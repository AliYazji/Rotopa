-- ============================================================================
-- Rotopa · Module 09 (continued) — manufacturing / composite (assembled) items
--
-- No real replica here: checked the legacy backup directly (same discipline
-- as every other "addition" this project has made) — it HAS a manufacturing
-- concept (`OrderedmanufactureMasterTb`/`OrderedmanufactureDt`), but both
-- tables have ZERO rows in the real migrated data. Never actually used.
-- This is therefore a genuine new addition, built from scratch, not a port
-- of the legacy design (whose own column shape — Materials/ManPower/
-- Equipment/Subcontractor amounts AND percents per line — reads more like a
-- half-finished job-costing worksheet than a usable feature).
--
-- Scope, per explicit user request ("تصنيع بتكلفة تشغيل كاملة" — manufacturing
-- with full operating cost): a simple BOM (bill of materials) per finished
-- item, PLUS a manufacturing order that consumes the recipe's components and
-- produces the finished good, capitalizing not just material cost but also
-- manually-entered labor/equipment/subcontractor/other operating costs into
-- the finished good's unit cost.
--
-- Deliberately reuses the proven stock engine for BOTH legs (component
-- consumption AND finished-good production) via two ordinary
-- create_stock_move()/post_stock_move() calls — same "reuse the engine, add
-- a thin layer" principle as POS/sales-orders/every settlement-style
-- feature this project has built — rather than teaching post_stock_move()
-- new cross-item costing logic it was never designed for. Both calls pass
-- p_contra_account_id = null (stock-only, no per-move GL — the one
-- combined journal entry below is built directly, same as post_purchase_
-- invoice()/post_sales_invoice() already do for their own multi-line entries).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Permissions
-- ---------------------------------------------------------------------------
insert into permissions (key, module, description_ar, is_dangerous) values
  ('manufacturing.write', 'accounting', 'إنشاء وتعديل أوامر تصنيع مسودة وإدارة وصفات التصنيع (BOM)', false),
  ('manufacturing.post',  'accounting', 'ترحيل وإلغاء أوامر التصنيع', true)
on conflict (key) do nothing;

-- explicit begin/commit: set_config(...,true) is LOCAL to one transaction,
-- and outside an explicit BEGIN, psql/Postgres autocommits each top-level
-- statement as its OWN transaction — so without this wrapping, the 'on'
-- from the first statement would already be gone by the time the INSERTs
-- run (same root cause as the earlier is_local=false fix in the
-- concurrency test scripts this session; caught here by actually applying
-- this migration to the real dev DB, not by reasoning about it in advance).
begin;
select set_config('app.skip_role_guard', 'on', true);
insert into role_permissions (role_id, permission_key)
select r.id, p.key from roles r cross join permissions p
where r.code = 'owner' and p.key in ('manufacturing.write','manufacturing.post')
on conflict do nothing;
insert into role_permissions (role_id, permission_key)
select r.id, p.key from roles r cross join permissions p
where r.code = 'accountant' and p.key in ('manufacturing.write','manufacturing.post')
on conflict do nothing;
commit;

-- ---------------------------------------------------------------------------
-- Bill of materials — reference data, not a transaction. One row per
-- (finished item, component) pair; qty = how much of the component ONE
-- unit of the finished item needs.
-- ---------------------------------------------------------------------------
create table bom_lines (
  id                 uuid primary key default extensions.gen_random_uuid(),
  org_id             uuid not null references organizations(id) on delete cascade,
  finished_item_id   uuid not null references items(id) on delete cascade,
  component_item_id  uuid not null references items(id) on delete restrict,
  qty                numeric(19,6) not null check (qty > 0),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (finished_item_id, component_item_id),
  check (finished_item_id <> component_item_id)
);
create index on bom_lines (org_id, finished_item_id);

alter table bom_lines enable row level security;
create policy bom_select on bom_lines for select using (app.is_member(org_id));
create policy bom_write  on bom_lines for all
  using (app.has_permission(org_id, 'manufacturing.write'))
  with check (app.has_permission(org_id, 'manufacturing.write'));
create trigger set_updated_at before update on bom_lines for each row execute function app.tg_set_updated_at();
create trigger audit after insert or update or delete on bom_lines for each row execute function app.tg_audit();

-- ---------------------------------------------------------------------------
-- Manufacturing orders — draft → posted → void, same 3-state shape as
-- every invoice-like document in this project.
-- ---------------------------------------------------------------------------
create table manufacturing_orders (
  id                  uuid primary key default extensions.gen_random_uuid(),
  org_id              uuid not null references organizations(id) on delete restrict,
  order_no            bigint not null,
  order_date          date not null,
  finished_item_id    uuid not null references items(id) on delete restrict,
  warehouse_id        uuid not null references warehouses(id) on delete restrict,
  qty                 numeric(19,6) not null check (qty > 0),
  description         text not null default '',

  -- manually-entered operating costs, capitalized into the finished good's
  -- unit cost alongside the material cost — the "تكلفة تشغيل كاملة" the
  -- user explicitly asked for, distinct from the BOM's material quantities
  labor_cost          numeric(19,4) not null default 0 check (labor_cost >= 0),
  equipment_cost      numeric(19,4) not null default 0 check (equipment_cost >= 0),
  subcontractor_cost  numeric(19,4) not null default 0 check (subcontractor_cost >= 0),
  other_cost          numeric(19,4) not null default 0 check (other_cost >= 0),

  status              text not null default 'draft' check (status in ('draft','posted','void')),
  consumption_move_id uuid references stock_moves(id) on delete restrict,
  production_move_id  uuid references stock_moves(id) on delete restrict,
  journal_entry_id    uuid references journal_entries(id) on delete restrict,
  void_of             uuid references manufacturing_orders(id) on delete restrict,
  reversed_by         uuid references manufacturing_orders(id) on delete restrict,
  void_reason         text,

  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  posted_by  uuid references auth.users(id),
  posted_at  timestamptz,
  updated_at timestamptz not null default now(),
  unique (org_id, order_no)
);
create index on manufacturing_orders (org_id, status);

create table manufacturing_order_lines (
  id                 uuid primary key default extensions.gen_random_uuid(),
  order_id           uuid not null references manufacturing_orders(id) on delete cascade,
  org_id             uuid not null references organizations(id) on delete restrict,
  line_no            int not null,
  component_item_id  uuid not null references items(id) on delete restrict,
  qty                numeric(19,6) not null check (qty > 0),
  unit_cost          numeric(19,6),   -- backfilled at posting from the consumption move's real line cost
  unique (order_id, line_no)
);
create index on manufacturing_order_lines (order_id);

-- same combined shape as app.tg_sales_invoice_line_validate(): backfill
-- org_id, refuse touching a line once the order isn't draft, validate the
-- component reference — one trigger, not three
create or replace function app.tg_manufacturing_order_line_validate()
returns trigger language plpgsql as $$
declare o manufacturing_orders%rowtype; it items%rowtype;
begin
  select * into o from manufacturing_orders where id = new.order_id;
  if not found then raise exception 'manufacturing order line references a missing order' using errcode = '23503'; end if;
  if o.status <> 'draft' then
    raise exception 'manufacturing order % is %; its lines are frozen', o.order_no, o.status using errcode = '23514';
  end if;
  new.org_id := o.org_id;

  select * into it from items where id = new.component_item_id;
  if it.org_id <> o.org_id then raise exception 'component item belongs to a different organization' using errcode = '23503'; end if;
  if not it.is_active then raise exception 'item % is inactive', it.code using errcode = '23514'; end if;
  if not it.is_stock_tracked then raise exception 'item % does not track stock and cannot be a component', it.code using errcode = '23514'; end if;

  return new;
end;
$$;
create trigger manufacturing_order_line_validate
  before insert or update on manufacturing_order_lines
  for each row execute function app.tg_manufacturing_order_line_validate();

-- immutability once posted/void — same shape as app.tg_sales_invoice_guard
create or replace function app.tg_manufacturing_order_guard()
returns trigger language plpgsql as $$
begin
  if old.status = 'void' then raise exception 'a void manufacturing order cannot be modified' using errcode = '23514'; end if;
  if old.status = 'posted' then
    if new.status <> 'void'
       or new.org_id <> old.org_id or new.order_no <> old.order_no or new.order_date <> old.order_date
       or new.finished_item_id <> old.finished_item_id or new.warehouse_id <> old.warehouse_id or new.qty <> old.qty then
      raise exception 'a posted manufacturing order is immutable; reverse it with void_manufacturing_order()' using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;
create trigger manufacturing_order_guard before update on manufacturing_orders for each row execute function app.tg_manufacturing_order_guard();
create trigger block_delete_unless_draft before delete on manufacturing_orders for each row execute function app.tg_block_delete_unless_draft();

create trigger set_updated_at before update on manufacturing_orders for each row execute function app.tg_set_updated_at();
create trigger audit after insert or update or delete on manufacturing_orders for each row execute function app.tg_audit();
create trigger audit after insert or update or delete on manufacturing_order_lines for each row execute function app.tg_audit();

alter table manufacturing_orders enable row level security;
alter table manufacturing_order_lines enable row level security;

create policy mo_select on manufacturing_orders for select using (app.is_member(org_id));
create policy mo_write  on manufacturing_orders for all
  using (app.has_permission(org_id, 'manufacturing.write'))
  with check (app.has_permission(org_id, 'manufacturing.write'));
create policy mol_select on manufacturing_order_lines for select using (app.is_member(org_id));
create policy mol_write  on manufacturing_order_lines for all
  using (app.has_permission(org_id, 'manufacturing.write'))
  with check (app.has_permission(org_id, 'manufacturing.write'));

-- ---------------------------------------------------------------------------
-- create_manufacturing_order() — if p_lines is omitted, the item's own BOM
-- (scaled by p_qty) becomes the order's lines automatically; an explicit
-- p_lines overrides it (a real batch can legitimately use more/less/
-- different components than the recipe says).
-- ---------------------------------------------------------------------------
create or replace function create_manufacturing_order(
  p_org uuid, p_order_date date, p_finished_item_id uuid, p_warehouse_id uuid, p_qty numeric,
  p_lines jsonb default null,   -- [{component_item_id, qty}] — defaults to the item's BOM * p_qty
  p_description text default ''
) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_order uuid; v_line jsonb; v_no int := 0;
  v_lines jsonb;
begin
  perform app.require_permission(p_org, 'manufacturing.write');

  if p_lines is not null then
    v_lines := p_lines;
  else
    select jsonb_agg(jsonb_build_object('component_item_id', b.component_item_id, 'qty', b.qty * p_qty))
      into v_lines
    from bom_lines b where b.finished_item_id = p_finished_item_id;
  end if;
  if v_lines is null or jsonb_array_length(v_lines) = 0 then
    raise exception 'no bill of materials for this item and no lines were given explicitly' using errcode = '23514';
  end if;

  insert into manufacturing_orders (org_id, order_no, order_date, finished_item_id, warehouse_id, qty, description, created_by)
  values (p_org, app.next_seq(p_org, 'manufacturing_order'), p_order_date, p_finished_item_id, p_warehouse_id, p_qty,
          p_description, auth.uid())
  returning id into v_order;

  for v_line in select * from jsonb_array_elements(v_lines) loop
    v_no := v_no + 1;
    insert into manufacturing_order_lines (order_id, line_no, component_item_id, qty)
    values (v_order, v_no, (v_line->>'component_item_id')::uuid, (v_line->>'qty')::numeric);
  end loop;

  return v_order;
end;
$$;

-- ---------------------------------------------------------------------------
-- post_manufacturing_order() — consume components, produce the finished
-- good at (material + overhead)/qty, post one combined journal entry.
-- ---------------------------------------------------------------------------
create or replace function post_manufacturing_order(
  p_order_id uuid,
  p_labor_account_id uuid default null,
  p_equipment_account_id uuid default null,
  p_subcontractor_account_id uuid default null,
  p_other_account_id uuid default null
) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  o manufacturing_orders%rowtype;
  fin items%rowtype;
  v_consumption_move uuid; v_production_move uuid; v_entry uuid; v_period uuid;
  v_material_cost numeric(19,4);
  v_overhead_cost numeric(19,4);
  v_finished_unit_cost numeric(19,6);
  v_line_no int := 0;
  g record;
begin
  select * into o from manufacturing_orders where id = p_order_id for update;
  if not found then raise exception 'manufacturing order not found' using errcode = 'P0002'; end if;
  perform app.require_permission(o.org_id, 'manufacturing.post');
  if o.status <> 'draft' then
    raise exception 'only a draft manufacturing order can be posted (this one is %)', o.status using errcode = '23514';
  end if;
  if not exists (select 1 from manufacturing_order_lines where order_id = p_order_id) then
    raise exception 'manufacturing order has no lines' using errcode = '23514';
  end if;

  select * into fin from items where id = o.finished_item_id;

  v_overhead_cost := o.labor_cost + o.equipment_cost + o.subcontractor_cost + o.other_cost;
  if o.labor_cost > 0 and p_labor_account_id is null then raise exception 'a labor cost account is required — this order has a labor cost' using errcode = '23514'; end if;
  if o.equipment_cost > 0 and p_equipment_account_id is null then raise exception 'an equipment cost account is required — this order has an equipment cost' using errcode = '23514'; end if;
  if o.subcontractor_cost > 0 and p_subcontractor_account_id is null then raise exception 'a subcontractor cost account is required — this order has a subcontractor cost' using errcode = '23514'; end if;
  if o.other_cost > 0 and p_other_account_id is null then raise exception 'an other-cost account is required — this order has an other cost' using errcode = '23514'; end if;

  -- 1) consume the components — stock-only (no GL yet), at each component's
  --    own current moving average, exactly like any other adjustment_out
  v_consumption_move := create_stock_move(o.org_id, 'adjustment_out', o.order_date,
    'استهلاك مواد أمر تصنيع رقم ' || o.order_no,
    (select jsonb_agg(jsonb_build_object(
        'item_id', l.component_item_id, 'warehouse_id', o.warehouse_id,
        'direction', 'out', 'entered_qty', l.qty))
     from manufacturing_order_lines l where l.order_id = p_order_id),
    'manufacturing_order_consumption', o.id);
  perform post_stock_move(v_consumption_move);

  -- pull the real per-line cost back onto the order lines, same "backfill
  -- from the engine's own computed cost" pattern every other module uses
  update manufacturing_order_lines mol
    set unit_cost = sml.unit_cost
  from stock_move_lines sml
  where sml.move_id = v_consumption_move and sml.item_id = mol.component_item_id and mol.order_id = p_order_id;

  select sum(qty * unit_cost) into v_material_cost from manufacturing_order_lines where order_id = p_order_id;
  v_finished_unit_cost := round((v_material_cost + v_overhead_cost) / o.qty, 6);

  -- 2) produce the finished good — stock-only again, at the just-computed
  --    fully-loaded cost (material + operating costs, per unit)
  v_production_move := create_stock_move(o.org_id, 'adjustment_in', o.order_date,
    'إنتاج أمر تصنيع رقم ' || o.order_no,
    jsonb_build_array(jsonb_build_object(
      'item_id', o.finished_item_id, 'warehouse_id', o.warehouse_id,
      'direction', 'in', 'entered_qty', o.qty, 'unit_cost', v_finished_unit_cost)),
    'manufacturing_order_production', o.id);
  perform post_stock_move(v_production_move);

  -- 3) one combined journal entry: Dr finished-goods inventory for the
  --    fully-loaded cost, Cr each distinct component inventory account for
  --    material consumed from it, Cr each overhead account actually used
  v_period := app.open_period_for(o.org_id, o.order_date);
  insert into journal_entries (org_id, entry_no, entry_date, fiscal_period_id, description,
                                source_type, source_id, created_by)
  values (o.org_id, app.next_seq(o.org_id, 'journal'), o.order_date, v_period,
          coalesce(nullif(o.description,''), 'أمر تصنيع رقم ' || o.order_no),
          'manufacturing_order', o.id, auth.uid())
  returning id into v_entry;

  v_line_no := v_line_no + 1;
  insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
  select v_entry, v_line_no, fin.inventory_account_id, 'أمر تصنيع رقم ' || o.order_no,
         round(v_finished_unit_cost * o.qty, 4), 0, org.base_currency_id, 1
  from organizations org where org.id = o.org_id;

  for g in
    select it.inventory_account_id acc, sum(mol.qty * mol.unit_cost) amt
    from manufacturing_order_lines mol join items it on it.id = mol.component_item_id
    where mol.order_id = p_order_id
    group by it.inventory_account_id
  loop
    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    select v_entry, v_line_no, g.acc, 'مواد مستهلَكة — أمر تصنيع رقم ' || o.order_no,
           0, round(g.amt, 4), org.base_currency_id, 1
    from organizations org where org.id = o.org_id;
  end loop;

  if o.labor_cost > 0 then
    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    select v_entry, v_line_no, p_labor_account_id, 'تكلفة عمالة — أمر تصنيع رقم ' || o.order_no, 0, o.labor_cost, org.base_currency_id, 1
    from organizations org where org.id = o.org_id;
  end if;
  if o.equipment_cost > 0 then
    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    select v_entry, v_line_no, p_equipment_account_id, 'تكلفة معدات — أمر تصنيع رقم ' || o.order_no, 0, o.equipment_cost, org.base_currency_id, 1
    from organizations org where org.id = o.org_id;
  end if;
  if o.subcontractor_cost > 0 then
    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    select v_entry, v_line_no, p_subcontractor_account_id, 'تكلفة مقاولين — أمر تصنيع رقم ' || o.order_no, 0, o.subcontractor_cost, org.base_currency_id, 1
    from organizations org where org.id = o.org_id;
  end if;
  if o.other_cost > 0 then
    v_line_no := v_line_no + 1;
    insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
    select v_entry, v_line_no, p_other_account_id, 'تكاليف أخرى — أمر تصنيع رقم ' || o.order_no, 0, o.other_cost, org.base_currency_id, 1
    from organizations org where org.id = o.org_id;
  end if;

  update journal_entries set status = 'posted', posted_by = auth.uid(), posted_at = now() where id = v_entry;
  update manufacturing_orders set
    status = 'posted', consumption_move_id = v_consumption_move, production_move_id = v_production_move,
    journal_entry_id = v_entry, posted_by = auth.uid(), posted_at = now()
  where id = p_order_id;

  return v_entry;
end;
$$;

-- ---------------------------------------------------------------------------
-- void_manufacturing_order() — reverse both legs (give back components,
-- take back the finished good) and mirror the financial entry, same shape
-- as void_purchase_invoice()/void_sales_invoice().
-- ---------------------------------------------------------------------------
create or replace function void_manufacturing_order(p_order_id uuid, p_date date, p_reason text default null)
returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  o manufacturing_orders%rowtype;
  v_consumption_move uuid; v_production_move uuid; v_entry uuid; v_period uuid; v_rev uuid;
begin
  select * into o from manufacturing_orders where id = p_order_id for update;
  if not found then raise exception 'manufacturing order not found' using errcode = 'P0002'; end if;
  perform app.require_permission(o.org_id, 'manufacturing.post');
  if o.status <> 'posted' then raise exception 'only a posted manufacturing order can be voided' using errcode = '23514'; end if;

  -- give the components back (reverse of the original consumption)
  v_consumption_move := create_stock_move(o.org_id, 'adjustment_in', p_date, 'عكس استهلاك — أمر تصنيع رقم ' || o.order_no,
    (select jsonb_agg(jsonb_build_object(
        'item_id', l.component_item_id, 'warehouse_id', o.warehouse_id,
        'direction', 'in', 'entered_qty', l.qty, 'unit_cost', l.unit_cost))
     from manufacturing_order_lines l where l.order_id = p_order_id),
    'manufacturing_order_void_consumption', o.id);
  perform post_stock_move(v_consumption_move);

  -- take back the finished good, at whatever it's worth NOW (current moving
  -- average) — same "fails naturally if less remains than was produced"
  -- rule void_purchase_invoice() already relies on
  v_production_move := create_stock_move(o.org_id, 'adjustment_out', p_date, 'عكس إنتاج — أمر تصنيع رقم ' || o.order_no,
    jsonb_build_array(jsonb_build_object(
      'item_id', o.finished_item_id, 'warehouse_id', o.warehouse_id,
      'direction', 'out', 'entered_qty', o.qty)),
    'manufacturing_order_void_production', o.id);
  perform post_stock_move(v_production_move);

  -- mirror the original financial entry
  v_period := app.open_period_for(o.org_id, p_date);
  insert into journal_entries (org_id, entry_no, entry_date, fiscal_period_id, description,
                                source_type, source_id, created_by)
  values (o.org_id, app.next_seq(o.org_id, 'journal'), p_date, v_period,
          'إلغاء أمر تصنيع رقم ' || o.order_no || coalesce(' — ' || p_reason, ''),
          'reversal', o.journal_entry_id, auth.uid())
  returning id into v_entry;

  insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
  select v_entry, line_no, account_id, 'عكس: ' || description, credit, debit, currency_id, rate
  from journal_lines where entry_id = o.journal_entry_id;

  update journal_entries set status = 'posted', posted_by = auth.uid(), posted_at = now() where id = v_entry;
  update journal_entries set status = 'void', reversed_by = v_entry, void_reason = p_reason where id = o.journal_entry_id;

  insert into manufacturing_orders (org_id, order_no, order_date, finished_item_id, warehouse_id, qty, description,
                                     journal_entry_id, consumption_move_id, production_move_id,
                                     void_of, status, created_by, posted_by, posted_at)
  values (o.org_id, app.next_seq(o.org_id, 'manufacturing_order'), p_date, o.finished_item_id, o.warehouse_id, o.qty,
          'إلغاء أمر تصنيع رقم ' || o.order_no, v_entry, v_consumption_move, v_production_move,
          o.id, 'posted', auth.uid(), auth.uid(), now())
  returning id into v_rev;

  update manufacturing_orders set status = 'void', reversed_by = v_rev, void_reason = p_reason where id = o.id;

  return v_rev;
end;
$$;

revoke all on function create_manufacturing_order(uuid,date,uuid,uuid,numeric,jsonb,text) from public, anon;
revoke all on function post_manufacturing_order(uuid,uuid,uuid,uuid,uuid) from public, anon;
revoke all on function void_manufacturing_order(uuid,date,text) from public, anon;
grant execute on function create_manufacturing_order(uuid,date,uuid,uuid,numeric,jsonb,text) to authenticated;
grant execute on function post_manufacturing_order(uuid,uuid,uuid,uuid,uuid) to authenticated;
grant execute on function void_manufacturing_order(uuid,date,text) to authenticated;
