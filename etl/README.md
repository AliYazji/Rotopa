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
| `inventory` | `ITEM_TB`, `CategoryItem_tb`, `center_tb`, `item_unit` | `items`, `item_categories`, `warehouses`, `item_units` | master data only — see below |
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

### Inventory — what's migrated and what isn't

`inventory` migrates **master data only**: 3,546 items, 13 categories, 2
warehouses (`center_tb`), 4,827 item units. It does **not** migrate stock
quantities or history (`Item_stock_tb`/`Item_stock_Details`, 178k rows) —
`ITEM_TB.QtyInStock` is unreliable in this backup (only 3 of 3,546 items have
it populated), the same pattern already seen with `master_acc.BLANCE` being
empty for accounts. Every migrated item starts with zero stock. A proper
opening-stock migration needs the same care the accounting opening balance
got — summing the real movement ledger, picking a cutover date, reconciling
a variance into a dedicated account — and belongs in its own step once
inventory is in real use, not bundled into master-data migration.

Two accounts are auto-created if missing (`INV-DEFAULT`, `COGS-DEFAULT`) and
assigned to every tracked item, because no item in this backup has its own
`sales_acc_no`/`Purchases_acc_no` set — review and replace them with real
accounts from your chart before relying on inventory GL postings.

## Not yet migrated (later phases)

Stock quantities/history (see above), sales and purchase invoices (modules
10/11 — not built yet; `stock_moves.move_type` already reserves
`purchase_in`/`sale_out` for when they exist), payroll.
