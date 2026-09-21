import {
	WorkflowBuilder, CREDENTIALS, webhook, respondJson, postgres, code, ifNode, setNode, schedule, httpRequest,
	splitOut, authenticate, unauthorized, truthy,
} from '../lib/builder.mjs';

const CFG = "$('Config').first().json";

const EVALUATE_JS = `
// Результат доставки одного события outbox в HR-систему.
const resp = $json;
const src = $('Claim Outbox Batch').item.json;
const status = Number(resp.statusCode ?? 0);
const ok = !resp.error && status >= 200 && status < 300;
let error = null;
if (!ok) {
  const detail = resp.error ? (resp.error.message || JSON.stringify(resp.error)) : JSON.stringify(resp.body ?? '');
  error = ('HTTP ' + status + ' ' + String(detail)).slice(0, 1500);
}
return { json: { outbox_id: src.id, event_kind: src.event_kind, ok, error } };
`;

const VALIDATE_JS = `
// Входящая синхронизация из HR-системы: { employees: [ {...}, ... ] }
const body = $('HR Inbound Webhook').first().json.body || {};
const list = Array.isArray(body.employees) ? body.employees : (Array.isArray(body) ? body : null);
const problems = [];
if (!list) problems.push('employees_array_required');
else if (list.length === 0) problems.push('employees_empty');
else if (list.length > 5000) problems.push('too_many_employees');
const employees = (list || []).map((e) => ({
  employee_id: String(e.employee_id ?? e.id ?? '').trim(),
  full_name: String(e.full_name ?? e.name ?? '').trim(),
  email: e.email ? String(e.email).trim() : null,
  department: e.department ?? null,
  position: e.position ?? null,
  timezone: e.timezone ?? null,
  work_schedule: e.work_schedule && typeof e.work_schedule === 'object' ? e.work_schedule : null,
  hr_external_id: e.hr_external_id != null ? String(e.hr_external_id) : null,
  status: ['active', 'inactive', 'terminated'].includes(e.status) ? e.status : null,
}));
const bad = employees.filter((e) => !/^[A-Za-z0-9._-]{1,64}$/.test(e.employee_id) || e.full_name.length < 2);
if (bad.length) problems.push('invalid_records:' + bad.length);
return [{ json: { ok: problems.length === 0, problems, employees, actor: $input.first().json.client_name } }];
`;

const SUMMARIZE_JS = `
const items = $input.all();
const failed = items.filter((i) => i.json && i.json.error);
return [{ json: {
  ok: failed.length === 0,
  processed: items.length,
  updated: items.length - failed.length,
  failed: failed.length,
  errors: failed.slice(0, 20).map((i) => String(i.json.error && i.json.error.message ? i.json.error.message : i.json.error)),
} }];
`;

export function build() {
	const wf = new WorkflowBuilder({
		name: 'Timetrack 06 — HR System Sync',
		description: 'Исходящая доставка событий в HR-систему (outbox) и входящая синхронизация справочника сотрудников',
		tags: ['timetrack'],
	});

	wf.sticky(
		'## Исходящая синхронизация (outbox → HR-система)\n' +
			'Каждые 15 минут: `fn_outbox_claim()` забирает пачку событий (attendance.created/updated, employee.upserted, consent.revoked), ' +
			'каждое отправляется `POST` на адрес из Config; результат фиксируется `fn_outbox_mark()` (повтор с экспоненциальной паузой, после 10 попыток — dead). ' +
			'Формат payload описан в docs/hr-integration.md. Для другой HR-системы замените ноду Push To HR System (например, на ноду BambooHR/Personio/1C HTTP).',
		{ pos: [0, -2.4], width: 1500, height: 200 },
	);
	wf.sticky(
		'## Входящая синхронизация (HR-система → справочник)\n' +
			'`POST /webhook/timetrack/hr/employees` (HR/system-токен) с `{ "employees": [ { employee_id, full_name, email, department, position, timezone, work_schedule, hr_external_id, status } ] }`. ' +
			'Каждая запись проходит через `fn_upsert_employee()`; статус `terminated` запускает удаление биометрии по политике хранения (воркфлоу 07).',
		{ pos: [0, 2.2], width: 1500, height: 170, color: 5 },
	);

	// ---------- outbox ----------
	wf.add(schedule('Sync Trigger', { cron: '*/15 * * * *', pos: [0, 0] }));
	wf.add(
		setNode('Config', {
			pos: [1, 0],
			fields: { hrSystemUrl: 'https://hr.example.com/api/timetrack/events', batchSize: 100, maxAttempts: 10 },
			notes: 'URL приёмника событий в HR-системе. Аутентификация — credential "HR System API" (заголовок).',
		}),
	);
	wf.add(
		postgres('Claim Outbox Batch', {
			pos: [2, 0],
			query: 'SELECT id, event_kind, entity_type, entity_id, payload, attempts, created_at FROM timetrack.fn_outbox_claim($1::int)',
			params: `={{ [ ${CFG}.batchSize ] }}`,
		}),
	);
	wf.add(
		httpRequest('Push To HR System', {
			pos: [3, 0],
			method: 'POST',
			url: `={{ ${CFG}.hrSystemUrl }}`,
			auth: { type: 'httpHeaderAuth', credential: CREDENTIALS.hrApi },
			body: {
				contentType: 'json',
				json:
					'={{ ({ id: $json.id, kind: $json.event_kind, entity_type: $json.entity_type, entity_id: $json.entity_id, ' +
					'created_at: $json.created_at, attempt: $json.attempts, data: $json.payload }) }}',
			},
			batching: { batchSize: 10, batchInterval: 500 },
			retry: false,
		}),
	);
	wf.add(code('Evaluate Delivery', { pos: [4, 0], js: EVALUATE_JS, mode: 'runOnceForEachItem' }));
	wf.add(
		postgres('Mark Outbox', {
			pos: [5, 0],
			batching: 'independently',
			query: 'SELECT timetrack.fn_outbox_mark($1::bigint, $2::boolean, $3, $4::int) AS marked',
			params: `={{ [ $json.outbox_id, $json.ok === true, $json.error ?? null, ${CFG}.maxAttempts ] }}`,
		}),
	);
	wf.chain('Sync Trigger', 'Config', 'Claim Outbox Batch', 'Push To HR System', 'Evaluate Delivery', 'Mark Outbox');

	// ---------- inbound ----------
	wf.add(webhook('HR Inbound Webhook', { path: 'timetrack/hr/employees', pos: [0, 3.2] }));
	wf.add(authenticate('Authenticate HR Sync', 'HR Inbound Webhook', [1, 3.2]));
	wf.add(ifNode('Is HR System?', { pos: [2, 3.2], conditions: truthy("={{ ['hr', 'system'].includes($json.role ?? '') }}") }));
	wf.add(unauthorized('Respond 401', [3, 4.2]));
	wf.add(code('Validate Payload', { pos: [3, 3.2], js: VALIDATE_JS }));
	wf.add(ifNode('Payload Valid?', { pos: [4, 3.2], conditions: truthy('={{ $json.ok === true }}') }));
	wf.add(
		respondJson('Respond 400', {
			pos: [5, 4.2],
			code: 400,
			body: "={{ ({ ok: false, code: 'validation_failed', problems: $json.problems }) }}",
		}),
	);
	wf.add(splitOut('Split Employees', { field: 'employees', pos: [5, 3.2] }));
	wf.add(
		postgres('Upsert Employee', {
			pos: [6, 3.2],
			batching: 'independently',
			onError: 'continueRegularOutput',
			query:
				'SELECT employee_id, full_name, status, updated_at\n' +
				'  FROM timetrack.fn_upsert_employee($1, $2, $3, $4, $5, $6, $7::jsonb, $8, $9, $10)',
			params:
				'={{ [ $json.employee_id, $json.full_name, $json.email ?? null, $json.department ?? null, $json.position ?? null, ' +
				'$json.timezone ?? null, $json.work_schedule ?? null, $json.hr_external_id ?? null, $json.status ?? null, ' +
				"$('Validate Payload').first().json.actor ?? null ] }}",
		}),
	);
	wf.add(code('Summarize Sync', { pos: [7, 3.2], js: SUMMARIZE_JS }));
	wf.add(respondJson('Respond Sync Result', { pos: [8, 3.2], body: '={{ $json }}' }));
	wf.chain('HR Inbound Webhook', 'Authenticate HR Sync', 'Is HR System?');
	wf.connect('Is HR System?', 'Validate Payload', { output: 0 });
	wf.connect('Is HR System?', 'Respond 401', { output: 1 });
	wf.chain('Validate Payload', 'Payload Valid?');
	wf.connect('Payload Valid?', 'Split Employees', { output: 0 });
	wf.connect('Payload Valid?', 'Respond 400', { output: 1 });
	wf.chain('Split Employees', 'Upsert Employee', 'Summarize Sync', 'Respond Sync Result');

	return wf;
}
