-- Phase 3: alerts.
--
-- process_alerts() runs every minute (pg_cron, set up by
-- supabase/setup/turn_on_alerts.sql). Each run:
--   1. records how earlier sends went (pg_net responses from Bird),
--   2. records a no_response check-in for every scheduled check-in that is
--      an hour overdue with no "I'm OK" or "I need help" around it,
--   3. emails and texts contacts about every check-in still pending.
-- Help requests and missed check-ins go to every contact; routine "I'm OK"
-- check-ins are emailed only to contacts with notify_on_checkin on. Texts go
-- only to contacts with sms_consent_at set, and only once texting is on.
--
-- Sends go to Bird's API through pg_net, using the API key stored in Supabase
-- Vault as 'bird_api_key'. Nothing here runs until alert_settings says so.

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
  -- pg_net request id; its response lands in net._http_response.
  request_id bigint,
  status text not null default 'queued' check (status in ('queued', 'accepted', 'failed')),
  http_status integer,
  error text,
  created_at timestamptz not null default now()
);
create index alert_deliveries_checkin_idx on public.alert_deliveries (checkin_id);
create index alert_deliveries_queued_idx on public.alert_deliveries (request_id) where status = 'queued';
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

-- Subject, plain text and SMS text for one check-in.
create function public.alert_message(
  p_status text,
  p_name text,
  p_tz text,
  p_occurred_at timestamptz,
  p_scheduled_for timestamptz,
  p_label text,
  p_note text
)
returns table (subject text, body text, sms text)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_at text;
  v_due text;
  v_label text := coalesce(nullif(btrim(p_label), ''), 'check-in');
  v_footer text := E'\n\nThis message was sent automatically by Alive & Well. '
    || 'Alive & Well is not a medical alert service. In an emergency, call 911.';
begin
  if p_status = 'need_help' then
    v_at := public.alert_time(p_occurred_at, p_tz);
    subject := p_name || ' asked for help';
    body := p_name || ' pressed "I need help" in Alive & Well at ' || v_at || ' on '
      || public.alert_day(p_occurred_at, p_tz) || '.'
      || case when nullif(btrim(p_note), '') is not null
           then E'\n\n' || p_name || ' wrote: "' || btrim(p_note) || '"' else '' end
      || E'\n\nPlease call or visit ' || p_name || ' now. If you think it is an emergency, call 911.'
      || v_footer;
    -- v_at ends in "a.m." or "p.m.", which also ends the sentence.
    sms := 'Alive & Well: ' || p_name || ' pressed "I need help" at ' || v_at
      || ' Please call or visit now. Emergency? Call 911.';
  elsif p_status = 'no_response' then
    v_due := public.alert_time(coalesce(p_scheduled_for, p_occurred_at), p_tz);
    subject := p_name || ' hasn''t checked in';
    body := p_name || ' hasn''t checked in for their ' || v_label || ', which was due at ' || v_due
      || ' today (' || public.alert_day(coalesce(p_scheduled_for, p_occurred_at), p_tz) || ').'
      || E'\n\nPlease call or visit ' || p_name || ' to make sure they''re all right. '
      || 'If you can''t reach them and you''re worried, call 911.'
      || v_footer;
    sms := 'Alive & Well: ' || p_name || ' hasn''t checked in for their ' || v_label
      || ' (due ' || v_due || '). Please call or visit to check on them. Emergency? Call 911.';
  else
    v_at := public.alert_time(p_occurred_at, p_tz);
    subject := p_name || ' checked in: I''m OK';
    body := p_name || ' checked in at ' || v_at || ' on ' || public.alert_day(p_occurred_at, p_tz)
      || ' and said "I''m OK".'
      || case when nullif(btrim(p_note), '') is not null
           then E'\n\n' || p_name || ' wrote: "' || btrim(p_note) || '"' else '' end
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

create function public.bird_send_email(
  p_to text, p_subject text, p_body text, p_idempotency_key text
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  cfg public.alert_settings;
begin
  select * into cfg from public.alert_settings where id;
  return public.bird_post(
    '/v1/email/messages',
    jsonb_build_object(
      'from', jsonb_build_object('email', cfg.email_from_address, 'name', cfg.email_from_name),
      'to', jsonb_build_array(p_to),
      'subject', p_subject,
      'text', p_body,
      'html', '<div style="font-family:Arial,sans-serif;font-size:18px;line-height:1.5;color:#111">'
        || replace(public.html_escape(p_body), E'\n', '<br>') || '</div>',
      'category', 'transactional',
      'track_opens', false,
      'track_clicks', false
    ),
    p_idempotency_key
  );
end;
$$;

create function public.bird_send_sms(p_to text, p_text text, p_idempotency_key text)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  cfg public.alert_settings;
begin
  select * into cfg from public.alert_settings where id;
  if cfg.sms_from is null then
    raise exception 'No texting number is set in alert_settings.sms_from';
  end if;
  return public.bird_post(
    '/v1/sms/messages',
    jsonb_build_object(
      'to', p_to,
      'from', cfg.sms_from,
      'text', p_text,
      'category', 'transactional',
      'validity_period', 3600,
      'options', jsonb_build_object('smart_encoding', true)
    ),
    p_idempotency_key
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- The job
-- ---------------------------------------------------------------------------

-- Copies Bird's answers (from pg_net) onto the delivery log, and marks a
-- check-in's alert failed when none of its messages were accepted.
create function public.reconcile_alert_deliveries()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.alert_deliveries d
  set status = case when r.status_code between 200 and 299 then 'accepted' else 'failed' end,
      http_status = r.status_code,
      error = case
        when r.status_code between 200 and 299 then null
        else left(coalesce(r.error_msg, r.content::text, 'No response'), 500)
      end
  from net._http_response r
  where r.id = d.request_id and d.status = 'queued';

  update public.checkins c
  set alert_state = 'failed'
  where c.alert_state = 'sent'
    and exists (select 1 from public.alert_deliveries d where d.checkin_id = c.id)
    and not exists (
      select 1 from public.alert_deliveries d
      where d.checkin_id = c.id and d.status in ('queued', 'accepted')
    );
end;
$$;

-- Records a no_response check-in for each scheduled time that is an hour
-- overdue with no response from two hours before it to four hours after
-- (the same window the app uses). Looks at today and yesterday in the
-- senior's time zone, never before p_since or before the schedule existed.
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
    select s.id as schedule_id, s.senior_id, s.created_at,
           (dd.d + s.time_of_day) at time zone sr.timezone as scheduled_for
    from public.schedules s
    join public.seniors sr on sr.id = s.senior_id
    cross join lateral (
      select (p_now at time zone sr.timezone)::date - g as d from generate_series(0, 1) g
    ) dd
    where s.is_active
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
    and o.scheduled_for > o.created_at
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

create function public.process_alerts(p_now timestamptz default now())
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  cfg public.alert_settings;
  c record;
  k record;
  v_msg record;
  v_missed integer := 0;
  v_alerted integer := 0;
  v_messages integer;
  v_for_contact boolean;
  v_notified uuid[];
  v_req bigint;
begin
  -- One run at a time.
  if not pg_try_advisory_xact_lock(hashtext('public.process_alerts')) then
    return jsonb_build_object('skipped', true);
  end if;

  select * into cfg from public.alert_settings where id;
  if not (cfg.email_live or cfg.sms_live) or cfg.live_since is null then
    return jsonb_build_object('live', false);
  end if;

  perform public.reconcile_alert_deliveries();
  v_missed := public.record_missed_checkins(p_now, cfg.live_since);

  -- Nothing from before alerts were switched on, and nothing so stale that an
  -- alert would only confuse (the job must have been stopped).
  update public.checkins set alert_state = 'not_needed'
  where alert_state = 'pending' and occurred_at < cfg.live_since;
  update public.checkins set alert_state = 'failed'
  where alert_state = 'pending' and occurred_at < p_now - interval '12 hours';

  for c in
    select ch.id, ch.senior_id, ch.status, ch.occurred_at, ch.scheduled_for, ch.message,
           sr.first_name, sr.timezone, sc.label
    from public.checkins ch
    join public.seniors sr on sr.id = ch.senior_id
    left join public.schedules sc on sc.id = ch.schedule_id
    where ch.alert_state = 'pending'
    order by ch.occurred_at
    limit 50
    for update of ch skip locked
  loop
    select * into v_msg from public.alert_message(
      c.status, c.first_name, c.timezone, c.occurred_at, c.scheduled_for, c.label, c.message
    );
    v_messages := 0;
    v_notified := '{}';

    for k in
      select * from public.contacts
      where senior_id = c.senior_id and (c.status <> 'ok' or notify_on_checkin)
      order by name
    loop
      v_for_contact := false;
      if cfg.email_live and k.email is not null then
        v_req := public.bird_send_email(k.email, v_msg.subject, v_msg.body,
                                        'alert/' || c.id || '/' || k.id || '/email');
        insert into public.alert_deliveries (checkin_id, contact_id, channel, destination, request_id)
        values (c.id, k.id, 'email', k.email, v_req);
        v_for_contact := true;
      end if;
      if c.status <> 'ok' and cfg.sms_live and cfg.sms_from is not null
         and k.phone is not null and k.sms_consent_at is not null then
        v_req := public.bird_send_sms(k.phone, v_msg.sms, 'alert/' || c.id || '/' || k.id || '/sms');
        insert into public.alert_deliveries (checkin_id, contact_id, channel, destination, request_id)
        values (c.id, k.id, 'sms', k.phone, v_req);
        v_for_contact := true;
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
    if v_messages > 0 then v_alerted := v_alerted + 1; end if;
  end loop;

  return jsonb_build_object('missed', v_missed, 'alerted', v_alerted);
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
  v_tag text := to_char(now(), 'YYYYMMDDHH24MISS');
  v_email bigint;
  v_sms bigint;
begin
  if p_email is not null then
    v_email := public.bird_send_email(
      p_email,
      'Test alert from Alive & Well',
      E'This is a test of Alive & Well alerts. If you can read this, alert emails reach you.\n\n'
        || 'Alive & Well is not a medical alert service. In an emergency, call 911.',
      'test/' || v_tag || '/email'
    );
    insert into public.alert_deliveries (channel, destination, request_id)
    values ('email', p_email, v_email);
  end if;
  if p_phone is not null then
    v_sms := public.bird_send_sms(
      p_phone,
      'Alive & Well: this is a test alert. If you got it, alert texts reach you.',
      'test/' || v_tag || '/sms'
    );
    insert into public.alert_deliveries (channel, destination, request_id)
    values ('sms', p_phone, v_sms);
  end if;
  return jsonb_build_object('email_request', v_email, 'sms_request', v_sms);
end;
$$;

-- Only alert_status() is for the app; everything else is for the job and the
-- SQL Editor.
revoke execute on function public.alert_status() from public, anon;
grant execute on function public.alert_status() to authenticated;
revoke execute on function public.alert_message(text, text, text, timestamptz, timestamptz, text, text) from public, anon, authenticated;
revoke execute on function public.bird_post(text, jsonb, text) from public, anon, authenticated;
revoke execute on function public.bird_send_email(text, text, text, text) from public, anon, authenticated;
revoke execute on function public.bird_send_sms(text, text, text) from public, anon, authenticated;
revoke execute on function public.reconcile_alert_deliveries() from public, anon, authenticated;
revoke execute on function public.record_missed_checkins(timestamptz, timestamptz) from public, anon, authenticated;
revoke execute on function public.process_alerts(timestamptz) from public, anon, authenticated;
revoke execute on function public.send_test_alert(text, text) from public, anon, authenticated;
revoke all on public.alert_settings from anon, authenticated;
revoke insert, update, delete on public.alert_deliveries from anon, authenticated;
