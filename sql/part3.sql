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
