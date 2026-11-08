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
