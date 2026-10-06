-- GrainVeda MVP · seed 06: identity-layer demo (migrations 31–33). Idempotent.
--   316 HR Admin (the one seat)        317 HR resource
--   318 an active employee with no assignment yet  ("a manager will assign you soon")
--   319 a joiner five days before joining, checklist stamped (HR pipeline, new-hire screens)
--   407 a scope of the SAME client in ANOTHER state (Assam): the client lens reaches it, the UP state lens does not
-- The people of seeds 02, 04 and 05 were written the old way (role, client, states); the database turned them into
-- assignments when they were inserted (migration 31, app.app_users_adopt_legacy).

-- Never on production: this file creates demo people, farmers and scopes (migration 23 marks the production project).
do $$ begin
  if to_regprocedure('app.environment()') is not null then
    if app.environment() = 'production' then
      raise exception 'demo seed refused: this is the PRODUCTION project (use supabase/seeds/production/)';
    end if;
  end if;
end $$;

-- Dates are counted from app.today() (Asia/Kolkata), the day the checklist and the countdown use: not the server clock's date.
insert into public.app_users (id, auth_uid, display_name, email, system_role, status, join_date) values
  ('00000000-0000-4000-8000-000000000316', '00000000-0000-4000-8000-000000000316', 'Asha (HR Admin)',  'grainvedas+hradmin@gmail.com', 'hr_admin',    'active', app.today() - 400),
  ('00000000-0000-4000-8000-000000000317', '00000000-0000-4000-8000-000000000317', 'Imran (HR)',       'grainvedas+hr@gmail.com',      'hr_resource', 'active', app.today() - 200),
  ('00000000-0000-4000-8000-000000000318', '00000000-0000-4000-8000-000000000318', 'Ravi Kumar',       'grainvedas+ravi@gmail.com',    'operational', 'active', app.today() - 20),
  ('00000000-0000-4000-8000-000000000319', '00000000-0000-4000-8000-000000000319', 'Meera Joshi',      'grainvedas+meera@gmail.com',   'operational', 'onboarding', app.today() + 5)
on conflict (id) do nothing;

insert into public.employee_org (employee_id, employment_type, designation_band, department, job_title, reports_to, buddy) values
  ('00000000-0000-4000-8000-000000000316', 'full_time', 'Manager',   'People',     'HR Admin',           '00000000-0000-4000-8000-000000000301', null),
  ('00000000-0000-4000-8000-000000000317', 'full_time', 'Executive', 'People',     'HR Executive',       '00000000-0000-4000-8000-000000000316', null),
  ('00000000-0000-4000-8000-000000000318', 'contract',  'Associate', 'Operations', 'Field Associate',    '00000000-0000-4000-8000-000000000303', null),
  ('00000000-0000-4000-8000-000000000319', 'full_time', 'Associate', 'Operations', 'Quality Associate',  '00000000-0000-4000-8000-000000000303', '00000000-0000-4000-8000-000000000306'),
  ('00000000-0000-4000-8000-000000000302', 'full_time', 'Senior Manager', 'Operations', 'State Lead, Uttar Pradesh', '00000000-0000-4000-8000-000000000301', null),
  ('00000000-0000-4000-8000-000000000303', 'full_time', 'Manager',   'Operations', 'Client Lead, Prasaadam', '00000000-0000-4000-8000-000000000302', null),
  ('00000000-0000-4000-8000-000000000305', 'full_time', 'Associate', 'Operations', 'Procurement Associate', '00000000-0000-4000-8000-000000000303', null),
  ('00000000-0000-4000-8000-000000000306', 'full_time', 'Executive', 'Quality',    'QC Technician',      '00000000-0000-4000-8000-000000000303', null)
on conflict (employee_id) do nothing;

insert into public.employee_docs (employee_id) values
  ('00000000-0000-4000-8000-000000000318'), ('00000000-0000-4000-8000-000000000319')
on conflict (employee_id) do nothing;

-- Meera's checklist, from the standard template (a full-time joiner: all eight tasks). The first is done.
do $$
begin
  if not exists (select 1 from public.onboarding_tasks where employee_id = '00000000-0000-4000-8000-000000000319') then
    perform app.stamp_tasks('00000000-0000-4000-8000-000000000319', '00000000-0000-4000-8000-000000000901', app.today() + 5, 'full_time');
    update public.onboarding_tasks set status = 'done', done_at = now() - interval '1 day', done_by = '00000000-0000-4000-8000-000000000319'
     where employee_id = '00000000-0000-4000-8000-000000000319' and code = 'offer_nda';
  end if;
end $$;

-- The same client in another state. Draft: nothing has flowed there yet.
insert into public.scopes (id, client_id, crop_id, state_id, season_code, geography, chain, status) values
  ('00000000-0000-4000-8000-000000000407', '00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000102',
   '00000000-0000-4000-8000-000000000002', 'KH26', 'Nagaon', '{procurement,qc,qr_activation}', 'draft')
on conflict (id) do nothing;
