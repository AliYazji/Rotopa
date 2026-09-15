-- ============================================================================
-- Rotopa · Module 08 (continued) — operational KPI dashboard
--
-- The old "/" page was just the trial balance rendered as if it were a
-- dashboard — a real report, but not an operational summary. This adds one
-- purpose-built aggregate RPC (same "dedicated report RPC" shape as
-- trial_balance()/income_statement()/balance_sheet(), just wider) so the
-- new home page can show cash position, AR/AP, this month's activity, the
-- trial-balance sanity check, today's fiscal-period status, and a short
-- worklist of things waiting on someone — all in one round trip. The old
-- trial-balance view moves to its own /trial-balance report page under
-- التقارير, where it already semantically belonged.
--
-- Deliberately uses account_categories.code = 'L100' (النقد وشبة النقد) for
-- "what counts as cash" rather than accounts.cashflow_class — checked the
-- real dev data first: cashflow_class is the same kind of sparse, unreliable
-- legacy-sourced flag as the accountCategoryType gap categorize-accounts.ts
-- already fixed once this project (2/114 real accounts tagged, one of them
-- literally "56000 سيارة 1" a vehicle expense account tagged 'cash') —
-- category_id/account_categories is the one that's actually been made
-- reliable (118/118 categorized, verified earlier this project).
-- ============================================================================

create or replace function dashboard_summary(p_org uuid)
returns table (
  cash_balance numeric,
  ar_balance numeric,
  ap_balance numeric,
  sales_this_month numeric,
  purchases_this_month numeric,
  trial_balance_debit numeric,
  trial_balance_credit numeric,
  today_period_status text,
  today_period_label text,
  fiscal_year_status text,
  draft_sales_invoices int,
  draft_purchase_invoices int,
  open_sales_orders int,
  open_purchase_orders int,
  pending_invitations int
)
-- security invoker + RLS-scoped subqueries (same convention as trial_balance()/
-- income_statement()) — a non-member simply gets a row of zeros/nulls, not an
-- explicit error, matching how every other report RPC in this project behaves.
language plpgsql stable security invoker set search_path = public as $$
begin
  return query
  select
    coalesce((
      select sum(account_balance(a.id)) from accounts a
      join account_categories c on c.id = a.category_id
      where a.org_id = p_org and c.code = 'L100'
    ), 0),
    coalesce((
      select sum(account_balance(a.id)) from accounts a
      join account_categories c on c.id = a.category_id
      where a.org_id = p_org and c.code = 'L120'
    ), 0),
    coalesce((
      select -sum(account_balance(a.id)) from accounts a
      join account_categories c on c.id = a.category_id
      where a.org_id = p_org and c.code = 'L300'
    ), 0),
    coalesce((
      select sum(l.line_total * i.rate) from sales_invoices i
      join sales_invoice_lines l on l.invoice_id = i.id
      where i.org_id = p_org and i.status = 'posted'
        and date_trunc('month', i.invoice_date) = date_trunc('month', current_date)
    ), 0),
    coalesce((
      select sum(l.line_total * i.rate) from purchase_invoices i
      join purchase_invoice_lines l on l.invoice_id = i.id
      where i.org_id = p_org and i.status = 'posted'
        and date_trunc('month', i.invoice_date) = date_trunc('month', current_date)
    ), 0),
    coalesce((select sum(debit_base) from account_period_balances b join accounts a on a.id = b.account_id where a.org_id = p_org), 0),
    coalesce((select sum(credit_base) from account_period_balances b join accounts a on a.id = b.account_id where a.org_id = p_org), 0),
    (select p.status from fiscal_periods p where p.org_id = p_org and current_date between p.start_date and p.end_date),
    (select 'فترة ' || p.period_no from fiscal_periods p where p.org_id = p_org and current_date between p.start_date and p.end_date),
    (select y.status from fiscal_years y
       join fiscal_periods p on p.fiscal_year_id = y.id
       where p.org_id = p_org and current_date between p.start_date and p.end_date),
    (select count(*)::int from sales_invoices where org_id = p_org and status = 'draft'),
    (select count(*)::int from purchase_invoices where org_id = p_org and status = 'draft'),
    (select count(*)::int from sales_orders where org_id = p_org and status = 'confirmed'),
    (select count(*)::int from purchase_orders where org_id = p_org and status = 'confirmed'),
    (select count(*)::int from membership_invitations where org_id = p_org and status = 'pending');
end;
$$;

revoke all on function dashboard_summary(uuid) from public, anon;
grant execute on function dashboard_summary(uuid) to authenticated;
