-- What kind of help the senior asked for. After "I need help", the app shows
-- a short list; the choice is stored on the check-in and named in the alert
-- ("Daddy asked for help: I need a doctor"). Keep the list in step with
-- HELP_TYPES in src/lib/help.ts.

alter table public.checkins add column help_type text
  check (help_type in ('doctor', 'supplies', 'transport', 'personal_care', 'other'));
alter table public.checkins add constraint checkins_help_type_only_for_help
  check (help_type is null or status = 'need_help');

-- The words shown to the family. 'other' and null name nothing in particular.
create function public.help_label(p_help_type text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_help_type
    when 'doctor' then 'I need a doctor'
    when 'supplies' then 'I need food or medicine'
    when 'transport' then 'I need transport'
    when 'personal_care' then 'I need personal care'
  end
$$;

-- Replaced by the version below, which also takes the help type.
drop function public.alert_message(text, text, text, timestamptz, timestamptz, text, text, boolean);

create or replace function public.alert_message(
  p_status text,
  p_name text,
  p_tz text,
  p_occurred_at timestamptz,
  p_scheduled_for timestamptz,
  p_label text,
  p_note text,
  p_followup boolean default false,
  p_help_type text default null
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
  v_help text := public.help_label(p_help_type);
  v_footer text := E'\n\nThis message was sent automatically by Alive & Well. '
    || 'Alive & Well is not a medical alert service. In an emergency, call 911.';
begin
  -- alert_time() ends in "a.m."/"p.m.", which also ends a sentence, so no
  -- period is added after it.
  if p_status = 'need_help' then
    subject := p_name || ' asked for help' || coalesce(': ' || v_help, '');
    body := p_name || ' pressed "I need help" in Alive & Well at ' || v_at || ' on ' || v_day
      || coalesce(' and chose "' || v_help || '"', '') || '.'
      || v_note
      || E'\n\nPlease call or visit ' || p_name || ' now. If you think it is an emergency, call 911.'
      || v_footer;
    sms := 'Alive & Well: ' || p_name
      || case when v_help is null then ' pressed "I need help"'
              else ' asked for help ("' || v_help || '")' end
      || ' at ' || v_at || ' Please call or visit now. Emergency? Call 911.';
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

create or replace function public.send_checkin_alerts(p_checkin_id uuid, p_now timestamptz)
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
  select ch.id, ch.senior_id, ch.status, ch.occurred_at, ch.scheduled_for, ch.message, ch.help_type,
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
    c.status, c.first_name, v_tz, c.occurred_at, c.scheduled_for, c.label, c.message, v_followup,
    c.help_type
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

revoke execute on function public.alert_message(text, text, text, timestamptz, timestamptz, text, text, boolean, text) from public, anon, authenticated;
revoke execute on function public.send_checkin_alerts(uuid, timestamptz) from public, anon, authenticated;
