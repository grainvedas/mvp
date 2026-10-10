// A short card that tells a person what their role is for (Veda, 10 Oct 2026). One component for every role: the words
// come from the dictionaries (guide.<role>.title and guide.<role>.1 … guide.<role>.9, English and Hindi); a role with
// no words shows nothing. Hiding it is remembered on this device only (a convenience; nothing depends on it).
import { useState, type ReactNode } from 'react';
import { useI18n } from '../lib/i18n';

const key = (role: string) => `gv.guide.${role}.hidden`;
function readHidden(role: string): boolean {
  try { return window.localStorage.getItem(key(role)) === '1'; } catch { return false; }
}
function writeHidden(role: string, hidden: boolean) {
  try { if (hidden) window.localStorage.setItem(key(role), '1'); else window.localStorage.removeItem(key(role)); } catch { /* private window: not remembered */ }
}

/** The lines of a role's guide, in order, as far as they are written. Pure over `t`, so it is tested without a screen. */
export function guideLines(role: string, t: (k: string, v?: Record<string, string | number>, f?: string) => string): string[] {
  const out: string[] = [];
  for (let i = 1; i <= 9; i++) {
    const line = t(`guide.${role}.${i}`, undefined, '');
    if (!line) break;
    out.push(line);
  }
  return out;
}

export function RoleGuide({ role, children }: { role: string; children?: ReactNode }) {
  const { t } = useI18n();
  const [hidden, setHidden] = useState(() => readHidden(role));
  const title = t(`guide.${role}.title`, undefined, '');
  const lines = guideLines(role, t);
  if (!title || lines.length === 0) return null;
  const toggle = (h: boolean) => { writeHidden(role, h); setHidden(h); };
  if (hidden) {
    return <p className="small"><button type="button" className="linkish" onClick={() => toggle(false)} data-testid="guide-show">{t('guide.show')}</button></p>;
  }
  return (
    <section className="card guide" aria-labelledby={`guide-${role}`} data-testid="role-guide" data-role={role}>
      <div className="guide-hd">
        <h2 id={`guide-${role}`}><span aria-hidden="true">🧭 </span>{title}</h2>
        <button type="button" className="secondary small-btn" onClick={() => toggle(true)} data-testid="guide-hide">{t('guide.hide')}</button>
      </div>
      <ul className="guide-list">{lines.map((l) => <li key={l}>{l}</li>)}</ul>
      {children}
    </section>
  );
}
