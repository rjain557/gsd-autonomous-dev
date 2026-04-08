// ═══════════════════════════════════════════════════════════
// RemediationAgent
// Given a ReviewResult with failures, proposes and applies
// targeted code fixes. Each fix is atomic and traceable.
// ═══════════════════════════════════════════════════════════

import { BaseAgent } from '../harness/base-agent';
import type {
  AgentInput,
  AgentOutput,
  RemediationInput,
  PatchSet,
  Patch,
  Issue,
} from '../harness/types';
import * as fs from 'fs/promises';
import * as path from 'path';
import { execFile } from 'child_process';
import { promisify } from 'util';

const execFileAsync = promisify(execFile);

export class RemediationAgent extends BaseAgent {
  protected async run(input: AgentInput): Promise<AgentOutput> {
    const { reviewResult, repoRoot } = input as RemediationInput;

    // Sort issues by severity: critical first
    const sortedIssues = [...reviewResult.issues].sort((a, b) => {
      const order = { critical: 0, high: 1, medium: 2, low: 3 };
      return (order[a.severity] ?? 4) - (order[b.severity] ?? 4);
    });

    // Only fix critical and high issues (medium/low if time permits)
    const toFix = sortedIssues.filter(i => i.severity === 'critical' || i.severity === 'high');

    const patches: Patch[] = [];

    for (const issue of toFix) {
      try {
        const patch = await this.fixIssue(issue, repoRoot);
        if (patch) {
          patches.push(patch);
        }
      } catch (err) {
        console.log(`[REMEDIATION] Skipping ${issue.id}: ${err instanceof Error ? err.message : String(err)}`);
      }
    }

    // Run tests after all fixes applied
    const testsPassed = await this.runTests(repoRoot);

    // If tests fail, rollback all patched files from backups
    if (!testsPassed && patches.length > 0) {
      console.log(`[REMEDIATION] Tests failed after ${patches.length} patches — rolling back`);
      for (const patch of patches) {
        const filePath = path.resolve(repoRoot, patch.file);
        const backupPath = filePath + '.gsd-backup';
        try {
          await fs.copyFile(backupPath, filePath);
        } catch { /* backup may not exist if write failed */ }
      }
    }

    // Clean up backup files
    for (const patch of patches) {
      const backupPath = path.resolve(repoRoot, patch.file) + '.gsd-backup';
      try { await fs.unlink(backupPath); } catch { /* ignore */ }
    }

    return {
      patches,
      testsPassed,
    } satisfies PatchSet;
  }

  private async fixIssue(issue: Issue, repoRoot: string): Promise<Patch | null> {
    const filePath = path.resolve(repoRoot, issue.file);

    // Read the current file content
    let fileContent: string;
    try {
      fileContent = await fs.readFile(filePath, 'utf-8');
    } catch {
      console.log(`[REMEDIATION] Cannot read ${issue.file} — skipping`);
      return null;
    }

    // Build system prompt with vault context
    const systemPrompt = await this.buildSystemPrompt();

    const userMessage = [
      '## Issue to Fix',
      '',
      `| Field | Value |`,
      `|---|---|`,
      `| ID | ${issue.id} |`,
      `| File | ${issue.file} |`,
      `| Line | ${issue.line} |`,
      `| Severity | ${issue.severity} |`,
      `| Category | ${issue.category} |`,
      `| Message | ${issue.message} |`,
      issue.suggestedFix ? `| Suggested fix | ${issue.suggestedFix} |` : '',
      '',
      '## Current File Content',
      '',
      '```',
      fileContent.substring(0, 8000),
      '```',
      '',
      '## Instructions',
      '',
      'Return ONLY the complete fixed file content. No explanations, no markdown code fences.',
      'Make the MINIMAL change needed to fix this specific issue.',
      'Do not refactor surrounding code.',
    ].join('\n');

    // RemediationAgent returns raw file content, not JSON — no schema needed.
    const fixedContent = await this.callLLM(systemPrompt, userMessage);

    // Validate the fix is different from original
    if (fixedContent.trim() === fileContent.trim()) {
      return null;
    }

    // Validate the fix looks like code, not an LLM explanation
    if (this.looksLikeExplanation(fixedContent)) {
      console.log(`[REMEDIATION] LLM returned explanation instead of code for ${issue.id} — skipping`);
      return null;
    }

    // Write the fix, keeping a backup for rollback
    const backupPath = filePath + '.gsd-backup';
    await fs.copyFile(filePath, backupPath);
    await fs.writeFile(filePath, fixedContent, 'utf-8');

    return {
      file: issue.file,
      issueId: issue.id,
      diff: `Modified ${issue.file} at line ${issue.line}`,
      description: `Fix ${issue.severity} ${issue.category} issue: ${issue.message}`,
    };
  }

  /** Detect if LLM returned an explanation instead of raw code. */
  private looksLikeExplanation(content: string): boolean {
    const firstLine = content.trim().split('\n')[0];
    // If response starts with common explanation patterns, it's not code
    const explanationStarts = [
      /^(Here|I |The |This |Let me|Sure|To fix|Below|I've)/i,
      /^```/,  // code fence means LLM wrapped it instead of returning raw
    ];
    return explanationStarts.some(re => re.test(firstLine));
  }

  private async runTests(repoRoot: string): Promise<boolean> {
    try {
      await execFileAsync(
        process.platform === 'win32' ? 'cmd' : 'sh',
        process.platform === 'win32' ? ['/c', 'dotnet build --no-restore'] : ['-c', 'dotnet build --no-restore'],
        { cwd: repoRoot, timeout: 120_000 },
      );
      return true;
    } catch {
      return false;
    }
  }
}
