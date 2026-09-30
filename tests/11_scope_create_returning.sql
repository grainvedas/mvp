-- Migration 18: a Client Manager creates a draft scope and gets the row back (INSERT … RETURNING under RLS).
begin;
select t.as_service();
do $$
declare r public.scopes;
begin
  perform t.as_user(t.u('03'));
  insert into public.scopes (client_id, crop_id, season_code, geography, chain, status)
  values ('00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000101', 'RB27', 'Returning test',
          '{procurement,qc,qr_activation}', 'draft') returning * into r;
  perform t.ok(r.id is not null and r.status = 'draft', 'client manager creates a draft scope and reads it back');
  update public.scopes set status = 'active' where id = r.id returning * into r;
  perform t.ok(r.status = 'active' and r.quality_params is not null, 'client manager activates it; limits frozen at activation');
  perform t.as_user(t.u('04'));
  perform t.ok((select count(*) from public.scopes where id = r.id) = 1, 'client view sees the new scope');
  perform t.as_user(t.u('12'));
  perform t.ok((select count(*) from public.scopes where id = r.id) = 0, 'other client''s operator does not');
  perform t.fails($q$ insert into public.scopes (client_id, crop_id, season_code, geography, chain, status)
    values ('00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000101', 'RB27', 'Nope', '{procurement,qc,qr_activation}', 'draft') $q$,
    'row-level security', 'an operator cannot create a scope');
  perform t.as_service();
end $$;
rollback;
