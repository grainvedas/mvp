-- GrainVeda MVP · seed 05: Phase 2 demo scopes. Idempotent.
--   405 Basti mill:   Procurement → QC → Milling → Packing → Commercial → Shipment → QR   (PRD §12 T4)
--   406 Bansi batch:  Procurement → Village Batch → QC → QR                              (aggregation)
-- Packing is held by the Sorting Operator (309): a different person from milling (308), because nobody verifies a
-- lot they recorded themselves. 309 now works in two scopes (multi-slot navigation).

-- Never on production: this file creates demo people, farmers and scopes (migration 23 marks the production project).
do $$ begin
  if to_regprocedure('app.environment()') is not null then
    if app.environment() = 'production' then
      raise exception 'demo seed refused: this is the PRODUCTION project (use supabase/seeds/production/)';
    end if;
  end if;
end $$;

insert into public.app_users (id, auth_uid, role, display_name, phone, state_ids, client_id) values
  ('00000000-0000-4000-8000-000000000314', '00000000-0000-4000-8000-000000000314', 'operator', 'Shipment Operator',
   '+910000000014', '{}', '00000000-0000-4000-8000-000000000201'),
  ('00000000-0000-4000-8000-000000000315', '00000000-0000-4000-8000-000000000315', 'operator', 'Village Batch Operator',
   '+910000000015', '{}', '00000000-0000-4000-8000-000000000201')
on conflict (id) do nothing;

insert into public.scopes (id, client_id, crop_id, season_code, geography, chain, status) values
  ('00000000-0000-4000-8000-000000000405', '00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000101',
   'KH26', 'Basti mill', '{procurement,qc,milling,packing,commercial,shipment,qr_activation}', 'active'),
  ('00000000-0000-4000-8000-000000000406', '00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000101',
   'KH26', 'Bansi batch', '{procurement,village_batch,qc,qr_activation}', 'active')
on conflict (id) do nothing;

insert into public.slot_assignments (user_id, scope_id, stage_type)
select u, s, st from (values
  ('00000000-0000-4000-8000-000000000305'::uuid, '00000000-0000-4000-8000-000000000405'::uuid, 'procurement'::public.stage_type),
  ('00000000-0000-4000-8000-000000000306', '00000000-0000-4000-8000-000000000405', 'qc'),
  ('00000000-0000-4000-8000-000000000308', '00000000-0000-4000-8000-000000000405', 'milling'),
  ('00000000-0000-4000-8000-000000000309', '00000000-0000-4000-8000-000000000405', 'packing'),
  ('00000000-0000-4000-8000-000000000311', '00000000-0000-4000-8000-000000000405', 'commercial'),
  ('00000000-0000-4000-8000-000000000314', '00000000-0000-4000-8000-000000000405', 'shipment'),
  ('00000000-0000-4000-8000-000000000307', '00000000-0000-4000-8000-000000000405', 'qr_activation'),
  ('00000000-0000-4000-8000-000000000305', '00000000-0000-4000-8000-000000000406', 'procurement'),
  ('00000000-0000-4000-8000-000000000315', '00000000-0000-4000-8000-000000000406', 'village_batch'),
  ('00000000-0000-4000-8000-000000000306', '00000000-0000-4000-8000-000000000406', 'qc'),
  ('00000000-0000-4000-8000-000000000307', '00000000-0000-4000-8000-000000000406', 'qr_activation')
) as v(u, s, st)
on conflict do nothing;
