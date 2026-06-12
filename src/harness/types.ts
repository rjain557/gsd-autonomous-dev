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
  | 'deploy-agent'
  // V6 additions:
  | 'milestone-orchestrator'
  | 'review-auditor-agent'
  | 'scout-agent'
  | 'researcher-agent'
  // v6.2: hard-5% domain agents (replaces human hires per myJian §10.15):
  | 'security-agent'
  | 'compliance-agent'
  | 'legal-agent'
  | 'pm-agent'
  // v6.3: maintenance flow (Phase U — update existing applications):
  | 'issue-triage-agent'
  | 'update-spec-agent';

export type PipelineStage =
  | 'triage'         // v6.3: maintenance — issue intake + fault localization
  | 'update-spec'    // v6.3: maintenance — frozen change spec generation
  | 'blueprint'
  | 'review'
  | 'remediate'
  | 'e2e'
  | 'post-deploy'
  | 'gate'
  | 'audit'          // V6: ReviewAuditor cross-review between gate and deploy
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
  // v6.3: maintenance flow (Phase U) — null on greenfield runs
  triageContext: { issueDescription: string } | null;
  triageResult: TriageResult | null;
  specUpdateResult: SpecUpdateResult | null;
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

// ── Maintenance Flow (Phase U — v6.3) ───────────────────────

export type ReproStatus = 'confirmed' | 'not-reproducible' | 'needs-info';
export type MaintenanceCategory = 'bug' | 'feature' | 'change-request' | 'question';

export interface SuspectLocation {
  file: string;
  symbol: string;        // function / class / component / stored procedure
  lines: string;         // e.g. "120-145" (best effort)
  confidence: number;    // 0-1; <0.4 suspects are excluded by triage rules
  rationale: string;     // must cite the code excerpt (attribution over confidence)
}

export interface TriageInput extends AgentInput {
  issueDescription: string;
  repoRoot: string;
  candidateFiles: Array<{ path: string; excerpt: string; matchScore: number }>;
  specPaths: string[];
}

export interface TriageResult extends AgentOutput {
  isValid: boolean;                  // actionable now (bugs require confirmed repro)
  category: MaintenanceCategory;
  severity: Severity;
  reproStatus: ReproStatus;
  reproArtifact: string;             // failing test sketch / Playwright steps / SQL state
  clarifyingQuestions: string[];     // populated when reproStatus = needs-info
  suspects: SuspectLocation[];
  affectedComponents: string[];
  affectedSpecs: string[];           // frozen spec areas the fix will touch
  riskLevel: RiskLevel;
  recommendedAction: string;
  scopeAnalysis: string;
}

export interface UpdateSpecInput extends AgentInput {
  triageResult: TriageResult;
  repoRoot: string;
  specExcerpts: Array<{ path: string; excerpt: string }>;
}

export interface DeltaSpec {
  target: string;                    // e.g. "06-api-contracts §Orders"
  change: string;                    // ADDED / MODIFIED / REMOVED content in target's format
}

export interface SpecUpdateResult extends AgentOutput {
  changeId: string;                  // CH-{runId}
  proposal: string;                  // root cause, approach, alternative, non-goals
  deltaSpecs: DeltaSpec[];
  earsCriteria: string[];            // WHEN ... THE SYSTEM SHALL ... (repro flip first)
  tasks: string[];                   // ordered checklist for RemediationAgent
  testPlan: string;
  riskLevel: RiskLevel;
  requiresHumanApproval: boolean;
  summary: string;
}

// ── Orchestrator ────────────────────────────────────────────

export interface PipelineTrigger {
  trigger: TriggerType;
  fromStage?: PipelineStage;
  dryRun?: boolean;
  vaultPath: string;
  /** v6.3: client-reported issue text — starts the maintenance flow at stage 'triage' */
  issueDescription?: string;
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

// ═══════════════════════════════════════════════════════════════
// v6.2 — Hard-5% Domain Agents (Security / Compliance / Legal / PM)
// Replaces the senior security engineer + compliance lead +
// retained counsel + PM hires from myJian §10.15. AI agents do the
// drafting; RJain (or named officer) is the human-of-record where
// statute or contract requires a human signatory.
// ═══════════════════════════════════════════════════════════════

// ── Security Agent ──────────────────────────────────────────

export interface SecurityAgentInput extends AgentInput {
  convergenceReport: ConvergenceReport;
  changedFiles: string[];
  patchSet?: PatchSet;
  securityCriticalPaths: string[];
}

export interface SecurityFinding {
  id: string;
  file: string;
  line: number;
  severity: Severity;
  category: 'static-analysis' | 'secret-leak' | 'crypto' | 'auth' | 'sandbox-escape' | 'supply-chain' | 'threat-model-delta' | 'hsm-bypass' | 'audit-gap';
  cwe?: string;
  message: string;
  suggestedRemediation: string;
  securityCriticalPath: boolean;
}

export interface ThreatModelDelta {
  affected_components: string[];
  new_trust_boundaries: string[];
  new_attack_surfaces: string[];
  draft_update_text: string;
}

export interface SignatoryAction {
  category: 'hsm' | 'cert-rotation' | 'compliance-attestation' | 'vendor-application' | 'incident-response' | 'legal-execution';
  description: string;
  signatory: 'CEO' | 'CISO' | 'GC' | 'named-officer';
  dueDate?: string;
  blocking: boolean;
  artifactPath?: string;
}

export interface SecurityReviewResult extends AgentOutput {
  signoffGranted: boolean;
  findings: SecurityFinding[];
  threatModelDelta: ThreatModelDelta | null;
  scaResults: {
    npmAuditCritical: number;
    npmAuditHigh: number;
    dotnetVulnCount: number;
    denyListLicenses: string[];
  };
  signatoryActions: SignatoryAction[];
  evidence: string[];
}

// ── Compliance Agent ────────────────────────────────────────

export type ComplianceFramework =
  | 'CMMC' | 'FedRAMP' | 'FISMA' | 'DFARS' | 'ITAR' | 'CJIS'
  | 'HIPAA' | 'PCI-DSS' | 'GLBA' | 'SOX' | 'SOC2'
  | 'NIST-800-53' | 'ISO-27001'
  | 'StateRAMP' | 'NERC-CIP' | 'FERPA';

export interface ComplianceAgentInput extends AgentInput {
  requested_frameworks: ComplianceFramework[];
  client_scope: 'all' | string;
  window: { start: string; end: string };
  evidence_mode: 'point-in-time' | 'continuous';
  prior_evidence_pack_ids?: string[];
}

export interface ComplianceException {
  control_id: string;
  description: string;
  remediated_at?: string;
}

export interface FrameworkResult {
  framework: ComplianceFramework;
  total_controls: number;
  mapped_controls: number;
  gap_count: number;
  management_assertion_draft: string;
  exceptions: ComplianceException[];
}

export interface ControlMappingGroup {
  group_id: string;
  mapped_to: { framework: ComplianceFramework; control_id: string }[];
  evidence_sources: string[];
}

export interface ComplianceGap {
  framework: ComplianceFramework;
  control_id: string;
  description: string;
  remediation_task: string;
  effort: 'low' | 'medium' | 'high';
  risk_severity: Severity;
}

export interface AttestationDriftItem {
  control_id: string;
  evidence_source: string;
  last_evidence_at: string;
  expected_cadence: string;
  drift_severity: 'low' | 'medium' | 'high';
}

export interface ComplianceArtifacts extends AgentOutput {
  pack_id: string;
  generated_at: string;
  client_scope: string;
  window: { start: string; end: string };
  framework_results: FrameworkResult[];
  control_mapping_groups: ControlMappingGroup[];
  gaps: ComplianceGap[];
  continuous_attestation_drift: AttestationDriftItem[];
  signatoryActions: SignatoryAction[];
  evidence_pack_path: string;
}

// ── Legal Agent ─────────────────────────────────────────────

export type LegalDocumentType =
  | 'msa-amendment' | 'baa-update' | 'eula' | 'privacy-notice'
  | 'employment-monitoring-notice' | 'consent-form' | 'breach-notification'
  | 'data-processing-addendum' | 'vendor-contract-summary'
  | 'state-law-summary' | 'sub-processor-disclosure' | 'nda';

export type LegalJurisdiction =
  | 'US-CA' | 'US-IL' | 'US-NY' | 'US-CT' | 'US-CO' | 'US-WA' | 'US-VA' | 'US-TX' | 'US-FL'
  | 'US-FEDERAL' | 'EU' | 'UK' | 'CA' | 'AU' | 'ALL-US-STATES';

export interface LegalAgentInput extends AgentInput {
  document_type: LegalDocumentType;
  triggering_capability: string;
  affected_jurisdictions: LegalJurisdiction[];
  counterparty?: {
    name: string;
    type: 'client' | 'vendor' | 'employee' | 'regulator';
    existing_contract_id?: string;
  };
  client_codes?: string[];
  baseline_template_path?: string;
}

export interface LegalCitation {
  jurisdiction: LegalJurisdiction;
  statute: string;
  effective_date: string;
  url?: string;
  freshness_verified_at?: string;
}

export interface JurisdictionSection {
  jurisdiction: LegalJurisdiction;
  variation_from_baseline: string;
  controlling_statute: string;
}

export interface BoundaryViolation {
  clause_id: string;
  reason: string;
  recommended_action: 'remove' | 'route-to-attorney' | 'rewrite-as-preparation';
}

export interface LegalArtifact extends AgentOutput {
  draft_path: string;
  document_type: LegalDocumentType;
  affected_jurisdictions: LegalJurisdiction[];
  requires_licensed_attorney_review: boolean;
  attorney_review_level: 'in-house' | 'outside-counsel-general' | 'outside-counsel-specialist';
  citations: LegalCitation[];
  jurisdiction_specific_sections: JurisdictionSection[];
  redline_against?: string;
  signatoryActions: SignatoryAction[];
  boundary_violations: BoundaryViolation[];
  draft_body: string;
  plain_english_summary: string;
  statute_verification_recommended: boolean;
}

// ── PM Agent ────────────────────────────────────────────────

export type PMReportType = 'weekly-status' | 'vendor-only' | 'milestone-only' | 'rjain-action-items' | 'full';

export interface PMAgentInput extends AgentInput {
  report_type: PMReportType;
  window?: { start: string; end: string };
  include_archived_vendors?: boolean;
}

export interface PMActionItem {
  category: 'vendor-call' | 'signature' | 'decision' | 'review';
  description: string;
  due_date?: string;
  priority: 'urgent' | 'high' | 'normal';
  artifact_path?: string;
}

export interface VendorStatus {
  vendor: string;
  capability: string;
  status: 'not-started' | 'in-progress' | 'active' | 'lapsed' | 'archived';
  technijian_poc: string;
  vendor_poc?: string;
  last_activity: string;
  next_action: string;
  next_action_owner: 'pm-agent' | 'legal-agent' | 'security-agent' | 'rjain';
}

export interface RenewalItem {
  item: string;
  due_date: string;
  days_until: number;
  preparation_status: 'not-started' | 'in-progress' | 'ready-for-signature' | 'complete';
  owner: string;
}

export interface MilestoneStatus {
  milestone_id: string;
  phase_number?: number;
  title: string;
  status: 'pending' | 'in-progress' | 'blocked' | 'complete' | 'cancelled';
  percent_complete: number;
  eta?: string;
  blocking_dependencies: string[];
}

export interface PMBlocker {
  description: string;
  blocking_milestones: string[];
  owner: string;
  severity: Severity;
}

export interface SignatoryItem {
  document_type: string;
  artifact_path: string;
  signatory: string;
  due_date?: string;
}

export interface PMStatusReport extends AgentOutput {
  report_date: string;
  report_type: PMReportType;
  status_report_markdown: string;
  rjain_action_items: PMActionItem[];
  vendor_relationships: VendorStatus[];
  urgent_renewals: RenewalItem[];
  milestone_status: MilestoneStatus[];
  blockers: PMBlocker[];
  artifacts_awaiting_signature: SignatoryItem[];
}
