-- Regression coverage for 20250911004200_sector_validation.sql.
--
-- Before this fix, create_organization(p_sector => 'pharmacy') (or any of
-- the other 7 sectors reserved in organizations.sector's check constraint
-- but with no real app.seed_coa_<sector>() template) passed validation
-- silently and got the restaurant/hotel chart anyway — the org would look
-- correctly tagged sector='pharmacy' while actually running the wrong
-- chart of accounts, with nothing surfacing the mismatch. Now it must be
-- rejected outright, with no organization row (partial or otherwise) left
-- behind, and the two real sectors must keep working exactly as before.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values ('fc000000-0000-0000-000f-000000000001','owner@sectorval.test');
select set_config('request.jwt.claim.sub','fc000000-0000-0000-000f-000000000001', true);
set local role authenticated;

do $$
declare
  v_before_count int;
  v_after_count int;
  v_caught boolean;
  v_msg text;
  v_org uuid;
begin
  -- =========================================================================
  -- 1) an unimplemented-but-named sector (pharmacy) must fail outright, and
  --    leave absolutely no organization row behind — not even a partial one
  -- =========================================================================
  select count(*) into v_before_count from organizations;

  v_caught := false;
  begin
    perform create_organization('PHARMORG', 'صيدلية اختبار', 'NIS', 'شيكل', 1, 'pharmacy');
  exception when others then
    v_caught := true;
    get stacked diagnostics v_msg = message_text;
  end;
  assert v_caught, 'creating an org with sector=pharmacy should raise, not succeed';
  assert v_msg ilike '%not implemented%', 'error message should say the sector template is not implemented, got: ' || coalesce(v_msg, '<null>');

  select count(*) into v_after_count from organizations;
  assert v_after_count = v_before_count, 'a rejected sector-template org creation must leave no partial organization row';
  assert not exists (select 1 from organizations where code = 'PHARMORG'), 'no organization row should exist for the failed pharmacy attempt';
  assert not exists (select 1 from accounts a join organizations o on o.id = a.org_id where o.code = 'PHARMORG'), 'no account rows should exist either — nothing to seed for an org that was never created';

  -- =========================================================================
  -- 2) another unimplemented sector (salon) — same guard, not a one-off
  --    special case for "pharmacy" specifically
  -- =========================================================================
  v_caught := false;
  begin
    perform create_organization('SALONORG', 'صالون اختبار', 'NIS', 'شيكل', 1, 'salon');
  exception when others then
    v_caught := true;
  end;
  assert v_caught, 'creating an org with sector=salon should raise too';
  assert not exists (select 1 from organizations where code = 'SALONORG'), 'no organization row should exist for the failed salon attempt';

  -- =========================================================================
  -- 3) the two real sectors must keep working exactly as before
  -- =========================================================================
  v_org := create_organization('RESTVALORG', 'مطعم اختبار صريح', 'NIS', 'شيكل', 1, 'restaurant_hotel');
  assert v_org is not null, 'restaurant_hotel org creation should still succeed';
  assert (select sector from organizations where id = v_org) = 'restaurant_hotel';
  assert (select count(*) from accounts where org_id = v_org) = 285, 'restaurant_hotel org should still seed the 285-account chart';

  v_org := create_organization('MFGVALORG', 'مصنع اختبار صريح', 'NIS', 'شيكل', 1, 'manufacturing');
  assert v_org is not null, 'manufacturing org creation should still succeed';
  assert (select sector from organizations where id = v_org) = 'manufacturing';
  assert (select count(*) from accounts where org_id = v_org) = 233, 'manufacturing org should still seed the 233-account chart';

  -- omitting p_sector entirely must still default to restaurant_hotel
  v_org := create_organization('DEFVALORG', 'مؤسسة اختبار بلا قطاع');
  assert (select sector from organizations where id = v_org) = 'restaurant_hotel', 'omitting p_sector should still default to restaurant_hotel';

  raise notice 'SECTOR VALIDATION OK';
end $$;

rollback;
