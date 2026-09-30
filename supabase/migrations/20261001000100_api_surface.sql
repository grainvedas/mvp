-- GrainVeda MVP · migration 14: close the `app` schema to everything except its intended API (SECURITY FIX)
--
-- Postgres grants EXECUTE on every new function to PUBLIC. Once `app` was exposed to the REST API (27 Sep, needed for
-- the RPCs), every function in it became callable by any visitor holding the public key, including internal ones.
-- Proven on the local stack before this migration: an anonymous POST to /rest/v1/rpc/ledger_append wrote a forged
-- "seal" block into the ledger (it hashes correctly, so verify_ledger() cannot tell it from a real one).
-- Other exposed internals: next_farmer_code / next_footprint_code (burn identifiers), derive_qc_verdict, reconcile …
--
-- Rule from here on: nothing in `app` is executable by anon/authenticated unless granted by name below.
-- tests/08_api_surface.sql fails if any function outside these lists becomes callable.

revoke execute on all functions in schema app from public, anon, authenticated;
alter default privileges in schema app revoke execute on functions from public;
grant execute on all functions in schema app to service_role;
alter default privileges in schema app grant execute on functions to service_role;

-- 1. Public API (anonymous visitors: the verify page only)
grant execute on function app.public_lot_journey(text) to anon, authenticated;

-- 2. Signed-in API (called by the app over REST)
grant execute on function app.verify_footprint(uuid)                        to authenticated;
grant execute on function app.seal_lot(uuid, uuid)                          to authenticated;
grant execute on function app.incoming_records(uuid, public.stage_type)     to authenticated;
grant execute on function app.pipeline_summary(uuid)                        to authenticated;
grant execute on function app.resolve_market_verdict(uuid)                  to authenticated;
grant execute on function app.available_qty(uuid)                           to authenticated;
grant execute on function app.verify_ledger()                               to authenticated;

-- 3. Helpers that row-level-security policies evaluate as the caller (read-only, answer only about the caller)
grant execute on function app.current_role()                                to authenticated;
grant execute on function app.current_user_id()                             to authenticated;
grant execute on function app.my_state_ids()                                to authenticated;
grant execute on function app.my_client_id()                                to authenticated;
grant execute on function app.can_access_scope(uuid)                        to authenticated;
grant execute on function app.can_access_client(uuid)                       to authenticated;
grant execute on function app.can_manage_client(uuid)                       to authenticated;
grant execute on function app.can_see_footprint(uuid, public.stage_type)    to authenticated;
grant execute on function app.farmer_access(uuid)                           to authenticated;
grant execute on function app.is_my_stage(uuid, uuid, public.stage_type)    to authenticated;

-- 4. Pure functions used by unique indexes on app_users (migration 9)
grant execute on function app.phone_key(text)                               to anon, authenticated;
grant execute on function app.email_key(text)                               to anon, authenticated;

notify pgrst, 'reload schema';
