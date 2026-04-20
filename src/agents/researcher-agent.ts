// ═══════════════════════════════════════════════════════════
// GSD V6 — Researcher Agent (subagent)
// Runs Context7 / GitNexus / Graphify queries against the
// installed MCP servers and tool CLIs. Returns synthesized
// findings. Used by Remediation and E2E agents.
// ═══════════════════════════════════════════════════════════

import { BaseAgent } from '../harness/base-agent';
import type { AgentInput, AgentOutput } from '../harness/types';
import { execFile } from 'child_process';
import { promisify } from 'util';

const execFileAsync = promisify(execFile);

export type ResearchSource = 'gitnexus' | 'graphify' | 'context7' | 'semgrep';

export interface ResearcherInput extends AgentInput {
  cwd: string;
  query: string;
  sources: ResearchSource[];
  timeoutMs?: number;
}

export interface ResearchFinding {
  source: ResearchSource;
  success: boolean;
  content: string;
  error?: string;
}

export interface ResearcherOutput extends AgentOutput {
  query: string;
  findings: ResearchFinding[];
  synthesizedSummary: string;
}

export class ResearcherAgent extends BaseAgent {
  protected async run(input: AgentInput): Promise<AgentOutput> {
    const { cwd, query, sources, timeoutMs = 60_000 } = input as ResearcherInput;

    const findings: ResearchFinding[] = [];

    for (const source of sources) {
      const finding = await this.queryOneSource(source, query, cwd, timeoutMs);
      findings.push(finding);
    }

    const synthesizedSummary = this.synthesize(query, findings);

    const result: ResearcherOutput = {
      query,
      findings,
      synthesizedSummary,
    };
    return result;
  }

  private async queryOneSource(
    source: ResearchSource,
    query: string,
    cwd: string,
    timeoutMs: number,
  ): Promise<ResearchFinding> {
    try {
      switch (source) {
        case 'gitnexus': {
          // gitnexus query CLI: npx gitnexus query "<concept>"
          const { stdout } = await execFileAsync('npx', ['gitnexus', 'query', query], {
            cwd,
            timeout: timeoutMs,
            maxBuffer: 10 * 1024 * 1024,
          });
          return { source, success: true, content: stdout.slice(0, 4000) };
        }
        case 'graphify': {
          // graphify query CLI: npx graphify query "<concept>" (if installed)
          const { stdout } = await execFileAsync('npx', ['graphify', 'query', query], {
            cwd,
            timeout: timeoutMs,
            maxBuffer: 10 * 1024 * 1024,
          });
          return { source, success: true, content: stdout.slice(0, 4000) };
        }
        case 'semgrep': {
          // semgrep --lang=sql -e <pattern> . is a rough shortcut; real usage
          // would call out to custom rules. This is a simplified surface.
          const { stdout } = await execFileAsync('semgrep', ['--lang=generic', '-e', query, '.'], {
            cwd,
            timeout: timeoutMs,
            maxBuffer: 10 * 1024 * 1024,
          });
          return { source, success: true, content: stdout.slice(0, 4000) };
        }
        case 'context7': {
          // Context7 is an MCP server; the CLI route from Node is not standardized.
          // Return a placeholder so callers know to use the MCP directly.
          return {
            source,
            success: false,
            content: '',
            error: 'Context7 is MCP-only; invoke via Claude Code MCP tools, not this agent.',
          };
        }
      }
    } catch (e) {
      const err = e as { stdout?: string; stderr?: string; message?: string };
      return {
        source,
        success: false,
        content: (err.stdout ?? '').slice(0, 2000),
        error: (err.stderr ?? err.message ?? 'unknown').slice(0, 500),
      };
    }
  }

  private synthesize(query: string, findings: ResearchFinding[]): string {
    const lines = [`Query: ${query}`, ''];
    for (const f of findings) {
      lines.push(`=== ${f.source} ===`);
      if (f.success) {
        lines.push(f.content.slice(0, 1500));
      } else {
        lines.push(`[error: ${f.error ?? 'unknown'}]`);
      }
      lines.push('');
    }
    return lines.join('\n');
  }
}
