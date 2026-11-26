# Memo to Nana

**From:** Esther Efua Acquandoh
**Date:** 26 November 2026
**Subject:** Overselling stopped, Monday report in seconds — and what the data says about your stock

## What I found

- **Overselling has already happened more than you knew.** 14 products show fewer than zero
  units in stock: 27 items sold that were never on the shelf. For another 143 products, the
  stock figure no longer matches the record of goods coming in and going out.
- **The Monday figures were at risk of being badly wrong.** "Completed" is typed five different
  ways in your order records. A report that looks for one spelling sees about 66 million of
  completed sales instead of 340 million.
- **533 customers are registered twice**, so their spending is split and some rank lower than
  they should.

## What I built

| What you asked for | Status | Evidence |
|---|---|---|
| No overselling: one buyer gets the last unit, the other is told "out of stock" | Done | Tested 6 times in a row: 400 shoppers racing for 50 units, exactly 50 sold, no errors, about 3–4 seconds each time |
| Monday report in seconds | Done | Opens in under a hundredth of a second; it was about half a second before, on your data |
| Low stock at a glance, through every category level | Done | About 6 thousandths of a second; still works when a new level is added |
| A trail of every stock movement | Done | Every change is recorded with its reason, and records cannot be edited afterwards |
| Extra: a list of the 157 products to recount | Done | Staff enter what they count; each count is recorded in the trail |

The Monday report is now prepared ahead of time, so it opens instantly — but it shows figures as
of its last update, which I suggest scheduling for early Monday morning. If Adwoa needs same-day
figures, it can be updated every hour instead, at a cost of about three seconds of server time
each time.

## What I recommend

1. **Count the 157 products on the new list, starting with the 14 below zero.** Until then, their
   stock figures cannot be trusted and some customers may be owed goods.
2. **Do not buy the bigger server.** The report problem was in how the figures were worked out,
   not in the machine.
3. **Decide where the "Promotions" and "Clearance" categories belong**, and set a "warn me
   below" level for your fastest sellers: today every product warns at fewer than 5 units.

## What I could not stand behind

- **I could not reproduce Adwoa's 40 minutes**; on the data I was given the old-style report took
  about half a second. I can say the new report is fast; I cannot say why hers was slow.
- **The true stock of the 157 listed products**: only a physical count can tell.
- **About 1,790 orders whose total differs from their items** (about 740 thousand in all) —
  possibly discounts or delivery fees; the records do not say.
- **A real flash sale**: tested with 400 simulated shoppers on a laptop, not on your live system,
  and only for orders of a single product.
