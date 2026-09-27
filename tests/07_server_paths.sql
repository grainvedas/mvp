-- Workstream H: server paths the Phase 0 suite did not reach (migrations 11–13).
-- Signed-in paths use t.as_user (JWT + role authenticated); the concurrent-session checks are in tests/concurrency/.
begin;
select t.as_service();
create temp table h (k text primary key, v uuid);
grant select on h to authenticated;

-- ---------------------------------------------------------------------------
-- app.verify_footprint called as a logged-in user
-- ---------------------------------------------------------------------------
do $$
declare p uuid;
begin
  p := t.procure(t.scope('01'), t.farmer('04'), 166, 2, 2, 12.1, 12.0, 12.2);   -- Geeta Kumari 162 kg, pending
  insert into h values ('p', p);
end $$;

select t.as_user(t.u('05'));   -- the creator
select t.fails(format('select app.verify_footprint(%L)', (select v from h where k = 'p')), 'receiving stage',
               'verify rpc: the creator cannot verify');
select t.as_user(t.u('07'));   -- QR sealer: two stages ahead
select t.fails(format('select app.verify_footprint(%L)', (select v from h where k = 'p')), 'receiving stage',
               'verify rpc: a stage further ahead cannot verify');
select t.as_user('20000000-0000-4000-8000-000000000001');   -- signed in, no app_users row
select t.fails(format('select app.verify_footprint(%L)', (select v from h where k = 'p')), 'not authenticated',
               'verify rpc: a login with no app user is refused');
select t.as_user(t.u('06'));   -- QC technician: the receiving stage
select t.ok((select status = 'verified' and verified_by = t.u('06') from app.verify_footprint((select v from h where k = 'p'))),
            'verify rpc: the QC technician verifies; verified_by is the caller');
select t.ok((select actor from public.ledger where footprint_id = (select v from h where k = 'p') and event = 'verify') = t.u('06'),
            'verify rpc: the verify block names the QC technician');
select t.fails(format('select app.verify_footprint(%L)', (select v from h where k = 'p')), 'not pending',
               'verify rpc: a verified record cannot be verified again');

-- ---------------------------------------------------------------------------
-- Migration 11: the actor is the signed-in caller
-- ---------------------------------------------------------------------------
select t.as_service();
do $$
declare p uuid; q uuid; qr uuid;
begin
  p := t.procure(t.scope('01'), t.farmer('05'), 200, 2, 2.5, 12, 12, 12);        -- Suresh Yadav 195 kg, pending
  insert into h values ('p2', p);
  -- QC → QR on the verified lot above (service path)
  insert into public.footprints (scope_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('01'), 'qc', (select v from h where k = 'p'), t.u('06'),
          '{"qty_kg":162,"sample_qty_kg":0.5,"readings":{"moisture_pct":12.1,"broken_pct":2,"foreign_matter_pct":0.2}}')
  returning id into q;
  perform t.verify(q, t.u('07'));
  insert into public.footprints (scope_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('01'), 'qr_activation', q, t.u('07'), '{}') returning id into qr;
  insert into h values ('q', q), ('qr', qr);
end $$;

select t.as_user(t.u('05'));
select t.fails(format($q$ update public.footprints set status = 'verified', verified_by = %L where id = %L $q$,
                      t.u('06'), (select v from h where k = 'p2')),
               'signed-in user', 'actor: the creator cannot verify by naming the QC technician');

select t.as_user('20000000-0000-4000-8000-000000000001');
select t.fails(format('select app.seal_lot(%L, %L)', (select v from h where k = 'qr'), t.u('07')), 'only the assigned QR operator',
               'actor: a login with no app user cannot seal by naming the QR operator');
select t.as_user(t.u('06'));
select t.fails(format('select app.seal_lot(%L, %L)', (select v from h where k = 'qr'), t.u('07')), 'only the assigned QR operator',
               'actor: the QC technician cannot seal by naming the QR operator');
select t.as_user(t.u('07'));
select t.ok((select sealed_by = t.u('07') from app.seal_lot((select v from h where k = 'qr'))),
            'actor: the QR operator seals; sealed_by is the caller');

select t.as_user(t.u('03'));   -- Client Manager
select t.fails(format($q$ update public.qc_verdicts set override = jsonb_build_object('market','export','reason','test','authoriser',%L)
                          where footprint_id = %L $q$, t.u('01'), (select v from h where k = 'q')),
               'authoriser must be the signed-in user', 'actor: a client manager cannot name the admin as override authoriser');
update public.qc_verdicts
   set override = jsonb_build_object('market', 'export', 'reason', 'Buyer accepts 12.1 percent after re-drying', 'authoriser', t.u('03'))
 where footprint_id = (select v from h where k = 'q');
select t.ok((select override->>'authoriser' from public.qc_verdicts where footprint_id = (select v from h where k = 'q')) = t.u('03')::text,
            'actor: the client manager overrides as themselves');

-- ---------------------------------------------------------------------------
-- Farmer verification and Farmer IDs (migrations 11, 12)
-- ---------------------------------------------------------------------------
select t.as_service();
insert into public.farmers (id, client_id, scope_ids, status, name, guardian_name, village, district, phone, land_area_acres, created_by)
values ('00000000-0000-4000-8000-000000000591', '00000000-0000-4000-8000-000000000201', array[t.scope('01')], 'under_review',
        'Kamla Devi', 'Shri Ramesh', 'Bansi', 'Siddharthnagar', '+919000000091', 1.5, t.u('05')),
       ('00000000-0000-4000-8000-000000000592', '00000000-0000-4000-8000-000000000201', array[t.scope('01')], 'under_review',
        'Raju Prasad', 'Shri Mohan', 'Itwa', 'Siddharthnagar', '+919000000092', 2.0, t.u('05')),
       ('00000000-0000-4000-8000-000000000593', '00000000-0000-4000-8000-000000000201', array[t.scope('01')], 'under_review',
        'Phoolmati', 'Shri Lallan', 'Naugarh', 'Siddharthnagar', '+919000000093', 0.8, t.u('05'));

select t.as_user(t.u('05'));   -- procurement operator (has the farmers module)
select t.fails(format($q$ update public.farmers set status = 'active', verified_by = %L where id = %L $q$,
                      t.u('02'), '00000000-0000-4000-8000-000000000591'),
               'signed-in user', 'farmer: an operator cannot activate a farmer by naming the State Manager');
select t.fails(format($q$ update public.farmers set status = 'active', verified_by = %L where id = %L $q$,
                      t.u('05'), '00000000-0000-4000-8000-000000000591'),
               'State Manager or admin', 'farmer: an operator cannot verify a farmer');
select t.fails($q$ insert into public.farmers (client_id, status, name, guardian_name, village, district, phone, land_area_acres, farmer_code)
                   values ('00000000-0000-4000-8000-000000000201', 'draft', 'X', 'Y', 'Z', 'W', '+919000000099', 1, 'PRSDM-F-0099') $q$,
               'set by verification', 'farmer: an operator cannot create a farmer that already has a Farmer ID');
insert into public.farmers (client_id, status, name, guardian_name, village, district, phone, land_area_acres, created_by)
values ('00000000-0000-4000-8000-000000000201', 'draft', 'Munni Devi', 'Shri Hari', 'Itwa', 'Siddharthnagar', '+919000000094', 1, t.u('03'));
select t.ok((select created_by from public.farmers where phone = '+919000000094') = t.u('05'),
            'farmer: created_by is stamped as the signed-in operator, whatever was sent');

select t.as_user(t.u('02'));   -- State Manager, UP
update public.farmers set status = 'active', verified_by = t.u('02') where id = '00000000-0000-4000-8000-000000000591';
select t.ok((select farmer_code from public.farmers where id = '00000000-0000-4000-8000-000000000591') = 'PRSDM-F-0006',
            'farmer id: the next Prasaadam ID after the five seeded is PRSDM-F-0006');
update public.farmers set status = 'active', verified_by = t.u('02') where id = '00000000-0000-4000-8000-000000000592';
select t.ok((select farmer_code from public.farmers where id = '00000000-0000-4000-8000-000000000592') = 'PRSDM-F-0007',
            'farmer id: then PRSDM-F-0007');
select t.fails(format($q$ update public.farmers set farmer_code = 'PRSDM-F-0099' where id = %L $q$, '00000000-0000-4000-8000-000000000591'),
               'issued by verification only', 'farmer id: a signed-in user cannot change a Farmer ID');
update public.farmers set status = 'under_review' where id = '00000000-0000-4000-8000-000000000591';
update public.farmers set status = 'active', verified_by = t.u('02') where id = '00000000-0000-4000-8000-000000000591';
select t.ok((select farmer_code from public.farmers where id = '00000000-0000-4000-8000-000000000591') = 'PRSDM-F-0006',
            'farmer id: re-verification keeps the ID issued the first time');

-- ---------------------------------------------------------------------------
-- Identifiers past 9999 (migration 12)
-- ---------------------------------------------------------------------------
select t.as_service();
update public.footprint_counters set last_seq = 9999 where series = 'PRSDM-KNM-KH26' and stage_type = 'procurement';
do $$
declare p uuid;
begin
  p := t.procure(t.scope('01'), t.farmer('01'), 50, 1, 1, 12, 12, 12);
  perform t.ok((select footprint_code from public.footprints where id = p) = 'PRSDM-KNM-KH26-P-10000',
               'codes: the 10,000th lot of a stage is P-10000, not a clash with P-1000');
end $$;
update public.farmer_id_counters set last_seq = 9999 where client_id = '00000000-0000-4000-8000-000000000201';
update public.farmers set status = 'active', verified_by = t.u('02') where id = '00000000-0000-4000-8000-000000000593';
select t.ok((select farmer_code from public.farmers where id = '00000000-0000-4000-8000-000000000593') = 'PRSDM-F-10000',
            'farmer id: the 10,000th Farmer ID is PRSDM-F-10000, not a clash with PRSDM-F-1000');

-- ---------------------------------------------------------------------------
-- Ledger hashes do not depend on the session's time zone (migration 13)
-- ---------------------------------------------------------------------------
set local timezone = 'Asia/Kolkata';
set local datestyle = 'SQL, DMY';
select t.procure(t.scope('01'), t.farmer('02'), 60, 1, 1, 12, 12, 12) is not null as block_written_in_ist;
set local timezone = 'UTC';
set local datestyle = 'ISO, MDY';
select t.ok(not exists (select 1 from app.verify_ledger()), 'ledger: a block written from an Asia/Kolkata session verifies from a UTC session');
set local timezone = 'America/New_York';
select t.ok(not exists (select 1 from app.verify_ledger()), 'ledger: and from any other time zone');

rollback;
