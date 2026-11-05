-- Phase 3: alerts.
--
-- process_alerts() runs every minute (pg_cron, set up by
-- supabase/setup/turn_on_alerts.sql). Each run:
--   1. records how earlier sends went (pg_net responses from Bird) and
--      re-sends any that hit a temporary problem,
--   2. records a no_response check-in for every scheduled check-in that is
--      an hour overdue with no "I'm OK" or "I need help" around it,
--   3. emails and texts contacts about every check-in still pending.
-- Help requests and missed check-ins go to every contact. Routine "I'm OK"
-- check-ins are emailed only to contacts with notify_on_checkin on, plus a
-- "has now checked in" follow-up to anyone told about a missed check-in it
-- answers. Texts go only to contacts with sms_consent_at set, and only once
-- texting is on.
--
-- Sends go to Bird's API through pg_net, using the API key stored in Supabase
-- Vault as 'bird_api_key'. Nothing here runs until alert_settings says so.

-- ---------------------------------------------------------------------------
-- Data the job depends on
-- ---------------------------------------------------------------------------

-- A senior's time zone must be real: the job converts every check-in time
-- with it. create_senior() already checks; this covers later edits too.
create function public.seniors_check_timezone()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not exists (select 1 from pg_catalog.pg_timezone_names z where z.name = new.timezone) then
    raise exception 'Unknown time zone: %', new.timezone using errcode = '22023';
  end if;
  return new;
end;
$$;

create trigger seniors_check_timezone
  before insert or update of timezone on public.seniors
  for each row execute function public.seniors_check_timezone();

-- The time zone if it's real, otherwise null. Lets the job skip a senior with
-- a bad value instead of erroring for everyone.
create function public.valid_timezone(p_tz text)
returns text
language sql
stable
set search_path = ''
as $$ select z.name from pg_catalog.pg_timezone_names z where z.name = p_tz limit 1 $$;

-- When a schedule's time, days or on/off state last changed. Times before
-- this are never reported as missed, so editing a schedule can't produce an
-- alert for a time that didn't exist when it was due.
alter table public.schedules add column effective_from timestamptz;
update public.schedules set effective_from = created_at;
alter table public.schedules alter column effective_from set not null;
alter table public.schedules alter column effective_from set default now();

create function public.schedules_effective_from()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if current_user <> 'postgres' then
      new.effective_from := now();
    end if;
  elsif new.time_of_day is distinct from old.time_of_day
     or new.frequency is distinct from old.frequency
     or new.day_of_week is distinct from old.day_of_week
     or (new.is_active and not old.is_active) then
    new.effective_from := now();
  elsif current_user <> 'postgres' then
    new.effective_from := old.effective_from;
  end if;
  return new;
end;
$$;

create trigger schedules_effective_from
  before insert or update on public.schedules
  for each row execute function public.schedules_effective_from();

-- ---------------------------------------------------------------------------
-- Settings (one row) and delivery log
-- ---------------------------------------------------------------------------

create table public.alert_settings (
  id boolean primary key default true check (id),
  email_from_address text not null default 'alerts@seniorsalive.ca',
  email_from_name text not null default 'Alive & Well',
  -- E.164 number in Bird that texts come from.
  sms_from text check (sms_from ~ '^\+[1-9][0-9]{7,14}$'),
  email_live boolean not null default false,
  sms_live boolean not null default false,
  -- Check-ins before this moment are never alerted (no backlog at switch-on).
  live_since timestamptz,
  updated_at timestamptz not null default now()
);
insert into public.alert_settings default values;
alter table public.alert_settings enable row level security;
-- No policies: only the functions below read it.

create table public.alert_deliveries (
  id bigint generated always as identity primary key,
  checkin_id uuid references public.checkins (id) on delete cascade,
  contact_id uuid references public.contacts (id) on delete set null,
  channel text not null check (channel in ('email', 'sms')),
  destination text not null,
  -- The exact request, so a retry sends the same thing with the same key
  -- (Bird sends it once however often it's retried within 3 hours).
  path text not null,
  body jsonb not null,
  idempotency_key text not null,
  -- pg_net request id of the latest attempt; its answer lands in net._http_response.
  request_id bigint,
  -- queued: waiting for Bird's answer; accepted: Bird took it; retry: a
  -- temporary problem, sent again at next_attempt_at; failed: given up;
  -- skipped: not sent because this address got too many messages lately.
  status text not null default 'queued'
    check (status in ('queued', 'accepted', 'retry', 'failed', 'skipped')),
  attempts integer not null default 1,
  last_attempt_at timestamptz not null default now(),
  next_attempt_at timestamptz,
  http_status integer,
  error text,
  created_at timestamptz not null default now()
);
create index alert_deliveries_checkin_idx on public.alert_deliveries (checkin_id);
create index alert_deliveries_open_idx on public.alert_deliveries (status) where status in ('queued', 'retry');
create index alert_deliveries_destination_idx on public.alert_deliveries (destination, created_at);
alter table public.alert_deliveries enable row level security;
create policy "Circle reads alert deliveries" on public.alert_deliveries
  for select to authenticated
  using (exists (
    select 1 from public.checkins c where c.id = checkin_id and public.is_circle_member(c.senior_id)
  ));

-- The alert job runs as postgres and records missed check-ins with their real
-- times, so it is exempt from the app's check-in rules like the service role.
create or replace function public.checkins_before_insert()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' and current_user <> 'postgres' then
    new.occurred_at := now();
    new.created_by := auth.uid();
    new.alert_state := 'pending';
    new.alerted_at := null;
    new.notified_contacts := '{}';
  end if;
  return new;
end;
$$;

-- What the app may say about alerts. Texts count only once a number is set.
create function public.alert_status()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'email', s.email_live,
    'sms', s.sms_live and s.sms_from is not null
  )
  from public.alert_settings s
  where s.id;
$$;

-- ---------------------------------------------------------------------------
-- Wording
-- ---------------------------------------------------------------------------

-- "9:00 a.m." in the senior's time zone.
create function public.alert_time(p_at timestamptz, p_tz text)
returns text
language sql
stable
set search_path = ''
as $$ select to_char(p_at at time zone p_tz, 'FMHH12:MI a.m.') $$;

-- "Tuesday, November 3" in the senior's time zone.
create function public.alert_day(p_at timestamptz, p_tz text)
returns text
language sql
stable
set search_path = ''
as $$ select to_char(p_at at time zone p_tz, 'FMDay, FMMonth FMDD') $$;

create function public.html_escape(p text)
returns text
language sql
immutable
set search_path = ''
as $$
  select replace(replace(replace(replace(coalesce(p, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;')
$$;

-- Subject, plain text and SMS text for one check-in. p_followup marks an
-- "I'm OK" that answers a missed check-in people were already told about.
create function public.alert_message(
  p_status text,
  p_name text,
  p_tz text,
  p_occurred_at timestamptz,
  p_scheduled_for timestamptz,
  p_label text,
  p_note text,
  p_followup boolean default false
)
returns table (subject text, body text, sms text)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_at text := public.alert_time(p_occurred_at, p_tz);
  v_day text := public.alert_day(p_occurred_at, p_tz);
  v_due text;
  v_label text := coalesce(nullif(btrim(p_label), ''), 'check-in');
  v_note text := case when nullif(btrim(p_note), '') is not null
                   then E'\n\n' || p_name || ' wrote: "' || btrim(p_note) || '"' else '' end;
  v_footer text := E'\n\nThis message was sent automatically by Alive & Well. '
    || 'Alive & Well is not a medical alert service. In an emergency, call 911.';
begin
  -- alert_time() ends in "a.m."/"p.m.", which also ends a sentence, so no
  -- period is added after it.
  if p_status = 'need_help' then
    subject := p_name || ' asked for help';
    body := p_name || ' pressed "I need help" in Alive & Well at ' || v_at || ' on ' || v_day || '.'
      || v_note
      || E'\n\nPlease call or visit ' || p_name || ' now. If you think it is an emergency, call 911.'
      || v_footer;
    sms := 'Alive & Well: ' || p_name || ' pressed "I need help" at ' || v_at
      || ' Please call or visit now. Emergency? Call 911.';
  elsif p_status = 'no_response' then
    v_due := public.alert_time(coalesce(p_scheduled_for, p_occurred_at), p_tz);
    subject := p_name || ' hasn''t checked in';
    body := p_name || ' hasn''t checked in for their ' || v_label || ', which was due at ' || v_due
      || ' on ' || public.alert_day(coalesce(p_scheduled_for, p_occurred_at), p_tz) || '.'
      || E'\n\nPlease call or visit ' || p_name || ' to make sure they''re all right. '
      || 'If you can''t reach them and you''re worried, call 911.'
      || E'\n\nIf ' || p_name || ' checks in later, we''ll let you know.'
      || v_footer;
    sms := 'Alive & Well: ' || p_name || ' hasn''t checked in for their ' || v_label
      || ' (due ' || v_due || '). Please call or visit to check on them. Emergency? Call 911.';
  elsif p_followup then
    subject := p_name || ' has now checked in';
    body := p_name || ' checked in at ' || v_at || ' on ' || v_day || ' and said "I''m OK".'
      || v_note
      || E'\n\nThis follows our earlier message that ' || p_name || ' hadn''t checked in.'
      || v_footer;
    sms := 'Alive & Well: ' || p_name || ' has now checked in and said "I''m OK" (' || v_at || ').';
  else
    subject := p_name || ' checked in: I''m OK';
    body := p_name || ' checked in at ' || v_at || ' on ' || v_day || ' and said "I''m OK".'
      || v_note
      || E'\n\nYou get these because "I''m OK" messages are turned on for you in Alive & Well.'
      || v_footer;
    sms := null;
  end if;
  return next;
end;
$$;

-- ---------------------------------------------------------------------------
-- Sending through Bird
-- ---------------------------------------------------------------------------

-- Queues one request to Bird's API and returns the pg_net request id.
create function public.bird_post(p_path text, p_body jsonb, p_idempotency_key text)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key text;
  v_region text;
begin
  select s.decrypted_secret into v_key
  from vault.decrypted_secrets s where s.name = 'bird_api_key' limit 1;
  if v_key is null then
    raise exception 'Bird API key is missing from Vault (bird_api_key)';
  end if;
  -- Keys look like bk_us1_...; the region picks the API host.
  v_region := coalesce(substring(v_key from '^b[km]_([a-z0-9]+)_'), 'us1');
  return net.http_post(
    url := 'https://' || v_region || '.platform.bird.com' || p_path,
    body := p_body,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_key,
      'Idempotency-Key', p_idempotency_key
    ),
    timeout_milliseconds := 15000
  );
end;
$$;

create function public.email_request(p_to text, p_subject text, p_body text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'from', jsonb_build_object('email', s.email_from_address, 'name', s.email_from_name),
    'to', jsonb_build_array(p_to),
    'subject', p_subject,
    'text', p_body,
    'html', '<div style="font-family:Arial,sans-serif;font-size:18px;line-height:1.5;color:#111">'
      || replace(public.html_escape(p_body), E'\n', '<br>') || '</div>',
    'category', 'transactional',
    'track_opens', false,
    'track_clicks', false
  )
  from public.alert_settings s where s.id
$$;

create function public.sms_request(p_to text, p_text text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'to', p_to,
    'from', s.sms_from,
    'text', p_text,
    'category', 'transactional',
    'validity_period', 3600,
    'options', jsonb_build_object('smart_encoding', true)
  )
  from public.alert_settings s where s.id
$$;

-- Sends one message and logs it, unless this address has had too many
-- messages lately (protects people from floods and the sender's reputation).
-- Returns true when it was sent.
create function public.send_alert_message(
  p_checkin_id uuid, p_contact_id uuid, p_channel text, p_destination text,
  p_body jsonb, p_idempotency_key text, p_now timestamptz default now()
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_path text := case p_channel when 'email' then '/v1/email/messages' else '/v1/sms/messages' end;
  v_recent_hour integer;
  v_recent_day integer;
begin
  select count(*) filter (where d.created_at > p_now - interval '1 hour'),
         count(*)
  into v_recent_hour, v_recent_day
  from public.alert_deliveries d
  where d.destination = p_destination and d.status <> 'skipped'
    and d.created_at > p_now - interval '1 day';

  if v_recent_hour >= 10 or v_recent_day >= 40 then
    insert into public.alert_deliveries
      (checkin_id, contact_id, channel, destination, path, body, idempotency_key, status, error,
       created_at, last_attempt_at)
    values (p_checkin_id, p_contact_id, p_channel, p_destination, v_path, p_body, p_idempotency_key,
            'skipped', 'Too many messages to this address recently', p_now, p_now);
    return false;
  end if;

  insert into public.alert_deliveries
    (checkin_id, contact_id, channel, destination, path, body, idempotency_key, request_id,
     created_at, last_attempt_at)
  values (p_checkin_id, p_contact_id, p_channel, p_destination, v_path, p_body, p_idempotency_key,
          public.bird_post(v_path, p_body, p_idempotency_key), p_now, p_now);
  return true;
end;
$$;

-- ---------------------------------------------------------------------------
-- The job
-- ---------------------------------------------------------------------------

-- Copies Bird's answers (from pg_net) onto the delivery log. Temporary
-- problems (server errors, timeouts, rate limits, no answer within 10
-- minutes) are sent again after 2, 4 and 8 minutes with the same key; other
-- refusals are final. A check-in's alert is marked failed once none of its
-- messages were accepted or are still being tried.
create function public.reconcile_alert_deliveries(p_now timestamptz default now())
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  d record;
begin
  update public.alert_deliveries a
  set http_status = r.status_code,
      status = case
        when r.status_code between 200 and 299 then 'accepted'
        when r.status_code between 400 and 499 and r.status_code not in (408, 429) then 'failed'
        when a.attempts >= 4 then 'failed'
        else 'retry'
      end,
      next_attempt_at = p_now + make_interval(mins => power(2, a.attempts)::int),
      error = case
        when r.status_code between 200 and 299 then null
        else left(coalesce(r.error_msg, r.content::text, 'No response'), 500)
      end
  from net._http_response r
  where r.id = a.request_id and a.status = 'queued';

  update public.alert_deliveries a
  set status = case when a.attempts >= 4 then 'failed' else 'retry' end,
      next_attempt_at = p_now + make_interval(mins => power(2, a.attempts)::int),
      error = 'No answer from Bird'
  where a.status = 'queued' and a.last_attempt_at < p_now - interval '10 minutes';

  for d in
    select * from public.alert_deliveries
    where status = 'retry' and next_attempt_at <= p_now
    order by id
    for update skip locked
  loop
    update public.alert_deliveries
    set request_id = public.bird_post(d.path, d.body, d.idempotency_key),
        status = 'queued',
        attempts = d.attempts + 1,
        last_attempt_at = p_now,
        next_attempt_at = null
    where id = d.id;
  end loop;

  update public.checkins c
  set alert_state = 'failed'
  where c.alert_state = 'sent'
    and exists (
      select 1 from public.alert_deliveries a where a.checkin_id = c.id and a.status <> 'skipped'
    )
    and not exists (
      select 1 from public.alert_deliveries a
      where a.checkin_id = c.id and a.status in ('queued', 'accepted', 'retry')
    );
end;
$$;

-- Records a no_response check-in for each scheduled time that is an hour
-- overdue with no response from two hours before it to four hours after
-- (the same window the app uses). Looks at today and yesterday in the
-- senior's time zone, never before p_since or before the schedule's current
-- time and days took effect.
create function public.record_missed_checkins(p_now timestamptz, p_since timestamptz)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  with occ as (
    select s.id as schedule_id, s.senior_id, s.effective_from,
           (dd.d + s.time_of_day) at time zone coalesce(t.tz, 'UTC') as scheduled_for
    from public.schedules s
    join public.seniors sr on sr.id = s.senior_id
    -- A senior whose time zone isn't real is skipped rather than stopping
    -- everyone's alerts (the trigger above keeps new bad values out). The
    -- 'UTC' fallback only keeps the expression from erroring before the
    -- t.tz filter applies.
    cross join lateral (select public.valid_timezone(sr.timezone) as tz) t
    cross join lateral (
      select (p_now at time zone coalesce(t.tz, 'UTC'))::date - g as d from generate_series(0, 1) g
    ) dd
    where s.is_active
      and t.tz is not null
      and case s.frequency
        when 'daily' then true
        when 'weekdays' then extract(isodow from dd.d) between 1 and 5
        when 'weekends' then extract(isodow from dd.d) in (6, 7)
        when 'weekly' then extract(dow from dd.d) = s.day_of_week
        else false
      end
  )
  insert into public.checkins (senior_id, status, schedule_id, scheduled_for, occurred_at, alert_state)
  select o.senior_id, 'no_response', o.schedule_id, o.scheduled_for,
         o.scheduled_for + interval '1 hour', 'pending'
  from occ o
  where o.scheduled_for + interval '1 hour' <= p_now
    and o.scheduled_for + interval '1 hour' > greatest(p_since, p_now - interval '12 hours')
    and o.scheduled_for > o.effective_from
    and not exists (
      select 1 from public.checkins x
      where x.senior_id = o.senior_id
        and x.status in ('ok', 'need_help')
        and x.occurred_at between o.scheduled_for - interval '2 hours'
                              and o.scheduled_for + interval '4 hours'
    )
  on conflict (schedule_id, scheduled_for) where status = 'no_response' do nothing;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- Sends the alerts for one pending check-in and records the outcome.
create function public.send_checkin_alerts(p_checkin_id uuid, p_now timestamptz)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  cfg public.alert_settings;
  c record;
  k record;
  v_msg record;
  v_tz text;
  v_told uuid[];
  v_followup boolean;
  v_messages integer := 0;
  v_for_contact boolean;
  v_notified uuid[] := '{}';
  v_key text;
begin
  select * into cfg from public.alert_settings where id;
  select ch.id, ch.senior_id, ch.status, ch.occurred_at, ch.scheduled_for, ch.message,
         sr.first_name, sr.timezone, sc.label
  into c
  from public.checkins ch
  join public.seniors sr on sr.id = ch.senior_id
  left join public.schedules sc on sc.id = ch.schedule_id
  where ch.id = p_checkin_id;

  v_tz := coalesce(public.valid_timezone(c.timezone), 'America/Toronto');

  -- An "I'm OK" that answers a missed check-in people were told about.
  if c.status = 'ok' then
    select coalesce(array_agg(distinct t), '{}') into v_told
    from public.checkins m, unnest(m.notified_contacts) t
    where m.senior_id = c.senior_id and m.status = 'no_response'
      and m.alert_state in ('sent', 'failed')
      and m.occurred_at <= c.occurred_at
      and m.scheduled_for between c.occurred_at - interval '4 hours' and c.occurred_at + interval '2 hours';
  end if;
  v_told := coalesce(v_told, '{}');
  v_followup := cardinality(v_told) > 0;

  select * into v_msg from public.alert_message(
    c.status, c.first_name, v_tz, c.occurred_at, c.scheduled_for, c.label, c.message, v_followup
  );

  for k in
    select * from public.contacts
    where senior_id = c.senior_id
      and (c.status <> 'ok' or notify_on_checkin or id = any (v_told))
    order by name
  loop
    v_for_contact := false;
    v_key := 'alert/' || c.id || '/' || k.id;
    if cfg.email_live and k.email is not null then
      v_for_contact := public.send_alert_message(
        c.id, k.id, 'email', k.email,
        public.email_request(k.email, v_msg.subject, v_msg.body), v_key || '/email', p_now
      ) or v_for_contact;
    end if;
    -- Texts: help and missed alerts, and the follow-up to people told about a miss.
    if (c.status <> 'ok' or k.id = any (v_told))
       and cfg.sms_live and cfg.sms_from is not null
       and k.phone is not null and k.sms_consent_at is not null then
      v_for_contact := public.send_alert_message(
        c.id, k.id, 'sms', k.phone, public.sms_request(k.phone, v_msg.sms), v_key || '/sms', p_now
      ) or v_for_contact;
    end if;
    if v_for_contact then
      v_messages := v_messages + 1;
      v_notified := v_notified || k.id;
    end if;
  end loop;

  update public.checkins
  set alert_state = case
        when v_messages > 0 then 'sent'
        when c.status = 'ok' then 'not_needed'
        else 'no_contacts'
      end,
      alerted_at = case when v_messages > 0 then p_now end,
      notified_contacts = v_notified
  where id = c.id;
  return v_messages > 0;
end;
$$;

create function public.process_alerts(p_now timestamptz default now())
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  cfg public.alert_settings;
  v_id uuid;
  v_missed integer := 0;
  v_alerted integer := 0;
  v_errors integer := 0;
begin
  -- One run at a time.
  if not pg_try_advisory_xact_lock(hashtext('public.process_alerts')) then
    return jsonb_build_object('skipped', true);
  end if;

  select * into cfg from public.alert_settings where id;
  if not (cfg.email_live or cfg.sms_live) or cfg.live_since is null then
    return jsonb_build_object('live', false);
  end if;

  perform public.reconcile_alert_deliveries(p_now);
  v_missed := public.record_missed_checkins(p_now, cfg.live_since);

  -- Nothing from before alerts were switched on, and nothing so stale that an
  -- alert would only confuse (the job must have been stopped).
  update public.checkins set alert_state = 'not_needed'
  where alert_state = 'pending' and occurred_at < cfg.live_since;
  update public.checkins set alert_state = 'failed'
  where alert_state = 'pending' and occurred_at < p_now - interval '12 hours';

  for v_id in
    select ch.id from public.checkins ch
    where ch.alert_state = 'pending'
    order by ch.occurred_at
    limit 50
    for update skip locked
  loop
    -- One check-in's problem mustn't hold up everyone else's alerts. A failed
    -- attempt sends nothing (its sends are rolled back) and is tried again
    -- next minute.
    begin
      if public.send_checkin_alerts(v_id, p_now) then
        v_alerted := v_alerted + 1;
      end if;
    exception when others then
      v_errors := v_errors + 1;
      raise warning 'Alive & Well: alert for check-in % failed: %', v_id, sqlerrm;
    end;
  end loop;

  return jsonb_build_object('missed', v_missed, 'alerted', v_alerted, 'errors', v_errors);
end;
$$;

-- Sends a sample alert to an address or number, to test the whole path.
-- Run from the SQL Editor: select public.send_test_alert('you@example.com', null);
create function public.send_test_alert(p_email text, p_phone text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tag text := to_char(clock_timestamp(), 'YYYYMMDDHH24MISSUS');
begin
  if p_email is not null then
    perform public.send_alert_message(
      null, null, 'email', p_email,
      public.email_request(
        p_email,
        'Test alert from Alive & Well',
        E'This is a test of Alive & Well alerts. If you can read this, alert emails reach you.\n\n'
          || 'Alive & Well is not a medical alert service. In an emergency, call 911.'
      ),
      'test/' || v_tag || '/email'
    );
  end if;
  if p_phone is not null then
    perform public.send_alert_message(
      null, null, 'sms', p_phone,
      public.sms_request(p_phone, 'Alive & Well: this is a test alert. If you got it, alert texts reach you.'),
      'test/' || v_tag || '/sms'
    );
  end if;
  return jsonb_build_object('sent', true, 'see', 'select * from public.alert_problems();');
end;
$$;

-- For checking on the system from the SQL Editor: recent messages that
-- didn't go through, and recent runs of the job that errored.
create function public.alert_problems()
returns table (at timestamptz, what text, detail text)
language plpgsql
security definer
set search_path = ''
as $$
begin
  return query
  select d.created_at, d.channel || ' to ' || d.destination || ': ' || d.status,
         coalesce(d.http_status::text || ' ', '') || coalesce(d.error, '')
  from public.alert_deliveries d
  where d.status in ('failed', 'skipped', 'retry') and d.created_at > now() - interval '7 days';

  if to_regclass('cron.job_run_details') is not null then
    return query execute
      'select r.start_time, ''job run failed''::text, r.return_message
       from cron.job_run_details r
       join cron.job j on j.jobid = r.jobid
       where j.jobname = ''alive-and-well-alerts'' and r.status = ''failed''
         and r.start_time > now() - interval ''7 days''';
  end if;
end;
$$;

-- Only alert_status() is for the app; everything else is for the job and the
-- SQL Editor.
revoke execute on function public.alert_status() from public, anon;
grant execute on function public.alert_status() to authenticated;
revoke execute on function public.alert_message(text, text, text, timestamptz, timestamptz, text, text, boolean) from public, anon, authenticated;
revoke execute on function public.bird_post(text, jsonb, text) from public, anon, authenticated;
revoke execute on function public.email_request(text, text, text) from public, anon, authenticated;
revoke execute on function public.sms_request(text, text) from public, anon, authenticated;
revoke execute on function public.send_alert_message(uuid, uuid, text, text, jsonb, text, timestamptz) from public, anon, authenticated;
revoke execute on function public.reconcile_alert_deliveries(timestamptz) from public, anon, authenticated;
revoke execute on function public.record_missed_checkins(timestamptz, timestamptz) from public, anon, authenticated;
revoke execute on function public.send_checkin_alerts(uuid, timestamptz) from public, anon, authenticated;
revoke execute on function public.process_alerts(timestamptz) from public, anon, authenticated;
revoke execute on function public.send_test_alert(text, text) from public, anon, authenticated;
revoke execute on function public.alert_problems() from public, anon, authenticated;
revoke all on public.alert_settings from anon, authenticated;
revoke insert, update, delete on public.alert_deliveries from anon, authenticated;
