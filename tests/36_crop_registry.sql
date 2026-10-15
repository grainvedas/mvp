-- Migration 42 (Veda, 13 Oct 2026, State Manager brief part C): the crop registry. Ram is the demo UP State Manager
-- (302), the Client Manager of PRSDM is 303, Procurement 305, QC 306, the admin 301; 'AS' an Assam State Manager made
-- below. Every rule is the server's: each check asks the database as the person would, through the API's own role.
begin;
select t.as_service();
create temp table fx (k text primary key, id uuid);
grant select, insert on fx to authenticated;
create or replace function pg_temp.f(p text) returns uuid language sql stable as $$ select id from fx where k = p $$;
create or replace function pg_temp.audits(p_action text, p_target uuid) returns int language sql stable security definer as $$
  select count(*)::int from public.audit_log where action = p_action and target = p_target $$;
create or replace function pg_temp.crop(p uuid) returns public.crops language sql stable security definer as $$
  select * from public.crops where id = p $$;
create or replace function pg_temp.fp(p uuid) returns public.footprints language sql stable security definer as $$
  select * from public.footprints where id = p $$;
create or replace function pg_temp.verdict(p uuid) returns public.qc_verdicts language sql stable security definer as $$
  select * from public.qc_verdicts where footprint_id = p $$;
\set UP '''00000000-0000-4000-8000-000000000001'''
\set AS '''00000000-0000-4000-8000-000000000002'''
\set PRSDM '''00000000-0000-4000-8000-000000000201'''

-- an Assam State Manager, as a script would make him
do $$ declare v uuid; begin
  insert into public.app_users (id, auth_uid, display_name, email) values
    ('00000000-0000-4000-8000-000000000c01', '00000000-0000-4000-8000-000000000c01', 'Assam State Manager', 'sm.assam2@example.com') returning id into v;
  insert into fx values ('AS', v);
  insert into public.assignments (employee_id, lens, op_role, state_id) values (v, 'state', 'state_supervisor', '00000000-0000-4000-8000-000000000002');
end $$;

-- 1 · a crop's code is unique within its state -----------------------------------------------------------------------------
select t.as_user(t.u('02'));
do $$ declare cr uuid; begin
  insert into public.crops (name, code, primary_unit, state_id) values ('Test rice', 'TSTA', 'kg', '00000000-0000-4000-8000-000000000001') returning id into cr;
  insert into fx values ('TSTA_UP', cr);
  perform t.ok(cr is not null, 'C code: Ram adds a crop of his state');
end $$;
select t.fails($q$ insert into public.crops (name, code, primary_unit, state_id) values ('Test rice again', 'TSTA', 'kg', '00000000-0000-4000-8000-000000000001') $q$,
               'crops_state_code_uidx', 'C code: not twice in one state');
select t.as_user(pg_temp.f('AS'));
do $$ declare cr uuid; begin
  insert into public.crops (name, code, primary_unit, state_id) values ('Test rice', 'TSTA', 'kg', '00000000-0000-4000-8000-000000000002') returning id into cr;
  insert into fx values ('TSTA_AS', cr);
  perform t.ok(cr is not null, 'C code: the same crop and code in another state is that state''s own entry (Veda, 13 Oct)');
end $$;

-- 2 · typed quality limits: what is refused, what is kept ------------------------------------------------------------------
select t.as_user(t.u('02'));
select t.fails(format($q$ update public.crops set quality_params = '[{"param":"aroma","label":"Aroma","type":"smell"}]' where id = %L $q$, pg_temp.f('TSTA_UP')),
               'type number, grade or yes/no', 'C limits: an unknown type is refused');
select t.fails(format($q$ update public.crops set quality_params = '[{"param":"aroma","label":"Aroma","type":"grade","options":["A","B"],"domestic_pass":["A","Z"],"export_pass":["A"]}]' where id = %L $q$, pg_temp.f('TSTA_UP')),
               'must be one or more of its grades', 'C limits: a passing grade that is not one of the grades is refused');
select t.fails(format($q$ update public.crops set quality_params = '[{"param":"aroma","label":"Aroma","type":"grade","options":["A"],"domestic_pass":["A"],"export_pass":["A"]}]' where id = %L $q$, pg_temp.f('TSTA_UP')),
               'at least two different grades', 'C limits: a grade list of one is refused');
select t.fails(format($q$ update public.crops set quality_params = '[{"param":"insects","label":"Live insects","type":"yesno"}]' where id = %L $q$, pg_temp.f('TSTA_UP')),
               'say which answer passes', 'C limits: yes/no without the passing answer is refused');
select t.fails(format($q$ update public.crops set quality_params = '[{"param":"length_mm","label":"Length","operator":"between","domestic_limit":[6,5],"export_limit":[5,6]}]' where id = %L $q$, pg_temp.f('TSTA_UP')),
               'two numbers, low to high', 'C limits: "between" high to low is refused');
select t.fails(format($q$ update public.crops set quality_params = '[{"param":"m","label":"M","operator":"<=","domestic_limit":1,"export_limit":1},{"param":"m","label":"M2","operator":"<=","domestic_limit":1,"export_limit":1}]' where id = %L $q$, pg_temp.f('TSTA_UP')),
               'twice', 'C limits: one key twice is refused');
do $$ declare n int; begin
  update public.crops set quality_params = '[
      {"param":"moisture_pct","label":"Moisture","unit":"%","operator":"<=","domestic_limit":14,"export_limit":13},
      {"param":"aroma","label":"Aroma","type":"grade","options":["A","B","C"],"domestic_pass":["A","B"],"export_pass":["A"]},
      {"param":"live_insects","label":"Live insects","type":"yesno","domestic_pass":false,"export_pass":false}]'
   where id = pg_temp.f('TSTA_UP'); get diagnostics n = row_count;
  perform t.ok(n = 1, 'C limits: a number, a grade and a yes/no are kept');
end $$;

-- 3 · the lab's verdict follows the type ------------------------------------------------------------------------------------
select t.as_service();
do $$ declare qp jsonb := (pg_temp.crop(pg_temp.f('TSTA_UP'))).quality_params; aroma jsonb; ins jsonb; num jsonb; begin
  aroma := qp->1; ins := qp->2; num := qp->0;
  perform t.ok(app.judge_typed(aroma, '{"aroma":"A"}') @> '{"value":"A","domestic":"pass","export":"pass"}', 'C verdict: grade A passes both');
  perform t.ok(app.judge_typed(aroma, '{"aroma":"B"}') @> '{"domestic":"pass","export":"fail"}', 'C verdict: grade B passes domestic, fails export');
  perform t.ok(app.judge_typed(aroma, '{"aroma":"C"}') @> '{"domestic":"fail","export":"fail"}', 'C verdict: grade C fails both');
  perform t.ok(app.judge_typed(aroma, '{}') @> '{"domestic":"pending","export":"pending"}', 'C verdict: no grade read: pending');
  perform t.ok(app.judge_typed(ins, '{"live_insects":false}') @> '{"value":false,"domestic":"pass","export":"pass"}', 'C verdict: "no live insects" passes');
  perform t.ok(app.judge_typed(ins, '{"live_insects":"yes"}') @> '{"value":true,"domestic":"fail","export":"fail"}', 'C verdict: "yes" (typed as a word) fails');
  perform t.ok(app.judge_typed(num, '{"moisture_pct":13.5}') @> '{"domestic":"pass","export":"fail"}', 'C verdict: a number as before');
  perform t.ok(app.judge_typed(num - 'type', '{"moisture_pct":"12"}') @> '{"domestic":"pass","export":"pass"}', 'C verdict: an old limit without a type is a number');
end $$;

-- 4 · good farming practice: the crop's list ----------------------------------------------------------------------------------
select t.as_user(t.u('02'));
select t.fails(format($q$ update public.crops set gap_items = '[{"key":"seed","label":"Seed","type":"colour"}]' where id = %L $q$, pg_temp.f('TSTA_UP')),
               'type date, yes/no, number, text or choice', 'C GAP: an unknown type is refused');
select t.fails(format($q$ update public.crops set gap_items = '[{"key":"seed","label":"Seed","type":"choice","options":["certified"]}]' where id = %L $q$, pg_temp.f('TSTA_UP')),
               'at least two options', 'C GAP: a choice of one is refused');
do $$ declare n int; m int := extract(month from (now() at time zone 'Asia/Kolkata'))::int; begin
  update public.crops set gap_items = '[
      {"key":"seed_source","label":"Seed source","type":"choice","options":["certified","farm_saved"],"required":true},
      {"key":"sowing_date","label":"Sowing date","type":"date","required":false}]',
    -- a harvest window that does not hold this month (two months on, for two months)
    harvest_from = ((m + 1) % 12) + 1, harvest_to = ((m + 2) % 12) + 1,
    export_docs = '{Phytosanitary certificate,Certificate of origin}'
   where id = pg_temp.f('TSTA_UP'); get diagnostics n = row_count;
  perform t.ok(n = 1, 'C GAP: Ram keeps a list of practices, a harvest window and export documents');
end $$;
select t.fails(format($q$ update public.crops set harvest_from = 3, harvest_to = null where id = %L $q$, pg_temp.f('TSTA_UP')),
               'crops_harvest_both', 'C harvest: a window has both ends');

-- 5 · recommended chain; ready -----------------------------------------------------------------------------------------------
select t.fails(format($q$ update public.crops set recommended_chain = '{procurement,milling,qc,qr_activation}' where id = %L $q$, pg_temp.f('TSTA_UP')),
               'stage milling is not allowed for this crop', 'C chain: a processing stage the crop does not allow is refused');
select t.fails(format($q$ update public.crops set recommended_chain = '{procurement,qr_activation}' where id = %L $q$, pg_temp.f('TSTA_UP')),
               'recommended chain: chain needs at least entry, qc', 'C chain: a chain without the lab is refused');
do $$ declare r jsonb; begin
  r := (select x from jsonb_array_elements(app.crop_registry()) x where x->>'id' = pg_temp.f('TSTA_UP')::text);
  perform t.ok(r->'missing' = '["yield","chain"]' and not (r->>'ready')::boolean, 'C ready: the registry says what it lacks (yield, chain)');
  perform t.ok(not exists (select 1 from jsonb_array_elements(app.crop_registry()) x where x->>'id' = pg_temp.f('TSTA_AS')::text),
               'C registry: Ram does not list another state''s crops');
  perform t.ok(exists (select 1 from jsonb_array_elements(app.crop_registry()) x where x->>'code' = 'KNM'), 'C registry: … and lists a crop with no state yet');
end $$;

-- the Client Manager's scope with this crop: made as a draft; not activated while the crop is not ready
select t.as_user(t.u('03'));
do $$ declare sc uuid; begin
  insert into public.scopes (client_id, crop_id, season_code, geography, chain, state_id)
  values ('00000000-0000-4000-8000-000000000201', pg_temp.f('TSTA_UP'), 'KH27', 'Registry test', '{procurement,qc,qr_activation}', '00000000-0000-4000-8000-000000000001')
  returning id into sc;
  insert into fx values ('SC', sc);
  update public.scopes set qc_report_required = false where id = sc;   -- migration 50: this test's lab record carries no report file
  perform t.ok(sc is not null, 'C ready: a draft scope may use a crop that is not ready yet');
end $$;
select t.fails(format($q$ update public.scopes set status = 'active' where id = %L $q$, pg_temp.f('SC')),
               'this crop is not ready: yield, chain', 'C ready: the scope is not activated while the crop lacks yield and chain');
select t.fails(format($q$ insert into public.scopes (client_id, crop_id, season_code, geography, chain, state_id, status) values (%L, %L, 'KH27', 'Straight to active', '{procurement,qc,qr_activation}', %L, 'active') $q$,
                      :PRSDM, pg_temp.f('TSTA_UP'), :UP),
               'this crop is not ready', 'C ready: nor made active at once');
select t.as_user(t.u('02'));
do $$ declare n int; begin
  update public.crops set yield_per_acre_kg = 1100, recommended_chain = '{procurement,qc,qr_activation}' where id = pg_temp.f('TSTA_UP');
  get diagnostics n = row_count;
  perform t.ok(n = 1 and (select (x->>'ready')::boolean from jsonb_array_elements(app.crop_registry()) x where x->>'id' = pg_temp.f('TSTA_UP')::text),
               'C ready: with a yield per acre and a recommended chain the crop is ready');
  perform t.ok((app.state_home('00000000-0000-4000-8000-000000000001')->'crops'->>'ready')::int >= 1, 'C ready: his overview counts his ready crops');
end $$;
select t.fails(format($q$ update public.crops set yield_per_acre_kg = 0 where id = %L $q$, pg_temp.f('TSTA_UP')), 'check constraint', 'C yield: a yield of 0 is refused');
select t.as_user(t.u('03'));
do $$ declare n int; begin
  perform app.assign(t.u('05'), 'scope', pg_temp.f('SC'), 'operator', '{procurement}', '', null);   -- migration 44: people first
  perform app.assign(t.u('06'), 'scope', pg_temp.f('SC'), 'operator', '{qc}', '', null);
  perform app.assign(t.u('07'), 'scope', pg_temp.f('SC'), 'operator', '{qr_activation}', '', null);
  update public.scopes set status = 'active' where id = pg_temp.f('SC'); get diagnostics n = row_count;
  perform t.ok(n = 1, 'C ready: the Client Manager activates the scope once the crop is ready');
end $$;

-- 6 · the farmer's practice: answered by the Client Manager; checked at Procurement ------------------------------------------
select t.as_user(t.u('05'));
select t.fails(format($q$ select t.procure_as(%L, %L, %L) $q$, pg_temp.f('SC'), t.farmer('03'), t.u('05')),
               'good farming practice not complete for this farmer (Test rice): Seed source', 'C GAP: a required practice not answered refuses the lot');
select t.as_user(t.u('02'));
select t.fails(format($q$ select app.save_farmer_gap(%L, %L, '{"seed_source":"certified"}') $q$, t.farmer('03'), pg_temp.f('TSTA_UP')),
               'filled in by the Client Manager', 'C GAP: Ram does not fill a farmer''s practice (he verifies the farmer)');
select t.as_user(t.u('03'));
select t.fails(format($q$ select app.save_farmer_gap(%L, %L, '{"seed_source":"bought"}') $q$, t.farmer('03'), pg_temp.f('TSTA_UP')),
               'one of its options', 'C GAP: an answer that is not one of the options is refused');
select t.fails(format($q$ select app.save_farmer_gap(%L, %L, '{"colour":"red"}') $q$, t.farmer('03'), pg_temp.f('TSTA_UP')),
               'is not in this crop''s list', 'C GAP: a practice that is not in the list is refused');
select t.fails(format($q$ select app.save_farmer_gap(%L, %L, '{"seed_source":"certified"}') $q$, t.farmer('03'), pg_temp.f('TSTA_AS')),
               'another state', 'C GAP: not against another state''s crop');
do $$ declare r jsonb; begin
  r := app.save_farmer_gap(t.farmer('03'), pg_temp.f('TSTA_UP'), '{"seed_source":"certified","sowing_date":""}');
  perform t.ok(r->'answers' = '{"seed_source":"certified"}' and r->'missing' = '{"required":[],"optional":["Sowing date"]}',
               'C GAP: the Client Manager answers; an empty answer is dropped; what is still open is said');
  perform t.ok(pg_temp.audits('farmer_gap_saved', t.farmer('03')) = 1, 'C GAP: the answer is in the Audit log');
  perform t.ok((select count(*) from public.farmer_gap where farmer_id = t.farmer('03')) = 1, 'C GAP: the Client Manager reads it back');
end $$;
select t.as_user(pg_temp.f('AS'));
select t.ok((select count(*) from public.farmer_gap) = 0, 'C GAP: another state''s manager reads no farmer''s practice');
select t.as_user(t.u('05'));
do $$ declare p uuid; w text[]; begin
  p := t.procure_as(pg_temp.f('SC'), t.farmer('03'), t.u('05'));
  insert into fx values ('P1', p);
  w := (pg_temp.fp(p)).warnings;
  perform t.ok(p is not null, 'C GAP: with the required practice answered the lot is saved');
  perform t.ok('good farming practice not filled: Sowing date' = any (w), 'C GAP: an optional practice not answered is a warning on the lot');
  perform t.ok(exists (select 1 from unnest(w) x where x like 'outside the harvest window (%'), 'C harvest: a lot outside the harvest window is saved with a warning');
  perform t.ok(app.preview_reconcile(pg_temp.f('SC'), 'procurement', null, '{"gross_kg":100,"bags":2,"tare_kg_per_bag":1,"moisture_pct":[12,12,12]}', t.farmer('04'))->>'error'
               like 'good farming practice not complete%', 'C GAP: the form''s preview says the same before saving');
end $$;

-- 7 · the lab record with typed readings --------------------------------------------------------------------------------------
select t.as_user(t.u('06'));
do $$ declare q uuid; v public.qc_verdicts; begin
  perform app.verify_footprint(pg_temp.f('P1'));
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (pg_temp.f('SC'), '00000000-0000-4000-8000-000000000201', 'qc', pg_temp.f('P1'), t.u('06'),
          '{"qty_kg": 97, "sample_qty_kg": 0.5, "readings": {"moisture_pct": 12.5, "aroma": "B", "live_insects": false}}') returning id into q;
  v := pg_temp.verdict(q);
  perform t.ok(v.domestic_verdict = 'pass' and v.export_verdict = 'fail', 'C verdict: the saved lab record follows the types (aroma B: domestic pass, export fail)');
  perform t.ok(v.judged @> '[{"param":"aroma","value":"B","domestic":"pass","export":"fail"},{"param":"live_insects","value":false}]', 'C verdict: each reading is kept with its own verdict');
  perform t.ok((app.preview_verdict(pg_temp.f('SC'), '{"moisture_pct": 12.5, "aroma": "B", "live_insects": false}')->>'export') = 'fail', 'C verdict: the preview says the same');
end $$;

-- 8 · the admin's three acts ---------------------------------------------------------------------------------------------------
select t.as_user(t.u('02'));
select t.fails(format($q$ select app.retire_crop(%L, 'mine') $q$, pg_temp.f('TSTA_UP')), 'only the admin', 'C admin: Ram retires no crop');
select t.fails(format($q$ select app.remove_crop(%L, 'mine') $q$, pg_temp.f('TSTA_UP')), 'only the admin', 'C admin: nor removes one');
select t.fails(format($q$ update public.crops set state_id = %L where id = %L $q$, :AS, pg_temp.f('TSTA_UP')), 'state is set once', 'C admin: nor moves his crop to another state');
do $$ declare cr uuid; begin
  insert into public.crops (name, code, primary_unit, state_id) values ('Mistake', 'MSTK', 'kg', '00000000-0000-4000-8000-000000000001') returning id into cr;
  insert into fx values ('MSTK', cr);
  insert into public.crops (name, code, primary_unit, state_id) values ('Wrong state', 'WRNG', 'kg', '00000000-0000-4000-8000-000000000001') returning id into cr;
  insert into fx values ('WRNG', cr);
end $$;
select t.as_user(t.u('01'));
select t.fails(format($q$ select app.remove_crop(%L, '') $q$, pg_temp.f('MSTK')), 'a reason is required', 'C admin: a removal needs a reason');
select t.fails(format($q$ select app.remove_crop(%L, 'added by mistake') $q$, pg_temp.f('TSTA_UP')), 'retire it instead', 'C admin: a crop in use is not removed');
do $$ begin
  perform app.remove_crop(pg_temp.f('MSTK'), 'added by mistake');
  perform t.ok(pg_temp.crop(pg_temp.f('MSTK')) is null and pg_temp.audits('crop_removed', pg_temp.f('MSTK')) = 1,
               'C admin: an unused crop is removed, and the removal is in the Audit log');
  perform app.correct_crop_state(pg_temp.f('WRNG'), '00000000-0000-4000-8000-000000000002', 'it is grown in Assam');
  perform t.ok((pg_temp.crop(pg_temp.f('WRNG'))).state_id = '00000000-0000-4000-8000-000000000002', 'C admin: corrects the state of an unused crop');
  perform t.ok(pg_temp.audits('crop_state_corrected', pg_temp.f('WRNG')) = 1 and pg_temp.audits('crop_state_set', pg_temp.f('WRNG')) = 0,
               'C admin: the correction is logged once');
end $$;
select t.fails(format($q$ select app.correct_crop_state(%L, %L, 'move it') $q$, pg_temp.f('TSTA_UP'), :AS), 'its state stays', 'C admin: a crop in use keeps its state');
do $$ declare before int := pg_temp.audits('crop_changed', pg_temp.f('TSTA_UP')); begin
  perform app.retire_crop(pg_temp.f('TSTA_UP'), 'replaced by a new variety');
  perform t.ok((pg_temp.crop(pg_temp.f('TSTA_UP'))).retired_at is not null and pg_temp.audits('crop_retired', pg_temp.f('TSTA_UP')) = 1
               and pg_temp.audits('crop_changed', pg_temp.f('TSTA_UP')) = before, 'C admin: a crop in use is retired, logged once');
end $$;
select t.fails(format($q$ select app.retire_crop(%L, 'again') $q$, pg_temp.f('TSTA_UP')), 'already retired', 'C admin: not twice');
select t.as_user(t.u('03'));
select t.fails(format($q$ insert into public.scopes (client_id, crop_id, season_code, geography, chain, state_id) values (%L, %L, 'KH28', 'After retiring', '{procurement,qc,qr_activation}', %L) $q$,
                      :PRSDM, pg_temp.f('TSTA_UP'), :UP),
               'this crop is retired', 'C retire: no new scope with a retired crop');
select t.fails(format($q$ select app.save_farmer_gap(%L, %L, '{"seed_source":"certified"}') $q$, t.farmer('04'), pg_temp.f('TSTA_UP')),
               'this crop is retired', 'C retire: no new practice answers for it');
do $$ begin
  perform t.ok((select status from public.scopes where id = pg_temp.f('SC')) = 'active', 'C retire: the scope that uses it goes on');
end $$;

-- 9 · the ledger of a state: "Signed by" lists everyone who signed its blocks --------------------------------------------------
select t.as_user(t.u('02'));
do $$ declare r jsonb; begin
  r := app.state_ledger_page('00000000-0000-4000-8000-000000000001', null, null, null, null, 500, 0);
  perform t.ok(jsonb_array_length(r->'filters'->'actors') > 0
               and (select count(distinct x->>'actor') from jsonb_array_elements(r->'rows') x where x->>'actor' is not null)
                   = (select count(*) from jsonb_array_elements(r->'filters'->'actors') a
                       where a->>'id' in (select x->>'actor' from jsonb_array_elements(r->'rows') x)),
               'ledger: every signer of his state''s blocks is offered in "Signed by"');
  perform t.ok(exists (select 1 from jsonb_array_elements(r->'filters'->'actors') a where a->>'id' = t.u('06')::text),
               'ledger: the lab operator who signed the new lot''s blocks is one of them');
end $$;

select t.as_service();
rollback;
