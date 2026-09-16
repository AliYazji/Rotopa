-- create_dealer(): account is auto-created under the chosen header, correctly
-- wired, and repeated calls don't collide on the generated code.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values ('a1000000-0000-0000-0000-000000000001','dlr@test');
select set_config('request.jwt.claim.sub','a1000000-0000-0000-0000-000000000001', true);
set local role authenticated;
select set_config('t.org', create_organization('DLRORG','مؤسسة اختبار العملاء','NIS','شيكل',1)::text, true);

do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_customers uuid;
  v_d1 uuid; v_d2 uuid;
  v_acc1 uuid; v_acc2 uuid;
begin
  -- Z-prefixed: create_organization() now seeds a real default chart of
  -- accounts (20250911003800) using plain 10000-65999 numeric codes, so
  -- this test's own scratch header needs a code that can't collide with it
  insert into accounts (org_id, code, name_ar, is_postable, nature)
  values (v_org, 'Z1120', 'العملاء', false, 'debit') returning id into v_customers;

  v_d1 := create_dealer(v_org, 'عميل أول', v_customers, p_is_customer := true, p_phone := '0599000001');
  v_d2 := create_dealer(v_org, 'عميل ثاني', v_customers, p_is_customer := true, p_phone := '0599000002');

  select account_id into v_acc1 from dealers where id = v_d1;
  select account_id into v_acc2 from dealers where id = v_d2;

  assert v_acc1 is not null and v_acc2 is not null, 'both dealers should have an account';
  assert v_acc1 <> v_acc2, 'each dealer must get its own account';
  assert (select parent_id from accounts where id = v_acc1) = v_customers, 'account should be under the chosen header';
  assert (select is_postable from accounts where id = v_acc1), 'the new account must be postable';
  assert (select code from accounts where id = v_acc1) = 'Z112001', 'first child code should be Z112001';
  assert (select code from accounts where id = v_acc2) = 'Z112002', 'second child code should be Z112002';

  -- trying to attach a dealer under a postable account must fail
  begin
    perform create_dealer(v_org, 'خطأ متعمد', v_acc1, p_is_customer := true);
    raise exception 'TEST FAIL: created a dealer under a postable account';
  exception when sqlstate '23514' then null;
  end;

  -- a dealer with no role at all must fail
  begin
    perform create_dealer(v_org, 'بلا دور', v_customers);
    raise exception 'TEST FAIL: created a dealer with no role';
  exception when sqlstate '23514' then null;
  end;

  -- the new account behaves normally: postable, so it can receive a real posting
  -- (against another postable account, not the non-postable header itself)
  perform post_journal_entry(create_journal_entry(v_org, current_date, 'فاتورة تجريبية',
    jsonb_build_array(
      jsonb_build_object('account_id', v_acc1, 'debit', 200, 'currency_id', (select base_currency_id from organizations where id=v_org)),
      jsonb_build_object('account_id', v_acc2, 'credit', 200, 'currency_id', (select base_currency_id from organizations where id=v_org)))));
  assert account_balance(v_acc1) = 200, 'the auto-created account should accept normal postings';

  raise notice 'DEALER PROVISIONING OK';
end $$;

rollback;
