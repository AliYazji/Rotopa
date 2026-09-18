-- ============================================================================
-- Rotopa · Core Stabilization Phase 0 (1/3) — fiscal-period filtering in
-- trial_balance()/income_statement()/balance_sheet() was silently broken.
--
-- The date predicate lived in the ON clause of `left join fiscal_periods`,
-- e.g. `left join fiscal_periods p on p.id = b.fiscal_period_id and
-- p.start_date <= p_as_of`. A failing ON condition on a LEFT JOIN does not
-- drop the left-side row — it only nulls out the right side's columns
-- (`p.*`). account_period_balances (aliased `b`) sits on the LEFT side of
-- that join, so `b.debit_base`/`b.credit_base` stayed in the SUM() no
-- matter what p_as_of/p_from/p_to were — every report was silently
-- cumulative-from-inception regardless of the date argument.
--
-- Fix: filter account_period_balances against fiscal_periods in its own
-- CTE (an actual INNER JOIN, so a non-matching period genuinely drops the
-- balance row), then LEFT JOIN that already-filtered set onto accounts —
-- accounts with no matching balance still appear as a row (0, excluded by
-- the existing HAVING clause), exactly as before. Same signatures, same
-- SECURITY INVOKER/search_path/grants — a body-only fix.
-- ============================================================================

create or replace function trial_balance(p_org uuid, p_as_of date default null)
returns table (
  account_id  uuid,
  code        extensions.citext,
  name_ar     text,
  depth       smallint,
  debit       numeric(19,4),
  credit      numeric(19,4),
  balance     numeric(19,4)
) language sql stable security invoker set search_path = public as $$
  with filtered_balances as (
    select b.account_id, b.debit_base, b.credit_base
    from account_period_balances b
    join fiscal_periods p on p.id = b.fiscal_period_id
    where p_as_of is null or p.start_date <= p_as_of
  )
  select a.id, a.code, a.name_ar, a.depth,
         coalesce(sum(b.debit_base), 0),
         coalesce(sum(b.credit_base), 0),
         coalesce(sum(b.debit_base - b.credit_base), 0)
  from accounts a
  left join filtered_balances b on b.account_id = a.id
  where a.org_id = p_org and a.is_postable
  group by a.id, a.code, a.name_ar, a.depth
  having coalesce(sum(b.debit_base), 0) <> 0 or coalesce(sum(b.credit_base), 0) <> 0
  order by a.code;
$$;

create or replace function income_statement(p_org uuid, p_from date, p_to date)
returns table (
  category_id       uuid,
  category_code     text,
  category_name_ar  text,
  section           text,
  category_sort     int,
  account_id        uuid,
  account_code      extensions.citext,
  account_name_ar   text,
  amount            numeric(19,4)
) language sql stable security invoker set search_path = public as $$
  with filtered_balances as (
    select b.account_id, b.debit_base, b.credit_base
    from account_period_balances b
    join fiscal_periods p on p.id = b.fiscal_period_id
    where (p_from is null or p.end_date >= p_from)
      and (p_to   is null or p.start_date <= p_to)
  )
  select c.id, c.code, c.name_ar, c.section, c.sort_order,
         a.id, a.code, a.name_ar,
         coalesce(sum(case when c.normal_balance = 'credit' then b.credit_base - b.debit_base
                            else b.debit_base - b.credit_base end), 0)
  from accounts a
  join account_categories c on c.id = a.category_id
  left join filtered_balances b on b.account_id = a.id
  where a.org_id = p_org and a.is_postable and c.statement = 'income_statement'
  group by c.id, c.code, c.name_ar, c.section, c.sort_order, a.id, a.code, a.name_ar
  having coalesce(sum(case when c.normal_balance = 'credit' then b.credit_base - b.debit_base
                            else b.debit_base - b.credit_base end), 0) <> 0
  order by c.sort_order, a.code;
$$;

create or replace function balance_sheet(p_org uuid, p_as_of date default null)
returns table (
  category_id       uuid,
  category_code     text,
  category_name_ar  text,
  section           text,
  category_sort     int,
  account_id        uuid,
  account_code      extensions.citext,
  account_name_ar   text,
  amount            numeric(19,4)
) language sql stable security invoker set search_path = public as $$
  with filtered_balances as (
    select b.account_id, b.debit_base, b.credit_base
    from account_period_balances b
    join fiscal_periods p on p.id = b.fiscal_period_id
    where p_as_of is null or p.start_date <= p_as_of
  )
  select c.id, c.code, c.name_ar, c.section, c.sort_order,
         a.id, a.code, a.name_ar,
         coalesce(sum(case when c.normal_balance = 'credit' then b.credit_base - b.debit_base
                            else b.debit_base - b.credit_base end), 0)
  from accounts a
  join account_categories c on c.id = a.category_id
  left join filtered_balances b on b.account_id = a.id
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
           left join filtered_balances b2 on b2.account_id = a2.id
           where a2.org_id = p_org and a2.is_postable and c2.statement = 'income_statement'
         ), 0);
$$;

grant execute on function trial_balance(uuid, date) to authenticated;
grant execute on function income_statement(uuid, date, date) to authenticated;
grant execute on function balance_sheet(uuid, date) to authenticated;
