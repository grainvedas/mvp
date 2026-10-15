-- Migration 49 (Veda, 15 Oct 2026: the operator-stages brief, release 2, "numbers you can trust"). Scope 03 (Basti):
-- Procurement (05) → QC (06) → Milling (08) → Commercial (11) → QR (07). Scope 06 (Bansi batch): Procurement (05) →
-- Village Batch (15) → QC (06) → QR (07). 02 is the State Manager of Uttar Pradesh. Farmers 501 Ram Achal, 502 Sita Devi
-- (Siddharthnagar). Crop 101 Kalanamak rice (GI 280).
begin;
select t.as_service();
create temp table fx (k text primary key, id uuid);
create temp table fxt (k text primary key, v text);
grant select, insert, update on fx, fxt to authenticated, anon;
create or replace function pg_temp.f(p text) returns uuid language sql stable as $$ select id from fx where k = p $$;
create or replace function pg_temp.fp(p uuid) returns public.footprints language sql stable security definer as $$
  select * from public.footprints where id = p $$;
create or replace function pg_temp.checks_of(p uuid) returns jsonb language sql stable security definer as $$
  select d.physical_checks from public.footprints f join public.stage_definitions d on d.stage_type = f.stage_type where f.id = p $$;
create or replace function pg_temp.last_block(p uuid) returns jsonb language sql stable security definer as $$
  select payload from public.ledger where footprint_id = p order by seq desc limit 1 $$;
create or replace function pg_temp.links(p uuid) returns jsonb language sql stable security definer as $$
  select coalesce(jsonb_agg(jsonb_build_object('parent', parent_id, 'kg', kg, 'how', how) order by kg), '[]') from public.footprint_links where child_id = p $$;
create or replace function pg_temp.farmers(p uuid) returns jsonb language sql stable security definer as $$ select app.lot_farmers(p) $$;
create or replace function pg_temp.gi(p uuid) returns text language sql stable security definer as $$ select app.lot_gi_status(p) $$;
grant execute on all functions in schema pg_temp to authenticated, anon;
create or replace function pg_temp.qc(p_scope uuid, p_src uuid, p_kg numeric) returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (p_scope, '00000000-0000-4000-8000-000000000201', 'qc', p_src, t.u('06'),
          jsonb_build_object('qty_kg', p_kg, 'sample_qty_kg', 1, 'readings', jsonb_build_object('moisture_pct', 11.8, 'broken_pct', 2, 'foreign_matter_pct', 0.2)))
  returning id into v; return v;
end $$;
create or replace function pg_temp.mill(p_src uuid, p_in numeric, p_rice numeric) returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('03'), '00000000-0000-4000-8000-000000000201', 'milling', p_src, t.u('08'),
          jsonb_build_object('input_kg', p_in, 'rice_kg', p_rice, 'bran_kg', p_in - p_rice - 1, 'loss_kg', 1))
  returning id into v; return v;
end $$;
grant execute on all functions in schema pg_temp to authenticated;

-- 1 · A2/G3: the receiver ticks only what he sees; the system answers the rest ---------------------------------------------
select t.ok(jsonb_array_length((select physical_checks from public.stage_definitions where stage_type = 'procurement')) = 3
            and not ((select physical_checks from public.stage_definitions where stage_type = 'procurement') ? 'Net quantity reviewed'),
            'Procurement hands over three things to see (bags counted, sound grain, tags), none of them a number the system has');
insert into fx select 'P1', t.procure(t.scope('03'), t.farmer('01'), 126, 3, 2, 12, 12, 12);              -- 120 kg
select t.as_user(t.u('06'));
select t.ok((app.stage_form(t.scope('03'), 'qc')->'prev_stage'->'physical_checks') = (select physical_checks from public.stage_definitions where stage_type = 'procurement'),
            'the QC form gives Procurement''s physical checks to tick');
select t.ok((select bool_and((c->>'ok')::boolean) from jsonb_array_elements(app.system_checks(pg_temp.f('P1'))) c)
            and (select count(*) from jsonb_array_elements(app.system_checks(pg_temp.f('P1'))) c
                  where c->>'key' in ('farmer_active', 'moisture_three', 'net_worked_out', 'practice_complete', 'no_open_flags')) = 5,
            'the system checks the farmer, the three readings, the net weight, the practice and the flags itself');
select t.fails(format($$select app.verify_record(%L)$$, pg_temp.f('P1')), 'tick what you checked', 'verifying without the ticks is refused');
select t.fails(format($$select app.verify_record(%L, null, null, '["Bags tagged with the lot number"]')$$, pg_temp.f('P1')),
               'Bags counted', 'a check left out is named');
select app.verify_record(pg_temp.f('P1'), null, null, pg_temp.checks_of(pg_temp.f('P1')));
select t.ok((pg_temp.fp(pg_temp.f('P1'))).status = 'verified'
            and (pg_temp.last_block(pg_temp.f('P1')))->'checked' = pg_temp.checks_of(pg_temp.f('P1')),
            'all ticked: verified, and the ledger keeps what he ticked');

-- 2 · A3/G2: what is left of a lot is shown, after part of it is used ---------------------------------------------------------
select t.as_service();
insert into fx select 'Q1', pg_temp.qc(t.scope('03'), pg_temp.f('P1'), 120);                                -- 119 kg out
select t.as_user(t.u('08'));
select app.verify_record(pg_temp.f('Q1'), null, null, pg_temp.checks_of(pg_temp.f('Q1')));
insert into fx select 'M1', pg_temp.mill(pg_temp.f('Q1'), 60, 40);
select t.ok((select (r->>'available_kg')::numeric from jsonb_array_elements(app.incoming_lots(t.scope('03'), 'milling')) r where r->>'id' = pg_temp.f('Q1')::text) = 59,
            'the Mill sees what is left on the lab lot after his first run: 59 kg of 119');
select t.ok((select (r->>'made_by_me')::boolean = false and r->>'maker_name' = 'QC Technician' and (r->>'farmer_count')::int = 1
               from jsonb_array_elements(app.incoming_lots(t.scope('03'), 'milling')) r where r->>'id' = pg_temp.f('Q1')::text),
            'each waiting lot says who made it and how many farmers are in it');

-- 3 · E: lineage, shares and GI --------------------------------------------------------------------------------------------
select t.as_service();
select t.ok(pg_temp.links(pg_temp.f('M1')) = jsonb_build_array(jsonb_build_object('parent', pg_temp.f('Q1'), 'kg', 60.000, 'how', 'input')),
            'a run is linked to its source with the kilograms it took (60 of 119)');
select t.ok((pg_temp.farmers(pg_temp.f('M1'))->0->>'name') = 'Ram Achal' and (pg_temp.farmers(pg_temp.f('M1'))->0->>'share_pct')::numeric = 100
            and (pg_temp.farmers(pg_temp.f('M1'))->0->>'kg')::numeric = 40,
            'the farmers of the rice: Ram Achal, 100 % of its 40 kg');
select t.ok(pg_temp.gi(pg_temp.f('M1')) = 'unknown', 'GI not known while the crop has no GI districts');
update public.crops set gi_districts = array['Siddharth Nagar', 'Basti', 'Gorakhpur'] where id = '00000000-0000-4000-8000-000000000101';
select t.ok(pg_temp.gi(pg_temp.f('M1')) = 'gi', 'with the GI area set, his district (written differently) is matched: GI');
-- a batch of two lots of one farmer and one of another, one of them outside the GI area
insert into fx select 'A', t.procure(t.scope('06'), t.farmer('01'), 126, 3, 2, 12, 12, 12);             -- 120
insert into fx select 'B', t.procure(t.scope('06'), t.farmer('01'), 66, 3, 2, 12, 12, 12);              -- 60
insert into fx select 'C', t.procure(t.scope('06'), t.farmer('02'), 126, 3, 2, 12, 12, 12);             -- 120
select t.as_user(t.u('15'));
select app.verify_footprint(pg_temp.f('A')); select app.verify_footprint(pg_temp.f('B')); select app.verify_footprint(pg_temp.f('C'));
insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
values (t.scope('06'), '00000000-0000-4000-8000-000000000201', 'village_batch', pg_temp.f('A'), t.u('15'),
        jsonb_build_object('village', 'Bansi', 'source_footprint_ids', jsonb_build_array(pg_temp.f('A'), pg_temp.f('B'), pg_temp.f('C'))));
select t.as_service();
insert into fx select 'VB', id from public.footprints where stage_type = 'village_batch' and prev_footprint_id = pg_temp.f('A');
select t.ok(jsonb_array_length(pg_temp.links(pg_temp.f('VB'))) = 3, 'a batch is linked to each of its lots, whole');
select t.ok(jsonb_array_length(pg_temp.farmers(pg_temp.f('VB'))) = 2
            and (select (x->>'share_pct')::numeric from jsonb_array_elements(pg_temp.farmers(pg_temp.f('VB'))) x where x->>'name' = 'Ram Achal') = 60,
            'two farmers, not three lots (G6): Ram Achal 60 % (180 of 300 kg), Sita Devi 40 %');
select t.ok(pg_temp.gi(pg_temp.f('VB')) = 'gi', 'every lot from the GI area: the batch is GI');
update public.farmers set district = 'Lucknow' where id = '00000000-0000-4000-8000-000000000502';
select t.ok(pg_temp.gi(pg_temp.f('VB')) = 'non_gi', 'one lot from outside the GI area: the batch is not GI');
update public.farmers set district = 'Siddharthnagar' where id = '00000000-0000-4000-8000-000000000502';
select t.ok((select count(*) from public.footprint_links where from_older) = 0, 'a database built from nothing has no older links');

-- 4 · A7/G5: no fixed threshold; the crop's ceiling; the range its own runs have shown -------------------------------------
select t.ok(not exists (select 1 from unnest((pg_temp.fp(pg_temp.f('M1'))).warnings) w where w like 'outturn%' or w like 'yield below%'),
            'a 67 % outturn is not warned by a fixed number');
select t.as_user(t.u('08'));
select t.ok(exists (select 1 from jsonb_array_elements_text(app.preview_reconcile(t.scope('03'), 'milling', pg_temp.f('Q1'),
              '{"input_kg": 10, "rice_kg": 7.5, "bran_kg": 1.5, "loss_kg": 1}', null, false, null, false)->'warnings') w
              where w like 'outturn 75.0 % is above the crop''s ceiling of 70 %%'),
            '75 % is above the crop''s ceiling (70 % unless set): the State Manager is told');
select t.as_service();
update public.crops set thresholds = '{"milling_outturn_ceiling_pct": 80, "learn_after_runs": 3}' where id = '00000000-0000-4000-8000-000000000101';
select t.as_user(t.u('08'));
select t.ok(not exists (select 1 from jsonb_array_elements_text(app.preview_reconcile(t.scope('03'), 'milling', pg_temp.f('Q1'),
              '{"input_kg": 10, "rice_kg": 7.5, "bran_kg": 1.5, "loss_kg": 1}', null, false, null, false)->'warnings') w where w like 'outturn%'),
            'the ceiling is the crop''s: at 80 %, 75 % is not warned');
-- three verified runs at about 66 % make a range; then 75 % is outside it
insert into fx select 'M2', pg_temp.mill(pg_temp.f('Q1'), 15, 10);
insert into fx select 'M3', pg_temp.mill(pg_temp.f('Q1'), 15, 9.9);
select t.as_user(t.u('11'));
select app.verify_record(pg_temp.f('M1'), null, null, pg_temp.checks_of(pg_temp.f('M1')));
select app.verify_record(pg_temp.f('M2'), null, null, pg_temp.checks_of(pg_temp.f('M2')));
select app.verify_record(pg_temp.f('M3'), null, null, pg_temp.checks_of(pg_temp.f('M3')));
select t.as_user(t.u('08'));
select t.ok(exists (select 1 from jsonb_array_elements_text(app.preview_reconcile(t.scope('03'), 'milling', pg_temp.f('Q1'),
              '{"input_kg": 10, "rice_kg": 7.5, "bran_kg": 1.5, "loss_kg": 1}', null, false, null, false)->'warnings') w
              where w like 'outturn 75.0 % is outside the usual range of this crop%from 3 verified runs)'),
            'after its own runs (3 here, 10 unless set), an outturn far from them is warned with their range');
-- the State Manager sees runs above the ceiling
select t.as_service();
update public.crops set thresholds = '{}' where id = '00000000-0000-4000-8000-000000000101';
select t.as_user(t.u('08'));
insert into fx select 'M4', pg_temp.mill(pg_temp.f('Q1'), 10, 7.5);
select t.as_user(t.u('02'));
select t.ok((app.my_actions()->>'outturn_review')::int = 1, 'the State Manager''s "Needs my action": one run above the ceiling');
select t.as_user(t.u('03'));
select t.ok((app.my_actions()->>'outturn_review')::int = 0, 'the Client Manager is not asked (it is the State Manager''s to look at)');

-- 5 · G6 on the public page: farmers counted once; the GI status ----------------------------------------------------------
select t.as_user(t.u('06'));
select app.verify_record(pg_temp.f('VB'), null, null, pg_temp.checks_of(pg_temp.f('VB')));
insert into fx select 'Q2', pg_temp.qc(t.scope('06'), pg_temp.f('VB'), 300);
select t.as_user(t.u('07'));
select app.verify_record(pg_temp.f('Q2'), null, null, pg_temp.checks_of(pg_temp.f('Q2')));
insert into fxt select 'S', (app.seal_source(pg_temp.f('Q2'))).qr_code;
select t.as_anon();
select t.ok((app.public_lot_journey((select v from fxt where k = 'S'))->>'farmer_count')::int = 2
            and (select jsonb_array_length(e->'farmers') from jsonb_array_elements(app.public_lot_journey((select v from fxt where k = 'S'))->'journey') e
                  where e->>'stage' = 'village_batch') = 2
            and app.public_lot_journey((select v from fxt where k = 'S'))->>'gi_status' = 'gi',
            'the public page: 2 farmers (not 3 lots), one line each, and the GI status');
select t.as_service();
rollback;
