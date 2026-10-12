-- GrainVeda MVP · seed 07: HR by geography (migration 39). Idempotent. Never on production.
--   Imran (317, HR resource) works for Uttar Pradesh; every demo employee is based in the state of their seats
--   (Uttar Pradesh for everyone in the demo), so Imran's screens show the same people as before.
--   Asha (316, HR Admin) needs no states: she works for every state.
do $$ begin
  if to_regprocedure('app.environment()') is not null then
    if app.environment() = 'production' then
      raise exception 'demo seed refused: this is the PRODUCTION project (use supabase/seeds/production/)';
    end if;
  end if;
end $$;

insert into public.hr_states (employee_id, state_id, set_by)
select '00000000-0000-4000-8000-000000000317', '00000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000316'
 where not exists (select 1 from public.hr_states where employee_id = '00000000-0000-4000-8000-000000000317'
                     and state_id = '00000000-0000-4000-8000-000000000001' and ended_at is null);

-- an HR record for the demo people the older seeds made without one
insert into public.employee_org (employee_id)
select u.id from public.app_users u
 where not u.external and u.system_role <> 'admin' and not exists (select 1 from public.employee_org e where e.employee_id = u.id);

-- where each is based: the one state of their seats, else Uttar Pradesh (the demo's state)
with seats as (
  select a.employee_id, array_agg(distinct coalesce(a.state_id, sc.state_id, c.state_id)) as st
    from public.assignments a left join public.scopes sc on sc.id = a.scope_id left join public.clients c on c.id = a.client_id
   where a.active group by a.employee_id)
update public.employee_org e
   set base_state_id = coalesce(case when cardinality(s.st) = 1 then s.st[1] end, '00000000-0000-4000-8000-000000000001')
  from public.app_users u left join seats s on s.employee_id = u.id
 where u.id = e.employee_id and e.base_state_id is null and not u.external and u.system_role <> 'admin';
