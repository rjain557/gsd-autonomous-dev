// ═══════════════════════════════════════════════════════════
// DeployAgent
// Executes alpha deploy sequence. Only runs if QualityGateAgent
// passes. Reads config from vault. Rolls back on any failure.
// ═══════════════════════════════════════════════════════════

import { BaseAgent } from '../harness/base-agent';
import type {
  AgentInput,
  AgentOutput,
  DeployInput,
  DeployRecord,
  StepResult,
} from '../harness/types';
import { HardGateViolation } from '../harness/types';
import { execFile } from 'child_process';
import { promisify } from 'util';
import * as fs from 'fs/promises';
import * as path from 'path';
import * as http from 'http';
import * as https from 'https';

const execFileAsync = promisify(execFile);

export class DeployAgent extends BaseAgent {
  protected async run(input: AgentInput): Promise<AgentOutput> {
    const { gateResult, deployConfig, commitSha } = input as DeployInput;

    // ── HARD GATE ASSERTION ──
    if (!gateResult.passed) {
      throw new HardGateViolation(
        `DeployAgent received GateResult.passed=${gateResult.passed}. ` +
        `REFUSING TO DEPLOY. This is a pipeline integrity violation.`
      );
    }

    // ── Verify rollback procedure exists BEFORE deploying ──
    let rollbackNote;
    try {
      rollbackNote = await this.vaultAdapter.read('knowledge/rollback-procedures.md');
    } catch {
      throw new Error(
        'Rollback procedure not found at knowledge/rollback-procedures.md. ' +
        'REFUSING TO DEPLOY — rollback must exist before deploy logic.'
      );
    }

    // ── Fire deploy start hook ──
    await this.hooks.fire('onDeployStart', {
      runId: this.state.runId,
      agentId: this.agentId,
      state: this.state,
    });

    const steps: StepResult[] = [];
    let rollbackExecuted = false;

    try {
      // Step 1: Create deploy snapshot
      steps.push(await this.executeStep('create-snapshot', async () => {
        const tag = `deploy-${deployConfig.environment}-${new Date().toISOString().split('T')[0]}`;
        await this.safeExec(`git tag ${tag}`);
        return `Tagged ${tag}`;
      }));
      this.checkStepSuccess(steps);

      // Step 2: Build release artifacts
      steps.push(await this.executeStep('build-release', async () => {
        const result = await this.safeExec('dotnet publish -c Release -o ./publish');
        return result.output.substring(0, 500);
      }));
      this.checkStepSuccess(steps);

      // Step 3: Build frontend
      steps.push(await this.executeStep('build-frontend', async () => {
        const result = await this.safeExec('npm run build');
        return result.output.substring(0, 500);
      }));
      this.checkStepSuccess(steps);

      // Step 4: Copy to deploy target (cross-platform: uses Node fs.cp, not xcopy)
      steps.push(await this.executeStep('copy-artifacts', async () => {
        const target = deployConfig.target;
        const source = path.resolve('./publish');
        await fs.cp(source, target, { recursive: true, force: true });
        return `Copied ${source} to ${target}`;
      }));
      this.checkStepSuccess(steps);

      // Step 5: Health check (cross-platform: uses Node http/https, not curl)
      steps.push(await this.executeStep('health-check', async () => {
        // Support both http and https targets. If target already has protocol, use it.
        const target = deployConfig.target;
        const url = target.startsWith('http')
          ? `${target}${deployConfig.healthEndpoint}`
          : `http://${target}${deployConfig.healthEndpoint}`;
        const statusCode = await this.httpGet(url);
        if (statusCode !== 200) {
          throw new Error(`Health check failed: ${url} returned HTTP ${statusCode}`);
        }
        return `GET ${url} -> 200 OK`;
      }));
      this.checkStepSuccess(steps);

    } catch (err) {
      // ── ROLLBACK ON ANY FAILURE ──
      console.error(`[DEPLOY] Step failed — executing rollback`);

      const rollbackStep = await this.executeStep('rollback', async () => {
        // Execute rollback from vault procedure
        return await this.executeRollback(rollbackNote.body);
      });
      steps.push(rollbackStep);
      rollbackExecuted = true;

      const record: DeployRecord = {
        success: false,
        environment: deployConfig.environment,
        commitSha,
        deployedAt: new Date().toISOString(),
        steps,
        rollbackExecuted,
      };

      // Fire rollback hook
      await this.hooks.fire('onDeployRollback', {
        runId: this.state.runId,
        agentId: this.agentId,
        output: record,
        error: err instanceof Error ? err : new Error(String(err)),
        state: this.state,
      });

      return record;
    }

    // ── SUCCESS ──
    const record: DeployRecord = {
      success: true,
      environment: deployConfig.environment,
      commitSha,
      deployedAt: new Date().toISOString(),
      steps,
      rollbackExecuted: false,
    };

    // Fire deploy complete hook
    await this.hooks.fire('onDeployComplete', {
      runId: this.state.runId,
      agentId: this.agentId,
      output: record,
      state: this.state,
    });

    return record;
  }

  private async executeStep(
    name: string,
    fn: () => Promise<string>,
  ): Promise<StepResult> {
    const start = Date.now();
    try {
      const output = await fn();
      return {
        name,
        success: true,
        output,
        durationMs: Date.now() - start,
      };
    } catch (err) {
      return {
        name,
        success: false,
        output: err instanceof Error ? err.message : String(err),
        durationMs: Date.now() - start,
      };
    }
  }

  private checkStepSuccess(steps: StepResult[]): void {
    const last = steps[steps.length - 1];
    if (last && !last.success) {
      throw new Error(`Deploy step "${last.name}" failed: ${last.output}`);
    }
  }

  private async executeRollback(rollbackBody: string): Promise<string> {
    const commands = rollbackBody
      .match(/```[\s\S]*?```/g)
      ?.map(block => block.replace(/```\w*/g, '').trim())
      .filter(cmd => cmd.length > 0) ?? [];

    if (commands.length === 0) {
      return 'WARNING: No rollback commands found in procedure markdown';
    }

    const results: string[] = [];

    for (const cmd of commands) {
      try {
        // Use execFile with shell to avoid injection, but allow shell syntax
        const { stdout } = await execFileAsync(
          process.platform === 'win32' ? 'cmd' : 'sh',
          process.platform === 'win32' ? ['/c', cmd] : ['-c', cmd],
          { timeout: 60_000 },
        );
        results.push(`OK: ${cmd.substring(0, 80)}`);
      } catch (err) {
        // STOP on first failure — partial rollback leaves system in undefined state
        results.push(`FAILED: ${cmd.substring(0, 80)} — ${err instanceof Error ? err.message : String(err)}`);
        results.push(`HALTED: Rollback stopped at failed step. ${commands.length - results.length + 1} steps remaining.`);
        results.push(`ESCALATION REQUIRED: Manual intervention needed to complete rollback.`);
        break;
      }
    }

    return results.join('\n');
  }

  private async safeExec(cmd: string): Promise<{ output: string }> {
    try {
      const { stdout } = await execFileAsync(
        process.platform === 'win32' ? 'cmd' : 'sh',
        process.platform === 'win32' ? ['/c', cmd] : ['-c', cmd],
        { timeout: 60_000 },
      );
      return { output: stdout.trim() };
    } catch (err: unknown) {
      const error = err as { stdout?: string; message?: string };
      throw new Error((error.stdout ?? error.message ?? 'unknown error').substring(0, 500));
    }
  }

  private httpGet(url: string): Promise<number> {
    const client = url.startsWith('https') ? https : http;
    return new Promise((resolve, reject) => {
      const req = client.get(url, { timeout: 10_000 }, (res) => {
        resolve(res.statusCode ?? 0);
        res.resume(); // drain response
      });
      req.on('error', reject);
      req.on('timeout', () => { req.destroy(); reject(new Error('Health check timed out')); });
    });
  }
}
