-- ============================================================================
-- Rotopa · Module 08 (continued) — income statement & balance sheet
--
-- module 08's first slice shipped trial_balance()/account_ledger() only;
-- the plan called for the balance sheet and income statement too. Both
-- were always derivable from data the schema already carries —
-- account_categories.statement/section/normal_balance were seeded from the
-- legacy accountCategoryType_tb.CategoryTypGroup mapping back in the ETL's
-- categories.ts step (module 01), just never queried by a report function.
--
-- Same shape as trial_balance()/account_ledger(): plain SQL, STABLE,
-- SECURITY INVOKER — RLS on the underlying tables does the org-scoping,
-- no elevated permission needed to read what you can already see.
--
-- Both return per-ACCOUNT rows tagged with their category (id, name,
-- section, sort order) rather than pre-aggregating into fixed section
-- totals server-side — the client groups/subtotals by category, same
-- division of responsibility as trial_balance() leaving formatting to the
-- caller. `amount` is always in the category's own natural-balance sign
-- (positive when a credit-normal account is credited, or a debit-normal
-- account is debited) so every row reads as a plain positive number.
--
-- Deferred, documented, not silently missing: a cash flow statement
-- (account_categories.cashflow_section exists in the schema but the ETL
-- never populates it — no source data to classify operating/investing/
-- financing from) and budget-vs-actual (the budgets dimension table from
-- module 03 has no real usage in the migrated data to report against yet).
-- ============================================================================

-- Income statement: revenue/expense accounts, net for the [p_from, p_to]
-- window — periods are matched by OVERLAP (any period touching the range
-- counts in full), same month-granularity precision as the rest of the
-- reporting layer; account_period_balances is a monthly rollup, not daily.
create or replace function income_statement(p_org uuid, p_from date, p_to date)
returns table (
  category_id       uuid,
  category_code     text,
  category_name_ar  text,
  section           text,
  category_sort     int,
  account_id        uuid,
  account_code      citext,
  account_name_ar   text,
  amount            numeric(19,4)
) language sql stable security invoker set search_path = public as $$
  select c.id, c.code, c.name_ar, c.section, c.sort_order,
         a.id, a.code, a.name_ar,
         coalesce(sum(case when c.normal_balance = 'credit' then b.credit_base - b.debit_base
                            else b.debit_base - b.credit_base end), 0)
  from accounts a
  join account_categories c on c.id = a.category_id
  left join account_period_balances b on b.account_id = a.id
  left join fiscal_periods p on p.id = b.fiscal_period_id
      and (p_from is null or p.end_date >= p_from)
      and (p_to   is null or p.start_date <= p_to)
  where a.org_id = p_org and a.is_postable and c.statement = 'income_statement'
  group by c.id, c.code, c.name_ar, c.section, c.sort_order, a.id, a.code, a.name_ar
  having coalesce(sum(case when c.normal_balance = 'credit' then b.credit_base - b.debit_base
                            else b.debit_base - b.credit_base end), 0) <> 0
  order by c.sort_order, a.code;
$$;

-- Balance sheet as of p_as_of (cumulative from inception, like
-- trial_balance()). Includes one synthetic row — no account_id, category
-- code 'UNCLOSED' — for net income earned since the last time income/
-- expense accounts were closed to equity. There is no periodic closing
-- step in this system yet (the one-time ETL close at cutover was exactly
-- that — a ONE-TIME event, not a recurring mechanism), so without this
-- line the balance sheet would not balance against assets = liabilities +
-- equity the moment any revenue or expense posts after that cutover.
create or replace function balance_sheet(p_org uuid, p_as_of date default null)
returns table (
  category_id       uuid,
  category_code     text,
  category_name_ar  text,
  section           text,
  category_sort     int,
  account_id        uuid,
  account_code      citext,
  account_name_ar   text,
  amount            numeric(19,4)
) language sql stable security invoker set search_path = public as $$
  select c.id, c.code, c.name_ar, c.section, c.sort_order,
         a.id, a.code, a.name_ar,
         coalesce(sum(case when c.normal_balance = 'credit' then b.credit_base - b.debit_base
                            else b.debit_base - b.credit_base end), 0)
  from accounts a
  join account_categories c on c.id = a.category_id
  left join account_period_balances b on b.account_id = a.id
  left join fiscal_periods p on p.id = b.fiscal_period_id
      and (p_as_of is null or p.start_date <= p_as_of)
  where a.org_id = p_org and a.is_postable and c.statement = 'balance_sheet'
  group by c.id, c.code, c.name_ar, c.section, c.sort_order, a.id, a.code, a.name_ar
  having coalesce(sum(case when c.normal_balance = 'credit' then b.credit_base - b.debit_base
                            else b.debit_base - b.credit_base end), 0) <> 0

  union all

  select null, 'UNCLOSED', 'أرباح/خسائر غير مقفلة (منذ آخر إقفال)', 'equity', 999,
         null, null, null,
         coalesce((
           select sum(case c2.section
                        when 'income'  then b2.credit_base - b2.debit_base
                        when 'expense' then -(b2.debit_base - b2.credit_base)
                        else 0
                      end)
           from accounts a2
           join account_categories c2 on c2.id = a2.category_id
           left join account_period_balances b2 on b2.account_id = a2.id
           left join fiscal_periods p2 on p2.id = b2.fiscal_period_id
               and (p_as_of is null or p2.start_date <= p_as_of)
           where a2.org_id = p_org and a2.is_postable and c2.statement = 'income_statement'
         ), 0);
$$;

grant execute on function income_statement(uuid, date, date) to authenticated;
grant execute on function balance_sheet(uuid, date) to authenticated;
