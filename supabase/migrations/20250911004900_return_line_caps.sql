-- ============================================================================
-- Rotopa · Executive review remediation, Package 1 (1/2) — sales/purchase
-- returns must cap against the specific original invoice LINE, re-check at
-- post time (not just draft-creation time), and lock against concurrent
-- over-returning.
--
-- ROOT CAUSES (confirmed against the live code, not assumed):
--   1. sales_return_lines/purchase_return_lines only ever referenced
--      (invoice_id, item_id) — never the specific sales_invoice_lines/
--      purchase_invoice_lines row. If the same item legitimately appears
--      on two lines of one invoice (different price/discount), the
--      "already returned" cap pooled both lines' quantity together, and
--      the original unit_price/unit_cost/unit_id looked up for a new
--      return line came from whichever of the two rows Postgres happened
--      to pick (no line_no/id filter on that SELECT INTO).
--   2. The "already returned" cap was computed ONLY inside
--      create_sales_return()/create_purchase_return() (draft-creation
--      time), by summing OTHER returns already status='posted'. Draft
--      returns are invisible to that sum — post_sales_return()/
--      post_purchase_return() never re-validated it at all. Two drafts
--      each for the full sold quantity of the same line both pass the
--      draft-time check independently (neither sees the other, since
--      neither is posted yet), and both can then be posted, together
--      returning more than was ever sold. No FOR UPDATE lock existed
--      anywhere in this path either, so even a single-threaded but
--      out-of-order post sequence had no serialization point.
--
-- FIX:
--   * sales_return_lines/purchase_return_lines gain
--     sales_invoice_line_id/purchase_invoice_line_id, a real FK to the
--     specific original line. create_sales_return()/create_purchase_return()
--     now take {invoice_line_id, qty} instead of {item_id, qty} — the
--     line is looked up by its own id (deterministic, no ambiguity
--     possible), locked FOR UPDATE while reading it.
--   * post_sales_return()/post_purchase_return() now RE-CHECK the cap
--     themselves, at the real commit point, grouping this return's own
--     lines by sales_invoice_line_id first (so duplicate lines against
--     the same original line within one return are summed together, not
--     checked independently), locking each distinct original line FOR
--     UPDATE in a deterministic order (by id) to avoid a lock-ordering
--     deadlock between two concurrent posts touching overlapping lines,
--     then re-summing every OTHER posted return's qty against that same
--     line before allowing this post to proceed. This is the real
--     serialization point: whichever of two concurrent post_*_return()
--     calls against the same line reaches its FOR UPDATE first commits
--     first: the second correctly sees the first's now-posted quantity
--     once its own lock is granted, under Postgres's normal READ
--     COMMITTED re-read-after-lock-wait behavior, and is rejected if
--     that would exceed the line's remaining returnable quantity, under
--     ANY interleaving.
--   * post_sales_return()/post_purchase_return() also now read VAT from
--     the ORIGINAL invoice's frozen tax_rate (20250911004800_tax_snapshot.sql)
--     instead of a fresh app.vat_rate() call, and store their own
--     tax_rate/tax_amount.
--
-- Existing return_lines rows are backfilled to the specific original line
-- ONLY where it is unambiguous (exactly one original line for that
-- (invoice, item) pair) — see the backfill block below for why an
-- ambiguous historical row is left NULL rather than guessed, and why that
-- is safe (the new per-line cap only governs returns created through the
-- new code path from here on; it does not retroactively re-validate
-- historical data).
-- ============================================================================

alter table sales_return_lines add column sales_invoice_line_id uuid references sales_invoice_lines(id) on delete restrict;
create index on sales_return_lines (sales_invoice_line_id);

alter table purchase_return_lines add column purchase_invoice_line_id uuid references purchase_invoice_lines(id) on delete restrict;
create index on purchase_return_lines (purchase_invoice_line_id);

-- backfill: only where the (invoice, item) pair resolves to exactly one
-- original line -- the only case where the old, ambiguous design was
-- actually safe to begin with
update sales_return_lines srl
set sales_invoice_line_id = sil.id
from sales_returns sr, sales_invoice_lines sil
where srl.return_id = sr.id
  and sil.invoice_id = sr.sales_invoice_id
  and sil.item_id = srl.item_id
  and (select count(*) from sales_invoice_lines x where x.invoice_id = sr.sales_invoice_id and x.item_id = srl.item_id) = 1;

update purchase_return_lines prl
set purchase_invoice_line_id = pil.id
from purchase_returns pr, purchase_invoice_lines pil
where prl.return_id = pr.id
  and pil.invoice_id = pr.purchase_invoice_id
  and pil.item_id = prl.item_id
  and (select count(*) from purchase_invoice_lines x where x.invoice_id = pr.purchase_invoice_id and x.item_id = prl.item_id) = 1;

-- ---------------------------------------------------------------------------
-- create_sales_return() — same signature (uuid,uuid,jsonb,text,uuid,text) as
-- 20250911003400_composite_items.sql; p_lines items now shaped as
-- {invoice_line_id, qty} instead of {item_id, qty}.
-- ---------------------------------------------------------------------------
create or replace function create_sales_return(
  p_org uuid, p_sales_invoice_id uuid,
  p_lines jsonb,   -- [{invoice_line_id, qty}] — price/cost always looked up from the original invoice line, never client-supplied
  p_payment_method text default 'credit', p_cash_account_id uuid default null, p_description text default ''
) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  inv sales_invoices%rowtype;
  v_return uuid; v_line jsonb; v_no int := 0;
  v_invoice_line_id uuid; v_qty numeric; v_orig record; v_already numeric; v_base_qty numeric; v_is_composite boolean;
begin
  perform app.require_permission(p_org, 'sales.write');

  select * into inv from sales_invoices where id = p_sales_invoice_id and org_id = p_org;
  if not found then raise exception 'sales invoice not found in this organization' using errcode = '23503'; end if;
  if inv.status <> 'posted' then raise exception 'only a posted invoice can be returned against' using errcode = '23514'; end if;

  insert into sales_returns (org_id, return_no, return_date, sales_invoice_id, dealer_id, warehouse_id,
                              currency_id, rate, payment_method, cash_account_id, description, created_by)
  values (p_org, app.next_seq(p_org, 'sales_return'), current_date, p_sales_invoice_id, inv.dealer_id, inv.warehouse_id,
          inv.currency_id, inv.rate, coalesce(p_payment_method,'credit'), p_cash_account_id, coalesce(p_description,''), auth.uid())
  returning id into v_return;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_no := v_no + 1;
    v_invoice_line_id := (v_line->>'invoice_line_id')::uuid;
    v_qty := (v_line->>'qty')::numeric;

    select id, item_id, qty, unit_price, unit_cost, unit_id into v_orig
    from sales_invoice_lines where id = v_invoice_line_id and invoice_id = p_sales_invoice_id
    for update;
    if not found then raise exception 'invoice line not found on this invoice' using errcode = '23514'; end if;

    select is_composite into v_is_composite from items where id = v_orig.item_id;
    if v_is_composite then
      raise exception 'returning a composite item is not supported yet' using errcode = '23514';
    end if;

    select coalesce(sum(l.qty), 0) into v_already
    from sales_return_lines l join sales_returns r on r.id = l.return_id
    where l.sales_invoice_line_id = v_invoice_line_id and r.status = 'posted';
    if v_already + v_qty > v_orig.qty then
      raise exception 'cannot return % — only % of % remains returnable for this invoice line', v_qty, v_orig.qty - v_already, v_orig.qty
        using errcode = '23514';
    end if;

    v_base_qty := item_unit_to_base(v_orig.item_id, v_orig.unit_id, v_qty);
    insert into sales_return_lines (return_id, org_id, line_no, item_id, sales_invoice_line_id, qty, unit_price, unit_cost, unit_id, base_qty)
    values (v_return, p_org, v_no, v_orig.item_id, v_invoice_line_id, v_qty, v_orig.unit_price, v_orig.unit_cost, v_orig.unit_id, v_base_qty);
  end loop;

  return v_return;
end;
$$;

-- ---------------------------------------------------------------------------
-- post_sales_return() — same signature (uuid,uuid,uuid) as
-- 20250911003500_configurable_tax.sql. Body: re-checks the return cap at
-- the real commit point (grouped by original line, locked in id order),
-- and reads VAT from the original invoice's frozen tax_rate.
-- ---------------------------------------------------------------------------
create or replace function post_sales_return(
  p_return_id uuid,
  p_default_sales_account_id uuid default null,
  p_output_vat_account_id uuid default null
) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  r sales_returns%rowtype;
  inv sales_invoices%rowtype;
  v_move uuid; v_entry uuid; v_period uuid;
  v_line_no int := 0; v_total numeric(19,4); v_vat numeric(19,4);
  v_orig_qty numeric; v_already numeric;
  g record;
begin
  select * into r from sales_returns where id = p_return_id for update;
  if not found then raise exception 'return not found' using errcode = 'P0002'; end if;
  perform app.require_permission(r.org_id, 'sales.post');
  if r.status <> 'draft' then raise exception 'only a draft return can be posted (this one is %)', r.status using errcode = '23514'; end if;
  if not exists (select 1 from sales_return_lines where return_id = p_return_id) then
    raise exception 'return has no lines' using errcode = '23514';
  end if;

  -- lock the original invoice too — void_sales_invoice() also locks it
  -- FOR UPDATE, so this serializes a concurrent "void the invoice" against
  -- "post a return against it" (package 1, item 2 below builds the actual
  -- policy on top of this lock)
  select * into inv from sales_invoices where id = r.sales_invoice_id for update;
  if inv.status <> 'posted' then
    raise exception 'the original invoice is no longer posted (status: %) — this return can no longer be posted', inv.status
      using errcode = '23514';
  end if;

  -- re-validate the return cap here, at the real commit point — the
  -- draft-time check in create_sales_return() only ever compared against
  -- OTHER already-posted returns, so two drafts for the same line can
  -- both reach this point; this is what actually prevents both from
  -- posting. Group by original line first so duplicate lines against the
  -- same source line within THIS return are summed, not checked one at a
  -- time, and lock in a deterministic order (by line id) so two
  -- concurrent posts touching overlapping lines can never deadlock.
  for g in
    select sales_invoice_line_id, sum(qty) as qty
    from sales_return_lines
    where return_id = p_return_id
    group by sales_invoice_line_id
    order by sales_invoice_line_id
  loop
    select qty into v_orig_qty from sales_invoice_lines where id = g.sales_invoice_line_id for update;

    select coalesce(sum(l2.qty), 0) into v_already
    from sales_return_lines l2 join sales_returns r2 on r2.id = l2.return_id
    where l2.sales_invoice_line_id = g.sales_invoice_line_id and r2.status = 'posted' and r2.id <> p_return_id;

    if v_already + g.qty > v_orig_qty then
      raise exception 'cannot post this return — only % of % remains returnable for invoice line % (another return against it was posted first)',
        v_orig_qty - v_already, v_orig_qty, g.sales_invoice_line_id
        using errcode = '23514';
    end if;
  end loop;

  select sum(line_total) into v_total from sales_return_lines where return_id = p_return_id;
  v_vat := round(v_total * inv.tax_rate, 4);
  if v_vat > 0 and p_output_vat_account_id is null then
    raise exception 'an output VAT account is required to post a sales return' using errcode = '23514';
  end if;

  update sales_returns set tax_rate = inv.tax_rate, tax_amount = v_vat where id = p_return_id;

  v_move := create_stock_move(r.org_id, 'adjustment_in', r.return_date,
    'مرجع فاتورة مبيعات — إشعار رقم ' || r.return_no,
    (select jsonb_agg(jsonb_build_object('item_id', l.item_id, 'warehouse_id', r.warehouse_id,
                                          'direction', 'in', 'unit_id', l.unit_id, 'entered_qty', l.qty, 'unit_cost', l.unit_cost))
     from sales_return_lines l where l.return_id = p_return_id),
    'sales_return', r.id);
  perform post_stock_move(v_move);

  v_period := app.open_period_for(r.org_id, r.return_date);
  insert into journal_entries (org_id, entry_no, entry_date, fiscal_period_id, description,
                                source_type, source_id, document_currency_id, created_by)
  values (r.org_id, app.next_seq(r.org_id, 'journal'), r.return_date, v_period,
          coalesce(nullif(r.description,''), 'إشعار مرجع مبيعات رقم ' || r.return_no), 'sales_return', r.id, r.currency_id, auth.uid())
  returning id into v_entry;

  v_line_no := v_line_no + 1;
  insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate, dealer_id)
  select v_entry, v_line_no,
         case when r.payment_method = 'cash' then r.cash_account_id else d.account_id end,
         'مرجع مبيعات رقم ' || r.return_no, 0, round((v_total + v_vat) * r.rate, 4), r.currency_id, r.rate,
         case when r.payment_method = 'cash' then null else r.dealer_id end
  from dealers d where d.id = r.dealer_id;

  for g in
    select coalesce(it.sales_account_id, p_default_sales_account_id) acc, sum(l.line_total) amt
    from sales_return_lines l join items it on it.id = l.item_id
    where l.return_id = p_return_id
    group by coalesce(it.sales_account_id, p_default_sales_account_id)
  loop
    if g.acc is null then raise exception 'an item on this return has no sales account and no default was given' using errcode = '23514'; end if;
    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    values (v_entry, v_line_no, g.acc, 'مرجع مبيعات', round(g.amt * r.rate, 4), 0, r.currency_id, r.rate);
  end loop;

  if v_vat > 0 then
    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    values (v_entry, v_line_no, p_output_vat_account_id, 'عكس ضريبة مخرجات — مرجع مبيعات', round(v_vat * r.rate, 4), 0, r.currency_id, r.rate);
  end if;

  for g in
    select it.cogs_account_id acc, sum(l.base_qty * l.unit_cost) amt
    from sales_return_lines l join items it on it.id = l.item_id
    where l.return_id = p_return_id group by it.cogs_account_id
  loop
    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    values (v_entry, v_line_no, g.acc, 'عكس تكلفة البضاعة المباعة — مرجع', 0, round(g.amt, 4), r.currency_id, 1);
  end loop;
  for g in
    select it.inventory_account_id acc, sum(l.base_qty * l.unit_cost) amt
    from sales_return_lines l join items it on it.id = l.item_id
    where l.return_id = p_return_id group by it.inventory_account_id
  loop
    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    values (v_entry, v_line_no, g.acc, 'إعادة للمخزون — مرجع', round(g.amt, 4), 0, r.currency_id, 1);
  end loop;

  update journal_entries set status = 'posted', posted_by = auth.uid(), posted_at = now() where id = v_entry;
  update sales_returns set status = 'posted', journal_entry_id = v_entry, stock_move_id = v_move,
                           posted_by = auth.uid(), posted_at = now() where id = p_return_id;

  return v_entry;
end;
$$;

-- ---------------------------------------------------------------------------
-- create_purchase_return()/post_purchase_return() — same shape of change,
-- mirrored.
-- ---------------------------------------------------------------------------
create or replace function create_purchase_return(
  p_org uuid, p_purchase_invoice_id uuid,
  p_lines jsonb,   -- [{invoice_line_id, qty}]
  p_payment_method text default 'credit', p_cash_account_id uuid default null, p_description text default ''
) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  inv purchase_invoices%rowtype;
  v_return uuid; v_line jsonb; v_no int := 0;
  v_invoice_line_id uuid; v_qty numeric; v_orig record; v_already numeric; v_base_qty numeric;
begin
  perform app.require_permission(p_org, 'purchases.write');

  select * into inv from purchase_invoices where id = p_purchase_invoice_id and org_id = p_org;
  if not found then raise exception 'purchase invoice not found in this organization' using errcode = '23503'; end if;
  if inv.status <> 'posted' then raise exception 'only a posted invoice can be returned against' using errcode = '23514'; end if;

  insert into purchase_returns (org_id, return_no, return_date, purchase_invoice_id, dealer_id, warehouse_id,
                                 currency_id, rate, payment_method, cash_account_id, description, created_by)
  values (p_org, app.next_seq(p_org, 'purchase_return'), current_date, p_purchase_invoice_id, inv.dealer_id, inv.warehouse_id,
          inv.currency_id, inv.rate, coalesce(p_payment_method,'credit'), p_cash_account_id, coalesce(p_description,''), auth.uid())
  returning id into v_return;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_no := v_no + 1;
    v_invoice_line_id := (v_line->>'invoice_line_id')::uuid;
    v_qty := (v_line->>'qty')::numeric;

    select id, item_id, qty, unit_price, unit_id into v_orig
    from purchase_invoice_lines where id = v_invoice_line_id and invoice_id = p_purchase_invoice_id
    for update;
    if not found then raise exception 'invoice line not found on this invoice' using errcode = '23514'; end if;

    select coalesce(sum(l.qty), 0) into v_already
    from purchase_return_lines l join purchase_returns r on r.id = l.return_id
    where l.purchase_invoice_line_id = v_invoice_line_id and r.status = 'posted';
    if v_already + v_qty > v_orig.qty then
      raise exception 'cannot return % — only % of % remains returnable for this invoice line', v_qty, v_orig.qty - v_already, v_orig.qty
        using errcode = '23514';
    end if;

    v_base_qty := item_unit_to_base(v_orig.item_id, v_orig.unit_id, v_qty);
    insert into purchase_return_lines (return_id, org_id, line_no, item_id, purchase_invoice_line_id, qty, unit_price, unit_id, base_qty)
    values (v_return, p_org, v_no, v_orig.item_id, v_invoice_line_id, v_qty, v_orig.unit_price, v_orig.unit_id, v_base_qty);
  end loop;

  return v_return;
end;
$$;

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
    select it.inventory_account_id acc, sum(l.line_total) amt
    from purchase_return_lines l join items it on it.id = l.item_id
    where l.return_id = p_return_id group by it.inventory_account_id
  loop
    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    values (v_entry, v_line_no, g.acc, 'مرجع مشتريات', 0, round(g.amt * r.rate, 4), r.currency_id, r.rate);
  end loop;

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

grant execute on function create_sales_return(uuid,uuid,jsonb,text,uuid,text) to authenticated;
grant execute on function post_sales_return(uuid,uuid,uuid) to authenticated;
grant execute on function create_purchase_return(uuid,uuid,jsonb,text,uuid,text) to authenticated;
grant execute on function post_purchase_return(uuid,uuid) to authenticated;
