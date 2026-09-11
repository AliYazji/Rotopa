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
npm run etl:inventory       # items, categories, warehouses, units
npm run etl:opening-stock   # opening stock quantities — needs inventory
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
| `inventory` | `ITEM_TB`, `CategoryItem_tb`, `center_tb`, `item_unit` | `items`, `item_categories`, `warehouses`, `item_units` | master data only |
| `opening-stock` | `Item_stock_Details` (summed) | one `stock_moves` row + lines | quantities/cost only — see below |
| `opening-balances` | `acc_trn` (summed) | one `journal_entries` row + lines | see below |

### Opening balances — how it works

The legacy backup has no usable stored balance (`master_acc.initial_balance`
and `.BLANCE` are both empty in this dump), so the step **sums the entire
`acc_trn` history per account** (`SUM(DBAmount)`, `SUM(CRAmount)`) and posts
the net as one opening entry dated at the start of the target organization's
current fiscal year.

- **Income/expense accounts are closed, not carried forward.** Classified by
  the legacy `master_acc.class_acc` (4 = trading/income, 5 = expense —
  verified against every account in this backup, not just assumed), their net
  is posted as a single line to an auto-created retained-earnings account
  (`RE`), the same as a real year-end closing entry. Only balance-sheet
  accounts are carried forward one-for-one.
- Foreign-currency accounts post in their own currency at `fx_rate()` on the
  cutover date.
- An account frozen in the legacy system (`StopTransaction=1` →
  `allow_transactions=false`) can still receive its carried-forward balance —
  the database has an explicit exception for `is_opening` entries only
  (`20250911000900_gl_opening_exception.sql`).
- Anything from `acc_trn` not present in the migrated chart, plus whatever
  plug is needed to force the entry to balance exactly, goes to an
  auto-created **`OB-VAR` — فروقات الأرصدة الافتتاحية** account instead of
  being dropped.

**Why `AccAmount`, not `DBAmount`/`CRAmount`, is the amount field.** An
earlier version of this step summed `DBAmount`/`CRAmount` directly, which
happened to net to almost exactly zero across the whole legacy ledger
(2,427,335.600 vs .660) — reassuring, but wrong: those columns are 0/non-zero
*markers* for which side a row is on, not the amount in every case. The
legacy application's own `dbo.Account_Balance_Trns_DB_CR` function (still
callable against the restored backup — the old *desktop app* is gone, but the
database and its stored procedures are not) computes a balance from
`AccAmount` (the row's amount in the account's own currency), gated by
`DBAmount = 0`. Running that exact formula against every account changed
several balances materially — e.g. the USD bank account's balance went from
an NIS-sized number that made no sense for a USD account to 13,000 (its real
USD balance) — and `OB-VAR`'s plug dropped from ~105,000 to **3,520.06** on
this backup. The step now uses this verified formula.

The remaining 3,520.06 is small enough to be an honest rounding/edge-case
residual rather than a modeling error, but it is still worth an accountant's
five-minute look in `OB-VAR` before trusting the opening trial balance as a
real balance sheet.

**Also expect a few expense accounts to be carried forward instead of
closed**, when the source data itself never classified them: e.g. `51023`,
`51024`, `53103`, `80003` in this backup all have `class_acc=2` ("both")
rather than `5` (expense), even though their names and parent accounts are
clearly expenses. The step trusts `class_acc` as-is rather than guessing from
the name or code range, so these land as ordinary balance-sheet lines —
visible in the trial balance, easy for an accountant to spot and reclassify.

### Inventory — items, then stock

`inventory` migrates **master data only**: 3,546 items, 13 categories, 2
warehouses (`center_tb`), 4,827 item units — every item starts at zero
quantity. `ITEM_TB.QtyInStock` was not usable to seed a balance directly
(only 3 of 3,546 items have it populated), the same pattern already seen
with `master_acc.BLANCE` being empty for accounts.

Two accounts are auto-created if missing (`INV-DEFAULT`, `COGS-DEFAULT`) and
assigned to every tracked item, because no item in this backup has its own
`sales_acc_no`/`Purchases_acc_no` set — review and replace them with real
accounts from your chart before relying on inventory GL postings.

`opening-stock` (run after `inventory`) sums the **real movement ledger**
instead — `Item_stock_Details` (177,885 rows: `qty_in`/`qty_out`/`price` per
item/store/date) — the same care the accounting opening balance got. Net
quantity per item/warehouse, cost = the quantity-weighted average of its
`qty_in` rows only (an out-row's `price` is a selling/issue price in this
data, not a cost). On the real backup: **1,918 item/warehouse pairs posted**
with real stock and a real cost basis; **1,059 had a negative net** (sold
more historically than was ever received there — a pre-existing hole in the
source data, not something this step can paper over) and were skipped
entirely, logged by count. It posts quantities only, no journal entry — the
accounting opening balance already carries whatever inventory-account value
existed at the GL level in the legacy books; posting it again here would
double it.

**Bug worth knowing about if you write another ETL step that joins on an
`..._no` column:** `warehouses.legacy_no` (and the other dimension tables'
`legacy_no`) are `bigint`; `node-postgres` returns `bigint` as a *string* by
default (to avoid precision loss), while the `mssql` driver returns the
matching legacy column as a plain `number`. A `Map` built from one and
looked up with the other misses on every row — silently, no error, just an
empty result. `currencies.legacy_no`/`account_categories.legacy_no` are
`integer` and unaffected; this bit `opening-stock` specifically (100% of
rows "unmatched" until traced down) and is now fixed with an explicit
`Number()` on the Postgres side.

## Not yet migrated (later phases)

Sales and purchase invoices — historical ones, that is; the sales module
itself now exists (module 10) and posts *new* invoices correctly. Module 11
(purchases) is not built yet; `stock_moves.move_type` already reserves
`purchase_in` for when it is. Payroll.
