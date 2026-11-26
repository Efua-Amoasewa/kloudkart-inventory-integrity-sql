-- tests/test_refresh.sql
-- Times the stored report's refresh (the cost side of ADR-002) and checks it is readable.

\pset pager off
\timing on
\echo '--- refresh three times; each time is the cost of bringing the figures up to date'
CALL refresh_monday_report();
CALL refresh_monday_report();
CALL refresh_monday_report();
\timing off

\echo '--- every refresh is logged, so Adwoa can see how fresh her figures are'
SELECT refreshed_at, duration FROM monday_report_refresh_log ORDER BY refreshed_at;

\echo '--- the stored top 100 matches the live one (expect 0 differences)'
SELECT count(*) AS differences
FROM (
    (SELECT person_id, total_spent, spend_rank FROM report_top_100
     EXCEPT
     SELECT person_id, total_spent, spend_rank FROM monday_top_100)
    UNION ALL
    (SELECT person_id, total_spent, spend_rank FROM monday_top_100
     EXCEPT
     SELECT person_id, total_spent, spend_rank FROM report_top_100)
) AS diff;
