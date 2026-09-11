-- ============================================================================
-- Rotopa · Module 04 (completion) — create a dealer AND its ledger account
-- together, atomically.
--
-- Every dealer needs a postable account of its own (accounts.is_postable is
-- enforced by dealer_account_check, module 04). Doing that by hand — create
-- the account, note its id, then create the dealer — is exactly the kind of
-- two-step, easy-to-get-wrong process this project exists to remove. One
-- call: pick the parent header account (e.g. «11200 العملاء»), name the
-- dealer, get both rows back correctly wired.
-- ============================================================================

create or replace function create_dealer(
  p_org uuid,
  p_name_ar text,
  p_parent_account_id uuid,
  p_is_customer boolean default false,
  p_is_supplier boolean default false,
  p_is_employee boolean default false,
  p_currency_id uuid default null,
  p_credit_limit numeric default 0,
  p_phone text default null,
  p_email text default null,
  p_address text default null,
  p_city text default null,
  p_tax_no text default null,
  p_code text default null           -- optional explicit dealer code; auto-generated otherwise
) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_parent accounts%rowtype;
  v_account_id uuid;
  v_dealer_id uuid;
  v_suffix int;
  v_code text;
  v_attempt int := 0;
begin
  perform app.require_permission(p_org, 'dealers.write');
  if not (p_is_customer or p_is_supplier or p_is_employee) then
    raise exception 'a dealer needs at least one role (customer/supplier/employee)' using errcode = '23514';
  end if;

  select * into v_parent from accounts where id = p_parent_account_id;
  if not found or v_parent.org_id <> p_org then
    raise exception 'parent account not found in this organization' using errcode = '23503';
  end if;
  if v_parent.is_postable then
    raise exception 'account % is postable and cannot take a new dealer sub-account; pick a header account', v_parent.code
      using errcode = '23514';
  end if;

  -- generate a free child code under the parent (retry on the rare race with
  -- another dealer being created under the same parent at the same time)
  loop
    v_attempt := v_attempt + 1;
    select coalesce(max(nullif(regexp_replace(a.code::text, '^' || v_parent.code::text, ''), '')::int), 0) + 1
      into v_suffix
    from accounts a
    where a.org_id = p_org and a.parent_id = p_parent_account_id
      and a.code::text ~ ('^' || v_parent.code::text || '[0-9]+$');
    v_code := v_parent.code::text || lpad(v_suffix::text, 2, '0');
    begin
      insert into accounts (org_id, code, name_ar, parent_id, category_id, nature, is_postable, currency_id)
      values (p_org, v_code, p_name_ar, p_parent_account_id, v_parent.category_id, v_parent.nature, true, p_currency_id)
      returning id into v_account_id;
      exit;
    exception when unique_violation then
      if v_attempt >= 5 then raise; end if;
    end;
  end loop;

  insert into dealers (org_id, code, name_ar, is_customer, is_supplier, is_employee, account_id,
                        currency_id, credit_limit, phone, email, address, city, tax_no)
  values (p_org, coalesce(p_code, 'D' || to_char(now(), 'YYMMDDHH24MISS') || floor(random()*100)::int),
          p_name_ar, p_is_customer, p_is_supplier, p_is_employee, v_account_id,
          p_currency_id, coalesce(p_credit_limit,0), p_phone, p_email, p_address, p_city, p_tax_no)
  returning id into v_dealer_id;

  return v_dealer_id;
end;
$$;

revoke all on function create_dealer(uuid,text,uuid,boolean,boolean,boolean,uuid,numeric,text,text,text,text,text,text) from public, anon;
grant execute on function create_dealer(uuid,text,uuid,boolean,boolean,boolean,uuid,numeric,text,text,text,text,text,text) to authenticated;
