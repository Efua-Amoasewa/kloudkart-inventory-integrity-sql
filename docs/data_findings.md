# Data findings — Kloud Kart

Measured on a fresh load of the Evalu8 bundle (PostgreSQL 18.7), 2026-11-26.
Every count below is produced by [`sql/01_integrity_checks.sql`](../sql/01_integrity_checks.sql),
except where a finding names its own query. "Now" in date checks means the moment the
check runs, so the future-dated counts (F-11) can only fall as time passes.

## Summary

The schema enforces almost nothing (no foreign keys, no unique email, free-text status),
and four years of traffic used that freedom. Ranked by what each fault does to the numbers
Nana relies on — stock counts, the Monday report and the low-stock rollup — rather than by
how many rows it touches:

1. **Stock is already wrong.** 14 products show negative stock (27 units sold that did not
   exist), and 144 products' stock no longer equals the sum of their own movement log.
   This is the overselling problem, already in the data.
2. **A naive Monday report would miss 80 % of completed spend**, because "completed" is
   spelled four ways (plus "complete").
3. **533 customers exist twice**, splitting their spend and inflating the customer count.
4. A handful of keying errors (quantities of 999 / 9999) and repeated order lines would
   inflate any figure built from order lines by about 4.0 million (3.07 m + 0.94 m).

The biggest count (89,260 status rows) is not the most dangerous fault; 14 negative-stock
products are, because they are exactly the failure Nana is paying refunds for.

## Reconciliation

How the Monday report's base is formed from what was loaded.

| Stage | Rows | Delta | Reason |
|---|---|---|---|
| Orders loaded | 159,384 | | `load.sql` row count |
| … whose customer exists | 159,174 | −210 | F-09: customer id not in `customers` |
| … not dated in the future | 159,159 | −15 | F-11: dated after the check ran |
| … in a "spend" status | 124,030 | −35,129 | Pending, cancelled and refunded orders excluded (decision: ADR-004) |
| Customer rows loaded | 40,420 | | `load.sql` row count |
| … distinct people (by trimmed, lower-cased email) | 39,885 | −535 | F-06: one person, several rows |

## Findings, ranked by risk

### F-01: Products with negative stock — Severity: Critical

- **What it is:** 14 products have `stock_quantity` below zero (−1 to −4), 27 units in total.
  No `CHECK (stock_quantity >= 0)` exists.
- **How I detected it:** `WHERE stock_quantity < 0`. For 13 of the 14 the movement log sums to
  the same negative number, so the log recorded the oversell faithfully.
- **Scale:** 14 products, 27 units.
- **Effect on the client's number:** 27 units were sold to customers who paid for stock that
  did not exist — the refund-and-apology cost Nana described. Every low-stock figure for these
  products is wrong in the reassuring direction: negative stock sorts as "very low" but hides
  that customers are owed goods.
- **What I did about it:** Added `CHECK (stock_quantity >= 0) NOT VALID` so no new write can go
  below zero (`sql/02_schema_fixes.sql`), and made `place_order` lock the row before deciding
  (`sql/04_place_order.sql`). I did not overwrite the 14 values: the right number is whatever
  is physically on the shelf, and only a stock count can say that.
- **Residual risk:** The 14 products stay negative until someone counts them. The constraint is
  `NOT VALID`, so it protects new writes but does not certify old rows.

### F-02: Stock does not match its own movement log — Severity: Critical

- **What it is:** For 3,879 of 4,023 products, `stock_quantity` equals the sum of every movement
  in `inventory_log`. For the other 144 it does not. Nothing forces stock changes and log rows to
  happen together.
- **How I detected it:** Join `products` to `sum(change_qty)` per product; count where unequal.
- **Scale:** 144 products; 2,553 units of disagreement in total (net −2,375: the stock figure is
  lower than the log implies on 122 of them, higher on 22).
- **Effect on the client's number:** Nana's stock counts "no longer match reality closely enough
  to trust" — this is the measurable version. For these products either the low-stock view or the
  audit trail is wrong, and today nobody can say which.
- **What I did about it:** From now on every stock change writes the log in the same transaction,
  through a trigger (`sql/03_audit_trail.sql`). The improvement beyond the brief is a work list of
  these products and a way to record a shelf count through the trail (`sql/08_improvement.sql`).
- **Residual risk:** The 144 existing gaps are not repaired until a stock count decides the true
  figure.

### F-03: Order status spelled 15 ways — Severity: High

- **What it is:** `status` is free text. 15 spellings collapse into 5 meanings: completed
  (`completed`, ` completed` with a leading space, `Completed`, `COMPLETED`, `complete`), pending,
  shipped, refunded and cancelled (`cancelled`, `canceled`, `Cancelled`, `CANCELLED`).
- **How I detected it:** `SELECT status, count(*) FROM orders GROUP BY status`, then grouping by
  `lower(trim(status))`.
- **Scale:** 159,384 orders; a filter on `status = 'completed'` matches 22,091 of the 111,351
  completed orders.
- **Effect on the client's number:** A Monday report filtering on the obvious spelling would show
  66.5 million of completed spend instead of 339.6 million — an 80 % understatement — and would
  rank customers on a fifth of their history.
- **What I did about it:** Added an `order_status_map` table that maps every spelling seen to one
  status and says whether it counts as spend; the report joins through it, and orders may only use
  a spelling that is in the map. New orders from `place_order` write `completed`.
- **Residual risk:** A new spelling must be added to the map before the application can use it —
  deliberately, so it cannot silently drop out of the report.

### F-06: The same customer on several rows — Severity: High

- **What it is:** `email` was never unique. 533 email addresses (compared trimmed and
  lower-cased) appear on 1,068 customer rows; every group carries one name, so these are the
  same people registered more than once.
- **How I detected it:** `GROUP BY lower(trim(email)) HAVING count(*) > 1`, then checking that each
  group has a single `lower(trim(full_name))`.
- **Scale:** 1,068 rows; 535 surplus.
- **Effect on the client's number:** The customer count is overstated by 535 (40,420 rows,
  39,885 people). Each duplicated person's spend is split across rows, so their total and rank
  are understated; merging them changes one name in the top 100.
- **What I did about it:** The report treats the lowest `customer_id` per normalised email as the
  person (`customer_identity` view, `sql/05_monday_report.sql`). I did not merge or delete rows.
- **Residual risk:** Two genuinely different people sharing one address would be merged in the
  report. No such case exists today (every group has one name).

### F-04: Keying-error quantities — Severity: High

- **What it is:** 6 order lines carry quantities of 999 or 9999. 99 % of lines are for 5 units
  or fewer, and the orders' own `total_amount` does not include these amounts.
- **How I detected it:** `ORDER BY quantity DESC`, then comparing each order's `total_amount`
  with the sum of its lines.
- **Scale:** 6 lines in 6 orders.
- **Effect on the client's number:** Any figure built from order lines (units sold, revenue by
  product) is inflated by 3,073,441.59 — the value of these 6 lines alone — and by 23,994 units.
- **What I did about it:** The Monday report uses `orders.total_amount`, the figure charged at
  checkout, so it is unaffected. Lines are flagged, not edited.
- **Residual risk:** Product-level revenue built from lines would still be wrong until these are
  corrected by someone who can see the original orders.

### F-05: Order lines repeated — Severity: Medium

- **What it is:** 616 (order, product) pairs appear more than once; in 577 of them every value is
  identical, which looks like a double insert rather than two genuine lines.
- **How I detected it:** `GROUP BY order_id, product_id, quantity, unit_price HAVING count(*) > 1`.
- **Scale:** 578 surplus rows, 894 units, 941,247.62 of line value.
- **Effect on the client's number:** Line-based revenue and units sold are overstated by those
  amounts. Together with F-04 this explains most of the 2,279 orders whose total disagrees with
  their lines.
- **What I did about it:** Report uses `total_amount`. Not deleted: the 39 non-identical pairs show
  that a repeated product can be legitimate, and only the application owner can say which is
  which.
- **Residual risk:** As F-04.

### F-09: Orders whose customer does not exist — Severity: Medium

- **What it is:** 210 orders reference a `customer_id` absent from `customers`.
- **How I detected it:** Anti-join `orders` → `customers`.
- **Scale:** 210 orders, 665,180.61 of order value.
- **Effect on the client's number:** These orders cannot appear in a per-customer report; that
  money is silently missing from "total spent" and from the ranking.
- **What I did about it:** Added the foreign key `NOT VALID`, so new orders must name a real
  customer. The excluded value is stated in the reconciliation above.
- **Residual risk:** The 210 stay unattributed until the customer rows are recovered.

### F-08: Order lines with no order — Severity: Medium

- **What it is:** 692 lines in 689 orders whose ids (900101–999862) lie outside the range of
  existing orders (500001–659384). The order headers are gone.
- **How I detected it:** Anti-join `order_items` → `orders`.
- **Scale:** 692 lines, 826,327.80 of line value.
- **Effect on the client's number:** Invisible to every order-based report; would inflate any
  product-sales figure built from lines.
- **What I did about it:** Foreign key added `NOT VALID`. Not deleted. New order numbers start at
  1,000,000 so no new order can ever inherit these lines (`sql/02_schema_fixes.sql`).
- **Residual risk:** If these were real sales, 826 k of revenue has no customer and no date.

### F-12: Category tree has a loop and a missing parent — Severity: Medium

- **What it is:** "Promotions" (9002) and "Seasonal Promotions" (9001) are each other's parent,
  and "Clearance" (9003) points at a parent (8999) that does not exist.
- **How I detected it:** Walking down from the roots with a recursive query (with a `CYCLE` guard)
  reaches 91 of 94 categories; the three left over are these.
- **Scale:** 3 categories; 6 products, all under the Promotions loop (Clearance holds none),
  2 of them low on stock (fewer than 5 units, the threshold in ADR-005).
- **Effect on the client's number:** These products never appear in a rollup that starts from
  the top of the tree, so 2 low-stock items are invisible on Nana's dashboard. A recursive query
  without a loop guard started from 9001 or 9002 never finishes.
- **What I did about it:** The rollup carries a `CYCLE` guard and lists unreachable categories
  separately so their products are still counted (`sql/06_category_rollup.sql`). Foreign key on
  `parent_id` added `NOT VALID`.
- **Residual risk:** Someone must decide where Promotions and Clearance belong; I cannot.

### F-13: Products with no category — Severity: Medium

- **What it is:** 37 products have `category_id` NULL.
- **How I detected it:** `WHERE category_id IS NULL`.
- **Scale:** 37 products; 12 are low on stock (fewer than 5 units).
- **Effect on the client's number:** They fall outside every category in the rollup.
- **What I did about it:** The rollup reports them under "Uncategorised" so they are still seen.
  Not made `NOT NULL`: race_test.py creates products with no category, and Nana may sell
  uncategorised items deliberately.
- **Residual risk:** Low; they are visible.

### F-10: Order lines with no price or a zero price — Severity: Low

- **What it is:** 148 lines have no `unit_price`; 152 have a price of 0.
- **How I detected it:** `WHERE unit_price IS NULL` / `= 0`.
- **Scale:** 300 lines; the 148 unpriced lines are worth about 399,909 at today's list price.
- **Effect on the client's number:** Line-based revenue is understated by up to that amount.
  Zero-priced lines may be promotions; nothing in the data says.
- **What I did about it:** Report uses `total_amount`. Flagged.
- **Residual risk:** Unknown whether zero means "free" or "missing".

### F-11: Rows dated in the future — Severity: Low

- **What it is:** 15 orders and 33 log rows are dated after today (latest 2027-08-20).
  The extract's dense data ends on 2026-08-31.
- **How I detected it:** `WHERE order_date > now()`.
- **Scale:** 15 orders worth 40,871.60.
- **Effect on the client's number:** They would land in months that have not happened, then
  silently join the trailing-12-month figures when their date arrives.
- **What I did about it:** The report excludes orders dated after the moment it is refreshed.
- **Residual risk:** The real dates are unknown.

### F-07: Emails with surrounding spaces — Severity: Low

- **What it is:** 1,314 emails start or end with a space.
- **How I detected it:** `WHERE email <> trim(email)`.
- **Scale:** 1,314 rows.
- **Effect on the client's number:** On its own, nothing visible; but it hides duplicates — exact
  matching finds 299 duplicated addresses, trimmed matching finds 533 (F-06).
- **What I did about it:** All matching trims and lower-cases. New emails must arrive trimmed.
- **Residual risk:** Low.

### F-14: Movement log rows for products that no longer exist — Severity: Low

- **What it is:** 120 log rows reference 111 product ids absent from `products`.
- **How I detected it:** Anti-join `inventory_log` → `products`.
- **Scale:** 120 rows.
- **Effect on the client's number:** None on current stock. An auditor walking the trail meets
  movements for products nobody can name.
- **What I did about it:** Kept: an audit trail should outlive what it describes. Foreign key added
  `NOT VALID` so new movements must name a real product.
- **Residual risk:** Low.

## Looked wrong, is not wrong

| Apparent problem | Why it looks wrong | Why it is actually fine |
|---|---|---|
| Negative `change_qty` on 262,088 sale, 290 correction and 268 damage rows | Negative quantities | `change_qty` is signed by design: negative is stock going out (schema comment). |
| 90 `stock_take` rows with `change_qty` = 0 | A movement of nothing | A stock count that confirmed the figure; recording it is good practice. |
| Order lines hold 554,451 units but the log records 412,645 sold | 141,806 units "missing" from the trail | The log records a sale when an order is completed or shipped. Matched by product and day, 227,443 of 227,700 groups agree exactly; the gap is pending, cancelled and refunded orders, which never moved stock. |
| 4,116 lines sold below today's product price | Price mismatch | Never above it, only below: the price at the time of sale or a discount. A line keeps the price the customer paid. |
| 406 product names used more than once | Duplicate products | Only 16 groups share both category and price; the other 390 differ in category or price, so they are different items that happen to share a name. |
| `order_date` stored without a time zone | The schema comment flags it | Ghana is UTC+0 all year with no daylight saving, and orders peak at 13:00–14:00, consistent with local time. It becomes a risk only if Nigerian customers (Abuja, Lagos: UTC+1, about 5,400 customers) are ever reported by hour. |
| Customers in Abuja and Lagos | Accra shop, Nigerian cities | Cross-border customers, not errors. |

## Could not verify

- Whether `total_amount` is right on the roughly 1,790 orders whose total still differs from
  their lines after removing F-04 and F-05 (about 740 k in total). Discounts or delivery fees
  would explain it; the extract has no column for either.
- The true stock of the 14 negative and 144 mismatched products: only a physical count can.
- Whether zero-priced lines are promotions or missing prices.
- Where the Promotions / Seasonal Promotions loop and the Clearance category belong in the tree.
