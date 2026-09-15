-- Stock reservations: available-to-promise math, hard cap at creation,
-- active-only editability, release/fulfill terminal states, delete guard.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values ('f8000000-0000-0000-0008-000000000001','resv@test');
select set_config('request.jwt.claim.sub','f8000000-0000-0000-0008-000000000001', true);
set local role authenticated;
select set_config('t.org', create_organization('RESVORG','مؤسسة اختبار الحجز','NIS','شيكل',1)::text, true);

do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_equity uuid; v_inv_acc uuid; v_cogs_acc uuid; v_wh uuid; v_item uuid; v_inactive_item uuid;
  v_r1 uuid; v_r2 uuid;
begin
  insert into accounts (org_id, code, name_ar, is_postable, nature) values (v_org,'EQ','حقوق',true,'credit') returning id into v_equity;
  insert into accounts (org_id, code, name_ar, is_postable, nature) values (v_org,'INV','المخزون',true,'debit') returning id into v_inv_acc;
  insert into accounts (org_id, code, name_ar, is_postable, nature) values (v_org,'COGS','تكلفة البضاعة',true,'debit') returning id into v_cogs_acc;
  insert into warehouses (org_id, code, name_ar) values (v_org,'W1','الرئيسي') returning id into v_wh;
  insert into items (org_id, code, name_ar, sales_price, inventory_account_id, cogs_account_id)
  values (v_org, 'SKU1', 'صنف', 10, v_inv_acc, v_cogs_acc) returning id into v_item;
  insert into items (org_id, code, name_ar, sales_price, inventory_account_id, cogs_account_id, is_active)
  values (v_org, 'SKU2', 'صنف غير نشط', 10, v_inv_acc, v_cogs_acc, false) returning id into v_inactive_item;

  perform post_stock_move(create_stock_move(v_org, 'opening', current_date, 'رصيد افتتاحي',
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'warehouse_id', v_wh, 'direction', 'in', 'entered_qty', 50, 'unit_cost', 5))),
    v_equity);

  assert item_available_to_promise(v_item, v_wh) = 50, 'nothing reserved yet -> all 50 available';

  -- 1) reserve 20 -> 30 remain available
  v_r1 := reserve_stock(v_org, v_item, v_wh, 20, p_notes := 'حجز أول');
  assert item_available_to_promise(v_item, v_wh) = 30, 'available should drop to 30 (50 - 20)';
  assert item_reserved_qty(v_item, v_wh) = 20, 'reserved qty should read 20';

  -- 2) cannot reserve more than what's available
  begin
    perform reserve_stock(v_org, v_item, v_wh, 35);
    raise exception 'TEST FAIL: reserved beyond what is available to promise';
  exception when sqlstate '23514' then null;
  end;

  -- 3) reserve exactly the remaining 30 -> available hits 0
  v_r2 := reserve_stock(v_org, v_item, v_wh, 30);
  assert item_available_to_promise(v_item, v_wh) = 0, 'available should be exactly 0 now';

  -- 4) zero/negative/inactive-item/inactive-warehouse reservations all rejected
  begin
    perform reserve_stock(v_org, v_item, v_wh, 0);
    raise exception 'TEST FAIL: reserved zero quantity';
  exception when sqlstate '23514' then null;
  end;
  begin
    perform reserve_stock(v_org, v_inactive_item, v_wh, 1);
    raise exception 'TEST FAIL: reserved an inactive item';
  exception when sqlstate '23514' then null;
  end;

  -- 5) an active reservation's quantity cannot be edited directly (only notes)
  begin
    update stock_reservations set qty = 999 where id = v_r1;
    raise exception 'TEST FAIL: edited an active reservation''s quantity';
  exception when sqlstate '23514' then null;
  end;
  update stock_reservations set notes = 'ملاحظة محدّثة' where id = v_r1;
  assert (select notes from stock_reservations where id = v_r1) = 'ملاحظة محدّثة', 'notes should stay editable while active';

  -- 6) release the first reservation -> its 20 becomes available again
  perform release_stock_reservation(v_r1, 'الزبون غيّر رأيه');
  assert (select status from stock_reservations where id = v_r1) = 'released', 'reservation should be released';
  assert item_available_to_promise(v_item, v_wh) = 20, 'available should go back up by the released 20';

  -- 7) a released reservation is terminal: cannot release/fulfill/edit again
  begin
    perform release_stock_reservation(v_r1, null);
    raise exception 'TEST FAIL: released an already-released reservation';
  exception when sqlstate '23514' then null;
  end;
  begin
    perform fulfill_stock_reservation(v_r1);
    raise exception 'TEST FAIL: fulfilled an already-released reservation';
  exception when sqlstate '23514' then null;
  end;
  begin
    update stock_reservations set notes = 'x' where id = v_r1;
    raise exception 'TEST FAIL: edited a released reservation';
  exception when sqlstate '23514' then null;
  end;

  -- 8) fulfill the second reservation
  perform fulfill_stock_reservation(v_r2);
  assert (select status from stock_reservations where id = v_r2) = 'fulfilled', 'reservation should be fulfilled';

  -- 9) delete guard: terminal reservations cannot be deleted, a fresh active one can
  begin
    delete from stock_reservations where id = v_r1;
    raise exception 'TEST FAIL: deleted a released reservation';
  exception when sqlstate '23514' then null;
  end;
  declare v_r3 uuid;
  begin
    v_r3 := reserve_stock(v_org, v_item, v_wh, 5);
    delete from stock_reservations where id = v_r3;
    assert not exists (select 1 from stock_reservations where id = v_r3), 'an untouched active reservation should be deletable';
  end;

  raise notice 'STOCK RESERVATIONS OK';
end $$;

rollback;
