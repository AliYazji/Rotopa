-- Receipt/payment vouchers: multi-line posting, balance, void, isolation.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values ('e0000000-0000-0000-0000-000000000001','vch@test');
select set_config('request.jwt.claim.sub','e0000000-0000-0000-0000-000000000001', true);
set local role authenticated;
select set_config('t.org', create_organization('VCHORG','مؤسسة اختبار السندات','NIS','شيكل',1)::text, true);

do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_base uuid := (select base_currency_id from organizations where id = v_org);
  v_parent uuid;
  v_cash uuid; v_ar1 uuid; v_ar2 uuid; v_exp uuid;
  v_voucher uuid; v_entry uuid; v_rev uuid;
begin
  insert into accounts (org_id, code, name_ar, is_postable, nature) values (v_org,'A','أصول',false,'debit') returning id into v_parent;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'A1','الصندوق',v_parent,true,'debit') returning id into v_cash;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'A2','عميل 1',v_parent,true,'debit') returning id into v_ar1;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'A3','عميل 2',v_parent,true,'debit') returning id into v_ar2;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'A4','مصروف',v_parent,true,'debit') returning id into v_exp;

  -- multi-line receipt voucher: 700 + 300 from two customers into cash
  v_voucher := create_voucher(v_org, 'receipt', current_date, 'تحصيل من عملاء',
    v_cash, v_base,
    jsonb_build_array(
      jsonb_build_object('account_id', v_ar1, 'amount', 700),
      jsonb_build_object('account_id', v_ar2, 'amount', 300)
    ));
  v_entry := post_voucher(v_voucher);

  assert (select status from vouchers where id = v_voucher) = 'posted', 'voucher not posted';
  assert account_balance(v_cash) = 1000, 'cash should be debited 1000';
  assert account_balance(v_ar1) = -700, 'ar1 should be credited 700';
  assert account_balance(v_ar2) = -300, 'ar2 should be credited 300';
  assert (select count(*) from journal_lines where entry_id = v_entry) = 3, 'expected 3 lines (2 + cash leg)';

  -- cash account cannot appear as its own "other side" line (caught immediately, at line-insert time)
  begin
    perform create_voucher(v_org, 'payment', current_date, 'خطأ متعمد', v_cash, v_base,
      jsonb_build_array(jsonb_build_object('account_id', v_cash, 'amount', 10)));
    raise exception 'TEST FAIL: created a voucher line against its own cash account';
  exception when sqlstate '23514' then null;
  end;

  -- payment voucher: single line
  v_voucher := create_voucher(v_org, 'payment', current_date, 'دفع مصاريف', v_cash, v_base,
    jsonb_build_array(jsonb_build_object('account_id', v_exp, 'amount', 150)));
  perform post_voucher(v_voucher);
  assert account_balance(v_cash) = 850, 'cash should net to 850 after payment';
  assert account_balance(v_exp) = 150, 'expense should be debited 150';

  -- void the receipt voucher: reverses via a new posted voucher + entry
  select journal_entry_id into v_entry from vouchers
    where org_id = v_org and voucher_type = 'receipt' and status = 'posted' limit 1;
  v_rev := void_voucher((select id from vouchers where journal_entry_id = v_entry), current_date, 'اختبار الإلغاء');
  assert (select status from vouchers where journal_entry_id = v_entry) = 'void', 'original voucher not void';
  assert (select status from vouchers where id = v_rev) = 'posted', 'reversing voucher not posted';
  assert account_balance(v_cash) = -150, 'cash should drop back by 1000 (850 - 1000)';

  raise notice 'VOUCHERS OK';
end $$;

rollback;
