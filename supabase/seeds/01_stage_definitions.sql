-- GrainVeda MVP · seed: stage_definitions — the single stage registry (PRD §5.4 flags, §7 physics, F1)
-- form_schema: fields the generic 8-step component renders at step 4. handoff_checks: tick-list written at step 8.
-- "section" (since 4 Oct 2026) groups consecutive fields under a heading on the form; its words are in the app's
-- dictionaries (section.<key>). It says nothing about what is stored: no database rule reads it.
-- Idempotent.

insert into public.stage_definitions
  (stage_type, code, label, is_first, is_gate, splits_forward, aggregates, allows_exceed_input, yield_alarm, is_processing, sort_order, form_schema, handoff_checks)
values
('procurement', 'P', 'Procurement (farm-gate)', true, false, false, false, false, false, false, 10,
 '[{"key":"farmer_id","section":"farmer","label":"Farmer","type":"farmer","required":true,"column":true},
   {"key":"gross_kg","section":"weighing","label":"Gross weight","unit":"kg","type":"number","required":true},
   {"key":"bags","section":"weighing","label":"Bags","type":"integer","required":true},
   {"key":"tare_kg_per_bag","section":"weighing","label":"Tare per bag","unit":"kg","type":"number","required":true},
   {"key":"moisture_pct","section":"moisture","label":"Moisture (3 readings)","unit":"%","type":"number[3]","required":true},
   {"key":"photo","section":"evidence","label":"Photo evidence","type":"attachment","required":false},
   {"key":"collection_point_id","section":"where","label":"Where (collection point, or at the farm)","type":"collection_point","required":false,"required_when":"procurement_details_required"},
   {"key":"gps","section":"where","label":"GPS where the lot was weighed","type":"gps","required":false,"required_when":"procurement_details_required"},
   {"key":"delivered_by","section":"where","label":"Delivered by","type":"select","options":["farmer","family","agent"],"required":false,"required_when":"procurement_details_required"},
   {"key":"agent_name","section":"where","label":"Agent''s name (when an agent delivered)","type":"text","required":false},
   {"key":"harvest_date","section":"optional","label":"Harvest date","type":"date","required":false},
   {"key":"condition","section":"optional","label":"Condition","type":"select","options":["good","damp","pest","mixed"],"required":false},
   {"key":"slip","section":"optional","label":"Weighbridge or scale slip (photo)","type":"attachment","required":false,"label_as":"document"},
   {"key":"price_per_quintal","section":"payment","label":"Price per quintal","unit":"₹/quintal","type":"number","required":false,"shown_when":"record_price","required_when":"record_price"},
   {"key":"payment_status","section":"payment","label":"Payment","type":"select","options":["pending","paid"],"required":false,"shown_when":"record_price","required_when":"record_price"},
   {"key":"payment_mode","section":"payment","label":"Paid by","type":"select","options":["bank","upi","cash"],"required":false,"shown_when":"record_price"},
   {"key":"txn_ref","section":"payment","label":"Transaction ID (never an account number)","type":"text","required":false,"shown_when":"record_price"}]',
 '["Farmer is active and named","Gross, bags and tare recorded","Three moisture readings recorded","Net quantity reviewed"]'),

('lot_inward', 'LI', 'Lot Inward (pre-aggregated lot)', true, false, false, false, false, false, false, 20,
 '[{"key":"declared_kg","section":"weighing","label":"Declared quantity","unit":"kg","type":"number","required":true},
   {"key":"weighed_kg","section":"weighing","label":"Actual weighed","unit":"kg","type":"number","required":true},
   {"key":"source_type","section":"source","label":"Source type","type":"select","options":["farmer_group","fpo","trader","own_farm"],"required":true},
   {"key":"source_name","section":"source","label":"Source name","type":"text","required":true},
   {"key":"crop_declared","section":"source","label":"Crop declared","type":"text","required":true},
   {"key":"moisture_pct","section":"quality","label":"Moisture baseline","unit":"%","type":"number","required":true},
   {"key":"condition","section":"quality","label":"Condition","type":"text","required":false}]',
 '["Weighed quantity recorded","Source declared","Crop declared","Moisture baseline recorded","Date recorded"]'),

('village_batch', 'VB', 'Collection Batch (one collection point)', false, false, false, true, false, false, false, 30,
 '[{"key":"source_footprint_ids","section":"batch","label":"Farmer lots in this batch","type":"footprint[]","required":true,"sets_prev":true},
   {"key":"single_origin","section":"batch","label":"Single-origin batch (lots from one village only)","type":"boolean","required":false},
   {"key":"bags","section":"batch","label":"Bags in the batch","type":"integer","required":false},
   {"key":"reweighed_kg","section":"weighing","label":"Re-weighed total (optional)","unit":"kg","type":"number","required":false},
   {"key":"moisture_fresh_pct","section":"weighing","label":"Fresh moisture reading (optional)","unit":"%","type":"number","required":false}]',
 '["All source lots verified","Batch total equals sum of sources","One collection point; villages from the lots"]'),

('milling', 'M', 'Milling', false, false, false, false, false, true, true, 40,
 '[{"key":"input_kg","section":"input","label":"Paddy in","unit":"kg","type":"number","required":true},
   {"key":"rice_kg","section":"output","label":"Rice out","unit":"kg","type":"number","required":true},
   {"key":"bran_kg","section":"output","label":"Bran","unit":"kg","type":"number","required":true},
   {"key":"loss_kg","section":"output","label":"Loss","unit":"kg","type":"number","required":true}]',
 '["Input = rice + bran + loss","Yield reviewed","Rice quantity forwarded"]'),

('sorting', 'S', 'Sorting', false, false, false, false, false, false, true, 50,
 '[{"key":"input_kg","section":"input","label":"Input","unit":"kg","type":"number","required":true},
   {"key":"reject_kg","section":"output","label":"Reject","unit":"kg","type":"number","required":true},
   {"key":"reject_reasons","section":"output","label":"Reject reasons","type":"breakdown","required":false},
   {"key":"loss_kg","section":"output","label":"Loss","unit":"kg","type":"number","required":true}]',
 '["Clean output derived = input - reject - loss","Reject reasons recorded","Clean quantity forwarded"]'),

('grading', 'G', 'Grading', false, false, true, false, false, false, true, 60,
 '[{"key":"input_kg","section":"input","label":"Input","unit":"kg","type":"number","required":true},
   {"key":"grade_a_kg","section":"grades","label":"Grade A","unit":"kg","type":"number","required":true},
   {"key":"grade_b_kg","section":"grades","label":"Grade B","unit":"kg","type":"number","required":true},
   {"key":"grade_c_kg","section":"grades","label":"Grade C","unit":"kg","type":"number","required":true},
   {"key":"reject_kg","section":"output","label":"Reject","unit":"kg","type":"number","required":true},
   {"key":"loss_kg","section":"output","label":"Loss","unit":"kg","type":"number","required":true},
   {"key":"split_into_grades","section":"output","label":"Split into grade lots","type":"boolean","required":false,"column":true}]',
 '["A + B + C + reject + loss = input","Split decision recorded","Grade quantities forwarded"]'),

('drying', 'D', 'Drying', false, false, false, false, false, false, true, 70,
 '[{"key":"input_kg","section":"input","label":"Input","unit":"kg","type":"number","required":true},
   {"key":"moisture_in_pct","section":"input","label":"Moisture in","unit":"%","type":"number","required":true},
   {"key":"moisture_out_pct","section":"output","label":"Moisture out","unit":"%","type":"number","required":true},
   {"key":"output_kg","section":"output","label":"Output","unit":"kg","type":"number","required":true}]',
 '["Moisture in and out recorded","Water removed reconciled","Output forwarded"]'),

('popping', 'PP', 'Popping (makhana)', false, false, false, false, false, false, true, 80,
 '[{"key":"input_kg","section":"input","label":"Input","unit":"kg","type":"number","required":true},
   {"key":"output_kg","section":"output","label":"Output","unit":"kg","type":"number","required":true},
   {"key":"pop_rate_pct","section":"output","label":"Pop rate","unit":"%","type":"number","required":true}]',
 '["Pop rate recorded","Output forwarded"]'),

('cleaning', 'C', 'Cleaning', false, false, false, false, false, false, true, 90,
 '[{"key":"input_kg","section":"input","label":"Input","unit":"kg","type":"number","required":true},
   {"key":"foreign_matter_kg","section":"output","label":"Foreign matter removed","unit":"kg","type":"number","required":true},
   {"key":"loss_kg","section":"output","label":"Loss","unit":"kg","type":"number","required":true}]',
 '["Foreign matter recorded separately from loss","Output forwarded"]'),

('blanching', 'B', 'Blanching', false, false, false, false, true, false, true, 100,
 '[{"key":"input_kg","section":"input","label":"Input","unit":"kg","type":"number","required":true},
   {"key":"output_kg","section":"output","label":"Output","unit":"kg","type":"number","required":true}]',
 '["Water uptake recorded","Output forwarded"]'),

('cold_storage', 'CS', 'Cold Storage', false, false, false, false, false, false, true, 110,
 '[{"key":"stored_kg","section":"storage","label":"Quantity stored","unit":"kg","type":"number","required":true},
   {"key":"stored_on","section":"storage","label":"Stored on","type":"date","required":true},
   {"key":"retrieved_kg","section":"retrieval","label":"Quantity retrieved","unit":"kg","type":"number","required":true},
   {"key":"retrieved_on","section":"retrieval","label":"Retrieved on","type":"date","required":true}]',
 '["Retrieved quantity recorded","Spoilage reconciled","Retrieved quantity forwarded"]'),

('packing', 'PK', 'Packing', false, false, false, false, false, false, true, 120,
 '[{"key":"input_kg","section":"input","label":"Input","unit":"kg","type":"number","required":true},
   {"key":"packets","section":"packing","label":"Packets","type":"packets[]","required":true},
   {"key":"wastage_kg","section":"packing","label":"Wastage","unit":"kg","type":"number","required":true},
   {"key":"batch_code","section":"packing","label":"Batch code (QR link)","type":"text","required":true}]',
 '["Batch code assigned","Σ packets + wastage = input","Packed quantity forwarded"]'),

('qc', 'QC', 'Quality Control', false, false, false, false, false, false, false, 130,
 '[{"key":"qty_kg","section":"sample","label":"Lot quantity","unit":"kg","type":"number","required":true},
   {"key":"sample_qty_kg","section":"sample","label":"Sample drawn","unit":"kg","type":"number","required":true},
   {"key":"readings","section":"readings","label":"Readings per crop parameter","type":"readings","required":true},
   {"key":"lab_ref","section":"lab","label":"Lab reference","type":"text","required":false}]',
 '["All crop parameters read","Both verdicts derived","Sample deducted; forwarding quantity reviewed"]'),

('commercial', 'CM', 'Commercial Clearance', false, false, true, false, false, false, false, 140,
 '[{"key":"buyer","section":"buyer","label":"Buyer","type":"text","required":true},
   {"key":"market","section":"buyer","label":"Market","type":"select","options":["domestic","export"],"required":true,"gate":"market_verdict"},
   {"key":"qty_kg","section":"quantity","label":"Quantity to this buyer","unit":"kg","type":"number","required":true},
   {"key":"price_per_kg","section":"quantity","label":"Price","unit":"INR/kg","type":"number","required":false}]',
 '["Buyer and market recorded","Export sale backed by export PASS or override","Allocation within available"]'),

('shipment', 'SH', 'Shipment', false, false, false, false, false, false, false, 150,
 '[{"key":"shipped_kg","section":"quantity","label":"Shipped","unit":"kg","type":"number","required":true},
   {"key":"transit_loss_kg","section":"quantity","label":"Transit loss","unit":"kg","type":"number","required":false},
   {"key":"vehicle_or_container","section":"transport","label":"Vehicle / container","type":"text","required":true},
   {"key":"dispatch_date","section":"transport","label":"Dispatch date","type":"date","required":true},
   {"key":"destination","section":"transport","label":"Destination","type":"text","required":true},
   {"key":"documents","section":"documents","label":"Documents (photo or PDF)","type":"attachment","accept":"document","required":false}]',
 '["Dispatch recorded","Transit loss carried to forwarding quantity","Documents attached"]'),

('qr_activation', 'QR', 'QR Activation (seal)', false, true, false, false, false, false, false, 160,
 '[]',
 '["Every stage behind verified","QC verdict present","No open flags","Final quantity recorded"]')
on conflict (stage_type) do update set
  code = excluded.code, label = excluded.label, is_first = excluded.is_first, is_gate = excluded.is_gate,
  splits_forward = excluded.splits_forward, aggregates = excluded.aggregates, allows_exceed_input = excluded.allows_exceed_input,
  yield_alarm = excluded.yield_alarm, is_processing = excluded.is_processing, sort_order = excluded.sort_order,
  form_schema = excluded.form_schema, handoff_checks = excluded.handoff_checks;

-- Migration 49 (A2/G3): what the receiving person checks with his own eyes; the rest the system checks (app.system_checks).
-- The same list as the migration, so a database built from nothing has it too.
-- A database from before migration 49 (the upgrade path of tests/run_local.sh) has no column yet: migration 49 fills it.
do $seed49$ begin
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'stage_definitions' and column_name = 'physical_checks') then
    execute $q$
update public.stage_definitions d set physical_checks = v.c::jsonb from (values
  ('procurement',  '["Bags counted: the number matches the record", "The grain looks and smells sound (no mould, no insects)", "Bags tagged with the lot number"]'),
  ('lot_inward',   '["Bags counted: the number matches the record", "The grain looks and smells sound (no mould, no insects)"]'),
  ('village_batch','["Bags of every lot counted at the collection point", "Batch bags tagged with the batch number"]'),
  ('milling',      '["Rice bags sealed and tagged with the lot number", "The mill line was clear of any other rice"]'),
  ('sorting',      '["Bags sealed and tagged with the lot number"]'),
  ('grading',      '["Each grade bagged apart and tagged with its lot number"]'),
  ('drying',       '["Bags sealed and tagged with the lot number"]'),
  ('popping',      '["Bags sealed and tagged with the lot number"]'),
  ('cleaning',     '["Bags sealed and tagged with the lot number"]'),
  ('blanching',    '["Bags sealed and tagged with the lot number"]'),
  ('cold_storage', '["Bags counted out of storage"]'),
  ('packing',      '["Packs sealed; the labels match the batch", "Wastage bagged and weighed"]'),
  ('qc',           '["Sample bag sealed and labelled", "Counter-sample stored"]'),
  ('commercial',   '["Packs set aside for this buyer counted"]'),
  ('shipment',     '["Packs counted at loading", "Vehicle clean and dry"]'),
  ('qr_activation','[]')) as v(t, c)
 where d.stage_type::text = v.t;
    $q$;
  end if;
end $seed49$;

-- Migration 50: the batch code is the system's; transit loss is recorded at delivery; the lab report (the same edits as
-- the migration, so a database built from nothing has them).
update public.stage_definitions set form_schema = (select coalesce(jsonb_agg(x order by n), '[]'::jsonb)
                                                     from jsonb_array_elements(form_schema) with ordinality as e(x, n) where x->>'key' <> 'batch_code')
 where stage_type = 'packing';
update public.stage_definitions set form_schema = (select coalesce(jsonb_agg(x order by n), '[]'::jsonb)
                                                     from jsonb_array_elements(form_schema) with ordinality as e(x, n) where x->>'key' <> 'transit_loss_kg')
 where stage_type = 'shipment';
update public.stage_definitions set form_schema = form_schema || '[
  {"key": "lab_name", "type": "text", "label": "Lab", "section": "lab", "required": false, "required_when": "qc_report_required"},
  {"key": "report_no", "type": "text", "label": "Report number", "section": "lab", "required": false, "required_when": "qc_report_required"},
  {"key": "report_date", "type": "date", "label": "Report date", "section": "lab", "required": false, "required_when": "qc_report_required"},
  {"key": "sample_id", "type": "text", "label": "Sample ID", "section": "lab", "required": false},
  {"key": "report_file", "type": "attachment", "label": "Lab report (PDF or photo)", "accept": "document", "section": "lab", "required": false, "required_when": "qc_report_required", "label_as": "lab_report"}
]'::jsonb
 where stage_type = 'qc' and not (form_schema @> '[{"key": "report_no"}]');

-- Migration 53: Milling, Quality Control and Packing (the same edits as the migration, so a database built from nothing
-- has them).
-- Milling: head rice, broken, husk and bran replace "rice out / bran / loss" (the loss is worked out). Records of before
-- keep their payloads and are read and corrected as before (app.reconcile reads both).
update public.stage_definitions set form_schema = '[
  {"key": "mill_id", "type": "mill", "label": "Mill", "section": "mill", "required": false, "required_when": "stage_details_required"},
  {"key": "line_clearance", "type": "select", "label": "Line clearance", "options": ["fully_cleaned", "quick_clean", "same_crop"], "section": "mill", "required": false},
  {"key": "mill_operator", "type": "text", "label": "Mill operator", "section": "mill", "required": false, "required_when": "stage_details_required"},
  {"key": "input_kg", "type": "number", "unit": "kg", "label": "Paddy in", "section": "input", "required": true},
  {"key": "sent_kg", "type": "number", "unit": "kg", "label": "Sent from the lot (when the mill is elsewhere)", "section": "input", "required": false},
  {"key": "head_rice_kg", "type": "number", "unit": "kg", "label": "Head rice", "section": "output", "required": true},
  {"key": "broken_kg", "type": "number", "unit": "kg", "label": "Broken rice", "section": "output", "required": true},
  {"key": "husk_kg", "type": "number", "unit": "kg", "label": "Husk", "section": "output", "required": true},
  {"key": "bran_kg", "type": "number", "unit": "kg", "label": "Bran", "section": "output", "required": true},
  {"key": "polish", "type": "select", "label": "Polish", "options": ["light", "medium", "full"], "section": "optional", "required": false},
  {"key": "slip", "type": "attachment", "label": "Mill slip (photo)", "section": "optional", "required": false, "label_as": "document"}
]'::jsonb,
  handoff_checks = '["Loss worked out from the outputs", "Recovery and head rice reviewed", "Head rice forwarded"]'::jsonb
 where stage_type = 'milling';

-- Quality Control: where the scope asks the details, the sample drawn first (its quantity, lab and counter-sample come
-- with it) replaces the typed sample quantity and lab name; elsewhere the form is as before.
update public.stage_definitions d set form_schema = (
    select coalesce(jsonb_agg(y order by k), '[]'::jsonb) from (
      select case
               when x->>'key' in ('sample_qty_kg', 'lab_name') then x || '{"hidden_when": "stage_details_required"}'::jsonb
               when x->>'key' = 'sample_id' then x || '{"label": "Shared sample ID (two lots tested on one sample)"}'::jsonb
               else x end as y, n::numeric as k
        from jsonb_array_elements(d.form_schema) with ordinality as e(x, n) where x->>'key' not in ('sample_ref', 'lab_id')
      union all   -- the sample stands next to the lot quantity, in the "sample" section
      select '{"key": "sample_ref", "type": "qc_sample", "label": "Sample (drawn and sent to the lab)", "section": "sample", "required": false, "shown_when": "stage_details_required", "required_when": "stage_details_required"}'::jsonb,
             coalesce((select n from jsonb_array_elements(d.form_schema) with ordinality as e(x, n) where x->>'key' = 'qty_kg'), 0) + 0.5
    ) z)
 where stage_type = 'qc';

-- Packing: the packing unit; packs from the client's pack list (where the scope asks the details; typed sizes
-- otherwise); the wastage worked out, with a reason above 2 %.
update public.stage_definitions set form_schema = '[
  {"key": "input_kg", "type": "number", "unit": "kg", "label": "Input", "section": "input", "required": true},
  {"key": "packing_unit_id", "type": "packing_unit", "label": "Packing unit", "section": "packing", "required": false, "required_when": "stage_details_required"},
  {"key": "packets", "type": "sku_packs", "label": "Packs (from the pack list)", "section": "packing", "required": true, "shown_when": "stage_details_required"},
  {"key": "packets", "type": "packets[]", "label": "Packets", "section": "packing", "required": true, "hidden_when": "stage_details_required"},
  {"key": "wastage_reason", "type": "text", "label": "Why the wastage is above 2 % (when it is)", "section": "packing", "required": false}
]'::jsonb,
  handoff_checks = '["Batch code given by the system", "Packs + wastage = input", "Packed quantity forwarded"]'::jsonb
 where stage_type = 'packing';

-- Commercial checks the pack count per size, then accepts or returns (C6).
-- A database from before migration 49 has no physical checks (the upgrade path): nothing to add.
do $seed53$ begin
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'stage_definitions' and column_name = 'physical_checks') then
    execute $q$ update public.stage_definitions set physical_checks = physical_checks || '["Pack count per size matches the packing record"]'::jsonb
                 where stage_type = 'packing' and not (physical_checks @> '["Pack count per size matches the packing record"]'::jsonb) $q$;
  end if;
end $seed53$;

-- Migration 54: the Collection Batch's collection point, Commercial (C7) and Shipment (C8) (the same edits as the
-- migration, so a database built from nothing has them).
-- Collection Batch: its collection point first (Veda, 16 Oct: "there can be more than 1 cc in a scope … like in mill
-- there is option to choose"); the lots offered are that point's.
update public.stage_definitions set form_schema =
  '[{"key": "collection_point_id", "type": "collection_point", "label": "Collection point (where the bags are)", "section": "batch", "required": false, "required_when": "stage_details_required"}]'::jsonb
  || (select coalesce(jsonb_agg(x order by n), '[]'::jsonb) from jsonb_array_elements(form_schema) with ordinality as e(x, n) where x->>'key' <> 'collection_point_id')
 where stage_type = 'village_batch';

-- Commercial (C7): the buyer from the list, the export market's profile and the destination, the order number, packs by
-- type (where the batch was packed from the pack list), price and terms (kept apart; where the scope records prices).
-- A form "with_packs" field shows where the lot it comes from has packs by type; "hidden_when_packs" hides it there.
-- Migration 58: "cartons", the full cartons chosen for this order (else the oldest free ones are set aside).
update public.stage_definitions set form_schema = '[
  {"key": "buyer_id", "type": "buyer", "label": "Buyer (from the client''s list)", "section": "buyer", "required": false, "shown_when": "stage_details_required", "required_when": "stage_details_required"},
  {"key": "buyer", "type": "text", "label": "Buyer", "section": "buyer", "required": true, "hidden_when": "stage_details_required"},
  {"key": "market", "gate": "market_verdict", "type": "select", "label": "Market", "options": ["domestic", "export"], "section": "buyer", "required": true},
  {"key": "market_code", "type": "market_profile", "label": "Export market (its profile)", "section": "buyer", "required": false, "shown_when": "stage_details_required"},
  {"key": "destination_country", "type": "text", "label": "Destination country (export)", "section": "buyer", "required": false, "shown_when": "stage_details_required"},
  {"key": "order_no", "type": "text", "label": "Order or contract number", "section": "buyer", "required": false, "shown_when": "stage_details_required", "required_when": "stage_details_required"},
  {"key": "sale_route", "type": "select", "label": "Sale route", "options": ["own_brand", "white_label", "bulk", "prasaadam"], "section": "buyer", "required": false, "shown_when": "stage_details_required"},
  {"key": "packs", "type": "order_packs", "label": "Packs sold", "section": "quantity", "required": false, "shown_when": "stage_details_required", "with_packs": true},
  {"key": "cartons", "type": "order_cartons", "label": "Cartons", "section": "quantity", "required": false, "shown_when": "stage_details_required", "with_packs": true},
  {"key": "qty_kg", "type": "number", "unit": "kg", "label": "Quantity to this buyer", "section": "quantity", "required": true, "hidden_when_packs": true},
  {"key": "price_per_kg", "type": "number", "unit": "per kg", "label": "Price", "section": "terms", "required": false, "shown_when": "record_price"},
  {"key": "currency", "type": "select", "label": "Currency", "options": ["INR", "USD", "EUR", "GBP", "AED", "SAR", "JPY", "AUD"], "section": "terms", "required": false, "shown_when": "record_price"},
  {"key": "incoterms", "type": "select", "label": "Incoterms (export)", "options": ["EXW", "FCA", "FOB", "CFR", "CIF", "CPT", "CIP", "DAP", "DPU", "DDP"], "section": "terms", "required": false, "shown_when": "record_price"}
]'::jsonb
 where stage_type = 'commercial';
-- what the receiver ticks (migration 49's column: a database from before it, on the upgrade path, has none yet)
do $seed54$ begin
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'stage_definitions' and column_name = 'physical_checks') then
    execute $q$ update public.stage_definitions set physical_checks = '["Packs set aside for this buyer counted", "Packs handed over match the order"]'::jsonb
                 where stage_type = 'commercial' $q$;
  end if;
end $seed54$;

-- Shipment (C8): the packs of one order (partial shipments), the serials scanned (migration 57: for both markets, where
-- the order's lot has packs), the domestic and export
-- papers, the loading photo. A form "for_market" field shows for the order's market only.
update public.stage_definitions set form_schema = '[
  {"key": "packs", "type": "order_packs", "label": "Packs shipped", "section": "quantity", "required": false, "shown_when": "stage_details_required", "with_packs": true},
  {"key": "shipped_kg", "type": "number", "unit": "kg", "label": "Shipped", "section": "quantity", "required": true, "hidden_when_packs": true},
  {"key": "serials", "type": "serials", "label": "Pack codes loaded", "section": "quantity", "required": false, "when_packed": true},
  {"key": "vehicle_or_container", "type": "text", "label": "Vehicle / container", "section": "transport", "required": true, "hidden_when": "stage_details_required"},
  {"key": "vehicle_no", "type": "text", "label": "Vehicle number", "section": "transport", "required": false, "shown_when": "stage_details_required", "required_when": "stage_details_required", "for_market": "domestic"},
  {"key": "transporter", "type": "text", "label": "Transporter", "section": "transport", "required": false, "shown_when": "stage_details_required", "for_market": "domestic"},
  {"key": "driver_phone", "type": "text", "label": "Driver''s phone", "section": "transport", "required": false, "shown_when": "stage_details_required", "for_market": "domestic"},
  {"key": "container_no", "type": "text", "label": "Container number", "section": "transport", "required": false, "shown_when": "stage_details_required", "required_when": "stage_details_required", "for_market": "export"},
  {"key": "seal_no", "type": "text", "label": "Container seal number", "section": "transport", "required": false, "shown_when": "stage_details_required", "required_when": "stage_details_required", "for_market": "export"},
  {"key": "vessel", "type": "text", "label": "Vessel", "section": "transport", "required": false, "shown_when": "stage_details_required", "for_market": "export"},
  {"key": "forwarder", "type": "text", "label": "Forwarder", "section": "transport", "required": false, "shown_when": "stage_details_required", "for_market": "export"},
  {"key": "port_loading", "type": "text", "label": "Port of loading", "section": "transport", "required": false, "shown_when": "stage_details_required", "for_market": "export"},
  {"key": "port_discharge", "type": "text", "label": "Port of discharge", "section": "transport", "required": false, "shown_when": "stage_details_required", "for_market": "export"},
  {"key": "dispatch_date", "type": "date", "label": "Dispatch date", "section": "transport", "required": true},
  {"key": "arrival_on", "type": "date", "label": "Expected arrival", "section": "transport", "required": false, "shown_when": "stage_details_required", "for_market": "export"},
  {"key": "destination", "type": "text", "label": "Destination", "section": "transport", "required": true},
  {"key": "invoice_no", "type": "text", "label": "Invoice number", "section": "papers", "required": false, "shown_when": "stage_details_required", "required_when": "stage_details_required"},
  {"key": "lr_no", "type": "text", "label": "LR number (lorry receipt)", "section": "papers", "required": false, "shown_when": "stage_details_required", "required_when": "stage_details_required", "for_market": "domestic"},
  {"key": "eway_bill_no", "type": "text", "label": "E-way bill number (when required)", "section": "papers", "required": false, "shown_when": "stage_details_required", "for_market": "domestic"},
  {"key": "shipping_bill_no", "type": "text", "label": "Shipping bill number", "section": "papers", "required": false, "shown_when": "stage_details_required", "required_when": "stage_details_required", "for_market": "export"},
  {"key": "bl_no", "type": "text", "label": "Bill of lading number (may come later)", "section": "papers", "required": false, "shown_when": "stage_details_required", "for_market": "export"},
  {"key": "loading_photo", "type": "attachment", "label": "Loading photo (the seal or the vehicle)", "section": "documents", "required": false, "label_as": "loading_photo"},
  {"key": "documents", "type": "attachment", "label": "Documents (photo or PDF)", "accept": "document", "section": "documents", "required": false}
]'::jsonb
 where stage_type = 'shipment';

-- Migration 55 (C3, Veda 16 Oct 2026): the Warehouse stage and the domestic order's form. A database whose stage types do
-- not have 'warehouse' yet (before migration 55a: the upgrade path) is left as it is; migration 55 does the same there.
do $seed55$ begin
  if exists (select 1 from pg_enum e join pg_type t on t.oid = e.enumtypid where t.typname = 'stage_type' and e.enumlabel = 'warehouse')
     and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'stage_definitions' and column_name = 'physical_checks') then
    execute $w55$
-- ---------------------------------------------------------------------------------------------------------------------
-- The Warehouse stage (stage_definitions) and the domestic order's form (Veda, 16 Oct)
-- ---------------------------------------------------------------------------------------------------------------------
insert into public.stage_definitions
  (stage_type, code, label, is_first, is_gate, splits_forward, aggregates, allows_exceed_input, yield_alarm, is_processing, sort_order, form_schema, handoff_checks, physical_checks)
values ('warehouse', 'WH', 'Warehouse', false, false, false, false, false, false, false, 35,
 '[{"key": "declared_kg", "type": "number", "unit": "kg", "label": "Sent (what the lot holds)", "section": "arrival", "required": true},
   {"key": "received_kg", "type": "number", "unit": "kg", "label": "Received (weighed here)", "section": "arrival", "required": true},
   {"key": "discrepancy_reason", "type": "text", "label": "Why the weights differ (when they do)", "section": "arrival", "required": false},
   {"key": "condition", "type": "select", "label": "Condition on arrival", "options": ["good", "damp", "pest", "mixed"], "section": "arrival", "required": true},
   {"key": "bags_in", "type": "integer", "label": "Bags in", "section": "arrival", "required": true},
   {"key": "location", "type": "text", "label": "Warehouse or location", "section": "stored", "required": true},
   {"key": "stack", "type": "text", "label": "Stack or row", "section": "stored", "required": false},
   {"key": "photo", "type": "attachment", "label": "Photo of the stack (optional)", "section": "stored", "required": false}]'::jsonb,
 '["Received weight recorded; any difference explained", "Location and stack recorded", "Bags counted in"]'::jsonb,
 '["Bags counted out of the warehouse", "The grain looks and smells sound (no mould, no insects)"]'::jsonb)
on conflict (stage_type) do update set
  code = excluded.code, label = excluded.label, is_first = excluded.is_first, is_gate = excluded.is_gate,
  splits_forward = excluded.splits_forward, aggregates = excluded.aggregates, allows_exceed_input = excluded.allows_exceed_input,
  yield_alarm = excluded.yield_alarm, is_processing = excluded.is_processing, sort_order = excluded.sort_order,
  form_schema = excluded.form_schema, handoff_checks = excluded.handoff_checks, physical_checks = excluded.physical_checks;

-- A domestic order does not show the export fields: the market's profile, the destination and the Incoterms show only
-- when the market chosen is export ("shown_if"; display only, the save asks them for export as before).
update public.stage_definitions set form_schema = (
  select jsonb_agg(case when x->>'key' in ('market_code', 'destination_country', 'incoterms')
                        then x || '{"shown_if": {"market": "export"}}'::jsonb else x end order by n)
    from jsonb_array_elements(form_schema) with ordinality as e(x, n))
 where stage_type = 'commercial';

    $w55$;
  end if;
end $seed55$;

-- Migration 56: an export sale asks its market's profile and its destination; the form now says so ("required", shown
-- only for export). The same change as the migration's, for a database seeded after it. A form that does not yet show
-- them only for export (before migration 55) is left as it is.
update public.stage_definitions d
   set form_schema = (select jsonb_agg(case when f->>'key' in ('market_code', 'destination_country') then f || '{"required": true}'::jsonb else f end
                                       order by n)
                        from jsonb_array_elements(d.form_schema) with ordinality as x(f, n))
 where d.stage_type = 'commercial' and exists (select 1 from jsonb_array_elements(d.form_schema) f where f->>'key' = 'market_code' and f ? 'shown_if');

-- Migration 66 (Phase 2, Part E): "Procured through" on the procurement form, after "Where" (the same edit as the
-- migration, so a database built from nothing has it): one of the scope's sourcing partners, pre-filled.
update public.stage_definitions d
   set form_schema = (select jsonb_agg(f order by n) from (
          select f, n::numeric as n from jsonb_array_elements(d.form_schema) with ordinality as x(f, n)
          union all
          select '{"key": "procured_through", "type": "partner", "label": "Procured through", "section": "where", "required": false}'::jsonb,
                 (select n + 0.5 from jsonb_array_elements(d.form_schema) with ordinality as y(g, n) where g->>'key' = 'collection_point_id')) z)
 where d.stage_type = 'procurement'
   and exists (select 1 from jsonb_array_elements(d.form_schema) f where f->>'key' = 'collection_point_id')
   and not exists (select 1 from jsonb_array_elements(d.form_schema) f where f->>'key' = 'procured_through');
