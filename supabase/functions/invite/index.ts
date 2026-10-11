// Supabase Edge Function entry point. Deploy: supabase functions deploy invite --no-verify-jwt
// (an invite is opened by someone who has no sign-in yet; "send" and "reminders" check the caller's sign-in themselves).
// SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are provided by Supabase automatically. A mail sender
// (MAIL_API_URL, MAIL_API_KEY, MAIL_FROM; and APP_URL) is optional: without it invites are links HR copies.
import { handle } from './handler.ts';

Deno.serve((req: Request) => handle(req, Deno.env.toObject()));
