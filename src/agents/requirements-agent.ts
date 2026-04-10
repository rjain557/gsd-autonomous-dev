// ═══════════════════════════════════════════════════════════
// RequirementsAgent (Phase A)
// Drafts Intake Pack from unstructured project input.
// Produces structured requirements, RACI, NFRs, risk register.
// ═══════════════════════════════════════════════════════════

import { BaseAgent } from '../harness/base-agent';
import type { AgentInput, AgentOutput } from '../harness/types';
import type { IntakePack } from '../harness/sdlc-types';

export class RequirementsAgent extends BaseAgent {
  protected async run(input: AgentInput): Promise<AgentOutput> {
    const { projectName, projectDescription } = input as { projectName: string; projectDescription: string };

    const systemPrompt = await this.buildSystemPrompt();
    const userMessage = [
      '## Project',
      `**Name:** ${projectName}`,
      `**Description:** ${projectDescription}`,
      '',
      '## Instructions',
      'Generate a complete Intake Pack with ALL of the following sections.',
      'Return ONLY valid JSON matching the IntakePack schema.',
    ].join('\n');

    const schema = {
      type: 'object' as const,
      properties: {
        problemStatement: { type: 'string' },
        outcomes: { type: 'array', items: { type: 'string' } },
        successMetrics: { type: 'array', items: { type: 'string' } },
        stakeholders: { type: 'array', items: { type: 'object', properties: { name: { type: 'string' }, role: { type: 'string' }, raci: { type: 'string' } } } },
        dataClassification: { type: 'string' },
        regulatoryScope: { type: 'array', items: { type: 'string' } },
        domainOperations: { type: 'array', items: { type: 'object', properties: { entity: { type: 'string' }, operations: { type: 'array', items: { type: 'string' } }, roles: { type: 'array', items: { type: 'string' } } } } },
        rbacSketch: { type: 'array', items: { type: 'object', properties: { role: { type: 'string' }, permissions: { type: 'array', items: { type: 'string' } } } } },
        nfrs: { type: 'array', items: { type: 'object', properties: { category: { type: 'string' }, requirement: { type: 'string' }, target: { type: 'string' } } } },
        riskRegister: { type: 'array', items: { type: 'object', properties: { risk: { type: 'string' }, likelihood: { type: 'string' }, impact: { type: 'string' }, mitigation: { type: 'string' } } } },
        acceptanceCriteria: { type: 'array', items: { type: 'object', properties: { id: { type: 'string' }, description: { type: 'string' }, testable: { type: 'boolean' } } } },
        dependencies: { type: 'array', items: { type: 'string' } },
      },
      required: ['problemStatement', 'outcomes', 'stakeholders', 'domainOperations', 'acceptanceCriteria'],
    };

    const response = await this.callLLM(systemPrompt, userMessage, schema);
    return this.extractJSON<IntakePack>(response);
  }
}
