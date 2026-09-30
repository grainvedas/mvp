// HS256 JWT for local keys (anon / service_role), same shape as Supabase's.
import { createHmac } from 'node:crypto';
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
export function sign(payload, secret) {
  const head = b64({ alg: 'HS256', typ: 'JWT' }), body = b64(payload);
  const sig = createHmac('sha256', secret).update(`${head}.${body}`).digest('base64url');
  return `${head}.${body}.${sig}`;
}
if (process.argv[1]?.endsWith('jwt.mjs')) {
  const [, , role, secret] = process.argv;
  console.log(sign({ role, iss: 'supabase-local', iat: 1700000000, exp: 4102444800 }, secret));
}
