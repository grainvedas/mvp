-- GrainVeda MVP · Phase 0 · migration 9: link a login to its app_users row (execution plan, workstream D; PRD §4)
-- A login (auth.users row) is linked to the app_users row whose phone or email matches, as soon as that phone or email
-- is CONFIRMED (OTP verified, or created confirmed by an admin). Nobody hand-maps UUIDs.
--   * Only a confirmed channel counts: an unconfirmed sign-up can never claim a row.
--   * Exactly one active, unlinked row must match; otherwise nothing is linked and a WARNING is logged.
--   * One login links to at most one row, and a row linked to a login that still exists is never re-linked.
--   * "Unlinked" = auth_uid null, the seed placeholder (auth_uid = id), or a login that has since been deleted.
--   * Linking never blocks sign-in: an unexpected error becomes a WARNING and the user signs in with no role.
-- Phone and email become unique across app_users, compared normalised (digits only; trimmed lower case), because
-- Supabase Auth stores phones without the '+' and the seed stores them with it.

create or replace function app.phone_key(p text) returns text
language sql immutable as $$ select nullif(regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g'), '') $$;

create or replace function app.email_key(p text) returns text
language sql immutable as $$ select nullif(lower(btrim(coalesce(p, ''))), '') $$;

create unique index app_users_phone_key on public.app_users (app.phone_key(phone));
create unique index app_users_email_key on public.app_users (app.email_key(email));

create or replace function app.link_login() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_phone text; v_email text; v_rows uuid[];
begin
  begin
    v_phone := case when new.phone_confirmed_at is not null then app.phone_key(new.phone) end;
    v_email := case when new.email_confirmed_at is not null then app.email_key(new.email) end;
    if v_phone is null and v_email is null then return null; end if;
    if exists (select 1 from public.app_users where auth_uid = new.id) then return null; end if;   -- one login, one row

    select array_agg(u.id) into v_rows
      from public.app_users u
     where u.active
       and ((v_phone is not null and app.phone_key(u.phone) = v_phone)
         or (v_email is not null and app.email_key(u.email) = v_email))
       and (u.auth_uid is null or u.auth_uid = u.id
            or not exists (select 1 from auth.users a where a.id = u.auth_uid));

    if cardinality(v_rows) = 1 then
      -- re-checked under the row lock, so two logins confirming at once cannot both take the row
      update public.app_users u set auth_uid = new.id
       where u.id = v_rows[1]
         and (u.auth_uid is null or u.auth_uid = u.id
              or not exists (select 1 from auth.users a where a.id = u.auth_uid));
    elsif cardinality(v_rows) > 1 then
      raise warning 'login % matches % app users by phone/email; not linked', new.id, cardinality(v_rows);
    end if;
  exception when others then
    raise warning 'login linking failed for %: %', new.id, sqlerrm;
  end;
  return null;
end $$;

create trigger grainveda_link_login
  after insert or update of phone, email, phone_confirmed_at, email_confirmed_at on auth.users
  for each row execute function app.link_login();
