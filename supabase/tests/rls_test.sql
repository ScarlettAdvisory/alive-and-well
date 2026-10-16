\o /dev/null
-- Row level security tests. Run with scripts/test-db.sh.
-- Any failed check raises an exception and stops the run (ON_ERROR_STOP).

\set ON_ERROR_STOP on

-- Two families: Alice looks after Margaret; Bob is Walter, checking in himself.
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000000a', 'alice@example.com'),
  ('00000000-0000-0000-0000-00000000000b', 'bob@example.com');

do $$ begin
  if (select count(*) from public.profiles) <> 2 then
    raise exception 'FAIL: a profile should be created for each new user';
  end if;
end $$;

create function pg_temp.act_as(p_user uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated')::text, false);
  set role authenticated;
end $$;

-- Alice sets up Margaret.
select pg_temp.act_as('00000000-0000-0000-0000-00000000000a');
select public.create_senior('Margaret', 'America/Toronto', 'family') as margaret \gset
select set_config('test.margaret', :'margaret', false);
insert into public.contacts (senior_id, name, email, phone)
  values (:'margaret', 'Alice', 'alice@example.com', '+16135550101');
insert into public.schedules (senior_id, label, time_of_day)
  values (:'margaret', 'Morning check-in', '09:00') returning id as margaret_sched \gset
select set_config('test.margaret_sched', :'margaret_sched', false);

-- A check-in from the app: time, author and alert state are forced server-side.
insert into public.checkins (senior_id, status, message, occurred_at, alert_state, notified_contacts, schedule_id)
  values (:'margaret', 'ok', 'Fine today', '2000-01-01', 'sent', '{00000000-0000-0000-0000-000000000099}', :'margaret_sched');

do $$ declare r record; begin
  select * into r from public.checkins;
  if r.occurred_at < now() - interval '1 minute' then raise exception 'FAIL: occurred_at was not forced to now()'; end if;
  if r.alert_state <> 'pending' then raise exception 'FAIL: alert_state was not forced to pending'; end if;
  if r.notified_contacts <> '{}' then raise exception 'FAIL: notified_contacts was not cleared'; end if;
  if r.created_by <> '00000000-0000-0000-0000-00000000000a' then raise exception 'FAIL: created_by was not set to the caller'; end if;
end $$;

-- The app can't record a missed check-in, or edit or delete history.
do $$ begin
  begin
    insert into public.checkins (senior_id, status)
      select id, 'no_response' from public.seniors;
    raise exception 'FAIL: app inserted a no_response check-in';
  exception when insufficient_privilege then null;
  end;
  update public.checkins set status = 'need_help';
  if exists (select 1 from public.checkins where status = 'need_help') then
    raise exception 'FAIL: app updated a check-in';
  end if;
  delete from public.checkins;
  if not exists (select 1 from public.checkins) then
    raise exception 'FAIL: app deleted a check-in';
  end if;
end $$;

-- Bob sets himself up and must see nothing of Margaret's.
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-00000000000b');
select public.create_senior('Walter', 'America/Vancouver', 'senior') as walter \gset
select set_config('test.walter', :'walter', false);

do $$ begin
  if (select count(*) from public.seniors) <> 1 then raise exception 'FAIL: Bob sees other seniors'; end if;
  if exists (select 1 from public.contacts) then raise exception 'FAIL: Bob sees another family''s contacts'; end if;
  if exists (select 1 from public.schedules) then raise exception 'FAIL: Bob sees another family''s schedules'; end if;
  if exists (select 1 from public.checkins) then raise exception 'FAIL: Bob sees another family''s check-ins'; end if;
  if (select count(*) from public.circle_members) <> 1 then raise exception 'FAIL: Bob sees other circles'; end if;
  if (select count(*) from public.profiles) <> 1 then raise exception 'FAIL: Bob sees other profiles'; end if;
end $$;

-- Bob can't write into Margaret's circle.
do $$ begin
  begin
    insert into public.contacts (senior_id, name, email)
      values (current_setting('test.margaret')::uuid, 'Mallory', 'mallory@example.com');
    raise exception 'FAIL: Bob added a contact for Margaret';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.checkins (senior_id, status)
      values (current_setting('test.margaret')::uuid, 'ok');
    raise exception 'FAIL: Bob checked in for Margaret';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.circle_members (senior_id, user_id, role)
      values (current_setting('test.margaret')::uuid, '00000000-0000-0000-0000-00000000000b', 'family');
    raise exception 'FAIL: Bob added himself to Margaret''s circle';
  exception when insufficient_privilege then null;
  end;
end $$;

-- Bob can't attach his check-in to Margaret's schedule.
do $$ begin
  begin
    insert into public.checkins (senior_id, status, schedule_id)
      values (current_setting('test.walter')::uuid, 'ok', current_setting('test.margaret_sched')::uuid);
    raise exception 'FAIL: check-in linked to another senior''s schedule';
  exception when insufficient_privilege then null;
  end;
end $$;

-- Input validation in create_senior.
do $$ begin
  begin
    perform public.create_senior('X', 'Not/AZone', 'family');
    raise exception 'FAIL: unknown time zone accepted';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.create_senior('X', 'America/Toronto', 'admin');
    raise exception 'FAIL: unknown role accepted';
  exception when invalid_parameter_value then null;
  end;
end $$;

-- Signed-out visitors see nothing and can't create seniors.
reset role;
select set_config('request.jwt.claims', '{"role":"anon"}', false);
set role anon;
do $$ begin
  if exists (select 1 from public.seniors) or exists (select 1 from public.checkins) then
    raise exception 'FAIL: anon can read data';
  end if;
  begin
    perform public.create_senior('X', 'America/Toronto', 'family');
    raise exception 'FAIL: anon created a senior';
  exception when insufficient_privilege then null;
  end;
end $$;

-- The alert job (service role) can record a missed check-in, once per occurrence.
reset role;
select set_config('request.jwt.claims', '{"role":"service_role"}', false);
set role service_role;
insert into public.checkins (senior_id, status, schedule_id, scheduled_for, alert_state)
  values (:'margaret', 'no_response', :'margaret_sched', '2026-10-15 13:00+00', 'sent');
do $$ begin
  if not exists (select 1 from public.checkins where status = 'no_response' and alert_state = 'sent') then
    raise exception 'FAIL: service role values were overwritten';
  end if;
  begin
    insert into public.checkins (senior_id, status, schedule_id, scheduled_for)
      values (current_setting('test.margaret')::uuid, 'no_response',
              current_setting('test.margaret_sched')::uuid, '2026-10-15 13:00+00');
    raise exception 'FAIL: duplicate missed check-in recorded';
  exception when unique_violation then null;
  end;
end $$;

-- Invites: Alice invites Margaret (who signs in on her own phone).
reset role;
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000000c', 'margaret@example.com');
update public.profiles set display_name = 'Alice' where id = '00000000-0000-0000-0000-00000000000a';

select pg_temp.act_as('00000000-0000-0000-0000-00000000000a');
select public.create_invite(:'margaret', 'senior') as invite \gset
select set_config('test.invite', :'invite', false);

do $$ begin
  if current_setting('test.invite') !~ '^[A-HJ-KM-NP-Z2-9]{8}$' then
    raise exception 'FAIL: invite code has the wrong shape: %', current_setting('test.invite');
  end if;
  if (select count(*) from public.circle_invites) <> 1 then
    raise exception 'FAIL: Alice can''t see her invite';
  end if;
end $$;

-- Bob can't see Alice's invites or create invites for Margaret.
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-00000000000b');
do $$ begin
  if exists (select 1 from public.circle_invites) then
    raise exception 'FAIL: Bob sees another circle''s invites';
  end if;
  begin
    perform public.create_invite(current_setting('test.margaret')::uuid, 'family');
    raise exception 'FAIL: Bob created an invite for Margaret';
  exception when insufficient_privilege then null;
  end;
  if exists (select 1 from public.circle_people(current_setting('test.margaret')::uuid)) then
    raise exception 'FAIL: Bob can list Margaret''s circle';
  end if;
end $$;

-- Margaret joins with the code, typed loosely (lowercase, with a space).
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-00000000000c');
select public.accept_invite(lower(substr(:'invite', 1, 4)) || ' ' || substr(:'invite', 5)) as joined \gset
do $$ declare r record; begin
  if current_setting('test.margaret') <> (select senior_id::text from public.circle_members limit 1) then
    raise exception 'FAIL: Margaret did not join her circle';
  end if;
  if (select role from public.circle_members where user_id = '00000000-0000-0000-0000-00000000000c') <> 'senior' then
    raise exception 'FAIL: Margaret joined with the wrong role';
  end if;
  if (select count(*) from public.contacts) <> 1 then
    raise exception 'FAIL: Margaret can''t see her contacts after joining';
  end if;
  select string_agg(coalesce(display_name, '?') || ':' || role || ':' || is_me, ',' order by display_name nulls last) into r
    from public.circle_people(current_setting('test.margaret')::uuid);
  if r.string_agg <> 'Alice:family:false,?:senior:true' then
    raise exception 'FAIL: circle_people returned %', r.string_agg;
  end if;
end $$;

-- A used code can't be reused; an expired one doesn't work.
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-00000000000b');
do $$ begin
  begin
    perform public.accept_invite(current_setting('test.invite'));
    raise exception 'FAIL: a used invite worked again';
  exception when sqlstate 'PT404' then null;
  end;
  begin
    perform public.accept_invite('ZZZZZZZZ');
    raise exception 'FAIL: a made-up invite worked';
  exception when sqlstate 'PT404' then null;
  end;
end $$;
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-00000000000a');
select public.create_invite(:'margaret', 'family') as invite2 \gset
reset role;
update public.circle_invites set expires_at = now() - interval '1 minute' where code = :'invite2';
select set_config('test.invite2', :'invite2', false);
select pg_temp.act_as('00000000-0000-0000-0000-00000000000b');
do $$ begin
  begin
    perform public.accept_invite(current_setting('test.invite2'));
    raise exception 'FAIL: an expired invite worked';
  exception when sqlstate 'PT404' then null;
  end;
  if exists (select 1 from public.seniors where first_name = 'Margaret') then
    raise exception 'FAIL: Bob got into Margaret''s circle';
  end if;
end $$;

reset role;
\echo 'All RLS tests passed.'
