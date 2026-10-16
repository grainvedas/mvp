-- GrainVeda MVP · migration 55a: the Warehouse stage type (release 8 of the operator-stages plan, C3; Veda, 16 Oct 2026,
-- "yes proceed"). A new value of public.stage_type, in a migration of its own: a value added to an enum cannot be used in
-- the transaction that adds it, and every migration is one transaction. Migration 55 uses it. Nothing else changes here.
select set_config('app.change_path', 'migration 55a', true);
alter type public.stage_type add value if not exists 'warehouse' before 'milling';
