// ═══════════════════════════════════════════════════════════
// GSD V6 — Per-Project Stack Context
// Resolves target-project stack configuration from
// docs/gsd/stack-overrides.md. Defaults to .NET 8 if the file
// is absent. Preserves existing behavior for projects
// bootstrapped before v6.1.0.
// ═══════════════════════════════════════════════════════════

import * as fs from 'fs/promises';
import * as path from 'path';

export interface ProjectStackContext {
  // Backend
  backendFramework: string;        // e.g. "net9.0", "net8.0", "net10.0"
  backendSdk: string;              // e.g. ".NET 10 SDK"
  solutionFileFormat: 'sln' | 'slnx';
  dataAccessPattern: string;       // e.g. "Dapper + stored procedures"
  database: string;                // e.g. "SQL Server"

  // Frontend
  frontendFramework: string;       // e.g. "React 18"
  frontendUiLibrary: string;       // e.g. "Fluent UI v9"
  frontendBuildTool: string;       // e.g. "Vite"

  // Mobile
  mobileFramework: string | null;  // e.g. "React Native" or null
  mobileToolchain: string | null;  // e.g. "Expo managed workflow"

  // Agent
  agentLanguage: string | null;    // e.g. "Go" or null

  // Compliance
  complianceFrameworks: string[];  // e.g. ["SOC 2", "HIPAA", ...]

  // Raw document for agents that want the markdown directly
  rawMarkdown: string | null;

  // Indicates whether this was resolved from an override file or defaulted
  source: 'override' | 'default';

  // Where the override file was looked for (absolute path)
  resolvedFromPath: string | null;
}

export const DEFAULT_STACK_CONTEXT: ProjectStackContext = {
  backendFramework: 'net8.0',
  backendSdk: '.NET 8 SDK',
  solutionFileFormat: 'sln',
  dataAccessPattern: 'Dapper + stored procedures',
  database: 'SQL Server',
  frontendFramework: 'React 18',
  frontendUiLibrary: 'Fluent UI v9',
  frontendBuildTool: 'Vite',
  mobileFramework: null,
  mobileToolchain: null,
  agentLanguage: null,
  complianceFrameworks: ['SOC 2', 'HIPAA', 'PCI', 'GDPR'],
  rawMarkdown: null,
  source: 'default',
  resolvedFromPath: null,
};

/**
 * Reads `<projectRoot>/docs/gsd/stack-overrides.md` and parses known
 * fields. If the file is absent, returns v6.0.0 defaults (`.NET 8`) for
 * backward compatibility.
 *
 * @param projectRoot Absolute path to the target project root
 */
export async function getProjectStackContext(
  projectRoot: string,
): Promise<ProjectStackContext> {
  const overridePath = path.join(projectRoot, 'docs', 'gsd', 'stack-overrides.md');

  let rawMarkdown: string;
  try {
    rawMarkdown = await fs.readFile(overridePath, 'utf-8');
  } catch {
    return { ...DEFAULT_STACK_CONTEXT, resolvedFromPath: overridePath };
  }

  return { ...parseStackOverrides(rawMarkdown), resolvedFromPath: overridePath };
}

/**
 * Parses stack-overrides.md markdown table rows into ProjectStackContext
 * fields. Tolerant of missing fields — falls back to defaults for anything
 * not declared. Never throws on malformed input.
 */
export function parseStackOverrides(markdown: string): ProjectStackContext {
  const ctx: ProjectStackContext = {
    ...DEFAULT_STACK_CONTEXT,
    source: 'override',
    rawMarkdown: markdown,
  };

  const lines = markdown.split('\n');
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed.startsWith('|') || trimmed.startsWith('|---') || trimmed.startsWith('|:')) continue;

    const cells = trimmed
      .split('|')
      .map((c) => c.trim())
      .filter((c) => c.length > 0);
    if (cells.length < 2) continue;

    const label = cells[0].toLowerCase();
    const value = cells[1];

    // Skip header rows like `| Field | Value |`
    if (value.toLowerCase() === 'value' || value.toLowerCase() === 'setting') continue;

    if (label.includes('backend runtime') || label.includes('backend framework') || label === 'backend') {
      ctx.backendFramework = normalizeFramework(value);
    } else if (label.includes('backend sdk') || label === 'sdk') {
      ctx.backendSdk = value;
    } else if (label.includes('solution file')) {
      ctx.solutionFileFormat = value.toLowerCase().includes('slnx') ? 'slnx' : 'sln';
    } else if (label.includes('data access')) {
      ctx.dataAccessPattern = value;
    } else if (label === 'database') {
      ctx.database = value;
    } else if (label.includes('frontend framework') || label === 'frontend') {
      ctx.frontendFramework = value;
    } else if (label.includes('frontend ui library') || label.includes('ui library')) {
      ctx.frontendUiLibrary = value;
    } else if (label.includes('frontend build') || label === 'build tool') {
      ctx.frontendBuildTool = value;
    } else if (label.includes('mobile framework') || label === 'mobile') {
      ctx.mobileFramework = isNone(value) ? null : value;
    } else if (label.includes('mobile toolchain')) {
      ctx.mobileToolchain = isNone(value) ? null : value;
    } else if (label.includes('agent language') || label.includes('remote agent language')) {
      ctx.agentLanguage = isNone(value) ? null : value;
    } else if (label.includes('compliance')) {
      ctx.complianceFrameworks = value
        .split(/[,/]/)
        .map((s) => s.trim())
        .filter((s) => s.length > 0);
    }
  }

  return ctx;
}

/**
 * Normalizes various ways a user might write a .NET framework to the
 * canonical `net{N}.0` form. Pass-through for unrecognized values.
 */
export function normalizeFramework(value: string): string {
  const v = value.toLowerCase().replace(/\s+/g, '');
  if (v.includes('net10') || v.includes('.net10')) return 'net10.0';
  if (v.includes('net9') || v.includes('.net9')) return 'net9.0';
  if (v.includes('net8') || v.includes('.net8')) return 'net8.0';
  if (v.includes('net7') || v.includes('.net7')) return 'net7.0';
  return value;
}

function isNone(value: string): boolean {
  const v = value.toLowerCase().trim();
  return v === 'none' || v === 'n/a' || v === '-' || v === '(none)';
}

/**
 * Renders the stack context as a prompt-injectable block. Agents read this
 * block in their system prompt and honor the declared framework.
 */
export function renderStackContextBlock(ctx: ProjectStackContext): string {
  const lines: string[] = [];
  lines.push('--- PROJECT STACK CONTEXT ---');
  lines.push(`Backend framework: ${ctx.backendFramework}`);
  lines.push(`Backend SDK: ${ctx.backendSdk}`);
  lines.push(`Solution file format: ${ctx.solutionFileFormat}`);
  lines.push(`Data access: ${ctx.dataAccessPattern}`);
  lines.push(`Database: ${ctx.database}`);
  lines.push(`Frontend: ${ctx.frontendFramework} + ${ctx.frontendUiLibrary} + ${ctx.frontendBuildTool}`);
  if (ctx.mobileFramework) {
    lines.push(`Mobile: ${ctx.mobileFramework}${ctx.mobileToolchain ? ` (${ctx.mobileToolchain})` : ''}`);
  }
  if (ctx.agentLanguage) {
    lines.push(`Agent language: ${ctx.agentLanguage}`);
  }
  lines.push(`Compliance: ${ctx.complianceFrameworks.join(', ')}`);
  lines.push('');
  lines.push(`Source: ${ctx.source}  // "override" means the project declared this; "default" means GSD v6.0.0 defaults`);
  lines.push('');
  lines.push('IMPORTANT: If this context says backend is net9.0 or newer, do NOT generate');
  lines.push('code, diagnostics, or recommendations assuming .NET 8. Honor the declared');
  lines.push('framework for every artifact (csproj TargetFramework, SDK version, docs).');
  lines.push('--- END STACK CONTEXT ---');
  return lines.join('\n');
}
