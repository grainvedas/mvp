// Migration 72 (Phase 3, release 5, Part E3): a client's showcase page. Every rule is the database's: what is public
// (app.public_showcase: nothing until the client's owner approved it), who approves and unpublishes
// (app.showcase_publish, app.showcase_unpublish), what the client's and GrainVeda's people see of it (app.showcase_of).
import { rpc } from './api';

export interface ShowcaseCrop { crop: string; gi_tag: string | null; season: string; tonnes: number; villages: number; gi_pct: number | null; lab_pass_pct: number | null }
export interface ShowcaseData {
  code: string; name: string; own_brand: boolean; expired?: boolean;
  verification: { status: 'active' | 'paused' | 'ended'; ended_on: string | null } | null;
  totals?: { tonnes: number; villages: number; gi_pct: number | null; lab_pass_pct: number | null; states: number; crops: number };
  states?: { state: string; status: 'active' | 'paused' | 'ended'; ended_on: string | null; crops: ShowcaseCrop[] }[];
  recalls?: { qr_code: string; crop: string; season: string; at: string | null; reason: string | null }[];
  partners?: string[];
}
export interface ShowcaseOf {
  client_id: string; code: string; status: 'never' | 'published' | 'unpublished';
  published_at: string | null; published_by: string | null; unpublished_at: string | null; unpublished_by: string | null; unpublish_reason: string | null;
  may_publish: boolean; may_unpublish: boolean; live_until: string | null; preview: ShowcaseData;
}

export const publicShowcase = (code: string) => rpc<ShowcaseData | null>('public_showcase', { p_code: code });
export const showcaseOf = (client: string) => rpc<ShowcaseOf>('showcase_of', { p_client: client });
export const publishShowcase = (client: string) => rpc<ShowcaseOf>('showcase_publish', { p_client: client });
export const unpublishShowcase = (client: string, reason: string) => rpc<ShowcaseOf>('showcase_unpublish', { p_client: client, p_reason: reason });

/** Pure: a figure as the page writes it ("—" when there is none yet). */
export function figure(kind: 'tonnes' | 'villages' | 'pct', v: number | null | undefined): string {
  if (v === null || v === undefined) return '—';
  if (kind === 'tonnes') return `${Number(v).toLocaleString('en-IN', { maximumFractionDigits: 2 })} t`;
  if (kind === 'pct') return `${Number(v).toLocaleString('en-IN', { maximumFractionDigits: 1 })} %`;
  return Number(v).toLocaleString('en-IN');
}
/** Pure: where "Verify any pack" goes: a sealed lot's QR code or a pack's serial (the verify page reads both). */
export function verifyPath(code: string): string | null {
  const c = code.trim().replace(/\s+/g, '').toUpperCase();
  return /^[A-Z0-9][A-Z0-9-]{4,60}$/.test(c) ? `/verify/${encodeURIComponent(c)}` : null;
}
