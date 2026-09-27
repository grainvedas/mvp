-- GrainVeda MVP · Phase 0 · migration 10: who may write app_users (PRD §4 permissions; closes a hole in migration 5)
-- Migration 5's users_update policy has no WITH CHECK and no column limits: a Client Manager could set their own role to
-- admin, or point any user row of their client at any login (auth_uid). Migration 9 links logins by phone/email, which
-- makes the identity columns security-critical. Rules for every signed-in caller (the service role, seeds and the login
-- linker run without a JWT and are not affected):
--   1. auth_uid is written only by login linking (migration 9) or the service role, never by a signed-in user.
--   2. Nobody changes their own role, client, states or active flag.
--   3. Except an admin, a caller edits only rows ranked below them, before and after the edit:
--      admin > state_manager > client_manager > client_view = operator (the ladder users_insert already applies).

create or replace function app.role_rank(r public.user_role) returns int
language sql immutable as $$
  select case r when 'admin' then 4 when 'state_manager' then 3 when 'client_manager' then 2 else 1 end
$$;

create or replace function app.app_users_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare me uuid; my_role public.user_role;
begin
  if auth.uid() is null then return new; end if;
  me := app.current_user_id();
  my_role := app.current_role();

  if tg_op = 'INSERT' then
    if new.auth_uid is not null then
      raise exception 'auth_uid is set by login linking, not by hand' using errcode = '42501'; end if;
    return new;
  end if;

  if new.auth_uid is distinct from old.auth_uid then
    raise exception 'auth_uid is set by login linking, not by hand' using errcode = '42501'; end if;
  if old.id = me then
    if new.role <> old.role or new.client_id is distinct from old.client_id
       or new.state_ids <> old.state_ids or new.active <> old.active then
      raise exception 'you cannot change your own role, client, states or active flag' using errcode = '42501'; end if;
    return new;
  end if;
  if my_role is distinct from 'admin'
     and (my_role is null
          or app.role_rank(old.role) >= app.role_rank(my_role)
          or app.role_rank(new.role) >= app.role_rank(my_role)) then
    raise exception 'a % may only manage users ranked below them (% → %)',
      coalesce(my_role::text, 'user without a role'), old.role, new.role using errcode = '42501';
  end if;
  return new;
end $$;

create trigger app_users_guard before insert or update on public.app_users
  for each row execute function app.app_users_guard();
