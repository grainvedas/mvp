// Shared helpers for the Node scripts in scripts/ and tests/. No dependencies (Node 20+ has fetch).
// Reads .env.local then .env from the repo root; real environment variables win.
import { readFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

export const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

export function loadEnv() {
  const env = {};
  // .env.local overrides .env; ENV_FILE (e.g. .env.stack for the local stack) overrides both
  for (const name of ['.env', '.env.local', ...(process.env.ENV_FILE ? [process.env.ENV_FILE] : [])]) {
    const p = join(ROOT, name);
    if (!existsSync(p)) continue;
    for (const line of readFileSync(p, 'utf8').split(/\r?\n/)) {
      const m = line.match(/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$/);
      if (!m) continue;
      let v = m[2];
      if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1);
      env[m[1]] = v;
    }
  }
  return { ...env, ...process.env };
}

function first(env, names) {
  for (const n of names) if (env[n]) return env[n];
  return undefined;
}

export function supabaseConfig({ needService = false } = {}) {
  const env = loadEnv();
  const url = first(env, ['SUPABASE_URL', 'NEXT_PUBLIC_SUPABASE_URL', 'VITE_SUPABASE_URL']);
  const anon = first(env, ['SUPABASE_ANON_KEY', 'NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY', 'NEXT_PUBLIC_SUPABASE_ANON_KEY',
    'SUPABASE_PUBLISHABLE_KEY', 'VITE_SUPABASE_ANON_KEY']);
  const service = first(env, ['SUPABASE_SERVICE_ROLE_KEY', 'SUPABASE_SECRET_KEY', 'SERVICE_ROLE_KEY']);
  const missing = [];
  if (!url) missing.push('SUPABASE_URL');
  if (!anon) missing.push('SUPABASE_ANON_KEY (or NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY)');
  if (needService && !service) missing.push('SUPABASE_SERVICE_ROLE_KEY');
  if (missing.length) throw new Error(`missing in .env.local: ${missing.join(', ')}`);
  return { url: url.replace(/\/+$/, ''), anon, service, env };
}

// Minimal REST client. `profile` selects the exposed schema ('public' or 'app').
export function client(cfg, { key, token, profile = 'public' } = {}) {
  const base = {
    apikey: key,
    Authorization: `Bearer ${token ?? key}`,
    'Accept-Profile': profile,
    'Content-Profile': profile,
  };
  async function req(method, path, body, extra = {}) {
    const res = await fetch(`${cfg.url}${path}`, {
      method,
      headers: { ...base, ...(body !== undefined ? { 'Content-Type': 'application/json' } : {}), ...extra },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await res.text();
    let data = null;
    try { data = text ? JSON.parse(text) : null; } catch { data = text; }
    return { status: res.status, ok: res.ok, data };
  }
  return {
    get: (table, query = '') => req('GET', `/rest/v1/${table}${query ? `?${query}` : ''}`),
    count: async (table, query = '', col = 'id') => {
      const r = await req('GET', `/rest/v1/${table}?select=${col}${query ? `&${query}` : ''}`);
      return r.ok ? r.data.length : r;
    },
    insert: (table, row) => req('POST', `/rest/v1/${table}`, row, { Prefer: 'return=representation' }),
    update: (table, query, patch) => req('PATCH', `/rest/v1/${table}?${query}`, patch, { Prefer: 'return=representation' }),
    rpc: (fn, args = {}) => req('POST', `/rest/v1/rpc/${fn}`, args),
    raw: req,
  };
}

export async function signIn(cfg, { email, phone, password }) {
  const res = await fetch(`${cfg.url}/auth/v1/token?grant_type=password`, {
    method: 'POST',
    headers: { apikey: cfg.anon, 'Content-Type': 'application/json' },
    body: JSON.stringify(email ? { email, password } : { phone, password }),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`sign-in failed for ${email ?? phone}: ${res.status} ${data.error_description ?? data.msg ?? ''}`);
  return data.access_token;
}

// git-ignored by the `.env.*` rule; the local stack keeps its own file so live and local passwords never mix
export const DEMO_LOGINS_FILE = join(ROOT, process.env.ENV_FILE === '.env.stack' ? '.env.demo-logins.stack' : '.env.demo-logins');

export function readDemoLogins() {
  if (!existsSync(DEMO_LOGINS_FILE)) return {};
  const out = {};
  for (const line of readFileSync(DEMO_LOGINS_FILE, 'utf8').split(/\r?\n/)) {
    const m = line.match(/^DEMO_([0-9]{3})_PASSWORD=(.+)$/);
    if (m) out[m[1]] = m[2];
  }
  return out;
}
