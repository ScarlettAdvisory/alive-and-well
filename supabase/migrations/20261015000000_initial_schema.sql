-- Alive & Well: initial schema.
--
-- A "senior" is the person who checks in. Each senior has a circle of app users
-- (the senior themselves and/or family members) who can see and manage
-- everything about them, plus a list of contacts who receive alerts. Contacts
-- don't need an app account.
--
-- Every table has row level security on: people can only reach seniors whose
-- circle they belong to. The alert job runs with the service role, which
-- bypasses RLS, and is the only thing that updates alert fields on check-ins.

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text check (char_length(display_name) <= 80),
  created_at timestamptz not null default now()
);

create table public.seniors (
  id uuid primary key default gen_random_uuid(),
  first_name text not null check (char_length(btrim(first_name)) between 1 and 80),
  -- IANA name, e.g. America/Toronto. Check-in times are in this zone.
  timezone text not null default 'America/Toronto',
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now()
);

create table public.circle_members (
  senior_id uuid not null references public.seniors (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  role text not null check (role in ('senior', 'family')),
  created_at timestamptz not null default now(),
  primary key (senior_id, user_id)
);
create index circle_members_user_id_idx on public.circle_members (user_id);

create table public.contacts (
  id uuid primary key default gen_random_uuid(),
  senior_id uuid not null references public.seniors (id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 80),
  relationship text check (char_length(relationship) <= 80),
  email text check (email ~ '^[^\s@]+@[^\s@]+\.[^\s@]+$'),
  -- E.164, e.g. +16135550123
  phone text check (phone ~ '^\+[1-9][0-9]{7,14}$'),
  -- Routine "I'm OK" messages go only to contacts with this on. Missed
  -- check-in and help alerts always go to every contact.
  notify_on_checkin boolean not null default true,
  -- Set when the contact agrees to receive alert texts; no texts without it.
  sms_consent_at timestamptz,
  created_at timestamptz not null default now(),
  check (email is not null or phone is not null)
);
create index contacts_senior_id_idx on public.contacts (senior_id);

create table public.schedules (
  id uuid primary key default gen_random_uuid(),
  senior_id uuid not null references public.seniors (id) on delete cascade,
  label text not null default 'Check-in' check (char_length(btrim(label)) between 1 and 80),
  time_of_day time not null,
  frequency text not null default 'daily'
    check (frequency in ('daily', 'weekdays', 'weekends', 'weekly')),
  -- 0 = Sunday ... 6 = Saturday; required for weekly schedules.
  day_of_week smallint check (day_of_week between 0 and 6),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  check (frequency <> 'weekly' or day_of_week is not null)
);
create index schedules_senior_id_idx on public.schedules (senior_id);

create table public.checkins (
  id uuid primary key default gen_random_uuid(),
  senior_id uuid not null references public.seniors (id) on delete cascade,
  status text not null check (status in ('ok', 'need_help', 'no_response')),
  message text check (char_length(message) <= 1000),
  occurred_at timestamptz not null default now(),
  -- The scheduled check-in this answers (or missed), if any.
  schedule_id uuid references public.schedules (id) on delete set null,
  scheduled_for timestamptz,
  created_by uuid references auth.users (id) on delete set null,
  -- pending: the alert job still has to send something for this row.
  alert_state text not null default 'pending'
    check (alert_state in ('pending', 'not_needed', 'sent', 'failed', 'no_contacts')),
  alerted_at timestamptz,
  notified_contacts uuid[] not null default '{}'
);
create index checkins_senior_occurred_idx on public.checkins (senior_id, occurred_at desc);
create index checkins_pending_idx on public.checkins (occurred_at) where alert_state = 'pending';
-- The alert job records at most one missed check-in per scheduled occurrence.
create unique index checkins_one_missed_per_occurrence
  on public.checkins (schedule_id, scheduled_for) where status = 'no_response';

-- ---------------------------------------------------------------------------
-- Helpers and triggers
-- ---------------------------------------------------------------------------

-- Security definer so policies can consult circle_members without recursing
-- into circle_members' own policy.
create function public.is_circle_member(p_senior_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.circle_members m
    where m.senior_id = p_senior_id and m.user_id = (select auth.uid())
  );
$$;

create function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id) values (new.id);
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Check-ins written from the app can't fake their time, author or alert state.
-- The service role (the alert job) is exempt.
create function public.checkins_before_insert()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    new.occurred_at := now();
    new.created_by := auth.uid();
    new.alert_state := 'pending';
    new.alerted_at := null;
    new.notified_contacts := '{}';
  end if;
  return new;
end;
$$;

create trigger checkins_before_insert
  before insert on public.checkins
  for each row execute function public.checkins_before_insert();

-- Creates a senior and adds the caller to their circle in one step.
-- p_role is 'senior' when the caller is the person checking in, 'family' when
-- they're setting it up for someone else.
create function public.create_senior(p_first_name text, p_timezone text, p_role text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_senior uuid;
begin
  if v_user is null then
    raise exception 'Not signed in' using errcode = '42501';
  end if;
  if p_role not in ('senior', 'family') then
    raise exception 'Unknown role %', p_role using errcode = '22023';
  end if;
  if not exists (select 1 from pg_catalog.pg_timezone_names where name = p_timezone) then
    raise exception 'Unknown time zone %', p_timezone using errcode = '22023';
  end if;

  insert into public.seniors (first_name, timezone, created_by)
  values (btrim(p_first_name), p_timezone, v_user)
  returning id into v_senior;

  insert into public.circle_members (senior_id, user_id, role)
  values (v_senior, v_user, p_role);

  return v_senior;
end;
$$;

revoke execute on function public.create_senior(text, text, text) from public, anon;
grant execute on function public.create_senior(text, text, text) to authenticated;
revoke execute on function public.is_circle_member(uuid) from public, anon;
grant execute on function public.is_circle_member(uuid) to authenticated;
revoke execute on function public.handle_new_user() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------------

alter table public.profiles enable row level security;
alter table public.seniors enable row level security;
alter table public.circle_members enable row level security;
alter table public.contacts enable row level security;
alter table public.schedules enable row level security;
alter table public.checkins enable row level security;

create policy "Read own profile" on public.profiles
  for select to authenticated using (id = (select auth.uid()));
create policy "Update own profile" on public.profiles
  for update to authenticated using (id = (select auth.uid())) with check (id = (select auth.uid()));

-- Seniors are created through create_senior(), so there's no insert policy.
create policy "Circle reads senior" on public.seniors
  for select to authenticated using (public.is_circle_member(id));
create policy "Circle updates senior" on public.seniors
  for update to authenticated using (public.is_circle_member(id)) with check (public.is_circle_member(id));

-- Adding people to a circle (invitations) comes in a later phase.
create policy "Circle reads members" on public.circle_members
  for select to authenticated using (public.is_circle_member(senior_id));
create policy "Leave a circle" on public.circle_members
  for delete to authenticated using (user_id = (select auth.uid()));

create policy "Circle manages contacts" on public.contacts
  for all to authenticated
  using (public.is_circle_member(senior_id)) with check (public.is_circle_member(senior_id));

create policy "Circle manages schedules" on public.schedules
  for all to authenticated
  using (public.is_circle_member(senior_id)) with check (public.is_circle_member(senior_id));

-- Check-ins are a record: the app can add "I'm OK" and "I need help" rows but
-- never change or remove them. Missed check-ins come only from the alert job.
create policy "Circle reads check-ins" on public.checkins
  for select to authenticated using (public.is_circle_member(senior_id));
create policy "Circle adds check-ins" on public.checkins
  for insert to authenticated
  with check (
    public.is_circle_member(senior_id)
    and status in ('ok', 'need_help')
    and (
      schedule_id is null
      or exists (select 1 from public.schedules s where s.id = schedule_id and s.senior_id = checkins.senior_id)
    )
  );
