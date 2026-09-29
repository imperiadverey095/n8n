// Приёмник событий кадровой системы: показывает, что уходит из outbox.
import { createServer } from 'node:http';
const PORT = Number(process.env.HR_SINK_PORT || 8011);
const events = [];
createServer(async (req, res) => {
  // Тело больше 10 МБ отклоняется, а не копится в памяти.
  const chunks = []; let size = 0;
  for await (const c of req) {
    size += c.length;
    if (size > 10 * 1024 * 1024) { res.writeHead(413); return res.end(); }
    chunks.push(c);
  }
  const body = Buffer.concat(chunks).toString('utf8');
  if (req.method === 'POST') {
    try { const e = JSON.parse(body); events.push(e); console.log(new Date().toISOString().slice(11,19), 'принято:', e.kind, e.entity_type + '#' + e.entity_id); }
    catch { console.log('принято тело, не JSON'); }
    res.writeHead(200, { 'Content-Type': 'application/json' }); return res.end('{"ok":true}');
  }
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ received: events.length, kinds: events.map((e) => e.kind) }));
// Только localhost: приёмник без авторизации показывает, какие события ушли.
}).listen(PORT, '127.0.0.1', () => console.log(`приёмник HR: http://127.0.0.1:${PORT}`));
