-- Hotel: room/type master data, reservation overlap rejection, check-in/out,
-- per-night revenue posting (single + batch audit run), guards.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id, email) values ('f3000000-0000-0000-0003-000000000001','hotel@test');
select set_config('request.jwt.claim.sub','f3000000-0000-0000-0003-000000000001', true);
set local role authenticated;
select set_config('t.org', create_organization('HOTORG','مؤسسة اختبار الفندق','NIS','شيكل',1)::text, true);

do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_parent uuid; v_ar uuid; v_revenue uuid;
  v_type uuid; v_room1 uuid; v_room2 uuid; v_guest uuid;
  v_res1 uuid; v_res2 uuid; v_entry uuid;
  v_in date := current_date; v_out date := current_date + 3;
begin
  insert into accounts (org_id, code, name_ar, is_postable, nature) values (v_org,'PAR','أصول',false,'debit') returning id into v_parent;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'AR','ذمم نزلاء',v_parent,true,'debit') returning id into v_ar;
  insert into accounts (org_id, code, name_ar, parent_id, is_postable, nature) values (v_org,'REV','إيراد غرف',v_parent,true,'credit') returning id into v_revenue;

  insert into room_types (org_id, code, name_ar, default_rate, revenue_account_id)
  values (v_org, 'STD', 'غرفة قياسية', 100, v_revenue) returning id into v_type;
  insert into rooms (org_id, room_no, room_type_id) values (v_org, '101', v_type) returning id into v_room1;
  insert into rooms (org_id, room_no, room_type_id) values (v_org, '102', v_type) returning id into v_room2;

  insert into dealers (org_id, code, name_ar, is_customer, account_id) values (v_org,'G1','نزيل',true,v_ar) returning id into v_guest;

  -- 1) book room 101 for 3 nights
  v_res1 := create_reservation(v_org, v_guest, v_room1, 100, v_in, v_out);
  assert (select status from reservations where id = v_res1) = 'booked', 'should start booked';

  -- 2) an overlapping reservation on the SAME room is rejected
  begin
    perform create_reservation(v_org, v_guest, v_room1, 100, v_in + 1, v_out + 1);
    raise exception 'TEST FAIL: double-booked the same room for an overlapping range';
  exception when sqlstate '23514' then null;
  end;

  -- 3) check in -> room becomes occupied
  perform check_in_reservation(v_res1);
  assert (select status from reservations where id = v_res1) = 'checked_in', 'should be checked in';
  assert (select status from rooms where id = v_room1) = 'occupied', 'room should be occupied';

  -- 4) post the first night
  v_entry := post_room_night(v_res1, v_in);
  assert (select sum(debit) from journal_lines where entry_id = v_entry) = (select sum(credit) from journal_lines where entry_id = v_entry),
    'night entry must balance';
  assert account_balance(v_ar) = 100, 'guest AR should be debited 100 for the first night';
  assert account_balance(v_revenue) = -100, 'room revenue should be credited 100';

  -- 5) the same night cannot be posted twice
  begin
    perform post_room_night(v_res1, v_in);
    raise exception 'TEST FAIL: posted the same night twice';
  exception when sqlstate '23514' then null;
  end;

  -- 6) a night outside the stay is rejected
  begin
    perform post_room_night(v_res1, v_out + 10);
    raise exception 'TEST FAIL: posted a night outside the reservation''s stay';
  exception when sqlstate '23514' then null;
  end;

  -- 7) run_night_audit posts the second night in a batch, for every checked-in reservation
  perform run_night_audit(v_org, v_in + 1);
  assert account_balance(v_ar) = 200, 'guest AR should now reflect 2 nights (200)';
  assert (select count(*) from reservation_nights where reservation_id = v_res1) = 2, 'two nights should be on record';

  -- 8) check out -> room goes to cleaning, reservation closes
  perform check_out_reservation(v_res1);
  assert (select status from reservations where id = v_res1) = 'checked_out', 'should be checked out';
  assert (select status from rooms where id = v_room1) = 'cleaning', 'room should need cleaning';

  -- 9) cannot check in a reservation that's already checked out
  begin
    perform check_in_reservation(v_res1);
    raise exception 'TEST FAIL: checked in an already-checked-out reservation';
  exception when sqlstate '23514' then null;
  end;

  -- 10) the third (final) night can still be posted after checkout — the
  --     guest's stay is over but the last night's revenue is still owed
  perform post_room_night(v_res1, v_in + 2);
  assert account_balance(v_ar) = 300, 'guest AR should reflect all 3 nights (300)';

  -- 11) cancel a still-booked reservation on the other room
  v_res2 := create_reservation(v_org, v_guest, v_room2, 100, v_in, v_out);
  perform cancel_reservation(v_res2, 'تغيير خطة النزيل');
  assert (select status from reservations where id = v_res2) = 'cancelled', 'should be cancelled';

  -- 12) cannot cancel a reservation that's already checked in/out
  begin
    perform cancel_reservation(v_res1, null);
    raise exception 'TEST FAIL: cancelled a checked-out reservation';
  exception when sqlstate '23514' then null;
  end;

  -- 13) commercial terms are frozen once no longer booked; cosmetic fields aren't
  begin
    update reservations set rate_per_night = 999 where id = v_res1;
    raise exception 'TEST FAIL: changed the rate on a checked-out reservation';
  exception when sqlstate '23514' then null;
  end;
  update reservations set notes = 'ملاحظة بعد المغادرة' where id = v_res1;
  assert (select notes from reservations where id = v_res1) = 'ملاحظة بعد المغادرة', 'cosmetic field should stay editable';

  -- 14) a reservation with posted nights cannot be deleted (plain FK restrict, not a custom guard)
  begin
    delete from reservations where id = v_res1;
    raise exception 'TEST FAIL: deleted a reservation with posted nights';
  exception when sqlstate '23503' then null;
  end;

  -- 15) a reservation with NO posted nights (the cancelled one) can be deleted freely
  delete from reservations where id = v_res2;
  assert not exists (select 1 from reservations where id = v_res2), 'cancelled reservation with no nights should be deletable';

  raise notice 'HOTEL OK';
end $$;

rollback;
