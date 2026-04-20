// ═══════════════════════════════════════════════════════════
// GSD Agent System — Orchestrator
// Plans the task graph, routes work between agents, collects
// results, decides retry/escalate/halt, logs all decisions.
// ═══════════════════════════════════════════════════════════

import { v4 as uuidv4 } from 'uuid';
import type {
  AgentId,
  PipelineState,
  PipelineStage,
  PipelineTrigger,
  Decision,
  TaskGraph,
  TaskNode,
  ConvergenceReport,
  ReviewResult,
  PatchSet,
  GateResult,
  DeployRecord,
  QualityGateThresholds,
  ProjectPaths,
} from './types';
import { QualityGateFailure, EscalationError, HardGateViolation } from './types';
import { VaultAdapter } from './vault-adapter';
import { HookSystem } from './hooks';
import { RateLimiter } from './rate-limiter';
import { registerDefaultHooks } from './default-hooks';
import { BaseAgent } from './base-agent';

// Agent imports
import { BlueprintAnalysisAgent } from '../agents/blueprint-analysis-agent';
import { CodeReviewAgent } from '../agents/code-review-agent';
import { RemediationAgent } from '../agents/remediation-agent';
import { QualityGateAgent } from '../agents/quality-gate-agent';
import { E2EValidationAgent } from '../agents/e2e-validation-agent';
import { PostDeployValidationAgent } from '../agents/post-deploy-validation-agent';
import { DeployAgent } from '../agents/deploy-agent';
import { ReviewAuditorAgent } from '../agents/review-auditor-agent';

// V6 primitives
import { StuckDetector } from './v6/stuck-detector';
import { runMechanicalFixBand } from './v6/mechanical-fix';
import { StateDB } from './v6/state-db';
import type { ObservabilityLogger } from './v6/observability-logger';
import type { BudgetRouter } from './v6/budget-router';
import { CapabilityRouter } from './v6/capability-router';
import type { AgentCapability } from './v6/types';
import { GitTxn } from './v6/git-txn';
import { getProjectStackContext } from './project-stack-context';
import * as path from 'path';

/**
 * Phase-to-agent routing table.
 * Primary = subscription CLI ($0 marginal). Fallbacks tried in order.
 * DeepSeek/MiniMax are emergency-only (pay-per-token API).
 */
const PHASE_ROUTING: Record<string, string[]> = {
  blueprint:    ['claude', 'gemini', 'codex'],
  review:       ['claude', 'gemini', 'codex'],
  remediate:    ['claude', 'codex', 'gemini'],
  gate:         ['claude', 'codex'],
  audit:        ['gemini', 'claude'], // V6: prefer Gemini for 1M context cross-review
  e2e:          ['claude', 'gemini', 'codex'],
  deploy:       ['claude'],
  'post-deploy': ['claude', 'gemini'],
};

export class Orchestrator {
  private agents = new Map<AgentId, BaseAgent>();
  private vault: VaultAdapter;
  private vaultPath: string;
  private hooks: HookSystem;
  private rateLimiter: RateLimiter;
  private stuckDetector: StuckDetector | null = null;
  private capabilityRouter: CapabilityRouter | null = null;
  private milestoneContext: {
    observability?: ObservabilityLogger | null;
    budgetRouter?: BudgetRouter | null;
    runId?: string | null;
    compactedOutputDir?: string | null;
  } | null = null;
  state: PipelineState;

  // v6.1.0: project root for per-project stack-overrides resolution
  private projectRoot: string;

  constructor(vaultPath: string, projectRoot: string = process.cwd()) {
    this.vaultPath = vaultPath;
    this.projectRoot = projectRoot;
    this.vault = new VaultAdapter(vaultPath);
    this.hooks = new HookSystem();
    this.rateLimiter = new RateLimiter(0.8);
    this.state = this.createInitialState('manual');
  }

  /** V6: attach milestone context (observability + budget + runId). Call before initialize(). */
  setMilestoneContext(ctx: {
    observability?: ObservabilityLogger | null;
    budgetRouter?: BudgetRouter | null;
    runId?: string | null;
    compactedOutputDir?: string | null;
  }): void {
    this.milestoneContext = ctx;
    // If agents already instantiated, propagate to them
    for (const agent of this.agents.values()) {
      agent.setMilestoneContext(ctx);
    }
  }

  /** Load all agent notes, register hooks, instantiate agents, create state. */
  async initialize(): Promise<void> {
    // Register default hooks
    registerDefaultHooks(this.hooks, this.vault, () => this.state);

    // Register rate limits for the 3 subscription CLIs
    // These are the primary workhorses — $0 marginal cost
    this.rateLimiter.registerAgent('claude', { rpm: 10, cooldownMs: 5 * 60_000, safetyFactor: 0.8 });
    this.rateLimiter.registerAgent('codex',  { rpm: 10, cooldownMs: 5 * 60_000, safetyFactor: 0.8 });
    this.rateLimiter.registerAgent('gemini', { rpm: 15, cooldownMs: 5 * 60_000, safetyFactor: 0.8 });

    // Emergency API fallbacks (pay-per-token — avoid unless all subscriptions exhausted)
    this.rateLimiter.registerAgent('deepseek', { rpm: 60, cooldownMs: 5 * 60_000, safetyFactor: 0.8 });
    this.rateLimiter.registerAgent('minimax',  { rpm: 30, cooldownMs: 5 * 60_000, safetyFactor: 0.8 });

    // Instantiate agents
    const agentDefs: Array<[AgentId, new (...args: ConstructorParameters<typeof BaseAgent>) => BaseAgent]> = [
      ['blueprint-analysis-agent', BlueprintAnalysisAgent],
      ['code-review-agent', CodeReviewAgent],
      ['remediation-agent', RemediationAgent],
      ['quality-gate-agent', QualityGateAgent],
      ['review-auditor-agent', ReviewAuditorAgent],   // V6: cross-review gate
      ['e2e-validation-agent', E2EValidationAgent],
      ['deploy-agent', DeployAgent],
      ['post-deploy-validation-agent', PostDeployValidationAgent],
    ];

    // Agent-to-stage mapping for phase-based model routing
    // (models are picked dynamically per stage via pickAgentForPhase, not hardcoded)
    // v6.1.0: resolve project stack context once per run (reads
    // <projectRoot>/docs/gsd/stack-overrides.md; defaults to .NET 8)
    const stackContext = await getProjectStackContext(this.projectRoot);
    console.log(`[ORCHESTRATOR] Project stack: ${stackContext.backendFramework} (source: ${stackContext.source})`);

    for (const [id, AgentClass] of agentDefs) {
      const agent = new AgentClass(id, this.vault, this.hooks, this.state);
      await agent.initialize();
      // Initial rate limiter set to claude; overridden per-stage in run()
      agent.setRateLimiter(this.rateLimiter, 'claude');
      // V6: propagate milestone context if set
      if (this.milestoneContext) agent.setMilestoneContext(this.milestoneContext);
      // v6.1.0: inject per-project stack context
      agent.setProjectStackContext(stackContext);
      this.agents.set(id, agent);
    }

    // V6: initialize StuckDetector backed by the shared state.db
    try {
      const dbPath = path.join(this.vaultPath, 'state.db');
      const sdb = new StateDB(dbPath);
      this.stuckDetector = new StuckDetector(sdb, 2);
    } catch {
      this.stuckDetector = null;
    }

    // V6: initialize CapabilityRouter with static capability profiles per CLI model
    const capabilities: AgentCapability[] = [
      { agentId: 'claude',   languages: ['typescript', 'csharp', 'sql', 'tsx'],         domains: ['auth', 'billing', 'ui', 'api', 'db'], maxContextTokens: 200_000, qualityScore: 0.95, availabilityScore: 1.0 },
      { agentId: 'codex',    languages: ['typescript', 'csharp', 'sql', 'python'],      domains: ['api', 'db', 'refactor'],              maxContextTokens: 200_000, qualityScore: 0.90, availabilityScore: 1.0 },
      { agentId: 'gemini',   languages: ['typescript', 'csharp', 'sql', 'tsx', 'md'],   domains: ['research', 'review', 'audit', 'ui'],  maxContextTokens: 1_000_000, qualityScore: 0.88, availabilityScore: 1.0 },
      { agentId: 'deepseek', languages: ['typescript', 'csharp', 'sql', 'python'],      domains: ['api', 'db', 'refactor'],              maxContextTokens: 128_000, qualityScore: 0.82, availabilityScore: 0.9 },
      { agentId: 'minimax',  languages: ['typescript', 'csharp', 'sql'],                domains: ['api', 'review'],                      maxContextTokens: 200_000, qualityScore: 0.78, availabilityScore: 0.9 },
    ];
    this.capabilityRouter = new CapabilityRouter(capabilities);

    // Log subscription status
    console.log(`[ORCHESTRATOR] Initialized ${this.agents.size} agents`);
    console.log(`[ORCHESTRATOR] Subscription CLIs: Claude Max + ChatGPT Max + Gemini Ultra ($0 marginal)`);
    console.log(`[ORCHESTRATOR] API fallbacks: DeepSeek + MiniMax (emergency only)`);
    if (this.stuckDetector) console.log(`[ORCHESTRATOR] V6 StuckDetector: active`);
  }

  /** Get the best CLI agent for a phase, respecting rate limits, V6 budget pressure, and capability scoring. */
  private pickAgentForPhase(phase: string): string {
    let candidates = PHASE_ROUTING[phase] ?? ['claude', 'codex', 'gemini'];

    // V6: CapabilityRouter — re-order candidates by score for this phase's task shape
    if (this.capabilityRouter) {
      const domainForPhase: Record<string, string[]> = {
        blueprint: ['review', 'research'],
        review:    ['review'],
        remediate: ['refactor', 'api', 'db'],
        gate:      ['review'],
        audit:     ['audit', 'review'],
        e2e:       ['ui', 'api'],
        deploy:    ['api'],
        'post-deploy': ['api', 'ui'],
      };
      const ranked = this.capabilityRouter.rank({
        languages: ['typescript', 'csharp', 'sql'],
        domains: domainForPhase[phase] ?? [],
        tokenSize: 0,
        stage: phase,
      });
      const rankedIds = ranked.map((r) => r.agentId);
      // Keep only candidates in the phase routing list, but order by capability score
      candidates = rankedIds.filter((id) => candidates.includes(id)).concat(
        candidates.filter((id) => !rankedIds.includes(id)),
      );
      this.logObs('router-decisions', 'capability-rank', { phase, rankedCandidates: candidates, topScore: ranked[0]?.score });
    }

    // V6: if a budget router is attached and budget pressure warrants it, downgrade.
    const budget = this.milestoneContext?.budgetRouter;
    if (budget) {
      const status = budget.status;
      if (status.tier === 'emergency') {
        candidates = ['deepseek', 'minimax'];
        this.logObs('router-decisions', 'budget-emergency-override', { phase, candidates, status });
      } else if (status.tier === 'downgrade-hard') {
        // Prefer gemini (cheapest subscription CLI) at >= 75%
        candidates = ['gemini', ...candidates.filter((c) => c !== 'gemini')];
        this.logObs('router-decisions', 'budget-hard-downgrade', { phase, candidates, status });
      } else if (status.tier === 'downgrade-soft') {
        // Prefer gemini/codex over premium (claude) at >= 50%
        candidates = [...candidates.filter((c) => c !== 'claude'), 'claude'];
        this.logObs('router-decisions', 'budget-soft-downgrade', { phase, candidates, status });
      }
    }

    const available = this.rateLimiter.pickAvailable(candidates);
    if (available) return available;

    // All subscription CLIs exhausted — try API fallbacks
    const apiFallback = this.rateLimiter.pickAvailable(['deepseek', 'minimax']);
    if (apiFallback) {
      console.log(`[ORCHESTRATOR] All subscription CLIs busy — falling back to API: ${apiFallback}`);
      return apiFallback;
    }

    // Everything exhausted — return primary and let rate limiter sleep
    return candidates[0];
  }

  /** Run the full pipeline from trigger to completion. */
  async run(trigger: PipelineTrigger): Promise<PipelineState> {
    this.state = this.createInitialState(trigger.trigger);

    // Resume from stage if specified
    const startStage = trigger.fromStage ?? 'blueprint';
    if (trigger.fromStage) {
      console.log(`[ORCHESTRATOR] Resuming from stage: ${trigger.fromStage}`);
      await this.loadLastState(trigger);
    }

    const graph = await this.buildTaskGraph();

    console.log(`[ORCHESTRATOR] Pipeline run=${this.state.runId} trigger=${trigger.trigger}`);
    console.log(`[ORCHESTRATOR] Task graph: ${graph.nodes.length} steps`);

    // Execute stages in dependency order (V6: audit inserted between gate and e2e)
    const stageOrder: PipelineStage[] = ['blueprint', 'review', 'remediate', 'gate', 'audit', 'e2e', 'deploy', 'post-deploy'];
    const startIdx = stageOrder.indexOf(startStage);

    for (let i = startIdx; i < stageOrder.length; i++) {
      const stage = stageOrder[i];

      // Skip deploy in dry-run mode
      if (stage === 'deploy' && trigger.dryRun) {
        await this.logDecision(stage, 'skip_deploy', 'Dry run mode — skipping deploy', '');
        console.log(`[ORCHESTRATOR] DRY RUN — would deploy commit ${this.state.gateResult?.passed ? '(gate passed)' : '(gate NOT passed)'}`);
        break;
      }

      // Skip remediate if review passed
      if (stage === 'remediate' && this.state.reviewResult?.passed) {
        await this.logDecision(stage, 'skip', 'Review passed — no remediation needed', '');
        continue;
      }

      // Skip gate if going through remediation loop (handled separately)
      if (stage === 'gate' && !this.state.reviewResult?.passed && !this.state.patchSet) {
        await this.logDecision(stage, 'skip_gate',
          'Gate skipped — review failed and no patches yet; remediation loop will handle gate',
          '');
        continue;
      }

      this.state.currentStage = stage;

      // Pick the best available CLI model for this stage (rate-limit aware)
      const cliModel = this.pickAgentForPhase(stage);
      this.rateLimiter.trackModelSwitch(stage, cliModel);
      // Update only the agent that will run in this stage (not all agents)
      const stageAgentId = this.getAgentIdForStage(stage);
      const stageAgent = stageAgentId ? this.agents.get(stageAgentId) : undefined;
      if (stageAgent) stageAgent.setRateLimiter(this.rateLimiter, cliModel);

      try {
        await this.executeStage(stage);
        await this.saveState(); // Persist state after each stage for --from-stage resume
      } catch (err) {
        if (err instanceof QualityGateFailure) {
          // Gate failed — enter remediation loop
          await this.logDecision(stage, 'enter_remediation_loop',
            'Quality gate failed — starting remediation loop',
            JSON.stringify(err.gateResult.evidence.slice(0, 3)));

          const loopResult = await this.handleRemediationLoop(
            this.state.reviewResult!,
            3, // max iterations
          );

          if (loopResult.passed) {
            this.state.gateResult = loopResult;
            await this.logDecision('gate', 'passed_after_remediation',
              `Gate passed after remediation loop`,
              `coverage=${loopResult.coverage}%`);
            await this.saveState(); // Persist before moving to deploy
            continue;
          } else {
            this.state.status = 'failed';
            await this.logDecision('gate', 'failed_after_remediation',
              `Gate still failing after max remediation iterations`,
              JSON.stringify(loopResult.evidence.slice(0, 3)));
            await this.saveState(); // Persist failure state for resume
            break;
          }
        }

        if (err instanceof EscalationError) {
          // Agent exhausted all retries — log with full context
          this.state.status = 'paused';
          await this.logDecision(stage, 'escalation',
            `Agent ${err.agentId} failed after ${err.attempts} attempts: ${err.lastError.message}`,
            `Last error: ${err.lastError.name}`);
          console.error(`\n[ESCALATION] ${err.agentId} exhausted ${err.attempts} retries. Pipeline paused.`);
          console.error(`  Resume: pipeline run --from-stage ${stage}\n`);
          break;
        }

        // Unrecoverable error (unknown type)
        this.state.status = 'failed';
        await this.logDecision(stage, 'halt',
          `Unrecoverable error: ${err instanceof Error ? err.message : String(err)}`,
          '');
        break;
      }
    }

    if (this.state.status === 'running') {
      this.state.status = 'complete';
    }
    this.state.completedAt = new Date().toISOString();

    // Write final session summary
    await this.vault.append(
      `sessions/${new Date().toISOString().split('T')[0]}-run-${this.state.runId}.md`,
      this.buildFinalSummary(),
    );

    return this.state;
  }

  /** Execute a single pipeline stage. */
  private async executeStage(stage: PipelineStage): Promise<void> {
    switch (stage) {
      case 'blueprint': {
        const agent = this.agents.get('blueprint-analysis-agent')!;
        const report = await this.executeWithRetry(agent, {
          blueprintPath: '.gsd/health/requirements-matrix.json',
          specPaths: await this.findSpecPaths(),
          repoRoot: process.cwd(),
        }) as ConvergenceReport;

        this.state.convergenceReport = report;
        await this.logDecision('blueprint', 'complete',
          `Analysis complete: ${report.aligned.length} aligned, ${report.drifted.length} drifted, ${report.missing.length} missing`,
          `riskLevel=${report.riskLevel}`);

        // Decision: proceed if risk is acceptable
        if (report.riskLevel === 'high') {
          await this.logDecision('blueprint', 'warn_high_risk',
            'High risk level detected — proceeding with caution',
            `${report.drifted.length} drifted items`);
        }
        break;
      }

      case 'review': {
        const agent = this.agents.get('code-review-agent')!;
        const qualityGates = await this.loadQualityGates();
        const result = await this.executeWithRetry(agent, {
          convergenceReport: this.state.convergenceReport!,
          changedFiles: await this.getChangedFiles(),
          qualityGates,
        }) as ReviewResult;

        this.state.reviewResult = result;
        await this.logDecision('review', result.passed ? 'passed' : 'failed',
          `Review ${result.passed ? 'passed' : 'failed'}: ${result.issues.length} issues, coverage=${result.coveragePercent}%`,
          result.securityFlags.length > 0 ? `security: ${result.securityFlags.join(', ')}` : '');
        break;
      }

      case 'remediate': {
        const agent = this.agents.get('remediation-agent')!;
        const patchSet = await this.executeWithRetry(agent, {
          reviewResult: this.state.reviewResult!,
          repoRoot: process.cwd(),
        }) as PatchSet;

        this.state.patchSet = patchSet;
        await this.logDecision('remediate', 'complete',
          `Applied ${patchSet.patches.length} patches, tests ${patchSet.testsPassed ? 'passed' : 'failed'}`,
          patchSet.patches.map(p => p.issueId).join(', '));
        break;
      }

      case 'gate': {
        const agent = this.agents.get('quality-gate-agent')!;
        const qualityGates = await this.loadQualityGates();
        const result = await this.executeWithRetry(agent, {
          patchSet: this.state.patchSet ?? { patches: [], testsPassed: true },
          qualityThresholds: qualityGates,
        }) as GateResult;

        this.state.gateResult = result;
        this.logObs('gate-results', 'gate-complete', {
          passed: result.passed,
          coverage: result.coverage,
          securityScore: result.securityScore,
          evidenceCount: result.evidence.length,
        });
        await this.logDecision('gate', 'passed',
          `Gate passed: coverage=${result.coverage}%, security=${result.securityScore}`,
          result.evidence.join(' | '));
        break;
      }

      case 'audit': {
        // V6 cross-review gate between QualityGate (pass) and Deploy.
        if (!this.state.gateResult?.passed) {
          await this.logDecision('audit', 'skip', 'Gate did not pass — audit skipped', '');
          break;
        }
        const agent = this.agents.get('review-auditor-agent');
        if (!agent) {
          await this.logDecision('audit', 'skip', 'ReviewAuditorAgent not registered', '');
          break;
        }
        const auditInput = {
          reviewResult: this.state.reviewResult ?? { passed: true, issues: [], coveragePercent: 0, securityFlags: [] },
          patchSet: this.state.patchSet ?? { patches: [], testsPassed: true },
          gateResult: this.state.gateResult,
          convergenceSummary: this.state.convergenceReport
            ? `aligned=${this.state.convergenceReport.aligned.length} drifted=${this.state.convergenceReport.drifted.length} missing=${this.state.convergenceReport.missing.length}`
            : '(no convergence report)',
        };
        const audit = await this.executeWithRetry(agent, auditInput as unknown as Record<string, unknown>) as Record<string, unknown>;
        const auditPassed = audit.passed === true;
        await this.logDecision('audit', auditPassed ? 'passed' : 'failed',
          `Cross-review: ${(audit.findings as unknown[] | undefined)?.length ?? 0} findings, recommendation=${audit.recommendation}`,
          `confidence=${audit.confidence} reviewer=${audit.reviewerModel}`);
        if (!auditPassed) {
          // Audit blocks deploy: mark gate as failed so downstream HardGateViolation trips
          this.state.gateResult = { ...this.state.gateResult, passed: false };
        }
        break;
      }

      case 'deploy': {
        // DeployAgent has its own HardGateViolation assertion.
        // Pre-check here as a fast path to avoid unnecessary agent setup.
        if (!this.state.gateResult?.passed) {
          throw new HardGateViolation('Orchestrator pre-check: GateResult.passed is not true');
        }

        const agent = this.agents.get('deploy-agent')!;
        const deployConfig = await this.loadDeployConfig();
        const commitSha = await this.getCurrentCommitSha();

        const record = await this.executeWithRetry(agent, {
          gateResult: this.state.gateResult,
          deployConfig,
          commitSha,
        }) as DeployRecord;

        this.state.deployRecord = record;
        this.logObs('deploy-logs', 'deploy-complete', {
          success: record.success,
          environment: record.environment,
          commitSha: record.commitSha,
          steps: record.steps.map((s) => ({ name: s.name, success: s.success, durationMs: s.durationMs })),
          rollbackExecuted: record.rollbackExecuted,
        });
        await this.logDecision('deploy', record.success ? 'success' : 'failed',
          `Deploy ${record.success ? 'succeeded' : 'failed'} to ${record.environment}`,
          record.rollbackExecuted ? 'ROLLBACK EXECUTED' : '');
        break;
      }

      case 'e2e': {
        const agent = this.agents.get('e2e-validation-agent')!;
        const deployConfig = await this.loadDeployConfig();
        const projectPaths = await this.loadProjectPaths();
        const result = await this.executeWithRetry(agent, {
          repoRoot: process.cwd(),
          backendUrl: `http://${deployConfig.target}`,
          frontendUrl: `http://${deployConfig.target}`,
          storyboardsPath: projectPaths.storyboardsPath,
          apiContractsPath: projectPaths.apiContractsPath,
          screenStatesPath: projectPaths.screenStatesPath,
          apiSpMapPath: projectPaths.apiSpMapPath,
        }) as Record<string, unknown>;

        const passed = result.passed as boolean;
        this.logObs('e2e-traces', 'e2e-complete', {
          passed,
          totalFlows: result.totalFlows,
          passedFlows: result.passedFlows,
          failedFlows: result.failedFlows,
          categories: result.categories,
        });
        await this.logDecision('e2e', passed ? 'passed' : 'failed',
          `E2E validation: ${result.passedFlows}/${result.totalFlows} flows passed`,
          `API: ${(result.categories as Record<string, unknown>)?.apiContract ? JSON.stringify((result.categories as Record<string, Record<string, unknown>>).apiContract.failures).substring(0, 200) : ''}`);

        if (!passed) {
          // E2E failures should block deploy but not halt — route to remediation
          await this.logDecision('e2e', 'route_to_remediation',
            'E2E validation failed — routing to remediation before deploy', '');
        }
        break;
      }

      case 'post-deploy': {
        if (!this.state.deployRecord?.success) {
          await this.logDecision('post-deploy', 'skip',
            'Skipping post-deploy validation — deploy did not succeed', '');
          break;
        }

        const agent = this.agents.get('post-deploy-validation-agent')!;
        const deployConfig = await this.loadDeployConfig();
        const target = deployConfig.target;
        const baseUrl = target.startsWith('http') ? target : `http://${target}`;

        const postDeployPaths = await this.loadProjectPaths();
        const result = await this.executeWithRetry(agent, {
          deployRecord: this.state.deployRecord,
          frontendUrl: baseUrl,
          apiBaseUrl: baseUrl,
          storyboardsPath: postDeployPaths.storyboardsPath,
          apiContractsPath: postDeployPaths.apiContractsPath,
        }) as Record<string, unknown>;

        const passed = result.passed as boolean;
        const checks = (result.checks as Array<Record<string, unknown>>) ?? [];
        const failed = checks.filter(c => !c.passed);

        await this.logDecision('post-deploy', passed ? 'passed' : 'failed',
          `Post-deploy: ${checks.length - failed.length}/${checks.length} checks passed`,
          failed.length > 0 ? failed.slice(0, 3).map(c => `${c.name}: ${c.details}`).join(' | ') : '');

        if (!passed) {
          console.error(`\n[POST-DEPLOY FAILURE] ${failed.length} checks failed. Consider rollback.`);
          for (const f of failed) {
            console.error(`  [${f.severity}] ${f.name}: ${f.details}`);
          }
        }
        break;
      }
    }
  }

  /** Execute an agent with retry logic based on vault config. V6: wrapped in a git transaction that rolls back on failure if the agent is destructive. */
  private async executeWithRetry(agent: BaseAgent, input: Record<string, unknown>): Promise<Record<string, unknown>> {
    const agentId = (agent as unknown as { agentId: AgentId }).agentId;
    const maxRetries = await this.getMaxRetries(agentId);

    // V6: destructive agents (those that write code) run inside a git transaction.
    // Read-only agents (review, gate, audit, e2e) don't need a transaction.
    const destructiveAgents: AgentId[] = ['remediation-agent', 'deploy-agent'];
    const needsTxn = destructiveAgents.includes(agentId) && this.isGitRepo();

    for (let attempt = 0; attempt <= maxRetries; attempt++) {
      let txn: GitTxn | null = null;
      let handle: Awaited<ReturnType<GitTxn['begin']>> | null = null;
      if (needsTxn) {
        try {
          txn = new GitTxn({ cwd: process.cwd() });
          handle = await txn.begin();
          this.logObs('router-decisions', 'git-txn-begin', { agentId, attempt, beganAtSha: handle.beganAtSha });
        } catch (e) {
          // Git txn setup failed — proceed without it rather than halting
          txn = null;
          handle = null;
          this.logObs('router-decisions', 'git-txn-setup-failed', { agentId, error: (e as Error).message });
        }
      }

      try {
        const result = await agent.execute(input) as Record<string, unknown>;
        // Success: commit the txn if we started one
        if (txn && handle) {
          try {
            const sha = await txn.commit(handle, `[gsd-v6] ${agentId} attempt=${attempt + 1}`);
            this.logObs('router-decisions', 'git-txn-commit', { agentId, sha, attempt });
          } catch (e) {
            this.logObs('router-decisions', 'git-txn-commit-failed', { agentId, error: (e as Error).message });
          }
        }
        return result;
      } catch (err) {
        // Failure: rollback txn to pre-task state
        if (txn && handle) {
          try {
            await txn.rollback(handle);
            this.logObs('router-decisions', 'git-txn-rollback', { agentId, attempt, beganAtSha: handle.beganAtSha });
          } catch (rbErr) {
            this.logObs('router-decisions', 'git-txn-rollback-failed', { agentId, error: (rbErr as Error).message });
          }
        }

        if (err instanceof QualityGateFailure) {
          throw err; // Don't retry gate failures — they're intentional
        }

        if (attempt < maxRetries) {
          await this.hooks.fire('onRetry', {
            runId: this.state.runId,
            agentId,
            attempt: attempt + 1,
            state: this.state,
          });
          console.log(`[ORCHESTRATOR] Retrying ${agentId} (attempt ${attempt + 2}/${maxRetries + 1})`);
        } else {
          throw new EscalationError(
            agentId,
            maxRetries + 1,
            err instanceof Error ? err : new Error(String(err)),
          );
        }
      }
    }

    throw new Error('Unreachable');
  }

  private isGitRepo(): boolean {
    try {
      require('child_process').execFileSync('git', ['rev-parse', '--is-inside-work-tree'], { cwd: process.cwd(), stdio: 'pipe', timeout: 5000 });
      return true;
    } catch {
      return false;
    }
  }

  /** Remediation → Gate loop with max iterations. */
  private async handleRemediationLoop(
    reviewResult: ReviewResult,
    maxIterations: number,
  ): Promise<GateResult> {
    let lastGateResult: GateResult = {
      passed: false,
      coverage: 0,
      securityScore: 0,
      evidence: ['Initial gate failure — entering remediation loop'],
    };

    for (let i = 0; i < maxIterations; i++) {
      console.log(`[ORCHESTRATOR] Remediation loop iteration ${i + 1}/${maxIterations}`);

      // V6: run the mechanical-fix band first — cheap, fast, sometimes resolves the failure
      try {
        const mech = await runMechanicalFixBand({ cwd: process.cwd(), timeoutMs: 120_000 });
        await this.logDecision('remediate', 'mechanical-fix-band',
          `mechfix: ${mech.steps.filter((s) => s.ran && s.success).length}/${mech.steps.length} steps ok, anyChange=${mech.anyChange}`,
          mech.steps.map((s) => `${s.name}:${s.success ? 'ok' : 'fail'}`).join(' | '));
      } catch { /* mechfix band is best-effort */ }

      // Run remediation
      this.state.currentStage = 'remediate';
      const remAgent = this.agents.get('remediation-agent')!;
      const patchSet = await this.executeWithRetry(remAgent, {
        reviewResult,
        repoRoot: process.cwd(),
      }) as PatchSet;
      this.state.patchSet = patchSet;

      // V6: StuckDetector — hash the PatchSet; if the same hash reappears, escalate
      if (this.stuckDetector) {
        const signal = this.stuckDetector.record(`remediation-loop-${this.state.runId}`, patchSet, `iter=${i + 1}`);
        if (signal.isStuck) {
          await this.logDecision('remediate', 'stuck-detected',
            `Remediation loop produced a repeating PatchSet signature (occurrences=${signal.occurrences}). Escalating instead of retrying.`,
            `sig=${signal.signatureHash.slice(0, 12)}`);
          // Return last known gate result; caller will mark failed
          return lastGateResult;
        }
      }

      // Run quality gate
      this.state.currentStage = 'gate';
      const gateAgent = this.agents.get('quality-gate-agent')!;
      const qualityGates = await this.loadQualityGates();

      try {
        lastGateResult = await this.executeWithRetry(gateAgent, {
          patchSet,
          qualityThresholds: qualityGates,
        }) as GateResult;

        // If we get here without throwing, gate passed
        return lastGateResult;
      } catch (err) {
        if (err instanceof QualityGateFailure) {
          lastGateResult = err.gateResult;
          await this.logDecision('gate', 'loop_iteration_failed',
            `Remediation loop ${i + 1}/${maxIterations}: gate still failing`,
            err.gateResult.evidence.slice(0, 2).join(' | '));
        } else {
          throw err;
        }
      }
    }

    return lastGateResult;
  }

  // ── Task Graph ────────────────────────────────────────────

  private async buildTaskGraph(): Promise<TaskGraph> {
    // Read task graph from vault architecture note
    try {
      const note = await this.vault.read('architecture/agent-system-design.md');
      const parsed = parseTaskGraphFromMarkdown(note.body);
      if (parsed.nodes.length > 0) {
        console.log(`[ORCHESTRATOR] Loaded task graph from vault: ${parsed.nodes.length} steps`);
        return parsed;
      }
      console.warn(`[ORCHESTRATOR] Task graph table not parseable — using hardcoded fallback. Check memory/architecture/agent-system-design.md format.`);
    } catch (err) {
      console.warn(`[ORCHESTRATOR] Could not read task graph from vault: ${err instanceof Error ? err.message : String(err)}`);
    }

    // Fallback: hardcoded default graph
    console.log(`[ORCHESTRATOR] Using default task graph`);
    const nodes: TaskNode[] = [
      { step: 1, agentId: 'blueprint-analysis-agent', dependsOn: [], onSuccess: 2, onFailure: 'retry', maxRetries: 3, escalateAfterRetries: true },
      { step: 2, agentId: 'code-review-agent', dependsOn: [1], onSuccess: 'next', onFailure: 'retry', maxRetries: 3, escalateAfterRetries: true },
      { step: 3, agentId: 'remediation-agent', dependsOn: [2], onSuccess: 4, onFailure: 'retry', maxRetries: 2, escalateAfterRetries: true },
      { step: 4, agentId: 'quality-gate-agent', dependsOn: [3], onSuccess: 5, onFailure: 3, maxRetries: 2, escalateAfterRetries: true },
      { step: 5, agentId: 'e2e-validation-agent', dependsOn: [4], onSuccess: 6, onFailure: 3, maxRetries: 2, escalateAfterRetries: true },
      { step: 6, agentId: 'deploy-agent', dependsOn: [5], onSuccess: 7, onFailure: 'halt', maxRetries: 1, escalateAfterRetries: true },
      { step: 7, agentId: 'post-deploy-validation-agent', dependsOn: [6], onSuccess: 'complete', onFailure: 'halt', maxRetries: 2, escalateAfterRetries: true },
    ];

    return { nodes, description: 'Blueprint → Review → Remediate → Gate → E2E → Deploy → Post-Deploy' };
  }

  // Task graph parsing delegated to standalone exported function below


  // ── Decision Logging ──────────────────────────────────────

  /** V6: structured observability event (no-op if no logger attached). */
  private logObs(
    category: 'e2e-traces' | 'deploy-logs' | 'gate-results' | 'build-output' | 'router-decisions',
    kind: string,
    data: Record<string, unknown>,
  ): void {
    const obs = this.milestoneContext?.observability;
    if (!obs) return;
    obs.log(category, kind, { source: 'orchestrator', stage: this.state.currentStage, ...data });
  }

  private async logDecision(
    stage: PipelineStage,
    action: string,
    reason: string,
    evidence: string,
  ): Promise<void> {
    const decision: Decision = {
      timestamp: new Date().toISOString(),
      agentId: 'orchestrator',
      stage,
      action,
      reason,
      evidence,
    };

    this.state.decisions.push(decision);
    await this.vault.logDecision(this.state.runId, decision);
  }

  // ── Helpers ───────────────────────────────────────────────

  private getAgentIdForStage(stage: PipelineStage): AgentId | undefined {
    const map: Partial<Record<PipelineStage, AgentId>> = {
      blueprint: 'blueprint-analysis-agent',
      review: 'code-review-agent',
      remediate: 'remediation-agent',
      gate: 'quality-gate-agent',
      audit: 'review-auditor-agent',
      e2e: 'e2e-validation-agent',
      deploy: 'deploy-agent',
      'post-deploy': 'post-deploy-validation-agent',
    };
    return map[stage];
  }

  private createInitialState(trigger: string): PipelineState {
    return {
      runId: uuidv4().substring(0, 8),
      triggeredBy: trigger as PipelineState['triggeredBy'],
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

  /** Save pipeline state to vault after each stage for resume capability. */
  private async saveState(): Promise<void> {
    const serialized = JSON.stringify(this.state, null, 2);
    // Write to run-specific file (history) AND latest pointer (for resume)
    const runPath = `sessions/pipeline-state-${this.state.runId}.json`;
    const latestPath = `sessions/pipeline-state-latest.json`;
    await this.vault.create(runPath, { type: 'pipeline-state', runId: this.state.runId, savedAt: new Date().toISOString() }, serialized);
    await this.vault.create(latestPath, { type: 'pipeline-state-latest', runId: this.state.runId, savedAt: new Date().toISOString() }, serialized);
  }

  /** Load the most recent pipeline state from vault for --from-stage resume. */
  private async loadLastState(trigger: PipelineTrigger): Promise<void> {
    // Read the latest state pointer directly (O(1) instead of walking all files)
    try {
      const latest = await this.vault.read('sessions/pipeline-state-latest.json');
      const parsed = JSON.parse(latest.body) as PipelineState;

      // Preserve the ORIGINAL runId so saveState() updates the same file
      this.state.runId = parsed.runId;
      this.state.convergenceReport = parsed.convergenceReport;
      this.state.reviewResult = parsed.reviewResult;
      this.state.patchSet = parsed.patchSet;
      this.state.gateResult = parsed.gateResult;
      this.state.deployRecord = parsed.deployRecord ?? null;
      this.state.blueprintVersion = parsed.blueprintVersion;
      this.state.decisions = parsed.decisions ?? [];
      this.state.costAccumulator = parsed.costAccumulator ?? [];
      this.state.currentStage = trigger.fromStage ?? parsed.currentStage;

      console.log(`[ORCHESTRATOR] Restored state from run ${parsed.runId} (stage: ${parsed.currentStage}) — resuming at ${this.state.currentStage}`);
    } catch {
      console.log(`[ORCHESTRATOR] No saved state found — starting fresh`);
    }
  }

  private async findSpecPaths(): Promise<string[]> {
    const specDirs = ['docs', 'docs/specs'];
    const results: string[] = [];

    for (const dir of specDirs) {
      try {
        const { readdir } = await import('fs/promises');
        const entries = await readdir(dir);
        for (const entry of entries) {
          if (entry.endsWith('.md') && entry.startsWith('Phase-')) {
            results.push(`${dir}/${entry}`);
          }
        }
      } catch {
        // Directory doesn't exist
      }
    }

    return results;
  }

  private async loadQualityGates(): Promise<QualityGateThresholds> {
    try {
      const note = await this.vault.read('knowledge/quality-gates.md');

      // Parse thresholds from markdown tables — try multiple patterns
      const coverageMatch = note.body.match(/Line coverage\s*\|\s*>=?\s*(\d+)%/i);
      const blockCriticalMatch = note.body.match(/Critical vulnerabilities\s*\|\s*0\s*\|\s*(Yes|No)/i);
      const securityMatch = note.body.match(/## Security Gate/i);

      const minCoverage = coverageMatch ? parseInt(coverageMatch[1]) : 80;
      const blockOnCritical = blockCriticalMatch ? blockCriticalMatch[1].toLowerCase() === 'yes' : true;
      const securityScanEnabled = !!securityMatch;

      console.log(`[ORCHESTRATOR] Quality gates loaded: coverage>=${minCoverage}%, blockOnCritical=${blockOnCritical}`);
      return { minCoverage, blockOnCritical, securityScanEnabled };
    } catch (err) {
      console.log(`[ORCHESTRATOR] quality-gates.md not found, using defaults: ${err instanceof Error ? err.message : ''}`);
      return { minCoverage: 80, blockOnCritical: true, securityScanEnabled: true };
    }
  }

  private async loadDeployConfig(): Promise<{ environment: 'alpha'; target: string; healthEndpoint: string }> {
    try {
      const note = await this.vault.read('knowledge/deploy-config.md');

      // Parse structured fields from markdown tables — capture between pipes, not including trailing pipe
      const serverMatch = note.body.match(/Server\s*\|\s*([^|\n]+)/);
      const deployPathMatch = note.body.match(/Deploy Path\s*\|\s*([^|\n]+)/);
      const healthMatch = note.body.match(/Health Endpoint\s*\|\s*([^|\n]+)/);

      const target = (deployPathMatch?.[1] ?? serverMatch?.[1] ?? '').trim();
      const healthEndpoint = (healthMatch?.[1] ?? '/api/health').trim();

      if (!target) {
        throw new Error('No deploy target found in deploy-config.md (expected "Server" or "Deploy Path" row)');
      }

      console.log(`[ORCHESTRATOR] Deploy config loaded: target=${target}, health=${healthEndpoint}`);
      return { environment: 'alpha', target, healthEndpoint };
    } catch (err) {
      throw new Error(
        `Deploy config missing or invalid: ${err instanceof Error ? err.message : String(err)}. ` +
        `Create memory/knowledge/deploy-config.md with Server and Deploy Path rows.`
      );
    }
  }

  private async loadProjectPaths(): Promise<ProjectPaths> {
    const defaults: ProjectPaths = {
      storyboardsPath: 'design/web/v8/src/_analysis/09-storyboards.md',
      apiContractsPath: 'design/web/v8/src/_analysis/06-api-contracts.md',
      screenStatesPath: 'design/web/v8/src/_analysis/10-screen-state-matrix.md',
      apiSpMapPath: 'design/web/v8/src/_analysis/11-api-to-sp-map.md',
    };

    try {
      const note = await this.vault.read('knowledge/project-paths.md');

      const extract = (key: string): string | undefined => {
        const match = note.body.match(new RegExp(`${key}\\s*\\|\\s*([^|\\n]+)`));
        return match?.[1]?.trim();
      };

      const paths: ProjectPaths = {
        storyboardsPath: extract('storyboardsPath') ?? defaults.storyboardsPath,
        apiContractsPath: extract('apiContractsPath') ?? defaults.apiContractsPath,
        screenStatesPath: extract('screenStatesPath') ?? defaults.screenStatesPath,
        apiSpMapPath: extract('apiSpMapPath') ?? defaults.apiSpMapPath,
      };

      console.log(`[ORCHESTRATOR] Project paths loaded from vault`);
      return paths;
    } catch {
      console.log(`[ORCHESTRATOR] project-paths.md not found, using defaults`);
      return defaults;
    }
  }

  private async getCurrentCommitSha(): Promise<string> {
    const { execFile } = await import('child_process');
    const { promisify } = await import('util');
    try {
      const { stdout } = await promisify(execFile)('git', ['rev-parse', 'HEAD']);
      return stdout.trim();
    } catch {
      return 'unknown';
    }
  }

  private async getMaxRetries(agentId: AgentId): Promise<number> {
    try {
      const note = await this.vault.read(`agents/${agentId}.md`);
      return (note.meta.max_retries as number) ?? 3;
    } catch {
      return 3;
    }
  }

  private async getChangedFiles(): Promise<string[]> {
    const { execFile } = await import('child_process');
    const { promisify } = await import('util');
    try {
      const { stdout } = await promisify(execFile)('git', ['diff', '--name-only', 'HEAD~1']);
      return stdout.trim().split('\n').filter(f => f.length > 0);
    } catch {
      return [];
    }
  }

  private buildFinalSummary(): string {
    const totalCost = this.state.costAccumulator.reduce((sum, e) => sum + e.estimatedCostUsd, 0);
    return [
      `## Pipeline Run Summary`,
      '',
      `| Field | Value |`,
      `|---|---|`,
      `| Run ID | ${this.state.runId} |`,
      `| Status | ${this.state.status} |`,
      `| Trigger | ${this.state.triggeredBy} |`,
      `| Started | ${this.state.startedAt} |`,
      `| Completed | ${this.state.completedAt ?? 'N/A'} |`,
      `| Stages completed | ${this.state.decisions.length} decisions |`,
      `| Estimated cost | $${totalCost.toFixed(2)} |`,
      '',
      `### Decisions`,
      '',
      ...this.state.decisions.map(d =>
        `- **${d.stage}/${d.action}**: ${d.reason}${d.evidence ? ` (${d.evidence})` : ''}`
      ),
    ].join('\n');
  }
}

// ── Standalone task graph parser (exported for testability) ──

/** Parse task graph from the markdown table in an architecture note. */
export function parseTaskGraphFromMarkdown(body: string): TaskGraph {
  // Whitespace-tolerant, case-insensitive table header match
  const tableMatch = body.match(/\|\s*Step\s*\|.*?\n\|[-|\s:]+\n((?:\|.*(?:\n|$))+)/is);
  if (!tableMatch) return { nodes: [], description: '' };

  const rows = tableMatch[1].trim().split('\n');
  const nodes: TaskNode[] = [];

  for (const row of rows) {
    const cells = row.split('|').map(c => c.trim()).filter(c => c.length > 0);
    if (cells.length < 5) {
      console.warn(`[TASK-GRAPH] Skipping malformed row (${cells.length} cells): ${row.substring(0, 80)}`);
      continue;
    }

    const step = parseInt(cells[0]);
    if (isNaN(step)) {
      console.warn(`[TASK-GRAPH] Skipping row with non-numeric step: "${cells[0]}"`);
      continue;
    }

    const agentId = cells[1].toLowerCase().replace(/\s+/g, '-') as AgentId;
    if (!agentId || agentId === ('-' as string)) {
      console.warn(`[TASK-GRAPH] Skipping row ${step} with empty agent ID`);
      continue;
    }

    const dependsOn = cells[2] === '(trigger)' ? [] :
      cells[2].split(',').map(s => parseInt(s.replace(/Step\s*/i, '').trim())).filter(n => !isNaN(n));
    const onSuccessRaw = cells[3].toLowerCase();
    const onFailureRaw = cells[4].toLowerCase();
    const maxRetries = cells.length > 5 ? parseInt(cells[5]) || 3 : 3;

    const onSuccess: 'next' | 'complete' | number =
      onSuccessRaw.includes('complete') ? 'complete' :
      onSuccessRaw.match(/step\s*(\d+)/i) ? parseInt(onSuccessRaw.match(/step\s*(\d+)/i)![1]) :
      'next';

    const onFailure: 'retry' | 'halt' | number =
      onFailureRaw.includes('halt') ? 'halt' :
      onFailureRaw.includes('retry') ? 'retry' :
      onFailureRaw.match(/step\s*(\d+)/i) ? parseInt(onFailureRaw.match(/step\s*(\d+)/i)![1]) :
      'retry';

    nodes.push({ step, agentId, dependsOn, onSuccess, onFailure, maxRetries, escalateAfterRetries: true });
  }

  return { nodes, description: 'Loaded from vault' };
}
