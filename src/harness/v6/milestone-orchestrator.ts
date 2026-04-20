// ═══════════════════════════════════════════════════════════
// GSD V6 — Milestone Orchestrator
// Top-level runner. Wraps SDLC + Pipeline orchestrators inside
// the Milestone → Slice → Task hierarchy, with SQLite state,
// worktree isolation, budget routing, and auto-lock.
// ═══════════════════════════════════════════════════════════

import * as path from 'path';
import * as fs from 'fs';
import { v4 as uuidv4 } from 'uuid';

import { StateDB } from './state-db';
import { WorktreeManager } from './worktree-manager';
import { AutoLock } from './auto-lock';
import { BudgetRouter } from './budget-router';
import { ObservabilityLogger } from './observability-logger';
import { CapabilityEscalator, isCapabilityGap } from './capability-escalation';
import { SlicePlanner } from './slice-planner';
import { validateStackLeaks, formatStackLeakReport } from './stack-leak-validator';
import { getProjectStackContext } from '../project-stack-context';
import type {
  Milestone,
  MilestoneId,
  MilestoneStatus,
  Slice,
  SliceId,
  SliceStatus,
} from './types';
import type { SdlcOrchestrator } from '../sdlc-orchestrator';
import type { Orchestrator } from '../orchestrator';
import type { PipelineState, PipelineStage, TriggerType } from '../types';
import type { SdlcPhase } from '../sdlc-types';

export interface MilestoneOrchestratorOptions {
  vaultPath: string;                // default: ./memory
  parentRepoPath?: string;          // default: cwd
  budgetUsd?: number;                // default: 10 (generous, dev budget)
  useWorktree?: boolean;             // default: auto-detect (true if parentRepoPath is git repo)
  baseBranch?: string;               // default: 'main'
  observabilityRoot?: string;        // default: <vaultPath>/observability
}

export interface MilestoneRunInput {
  milestoneName: string;
  description: string;
  trigger: TriggerType;
  // SDLC inputs
  sdlcFromPhase?: SdlcPhase;
  sdlcToPhase?: SdlcPhase;
  projectName?: string;
  projectDescription?: string;
  designPath?: string;
  review?: boolean;
  // Pipeline inputs
  pipelineFromStage?: PipelineStage;
  dryRun?: boolean;
}

export interface MilestoneRunResult {
  milestoneId: MilestoneId;
  runId: string;
  status: MilestoneStatus;
  sliceResults: Array<{ sliceId: SliceId; status: SliceStatus; error?: string }>;
  totalCostUsd: number;
  durationMs: number;
  pipelineState?: PipelineState;
  sdlcStatus?: string;
  error?: string;
}

export class MilestoneOrchestrator {
  private opts: Required<Omit<MilestoneOrchestratorOptions, 'parentRepoPath' | 'observabilityRoot'>> & {
    parentRepoPath: string;
    observabilityRoot: string;
  };
  private db: StateDB;
  private worktreeManager: WorktreeManager | null;
  private autoLock: AutoLock;
  private budgetRouter: BudgetRouter;
  private observability: ObservabilityLogger | null = null;

  constructor(opts: MilestoneOrchestratorOptions) {
    this.opts = {
      vaultPath: opts.vaultPath,
      parentRepoPath: opts.parentRepoPath ?? process.cwd(),
      budgetUsd: opts.budgetUsd ?? 10,
      useWorktree: opts.useWorktree ?? false,
      baseBranch: opts.baseBranch ?? 'main',
      observabilityRoot: opts.observabilityRoot ?? path.join(opts.vaultPath, 'observability'),
    };

    const dbPath = path.join(this.opts.vaultPath, 'state.db');
    this.db = new StateDB(dbPath);

    this.worktreeManager = this.opts.useWorktree
      ? new WorktreeManager(this.db, { parentRepoPath: this.opts.parentRepoPath })
      : null;

    this.autoLock = new AutoLock(path.join(this.opts.vaultPath, 'state.db.lock'));
    this.budgetRouter = new BudgetRouter({ budgetUsd: this.opts.budgetUsd, spentUsd: 0 });
  }

  get db_(): StateDB { return this.db; }
  get worktreeManager_(): WorktreeManager | null { return this.worktreeManager; }

  close(): void {
    this.autoLock.release();
    this.db.close();
  }

  /**
   * Full V6 milestone run. Preserves existing SDLC+Pipeline behavior as a
   * single default slice, but now wrapped in SQLite state + worktree + budget.
   */
  async run(
    input: MilestoneRunInput,
    sdlcOrchestratorFactory: () => SdlcOrchestrator,
    pipelineOrchestratorFactory: () => Orchestrator,
  ): Promise<MilestoneRunResult> {
    const runId = uuidv4();
    const milestoneId = `M${Date.now().toString(36).slice(-6).toUpperCase()}`;
    const now = new Date().toISOString();
    const start = Date.now();

    // Acquire lock
    try {
      this.autoLock.acquire(runId);
    } catch (e) {
      const stale = this.autoLock.inspect();
      return {
        milestoneId,
        runId,
        status: 'failed',
        sliceResults: [],
        totalCostUsd: 0,
        durationMs: Date.now() - start,
        error: `lock held: ${(e as Error).message} (stale=${stale?.staleMinutes.toFixed(1) ?? 'unknown'}min)`,
      };
    }

    this.observability = new ObservabilityLogger(this.opts.observabilityRoot, runId);

    // Create milestone in SQLite
    const milestone: Milestone = {
      id: milestoneId,
      name: input.milestoneName,
      description: input.description,
      status: 'running',
      startedAt: now,
      completedAt: null,
      budgetUsd: this.opts.budgetUsd,
      spentUsd: 0,
      worktreePath: null,
      parentRepoPath: this.opts.parentRepoPath,
    };
    this.db.createMilestone(milestone);
    this.observability.log('router-decisions', 'milestone-start', {
      milestoneId,
      runId,
      budgetUsd: this.opts.budgetUsd,
      useWorktree: this.opts.useWorktree,
    });

    // Optional: create worktree
    if (this.worktreeManager) {
      try {
        const wt = await this.worktreeManager.create(milestoneId, this.opts.baseBranch);
        this.observability.log('router-decisions', 'worktree-created', {
          milestoneId,
          path: wt.path,
          branch: wt.branch,
        });
      } catch (e) {
        this.observability.log('router-decisions', 'worktree-skipped', {
          milestoneId,
          reason: (e as Error).message,
        });
        // Continue without worktree
      }
    }

    // V6: plan slices from roadmap if present; else single default slice
    const plan = SlicePlanner.plan({
      milestoneId,
      vaultPath: this.opts.vaultPath,
      milestoneName: input.milestoneName,
      description: input.description,
    });
    for (const s of plan.slices) {
      this.db.createSlice({ ...s, status: 'pending' });
    }
    this.observability.log('router-decisions', 'slice-plan', {
      milestoneId,
      source: plan.source,
      sliceCount: plan.slices.length,
      slices: plan.slices.map((s) => ({ id: s.id, name: s.name, dependsOn: s.dependsOnSliceIds })),
    });

    // MVP: execute slices sequentially in plan order. Dep-aware parallel
    // execution uses ExecutionGraph.runGraph once slice-level tasks are split.
    const sliceId: SliceId = plan.slices[0].id;
    this.db.updateSliceStatus(sliceId, 'running', { startedAt: now });

    const result: MilestoneRunResult = {
      milestoneId,
      runId,
      status: 'running',
      sliceResults: [],
      totalCostUsd: 0,
      durationMs: 0,
    };

    try {
      // Execute SDLC phases if requested
      if (input.sdlcFromPhase) {
        const sdlc = sdlcOrchestratorFactory();
        // v6.1.0: SdlcOrchestrator constructor now takes projectRoot; factory
        // instantiates it with the milestone's parentRepoPath, which is the
        // authoritative "target project root" for stack-overrides resolution.
        await sdlc.initialize();
        const sdlcTrigger: 'manual' | 'schedule' = input.trigger === 'webhook' ? 'manual' : input.trigger;
        const sdlcResult = await sdlc.run({
          trigger: sdlcTrigger,
          fromPhase: input.sdlcFromPhase,
          projectName: input.projectName ?? 'Untitled',
          projectDescription: input.projectDescription ?? '',
          designPath: input.designPath,
          vaultPath: this.opts.vaultPath,
          review: input.review,
        });
        result.sdlcStatus = sdlcResult.status;
        this.observability.log('router-decisions', 'sdlc-complete', {
          milestoneId,
          status: sdlcResult.status,
          phase: sdlcResult.currentPhase,
        });
        if (sdlcResult.status === 'failed') {
          throw new Error(`SDLC failed at phase ${sdlcResult.currentPhase}`);
        }

        // v6.1.0: stack-leak validation over generated artifacts (docs/sdlc/, docs/spec/)
        try {
          const stackCtx = await getProjectStackContext(this.opts.parentRepoPath);
          const leakReport = await validateStackLeaks({
            projectRoot: this.opts.parentRepoPath,
            context: stackCtx,
            scanPatterns: ['.csproj', '.json', '.md', '.yaml', '.yml', '.xml'],
          });
          this.observability?.log('gate-results', 'stack-leak-report', {
            filesScanned: leakReport.filesScanned,
            filesMatched: leakReport.filesMatched,
            findingsCount: leakReport.findings.length,
            contextSource: leakReport.contextSource,
            expectedFramework: leakReport.contextBackendFramework,
          });
          if (leakReport.findings.length > 0) {
            this.db.recordDecision({
              milestoneId,
              sliceId,
              timestamp: new Date().toISOString(),
              action: 'stack-leak-detected',
              reason: `${leakReport.findings.length} stack-layer leak(s) in generated artifacts (expected ${leakReport.contextBackendFramework})`,
              evidence: formatStackLeakReport(leakReport).slice(0, 4000),
            });
            console.warn(`[MILESTONE] Stack leak validator found ${leakReport.findings.length} finding(s). See decision log.`);
          }
        } catch (e) {
          // Validator is best-effort post-phase check; do not fail the milestone on validator error
          this.observability?.log('gate-results', 'stack-leak-error', { error: (e as Error).message });
        }
      }

      // Execute Pipeline stages if requested
      if (input.pipelineFromStage) {
        const pipeline = pipelineOrchestratorFactory();
        // V6: thread milestone context BEFORE initialize so agents get it
        pipeline.setMilestoneContext({
          observability: this.observability,
          budgetRouter: this.budgetRouter,
          runId,
          compactedOutputDir: path.join(this.opts.observabilityRoot, 'raw'),
        });
        await pipeline.initialize();
        const pipelineState = await pipeline.run({
          trigger: input.trigger,
          fromStage: input.pipelineFromStage,
          dryRun: input.dryRun,
          vaultPath: this.opts.vaultPath,
        });

        // V6: scan decisions and any returned state for capability gaps
        const escalator = new CapabilityEscalator(this.db, milestoneId, this.observability);
        for (const decision of pipelineState.decisions) {
          if (isCapabilityGap(decision.evidence)) {
            const outcome = escalator.handle(decision.evidence, sliceId);
            this.observability?.log('router-decisions', 'capability-escalated', { decision: decision.action, outcome });
          }
        }
        result.pipelineState = pipelineState;
        const cost = pipelineState.costAccumulator.reduce((s, e) => s + e.estimatedCostUsd, 0);
        result.totalCostUsd += cost;
        this.db.addMilestoneSpend(milestoneId, cost);
        this.budgetRouter.updateSpend(this.db.getMilestone(milestoneId)?.spentUsd ?? 0);
        this.observability.log('router-decisions', 'pipeline-complete', {
          milestoneId,
          status: pipelineState.status,
          stage: pipelineState.currentStage,
          cost,
          budgetStatus: this.budgetRouter.status,
        });
        if (pipelineState.status === 'failed') {
          throw new Error(`Pipeline failed at stage ${pipelineState.currentStage}`);
        }
      }

      // Slice succeeded
      this.db.updateSliceStatus(sliceId, 'complete', { completedAt: new Date().toISOString() });
      result.sliceResults.push({ sliceId, status: 'complete' });

      // Milestone succeeded
      this.db.updateMilestoneStatus(milestoneId, 'complete', new Date().toISOString());
      result.status = 'complete';

      this.db.recordDecision({
        milestoneId,
        sliceId,
        timestamp: new Date().toISOString(),
        action: 'milestone-complete',
        reason: 'all stages succeeded',
        evidence: `runId=${runId} cost=$${result.totalCostUsd.toFixed(4)}`,
      });
    } catch (err) {
      const errMsg = (err as Error).message;
      this.db.updateSliceStatus(sliceId, 'failed', { completedAt: new Date().toISOString() });
      this.db.updateMilestoneStatus(milestoneId, 'failed', new Date().toISOString());
      result.sliceResults.push({ sliceId, status: 'failed', error: errMsg });
      result.status = 'failed';
      result.error = errMsg;
      this.db.recordDecision({
        milestoneId,
        sliceId,
        timestamp: new Date().toISOString(),
        action: 'milestone-failed',
        reason: errMsg,
        evidence: `runId=${runId}`,
      });
      this.observability?.log('router-decisions', 'milestone-failed', { milestoneId, error: errMsg });
    } finally {
      result.durationMs = Date.now() - start;
      // Persist markdown narrative file
      await this.writeMilestoneRoadmap(milestoneId, input, result);
      this.autoLock.release();
    }

    return result;
  }

  private async writeMilestoneRoadmap(
    milestoneId: MilestoneId,
    input: MilestoneRunInput,
    result: MilestoneRunResult,
  ): Promise<void> {
    const dir = path.join(this.opts.vaultPath, 'milestones', milestoneId);
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    const roadmap = [
      `---`,
      `type: milestone`,
      `id: ${milestoneId}`,
      `name: ${input.milestoneName}`,
      `status: ${result.status}`,
      `run_id: ${result.runId}`,
      `cost_usd: ${result.totalCostUsd}`,
      `duration_ms: ${result.durationMs}`,
      `---`,
      ``,
      `# Milestone ${milestoneId}: ${input.milestoneName}`,
      ``,
      `## Description`,
      input.description,
      ``,
      `## Slices`,
      ...result.sliceResults.map((s) => `- ${s.sliceId}: ${s.status}${s.error ? ` — ${s.error}` : ''}`),
      ``,
      `## Status`,
      `- ${result.status}`,
      result.error ? `- Error: ${result.error}` : '',
    ].join('\n');
    fs.writeFileSync(path.join(dir, 'ROADMAP.md'), roadmap, 'utf8');
  }
}
