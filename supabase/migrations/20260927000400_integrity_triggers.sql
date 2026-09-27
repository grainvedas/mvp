-- GrainVeda MVP · Phase 0 · migration 4: helpers, integrity rules 1–9 (PRD §8), per-stage reconciliation (PRD §7),
-- QC verdict derivation, market-verdict chain walk, ledger hash chain, scope activation, QR seal.
-- Every rule here is the server-side truth; the front-end mirrors it for live review only.

-- ===========================================================================
-- A. Identity helpers
-- ===========================================================================

-- The app_users row for the current JWT (null for service role / seed scripts).
create or replace function app.current_user_id() returns uuid
language sql stable security definer set search_path = public as $$
  select id from public.app_users where auth_uid = auth.uid() and active
$$;

create or replace function app.current_role() returns public.user_role
language sql stable security definer set search_path = public as $$
  select role from public.app_users where auth_uid = auth.uid() and active
$$;

create or replace function app.user_role_of(p_user uuid) returns public.user_role
language sql stable security definer set search_path = public as $$
  select role from public.app_users where id = p_user
$$;

-- Gateway roles may act at any stage; every such act is ledgered as 'supervisory'.
create or replace function app.is_gateway_role(r public.user_role) returns boolean
language sql immutable as $$ select r in ('admin','state_manager','client_manager') $$;

create or replace function app.is_gateway() returns boolean
language sql stable as $$ select coalesce(app.is_gateway_role(app.current_role()), false) $$;

-- ===========================================================================
-- B. Chain helpers (thumb rule: prev/next resolved from the scope's frozen chain, never hardcoded)
-- ===========================================================================

create or replace function app.chain_index(p_scope uuid, p_stage public.stage_type) returns int
language sql stable as $$
  select i from public.scopes s, unnest(s.chain) with ordinality as c(st, i)
  where s.id = p_scope and c.st = p_stage
$$;

create or replace function app.chain_prev(p_scope uuid, p_stage public.stage_type) returns public.stage_type
language sql stable as $$
  select s.chain[app.chain_index(p_scope, p_stage) - 1] from public.scopes s where s.id = p_scope
$$;

create or replace function app.chain_next(p_scope uuid, p_stage public.stage_type) returns public.stage_type
language sql stable as $$
  select s.chain[app.chain_index(p_scope, p_stage) + 1] from public.scopes s where s.id = p_scope
$$;

-- Does p_user hold the slot for p_stage in p_scope?
create or replace function app.has_slot(p_user uuid, p_scope uuid, p_stage public.stage_type) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.slot_assignments
                 where user_id = p_user and scope_id = p_scope and stage_type = p_stage)
$$;

-- isMyStage: operator may create only at an assigned stage; gateway roles bypass (ledgered).
create or replace function app.is_my_stage(p_user uuid, p_scope uuid, p_stage public.stage_type) returns boolean
language sql stable security definer set search_path = public as $$
  select app.is_gateway_role(app.user_role_of(p_user)) or app.has_slot(p_user, p_scope, p_stage)
$$;

-- isNextStageUser: the RECEIVING stage's operator verifies the record behind it.
create or replace function app.is_next_stage_user(p_user uuid, p_scope uuid, p_prev_stage public.stage_type) returns boolean
language sql stable security definer set search_path = public as $$
  select app.is_gateway_role(app.user_role_of(p_user))
      or app.has_slot(p_user, p_scope, app.chain_next(p_scope, p_prev_stage))
$$;

-- Can the current JWT see this scope at all? (RLS uses this.)
create or replace function app.can_access_scope(p_scope uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1
    from public.app_users u
    join public.scopes s on s.id = p_scope
    join public.clients c on c.id = s.client_id
    where u.auth_uid = auth.uid() and u.active and (
         u.role = 'admin'
      or (u.role = 'state_manager' and c.state_id = any(u.state_ids))
      or (u.role in ('client_manager','client_view') and u.client_id = s.client_id)
      or (u.role = 'operator' and exists (select 1 from public.slot_assignments sa where sa.user_id = u.id and sa.scope_id = s.id))
    )
  )
$$;

create or replace function app.can_access_client(p_client uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1
    from public.app_users u
    join public.clients c on c.id = p_client
    where u.auth_uid = auth.uid() and u.active and (
         u.role = 'admin'
      or (u.role = 'state_manager' and c.state_id = any(u.state_ids))
      or (u.role in ('client_manager','client_view','operator') and u.client_id = p_client)
    )
  )
$$;

-- ===========================================================================
-- C. Quantity helpers
-- ===========================================================================

-- Remaining quantity a footprint can still hand forward: qty_out minus what children already took.
create or replace function app.available_qty(p_fp uuid) returns numeric
language sql stable as $$
  select f.qty_out - coalesce((
    select sum(c.qty_in) from public.footprints c
    where c.prev_footprint_id = f.id and c.status not in ('superseded','legacy')
  ), 0)
  from public.footprints f where f.id = p_fp
$$;

create or replace function app.req_num(p jsonb, k text) returns numeric
language plpgsql immutable as $$
declare v numeric;
begin
  if p ? k and jsonb_typeof(p->k) = 'number' then
    v := (p->>k)::numeric;
  elsif p ? k and jsonb_typeof(p->k) = 'string' and (p->>k) ~ '^-?[0-9]+(\.[0-9]+)?$' then
    v := (p->>k)::numeric;
  else
    raise exception 'payload.% is required and must be numeric', k using errcode = '23514';
  end if;
  if v < 0 then raise exception 'payload.% must be >= 0', k using errcode = '23514'; end if;
  return v;
end $$;

create or replace function app.opt_num(p jsonb, k text, dflt numeric) returns numeric
language sql immutable as $$
  select case when p ? k and jsonb_typeof(p->k) in ('number','string') and (p->>k) ~ '^-?[0-9]+(\.[0-9]+)?$'
              then (p->>k)::numeric else dflt end
$$;

create or replace function app.approx_eq(a numeric, b numeric) returns boolean
language sql immutable as $$ select abs(a - b) <= app.kg_tolerance() $$;

-- ===========================================================================
-- D. Market-verdict chain walk (PRD §5.7): any lot inherits the verdict of the QC record behind it.
-- ===========================================================================
create or replace function app.resolve_market_verdict(p_fp uuid)
returns table (qc_footprint_id uuid, domestic public.verdict, export public.verdict, override jsonb)
language plpgsql stable as $$
declare cur uuid := p_fp; st public.stage_type; hops int := 0;
begin
  while cur is not null and hops < 64 loop
    select f.stage_type into st from public.footprints f where f.id = cur;
    if st = 'qc' then
      return query select v.footprint_id, v.domestic_verdict, v.export_verdict, v.override
                   from public.qc_verdicts v where v.footprint_id = cur;
      return;
    end if;
    select f.prev_footprint_id into cur from public.footprints f where f.id = cur;
    hops := hops + 1;
  end loop;
  return query select null::uuid, 'pending'::public.verdict, 'pending'::public.verdict, null::jsonb;
end $$;

-- Export sale is allowed when export verdict passed, or a client-level override names the export market.
create or replace function app.export_allowed(p_source_fp uuid) returns boolean
language sql stable as $$
  select coalesce(
    (select v.export = 'pass' or (v.override is not null and v.override->>'market' = 'export')
     from app.resolve_market_verdict(p_source_fp) v), false)
$$;

-- ===========================================================================
-- E. Ledger (rule 6): append-only, hash-chained, trigger-written, never updated or deleted.
-- ===========================================================================
create or replace function app.ledger_append(
  p_footprint uuid, p_scope uuid, p_event public.ledger_event, p_actor uuid, p_payload jsonb
) returns text
language plpgsql security definer set search_path = public as $$
declare v_prev text; v_phash text; v_hash text; v_ts timestamptz := clock_timestamp();
begin
  perform pg_advisory_xact_lock(hashtext('grainveda_ledger'));   -- serialise writers → unambiguous prev_hash
  select hash into v_prev from public.ledger order by seq desc limit 1;
  v_prev  := coalesce(v_prev, repeat('0', 64));
  v_phash := encode(digest(p_payload::text, 'sha256'), 'hex');
  v_hash  := encode(digest(v_prev || v_phash || coalesce(p_actor::text, '') || v_ts::text, 'sha256'), 'hex');
  insert into public.ledger (footprint_id, scope_id, event, actor, payload, payload_hash, prev_hash, hash, created_at)
  values (p_footprint, p_scope, p_event, p_actor, p_payload, v_phash, v_prev, v_hash, v_ts);
  return v_hash;
end $$;

create or replace function app.ledger_guard() returns trigger
language plpgsql as $$
begin
  raise exception 'ledger is append-only (% refused)', tg_op using errcode = '42501';
end $$;

create trigger ledger_no_update_delete
  before update or delete on public.ledger
  for each row execute function app.ledger_guard();

-- Nightly / on-demand chain verification. Returns the first bad block, or nothing when the chain is intact.
create or replace function app.verify_ledger()
returns table (seq bigint, problem text)
language plpgsql stable security definer set search_path = public as $$
declare r record; v_prev text := repeat('0', 64); v_calc text;
begin
  for r in select * from public.ledger order by ledger.seq loop
    if r.prev_hash <> v_prev then
      return query select r.seq, 'prev_hash mismatch'; return;
    end if;
    if r.payload_hash <> encode(digest(r.payload::text, 'sha256'), 'hex') then
      return query select r.seq, 'payload_hash mismatch'; return;
    end if;
    v_calc := encode(digest(r.prev_hash || r.payload_hash || coalesce(r.actor::text, '') || r.created_at::text, 'sha256'), 'hex');
    if v_calc <> r.hash then
      return query select r.seq, 'hash mismatch'; return;
    end if;
    v_prev := r.hash;
  end loop;
  return;
end $$;

-- Snapshot of a footprint that gets hashed (stable column order, no volatile fields).
create or replace function app.footprint_snapshot(f public.footprints) returns jsonb
language sql immutable as $$
  select jsonb_build_object(
    'id', f.id, 'footprint_code', f.footprint_code, 'client_id', f.client_id, 'scope_id', f.scope_id,
    'stage_type', f.stage_type, 'prev_footprint_id', f.prev_footprint_id, 'farmer_id', f.farmer_id,
    'qty_in', f.qty_in, 'qty_out', f.qty_out, 'status', f.status, 'payload', f.payload, 'computed', f.computed,
    'warnings', to_jsonb(f.warnings), 'lot_closed', f.lot_closed, 'is_grade_lot', f.is_grade_lot, 'grade', f.grade,
    'split_into_grades', f.split_into_grades, 'supersedes_id', f.supersedes_id,
    'created_by', f.created_by, 'verified_by', f.verified_by, 'verified_at', f.verified_at, 'created_at', f.created_at
  )
$$;

-- ===========================================================================
-- F. Scope activation (rule 5): chain shape is validated once, then frozen (decision D1).
-- ===========================================================================
create or replace function app.validate_chain(p_chain public.stage_type[], p_crop uuid) returns void
language plpgsql stable as $$
declare n int := coalesce(array_length(p_chain, 1), 0); allowed public.stage_type[]; st public.stage_type;
begin
  if n < 3 then raise exception 'chain needs at least entry, qc and qr_activation' using errcode = '23514'; end if;
  if p_chain[1] not in ('procurement','lot_inward') then
    raise exception 'chain must start with procurement or lot_inward' using errcode = '23514'; end if;
  if p_chain[n] <> 'qr_activation' then
    raise exception 'chain must end with qr_activation' using errcode = '23514'; end if;
  if not ('qc' = any(p_chain)) then raise exception 'qc is mandatory in every chain' using errcode = '23514'; end if;
  if (select count(*) from unnest(p_chain)) <> (select count(distinct x) from unnest(p_chain) x) then
    raise exception 'a stage type may appear only once per chain' using errcode = '23514'; end if;
  if 'procurement' = any(p_chain) and 'lot_inward' = any(p_chain) then
    raise exception 'chain may contain procurement or lot_inward, not both' using errcode = '23514'; end if;
  if 'village_batch' = any(p_chain) and p_chain[1] <> 'procurement' then
    raise exception 'village_batch requires procurement as the entry stage' using errcode = '23514'; end if;
  select allowed_stages into allowed from public.crops where id = p_crop;
  foreach st in array p_chain loop
    if (select is_processing from public.stage_definitions d where d.stage_type = st)
       and not (st = any(coalesce(allowed, '{}'))) then
      raise exception 'stage % is not allowed for this crop', st using errcode = '23514';
    end if;
  end loop;
end $$;

create or replace function app.scopes_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' and new.status = 'active' then
    perform app.validate_chain(new.chain, new.crop_id);
    new.activated_at := coalesce(new.activated_at, now());
  elsif tg_op = 'UPDATE' then
    if old.status = 'draft' and new.status = 'active' then
      perform app.validate_chain(new.chain, new.crop_id);
      new.activated_at := coalesce(new.activated_at, now());
    elsif old.status <> 'draft' then
      if new.chain is distinct from old.chain or new.crop_id <> old.crop_id or new.client_id <> old.client_id
         or new.season_code <> old.season_code then
        raise exception 'scope chain/crop/client/season are frozen after activation; open a new scope' using errcode = '42501';
      end if;
      if old.status = 'closed' and new.status <> 'closed' then
        raise exception 'a closed scope cannot be reopened' using errcode = '42501';
      end if;
    end if;
  end if;
  return new;
end $$;

create trigger scopes_guard before insert or update on public.scopes
  for each row execute function app.scopes_guard();

create or replace function app.scopes_ledger() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (tg_op = 'INSERT' and new.status = 'active') or (tg_op = 'UPDATE' and old.status = 'draft' and new.status = 'active') then
    perform app.ledger_append(null, new.id, 'scope_activate', app.current_user_id(),
      jsonb_build_object('scope_id', new.id, 'client_id', new.client_id, 'crop_id', new.crop_id,
                         'season_code', new.season_code, 'chain', to_jsonb(new.chain), 'activated_at', new.activated_at));
  end if;
  return new;
end $$;

create trigger scopes_ledger after insert or update on public.scopes
  for each row execute function app.scopes_ledger();

-- ===========================================================================
-- G. Per-stage reconciliation (PRD §7). Sets qty_in, qty_out, computed, warnings; raises on violation.
-- ===========================================================================
create or replace function app.reconcile(f public.footprints, p_scope public.scopes) returns public.footprints
language plpgsql stable as $$
declare
  p jsonb := f.payload; c jsonb := '{}'::jsonb; w text[] := '{}';
  tol jsonb := p_scope.tolerances;
  v_in numeric; v_out numeric; a numeric; b numeric; d numeric; e numeric; s numeric; pk jsonb;
  prev public.footprints;
begin
  if f.prev_footprint_id is not null then
    select * into prev from public.footprints where id = f.prev_footprint_id;
  end if;

  case f.stage_type
    when 'procurement' then
      a := app.req_num(p, 'gross_kg'); b := app.req_num(p, 'bags'); d := app.req_num(p, 'tare_kg_per_bag');
      if not (p ? 'moisture_pct' and jsonb_typeof(p->'moisture_pct') = 'array' and jsonb_array_length(p->'moisture_pct') = 3) then
        raise exception 'payload.moisture_pct must be an array of 3 readings' using errcode = '23514';
      end if;
      select avg(x::numeric), min(x::numeric), max(x::numeric) into a, b, d
        from jsonb_array_elements_text(p->'moisture_pct') x;   -- reuse vars: a=avg b=min d=max
      v_in := app.req_num(p, 'gross_kg') - app.req_num(p, 'bags') * app.req_num(p, 'tare_kg_per_bag');
      if v_in <= 0 then raise exception 'net weight must be positive (gross - bags x tare)' using errcode = '23514'; end if;
      v_out := v_in;
      c := jsonb_build_object('net_kg', v_in, 'moisture_avg', round(a, 2), 'moisture_min', b, 'moisture_max', d);
      if f.farmer_id is null then raise exception 'procurement requires farmer_id' using errcode = '23514'; end if;

    when 'lot_inward' then
      a := app.req_num(p, 'declared_kg'); b := app.req_num(p, 'weighed_kg');
      if b <= 0 then raise exception 'weighed_kg must be positive' using errcode = '23514'; end if;
      if coalesce(p->>'source_type', '') = '' or coalesce(p->>'source_name', '') = '' then
        raise exception 'payload.source_type and source_name are required' using errcode = '23514'; end if;
      perform app.req_num(p, 'moisture_pct');
      v_in := b; v_out := b;
      c := jsonb_build_object('variance_kg', a - b, 'variance_pct', case when a > 0 then round((a - b) / a * 100, 2) else null end);
      if a > 0 and abs(a - b) / a * 100 > app.opt_num(tol, 'lot_inward_variance_pct', 2) then
        w := array_append(w, 'declared vs weighed variance exceeds tolerance'); end if;

    when 'village_batch' then
      -- aggregates: qty_in = Σ qty_out of the source procurement lots (validated in the insert trigger)
      select coalesce(sum(s.qty_out), 0) into v_in
        from public.footprints s
        where s.id in (select (x)::uuid from jsonb_array_elements_text(coalesce(p->'source_footprint_ids', '[]'::jsonb)) x);
      if v_in <= 0 then raise exception 'village_batch needs payload.source_footprint_ids with quantity' using errcode = '23514'; end if;
      v_out := v_in;
      c := jsonb_build_object('source_count', jsonb_array_length(p->'source_footprint_ids'));

    when 'milling' then
      v_in := app.req_num(p, 'input_kg'); a := app.req_num(p, 'rice_kg'); b := app.req_num(p, 'bran_kg'); d := app.req_num(p, 'loss_kg');
      if not app.approx_eq(v_in, a + b + d) then
        raise exception 'milling: input (%) must equal rice + bran + loss (%)', v_in, a + b + d using errcode = '23514'; end if;
      v_out := a;
      c := jsonb_build_object('yield_pct', round(a / nullif(v_in, 0) * 100, 2), 'bran_kg', b, 'loss_kg', d);
      if v_in > 0 and a / v_in * 100 < app.opt_num(tol, 'yield_warn_pct', 70) then w := array_append(w, 'yield below threshold'); end if;

    when 'sorting' then
      v_in := app.req_num(p, 'input_kg'); a := app.req_num(p, 'reject_kg'); d := app.req_num(p, 'loss_kg');
      v_out := v_in - a - d;                                          -- clean output is DERIVED, never entered
      if v_out < 0 then raise exception 'sorting: reject + loss exceed input' using errcode = '23514'; end if;
      c := jsonb_build_object('clean_kg', v_out, 'reject_kg', a, 'loss_kg', d, 'reject_reasons', coalesce(p->'reject_reasons', '[]'::jsonb));

    when 'grading' then
      if f.is_grade_lot then
        -- child grade lot: quantity given directly, coupled to the grading run (validated in trigger)
        v_in := app.req_num(p, 'qty_kg'); v_out := v_in;
        c := jsonb_build_object('grade', f.grade);
      else
        v_in := app.req_num(p, 'input_kg');
        a := app.req_num(p, 'grade_a_kg'); b := app.req_num(p, 'grade_b_kg'); d := app.req_num(p, 'grade_c_kg');
        e := app.req_num(p, 'reject_kg'); s := app.req_num(p, 'loss_kg');
        if not app.approx_eq(v_in, a + b + d + e + s) then
          raise exception 'grading: A + B + C + reject + loss (%) must equal input (%)', a + b + d + e + s, v_in using errcode = '23514'; end if;
        v_out := a + b + d;
        c := jsonb_build_object('grade_split', jsonb_build_object('A', a, 'B', b, 'C', d), 'reject_kg', e, 'loss_kg', s);
      end if;

    when 'drying' then
      v_in := app.req_num(p, 'input_kg'); a := app.req_num(p, 'moisture_in_pct'); b := app.req_num(p, 'moisture_out_pct');
      v_out := app.req_num(p, 'output_kg');
      if b >= 100 or a >= 100 then raise exception 'moisture must be below 100%%' using errcode = '23514'; end if;
      e := v_in * (100 - a) / (100 - b);                              -- dry-matter expected output
      c := jsonb_build_object('expected_out_kg', round(e, 3), 'water_removed_kg', round(v_in - e, 3),
                              'grain_loss_kg', round(greatest(e - v_out, 0), 3));
      if v_out > e * 1.01 + app.kg_tolerance() then w := array_append(w, 'output exceeds dry-matter expectation'); end if;  -- 1% weighing noise
      if e - v_out > greatest(e * 0.02, app.kg_tolerance()) then w := array_append(w, 'grain loss beyond moisture removal'); end if;

    when 'popping' then
      v_in := app.req_num(p, 'input_kg'); v_out := app.req_num(p, 'output_kg'); a := app.req_num(p, 'pop_rate_pct');
      c := jsonb_build_object('pop_rate_pct', a, 'weight_yield_pct', round(v_out / nullif(v_in, 0) * 100, 2));
      if a < app.opt_num(tol, 'pop_rate_min_pct', 80) then w := array_append(w, 'pop rate below threshold'); end if;

    when 'blanching' then
      v_in := app.req_num(p, 'input_kg'); v_out := app.req_num(p, 'output_kg');
      c := jsonb_build_object('water_uptake_kg', round(v_out - v_in, 3));   -- output > input is valid here

    when 'cleaning' then
      v_in := app.req_num(p, 'input_kg'); a := app.req_num(p, 'foreign_matter_kg'); d := app.req_num(p, 'loss_kg');
      v_out := v_in - a - d;
      if v_out < 0 then raise exception 'cleaning: foreign matter + loss exceed input' using errcode = '23514'; end if;
      c := jsonb_build_object('foreign_matter_kg', a, 'loss_kg', d);

    when 'cold_storage' then
      v_in := app.req_num(p, 'stored_kg'); v_out := app.req_num(p, 'retrieved_kg');
      c := jsonb_build_object('spoilage_kg', round(v_in - v_out, 3));

    when 'packing' then
      v_in := app.req_num(p, 'input_kg'); d := app.req_num(p, 'wastage_kg');
      if coalesce(p->>'batch_code', '') = '' then raise exception 'packing: batch_code is mandatory (QR link)' using errcode = '23514'; end if;
      if not (p ? 'packets' and jsonb_typeof(p->'packets') = 'array' and jsonb_array_length(p->'packets') > 0) then
        raise exception 'packing: payload.packets [{units,size_kg}] is required' using errcode = '23514'; end if;
      select coalesce(sum(app.req_num(x, 'units') * app.req_num(x, 'size_kg')), 0) into v_out from jsonb_array_elements(p->'packets') x;
      if not app.approx_eq(v_in, v_out + d) then
        raise exception 'packing: Σ packets (%) + wastage (%) must equal input (%)', v_out, d, v_in using errcode = '23514'; end if;
      c := jsonb_build_object('packed_kg', v_out, 'wastage_kg', d, 'batch_code', p->>'batch_code');

    when 'qc' then
      v_in := app.req_num(p, 'qty_kg'); a := app.req_num(p, 'sample_qty_kg');
      if a >= v_in then raise exception 'qc: sample must be smaller than the lot' using errcode = '23514'; end if;
      if not (p ? 'readings' and jsonb_typeof(p->'readings') = 'object') then
        raise exception 'qc: payload.readings {param: value} is required' using errcode = '23514'; end if;
      v_out := v_in - a;                                              -- sample consumed in testing (rule 7)
      c := jsonb_build_object('sample_qty_kg', a, 'forwarding_kg', v_out);

    when 'commercial' then
      v_in := app.req_num(p, 'qty_kg'); v_out := v_in;
      if coalesce(p->>'buyer', '') = '' then raise exception 'commercial: buyer is required' using errcode = '23514'; end if;
      if coalesce(p->>'market', '') not in ('domestic','export') then
        raise exception 'commercial: market must be domestic or export' using errcode = '23514'; end if;
      if p->>'market' = 'export' and not app.export_allowed(f.prev_footprint_id) then
        raise exception 'commercial: export sale requires export PASS or a client-level override' using errcode = '23514'; end if;
      c := jsonb_build_object('market', p->>'market', 'buyer', p->>'buyer');

    when 'shipment' then
      v_in := app.req_num(p, 'shipped_kg'); d := app.opt_num(p, 'transit_loss_kg', 0);
      v_out := v_in - d;
      if v_out < 0 then raise exception 'shipment: transit loss exceeds shipped quantity' using errcode = '23514'; end if;
      c := jsonb_build_object('transit_loss_kg', d);

    when 'qr_activation' then
      if prev.id is null then raise exception 'qr_activation needs a predecessor' using errcode = '23514'; end if;
      v_in := app.available_qty(prev.id); v_out := v_in;              -- takes whatever remains of the final lot
      if v_in <= 0 then raise exception 'qr_activation: final quantity must be recorded and positive' using errcode = '23514'; end if;
      c := jsonb_build_object('final_kg', v_in);

    else
      raise exception 'no reconciliation rule for stage %', f.stage_type using errcode = '23514';
  end case;

  -- Rule 3: output never exceeds input, except blanching.
  if v_out > v_in + app.kg_tolerance() and f.stage_type <> 'blanching' then
    raise exception '% : output (%) exceeds input (%)', f.stage_type, v_out, v_in using errcode = '23514';
  end if;

  f.qty_in := round(v_in, 3); f.qty_out := round(v_out, 3); f.computed := c; f.warnings := w;
  return f;
end $$;

-- ===========================================================================
-- H. Footprint code
-- ===========================================================================
create or replace function app.next_footprint_code(p_scope uuid, p_stage public.stage_type, p_grade text) returns text
language plpgsql as $$
declare v_seq int; v_client text; v_crop text; v_season text; v_stage text; v_series text;
begin
  select c.code, cr.code, s.season_code into v_client, v_crop, v_season
    from public.scopes s join public.clients c on c.id = s.client_id join public.crops cr on cr.id = s.crop_id
    where s.id = p_scope;
  v_series := format('%s-%s-%s', v_client, v_crop, v_season);
  insert into public.footprint_counters (series, stage_type, last_seq) values (v_series, p_stage, 1)
  on conflict (series, stage_type) do update set last_seq = public.footprint_counters.last_seq + 1
  returning last_seq into v_seq;
  select code into v_stage from public.stage_definitions where stage_type = p_stage;
  return format('%s-%s-%s-%s-%s%s', v_client, v_crop, v_season, v_stage, lpad(v_seq::text, 4, '0'),
                case when p_grade is null then '' else '-' || p_grade end);
end $$;

-- ===========================================================================
-- I. Footprint triggers: rules 1, 2, 3, 4, 7, 8 + auto-close + ledger
-- ===========================================================================
create or replace function app.footprints_before_insert() returns trigger
language plpgsql security definer set search_path = public as $$
declare sc public.scopes; def public.stage_definitions; prev public.footprints; src uuid; expected_prev public.stage_type;
begin
  select * into sc from public.scopes where id = new.scope_id;
  if sc.id is null then raise exception 'unknown scope' using errcode = '23503'; end if;
  if sc.status <> 'active' then raise exception 'scope is not active' using errcode = '42501'; end if;
  new.client_id := sc.client_id;                                        -- stamped from the scope, never trusted from the client

  select * into def from public.stage_definitions where stage_type = new.stage_type;
  if def.stage_type is null then raise exception 'unknown stage type %', new.stage_type using errcode = '23514'; end if;
  if app.chain_index(new.scope_id, new.stage_type) is null then
    raise exception 'stage % is not in this scope''s chain', new.stage_type using errcode = '23514'; end if;

  if new.status not in ('pending','legacy') then
    raise exception 'a footprint is created as pending; verification is a separate act' using errcode = '23514'; end if;
  if new.verified_by is not null or new.verified_at is not null then
    raise exception 'verified_by/verified_at are set by verification, not at create' using errcode = '23514'; end if;

  -- Creator must hold the slot (isMyStage) or be a gateway role.
  if not app.is_my_stage(new.created_by, new.scope_id, new.stage_type) then
    raise exception 'user % may not create at stage % in this scope', new.created_by, new.stage_type using errcode = '42501'; end if;

  -- Rule 1 / 2: predecessor coupling.
  if def.is_first then
    if new.prev_footprint_id is not null then raise exception 'first stage has no predecessor' using errcode = '23514'; end if;
  else
    if new.prev_footprint_id is null then raise exception 'prev_footprint_id is required for stage %', new.stage_type using errcode = '23514'; end if;
    select * into prev from public.footprints where id = new.prev_footprint_id;
    if prev.scope_id <> new.scope_id then raise exception 'predecessor must be in the same scope' using errcode = '23514'; end if;
    if prev.lot_closed then raise exception 'predecessor lot is closed' using errcode = '23514'; end if;
    if prev.status in ('superseded','legacy') then raise exception 'predecessor is % and cannot be built on', prev.status using errcode = '23514'; end if;

    if new.is_grade_lot then
      if prev.stage_type <> 'grading' or not prev.split_into_grades or prev.is_grade_lot then
        raise exception 'a grade lot must be coupled to a grading run that was split' using errcode = '23514'; end if;
      if new.created_by <> prev.created_by and not app.is_gateway_role(app.user_role_of(new.created_by)) then
        raise exception 'grade lots are created by the grading run''s creator' using errcode = '42501'; end if;
    else
      expected_prev := app.chain_prev(new.scope_id, new.stage_type);
      if prev.stage_type <> expected_prev then
        raise exception 'predecessor of % must be % (got %)', new.stage_type, expected_prev, prev.stage_type using errcode = '23514'; end if;
      if prev.split_into_grades then
        raise exception 'a split grading run is not a source; use its grade lots' using errcode = '23514'; end if;
      if prev.status <> 'verified' then
        raise exception 'predecessor must be verified before the next stage builds on it' using errcode = '23514'; end if;
    end if;
  end if;

  -- Aggregates (village_batch): every source is a verified predecessor-stage lot in this scope.
  if def.aggregates then
    if not (new.payload ? 'source_footprint_ids' and jsonb_typeof(new.payload->'source_footprint_ids') = 'array') then
      raise exception 'village_batch requires payload.source_footprint_ids' using errcode = '23514'; end if;
    for src in select (x)::uuid from jsonb_array_elements_text(new.payload->'source_footprint_ids') x loop
      select * into prev from public.footprints where id = src;
      if prev.id is null or prev.scope_id <> new.scope_id or prev.stage_type <> app.chain_prev(new.scope_id, new.stage_type)
         or prev.status <> 'verified' or prev.lot_closed then
        raise exception 'village_batch source % is not a verified, open predecessor lot in this scope', src using errcode = '23514'; end if;
    end loop;
    if new.prev_footprint_id <> (new.payload->'source_footprint_ids'->>0)::uuid then
      raise exception 'village_batch prev_footprint_id must be the first source' using errcode = '23514'; end if;
  end if;

  -- Procurement: farmer must be active and belong to the client.
  if new.stage_type = 'procurement' then
    if not exists (select 1 from public.farmers fm where fm.id = new.farmer_id and fm.client_id = new.client_id and fm.status = 'active') then
      raise exception 'procurement requires an active farmer of this client' using errcode = '23514'; end if;
  end if;

  -- Reconciliation (rules 3, 7) → canonical quantities.
  new := app.reconcile(new, sc);

  -- Availability: cannot take more than the predecessor still holds (aggregates take whole sources, checked above).
  if new.prev_footprint_id is not null and not def.aggregates then
    if new.qty_in > app.available_qty(new.prev_footprint_id) + app.kg_tolerance() then
      raise exception 'qty_in % exceeds available % on predecessor', new.qty_in, app.available_qty(new.prev_footprint_id) using errcode = '23514'; end if;
  end if;

  if new.footprint_code is null or new.footprint_code = '' then
    new.footprint_code := app.next_footprint_code(new.scope_id, new.stage_type, new.grade);
  end if;
  return new;
end $$;

create trigger footprints_before_insert before insert on public.footprints
  for each row execute function app.footprints_before_insert();

create or replace function app.footprints_after_insert() returns trigger
language plpgsql security definer set search_path = public as $$
declare sc public.scopes; src uuid; v_close_kg numeric; v_actor uuid; v_event public.ledger_event;
begin
  select * into sc from public.scopes where id = new.scope_id;
  v_close_kg := app.opt_num(sc.tolerances, 'auto_close_kg', 2);
  v_actor := coalesce(app.current_user_id(), new.created_by);
  v_event := case when app.is_gateway_role(app.user_role_of(new.created_by))
                   and not app.has_slot(new.created_by, new.scope_id, new.stage_type)
                  then 'supervisory'::public.ledger_event else 'create'::public.ledger_event end;

  -- Auto-close: a run that leaves < auto_close_kg of the source closes it.
  if new.prev_footprint_id is not null and not new.is_grade_lot then
    if app.available_qty(new.prev_footprint_id) < v_close_kg then
      update public.footprints set lot_closed = true where id = new.prev_footprint_id and lot_closed = false;
    end if;
  end if;
  if new.stage_type = 'village_batch' then
    for src in select (x)::uuid from jsonb_array_elements_text(new.payload->'source_footprint_ids') x loop
      update public.footprints set lot_closed = true where id = src and lot_closed = false;
    end loop;
  end if;

  -- QC: derive both verdicts from readings vs the crop's structured limits.
  if new.stage_type = 'qc' then
    perform app.derive_qc_verdict(new);
  end if;

  perform app.ledger_append(new.id, new.scope_id, v_event, v_actor, app.footprint_snapshot(new));
  return new;
end $$;

create trigger footprints_after_insert after insert on public.footprints
  for each row execute function app.footprints_after_insert();

-- Rule 4: verified records are immutable; only lot_closed and status→superseded may change.
create or replace function app.footprints_before_update() returns trigger
language plpgsql security definer set search_path = public as $$
declare sc public.scopes;
begin
  -- Sacred stamps never change, whatever the status.
  if new.scope_id <> old.scope_id or new.client_id <> old.client_id or new.stage_type <> old.stage_type
     or new.prev_footprint_id is distinct from old.prev_footprint_id or new.created_by <> old.created_by
     or new.footprint_code <> old.footprint_code or new.is_grade_lot <> old.is_grade_lot or new.grade is distinct from old.grade then
    raise exception 'scope_id, client_id, stage_type, prev_footprint_id, created_by, footprint_code, grade are immutable' using errcode = '42501';
  end if;

  if old.status = 'pending' then
    if new.status = 'verified' then
      if new.verified_by is null then raise exception 'verified_by is required' using errcode = '23514'; end if;
      -- isGate (QR): there is no stage after it; its verification IS the whole-chain re-walk done by the sealer.
      if (select is_gate from public.stage_definitions d where d.stage_type = new.stage_type) then
        if not app.is_my_stage(new.verified_by, new.scope_id, new.stage_type) then
          raise exception 'user % may not seal: not the assigned QR operator', new.verified_by using errcode = '42501'; end if;
      else
        if not app.is_next_stage_user(new.verified_by, new.scope_id, new.stage_type) then
          raise exception 'user % may not verify a % record: verification is by the receiving stage', new.verified_by, new.stage_type using errcode = '42501'; end if;
        if new.verified_by = old.created_by and not app.is_gateway_role(app.user_role_of(new.verified_by)) then
          raise exception 'a record cannot be verified by its own creator' using errcode = '42501'; end if;
      end if;
      new.verified_at := coalesce(new.verified_at, now());
      -- the verified snapshot is exactly what the creator reviewed: no payload edits ride along with verification
      if new.payload <> old.payload or new.qty_in <> old.qty_in or new.qty_out <> old.qty_out then
        raise exception 'payload/quantities cannot change in the same act as verification' using errcode = '42501'; end if;
    elsif new.status = 'pending' then
      -- creator may still correct a pending record; reconciliation re-runs
      if new.payload <> old.payload or new.farmer_id is distinct from old.farmer_id then
        select * into sc from public.scopes where id = new.scope_id;
        new := app.reconcile(new, sc);
        if new.prev_footprint_id is not null and not new.is_grade_lot and new.stage_type <> 'village_batch'
           and new.qty_in > app.available_qty(new.prev_footprint_id) + old.qty_in + app.kg_tolerance() then
          raise exception 'qty_in exceeds available on predecessor' using errcode = '23514'; end if;
      end if;
    elsif new.status = 'superseded' then
      null;
    else
      raise exception 'pending → % is not a valid transition', new.status using errcode = '23514';
    end if;
  else
    -- verified / superseded / legacy: frozen except lot_closed and status → superseded
    if new.payload <> old.payload or new.computed <> old.computed or new.qty_in <> old.qty_in or new.qty_out <> old.qty_out
       or new.warnings <> old.warnings or new.farmer_id is distinct from old.farmer_id
       or new.verified_by is distinct from old.verified_by or new.verified_at is distinct from old.verified_at
       or new.split_into_grades <> old.split_into_grades then
      raise exception 'a % footprint is immutable; create a superseding record instead', old.status using errcode = '42501';
    end if;
    if new.status <> old.status and not (old.status = 'verified' and new.status = 'superseded') then
      raise exception '% → % is not a valid transition', old.status, new.status using errcode = '23514';
    end if;
  end if;
  return new;
end $$;

create trigger footprints_before_update before update on public.footprints
  for each row execute function app.footprints_before_update();

create or replace function app.footprints_after_update() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_actor uuid;
begin
  if old.status = 'pending' and new.status = 'verified' then
    v_actor := coalesce(app.current_user_id(), new.verified_by);
    perform app.ledger_append(new.id, new.scope_id,
      case when app.is_gateway_role(app.user_role_of(new.verified_by))
            and not app.has_slot(new.verified_by, new.scope_id, app.chain_next(new.scope_id, new.stage_type))
           then 'supervisory'::public.ledger_event else 'verify'::public.ledger_event end,
      v_actor, app.footprint_snapshot(new));
  end if;
  if new.status = 'superseded' and old.status <> 'superseded' then
    perform app.ledger_append(new.id, new.scope_id, 'supersede', app.current_user_id(), app.footprint_snapshot(new));
  end if;
  if new.lot_closed and not old.lot_closed then
    perform app.ledger_append(new.id, new.scope_id, 'close', app.current_user_id(),
      jsonb_build_object('id', new.id, 'lot_closed', true, 'available_kg', app.available_qty(new.id)));
  end if;
  return new;
end $$;

create trigger footprints_after_update after update on public.footprints
  for each row execute function app.footprints_after_update();

create or replace function app.footprints_no_delete() returns trigger
language plpgsql as $$
begin
  raise exception 'footprints are never deleted; supersede instead' using errcode = '42501';
end $$;
create trigger footprints_no_delete before delete on public.footprints
  for each row execute function app.footprints_no_delete();

-- ===========================================================================
-- J. QC verdict engine: both verdicts derived from readings against structured crop limits. No manual export approval.
-- ===========================================================================
create or replace function app.judge_param(v numeric, op text, lim jsonb) returns public.verdict
language plpgsql immutable as $$
begin
  if v is null or lim is null or jsonb_typeof(lim) = 'null' then return 'pending'; end if;
  case op
    when '<='      then return case when v <= (lim#>>'{}')::numeric then 'pass' else 'fail' end;
    when '>='      then return case when v >= (lim#>>'{}')::numeric then 'pass' else 'fail' end;
    when 'between' then return case when v >= (lim->>0)::numeric and v <= (lim->>1)::numeric then 'pass' else 'fail' end;
    else return 'pending';
  end case;
end $$;

create or replace function app.derive_qc_verdict(f public.footprints) returns void
language plpgsql security definer set search_path = public as $$
declare qp jsonb; prm jsonb; v numeric; dv public.verdict; ev public.verdict;
        dom public.verdict := 'pass'; exp public.verdict := 'pass'; judged jsonb := '[]'::jsonb;
begin
  select c.quality_params into qp from public.scopes s join public.crops c on c.id = s.crop_id where s.id = f.scope_id;
  if qp is null or jsonb_array_length(qp) = 0 then dom := 'pending'; exp := 'pending'; end if;
  for prm in select * from jsonb_array_elements(coalesce(qp, '[]'::jsonb)) loop
    v := app.opt_num(f.payload->'readings', prm->>'param', null);
    dv := app.judge_param(v, prm->>'operator', prm->'domestic_limit');
    ev := app.judge_param(v, prm->>'operator', prm->'export_limit');
    judged := judged || jsonb_build_object('param', prm->>'param', 'value', v, 'domestic', dv, 'export', ev);
    if dv = 'fail' then dom := 'fail'; elsif dv = 'pending' and dom <> 'fail' then dom := 'pending'; end if;
    if ev = 'fail' then exp := 'fail'; elsif ev = 'pending' and exp <> 'fail' then exp := 'pending'; end if;
  end loop;
  insert into public.qc_verdicts (footprint_id, domestic_verdict, export_verdict, readings, judged)
  values (f.id, dom, exp, coalesce(f.payload->'readings', '{}'::jsonb), judged);
end $$;

-- Override: client-level only (client_manager or above), reason + authoriser mandatory, derived verdicts untouched.
create or replace function app.qc_verdicts_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare auth_role public.user_role;
begin
  if new.domestic_verdict <> old.domestic_verdict or new.export_verdict <> old.export_verdict
     or new.readings <> old.readings or new.judged <> old.judged then
    raise exception 'derived verdicts and readings are immutable; only override may be set' using errcode = '42501';
  end if;
  if new.override is distinct from old.override then
    if old.override is not null then raise exception 'an override cannot be changed or removed' using errcode = '42501'; end if;
    if coalesce(new.override->>'reason', '') = '' or coalesce(new.override->>'authoriser', '') = ''
       or coalesce(new.override->>'market', '') not in ('domestic','export') then
      raise exception 'override needs market, reason and authoriser' using errcode = '23514'; end if;
    auth_role := app.user_role_of((new.override->>'authoriser')::uuid);
    if not app.is_gateway_role(auth_role) then
      raise exception 'override authoriser must be client_manager or above' using errcode = '42501'; end if;
    new.override := new.override || jsonb_build_object('at', now());
    perform app.ledger_append(new.footprint_id, (select scope_id from public.footprints where id = new.footprint_id),
      'override', coalesce(app.current_user_id(), (new.override->>'authoriser')::uuid),
      jsonb_build_object('footprint_id', new.footprint_id, 'override', new.override,
                         'domestic_verdict', new.domestic_verdict, 'export_verdict', new.export_verdict));
  end if;
  return new;
end $$;
create trigger qc_verdicts_guard before update on public.qc_verdicts
  for each row execute function app.qc_verdicts_guard();

create or replace function app.qc_verdicts_no_delete() returns trigger
language plpgsql as $$ begin raise exception 'qc verdicts are never deleted' using errcode = '42501'; end $$;
create trigger qc_verdicts_no_delete before delete on public.qc_verdicts
  for each row execute function app.qc_verdicts_no_delete();

-- ===========================================================================
-- K. Verification and seal as RPCs (the front-end calls these; direct updates are also guarded above)
-- ===========================================================================
create or replace function app.verify_footprint(p_fp uuid) returns public.footprints
language plpgsql security definer set search_path = public as $$
declare me uuid := app.current_user_id(); r public.footprints;
begin
  if me is null then raise exception 'not authenticated' using errcode = '42501'; end if;
  update public.footprints set status = 'verified', verified_by = me, verified_at = now()
   where id = p_fp and status = 'pending' returning * into r;
  if r.id is null then raise exception 'footprint not found or not pending' using errcode = 'P0002'; end if;
  return r;
end $$;

-- QR gate (isGate): re-walk the whole chain, then seal. Predecessor-agnostic: works after QC, Commercial or Shipment.
create or replace function app.seal_lot(p_qr_fp uuid, p_sealer uuid default null) returns public.qr_seals
language plpgsql security definer set search_path = public as $$
declare me uuid := coalesce(app.current_user_id(), p_sealer); qr public.footprints; cur public.footprints;
        hops int := 0; has_qc boolean := false; batch text[] := '{}'; v_hash text; seal public.qr_seals; v_code text;
        vd record;
begin
  select * into qr from public.footprints where id = p_qr_fp;
  if qr.id is null or qr.stage_type <> 'qr_activation' then raise exception 'not a qr_activation footprint' using errcode = 'P0002'; end if;
  if me is null or not app.is_my_stage(me, qr.scope_id, 'qr_activation') then
    raise exception 'only the assigned QR operator (or a gateway role) may seal' using errcode = '42501'; end if;
  if exists (select 1 from public.qr_seals where footprint_id = qr.id) then raise exception 'already sealed' using errcode = '23505'; end if;
  if qr.qty_out <= 0 then raise exception 'gate: final quantity not recorded' using errcode = '23514'; end if;

  -- Gate: every ancestor verified, no open flags, QC verdict present.
  cur := qr;
  while cur.prev_footprint_id is not null and hops < 64 loop
    select * into cur from public.footprints where id = cur.prev_footprint_id;
    if cur.status <> 'verified' then
      raise exception 'gate: % % is not verified', cur.stage_type, cur.footprint_code using errcode = '23514'; end if;
    if exists (select 1 from public.flags fl where fl.footprint_id = cur.id and fl.status = 'open') then
      raise exception 'gate: open flag on % %', cur.stage_type, cur.footprint_code using errcode = '23514'; end if;
    if cur.stage_type = 'qc' then has_qc := true; end if;
    if cur.stage_type = 'packing' then batch := array_append(batch, cur.payload->>'batch_code'); end if;
    hops := hops + 1;
  end loop;
  if not has_qc then raise exception 'gate: no QC record behind this lot' using errcode = '23514'; end if;
  select * into vd from app.resolve_market_verdict(qr.id);
  if vd.domestic = 'pending' and vd.export = 'pending' then
    raise exception 'gate: QC verdict is pending' using errcode = '23514'; end if;

  -- Seal: the QR footprint is verified by the sealer (whole-chain re-walk is its verification), then the block is written.
  update public.footprints set status = 'verified', verified_by = me, verified_at = now() where id = qr.id and status = 'pending';
  update public.footprints set lot_closed = true where id = qr.id;
  v_code := 'GV-' || upper(substr(encode(digest(qr.id::text || clock_timestamp()::text, 'sha256'), 'hex'), 1, 12));
  v_hash := app.ledger_append(qr.id, qr.scope_id, 'seal', me,
    jsonb_build_object('footprint_id', qr.id, 'footprint_code', qr.footprint_code, 'qr_code', v_code,
                       'batch_codes', to_jsonb(batch), 'final_kg', qr.qty_out,
                       'domestic_verdict', vd.domestic, 'export_verdict', vd.export, 'override', vd.override));
  insert into public.qr_seals (footprint_id, qr_code, batch_codes, sealed_by, ledger_hash)
  values (qr.id, v_code, batch, me, v_hash) returning * into seal;
  return seal;
end $$;

create or replace function app.qr_seals_guard() returns trigger
language plpgsql as $$ begin raise exception 'seals are immutable' using errcode = '42501'; end $$;
create trigger qr_seals_guard before update or delete on public.qr_seals
  for each row execute function app.qr_seals_guard();

-- Farmer ID is issued only by a State Manager (or admin) verification.
create or replace function app.farmers_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare vr public.user_role;
begin
  if tg_op = 'UPDATE' and new.status = 'active' and old.status <> 'active' then
    if new.verified_by is null then raise exception 'farmer verification needs verified_by' using errcode = '23514'; end if;
    vr := app.user_role_of(new.verified_by);
    if vr not in ('admin','state_manager') then raise exception 'only a State Manager or admin issues a Farmer ID' using errcode = '42501'; end if;
    new.verified_at := coalesce(new.verified_at, now());
    if new.farmer_code is null then
      new.farmer_code := (select c.code from public.clients c where c.id = new.client_id) || '-F-' ||
                         lpad((select count(*) + 1 from public.farmers f where f.client_id = new.client_id and f.farmer_code is not null)::text, 4, '0');
    end if;
  elsif tg_op = 'INSERT' and new.status = 'active' then
    raise exception 'farmers are created as draft/under_review; activation is a verification act' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger farmers_guard before insert or update on public.farmers
  for each row execute function app.farmers_guard();
