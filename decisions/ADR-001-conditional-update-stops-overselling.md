# ADR-001: Stop overselling with one check-and-decrement statement inside place_order

- **Status:** Accepted
- **Date:** 2026-11-26
- **Decision owner:** Esther Efua Acquandoh

## Context

Kloud Kart oversold its best-selling product twice last month, and the data shows it is
not a one-off: 14 products carry negative stock today (F-01). Under PostgreSQL's default
isolation (Read Committed) two orders can both read "1 left", both decide to sell, and both
write — a lost update. Nobody wrote a bug; each order was correct on its own.

The mechanism must satisfy `race_test.py` unmodified: exactly one winner of the last unit
over 25 rounds, exactly 50 winners from 400 simultaneous buyers of 50 units, a clean refusal
that says "out of stock", no error ever reaching the caller, stock never below zero, and the
order and its stock movement in one unit of work. Marketing expects flash sales of about 400
orders in ten seconds on one product.

**Would triggers alone have fixed it?** No, though the suggestion was reasonable. A trigger
is good at doing something every time stock changes, whoever changes it — which is exactly
how the audit trail is built (ADR-003). What it cannot do is make two buyers take turns: when
two orders arrive at the same instant, each runs inside its own transaction, each fires its
own copy of the trigger, and neither can see the other's unfinished sale, so both still
believe the last unit is available. What fixes it is making the second buyer wait until the
first has finished, then look again.

## Decision

`place_order` checks and decrements stock in a single statement —
`UPDATE products SET stock_quantity = stock_quantity - qty WHERE product_id = … AND stock_quantity >= qty` —
and treats "no row changed" as out of stock. PostgreSQL locks the row while updating; a
second buyer waits for that lock, re-reads the committed row and finds too little stock.
The order, its line and the movement are written in the same transaction
(`sql/04_place_order.sql`). A `CHECK (stock_quantity >= 0)` constraint is the safety net
underneath (`sql/02_schema_fixes.sql`).

## Alternatives considered

### Alternative A: Explicit lock — `SELECT … FOR UPDATE`, then `UPDATE`

- **How it would work:** Read the stock with `FOR UPDATE` (taking the row lock), decide in
  PL/pgSQL, then decrement.
- **Why it is attractive:** The lock is visible in the code, and reading the stock first
  allows richer decisions (a partial fill, a reservation).
- **Why rejected:** For a single product it takes the same lock as the chosen design with an
  extra statement and nothing gained. It becomes the right choice for multi-item orders,
  where every product must be locked in ascending `product_id` order to avoid deadlocks.

### Alternative B: `SERIALIZABLE` isolation with a retry loop

- **How it would work:** Run the order at `SERIALIZABLE`; PostgreSQL aborts one of two
  conflicting buyers with a serialization failure (SQLSTATE 40001) and the function retries.
- **Why it is attractive:** It protects against anomalies nobody has thought of yet, without
  relying on every writer following a locking convention.
- **Why rejected:** In a flash sale nearly every buyer conflicts with every other, so most
  attempts abort and retry, repeatedly — more work exactly when the server is busiest. The
  retry loop is also code someone may later remove, and an un-retried abort is a failure in
  `race_test.py`.

### Alternative C: Triggers alone

- **How it would work:** A trigger on order insert decrements stock.
- **Why it is attractive:** It was the suggestion Nana received, and it runs for every writer.
- **Why rejected:** It does not make concurrent buyers take turns (see Context).

### Alternative D: The `CHECK (stock_quantity >= 0)` constraint alone

- **How it would work:** Let both buyers try; the one that would push stock below zero fails.
- **Why it is attractive:** One line, enforced for every writer forever.
- **Why rejected as the mechanism:** It refuses by raising an error, not with an answer the
  customer can be shown, and an error reaching the caller fails the test. Kept as the safety
  net.

## Consequences

- **What this buys:** Exactly one winner, every time: `race_test.py` passed 6 of 6
  consecutive runs (`evidence/race_test_runs.txt`). No retries, so no retry storms.
- **What this costs:** Buyers of the *same* product queue one behind another; different
  products do not wait for each other. A refused attempt leaves a gap in order numbers. A
  buyer stuck behind a lock for more than 5 seconds is told "busy, please try again" rather
  than left waiting. The guarantee holds only if every sale goes through `place_order`.
- **What it costs the client if I am wrong:** Overselling continues: refunds, apologies,
  reviews — and stock counts drift further from reality.
- **What would make me revisit this:** Orders with several products (switch to Alternative
  A, locking in `product_id` order); or "busy" answers appearing in normal trading, which
  would mean something is holding product locks far too long.

## What this survives

A 400-buyer flash sale on 50 units: exactly 50 sold, 350 told "out of stock", 0 errors, in
3.58–4.13 s of wall clock per run across 6 runs on a fresh load, including opening 400 connections, on a
4-core laptop. Each sale holds the product lock only for the decrement and three inserts,
so the queue drains quickly; most of the wall clock is connection set-up.

It does not survive a spike that needs more simultaneous connections than the server allows
(`max_connections` = 500): those buyers are refused before `place_order` runs. Raising that
ceiling further needs a connection pooler — new infrastructure, so Nana's decision.

A naive build (read stock, then update it, at the default isolation level) passes every test
on a quiet day and fails on the first flash sale — the exact failure Nana already has.
