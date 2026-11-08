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
