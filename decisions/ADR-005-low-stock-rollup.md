# ADR-005: Define low stock as fewer than 5 units and roll it up with a guarded recursive walk

- **Status:** Accepted
- **Date:** 2026-11-26
- **Decision owner:** Esther Efua Acquandoh

## Context

Nana wants low-stock visibility rolled up through a category tree that is four levels deep
today and keeps growing; the brief forbids hard-coding the depth. "Low" is not defined and the
schema has no reorder level. The tree is also broken: Promotions and Seasonal Promotions are
each other's parent, Clearance's parent does not exist (F-12), and 37 products have no
category at all (F-13).

## Decision

**Low stock** means fewer than 5 units, defined once in `low_stock_threshold()`. Half of all
products hold 12 or fewer and a typical product sells about 18 units a month, so 5 units is
roughly a week of cover. Out of stock (0 or below) is counted separately.

The rollup (`sql/06_category_rollup.sql`) is a recursive query that starts from **every**
category and walks down to whatever depth exists, with a `CYCLE` guard. A category's figure
includes everything beneath it. Products the tree cannot reach, and uncategorised products,
are listed explicitly. It stays a live view, not a stored answer.

## Alternatives considered

### Alternative A: Join the category table to itself four times

- **How it would work:** Category → parent → grandparent → great-grandparent.
- **Why it is attractive:** Simple to read; fast.
- **Why rejected:** It silently stops at level four the week marketing adds a fifth — the exact
  thing the brief forbids.

### Alternative B: A per-product reorder level

- **How it would work:** Each product carries its own "warn me below" figure.
- **Why it is attractive:** The right answer: fast sellers need more cover than slow ones.
- **Why rejected for now:** The data has no such figure and inventing 4,023 of them would be
  guessing. Recommended to Nana as a next step.

### Alternative C: Store the rollup's answer, like the Monday report

- **How it would work:** A materialized view refreshed on a schedule.
- **Why it is attractive:** Consistent with ADR-002.
- **Why rejected:** Stock changes with every sale, and a stale low-stock figure is the
  dangerous kind. The live view answers in about 6 ms anyway.

## Consequences

- **What this buys:** 1,424 low-stock products shown across the tree with none counted twice
  (top-level families 1,410 + loop 2 + Clearance 0 + uncategorised 12 = 1,424), and a fifth
  level is picked up with no query change (`tests/test_category_rollup.sql`).
- **What this costs:** One threshold for every product. For a product selling 100 a month,
  5 units is about a day and a half of cover, not a week.
- **What it costs the client if I am wrong:** Fast sellers run out before they appear on the
  list, or the list is so long it is ignored (1,424 of 4,023 products today).
- **What would make me revisit this:** Nana setting reorder levels per product or category,
  or staff reporting the list is too long to act on.

## What this survives

A loop in the tree no longer hangs the query: the `CYCLE` guard stops it after one lap. A new
level, or a category whose parent is deleted, still has its products counted. During a flash
sale the rollup reads stock without blocking sales (readers never block writers in
PostgreSQL), so Nana can watch stock fall live.
