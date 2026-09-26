import {
	WorkflowBuilder, CREDENTIALS, webhook, respondJson, postgres, code, ifNode, setNode,
	httpRequest, cryptoHashBinary, authenticate, unauthorized, truthy,
} from '../lib/builder.mjs';

const CFG = "$('Config').first().json";

const VALIDATE_JS = `
// Проверка данных регистрации сотрудника и снимка лица.
const hook = $('Enroll Webhook').first();
const auth = $input.first().json;
const body = hook.json.body || {};
const problems = [];

const employeeId = String(body.employee_id ?? '').trim();
if (!/^[A-Za-z0-9._-]{1,64}$/.test(employeeId)) problems.push('employee_id_invalid');
const fullName = String(body.full_name ?? '').trim();
if (fullName.length < 2) problems.push('full_name_required');
const email = body.email ? String(body.email).trim() : null;
if (email && !/^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$/.test(email)) problems.push('email_invalid');

// согласие на обработку биометрии обязательно (GDPR ст. 9, 152-ФЗ ст. 11)
const consent = body.consent_granted === true || String(body.consent_granted).toLowerCase() === 'true';
if (!consent) problems.push('consent_required');

let schedule = null;
if (body.work_schedule) {
  try {
    schedule = typeof body.work_schedule === 'string' ? JSON.parse(body.work_schedule) : body.work_schedule;
    const okShape = schedule && typeof schedule === 'object'
      && /^\\d{2}:\\d{2}$/.test(schedule.start) && /^\\d{2}:\\d{2}$/.test(schedule.end)
      && Array.isArray(schedule.days) && schedule.days.every((d) => Number.isInteger(d) && d >= 1 && d <= 7);
    if (!okShape) problems.push('work_schedule_invalid');
  } catch (e) {
    problems.push('work_schedule_invalid');
  }
}

const binary = hook.binary || {};
let image = binary.image || Object.values(binary)[0];
if (!image && typeof body.image_base64 === 'string' && body.image_base64.length > 0) {
  const buffer = Buffer.from(body.image_base64.replace(/^data:[^;]+;base64,/, ''), 'base64');
  if (buffer.length > 0) {
    image = await this.helpers.prepareBinaryData(buffer, 'enroll.jpg', body.image_mime || 'image/jpeg');
  }
}
if (!image) problems.push('image_missing');

return [{
  json: {
    ok: problems.length === 0,
    problems,
    employee_id: employeeId,
    full_name: fullName,
    email,
    department: body.department ? String(body.department).trim() : null,
    position: body.position ? String(body.position).trim() : null,
    timezone: body.timezone ? String(body.timezone).trim() : null,
    work_schedule: schedule,
    hr_external_id: body.hr_external_id ? String(body.hr_external_id) : null,
    consent_via: body.consent_via ? String(body.consent_via) : 'api',
    consent_document_ref: body.consent_document_ref ? String(body.consent_document_ref) : null,
    actor: auth.client_name,
  },
  binary: image ? { image } : undefined,
}];
`;

const ATTACH_JS = `
// Postgres-нода отдаёт только колонки запроса и теряет binary, поэтому снимок и
// остальные поля (в том числе actor для аудита) возвращаются из шага валидации.
const validated = $('Validate Enrollment').first();
const info = { ...validated.json, ...$input.first().json };
return [{ json: info, binary: validated.binary }];
`;

const INTERPRET_JS = `
// Ответ CompreFace POST /api/v1/recognition/faces?subject=...
const info = $('Attach Image').first();
const resp = $input.first().json;
const status = Number(resp.statusCode ?? 0);
const body = resp.body ?? {};
const out = { ...info.json, ok: false, code: null, http_status: 200, message: '', face_id: null, subject: null };
if (resp.error || status === 0 || status >= 500) {
  out.code = 'face_service_unavailable'; out.http_status = 502;
  out.message = 'Сервис распознавания недоступен' + (status ? ' (HTTP ' + status + ')' : '');
} else if (status === 400 && (body.code === 28 || /no face/i.test(body.message || ''))) {
  out.code = 'no_face'; out.http_status = 422; out.message = 'На снимке не найдено лицо — нужен фронтальный снимок';
} else if (status === 401 || status === 403) {
  out.code = 'face_service_auth'; out.http_status = 502; out.message = 'Неверный API-ключ сервиса распознавания';
} else if (status === 200 || status === 201) {
  out.ok = true; out.code = 'enrolled';
  out.face_id = body.image_id ?? null;
  out.subject = body.subject ?? info.json.employee_id;
} else {
  out.code = 'face_service_error'; out.http_status = 502; out.message = body.message || ('HTTP ' + status);
}
return [{ json: out, binary: info.binary }];
`;

export function build() {
	const wf = new WorkflowBuilder({
		name: 'Timetrack 01 — Employee Enrollment',
		description: 'Регистрация сотрудника и его лица (с фиксацией согласия), отзыв биометрии',
		tags: ['timetrack'],
	});

	wf.sticky(
		'## Регистрация сотрудника и лица\n' +
			'`POST /webhook/timetrack/employees/enroll` — заголовок `X-Api-Token` (HR-токен). Тело (multipart или JSON): ' +
			'`employee_id`, `full_name`, `email`, `department`, `position`, `timezone`, `work_schedule`, `hr_external_id`, ' +
			'`consent_granted=true` (обязательно), `consent_document_ref`, снимок `image` (или `image_base64`).\n\n' +
			'Поток: аутентификация HR → валидация и проверка согласия → upsert сотрудника + запись согласия (БД) → ' +
			'загрузка лица в CompreFace (subject = employee_id) → запись регистрации (только ссылка на шаблон и хэш снимка).',
		{ pos: [0, -2.4], width: 1500, height: 230 },
	);
	wf.sticky(
		'## Отзыв биометрии (право на удаление)\n' +
			'`POST /webhook/timetrack/biometrics/revoke` — тело `{ "employee_id": "...", "reason": "..." }`. ' +
			'Разрешено HR-токену и самому сотруднику (его личным токеном). Удаляет шаблоны в CompreFace, деактивирует регистрации и отзывает согласие. ' +
			'После отзыва отметка по лицу отклоняется (`consent_missing`), ручная отметка продолжает работать.',
		{ pos: [0, 2.2], width: 1200, height: 170, color: 5 },
	);

	wf.add(webhook('Enroll Webhook', { path: 'timetrack/employees/enroll', pos: [0, 0] }));
	wf.add(
		setNode('Config', {
			pos: [1, 0],
			notes: 'Адрес CompreFace, порог детекции при регистрации, версия текста согласия.',
			fields: { faceApiUrl: 'http://compreface-api:8080', detProbThreshold: 0.9, consentVersion: 'v1.0', provider: 'compreface' },
		}),
	);
	wf.add(authenticate('Authenticate HR', 'Enroll Webhook', [2, 0]));
	wf.add(ifNode('Is HR?', { pos: [3, 0], conditions: truthy("={{ ['hr', 'system'].includes($json.role ?? '') }}") }));
	wf.add(unauthorized('Respond 401', [4, 1]));
	wf.add(code('Validate Enrollment', { pos: [4, 0], js: VALIDATE_JS }));
	wf.add(ifNode('Valid?', { pos: [5, 0], conditions: truthy('={{ $json.ok === true }}') }));
	wf.add(
		respondJson('Respond 400', {
			pos: [6, 1],
			code: 400,
			body: "={{ ({ ok: false, code: 'validation_failed', problems: $json.problems }) }}",
		}),
	);
	wf.add(
		postgres('Upsert Employee And Consent', {
			pos: [6, 0],
			notes: 'fn_upsert_employee + fn_grant_consent в одной транзакции. Согласие фиксируется до загрузки биометрии.',
			query:
				'WITH e AS (\n' +
				"  SELECT * FROM timetrack.fn_upsert_employee($1, $2, $3, $4, $5, $6, $7::jsonb, $8, 'active', $9)\n" +
				'), c AS (\n' +
				'  SELECT timetrack.fn_grant_consent(e.employee_id, $10, $11, $12, $9) AS consent_id FROM e\n' +
				')\n' +
				'SELECT e.employee_id, e.full_name, e.email, e.timezone, c.consent_id FROM e, c',
			params:
				'={{ [ $json.employee_id, $json.full_name, $json.email ?? null, $json.department ?? null, $json.position ?? null, ' +
				'$json.timezone ?? null, $json.work_schedule ?? null, $json.hr_external_id ?? null, $json.actor ?? null, ' +
				`${CFG}.consentVersion, $json.consent_via ?? null, $json.consent_document_ref ?? null ] }}`,
		}),
	);
	wf.add(code('Attach Image', { pos: [7, 0], js: ATTACH_JS }));
	wf.add(
		httpRequest('Register Face', {
			pos: [8, 0],
			method: 'POST',
			url: `={{ ${CFG}.faceApiUrl }}/api/v1/recognition/faces`,
			auth: { type: 'httpHeaderAuth', credential: CREDENTIALS.faceApi },
			query: [
				{ name: 'subject', value: '={{ $json.employee_id }}' },
				{ name: 'det_prob_threshold', value: `={{ ${CFG}.detProbThreshold }}` },
			],
			body: {
				contentType: 'multipart-form-data',
				parameters: [{ parameterType: 'formBinaryData', name: 'file', inputDataFieldName: 'image' }],
			},
			notes: 'Добавляет пример лица к subject = employee_id (subject создаётся автоматически).',
		}),
	);
	wf.add(code('Interpret Registration', { pos: [9, 0], js: INTERPRET_JS }));
	wf.add(cryptoHashBinary('Hash Enrollment Image', { pos: [10, 0] }));
	wf.add(ifNode('Registered?', { pos: [11, 0], conditions: truthy('={{ $json.ok === true }}') }));
	wf.add(
		postgres('Record Enrollment', {
			pos: [12, 0],
			query: 'SELECT timetrack.fn_record_enrollment($1, $2, $3, $4, $5, $6) AS enrollment_id',
			params:
				`={{ [ $json.employee_id, ${CFG}.provider, $json.subject ?? $json.employee_id, $json.face_id ?? null, ` +
				'$json.image_hash ?? null, $json.actor ?? null ] }}',
		}),
	);
	wf.add(
		respondJson('Respond Enrolled', {
			pos: [13, 0],
			code: 201,
			body:
				"={{ ({ ok: true, code: 'enrolled', employee_id: $('Interpret Registration').first().json.employee_id, " +
				"full_name: $('Interpret Registration').first().json.full_name, enrollment_id: $json.enrollment_id, " +
				"face_id: $('Interpret Registration').first().json.face_id, consent_id: $('Upsert Employee And Consent').first().json.consent_id }) }}",
		}),
	);
	wf.add(
		respondJson('Respond Registration Failed', {
			pos: [12, 1],
			code: '={{ $json.http_status }}',
			body:
				'={{ ({ ok: false, code: $json.code, message: $json.message, employee_id: $json.employee_id, ' +
				"note: 'Сотрудник и согласие сохранены; повторите загрузку снимка' }) }}",
		}),
	);

	wf.chain('Enroll Webhook', 'Config', 'Authenticate HR', 'Is HR?');
	wf.connect('Is HR?', 'Validate Enrollment', { output: 0 });
	wf.connect('Is HR?', 'Respond 401', { output: 1 });
	wf.chain('Validate Enrollment', 'Valid?');
	wf.connect('Valid?', 'Upsert Employee And Consent', { output: 0 });
	wf.connect('Valid?', 'Respond 400', { output: 1 });
	wf.chain('Upsert Employee And Consent', 'Attach Image', 'Register Face', 'Interpret Registration', 'Hash Enrollment Image', 'Registered?');
	wf.connect('Registered?', 'Record Enrollment', { output: 0 });
	wf.connect('Registered?', 'Respond Registration Failed', { output: 1 });
	wf.chain('Record Enrollment', 'Respond Enrolled');

	// ---------- отзыв биометрии ----------
	wf.add(webhook('Revoke Webhook', { path: 'timetrack/biometrics/revoke', pos: [0, 3.2] }));
	wf.add(
		setNode('Config (revoke)', {
			pos: [1, 3.2],
			fields: { faceApiUrl: 'http://compreface-api:8080' },
		}),
	);
	wf.add(authenticate('Authenticate Revoke', 'Revoke Webhook', [2, 3.2]));
	wf.add(
		ifNode('Can Revoke?', {
			pos: [3, 3.2],
			conditions: truthy(
				"={{ ['hr', 'system'].includes($json.role ?? '') || ($json.role === 'employee' && $json.employee_id === String($('Revoke Webhook').first().json.body?.employee_id ?? '')) }}",
			),
		}),
	);
	wf.add(unauthorized('Respond 401 (revoke)', [4, 4.2]));
	wf.add(
		httpRequest('Delete Face Templates', {
			pos: [4, 3.2],
			method: 'DELETE',
			url:
				"={{ $('Config (revoke)').first().json.faceApiUrl }}/api/v1/recognition/subjects/" +
				"{{ encodeURIComponent(String($('Revoke Webhook').first().json.body?.employee_id ?? '')) }}",
			auth: { type: 'httpHeaderAuth', credential: CREDENTIALS.faceApi },
			notes: 'Удаляет subject со всеми примерами лица. 404 (subject уже нет) считается успехом.',
		}),
	);
	wf.add(
		ifNode('Templates Deleted?', {
			pos: [5, 3.2],
			conditions: truthy('={{ [200, 404].includes(Number($json.statusCode ?? 0)) }}'),
		}),
	);
	wf.add(
		postgres('Revoke In Database', {
			pos: [6, 3.2],
			query: 'SELECT enrollments_deactivated, consents_revoked FROM timetrack.fn_revoke_biometrics($1, $2, $3, $4)',
			params:
				"={{ [ String($('Revoke Webhook').first().json.body?.employee_id ?? ''), " +
				"$('Revoke Webhook').first().json.body?.reason ?? 'revoke_request', " +
				"$('Authenticate Revoke').first().json.client_name ?? null, $('Authenticate Revoke').first().json.role ?? null ] }}",
		}),
	);
	wf.add(
		respondJson('Respond Revoked', {
			pos: [7, 3.2],
			body:
				"={{ ({ ok: true, code: 'revoked', employee_id: String($('Revoke Webhook').first().json.body?.employee_id ?? ''), " +
				'enrollments_deactivated: $json.enrollments_deactivated, consents_revoked: $json.consents_revoked, ' +
				"face_service_status: $('Delete Face Templates').first().json.statusCode ?? null }) }}",
		}),
	);
	wf.add(
		respondJson('Respond Revoke Failed', {
			pos: [6, 4.2],
			code: 502,
			body:
				"={{ ({ ok: false, code: 'face_service_error', message: 'Не удалось удалить шаблоны в сервисе распознавания; данные в БД не изменены', " +
				'face_service_status: $json.statusCode ?? null }) }}',
		}),
	);
	wf.chain('Revoke Webhook', 'Config (revoke)', 'Authenticate Revoke', 'Can Revoke?');
	wf.connect('Can Revoke?', 'Delete Face Templates', { output: 0 });
	wf.connect('Can Revoke?', 'Respond 401 (revoke)', { output: 1 });
	wf.chain('Delete Face Templates', 'Templates Deleted?');
	wf.connect('Templates Deleted?', 'Revoke In Database', { output: 0 });
	wf.connect('Templates Deleted?', 'Respond Revoke Failed', { output: 1 });
	wf.chain('Revoke In Database', 'Respond Revoked');

	return wf;
}
