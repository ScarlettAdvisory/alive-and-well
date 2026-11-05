-- Minimal stand-in for the parts of Supabase the migrations rely on, so they
-- can be tested against a plain Postgres. Not used in production.

create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;

create schema auth;
grant usage on schema auth to anon, authenticated, service_role;

create table auth.users (
  id uuid primary key default gen_random_uuid(),
  email text,
  phone text
);

-- Same claim lookups Supabase's own auth.uid() and auth.role() use.
create function auth.uid() returns uuid language sql stable as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid
$$;

create function auth.role() returns text language sql stable as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')
  )::text
$$;

grant usage on schema public to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;

-- pg_net: requests are logged instead of sent; tests write responses into
-- net._http_response themselves.
create schema net;
create table net.requests (
  id bigint generated always as identity primary key,
  url text, body jsonb, headers jsonb
);
create table net._http_response (
  id bigint primary key,
  status_code integer,
  content_type text,
  headers jsonb,
  content text,
  timed_out boolean,
  error_msg text,
  created timestamptz default now()
);
create function net.http_post(
  url text, body jsonb default '{}', params jsonb default '{}',
  headers jsonb default '{}', timeout_milliseconds integer default 5000
) returns bigint language sql as $$
  insert into net.requests (url, body, headers) values (url, body, headers) returning id
$$;

-- Supabase Vault
create schema vault;
create table vault.decrypted_secrets (name text primary key, decrypted_secret text);
