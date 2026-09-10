# ETL — miles2023 → Rotopa

Loads the legacy SQL Server backup into a Rotopa organization. Connects to the
target with a **direct Postgres connection** (superuser), so it bypasses RLS and
does not use the `create_organization()` auth flow.

## Setup

```bash
cd etl
cp .env.example .env      # fill in MSSQL_* and TARGET_DATABASE_URL
npm install
```

`TARGET_DATABASE_URL` must already have the migrations applied
(`supabase db push`, or the test runner for a local DB).

## Run

```bash
npm run etl                 # all steps, in order
npm run etl:currencies
npm run etl:accounts        # categories + accounts
npm run etl:rates
npm run etl:dealers
npm run verify              # row-count + tree-integrity check vs. the legacy DB
```

Every step is idempotent (`on conflict do update`) — safe to re-run.

## Steps & mapping

| step | source | target | notes |
|---|---|---|---|
| `currencies` | `Lockup_tb` (`Currancy`) | `currencies` | `BASE_CURRENCY_LEGACY_NO` picks the base |
| `categories` | `accountCategoryType_tb` | `account_categories` | `CategoryTypGroup` → statement/section |
| `accounts` | `master_acc` | `accounts` | tree by `father_acc`; `is_postable` = leaf; nature 1→credit 2→debit 3→both |
| `rates` | `currancy_rate_tb` (wide) | `exchange_rates` (long) | one row per currency per date |
| `dealers` | `Dealers_tb` | `dealers` | merged by `Dealer_no`; role = flags |

## Not yet migrated (later phases)

Opening balances (as one opening journal entry per the cut-over date),
historical transactions (archive schema), inventory, invoices, payroll.
