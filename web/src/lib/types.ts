// Shapes returned by the database (migrations 1–16). Kept by hand; `supabase gen types` can replace them later.
export type Role = 'admin' | 'state_manager' | 'client_manager' | 'client_view' | 'operator';
export type StageType =
  | 'procurement' | 'lot_inward' | 'village_batch' | 'milling' | 'sorting' | 'grading' | 'drying' | 'popping'
  | 'cleaning' | 'blanching' | 'cold_storage' | 'packing' | 'qc' | 'commercial' | 'shipment' | 'qr_activation';
export type FootprintStatus = 'pending' | 'verified' | 'closed' | 'superseded' | 'legacy';

export interface FieldDef {
  key: string;
  label: string;
  type: string;            // number | integer | number[3] | text | select | date | boolean | attachment | readings | farmer | …
  unit?: string;
  required?: boolean;
  options?: string[];
  column?: boolean;        // stored in a footprints column (e.g. farmer_id), not in payload
  sets_prev?: boolean;     // footprint[] whose first lot becomes prev_footprint_id (aggregating stages)
  gate?: 'market_verdict'; // select: only the markets the source lot may be sold to are offered (app.lot_markets)
  accept?: 'document';     // attachment: any photo or PDF from the phone (default: take a photo with the camera)
  section?: string;        // heading the field stands under on the form (section.<key> in the dictionaries); display only
  /** migration 50: required when the scope's setting of this name is on (the lab report: qc_report_required) */
  required_when?: string;
  /** migration 50: an attachment is registered under this label (lab_report, acceptance, pod, loading_photo, document) */
  label_as?: string;
  /** migration 52: on the form only where the scope's setting of this name is on (price and payment: record_price) */
  shown_when?: string;
  /** migration 53: the field is NOT on the form where the scope's setting of this name is on */
  hidden_when?: string;
}

export interface StageDefinition {
  stage_type: StageType;
  code: string;
  label: string;
  is_first: boolean;
  is_gate: boolean;
  splits_forward: boolean;
  aggregates: boolean;
  allows_exceed_input: boolean;
  yield_alarm: boolean;
  is_processing: boolean;
  form_schema: FieldDef[];
  handoff_checks: string[];
  sort_order: number;
}

export interface QualityParam {
  param: string;
  label: string;
  unit?: string;
  /** migration 42: a number (the default, also when absent), a grade from a list, or yes/no */
  type?: 'number' | 'grade' | 'yesno';
  operator: '<=' | '>=' | 'between';
  domestic_limit: number | [number, number];
  export_limit: number | [number, number];
  /** grade: the grades a reading may be */
  options?: string[];
  /** grade: the passing grades; yes/no: the passing answer */
  domestic_pass?: string[] | boolean;
  export_pass?: string[] | boolean;
}

export interface StageForm {
  scope: {
    id: string; season_code: string; geography: string; status: string; chain: StageType[];
    tolerances: Record<string, number>;
    /** migration 48 (E4): the scope's short code, in its record numbers */
    short_code?: string | null;
    /** migration 50 (C5): the lab record names the lab, the report number and date, and attaches the report */
    qc_report_required?: boolean;
    /** migration 52 (C1): Procurement records the price and the payment; asks where, the GPS and who delivered */
    record_price?: boolean; procurement_details_required?: boolean;
    /** migration 53 (C4–C6): Milling, QC and Packing ask the mill, sample, lab, packing unit and packs from the lists */
    stage_details_required?: boolean; market_codes?: string[];
    client: { id: string; name: string; code: string };
    crop: { id: string; name: string; code: string; gi_tag: string | null; primary_unit: string;
      /** migration 52: the crop's thresholds (moisture_spread_pct, batch_loss_pct …) */ thresholds?: Record<string, number> | null };
  };
  stage: StageDefinition;
  position: number;
  prev_stage: { stage_type: StageType; label: string; handoff_checks: string[]; /** migration 49: what the receiver ticks */ physical_checks?: string[] } | null;
  next_stage: { stage_type: StageType; label: string } | null;
  quality_params: QualityParam[];
  can_create: boolean;
  can_verify_incoming: boolean;
  /** migration 48 (A10): the reader records here as a manager (holds no slot): a reason is asked */
  records_as_manager?: boolean;
  /** migration 48 (A10): the reader verifies here as a manager: a reason is asked */
  verifies_as_manager?: boolean;
}

export interface Footprint {
  id: string;
  footprint_code: string;
  client_id: string;
  scope_id: string;
  stage_type: StageType;
  prev_footprint_id: string | null;
  farmer_id: string | null;
  qty_in: number;
  qty_out: number;
  status: FootprintStatus;
  payload: Record<string, unknown>;
  computed: Record<string, unknown>;
  warnings: string[];
  lot_closed: boolean;
  is_grade_lot: boolean;
  grade: string | null;
  split_into_grades: boolean;
  supersedes_id: string | null;
  created_by: string;
  verified_by: string | null;
  verified_at: string | null;
  created_at: string;
  /** When the operator saved it on the phone (migration 29). Absent on older servers and older records: use created_at. */
  captured_at?: string | null;
  /** migration 48 (A9): the date it happened (the person says; today by default). Absent on older records. */
  happened_on?: string | null;
  /** migration 48 (A10): why a manager recorded at a stage he does not hold */
  manager_reason?: string | null;
}

/** app.preview_verdict: what the save of a lab record would derive from these readings. */
export interface VerdictPreview {
  ok: boolean;
  domestic: 'pass' | 'fail' | 'pending';
  export: 'pass' | 'fail' | 'pending';
  judged: { param: string; value: number | string | boolean | null; domestic: string; export: string }[];
}

export interface Preview {
  ok: boolean;
  qty_in?: number;
  qty_out?: number;
  computed?: Record<string, unknown>;
  warnings?: string[];
  available_on_prev?: number | null;
  error?: string;
  code?: string;
}

export interface Slot {
  scope_id: string; stage_type: StageType; stage_label: string; scope_label: string; client_name: string;
  chain: StageType[]; scope_status: string;
}
export interface ScopeSummary {
  scope_id: string; client_id: string; client_name: string; crop_name: string; season_code: string;
  geography: string; status: string; chain: StageType[];
  /** Migration 32. manage: the person manages this scope. whole: they read all of it (managers, the client's login, an export manager). */
  state_id?: string; state_name?: string; manage?: boolean; whole?: boolean;
  /** Migration 41: the person builds this scope (its client's Client Manager): edits, activates, closes it. */
  build?: boolean;
}
// Identity layer (migrations 31–33). Two things grant access: the system role and the assignments. `role` is the
// summary the database keeps for display and the menu; no screen decides what may be DONE from it.
export type SystemRole = 'admin' | 'hr_admin' | 'hr_resource' | 'operational';
export type EmployeeStatus = 'invited' | 'onboarding' | 'active' | 'suspended' | 'offboarded';
export type EmploymentType = 'full_time' | 'intern' | 'contract' | 'consultant';
export type Lens = 'scope' | 'client' | 'state';
export type OpRole = 'operator' | 'export_manager' | 'client_account' | 'client_viewer' | 'state_supervisor';
/** What the signed-in person may open, as the database says it (never worked out in the app from the role). */
export interface Can {
  admin: boolean; hr: boolean; hr_admin: boolean; assign: boolean; state_lens: boolean;
  /** Migration 34: the admin oversees (reads everything, runs no operation); who reads the audit log; is the HR Admin seat filled. */
  oversee?: boolean; audit?: boolean; hr_seat_filled?: boolean;
  /** Migration 35: the HR Admin seats State Managers (gives the state lens). */
  state_seat?: boolean;
  /** Migration 41: a State Manager acting as one (not also a Client Manager, HR or the admin); who builds scopes (a Client Manager). */
  state_manager?: boolean; build_scope?: boolean;
}
export interface MyAssignment {
  id: string; lens: Lens; op_role: OpRole; scope_id: string | null; client_id: string | null; client_name: string | null;
  state_id: string | null; state_name: string | null; stages: StageType[]; posting: string | null; season_code: string | null;
  ends_on: string | null; label: string;
}
export interface MyContext {
  user: null | {
    id: string; role: Role; display_name: string; email: string | null; phone: string | null;
    client_id: string | null; client_name: string | null; state_ids: string[];
    /** Absent on a server before migration 32: treated as an active operational person with no extra rights. */
    system_role?: SystemRole; status?: EmployeeStatus; external?: boolean; join_date?: string | null; can?: Can;
  };
  slots: Slot[];
  scopes: ScopeSummary[];
  assignments?: MyAssignment[];
  /** The once-a-day sign-in code is switched on and today's has not been entered yet: nothing else is open. */
  needs_daily_code?: boolean;
  onboarding?: { total: number; open: number } | null;
}
export const NO_RIGHTS: Can = { admin: false, hr: false, hr_admin: false, assign: false, state_lens: false };

export interface Farmer {
  id: string; farmer_code: string | null; client_id: string; scope_ids: string[];
  status: 'draft' | 'under_review' | 'active' | 'inactive';
  name: string; guardian_name: string; village: string; district: string; phone: string; land_area_acres: number;
  extra: Record<string, unknown>; photo_consent: boolean; created_at: string;
  /** Migration 34: the farmer's state, and the Client Manager's first verification (step 1). Absent before it. */
  state_id?: string | null; reviewed_by?: string | null; reviewed_at?: string | null;
  /** Migration 43: acres under the GI crop; needed before the Farmer ID (a draft may go without). Absent before it. */
  gi_land_acres?: number | null;
  /** Migration 44: the state farmer ID (F-UP-00001) once the State Manager has verified, and the public-page consent. */
  state_farmer_id?: string | null; public_id_consent?: boolean;
  /** Migration 51 (Part B): the block, the farm's GPS, the land record and GI authorised-user numbers; whether the GPS is
   *  required before the Client Manager's verification (false for the farmers registered before). Absent before it. */
  block?: string | null; farm_lat?: number | null; farm_lng?: number | null; land_record_no?: string | null; gi_user_no?: string | null;
  location_required?: boolean;
}

export interface FootprintDetail {
  footprint: Footprint;
  stage_label: string;
  created_by_name: string | null;
  verified_by_name: string | null;
  farmer: { name: string; farmer_code: string | null; village: string; /** migration 44 */ state_farmer_code?: string | null } | null;
  prev: { id: string; footprint_code: string; stage_type: StageType } | null;
  available_kg: number;
  qc: null | { domestic_verdict: string; export_verdict: string; readings: Record<string, number>;
    judged: { param: string; value: number | string | boolean | null; domestic: string; export: string }[]; override: Record<string, unknown> | null };
  market_verdict: { domestic: string; export: string; overridden: boolean };
  seal: null | { qr_code: string; batch_codes: string[]; sealed_at: string; ledger_hash: string };
  flags: { id: string; text: string; status: string; created_at: string; raised_by_name: string | null; kind?: 'flag' | 'condition' }[];
  /** migration 48 (A1): the times it was returned to its sender */
  returns?: FootprintReturn[];
  /** migration 49: its farmers (documented proportions), GI status, sources with the kg taken, what the system checks */
  farmers?: LotFarmer[]; gi_status?: GiStatus; sources?: { id: string; code: string; stage: StageType; kg: number; how: string; from_older: boolean }[];
  system_checks?: SystemCheck[];
  can_return?: boolean;
  /** migration 50: a packing record's batch and packs; a shipment's delivery; a sealed lot's release status */
  packs?: { batch_code: string | null; packed: number; void: number; prints: number; best_before: string | null } | null;
  /** migration 53: the lab's verdict per market profile of the scope; a closed lot; the net weight check of a packing record */
  profile_verdicts?: { code: string; name: string; version: number; verdict: 'pass' | 'fail' | 'pending'; failed: string[]; missing: string[] }[];
  closure?: { floor_loss_kg: number; reason: string; closed_at: string; closed_by_name: string | null } | null;
  net_weight?: { needed: boolean; check: null | { serials: string[]; weights: Record<string, { g: number; size_g: number; allowed_short_g: number; ok: boolean }> | null;
    result: 'pass' | 'fail' | null; checked_at: string | null } } | null;
  delivery?: Delivery | null;
  release?: ReleaseStatus | null;
  attachments: { id: string; kind: string; storage_path: string; sha256: string; created_at: string; label?: string | null }[];
  ledger: { seq: number; event: string; hash: string; prev_hash: string; created_at: string; actor_name: string | null }[];
}

export type GiStatus = 'gi' | 'non_gi' | 'unknown';
export interface LotFarmer { farmer_id: string; name: string; village: string | null; district: string | null; share_pct: number; kg: number }
/** app.system_checks: one thing the data answers about a record (its words: chk.<key>) */
export interface SystemCheck { key: string; ok: boolean; vars: Record<string, string | number> }
/** app.incoming_lots: a waiting lot with what is left on it (migration 49, A3/G2) */
export type IncomingLot = Footprint & { available_kg: number; returned: boolean; maker_name: string | null; made_by_me: boolean; gi_status: GiStatus; farmer_count: number };

export interface FootprintReturn {
  id: string; reason: string; status: 'open' | 'corrected' | 'withdrawn'; returned_at: string; returned_by_name: string | null;
  resolved_at: string | null; resolved_by_name: string | null;
}

/** migration 48 (D3): what waits for the signed-in person (app.my_actions) */
export interface MyActions {
  returned: { id: string; code: string; stage: StageType; scope_id: string; scope: string; reason: string; by: string | null; at: string; in_place: boolean }[];
  to_verify: { scope_id: string; scope: string; stage: StageType; from_stage: StageType; n: number }[];
  proposals: number; farmers_to_verify: number; requirement_lines: number; flags: number; conditions: number;
  /** migration 51: verified farmers of my clients without their farm's GPS (asked to add it) */
  farmers_without_gps?: number;
}

export const MANAGER_ROLES: Role[] = ['admin', 'state_manager', 'client_manager'];
export const ROLE_RANK: Record<Role, number> = { admin: 4, state_manager: 3, client_manager: 2, client_view: 1, operator: 1 };
export const isManager = (r?: Role | null) => !!r && MANAGER_ROLES.includes(r);

export interface LotMarkets {
  has_qc: boolean; domestic: 'pass' | 'fail' | 'pending'; export: 'pass' | 'fail' | 'pending';
  overridden: boolean; export_allowed: boolean; markets: string[];
}
export interface Withdrawal { footprint_id: string; reason: string; withdrawn_by: string; withdrawn_at: string }


/** migration 50 (G9/G10, C9): a release's status; a recall shows on every pack */
export interface ReleaseStatus { status: 'active' | 'under_investigation' | 'recalled'; reason?: string | null; at?: string; by?: string | null }
/** migration 50 (G12): what arrived, recorded at delivery */
export interface Delivery { shipment_id: string; received_kg: number; transit_loss_kg: number; received_on: string; note: string | null; confirmed_by_name: string | null; confirmed_at?: string }
/** migration 50 (G9): what the QR person reads before release */
export interface ReleasePreview { ready: boolean; market: string | null; source: { code: string; stage: string; kg: number }; checks: SystemCheck[] }
/** migration 50 (G8): the labels of a packing record */
export interface LabelSheet { batch_code: string; crop: string; gi_tag: string | null; gi_status: GiStatus; season: string; geography: string; client: string; reprint: boolean;
  packs: { serial: string; size_kg: number; packed_on: string; best_before: string | null }[] }
