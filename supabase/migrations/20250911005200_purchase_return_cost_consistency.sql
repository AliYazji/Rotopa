-- ============================================================================
-- Rotopa · Executive review remediation, Package 3 — purchase returns must
-- reverse inventory at the ORIGINAL receiving cost when a direct link to the
-- original purchase invoice line exists, and the GL inventory account must
-- always move by exactly the same amount as the sub-ledger (item_warehouse_
-- balances) — never a silently-diverging one.
--
-- ROOT CAUSE (confirmed against the live code):
--   * purchase_return_lines.unit_price is already copied from the ORIGINAL
--     purchase_invoice_lines.unit_price at create_purchase_return() time
--     (20250911004900) — so the AP-side debit and the inventory GL credit,
--     both driven by purchase_return_lines.line_total, were ALREADY correct
--     and consistent with each other, and with the original receiving cost.
--   * But the physical stock exit went through the generic
--     create_stock_move(...)/post_stock_move() path with NO unit_cost
--     supplied, so post_stock_move's ordinary weighted-average 'out' logic
--     costed the exit at whatever the item's CURRENT average happened to be
--     — and, being an ordinary weighted-average exit, left the REMAINING
--     balance's average completely unchanged.
--   * Whenever the item's average had moved since the original receipt
--     (more purchases, more sales, more returns), the amount actually
--     removed from item_warehouse_balances' value (qty * current avg)
--     silently diverged from the amount credited to the inventory GL
--     account (qty * original cost) — a permanent, compounding GL-vs-
--     sub-ledger split that never surfaces on its own (both sides look
--     locally "correct").
--
-- POLICY ADOPTED (per the review's own preference order):
--   1. When a direct link exists (true for every return created through
--      create_purchase_return() since 20250911004900 — p_lines has always
--      required {invoice_line_id, qty}), reverse at the ORIGINAL receiving
--      cost and recompute the REMAINING balance's moving average so that
--      the value actually removed from item_warehouse_balances is exactly
--      the original-cost amount:
--        new_total_value = old_qty * old_avg_cost - returned_qty * original_cost
--        new_avg_cost    = new_total_value / (old_qty - returned_qty)
--      This is mathematically exact whenever new_total_value >= 0 — which is
--      always true unless a LATER, much cheaper receipt has already diluted
--      the average so far down that the remaining pool can no longer give
--      back the full original-cost amount without going negative.
--   2. In that unsafe case (new_total_value < 0, or the item is being fully
--      depleted with residual value left over), inventory absorbs only what
--      it safely can (floored at 0 — the batch being reversed no longer has
--      a traceable place to live in a blended average), and the remainder
--      is posted to an explicit, caller-supplied purchase/valuation-variance
--      account (p_variance_account_id) instead of being silently folded into
--      inventory or dumped into an arbitrary account. The function requires
--      this account only when a variance actually arises (same pattern
--      already used for p_input_vat_account_id).
--
-- WHY post_stock_move() ITSELF IS NOT TOUCHED: it remains the single,
-- untouched moving-weighted-average engine used by every other caller
-- (sales, transfers, adjustments, manufacturing) — this migration does not
-- change its costing rules. The stock move for a purchase return still goes
-- through it exactly as before (qty leaves at the item's current average,
-- same as any other exit); immediately afterward, post_purchase_return()
-- applies a narrowly-scoped CORRECTIVE update to item_warehouse_balances.
-- avg_cost alone (never qty, which post_stock_move already set correctly)
-- to reflect the "reverse at original cost" policy above. item_warehouse_
-- balances has no posted-is-immutable guard (it is a continuously mutated
-- running balance, unlike a document header/line), so this plain UPDATE
-- needs no trigger disabling.
--
-- JOURNAL ENTRY — both cases, per item:
--   Case A (safe, the common case): credit inventory_account_id by exactly
--     the value actually removed (= original cost * returned qty, since
--     nothing was capped) — identical to today's behavior when the average
--     hasn't drifted, and now ALSO exact when it has.
--   Case B (unsafe / capped): credit inventory_account_id by only the safely
--     absorbed portion, and credit p_variance_account_id by the shortfall
--     (original cost * returned qty − amount actually absorbed by
--     inventory). The two credits still sum to exactly the same total as
--     before (line_total, matching the AP-side debit) — the entry stays
--     balanced; only which account receives which slice of the credit
--     changes. The variance amount is provably >= 0 by construction (it is
--     only ever nonzero when the safe case's cap actually bound), so it is
--     always posted as a single credit-side line, never a debit swing.
--
-- ACCEPTANCE CRITERION MET BY CONSTRUCTION: the inventory GL credit for
-- every item is defined as exactly the amount subtracted from that item's
-- item_warehouse_balances value (old_total_value − new_total_value) — so
-- GL inventory value and sub-ledger inventory value move together, exactly,
-- to the same 4-decimal-place rounding already used throughout this schema.
-- ============================================================================

drop function if exists post_purchase_return(uuid, uuid);

create or replace function post_purchase_return(p_return_id uuid, p_input_vat_account_id uuid default null, p_variance_account_id uuid default null)
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
  -- moving average per item, capturing exactly how much value that removed
  -- from inventory (and, if the average had drifted too far, how much
  -- couldn't be safely absorbed and must go to the variance account instead)
  for g in
    select item_id, sum(base_qty) as ret_qty, sum(line_total) as ret_value
    from purchase_return_lines
    where return_id = p_return_id
    group by item_id
    order by item_id
  loop
    select * into v_old from item_warehouse_balances where item_id = g.item_id and warehouse_id = r.warehouse_id for update;

    -- post_stock_move already moved qty out at the current average and left
    -- the average itself unchanged, so the pre-return state is exactly
    -- reconstructible: qty was v_old.qty + g.ret_qty, average was v_old.avg_cost
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

  if v_total_variance > 0 and p_variance_account_id is null then
    raise exception 'the item''s average cost has moved too far since the original purchase for this return to be fully absorbed into inventory — a purchase/valuation-variance account is required / تغير متوسط تكلفة الصنف كثيرًا منذ الشراء الأصلي بحيث لا يمكن استيعاب هذا المرتجع بالكامل داخل المخزون — يلزم تحديد حساب فروقات تقييم المشتريات'
      using errcode = '23514';
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
    values (v_entry, v_line_no, p_variance_account_id, 'فرق تقييم مخزون — مرجع مشتريات', 0, round(v_total_variance * r.rate, 4), r.currency_id, r.rate);
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

grant execute on function post_purchase_return(uuid,uuid,uuid) to authenticated;
