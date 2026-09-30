export const kg = (n: number | string | null | undefined) =>
  n === null || n === undefined || n === '' ? '—' : `${Number(n).toLocaleString('en-IN', { maximumFractionDigits: 3 })} kg`;
export const num = (n: number | string | null | undefined, digits = 2) =>
  n === null || n === undefined || n === '' ? '—' : Number(n).toLocaleString('en-IN', { maximumFractionDigits: digits });
export const dateTime = (s: string | null | undefined) =>
  s ? new Date(s).toLocaleString('en-IN', { dateStyle: 'medium', timeStyle: 'short' }) : '—';
export const date = (s: string | null | undefined) => (s ? new Date(s).toLocaleDateString('en-IN', { dateStyle: 'medium' }) : '—');
export const shortHash = (h: string | null | undefined) => (h ? `${h.slice(0, 8)}…${h.slice(-6)}` : '—');
export const humanise = (s: string) => s.replace(/_/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase());
