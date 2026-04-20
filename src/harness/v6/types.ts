// ═══════════════════════════════════════════════════════════
// GSD V6 — Hierarchical Types
// Milestone → Slice → Task → Stage
// ═══════════════════════════════════════════════════════════

import type { AgentId, PipelineStage, PipelineState, Decision } from '../types';

// ── Identifiers ─────────────────────────────────────────────
export type MilestoneId = string;    // e.g., "M001"
export type SliceId = string;         // e.g., "S01"
export type TaskId = string;          // e.g., "T001"

export type MilestoneStatus = 'pending' | 'running' | 'paused' | 'failed' | 'complete';
export type SliceStatus = 'pending' | 'running' | 'blocked' | 'failed' | 'complete';
export type TaskStatus = 'pending' | 'running' | 'stuck' | 'failed' | 'complete' | 'skipped';

// ── Milestone ───────────────────────────────────────────────
export interface Milestone {
  id: MilestoneId;
  name: string;
  description: string;
  status: MilestoneStatus;
  startedAt: string;
  completedAt: string | null;
  budgetUsd: number;
  spentUsd: number;
  worktreePath: string | null;
  parentRepoPath: string;
}

// ── Slice ───────────────────────────────────────────────────
export interface Slice {
  id: SliceId;
  milestoneId: MilestoneId;
  name: string;
  description: string;
  status: SliceStatus;
  dependsOnSliceIds: SliceId[];
  startedAt: string | null;
  completedAt: string | null;
}

// ── Task ────────────────────────────────────────────────────
export interface Task {
  id: TaskId;
  sliceId: SliceId;
  agentId: AgentId;
  stage: PipelineStage;
  status: TaskStatus;
  dependsOnTaskIds: TaskId[];
  startedAt: string | null;
  completedAt: string | null;
  costUsd: number;
  tokensIn: number;
  tokensOut: number;
  outputHash: string | null;
  attempt: number;
  maxAttempts: number;
}

// ── Stuck Pattern ──────────────────────────────────────────
export interface StuckPattern {
  id: number;
  signatureHash: string;
  occurrences: number;
  firstSeen: string;
  lastSeen: string;
  context: string;
}

// ── Rate Limit Window ──────────────────────────────────────
export interface RateLimitWindow {
  cliId: string;
  timestamp: string;
  callsInWindow: number;
}

// ── Timeout Hierarchy ──────────────────────────────────────
export interface TaskTimeouts {
  softTimeoutSec: number;   // inject "wrap up" message
  idleTimeoutSec: number;   // probe for progress
  hardTimeoutSec: number;   // halt + forensic bundle
}

export const DEFAULT_TIMEOUTS: TaskTimeouts = {
  softTimeoutSec: 120,
  idleTimeoutSec: 180,
  hardTimeoutSec: 300,
};

// ── Budget Status ──────────────────────────────────────────
export type BudgetTier = 'normal' | 'downgrade-soft' | 'downgrade-hard' | 'emergency';

export interface BudgetStatus {
  spentUsd: number;
  budgetUsd: number;
  percentUsed: number;
  tier: BudgetTier;
}

// ── Capability ─────────────────────────────────────────────
export interface AgentCapability {
  agentId: string;
  languages: string[];
  domains: string[];
  maxContextTokens: number;
  qualityScore: number;          // 0-1, from historical eval results
  availabilityScore: number;     // 0-1, current rate-limit headroom
}

// ── Execution Graph ────────────────────────────────────────
export interface GraphNode {
  id: TaskId;
  dependsOn: TaskId[];
  status: TaskStatus;
}

export interface ExecutionPlan {
  ready: TaskId[];        // no unsatisfied deps, not running
  running: TaskId[];      // currently executing
  blocked: TaskId[];      // waiting on deps
  complete: TaskId[];
  failed: TaskId[];
}

// ── Milestone Run Context ──────────────────────────────────
// Passed from MilestoneOrchestrator into slice-level work.
export interface MilestoneContext {
  milestone: Milestone;
  slice: Slice;
  worktreePath: string;
  vaultPath: string;
  budgetStatus: BudgetStatus;
  parentRunId: string;
}

// ── Slice Execution Result ─────────────────────────────────
export interface SliceResult {
  sliceId: SliceId;
  status: SliceStatus;
  pipelineState: PipelineState | null;
  decisions: Decision[];
  costUsd: number;
  durationMs: number;
  error?: string;
}

// ── Capability Gap (Tier 4.7) ──────────────────────────────
export interface CapabilityGap {
  kind: 'capability-gap';
  missing: string;
  blocks: string;
  suggestedFix: string;
}

// ── Forensics Bundle ───────────────────────────────────────
export interface ForensicsBundle {
  runId: string;
  createdAt: string;
  milestoneId: MilestoneId | null;
  sliceIds: SliceId[];
  taskIds: TaskId[];
  decisionsMarkdownPaths: string[];
  observabilityPaths: string[];
  gitDiff: string;
  stateSnapshot: object;
  outputZipPath: string;
}
