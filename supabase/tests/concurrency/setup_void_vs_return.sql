-- Concurrency fixture #3: a posted sales invoice with ONE draft return
-- already created against it. Two concurrent processes then race to (a)
-- post that draft return, (b) void the invoice — exactly one of the two
-- must win; the other must be rejected, and the final state must be
-- self-consistent (never "invoice voided AND its return posted" at once).
\set ON_ERROR_STOP on

insert into auth.users (id, email) values ('c0000000-0000-0000-0000-000000000003','concurrency-voidret@test')
  on conflict (id) do nothing;
select set_config('request.jwt.claim.sub','c0000000-0000-0000-0000-000000000003', false);
set role authenticated;

do $$
declare
  v_org uuid; v_parent uuid; v_inv uuid; v_cogs uuid; v_rev uuid; v_equity uuid; v_ar uuid; v_vat uuid;
  v_wh uuid; v_item uuid; v_cust uuid; v_invoice uuid; v_return uuid;
begin
  v_org := create_organization('CONCVOIDRETORG','مؤسسة اختبار تزامن الإلغاء والمرتجع','NIS','شيكل',1);
  insert into accounts (org_id, code, name_ar, is_postable, nature) values (v_org,'PAR','a',false,'debit') returning id into v_parent;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'INV','b',v_parent,true,'debit') returning id into v_inv;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'COGS','c',v_parent,true,'debit') returning id into v_cogs;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'REV','d',v_parent,true,'credit') returning id into v_rev;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'EQ','e',v_parent,true,'credit') returning id into v_equity;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'AR','f',v_parent,false,'debit') returning id into v_ar;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'VATOUT','g',v_parent,true,'credit') returning id into v_vat;
  insert into warehouses (org_id, code, name_ar) values (v_org, 'W1', 'w') returning id into v_wh;
  insert into items (org_id, code, name_ar, inventory_account_id, cogs_account_id, sales_account_id)
  values (v_org, 'SKU-VOIDRET-RACE', 'صنف اختبار تزامن', v_inv, v_cogs, v_rev) returning id into v_item;
  v_cust := create_dealer(v_org, 'عميل اختبار', v_ar, p_is_customer := true);

  perform post_stock_move(create_stock_move(v_org, 'opening', current_date, 'رصيد افتتاحي',
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'warehouse_id', v_wh, 'direction', 'in', 'entered_qty', 100, 'unit_cost', 1))),
    v_equity);

  v_invoice := create_sales_invoice(v_org, current_date, v_cust, v_wh,
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 10, 'unit_price', 5)));
  perform post_sales_invoice(v_invoice, p_output_vat_account_id := v_vat);

  v_return := create_sales_return(v_org, v_invoice,
    jsonb_build_array(jsonb_build_object('invoice_line_id', (select id from sales_invoice_lines where invoice_id = v_invoice), 'qty', 3)));

  insert into concurrency_handshake (k, v) values
    ('vr_invoice_id', v_invoice), ('vr_return_id', v_return), ('vr_vat_account_id', v_vat);
end $$;

select k, v from concurrency_handshake where k like 'vr_%' order by k;
