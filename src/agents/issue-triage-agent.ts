// ═══════════════════════════════════════════════════════════
// GSD V6.3 — Issue Triage Agent (Phase U1, maintenance flow)
// Reviews a client-reported issue, attempts reproduction,
// localizes the fault hierarchically (file → symbol → line),
// and emits a TriageResult for the UpdateSpecAgent.
// Localization candidates are gathered deterministically by
// the harness (keyword/path ranking — the Agentless pattern);
// the LLM narrows and grounds them. Vault contract:
// memory/agents/issue-triage-agent.md
// ═══════════════════════════════════════════════════════════

import { BaseAgent } from '../harness/base-agent';
import type { AgentInput, AgentOutput, TriageInput, TriageResult } from '../harness/types';
import * as fs from 'fs';
import * as path from 'path';

const SOURCE_EXTENSIONS = new Set(['.ts', '.tsx', '.js', '.jsx', '.cs', '.sql', '.json', '.md']);
const SKIP_DIRS = new Set(['node_modules', '.git', 'dist', 'build', 'bin', 'obj', '.gsd', '.gitnexus', 'graphify-out']);
const MAX_CANDIDATES = 12;
const EXCERPT_BYTES = 2200;

const TRIAGE_SCHEMA: Record<string, unknown> = {
  type: 'object',
  properties: {
    isValid: { type: 'boolean' },
    category: { type: 'string', enum: ['bug', 'feature', 'change-request', 'question'] },
    severity: { type: 'string', enum: ['low', 'medium', 'high', 'critical'] },
    reproStatus: { type: 'string', enum: ['confirmed', 'not-reproducible', 'needs-info'] },
    reproArtifact: { type: 'string' },
    clarifyingQuestions: { type: 'array', items: { type: 'string' } },
    suspects: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          file: { type: 'string' },
          symbol: { type: 'string' },
          lines: { type: 'string' },
          confidence: { type: 'number' },
          rationale: { type: 'string' },
        },
        required: ['file', 'symbol', 'lines', 'confidence', 'rationale'],
      },
    },
    affectedComponents: { type: 'array', items: { type: 'string' } },
    affectedSpecs: { type: 'array', items: { type: 'string' } },
    riskLevel: { type: 'string', enum: ['low', 'medium', 'high'] },
    recommendedAction: { type: 'string' },
    scopeAnalysis: { type: 'string' },
  },
  required: [
    'isValid', 'category', 'severity', 'reproStatus', 'reproArtifact', 'clarifyingQuestions',
    'suspects', 'affectedComponents', 'affectedSpecs', 'riskLevel', 'recommendedAction', 'scopeAnalysis',
  ],
};

export class IssueTriageAgent extends BaseAgent {
  protected async run(input: AgentInput): Promise<AgentOutput> {
    const { issueDescription, repoRoot, specPaths } = input as TriageInput;
    let { candidateFiles } = input as TriageInput;

    if (!issueDescription || issueDescription.trim().length === 0) {
      throw new Error('IssueTriageAgent requires a non-empty issueDescription');
    }

    // Harness-side hierarchical localization, pass 1: deterministic candidate
    // ranking (keyword grep + path-name match). The LLM does pass 2 (narrowing).
    if (!candidateFiles || candidateFiles.length === 0) {
      candidateFiles = this.gatherCandidates(repoRoot, issueDescription);
    }

    const systemPrompt = await this.buildSystemPrompt();

    const candidateBlock = candidateFiles
      .map(c => `### ${c.path} (match score ${c.matchScore})\n\`\`\`\n${c.excerpt}\n\`\`\``)
      .join('\n\n');

    const userMessage = [
      `## Client-reported issue\n\n${issueDescription}`,
      `## Frozen specs available\n\n${(specPaths ?? []).join('\n') || '(none found)'}`,
      `## Candidate files (pre-ranked by the harness — narrow these to suspects)\n\n${candidateBlock || '(no keyword matches — localization confidence will be low)'}`,
      `Follow your triage rules: classify, reproduce (bugs), localize hierarchically with grounded rationales, estimate blast radius. Return ONLY JSON.`,
    ].join('\n\n');

    const response = await this.callLLM(systemPrompt, userMessage, TRIAGE_SCHEMA);
    const result = this.extractJSON<TriageResult>(response);

    // Enforce the triage-rules invariants regardless of model output:
    // bugs are only actionable with a confirmed reproduction.
    if (result.category === 'bug' && result.reproStatus !== 'confirmed') {
      result.isValid = false;
    }
    // Suspects below the confidence floor are excluded (triage-rules.md).
    result.suspects = (result.suspects ?? []).filter(s => s.confidence >= 0.4);
    if (result.category === 'bug' && result.suspects.length === 0) {
      result.isValid = false;
      result.recommendedAction = result.recommendedAction
        || 'No grounded suspects — run an interactive GitNexus localization session.';
    }

    return result;
  }

  /**
   * Pass-1 localization: rank repo files by issue-keyword hits in path + content.
   * Deterministic and cheap (the Agentless pattern) — no LLM, no embeddings.
   */
  private gatherCandidates(
    repoRoot: string,
    issue: string,
  ): Array<{ path: string; excerpt: string; matchScore: number }> {
    const keywords = this.extractKeywords(issue);
    if (keywords.length === 0) return [];

    const files: string[] = [];
    const walk = (dir: string, depth: number): void => {
      if (depth > 6 || files.length > 4000) return;
      let entries: fs.Dirent[];
      try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
      for (const e of entries) {
        if (e.isDirectory()) {
          if (!SKIP_DIRS.has(e.name) && !e.name.startsWith('.')) walk(path.join(dir, e.name), depth + 1);
        } else if (SOURCE_EXTENSIONS.has(path.extname(e.name))) {
          files.push(path.join(dir, e.name));
        }
      }
    };
    walk(repoRoot, 0);

    const scored: Array<{ path: string; excerpt: string; matchScore: number }> = [];
    for (const file of files) {
      const rel = path.relative(repoRoot, file);
      let score = 0;
      const relLower = rel.toLowerCase();
      for (const kw of keywords) if (relLower.includes(kw)) score += 3; // path hits weigh more

      let content = '';
      try {
        const stat = fs.statSync(file);
        if (stat.size > 512 * 1024) continue; // skip huge files
        content = fs.readFileSync(file, 'utf8');
      } catch { continue; }
      const contentLower = content.toLowerCase();
      let firstHit = -1;
      for (const kw of keywords) {
        const idx = contentLower.indexOf(kw);
        if (idx >= 0) {
          score += 1;
          if (firstHit < 0 || idx < firstHit) firstHit = idx;
        }
      }
      if (score === 0) continue;

      const start = Math.max(0, (firstHit < 0 ? 0 : firstHit) - 300);
      scored.push({ path: rel, excerpt: content.slice(start, start + EXCERPT_BYTES), matchScore: score });
    }

    return scored.sort((a, b) => b.matchScore - a.matchScore).slice(0, MAX_CANDIDATES);
  }

  /** Keyword extraction: identifiers, quoted strings, and rare words from the issue text. */
  private extractKeywords(issue: string): string[] {
    const stop = new Set([
      'the', 'and', 'for', 'that', 'this', 'with', 'when', 'then', 'from', 'have', 'has',
      'not', 'but', 'are', 'was', 'were', 'will', 'should', 'would', 'page', 'user', 'users',
      'error', 'issue', 'problem', 'does', 'doesnt', 'cant', 'cannot', 'after', 'before',
      'click', 'clicking', 'shows', 'showing', 'getting', 'gets', 'into', 'them', 'they',
    ]);
    const tokens = new Set<string>();
    // quoted strings and code-ish identifiers are the strongest signals
    for (const m of issue.matchAll(/["'`]([^"'`]{3,60})["'`]/g)) tokens.add(m[1].toLowerCase().trim());
    for (const m of issue.matchAll(/\b([A-Z][a-z]+[A-Z]\w+|[a-z]+_[a-z_]+|usp_\w+|\w+Controller|\w+Dto)\b/g)) {
      tokens.add(m[1].toLowerCase());
    }
    for (const m of issue.toLowerCase().matchAll(/\b([a-z][a-z0-9-]{4,})\b/g)) {
      if (!stop.has(m[1])) tokens.add(m[1]);
    }
    return Array.from(tokens).slice(0, 15);
  }
}
