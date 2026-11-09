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

-- Bird answers 202 Accepted to everything sent so far.
create function pg_temp.bird_accepts_all() returns void language sql as $$
  insert into net._http_response (id, status_code, content)
  select d.request_id, 202, '{}' from public.alert_deliveries d
  where d.status = 'queued' and d.request_id is not null
  on conflict (id) do nothing
$$;

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
-- These schedules have been as they are since they were created.
update public.schedules set effective_from = created_at;
-- An "I'm OK" from before alerts were switched on must never be sent.
insert into public.checkins (id, senior_id, status, occurred_at)
values ('00000000-0000-0000-0000-00000000e000', '00000000-0000-0000-0000-00000000a001', 'ok', '2026-11-04 12:00-05');
insert into vault.decrypted_secrets values ('bird_api_key', 'bk_us1_testkey');

-- Not switched on: nothing happens.
do $$ begin
  if public.process_alerts('2026-11-05 10:30-05') ->> 'live' <> 'false' then
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
      and body ->> 'text' like 'Rose hasn''t checked in for their Morning check-in, which was due at 9:00 a.m. on Thursday, November 5.%'
      and body -> 'from' = '{"email": "alerts@seniorsalive.ca", "name": "Alive & Well"}'
  ) then
    perform pg_temp.fail('missed-check-in email to Ann is wrong');
  end if;
  if (select count(*) from public.alert_deliveries where checkin_id = v_missed.id and status = 'queued') <> 3 then
    perform pg_temp.fail('deliveries were not logged');
  end if;
end $$;

-- Running again doesn't record or send anything twice.
select pg_temp.bird_accepts_all();
do $$ begin
  perform public.process_alerts('2026-11-05 10:01-05');
  perform public.process_alerts('2026-11-05 15:00-05');
  if (select count(*) from public.checkins where senior_id = '00000000-0000-0000-0000-00000000a001' and status = 'no_response') <> 1 then
    perform pg_temp.fail('missed check-in recorded twice');
  end if;
  if pg_temp.requests() <> 3 then perform pg_temp.fail('alert sent twice'); end if;
end $$;

select pg_temp.bird_accepts_all();

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

select pg_temp.bird_accepts_all();

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
from public.alert_deliveries d
where not exists (select 1 from net._http_response r where r.id = d.request_id);
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
update public.schedules set effective_from = created_at where senior_id = '00000000-0000-0000-0000-00000000a002';
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

-- ---------------------------------------------------------------------------
-- Review fixes
-- ---------------------------------------------------------------------------

-- From here on only Rose's morning check-in is active, and Walt is set aside.
update public.schedules set is_active = false
where id in ('00000000-0000-0000-0000-00000000b002', '00000000-0000-0000-0000-00000000b003');
delete from public.seniors where id = '00000000-0000-0000-0000-00000000a002';
update public.alert_settings set sms_from = '+12265550100';
select pg_temp.bird_accepts_all();

-- "Has now checked in": Sunday's 9:00 is missed and Ann and Ben are told.
-- Rose checks in at 10:20, so both hear she's OK (Ben too, though he doesn't
-- get routine messages), and Ann gets a text because she was texted.
do $$
declare v_before integer;
begin
  perform public.process_alerts('2026-11-08 10:00:30-05');
  perform pg_temp.bird_accepts_all();
  insert into public.checkins (id, senior_id, status, occurred_at)
  values ('00000000-0000-0000-0000-00000000e003', '00000000-0000-0000-0000-00000000a001', 'ok', '2026-11-08 10:20-05');
  v_before := pg_temp.requests();
  perform public.process_alerts('2026-11-08 10:20:30-05');
  if pg_temp.requests() <> v_before + 3 then
    perform pg_temp.fail('follow-up should send 3 messages, sent ' || (pg_temp.requests() - v_before));
  end if;
  if (select count(*) from net.requests where id > v_before and body ->> 'subject' = 'Rose has now checked in') <> 2 then
    perform pg_temp.fail('follow-up emails to Ann and Ben are wrong');
  end if;
  if not exists (select 1 from net.requests where id > v_before
                 and body ->> 'text' = 'Alive & Well: Rose has now checked in and said "I''m OK" (10:20 a.m.).') then
    perform pg_temp.fail('follow-up text to Ann is wrong');
  end if;
end $$;
select pg_temp.bird_accepts_all();

-- Retries: Bird is briefly down (503), then doesn't answer, then accepts.
-- Each retry sends the identical request with the same key.
insert into public.checkins (id, senior_id, status, occurred_at)
values ('00000000-0000-0000-0000-00000000e004', '00000000-0000-0000-0000-00000000a001', 'need_help', '2026-11-08 12:00-05');
do $$
declare
  v_first integer;
  v_d record;
begin
  perform public.process_alerts('2026-11-08 12:00:30-05');
  v_first := pg_temp.requests();
  insert into net._http_response (id, status_code, content)
  select request_id, 503, 'Service Unavailable' from public.alert_deliveries
  where checkin_id = '00000000-0000-0000-0000-00000000e004';
  perform public.process_alerts('2026-11-08 12:01-05');
  if (select count(*) from public.alert_deliveries
      where checkin_id = '00000000-0000-0000-0000-00000000e004' and status = 'retry') <> 3 then
    perform pg_temp.fail('503s were not set to retry');
  end if;
  if pg_temp.requests() <> v_first then perform pg_temp.fail('retried too soon'); end if;
  perform public.process_alerts('2026-11-08 12:03-05');
  if pg_temp.requests() <> v_first + 3 then perform pg_temp.fail('retries were not sent after 2 minutes'); end if;
  for v_d in select * from public.alert_deliveries where checkin_id = '00000000-0000-0000-0000-00000000e004' loop
    if (select count(distinct (body, headers ->> 'Idempotency-Key')) from net.requests r
        where r.headers ->> 'Idempotency-Key' = v_d.idempotency_key) <> 1
       or (select count(*) from net.requests r where r.headers ->> 'Idempotency-Key' = v_d.idempotency_key) <> 2 then
      perform pg_temp.fail('a retry differed from the first attempt: ' || v_d.idempotency_key);
    end if;
  end loop;
  -- No answer at all for 10 minutes: tried again (third attempt) 4 minutes later.
  perform public.process_alerts('2026-11-08 12:14-05');
  if (select count(*) from public.alert_deliveries
      where checkin_id = '00000000-0000-0000-0000-00000000e004' and status = 'retry' and error = 'No answer from Bird') <> 3 then
    perform pg_temp.fail('unanswered sends were not set to retry');
  end if;
  perform public.process_alerts('2026-11-08 12:18-05');
  perform pg_temp.bird_accepts_all();
  perform public.process_alerts('2026-11-08 12:19-05');
  if (select count(*) from public.alert_deliveries
      where checkin_id = '00000000-0000-0000-0000-00000000e004' and status = 'accepted' and attempts = 3) <> 3 then
    perform pg_temp.fail('sends were not accepted on the third attempt');
  end if;
  if (select alert_state from public.checkins where id = '00000000-0000-0000-0000-00000000e004') <> 'sent' then
    perform pg_temp.fail('retried help alert not marked sent');
  end if;
end $$;

-- A time zone that isn't real is refused, and if one gets in anyway it
-- doesn't stop other seniors' alerts.
do $$ begin
  begin
    update public.seniors set timezone = 'Not/AZone' where id = '00000000-0000-0000-0000-00000000a001';
    perform pg_temp.fail('an unknown time zone was saved');
  exception when invalid_parameter_value then null;
  end;
end $$;
insert into public.seniors (id, first_name, timezone)
values ('00000000-0000-0000-0000-00000000a003', 'Bad', 'America/Toronto');
insert into public.contacts (senior_id, name, email)
values ('00000000-0000-0000-0000-00000000a003', 'Zed', 'zed@example.com');
insert into public.schedules (senior_id, time_of_day, created_at, effective_from)
values ('00000000-0000-0000-0000-00000000a003', '09:00', '2026-11-01', '2026-11-01');
alter table public.seniors disable trigger seniors_check_timezone;
update public.seniors set timezone = 'Not/AZone' where id = '00000000-0000-0000-0000-00000000a003';
alter table public.seniors enable trigger seniors_check_timezone;
insert into public.checkins (id, senior_id, status, occurred_at) values
  ('00000000-0000-0000-0000-00000000e005', '00000000-0000-0000-0000-00000000a001', 'need_help', '2026-11-09 08:00-05'),
  ('00000000-0000-0000-0000-00000000e006', '00000000-0000-0000-0000-00000000a003', 'need_help', '2026-11-09 08:00-05');
do $$
declare v_result jsonb;
begin
  v_result := public.process_alerts('2026-11-09 08:00:30-05');
  if (select alert_state from public.checkins where id = '00000000-0000-0000-0000-00000000e005') <> 'sent' then
    perform pg_temp.fail('a bad time zone elsewhere stopped Rose''s alert: ' || v_result);
  end if;
  if (select alert_state from public.checkins where id = '00000000-0000-0000-0000-00000000e006') <> 'sent' then
    perform pg_temp.fail('help alert for a senior with a bad time zone was not sent: ' || v_result);
  end if;
end $$;
delete from public.seniors where id = '00000000-0000-0000-0000-00000000a003';
select pg_temp.bird_accepts_all();

-- Editing a schedule: renaming it keeps its start; changing its time restarts
-- it, and times before the change are never reported missed.
select pg_temp.act_as('00000000-0000-0000-0000-0000000000d1');
update public.schedules set label = 'Morning hello', effective_from = '2000-01-01'
where id = '00000000-0000-0000-0000-00000000b001';
reset role;
do $$ begin
  if (select effective_from from public.schedules where id = '00000000-0000-0000-0000-00000000b001') <> '2026-11-01' then
    perform pg_temp.fail('renaming a schedule changed when it took effect');
  end if;
end $$;
select pg_temp.act_as('00000000-0000-0000-0000-0000000000d1');
update public.schedules set time_of_day = '09:05' where id = '00000000-0000-0000-0000-00000000b001';
reset role;
do $$ begin
  if (select effective_from from public.schedules where id = '00000000-0000-0000-0000-00000000b001') < now() - interval '1 minute' then
    perform pg_temp.fail('changing a schedule''s time did not restart it');
  end if;
  -- Pretend the change happened at 9:30 on Monday: 9:05 that day isn't missed.
  update public.schedules set effective_from = '2026-11-09 09:30-05'
  where id = '00000000-0000-0000-0000-00000000b001';
  perform public.process_alerts('2026-11-09 10:10-05');
  if exists (select 1 from public.checkins
             where schedule_id = '00000000-0000-0000-0000-00000000b001' and scheduled_for = '2026-11-09 09:05-05') then
    perform pg_temp.fail('a time from before the schedule changed was reported missed');
  end if;
end $$;

-- Too many messages to one address in an hour: the rest are skipped.
do $$ begin
  for i in 1..12 loop
    perform public.send_test_alert('flood@example.com');
  end loop;
  if (select count(*) from public.alert_deliveries where destination = 'flood@example.com' and status = 'queued') <> 10
     or (select count(*) from public.alert_deliveries where destination = 'flood@example.com' and status = 'skipped') <> 2 then
    perform pg_temp.fail('rate limit did not stop at 10 an hour');
  end if;
end $$;

\echo 'All alert tests passed.'
