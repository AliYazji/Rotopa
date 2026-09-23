-- Concurrency fixture #2: a real posted sales invoice, ONE line selling 10
-- units, with TWO draft sales_returns already created against it — each
-- for 8 units of that same line (16 > 10 — only one return may ever
-- legitimately post). Both drafts are created here, single-threaded and
-- safely (draft creation was never the unsafe part — post_sales_return()
-- is), then handed to two concurrent attempt_return.sql processes that
-- each try to POST their own draft at the same time.
\set ON_ERROR_STOP on

insert into auth.users (id, email) values ('c0000000-0000-0000-0000-000000000002','concurrency-returns@test')
  on conflict (id) do nothing;
select set_config('request.jwt.claim.sub','c0000000-0000-0000-0000-000000000002', false);
set role authenticated;

do $$
declare
  v_org uuid; v_parent uuid; v_inv uuid; v_cogs uuid; v_rev uuid; v_equity uuid; v_ar uuid; v_vat uuid;
  v_wh uuid; v_item uuid; v_cust uuid; v_invoice uuid; v_return_a uuid; v_return_b uuid;
begin
  v_org := create_organization('CONCRETORG','مؤسسة اختبار تزامن المرتجعات','NIS','شيكل',1);
  insert into accounts (org_id, code, name_ar, is_postable, nature) values (v_org,'PAR','a',false,'debit') returning id into v_parent;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'INV','b',v_parent,true,'debit') returning id into v_inv;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'COGS','c',v_parent,true,'debit') returning id into v_cogs;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'REV','d',v_parent,true,'credit') returning id into v_rev;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'EQ','e',v_parent,true,'credit') returning id into v_equity;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'AR','f',v_parent,false,'debit') returning id into v_ar;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'VATOUT','g',v_parent,true,'credit') returning id into v_vat;
  insert into warehouses (org_id, code, name_ar) values (v_org, 'W1', 'w') returning id into v_wh;
  insert into items (org_id, code, name_ar, inventory_account_id, cogs_account_id, sales_account_id)
  values (v_org, 'SKU-RET-RACE', 'صنف اختبار تزامن المرتجعات', v_inv, v_cogs, v_rev) returning id into v_item;
  v_cust := create_dealer(v_org, 'عميل اختبار تزامن', v_ar, p_is_customer := true);

  perform post_stock_move(create_stock_move(v_org, 'opening', current_date, 'رصيد افتتاحي',
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'warehouse_id', v_wh, 'direction', 'in', 'entered_qty', 100, 'unit_cost', 1))),
    v_equity);

  v_invoice := create_sales_invoice(v_org, current_date, v_cust, v_wh,
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 10, 'unit_price', 5)));
  perform post_sales_invoice(v_invoice, p_output_vat_account_id := v_vat);

  -- two drafts, each for 8 of the same 10-qty line — both created fine,
  -- since draft-time checking only ever counted OTHER already-POSTED
  -- returns (neither of these is posted yet, so neither sees the other)
  v_return_a := create_sales_return(v_org, v_invoice,
    jsonb_build_array(jsonb_build_object('invoice_line_id', (select id from sales_invoice_lines where invoice_id = v_invoice), 'qty', 8)));
  v_return_b := create_sales_return(v_org, v_invoice,
    jsonb_build_array(jsonb_build_object('invoice_line_id', (select id from sales_invoice_lines where invoice_id = v_invoice), 'qty', 8)));

  insert into concurrency_handshake (k, v) values
    ('ret_org_id', v_org), ('ret_vat_account_id', v_vat),
    ('ret_return_a', v_return_a), ('ret_return_b', v_return_b),
    ('ret_invoice_line_id', (select id from sales_invoice_lines where invoice_id = v_invoice));
end $$;

select k, v from concurrency_handshake where k like 'ret_%' order by k;
