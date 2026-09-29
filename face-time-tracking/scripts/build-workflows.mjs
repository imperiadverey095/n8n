#!/usr/bin/env node
// Собирает workflows/*.json из описаний в scripts/workflows/*.mjs.
//   node scripts/build-workflows.mjs
import { readdirSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join, basename } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const srcDir = join(here, 'workflows');
const outDir = join(here, '..', 'workflows');
mkdirSync(outDir, { recursive: true });

const files = readdirSync(srcDir).filter((f) => /^\d\d-.*\.mjs$/.test(f)).sort();
let total = 0;
for (const file of files) {
	const mod = await import(pathToFileURL(join(srcDir, file)).href);
	const wf = mod.build();
	const json = wf.toJSON();
	const out = join(outDir, basename(file, '.mjs') + '.json');
	writeFileSync(out, JSON.stringify(json, null, 2) + '\n');
	const nodes = json.nodes.filter((n) => n.type !== 'n8n-nodes-base.stickyNote').length;
	total += nodes;
	console.log(`${basename(out).padEnd(40)} ${String(nodes).padStart(3)} nodes  "${json.name}"`);
}
console.log(`\n${files.length} workflows, ${total} nodes written to ${outDir}`);
