// ═══════════════════════════════════════════════════════════
// GSD V6 — Unit tests for V6 modules
// Runnable via: npx ts-node src/harness/v6/__tests__/v6-tests.ts
// Lightweight harness (no Jest dep) — each test is a sync/async
// function that throws on failure.
// ═══════════════════════════════════════════════════════════

import * as fs from 'fs';
import * as path from 'path';
import * as os from 'os';
import * as assert from 'assert';

import { StateDB } from '../state-db';
import { ExecutionGraph } from '../execution-graph';
import { BudgetRouter } from '../budget-router';
import { CapabilityRouter } from '../capability-router';
import { StuckDetector } from '../stuck-detector';
import { AutoLock } from '../auto-lock';
import { runWithTimeouts } from '../timeout-hierarchy';
import { SlicePlanner } from '../slice-planner';
import { CapabilityEscalator, isCapabilityGap } from '../capability-escalation';
import type { Task, Slice, Milestone } from '../types';
import type { AgentCapability } from '../types';
// v6.1.0 — project stack context
import {
  parseStackOverrides,
  getProjectStackContext,
  normalizeFramework,
  renderStackContextBlock,
  DEFAULT_STACK_CONTEXT,
} from '../../project-stack-context';
import { validateStackLeaks, formatStackLeakReport } from '../stack-leak-validator';

interface TestCase {
  name: string;
  run: () => void | Promise<void>;
}

const tests: TestCase[] = [];
function test(name: string, run: () => void | Promise<void>): void {
  tests.push({ name, run });
}

function tmpDir(prefix: string): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), `gsd-v6-${prefix}-`));
  return dir;
}

// ── StateDB ──────────────────────────────────────────────
test('StateDB: create + get milestone', () => {
  const dir = tmpDir('statedb');
  const db = new StateDB(path.join(dir, 'state.db'));
  const m: Milestone = {
    id: 'M001', name: 'test', description: 'd',
    status: 'running', startedAt: new Date().toISOString(), completedAt: null,
    budgetUsd: 5, spentUsd: 0, worktreePath: null, parentRepoPath: dir,
  };
  db.createMilestone(m);
  const got = db.getMilestone('M001');
  assert.ok(got);
  assert.strictEqual(got!.name, 'test');
  db.close();
});

test('StateDB: slices + tasks round-trip', () => {
  const dir = tmpDir('statedb2');
  const db = new StateDB(path.join(dir, 'state.db'));
  const m: Milestone = {
    id: 'M002', name: 't', description: '',
    status: 'running', startedAt: new Date().toISOString(), completedAt: null,
    budgetUsd: 1, spentUsd: 0, worktreePath: null, parentRepoPath: dir,
  };
  db.createMilestone(m);
  const s: Slice = {
    id: 'S01', milestoneId: 'M002', name: 's1', description: '',
    status: 'pending', dependsOnSliceIds: [],
    startedAt: null, completedAt: null,
  };
  db.createSlice(s);
  const t: Task = {
    id: 'T001', sliceId: 'S01', agentId: 'code-review-agent', stage: 'review',
    status: 'pending', dependsOnTaskIds: [],
    startedAt: null, completedAt: null,
    costUsd: 0, tokensIn: 0, tokensOut: 0, outputHash: null,
    attempt: 0, maxAttempts: 3,
  };
  db.createTask(t);

  const slices = db.listSlicesForMilestone('M002');
  const tasks = db.listTasksForSlice('S01');
  assert.strictEqual(slices.length, 1);
  assert.strictEqual(tasks.length, 1);
  assert.strictEqual(tasks[0].id, 'T001');
  db.close();
});

test('StateDB: stuck pattern increments on repeat', () => {
  const dir = tmpDir('statedb3');
  const db = new StateDB(path.join(dir, 'state.db'));
  const now = new Date().toISOString();
  const a = db.upsertStuckPattern('sig-1', 'ctx', now);
  assert.strictEqual(a.occurrences, 1);
  const b = db.upsertStuckPattern('sig-1', 'ctx', now);
  assert.strictEqual(b.occurrences, 2);
  db.close();
});

// ── ExecutionGraph ───────────────────────────────────────
test('ExecutionGraph: computePlan respects deps', () => {
  const tasks: Task[] = [
    { id: 'T1', sliceId: 'S1', agentId: 'code-review-agent', stage: 'review', status: 'pending', dependsOnTaskIds: [], startedAt: null, completedAt: null, costUsd: 0, tokensIn: 0, tokensOut: 0, outputHash: null, attempt: 0, maxAttempts: 1 },
    { id: 'T2', sliceId: 'S1', agentId: 'quality-gate-agent', stage: 'gate', status: 'pending', dependsOnTaskIds: ['T1'], startedAt: null, completedAt: null, costUsd: 0, tokensIn: 0, tokensOut: 0, outputHash: null, attempt: 0, maxAttempts: 1 },
  ];
  const plan = ExecutionGraph.computePlan(tasks);
  assert.deepStrictEqual(plan.ready, ['T1']);
  assert.deepStrictEqual(plan.blocked, ['T2']);
});

test('ExecutionGraph: detects cycles', () => {
  const tasks: Task[] = [
    { id: 'A', sliceId: 'S1', agentId: 'code-review-agent', stage: 'review', status: 'pending', dependsOnTaskIds: ['B'], startedAt: null, completedAt: null, costUsd: 0, tokensIn: 0, tokensOut: 0, outputHash: null, attempt: 0, maxAttempts: 1 },
    { id: 'B', sliceId: 'S1', agentId: 'code-review-agent', stage: 'review', status: 'pending', dependsOnTaskIds: ['A'], startedAt: null, completedAt: null, costUsd: 0, tokensIn: 0, tokensOut: 0, outputHash: null, attempt: 0, maxAttempts: 1 },
  ];
  const cycles = ExecutionGraph.detectCycles(tasks);
  assert.ok(cycles.length > 0);
});

test('ExecutionGraph: runGraph completes independent tasks', async () => {
  const tasks: Task[] = [
    { id: 'T1', sliceId: 'S1', agentId: 'code-review-agent', stage: 'review', status: 'pending', dependsOnTaskIds: [], startedAt: null, completedAt: null, costUsd: 0, tokensIn: 0, tokensOut: 0, outputHash: null, attempt: 0, maxAttempts: 1 },
    { id: 'T2', sliceId: 'S1', agentId: 'quality-gate-agent', stage: 'gate', status: 'pending', dependsOnTaskIds: [], startedAt: null, completedAt: null, costUsd: 0, tokensIn: 0, tokensOut: 0, outputHash: null, attempt: 0, maxAttempts: 1 },
  ];
  const results = await ExecutionGraph.runGraph(tasks, async (t) => ({
    taskId: t.id,
    status: 'complete' as const,
  }));
  assert.strictEqual(results.size, 2);
  assert.strictEqual(results.get('T1')?.status, 'complete');
  assert.strictEqual(results.get('T2')?.status, 'complete');
});

// ── BudgetRouter ─────────────────────────────────────────
test('BudgetRouter: tier transitions at 50/75/90%', () => {
  const r = new BudgetRouter({ budgetUsd: 10, spentUsd: 0 });
  assert.strictEqual(r.status.tier, 'normal');
  r.updateSpend(5.5);  // 55%
  assert.strictEqual(r.status.tier, 'downgrade-soft');
  r.updateSpend(7.6);  // 76%
  assert.strictEqual(r.status.tier, 'downgrade-hard');
  r.updateSpend(9.1);  // 91%
  assert.strictEqual(r.status.tier, 'emergency');
});

test('BudgetRouter: pickModel downgrades premium to standard at 50%', () => {
  const r = new BudgetRouter({ budgetUsd: 10, spentUsd: 5.5 });
  const pick = r.pickModel('premium');
  assert.ok(pick.tier === 'standard');
});

test('BudgetRouter: pickModel forces emergency at 90%', () => {
  const r = new BudgetRouter({ budgetUsd: 10, spentUsd: 9.5 });
  const pick = r.pickModel('premium');
  assert.strictEqual(pick.tier, 'emergency');
});

// ── CapabilityRouter ─────────────────────────────────────
test('CapabilityRouter: ranks by match score', () => {
  const caps: AgentCapability[] = [
    { agentId: 'A', languages: ['typescript'], domains: ['ui'], maxContextTokens: 100_000, qualityScore: 0.9, availabilityScore: 1 },
    { agentId: 'B', languages: ['csharp'], domains: ['db'], maxContextTokens: 100_000, qualityScore: 0.9, availabilityScore: 1 },
  ];
  const router = new CapabilityRouter(caps);
  const picks = router.rank({ languages: ['typescript'], domains: ['ui'], tokenSize: 1000 });
  assert.strictEqual(picks[0].agentId, 'A');
});

// ── StuckDetector ────────────────────────────────────────
test('StuckDetector: reports stuck at threshold', () => {
  const dir = tmpDir('stuck');
  const db = new StateDB(path.join(dir, 'state.db'));
  const sd = new StuckDetector(db, 2);
  const s1 = sd.record('task-1', { patches: ['a'] }, 'ctx');
  assert.strictEqual(s1.isStuck, false);
  const s2 = sd.record('task-1', { patches: ['a'] }, 'ctx');
  assert.strictEqual(s2.isStuck, true);
  db.close();
});

// ── AutoLock ─────────────────────────────────────────────
test('AutoLock: acquire + release', () => {
  const dir = tmpDir('lock');
  const lock = new AutoLock(path.join(dir, 'state.db.lock'));
  const info = lock.acquire('run-1');
  assert.strictEqual(info.runId, 'run-1');
  lock.release();
  const inspected = lock.inspect();
  assert.strictEqual(inspected, null);
});

test('AutoLock: second acquire fails while first alive', () => {
  const dir = tmpDir('lock2');
  const lockA = new AutoLock(path.join(dir, 'state.db.lock'));
  const lockB = new AutoLock(path.join(dir, 'state.db.lock'));
  lockA.acquire('run-A');
  let threw = false;
  try { lockB.acquire('run-B'); } catch { threw = true; }
  assert.strictEqual(threw, true);
  lockA.release();
});

// ── TimeoutHierarchy ─────────────────────────────────────
test('TimeoutHierarchy: completes before hard timeout', async () => {
  const result = await runWithTimeouts<number>(
    async () => { await new Promise((r) => setTimeout(r, 50)); return 42; },
    { softTimeoutSec: 30, idleTimeoutSec: 30, hardTimeoutSec: 30 },
  );
  assert.strictEqual(result.timedOut, false);
  assert.strictEqual(result.result, 42);
});

test('TimeoutHierarchy: hard timeout fires', async () => {
  const result = await runWithTimeouts<number>(
    async () => { await new Promise((r) => setTimeout(r, 3000)); return 1; },
    { softTimeoutSec: 1, idleTimeoutSec: 1, hardTimeoutSec: 1 },
  );
  assert.strictEqual(result.timedOut, true);
  assert.strictEqual(result.stage, 'hard');
});

// ── SlicePlanner ─────────────────────────────────────────
test('SlicePlanner: default slice when no roadmap', () => {
  const dir = tmpDir('planner');
  const plan = SlicePlanner.plan({
    milestoneId: 'M001',
    vaultPath: dir,
    milestoneName: 'test',
    description: 'd',
  });
  assert.strictEqual(plan.source, 'default');
  assert.strictEqual(plan.slices.length, 1);
  assert.strictEqual(plan.slices[0].id, 'S01');
});

test('SlicePlanner: parseRoadmap extracts slices with deps', () => {
  const md = `
# Milestone test

## Slices
- S01: thread archive — archive flow
- S02: thread restore — restore (depends on S01)
- S03: bulk ui — batch actions (depends on S01, S02)
`;
  const slices = SlicePlanner.parseRoadmap(md, 'M001');
  assert.strictEqual(slices.length, 3);
  assert.deepStrictEqual(slices[1].dependsOnSliceIds, ['S01']);
  assert.deepStrictEqual(slices[2].dependsOnSliceIds, ['S01', 'S02']);
});

// ── CapabilityEscalator ──────────────────────────────────
test('CapabilityEscalator: new-slice resolution creates a capability slice', () => {
  const dir = tmpDir('escal');
  const db = new StateDB(path.join(dir, 'state.db'));
  db.createMilestone({
    id: 'M001', name: 't', description: '',
    status: 'running', startedAt: new Date().toISOString(), completedAt: null,
    budgetUsd: 1, spentUsd: 0, worktreePath: null, parentRepoPath: dir,
  });
  db.createSlice({
    id: 'S01', milestoneId: 'M001', name: 's', description: '',
    status: 'running', dependsOnSliceIds: [], startedAt: null, completedAt: null,
  });
  const esc = new CapabilityEscalator(db, 'M001');
  const outcome = esc.handle(
    { kind: 'capability-gap', missing: 'Semgrep rule for X', blocks: 'S01', suggestedFix: 'add rule' },
    'S01',
  );
  assert.strictEqual(outcome.resolution, 'new-slice');
  assert.ok(outcome.newSliceId);
  db.close();
});

test('isCapabilityGap type guard', () => {
  assert.strictEqual(isCapabilityGap({ kind: 'capability-gap', missing: 'X', blocks: '', suggestedFix: '' }), true);
  assert.strictEqual(isCapabilityGap({ kind: 'other' }), false);
  assert.strictEqual(isCapabilityGap(null), false);
});

// ── v6.1.0: Project Stack Context ────────────────────────
const FIXTURES_DIR = path.join(__dirname, '..', '..', '..', '..', 'test-fixtures', 'stack-overrides');

test('ProjectStackContext: parseStackOverrides(net9-full.md) extracts all fields', () => {
  const md = fs.readFileSync(path.join(FIXTURES_DIR, 'net9-full.md'), 'utf8');
  const ctx = parseStackOverrides(md);
  assert.strictEqual(ctx.source, 'override');
  assert.strictEqual(ctx.backendFramework, 'net9.0');
  assert.strictEqual(ctx.backendSdk, '.NET 10 SDK');
  assert.strictEqual(ctx.solutionFileFormat, 'slnx');
  assert.ok(ctx.dataAccessPattern.includes('Dapper'));
  assert.strictEqual(ctx.database, 'SQL Server');
  assert.strictEqual(ctx.frontendFramework, 'React 18');
  assert.strictEqual(ctx.frontendUiLibrary, 'Fluent UI v9');
  assert.strictEqual(ctx.frontendBuildTool, 'Vite');
  assert.strictEqual(ctx.mobileFramework, 'React Native');
  assert.strictEqual(ctx.mobileToolchain, 'Expo managed workflow');
  assert.strictEqual(ctx.agentLanguage, 'Go');
  assert.ok(ctx.complianceFrameworks.includes('HIPAA'));
  assert.ok(ctx.rawMarkdown !== null);
});

test('ProjectStackContext: parseStackOverrides(net8-minimal.md) defaults unspecified fields', () => {
  const md = fs.readFileSync(path.join(FIXTURES_DIR, 'net8-minimal.md'), 'utf8');
  const ctx = parseStackOverrides(md);
  assert.strictEqual(ctx.source, 'override');
  assert.strictEqual(ctx.backendFramework, 'net8.0');
  // Unspecified fields inherit defaults
  assert.strictEqual(ctx.backendSdk, DEFAULT_STACK_CONTEXT.backendSdk);
  assert.strictEqual(ctx.solutionFileFormat, DEFAULT_STACK_CONTEXT.solutionFileFormat);
  assert.strictEqual(ctx.frontendFramework, DEFAULT_STACK_CONTEXT.frontendFramework);
  assert.strictEqual(ctx.mobileFramework, null);
  assert.strictEqual(ctx.agentLanguage, null);
});

test('ProjectStackContext: parseStackOverrides(empty.md) returns defaults with source="override"', () => {
  const md = fs.readFileSync(path.join(FIXTURES_DIR, 'empty.md'), 'utf8');
  const ctx = parseStackOverrides(md);
  assert.strictEqual(ctx.source, 'override');
  assert.strictEqual(ctx.backendFramework, DEFAULT_STACK_CONTEXT.backendFramework);
  assert.strictEqual(ctx.frontendFramework, DEFAULT_STACK_CONTEXT.frontendFramework);
  assert.ok(ctx.rawMarkdown !== null);
});

test('ProjectStackContext: getProjectStackContext on missing path returns defaults with source="default"', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gsd-stack-ctx-'));
  const ctx = await getProjectStackContext(dir);
  assert.strictEqual(ctx.source, 'default');
  assert.strictEqual(ctx.backendFramework, 'net8.0');
  assert.strictEqual(ctx.rawMarkdown, null);
});

test('ProjectStackContext: getProjectStackContext on real override file parses correctly', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gsd-stack-ctx-'));
  const gsdDir = path.join(dir, 'docs', 'gsd');
  fs.mkdirSync(gsdDir, { recursive: true });
  fs.copyFileSync(path.join(FIXTURES_DIR, 'net9-full.md'), path.join(gsdDir, 'stack-overrides.md'));
  const ctx = await getProjectStackContext(dir);
  assert.strictEqual(ctx.source, 'override');
  assert.strictEqual(ctx.backendFramework, 'net9.0');
  assert.ok(ctx.resolvedFromPath?.endsWith('stack-overrides.md'));
});

test('ProjectStackContext: normalizeFramework tolerates multiple input forms', () => {
  assert.strictEqual(normalizeFramework('.NET 9'), 'net9.0');
  assert.strictEqual(normalizeFramework('net9.0'), 'net9.0');
  assert.strictEqual(normalizeFramework('net9'), 'net9.0');
  assert.strictEqual(normalizeFramework('.net9'), 'net9.0');
  assert.strictEqual(normalizeFramework('NET9'), 'net9.0');
  assert.strictEqual(normalizeFramework('.NET 10'), 'net10.0');
  assert.strictEqual(normalizeFramework('net8.0'), 'net8.0');
  assert.strictEqual(normalizeFramework('unknown-framework'), 'unknown-framework');
});

test('ProjectStackContext: renderStackContextBlock includes PROJECT STACK CONTEXT header + framework', () => {
  const md = fs.readFileSync(path.join(FIXTURES_DIR, 'net9-full.md'), 'utf8');
  const ctx = parseStackOverrides(md);
  const block = renderStackContextBlock(ctx);
  assert.ok(block.includes('--- PROJECT STACK CONTEXT ---'));
  assert.ok(block.includes('net9.0'));
  assert.ok(block.includes('--- END STACK CONTEXT ---'));
  assert.ok(block.includes('Source: override'));
});

// ── v6.1.0: Stack Leak Validator ─────────────────────────
test('StackLeakValidator: flags forbidden framework in csproj when context declares net9', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gsd-leak-'));
  fs.writeFileSync(path.join(dir, 'App.csproj'), '<Project><PropertyGroup><TargetFramework>net8.0</TargetFramework></PropertyGroup></Project>');
  const ctx = parseStackOverrides(fs.readFileSync(path.join(FIXTURES_DIR, 'net9-full.md'), 'utf8'));
  const report = await validateStackLeaks({ projectRoot: dir, context: ctx });
  assert.ok(report.findings.length > 0, 'expected at least one finding');
  const leak = report.findings[0];
  assert.strictEqual(leak.found, 'net8.0');
  assert.strictEqual(leak.expected, 'net9.0');
  assert.strictEqual(leak.leakKind, 'backend-framework');
});

test('StackLeakValidator: no findings when artifact matches declared framework', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gsd-leak-'));
  fs.writeFileSync(path.join(dir, 'App.csproj'), '<Project><PropertyGroup><TargetFramework>net9.0</TargetFramework></PropertyGroup></Project>');
  const ctx = parseStackOverrides(fs.readFileSync(path.join(FIXTURES_DIR, 'net9-full.md'), 'utf8'));
  const report = await validateStackLeaks({ projectRoot: dir, context: ctx });
  assert.strictEqual(report.findings.length, 0);
  assert.strictEqual(report.filesScanned >= 1, true);
});

test('StackLeakValidator: skips migration/legacy context (false-positive filter)', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gsd-leak-'));
  fs.writeFileSync(
    path.join(dir, 'UPGRADE.md'),
    [
      '# Upgrade notes',
      '',
      '- migration: moving from net8.0 to net9.0',
      '- legacy net8.0 builds remain archived',
      '- previously targeted net8.0',
      '- > (was net8.0)',
      '',
    ].join('\n'),
  );
  const ctx = parseStackOverrides(fs.readFileSync(path.join(FIXTURES_DIR, 'net9-full.md'), 'utf8'));
  const report = await validateStackLeaks({ projectRoot: dir, context: ctx });
  assert.strictEqual(report.findings.length, 0, 'migration prose must not be flagged');
});

test('StackLeakValidator: respects ignore dirs (node_modules, .git, etc.)', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gsd-leak-'));
  const nm = path.join(dir, 'node_modules', 'pkg');
  fs.mkdirSync(nm, { recursive: true });
  fs.writeFileSync(path.join(nm, 'leak.csproj'), '<TargetFramework>net8.0</TargetFramework>');
  const ctx = parseStackOverrides(fs.readFileSync(path.join(FIXTURES_DIR, 'net9-full.md'), 'utf8'));
  const report = await validateStackLeaks({ projectRoot: dir, context: ctx });
  assert.strictEqual(report.findings.length, 0, 'node_modules must be skipped');
});

test('StackLeakValidator: formatStackLeakReport renders "No stack leaks detected" on empty', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gsd-leak-'));
  const ctx = parseStackOverrides(fs.readFileSync(path.join(FIXTURES_DIR, 'net9-full.md'), 'utf8'));
  const report = await validateStackLeaks({ projectRoot: dir, context: ctx });
  const rendered = formatStackLeakReport(report);
  assert.ok(rendered.includes('No stack leaks detected'));
});

// ── Runner ───────────────────────────────────────────────
async function main(): Promise<void> {
  let passed = 0;
  let failed = 0;
  const failures: Array<{ name: string; error: string }> = [];

  console.log(`\nRunning ${tests.length} V6 unit tests...\n`);

  for (const t of tests) {
    try {
      await t.run();
      console.log(`  PASS  ${t.name}`);
      passed++;
    } catch (e) {
      console.log(`  FAIL  ${t.name}`);
      console.log(`         ${(e as Error).message}`);
      failures.push({ name: t.name, error: (e as Error).message });
      failed++;
    }
  }

  console.log(`\n${passed} passed, ${failed} failed\n`);
  if (failed > 0) {
    console.log('Failures:');
    for (const f of failures) console.log(`  - ${f.name}: ${f.error}`);
    process.exit(1);
  }
}

main().catch((e) => {
  console.error('test runner crashed:', e);
  process.exit(2);
});
