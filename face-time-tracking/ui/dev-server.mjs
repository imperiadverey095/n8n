#!/usr/bin/env node
// -----------------------------------------------------------------------------
//  Локальный сервер для разработки интерфейсов (ui/*.html) БЕЗ n8n.
//  Повторяет контракты вебхуков воркфлоу 02/04 поверх настоящей БД: те же
//  токены, те же функции timetrack.fn_*, те же коды ответов. Распознавание лица
//  здесь заглушено — см. RECOGNIZE ниже; в бою его делает CompreFace в n8n.
//
//    DATABASE_URL=postgres://user:pass@host:5432/timetrack node ui/dev-server.mjs
//    открыть http://localhost:8099/kiosk.html
//
//  Это инструмент для вёрстки и демонстрации, а не продакшен-путь:
//  в продакшене страницы обращаются к вебхукам n8n.
// -----------------------------------------------------------------------------
import { createServer } from 'node:http';
import { execFile } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { promisify } from 'node:util';
import { createHash, randomUUID } from 'node:crypto';
import { dirname, join, extname } from 'node:path';
import { fileURLToPath } from 'node:url';

const execFileAsync = promisify(execFile);
const here = dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.PORT || 8099);
const DB = process.env.DATABASE_URL;
if (!DB) {
	console.error('нужен DATABASE_URL, например postgres://postgres@127.0.0.1:5432/timetrack');
	process.exit(1);
}

// Строка подключения разбирается в переменные окружения и НЕ передаётся psql
// аргументом: Node включает всю командную строку в текст ошибки execFile,
// и пароль утёк бы вместе с ней.
function connectionEnv(url) {
	try {
		const u = new URL(url);
		const env = { ...process.env };
		if (u.hostname) env.PGHOST = decodeURIComponent(u.hostname);
		if (u.port) env.PGPORT = u.port;
		if (u.username) env.PGUSER = decodeURIComponent(u.username);
		if (u.password) env.PGPASSWORD = decodeURIComponent(u.password);
		const db = u.pathname.replace(/^\//, '');
		if (db) env.PGDATABASE = decodeURIComponent(db);
		for (const [key, value] of u.searchParams) {
			if (key === 'host') env.PGHOST = value;
			if (key === 'port') env.PGPORT = value;
		}
		return env;
	} catch {
		return null;
	}
}
const PG_ENV = connectionEnv(DB);
const mask = (text) => String(text).replace(/(postgres(?:ql)?:\/\/[^:@\s]*:)[^@\s]*(@)/g, '$1***$2');

const lit = (v) =>
	v === null || v === undefined ? 'NULL' : `'${String(typeof v === 'object' ? JSON.stringify(v) : v).replace(/'/g, "''")}'`;

async function sql(query) {
	const args = ['-X', '-At', '-v', 'ON_ERROR_STOP=1', '-c', query];
	const options = { maxBuffer: 32 * 1024 * 1024 };
	if (PG_ENV) options.env = PG_ENV;
	else args.unshift(DB);
	const { stdout } = await execFileAsync('psql', args, options);
	return stdout.trim();
}
const one = async (query) => {
	const out = await sql(query);
	const line = out.split('\n').find((l) => l.startsWith('{') || l.startsWith('['));
	return line ? JSON.parse(line) : null;
};

async function authenticate(token) {
	if (!token || token.length < 16) return null;
	return await one(
		`SELECT row_to_json(x) FROM (SELECT client_id, client_name, role, employee_id, location FROM timetrack.fn_authenticate(${lit(token)})) x`,
	);
}

// Заглушка распознавания: вместо CompreFace берём сотрудника из поля формы
// employee_id, иначе — первого с действующим согласием. Схожесть подставляется.
async function RECOGNIZE(fields) {
	const hint = fields.employee_id ? String(fields.employee_id) : null;
	const row = await one(
		`SELECT row_to_json(x) FROM (
		   SELECT e.employee_id, e.full_name FROM timetrack.employees e
		    WHERE e.status = 'active' AND timetrack.fn_has_consent(e.employee_id)
		      AND (${lit(hint)}::text IS NULL OR e.employee_id = ${lit(hint)})
		    ORDER BY e.employee_id LIMIT 1) x`,
	);
	if (!row) return { matched: false, code: 'unknown_face', http: 404, message: 'Лицо не зарегистрировано' };
	return { matched: true, employee_id: row.employee_id, similarity: 0.94 + Math.random() * 0.05 };
}

function parseMultipart(buffer, contentType) {
	const m = /boundary=(?:"([^"]+)"|([^;]+))/i.exec(contentType || '');
	if (!m) return { fields: {}, files: {} };
	const boundary = Buffer.from(`--${m[1] || m[2]}`);
	const fields = {};
	const files = {};
	let start = buffer.indexOf(boundary);
	while (start >= 0) {
		const next = buffer.indexOf(boundary, start + boundary.length);
		if (next < 0) break;
		const part = buffer.subarray(start + boundary.length + 2, next - 2);
		const sep = part.indexOf('\r\n\r\n');
		if (sep > 0) {
			const head = part.subarray(0, sep).toString('utf8');
			const body = part.subarray(sep + 4);
			const name = /name="([^"]+)"/i.exec(head)?.[1];
			const filename = /filename="([^"]*)"/i.exec(head)?.[1];
			if (name && filename !== undefined) files[name] = { filename, data: body };
			else if (name) fields[name] = body.toString('utf8');
		}
		start = next;
	}
	return { fields, files };
}

const readBody = (req) =>
	new Promise((resolve, reject) => {
		const chunks = [];
		req.on('data', (c) => chunks.push(c));
		req.on('end', () => resolve(Buffer.concat(chunks)));
		req.on('error', reject);
	});

const json = (res, code, body) => {
	res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8', 'Access-Control-Allow-Origin': '*' });
	res.end(JSON.stringify(body));
};

const MIME = { '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8', '.js': 'text/javascript; charset=utf-8' };

const server = createServer(async (req, res) => {
	const url = new URL(req.url, `http://${req.headers.host}`);
	const path = url.pathname;
	const token =
		req.headers['x-api-token'] || String(req.headers.authorization || '').replace(/^Bearer\s+/i, '') || url.searchParams.get('token');

	try {
		if (req.method === 'OPTIONS') {
			res.writeHead(204, {
				'Access-Control-Allow-Origin': '*',
				'Access-Control-Allow-Headers': 'X-Api-Token, Content-Type',
				'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
			});
			return res.end();
		}

		// ---------- статика ----------
		if (req.method === 'GET' && (path === '/' || /\.(html|css|js)$/.test(path))) {
			const file = path === '/' ? 'kiosk.html' : path.replace(/^\//, '');
			const body = await readFile(join(here, file));
			res.writeHead(200, { 'Content-Type': MIME[extname(file)] || 'application/octet-stream' });
			return res.end(body);
		}

		// ---------- отметка по лицу (воркфлоу 02) ----------
		if (req.method === 'POST' && path === '/webhook/timetrack/clock') {
			const auth = await authenticate(token);
			if (!auth || !['device', 'system', 'hr'].includes(auth.role))
				return json(res, 401, { ok: false, code: 'unauthorized', message: 'Неверный или отсутствующий API-токен' });

			const body = await readBody(req);
			const { fields, files } = parseMultipart(body, req.headers['content-type']);
			const image = files.image;
			if (!image || !image.data.length)
				return json(res, 400, { ok: false, code: 'bad_request', message: 'Не передан снимок', problems: ['image_missing'] });

			const rec = await RECOGNIZE(fields);
			if (!rec.matched) return json(res, rec.http, { ok: false, code: rec.code, message: rec.message, request_id: fields.request_id });
			if (fields.employee_id && fields.employee_id !== rec.employee_id)
				return json(res, 403, { ok: false, code: 'employee_mismatch', message: 'Лицо не соответствует указанному сотруднику' });

			const hash = createHash('sha256').update(image.data).digest('hex');
			const meta = { face_probability: 0.999, faces_detected: 1, via: 'dev-server' };
			const r = await one(`SELECT row_to_json(x) FROM (
				SELECT ok, code, event_id, event_type, occurred_at, duplicate, employee_id, full_name, timezone
				  FROM timetrack.fn_clock(${lit(rec.employee_id)}, ${lit(fields.event_type || 'auto')}, 'face',
				       ${lit(fields.device_id || auth.client_name)}, ${lit(fields.location || auth.location)},
				       ${rec.similarity.toFixed(4)}::numeric, NULL, ${lit(hash)}, ${lit(fields.request_id || randomUUID())},
				       ${lit(fields.captured_at || null)}::timestamptz, ${lit(meta)}::jsonb, ${lit(auth.client_name)},
				       120, 16, true, 24)) x`);
			if (!r.ok) return json(res, 403, { ok: false, code: r.code, employee_id: r.employee_id });
			return json(res, 200, { ...r, similarity: Number(rec.similarity.toFixed(4)) });
		}

		// ---------- мои записи (воркфлоу 04) ----------
		if (req.method === 'GET' && path === '/webhook/timetrack/me/records') {
			const auth = await authenticate(token);
			if (!auth || auth.role !== 'employee') return json(res, 401, { ok: false, code: 'unauthorized' });
			const from = /^\d{4}-\d{2}-\d{2}$/.test(url.searchParams.get('from') || '') ? url.searchParams.get('from') : null;
			const to = /^\d{4}-\d{2}-\d{2}$/.test(url.searchParams.get('to') || '') ? url.searchParams.get('to') : null;
			const r = await one(`SELECT row_to_json(x) FROM (
				SELECT employee, days, sessions, corrections, absences, totals
				  FROM timetrack.fn_timesheet(${lit(auth.employee_id)},
				       COALESCE(${lit(from)}::date, CURRENT_DATE - 30), COALESCE(${lit(to)}::date, CURRENT_DATE), NULL, true)) x`);
			return json(res, 200, r ?? {});
		}

		// ---------- запрос корректировки (воркфлоу 04) ----------
		if (req.method === 'POST' && path === '/webhook/timetrack/me/corrections') {
			const auth = await authenticate(token);
			if (!auth || auth.role !== 'employee') return json(res, 401, { ok: false, code: 'unauthorized' });
			const b = JSON.parse((await readBody(req)).toString('utf8') || '{}');
			const r = await one(`SELECT row_to_json(x) FROM (
				SELECT ok, code, request FROM timetrack.fn_request_correction(${lit(auth.employee_id)}, ${lit(b.action || 'add')},
				       ${b.event_id ? `${Number(b.event_id)}::bigint` : 'NULL'}, ${lit(b.requested_type || null)},
				       ${lit(b.requested_time || null)}::timestamptz, ${lit(b.reason || '')}, ${lit(auth.client_name)}, 45)) x`);
			return json(res, r.ok ? 201 : 400, r);
		}

		// ---------- очередь и решения HR (воркфлоу 04) ----------
		if (req.method === 'GET' && path === '/webhook/timetrack/hr/corrections') {
			const auth = await authenticate(token);
			if (!auth || !['hr', 'system'].includes(auth.role)) return json(res, 401, { ok: false, code: 'unauthorized' });
			const status = ['pending', 'approved', 'rejected'].includes(url.searchParams.get('status'))
				? url.searchParams.get('status')
				: 'pending';
			const out = await sql(`SELECT COALESCE(json_agg(row_to_json(x)), '[]') FROM (
				SELECT c.id AS request_id, c.employee_id, e.full_name, e.department, c.action, c.event_id,
				       a.event_type AS current_type, a.occurred_at AS current_occurred_at,
				       c.requested_type, c.requested_time, c.reason, c.status, c.reviewed_by, c.reviewed_at,
				       c.review_comment, c.created_at
				  FROM timetrack.correction_requests c
				  JOIN timetrack.employees e ON e.employee_id = c.employee_id
				  LEFT JOIN timetrack.attendance_events a ON a.id = c.event_id
				 WHERE c.status = ${lit(status)} ORDER BY c.created_at LIMIT 500) x`);
			return json(res, 200, JSON.parse(out));
		}
		if (req.method === 'POST' && path === '/webhook/timetrack/hr/corrections/review') {
			const auth = await authenticate(token);
			if (!auth || !['hr', 'system'].includes(auth.role)) return json(res, 401, { ok: false, code: 'unauthorized' });
			const b = JSON.parse((await readBody(req)).toString('utf8') || '{}');
			const uuid = /^[0-9a-f-]{36}$/i.test(b.request_id || '') ? b.request_id : '00000000-0000-0000-0000-000000000000';
			const r = await one(`SELECT row_to_json(x) FROM (
				SELECT ok, code, request, result_event FROM timetrack.fn_review_correction(${lit(uuid)}::uuid,
				       ${lit(b.decision || '')}, ${lit(b.comment || null)}, ${lit(auth.client_name)})) x`);
			return json(res, r.ok ? 200 : 400, r);
		}

		// ---------- отчёт (воркфлоу 03), только сводка для панели HR ----------
		if (req.method === 'GET' && path === '/webhook/timetrack/reports') {
			const auth = await authenticate(token);
			if (!auth || !['hr', 'system', 'employee'].includes(auth.role)) return json(res, 401, { ok: false, code: 'unauthorized' });
			const from = /^\d{4}-\d{2}-\d{2}$/.test(url.searchParams.get('from') || '') ? url.searchParams.get('from') : null;
			const to = /^\d{4}-\d{2}-\d{2}$/.test(url.searchParams.get('to') || '') ? url.searchParams.get('to') : null;
			const emp = auth.role === 'employee' ? auth.employee_id : url.searchParams.get('employee_id');
			const out = await sql(`SELECT COALESCE(json_agg(row_to_json(x)), '[]') FROM (
				SELECT employee, totals, days FROM timetrack.fn_timesheet(${lit(emp)},
				       COALESCE(${lit(from)}::date, date_trunc('month', CURRENT_DATE)::date),
				       COALESCE(${lit(to)}::date, CURRENT_DATE), NULL, false)) x`);
			return json(res, 200, { ok: true, data: JSON.parse(out) });
		}

		json(res, 404, { ok: false, code: 'not_found', path });
	} catch (e) {
		// Клиенту — только код: в тексте ошибки psql оказываются SQL-запрос,
		// пути на диске и (при запуске со строкой в argv) строка подключения.
		console.error('[dev-server]', req.method, path, '→', mask(e.message || e));
		json(res, 500, { ok: false, code: 'server_error' });
	}
});

server.listen(PORT, () => console.log(`dev-server: http://localhost:${PORT}/kiosk.html  (БД: ${mask(DB)})`));
