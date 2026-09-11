-- Purchase invoice: Dr inventory / Cr AP-or-cash at the invoice's own cost,
-- credit vs cash, void removes stock at current average and reverses, guards.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values ('d1000000-0000-0000-0000-000000000001','purchases@test');
select set_config('request.jwt.claim.sub','d1000000-0000-0000-0000-000000000001', true);
set local role authenticated;
select set_config('t.org', create_organization('PURORG','مؤسسة اختبار المشتريات','NIS','شيكل',1)::text, true);

do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_parent uuid; v_ap uuid; v_cash uuid; v_inv_acc uuid; v_cogs_acc uuid;
  v_wh uuid; v_item uuid; v_supp uuid;
  v_inv1 uuid; v_inv2 uuid; v_entry uuid;
begin
  insert into accounts (org_id, code, name_ar, is_postable, nature) values (v_org,'PAR','أصول',false,'debit') returning id into v_parent;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'AP','ذمم موردين',v_parent,true,'credit') returning id into v_ap;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'CASH','الصندوق',v_parent,true,'debit') returning id into v_cash;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'INV','المخزون',v_parent,true,'debit') returning id into v_inv_acc;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'COGS','تكلفة البضاعة',v_parent,true,'debit') returning id into v_cogs_acc;

  insert into warehouses (org_id, code, name_ar) values (v_org,'W1','الرئيسي') returning id into v_wh;
  insert into dealers (org_id, code, name_ar, is_supplier, account_id) values (v_org,'S1','مورد',true,v_ap) returning id into v_supp;

  insert into items (org_id, code, name_ar, inventory_account_id, cogs_account_id)
  values (v_org, 'SKU1', 'صنف', v_inv_acc, v_cogs_acc) returning id into v_item;

  -- 1) credit purchase: 100 units @ 10, 10% discount -> net cost 9/unit
  v_inv1 := create_purchase_invoice(v_org, current_date, v_supp, v_wh,
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 100, 'unit_price', 10, 'discount_pct', 10)));
  v_entry := post_purchase_invoice(v_inv1);

  assert item_stock_on_hand(v_item, v_wh) = 100, 'stock should be 100 after the purchase';
  assert account_balance(v_inv_acc) = 900, 'inventory should be debited 900 (100 x net 9)';
  assert account_balance(v_ap) = -900, 'AP should be credited 900';
  assert (select unit_cost from stock_move_lines sml join purchase_invoices pi on pi.stock_move_id = sml.move_id where pi.id = v_inv1) = 9,
    'stock move line should carry the net unit cost (9), not the gross price (10)';
  assert (select sum(debit) from journal_lines where entry_id = v_entry) = (select sum(credit) from journal_lines where entry_id = v_entry),
    'purchase entry must balance';

  -- 2) cash purchase: 5 units @ 20 (no discount) -> Dr cash never touched, Cr cash instead of AP
  v_inv2 := create_purchase_invoice(v_org, current_date, v_supp, v_wh,
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 5, 'unit_price', 20)),
    p_payment_method := 'cash', p_cash_account_id := v_cash);
  perform post_purchase_invoice(v_inv2);
  assert account_balance(v_cash) = -100, 'cash should be credited 100 (5 x 20)';
  assert account_balance(v_ap) = -900, 'AP should be unaffected by the cash purchase';
  assert item_stock_on_hand(v_item, v_wh) = 105, 'stock should rise to 105';
  -- weighted average after adding 5 @ 20 to 100 @ 9: (900 + 100) / 105
  assert round((select avg_cost from item_warehouse_balances where item_id = v_item and warehouse_id = v_wh), 4) = round(1000.0/105, 4),
    'moving average should reflect the new higher-cost batch';

  -- 3) void the credit purchase: removes 100 units at CURRENT average (not the original 9), reverses the entry
  perform void_purchase_invoice(v_inv1, current_date, 'اختبار الإلغاء');
  assert (select status from purchase_invoices where id = v_inv1) = 'void', 'invoice should be void';
  assert item_stock_on_hand(v_item, v_wh) = 5, 'stock should drop back to just the cash purchase''s 5 units';
  assert account_balance(v_ap) = 0, 'AP should net back to 0 for the voided invoice''s effect';
  assert account_balance(v_inv_acc) = 100, 'inventory should net back to just the cash purchase''s 100 (5 x 20)';

  -- 4) cannot void past what remains (simulate by trying to void the cash
  --    purchase after separately draining stock below its own quantity)
  perform post_stock_move(create_stock_move(v_org, 'adjustment_out', current_date, 'تصريف',
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'warehouse_id', v_wh, 'direction', 'out', 'entered_qty', 4))));
  assert item_stock_on_hand(v_item, v_wh) = 1, 'only 1 unit should remain';
  begin
    perform void_purchase_invoice(v_inv2, current_date, null);
    raise exception 'TEST FAIL: voided a purchase whose stock was already consumed';
  exception when sqlstate '23514' then null;
  end;

  -- 5) posted invoice is immutable
  begin
    update purchase_invoices set description = 'tampered' where id = v_inv2;
    raise exception 'TEST FAIL: edited a posted invoice';
  exception when sqlstate '23514' then null;
  end;

  -- 6) posted invoice cannot be deleted (delete-guard), only voided
  begin
    delete from purchase_invoices where id = v_inv2;
    raise exception 'TEST FAIL: deleted a posted invoice';
  exception when sqlstate '23514' then null;
  end;

  -- 7) a dealer that is not a supplier cannot receive a purchase invoice
  declare v_customer_only uuid; v_ar uuid;
  begin
    insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'AR','ذمم عملاء',v_parent,true,'debit') returning id into v_ar;
    insert into dealers (org_id, code, name_ar, is_customer, account_id) values (v_org,'C1','عميل',true,v_ar) returning id into v_customer_only;
    begin
      perform create_purchase_invoice(v_org, current_date, v_customer_only, v_wh,
        jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 1, 'unit_price', 10)));
      raise exception 'TEST FAIL: created a purchase invoice for a non-supplier';
    exception when sqlstate '23514' then null;
    end;
  end;

  raise notice 'PURCHASES OK';
end $$;

rollback;
