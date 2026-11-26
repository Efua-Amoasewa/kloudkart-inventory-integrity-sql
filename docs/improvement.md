# Improvement beyond the brief: a stock-count work list that closes through the audit trail

## The problem it solves

Nana says his stock counts "no longer match reality closely enough to trust". The diagnosis
turned that into numbers: 14 products show negative stock — goods customers paid for that were
not on the shelf (F-01) — and 144 products' stock disagrees with the sum of their own movement
log by 2,553 units in total (F-02). The brief's four requirements stop new damage; none of them
tells staff which shelves to go and count, or gives them a way to record what they find without
breaking the trail.

## What I built

`sql/08_improvement.sql`, tested in `tests/test_improvement.sql`:

- **`stock_drift`** — a work list of every product to count: today 157 (14 with negative stock,
  143 whose stock and log disagree), worst first, with the unexplained difference and the date
  of the last movement.
- **`record_stock_count(product, counted, counted_by)`** — staff enter what is on the shelf. In
  one step it sets the stock to the counted figure (logged as a `stock_take`) and, if the log
  still cannot explain that figure, adds one `correction` entry that closes the historical gap.
  Both entries name who counted. The product then leaves the work list.

Because every stock change is now logged (ADR-003), stock and log move together from here on.
A product appearing on the list **after** it has been counted means something changed stock
without going through the database's normal paths — so the list doubles as an alarm.

## What it is worth to Nana

- **A finite job instead of a vague worry:** 157 named products to count, worst first, rather
  than a re-count of all 4,023.
- **Fewer repeat refunds:** the 14 negative-stock products are the ones most likely to be
  oversold again or owed to customers; they head the list.
- **Trust that lasts:** once counted, stock and the auditor's trail agree, and stay agreeing —
  and if they ever drift, the list shows it the same day.
- **Every correction is explained:** an auditor sees who counted, when, and by how much the
  figure moved, instead of a silent edit.

Tested on the worst case (product 7667: recorded 220, log implied 276): a count of 7 produced a
`stock_take` of −213 and a `correction` of −56, both ending at 7, and the product left the list.

## What it cost

- About 60 lines of SQL: one view and one function, no new tables or infrastructure.
- No cost to sales: `place_order` is unchanged. A count takes the same product lock as a sale,
  so a count and a sale of the same product queue for a moment rather than overwrite each other.
- Staff time to count 157 shelves — the real cost, and a decision for Nana about when.
