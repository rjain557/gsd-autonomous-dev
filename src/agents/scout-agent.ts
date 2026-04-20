// ═══════════════════════════════════════════════════════════
// GSD V6 — Scout Agent (subagent)
// Reads specs and vault notes, returns summarized context.
// Used by Blueprint, Review, Remediation agents to avoid
// loading the full vault into their main context.
// ═══════════════════════════════════════════════════════════

import { BaseAgent } from '../harness/base-agent';
import type { AgentInput, AgentOutput } from '../harness/types';
import * as fs from 'fs';
import * as path from 'path';

export interface ScoutInput extends AgentInput {
  vaultPath: string;
  topics: string[];           // e.g. ["agents/code-review-agent", "knowledge/quality-gates"]
  maxBytesPerTopic?: number;  // default 1500
  maxTotalBytes?: number;     // default 8000
}

export interface ScoutFinding {
  topic: string;
  path: string;
  found: boolean;
  summary: string;
  bytesRead: number;
}

export interface ScoutOutput extends AgentOutput {
  findings: ScoutFinding[];
  totalBytes: number;
  topics: string[];
}

export class ScoutAgent extends BaseAgent {
  protected async run(input: AgentInput): Promise<AgentOutput> {
    const { vaultPath, topics, maxBytesPerTopic = 1500, maxTotalBytes = 8000 } = input as ScoutInput;

    const findings: ScoutFinding[] = [];
    let totalBytes = 0;

    for (const topic of topics) {
      if (totalBytes >= maxTotalBytes) {
        findings.push({ topic, path: '', found: false, summary: '[budget exhausted]', bytesRead: 0 });
        continue;
      }
      const relPath = topic.endsWith('.md') ? topic : `${topic}.md`;
      const fullPath = path.join(vaultPath, relPath);
      if (!fs.existsSync(fullPath)) {
        findings.push({ topic, path: fullPath, found: false, summary: '[not found]', bytesRead: 0 });
        continue;
      }

      const content = fs.readFileSync(fullPath, 'utf8');
      const summary = this.summarize(content, maxBytesPerTopic);
      findings.push({ topic, path: fullPath, found: true, summary, bytesRead: summary.length });
      totalBytes += summary.length;
    }

    const result: ScoutOutput = {
      findings,
      totalBytes,
      topics,
    };
    return result;
  }

  private summarize(content: string, maxBytes: number): string {
    if (content.length <= maxBytes) return content;
    // Prefer: frontmatter + first heading's body + table of contents
    const lines = content.split('\n');
    const out: string[] = [];
    let bytes = 0;
    let inFrontmatter = false;
    let frontmatterClosed = false;
    for (const line of lines) {
      if (line.startsWith('---') && !frontmatterClosed) {
        inFrontmatter = !inFrontmatter;
        if (!inFrontmatter) frontmatterClosed = true;
        out.push(line);
        bytes += line.length + 1;
        continue;
      }
      // Headings and bullet points always
      if (line.startsWith('#') || line.startsWith('- ') || line.startsWith('* ')) {
        out.push(line);
        bytes += line.length + 1;
      } else if (bytes < maxBytes * 0.8 && line.trim().length > 0) {
        out.push(line);
        bytes += line.length + 1;
      }
      if (bytes >= maxBytes) {
        out.push('… [truncated by Scout]');
        break;
      }
    }
    return out.join('\n');
  }
}
