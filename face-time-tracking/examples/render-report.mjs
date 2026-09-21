#!/usr/bin/env node
// Формирует отчёты тем же кодом, что нода "Build Report" воркфлоу 03, на данных из БД.
// Пишет examples/output/report.html, report.csv, report.json.
//   DATABASE_URL=postgres://... node examples/render-report.mjs   (или переменные PG*)
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..');
const out = join(here, 'output');
mkdirSync(out, { recursive: true });

function sql(query) {
	const args = ['-X', '-At', '-v', 'ON_ERROR_STOP=1', '-c', query];
	if (process.env.DATABASE_URL) args.unshift(process.env.DATABASE_URL);
	return execFileSync('psql', args, { encoding: 'utf8' }).trim();
}

// период: неделя, в которую попал демо-день (та же логика, что в examples/demo-day.sql)
const period = JSON.parse(sql(`
  SELECT json_build_object('from', date_trunc('week', d)::date, 'to', (date_trunc('week', d) + interval '6 days')::date, 'day', d)
    FROM (SELECT CASE WHEN (now() AT TIME ZONE 'Europe/Moscow')::time >= time '19:00'
                      THEN (now() AT TIME ZONE 'Europe/Moscow')::date
                      ELSE (now() AT TIME ZONE 'Europe/Moscow')::date - 1 END AS d) x`));
const rows = JSON.parse(sql(`
  SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json)
    FROM (SELECT employee, days, sessions, corrections, totals
            FROM timetrack.fn_timesheet(NULL, '${period.from}'::date, '${period.to}'::date, NULL, true)) t`));

const wf = JSON.parse(readFileSync(join(root, 'workflows', '03-attendance-reports.json'), 'utf8'));
const buildReport = wf.nodes.find((n) => n.name === 'Build Report').parameters.jsCode;

// минимальная эмуляция окружения Code-ноды n8n: $input, $('Node')
function runBuildReport(params) {
	const nodes = { 'Resolve Parameters': params };
	const $ = (name) => ({ first: () => ({ json: nodes[name] }), all: () => [{ json: nodes[name] }] });
	const $input = { all: () => rows.map((json) => ({ json })), first: () => ({ json: rows[0] }) };
	return new Function('$', '$input', '$json', `return (async function () {${buildReport}\n})()`)($, $input, rows[0]);
}

const base = { from: period.from, to: period.to, requester: 'HR portal', csv_delimiter: ';', company_name: 'Демо-компания' };
const html = (await runBuildReport({ ...base, type: 'detailed', format: 'html' }))[0].json.html;
writeFileSync(join(out, 'report.html'), html);

const csvItems = await runBuildReport({ ...base, type: 'standard', format: 'csv' });
const columns = Object.keys(csvItems[0].json);
const csv = [columns.join(';'), ...csvItems.map((i) => columns.map((c) => String(i.json[c] ?? '').replace(/;/g, ',')).join(';'))].join('\n');
writeFileSync(join(out, 'report.csv'), '﻿' + csv + '\n');

const json = (await runBuildReport({ ...base, type: 'summary', format: 'json' }))[0].json;
writeFileSync(join(out, 'report.json'), JSON.stringify(json, null, 2) + '\n');

console.log(`report period ${period.from} — ${period.to} (demo day ${period.day}): ${rows.length} employees`);
console.log(`  ${join('examples/output', 'report.html')}  ${html.length} bytes, ${(html.match(/<table/g) || []).length} tables`);
console.log(`  ${join('examples/output', 'report.csv')}   ${csvItems.length} rows × ${columns.length} columns`);
console.log(`  ${join('examples/output', 'report.json')}  summary for ${json.data.length} employees`);
