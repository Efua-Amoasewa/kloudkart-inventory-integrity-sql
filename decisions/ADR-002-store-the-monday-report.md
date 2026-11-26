# ADR-002: Make the Monday report fast by storing its answer, not by buying a bigger server

- **Status:** Accepted
- **Date:** 2026-11-26
- **Decision owner:** Esther Efua Acquandoh

## Context

Adwoa's Monday report takes about 40 minutes and sometimes does not finish, so Nana decides
without it. Someone has priced a bigger server. Measured on this extract (159,384 orders),
the report written as plain views takes 353–448 ms per part (median of 20 runs,
`evidence/performance_before.txt`). The 40 minutes is therefore not reproduced by the data I
was given; it most likely comes from how the current report is built, which I could not see.
The plans show where the time goes: matching duplicate customers by email, grouping 124,030
orders where the planner expected 200 groups, and a sort that spilled to disk. Kloud Kart adds
about 4,000 orders a day, so a report that rereads every order gets slower every week.

## Decision

Keep the report's logic in plain views (`sql/05_monday_report.sql`, one definition of
"spend") and store their answers as materialized views refreshed by
`CALL refresh_monday_report()` before Adwoa starts on Monday (`sql/07_performance.sql`).
Each has a unique index so it refreshes `CONCURRENTLY`: readers keep the previous figures
while a refresh runs. Add an index on `orders(customer_id)` for one-customer lookups, built
`CONCURRENTLY` so order-taking is not blocked. Every refresh is logged with its time.

## Alternatives considered

### Alternative A: A bigger server

- **How it would work:** Same queries, more CPU and memory.
- **Why it is attractive:** No change to anything Adwoa does; immediate.
- **Why rejected:** A monthly bill the brief rules out, and it only divides the same work by
  a constant while the order table keeps growing. Storing the answer removes the work from
  the moment someone is waiting.

### Alternative B: Plain views only

- **How it would work:** Adwoa reads the views in `05_monday_report.sql` directly.
- **Why it is attractive:** Always current, nothing to schedule, and under half a second on
  today's data — within "seconds".
- **Why rejected:** The cost grows with every order and lands on the live server during the
  working day. Kept as the definition the stored report is built from.

### Alternative C: Indexes only

- **How it would work:** Index the join and grouping columns and keep querying live.
- **Why it is attractive:** No staleness at all.
- **Why rejected:** The report reads nearly every order; an index helps a query that wants a
  few rows, and the planner correctly ignores it for one that wants most of them.

### Alternative D: A running summary table updated by a trigger on every order

- **How it would work:** Each sale adds its amount to the customer's stored totals.
- **Why it is attractive:** Instant and always fresh.
- **Why rejected:** It puts extra writes — and a second busy row per customer — inside every
  sale, exactly the path that must stay short during a flash sale, and it must also handle
  refunds and status changes correctly forever.

## Consequences

- **What this buys:** Customer summary 447.75 ms → 3.14 ms, top 100 423.33 → 0.07 ms, running
  total 353.33 → 9.63 ms, monthly spend 396.19 → 7.09 ms, one customer's orders 7.70 → 0.13 ms
  (medians, `docs/measurement_report.md`).
- **What this costs:** The figures are as of the last refresh. A refresh takes 3.15–3.41 s.
  Inserting orders is about 6 % slower (18.22 → 19.33 ms per 1,000) because of the new index.
  The stored copies use disk.
- **What it costs the client if I am wrong:** If Adwoa needs same-day figures, Monday's
  decisions are made on numbers that miss Monday morning's orders.
- **What would make me revisit this:** A need for intraday figures (refresh hourly instead,
  about 3.5 s of server time an hour), or refresh time growing past a few minutes.

## What this survives

A flash sale does not touch the stored report: `place_order` writes no report rows, so the
sale path carries no extra cost apart from maintaining one index. A concurrent refresh reads
the order tables without blocking new orders. Refresh time grows with the number of orders;
I have not measured it at 10× today's volume.

A naive build — reading the live tables for every report and hoping a bigger server keeps up
— pays for that server every month and still slows down every week.
