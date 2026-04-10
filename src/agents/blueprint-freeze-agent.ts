// ═══════════════════════════════════════════════════════════
// BlueprintFreezeAgent (Phase D)
// Freezes UI/UX blueprint by synthesizing Figma analysis
// with reconciled Phase A/B. Produces frozen specification.
// ═══════════════════════════════════════════════════════════

import { BaseAgent } from '../harness/base-agent';
import type { AgentInput, AgentOutput } from '../harness/types';
import type { IntakePack, ArchitecturePack, FigmaDeliverables, ReconciliationReport, FrozenBlueprint } from '../harness/sdlc-types';
import * as fs from 'fs/promises';
import * as path from 'path';

export class BlueprintFreezeAgent extends BaseAgent {
  protected async run(input: AgentInput): Promise<AgentOutput> {
    const { intakePack, figmaDeliverables, reconciliationReport } = input as {
      intakePack: IntakePack;
      architecturePack: ArchitecturePack;
      figmaDeliverables: FigmaDeliverables;
      reconciliationReport: ReconciliationReport | null;
    };

    // Read Figma analysis files for blueprint synthesis
    let screenInventory = '';
    let componentInventory = '';
    let designSystem = '';
    let navigation = '';
    try { screenInventory = await fs.readFile(path.join(figmaDeliverables.analysisPath, '01-screen-inventory.md'), 'utf-8'); } catch {}
    try { componentInventory = await fs.readFile(path.join(figmaDeliverables.analysisPath, '02-component-inventory.md'), 'utf-8'); } catch {}
    try { designSystem = await fs.readFile(path.join(figmaDeliverables.analysisPath, '03-design-system.md'), 'utf-8'); } catch {}
    try { navigation = await fs.readFile(path.join(figmaDeliverables.analysisPath, '04-navigation-routing.md'), 'utf-8'); } catch {}

    const systemPrompt = await this.buildSystemPrompt();
    const userMessage = [
      '## Screen Inventory (from Figma)',
      screenInventory.substring(0, 3000),
      '',
      '## Component Inventory (from Figma)',
      componentInventory.substring(0, 2000),
      '',
      '## Design System (from Figma)',
      designSystem.substring(0, 2000),
      '',
      '## Navigation (from Figma)',
      navigation.substring(0, 1500),
      '',
      '## RBAC from Requirements',
      JSON.stringify(intakePack?.rbacSketch ?? [], null, 2).substring(0, 1000),
      '',
      '## Reconciliation Gaps',
      JSON.stringify(reconciliationReport?.gapsFound ?? [], null, 2).substring(0, 1000),
      '',
      '## Instructions',
      'Synthesize all inputs into a Frozen Blueprint document.',
      'Extract screen inventory, component inventory, design tokens, RBAC, accessibility requirements.',
      'Mark the blueprint as FROZEN with current timestamp.',
      'Return ONLY valid JSON matching the FrozenBlueprint schema.',
    ].join('\n');

    const schema = {
      type: 'object' as const,
      properties: {
        screenInventory: { type: 'array', items: { type: 'object', properties: { route: { type: 'string' }, name: { type: 'string' }, layout: { type: 'string' }, roles: { type: 'array' }, states: { type: 'array' } } } },
        componentInventory: { type: 'array', items: { type: 'object', properties: { name: { type: 'string' }, category: { type: 'string' }, screens: { type: 'array' }, variants: { type: 'number' } } } },
        designTokens: { type: 'object', properties: { colors: { type: 'number' }, typography: { type: 'number' }, spacing: { type: 'number' }, icons: { type: 'number' } } },
        navigationArchitecture: { type: 'object', properties: { routes: { type: 'number' }, nestedLevels: { type: 'number' }, authRequired: { type: 'number' } } },
        rbacMatrix: { type: 'array', items: { type: 'object', properties: { role: { type: 'string' }, screens: { type: 'array' }, operations: { type: 'array' } } } },
        accessibilityRequirements: { type: 'array', items: { type: 'string' } },
        copyDeck: { type: 'array', items: { type: 'object', properties: { screen: { type: 'string' }, titles: { type: 'array' }, emptyStates: { type: 'array' }, errorMessages: { type: 'array' } } } },
        approvalStatus: { type: 'object', properties: { productLead: { type: 'boolean' }, uxOwner: { type: 'boolean' }, techArchitect: { type: 'boolean' } } },
        frozenAt: { type: 'string' },
      },
      required: ['screenInventory', 'componentInventory', 'designTokens', 'rbacMatrix', 'frozenAt'],
    };

    const response = await this.callLLM(systemPrompt, userMessage, schema);
    const result = this.extractJSON<FrozenBlueprint>(response);
    result.frozenAt = new Date().toISOString();
    return result;
  }
}
