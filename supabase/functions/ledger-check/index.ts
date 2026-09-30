// Supabase Edge Function entry point. Deploy: supabase functions deploy ledger-check --no-verify-jwt
// (the monitor authenticates with the x-check-token header, not a user JWT). Set the token once:
//   supabase secrets set LEDGER_CHECK_TOKEN=<long random string>
import { handle } from './handler.ts';

Deno.serve((req: Request) => handle(req, Deno.env.toObject()));
