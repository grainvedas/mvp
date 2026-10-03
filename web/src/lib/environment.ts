// Which system is this? app.environment() answers 'production' only on the project marked by the production seed
// (migration 23); every other project is a practice system and says so on every screen, the public page included,
// so a label printed from practice data cannot pass for a real lot.
// The answer is remembered per database URL so the strip does not flicker and still shows with no network.
import { useEffect, useState } from 'react';
import { appDb, SUPABASE_URL } from './supabase';

export type Environment = 'production' | 'staging';
const KEY = `grainveda-env:${SUPABASE_URL}`;

function remembered(): Environment | null {
  try { const v = localStorage.getItem(KEY); return v === 'production' || v === 'staging' ? v : null; } catch { return null; }
}

let asked: Promise<Environment | null> | null = null;
/** One request per page load. Null = could not ask and nothing remembered (an older database, or first visit offline). */
export function loadEnvironment(): Promise<Environment | null> {
  asked ??= (async () => {
    try {
      const { data, error } = await appDb.rpc('environment');
      if (error || typeof data !== 'string') return remembered();
      const env: Environment = data === 'production' ? 'production' : 'staging';
      try { localStorage.setItem(KEY, env); } catch { /* private mode */ }
      return env;
    } catch { return remembered(); }
  })();
  return asked;
}

export function useEnvironment(): Environment | null {
  const [env, setEnv] = useState<Environment | null>(remembered);
  useEffect(() => {
    let live = true;
    void loadEnvironment().then((e) => { if (live && e) setEnv(e); });
    return () => { live = false; };
  }, []);
  return env;
}
