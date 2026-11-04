-- Account deletion from inside the app (an App Store requirement).
--
-- delete_account() removes the caller's sign-in and profile and takes them out
-- of every circle. A senior whose circle would be left empty is deleted with
-- everything about them (contacts, schedules, check-ins, invites), since no
-- one could reach that data again. Seniors still shared with someone else are
-- kept for them; the caller's name disappears from their records.

create function public.delete_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception 'Not signed in' using errcode = '42501';
  end if;

  delete from public.seniors s
  where exists (
    select 1 from public.circle_members m where m.senior_id = s.id and m.user_id = v_user
  )
  and not exists (
    select 1 from public.circle_members m where m.senior_id = s.id and m.user_id <> v_user
  );

  -- Cascades to profiles and circle_members; created_by/used_by columns
  -- elsewhere are set to null.
  delete from auth.users where id = v_user;
end;
$$;

revoke execute on function public.delete_account() from public, anon;
grant execute on function public.delete_account() to authenticated;
