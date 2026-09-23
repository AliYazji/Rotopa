-- Regression coverage for 20250911004700_void_journal_entry_source_protection.sql.
--
-- Before this fix, void_journal_entry() never checked source_type at all —
-- it would void a module-sourced entry (e.g. a sales invoice's own
-- journal_entries row) directly, reversing only the GL side while the
-- owning document (sales_invoices.status) stayed 'posted' forever: a
-- permanent split between the document and its ledger. Also, a draft
-- entry's source_type/source_id could be freely rewritten by direct
-- UPDATE (RLS only checked status='draft', not the source columns).
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values ('fc000000-0000-0000-0013-000000000001','owner@voidsource.test');
select set_config('request.jwt.claim.sub','fc000000-0000-0000-0013-000000000001', true);
set local role authenticated;
select set_config('t.org', create_organization('VOIDSRCORG','مؤسسة اختبار حماية مصدر القيد')::text, true);

do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_cash uuid; v_rev uuid; v_inv_acc uuid; v_cogs uuid; v_vat_out uuid; v_cust_ctrl uuid;
  v_wh uuid; v_item uuid; v_cust uuid;
  v_cur uuid;
  v_manual_entry uuid;
  v_invoice uuid; v_invoice_entry uuid;
  v_reversal_entry uuid;
  v_caught boolean; v_msg text;
  v_rows int;
begin
  v_cur := (select base_currency_id from organizations where id = v_org);
  select id into v_cash    from accounts where org_id = v_org and code = '11101';
  select id into v_rev     from accounts where org_id = v_org and code = '61101';
  select id into v_inv_acc from accounts where org_id = v_org and code = '11601';
  select id into v_cogs    from accounts where org_id = v_org and code = '51101';
  select id into v_vat_out from accounts where org_id = v_org and code = '31401';
  select id into v_cust_ctrl from accounts where org_id = v_org and code = '11501';

  -- =========================================================================
  -- 1) baseline regression: voiding a genuine MANUAL entry still works
  -- =========================================================================
  v_manual_entry := create_journal_entry(v_org, current_date, 'قيد يدوي',
    jsonb_build_array(
      jsonb_build_object('account_id', v_cash, 'debit', 100, 'currency_id', v_cur),
      jsonb_build_object('account_id', v_rev,  'credit', 100, 'currency_id', v_cur)
    ));
  perform post_journal_entry(v_manual_entry);
  assert (select source_type from journal_entries where id = v_manual_entry) = 'manual';
  perform void_journal_entry(v_manual_entry, current_date, 'اختبار الإلغاء اليدوي العادي');
  assert (select status from journal_entries where id = v_manual_entry) = 'void', 'a genuine manual entry should still be voidable directly';

  -- =========================================================================
  -- set up a real sales invoice (module-sourced entry) to attack
  -- =========================================================================
  insert into warehouses (org_id, code, name_ar) values (v_org, 'W1', 'المستودع الرئيسي') returning id into v_wh;
  v_cust := create_dealer(v_org, 'عميل اختبار', v_cust_ctrl, p_is_customer := true);
  insert into items (org_id, code, name_ar, inventory_account_id, cogs_account_id, sales_account_id, sales_price)
  values (v_org, 'VSSKU', 'صنف اختبار', v_inv_acc, v_cogs, v_rev, 50)
  returning id into v_item;
  perform post_stock_move(create_stock_move(v_org, 'opening', current_date, 'رصيد افتتاحي',
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'warehouse_id', v_wh, 'direction', 'in', 'entered_qty', 100, 'unit_cost', 10))),
    (select id from accounts where org_id = v_org and code = '41001'));

  v_invoice := create_sales_invoice(v_org, current_date, v_cust, v_wh,
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 2, 'unit_price', 50)));
  perform post_sales_invoice(v_invoice, p_output_vat_account_id := v_vat_out);
  v_invoice_entry := (select journal_entry_id from sales_invoices where id = v_invoice);
  assert (select source_type from journal_entries where id = v_invoice_entry) = 'sales_invoice';

  -- =========================================================================
  -- 2) void_journal_entry() directly on the sales invoice's own entry must
  --    be rejected, naming the source type
  -- =========================================================================
  v_caught := false;
  begin
    perform void_journal_entry(v_invoice_entry, current_date, 'محاولة تجاوز عبر القيد مباشرة');
  exception when sqlstate '23514' then
    v_caught := true;
    get stacked diagnostics v_msg = message_text;
  end;
  assert v_caught, 'void_journal_entry() should reject a sales_invoice-sourced entry';
  assert v_msg ilike '%sales_invoice%', 'the error should name the source type, got: ' || coalesce(v_msg, '<null>');

  -- =========================================================================
  -- 3) nothing changed: the invoice AND its entry are both still posted —
  --    no split between the document and its ledger
  -- =========================================================================
  assert (select status from sales_invoices where id = v_invoice) = 'posted', 'the invoice should remain posted after the rejected attempt';
  assert (select status from journal_entries where id = v_invoice_entry) = 'posted', 'the invoice''s entry should remain posted after the rejected attempt';

  -- =========================================================================
  -- 4) the correct path (void_sales_invoice) still works end to end
  -- =========================================================================
  perform void_sales_invoice(v_invoice, current_date, 'إلغاء صحيح عبر مسار الفاتورة');
  assert (select status from sales_invoices where id = v_invoice) = 'void', 'void_sales_invoice() should still work correctly';
  assert (select status from journal_entries where id = v_invoice_entry) = 'void', 'the original entry should now be void via the correct path';

  -- =========================================================================
  -- 5) the reversal entry void_sales_invoice() just created cannot be
  --    re-voided directly via void_journal_entry() either
  -- =========================================================================
  select reversed_by into v_reversal_entry from journal_entries where id = v_invoice_entry;
  assert (select source_type from journal_entries where id = v_reversal_entry) = 'reversal';
  v_caught := false;
  begin
    perform void_journal_entry(v_reversal_entry, current_date, 'محاولة إلغاء قيد العكس مباشرة');
  exception when sqlstate '23514' then v_caught := true;
  end;
  assert v_caught, 'void_journal_entry() should reject a reversal-sourced entry too — only genuine manual entries';

  -- =========================================================================
  -- 6) source_type/source_id are write-once: a direct UPDATE on a fresh
  --    draft manual entry attempting to relabel it is rejected
  -- =========================================================================
  declare v_draft uuid; begin
    v_draft := create_journal_entry(v_org, current_date, 'مسودة لاختبار عدم التعديل',
      jsonb_build_array(
        jsonb_build_object('account_id', v_cash, 'debit', 5, 'currency_id', v_cur),
        jsonb_build_object('account_id', v_rev,  'credit', 5, 'currency_id', v_cur)
      ));
    assert (select source_type from journal_entries where id = v_draft) = 'manual';

    v_caught := false;
    begin
      update journal_entries set source_type = 'sales_invoice', source_id = v_invoice where id = v_draft;
    exception when sqlstate '23514' then v_caught := true;
    end;
    assert v_caught, 'directly relabeling a draft entry''s source_type/source_id should be rejected (write-once)';
    assert (select source_type from journal_entries where id = v_draft) = 'manual', 'the draft''s source_type should be unchanged after the rejected attempt';
    assert (select source_id from journal_entries where id = v_draft) is null, 'the draft''s source_id should be unchanged after the rejected attempt';
  end;

  raise notice 'VOID JOURNAL ENTRY SOURCE PROTECTION OK';
end $$;

rollback;
