// ═══════════════════════════════════════════════════════════
// BlueprintAnalysisAgent
// Reads blueprint/spec files, extracts requirements, detects
// drift from current implementation.
// ═══════════════════════════════════════════════════════════

import { BaseAgent } from '../harness/base-agent';
import type {
  AgentInput,
  AgentOutput,
  BlueprintAnalysisInput,
  ConvergenceReport,
  DriftItem,
  RiskLevel,
} from '../harness/types';
import * as fs from 'fs/promises';
import * as path from 'path';

export class BlueprintAnalysisAgent extends BaseAgent {
  protected async run(input: AgentInput): Promise<AgentOutput> {
    const { blueprintPath, specPaths, repoRoot } = input as BlueprintAnalysisInput;

    // Read blueprint/matrix
    const blueprint = await this.readBlueprint(blueprintPath, repoRoot);
    if (!blueprint) {
      throw new Error(`Blueprint file not found: ${blueprintPath}`);
    }

    // Read spec documents for context
    const specContext = await this.readSpecs(specPaths, repoRoot);

    // Build system prompt with vault context
    const systemPrompt = await this.buildSystemPrompt();

    // Ask LLM to analyze drift
    const userMessage = [
      '## Blueprint Requirements',
      '',
      '```json',
      JSON.stringify(blueprint, null, 2),
      '```',
      '',
      '## Specification Context',
      '',
      specContext,
      '',
      '## Instructions',
      '',
      'Analyze each requirement in the blueprint against the current codebase.',
      'Return a JSON ConvergenceReport with fields: aligned, drifted, missing, riskLevel.',
      'For drifted items include: requirementId, expected, actual, severity.',
      'riskLevel: low (<=5% drifted), medium (5-15%), high (>15%).',
      '',
      'Return ONLY valid JSON, no markdown code fences.',
    ].join('\n');

    // JSON schema for structured output via tool_use
    const convergenceSchema = {
      type: 'object' as const,
      properties: {
        aligned: { type: 'array', items: { type: 'string' } },
        drifted: {
          type: 'array',
          items: {
            type: 'object',
            properties: {
              requirementId: { type: 'string' },
              expected: { type: 'string' },
              actual: { type: 'string' },
              severity: { type: 'string', enum: ['low', 'medium', 'high', 'critical'] },
            },
            required: ['requirementId', 'expected', 'actual', 'severity'],
          },
        },
        missing: { type: 'array', items: { type: 'string' } },
        riskLevel: { type: 'string', enum: ['low', 'medium', 'high'] },
      },
      required: ['aligned', 'drifted', 'missing', 'riskLevel'],
    };

    const response = await this.callLLM(systemPrompt, userMessage, convergenceSchema);
    return this.parseReport(response);
  }

  private async readBlueprint(
    blueprintPath: string,
    repoRoot: string,
  ): Promise<Record<string, unknown> | null> {
    const absPath = path.resolve(repoRoot, blueprintPath);
    try {
      const content = await fs.readFile(absPath, 'utf-8');
      return JSON.parse(content);
    } catch {
      return null;
    }
  }

  private async readSpecs(specPaths: string[], repoRoot: string): Promise<string> {
    const sections: string[] = [];

    for (const specPath of specPaths) {
      try {
        const absPath = path.resolve(repoRoot, specPath);
        const content = await fs.readFile(absPath, 'utf-8');
        sections.push(`### ${specPath}\n\n${content.substring(0, 3000)}`);
      } catch {
        sections.push(`### ${specPath}\n\n<!-- not found -->`);
      }
    }

    return sections.join('\n\n');
  }

  private parseReport(llmResponse: string): ConvergenceReport {
    // extractJSON throws on failure instead of silently returning empty data
    const parsed = this.extractJSON<Record<string, unknown>>(llmResponse);

    return {
      aligned: Array.isArray(parsed.aligned) ? parsed.aligned : [],
      drifted: (Array.isArray(parsed.drifted) ? parsed.drifted : []).map((d: Record<string, unknown>) => ({
        requirementId: String(d.requirementId ?? ''),
        expected: String(d.expected ?? ''),
        actual: String(d.actual ?? ''),
        severity: (['low', 'medium', 'high', 'critical'].includes(String(d.severity))
          ? d.severity
          : 'medium') as DriftItem['severity'],
      })),
      missing: Array.isArray(parsed.missing) ? parsed.missing : [],
      riskLevel: this.calculateRiskLevel(parsed),
    };
  }

  private calculateRiskLevel(parsed: Record<string, unknown>): RiskLevel {
    const total =
      (Array.isArray(parsed.aligned) ? parsed.aligned.length : 0) +
      (Array.isArray(parsed.drifted) ? parsed.drifted.length : 0) +
      (Array.isArray(parsed.missing) ? parsed.missing.length : 0);

    if (total === 0) return 'high';

    const driftedCount = Array.isArray(parsed.drifted) ? parsed.drifted.length : 0;
    const driftPct = (driftedCount / total) * 100;

    if (driftPct <= 5) return 'low';
    if (driftPct <= 15) return 'medium';
    return 'high';
  }
}
