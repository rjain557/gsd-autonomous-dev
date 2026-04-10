// ═══════════════════════════════════════════════════════════
// PhaseReconcileAgent (Phase A/B Update)
// Updates Phase A/B deliverables based on finalized Figma Make
// output. Identifies gaps, new requirements, and alignment.
// ═══════════════════════════════════════════════════════════

import { BaseAgent } from '../harness/base-agent';
import type { AgentInput, AgentOutput } from '../harness/types';
import type { IntakePack, ArchitecturePack, FigmaDeliverables, ReconciliationReport } from '../harness/sdlc-types';
import * as fs from 'fs/promises';
import * as path from 'path';

export class PhaseReconcileAgent extends BaseAgent {
  protected async run(input: AgentInput): Promise<AgentOutput> {
    const { intakePack, architecturePack, figmaDeliverables } = input as {
      intakePack: IntakePack;
      architecturePack: ArchitecturePack;
      figmaDeliverables: FigmaDeliverables;
    };

    // Read key Figma analysis files for comparison
    let apiContracts = '';
    let screenInventory = '';
    let dataTypes = '';
    try { apiContracts = await fs.readFile(path.join(figmaDeliverables.analysisPath, '06-api-contracts.md'), 'utf-8'); } catch {}
    try { screenInventory = await fs.readFile(path.join(figmaDeliverables.analysisPath, '01-screen-inventory.md'), 'utf-8'); } catch {}
    try { dataTypes = await fs.readFile(path.join(figmaDeliverables.analysisPath, '05-data-types.md'), 'utf-8'); } catch {}

    const systemPrompt = await this.buildSystemPrompt();
    const userMessage = [
      '## Phase A: Intake Pack',
      '```json',
      JSON.stringify(intakePack, null, 2).substring(0, 4000),
      '```',
      '',
      '## Phase B: Architecture Pack (OpenAPI Draft)',
      '```yaml',
      (architecturePack.openApiDraft ?? '').substring(0, 3000),
      '```',
      '',
      '## Figma Analysis: Screen Inventory (excerpt)',
      screenInventory.substring(0, 2000),
      '',
      '## Figma Analysis: API Contracts (excerpt)',
      apiContracts.substring(0, 3000),
      '',
      '## Figma Analysis: Data Types (excerpt)',
      dataTypes.substring(0, 2000),
      '',
      '## Instructions',
      'Compare Phase A/B deliverables against the Figma Make analysis output.',
      'Identify:',
      '1. Gaps: what Figma revealed that Phase A/B missed',
      '2. New requirements: screens, flows, entities discovered during prototyping',
      '3. Updated endpoints: API endpoints added/changed from Figma analysis',
      '4. Updated data models: entities added/changed',
      '5. Alignment score: 0-100 how well Phase A/B aligns with Figma output',
      '',
      'Return updated IntakePack and ArchitecturePack with reconciled content.',
      'Return ONLY valid JSON matching the ReconciliationReport schema.',
    ].join('\n');

    const schema = {
      type: 'object' as const,
      properties: {
        gapsFound: { type: 'array', items: { type: 'object', properties: { source: { type: 'string' }, description: { type: 'string' }, resolution: { type: 'string' } } } },
        newRequirements: { type: 'array', items: { type: 'string' } },
        updatedEndpoints: { type: 'array', items: { type: 'string' } },
        updatedDataModels: { type: 'array', items: { type: 'string' } },
        alignmentScore: { type: 'number' },
        updatedIntakePack: { type: 'object' },
        updatedArchitecturePack: { type: 'object' },
      },
      required: ['gapsFound', 'alignmentScore', 'updatedIntakePack', 'updatedArchitecturePack'],
    };

    const response = await this.callLLM(systemPrompt, userMessage, schema);
    return this.extractJSON<ReconciliationReport>(response);
  }
}
