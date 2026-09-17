-- ============================================================================
-- Rotopa · Module 08 (slice) — read models for the web app
-- Thin, security-invoker functions: RLS on the underlying tables still applies.
-- ============================================================================

-- Trial balance as of a date (inclusive). One row per postable account that has
-- any movement, plus its running balance.
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
  select a.id, a.code, a.name_ar, a.depth,
         coalesce(sum(b.debit_base), 0),
         coalesce(sum(b.credit_base), 0),
         coalesce(sum(b.debit_base - b.credit_base), 0)
  from accounts a
  left join account_period_balances b on b.account_id = a.id
  left join fiscal_periods p on p.id = b.fiscal_period_id
      and (p_as_of is null or p.start_date <= p_as_of)
  where a.org_id = p_org and a.is_postable
  group by a.id, a.code, a.name_ar, a.depth
  having coalesce(sum(b.debit_base), 0) <> 0 or coalesce(sum(b.credit_base), 0) <> 0
  order by a.code;
$$;

-- Statement of account — posted lines for one account in a date window.
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
    and e.status = 'posted'
    and (p_from is null or e.entry_date >= p_from)
    and (p_to   is null or e.entry_date <= p_to)
  order by e.entry_date, e.entry_no, l.line_no;
$$;

grant execute on function trial_balance(uuid, date) to authenticated;
grant execute on function account_ledger(uuid, date, date) to authenticated;
