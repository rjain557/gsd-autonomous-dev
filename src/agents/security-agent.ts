// ═══════════════════════════════════════════════════════════
// SecurityAgent
// Security-engineer-of-record for the GSD pipeline. Replaces
// the human senior security engineer hire from myJian §10.15.
// Read-only — flags findings, never modifies code. Signoff on
// security-critical paths is BINDING (QualityGate fails without it).
// ═══════════════════════════════════════════════════════════

import { BaseAgent } from '../harness/base-agent';
import type {
  AgentInput,
  AgentOutput,
  SecurityAgentInput,
  SecurityReviewResult,
  SecurityFinding,
  SignatoryAction,
  ThreatModelDelta,
} from '../harness/types';
import { execFile } from 'child_process';
import { promisify } from 'util';

const execFileAsync = promisify(execFile);

export class SecurityAgent extends BaseAgent {
  protected async run(input: AgentInput): Promise<AgentOutput> {
    const { convergenceReport, changedFiles, patchSet, securityCriticalPaths } = input as SecurityAgentInput;

    // Run static analysis + SCA in parallel before LLM review
    const [semgrepResult, scaResult, codeqlResult] = await Promise.all([
      this.runSemgrep(),
      this.runScaScan(),
      this.runCodeQL(),
    ]);

    // Classify changed files: are any in security-critical paths?
    const criticalPathHits = changedFiles.filter(f =>
      securityCriticalPaths.some(p => f.includes(p) || this.matchesPattern(f, p))
    );

    const systemPrompt = await this.buildSystemPrompt();

    const userMessage = [
      '## Convergence Report',
      '```json',
      JSON.stringify(convergenceReport, null, 2).substring(0, 2000),
      '```',
      '',
      '## Changed Files',
      changedFiles.join('\n'),
      '',
      '## Security-Critical Path Hits',
      criticalPathHits.length === 0 ? '(none — advisory mode for this PR)' : criticalPathHits.join('\n'),
      '',
      '## Patch Set',
      patchSet ? `${patchSet.patches.length} patches pending` : '(no patches — pre-remediation review)',
      '',
      '## Static Analysis — Semgrep',
      semgrepResult.output.substring(0, 3000),
      '',
      '## Supply Chain — SCA',
      `npm audit critical: ${scaResult.npmAuditCritical}, high: ${scaResult.npmAuditHigh}`,
      `dotnet vulnerable packages: ${scaResult.dotnetVulnCount}`,
      `deny-list licenses found: ${scaResult.denyListLicenses.join(', ') || '(none)'}`,
      '',
      '## CodeQL',
      codeqlResult.available ? codeqlResult.output.substring(0, 2000) : '(CodeQL not available in this env)',
      '',
      '## Instructions',
      '',
      'Perform THREE passes:',
      '1. **Static analysis surface**: aggregate Semgrep + CodeQL + SCA findings by file. Group by CWE.',
      '2. **Security-critical path review**: for any file in the critical-paths list, do an explicit second look for the patterns listed in your system prompt (TLS verify=false, secret-in-log, race conditions, off-by-one in allow-list, timing side-channel, missing rate limits, deserialization, path traversal, SQL injection, missing audit-log, HSM-bypass).',
      '3. **Threat-model delta**: identify whether the PR changes any STRIDE assumption / attack surface / trust boundary.',
      '',
      'Return a JSON SecurityReviewResult with fields: signoffGranted (boolean), findings (array), threatModelDelta (object|null), scaResults (object), signatoryActions (array), evidence (array of strings).',
      '',
      'Set signoffGranted=true ONLY if: zero critical findings, zero high findings on security-critical paths, threat-model delta either nil or has remediation patch ready, no deny-list licenses.',
      '',
      'Output ONLY valid JSON.',
    ].join('\n');

    const schema = {
      type: 'object' as const,
      properties: {
        signoffGranted: { type: 'boolean' },
        findings: {
          type: 'array',
          items: {
            type: 'object',
            properties: {
              id: { type: 'string' },
              file: { type: 'string' },
              line: { type: 'number' },
              severity: { type: 'string', enum: ['low', 'medium', 'high', 'critical'] },
              category: { type: 'string', enum: ['static-analysis', 'secret-leak', 'crypto', 'auth', 'sandbox-escape', 'supply-chain', 'threat-model-delta', 'hsm-bypass', 'audit-gap'] },
              cwe: { type: 'string' },
              message: { type: 'string' },
              suggestedRemediation: { type: 'string' },
              securityCriticalPath: { type: 'boolean' },
            },
            required: ['id', 'file', 'severity', 'category', 'message', 'suggestedRemediation', 'securityCriticalPath'],
          },
        },
        threatModelDelta: {
          type: ['object', 'null'],
        },
        signatoryActions: {
          type: 'array',
          items: { type: 'object' },
        },
        evidence: { type: 'array', items: { type: 'string' } },
      },
      required: ['signoffGranted', 'findings', 'signatoryActions', 'evidence'],
    };

    const response = await this.callLLM(systemPrompt, userMessage, schema);
    return this.parseResult(response, scaResult, criticalPathHits.length > 0);
  }

  private async runSemgrep(): Promise<{ available: boolean; output: string }> {
    const result = await this.safeExec('semgrep --config p/security-audit --config p/owasp-top-ten --config p/secrets --json --timeout 120 . 2>&1');
    if (!result.success && /command not found|is not recognized/i.test(result.output)) {
      return { available: false, output: 'semgrep not installed' };
    }
    return { available: true, output: result.output };
  }

  private async runCodeQL(): Promise<{ available: boolean; output: string }> {
    const result = await this.safeExec('codeql --version 2>&1');
    if (!result.success) {
      return { available: false, output: 'codeql not available' };
    }
    return { available: true, output: 'codeql available — db build skipped in agent run (use offline tooling)' };
  }

  private async runScaScan(): Promise<{
    npmAuditCritical: number;
    npmAuditHigh: number;
    dotnetVulnCount: number;
    denyListLicenses: string[];
  }> {
    const [npmRes, dotnetRes] = await Promise.all([
      this.safeExec('npm audit --json 2>&1'),
      this.safeExec('dotnet list package --vulnerable 2>&1'),
    ]);

    let npmCritical = 0;
    let npmHigh = 0;
    try {
      const parsed = JSON.parse(npmRes.output);
      const meta = (parsed?.metadata?.vulnerabilities ?? {}) as Record<string, number>;
      npmCritical = Number(meta.critical ?? 0);
      npmHigh = Number(meta.high ?? 0);
    } catch {
      // JSON parse failed (no package.json or audit unsupported) — leave at 0
    }

    const dotnetVulnCount = (dotnetRes.output.match(/^\s*>\s+\S+\s+/gm) ?? []).length;
    const denyList = ['GPL-3.0', 'AGPL-3.0', 'LGPL-3.0', 'SSPL-1.0']
      .filter(lic => dotnetRes.output.includes(lic) || npmRes.output.includes(lic));

    return {
      npmAuditCritical: npmCritical,
      npmAuditHigh: npmHigh,
      dotnetVulnCount,
      denyListLicenses: denyList,
    };
  }

  private matchesPattern(file: string, pattern: string): boolean {
    // Simple glob: /security/* matches anything under /security/
    if (pattern.endsWith('/*')) {
      const prefix = pattern.slice(0, -2);
      return file.includes(prefix);
    }
    if (pattern.startsWith('*') && pattern.endsWith('*')) {
      return file.toLowerCase().includes(pattern.slice(1, -1).toLowerCase());
    }
    return false;
  }

  private async safeExec(cmd: string): Promise<{ success: boolean; output: string }> {
    const shell = process.platform === 'win32' ? 'cmd' : 'sh';
    const shellArgs = process.platform === 'win32' ? ['/c', cmd] : ['-c', cmd];
    try {
      const { stdout, stderr } = await execFileAsync(shell, shellArgs, {
        timeout: 180_000,
        maxBuffer: 10 * 1024 * 1024,
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

  private parseResult(
    llmResponse: string,
    scaResult: { npmAuditCritical: number; npmAuditHigh: number; dotnetVulnCount: number; denyListLicenses: string[] },
    hasCriticalPathFiles: boolean,
  ): SecurityReviewResult {
    const parsed = this.extractJSON<Record<string, unknown>>(llmResponse);

    const findings: SecurityFinding[] = Array.isArray(parsed.findings)
      ? (parsed.findings as Record<string, unknown>[]).map((f, i) => ({
          id: String(f.id ?? `SEC-${i + 1}`),
          file: String(f.file ?? 'unknown'),
          line: Number(f.line ?? 0),
          severity: (f.severity as SecurityFinding['severity']) ?? 'medium',
          category: (f.category as SecurityFinding['category']) ?? 'static-analysis',
          cwe: f.cwe as string | undefined,
          message: String(f.message ?? ''),
          suggestedRemediation: String(f.suggestedRemediation ?? ''),
          securityCriticalPath: Boolean(f.securityCriticalPath),
        }))
      : [];

    const signatoryActions = Array.isArray(parsed.signatoryActions)
      ? (parsed.signatoryActions as SignatoryAction[])
      : [];

    const threatModelDelta = (parsed.threatModelDelta as ThreatModelDelta | null) ?? null;

    // Independent verification of signoffGranted from findings
    const hasCritical = findings.some(f => f.severity === 'critical');
    const hasHighOnCriticalPath = findings.some(f => f.severity === 'high' && f.securityCriticalPath);
    const hasDenyListLicense = scaResult.denyListLicenses.length > 0;
    const threatModelDeltaUnresolved = threatModelDelta !== null;

    const computedSignoff = !hasCritical && !hasHighOnCriticalPath && !hasDenyListLicense && !threatModelDeltaUnresolved;
    const llmSignoff = Boolean(parsed.signoffGranted);

    // Use the more restrictive of the two (defense in depth)
    const signoffGranted = computedSignoff && llmSignoff;

    const evidence = Array.isArray(parsed.evidence) ? (parsed.evidence as string[]) : [];
    evidence.push(`sca: npm-critical=${scaResult.npmAuditCritical} npm-high=${scaResult.npmAuditHigh} dotnet-vuln=${scaResult.dotnetVulnCount} deny-licenses=${scaResult.denyListLicenses.length}`);
    evidence.push(`critical-path-files: ${hasCriticalPathFiles}`);
    evidence.push(`signoff-computed: ${computedSignoff}, llm-stated: ${llmSignoff}, final: ${signoffGranted}`);

    return {
      signoffGranted,
      findings,
      threatModelDelta,
      scaResults: scaResult,
      signatoryActions,
      evidence,
    };
  }
}
