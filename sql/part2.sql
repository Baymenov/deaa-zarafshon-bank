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


-- 2.4 Late-arriving segment change for customer 5520
-- Step 1: close the current row the day before the effective date
UPDATE dim_customer
SET valid_to = DATE '2026-03-11',
    is_current = 'N'
WHERE client_no = 5520
  AND is_current = 'Y';

-- Step 2: insert the new version from the effective date
INSERT INTO dim_customer
    (customer_key, client_no, segment, valid_from, valid_to, is_current)
VALUES
    (2002, 5520, 'affluent', DATE '2026-03-12', DATE '9999-12-31', 'Y');

-- Step 3: re-key facts that were loaded with the old key
UPDATE fact_transaction f
SET customer_key = c.customer_key
FROM dim_date d, dim_customer c
WHERE f.date_key = d.date_key
  AND c.client_no = f.client_no
  AND d.full_date BETWEEN c.valid_from AND c.valid_to
  AND f.client_no = 5520
  AND d.full_date >= DATE '2026-03-12'
  AND f.customer_key <> c.customer_key;
