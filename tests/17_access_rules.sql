-- Migration 25: an operator reads only the ledger blocks of records the operator can see (thumb rule holds through
-- the ledger too); stage assignments can be removed and, with changes to people, are ledger blocks.
begin;
select t.as_service();

-- 1 · ledger read ------------------------------------------------------------------------------------------------------
do $$
declare p uuid; q uuid; m uuid; cm uuid; n_all bigint; n_scope bigint; c constant uuid := '00000000-0000-4000-8000-000000000201';
begin
  p := t.procure(t.scope('03'), t.farmer('01'), 126, 3, 2, 12.1, 12.0, 12.2);
  perform t.verify(p, t.u('06'));
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('03'), c, 'qc', p, t.u('06'), '{"qty_kg":120,"sample_qty_kg":1,"readings":{"moisture_pct":12.1,"broken_pct":2,"foreign_matter_pct":0.2}}') returning id into q;
  perform t.verify(q, t.u('08'));
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('03'), c, 'milling', q, t.u('08'), '{"input_kg":119,"rice_kg":80,"bran_kg":30,"loss_kg":9}') returning id into m;
  perform t.verify(m, t.u('11'));
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('03'), c, 'commercial', m, t.u('11'), '{"buyer":"Secret Buyer Ltd","market":"domestic","qty_kg":80,"price_per_kg":212}') returning id into cm;
  select count(*) into n_all from public.ledger;
  select count(*) into n_scope from public.ledger where scope_id = t.scope('03');

  perform t.as_user(t.u('05'));                                          -- procurement operator of this scope
  perform t.ok((select count(*) from public.ledger where footprint_id = p) >= 2, 'ledger: the procurement operator reads the blocks of his own lot');
  perform t.ok((select count(*) from public.ledger where footprint_id in (q, m, cm)) = 0
               and not exists (select 1 from public.ledger where payload::text ilike '%Secret Buyer%' or payload::text ilike '%price_per_kg%'),
               'ledger: he cannot read the lab, mill or sale blocks of the same scope: no buyer, no price');
  perform t.ok((select count(*) from public.ledger l where l.footprint_id is null) = 0
               and (select count(*) from public.ledger l) = (select count(*) from public.ledger l join public.footprints f on f.id = l.footprint_id),
               'ledger: every block an operator reads belongs to a record he can see; none without a record');
  perform t.ok((app.footprint_detail(p)->'ledger') is not null and jsonb_array_length(app.footprint_detail(p)->'ledger') >= 2,
               'ledger: the record page still shows his lot''s ledger');

  perform t.as_user(t.u('08'));                                          -- mill operator: the stage behind (QC) and his own
  perform t.ok((select count(*) from public.ledger where footprint_id = q) >= 1 and (select count(*) from public.ledger where footprint_id = m) >= 1
               and (select count(*) from public.ledger where footprint_id in (p, cm)) = 0,
               'ledger: the mill operator reads the lab and mill blocks, not procurement and not the sale');
  perform t.as_user(t.u('11'));                                          -- commercial: own stage carries the buyer
  perform t.ok(exists (select 1 from public.ledger where footprint_id = cm and payload::text ilike '%Secret Buyer%')
               and (select count(*) from public.ledger where footprint_id in (p, q)) = 0,
               'ledger: the Commercial operator reads his own sale block, not procurement or the lab');

  perform t.as_user(t.u('03'));
  perform t.ok((select count(*) from public.ledger where scope_id = t.scope('03')) = n_scope and (select count(*) from public.ledger where scope_id is null) = 0,
               'ledger: the Client Manager reads every block of his scope and no block without a scope (farmers, users)');
  perform t.ok((select count(*) from app.scope_activity(t.scope('03'), 14)) >= 1, 'ledger: the scope dashboard''s activity still works for him');
  perform t.as_user(t.u('04'));
  perform t.ok((select count(*) from public.ledger where scope_id = t.scope('03')) = n_scope, 'ledger: Client View reads the blocks of the client''s scopes');
  perform t.as_user(t.u('02'));
  perform t.ok((select count(*) from public.ledger where scope_id = t.scope('03')) = n_scope and (select count(*) from public.ledger where scope_id is null) = 0,
               'ledger: the State Manager reads the scopes of his state');
  perform t.as_user(t.u('12'));
  perform t.ok((select count(*) from public.ledger) = 0, 'ledger: another client''s operator reads nothing');
  perform t.as_user(t.u('01'));
  perform t.ok((select count(*) from public.ledger) = n_all and (select count(*) from public.ledger where scope_id is null) > 0,
               'ledger: the admin reads the whole chain');
  perform t.as_anon();
  perform t.fails('select count(*) from public.ledger', 'permission denied', 'ledger: an anonymous visitor cannot read the table at all');
  perform t.as_service();
  update public.app_users set active = false where id = t.u('05');
  perform t.as_user(t.u('05'));
  perform t.ok((select count(*) from public.ledger) = 0, 'ledger: a deactivated operator reads nothing');
  perform t.as_service();
  update public.app_users set active = true where id = t.u('05');
end $$;

-- 2 · assignments ------------------------------------------------------------------------------------------------------
do $$
declare slot uuid; n0 bigint; b record; sc uuid; other_cm uuid; c constant uuid := '00000000-0000-4000-8000-000000000201';
begin
  select count(*) into n0 from public.ledger;
  perform t.as_user(t.u('03'));
  insert into public.slot_assignments (user_id, scope_id, stage_type) values (t.u('10'), t.scope('03'), 'milling') returning id into slot;
  perform t.as_service();
  select * into b from public.ledger order by seq desc limit 1;
  perform t.ok((select count(*) from public.ledger) = n0 + 1 and b.event = 'supervisory' and b.scope_id = t.scope('03') and b.actor = t.u('03')
               and b.payload->>'act' = 'slot_assigned' and b.payload->>'stage_type' = 'milling' and b.payload->>'user_name' = 'Grading Operator',
               'slots: giving a stage on an active scope is a ledger block naming the manager, the person and the stage');
  perform t.ok(app.is_my_stage(t.u('10'), t.scope('03'), 'milling'), 'slots: the person may now work at that stage');

  perform t.as_user(t.u('03'));
  perform t.fails(format('update public.slot_assignments set stage_type = %L where id = %L', 'qc', slot), 'given or removed, not changed', 'slots: an assignment cannot be rewritten to another stage');
  perform t.fails(format('update public.slot_assignments set user_id = %L where id = %L', t.u('05'), slot), 'given or removed, not changed', 'slots: nor to another person');
  perform t.fails(format('insert into public.slot_assignments (user_id, scope_id, stage_type) values (%L, %L, %L)', t.u('10'), t.scope('03'), 'packing'),
                  'not in this scope''s chain', 'slots: a stage outside the scope''s chain cannot be assigned');
  perform t.as_user(t.u('10'));
  delete from public.slot_assignments where id = slot;
  perform t.as_service();
  perform t.ok(exists (select 1 from public.slot_assignments where id = slot), 'slots: an operator cannot remove an assignment (not even his own)');
  insert into public.app_users (role, display_name, email, client_id) values ('client_manager', 'Other CM', 'other.cm@test', '00000000-0000-4000-8000-000000000202') returning id into other_cm;
  perform t.as_user(other_cm);
  delete from public.slot_assignments where id = slot;
  perform t.as_service();
  perform t.ok(exists (select 1 from public.slot_assignments where id = slot), 'slots: nor can another client''s manager');

  select count(*) into n0 from public.ledger;
  perform t.as_user(t.u('03'));
  delete from public.slot_assignments where id = slot;
  perform t.as_service();
  select * into b from public.ledger order by seq desc limit 1;
  perform t.ok(not exists (select 1 from public.slot_assignments where id = slot) and (select count(*) from public.ledger) = n0 + 1
               and b.payload->>'act' = 'slot_removed' and b.actor = t.u('03') and b.payload->>'user_id' = t.u('10')::text,
               'slots: the Client Manager removes it; that is a ledger block too');
  perform t.ok(not app.is_my_stage(t.u('10'), t.scope('03'), 'milling'), 'slots: the person may no longer work at that stage');

  -- a draft scope is being set up: no blocks until activation, which records who holds which stage
  perform t.as_user(t.u('03'));
  insert into public.scopes (client_id, crop_id, season_code, geography, chain, status)
  values (c, '00000000-0000-4000-8000-000000000101', 'KH26', 'Test block', '{procurement,qc,qr_activation}', 'draft') returning id into sc;
  select count(*) into n0 from public.ledger where scope_id = sc;
  insert into public.slot_assignments (user_id, scope_id, stage_type) values (t.u('05'), sc, 'procurement'), (t.u('06'), sc, 'qc'), (t.u('07'), sc, 'qc'), (t.u('07'), sc, 'qr_activation');
  delete from public.slot_assignments where scope_id = sc and user_id = t.u('07') and stage_type = 'qc';
  perform t.ok((select count(*) from public.ledger where scope_id = sc) = n0, 'slots: setting up a draft scope writes nothing to the ledger');
  update public.scopes set status = 'active' where id = sc;
  select * into b from public.ledger where scope_id = sc order by seq desc limit 1;
  perform t.ok(b.payload->>'act' = 'slots_at_activation' and jsonb_array_length(b.payload->'slots') = 3
               and b.payload->'slots'->0->>'stage_type' = 'procurement' and b.payload->'slots'->2->>'user_name' = 'QR Sealer'
               and (select event from public.ledger where scope_id = sc order by seq desc offset 1 limit 1) = 'scope_activate',
               'slots: activation records who holds which stage, right after the activation block');
  perform t.as_service();
end $$;

-- 3 · people -----------------------------------------------------------------------------------------------------------
-- Migration 31–33: a person is created by HR (app.add_joiner), never by a manager; the blocks are the same kind.
do $$
declare u uuid; b record; n0 bigint;
begin
  select count(*) into n0 from public.ledger;
  perform t.as_user(t.u('03'));
  perform t.fails($q$ select app.add_joiner('{"full_name":"New Sorter","personal_email":"sorter@test.in","join_date":"2026-11-01"}') $q$,
                  'only HR adds a joiner', 'people: a Client Manager no longer creates people');
  perform t.as_user(t.u('17'));
  u := (app.add_joiner('{"full_name":"New Sorter","personal_email":"sorter@test.in","phone":"9812345678","join_date":"2026-11-01"}')->>'id')::uuid;
  perform t.as_service();
  select * into b from public.ledger order by seq desc limit 1;
  perform t.ok((select count(*) from public.ledger) = n0 + 1 and b.event = 'supervisory' and b.scope_id is null and b.actor = t.u('17')
               and b.payload->>'kind' = 'user_created' and b.payload->>'role' = 'operator' and b.payload->>'status' = 'invited'
               and b.payload->>'name' = 'New Sorter',
               'people: creating a person is a ledger block naming who created whom');
  perform t.as_user(t.u('17'));
  perform app.suspend_person(u, 'did not join');
  update public.app_users set phone = '+919898989898' where id = u;
  update public.app_users set display_name = 'New Sorter' where id = u;          -- nothing changed: no block
  perform t.as_service();
  perform t.ok((select count(*) from public.ledger) = n0 + 3
               and (select payload->'before'->>'active' = 'true' and payload->'after'->>'active' = 'false'
                       and payload->'after'->>'status' = 'suspended' from public.ledger order by seq desc offset 1 limit 1)
               and (select payload->'after'->>'sign_in' = 'changed' from public.ledger order by seq desc limit 1),
               'people: suspending and changing the sign-in are blocks; a save that changes nothing is not');
  perform t.ok(not exists (select 1 from public.ledger where seq > n0 and (payload::text like '%9812345678%' or payload::text like '%9898989898%'
                                                                          or payload::text like '%sorter@test.in%')),
               'people: phone numbers and email addresses never enter the ledger');
  perform t.as_user(t.u('03'));
  perform t.ok((select count(*) from public.ledger where payload->>'kind' like 'user_%') = 0, 'people: these blocks are not readable by a Client Manager');
  perform t.as_user(t.u('17'));
  perform t.ok((select count(*) from public.ledger) = 0, 'people: nor by HR, who reads no ledger at all');
  perform t.as_user(t.u('01'));
  perform t.ok((select count(*) from public.ledger where payload->>'user_id' = u::text) = 3, 'people: the admin reads them');
  perform t.as_service();
  delete from public.app_users where id = u;
  perform t.ok((select payload->>'kind' from public.ledger order by seq desc limit 1) = 'user_removed', 'people: removing a user row (service role, an undone create) is a block');
  perform t.ok((select count(*) from app.verify_ledger()) = 0, 'the chain still verifies with the new kinds of block');
end $$;

rollback;
