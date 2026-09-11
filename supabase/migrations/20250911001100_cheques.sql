-- ============================================================================
-- Rotopa · Module 07 — Cheques (الشيكات)
--
-- A cheque is recognised once (usually as a voucher's payment method — the
-- voucher already posts Dr/Cr against a "holding" account such as
-- «شيكات تحت التحصيل» / «شيكات تحت الدفع») and then moves through a small
-- state machine. Only the transitions with a real cash effect post a journal
-- entry; everything else is bookkeeping.
--
--   incoming (from a customer):
--     in_hand -> deposited -> cleared   Dr bank / Cr holding
--                          -> bounced   Dr dealer (reinstate AR) / Cr holding
--     in_hand -> cancelled              Dr dealer (reinstate AR) / Cr holding
--     in_hand -> endorsed               Dr target account / Cr holding
--   outgoing (issued to a supplier):
--     in_hand -> deposited -> cleared   Dr holding / Cr bank
--                          -> bounced   Dr holding / Cr dealer (reinstate AP)
--     in_hand -> cancelled              Dr holding / Cr dealer (reinstate AP)
--     (outgoing cheques cannot be endorsed — we don't re-issue someone else's)
-- ============================================================================

create table cheques (
  id            uuid primary key default extensions.gen_random_uuid(),
  org_id        uuid not null references organizations(id) on delete restrict,
  direction     text not null check (direction in ('incoming','outgoing')),
  cheque_no     text not null,
  cheque_date   date not null,          -- due / maturity date printed on the cheque
  bank_name     text,
  party_name    text,                   -- drawer (incoming) or payee (outgoing) printed on the cheque

  amount        numeric(19,4) not null check (amount > 0),   -- in the cheque's own currency
  currency_id   uuid not null references currencies(id),
  rate          numeric(19,9) not null default 1 check (rate > 0),

  dealer_id           uuid not null references dealers(id) on delete restrict,
  holding_account_id  uuid not null references accounts(id) on delete restrict,
  bank_account_id     uuid references accounts(id) on delete restrict,

  status        text not null default 'in_hand'
                  check (status in ('in_hand','deposited','cleared','bounced','cancelled','endorsed')),
  voucher_id    uuid references vouchers(id) on delete restrict,
  clearing_entry_id uuid references journal_entries(id) on delete restrict,

  notes         text,
  created_by    uuid references auth.users(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  unique (org_id, direction, cheque_no, bank_name)
);
create index on cheques (org_id, status);
create index on cheques (org_id, cheque_date);
create index on cheques (dealer_id);

-- ---------------------------------------------------------------------------
-- Validation + guards
-- ---------------------------------------------------------------------------
create or replace function app.tg_cheque_validate()
returns trigger language plpgsql as $$
declare a accounts%rowtype; d dealers%rowtype;
begin
  select * into a from accounts where id = new.holding_account_id;
  if a.org_id <> new.org_id then raise exception 'holding account belongs to a different organization' using errcode='23503'; end if;
  if not a.is_postable then raise exception 'holding account % is not postable', a.code using errcode='23514'; end if;

  select * into d from dealers where id = new.dealer_id;
  if d.org_id <> new.org_id then raise exception 'dealer belongs to a different organization' using errcode='23503'; end if;

  if new.bank_account_id is not null then
    if (select org_id from accounts where id = new.bank_account_id) <> new.org_id then
      raise exception 'bank account belongs to a different organization' using errcode='23503';
    end if;
  end if;

  if new.direction = 'outgoing' and new.status = 'endorsed' then
    raise exception 'an outgoing cheque cannot be endorsed' using errcode = '23514';
  end if;

  return new;
end;
$$;
create trigger cheque_validate before insert or update on cheques for each row execute function app.tg_cheque_validate();

create or replace function app.tg_cheque_guard()
returns trigger language plpgsql as $$
begin
  if old.status in ('cleared','bounced','cancelled','endorsed') then
    raise exception 'cheque is %; it cannot be changed further', old.status using errcode = '23514';
  end if;
  return new;
end;
$$;
create trigger cheque_guard before update on cheques for each row execute function app.tg_cheque_guard();

create trigger set_updated_at before update on cheques for each row execute function app.tg_set_updated_at();
create trigger audit after insert or update or delete on cheques for each row execute function app.tg_audit();

-- ---------------------------------------------------------------------------
-- RPCs
-- ---------------------------------------------------------------------------
create or replace function create_cheque(
  p_org uuid, p_direction text, p_cheque_no text, p_cheque_date date,
  p_amount numeric, p_currency_id uuid, p_dealer_id uuid, p_holding_account_id uuid,
  p_bank_name text default null, p_party_name text default null,
  p_rate numeric default 1, p_voucher_id uuid default null, p_notes text default null
) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare v_id uuid;
begin
  perform app.require_permission(p_org, 'cheques.write');
  insert into cheques (org_id, direction, cheque_no, cheque_date, bank_name, party_name,
                        amount, currency_id, rate, dealer_id, holding_account_id, voucher_id,
                        notes, created_by)
  values (p_org, p_direction, p_cheque_no, p_cheque_date, p_bank_name, p_party_name,
          round(p_amount,4), p_currency_id, coalesce(p_rate,1), p_dealer_id, p_holding_account_id, p_voucher_id,
          p_notes, auth.uid())
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function set_cheque_deposited(p_cheque_id uuid, p_bank_account_id uuid)
returns void language plpgsql security definer set search_path = public, app as $$
declare c cheques%rowtype;
begin
  select * into c from cheques where id = p_cheque_id for update;
  if not found then raise exception 'cheque not found' using errcode = 'P0002'; end if;
  perform app.require_permission(c.org_id, 'cheques.write');
  if c.status <> 'in_hand' then raise exception 'only an in-hand cheque can be deposited' using errcode = '23514'; end if;
  update cheques set status = 'deposited', bank_account_id = p_bank_account_id where id = p_cheque_id;
end;
$$;

-- Shared by clear/bounce/cancel/endorse: one settlement entry (holding <-> other side).
create or replace function app.post_cheque_entry(
  c cheques, p_date date, p_other_account uuid, p_holding_is_debit boolean, p_desc text
) returns uuid language plpgsql security definer set search_path = public, app as $$
declare v_entry uuid; v_period uuid; v_base numeric(19,4);
begin
  v_period := app.open_period_for(c.org_id, p_date);
  v_base := round(c.amount * c.rate, 4);

  insert into journal_entries (org_id, entry_no, entry_date, fiscal_period_id, description,
                                source_type, source_id, document_currency_id, created_by)
  values (c.org_id, app.next_seq(c.org_id, 'journal'), p_date, v_period, p_desc,
          'cheque', c.id, c.currency_id, auth.uid())
  returning id into v_entry;

  insert into journal_lines (entry_id, line_no, account_id, description, debit, credit,
                              currency_id, rate, fc_debit, fc_credit, dealer_id)
  values
    (v_entry, 1, c.holding_account_id, p_desc,
     case when p_holding_is_debit then v_base else 0 end, case when p_holding_is_debit then 0 else v_base end,
     c.currency_id, c.rate,
     case when p_holding_is_debit then c.amount else 0 end, case when p_holding_is_debit then 0 else c.amount end,
     c.dealer_id),
    (v_entry, 2, p_other_account, p_desc,
     case when p_holding_is_debit then 0 else v_base end, case when p_holding_is_debit then v_base else 0 end,
     c.currency_id, c.rate,
     case when p_holding_is_debit then 0 else c.amount end, case when p_holding_is_debit then c.amount else 0 end,
     c.dealer_id);

  update journal_entries set status = 'posted', posted_by = auth.uid(), posted_at = now() where id = v_entry;
  return v_entry;
end;
$$;

create or replace function clear_cheque(p_cheque_id uuid, p_date date, p_bank_account_id uuid default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare c cheques%rowtype; v_bank uuid; v_entry uuid;
begin
  select * into c from cheques where id = p_cheque_id for update;
  if not found then raise exception 'cheque not found' using errcode = 'P0002'; end if;
  perform app.require_permission(c.org_id, 'cheques.post');
  if c.status not in ('in_hand','deposited') then
    raise exception 'only an in-hand or deposited cheque can clear' using errcode = '23514';
  end if;
  v_bank := coalesce(p_bank_account_id, c.bank_account_id);
  if v_bank is null then raise exception 'a bank account is required to clear a cheque' using errcode = '23514'; end if;

  -- incoming: Dr bank / Cr holding (holding is credit)  -> holding_is_debit = false
  -- outgoing: Dr holding / Cr bank                        -> holding_is_debit = true
  v_entry := app.post_cheque_entry(c, p_date, v_bank, c.direction = 'outgoing',
    'تحصيل شيك رقم ' || c.cheque_no);

  update cheques set status = 'cleared', bank_account_id = v_bank, clearing_entry_id = v_entry where id = c.id;
  return v_entry;
end;
$$;

create or replace function bounce_cheque(p_cheque_id uuid, p_date date, p_reason text default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare c cheques%rowtype; v_entry uuid;
begin
  select * into c from cheques where id = p_cheque_id for update;
  if not found then raise exception 'cheque not found' using errcode = 'P0002'; end if;
  perform app.require_permission(c.org_id, 'cheques.post');
  if c.status <> 'deposited' then raise exception 'only a deposited cheque can bounce' using errcode = '23514'; end if;

  -- incoming: reinstate what the customer owes -> Dr dealer account / Cr holding -> holding_is_debit=false
  -- outgoing: reinstate what we owe the supplier -> Dr holding / Cr dealer      -> holding_is_debit=true
  v_entry := app.post_cheque_entry(c, p_date, (select account_id from dealers where id = c.dealer_id),
    c.direction = 'outgoing', 'ارتداد شيك رقم ' || c.cheque_no || coalesce(' — ' || p_reason, ''));

  update cheques set status = 'bounced', clearing_entry_id = v_entry, notes = coalesce(notes || E'\n', '') || coalesce(p_reason,'') where id = c.id;
  return v_entry;
end;
$$;

create or replace function cancel_cheque(p_cheque_id uuid, p_date date, p_reason text default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare c cheques%rowtype; v_entry uuid;
begin
  select * into c from cheques where id = p_cheque_id for update;
  if not found then raise exception 'cheque not found' using errcode = 'P0002'; end if;
  perform app.require_permission(c.org_id, 'cheques.post');
  if c.status <> 'in_hand' then raise exception 'only an in-hand cheque can be cancelled' using errcode = '23514'; end if;

  v_entry := app.post_cheque_entry(c, p_date, (select account_id from dealers where id = c.dealer_id),
    c.direction = 'outgoing', 'إلغاء شيك رقم ' || c.cheque_no || coalesce(' — ' || p_reason, ''));

  update cheques set status = 'cancelled', clearing_entry_id = v_entry, notes = coalesce(notes || E'\n', '') || coalesce(p_reason,'') where id = c.id;
  return v_entry;
end;
$$;

create or replace function endorse_cheque(p_cheque_id uuid, p_date date, p_target_account_id uuid, p_reason text default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare c cheques%rowtype; v_entry uuid;
begin
  select * into c from cheques where id = p_cheque_id for update;
  if not found then raise exception 'cheque not found' using errcode = 'P0002'; end if;
  perform app.require_permission(c.org_id, 'cheques.post');
  if c.direction <> 'incoming' then raise exception 'only an incoming cheque can be endorsed' using errcode = '23514'; end if;
  if c.status <> 'in_hand' then raise exception 'only an in-hand cheque can be endorsed' using errcode = '23514'; end if;

  -- Dr target account / Cr holding -> holding_is_debit = false
  v_entry := app.post_cheque_entry(c, p_date, p_target_account_id, false,
    'تجيير شيك رقم ' || c.cheque_no || coalesce(' — ' || p_reason, ''));

  update cheques set status = 'endorsed', clearing_entry_id = v_entry, notes = coalesce(notes || E'\n', '') || coalesce(p_reason,'') where id = c.id;
  return v_entry;
end;
$$;

revoke all on function create_cheque(uuid,text,text,date,numeric,uuid,uuid,uuid,text,text,numeric,uuid,text) from public, anon;
revoke all on function set_cheque_deposited(uuid,uuid) from public, anon;
revoke all on function clear_cheque(uuid,date,uuid) from public, anon;
revoke all on function bounce_cheque(uuid,date,text) from public, anon;
revoke all on function cancel_cheque(uuid,date,text) from public, anon;
revoke all on function endorse_cheque(uuid,date,uuid,text) from public, anon;
grant execute on function create_cheque(uuid,text,text,date,numeric,uuid,uuid,uuid,text,text,numeric,uuid,text) to authenticated;
grant execute on function set_cheque_deposited(uuid,uuid) to authenticated;
grant execute on function clear_cheque(uuid,date,uuid) to authenticated;
grant execute on function bounce_cheque(uuid,date,text) to authenticated;
grant execute on function cancel_cheque(uuid,date,text) to authenticated;
grant execute on function endorse_cheque(uuid,date,uuid,text) to authenticated;
-- app.post_cheque_entry is an internal helper: not in the public schema PostgREST
-- exposes, and only ever invoked from the SECURITY DEFINER functions above
-- (which run as their owner), so it needs no grant of its own.

-- ---------------------------------------------------------------------------
-- Permissions + RLS
-- ---------------------------------------------------------------------------
insert into permissions (key, module, description_ar, is_dangerous) values
  ('cheques.write', 'accounting', 'تسجيل الشيكات وإيداعها', false),
  ('cheques.post',  'accounting', 'تحصيل/ارتداد/إلغاء/تجيير الشيكات', true)
on conflict (key) do nothing;

insert into role_permissions (role_id, permission_key)
select r.id, p.key from roles r cross join permissions p
where r.code = 'owner' and p.key in ('cheques.write','cheques.post')
on conflict do nothing;
insert into role_permissions (role_id, permission_key)
select r.id, p.key from roles r cross join permissions p
where r.code = 'accountant' and p.key in ('cheques.write','cheques.post')
on conflict do nothing;

alter table cheques enable row level security;
create policy cheque_select on cheques for select using (app.is_member(org_id));
create policy cheque_write  on cheques for all
  using (app.has_permission(org_id, 'cheques.write'))
  with check (app.has_permission(org_id, 'cheques.write'));
