// ═══════════════════════════════════════════════════════════
// GSD Agent System — VaultAdapter
// Reads/writes Obsidian vault notes with frontmatter parsing,
// wikilink resolution, and file locking for safe concurrent writes.
// ═══════════════════════════════════════════════════════════

import * as fs from 'fs/promises';
import * as path from 'path';
import * as lockfile from 'proper-lockfile';
import type { VaultNote, VaultNoteMeta, AgentInput, AgentOutput, Decision } from './types';

export class VaultAdapter {
  private vaultRoot: string;
  private lockMap = new Map<string, Promise<void>>();

  constructor(vaultRoot: string) {
    this.vaultRoot = path.resolve(vaultRoot);
  }

  // ── Read note, parse frontmatter, return { meta, body } ───

  async read(notePath: string): Promise<VaultNote> {
    const absPath = this.resolve(notePath);
    const raw = await fs.readFile(absPath, 'utf-8');
    const { meta, body } = this.parseFrontmatter(raw);
    return { meta, body, path: notePath };
  }

  // ── Follow [[wikilinks]] recursively, return merged context ─

  async readWithLinks(notePath: string, depth: number = 1): Promise<string> {
    const visited = new Set<string>();
    return this._readWithLinksRecursive(notePath, depth, visited);
  }

  private async _readWithLinksRecursive(
    notePath: string,
    depth: number,
    visited: Set<string>,
  ): Promise<string> {
    const normalized = this.normalizePath(notePath);
    if (visited.has(normalized)) {
      return `<!-- circular reference: ${notePath} -->\n`;
    }
    visited.add(normalized);

    let note: VaultNote;
    try {
      note = await this.read(notePath);
    } catch {
      return `<!-- not found: ${notePath} -->\n`;
    }

    if (depth <= 0) {
      return `## ${notePath}\n\n${note.body}\n`;
    }

    const links = this.extractWikilinks(note.body);
    let result = `## ${notePath}\n\n${note.body}\n`;

    for (const link of links) {
      const resolved = this.resolveLink(link, notePath);
      const linkedContent = await this._readWithLinksRecursive(resolved, depth - 1, visited);
      result += `\n${linkedContent}`;
    }

    return result;
  }

  // ── Append timestamped entry — NEVER overwrites ───────────

  async append(notePath: string, entry: string): Promise<void> {
    const absPath = this.resolve(notePath);
    await this.ensureDir(path.dirname(absPath));

    const timestamp = new Date().toISOString();
    const timestamped = `\n---\n_${timestamp}_\n\n${entry}\n`;

    await this.withLock(notePath, async () => {
      try {
        await fs.access(absPath);
        await fs.appendFile(absPath, timestamped, 'utf-8');
      } catch {
        // File doesn't exist — create with the entry
        await fs.writeFile(absPath, timestamped, 'utf-8');
      }
    });

    this.debugLog(`VAULT APPEND: ${notePath}`);
  }

  // ── Create new note with frontmatter template ─────────────

  async create(notePath: string, frontmatter: Record<string, unknown>, body: string): Promise<void> {
    const absPath = this.resolve(notePath);
    await this.ensureDir(path.dirname(absPath));

    const yamlLines = Object.entries(frontmatter).map(([key, val]) => {
      if (Array.isArray(val)) {
        return `${key}: [${val.map(v => JSON.stringify(v)).join(', ')}]`;
      }
      return `${key}: ${typeof val === 'string' ? val : JSON.stringify(val)}`;
    });

    const content = `---\n${yamlLines.join('\n')}\n---\n\n${body}\n`;

    await this.withLock(notePath, async () => {
      await fs.writeFile(absPath, content, 'utf-8');
    });

    this.debugLog(`VAULT CREATE: ${notePath}`);
  }

  // ── Search notes by frontmatter field value ───────────────

  async findByMeta(field: string, value: string): Promise<VaultNote[]> {
    const results: VaultNote[] = [];
    const allFiles = await this.walkMd(this.vaultRoot);

    for (const filePath of allFiles) {
      try {
        const relative = path.relative(this.vaultRoot, filePath).replace(/\\/g, '/');
        const note = await this.read(relative);
        if (note.meta[field] !== undefined && String(note.meta[field]) === value) {
          results.push(note);
        }
      } catch {
        // Skip unreadable files
      }
    }

    return results;
  }

  // ── Resolve [[wikilink]] to relative vault path ───────────

  resolveLink(link: string, fromNote: string): string {
    // Remove [[ and ]] if present
    const cleaned = link.replace(/^\[\[/, '').replace(/\]\]$/, '');

    // If the link already has a path separator, treat as relative to vault root
    if (cleaned.includes('/')) {
      return cleaned.endsWith('.md') ? cleaned : `${cleaned}.md`;
    }

    // Otherwise, search for a matching file name in the vault
    const fromDir = path.dirname(fromNote);
    const candidate = path.join(fromDir, cleaned.endsWith('.md') ? cleaned : `${cleaned}.md`);
    return candidate.replace(/\\/g, '/');
  }

  // ── Build merged context string from multiple notes ───────

  async buildContext(notePaths: string[]): Promise<string> {
    const sections: string[] = [];

    for (const notePath of notePaths) {
      try {
        const note = await this.read(notePath);
        sections.push(`## ${notePath}\n\n${note.body}`);
      } catch {
        sections.push(`<!-- not found: ${notePath} -->`);
      }
    }

    return sections.join('\n\n---\n\n');
  }

  // ── Write session log entry for a completed agent run ─────

  async logRun(
    runId: string,
    agentId: string,
    input: AgentInput,
    output: AgentOutput,
    durationMs: number,
  ): Promise<void> {
    const date = new Date().toISOString().split('T')[0];
    const logPath = `sessions/${date}-run-${runId}.md`;

    const entry = [
      `### ${agentId} — ${new Date().toISOString()}`,
      '',
      `| Field | Value |`,
      `|---|---|`,
      `| Duration | ${durationMs}ms |`,
      `| Input keys | ${Object.keys(input).join(', ')} |`,
      `| Output keys | ${Object.keys(output).join(', ')} |`,
      '',
      '**Input summary:**',
      '```json',
      JSON.stringify(input, null, 2).substring(0, 1000),
      '```',
      '',
      '**Output summary:**',
      '```json',
      JSON.stringify(output, null, 2).substring(0, 1000),
      '```',
    ].join('\n');

    await this.append(logPath, entry);
  }

  // ── Write a decision entry (orchestrator use only) ────────

  async logDecision(runId: string, decision: Decision): Promise<void> {
    const date = new Date().toISOString().split('T')[0];
    const logPath = `decisions/${date}-run-${runId}.md`;

    const entry = [
      `### ${decision.stage} — ${decision.action}`,
      '',
      `| Field | Value |`,
      `|---|---|`,
      `| Agent | ${decision.agentId} |`,
      `| Stage | ${decision.stage} |`,
      `| Action | ${decision.action} |`,
      `| Reason | ${decision.reason} |`,
      '',
      decision.evidence ? `**Evidence:** ${decision.evidence}` : '',
    ].join('\n');

    await this.append(logPath, entry);
  }

  // ── Internal Helpers ──────────────────────────────────────

  private resolve(notePath: string): string {
    return path.resolve(this.vaultRoot, notePath);
  }

  private normalizePath(notePath: string): string {
    return notePath.replace(/\\/g, '/').toLowerCase();
  }

  private parseFrontmatter(raw: string): { meta: VaultNoteMeta; body: string } {
    const fmMatch = raw.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n([\s\S]*)$/);
    if (!fmMatch) {
      return { meta: {}, body: raw };
    }

    const meta: VaultNoteMeta = {};
    const fmLines = fmMatch[1].split(/\r?\n/);

    for (const line of fmLines) {
      const colonIdx = line.indexOf(':');
      if (colonIdx === -1) continue;

      const key = line.substring(0, colonIdx).trim();
      let value: unknown = line.substring(colonIdx + 1).trim();

      // Parse arrays: [item1, item2]
      if (typeof value === 'string' && value.startsWith('[') && value.endsWith(']')) {
        try {
          value = JSON.parse(value);
        } catch {
          // Leave as string if not valid JSON array
        }
      }
      // Parse booleans
      else if (value === 'true') value = true;
      else if (value === 'false') value = false;
      // Parse numbers
      else if (typeof value === 'string' && /^\d+$/.test(value)) {
        value = parseInt(value, 10);
      }

      meta[key] = value;
    }

    return { meta, body: fmMatch[2].trim() };
  }

  private extractWikilinks(text: string): string[] {
    const matches = text.match(/\[\[([^\]]+)\]\]/g) || [];
    return matches.map(m => m.slice(2, -2));
  }

  private async ensureDir(dirPath: string): Promise<void> {
    await fs.mkdir(dirPath, { recursive: true });
  }

  private async withLock(notePath: string, fn: () => Promise<void>): Promise<void> {
    const absPath = this.resolve(notePath);
    const dir = path.dirname(absPath);
    await this.ensureDir(dir);

    // Use OS-level file lock on the directory to prevent cross-process corruption.
    // Falls back to in-memory sequencing if lockfile fails (e.g., network drives).
    let release: (() => Promise<void>) | null = null;
    try {
      release = await lockfile.lock(dir, {
        stale: 10_000,
        retries: { retries: 3, minTimeout: 100, maxTimeout: 1000 },
      });
    } catch {
      // Fallback: in-memory sequencing for this process only
      this.debugLog(`OS lock failed for ${notePath}, falling back to in-memory lock`);
    }

    try {
      await fn();
    } finally {
      if (release) {
        try { await release(); } catch { /* lock already released */ }
      }
    }
  }

  private async walkMd(dir: string): Promise<string[]> {
    const results: string[] = [];
    const entries = await fs.readdir(dir, { withFileTypes: true });

    for (const entry of entries) {
      const fullPath = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        const sub = await this.walkMd(fullPath);
        results.push(...sub);
      } else if (entry.name.endsWith('.md')) {
        results.push(fullPath);
      }
    }

    return results;
  }

  private debugLog(message: string): void {
    if (process.env.GSD_DEBUG === 'true') {
      console.log(`[VAULT] ${message}`);
    }
  }
}
