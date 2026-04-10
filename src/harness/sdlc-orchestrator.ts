// ═══════════════════════════════════════════════════════════
// GSD Agent System — SDLC Orchestrator
// Orchestrates Phases A-E of the Technijian SDLC v6.0,
// then hands off to the Pipeline Orchestrator (Phases F-G).
// ═══════════════════════════════════════════════════════════

import { v4 as uuidv4 } from 'uuid';
import * as fs from 'fs/promises';
import * as path from 'path';
import type {
  SdlcPhase,
  SdlcState,
  SdlcStatus,
  SdlcTrigger,
  IntakePack,
  ArchitecturePack,
  FigmaDeliverables,
  ReconciliationReport,
  FrozenBlueprint,
  ContractArtifacts,
} from './sdlc-types';
import { VaultAdapter } from './vault-adapter';
import { HookSystem } from './hooks';
import { RateLimiter } from './rate-limiter';
import { registerDefaultHooks } from './default-hooks';
import { BaseAgent } from './base-agent';
import { Orchestrator } from './orchestrator';

// Agent imports
import { RequirementsAgent } from '../agents/requirements-agent';
import { ArchitectureAgent } from '../agents/architecture-agent';
import { FigmaIntegrationAgent } from '../agents/figma-integration-agent';
import { PhaseReconcileAgent } from '../agents/phase-reconcile-agent';
import { BlueprintFreezeAgent } from '../agents/blueprint-freeze-agent';
import { ContractFreezeAgent } from '../agents/contract-freeze-agent';

/**
 * Phase-to-model routing for SDLC phases.
 * Uses PHASE_ROUTING style: primary → fallback.
 */
const SDLC_PHASE_ROUTING: Record<string, string[]> = {
  'phase-a':           ['claude', 'gemini'],      // Requirements need deep reasoning
  'phase-b':           ['claude', 'codex'],        // Architecture needs deep reasoning
  'phase-c':           ['codex', 'gemini'],         // File validation, minimal LLM
  'phase-ab-reconcile': ['claude', 'gemini'],      // Document comparison
  'phase-d':           ['gemini', 'claude'],        // Large context synthesis
  'phase-e':           ['codex', 'claude'],          // Structured output generation
};

const SDLC_PHASE_ORDER: SdlcPhase[] = [
  'phase-a', 'phase-b', 'phase-c', 'phase-ab-reconcile', 'phase-d', 'phase-e', 'pipeline',
];

export class SdlcOrchestrator {
  private agents = new Map<string, BaseAgent>();
  private vault: VaultAdapter;
  private hooks: HookSystem;
  private rateLimiter: RateLimiter;
  private pipelineOrchestrator: Orchestrator;
  state: SdlcState;

  constructor(vaultPath: string) {
    this.vault = new VaultAdapter(vaultPath);
    this.hooks = new HookSystem();
    this.rateLimiter = new RateLimiter(0.8);
    this.pipelineOrchestrator = new Orchestrator(vaultPath);
    this.state = this.createInitialState();
  }

  async initialize(): Promise<void> {
    // Register hooks and rate limits (shared with pipeline)
    registerDefaultHooks(this.hooks, this.vault, () => ({
      runId: this.state.sdlcRunId,
      triggeredBy: 'manual' as const,
      blueprintVersion: '0.0.0',
      convergenceReport: null,
      reviewResult: null,
      patchSet: null,
      gateResult: null,
      deployRecord: null,
      decisions: [],
      currentStage: 'blueprint' as const,
      status: 'running' as const,
      costAccumulator: [],
      startedAt: this.state.startedAt,
      completedAt: null,
    }));

    this.rateLimiter.registerAgent('claude', { rpm: 10, cooldownMs: 5 * 60_000, safetyFactor: 0.8 });
    this.rateLimiter.registerAgent('codex',  { rpm: 10, cooldownMs: 5 * 60_000, safetyFactor: 0.8 });
    this.rateLimiter.registerAgent('gemini', { rpm: 15, cooldownMs: 5 * 60_000, safetyFactor: 0.8 });

    // Instantiate SDLC agents
    const agentDefs: Array<[string, new (...args: ConstructorParameters<typeof BaseAgent>) => BaseAgent]> = [
      ['requirements-agent', RequirementsAgent],
      ['architecture-agent', ArchitectureAgent],
      ['figma-integration-agent', FigmaIntegrationAgent],
      ['phase-reconcile-agent', PhaseReconcileAgent],
      ['blueprint-freeze-agent', BlueprintFreezeAgent],
      ['contract-freeze-agent', ContractFreezeAgent],
    ];

    for (const [id, AgentClass] of agentDefs) {
      const agent = new (AgentClass as new (...args: unknown[]) => BaseAgent)(id, this.vault, this.hooks, {});
      await agent.initialize();
      agent.setRateLimiter(this.rateLimiter, 'claude');
      this.agents.set(id, agent);
    }

    // Initialize pipeline orchestrator for Phase F-G handoff
    await this.pipelineOrchestrator.initialize();

    console.log(`[SDLC] Initialized ${this.agents.size} SDLC agents + pipeline orchestrator`);
  }

  async run(trigger: SdlcTrigger): Promise<SdlcState> {
    // If resuming, load prior state from vault
    const startPhase = trigger.fromPhase ?? 'phase-a';
    if (startPhase !== 'phase-a') {
      await this.loadLastState();
      if (this.state.sdlcRunId) {
        console.log(`[SDLC] Resumed from saved state (run ${this.state.sdlcRunId})`);
      }
    } else {
      this.state = this.createInitialState();
    }

    if (!this.state.sdlcRunId) {
      this.state.sdlcRunId = uuidv4().substring(0, 8);
    }
    this.state.startedAt = this.state.startedAt || new Date().toISOString();

    const startIdx = SDLC_PHASE_ORDER.indexOf(startPhase);
    console.log(`\n[SDLC] Starting from phase: ${startPhase}`);

    for (let i = startIdx; i < SDLC_PHASE_ORDER.length; i++) {
      const phase = SDLC_PHASE_ORDER[i];
      this.state.currentPhase = phase;
      this.state.status = 'running';

      // Pick best available CLI model for this phase
      const candidates = SDLC_PHASE_ROUTING[phase] ?? ['claude', 'codex', 'gemini'];
      const cliModel = this.rateLimiter.pickAvailable(candidates) ?? candidates[0];
      this.rateLimiter.trackModelSwitch(phase, cliModel);

      // Update the active agent's rate limiter
      const agentId = this.getAgentIdForPhase(phase);
      if (agentId) {
        const agent = this.agents.get(agentId);
        if (agent) agent.setRateLimiter(this.rateLimiter, cliModel);
      }

      console.log(`\n[SDLC] Phase: ${phase} | Model: ${cliModel}`);

      try {
        if (phase === 'pipeline') {
          // Hand off to existing v4.1 pipeline
          console.log(`[SDLC] Handing off to Pipeline Orchestrator (Phases F-G)...`);
          const pipelineResult = await this.pipelineOrchestrator.run({
            trigger: trigger.trigger,
            vaultPath: trigger.vaultPath,
          });
          this.state.status = pipelineResult.status === 'complete' ? 'complete' : 'failed';
        } else {
          await this.executePhase(phase, trigger);
        }

        await this.saveState();
        this.logDecision(phase, 'complete', `Phase ${phase} completed successfully`);

        // Human review gate — pause after each phase if --review flag set
        if (trigger.review && phase !== 'pipeline') {
          console.log(`\n[SDLC] ═══ REVIEW GATE ═══`);
          console.log(`[SDLC] Phase ${phase} output saved to docs/sdlc/`);
          console.log(`[SDLC] Review the artifacts, then resume with:`);
          console.log(`[SDLC]   gsd run <next-milestone>`);
          console.log(`[SDLC] ════════════════════\n`);
          this.state.status = 'paused';
          await this.saveState();
          break; // Exit the phase loop — user resumes manually
        }
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        console.error(`[SDLC] Phase ${phase} failed: ${msg}`);
        this.logDecision(phase, 'failed', msg);
        this.state.status = 'failed';
        await this.saveState();
        break;
      }
    }

    this.state.completedAt = new Date().toISOString();
    await this.saveState();
    return this.state;
  }

  private async executePhase(phase: SdlcPhase, trigger: SdlcTrigger): Promise<void> {
    switch (phase) {
      case 'phase-a': {
        const agent = this.agents.get('requirements-agent')!;
        const result = await agent.execute({
          projectName: trigger.projectName,
          projectDescription: trigger.projectDescription,
        }) as unknown as IntakePack;
        this.state.intakePack = result;
        await this.writeArtifact('docs/sdlc/phase-a-intake-pack.json', result);
        break;
      }

      case 'phase-b': {
        if (!this.state.intakePack) throw new Error('Phase B requires Phase A output (IntakePack)');
        const agent = this.agents.get('architecture-agent')!;
        const result = await agent.execute({
          intakePack: this.state.intakePack,
        }) as unknown as ArchitecturePack;
        this.state.architecturePack = result;
        await this.writeArtifact('docs/sdlc/phase-b-architecture-pack.json', result);
        // Write OpenAPI draft as separate file if present
        if (result.openApiDraft) {
          await this.writeArtifactRaw('docs/sdlc/openapi-draft.yaml', result.openApiDraft as string);
        }
        break;
      }

      case 'phase-c': {
        const agent = this.agents.get('figma-integration-agent')!;
        const result = await agent.execute({
          designPath: trigger.designPath ?? 'design/web/v1/src/',
          architecturePack: this.state.architecturePack,
        }) as unknown as FigmaDeliverables;
        this.state.figmaDeliverables = result;

        if (result.completeness < 12) {
          console.warn(`[SDLC] Figma deliverables incomplete: ${result.completeness}/12. Run Figma Make generation first.`);
        }
        break;
      }

      case 'phase-ab-reconcile': {
        if (!this.state.intakePack || !this.state.architecturePack || !this.state.figmaDeliverables) {
          throw new Error('Phase AB-Reconcile requires Phase A, B, and C outputs');
        }
        const agent = this.agents.get('phase-reconcile-agent')!;
        const result = await agent.execute({
          intakePack: this.state.intakePack,
          architecturePack: this.state.architecturePack,
          figmaDeliverables: this.state.figmaDeliverables,
        }) as unknown as ReconciliationReport;
        this.state.reconciliationReport = result;
        this.state.intakePack = result.updatedIntakePack;
        this.state.architecturePack = result.updatedArchitecturePack;
        await this.writeArtifact('docs/sdlc/phase-ab-reconciliation-report.json', result);
        // Overwrite Phase A/B with reconciled versions
        await this.writeArtifact('docs/sdlc/phase-a-intake-pack.json', result.updatedIntakePack);
        await this.writeArtifact('docs/sdlc/phase-b-architecture-pack.json', result.updatedArchitecturePack);
        break;
      }

      case 'phase-d': {
        if (!this.state.figmaDeliverables) throw new Error('Phase D requires Phase C output');
        const agent = this.agents.get('blueprint-freeze-agent')!;
        const result = await agent.execute({
          intakePack: this.state.intakePack,
          architecturePack: this.state.architecturePack,
          figmaDeliverables: this.state.figmaDeliverables,
          reconciliationReport: this.state.reconciliationReport,
        }) as unknown as FrozenBlueprint;
        this.state.frozenBlueprint = result;
        await this.writeArtifact('docs/sdlc/phase-d-frozen-blueprint.json', result);
        break;
      }

      case 'phase-e': {
        if (!this.state.frozenBlueprint) throw new Error('Phase E requires Phase D output (Frozen Blueprint)');
        const agent = this.agents.get('contract-freeze-agent')!;
        const result = await agent.execute({
          frozenBlueprint: this.state.frozenBlueprint,
          architecturePack: this.state.architecturePack,
          figmaDeliverables: this.state.figmaDeliverables,
        }) as unknown as ContractArtifacts;
        this.state.contractArtifacts = result;
        await this.writeArtifact('docs/sdlc/phase-e-contract-artifacts.json', result);
        // Write validation report as readable markdown
        const gapReport = [
          '# SCG1 Validation Report',
          '',
          `**Status:** ${result.scg1Passed ? 'PASSED' : 'FAILED'}`,
          `**Routes:** ${result.routes} | **Endpoints:** ${result.endpoints} | **SPs:** ${result.storedProcedures}`,
          '',
          '## Gaps',
          '',
          ...(result.gaps as Array<{id: string; layer: string; issue: string; action: string}>).map(
            (g) => `- **${g.id}** [${g.layer}]: ${g.issue} — Action: ${g.action}`
          ),
          result.gaps.length === 0 ? '- None' : '',
        ].join('\n');
        await this.writeArtifactRaw('docs/spec/validation-report.md', gapReport);

        if (!result.scg1Passed) {
          console.warn(`[SDLC] SCG1 gate has ${result.gaps.length} gaps. Review docs/spec/validation-report.md before proceeding.`);
        }
        break;
      }
    }
  }

  private getAgentIdForPhase(phase: SdlcPhase): string | undefined {
    const map: Partial<Record<SdlcPhase, string>> = {
      'phase-a': 'requirements-agent',
      'phase-b': 'architecture-agent',
      'phase-c': 'figma-integration-agent',
      'phase-ab-reconcile': 'phase-reconcile-agent',
      'phase-d': 'blueprint-freeze-agent',
      'phase-e': 'contract-freeze-agent',
    };
    return map[phase];
  }

  /** Write a JSON artifact to disk (creates parent directories). */
  private async writeArtifact(relativePath: string, data: unknown): Promise<void> {
    try {
      const fullPath = path.resolve(relativePath);
      await fs.mkdir(path.dirname(fullPath), { recursive: true });
      await fs.writeFile(fullPath, JSON.stringify(data, null, 2), 'utf-8');
      console.log(`[SDLC] Wrote artifact: ${relativePath}`);
    } catch (err) {
      console.warn(`[SDLC] Failed to write artifact ${relativePath}: ${err instanceof Error ? err.message : String(err)}`);
    }
  }

  /** Write a raw string artifact to disk. */
  private async writeArtifactRaw(relativePath: string, content: string): Promise<void> {
    try {
      const fullPath = path.resolve(relativePath);
      await fs.mkdir(path.dirname(fullPath), { recursive: true });
      await fs.writeFile(fullPath, content, 'utf-8');
      console.log(`[SDLC] Wrote artifact: ${relativePath}`);
    } catch (err) {
      console.warn(`[SDLC] Failed to write artifact ${relativePath}: ${err instanceof Error ? err.message : String(err)}`);
    }
  }

  private logDecision(phase: string, action: string, reason: string): void {
    this.state.decisions.push({
      phase,
      action,
      reason,
      timestamp: new Date().toISOString(),
    });
  }

  private async saveState(): Promise<void> {
    const stateJson = JSON.stringify(this.state, null, 2);
    try {
      // Save run-specific state
      await this.vault.create(`sessions/sdlc-state-${this.state.sdlcRunId}.json`, {
        type: 'sdlc-state',
        description: `SDLC run ${this.state.sdlcRunId}`,
      }, stateJson);
      // Save latest pointer for resume
      await this.vault.create(`sessions/sdlc-state-latest.json`, {
        type: 'sdlc-state',
        description: 'Latest SDLC state for resume',
      }, stateJson);
    } catch { /* state save is best-effort */ }
  }

  private async loadLastState(): Promise<void> {
    try {
      const note = await this.vault.read('sessions/sdlc-state-latest.json');
      const parsed = JSON.parse(note.body) as SdlcState;
      this.state.sdlcRunId = parsed.sdlcRunId;
      this.state.intakePack = parsed.intakePack;
      this.state.architecturePack = parsed.architecturePack;
      this.state.figmaDeliverables = parsed.figmaDeliverables;
      this.state.reconciliationReport = parsed.reconciliationReport;
      this.state.frozenBlueprint = parsed.frozenBlueprint;
      this.state.contractArtifacts = parsed.contractArtifacts;
      this.state.decisions = parsed.decisions ?? [];
      this.state.costAccumulator = parsed.costAccumulator ?? [];
      this.state.startedAt = parsed.startedAt;
    } catch {
      console.log('[SDLC] No prior state found — starting fresh');
    }
  }

  /** Get current state for status reporting */
  getStatus(): { phase: SdlcPhase; status: SdlcStatus; completed: string[]; next: string | null } {
    const currentIdx = SDLC_PHASE_ORDER.indexOf(this.state.currentPhase);
    const completed = SDLC_PHASE_ORDER.slice(0, currentIdx).filter(p => {
      switch (p) {
        case 'phase-a': return !!this.state.intakePack;
        case 'phase-b': return !!this.state.architecturePack;
        case 'phase-c': return !!this.state.figmaDeliverables;
        case 'phase-ab-reconcile': return !!this.state.reconciliationReport;
        case 'phase-d': return !!this.state.frozenBlueprint;
        case 'phase-e': return !!this.state.contractArtifacts;
        default: return false;
      }
    });
    const next = currentIdx < SDLC_PHASE_ORDER.length - 1 ? SDLC_PHASE_ORDER[currentIdx + 1] : null;
    return { phase: this.state.currentPhase, status: this.state.status, completed, next };
  }

  private createInitialState(): SdlcState {
    return {
      sdlcRunId: '',
      currentPhase: 'phase-a',
      status: 'pending',
      intakePack: null,
      architecturePack: null,
      figmaDeliverables: null,
      reconciliationReport: null,
      frozenBlueprint: null,
      contractArtifacts: null,
      decisions: [],
      costAccumulator: [],
      startedAt: new Date().toISOString(),
      completedAt: null,
    };
  }
}
