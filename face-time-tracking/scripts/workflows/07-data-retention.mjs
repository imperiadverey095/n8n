import {
	WorkflowBuilder, CREDENTIALS, postgres, ifNode, setNode, schedule, httpRequest, truthy,
} from '../lib/builder.mjs';

const CFG = "$('Config').first().json";

export function build() {
	const wf = new WorkflowBuilder({
		name: 'Timetrack 07 — Data Retention',
		description: 'Политика хранения: удаление биометрии уволенных/отозвавших согласие, очистка журналов',
		tags: ['timetrack'],
	});

	wf.sticky(
		'## Политика хранения данных\n' +
			'Ежедневно в 03:00 UTC:\n' +
			'1. `fn_biometrics_due_for_deletion()` — уволенные ≥ N дней назад и отозвавшие согласие → `DELETE subject` в CompreFace → `fn_revoke_biometrics()`.\n' +
			'2. Очистка журнала аудита старше auditRetentionDays и отправленных записей outbox старше outboxRetentionDays.\n' +
			'3. Опционально (anonymizeEventsAfterDays > 0) — обезличивание технических полей старых событий; сами табели не удаляются.\n\n' +
			'Сроки — в ноде Config; согласуйте их с юристом (см. docs/privacy-compliance.md).',
		{ pos: [0, -2.6], width: 1400, height: 230 },
	);

	wf.add(schedule('Retention Trigger', { cron: '0 3 * * *', pos: [0, 0] }));
	wf.add(
		setNode('Config', {
			pos: [1, 0],
			fields: {
				faceApiUrl: 'http://compreface-api:8080',
				daysAfterTermination: 30,
				auditRetentionDays: 730,
				outboxRetentionDays: 30,
				anonymizeEventsAfterDays: 0,
			},
		}),
	);
	wf.add(
		postgres('Find Biometrics To Delete', {
			pos: [2, 0],
			query: 'SELECT employee_id, provider, provider_subject_id, reason FROM timetrack.fn_biometrics_due_for_deletion($1::int)',
			params: `={{ [ ${CFG}.daysAfterTermination ] }}`,
		}),
	);
	wf.add(
		httpRequest('Delete Subject In Face Service', {
			pos: [3, 0],
			method: 'DELETE',
			url: `={{ ${CFG}.faceApiUrl }}/api/v1/recognition/subjects/{{ encodeURIComponent($json.provider_subject_id) }}`,
			auth: { type: 'httpHeaderAuth', credential: CREDENTIALS.faceApi },
			batching: { batchSize: 5, batchInterval: 500 },
		}),
	);
	wf.add(
		ifNode('Deleted Or Missing?', {
			pos: [4, 0],
			conditions: truthy('={{ [200, 404].includes(Number($json.statusCode ?? 0)) }}'),
		}),
	);
	wf.add(
		postgres('Revoke In Database', {
			pos: [5, 0],
			batching: 'independently',
			query: 'SELECT enrollments_deactivated, consents_revoked FROM timetrack.fn_revoke_biometrics($1, $2, $3, $4)',
			params:
				"={{ [ $('Find Biometrics To Delete').item.json.employee_id, 'retention:' + $('Find Biometrics To Delete').item.json.reason, 'retention-job', 'system' ] }}",
		}),
	);
	wf.add(
		postgres('Log Deletion Failure', {
			pos: [5, 1],
			batching: 'independently',
			query: "SELECT timetrack.fn_audit('retention-job', 'system', 'biometrics.delete_failed', 'employee', $1, $2::jsonb) AS audit_id",
			params:
				"={{ [ $('Find Biometrics To Delete').item.json.employee_id, ({ status: $json.statusCode ?? null, error: $json.error?.message ?? $json.error ?? null }) ] }}",
		}),
	);
	wf.chain('Retention Trigger', 'Config', 'Find Biometrics To Delete', 'Delete Subject In Face Service', 'Deleted Or Missing?');
	wf.connect('Deleted Or Missing?', 'Revoke In Database', { output: 0 });
	wf.connect('Deleted Or Missing?', 'Log Deletion Failure', { output: 1 });

	wf.add(
		postgres('Purge Logs', {
			pos: [2, 1.6],
			notes: 'Журнал аудита, отправленный outbox и (опционально) обезличивание старых событий.',
			query:
				'SELECT timetrack.fn_purge_audit_log($1::int) AS audit_deleted,\n' +
				'       timetrack.fn_purge_outbox($2::int)   AS outbox_deleted,\n' +
				'       CASE WHEN $3::int > 0 THEN timetrack.fn_anonymize_old_events($3::int) ELSE 0 END AS events_anonymized',
			params: `={{ [ ${CFG}.auditRetentionDays, ${CFG}.outboxRetentionDays, ${CFG}.anonymizeEventsAfterDays ] }}`,
		}),
	);
	wf.connect('Config', 'Purge Logs');

	return wf;
}
