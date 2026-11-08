-- Part 3: loan lifecycle

-- 3.1 Accumulating snapshot, one row per loan application
CREATE TABLE fact_loan_application (
    application_key               BIGINT PRIMARY KEY,
    application_number            VARCHAR(20) NOT NULL UNIQUE,

    submitted_date_key            INT NOT NULL,
    docs_verified_date_key        INT NOT NULL DEFAULT -1,
    credit_scored_date_key        INT NOT NULL DEFAULT -1,
    decision_date_key             INT NOT NULL DEFAULT -1,
    contract_signed_date_key      INT NOT NULL DEFAULT -1,
    disbursed_date_key            INT NOT NULL DEFAULT -1,
    withdrawn_date_key            INT NOT NULL DEFAULT -1,

    submitted_at                  TIMESTAMP,
    docs_verified_at              TIMESTAMP,
    credit_scored_at              TIMESTAMP,
    decision_at                   TIMESTAMP,
    contract_signed_at            TIMESTAMP,
    disbursed_at                  TIMESTAMP,
    withdrawn_at                  TIMESTAMP,

    customer_key                  BIGINT NOT NULL,
    branch_key                    INT NOT NULL,
    loan_product_key              INT NOT NULL,
    status_key                    INT NOT NULL,
    verifier_employee_key         INT,
    scorer_employee_key           INT,
    decision_employee_key         INT,
    contract_employee_key         INT,
    disbursing_employee_key       INT,
    withdrawn_at_stage            VARCHAR(30),

    application_count             SMALLINT NOT NULL DEFAULT 1,
    requested_amount_uzs          NUMERIC(18,2),
    approved_amount_uzs           NUMERIC(18,2),
    disbursed_amount_uzs          NUMERIC(18,2),
    interest_rate                 NUMERIC(5,2),
    term_months                   SMALLINT,

    days_submit_to_docs           INT,
    days_docs_to_score            INT,
    days_score_to_decision        INT,
    days_decision_to_contract     INT,
    days_contract_to_disbursement INT,
    days_submit_to_disbursement   INT,
    days_in_current_stage         INT
);


-- 3.2 Extra columns needed for the nightly load
ALTER TABLE fact_loan_application
    ADD COLUMN is_open CHAR(1) NOT NULL DEFAULT 'Y';

CREATE INDEX ix_fact_loan_open
    ON fact_loan_application (is_open);

-- 3.2 Nightly load: insert new applications, update changed ones
MERGE INTO fact_loan_application f
USING stg_loan_application s
   ON f.application_number = s.application_number
WHEN MATCHED AND (
        f.docs_verified_at       IS DISTINCT FROM s.docs_verified_at
     OR f.credit_scored_at       IS DISTINCT FROM s.credit_scored_at
     OR f.decision_at            IS DISTINCT FROM s.decision_at
     OR f.contract_signed_at     IS DISTINCT FROM s.contract_signed_at
     OR f.disbursed_at           IS DISTINCT FROM s.disbursed_at
     OR f.withdrawn_at           IS DISTINCT FROM s.withdrawn_at
     OR f.status_key             <> s.status_key) THEN
    UPDATE SET
        docs_verified_at              = s.docs_verified_at,
        docs_verified_date_key        = s.docs_verified_date_key,
        verifier_employee_key         = s.verifier_employee_key,
        credit_scored_at              = s.credit_scored_at,
        credit_scored_date_key        = s.credit_scored_date_key,
        scorer_employee_key           = s.scorer_employee_key,
        decision_at                   = s.decision_at,
        decision_date_key             = s.decision_date_key,
        decision_employee_key         = s.decision_employee_key,
        contract_signed_at            = s.contract_signed_at,
        contract_signed_date_key      = s.contract_signed_date_key,
        contract_employee_key         = s.contract_employee_key,
        disbursed_at                  = s.disbursed_at,
        disbursed_date_key            = s.disbursed_date_key,
        disbursing_employee_key       = s.disbursing_employee_key,
        withdrawn_at                  = s.withdrawn_at,
        withdrawn_date_key            = s.withdrawn_date_key,
        withdrawn_at_stage            = s.withdrawn_at_stage,
        status_key                    = s.status_key,
        approved_amount_uzs           = s.approved_amount_uzs,
        disbursed_amount_uzs          = s.disbursed_amount_uzs,
        interest_rate                 = s.interest_rate,
        term_months                   = s.term_months,
        days_submit_to_docs           = s.days_submit_to_docs,
        days_docs_to_score            = s.days_docs_to_score,
        days_score_to_decision        = s.days_score_to_decision,
        days_decision_to_contract     = s.days_decision_to_contract,
        days_contract_to_disbursement = s.days_contract_to_disbursement,
        days_submit_to_disbursement   = s.days_submit_to_disbursement,
        is_open                       = s.is_open
WHEN NOT MATCHED THEN
    INSERT (application_key, application_number, submitted_date_key,
            submitted_at, customer_key, branch_key, loan_product_key,
            status_key, requested_amount_uzs, is_open)
    VALUES (s.application_key, s.application_number, s.submitted_date_key,
            s.submitted_at, s.customer_key, s.branch_key,
            s.loan_product_key, s.status_key, s.requested_amount_uzs,
            s.is_open);

-- 3.2 Daily refresh of the age in the current stage, open applications only
UPDATE fact_loan_application
SET days_in_current_stage =
        CURRENT_DATE - CAST(COALESCE(contract_signed_at, decision_at,
                                     credit_scored_at, docs_verified_at,
                                     submitted_at) AS DATE)
WHERE is_open = 'Y';


-- 3.3 Month-end snapshot of open applications by stage
CREATE TABLE fact_loan_stage_month_end (
    month_end_date_key   INT NOT NULL,
    application_key      BIGINT NOT NULL,
    branch_key           INT NOT NULL,
    loan_product_key     INT NOT NULL,
    customer_key         BIGINT NOT NULL,
    stage_key            INT NOT NULL,
    application_count    SMALLINT NOT NULL DEFAULT 1,
    requested_amount_uzs NUMERIC(18,2),
    days_in_stage        INT,
    PRIMARY KEY (month_end_date_key, application_key)
);

-- Monthly load for October 2026 (cutoff = first day of the next month)
INSERT INTO fact_loan_stage_month_end
    (month_end_date_key, application_key, branch_key, loan_product_key,
     customer_key, stage_key, application_count, requested_amount_uzs,
     days_in_stage)
SELECT 20261031,
       f.application_key,
       f.branch_key,
       f.loan_product_key,
       f.customer_key,
       ls.stage_key,
       1,
       f.requested_amount_uzs,
       DATE '2026-10-31' - CAST(
           COALESCE(f.contract_signed_at, f.decision_at, f.credit_scored_at,
                    f.docs_verified_at, f.submitted_at) AS DATE)
FROM fact_loan_application f
JOIN dim_application_status st ON f.status_key = st.status_key
JOIN dim_loan_stage ls
  ON ls.stage_name =
     CASE WHEN f.contract_signed_at < TIMESTAMP '2026-11-01 00:00:00' THEN 'contract_signed'
          WHEN f.decision_at        < TIMESTAMP '2026-11-01 00:00:00' THEN 'approved'
          WHEN f.credit_scored_at   < TIMESTAMP '2026-11-01 00:00:00' THEN 'credit_scored'
          WHEN f.docs_verified_at   < TIMESTAMP '2026-11-01 00:00:00' THEN 'docs_verified'
          ELSE 'submitted' END
WHERE f.submitted_at < TIMESTAMP '2026-11-01 00:00:00'
  AND (f.disbursed_at IS NULL OR f.disbursed_at >= TIMESTAMP '2026-11-01 00:00:00')
  AND (f.withdrawn_at IS NULL OR f.withdrawn_at >= TIMESTAMP '2026-11-01 00:00:00')
  AND NOT (st.final_outcome = 'rejected'
           AND f.decision_at < TIMESTAMP '2026-11-01 00:00:00');

-- 3.3 Trend of applications per stage at each month end
SELECT d.year_month,
       s.stage_name,
       SUM(m.application_count) AS applications
FROM fact_loan_stage_month_end m
JOIN dim_date d       ON m.month_end_date_key = d.date_key
JOIN dim_loan_stage s ON m.stage_key = s.stage_key
GROUP BY d.year_month, s.stage_name
ORDER BY d.year_month, s.stage_name;


-- 3.4 Median days from approval to disbursement by branch, Q3 2026
SELECT b.branch_name,
       COUNT(*) AS disbursed_applications,
       PERCENTILE_CONT(0.5) WITHIN GROUP
           (ORDER BY (dd.full_date - da.full_date)) AS median_days
FROM fact_loan_application f
JOIN dim_branch b ON f.branch_key = b.branch_key
JOIN dim_date da  ON f.decision_date_key = da.date_key
JOIN dim_date dd  ON f.disbursed_date_key = dd.date_key
WHERE f.decision_date_key  <> -1
  AND f.disbursed_date_key <> -1
  AND dd.full_date BETWEEN DATE '2026-07-01' AND DATE '2026-09-30'
GROUP BY b.branch_name
ORDER BY median_days DESC;

-- 3.4 Nightly test: disbursed applications must have ordered milestone dates
SELECT f.application_number
FROM fact_loan_application f
JOIN dim_date ds ON f.submitted_date_key       = ds.date_key
JOIN dim_date da ON f.decision_date_key        = da.date_key
JOIN dim_date dd ON f.disbursed_date_key       = dd.date_key
WHERE f.disbursed_date_key <> -1
  AND (   f.decision_date_key = -1
       OR da.full_date < ds.full_date
       OR dd.full_date < da.full_date);
