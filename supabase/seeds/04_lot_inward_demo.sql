-- GrainVeda MVP · seed 04: a Lot Inward scope so the second entry point can be tested end to end (execution plan §7).
-- Lot Inward → QC → QR, same client and crop as the other demo scopes, its own geography. Idempotent.

-- Never on production: this file creates demo people, farmers and scopes (migration 23 marks the production project).
do $$ begin
  if to_regprocedure('app.environment()') is not null then
    if app.environment() = 'production' then
      raise exception 'demo seed refused: this is the PRODUCTION project (use supabase/seeds/production/)';
    end if;
  end if;
end $$;

insert into public.app_users (id, auth_uid, role, display_name, phone, state_ids, client_id) values
  ('00000000-0000-4000-8000-000000000313', '00000000-0000-4000-8000-000000000313', 'operator', 'Lot Inward Operator',
   '+910000000013', '{}', '00000000-0000-4000-8000-000000000201')
on conflict (id) do nothing;

insert into public.scopes (id, client_id, crop_id, season_code, geography, chain, status) values
  ('00000000-0000-4000-8000-000000000404', '00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000101',
   'KH26', 'Gorakhpur mandi', '{lot_inward,qc,qr_activation}', 'active')
on conflict (id) do nothing;

insert into public.slot_assignments (user_id, scope_id, stage_type)
select u, s, st from (values
  ('00000000-0000-4000-8000-000000000313'::uuid, '00000000-0000-4000-8000-000000000404'::uuid, 'lot_inward'::public.stage_type),
  ('00000000-0000-4000-8000-000000000306', '00000000-0000-4000-8000-000000000404', 'qc'),
  ('00000000-0000-4000-8000-000000000307', '00000000-0000-4000-8000-000000000404', 'qr_activation')
) as v(u, s, st)
on conflict do nothing;
