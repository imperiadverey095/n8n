import {
	WorkflowBuilder, CREDENTIALS, webhook, respondJson, postgres, code, ifNode, setNode,
	httpRequest, cryptoHashBinary, authenticate, unauthorized, truthy,
} from '../lib/builder.mjs';

const CFG = "$('Config').first().json";

const PREPARE_REQUEST_JS = `
// Собирает запрос терминала: метаданные + изображение в binary-поле "image".
// Фото НЕ попадает в JSON (кроме случая, когда клиент прислал image_base64) —
// рекомендуемый способ загрузки: multipart/form-data, поле "image".
const hook = $('Clock Webhook').first();
const auth = $input.first().json;
const body = hook.json.body || {};
const headers = hook.json.headers || {};
const problems = [];

const binary = hook.binary || {};
let image = binary.image || Object.values(binary)[0];
if (!image && typeof body.image_base64 === 'string' && body.image_base64.length > 0) {
  const b64 = body.image_base64.replace(/^data:[^;]+;base64,/, '');
  const buffer = Buffer.from(b64, 'base64');
  if (buffer.length > 0) {
    image = await this.helpers.prepareBinaryData(buffer, 'capture.jpg', body.image_mime || 'image/jpeg');
  }
}
if (!image) problems.push('image_missing');
if (image && image.mimeType && !/^image\\//.test(image.mimeType)) problems.push('not_an_image');

const eventType = ['check_in', 'check_out', 'auto'].includes(body.event_type) ? body.event_type : 'auto';
const capturedAt = body.captured_at && !Number.isNaN(Date.parse(body.captured_at))
  ? new Date(body.captured_at).toISOString()
  : null;
const liveness = Number(body.liveness_score);

return [{
  json: {
    ok: problems.length === 0,
    code: problems.length ? 'bad_request' : null,
    http_status: problems.length ? 400 : 200,
    message: problems.length ? 'Некорректный запрос: ' + problems.join(', ') : '',
    problems,
    client_id: auth.client_id,
    client_name: auth.client_name,
    client_role: auth.role,
    device_id: body.device_id || auth.client_name || null,
    location: body.location || auth.location || null,
    event_type: eventType,
    employee_id_hint: body.employee_id ? String(body.employee_id) : null,
    request_id: body.request_id || headers['idempotency-key'] || null,
    captured_at: capturedAt,
    liveness_score: Number.isFinite(liveness) ? liveness : null,
    client_ip: headers['x-forwarded-for'] || headers['x-real-ip'] || null,
  },
  binary: image ? { image } : undefined,
}];
`;

const INTERPRET_JS = `
// Разбирает ответ CompreFace /api/v1/recognition/recognize и принимает решение.
const cfg = $('Config').first().json;
const req = $('Prepare Request').first();
const resp = $input.first().json;
const status = Number(resp.statusCode ?? 0);
const body = resp.body ?? {};
const out = {
  ...req.json,
  matched: false, code: null, http_status: 200, message: '',
  employee_id: null, similarity: null, face_probability: null, faces_detected: 0,
};

if (resp.error || status === 0 || status >= 500) {
  out.code = 'face_service_unavailable'; out.http_status = 502;
  out.message = 'Сервис распознавания недоступен' + (status ? ' (HTTP ' + status + ')' : '');
} else if (status === 400 && (body.code === 28 || /no face/i.test(body.message || ''))) {
  out.code = 'no_face'; out.http_status = 422; out.message = 'На снимке не найдено лицо';
} else if (status === 401 || status === 403) {
  out.code = 'face_service_auth'; out.http_status = 502; out.message = 'Неверный API-ключ сервиса распознавания';
} else if (status !== 200) {
  out.code = 'face_service_error'; out.http_status = 502; out.message = body.message || ('HTTP ' + status);
} else {
  const results = Array.isArray(body.result) ? body.result : [];
  out.faces_detected = results.length;
  if (results.length === 0) {
    out.code = 'no_face'; out.http_status = 422; out.message = 'На снимке не найдено лицо';
  } else if (results.length > 1 && !cfg.allowMultipleFaces) {
    out.code = 'multiple_faces'; out.http_status = 422; out.message = 'На снимке несколько лиц';
  } else {
    // берём лицо с максимальной вероятностью детекции
    const best = results.slice().sort((a, b) => (b.box?.probability ?? 0) - (a.box?.probability ?? 0))[0];
    out.face_probability = best.box?.probability ?? null;
    const subject = (best.subjects || [])[0];
    if (!subject) {
      out.code = 'unknown_face'; out.http_status = 404; out.message = 'Лицо не зарегистрировано';
    } else if (Number(subject.similarity) < Number(cfg.similarityThreshold)) {
      out.code = 'low_similarity'; out.http_status = 404; out.similarity = Number(subject.similarity);
      out.message = 'Недостаточная схожесть лица';
    } else {
      out.matched = true; out.code = 'matched';
      out.employee_id = String(subject.subject);
      out.similarity = Number(subject.similarity);
    }
  }
}

// защита от подмены: терминал передал employee_id, а лицо принадлежит другому
if (out.matched && out.employee_id_hint && out.employee_id_hint !== out.employee_id) {
  out.matched = false; out.code = 'employee_mismatch'; out.http_status = 403;
  out.message = 'Лицо не соответствует указанному сотруднику';
}

return [{ json: out, binary: req.binary }];
`;

export function build() {
	const wf = new WorkflowBuilder({
		name: 'Timetrack 02 — Face Clock In/Out',
		description: 'Отметка прихода/ухода по фото (CompreFace) и ручная отметка по личному токену',
		tags: ['timetrack'],
	});

	wf.sticky(
		'## Отметка прихода/ухода по лицу\n' +
			'`POST /webhook/timetrack/clock` — заголовок `X-Api-Token` (токен терминала), тело: multipart `image` ' +
			'(или JSON `image_base64`), опционально `event_type` (check_in|check_out|auto), `request_id`, `device_id`, `location`, `captured_at`, `employee_id`.\n\n' +
			'Поток: аутентификация терминала → подготовка снимка → распознавание (CompreFace) → проверка порога схожести → ' +
			'`timetrack.fn_clock()` (согласие, антидребезг, чередование приход/уход, идемпотентность) → ответ.\n\n' +
			'Фото не сохраняется: в БД пишется только sha256-хэш снимка и оценка схожести.',
		{ pos: [0, -2.4], width: 1500, height: 240 },
	);
	wf.sticky(
		'## Ручная отметка (без биометрии)\n' +
			'`POST /webhook/timetrack/clock/manual` — заголовок `X-Api-Token` (личный токен сотрудника), тело: `event_type`, `request_id`.\n' +
			'Альтернатива для сотрудников, не давших согласие на биометрию, и на случай сбоя терминала. ' +
			'HR-токен может отмечать другого сотрудника, передав `employee_id`.',
		{ pos: [0, 2.2], width: 1200, height: 160, color: 5 },
	);

	// ---------- основная цепочка ----------
	wf.add(webhook('Clock Webhook', { path: 'timetrack/clock', pos: [0, 0] }));
	wf.add(
		setNode('Config', {
			pos: [1, 0],
			notes: 'Настройки: адрес CompreFace, пороги, антидребезг. Меняйте здесь.',
			fields: {
				faceApiUrl: 'http://compreface-api:8080',
				similarityThreshold: 0.9,
				detProbThreshold: 0.85,
				debounceSeconds: 120,
				maxSessionHours: 16,
				allowMultipleFaces: false,
				requireConsent: true,
			},
		}),
	);
	wf.add(authenticate('Authenticate Client', 'Clock Webhook', [2, 0]));
	wf.add(
		ifNode('Is Authenticated?', {
			pos: [3, 0],
			conditions: truthy("={{ ['device', 'system', 'hr'].includes($json.role ?? '') }}"),
		}),
	);
	wf.add(unauthorized('Respond 401', [4, 1]));
	wf.add(code('Prepare Request', { pos: [4, 0], js: PREPARE_REQUEST_JS }));
	wf.add(ifNode('Has Image?', { pos: [5, 0], conditions: truthy('={{ $json.ok === true }}') }));
	wf.add(
		respondJson('Respond Bad Request', {
			pos: [6, 1],
			code: 400,
			body: '={{ ({ ok: false, code: $json.code, message: $json.message, problems: $json.problems }) }}',
		}),
	);
	wf.add(
		httpRequest('Recognize Face', {
			pos: [6, 0],
			method: 'POST',
			url: `={{ ${CFG}.faceApiUrl }}/api/v1/recognition/recognize`,
			auth: { type: 'httpHeaderAuth', credential: CREDENTIALS.faceApi },
			query: [
				{ name: 'limit', value: '1' },
				{ name: 'prediction_count', value: '1' },
				{ name: 'det_prob_threshold', value: `={{ ${CFG}.detProbThreshold }}` },
			],
			body: {
				contentType: 'multipart-form-data',
				parameters: [{ parameterType: 'formBinaryData', name: 'file', inputDataFieldName: 'image' }],
			},
			notes: 'CompreFace Recognition API. Ключ — в credential "CompreFace Recognition API Key" (заголовок x-api-key).',
		}),
	);
	wf.add(code('Interpret Recognition', { pos: [7, 0], js: INTERPRET_JS }));
	wf.add(cryptoHashBinary('Hash Image', { pos: [8, 0] }));
	wf.add(ifNode('Face Matched?', { pos: [9, 0], conditions: truthy('={{ $json.matched === true }}') }));

	wf.add(
		postgres('Record Attendance', {
			pos: [10, 0],
			notes: 'timetrack.fn_clock(): согласие, антидребезг, чередование приход/уход, идемпотентность, аудит.',
			query:
				'SELECT ok, code, event_id, event_type, occurred_at, duplicate, employee_id, full_name, timezone\n' +
				"  FROM timetrack.fn_clock($1, $2, 'face', $3, $4, $5::numeric, $6::numeric, $7, $8,\n" +
				'                          $9::timestamptz, $10::jsonb, $11, $12::int, $13::int, $14::boolean)',
			params:
				'={{ [ $json.employee_id, $json.event_type, $json.device_id ?? null, $json.location ?? null, ' +
				'$json.similarity ?? null, $json.liveness_score ?? null, $json.image_hash ?? null, $json.request_id ?? null, ' +
				'$json.captured_at ?? null, ' +
				'({ face_probability: $json.face_probability ?? null, faces_detected: $json.faces_detected ?? 0, client_ip: $json.client_ip ?? null }), ' +
				`$json.client_name ?? null, ${CFG}.debounceSeconds, ${CFG}.maxSessionHours, ${CFG}.requireConsent ] }}`,
		}),
	);
	wf.add(
		postgres('Log Failed Recognition', {
			pos: [10, 1],
			notes: 'Неуспешные попытки пишутся в audit_log без фото: код, схожесть, хэш снимка.',
			query: "SELECT timetrack.fn_audit($1, 'device', 'recognition.failed', 'device', $2, $3::jsonb, $4) AS audit_id",
			params:
				'={{ [ $json.client_name ?? null, $json.device_id ?? null, ' +
				'({ code: $json.code, similarity: $json.similarity ?? null, faces_detected: $json.faces_detected ?? 0, ' +
				'image_hash: $json.image_hash ?? null, request_id: $json.request_id ?? null, employee_id_hint: $json.employee_id_hint ?? null }), ' +
				'$json.client_ip ?? null ] }}',
		}),
	);
	wf.add(
		respondJson('Respond Recognition Failed', {
			pos: [11, 1],
			code: "={{ $('Interpret Recognition').first().json.http_status }}",
			body:
				"={{ ({ ok: false, code: $('Interpret Recognition').first().json.code, " +
				"message: $('Interpret Recognition').first().json.message, " +
				"faces_detected: $('Interpret Recognition').first().json.faces_detected, " +
				"request_id: $('Interpret Recognition').first().json.request_id }) }}",
		}),
	);
	wf.add(ifNode('Clock Accepted?', { pos: [11, 0], conditions: truthy('={{ $json.ok === true }}') }));
	wf.add(
		respondJson('Respond Success', {
			pos: [12, 0],
			body:
				'={{ ({ ok: true, code: $json.code, duplicate: $json.duplicate, employee_id: $json.employee_id, ' +
				'full_name: $json.full_name, event_type: $json.event_type, occurred_at: $json.occurred_at, ' +
				"event_id: $json.event_id, similarity: $('Interpret Recognition').first().json.similarity }) }}",
		}),
	);
	wf.add(
		respondJson('Respond Rejected', {
			pos: [12, 1],
			code: 403,
			body: '={{ ({ ok: false, code: $json.code, employee_id: $json.employee_id, message: ' +
				"({ consent_missing: 'Нет действующего согласия на обработку биометрии', employee_inactive: 'Сотрудник неактивен', " +
				"employee_not_found: 'Сотрудник не найден' })[$json.code] || $json.code }) }}",
		}),
	);

	wf.chain('Clock Webhook', 'Config', 'Authenticate Client', 'Is Authenticated?');
	wf.connect('Is Authenticated?', 'Prepare Request', { output: 0 });
	wf.connect('Is Authenticated?', 'Respond 401', { output: 1 });
	wf.chain('Prepare Request', 'Has Image?');
	wf.connect('Has Image?', 'Recognize Face', { output: 0 });
	wf.connect('Has Image?', 'Respond Bad Request', { output: 1 });
	wf.chain('Recognize Face', 'Interpret Recognition', 'Hash Image', 'Face Matched?');
	wf.connect('Face Matched?', 'Record Attendance', { output: 0 });
	wf.connect('Face Matched?', 'Log Failed Recognition', { output: 1 });
	wf.chain('Log Failed Recognition', 'Respond Recognition Failed');
	wf.chain('Record Attendance', 'Clock Accepted?');
	wf.connect('Clock Accepted?', 'Respond Success', { output: 0 });
	wf.connect('Clock Accepted?', 'Respond Rejected', { output: 1 });

	// ---------- ручная отметка ----------
	wf.add(webhook('Manual Clock Webhook', { path: 'timetrack/clock/manual', pos: [0, 3.2] }));
	wf.add(authenticate('Authenticate Employee', 'Manual Clock Webhook', [1, 3.2]));
	wf.add(
		ifNode('Is Employee Token?', {
			pos: [2, 3.2],
			conditions: truthy(
				"={{ $json.role === 'employee' || (['hr', 'system'].includes($json.role ?? '') && !!$('Manual Clock Webhook').first().json.body?.employee_id) }}",
			),
		}),
	);
	wf.add(unauthorized('Respond 401 (manual)', [3, 4.2]));
	wf.add(
		postgres('Record Manual Attendance', {
			pos: [3, 3.2],
			query:
				'SELECT ok, code, event_id, event_type, occurred_at, duplicate, employee_id, full_name, timezone\n' +
				"  FROM timetrack.fn_clock($1, $2, 'manual', NULL, $3, NULL, NULL, NULL, $4, NULL, $5::jsonb, $6, $7::int, $8::int, false)",
			params:
				"={{ [ ($json.role === 'employee' ? $json.employee_id : String($('Manual Clock Webhook').first().json.body.employee_id)), " +
				"$('Manual Clock Webhook').first().json.body?.event_type ?? 'auto', " +
				"$('Manual Clock Webhook').first().json.body?.location ?? null, " +
				"$('Manual Clock Webhook').first().json.body?.request_id ?? null, " +
				"({ note: $('Manual Clock Webhook').first().json.body?.note ?? null, via: 'manual_api', by_role: $json.role }), " +
				'$json.client_name ?? null, 60, 16 ] }}',
		}),
	);
	wf.add(ifNode('Manual Accepted?', { pos: [4, 3.2], conditions: truthy('={{ $json.ok === true }}') }));
	wf.add(
		respondJson('Respond Manual Success', {
			pos: [5, 3.2],
			body:
				'={{ ({ ok: true, code: $json.code, duplicate: $json.duplicate, employee_id: $json.employee_id, ' +
				'full_name: $json.full_name, event_type: $json.event_type, occurred_at: $json.occurred_at, event_id: $json.event_id }) }}',
		}),
	);
	wf.add(
		respondJson('Respond Manual Rejected', {
			pos: [5, 4.2],
			code: 403,
			body: '={{ ({ ok: false, code: $json.code, employee_id: $json.employee_id }) }}',
		}),
	);
	wf.chain('Manual Clock Webhook', 'Authenticate Employee', 'Is Employee Token?');
	wf.connect('Is Employee Token?', 'Record Manual Attendance', { output: 0 });
	wf.connect('Is Employee Token?', 'Respond 401 (manual)', { output: 1 });
	wf.chain('Record Manual Attendance', 'Manual Accepted?');
	wf.connect('Manual Accepted?', 'Respond Manual Success', { output: 0 });
	wf.connect('Manual Accepted?', 'Respond Manual Rejected', { output: 1 });

	return wf;
}
