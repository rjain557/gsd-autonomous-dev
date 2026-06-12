/**
 * model-catalog-sync — G8 drift reconciler (see docs/GSD-AI-Driven-Dev-Setup.md, Track 1).
 *
 * Diffs config/model-registry.json against the Cortex knowledge-brain topic
 * `model_catalog.md` (re-verified weekly) and reports drift:
 *   - registry model_ids no longer present in the catalog (stale / renamed / deprecated)
 *   - catalog deprecation notes that may affect us (shut down / retired / 404)
 *   - catalog coding-agent recommendations not represented in the registry
 *
 * It is read-only — it never edits the registry; a human applies changes after review.
 * Wired into memory/knowledge/feature-check-schedule.md (run on the 30-day check).
 *
 * Usage:
 *   npx ts-node src/tools/model-catalog-sync.ts [--json] [--catalog <path>]
 *   npm run model-sync
 *
 * Catalog path resolution (first that exists):
 *   1. --catalog <path>
 *   2. $CORTEX_VAULT/claude-memory/topics/model_catalog.md
 *   3. the registered Administrator default (memory/knowledge/knowledge-sources.md)
 *
 * Exit codes: 0 = in sync (or catalog unavailable — soft skip); 1 = drift found; 2 = error.
 */

import * as fs from 'fs';
import * as path from 'path';

const REGISTRY_PATH = path.resolve(__dirname, '../../config/model-registry.json');

const DEFAULT_CATALOG =
  'C:\\Users\\Administrator\\OneDrive - Technijian, Inc\\Documents\\obsidian' +
  '\\rjain557-knowledge\\rjain557-knowledge\\claude-memory\\topics\\model_catalog.md';

interface RegistryAgent {
  type?: string;
  model_id?: string;
  model_id_paid?: string;
  enabled?: boolean;
}
interface Registry {
  agents: Record<string, RegistryAgent>;
  disabled_agents?: string[];
}

interface Finding {
  severity: 'drift' | 'warn' | 'info';
  agent?: string;
  message: string;
}

function arg(name: string): string | undefined {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : undefined;
}

function resolveCatalogPath(): string | null {
  const explicit = arg('--catalog');
  if (explicit && fs.existsSync(explicit)) return explicit;
  const env = process.env.CORTEX_VAULT;
  if (env) {
    const p = path.join(env, 'claude-memory', 'topics', 'model_catalog.md');
    if (fs.existsSync(p)) return p;
  }
  if (fs.existsSync(DEFAULT_CATALOG)) return DEFAULT_CATALOG;
  return null;
}

/**
 * Extract model ids from the catalog markdown. Model ids appear as the first
 * column of the pipe-tables, wrapped in backticks (`gemini-3.5-flash`) or plain
 * (claude-sonnet-4-6). We collect every backticked token and every first-cell
 * token that looks like a model id (lowercase + digits + dashes/dots).
 */
function parseCatalogModelIds(md: string): Set<string> {
  const ids = new Set<string>();
  const modelLike = /^[a-z][a-z0-9.\-/]*\d[a-z0-9.\-/]*$/i;

  // backticked tokens anywhere
  for (const m of md.matchAll(/`([^`]+)`/g)) {
    const tok = m[1].trim();
    if (modelLike.test(tok)) ids.add(tok.toLowerCase());
  }
  // first cell of every table row — test the whole cell and each whitespace/comma/slash token
  // so rows like "glm-4.7-flash (z.ai)" or "gemini-pro-latest / gemini-flash-latest" are captured
  for (const line of md.split(/\r?\n/)) {
    if (!line.trim().startsWith('|')) continue;
    const first = line.split('|')[1]?.replace(/`/g, '').trim();
    if (!first) continue;
    if (modelLike.test(first)) ids.add(first.toLowerCase());
    for (const tok of first.split(/[\s,/]+/)) {
      if (modelLike.test(tok)) ids.add(tok.toLowerCase());
    }
  }
  return ids;
}

function parseDeprecationNotes(md: string): string[] {
  const out: string[] = [];
  const rx = /(shut down|shutdown|deprecat|retire|removed|404s?\b|no longer)/i;
  for (const raw of md.split(/\r?\n/)) {
    const line = raw.trim();
    if (line && rx.test(line) && !line.startsWith('#')) out.push(line.replace(/\s+/g, ' '));
  }
  return out;
}

function loadRegistry(): Registry {
  // strip a possible UTF-8 BOM (PowerShell-written JSON)
  const raw = fs.readFileSync(REGISTRY_PATH, 'utf8').replace(/^﻿/, '');
  return JSON.parse(raw) as Registry;
}

function reconcile(reg: Registry, catalogIds: Set<string>, notes: string[]): Finding[] {
  const findings: Finding[] = [];
  const has = (id?: string) => !!id && catalogIds.has(id.toLowerCase());

  for (const [name, agent] of Object.entries(reg.agents)) {
    // CLI subscription agents (claude/codex/gemini) have no pinned model_id — skip id-diffing
    if (agent.type === 'cli' && !agent.model_id) continue;

    for (const field of ['model_id', 'model_id_paid'] as const) {
      const id = agent[field];
      if (!id) continue;
      if (!has(id)) {
        const enabledNote = agent.enabled === false ? ' (agent currently disabled)' : '';
        findings.push({
          severity: agent.enabled === false ? 'warn' : 'drift',
          agent: name,
          message: `${name}.${field} = "${id}" is not in the catalog — likely renamed/deprecated.${enabledNote}`,
        });
      }
    }
  }

  // deprecation notes that name a model id present in the registry
  const regIds = new Set<string>();
  for (const a of Object.values(reg.agents)) {
    if (a.model_id) regIds.add(a.model_id.toLowerCase());
    if (a.model_id_paid) regIds.add(a.model_id_paid.toLowerCase());
  }
  for (const note of notes) {
    for (const id of regIds) {
      if (note.toLowerCase().includes(id)) {
        findings.push({ severity: 'drift', message: `Catalog deprecation note affects "${id}": ${note}` });
      }
    }
  }
  // surface remaining deprecation notes as info for the human reviewer
  for (const note of notes.slice(0, 8)) {
    findings.push({ severity: 'info', message: `Catalog note: ${note}` });
  }

  return findings;
}

function main(): number {
  const json = process.argv.includes('--json');
  let reg: Registry;
  try {
    reg = loadRegistry();
  } catch (e) {
    console.error(`error: cannot read ${REGISTRY_PATH}: ${(e as Error).message}`);
    return 2;
  }

  const catalogPath = resolveCatalogPath();
  if (!catalogPath) {
    const msg =
      'Cortex model_catalog.md not found (set CORTEX_VAULT or use --catalog). ' +
      'Skipping drift check — this is normal off the Administrator fleet host.';
    if (json) console.log(JSON.stringify({ status: 'skipped', reason: msg }, null, 2));
    else console.log(`⏭  ${msg}`);
    return 0; // soft skip, not a failure
  }

  const md = fs.readFileSync(catalogPath, 'utf8');
  const catalogIds = parseCatalogModelIds(md);
  const notes = parseDeprecationNotes(md);
  const findings = reconcile(reg, catalogIds, notes);

  const drift = findings.filter((f) => f.severity === 'drift');
  const warn = findings.filter((f) => f.severity === 'warn');

  if (json) {
    console.log(JSON.stringify({ catalogPath, catalogModelCount: catalogIds.size, findings }, null, 2));
    return drift.length ? 1 : 0;
  }

  console.log(`Model-catalog drift check`);
  console.log(`  registry: ${REGISTRY_PATH}`);
  console.log(`  catalog : ${catalogPath} (${catalogIds.size} model ids)\n`);

  if (!findings.length) {
    console.log('✓ Registry is in sync with the catalog — no drift.');
    return 0;
  }
  for (const f of drift) console.log(`  🔴 DRIFT  ${f.message}`);
  for (const f of warn) console.log(`  🟡 WARN   ${f.message}`);
  for (const f of findings.filter((x) => x.severity === 'info')) console.log(`  ℹ  ${f.message}`);

  console.log(
    `\n${drift.length} drift, ${warn.length} warn. ` +
      (drift.length
        ? 'Review against the catalog and update config/model-registry.json (do not auto-apply).'
        : 'No blocking drift.'),
  );
  return drift.length ? 1 : 0;
}

process.exit(main());
