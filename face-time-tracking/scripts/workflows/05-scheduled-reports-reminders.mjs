import {
	WorkflowBuilder, postgres, code, filterNode, setNode, schedule, email, convertToCsv, splitOut, truthy,
} from '../lib/builder.mjs';
import { REPORT_LIB_JS } from './03-attendance-reports.mjs';

const CFG_M = "$('Config (monthly)').first().json";
const CFG_W = "$('Config (weekly)').first().json";

const PREVIOUS_MONTH_JS = `
// Предыдущий календарный месяц (UTC).
const now = new Date();
const from = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - 1, 1));
const to = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 0));
return [{ json: { from: from.toISOString().slice(0, 10), to: to.toISOString().slice(0, 10) } }];
`;

const BUILD_MONTHLY_JS = `
${REPORT_LIB_JS}
const period = $('Previous Month').first().json;
const cfg = $('Config (monthly)').first().json;
const timesheets = $input.all().map((i) => i.json).filter((r) => r && r.employee);
const label = period.from + ' — ' + period.to;

let rows = timesheets.flatMap(dayRows);
if (!rows.length) rows = [{ info: 'Нет данных за период ' + label }];

const sections = [
  '<p class="muted">Период: ' + esc(label) + ' · Сотрудников: ' + timesheets.length + '</p>',
  '<h2>Сводка по сотрудникам</h2>' + htmlTable(timesheets.map(summaryRow), SUMMARY_COLUMNS),
  '<p class="muted">Полный табель по дням — во вложении (CSV). Незакрытые смены и отсутствия требуют проверки.</p>',
];
const title = (cfg.companyName ? cfg.companyName + ' · ' : '') + 'Табель за ' + label;
return [{ json: { subject: title, html: htmlDocument(title, sections), rows, from: period.from, to: period.to } }];
`;

const BUILD_REMINDER_JS = `
${REPORT_LIB_JS}
const cfg = $('Config (weekly)').first().json;
const item = $json;
const STATUS = { incomplete: 'не закрыта смена (нет отметки ухода)', absent: 'нет отметок в рабочий день' };
const list = (item.issues || []).map((d) =>
  '<li><b>' + esc(d.work_date) + '</b> — ' + esc(STATUS[d.status] || d.status)
  + (d.first_in ? ' (приход ' + esc(fmtTime(d.first_in, item.timezone)) + ')' : '') + '</li>').join('');
const html = '<p>Здравствуйте, ' + esc(item.full_name) + '!</p>'
  + '<p>За прошедшую неделю в вашем учёте рабочего времени есть дни, требующие внимания:</p><ul>' + list + '</ul>'
  + '<p>Если это ошибка, отправьте запрос на корректировку' + (cfg.selfServiceUrl ? ': <a href="' + esc(cfg.selfServiceUrl) + '">' + esc(cfg.selfServiceUrl) + '</a>' : '') + '.</p>'
  + '<p class="muted">Письмо сформировано автоматически системой учёта рабочего времени.</p>';
return { json: { ...item, html, subject: 'Проверьте отметки рабочего времени за неделю' } };
`;

export function build() {
	const wf = new WorkflowBuilder({
		name: 'Timetrack 05 — Scheduled Reports & Reminders',
		description: 'Ежемесячный табель для HR (CSV + HTML) и еженедельные напоминания сотрудникам о проблемных днях',
		tags: ['timetrack'],
	});

	wf.sticky(
		'## Ежемесячный табель для HR\n' +
			'1-го числа в 06:00 UTC: табель за прошлый месяц по всем сотрудникам → письмо HR со сводкой в теле и CSV по дням во вложении. ' +
			'Расписание меняется в ноде триггера (cron), адреса — в Config (monthly).',
		{ pos: [0, -2.2], width: 1200, height: 150 },
	);
	wf.sticky(
		'## Еженедельные напоминания сотрудникам\n' +
			'По понедельникам в 08:00 UTC: каждому сотруднику с незакрытыми сменами или отсутствиями за прошлую неделю приходит письмо ' +
			'со списком дней и ссылкой на самообслуживание. Это реализует право сотрудника проверять и исправлять свои записи.',
		{ pos: [0, 2.2], width: 1200, height: 150, color: 5 },
	);

	// ---------- месячный отчёт ----------
	wf.add(schedule('Monthly Timesheet Trigger', { cron: '0 6 1 * *', pos: [0, 0] }));
	wf.add(
		setNode('Config (monthly)', {
			pos: [1, 0],
			fields: { hrEmail: 'hr@example.com', fromEmail: 'timetrack@example.com', csvDelimiter: ';', companyName: '' },
		}),
	);
	wf.add(code('Previous Month', { pos: [2, 0], js: PREVIOUS_MONTH_JS }));
	wf.add(
		postgres('Load Monthly Timesheets', {
			pos: [3, 0],
			alwaysOutputData: true,
			query: 'SELECT employee, days, sessions, corrections, totals FROM timetrack.fn_timesheet(NULL, $1::date, $2::date, NULL, true)',
			params: '={{ [ $json.from, $json.to ] }}',
		}),
	);
	wf.add(code('Build Monthly Report', { pos: [4, 0], js: BUILD_MONTHLY_JS }));
	wf.add(splitOut('Split CSV Rows', { field: 'rows', pos: [5, 0] }));
	wf.add(
		convertToCsv('Convert To CSV', {
			pos: [6, 0],
			fileName: "=timesheet_{{ $('Previous Month').first().json.from }}_{{ $('Previous Month').first().json.to }}.csv",
			delimiter: `={{ ${CFG_M}.csvDelimiter }}`,
		}),
	);
	wf.add(
		email('Send Monthly Report', {
			pos: [7, 0],
			from: `={{ ${CFG_M}.fromEmail }}`,
			to: `={{ ${CFG_M}.hrEmail }}`,
			subject: "={{ $('Build Monthly Report').first().json.subject }}",
			html: "={{ $('Build Monthly Report').first().json.html }}",
			attachments: 'data',
			onError: 'stopWorkflow',
		}),
	);
	wf.chain('Monthly Timesheet Trigger', 'Config (monthly)', 'Previous Month', 'Load Monthly Timesheets', 'Build Monthly Report', 'Split CSV Rows', 'Convert To CSV', 'Send Monthly Report');

	// ---------- напоминания ----------
	wf.add(schedule('Weekly Reminder Trigger', { cron: '0 8 * * 1', pos: [0, 3.2] }));
	wf.add(
		setNode('Config (weekly)', {
			pos: [1, 3.2],
			fields: { fromEmail: 'timetrack@example.com', selfServiceUrl: '', lookbackDays: 7 },
		}),
	);
	wf.add(
		postgres('Load Attendance Issues', {
			pos: [2, 3.2],
			query:
				'SELECT i.employee_id, i.full_name, i.email, i.issues, e.timezone\n' +
				'  FROM timetrack.fn_attendance_issues((CURRENT_DATE - $1::int)::date, (CURRENT_DATE - 1)::date) i\n' +
				'  JOIN timetrack.employees e ON e.employee_id = i.employee_id',
			params: `={{ [ ${CFG_W}.lookbackDays ] }}`,
		}),
	);
	wf.add(filterNode('Has Email?', { pos: [3, 3.2], conditions: truthy("={{ typeof $json.email === 'string' && $json.email.includes('@') }}") }));
	wf.add(code('Build Reminder', { pos: [4, 3.2], js: BUILD_REMINDER_JS, mode: 'runOnceForEachItem' }));
	wf.add(
		email('Send Reminder', {
			pos: [5, 3.2],
			from: `={{ ${CFG_W}.fromEmail }}`,
			to: '={{ $json.email }}',
			subject: '={{ $json.subject }}',
			html: '={{ $json.html }}',
		}),
	);
	wf.chain('Weekly Reminder Trigger', 'Config (weekly)', 'Load Attendance Issues', 'Has Email?', 'Build Reminder', 'Send Reminder');

	return wf;
}
