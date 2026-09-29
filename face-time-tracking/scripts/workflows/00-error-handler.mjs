import { WorkflowBuilder, NODE, postgres, setNode, email } from '../lib/builder.mjs';

const CFG = "$('Config').first().json";

export function build() {
	const wf = new WorkflowBuilder({
		name: 'Timetrack 00 — Error Handler',
		description: 'Уведомление администратора и запись в аудит при сбое любого воркфлоу учёта времени',
		tags: ['timetrack'],
	});

	wf.sticky(
		'## Обработчик ошибок\n' +
			'Назначьте этот воркфлоу как **Error Workflow** в настройках каждого воркфлоу Timetrack (Settings → Error workflow). ' +
			'При сбое администратор получает письмо с именем воркфлоу, узла и текстом ошибки, а факт сбоя записывается в `timetrack.audit_log`.',
		{ pos: [0, -2], width: 1100, height: 150 },
	);

	wf.add({ name: 'Error Trigger', node: NODE.errorTrigger, pos: [0, 0], parameters: {} });
	wf.add(setNode('Config', { pos: [1, 0], fields: { adminEmail: 'admin@example.com', fromEmail: 'timetrack@example.com' } }));
	wf.add(
		postgres('Audit Failure', {
			pos: [2, 0],
			onError: 'continueRegularOutput',
			query: "SELECT timetrack.fn_audit('n8n', 'system', 'workflow.failed', 'workflow', $1, $2::jsonb) AS audit_id",
			params:
				"={{ [ $('Error Trigger').first().json.workflow?.name ?? 'unknown', ({ execution_id: $('Error Trigger').first().json.execution?.id ?? null, " +
				"node: $('Error Trigger').first().json.execution?.lastNodeExecuted ?? null, message: $('Error Trigger').first().json.execution?.error?.message ?? null, " +
				"url: $('Error Trigger').first().json.execution?.url ?? null }) ] }}",
		}),
	);
	wf.add(
		email('Send Error Alert', {
			pos: [3, 0],
			from: `={{ ${CFG}.fromEmail }}`,
			to: `={{ ${CFG}.adminEmail }}`,
			subject: "=[Учёт времени] Сбой воркфлоу «{{ $('Error Trigger').first().json.workflow?.name ?? 'unknown' }}»",
			html:
				"=<p>Воркфлоу <b>{{ $('Error Trigger').first().json.workflow?.name ?? 'unknown' }}</b> завершился с ошибкой.</p>" +
				"<ul><li>Узел: {{ $('Error Trigger').first().json.execution?.lastNodeExecuted ?? '—' }}</li>" +
				`<li>Ошибка: {{ String($('Error Trigger').first().json.execution?.error?.message ?? '').replace(/[&<>]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;'}[c])) }}</li>` +
				"<li>Выполнение: <a href=\"{{ $('Error Trigger').first().json.execution?.url ?? '#' }}\">{{ $('Error Trigger').first().json.execution?.id ?? '—' }}</a></li></ul>",
			onError: 'stopWorkflow',
		}),
	);
	wf.chain('Error Trigger', 'Config', 'Audit Failure', 'Send Error Alert');
	return wf;
}
