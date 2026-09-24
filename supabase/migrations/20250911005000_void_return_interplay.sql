-- ============================================================================
-- Rotopa · Executive review remediation, Package 1 (2/2) — void_sales_invoice()/
-- void_purchase_invoice() must not be allowed to run out from under a
-- return that still references the invoice.
--
-- ROOT CAUSE: confirmed against the live code — neither function checked
-- for a related sales_returns/purchase_returns row at all, in draft OR
-- posted state.
--   * If a POSTED return already exists against the invoice (some qty
--     already physically/financially returned), voiding the invoice
--     still restocked/reversed the FULL ORIGINAL invoice quantity/amount
--     with no subtraction of what the return already restocked/reversed —
--     double-counting the returned portion (real stock/GL inflation).
--   * If a DRAFT return exists, voiding proceeded anyway, leaving an
--     orphaned draft pointing at a now-void invoice; nothing blocked
--     later posting that orphaned draft either — the previous migration
--     (20250911004900) closed that second half by having
--     post_sales_return()/post_purchase_return() lock and re-check the
--     original invoice's own status before posting.
--
-- POLICY (the safe one specified for this stage): voiding a sales/
-- purchase invoice is refused outright while it has ANY return that is
-- not itself void — draft or posted. The user must first cancel the
-- draft return (delete it — sales_return_lines/purchase_returns already
-- support deleting a draft) or reverse the posted return
-- (void_sales_return()/void_purchase_return()) through its own normal
-- operational path. This function never does either of those
-- automatically/silently on the caller's behalf.
--
-- One subtlety caught live while verifying this migration:
-- void_sales_return()/void_purchase_return() do not just flip the
-- original return row to status='void' — they ALSO insert a second,
-- brand-new "mirror" sales_returns/purchase_returns row (status='posted',
-- void_of = <the original return's id>) representing the reversal
-- itself, same pattern journal_entries/sales_invoices use for their own
-- voids. A plain `status <> 'void'` check treats that mirror row as
-- "still an active return", permanently blocking the invoice void even
-- after the return was properly reversed. Filtered out via
-- `void_of is null` — a real, non-reversal return never has void_of set;
-- only a void's own mirror row does.
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
      select jsonb_agg(x) from (
        select jsonb_build_object('item_id', l.item_id, 'warehouse_id', inv.warehouse_id,
                                   'direction', 'in', 'entered_qty', l.base_qty, 'unit_cost', l.unit_cost) as x
        from sales_invoice_lines l join items it on it.id = l.item_id
        where l.invoice_id = p_invoice_id and not it.is_composite
        union all
        select jsonb_build_object('item_id', b.component_item_id, 'warehouse_id', inv.warehouse_id, 'direction', 'in',
                                   'entered_qty', b.qty * l.base_qty, 'unit_cost', coalesce(iwb.avg_cost, 0)) as x
        from sales_invoice_lines l join items it on it.id = l.item_id
        join bom_lines b on b.finished_item_id = l.item_id
        left join item_warehouse_balances iwb on iwb.item_id = b.component_item_id and iwb.warehouse_id = inv.warehouse_id
        where l.invoice_id = p_invoice_id and it.is_composite
      ) combined
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

create or replace function void_purchase_invoice(p_invoice_id uuid, p_date date, p_reason text default null)
returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  inv purchase_invoices%rowtype;
  v_move uuid;
  v_entry uuid;
  v_period uuid;
  v_rev uuid;
begin
  select * into inv from purchase_invoices where id = p_invoice_id for update;
  if not found then raise exception 'invoice not found' using errcode = 'P0002'; end if;
  perform app.require_permission(inv.org_id, 'purchases.post');
  if inv.status <> 'posted' then raise exception 'only a posted invoice can be voided' using errcode = '23514'; end if;

  if exists (select 1 from purchase_returns where purchase_invoice_id = p_invoice_id and status <> 'void' and void_of is null) then
    raise exception 'this invoice has a return that is not void yet — cancel the draft return or reverse the posted return first / لهذه الفاتورة مرجع لم يُلغَ بعد — يجب إلغاء المسودة أو عكس المرتجع المرحّل أولًا' using errcode = '23514';
  end if;

  v_move := create_stock_move(inv.org_id, 'adjustment_out', p_date, 'مرجع فاتورة مشتريات رقم ' || inv.invoice_no,
    (select jsonb_agg(jsonb_build_object(
        'item_id', l.item_id, 'warehouse_id', inv.warehouse_id,
        'direction', 'out', 'entered_qty', l.base_qty))
     from purchase_invoice_lines l where l.invoice_id = p_invoice_id),
    'purchase_invoice_void', inv.id);
  perform post_stock_move(v_move);

  v_period := app.open_period_for(inv.org_id, p_date);
  insert into journal_entries (org_id, entry_no, entry_date, fiscal_period_id, description,
                                source_type, source_id, document_currency_id, created_by)
  values (inv.org_id, app.next_seq(inv.org_id, 'journal'), p_date, v_period,
          'إلغاء فاتورة مشتريات رقم ' || inv.invoice_no || coalesce(' — ' || p_reason, ''),
          'reversal', inv.journal_entry_id, inv.currency_id, auth.uid())
  returning id into v_entry;

  insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate, dealer_id)
  select v_entry, line_no, account_id, 'عكس: ' || description, credit, debit, currency_id, rate, dealer_id
  from journal_lines where entry_id = inv.journal_entry_id;

  update journal_entries set status = 'posted', posted_by = auth.uid(), posted_at = now() where id = v_entry;
  update journal_entries set status = 'void', reversed_by = v_entry, void_reason = p_reason where id = inv.journal_entry_id;

  insert into purchase_invoices (org_id, invoice_no, invoice_date, dealer_id, warehouse_id, currency_id, rate,
                                  payment_method, cash_account_id, description, due_date, journal_entry_id, stock_move_id,
                                  void_of, status, created_by, posted_by, posted_at)
  values (inv.org_id, app.next_seq(inv.org_id, 'purchase_invoice'), p_date, inv.dealer_id, inv.warehouse_id,
          inv.currency_id, inv.rate, inv.payment_method, inv.cash_account_id,
          'إلغاء فاتورة رقم ' || inv.invoice_no, p_date, v_entry, v_move, inv.id, 'posted', auth.uid(), auth.uid(), now())
  returning id into v_rev;

  update purchase_invoices set status = 'void', reversed_by = v_rev, void_reason = p_reason where id = inv.id;

  return v_rev;
end;
$$;
