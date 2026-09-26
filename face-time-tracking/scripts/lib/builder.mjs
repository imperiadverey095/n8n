// -----------------------------------------------------------------------------
//  Мини-DSL для сборки JSON-воркфлоу n8n.
//  Идея: описывать ноды и связи кодом (проверяемо, без ручной правки JSON),
//  а результат — обычные файлы workflows/*.json, которые импортируются в n8n.
//  Идентификаторы нод детерминированы (sha1 от имени), поэтому повторная
//  сборка даёт побайтно тот же JSON и чистый git diff.
// -----------------------------------------------------------------------------
import { createHash } from 'node:crypto';

export const CREDENTIALS = {
	postgres: { id: 'timetrack-postgres', name: 'Timetrack Postgres' },
	faceApi: { id: 'timetrack-compreface-key', name: 'CompreFace Recognition API Key' },
	smtp: { id: 'timetrack-smtp', name: 'Timetrack SMTP' },
	hrApi: { id: 'timetrack-hr-api', name: 'HR System API' },
};

// Версии нод выбраны так, чтобы они были и в этом репозитории, и в актуальных
// релизах n8n (см. docs/n8n-node-versions.md).
export const NODE = {
	webhook: { type: 'n8n-nodes-base.webhook', typeVersion: 2 },
	respond: { type: 'n8n-nodes-base.respondToWebhook', typeVersion: 1.1 },
	http: { type: 'n8n-nodes-base.httpRequest', typeVersion: 4.2 },
	postgres: { type: 'n8n-nodes-base.postgres', typeVersion: 2.5 },
	code: { type: 'n8n-nodes-base.code', typeVersion: 2 },
	if: { type: 'n8n-nodes-base.if', typeVersion: 2.2 },
	switch: { type: 'n8n-nodes-base.switch', typeVersion: 3.2 },
	filter: { type: 'n8n-nodes-base.filter', typeVersion: 2.2 },
	set: { type: 'n8n-nodes-base.set', typeVersion: 3.4 },
	schedule: { type: 'n8n-nodes-base.scheduleTrigger', typeVersion: 1.2 },
	email: { type: 'n8n-nodes-base.emailSend', typeVersion: 2.1 },
	convertToFile: { type: 'n8n-nodes-base.convertToFile', typeVersion: 1.1 },
	crypto: { type: 'n8n-nodes-base.crypto', typeVersion: 1 },
	splitOut: { type: 'n8n-nodes-base.splitOut', typeVersion: 1 },
	errorTrigger: { type: 'n8n-nodes-base.errorTrigger', typeVersion: 1 },
	noOp: { type: 'n8n-nodes-base.noOp', typeVersion: 1 },
	stickyNote: { type: 'n8n-nodes-base.stickyNote', typeVersion: 1 },
};

const GRID_X = 280;
const GRID_Y = 200;
const ORIGIN = [160, 300];

export function uuidFrom(seed) {
	const h = createHash('sha1').update(String(seed)).digest('hex');
	// формат UUID v5-подобный (версия 5, вариант RFC 4122)
	return [
		h.slice(0, 8),
		h.slice(8, 12),
		'5' + h.slice(13, 16),
		((parseInt(h.slice(16, 18), 16) & 0x3f) | 0x80).toString(16).padStart(2, '0') + h.slice(18, 20),
		h.slice(20, 32),
	].join('-');
}

// Алфавит идентификаторов n8n (NANOID_ALPHABET), 16 символов.
const ID_ALPHABET = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';

/**
 * Стабильный идентификатор воркфлоу из его имени. `n8n import:workflow`
 * делает upsert по полю `id`: без него каждый импорт создаёт ещё одну копию
 * воркфлоу, а вебхуки остаются за старой. Детерминированный id превращает
 * повторный импорт в обновление на месте.
 */
export function idFrom(seed) {
	const h = createHash('sha1').update(String(seed)).digest();
	let out = '';
	for (let i = 0; i < 16; i += 1) out += ID_ALPHABET[h[i] % ID_ALPHABET.length];
	return out;
}

/** Условие для нод If / Filter / Switch (формат filter v2). */
export function cond(leftValue, operator, rightValue = '', id = undefined) {
	const [type, operation] = operator.split(':');
	const singleValue = ['true', 'false', 'exists', 'notExists', 'empty', 'notEmpty'].includes(operation);
	const c = {
		id: id ?? uuidFrom(`cond:${leftValue}:${operator}:${rightValue}`),
		leftValue,
		rightValue,
		operator: singleValue ? { type, operation, singleValue: true } : { type, operation },
	};
	return c;
}

export function conditions(list, combinator = 'and') {
	return {
		options: { caseSensitive: true, leftValue: '', typeValidation: 'strict', version: 2 },
		conditions: list,
		combinator,
	};
}

/** Условие «выражение истинно» — самый удобный способ для сложной логики. */
export function truthy(expression) {
	return conditions([cond(expression, 'boolean:true', '')]);
}

export class WorkflowBuilder {
	constructor({ name, description = '', tags = [] }) {
		this.name = name;
		this.description = description;
		this.tags = tags;
		this.nodes = [];
		this.connections = {};
		this.settings = {
			executionOrder: 'v1',
			saveManualExecutions: true,
			saveExecutionProgress: false,
			saveDataErrorExecution: 'all',
			saveDataSuccessExecution: 'all',
			timezone: 'UTC',
		};
	}

	position([col, row]) {
		return [ORIGIN[0] + col * GRID_X, ORIGIN[1] + row * GRID_Y];
	}

	add(spec) {
		const {
			name,
			node,
			type,
			typeVersion,
			parameters = {},
			pos = [0, 0],
			credentials,
			notes,
			onError,
			alwaysOutputData,
			retryOnFail,
			maxTries,
			waitBetweenTries,
			executeOnce,
			disabled,
		} = spec;
		if (!name) throw new Error('node name is required');
		if (this.nodes.some((n) => n.name === name)) throw new Error(`duplicate node name: ${name}`);
		const base = node ?? { type, typeVersion };
		if (!base.type || !base.typeVersion) throw new Error(`node type/version missing for ${name}`);
		const n = {
			parameters,
			id: uuidFrom(`${this.name}:${name}`),
			name,
			type: base.type,
			typeVersion: base.typeVersion,
			position: this.position(pos),
		};
		if (base.type === NODE.webhook.type) n.webhookId = uuidFrom(`${this.name}:${name}:webhook`);
		if (credentials) n.credentials = credentials;
		if (notes) {
			n.notes = notes;
			n.notesInFlow = true;
		}
		if (onError) n.onError = onError;
		if (alwaysOutputData) n.alwaysOutputData = true;
		if (retryOnFail) {
			n.retryOnFail = true;
			n.maxTries = maxTries ?? 3;
			n.waitBetweenTries = waitBetweenTries ?? 1000;
		}
		if (executeOnce) n.executeOnce = true;
		if (disabled) n.disabled = true;
		this.nodes.push(n);
		return name;
	}

	connect(from, to, { output = 0, input = 0 } = {}) {
		for (const nm of [from, to]) {
			if (!this.nodes.some((n) => n.name === nm)) throw new Error(`connect: unknown node "${nm}"`);
		}
		const src = (this.connections[from] ??= { main: [] });
		while (src.main.length <= output) src.main.push([]);
		src.main[output].push({ node: to, type: 'main', index: input });
		return this;
	}

	/** Цепочка: chain('A','B','C') = A→B→C */
	chain(...names) {
		for (let i = 0; i < names.length - 1; i++) this.connect(names[i], names[i + 1]);
		return this;
	}

	sticky(content, { pos = [0, -2], width = 520, height = 220, color = 4 } = {}) {
		const n = {
			parameters: { content, height, width, color },
			id: uuidFrom(`${this.name}:sticky:${content.slice(0, 40)}:${pos.join(',')}`),
			name: `Sticky Note ${this.nodes.filter((x) => x.type === NODE.stickyNote.type).length + 1}`,
			type: NODE.stickyNote.type,
			typeVersion: NODE.stickyNote.typeVersion,
			position: this.position(pos),
		};
		this.nodes.push(n);
		return this;
	}

	toJSON() {
		// связи должны ссылаться только на существующие ноды
		for (const [from, outs] of Object.entries(this.connections)) {
			for (const out of outs.main) {
				for (const c of out) {
					if (!this.nodes.some((n) => n.name === c.node)) throw new Error(`dangling connection ${from} → ${c.node}`);
				}
			}
		}
		return {
			// id обязателен: импорт делает upsert по нему, иначе плодятся копии.
			id: idFrom(`workflow:${this.name}`),
			name: this.name,
			nodes: this.nodes,
			connections: this.connections,
			settings: this.settings,
			pinData: {},
			// Теги в экспорт не включаются: `n8n import:workflow --separate` создаёт тег
			// на каждый файл и падает на уникальности имени, если тег общий.
			// Назначайте теги в интерфейсе после импорта.
			meta: { templateCredsSetupCompleted: false, description: this.description, tags: this.tags },
			active: false,
		};
	}
}

// -----------------------------------------------------------------------------
//  Фабрики типовых нод
// -----------------------------------------------------------------------------

export function webhook(name, { path, method = 'POST', pos, notes, options = {} }) {
	return {
		name,
		node: NODE.webhook,
		pos,
		notes,
		parameters: {
			httpMethod: method,
			path,
			responseMode: 'responseNode',
			// ignoreBots не включаем: фильтр по User-Agent может отсечь киоски/мобильные клиенты (okhttp, Dart, curl)
			options: { ...options },
		},
	};
}

/** Ответ JSON: body — выражение n8n, возвращающее объект. */
export function respondJson(name, { body, code = 200, pos, headers = [] }) {
	const options = { responseCode: code };
	if (headers.length) options.responseHeaders = { entries: headers };
	return {
		name,
		node: NODE.respond,
		pos,
		parameters: { respondWith: 'json', responseBody: body, options },
	};
}

export function respondFirstItem(name, { code = 200, pos }) {
	return {
		name,
		node: NODE.respond,
		pos,
		parameters: { respondWith: 'firstIncomingItem', options: { responseCode: code } },
	};
}

export function respondAllItems(name, { code = 200, pos }) {
	return {
		name,
		node: NODE.respond,
		pos,
		parameters: { respondWith: 'allIncomingItems', options: { responseCode: code } },
	};
}

export function respondText(name, { body, code = 200, contentType = 'text/plain; charset=utf-8', pos }) {
	return {
		name,
		node: NODE.respond,
		pos,
		parameters: {
			respondWith: 'text',
			responseBody: body,
			options: { responseCode: code, responseHeaders: { entries: [{ name: 'Content-Type', value: contentType }] } },
		},
	};
}

export function respondBinary(name, { code = 200, pos, headers = [] }) {
	const options = { responseCode: code };
	if (headers.length) options.responseHeaders = { entries: headers };
	return {
		name,
		node: NODE.respond,
		pos,
		parameters: { respondWith: 'binary', responseDataSource: 'automatically', options },
	};
}

/**
 * Postgres: выполнить запрос с позиционными параметрами $1..$n.
 * params — выражение вида "={{ [ a, b, c ] }}" (массив значений; объекты
 * сериализуются в JSON автоматически, начиная с версии ноды 2.5).
 */
export function postgres(name, { query, params, pos, notes, alwaysOutputData, batching, onError, executeOnce }) {
	const options = {};
	if (params) options.queryReplacement = params;
	if (batching) options.queryBatching = batching;
	return {
		name,
		node: NODE.postgres,
		pos,
		notes,
		alwaysOutputData,
		onError,
		executeOnce,
		credentials: { postgres: CREDENTIALS.postgres },
		parameters: { operation: 'executeQuery', query, options },
	};
}

export function code(name, { js, pos, notes, mode = 'runOnceForAllItems', onError }) {
	return {
		name,
		node: NODE.code,
		pos,
		notes,
		onError,
		parameters: { mode, jsCode: js.trim() + '\n' },
	};
}

export function ifNode(name, { conditions: c, pos, notes }) {
	return { name, node: NODE.if, pos, notes, parameters: { conditions: c, options: {} } };
}

export function filterNode(name, { conditions: c, pos, notes }) {
	return { name, node: NODE.filter, pos, notes, parameters: { conditions: c, options: {} } };
}

/** Switch по правилам: rules = [{ key: 'json', conditions }] → выходы в том же порядке. */
export function switchNode(name, { rules, pos, notes, fallback = 'none' }) {
	return {
		name,
		node: NODE.switch,
		pos,
		notes,
		parameters: {
			rules: {
				values: rules.map((r) => ({ conditions: r.conditions, renameOutput: true, outputKey: r.key })),
			},
			options: { fallbackOutput: fallback },
		},
	};
}

/** Edit Fields (Set): fields = { name: value | {value, type} } */
export function setNode(name, { fields, pos, notes, includeOtherFields = false }) {
	const assignments = Object.entries(fields).map(([key, v]) => {
		const spec = typeof v === 'object' && v !== null && 'value' in v ? v : { value: v, type: guessType(v) };
		return { id: uuidFrom(`set:${name}:${key}`), name: key, value: spec.value, type: spec.type };
	});
	return {
		name,
		node: NODE.set,
		pos,
		notes,
		parameters: { mode: 'manual', assignments: { assignments }, includeOtherFields, options: {} },
	};
}

function guessType(v) {
	if (typeof v === 'number') return 'number';
	if (typeof v === 'boolean') return 'boolean';
	if (Array.isArray(v)) return 'array';
	if (typeof v === 'object' && v !== null) return 'object';
	return 'string';
}

export function httpRequest(name, spec) {
	const {
		method = 'GET',
		url,
		auth, // { type: 'httpHeaderAuth', credential }
		query = [],
		body, // { contentType: 'json', json } | { contentType: 'multipart-form-data', parameters }
		timeout = 30000,
		fullResponse = true,
		neverError = true,
		pos,
		notes,
		onError = 'continueRegularOutput',
		retry = true,
		batching,
	} = spec;
	const parameters = {
		method,
		url,
		authentication: auth ? 'genericCredentialType' : 'none',
		options: { timeout, response: { response: { fullResponse, neverError } } },
	};
	if (batching) parameters.options.batching = { batch: batching };
	const credentials = {};
	if (auth) {
		parameters.genericAuthType = auth.type;
		credentials[auth.type] = auth.credential;
	}
	if (query.length) {
		parameters.sendQuery = true;
		parameters.specifyQuery = 'keypair';
		parameters.queryParameters = { parameters: query };
	}
	if (body) {
		parameters.sendBody = true;
		parameters.contentType = body.contentType;
		if (body.contentType === 'json') {
			parameters.specifyBody = 'json';
			parameters.jsonBody = body.json;
		} else if (body.contentType === 'multipart-form-data') {
			parameters.bodyParameters = { parameters: body.parameters };
		}
	}
	return {
		name,
		node: NODE.http,
		pos,
		notes,
		onError,
		retryOnFail: retry,
		maxTries: 3,
		waitBetweenTries: 1500,
		parameters,
		credentials: Object.keys(credentials).length ? credentials : undefined,
	};
}

export function cryptoHashBinary(name, { binaryPropertyName = 'image', dataPropertyName = 'image_hash', pos }) {
	return {
		name,
		node: NODE.crypto,
		pos,
		parameters: {
			action: 'hash',
			type: 'SHA256',
			binaryData: true,
			binaryPropertyName,
			dataPropertyName,
			encoding: 'hex',
		},
	};
}

export function schedule(name, { cron, pos, notes }) {
	return {
		name,
		node: NODE.schedule,
		pos,
		notes,
		parameters: { rule: { interval: [{ field: 'cronExpression', expression: cron }] } },
	};
}

export function email(name, { from, to, subject, html, attachments, pos, notes, onError = 'continueRegularOutput' }) {
	const options = { appendAttribution: false };
	if (attachments) options.fileAttachments = attachments;
	return {
		name,
		node: NODE.email,
		pos,
		notes,
		onError,
		credentials: { smtp: CREDENTIALS.smtp },
		parameters: { fromEmail: from, toEmail: to, subject, emailFormat: 'html', html, options },
	};
}

export function convertToCsv(name, { fileName, delimiter, pos }) {
	return {
		name,
		node: NODE.convertToFile,
		pos,
		parameters: {
			operation: 'csv',
			binaryPropertyName: 'data',
			options: { fileName, headerRow: true, delimiter },
		},
	};
}

export function splitOut(name, { field, pos }) {
	return { name, node: NODE.splitOut, pos, parameters: { fieldToSplitOut: field, include: 'noOtherFields', options: {} } };
}

export function noOp(name, { pos }) {
	return { name, node: NODE.noOp, pos, parameters: {} };
}

/** Выражение для чтения API-токена из заголовков вебхука. */
export function tokenExpr(webhookName) {
	return (
		`={{ [ (($('${webhookName}').first().json.headers['x-api-token'] ` +
		`|| ($('${webhookName}').first().json.headers.authorization || '').replace(/^Bearer\\s+/i, '')) || '') ] }}`
	);
}

export const AUTH_QUERY =
	'SELECT client_id, client_name, role, employee_id, location FROM timetrack.fn_authenticate($1)';

/** Нода аутентификации по токену для указанного вебхука. */
export function authenticate(name, webhookName, pos) {
	return postgres(name, {
		query: AUTH_QUERY,
		params: tokenExpr(webhookName),
		pos,
		alwaysOutputData: true,
		notes: 'Токен из заголовка X-Api-Token или Authorization: Bearer. Пустой результат = неверный токен.',
	});
}

export function unauthorized(name, pos) {
	return respondJson(name, {
		code: 401,
		pos,
		body: "={{ ({ ok: false, code: 'unauthorized', message: 'Неверный или отсутствующий API-токен' }) }}",
	});
}
