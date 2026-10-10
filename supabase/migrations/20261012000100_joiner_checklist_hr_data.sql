-- Migration 37 (Veda, 11 Oct 2026, brief "GrainVeda MVP — Joiner checklist and HR data improvements"; her answers: as
-- recommended). Additive: new columns, two new tables, new and replaced functions, one storage policy. No row, file or
-- ledger block is deleted or rewritten by it; the open checklists of people still joining get one step added
-- (Personal details) and the steps after Identity move one place down to make room for it.
--
--  A1  PAN, Aadhaar, UAN and bank account checked for duplicates WITHOUT the numbers: the number goes from the phone to
--      the Edge Function `id-numbers` only, which validates it, computes an HMAC-SHA256 with a key held only in the
--      function's secrets and hands this database the HMAC and the last 4 (app.record_id_number, service key only). PAN,
--      Aadhaar and UAN: a second person with the same HMAC is refused (unique indexes). Bank: saved, HR warned and may
--      accept with a reason. The database never receives a full number, so it cannot write one anywhere.
--  A2  Card images: only a masked Aadhaar is uploaded; HR confirms "masked: yes / no"; "no" deletes the image (storage
--      policy below) and asks the joiner again; the file's record stays. "PAN card seen" by HR instead of a file.
--  A3  A "Personal details" step (date of birth, father's or spouse's name, addresses, emergency contact).
--  A4  Phone required at Add joiner.
--  B1  No step is overdue on the day it is made: due = the later of (join date + offset) and (date added + 3 days).
--  B2  An optional "depends on" per template task; a hire's step is locked only by the steps it depends on.
--  B4  my_onboarding says the joiner's system role; B5 the joiner's contacts (reports-to and the HR Admin);
--  B6  first-day details per joiner, with template defaults.

-- 1 · schema ----------------------------------------------------------------------------------------------------------------
alter table public.employee_docs
  add column if not exists pan_hmac text check (pan_hmac ~ '^[0-9a-f]{64}$'),
  add column if not exists aadhaar_hmac text check (aadhaar_hmac ~ '^[0-9a-f]{64}$'),
  add column if not exists uan_hmac text check (uan_hmac ~ '^[0-9a-f]{64}$'),
  add column if not exists bank_hmac text check (bank_hmac ~ '^[0-9a-f]{64}$'),
  add column if not exists id_key text check (id_key ~ '^[a-z0-9_-]{1,20}$'),
  add column if not exists pan_card_seen_by uuid references public.app_users(id),
  add column if not exists pan_card_seen_at timestamptz;
comment on column public.employee_docs.pan_hmac is 'HMAC-SHA256 of the normalised PAN (key: ID_HMAC_KEY in the id-numbers function, never in the database). Null with pan_last4 set: entered before migration 37, not checked for duplicates.';
create unique index if not exists employee_docs_pan_hmac_key on public.employee_docs (pan_hmac) where pan_hmac is not null;
create unique index if not exists employee_docs_aadhaar_hmac_key on public.employee_docs (aadhaar_hmac) where aadhaar_hmac is not null;
create unique index if not exists employee_docs_uan_hmac_key on public.employee_docs (uan_hmac) where uan_hmac is not null;
create index if not exists employee_docs_bank_hmac on public.employee_docs (bank_hmac) where bank_hmac is not null;

-- What HR sees of a number that matched another person's: who, which kind, the last 4; never the number or the HMAC.
create table if not exists public.id_number_matches (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.app_users(id) on delete cascade,
  kind text not null check (kind in ('pan', 'aadhaar', 'uan', 'bank')),
  matched_employee uuid not null references public.app_users(id) on delete cascade,
  outcome text not null check (outcome in ('refused', 'warned')),
  last4 text check (last4 ~ '^[0-9A-Z]{4}$'),
  created_at timestamptz not null default now(),
  accepted_at timestamptz, accepted_by uuid references public.app_users(id), accept_reason text
);
create index if not exists id_number_matches_employee on public.id_number_matches (employee_id, created_at);
alter table public.id_number_matches enable row level security;
grant select on public.id_number_matches to authenticated;
create policy id_number_matches_read on public.id_number_matches for select to authenticated using (app.acts_as_hr());

-- card images: masked Aadhaar only from now on; HR's "masked: yes / no"; a removed image keeps its record
alter table public.employee_files drop constraint if exists employee_files_kind_check;
alter table public.employee_files add constraint employee_files_kind_check
  check (kind = any (array['offer_letter', 'nda', 'pan', 'aadhaar', 'aadhaar_masked', 'bank_proof', 'contract', 'pf_form', 'form16', 'other']));
alter table public.employee_files
  add column if not exists masked text check (masked in ('yes', 'no')),
  add column if not exists masked_by uuid references public.app_users(id),
  add column if not exists masked_at timestamptz,
  add column if not exists removed_at timestamptz,
  add column if not exists removed_by uuid references public.app_users(id);

-- the Personal details step, dependencies, the offset kept for recomputing due dates
alter table public.template_tasks drop constraint if exists template_tasks_kind_check;
alter table public.template_tasks add constraint template_tasks_kind_check
  check (kind = any (array['sign', 'identity', 'personal', 'bank', 'countersign', 'nomination', 'it', 'buddy', 'goals', 'other']));
alter table public.template_tasks add column if not exists depends_on text[] not null default '{}';
alter table public.onboarding_tasks
  add column if not exists depends_on text[] not null default '{}',
  add column if not exists due_offset_days integer;

-- first-day details: per joiner, with template defaults; which template a joiner was made from
alter table public.onboarding_templates
  add column if not exists first_day_time text, add column if not exists first_day_place text,
  add column if not exists first_day_ask_for text, add column if not exists first_day_bring text;
alter table public.employee_org
  add column if not exists template_id uuid references public.onboarding_templates(id),
  add column if not exists first_day_date date, add column if not exists first_day_time text,
  add column if not exists first_day_place text, add column if not exists first_day_ask_for text,
  add column if not exists first_day_bring text;

create table if not exists public.employee_personal (
  employee_id uuid primary key references public.app_users(id) on delete cascade,
  date_of_birth date,
  relative_kind text check (relative_kind in ('father', 'spouse')),
  relative_name text,
  present_address text,
  permanent_address text,
  emergency_name text,
  emergency_relation text,
  emergency_phone text,
  updated_by uuid references public.app_users(id),
  updated_at timestamptz not null default now()
);
alter table public.employee_personal enable row level security;
grant select on public.employee_personal to authenticated;
create policy employee_personal_read on public.employee_personal for select to authenticated
  using ((employee_id = app.current_user_id()) or app.acts_as_hr());


-- 2 · due dates with a grace period (B1) and dependencies copied from the template (B2)

CREATE OR REPLACE FUNCTION app.stamp_tasks(p_employee uuid, p_template uuid, p_join date, p_type employment_type)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare n int;
begin
  -- Statutory tasks (PF, gratuity) are for full-time employees only: interns, contractors and consultants skip them.
  -- B1: never overdue on the day it is made: the later of (join date + offset) and (today + 3 days of grace)
  insert into public.onboarding_tasks (employee_id, seq, code, title, owner, due_on, statutory, kind, depends_on, due_offset_days)
  select p_employee, t.seq, t.code, t.title, t.owner, greatest(p_join + t.due_offset_days, app.today() + 3), t.statutory, t.kind,
         t.depends_on, t.due_offset_days
    from public.template_tasks t
   where t.template_id = p_template and not (t.statutory and p_type <> 'full_time')
   order by t.seq;
  get diagnostics n = row_count;
  return n;
end $function$;

-- 3 · Add joiner: phone required (A4); the template it was made from is kept (B6 defaults)

CREATE OR REPLACE FUNCTION app.add_joiner(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise(); my_role public.system_role; v_role public.system_role;
        v_name text := btrim(coalesce(p->>'full_name', '')); v_email text := app.email_key(p->>'personal_email');
        v_phone text; v_join date; v_type public.employment_type; v_tpl uuid; v_id uuid; n int;
begin
  select system_role into my_role from public.app_users where id = me and status = 'active';
  if my_role is null or my_role not in ('admin', 'hr_admin', 'hr_resource') then
    raise exception 'only HR adds a joiner' using errcode = '42501'; end if;
  v_role := coalesce(nullif(p->>'system_role', ''), 'operational')::public.system_role;
  -- An admin is never made in the app: the database owner runs the break-glass script (docs/OPERATIONS.md).
  if v_role = 'admin' then
    raise exception 'not allowed here: an admin is made only by the database owner (break-glass script)' using errcode = '42501'; end if;
  -- The admin adds one kind of person: the one for the HR Admin seat, and only while that seat is empty.
  if my_role = 'admin' and app.hr_seat_filled() then
    raise exception 'only HR adds joiners now: the HR Admin seat is filled' using errcode = '42501'; end if;
  if my_role = 'admin' and v_role not in ('hr_resource', 'hr_admin') then
    raise exception 'only HR adds joiners: the admin adds only the person for the HR Admin seat (system role HR)' using errcode = '42501'; end if;
  -- the HR Admin seat is the admin's to give
  if v_role = 'hr_admin' and my_role <> 'admin' then
    raise exception 'only the admin gives the % seat', v_role using errcode = '42501'; end if;
  if v_role = 'hr_admin' and exists (select 1 from public.app_users where system_role = 'hr_admin' and status <> 'offboarded') then
    raise exception 'the HR Admin seat is taken: there is exactly one' using errcode = '23514'; end if;

  if v_name = '' then raise exception 'full name is required' using errcode = '23514'; end if;
  if v_email is null or v_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then
    raise exception 'a valid personal email is required: it is the sign-in' using errcode = '23514'; end if;
  -- A4 (11 Oct 2026): phone is required; it is the field staff's main identifier
  if coalesce(btrim(p->>'phone'), '') = '' then raise exception 'phone is required' using errcode = '23514'; end if;
  v_phone := app.normalise_in_mobile(p->>'phone');
  if v_phone is null then raise exception 'phone must be a 10-digit Indian mobile number' using errcode = '23514'; end if;
  begin v_join := (p->>'join_date')::date; exception when others then v_join := null; end;
  if v_join is null then raise exception 'join date is required' using errcode = '23514'; end if;
  v_type := coalesce(nullif(p->>'employment_type', ''), 'full_time')::public.employment_type;
  v_tpl := coalesce(nullif(p->>'template_id', '')::uuid, (select id from public.onboarding_templates where is_default and active));
  if v_tpl is null or not exists (select 1 from public.onboarding_templates where id = v_tpl and active) then
    raise exception 'no onboarding template: make one under HR → Templates' using errcode = '23514'; end if;

  begin
    insert into public.app_users (display_name, email, phone, status, system_role, join_date, created_by)
    values (v_name, v_email, v_phone, 'invited', v_role, v_join, me) returning id into v_id;
  exception when unique_violation then
    raise exception 'a person with this email or phone already exists' using errcode = '23505';
  end;
  insert into public.employee_org (employee_id, employment_type, designation_band, department, job_title, reports_to, buddy, updated_by, template_id)
  values (v_id, v_type, nullif(btrim(p->>'designation_band'), ''), nullif(btrim(p->>'department'), ''), nullif(btrim(p->>'job_title'), ''),
          nullif(p->>'reports_to', '')::uuid, nullif(p->>'buddy', '')::uuid, me, v_tpl);
  insert into public.employee_docs (employee_id) values (v_id);
  n := app.stamp_tasks(v_id, v_tpl, v_join, v_type);

  perform app.audit('identity_created', v_id, jsonb_build_object('name', v_name, 'system_role', v_role, 'employment_type', v_type,
                                                                 'join_date', v_join, 'tasks', n));
  if v_role = 'hr_resource' then
    -- an HR resource making another HR resource is allowed, and always flagged for the admin to see
    perform app.audit('hr_resource_created', v_id, jsonb_build_object('name', v_name, 'by_role', my_role), my_role = 'hr_resource');
  end if;
  return jsonb_build_object('id', v_id, 'tasks', n, 'status', 'invited');
end $function$;

-- 4 · HR edits a joiner: the first day (B6); due dates recomputed with the grace period (B1)

CREATE OR REPLACE FUNCTION app.update_joiner(p_employee uuid, p jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise(); u public.app_users; v_join date; delta int;
begin
  select * into u from public.app_users where id = p_employee and not external;
  if u.id is null then raise exception 'person not found' using errcode = 'P0002'; end if;
  if not ((app.is_admin() or app.is_hr()) and app.hr_may_manage(u.system_role)) then
    raise exception 'only HR edits a person''s record' using errcode = '42501'; end if;
  insert into public.employee_org (employee_id, updated_by) values (u.id, me) on conflict (employee_id) do nothing;
  update public.employee_org set
    employment_type  = coalesce(nullif(p->>'employment_type', '')::public.employment_type, employment_type),
    designation_band = case when p ? 'designation_band' then nullif(btrim(p->>'designation_band'), '') else designation_band end,
    department       = case when p ? 'department' then nullif(btrim(p->>'department'), '') else department end,
    job_title        = case when p ? 'job_title' then nullif(btrim(p->>'job_title'), '') else job_title end,
    reports_to       = case when p ? 'reports_to' then nullif(p->>'reports_to', '')::uuid else reports_to end,
    buddy            = case when p ? 'buddy' then nullif(p->>'buddy', '')::uuid else buddy end,
    -- B6: the first day, as HR sets it for this joiner (empty: the template's default, or the join date)
    first_day_date   = case when p ? 'first_day_date' then nullif(p->>'first_day_date', '')::date else first_day_date end,
    first_day_time   = case when p ? 'first_day_time' then nullif(left(btrim(p->>'first_day_time'), 40), '') else first_day_time end,
    first_day_place  = case when p ? 'first_day_place' then nullif(left(btrim(p->>'first_day_place'), 300), '') else first_day_place end,
    first_day_ask_for = case when p ? 'first_day_ask_for' then nullif(left(btrim(p->>'first_day_ask_for'), 120), '') else first_day_ask_for end,
    first_day_bring  = case when p ? 'first_day_bring' then nullif(left(btrim(p->>'first_day_bring'), 300), '') else first_day_bring end,
    updated_by = me, updated_at = now()
  where employee_id = u.id;
  if coalesce(p->>'join_date', '') <> '' then
    v_join := (p->>'join_date')::date;
    if u.join_date is distinct from v_join then
      delta := v_join - coalesce(u.join_date, v_join);
      update public.app_users set join_date = v_join where id = u.id;
      -- B1: a step made from a template keeps its offset: the later of (new join date + offset) and (date added + 3)
      update public.onboarding_tasks set due_on = case when due_offset_days is null then due_on + delta
                                                       else greatest(v_join + due_offset_days, created_at::date + 3) end
       where employee_id = u.id and status = 'pending';
    end if;
  end if;
end $function$;

-- 5 · documents: no full card image from now on (A2)

CREATE OR REPLACE FUNCTION app.register_hr_file(p_employee uuid, p_kind text, p_path text, p_sha256 text, p_file_name text DEFAULT NULL::text, p_task uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise(); v_id uuid;
begin
  if not (p_employee = me or ((app.is_admin() or app.is_hr()) and app.hr_may_manage((select system_role from public.app_users where id = p_employee)))) then
    raise exception 'not allowed to add a document for this person' using errcode = '42501'; end if;
  if p_path is distinct from format('%s/%s', p_employee, split_part(p_path, '/', 2)) or split_part(p_path, '/', 2) = '' then
    raise exception 'document path must be <person>/<file>' using errcode = '23514'; end if;
  -- A2 (11 Oct 2026): a full PAN or Aadhaar card image shows the whole number: only a masked Aadhaar is kept
  if p_kind in ('pan', 'aadhaar') then
    raise exception 'a photo of a full PAN or Aadhaar card is not kept: upload the masked Aadhaar (only the last 4 digits visible)' using errcode = '23514'; end if;
  if p_task is not null and not exists (select 1 from public.onboarding_tasks t where t.id = p_task and t.employee_id = p_employee) then
    raise exception 'that task belongs to someone else' using errcode = '23514'; end if;
  insert into public.employee_files (employee_id, kind, storage_path, file_name, sha256, task_id, uploaded_by)
  values (p_employee, p_kind, p_path, left(p_file_name, 200), lower(p_sha256), p_task, me) returning id into v_id;
  return v_id;
end $function$;

-- 6 · completing a step: numbers through the id-numbers function only (A1), Personal details (A3), dependencies (B2)

CREATE OR REPLACE FUNCTION app.complete_task(p_task uuid, p_data jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise(); t public.onboarding_tasks; u public.app_users; as_hr boolean; d jsonb := coalesce(p_data, '{}'::jsonb);
        g jsonb; n_open int;
begin
  select * into t from public.onboarding_tasks where id = p_task;
  if t.id is null then raise exception 'task not found' using errcode = 'P0002'; end if;
  select * into u from public.app_users where id = t.employee_id;
  as_hr := (app.is_admin() or app.is_hr()) and app.hr_may_manage(u.system_role) and u.id <> me;
  if not (as_hr or (t.employee_id = me and t.owner = 'hire')) then
    raise exception 'this task is not yours to complete' using errcode = '42501'; end if;
  if u.status in ('suspended', 'offboarded') then raise exception 'this person is %', u.status using errcode = '42501'; end if;
  if t.status = 'done' then raise exception 'this task is already done' using errcode = '23514'; end if;

  -- A1 (migration 37): numbers no longer come through here at all. They go to the id-numbers function, which keeps
  -- an HMAC and the last 4 (app.record_id_number); this step only checks that it was done. An app from before sends
  -- the last 4 here: refused, with words that say what to do. Nothing of what was sent is repeated in the answer.
  if d ?| array['pan_last4', 'aadhaar_last4', 'bank_last4', 'pf_uan_last4', 'pan', 'aadhaar', 'uan', 'account', 'bank_account'] then
    raise exception 'this version of the app is out of date: reload the page and enter the number again' using errcode = '23514'; end if;
  -- B2: a hire's step opens when the steps it depends on are done (HR is not held by it)
  if not as_hr and exists (select 1 from public.onboarding_tasks x
                            where x.employee_id = t.employee_id and x.code = any (t.depends_on) and x.status = 'pending') then
    raise exception 'this step opens after: %', (select string_agg(x.title, ', ' order by x.seq) from public.onboarding_tasks x
                            where x.employee_id = t.employee_id and x.code = any (t.depends_on) and x.status = 'pending')
      using errcode = '23514'; end if;

  case t.kind
    when 'sign' then
      if not as_hr and coalesce((d->>'acknowledged')::boolean, false) is not true then
        raise exception 'tick the box to say you have read and signed' using errcode = '23514'; end if;
    when 'identity' then
      -- A1/A2: the PAN or the Aadhaar was checked by the id-numbers function; a masked Aadhaar image is optional
      if not exists (select 1 from public.employee_docs x where x.employee_id = u.id and (x.pan_hmac is not null or x.aadhaar_hmac is not null)) then
        raise exception 'enter your PAN or your Aadhaar number first' using errcode = '23514'; end if;
    when 'personal' then
      -- A3: what the statutory forms need
      begin
        if coalesce(d->>'date_of_birth', '') = '' or (d->>'date_of_birth')::date > app.today() - 14 * 365 or (d->>'date_of_birth')::date < date '1930-01-01' then
          raise exception 'give your date of birth' using errcode = '23514'; end if;
      exception when invalid_datetime_format or datetime_field_overflow then
        raise exception 'give your date of birth' using errcode = '23514';
      end;
      if coalesce(d->>'relative_kind', '') not in ('father', 'spouse') or coalesce(btrim(d->>'relative_name'), '') = '' then
        raise exception 'give your father''s or your spouse''s name' using errcode = '23514'; end if;
      if coalesce(btrim(d->>'present_address'), '') = '' or coalesce(btrim(d->>'permanent_address'), '') = '' then
        raise exception 'give your present and your permanent address' using errcode = '23514'; end if;
      if coalesce(btrim(d->>'emergency_name'), '') = '' or coalesce(btrim(d->>'emergency_relation'), '') = ''
         or app.normalise_in_mobile(d->>'emergency_phone') is null then
        raise exception 'give an emergency contact: name, relation and a 10-digit mobile number' using errcode = '23514'; end if;
      insert into public.employee_personal (employee_id, date_of_birth, relative_kind, relative_name, present_address, permanent_address,
                                            emergency_name, emergency_relation, emergency_phone, updated_by, updated_at)
      values (u.id, (d->>'date_of_birth')::date, d->>'relative_kind', left(btrim(d->>'relative_name'), 120), left(btrim(d->>'present_address'), 500),
              left(btrim(d->>'permanent_address'), 500), left(btrim(d->>'emergency_name'), 120), left(btrim(d->>'emergency_relation'), 60),
              app.normalise_in_mobile(d->>'emergency_phone'), me, now())
      on conflict (employee_id) do update set date_of_birth = excluded.date_of_birth, relative_kind = excluded.relative_kind,
             relative_name = excluded.relative_name, present_address = excluded.present_address, permanent_address = excluded.permanent_address,
             emergency_name = excluded.emergency_name, emergency_relation = excluded.emergency_relation,
             emergency_phone = excluded.emergency_phone, updated_by = me, updated_at = now();
      -- the audit line says that it happened, never what was given
      perform app.audit('personal_details_saved', u.id, jsonb_build_object('name', u.display_name));
    when 'bank' then
      if coalesce(btrim(d->>'bank_name'), '') = '' then
        raise exception 'give the name of the bank' using errcode = '23514'; end if;
      if not exists (select 1 from public.employee_docs x where x.employee_id = u.id and x.bank_hmac is not null) then
        raise exception 'enter the account number first' using errcode = '23514'; end if;
      update public.employee_docs set bank_name = left(btrim(d->>'bank_name'), 120), updated_at = now() where employee_id = u.id;
    when 'nomination' then
      if coalesce(btrim(d->>'gratuity_nominee'), '') = '' or coalesce(btrim(d->>'nominee_relation'), '') = '' then
        raise exception 'the nominee''s name and relation are required' using errcode = '23514'; end if;
      update public.employee_docs set gratuity_nominee = btrim(d->>'gratuity_nominee'), nominee_relation = btrim(d->>'nominee_relation'),
             updated_at = now() where employee_id = u.id;
    when 'buddy' then
      if coalesce(d->>'buddy', '') = '' and (select buddy from public.employee_org where employee_id = u.id) is null then
        raise exception 'choose the buddy first' using errcode = '23514'; end if;
      if coalesce(d->>'buddy', '') <> '' then
        update public.employee_org set buddy = (d->>'buddy')::uuid, updated_by = me, updated_at = now() where employee_id = u.id;
      end if;
    when 'goals' then
      for g in select * from jsonb_array_elements(coalesce(d->'goals', '[]'::jsonb)) loop
        insert into public.employee_goals (employee_id, horizon, goal, set_by) values (u.id, (g->>'horizon')::int, btrim(g->>'goal'), me);
      end loop;
      if (select count(distinct horizon) from public.employee_goals where employee_id = u.id) < 3 then
        raise exception 'set at least one goal each for 30, 60 and 90 days' using errcode = '23514'; end if;
    else null;
  end case;

  update public.onboarding_tasks set status = 'done', done_at = now(), done_by = me, note = nullif(btrim(d->>'note'), '') where id = t.id;
  select count(*) into n_open from public.onboarding_tasks where employee_id = u.id and status = 'pending';
  -- Everything done: the joiner is active without HR having to press anything.
  if n_open = 0 and u.status = 'onboarding' then
    update public.app_users set status = 'active' where id = u.id;
    perform app.audit('activated', u.id, jsonb_build_object('name', u.display_name, 'from', 'onboarding', 'how', 'checklist complete'));
  end if;
  return jsonb_build_object('ok', true, 'open', n_open, 'status', (select status from public.app_users where id = u.id));
end $function$;

-- 7 · the numbers (A1) ------------------------------------------------------------------------------------------------------
-- Which person a number is for, asked AS THE CALLER by the id-numbers function before it computes anything: the
-- joiner's own step, still open, of the kind that takes this number; or HR for a person HR manages. The number itself
-- is not sent here.
create or replace function app.id_number_target(p_task uuid, p_kind text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := app.me_or_raise(); t public.onboarding_tasks; u public.app_users; as_hr boolean;
begin
  select * into t from public.onboarding_tasks where id = p_task;
  if t.id is null then raise exception 'task not found' using errcode = 'P0002'; end if;
  select * into u from public.app_users where id = t.employee_id;
  as_hr := app.acts_as_hr() and app.hr_may_manage(u.system_role) and u.id <> me;
  if not (as_hr or (t.employee_id = me and t.owner = 'hire')) then
    raise exception 'this step is not yours' using errcode = '42501'; end if;
  if u.status in ('suspended', 'offboarded') then raise exception 'this person is %', u.status using errcode = '42501'; end if;
  if t.status <> 'pending' then raise exception 'this step is done already' using errcode = '23514'; end if;
  if not ((p_kind in ('pan', 'aadhaar') and t.kind = 'identity') or (p_kind = 'bank' and t.kind = 'bank') or (p_kind = 'uan' and t.kind = 'nomination')) then
    raise exception 'this step does not take that number' using errcode = '23514'; end if;
  return jsonb_build_object('employee_id', u.id, 'actor_id', me);
end $$;

-- What the id-numbers function stores: the HMAC and the last 4. SERVICE KEY ONLY: a person cannot call it, so nobody
-- can store an HMAC the function did not compute (and so slip past the duplicate check).
create or replace function app.record_id_number(p_task uuid, p_actor uuid, p_kind text, p_hmac text, p_last4 text,
                                                 p_key text default 'k1', p_ifsc text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t public.onboarding_tasks; u public.app_users; v_last4 text := upper(coalesce(p_last4, '')); other uuid; n int := 0;
begin
  if p_kind not in ('pan', 'aadhaar', 'uan', 'bank') then raise exception 'unknown kind of number' using errcode = '23514'; end if;
  if coalesce(p_hmac, '') !~ '^[0-9a-f]{64}$' then raise exception 'not an HMAC' using errcode = '23514'; end if;
  if v_last4 !~ '^[0-9A-Z]{4}$' then raise exception 'the last 4 characters only' using errcode = '23514'; end if;
  if p_kind = 'bank' and upper(coalesce(p_ifsc, '')) !~ '^[A-Z]{4}0[A-Z0-9]{6}$' then raise exception 'IFSC looks wrong' using errcode = '23514'; end if;
  select * into t from public.onboarding_tasks where id = p_task;
  if t.id is null then raise exception 'task not found' using errcode = 'P0002'; end if;
  select * into u from public.app_users where id = t.employee_id;
  insert into public.employee_docs (employee_id) values (u.id) on conflict (employee_id) do nothing;

  if p_kind in ('pan', 'aadhaar', 'uan') then
    execute format('select employee_id from public.employee_docs where %I = $1 and employee_id <> $2 limit 1', p_kind || '_hmac')
       into other using p_hmac, u.id;
    if other is null then
      begin
        execute format('update public.employee_docs set %I = $1, %I = $2, id_key = $3, updated_at = now() where employee_id = $4',
                       p_kind || '_hmac', case p_kind when 'uan' then 'pf_uan_last4' else p_kind || '_last4' end)
          using p_hmac, v_last4, p_key, u.id;
      exception when unique_violation then
        execute format('select employee_id from public.employee_docs where %I = $1 and employee_id <> $2 limit 1', p_kind || '_hmac')
           into other using p_hmac, u.id;
      end;
    end if;
    if other is not null then
      insert into public.id_number_matches (employee_id, kind, matched_employee, outcome, last4) values (u.id, p_kind, other, 'refused', v_last4);
      perform app.audit_as(p_actor, 'id_number_refused', u.id, jsonb_build_object('name', u.display_name, 'kind', p_kind, 'last4', v_last4,
              'matches', other, 'matches_name', (select display_name from public.app_users where id = other)), true);
      return jsonb_build_object('outcome', 'refused');
    end if;
    return jsonb_build_object('outcome', 'saved');
  end if;

  -- bank: saved; HR is warned about every other person with the same account (same bank, same number)
  update public.employee_docs set bank_hmac = p_hmac, bank_last4 = v_last4, bank_ifsc = upper(p_ifsc), id_key = p_key, updated_at = now()
   where employee_id = u.id;
  for other in select employee_id from public.employee_docs where bank_hmac = p_hmac and employee_id <> u.id loop
    insert into public.id_number_matches (employee_id, kind, matched_employee, outcome, last4) values (u.id, 'bank', other, 'warned', v_last4);
    perform app.audit_as(p_actor, 'bank_account_shared', u.id, jsonb_build_object('name', u.display_name, 'last4', v_last4,
            'matches', other, 'matches_name', (select display_name from public.app_users where id = other)), false);
    n := n + 1;
  end loop;
  return jsonb_build_object('outcome', case when n > 0 then 'warned' else 'saved' end);
end $$;

-- An audit line written for a person acting through a server function (the service key has no person of its own).
create or replace function app.audit_as(p_actor uuid, p_action text, p_target uuid, p_detail jsonb default '{}'::jsonb, p_flagged boolean default false)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.audit_log (actor, action, target, detail, flagged)
  values (p_actor, p_action, p_target, coalesce(p_detail, '{}'::jsonb), coalesce(p_flagged, false));
end $$;

-- HR accepts a bank account that is also on another person's record, with a written reason: a flagged audit line.
create or replace function app.accept_shared_bank(p_match uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := app.me_or_raise(); m public.id_number_matches;
begin
  select * into m from public.id_number_matches where id = p_match;
  if m.id is null or m.kind <> 'bank' or m.outcome <> 'warned' then raise exception 'no such bank warning' using errcode = 'P0002'; end if;
  if not (app.acts_as_hr() and app.hr_may_manage((select system_role from public.app_users where id = m.employee_id)) and m.employee_id <> me) then
    raise exception 'only HR accepts a shared bank account' using errcode = '42501'; end if;
  if m.accepted_at is not null then raise exception 'accepted already' using errcode = '23514'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  update public.id_number_matches set accepted_at = now(), accepted_by = me, accept_reason = left(app.scrub_numbers(btrim(p_reason)), 500) where id = m.id;
  perform app.audit('bank_duplicate_accepted', m.employee_id, jsonb_build_object('last4', m.last4, 'matches', m.matched_employee,
          'matches_name', (select display_name from public.app_users where id = m.matched_employee), 'reason', left(app.scrub_numbers(btrim(p_reason)), 500)), true);
end $$;

-- 8 · card images (A2) -----------------------------------------------------------------------------------------------------
-- HR, having opened the image: masked (only the last 4 digits visible) or not. Not masked: the image is to be deleted
-- (the storage policy below lets HR delete exactly such an image), and the identity step is opened again so the joiner
-- is asked for a masked one. Both acts are audit lines; the file's record stays.
create or replace function app.confirm_masked(p_file uuid, p_masked boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := app.me_or_raise(); f public.employee_files; u public.app_users; reopened int := 0;
begin
  select * into f from public.employee_files where id = p_file;
  if f.id is null then raise exception 'file not found' using errcode = 'P0002'; end if;
  select * into u from public.app_users where id = f.employee_id;
  if not (app.acts_as_hr() and app.hr_may_manage(u.system_role) and u.id <> me) then
    raise exception 'only HR checks a card image' using errcode = '42501'; end if;
  if f.removed_at is not null then raise exception 'this image was deleted already' using errcode = '23514'; end if;
  update public.employee_files set masked = case when p_masked then 'yes' else 'no' end, masked_by = me, masked_at = now() where id = f.id;
  if p_masked then
    perform app.audit('card_masked_confirmed', u.id, jsonb_build_object('name', u.display_name, 'file', f.file_name, 'kind', f.kind));
  else
    update public.onboarding_tasks set status = 'pending', done_at = null, done_by = null,
           note = 'asked again: a masked Aadhaar (only the last 4 digits visible)'
     where employee_id = u.id and kind = 'identity' and status = 'done';
    get diagnostics reopened = row_count;
    perform app.audit('card_not_masked', u.id, jsonb_build_object('name', u.display_name, 'file', f.file_name, 'kind', f.kind,
            'asked_again', reopened > 0), true);
  end if;
  return jsonb_build_object('path', f.storage_path, 'delete', not p_masked);
end $$;

-- After the image is deleted from storage: the record says so (who, when). Refused while the image is still there.
create or replace function app.note_file_removed(p_file uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := app.me_or_raise(); f public.employee_files; u public.app_users;
begin
  select * into f from public.employee_files where id = p_file;
  if f.id is null then raise exception 'file not found' using errcode = 'P0002'; end if;
  select * into u from public.app_users where id = f.employee_id;
  if not (app.acts_as_hr() and app.hr_may_manage(u.system_role) and u.id <> me) then
    raise exception 'only HR deletes a card image' using errcode = '42501'; end if;
  if f.masked is distinct from 'no' then raise exception 'only an image HR found not masked is deleted' using errcode = '23514'; end if;
  if f.removed_at is not null then return; end if;
  if exists (select 1 from storage.objects o where o.bucket_id = 'hr-docs' and o.name = f.storage_path) then
    raise exception 'the image is still in the store: delete it first' using errcode = '23514'; end if;
  update public.employee_files set removed_at = now(), removed_by = me where id = f.id;
  perform app.audit('hr_file_removed', u.id, jsonb_build_object('name', u.display_name, 'file', f.file_name, 'kind', f.kind,
          'why', 'not masked'), true);
end $$;

-- Used by the storage policy: may the caller delete this object? Only HR, only an image HR marked "not masked".
create or replace function app.may_remove_hr_file(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select app.acts_as_hr() and exists (
    select 1 from public.employee_files f join public.app_users u on u.id = f.employee_id
     where f.storage_path = p_name and f.masked = 'no' and f.removed_at is null
       and app.hr_may_manage(u.system_role) and u.id <> app.current_user_id())
$$;
-- Supabase already lets authenticated delete in storage.objects (the policies decide); the local stand-in does not.
do $g$ begin
  if not has_table_privilege('authenticated', 'storage.objects', 'DELETE') then execute 'grant delete on storage.objects to authenticated'; end if;
end $g$;
create policy hr_docs_remove_unmasked on storage.objects for delete to authenticated
  using (bucket_id = 'hr-docs' and app.may_remove_hr_file(name));

-- "PAN card seen": HR has seen the card and keeps no image of it (A2.3).
create or replace function app.record_card_seen(p_employee uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := app.me_or_raise(); u public.app_users;
begin
  select * into u from public.app_users where id = p_employee and not external;
  if u.id is null then raise exception 'person not found' using errcode = 'P0002'; end if;
  if not (app.acts_as_hr() and app.hr_may_manage(u.system_role) and u.id <> me) then
    raise exception 'only HR records a card as seen' using errcode = '42501'; end if;
  insert into public.employee_docs (employee_id) values (u.id) on conflict (employee_id) do nothing;
  update public.employee_docs set pan_card_seen_by = me, pan_card_seen_at = now(), updated_at = now() where employee_id = u.id;
  perform app.audit('pan_card_seen', u.id, jsonb_build_object('name', u.display_name));
end $$;


-- 9 · what a joiner reads: system role (B4), contacts (B5), first day (B6), personal details, checked numbers, dependencies

CREATE OR REPLACE FUNCTION app.my_onboarding()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise(); u public.app_users; o public.employee_org; d public.employee_docs; tp public.onboarding_templates;
begin
  select * into u from public.app_users where id = me;
  select * into o from public.employee_org where employee_id = me;
  select * into d from public.employee_docs where employee_id = me;
  select * into tp from public.onboarding_templates
   where id = coalesce(o.template_id, (select id from public.onboarding_templates where is_default and active limit 1));
  return jsonb_build_object(
    'status', u.status, 'name', u.display_name, 'join_date', u.join_date, 'today', app.today(), 'system_role', u.system_role,
    'days_to_join', case when u.join_date is null then null else u.join_date - app.today() end,
    'org', jsonb_build_object('job_title', o.job_title, 'department', o.department, 'designation_band', o.designation_band,
                              'employment_type', o.employment_type),
    'reports_to', (select jsonb_build_object('name', r.display_name, 'email', r.email, 'phone', r.phone) from public.app_users r where r.id = o.reports_to),
    'buddy', (select jsonb_build_object('name', b.display_name, 'email', b.email, 'phone', b.phone) from public.app_users b where b.id = o.buddy),
    -- B5: who a joiner can turn to: the HR Admin (besides the reports-to person above)
    'hr_admin', (select jsonb_build_object('name', h.display_name, 'email', h.email, 'phone', h.phone) from public.app_users h
                  where h.system_role = 'hr_admin' and h.status = 'active' and h.id <> me limit 1),
    -- B6: the first day, as HR set it for this joiner, else the template's defaults (the date: the join date)
    'first_day', jsonb_build_object(
       'date', coalesce(o.first_day_date, u.join_date),
       'time', coalesce(o.first_day_time, tp.first_day_time), 'place', coalesce(o.first_day_place, tp.first_day_place),
       'ask_for', coalesce(o.first_day_ask_for, tp.first_day_ask_for), 'bring', coalesce(o.first_day_bring, tp.first_day_bring)),
    'personal', (select jsonb_build_object('date_of_birth', x.date_of_birth, 'relative_kind', x.relative_kind, 'relative_name', x.relative_name,
                   'present_address', x.present_address, 'permanent_address', x.permanent_address, 'emergency_name', x.emergency_name,
                   'emergency_relation', x.emergency_relation, 'emergency_phone', x.emergency_phone)
                   from public.employee_personal x where x.employee_id = me),
    'checked', jsonb_build_object('pan', d.pan_hmac is not null, 'aadhaar', d.aadhaar_hmac is not null, 'uan', d.uan_hmac is not null,
                                  'bank', d.bank_hmac is not null),
    'docs', jsonb_build_object('pan_last4', d.pan_last4, 'aadhaar_last4', d.aadhaar_last4, 'bank_name', d.bank_name, 'bank_ifsc', d.bank_ifsc,
                               'bank_last4', d.bank_last4, 'pf_uan_last4', d.pf_uan_last4, 'gratuity_nominee', d.gratuity_nominee,
                               'nominee_relation', d.nominee_relation),
    'files', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'kind', f.kind, 'file_name', f.file_name, 'task_id', f.task_id, 'created_at', f.created_at,
                                        'masked', f.masked) order by f.created_at)
                                        from public.employee_files f where f.employee_id = me and f.removed_at is null), '[]'::jsonb),
    'tasks', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'seq', t.seq, 'code', t.code, 'title', t.title, 'owner', t.owner,
                         'due_on', t.due_on, 'statutory', t.statutory, 'kind', t.kind, 'status', t.status, 'done_at', t.done_at, 'note', t.note,
                         'depends_on', to_jsonb(t.depends_on))
                         order by t.seq) from public.onboarding_tasks t where t.employee_id = me), '[]'::jsonb),
    'goals', coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'horizon', g.horizon, 'goal', g.goal) order by g.horizon, g.created_at)
                         from public.employee_goals g where g.employee_id = me), '[]'::jsonb)
  );
end $function$;

-- 10 · what HR reads of a joiner: checked numbers and matches (A1), card images (A2), personal details (A3), first day (B6)

CREATE OR REPLACE FUNCTION app.joiner_detail(p_employee uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare u public.app_users; o public.employee_org; d public.employee_docs; tp public.onboarding_templates;
begin
  perform app.me_or_raise();
  select * into u from public.app_users where id = p_employee and not external;
  if u.id is null or not app.acts_as_hr() then
    raise exception 'person not found' using errcode = 'P0002'; end if;
  select * into o from public.employee_org where employee_id = u.id;
  select * into d from public.employee_docs where employee_id = u.id;
  select * into tp from public.onboarding_templates
   where id = coalesce(o.template_id, (select id from public.onboarding_templates where is_default and active limit 1));
  return jsonb_build_object(
    'person', jsonb_build_object('id', u.id, 'name', u.display_name, 'email', u.email, 'phone', u.phone, 'status', u.status,
               'system_role', u.system_role, 'join_date', u.join_date, 'created_at', u.created_at,
               'days_to_join', case when u.join_date is null then null else u.join_date - app.today() end,
               'has_login', u.auth_uid is not null and u.auth_uid <> u.id,
               'created_by', (select display_name from public.app_users where id = u.created_by)),
    'can_manage', app.hr_may_manage(u.system_role) and u.id <> app.current_user_id(),
    -- "Mark as joined", exactly as app.activate_joiner decides it
    'can_activate', u.status in ('invited', 'onboarding') and u.id <> app.current_user_id()
                    and ((app.is_admin() and u.system_role = 'hr_admin') or (app.is_hr() and app.hr_may_manage(u.system_role))),
    'org', jsonb_build_object('employment_type', o.employment_type, 'designation_band', o.designation_band, 'department', o.department,
             'job_title', o.job_title, 'reports_to', o.reports_to, 'buddy', o.buddy,
             'reports_to_name', (select display_name from public.app_users where id = o.reports_to),
             'buddy_name', (select display_name from public.app_users where id = o.buddy)),
    'docs', jsonb_build_object('pan_last4', d.pan_last4, 'aadhaar_last4', d.aadhaar_last4, 'bank_name', d.bank_name, 'bank_ifsc', d.bank_ifsc,
             'bank_last4', d.bank_last4, 'pf_uan_last4', d.pf_uan_last4, 'gratuity_nominee', d.gratuity_nominee,
             'nominee_relation', d.nominee_relation, 'form16_ref', d.form16_ref,
             'pan_card_seen_by', (select display_name from public.app_users where id = d.pan_card_seen_by), 'pan_card_seen_at', d.pan_card_seen_at),
    -- A1: per number, whether it was checked for duplicates ("not checked": entered before migration 37, last 4 only)
    'checked', jsonb_build_object(
       'pan', case when d.pan_hmac is not null then 'checked' when d.pan_last4 is not null then 'not_checked' end,
       'aadhaar', case when d.aadhaar_hmac is not null then 'checked' when d.aadhaar_last4 is not null then 'not_checked' end,
       'uan', case when d.uan_hmac is not null then 'checked' when d.pf_uan_last4 is not null then 'not_checked' end,
       'bank', case when d.bank_hmac is not null then 'checked' when d.bank_last4 is not null then 'not_checked' end),
    -- A1: numbers that matched another person's: refused (PAN, Aadhaar, UAN) or a warning to accept (bank)
    'matches', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'kind', m.kind, 'outcome', m.outcome, 'last4', m.last4,
               'matched_id', m.matched_employee, 'matched_name', (select display_name from public.app_users where id = m.matched_employee),
               'at', m.created_at, 'accepted_at', m.accepted_at, 'accept_reason', m.accept_reason,
               'accepted_by', (select display_name from public.app_users where id = m.accepted_by)) order by m.created_at desc)
               from public.id_number_matches m where m.employee_id = u.id), '[]'::jsonb),
    'personal', (select jsonb_build_object('date_of_birth', x.date_of_birth, 'relative_kind', x.relative_kind, 'relative_name', x.relative_name,
                   'present_address', x.present_address, 'permanent_address', x.permanent_address, 'emergency_name', x.emergency_name,
                   'emergency_relation', x.emergency_relation, 'emergency_phone', x.emergency_phone, 'updated_at', x.updated_at)
                   from public.employee_personal x where x.employee_id = u.id),
    'first_day', jsonb_build_object(
       'date', o.first_day_date, 'time', o.first_day_time, 'place', o.first_day_place, 'ask_for', o.first_day_ask_for, 'bring', o.first_day_bring,
       'default_date', u.join_date, 'default_time', tp.first_day_time, 'default_place', tp.first_day_place,
       'default_ask_for', tp.first_day_ask_for, 'default_bring', tp.first_day_bring),
    'files', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'kind', f.kind, 'file_name', f.file_name, 'storage_path', f.storage_path,
               'sha256', f.sha256, 'task_id', f.task_id, 'created_at', f.created_at, 'masked', f.masked, 'masked_at', f.masked_at,
               'masked_by', (select display_name from public.app_users where id = f.masked_by), 'removed_at', f.removed_at,
               'uploaded_by', (select display_name from public.app_users where id = f.uploaded_by)) order by f.created_at)
               from public.employee_files f where f.employee_id = u.id), '[]'::jsonb),
    'tasks', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'seq', t.seq, 'code', t.code, 'title', t.title, 'owner', t.owner,
               'due_on', t.due_on, 'statutory', t.statutory, 'kind', t.kind, 'status', t.status, 'done_at', t.done_at, 'note', t.note,
               'overdue', t.status = 'pending' and t.due_on < app.today(), 'depends_on', to_jsonb(t.depends_on),
               'done_by', (select display_name from public.app_users where id = t.done_by)) order by t.seq)
               from public.onboarding_tasks t where t.employee_id = u.id), '[]'::jsonb),
    'notes', coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'note', n.note, 'at', n.created_at,
               'by', (select display_name from public.app_users where id = n.written_by)) order by n.created_at desc)
               from public.employee_notes n where n.employee_id = u.id), '[]'::jsonb),
    'goals', coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'horizon', g.horizon, 'goal', g.goal) order by g.horizon, g.created_at)
               from public.employee_goals g where g.employee_id = u.id), '[]'::jsonb),
    'exits', coalesce((select jsonb_agg(jsonb_build_object('exit_date', e.exit_date, 'reason', e.reason, 'final_settlement', e.final_settlement,
               'form16_ref', e.form16_ref, 'at', e.created_at) order by e.created_at desc)
               from public.employee_exits e where e.employee_id = u.id), '[]'::jsonb),
    'assignments', (select count(*) from public.assignments a where a.employee_id = u.id and a.active)
  );
end $function$;

-- 10b · a number typed into free text (a problem report, a reason) never reaches client_errors or the audit log (A1.5)
create or replace function app.scrub_numbers(p text) returns text
language sql immutable set search_path = public as $$
  select regexp_replace(regexp_replace(p, '[A-Za-z]{5}\s*[0-9]{4}\s*[A-Za-z]', '[number removed]', 'g'),
                        '(\d[\s-]?){8,}\d', '[number removed]', 'g')
$$;
revoke execute on function app.scrub_numbers(text) from public, anon;

CREATE OR REPLACE FUNCTION app.report_client_error(p_kind text, p_message text, p_detail text DEFAULT NULL::text, p_path text DEFAULT NULL::text, p_build text DEFAULT NULL::text, p_online boolean DEFAULT NULL::boolean, p_agent text DEFAULT NULL::text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.current_user_id();
begin
  if me is null or coalesce(btrim(p_message), '') = '' then return false; end if;
  if (select count(*) from public.client_errors e where e.user_id = me and e.at > now() - interval '1 hour') >= 30 then
    return false;                                                       -- a looping screen must not fill the table
  end if;
  delete from public.client_errors where at < now() - interval '90 days';
  insert into public.client_errors (user_id, role, kind, message, detail, path, build, online, agent)
  values (me, app.current_role(),
          case when p_kind in ('error', 'rejection', 'boundary', 'sync_refused', 'report') then p_kind else 'error' end,
          left(app.scrub_numbers(p_message), 500), left(app.scrub_numbers(p_detail), 2000), left(split_part(coalesce(p_path, ''), '?', 1), 200),
          left(p_build, 40), p_online, left(p_agent, 300));
  return true;
end $function$;

-- 11 · Personal details in the Standard joining template, right after Identity; and on the open checklists of people
-- still joining (Veda, 11 Oct: "as per recommendation"). The steps after Identity move one place down; nothing else changes.
do $$
declare tpl uuid; idseq int;
begin
  select id into tpl from public.onboarding_templates where is_default and active limit 1;
  if tpl is not null and not exists (select 1 from public.template_tasks where template_id = tpl and kind = 'personal') then
    select seq into idseq from public.template_tasks where template_id = tpl and kind = 'identity' order by seq limit 1;
    idseq := coalesce(idseq, 0);
    update public.template_tasks set seq = seq + 1000 where template_id = tpl and seq > idseq;
    update public.template_tasks set seq = seq - 999 where template_id = tpl and seq > 1000;
    insert into public.template_tasks (template_id, seq, code, title, owner, due_offset_days, statutory, kind)
    values (tpl, idseq + 1, 'personal', 'Personal details', 'hire', -5, false, 'personal');
  end if;
end $$;

do $$
declare r record; idseq int;
begin
  for r in select u.id, u.join_date from public.app_users u
            where u.status in ('invited', 'onboarding') and not u.external
              and exists (select 1 from public.onboarding_tasks t where t.employee_id = u.id)
              and not exists (select 1 from public.onboarding_tasks t where t.employee_id = u.id and (t.kind = 'personal' or t.code = 'personal')) loop
    select seq into idseq from public.onboarding_tasks where employee_id = r.id and kind = 'identity' order by seq limit 1;
    idseq := coalesce(idseq, 0);
    update public.onboarding_tasks set seq = seq + 1 where employee_id = r.id and seq > idseq;
    insert into public.onboarding_tasks (employee_id, seq, code, title, owner, due_on, statutory, kind, due_offset_days)
    values (r.id, idseq + 1, 'personal', 'Personal details', 'hire', greatest(coalesce(r.join_date, app.today()) - 5, app.today() + 3), false, 'personal', -5);
  end loop;
end $$;

-- 12 · who may call what ------------------------------------------------------------------------------------------------------
revoke execute on function app.id_number_target(uuid, text) from public, anon;
revoke execute on function app.record_id_number(uuid, uuid, text, text, text, text, text) from public, anon, authenticated;
revoke execute on function app.audit_as(uuid, text, uuid, jsonb, boolean) from public, anon, authenticated;
revoke execute on function app.accept_shared_bank(uuid, text) from public, anon;
revoke execute on function app.confirm_masked(uuid, boolean) from public, anon;
revoke execute on function app.note_file_removed(uuid) from public, anon;
revoke execute on function app.may_remove_hr_file(text) from public, anon;
revoke execute on function app.record_card_seen(uuid) from public, anon;
grant execute on function app.id_number_target(uuid, text) to authenticated;
grant execute on function app.accept_shared_bank(uuid, text) to authenticated;
grant execute on function app.confirm_masked(uuid, boolean) to authenticated;
grant execute on function app.note_file_removed(uuid) to authenticated;
grant execute on function app.may_remove_hr_file(text) to authenticated;     -- read inside the storage policy, as the caller
grant execute on function app.record_card_seen(uuid) to authenticated;
grant execute on function app.record_id_number(uuid, uuid, text, text, text, text, text) to service_role;
grant execute on function app.audit_as(uuid, text, uuid, jsonb, boolean) to service_role;
