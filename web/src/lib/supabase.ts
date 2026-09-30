import { createClient } from '@supabase/supabase-js';

const env = import.meta.env as Record<string, string | undefined>;
export const SUPABASE_URL = env.VITE_SUPABASE_URL ?? env.NEXT_PUBLIC_SUPABASE_URL ?? '';
export const SUPABASE_ANON_KEY =
  env.VITE_SUPABASE_ANON_KEY ?? env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ?? env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? '';

export const configured = Boolean(SUPABASE_URL && SUPABASE_ANON_KEY);

export const supabase = createClient(SUPABASE_URL || 'http://invalid.local', SUPABASE_ANON_KEY || 'missing', {
  auth: { persistSession: true, autoRefreshToken: true, storageKey: 'grainveda-auth' },
});

/** The `app` schema: RPCs such as stage_form, preview_reconcile, verify_footprint, seal_lot. */
export const appDb = supabase.schema('app');
