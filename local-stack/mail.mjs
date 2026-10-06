// Local stand-in for a mail service, so the two things that send mail (the invite note, the once-a-day sign-in code)
// can be tested end to end without sending anything anywhere. Never deployed. Keeps the messages in memory.
//   POST   /emails            { from, to[], subject, text }  with "Authorization: Bearer <MAIL_API_KEY>"   (the Resend shape)
//   GET    /outbox?to=a@b.c   the messages kept (all, or those to one address), oldest first
//   DELETE /outbox            forget them
import http from 'node:http';
const port = Number(process.env.MAIL_PORT ?? 54334);
const key = process.env.MAIL_API_KEY ?? '';
const box = [];
const send = (res, status, body) => { res.writeHead(status, { 'content-type': 'application/json', 'access-control-allow-origin': '*' }); res.end(JSON.stringify(body)); };
http.createServer(async (req, res) => {
  const u = new URL(req.url ?? '/', 'http://local');
  if (req.method === 'POST' && u.pathname === '/emails') {
    if (!key || req.headers.authorization !== `Bearer ${key}`) return send(res, 401, { message: 'bad key' });
    const chunks = []; for await (const c of req) chunks.push(c);
    let m; try { m = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { return send(res, 400, { message: 'body must be JSON' }); }
    if (!m?.from || !Array.isArray(m.to) || !m.to.length || !m.subject) return send(res, 422, { message: 'from, to[] and subject are required' });
    box.push({ from: m.from, to: m.to.map((x) => String(x).toLowerCase()), subject: m.subject, text: m.text ?? '', at: new Date().toISOString() });
    if (box.length > 500) box.shift();
    return send(res, 200, { id: `local-${box.length}` });
  }
  if (req.method === 'GET' && u.pathname === '/outbox') {
    const to = (u.searchParams.get('to') ?? '').toLowerCase();
    return send(res, 200, to ? box.filter((m) => m.to.includes(to)) : box);
  }
  if (req.method === 'DELETE' && u.pathname === '/outbox') { box.length = 0; return send(res, 200, { ok: true }); }
  send(res, 404, { message: 'no route' });
}).listen(port, '127.0.0.1', () => console.log(`mail stand-in on ${port}`));
