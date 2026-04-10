// ═══════════════════════════════════════════════════════════
// ArchitectureAgent (Phase B)
// Transforms Phase A Intake Pack into Architecture Pack.
// Generates diagrams (Mermaid), draft OpenAPI, threat model.
// ═══════════════════════════════════════════════════════════

import { BaseAgent } from '../harness/base-agent';
import type { AgentInput, AgentOutput } from '../harness/types';
import type { IntakePack, ArchitecturePack } from '../harness/sdlc-types';

export class ArchitectureAgent extends BaseAgent {
  protected async run(input: AgentInput): Promise<AgentOutput> {
    const { intakePack } = input as { intakePack: IntakePack };

    const systemPrompt = await this.buildSystemPrompt();
    const userMessage = [
      '## Intake Pack',
      '```json',
      JSON.stringify(intakePack, null, 2).substring(0, 8000),
      '```',
      '',
      '## Instructions',
      'Generate a complete Architecture Pack based on the Intake Pack.',
      'Include Mermaid diagram syntax for all diagrams.',
      'Generate a draft OpenAPI 3.0 YAML spec from the domain operations.',
      'Tech stack: .NET 8 + Dapper + SQL Server stored procedures + React 18 + TypeScript.',
      'Apply: API-First, SP-Only (no EF Core), multi-tenant with TenantId.',
      'Return ONLY valid JSON matching the ArchitecturePack schema.',
    ].join('\n');

    const schema = {
      type: 'object' as const,
      properties: {
        systemContextDiagram: { type: 'string' },
        componentDiagrams: { type: 'array', items: { type: 'string' } },
        sequenceDiagrams: { type: 'array', items: { type: 'string' } },
        dataFlowDiagram: { type: 'string' },
        openApiDraft: { type: 'string' },
        dataModelInventory: { type: 'array', items: { type: 'object', properties: { entity: { type: 'string' }, fields: { type: 'array' } } } },
        threatModel: { type: 'array', items: { type: 'object', properties: { threat: { type: 'string' }, boundary: { type: 'string' }, mitigation: { type: 'string' }, severity: { type: 'string' } } } },
        observabilityPlan: { type: 'object', properties: { logging: { type: 'string' }, metrics: { type: 'string' }, tracing: { type: 'string' }, alerting: { type: 'string' } } },
        promotionModel: { type: 'object', properties: { environments: { type: 'array', items: { type: 'string' } }, strategy: { type: 'string' }, rollbackPlan: { type: 'string' } } },
      },
      required: ['systemContextDiagram', 'openApiDraft', 'dataModelInventory', 'threatModel'],
    };

    const response = await this.callLLM(systemPrompt, userMessage, schema);
    return this.extractJSON<ArchitecturePack>(response);
  }
}
