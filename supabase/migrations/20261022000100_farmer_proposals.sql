-- =====================================================================================================================
-- Migration 47: the Procurement operator and a farmer already verified (Veda, 14 Oct 2026, on staging: p could not
-- record a lot for farmer TCUP-F-0001 because its good farming practice was not filled in, and nothing let him fill it):
--   · good farming practice: whoever adds the client's farmers (its Client Manager; Procurement and Village Batch in its
--     scopes) answers it for a farmer at any status, and it counts at once (Veda: "count at once"). The server allowed
--     it already (app.save_farmer_gap); the app now opens it to him.
--   · any other detail he finds wrong or missing (name, father's name, village, district, phone, land, GI land, notes):
--     he proposes the corrected value with a reason; nothing changes until the Client Manager approves it (then it goes
--     through the normal change rules: a reason in the farmer's history; GI land and phone for the State Manager to
--     accept) or refuses it with a reason (Veda: "if other details need omission then if p does it it should go to lucky
--     for verification").
-- Additive only: one new table, functions, grants. Nothing changed or deleted.
-- =====================================================================================================================
select set_config('app.change_path', 'migration 47', true);

create table if not exists public.farmer_proposals (
  id             uuid primary key default gen_random_uuid(),
  farmer_id      uuid not null references public.farmers(id),
  client_id      uuid not null references public.clients(id),
  changes        jsonb not null check (jsonb_typeof(changes) = 'object'),
  before         jsonb not null default '{}'::jsonb,           -- the values when he proposed, for the Client Manager to compare
  reason         text not null check (length(btrim(reason)) between 3 and 300),
  status         text not null default 'requested' check (status in ('requested', 'approved', 'refused', 'withdrawn')),
  requested_by   uuid not null references public.app_users(id),
  requested_at   timestamptz not null default now(),
  decided_by     uuid references public.app_users(id),
  decided_at     timestamptz,
  decided_reason text
);
create index if not exists farmer_proposals_open on public.farmer_proposals (client_id) where status = 'requested';
alter table public.farmer_proposals enable row level security;
revoke all on public.farmer_proposals from anon, authenticated;   -- read and written through the functions below
create trigger zz_change_log after insert or update or delete on public.farmer_proposals for each row execute function app.log_change('id');

-- the details a proposal may correct (status, consents and the IDs are not his to propose)
create or replace function app.proposal_fields() returns text[]
language sql immutable as $$ select array['name', 'guardian_name', 'village', 'district', 'phone', 'land_area_acres', 'gi_land_acres', 'notes'] $$;

create or replace function app.farmer_values(f public.farmers) returns jsonb
language sql stable as $$
  select jsonb_build_object('name', f.name, 'guardian_name', f.guardian_name, 'village', f.village, 'district', f.district,
    'phone', f.phone, 'land_area_acres', f.land_area_acres, 'gi_land_acres', f.gi_land_acres, 'notes', f.extra->>'notes') $$;

-- he proposes: someone at Procurement or Village Batch of the client (not its Client Manager, who changes it himself)
create or replace function app.propose_farmer_change(p_farmer uuid, p jsonb, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := app.me_or_raise(); f public.farmers; k text; ch jsonb := '{}'::jsonb; cur jsonb; pr public.farmer_proposals; v numeric;
begin
  select * into f from public.farmers where id = p_farmer;
  if f.id is null then raise exception 'farmer not found' using errcode = 'P0002'; end if;
  if app.client_account_holder(me, f.client_id) then
    raise exception 'you are this client''s Client Manager: change the farmer yourself' using errcode = '23514'; end if;
  if not app.farmer_create(f.client_id) then
    raise exception 'a correction is proposed by someone at Procurement or Village Batch of this client' using errcode = '42501'; end if;
  if f.status = 'draft' then raise exception 'this farmer is still a draft: change it on its page' using errcode = '23514'; end if;
  if f.status = 'inactive' then raise exception 'this farmer is deactivated' using errcode = '23514'; end if;
  if length(btrim(coalesce(p_reason, ''))) < 3 then raise exception 'say why (what is wrong or missing)' using errcode = '23514'; end if;
  if jsonb_typeof(p) <> 'object' then raise exception 'the corrected values' using errcode = '23514'; end if;
  cur := app.farmer_values(f);
  for k in select jsonb_object_keys(p) loop
    if not (k = any(app.proposal_fields())) then raise exception '"%" cannot be proposed', k using errcode = '23514'; end if;
    if nullif(btrim(p->>k), '') is null then continue; end if;
    if k in ('land_area_acres', 'gi_land_acres') then
      begin v := (p->>k)::numeric; exception when others then v := null; end;
      if v is null or v <= 0 or v > 100000 then raise exception '%: a number of acres above 0', k using errcode = '23514'; end if;
      if (cur->>k) is null or (cur->>k)::numeric <> v then ch := ch || jsonb_build_object(k, v); end if;
    else
      if (cur->>k) is distinct from btrim(p->>k) then ch := ch || jsonb_build_object(k, left(btrim(p->>k), 200)); end if;
    end if;
  end loop;
  if ch = '{}'::jsonb then raise exception 'nothing differs from the farmer''s record' using errcode = '23514'; end if;
  insert into public.farmer_proposals (farmer_id, client_id, changes, before, reason, requested_by)
  values (f.id, f.client_id, ch, (select jsonb_object_agg(x, cur->x) from jsonb_object_keys(ch) x), left(btrim(p_reason), 300), me)
  returning * into pr;
  perform app.audit('farmer_change_proposed', f.id, jsonb_build_object('proposal', pr.id, 'fields', (select jsonb_agg(x) from jsonb_object_keys(ch) x),
    'reason', pr.reason, 'farmer_code', f.farmer_code), false);
  return to_jsonb(pr) - 'changes' - 'before' || jsonb_build_object('fields', (select jsonb_agg(x) from jsonb_object_keys(ch) x));
end $$;

-- the open ones (and the last decided) for the Client Manager of the client; his own for the one who proposed
create or replace function app.farmer_proposals(p_client uuid default null, p_farmer uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := app.me_or_raise();
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', x.id, 'farmer_id', x.farmer_id, 'farmer_name', f.name, 'farmer_code', f.farmer_code,
             'changes', x.changes, 'before', x.before, 'reason', x.reason, 'status', x.status,
             'requested_by', (select display_name from public.app_users where id = x.requested_by), 'requested_at', x.requested_at,
             'decided_by', (select display_name from public.app_users where id = x.decided_by), 'decided_at', x.decided_at,
             'decided_reason', x.decided_reason, 'mine', x.requested_by = me,
             'can_decide', x.status = 'requested' and app.client_account_holder(me, x.client_id))
           order by x.status <> 'requested', x.requested_at desc)
      from public.farmer_proposals x join public.farmers f on f.id = x.farmer_id
     where (p_client is null or x.client_id = p_client) and (p_farmer is null or x.farmer_id = p_farmer)
       and (app.client_account_holder(me, x.client_id) or x.requested_by = me)
       and (x.status = 'requested' or x.decided_at > now() - interval '30 days')), '[]'::jsonb);
end $$;

-- the Client Manager decides: approve (the change is made in his name, with the proposer and the reason) or refuse
create or replace function app.decide_farmer_proposal(p_id uuid, p_approve boolean, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := app.me_or_raise(); pr public.farmer_proposals; who text;
begin
  select * into pr from public.farmer_proposals where id = p_id for update;
  if pr.id is null then raise exception 'proposal not found' using errcode = 'P0002'; end if;
  if not app.client_account_holder(me, pr.client_id) then
    raise exception 'the Client Manager of this client decides it' using errcode = '42501'; end if;
  if pr.status <> 'requested' then raise exception 'this proposal is % already', pr.status using errcode = '23514'; end if;
  who := (select display_name from public.app_users where id = pr.requested_by);
  if p_approve then
    perform app.change_farmer(pr.farmer_id, pr.changes, format('proposed by %s: %s', who, pr.reason));
    update public.farmer_proposals set status = 'approved', decided_by = me, decided_at = now(), decided_reason = nullif(left(btrim(p_reason), 300), '')
     where id = pr.id returning * into pr;
    perform app.audit('farmer_change_approved', pr.farmer_id, jsonb_build_object('proposal', pr.id, 'proposed_by', who), false);
  else
    if length(btrim(coalesce(p_reason, ''))) < 3 then raise exception 'say why you refuse it' using errcode = '23514'; end if;
    update public.farmer_proposals set status = 'refused', decided_by = me, decided_at = now(), decided_reason = left(btrim(p_reason), 300)
     where id = pr.id returning * into pr;
    perform app.audit('farmer_change_refused', pr.farmer_id, jsonb_build_object('proposal', pr.id, 'proposed_by', who, 'reason', pr.decided_reason), true);
  end if;
  return jsonb_build_object('id', pr.id, 'status', pr.status);
end $$;

-- he withdraws his own while it waits
create or replace function app.withdraw_farmer_proposal(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := app.me_or_raise(); pr public.farmer_proposals;
begin
  update public.farmer_proposals set status = 'withdrawn', decided_by = me, decided_at = now()
   where id = p_id and requested_by = me and status = 'requested' returning * into pr;
  if pr.id is null then raise exception 'only your own proposal, while it waits' using errcode = '42501'; end if;
  perform app.audit('farmer_change_withdrawn', pr.farmer_id, jsonb_build_object('proposal', pr.id), false);
  return jsonb_build_object('id', pr.id, 'status', pr.status);
end $$;

revoke all on function app.proposal_fields(), app.farmer_values(public.farmers) from public, anon, authenticated;
revoke all on function app.propose_farmer_change(uuid, jsonb, text), app.farmer_proposals(uuid, uuid),
  app.decide_farmer_proposal(uuid, boolean, text), app.withdraw_farmer_proposal(uuid) from public, anon;
grant execute on function app.propose_farmer_change(uuid, jsonb, text), app.farmer_proposals(uuid, uuid),
  app.decide_farmer_proposal(uuid, boolean, text), app.withdraw_farmer_proposal(uuid) to authenticated;
