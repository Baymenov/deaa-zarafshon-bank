-- Part 5: pipeline, quality and compliance

-- 5.1 Control and log tables
CREATE TABLE load_batch (
    batch_id       BIGINT PRIMARY KEY,
    file_name      VARCHAR(200) NOT NULL,
    file_hash      CHAR(64) NOT NULL UNIQUE,
    status         VARCHAR(10) NOT NULL,
    loaded_at      TIMESTAMP
);

CREATE TABLE fact_transaction_correction (
    transaction_id     VARCHAR(30) NOT NULL,
    account_key        BIGINT NOT NULL,
    old_amount_uzs     NUMERIC(18,2),
    new_amount_uzs     NUMERIC(18,2),
    old_fee_uzs        NUMERIC(18,2),
    new_fee_uzs        NUMERIC(18,2),
    batch_id           BIGINT NOT NULL,
    corrected_at       TIMESTAMP NOT NULL
);

ALTER TABLE fact_transaction
    ADD CONSTRAINT uq_fact_transaction UNIQUE (transaction_id, account_key);

-- 5.1 Step 1: remove duplicates inside the staging table (last record wins)
DELETE FROM stg_fact_transaction s
USING (
    SELECT ctid AS row_id,
           ROW_NUMBER() OVER (PARTITION BY transaction_id, account_key
                              ORDER BY record_no DESC) AS rn
    FROM stg_fact_transaction
) d
WHERE s.ctid = d.row_id
  AND d.rn > 1;

-- 5.1 Step 2: log the old values of corrected rows
INSERT INTO fact_transaction_correction
    (transaction_id, account_key, old_amount_uzs, new_amount_uzs,
     old_fee_uzs, new_fee_uzs, batch_id, corrected_at)
SELECT f.transaction_id, f.account_key,
       f.amount_signed_uzs, s.amount_signed_uzs,
       f.fee_amount_uzs, s.fee_amount_uzs,
       s.batch_id, CURRENT_TIMESTAMP
FROM fact_transaction f
JOIN stg_fact_transaction s
  ON s.transaction_id = f.transaction_id
 AND s.account_key    = f.account_key
WHERE f.amount_signed_uzs <> s.amount_signed_uzs
   OR f.fee_amount_uzs    <> s.fee_amount_uzs;

-- 5.1 Step 3: insert new postings, update corrected ones
MERGE INTO fact_transaction f
USING stg_fact_transaction s
   ON f.transaction_id = s.transaction_id
  AND f.account_key    = s.account_key
WHEN MATCHED AND (f.amount_signed_uzs <> s.amount_signed_uzs
               OR f.fee_amount_uzs    <> s.fee_amount_uzs) THEN
    UPDATE SET amount_signed_uzs = s.amount_signed_uzs,
               fee_amount_uzs    = s.fee_amount_uzs
WHEN NOT MATCHED THEN
    INSERT (transaction_id, account_key, date_key, customer_key,
            branch_key, transaction_type_key, currency_key, channel_key,
            amount_signed_uzs, fee_amount_uzs, transaction_count,
            exchange_rate)
    VALUES (s.transaction_id, s.account_key, s.date_key, s.customer_key,
            s.branch_key, s.transaction_type_key, s.currency_key,
            s.channel_key, s.amount_signed_uzs, s.fee_amount_uzs, 1,
            s.exchange_rate);

-- 5.1 Step 4: rebuild the daily aggregate for every date touched by the load
DELETE FROM agg_daily_net_inflow
WHERE date_key IN (SELECT DISTINCT date_key FROM stg_fact_transaction);

INSERT INTO agg_daily_net_inflow
    (date_key, region, segment, net_inflow_uzs, transaction_count)
SELECT f.date_key,
       b.region,
       c.segment,
       SUM(f.amount_signed_uzs),
       COUNT(*)
FROM fact_transaction f
JOIN dim_branch   b ON f.branch_key   = b.branch_key
JOIN dim_customer c ON f.customer_key = c.customer_key
WHERE f.date_key IN (SELECT DISTINCT date_key FROM stg_fact_transaction)
GROUP BY f.date_key, b.region, c.segment;


-- 5.2 Serving table for the declined-transactions dashboard
CREATE TABLE agg_card_decline_minute (
    window_start    TIMESTAMP NOT NULL,
    mcc             CHAR(4) NOT NULL,
    total_count     INT NOT NULL,
    declined_count  INT NOT NULL,
    updated_at      TIMESTAMP NOT NULL,
    PRIMARY KEY (window_start, mcc)
);

-- 5.2 Upsert written by the stream (a new or corrected window replaces the old row)
INSERT INTO agg_card_decline_minute
    (window_start, mcc, total_count, declined_count, updated_at)
VALUES
    (TIMESTAMP '2026-11-07 14:03:00', '5411', 1240, 37, CURRENT_TIMESTAMP)
ON CONFLICT (window_start, mcc)
DO UPDATE SET total_count    = EXCLUDED.total_count,
              declined_count = EXCLUDED.declined_count,
              updated_at     = EXCLUDED.updated_at;

-- 5.2 Dashboard: decline share by merchant category and hour of day
SELECT mcc,
       EXTRACT(HOUR FROM window_start) AS hour_of_day,
       SUM(declined_count)             AS declined,
       SUM(total_count)                AS total,
       ROUND(100.0 * SUM(declined_count) / SUM(total_count), 2) AS decline_share_pct
FROM agg_card_decline_minute
WHERE window_start >= DATE '2026-11-07'
  AND window_start <  DATE '2026-11-08'
GROUP BY mcc, EXTRACT(HOUR FROM window_start)
ORDER BY mcc, hour_of_day;
