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
(`supabase db push`, or `scripts/local-db.sh` for a local DB).

## Run

```bash
npm run etl                 # all steps, in order
npm run etl:currencies
npm run etl:accounts        # categories + accounts
npm run etl:rates
npm run etl:dealers
npm run etl:opening         # opening balances — run last, needs accounts + rates
npm run verify               # row-count + tree-integrity check vs. the legacy DB
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
| `opening-balances` | `acc_trn` (summed) | one `journal_entries` row + lines | see below |

### Opening balances — how it works, and its limit

The legacy backup has no usable stored balance (`master_acc.initial_balance`
and `.BLANCE` are both empty in this dump), so the step **sums the entire
`acc_trn` history per account** and posts the net as one opening entry dated
at the start of the target organization's current fiscal year. Foreign-currency
accounts post in their own currency at `fx_rate()` on that date. An account
frozen in the legacy system (`StopTransaction=1` → `allow_transactions=false`)
can still receive its carried-forward balance — the database has an explicit
exception for `is_opening` entries only (`20250911000900_gl_opening_exception.sql`).

Any account from `acc_trn` not present in the migrated chart, plus whatever
plug is needed to force the entry to balance exactly, is posted to an
auto-created **`OB-VAR` — فروقات الأرصدة الافتتاحية** account, so nothing is
silently dropped.

**Known limitation:** this sums *every* account, including income/expense —
a real cut-over should first close income and expense into retained earnings
and carry forward only balance-sheet accounts. Until that step exists, expect
`OB-VAR` to absorb roughly the period's net result; check it before trusting
the opening trial balance as a real balance sheet.

## Not yet migrated (later phases)

Historical transaction detail (archive schema, if ever needed for drill-down),
inventory, invoices, payroll.
