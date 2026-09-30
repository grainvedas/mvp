-- GrainVeda MVP · seed 03: email addresses for the four demo manager logins (Phase 0, workstream D). Idempotent.
-- Plus-addresses of the company inbox, so password-reset and invite mail for every demo login reaches one mailbox
-- that GrainVeda controls. Operators sign in by phone and need no email.
-- Only fills an empty email, so an address changed later by an admin is never overwritten by a re-seed.

update public.app_users set email = v.email
  from (values
    ('00000000-0000-4000-8000-000000000301'::uuid, 'grainvedas+admin@gmail.com'),
    ('00000000-0000-4000-8000-000000000302'::uuid, 'grainvedas+statemanager@gmail.com'),
    ('00000000-0000-4000-8000-000000000303'::uuid, 'grainvedas+clientmanager@gmail.com'),
    ('00000000-0000-4000-8000-000000000304'::uuid, 'grainvedas+clientview@gmail.com')
  ) as v(id, email)
 where public.app_users.id = v.id
   and public.app_users.email is null;
