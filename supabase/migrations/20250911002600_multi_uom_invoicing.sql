-- ============================================================================
-- Rotopa · Modules 09/10/11 (continued) — multi-UOM at the invoice line level
--
-- Not a legacy replica either — an addition the user chose after comparing
-- against a parallel project. The foundation already existed from module 09
-- (`item_units` + `item_unit_to_base()`, used by stock_move_lines) but was
-- never wired into sales/purchase invoice lines — those only ever dealt in
-- the item's base unit. This finishes that wiring so someone can actually
-- sell/buy "2 كرتون" and have it correctly convert to base units for stock
-- and cost purposes, instead of only being able to type quantities in the
-- item's smallest unit.
--
-- Column split, same pattern stock_move_lines already uses: `qty` stays the
-- ENTERED quantity, in whatever unit the line's `unit_id` says (null = base
-- unit) — this is what revenue/cost-basis math (`line_total`) is naturally
-- expressed in, since that's the unit the price was quoted in. A new
-- `base_qty` column holds the same quantity converted to the item's base
-- unit — this is what stock and per-base-unit-cost math needs, since
-- `unit_cost` (wherever it's pulled from the stock engine) is ALWAYS
-- per-base-unit by that engine's own convention. Mixing the two up is
-- exactly the bug this migration has to route around at several existing
-- call sites below (marked explicitly).
-- ============================================================================

alter table sales_invoice_lines    add column unit_id uuid references item_units(id) on delete restrict;
alter table purchase_invoice_lines add column unit_id uuid references item_units(id) on delete restrict;
alter table sales_return_lines     add column unit_id uuid references item_units(id) on delete restrict;
alter table purchase_return_lines  add column unit_id uuid references item_units(id) on delete restrict;

alter table sales_invoice_lines    add column base_qty numeric(19,4);
alter table purchase_invoice_lines add column base_qty numeric(19,4);
alter table sales_return_lines     add column base_qty numeric(19,4);
alter table purchase_return_lines  add column base_qty numeric(19,4);

-- Backfill: every existing line has unit_id null (base unit, factor 1), so
-- base_qty = qty exactly. sales/purchase invoice lines have their own
-- BEFORE INSERT OR UPDATE validate trigger that rejects touching a line
-- once its invoice is posted — this backfill is a schema migration filling
-- in a column that didn't exist yet, not a runtime edit, so (like the
-- due_date backfill before it) it's the one legitimate place to step
-- around that guard. Return lines have no such trigger, so no need there.
alter table sales_invoice_lines    disable trigger sales_invoice_line_validate;
alter table purchase_invoice_lines disable trigger purchase_invoice_line_validate;

update sales_invoice_lines    set base_qty = qty where base_qty is null;
update purchase_invoice_lines set base_qty = qty where base_qty is null;
update sales_return_lines     set base_qty = qty where base_qty is null;
update purchase_return_lines  set base_qty = qty where base_qty is null;

alter table sales_invoice_lines    enable trigger sales_invoice_line_validate;
alter table purchase_invoice_lines enable trigger purchase_invoice_line_validate;

alter table sales_invoice_lines    alter column base_qty set not null;
alter table purchase_invoice_lines alter column base_qty set not null;
alter table sales_return_lines     alter column base_qty set not null;
alter table purchase_return_lines  alter column base_qty set not null;

alter table sales_invoice_lines    add constraint sales_invoice_lines_base_qty_positive    check (base_qty > 0);
alter table purchase_invoice_lines add constraint purchase_invoice_lines_base_qty_positive check (base_qty > 0);
alter table sales_return_lines     add constraint sales_return_lines_base_qty_positive     check (base_qty > 0);
alter table purchase_return_lines  add constraint purchase_return_lines_base_qty_positive  check (base_qty > 0);

-- ---------------------------------------------------------------------------
-- Line-validate triggers: check the unit actually belongs to the item, and
-- compute base_qty — same two responsibilities stock_move_lines' own
-- validate trigger already has for the exact same columns.
-- ---------------------------------------------------------------------------
create or replace function app.tg_sales_invoice_line_validate()
returns trigger language plpgsql as $$
declare inv sales_invoices%rowtype; it items%rowtype;
begin
  select * into inv from sales_invoices where id = new.invoice_id;
  if not found then raise exception 'invoice line references a missing invoice' using errcode = '23503'; end if;
  if inv.status <> 'draft' then
    raise exception 'invoice % is %; its lines are frozen', inv.invoice_no, inv.status using errcode = '23514';
  end if;
  new.org_id := inv.org_id;

  select * into it from items where id = new.item_id;
  if it.org_id <> inv.org_id then raise exception 'item belongs to a different organization' using errcode = '23503'; end if;
  if not it.is_active then raise exception 'item % is inactive', it.code using errcode = '23514'; end if;
  if not it.is_stock_tracked then raise exception 'item % does not track stock and cannot be sold this way yet', it.code using errcode = '23514'; end if;

  if new.unit_id is not null and (select item_id from item_units where id = new.unit_id) <> new.item_id then
    raise exception 'unit does not belong to this item' using errcode = '23514';
  end if;
  new.base_qty := item_unit_to_base(new.item_id, new.unit_id, new.qty);

  return new;
end;
$$;

create or replace function app.tg_purchase_invoice_line_validate()
returns trigger language plpgsql as $$
declare inv purchase_invoices%rowtype; it items%rowtype;
begin
  select * into inv from purchase_invoices where id = new.invoice_id;
  if not found then raise exception 'invoice line references a missing invoice' using errcode = '23503'; end if;
  if inv.status <> 'draft' then
    raise exception 'invoice % is %; its lines are frozen', inv.invoice_no, inv.status using errcode = '23514';
  end if;
  new.org_id := inv.org_id;

  select * into it from items where id = new.item_id;
  if it.org_id <> inv.org_id then raise exception 'item belongs to a different organization' using errcode = '23503'; end if;
  if not it.is_active then raise exception 'item % is inactive', it.code using errcode = '23514'; end if;
  if not it.is_stock_tracked then raise exception 'item % does not track stock and cannot be purchased this way yet', it.code using errcode = '23514'; end if;

  if new.unit_id is not null and (select item_id from item_units where id = new.unit_id) <> new.item_id then
    raise exception 'unit does not belong to this item' using errcode = '23514';
  end if;
  new.base_qty := item_unit_to_base(new.item_id, new.unit_id, new.qty);

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- create_sales_invoice / create_purchase_invoice: accept an optional
-- unit_id per line (same parameter list — jsonb line objects just grow an
-- optional key, so no drop/recreate needed, unlike a scalar parameter).
-- ---------------------------------------------------------------------------
create or replace function create_sales_invoice(
  p_org uuid, p_invoice_date date, p_dealer_id uuid, p_warehouse_id uuid,
  p_lines jsonb,   -- [{item_id, qty, unit_price, discount_pct, unit_id}]
  p_currency_id uuid default null, p_rate numeric default 1,
  p_payment_method text default 'credit', p_cash_account_id uuid default null,
  p_description text default '', p_due_date date default null
) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_invoice uuid; v_line jsonb; v_no int := 0;
  v_currency uuid; v_is_customer boolean;
begin
  perform app.require_permission(p_org, 'sales.write');

  select is_customer into v_is_customer from dealers where id = p_dealer_id and org_id = p_org;
  if v_is_customer is null then raise exception 'dealer not found in this organization' using errcode = '23503'; end if;
  if not v_is_customer then raise exception 'dealer is not marked as a customer' using errcode = '23514'; end if;

  v_currency := coalesce(p_currency_id, (select base_currency_id from organizations where id = p_org));

  insert into sales_invoices (org_id, invoice_no, invoice_date, dealer_id, warehouse_id, currency_id, rate,
                               payment_method, cash_account_id, description, due_date, created_by)
  values (p_org, app.next_seq(p_org, 'sales_invoice'), p_invoice_date, p_dealer_id, p_warehouse_id,
          v_currency, coalesce(p_rate, 1), coalesce(p_payment_method,'credit'), p_cash_account_id,
          coalesce(p_description,''), coalesce(p_due_date, p_invoice_date), auth.uid())
  returning id into v_invoice;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_no := v_no + 1;
    insert into sales_invoice_lines (invoice_id, line_no, item_id, qty, unit_price, discount_pct, unit_id)
    values (v_invoice, v_no, (v_line->>'item_id')::uuid,
            (v_line->>'qty')::numeric, (v_line->>'unit_price')::numeric,
            coalesce((v_line->>'discount_pct')::numeric, 0), (v_line->>'unit_id')::uuid);
  end loop;

  return v_invoice;
end;
$$;

create or replace function create_purchase_invoice(
  p_org uuid, p_invoice_date date, p_dealer_id uuid, p_warehouse_id uuid,
  p_lines jsonb,   -- [{item_id, qty, unit_price, discount_pct, unit_id}]
  p_currency_id uuid default null, p_rate numeric default 1,
  p_payment_method text default 'credit', p_cash_account_id uuid default null,
  p_description text default '', p_due_date date default null
) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_invoice uuid; v_line jsonb; v_no int := 0;
  v_currency uuid; v_is_supplier boolean;
begin
  perform app.require_permission(p_org, 'purchases.write');

  select is_supplier into v_is_supplier from dealers where id = p_dealer_id and org_id = p_org;
  if v_is_supplier is null then raise exception 'dealer not found in this organization' using errcode = '23503'; end if;
  if not v_is_supplier then raise exception 'dealer is not marked as a supplier' using errcode = '23514'; end if;

  v_currency := coalesce(p_currency_id, (select base_currency_id from organizations where id = p_org));

  insert into purchase_invoices (org_id, invoice_no, invoice_date, dealer_id, warehouse_id, currency_id, rate,
                                  payment_method, cash_account_id, description, due_date, created_by)
  values (p_org, app.next_seq(p_org, 'purchase_invoice'), p_invoice_date, p_dealer_id, p_warehouse_id,
          v_currency, coalesce(p_rate, 1), coalesce(p_payment_method,'credit'), p_cash_account_id,
          coalesce(p_description,''), coalesce(p_due_date, p_invoice_date), auth.uid())
  returning id into v_invoice;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_no := v_no + 1;
    insert into purchase_invoice_lines (invoice_id, line_no, item_id, qty, unit_price, discount_pct, unit_id)
    values (v_invoice, v_no, (v_line->>'item_id')::uuid,
            (v_line->>'qty')::numeric, (v_line->>'unit_price')::numeric,
            coalesce((v_line->>'discount_pct')::numeric, 0), (v_line->>'unit_id')::uuid);
  end loop;

  return v_invoice;
end;
$$;

-- ---------------------------------------------------------------------------
-- post_sales_invoice: pass the real unit through to the stock move (a nicer
-- audit trail there too — "2 كرتون" not "24 قطعة"), and switch COGS/
-- inventory math from qty (entered unit) to base_qty (what unit_cost, always
-- per-base-unit, actually prices).
-- ---------------------------------------------------------------------------
create or replace function post_sales_invoice(
  p_invoice_id uuid,
  p_default_sales_account_id uuid default null,
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

  v_move := create_stock_move(inv.org_id, 'sale_out', inv.invoice_date,
    'فاتورة مبيعات رقم ' || inv.invoice_no,
    (select jsonb_agg(jsonb_build_object(
        'item_id', l.item_id, 'warehouse_id', inv.warehouse_id,
        'direction', 'out', 'unit_id', l.unit_id, 'entered_qty', l.qty))
     from sales_invoice_lines l where l.invoice_id = p_invoice_id),
    'sales_invoice', inv.id);
  perform post_stock_move(v_move);

  -- pull the real costs back onto the invoice lines (unit_cost is always per base unit)
  update sales_invoice_lines sil
    set unit_cost = sml.unit_cost
  from stock_move_lines sml
  where sml.move_id = v_move and sml.item_id = sil.item_id and sil.invoice_id = p_invoice_id;

  v_period := app.open_period_for(inv.org_id, inv.invoice_date);
  select sum(line_total) into v_total from sales_invoice_lines where invoice_id = p_invoice_id;
  v_vat := round(v_total * app.vat_rate(), 4);

  insert into journal_entries (org_id, entry_no, entry_date, fiscal_period_id, description,
                                source_type, source_id, document_currency_id, created_by)
  values (inv.org_id, app.next_seq(inv.org_id, 'journal'), inv.invoice_date, v_period,
          coalesce(nullif(inv.description,''), 'فاتورة مبيعات رقم ' || inv.invoice_no),
          'sales_invoice', inv.id, inv.currency_id, auth.uid())
  returning id into v_entry;

  v_line_no := v_line_no + 1;
  insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate, dealer_id)
  select v_entry, v_line_no,
         case when inv.payment_method = 'cash' then inv.cash_account_id else d.account_id end,
         'فاتورة مبيعات رقم ' || inv.invoice_no, round((v_total + v_vat) * inv.rate, 4), 0, inv.currency_id, inv.rate,
         case when inv.payment_method = 'cash' then null else inv.dealer_id end
  from dealers d where d.id = inv.dealer_id;

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

  if v_vat > 0 then
    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    values (v_entry, v_line_no, p_output_vat_account_id, 'ضريبة قيمة مضافة على المبيعات', 0, round(v_vat * inv.rate, 4), inv.currency_id, inv.rate);
  end if;

  -- Dr COGS / Cr inventory at base_qty x unit_cost (unit_cost is per base unit — using
  -- entered qty here would silently overstate cost by the unit's conversion factor)
  for g in
    select it.cogs_account_id acc, sum(l.base_qty * l.unit_cost) amt
    from sales_invoice_lines l join items it on it.id = l.item_id
    where l.invoice_id = p_invoice_id
    group by it.cogs_account_id
  loop
    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    values (v_entry, v_line_no, g.acc, 'تكلفة البضاعة المباعة', round(g.amt, 4), 0, inv.currency_id, 1);
  end loop;
  for g in
    select it.inventory_account_id acc, sum(l.base_qty * l.unit_cost) amt
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

-- ---------------------------------------------------------------------------
-- void_sales_invoice: restock using base_qty directly (no unit_id) — it's
-- already the real base-unit quantity that left, so there's nothing left to
-- convert; re-deriving it from qty+unit_id a second time would just be the
-- same math run twice for no benefit.
-- ---------------------------------------------------------------------------
create or replace function void_sales_invoice(p_invoice_id uuid, p_date date, p_reason text default null)
returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  inv sales_invoices%rowtype;
  v_move uuid;
  v_entry uuid;
  v_period uuid;
  v_rev uuid;
  v_line_no int;
begin
  select * into inv from sales_invoices where id = p_invoice_id for update;
  if not found then raise exception 'invoice not found' using errcode = 'P0002'; end if;
  perform app.require_permission(inv.org_id, 'sales.post');
  if inv.status <> 'posted' then raise exception 'only a posted invoice can be voided' using errcode = '23514'; end if;

  v_move := create_stock_move(inv.org_id, 'adjustment_in', p_date, 'مرجع فاتورة مبيعات رقم ' || inv.invoice_no,
    (select jsonb_agg(jsonb_build_object(
        'item_id', l.item_id, 'warehouse_id', inv.warehouse_id,
        'direction', 'in', 'entered_qty', l.base_qty, 'unit_cost', l.unit_cost))
     from sales_invoice_lines l where l.invoice_id = p_invoice_id),
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

-- ---------------------------------------------------------------------------
-- post_purchase_invoice: pass the real unit through, and fix the unit_cost
-- fed to the stock engine — it MUST be per-base-unit, but line_total / qty
-- is per-ENTERED-unit (e.g. per carton). Dividing by base_qty instead is the
-- fix; this was silently wrong the moment any real carton-style unit got
-- used, masked until now because qty always equalled base_qty (factor 1).
-- ---------------------------------------------------------------------------
create or replace function post_purchase_invoice(p_invoice_id uuid, p_input_vat_account_id uuid default null)
returns uuid
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

  v_move := create_stock_move(inv.org_id, 'purchase_in', inv.invoice_date,
    'فاتورة مشتريات رقم ' || inv.invoice_no,
    (select jsonb_agg(jsonb_build_object(
        'item_id', l.item_id, 'warehouse_id', inv.warehouse_id,
        'direction', 'in', 'unit_id', l.unit_id, 'entered_qty', l.qty,
        'unit_cost', round(l.line_total / l.base_qty, 4)))
     from purchase_invoice_lines l where l.invoice_id = p_invoice_id),
    'purchase_invoice', inv.id);
  perform post_stock_move(v_move);

  v_period := app.open_period_for(inv.org_id, inv.invoice_date);
  select sum(line_total) into v_total from purchase_invoice_lines where invoice_id = p_invoice_id;
  v_vat := round(v_total * app.vat_rate(), 4);

  insert into journal_entries (org_id, entry_no, entry_date, fiscal_period_id, description,
                                source_type, source_id, document_currency_id, created_by)
  values (inv.org_id, app.next_seq(inv.org_id, 'journal'), inv.invoice_date, v_period,
          coalesce(nullif(inv.description,''), 'فاتورة مشتريات رقم ' || inv.invoice_no),
          'purchase_invoice', inv.id, inv.currency_id, auth.uid())
  returning id into v_entry;

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

  if v_vat > 0 then
    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    values (v_entry, v_line_no, p_input_vat_account_id, 'ضريبة قيمة مضافة على المشتريات', round(v_vat * inv.rate, 4), 0, inv.currency_id, inv.rate);
  end if;

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

-- ---------------------------------------------------------------------------
-- void_purchase_invoice: destock using base_qty directly, same reasoning as
-- void_sales_invoice above.
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- create_sales_return / create_purchase_return: a return always inherits
-- its unit from the ORIGINAL invoice line (no client-supplied unit_id) —
-- "returning 1 كرتون of the 3 كرتون sold" is the only sensible framing;
-- letting a return pick a different unit than the sale would make the
-- over-return check ambiguous (comparing quantities in different units).
-- ---------------------------------------------------------------------------
create or replace function create_sales_return(
  p_org uuid, p_sales_invoice_id uuid,
  p_lines jsonb,
  p_payment_method text default 'credit', p_cash_account_id uuid default null, p_description text default ''
) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  inv sales_invoices%rowtype;
  v_return uuid; v_line jsonb; v_no int := 0;
  v_item uuid; v_qty numeric; v_orig record; v_already numeric; v_base_qty numeric;
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
    v_item := (v_line->>'item_id')::uuid;
    v_qty := (v_line->>'qty')::numeric;

    select qty, unit_price, unit_cost, unit_id into v_orig
    from sales_invoice_lines where invoice_id = p_sales_invoice_id and item_id = v_item;
    if not found then raise exception 'item is not on the original invoice' using errcode = '23514'; end if;

    select coalesce(sum(l.qty), 0) into v_already
    from sales_return_lines l join sales_returns r on r.id = l.return_id
    where r.sales_invoice_id = p_sales_invoice_id and l.item_id = v_item and r.status = 'posted';
    if v_already + v_qty > v_orig.qty then
      raise exception 'cannot return % — only % of % remains returnable for this item', v_qty, v_orig.qty - v_already, v_orig.qty
        using errcode = '23514';
    end if;

    v_base_qty := item_unit_to_base(v_item, v_orig.unit_id, v_qty);
    insert into sales_return_lines (return_id, org_id, line_no, item_id, qty, unit_price, unit_cost, unit_id, base_qty)
    values (v_return, p_org, v_no, v_item, v_qty, v_orig.unit_price, v_orig.unit_cost, v_orig.unit_id, v_base_qty);
  end loop;

  return v_return;
end;
$$;

create or replace function create_purchase_return(
  p_org uuid, p_purchase_invoice_id uuid,
  p_lines jsonb,
  p_payment_method text default 'credit', p_cash_account_id uuid default null, p_description text default ''
) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  inv purchase_invoices%rowtype;
  v_return uuid; v_line jsonb; v_no int := 0;
  v_item uuid; v_qty numeric; v_orig record; v_already numeric; v_base_qty numeric;
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
    v_item := (v_line->>'item_id')::uuid;
    v_qty := (v_line->>'qty')::numeric;

    select qty, unit_price, unit_id into v_orig
    from purchase_invoice_lines where invoice_id = p_purchase_invoice_id and item_id = v_item;
    if not found then raise exception 'item is not on the original invoice' using errcode = '23514'; end if;

    select coalesce(sum(l.qty), 0) into v_already
    from purchase_return_lines l join purchase_returns r on r.id = l.return_id
    where r.purchase_invoice_id = p_purchase_invoice_id and l.item_id = v_item and r.status = 'posted';
    if v_already + v_qty > v_orig.qty then
      raise exception 'cannot return % — only % of % remains returnable for this item', v_qty, v_orig.qty - v_already, v_orig.qty
        using errcode = '23514';
    end if;

    v_base_qty := item_unit_to_base(v_item, v_orig.unit_id, v_qty);
    insert into purchase_return_lines (return_id, org_id, line_no, item_id, qty, unit_price, unit_id, base_qty)
    values (v_return, p_org, v_no, v_item, v_qty, v_orig.unit_price, v_orig.unit_id, v_base_qty);
  end loop;

  return v_return;
end;
$$;

-- ---------------------------------------------------------------------------
-- post_sales_return / void_sales_return / post_purchase_return /
-- void_purchase_return: same qty-vs-base_qty split applied throughout.
-- ---------------------------------------------------------------------------
create or replace function post_sales_return(
  p_return_id uuid,
  p_default_sales_account_id uuid default null,
  p_output_vat_account_id uuid default null
) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  r sales_returns%rowtype;
  v_move uuid; v_entry uuid; v_period uuid;
  v_line_no int := 0; v_total numeric(19,4); v_vat numeric(19,4);
  g record;
begin
  select * into r from sales_returns where id = p_return_id for update;
  if not found then raise exception 'return not found' using errcode = 'P0002'; end if;
  perform app.require_permission(r.org_id, 'sales.post');
  if r.status <> 'draft' then raise exception 'only a draft return can be posted (this one is %)', r.status using errcode = '23514'; end if;
  if not exists (select 1 from sales_return_lines where return_id = p_return_id) then
    raise exception 'return has no lines' using errcode = '23514';
  end if;
  if p_output_vat_account_id is null then
    raise exception 'an output VAT account is required to post a sales return' using errcode = '23514';
  end if;

  v_move := create_stock_move(r.org_id, 'adjustment_in', r.return_date,
    'مرجع فاتورة مبيعات — إشعار رقم ' || r.return_no,
    (select jsonb_agg(jsonb_build_object('item_id', l.item_id, 'warehouse_id', r.warehouse_id,
                                          'direction', 'in', 'unit_id', l.unit_id, 'entered_qty', l.qty, 'unit_cost', l.unit_cost))
     from sales_return_lines l where l.return_id = p_return_id),
    'sales_return', r.id);
  perform post_stock_move(v_move);

  select sum(line_total) into v_total from sales_return_lines where return_id = p_return_id;
  v_vat := round(v_total * app.vat_rate(), 4);

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

create or replace function void_sales_return(p_return_id uuid, p_date date, p_reason text default null)
returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  r sales_returns%rowtype; v_move uuid; v_entry uuid; v_period uuid; v_rev uuid;
begin
  select * into r from sales_returns where id = p_return_id for update;
  if not found then raise exception 'return not found' using errcode = 'P0002'; end if;
  perform app.require_permission(r.org_id, 'sales.post');
  if r.status <> 'posted' then raise exception 'only a posted return can be voided' using errcode = '23514'; end if;

  v_move := create_stock_move(r.org_id, 'adjustment_out', p_date, 'إلغاء مرجع مبيعات رقم ' || r.return_no,
    (select jsonb_agg(jsonb_build_object('item_id', l.item_id, 'warehouse_id', r.warehouse_id,
                                          'direction', 'out', 'entered_qty', l.base_qty))
     from sales_return_lines l where l.return_id = p_return_id),
    'sales_return_void', r.id);
  perform post_stock_move(v_move);

  v_period := app.open_period_for(r.org_id, p_date);
  insert into journal_entries (org_id, entry_no, entry_date, fiscal_period_id, description,
                                source_type, source_id, document_currency_id, created_by)
  values (r.org_id, app.next_seq(r.org_id, 'journal'), p_date, v_period,
          'إلغاء مرجع مبيعات رقم ' || r.return_no || coalesce(' — ' || p_reason, ''),
          'reversal', r.journal_entry_id, r.currency_id, auth.uid())
  returning id into v_entry;

  insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate, dealer_id)
  select v_entry, line_no, account_id, 'عكس: ' || description, credit, debit, currency_id, rate, dealer_id
  from journal_lines where entry_id = r.journal_entry_id;

  update journal_entries set status = 'posted', posted_by = auth.uid(), posted_at = now() where id = v_entry;
  update journal_entries set status = 'void', reversed_by = v_entry, void_reason = p_reason where id = r.journal_entry_id;

  insert into sales_returns (org_id, return_no, return_date, sales_invoice_id, dealer_id, warehouse_id,
                              currency_id, rate, payment_method, cash_account_id, description,
                              journal_entry_id, stock_move_id, void_of, status, created_by, posted_by, posted_at)
  values (r.org_id, app.next_seq(r.org_id, 'sales_return'), p_date, r.sales_invoice_id, r.dealer_id, r.warehouse_id,
          r.currency_id, r.rate, r.payment_method, r.cash_account_id, 'إلغاء مرجع رقم ' || r.return_no,
          v_entry, v_move, r.id, 'posted', auth.uid(), auth.uid(), now())
  returning id into v_rev;

  update sales_returns set status = 'void', reversed_by = v_rev, void_reason = p_reason where id = r.id;

  return v_rev;
end;
$$;

create or replace function post_purchase_return(p_return_id uuid, p_input_vat_account_id uuid default null)
returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  r purchase_returns%rowtype;
  v_move uuid; v_entry uuid; v_period uuid;
  v_line_no int := 0; v_total numeric(19,4); v_vat numeric(19,4);
  g record;
begin
  select * into r from purchase_returns where id = p_return_id for update;
  if not found then raise exception 'return not found' using errcode = 'P0002'; end if;
  perform app.require_permission(r.org_id, 'purchases.post');
  if r.status <> 'draft' then raise exception 'only a draft return can be posted (this one is %)', r.status using errcode = '23514'; end if;
  if not exists (select 1 from purchase_return_lines where return_id = p_return_id) then
    raise exception 'return has no lines' using errcode = '23514';
  end if;
  if p_input_vat_account_id is null then
    raise exception 'an input VAT account is required to post a purchase return' using errcode = '23514';
  end if;

  v_move := create_stock_move(r.org_id, 'adjustment_out', r.return_date, 'مرجع فاتورة مشتريات — إشعار رقم ' || r.return_no,
    (select jsonb_agg(jsonb_build_object('item_id', l.item_id, 'warehouse_id', r.warehouse_id,
                                          'direction', 'out', 'unit_id', l.unit_id, 'entered_qty', l.qty))
     from purchase_return_lines l where l.return_id = p_return_id),
    'purchase_return', r.id);
  perform post_stock_move(v_move);

  select sum(line_total) into v_total from purchase_return_lines where return_id = p_return_id;
  v_vat := round(v_total * app.vat_rate(), 4);

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

create or replace function void_purchase_return(p_return_id uuid, p_date date, p_reason text default null)
returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  r purchase_returns%rowtype; v_move uuid; v_entry uuid; v_period uuid; v_rev uuid;
begin
  select * into r from purchase_returns where id = p_return_id for update;
  if not found then raise exception 'return not found' using errcode = 'P0002'; end if;
  perform app.require_permission(r.org_id, 'purchases.post');
  if r.status <> 'posted' then raise exception 'only a posted return can be voided' using errcode = '23514'; end if;

  -- undo the removal: real receipt back in, at the return line's own
  -- commercial value divided by its base quantity — line_total/base_qty is
  -- exactly the same "per-base-unit cost from a total" derivation
  -- post_purchase_invoice() uses, not a new formula
  v_move := create_stock_move(r.org_id, 'adjustment_in', p_date, 'إلغاء مرجع مشتريات رقم ' || r.return_no,
    (select jsonb_agg(jsonb_build_object('item_id', l.item_id, 'warehouse_id', r.warehouse_id,
                                          'direction', 'in', 'unit_id', l.unit_id, 'entered_qty', l.qty,
                                          'unit_cost', round(l.line_total / l.base_qty, 4)))
     from purchase_return_lines l where l.return_id = p_return_id),
    'purchase_return_void', r.id);
  perform post_stock_move(v_move);

  v_period := app.open_period_for(r.org_id, p_date);
  insert into journal_entries (org_id, entry_no, entry_date, fiscal_period_id, description,
                                source_type, source_id, document_currency_id, created_by)
  values (r.org_id, app.next_seq(r.org_id, 'journal'), p_date, v_period,
          'إلغاء مرجع مشتريات رقم ' || r.return_no || coalesce(' — ' || p_reason, ''),
          'reversal', r.journal_entry_id, r.currency_id, auth.uid())
  returning id into v_entry;

  insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate, dealer_id)
  select v_entry, line_no, account_id, 'عكس: ' || description, credit, debit, currency_id, rate, dealer_id
  from journal_lines where entry_id = r.journal_entry_id;

  update journal_entries set status = 'posted', posted_by = auth.uid(), posted_at = now() where id = v_entry;
  update journal_entries set status = 'void', reversed_by = v_entry, void_reason = p_reason where id = r.journal_entry_id;

  insert into purchase_returns (org_id, return_no, return_date, purchase_invoice_id, dealer_id, warehouse_id,
                                 currency_id, rate, payment_method, cash_account_id, description,
                                 journal_entry_id, stock_move_id, void_of, status, created_by, posted_by, posted_at)
  values (r.org_id, app.next_seq(r.org_id, 'purchase_return'), p_date, r.purchase_invoice_id, r.dealer_id, r.warehouse_id,
          r.currency_id, r.rate, r.payment_method, r.cash_account_id, 'إلغاء مرجع رقم ' || r.return_no,
          v_entry, v_move, r.id, 'posted', auth.uid(), auth.uid(), now())
  returning id into v_rev;

  update purchase_returns set status = 'void', reversed_by = v_rev, void_reason = p_reason where id = r.id;

  return v_rev;
end;
$$;
