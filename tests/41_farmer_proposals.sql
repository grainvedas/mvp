-- Migration 47 (Veda, 14 Oct 2026, on staging): the person at Procurement and a farmer already verified. He answers the
-- farmer's good farming practice (it counts at once, so his lot is no longer refused); any other detail he finds wrong or
-- missing he proposes, with a reason, and nothing changes until the Client Manager approves it (then through the normal
-- change rules) or refuses it with a reason. 305 the field operator at Procurement, 303 the Client Manager, 306 QC,
-- 312 another client's operator. Farmer 501 (PRSDM-F-0001, active).
begin;
select t.as_service();
create temp table fx (k text primary key, id uuid);
grant select, insert, update on fx to authenticated;
create or replace function pg_temp.f(p text) returns uuid language sql stable as $$ select id from fx where k = p $$;
create or replace function pg_temp.prop(p uuid) returns public.farmer_proposals language sql stable security definer as $$
  select * from public.farmer_proposals where id = p $$;
create or replace function pg_temp.farmer() returns public.farmers language sql stable security definer as $$
  select * from public.farmers where id = '00000000-0000-4000-8000-000000000501' $$;
create or replace function pg_temp.audits(p_action text) returns int language sql stable security definer as $$
  select count(*)::int from public.audit_log where action = p_action $$;
grant execute on all functions in schema pg_temp to authenticated;
-- the crop asks one practice, required
update public.crops set gap_items = '[{"key":"seed","label":"Seed source certified","type":"yesno","required":true}]'
 where id = '00000000-0000-4000-8000-000000000101';

-- 1 · good farming practice: he answers it, and his lot is no longer refused -----------------------------------------------
select t.as_user(t.u('05'));
select t.fails($$select t.procure_as(t.scope('01'), '00000000-0000-4000-8000-000000000501', t.u('05'))$$, 'good farming practice',
               'before: the lot of a farmer without the required practice is refused');
select app.save_farmer_gap('00000000-0000-4000-8000-000000000501', '00000000-0000-4000-8000-000000000101', '{"seed": true}');
select t.ok(t.procure_as(t.scope('01'), '00000000-0000-4000-8000-000000000501', t.u('05')) is not null,
            'the person at Procurement answers it for a verified farmer, and it counts at once: his lot is saved');
select t.as_user(t.u('06'));
select t.fails($$select app.save_farmer_gap('00000000-0000-4000-8000-000000000501', '00000000-0000-4000-8000-000000000101', '{"seed": false}')$$,
               'farmer not found', 'QC does not answer it (he does not even read the farmer)');

-- 2 · other details: proposed, not changed ---------------------------------------------------------------------------------
select t.as_user(t.u('05'));
insert into fx select 'P1', (app.propose_farmer_change('00000000-0000-4000-8000-000000000501',
  '{"village": "Bansi Kalan", "name": "Ram Achal"}', 'village spelt wrong at the import')->>'id')::uuid;
select t.ok((pg_temp.prop(pg_temp.f('P1'))).changes = '{"village": "Bansi Kalan"}'::jsonb
            and (pg_temp.prop(pg_temp.f('P1'))).before->>'village' = (pg_temp.farmer()).village
            and (pg_temp.prop(pg_temp.f('P1'))).status = 'requested',
            'he proposes a corrected village: only what differs is kept, with the value it replaces');
select t.ok((pg_temp.farmer()).village <> 'Bansi Kalan', 'nothing changes yet');
select t.ok(pg_temp.audits('farmer_change_proposed') = 1, 'the proposal is in the Audit log');
select t.fails($$select app.propose_farmer_change('00000000-0000-4000-8000-000000000501', '{"name": "Ram Achal"}', 'same as before')$$,
               'nothing differs', 'a proposal that changes nothing is refused');
select t.fails($$select app.propose_farmer_change('00000000-0000-4000-8000-000000000501', '{"status": "inactive"}', 'he left farming')$$,
               'cannot be proposed', 'the status is not his to propose');
select t.fails($$select app.propose_farmer_change('00000000-0000-4000-8000-000000000501', '{"village": "X"}', 'no')$$,
               'say why', 'a reason is needed');
select t.fails($$select app.propose_farmer_change('00000000-0000-4000-8000-000000000501', '{"gi_land_acres": "-2"}', 'GI land measured')$$,
               'acres above 0', 'acres must be a number above 0');
select t.as_user(t.u('03'));
select t.fails($$select app.propose_farmer_change('00000000-0000-4000-8000-000000000501', '{"village": "X"}', 'a test')$$,
               'change the farmer yourself', 'the Client Manager changes the farmer himself, he does not propose');
select t.as_user(t.u('06'));
select t.fails($$select app.propose_farmer_change('00000000-0000-4000-8000-000000000501', '{"village": "X"}', 'a test')$$,
               'Procurement or Village Batch', 'QC does not propose');
select t.ok(jsonb_array_length(app.farmer_proposals('00000000-0000-4000-8000-000000000201', null)) = 0, 'nor reads the proposals');
select t.as_user(t.u('12'));
select t.fails($$select app.propose_farmer_change('00000000-0000-4000-8000-000000000501', '{"village": "X"}', 'a test')$$,
               'Procurement or Village Batch', 'another client''s operator does not propose');

-- 3 · the Client Manager decides ---------------------------------------------------------------------------------------------
select t.as_user(t.u('05'));
select t.ok((app.farmer_proposals(null, '00000000-0000-4000-8000-000000000501')->0->>'mine')::boolean
            and not (app.farmer_proposals(null, '00000000-0000-4000-8000-000000000501')->0->>'can_decide')::boolean,
            'he reads his own proposal, and cannot decide it');
select t.fails(format($$select app.decide_farmer_proposal(%L, true)$$, pg_temp.f('P1')), 'Client Manager of this client decides', 'he cannot approve it');
select t.as_user(t.u('03'));
select t.ok((app.farmer_proposals('00000000-0000-4000-8000-000000000201', null)->0->>'can_decide')::boolean
            and (app.farmer_proposals('00000000-0000-4000-8000-000000000201', null)->0->'changes'->>'village') = 'Bansi Kalan',
            'the Client Manager reads it, with the value proposed, and may decide');
select app.decide_farmer_proposal(pg_temp.f('P1'), true);
select t.ok((pg_temp.farmer()).village = 'Bansi Kalan' and (pg_temp.prop(pg_temp.f('P1'))).status = 'approved'
            and (pg_temp.prop(pg_temp.f('P1'))).decided_by = t.u('03'),
            'approved: the farmer changes, in the Client Manager''s name');
select t.ok(exists (select 1 from jsonb_array_elements(app.farmer_history('00000000-0000-4000-8000-000000000501')->'events') e
                     where e->>'reason' like 'proposed by Procurement Op (field): village spelt wrong%'),
            'the farmer''s history says who proposed it and why');
select t.fails(format($$select app.decide_farmer_proposal(%L, false, 'too late')$$, pg_temp.f('P1')), 'approved already', 'decided once only');
-- GI land: approved, it waits for the State Manager to accept, as any change to it does
select t.as_user(t.u('05'));
insert into fx select 'P2', (app.propose_farmer_change('00000000-0000-4000-8000-000000000501', '{"gi_land_acres": "0.5"}', 'GI land measured at the gate')->>'id')::uuid;
select t.as_user(t.u('03'));
select app.decide_farmer_proposal(pg_temp.f('P2'), true);
select t.as_service();
select t.ok(exists (select 1 from public.farmer_change_flags where farmer_id = '00000000-0000-4000-8000-000000000501' and field = 'gi_land_acres' and accepted_at is null),
            'a GI land change approved waits for the State Manager to accept it, as any change to it does');
-- refused, with a reason; withdrawn by its own proposer only
select t.as_user(t.u('05'));
insert into fx select 'P3', (app.propose_farmer_change('00000000-0000-4000-8000-000000000501', '{"district": "Siddharth Nagar"}', 'district written short')->>'id')::uuid;
insert into fx select 'P4', (app.propose_farmer_change('00000000-0000-4000-8000-000000000501', '{"notes": "TEST note"}', 'a note to add')->>'id')::uuid;
select t.as_user(t.u('03'));
select t.fails(format($$select app.decide_farmer_proposal(%L, false, '')$$, pg_temp.f('P3')), 'say why', 'refusing needs a reason');
select app.decide_farmer_proposal(pg_temp.f('P3'), false, 'the short form is the official one');
select t.ok((pg_temp.prop(pg_temp.f('P3'))).status = 'refused' and (pg_temp.farmer()).district is distinct from 'Siddharth Nagar',
            'refused, with the reason; the farmer is as it was');
select t.fails(format($$select app.withdraw_farmer_proposal(%L)$$, pg_temp.f('P4')), 'only your own', 'the Client Manager does not withdraw his proposal');
select t.as_user(t.u('05'));
select app.withdraw_farmer_proposal(pg_temp.f('P4'));
select t.ok((pg_temp.prop(pg_temp.f('P4'))).status = 'withdrawn', 'he withdraws his own while it waits');
select t.ok(pg_temp.audits('farmer_change_approved') = 2 and pg_temp.audits('farmer_change_refused') = 1 and pg_temp.audits('farmer_change_withdrawn') = 1,
            'every decision is in the Audit log');
select t.as_service();
rollback;
