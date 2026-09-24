-- ============================================================================
-- Rotopa · Executive review remediation, Package 2 (2/2) — void_sales_invoice()
-- must reverse a composite item's sale using the EXACT components, quantities
-- and costs that were actually consumed at sale time — never re-derive them
-- from the CURRENT recipe (bom_lines) or the CURRENT moving average cost.
--
-- ROOT CAUSE: confirmed against the live code — the restock leg of
-- void_sales_invoice() built its jsonb move payload for composite lines with:
--   join bom_lines b on b.finished_item_id = l.item_id            -- LIVE recipe
--   left join item_warehouse_balances iwb ... iwb.avg_cost         -- LIVE cost
-- If the recipe (bom_lines) or a component's moving average changed between
-- the sale and the void, the reversal put back the WRONG components/
-- quantities and expensed/valued them at the WRONG cost — silently
-- corrupting both stock and the GL relative to what was actually sold.
--
-- WHY NO NEW LINK COLUMN IS NEEDED: stock_move_lines already stores, per row,
-- the exact item_id/warehouse_id/base_qty consumed and (for 'out' rows) the
-- unit_cost actually charged — frozen permanently at posting time by
-- post_stock_move() (`update stock_move_lines set unit_cost = v_old.avg_cost
-- where id = l.id`, the moving average AT THE MOMENT OF POSTING, never
-- touched again). sales_invoices.stock_move_id already points at that exact
-- original move. So the original sale's own stock_move_lines are themselves
-- the authoritative "what was actually consumed, at what cost" record — for
-- BOTH plain items and composite items' expanded components alike. No new
-- linking is required to reverse precisely; what was missing was simply that
-- void_sales_invoice() ignored this record and recomputed instead.
--
-- FIX: void_sales_invoice()'s restock move is now built directly from
--   select item_id, warehouse_id, base_qty, unit_cost
--   from stock_move_lines where move_id = inv.stock_move_id and direction = 'out'
-- i.e. a literal mirror of the original outgoing lines, flipped to 'in',
-- unchanged whatever the current recipe or current average cost may be. The
-- previous is_composite/not is_composite UNION ALL branching — which existed
-- only to re-derive composite components — is removed entirely; this single
-- query already covers plain items exactly as before (they already routed
-- through the same original stock_move_lines).
-- ============================================================================

create or replace function void_sales_invoice(p_invoice_id uuid, p_date date, p_reason text default null)
returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  inv sales_invoices%rowtype;
  v_move uuid;
  v_entry uuid;
  v_period uuid;
  v_rev uuid;
begin
  select * into inv from sales_invoices where id = p_invoice_id for update;
  if not found then raise exception 'invoice not found' using errcode = 'P0002'; end if;
  perform app.require_permission(inv.org_id, 'sales.post');
  if inv.status <> 'posted' then raise exception 'only a posted invoice can be voided' using errcode = '23514'; end if;

  if exists (select 1 from sales_returns where sales_invoice_id = p_invoice_id and status <> 'void' and void_of is null) then
    raise exception 'this invoice has a return that is not void yet — cancel the draft return or reverse the posted return first / لهذه الفاتورة مرجع لم يُلغَ بعد — يجب إلغاء المسودة أو عكس المرتجع المرحّل أولًا' using errcode = '23514';
  end if;

  v_move := create_stock_move(inv.org_id, 'adjustment_in', p_date, 'مرجع فاتورة مبيعات رقم ' || inv.invoice_no,
    (
      select jsonb_agg(jsonb_build_object(
        'item_id', sml.item_id, 'warehouse_id', sml.warehouse_id,
        'direction', 'in', 'entered_qty', sml.base_qty, 'unit_cost', sml.unit_cost))
      from stock_move_lines sml
      where sml.move_id = inv.stock_move_id and sml.direction = 'out'
    ),
    'sales_invoice_void', inv.id);
  perform post_stock_move(v_move);

  v_period := app.open_period_for(inv.org_id, p_date);
  insert into journal_entries (org_id, entry_no, entry_date, fiscal_period_id, description,
                                source_type, source_id, document_currency_id, created_by)
  values (inv.org_id, app.next_seq(inv.org_id, 'journal'), p_date, v_period,
          'إلغاء فاتورة مبيعات رقم ' || inv.invoice_no || coalesce(' — ' || p_reason, ''),
          'reversal', inv.journal_entry_id, inv.currency_id, auth.uid())
  returning id into v_entry;

  insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate, dealer_id)
  select v_entry, line_no, account_id, 'عكس: ' || description, credit, debit, currency_id, rate, dealer_id
  from journal_lines where entry_id = inv.journal_entry_id;

  update journal_entries set status = 'posted', posted_by = auth.uid(), posted_at = now() where id = v_entry;
  update journal_entries set status = 'void', reversed_by = v_entry, void_reason = p_reason where id = inv.journal_entry_id;

  insert into sales_invoices (org_id, invoice_no, invoice_date, dealer_id, warehouse_id, currency_id, rate,
                               payment_method, cash_account_id, description, due_date, journal_entry_id, stock_move_id,
                               void_of, status, created_by, posted_by, posted_at)
  values (inv.org_id, app.next_seq(inv.org_id, 'sales_invoice'), p_date, inv.dealer_id, inv.warehouse_id,
          inv.currency_id, inv.rate, inv.payment_method, inv.cash_account_id,
          'إلغاء فاتورة رقم ' || inv.invoice_no, p_date, v_entry, v_move, inv.id, 'posted', auth.uid(), auth.uid(), now())
  returning id into v_rev;

  update sales_invoices set status = 'void', reversed_by = v_rev, void_reason = p_reason where id = inv.id;

  return v_rev;
end;
$$;
