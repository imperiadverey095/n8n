#!/usr/bin/env node
// Структурная проверка workflows/*.json без запуска n8n:
//  * уникальные имена нод, связи ссылаются на существующие ноды;
//  * тип и версия каждой ноды существуют в исходниках packages/nodes-base
//    (если скрипт запущен внутри репозитория n8n);
//  * число параметров Postgres-запроса ($1..$n) совпадает с длиной массива
//    в options.queryReplacement;
//  * выражения "={{ ... }}" сбалансированы по скобкам.
//   node scripts/validate-workflows.mjs
import { readdirSync, readFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const wfDir = join(here, '..', 'workflows');
const nodesBase = join(here, '..', '..', 'packages', 'nodes-base');
const canCheckTypes = existsSync(join(nodesBase, 'package.json'));

const errors = [];
const warnings = [];

// ---------- реестр нод из исходников ----------
const registry = new Map(); // typeName → Set(versions)
if (canCheckTypes) {
	const pkg = JSON.parse(readFileSync(join(nodesBase, 'package.json'), 'utf8'));
	for (const distPath of pkg.n8n.nodes) {
		const tsPath = join(nodesBase, distPath.replace(/^dist\//, '').replace(/\.js$/, '.ts'));
		if (!existsSync(tsPath)) continue;
		const src = readFileSync(tsPath, 'utf8');
		// имя типа — первое поле name: внутри объекта description (до него могут быть другие константы)
		const descStart = src.search(/description(?:\s*:\s*INodeType(?:Base)?Description)?\s*=\s*\{/);
		const nameMatch = src.slice(descStart >= 0 ? descStart : 0).match(/\bname:\s*'([A-Za-z0-9]+)'/);
		if (!nameMatch) continue;
		const versions = new Set();
		const collect = (text) => {
			for (const m of text.matchAll(/\bversion:\s*\[([^\]]+)\]/g)) m[1].split(',').forEach((v) => versions.add(Number(v.trim())));
			for (const m of text.matchAll(/\bversion:\s*([0-9.]+)\s*,/g)) versions.add(Number(m[1]));
			for (const m of text.matchAll(/^\s*([0-9.]+):\s*new\s+\w+/gm)) versions.add(Number(m[1]));
		};
		collect(src);
		// версионированные ноды держат версии в подпапках (V1/, v2/, ...)
		const dir = dirname(tsPath);
		const walk = (d, depth) => {
			if (depth > 2) return;
			for (const entry of readdirSync(d, { withFileTypes: true })) {
				const p = join(d, entry.name);
				if (entry.isDirectory()) walk(p, depth + 1);
				else if (/\.node\.ts$/.test(entry.name) && p !== tsPath) collect(readFileSync(p, 'utf8'));
			}
		};
		walk(dir, 0);
		const key = `n8n-nodes-base.${nameMatch[1]}`;
		const existing = registry.get(key) ?? new Set();
		versions.forEach((v) => Number.isFinite(v) && existing.add(v));
		registry.set(key, existing);
	}
}

function splitTopLevel(text) {
	const parts = [];
	let depth = 0, quote = null, cur = '';
	for (let i = 0; i < text.length; i++) {
		const ch = text[i];
		if (quote) {
			cur += ch;
			if (ch === '\\') { cur += text[++i] ?? ''; continue; }
			if (ch === quote) quote = null;
			continue;
		}
		if (ch === "'" || ch === '"' || ch === '`') { quote = ch; cur += ch; continue; }
		if (ch === '/' && text[i + 1] !== '/' && /[=(,\[]\s*$/.test(cur)) {
			// литерал регулярного выражения
			let j = i + 1;
			while (j < text.length && text[j] !== '/') { if (text[j] === '\\') j++; j++; }
			cur += text.slice(i, j + 1); i = j; continue;
		}
		if ('([{'.includes(ch)) depth++;
		if (')]}'.includes(ch)) depth--;
		if (ch === ',' && depth === 0) { parts.push(cur.trim()); cur = ''; continue; }
		cur += ch;
	}
	if (cur.trim()) parts.push(cur.trim());
	return parts;
}

function checkExpression(where, value) {
	if (typeof value !== 'string' || !value.startsWith('=')) return;
	const opens = (value.match(/{{/g) || []).length;
	const closes = (value.match(/}}/g) || []).length;
	if (opens !== closes) errors.push(`${where}: несбалансированные {{ }} в выражении`);
	for (const m of value.matchAll(/{{([\s\S]*?)}}/g)) {
		const body = m[1];
		let depth = 0;
		for (const ch of body) { if ('([{'.includes(ch)) depth++; if (')]}'.includes(ch)) depth--; }
		if (depth !== 0) errors.push(`${where}: несбалансированные скобки внутри {{ }}: ${body.slice(0, 60)}…`);
	}
}

function walkParams(where, obj) {
	if (typeof obj === 'string') return checkExpression(where, obj);
	if (Array.isArray(obj)) return obj.forEach((v, i) => walkParams(`${where}[${i}]`, v));
	if (obj && typeof obj === 'object') for (const [k, v] of Object.entries(obj)) walkParams(`${where}.${k}`, v);
}

const files = readdirSync(wfDir).filter((f) => f.endsWith('.json')).sort();
let nodeCount = 0;
for (const file of files) {
	const wf = JSON.parse(readFileSync(join(wfDir, file), 'utf8'));
	const names = new Set();
	const triggers = wf.nodes.filter((n) => /trigger|webhook$/i.test(n.type));
	if (!triggers.length) errors.push(`${file}: нет триггера`);
	for (const n of wf.nodes) {
		const where = `${file} → "${n.name}"`;
		if (names.has(n.name)) errors.push(`${where}: дублирующееся имя ноды`);
		names.add(n.name);
		nodeCount++;
		if (!n.id || !Array.isArray(n.position) || n.position.length !== 2) errors.push(`${where}: нет id/position`);
		if (canCheckTypes) {
			const versions = registry.get(n.type);
			if (!versions) errors.push(`${where}: неизвестный тип ноды ${n.type}`);
			else if (!versions.has(n.typeVersion)) errors.push(`${where}: версии ${n.typeVersion} нет у ${n.type} (есть: ${[...versions].sort((a, b) => a - b).join(', ')})`);
		}
		walkParams(where, n.parameters);
		if (n.type === 'n8n-nodes-base.postgres') {
			const q = n.parameters.query || '';
			const maxParam = Math.max(0, ...[...q.matchAll(/\$(\d+)/g)].map((m) => Number(m[1])));
			const repl = n.parameters.options?.queryReplacement ?? '';
			const m = repl.match(/^=\{\{\s*\[([\s\S]*)\]\s*\}\}$/);
			if (maxParam > 0 && !m) errors.push(`${where}: запрос использует $1..$${maxParam}, но queryReplacement не массив`);
			else if (m) {
				const count = splitTopLevel(m[1]).length;
				if (count !== maxParam) errors.push(`${where}: в запросе ${maxParam} параметров, в queryReplacement — ${count}`);
			}
			if (/{{/.test(q)) warnings.push(`${where}: выражение внутри SQL — проверьте на инъекции`);
		}
		if (n.type === 'n8n-nodes-base.webhook' && !n.webhookId) errors.push(`${where}: у Webhook нет webhookId`);
		if (n.type === 'n8n-nodes-base.webhook' && n.parameters.responseMode === 'responseNode') {
			const hasRespond = wf.nodes.some((x) => x.type === 'n8n-nodes-base.respondToWebhook');
			if (!hasRespond) errors.push(`${where}: responseMode=responseNode без ноды Respond to Webhook`);
		}
	}
	for (const [from, outs] of Object.entries(wf.connections)) {
		if (!names.has(from)) errors.push(`${file}: связь от несуществующей ноды "${from}"`);
		for (const out of outs.main) for (const c of out) if (!names.has(c.node)) errors.push(`${file}: связь "${from}" → несуществующая нода "${c.node}"`);
	}
	// каждая не-триггерная нода (кроме заметок) должна иметь вход
	const withInput = new Set(Object.values(wf.connections).flatMap((o) => o.main.flat().map((c) => c.node)));
	for (const n of wf.nodes) {
		if (n.type === 'n8n-nodes-base.stickyNote') continue;
		const isTrigger = /trigger|webhook$/i.test(n.type);
		if (!isTrigger && !withInput.has(n.name)) errors.push(`${file} → "${n.name}": нода без входящей связи`);
	}
}

for (const w of warnings) console.log('WARN', w);
if (errors.length) {
	for (const e of errors) console.error('ERROR', e);
	console.error(`\n${errors.length} ошибок в ${files.length} файлах`);
	process.exit(1);
}
console.log(`OK: ${files.length} воркфлоу, ${nodeCount} нод, ${canCheckTypes ? `типы/версии проверены по ${registry.size} нодам репозитория` : 'типы не проверялись (запуск вне репозитория n8n)'}`);
