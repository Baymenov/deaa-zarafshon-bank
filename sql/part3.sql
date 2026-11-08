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
