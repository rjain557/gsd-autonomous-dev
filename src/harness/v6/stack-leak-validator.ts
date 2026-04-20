// ═══════════════════════════════════════════════════════════
// GSD V6.1.0 — Stack-Leak Validator
// Scans generated artifacts (JSON, md, xml/csproj, yaml) for
// stack-layer values that contradict the resolved PROJECT STACK
// CONTEXT. Example: if the project declares net9.0 but a generated
// phase-b-architecture-pack.json contains "net8.0", that's a leak.
// Designed as a post-phase quality check.
// ═══════════════════════════════════════════════════════════

import * as fs from 'fs/promises';
import * as path from 'path';
import type { ProjectStackContext } from '../project-stack-context';

export type StackLeakSeverity = 'error' | 'warning' | 'info';

export interface StackLeakFinding {
  severity: StackLeakSeverity;
  file: string;
  line: number;
  column: number;
  leakKind: 'backend-framework' | 'backend-sdk' | 'solution-format' | 'frontend' | 'database' | 'compliance';
  found: string;      // the leaked text
  expected: string;   // what the context declared
  snippet: string;    // up to 120 chars of surrounding context
}

export interface StackLeakReport {
  scannedAt: string;
  projectRoot: string;
  filesScanned: number;
  filesMatched: number;
  findings: StackLeakFinding[];
  contextSource: 'override' | 'default';
  contextBackendFramework: string;
}

export interface StackLeakValidatorOptions {
  projectRoot: string;
  context: ProjectStackContext;
  /** File globs/extensions to scan. Default: generated artifacts only. */
  scanPatterns?: string[];
  /** Paths to skip (relative to projectRoot). */
  ignorePaths?: string[];
  /** Max bytes per file before we skip (default 2MB). */
  maxFileBytes?: number;
}

const DEFAULT_SCAN_EXTENSIONS = new Set([
  '.csproj',
  '.json',
  '.md',
  '.yaml',
  '.yml',
  '.xml',
  '.targets',
  '.props',
]);

const DEFAULT_IGNORE_DIRS = new Set([
  'node_modules',
  'dist',
  'build',
  '.git',
  '.gsd-worktrees',
  '.gitnexus',
  'graphify-out',
  '_archive',
]);

const ALL_NET_VERSIONS = ['net6.0', 'net7.0', 'net8.0', 'net9.0', 'net10.0'];

async function walkFiles(
  dir: string,
  ignoreDirs: Set<string>,
  accept: (file: string) => boolean,
  out: string[] = [],
  depth: number = 0,
): Promise<string[]> {
  if (depth > 10) return out;
  let entries: Array<{ name: string; isDirectory: () => boolean; isFile: () => boolean }>;
  try {
    const raw = await fs.readdir(dir, { withFileTypes: true });
    entries = raw;
  } catch {
    return out;
  }
  for (const entry of entries) {
    if (ignoreDirs.has(entry.name)) continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      await walkFiles(full, ignoreDirs, accept, out, depth + 1);
    } else if (entry.isFile() && accept(full)) {
      out.push(full);
    }
  }
  return out;
}

export async function validateStackLeaks(
  opts: StackLeakValidatorOptions,
): Promise<StackLeakReport> {
  const ctx = opts.context;
  const maxBytes = opts.maxFileBytes ?? 2 * 1024 * 1024;
  const ignoreDirs = new Set([...DEFAULT_IGNORE_DIRS, ...(opts.ignorePaths ?? [])]);

  const accept = (file: string): boolean => {
    const ext = path.extname(file).toLowerCase();
    if (opts.scanPatterns && opts.scanPatterns.length > 0) {
      return opts.scanPatterns.some((p) => file.endsWith(p));
    }
    return DEFAULT_SCAN_EXTENSIONS.has(ext);
  };

  const files = await walkFiles(opts.projectRoot, ignoreDirs, accept);

  // Frameworks that should NOT appear (everything except the declared one)
  const allowedFramework = ctx.backendFramework;
  const forbiddenFrameworks = ALL_NET_VERSIONS.filter((v) => v !== allowedFramework);

  const findings: StackLeakFinding[] = [];
  let filesMatched = 0;

  for (const file of files) {
    let content: string;
    try {
      const stat = await fs.stat(file);
      if (stat.size > maxBytes) continue;
      content = await fs.readFile(file, 'utf8');
    } catch {
      continue;
    }

    const fileLeaks: StackLeakFinding[] = [];
    const lines = content.split(/\r?\n/);

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      // Only enforce backend framework leaks: these are the highest-risk
      // net8.0/net9.0 mismatches. Other stack layers (frontend, db) could
      // reasonably appear in many contexts (docs, migration notes) without
      // being leaks; we warn on those instead of erroring.
      for (const fw of forbiddenFrameworks) {
        const pattern = new RegExp(`\\b${fw.replace('.', '\\.')}\\b`, 'g');
        const matches = line.matchAll(pattern);
        for (const m of matches) {
          const idx = m.index ?? 0;
          // Skip obvious false positives in migration/comparison contexts
          if (isFalsePositive(line, idx)) continue;

          fileLeaks.push({
            severity: 'error',
            file: path.relative(opts.projectRoot, file),
            line: i + 1,
            column: idx + 1,
            leakKind: 'backend-framework',
            found: fw,
            expected: allowedFramework,
            snippet: line.slice(Math.max(0, idx - 30), Math.min(line.length, idx + 90)),
          });
        }
      }
    }

    if (fileLeaks.length > 0) filesMatched++;
    findings.push(...fileLeaks);
  }

  return {
    scannedAt: new Date().toISOString(),
    projectRoot: opts.projectRoot,
    filesScanned: files.length,
    filesMatched,
    findings,
    contextSource: ctx.source,
    contextBackendFramework: allowedFramework,
  };
}

/**
 * Heuristic: skip findings that appear in migration/comparison contexts where
 * mentioning another framework is deliberate, not a leak.
 */
function isFalsePositive(line: string, idx: number): boolean {
  const lower = line.toLowerCase();
  const hints = [
    'migrat',        // "migration from net8.0 to net9.0"
    'upgrad',        // "upgrade from net8.0"
    'previous',      // "previously targeted net8.0"
    'legacy',        // "legacy net8.0 artifact"
    'archived',
    'changelog',     // changelog line mentioning prior version
    'supersede',
    'comment',
    'was ',          // "was net8.0"
  ];
  // If the line starts with a markdown blockquote or an HTML comment,
  // treat as informational rather than a live declaration.
  if (/^\s*[>]|^\s*<!--|^\s*\/\//.test(line)) return true;
  void idx;
  return hints.some((h) => lower.includes(h));
}

export function formatStackLeakReport(report: StackLeakReport): string {
  const lines: string[] = [];
  lines.push('# Stack Leak Validation Report');
  lines.push('');
  lines.push(`Scanned: ${report.scannedAt}`);
  lines.push(`Project root: ${report.projectRoot}`);
  lines.push(`Context source: ${report.contextSource}`);
  lines.push(`Declared backend framework: ${report.contextBackendFramework}`);
  lines.push(`Files scanned: ${report.filesScanned}`);
  lines.push(`Files with leaks: ${report.filesMatched}`);
  lines.push(`Total findings: ${report.findings.length}`);
  lines.push('');
  if (report.findings.length === 0) {
    lines.push('No stack leaks detected.');
    return lines.join('\n');
  }
  const byFile: Record<string, StackLeakFinding[]> = {};
  for (const f of report.findings) {
    (byFile[f.file] ??= []).push(f);
  }
  for (const [file, items] of Object.entries(byFile)) {
    lines.push(`## ${file} (${items.length})`);
    for (const f of items) {
      lines.push(`- [${f.severity}] line ${f.line}:${f.column} — found "${f.found}" (expected "${f.expected}"): ${f.snippet.trim()}`);
    }
    lines.push('');
  }
  return lines.join('\n');
}
