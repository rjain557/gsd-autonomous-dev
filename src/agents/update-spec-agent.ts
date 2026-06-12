// ═══════════════════════════════════════════════════════════
// GSD V6.3 — Update Spec Agent (Phase U2, maintenance flow)
// Turns a confirmed TriageResult into a frozen change spec
// (proposal + delta specs + EARS criteria + tasks + test plan)
// so the unmodified pipeline (F1-G) implements against a spec,
// never against raw issue text. HARD GATE: bugs require a
// confirmed reproduction (mirrors Memory Rule 8).
// Vault contract: memory/agents/update-spec-agent.md
// ═══════════════════════════════════════════════════════════

import { BaseAgent } from '../harness/base-agent';
import type { AgentInput, AgentOutput, SpecUpdateResult, UpdateSpecInput } from '../harness/types';
import * as fs from 'fs';
import * as path from 'path';

const SPEC_EXCERPT_BYTES = 3000;

const SPEC_SCHEMA: Record<string, unknown> = {
  type: 'object',
  properties: {
    proposal: { type: 'string' },
    deltaSpecs: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          target: { type: 'string' },
          change: { type: 'string' },
        },
        required: ['target', 'change'],
      },
    },
    earsCriteria: { type: 'array', items: { type: 'string' } },
    tasks: { type: 'array', items: { type: 'string' } },
    testPlan: { type: 'string' },
    riskLevel: { type: 'string', enum: ['low', 'medium', 'high'] },
    requiresHumanApproval: { type: 'boolean' },
    summary: { type: 'string' },
  },
  required: ['proposal', 'deltaSpecs', 'earsCriteria', 'tasks', 'testPlan', 'riskLevel', 'requiresHumanApproval', 'summary'],
};

export class UpdateSpecAgent extends BaseAgent {
  protected async run(input: AgentInput): Promise<AgentOutput> {
    const { triageResult, repoRoot } = input as UpdateSpecInput;
    let { specExcerpts } = input as UpdateSpecInput;

    if (!triageResult) {
      throw new Error('UpdateSpecAgent requires a triageResult');
    }
    // HARD GATE (mirrors Rule 8) — never spec an unverified bug.
    if (triageResult.category === 'bug' && triageResult.reproStatus !== 'confirmed') {
      throw new Error(
        `HardGateViolation: cannot write a change spec for a bug without a confirmed reproduction ` +
        `(reproStatus=${triageResult.reproStatus}). Resolve triage first.`,
      );
    }
    if (!triageResult.isValid) {
      throw new Error('UpdateSpecAgent received an invalid triage result — orchestrator should have halted.');
    }

    // Load excerpts of the affected frozen specs and suspect files for grounding.
    if (!specExcerpts || specExcerpts.length === 0) {
      specExcerpts = this.loadExcerpts(repoRoot, [
        ...(triageResult.affectedSpecs ?? []),
        ...(triageResult.suspects ?? []).map(s => s.file),
      ]);
    }

    const systemPrompt = await this.buildSystemPrompt();

    const excerptBlock = specExcerpts
      .map(s => `### ${s.path}\n\`\`\`\n${s.excerpt}\n\`\`\``)
      .join('\n\n');

    const userMessage = [
      `## Triage result\n\n${JSON.stringify(triageResult, null, 2)}`,
      `## Affected spec / suspect excerpts\n\n${excerptBlock || '(none loaded — be conservative, raise requiresHumanApproval)'}`,
      `Write the change specification per your guidelines: proposal, delta specs only (never full rewrites), EARS acceptance criteria with the reproduction flip as criterion #1, small ordered tasks, and the test plan. Raise risk to high if any security-critical path is touched. Return ONLY JSON.`,
    ].join('\n\n');

    const response = await this.callLLM(systemPrompt, userMessage, SPEC_SCHEMA);
    const parsed = this.extractJSON<Omit<SpecUpdateResult, 'changeId'>>(response);

    const changeId = `CH-${this.state.runId}`;
    const result: SpecUpdateResult = { changeId, ...parsed } as SpecUpdateResult;

    // Enforce invariants regardless of model output.
    if (result.riskLevel === 'high') result.requiresHumanApproval = true;
    if (triageResult.category === 'bug') {
      const flip = (result.earsCriteria ?? []).some(c => /WHEN/i.test(c) && /SHALL/i.test(c));
      if (!flip || (result.earsCriteria ?? []).length === 0) {
        throw new Error('Change spec missing EARS acceptance criteria (repro flip is mandatory for bugs).');
      }
    }

    // Persist the change spec to the vault (append-only — Memory Rule 10).
    await this.vaultAdapter.create(
      `changes/${changeId}/change-spec.md`,
      { type: 'change-spec', changeId, runId: this.state.runId, createdAt: new Date().toISOString() },
      this.renderChangeSpec(result, triageResult),
    );

    return result;
  }

  private loadExcerpts(repoRoot: string, targets: string[]): Array<{ path: string; excerpt: string }> {
    const out: Array<{ path: string; excerpt: string }> = [];
    const seen = new Set<string>();
    for (const t of targets) {
      if (!t || seen.has(t)) continue;
      seen.add(t);
      const full = path.isAbsolute(t) ? t : path.join(repoRoot, t);
      try {
        if (fs.existsSync(full) && fs.statSync(full).isFile()) {
          out.push({ path: t, excerpt: fs.readFileSync(full, 'utf8').slice(0, SPEC_EXCERPT_BYTES) });
        }
      } catch { /* unreadable target — skip */ }
      if (out.length >= 8) break;
    }
    return out;
  }

  private renderChangeSpec(spec: SpecUpdateResult, triage: { reproArtifact: string; severity: string; category: string }): string {
    return [
      `# ${spec.changeId}: ${spec.summary}`,
      ``,
      `Category: ${triage.category} | Severity: ${triage.severity} | Risk: ${spec.riskLevel} | Human approval: ${spec.requiresHumanApproval}`,
      ``,
      `## Proposal`,
      spec.proposal,
      ``,
      `## Delta specs`,
      ...spec.deltaSpecs.map(d => `### ${d.target}\n${d.change}`),
      ``,
      `## Acceptance criteria (EARS)`,
      ...spec.earsCriteria.map((c, i) => `${i + 1}. ${c}`),
      ``,
      `## Tasks`,
      ...spec.tasks.map((t, i) => `- [ ] ${i + 1}. ${t}`),
      ``,
      `## Test plan`,
      spec.testPlan,
      ``,
      `## Reproduction artifact (from triage)`,
      '```',
      triage.reproArtifact || '(n/a — non-bug change)',
      '```',
    ].join('\n');
  }
}
