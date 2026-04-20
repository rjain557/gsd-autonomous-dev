// ═══════════════════════════════════════════════════════════
// GSD V6 — Doc Gardener (recurring job)
// Scans vault agent notes and knowledge notes for drift:
//   - Agent vault note declares tools that no longer exist in code
//   - Knowledge note references files that have been moved or deleted
//   - External tools declared but not installed
// Produces a DocGardenReport — caller decides whether to auto-PR.
// ═══════════════════════════════════════════════════════════

import * as fs from 'fs';
import * as path from 'path';
import { execFile } from 'child_process';
import { promisify } from 'util';

const execFileAsync = promisify(execFile);

export interface DocDriftFinding {
  severity: 'info' | 'warning' | 'error';
  notePath: string;
  kind: 'stale-reads' | 'stale-writes' | 'missing-tool' | 'missing-related-code' | 'stale-aliases';
  message: string;
  evidence: string;
}

export interface DocGardenReport {
  scannedAt: string;
  vaultPath: string;
  notesScanned: number;
  findings: DocDriftFinding[];
}

export interface DocGardenerOptions {
  vaultPath: string;
  repoRoot?: string;
  checkToolAvailability?: boolean;  // default true
}

async function toolInstalled(tool: string): Promise<boolean> {
  try {
    // shell: true on Windows so .cmd/.bat shims (claude, codex, gemini, pnpm, gitnexus, graphify, etc.) resolve.
    await execFileAsync(tool, ['--version'], { timeout: 8000, shell: process.platform === 'win32' });
    return true;
  } catch {
    return false;
  }
}

function readFrontmatter(raw: string): Record<string, unknown> | null {
  const match = raw.match(/^---\n([\s\S]*?)\n---/);
  if (!match) return null;
  const fm: Record<string, unknown> = {};
  for (const line of match[1].split('\n')) {
    const kv = line.match(/^([a-zA-Z_]+):\s*(.+)$/);
    if (kv) fm[kv[1]] = kv[2].trim();
  }
  return fm;
}

function listAgentNotes(vaultPath: string): string[] {
  const dir = path.join(vaultPath, 'agents');
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir).filter((f) => f.endsWith('.md')).map((f) => path.join(dir, f));
}

function listKnowledgeNotes(vaultPath: string): string[] {
  const dir = path.join(vaultPath, 'knowledge');
  if (!fs.existsSync(dir)) return [];
  const out: string[] = [];
  const walk = (d: string): void => {
    for (const entry of fs.readdirSync(d)) {
      const full = path.join(d, entry);
      const stat = fs.statSync(full);
      if (stat.isDirectory()) walk(full);
      else if (entry.endsWith('.md')) out.push(full);
    }
  };
  walk(dir);
  return out;
}

export async function runDocGardener(opts: DocGardenerOptions): Promise<DocGardenReport> {
  const repoRoot = opts.repoRoot ?? process.cwd();
  const findings: DocDriftFinding[] = [];
  let scanned = 0;

  // Scan agent notes
  const knownTools = new Set(['claude', 'codex', 'gemini', 'semgrep', 'npm', 'dotnet', 'git', 'gitnexus', 'graphify', 'playwright', 'node']);
  for (const notePath of listAgentNotes(opts.vaultPath)) {
    scanned++;
    const raw = fs.readFileSync(notePath, 'utf8');
    const fm = readFrontmatter(raw);
    if (!fm) continue;

    // Check declared `reads` paths
    const reads = fm.reads as unknown;
    if (Array.isArray(reads)) {
      for (const p of reads as string[]) {
        const asPath = p.replace(/^\//, '').replace(/[[\]]/g, '');
        const candidate = path.join(repoRoot, asPath);
        if (!fs.existsSync(candidate)) {
          findings.push({
            severity: 'warning',
            notePath,
            kind: 'stale-reads',
            message: `Declared reads path does not exist: ${p}`,
            evidence: candidate,
          });
        }
      }
    }

    // Check that external tools declared are installed (opt-in)
    if (opts.checkToolAvailability !== false) {
      const tools = fm.tools as unknown;
      if (Array.isArray(tools)) {
        for (const t of tools as string[]) {
          const cleaned = t.replace(/[[\]]/g, '').trim();
          if (knownTools.has(cleaned)) {
            const installed = await toolInstalled(cleaned);
            if (!installed) {
              findings.push({
                severity: 'info',
                notePath,
                kind: 'missing-tool',
                message: `Declared tool not found on PATH: ${cleaned}`,
                evidence: 'tool(--version) failed',
              });
            }
          }
        }
      }
    }
  }

  // Scan knowledge notes for wiki-links to missing files
  for (const notePath of listKnowledgeNotes(opts.vaultPath)) {
    scanned++;
    const raw = fs.readFileSync(notePath, 'utf8');
    const links = raw.matchAll(/\[\[([^\]|]+)(?:\|[^\]]+)?\]\]/g);
    for (const m of links) {
      const target = m[1].trim();
      const rel = target.endsWith('.md') ? target : `${target}.md`;
      const candidate = path.join(opts.vaultPath, rel);
      if (!fs.existsSync(candidate)) {
        findings.push({
          severity: 'warning',
          notePath,
          kind: 'missing-related-code',
          message: `Wiki-link target missing: ${target}`,
          evidence: candidate,
        });
      }
    }
  }

  return {
    scannedAt: new Date().toISOString(),
    vaultPath: opts.vaultPath,
    notesScanned: scanned,
    findings,
  };
}

export function formatDocGardenReport(report: DocGardenReport): string {
  const lines: string[] = [];
  lines.push(`# Doc Garden Report`);
  lines.push(`Scanned: ${report.scannedAt}`);
  lines.push(`Vault: ${report.vaultPath}`);
  lines.push(`Notes scanned: ${report.notesScanned}`);
  lines.push(`Findings: ${report.findings.length}`);
  lines.push('');
  if (report.findings.length === 0) {
    lines.push('No drift detected.');
  } else {
    const byKind: Record<string, DocDriftFinding[]> = {};
    for (const f of report.findings) {
      (byKind[f.kind] ??= []).push(f);
    }
    for (const [kind, list] of Object.entries(byKind)) {
      lines.push(`## ${kind} (${list.length})`);
      for (const f of list) {
        lines.push(`- [${f.severity}] \`${path.relative(report.vaultPath, f.notePath)}\` — ${f.message}`);
      }
      lines.push('');
    }
  }
  return lines.join('\n');
}
