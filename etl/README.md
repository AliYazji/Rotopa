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
| `categorize-accounts` | *(none — derived from the already-migrated `accounts` tree)* | `accounts.category_id` | runs **last**; see below |

### Account categories — RESOLVED: derived from the tree, not the broken legacy flag

**Original gap** (kept here for history): `master_acc.accountCategoryType` — the field the
`accounts` step originally read `category_id` from — is set on only 24 of 114 real accounts;
the legacy system itself never classified roughly 80% of its own chart. `master_acc.class_acc`
looked like a tempting fallback (it covers all 114) but was already found unreliable for this
elsewhere (4 real expense accounts are tagged `class_acc=2` instead of `5`) — auto-deriving from
it would silently misclassify those accounts, worse than leaving them blank.

**Fix**: `categorize-accounts` (`src/steps/categorize-accounts.ts`) ignores both legacy fields
entirely and instead classifies every account from a source the legacy data never corrupted —
the account TREE itself (`accounts.parent_id`), which migrates at 100% integrity (see `verify`
above). It walks each account to its top-level ancestor via a recursive query, then assigns one
of the 22 real `account_categories` (themselves seeded correctly from the legacy
`accountCategoryType_tb` in `categories.ts` — the legacy admins built a proper taxonomy, they
just never finished tagging their own accounts with it) using accounting logic: "شيكات تحت
التحصيل" sits under "الاصول المتداولة" whether or not anyone ever ticked a flag for it. A short
list of exact-code overrides handles the handful of cases where the tree position alone isn't
precise enough (e.g. "رواتب العمال" → مصاريف الرواتب والاجور specifically, not generic operating
expenses; "الخصم المسموح به" → إيراد غير مباشر, since a sales discount is a contra-revenue item,
not a cost of goods sold line — it was previously miscategorized under COGS by the one legacy
flag that WAS set for it).

**Must run last**: `inventory` (creates `COGS-DEFAULT`/`INV-DEFAULT` on demand) and
`opening-balances` (creates `OB-VAR`/`RE` on demand) each add their own fallback accounts
*after* the `accounts` step has already run — categorizing any earlier leaves exactly those 4
system accounts uncategorized, the same gap this step exists to close. `npm run etl` runs the
full pipeline in the correct order automatically; running steps individually, run
`categorize-accounts` after everything else.

**Result on the real backup**: 118/118 accounts categorized (114 real + 4 system fallbacks),
zero left for manual cleanup — confirmed by re-querying `trial_balance()` for accounts with a
category still null (0 rows). The income statement/balance sheet pages' "N accounts have no
category" warning banner is dead code now for this dataset, but deliberately left in place — a
different/future legacy dataset could still hit a genuine gap this tree-based logic can't infer
(e.g. a business unit reorganized into a shape `categorize-accounts`'s override list doesn't
anticipate), and the banner is the honest way to surface that rather than silently miscategorizing.

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

Sales and purchase invoices — historical ones, that is; both the sales
(module 10) and purchases (module 11) modules now exist and post *new*
invoices correctly, but no ETL step brings over the legacy `INVOICE_TB`
history as invoice rows (opening stock/balances already captured their net
effect, so back-filling old invoice documents would double it). Payroll.
