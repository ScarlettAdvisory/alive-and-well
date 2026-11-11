-- Tests for help choices (20261111000000_help_types.sql). Runs last.

reset role;
create function pg_temp.fail(msg text) returns void language plpgsql as $$
begin raise exception 'FAIL: %', msg; end $$;
create function pg_temp.act_as(p_user uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated')::text, false);
  set role authenticated;
end $$;

delete from public.seniors;
delete from public.alert_deliveries;
update public.alert_settings
set email_live = true, sms_live = true, sms_from = '+12265550100', live_since = '2026-11-01', reminders_live = false;

insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000a9', 'pat@example.com')
on conflict do nothing;
insert into public.seniors (id, first_name, timezone)
values ('00000000-0000-0000-0000-00000000e100', 'Pat', 'America/Toronto');
insert into public.circle_members (senior_id, user_id, role)
values ('00000000-0000-0000-0000-00000000e100', '00000000-0000-0000-0000-0000000000a9', 'senior');
insert into public.contacts (senior_id, name, email, phone, sms_consent_at)
values ('00000000-0000-0000-0000-00000000e100', 'Kim', 'kim@example.com', '+16135550199', '2026-11-01');

-- The app can record what kind of help, but only on a help request.
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a9');
insert into public.checkins (id, senior_id, status, help_type)
values ('00000000-0000-0000-0000-00000000e101', '00000000-0000-0000-0000-00000000e100', 'need_help', 'transport');
do $$ begin
  begin
    insert into public.checkins (senior_id, status, help_type)
    values ('00000000-0000-0000-0000-00000000e100', 'ok', 'doctor');
    perform pg_temp.fail('help type saved on an "I''m OK"');
  exception when check_violation then null;
  end;
  begin
    insert into public.checkins (senior_id, status, help_type)
    values ('00000000-0000-0000-0000-00000000e100', 'need_help', 'haircut');
    perform pg_temp.fail('unknown help type saved');
  exception when check_violation then null;
  end;
end $$;
reset role;

-- The alert names it. "Other" (with a note) and no choice name nothing.
update public.checkins set occurred_at = '2026-11-11 11:16-05' where id = '00000000-0000-0000-0000-00000000e101';
insert into public.checkins (id, senior_id, status, help_type, message, occurred_at) values
  ('00000000-0000-0000-0000-00000000e102', '00000000-0000-0000-0000-00000000e100', 'need_help', 'other', 'My cat is stuck', '2026-11-11 11:20-05');
do $$
declare v_before bigint := coalesce((select max(id) from net.requests), 0);
begin
  perform public.process_alerts('2026-11-11 11:21-05');
  if not exists (select 1 from net.requests where id > v_before
                 and body ->> 'text' = 'Alive & Well: Pat asked for help ("I need transport") at 11:16 a.m. Please call or visit now. Emergency? Call 911.') then
    perform pg_temp.fail('transport text is wrong: ' || coalesce((select string_agg(body ->> 'text', ' | ') from net.requests where id > v_before and url like '%sms%'), 'none'));
  end if;
  if not exists (select 1 from net.requests where id > v_before
                 and body ->> 'subject' = 'Pat asked for help: I need transport'
                 and body ->> 'text' like 'Pat pressed "I need help" in Alive & Well at 11:16 a.m. on Wednesday, November 11 and chose "I need transport".%') then
    perform pg_temp.fail('transport email is wrong');
  end if;
  if not exists (select 1 from net.requests where id > v_before
                 and body ->> 'subject' = 'Pat asked for help'
                 and body ->> 'text' like 'Pat pressed "I need help" in Alive & Well at 11:20 a.m. on Wednesday, November 11.%Pat wrote: "My cat is stuck"%') then
    perform pg_temp.fail('"Other" email is wrong');
  end if;
  if not exists (select 1 from net.requests where id > v_before
                 and body ->> 'text' = 'Alive & Well: Pat pressed "I need help" at 11:20 a.m. Please call or visit now. Emergency? Call 911.') then
    perform pg_temp.fail('"Other" text is wrong');
  end if;
end $$;

-- Every label fits in one text message.
do $$
declare t text;
begin
  foreach t in array array['doctor', 'supplies', 'transport', 'personal_care'] loop
    if length((select sms from public.alert_message('need_help', 'Margaret-Anne', 'America/Toronto',
                 '2026-11-11 23:59-05', null, null, null, false, t))) > 160 then
      perform pg_temp.fail('text for ' || t || ' is longer than one message');
    end if;
  end loop;
end $$;

\echo 'All help type tests passed.'
