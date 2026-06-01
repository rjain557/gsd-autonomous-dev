// ═══════════════════════════════════════════════════════════
// ComplianceAgent
// Compliance-lead agent for the GSD pipeline. Replaces the
// human compliance-lead contractor from myJian §10.15. Maps
// Edge telemetry → controls across all 16 frameworks, generates
// evidence packs, drafts management assertions for RJain signoff,
// detects control gaps. Read-only.
// ═══════════════════════════════════════════════════════════

import { BaseAgent } from '../harness/base-agent';
import type {
  AgentInput,
  AgentOutput,
  ComplianceAgentInput,
  ComplianceArtifacts,
  ComplianceFramework,
  FrameworkResult,
  ControlMappingGroup,
  ComplianceGap,
  AttestationDriftItem,
  SignatoryAction,
} from '../harness/types';
import * as fs from 'fs';
import * as path from 'path';

export class ComplianceAgent extends BaseAgent {
  protected async run(input: AgentInput): Promise<AgentOutput> {
    const { requested_frameworks, client_scope, window, evidence_mode, prior_evidence_pack_ids } = input as ComplianceAgentInput;

    // Pre-load framework reference files (filtered to requested frameworks only)
    const frameworkRefs = await this.loadFrameworkRefs(requested_frameworks);
    const telemetryCatalog = await this.loadTelemetryCatalog();
    const priorPacks = await this.loadPriorPacks(prior_evidence_pack_ids);

    const systemPrompt = await this.buildSystemPrompt();

    const userMessage = [
      '## Requested Frameworks',
      requested_frameworks.join(', '),
      '',
      '## Client Scope',
      client_scope,
      '',
      '## Window',
      `${window.start} to ${window.end} (mode: ${evidence_mode})`,
      '',
      '## Edge Telemetry Catalog',
      telemetryCatalog.substring(0, 4000),
      '',
      '## Framework References (excerpts)',
      frameworkRefs.substring(0, 12000),
      '',
      '## Prior Evidence Packs (for diff)',
      priorPacks || '(no prior packs referenced)',
      '',
      '## Instructions',
      '',
      'Run FOUR passes:',
      '1. **Control mapping**: for each framework, map each control to evidence source(s) from the telemetry catalog. Flag controls with no source as gaps.',
      '2. **Evidence pack generation**: build the auditor-ready evidence record schema. Draft the management assertion text for each framework.',
      '3. **Gap analysis**: for each gap, write a remediation task (what new Edge plugin / SQL view / telemetry event is needed). Effort + risk severity.',
      '4. **Continuous-attestation drift**: for previously-mapped controls, check whether the source still emits in the window. Flag drifts.',
      '',
      '**Cross-framework consolidation**: many controls map to the same evidence. Express N-to-1 with control_mapping_groups so the same evidence is not re-evaluated.',
      '',
      '**Named signatories**: every framework requires a human signatory at audit time. RJain (CEO) is the default. List in signatoryActions.',
      '',
      'Return a JSON ComplianceArtifacts with: pack_id, generated_at, client_scope, window, framework_results, control_mapping_groups, gaps, continuous_attestation_drift, signatoryActions, evidence_pack_path.',
      '',
      'Output ONLY valid JSON.',
    ].join('\n');

    const schema = {
      type: 'object' as const,
      properties: {
        pack_id: { type: 'string' },
        generated_at: { type: 'string' },
        client_scope: { type: 'string' },
        window: {
          type: 'object',
          properties: {
            start: { type: 'string' },
            end: { type: 'string' },
          },
          required: ['start', 'end'],
        },
        framework_results: { type: 'array' },
        control_mapping_groups: { type: 'array' },
        gaps: { type: 'array' },
        continuous_attestation_drift: { type: 'array' },
        signatoryActions: { type: 'array' },
        evidence_pack_path: { type: 'string' },
      },
      required: ['pack_id', 'generated_at', 'framework_results', 'gaps', 'signatoryActions'],
    };

    const response = await this.callLLM(systemPrompt, userMessage, schema);
    return this.parseResult(response, requested_frameworks, client_scope, window);
  }

  private async loadFrameworkRefs(frameworks: ComplianceFramework[]): Promise<string> {
    const refDir = path.join(process.cwd(), 'memory', 'knowledge', 'frameworks');
    const parts: string[] = [];

    for (const fw of frameworks) {
      const fileName = `${fw.toLowerCase().replace(/_/g, '-')}.md`;
      const filePath = path.join(refDir, fileName);
      try {
        const body = await fs.promises.readFile(filePath, 'utf-8');
        parts.push(`### ${fw}\n${body.substring(0, 4000)}`);
      } catch {
        parts.push(`### ${fw}\n(reference doc missing at ${filePath} — treat as cold-start)`);
      }
    }
    return parts.join('\n\n');
  }

  private async loadTelemetryCatalog(): Promise<string> {
    const catalogPath = path.join(process.cwd(), 'memory', 'knowledge', 'edge-telemetry-catalog.md');
    try {
      return await fs.promises.readFile(catalogPath, 'utf-8');
    } catch {
      return '(edge-telemetry-catalog.md missing — control mapping cannot proceed)';
    }
  }

  private async loadPriorPacks(packIds: string[] | undefined): Promise<string> {
    if (!packIds || packIds.length === 0) return '';
    const packDir = path.join(process.cwd(), 'memory', 'decisions', 'compliance');
    const parts: string[] = [];
    for (const id of packIds) {
      const filePath = path.join(packDir, `${id}.md`);
      try {
        const body = await fs.promises.readFile(filePath, 'utf-8');
        parts.push(`### ${id}\n${body.substring(0, 2000)}`);
      } catch {
        // ignore missing
      }
    }
    return parts.join('\n\n') || '(no prior packs found on disk)';
  }

  private parseResult(
    llmResponse: string,
    frameworks: ComplianceFramework[],
    clientScope: string,
    window: { start: string; end: string },
  ): ComplianceArtifacts {
    const parsed = this.extractJSON<Record<string, unknown>>(llmResponse);

    const pack_id = String(parsed.pack_id ?? `compliance-${clientScope}-${Date.now()}`);
    const generated_at = String(parsed.generated_at ?? new Date().toISOString());

    const framework_results: FrameworkResult[] = Array.isArray(parsed.framework_results)
      ? (parsed.framework_results as Record<string, unknown>[]).map(fr => ({
          framework: fr.framework as ComplianceFramework,
          total_controls: Number(fr.total_controls ?? 0),
          mapped_controls: Number(fr.mapped_controls ?? 0),
          gap_count: Number(fr.gap_count ?? 0),
          management_assertion_draft: String(fr.management_assertion_draft ?? ''),
          exceptions: Array.isArray(fr.exceptions) ? (fr.exceptions as FrameworkResult['exceptions']) : [],
        }))
      : [];

    const control_mapping_groups: ControlMappingGroup[] = Array.isArray(parsed.control_mapping_groups)
      ? (parsed.control_mapping_groups as ControlMappingGroup[])
      : [];

    const gaps: ComplianceGap[] = Array.isArray(parsed.gaps)
      ? (parsed.gaps as ComplianceGap[])
      : [];

    const continuous_attestation_drift: AttestationDriftItem[] = Array.isArray(parsed.continuous_attestation_drift)
      ? (parsed.continuous_attestation_drift as AttestationDriftItem[])
      : [];

    const signatoryActions: SignatoryAction[] = Array.isArray(parsed.signatoryActions)
      ? (parsed.signatoryActions as SignatoryAction[])
      : frameworks.map(fw => ({
          category: 'compliance-attestation' as const,
          description: `Management assertion required for ${fw} window ${window.start} to ${window.end}`,
          signatory: 'CEO' as const,
          blocking: false,
        }));

    const evidence_pack_path = String(parsed.evidence_pack_path ?? `decisions/compliance/${pack_id}.md`);

    return {
      pack_id,
      generated_at,
      client_scope: clientScope,
      window,
      framework_results,
      control_mapping_groups,
      gaps,
      continuous_attestation_drift,
      signatoryActions,
      evidence_pack_path,
    };
  }
}
