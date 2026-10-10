// Supabase Edge Function entry point. Deploy: supabase functions deploy id-numbers
// SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are provided by Supabase automatically; ID_HMAC_KEY (and
// ID_HMAC_KEY_ID) are set with `supabase secrets set` by scripts\staging_joiner_hr_data.ps1 (docs/OPERATIONS.md).
import { handle } from './handler.ts';

Deno.serve((req: Request) => handle(req, Deno.env.toObject()));
