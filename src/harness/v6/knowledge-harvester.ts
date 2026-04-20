// ═══════════════════════════════════════════════════════════
// GSD V6 — Knowledge Harvester (recurring job)
// Weekly pass over memory/decisions/ + SQLite decisions table
// to distill patterns into:
//   memory/knowledge/patterns.md         — recurring remediations
//   memory/knowledge/anti-patterns.md    — recurring stuck-loop sigs
// ═══════════════════════════════════════════════════════════

import * as fs from 'fs';
import * as path from 'path';
import type { StateDB } from './state-db';

export interface HarvestPattern {
  category: string;
  signature: string;
  occurrences: number;
  firstSeen: string;
  lastSeen: string;
  sampleEvidence: string;
}

export interface HarvestReport {
  scannedAt: string;
  decisionCount: number;
  patterns: HarvestPattern[];
  antiPatterns: HarvestPattern[];
  outputFiles: string[];
}

export interface HarvesterOptions {
  vaultPath: string;
  db: StateDB;
  sinceDays?: number;      // default 7
  writeFiles?: boolean;    // default true
}

/** Bucket decisions by {action} — the action verb reveals the pattern. */
function bucketByAction(
  decisions: Array<{ timestamp: string; action: string; reason: string; evidence: string }>,
): Map<string, HarvestPattern> {
  const map = new Map<string, HarvestPattern>();
  for (const d of decisions) {
    const key = d.action;
    const existing = map.get(key);
    if (existing) {
      existing.occurrences++;
      if (d.timestamp < existing.firstSeen) existing.firstSeen = d.timestamp;
      if (d.timestamp > existing.lastSeen) existing.lastSeen = d.timestamp;
    } else {
      map.set(key, {
        category: d.action.split('-')[0] ?? 'misc',
        signature: d.action,
        occurrences: 1,
        firstSeen: d.timestamp,
        lastSeen: d.timestamp,
        sampleEvidence: `${d.reason} | ${d.evidence}`.slice(0, 400),
      });
    }
  }
  return map;
}

export async function runKnowledgeHarvest(opts: HarvesterOptions): Promise<HarvestReport> {
  const sinceDays = opts.sinceDays ?? 7;
  const cutoffMs = Date.now() - sinceDays * 24 * 60 * 60 * 1000;
  const cutoffIso = new Date(cutoffMs).toISOString();

  // Gather decisions from SQLite across all milestones (simplified scan)
  const milestones = opts.db.listMilestones();
  const allDecisions: Array<{ timestamp: string; action: string; reason: string; evidence: string }> = [];
  for (const m of milestones) {
    const ds = opts.db.listDecisionsForMilestone(m.id);
    for (const d of ds) {
      if (d.timestamp >= cutoffIso) {
        allDecisions.push({ timestamp: d.timestamp, action: d.action, reason: d.reason, evidence: d.evidence });
      }
    }
  }

  const buckets = bucketByAction(allDecisions);

  // Patterns: recurring remediations or successful actions
  const patterns: HarvestPattern[] = [];
  // Anti-patterns: stuck loops or repeated failures
  const antiPatterns: HarvestPattern[] = [];

  for (const p of buckets.values()) {
    if (p.occurrences < 2) continue;
    if (/stuck|failed|escalation|halt|rollback/i.test(p.signature)) {
      antiPatterns.push(p);
    } else {
      patterns.push(p);
    }
  }

  // Also ingest StuckDetector table
  const stuckRows = opts.db.listStuckPatterns(2);
  for (const s of stuckRows) {
    antiPatterns.push({
      category: 'stuck-loop',
      signature: s.signatureHash,
      occurrences: s.occurrences,
      firstSeen: s.firstSeen,
      lastSeen: s.lastSeen,
      sampleEvidence: s.context,
    });
  }

  patterns.sort((a, b) => b.occurrences - a.occurrences);
  antiPatterns.sort((a, b) => b.occurrences - a.occurrences);

  const outputFiles: string[] = [];
  if (opts.writeFiles !== false) {
    const knowledgeDir = path.join(opts.vaultPath, 'knowledge');
    if (!fs.existsSync(knowledgeDir)) fs.mkdirSync(knowledgeDir, { recursive: true });

    const patternsPath = path.join(knowledgeDir, 'patterns.md');
    fs.writeFileSync(patternsPath, formatPatterns('Recurring Patterns', patterns, sinceDays), 'utf8');
    outputFiles.push(patternsPath);

    const antiPath = path.join(knowledgeDir, 'anti-patterns.md');
    fs.writeFileSync(antiPath, formatPatterns('Anti-Patterns & Stuck Loops', antiPatterns, sinceDays), 'utf8');
    outputFiles.push(antiPath);
  }

  return {
    scannedAt: new Date().toISOString(),
    decisionCount: allDecisions.length,
    patterns,
    antiPatterns,
    outputFiles,
  };
}

function formatPatterns(title: string, items: HarvestPattern[], sinceDays: number): string {
  const lines: string[] = [];
  lines.push('---');
  lines.push('type: knowledge');
  lines.push(`description: ${title} mined from the last ${sinceDays} days of decisions`);
  lines.push(`generated_at: ${new Date().toISOString()}`);
  lines.push('source: gsd knowledge-harvest job');
  lines.push('---');
  lines.push('');
  lines.push(`# ${title}`);
  lines.push('');
  lines.push(`Harvested from decisions + stuck_patterns over the last ${sinceDays} days.`);
  lines.push('');
  if (items.length === 0) {
    lines.push('_No patterns detected this window._');
    return lines.join('\n');
  }
  lines.push('| Signature | Category | Occurrences | First Seen | Last Seen | Sample |');
  lines.push('|-----------|----------|:----------:|------------|-----------|--------|');
  for (const p of items.slice(0, 50)) {
    const sig = p.signature.length > 48 ? `\`${p.signature.slice(0, 45)}…\`` : `\`${p.signature}\``;
    lines.push(`| ${sig} | ${p.category} | ${p.occurrences} | ${p.firstSeen.slice(0, 10)} | ${p.lastSeen.slice(0, 10)} | ${p.sampleEvidence.slice(0, 80).replace(/\|/g, '\\|')} |`);
  }
  return lines.join('\n');
}
