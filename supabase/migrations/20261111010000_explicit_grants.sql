-- Explicit Data API access for every table.
--
-- From October 30, 2026, Supabase no longer grants the API roles access to
-- new tables in "public" automatically. Tables made before then kept their
-- grants, but a fresh project (or a rebuilt one) would leave the app with
-- "permission denied". This states the access each table needs. Row-level
-- security still decides which rows each person sees. Safe to run on a
-- project that already has these grants.
--
-- New tables: add their grants here (or in their own migration).

grant usage on schema public to anon, authenticated, service_role;

-- Tables the app reads and writes directly (RLS policies limit rows).
grant select, update on public.profiles to authenticated;
grant select, update on public.seniors to authenticated;
grant select, delete on public.circle_members to authenticated;
grant select, insert, update, delete on public.contacts to authenticated;
grant select, insert, update, delete on public.schedules to authenticated;
grant select, insert on public.checkins to authenticated;
grant select, delete on public.circle_invites to authenticated;

-- Logs the family may read (RLS: their own circle only).
grant select on public.alert_deliveries to authenticated;
grant select on public.checkin_reminders to authenticated;

-- alert_settings and push_devices: no API access at all; only the
-- functions that use them can.
revoke all on public.alert_settings from anon, authenticated;
revoke all on public.push_devices from anon, authenticated;

-- Nothing for signed-out visitors.
revoke all on all tables in schema public from anon;

-- The server side (service role) keeps full access, as before.
grant all on all tables in schema public to service_role;
grant usage, select on all sequences in schema public to service_role;
