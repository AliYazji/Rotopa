-- ============================================================================
-- Rotopa · Module 09 (continued) — stock reservations
--
-- Another addition (not a legacy replica) the user picked after comparing
-- against a parallel project. Purpose: hold a quantity of an item at a
-- warehouse against future demand (a phone order taken before an invoice
-- exists yet, stock set aside for a specific customer) WITHOUT moving any
-- real stock and WITHOUT touching item_warehouse_balances at all — a
-- reservation is a promise, not a movement.
--
-- Design: physical on-hand (`item_stock_on_hand()`, module 09) never
-- changes because of a reservation. What changes is a new derived number,
-- "available to promise" = on-hand minus every ACTIVE reservation for that
-- item/warehouse. This is intentionally a SOFT signal, not a hard block:
-- creating a reservation IS hard-capped at the currently available amount
-- (you can't reserve stock that's already fully promised), but selling
-- against low availability is still just a visible warning on the invoice
-- forms, same as the existing on-hand warning — the hard, unconditional
-- floor stays "physical stock can't go negative" (already enforced by
-- post_stock_move() itself), not "some other reservation exists".
--
-- No draft/posted GL lifecycle here at all — a reservation never touches
-- accounting or physical inventory, so it doesn't need one. Its own
-- lifecycle is simpler: active -> released (abandoned/cancelled) or
-- active -> fulfilled (the reserved stock actually went out via a real
-- document later). Both are terminal and immutable, same "audit trail
-- preserved" principle as every void/cancel elsewhere in this schema.
-- ============================================================================

create table stock_reservations (
  id            uuid primary key default extensions.gen_random_uuid(),
  org_id        uuid not null references organizations(id) on delete restrict,
  item_id       uuid not null references items(id) on delete restrict,
  warehouse_id  uuid not null references warehouses(id) on delete restrict,
  qty           numeric(19,4) not null check (qty > 0),   -- always in the item's base unit — a reservation isn't a commercial document, no need for the qty/unit_id split invoices have
  status        text not null default 'active' check (status in ('active','released','fulfilled')),
  source_type   text not null default 'manual',           -- e.g. 'manual', later 'sales_order' once that module exists
  source_id     uuid,
  notes         text not null default '',
  release_reason text,

  created_by    uuid references auth.users(id),
  created_at    timestamptz not null default now(),
  released_by   uuid references auth.users(id),
  released_at   timestamptz,
  fulfilled_by  uuid references auth.users(id),
  fulfilled_at  timestamptz,

  constraint stock_reservations_released_has_timestamp  check (status <> 'released'  or released_at  is not null),
  constraint stock_reservations_fulfilled_has_timestamp check (status <> 'fulfilled' or fulfilled_at is not null)
);
create index on stock_reservations (org_id, item_id, warehouse_id) where status = 'active';
create index on stock_reservations (org_id, status);
create index on stock_reservations (org_id, source_type, source_id);

create or replace function app.tg_stock_reservation_guard()
returns trigger language plpgsql as $$
begin
  if old.status <> 'active' then
    raise exception 'reservation is %; it is terminal and cannot be modified', old.status using errcode = '23514';
  end if;
  if new.status = 'active' then
    -- while still active, only notes may change (a correction to what it's for)
    if new.org_id <> old.org_id or new.item_id <> old.item_id or new.warehouse_id <> old.warehouse_id
       or new.qty <> old.qty or new.source_type <> old.source_type
       or new.source_id is distinct from old.source_id then
      raise exception 'an active reservation''s quantity/item/warehouse cannot be edited — release it and create a new one instead' using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;
create trigger stock_reservation_guard before update on stock_reservations
  for each row execute function app.tg_stock_reservation_guard();
create trigger audit after insert or update or delete on stock_reservations
  for each row execute function app.tg_audit();

-- extend the shared delete-guard: only an untouched active reservation may
-- be deleted outright; released/fulfilled ones are permanent history
create or replace function app.tg_block_delete_unless_draft()
returns trigger language plpgsql as $$
declare v_deletable boolean;
begin
  v_deletable := case
    when tg_table_name = 'cheques' then old.status = 'in_hand'
    when tg_table_name = 'pos_orders' then old.status = 'open'
    when tg_table_name = 'stock_reservations' then old.status = 'active'
    else old.status = 'draft'
  end;
  if not v_deletable then
    raise exception '% % is % and cannot be deleted — use void/cancel instead', tg_table_name, old.id, old.status
      using errcode = '23514';
  end if;
  return old;
end;
$$;
create trigger block_delete_unless_draft before delete on stock_reservations
  for each row execute function app.tg_block_delete_unless_draft();

-- ---------------------------------------------------------------------------
-- Read helper — same "language sql stable" convention as item_stock_on_hand()
-- ---------------------------------------------------------------------------
create or replace function item_reserved_qty(p_item_id uuid, p_warehouse_id uuid default null)
returns numeric language sql stable as $$
  select coalesce(sum(qty), 0) from stock_reservations
  where item_id = p_item_id and status = 'active'
    and (p_warehouse_id is null or warehouse_id = p_warehouse_id);
$$;

create or replace function item_available_to_promise(p_item_id uuid, p_warehouse_id uuid default null)
returns numeric language sql stable as $$
  select item_stock_on_hand(p_item_id, p_warehouse_id) - item_reserved_qty(p_item_id, p_warehouse_id);
$$;

-- ---------------------------------------------------------------------------
-- RPCs
-- ---------------------------------------------------------------------------
create or replace function reserve_stock(
  p_org uuid, p_item_id uuid, p_warehouse_id uuid, p_qty numeric,
  p_source_type text default 'manual', p_source_id uuid default null, p_notes text default ''
) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  it items%rowtype;
  w warehouses%rowtype;
  v_available numeric;
  v_reservation uuid;
begin
  perform app.require_permission(p_org, 'inventory.write');

  select * into it from items where id = p_item_id and org_id = p_org;
  if not found then raise exception 'item not found in this organization' using errcode = '23503'; end if;
  if not it.is_stock_tracked then raise exception 'item % does not track stock and cannot be reserved', it.code using errcode = '23514'; end if;
  if not it.is_active then raise exception 'item % is inactive', it.code using errcode = '23514'; end if;

  select * into w from warehouses where id = p_warehouse_id and org_id = p_org;
  if not found then raise exception 'warehouse not found in this organization' using errcode = '23503'; end if;
  if not w.is_active then raise exception 'warehouse % is inactive', w.code using errcode = '23514'; end if;

  if p_qty is null or p_qty <= 0 then raise exception 'reservation quantity must be greater than zero' using errcode = '23514'; end if;

  v_available := item_available_to_promise(p_item_id, p_warehouse_id);
  if p_qty > v_available then
    raise exception 'cannot reserve % — only % available to promise for this item at this warehouse', p_qty, v_available
      using errcode = '23514';
  end if;

  insert into stock_reservations (org_id, item_id, warehouse_id, qty, source_type, source_id, notes, created_by)
  values (p_org, p_item_id, p_warehouse_id, p_qty, coalesce(p_source_type, 'manual'), p_source_id, coalesce(p_notes, ''), auth.uid())
  returning id into v_reservation;

  return v_reservation;
end;
$$;

create or replace function release_stock_reservation(p_reservation_id uuid, p_reason text default null)
returns uuid
language plpgsql security definer set search_path = public, app as $$
declare r stock_reservations%rowtype;
begin
  select * into r from stock_reservations where id = p_reservation_id for update;
  if not found then raise exception 'reservation not found' using errcode = 'P0002'; end if;
  perform app.require_permission(r.org_id, 'inventory.write');
  if r.status <> 'active' then raise exception 'only an active reservation can be released (this one is %)', r.status using errcode = '23514'; end if;

  update stock_reservations
    set status = 'released', released_by = auth.uid(), released_at = now(), release_reason = p_reason
    where id = p_reservation_id;

  return p_reservation_id;
end;
$$;

create or replace function fulfill_stock_reservation(p_reservation_id uuid)
returns uuid
language plpgsql security definer set search_path = public, app as $$
declare r stock_reservations%rowtype;
begin
  select * into r from stock_reservations where id = p_reservation_id for update;
  if not found then raise exception 'reservation not found' using errcode = 'P0002'; end if;
  perform app.require_permission(r.org_id, 'inventory.write');
  if r.status <> 'active' then raise exception 'only an active reservation can be fulfilled (this one is %)', r.status using errcode = '23514'; end if;

  update stock_reservations
    set status = 'fulfilled', fulfilled_by = auth.uid(), fulfilled_at = now()
    where id = p_reservation_id;

  return p_reservation_id;
end;
$$;

revoke all on function reserve_stock(uuid,uuid,uuid,numeric,text,uuid,text) from public, anon;
revoke all on function release_stock_reservation(uuid,text) from public, anon;
revoke all on function fulfill_stock_reservation(uuid) from public, anon;
grant execute on function reserve_stock(uuid,uuid,uuid,numeric,text,uuid,text) to authenticated;
grant execute on function release_stock_reservation(uuid,text) to authenticated;
grant execute on function fulfill_stock_reservation(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- RLS — same inventory.write gate as every other module-09 mutation
-- ---------------------------------------------------------------------------
alter table stock_reservations enable row level security;

create policy stock_reservation_select on stock_reservations for select using (app.is_member(org_id));
create policy stock_reservation_write on stock_reservations for all
  using (app.has_permission(org_id, 'inventory.write')) with check (app.has_permission(org_id, 'inventory.write'));
