-- GrainVeda MVP · Phase 0 · migration 12: identifiers that cannot collide (execution plan, workstream H; PRD §8)
--   * Farmer ID used count(*) + 1: two State Managers verifying at once got the same number (the second save failed on
--     the unique farmer_code). It now comes from a per-client counter row, incremented atomically like footprint codes.
--   * lpad(n, 4, '0') truncates: number 10000 became '1000' and collided with number 1000, in Farmer IDs and in footprint
--     codes. Numbers are now padded to at least 4 digits and never cut.
-- Formats are unchanged: PRSDM-F-0006, PRSDM-KNM-KH26-P-0001.

create table public.farmer_id_counters (
  client_id  uuid primary key references public.clients(id),
  last_seq   int not null default 0
);
alter table public.farmer_id_counters enable row level security;
revoke all on public.farmer_id_counters from authenticated, anon;   -- touched only inside security-definer code

-- Start each client at the highest Farmer ID already issued (the demo seed issued PRSDM-F-0001 … 0005).
insert into public.farmer_id_counters (client_id, last_seq)
select client_id, coalesce(max(substring(farmer_code from '-F-([0-9]+)$')::int), 0)
  from public.farmers where farmer_code is not null
 group by client_id;

create or replace function app.pad_seq(n int) returns text
language sql immutable as $$ select lpad(n::text, greatest(4, length(n::text)), '0') $$;

create or replace function app.next_farmer_code(p_client uuid) returns text
language plpgsql security definer set search_path = public as $$
declare v_seq int;
begin
  insert into public.farmer_id_counters as c (client_id, last_seq) values (p_client, 1)
  on conflict (client_id) do update set last_seq = c.last_seq + 1
  returning c.last_seq into v_seq;
  return (select code from public.clients where id = p_client) || '-F-' || app.pad_seq(v_seq);
end $$;

-- Farmer ID is issued only by a State Manager (or admin) verification. Body as migration 4, counter instead of count+1.
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
      new.farmer_code := app.next_farmer_code(new.client_id);
    end if;
  elsif tg_op = 'INSERT' and new.status = 'active' then
    raise exception 'farmers are created as draft/under_review; activation is a verification act' using errcode = '23514';
  end if;
  return new;
end $$;

-- Footprint codes: body as migration 4, padding that never truncates.
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
  return format('%s-%s-%s-%s-%s%s', v_client, v_crop, v_season, v_stage, app.pad_seq(v_seq),
                case when p_grade is null then '' else '-' || p_grade end);
end $$;
