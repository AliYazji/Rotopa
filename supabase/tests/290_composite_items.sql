-- Composite items assembled AT SALE TIME (not batch-manufactured ahead of
-- time like module 09's manufacturing_orders) — an "ice cream cup" made of
-- ice cream + biscuit + topping + a spoon, consumed the moment it's sold.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values
  ('f8000000-0000-0000-0008-000000000001','owner@composite.test');
select set_config('request.jwt.claim.sub','f8000000-0000-0000-0008-000000000001', true);
set local role authenticated;
select set_config('t.org', create_organization('COMPORG','مؤسسة اختبار المنتج المركب','NIS','شيكل',1)::text, true);

do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_parent uuid; v_ar uuid; v_rawinv uuid; v_cogs uuid; v_othercogs uuid; v_sales uuid; v_equity uuid; v_vat_out uuid;
  v_wh uuid; v_cust uuid;
  v_icecream uuid; v_biscuit uuid; v_topping uuid; v_spoon uuid; v_cup uuid; v_otheritem uuid;
  v_inv uuid; s record;
  before_biscuit numeric; before_topping numeric; before_spoon numeric; before_icecream numeric; before_rawinv numeric;
begin
  insert into accounts (org_id, code, name_ar, is_postable, nature) values (v_org,'PAR','a',false,'debit') returning id into v_parent;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'AR','ذمم عملاء',v_parent,true,'debit') returning id into v_ar;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'RAWINV','مخزون خام',v_parent,true,'debit') returning id into v_rawinv;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'CUPCOGS','تكلفة الأكواب',v_parent,true,'debit') returning id into v_cogs;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'OTHERCOGS','تكلفة الصنف العادي',v_parent,true,'debit') returning id into v_othercogs;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'SALES','المبيعات',v_parent,true,'credit') returning id into v_sales;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'EQ','حقوق الملكية',v_parent,true,'credit') returning id into v_equity;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'VATOUT','ضريبة مخرجات',v_parent,true,'credit') returning id into v_vat_out;

  insert into warehouses (org_id, code, name_ar) values (v_org, 'W1', 'الرئيسي') returning id into v_wh;
  insert into dealers (org_id, code, name_ar, is_customer, account_id) values (v_org,'C1','زبون',true,v_ar) returning id into v_cust;

  -- real, stock-tracked components
  insert into items (org_id, code, name_ar, inventory_account_id, cogs_account_id) values (v_org,'ICECREAM','بوظة',v_rawinv,v_rawinv) returning id into v_icecream;
  insert into items (org_id, code, name_ar, inventory_account_id, cogs_account_id) values (v_org,'BISCUIT','بسكويت',v_rawinv,v_rawinv) returning id into v_biscuit;
  insert into items (org_id, code, name_ar, inventory_account_id, cogs_account_id) values (v_org,'TOPPING','زينة',v_rawinv,v_rawinv) returning id into v_topping;
  insert into items (org_id, code, name_ar, inventory_account_id, cogs_account_id) values (v_org,'SPOON','ملعقة',v_rawinv,v_rawinv) returning id into v_spoon;
  insert into items (org_id, code, name_ar, inventory_account_id, cogs_account_id, sales_account_id, sales_price) values (v_org,'OTHER','صنف عادي',v_rawinv,v_othercogs,v_sales,15) returning id into v_otheritem;

  -- opening stock, distinct costs per component
  perform post_stock_move(create_stock_move(v_org, 'opening', current_date, 'رصيد بوظة',
    jsonb_build_array(jsonb_build_object('item_id', v_icecream, 'warehouse_id', v_wh, 'direction', 'in', 'entered_qty', 100, 'unit_cost', 10))), v_equity);
  perform post_stock_move(create_stock_move(v_org, 'opening', current_date, 'رصيد بسكويت',
    jsonb_build_array(jsonb_build_object('item_id', v_biscuit, 'warehouse_id', v_wh, 'direction', 'in', 'entered_qty', 100, 'unit_cost', 1))), v_equity);
  perform post_stock_move(create_stock_move(v_org, 'opening', current_date, 'رصيد زينة',
    jsonb_build_array(jsonb_build_object('item_id', v_topping, 'warehouse_id', v_wh, 'direction', 'in', 'entered_qty', 100, 'unit_cost', 0.5))), v_equity);
  perform post_stock_move(create_stock_move(v_org, 'opening', current_date, 'رصيد ملاعق',
    jsonb_build_array(jsonb_build_object('item_id', v_spoon, 'warehouse_id', v_wh, 'direction', 'in', 'entered_qty', 100, 'unit_cost', 0.2))), v_equity);
  perform post_stock_move(create_stock_move(v_org, 'opening', current_date, 'رصيد صنف عادي',
    jsonb_build_array(jsonb_build_object('item_id', v_otheritem, 'warehouse_id', v_wh, 'direction', 'in', 'entered_qty', 50, 'unit_cost', 5))), v_equity);

  -- =========================================================================
  -- 1) the composite item — no stock ledger, has its own sales price + COGS account
  -- =========================================================================
  insert into items (org_id, code, name_ar, is_composite, is_stock_tracked, cogs_account_id, sales_account_id, sales_price)
  values (v_org, 'CUP', 'محقن بوظة', true, false, v_cogs, v_sales, 12) returning id into v_cup;

  -- can't post-consistency-check: is_composite item cannot ALSO be stock-tracked
  begin
    insert into items (org_id, code, name_ar, is_composite, is_stock_tracked) values (v_org, 'BAD', 'x', true, true);
    raise exception 'TEST FAIL: created a composite item that also tracks its own stock';
  exception when sqlstate '23514' then null;
  end;

  -- recipe: 1 cup = 0.2 ice cream + 1 biscuit + 0.1 topping + 1 spoon
  insert into bom_lines (org_id, finished_item_id, component_item_id, qty) values
    (v_org, v_cup, v_icecream, 0.2),
    (v_org, v_cup, v_biscuit, 1),
    (v_org, v_cup, v_topping, 0.1),
    (v_org, v_cup, v_spoon, 1);

  assert item_composite_buildable_qty(v_cup, v_wh) = 100, 'buildable qty should be limited by the tightest component (all at 100 here after scaling)';

  -- =========================================================================
  -- 2) posting fails without a recipe / without a COGS account
  -- =========================================================================
  declare v_nobom uuid; v_nocogs uuid; v_badinv uuid;
  begin
    insert into items (org_id, code, name_ar, is_composite, is_stock_tracked, sales_account_id, sales_price)
    values (v_org, 'NOBOM', 'بلا وصفة', true, false, v_sales, 5) returning id into v_nobom;
    v_badinv := create_sales_invoice(v_org, current_date, v_cust, v_wh, jsonb_build_array(jsonb_build_object('item_id', v_nobom, 'qty', 1, 'unit_price', 5)));
    begin
      perform post_sales_invoice(v_badinv, p_output_vat_account_id := v_vat_out);
      raise exception 'TEST FAIL: posted a composite item with no recipe';
    exception when sqlstate '23514' then null;
    end;

    insert into items (org_id, code, name_ar, is_composite, is_stock_tracked, sales_account_id, sales_price)
    values (v_org, 'NOCOGS', 'بلا حساب تكلفة', true, false, v_sales, 5) returning id into v_nocogs;
    insert into bom_lines (org_id, finished_item_id, component_item_id, qty) values (v_org, v_nocogs, v_biscuit, 1);
    v_badinv := create_sales_invoice(v_org, current_date, v_cust, v_wh, jsonb_build_array(jsonb_build_object('item_id', v_nocogs, 'qty', 1, 'unit_price', 5)));
    begin
      perform post_sales_invoice(v_badinv, p_output_vat_account_id := v_vat_out);
      raise exception 'TEST FAIL: posted a composite item with no COGS account';
    exception when sqlstate '23514' then null;
    end;
  end;

  -- =========================================================================
  -- 3) real sale: 5 cups + 2 of a normal item on the SAME invoice
  -- =========================================================================
  before_icecream := item_stock_on_hand(v_icecream, v_wh);
  before_biscuit := item_stock_on_hand(v_biscuit, v_wh);
  before_topping := item_stock_on_hand(v_topping, v_wh);
  before_spoon := item_stock_on_hand(v_spoon, v_wh);
  before_rawinv := account_balance(v_rawinv);

  v_inv := create_sales_invoice(v_org, current_date, v_cust, v_wh,
    jsonb_build_array(
      jsonb_build_object('item_id', v_cup, 'qty', 5, 'unit_price', 12),
      jsonb_build_object('item_id', v_otheritem, 'qty', 2, 'unit_price', 15)
    ));
  perform post_sales_invoice(v_inv, p_output_vat_account_id := v_vat_out);

  -- components consumed by exactly 5x the recipe
  assert item_stock_on_hand(v_icecream, v_wh) = before_icecream - 1, 'ice cream should drop by 5*0.2=1';
  assert item_stock_on_hand(v_biscuit, v_wh) = before_biscuit - 5, 'biscuit should drop by 5*1=5';
  assert item_stock_on_hand(v_topping, v_wh) = before_topping - 0.5, 'topping should drop by 5*0.1=0.5';
  assert item_stock_on_hand(v_spoon, v_wh) = before_spoon - 5, 'spoon should drop by 5*1=5';
  -- the composite item itself never carries stock
  assert not exists (select 1 from item_warehouse_balances where item_id = v_cup), 'the composite item should never have its own stock balance row';
  -- the normal item on the same invoice still works exactly as always
  assert item_stock_on_hand(v_otheritem, v_wh) = 48, 'the ordinary item on the same invoice should deduct normally (50-2)';

  -- cost check: 5 cups * (0.2*10 + 1*1 + 0.1*0.5 + 1*0.2) = 5 * (2+1+0.05+0.2) = 5*3.25 = 16.25
  assert account_balance(v_cogs) = 16.25, 'composite COGS should equal 5x the recipe cost at real component averages';
  assert account_balance(v_rawinv) = before_rawinv - 16.25 - (2*5), 'raw-material inventory should drop by both the composite consumption and the ordinary item sale';

  -- the journal entry balances
  select sum(debit) as d, sum(credit) as c into s from journal_lines where entry_id = (select journal_entry_id from sales_invoices where id = v_inv);
  assert s.d = s.c, 'the combined invoice entry (composite + ordinary line) must balance';

  -- =========================================================================
  -- 4) void restores the components at their ORIGINAL sale-time cost
  --    (precision under a changed recipe/cost is covered separately in
  --    supabase/tests/450_composite_void_precision.sql)
  -- =========================================================================
  perform void_sales_invoice(v_inv, current_date, 'اختبار الإلغاء');
  assert item_stock_on_hand(v_icecream, v_wh) = before_icecream, 'ice cream should be fully restored';
  assert item_stock_on_hand(v_biscuit, v_wh) = before_biscuit, 'biscuit should be fully restored';
  assert item_stock_on_hand(v_topping, v_wh) = before_topping, 'topping should be fully restored';
  assert item_stock_on_hand(v_spoon, v_wh) = before_spoon, 'spoon should be fully restored';
  assert item_stock_on_hand(v_otheritem, v_wh) = 50, 'the ordinary item should also be fully restored';
  assert not exists (select 1 from item_warehouse_balances where item_id = v_cup), 'the composite item should still have no stock balance row after void';

  -- =========================================================================
  -- 5) returning a composite item is explicitly rejected
  -- =========================================================================
  v_inv := create_sales_invoice(v_org, current_date, v_cust, v_wh,
    jsonb_build_array(jsonb_build_object('item_id', v_cup, 'qty', 1, 'unit_price', 12)));
  perform post_sales_invoice(v_inv, p_output_vat_account_id := v_vat_out);
  declare v_inv_line uuid; v_caught boolean; v_msg text; begin
    v_inv_line := (select id from sales_invoice_lines where invoice_id = v_inv);
    v_caught := false;
    begin
      perform create_sales_return(v_org, v_inv, jsonb_build_array(jsonb_build_object('invoice_line_id', v_inv_line, 'qty', 1)));
    exception when sqlstate '23514' then
      v_caught := true;
      get stacked diagnostics v_msg = message_text;
    end;
    assert v_caught, 'TEST FAIL: created a return for a composite item';
    assert v_msg ilike '%composite%', 'the rejection should specifically be about the composite item, not some other 23514, got: ' || coalesce(v_msg, '<null>');
  end;

  raise notice 'COMPOSITE ITEMS OK';
end $$;

rollback;
