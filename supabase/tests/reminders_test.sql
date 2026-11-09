-- Tests for check-in reminders (20261109000000_reminders.sql). Runs after
-- alerts_test.sql against the stubbed pg_net in supabase_stub.sql.

reset role;

create function pg_temp.fail(msg text) returns void language plpgsql as $$
begin raise exception 'FAIL: %', msg; end $$;

create function pg_temp.act_as(p_user uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated')::text, false);
  set role authenticated;
end $$;

create function pg_temp.pushes() returns integer language sql as $$
  select count(*)::integer from net.requests where url = 'https://exp.host/--/api/v2/push/send'
$$;

-- Start clean.
delete from public.seniors;
update public.alert_settings
set email_live = true, sms_live = false, sms_from = null, live_since = '2026-11-01', reminders_live = true;

-- June (Toronto) checks in herself on her phone; her son Sam looks after her.
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000f1', 'june@example.com'),
  ('00000000-0000-0000-0000-0000000000f2', 'sam@example.com'),
  ('00000000-0000-0000-0000-0000000000f3', 'stranger@example.com');
insert into public.seniors (id, first_name, timezone)
values ('00000000-0000-0000-0000-00000000c001', 'June', 'America/Toronto');
insert into public.circle_members (senior_id, user_id, role) values
  ('00000000-0000-0000-0000-00000000c001', '00000000-0000-0000-0000-0000000000f1', 'senior'),
  ('00000000-0000-0000-0000-00000000c001', '00000000-0000-0000-0000-0000000000f2', 'family');
insert into public.contacts (senior_id, name, email)
values ('00000000-0000-0000-0000-00000000c001', 'Sam', 'sam@example.com');
insert into public.schedules (id, senior_id, label, time_of_day, created_at, effective_from)
values ('00000000-0000-0000-0000-00000000d001', '00000000-0000-0000-0000-00000000c001',
        'Morning check-in', '09:00', '2026-11-01', '2026-11-01');

-- Registering phones: June's and Sam's. A stranger can't attach to June.
select pg_temp.act_as('00000000-0000-0000-0000-0000000000f1');
select public.register_push_device('00000000-0000-0000-0000-00000000c001', 'ExponentPushToken[june]', 'ios');
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-0000000000f2');
select public.register_push_device('00000000-0000-0000-0000-00000000c001', 'ExponentPushToken[sam]', 'android');
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-0000000000f3');
do $$ begin
  begin
    perform public.register_push_device('00000000-0000-0000-0000-00000000c001', 'ExponentPushToken[x]', 'ios');
    perform pg_temp.fail('a stranger registered a phone for June');
  exception when insufficient_privilege then null;
  end;
  begin
    perform 1 from public.push_devices;
    perform pg_temp.fail('push_devices is readable directly');
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

-- 8:59: nothing yet. 9:00:30: one reminder, to June's phone only.
do $$
declare v_body jsonb;
begin
  perform public.process_alerts('2026-11-10 08:59-05');
  if pg_temp.pushes() <> 0 then perform pg_temp.fail('reminder sent early'); end if;
  perform public.process_alerts('2026-11-10 09:00:30-05');
  if pg_temp.pushes() <> 1 then perform pg_temp.fail('expected one reminder at 9:00, got ' || pg_temp.pushes()); end if;
  select body into v_body from net.requests where url like 'https://exp.host/%';
  if jsonb_array_length(v_body) <> 1 or v_body -> 0 ->> 'to' <> 'ExponentPushToken[june]' then
    perform pg_temp.fail('reminder went to the wrong phones: ' || v_body);
  end if;
  if v_body -> 0 ->> 'title' <> 'Time to check in, June'
     or v_body -> 0 ->> 'body' <> 'Tap here to let your family know you''re OK, or to ask for help.'
     or v_body -> 0 -> 'data' ->> 'url' <> '/' or v_body -> 0 ->> 'channelId' <> 'checkins' then
    perform pg_temp.fail('reminder content is wrong: ' || v_body);
  end if;
  -- Not again.
  perform public.process_alerts('2026-11-10 09:05-05');
  if pg_temp.pushes() <> 1 then perform pg_temp.fail('reminder sent twice'); end if;
end $$;

-- Expo answers OK: recorded as sent.
insert into net._http_response (id, status_code, content)
select request_id, 200, '{"data":[{"status":"ok","id":"abc"}]}' from public.checkin_reminders;

-- 9:30: still no check-in, so a nudge saying when Sam will be told.
do $$
declare v_body jsonb;
begin
  perform public.process_alerts('2026-11-10 09:30:20-05');
  if (select status from public.checkin_reminders where kind = 'due') <> 'sent' then
    perform pg_temp.fail('Expo''s OK was not recorded');
  end if;
  if pg_temp.pushes() <> 2 then perform pg_temp.fail('no nudge at 9:30'); end if;
  select body into v_body from net.requests where url like 'https://exp.host/%' order by id desc limit 1;
  if v_body -> 0 ->> 'title' <> 'June, please check in'
     or v_body -> 0 ->> 'body' <> 'Tap here to check in. If you haven''t checked in by 10:00 a.m. your family will be told.' then
    perform pg_temp.fail('nudge content is wrong: ' || v_body);
  end if;
end $$;

-- Expo says the phone is gone (app deleted): it's forgotten.
insert into net._http_response (id, status_code, content)
select request_id, 200, '{"data":[{"status":"error","message":"gone","details":{"error":"DeviceNotRegistered"}}]}'
from public.checkin_reminders where kind = 'nudge';
select public.reconcile_checkin_reminders();
do $$ begin
  if exists (select 1 from public.push_devices where token = 'ExponentPushToken[june]') then
    perform pg_temp.fail('unregistered phone was not forgotten');
  end if;
  if (select status from public.checkin_reminders where kind = 'nudge') <> 'failed' then
    perform pg_temp.fail('nudge to an unregistered phone not marked failed');
  end if;
end $$;

-- Next day: June checked in early at 8:15, so no reminder at 9:00 or 9:30.
select pg_temp.act_as('00000000-0000-0000-0000-0000000000f1');
select public.register_push_device('00000000-0000-0000-0000-00000000c001', 'ExponentPushToken[june2]', 'ios');
reset role;
insert into public.checkins (senior_id, status, occurred_at)
values ('00000000-0000-0000-0000-00000000c001', 'ok', '2026-11-11 08:15-05');
do $$
declare v_before integer := pg_temp.pushes();
begin
  perform public.process_alerts('2026-11-11 09:00:30-05');
  perform public.process_alerts('2026-11-11 09:30:30-05');
  if pg_temp.pushes() <> v_before then perform pg_temp.fail('reminded after an early check-in'); end if;
end $$;

-- The job was down at 9:00 and runs again at 9:20: too late for the 9:00
-- reminder; the 9:30 nudge still goes.
do $$
declare v_before integer := pg_temp.pushes();
begin
  perform public.process_alerts('2026-11-12 09:20-05');
  if pg_temp.pushes() <> v_before then perform pg_temp.fail('stale reminder sent'); end if;
  perform public.process_alerts('2026-11-12 09:31-05');
  if pg_temp.pushes() <> v_before + 1 then perform pg_temp.fail('nudge not sent after a missed reminder'); end if;
end $$;

-- Signing out forgets the phone; a phone moved to Sam gets no reminders.
select pg_temp.act_as('00000000-0000-0000-0000-0000000000f1');
select public.forget_push_device('ExponentPushToken[june2]');
reset role;
do $$
declare v_before integer := pg_temp.pushes();
begin
  if exists (select 1 from public.push_devices where token = 'ExponentPushToken[june2]') then
    perform pg_temp.fail('signing out did not forget the phone');
  end if;
  perform public.process_alerts('2026-11-13 09:00:30-05');
  if pg_temp.pushes() <> v_before then perform pg_temp.fail('a family member''s phone got a reminder'); end if;
end $$;

-- Reminders can be switched off.
select pg_temp.act_as('00000000-0000-0000-0000-0000000000f1');
select public.register_push_device('00000000-0000-0000-0000-00000000c001', 'ExponentPushToken[june3]', 'ios');
reset role;
update public.alert_settings set reminders_live = false;
do $$
declare v_before integer := pg_temp.pushes();
begin
  perform public.process_alerts('2026-11-14 09:00:30-05');
  if pg_temp.pushes() <> v_before then perform pg_temp.fail('reminder sent while switched off'); end if;
end $$;
update public.alert_settings set reminders_live = true;

-- Alerts off: reminders still go.
update public.alert_settings set email_live = false;
do $$
declare v_before integer := pg_temp.pushes();
begin
  perform public.process_alerts('2026-11-15 09:00:30-05');
  if pg_temp.pushes() <> v_before + 1 then perform pg_temp.fail('reminders stopped when alerts were off'); end if;
end $$;

\echo 'All reminder tests passed.'
