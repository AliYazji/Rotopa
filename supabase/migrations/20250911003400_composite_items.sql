-- ============================================================================
-- Rotopa · Module 10 (continued) — composite items assembled AT SALE TIME
--
-- Different from module 09's manufacturing_orders (built earlier this same
-- session): that feature is BATCH production ahead of time — decide to
-- build N units, they sit in stock as a real item afterward. This is the
-- OTHER real pattern the user actually asked about next, with a concrete
-- example: "محقن بوظة" (an ice-cream cup) needs a scoop of ice cream + a
-- biscuit + toppings + a spoon, assembled the moment it's SOLD — the
-- composite item itself never sits in inventory at all; only its
-- components do.
--
-- Reuses bom_lines as-is (module 09) — a recipe is a recipe regardless of
-- whether it's fulfilled by a manufacturing order or by a sale.
--
-- IMPORTANT — these three functions (post_sales_invoice/void_sales_invoice/
-- create_sales_return) have EACH already been through 2-3 rounds of
-- `create or replace` by later migrations (VAT, due-dates+aging, multi-UOM
-- invoicing) since module 10 first created them. A first attempt at this
-- migration copied their ORIGINAL module-10 bodies as a base and would have
-- silently reverted every one of those — lost the VAT-required check, the
-- due_date column, and the whole base_qty/unit_id multi-UOM machinery.
-- Caught immediately by the full local test suite (20+ files failed, not
-- subtle at all) before this ever touched the real dev DB. Rewritten here
-- starting from the ACTUAL latest bodies (grepped every migration that
-- redefines each function, confirmed 20250911002600_multi_uom_invoicing.sql
-- is the true last one before this file) with composite-item handling
-- layered on top, not the other way around.
-- ============================================================================

alter table items add column is_composite boolean not null default false;
-- a composite item never carries its own stock ledger — same relaxation
-- is_stock_tracked=false already gives "service" items (no inventory/cogs
-- account required on the item itself; only its components' accounts matter)
alter table items add constraint items_composite_not_stock_tracked check (not is_composite or not is_stock_tracked);

comment on column items.is_composite is
  'Assembled from its bom_lines recipe at the moment of sale (post_sales_invoice/void_sales_invoice) — never has its own item_warehouse_balances row.';

-- ---------------------------------------------------------------------------
-- app.tg_sales_invoice_line_validate() previously rejected ANY non-stock-
-- tracked item outright — written for plain "service" items with no cost
-- basis at all, but a composite item is also is_stock_tracked=false while
-- still having a very real cost basis (via its recipe). Relaxed to let a
-- composite item through; a genuine non-composite service item is still
-- rejected exactly as before. Found by actually trying to create an
-- invoice line for a composite item in this migration's own test — not
-- something that could have been guessed from reading post_sales_invoice()
-- alone, since the block happens one layer earlier, at draft creation.
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
  if not it.is_stock_tracked and not it.is_composite then
    raise exception 'item % does not track stock and cannot be sold this way yet', it.code using errcode = '23514';
  end if;

  if new.unit_id is not null and (select item_id from item_units where id = new.unit_id) <> new.item_id then
    raise exception 'unit does not belong to this item' using errcode = '23514';
  end if;
  new.base_qty := item_unit_to_base(new.item_id, new.unit_id, new.qty);

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- How many could be sold right now, given current component stock — same
-- "available to promise" spirit as stock_reservations' own helper, just
-- computed from the recipe instead of from reservations.
-- ---------------------------------------------------------------------------
create or replace function item_composite_buildable_qty(p_item_id uuid, p_warehouse_id uuid)
returns numeric language sql stable as $$
  select floor(min(coalesce(iwb.qty, 0) / b.qty))
  from bom_lines b
  left join item_warehouse_balances iwb on iwb.item_id = b.component_item_id and iwb.warehouse_id = p_warehouse_id
  where b.finished_item_id = p_item_id;
$$;

-- ---------------------------------------------------------------------------
-- post_sales_invoice() — SAME signature/VAT/multi-UOM behavior as
-- 20250911002600_multi_uom_invoicing.sql for any invoice with no composite
-- lines. A composite line expands into its BOM components (scaled by its
-- OWN base_qty, so a composite item sold in a non-base unit still consumes
-- the right multiple of its recipe) instead of consuming its own stock.
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
  if exists (
    select 1 from sales_invoice_lines l join items it on it.id = l.item_id
    where l.invoice_id = p_invoice_id and it.is_composite
      and not exists (select 1 from bom_lines b where b.finished_item_id = it.id)
  ) then
    raise exception 'a composite item on this invoice has no recipe (bom_lines) defined' using errcode = '23514';
  end if;
  if exists (
    select 1 from sales_invoice_lines l join items it on it.id = l.item_id
    where l.invoice_id = p_invoice_id and it.is_composite and it.cogs_account_id is null
  ) then
    raise exception 'a composite item on this invoice has no COGS account set' using errcode = '23514';
  end if;

  -- composite lines' unit_cost (per ONE unit of the composite item) = sum
  -- (component qty needed for ONE unit * component's CURRENT moving-average
  -- cost) — bom_lines.qty is ALREADY "per one finished unit" (see its own
  -- table comment), so this is directly the per-unit cost, no division by
  -- base_qty (a real bug caught by this migration's own test: dividing by
  -- base_qty again understated a 5-cup line's COGS by a factor of 5,
  -- surfacing as a very literal "the journal entry doesn't balance" error
  -- — not a subtle miscalculation, the ledger itself refused to lie).
  -- Safe to read item_warehouse_balances.avg_cost either before or after
  -- the stock move below: an OUT movement never changes a weighted
  -- average, only an IN movement does (confirmed directly in module 09's
  -- own costing code) — no ordering hazard even when two composite lines
  -- on the same invoice share a component.
  update sales_invoice_lines sil set unit_cost = sub.unit_cost
  from (
    select l.id, sum(b.qty * coalesce(iwb.avg_cost, 0)) as unit_cost
    from sales_invoice_lines l
    join items it on it.id = l.item_id
    join bom_lines b on b.finished_item_id = l.item_id
    left join item_warehouse_balances iwb on iwb.item_id = b.component_item_id and iwb.warehouse_id = inv.warehouse_id
    where l.invoice_id = p_invoice_id and it.is_composite
    group by l.id, l.base_qty
  ) sub
  where sil.id = sub.id;

  -- 1) deduct stock — a normal line deducts itself (own unit_id/qty, exactly
  --    as before); a composite line expands into its BOM components instead,
  --    scaled by its own base_qty (it never had its own stock)
  v_move := create_stock_move(inv.org_id, 'sale_out', inv.invoice_date,
    'فاتورة مبيعات رقم ' || inv.invoice_no,
    (
      select jsonb_agg(x) from (
        select jsonb_build_object('item_id', l.item_id, 'warehouse_id', inv.warehouse_id,
                                   'direction', 'out', 'unit_id', l.unit_id, 'entered_qty', l.qty) as x
        from sales_invoice_lines l join items it on it.id = l.item_id
        where l.invoice_id = p_invoice_id and not it.is_composite
        union all
        select jsonb_build_object('item_id', b.component_item_id, 'warehouse_id', inv.warehouse_id,
                                   'direction', 'out', 'entered_qty', b.qty * l.base_qty) as x
        from sales_invoice_lines l join items it on it.id = l.item_id
        join bom_lines b on b.finished_item_id = l.item_id
        where l.invoice_id = p_invoice_id and it.is_composite
      ) combined
    ),
    'sales_invoice', inv.id);
  perform post_stock_move(v_move);

  -- pull the real costs back onto NON-composite lines only (unit_cost is
  -- always per base unit) — composite lines already got theirs above, they
  -- never appear in stock_move_lines under their own item_id
  update sales_invoice_lines sil
    set unit_cost = sml.unit_cost
  from stock_move_lines sml, items it
  where sml.move_id = v_move and sml.item_id = sil.item_id and sil.invoice_id = p_invoice_id
    and it.id = sil.item_id and not it.is_composite;

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

  -- Dr COGS, grouped by account, at base_qty x unit_cost (per-base-unit) —
  -- normal AND composite items both use their own cogs_account_id (a
  -- composite item needs one even though it has no inventory_account_id of
  -- its own; validated required above)
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

  -- Cr inventory — a normal line credits its own inventory account; a
  -- composite line credits EACH COMPONENT's inventory account instead, for
  -- exactly what this invoice consumed from it
  for g in
    select acc, sum(amt) amt from (
      select it.inventory_account_id acc, l.base_qty * l.unit_cost amt
      from sales_invoice_lines l join items it on it.id = l.item_id
      where l.invoice_id = p_invoice_id and not it.is_composite
      union all
      select ci.inventory_account_id acc, b.qty * l.base_qty * coalesce(iwb.avg_cost, 0) amt
      from sales_invoice_lines l join items it on it.id = l.item_id
      join bom_lines b on b.finished_item_id = l.item_id
      join items ci on ci.id = b.component_item_id
      left join item_warehouse_balances iwb on iwb.item_id = b.component_item_id and iwb.warehouse_id = inv.warehouse_id
      where l.invoice_id = p_invoice_id and it.is_composite
    ) x
    group by acc
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
-- void_sales_invoice() — SAME signature/due_date behavior. Restocks using
-- base_qty directly, same as the current version (already the real
-- base-unit quantity, nothing left to convert). A composite line's
-- components get restocked at THEIR OWN current average cost (no stored
-- per-component breakdown to trace back to) — same "restock at current
-- value" principle void_purchase_invoice() already uses when exact
-- historical tracing isn't the more correct choice.
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
begin
  select * into inv from sales_invoices where id = p_invoice_id for update;
  if not found then raise exception 'invoice not found' using errcode = 'P0002'; end if;
  perform app.require_permission(inv.org_id, 'sales.post');
  if inv.status <> 'posted' then raise exception 'only a posted invoice can be voided' using errcode = '23514'; end if;

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

-- ---------------------------------------------------------------------------
-- create_sales_return() — SAME signature/unit_id/base_qty behavior. Sales
-- returns of a composite item are explicitly NOT supported yet — no stored
-- per-component cost breakdown to restock against accurately, and
-- "returning" an assembled item (an eaten ice-cream cup) is a genuinely
-- different business question than returning a shelf item. Rejected with a
-- clear message rather than silently doing something approximate.
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
  v_item uuid; v_qty numeric; v_orig record; v_already numeric; v_base_qty numeric; v_is_composite boolean;
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

    select is_composite into v_is_composite from items where id = v_item;
    if v_is_composite then
      raise exception 'returning a composite item is not supported yet' using errcode = '23514';
    end if;

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

revoke all on function item_composite_buildable_qty(uuid,uuid) from public, anon;
grant execute on function item_composite_buildable_qty(uuid,uuid) to authenticated;
