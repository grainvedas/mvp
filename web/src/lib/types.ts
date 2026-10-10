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
  operator: '<=' | '>=' | 'between';
  domestic_limit: number | [number, number];
  export_limit: number | [number, number];
}

export interface StageForm {
  scope: {
    id: string; season_code: string; geography: string; status: string; chain: StageType[];
    tolerances: Record<string, number>;
    client: { id: string; name: string; code: string };
    crop: { id: string; name: string; code: string; gi_tag: string | null; primary_unit: string };
  };
  stage: StageDefinition;
  position: number;
  prev_stage: { stage_type: StageType; label: string; handoff_checks: string[] } | null;
  next_stage: { stage_type: StageType; label: string } | null;
  quality_params: QualityParam[];
  can_create: boolean;
  can_verify_incoming: boolean;
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
}

/** app.preview_verdict: what the save of a lab record would derive from these readings. */
export interface VerdictPreview {
  ok: boolean;
  domestic: 'pass' | 'fail' | 'pending';
  export: 'pass' | 'fail' | 'pending';
  judged: { param: string; value: number | null; domestic: string; export: string }[];
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
}

export interface FootprintDetail {
  footprint: Footprint;
  stage_label: string;
  created_by_name: string | null;
  verified_by_name: string | null;
  farmer: { name: string; farmer_code: string | null; village: string } | null;
  prev: { id: string; footprint_code: string; stage_type: StageType } | null;
  available_kg: number;
  qc: null | { domestic_verdict: string; export_verdict: string; readings: Record<string, number>;
    judged: { param: string; value: number | null; domestic: string; export: string }[]; override: Record<string, unknown> | null };
  market_verdict: { domestic: string; export: string; overridden: boolean };
  seal: null | { qr_code: string; batch_codes: string[]; sealed_at: string; ledger_hash: string };
  flags: { id: string; text: string; status: string; created_at: string; raised_by_name: string | null }[];
  attachments: { id: string; kind: string; storage_path: string; sha256: string; created_at: string }[];
  ledger: { seq: number; event: string; hash: string; prev_hash: string; created_at: string; actor_name: string | null }[];
}

export const MANAGER_ROLES: Role[] = ['admin', 'state_manager', 'client_manager'];
export const ROLE_RANK: Record<Role, number> = { admin: 4, state_manager: 3, client_manager: 2, client_view: 1, operator: 1 };
export const isManager = (r?: Role | null) => !!r && MANAGER_ROLES.includes(r);

export interface LotMarkets {
  has_qc: boolean; domestic: 'pass' | 'fail' | 'pending'; export: 'pass' | 'fail' | 'pending';
  overridden: boolean; export_allowed: boolean; markets: string[];
}
export interface Withdrawal { footprint_id: string; reason: string; withdrawn_by: string; withdrawn_at: string }

