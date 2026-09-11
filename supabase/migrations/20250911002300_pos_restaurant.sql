-- ============================================================================
-- Rotopa · Module 16 — Restaurant / POS (outlets, tables, captain-order)
--
-- Built ahead of the legacy screenshots, same as module 15 (user: "جرب إنت
-- كمل الباقي وإن توفرت الصور بأبعتها و بتقارن") — from the plan's own
-- description ("المنافذ والطاولات، شاشة الكاشير وكابتن أوردر، طابعات المطبخ
-- حسب التصنيف، وترحيل مبيعات اليوم عند الإقفال") plus standard restaurant-
-- POS practice. Expect revision once the real PointOfSalesTb/
-- outlet_tabel_tb/CabtenOrdersCashier screens are seen.
--
-- The earlier PosCheckout.tsx page (web only, no migration) is explicitly
-- NOT this module — it is a fast, one-shot "pick items, pay immediately,
-- post" cashier screen with no concept of a table or an order that stays
-- open while more items get added over time. THIS module adds exactly
-- that: a "captain" opens an order against a table, adds items as the
-- guest orders more over the course of the visit, and only at the end does
-- a cashier settle it — which is the point where it becomes a real
-- sales_invoice, reusing create_sales_invoice()/post_sales_invoice()
-- (modules 10 + 17) exactly the way PosCheckout.tsx already does. No new
-- posting logic was written for money — only for accumulating an order
-- before it becomes one.
--
-- Design decisions worth recording:
--   * "ترحيل مبيعات اليوم عند الإقفال" (posting the day's sales at close) —
--     the legacy description reads like a single end-of-day batch JV. NOT
--     implemented that way here, on purpose: every settlement already
--     posts its own real sales_invoice immediately (same as PosCheckout),
--     consistent with everything else in this rebuild and already tested
--     in production use. There is no deferred "close the day" GL step to
--     build — flagging this explicitly as a deliberate deviation to
--     compare against the real legacy behavior once seen, not an oversight.
--   * "طابعات المطبخ حسب التصنيف" (kitchen printers by category) — added
--     as DATA only (item_categories.kitchen_station, a plain label like
--     'المطبخ'/'البار') so an order screen can group items by station for
--     the captain's own reference. Actually driving a physical kitchen
--     printer needs native OS/USB integration a web app cannot reach —
--     genuinely out of scope here, not a gap to silently paper over.
--   * A table's occupied/free status is a simple current flag (unlike
--     rooms, a table has no future-dated booking concept in this design —
--     restaurant seating is walk-up, not reserved by date range).
-- ============================================================================

create table outlets (
  id            uuid primary key default extensions.gen_random_uuid(),
  org_id        uuid not null references organizations(id) on delete restrict,
  code          text not null,
  name_ar       text not null,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (org_id, code)
);

create table pos_tables (
  id            uuid primary key default extensions.gen_random_uuid(),
  org_id        uuid not null references organizations(id) on delete restrict,
  outlet_id     uuid not null references outlets(id) on delete restrict,
  table_no      text not null,
  seats         int,
  status        text not null default 'free' check (status in ('free','occupied','reserved')),
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (org_id, outlet_id, table_no)
);

-- item_categories already exists (module 09/01) — kitchen routing is one
-- more label on it, not a new table; null = no specific station.
alter table item_categories add column kitchen_station text;

create table pos_orders (
  id            uuid primary key default extensions.gen_random_uuid(),
  org_id        uuid not null references organizations(id) on delete restrict,
  order_no      bigint not null,
  outlet_id     uuid not null references outlets(id) on delete restrict,
  table_id      uuid references pos_tables(id) on delete restrict,   -- null = takeaway, no table
  warehouse_id  uuid not null references warehouses(id) on delete restrict,
  guest_count   int,
  status        text not null default 'open' check (status in ('open','settled','cancelled')),
  notes         text not null default '',
  cancel_reason text,
  sales_invoice_id uuid references sales_invoices(id) on delete restrict,
  opened_by     uuid references auth.users(id),
  opened_at     timestamptz not null default now(),
  settled_at    timestamptz,
  updated_at    timestamptz not null default now(),
  unique (org_id, order_no),
  constraint pos_order_settled_has_invoice check (status <> 'settled' or sales_invoice_id is not null)
);
create index on pos_orders (org_id, status);
create index on pos_orders (org_id, table_id);

create table pos_order_lines (
  id            uuid primary key default extensions.gen_random_uuid(),
  order_id      uuid not null references pos_orders(id) on delete cascade,
  org_id        uuid not null references organizations(id) on delete restrict,
  line_no       int not null,
  item_id       uuid not null references items(id) on delete restrict,
  qty           numeric(19,4) not null check (qty > 0),
  unit_price    numeric(19,4) not null check (unit_price >= 0),
  line_total    numeric(19,4) generated always as (round(qty * unit_price, 4)) stored,
  notes         text not null default '',
  created_at    timestamptz not null default now(),
  unique (order_id, line_no)
);
create index on pos_order_lines (order_id);

-- ---------------------------------------------------------------------------
-- Guards — same shape as sales_invoice_lines/sales_invoices
-- ---------------------------------------------------------------------------
create or replace function app.tg_pos_order_line_validate()
returns trigger language plpgsql as $$
declare o pos_orders%rowtype; it items%rowtype;
begin
  select * into o from pos_orders where id = new.order_id;
  if not found then raise exception 'order line references a missing order' using errcode = '23503'; end if;
  if o.status <> 'open' then raise exception 'order % is %; its lines are frozen', o.order_no, o.status using errcode = '23514'; end if;
  new.org_id := o.org_id;

  select * into it from items where id = new.item_id;
  if it.org_id <> o.org_id then raise exception 'item belongs to a different organization' using errcode = '23503'; end if;
  if not it.is_active then raise exception 'item % is inactive', it.code using errcode = '23514'; end if;

  return new;
end;
$$;
create trigger pos_order_line_validate
  before insert or update on pos_order_lines
  for each row execute function app.tg_pos_order_line_validate();

create or replace function app.tg_pos_order_line_frozen()
returns trigger language plpgsql as $$
declare v_status text;
begin
  select status into v_status from pos_orders where id = old.order_id;
  if v_status <> 'open' then raise exception 'order is %; lines cannot be removed', v_status using errcode = '23514'; end if;
  return old;
end;
$$;
create trigger pos_order_line_frozen_del
  before delete on pos_order_lines
  for each row execute function app.tg_pos_order_line_frozen();

create or replace function app.tg_pos_order_guard()
returns trigger language plpgsql as $$
begin
  -- once no longer 'open', only `notes` may still change (cosmetic); every
  -- other field — including status itself — is frozen for a client update.
  -- The settle/cancel RPCs above always transition FROM 'open', so they
  -- never hit this branch at all.
  if old.status <> 'open' then
    if new.status <> old.status
       or new.org_id <> old.org_id or new.order_no <> old.order_no
       or new.outlet_id <> old.outlet_id or new.table_id is distinct from old.table_id
       or new.warehouse_id <> old.warehouse_id
       or new.sales_invoice_id is distinct from old.sales_invoice_id
       or new.opened_by is distinct from old.opened_by or new.opened_at <> old.opened_at
       or new.settled_at is distinct from old.settled_at
       or new.guest_count is distinct from old.guest_count
       or new.cancel_reason is distinct from old.cancel_reason then
      raise exception 'a % order cannot be modified except by the settle/cancel actions', old.status using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;
create trigger pos_order_guard before update on pos_orders for each row execute function app.tg_pos_order_guard();

create trigger set_updated_at before update on outlets for each row execute function app.tg_set_updated_at();
create trigger set_updated_at before update on pos_tables for each row execute function app.tg_set_updated_at();
create trigger set_updated_at before update on pos_orders for each row execute function app.tg_set_updated_at();
create trigger audit after insert or update or delete on pos_orders for each row execute function app.tg_audit();

-- extend the shared delete-guard with this module's own "draft-equivalent"
-- status, same pattern already used for cheques' 'in_hand'
create or replace function app.tg_block_delete_unless_draft()
returns trigger language plpgsql as $$
declare v_deletable boolean;
begin
  v_deletable := case
    when tg_table_name = 'cheques' then old.status = 'in_hand'
    when tg_table_name = 'pos_orders' then old.status = 'open'
    else old.status = 'draft'
  end;
  if not v_deletable then
    raise exception '% % is % and cannot be deleted — use void/cancel instead', tg_table_name, old.id, old.status
      using errcode = '23514';
  end if;
  return old;
end;
$$;
create trigger block_delete_unless_draft before delete on pos_orders for each row execute function app.tg_block_delete_unless_draft();

-- ---------------------------------------------------------------------------
-- RPCs
-- ---------------------------------------------------------------------------
create or replace function open_pos_order(
  p_org uuid, p_outlet_id uuid, p_warehouse_id uuid,
  p_table_id uuid default null, p_guest_count int default null, p_notes text default ''
) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare v_order uuid; v_table pos_tables%rowtype;
begin
  perform app.require_permission(p_org, 'pos.write');

  if not exists (select 1 from outlets where id = p_outlet_id and org_id = p_org and is_active) then
    raise exception 'outlet not found or inactive' using errcode = '23503';
  end if;

  if p_table_id is not null then
    select * into v_table from pos_tables where id = p_table_id and org_id = p_org;
    if not found then raise exception 'table not found in this organization' using errcode = '23503'; end if;
    if v_table.outlet_id <> p_outlet_id then raise exception 'table does not belong to this outlet' using errcode = '23514'; end if;
    if v_table.status <> 'free' then raise exception 'table % is not free', v_table.table_no using errcode = '23514'; end if;
  end if;

  insert into pos_orders (org_id, order_no, outlet_id, table_id, warehouse_id, guest_count, notes, opened_by)
  values (p_org, app.next_seq(p_org, 'pos_order'), p_outlet_id, p_table_id, p_warehouse_id,
          p_guest_count, coalesce(p_notes, ''), auth.uid())
  returning id into v_order;

  if p_table_id is not null then
    update pos_tables set status = 'occupied' where id = p_table_id;
  end if;

  return v_order;
end;
$$;

create or replace function add_order_line(
  p_order_id uuid, p_item_id uuid, p_qty numeric, p_unit_price numeric default null, p_notes text default ''
) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare o pos_orders%rowtype; v_price numeric(19,4); v_no int; v_line uuid;
begin
  select * into o from pos_orders where id = p_order_id for update;
  if not found then raise exception 'order not found' using errcode = 'P0002'; end if;
  perform app.require_permission(o.org_id, 'pos.write');
  if o.status <> 'open' then raise exception 'order % is %; cannot add lines', o.order_no, o.status using errcode = '23514'; end if;

  if p_unit_price is not null then
    v_price := p_unit_price;
  else
    select sales_price into v_price from items where id = p_item_id;
  end if;

  select coalesce(max(line_no), 0) + 1 into v_no from pos_order_lines where order_id = p_order_id;
  insert into pos_order_lines (order_id, line_no, item_id, qty, unit_price, notes)
  values (p_order_id, v_no, p_item_id, p_qty, coalesce(v_price, 0), coalesce(p_notes, ''))
  returning id into v_line;

  return v_line;
end;
$$;

create or replace function cancel_pos_order(p_order_id uuid, p_reason text default null)
returns void
language plpgsql security definer set search_path = public, app as $$
declare o pos_orders%rowtype;
begin
  select * into o from pos_orders where id = p_order_id for update;
  if not found then raise exception 'order not found' using errcode = 'P0002'; end if;
  perform app.require_permission(o.org_id, 'pos.write');
  if o.status <> 'open' then raise exception 'only an open order can be cancelled (this one is %)', o.status using errcode = '23514'; end if;

  update pos_orders set status = 'cancelled', cancel_reason = p_reason where id = p_order_id;
  if o.table_id is not null then
    update pos_tables set status = 'free' where id = o.table_id;
  end if;
end;
$$;

-- Settling an order IS the moment it becomes a real sales_invoice — same
-- create_sales_invoice()/post_sales_invoice() any other invoice uses, no
-- separate posting logic. The order's lines are simply handed over as the
-- invoice's own lines.
create or replace function settle_pos_order(
  p_order_id uuid, p_payment_method text, p_dealer_id uuid,
  p_cash_account_id uuid default null, p_default_sales_account_id uuid default null,
  p_output_vat_account_id uuid default null
) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare o pos_orders%rowtype; v_invoice uuid;
begin
  select * into o from pos_orders where id = p_order_id for update;
  if not found then raise exception 'order not found' using errcode = 'P0002'; end if;
  perform app.require_permission(o.org_id, 'pos.post');
  if o.status <> 'open' then raise exception 'only an open order can be settled (this one is %)', o.status using errcode = '23514'; end if;
  if not exists (select 1 from pos_order_lines where order_id = p_order_id) then
    raise exception 'order has no lines' using errcode = '23514';
  end if;

  v_invoice := create_sales_invoice(o.org_id, current_date, p_dealer_id, o.warehouse_id,
    (select jsonb_agg(jsonb_build_object('item_id', l.item_id, 'qty', l.qty, 'unit_price', l.unit_price))
     from pos_order_lines l where l.order_id = p_order_id),
    p_payment_method := p_payment_method, p_cash_account_id := p_cash_account_id,
    p_description := 'طلب رقم ' || o.order_no);
  perform post_sales_invoice(v_invoice, p_default_sales_account_id, p_output_vat_account_id);

  update pos_orders set status = 'settled', sales_invoice_id = v_invoice, settled_at = now() where id = p_order_id;
  if o.table_id is not null then
    update pos_tables set status = 'free' where id = o.table_id;
  end if;

  return v_invoice;
end;
$$;

revoke all on function open_pos_order(uuid,uuid,uuid,uuid,int,text) from public, anon;
revoke all on function add_order_line(uuid,uuid,numeric,numeric,text) from public, anon;
revoke all on function cancel_pos_order(uuid,text) from public, anon;
revoke all on function settle_pos_order(uuid,text,uuid,uuid,uuid,uuid) from public, anon;
grant execute on function open_pos_order(uuid,uuid,uuid,uuid,int,text) to authenticated;
grant execute on function add_order_line(uuid,uuid,numeric,numeric,text) to authenticated;
grant execute on function cancel_pos_order(uuid,text) to authenticated;
grant execute on function settle_pos_order(uuid,text,uuid,uuid,uuid,uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Permissions + RLS
-- ---------------------------------------------------------------------------
insert into permissions (key, module, description_ar, is_dangerous) values
  ('pos.write', 'pos', 'إدارة المنافذ والطاولات وفتح/إلغاء طلبات الكاشير', false),
  ('pos.post',  'pos', 'تسوية طلبات الكاشير (تحويلها لفاتورة مبيعات مرحّلة)', true)
on conflict (key) do nothing;
insert into role_permissions (role_id, permission_key)
select r.id, p.key from roles r cross join permissions p
where r.code = 'owner' and p.key in ('pos.write','pos.post') on conflict do nothing;
insert into role_permissions (role_id, permission_key)
select r.id, p.key from roles r cross join permissions p
where r.code = 'accountant' and p.key in ('pos.write','pos.post') on conflict do nothing;

alter table outlets         enable row level security;
alter table pos_tables      enable row level security;
alter table pos_orders      enable row level security;
alter table pos_order_lines enable row level security;

create policy outlet_select on outlets for select using (app.is_member(org_id));
create policy outlet_write  on outlets for all
  using (app.has_permission(org_id, 'pos.write')) with check (app.has_permission(org_id, 'pos.write'));

create policy pos_table_select on pos_tables for select using (app.is_member(org_id));
create policy pos_table_write  on pos_tables for all
  using (app.has_permission(org_id, 'pos.write')) with check (app.has_permission(org_id, 'pos.write'));

create policy pos_order_select on pos_orders for select using (app.is_member(org_id));
create policy pos_order_write  on pos_orders for all
  using (app.has_permission(org_id, 'pos.write')) with check (app.has_permission(org_id, 'pos.write'));

create policy pos_order_line_select on pos_order_lines for select using (app.is_member(org_id));
create policy pos_order_line_write  on pos_order_lines for all
  using (app.has_permission(org_id, 'pos.write')) with check (app.has_permission(org_id, 'pos.write'));
