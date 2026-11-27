# ADR-004: Define the Monday report's figures — spend, customer, ranking, time window

- **Status:** Accepted
- **Date:** 2026-11-26
- **Decision owner:** Esther Efua Acquandoh

## Context

The brief asks for total spent, order count, trailing-12-month spend, a running total and a
top-100 ranking, but leaves every definition open, and Nana is not available to ask. The data
makes each choice matter: status is spelled 15 ways (F-03), 533 people exist twice (F-06),
order lines are inflated by keying errors and repeats (F-04, F-05), and some orders are dated
in the future (F-11). Each decision below is applied in `sql/05_monday_report.sql`.

## Decision

1. **Spend** = orders whose status counts as spend — completed and shipped — valued at
   `orders.total_amount`, the amount charged at checkout.
2. **A customer** = a person, identified by trimmed, lower-cased email; duplicates are reported
   once under their lowest `customer_id`.
3. **Excluded** = orders whose customer does not exist (210) and orders dated after the report
   is refreshed (15).
4. **Ranking** uses `RANK`: people who spent the same share a place.
5. **Running total** adds orders in date order with `ROWS` framing and `order_id` as a
   tie-breaker.
6. **Trailing 12 months** = the current calendar month to date plus the 11 before it.

## Alternatives considered

### Alternative A: Count pending orders as spend

- **How it would work:** Include `pending` (16,009 orders) with completed and shipped.
- **Why it is attractive:** Shows demand sooner; Adwoa sees this week's orders straight away.
- **Why rejected:** Pending money has not been taken and some of it will be cancelled. A
  ranking Nana negotiates with should rest on money received.

### Alternative B: Value spend from order lines

- **How it would work:** `sum(quantity × unit_price)` per order.
- **Why it is attractive:** Itemised, and independent of what the application wrote.
- **Why rejected:** Keying errors and repeated lines inflate line totals by about 4.0 million
  (F-04, F-05); `total_amount` is what the customer was actually charged.

### Alternative C: One customer per `customer_id`

- **How it would work:** Report the rows as stored.
- **Why it is attractive:** No merging, so no risk of joining two different people.
- **Why rejected:** 533 people's spend would be split across two rows, understating their
  rank. Every duplicated group carries one name, so merging is safe on today's data.

### Alternative D: `ROW_NUMBER` for the top 100; default `RANGE` framing for the running total

- **How it would work:** Always exactly 100 rows; the database's default window frame.
- **Why it is attractive:** A list of exactly 100; less to write.
- **Why rejected:** `ROW_NUMBER` breaks ties by chance, so an equally good customer can be cut
  arbitrarily. `RANGE` shows two orders placed at the same moment with the same combined
  total, so a running total would jump twice by the same amount.

## Consequences

- **What this buys:** Figures that match a hand calculation exactly (`tests/test_monday_report.sql`:
  258,975.35 by hand and by report for rank 1), reconciled to 124,030 orders as of 26 November 2026
  (124,031 from 4 December, as a future-dated order comes due), with every exclusion counted in
  `docs/data_findings.md`.
- **What this costs:** The report shows less money than a figure including pending orders,
  and "top 100" can hold slightly more than 100 people when there is a tie at the boundary.
- **What it costs the client if I am wrong:** If Nana counts shipped orders as not yet
  earned, spend is overstated by roughly the shipped share (about 41 million of 380 million).
  If two different people ever share an email, the report would merge them.
- **What would make me revisit this:** Nana defining "spend" differently, partial refunds
  appearing, or a shared email with two different names.

## What this survives

New status spellings cannot silently disappear: an order may only use a spelling that is in
`order_status_map`, so a new one forces someone to decide whether it counts. Orders placed
during a flash sale through `place_order` are written as `completed` and counted at the next
refresh. A naive report filtering `status = 'completed'` would have missed 80 % of completed
spend.
