-- GrainVeda: EMPTY THE PRACTICE SYSTEM, to start it the way a pilot starts: with nothing in it.
-- Removes every person, state, crop, client, scope, farmer, record, verdict, seal, flag, ledger block, audit line,
-- counter and joining file entry. Keeps: the rules themselves (the migrations), the 16 stage definitions, the standard
-- joining checklist, and the mark that says which system this is.
-- NOT REVERSIBLE. Refuses on production. Logins and stored files are not in this database's reach: they are removed
-- by scripts/fresh_start/clear_logins_and_files.mjs.
-- Run it only through scripts/staging_fresh_start.ps1, which checks the project, copies the rows out first, and puts
-- the first admin back afterwards. One transaction: it empties everything or nothing.
begin;

do $$
declare
  keep text[] := array['app_meta', 'stage_definitions', 'onboarding_templates', 'template_tasks'];
  list text;
  link record;
begin
  if app.environment() <> 'staging' then
    raise exception 'refused: this project says it is "%", not staging. Nothing was removed.', app.environment();
  end if;

  -- The standard joining checklist stays (migration 31 wrote it; HR needs it for the first joiner). Checklists made
  -- by people go, and the standard one no longer points at a person who is about to be removed.
  delete from public.template_tasks where template_id in (select id from public.onboarding_templates where not is_default);
  delete from public.onboarding_templates where not is_default;
  update public.onboarding_templates set created_by = null where created_by is not null;

  -- Every table of the public schema except the four above: a table added by a later migration is emptied too,
  -- unless it is added to "keep". TRUNCATE names them all at once, so the links between them do not get in the way.
  select string_agg(format('public.%I', c.relname), ', ' order by c.relname) into list
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and c.relname <> all (keep);

  -- The audit log refuses TRUNCATE for everyone. Only the owner of the database can set that aside, and does it
  -- here, once, on purpose: the fresh system starts with an empty log, and its first line is the first admin.
  -- A table that stays may point at one that is emptied (the checklist's "made by" points at people). Postgres then
  -- refuses the TRUNCATE even when no row points anywhere, so such a link is taken off and put back exactly as it
  -- was, inside this same transaction.
  create temporary table fresh_start_links on commit drop as
    select con.conname, con.conrelid::regclass::text as tab, pg_get_constraintdef(con.oid) as def
      from pg_constraint con
      join pg_class kept on kept.oid = con.conrelid join pg_namespace kn on kn.oid = kept.relnamespace
      join pg_class gone on gone.oid = con.confrelid join pg_namespace gn on gn.oid = gone.relnamespace
     where con.contype = 'f' and kn.nspname = 'public' and gn.nspname = 'public'
       and kept.relname = any (keep) and gone.relname <> all (keep);
  for link in select * from fresh_start_links loop
    execute format('alter table %s drop constraint %I', link.tab, link.conname);
  end loop;

  alter table public.audit_log disable trigger audit_log_no_truncate;
  execute 'truncate table ' || list || ' restart identity';
  alter table public.audit_log enable trigger audit_log_no_truncate;

  for link in select * from fresh_start_links loop
    execute format('alter table %s add constraint %I %s', link.tab, link.conname, link.def);
  end loop;

  insert into public.app_meta (key, value)
  values ('fresh_start', to_char(now() at time zone 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI') || ' IST')
  on conflict (key) do update set value = excluded.value;
end $$;

commit;

-- What is in the system now (the script reads this line).
select 'fresh start: people=' || (select count(*) from public.app_users)
    || ' states=' || (select count(*) from public.states)
    || ' crops=' || (select count(*) from public.crops)
    || ' clients=' || (select count(*) from public.clients)
    || ' scopes=' || (select count(*) from public.scopes)
    || ' farmers=' || (select count(*) from public.farmers)
    || ' records=' || (select count(*) from public.footprints)
    || ' ledger=' || (select count(*) from public.ledger)
    || ' audit=' || (select count(*) from public.audit_log)
    || ' stage_definitions=' || (select count(*) from public.stage_definitions)
    || ' checklist_tasks=' || (select count(*) from public.template_tasks)
    || ' audit_guard=' || (select case when tgenabled = 'O' then 'on' else 'OFF' end from pg_trigger where tgname = 'audit_log_no_truncate')
    || ' links_back=' || (select count(*) from pg_constraint where contype = 'f' and conrelid = 'public.onboarding_templates'::regclass)
    as result;
