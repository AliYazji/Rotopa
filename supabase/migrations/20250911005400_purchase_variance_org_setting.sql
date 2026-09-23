-- ============================================================================
-- Rotopa · Post-review hardening — purchase/valuation-variance account must
-- be a fixed per-organization setting, not a free parameter any posting
-- user can pass through the RPC.
--
-- WHY: 20250911005200_purchase_return_cost_consistency.sql shipped
-- p_variance_account_id as a caller-supplied argument to post_purchase_
-- return() — functionally correct (the difference always lands in an
-- explicit, non-arbitrary account) but organizationally wrong: it let
-- WHOEVER posts a return choose which GL account absorbs a valuation
-- variance, transaction by transaction. That is an accounting-policy
-- decision, not an operational one, and belongs behind the same
-- 'settings.write' permission every other default-account setting already
-- requires (org_settings' own settings_write RLS policy, unchanged by this
-- migration) — never inside a per-call argument a regular clerk can set.
--
-- POLICY: the variance account is read from org_settings
-- (key='default_accounts', field 'purchase_variance_account_id') — the
-- SAME key/row the web Settings page already uses for
-- sales_account_id/output_vat_account_id/input_vat_account_id/
-- cash_account_id, so it inherits the exact same RLS-enforced write
-- permission ('settings.write') with no new policy needed. A missing
-- setting behaves exactly like a missing p_variance_account_id did before:
-- posting is refused, with a clear message, ONLY if a variance actually
-- arises — the common case (no drift) is entirely unaffected.
--
-- Recommended default account, per the accounting decision this
-- implements: "فروقات أسعار المشتريات وتقييم المخزون" (purchase price and
-- inventory valuation variance), classified under cost of goods sold /
-- inventory adjustments, normal balance debit — while still able to carry
-- an occasional credit movement, since the variance direction in this
-- function is always a credit-side shortfall being routed away from
-- inventory (see the migration this one amends for the exact derivation).
-- Which literal account row that is remains the organization's own
-- chart-of-accounts decision; this migration only fixes WHERE the function
-- reads its identity from, not which account gets created.
--
-- ORPHANED-OVERLOAD DISCIPLINE: the previous migration changed
-- post_purchase_return()'s arity from 2 to 3 parameters via `create or
-- replace` — Postgres correctly replaced the 2-arg signature in place
-- (create or replace only reuses an EXISTING function when the argument
-- list matches exactly; a changed arity creates a NEW, separate overload
-- and would otherwise leave the old one orphaned). That prior migration's
-- own `drop function if exists post_purchase_return(uuid, uuid)` already
-- removed the OLD 2-arg version, so today there is exactly one live
-- 3-arg overload to remove here — this migration drops that 3-arg
-- overload explicitly before recreating the 2-arg version, so the
-- function never has more than one live signature at any point.
-- ============================================================================

create or replace function app.purchase_variance_account(p_org uuid) returns uuid
language sql stable as $$
  select nullif(value->>'purchase_variance_account_id', '')::uuid
  from org_settings where org_id = p_org and key = 'default_accounts';
$$;
comment on function app.purchase_variance_account(uuid) is
  'Per-organization purchase/valuation-variance account, configured from /settings (org_settings key=''default_accounts'', field purchase_variance_account_id) — editable only by a user with the settings.write permission. Null when never configured.';

drop function if exists post_purchase_return(uuid, uuid, uuid);

create or replace function post_purchase_return(p_return_id uuid, p_input_vat_account_id uuid default null)
returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  r purchase_returns%rowtype;
  inv purchase_invoices%rowtype;
  v_move uuid; v_entry uuid; v_period uuid;
  v_line_no int := 0; v_total numeric(19,4); v_vat numeric(19,4);
  v_orig_qty numeric; v_already numeric;
  g record;
  v_old item_warehouse_balances%rowtype;
  v_old_total_value numeric(19,4); v_uncapped_new_value numeric(19,4);
  v_new_qty numeric(19,4); v_new_total_value numeric(19,4); v_new_avg numeric(19,4);
  v_inv_decrease numeric(19,4); v_item_variance numeric(19,4);
  v_item_ids uuid[] := '{}'; v_inv_decreases numeric[] := '{}';
  v_total_variance numeric(19,4) := 0;
  v_variance_account_id uuid;
begin
  select * into r from purchase_returns where id = p_return_id for update;
  if not found then raise exception 'return not found' using errcode = 'P0002'; end if;
  perform app.require_permission(r.org_id, 'purchases.post');
  if r.status <> 'draft' then raise exception 'only a draft return can be posted (this one is %)', r.status using errcode = '23514'; end if;
  if not exists (select 1 from purchase_return_lines where return_id = p_return_id) then
    raise exception 'return has no lines' using errcode = '23514';
  end if;

  select * into inv from purchase_invoices where id = r.purchase_invoice_id for update;
  if inv.status <> 'posted' then
    raise exception 'the original invoice is no longer posted (status: %) — this return can no longer be posted', inv.status
      using errcode = '23514';
  end if;

  for g in
    select purchase_invoice_line_id, sum(qty) as qty
    from purchase_return_lines
    where return_id = p_return_id
    group by purchase_invoice_line_id
    order by purchase_invoice_line_id
  loop
    select qty into v_orig_qty from purchase_invoice_lines where id = g.purchase_invoice_line_id for update;

    select coalesce(sum(l2.qty), 0) into v_already
    from purchase_return_lines l2 join purchase_returns r2 on r2.id = l2.return_id
    where l2.purchase_invoice_line_id = g.purchase_invoice_line_id and r2.status = 'posted' and r2.id <> p_return_id;

    if v_already + g.qty > v_orig_qty then
      raise exception 'cannot post this return — only % of % remains returnable for invoice line % (another return against it was posted first)',
        v_orig_qty - v_already, v_orig_qty, g.purchase_invoice_line_id
        using errcode = '23514';
    end if;
  end loop;

  select sum(line_total) into v_total from purchase_return_lines where return_id = p_return_id;
  v_vat := round(v_total * inv.tax_rate, 4);
  if v_vat > 0 and p_input_vat_account_id is null then
    raise exception 'an input VAT account is required to post a purchase return' using errcode = '23514';
  end if;

  update purchase_returns set tax_rate = inv.tax_rate, tax_amount = v_vat where id = p_return_id;

  v_move := create_stock_move(r.org_id, 'adjustment_out', r.return_date, 'مرجع فاتورة مشتريات — إشعار رقم ' || r.return_no,
    (select jsonb_agg(jsonb_build_object('item_id', l.item_id, 'warehouse_id', r.warehouse_id,
                                          'direction', 'out', 'unit_id', l.unit_id, 'entered_qty', l.qty))
     from purchase_return_lines l where l.return_id = p_return_id),
    'purchase_return', r.id);
  perform post_stock_move(v_move);

  -- reverse at the ORIGINAL receiving cost: correct the remaining balance's
  -- moving average per item (see 20250911005200 for the full derivation)
  for g in
    select item_id, sum(base_qty) as ret_qty, sum(line_total) as ret_value
    from purchase_return_lines
    where return_id = p_return_id
    group by item_id
    order by item_id
  loop
    select * into v_old from item_warehouse_balances where item_id = g.item_id and warehouse_id = r.warehouse_id for update;

    v_old_total_value := round((v_old.qty + g.ret_qty) * v_old.avg_cost, 4);
    v_new_qty := v_old.qty;
    v_uncapped_new_value := round(v_old_total_value - g.ret_value, 4);
    v_new_total_value := case when v_new_qty = 0 or v_uncapped_new_value < 0 then 0 else v_uncapped_new_value end;
    v_new_avg := case when v_new_qty = 0 then 0 else round(v_new_total_value / v_new_qty, 4) end;
    v_inv_decrease := v_old_total_value - v_new_total_value;
    v_item_variance := round(g.ret_value - v_inv_decrease, 4);

    update item_warehouse_balances set avg_cost = v_new_avg, updated_at = now()
      where item_id = g.item_id and warehouse_id = r.warehouse_id;

    v_item_ids := v_item_ids || g.item_id;
    v_inv_decreases := v_inv_decreases || v_inv_decrease;
    v_total_variance := v_total_variance + v_item_variance;
  end loop;

  if v_total_variance > 0 then
    v_variance_account_id := app.purchase_variance_account(r.org_id);
    if v_variance_account_id is null then
      raise exception 'the item''s average cost has moved too far since the original purchase for this return to be fully absorbed into inventory — configure a purchase/valuation-variance account in Settings first / تغير متوسط تكلفة الصنف كثيرًا منذ الشراء الأصلي بحيث لا يمكن استيعاب هذا المرتجع بالكامل داخل المخزون — يلزم تهيئة حساب فروقات تقييم المشتريات من الإعدادات أولًا'
        using errcode = '23514';
    end if;
  end if;

  v_period := app.open_period_for(r.org_id, r.return_date);
  insert into journal_entries (org_id, entry_no, entry_date, fiscal_period_id, description,
                                source_type, source_id, document_currency_id, created_by)
  values (r.org_id, app.next_seq(r.org_id, 'journal'), r.return_date, v_period,
          coalesce(nullif(r.description,''), 'إشعار مرجع مشتريات رقم ' || r.return_no), 'purchase_return', r.id, r.currency_id, auth.uid())
  returning id into v_entry;

  v_line_no := v_line_no + 1;
  insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate, dealer_id)
  select v_entry, v_line_no,
         case when r.payment_method = 'cash' then r.cash_account_id else d.account_id end,
         'مرجع مشتريات رقم ' || r.return_no, round((v_total + v_vat) * r.rate, 4), 0, r.currency_id, r.rate,
         case when r.payment_method = 'cash' then null else r.dealer_id end
  from dealers d where d.id = r.dealer_id;

  for g in
    select it.inventory_account_id acc, sum(t.dec) amt
    from unnest(v_item_ids, v_inv_decreases) as t(item_id, dec)
    join items it on it.id = t.item_id
    group by it.inventory_account_id
  loop
    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    values (v_entry, v_line_no, g.acc, 'مرجع مشتريات', 0, round(g.amt * r.rate, 4), r.currency_id, r.rate);
  end loop;

  if v_total_variance > 0 then
    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    values (v_entry, v_line_no, v_variance_account_id, 'فرق تقييم مخزون — مرجع مشتريات', 0, round(v_total_variance * r.rate, 4), r.currency_id, r.rate);
  end if;

  if v_vat > 0 then
    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    values (v_entry, v_line_no, p_input_vat_account_id, 'عكس ضريبة مدخلات — مرجع مشتريات', 0, round(v_vat * r.rate, 4), r.currency_id, r.rate);
  end if;

  update journal_entries set status = 'posted', posted_by = auth.uid(), posted_at = now() where id = v_entry;
  update purchase_returns set status = 'posted', journal_entry_id = v_entry, stock_move_id = v_move,
                              posted_by = auth.uid(), posted_at = now() where id = p_return_id;

  return v_entry;
end;
$$;

revoke all on function post_purchase_return(uuid, uuid) from public;
grant execute on function post_purchase_return(uuid, uuid) to authenticated;

revoke all on function app.purchase_variance_account(uuid) from public;
grant execute on function app.purchase_variance_account(uuid) to authenticated, service_role;
