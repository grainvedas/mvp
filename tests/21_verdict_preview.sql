-- Migration 29, part 2: the lab verdict before saving (FIX_LIST item 9).
-- app.preview_verdict must say exactly what the save derives. The save's own function (derive_qc_verdict) is untouched;
-- this file holds the two to the same answer, case by case.
begin;
select t.as_service();

do $$
declare s uuid := t.scope('01'); c constant uuid := '00000000-0000-4000-8000-000000000201';
        p uuid; q uuid; v public.qc_verdicts; j jsonb; rd jsonb; n int := 0;
        cases constant jsonb := '[
          {"readings": {"moisture_pct":11.9,"broken_pct":2,"foreign_matter_pct":0.2},   "dom":"pass",    "exp":"pass"},
          {"readings": {"moisture_pct":12.6,"broken_pct":3.4,"foreign_matter_pct":0.4}, "dom":"pass",    "exp":"fail"},
          {"readings": {"moisture_pct":13.5,"broken_pct":2,"foreign_matter_pct":0.2},   "dom":"fail",    "exp":"fail"},
          {"readings": {"moisture_pct":11.9,"broken_pct":2},                            "dom":"pending", "exp":"pending"},
          {"readings": {"moisture_pct":13.0,"broken_pct":5,"foreign_matter_pct":1},     "dom":"pass",    "exp":"fail"}
        ]';
begin
  for rd in select * from jsonb_array_elements(cases) loop
    n := n + 1;
    perform t.as_service();
    p := t.procure(s, t.farmer(lpad(n::text, 2, '0')), 150, 1, 2.5, 11.9, 11.8, 12.0);
    perform t.as_user(t.u('06')); perform app.verify_footprint(p);
    j := app.preview_verdict(s, rd->'readings');                    -- what the form shows before saving
    insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
    values (s, c, 'qc', p, t.u('06'), jsonb_build_object('qty_kg', 147.5, 'sample_qty_kg', 0.5, 'readings', rd->'readings')) returning id into q;
    perform t.as_service();
    select * into v from public.qc_verdicts where footprint_id = q;  -- what the save derived
    perform t.ok((j->>'ok')::boolean and j->>'domestic' = v.domestic_verdict::text and j->>'export' = v.export_verdict::text and j->'judged' = v.judged,
                 format('verdict preview = verdict saved (case %s: %s / %s)', n, v.domestic_verdict, v.export_verdict));
    perform t.ok(v.domestic_verdict::text = rd->>'dom' and v.export_verdict::text = rd->>'exp',
                 format('verdict preview: case %s is %s / %s as the limits say', n, rd->>'dom', rd->>'exp'));
  end loop;

  perform t.ok(app.judge_readings(s, '{"moisture_pct":11.9,"broken_pct":2,"foreign_matter_pct":0.2}') -> 'judged' @> '[{"param":"moisture_pct","domestic":"pass","export":"pass"}]',
               'verdict preview: each parameter is judged on its own');
  -- who may ask
  perform t.as_anon();
  perform t.fails($q$ select app.preview_verdict('00000000-0000-4000-8000-000000000401', '{}') $q$, 'permission denied', 'verdict preview: an anonymous visitor cannot call it');
  perform t.fails($q$ select app.judge_readings('00000000-0000-4000-8000-000000000401', '{}') $q$, 'permission denied', 'verdict preview: the inner function is closed to the API');
  perform t.as_user(t.u('12'));
  perform t.ok((app.preview_verdict(s, '{"moisture_pct":11}') ->> 'ok')::boolean = false, 'verdict preview: another client''s operator gets no answer for this scope');
  perform t.fails($q$ select app.judge_readings('00000000-0000-4000-8000-000000000401', '{}') $q$, 'permission denied', 'verdict preview: a signed-in person cannot call the inner function either');
  perform t.as_service();
end $$;

rollback;
