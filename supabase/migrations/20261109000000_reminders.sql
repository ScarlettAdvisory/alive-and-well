-- Check-in reminders: a phone notification to the senior at each check-in
-- time, and a second one 30 minutes later if they still haven't checked in.
-- Tapping it opens the check-in screen with "I'm OK" and "I need help".
--
-- The app registers each phone's Expo push token with register_push_device().
-- send_checkin_reminders() runs inside the every-minute alert job and sends
-- through Expo's push service (https://exp.host) with pg_net. Only phones
-- signed in by someone whose role in the circle is 'senior' get reminders.

-- ---------------------------------------------------------------------------
-- Phones
-- ---------------------------------------------------------------------------

create table public.push_devices (
  token text primary key check (token ~ '^Expo(nent)?PushToken\[.+\]$'),
  user_id uuid not null references auth.users (id) on delete cascade,
  senior_id uuid not null references public.seniors (id) on delete cascade,
  platform text check (platform in ('ios', 'android')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index push_devices_senior_idx on public.push_devices (senior_id);
alter table public.push_devices enable row level security;
-- No direct access: the app uses the two functions below.
revoke all on public.push_devices from anon, authenticated;

-- Records (or moves) this phone's token to the signed-in person and senior.
create function public.register_push_device(p_senior_id uuid, p_token text, p_platform text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'Not signed in' using errcode = '42501';
  end if;
  if not public.is_circle_member(p_senior_id) then
    raise exception 'Not in this circle' using errcode = '42501';
  end if;
  insert into public.push_devices (token, user_id, senior_id, platform)
  values (p_token, auth.uid(), p_senior_id, p_platform)
  on conflict (token) do update
    set user_id = excluded.user_id, senior_id = excluded.senior_id,
        platform = excluded.platform, updated_at = now();
end;
$$;

-- Forgets this phone when its user signs out.
create function public.forget_push_device(p_token text)
returns void
language sql
security definer
set search_path = ''
as $$ delete from public.push_devices where token = p_token and user_id = auth.uid() $$;

revoke execute on function public.register_push_device(uuid, text, text) from public, anon;
grant execute on function public.register_push_device(uuid, text, text) to authenticated;
revoke execute on function public.forget_push_device(text) from public, anon;
grant execute on function public.forget_push_device(text) to authenticated;

-- ---------------------------------------------------------------------------
-- Reminders sent
-- ---------------------------------------------------------------------------

alter table public.alert_settings add column reminders_live boolean not null default true;

create table public.checkin_reminders (
  schedule_id uuid not null references public.schedules (id) on delete cascade,
  scheduled_for timestamptz not null,
  -- due: at the check-in time; nudge: 30 minutes later if still not checked in.
  kind text not null check (kind in ('due', 'nudge')),
  -- Tokens in the order they were sent, to match Expo's answers.
  tokens text[] not null,
  request_id bigint,
  status text not null default 'queued' check (status in ('queued', 'sent', 'failed')),
  error text,
  created_at timestamptz not null default now(),
  primary key (schedule_id, scheduled_for, kind)
);
alter table public.checkin_reminders enable row level security;
create policy "Circle reads reminders" on public.checkin_reminders
  for select to authenticated
  using (exists (
    select 1 from public.schedules s where s.id = schedule_id and public.is_circle_member(s.senior_id)
  ));
revoke insert, update, delete on public.checkin_reminders from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Sending
-- ---------------------------------------------------------------------------

-- Reads Expo's answers: a reminder is 'sent' if any phone accepted it, and
-- phones Expo says are no longer registered (app deleted) are forgotten.
create function public.reconcile_checkin_reminders()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_json jsonb;
  v_ok boolean;
  i integer;
begin
  for r in
    select cr.schedule_id, cr.scheduled_for, cr.kind, cr.tokens, h.status_code, h.content, h.error_msg
    from public.checkin_reminders cr
    join net._http_response h on h.id = cr.request_id
    where cr.status = 'queued'
  loop
    v_ok := false;
    begin
      v_json := r.content::jsonb;
    exception when others then
      v_json := null;
    end;
    if r.status_code between 200 and 299 and jsonb_typeof(v_json -> 'data') = 'array' then
      for i in 0 .. jsonb_array_length(v_json -> 'data') - 1 loop
        if v_json -> 'data' -> i ->> 'status' = 'ok' then
          v_ok := true;
        elsif v_json -> 'data' -> i -> 'details' ->> 'error' = 'DeviceNotRegistered' then
          delete from public.push_devices where token = r.tokens[i + 1];
        end if;
      end loop;
    end if;
    update public.checkin_reminders
    set status = case when v_ok then 'sent' else 'failed' end,
        error = case when v_ok then null
                     else left(coalesce(r.error_msg, r.content::text, 'No response'), 500) end
    where schedule_id = r.schedule_id and scheduled_for = r.scheduled_for and kind = r.kind;
  end loop;
end;
$$;

-- Sends the reminders that are due now. A reminder goes out within 10
-- minutes of its time (later than that it would only confuse), only if the
-- senior hasn't already checked in from 2 hours before the time until now,
-- and only once.
create function public.send_checkin_reminders(p_now timestamptz default now())
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  cfg public.alert_settings;
  o record;
  v_tokens text[];
  v_messages jsonb;
  v_title text;
  v_body text;
  v_tell_family boolean;
  v_count integer := 0;
begin
  select * into cfg from public.alert_settings where id;
  if not cfg.reminders_live then
    return 0;
  end if;

  perform public.reconcile_checkin_reminders();

  for o in
    with occ as (
      select s.id as schedule_id, s.senior_id, s.label, sr.first_name, t.tz,
             (dd.d + s.time_of_day) at time zone t.tz as scheduled_for, s.effective_from
      from public.schedules s
      join public.seniors sr on sr.id = s.senior_id
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
    ),
    due as (
      select occ.*, k.kind, k.offset_min
      from occ
      cross join (values ('due', 0), ('nudge', 30)) k (kind, offset_min)
      where occ.scheduled_for + make_interval(mins => k.offset_min) <= p_now
        and occ.scheduled_for + make_interval(mins => k.offset_min + 10) > p_now
        and occ.scheduled_for > occ.effective_from
    )
    select due.* from due
    where not exists (
        select 1 from public.checkins x
        where x.senior_id = due.senior_id and x.status in ('ok', 'need_help')
          and x.occurred_at between due.scheduled_for - interval '2 hours' and p_now
      )
      and not exists (
        select 1 from public.checkin_reminders cr
        where cr.schedule_id = due.schedule_id and cr.scheduled_for = due.scheduled_for
          and cr.kind = due.kind
      )
  loop
    select coalesce(array_agg(d.token order by d.token), '{}') into v_tokens
    from public.push_devices d
    join public.circle_members m on m.senior_id = d.senior_id and m.user_id = d.user_id
    where d.senior_id = o.senior_id and m.role = 'senior';
    if cardinality(v_tokens) = 0 then
      continue;
    end if;

    if o.kind = 'due' then
      v_title := 'Time to check in, ' || o.first_name;
      v_body := 'Tap here to let your family know you''re OK, or to ask for help.';
    else
      v_tell_family := (cfg.email_live or cfg.sms_live) and exists (
        select 1 from public.contacts k
        where k.senior_id = o.senior_id
          and ((cfg.email_live and k.email is not null)
            or (cfg.sms_live and cfg.sms_from is not null and k.phone is not null and k.sms_consent_at is not null))
      );
      v_title := o.first_name || ', please check in';
      -- alert_time() ends in "a.m."/"p.m.", which also ends the sentence.
      v_body := case when v_tell_family
        then 'Tap here to check in. If you haven''t checked in by '
             || public.alert_time(o.scheduled_for + interval '1 hour', o.tz) || ' your family will be told.'
        else 'Tap here to check in.' end;
    end if;

    select jsonb_agg(jsonb_build_object(
      'to', tok,
      'title', v_title,
      'body', v_body,
      'sound', 'default',
      'priority', 'high',
      'channelId', 'checkins',
      'ttl', 1800,
      'data', jsonb_build_object('url', '/', 'kind', o.kind, 'scheduled_for', o.scheduled_for)
    ) order by tok)
    into v_messages
    from unnest(v_tokens) tok;

    insert into public.checkin_reminders (schedule_id, scheduled_for, kind, tokens, request_id, created_at)
    values (
      o.schedule_id, o.scheduled_for, o.kind, v_tokens,
      net.http_post(
        url := 'https://exp.host/--/api/v2/push/send',
        body := v_messages,
        headers := jsonb_build_object('Content-Type', 'application/json', 'Accept', 'application/json'),
        timeout_milliseconds := 15000
      ),
      p_now
    );
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

revoke execute on function public.reconcile_checkin_reminders() from public, anon, authenticated;
revoke execute on function public.send_checkin_reminders(timestamptz) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Run reminders from the every-minute job (before the alerts-on check, so
-- reminders work even while alert emails and texts are off).
-- ---------------------------------------------------------------------------

create or replace function public.process_alerts(p_now timestamptz default now())
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
  v_reminders integer := 0;
begin
  -- One run at a time.
  if not pg_try_advisory_xact_lock(hashtext('public.process_alerts')) then
    return jsonb_build_object('skipped', true);
  end if;

  -- A reminder problem mustn't stop alerts.
  begin
    v_reminders := public.send_checkin_reminders(p_now);
  exception when others then
    raise warning 'Alive & Well: reminders failed: %', sqlerrm;
  end;

  select * into cfg from public.alert_settings where id;
  if not (cfg.email_live or cfg.sms_live) or cfg.live_since is null then
    return jsonb_build_object('live', false, 'reminders', v_reminders);
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

  return jsonb_build_object('missed', v_missed, 'alerted', v_alerted, 'errors', v_errors,
                            'reminders', v_reminders);
end;
$$;
revoke execute on function public.process_alerts(timestamptz) from public, anon, authenticated;
