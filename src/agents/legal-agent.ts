// ═══════════════════════════════════════════════════════════
// LegalAgent
// Legal drafting agent for the GSD pipeline. Replaces the human
// retained-counsel time from myJian §10.15. Drafts MSA/BAA/EULA/
// privacy/consent/breach-notification documents that RJain or
// retained counsel reviews and signs. UPL boundary is enforced via
// requires_licensed_attorney_review flag.
// ═══════════════════════════════════════════════════════════

import { BaseAgent } from '../harness/base-agent';
import type {
  AgentInput,
  AgentOutput,
  LegalAgentInput,
  LegalArtifact,
  LegalDocumentType,
  LegalJurisdiction,
  LegalCitation,
  JurisdictionSection,
  BoundaryViolation,
  SignatoryAction,
} from '../harness/types';
import * as fs from 'fs';
import * as path from 'path';

const TECH_LEGAL_REPO = process.env.TECH_LEGAL_REPO ?? 'D:/VSCode/tech-legal';

export class LegalAgent extends BaseAgent {
  protected async run(input: AgentInput): Promise<AgentOutput> {
    const { document_type, triggering_capability, affected_jurisdictions, counterparty, baseline_template_path } = input as LegalAgentInput;

    const jurisdictionMatrix = await this.loadJurisdictionMatrix();
    const uplBoundaries = await this.loadUplBoundaries();
    const baselineTemplate = await this.loadBaselineTemplate(document_type, baseline_template_path);

    const systemPrompt = await this.buildSystemPrompt();

    const userMessage = [
      '## Document Type',
      document_type,
      '',
      '## Triggering Capability',
      triggering_capability,
      '',
      '## Affected Jurisdictions',
      affected_jurisdictions.join(', '),
      '',
      '## Counterparty',
      counterparty ? `${counterparty.name} (${counterparty.type})${counterparty.existing_contract_id ? ' — existing contract: ' + counterparty.existing_contract_id : ''}` : '(no counterparty)',
      '',
      '## Jurisdiction Matrix (excerpt for affected jurisdictions)',
      jurisdictionMatrix.substring(0, 4000),
      '',
      '## UPL Boundaries',
      uplBoundaries.substring(0, 2000),
      '',
      '## Baseline Template',
      baselineTemplate ? baselineTemplate.substring(0, 4000) : '(no template — draft from scratch)',
      '',
      '## Instructions',
      '',
      'Run FIVE passes:',
      '1. **Statute identification**: for each affected jurisdiction, identify controlling statutes. Cite by name, citation, effective date.',
      '2. **Template selection**: load the closest baseline from tech-legal; identify variations needed.',
      '3. **Drafting**: produce the draft with "DRAFT — REQUIRES ATTORNEY REVIEW" header, inline citations, per-jurisdiction sections.',
      '4. **UPL boundary check**: for each clause, classify as preparation (OK) vs advice (boundary violation). Refuse clauses that cross.',
      '5. **Named-signatory identification**: list internal + counterparty signatories, recommended attorney review level.',
      '',
      '**Default Technijian signatory**: RJain (CEO). Adjust if the document calls for a different officer (Privacy Officer, CISO, etc.).',
      '',
      'Return a JSON LegalArtifact with: draft_path, document_type, affected_jurisdictions, requires_licensed_attorney_review, attorney_review_level, citations, jurisdiction_specific_sections, signatoryActions, boundary_violations, draft_body, plain_english_summary, statute_verification_recommended.',
      '',
      'The draft_body is the full document text — be thorough but stay inside UPL bounds (preparation, not advice).',
      '',
      'Output ONLY valid JSON.',
    ].join('\n');

    const schema = {
      type: 'object' as const,
      properties: {
        draft_path: { type: 'string' },
        document_type: { type: 'string' },
        affected_jurisdictions: { type: 'array', items: { type: 'string' } },
        requires_licensed_attorney_review: { type: 'boolean' },
        attorney_review_level: { type: 'string', enum: ['in-house', 'outside-counsel-general', 'outside-counsel-specialist'] },
        citations: { type: 'array' },
        jurisdiction_specific_sections: { type: 'array' },
        signatoryActions: { type: 'array' },
        boundary_violations: { type: 'array' },
        draft_body: { type: 'string' },
        plain_english_summary: { type: 'string' },
        statute_verification_recommended: { type: 'boolean' },
      },
      required: ['draft_path', 'document_type', 'requires_licensed_attorney_review', 'draft_body'],
    };

    const response = await this.callLLM(systemPrompt, userMessage, schema);
    return this.parseResult(response, document_type, affected_jurisdictions);
  }

  private async loadJurisdictionMatrix(): Promise<string> {
    const filePath = path.join(process.cwd(), 'memory', 'knowledge', 'jurisdiction-matrix.md');
    try {
      return await fs.promises.readFile(filePath, 'utf-8');
    } catch {
      return '(jurisdiction-matrix.md missing — relying on framework documents alone)';
    }
  }

  private async loadUplBoundaries(): Promise<string> {
    const filePath = path.join(process.cwd(), 'memory', 'knowledge', 'upl-boundaries.md');
    try {
      return await fs.promises.readFile(filePath, 'utf-8');
    } catch {
      return [
        'UPL boundary (default rules, in absence of upl-boundaries.md):',
        '- Refuse: tactical legal advice in adversarial situations',
        '- Refuse: drafting court filings, discovery responses, regulator-facing letters without attorney review',
        '- Allow: preparation of contracts/notices/policies marked DRAFT — REQUIRES ATTORNEY REVIEW',
        '- Allow: state law summaries with statute citations',
        '- Allow: jurisdiction comparison tables',
        '- Always set requires_licensed_attorney_review=true on any output that will be executed by Technijian',
      ].join('\n');
    }
  }

  private async loadBaselineTemplate(documentType: LegalDocumentType, override?: string): Promise<string | null> {
    const candidatePaths = override
      ? [override]
      : [
          path.join(TECH_LEGAL_REPO, 'templates', `${documentType}.md`),
          path.join(TECH_LEGAL_REPO, 'templates', `${documentType}-template.md`),
          path.join(TECH_LEGAL_REPO, documentType, 'template.md'),
        ];

    for (const p of candidatePaths) {
      try {
        return await fs.promises.readFile(p, 'utf-8');
      } catch {
        // try next
      }
    }
    return null;
  }

  private parseResult(
    llmResponse: string,
    documentType: LegalDocumentType,
    jurisdictions: LegalJurisdiction[],
  ): LegalArtifact {
    const parsed = this.extractJSON<Record<string, unknown>>(llmResponse);

    const draft_path = String(parsed.draft_path ?? `tech-legal/drafts/${documentType}-${Date.now()}.md`);
    const requires_review = Boolean(parsed.requires_licensed_attorney_review ?? true);

    const citations: LegalCitation[] = Array.isArray(parsed.citations)
      ? (parsed.citations as LegalCitation[])
      : [];

    const jurisdiction_sections: JurisdictionSection[] = Array.isArray(parsed.jurisdiction_specific_sections)
      ? (parsed.jurisdiction_specific_sections as JurisdictionSection[])
      : [];

    const signatoryActions: SignatoryAction[] = Array.isArray(parsed.signatoryActions)
      ? (parsed.signatoryActions as SignatoryAction[])
      : [{
          category: 'legal-execution',
          description: `Counterparty signature required on ${documentType}`,
          signatory: 'CEO',
          blocking: false,
          artifactPath: draft_path,
        }];

    const boundary_violations: BoundaryViolation[] = Array.isArray(parsed.boundary_violations)
      ? (parsed.boundary_violations as BoundaryViolation[])
      : [];

    const draft_body = String(parsed.draft_body ?? '');
    const plain_english_summary = String(parsed.plain_english_summary ?? '');

    // Defense-in-depth: ALWAYS true if any output crosses to execution
    const executionBound = ['msa-amendment', 'baa-update', 'eula', 'breach-notification', 'data-processing-addendum'].includes(documentType);
    const finalRequiresReview = requires_review || executionBound;

    return {
      draft_path,
      document_type: documentType,
      affected_jurisdictions: jurisdictions,
      requires_licensed_attorney_review: finalRequiresReview,
      attorney_review_level: (parsed.attorney_review_level as LegalArtifact['attorney_review_level']) ?? 'outside-counsel-general',
      citations,
      jurisdiction_specific_sections: jurisdiction_sections,
      redline_against: parsed.redline_against as string | undefined,
      signatoryActions,
      boundary_violations,
      draft_body,
      plain_english_summary,
      statute_verification_recommended: Boolean(parsed.statute_verification_recommended),
    };
  }
}
