-- Cash drawer shifts (وردية الصندوق): open with a denomination count,
-- close with another count, and a nonzero variance posts a real journal
-- entry against a caller-chosen account. A cash sale rung up with no shift
-- open at all still posts exactly as before — the feature is additive.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values
  ('fe000000-0000-0000-000e-000000000001','owner@cashshift.test'),
  ('fe000000-0000-0000-000e-000000000002','viewer@cashshift.test');
select set_config('request.jwt.claim.sub','fe000000-0000-0000-000e-000000000001', true);
set local role authenticated;
select set_config('t.org', create_organization('CASHORG','مؤسسة اختبار الصندوق','NIS','شيكل',1)::text, true);

do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_cash uuid; v_shortage uuid; v_overage uuid; v_ar uuid; v_wh uuid; v_cust uuid; v_cashier uuid;
  v_vat uuid;
  v_shift1 uuid; v_shift2 uuid; v_shift3 uuid;
  v_item uuid; v_inv uuid;
  v_open_gl numeric; v_close_gl numeric; v_expected numeric;
  v_viewer_role uuid;
begin
  select id into v_cash from accounts where org_id=v_org and code='11101';
  select id into v_shortage from accounts where org_id=v_org and code='53701';
  select id into v_overage from accounts where org_id=v_org and code='65104';
  select id into v_ar from accounts where org_id=v_org and code='11501';
  select id into v_vat from accounts where org_id=v_org and code='31401';
  insert into warehouses (org_id, code, name_ar) values (v_org,'W1','رئيسي') returning id into v_wh;
  v_cust := create_dealer(v_org, 'زبون', v_ar, p_is_customer := true);
  v_cashier := create_dealer(v_org, 'كاشير 1', (select id from accounts where org_id=v_org and code='11504'), p_is_employee := true);
  insert into items (org_id, code, name_ar, inventory_account_id, cogs_account_id, sales_account_id, sales_price)
    values (v_org,'ITM','صنف',(select id from accounts where org_id=v_org and code='11601'),
            (select id from accounts where org_id=v_org and code='51101'),
            (select id from accounts where org_id=v_org and code='61101'), 50)
    returning id into v_item;
  perform post_stock_move(create_stock_move(v_org,'opening',current_date,'رصيد',
    jsonb_build_array(jsonb_build_object('item_id', v_item,'warehouse_id', v_wh,'direction','in','entered_qty',100,'unit_cost',20))));

  -- =========================================================================
  -- 1) open a shift: opening_total computed from denominations, GL snapshot taken
  -- =========================================================================
  v_shift1 := open_cash_shift(v_org, v_cash,
    jsonb_build_object('100', 3, '20', 5, '5', 2), v_cashier, 'بداية الوردية الصباحية');
  assert (select opening_total from cash_shifts where id = v_shift1) = 410, 'opening total should be 3*100+5*20+2*5=410';
  assert (select opening_gl_balance from cash_shifts where id = v_shift1) = account_balance(v_cash), 'opening GL snapshot should match the cash account balance at open time';
  assert (select status from cash_shifts where id = v_shift1) = 'open', 'a new shift should be open';

  -- can't open a second shift on the same drawer while one is already open
  begin
    perform open_cash_shift(v_org, v_cash, '{}'::jsonb);
    raise exception 'TEST FAIL: opened a second shift on an already-open drawer';
  exception when sqlstate '23514' then null;
  end;

  -- a non-employee dealer cannot be the cashier
  begin
    perform open_cash_shift(v_org, (select id from accounts where org_id=v_org and code='11102'), '{}'::jsonb, v_cust);
    raise exception 'TEST FAIL: accepted a non-employee dealer as cashier';
  exception when sqlstate '23503' then null;
  end;

  -- =========================================================================
  -- 2) a cash sale posted while the shift is open links to it, and moves the
  --    GL exactly like any other cash sale (no special-casing needed):
  --    2 @ 50 = 100 subtotal + 16 VAT = 116 debited to the cash account
  -- =========================================================================
  v_open_gl := account_balance(v_cash);
  v_inv := create_sales_invoice(v_org, current_date, v_cust, v_wh,
    jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 2, 'unit_price', 50)),
    p_payment_method := 'cash', p_cash_account_id := v_cash, p_cash_shift_id := v_shift1);
  perform post_sales_invoice(v_inv, p_output_vat_account_id := v_vat);
  assert (select cash_shift_id from sales_invoices where id = v_inv) = v_shift1, 'the invoice should be linked to the open shift';
  assert account_balance(v_cash) - v_open_gl = 116, 'the cash account should have moved by exactly 116 (100 + 16 VAT)';

  -- a cash_shift_id that doesn't exist (or isn't open, or is another org's) is rejected
  begin
    perform create_sales_invoice(v_org, current_date, v_cust, v_wh,
      jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 1, 'unit_price', 50)),
      p_cash_shift_id := extensions.gen_random_uuid());
    raise exception 'TEST FAIL: accepted a bogus cash_shift_id';
  exception when sqlstate '23503' then null;
  end;

  -- =========================================================================
  -- 3) close with an EXACT match -> zero variance, no journal entry posted
  --    expected = 410 (opening) + 116 (this shift's only GL movement) = 526
  -- =========================================================================
  perform close_cash_shift(v_shift1, jsonb_build_object('100', 5, '20', 1, '5', 1, '1', 1));  -- 500+20+5+1=526
  assert (select status from cash_shifts where id = v_shift1) = 'closed', 'shift should now be closed';
  assert (select variance from cash_shifts where id = v_shift1) = 0, 'an exact count should show zero variance';
  assert (select variance_journal_entry_id from cash_shifts where id = v_shift1) is null, 'no journal entry should be posted when the variance is zero';
  assert (select expected_closing from cash_shifts where id = v_shift1) = 526, 'expected closing should be 526';

  -- a closed shift can't be closed again, and can't be modified directly
  begin
    perform close_cash_shift(v_shift1, '{}'::jsonb);
    raise exception 'TEST FAIL: closed an already-closed shift';
  exception when sqlstate '23514' then null;
  end;
  -- no UPDATE/INSERT policy exists on cash_shifts at all (writes go only
  -- through the two functions, which are SECURITY DEFINER and bypass RLS) —
  -- so a direct update silently touches zero rows rather than raising
  update cash_shifts set notes = 'tampered' where id = v_shift1;
  assert (select notes from cash_shifts where id = v_shift1) <> 'tampered', 'a closed shift should not be directly modifiable at all (no write policy covers it)';

  -- =========================================================================
  -- 4) a SHORTAGE: counted less than expected -> requires a variance
  --    account, posts a debit to it and a credit to the cash account
  -- =========================================================================
  v_shift2 := open_cash_shift(v_org, v_cash, jsonb_build_object('100', 5, '20', 1, '5', 1, '1', 1), v_cashier);  -- 526 again
  -- no sale this time; count 30 short at close
  begin
    perform close_cash_shift(v_shift2, jsonb_build_object('100', 4, '20', 2, '5', 3, '1', 1));  -- 400+40+15+1=456 (70 short)
    raise exception 'TEST FAIL: closed a shift with a real variance and no variance account';
  exception when sqlstate '23514' then null;
  end;
  perform close_cash_shift(v_shift2, jsonb_build_object('100', 4, '20', 2, '5', 3, '1', 1), v_shortage);
  assert (select variance from cash_shifts where id = v_shift2) = -70, 'shortage should be exactly -70';
  assert (select variance_journal_entry_id from cash_shifts where id = v_shift2) is not null, 'a shortage should post a journal entry';
  assert account_balance(v_shortage) = 70, 'the shortage expense account should carry the 70 debit';

  -- =========================================================================
  -- 5) an OVERAGE: counted more than expected -> credits the income account
  -- =========================================================================
  v_shift3 := open_cash_shift(v_org, v_cash, jsonb_build_object('100', 4, '20', 2, '5', 3, '1', 1));  -- 456 (matches shift2's real closing balance), no cashier this time
  perform close_cash_shift(v_shift3, jsonb_build_object('100', 4, '20', 3, '5', 3, '1', 1), v_overage);  -- +20 over
  assert (select variance from cash_shifts where id = v_shift3) = 20, 'overage should be exactly 20';
  assert account_balance(v_overage) = -20, 'the overage income account should carry a 20 credit (shown negative under a debit-normal report convention)';

  -- =========================================================================
  -- 6) viewer (no cash_shifts permissions) cannot open or close a shift
  -- =========================================================================
  select id into v_viewer_role from roles where org_id = v_org and code = 'viewer';
  insert into memberships (org_id, user_id, role_id) values (v_org, 'fe000000-0000-0000-000e-000000000002', v_viewer_role);
  perform set_config('request.jwt.claim.sub', 'fe000000-0000-0000-000e-000000000002', true);
  begin
    perform open_cash_shift(v_org, v_cash, '{}'::jsonb);
    raise exception 'TEST FAIL: a viewer opened a cash shift';
  exception when sqlstate '42501' then null;
  end;
  perform set_config('request.jwt.claim.sub', 'fe000000-0000-0000-000e-000000000001', true);

  raise notice 'CASH SHIFTS OK';
end $$;

rollback;
