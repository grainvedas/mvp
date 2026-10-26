-- Migration 68 (Phase 3, release 2 of Veda's combined brief of 19 Oct 2026: Parts C and E4, with item 65).
-- What client users see, and the exports of every view.
--
--   C   four views, read on the server for whoever may read them, each from one function a later API can call too:
--       the portfolio (app.client_portfolio: every scope the reader reaches, by state and crop and in total: procured,
--       in process, packed, sold, shipped, packs released, scans, open copy flags, open lab results, recalls, "Waiting on
--       GrainVeda"); one scope (app.client_scope_detail: the pipeline by stage, lots and batches, QC per market with its
--       lab and report number, documents, the reports issued, the people on each stage by name and role only); the
--       farmers (the client's own: its farmer records are the farmers' consent to it; phones never); across scopes
--       (app.client_across: buyers and orders, scans by city, copy flags, recalls, the outputs issued)
--       Who reads them: a client's owner and viewers (a viewer only the scopes it reaches; never the client's own staff),
--       the admin, and the client's State and Client Managers (the scopes they see whole). Prices (the client's own) are
--       on the screens and in the internal copy only for those who may take the internal copy (Phase 1, C3; migration
--       67: the owner and the viewers the owner allowed); never another client's
--   E4  each view as an export (app.export_client_view): its tables, made by the same functions as the screen, in a
--       shareable copy (default: no prices, no farmer names) or an internal one; every download in the Audit log
--   65  (the run sheet's checks of item 64) a client account's kind is said where it shows: People → Client logins
--       and the person's page (people_page, employee_profile: client_account)
--   the isolation probe (found while checking this release on the local stack): a person's own row (an ended
--       assignment to a client he no longer works for) is his own, not another client's leak
-- Additive: new functions only; replaced from their own text, each change named: app.people_page, app.employee_profile,
-- app.isolation_probe.
select set_config('app.change_path', 'migration 68', true);

-- 1 · who reads what ------------------------------------------------------------------------------------------------------
-- a scope: a client account (owner or viewer, active) of its client that reaches it; the people of GrainVeda who see the
-- scope whole (the admin, its State and Client Managers, those who watch its state). Never a client's own staff here.
create or replace function app.cv_may_scope(p_scope uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.current_user_id() is not null and coalesce((
    select case when app.is_client_login()
                then app.client_reader_of(s.client_id) and app.account_reaches(app.current_user_id(), s.id)
                else app.sees_whole_scope(s.id) end
      from public.scopes s where s.id = p_scope and s.status in ('active', 'closed')), false)
$$;

-- a client: its owner and viewers; the admin; whoever manages it in a state; whoever sees one of its scopes whole
create or replace function app.cv_may_client(p_client uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.current_user_id() is not null and exists (select 1 from public.clients c where c.id = p_client) and
    case when app.is_client_login() then app.client_reader_of(p_client)
              and exists (select 1 from public.client_accounts ca where ca.user_id = app.current_user_id() and ca.status = 'active')
         else app.is_admin() or app.manages_client(app.current_user_id(), p_client)
              or exists (select 1 from public.scopes s where s.client_id = p_client and app.cv_may_scope(s.id)) end
$$;

-- the scopes of a client the reader reaches (active and closed; a draft is nobody's view yet)
create or replace function app.cv_scopes(p_client uuid) returns setof uuid
language sql stable security definer set search_path = public as $$
  select s.id from public.scopes s where s.client_id = p_client and s.status in ('active', 'closed') and app.cv_may_scope(s.id)
$$;

-- prices and farmers' names: for those who may take the internal copy (Phase 1, C3; migration 67), never another's
create or replace function app.cv_internal_scope(p_scope uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.cv_may_scope(p_scope) and (app.may_internal_copy(p_scope) or (app.is_admin() and not app.is_client_login()))
$$;
create or replace function app.cv_internal_client(p_client uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.cv_may_client(p_client) and
    case when app.is_client_login() then app.client_reader_of(p_client) and app.client_internal_ok()
         else app.is_admin() or app.manages_client(app.current_user_id(), p_client) end
$$;

create or replace function app.cv_scope_label(p_scope uuid) returns text
language sql stable security definer set search_path = public as $$
  select cr.name || ' · ' || s.season_code || ' · ' || s.geography from public.scopes s join public.crops cr on cr.id = s.crop_id where s.id = p_scope
$$;

-- 2 · one scope's figures (C: the portfolio's columns) ------------------------------------------------------------------------
--   procured        verified kg at the chain's first stage
--   in process      verified kg not yet handed on, at the stages before Packing (or before the sale, the shipment or the
--                   seal where the chain has no Packing): what is in the chain and not yet packed
--   packed          packs made and not void, and their kg
--   sold, shipped   verified kg of the sales and of the shipments
--   released        packs live on their public page (migration 62: those a sealed shipment carried, and old data)
--   scans           scans of the scope's packs and lots
--   copy flags      open copy-scan flags
--   lab             samples at the lab with no report yet; lab results failing every market of the scope with no
--                   acceptance by the client and no decision
--   recalls         lots recalled; under investigation apart
--   waiting         "Waiting on GrainVeda" (Phase 1, B): records waiting for their check, samples at the lab, open flags
create or replace function app.cv_scope_figures(p_scope uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  with s as (select * from public.scopes where id = p_scope),
  chain as (select c.st, c.i from s cross join unnest(s.chain) with ordinality c(st, i)),
  stop as (select coalesce(min(i), 1000) as i from chain where st in ('packing', 'commercial', 'shipment', 'qr_activation')),
  live as (select f.* from public.footprints f where f.scope_id = p_scope and f.status not in ('superseded', 'legacy')
             and not exists (select 1 from public.withdrawals w where w.footprint_id = f.id)),
  seals as (select q.footprint_id as seal_id, q.qr_code from public.qr_seals q join public.footprints f on f.id = q.footprint_id where f.scope_id = p_scope),
  lastrel as (select distinct on (e.seal_id) e.seal_id, e.status from public.release_events e join seals x on x.seal_id = e.seal_id order by e.seal_id, e.seq desc),
  qcf as (select l.id, v.domestic_verdict as dom, v.export_verdict as exp, v.override
            from live l left join public.qc_verdicts v on v.footprint_id = l.id where l.stage_type = 'qc'),
  waiting_lab as (select count(*) as n from public.qc_samples q where q.scope_id = p_scope and q.status = 'sent' and q.qc_footprint_id is null),
  failed_lab as (select count(*) as n from qcf, s
                  where qcf.override is null
                    and not exists (select 1 from public.attachments a where a.footprint_id = qcf.id and a.label = 'acceptance')
                    and (('domestic' = any (s.market_codes) and qcf.dom = 'fail') or ('export' = any (s.market_codes) and qcf.exp = 'fail'))
                    and not (('domestic' = any (s.market_codes) and qcf.dom = 'pass') or ('export' = any (s.market_codes) and qcf.exp = 'pass'))),
  pk as (select count(*) filter (where status <> 'void') as n, coalesce(sum(size_kg) filter (where status <> 'void'), 0) as kg
           from public.packs where scope_id = p_scope),
  rel as (select coalesce(sum(released + old_data), 0) as n from app.scope_pack_states(p_scope)),
  sc as (select count(*) as n from public.scans x
          where (x.kind = 'pack' and exists (select 1 from public.packs p where p.serial = x.code and p.scope_id = p_scope))
             or (x.kind = 'lot' and exists (select 1 from seals q where q.qr_code = x.code))),
  pend as (select count(*) as n from live where status = 'pending'),
  fl as (select count(*) as n from public.flags g join live l on l.id = g.footprint_id where g.status = 'open')
  select jsonb_build_object(
    'procured_kg', coalesce((select sum(l.qty_out) from live l join chain c on c.st = l.stage_type and c.i = 1
                              where l.status = 'verified' and not l.split_into_grades), 0),
    'in_process_kg', coalesce((select sum(app.available_qty(l.id)) from live l join chain c on c.st = l.stage_type, stop
                                where l.status = 'verified' and not l.lot_closed and not l.split_into_grades and c.i < stop.i), 0),
    'packed_packs', (select n from pk), 'packed_kg', (select kg from pk),
    'sold_kg', coalesce((select sum(qty_out) from live where stage_type = 'commercial' and status = 'verified'), 0),
    'shipped_kg', coalesce((select sum(qty_out) from live where stage_type = 'shipment' and status = 'verified'), 0),
    'released_packs', (select n from rel),
    'scans', (select n from sc),
    'copy_flags', (select count(*) from public.scan_flags where scope_id = p_scope and status = 'open'),
    'lab_waiting', (select n from waiting_lab), 'lab_failed', (select n from failed_lab),
    'lab_open', (select n from waiting_lab) + (select n from failed_lab),
    'recalls', (select count(*) from lastrel where status = 'recalled'),
    'investigations', (select count(*) from lastrel where status = 'under_investigation'),
    'waiting', (select n from pend) + (select n from waiting_lab) + (select n from fl))
$$;

-- 3 · the portfolio (C) ----------------------------------------------------------------------------------------------------
create or replace function app.cv_portfolio_data(p_client uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_rows jsonb; v_num constant text[] := array['procured_kg', 'in_process_kg', 'packed_packs', 'packed_kg', 'sold_kg', 'shipped_kg',
  'released_packs', 'scans', 'copy_flags', 'lab_open', 'lab_waiting', 'lab_failed', 'recalls', 'investigations', 'waiting'];
begin
  select coalesce(jsonb_agg(r order by r->>'state', r->>'crop', r->>'season', r->>'place'), '[]'::jsonb) into v_rows
    from (select jsonb_build_object('scope_id', s.id, 'state_id', s.state_id, 'state', st.name, 'crop_id', s.crop_id, 'crop', cr.name,
                   'season', s.season_code, 'place', s.geography, 'status', s.status, 'delivery_model', s.delivery_model,
                   'label', app.cv_scope_label(s.id)) || app.cv_scope_figures(s.id) as r
            from public.scopes s join public.crops cr on cr.id = s.crop_id left join public.states st on st.id = s.state_id
           where s.id in (select app.cv_scopes(p_client))) x;
  return jsonb_build_object(
    'scopes', v_rows,
    'groups', coalesce((select jsonb_agg(
                  jsonb_build_object('state_id', g.sid, 'state', g.st, 'crop_id', g.cid, 'crop', g.cr,
                    'scopes', (select count(*) from jsonb_array_elements(v_rows) r where r->>'state_id' is not distinct from g.sid and r->>'crop_id' = g.cid))
                  || (select jsonb_object_agg(k, (select coalesce(sum((r->>k)::numeric), 0) from jsonb_array_elements(v_rows) r
                                                   where r->>'state_id' is not distinct from g.sid and r->>'crop_id' = g.cid))
                        from unnest(v_num) k)
                  order by g.st, g.cr)
                from (select distinct r->>'state_id' as sid, r->>'state' as st, r->>'crop_id' as cid, r->>'crop' as cr
                        from jsonb_array_elements(v_rows) r) g), '[]'::jsonb),
    'total', jsonb_build_object('scopes', jsonb_array_length(v_rows)) ||
             (select jsonb_object_agg(k, coalesce((select sum((r->>k)::numeric) from jsonb_array_elements(v_rows) r), 0)) from unnest(v_num) k));
end $$;

-- 4 · one scope (C) ----------------------------------------------------------------------------------------------------------
create or replace function app.cv_scope_data(p_scope uuid, p_internal boolean) returns jsonb
language sql stable security definer set search_path = public as $$
  with s as (select * from public.scopes where id = p_scope),
  live as (select f.* from public.footprints f where f.scope_id = p_scope and f.status not in ('superseded', 'legacy')
             and not exists (select 1 from public.withdrawals w where w.footprint_id = f.id)),
  seals as (select q.*, f.footprint_code from public.qr_seals q join public.footprints f on f.id = q.footprint_id where f.scope_id = p_scope),
  bat as (select p.batch_code, count(*) filter (where p.status <> 'void') as packs, coalesce(sum(p.size_kg) filter (where p.status <> 'void'), 0) as kg,
                 min(p.best_before) filter (where p.status <> 'void') as best_before, min(p.packed_on) as packed_on
            from public.packs p where p.scope_id = p_scope group by p.batch_code)
  select jsonb_build_object(
    'head', app.export_scope_head(p_scope) || jsonb_build_object('scope_id', p_scope, 'label', app.cv_scope_label(p_scope),
              'delivery_model', (select delivery_model from s), 'markets', to_jsonb((select market_codes from s)),
              'gi_user_no', (select gi_user_no from s), 'chain', to_jsonb((select chain from s))),
    'figures', app.cv_scope_figures(p_scope),
    'pipeline', coalesce((select jsonb_agg(jsonb_build_object('stage', c.st, 'pos', c.i,
                   'records', (select count(*) from live l where l.stage_type = c.st),
                   'pending', (select count(*) from live l where l.stage_type = c.st and l.status = 'pending'),
                   'verified', (select count(*) from live l where l.stage_type = c.st and l.status = 'verified'),
                   'kg_out', coalesce((select sum(l.qty_out) from live l where l.stage_type = c.st and l.status = 'verified' and not l.split_into_grades), 0),
                   'kg_waiting', coalesce((select sum(app.available_qty(l.id)) from live l
                                            where l.stage_type = c.st and l.status = 'verified' and not l.lot_closed and not l.split_into_grades), 0))
                   order by c.i) from s cross join unnest(s.chain) with ordinality c(st, i)), '[]'::jsonb),
    'lots', coalesce((select jsonb_agg(jsonb_build_object('lot', q.footprint_code, 'qr_code', q.qr_code, 'sealed_at', q.sealed_at,
                   'batches', array_to_string(q.batch_codes, ', '), 'release', app.release_status(q.footprint_id) ->> 'status',
                   'packs_live', (select count(*) from app.lot_released_packs(q.footprint_id)))
                   order by q.sealed_at desc) from seals q), '[]'::jsonb),
    'batches', coalesce((select jsonb_agg(jsonb_build_object('batch_code', b.batch_code, 'packs', b.packs, 'kg', b.kg, 'packed_on', b.packed_on,
                   'best_before', b.best_before, 'released', coalesce(ps.released, 0) + coalesce(ps.old_data, 0), 'held', coalesce(ps.held, 0),
                   'void', coalesce(ps.void, 0)) order by b.batch_code)
                   from bat b left join app.scope_pack_states(p_scope) ps on ps.batch_code = b.batch_code), '[]'::jsonb),
    'qc', coalesce((select jsonb_agg(jsonb_build_object('code', l.footprint_code, 'status', l.status, 'tested_on', coalesce(l.happened_on, l.created_at::date),
                   'lab', coalesce((select name from public.labs where id::text = l.payload->>'lab_id'), l.payload->>'lab_name'),
                   'report_no', l.payload->>'report_no', 'report_date', l.payload->>'report_date',
                   'domestic', case when 'domestic' = any (s.market_codes) then v.domestic_verdict::text end,
                   'export', case when 'export' = any (s.market_codes) then v.export_verdict::text end,
                   'accepted', exists (select 1 from public.attachments a where a.footprint_id = l.id and a.label = 'acceptance'),
                   'decided', v.override is not null) order by l.created_at)
                   from live l cross join s left join public.qc_verdicts v on v.footprint_id = l.id where l.stage_type = 'qc'), '[]'::jsonb),
    'documents', coalesce((select jsonb_agg(d order by d->>'kind', d->>'what') from (
                   select jsonb_build_object('kind', 'export_doc', 'what', e.doc, 'status', e.status, 'record', f.footprint_code,
                            'on_file', e.attachment_id is not null, 'at', e.set_at) as d
                     from public.export_documents e join public.footprints f on f.id = e.footprint_id where e.scope_id = p_scope
                   union all
                   select jsonb_build_object('kind', 'lab_report', 'what', coalesce(l.payload->>'report_no', l.footprint_code), 'status', l.status,
                            'record', l.footprint_code, 'on_file', exists (select 1 from public.attachments a where a.footprint_id = l.id),
                            'at', l.created_at)
                     from live l where l.stage_type = 'qc'
                   union all
                   select jsonb_build_object('kind', 'gi_user', 'what', s.gi_user_no, 'status', 'recorded', 'record', null,
                            'on_file', s.gi_user_file is not null, 'at', null)
                     from s where s.gi_user_no is not null) x), '[]'::jsonb),
    'reports', coalesce((select jsonb_agg(jsonb_build_object('ref', r.ref, 'kind', r.kind, 'final', r.final, 'version', r.version, 'status', r.status,
                   'issued_at', r.issued_at) order by r.issued_at desc) from public.reports r where r.scope_id = p_scope), '[]'::jsonb),
    -- the people on each stage: name and role only (never a phone, an email or an HR fact)
    'people', coalesce((select jsonb_agg(jsonb_build_object('stage', sa.stage_type, 'name', u.display_name, 'client_staff', u.external)
                   order by array_position((select chain from s), sa.stage_type), u.display_name)
                   from public.slot_assignments sa join public.assignments a on a.id = sa.assignment_id join public.app_users u on u.id = sa.user_id
                  where sa.scope_id = p_scope and a.active and (a.ends_on is null or a.ends_on >= app.today()) and u.status = 'active'), '[]'::jsonb),
    'internal', p_internal)
$$;

-- 5 · across scopes (C) -------------------------------------------------------------------------------------------------------
create or replace function app.cv_across_data(p_client uuid, p_internal boolean) returns jsonb
language sql stable security definer set search_path = public as $$
  with sc as (select id from app.cv_scopes(p_client) id),
  live as (select f.* from public.footprints f where f.scope_id in (select id from sc) and f.status not in ('superseded', 'legacy')
             and not exists (select 1 from public.withdrawals w where w.footprint_id = f.id)),
  ord as (select o.*, coalesce((select b.name from public.buyers b where b.id::text = o.payload->>'buyer_id'), o.payload->>'buyer') as buyer_name,
                 coalesce((select sum(x.qty_out) from live x where x.stage_type = 'shipment' and x.status = 'verified'
                            and (x.prev_footprint_id = o.id or exists (select 1 from public.footprint_links k where k.child_id = x.id and k.parent_id = o.id))), 0) as shipped
            from live o where o.stage_type = 'commercial'),
  seals as (select q.footprint_id as seal_id, q.qr_code, f.scope_id from public.qr_seals q join public.footprints f on f.id = q.footprint_id
             where f.scope_id in (select id from sc)),
  sx as (select x.* from public.scans x
          where (x.kind = 'pack' and exists (select 1 from public.packs p where p.serial = x.code and p.scope_id in (select id from sc)))
             or (x.kind = 'lot' and exists (select 1 from seals q where q.qr_code = x.code)))
  select jsonb_build_object(
    'orders', coalesce((select jsonb_agg(jsonb_build_object('code', o.footprint_code, 'scope_id', o.scope_id, 'scope', app.cv_scope_label(o.scope_id),
                   'on', coalesce(o.happened_on, o.created_at::date), 'buyer', o.buyer_name, 'market', o.payload->>'market',
                   'destination_country', o.payload->>'destination_country', 'order_no', o.payload->>'order_no', 'qty_kg', o.qty_out,
                   'shipped_kg', o.shipped, 'status', o.status)
                 || case when p_internal then jsonb_build_object(
                   'price_per_kg', coalesce(st.price_per_kg, (o.payload->>'price_per_kg')::numeric),
                   'currency', coalesce(st.currency, o.payload->>'currency'),
                   'total_value', coalesce(st.total_value, round(o.qty_out * (o.payload->>'price_per_kg')::numeric, 2))) else '{}'::jsonb end
                 order by o.created_at desc)
                 from ord o left join public.sale_terms st on st.footprint_id = o.id), '[]'::jsonb),
    'buyers', coalesce((select jsonb_agg(jsonb_build_object('buyer', b.buyer, 'orders', b.n, 'qty_kg', b.kg, 'shipped_kg', b.sh) order by b.kg desc, b.buyer)
                 from (select coalesce(buyer_name, '—') as buyer, count(*) as n, coalesce(sum(qty_out), 0) as kg, coalesce(sum(shipped), 0) as sh
                         from ord group by coalesce(buyer_name, '—')) b), '[]'::jsonb),
    'scans_by_city', coalesce((select jsonb_agg(jsonb_build_object('city', c.city, 'region', c.region, 'country', c.country, 'scans', c.n, 'last_at', c.last_at)
                 order by c.n desc, c.city) from (select city, region, country, count(*) as n, max(at) as last_at from sx group by city, region, country) c), '[]'::jsonb),
    'copy_flags', coalesce((select jsonb_agg(jsonb_build_object('serial', g.serial, 'kind', g.kind, 'status', g.status, 'raised_at', g.raised_at,
                 'scope', app.cv_scope_label(g.scope_id)) order by g.raised_at desc)
                 from public.scan_flags g where g.scope_id in (select id from sc)), '[]'::jsonb),
    'recalls', coalesce((select jsonb_agg(jsonb_build_object('qr_code', q.qr_code, 'scope', app.cv_scope_label(q.scope_id), 'status', e.status,
                 'reason', e.reason, 'at', e.at) order by e.at desc)
                 from seals q join lateral (select * from public.release_events e where e.seal_id = q.seal_id order by e.seq desc limit 1) e on true
                where e.status in ('recalled', 'under_investigation')), '[]'::jsonb),
    'outputs', coalesce((select jsonb_agg(jsonb_build_object('ref', r.ref, 'kind', r.kind, 'final', r.final, 'version', r.version, 'status', r.status,
                 'issued_at', r.issued_at, 'scope', app.cv_scope_label(r.scope_id)) order by r.issued_at desc)
                 from public.reports r where r.scope_id in (select id from sc)), '[]'::jsonb),
    'internal', p_internal)
$$;

-- 6 · the farmers (C): the client's own (its farmer records are their consent to it); never a phone; a name only inside
-- (a client account: those of the scopes it reaches, migration 67; GrainVeda: those its own rules let it read)
create or replace function app.cv_farmer_row(f public.farmers, p_internal boolean) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('farmer_code', f.farmer_code, 'village', f.village, 'block', f.block, 'district', f.district,
           'state', (select name from public.states where id = f.state_id), 'land_area_acres', f.land_area_acres,
           'gi_land_acres', f.gi_land_acres, 'status', f.status)
      || case when p_internal then jsonb_build_object('name', f.name) else '{}'::jsonb end
$$;

create or replace function app.cv_farmers_data(p_client uuid, p_internal boolean) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(app.cv_farmer_row(f, p_internal) order by f.farmer_code), '[]'::jsonb)
    from public.farmers f
   where f.client_id = p_client
     and case when app.is_client_login() then app.account_sees_farmer(app.current_user_id(), f.id, f.client_id, f.state_id)
              else app.farmer_read(f.client_id, f.state_id) end      -- the rule the farmers' own table reads by
$$;
-- 7 · the screens (C) -------------------------------------------------------------------------------------------------------
create or replace function app.client_portfolio(p_client uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not app.cv_may_client(p_client) then raise exception 'not allowed to read this client''s portfolio' using errcode = '42501'; end if;
  return app.cv_portfolio_data(p_client)
      || jsonb_build_object('client', (select jsonb_build_object('id', c.id, 'name', c.name, 'code', c.code) from public.clients c where c.id = p_client),
                            'may_internal', app.cv_internal_client(p_client));
end $$;

create or replace function app.client_scope_detail(p_scope uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not app.cv_may_scope(p_scope) then raise exception 'not allowed to read this scope' using errcode = '42501'; end if;
  return app.cv_scope_data(p_scope, app.cv_internal_scope(p_scope))
      || jsonb_build_object('client', (select jsonb_build_object('id', c.id, 'name', c.name, 'code', c.code)
                                         from public.scopes s join public.clients c on c.id = s.client_id where s.id = p_scope),
                            'may_internal', app.cv_internal_scope(p_scope));
end $$;

create or replace function app.client_across(p_client uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not app.cv_may_client(p_client) then raise exception 'not allowed to read this client''s portfolio' using errcode = '42501'; end if;
  return app.cv_across_data(p_client, app.cv_internal_client(p_client))
      || jsonb_build_object('client', (select jsonb_build_object('id', c.id, 'name', c.name, 'code', c.code) from public.clients c where c.id = p_client),
                            'may_internal', app.cv_internal_client(p_client));
end $$;

-- 8 · the exports (E4): the screen's own data as tables, one per part of the view --------------------------------------------
-- a table from rows of the data: the columns named (in this order), each row's values; a column the copy may not carry
-- is never asked for (the data of a shareable copy holds no price and no name to begin with)
create or replace function app.cv_table(p_key text, p_rows jsonb, p_cols text[]) returns jsonb
language sql immutable as $$
  select jsonb_build_object('key', p_key, 'columns', to_jsonb(p_cols),
           'rows', coalesce((select jsonb_agg((select jsonb_agg(r -> c order by o) from unnest(p_cols) with ordinality t(c, o)) order by n)
                               from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) with ordinality x(r, n)), '[]'::jsonb))
$$;

create or replace function app.cv_figure_cols() returns text[]
language sql immutable as $$
  select array['procured_kg', 'in_process_kg', 'packed_packs', 'packed_kg', 'sold_kg', 'shipped_kg', 'released_packs', 'scans', 'copy_flags',
               'lab_open', 'recalls', 'waiting']
$$;

create or replace function app.export_client_view(p_view text, p_client uuid default null, p_scope uuid default null, p_copy text default 'shareable')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_int boolean; v_client uuid; d jsonb; tabs jsonb; v_target uuid; v_rows int;
begin
  if p_copy is null or p_copy not in ('shareable', 'internal') then
    raise exception 'an export is a shareable or an internal copy' using errcode = '22023'; end if;
  if p_view is null or p_view not in ('portfolio', 'scope', 'farmers', 'across') then
    raise exception 'a view is the portfolio, one scope, the farmers or across scopes' using errcode = '22023'; end if;
  if p_view = 'scope' then
    if p_scope is null or not app.cv_may_scope(p_scope) then raise exception 'not allowed to export this scope' using errcode = '42501'; end if;
    v_client := (select client_id from public.scopes where id = p_scope); v_target := p_scope;
    v_int := p_copy = 'internal';
    if v_int and not app.cv_internal_scope(p_scope) then
      raise exception 'the internal copy is for the people of this scope, the client''s owner and the viewers it allowed: take the shareable copy'
        using errcode = '42501'; end if;
  else
    if p_client is null or not app.cv_may_client(p_client) then raise exception 'not allowed to export this client''s views' using errcode = '42501'; end if;
    v_client := p_client; v_target := p_client;
    v_int := p_copy = 'internal';
    if v_int and not app.cv_internal_client(p_client) then
      raise exception 'the internal copy is for the people of this client, its owner and the viewers it allowed: take the shareable copy'
        using errcode = '42501'; end if;
  end if;

  if p_view = 'portfolio' then
    d := app.cv_portfolio_data(p_client);
    tabs := jsonb_build_array(
      app.cv_table('scopes', d->'scopes', array['state', 'crop', 'season', 'place', 'status', 'delivery_model'] || app.cv_figure_cols()),
      app.cv_table('groups', d->'groups', array['state', 'crop', 'scopes'] || app.cv_figure_cols()),
      app.cv_table('total', jsonb_build_array(d->'total'), array['scopes'] || app.cv_figure_cols()));
  elsif p_view = 'scope' then
    d := app.cv_scope_data(p_scope, v_int);
    tabs := jsonb_build_array(
      app.cv_table('pipeline', d->'pipeline', array['pos', 'stage', 'records', 'pending', 'verified', 'kg_out', 'kg_waiting']),
      app.cv_table('lots', d->'lots', array['lot', 'qr_code', 'sealed_at', 'batches', 'release', 'packs_live']),
      app.cv_table('batches', d->'batches', array['batch_code', 'packs', 'kg', 'packed_on', 'best_before', 'released', 'held', 'void']),
      app.cv_table('qc', d->'qc', array['code', 'status', 'tested_on', 'lab', 'report_no', 'report_date', 'domestic', 'export', 'accepted', 'decided']),
      app.cv_table('documents', d->'documents', array['kind', 'what', 'status', 'record', 'on_file', 'at']),
      app.cv_table('reports', d->'reports', array['ref', 'kind', 'final', 'version', 'status', 'issued_at']),
      app.cv_table('people', d->'people', array['stage', 'name', 'client_staff']));
  elsif p_view = 'across' then
    d := app.cv_across_data(p_client, v_int);
    tabs := jsonb_build_array(
      app.cv_table('orders', d->'orders', array['code', 'scope', 'on', 'buyer', 'market', 'destination_country', 'order_no', 'qty_kg', 'shipped_kg', 'status']
                     || case when v_int then array['price_per_kg', 'currency', 'total_value'] else '{}'::text[] end),
      app.cv_table('buyers', d->'buyers', array['buyer', 'orders', 'qty_kg', 'shipped_kg']),
      app.cv_table('scans_by_city', d->'scans_by_city', array['city', 'region', 'country', 'scans', 'last_at']),
      app.cv_table('copy_flags', d->'copy_flags', array['serial', 'kind', 'status', 'raised_at', 'scope']),
      app.cv_table('recalls', d->'recalls', array['qr_code', 'scope', 'status', 'reason', 'at']),
      app.cv_table('outputs', d->'outputs', array['ref', 'kind', 'final', 'version', 'status', 'issued_at', 'scope']));
  else
    d := app.cv_farmers_data(p_client, v_int);
    tabs := jsonb_build_array(app.cv_table('farmers', d,
      case when v_int then array['farmer_code', 'name'] else array['farmer_code'] end
      || array['village', 'block', 'district', 'state', 'land_area_acres', 'gi_land_acres', 'status']));
  end if;

  select coalesce(sum(jsonb_array_length(x->'rows')), 0) into v_rows from jsonb_array_elements(tabs) x;
  perform app.audit('export_downloaded', v_target, jsonb_build_object('kind', 'client_view', 'view', p_view, 'copy', p_copy,
    'client_id', v_client, 'rows', v_rows), false);
  return jsonb_build_object('kind', 'client_view', 'view', p_view, 'copy', p_copy,
    'generated_at', to_char(now() at time zone 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI'), 'generated_by', app.export_made_by(),
    'client', (select jsonb_build_object('name', c.name, 'code', c.code) from public.clients c where c.id = v_client),
    'scope', case when p_view = 'scope' then app.export_scope_head(p_scope) || jsonb_build_object('label', app.cv_scope_label(p_scope)) end,
    'units', case when p_view = 'scope' then app.param_units(p_scope) else '{}'::jsonb end,
    'tables', tabs);
end $$;

-- 8b · the functions replaced, each from its text as migration 67 left it, with the change named ------------------------
-- item 65: People → Client logins says what each client account is (its staff had nothing under access)
CREATE OR REPLACE FUNCTION app.people_page(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise(); full_view boolean; v_kind text := coalesce(nullif(p->>'kind', ''), 'employees');
        v_q text := nullif(lower(btrim(p->>'q')), ''); v_status text := nullif(p->>'status', ''); v_state uuid := nullif(p->>'state', '')::uuid;
        v_client uuid := nullif(p->>'client', '')::uuid; v_role text := nullif(p->>'role', ''); v_open uuid := nullif(p->>'opening', '')::uuid;
        v_owner text := nullif(p->>'owner', ''); v_unass boolean := coalesce((p->>'unassigned')::boolean, false);
        v_limit int := least(greatest(coalesce((p->>'limit')::int, 50), 1), 200); v_offset int := greatest(coalesce((p->>'offset')::int, 0), 0);
        v_digits text; res jsonb; v_limited boolean := app.is_hr() and not app.hr_full(); v_mine uuid[] := app.my_hr_states();
        v_cm boolean := app.cm_limited();                                       -- migration 59 (B4)
begin
  full_view := app.is_admin() or app.is_hr();
  if not (full_view or app.can_assign()) then
    raise exception 'the people directory is for HR and for those who assign' using errcode = '42501'; end if;
  v_digits := regexp_replace(coalesce(v_q, ''), '[^0-9]', '', 'g');
  with vis as (
    select u.*, o.employment_type, o.designation_band, o.department, o.job_title, o.reports_to, o.opening_id, o.intended_role,
           o.intended_stage, o.hr_owner, o.base_state_id, o.base_district
      from public.app_users u left join public.employee_org o on o.employee_id = u.id
     where ((not u.external and (full_view or u.status <> 'offboarded')) or (u.external and (app.is_admin() or app.manages_viewer(u.id))))
       and (not v_limited or u.id = me or o.base_state_id = any(v_mine))
       and (full_view or u.external or not (select app.sm_limited()) or u.id in (select unnest(app.sm_seen_ids())))   -- migration 41
       and (full_view or u.external or not (select app.cm_limited()) or u.id in (select unnest(app.cm_seen_ids())))   -- migration 44 (A4)
       and not u.test_data                                                                                            -- migration 44 (G7)
  ), f as (
    select v.* from vis v
     where (v_kind = 'client_logins') = v.external
       and (v_q is null or lower(v.display_name) like '%' || v_q || '%' or (not v_cm and lower(coalesce(v.email, '')) like '%' || v_q || '%')
            or (not v_cm and v_q ~ '^[0-9+ -]{4,}$' and coalesce(v.phone, '') like '%' || v_digits || '%')
            or lower(coalesce(v.job_title, '')) like '%' || v_q || '%')
       and (v_status is null or v.status::text = v_status)
       and (v_state is null or exists (select 1 from public.assignments a left join public.scopes s on s.id = a.scope_id left join public.clients c on c.id = a.client_id
                                        where a.employee_id = v.id and a.active and (full_view or app.assignment_visible(a)) and v_state in (a.state_id, s.state_id, c.state_id))
            or exists (select 1 from public.openings op where op.id = v.opening_id and op.state_id = v_state)
            or v.base_state_id = v_state)
       and (v_client is null or exists (select 1 from public.assignments a left join public.scopes s on s.id = a.scope_id
                                         where a.employee_id = v.id and a.active and (full_view or app.assignment_visible(a)) and v_client in (a.client_id, s.client_id)))
       and (v_role is null or v.intended_role = v_role)
       and (v_open is null or v.opening_id = v_open)
       and (v_owner is null or (v_owner = 'mine' and v.hr_owner = me) or (v_owner not in ('mine', 'none') and v.hr_owner::text = v_owner)
            or (v_owner = 'none' and v.hr_owner is null))
       and (not v_unass or not exists (select 1 from public.assignments a where a.employee_id = v.id and a.active))
  )
  select jsonb_build_object(
    'total', (select count(*) from f),
    'counts', (select jsonb_build_object('employees', count(*) filter (where not external), 'client_logins', count(*) filter (where external)) from vis),
    'rows', coalesce((select jsonb_agg(x.j order by x.external, x.display_name) from (
      select f.external, f.display_name, jsonb_build_object(
             'id', f.id, 'name', f.display_name, 'email', case when v_cm and not f.external then null else f.email end,                              -- migration 59 (B4)
             'phone', case when v_cm and not f.external and not app.cm_phone_ok(f.id) then null else f.phone end, 'status', f.status, 'system_role', f.system_role,
             'external', f.external, 'join_date', f.join_date, 'has_login', f.auth_uid is not null and f.auth_uid <> f.id,
             'client_account', (select jsonb_build_object('kind', ca.kind, 'status', ca.status, 'client_name', c3.name)          -- migration 68 (item 65)
                                  from public.client_accounts ca join public.clients c3 on c3.id = ca.client_id where ca.user_id = f.id),
             'role', f.intended_role, 'stage', f.intended_stage,
             'opening_code', (select code from public.openings where id = f.opening_id),
             'base', jsonb_build_object('state_id', f.base_state_id, 'state_name', (select name from public.states where id = f.base_state_id),
                                        'district', f.base_district),
             'org', jsonb_build_object('employment_type', f.employment_type, 'designation_band', f.designation_band,
                      'department', f.department, 'job_title', f.job_title,
                      'reports_to_name', (select display_name from public.app_users where id = f.reports_to)),
             'assignments', coalesce((select jsonb_agg(app.assignment_json(a) order by a.lens, a.created_at)
                                        from public.assignments a where a.employee_id = f.id and a.active and app.assignment_visible(a)), '[]'::jsonb),
             'elsewhere', case when app.cm_limited() then 0 else (select count(*) from public.assignments a where a.employee_id = f.id and a.active and not app.assignment_visible(a)) end,   -- migration 57 (G20)
             'unassigned', not exists (select 1 from public.assignments a where a.employee_id = f.id and a.active),
             'assignable', app.may_offer_assign_seen(f.id)) as j
        from f order by f.external, f.display_name limit v_limit offset v_offset) x), '[]'::jsonb),
    'limit', v_limit, 'offset', v_offset) into res;
  return res;
end $function$;

-- item 65: the person's page says what a client account is (an owner read "Client login (read-only)")
CREATE OR REPLACE FUNCTION app.employee_profile(p_employee uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise(); u public.app_users; o public.employee_org; full_view boolean; hr_ok boolean;
begin
  select * into u from public.app_users where id = p_employee;
  full_view := app.is_admin() or (app.is_hr() and (app.hr_full() or app.hr_covers(p_employee)));
  if u.id is null or not (u.id = me or (not u.external and (full_view or (app.can_assign() and u.status <> 'offboarded' and (not app.sm_limited() or app.sm_sees(u.id)) and (not app.cm_limited() or u.id = any (app.cm_seen_ids())) and not u.test_data)))
                          or (u.external and (app.is_admin() or app.manages_viewer(u.id)))) then
    raise exception 'person not found' using errcode = 'P0002'; end if;
  select * into o from public.employee_org where employee_id = u.id;
  hr_ok := app.may_manage_person(u.id);
  return jsonb_build_object(
    'identity', jsonb_build_object('id', u.id, 'name', u.display_name,
                  'email', case when u.id <> me and not u.external and app.cm_limited() then null else u.email end,              -- migration 59 (B4)
                  'phone', case when u.id <> me and not u.external and app.cm_limited() and not app.cm_phone_ok(u.id) then null else u.phone end,
                  'status', u.status,
                  'external', u.external, 'join_date', u.join_date, 'created_at', u.created_at,
                  'has_login', u.auth_uid is not null and u.auth_uid <> u.id,
                  'client_account', (select jsonb_build_object('kind', ca.kind, 'status', ca.status, 'client_name', c3.name)          -- migration 68 (item 65)
                                  from public.client_accounts ca join public.clients c3 on c3.id = ca.client_id where ca.user_id = u.id)),
    'org', jsonb_build_object('employment_type', o.employment_type, 'designation_band', o.designation_band, 'department', o.department,
             'job_title', o.job_title, 'reports_to_name', (select display_name from public.app_users where id = o.reports_to),
             'buddy_name', (select display_name from public.app_users where id = o.buddy)),
    'system_role', u.system_role,
    'assignments', coalesce((select jsonb_agg(app.assignment_json(a) order by a.lens, a.created_at)
                               from public.assignments a where a.employee_id = u.id and a.active and app.assignment_visible(a)), '[]'::jsonb),
    'history', coalesce((select jsonb_agg(app.assignment_json(a) order by a.ended_at desc)
                           from public.assignments a where a.employee_id = u.id and not a.active and app.assignment_visible(a)), '[]'::jsonb),
    'elsewhere', case when app.cm_limited() then 0 else (select count(*) from public.assignments a where a.employee_id = u.id and a.active and not app.assignment_visible(a)) end,   -- migration 57 (G20)
    'exits', case when app.acts_as_hr() then coalesce((select jsonb_agg(jsonb_build_object('exit_date', e.exit_date, 'reason', e.reason) order by e.created_at desc)
                                                   from public.employee_exits e where e.employee_id = u.id), '[]'::jsonb) else '[]'::jsonb end,
    'can', jsonb_build_object(
      'assign', app.may_offer_assign(u.id),   -- migration 44
      'suspend', hr_ok and u.status in ('invited', 'onboarding', 'active'),
      'reinstate', hr_ok and u.status = 'suspended',
      'offboard', hr_ok and u.status <> 'offboarded',
      'rehire', hr_ok and u.status = 'offboarded' and not u.external,
      'reset_login', app.reset_login_allowed(u.id),
      'set_role', not u.external and u.id <> me and u.system_role in ('operational', 'hr_resource')
                  and (app.is_hr_admin() or (app.is_admin() and not app.hr_seat_filled())),
      'hr_record', app.acts_as_hr() and not u.external));
end $function$;

-- the probe: a person's own rows are his own (an ended assignment of a client he no longer works for was counted as a leak)
CREATE OR REPLACE FUNCTION app.isolation_probe(p_functions boolean DEFAULT true, p_read_only boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'app'
AS $function$
declare
  u record; t record; fn record; probe record;
  v_clients uuid[]; v_rows jsonb; v_res jsonb; v_base jsonb; v_txt text; r jsonb; v_owner uuid;
  leaks jsonb := '[]'::jsonb; own_seen int := 0; people int := 0; tables int := 0; calls int := 0; refused int := 0;
  cols text; ids jsonb := '[]'::jsonb; v_key text; v_done text[] := '{}';
  link_cols constant text[] := array['id', 'client_id', 'scope_id', 'footprint_id', 'seal_id', 'farmer_id', 'attachment_id',
                                     'requirement_id', 'buyer_id', 'employee_id', 'user_id', 'link_id'];   -- link_id: migration 56b
begin
  if current_user in ('authenticated', 'anon') then raise exception 'the isolation probe is run by the database owner' using errcode = '42501'; end if;
  -- from here the transaction writes nothing (a function that would write, called as someone, fails)
  if p_read_only then perform set_config('transaction_read_only', 'on', true); end if;
  -- the ids other clients' records go by: a few records of every stage, the scopes, farmers, the client's lists, files,
  -- samples, sales' terms and documents, people
  select coalesce(jsonb_agg(jsonb_build_object('kind', k, 'id', id, 'client', client_id)), '[]'::jsonb) into ids from (
    select 'footprint:' || stage_type as k, id, client_id from (
      select f.*, row_number() over (partition by f.client_id, f.stage_type order by f.created_at desc) n from public.footprints f) x where n <= 2
    union all select 'scope', id, client_id from public.scopes
    union all select 'farmer', id, client_id from (select fa.*, row_number() over (partition by client_id order by created_at desc) n from public.farmers fa) x where n <= 3
    union all select 'buyer', id, client_id from public.buyers
    union all select 'collection_point', id, client_id from public.collection_points
    union all select 'mill', id, client_id from public.mills
    union all select 'packing_unit', id, client_id from public.packing_units
    union all select 'pack_sku', id, client_id from public.pack_skus
    union all select 'lab', id, client_id from public.labs where client_id is not null
    union all select 'attachment', a.id, f.client_id from (select a.*, row_number() over (partition by a.footprint_id order by a.created_at) n from public.attachments a) a
                join public.footprints f on f.id = a.footprint_id where a.n = 1
    union all select 'sample', id, client_id from public.qc_samples
    union all select 'client', id, id from public.clients) z;

  for u in
    select au.id, au.auth_uid, au.role,
           array_remove(array(select distinct c from unnest(array[au.client_id]
             || array(select a.client_id from app.eff_assignments(au.id) a where a.client_id is not null)
             || array(select s.client_id from app.eff_assignments(au.id) a join public.scopes s on s.id = a.scope_id)) c), null) as clients
      from public.app_users au
     where au.active and coalesce(au.system_role, 'operational') = 'operational' and au.role <> 'admin' and au.role <> 'state_manager'
       and not exists (select 1 from app.eff_assignments(au.id) a where a.lens = 'state')
     order by au.id
  loop
    people := people + 1;
    v_clients := u.clients;
    -- 1 · the tables, as him
    for t in
      select c.relname, array(select a.attname::text from pg_attribute a where a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
                                and a.attname::text = any (link_cols)
                                and has_column_privilege('authenticated', c.oid, a.attname, 'select') order by a.attnum) as cs   -- migration 56b
        from pg_class c join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public' and c.relkind = 'r' and has_any_column_privilege('authenticated', c.oid, 'select')   -- migration 56b
       order by c.relname
    loop
      if cardinality(t.cs) = 0 or t.cs = array['id'] or t.relname = 'app_users' or t.relname like 'employee\_%' then continue; end if;
      cols := (select string_agg(quote_ident(x), ', ') from unnest(t.cs) x);
      perform set_config('request.jwt.claims', json_build_object('sub', u.auth_uid, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      begin
        execute format('select coalesce(jsonb_agg(to_jsonb(x)), ''[]''::jsonb) from (select %s from public.%I limit 5000) x', cols, t.relname) into v_rows;
      exception when others then v_rows := '[]'::jsonb;
      end;
      execute 'reset role';
      perform set_config('request.jwt.claims', '', true);
      if people = 1 then tables := tables + 1; end if;
      for r in select * from jsonb_array_elements(v_rows) loop
        if r ->> 'employee_id' = u.id::text or r ->> 'user_id' = u.id::text then own_seen := own_seen + 1; continue; end if;   -- migration 68: his own row
        v_owner := app.isolation_owner(t.relname, r);
        if v_owner is null then continue; end if;
        if v_owner = any (v_clients) then own_seen := own_seen + 1;
        else leaks := leaks || jsonb_build_object('kind', 'table', 'what', t.relname, 'person', left(u.id::text, 8), 'role', u.role);
             exit;
        end if;
      end loop;
    end loop;

    -- 2 · the functions, as him, with other clients' ids: once for each kind of person (role and clients)
    v_key := u.role || ':' || coalesce(array_to_string(array(select x::text from unnest(v_clients) x order by 1), ','), '');
    if p_functions and not (v_key = any (v_done)) then
      v_done := v_done || v_key;
      for fn in
        select p.oid, n.nspname || '.' || p.proname as name, p.proname
          from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'app' and p.prokind = 'f' and has_function_privilege('authenticated', p.oid, 'execute')
           and p.pronargs - p.pronargdefaults = 1 and p.proargtypes[0] = 'uuid'::regtype
           and p.prorettype <> 'trigger'::regtype
         order by 2
      loop
        -- what the function answers for an id that is nobody's: an answer like it is no data (a default, "pending")
        perform set_config('request.jwt.claims', json_build_object('sub', u.auth_uid, 'role', 'authenticated')::text, true);
        execute 'set local role authenticated';
        begin
          execute format('select to_jsonb(%s($1))', fn.name) using gen_random_uuid() into v_base;
        exception when others then v_base := null;
        end;
        execute 'reset role';
        perform set_config('request.jwt.claims', '', true);
        for probe in select x->>'kind' as kind, (x->>'id')::uuid as id from jsonb_array_elements(ids) x
                      where not ((x->>'client')::uuid = any (v_clients)) loop
          calls := calls + 1;
          perform set_config('request.jwt.claims', json_build_object('sub', u.auth_uid, 'role', 'authenticated')::text, true);
          execute 'set local role authenticated';
          begin
            execute format('select to_jsonb(%s($1))', fn.name) using probe.id into v_res;
          exception when others then v_res := null; refused := refused + 1;
          end;
          execute 'reset role';
          perform set_config('request.jwt.claims', '', true);
          v_txt := coalesce(v_res::text, 'null');
          if v_res is distinct from v_base and v_txt not in ('null', '[]', '{}', 'false', '0', '""')
             and not (jsonb_typeof(v_res) = 'object' and not exists (select 1 from jsonb_each(v_res) e where e.value not in ('null'::jsonb, '[]'::jsonb, '{}'::jsonb, 'false'::jsonb, '0'::jsonb))) then
            leaks := leaks || jsonb_build_object('kind', 'function', 'what', fn.proname, 'with', probe.kind, 'person', left(u.id::text, 8), 'role', u.role);
          end if;
        end loop;
      end loop;
    end if;
  end loop;

  return jsonb_build_object('people', people, 'tables', tables, 'calls', calls, 'refused', refused, 'own_rows_seen', own_seen,
    'clients', (select count(*) from public.clients), 'daily_code', app.daily_code_on(),
    'leaks', (select coalesce(jsonb_agg(distinct x), '[]'::jsonb) from jsonb_array_elements(leaks) x));
end $function$;


-- 9 · grants: the screens and the export are the way in ----------------------------------------------------------------------
revoke execute on function app.cv_may_scope(uuid), app.cv_may_client(uuid), app.cv_scopes(uuid), app.cv_internal_scope(uuid),
  app.cv_internal_client(uuid), app.cv_scope_label(uuid), app.cv_scope_figures(uuid), app.cv_portfolio_data(uuid),
  app.cv_scope_data(uuid, boolean), app.cv_across_data(uuid, boolean), app.cv_farmers_data(uuid, boolean),
  app.cv_farmer_row(public.farmers, boolean), app.cv_table(text, jsonb, text[]), app.cv_figure_cols()
  from public, anon, authenticated;
revoke execute on function app.client_portfolio(uuid), app.client_scope_detail(uuid), app.client_across(uuid),
  app.export_client_view(text, uuid, uuid, text) from public, anon;
grant execute on function app.client_portfolio(uuid), app.client_scope_detail(uuid), app.client_across(uuid),
  app.export_client_view(text, uuid, uuid, text) to authenticated;

notify pgrst, 'reload schema';
