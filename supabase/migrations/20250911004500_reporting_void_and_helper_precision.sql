-- ============================================================================
-- Rotopa · Core Stabilization Phase 0 (5/5) — voided entries must not
-- disappear from historical reports, and the remaining period-level helper
-- functions need the same entry-date precision as the main reports.
--
-- ROOT CAUSE 1 — void_journal_entry() (20250911000600_general_ledger.sql)
-- never deletes or rewrites the original entry: it flips it to
-- status='void' and inserts a brand-new, separately-dated reversal entry
-- with status='posted' (debit/credit swapped, same account). That is a
-- real, historically-accurate reversing-entry pattern: the ORIGINAL
-- entry's effect genuinely happened on its own entry_date and stayed true
-- until the REVERSAL's own (later) entry_date offset it. But
-- 20250911004400 filtered every report on `e.status = 'posted'` only,
-- which excludes the now-void original while still counting the
-- reversal — undercounting every period between the original entry_date
-- and the void date, and changing already-published historical reports
-- retroactively the moment a later void happens. The fix is exactly what
-- the user specified: treat 'posted' and 'void' as equally real for
-- reporting (only a 'draft' entry never happened) — entry_date is what
-- decides whether an entry's effect is in scope for a given report date,
-- not its current status.
--
-- ROOT CAUSE 2 — account_balance()/chart_of_accounts_balances() were
-- never touched by 20250911004100/004400 (those only covered
-- trial_balance/income_statement/balance_sheet) and still read the
-- monthly account_period_balances rollup filtered by
-- `fiscal_periods.start_date <= p_as_of` — the exact same period-level
-- (not entry-level) imprecision fixed in the main reports, plus the same
-- posted-only exclusion of void/reversal pairs. Both are rewritten to sum
-- journal_lines/journal_entries directly, exactly like the main reports.
--
-- ROOT CAUSE 3 — account_ledger() (20250911000800_reporting.sql) filtered
-- `e.status = 'posted'` too, so after a void the ledger showed the
-- reversal but silently dropped the original line it was reversing —
-- broken narrative and a running balance that starts from the wrong
-- point. Fix: broaden the same status filter; the existing date-ordered
-- window-function running balance already produces the right sequence
-- once both lines are present (debit 100 on the original's entry_date,
-- offsetting credit 100 on the reversal's entry_date — no other change
-- needed here).
--
-- Every function below keeps its exact signature, return type, security
-- mode, search_path and grants from its immediately-preceding definition
-- (20250911004400 for the first three, the untouched originals in
-- 20250911000600/20250911000800 for account_balance/
-- chart_of_accounts_balances/account_ledger) — body-only redefinitions.
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
    where e.org_id = p_org and e.status in ('posted', 'void')
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
    where e.org_id = p_org and e.status in ('posted', 'void')
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
    where e.org_id = p_org and e.status in ('posted', 'void')
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
             and e2.org_id = p_org and e2.status in ('posted', 'void')
             and (p_as_of is null or e2.entry_date <= p_as_of)
         ), 0);
$$;

grant execute on function trial_balance(uuid, date) to authenticated;
grant execute on function income_statement(uuid, date, date) to authenticated;
grant execute on function balance_sheet(uuid, date) to authenticated;

-- ---------------------------------------------------------------------------
-- account_balance() — same signature/return type as
-- 20250911000600_general_ledger.sql (no SECURITY/search_path clause there
-- either — preserved exactly, not "fixed" to the newer convention, since
-- that would be an unrequested behavior change beyond this fix's scope).
-- ---------------------------------------------------------------------------
create or replace function account_balance(p_account_id uuid, p_as_of date default null)
returns numeric language sql stable as $$
  select coalesce(sum(l.debit - l.credit), 0)
  from journal_lines l
  join journal_entries e on e.id = l.entry_id
  where l.account_id = p_account_id
    and e.status in ('posted', 'void')
    and (p_as_of is null or e.entry_date <= p_as_of);
$$;

-- ---------------------------------------------------------------------------
-- chart_of_accounts_balances() — same signature/return type/SECURITY
-- INVOKER/search_path (public, extensions — needed for the ltree `<@`
-- operator) as 20250911003700_coa_balances.sql. The ltree descendant-or-
-- self rollup (d.path <@ a.path) is unchanged — only its balance source
-- moved from the monthly rollup to entry-level summation.
--
-- Written as a pre-aggregated CTE rather than the straightforward
-- "correlated subquery joining journal_lines directly, once per outer
-- account row" version (which is what the monthly-rollup original already
-- did, and what a first pass of this fix also did) — see the performance
-- section of this migration's PR description for the measured reason:
-- EXPLAIN ANALYZE at ~3,000-entry scale showed that version repeating a
-- sequential scan of journal_lines once per account (285 times) —
-- ~675ms/107k buffer hits, versus ~8ms/1.2k buffer hits for this version,
-- with byte-identical output. An index on journal_lines(account_id) was
-- tried first and empirically did NOT change the plan (Hash Join doesn't
-- consult an index on its probed side) — confirming this needed a query
-- restructure, not a speculative index.
-- ---------------------------------------------------------------------------
create or replace function chart_of_accounts_balances(p_org uuid, p_as_of date default null)
returns table (account_id uuid, balance numeric(19,4))
language sql stable security invoker set search_path = public, extensions as $$
  with leaf_balances as (
    select l.account_id, sum(l.debit - l.credit) as balance
    from journal_lines l
    join journal_entries e on e.id = l.entry_id
    where e.org_id = p_org and e.status in ('posted', 'void')
      and (p_as_of is null or e.entry_date <= p_as_of)
    group by l.account_id
  )
  select a.id,
         coalesce((
           select sum(b.balance)
           from accounts d
           join leaf_balances b on b.account_id = d.id
           where d.org_id = p_org and d.is_postable and d.path <@ a.path
         ), 0)
  from accounts a
  where a.org_id = p_org;
$$;

-- ---------------------------------------------------------------------------
-- account_ledger() — same signature/return type/SECURITY INVOKER/
-- search_path/grant as 20250911000800_reporting.sql. Only the status
-- filter changes; the existing date-ordered window-function running
-- balance already produces the right sequence once the void original and
-- its posted reversal are both present.
-- ---------------------------------------------------------------------------
create or replace function account_ledger(
  p_account_id uuid,
  p_from date default null,
  p_to date default null
)
returns table (
  entry_no    bigint,
  entry_date  date,
  description text,
  debit       numeric(19,4),
  credit      numeric(19,4),
  running     numeric(19,4)
) language sql stable security invoker set search_path = public as $$
  select e.entry_no, e.entry_date,
         coalesce(nullif(l.description,''), e.description),
         l.debit, l.credit,
         sum(l.debit - l.credit) over (order by e.entry_date, e.entry_no, l.line_no
                                       rows between unbounded preceding and current row)
  from journal_lines l
  join journal_entries e on e.id = l.entry_id
  where l.account_id = p_account_id
    and e.status in ('posted', 'void')
    and (p_from is null or e.entry_date >= p_from)
    and (p_to   is null or e.entry_date <= p_to)
  order by e.entry_date, e.entry_no, l.line_no;
$$;

grant execute on function account_ledger(uuid, date, date) to authenticated;
