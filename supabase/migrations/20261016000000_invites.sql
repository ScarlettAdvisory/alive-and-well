-- Invite codes let a second person join a senior's circle from their own
-- phone: whoever set the senior up creates a code, the other person types it
-- in after signing in. Also lets circle members see each other's names.

create table public.circle_invites (
  -- 8 characters from an alphabet without look-alikes (no 0/O, 1/I/L).
  code text primary key check (code ~ '^[A-HJ-KM-NP-Z2-9]{8}$'),
  senior_id uuid not null references public.seniors (id) on delete cascade,
  role text not null check (role in ('senior', 'family')),
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '7 days',
  used_by uuid references auth.users (id) on delete set null,
  used_at timestamptz
);
create index circle_invites_senior_id_idx on public.circle_invites (senior_id);

alter table public.circle_invites enable row level security;

-- Codes are created and redeemed through the functions below.
create policy "Circle reads invites" on public.circle_invites
  for select to authenticated using (public.is_circle_member(senior_id));
create policy "Circle cancels invites" on public.circle_invites
  for delete to authenticated using (public.is_circle_member(senior_id));

create function public.create_invite(p_senior_id uuid, p_role text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  v_code text;
begin
  if not public.is_circle_member(p_senior_id) then
    raise exception 'Not in this circle' using errcode = '42501';
  end if;
  if p_role not in ('senior', 'family') then
    raise exception 'Unknown role %', p_role using errcode = '22023';
  end if;
  loop
    select string_agg(substr(v_alphabet, 1 + floor(random() * length(v_alphabet))::int, 1), '')
      into v_code from generate_series(1, 8);
    begin
      insert into public.circle_invites (code, senior_id, role, created_by)
      values (v_code, p_senior_id, p_role, auth.uid());
      return v_code;
    exception when unique_violation then
      -- Astronomically rare; try another code.
    end;
  end loop;
end;
$$;

-- Joins the caller to the invite's circle and returns the senior's id.
-- Codes work once and expire after a week.
create function public.accept_invite(p_code text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_invite public.circle_invites;
begin
  if v_user is null then
    raise exception 'Not signed in' using errcode = '42501';
  end if;

  select * into v_invite from public.circle_invites
  where code = upper(regexp_replace(p_code, '[^A-Za-z0-9]', '', 'g'))
  for update;

  if v_invite.code is null or v_invite.used_at is not null or v_invite.expires_at < now() then
    -- PT404 makes the API answer 404 (PostgREST maps PTxyz codes to HTTP xyz)
    -- rather than a 500: a mistyped code isn't a server error.
    raise exception 'That code is not valid' using errcode = 'PT404';
  end if;

  insert into public.circle_members (senior_id, user_id, role)
  values (v_invite.senior_id, v_user, v_invite.role)
  on conflict (senior_id, user_id) do nothing;

  update public.circle_invites set used_by = v_user, used_at = now()
  where code = v_invite.code;

  return v_invite.senior_id;
end;
$$;

-- Names and roles of everyone in a circle the caller belongs to.
create function public.circle_people(p_senior_id uuid)
returns table (user_id uuid, role text, display_name text, is_me boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select m.user_id, m.role, p.display_name, m.user_id = (select auth.uid())
  from public.circle_members m
  left join public.profiles p on p.id = m.user_id
  where m.senior_id = p_senior_id and public.is_circle_member(p_senior_id)
  order by m.created_at;
$$;

revoke execute on function public.create_invite(uuid, text) from public, anon;
grant execute on function public.create_invite(uuid, text) to authenticated;
revoke execute on function public.accept_invite(text) from public, anon;
grant execute on function public.accept_invite(text) to authenticated;
revoke execute on function public.circle_people(uuid) from public, anon;
grant execute on function public.circle_people(uuid) to authenticated;
