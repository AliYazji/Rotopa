-- ============================================================================
-- Rotopa · Module 01 (continued) — balance per account on the chart-of-
-- accounts browsing screen itself, not just after drilling into one.
--
-- trial_balance() doesn't fit here: it only lists POSTABLE accounts that
-- have a nonzero balance (correct for an actual trial balance report), but
-- /accounts shows the WHOLE tree including group/parent rows and zero
-- balances. A group row's balance is the rolled-up sum of every postable
-- account under it (the standard chart-of-accounts convention) — computed
-- via the ltree `path` column already indexed with a GiST index
-- (accounts_path_gist) for exactly this kind of descendant-or-self query.
-- ============================================================================
create or replace function chart_of_accounts_balances(p_org uuid, p_as_of date default null)
returns table (account_id uuid, balance numeric(19,4))
language sql stable security invoker set search_path = public, extensions as $$
  select a.id,
         coalesce((
           select sum(b.debit_base - b.credit_base)
           from accounts d
           join account_period_balances b on b.account_id = d.id
           join fiscal_periods p on p.id = b.fiscal_period_id
             and (p_as_of is null or p.start_date <= p_as_of)
           where d.org_id = p_org and d.is_postable and d.path <@ a.path
         ), 0)
  from accounts a
  where a.org_id = p_org;
$$;
