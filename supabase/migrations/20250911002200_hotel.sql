-- ============================================================================
-- Rotopa · Module 15 — Hotel (rooms, reservations, nightly revenue posting)
--
-- Built ahead of the legacy screenshots (user: "جرب إنت كمل الباقي" — try it
-- yourself, we'll compare against the real screens once they arrive and see
-- what's better). Modeled from the plan's own description ("الغرف وأنواعها
-- وأسعارها، الحجوزات والوصول والمغادرة، حسابات النُزلاء، والترحيل الليلي
-- للإيرادات") plus standard hotel-PMS practice — expect this to be revised
-- once the real ROOMS/reservation_tb/Hotels_Trans screens are seen.
--
-- Design decisions worth recording:
--   * A guest is a dealer (is_customer=true) — "حسابات النُزلاء" IS the
--     existing dealer/AR infrastructure, not a new party concept. Payment
--     collection reuses vouchers (a receipt against the guest's account),
--     not a new mechanism.
--   * rooms.status is the room's CURRENT physical state (available/
--     occupied/cleaning/out_of_service); a reservation for FUTURE dates on
--     a currently-occupied room is a real, valid case, so availability for
--     a date range is computed from overlapping reservations, never from
--     this single flag.
--   * A reservation itself posts nothing at booking. Only actual nights
--     stayed post revenue, one at a time (post_room_night) or in a batch
--     for the whole org (run_night_audit) — mirroring the "ترحيل ليلي"
--     description literally: a nightly run, not a stay-total invoice.
--     Each night is its own reservation_nights row (permanent audit trail,
--     same reasoning as fixed_asset_depreciation_runs — repeats over time,
--     needs a fresh source_id per post for journal_entries' one-entry-per-
--     source-document constraint).
--   * Deliberately NOT built: itemized guest folio (minibar, room service,
--     laundry...) — a stay's only charge for now is room-nights at the
--     reservation's own rate. Incidentals would need their own charge
--     table; flagged, not guessed at.
-- ============================================================================

create table room_types (
  id            uuid primary key default extensions.gen_random_uuid(),
  org_id        uuid not null references organizations(id) on delete restrict,
  code          text not null,
  name_ar       text not null,
  default_rate  numeric(19,4) not null default 0 check (default_rate >= 0),
  revenue_account_id uuid references accounts(id) on delete restrict,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (org_id, code)
);

create table rooms (
  id            uuid primary key default extensions.gen_random_uuid(),
  org_id        uuid not null references organizations(id) on delete restrict,
  room_no       text not null,
  room_type_id  uuid not null references room_types(id) on delete restrict,
  floor         text,
  status        text not null default 'available' check (status in ('available','occupied','cleaning','out_of_service')),
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (org_id, room_no)
);
create index on rooms (org_id, room_type_id);

create table reservations (
  id            uuid primary key default extensions.gen_random_uuid(),
  org_id        uuid not null references organizations(id) on delete restrict,
  reservation_no bigint not null,
  guest_id      uuid not null references dealers(id) on delete restrict,
  room_id       uuid not null references rooms(id) on delete restrict,
  rate_per_night numeric(19,4) not null check (rate_per_night >= 0),
  planned_check_in  date not null,
  planned_check_out date not null,
  actual_check_in   timestamptz,
  actual_check_out  timestamptz,
  status        text not null default 'booked' check (status in ('booked','checked_in','checked_out','cancelled')),
  notes         text not null default '',
  cancel_reason text,
  created_by    uuid references auth.users(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (org_id, reservation_no),
  constraint res_dates_order check (planned_check_out > planned_check_in)
);
create index on reservations (org_id, room_id, status);
create index on reservations (org_id, guest_id);

-- Permanent per-night audit trail — see header comment for why each post
-- needs its own row rather than updating a running total.
create table reservation_nights (
  id            uuid primary key default extensions.gen_random_uuid(),
  org_id        uuid not null references organizations(id) on delete restrict,
  reservation_id uuid not null references reservations(id) on delete restrict,
  night_date    date not null,
  amount        numeric(19,4) not null check (amount >= 0),
  journal_entry_id uuid references journal_entries(id) on delete restrict,
  created_by    uuid references auth.users(id),
  created_at    timestamptz not null default now(),
  unique (org_id, reservation_id, night_date)
);
create index on reservation_nights (org_id, reservation_id);

-- ---------------------------------------------------------------------------
-- Guards
-- ---------------------------------------------------------------------------
create trigger set_updated_at before update on room_types for each row execute function app.tg_set_updated_at();
create trigger set_updated_at before update on rooms for each row execute function app.tg_set_updated_at();
create trigger set_updated_at before update on reservations for each row execute function app.tg_set_updated_at();
create trigger audit after insert or update or delete on reservations for each row execute function app.tg_audit();

-- A reservation's commercial terms are only editable while still 'booked' —
-- once checked in, nights may already be posted at the original rate.
-- Cosmetic fields (notes) and the status/actual-time bookkeeping columns
-- (only ever touched by the RPCs below) stay editable regardless.
create or replace function app.tg_reservation_guard()
returns trigger language plpgsql as $$
begin
  if old.status <> 'booked' then
    if new.guest_id <> old.guest_id or new.room_id <> old.room_id or new.rate_per_night <> old.rate_per_night
       or new.planned_check_in <> old.planned_check_in or new.planned_check_out <> old.planned_check_out then
      raise exception 'a reservation''s terms cannot change once it is %', old.status using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;
create trigger reservation_guard before update on reservations for each row execute function app.tg_reservation_guard();

-- ---------------------------------------------------------------------------
-- RPCs
-- ---------------------------------------------------------------------------
create or replace function create_reservation(
  p_org uuid, p_guest_id uuid, p_room_id uuid, p_rate_per_night numeric,
  p_planned_check_in date, p_planned_check_out date, p_notes text default ''
) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_is_guest boolean;
  v_room rooms%rowtype;
  v_reservation uuid;
begin
  perform app.require_permission(p_org, 'hotel.write');

  select is_customer into v_is_guest from dealers where id = p_guest_id and org_id = p_org;
  if v_is_guest is null then raise exception 'guest not found in this organization' using errcode = '23503'; end if;
  if not v_is_guest then raise exception 'dealer is not marked as a customer' using errcode = '23514'; end if;

  select * into v_room from rooms where id = p_room_id and org_id = p_org;
  if not found then raise exception 'room not found in this organization' using errcode = '23503'; end if;
  if not v_room.is_active then raise exception 'room % is inactive', v_room.room_no using errcode = '23514'; end if;

  if exists (
    select 1 from reservations r
    where r.room_id = p_room_id and r.status in ('booked', 'checked_in')
      and r.planned_check_in < p_planned_check_out and r.planned_check_out > p_planned_check_in
  ) then
    raise exception 'room % is already booked for part of this date range', v_room.room_no using errcode = '23514';
  end if;

  insert into reservations (org_id, reservation_no, guest_id, room_id, rate_per_night,
                             planned_check_in, planned_check_out, notes, created_by)
  values (p_org, app.next_seq(p_org, 'reservation'), p_guest_id, p_room_id, p_rate_per_night,
          p_planned_check_in, p_planned_check_out, coalesce(p_notes, ''), auth.uid())
  returning id into v_reservation;

  return v_reservation;
end;
$$;

create or replace function check_in_reservation(p_reservation_id uuid)
returns void
language plpgsql security definer set search_path = public, app as $$
declare r reservations%rowtype;
begin
  select * into r from reservations where id = p_reservation_id for update;
  if not found then raise exception 'reservation not found' using errcode = 'P0002'; end if;
  perform app.require_permission(r.org_id, 'hotel.post');
  if r.status <> 'booked' then raise exception 'only a booked reservation can check in (this one is %)', r.status using errcode = '23514'; end if;

  update reservations set status = 'checked_in', actual_check_in = now() where id = p_reservation_id;
  update rooms set status = 'occupied' where id = r.room_id;
end;
$$;

create or replace function check_out_reservation(p_reservation_id uuid)
returns void
language plpgsql security definer set search_path = public, app as $$
declare r reservations%rowtype;
begin
  select * into r from reservations where id = p_reservation_id for update;
  if not found then raise exception 'reservation not found' using errcode = 'P0002'; end if;
  perform app.require_permission(r.org_id, 'hotel.post');
  if r.status <> 'checked_in' then raise exception 'only a checked-in reservation can check out (this one is %)', r.status using errcode = '23514'; end if;

  update reservations set status = 'checked_out', actual_check_out = now() where id = p_reservation_id;
  update rooms set status = 'cleaning' where id = r.room_id;
end;
$$;

create or replace function cancel_reservation(p_reservation_id uuid, p_reason text default null)
returns void
language plpgsql security definer set search_path = public, app as $$
declare r reservations%rowtype;
begin
  select * into r from reservations where id = p_reservation_id for update;
  if not found then raise exception 'reservation not found' using errcode = 'P0002'; end if;
  perform app.require_permission(r.org_id, 'hotel.write');
  if r.status <> 'booked' then raise exception 'only a booked reservation can be cancelled (this one is %)', r.status using errcode = '23514'; end if;

  update reservations set status = 'cancelled', cancel_reason = p_reason where id = p_reservation_id;
end;
$$;

-- One night's room revenue: Dr the guest's own AR account, Cr the room
-- type's revenue account (falling back to a default, same pattern as
-- sales/payroll's own account fallbacks).
create or replace function post_room_night(
  p_reservation_id uuid, p_night_date date, p_default_revenue_account_id uuid default null
) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  r reservations%rowtype;
  v_revenue_account uuid;
  v_currency uuid;
  v_period uuid;
  v_entry uuid;
  v_run uuid;
begin
  select * into r from reservations where id = p_reservation_id for update;
  if not found then raise exception 'reservation not found' using errcode = 'P0002'; end if;
  perform app.require_permission(r.org_id, 'hotel.post');
  if r.status not in ('checked_in', 'checked_out') then
    raise exception 'only a checked-in or checked-out reservation can have nights posted (this one is %)', r.status using errcode = '23514';
  end if;
  if p_night_date < r.planned_check_in or p_night_date >= r.planned_check_out then
    raise exception 'night % is outside this reservation''s stay (% to %)', p_night_date, r.planned_check_in, r.planned_check_out using errcode = '23514';
  end if;
  if exists (select 1 from reservation_nights where reservation_id = p_reservation_id and night_date = p_night_date) then
    raise exception 'night % was already posted for this reservation', p_night_date using errcode = '23514';
  end if;

  select coalesce(rt.revenue_account_id, p_default_revenue_account_id)
    into v_revenue_account
  from reservations rr join rooms ro on ro.id = rr.room_id join room_types rt on rt.id = ro.room_type_id
  where rr.id = p_reservation_id;
  if v_revenue_account is null then
    raise exception 'this room type has no revenue account and no default was given' using errcode = '23514';
  end if;

  insert into reservation_nights (org_id, reservation_id, night_date, amount, created_by)
  values (r.org_id, p_reservation_id, p_night_date, r.rate_per_night, auth.uid())
  returning id into v_run;

  select base_currency_id into v_currency from organizations where id = r.org_id;
  v_period := app.open_period_for(r.org_id, p_night_date);
  insert into journal_entries (org_id, entry_no, entry_date, fiscal_period_id, description,
                                source_type, source_id, created_by)
  values (r.org_id, app.next_seq(r.org_id, 'journal'), p_night_date, v_period,
          'إيراد غرفة — حجز رقم ' || r.reservation_no || ' — ليلة ' || p_night_date,
          'hotel_night', v_run, auth.uid())
  returning id into v_entry;

  insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate, dealer_id)
  select v_entry, 1, d.account_id, 'إيراد غرفة — حجز رقم ' || r.reservation_no, r.rate_per_night, 0, v_currency, 1, r.guest_id
  from dealers d where d.id = r.guest_id;
  insert into journal_lines (entry_id, line_no, account_id, description, debit, credit, currency_id, rate)
  values (v_entry, 2, v_revenue_account, 'إيراد غرفة — حجز رقم ' || r.reservation_no, 0, r.rate_per_night, v_currency, 1);

  update journal_entries set status = 'posted', posted_by = auth.uid(), posted_at = now() where id = v_entry;
  update reservation_nights set journal_entry_id = v_entry where id = v_run;

  return v_entry;
end;
$$;

-- Convenience batch runner for a nightly close — "الترحيل الليلي للإيرادات"
-- literally: posts every checked-in reservation's night for p_date, skipping
-- (not failing) any that are out of range or already posted.
create or replace function run_night_audit(p_org uuid, p_date date, p_default_revenue_account_id uuid default null)
returns table(reservation_id uuid, journal_entry_id uuid, amount numeric)
language plpgsql security definer set search_path = public, app as $$
declare a record; v_entry uuid; v_amount numeric(19,4);
begin
  perform app.require_permission(p_org, 'hotel.post');
  for a in select id from reservations where org_id = p_org and status = 'checked_in' order by reservation_no loop
    begin
      v_entry := post_room_night(a.id, p_date, p_default_revenue_account_id);
    exception when sqlstate '23514' then
      continue;   -- out of range for this reservation, or already posted
    end;
    select rn.amount into v_amount from reservation_nights rn where rn.reservation_id = a.id and rn.night_date = p_date;
    reservation_id := a.id;
    journal_entry_id := v_entry;
    amount := v_amount;
    return next;
  end loop;
end;
$$;

revoke all on function create_reservation(uuid,uuid,uuid,numeric,date,date,text) from public, anon;
revoke all on function check_in_reservation(uuid) from public, anon;
revoke all on function check_out_reservation(uuid) from public, anon;
revoke all on function cancel_reservation(uuid,text) from public, anon;
revoke all on function post_room_night(uuid,date,uuid) from public, anon;
revoke all on function run_night_audit(uuid,date,uuid) from public, anon;
grant execute on function create_reservation(uuid,uuid,uuid,numeric,date,date,text) to authenticated;
grant execute on function check_in_reservation(uuid) to authenticated;
grant execute on function check_out_reservation(uuid) to authenticated;
grant execute on function cancel_reservation(uuid,text) to authenticated;
grant execute on function post_room_night(uuid,date,uuid) to authenticated;
grant execute on function run_night_audit(uuid,date,uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Permissions + RLS
-- ---------------------------------------------------------------------------
insert into permissions (key, module, description_ar, is_dangerous) values
  ('hotel.write', 'hotel', 'إدارة الغرف وأنواعها وإنشاء وإلغاء الحجوزات', false),
  ('hotel.post',  'hotel', 'تسجيل الوصول والمغادرة وترحيل الإيراد الليلي', true)
on conflict (key) do nothing;
insert into role_permissions (role_id, permission_key)
select r.id, p.key from roles r cross join permissions p
where r.code = 'owner' and p.key in ('hotel.write','hotel.post') on conflict do nothing;
insert into role_permissions (role_id, permission_key)
select r.id, p.key from roles r cross join permissions p
where r.code = 'accountant' and p.key in ('hotel.write','hotel.post') on conflict do nothing;

alter table room_types         enable row level security;
alter table rooms              enable row level security;
alter table reservations       enable row level security;
alter table reservation_nights enable row level security;

create policy room_type_select on room_types for select using (app.is_member(org_id));
create policy room_type_write  on room_types for all
  using (app.has_permission(org_id, 'hotel.write')) with check (app.has_permission(org_id, 'hotel.write'));

create policy room_select on rooms for select using (app.is_member(org_id));
create policy room_write  on rooms for all
  using (app.has_permission(org_id, 'hotel.write')) with check (app.has_permission(org_id, 'hotel.write'));

create policy reservation_select on reservations for select using (app.is_member(org_id));
create policy reservation_write  on reservations for all
  using (app.has_permission(org_id, 'hotel.write')) with check (app.has_permission(org_id, 'hotel.write'));

create policy reservation_night_select on reservation_nights for select using (app.is_member(org_id));
-- no insert/update policy — a permanent audit trail written only by post_room_night()
