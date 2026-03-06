/** Core GSD data types — mirrors the JSON schemas from the engine */

export interface HealthData {
  health_score: number;
  total_requirements: number;
  satisfied: number;
  partial: number;
  not_started: number;
  iteration: number;
}

export interface Requirement {
  id: string;
  source: 'spec' | 'figma' | 'compliance';
  sdlc_phase: string;
  description: string;
  figma_frame: string | null;
  spec_doc: string;
  status: 'satisfied' | 'partial' | 'not_started';
  satisfied_by: string[];
  depends_on: string[];
  pattern: string;
  priority: 'critical' | 'high' | 'medium' | 'low';
  confidence: 'high' | 'medium' | 'low';
}

export interface RequirementsMatrix {
  meta: {
    total_requirements: number;
    satisfied: number;
    partial: number;
    not_started: number;
    health_score: number;
    figma_version: string;
    sdlc_phases: string[];
    last_updated: string;
    iteration: number;
  };
  requirements: Requirement[];
}

export interface EngineStatus {
  pid: number;
  state: 'starting' | 'running' | 'sleeping' | 'stalled' | 'completed' | 'converged';
  phase: string;
  agent: string;
  iteration: number;
  attempt: string;
  batch_size: number;
  health_score: number;
  last_heartbeat: string;
  started_at: string;
  elapsed_minutes: number;
  sleep_until: string | null;
  sleep_reason: string | null;
  last_error: string | null;
  errors_this_iteration: number;
  recovered_from_error: boolean;
}

export interface QueueItem {
  req_id: string;
  description: string;
  priority: 'critical' | 'high' | 'medium' | 'low';
  depends_on: string[];
  target_files: string[];
  pattern: string;
  acceptance_criteria: string;
  figma_reference: string | null;
  estimated_effort: 'low' | 'medium' | 'high';
}

export interface QueueData {
  iteration: number;
  health_before: number;
  batch_size: number;
  priority_order: number;
  batch: QueueItem[];
  timestamp: string;
}

export interface CostDetail {
  agent: string;
  phase: string;
  iteration: number;
  tokens_in: number;
  tokens_out: number;
  cost_usd: number;
  timestamp: string;
}

export interface CostRun {
  started: string;
  ended: string;
  calls: number;
  cost_usd: number;
  details: CostDetail[];
}

export interface CostSummary {
  pipeline: string;
  project: string;
  started: string;
  runs: CostRun[];
  total_cost_usd: number;
  total_calls: number;
}

export interface HandoffEntry {
  iteration: number;
  timestamp: string;
  agent: string;
  phase: string;
  action: string;
  health_before: number;
  health_after: number;
  batch_size: number;
  status: 'success' | 'partial' | 'failed';
  output_files: string[];
  duration_seconds: number;
  error: string | null;
}

export interface SupervisorState {
  diagnosis: string;
  confidence: 'high' | 'medium' | 'low';
  last_attempted_fix: string;
  attempts: number;
  timestamp: string;
}

export interface GsdSnapshot {
  health: HealthData | null;
  matrix: RequirementsMatrix | null;
  engine: EngineStatus | null;
  queue: QueueData | null;
  costs: CostSummary | null;
  handoffs: HandoffEntry[];
  supervisor: SupervisorState | null;
  timestamp: number;
}
