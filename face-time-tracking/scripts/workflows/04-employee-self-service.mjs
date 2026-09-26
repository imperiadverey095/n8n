import {
	WorkflowBuilder, webhook, respondJson, respondFirstItem, respondAllItems, postgres, ifNode, setNode, email,
	authenticate, unauthorized, truthy,
} from '../lib/builder.mjs';

const CFG = "$('Config').first().json";
const CFG_R = "$('Config (review)').first().json";

// Время в письмах — в привычном формате и с явным указанием пояса: сотрудник и
// кадровик могут сидеть в разных зонах, и «13:02» без пояса порождает споры.
const LOCAL_TIME =
	'((t, z) => t ? DateTime.fromISO(t).setZone(z).toFormat("dd.MM.yyyy HH:mm") + " (" + z + ")" : "—")';

export function build() {
	const wf = new WorkflowBuilder({
		name: 'Timetrack 04 — Employee Self-Service',
		description: 'Личный кабинет: просмотр своих отметок, запросы на корректировку, рассмотрение HR',
		tags: ['timetrack'],
	});

	wf.sticky(
		'## Самообслуживание сотрудника\n' +
			'* `GET /webhook/timetrack/me/records?from=&to=` — свои дни, сессии, корректировки (личный токен).\n' +
			'* `POST /webhook/timetrack/me/corrections` — `{ action: add|change|void, event_id, requested_type, requested_time, reason }`. ' +
			'Создаёт запрос (статус pending), HR получает письмо.\n\n' +
			'Сотрудник видит и правит только собственные данные — область доступа задаётся токеном, а не параметрами запроса.',
		{ pos: [0, -2.4], width: 1400, height: 200 },
	);
	wf.sticky(
		'## Рассмотрение HR\n' +
			'* `GET /webhook/timetrack/hr/corrections?status=pending` — очередь запросов.\n' +
			'* `POST /webhook/timetrack/hr/corrections/review` — `{ request_id, decision: approved|rejected, comment }`. ' +
			'При одобрении `fn_review_correction()` создаёт событие с source=correction и помечает старое как corrected/voided; сотрудник получает письмо.',
		{ pos: [0, 4.2], width: 1400, height: 170, color: 5 },
	);

	// ---------- мои записи ----------
	wf.add(webhook('My Records Webhook', { path: 'timetrack/me/records', method: 'GET', pos: [0, 0] }));
	wf.add(authenticate('Authenticate (records)', 'My Records Webhook', [1, 0]));
	wf.add(ifNode('Is Employee? (records)', { pos: [2, 0], conditions: truthy("={{ $json.role === 'employee' }}") }));
	wf.add(unauthorized('Respond 401 (records)', [3, 1]));
	wf.add(
		postgres('Load My Records', {
			pos: [3, 0],
			alwaysOutputData: true,
			query:
				'SELECT employee, days, sessions, corrections, absences, totals\n' +
				"  FROM timetrack.fn_timesheet($1, COALESCE(NULLIF($2, '')::date, CURRENT_DATE - 30),\n" +
				"                              COALESCE(NULLIF($3, '')::date, CURRENT_DATE), NULL, true)",
			params:
				"={{ [ $json.employee_id, (/^\\d{4}-\\d{2}-\\d{2}$/.test(String($('My Records Webhook').first().json.query?.from ?? '')) ? $('My Records Webhook').first().json.query.from : ''), " +
				"(/^\\d{4}-\\d{2}-\\d{2}$/.test(String($('My Records Webhook').first().json.query?.to ?? '')) ? $('My Records Webhook').first().json.query.to : '') ] }}",
		}),
	);
	wf.add(respondFirstItem('Respond My Records', { pos: [4, 0] }));
	wf.chain('My Records Webhook', 'Authenticate (records)', 'Is Employee? (records)');
	wf.connect('Is Employee? (records)', 'Load My Records', { output: 0 });
	wf.connect('Is Employee? (records)', 'Respond 401 (records)', { output: 1 });
	wf.chain('Load My Records', 'Respond My Records');

	// ---------- запрос корректировки ----------
	wf.add(webhook('Correction Webhook', { path: 'timetrack/me/corrections', pos: [0, 2] }));
	wf.add(
		setNode('Config', {
			pos: [1, 2],
			fields: { hrEmail: 'hr@example.com', fromEmail: 'timetrack@example.com', maxCorrectionAgeDays: 45, timezone: 'Europe/Moscow' },
			notes: 'Адрес HR для уведомлений, допустимая давность корректируемых событий и часовой пояс организации для времени в письмах.',
		}),
	);
	wf.add(authenticate('Authenticate (correction)', 'Correction Webhook', [2, 2]));
	wf.add(ifNode('Is Employee? (correction)', { pos: [3, 2], conditions: truthy("={{ $json.role === 'employee' }}") }));
	wf.add(unauthorized('Respond 401 (correction)', [4, 3]));
	wf.add(
		postgres('Create Correction Request', {
			pos: [4, 2],
			notes: 'fn_request_correction проверяет принадлежность события, давность, дубли и обязательность причины.',
			query:
				'SELECT ok, code, request\n' +
				"  FROM timetrack.fn_request_correction($1, $2, NULLIF($3, '')::bigint, $4, NULLIF($5, '')::timestamptz, $6, $7, $8::int)",
			params:
				"={{ [ $json.employee_id, String($('Correction Webhook').first().json.body?.action ?? 'add'), " +
				"(/^\\d+$/.test(String($('Correction Webhook').first().json.body?.event_id ?? '')) ? String($('Correction Webhook').first().json.body.event_id) : ''), " +
				"$('Correction Webhook').first().json.body?.requested_type ?? null, " +
				"(!Number.isNaN(Date.parse($('Correction Webhook').first().json.body?.requested_time ?? '')) ? new Date($('Correction Webhook').first().json.body.requested_time).toISOString() : ''), " +
				"String($('Correction Webhook').first().json.body?.reason ?? ''), $json.client_name ?? null, " +
				`${CFG}.maxCorrectionAgeDays ] }}`,
		}),
	);
	wf.add(ifNode('Request Created?', { pos: [5, 2], conditions: truthy('={{ $json.ok === true }}') }));
	wf.add(
		email('Notify HR', {
			pos: [6, 2],
			from: `={{ ${CFG}.fromEmail }}`,
			to: `={{ ${CFG}.hrEmail }}`,
			subject: '=[Учёт времени] Запрос на корректировку от {{ $json.request.employee_id }}',
			html:
				'=<p>Сотрудник <b>{{ $json.request.employee_id }}</b> запросил корректировку отметки.</p>' +
				`<ul><li>Действие: {{ ({add:'добавить отметку',change:'исправить время',void:'аннулировать отметку'})[$json.request.action] ?? $json.request.action }}</li><li>Событие: {{ $json.request.event_id ?? '—' }}</li>` +
				`<li>Тип: {{ ({check_in:'приход',check_out:'уход'})[$json.request.requested_type] ?? ($json.request.requested_type ?? '—') }}</li>` +
				`<li>Время: {{ ${LOCAL_TIME}($json.request.requested_time, ${CFG}.timezone) }}</li>` +
				`<li>Причина: {{ String($json.request.reason ?? '').replace(/[&<>]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;'}[c])) }}</li></ul>` +
				'<p>ID запроса: <code>{{ $json.request.id }}</code>. Рассмотрите его через <code>POST /webhook/timetrack/hr/corrections/review</code>.</p>',
			notes: 'Если SMTP не настроен, нода пропускается (continue on error) и запрос всё равно создаётся.',
		}),
	);
	wf.add(
		respondJson('Respond Request Created', {
			pos: [7, 2],
			code: 201,
			body: "={{ ({ ok: true, code: 'created', request: $('Create Correction Request').first().json.request }) }}",
		}),
	);
	wf.add(
		respondJson('Respond Request Error', {
			pos: [6, 3],
			code: 400,
			body:
				'={{ ({ ok: false, code: $json.code, message: ({ invalid_action: "Недопустимое действие", reason_required: "Укажите причину (не менее 3 символов)", ' +
				'event_not_found: "Событие не найдено или принадлежит другому сотруднику", event_not_editable: "Событие уже скорректировано", ' +
				'event_too_old: "Событие слишком старое для корректировки", already_pending: "По этому событию уже есть открытый запрос", ' +
				'invalid_request: "Укажите тип и время отметки", time_in_future: "Время не может быть в будущем", time_too_old: "Слишком давняя дата" })[$json.code] ?? $json.code }) }}',
		}),
	);
	wf.chain('Correction Webhook', 'Config', 'Authenticate (correction)', 'Is Employee? (correction)');
	wf.connect('Is Employee? (correction)', 'Create Correction Request', { output: 0 });
	wf.connect('Is Employee? (correction)', 'Respond 401 (correction)', { output: 1 });
	wf.chain('Create Correction Request', 'Request Created?');
	wf.connect('Request Created?', 'Notify HR', { output: 0 });
	wf.connect('Request Created?', 'Respond Request Error', { output: 1 });
	wf.chain('Notify HR', 'Respond Request Created');

	// ---------- очередь HR ----------
	wf.add(webhook('Corrections Queue Webhook', { path: 'timetrack/hr/corrections', method: 'GET', pos: [0, 5.2] }));
	wf.add(authenticate('Authenticate (queue)', 'Corrections Queue Webhook', [1, 5.2]));
	wf.add(ifNode('Is HR? (queue)', { pos: [2, 5.2], conditions: truthy("={{ ['hr', 'system'].includes($json.role ?? '') }}") }));
	wf.add(unauthorized('Respond 401 (queue)', [3, 6.2]));
	wf.add(
		postgres('List Correction Requests', {
			pos: [3, 5.2],
			alwaysOutputData: true,
			query:
				'SELECT c.id AS request_id, c.employee_id, e.full_name, e.department, c.action, c.event_id,\n' +
				'       a.event_type AS current_type, a.occurred_at AS current_occurred_at,\n' +
				'       c.requested_type, c.requested_time, c.reason, c.status, c.reviewed_by, c.reviewed_at,\n' +
				'       c.review_comment, c.result_event_id, c.created_at\n' +
				'  FROM timetrack.correction_requests c\n' +
				'  JOIN timetrack.employees e ON e.employee_id = c.employee_id\n' +
				'  LEFT JOIN timetrack.attendance_events a ON a.id = c.event_id\n' +
				" WHERE c.status = COALESCE(NULLIF($1, ''), 'pending')\n" +
				' ORDER BY c.created_at\n' +
				' LIMIT 500',
			params: "={{ [ String($('Corrections Queue Webhook').first().json.query?.status ?? 'pending') ] }}",
		}),
	);
	wf.add(respondAllItems('Respond Queue', { pos: [4, 5.2] }));
	wf.chain('Corrections Queue Webhook', 'Authenticate (queue)', 'Is HR? (queue)');
	wf.connect('Is HR? (queue)', 'List Correction Requests', { output: 0 });
	wf.connect('Is HR? (queue)', 'Respond 401 (queue)', { output: 1 });
	wf.chain('List Correction Requests', 'Respond Queue');

	// ---------- решение HR ----------
	wf.add(webhook('Review Webhook', { path: 'timetrack/hr/corrections/review', pos: [0, 7.2] }));
	wf.add(setNode('Config (review)', { pos: [1, 7.2], fields: { fromEmail: 'timetrack@example.com', timezone: 'Europe/Moscow' } }));
	wf.add(authenticate('Authenticate (review)', 'Review Webhook', [2, 7.2]));
	wf.add(ifNode('Is HR? (review)', { pos: [3, 7.2], conditions: truthy("={{ ['hr', 'system'].includes($json.role ?? '') }}") }));
	wf.add(unauthorized('Respond 401 (review)', [4, 8.2]));
	wf.add(
		postgres('Review Correction', {
			pos: [4, 7.2],
			query: 'SELECT ok, code, request, result_event FROM timetrack.fn_review_correction($1::uuid, $2, $3, $4)',
			params:
				"={{ [ (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(String($('Review Webhook').first().json.body?.request_id ?? '')) " +
				"? String($('Review Webhook').first().json.body.request_id) : '00000000-0000-0000-0000-000000000000'), " +
				"String($('Review Webhook').first().json.body?.decision ?? ''), $('Review Webhook').first().json.body?.comment ?? null, $json.client_name ?? null ] }}",
		}),
	);
	wf.add(ifNode('Reviewed?', { pos: [5, 7.2], conditions: truthy('={{ $json.ok === true }}') }));
	wf.add(
		postgres('Load Employee Contact', {
			pos: [6, 7.2],
			alwaysOutputData: true,
			query: 'SELECT e.email, e.full_name, e.timezone FROM timetrack.employees e WHERE e.employee_id = $1',
			params: '={{ [ $json.request.employee_id ] }}',
		}),
	);
	wf.add(ifNode('Has Email?', { pos: [7, 7.2], conditions: truthy("={{ typeof $json.email === 'string' && $json.email.includes('@') }}") }));
	wf.add(
		email('Notify Employee', {
			pos: [8, 7.2],
			from: `={{ ${CFG_R}.fromEmail }}`,
			to: '={{ $json.email }}',
			subject: "=[Учёт времени] Ваш запрос на корректировку {{ $('Review Correction').first().json.code === 'approved' ? 'одобрен' : 'отклонён' }}",
			html:
				"=<p>Здравствуйте, {{ $json.full_name }}!</p><p>Ваш запрос на корректировку отметки <b>{{ $('Review Correction').first().json.code === 'approved' ? 'одобрен' : 'отклонён' }}</b>.</p>" +
				`<ul><li>Действие: {{ ({add:'добавить отметку',change:'исправить время',void:'аннулировать отметку'})[$('Review Correction').first().json.request.action] ?? $('Review Correction').first().json.request.action }}</li>` +
				`<li>Время: {{ ${LOCAL_TIME}($('Review Correction').first().json.request.requested_time, $json.timezone || ${CFG_R}.timezone) }}</li>` +
				`<li>Комментарий HR: {{ String($('Review Correction').first().json.request.review_comment ?? '').replace(/[&<>]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;'}[c])) }}</li></ul>`,
		}),
	);
	wf.add(
		respondJson('Respond Reviewed', {
			pos: [9, 7.2],
			body:
				"={{ ({ ok: true, code: $('Review Correction').first().json.code, request: $('Review Correction').first().json.request, " +
				"result_event: $('Review Correction').first().json.result_event }) }}",
		}),
	);
	wf.add(
		respondJson('Respond Review Error', {
			pos: [6, 8.2],
			code: "={{ $json.code === 'request_not_found' ? 404 : 400 }}",
			body: '={{ ({ ok: false, code: $json.code, request: $json.request ?? null }) }}',
		}),
	);
	wf.chain('Review Webhook', 'Config (review)', 'Authenticate (review)', 'Is HR? (review)');
	wf.connect('Is HR? (review)', 'Review Correction', { output: 0 });
	wf.connect('Is HR? (review)', 'Respond 401 (review)', { output: 1 });
	wf.chain('Review Correction', 'Reviewed?');
	wf.connect('Reviewed?', 'Load Employee Contact', { output: 0 });
	wf.connect('Reviewed?', 'Respond Review Error', { output: 1 });
	wf.chain('Load Employee Contact', 'Has Email?');
	wf.connect('Has Email?', 'Notify Employee', { output: 0 });
	wf.connect('Has Email?', 'Respond Reviewed', { output: 1 });
	wf.chain('Notify Employee', 'Respond Reviewed');

	return wf;
}
