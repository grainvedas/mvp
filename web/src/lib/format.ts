export const kg = (n: number | string | null | undefined) =>
  n === null || n === undefined || n === '' ? '—' : `${Number(n).toLocaleString('en-IN', { maximumFractionDigits: 3 })} kg`;
export const num = (n: number | string | null | undefined, digits = 2) =>
  n === null || n === undefined || n === '' ? '—' : Number(n).toLocaleString('en-IN', { maximumFractionDigits: digits });
export const dateTime = (s: string | null | undefined) =>
  s ? new Date(s).toLocaleString('en-IN', { dateStyle: 'medium', timeStyle: 'short' }) : '—';
export const date = (s: string | null | undefined) => (s ? new Date(s).toLocaleDateString('en-IN', { dateStyle: 'medium' }) : '—');
export const shortHash = (h: string | null | undefined) => (h ? `${h.slice(0, 8)}…${h.slice(-6)}` : '—');
/** Today's date in India (YYYY-MM-DD), whatever the device's clock zone: the UTC date is a day early from 00:00 to 05:30 IST. */
export const todayIST = (now: number = Date.now()) => new Date(now + 5.5 * 3600e3).toISOString().slice(0, 10);
/** What an audit entry's from/to says, or '' when it has no "to". An empty "from" (nothing before) shows as a dash. */
export const fromTo = (from: unknown, to: unknown) =>
  to === undefined || to === null || String(to) === '' || from === undefined ? '' : `${String(from ?? '') === '' ? '—' : humanise(String(from))} → ${humanise(String(to))}`;
export const humanise = (s: string) => s.replace(/_/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase());
