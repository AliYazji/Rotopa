-- Manufacturing / composite items: BOM-driven component consumption, fully-
-- loaded finished-good costing (material + labor/equipment/subcontractor/
-- other), void reversal, and the usual guards.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values
  ('f7000000-0000-0000-0007-000000000001','owner@mfg.test'),
  ('f7000000-0000-0000-0007-000000000002','viewer@mfg.test');
select set_config('request.jwt.claim.sub','f7000000-0000-0000-0007-000000000001', true);
set local role authenticated;
select set_config('t.org', create_organization('MFGORG','مؤسسة اختبار التصنيع','NIS','شيكل',1)::text, true);

do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_parent uuid; v_raw_inv uuid; v_fin_inv uuid; v_equity uuid; v_labor uuid; v_equip uuid;
  v_wh uuid; v_compA uuid; v_compB uuid; v_finished uuid;
  v_mo uuid; v_viewer_role uuid;
  s record; entry record;
begin
  insert into accounts (org_id, code, name_ar, is_postable, nature) values (v_org,'PAR','a',false,'debit') returning id into v_parent;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'RAWINV','مخزون مواد خام',v_parent,true,'debit') returning id into v_raw_inv;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'FININV','مخزون تام الصنع',v_parent,true,'debit') returning id into v_fin_inv;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'EQ','حقوق الملكية',v_parent,true,'credit') returning id into v_equity;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'LABOR','أجور مستحقة',v_parent,true,'credit') returning id into v_labor;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'EQUIP','مصاريف معدات',v_parent,true,'credit') returning id into v_equip;

  insert into warehouses (org_id, code, name_ar) values (v_org, 'W1', 'الرئيسي') returning id into v_wh;
  insert into items (org_id, code, name_ar, inventory_account_id, cogs_account_id) values (v_org, 'COMPA', 'مكوّن أ', v_raw_inv, v_raw_inv) returning id into v_compA;
  insert into items (org_id, code, name_ar, inventory_account_id, cogs_account_id) values (v_org, 'COMPB', 'مكوّن ب', v_raw_inv, v_raw_inv) returning id into v_compB;
  insert into items (org_id, code, name_ar, inventory_account_id, cogs_account_id) values (v_org, 'FIN', 'منتج مُصنَّع', v_fin_inv, v_fin_inv) returning id into v_finished;

  -- opening stock: 100 of A at cost 5, 100 of B at cost 2
  perform post_stock_move(create_stock_move(v_org, 'opening', current_date, 'رصيد افتتاحي أ',
    jsonb_build_array(jsonb_build_object('item_id', v_compA, 'warehouse_id', v_wh, 'direction', 'in', 'entered_qty', 100, 'unit_cost', 5))), v_equity);
  perform post_stock_move(create_stock_move(v_org, 'opening', current_date, 'رصيد افتتاحي ب',
    jsonb_build_array(jsonb_build_object('item_id', v_compB, 'warehouse_id', v_wh, 'direction', 'in', 'entered_qty', 100, 'unit_cost', 2))), v_equity);

  -- =========================================================================
  -- 1) define the BOM: 1 finished unit = 2 of A + 3 of B
  -- =========================================================================
  insert into bom_lines (org_id, finished_item_id, component_item_id, qty) values
    (v_org, v_finished, v_compA, 2),
    (v_org, v_finished, v_compB, 3);

  -- self-reference is rejected outright
  begin
    insert into bom_lines (org_id, finished_item_id, component_item_id, qty) values (v_org, v_finished, v_finished, 1);
    raise exception 'TEST FAIL: a BOM line referenced its own finished item as a component';
  exception when sqlstate '23514' then null;
  end;

  -- =========================================================================
  -- 2) create a manufacturing order for 10 units — lines auto-derived from
  --    the BOM (2*10=20 of A, 3*10=30 of B)
  -- =========================================================================
  v_mo := create_manufacturing_order(v_org, current_date, v_finished, v_wh, 10);
  assert (select count(*) from manufacturing_order_lines where order_id = v_mo) = 2, 'should have 2 lines, one per BOM component';
  assert (select qty from manufacturing_order_lines where order_id = v_mo and component_item_id = v_compA) = 20, 'component A qty should be 2*10=20';
  assert (select qty from manufacturing_order_lines where order_id = v_mo and component_item_id = v_compB) = 30, 'component B qty should be 3*10=30';

  -- =========================================================================
  -- 3) post with labor + equipment costs, no subcontractor/other
  -- =========================================================================
  -- missing the labor account should be rejected since labor_cost > 0
  update manufacturing_orders set labor_cost = 200, equipment_cost = 50 where id = v_mo;
  begin
    perform post_manufacturing_order(v_mo, p_equipment_account_id := v_equip);
    raise exception 'TEST FAIL: posted without a labor account despite a labor cost';
  exception when sqlstate '23514' then null;
  end;

  perform post_manufacturing_order(v_mo, p_labor_account_id := v_labor, p_equipment_account_id := v_equip);
  assert (select status from manufacturing_orders where id = v_mo) = 'posted', 'order should be posted';

  -- material cost = 20*5 + 30*2 = 100+60 = 160; + overhead 200+50 = 250; total 410 / 10 units = 41/unit
  assert item_stock_on_hand(v_finished, v_wh) = 10, 'finished good stock should be exactly the order qty';
  assert item_stock_on_hand(v_compA, v_wh) = 80, 'component A should drop by 20 (100-20)';
  assert item_stock_on_hand(v_compB, v_wh) = 70, 'component B should drop by 30 (100-30)';
  assert account_balance(v_fin_inv) = 410, 'finished-goods inventory should carry the full material+overhead cost (160+250)';
  assert account_balance(v_raw_inv) = (100*5 + 100*2) - 160, 'raw-material inventory should drop by exactly the material cost consumed';
  assert account_balance(v_labor) = -200, 'labor account should be credited 200 (a credit-normal balance shows negative under debit-credit)';
  assert account_balance(v_equip) = -50, 'equipment account should be credited 50';

  -- the journal entry must balance (it always does by construction, but assert it explicitly)
  select sum(debit) as d, sum(credit) as c into entry from journal_lines where entry_id = (select journal_entry_id from manufacturing_orders where id = v_mo);
  assert entry.d = entry.c, 'the manufacturing journal entry should balance';
  assert entry.d = 410, 'the entry total should be the fully-loaded finished cost';

  -- =========================================================================
  -- 4) posted order is immutable; its lines are frozen
  -- =========================================================================
  begin
    update manufacturing_orders set qty = 99 where id = v_mo;
    raise exception 'TEST FAIL: modified a posted manufacturing order';
  exception when sqlstate '23514' then null;
  end;
  begin
    delete from manufacturing_orders where id = v_mo;
    raise exception 'TEST FAIL: deleted a posted manufacturing order';
  exception when sqlstate '23514' then null;
  end;

  -- =========================================================================
  -- 5) void reverses both legs and mirrors the financial entry
  -- =========================================================================
  perform void_manufacturing_order(v_mo, current_date, 'اختبار الإلغاء');
  assert (select status from manufacturing_orders where id = v_mo) = 'void', 'original order should be void';
  assert item_stock_on_hand(v_finished, v_wh) = 0, 'finished good stock should return to 0';
  assert item_stock_on_hand(v_compA, v_wh) = 100, 'component A should be fully restored';
  assert item_stock_on_hand(v_compB, v_wh) = 100, 'component B should be fully restored';
  assert account_balance(v_fin_inv) = 0, 'finished-goods inventory should net back to 0';

  -- =========================================================================
  -- 6) explicit p_lines overrides the BOM entirely
  -- =========================================================================
  declare v_mo2 uuid;
  begin
    v_mo2 := create_manufacturing_order(v_org, current_date, v_finished, v_wh, 5,
      jsonb_build_array(jsonb_build_object('component_item_id', v_compA, 'qty', 999)));
    assert (select count(*) from manufacturing_order_lines where order_id = v_mo2) = 1, 'explicit lines should override the BOM (only 1 line, not 2)';
    assert (select qty from manufacturing_order_lines where order_id = v_mo2) = 999, 'explicit qty should be used as-is, not derived from the BOM';
    -- over-consuming (999 > 100 on hand) should fail at posting
    begin
      perform post_manufacturing_order(v_mo2);
      raise exception 'TEST FAIL: posted a manufacturing order that oversells a component';
    exception when sqlstate '23514' then null;
    end;
    delete from manufacturing_orders where id = v_mo2;
  end;

  -- =========================================================================
  -- 7) a draft order with no BOM and no explicit lines is rejected outright
  -- =========================================================================
  declare v_compC uuid;
  begin
    insert into items (org_id, code, name_ar, inventory_account_id, cogs_account_id) values (v_org, 'NOBOM', 'صنف بلا وصفة', v_fin_inv, v_fin_inv) returning id into v_compC;
    begin
      perform create_manufacturing_order(v_org, current_date, v_compC, v_wh, 1);
      raise exception 'TEST FAIL: created a manufacturing order for an item with no BOM and no explicit lines';
    exception when sqlstate '23514' then null;
    end;
  end;

  -- =========================================================================
  -- 8) permission gating — a viewer cannot create or post
  -- =========================================================================
  select id into v_viewer_role from roles where org_id = v_org and code = 'viewer';
  insert into memberships (org_id, user_id, role_id) values (v_org, 'f7000000-0000-0000-0007-000000000002', v_viewer_role);
  perform set_config('request.jwt.claim.sub', 'f7000000-0000-0000-0007-000000000002', true);
  begin
    perform create_manufacturing_order(v_org, current_date, v_finished, v_wh, 1);
    raise exception 'TEST FAIL: a viewer created a manufacturing order';
  exception when sqlstate '42501' then null;
  end;
  perform set_config('request.jwt.claim.sub', 'f7000000-0000-0000-0007-000000000001', true);

  raise notice 'MANUFACTURING OK';
end $$;

rollback;
