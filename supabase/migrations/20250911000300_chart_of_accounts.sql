-- ============================================================================
-- Rotopa · Module 01 — Chart of Accounts
-- A single hierarchical tree. Only leaf ("postable") accounts carry journal
-- lines; parents exist purely to aggregate. Financial-statement placement is
-- driven by account_categories, cash-flow by cashflow_class.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- account_categories — financial statement buckets
-- (replaces legacy accountCategoryType_tb + AccountType)
-- ---------------------------------------------------------------------------
create table account_categories (
  id            uuid primary key default extensions.gen_random_uuid(),
  org_id        uuid not null references organizations(id) on delete cascade,
  code          text not null,
  name_ar       text not null,
  name_en       text,
  statement     text not null check (statement in ('balance_sheet','income_statement')),
  section       text not null check (section in ('asset','liability','equity','income','expense')),
  normal_balance text not null check (normal_balance in ('debit','credit')),
  cashflow_section text check (cashflow_section in ('operating','investing','financing')),
  sort_order    int not null default 0,
  legacy_no     int,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (org_id, code)
);
create index on account_categories (org_id);

-- ---------------------------------------------------------------------------
-- accounts — the tree
-- ---------------------------------------------------------------------------
create table accounts (
  id            uuid primary key default extensions.gen_random_uuid(),
  org_id        uuid not null references organizations(id) on delete cascade,
  code          extensions.citext not null,
  name_ar       text not null,
  name_en       text,

  parent_id     uuid references accounts(id) on delete restrict,
  category_id   uuid references account_categories(id) on delete restrict,

  nature        text not null default 'both' check (nature in ('debit','credit','both')),
  is_postable   boolean not null default true,        -- leaf that accepts journal lines
  allow_transactions boolean not null default true,   -- soft stop (legacy StopTransaction)

  currency_id   uuid references currencies(id),       -- null = any currency
  cashflow_class text check (cashflow_class in ('cash','operating','investing','financing')),

  -- subledger link: control accounts summarise a subledger and take no manual lines
  is_control    boolean not null default false,
  control_type  text check (control_type in ('customers','suppliers','employees','bank','cash','inventory','fixed_assets','tax')),

  -- dimension requirements — enforced by the posting engine
  require_dealer        boolean not null default false,
  require_cost_center   boolean not null default false,
  require_department    boolean not null default false,
  require_project       boolean not null default false,

  -- maintained by trigger
  depth         smallint not null default 0,
  path          extensions.ltree,

  is_active     boolean not null default true,
  legacy_code   text,
  notes         text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  unique (org_id, code),
  -- a control account must restrict its subledger
  constraint accounts_control_type check (is_control = (control_type is not null))
);
create index on accounts (org_id);
create index on accounts (org_id, parent_id);
create index accounts_path_gist on accounts using gist (path);
create index accounts_name_trgm on accounts using gin (name_ar extensions.gin_trgm_ops);

-- ---------------------------------------------------------------------------
-- Tree integrity: no cycles, path/depth upkeep, leaf-only posting
-- ---------------------------------------------------------------------------
create or replace function app.tg_accounts_tree()
returns trigger language plpgsql as $$
declare
  v_parent accounts%rowtype;
  v_code_label text;
begin
  -- label = code with ltree-safe characters (digits/letters/underscore only)
  v_code_label := regexp_replace(new.code::text, '[^A-Za-z0-9_]', '_', 'g');

  if new.parent_id is null then
    new.depth := 0;
    new.path  := v_code_label::extensions.ltree;
  else
    if new.parent_id = new.id then
      raise exception 'account % cannot be its own parent', new.code using errcode = '23514';
    end if;
    select * into v_parent from accounts where id = new.parent_id and org_id = new.org_id;
    if not found then
      raise exception 'parent account not found in this organization' using errcode = '23503';
    end if;
    -- a parent must not itself be postable (parents only aggregate)
    if v_parent.is_postable then
      raise exception 'account % is postable and cannot have children; make it a non-postable parent first', v_parent.code
        using errcode = '23514';
    end if;
    -- cycle check: new.id must not appear in the parent's path
    if tg_op = 'UPDATE' and v_parent.path operator(extensions.~) (('*.' || regexp_replace(old.code::text,'[^A-Za-z0-9_]','_','g') || '.*')::extensions.lquery) then
      raise exception 'moving account % under % would create a cycle', new.code, v_parent.code using errcode = '23514';
    end if;
    new.depth := v_parent.depth + 1;
    new.path  := v_parent.path operator(extensions.||) v_code_label;
  end if;

  return new;
end;
$$;

create trigger accounts_tree
  before insert or update of parent_id, code on accounts
  for each row execute function app.tg_accounts_tree();

-- when a node moves or is recoded, refresh every descendant's path/depth
create or replace function app.tg_accounts_tree_cascade()
returns trigger language plpgsql as $$
begin
  if new.path is distinct from old.path then
    update accounts c
       set path  = new.path operator(extensions.||) subpath(c.path, nlevel(old.path)),
           depth = new.depth + (nlevel(c.path) - nlevel(old.path))
     where c.org_id = new.org_id
       and c.path operator(extensions.<@) old.path
       and c.id <> new.id;
  end if;
  return null;
end;
$$;

create trigger accounts_tree_cascade
  after update of path on accounts
  for each row execute function app.tg_accounts_tree_cascade();

-- block making an account postable while it still has children
create or replace function app.tg_accounts_postable_guard()
returns trigger language plpgsql as $$
begin
  if new.is_postable and exists (select 1 from accounts where parent_id = new.id) then
    raise exception 'account % has children and cannot be marked postable', new.code using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger accounts_postable_guard
  before update of is_postable on accounts
  for each row when (new.is_postable and not old.is_postable)
  execute function app.tg_accounts_postable_guard();

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table account_categories enable row level security;
alter table accounts           enable row level security;

create policy acccat_select on account_categories for select using (app.is_member(org_id));
create policy acccat_write  on account_categories for all
  using (app.has_permission(org_id, 'accounts.write'))
  with check (app.has_permission(org_id, 'accounts.write'));

create policy account_select on accounts for select using (app.is_member(org_id));
create policy account_write  on accounts for all
  using (app.has_permission(org_id, 'accounts.write'))
  with check (app.has_permission(org_id, 'accounts.write'));

create trigger set_updated_at before update on account_categories for each row execute function app.tg_set_updated_at();
create trigger set_updated_at before update on accounts           for each row execute function app.tg_set_updated_at();

create trigger audit after insert or update or delete on account_categories for each row execute function app.tg_audit();
create trigger audit after insert or update or delete on accounts           for each row execute function app.tg_audit();
