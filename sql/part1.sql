-- Part 1: dimensional model for transactions and balances

-- 1.3 Total deposits in and net inflow by region for one day
SELECT b.region,
       SUM(CASE WHEN f.amount_signed_uzs > 0
                THEN f.amount_signed_uzs ELSE 0 END) AS total_deposits_in,
       SUM(f.amount_signed_uzs) AS net_inflow
FROM fact_transaction f
JOIN dim_branch b ON f.branch_key = b.branch_key
JOIN dim_date d ON f.date_key = d.date_key
WHERE d.full_date = DATE '2026-03-12'
GROUP BY b.region;

-- 1.4 Average monthly balance per customer, last 24 full months
WITH daily_customer AS (
    SELECT c.client_no,
           d.year_month,
           d.full_date,
           SUM(f.closing_balance_uzs) AS customer_balance
    FROM fact_daily_balance f
    JOIN dim_date d ON f.date_key = d.date_key
    JOIN dim_customer c ON f.customer_key = c.customer_key
    WHERE d.full_date >= DATE '2024-11-01'
      AND d.full_date <  DATE '2026-11-01'
    GROUP BY c.client_no, d.year_month, d.full_date
)
SELECT client_no,
       year_month,
       AVG(customer_balance) AS avg_monthly_balance_uzs
FROM daily_customer
GROUP BY client_no, year_month
ORDER BY client_no, year_month;
-- 1.5 Build and query the monthly balance snapshot
