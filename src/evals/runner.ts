// ═══════════════════════════════════════════════════════════
// GSD Agent System — Eval Runner
// Reads test cases from vault, runs each agent in isolation,
// scores output, writes results to vault.
// ═══════════════════════════════════════════════════════════

import { VaultAdapter } from '../harness/vault-adapter';
import { HookSystem } from '../harness/hooks';
import { BaseAgent } from '../harness/base-agent';
import { registerDefaultHooks } from '../harness/default-hooks';
import type { PipelineState, AgentId } from '../harness/types';
import { BlueprintAnalysisAgent } from '../agents/blueprint-analysis-agent';
import { CodeReviewAgent } from '../agents/code-review-agent';
import { QualityGateAgent } from '../agents/quality-gate-agent';
import { DeployAgent } from '../agents/deploy-agent';
import { RemediationAgent } from '../agents/remediation-agent';
import { E2EValidationAgent } from '../agents/e2e-validation-agent';
import { PostDeployValidationAgent } from '../agents/post-deploy-validation-agent';
import { QualityGateFailure } from '../harness/types';
import type { ReviewResult } from '../harness/types';
import { scoreReviewQuality } from './judges/review-quality-judge';

interface TestCase {
  id: string;
  agent: string;
  description: string;
  input: Record<string, unknown>;
  expected: Record<string, unknown>;
  scoring: ScoringRule[];
}

interface ScoringRule {
  field: string;
  type: 'exact' | 'threshold' | 'boolean' | 'error_thrown';
  value?: unknown;
  threshold?: number;
  errorType?: string;
}

interface EvalResult {
  testId: string;
  agent: string;
  passed: boolean;
  score: number;
  maxScore: number;
  details: string[];
  durationMs: number;
}

export class EvalRunner {
  private vault: VaultAdapter;
  private results: EvalResult[] = [];

  constructor(vaultPath: string) {
    this.vault = new VaultAdapter(vaultPath);
  }

  async runAll(): Promise<EvalResult[]> {
    console.log('\n═══════════════════════════════════════════════');
    console.log('  GSD Agent Eval Suite');
    console.log('═══════════════════════════════════════════════\n');

    const testCases = await this.loadTestCases();
    console.log(`Loaded ${testCases.length} test cases\n`);

    for (const tc of testCases) {
      const result = await this.runTestCase(tc);
      this.results.push(result);

      const status = result.passed ? 'PASS' : 'FAIL';
      console.log(`  [${status}] ${tc.id}: ${tc.description} (${result.score}/${result.maxScore})`);
      for (const detail of result.details) {
        console.log(`         ${detail}`);
      }
    }

    // Summary
    const passed = this.results.filter(r => r.passed).length;
    const total = this.results.length;
    console.log(`\n═══════════════════════════════════════════════`);
    console.log(`  Results: ${passed}/${total} passed`);
    console.log(`═══════════════════════════════════════════════\n`);

    // Write results to vault
    await this.writeResults();

    return this.results;
  }

  private async runTestCase(tc: TestCase): Promise<EvalResult> {
    const start = Date.now();
    const details: string[] = [];
    let score = 0;
    const maxScore = tc.scoring.length;

    try {
      // Create isolated agent
      const state = this.createMockState();
      const hooks = new HookSystem();
      registerDefaultHooks(hooks, this.vault, () => state);

      const agent = this.createAgent(tc.agent as AgentId, hooks, state);
      if (!agent) {
        return { testId: tc.id, agent: tc.agent, passed: false, score: 0, maxScore, details: ['Agent not found'], durationMs: Date.now() - start };
      }

      await agent.initialize();

      let output: Record<string, unknown> | null = null;
      let thrownError: Error | null = null;

      try {
        output = await agent.execute(tc.input) as Record<string, unknown>;
      } catch (err) {
        thrownError = err instanceof Error ? err : new Error(String(err));
      }

      // Run quality judge for code review results
      if (tc.agent === 'code-review-agent' && output) {
        const reviewResult = output as unknown as ReviewResult;
        const judgeScore = scoreReviewQuality(reviewResult, 3, 1);
        details.push(`  [JUDGE] Review quality: ${judgeScore.overall}/5 — ${judgeScore.rationale}`);
      }

      // Score against expected
      for (const rule of tc.scoring) {
        const ruleResult = this.scoreRule(rule, output, thrownError);
        if (ruleResult.passed) {
          score++;
          details.push(`  OK: ${rule.field} (${rule.type})`);
        } else {
          details.push(`  FAIL: ${rule.field} — ${ruleResult.reason}`);
        }
      }
    } catch (err) {
      details.push(`  ERROR: ${err instanceof Error ? err.message : String(err)}`);
    }

    return {
      testId: tc.id,
      agent: tc.agent,
      passed: score === maxScore,
      score,
      maxScore,
      details,
      durationMs: Date.now() - start,
    };
  }

  private scoreRule(
    rule: ScoringRule,
    output: Record<string, unknown> | null,
    thrownError: Error | null,
  ): { passed: boolean; reason: string } {
    switch (rule.type) {
      case 'exact': {
        const actual = this.getNestedField(output, rule.field);
        if (actual === rule.value) {
          return { passed: true, reason: '' };
        }
        return { passed: false, reason: `expected ${JSON.stringify(rule.value)}, got ${JSON.stringify(actual)}` };
      }
      case 'threshold': {
        const actual = Number(this.getNestedField(output, rule.field));
        const threshold = rule.threshold ?? 0;
        if (actual >= threshold) {
          return { passed: true, reason: '' };
        }
        return { passed: false, reason: `expected >= ${threshold}, got ${actual}` };
      }
      case 'boolean': {
        const actual = this.getNestedField(output, rule.field);
        if (typeof actual === 'boolean') {
          return { passed: true, reason: '' };
        }
        return { passed: false, reason: `expected boolean, got ${typeof actual}` };
      }
      case 'error_thrown': {
        if (thrownError && rule.errorType) {
          if (thrownError.name === rule.errorType || thrownError.constructor.name === rule.errorType) {
            return { passed: true, reason: '' };
          }
          return { passed: false, reason: `expected ${rule.errorType}, got ${thrownError.name}` };
        }
        if (thrownError) {
          return { passed: true, reason: '' };
        }
        return { passed: false, reason: 'expected error to be thrown, but none was' };
      }
      default:
        return { passed: false, reason: `unknown scoring type: ${rule.type}` };
    }
  }

  private getNestedField(obj: Record<string, unknown> | null, field: string): unknown {
    if (!obj) return undefined;
    const parts = field.split('.');
    let current: unknown = obj;
    for (const part of parts) {
      if (current === null || current === undefined) return undefined;
      if (typeof current === 'object') {
        current = (current as Record<string, unknown>)[part];
      } else {
        return undefined;
      }
    }
    return current;
  }

  private createAgent(agentId: AgentId, hooks: HookSystem, state: PipelineState) {
    type AgentConstructor = new (
      id: AgentId,
      vault: VaultAdapter,
      hooks: HookSystem,
      state: PipelineState,
    ) => BaseAgent;

    const agentMap: Record<string, AgentConstructor> = {
      'blueprint-analysis-agent': BlueprintAnalysisAgent,
      'code-review-agent': CodeReviewAgent,
      'remediation-agent': RemediationAgent,
      'quality-gate-agent': QualityGateAgent,
      'e2e-validation-agent': E2EValidationAgent,
      'deploy-agent': DeployAgent,
      'post-deploy-validation-agent': PostDeployValidationAgent,
    };

    const AgentClass = agentMap[agentId];
    if (!AgentClass) return null;

    return new AgentClass(agentId, this.vault, hooks, state);
  }

  private createMockState(): PipelineState {
    return {
      runId: 'eval-' + Date.now(),
      triggeredBy: 'manual',
      blueprintVersion: '0.0.0',
      convergenceReport: null,
      reviewResult: null,
      patchSet: null,
      gateResult: null,
      deployRecord: null,
      decisions: [],
      currentStage: 'blueprint',
      status: 'running',
      costAccumulator: [],
      startedAt: new Date().toISOString(),
      completedAt: null,
    };
  }

  private async loadTestCases(): Promise<TestCase[]> {
    // Try to parse from vault markdown first
    try {
      const note = await this.vault.read('evals/test-cases.md');
      const parsed = this.parseTestCasesFromMarkdown(note.body);
      if (parsed.length > 0) {
        console.log(`  Loaded ${parsed.length} test cases from vault`);
        return parsed;
      }
    } catch {
      console.log('  Vault test-cases.md not found, using built-in test cases');
    }

    // Built-in test cases matching the vault spec
    return this.getBuiltInTestCases();
  }

  private getBuiltInTestCases(): TestCase[] {
    return [
      {
        id: 'TC-BA-001',
        agent: 'blueprint-analysis-agent',
        description: 'Detect drift items from blueprint',
        input: {
          blueprintPath: 'test-fixtures/blueprint-with-drift.json',
          specPaths: ['test-fixtures/spec-phase-a.md'],
          repoRoot: 'test-fixtures/repo-with-drift',
        },
        expected: { riskLevel: 'medium' },
        scoring: [
          { field: 'riskLevel', type: 'exact', value: 'medium' },
          { field: 'drifted.length', type: 'threshold', threshold: 1 },
        ],
      },
      {
        id: 'TC-CR-001',
        agent: 'code-review-agent',
        description: 'Detect lint violations and security issues',
        input: {
          convergenceReport: { aligned: [], drifted: [], missing: [], riskLevel: 'low' },
          changedFiles: ['test-fixtures/code-with-issues/AuthService.cs'],
          qualityGates: { minCoverage: 80, blockOnCritical: true, securityScanEnabled: true },
        },
        expected: { passed: false },
        scoring: [
          { field: 'passed', type: 'exact', value: false },
          { field: 'issues.length', type: 'threshold', threshold: 1 },
        ],
      },
      {
        id: 'TC-QG-001',
        agent: 'quality-gate-agent',
        description: 'Pass when all thresholds met',
        input: {
          patchSet: { patches: [], testsPassed: true },
          qualityThresholds: { minCoverage: 80, blockOnCritical: true, securityScanEnabled: true },
        },
        expected: { passed: true },
        scoring: [
          { field: 'passed', type: 'exact', value: true },
          { field: 'evidence.length', type: 'threshold', threshold: 1 },
        ],
      },
      {
        id: 'TC-QG-002',
        agent: 'quality-gate-agent',
        description: 'Fail when coverage below threshold',
        input: {
          patchSet: { patches: [], testsPassed: true },
          qualityThresholds: { minCoverage: 95, blockOnCritical: true, securityScanEnabled: true },
        },
        expected: {},
        scoring: [
          { field: 'error', type: 'error_thrown', errorType: 'QualityGateFailure' },
        ],
      },
      {
        id: 'TC-DA-001',
        agent: 'deploy-agent',
        description: 'Reject when GateResult.passed is false',
        input: {
          gateResult: { passed: false, coverage: 70, securityScore: 50, evidence: ['tests failed'] },
          deployConfig: { environment: 'alpha', target: '10.100.253.131', healthEndpoint: '/api/health' },
          commitSha: 'abc123',
        },
        expected: {},
        scoring: [
          { field: 'error', type: 'error_thrown', errorType: 'HardGateViolation' },
        ],
      },
      {
        id: 'TC-RA-001',
        agent: 'remediation-agent',
        description: 'Fix a single critical issue',
        input: {
          reviewResult: {
            passed: false,
            issues: [{
              id: 'ISS-001', file: 'test-fixtures/fixable/Service.cs', line: 10,
              severity: 'critical', category: 'security', message: 'Hardcoded connection string',
            }],
            coveragePercent: 85,
            securityFlags: ['hardcoded-secret'],
          },
          repoRoot: 'test-fixtures/fixable',
        },
        expected: {},
        scoring: [
          { field: 'testsPassed', type: 'boolean' },
        ],
      },
    ];
  }

  /** Parse test cases from vault markdown format. */
  private parseTestCasesFromMarkdown(body: string): TestCase[] {
    const cases: TestCase[] = [];

    // Split by ### TC- headers
    const sections = body.split(/(?=### TC-)/);

    for (const section of sections) {
      const idMatch = section.match(/### (TC-\w+-\d+):\s*(.+)/);
      if (!idMatch) continue;

      const id = idMatch[1];
      const description = idMatch[2].trim();

      // Extract agent from the parent ## section
      const agentMatch = body.substring(0, body.indexOf(section)).match(/## (\w+Agent)\b/);

      // Extract Input JSON
      const inputMatch = section.match(/\*\*Input:\*\*\s*```json\s*\n([\s\S]*?)```/);
      let input: Record<string, unknown> = {};
      if (inputMatch) {
        try { input = JSON.parse(inputMatch[1]); } catch { /* skip */ }
      }

      // Extract scoring rules from the **Scoring:** line
      const scoring: ScoringRule[] = [];
      const scoringMatch = section.match(/\*\*Scoring:\*\*\s*(.+)/);
      if (scoringMatch) {
        const rules = scoringMatch[1].split(',').map(s => s.trim());
        for (const rule of rules) {
          const exactMatch = rule.match(/(\w+(?:\.\w+)*)\s*===?\s*(.+)/);
          const thresholdMatch = rule.match(/(\w+(?:\.\w+)*)\s*>=?\s*(\d+)/);
          if (exactMatch) {
            let value: unknown = exactMatch[2].trim();
            if (value === 'true') value = true;
            else if (value === 'false') value = false;
            else if (/^\d+$/.test(value as string)) value = parseInt(value as string);
            scoring.push({ field: exactMatch[1], type: 'exact', value });
          } else if (thresholdMatch) {
            scoring.push({ field: thresholdMatch[1], type: 'threshold', threshold: parseInt(thresholdMatch[2]) });
          }
        }
      }

      // Determine agent from section context
      let agent = '';
      if (id.startsWith('TC-BA')) agent = 'blueprint-analysis-agent';
      else if (id.startsWith('TC-CR')) agent = 'code-review-agent';
      else if (id.startsWith('TC-QG')) agent = 'quality-gate-agent';
      else if (id.startsWith('TC-DA')) agent = 'deploy-agent';
      else if (id.startsWith('TC-RA')) agent = 'remediation-agent';

      if (agent && Object.keys(input).length > 0) {
        cases.push({ id, agent, description, input, expected: {}, scoring });
      }
    }

    return cases;
  }

  private async writeResults(): Promise<void> {
    const date = new Date().toISOString().split('T')[0];
    const passed = this.results.filter(r => r.passed).length;
    const total = this.results.length;

    const content = [
      `# Eval Results — ${date}`,
      '',
      `| Test | Agent | Score | Status |`,
      `|---|---|---|---|`,
      ...this.results.map(r =>
        `| ${r.testId} | ${r.agent} | ${r.score}/${r.maxScore} | ${r.passed ? 'PASS' : 'FAIL'} |`
      ),
      '',
      `**Total: ${passed}/${total} passed**`,
    ].join('\n');

    await this.vault.create(`evals/results/${date}.md`, {
      type: 'eval-results',
      date,
      passed,
      total,
    }, content);
  }
}

// ── CLI entry point ──

async function main(): Promise<void> {
  const vaultPath = process.argv[2] ?? './memory';
  const runner = new EvalRunner(vaultPath);
  const results = await runner.runAll();

  const allPassed = results.every(r => r.passed);
  process.exit(allPassed ? 0 : 1);
}

main().catch(err => {
  console.error('Eval runner failed:', err);
  process.exit(1);
});
