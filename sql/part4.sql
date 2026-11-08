-- Part 4: raw data vault for the customer

CREATE TABLE hub_customer (
    customer_hk          CHAR(32) PRIMARY KEY,
    pinfl                CHAR(14) NOT NULL UNIQUE,
    load_date            TIMESTAMP NOT NULL,
    record_source        VARCHAR(30) NOT NULL
);

CREATE TABLE hub_source_customer (
    source_customer_hk   CHAR(32) PRIMARY KEY,
    source_system        VARCHAR(20) NOT NULL,
    source_customer_id   VARCHAR(50) NOT NULL,
    load_date            TIMESTAMP NOT NULL,
    record_source        VARCHAR(30) NOT NULL,
    UNIQUE (source_system, source_customer_id)
);

CREATE TABLE lnk_customer_source (
    link_hk              CHAR(32) PRIMARY KEY,
    customer_hk          CHAR(32) NOT NULL REFERENCES hub_customer (customer_hk),
    source_customer_hk   CHAR(32) NOT NULL REFERENCES hub_source_customer (source_customer_hk),
    load_date            TIMESTAMP NOT NULL,
    record_source        VARCHAR(30) NOT NULL,
    UNIQUE (customer_hk, source_customer_hk)
);

CREATE TABLE sat_abs_customer (
    source_customer_hk   CHAR(32) NOT NULL REFERENCES hub_source_customer (source_customer_hk),
    load_date            TIMESTAMP NOT NULL,
    record_source        VARCHAR(30) NOT NULL,
    hash_diff            CHAR(32) NOT NULL,
    full_name            VARCHAR(200),
    branch_of_record     VARCHAR(100),
    address              VARCHAR(300),
    first_account_date   DATE,
    customer_status      VARCHAR(20),
    PRIMARY KEY (source_customer_hk, load_date)
);

CREATE TABLE sat_card_customer (
    source_customer_hk   CHAR(32) NOT NULL REFERENCES hub_source_customer (source_customer_hk),
    load_date            TIMESTAMP NOT NULL,
    record_source        VARCHAR(30) NOT NULL,
    hash_diff            CHAR(32) NOT NULL,
    pan_token            VARCHAR(40),
    address              VARCHAR(300),
    phone                VARCHAR(20),
    card_holder_status   VARCHAR(20),
    PRIMARY KEY (source_customer_hk, load_date)
);

CREATE TABLE sat_app_customer (
    source_customer_hk   CHAR(32) NOT NULL REFERENCES hub_source_customer (source_customer_hk),
    load_date            TIMESTAMP NOT NULL,
    record_source        VARCHAR(30) NOT NULL,
    hash_diff            CHAR(32) NOT NULL,
    phone                VARCHAR(20),
    device_id            VARCHAR(60),
    registration_date    DATE,
    app_status           VARCHAR(20),
    PRIMARY KEY (source_customer_hk, load_date)
);

CREATE TABLE sat_crm_customer (
    source_customer_hk   CHAR(32) NOT NULL REFERENCES hub_source_customer (source_customer_hk),
    load_date            TIMESTAMP NOT NULL,
    record_source        VARCHAR(30) NOT NULL,
    hash_diff            CHAR(32) NOT NULL,
    full_name            VARCHAR(200),
    address              VARCHAR(300),
    segment              VARCHAR(20),
    relationship_manager VARCHAR(100),
    marketing_consent    CHAR(1),
    crm_status           VARCHAR(20),
    PRIMARY KEY (source_customer_hk, load_date)
);

CREATE TABLE sat_kyc_customer (
    customer_hk          CHAR(32) NOT NULL REFERENCES hub_customer (customer_hk),
    load_date            TIMESTAMP NOT NULL,
    record_source        VARCHAR(30) NOT NULL,
    hash_diff            CHAR(32) NOT NULL,
    passport_number      VARCHAR(20),
    full_name            VARCHAR(200),
    birth_date           DATE,
    risk_rating          VARCHAR(10),
    sanctions_status     VARCHAR(20),
    document_expiry_date DATE,
    PRIMARY KEY (customer_hk, load_date)
);


-- 4.2 Load rule for sat_card_customer: insert a row only if hash_diff changed
INSERT INTO sat_card_customer
    (source_customer_hk, load_date, record_source, hash_diff,
     pan_token, address, phone, card_holder_status)
SELECT s.source_customer_hk,
       CURRENT_TIMESTAMP,
       'CARD',
       s.hash_diff,
       s.pan_token,
       s.address,
       s.phone,
       s.card_holder_status
FROM stg_card_customer s
LEFT JOIN (
    SELECT source_customer_hk,
           hash_diff,
           ROW_NUMBER() OVER (PARTITION BY source_customer_hk
                              ORDER BY load_date DESC) AS rn
    FROM sat_card_customer
) cur ON cur.source_customer_hk = s.source_customer_hk
     AND cur.rn = 1
WHERE cur.source_customer_hk IS NULL
   OR cur.hash_diff <> s.hash_diff;


WITH abs_cur AS (
    SELECT source_customer_hk, address, load_date,
           'ABS' AS source_name, 1 AS prec
    FROM (SELECT s.*,
                 ROW_NUMBER() OVER (PARTITION BY source_customer_hk
                                    ORDER BY load_date DESC) AS rn
          FROM sat_abs_customer s) x
    WHERE rn = 1 AND address IS NOT NULL
),
crm_cur AS (
    SELECT source_customer_hk, address, load_date,
           'CRM' AS source_name, 2 AS prec
    FROM (SELECT s.*,
                 ROW_NUMBER() OVER (PARTITION BY source_customer_hk
                                    ORDER BY load_date DESC) AS rn
          FROM sat_crm_customer s) x
    WHERE rn = 1 AND address IS NOT NULL
),
card_cur AS (
    SELECT source_customer_hk, address, load_date,
           'CARD' AS source_name, 3 AS prec
    FROM (SELECT s.*,
                 ROW_NUMBER() OVER (PARTITION BY source_customer_hk
                                    ORDER BY load_date DESC) AS rn
          FROM sat_card_customer s) x
    WHERE rn = 1 AND address IS NOT NULL
),
all_cur AS (
    SELECT * FROM abs_cur
    UNION ALL SELECT * FROM crm_cur
    UNION ALL SELECT * FROM card_cur
),
ranked AS (
    SELECT l.customer_hk,
           a.address,
           a.source_name,
           a.load_date,
           ROW_NUMBER() OVER (PARTITION BY l.customer_hk
                              ORDER BY a.load_date DESC, a.prec ASC) AS rn
    FROM all_cur a
    JOIN lnk_customer_source l
      ON l.source_customer_hk = a.source_customer_hk
)
SELECT customer_hk,
       address,
       source_name AS address_source,
       load_date   AS address_loaded_at
FROM ranked
WHERE rn = 1;


-- 4.4 CRM segment of customer C-2290 as loaded by 2026-02-10
SELECT h.source_customer_id AS crm_id,
       s.segment,
       s.load_date,
       s.record_source,
       s.hash_diff
FROM hub_source_customer h
JOIN sat_crm_customer s
  ON s.source_customer_hk = h.source_customer_hk
WHERE h.source_system      = 'CRM'
  AND h.source_customer_id = 'C-2290'
  AND s.load_date < TIMESTAMP '2026-02-11 00:00:00'
ORDER BY s.load_date DESC
LIMIT 1;


-- 4.5 New source: only one new satellite is needed
CREATE TABLE sat_ins_customer (
    source_customer_hk   CHAR(32) NOT NULL REFERENCES hub_source_customer (source_customer_hk),
    load_date            TIMESTAMP NOT NULL,
    record_source        VARCHAR(30) NOT NULL,
    hash_diff            CHAR(32) NOT NULL,
    full_name            VARCHAR(200),
    phone                VARCHAR(20),
    policy_status        VARCHAR(20),
    PRIMARY KEY (source_customer_hk, load_date)
);
