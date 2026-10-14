-- Migration 46 (Veda, 14 Oct 2026, "GrainVeda MVP — HR requirements list and staffing a scope"): requirements and their
-- lines, raised by themselves from a scope's empty stages (when its People step is saved) and for a client with no Client
-- Manager, by hand by the Client Manager (his scope) and the State Manager (his state); HR's queue (publish as one opening
-- group with corrections logged, return, decline, hold; her states only, the HR Admin all); what the requester sees
-- (each line's status, the people ready for it first in the pool); openings that say where they came from; and one
-- person on two stages in a row (allowed: he verifies his own record; the ledger, the public page and the counts say so).
-- 303 the Prasaadam Client Manager, 302 the UP State Manager, 317 HR for UP, 316 the HR Admin, 305 the field operator.
begin;
select t.as_service();
create temp table fx (k text primary key, id uuid);
grant select, insert, update on fx to authenticated; grant select on fx to anon;
create or replace function pg_temp.f(p text) returns uuid language sql stable as $$ select id from fx where k = p $$;
create or replace function pg_temp.lines(p_scope uuid) returns setof public.requirement_lines language sql stable security definer as $$
  select l.* from public.requirement_lines l join public.requirements r on r.id = l.requirement_id where r.scope_id = p_scope order by l.created_at $$;
create or replace function pg_temp.line(p_scope uuid, p_stage text) returns public.requirement_lines language sql stable security definer as $$
  select l.* from public.requirement_lines l join public.requirements r on r.id = l.requirement_id
   where r.scope_id = p_scope and l.stage::text = p_stage
   order by l.status in ('requested', 'returned', 'held', 'published') desc, l.auto, l.created_at desc limit 1 $$;
create or replace function pg_temp.audits(p_action text) returns int language sql stable security definer as $$
  select count(*)::int from public.audit_log where action = p_action $$;
create or replace function pg_temp.requested_in(p_state uuid) returns int language sql stable security definer as $$
  select count(*)::int from public.requirement_lines l join public.requirements r on r.id = l.requirement_id
   where l.status = 'requested' and r.state_id = p_state $$;
create or replace function pg_temp.lid(p_kind text) returns uuid language sql stable security definer as $$
  select l.id from public.requirement_lines l join public.requirements r on r.id = l.requirement_id where r.kind = p_kind order by l.created_at limit 1 $$;
grant execute on all functions in schema pg_temp to authenticated;

-- 1 · a scope's empty stages become lines when its People step is saved ---------------------------------------------------
select t.as_user(t.u('03'));
with x as (insert into public.scopes (client_id, crop_id, season_code, geography, chain, status)
  values ('00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000101', 'KH26', 'gkp (test 40)',
          '{procurement,qc,milling,packing,qr_activation}', 'draft') returning id)
insert into fx select 'S', id from x;
select t.ok((select count(*) from pg_temp.lines(pg_temp.f('S'))) = 0, 'a draft scope alone raises no lines (its People step is not saved yet)');
select app.save_people_step(pg_temp.f('S'));
select t.ok((select count(*) from pg_temp.lines(pg_temp.f('S')) where status = 'requested' and auto and role = 'operator' and positions = 1) = 5,
            'saving the People step raises one Requested line per empty stage (5)');
select t.ok((select bool_and(needed_by = current_date + 14) from pg_temp.lines(pg_temp.f('S'))), 'each needed by in two weeks unless said otherwise');
select t.as_service();
select t.ok((select raised_by from public.requirements where scope_id = pg_temp.f('S')) = t.u('03'), 'in the name of the Client Manager who saved it');
select t.ok(pg_temp.audits('requirement_line_raised') >= 5, 'every line raised is in the Audit log');
select t.as_user(t.u('03'));
select app.save_people_step(pg_temp.f('S'));
select t.ok((select count(*) from pg_temp.lines(pg_temp.f('S'))) = 5, 'saving it again raises nothing twice');
select t.ok(jsonb_array_length(app.scope_requirement(pg_temp.f('S'))->'lines') = 5
            and (app.scope_requirement(pg_temp.f('S'))->'lines'->0->>'shown') = 'requested'
            and (app.scope_requirement(pg_temp.f('S'))->>'can_request')::boolean,
            'the People step reads each line and its status; he may ask for more');

-- a stage gets a person: its line closes "filled from the pool"
select app.assign(t.u('05'), 'scope', pg_temp.f('S'), 'operator', '{procurement}', '', null);
select t.ok((pg_temp.line(pg_temp.f('S'), 'procurement')).status = 'filled'
            and (pg_temp.line(pg_temp.f('S'), 'procurement')).status_reason = 'filled from the pool',
            'a stage given a person from the pool: its line closes, "filled from the pool"');
-- the chain changes: a stage that leaves closes its line; one that comes back gets a new line
update public.scopes set chain = '{procurement,qc,milling,qr_activation}' where id = pg_temp.f('S');
select t.ok((pg_temp.line(pg_temp.f('S'), 'packing')).status = 'withdrawn'
            and (pg_temp.line(pg_temp.f('S'), 'packing')).status_reason = 'the chain no longer has this stage',
            'a stage taken out of the chain: its line is withdrawn, with why');
update public.scopes set chain = '{procurement,qc,milling,packing,qr_activation}' where id = pg_temp.f('S');
select t.ok((pg_temp.line(pg_temp.f('S'), 'packing')).status = 'requested', 'put back: a new line for it');
select t.as_service();
select t.ok(pg_temp.audits('requirement_line_filled') >= 1 and pg_temp.audits('requirement_line_closed') >= 1, 'closing a line is in the Audit log');

-- 2 · a client with no Client Manager: a line in the State Manager's name ------------------------------------------------
select app.sync_client_requirement('00000000-0000-4000-8000-000000000202');
select t.ok((select l.role = 'client_manager' and l.status = 'requested' and r.raised_by = t.u('02') and l.auto
               from public.requirements r join public.requirement_lines l on l.requirement_id = r.id
              where r.kind = 'client' and r.client_id = '00000000-0000-4000-8000-000000000202'),
            'a client with no Client Manager: a Client Manager line, raised in the State Manager''s name');
select app.sync_client_requirement('00000000-0000-4000-8000-000000000202');
select t.ok((select count(*) from public.requirement_lines l join public.requirements r on r.id = l.requirement_id
              where r.client_id = '00000000-0000-4000-8000-000000000202' and r.kind = 'client') = 1, 'and only once');
select t.ok((select count(*) from public.requirements where kind = 'client' and client_id = '00000000-0000-4000-8000-000000000201') = 0,
            'a client with its Client Manager gets none');

-- 3 · by hand ------------------------------------------------------------------------------------------------------------
select t.as_user(t.u('03'));
select app.request_people(jsonb_build_object('scope_id', pg_temp.f('S'), 'lines', jsonb_build_array(
  jsonb_build_object('role', 'operator', 'stage', 'milling', 'positions', 2, 'posting', 'Gorakhpur mill', 'note', 'two shifts'))));
select t.ok((select count(*) from pg_temp.lines(pg_temp.f('S')) where not auto and stage = 'milling' and positions = 2 and posting = 'Gorakhpur mill') = 1,
            'the Client Manager asks for more people for his scope by hand');
select t.fails($$select app.request_people(jsonb_build_object('scope_id', pg_temp.f('S'), 'lines', jsonb '[{"role":"operator","stage":"shipment","positions":1}]'))$$,
               'chain', 'a stage that is not in the chain is refused');
select t.fails($$select app.request_people(jsonb_build_object('scope_id', pg_temp.f('S'), 'lines', jsonb '[{"role":"operator","stage":"qc","positions":0}]'))$$,
               '1 to 500', 'a number of people below 1 is refused');
select t.fails($$select app.request_people(jsonb_build_object('scope_id', pg_temp.f('S'), 'lines', jsonb_build_array(jsonb_build_object('role','operator','stage','qc','positions',1,'needed_by', current_date - 1))))$$,
               'today or later', 'a needed-by date in the past is refused');
select t.fails($$select app.request_people(jsonb_build_object('state_id', '00000000-0000-4000-8000-000000000001', 'lines', jsonb '[{"role":"other","positions":1}]'))$$,
               'State Manager', 'the Client Manager does not raise a state''s requirement');
select t.as_user(t.u('12'));
select t.fails($$select app.request_people(jsonb_build_object('scope_id', pg_temp.f('S'), 'lines', jsonb '[{"role":"operator","stage":"qc","positions":1}]'))$$,
               'Client Manager', 'someone else cannot ask for this scope''s people');
select t.fails($$select app.scope_requirement(pg_temp.f('S'))$$, 'not your scope', 'nor read its requirement');
select t.as_user(t.u('02'));
select app.request_people(jsonb_build_object('state_id', '00000000-0000-4000-8000-000000000001', 'note', 'harvest',
  'lines', jsonb '[{"role":"other","positions":3,"note":"drivers"}]'));
select t.ok(exists (select 1 from jsonb_array_elements(app.state_requirements('00000000-0000-4000-8000-000000000001')) r
                     where r->>'kind' = 'state' and r->'lines'->0->>'note' = 'drivers'),
            'the State Manager asks for his state; his home shows the open requirements');
select t.ok(exists (select 1 from jsonb_array_elements(app.state_requirements('00000000-0000-4000-8000-000000000001')) r
                     where r->>'scope_id' = pg_temp.f('S')::text),
            'by client: the scope''s requirement is there too');
select t.fails($$select app.request_people(jsonb_build_object('state_id', '00000000-0000-4000-8000-000000000002', 'lines', jsonb '[{"role":"other","positions":1}]'))$$,
               'State Manager', 'not for a state that is not his');

-- an Assam scope's lines (for the HR of another state)
select t.as_user(t.u('03'));
select app.save_people_step('00000000-0000-4000-8000-000000000407');
select t.ok((select count(*) from pg_temp.lines('00000000-0000-4000-8000-000000000407')) = 3, 'the Assam draft''s three empty stages: three lines');

-- 4 · HR's queue ---------------------------------------------------------------------------------------------------------
select t.as_user(t.u('17'));
select t.ok((app.hr_requirement_counts()->>'new')::int = pg_temp.requested_in('00000000-0000-4000-8000-000000000001')
            and (app.hr_requirement_counts()->>'oldest_days')::int = 0, 'HR''s figure: the new lines of her states, and the oldest''s age in days');
select t.ok(not exists (select 1 from jsonb_array_elements(app.hr_requirements()->'groups') g where g->>'state_id' = '00000000-0000-4000-8000-000000000002'),
            'HR sees her own states only (no Assam)');
select t.ok(exists (select 1 from jsonb_array_elements(app.hr_requirements(jsonb_build_object('scope_id', pg_temp.f('S')))->'groups') g
                     where jsonb_array_length(g->'lines') = 5),
            'filtered to the scope: its five open lines (four left of the raised ones, and the one by hand)');
select t.ok(jsonb_array_length(app.hr_requirements(jsonb_build_object('role', 'client_manager'))->'groups') = 1, 'filtered by role');
select t.fails(format($$select app.decide_lines(array[%L]::uuid[], 'publish')$$, (pg_temp.line('00000000-0000-4000-8000-000000000407', 'qc')).id),
               'not yours', 'she cannot publish a line of a state that is not hers');
select t.fails(format($$select app.decide_lines(array[%L]::uuid[], 'return')$$, (pg_temp.line(pg_temp.f('S'), 'qc')).id),
               'question', 'returning needs the question');
select t.fails(format($$select app.decide_lines(array[%L]::uuid[], 'decline', 'no')$$, (pg_temp.line(pg_temp.f('S'), 'qc')).id),
               'why', 'declining needs a reason');
-- return with a question; the Client Manager answers; it waits for HR again
select app.decide_lines(array[(pg_temp.line(pg_temp.f('S'), 'qc')).id], 'return', 'One QC technician or two?');
select t.ok((pg_temp.line(pg_temp.f('S'), 'qc')).status = 'returned', 'returned with her question');
select t.as_user(t.u('03'));
select app.requester_act((pg_temp.line(pg_temp.f('S'), 'qc')).id, 'answer', '{"answer":"One is enough","positions":1}');
select t.ok((pg_temp.line(pg_temp.f('S'), 'qc')).status = 'requested', 'answered: Requested again');
select t.as_user(t.u('17'));
-- publish the whole scope in one act, one line corrected: one opening group, "requested by" the Client Manager
insert into fx values ('M2', (select id from pg_temp.lines(pg_temp.f('S')) where not auto));
select app.decide_lines(array(select id from pg_temp.lines(pg_temp.f('S')) where status = 'requested'), 'publish', null,
  jsonb_build_object(pg_temp.f('M2')::text, jsonb_build_object('positions', 3)));
select t.as_service();
select t.ok((select count(*) from public.openings o join public.requirement_lines l on l.opening_id = o.id
              join public.requirements r on r.id = l.requirement_id where r.scope_id = pg_temp.f('S')) = 5
            and (select count(distinct o.group_id) from public.openings o join public.requirement_lines l on l.opening_id = o.id
                   join public.requirements r on r.id = l.requirement_id where r.scope_id = pg_temp.f('S')) = 1,
            'publishing the whole scope in one act: one opening (a group, a line per stage), nothing retyped');
select t.ok((select bool_and(o.source = 'requirement' and o.requested_by = t.u('03') and o.requirement_line_id = l.id and o.scope_id = pg_temp.f('S')
                             and o.group_title = 'Kalanamak rice · KH26 · gkp (test 40)' and o.code like 'UP-OPR-%')
               from public.openings o join public.requirement_lines l on l.opening_id = o.id where l.requirement_id = (select id from public.requirements where scope_id = pg_temp.f('S'))),
            'each part says where it came from: the requirement line, requested by the Client Manager, linked back');
select t.ok((select positions from public.openings where requirement_line_id = pg_temp.f('M2')) = 3
            and (select positions from public.requirement_lines where id = pg_temp.f('M2')) = 3
            and pg_temp.audits('requirement_line_corrected') = 1, 'her correction (2 → 3 people) is on both, and in the Audit log');
select t.ok((select bool_and(status = 'published') from pg_temp.lines(pg_temp.f('S')) where status not in ('filled', 'withdrawn')),
            'the lines are Published');
select t.ok((app.opening_json((select o from public.openings o where o.requirement_line_id = pg_temp.f('M2')))->>'requested_by_name') = 'Prasaadam Client Manager'
            and (app.opening_json((select o from public.openings o where o.requirement_line_id = pg_temp.f('M2')))->>'source') = 'requirement',
            'the opening reads "From requirement by" its requester');
select t.ok(not exists (select 1 from public.openings where requirement_line_id is null and source <> 'hr')
            and (select column_default from information_schema.columns where table_schema = 'public' and table_name = 'openings' and column_name = 'source') like '''hr''%',
            'openings made before (and by HR by hand) are "Created by HR"');
select t.as_user(t.u('17'));
select t.fails(format($$select app.decide_lines(array[%L]::uuid[], 'decline', 'not needed')$$, pg_temp.f('M2')),
               'published', 'a published line is not declined');
-- decline and hold, with reasons; a declined raised line is not raised again by itself
select app.decide_lines(array[pg_temp.lid('state')], 'hold', 'after the harvest plan');
select t.ok((app.hr_requirements(jsonb_build_object('status', 'held'))->'groups'->0->'lines'->0->>'reason') = 'after the harvest plan', 'held, with the reason');
select app.decide_lines(array[pg_temp.lid('client')], 'decline', 'the State Manager covers DEMOX this season');
select t.as_service();
select app.sync_client_requirement('00000000-0000-4000-8000-000000000202');
select t.ok((select count(*) from public.requirement_lines l join public.requirements r on r.id = l.requirement_id where r.kind = 'client') = 1
            and (select status from public.requirement_lines l join public.requirements r on r.id = l.requirement_id where r.kind = 'client') = 'declined',
            'declined, with the reason; not raised again by itself');
select t.ok(pg_temp.audits('requirement_line_published') = 5 and pg_temp.audits('requirement_line_returned') = 1
            and pg_temp.audits('requirement_line_answered') = 1 and pg_temp.audits('requirement_line_declined') = 1
            and pg_temp.audits('requirement_line_held') = 1, 'every status change is a line in the Audit log');
select t.as_user(t.u('03'));
select t.fails(format($$select app.decide_lines(array[%L]::uuid[], 'publish')$$, (pg_temp.line(pg_temp.f('S'), 'qc')).id),
               'only HR', 'the Client Manager does not decide');
-- the HR Admin sees every state
select t.as_user(t.u('16'));
select t.ok(exists (select 1 from jsonb_array_elements(app.hr_requirements()->'groups') g where g->>'state_id' = '00000000-0000-4000-8000-000000000002'),
            'the HR Admin sees all states');

-- 5 · what the requester sees: Joining, Ready to assign, first in the pool ------------------------------------------------
select t.as_service();
insert into fx values ('OQC', (pg_temp.line(pg_temp.f('S'), 'qc')).opening_id),
                      ('OMIL', (select opening_id from pg_temp.lines(pg_temp.f('S')) where auto and stage = 'milling'));
update public.employee_org set opening_id = pg_temp.f('OQC') where employee_id = t.u('19');       -- Meera: still joining
update public.employee_org set opening_id = pg_temp.f('OMIL') where employee_id = t.u('18');      -- Ravi: joined, not placed
select t.as_user(t.u('03'));
select t.ok((select l->>'shown' from jsonb_array_elements(app.scope_requirement(pg_temp.f('S'))->'lines') l where l->>'stage' = 'qc') = 'joining'
            and (select l->'joining'->0->>'name' from jsonb_array_elements(app.scope_requirement(pg_temp.f('S'))->'lines') l where l->>'stage' = 'qc') = 'Meera Joshi',
            'a line with someone still joining on its opening reads Joining, with the name');
select t.ok((select l->>'shown' from jsonb_array_elements(app.scope_requirement(pg_temp.f('S'))->'lines') l where l->>'stage' = 'milling' and (l->>'auto')::boolean) = 'ready'
            and (select l->'ready'->0->>'name' from jsonb_array_elements(app.scope_requirement(pg_temp.f('S'))->'lines') l where l->>'stage' = 'milling' and (l->>'auto')::boolean) = 'Ravi Kumar',
            'joined and not placed yet: Ready to assign, with the name');
select t.ok((app.roster_pool(pg_temp.f('S'))->0->>'name') = 'Ravi Kumar' and (app.roster_pool(pg_temp.f('S'))->0->>'ready_for') = 'milling',
            'Ready-to-assign people come first in the pool, with the stage they are for');
select app.assign(t.u('18'), 'scope', pg_temp.f('S'), 'operator', '{milling}', '', null);
select t.ok((select status from pg_temp.lines(pg_temp.f('S')) where auto and stage = 'milling') = 'filled',
            'assigned: the line is Filled');
select t.ok(coalesce((select x->>'ready_for' from jsonb_array_elements(app.roster_pool(pg_temp.f('S'))) x where x->>'name' = 'Ravi Kumar'), '') = '',
            'and he is no longer shown as ready for it');
-- the requester withdraws a line he no longer needs
select app.request_people(jsonb_build_object('scope_id', pg_temp.f('S'), 'lines', jsonb '[{"role":"export_manager","positions":1}]'));
select app.requester_act((select id from pg_temp.lines(pg_temp.f('S')) where role = 'export_manager'), 'withdraw', '{"reason":"the client ships himself"}');
select t.ok((select status from pg_temp.lines(pg_temp.f('S')) where role = 'export_manager') = 'withdrawn', 'the requester withdraws a line');

-- 6 · a manual opening for several stages of one scope -------------------------------------------------------------------
select t.as_user(t.u('17'));
select t.ok(jsonb_array_length(app.save_openings(jsonb_build_object('state_id', '00000000-0000-4000-8000-000000000001', 'role', 'operator',
              'scope_id', t.scope('05'), 'stages', jsonb '["milling","packing"]', 'positions', 1))) = 2, 'HR makes one opening for two stages of a scope at once');
select t.as_service();
select t.ok((select count(distinct group_id) = 1 and count(*) = 2 and bool_and(source = 'hr' and client_id = '00000000-0000-4000-8000-000000000201'
                    and group_title = 'Kalanamak rice · KH26 · Basti mill')
               from public.openings where scope_id = t.scope('05') and stage in ('milling', 'packing') and requirement_line_id is null),
            'one group, the scope''s client filled in, "Created by HR"');
select t.as_user(t.u('17'));
select t.fails($$select app.save_openings(jsonb_build_object('state_id', '00000000-0000-4000-8000-000000000001', 'role', 'client_manager', 'stages', jsonb '["milling","packing"]', 'positions', 1))$$,
               'one scope', 'several stages only for an operator opening of one scope');

-- 7 · one person on two stages in a row (E) ------------------------------------------------------------------------------
select t.as_user(t.u('03'));
select t.ok(exists (select 1 from jsonb_array_elements(app.assignment_warnings(t.u('05'), 'scope', t.scope('01'), 'operator', '{procurement,qc}')) w
                     where w->>'code' = 'adjacent_stages' and w->>'first' = 'procurement' and w->>'second' = 'qc' and w->>'name' = 'Procurement Op (field)'),
            'two stages in a row: a warning that names the person and both stages (not a refusal)');
select t.ok(exists (select 1 from jsonb_array_elements(app.assignment_warnings(t.u('05'), 'scope', t.scope('05'), 'operator', '{packing}')) w
                     where w->>'code' = 'several_stages')
            and not exists (select 1 from jsonb_array_elements(app.assignment_warnings(t.u('05'), 'scope', t.scope('05'), 'operator', '{packing}')) w
                     where w->>'code' = 'adjacent_stages'),
            'Packing with the Procurement he holds: a note, no two-in-a-row warning');
select app.set_stages((select id from public.assignments where employee_id = t.u('05') and scope_id = t.scope('05') and active), '{procurement,packing}');
select t.ok((select stages from public.assignments where employee_id = t.u('05') and scope_id = t.scope('05') and active) = '{procurement,packing}',
            'the server lets one person hold Procurement and Packing');
select t.ok(exists (select 1 from jsonb_array_elements(app.set_stages((select id from public.assignments where employee_id = t.u('05') and scope_id = t.scope('01') and active),
                                                                '{procurement,qc}')->'warnings') w where w->>'code' = 'adjacent_stages'),
            'a stage given on the roster next to one he holds: done, and the warning comes back with it');
select t.as_service();
do $$
declare s uuid := '00000000-0000-4000-8000-000000000401'; c uuid := '00000000-0000-4000-8000-000000000201'; p uuid; q uuid; qr uuid; seal public.qr_seals; j jsonb;
begin
  p := t.procure_as(s, t.farmer('01'), t.u('05'));
  perform t.as_user(t.u('05')); perform app.verify_footprint(p);           -- before: "a record cannot be verified by its own creator"
  perform t.as_service();
  perform t.ok((select status = 'verified' and verified_by = t.u('05') from public.footprints where id = p),
               'he verifies his own procurement record at QC (Veda''s decision)');
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (s, c, 'qc', p, t.u('05'), '{"qty_kg":95,"sample_qty_kg":1,"readings":{"moisture_pct":11.8,"broken_pct":2,"foreign_matter_pct":0.2}}') returning id into q;
  perform t.as_user(t.u('07')); perform app.verify_footprint(q);
  perform t.as_service();
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (s, c, 'qr_activation', q, t.u('07'), '{}') returning id into qr;
  perform t.as_user(t.u('07')); seal := app.seal_lot(qr);
  perform t.as_anon();
  j := app.public_lot_journey(seal.qr_code);
  perform t.ok((j->>'same_person')::boolean and not (j->>'independent')::boolean,
               'the public page is told some steps were recorded and checked by the same person');
  perform t.as_user(t.u('01'));
  j := app.ledger_page(null, null, s, t.u('05'), false, 20, 0);
  perform t.ok(exists (select 1 from jsonb_array_elements(j->'rows') r where r->>'event' = 'verify' and r->>'footprint_id' = p::text
                         and (r->>'same_person')::boolean and r->>'stage_role' = 'qc'),
               'the ledger: his verification shows him as QC, marked same person, next stage');
  perform t.ok(exists (select 1 from jsonb_array_elements(j->'rows') r where r->>'event' = 'create' and r->>'footprint_id' = q::text
                         and (r->>'same_person')::boolean and r->>'stage_role' = 'qc'),
               'and the QC record he made on his own lot, the same');
  perform t.ok(exists (select 1 from jsonb_array_elements(j->'rows') r where r->>'event' = 'create' and r->>'footprint_id' = p::text
                         and not (r->>'same_person')::boolean and r->>'stage_role' = 'procurement'),
               'his procurement record itself: Procurement, not marked');
  perform t.as_user(t.u('02'));
  j := app.state_ledger_page('00000000-0000-4000-8000-000000000001', null, null, s, null, 50, 0);
  perform t.ok(exists (select 1 from jsonb_array_elements(j->'rows') r where (r->>'same_person')::boolean), 'the State Manager''s ledger marks it too');
  perform t.ok((select (x->'same_person'->>'verified_own')::int from jsonb_array_elements(app.state_home('00000000-0000-4000-8000-000000000001')->'scopes'->'list') x
                 where x->>'scope_id' = s::text) = 1
               and (select (x->'same_person'->>'made_on_own')::int from jsonb_array_elements(app.state_home('00000000-0000-4000-8000-000000000001')->'scopes'->'list') x
                 where x->>'scope_id' = s::text) = 1,
               'the State Manager''s overview counts it for the scope (1 verified by its maker, 1 made on his own lot)');
  perform t.as_user(t.u('03'));
  perform t.ok((app.scope_roster(s)->'same_person'->>'verified_own')::int = 1, 'and the scope''s page');
  perform t.as_service();
end $$;

-- 8 · a closed scope needs nobody: its open lines are withdrawn ------------------------------------------------------------
select t.as_user(t.u('03'));
update public.scopes set status = 'closed' where id = '00000000-0000-4000-8000-000000000407';
select t.ok((select count(*) from pg_temp.lines('00000000-0000-4000-8000-000000000407') where status = 'withdrawn' and status_reason = 'the scope is closed') = 3,
            'a scope closed: its open lines are withdrawn, "the scope is closed"');
select t.as_service();
rollback;
