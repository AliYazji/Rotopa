-- An opening entry may post to an account that has allow_transactions=false;
-- an ordinary entry to the same account must still be rejected.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values ('d0000000-0000-0000-0000-000000000001','ob@test');
select set_config('request.jwt.claim.sub','d0000000-0000-0000-0000-000000000001', true);
set local role authenticated;
select set_config('t.org', create_organization('OBORG','مؤسسة اختبار الافتتاح','NIS','شيكل',1)::text, true);

do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_base uuid := (select base_currency_id from organizations where id = v_org);
  v_frozen uuid;
  v_other uuid;
  v_e uuid;
begin
  insert into accounts (org_id, code, name_ar, is_postable, nature, allow_transactions)
  values (v_org, '99001', 'حساب مجمّد', true, 'both', false) returning id into v_frozen;
  insert into accounts (org_id, code, name_ar, is_postable, nature)
  values (v_org, '99002', 'حساب آخر', true, 'both') returning id into v_other;

  -- ordinary entry must be rejected
  begin
    v_e := create_journal_entry(v_org, current_date, 'محاولة عادية',
      jsonb_build_array(
        jsonb_build_object('account_id', v_frozen, 'debit', 10, 'currency_id', v_base),
        jsonb_build_object('account_id', v_other,  'credit', 10, 'currency_id', v_base)));
    perform post_journal_entry(v_e);
    raise exception 'TEST FAIL: posted to a frozen account outside an opening entry';
  exception when sqlstate '23514' then null;
  end;

  -- opening entry must succeed
  v_e := create_journal_entry(v_org, current_date, 'رصيد افتتاحي',
    jsonb_build_array(
      jsonb_build_object('account_id', v_frozen, 'debit', 500, 'currency_id', v_base),
      jsonb_build_object('account_id', v_other,  'credit', 500, 'currency_id', v_base)),
    'opening_balance', null, null, null, true);
  perform post_journal_entry(v_e);
  assert account_balance(v_frozen) = 500, 'opening entry to frozen account did not post';

  raise notice 'OPENING-BALANCE EXCEPTION OK';
end $$;

rollback;
