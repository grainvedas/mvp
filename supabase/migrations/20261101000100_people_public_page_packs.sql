-- GrainVeda MVP · migration 57 (release 10; Veda, 16 Oct 2026: "rest all ok and proceed with 57").
--   G20  "client info should not be shared": a Client Manager no longer sees a person who works now for another client
--        (the roster's pool, People, a person's page, the count of work "elsewhere"). His own client's people and the
--        free people of his state as before. HR and the admin see everyone, as before; HR staffs across clients.
--   G21  "when consumer scan and sees the record then this line should not appear": the public page never says that one
--        person recorded and checked a step. Each step says "checked by another person" only where that is true; the
--        public data no longer carries same_person (the ledger, the State Manager's home and the Roster keep it).
--   The public page, new look: the villages by share with their farmers, each market's limits beside the lab readings,
--        a pack's scans (how many, the first place), an export's country only (nothing of a domestic dispatch's place).
--   Shipment: the codes of the packs loaded are asked for a domestic shipment too (where the order's lot has packs);
--        app.order_pack_codes lets the phone check each code as it is scanned (this batch, void, shipped already);
--        the buyer's page shows a domestic shipment's e-way bill and lorry receipt, not the vehicle number.
-- Nothing is deleted or rewritten; no row is changed except the Shipment form's definition (the pack codes' field).
select set_config('app.change_path', 'migration 57', true);

-- ---------------------------------------------------------------------------------------------------------------------
-- G20: a person who works now for a client the reader may not see
-- ---------------------------------------------------------------------------------------------------------------------
create or replace function app.busy_for_other_client(p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select not (app.is_admin() or app.is_hr()) and exists (
    select 1 from public.assignments a left join public.scopes s on s.id = a.scope_id
     where a.employee_id = p_user and a.active and (a.ends_on is null or a.ends_on >= app.today())
       and coalesce(a.client_id, s.client_id) is not null
       and (a.lens <> 'scope' or (s.status in ('draft', 'active') and cardinality(a.stages) > 0))
       and not app.can_access_client(coalesce(a.client_id, s.client_id)))
$$;

-- ---------------------------------------------------------------------------------------------------------------------
-- Shipment: the packs of an order's lot, for the phone to check each code as it is scanned
-- ---------------------------------------------------------------------------------------------------------------------
create or replace function app.order_pack_codes(p_fp uuid, p_except uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare o public.footprints;
begin
  select * into o from public.footprints where id = p_fp and stage_type = 'commercial';
  if o.id is null or app.current_user_id() is null or not app.can_see_footprint(o.scope_id, o.stage_type) then
    raise exception 'record not found' using errcode = 'P0002'; end if;
  return coalesce((
    with shipped as (
      select x as serial, min(sh.footprint_code) as code
        from public.footprints sh, jsonb_array_elements_text(coalesce(sh.payload->'serials', '[]'::jsonb)) x
       where sh.scope_id = o.scope_id and sh.stage_type = 'shipment' and sh.status not in ('superseded', 'legacy')
         and sh.id is distinct from p_except group by x)
    select jsonb_agg(jsonb_build_object('serial', pk.serial, 'sku_id', pk.sku_id, 'sku', app.sku_name(k), 'size_kg', pk.size_kg,
             'void', pk.status <> 'packed', 'shipped_in', sp.code) order by pk.serial)
      from public.packs pk left join public.pack_skus k on k.id = pk.sku_id left join shipped sp on sp.serial = pk.serial
     where pk.footprint_id = o.prev_footprint_id), '[]'::jsonb);
end $$;

-- The Shipment form: the pack codes' field for both markets, where the order's lot has packs
update public.stage_definitions d
   set form_schema = (select jsonb_agg(case when f->>'key' = 'serials'
                                            then (f - 'for_market') || '{"with_packs": true, "label": "Pack codes loaded"}'::jsonb else f end order by n)
                        from jsonb_array_elements(d.form_schema) with ordinality as x(f, n))
 where d.stage_type = 'shipment' and exists (select 1 from jsonb_array_elements(d.form_schema) f where f->>'key' = 'serials' and f ? 'for_market');

-- ---------------------------------------------------------------------------------------------------------------------
-- Patches of the current definitions (each change asserted by gen57.py)
-- ---------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.people_directory()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare full_view boolean;
begin
  perform app.me_or_raise();
  full_view := app.is_admin() or app.is_hr();
  if not (full_view or app.can_assign()) then
    raise exception 'the people directory is for HR and for those who assign' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', u.id, 'name', u.display_name, 'email', u.email, 'phone', u.phone, 'status', u.status, 'system_role', u.system_role,
             'external', u.external, 'join_date', u.join_date, 'has_login', u.auth_uid is not null and u.auth_uid <> u.id,
             'org', jsonb_build_object('employment_type', o.employment_type, 'designation_band', o.designation_band,
                      'department', o.department, 'job_title', o.job_title,
                      'reports_to_name', (select display_name from public.app_users where id = o.reports_to)),
             'assignments', coalesce((select jsonb_agg(app.assignment_json(a) order by a.lens, a.created_at)
                                        from public.assignments a where a.employee_id = u.id and a.active and app.assignment_visible(a)), '[]'::jsonb),
             'elsewhere', case when app.cm_limited() then 0 else (select count(*) from public.assignments a where a.employee_id = u.id and a.active and not app.assignment_visible(a)) end,   -- migration 57 (G20)
             'unassigned', not exists (select 1 from public.assignments a where a.employee_id = u.id and a.active))
           order by u.external, u.display_name)
      from public.app_users u left join public.employee_org o on o.employee_id = u.id
     where (not u.external and (full_view or u.status <> 'offboarded') and (full_view or not (select app.sm_limited()) or u.id in (select unnest(app.sm_seen_ids())))
            and (full_view or not (select app.cm_limited()) or u.id in (select unnest(app.cm_seen_ids()))) and not u.test_data   -- migration 44
            and (not app.is_hr() or app.hr_full() or u.id = app.current_user_id() or o.base_state_id = any(app.my_hr_states())))
        or (u.external and (app.is_admin() or app.manages_viewer(u.id)))), '[]'::jsonb);
end $function$;

CREATE OR REPLACE FUNCTION app.people_page(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise(); full_view boolean; v_kind text := coalesce(nullif(p->>'kind', ''), 'employees');
        v_q text := nullif(lower(btrim(p->>'q')), ''); v_status text := nullif(p->>'status', ''); v_state uuid := nullif(p->>'state', '')::uuid;
        v_client uuid := nullif(p->>'client', '')::uuid; v_role text := nullif(p->>'role', ''); v_open uuid := nullif(p->>'opening', '')::uuid;
        v_owner text := nullif(p->>'owner', ''); v_unass boolean := coalesce((p->>'unassigned')::boolean, false);
        v_limit int := least(greatest(coalesce((p->>'limit')::int, 50), 1), 200); v_offset int := greatest(coalesce((p->>'offset')::int, 0), 0);
        v_digits text; res jsonb; v_limited boolean := app.is_hr() and not app.hr_full(); v_mine uuid[] := app.my_hr_states();
begin
  full_view := app.is_admin() or app.is_hr();
  if not (full_view or app.can_assign()) then
    raise exception 'the people directory is for HR and for those who assign' using errcode = '42501'; end if;
  v_digits := regexp_replace(coalesce(v_q, ''), '[^0-9]', '', 'g');
  with vis as (
    select u.*, o.employment_type, o.designation_band, o.department, o.job_title, o.reports_to, o.opening_id, o.intended_role,
           o.intended_stage, o.hr_owner, o.base_state_id, o.base_district
      from public.app_users u left join public.employee_org o on o.employee_id = u.id
     where ((not u.external and (full_view or u.status <> 'offboarded')) or (u.external and (app.is_admin() or app.manages_viewer(u.id))))
       and (not v_limited or u.id = me or o.base_state_id = any(v_mine))
       and (full_view or u.external or not (select app.sm_limited()) or u.id in (select unnest(app.sm_seen_ids())))   -- migration 41
       and (full_view or u.external or not (select app.cm_limited()) or u.id in (select unnest(app.cm_seen_ids())))   -- migration 44 (A4)
       and not u.test_data                                                                                            -- migration 44 (G7)
  ), f as (
    select v.* from vis v
     where (v_kind = 'client_logins') = v.external
       and (v_q is null or lower(v.display_name) like '%' || v_q || '%' or lower(coalesce(v.email, '')) like '%' || v_q || '%'
            or (v_q ~ '^[0-9+ -]{4,}$' and coalesce(v.phone, '') like '%' || v_digits || '%')
            or lower(coalesce(v.job_title, '')) like '%' || v_q || '%')
       and (v_status is null or v.status::text = v_status)
       and (v_state is null or exists (select 1 from public.assignments a left join public.scopes s on s.id = a.scope_id left join public.clients c on c.id = a.client_id
                                        where a.employee_id = v.id and a.active and (full_view or app.assignment_visible(a)) and v_state in (a.state_id, s.state_id, c.state_id))
            or exists (select 1 from public.openings op where op.id = v.opening_id and op.state_id = v_state)
            or v.base_state_id = v_state)
       and (v_client is null or exists (select 1 from public.assignments a left join public.scopes s on s.id = a.scope_id
                                         where a.employee_id = v.id and a.active and (full_view or app.assignment_visible(a)) and v_client in (a.client_id, s.client_id)))
       and (v_role is null or v.intended_role = v_role)
       and (v_open is null or v.opening_id = v_open)
       and (v_owner is null or (v_owner = 'mine' and v.hr_owner = me) or (v_owner not in ('mine', 'none') and v.hr_owner::text = v_owner)
            or (v_owner = 'none' and v.hr_owner is null))
       and (not v_unass or not exists (select 1 from public.assignments a where a.employee_id = v.id and a.active))
  )
  select jsonb_build_object(
    'total', (select count(*) from f),
    'counts', (select jsonb_build_object('employees', count(*) filter (where not external), 'client_logins', count(*) filter (where external)) from vis),
    'rows', coalesce((select jsonb_agg(x.j order by x.external, x.display_name) from (
      select f.external, f.display_name, jsonb_build_object(
             'id', f.id, 'name', f.display_name, 'email', f.email, 'phone', f.phone, 'status', f.status, 'system_role', f.system_role,
             'external', f.external, 'join_date', f.join_date, 'has_login', f.auth_uid is not null and f.auth_uid <> f.id,
             'role', f.intended_role, 'stage', f.intended_stage,
             'opening_code', (select code from public.openings where id = f.opening_id),
             'base', jsonb_build_object('state_id', f.base_state_id, 'state_name', (select name from public.states where id = f.base_state_id),
                                        'district', f.base_district),
             'org', jsonb_build_object('employment_type', f.employment_type, 'designation_band', f.designation_band,
                      'department', f.department, 'job_title', f.job_title,
                      'reports_to_name', (select display_name from public.app_users where id = f.reports_to)),
             'assignments', coalesce((select jsonb_agg(app.assignment_json(a) order by a.lens, a.created_at)
                                        from public.assignments a where a.employee_id = f.id and a.active and app.assignment_visible(a)), '[]'::jsonb),
             'elsewhere', case when app.cm_limited() then 0 else (select count(*) from public.assignments a where a.employee_id = f.id and a.active and not app.assignment_visible(a)) end,   -- migration 57 (G20)
             'unassigned', not exists (select 1 from public.assignments a where a.employee_id = f.id and a.active),
             'assignable', app.may_offer_assign(f.id)) as j
        from f order by f.external, f.display_name limit v_limit offset v_offset) x), '[]'::jsonb),
    'limit', v_limit, 'offset', v_offset) into res;
  return res;
end $function$;

CREATE OR REPLACE FUNCTION app.employee_profile(p_employee uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise(); u public.app_users; o public.employee_org; full_view boolean; hr_ok boolean;
begin
  select * into u from public.app_users where id = p_employee;
  full_view := app.is_admin() or (app.is_hr() and (app.hr_full() or app.hr_covers(p_employee)));
  if u.id is null or not (u.id = me or (not u.external and (full_view or (app.can_assign() and u.status <> 'offboarded' and (not app.sm_limited() or app.sm_sees(u.id)) and (not app.cm_limited() or u.id = any (app.cm_seen_ids())) and not u.test_data)))
                          or (u.external and (app.is_admin() or app.manages_viewer(u.id)))) then
    raise exception 'person not found' using errcode = 'P0002'; end if;
  select * into o from public.employee_org where employee_id = u.id;
  hr_ok := app.may_manage_person(u.id);
  return jsonb_build_object(
    'identity', jsonb_build_object('id', u.id, 'name', u.display_name, 'email', u.email, 'phone', u.phone, 'status', u.status,
                  'external', u.external, 'join_date', u.join_date, 'created_at', u.created_at,
                  'has_login', u.auth_uid is not null and u.auth_uid <> u.id),
    'org', jsonb_build_object('employment_type', o.employment_type, 'designation_band', o.designation_band, 'department', o.department,
             'job_title', o.job_title, 'reports_to_name', (select display_name from public.app_users where id = o.reports_to),
             'buddy_name', (select display_name from public.app_users where id = o.buddy)),
    'system_role', u.system_role,
    'assignments', coalesce((select jsonb_agg(app.assignment_json(a) order by a.lens, a.created_at)
                               from public.assignments a where a.employee_id = u.id and a.active and app.assignment_visible(a)), '[]'::jsonb),
    'history', coalesce((select jsonb_agg(app.assignment_json(a) order by a.ended_at desc)
                           from public.assignments a where a.employee_id = u.id and not a.active and app.assignment_visible(a)), '[]'::jsonb),
    'elsewhere', case when app.cm_limited() then 0 else (select count(*) from public.assignments a where a.employee_id = u.id and a.active and not app.assignment_visible(a)) end,   -- migration 57 (G20)
    'exits', case when app.acts_as_hr() then coalesce((select jsonb_agg(jsonb_build_object('exit_date', e.exit_date, 'reason', e.reason) order by e.created_at desc)
                                                   from public.employee_exits e where e.employee_id = u.id), '[]'::jsonb) else '[]'::jsonb end,
    'can', jsonb_build_object(
      'assign', app.may_offer_assign(u.id),   -- migration 44
      'suspend', hr_ok and u.status in ('invited', 'onboarding', 'active'),
      'reinstate', hr_ok and u.status = 'suspended',
      'offboard', hr_ok and u.status <> 'offboarded',
      'rehire', hr_ok and u.status = 'offboarded' and not u.external,
      'reset_login', app.reset_login_allowed(u.id),
      'set_role', not u.external and u.id <> me and u.system_role in ('operational', 'hr_resource')
                  and (app.is_hr_admin() or (app.is_admin() and not app.hr_seat_filled())),
      'hr_record', app.acts_as_hr() and not u.external));
end $function$;

CREATE OR REPLACE FUNCTION app.cm_seen_ids()
 RETURNS uuid[]
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with m as materialized (
    select app.current_user_id() as me,
           coalesce((select array_agg(distinct a.client_id) from app.eff_assignments(app.current_user_id()) a
                      where a.lens = 'client' and a.op_role = 'client_account'), '{}') as clients),
  st as materialized (select coalesce(array_agg(distinct c.state_id), '{}') as ids from public.clients c, m where c.id = any (m.clients))
  select coalesce(array_agg(u.id), '{}') from public.app_users u, m, st
   where u.id = m.me
      or (not u.external and u.system_role = 'operational' and not u.test_data and (
            -- his client's people: anyone on his client or one of its scopes
            exists (select 1 from public.assignments a left join public.scopes sc on sc.id = a.scope_id
                     where a.employee_id = u.id and a.active and coalesce(a.client_id, sc.client_id) = any (m.clients)
                       and not exists (select 1 from public.assignments z where z.employee_id = u.id and z.active and z.lens = 'state'))
            -- the eligible pool of his state: based there, working, no State Manager seat
            or (u.status in ('invited', 'onboarding', 'active')
                and exists (select 1 from public.employee_org o where o.employee_id = u.id and o.base_state_id = any (st.ids))
                and not app.busy_for_other_client(u.id)                                        -- migration 57 (G20)
                and not exists (select 1 from public.assignments z where z.employee_id = u.id and z.active and z.lens = 'state')))) $function$;

CREATE OR REPLACE FUNCTION app.work_elsewhere(p_user uuid, p_scope uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(jsonb_agg(case when app.can_access_client(s.client_id) or app.acts_as_hr()
           then jsonb_build_object('scope_id', s.id, 'label', s.season_code || ' · ' || s.geography, 'status', s.status,
                                   'client', c.name, 'stages', to_jsonb(a.stages))
           else jsonb_build_object('other_client', true, 'status', s.status, 'stages', to_jsonb(a.stages)) end   -- migration 56
           order by s.season_code, s.geography), '[]'::jsonb)
    from public.assignments a join public.scopes s on s.id = a.scope_id join public.clients c on c.id = s.client_id
   where a.employee_id = p_user and a.active and a.lens = 'scope' and a.scope_id is distinct from p_scope
     and (a.ends_on is null or a.ends_on >= app.today()) and s.status in ('draft', 'active') and cardinality(a.stages) > 0
     and (app.current_user_id() is null or app.can_access_client(s.client_id) or app.acts_as_hr())   -- migration 57 (G20) $function$;

CREATE OR REPLACE FUNCTION app.roster_pool(p_scope uuid, p_q text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare sc public.scopes; v_q text := nullif(lower(btrim(p_q)), '');
begin
  perform app.me_or_raise();
  select * into sc from public.scopes where id = p_scope;
  if sc.id is null or not app.runs_client(sc.client_id) then
    raise exception 'the Client Manager of this scope''s client chooses its people' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', u.id, 'name', u.display_name, 'status', u.status, 'district', o.base_district,
             'me', u.id = app.current_user_id(),
             'elsewhere', app.work_elsewhere(u.id, sc.id),                                       -- migration 51 (A15)
             'ready_for', rf.stage, 'ready_opening', rf.code,      -- migration 46: joined on an opening of this scope, not placed yet
             'stages', coalesce((select to_jsonb(a.stages) from public.assignments a
                                  where a.employee_id = u.id and a.active and a.lens = 'scope' and a.scope_id = sc.id), '[]'::jsonb))
           order by rf.stage is null, jsonb_array_length(app.work_elsewhere(u.id, sc.id)) > 0, u.id <> app.current_user_id(), u.display_name)
      from (select u.* from public.app_users u left join public.employee_org o2 on o2.employee_id = u.id
             where not u.external and not u.test_data and u.system_role = 'operational' and u.status in ('invited', 'onboarding', 'active')
               and (v_q is null or lower(u.display_name) like '%' || v_q || '%')
               and (o2.base_state_id = sc.state_id or app.client_account_holder(u.id, sc.client_id))
               -- migration 57 (G20): not a person who works now for another client, unless he works for this one too
               and (not app.busy_for_other_client(u.id) or app.client_account_holder(u.id, sc.client_id)
                    or exists (select 1 from public.assignments a3 join public.scopes s3 on s3.id = a3.scope_id
                                where a3.employee_id = u.id and a3.active and s3.client_id = sc.client_id))
             order by u.display_name limit 200) u
      left join public.employee_org o on o.employee_id = u.id
      left join lateral (select op.stage, op.code from public.openings op
                          where op.id = o.opening_id and u.status = 'active' and op.status <> 'closed' and op.role = 'operator'
                            and op.state_id = sc.state_id and op.stage = any(sc.chain)
                            and (op.scope_id = sc.id or (op.scope_id is null and (op.client_id is null or op.client_id = sc.client_id)))
                            and not exists (select 1 from public.assignments a where a.employee_id = u.id and a.active and a.lens = 'scope'
                                              and a.scope_id = sc.id and op.stage = any(a.stages))) rf on true
     where app.stage_refusal(u.id, sc.id) is null), '[]'::jsonb);
end $function$;

CREATE OR REPLACE FUNCTION app.public_lot_journey(p_qr_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare seal public.qr_seals; cur public.footprints; steps jsonb := '[]'::jsonb; hops int := 0;
        v_scope public.scopes; v_crop public.crops; v_client public.clients; vd record; fm public.farmers; step jsonb;
        v_independent boolean := true; v_later_maker uuid; v_same boolean := false; v_mkt text; v_dest text;   -- v_mkt, v_dest: migration 57
begin
  select * into seal from public.qr_seals where qr_code = p_qr_code;
  if seal.footprint_id is null then return null; end if;
  select * into cur from public.footprints where id = seal.footprint_id;
  select * into v_scope from public.scopes where id = cur.scope_id;
  select * into v_crop from public.crops where id = v_scope.crop_id;
  select * into v_client from public.clients where id = v_scope.client_id;
  select * into vd from app.resolve_market_verdict(cur.id);

  while cur.id is not null and hops < 64 loop
    step := jsonb_build_object(
      'stage', cur.stage_type, 'code', cur.footprint_code, 'qty_in_kg', cur.qty_in, 'qty_out_kg', cur.qty_out,
      'verified_at', cur.verified_at, 'created_at', cur.created_at,
      'captured_at', coalesce(cur.captured_at, cur.created_at), 'grade', cur.grade);
    if cur.stage_type = 'procurement' and cur.farmer_id is not null then
      select * into fm from public.farmers where id = cur.farmer_id;
      -- migration 50 (Part D): the village and the district, never the farmer's name or photo
      step := step || jsonb_build_object('farmer', jsonb_build_object('village', fm.village, 'district', fm.district));
    end if;
    if cur.stage_type = 'lot_inward' then
      step := step || jsonb_build_object('source', jsonb_build_object('type', cur.payload->>'source_type', 'name', cur.payload->>'source_name'));
    end if;
    if cur.stage_type = 'qc' then
      step := step || jsonb_build_object('readings', (select readings from public.qc_verdicts where footprint_id = cur.id))
                   || jsonb_build_object('markets', (select coalesce(jsonb_agg(jsonb_build_object('code', pv.code, 'name', pv.name,
                        'verdict', pv.verdict, 'failed', pv.failed,
                        'limits', (select mp.params from public.market_profiles mp where mp.id = pv.profile_id))   -- migration 57
                        order by pv.created_at, pv.code), '[]'::jsonb)
                        from public.qc_profile_verdicts pv where pv.footprint_id = cur.id));                      -- migration 53
    end if;
    if cur.stage_type = 'packing' then step := step || jsonb_build_object('batch_code', cur.payload->>'batch_code'); end if;
    if cur.stage_type = 'warehouse' then step := step || jsonb_build_object('days_in_storage', app.storage_days(cur.id)); end if;   -- migration 55
    if cur.stage_type = 'village_batch' then
      step := step || jsonb_build_object('village', coalesce(cur.payload->>'village',      -- migration 52: from the lots
             app.batch_villages(cur.id)),                    -- migration 52b: the villages only, through a helper
        'farmers', coalesce((
        select jsonb_agg(jsonb_build_object('village', g.village, 'district', g.district, 'qty_kg', g.qty_kg) order by g.village, g.qty_kg)
          from (select fa.name, fa.village, fa.district, sum(src.qty_out) as qty_kg                -- migration 49: one line a farmer
                  from public.footprints src join public.farmers fa on fa.id = src.farmer_id
                 where src.id in (select (x)::uuid from jsonb_array_elements_text(cur.payload->'source_footprint_ids') x)
                 group by fa.id, fa.name, fa.village, fa.district) g), '[]'::jsonb));
    end if;
    if cur.stage_type = 'shipment' then   -- migration 57: an export's country; nothing of a domestic dispatch's place
      select coalesce(o.payload->>'market', 'domestic'), o.payload->>'destination_country' into v_mkt, v_dest      -- the order's own words
        from public.footprints o where o.id = cur.prev_footprint_id and o.stage_type = 'commercial';
      step := step || jsonb_build_object('dispatched_on', cur.payload->>'dispatch_date',
        'destination', case when v_mkt = 'export' then coalesce(v_dest, cur.payload->>'destination') end);   -- before 54: the typed place
    end if;
    -- migration 57 (G21): checked by someone other than who recorded it (the public page says so only where true)
    step := step || jsonb_build_object('checked', cur.stage_type <> 'qr_activation' and cur.verified_by is not null
              and cur.verified_by <> cur.created_by
              and not exists (select 1 from public.ledger l where l.footprint_id = cur.id and l.event = 'supervisory'));
    -- "recorded by the person who handled it and checked by the next person": true only if no step was checked by
    -- its own maker, no two steps in a row were made by one person, and no step was done as a manager's supervisory act
    if (cur.stage_type <> 'qr_activation' and cur.verified_by is not null and cur.verified_by = cur.created_by)
       or (v_later_maker is not null and v_later_maker = cur.created_by)
       or exists (select 1 from public.ledger l where l.footprint_id = cur.id and l.event = 'supervisory') then
      v_independent := false;
    end if;
    -- migration 46: the same person recorded a step and checked it, or recorded the next one (the approved words)
    if (cur.stage_type <> 'qr_activation' and cur.verified_by is not null and cur.verified_by = cur.created_by)
       or (v_later_maker is not null and v_later_maker = cur.created_by and not cur.is_grade_lot) then
      v_same := true;
    end if;
    v_later_maker := cur.created_by;
    steps := jsonb_build_array(step) || steps;     -- prepend: journey reads farm → seal
    exit when cur.prev_footprint_id is null;
    select * into cur from public.footprints where id = cur.prev_footprint_id;
    hops := hops + 1;
  end loop;

  return jsonb_build_object(
    'qr_code', seal.qr_code, 'sealed_at', seal.sealed_at, 'ledger_hash', seal.ledger_hash, 'batch_codes', to_jsonb(seal.batch_codes),
    'crop', jsonb_build_object('name', v_crop.name, 'gi_tag', v_crop.gi_tag, 'origin', v_crop.origin),
    'client', jsonb_build_object('name', v_client.name, 'type', v_client.type),
    'season', v_scope.season_code, 'geography', v_scope.geography,
    'verdict', jsonb_build_object('domestic', vd.domestic, 'export', vd.export, 'overridden', vd.override is not null),
    'journey', steps,
    'independent', v_independent,
    -- migration 57 (G21): no same_person here (the ledger keeps it); the villages by share, with their farmers
    'villages', coalesce((select jsonb_agg(jsonb_build_object('village', y.village, 'district', y.district, 'share_pct', y.pct, 'farmers', y.n)
                                  order by y.pct desc, y.village)
                 from (select fv.village, fv.district, round(sum(s.share) * 100, 1) as pct, count(distinct e.farmer_id) as n
                         from app.lot_sources(seal.footprint_id) s join public.footprints e on e.id = s.entry_id
                         join public.farmers fv on fv.id = e.farmer_id group by fv.village, fv.district) y), '[]'::jsonb),
    'farmer_count', (select count(distinct e.farmer_id) from app.lot_sources(seal.footprint_id) s join public.footprints e on e.id = s.entry_id),
    'gi_status', app.lot_gi_status(seal.footprint_id),                                                   -- migration 49
    -- migration 50: the release's status (a recall on every pack) and the packs' dates
    'release', app.release_status(seal.footprint_id) - 'by',
    'packs', (select jsonb_build_object('n', count(*), 'packed_on', min(p.packed_on), 'best_before', min(p.best_before))
                from public.packs p where p.footprint_id in (select app.lot_packings(seal.footprint_id)) and p.status = 'packed')
  );
end $function$;

CREATE OR REPLACE FUNCTION app.public_pack(p_serial text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare p public.packs; v_seal uuid; q public.qr_seals; sc public.scopes; cr public.crops; v_pack jsonb;
begin
  select * into p from public.packs where serial = p_serial;
  if p.serial is null then return null; end if;
  select * into sc from public.scopes where id = p.scope_id; select * into cr from public.crops where id = sc.crop_id;
  v_pack := jsonb_build_object('serial', p.serial, 'batch_code', p.batch_code, 'size_kg', p.size_kg, 'packed_on', p.packed_on,
              'best_before', p.best_before, 'void', p.status = 'void',
              'copy_warning', app.scan_warning(p.serial), 'seller', (select c.name from public.clients c where c.id = sc.client_id),   -- migration 56
              -- migration 57: how often this pack was scanned and the first place (a city, never a person)
              'scans', (select jsonb_build_object('n', count(*),
                          'first_city', (select f.city from public.scans f where f.code = p.serial and f.city is not null order by f.at, f.id limit 1),
                          'first_country', (select f.country from public.scans f where f.code = p.serial and f.city is not null order by f.at, f.id limit 1))
                          from public.scans x where x.code = p.serial));
  select s into v_seal from app.packing_seals(p.footprint_id) s limit 1;
  if v_seal is null or p.status = 'void' then
    return jsonb_build_object('pack', v_pack, 'released', false,
      'crop', jsonb_build_object('name', cr.name, 'gi_tag', cr.gi_tag, 'origin', cr.origin), 'season', sc.season_code, 'geography', sc.geography,
      'gi_status', app.lot_gi_status(p.footprint_id));
  end if;
  select * into q from public.qr_seals where footprint_id = v_seal;
  return app.public_lot_journey(q.qr_code) || jsonb_build_object('pack', v_pack, 'released', true);
end $function$;

CREATE OR REPLACE FUNCTION app.buyer_content(p_fp uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare f public.footprints; sale public.footprints; sc public.scopes; cr public.crops; cl public.clients;
        v_ships uuid[]; v_pack uuid; v_up uuid[]; v_seal uuid; q public.qr_seals; v_files jsonb := '[]'::jsonb; r jsonb;
begin
  select * into f from public.footprints where id = p_fp;
  if f.id is null or f.stage_type not in ('commercial', 'shipment') then return null; end if;
  if f.stage_type = 'commercial' then sale := f;
  else select * into sale from public.footprints where id = f.prev_footprint_id; end if;
  select * into sc from public.scopes where id = f.scope_id;
  select * into cr from public.crops where id = sc.crop_id;
  select * into cl from public.clients where id = sc.client_id;
  v_ships := case when f.stage_type = 'shipment' then array[f.id]
                  else array(select s.id from public.footprints s where s.prev_footprint_id = sale.id and s.stage_type = 'shipment'
                               and s.status in ('pending', 'verified') order by s.created_at) end;
  v_pack := sale.prev_footprint_id;
  v_up := array(select app.lot_upstream(v_pack));
  select s into v_seal from app.packing_seals(v_pack) s limit 1;
  select * into q from public.qr_seals where footprint_id = v_seal;
  -- the files a buyer may open: the lab reports and client acceptances up the chain, the sale's export documents, the
  -- shipments' loading photos, bills of lading and proofs of delivery
  select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'label', a.label, 'record', x.footprint_code, 'sha256', a.sha256, 'at', a.created_at)
           order by a.created_at), '[]'::jsonb) into v_files
    from public.attachments a join public.footprints x on x.id = a.footprint_id
   where (a.footprint_id = any (v_up) and x.stage_type = 'qc' and a.label in ('lab_report', 'acceptance'))
      or (a.id in (select e.attachment_id from public.export_documents e where e.footprint_id = sale.id and e.status = 'received'))
      or (a.footprint_id = any (v_ships) and a.label in ('loading_photo', 'pod', 'bill_of_lading'));
  return jsonb_build_object(
    'kind', f.stage_type, 'code', f.footprint_code, 'generated_at', now(),
    'seller', cl.name,
    'crop', jsonb_build_object('name', cr.name, 'gi_tag', cr.gi_tag, 'origin', cr.origin), 'season', sc.season_code,
    'gi_status', app.lot_gi_status(v_pack),
    'order', jsonb_build_object('code', sale.footprint_code, 'order_no', sale.computed->>'order_no', 'buyer', sale.computed->>'buyer',
               'buyer_country', sale.computed->>'buyer_country', 'market', sale.computed->>'market', 'market_name', sale.computed->>'market_name',
               'destination_country', sale.computed->>'destination_country', 'packs', sale.computed->'packs', 'kg', sale.qty_out,
               'on', sale.happened_on),
    'shipments', coalesce((select jsonb_agg(jsonb_build_object('code', s.footprint_code, 'on', coalesce(s.payload->>'dispatch_date', s.happened_on::text),
                   'destination', s.payload->>'destination', 'invoice_no', s.payload->>'invoice_no', 'market', s.computed->>'market',
                   'eway_bill_no', s.payload->>'eway_bill_no', 'transporter', s.payload->>'transporter', 'lr_no', s.payload->>'lr_no',   -- migration 57: no vehicle
                   'container_no', s.computed->>'container_no', 'seal_no', s.payload->>'seal_no', 'shipping_bill_no', s.payload->>'shipping_bill_no',
                   'vessel', s.payload->>'vessel', 'port_loading', s.payload->>'port_loading', 'port_discharge', s.payload->>'port_discharge',
                   'bl_no', coalesce((select b.bl_no from public.bills_of_lading b where b.footprint_id = s.id), s.payload->>'bl_no'),
                   'packs', s.computed->'packs', 'kg', s.qty_out, 'pack_codes', s.computed->'serials_count',
                   'delivery', (select jsonb_build_object('on', d.received_on, 'received_kg', d.received_kg, 'note', d.note)
                                  from public.deliveries d where d.shipment_id = s.id order by d.confirmed_at desc limit 1)) order by s.created_at)
                   from public.footprints s where s.id = any (v_ships)), '[]'::jsonb),
    'lab', coalesce((select jsonb_agg(jsonb_build_object('code', x.footprint_code, 'on', x.happened_on, 'lab', x.computed->>'lab',
                   'report_no', x.payload->>'report_no', 'report_date', x.payload->>'report_date', 'readings', v.readings,
                   'domestic', v.domestic_verdict, 'export', v.export_verdict,
                   'released_on_acceptance', v.override is not null,
                   'markets', (select coalesce(jsonb_agg(jsonb_build_object('name', pv.name, 'verdict', pv.verdict, 'failed', pv.failed) order by pv.code), '[]'::jsonb)
                                 from public.qc_profile_verdicts pv where pv.footprint_id = x.id)) order by x.created_at)
                   from public.footprints x join public.qc_verdicts v on v.footprint_id = x.id
                  where x.id = any (v_up) and x.status in ('pending', 'verified')), '[]'::jsonb),
    'documents', case when sale.computed->>'market' = 'export' then app.export_docs_of(sale.id) else '[]'::jsonb end,
    'chain', coalesce((select jsonb_agg(jsonb_build_object('stage', x.stage_type, 'code', x.footprint_code, 'on', x.happened_on,
                   'verified', x.status = 'verified') order by x.created_at)
                   from public.footprints x where x.id = any (v_up) and x.stage_type <> 'procurement'), '[]'::jsonb),
    'origin', jsonb_build_object(
                   'villages', coalesce((select jsonb_agg(jsonb_build_object('village', y.village, 'district', y.district, 'share_pct', y.pct)
                                  order by y.pct desc, y.village)
                     from (select fm.village, fm.district, round(sum(s.share) * 100, 1) as pct
                             from app.lot_sources(v_pack) s join public.footprints e on e.id = s.entry_id
                             join public.farmers fm on fm.id = e.farmer_id group by fm.village, fm.district) y), '[]'::jsonb),
                   'farmers', (select count(distinct e.farmer_id) from app.lot_sources(v_pack) s join public.footprints e on e.id = s.entry_id),
                   'shares_note', 'documented proportions by mass balance, not physical identity'),
    'release', case when v_seal is null then null else app.release_status(v_seal) end,
    'qr_code', q.qr_code,
    'files', v_files);
end $function$;

CREATE OR REPLACE FUNCTION app.reconcile(f footprints, p_scope scopes)
 RETURNS footprints
 LANGUAGE plpgsql
 STABLE
AS $function$
declare
  p jsonb := f.payload; c jsonb := '{}'::jsonb; w text[] := '{}';
  tol jsonb := p_scope.tolerances;
  v_in numeric; v_out numeric; a numeric; b numeric; d numeric; e numeric; s numeric; pk jsonb;
  prev public.footprints;
  v_ceiling numeric; v_learn int; v_rng record; v_pct numeric;   -- migration 49
  v_rdate date; v_taken text; v_on date;                          -- migration 50
  v_cp text; v_n int; v_crop public.crops; v_lim numeric; v_spread numeric; v_vill jsonb; v_nv int; v_moist numeric; v_far int;   -- migration 52
  v_mill public.mills; v_pu public.packing_units; v_sku public.pack_skus; v_smp public.qc_samples; v_lab public.labs;
  v_labname text; v_labtests text; v_loss numeric;                                                                   -- migration 53
  v_buyer public.buyers; v_left jsonb; v_pl jsonb; v_mkt text; v_prof public.market_profiles; v_ser text[]; v_ser_txt text;
  v_scp public.collection_points;                                                                                    -- migration 54
begin
  if f.prev_footprint_id is not null then
    select * into prev from public.footprints where id = f.prev_footprint_id;
  end if;
  select * into v_crop from public.crops where id = p_scope.crop_id;          -- migration 52: its limits and thresholds

  case f.stage_type
    when 'procurement' then
      a := app.req_num(p, 'gross_kg'); b := app.req_num(p, 'bags'); d := app.req_num(p, 'tare_kg_per_bag');
      if not (p ? 'moisture_pct' and jsonb_typeof(p->'moisture_pct') = 'array' and jsonb_array_length(p->'moisture_pct') = 3) then
        raise exception 'payload.moisture_pct must be an array of 3 readings' using errcode = '23514';
      end if;
      select avg(x::numeric), min(x::numeric), max(x::numeric) into a, b, d
        from jsonb_array_elements_text(p->'moisture_pct') x;   -- reuse vars: a=avg b=min d=max
      v_in := app.req_num(p, 'gross_kg') - app.req_num(p, 'bags') * app.req_num(p, 'tare_kg_per_bag');
      if v_in <= 0 then raise exception 'net weight must be positive (gross - bags x tare)' using errcode = '23514'; end if;
      v_out := v_in;
      c := jsonb_build_object('net_kg', v_in, 'moisture_avg', round(a, 2), 'moisture_min', b, 'moisture_max', d);
      if f.farmer_id is null then raise exception 'procurement requires farmer_id' using errcode = '23514'; end if;
      -- migration 52 (C1): where it was weighed, its GPS, who delivered it (asked where the scope says so)
      v_cp := nullif(btrim(p->>'collection_point_id'), '');
      if v_cp is not null and v_cp <> 'farm' and not exists (select 1 from public.collection_points cp
           where cp.id::text = v_cp and cp.client_id = p_scope.client_id and cp.active) then
        raise exception 'procurement: the collection point is not one of this client''s active points' using errcode = '23514'; end if;
      if v_cp is not null then                                                  -- its name, for the record, the receipt and the batch
        c := c || jsonb_build_object('collection_point', case when v_cp = 'farm' then 'farm'
                                                            else (select cp.name from public.collection_points cp where cp.id::text = v_cp) end); end if;
      if (p ? 'gps_lat' or p ? 'gps_lng') and (app.opt_num(p, 'gps_lat', null) is null or app.opt_num(p, 'gps_lng', null) is null
           or not app.valid_gps(app.opt_num(p, 'gps_lat', null), app.opt_num(p, 'gps_lng', null))) then
        raise exception 'procurement: the GPS point is two numbers in India' using errcode = '23514'; end if;
      if coalesce(p->>'delivered_by', 'farmer') not in ('farmer', 'family', 'agent') then
        raise exception 'procurement: delivered by the farmer, his family or an agent' using errcode = '23514'; end if;
      if p->>'delivered_by' = 'agent' and length(btrim(coalesce(p->>'agent_name', ''))) < 2 then
        raise exception 'procurement: name the agent who delivered the lot' using errcode = '23514'; end if;
      if p ? 'condition' and p->>'condition' not in ('good', 'damp', 'pest', 'mixed') then
        raise exception 'procurement: the condition is good, damp, pest or mixed' using errcode = '23514'; end if;
      if coalesce(p_scope.procurement_details_required, false) then
        if v_cp is null then
          raise exception 'procurement: say where the lot was weighed (a collection point, or at the farm)' using errcode = '23514'; end if;
        if not (p ? 'gps_lat') then
          raise exception 'procurement: the GPS of where the lot was weighed is required' using errcode = '23514'; end if;
        if not (p ? 'delivered_by') then
          raise exception 'procurement: say who delivered the lot (the farmer, his family or an agent)' using errcode = '23514'; end if;
      end if;
      -- warnings only: above the crop's moisture limit; three readings far apart (the crop's threshold, else 1.5 points)
      select app.opt_num(q, 'domestic_limit', null) into v_lim
        from jsonb_array_elements(coalesce(p_scope.quality_params, v_crop.quality_params, '[]'::jsonb)) q
       where q->>'param' in ('moisture_pct', 'moisture') and coalesce(q->>'operator', '<=') in ('<=', '<') limit 1;
      if v_lim is not null and a > v_lim then
        w := array_append(w, format('moisture %s %% is above the crop''s limit of %s %%', round(a, 1), v_lim)); end if;
      v_spread := coalesce((v_crop.thresholds->>'moisture_spread_pct')::numeric, 1.5);
      if d - b > v_spread then
        w := array_append(w, format('the moisture readings are %s points apart (more than %s): read them again', round(d - b, 1), v_spread)); end if;

    when 'lot_inward' then
      a := app.req_num(p, 'declared_kg'); b := app.req_num(p, 'weighed_kg');
      if b <= 0 then raise exception 'weighed_kg must be positive' using errcode = '23514'; end if;
      if coalesce(p->>'source_type', '') = '' or coalesce(p->>'source_name', '') = '' then
        raise exception 'payload.source_type and source_name are required' using errcode = '23514'; end if;
      perform app.req_num(p, 'moisture_pct');
      v_in := b; v_out := b;
      c := jsonb_build_object('variance_kg', a - b, 'variance_pct', case when a > 0 then round((a - b) / a * 100, 2) else null end);
      if a > 0 and abs(a - b) / a * 100 > app.opt_num(tol, 'lot_inward_variance_pct', 2) then
        w := array_append(w, 'declared vs weighed variance exceeds tolerance'); end if;

    when 'village_batch' then
      -- aggregates: qty_in = Σ qty_out of the source procurement lots (validated in the insert trigger)
      select coalesce(sum(s.qty_out), 0) into v_in
        from public.footprints s
        where s.id in (select (x)::uuid from jsonb_array_elements_text(coalesce(p->'source_footprint_ids', '[]'::jsonb)) x);
      if v_in <= 0 then raise exception 'village_batch needs payload.source_footprint_ids with quantity' using errcode = '23514'; end if;
      v_out := v_in;
      c := jsonb_build_object('source_count', jsonb_array_length(p->'source_footprint_ids'));
      -- migration 52 (C2): one collection point; villages and farmers from the lots; single origin; re-weighed total
      select count(distinct coalesce(s.payload->>'collection_point_id', '')), min(coalesce(s.payload->>'collection_point_id', ''))
        into v_n, v_cp from public.footprints s where s.id in (select (x)::uuid from jsonb_array_elements_text(coalesce(p->'source_footprint_ids', '[]'::jsonb)) x);
      if v_n > 1 then
        raise exception 'collection batch: the lots are from different collection points (%): a batch is the lots at one place',
          (select string_agg(s.footprint_code || ' ' || coalesce(cp.name, case s.payload->>'collection_point_id' when 'farm' then 'at the farm' else 'no place recorded' end),
                             ', ' order by s.footprint_code)
             from public.footprints s left join public.collection_points cp on cp.id::text = s.payload->>'collection_point_id'
            where s.id in (select (x)::uuid from jsonb_array_elements_text(coalesce(p->'source_footprint_ids', '[]'::jsonb)) x)) using errcode = '23514'; end if;
      -- migration 54: the batch names its collection point (or "at the farm"); its lots are that point's
      if nullif(p->>'collection_point_id', '') is not null then
        if p->>'collection_point_id' <> 'farm' then
          select * into v_scp from public.collection_points cp where cp.id::text = p->>'collection_point_id' and cp.client_id = p_scope.client_id and cp.active;
          if v_scp.id is null then raise exception 'collection batch: the collection point is not one of this client''s active points' using errcode = '23514'; end if;
        end if;
        select string_agg(s.footprint_code, ', ' order by s.footprint_code) into v_ser_txt from public.footprints s
         where s.id in (select (x)::uuid from jsonb_array_elements_text(coalesce(p->'source_footprint_ids', '[]'::jsonb)) x)
           and coalesce(s.payload->>'collection_point_id', '') <> p->>'collection_point_id';
        if v_ser_txt is not null then
          raise exception 'collection batch: % not weighed at this collection point (a batch is the lots of the point it names)', v_ser_txt using errcode = '23514'; end if;
        v_cp := p->>'collection_point_id';
      elsif p_scope.stage_details_required then
        raise exception 'collection batch: choose the collection point (where the bags are)' using errcode = '23514';
      end if;
      select coalesce(jsonb_agg(jsonb_build_object('village', g.village, 'kg', g.kg, 'share_pct', round(g.kg / nullif(v_in, 0) * 100, 1))
                                order by g.kg desc, g.village), '[]'::jsonb), count(*)
        into v_vill, v_nv
        from (select min(fm.village) as village, sum(s.qty_out) as kg
                from public.footprints s join public.farmers fm on fm.id = s.farmer_id
               where s.id in (select (x)::uuid from jsonb_array_elements_text(coalesce(p->'source_footprint_ids', '[]'::jsonb)) x) group by app.norm_place(fm.village)) g;
      if coalesce((p->>'single_origin')::boolean, false) and v_nv > 1 then
        raise exception 'collection batch: a single-origin batch is from one village (these lots are from %)',
          (select string_agg(x->>'village', ', ') from jsonb_array_elements(v_vill) x) using errcode = '23514'; end if;
      select count(distinct s.farmer_id),
             round(sum(s.qty_out * (s.computed->>'moisture_avg')::numeric) / nullif(sum(s.qty_out) filter (where s.computed ? 'moisture_avg'), 0), 2)
        into v_far, v_moist from public.footprints s where s.id in (select (x)::uuid from jsonb_array_elements_text(coalesce(p->'source_footprint_ids', '[]'::jsonb)) x);
      if p ? 'bags' and app.req_num(p, 'bags') < 1 then
        raise exception 'collection batch: the bags are 1 or more' using errcode = '23514'; end if;
      if p ? 'moisture_fresh_pct' and (app.req_num(p, 'moisture_fresh_pct') < 0 or app.req_num(p, 'moisture_fresh_pct') >= 100) then
        raise exception 'moisture must be below 100' using errcode = '23514'; end if;
      if p ? 'reweighed_kg' then
        e := app.req_num(p, 'reweighed_kg');
        if e <= 0 then raise exception 'collection batch: the re-weighed total is more than 0' using errcode = '23514'; end if;
        if e > v_in + app.kg_tolerance() then
          raise exception 'collection batch: the re-weighed total (% kg) is more than the lots (% kg)', e, v_in using errcode = '23514'; end if;
        v_out := least(e, v_in);
        if (v_in - v_out) / v_in * 100 > coalesce((v_crop.thresholds->>'batch_loss_pct')::numeric, 1) then
          w := array_append(w, format('the batch weighs %s kg (%s %%) less than its lots', round(v_in - v_out, 1), round((v_in - v_out) / v_in * 100, 1))); end if;
      end if;
      c := c || jsonb_build_object('total_kg', v_in, 'farmers', v_far, 'villages', v_vill, 'moisture_avg', v_moist,
                                   'collection_point', case when v_cp = '' then null when v_cp = 'farm' then 'farm'
                                                            else (select cp.name from public.collection_points cp where cp.id::text = v_cp) end)
                || case when p ? 'reweighed_kg' then jsonb_build_object('loss_kg', round(v_in - v_out, 3)) else '{}'::jsonb end;

    when 'milling' then
      if p ? 'head_rice_kg' then
        -- migration 53 (C4): head rice, broken, husk and bran; the loss worked out (never typed, never below 0); the mill
        -- from the client's list, its operator, how the line was cleared (recorded by itself at a mill dedicated to the
        -- crop); sent vs received when the mill is elsewhere. Head rice goes forward; broken rice is a by-product.
        v_in := app.req_num(p, 'input_kg'); a := app.req_num(p, 'head_rice_kg');
        b := app.opt_num(p, 'broken_kg', 0); d := app.opt_num(p, 'husk_kg', 0); e := app.opt_num(p, 'bran_kg', 0);
        if v_in <= 0 then raise exception 'milling: the paddy in is more than 0 kg' using errcode = '23514'; end if;
        if least(a, b, d, e) < 0 then raise exception 'milling: an output is 0 kg or more' using errcode = '23514'; end if;
        v_loss := v_in - a - b - d - e;
        if v_loss < -app.kg_tolerance() then
          raise exception 'milling: the outputs (% kg) are more than the paddy in (% kg)', a + b + d + e, v_in using errcode = '23514'; end if;
        v_loss := greatest(v_loss, 0);
        if nullif(p->>'mill_id', '') is not null then
          select * into v_mill from public.mills m where m.id::text = p->>'mill_id' and m.client_id = p_scope.client_id and m.active;
          if v_mill.id is null then raise exception 'milling: the mill is not one of this client''s active mills' using errcode = '23514'; end if;
        elsif p_scope.stage_details_required then
          raise exception 'milling: say which mill (from the client''s list)' using errcode = '23514'; end if;
        if p_scope.stage_details_required and length(btrim(coalesce(p->>'mill_operator', ''))) < 2 then
          raise exception 'milling: name the mill operator' using errcode = '23514'; end if;
        if v_mill.id is not null and v_mill.dedicated_crop_id = p_scope.crop_id then v_cp := 'dedicated';
        else
          v_cp := nullif(p->>'line_clearance', '');
          if v_cp is not null and v_cp not in ('fully_cleaned', 'quick_clean', 'same_crop') then
            raise exception 'milling: the line was fully cleaned, given a quick clean, or its previous run was this crop' using errcode = '23514'; end if;
          if v_cp is null and v_mill.id is not null then
            raise exception 'milling: say how the line was cleared (the mill is not dedicated to this crop)' using errcode = '23514'; end if;
        end if;
        if p ? 'polish' and p->>'polish' not in ('light', 'medium', 'full') then
          raise exception 'milling: the polish is light, medium or full' using errcode = '23514'; end if;
        v_out := a;
        c := jsonb_build_object('head_rice_kg', a, 'broken_kg', b, 'husk_kg', d, 'bran_kg', e, 'loss_kg', round(v_loss, 3),
               'recovery_pct', round((a + b) / v_in * 100, 2), 'head_rice_pct', round(a / v_in * 100, 2), 'yield_pct', round((a + b) / v_in * 100, 2));
        if v_mill.id is not null then c := c || jsonb_build_object('mill', v_mill.name); end if;
        if v_cp is not null then c := c || jsonb_build_object('line_clearance', v_cp); end if;
        if p ? 'sent_kg' then
          s := app.req_num(p, 'sent_kg');
          if v_in > s + app.kg_tolerance() then
            raise exception 'milling: the mill received (% kg) more than was sent (% kg)', v_in, s using errcode = '23514'; end if;
          c := c || jsonb_build_object('transit_loss_kg', round(greatest(s - v_in, 0), 3));
        end if;
        -- no fixed threshold: the crop's ceiling (the State Manager is told) and, after enough runs, this mill's usual range
        v_pct := round((a + b) / v_in * 100, 1);
        select coalesce((cr.thresholds->>'milling_outturn_ceiling_pct')::numeric, 70), coalesce((cr.thresholds->>'learn_after_runs')::int, 10)
          into v_ceiling, v_learn from public.crops cr where cr.id = p_scope.crop_id;
        if v_pct > v_ceiling then
          w := array_append(w, format('outturn %s %% is above the crop''s ceiling of %s %%: the State Manager is told', v_pct, v_ceiling)); end if;
        if v_mill.id is not null then
          select * into v_rng from app.milling_range_mill(p_scope.crop_id, v_mill.id::text, f.id);
          if v_rng.n >= v_learn and v_rng.sd is not null and abs(v_pct - v_rng.mean) > 2 * v_rng.sd then
            w := array_append(w, format('recovery %s %% is outside the usual range of this mill (%s to %s %%, from %s verified runs)', v_pct,
                   round(v_rng.mean - 2 * v_rng.sd, 1), round(v_rng.mean + 2 * v_rng.sd, 1), v_rng.n)); end if;
        end if;
      else
      -- a record of before migration 53: rice out, bran and loss typed
      v_in := app.req_num(p, 'input_kg'); a := app.req_num(p, 'rice_kg'); b := app.req_num(p, 'bran_kg'); d := app.req_num(p, 'loss_kg');
      if not app.approx_eq(v_in, a + b + d) then
        raise exception 'milling: input (%) must equal rice + bran + loss (%)', v_in, a + b + d using errcode = '23514'; end if;
      v_out := a;
      c := jsonb_build_object('yield_pct', round(a / nullif(v_in, 0) * 100, 2), 'bran_kg', b, 'loss_kg', d);
      -- migration 49 (A7/G5): no fixed threshold. Above the crop's ceiling (70 % unless set) the State Manager is told;
      -- once the crop has its own verified runs (10 unless set), outside their usual range (mean ± 2 SD) is warned.
      if v_in > 0 then
        v_pct := round(a / v_in * 100, 1);
        select coalesce((cr.thresholds->>'milling_outturn_ceiling_pct')::numeric, 70), coalesce((cr.thresholds->>'learn_after_runs')::int, 10)
          into v_ceiling, v_learn from public.crops cr where cr.id = p_scope.crop_id;
        if v_pct > v_ceiling then
          w := array_append(w, format('outturn %s %% is above the crop''s ceiling of %s %%: the State Manager is told', v_pct, v_ceiling)); end if;
        select * into v_rng from app.milling_range(p_scope.crop_id, p_scope.client_id, f.id);
        if v_rng.n >= v_learn and v_rng.sd is not null and abs(v_pct - v_rng.mean) > 2 * v_rng.sd then
          w := array_append(w, format('outturn %s %% is outside the usual range of this crop (%s to %s %%, from %s verified runs)', v_pct,
                 round(v_rng.mean - 2 * v_rng.sd, 1), round(v_rng.mean + 2 * v_rng.sd, 1), v_rng.n)); end if;
      end if;
      end if;                                                                           -- migration 53

    when 'sorting' then
      v_in := app.req_num(p, 'input_kg'); a := app.req_num(p, 'reject_kg'); d := app.req_num(p, 'loss_kg');
      v_out := v_in - a - d;                                          -- clean output is DERIVED, never entered
      if v_out < 0 then raise exception 'sorting: reject + loss exceed input' using errcode = '23514'; end if;
      c := jsonb_build_object('clean_kg', v_out, 'reject_kg', a, 'loss_kg', d, 'reject_reasons', coalesce(p->'reject_reasons', '[]'::jsonb));

    when 'grading' then
      if f.is_grade_lot then
        -- child grade lot: quantity given directly, coupled to the grading run (validated in trigger)
        v_in := app.req_num(p, 'qty_kg'); v_out := v_in;
        c := jsonb_build_object('grade', f.grade);
      else
        v_in := app.req_num(p, 'input_kg');
        a := app.req_num(p, 'grade_a_kg'); b := app.req_num(p, 'grade_b_kg'); d := app.req_num(p, 'grade_c_kg');
        e := app.req_num(p, 'reject_kg'); s := app.req_num(p, 'loss_kg');
        if not app.approx_eq(v_in, a + b + d + e + s) then
          raise exception 'grading: A + B + C + reject + loss (%) must equal input (%)', a + b + d + e + s, v_in using errcode = '23514'; end if;
        v_out := a + b + d;
        c := jsonb_build_object('grade_split', jsonb_build_object('A', a, 'B', b, 'C', d), 'reject_kg', e, 'loss_kg', s);
      end if;

    when 'drying' then
      v_in := app.req_num(p, 'input_kg'); a := app.req_num(p, 'moisture_in_pct'); b := app.req_num(p, 'moisture_out_pct');
      v_out := app.req_num(p, 'output_kg');
      if b >= 100 or a >= 100 then raise exception 'moisture must be below 100%%' using errcode = '23514'; end if;
      e := v_in * (100 - a) / (100 - b);                              -- dry-matter expected output
      c := jsonb_build_object('expected_out_kg', round(e, 3), 'water_removed_kg', round(v_in - e, 3),
                              'grain_loss_kg', round(greatest(e - v_out, 0), 3));
      if v_out > e * 1.01 + app.kg_tolerance() then w := array_append(w, 'output exceeds dry-matter expectation'); end if;  -- 1% weighing noise
      if e - v_out > greatest(e * 0.02, app.kg_tolerance()) then w := array_append(w, 'grain loss beyond moisture removal'); end if;

    when 'popping' then
      v_in := app.req_num(p, 'input_kg'); v_out := app.req_num(p, 'output_kg'); a := app.req_num(p, 'pop_rate_pct');
      c := jsonb_build_object('pop_rate_pct', a, 'weight_yield_pct', round(v_out / nullif(v_in, 0) * 100, 2));
      if a < app.opt_num(tol, 'pop_rate_min_pct', 80) then w := array_append(w, 'pop rate below threshold'); end if;

    when 'blanching' then
      v_in := app.req_num(p, 'input_kg'); v_out := app.req_num(p, 'output_kg');
      c := jsonb_build_object('water_uptake_kg', round(v_out - v_in, 3));   -- output > input is valid here

    when 'cleaning' then
      v_in := app.req_num(p, 'input_kg'); a := app.req_num(p, 'foreign_matter_kg'); d := app.req_num(p, 'loss_kg');
      v_out := v_in - a - d;
      if v_out < 0 then raise exception 'cleaning: foreign matter + loss exceed input' using errcode = '23514'; end if;
      c := jsonb_build_object('foreign_matter_kg', a, 'loss_kg', d);

    when 'warehouse' then
      -- migration 55 (C3): sent (taken from the lot) vs received; a reason for any difference; condition, bags, location
      a := app.req_num(p, 'declared_kg'); b := app.req_num(p, 'received_kg');
      if a <= 0 then raise exception 'warehouse: what was sent is more than 0 kg' using errcode = '23514'; end if;
      if b <= 0 then raise exception 'warehouse: what was received is more than 0 kg' using errcode = '23514'; end if;
      if b > a + app.kg_tolerance() then
        raise exception 'warehouse: the received weight (% kg) is more than was sent (% kg)', trim_scale(b), trim_scale(a) using errcode = '23514'; end if;
      d := a - b; v_pct := round(d / a * 100, 2);
      if d > app.kg_tolerance() and length(btrim(coalesce(p->>'discrepancy_reason', ''))) < 5 then
        raise exception 'warehouse: say why % kg less was received than sent (at least 5 characters)', trim_scale(round(d, 3)) using errcode = '23514'; end if;
      if coalesce(p->>'condition', '') not in ('good', 'damp', 'pest', 'mixed') then
        raise exception 'warehouse: the condition on arrival is good, damp, pest or mixed' using errcode = '23514'; end if;
      e := app.req_num(p, 'bags_in');
      if e < 1 or e <> trunc(e) then raise exception 'warehouse: the bags in are a whole number, 1 or more' using errcode = '23514'; end if;
      if length(btrim(coalesce(p->>'location', ''))) < 2 then
        raise exception 'warehouse: name the warehouse or location' using errcode = '23514'; end if;
      v_in := a; v_out := b;
      c := jsonb_build_object('discrepancy_kg', round(d, 3), 'discrepancy_pct', v_pct, 'condition', p->>'condition', 'bags_in', e,
                              'location', btrim(p->>'location')) || case when nullif(btrim(p->>'stack'), '') is not null
                              then jsonb_build_object('stack', btrim(p->>'stack')) else '{}'::jsonb end;
      if v_pct > app.opt_num(v_crop.thresholds, 'warehouse_discrepancy_pct', 2) then
        w := array_append(w, format('the warehouse received %s kg (%s %%) less than was sent: flagged for the manager', trim_scale(round(d, 1)), trim_scale(round(v_pct, 1))));
      end if;

    when 'cold_storage' then
      v_in := app.req_num(p, 'stored_kg'); v_out := app.req_num(p, 'retrieved_kg');
      c := jsonb_build_object('spoilage_kg', round(v_in - v_out, 3));

    when 'packing' then
      v_in := app.req_num(p, 'input_kg');
      -- migration 50 (G1): the save gives the batch code (trigger footprints_a1_batch_code); the preview has none yet
      if coalesce(p->>'batch_code', '') = '' and f.id is not null then raise exception 'packing: batch_code is mandatory (QR link)' using errcode = '23514'; end if;
      if not (p ? 'packets' and jsonb_typeof(p->'packets') = 'array' and jsonb_array_length(p->'packets') > 0) then
        raise exception 'packing: payload.packets [{units,size_kg}] is required' using errcode = '23514'; end if;
      select coalesce(sum(app.req_num(x, 'units') * app.req_num(x, 'size_kg')), 0) into v_out from jsonb_array_elements(p->'packets') x;
      -- migration 53 (C6): packs from the client's pack list (each keeps its own size), the packing unit from the list;
      -- the wastage worked out (a record of before typed it); above 2 % (the crop's packing_wastage_pct) a reason
      for pk in select * from jsonb_array_elements(p->'packets') loop
        if nullif(pk->>'sku_id', '') is not null then
          select * into v_sku from public.pack_skus k where k.id::text = pk->>'sku_id' and k.client_id = p_scope.client_id and k.active;
          if v_sku.id is null then raise exception 'packing: a pack is not on the client''s pack list' using errcode = '23514'; end if;
          if abs(app.req_num(pk, 'size_kg') - case v_sku.unit when 'g' then v_sku.size / 1000 else v_sku.size end) > 0.0005 then
            raise exception 'packing: a pack from the list keeps its own size (% %)', v_sku.size, v_sku.unit using errcode = '23514'; end if;
          if app.req_num(pk, 'units') < 1 or app.req_num(pk, 'units') <> trunc(app.req_num(pk, 'units')) then
            raise exception 'packing: the number of packs is a whole number, 1 or more' using errcode = '23514'; end if;
        elsif p_scope.stage_details_required then
          raise exception 'packing: choose the packs from the client''s pack list' using errcode = '23514';
        end if;
      end loop;
      if nullif(p->>'packing_unit_id', '') is not null then
        select * into v_pu from public.packing_units u where u.id::text = p->>'packing_unit_id' and u.client_id = p_scope.client_id and u.active;
        if v_pu.id is null then raise exception 'packing: the packing unit is not one of this client''s active units' using errcode = '23514'; end if;
      elsif p_scope.stage_details_required then
        raise exception 'packing: say where it was packed (a packing unit of the client)' using errcode = '23514';
      end if;
      if p ? 'wastage_kg' then
        d := app.req_num(p, 'wastage_kg');
        if not app.approx_eq(v_in, v_out + d) then
          raise exception 'packing: Σ packets (%) + wastage (%) must equal input (%)', v_out, d, v_in using errcode = '23514'; end if;
      else
        d := v_in - v_out;
        if d < -app.kg_tolerance() then
          raise exception 'packing: the packs (% kg) are more than the input (% kg)', v_out, v_in using errcode = '23514'; end if;
        d := greatest(d, 0);
      end if;
      v_lim := coalesce((v_crop.thresholds->>'packing_wastage_pct')::numeric, 2);
      if v_in > 0 and d / v_in * 100 > v_lim then
        if length(btrim(coalesce(p->>'wastage_reason', ''))) < 5 then
          raise exception 'packing: the wastage is % %% of the input (more than % %%): say why', round(d / v_in * 100, 1), v_lim using errcode = '23514'; end if;
        w := array_append(w, format('wastage %s %% is above %s %%: %s', round(d / v_in * 100, 1), v_lim, btrim(p->>'wastage_reason')));
      end if;
      c := jsonb_build_object('packed_kg', v_out, 'wastage_kg', round(d, 3), 'wastage_pct', round(d / nullif(v_in, 0) * 100, 2), 'batch_code', p->>'batch_code')
           || case when v_pu.id is not null then jsonb_build_object('packing_unit', v_pu.name) else '{}'::jsonb end;

    when 'qc' then
      v_in := app.req_num(p, 'qty_kg');
      -- migration 53 (C5): the sample drawn first (its quantity and lab come with it); the lab from the state's list; a
      -- lab test (the library says "lab") is read at an accredited external lab, never in-house
      if nullif(p->>'sample_ref', '') is not null then
        select * into v_smp from public.qc_samples sm where sm.id::text = p->>'sample_ref';
        if v_smp.id is null or v_smp.footprint_id is distinct from f.prev_footprint_id then
          raise exception 'qc: the sample is not one drawn from this lot' using errcode = '23514'; end if;
        if v_smp.status <> 'sent' and v_smp.qc_footprint_id is distinct from f.id then
          raise exception 'qc: the results of sample % are in already (or it was disposed of)', v_smp.code using errcode = '23514'; end if;
        a := v_smp.qty_kg;
        if v_smp.lab_id is not null then select * into v_lab from public.labs l where l.id = v_smp.lab_id; end if;
      else
        if p_scope.stage_details_required then
          raise exception 'qc: choose the sample drawn from this lot (draw it first: it goes to the lab)' using errcode = '23514'; end if;
        a := app.req_num(p, 'sample_qty_kg');
      end if;
      if v_lab.id is null and nullif(p->>'lab_id', '') is not null then
        select * into v_lab from public.labs l where l.id::text = p->>'lab_id' and app.lab_for_scope(l.id, p_scope.id);   -- migration 54
        if v_lab.id is null then raise exception 'qc: the lab is not on this state''s or this client''s list' using errcode = '23514'; end if;
      end if;
      v_labname := coalesce(v_lab.name, nullif(btrim(p->>'lab_name'), ''));
      if p ? 'readings' and jsonb_typeof(p->'readings') = 'object' then
        select string_agg(distinct coalesce(lb.name, la.name), ', ') into v_labtests
          from jsonb_each(p->'readings') r
          join public.quality_param_library la on la.param = r.key
          left join public.quality_param_library lb on lb.param = la.alias_of
         where coalesce(lb.done_by, la.done_by) = 'lab' and nullif(btrim(r.value #>> '{}'), '') is not null;
        if v_labtests is not null and (v_lab.kind = 'in_house' or (v_lab.id is null and p_scope.stage_details_required)) then
          raise exception 'qc: % is a lab test: it is read at an accredited external lab', v_labtests using errcode = '23514'; end if;
      end if;
      if a >= v_in then raise exception 'qc: sample must be smaller than the lot' using errcode = '23514'; end if;
      if not (p ? 'readings' and jsonb_typeof(p->'readings') = 'object') then
        raise exception 'qc: payload.readings {param: value} is required' using errcode = '23514'; end if;
      v_out := v_in - a;                                              -- sample consumed in testing (rule 7)
      c := jsonb_build_object('sample_qty_kg', a, 'forwarding_kg', v_out);
      if v_smp.id is not null then c := c || jsonb_build_object('sample_code', v_smp.code); end if;                 -- migration 53
      if v_lab.id is not null then c := c || jsonb_build_object('lab', v_lab.name, 'lab_kind', v_lab.kind); end if;
      -- migration 50 (C5): the scope asks for the lab report (the default): the lab, its number and date; the file comes
      -- before verification. The date: not ahead of today, not before the lot existed. A number once per lab, unless
      -- the lots share the sample.
      if p_scope.qc_report_required then
        if coalesce(v_labname, '') = '' or coalesce(btrim(p->>'report_no'), '') = '' or coalesce(p->>'report_date', '') = '' then
          raise exception 'qc: the lab, the report number and the report date are required' using errcode = '23514'; end if;
        begin v_rdate := (p->>'report_date')::date; exception when others then
          raise exception 'qc: the report date is a date' using errcode = '23514'; end;
        if v_rdate > (now() at time zone 'Asia/Kolkata')::date then
          raise exception 'qc: the report date (%) is in the future', to_char(v_rdate, 'DD Mon YYYY') using errcode = '23514'; end if;
        v_on := coalesce(prev.happened_on, (coalesce(prev.captured_at, prev.created_at) at time zone 'Asia/Kolkata')::date);
        if prev.id is not null and v_rdate < v_on then
          raise exception 'qc: the report date (%) is before the lot it tests (% on %)', to_char(v_rdate, 'DD Mon YYYY'), prev.footprint_code, to_char(v_on, 'DD Mon YYYY')
            using errcode = '23514'; end if;
        v_taken := app.report_no_taken(v_labname, p->>'report_no', p->>'sample_id', f.id);
        if v_taken is not null then
          raise exception 'qc: report % of this lab is on % already (the same report twice needs the same sample ID)', btrim(p->>'report_no'), v_taken
            using errcode = '23505'; end if;
        c := c || jsonb_build_object('lab_name', v_labname, 'report_no', btrim(p->>'report_no'), 'report_date', v_rdate);
      end if;

    when 'commercial' then
      if p ? 'buyer_id' or p ? 'packs' or p ? 'order_no' or p_scope.stage_details_required then
        -- migration 54 (C7): the buyer from the client's list; the market, and for export its profile and the destination
        -- (the batch passed QC for that profile, or carries the client's written acceptance); the order number; packs by
        -- type where the batch was packed from the pack list (no more than are left), else the kilograms
        if coalesce(p->>'market', '') not in ('domestic','export') then
          raise exception 'commercial: market must be domestic or export' using errcode = '23514'; end if;
        if nullif(p->>'buyer_id', '') is not null then
          select * into v_buyer from public.buyers b where b.id::text = p->>'buyer_id' and b.client_id = p_scope.client_id and b.active;
          if v_buyer.id is null then raise exception 'commercial: the buyer is not one of this client''s active buyers' using errcode = '23514'; end if;
        elsif p_scope.stage_details_required or coalesce(btrim(p->>'buyer'), '') = '' then
          raise exception 'commercial: choose the buyer from the client''s list' using errcode = '23514';
        end if;
        if length(btrim(coalesce(p->>'order_no', ''))) < 2 then
          raise exception 'commercial: give the order or contract number' using errcode = '23514'; end if;
        if p->>'market' = 'export' then
          select * into v_prof from public.market_profiles m where m.crop_id = p_scope.crop_id and m.status = 'active'
             and m.code = p->>'market_code' and m.code <> 'domestic' and m.code = any (p_scope.market_codes);
          if v_prof.id is null then
            raise exception 'commercial: choose the export market (one of this scope''s market profiles)' using errcode = '23514'; end if;
          if length(btrim(coalesce(p->>'destination_country', ''))) < 2 then
            raise exception 'commercial: name the destination country' using errcode = '23514'; end if;
          if not app.profile_allowed(f.prev_footprint_id, v_prof.code) then
            raise exception 'commercial: this batch has not passed QC for % (nor carries the client''s written acceptance)', v_prof.name using errcode = '23514'; end if;
        end if;
        if p ? 'sale_route' and p->>'sale_route' not in ('own_brand', 'white_label', 'bulk', 'prasaadam') then
          raise exception 'commercial: the sale route is own brand, white label, bulk or Prasaadam' using errcode = '23514'; end if;
        v_left := case when prev.stage_type = 'packing' then app.packs_left_of(prev.id, f.id) else '[]'::jsonb end;
        if jsonb_array_length(v_left) > 0 then
          v_pl := app.check_pack_lines(p->'packs', v_left, 'commercial');
          v_in := (v_pl->>'kg')::numeric;
        else
          v_in := app.req_num(p, 'qty_kg');
        end if;
        v_out := v_in;
        c := jsonb_build_object('market', p->>'market', 'buyer', coalesce(v_buyer.name, btrim(p->>'buyer')), 'order_no', btrim(p->>'order_no'))
             || case when v_buyer.id is not null then jsonb_build_object('buyer_id', v_buyer.id, 'buyer_country', v_buyer.country) else '{}'::jsonb end
             || case when v_prof.id is not null then jsonb_build_object('market_code', v_prof.code, 'market_name', v_prof.name,
                                                                      'destination_country', btrim(p->>'destination_country')) else '{}'::jsonb end
             || case when v_pl is not null then jsonb_build_object('packs', v_pl->'lines') else '{}'::jsonb end
             || case when p ? 'sale_route' then jsonb_build_object('sale_route', p->>'sale_route') else '{}'::jsonb end;
      else
      v_in := app.req_num(p, 'qty_kg'); v_out := v_in;
      if coalesce(p->>'buyer', '') = '' then raise exception 'commercial: buyer is required' using errcode = '23514'; end if;
      if coalesce(p->>'market', '') not in ('domestic','export') then
        raise exception 'commercial: market must be domestic or export' using errcode = '23514'; end if;
      if p->>'market' = 'export' and not app.export_allowed(f.prev_footprint_id) then
        raise exception 'commercial: export sale requires export PASS or a client-level override' using errcode = '23514'; end if;
      c := jsonb_build_object('market', p->>'market', 'buyer', p->>'buyer');
      end if;                                                                           -- migration 54

    when 'shipment' then
      if p ? 'packs' or p ? 'invoice_no' or p_scope.stage_details_required then
        -- migration 54 (C8): the packs of one order (partial shipments: no more than are left of it); for export the pack
        -- codes scanned while loading, and the order's export documents complete; the papers of the market, their formats
        v_mkt := coalesce(prev.computed->>'market', prev.payload->>'market', 'domestic');
        if length(btrim(coalesce(p->>'invoice_no', ''))) < 2 then
          raise exception 'shipment: give the invoice number' using errcode = '23514'; end if;
        v_left := case when prev.stage_type = 'commercial' then app.packs_left_of(prev.id, f.id) else '[]'::jsonb end;
        if jsonb_array_length(v_left) > 0 then
          v_pl := app.check_pack_lines(p->'packs', v_left, 'shipment');
          v_in := (v_pl->>'kg')::numeric;
        else
          v_in := app.req_num(p, 'shipped_kg');
        end if;
        if v_mkt = 'export' then
          if not app.container_ok(p->>'container_no') then
            raise exception 'shipment: the container number is 4 letters and 7 digits (e.g. MSKU1234567)' using errcode = '23514'; end if;
          if length(btrim(coalesce(p->>'seal_no', ''))) < 3 then
            raise exception 'shipment: give the container seal number' using errcode = '23514'; end if;
          if btrim(coalesce(p->>'shipping_bill_no', '')) !~ '^[0-9]{6,8}$' then
            raise exception 'shipment: the shipping bill number is 6 to 8 digits' using errcode = '23514'; end if;
          if nullif(btrim(p->>'bl_no'), '') is not null and btrim(p->>'bl_no') !~ '^[A-Za-z0-9/-]{4,30}$' then
            raise exception 'shipment: a bill of lading number is 4 to 30 letters or digits' using errcode = '23514'; end if;
          select string_agg(x->>'doc', ', ') into v_ser_txt from jsonb_array_elements(app.export_docs_of(prev.id)) x where not (x->>'done')::boolean;
          if v_ser_txt is not null then
            raise exception 'shipment: the export documents of order % are not complete (%): attach their files at Commercial first', prev.footprint_code, v_ser_txt
              using errcode = '23514'; end if;
        else
          if not app.vehicle_ok(p->>'vehicle_no') then
            raise exception 'shipment: the vehicle number reads like UP53AB1234' using errcode = '23514'; end if;
          if length(btrim(coalesce(p->>'lr_no', ''))) < 2 then
            raise exception 'shipment: give the LR (lorry receipt) number' using errcode = '23514'; end if;
          if nullif(btrim(p->>'driver_phone'), '') is not null and regexp_replace(p->>'driver_phone', '[^0-9]', '', 'g') !~ '^(91)?[6-9][0-9]{9}$' then
            raise exception 'shipment: the driver''s phone is a 10-digit mobile number' using errcode = '23514'; end if;
          if nullif(btrim(p->>'eway_bill_no'), '') is not null and regexp_replace(p->>'eway_bill_no', '\s', '', 'g') !~ '^[0-9]{12}$' then
            raise exception 'shipment: an e-way bill number is 12 digits' using errcode = '23514'; end if;
        end if;
        -- migration 57: the codes of the packs loaded, for a domestic shipment too
        if v_pl is not null then
          select array_agg(upper(btrim(x))) into v_ser from jsonb_array_elements_text(case when jsonb_typeof(p->'serials') = 'array' then p->'serials' else '[]'::jsonb end) x where btrim(x) <> '';
          if coalesce(cardinality(v_ser), 0) = 0 then
            raise exception 'shipment: scan or type the codes of the packs loaded' using errcode = '23514'; end if;
          if cardinality(v_ser) <> (select count(distinct sr) from unnest(v_ser) sr) then
            raise exception 'shipment: a pack code is there twice' using errcode = '23514'; end if;
          select string_agg(sr, ', ') into v_ser_txt from unnest(v_ser) sr
           where not exists (select 1 from public.packs pk where pk.serial = sr and pk.status = 'packed' and pk.footprint_id = prev.prev_footprint_id);
          if v_ser_txt is not null then
            raise exception 'shipment: % not a pack of this order''s batch (or void)', v_ser_txt using errcode = '23514'; end if;
          select string_agg(sr, ', ') into v_ser_txt from unnest(v_ser) sr
           where exists (select 1 from public.footprints o where o.stage_type = 'shipment' and o.id <> f.id and o.status not in ('superseded', 'legacy')
                           and coalesce(o.payload->'serials', '[]'::jsonb) ? sr);
          if v_ser_txt is not null then
            raise exception 'shipment: % shipped already', v_ser_txt using errcode = '23514'; end if;
          select string_agg(x->>'name', ', ') into v_ser_txt from jsonb_array_elements(v_pl->'lines') x
           where (x->>'units')::numeric <> (select count(*) from unnest(v_ser) sr join public.packs pk on pk.serial = sr where pk.sku_id::text = x->>'sku_id');
          if v_ser_txt is not null or cardinality(v_ser) <> (select sum((x->>'units')::numeric) from jsonb_array_elements(v_pl->'lines') x) then
            raise exception 'shipment: the codes scanned do not match the packs shipped (%)', coalesce(v_ser_txt, 'other pack types') using errcode = '23514'; end if;
        end if;
        v_out := v_in;
        c := jsonb_build_object('market', v_mkt, 'invoice_no', btrim(p->>'invoice_no'))
             || case when v_pl is not null then jsonb_build_object('packs', v_pl->'lines') else '{}'::jsonb end
             || case when v_ser is not null then jsonb_build_object('serials_count', cardinality(v_ser)) else '{}'::jsonb end
             || case when v_mkt = 'export' then jsonb_build_object('container_no', upper(regexp_replace(p->>'container_no', '[\s-]', '', 'g')),
                       'bl_pending', nullif(btrim(p->>'bl_no'), '') is null) else '{}'::jsonb end;
      else
      v_in := app.req_num(p, 'shipped_kg'); d := app.opt_num(p, 'transit_loss_kg', 0);
      v_out := v_in - d;
      if v_out < 0 then raise exception 'shipment: transit loss exceeds shipped quantity' using errcode = '23514'; end if;
      c := jsonb_build_object('transit_loss_kg', d);
      end if;                                                                           -- migration 54

    when 'qr_activation' then
      if prev.id is null then raise exception 'qr_activation needs a predecessor' using errcode = '23514'; end if;
      v_in := app.available_qty(prev.id); v_out := v_in;              -- takes whatever remains of the final lot
      if v_in <= 0 then raise exception 'qr_activation: final quantity must be recorded and positive' using errcode = '23514'; end if;
      c := jsonb_build_object('final_kg', v_in);

    else
      raise exception 'no reconciliation rule for stage %', f.stage_type using errcode = '23514';
  end case;

  -- Rule 3: output never exceeds input, except blanching.
  if v_out > v_in + app.kg_tolerance() and f.stage_type <> 'blanching' then
    raise exception '% : output (%) exceeds input (%)', f.stage_type, v_out, v_in using errcode = '23514';
  end if;

  f.qty_in := round(v_in, 3); f.qty_out := round(v_out, 3); f.computed := c; f.warnings := w;
  return f;
end $function$;

-- ---------------------------------------------------------------------------------------------------------------------
-- Who may call what
-- ---------------------------------------------------------------------------------------------------------------------
revoke execute on function app.busy_for_other_client(uuid), app.order_pack_codes(uuid, uuid) from public, anon, authenticated;
grant execute on function app.order_pack_codes(uuid, uuid) to authenticated;
