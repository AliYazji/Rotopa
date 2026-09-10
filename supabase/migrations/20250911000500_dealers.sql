-- ============================================================================
-- Rotopa · Module 04 — Dealers (customers / suppliers / employees)
-- One row per real-world party. Roles are flags, so a party that both buys and
-- sells is a single dealer, not two. Each dealer owns one ledger account.
-- (replaces legacy Dealers_tb keyed by Dealer_no + Dealer_type)
-- ============================================================================

create table dealers (
  id              uuid primary key default extensions.gen_random_uuid(),
  org_id          uuid not null references organizations(id) on delete cascade,
  code            text not null,
  name_ar         text not null,
  name_en         text,

  is_customer     boolean not null default false,
  is_supplier     boolean not null default false,
  is_employee     boolean not null default false,

  account_id      uuid not null references accounts(id) on delete restrict,
  currency_id     uuid references currencies(id),

  -- terms
  credit_limit    numeric(19,4) not null default 0 check (credit_limit >= 0),
  payment_terms_days int not null default 0 check (payment_terms_days >= 0),
  sales_discount_pct    numeric(6,3) not null default 0 check (sales_discount_pct between 0 and 100),
  purchase_discount_pct numeric(6,3) not null default 0 check (purchase_discount_pct between 0 and 100),
  block_on_credit_limit boolean not null default false,

  -- identity / contact
  tax_no          text,
  commercial_reg_no text,
  phone           text,
  email           extensions.citext,
  address         text,
  city            text,

  is_active       boolean not null default true,
  legacy_no       bigint,
  legacy_type     int,
  notes           text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),

  unique (org_id, code),
  constraint dealers_has_role check (is_customer or is_supplier or is_employee)
);
create index on dealers (org_id);
create index on dealers (account_id);
create index on dealers (org_id, is_customer) where is_customer;
create index on dealers (org_id, is_supplier) where is_supplier;
create index dealers_name_trgm on dealers using gin (name_ar extensions.gin_trgm_ops);

-- the dealer's account must belong to the same org and be a leaf
create or replace function app.tg_dealer_account_check()
returns trigger language plpgsql as $$
declare v_acc accounts%rowtype;
begin
  select * into v_acc from accounts where id = new.account_id;
  if v_acc.org_id <> new.org_id then
    raise exception 'dealer account belongs to a different organization' using errcode = '23503';
  end if;
  if not v_acc.is_postable then
    raise exception 'dealer account % must be a postable (leaf) account', v_acc.code using errcode = '23514';
  end if;
  return new;
end;
$$;
create trigger dealer_account_check
  before insert or update of account_id, org_id on dealers
  for each row execute function app.tg_dealer_account_check();

alter table dealers enable row level security;
create policy dealer_select on dealers for select using (app.is_member(org_id));
create policy dealer_write  on dealers for all
  using (app.has_permission(org_id, 'dealers.write'))
  with check (app.has_permission(org_id, 'dealers.write'));

create trigger set_updated_at before update on dealers for each row execute function app.tg_set_updated_at();
create trigger audit after insert or update or delete on dealers for each row execute function app.tg_audit();
