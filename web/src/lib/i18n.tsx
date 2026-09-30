// Translation layer (execution plan §6). Every visible string goes through t(). English and Hindi (src/lib/i18n.hi.ts). Stage and field labels from the database are translated by key in the same table.
import { createContext, useContext, useMemo, useState, type ReactNode } from 'react';
import { en } from './i18n.en';
import { hi } from './i18n.hi';

export type Lang = 'en' | 'hi';
type Dict = Record<string, string>;
const dictionaries: Record<Lang, Dict> = { en, hi };

export function registerDictionary(lang: Lang, dict: Dict) {
  dictionaries[lang] = { ...dictionaries[lang], ...dict };
}

export function translate(lang: Lang, key: string, vars?: Record<string, string | number>, fallback?: string): string {
  let s = dictionaries[lang][key] ?? dictionaries.en[key] ?? fallback ?? key;
  if (vars) for (const [k, v] of Object.entries(vars)) s = s.replaceAll(`{${k}}`, String(v));
  return s;
}

interface I18n { lang: Lang; setLang: (l: Lang) => void; t: (key: string, vars?: Record<string, string | number>, fallback?: string) => string }
const Ctx = createContext<I18n>({ lang: 'en', setLang: () => {}, t: (k, v, f) => translate('en', k, v, f) });

function initialLang(): Lang {
  try { return (localStorage.getItem('grainveda-lang') as Lang) === 'hi' ? 'hi' : 'en'; } catch { return 'en'; }
}

export function I18nProvider({ children }: { children: ReactNode }) {
  const [lang, setLangState] = useState<Lang>(initialLang);
  const value = useMemo<I18n>(() => ({
    lang,
    setLang: (l) => { setLangState(l); try { localStorage.setItem('grainveda-lang', l); } catch { /* private mode */ } },
    t: (key, vars, fallback) => translate(lang, key, vars, fallback),
  }), [lang]);
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export const useI18n = () => useContext(Ctx);
