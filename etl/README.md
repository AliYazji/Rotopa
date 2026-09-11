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

**Open question, not yet resolved — verify before relying on these figures
for a real cut-over:** on this backup, `OB-VAR` absorbs a plug of roughly
105,000, unrelated to the P&L-closing above (closing 23 accounts into one
retained-earnings line does not change the total debit/credit — only
regrouping does that). The legacy `AccBalance()` function computes an
account's balance from `AccAmount`/`group_amount` gated by
`DBAmount<>0`/`CRAmount<>0`, *not* by summing `DBAmount`/`CRAmount`
directly — trying that alternative changes the numbers but does not remove
the imbalance either (2,427,335.600 vs 2,398,355.660 instead of vs
2,427,335.660), so it isn't obviously "more correct". Resolving this
precisely needs either a trial-balance report from the running legacy
application to reconcile against, or reading the rest of `AccBalance`'s
~40 branches (`analysis/src_functions_scalar.sql`). Until then, treat
`OB-VAR`'s balance as "needs an accountant's review", not as fact.

**Also expect a few expense accounts to be carried forward instead of
closed**, when the source data itself never classified them: e.g. `51023`,
`51024`, `53103`, `80003` in this backup all have `class_acc=2` ("both")
rather than `5` (expense), even though their names and parent accounts are
clearly expenses. The step trusts `class_acc` as-is rather than guessing from
the name or code range, so these land as ordinary balance-sheet lines —
visible in the trial balance, easy for an accountant to spot and reclassify.

## Not yet migrated (later phases)

Historical transaction detail (archive schema, if ever needed for drill-down),
inventory, invoices, payroll.
