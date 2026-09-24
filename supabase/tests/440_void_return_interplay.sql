-- Regression coverage for 20250911005000_void_return_interplay.sql.
--
-- Before this fix, void_sales_invoice()/void_purchase_invoice() never
-- checked for a related sales_returns/purchase_returns row at all — a
-- posted return already restocked/reversed part of the invoice, so
-- voiding the invoice on top of that double-counted the returned
-- portion; a draft return was left orphaned, pointing at a now-void
-- invoice. The genuinely concurrent version of the return-vs-void race is
-- covered separately with real OS-level concurrency in
-- supabase/tests/concurrency/run.sh's third scenario — this file covers
-- the sequential/deterministic scenarios.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values ('fc000000-0000-0000-0016-000000000001','owner@voidreturn.test');
select set_config('request.jwt.claim.sub','fc000000-0000-0000-0016-000000000001', true);
set local role authenticated;
select set_config('t.org', create_organization('VOIDRETORG','مؤسسة اختبار تداخل الإلغاء والمرتجع')::text, true);

do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_rev uuid; v_inv_acc uuid; v_cogs uuid; v_vat_out uuid; v_cust_ctrl uuid;
  v_wh uuid; v_item uuid; v_cust uuid;
  v_caught boolean; v_msg text;
begin
  select id into v_rev     from accounts where org_id = v_org and code = '61101';
  select id into v_inv_acc from accounts where org_id = v_org and code = '11601';
  select id into v_cogs    from accounts where org_id = v_org and code = '51101';
  select id into v_vat_out from accounts where org_id = v_org and code = '31401';
  select id into v_cust_ctrl from accounts where org_id = v_org and code = '11501';

  insert into warehouses (org_id, code, name_ar) values (v_org, 'W1', 'المستودع الرئيسي') returning id into v_wh;
  v_cust := create_dealer(v_org, 'عميل اختبار', v_cust_ctrl, p_is_customer := true);
  insert into items (org_id, code, name_ar, inventory_account_id, cogs_account_id, sales_account_id, sales_price)
  values (v_org, 'VRSKU', 'صنف اختبار', v_inv_acc, v_cogs, v_rev, 40)
  returning id into v_item;
  perform post_stock_move(create_stock_move(v_org, 'opening', current_date, 'رصيد افتتاحي',
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'warehouse_id', v_wh, 'direction', 'in', 'entered_qty', 1000, 'unit_cost', 10))),
    (select id from accounts where org_id = v_org and code = '41001'));

  -- =========================================================================
  -- 1) a PARTIAL POSTED return exists -> voiding the original invoice
  --    must be rejected
  -- =========================================================================
  declare v_inv1 uuid; v_line1 uuid; v_ret1 uuid; begin
    v_inv1 := create_sales_invoice(v_org, current_date, v_cust, v_wh,
      jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 10, 'unit_price', 40)));
    perform post_sales_invoice(v_inv1, p_output_vat_account_id := v_vat_out);
    v_line1 := (select id from sales_invoice_lines where invoice_id = v_inv1);

    v_ret1 := create_sales_return(v_org, v_inv1, jsonb_build_array(jsonb_build_object('invoice_line_id', v_line1, 'qty', 3)));
    perform post_sales_return(v_ret1, p_output_vat_account_id := v_vat_out);

    v_caught := false; v_msg := null;
    begin
      perform void_sales_invoice(v_inv1, current_date, 'محاولة إلغاء رغم وجود مرتجع مرحّل');
    exception when sqlstate '23514' then
      v_caught := true;
      get stacked diagnostics v_msg = message_text;
    end;
    assert v_caught, 'voiding an invoice with a posted (non-void) return should be rejected';
    assert v_msg ilike '%return%', 'the message should mention the return, got: ' || coalesce(v_msg, '<null>');
    assert (select status from sales_invoices where id = v_inv1) = 'posted', 'the invoice should remain posted after the rejected void attempt';

    -- reverse the return through its own proper path -> void should now succeed
    perform void_sales_return(v_ret1, current_date, 'عكس المرتجع قبل إلغاء الفاتورة');
    perform void_sales_invoice(v_inv1, current_date, 'إلغاء صحيح بعد عكس المرتجع');
    assert (select status from sales_invoices where id = v_inv1) = 'void', 'voiding should succeed once the return is itself void';
  end;

  -- =========================================================================
  -- 2) a DRAFT return exists (never posted) -> voiding the original
  --    invoice must also be rejected, with no silent auto-cancel of the draft
  -- =========================================================================
  declare v_inv2 uuid; v_line2 uuid; v_ret2 uuid; begin
    v_inv2 := create_sales_invoice(v_org, current_date, v_cust, v_wh,
      jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 10, 'unit_price', 40)));
    perform post_sales_invoice(v_inv2, p_output_vat_account_id := v_vat_out);
    v_line2 := (select id from sales_invoice_lines where invoice_id = v_inv2);

    v_ret2 := create_sales_return(v_org, v_inv2, jsonb_build_array(jsonb_build_object('invoice_line_id', v_line2, 'qty', 2)));
    assert (select status from sales_returns where id = v_ret2) = 'draft';

    v_caught := false;
    begin
      perform void_sales_invoice(v_inv2, current_date, 'محاولة إلغاء رغم وجود مسودة مرتجع');
    exception when sqlstate '23514' then v_caught := true;
    end;
    assert v_caught, 'voiding an invoice with a draft (non-void) return should be rejected too';
    assert (select status from sales_invoices where id = v_inv2) = 'posted', 'the invoice should remain posted';
    assert (select status from sales_returns where id = v_ret2) = 'draft', 'the draft return must NOT be silently cancelled — the function never touches it';

    -- the user cancels (deletes) the draft themselves -> void now succeeds
    delete from sales_returns where id = v_ret2;
    perform void_sales_invoice(v_inv2, current_date, 'إلغاء صحيح بعد حذف المسودة');
    assert (select status from sales_invoices where id = v_inv2) = 'void';
  end;

  -- =========================================================================
  -- 3) post_sales_return()'s OWN independent guard (added in
  --    20250911004900, alongside this migration's void-side guard): if
  --    the original invoice is no longer 'posted' by the time a draft
  --    return against it is posted, reject it. void_sales_invoice() now
  --    makes reaching this state through its own RPC impossible (scenario
  --    2 above already proved that) — the only real way it can still
  --    happen is the exact instant of a genuine concurrent race, covered
  --    separately with real OS-level concurrency in
  --    supabase/tests/concurrency/run.sh's third scenario. To test this
  --    guard deterministically here, the invoice's status is flipped
  --    directly to 'void' (RLS + app.tg_sales_invoice_guard() both permit
  --    a plain status='posted'->'void' UPDATE with every other column
  --    unchanged — the exact narrow case they exist to allow), bypassing
  --    void_sales_invoice() entirely, to isolate this specific guard from
  --    the void-side one already covered above.
  -- =========================================================================
  declare v_inv3 uuid; v_line3 uuid; v_ret3 uuid; begin
    v_inv3 := create_sales_invoice(v_org, current_date, v_cust, v_wh,
      jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 10, 'unit_price', 40)));
    perform post_sales_invoice(v_inv3, p_output_vat_account_id := v_vat_out);
    v_line3 := (select id from sales_invoice_lines where invoice_id = v_inv3);

    v_ret3 := create_sales_return(v_org, v_inv3, jsonb_build_array(jsonb_build_object('invoice_line_id', v_line3, 'qty', 2)));
    update sales_invoices set status = 'void' where id = v_inv3;
    assert (select status from sales_invoices where id = v_inv3) = 'void';

    v_caught := false; v_msg := null;
    begin
      perform post_sales_return(v_ret3, p_output_vat_account_id := v_vat_out);
    exception when sqlstate '23514' then
      v_caught := true;
      get stacked diagnostics v_msg = message_text;
    end;
    assert v_caught, 'posting a draft return whose original invoice is no longer posted should be rejected';
    assert v_msg ilike '%no longer posted%' or v_msg ilike '%status%', 'the message should explain the invoice is no longer posted, got: ' || coalesce(v_msg, '<null>');
    assert (select status from sales_returns where id = v_ret3) = 'draft', 'the rejected return should remain a draft';
  end;

  raise notice 'VOID/RETURN INTERPLAY OK';
end $$;

rollback;
