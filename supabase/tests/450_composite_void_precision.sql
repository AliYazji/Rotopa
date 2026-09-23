-- Regression coverage for 20250911005100_composite_void_precision.sql.
--
-- Before this fix, void_sales_invoice()'s composite-item restock leg
-- re-derived "what to put back" from the LIVE bom_lines recipe and the
-- CURRENT item_warehouse_balances.avg_cost at the moment of the void — not
-- from what was actually consumed and expensed at the moment of the sale.
-- This test changes BOTH the recipe and a component's moving average AFTER
-- the sale, then voids, and proves the reversal still exactly matches the
-- ORIGINAL sale: original components (including one since REMOVED from the
-- recipe), original quantities, original cost — and never touches a
-- component that was only added to the recipe afterward.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values
  ('f9000000-0000-0000-0009-000000000001','owner@compositevoid.test');
select set_config('request.jwt.claim.sub','f9000000-0000-0000-0009-000000000001', true);
set local role authenticated;
select set_config('t.org', create_organization('CVPORG','مؤسسة اختبار دقة إلغاء المنتج المركب','NIS','شيكل',1)::text, true);

do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_parent uuid; v_ar uuid; v_rawinv uuid; v_cogs uuid; v_sales uuid; v_equity uuid; v_vat_out uuid;
  v_wh uuid; v_cust uuid;
  v_icecream uuid; v_biscuit uuid; v_topping uuid; v_spoon uuid; v_napkin uuid; v_cup uuid;
  v_inv uuid; v_move uuid;
  before_icecream numeric; before_biscuit numeric; before_topping numeric; before_spoon numeric;
  before_void_icecream numeric;
  v_void_icecream_cost numeric; v_void_spoon_qty numeric;
begin
  insert into accounts (org_id, code, name_ar, is_postable, nature) values (v_org,'PAR','a',false,'debit') returning id into v_parent;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'AR','ذمم عملاء',v_parent,true,'debit') returning id into v_ar;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'RAWINV','مخزون خام',v_parent,true,'debit') returning id into v_rawinv;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'CUPCOGS','تكلفة الأكواب',v_parent,true,'debit') returning id into v_cogs;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'SALES','المبيعات',v_parent,true,'credit') returning id into v_sales;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'EQ','حقوق الملكية',v_parent,true,'credit') returning id into v_equity;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'VATOUT','ضريبة مخرجات',v_parent,true,'credit') returning id into v_vat_out;

  insert into warehouses (org_id, code, name_ar) values (v_org, 'W1', 'الرئيسي') returning id into v_wh;
  insert into dealers (org_id, code, name_ar, is_customer, account_id) values (v_org,'C1','زبون',true,v_ar) returning id into v_cust;

  insert into items (org_id, code, name_ar, inventory_account_id, cogs_account_id) values (v_org,'ICECREAM','بوظة',v_rawinv,v_rawinv) returning id into v_icecream;
  insert into items (org_id, code, name_ar, inventory_account_id, cogs_account_id) values (v_org,'BISCUIT','بسكويت',v_rawinv,v_rawinv) returning id into v_biscuit;
  insert into items (org_id, code, name_ar, inventory_account_id, cogs_account_id) values (v_org,'TOPPING','زينة',v_rawinv,v_rawinv) returning id into v_topping;
  insert into items (org_id, code, name_ar, inventory_account_id, cogs_account_id) values (v_org,'SPOON','ملعقة',v_rawinv,v_rawinv) returning id into v_spoon;
  insert into items (org_id, code, name_ar, inventory_account_id, cogs_account_id) values (v_org,'NAPKIN','منديل',v_rawinv,v_rawinv) returning id into v_napkin;

  perform post_stock_move(create_stock_move(v_org, 'opening', current_date, 'رصيد بوظة',
    jsonb_build_array(jsonb_build_object('item_id', v_icecream, 'warehouse_id', v_wh, 'direction', 'in', 'entered_qty', 100, 'unit_cost', 10))), v_equity);
  perform post_stock_move(create_stock_move(v_org, 'opening', current_date, 'رصيد بسكويت',
    jsonb_build_array(jsonb_build_object('item_id', v_biscuit, 'warehouse_id', v_wh, 'direction', 'in', 'entered_qty', 100, 'unit_cost', 1))), v_equity);
  perform post_stock_move(create_stock_move(v_org, 'opening', current_date, 'رصيد زينة',
    jsonb_build_array(jsonb_build_object('item_id', v_topping, 'warehouse_id', v_wh, 'direction', 'in', 'entered_qty', 100, 'unit_cost', 0.5))), v_equity);
  perform post_stock_move(create_stock_move(v_org, 'opening', current_date, 'رصيد ملاعق',
    jsonb_build_array(jsonb_build_object('item_id', v_spoon, 'warehouse_id', v_wh, 'direction', 'in', 'entered_qty', 100, 'unit_cost', 0.2))), v_equity);

  insert into items (org_id, code, name_ar, is_composite, is_stock_tracked, cogs_account_id, sales_account_id, sales_price)
  values (v_org, 'CUP', 'محقن بوظة', true, false, v_cogs, v_sales, 12) returning id into v_cup;

  -- original recipe: 1 cup = 0.2 ice cream + 1 biscuit + 0.1 topping + 1 spoon
  insert into bom_lines (org_id, finished_item_id, component_item_id, qty) values
    (v_org, v_cup, v_icecream, 0.2),
    (v_org, v_cup, v_biscuit, 1),
    (v_org, v_cup, v_topping, 0.1),
    (v_org, v_cup, v_spoon, 1);

  before_icecream := item_stock_on_hand(v_icecream, v_wh);
  before_biscuit := item_stock_on_hand(v_biscuit, v_wh);
  before_topping := item_stock_on_hand(v_topping, v_wh);
  before_spoon := item_stock_on_hand(v_spoon, v_wh);

  -- =========================================================================
  -- sell 5 cups at the ORIGINAL recipe / ORIGINAL component costs
  -- =========================================================================
  v_inv := create_sales_invoice(v_org, current_date, v_cust, v_wh,
    jsonb_build_array(jsonb_build_object('item_id', v_cup, 'qty', 5, 'unit_price', 12)));
  perform post_sales_invoice(v_inv, p_output_vat_account_id := v_vat_out);

  assert item_stock_on_hand(v_icecream, v_wh) = before_icecream - 1,   'ice cream should drop by 5*0.2=1';
  assert item_stock_on_hand(v_biscuit, v_wh)  = before_biscuit - 5,    'biscuit should drop by 5*1=5';
  assert item_stock_on_hand(v_topping, v_wh)  = before_topping - 0.5,  'topping should drop by 5*0.1=0.5';
  assert item_stock_on_hand(v_spoon, v_wh)    = before_spoon - 5,      'spoon should drop by 5*1=5';

  -- =========================================================================
  -- AFTER the sale, change both the ice cream cost AND the recipe itself:
  --   * a large new receipt at a very different cost moves the moving
  --     average far away from the 10 that was actually charged at sale time
  --   * the recipe drops "spoon" (still owed a restock from the ORIGINAL
  --     sale) and gains "napkin" (never part of the original sale at all)
  -- =========================================================================
  perform post_stock_move(create_stock_move(v_org, 'opening', current_date, 'دفعة بوظة جديدة بسعر مختلف تمامًا',
    jsonb_build_array(jsonb_build_object('item_id', v_icecream, 'warehouse_id', v_wh, 'direction', 'in', 'entered_qty', 100, 'unit_cost', 100))), v_equity);
  perform post_stock_move(create_stock_move(v_org, 'opening', current_date, 'رصيد مناديل',
    jsonb_build_array(jsonb_build_object('item_id', v_napkin, 'warehouse_id', v_wh, 'direction', 'in', 'entered_qty', 50, 'unit_cost', 0.3))), v_equity);

  delete from bom_lines where finished_item_id = v_cup and component_item_id = v_spoon;
  insert into bom_lines (org_id, finished_item_id, component_item_id, qty) values (v_org, v_cup, v_napkin, 1);

  -- baseline taken AFTER the extra receipt (a full restore must add exactly
  -- the 1 unit originally consumed on top of whatever is on hand right now)
  before_void_icecream := item_stock_on_hand(v_icecream, v_wh);

  -- sanity: the recipe really did change (buildable qty would now derive from napkin, not spoon)
  assert not exists (select 1 from bom_lines where finished_item_id = v_cup and component_item_id = v_spoon),
    'sanity: spoon should no longer be part of the recipe';
  assert exists (select 1 from bom_lines where finished_item_id = v_cup and component_item_id = v_napkin),
    'sanity: napkin should now be part of the recipe';

  -- =========================================================================
  -- void the ORIGINAL sale — must reverse what was ACTUALLY sold, not
  -- what the recipe/costs look like now
  -- =========================================================================
  perform void_sales_invoice(v_inv, current_date, 'اختبار دقة الإلغاء بعد تغيير الوصفة والتكلفة');

  -- every ORIGINAL component is restored by its ORIGINAL quantity, including
  -- "spoon" which the CURRENT recipe no longer even mentions
  assert item_stock_on_hand(v_icecream, v_wh) = before_void_icecream + 1, 'ice cream should gain back exactly the 1 unit originally consumed, regardless of the recipe/cost change since';
  assert item_stock_on_hand(v_biscuit, v_wh)  = before_biscuit,  'biscuit should be fully restored';
  assert item_stock_on_hand(v_topping, v_wh)  = before_topping,  'topping should be fully restored';
  assert item_stock_on_hand(v_spoon, v_wh)    = before_spoon,    'spoon must still be restored by the void even though it was removed from the CURRENT recipe';

  -- napkin was never part of the ORIGINAL sale (only added to the recipe
  -- afterward) — the void must NOT touch it at all
  assert item_stock_on_hand(v_napkin, v_wh) = 50, 'napkin was never part of the original sale — the void must not move it';

  -- the void must have restocked ice cream at its ORIGINAL frozen cost (10),
  -- never the inflated current average (~55.23 after the 100-unit@100 receipt)
  select sml.unit_cost into v_void_icecream_cost
  from stock_move_lines sml join stock_moves sm on sm.id = sml.move_id
  where sm.source_type = 'sales_invoice_void' and sm.source_id = v_inv and sml.item_id = v_icecream;
  assert v_void_icecream_cost = 10, 'the void must restock ice cream at the ORIGINAL cost charged at sale time (10), got: ' || coalesce(v_void_icecream_cost::text, '<null>');

  -- the void's restock move must exist for spoon even though it is gone from bom_lines
  select sml.entered_qty into v_void_spoon_qty
  from stock_move_lines sml join stock_moves sm on sm.id = sml.move_id
  where sm.source_type = 'sales_invoice_void' and sm.source_id = v_inv and sml.item_id = v_spoon;
  assert v_void_spoon_qty = 5, 'the void must restock exactly the 5 spoons that were originally consumed, got: ' || coalesce(v_void_spoon_qty::text, '<null>');

  -- and it must NOT contain any line for napkin at all
  assert not exists (
    select 1 from stock_move_lines sml join stock_moves sm on sm.id = sml.move_id
    where sm.source_type = 'sales_invoice_void' and sm.source_id = v_inv and sml.item_id = v_napkin
  ), 'the void must not create any stock movement for napkin — it was never part of the original sale';

  raise notice 'COMPOSITE VOID PRECISION OK';
end $$;

rollback;
