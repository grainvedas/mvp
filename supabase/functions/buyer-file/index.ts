// Supabase Edge Function entry point. Deploy: supabase functions deploy buyer-file --no-verify-jwt
// (a buyer opens his link without a sign-in; the link's token is the permission). SUPABASE_URL and
// SUPABASE_SERVICE_ROLE_KEY are provided by Supabase automatically.
import { handle } from './handler.ts';

Deno.serve((req: Request) => handle(req, Deno.env.toObject()));
