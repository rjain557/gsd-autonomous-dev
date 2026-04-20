// ═══════════════════════════════════════════════════════════
// GSD V6 — Execution Graph Scheduler
// Dependency-aware task scheduler. Runs independent tasks in
// parallel up to a concurrency limit.
// ═══════════════════════════════════════════════════════════

import type { Task, TaskId, TaskStatus, ExecutionPlan } from './types';

export interface TaskRunResult {
  taskId: TaskId;
  status: 'complete' | 'failed' | 'stuck';
  error?: Error;
  outputHash?: string;
}

export type TaskRunner = (task: Task) => Promise<TaskRunResult>;

export interface ExecutionGraphOptions {
  concurrency?: number;
  stopOnFailure?: boolean;
}

export class ExecutionGraph {
  /** Compute which tasks can run now vs are blocked. */
  static computePlan(tasks: Task[]): ExecutionPlan {
    const byId = new Map<TaskId, Task>();
    for (const t of tasks) byId.set(t.id, t);

    const plan: ExecutionPlan = { ready: [], running: [], blocked: [], complete: [], failed: [] };

    for (const t of tasks) {
      if (t.status === 'complete') {
        plan.complete.push(t.id);
        continue;
      }
      if (t.status === 'failed') {
        plan.failed.push(t.id);
        continue;
      }
      if (t.status === 'running') {
        plan.running.push(t.id);
        continue;
      }
      // pending/stuck/skipped: check deps
      const depsSatisfied = t.dependsOnTaskIds.every((depId) => {
        const dep = byId.get(depId);
        return dep && dep.status === 'complete';
      });
      const depsFailed = t.dependsOnTaskIds.some((depId) => {
        const dep = byId.get(depId);
        return dep && dep.status === 'failed';
      });
      if (depsFailed) {
        plan.blocked.push(t.id);
      } else if (depsSatisfied) {
        plan.ready.push(t.id);
      } else {
        plan.blocked.push(t.id);
      }
    }
    return plan;
  }

  /** Detect cycles using DFS. Returns array of task IDs forming cycles. */
  static detectCycles(tasks: Task[]): TaskId[][] {
    const byId = new Map<TaskId, Task>();
    for (const t of tasks) byId.set(t.id, t);

    const WHITE = 0, GRAY = 1, BLACK = 2;
    const color = new Map<TaskId, number>();
    for (const t of tasks) color.set(t.id, WHITE);

    const cycles: TaskId[][] = [];
    const stack: TaskId[] = [];

    const visit = (id: TaskId): void => {
      color.set(id, GRAY);
      stack.push(id);
      const task = byId.get(id);
      if (task) {
        for (const dep of task.dependsOnTaskIds) {
          const c = color.get(dep);
          if (c === GRAY) {
            const cycleStart = stack.indexOf(dep);
            if (cycleStart >= 0) cycles.push(stack.slice(cycleStart).concat(dep));
          } else if (c === WHITE) {
            visit(dep);
          }
        }
      }
      color.set(id, BLACK);
      stack.pop();
    };

    for (const t of tasks) {
      if (color.get(t.id) === WHITE) visit(t.id);
    }
    return cycles;
  }

  /**
   * Run all tasks respecting dependencies.
   * Updates task.status via the runner's returned result.
   * Returns final set of tasks with terminal statuses filled.
   */
  static async runGraph(
    tasks: Task[],
    runner: TaskRunner,
    options: ExecutionGraphOptions = {},
  ): Promise<Map<TaskId, TaskRunResult>> {
    const concurrency = options.concurrency ?? 2;
    const stopOnFailure = options.stopOnFailure ?? false;

    const cycles = ExecutionGraph.detectCycles(tasks);
    if (cycles.length > 0) {
      throw new Error(`Dependency cycles detected: ${cycles.map((c) => c.join(' -> ')).join('; ')}`);
    }

    const results = new Map<TaskId, TaskRunResult>();
    const taskMap = new Map<TaskId, Task>();
    for (const t of tasks) taskMap.set(t.id, { ...t });

    let halted = false;

    while (true) {
      const snapshot = Array.from(taskMap.values());
      const plan = ExecutionGraph.computePlan(snapshot);

      if (halted) break;
      if (plan.ready.length === 0 && plan.running.length === 0) break;

      // Launch up to `concurrency` new tasks
      const currentlyRunning = plan.running.length;
      const slotsAvailable = Math.max(0, concurrency - currentlyRunning);
      const toLaunch = plan.ready.slice(0, slotsAvailable);

      if (toLaunch.length === 0 && plan.running.length === 0) break;

      const launched = toLaunch.map(async (taskId) => {
        const task = taskMap.get(taskId);
        if (!task) return;
        const runningTask: Task = { ...task, status: 'running' as TaskStatus };
        taskMap.set(taskId, runningTask);
        try {
          const result = await runner(runningTask);
          const finalTask: Task = { ...runningTask, status: result.status };
          taskMap.set(taskId, finalTask);
          results.set(taskId, result);
          if (result.status === 'failed' && stopOnFailure) halted = true;
        } catch (err) {
          const failedTask: Task = { ...runningTask, status: 'failed' as TaskStatus };
          taskMap.set(taskId, failedTask);
          results.set(taskId, { taskId, status: 'failed', error: err as Error });
          if (stopOnFailure) halted = true;
        }
      });

      await Promise.all(launched);
    }

    return results;
  }
}
