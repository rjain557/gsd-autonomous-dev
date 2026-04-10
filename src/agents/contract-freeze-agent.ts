// ═══════════════════════════════════════════════════════════
// ContractFreezeAgent (Phase E / SCG1)
// Generates and freezes contract artifacts: OpenAPI, API↔SP Map,
// DB Plan, Test Plan. Validates generated code against contract.
// ═══════════════════════════════════════════════════════════

import { BaseAgent } from '../harness/base-agent';
import type { AgentInput, AgentOutput } from '../harness/types';
import type { ArchitecturePack, FigmaDeliverables, FrozenBlueprint, ContractArtifacts } from '../harness/sdlc-types';
import * as fs from 'fs/promises';
import * as path from 'path';

export class ContractFreezeAgent extends BaseAgent {
  protected async run(input: AgentInput): Promise<AgentOutput> {
    const { frozenBlueprint, architecturePack, figmaDeliverables } = input as {
      frozenBlueprint: FrozenBlueprint;
      architecturePack: ArchitecturePack | null;
      figmaDeliverables: FigmaDeliverables | null;
    };

    // Read Figma analysis files for contract generation
    let apiContracts = '';
    let apiSpMap = '';
    let dataTypes = '';
    let storyboards = '';
    const analysisPath = figmaDeliverables?.analysisPath ?? '';
    try { apiContracts = await fs.readFile(path.join(analysisPath, '06-api-contracts.md'), 'utf-8'); } catch {}
    try { apiSpMap = await fs.readFile(path.join(analysisPath, '11-api-to-sp-map.md'), 'utf-8'); } catch {}
    try { dataTypes = await fs.readFile(path.join(analysisPath, '05-data-types.md'), 'utf-8'); } catch {}
    try { storyboards = await fs.readFile(path.join(analysisPath, '09-storyboards.md'), 'utf-8'); } catch {}

    const systemPrompt = await this.buildSystemPrompt();
    const userMessage = [
      '## Frozen Blueprint',
      `Screens: ${frozenBlueprint.screenInventory.length}`,
      `Components: ${frozenBlueprint.componentInventory.length}`,
      `Routes: ${frozenBlueprint.navigationArchitecture.routes}`,
      '',
      '## API Contracts (from Figma)',
      apiContracts.substring(0, 4000),
      '',
      '## API-to-SP Map (from Figma)',
      apiSpMap.substring(0, 3000),
      '',
      '## Data Types (from Figma)',
      dataTypes.substring(0, 3000),
      '',
      '## OpenAPI Draft (from Architecture Pack)',
      (architecturePack?.openApiDraft ?? '').substring(0, 2000),
      '',
      '## Instructions',
      'Generate the SCG1 contract artifacts:',
      '1. Count routes from blueprint screen inventory → routes',
      '2. Count endpoints from API contracts → endpoints',
      '3. Count SPs from API↔SP map → storedProcedures',
      '4. Identify gaps between generated code and contract (DTO mismatches, missing SPs, etc.)',
      '5. Set scg1Passed=true ONLY if zero critical gaps',
      '',
      'Return ONLY valid JSON matching the ContractArtifacts schema.',
      'Paths should reference /docs/spec/ directory.',
    ].join('\n');

    const schema = {
      type: 'object' as const,
      properties: {
        uiContractPath: { type: 'string' },
        openApiPath: { type: 'string' },
        apiSpMapPath: { type: 'string' },
        dbPlanPath: { type: 'string' },
        testPlanPath: { type: 'string' },
        ciGatesPath: { type: 'string' },
        validationReportPath: { type: 'string' },
        routes: { type: 'number' },
        endpoints: { type: 'number' },
        storedProcedures: { type: 'number' },
        gaps: { type: 'array', items: { type: 'object', properties: { id: { type: 'string' }, layer: { type: 'string' }, issue: { type: 'string' }, action: { type: 'string' } } } },
        scg1Passed: { type: 'boolean' },
      },
      required: ['routes', 'endpoints', 'storedProcedures', 'gaps', 'scg1Passed'],
    };

    const response = await this.callLLM(systemPrompt, userMessage, schema);
    const result = this.extractJSON<ContractArtifacts>(response);

    // Set default paths if not provided by LLM
    result.uiContractPath ??= '/docs/spec/ui-contract.csv';
    result.openApiPath ??= '/docs/spec/openapi.yaml';
    result.apiSpMapPath ??= '/docs/spec/apitospmap.csv';
    result.dbPlanPath ??= '/docs/spec/db-plan.md';
    result.testPlanPath ??= '/docs/spec/test-plan.md';
    result.ciGatesPath ??= '/docs/spec/ci-gates.md';
    result.validationReportPath ??= '/docs/spec/validation-report.md';

    console.log(`[CONTRACT-FREEZE] Routes: ${result.routes}, Endpoints: ${result.endpoints}, SPs: ${result.storedProcedures}, Gaps: ${result.gaps.length}, SCG1: ${result.scg1Passed ? 'PASSED' : 'FAILED'}`);
    return result;
  }
}
