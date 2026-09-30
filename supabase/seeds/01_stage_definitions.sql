-- GrainVeda MVP · seed: stage_definitions — the single stage registry (PRD §5.4 flags, §7 physics, F1)
-- form_schema: fields the generic 8-step component renders at step 4. handoff_checks: tick-list written at step 8.
-- Idempotent.

insert into public.stage_definitions
  (stage_type, code, label, is_first, is_gate, splits_forward, aggregates, allows_exceed_input, yield_alarm, is_processing, sort_order, form_schema, handoff_checks)
values
('procurement', 'P', 'Procurement (farm-gate)', true, false, false, false, false, false, false, 10,
 '[{"key":"farmer_id","label":"Farmer","type":"farmer","required":true,"column":true},
   {"key":"gross_kg","label":"Gross weight","unit":"kg","type":"number","required":true},
   {"key":"bags","label":"Bags","type":"integer","required":true},
   {"key":"tare_kg_per_bag","label":"Tare per bag","unit":"kg","type":"number","required":true},
   {"key":"moisture_pct","label":"Moisture (3 readings)","unit":"%","type":"number[3]","required":true},
   {"key":"photo","label":"Photo evidence","type":"attachment","required":false}]',
 '["Farmer is active and named","Gross, bags and tare recorded","Three moisture readings recorded","Net quantity reviewed"]'),

('lot_inward', 'LI', 'Lot Inward (pre-aggregated lot)', true, false, false, false, false, false, false, 20,
 '[{"key":"declared_kg","label":"Declared quantity","unit":"kg","type":"number","required":true},
   {"key":"weighed_kg","label":"Actual weighed","unit":"kg","type":"number","required":true},
   {"key":"source_type","label":"Source type","type":"select","options":["farmer_group","fpo","trader","own_farm"],"required":true},
   {"key":"source_name","label":"Source name","type":"text","required":true},
   {"key":"crop_declared","label":"Crop declared","type":"text","required":true},
   {"key":"moisture_pct","label":"Moisture baseline","unit":"%","type":"number","required":true},
   {"key":"condition","label":"Condition","type":"text","required":false}]',
 '["Weighed quantity recorded","Source declared","Crop declared","Moisture baseline recorded","Date recorded"]'),

('village_batch', 'VB', 'Village Batch (aggregate farmer lots)', false, false, false, true, false, false, false, 30,
 '[{"key":"source_footprint_ids","label":"Farmer lots in this batch","type":"footprint[]","required":true,"sets_prev":true},
   {"key":"village","label":"Village","type":"text","required":true}]',
 '["All source lots verified","Batch total equals sum of sources","Village named"]'),

('milling', 'M', 'Milling', false, false, false, false, false, true, true, 40,
 '[{"key":"input_kg","label":"Paddy in","unit":"kg","type":"number","required":true},
   {"key":"rice_kg","label":"Rice out","unit":"kg","type":"number","required":true},
   {"key":"bran_kg","label":"Bran","unit":"kg","type":"number","required":true},
   {"key":"loss_kg","label":"Loss","unit":"kg","type":"number","required":true}]',
 '["Input = rice + bran + loss","Yield reviewed","Rice quantity forwarded"]'),

('sorting', 'S', 'Sorting', false, false, false, false, false, false, true, 50,
 '[{"key":"input_kg","label":"Input","unit":"kg","type":"number","required":true},
   {"key":"reject_kg","label":"Reject","unit":"kg","type":"number","required":true},
   {"key":"reject_reasons","label":"Reject reasons","type":"breakdown","required":false},
   {"key":"loss_kg","label":"Loss","unit":"kg","type":"number","required":true}]',
 '["Clean output derived = input - reject - loss","Reject reasons recorded","Clean quantity forwarded"]'),

('grading', 'G', 'Grading', false, false, true, false, false, false, true, 60,
 '[{"key":"input_kg","label":"Input","unit":"kg","type":"number","required":true},
   {"key":"grade_a_kg","label":"Grade A","unit":"kg","type":"number","required":true},
   {"key":"grade_b_kg","label":"Grade B","unit":"kg","type":"number","required":true},
   {"key":"grade_c_kg","label":"Grade C","unit":"kg","type":"number","required":true},
   {"key":"reject_kg","label":"Reject","unit":"kg","type":"number","required":true},
   {"key":"loss_kg","label":"Loss","unit":"kg","type":"number","required":true},
   {"key":"split_into_grades","label":"Split into grade lots","type":"boolean","required":false,"column":true}]',
 '["A + B + C + reject + loss = input","Split decision recorded","Grade quantities forwarded"]'),

('drying', 'D', 'Drying', false, false, false, false, false, false, true, 70,
 '[{"key":"input_kg","label":"Input","unit":"kg","type":"number","required":true},
   {"key":"moisture_in_pct","label":"Moisture in","unit":"%","type":"number","required":true},
   {"key":"moisture_out_pct","label":"Moisture out","unit":"%","type":"number","required":true},
   {"key":"output_kg","label":"Output","unit":"kg","type":"number","required":true}]',
 '["Moisture in and out recorded","Water removed reconciled","Output forwarded"]'),

('popping', 'PP', 'Popping (makhana)', false, false, false, false, false, false, true, 80,
 '[{"key":"input_kg","label":"Input","unit":"kg","type":"number","required":true},
   {"key":"output_kg","label":"Output","unit":"kg","type":"number","required":true},
   {"key":"pop_rate_pct","label":"Pop rate","unit":"%","type":"number","required":true}]',
 '["Pop rate recorded","Output forwarded"]'),

('cleaning', 'C', 'Cleaning', false, false, false, false, false, false, true, 90,
 '[{"key":"input_kg","label":"Input","unit":"kg","type":"number","required":true},
   {"key":"foreign_matter_kg","label":"Foreign matter removed","unit":"kg","type":"number","required":true},
   {"key":"loss_kg","label":"Loss","unit":"kg","type":"number","required":true}]',
 '["Foreign matter recorded separately from loss","Output forwarded"]'),

('blanching', 'B', 'Blanching', false, false, false, false, true, false, true, 100,
 '[{"key":"input_kg","label":"Input","unit":"kg","type":"number","required":true},
   {"key":"output_kg","label":"Output","unit":"kg","type":"number","required":true}]',
 '["Water uptake recorded","Output forwarded"]'),

('cold_storage', 'CS', 'Cold Storage', false, false, false, false, false, false, true, 110,
 '[{"key":"stored_kg","label":"Quantity stored","unit":"kg","type":"number","required":true},
   {"key":"retrieved_kg","label":"Quantity retrieved","unit":"kg","type":"number","required":true},
   {"key":"stored_on","label":"Stored on","type":"date","required":true},
   {"key":"retrieved_on","label":"Retrieved on","type":"date","required":true}]',
 '["Retrieved quantity recorded","Spoilage reconciled","Retrieved quantity forwarded"]'),

('packing', 'PK', 'Packing', false, false, false, false, false, false, true, 120,
 '[{"key":"input_kg","label":"Input","unit":"kg","type":"number","required":true},
   {"key":"packets","label":"Packets","type":"packets[]","required":true},
   {"key":"wastage_kg","label":"Wastage","unit":"kg","type":"number","required":true},
   {"key":"batch_code","label":"Batch code (QR link)","type":"text","required":true}]',
 '["Batch code assigned","Σ packets + wastage = input","Packed quantity forwarded"]'),

('qc', 'QC', 'Quality Control', false, false, false, false, false, false, false, 130,
 '[{"key":"qty_kg","label":"Lot quantity","unit":"kg","type":"number","required":true},
   {"key":"sample_qty_kg","label":"Sample drawn","unit":"kg","type":"number","required":true},
   {"key":"readings","label":"Readings per crop parameter","type":"readings","required":true},
   {"key":"lab_ref","label":"Lab reference","type":"text","required":false}]',
 '["All crop parameters read","Both verdicts derived","Sample deducted; forwarding quantity reviewed"]'),

('commercial', 'CM', 'Commercial Clearance', false, false, true, false, false, false, false, 140,
 '[{"key":"buyer","label":"Buyer","type":"text","required":true},
   {"key":"market","label":"Market","type":"select","options":["domestic","export"],"required":true},
   {"key":"qty_kg","label":"Quantity to this buyer","unit":"kg","type":"number","required":true},
   {"key":"price_per_kg","label":"Price","unit":"INR/kg","type":"number","required":false}]',
 '["Buyer and market recorded","Export sale backed by export PASS or override","Allocation within available"]'),

('shipment', 'SH', 'Shipment', false, false, false, false, false, false, false, 150,
 '[{"key":"shipped_kg","label":"Shipped","unit":"kg","type":"number","required":true},
   {"key":"transit_loss_kg","label":"Transit loss","unit":"kg","type":"number","required":false},
   {"key":"vehicle_or_container","label":"Vehicle / container","type":"text","required":true},
   {"key":"dispatch_date","label":"Dispatch date","type":"date","required":true},
   {"key":"destination","label":"Destination","type":"text","required":true}]',
 '["Dispatch recorded","Transit loss carried to forwarding quantity","Documents attached"]'),

('qr_activation', 'QR', 'QR Activation (seal)', false, true, false, false, false, false, false, 160,
 '[]',
 '["Every stage behind verified","QC verdict present","No open flags","Final quantity recorded"]')
on conflict (stage_type) do update set
  code = excluded.code, label = excluded.label, is_first = excluded.is_first, is_gate = excluded.is_gate,
  splits_forward = excluded.splits_forward, aggregates = excluded.aggregates, allows_exceed_input = excluded.allows_exceed_input,
  yield_alarm = excluded.yield_alarm, is_processing = excluded.is_processing, sort_order = excluded.sort_order,
  form_schema = excluded.form_schema, handoff_checks = excluded.handoff_checks;
