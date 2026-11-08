-- Part 2: customer history and slowly changing dimensions

-- 2.3 Transactions of customer 4471 while rated high risk (surrogate key)
SELECT f.transaction_id,
       d.full_date,
       f.amount_signed_uzs,
       c.risk_rating
FROM fact_transaction f
JOIN dim_customer c ON f.customer_key = c.customer_key
JOIN dim_date d     ON f.date_key = d.date_key
WHERE c.client_no = 4471
  AND c.risk_rating = 'high'
ORDER BY d.full_date, f.transaction_id;

-- 2.3 Same question if the fact table has only client_no (range join)
SELECT f.transaction_id,
       d.full_date,
       f.amount_signed_uzs,
       c.risk_rating
FROM fact_transaction f
JOIN dim_date d     ON f.date_key = d.date_key
JOIN dim_customer c ON c.client_no = f.client_no
                   AND d.full_date BETWEEN c.valid_from AND c.valid_to
WHERE f.client_no = 4471
  AND c.risk_rating = 'high'
ORDER BY d.full_date, f.transaction_id;
