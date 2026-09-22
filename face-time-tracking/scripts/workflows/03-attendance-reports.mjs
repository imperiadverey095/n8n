import {
	WorkflowBuilder, webhook, respondJson, respondFirstItem, respondText, respondBinary, postgres, code, ifNode,
	setNode, switchNode, convertToCsv, authenticate, unauthorized, truthy, conditions, cond,
} from '../lib/builder.mjs';

const RESOLVE_JS = `
// Параметры отчёта: период, тип, формат, область (сотрудник/подразделение).
const q = $('Report Webhook').first().json.query || {};
const auth = $input.first().json;
const cfg = $('Config').first().json;
const problems = [];

const type = ['standard', 'detailed', 'summary'].includes(q.type) ? q.type : 'standard';
const format = ['json', 'csv', 'html'].includes(q.format) ? q.format : 'json';

const isDate = (s) => typeof s === 'string' && /^\\d{4}-\\d{2}-\\d{2}$/.test(s) && !Number.isNaN(Date.parse(s));
const today = new Date();
const defFrom = new Date(Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), 1)).toISOString().slice(0, 10);
const defTo = new Date(Date.UTC(today.getUTCFullYear(), today.getUTCMonth() + 1, 0)).toISOString().slice(0, 10);
const from = isDate(q.from) ? q.from : defFrom;
const to = isDate(q.to) ? q.to : defTo;
if (from > to) problems.push('from_after_to');
if ((Date.parse(to) - Date.parse(from)) / 86400000 > cfg.maxPeriodDays) problems.push('period_too_long');

let employeeId = q.employee_id ? String(q.employee_id) : null;
let department = q.department ? String(q.department) : null;
if (auth.role === 'employee') {
  // сотрудник видит только собственный табель
  employeeId = auth.employee_id;
  department = null;
}
if (employeeId && !/^[A-Za-z0-9._-]{1,64}$/.test(employeeId)) problems.push('employee_id_invalid');

return [{
  json: {
    ok: problems.length === 0,
    problems,
    type, format, from, to,
    employee_id: employeeId,
    department,
    include_inactive: String(q.include_inactive) === 'true',
    requester: auth.client_name,
    requester_role: auth.role,
    csv_delimiter: cfg.csvDelimiter,
    company_name: cfg.companyName,
  },
}];
`;

// Общий код форматирования отчётов (используется и в отчётах по запросу, и в рассылке).
export const REPORT_LIB_JS = `
const fmtMin = (m) => {
  const n = Number(m) || 0;
  return Math.floor(n / 60) + ':' + String(n % 60).padStart(2, '0');
};
const fmtTime = (iso, tz) => {
  if (!iso) return '';
  try {
    return new Intl.DateTimeFormat('ru-RU', { timeZone: tz || 'UTC', hour: '2-digit', minute: '2-digit' }).format(new Date(iso));
  } catch (e) { return String(iso).slice(11, 16); }
};
const fmtDateTime = (iso, tz) => {
  if (!iso) return '';
  try {
    return new Intl.DateTimeFormat('ru-RU', { timeZone: tz || 'UTC', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' }).format(new Date(iso));
  } catch (e) { return String(iso); }
};
const STATUS_RU = {
  present: 'присутствовал', late: 'опоздание', incomplete: 'не закрыта смена', absent: 'отсутствие',
  day_off: 'выходной', holiday: 'праздник', vacation: 'отпуск', sick_leave: 'больничный',
  business_trip: 'командировка', remote: 'удалённо', unpaid_leave: 'отпуск без сохранения', other: 'отсутствие (прочее)',
};
const DAY_TYPE_RU = { workday: 'рабочий', weekend: 'выходной', holiday: 'праздник', short_day: 'предпраздничный' };
const ABSENCE_RU = {
  vacation: 'отпуск', sick_leave: 'больничный', business_trip: 'командировка',
  remote: 'удалённо', unpaid_leave: 'отпуск без сохранения', other: 'прочее',
};
const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (ch) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[ch]));

function dayRows(ts) {
  const tz = ts.employee.timezone;
  return (ts.days || []).map((d) => ({
    employee_id: ts.employee.employee_id,
    full_name: ts.employee.full_name,
    department: ts.employee.department ?? '',
    date: d.work_date,
    day_type: DAY_TYPE_RU[d.day_type] || d.day_type || '',
    scheduled: d.scheduled ? 'да' : 'нет',
    status: STATUS_RU[d.status] || d.status,
    absence: d.absence_type ? (ABSENCE_RU[d.absence_type] || d.absence_type) : '',
    first_in: fmtTime(d.first_in, tz),
    last_out: fmtTime(d.last_out, tz),
    sessions: d.sessions,
    worked: fmtMin(d.worked_minutes),
    worked_minutes: d.worked_minutes,
    credited: fmtMin(d.credited_minutes || 0),
    credited_minutes: d.credited_minutes || 0,
    breaks: fmtMin(d.break_minutes),
    scheduled_minutes: d.scheduled_minutes,
    late_minutes: d.late_minutes,
    early_leave_minutes: d.early_leave_minutes,
    overtime_minutes: d.overtime_minutes,
  }));
}

function summaryRow(ts) {
  const t = ts.totals || {};
  return {
    employee_id: ts.employee.employee_id,
    full_name: ts.employee.full_name,
    department: ts.employee.department ?? '',
    position: ts.employee.position ?? '',
    scheduled_days: t.scheduled_days ?? 0,
    days_present: t.days_present ?? 0,
    days_absent: t.days_absent ?? 0,
    days_incomplete: t.days_incomplete ?? 0,
    late_days: t.late_days ?? 0,
    days_vacation: t.days_vacation ?? 0,
    days_sick_leave: t.days_sick_leave ?? 0,
    days_business_trip: t.days_business_trip ?? 0,
    days_other_absence: t.days_other_absence ?? 0,
    days_holiday: t.days_holiday ?? 0,
    credited_hours: fmtMin(t.credited_minutes),
    credited_minutes: t.credited_minutes ?? 0,
    scheduled_hours: fmtMin(t.scheduled_minutes),
    worked_hours: fmtMin(t.worked_minutes),
    worked_minutes: t.worked_minutes ?? 0,
    late_minutes: t.late_minutes ?? 0,
    early_leave_minutes: t.early_leave_minutes ?? 0,
    overtime_hours: fmtMin(t.overtime_minutes),
    overtime_minutes: t.overtime_minutes ?? 0,
  };
}

function sessionRows(ts) {
  const tz = ts.employee.timezone;
  return (ts.sessions || []).map((s) => ({
    employee_id: ts.employee.employee_id,
    full_name: ts.employee.full_name,
    date: s.work_date,
    check_in: fmtDateTime(s.check_in, tz),
    check_out: fmtDateTime(s.check_out, tz),
    worked: s.worked_minutes == null ? '' : fmtMin(s.worked_minutes),
    in_source: s.in_source,
    out_source: s.out_source ?? '',
    in_event_id: s.in_event_id,
    out_event_id: s.out_event_id ?? '',
    incomplete: s.incomplete ? 'да' : 'нет',
  }));
}

function correctionRows(ts) {
  const tz = ts.employee.timezone;
  return (ts.corrections || []).map((c) => ({
    employee_id: ts.employee.employee_id,
    full_name: ts.employee.full_name,
    request_id: c.id,
    action: c.action,
    event_id: c.event_id ?? '',
    requested_type: c.requested_type ?? '',
    requested_time: fmtDateTime(c.requested_time, tz),
    reason: c.reason,
    status: c.status,
    reviewed_by: c.reviewed_by ?? '',
    reviewed_at: fmtDateTime(c.reviewed_at, tz),
    review_comment: c.review_comment ?? '',
    created_at: fmtDateTime(c.created_at, tz),
  }));
}

function absenceRows(ts) {
  return (ts.absences || []).map((a) => ({
    employee_id: ts.employee.employee_id,
    full_name: ts.employee.full_name,
    absence_type: ABSENCE_RU[a.absence_type] || a.absence_type,
    date_from: a.date_from,
    date_to: a.date_to,
    status: a.status,
    counts_as_worked: a.counts_as_worked ? 'да' : 'нет',
    comment: a.comment ?? '',
    external_id: a.external_id ?? '',
  }));
}

function htmlTable(rows, columns) {
  if (!rows.length) return '<p><i>Нет данных</i></p>';
  const head = columns.map((c) => '<th>' + esc(c.title) + '</th>').join('');
  const body = rows.map((r) => '<tr>' + columns.map((c) => '<td>' + esc(r[c.key]) + '</td>').join('') + '</tr>').join('');
  return '<table><thead><tr>' + head + '</tr></thead><tbody>' + body + '</tbody></table>';
}

const DAY_COLUMNS = [
  { key: 'date', title: 'Дата' }, { key: 'day_type', title: 'Тип дня' }, { key: 'status', title: 'Статус' },
  { key: 'first_in', title: 'Приход' }, { key: 'last_out', title: 'Уход' }, { key: 'worked', title: 'Отработано' },
  { key: 'credited', title: 'Зачтено' }, { key: 'breaks', title: 'Перерывы' },
  { key: 'late_minutes', title: 'Опоздание, мин' }, { key: 'early_leave_minutes', title: 'Ранний уход, мин' },
  { key: 'overtime_minutes', title: 'Сверхурочно, мин' },
];
const SUMMARY_COLUMNS = [
  { key: 'employee_id', title: 'Табельный №' }, { key: 'full_name', title: 'Сотрудник' }, { key: 'department', title: 'Подразделение' },
  { key: 'scheduled_days', title: 'Плановых дней' }, { key: 'days_present', title: 'Отработано дней' },
  { key: 'days_absent', title: 'Прогулов' }, { key: 'days_incomplete', title: 'Незакрытых смен' }, { key: 'late_days', title: 'Опозданий' },
  { key: 'days_vacation', title: 'Отпуск' }, { key: 'days_sick_leave', title: 'Больничный' }, { key: 'days_business_trip', title: 'Командировки' },
  { key: 'scheduled_hours', title: 'План, ч' }, { key: 'worked_hours', title: 'Факт, ч' },
  { key: 'credited_hours', title: 'Зачтено, ч' }, { key: 'overtime_hours', title: 'Сверхурочно, ч' },
];
const ABSENCE_COLUMNS = [
  { key: 'absence_type', title: 'Тип' }, { key: 'date_from', title: 'С' }, { key: 'date_to', title: 'По' },
  { key: 'status', title: 'Статус' }, { key: 'counts_as_worked', title: 'Зачитывается как работа' },
  { key: 'comment', title: 'Комментарий' },
];
const SESSION_COLUMNS = [
  { key: 'date', title: 'Дата' }, { key: 'check_in', title: 'Приход' }, { key: 'check_out', title: 'Уход' },
  { key: 'worked', title: 'Длительность' }, { key: 'in_source', title: 'Источник прихода' }, { key: 'out_source', title: 'Источник ухода' },
  { key: 'in_event_id', title: 'ID прихода' }, { key: 'out_event_id', title: 'ID ухода' },
];
const CORRECTION_COLUMNS = [
  { key: 'created_at', title: 'Создан' }, { key: 'action', title: 'Действие' }, { key: 'requested_type', title: 'Тип' },
  { key: 'requested_time', title: 'Время' }, { key: 'reason', title: 'Причина' }, { key: 'status', title: 'Статус' },
  { key: 'reviewed_by', title: 'Рассмотрел' }, { key: 'review_comment', title: 'Комментарий' },
];

function htmlDocument(title, sections) {
  return '<!doctype html><html lang="ru"><head><meta charset="utf-8"><title>' + esc(title) + '</title>'
    + '<style>body{font-family:Arial,Helvetica,sans-serif;font-size:13px;color:#1f2933;margin:24px}'
    + 'h1{font-size:20px}h2{font-size:16px;margin-top:28px}h3{font-size:14px;margin:18px 0 6px}'
    + 'table{border-collapse:collapse;width:100%;margin:8px 0 16px}th,td{border:1px solid #d3dce6;padding:5px 8px;text-align:left}'
    + 'th{background:#f0f4f8}tr:nth-child(even) td{background:#fafbfc}.muted{color:#627d98}</style></head><body>'
    + '<h1>' + esc(title) + '</h1>' + sections.join('') + '</body></html>';
}
`;

const BUILD_REPORT_JS = `
${REPORT_LIB_JS}
const p = $('Resolve Parameters').first().json;
const timesheets = $input.all().map((i) => i.json).filter((r) => r && r.employee);
const period = p.from + ' — ' + p.to;
const meta = { type: p.type, format: p.format, from: p.from, to: p.to, employees: timesheets.length, generated_at: new Date().toISOString(), requested_by: p.requester };

// ---------- JSON ----------
if (p.format === 'json') {
  let data;
  if (p.type === 'summary') {
    data = timesheets.map((ts) => ({ employee: ts.employee, totals: ts.totals }));
  } else if (p.type === 'standard') {
    data = timesheets.map((ts) => ({ employee: ts.employee, totals: ts.totals, days: ts.days }));
  } else {
    data = timesheets;
  }
  return [{ json: { ok: true, report: meta, data } }];
}

// ---------- CSV: плоские строки ----------
if (p.format === 'csv') {
  let rows = [];
  if (p.type === 'summary') rows = timesheets.map(summaryRow);
  else if (p.type === 'standard') rows = timesheets.flatMap(dayRows);
  else rows = timesheets.flatMap((ts) => dayRows(ts).map((r) => ({ section: 'day', ...r }))
      .concat(sessionRows(ts).map((r) => ({ section: 'session', ...r })))
      .concat(absenceRows(ts).map((r) => ({ section: 'absence', ...r })))
      .concat(correctionRows(ts).map((r) => ({ section: 'correction', ...r }))));
  if (!rows.length) rows = [{ info: 'Нет данных за период ' + period }];
  return rows.map((r) => ({ json: r }));
}

// ---------- HTML ----------
const sections = [];
sections.push('<p class="muted">Период: ' + esc(period) + ' · Сотрудников: ' + timesheets.length
  + ' · Сформировано: ' + esc(new Date().toISOString().replace('T', ' ').slice(0, 16)) + ' UTC</p>');
sections.push('<h2>Сводка</h2>' + htmlTable(timesheets.map(summaryRow), SUMMARY_COLUMNS));
if (p.type !== 'summary') {
  for (const ts of timesheets) {
    sections.push('<h2>' + esc(ts.employee.full_name) + ' <span class="muted">(' + esc(ts.employee.employee_id) + ', '
      + esc(ts.employee.department ?? '—') + ', ' + esc(ts.employee.timezone) + ')</span></h2>');
    sections.push('<h3>По дням</h3>' + htmlTable(dayRows(ts), DAY_COLUMNS));
    if (p.type === 'detailed') {
      sections.push('<h3>Сессии</h3>' + htmlTable(sessionRows(ts), SESSION_COLUMNS));
      sections.push('<h3>Отсутствия</h3>' + htmlTable(absenceRows(ts), ABSENCE_COLUMNS));
      sections.push('<h3>Корректировки</h3>' + htmlTable(correctionRows(ts), CORRECTION_COLUMNS));
    }
  }
}
const title = (p.company_name ? p.company_name + ' · ' : '') + 'Табель учёта рабочего времени ' + period;
return [{ json: { html: htmlDocument(title, sections), report: meta } }];
`;

export function build() {
	const wf = new WorkflowBuilder({
		name: 'Timetrack 03 — Attendance Reports',
		description: 'Табели и отчёты по посещаемости по запросу: standard / detailed / summary в json, csv или html',
		tags: ['timetrack'],
	});

	wf.sticky(
		'## Отчёты по запросу\n' +
			'`GET /webhook/timetrack/reports?type=standard|detailed|summary&format=json|csv|html&from=YYYY-MM-DD&to=YYYY-MM-DD&employee_id=&department=`\n\n' +
			'Заголовок `X-Api-Token`: HR-токен видит всех, личный токен сотрудника — только себя. ' +
			'Период по умолчанию — текущий месяц. Данные считает `timetrack.fn_timesheet()`; форматирование — в ноде Build Report.\n\n' +
			'* **summary** — итоги по сотрудникам; **standard** — табель по дням; **detailed** — дни + сессии + корректировки.',
		{ pos: [0, -2.4], width: 1500, height: 230 },
	);

	wf.add(webhook('Report Webhook', { path: 'timetrack/reports', method: 'GET', pos: [0, 0] }));
	wf.add(
		setNode('Config', {
			pos: [1, 0],
			fields: { maxPeriodDays: 366, csvDelimiter: ';', companyName: '' },
			notes: 'csvDelimiter ";" удобен для Excel с русской локалью.',
		}),
	);
	wf.add(authenticate('Authenticate', 'Report Webhook', [2, 0]));
	wf.add(
		ifNode('Is Authorized?', {
			pos: [3, 0],
			conditions: truthy("={{ ['hr', 'system', 'employee'].includes($json.role ?? '') }}"),
		}),
	);
	wf.add(unauthorized('Respond 401', [4, 1]));
	wf.add(code('Resolve Parameters', { pos: [4, 0], js: RESOLVE_JS }));
	wf.add(ifNode('Params Valid?', { pos: [5, 0], conditions: truthy('={{ $json.ok === true }}') }));
	wf.add(
		respondJson('Respond 400', {
			pos: [6, 1],
			code: 400,
			body: "={{ ({ ok: false, code: 'bad_request', problems: $json.problems }) }}",
		}),
	);
	wf.add(
		postgres('Load Timesheet', {
			pos: [6, 0],
			alwaysOutputData: true,
			query: 'SELECT employee, days, sessions, corrections, absences, totals\n  FROM timetrack.fn_timesheet($1, $2::date, $3::date, $4, $5::boolean)',
			params: '={{ [ $json.employee_id ?? null, $json.from, $json.to, $json.department ?? null, $json.include_inactive === true ] }}',
		}),
	);
	wf.add(code('Build Report', { pos: [7, 0], js: BUILD_REPORT_JS }));
	wf.add(
		postgres('Audit Report Access', {
			pos: [8, 1],
			executeOnce: true,
			onError: 'continueRegularOutput',
			notes: 'Кто и какой отчёт запрашивал (подотчётность по GDPR).',
			query: "SELECT timetrack.fn_audit($1, $2, 'report.generated', 'report', $3, $4::jsonb) AS audit_id",
			params:
				"={{ [ $('Resolve Parameters').first().json.requester ?? null, $('Resolve Parameters').first().json.requester_role ?? null, " +
				"$('Resolve Parameters').first().json.type, ({ from: $('Resolve Parameters').first().json.from, to: $('Resolve Parameters').first().json.to, " +
				"employee_id: $('Resolve Parameters').first().json.employee_id ?? null, department: $('Resolve Parameters').first().json.department ?? null, " +
				"format: $('Resolve Parameters').first().json.format }) ] }}",
		}),
	);
	wf.add(
		switchNode('Route By Format', {
			pos: [8, 0],
			rules: [
				{ key: 'json', conditions: conditions([cond("={{ $('Resolve Parameters').first().json.format }}", 'string:equals', 'json')]) },
				{ key: 'csv', conditions: conditions([cond("={{ $('Resolve Parameters').first().json.format }}", 'string:equals', 'csv')]) },
				{ key: 'html', conditions: conditions([cond("={{ $('Resolve Parameters').first().json.format }}", 'string:equals', 'html')]) },
			],
		}),
	);
	wf.add(respondFirstItem('Respond JSON', { pos: [9, -1] }));
	wf.add(
		convertToCsv('Convert To CSV', {
			pos: [9, 0],
			fileName: "=timesheet_{{ $('Resolve Parameters').first().json.from }}_{{ $('Resolve Parameters').first().json.to }}.csv",
			delimiter: "={{ $('Resolve Parameters').first().json.csv_delimiter }}",
		}),
	);
	wf.add(
		respondBinary('Respond CSV', {
			pos: [10, 0],
			headers: [
				{ name: 'Content-Type', value: 'text/csv; charset=utf-8' },
				{
					name: 'Content-Disposition',
					value: "=attachment; filename=\"timesheet_{{ $('Resolve Parameters').first().json.from }}_{{ $('Resolve Parameters').first().json.to }}.csv\"",
				},
			],
		}),
	);
	wf.add(respondText('Respond HTML', { pos: [9, 1], body: '={{ $json.html }}', contentType: 'text/html; charset=utf-8' }));

	wf.chain('Report Webhook', 'Config', 'Authenticate', 'Is Authorized?');
	wf.connect('Is Authorized?', 'Resolve Parameters', { output: 0 });
	wf.connect('Is Authorized?', 'Respond 401', { output: 1 });
	wf.chain('Resolve Parameters', 'Params Valid?');
	wf.connect('Params Valid?', 'Load Timesheet', { output: 0 });
	wf.connect('Params Valid?', 'Respond 400', { output: 1 });
	wf.chain('Load Timesheet', 'Build Report', 'Route By Format');
	wf.connect('Build Report', 'Audit Report Access');
	wf.connect('Route By Format', 'Respond JSON', { output: 0 });
	wf.connect('Route By Format', 'Convert To CSV', { output: 1 });
	wf.connect('Route By Format', 'Respond HTML', { output: 2 });
	wf.chain('Convert To CSV', 'Respond CSV');

	return wf;
}
