// ═══════════════════════════════════════════════════════════
// FigmaIntegrationAgent (Phase C)
// Validates Figma Make deliverables (12 analysis files + stubs).
// Runs DTO validation and build verification.
// Minimal LLM usage — mostly file system checks.
// ═══════════════════════════════════════════════════════════

import { BaseAgent } from '../harness/base-agent';
import type { AgentInput, AgentOutput } from '../harness/types';
import type { FigmaDeliverables } from '../harness/sdlc-types';
import * as fs from 'fs/promises';
import * as path from 'path';

const EXPECTED_ANALYSIS_FILES: Array<{ key: keyof FigmaDeliverables['analysisFiles']; filename: string }> = [
  { key: 'screenInventory', filename: '01-screen-inventory.md' },
  { key: 'componentInventory', filename: '02-component-inventory.md' },
  { key: 'designSystem', filename: '03-design-system.md' },
  { key: 'navigationRouting', filename: '04-navigation-routing.md' },
  { key: 'dataTypes', filename: '05-data-types.md' },
  { key: 'apiContracts', filename: '06-api-contracts.md' },
  { key: 'hooksState', filename: '07-hooks-state.md' },
  { key: 'mockDataCatalog', filename: '08-mock-data-catalog.md' },
  { key: 'storyboards', filename: '09-storyboards.md' },
  { key: 'screenStateMatrix', filename: '10-screen-state-matrix.md' },
  { key: 'apiSpMap', filename: '11-api-to-sp-map.md' },
  { key: 'implementationGuide', filename: '12-implementation-guide.md' },
];

export class FigmaIntegrationAgent extends BaseAgent {
  protected async run(input: AgentInput): Promise<AgentOutput> {
    const { designPath } = input as { designPath: string };
    const analysisPath = path.join(designPath, '_analysis');
    const stubsPath = path.join(designPath, '_stubs');
    const generatedPath = path.join(designPath, '..', 'generated');

    // Check which analysis files exist
    const analysisFiles: FigmaDeliverables['analysisFiles'] = {
      screenInventory: false, componentInventory: false, designSystem: false,
      navigationRouting: false, dataTypes: false, apiContracts: false,
      hooksState: false, mockDataCatalog: false, storyboards: false,
      screenStateMatrix: false, apiSpMap: false, implementationGuide: false,
    };

    let completeness = 0;
    for (const { key, filename } of EXPECTED_ANALYSIS_FILES) {
      try {
        await fs.access(path.join(analysisPath, filename));
        analysisFiles[key] = true;
        completeness++;
      } catch { /* file not found */ }
    }

    console.log(`[FIGMA] Analysis files: ${completeness}/12`);
    for (const { key, filename } of EXPECTED_ANALYSIS_FILES) {
      console.log(`  ${analysisFiles[key] ? '✓' : '✗'} ${filename}`);
    }

    // DTO validation — check naming conventions in stub files
    const dtoMismatches: string[] = [];
    try {
      const stubFiles = await this.findFiles(path.join(stubsPath, 'backend', 'Models'), ['.cs']);
      for (const f of stubFiles) {
        const content = await fs.readFile(f, 'utf-8');
        // Check DTO naming: must be Create{Entity}Dto, Update{Entity}Dto, {Entity}ResponseDto
        const classes = content.match(/class\s+(\w+)/g) ?? [];
        for (const cls of classes) {
          const name = cls.replace('class ', '');
          if (!name.endsWith('Dto') && !name.endsWith('Response')) {
            dtoMismatches.push(`${path.basename(f)}: ${name} does not follow DTO naming convention`);
          }
        }
      }
    } catch { /* no stubs directory */ }

    // Build verification
    let dotnetBuild = false;
    let npmBuild = false;
    try {
      const { execFile } = await import('child_process');
      const { promisify } = await import('util');
      const exec = promisify(execFile);
      const shell = process.platform === 'win32' ? 'cmd' : 'sh';
      const shellFlag = process.platform === 'win32' ? '/c' : '-c';

      try {
        await exec(shell, [shellFlag, 'dotnet build --no-restore 2>&1'], { timeout: 60_000 });
        dotnetBuild = true;
      } catch { /* build failed */ }

      try {
        await exec(shell, [shellFlag, 'npm run build 2>&1'], { timeout: 60_000 });
        npmBuild = true;
      } catch { /* build failed */ }
    } catch { /* exec not available */ }

    return {
      analysisPath,
      stubsPath,
      generatedPath,
      analysisFiles,
      completeness,
      dtoValidation: { passed: dtoMismatches.length === 0, mismatches: dtoMismatches },
      buildVerification: { dotnetBuild, npmBuild },
    } satisfies FigmaDeliverables;
  }

  private async findFiles(dir: string, exts: string[]): Promise<string[]> {
    const results: string[] = [];
    const skip = new Set(['node_modules', '.git', 'bin', 'obj', 'dist']);
    let entries;
    try { entries = await fs.readdir(dir, { withFileTypes: true }); } catch { return results; }
    for (const e of entries) {
      const p = path.join(dir, e.name);
      if (e.isDirectory() && !skip.has(e.name)) results.push(...await this.findFiles(p, exts));
      else if (exts.some(ext => e.name.endsWith(ext))) results.push(p);
    }
    return results;
  }
}
