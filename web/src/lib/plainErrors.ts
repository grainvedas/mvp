// Plain words for the database's refusals (migration 48, brief A4/G13: "plain error messages, never DB text"; every
// message in English and Hindi). The database's own sentence is matched here and replaced by a dictionary key
// (`err.*` in i18n.en.ts and i18n.hi.ts), with the parts that matter (a code, a quantity, a date) carried over. A message
// that is not in the list and reads like the database's inside words (a column name, a constraint, a type) becomes
// the general "could not be saved" with a reference; a plain sentence the database wrote for people is kept.
export interface PlainRule { re: RegExp; key: string; vars?: string[] }

const STAGE = '([a-z_]+)';
export const PLAIN_RULES: PlainRule[] = [
  // the farmer and good farming practice
  { re: /good farming practice not complete for this farmer \((.*?)\): (.*)$/i, key: 'err.gap', vars: ['crop', 'items'] },
  { re: /procurement requires an active farmer of this client/i, key: 'err.farmer_active' },
  { re: /procurement requires farmer_id/i, key: 'err.farmer_required' },
  // quantities and the lot it comes from
  { re: /qty_in ([\d.]+) exceeds available ([\d.]+) on predecessor/i, key: 'err.qty_over', vars: ['qin', 'avail'] },
  { re: /qty_in exceeds available on predecessor/i, key: 'err.qty_over_plain' },
  { re: /predecessor lot is closed/i, key: 'err.prev_closed' },
  { re: /predecessor must be verified before the next stage builds on it/i, key: 'err.prev_unverified' },
  { re: /predecessor must be in the same scope/i, key: 'err.prev_scope' },
  { re: new RegExp(`predecessor of ${STAGE} must be ${STAGE} \\(got ${STAGE}\\)`, 'i'), key: 'err.prev_stage', vars: ['stage', 'expected', 'got'] },
  { re: new RegExp(`predecessor is ${STAGE} and cannot be built on`, 'i'), key: 'err.prev_status', vars: ['status'] },
  { re: /prev_footprint_id is required for stage/i, key: 'err.prev_required' },
  { re: /first stage has no predecessor/i, key: 'err.first_no_prev' },
  { re: /a split grading run is not a source; use its grade lots/i, key: 'err.split_source' },
  { re: /grade lots are created by the grading run/i, key: 'err.grade_lots_auto' },
  { re: /a grade (\w) lot carries exactly what the run graded as \w \(([\d.]+) kg\), not ([\d.]+) kg/i, key: 'err.grade_qty', vars: ['grade', 'expected', 'got'] },
  { re: /this run already has a grade (\w) lot/i, key: 'err.grade_dup', vars: ['grade'] },
  { re: /a grade lot must be coupled to a grading run that was split/i, key: 'err.grade_coupled' },
  { re: /only a grading run can be split into grade lots/i, key: 'err.split_only_grading' },
  // what was entered
  { re: /net weight must be positive/i, key: 'err.net_positive' },
  { re: /moisture must be below 100/i, key: 'err.moisture' },
  { re: /moisture_pct must be an array of 3 readings/i, key: 'err.moisture3' },
  { re: /source_type and source_name are required/i, key: 'err.source_required' },
  { re: /weighed_kg must be positive/i, key: 'err.weighed_positive' },
  { re: /milling: input \((.*?)\) must equal rice \+ bran \+ loss \((.*?)\)/i, key: 'err.milling_balance', vars: ['in', 'sum'] },
  { re: /grading: A \+ B \+ C \+ reject \+ loss \((.*?)\) must equal input \((.*?)\)/i, key: 'err.grading_balance', vars: ['sum', 'in'] },
  { re: /cleaning: foreign matter \+ loss exceed input/i, key: 'err.cleaning' },
  { re: /sorting: reject \+ loss exceed input/i, key: 'err.sorting' },
  { re: /packing: batch_code is mandatory/i, key: 'err.batch_code' },
  { re: /packing: payload\.packets/i, key: 'err.packets_required' },
  { re: /packing: Σ packets \((.*?)\) \+ wastage \((.*?)\) must equal input \((.*?)\)/i, key: 'err.packing_balance', vars: ['packs', 'waste', 'in'] },
  { re: /(\w+) ?: output \((.*?)\) exceeds input \((.*?)\)/i, key: 'err.out_over_in', vars: ['stage', 'out', 'in'] },
  { re: /qc: payload\.readings/i, key: 'err.readings_required' },
  { re: /qc: sample must be smaller than the lot/i, key: 'err.sample_small' },
  { re: /commercial: buyer is required/i, key: 'err.buyer_required' },
  { re: /commercial: export sale requires export PASS/i, key: 'err.export_needs_pass' },
  { re: /commercial: market must be domestic or export/i, key: 'err.market' },
  { re: /shipment: transit loss exceeds shipped quantity/i, key: 'err.transit_loss' },
  { re: /qr_activation: final quantity must be recorded and positive/i, key: 'err.qr_qty' },
  { re: /qr_activation needs a predecessor/i, key: 'err.qr_prev' },
  { re: /village_batch (requires|needs) payload\.source_footprint_ids/i, key: 'err.batch_sources' },
  { re: /village_batch source (\S+) is not a verified, open predecessor lot in this scope/i, key: 'err.batch_source_bad', vars: ['code'] },
  { re: /village_batch prev_footprint_id must be the first source/i, key: 'err.batch_first' },
  // who may do it
  { re: new RegExp(`may not create at stage ${STAGE} in this scope`, 'i'), key: 'err.not_your_stage', vars: ['stage'] },
  { re: /may not verify a \w+ record: verification is by the receiving stage/i, key: 'err.verify_receiving' },
  { re: /may not seal: not the assigned QR operator/i, key: 'err.seal_not_yours' },
  { re: /^scope is not active/i, key: 'err.scope_inactive' },
  { re: new RegExp(`stage ${STAGE} is not in this scope`, 'i'), key: 'err.stage_not_in_scope', vars: ['stage'] },
  // corrections, withdrawals, seals
  { re: /later records are built on this one \((.*?)\); withdraw those first/i, key: 'err.later_records', vars: ['codes'] },
  { re: /a sealed lot cannot be withdrawn/i, key: 'err.sealed_no_withdraw' },
  { re: /this record cannot be corrected after saving/i, key: 'err.no_correct_after' },
  { re: /only the person who recorded this lot can correct it/i, key: 'err.only_sender_corrects' },
  { re: /quantities, codes, dates and lot status are set by the server/i, key: 'err.server_fields' },
  { re: /payload\/quantities cannot change in the same act as verification/i, key: 'err.verify_no_change' },
  { re: /a \w+ footprint is immutable/i, key: 'err.immutable' },
  { re: /is not a valid transition/i, key: 'err.transition' },
  { re: /footprint not found or not pending/i, key: 'err.not_pending' },
  { re: /supersedes_id must name a withdrawn record/i, key: 'err.supersedes' },
  { re: /that withdrawn record already has a replacement/i, key: 'err.replacement_exists' },
  { re: /gate: open flag on batch source (\S+)/i, key: 'err.gate_flag_batch', vars: ['code'] },
  { re: new RegExp(`gate: open flag on ${STAGE} (\\S+)`, 'i'), key: 'err.gate_flag', vars: ['stage', 'code'] },
  // migration 48: return, the manager's reason, the date it happened, the short code
  { re: /a manager records at a stage he does not hold only with a written reason/i, key: 'err.manager_reason' },
  { re: /a manager verifies at a stage he does not hold only with a written reason/i, key: 'err.manager_verify_reason' },
  { re: /this record was returned to its sender/i, key: 'err.returned' },
  { re: /say why it is returned/i, key: 'err.return_reason' },
  { re: /it is returned already/i, key: 'err.returned_already' },
  { re: /you recorded it: correct it yourself/i, key: 'err.return_own' },
  { re: /only the next stage \(or a manager of this scope\) returns a record/i, key: 'err.return_who' },
  { re: /only a record waiting for verification is returned \(this one is (\w+)\)/i, key: 'err.return_status', vars: ['status'] },
  { re: /a QR record is not returned/i, key: 'err.return_qr' },
  { re: /write the condition/i, key: 'err.condition_text' },
  { re: /the date it happened \((.*?)\) cannot be after the day it is recorded \((.*?)\)/i, key: 'err.on_future', vars: ['on', 'rec'] },
  { re: /the date it happened \((.*?)\) is more than 31 days before/i, key: 'err.on_old', vars: ['on'] },
  { re: /it cannot have happened \((.*?)\) before the lot it comes from \((\S+) on (.*?)\)/i, key: 'err.on_before_prev', vars: ['on', 'code', 'prev'] },
  { re: /say on which date it happened/i, key: 'err.on_required' },
  { re: /only a manager can withdraw a record/i, key: 'err.withdraw_who' },
  { re: /^a reason is required/i, key: 'err.reason_required' },
  { re: /the short code (\w+) is in this scope's record numbers already/i, key: 'err.short_in_use', vars: ['code'] },
  { re: /another scope of this client, crop and season has the short code (\w+)/i, key: 'err.short_taken', vars: ['code'] },
  { re: /scopes_short_code_shape/i, key: 'err.short_shape' },
  { re: /footprints_manager_reason_shape/i, key: 'err.manager_reason_len' },
  // migration 49: the warnings a record carries (saved, but worth a look), in plain words too
  { re: /outturn ([\d.]+) % is above the crop's ceiling of ([\d.]+) %/i, key: 'warn.outturn_ceiling', vars: ['pct', 'max'] },
  { re: /outturn ([\d.]+) % is outside the usual range of this crop \(([\d.]+) to ([\d.]+) %, from (\d+) verified runs\)/i, key: 'warn.outturn_range', vars: ['pct', 'lo', 'hi', 'n'] },
  { re: /^yield below threshold$/i, key: 'warn.yield_below' },
  { re: /declared vs weighed variance exceeds tolerance/i, key: 'warn.variance' },
  { re: /grain loss beyond moisture removal/i, key: 'warn.grain_loss' },
  { re: /output exceeds dry-matter expectation/i, key: 'warn.dry_matter' },
  { re: /pop rate below threshold/i, key: 'warn.pop_rate' },
  { re: /good farming practice not filled: (.*)$/i, key: 'warn.practice_optional', vars: ['items'] },
  { re: /above the expected yield: ([\d.]+) of ([\d.]+) kg this season \(([\d.]+) acres of GI land\)/i, key: 'warn.expected_yield', vars: ['got', 'max', 'acres'] },
  { re: /outside the harvest window \((.*?)\)/i, key: 'warn.harvest_window', vars: ['months'] },
  { re: /phone clock not plausible: server time used/i, key: 'warn.clock' },
  { re: /tick what you checked with your own eyes: (.*)$/i, key: 'err.tick_checks', vars: ['items'] },
  // migration 50: packs, proof and blocks
  { re: /qc: the lab, the report number and the report date are required/i, key: 'err.lab_report_fields' },
  { re: /qc: the report date is a date/i, key: 'err.not_date' },
  { re: /qc: the report date \((.*?)\) is in the future/i, key: 'err.report_future', vars: ['date'] },
  { re: /qc: the report date \((.*?)\) is before the lot it tests \((\S+) on (.*?)\)/i, key: 'err.report_before_lot', vars: ['date', 'code', 'on'] },
  { re: /qc: report (.*?) of this lab is on (\S+) already/i, key: 'err.report_taken', vars: ['no', 'code'] },
  { re: /qc: the lab report file is attached before the lab record is verified/i, key: 'err.report_file' },
  { re: /GI and non-GI lots are not batched together \((.*)\)/i, key: 'err.gi_mix', vars: ['lots'] },
  { re: /an export release needs the client's written acceptance attached/i, key: 'err.acceptance' },
  { re: /these labels were printed before: say why/i, key: 'err.reprint_reason' },
  { re: /labels are printed at Packing/i, key: 'err.labels_who' },
  { re: /say why the pack is void/i, key: 'err.void_reason' },
  { re: /this pack is void already/i, key: 'err.void_already' },
  { re: /a pack is voided at Packing/i, key: 'err.void_who' },
  { re: /at most 20000 packs in one packing record \((\d+) given\)/i, key: 'err.packs_max', vars: ['n'] },
  { re: /a recalled release stays recalled/i, key: 'err.recall_final' },
  { re: /the release is (.*?) already/i, key: 'err.release_same', vars: ['status'] },
  { re: /changes a release's status/i, key: 'err.release_who' },
  { re: /^say why \(at least 10 characters\)/i, key: 'err.why10' },
  { re: /what arrived is between 0 and the ([\d.]+) kg shipped/i, key: 'err.delivery_kg', vars: ['kg'] },
  { re: /the delivery date is between the dispatch and today/i, key: 'err.delivery_date' },
  { re: /for export, the proof of delivery is attached first/i, key: 'err.pod' },
  { re: /the delivery is confirmed already/i, key: 'err.delivered_already' },
  { re: /the delivery is confirmed at Shipment/i, key: 'err.delivery_who' },
  { re: /unknown kind of document/i, key: 'err.doc_kind' },
  { re: /whether the lab report is asked is set before the scope is activated/i, key: 'err.qc_report_frozen' },
  { re: /^this shipment is (\w+)/i, key: 'err.shipment_status', vars: ['status'] },
  // migration 51: the set-up lists, the crop's GI area and photo, the farmer's place and GPS
  { re: /places are added by the State Manager, the Client Manager or Procurement of this state/i, key: 'err.place_who' },
  { re: /the district (.*?) is not on the list of this state/i, key: 'err.district_unlisted', vars: ['name'] },
  { re: /^name the block/i, key: 'err.block_needed' },
  { re: /the State Manager of the crop's state keeps its documents/i, key: 'err.crop_docs_who' },
  { re: /the file is not filed under this crop/i, key: 'err.file_crop' },
  { re: /the State Manager of the crop's state keeps its market profiles/i, key: 'err.profile_who' },
  { re: /market profile: (.*?) is not in the parameter library/i, key: 'err.prof_lib', vars: ['param'] },
  { re: /market profile: (.*?) is listed twice/i, key: 'err.prof_twice', vars: ['param'] },
  { re: /market profile: (.*?) needs an operator and a number limit/i, key: 'err.prof_limit', vars: ['param'] },
  { re: /market profile: (.*?) needs the grades that pass/i, key: 'err.prof_grades', vars: ['param'] },
  { re: /market profile: (.*?) needs the answer that passes/i, key: 'err.prof_yesno', vars: ['param'] },
  { re: /market profile: the parameters are a list/i, key: 'err.prof_list' },
  { re: /market profile: list the parameters it tests/i, key: 'err.prof_empty' },
  { re: /market profile: attach the document the limits come from/i, key: 'err.prof_source' },
  { re: /^market profile not found/i, key: 'err.prof_gone' },
  { re: /there is a draft of this profile already/i, key: 'err.prof_draft' },
  { re: /only a draft is activated \(this one is (\w+)\)/i, key: 'err.prof_not_draft', vars: ['status'] },
  { re: /a crop that is not a GI crop \(no GI registration number\) has no GI area/i, key: 'err.not_gi_area' },
  { re: /the reference photo is a photo filed under this crop/i, key: 'err.ref_photo' },
  { re: /add the farm's GPS location before the farmer is verified/i, key: 'err.farm_gps' },
  { re: /the district (.*?) is not on the list of the farmer's state/i, key: 'err.farmer_district', vars: ['name'] },
  { re: /^no access to this state/i, key: 'err.state_access' },
  { re: /"(farmers_gps_shape|collection_points_check|mills_check)"/i, key: 'err.gps_india' },
  { re: /"buyers_check"/i, key: 'err.buyer_domestic' },
  { re: /"labs_check"/i, key: 'err.lab_accreditation' },
  { re: /"(packing_units|buyers)_fssai_licence_check"/i, key: 'err.fssai' },
  { re: /"buyers_gstin_check"/i, key: 'err.gstin' },
  { re: /"buyers_country_check"/i, key: 'err.country' },
  { re: /"crops_shelf_life_by_material_shape"/i, key: 'err.shelf_life' },
  { re: /"(places_unique|collection_points_name|mills_name|packing_units_name|buyers_name|pack_skus_unique|labs_name)"/i, key: 'err.list_dup' },
  // the database's inside words, in general
  { re: /violates not-null constraint|null value in column/i, key: 'err.missing_value' },
  { re: /invalid input syntax for type (numeric|integer|bigint|real|double precision)/i, key: 'err.not_number' },
  { re: /invalid input syntax for type (date|timestamp)/i, key: 'err.not_date' },
  { re: /violates foreign key constraint/i, key: 'err.missing_link' },
  { re: /value too long for type/i, key: 'err.too_long' },
  { re: /numeric field overflow|out of range for type/i, key: 'err.too_big' },
  { re: /canceling statement due to statement timeout/i, key: 'err.timeout' },
];

/** Reads like the database's inside words: a snake_case name, a constraint, a relation, a type, an SQL word. */
export function looksTechnical(raw: string): boolean {
  return /\b[a-z]+_[a-z0-9_]+\b|\bconstraint\b|\brelation "|\bcolumn "|\bsyntax\b|\boperator does not exist\b|\bjsonb?\b|\buuid\b|\bSQLSTATE\b|\bPGRST\d|\bfunction app\.|\bpayload\b|\bfootprint\b|\bnull value\b|\bdeadlock\b/i.test(raw);
}

/** The plain words for a database message, or null when it is not in the list. */
export function plainWords(raw: string, t: (k: string, v?: Record<string, string | number>, f?: string) => string): string | null {
  const stageWord = (s: string) => t(`stage.${s}`, undefined, s.replace(/_/g, ' '));
  for (const r of PLAIN_RULES) {
    const m = r.re.exec(raw);
    if (!m) continue;
    const vars: Record<string, string> = {};
    (r.vars ?? []).forEach((name, i) => {
      const v = m[i + 1] ?? '';
      vars[name] = ['stage', 'expected', 'got'].includes(name) && /^[a-z_]+$/.test(v) ? stageWord(v) : v;
    });
    return t(r.key, vars);
  }
  return null;
}
