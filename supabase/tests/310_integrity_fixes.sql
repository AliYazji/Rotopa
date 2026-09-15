-- Two fixes from a full-system integrity audit: the orphaned zero-arg
-- app.vat_rate() overload is gone, and bom_lines now validates cross-org
-- item references like every other detail table in the schema.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values
  ('fa000000-0000-0000-000a-000000000001','owner@integrity.test'),
  ('fa000000-0000-0000-000a-000000000002','owner2@integrity.test');
select set_config('request.jwt.claim.sub','fa000000-0000-0000-000a-000000000001', true);
set local role authenticated;
select set_config('t.org1', create_organization('INTORG1','مؤسسة اختبار التكامل 1','NIS','شيكل',1)::text, true);

select set_config('request.jwt.claim.sub','fa000000-0000-0000-000a-000000000002', true);
select set_config('t.org2', create_organization('INTORG2','مؤسسة اختبار التكامل 2','NIS','شيكل',1)::text, true);

do $$
declare
  v_org1 uuid := current_setting('t.org1')::uuid;
  v_org2 uuid := current_setting('t.org2')::uuid;
  v_item1 uuid; v_item1b uuid; v_item2 uuid;
begin
  -- =========================================================================
  -- 1) the old zero-arg app.vat_rate() is gone; the per-org one still works
  -- =========================================================================
  begin
    perform app.vat_rate();
    raise exception 'TEST FAIL: the orphaned zero-arg app.vat_rate() still exists';
  exception when undefined_function then null;
  end;
  assert app.vat_rate(v_org1) = 0.16, 'app.vat_rate(org_id) should still work normally';

  -- =========================================================================
  -- 2) bom_lines now rejects a recipe mixing items from two organizations
  -- =========================================================================
  perform set_config('request.jwt.claim.sub','fa000000-0000-0000-000a-000000000001', true);
  insert into items (org_id, code, name_ar, is_stock_tracked) values (v_org1, 'FIN1', 'صنف مصنّع 1', false) returning id into v_item1;
  insert into items (org_id, code, name_ar, is_stock_tracked) values (v_org1, 'COMP1', 'مكوّن 1', false) returning id into v_item1b;

  perform set_config('request.jwt.claim.sub','fa000000-0000-0000-000a-000000000002', true);
  insert into items (org_id, code, name_ar, is_stock_tracked) values (v_org2, 'FIN2', 'صنف مصنّع 2', false) returning id into v_item2;

  perform set_config('request.jwt.claim.sub','fa000000-0000-0000-000a-000000000001', true);
  begin
    insert into bom_lines (org_id, finished_item_id, component_item_id, qty) values (v_org1, v_item1, v_item2, 1);
    raise exception 'TEST FAIL: created a BOM line with a component from another organization';
  exception when sqlstate '23503' then null;
  end;
  begin
    insert into bom_lines (org_id, finished_item_id, component_item_id, qty) values (v_org1, v_item2, v_item1b, 1);
    raise exception 'TEST FAIL: created a BOM line with a finished item from another organization';
  exception when sqlstate '23503' then null;
  end;

  -- a normal, same-org recipe still works exactly as before
  insert into bom_lines (org_id, finished_item_id, component_item_id, qty) values (v_org1, v_item1, v_item1b, 2);
  assert (select qty from bom_lines where finished_item_id = v_item1 and component_item_id = v_item1b) = 2,
    'a same-org BOM line should still insert normally';

  raise notice 'INTEGRITY FIXES OK';
end $$;

rollback;
