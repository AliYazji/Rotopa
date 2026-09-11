-- void_stock_move(): reverses quantity/cost correctly (including a transfer's
-- two legs), mirrors the GL entry when one exists, and only posted moves
-- can be voided.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values ('e1000000-0000-0000-0000-000000000001','void-stock@test');
select set_config('request.jwt.claim.sub','e1000000-0000-0000-0000-000000000001', true);
set local role authenticated;
select set_config('t.org', create_organization('VSMORG','مؤسسة اختبار إلغاء الحركة','NIS','شيكل',1)::text, true);

do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_parent uuid; v_inv uuid; v_equity uuid;
  v_wh1 uuid; v_wh2 uuid; v_item uuid;
  v_m1 uuid; v_m2 uuid; v_rev uuid;
begin
  insert into accounts (org_id, code, name_ar, is_postable, nature) values (v_org,'INV','المخزون',true,'debit') returning id into v_inv;
  insert into accounts (org_id, code, name_ar, is_postable, nature) values (v_org,'EQ','حقوق',true,'credit') returning id into v_equity;
  insert into warehouses (org_id, code, name_ar) values (v_org,'W1','رئيسي') returning id into v_wh1;
  insert into warehouses (org_id, code, name_ar) values (v_org,'W2','فرعي') returning id into v_wh2;
  insert into items (org_id, code, name_ar, inventory_account_id, cogs_account_id)
  values (v_org, 'SKU1', 'صنف', v_inv, v_inv) returning id into v_item;

  -- 1) opening move WITH a GL posting, then void it: quantity and GL both reverse
  v_m1 := create_stock_move(v_org, 'opening', current_date, 'رصيد افتتاحي',
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'warehouse_id', v_wh1, 'direction', 'in', 'entered_qty', 50, 'unit_cost', 4)));
  perform post_stock_move(v_m1, v_equity);
  assert item_stock_on_hand(v_item, v_wh1) = 50, 'should have 50 after opening';
  assert account_balance(v_inv) = 200, 'inventory account should show 200 (50x4)';

  v_rev := void_stock_move(v_m1, current_date, 'اختبار');
  assert (select status from stock_moves where id = v_m1) = 'void', 'original move should be void';
  assert (select status from stock_moves where id = v_rev) = 'posted', 'reversal move should be posted';
  assert item_stock_on_hand(v_item, v_wh1) = 0, 'stock should return to 0';
  assert account_balance(v_inv) = 0, 'inventory account should return to 0';
  assert account_balance(v_equity) = 0, 'equity account should return to 0 too';

  -- 2) a transfer, then void it: both warehouses return to their prior state
  perform post_stock_move(create_stock_move(v_org, 'opening', current_date, 'إعادة تخزين',
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'warehouse_id', v_wh1, 'direction', 'in', 'entered_qty', 30, 'unit_cost', 5))));
  v_m2 := create_stock_move(v_org, 'transfer', current_date, 'تحويل',
    jsonb_build_array(
      jsonb_build_object('item_id', v_item, 'warehouse_id', v_wh1, 'direction', 'out', 'entered_qty', 20),
      jsonb_build_object('item_id', v_item, 'warehouse_id', v_wh2, 'direction', 'in',  'entered_qty', 20, 'unit_cost', 0)));
  perform post_stock_move(v_m2);
  assert item_stock_on_hand(v_item, v_wh1) = 10, 'source should drop to 10';
  assert item_stock_on_hand(v_item, v_wh2) = 20, 'destination should have 20';

  perform void_stock_move(v_m2, current_date, null);
  assert item_stock_on_hand(v_item, v_wh1) = 30, 'source should return to 30';
  assert item_stock_on_hand(v_item, v_wh2) = 0, 'destination should return to 0';

  -- 3) only a posted move can be voided — not a draft, not an already-void one
  declare v_draft uuid;
  begin
    v_draft := create_stock_move(v_org, 'opening', current_date, 'مسودة',
      jsonb_build_array(jsonb_build_object('item_id', v_item, 'warehouse_id', v_wh1, 'direction', 'in', 'entered_qty', 1, 'unit_cost', 1)));
    begin
      perform void_stock_move(v_draft, current_date, null);
      raise exception 'TEST FAIL: voided a draft move';
    exception when sqlstate '23514' then null;
    end;
  end;

  begin
    perform void_stock_move(v_m1, current_date, null);
    raise exception 'TEST FAIL: voided an already-void move';
  exception when sqlstate '23514' then null;
  end;

  raise notice 'VOID STOCK MOVE OK';
end $$;

rollback;
