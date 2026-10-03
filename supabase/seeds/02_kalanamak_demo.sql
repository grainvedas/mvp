-- GrainVeda MVP · seed: Kalanamak demo (PRD §12 sample data) — state, crop, client, users, slots, farmers, two scopes.
-- Fixed UUIDs so tests and docs can reference them. auth_uid values are placeholders: in Supabase, create the
-- auth users and update app_users.auth_uid to match (see README). Idempotent.

-- Never on production: this file creates demo people, farmers and scopes (migration 23 marks the production project).
do $$ begin
  if to_regprocedure('app.environment()') is not null then
    if app.environment() = 'production' then
      raise exception 'demo seed refused: this is the PRODUCTION project (use supabase/seeds/production/)';
    end if;
  end if;
end $$;

insert into public.states (id, name, code) values
  ('00000000-0000-4000-8000-000000000001', 'Uttar Pradesh', 'UP'),
  ('00000000-0000-4000-8000-000000000002', 'Assam', 'AS')
on conflict (id) do nothing;

insert into public.crops (id, name, code, gi_tag, origin, primary_unit, quality_params, allowed_stages) values
  ('00000000-0000-4000-8000-000000000101', 'Kalanamak rice', 'KNM', 'GI 280', 'Eastern UP Terai belt (Siddharthnagar)', 'kg',
   '[{"param":"moisture_pct","label":"Moisture","unit":"%","operator":"<=","domestic_limit":13,"export_limit":12},
     {"param":"broken_pct","label":"Broken grains","unit":"%","operator":"<=","domestic_limit":5,"export_limit":3},
     {"param":"foreign_matter_pct","label":"Foreign matter","unit":"%","operator":"<=","domestic_limit":1,"export_limit":0.5}]',
   '{milling,sorting,grading,drying,cleaning,cold_storage,packing}'),
  ('00000000-0000-4000-8000-000000000102', 'Joha rice', 'JOHA', 'GI', 'Assam', 'kg',
   '[{"param":"moisture_pct","label":"Moisture","unit":"%","operator":"<=","domestic_limit":13,"export_limit":12}]',
   '{milling,sorting,grading,drying,cleaning,cold_storage,packing}')
on conflict (id) do nothing;

insert into public.clients (id, state_id, name, code, type) values
  ('00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000001', 'GrainVeda (Prasaadam trade scope)', 'PRSDM', 'grainveda'),
  ('00000000-0000-4000-8000-000000000202', '00000000-0000-4000-8000-000000000001', 'Demo Exporter Pvt Ltd', 'DEMOX', 'exporter')
on conflict (id) do nothing;

-- Users. auth_uid = same as id here for local testing.
insert into public.app_users (id, auth_uid, role, display_name, phone, state_ids, client_id) values
  ('00000000-0000-4000-8000-000000000301', '00000000-0000-4000-8000-000000000301', 'admin',          'Veda (Admin)',           null, '{}', null),
  ('00000000-0000-4000-8000-000000000302', '00000000-0000-4000-8000-000000000302', 'state_manager',  'UP State Manager',       null, '{00000000-0000-4000-8000-000000000001}', null),
  ('00000000-0000-4000-8000-000000000303', '00000000-0000-4000-8000-000000000303', 'client_manager', 'Prasaadam Client Manager', null, '{}', '00000000-0000-4000-8000-000000000201'),
  ('00000000-0000-4000-8000-000000000304', '00000000-0000-4000-8000-000000000304', 'client_view',    'Prasaadam Client View',  null, '{}', '00000000-0000-4000-8000-000000000201'),
  ('00000000-0000-4000-8000-000000000305', '00000000-0000-4000-8000-000000000305', 'operator',       'Procurement Op (field)', '+910000000005', '{}', '00000000-0000-4000-8000-000000000201'),
  ('00000000-0000-4000-8000-000000000306', '00000000-0000-4000-8000-000000000306', 'operator',       'QC Technician',          '+910000000006', '{}', '00000000-0000-4000-8000-000000000201'),
  ('00000000-0000-4000-8000-000000000307', '00000000-0000-4000-8000-000000000307', 'operator',       'QR Sealer',              '+910000000007', '{}', '00000000-0000-4000-8000-000000000201'),
  ('00000000-0000-4000-8000-000000000308', '00000000-0000-4000-8000-000000000308', 'operator',       'Mill Operator',          '+910000000008', '{}', '00000000-0000-4000-8000-000000000201'),
  ('00000000-0000-4000-8000-000000000309', '00000000-0000-4000-8000-000000000309', 'operator',       'Sorting Operator',       '+910000000009', '{}', '00000000-0000-4000-8000-000000000201'),
  ('00000000-0000-4000-8000-000000000310', '00000000-0000-4000-8000-000000000310', 'operator',       'Grading Operator',       '+910000000010', '{}', '00000000-0000-4000-8000-000000000201'),
  ('00000000-0000-4000-8000-000000000311', '00000000-0000-4000-8000-000000000311', 'operator',       'Commercial Manager',     '+910000000011', '{}', '00000000-0000-4000-8000-000000000201'),
  ('00000000-0000-4000-8000-000000000312', '00000000-0000-4000-8000-000000000312', 'operator',       'Demo Exporter Op (other client)', '+910000000012', '{}', '00000000-0000-4000-8000-000000000202')
on conflict (id) do nothing;

-- Scope A: minimal chain (T1). Scope B: processing chain with grading split (T2). Scope C: market fork (T3). All active.
insert into public.scopes (id, client_id, crop_id, season_code, geography, chain, status) values
  ('00000000-0000-4000-8000-000000000401', '00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000101',
   'KH26', 'Siddharthnagar', '{procurement,qc,qr_activation}', 'active'),
  ('00000000-0000-4000-8000-000000000402', '00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000101',
   'KH26', 'Gorakhpur', '{procurement,sorting,grading,qc,qr_activation}', 'active'),
  ('00000000-0000-4000-8000-000000000403', '00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000101',
   'KH26', 'Basti', '{procurement,qc,milling,commercial,qr_activation}', 'active')
on conflict (id) do nothing;

insert into public.slot_assignments (user_id, scope_id, stage_type)
select u, s, st from (values
  ('00000000-0000-4000-8000-000000000305'::uuid, '00000000-0000-4000-8000-000000000401'::uuid, 'procurement'::public.stage_type),
  ('00000000-0000-4000-8000-000000000306', '00000000-0000-4000-8000-000000000401', 'qc'),
  ('00000000-0000-4000-8000-000000000307', '00000000-0000-4000-8000-000000000401', 'qr_activation'),
  ('00000000-0000-4000-8000-000000000305', '00000000-0000-4000-8000-000000000402', 'procurement'),
  ('00000000-0000-4000-8000-000000000309', '00000000-0000-4000-8000-000000000402', 'sorting'),
  ('00000000-0000-4000-8000-000000000310', '00000000-0000-4000-8000-000000000402', 'grading'),
  ('00000000-0000-4000-8000-000000000306', '00000000-0000-4000-8000-000000000402', 'qc'),
  ('00000000-0000-4000-8000-000000000307', '00000000-0000-4000-8000-000000000402', 'qr_activation'),
  ('00000000-0000-4000-8000-000000000305', '00000000-0000-4000-8000-000000000403', 'procurement'),
  ('00000000-0000-4000-8000-000000000306', '00000000-0000-4000-8000-000000000403', 'qc'),
  ('00000000-0000-4000-8000-000000000308', '00000000-0000-4000-8000-000000000403', 'milling'),
  ('00000000-0000-4000-8000-000000000311', '00000000-0000-4000-8000-000000000403', 'commercial'),
  ('00000000-0000-4000-8000-000000000307', '00000000-0000-4000-8000-000000000403', 'qr_activation')
) as v(u, s, st)
on conflict do nothing;

-- Five farmers (PRD §12 sample). Created under_review, then activated by the State Manager (issues Farmer ID).
insert into public.farmers (id, client_id, scope_ids, status, name, guardian_name, village, district, phone, land_area_acres, created_by) values
  ('00000000-0000-4000-8000-000000000501', '00000000-0000-4000-8000-000000000201', '{00000000-0000-4000-8000-000000000401,00000000-0000-4000-8000-000000000402,00000000-0000-4000-8000-000000000403}', 'under_review', 'Ram Achal',    'Late Shri Ramdhani', 'Bansi',        'Siddharthnagar', '+919000000001', 2.5, '00000000-0000-4000-8000-000000000305'),
  ('00000000-0000-4000-8000-000000000502', '00000000-0000-4000-8000-000000000201', '{00000000-0000-4000-8000-000000000401,00000000-0000-4000-8000-000000000402,00000000-0000-4000-8000-000000000403}', 'under_review', 'Sita Devi',    'Shri Mahesh',        'Itwa',         'Siddharthnagar', '+919000000002', 1.8, '00000000-0000-4000-8000-000000000305'),
  ('00000000-0000-4000-8000-000000000503', '00000000-0000-4000-8000-000000000201', '{00000000-0000-4000-8000-000000000401,00000000-0000-4000-8000-000000000402,00000000-0000-4000-8000-000000000403}', 'under_review', 'Mohan Lal',    'Shri Bhola',         'Domariyaganj', 'Siddharthnagar', '+919000000003', 3.0, '00000000-0000-4000-8000-000000000305'),
  ('00000000-0000-4000-8000-000000000504', '00000000-0000-4000-8000-000000000201', '{00000000-0000-4000-8000-000000000401,00000000-0000-4000-8000-000000000402,00000000-0000-4000-8000-000000000403}', 'under_review', 'Geeta Kumari', 'Shri Ramesh',        'Naugarh',      'Siddharthnagar', '+919000000004', 2.2, '00000000-0000-4000-8000-000000000305'),
  ('00000000-0000-4000-8000-000000000505', '00000000-0000-4000-8000-000000000201', '{00000000-0000-4000-8000-000000000401,00000000-0000-4000-8000-000000000402,00000000-0000-4000-8000-000000000403}', 'under_review', 'Suresh Yadav', 'Shri Hariram',       'Shohratgarh',  'Siddharthnagar', '+919000000005', 4.1, '00000000-0000-4000-8000-000000000305')
on conflict (id) do nothing;

update public.farmers set status = 'active', verified_by = '00000000-0000-4000-8000-000000000302'
 where client_id = '00000000-0000-4000-8000-000000000201' and status = 'under_review';
