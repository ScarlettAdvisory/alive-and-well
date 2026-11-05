-- Tests for the alert job (20261105000000_alerts.sql). Runs after rls_test.sql
-- against the stubbed pg_net and Vault in supabase_stub.sql: sends are logged
-- in net.requests instead of reaching Bird.

reset role;

create function pg_temp.fail(msg text) returns void language plpgsql as $$
begin raise exception 'FAIL: %', msg; end $$;

create function pg_temp.act_as(p_user uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated')::text, false);
  set role authenticated;
end $$;

create function pg_temp.requests() returns integer language sql as $$
  select count(*)::integer from net.requests
$$;

-- Start clean: rls_test.sql's seniors would otherwise get alerts too.
delete from public.seniors;

-- Rose (Toronto) with three contacts:
--   Ann: email and texts (agreed), wants "I'm OK" messages
--   Ben: email only, doesn't want "I'm OK" messages
--   Cal: phone only, hasn't agreed to texts
insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000d1', 'dana@example.com');
insert into public.seniors (id, first_name, timezone)
values ('00000000-0000-0000-0000-00000000a001', 'Rose', 'America/Toronto');
insert into public.circle_members (senior_id, user_id, role)
values ('00000000-0000-0000-0000-00000000a001', '00000000-0000-0000-0000-0000000000d1', 'family');
insert into public.contacts (id, senior_id, name, email, phone, notify_on_checkin, sms_consent_at) values
  ('00000000-0000-0000-0000-0000000c0001', '00000000-0000-0000-0000-00000000a001', 'Ann', 'ann@example.com', '+16135550101', true, '2026-11-01'),
  ('00000000-0000-0000-0000-0000000c0002', '00000000-0000-0000-0000-00000000a001', 'Ben', 'ben@example.com', null, false, null),
  ('00000000-0000-0000-0000-0000000c0003', '00000000-0000-0000-0000-00000000a001', 'Cal', null, '+16135550103', true, null);
insert into public.schedules (id, senior_id, label, time_of_day, frequency, day_of_week, created_at) values
  ('00000000-0000-0000-0000-00000000b001', '00000000-0000-0000-0000-00000000a001', 'Morning check-in', '09:00', 'daily', null, '2026-11-01'),
  -- Thursday Nov 5 is not a weekend, and Rose's weekly call is on Mondays.
  ('00000000-0000-0000-0000-00000000b002', '00000000-0000-0000-0000-00000000a001', 'Weekend check-in', '08:00', 'weekends', null, '2026-11-01'),
  ('00000000-0000-0000-0000-00000000b003', '00000000-0000-0000-0000-00000000a001', 'Weekly call', '08:30', 'weekly', 1, '2026-11-01');
-- An "I'm OK" from before alerts were switched on must never be sent.
insert into public.checkins (id, senior_id, status, occurred_at)
values ('00000000-0000-0000-0000-00000000e000', '00000000-0000-0000-0000-00000000a001', 'ok', '2026-11-04 12:00-05');
insert into vault.decrypted_secrets values ('bird_api_key', 'bk_us1_testkey');

-- Not switched on: nothing happens.
do $$ begin
  if public.process_alerts('2026-11-05 10:30-05') <> '{"live": false}'::jsonb then
    perform pg_temp.fail('ran before alerts were switched on');
  end if;
  if pg_temp.requests() <> 0 then perform pg_temp.fail('sent before alerts were switched on'); end if;
end $$;

update public.alert_settings
set email_live = true, sms_live = true, sms_from = '+12265550100', live_since = '2026-11-05 00:00-05';

-- 9:59 a.m.: the 9:00 check-in isn't an hour overdue yet.
do $$ begin
  perform public.process_alerts('2026-11-05 09:59-05');
  if exists (select 1 from public.checkins where senior_id = '00000000-0000-0000-0000-00000000a001' and status = 'no_response') then
    perform pg_temp.fail('missed check-in recorded before it was an hour late');
  end if;
  if (select alert_state from public.checkins where id = '00000000-0000-0000-0000-00000000e000') <> 'not_needed' then
    perform pg_temp.fail('a check-in from before switch-on was left pending');
  end if;
  if pg_temp.requests() <> 0 then perform pg_temp.fail('sent something at 9:59'); end if;
end $$;

-- 10:00:30: missed. Ann gets an email and a text, Ben an email, Cal nothing.
do $$
declare
  v_missed record;
  v_sms jsonb;
begin
  if (public.process_alerts('2026-11-05 10:00:30-05') ->> 'missed')::int <> 1 then
    perform pg_temp.fail('expected exactly one missed check-in at 10:00');
  end if;
  select * into v_missed from public.checkins where senior_id = '00000000-0000-0000-0000-00000000a001' and status = 'no_response';
  if v_missed.scheduled_for <> '2026-11-05 09:00-05' or v_missed.occurred_at <> '2026-11-05 10:00-05' then
    perform pg_temp.fail('missed check-in has the wrong times: ' || v_missed.scheduled_for || ' / ' || v_missed.occurred_at);
  end if;
  if v_missed.alert_state <> 'sent' then perform pg_temp.fail('missed alert state is ' || v_missed.alert_state); end if;
  if v_missed.notified_contacts::text <> '{00000000-0000-0000-0000-0000000c0001,00000000-0000-0000-0000-0000000c0002}' then
    perform pg_temp.fail('missed alert notified ' || v_missed.notified_contacts::text);
  end if;
  if pg_temp.requests() <> 3 then perform pg_temp.fail('expected 3 sends, got ' || pg_temp.requests()); end if;
  if (select count(*) from net.requests where body -> 'to' = '["ben@example.com"]') <> 1 then
    perform pg_temp.fail('Ben did not get an email');
  end if;
  if exists (select 1 from net.requests where body::text like '%5550103%') then
    perform pg_temp.fail('Cal got a text without agreeing to texts');
  end if;

  select body into v_sms from net.requests where url = 'https://us1.platform.bird.com/v1/sms/messages';
  if v_sms ->> 'to' <> '+16135550101' or v_sms ->> 'from' <> '+12265550100' then
    perform pg_temp.fail('text went to/from the wrong number: ' || v_sms::text);
  end if;
  if v_sms ->> 'text' <> 'Alive & Well: Rose hasn''t checked in for their Morning check-in (due 9:00 a.m.). Please call or visit to check on them. Emergency? Call 911.' then
    perform pg_temp.fail('unexpected text: ' || (v_sms ->> 'text'));
  end if;
  if not exists (
    select 1 from net.requests
    where url = 'https://us1.platform.bird.com/v1/email/messages'
      and headers ->> 'Authorization' = 'Bearer bk_us1_testkey'
      and headers ->> 'Idempotency-Key' = 'alert/' || v_missed.id || '/00000000-0000-0000-0000-0000000c0001/email'
      and body ->> 'subject' = 'Rose hasn''t checked in'
      and body ->> 'text' like 'Rose hasn''t checked in for their Morning check-in, which was due at 9:00 a.m. today (Thursday, November 5).%'
      and body -> 'from' = '{"email": "alerts@seniorsalive.ca", "name": "Alive & Well"}'
  ) then
    perform pg_temp.fail('missed-check-in email to Ann is wrong');
  end if;
  if (select count(*) from public.alert_deliveries where checkin_id = v_missed.id and status = 'queued') <> 3 then
    perform pg_temp.fail('deliveries were not logged');
  end if;
end $$;

-- Running again doesn't record or send anything twice.
do $$ begin
  perform public.process_alerts('2026-11-05 10:01-05');
  perform public.process_alerts('2026-11-05 15:00-05');
  if (select count(*) from public.checkins where senior_id = '00000000-0000-0000-0000-00000000a001' and status = 'no_response') <> 1 then
    perform pg_temp.fail('missed check-in recorded twice');
  end if;
  if pg_temp.requests() <> 3 then perform pg_temp.fail('alert sent twice'); end if;
end $$;

-- Friday: Rose checks in early at 8:30 a.m. The 9:00 check-in is covered, and
-- only Ann (who wants "I'm OK" messages) gets an email; no texts.
insert into public.checkins (id, senior_id, status, occurred_at, message)
values ('00000000-0000-0000-0000-00000000e001', '00000000-0000-0000-0000-00000000a001', 'ok', '2026-11-06 08:30-05', 'Off to the market');
do $$
declare v_before integer := pg_temp.requests();
begin
  perform public.process_alerts('2026-11-06 10:05-05');
  if (select count(*) from public.checkins where senior_id = '00000000-0000-0000-0000-00000000a001' and status = 'no_response') <> 1 then
    perform pg_temp.fail('an early check-in did not cover the 9:00 time');
  end if;
  if pg_temp.requests() <> v_before + 1 then
    perform pg_temp.fail('"I''m OK" should send one email, sent ' || (pg_temp.requests() - v_before));
  end if;
  if not exists (
    select 1 from net.requests
    where body -> 'to' = '["ann@example.com"]'
      and body ->> 'subject' = 'Rose checked in: I''m OK'
      and body ->> 'text' like 'Rose checked in at 8:30 a.m. on Friday, November 6 and said "I''m OK".%Off to the market%'
  ) then
    perform pg_temp.fail('"I''m OK" email to Ann is wrong');
  end if;
end $$;

-- A help request goes to everyone: Ann (email and text) and Ben (email).
insert into public.checkins (id, senior_id, status, occurred_at, message)
values ('00000000-0000-0000-0000-00000000e002', '00000000-0000-0000-0000-00000000a001', 'need_help', '2026-11-06 12:00-05', 'I fell');
do $$
declare v_before integer := pg_temp.requests();
begin
  perform public.process_alerts('2026-11-06 12:00:40-05');
  if pg_temp.requests() <> v_before + 3 then
    perform pg_temp.fail('help request should send 3 messages, sent ' || (pg_temp.requests() - v_before));
  end if;
  if not exists (
    select 1 from net.requests
    where body ->> 'text' = 'Alive & Well: Rose pressed "I need help" at 12:00 p.m. Please call or visit now. Emergency? Call 911.'
  ) then
    perform pg_temp.fail('help text is wrong');
  end if;
  if not exists (
    select 1 from net.requests
    where body ->> 'subject' = 'Rose asked for help' and body ->> 'text' like '%Rose wrote: "I fell"%'
      and body ->> 'html' like '%Rose wrote: &quot;I fell&quot;%'
  ) then
    perform pg_temp.fail('help email is wrong');
  end if;
end $$;

-- Bird's answers: the help alert's three messages are all refused, so that
-- alert is marked failed; the missed alert had one accepted, so it stays sent.
insert into net._http_response (id, status_code, content)
select d.request_id, case when d.checkin_id = '00000000-0000-0000-0000-00000000e002' then 422 else 202 end,
       case when d.checkin_id = '00000000-0000-0000-0000-00000000e002' then '{"error":"domain not verified"}' else '{}' end
from public.alert_deliveries d;
do $$ begin
  perform public.process_alerts('2026-11-06 12:02-05');
  if (select alert_state from public.checkins where id = '00000000-0000-0000-0000-00000000e002') <> 'failed' then
    perform pg_temp.fail('help alert with every message refused is not marked failed');
  end if;
  if (select alert_state from public.checkins where senior_id = '00000000-0000-0000-0000-00000000a001' and status = 'no_response') <> 'sent' then
    perform pg_temp.fail('missed alert with accepted messages is not marked sent');
  end if;
  if (select count(*) from public.alert_deliveries where status = 'failed' and error like '%domain not verified%') <> 3 then
    perform pg_temp.fail('refused deliveries were not recorded with the reason');
  end if;
end $$;

-- A senior with no contacts: the missed check-in is recorded as no_contacts.
-- A schedule added after its time that day doesn't count as missed.
insert into public.seniors (id, first_name, timezone)
values ('00000000-0000-0000-0000-00000000a002', 'Walt', 'America/Vancouver');
insert into public.schedules (senior_id, time_of_day, created_at) values
  ('00000000-0000-0000-0000-00000000a002', '07:00', '2026-11-01'),
  ('00000000-0000-0000-0000-00000000a002', '08:00', '2026-11-07 09:00-07');
do $$
declare v_before integer := pg_temp.requests();
begin
  perform public.process_alerts('2026-11-07 10:00-07');
  if (select count(*) from public.checkins where senior_id = '00000000-0000-0000-0000-00000000a002') <> 1 then
    perform pg_temp.fail('expected only the 7:00 check-in to be missed for Walt');
  end if;
  if (select alert_state from public.checkins where senior_id = '00000000-0000-0000-0000-00000000a002') <> 'no_contacts' then
    perform pg_temp.fail('missed check-in with no contacts not marked no_contacts');
  end if;
  -- Saturday: Rose's weekend check-in counts now (8:00 a.m. Toronto = 5:00 a.m. Vancouver).
  if not exists (
    select 1 from public.checkins
    where schedule_id = '00000000-0000-0000-0000-00000000b002' and scheduled_for = '2026-11-07 08:00-05'
  ) then
    perform pg_temp.fail('Saturday weekend check-in was not recorded as missed');
  end if;
  if exists (select 1 from public.checkins where schedule_id = '00000000-0000-0000-0000-00000000b003') then
    perform pg_temp.fail('Monday-only weekly check-in recorded on another day');
  end if;
end $$;

-- What the app may claim.
do $$ begin
  if public.alert_status() <> '{"email": true, "sms": true}'::jsonb then
    perform pg_temp.fail('alert_status with both on: ' || public.alert_status());
  end if;
  update public.alert_settings set sms_from = null;
  if public.alert_status() <> '{"email": true, "sms": false}'::jsonb then
    perform pg_temp.fail('texts reported on without a number');
  end if;
end $$;

-- Test sends.
do $$
declare v_before integer := pg_temp.requests();
begin
  perform public.send_test_alert('me@example.com', null);
  if pg_temp.requests() <> v_before + 1 then perform pg_temp.fail('test alert did not send'); end if;
end $$;

-- Signed-in people may read alert_status() and their own delivery log, and
-- nothing else here.
select pg_temp.act_as('00000000-0000-0000-0000-0000000000d1');
do $$ begin
  perform public.alert_status();
  -- Thursday's missed (3), Friday's OK (1) and help (3), Saturday's two missed (6).
  if (select count(*) from public.alert_deliveries) <> 13 then
    perform pg_temp.fail('Dana should see all 13 of Rose''s deliveries');
  end if;
  begin
    perform public.process_alerts();
    perform pg_temp.fail('a signed-in user ran the alert job');
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.send_test_alert('x@example.com');
    perform pg_temp.fail('a signed-in user sent a test alert');
  exception when insufficient_privilege then null;
  end;
  begin
    perform 1 from public.alert_settings;
    perform pg_temp.fail('a signed-in user read alert_settings');
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-00000000000a');
do $$ begin
  if exists (select 1 from public.alert_deliveries) then
    perform pg_temp.fail('Alice can see deliveries for someone else''s circle');
  end if;
end $$;
reset role;

\echo 'All alert tests passed.'
