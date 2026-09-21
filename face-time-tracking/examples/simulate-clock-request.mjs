#!/usr/bin/env node
// Моделирует обмен терминала с воркфлоу 02 "Face Clock In/Out" без запуска n8n:
//  * запускает настоящий код нод "Prepare Request" и "Interpret Recognition" из workflows/02-face-clock-in-out.json,
//  * подменяет только HTTP-ответ CompreFace,
//  * вызывает timetrack.fn_clock() в реальной БД (в транзакции с откатом — данные демо не меняются),
//  * печатает запрос терминала и JSON-ответ, который сформировали бы ноды Respond to Webhook.
//   DATABASE_URL=postgres://... node examples/simulate-clock-request.mjs
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const wf = JSON.parse(readFileSync(join(root, 'workflows', '02-face-clock-in-out.json'), 'utf8'));
const jsOf = (name) => wf.nodes.find((n) => n.name === name).parameters.jsCode;
const config = Object.fromEntries(
	wf.nodes.find((n) => n.name === 'Config').parameters.assignments.assignments.map((a) => [a.name, a.value]),
);

function sql(query) {
	const args = ['-X', '-At', '-v', 'ON_ERROR_STOP=1', '-c', query];
	if (process.env.DATABASE_URL) args.unshift(process.env.DATABASE_URL);
	return execFileSync('psql', args, { encoding: 'utf8' }).trim();
}
const lit = (v) => (v === null || v === undefined ? 'NULL' : `'${String(typeof v === 'object' ? JSON.stringify(v) : v).replace(/'/g, "''")}'`);

// эмуляция окружения Code-ноды: $('Node'), $input, this.helpers
async function runCode(name, { nodes, input, helpers = {} }) {
	const $ = (n) => ({ first: () => nodes[n], all: () => [nodes[n]] });
	const $input = { first: () => input, all: () => [input] };
	const fn = new Function('$', '$input', '$json', 'Buffer', `return (async function () {${jsOf(name)}\n}).call(this)`);
	return fn.call({ helpers }, $, $input, input.json, Buffer);
}

const image = Buffer.from('ffd8ffe000104a46494600010100000100010000ffd9', 'hex'); // «снимок» (заглушка JPEG)
const imageHash = createHash('sha256').update(image).digest('hex');

async function scenario(title, { requestBody, comprefaceResponse }) {
	console.log(`\n${'='.repeat(78)}\n${title}\n${'='.repeat(78)}`);
	console.log('→ Терминал:  POST /webhook/timetrack/clock   (multipart/form-data, X-Api-Token: <токен терминала>)');
	console.log('   поля:', JSON.stringify(requestBody), ' image: photo.jpg,', image.length, 'bytes');

	const webhookItem = {
		json: { headers: { 'x-api-token': 'kiosk-token', 'x-forwarded-for': '10.0.0.15' }, params: {}, query: {}, body: requestBody },
		binary: { image: { mimeType: 'image/jpeg', fileName: 'photo.jpg', fileSize: `${image.length} B`, data: image.toString('base64') } },
	};
	const authItem = { json: { client_id: '00000000-0000-0000-0000-000000000001', client_name: 'Kiosk main entrance', role: 'device', employee_id: null, location: 'Проходная' } };

	const [prepared] = await runCode('Prepare Request', { nodes: { 'Clock Webhook': webhookItem }, input: authItem });
	console.log('   n8n Prepare Request →', JSON.stringify({ ok: prepared.json.ok, event_type: prepared.json.event_type, request_id: prepared.json.request_id, device_id: prepared.json.device_id, binary: Object.keys(prepared.binary || {}) }));

	console.log('   n8n Recognize Face → CompreFace POST /api/v1/recognition/recognize  ⇒ HTTP', comprefaceResponse.statusCode, JSON.stringify(comprefaceResponse.body));
	const [interpreted] = await runCode('Interpret Recognition', {
		nodes: { Config: { json: config }, 'Prepare Request': prepared },
		input: { json: comprefaceResponse },
	});
	interpreted.json.image_hash = imageHash; // нода Crypto (Hash Image)
	console.log('   n8n Interpret Recognition →', JSON.stringify({ matched: interpreted.json.matched, code: interpreted.json.code, similarity: interpreted.json.similarity, http_status: interpreted.json.http_status }));

	const r = interpreted.json;
	if (!r.matched) {
		// ветка Log Failed Recognition → Respond Recognition Failed
		console.log(`← Ответ терминалу: HTTP ${r.http_status}`, JSON.stringify({ ok: false, code: r.code, message: r.message, faces_detected: r.faces_detected, request_id: r.request_id }));
		return;
	}
	// нода Record Attendance: тот же порядок аргументов, что в options.queryReplacement воркфлоу
	const meta = { face_probability: r.face_probability, faces_detected: r.faces_detected, client_ip: r.client_ip };
	const row = sql(`BEGIN;
    SELECT row_to_json(x) FROM (
      SELECT ok, code, event_id, event_type, occurred_at, duplicate, employee_id, full_name, timezone
        FROM timetrack.fn_clock(${lit(r.employee_id)}, ${lit(r.event_type)}, 'face', ${lit(r.device_id)}, ${lit(r.location)},
             ${lit(r.similarity)}::numeric, ${lit(r.liveness_score)}::numeric, ${lit(r.image_hash)}, ${lit(r.request_id)},
             ${lit(r.captured_at)}::timestamptz, ${lit(meta)}::jsonb, ${lit(r.client_name)},
             ${config.debounceSeconds}::int, ${config.maxSessionHours}::int, ${config.requireConsent}::boolean) x
    ) x;
    ROLLBACK;`);
	const res = JSON.parse(row.split('\n').find((l) => l.startsWith('{')));
	console.log('   n8n Record Attendance → fn_clock →', JSON.stringify(res));
	if (res.ok) {
		console.log('← Ответ терминалу: HTTP 200', JSON.stringify({ ok: true, code: res.code, duplicate: res.duplicate, employee_id: res.employee_id, full_name: res.full_name, event_type: res.event_type, occurred_at: res.occurred_at, event_id: res.event_id, similarity: r.similarity }));
	} else {
		console.log('← Ответ терминалу: HTTP 403', JSON.stringify({ ok: false, code: res.code, employee_id: res.employee_id }));
	}
}

await scenario('Сценарий A. Сотрудник с согласием (EMP-002) распознан — отметка записана', {
	requestBody: { device_id: 'kiosk-1', location: 'Проходная', request_id: 'sim-0001' },
	comprefaceResponse: { statusCode: 200, body: { result: [{ box: { probability: 0.99971, x_min: 312, y_min: 140, x_max: 540, y_max: 410 }, subjects: [{ subject: 'EMP-002', similarity: 0.98213 }] }] } },
});
await scenario('Сценарий B. Похожее, но чужое лицо: similarity 0.71 < порога 0.90 — отказ, аудит без фото', {
	requestBody: { device_id: 'kiosk-1', request_id: 'sim-0002' },
	comprefaceResponse: { statusCode: 200, body: { result: [{ box: { probability: 0.9991 }, subjects: [{ subject: 'EMP-001', similarity: 0.71044 }] }] } },
});
await scenario('Сценарий C. На снимке нет лица (терминал сработал на тень)', {
	requestBody: { device_id: 'kiosk-1', request_id: 'sim-0003' },
	comprefaceResponse: { statusCode: 400, body: { message: 'No face is found in the given image', code: 28 } },
});
await scenario('Сценарий D. Терминал передал employee_id=EMP-001, а лицо принадлежит EMP-002 — защита от подмены', {
	requestBody: { device_id: 'kiosk-1', request_id: 'sim-0004', employee_id: 'EMP-001' },
	comprefaceResponse: { statusCode: 200, body: { result: [{ box: { probability: 0.9995 }, subjects: [{ subject: 'EMP-002', similarity: 0.97 }] }] } },
});
await scenario('Сценарий E. Сотрудник без действующего согласия (EMP-003) — CompreFace его не знает, но даже при совпадении fn_clock откажет', {
	requestBody: { device_id: 'kiosk-1', request_id: 'sim-0005' },
	comprefaceResponse: { statusCode: 200, body: { result: [{ box: { probability: 0.9995 }, subjects: [{ subject: 'EMP-003', similarity: 0.95 }] }] } },
});
