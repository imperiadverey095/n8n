#!/usr/bin/env node
// Заглушка CompreFace для сквозного прогона без Docker.
// Повторяет контракты, которые использует воркфлоу: регистрация лица,
// распознавание и удаление subject. Совпадение определяется по хэшу снимка:
// зарегистрированный кадр узнаётся, любой другой — нет.
import { createServer } from 'node:http';
import { createHash } from 'node:crypto';

const PORT = Number(process.env.CF_PORT || process.env.PORT || 8010);
const API_KEY = process.env.CF_API_KEY || 'stub-recognition-key';
const faces = new Map();   // хэш снимка → subject
const subjects = new Map(); // subject → [image_id]

const readBody = (req) => new Promise((resolve, reject) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => resolve(Buffer.concat(chunks)));
  req.on('error', reject);
});

// из multipart вытаскиваем только содержимое файла
function filePart(buffer, contentType) {
  const m = /boundary=(?:"([^"]+)"|([^;]+))/i.exec(contentType || '');
  if (!m) return null;
  const boundary = Buffer.from(`--${m[1] || m[2]}`);
  let start = buffer.indexOf(boundary);
  while (start >= 0) {
    const next = buffer.indexOf(boundary, start + boundary.length);
    if (next < 0) break;
    const part = buffer.subarray(start + boundary.length + 2, next - 2);
    const sep = part.indexOf('\r\n\r\n');
    if (sep > 0 && /filename="/i.test(part.subarray(0, sep).toString('utf8'))) return part.subarray(sep + 4);
    start = next;
  }
  return null;
}

const json = (res, code, body) => {
  res.writeHead(code, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(body));
};

createServer(async (req, res) => {
  const url = new URL(req.url, 'http://stub');
  const log = (...a) => console.log(new Date().toISOString().slice(11, 19), req.method, url.pathname, ...a);

  if (req.headers['x-api-key'] !== API_KEY) return json(res, 401, { message: 'Api key is not valid' });

  // регистрация лица
  if (req.method === 'POST' && url.pathname === '/api/v1/recognition/faces') {
    const subject = url.searchParams.get('subject');
    const file = filePart(await readBody(req), req.headers['content-type']);
    if (!file || !file.length) return json(res, 400, { message: 'No file', code: 26 });
    if (file.length < 8) return json(res, 400, { message: 'No face is found in the given image', code: 28 });
    const hash = createHash('sha256').update(file).digest('hex');
    const imageId = createHash('sha1').update(hash + subject).digest('hex');
    faces.set(hash, subject);
    subjects.set(subject, [...(subjects.get(subject) || []), imageId]);
    log('subject=' + subject, 'зарегистрирован');
    return json(res, 201, { image_id: imageId, subject });
  }

  // распознавание
  if (req.method === 'POST' && url.pathname === '/api/v1/recognition/recognize') {
    const file = filePart(await readBody(req), req.headers['content-type']);
    if (!file || !file.length) return json(res, 400, { message: 'No file', code: 26 });
    if (file.length < 8) return json(res, 400, { message: 'No face is found in the given image', code: 28 });
    const subject = faces.get(createHash('sha256').update(file).digest('hex'));
    log(subject ? 'узнан ' + subject : 'лицо не найдено в базе');
    return json(res, 200, {
      result: [{
        box: { probability: 0.9991, x_min: 100, y_min: 80, x_max: 320, y_max: 360 },
        subjects: subject ? [{ subject, similarity: 0.9721 }] : [],
      }],
    });
  }

  // удаление subject со всеми примерами
  if (req.method === 'DELETE' && url.pathname.startsWith('/api/v1/recognition/subjects/')) {
    const subject = decodeURIComponent(url.pathname.split('/').pop());
    const had = subjects.delete(subject);
    for (const [hash, s] of faces) if (s === subject) faces.delete(hash);
    log('subject=' + subject, had ? 'удалён' : 'не найден');
    return json(res, had ? 200 : 404, had ? { deleted: 1 } : { message: 'Subject not found' });
  }

  json(res, 404, { message: 'Not found' });
// Значение ключа в журнал не пишем — журналы попадают в артефакты прогона.
}).listen(PORT, () => console.log(`заглушка CompreFace: http://localhost:${PORT}`));
