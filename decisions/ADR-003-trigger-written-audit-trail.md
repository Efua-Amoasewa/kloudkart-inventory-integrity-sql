# ADR-003: Write the audit trail from a trigger on every stock change, and keep it append-only

- **Status:** Accepted
- **Date:** 2026-11-26
- **Decision owner:** Esther Efua Acquandoh

## Context

Nana wants a trail of every stock movement — sale, restock, correction — that an auditor can
walk afterwards. `inventory_log` exists, but nothing ties it to the stock figure: 144 products'
stock no longer equals the sum of their own log (F-02), so somewhere stock changed without a
movement being written. `race_test.py` test 4 checks that every successful sale left a row in
`inventory_log`.

## Decision

An `AFTER INSERT OR UPDATE OF stock_quantity` trigger on `products` writes one
`inventory_log` row for every stock change, whoever makes it (`sql/03_audit_trail.sql`).
Callers that know why stock moved (`place_order`, `record_stock_movement`,
`record_stock_count`) say so through transaction-local settings; a change made without them is
logged as `manual_update`. The log gains `order_id`, `stock_after` and `recorded_by`; old rows
keep NULL rather than an invented value. A second trigger refuses any `UPDATE` to the log.

## Alternatives considered

### Alternative A: Each function writes its own log row

- **How it would work:** `place_order` and the restock routine insert the movement themselves.
- **Why it is attractive:** Everything is visible in one function; no hidden code.
- **Why rejected:** Anyone who changes stock any other way leaves no trace — which is how F-02
  happened. A trigger cannot be forgotten.

### Alternative B: A new, separate movements table

- **How it would work:** Leave `inventory_log` as history and start a clean table.
- **Why it is attractive:** A tidy schema with proper types from day one.
- **Why rejected:** Two trails for an auditor to reconcile, and `race_test.py` reads
  `inventory_log`.

### Alternative C: Drop the stock column; stock is the sum of the log

- **How it would work:** Stock is computed from movements, so it can never disagree with them.
- **Why it is attractive:** A single source of truth.
- **Why rejected:** Every sale would sum hundreds of rows while holding the product lock,
  lengthening the flash-sale queue, and it is a large change for Nana's team to adopt.

## Consequences

- **What this buys:** Every stock change is in the trail, including manual ones, with the
  order that caused each sale. Verified (`tests/test_audit_trail.sql`): a restock, a manual
  update and a sale each produced exactly one correctly labelled row; a price-only change
  produced none; editing a log row was refused.
- **What this costs:** One extra insert per stock change, and code that runs without being
  called — documented here and in the README so maintainers know it exists.
- **What it costs the client if I am wrong:** An auditor finds stock changes with no
  explanation, and the stock figures stay untrustworthy.
- **What would make me revisit this:** A need to forbid deletes as well — that needs a
  separate application role without delete rights, which today's single-user setup and
  `race_test.py`'s own clean-up do not allow.

## What this survives

Contention: in race test 4, 12 buyers competing for 5 units left 5 sales plus 1 opening
balance — 6 movements for 6 changes. Each movement is written inside the buyer's own
transaction, so a refused or failed sale leaves no row.

It does not survive someone with full database rights disabling the trigger or deleting log
rows. The promise is: every change made through the database's normal paths is logged.
