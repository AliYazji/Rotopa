-- Weighted-average costing, transfer balance rule, negative-stock guard,
-- optional GL posting for adjustments.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values ('b1000000-0000-0000-0000-000000000001','inv@test');
select set_config('request.jwt.claim.sub','b1000000-0000-0000-0000-000000000001', true);
set local role authenticated;
select set_config('t.org', create_organization('INVORG','مؤسسة اختبار المخزون','NIS','شيكل',1)::text, true);

do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_base uuid := (select base_currency_id from organizations where id = v_org);
  v_inv_acc uuid; v_equity uuid; v_cogs uuid;
  v_wh1 uuid; v_wh2 uuid;
  v_item uuid;
  v_m1 uuid; v_m2 uuid; v_m3 uuid;
begin
  insert into accounts (org_id, code, name_ar, is_postable, nature) values (v_org,'INV','المخزون',true,'debit') returning id into v_inv_acc;
  insert into accounts (org_id, code, name_ar, is_postable, nature) values (v_org,'EQ','فروقات جرد',true,'credit') returning id into v_equity;
  insert into accounts (org_id, code, name_ar, is_postable, nature) values (v_org,'COGS','تكلفة البضاعة',true,'debit') returning id into v_cogs;

  insert into warehouses (org_id, code, name_ar) values (v_org,'W1','المستودع الرئيسي') returning id into v_wh1;
  insert into warehouses (org_id, code, name_ar) values (v_org,'W2','مستودع الفرع') returning id into v_wh2;

  insert into items (org_id, code, name_ar, inventory_account_id, cogs_account_id)
  values (v_org, 'SKU1', 'صنف تجريبي', v_inv_acc, v_cogs) returning id into v_item;

  -- 1) opening stock: 100 units @ 10 = 1000, posts Dr inventory / Cr equity
  v_m1 := create_stock_move(v_org, 'opening', current_date, 'رصيد افتتاحي',
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'warehouse_id', v_wh1, 'direction', 'in', 'entered_qty', 100, 'unit_cost', 10)));
  perform post_stock_move(v_m1, v_equity);
  assert item_stock_on_hand(v_item, v_wh1) = 100, 'should have 100 on hand';
  assert (select avg_cost from item_warehouse_balances where item_id=v_item and warehouse_id=v_wh1) = 10, 'avg cost should be 10';
  assert account_balance(v_inv_acc) = 1000, 'inventory account should show 1000';
  assert account_balance(v_equity) = -1000, 'equity should be credited 1000';

  -- 2) receive another 50 @ 16 -> new weighted average = (100*10 + 50*16)/150 = 12
  v_m2 := create_stock_move(v_org, 'adjustment_in', current_date, 'استلام إضافي',
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'warehouse_id', v_wh1, 'direction', 'in', 'entered_qty', 50, 'unit_cost', 16)));
  perform post_stock_move(v_m2, v_equity);
  assert item_stock_on_hand(v_item, v_wh1) = 150, 'should have 150 on hand';
  assert (select avg_cost from item_warehouse_balances where item_id=v_item and warehouse_id=v_wh1) = 12, 'weighted average should be 12';

  -- 3) transfer 40 units to warehouse 2. Deliberately pass a bogus unit_cost
  -- (999) on the "in" leg — the validator requires *some* number there, but
  -- post_stock_move must ignore it and use the source's real moving average
  -- (12) instead, so a transfer can never manufacture or destroy value.
  v_m3 := create_stock_move(v_org, 'transfer', current_date, 'تحويل بين مستودعين',
    jsonb_build_array(
      jsonb_build_object('item_id', v_item, 'warehouse_id', v_wh1, 'direction', 'out', 'entered_qty', 40),
      jsonb_build_object('item_id', v_item, 'warehouse_id', v_wh2, 'direction', 'in',  'entered_qty', 40, 'unit_cost', 999)
    ));
  perform post_stock_move(v_m3);
  assert item_stock_on_hand(v_item, v_wh1) = 110, 'source warehouse should drop to 110';
  assert item_stock_on_hand(v_item, v_wh2) = 40, 'destination warehouse should have 40';
  assert (select avg_cost from item_warehouse_balances where item_id=v_item and warehouse_id=v_wh2) = 12,
    'destination cost must be inherited from the source (12), not the bogus 999 supplied on the line';

  -- 4) sell (adjustment_out) 30 units from warehouse 1 at the CURRENT average (12), not a made-up price
  perform post_stock_move(
    create_stock_move(v_org, 'adjustment_out', current_date, 'صرف',
      jsonb_build_array(jsonb_build_object('item_id', v_item, 'warehouse_id', v_wh1, 'direction', 'out', 'entered_qty', 30))),
    v_equity);
  assert item_stock_on_hand(v_item, v_wh1) = 80, 'warehouse 1 should drop to 80';
  assert (select unit_cost from stock_move_lines where move_id in (select id from stock_moves where move_type='adjustment_out') limit 1) = 12,
    'the out-line cost should be computed as the moving average (12), not supplied by the caller';

  -- 5) cannot sell more than what's on hand
  begin
    perform post_stock_move(
      create_stock_move(v_org, 'adjustment_out', current_date, 'صرف زائد',
        jsonb_build_array(jsonb_build_object('item_id', v_item, 'warehouse_id', v_wh1, 'direction', 'out', 'entered_qty', 999))),
      v_equity);
    raise exception 'TEST FAIL: allowed stock to go negative';
  exception when sqlstate '23514' then null;
  end;

  -- 6) an item that isn't stock-tracked can't receive a stock move
  declare v_service uuid;
  begin
    insert into items (org_id, code, name_ar, is_stock_tracked) values (v_org, 'SVC', 'خدمة', false) returning id into v_service;
    begin
      perform create_stock_move(v_org, 'opening', current_date, 'خطأ متعمد',
        jsonb_build_array(jsonb_build_object('item_id', v_service, 'warehouse_id', v_wh1, 'direction', 'in', 'entered_qty', 1, 'unit_cost', 1)));
      raise exception 'TEST FAIL: created a stock move for a non-tracked item';
    exception when sqlstate '23514' then null;
    end;
  end;

  raise notice 'INVENTORY OK';
end $$;

rollback;
