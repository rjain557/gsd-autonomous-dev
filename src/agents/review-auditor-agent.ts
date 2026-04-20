// ═══════════════════════════════════════════════════════════
// GSD V6 — ReviewAuditorAgent (Cross-Review Gate)
// Runs between QualityGate pass and Deploy. Second opinion
// reviewer that looks for blind spots, contradictions, and
// suspicious passes in the ReviewResult + PatchSet + GateResult.
// Designed to run on Gemini (cheap, 1M context, $0 marginal).
// ═══════════════════════════════════════════════════════════

import { BaseAgent } from '../harness/base-agent';
import type { AgentInput, AgentOutput, ReviewResult, PatchSet, GateResult, Severity } from '../harness/types';

export interface ReviewAuditorInput extends AgentInput {
  reviewResult: ReviewResult;
  patchSet: PatchSet;
  gateResult: GateResult;
  convergenceSummary: string;
}

export interface AuditFinding {
  kind: 'blind-spot' | 'contradiction' | 'suspicious-pass' | 'missing-test' | 'risk';
  severity: Severity;
  message: string;
  evidence: string;
}

export interface ReviewAuditResult extends AgentOutput {
  passed: boolean;
  findings: AuditFinding[];
  confidence: 'high' | 'medium' | 'low';
  recommendation: 'proceed' | 'fix-blocking' | 'halt';
  reviewerModel: string;
}

export class ReviewAuditorAgent extends BaseAgent {
  protected async run(input: AgentInput): Promise<AgentOutput> {
    const { reviewResult, patchSet, gateResult, convergenceSummary } = input as ReviewAuditorInput;

    const findings: AuditFinding[] = [];

    // Heuristic audit: spot obvious contradictions even before LLM call
    if (gateResult.passed && reviewResult.issues.some((i) => i.severity === 'critical')) {
      findings.push({
        kind: 'contradiction',
        severity: 'critical',
        message: 'Quality gate passed but CodeReview reported a critical issue.',
        evidence: `Critical issues: ${reviewResult.issues.filter((i) => i.severity === 'critical').map((i) => i.id).join(', ')}`,
      });
    }

    if (gateResult.coverage < 50 && gateResult.passed) {
      findings.push({
        kind: 'suspicious-pass',
        severity: 'high',
        message: 'Coverage < 50% but gate passed — threshold may be mis-configured.',
        evidence: `coverage=${gateResult.coverage}%`,
      });
    }

    if (patchSet.patches.length > 0 && !patchSet.testsPassed) {
      findings.push({
        kind: 'risk',
        severity: 'high',
        message: 'Patches were applied but tests did not pass for the patch set.',
        evidence: `patches=${patchSet.patches.length}`,
      });
    }

    const filesChanged = new Set(patchSet.patches.map((p) => p.file));
    const testFilesChanged = Array.from(filesChanged).filter((f) => /\.(test|spec)\.(ts|tsx|js)$/i.test(f) || /\.Tests?\//i.test(f));
    if (filesChanged.size > 3 && testFilesChanged.length === 0) {
      findings.push({
        kind: 'missing-test',
        severity: 'medium',
        message: 'Multiple source files changed but no test files were touched.',
        evidence: `srcFiles=${filesChanged.size} testFiles=0`,
      });
    }

    // Second-opinion hook: the harness can override `callAuditLLM` via a
    // subclass to get a deeper LLM review. Default impl returns no findings.
    const llmFindings = await this.callAuditLLM({
      convergenceSummary,
      reviewResult,
      patchSet,
      gateResult,
      filesChangedCount: filesChanged.size,
    });

    const allFindings = [...findings, ...llmFindings];
    const anyBlocking = allFindings.some((f) => f.severity === 'critical' || f.severity === 'high');
    const passed = !anyBlocking;

    const result: ReviewAuditResult = {
      passed,
      findings: allFindings,
      confidence: allFindings.length === 0 ? 'high' : anyBlocking ? 'low' : 'medium',
      recommendation: anyBlocking
        ? (allFindings.some((f) => f.severity === 'critical') ? 'halt' : 'fix-blocking')
        : 'proceed',
      reviewerModel: llmFindings.length > 0 ? 'llm' : 'heuristic',
    };

    return result;
  }

  /**
   * Extension point: the harness can subclass and override this to perform a
   * deep LLM-based second-opinion review (typically on Gemini 1M context).
   * Default: heuristic-only, returns no LLM findings.
   */
  protected async callAuditLLM(_ctx: {
    convergenceSummary: string;
    reviewResult: ReviewResult;
    patchSet: PatchSet;
    gateResult: GateResult;
    filesChangedCount: number;
  }): Promise<AuditFinding[]> {
    return [];
  }
}
