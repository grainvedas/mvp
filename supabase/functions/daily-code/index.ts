// Supabase Edge Function entry point. Deploy: supabase functions deploy daily-code
// SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are provided by Supabase automatically.
// The sender (MAIL_API_URL, MAIL_API_KEY, MAIL_FROM) is set by hand: see ../_shared/mail.ts. Without it the function
// answers GET { sender: false } and the sign-in code stays switched off.
import { handle } from './handler.ts';

Deno.serve((req: Request) => handle(req, Deno.env.toObject()));
