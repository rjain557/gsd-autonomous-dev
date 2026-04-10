// ═══════════════════════════════════════════════════════════
// GSD Agent System — Types & Schemas
// All types used across the multi-agent pipeline harness.
// NO implementation — types only.
// ═══════════════════════════════════════════════════════════

// ── Agent Identity ──────────────────────────────────────────

export type AgentId =
  | 'orchestrator'
  | 'blueprint-analysis-agent'
  | 'code-review-agent'
  | 'remediation-agent'
  | 'quality-gate-agent'
  | 'e2e-validation-agent'
  | 'post-deploy-validation-agent'
  | 'deploy-agent';

export type PipelineStage =
  | 'blueprint'
  | 'review'
  | 'remediate'
  | 'e2e'
  | 'post-deploy'
  | 'gate'
  | 'deploy'
  | 'complete';

export type PipelineStatus = 'running' | 'paused' | 'failed' | 'complete';
export type TriggerType = 'manual' | 'schedule' | 'webhook';
export type RiskLevel = 'low' | 'medium' | 'high';
export type Severity = 'low' | 'medium' | 'high' | 'critical';
export type IssueCategory = 'correctness' | 'security' | 'style' | 'coverage' | 'convergence' | 'design';

// ── Agent I/O Base ──────────────────────────────────────────

export interface AgentInput {
  [key: string]: unknown;
}

export interface AgentOutput {
  [key: string]: unknown;
}

// ── Pipeline State ──────────────────────────────────────────

export interface PipelineState {
  runId: string;
  triggeredBy: TriggerType;
  blueprintVersion: string;
  convergenceReport: ConvergenceReport | null;
  reviewResult: ReviewResult | null;
  patchSet: PatchSet | null;
  gateResult: GateResult | null;
  deployRecord: DeployRecord | null;
  decisions: Decision[];
  currentStage: PipelineStage;
  status: PipelineStatus;
  costAccumulator: CostEntry[];
  startedAt: string;
  completedAt: string | null;
}

// ── Blueprint Analysis ──────────────────────────────────────

export interface BlueprintAnalysisInput extends AgentInput {
  blueprintPath: string;
  specPaths: string[];
  repoRoot: string;
}

export interface DriftItem {
  requirementId: string;
  expected: string;
  actual: string;
  severity: Severity;
}

export interface ConvergenceReport extends AgentOutput {
  aligned: string[];
  drifted: DriftItem[];
  missing: string[];
  riskLevel: RiskLevel;
}

// ── Code Review ─────────────────────────────────────────────

export interface CodeReviewInput extends AgentInput {
  convergenceReport: ConvergenceReport;
  changedFiles: string[];
  qualityGates: QualityGateThresholds;
}

export interface Issue {
  id: string;
  file: string;
  line: number;
  severity: Severity;
  category: IssueCategory;
  message: string;
  suggestedFix?: string;
}

export interface ReviewResult extends AgentOutput {
  passed: boolean;
  issues: Issue[];
  coveragePercent: number;
  securityFlags: string[];
}

// ── Remediation ─────────────────────────────────────────────

export interface RemediationInput extends AgentInput {
  reviewResult: ReviewResult;
  repoRoot: string;
}

export interface Patch {
  file: string;
  issueId: string;
  diff: string;
  description: string;
}

export interface PatchSet extends AgentOutput {
  patches: Patch[];
  testsPassed: boolean;
}

// ── Quality Gate ────────────────────────────────────────────

export interface QualityGateInput extends AgentInput {
  patchSet: PatchSet;
  qualityThresholds: QualityGateThresholds;
}

export interface QualityGateThresholds {
  minCoverage: number;
  blockOnCritical: boolean;
  securityScanEnabled: boolean;
}

export interface GateResult extends AgentOutput {
  passed: boolean;
  coverage: number;
  securityScore: number;
  evidence: string[];
}

// ── Deploy ──────────────────────────────────────────────────

export interface DeployInput extends AgentInput {
  gateResult: GateResult;
  deployConfig: DeployConfig;
  commitSha: string;
}

export interface DeployConfig {
  environment: 'alpha' | 'staging' | 'production';
  target: string;
  healthEndpoint: string;
}

export interface ProjectPaths {
  storyboardsPath: string;
  apiContractsPath: string;
  screenStatesPath: string;
  apiSpMapPath: string;
}

export interface StepResult {
  name: string;
  success: boolean;
  output: string;
  durationMs: number;
}

export interface DeployRecord extends AgentOutput {
  success: boolean;
  environment: string;
  commitSha: string;
  deployedAt: string;
  steps: StepResult[];
  rollbackExecuted: boolean;
}

// ── Orchestrator ────────────────────────────────────────────

export interface PipelineTrigger {
  trigger: TriggerType;
  fromStage?: PipelineStage;
  dryRun?: boolean;
  vaultPath: string;
}

export interface Decision {
  timestamp: string;
  agentId: AgentId;
  stage: PipelineStage;
  action: string;
  reason: string;
  evidence: string;
}

export interface CostEntry {
  agentId: AgentId;
  stage: PipelineStage;
  inputTokens: number;
  outputTokens: number;
  estimatedCostUsd: number;
}

// ── Hook System ─────────────────────────────────────────────

export type HookEvent =
  | 'onBeforeRun'
  | 'onAfterRun'
  | 'onError'
  | 'onRetry'
  | 'onVaultWrite'
  | 'onDeployStart'
  | 'onDeployComplete'
  | 'onDeployRollback';

export interface HookContext {
  runId: string;
  agentId?: AgentId;
  stage?: PipelineStage;
  input?: AgentInput;
  output?: AgentOutput;
  error?: Error;
  attempt?: number;
  state?: PipelineState;
  durationMs?: number;
  cliModel?: string;
  path?: string;
  content?: string;
}

export type HookHandler = (context: HookContext) => Promise<void>;

// ── Task Graph ──────────────────────────────────────────────

export interface TaskNode {
  step: number;
  agentId: AgentId;
  dependsOn: number[];
  onSuccess: 'next' | 'complete' | number;
  onFailure: 'retry' | 'halt' | number;
  maxRetries: number;
  escalateAfterRetries: boolean;
}

export interface TaskGraph {
  nodes: TaskNode[];
  description: string;
}

// ── Vault Types ─────────────────────────────────────────────

export interface VaultNoteMeta {
  agent_id?: string;
  model?: string;
  tools?: string[];
  forbidden_tools?: string[];
  reads?: string[];
  writes?: string[];
  max_retries?: number;
  timeout_seconds?: number;
  escalate_after_retries?: boolean;
  type?: string;
  description?: string;
  [key: string]: unknown;
}

export interface VaultNote {
  meta: VaultNoteMeta;
  body: string;
  path: string;
}

// ── E2E Validation ──────────────────────────────────────────

export interface E2EValidationInput extends AgentInput {
  repoRoot: string;
  backendUrl: string;
  frontendUrl: string;
  storyboardsPath: string;     // path to 09-storyboards.md
  apiContractsPath: string;    // path to 06-api-contracts.md
  screenStatesPath: string;    // path to 10-screen-state-matrix.md
  apiSpMapPath: string;        // path to 11-api-to-sp-map.md
}

export interface E2ETestResult {
  flow: string;
  step: number;
  action: string;
  expected: string;
  actual: string;
  passed: boolean;
  screenshot?: string;
  networkCalls?: string[];
}

export interface E2EValidationResult extends AgentOutput {
  passed: boolean;
  totalFlows: number;
  passedFlows: number;
  failedFlows: number;
  results: E2ETestResult[];
  categories: {
    apiContract: { tested: number; passed: number; failures: string[] };
    screenRender: { tested: number; passed: number; failures: string[] };
    crudOperations: { tested: number; passed: number; failures: string[] };
    authFlows: { tested: number; passed: number; failures: string[] };
    mockDataDetection: { tested: number; passed: number; failures: string[] };
    errorStates: { tested: number; passed: number; failures: string[] };
  };
}

// ── Post-Deploy Validation ──────────────────────────────────

export interface PostDeployInput extends AgentInput {
  deployRecord: DeployRecord;
  frontendUrl: string;
  apiBaseUrl: string;
  storyboardsPath: string;
  apiContractsPath: string;
  connectionString?: string;
}

export interface PostDeployValidationResult extends AgentOutput {
  passed: boolean;
  checks: PostDeployCheck[];
  spExistence: { expected: number; found: number; missing: string[] };
  dtoValidation: { tested: number; passed: number; mismatches: string[] };
  pageRender: { tested: number; passed: number; failures: string[] };
  authFlow: { passed: boolean; details: string };
}

export interface PostDeployCheck {
  name: string;
  category: 'infrastructure' | 'api' | 'database' | 'frontend' | 'auth';
  passed: boolean;
  details: string;
  severity: Severity;
}

// ── Error Types ─────────────────────────────────────────────

export class QualityGateFailure extends Error {
  constructor(
    public gateResult: GateResult,
    message?: string,
  ) {
    super(message ?? `Quality gate failed: coverage=${gateResult.coverage}%, security=${gateResult.securityScore}`);
    this.name = 'QualityGateFailure';
  }
}

export class HardGateViolation extends Error {
  constructor(message?: string) {
    super(message ?? 'HARD GATE VIOLATION: DeployAgent cannot execute without GateResult.passed === true');
    this.name = 'HardGateViolation';
  }
}

export class AgentTimeoutError extends Error {
  constructor(
    public agentId: AgentId,
    public timeoutMs: number,
  ) {
    super(`Agent ${agentId} timed out after ${timeoutMs}ms`);
    this.name = 'AgentTimeoutError';
  }
}

export class EscalationError extends Error {
  constructor(
    public agentId: AgentId,
    public attempts: number,
    public lastError: Error,
  ) {
    super(`Agent ${agentId} failed after ${attempts} attempts: ${lastError.message}`);
    this.name = 'EscalationError';
  }
}
