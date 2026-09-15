-- Invoice due dates + AR/AP aging: default due_date, explicit terms, FIFO
-- open-amount allocation against a real partial payment, bucket
-- classification, reconciliation to the real GL balance, cash invoices
-- excluded, invalid due_date rejected.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values ('f6000000-0000-0000-0006-000000000001','aging@test');
select set_config('request.jwt.claim.sub','f6000000-0000-0000-0006-000000000001', true);
set local role authenticated;
select set_config('t.org', create_organization('AGEORG','مؤسسة اختبار الأعمار','NIS','شيكل',1)::text, true);

do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_parent uuid; v_ar uuid; v_ap uuid; v_cash uuid; v_sales_acc uuid; v_inv_acc uuid; v_cogs_acc uuid; v_equity uuid;
  v_vat_out uuid; v_vat_in uuid;
  v_wh uuid; v_item uuid; v_cust uuid; v_supp uuid;
  v_s1 uuid; v_s2 uuid; v_s3 uuid; v_scash uuid; v_p1 uuid; v_p2 uuid;
  v_receipt uuid; v_payment uuid;
  v_row record; v_sum numeric; v_count int;
begin
  insert into accounts (org_id, code, name_ar, is_postable, nature) values (v_org,'PAR','أصول',false,'debit') returning id into v_parent;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'AR','ذمم عملاء',v_parent,true,'debit') returning id into v_ar;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'AP','ذمم موردين',v_parent,true,'credit') returning id into v_ap;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'CASH','الصندوق',v_parent,true,'debit') returning id into v_cash;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'SALES','المبيعات',v_parent,true,'credit') returning id into v_sales_acc;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'INV','المخزون',v_parent,true,'debit') returning id into v_inv_acc;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'COGS','تكلفة البضاعة',v_parent,true,'debit') returning id into v_cogs_acc;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'EQ','حقوق الملكية',v_parent,true,'credit') returning id into v_equity;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'VATOUT','ضريبة مخرجات',v_parent,true,'credit') returning id into v_vat_out;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'VATIN','ضريبة مدخلات',v_parent,true,'debit') returning id into v_vat_in;

  insert into warehouses (org_id, code, name_ar) values (v_org,'W1','الرئيسي') returning id into v_wh;
  insert into dealers (org_id, code, name_ar, is_customer, account_id) values (v_org,'C1','عميل',true,v_ar) returning id into v_cust;
  insert into dealers (org_id, code, name_ar, is_supplier, account_id) values (v_org,'S1','مورد',true,v_ap) returning id into v_supp;

  insert into items (org_id, code, name_ar, inventory_account_id, cogs_account_id, sales_account_id, sales_price)
  values (v_org, 'SKU1', 'صنف', v_inv_acc, v_cogs_acc, v_sales_acc, 25) returning id into v_item;

  perform post_stock_move(create_stock_move(v_org, 'opening', current_date - 60, 'رصيد افتتاحي',
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'warehouse_id', v_wh, 'direction', 'in', 'entered_qty', 1000, 'unit_cost', 10))),
    v_equity);

  -- 1) due_date defaults to invoice_date when not given; also a cash sale (never touches AR, so must never appear in aging)
  v_scash := create_sales_invoice(v_org, current_date - 50, v_cust, v_wh,
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 1, 'unit_price', 25)),
    p_payment_method := 'cash', p_cash_account_id := v_cash);
  assert (select due_date from sales_invoices where id = v_scash) = current_date - 50, 'due_date should default to invoice_date';
  perform post_sales_invoice(v_scash, p_output_vat_account_id := v_vat_out);

  -- 2) explicit due_date before invoice_date is rejected
  begin
    perform create_sales_invoice(v_org, current_date, v_cust, v_wh,
      jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 1, 'unit_price', 25)),
      p_due_date := current_date - 1);
    raise exception 'TEST FAIL: accepted a due_date before the invoice date';
  exception when sqlstate '23514' then null;
  end;

  -- 3) three real credit invoices, 100 subtotal each (4 x 25), 116 incl. VAT.
  --    Dated 60/30/5 days ago with 30-day terms -> due 30 days ago / today / +25 days.
  v_s1 := create_sales_invoice(v_org, current_date - 60, v_cust, v_wh,
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 4, 'unit_price', 25)),
    p_due_date := current_date - 30);
  v_s2 := create_sales_invoice(v_org, current_date - 30, v_cust, v_wh,
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 4, 'unit_price', 25)),
    p_due_date := current_date);
  v_s3 := create_sales_invoice(v_org, current_date - 5, v_cust, v_wh,
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 4, 'unit_price', 25)),
    p_due_date := current_date + 25);
  perform post_sales_invoice(v_s1, p_output_vat_account_id := v_vat_out);
  perform post_sales_invoice(v_s2, p_output_vat_account_id := v_vat_out);
  perform post_sales_invoice(v_s3, p_output_vat_account_id := v_vat_out);

  assert account_balance(v_ar) = round(3*116, 2), 'AR should carry all 3 credit invoices (the cash one never touches AR)';

  -- 4) partial receipt: 150 -> covers invoice 1 (116) fully + 34 of invoice 2's 116
  v_receipt := create_voucher(v_org, 'receipt', current_date - 2, 'تحصيل جزئي', v_cash,
    (select base_currency_id from organizations where id = v_org),
    jsonb_build_array(jsonb_build_object('account_id', v_ar, 'amount', 150, 'dealer_id', v_cust)));
  perform post_voucher(v_receipt);
  assert account_balance(v_ar) = round(3*116 - 150, 2), 'AR should drop by the 150 collected';

  -- 5) aging as of today: invoice1 fully paid (excluded), invoice2 partially open, invoice3 fully open
  v_count := 0; v_sum := 0;
  for v_row in select * from ar_aging_detail(v_org, current_date) where dealer_id = v_cust loop
    v_count := v_count + 1;
    v_sum := v_sum + v_row.open_amount;
    if v_row.invoice_id = v_s1 then raise exception 'TEST FAIL: fully-paid invoice 1 should not appear in aging'; end if;
    if v_row.invoice_id = v_s2 then
      assert round(v_row.open_amount,2) = round(116 - 34, 2), 'invoice 2 should show 82 still open (116 - 34 applied)';
      assert v_row.bucket = 'not_due', 'invoice 2 is due exactly today -> not_due bucket';
    end if;
    if v_row.invoice_id = v_s3 then
      assert v_row.open_amount = 116, 'invoice 3 should be fully open (payment already exhausted on invoice 2)';
      assert v_row.bucket = 'not_due', 'invoice 3 due in the future -> not_due';
    end if;
  end loop;
  assert v_count = 2, 'exactly 2 invoices should still be open (invoice 1 and the cash invoice excluded)';
  assert round(v_sum, 2) = round(account_balance(v_ar), 2), 'aging must reconcile exactly to the real AR balance — no invented or lost money';

  -- 6) push "as of" past invoice 2's due date -> it becomes overdue
  for v_row in select * from ar_aging_detail(v_org, current_date + 40) where invoice_id = v_s2 loop
    assert v_row.bucket = '31_60', 'invoice 2, 40 days past its due date, should land in the 31-60 bucket';
  end loop;

  -- =========================================================================
  -- AP mirror
  -- =========================================================================
  v_p1 := create_purchase_invoice(v_org, current_date - 40, v_supp, v_wh,
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 10, 'unit_price', 12)), p_due_date := current_date - 10);
  v_p2 := create_purchase_invoice(v_org, current_date - 10, v_supp, v_wh,
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 10, 'unit_price', 12)), p_due_date := current_date + 20);
  perform post_purchase_invoice(v_p1, v_vat_in);
  perform post_purchase_invoice(v_p2, v_vat_in);

  -- each: 10 x 12 = 120 subtotal, 139.20 incl. VAT; pay off exactly invoice 1
  v_payment := create_voucher(v_org, 'payment', current_date - 1, 'سداد جزئي', v_cash,
    (select base_currency_id from organizations where id = v_org),
    jsonb_build_array(jsonb_build_object('account_id', v_ap, 'amount', 139.20, 'dealer_id', v_supp)));
  perform post_voucher(v_payment);

  v_count := 0; v_sum := 0;
  for v_row in select * from ap_aging_detail(v_org, current_date) loop
    v_count := v_count + 1;
    v_sum := v_sum + v_row.open_amount;
    if v_row.invoice_id = v_p1 then raise exception 'TEST FAIL: fully-paid purchase invoice should not appear'; end if;
    if v_row.invoice_id = v_p2 then assert v_row.bucket = 'not_due', 'purchase invoice 2 not yet due'; end if;
  end loop;
  assert v_count = 1, 'exactly 1 open purchase invoice';
  assert round(v_sum, 2) = round(-account_balance(v_ap), 2), 'AP aging must reconcile to the real AP balance';

  raise notice 'DUE DATES + AGING OK';
end $$;

rollback;
