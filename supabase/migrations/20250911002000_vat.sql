-- ============================================================================
-- Rotopa · Module 17 — VAT (simple flat-rate version)
--
-- The legacy VAT tables (journal_invoice_tb, VATReport) have ZERO rows in
-- the real backup — Retaj never actually recorded VAT in the old system.
-- No real data to replicate "as-is" against, and building the legacy
-- report's full shape (selling/buying/reverse-charge/import/notes broken
-- out separately, 29 columns) with nothing to validate it against would be
-- guessing. User chose explicitly: a simple flat 16% on every invoice now,
-- no periodic VAT-return report yet — that's the deferred part, not this.
--
-- Standard VAT bookkeeping, added as one more leg to each invoice's
-- existing entry (not a new document type):
--   sales:    Dr AR/cash grows by the VAT (customer pays gross);
--             Cr output-VAT-payable for the VAT — a liability, since it's
--             owed to the tax authority, not revenue.
--   purchase: Dr input-VAT-recoverable for the VAT — an asset, reclaimable
--             against output VAT later; Cr AP/cash grows by the VAT.
-- Both keep the existing revenue/COGS/inventory legs computed on the
-- VAT-EXCLUSIVE subtotal, unchanged — VAT was never part of them.
--
-- void_sales_invoice()/void_purchase_invoice() need NO changes at all:
-- both already mirror-and-flip whatever lines the original entry has,
-- generically, so the new VAT leg reverses correctly for free.
-- ============================================================================

create or replace function app.vat_rate() returns numeric
language sql immutable as $$ select 0.16 $$;
comment on function app.vat_rate() is
  'Single flat rate for the whole system — no per-item exemption or reduced rate yet. One place to change if that becomes necessary.';

drop function if exists post_sales_invoice(uuid, uuid);
create or replace function post_sales_invoice(
  p_invoice_id uuid,
  p_default_sales_account_id uuid default null,   -- used only for an item missing its own sales_account_id
  p_output_vat_account_id uuid default null
) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  inv sales_invoices%rowtype;
  v_move uuid;
  v_entry uuid;
  v_period uuid;
  v_line_no int := 0;
  v_total numeric(19,4) := 0;
  v_vat numeric(19,4);
  g record;
begin
  select * into inv from sales_invoices where id = p_invoice_id for update;
  if not found then raise exception 'invoice not found' using errcode = 'P0002'; end if;
  perform app.require_permission(inv.org_id, 'sales.post');
  if inv.status <> 'draft' then
    raise exception 'only a draft invoice can be posted (this one is %)', inv.status using errcode = '23514';
  end if;
  if not exists (select 1 from sales_invoice_lines where invoice_id = p_invoice_id) then
    raise exception 'invoice has no lines' using errcode = '23514';
  end if;
  if p_output_vat_account_id is null then
    raise exception 'an output VAT account is required to post a sales invoice' using errcode = '23514';
  end if;

  -- 1) deduct stock at whatever it actually costs — the invoice's own
  --    unit_price never influences this. p_contra_account_id is left null:
  --    the invoice posts the complete inventory/COGS entry itself below.
  v_move := create_stock_move(inv.org_id, 'sale_out', inv.invoice_date,
    'فاتورة مبيعات رقم ' || inv.invoice_no,
    (select jsonb_agg(jsonb_build_object(
        'item_id', l.item_id, 'warehouse_id', inv.warehouse_id,
        'direction', 'out', 'entered_qty', l.qty))
     from sales_invoice_lines l where l.invoice_id = p_invoice_id),
    'sales_invoice', inv.id);
  perform post_stock_move(v_move);

  -- pull the real costs back onto the invoice lines
  update sales_invoice_lines sil
    set unit_cost = sml.unit_cost
  from stock_move_lines sml
  where sml.move_id = v_move and sml.item_id = sil.item_id and sil.invoice_id = p_invoice_id;

  -- 2) the financial entry
  v_period := app.open_period_for(inv.org_id, inv.invoice_date);
  select sum(line_total) into v_total from sales_invoice_lines where invoice_id = p_invoice_id;
  v_vat := round(v_total * app.vat_rate(), 4);

  insert into journal_entries (org_id, entry_no, entry_date, fiscal_period_id, description,
                                source_type, source_id, document_currency_id, created_by)
  values (inv.org_id, app.next_seq(inv.org_id, 'journal'), inv.invoice_date, v_period,
          coalesce(nullif(inv.description,''), 'فاتورة مبيعات رقم ' || inv.invoice_no),
          'sales_invoice', inv.id, inv.currency_id, auth.uid())
  returning id into v_entry;

  -- Dr AR (dealer) or Dr cash, for the invoice total INCLUDING VAT — the
  -- customer pays the gross amount, VAT and all
  v_line_no := v_line_no + 1;
  insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate, dealer_id)
  select v_entry, v_line_no,
         case when inv.payment_method = 'cash' then inv.cash_account_id else d.account_id end,
         'فاتورة مبيعات رقم ' || inv.invoice_no, round((v_total + v_vat) * inv.rate, 4), 0, inv.currency_id, inv.rate,
         case when inv.payment_method = 'cash' then null else inv.dealer_id end
  from dealers d where d.id = inv.dealer_id;

  -- Cr revenue, grouped by each item's sales account (falling back to the
  -- default) — at the VAT-EXCLUSIVE subtotal, same as before VAT existed
  for g in
    select coalesce(it.sales_account_id, p_default_sales_account_id) acc, sum(l.line_total) amt
    from sales_invoice_lines l join items it on it.id = l.item_id
    where l.invoice_id = p_invoice_id
    group by coalesce(it.sales_account_id, p_default_sales_account_id)
  loop
    if g.acc is null then
      raise exception 'an item on this invoice has no sales account and no default was given' using errcode = '23514';
    end if;
    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    values (v_entry, v_line_no, g.acc, 'مبيعات', 0, round(g.amt * inv.rate, 4), inv.currency_id, inv.rate);
  end loop;

  -- Cr output VAT payable — a liability owed to the tax authority, not revenue
  if v_vat > 0 then
    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    values (v_entry, v_line_no, p_output_vat_account_id, 'ضريبة قيمة مضافة على المبيعات', 0, round(v_vat * inv.rate, 4), inv.currency_id, inv.rate);
  end if;

  -- Dr COGS / Cr inventory, grouped by each item's own accounts, at the real cost just computed
  for g in
    select it.cogs_account_id acc, sum(l.qty * l.unit_cost) amt
    from sales_invoice_lines l join items it on it.id = l.item_id
    where l.invoice_id = p_invoice_id
    group by it.cogs_account_id
  loop
    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    values (v_entry, v_line_no, g.acc, 'تكلفة البضاعة المباعة', round(g.amt, 4), 0, inv.currency_id, 1);
  end loop;
  for g in
    select it.inventory_account_id acc, sum(l.qty * l.unit_cost) amt
    from sales_invoice_lines l join items it on it.id = l.item_id
    where l.invoice_id = p_invoice_id
    group by it.inventory_account_id
  loop
    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    values (v_entry, v_line_no, g.acc, 'تكلفة البضاعة المباعة', 0, round(g.amt, 4), inv.currency_id, 1);
  end loop;

  update journal_entries set status = 'posted', posted_by = auth.uid(), posted_at = now() where id = v_entry;
  update sales_invoices set status = 'posted', journal_entry_id = v_entry, stock_move_id = v_move,
                            posted_by = auth.uid(), posted_at = now()
    where id = p_invoice_id;

  return v_entry;
end;
$$;

drop function if exists post_purchase_invoice(uuid);
create or replace function post_purchase_invoice(
  p_invoice_id uuid,
  p_input_vat_account_id uuid default null
) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  inv purchase_invoices%rowtype;
  v_move uuid;
  v_entry uuid;
  v_period uuid;
  v_line_no int := 0;
  v_total numeric(19,4) := 0;
  v_vat numeric(19,4);
  g record;
begin
  select * into inv from purchase_invoices where id = p_invoice_id for update;
  if not found then raise exception 'invoice not found' using errcode = 'P0002'; end if;
  perform app.require_permission(inv.org_id, 'purchases.post');
  if inv.status <> 'draft' then
    raise exception 'only a draft invoice can be posted (this one is %)', inv.status using errcode = '23514';
  end if;
  if not exists (select 1 from purchase_invoice_lines where invoice_id = p_invoice_id) then
    raise exception 'invoice has no lines' using errcode = '23514';
  end if;
  if p_input_vat_account_id is null then
    raise exception 'an input VAT account is required to post a purchase invoice' using errcode = '23514';
  end if;

  -- 1) receive stock at exactly what the invoice says it cost — the line's
  --    net unit price (after its own discount) becomes the weighted-average
  --    engine's input cost, same value the GL entry below uses. VAT plays
  --    no part in the stock cost — it was never part of what the item is worth.
  v_move := create_stock_move(inv.org_id, 'purchase_in', inv.invoice_date,
    'فاتورة مشتريات رقم ' || inv.invoice_no,
    (select jsonb_agg(jsonb_build_object(
        'item_id', l.item_id, 'warehouse_id', inv.warehouse_id,
        'direction', 'in', 'entered_qty', l.qty, 'unit_cost', round(l.line_total / l.qty, 4)))
     from purchase_invoice_lines l where l.invoice_id = p_invoice_id),
    'purchase_invoice', inv.id);
  perform post_stock_move(v_move);

  -- 2) the financial entry
  v_period := app.open_period_for(inv.org_id, inv.invoice_date);
  select sum(line_total) into v_total from purchase_invoice_lines where invoice_id = p_invoice_id;
  v_vat := round(v_total * app.vat_rate(), 4);

  insert into journal_entries (org_id, entry_no, entry_date, fiscal_period_id, description,
                                source_type, source_id, document_currency_id, created_by)
  values (inv.org_id, app.next_seq(inv.org_id, 'journal'), inv.invoice_date, v_period,
          coalesce(nullif(inv.description,''), 'فاتورة مشتريات رقم ' || inv.invoice_no),
          'purchase_invoice', inv.id, inv.currency_id, auth.uid())
  returning id into v_entry;

  -- Dr inventory, grouped by each item's own inventory account, at the same
  -- VAT-EXCLUSIVE cost the stock move just recorded
  for g in
    select it.inventory_account_id acc, sum(l.line_total) amt
    from purchase_invoice_lines l join items it on it.id = l.item_id
    where l.invoice_id = p_invoice_id
    group by it.inventory_account_id
  loop
    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    values (v_entry, v_line_no, g.acc, 'فاتورة مشتريات رقم ' || inv.invoice_no, round(g.amt * inv.rate, 4), 0, inv.currency_id, inv.rate);
  end loop;

  -- Dr input VAT recoverable — an asset, reclaimable against output VAT later
  if v_vat > 0 then
    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    values (v_entry, v_line_no, p_input_vat_account_id, 'ضريبة قيمة مضافة على المشتريات', round(v_vat * inv.rate, 4), 0, inv.currency_id, inv.rate);
  end if;

  -- Cr AP (dealer) or Cr cash, for the invoice total INCLUDING VAT — the
  -- supplier is owed/paid the gross amount, VAT and all
  v_line_no := v_line_no + 1;
  insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate, dealer_id)
  select v_entry, v_line_no,
         case when inv.payment_method = 'cash' then inv.cash_account_id else d.account_id end,
         'فاتورة مشتريات رقم ' || inv.invoice_no, 0, round((v_total + v_vat) * inv.rate, 4), inv.currency_id, inv.rate,
         case when inv.payment_method = 'cash' then null else inv.dealer_id end
  from dealers d where d.id = inv.dealer_id;

  update journal_entries set status = 'posted', posted_by = auth.uid(), posted_at = now() where id = v_entry;
  update purchase_invoices set status = 'posted', journal_entry_id = v_entry, stock_move_id = v_move,
                               posted_by = auth.uid(), posted_at = now()
    where id = p_invoice_id;

  return v_entry;
end;
$$;

revoke all on function post_sales_invoice(uuid, uuid, uuid) from public, anon;
revoke all on function post_purchase_invoice(uuid, uuid) from public, anon;
grant execute on function post_sales_invoice(uuid, uuid, uuid) to authenticated;
grant execute on function post_purchase_invoice(uuid, uuid) to authenticated;
