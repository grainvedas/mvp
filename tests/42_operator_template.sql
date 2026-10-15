-- Migration 48 (Veda, 15 Oct 2026: the operator-stages brief, release 1, with the Client Manager's home, menu and ledger).
-- Scope 01 (Siddharthnagar): Procurement (05) → QC (06) → QR (07). 03 is the Client Manager (manages every scope of
-- the client, holds no stage). 12 is another client's operator. Farmer 501 (PRSDM-F-0001).
begin;
select t.as_service();
create temp table fx (k text primary key, id uuid);
grant select, insert, update on fx to authenticated;
create or replace function pg_temp.f(p text) returns uuid language sql stable as $$ select id from fx where k = p $$;
create or replace function pg_temp.fp(p uuid) returns public.footprints language sql stable security definer as $$
  select * from public.footprints where id = p $$;
create or replace function pg_temp.blocks(p uuid, p_event text) returns int language sql stable security definer as $$
  select count(*)::int from public.ledger where footprint_id = p and event::text = p_event $$;
create or replace function pg_temp.last_block(p uuid) returns jsonb language sql stable security definer as $$
  select payload from public.ledger where footprint_id = p order by seq desc limit 1 $$;
create or replace function pg_temp.ret(p uuid) returns public.footprint_returns language sql stable security definer as $$
  select * from public.footprint_returns where footprint_id = p order by returned_at desc limit 1 $$;
create or replace function pg_temp.today() returns date language sql stable as $$ select (now() at time zone 'Asia/Kolkata')::date $$;
-- migration 49: verifying ticks the record's physical checks (what the receiving person sees with his own eyes)
create or replace function pg_temp.checks_of(p uuid) returns jsonb language sql stable security definer as $$
  select d.physical_checks from public.footprints f join public.stage_definitions d on d.stage_type = f.stage_type where f.id = p $$;
create or replace function pg_temp.vr(p uuid, r text default null, c text default null) returns public.footprints language sql as $$
  select app.verify_record(p, r, c, pg_temp.checks_of(p)) $$;
grant execute on all functions in schema pg_temp to authenticated;
create or replace function pg_temp.lot(p_by uuid, p_on date default null, p_reason text default null) returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.footprints (scope_id, client_id, stage_type, farmer_id, created_by, payload, happened_on, manager_reason)
  values (t.scope('01'), '00000000-0000-4000-8000-000000000201', 'procurement', '00000000-0000-4000-8000-000000000501', p_by,
          '{"gross_kg":100,"bags":2,"tare_kg_per_bag":1,"moisture_pct":[12,12,12]}', p_on, p_reason) returning id into v;
  return v;
end $$;
grant execute on function pg_temp.lot(uuid, date, text) to authenticated;

-- 1 · E4: every scope has a short code; record numbers carry it --------------------------------------------------------
select t.ok((select short_code from public.scopes where id = t.scope('01')) = 'SDR'
            and (select short_code from public.scopes where id = t.scope('06')) = 'BNS',
            'the scopes already there got a short code from their place name (Siddharthnagar SDR, Bansi BNS)');
select t.ok(app.short_code_from('gkp') = 'GKP' and app.short_code_from('Bansi') = 'BNS' and app.short_code_from('Siddharthnagar') = 'SDR',
            'gkp → GKP, Bansi → BNS, Siddharthnagar → SDR');
select t.as_user(t.u('05'));
insert into fx select 'L1', pg_temp.lot(t.u('05'));
select t.ok((pg_temp.fp(pg_temp.f('L1'))).footprint_code ~ '^PRSDM-KNM-KH26-SDR-P-[0-9]{4}$',
            'a new record''s number names its scope: ' || (pg_temp.fp(pg_temp.f('L1'))).footprint_code);
select t.as_service();
select t.ok(exists (select 1 from public.footprints where scope_id = t.scope('01') and footprint_code ~ '^PRSDM-KNM-KH26-P-')
            or not exists (select 1 from public.footprints where scope_id = t.scope('01') and created_at < now()),
            'old record numbers are not changed');
select t.fails($$update public.scopes set short_code = 'SID' where id = '00000000-0000-4000-8000-000000000401'$$,
               'in this scope''s record numbers already', 'the short code cannot change once a record number carries it');
select t.fails($$update public.scopes set short_code = 'BNS' where id = '00000000-0000-4000-8000-000000000404'$$,
               'another scope of this client', 'two scopes of one client, crop and season never share a short code');
select t.fails($$update public.scopes set short_code = 'N1' where id = '00000000-0000-4000-8000-000000000407'$$,
               'scopes_short_code_shape', 'a short code is 2 to 4 letters');
update public.scopes set short_code = 'nag' where id = t.scope('07');
select t.ok((select short_code from public.scopes where id = t.scope('07')) = 'NAG', 'unused, it may change (written in capitals)');

-- 2 · A9: the date it happened ---------------------------------------------------------------------------------------
select t.ok((pg_temp.fp(pg_temp.f('L1'))).happened_on = pg_temp.today(), 'not given, it happened today (India)');
select t.ok((pg_temp.last_block(pg_temp.f('L1')))->>'happened_on' = pg_temp.today()::text, 'the ledger block carries the date it happened');
select t.as_user(t.u('05'));
select t.fails($$select pg_temp.lot(t.u('05'), pg_temp.today() + 1)$$, 'cannot be after the day it is recorded', 'never after the day it is recorded');
select t.fails($$select pg_temp.lot(t.u('05'), pg_temp.today() - 40)$$, 'more than 31 days before', 'at most 31 days before');
insert into fx select 'L2', pg_temp.lot(t.u('05'), pg_temp.today() - 3);
select t.ok((pg_temp.fp(pg_temp.f('L2'))).happened_on = pg_temp.today() - 3, 'procured three days ago, recorded today');
update public.footprints set happened_on = pg_temp.today() - 2 where id = pg_temp.f('L2');
select t.ok((pg_temp.fp(pg_temp.f('L2'))).happened_on = pg_temp.today() - 2, 'its sender corrects the date while it is pending');

-- 3 · A10/G14: a manager records at a stage he does not hold only with a written reason ----------------------------------
select t.as_user(t.u('03'));
select t.fails($$select pg_temp.lot(t.u('03'))$$, 'only with a written reason', 'the Client Manager records at Procurement: refused without a reason');
select t.fails($$select pg_temp.lot(t.u('03'), null, 'too short')$$, 'only with a written reason', 'a reason of fewer than 10 characters is refused');
insert into fx select 'M1', pg_temp.lot(t.u('03'), null, 'operator on leave today');
select t.as_service();
select t.ok((pg_temp.fp(pg_temp.f('M1'))).manager_reason = 'operator on leave today'
            and pg_temp.blocks(pg_temp.f('M1'), 'supervisory') = 1
            and (pg_temp.last_block(pg_temp.f('M1')))->>'manager_reason' = 'operator on leave today',
            'with a reason: saved, the ledger block is "supervisory" and carries the reason');
select t.as_user(t.u('05'));
insert into fx select 'L3', pg_temp.lot(t.u('05'), null, 'an operator types a reason');
select t.as_service();
select t.ok((pg_temp.fp(pg_temp.f('L3'))).manager_reason is null, 'the stage''s own operator carries no manager reason');

-- 4 · A1/G4: return to sender ----------------------------------------------------------------------------------------
select t.as_user(t.u('06'));
select t.fails(format($$select app.return_footprint(%L, 'short')$$, pg_temp.f('L1')), 'at least 10 characters', 'a return needs a reason of 10 characters or more');
select app.return_footprint(pg_temp.f('L1'), 'moisture readings look copied');
select t.ok((pg_temp.ret(pg_temp.f('L1'))).status = 'open' and (pg_temp.fp(pg_temp.f('L1'))).status = 'pending',
            'QC returns the lot to its sender: open, the lot still pending');
select t.ok(pg_temp.blocks(pg_temp.f('L1'), 'return') = 1, 'the ledger has a "return" block');
select t.fails(format($$select pg_temp.vr(%L)$$, pg_temp.f('L1')), 'returned to its sender', 'nobody verifies it while it is returned');
select t.fails(format($$select app.return_footprint(%L, 'moisture readings look copied')$$, pg_temp.f('L1')), 'returned already', 'returned once');
select t.ok(not ((app.footprint_detail(pg_temp.f('L1')))->>'can_return')::boolean
            and jsonb_array_length((app.footprint_detail(pg_temp.f('L1')))->'returns') = 1,
            'the record page shows the return, and offers no second one');
select t.as_user(t.u('05'));
select t.fails(format($$select app.return_footprint(%L, 'returning my own lot')$$, pg_temp.f('L2')), 'correct it yourself', 'the sender does not return his own');
select t.ok((app.my_actions()->'returned'->0->>'code') = (pg_temp.fp(pg_temp.f('L1'))).footprint_code
            and (app.my_actions()->'returned'->0->>'reason') = 'moisture readings look copied'
            and (app.my_actions()->'returned'->0->>'in_place')::boolean,
            'the sender''s "needs my action": his returned lot, with the reason; it can be corrected in place');
update public.footprints set payload = '{"gross_kg":101,"bags":2,"tare_kg_per_bag":1,"moisture_pct":[12,12.2,11.9]}' where id = pg_temp.f('L1');
select t.ok((pg_temp.ret(pg_temp.f('L1'))).status = 'corrected' and pg_temp.blocks(pg_temp.f('L1'), 'return') = 2
            and jsonb_array_length(app.my_actions()->'returned') = 0,
            'he corrects it: the return is closed, the ledger says "corrected"');
select t.as_user(t.u('12'));
select t.fails(format($$select app.return_footprint(%L, 'not my client at all')$$, pg_temp.f('L2')), 'not found', 'another client''s operator does not return it');
select t.as_user(t.u('07'));
select t.fails(format($$select app.return_footprint(%L, 'QR sealer returns it')$$, pg_temp.f('L2')), 'not found', 'a later stage does not return it (it does not even read it: the thumb rule)');
select t.as_user(t.u('06'));
select t.ok((app.my_actions()->'to_verify') @> jsonb_build_array(jsonb_build_object('scope_id', t.scope('01'), 'stage', 'qc')),
            'QC''s "needs my action": records waiting at his stage');
select pg_temp.vr(pg_temp.f('L1'));
select t.ok((pg_temp.fp(pg_temp.f('L1'))).status = 'verified', 'corrected, it is verified');
-- the sender withdraws a returned record (to record it again); nobody else but a manager
select app.return_footprint(pg_temp.f('L2'), 'wrong farmer chosen here');
select t.as_user(t.u('06'));
select t.fails(format($$select app.withdraw_footprint(%L, 'not mine')$$, pg_temp.f('L2')), 'only a manager', 'the one who returned it does not withdraw it');
select t.as_user(t.u('05'));
select app.withdraw_footprint(pg_temp.f('L2'), 'recorded for the wrong farmer');
select t.ok((pg_temp.fp(pg_temp.f('L2'))).status = 'superseded' and (pg_temp.ret(pg_temp.f('L2'))).status = 'withdrawn',
            'its sender withdraws it: the return is closed as withdrawn');
select t.fails(format($$select app.withdraw_footprint(%L, 'just because')$$, pg_temp.f('L3')), 'only a manager', 'he does not withdraw a record that was not returned');

-- 5 · verify with a reason (a manager) or with a condition --------------------------------------------------------------
select t.as_user(t.u('03'));
select t.fails(format($$select pg_temp.vr(%L)$$, pg_temp.f('L3')), 'only with a written reason', 'the Client Manager verifies at QC (not his stage): refused without a reason');
select t.fails(format($$select app.verify_footprint(%L)$$, pg_temp.f('L3')), 'only with a written reason', '... also by the old door');
select pg_temp.vr(pg_temp.f('L3'), 'QC technician is on leave');
select t.ok((pg_temp.fp(pg_temp.f('L3'))).status = 'verified' and pg_temp.blocks(pg_temp.f('L3'), 'supervisory') = 1
            and (pg_temp.last_block(pg_temp.f('L3')))->>'verify_reason' = 'QC technician is on leave',
            'with a reason: verified, marked supervisory, the reason in the block');
select t.as_user(t.u('06'));
select t.fails(format($$select pg_temp.vr(%L, null, 'bags')$$, pg_temp.f('M1')), 'at least 10 characters', 'a condition is written out');
select pg_temp.vr(pg_temp.f('M1'), null, 'slip photo to be added by Friday');
select t.as_service();
select t.ok((pg_temp.fp(pg_temp.f('M1'))).status = 'verified'
            and exists (select 1 from public.flags where footprint_id = pg_temp.f('M1') and kind = 'condition' and status = 'open')
            and (pg_temp.last_block(pg_temp.f('M1')))->>'condition' = 'slip photo to be added by Friday',
            'verified with a condition: an open condition on the record, the ledger block says it');
select t.as_user(t.u('03'));
select t.ok((app.my_actions()->>'conditions')::int >= 1, 'the Client Manager''s "needs my action" counts the open condition');

-- 6 · D5: the Client Manager's ledger ----------------------------------------------------------------------------------
select t.ok((app.client_ledger_page('00000000-0000-4000-8000-000000000201', null, null, null, 50, 0)->>'total')::int > 0
            and exists (select 1 from jsonb_array_elements(app.client_ledger_page('00000000-0000-4000-8000-000000000201', 'return', null, null, 50, 0)->'rows') r
                         where r->>'note' = 'moisture readings look copied'),
            'he reads his client''s ledger, the return with its reason');
select t.as_user(t.u('05'));
select t.fails($$select app.client_ledger_page('00000000-0000-4000-8000-000000000201', null, null, null, 50, 0)$$,
               'for its Client Manager', 'an operator does not read the client''s ledger');
select t.as_user(t.u('12'));
select t.fails($$select app.client_ledger_page('00000000-0000-4000-8000-000000000201', null, null, null, 50, 0)$$,
               'for its Client Manager', 'nor another client''s people');

-- 7 · Fix 1: the farmer's history names every line ----------------------------------------------------------------------
select t.as_service();
update public.crops set gap_items = '[{"key":"seed","label":"Seed source certified","type":"yesno","required":true}]'
 where id = '00000000-0000-4000-8000-000000000101';
select t.as_user(t.u('05'));
select app.save_farmer_gap('00000000-0000-4000-8000-000000000501', '00000000-0000-4000-8000-000000000101', '{"seed": true}');
select t.ok(exists (select 1 from jsonb_array_elements(app.farmer_history('00000000-0000-4000-8000-000000000501')->'events') e
                     where e->>'kind' = 'practice_saved' and e->>'crop' = 'Kalanamak rice' and e->>'by' = 'Procurement Op (field)'),
            'the practice answered is a line of its own: crop and who');
select t.ok(exists (select 1 from jsonb_array_elements(app.farmer_history('00000000-0000-4000-8000-000000000501')->'events') e
                     where e->>'kind' = 'lot_create' and e->>'record' = (pg_temp.fp(pg_temp.f('L1'))).footprint_code)
            and not exists (select 1 from jsonb_array_elements(app.farmer_history('00000000-0000-4000-8000-000000000501')->'events') e
                             where e->>'kind' is null),
            'his lots are named lines; no line is blank');

-- 8 · the Client Manager's "needs my action": corrections and farmers ----------------------------------------------------
select app.propose_farmer_change('00000000-0000-4000-8000-000000000501', '{"notes": "TEST note 48"}', 'a note to add');
select t.as_user(t.u('03'));
select t.ok((app.my_actions()->>'proposals')::int = 1, 'a correction proposed by Procurement waits for him');
select t.ok(app.my_actions() ? 'farmers_to_verify' and app.my_actions() ? 'requirement_lines' and app.my_actions() ? 'flags',
            'farmers, requirement lines and flags are counted too');

select t.as_service();
rollback;
