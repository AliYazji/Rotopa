-- ============================================================================
-- Rotopa · Core Stabilization Phase 0 (4/4) — reporting must be accurate to
-- the actual entry_date, not just the fiscal period.
--
-- 20250911004100_reporting_period_filter_fix.sql fixed the cross-PERIOD
-- leak (a query for period A no longer sees period B's balance) but that
-- fix still filtered at PERIOD granularity: it summed a period's whole
-- account_period_balances row once `fiscal_periods.start_date <= p_as_of`,
-- with no lower bound inside the period itself. A posting on the 25th of a
-- month is still inside a trial_balance(p_as_of = 15th of that SAME month)
-- result, because the period's start_date (the 1st) satisfies the filter —
-- the report would show money that, as of the requested date, hasn't been
-- posted yet.
--
-- Fix: stop reading the account_period_balances monthly rollup for these
-- three report functions entirely, and sum posted journal_lines directly,
-- filtered by the real journal_entries.entry_date. This is exact by
-- construction — no period-granularity gap is possible because there is no
-- period boundary involved anymore. journal_entries(org_id, entry_date) and
-- journal_entries(org_id, status) are both already indexed
-- (20250911000600_general_ledger.sql), as is journal_lines(org_id,
-- account_id) and journal_lines(entry_id) for the join.
--
-- This also settles a second real question along the way: fiscal_periods'
-- `status` (open/closed) is now completely irrelevant to these reports —
-- closing a period in this system only blocks NEW postings into it
-- (app.open_period_for), it does not run a year-end closing entry that
-- moves income/expense balances into retained earnings. balance_sheet()'s
-- UNCLOSED line and income_statement() must therefore keep counting every
-- posted income/expense line through p_as_of regardless of any period's
-- open/closed status — which direct journal_lines summation does
-- automatically, since it never looks at period status at all. A real
-- periodic/annual closing mechanism (posting income and expense to
-- retained earnings) is out of scope for Phase 0 and stays a separate,
-- later task.
--
-- Same signatures, same SECURITY INVOKER/search_path/grants as before —
-- body-only redefinitions again.
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
  with posted_lines as (
    select l.account_id, l.debit, l.credit
    from journal_lines l
    join journal_entries e on e.id = l.entry_id
    where e.org_id = p_org and e.status = 'posted'
      and (p_as_of is null or e.entry_date <= p_as_of)
  )
  select a.id, a.code, a.name_ar, a.depth,
         coalesce(sum(l.debit), 0),
         coalesce(sum(l.credit), 0),
         coalesce(sum(l.debit - l.credit), 0)
  from accounts a
  left join posted_lines l on l.account_id = a.id
  where a.org_id = p_org and a.is_postable
  group by a.id, a.code, a.name_ar, a.depth
  having coalesce(sum(l.debit), 0) <> 0 or coalesce(sum(l.credit), 0) <> 0
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
  with posted_lines as (
    select l.account_id, l.debit, l.credit
    from journal_lines l
    join journal_entries e on e.id = l.entry_id
    where e.org_id = p_org and e.status = 'posted'
      and (p_from is null or e.entry_date >= p_from)
      and (p_to   is null or e.entry_date <= p_to)
  )
  select c.id, c.code, c.name_ar, c.section, c.sort_order,
         a.id, a.code, a.name_ar,
         coalesce(sum(case when c.normal_balance = 'credit' then l.credit - l.debit
                            else l.debit - l.credit end), 0)
  from accounts a
  join account_categories c on c.id = a.category_id
  left join posted_lines l on l.account_id = a.id
  where a.org_id = p_org and a.is_postable and c.statement = 'income_statement'
  group by c.id, c.code, c.name_ar, c.section, c.sort_order, a.id, a.code, a.name_ar
  having coalesce(sum(case when c.normal_balance = 'credit' then l.credit - l.debit
                            else l.debit - l.credit end), 0) <> 0
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
  with posted_lines as (
    select l.account_id, l.debit, l.credit
    from journal_lines l
    join journal_entries e on e.id = l.entry_id
    where e.org_id = p_org and e.status = 'posted'
      and (p_as_of is null or e.entry_date <= p_as_of)
  )
  select c.id, c.code, c.name_ar, c.section, c.sort_order,
         a.id, a.code, a.name_ar,
         coalesce(sum(case when c.normal_balance = 'credit' then l.credit - l.debit
                            else l.debit - l.credit end), 0)
  from accounts a
  join account_categories c on c.id = a.category_id
  left join posted_lines l on l.account_id = a.id
  where a.org_id = p_org and a.is_postable and c.statement = 'balance_sheet'
  group by c.id, c.code, c.name_ar, c.section, c.sort_order, a.id, a.code, a.name_ar
  having coalesce(sum(case when c.normal_balance = 'credit' then l.credit - l.debit
                            else l.debit - l.credit end), 0) <> 0

  union all

  -- UNCLOSED: every posted income/expense line through p_as_of, regardless
  -- of fiscal_periods.status — closing a period only blocks new postings
  -- into it (app.open_period_for), it does not move income/expense to
  -- retained earnings, so a closed period's revenue/expense is still real,
  -- still-unclosed net income and must stay in this line until an actual
  -- year-end closing mechanism exists (a separate, later task)
  select null, 'UNCLOSED', 'أرباح/خسائر غير مقفلة (منذ آخر إقفال)', 'equity', 999,
         null, null, null,
         coalesce((
           select sum(case c2.section
                        when 'income'  then l2.credit - l2.debit
                        when 'expense' then -(l2.debit - l2.credit)
                        else 0
                      end)
           from accounts a2
           join account_categories c2 on c2.id = a2.category_id
           join journal_lines l2 on l2.account_id = a2.id
           join journal_entries e2 on e2.id = l2.entry_id
           where a2.org_id = p_org and a2.is_postable and c2.statement = 'income_statement'
             and e2.org_id = p_org and e2.status = 'posted'
             and (p_as_of is null or e2.entry_date <= p_as_of)
         ), 0);
$$;

grant execute on function trial_balance(uuid, date) to authenticated;
grant execute on function income_statement(uuid, date, date) to authenticated;
grant execute on function balance_sheet(uuid, date) to authenticated;
