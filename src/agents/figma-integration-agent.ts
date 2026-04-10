// ═══════════════════════════════════════════════════════════
// FigmaIntegrationAgent (Phase C)
// Two-stage validation:
//   Stage 1: Structural — 12/12 analysis files, DTO naming, builds
//   Stage 2: Design skill compliance — 5-state rule, composition
//            patterns, WAI-ARIA accessibility, design quality
// ═══════════════════════════════════════════════════════════

import { BaseAgent } from '../harness/base-agent';
import type { AgentInput, AgentOutput } from '../harness/types';
import type { FigmaDeliverables } from '../harness/sdlc-types';
import * as fs from 'fs/promises';
import * as path from 'path';

// ── Design Skill Audit Types ───────────────────────────────

export interface SkillFinding {
  skill: 'five-state-rule' | 'composition-patterns' | 'accessibility' | 'design-quality';
  file: string;
  issue: string;
  severity: 'error' | 'warning';
}

export interface SkillAuditReport {
  fiveStateRule: { passed: boolean; findings: SkillFinding[] };
  compositionPatterns: { passed: boolean; findings: SkillFinding[] };
  accessibility: { passed: boolean; findings: SkillFinding[] };
  designQuality: { passed: boolean; findings: SkillFinding[] };
  totalFindings: number;
  errorCount: number;
  passedAll: boolean;
}

// ── Expected Files ─────────────────────────────────────────

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

// ── Five Required States ───────────────────────────────────

const FIVE_STATES = ['loading', 'error', 'empty', 'populated', 'optimistic'] as const;

// ── Boolean Prop Anti-Patterns ─────────────────────────────

const BOOLEAN_PROP_PATTERNS = [
  /\bprimary\b(?!=)/i,      // <Button primary> instead of appearance="primary"
  /\bdisabled\s*>/i,         // bare disabled without =
  /\bloading\b(?!=)/i,       // <Button loading> instead of isLoading
  /\berror\b(?!=)/i,         // <MessageBar error> instead of intent="error"
  /\bsecondary\b(?!=)/i,     // <Button secondary>
];

// ── Accessibility Checks ───────────────────────────────────

const ARIA_CHECKS = [
  { pattern: /aria-label/i, label: 'aria-label usage' },
  { pattern: /role=/i, label: 'role attributes' },
  { pattern: /tabindex/i, label: 'tabIndex management' },
  { pattern: /contrast|4\.5:1|3:1/i, label: 'contrast ratios' },
  { pattern: /keyboard|focus/i, label: 'keyboard navigation' },
  { pattern: /aria-labelledby/i, label: 'dialog/drawer labelling' },
];

// ── Design Quality Checks ──────────────────────────────────

const DESIGN_QUALITY_CHECKS = [
  { pattern: /typography|font|segoe/i, label: 'typography system' },
  { pattern: /color.*palette|token|semantic/i, label: 'color semantics' },
  { pattern: /motion|animation|transition|micro-interaction/i, label: 'motion design' },
  { pattern: /spacing|padding|gap|density/i, label: 'spatial system' },
  { pattern: /elevation|shadow|depth/i, label: 'depth/elevation' },
  { pattern: /skeleton|shimmer/i, label: 'skeleton loading animations' },
];

// ── Agent Implementation ───────────────────────────────────

export class FigmaIntegrationAgent extends BaseAgent {
  protected async run(input: AgentInput): Promise<AgentOutput> {
    const { designPath } = input as { designPath: string };
    const analysisPath = path.join(designPath, '_analysis');
    const stubsPath = path.join(designPath, '_stubs');
    const generatedPath = path.join(designPath, '..', 'generated');

    // ── Stage 1: Structural Validation ─────────────────────

    const analysisFiles: FigmaDeliverables['analysisFiles'] = {
      screenInventory: false, componentInventory: false, designSystem: false,
      navigationRouting: false, dataTypes: false, apiContracts: false,
      hooksState: false, mockDataCatalog: false, storyboards: false,
      screenStateMatrix: false, apiSpMap: false, implementationGuide: false,
    };

    let completeness = 0;
    const fileContents: Map<string, string> = new Map();

    for (const { key, filename } of EXPECTED_ANALYSIS_FILES) {
      const filePath = path.join(analysisPath, filename);
      try {
        const content = await fs.readFile(filePath, 'utf-8');
        analysisFiles[key] = true;
        completeness++;
        fileContents.set(filename, content);
      } catch { /* file not found */ }
    }

    console.log(`[FIGMA] Analysis files: ${completeness}/12`);
    for (const { key, filename } of EXPECTED_ANALYSIS_FILES) {
      console.log(`  ${analysisFiles[key] ? '✓' : '✗'} ${filename}`);
    }

    // DTO validation
    const dtoMismatches: string[] = [];
    try {
      const stubFiles = await this.findFiles(path.join(stubsPath, 'backend', 'Models'), ['.cs']);
      for (const f of stubFiles) {
        const content = await fs.readFile(f, 'utf-8');
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

    // ── Stage 2: Design Skill Compliance Audit ─────────────

    let skillAudit: SkillAuditReport | null = null;

    if (completeness >= 10) {
      // Only run skill audit if we have enough files to validate
      skillAudit = this.auditDesignSkills(fileContents);
      console.log(`[FIGMA] Skill audit: ${skillAudit.totalFindings} findings (${skillAudit.errorCount} errors)`);
    } else {
      console.log('[FIGMA] Skipping skill audit — too few analysis files for meaningful validation');
    }

    return {
      analysisPath,
      stubsPath,
      generatedPath,
      analysisFiles,
      completeness,
      dtoValidation: { passed: dtoMismatches.length === 0, mismatches: dtoMismatches },
      buildVerification: { dotnetBuild, npmBuild },
      skillAudit,
    } as unknown as AgentOutput;
  }

  // ── Design Skill Audit ─────────────────────────────────────

  private auditDesignSkills(files: Map<string, string>): SkillAuditReport {
    const fiveStateFindings = this.auditFiveStateRule(files);
    const compositionFindings = this.auditCompositionPatterns(files);
    const accessibilityFindings = this.auditAccessibility(files);
    const designQualityFindings = this.auditDesignQuality(files);

    const allFindings = [
      ...fiveStateFindings, ...compositionFindings,
      ...accessibilityFindings, ...designQualityFindings,
    ];

    const errorCount = allFindings.filter(f => f.severity === 'error').length;

    return {
      fiveStateRule: {
        passed: fiveStateFindings.filter(f => f.severity === 'error').length === 0,
        findings: fiveStateFindings,
      },
      compositionPatterns: {
        passed: compositionFindings.filter(f => f.severity === 'error').length === 0,
        findings: compositionFindings,
      },
      accessibility: {
        passed: accessibilityFindings.filter(f => f.severity === 'error').length === 0,
        findings: accessibilityFindings,
      },
      designQuality: {
        passed: designQualityFindings.filter(f => f.severity === 'error').length === 0,
        findings: designQualityFindings,
      },
      totalFindings: allFindings.length,
      errorCount,
      passedAll: errorCount === 0,
    };
  }

  // ── Skill 1: Five-State Rule ─────────────────────────────

  private auditFiveStateRule(files: Map<string, string>): SkillFinding[] {
    const findings: SkillFinding[] = [];
    const matrix = files.get('10-screen-state-matrix.md');

    if (!matrix) {
      findings.push({
        skill: 'five-state-rule',
        file: '10-screen-state-matrix.md',
        issue: 'Screen state matrix file missing — cannot validate 5-state coverage',
        severity: 'error',
      });
      return findings;
    }

    const matrixLower = matrix.toLowerCase();

    // Check each state is mentioned
    for (const state of FIVE_STATES) {
      if (!matrixLower.includes(state)) {
        findings.push({
          skill: 'five-state-rule',
          file: '10-screen-state-matrix.md',
          issue: `State "${state}" not found in screen state matrix`,
          severity: 'error',
        });
      }
    }

    // Check skeleton-specific patterns (not just "spinner")
    if (matrixLower.includes('spinner') && !matrixLower.includes('skeleton')) {
      findings.push({
        skill: 'five-state-rule',
        file: '10-screen-state-matrix.md',
        issue: 'Uses "spinner" for loading states — must use Skeleton components matching layout shape per react-ui-design-patterns skill',
        severity: 'error',
      });
    }

    // Check for retry in error states
    if (!matrixLower.includes('retry')) {
      findings.push({
        skill: 'five-state-rule',
        file: '10-screen-state-matrix.md',
        issue: 'Error states do not mention "retry" action — all error states must include a retry button per react-ui-design-patterns skill',
        severity: 'warning',
      });
    }

    // Check optimistic update pattern
    if (!matrixLower.includes('optimistic') && !matrixLower.includes('onmutate')) {
      findings.push({
        skill: 'five-state-rule',
        file: '10-screen-state-matrix.md',
        issue: 'No optimistic update pattern found — mutations should update UI immediately and rollback on error',
        severity: 'warning',
      });
    }

    // Check empty state has CTA
    if (matrixLower.includes('empty') && !matrixLower.includes('cta') && !matrixLower.includes('button') && !matrixLower.includes('action')) {
      findings.push({
        skill: 'five-state-rule',
        file: '10-screen-state-matrix.md',
        issue: 'Empty states should include a CTA button to guide users to the next action',
        severity: 'warning',
      });
    }

    return findings;
  }

  // ── Skill 2: Composition Patterns ────────────────────────

  private auditCompositionPatterns(files: Map<string, string>): SkillFinding[] {
    const findings: SkillFinding[] = [];
    const components = files.get('02-component-inventory.md');

    if (!components) {
      findings.push({
        skill: 'composition-patterns',
        file: '02-component-inventory.md',
        issue: 'Component inventory file missing — cannot validate composition patterns',
        severity: 'error',
      });
      return findings;
    }

    // Check for boolean prop anti-patterns
    for (const pattern of BOOLEAN_PROP_PATTERNS) {
      const matches = components.match(new RegExp(`<\\w+[^>]*${pattern.source}[^>]*>`, 'gi'));
      if (matches) {
        for (const match of matches.slice(0, 3)) { // limit to 3 per pattern
          findings.push({
            skill: 'composition-patterns',
            file: '02-component-inventory.md',
            issue: `Boolean prop pattern detected: "${match.substring(0, 80)}" — use explicit variant props (appearance=, intent=) instead`,
            severity: 'warning',
          });
        }
      }
    }

    // Check for compound component usage
    const compoundPatterns = [
      { pattern: /drawer/i, needs: /drawerheader|drawerbody/i, label: 'Drawer compound structure' },
      { pattern: /dialog/i, needs: /dialogsurface|dialogbody|dialogtitle/i, label: 'Dialog compound structure' },
      { pattern: /menu/i, needs: /menutrigger|menupopover|menulist/i, label: 'Menu compound structure' },
    ];

    const componentsLower = components.toLowerCase();
    for (const { pattern, needs, label } of compoundPatterns) {
      if (pattern.test(componentsLower) && !needs.test(componentsLower)) {
        findings.push({
          skill: 'composition-patterns',
          file: '02-component-inventory.md',
          issue: `${label} — uses ${pattern} but missing compound sub-components (${needs.source})`,
          severity: 'warning',
        });
      }
    }

    // Check for slot-based composition
    if (!componentsLower.includes('slot') && !componentsLower.includes('contentbefore') && !componentsLower.includes('contentafter')) {
      findings.push({
        skill: 'composition-patterns',
        file: '02-component-inventory.md',
        issue: 'No slot-based composition found — Fluent UI v9 uses icon, contentBefore, contentAfter slots',
        severity: 'warning',
      });
    }

    return findings;
  }

  // ── Skill 3: Accessibility (WAI-ARIA) ────────────────────

  private auditAccessibility(files: Map<string, string>): SkillFinding[] {
    const findings: SkillFinding[] = [];

    // Check screen inventory for keyboard/focus documentation
    const screens = files.get('01-screen-inventory.md');
    if (screens) {
      const screensLower = screens.toLowerCase();
      if (!screensLower.includes('keyboard') && !screensLower.includes('focus')) {
        findings.push({
          skill: 'accessibility',
          file: '01-screen-inventory.md',
          issue: 'No keyboard navigation or focus management documented for screens',
          severity: 'error',
        });
      }
    }

    // Check design system for contrast ratios
    const designSystem = files.get('03-design-system.md');
    if (designSystem) {
      const dsLower = designSystem.toLowerCase();
      if (!dsLower.includes('contrast') && !dsLower.includes('4.5') && !dsLower.includes('wcag')) {
        findings.push({
          skill: 'accessibility',
          file: '03-design-system.md',
          issue: 'Color contrast ratios not documented — must meet WCAG 2.1 AA (4.5:1 text, 3:1 UI)',
          severity: 'error',
        });
      }
    }

    // Check component inventory for aria attributes
    const components = files.get('02-component-inventory.md');
    if (components) {
      const compLower = components.toLowerCase();
      let ariaChecksPassed = 0;
      for (const { pattern, label } of ARIA_CHECKS) {
        if (pattern.test(compLower)) {
          ariaChecksPassed++;
        } else {
          findings.push({
            skill: 'accessibility',
            file: '02-component-inventory.md',
            issue: `Missing ${label} documentation in component inventory`,
            severity: 'warning',
          });
        }
      }

      if (ariaChecksPassed < 3) {
        findings.push({
          skill: 'accessibility',
          file: '02-component-inventory.md',
          issue: `Only ${ariaChecksPassed}/6 ARIA checks addressed — component inventory needs comprehensive accessibility annotations`,
          severity: 'error',
        });
      }
    }

    // Check screen state matrix for alert roles
    const matrix = files.get('10-screen-state-matrix.md');
    if (matrix) {
      const matLower = matrix.toLowerCase();
      if (matLower.includes('error') && !matLower.includes('role="alert"') && !matLower.includes('role=alert') && !matLower.includes('role: alert')) {
        findings.push({
          skill: 'accessibility',
          file: '10-screen-state-matrix.md',
          issue: 'Error states should use role="alert" for screen reader announcement per web-design-guidelines skill',
          severity: 'warning',
        });
      }
    }

    return findings;
  }

  // ── Skill 4: Design Quality ──────────────────────────────

  private auditDesignQuality(files: Map<string, string>): SkillFinding[] {
    const findings: SkillFinding[] = [];
    const designSystem = files.get('03-design-system.md');

    if (!designSystem) {
      findings.push({
        skill: 'design-quality',
        file: '03-design-system.md',
        issue: 'Design system file missing — cannot validate design quality',
        severity: 'error',
      });
      return findings;
    }

    const dsLower = designSystem.toLowerCase();

    // Check each quality dimension
    let dimensionsCovered = 0;
    for (const { pattern, label } of DESIGN_QUALITY_CHECKS) {
      if (pattern.test(dsLower)) {
        dimensionsCovered++;
      } else {
        findings.push({
          skill: 'design-quality',
          file: '03-design-system.md',
          issue: `Missing ${label} specification — design system must define ${label} per frontend-design skill`,
          severity: 'warning',
        });
      }
    }

    if (dimensionsCovered < 4) {
      findings.push({
        skill: 'design-quality',
        file: '03-design-system.md',
        issue: `Only ${dimensionsCovered}/6 design quality dimensions addressed — design system is underspecified`,
        severity: 'error',
      });
    }

    // Check for generic font warning
    if (dsLower.includes('arial') || dsLower.includes('helvetica') || dsLower.includes('roboto')) {
      findings.push({
        skill: 'design-quality',
        file: '03-design-system.md',
        issue: 'Uses generic fonts (Arial/Helvetica/Roboto) — should use Segoe UI or distinctive typography per frontend-design skill',
        severity: 'warning',
      });
    }

    // Check implementation guide references skills
    const implGuide = files.get('12-implementation-guide.md');
    if (implGuide) {
      const implLower = implGuide.toLowerCase();
      if (!implLower.includes('skeleton') && !implLower.includes('five state') && !implLower.includes('5 state')) {
        findings.push({
          skill: 'design-quality',
          file: '12-implementation-guide.md',
          issue: 'Implementation guide does not reference five-state rule or skeleton patterns — should guide developers on state handling',
          severity: 'warning',
        });
      }
    }

    return findings;
  }

  // ── Helpers ────────────────────────────────────────────────

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
