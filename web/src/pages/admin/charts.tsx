// Small charts for the admin's screens, drawn as SVG with the app's own tokens. One hue for magnitude (--g500); a
// lighter step of it for "waiting"; status colours only for pass / fail, always with the words beside them. Every chart
// has its numbers in a table (a <details> under it) and a hover title on every mark; text is ink, never a series colour.
import type { ReactNode } from 'react';
import { useI18n } from '../../lib/i18n';

/** Pure: a "nice" top for an axis (1, 2, 5 × 10^n) at or above the largest value; 1 when everything is 0. */
export function niceMax(values: number[]): number {
  const max = Math.max(0, ...values.map((v) => Number(v) || 0));
  if (max <= 0) return 1;
  const p = 10 ** Math.floor(Math.log10(max));
  for (const m of [1, 2, 5, 10]) if (m * p >= max) return m * p;
  return 10 * p;
}

/** Pure: the change between the last `n` weeks and the `n` before them, as a whole percentage; null without a base. */
export function changePct(series: number[], n = 4): number | null {
  if (series.length < 2 * n) return null;
  const now = series.slice(-n).reduce((a, b) => a + (Number(b) || 0), 0);
  const before = series.slice(-2 * n, -n).reduce((a, b) => a + (Number(b) || 0), 0);
  if (before <= 0) return null;
  return Math.round(((now - before) / before) * 100);
}

/** Columns over time (one series). Labels under the first, middle and last column only; the axis top on the left. */
export function Columns({ values, labels, fmt, title, testId, height = 120 }: {
  values: number[]; labels: string[]; fmt: (v: number) => string; title: string; testId?: string; height?: number;
}) {
  const { t } = useI18n();
  const top = niceMax(values);
  const n = values.length;
  const W = 300, H = height, padL = 4, padB = 18, padT = 14;
  const slot = (W - padL) / Math.max(n, 1);
  const bw = Math.max(2, slot - 2);                                  // a 2 px surface gap between columns
  const y = (v: number) => padT + (H - padT - padB) * (1 - (Number(v) || 0) / top);
  const shown = new Set([0, Math.floor((n - 1) / 2), n - 1]);
  return (
    <figure className="chart" data-testid={testId}>
      <figcaption className="chart-title">{title}</figcaption>
      <svg viewBox={`0 0 ${W} ${H}`} role="img" aria-label={title} className="chart-svg">
        <line x1={padL} x2={W} y1={H - padB} y2={H - padB} className="chart-base" />
        <text x={padL} y={10} className="chart-axis">{fmt(top)}</text>
        {values.map((v, i) => {
          const h = Math.max(0, H - padB - y(v));
          const x = padL + i * slot + 1;
          return (
            <g key={i}>
              <rect x={x} y={padT} width={bw} height={H - padT - padB} className="chart-hit"><title>{`${labels[i]}: ${fmt(v)}`}</title></rect>
              {h > 0 && <path className="chart-col" d={roundTop(x, H - padB - h, bw, h)}><title>{`${labels[i]}: ${fmt(v)}`}</title></path>}
              {shown.has(i) && <text x={x + bw / 2} y={H - 4} textAnchor="middle" className="chart-axis">{labels[i]}</text>}
            </g>);
        })}
      </svg>
      <details className="chart-table"><summary>{t('chart.table')}</summary>
        <div className="table-wrap"><table><tbody>{values.map((v, i) => <tr key={i}><td>{labels[i]}</td><td className="num">{fmt(v)}</td></tr>)}</tbody></table></div>
      </details>
    </figure>
  );
}

/** A column whose top corners are rounded (4 px) and whose foot sits square on the baseline. */
function roundTop(x: number, y: number, w: number, h: number): string {
  const r = Math.min(4, w / 2, h);
  return `M${x},${y + h} V${y + r} Q${x},${y} ${x + r},${y} H${x + w - r} Q${x + w},${y} ${x + w},${y + r} V${y + h} Z`;
}

/** Horizontal bars, one row each, the value in ink at the end; an optional second, lighter part ("waiting"). */
export function Bars({ rows, fmt, testId, legend }: {
  rows: { key: string; label: ReactNode; value: number; rest?: number; title?: string }[];
  fmt: (v: number) => string; testId?: string; legend?: [string, string];
}) {
  const top = Math.max(1, ...rows.map((r) => (Number(r.value) || 0) + (Number(r.rest) || 0)));
  return (
    <div className="hbars" data-testid={testId}>
      {rows.map((r) => (
        <div className="hbar-row" key={r.key} title={r.title}>
          <div className="hbar-label">{r.label}</div>
          <div className="hbar-track">
            {Number(r.value) > 0 && <span className="hbar seg-a" style={{ width: `${(Number(r.value) / top) * 100}%` }} />}
            {Number(r.rest) > 0 && <span className="hbar seg-b" style={{ width: `${(Number(r.rest) / top) * 100}%` }} />}
          </div>
          <div className="hbar-val">{fmt(Number(r.value))}{r.rest !== undefined ? ` · ${fmt(Number(r.rest))}` : ''}</div>
        </div>))}
      {legend && <p className="small muted legend"><span className="key done" aria-hidden="true" /> {legend[0]} <span className="key pending" aria-hidden="true" /> {legend[1]}</p>}
    </div>
  );
}

/** Pass / fail as one bar with its words: status colours, never alone. */
export function PassFail({ pass, fail, label }: { pass: number; fail: number; label: string }) {
  const { t } = useI18n();
  const all = Number(pass) + Number(fail);
  const pct = all > 0 ? Math.round((Number(pass) / all) * 100) : null;
  return (
    <div className="pf-row">
      <div className="hbar-label">{label}</div>
      <div className="hbar-track" title={t('chart.pass_fail', { p: pass, f: fail })}>
        {Number(pass) > 0 && <span className="hbar seg-pass" style={{ width: `${(Number(pass) / Math.max(all, 1)) * 100}%` }} />}
        {Number(fail) > 0 && <span className="hbar seg-fail" style={{ width: `${(Number(fail) / Math.max(all, 1)) * 100}%` }} />}
      </div>
      <div className="hbar-val">{pct === null ? '—' : t('chart.pass_pct', { p: pct })} <span className="muted small">({t('chart.pass_fail', { p: pass, f: fail })})</span></div>
    </div>
  );
}
