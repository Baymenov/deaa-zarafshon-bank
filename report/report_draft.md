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
