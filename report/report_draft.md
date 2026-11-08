Part 1. Dimensional model for transactions and balances

1.1 Why Questions 1 and 2 need different fact tables

Question 1 (daily net inflow of deposits by region and segment) asks about
flows: how much money moved in or out during a period. Flows are events, so
the right design is a transaction fact table, where each row is one posted
money movement. Its amounts can be summed over any dimension, including time.

Question 2 (average monthly balance per customer and per branch) asks about
a state: how much money sat on the account on each day. A balance is not an
event. It exists on days when nothing happened, and a transaction table has
no rows for those days. Rebuilding balances from transactions would mean
replaying the whole history from the opening balance for every account,
which is slow and breaks when a correction arrives. A periodic snapshot fact
table solves this: one row per account per day, storing the closing balance.

Question 1 needs a transaction fact table. Question 2 needs a periodic
snapshot fact table.

Alternative considered: one combined table holding both transactions and
balances. Rejected, because the two have different grains. Mixing them
would repeat balances on every transaction row and make sums wrong.

1.2 Grain, dimensions and facts

fact_transaction
Grain: one row per posting to one account, that is, one debit or credit
leg of a transaction (identified by transaction_id and account_key).

Dimensions:
- dim_date (posting date)
- dim_account
- dim_customer (Type 2, surrogate key)
- dim_branch (carries region)
- dim_transaction_type (deposit, withdrawal, transfer in, transfer out, fee)
- dim_currency
- dim_channel (branch, ATM, mobile app, card)

Degenerate dimension: transaction_id (stored in the fact table, no
separate dimension table).

Facts:
| Fact | Meaning | Type |
| amount_signed_uzs | Signed amount in UZS, plus for credit, minus for debit | additive |
| fee_amount_uzs | Fee charged on the transaction | additive |
| transaction_count | Constant 1 per row, used for counting | additive |
| exchange_rate | Rate used to convert to UZS | non-additive |

fact_daily_balance
Grain: one row per account per calendar day, holding the end-of-day balance.

Dimensions:
- dim_date
- dim_account
- dim_customer (Type 2, surrogate key)
- dim_branch
- dim_product (current account, savings, deposit, loan)
- dim_currency

Facts:
| Fact | Meaning | Type |
| closing_balance_uzs | End-of-day balance in UZS | semi-additive |
| available_balance_uzs | Balance minus holds and limits | semi-additive |
| interest_rate | Interest rate on the account that day | non-additive |

Assumptions: all amounts are stored in UZS together with the original
currency; region is taken from dim_branch; balances are as of end of day,
as delivered by the core banking file.


1.3 Transfer between two accounts

Decision: a transfer from account A to account B is stored as two rows in
fact_transaction, one for each account. This follows from the grain chosen
in 1.2 (one posting to one account). The core banking file has one record,
and the load splits it into a debit row for A (transaction type "transfer
out", negative amount) and a credit row for B (transaction type
"transfer in", positive amount). Both rows keep the same transaction_id,
so the two legs can be linked back to the original transfer.

Example (posting date 2026-03-12, amounts in UZS):

| transaction_id | account | region     | type           | amount_signed_uzs |
| T1             | A       | Tashkent   | cash deposit   |  +500,000         |
| T2             | A       | Tashkent   | transfer out   |  -200,000         |
| T2             | B       | Samarkand  | transfer in    |  +200,000         |
| T3             | B       | Samarkand  | withdrawal     |   -50,000         |

Results by region:

| region    | total deposits in (credits) | net inflow |
| Tashkent  | 500,000                     | +300,000   |
| Samarkand | 200,000                     | +150,000   |
| Bank total| 700,000                     | +450,000   |

Check: the only money that really entered or left the bank is the cash
deposit (+500,000) and the withdrawal (-50,000), which gives +450,000. The
transfer moved 200,000 from Tashkent to Samarkand and cancels out in the
bank total, so the net inflow of 450,000 is correct. Each region also shows
its own correct figure, because each leg sits in the region of its own
account.

Alternative considered: one row per transfer with two account keys
(source_account_key and destination_account_key). Rejected for three
reasons. First, a query by region must decide which of the two accounts
defines the region, and the other side is lost or must be added with a
UNION. Second, the fact table would need two keys for every dimension
linked to the account (branch, customer, segment). Third, the sign of the
amount would depend on which side the analyst looks from, which makes
summing error-prone.

Assumptions: fact_transaction holds postings on deposit accounts, and
"total deposits in" is the sum of positive postings, including transfers in.

Queries:

SELECT b.region,
       SUM(CASE WHEN f.amount_signed_uzs > 0
                THEN f.amount_signed_uzs ELSE 0 END) AS total_deposits_in,
       SUM(f.amount_signed_uzs) AS net_inflow
FROM fact_transaction f
JOIN dim_branch b ON f.branch_key = b.branch_key
JOIN dim_date d ON f.date_key = d.date_key
WHERE d.full_date = DATE '2026-03-12'
GROUP BY b.region;


1.4 Average monthly balance per customer

Query (last 24 full months, per customer and month):

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

The query works in two steps. The inner query adds up all accounts of the
customer for each day (SUM across accounts). The outer query averages these
daily totals over the days of the month (AVG across time). The result for
branches is built the same way: join dim_branch instead of dim_customer and
group by branch.

Why AVG is right and SUM is wrong:
closing_balance_uzs is a semi-additive fact (see 1.2). It can be added
across accounts on one day, but not across days. A balance is the amount of
money on one date, so adding the balances of 30 days counts the same money
30 times. Example: an account holds 1,000,000 UZS for all 30 days of
April. SUM over days gives 30,000,000, which is not a balance and would
change with the number of days in the month (31 days would give 31,000,000
for the same account). AVG gives 1,000,000, which is the correct average
balance.

A common mistake is to write AVG(closing_balance_uzs) directly with
GROUP BY customer. This averages account-days and not customer-days. A
customer with two accounts of 1,000,000 and 3,000,000 would get 2,000,000
instead of the correct 4,000,000. This is why the daily SUM across accounts
comes first.

Assumptions: fact_daily_balance has a row for every open account on every
day, so days without transactions are included; the date dimension has a
year_month column; the customer is identified by client_no, because a
Type 2 customer has several surrogate keys over time; for an account opened
during the month, the average is taken over the days it existed.


1.5 Size of fact_daily_balance and how to keep it affordable

Estimate:
The case does not say how many accounts a customer has. I assume 2 accounts
per customer on average (for example one card or current account and one
savings or deposit account).

Accounts: 1,800,000 customers x 2 = 3,600,000 accounts
Rows: 3,600,000 accounts x 730 days = 2,628,000,000 rows

If every customer had only one account, the figure would be
1,800,000 x 730 = 1,314,000,000 rows. So the table holds between 1.3 and
2.6 billion rows. At about 40 bytes per row before compression (date key,
account key, customer key, branch key, product key, two balances, rate),
2.6 billion rows are about 105 GB, and about 21 GB in Parquet at 5x
compression. This is storable, but every Question 2 query would scan
billions of rows, and the table grows by 3.6 million rows every day.

Proposal: add a monthly snapshot table, fact_monthly_balance.
Grain: one row per account per calendar month.
Columns: month_key, account_key, customer_key, branch_key, product_key,
balance_day_sum_uzs, days_open, closing_balance_uzs.

balance_day_sum_uzs is the sum of the daily closing balances of the account
during the month. It is built once a month from fact_daily_balance:

INSERT INTO fact_monthly_balance
SELECT d.year_month_key,
       f.account_key,
       f.customer_key,
       f.branch_key,
       f.product_key,
       SUM(f.closing_balance_uzs) AS balance_day_sum_uzs,
       COUNT(*)                   AS days_open,
       MAX(CASE WHEN d.is_month_end = 1
                THEN f.closing_balance_uzs END) AS closing_balance_uzs
FROM fact_daily_balance f
JOIN dim_date d ON f.date_key = d.date_key
WHERE d.year_month_key = 202610
GROUP BY d.year_month_key, f.account_key, f.customer_key,
         f.branch_key, f.product_key;

Question 2 is then answered from the monthly table:

SELECT c.client_no,
       m.month_key,
       SUM(m.balance_day_sum_uzs) / dm.days_in_month AS avg_monthly_balance_uzs
FROM fact_monthly_balance m
JOIN dim_customer c ON m.customer_key = c.customer_key
JOIN dim_month dm ON m.month_key = dm.month_key
GROUP BY c.client_no, m.month_key, dm.days_in_month;

Size: 3,600,000 accounts x 24 months = 86,400,000 rows, about 30 times
smaller than the daily table.

Why Question 2 is still answered correctly: the monthly table stores the
sum of daily balances and not the average. Sums can be added across
accounts, and dividing by the number of days in the month at the end gives
the exact average. Storing a ready average per account would be wrong,
because averages of different accounts cannot be combined correctly when
an account was opened in the middle of the month.

Retention: keep the daily table only for the last 90 days (for daily
checks and corrections) and the monthly table for the full 24 months.
Daily data older than 90 days is archived in cheap storage.

Alternatives considered:
1. Store a row only when the balance changes (sparse snapshot). Rows drop
   sharply because most accounts change rarely. Rejected: every query
   must first expand the rows into days, and a missing row is ambiguous
   (no change, or missing data).
2. Keep the full daily table and rely on partitioning by month and
   columnar compression. Not rejected as a base, but it does not reduce
   the number of rows a Question 2 query has to read, so it is used
   together with the monthly table and not instead of it.


Part 2. Customer history and slowly changing dimensions

2.1 SCD type for each attribute

Question 5 asks for the full history of branch, segment and risk rating,
with the source and date of every value. This decides the first three
rows. For the other attributes the choice depends on whether anyone needs
the old value.

| Attribute                | Source       | Changes how often          | SCD type | Reason |
| Branch of record         | Core banking | A few % of customers a year | Type 2  | Q5 requires the branch history, and changes are rare, so few extra rows. |
| Segment                  | CRM          | Reviewed quarterly         | Type 2   | Q5 requires the segment history, and reports by segment must use the segment valid on the transaction date. |
| Risk rating              | KYC          | On any trigger event       | Type 2   | Q5 requires the history, and the Central Bank audit needs the rating that was valid at the time of each transaction. |
| Phone number             | Mobile app   | Often                      | Type 1   | No question needs old phone numbers, and Type 2 would create many rows for no benefit. The old value stays in the vault satellite (Part 4). |
| Date of first account    | Core banking | Never                      | Type 0   | The value is fixed, so it is never overwritten. A change in the source is a data error and is reported. |
| Relationship manager     | CRM          | When staff change          | Type 1   | No question asks for manager history. One manager leaving would otherwise create a new row for hundreds of customers. |

Alternatives considered:
- Phone number as Type 2: rejected, because frequent changes would multiply
  the rows of dim_customer, and every new row would also copy the Type 2
  attributes of the customer.
- Relationship manager as Type 2: rejected for the reason above. If
  management later asks for results by the manager at the time, the manager
  is moved into its own dimension (dim_relationship_manager) linked through
  a separate table, so that staff changes do not touch dim_customer.
- Phone number as Type 3 (a column for the previous value): rejected,
  because it keeps only one old value and answers no stated question.

Note: branch, segment and risk rating are all Type 2 in the same table.
A change in any of them closes the current row and creates a new one, so
one row of dim_customer describes the customer as she was during one period.


2.2 Rows of dim_customer for customer 4471

Assumptions:
- Before 2026-04-02 the risk rating of customer 4471 was high. The case
  does not give the old value, but Question 2.3 asks about the period when
  she was rated high, so this is the only reading that makes 2.3 meaningful.
- The first row starts on 2020-01-01 (the date the customer first appears
  in the warehouse). The exact date is not given in the case.
- valid_to is inclusive: it is the day before the next row starts.
  The current row has valid_to = 9999-12-31.
- Surrogate keys are generated by the warehouse (1001, 1002, 1003 here).

| customer_key | client_no | branch_name | segment  | risk_rating | valid_from | valid_to   | is_current |
| 1001         | 4471      | Chilonzor   | mass     | high        | 2020-01-01 | 2026-03-11 | N          |
| 1002         | 4471      | Yunusobod   | affluent | high        | 2026-03-12 | 2026-04-01 | N          |
| 1003         | 4471      | Yunusobod   | affluent | medium      | 2026-04-02 | 9999-12-31 | Y          |

Why there are three rows and not four: the branch and the segment changed
on the same day (2026-03-12), so they share one new row (key 1002). The
risk rating changed on a different day (2026-04-02), so it creates another
row (key 1003). A change in any Type 2 attribute closes the current row and
opens a new one; all Type 2 attributes are copied into the new row.

Answer: on 2026-04-05 the table contains 3 rows for customer 4471, but
only one of them is valid on that date: key 1003 (the only row where
valid_from <= 2026-04-05 <= valid_to). A fact loaded on 2026-04-05 must
therefore use customer_key 1003.

Alternative considered: separate rows per attribute change, or a separate
history table for each attribute. Rejected, because a report by segment and
branch would have to join several history tables by date, and the
"as it was at the time" picture of one customer would be spread over
several tables. One row per customer version keeps this in a single join.


2.3 Transactions made while customer 4471 was rated high risk

Query (fact_transaction carries the customer surrogate key):

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

For customer 4471 in 2.2, the rows with risk_rating = 'high' are keys 1001
and 1002, so the query returns all her transactions from the start of
history up to and including 2026-04-01. Transactions from 2026-04-02 are
not returned, because they carry key 1003 (medium).

Why this is easy with the surrogate key: when a transaction is loaded, the
pipeline finds the version of the customer that is valid on the
transaction date and stores its customer_key in the fact row. The question
"what was her rating at that time" is therefore already answered when the
row is written. The query only needs a plain join on the key and a filter
on the rating. No date comparison is needed, and each fact row matches
exactly one dimension row, so no transaction is duplicated or lost.

If fact_transaction carried only client_no:

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

The join must now compare the transaction date with the validity period of
every version of the customer. This has three problems. It is slower,
because a range join on 9 million rows a day cannot use a simple key
lookup. It depends on the Type 2 rows having no gaps and no overlaps (see
the test in 5.3); if two versions overlap, a transaction is counted twice,
and if there is a gap, it disappears from the result. And every report that
needs history, not only this one, must repeat the same date condition, so
one analyst forgetting it gives a wrong answer silently.

Alternative considered: store both client_no and customer_key in the fact
table. Accepted as a small addition: customer_key is used for history,
client_no is kept as a degenerate attribute for fast lookup of all
transactions of one customer across all versions.


2.4 Late-arriving segment change from the CRM

Example: customer 5520 (a different customer, to keep 2.2 unchanged) was
"mass" and became "affluent" on 2026-03-12. The CRM export with this
change arrives on 2026-03-14, two days late.

State before the late file arrives (valid_from of the first row is
assumed):

| customer_key | client_no | segment  | valid_from | valid_to   | is_current |
| 2001         | 5520      | mass     | 2024-06-01 | 9999-12-31 | Y          |

What the load must do when the file arrives on 2026-03-14:

1. Read the effective date of the change from the CRM record (the date the
   segment really changed, 2026-03-12), not the date the file was loaded
   (2026-03-14).
2. Compare the new segment with the current row. They differ, so this is a
   change.
3. Close the current row on the day before the effective date and insert
   the new row from the effective date:

| customer_key | client_no | segment  | valid_from | valid_to   | is_current |
| 2001         | 5520      | mass     | 2024-06-01 | 2026-03-11 | N          |
| 2002         | 5520      | affluent | 2026-03-12 | 9999-12-31 | Y          |

4. Fix the facts that were already loaded. Transactions of 2026-03-12 and
   2026-03-13 were loaded earlier with customer_key 2001 (mass), because
   the change was not known yet. They must now point to key 2002.
   Transactions of 2026-03-14 are not a problem if the dimension is loaded
   before the facts in the same run, so they get key 2002 directly.
5. Rebuild the aggregates that depend on the segment (for example, daily
   net inflow by segment) for the dates from 2026-03-12 onward, and write
   a line to a correction log (client_no, old key, new key, number of rows
   changed, load timestamp).

SQL for steps 3 and 4:

UPDATE dim_customer
SET valid_to = DATE '2026-03-11',
    is_current = 'N'
WHERE client_no = 5520
  AND is_current = 'Y';

INSERT INTO dim_customer
    (customer_key, client_no, segment, valid_from, valid_to, is_current)
VALUES
    (2002, 5520, 'affluent', DATE '2026-03-12', DATE '9999-12-31', 'Y');

UPDATE fact_transaction f
SET customer_key = c.customer_key
FROM dim_date d, dim_customer c
WHERE f.date_key = d.date_key
  AND c.client_no = f.client_no
  AND d.full_date BETWEEN c.valid_from AND c.valid_to
  AND f.client_no = 5520
  AND d.full_date >= DATE '2026-03-12'
  AND f.customer_key <> c.customer_key;

Pipeline rule:
(1) Within one run, dimensions are loaded before facts.
(2) The validity dates of a Type 2 row come from the effective date in the
source, never from the load date.
(3) If a change arrives with an effective date earlier than the start of
the current row, the dimension row is split so that periods stay without
gaps and without overlaps.
(4) After every dimension load, fact rows whose customer_key is not the
version valid on their date are re-keyed, and the affected aggregates are
rebuilt.
(5) Every correction is written to a log, so that a figure reported at
08:00 and changed later can be explained.

Assumption: the CRM export contains the date of the change. If it does
not, the effective date cannot be known, and the load date would have to be
used. This would give wrong history, so the field must be requested from
the CRM team.

Alternatives considered:
- Leave the old facts unchanged and apply the new segment only from the
  load date. Rejected: transactions of 2026-03-12 and 2026-03-13 would be
  reported under the wrong segment forever, and Question 1 (net inflow by
  segment) would be wrong for those days.
- Wait for the CRM file before loading the nightly facts. Rejected: one
  late file would block all reports, and the 08:00 deadline of Question 1
  would be missed for everyone.


Part 3. Loan lifecycle

3.1 Design of fact_loan_application (accumulating snapshot)

Why an accumulating snapshot: an application moves through a fixed
sequence of stages and we want to measure the time between them. One row
describes the whole life of one application, and the row is updated when
the application reaches the next stage. This makes the question "how many
days from submission to disbursement, and where does it stall" a simple
subtraction inside one row.

Grain: one row per loan application, from submission until it is
disbursed, rejected or withdrawn.

Date keys (one per milestone, all pointing to the same dim_date table, so
dim_date is used as a role-playing dimension):

| Column                        | Milestone |
| submitted_date_key            | Application submitted |
| docs_verified_date_key        | Documents verified |
| credit_scored_date_key        | Credit scored |
| decision_date_key             | Approved or rejected |
| contract_signed_date_key      | Contract signed |
| disbursed_date_key            | Loan disbursed |
| withdrawn_date_key            | Application withdrawn (if it happened) |

A milestone that has not happened yet points to a special row of dim_date
with key -1 and the label "Not reached". We do not leave the key empty
(NULL), because a NULL foreign key drops the row from an inner join. The
exact timestamps of each milestone are also stored (for example
submitted_at), so that lags shorter than one day can be calculated later.

Lag measures (precomputed at load time, in days, NULL until both
milestones have happened):

| Column                          | Calculation |
| days_submit_to_docs             | docs_verified - submitted |
| days_docs_to_score              | credit_scored - docs_verified |
| days_score_to_decision          | decision - credit_scored |
| days_decision_to_contract       | contract_signed - decision |
| days_contract_to_disbursement   | disbursed - contract_signed |
| days_submit_to_disbursement     | disbursed - submitted (total time, Question 4) |
| days_in_current_stage           | today - date of the last milestone reached (open applications only) |

Other facts:

| Column                | Meaning | Type |
| application_count     | Constant 1 | additive |
| requested_amount_uzs  | Amount the customer asked for | additive |
| approved_amount_uzs   | Amount approved | additive |
| disbursed_amount_uzs  | Amount paid out | additive |
| interest_rate         | Approved annual rate | non-additive |
| term_months           | Approved term | non-additive |

The lag columns are days, so they can be added, but the sum is almost never
useful. They are used with AVG, median and MAX.

Dimensions:
- dim_date (role-playing, 7 times, see above)
- dim_branch
- dim_loan_product
- dim_customer (Type 2 surrogate key, the version valid at submission)
- dim_employee (role-playing: verifier, scorer, decision maker, contract
  officer, disbursing officer; one key column per step, because core
  banking records the responsible employee at each step)
- dim_application_status (current stage and final outcome: in progress,
  approved, rejected, withdrawn, disbursed)

Degenerate dimension: application_number.
The stage at which a withdrawal happened is stored in the column
withdrawn_at_stage.

Where applications stall: for open applications, days_in_current_stage
together with the current stage shows where they wait now. For finished
applications, the average and the 90th percentile of each lag column show
which step is the slowest, by branch and product.

Alternatives considered:
- A transaction-style fact table with one row per stage event (a row for
  each of the six steps). Rejected: to get the time between two stages,
  every query must join the table to itself or use window functions, and
  the grain is not one application any more, so counts of applications are
  easy to get wrong.
- A periodic snapshot with one row per application per day. Rejected for
  Question 4: it creates millions of rows that repeat the same stage, and
  the lag still has to be found by scanning the days. A periodic snapshot
  is added later in 3.3 for a different question.

Assumptions: the six stage names of the case are the only milestones;
stages happen in this order; one application has at most one disbursement.


3.2 Nightly load of fact_loan_application

Assumptions: the case gives only the total of 2 million rows. I assume that
about 5,000 applications are submitted per day and that about 50,000
applications are open at any moment. The core banking file arrives at 01:00
and contains, for every application that had a new step the day before, the
timestamp and the employee of each step known so far.

Why not update all rows: an application that is disbursed, rejected or
withdrawn is finished and does not change any more. Only open applications
can change. Therefore the table has a column is_open ('Y' while the
application is in progress, 'N' when it is finished), and the load touches
only a small part of the table.

Steps of the load:

1. Load the file into a staging table, one row per application, with the
   timestamps of all steps reached so far.
2. Calculate in staging the date keys, the lag columns and the is_open
   flag, so that the final step only copies values.
3. Detect the changes. Join staging to the fact table on application_number
   (a unique index exists on it). Applications not found in the fact table
   are new and are inserted. Applications found are updated only if at
   least one value in staging is different from the fact table. If the
   file is loaded twice, the second run changes nothing, because nothing is
   different.
4. Update only the columns that can change: the timestamp, date key and
   responsible employee of the step that was reached; the status; the
   approved amount, rate and term (set at the decision); the disbursed
   amount; the lag columns of the finished steps; is_open.
   These columns are never updated: application_key, application_number,
   submitted_date_key, customer_key (the version valid at submission) and
   branch and product.
5. Update days_in_current_stage for all open applications, because this
   number grows every day even if there is no new step. This touches about
   50,000 rows and not 2 million.

A correction of an old, closed application (for example a wrong date) also
arrives in the file, so step 3 finds it by application_number and updates
it. No scan of the closed rows is needed to find it.


3.3 Applications per stage at the end of every month

Why the accumulating snapshot alone answers this badly:
The table keeps one row per application, and the row is updated as the
application moves on. It shows where each application is now, not where it
was at the end of last August. The old stage is not stored as a value. It
can be rebuilt from the milestone timestamps (the stage at a date is the
last milestone reached before that date), but this is a poor way to answer
a routine question:
1. Every month-end needs a CASE over six timestamp columns, a date spine
   for 24 month-ends, and a scan of all 2 million rows, repeated for every
   report.
2. Rejected and withdrawn applications must be handled by extra conditions,
   and the current status does not say when they left the process.
3. When a correction changes an old timestamp, past months change silently,
   and nobody can reproduce the figure that was reported at the time.

Second table: fact_loan_stage_month_end, a periodic snapshot.
Grain: one row per application that is still open at the end of a calendar
month. The row says at which stage the application was at that moment.
Dimensions: dim_date (month-end date), dim_branch, dim_loan_product,
dim_loan_stage, dim_customer. Facts: application_count (additive, 1 per
row), requested_amount_uzs (additive across applications, not across
months), days_in_stage (non-additive).

Size: about 50,000 open applications x 24 months = 1.2 million rows, small
compared with the 2 million rows of the accumulating snapshot, and each
month adds only about 50,000.

The table is filled once a month, right after the nightly load of the first
day of the month, from fact_loan_application. Rows of past months are not
changed afterwards, so the trend chart always shows what was true at the
time. If a serious error is found, the month is rebuilt and the rebuild is
written to the correction log.

Trend query:

SELECT d.year_month,
       s.stage_name,
       SUM(m.application_count) AS applications
FROM fact_loan_stage_month_end m
JOIN dim_date d       ON m.month_end_date_key = d.date_key
JOIN dim_loan_stage s ON m.stage_key = s.stage_key
GROUP BY d.year_month, s.stage_name
ORDER BY d.year_month, s.stage_name;

Assumptions: "in each stage" means the open stages (submitted, documents
verified, credit scored, approved, contract signed). Applications that were
disbursed, rejected or withdrawn are no longer in a stage; their counts per
month come from the accumulating snapshot using the disbursed, decision and
withdrawn dates.

Alternatives considered:
- Rebuild the stage from the accumulating snapshot at query time. Rejected
  for the three reasons above.
- A daily periodic snapshot of every open application. Rejected: 50,000 x
  730 = 36.5 million rows for a question that asks about month-ends.
- A snapshot with only counts per month, branch, product and stage.
  Smaller, but it cannot show which applications were stuck. It can be
  built as a view on top of the application-level snapshot when needed.


3.4 Median days from approval to disbursement, and a nightly test

Assumptions: "Q3 2026" means applications disbursed between 2026-07-01 and
2026-09-30 (the quarter is taken by disbursement date, because only then
the number of days is known). Only disbursed applications are included.
A disbursed application was approved, so the filter on approval is
implicit.

Query:

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

dim_date is joined twice (role-playing dimension, see 3.1): da gives the
approval date and dd the disbursement date. The syntax of
PERCENTILE_CONT is PostgreSQL and Oracle; in SQL Server it needs an OVER
clause, so the query would be written with a window function there.

Why the median and not the average: waiting times are skewed. Most
applications are disbursed in a few days, but a few wait for months
(missing documents, customer delays). A few such cases pull the average up
and the branch looks slow, while a typical customer is served quickly.
The median shows the typical case. The count is shown next to it, because
a median over 3 applications in a small branch is not reliable.

Alternative considered: add the two stored lags
(days_decision_to_contract + days_contract_to_disbursement). Rejected: the
sum is NULL if either lag is missing, and the dates are the original
data, so the dates are used. A column days_decision_to_disbursement could
be added to the table if the question is asked often.

Nightly data-quality test: milestone dates must be complete and in order.

SELECT f.application_number
FROM fact_loan_application f
JOIN dim_date ds ON f.submitted_date_key       = ds.date_key
JOIN dim_date da ON f.decision_date_key        = da.date_key
JOIN dim_date dd ON f.disbursed_date_key       = dd.date_key
WHERE f.disbursed_date_key <> -1
  AND (   f.decision_date_key = -1
       OR da.full_date < ds.full_date
       OR dd.full_date < da.full_date);

The test returns every disbursed application that has no approval date, or
whose approval is before submission, or whose disbursement is before
approval. The expected result is zero rows. Such rows would give negative
or missing days and would damage the median above.

When the test fails: the rows are copied to a table dq_issue with the
application number, the rule name and the load date. The load of the other
applications continues. The lag columns of the failed rows are set to NULL,
so that they do not enter the medians. If more than 0.1% of the rows fail,
the pipeline stops before publishing, and the data owner of core banking
is notified.


Part 4. Integration layer: data vault for four customer sources

4.1 Raw vault for the customer

Assumptions: every retail customer has a PINFL. Business customers
(40,000) have a tax ID instead and would follow the same pattern in a
separate hub; they are not shown to keep the report short. The KYC export
contains the PINFL together with the four source identifiers of the
customer (this is how "only KYC links them all" is read). Accounts and
transactions would be added with hub_account and a customer-account link
in the same way and are left out here.

Business key of hub_customer: the PINFL.
Reasons: (1) it is the only identifier that exists in every source once
KYC has linked them; (2) it is issued by the state to one person and does
not change when a passport is replaced; (3) the Central Bank already
audits KYC data by PINFL. Rejected: client_no (exists only in core
banking), crm_id (staff can create duplicates), passport number (changes
on renewal and some customers have no Uzbek passport).

Hubs (they store only business keys):

| Table               | Columns |
| hub_customer        | customer_hk, pinfl, load_date, record_source |
| hub_source_customer | source_customer_hk, source_system, source_customer_id, load_date, record_source |

hub_source_customer holds the identifiers of the four systems:
client_no, card_holder_id, app_user_id and crm_id. Its business key is the
pair source_system + source_customer_id. The hash keys (customer_hk,
source_customer_hk) are MD5 hashes of the business key.

Link (it stores a relationship between hubs):

| Table                | Columns |
| lnk_customer_source  | link_hk, customer_hk, source_customer_hk, load_date, record_source |

One row says: this source identifier belongs to the customer with this
PINFL. It is loaded from the KYC mapping.

Satellites (they store descriptive attributes and their history, one per
source):

| Table             | Attached to         | Columns |
| sat_abs_customer  | hub_source_customer | source_customer_hk, load_date, record_source, hash_diff, full_name, branch_of_record, address, first_account_date, customer_status |
| sat_card_customer | hub_source_customer | source_customer_hk, load_date, record_source, hash_diff, pan_token, address, phone, card_holder_status |
| sat_app_customer  | hub_source_customer | source_customer_hk, load_date, record_source, hash_diff, phone, device_id, registration_date, app_status |
| sat_crm_customer  | hub_source_customer | source_customer_hk, load_date, record_source, hash_diff, full_name, address, segment, relationship_manager, marketing_consent, crm_status |
| sat_kyc_customer  | hub_customer        | customer_hk, load_date, record_source, hash_diff, passport_number, full_name, birth_date, risk_rating, sanctions_status, document_expiry_date |

Rules for all satellites: the primary key is the hash key plus load_date;
rows are only inserted, never updated or deleted; a new row is inserted
only when hash_diff (a hash of all descriptive columns) differs from the
latest row of the same key.

Why two hubs and not one: the card, app, CRM and core banking records
arrive with their own identifiers. If their satellites hung on
hub_customer, each record would have to be matched to a PINFL before it
could be loaded, so the raw load would wait for the KYC mapping, and a
wrong match would have to be repaired inside the history. With
hub_source_customer every source loads at its own time under its own key,
and the matching is only one link row. A corrected match is a new link row
(with an effectivity satellite on the link, not shown), and the history of
the source stays untouched.

Alternatives considered:
- One hub_customer with the satellites attached to it. Rejected for the
  reason above.
- No common hub, one separate hub per source. Rejected: nothing would
  integrate the four views of one person, and Question 5 needs them
  together.
- Business key client_no or crm_id for hub_customer. Rejected, see above.

Note: the PINFL is personal data, so hub_customer and all satellites are
stored in the restricted zone described in 5.4. Analysts work with
customer_hk, not with the PINFL.
