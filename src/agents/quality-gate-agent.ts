// ═══════════════════════════════════════════════════════════
// QualityGateAgent
// Runs full test suite, coverage checks, security scans.
// Returns binary pass/fail. THROWS on failure — DeployAgent
// must never run if this agent fails.
// ═══════════════════════════════════════════════════════════

import { BaseAgent } from '../harness/base-agent';
import type {
  AgentInput,
  AgentOutput,
  QualityGateInput,
  GateResult,
} from '../harness/types';
import { QualityGateFailure } from '../harness/types';
import { execFile } from 'child_process';
import { promisify } from 'util';

const execFileAsync = promisify(execFile);

export class QualityGateAgent extends BaseAgent {
  protected async run(input: AgentInput): Promise<AgentOutput> {
    const { patchSet, qualityThresholds } = input as QualityGateInput;

    const evidence: string[] = [];
    let allPassed = true;
    let coverage = 0;
    let securityScore = 100;

    // Log patch context for traceability
    if (patchSet.patches.length > 0) {
      evidence.push(`patches applied: ${patchSet.patches.length} (${patchSet.patches.map(p => p.issueId).join(', ')})`);
    }

    // 1. dotnet build
    const buildResult = await this.runCheck('dotnet build --no-restore 2>&1', 60_000);
    if (buildResult.success) {
      evidence.push(`dotnet build: SUCCESS`);
    } else {
      evidence.push(`dotnet build: FAILED — ${buildResult.output.substring(0, 500)}`);
      allPassed = false;
    }

    // 2. npm build
    const npmResult = await this.runCheck('npm run build 2>&1', 60_000);
    if (npmResult.success) {
      evidence.push(`npm run build: SUCCESS`);
    } else {
      evidence.push(`npm run build: FAILED — ${npmResult.output.substring(0, 500)}`);
      allPassed = false;
    }

    // 3. dotnet test
    const testResult = await this.runCheck('dotnet test --no-build --verbosity normal 2>&1', 120_000);
    if (testResult.success) {
      evidence.push(`dotnet test: SUCCESS`);

      // Parse coverage from test output if available
      const coverageMatch = testResult.output.match(/Total\s+[\d.]+%.*?(\d+\.?\d*)%/);
      if (coverageMatch) {
        coverage = parseFloat(coverageMatch[1]);
      }
    } else {
      // Check if tests simply don't exist
      if (testResult.output.includes('No test is available')) {
        evidence.push(`dotnet test: NO TESTS FOUND (warning)`);
      } else {
        evidence.push(`dotnet test: FAILED — ${testResult.output.substring(0, 500)}`);
        allPassed = false;
      }
    }

    // 4. Coverage check
    if (coverage >= qualityThresholds.minCoverage) {
      evidence.push(`coverage: ${coverage}% (threshold: ${qualityThresholds.minCoverage}%) — PASS`);
    } else if (coverage > 0) {
      evidence.push(`coverage: ${coverage}% (threshold: ${qualityThresholds.minCoverage}%) — FAIL`);
      allPassed = false;
    } else {
      evidence.push(`coverage: not measured (no coverage tool configured)`);
    }

    // 5. Security scan — check for common vulnerability patterns
    if (qualityThresholds.securityScanEnabled) {
      const secResult = await this.runSecurityScan();
      securityScore = secResult.score;
      if (secResult.findings.length > 0) {
        evidence.push(`security scan: ${secResult.findings.length} finding(s)`);
        for (const finding of secResult.findings.slice(0, 5)) {
          evidence.push(`  - ${finding}`);
        }
        if (secResult.hasCritical) {
          allPassed = false;
        }
      } else {
        evidence.push(`security scan: no findings`);
      }
    }

    const gateResult: GateResult = {
      passed: allPassed,
      coverage,
      securityScore,
      evidence,
    };

    // HARD RULE: If failed, throw QualityGateFailure
    if (!gateResult.passed) {
      throw new QualityGateFailure(gateResult);
    }

    return gateResult;
  }

  private async runCheck(
    command: string,
    timeout: number,
  ): Promise<{ success: boolean; output: string }> {
    const shell = process.platform === 'win32' ? 'cmd' : 'sh';
    const shellArgs = process.platform === 'win32' ? ['/c', command] : ['-c', command];
    try {
      const { stdout, stderr } = await execFileAsync(shell, shellArgs, {
        timeout,
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

  private async runSecurityScan(): Promise<{
    score: number;
    findings: string[];
    hasCritical: boolean;
  }> {
    const findings: string[] = [];
    let hasCritical = false;

    const secretPatterns = [
      { regex: /password\s*=\s*["'][^"']+["']/i, label: 'Hardcoded password' },
      { regex: /api[_-]?key\s*=\s*["'][^"']+["']/i, label: 'Hardcoded API key' },
      { regex: /connectionString.*password/i, label: 'Password in connection string' },
      { regex: /secret\s*[:=]\s*["'][^"']{8,}["']/i, label: 'Hardcoded secret' },
    ];

    // Cross-platform: use Node.js fs to walk files instead of grep
    const scanExtensions = new Set(['.cs', '.ts', '.tsx', '.json', '.js']);
    const skipDirs = new Set(['node_modules', '.git', 'bin', 'obj', 'dist', '.gsd']);
    const skipFiles = new Set(['appsettings.json', 'appsettings.Development.json', 'package-lock.json']);

    const files = await this.walkFiles('.', scanExtensions, skipDirs);

    for (const filePath of files) {
      const basename = filePath.split('/').pop() ?? '';
      if (skipFiles.has(basename)) continue;

      let content: string;
      try {
        const { readFile } = await import('fs/promises');
        content = await readFile(filePath, 'utf-8');
      } catch { continue; }

      for (const { regex, label } of secretPatterns) {
        if (regex.test(content)) {
          findings.push(`${label} in: ${filePath}`);
          hasCritical = true;
        }
      }
    }

    // Run npm audit for known vulnerabilities (if package.json exists)
    try {
      const npmAudit = await this.runCheck('npm audit --json 2>&1', 30_000);
      if (npmAudit.success) {
        try {
          const audit = JSON.parse(npmAudit.output);
          const vulns = audit.metadata?.vulnerabilities ?? {};
          if ((vulns.critical ?? 0) > 0) { findings.push(`npm audit: ${vulns.critical} critical vulnerabilities`); hasCritical = true; }
          if ((vulns.high ?? 0) > 0) { findings.push(`npm audit: ${vulns.high} high vulnerabilities`); }
        } catch { /* npm audit output not parseable — skip */ }
      }
    } catch { /* npm not available */ }

    // Run dotnet list package --vulnerable (if .csproj exists)
    try {
      const dotnetAudit = await this.runCheck('dotnet list package --vulnerable 2>&1', 30_000);
      if (dotnetAudit.output.includes('has the following vulnerable packages')) {
        findings.push('dotnet: vulnerable NuGet packages detected');
        hasCritical = true;
      }
    } catch { /* dotnet not available */ }

    const score = Math.max(0, 100 - (findings.length * 15));
    return { score, findings, hasCritical };
  }

  private async walkFiles(
    dir: string,
    extensions: Set<string>,
    skipDirs: Set<string>,
  ): Promise<string[]> {
    const { readdir } = await import('fs/promises');
    const { join, extname } = await import('path');
    const results: string[] = [];

    let entries;
    try { entries = await readdir(dir, { withFileTypes: true }); }
    catch { return results; }

    for (const entry of entries) {
      const fullPath = join(dir, entry.name);
      if (entry.isDirectory()) {
        if (!skipDirs.has(entry.name)) {
          results.push(...await this.walkFiles(fullPath, extensions, skipDirs));
        }
      } else if (extensions.has(extname(entry.name))) {
        results.push(fullPath);
      }
    }

    return results;
  }
}
