export const kg = (n: number | string | null | undefined) =>
  n === null || n === undefined || n === '' ? '—' : `${Number(n).toLocaleString('en-IN', { maximumFractionDigits: 3 })} kg`;
export const num = (n: number | string | null | undefined, digits = 2) =>
  n === null || n === undefined || n === '' ? '—' : Number(n).toLocaleString('en-IN', { maximumFractionDigits: digits });
/** Every time is shown in India's time, whatever the phone's or the browser's zone (Veda, 15 Oct 2026: "show times in
 *  IST everywhere, including exports"). The browser pane showed UTC. */
export const IST = 'Asia/Kolkata';
export const dateTime = (s: string | null | undefined) =>
  s ? `${new Date(s).toLocaleString('en-IN', { dateStyle: 'medium', timeStyle: 'short', timeZone: IST })} IST` : '—';
export const date = (s: string | null | undefined) => (s ? new Date(s).toLocaleDateString('en-IN', { dateStyle: 'medium', timeZone: IST }) : '—');
/** A time for a spreadsheet: "2026-10-15 09:12:03 IST" (sortable, India's time). */
export const istStamp = (s: string | null | undefined) => {
  if (!s) return '';
  const d = new Date(s);
  if (Number.isNaN(d.getTime())) return String(s);
  return `${new Date(d.getTime() + 5.5 * 3600e3).toISOString().slice(0, 19).replace('T', ' ')} IST`;
};
export const shortHash = (h: string | null | undefined) => (h ? `${h.slice(0, 8)}…${h.slice(-6)}` : '—');
/** Today's date in India (YYYY-MM-DD), whatever the device's clock zone: the UTC date is a day early from 00:00 to 05:30 IST. */
export const todayIST = (now: number = Date.now()) => new Date(now + 5.5 * 3600e3).toISOString().slice(0, 10);
/** What an audit entry's from/to says, or '' when it has no "to". An empty "from" (nothing before) shows as a dash. */
export const fromTo = (from: unknown, to: unknown) =>
  to === undefined || to === null || String(to) === '' || from === undefined ? '' : `${String(from ?? '') === '' ? '—' : humanise(String(from))} → ${humanise(String(to))}`;
export const humanise = (s: string) => s.replace(/_/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase());
