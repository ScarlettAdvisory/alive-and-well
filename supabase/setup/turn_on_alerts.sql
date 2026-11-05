-- Turns on alert emails. Run once in the Supabase SQL Editor, after the
-- migration 20261105000000_alerts.sql.
--
-- Before running: replace PASTE_YOUR_BIRD_API_KEY_HERE below with an API key
-- from the Bird dashboard (Platform tools > API keys) that can send email and
-- SMS. It starts with bk_. The key is stored encrypted in Supabase Vault.
--
-- Safe to run again (for example with a new key).

create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron with schema pg_catalog;

do $$
declare
  v_key text := 'PASTE_YOUR_BIRD_API_KEY_HERE';
  v_id uuid;
begin
  if v_key !~ '^b[km]_' then
    raise exception 'Paste your Bird API key (it starts with bk_) in place of PASTE_YOUR_BIRD_API_KEY_HERE first.';
  end if;
  select id into v_id from vault.secrets where name = 'bird_api_key';
  if v_id is null then
    perform vault.create_secret(v_key, 'bird_api_key', 'Bird API key for Alive & Well alerts');
  else
    perform vault.update_secret(v_id, v_key);
  end if;
end $$;

update public.alert_settings
set email_live = true,
    live_since = coalesce(live_since, now()),
    updated_at = now();

-- Every minute. Re-running replaces the existing job of the same name.
select cron.schedule('alive-and-well-alerts', '* * * * *', 'select public.process_alerts()');

select public.alert_status() as alerts_now_on;

-- ---------------------------------------------------------------------------
-- Later, when the texting number is approved in Bird, run (with the number):
--
--   update public.alert_settings set sms_from = '+12265550100', sms_live = true, updated_at = now();
--
-- To send yourself a test (email, and optionally a mobile number):
--
--   select public.send_test_alert('you@example.com', '+16135550123');
--
-- To see how recent sends went (accepted, or failed with Bird's reason):
--
--   select public.reconcile_alert_deliveries();
--   select created_at, channel, destination, status, http_status, error
--   from public.alert_deliveries order by created_at desc limit 20;
--
-- To switch alerts off:
--
--   update public.alert_settings set email_live = false, sms_live = false;
--   select cron.unschedule('alive-and-well-alerts');
