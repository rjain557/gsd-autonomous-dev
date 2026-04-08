// ═══════════════════════════════════════════════════════════
// CodeReviewAgent
// Analyzes code against ConvergenceReport. Checks correctness,
// security, style, test coverage. Read-only — never modifies code.
// ═══════════════════════════════════════════════════════════

import { BaseAgent } from '../harness/base-agent';
import type {
  AgentInput,
  AgentOutput,
  CodeReviewInput,
  ReviewResult,
  Issue,
} from '../harness/types';
import { execFile } from 'child_process';
import { promisify } from 'util';

const execFileAsync = promisify(execFile);

export class CodeReviewAgent extends BaseAgent {
  protected async run(input: AgentInput): Promise<AgentOutput> {
    const { convergenceReport, changedFiles, qualityGates } = input as CodeReviewInput;

    // Run build checks
    const buildResult = await this.runBuildChecks();

    // Run lint/test commands (read-only)
    const testResult = await this.runTests();

    // Ask LLM to review code against convergence report
    const systemPrompt = await this.buildSystemPrompt();

    const userMessage = [
      '## Convergence Report',
      '',
      '```json',
      JSON.stringify(convergenceReport, null, 2).substring(0, 3000),
      '```',
      '',
      '## Changed Files',
      '',
      changedFiles.slice(0, 50).join('\n'),
      '',
      '## Build Results',
      '',
      `dotnet build: ${buildResult.dotnet.success ? 'PASS' : 'FAIL'}`,
      buildResult.dotnet.output.substring(0, 1000),
      '',
      `npm build: ${buildResult.npm.success ? 'PASS' : 'FAIL'}`,
      buildResult.npm.output.substring(0, 1000),
      '',
      '## Test Results',
      '',
      `Tests: ${testResult.success ? 'PASS' : 'FAIL'}`,
      testResult.output.substring(0, 1000),
      '',
      '## Quality Gate Thresholds',
      '',
      `Min coverage: ${qualityGates.minCoverage}%`,
      `Block on critical: ${qualityGates.blockOnCritical}`,
      '',
      '## Instructions',
      '',
      'Review the code changes against the convergence report.',
      'Return a JSON ReviewResult with: passed (boolean), issues (array), coveragePercent (number), securityFlags (array).',
      'Each issue: { id, file, line, severity, category, message, suggestedFix }.',
      'Set passed=true ONLY if zero critical/high issues AND coverage >= threshold.',
      'Return ONLY valid JSON.',
    ].join('\n');

    const reviewSchema = {
      type: 'object' as const,
      properties: {
        passed: { type: 'boolean' },
        issues: {
          type: 'array',
          items: {
            type: 'object',
            properties: {
              id: { type: 'string' },
              file: { type: 'string' },
              line: { type: 'number' },
              severity: { type: 'string', enum: ['low', 'medium', 'high', 'critical'] },
              category: { type: 'string', enum: ['correctness', 'security', 'style', 'coverage', 'convergence'] },
              message: { type: 'string' },
              suggestedFix: { type: 'string' },
            },
            required: ['id', 'file', 'severity', 'category', 'message'],
          },
        },
        coveragePercent: { type: 'number' },
        securityFlags: { type: 'array', items: { type: 'string' } },
      },
      required: ['passed', 'issues', 'coveragePercent', 'securityFlags'],
    };

    const response = await this.callLLM(systemPrompt, userMessage, reviewSchema);
    return this.parseReviewResult(response, buildResult, testResult, qualityGates);
  }

  private async runBuildChecks(): Promise<{
    dotnet: { success: boolean; output: string };
    npm: { success: boolean; output: string };
  }> {
    const dotnet = await this.safeExec('dotnet build --no-restore 2>&1');
    const npm = await this.safeExec('npm run build 2>&1');
    return { dotnet, npm };
  }

  private async runTests(): Promise<{ success: boolean; output: string }> {
    return this.safeExec('dotnet test --no-build --verbosity normal 2>&1');
  }

  private async safeExec(cmd: string): Promise<{ success: boolean; output: string }> {
    const shell = process.platform === 'win32' ? 'cmd' : 'sh';
    const shellArgs = process.platform === 'win32' ? ['/c', cmd] : ['-c', cmd];
    try {
      const { stdout, stderr } = await execFileAsync(shell, shellArgs, {
        timeout: 60_000,
        maxBuffer: 5 * 1024 * 1024,
      });
      return { success: true, output: (stdout + '\n' + stderr).trim() };
    } catch (err: unknown) {
      const error = err as { stdout?: string; stderr?: string; message?: string };
      return {
        success: false,
        output: ((error.stdout ?? '') + '\n' + (error.stderr ?? '') + '\n' + (error.message ?? '')).trim(),
      };
    }
  }

  private parseReviewResult(
    llmResponse: string,
    buildResult: { dotnet: { success: boolean }; npm: { success: boolean } },
    testResult: { success: boolean },
    qualityGates: { minCoverage: number; blockOnCritical: boolean },
  ): ReviewResult {
    const issues: Issue[] = [];

    // Add build failures as critical issues
    if (!buildResult.dotnet.success) {
      issues.push({
        id: 'BUILD-DOTNET-001',
        file: '*.csproj',
        line: 0,
        severity: 'critical',
        category: 'correctness',
        message: 'dotnet build failed',
      });
    }
    if (!buildResult.npm.success) {
      issues.push({
        id: 'BUILD-NPM-001',
        file: 'package.json',
        line: 0,
        severity: 'critical',
        category: 'correctness',
        message: 'npm build failed',
      });
    }

    // Parse LLM response — extractJSON throws on failure so retry logic engages
    const parsed = this.extractJSON<Record<string, unknown>>(llmResponse);

    if (Array.isArray(parsed.issues)) {
      for (const issue of parsed.issues as Record<string, unknown>[]) {
        issues.push({
          id: String(issue.id ?? `LLM-${issues.length}`),
          file: String(issue.file ?? 'unknown'),
          line: Number(issue.line ?? 0),
          severity: (issue.severity as Issue['severity']) ?? 'medium',
          category: (issue.category as Issue['category']) ?? 'correctness',
          message: String(issue.message ?? ''),
          suggestedFix: issue.suggestedFix as string | undefined,
        });
      }
    }

    const coveragePercent = Number(parsed.coveragePercent ?? 0);
    const securityFlags = Array.isArray(parsed.securityFlags) ? parsed.securityFlags as string[] : [];
    const hasCritical = issues.some(i => i.severity === 'critical' || i.severity === 'high');
    const coverageMet = coveragePercent >= qualityGates.minCoverage;

    return {
      passed: !hasCritical && coverageMet,
      issues,
      coveragePercent,
      securityFlags,
    };
  }
}
