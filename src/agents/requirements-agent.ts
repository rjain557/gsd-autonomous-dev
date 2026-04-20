// ═══════════════════════════════════════════════════════════
// RequirementsAgent (Phase A)
// Two-stage process:
//   Stage 1: Validate input specs for conflicts, gaps, and completeness
//   Stage 2: Generate Intake Pack from validated specifications
// ═══════════════════════════════════════════════════════════

import { BaseAgent } from '../harness/base-agent';
import type { AgentInput, AgentOutput } from '../harness/types';
import type { IntakePack } from '../harness/sdlc-types';

// ── Spec Validation Types ──────────────────────────────────

export interface SpecFinding {
  category: 'stack_conflict' | 'contradiction' | 'ambiguity' | 'missing_detail' | 'undefined_rule' | 'duplicate';
  document: string;
  location: string;
  issue: string;
  resolution: string;
  severity: 'critical' | 'high' | 'medium' | 'low';
}

export interface SpecValidationReport {
  specDocuments: string[];
  totalFindings: number;
  criticalCount: number;
  highCount: number;
  findings: SpecFinding[];
  stackAligned: boolean;
  passedValidation: boolean;
}

// ── Authoritative Stack Definition ─────────────────────────
// v6.1.0: backend is now derived from the PROJECT STACK CONTEXT block
// that BaseAgent injects into the system prompt. The default here remains
// ".NET 8" for backward compatibility; projects with docs/gsd/stack-overrides.md
// get their declared framework (net9.0, net10.0, etc.) instead.

type AuthoritativeStack = {
  database: string;
  orm: string;
  spPattern: string;
  backend: string;
  frontend: string;
  auth: string;
  infra: string;
  compliance: string[];
};

function buildAuthoritativeStack(stack: {
  backendFramework: string;
  database: string;
  dataAccessPattern: string;
  frontendFramework: string;
  frontendUiLibrary: string;
  complianceFrameworks: string[];
}): AuthoritativeStack {
  // Map canonical net9.0 → ".NET 9 Web API on IIS" for human-facing prose
  const nicename = (fw: string): string => {
    const m = fw.match(/^net(\d+)(?:\.\d+)?$/);
    return m ? `.NET ${m[1]} Web API on IIS` : `${fw} Web API on IIS`;
  };
  return {
    database: stack.database.includes('SQL Server') ? 'MS SQL Server 2022' : stack.database,
    orm: `${stack.dataAccessPattern} (no EF Core, no inline SQL)`,
    spPattern: 'usp_{Entity}_{Action}',
    backend: nicename(stack.backendFramework),
    frontend: `${stack.frontendFramework} + TypeScript + ${stack.frontendUiLibrary} + React Query v5`,
    auth: 'Microsoft Entra ID (Azure AD) + JWT Bearer',
    infra: 'Windows Server 2022 / IIS 10 Web Farm (no Docker/K8s)',
    compliance: stack.complianceFrameworks,
  };
}

const BANNED_TECH = [
  { pattern: /\bpostgre(sql|s)\b/i, label: 'PostgreSQL', replacement: 'MS SQL Server 2022' },
  { pattern: /\b(entity\s*framework|ef\s*core|dbcontext|savechanges\s*interceptor)\b/i, label: 'Entity Framework / EF Core', replacement: 'Dapper + SP-Only' },
  { pattern: /\bvue\.?js\b/i, label: 'Vue.js', replacement: 'React 18 + Fluent UI v9' },
  { pattern: /\bmediatr\b/i, label: 'MediatR', replacement: 'Direct SP calls via Dapper' },
  { pattern: /\bcqrs\b/i, label: 'CQRS pattern', replacement: 'SP-Only with thin API gateway' },
  { pattern: /\bncalc\b/i, label: 'NCalc', replacement: 'T-SQL expression evaluation in SP' },
  { pattern: /\bpgvector\b/i, label: 'pgvector', replacement: 'SQL Server full-text search or Azure AI Search' },
  { pattern: /\brtk\s*query\b/i, label: 'RTK Query', replacement: 'React Query v5 (TanStack Query)' },
  { pattern: /\bidentity\s*server\b/i, label: 'IdentityServer', replacement: 'Microsoft Entra ID' },
  { pattern: /\b(docker|k8s|kubernetes|containerized\s*microservices)\b/i, label: 'Docker/K8s', replacement: 'IIS Web Farm + ARR' },
  { pattern: /\bredux\b/i, label: 'Redux', replacement: 'React Query v5 + React Context' },
  { pattern: /\bgridstack\b/i, label: 'GridStack', replacement: 'Fluent UI DataGrid + react-window' },
];

// ── Agent Implementation ───────────────────────────────────

export class RequirementsAgent extends BaseAgent {
  protected async run(input: AgentInput): Promise<AgentOutput> {
    const {
      projectName,
      projectDescription,
      specDocuments,
    } = input as {
      projectName: string;
      projectDescription: string;
      specDocuments?: Array<{ name: string; content: string }>;
    };

    // Stage 1: Validate specs if provided
    let validationReport: SpecValidationReport | null = null;
    if (specDocuments && specDocuments.length > 0) {
      validationReport = this.validateSpecs(specDocuments);

      // If critical stack conflicts exist, run LLM-powered deep validation
      if (!validationReport.stackAligned || validationReport.criticalCount > 0) {
        const deepFindings = await this.deepValidateWithLLM(specDocuments, validationReport);
        validationReport.findings.push(...deepFindings);
        validationReport.totalFindings = validationReport.findings.length;
      }
    }

    // Stage 2: Generate Intake Pack
    const intakePack = await this.generateIntakePack(
      projectName,
      projectDescription,
      specDocuments,
      validationReport,
    );

    return {
      validationReport,
      intakePack,
    } as unknown as AgentOutput;
  }

  // ── Stage 1: Spec Validation ───────────────────────────────

  /**
   * Fast local validation: scan spec documents for banned tech patterns,
   * detect obvious contradictions, and flag structural gaps.
   */
  private validateSpecs(docs: Array<{ name: string; content: string }>): SpecValidationReport {
    const findings: SpecFinding[] = [];

    for (const doc of docs) {
      // Check for banned tech references
      this.checkStackConflicts(doc, findings);

      // Check for ambiguous language
      this.checkAmbiguities(doc, findings);

      // Check for missing business rules
      this.checkUndefinedRules(doc, findings);
    }

    // Cross-document checks (need all docs)
    if (docs.length > 1) {
      this.checkCrossDocContradictions(docs, findings);
      this.checkDuplicates(docs, findings);
      this.checkMissingDetails(docs, findings);
    }

    const criticalCount = findings.filter(f => f.severity === 'critical').length;
    const highCount = findings.filter(f => f.severity === 'high').length;
    const stackConflicts = findings.filter(f => f.category === 'stack_conflict');

    return {
      specDocuments: docs.map(d => d.name),
      totalFindings: findings.length,
      criticalCount,
      highCount,
      findings,
      stackAligned: stackConflicts.length === 0,
      passedValidation: criticalCount === 0 && stackConflicts.length === 0,
    };
  }

  /** Scan a single document for references to banned technologies. */
  private checkStackConflicts(
    doc: { name: string; content: string },
    findings: SpecFinding[],
  ): void {
    const lines = doc.content.split('\n');

    for (const banned of BANNED_TECH) {
      for (let i = 0; i < lines.length; i++) {
        if (banned.pattern.test(lines[i])) {
          findings.push({
            category: 'stack_conflict',
            document: doc.name,
            location: `Line ${i + 1}`,
            issue: `References ${banned.label}: "${lines[i].trim().substring(0, 120)}"`,
            resolution: `Replace with ${banned.replacement}`,
            severity: 'critical',
          });
        }
      }
    }
  }

  /** Flag ambiguous language patterns that produce untestable requirements. */
  private checkAmbiguities(
    doc: { name: string; content: string },
    findings: SpecFinding[],
  ): void {
    const ambiguousPatterns = [
      { pattern: /\bsupport(?:s)?\s+for\b/i, issue: '"Support for" is undefined — what constitutes support?' },
      { pattern: /\bshould\s+be\s+(?:fast|quick|responsive|performant)\b/i, issue: 'Unquantified performance requirement — needs measurable target' },
      { pattern: /\bas\s+needed\b/i, issue: '"As needed" is undefined — needs specific trigger conditions' },
      { pattern: /\betc\.?\b/i, issue: '"etc." hides undefined scope — enumerate all items explicitly' },
      { pattern: /\bvarious\b/i, issue: '"Various" is ambiguous — enumerate the specific items' },
      { pattern: /\bflexible\b/i, issue: '"Flexible" needs concrete definition of what can change and how' },
      { pattern: /\bscalable\b/i, issue: '"Scalable" needs quantified targets (users, data volume, throughput)' },
    ];

    const lines = doc.content.split('\n');
    for (const { pattern, issue } of ambiguousPatterns) {
      for (let i = 0; i < lines.length; i++) {
        if (pattern.test(lines[i])) {
          findings.push({
            category: 'ambiguity',
            document: doc.name,
            location: `Line ${i + 1}`,
            issue: `${issue}: "${lines[i].trim().substring(0, 120)}"`,
            resolution: 'Quantify or enumerate the requirement',
            severity: 'medium',
          });
        }
      }
    }
  }

  /** Flag business rules that lack edge case definitions. */
  private checkUndefinedRules(
    doc: { name: string; content: string },
    findings: SpecFinding[],
  ): void {
    const content = doc.content.toLowerCase();

    const ruleChecks = [
      {
        trigger: /formula[- ]based\s+pricing/i,
        needs: ['rounding', 'decimal', 'precision', 'division.by.zero', 'error.handling'],
        label: 'Formula-based pricing',
      },
      {
        trigger: /deduction|moisture|contamination/i,
        needs: ['threshold', 'tier', 'percentage', 'reject'],
        label: 'Deduction/moisture/contamination rules',
      },
      {
        trigger: /commission/i,
        needs: ['tier', 'bracket', 'cap', 'clawback', 'split'],
        label: 'Commission calculation',
      },
      {
        trigger: /rental|overage/i,
        needs: ['grace', 'minimum', 'pro.?rat', 'frequency', 'cancel'],
        label: 'Rental/overage billing',
      },
      {
        trigger: /last.write.wins|lww|conflict.resolution/i,
        needs: ['sub.?second', 'field.level', 'record.level'],
        label: 'Offline sync conflict resolution',
      },
      {
        trigger: /fx.rate|exchange.rate|currency.conv/i,
        needs: ['source', 'ttl', 'cache', 'stale', 'fallback'],
        label: 'FX rate management',
      },
      {
        trigger: /state.machine|status.fsm|workflow/i,
        needs: ['guard', 'transition', 'block', 'who.can'],
        label: 'State machine transitions',
      },
    ];

    for (const check of ruleChecks) {
      if (check.trigger.test(doc.content)) {
        const missing = check.needs.filter(need => {
          const needPattern = new RegExp(need.replace(/\./g, '.?'), 'i');
          return !needPattern.test(content);
        });

        if (missing.length > 0) {
          findings.push({
            category: 'undefined_rule',
            document: doc.name,
            location: 'Document-wide',
            issue: `${check.label} mentioned but missing: ${missing.join(', ')}`,
            resolution: `Define explicit rules for: ${missing.join(', ')}`,
            severity: missing.length >= 3 ? 'high' : 'medium',
          });
        }
      }
    }
  }

  /** Compare documents for contradictions on the same topic. */
  private checkCrossDocContradictions(
    docs: Array<{ name: string; content: string }>,
    findings: SpecFinding[],
  ): void {
    // Check for conflicting state machines
    const fsmPatterns = docs.map(doc => {
      const match = doc.content.match(/(?:draft|status)\s*(?:>|->|➔|→)\s*\w+(?:\s*(?:>|->|➔|→)\s*\w+)*/gi);
      return { name: doc.name, fsms: match ?? [] };
    });

    if (fsmPatterns.filter(d => d.fsms.length > 0).length > 1) {
      const uniqueFsms = new Set(fsmPatterns.flatMap(d => d.fsms.map(f => f.toLowerCase().replace(/\s+/g, ''))));
      if (uniqueFsms.size > fsmPatterns.filter(d => d.fsms.length > 0).length) {
        findings.push({
          category: 'contradiction',
          document: fsmPatterns.map(d => d.name).join(', '),
          location: 'State machine definitions',
          issue: 'Different state machine definitions found across documents',
          resolution: 'Unify to a single FSM per entity with explicit transition guards',
          severity: 'high',
        });
      }
    }

    // Check for conflicting numeric targets
    const numericPatterns = [
      { pattern: /(\d+)%\s*(?:coverage|test)/gi, label: 'Test coverage target' },
      { pattern: /(\d+)\s*Hz/gi, label: 'Refresh rate' },
      { pattern: /(\d+)\s*(?:days?)\s*(?:old|expir)/gi, label: 'Expiration period' },
      { pattern: /(\d+)\s*(?:months?|days?)\s*(?:lookback|historical)/gi, label: 'Lookback period' },
    ];

    for (const { pattern, label } of numericPatterns) {
      const values: Array<{ doc: string; value: string }> = [];
      for (const doc of docs) {
        let match: RegExpExecArray | null;
        const re = new RegExp(pattern.source, pattern.flags);
        while ((match = re.exec(doc.content)) !== null) {
          values.push({ doc: doc.name, value: match[0] });
        }
      }
      const uniqueValues = new Set(values.map(v => v.value.toLowerCase().replace(/\s+/g, '')));
      if (uniqueValues.size > 1) {
        findings.push({
          category: 'contradiction',
          document: values.map(v => v.doc).join(', '),
          location: label,
          issue: `Conflicting ${label}: ${[...uniqueValues].join(' vs ')}`,
          resolution: 'Standardize to a single target value',
          severity: 'high',
        });
      }
    }
  }

  /** Detect the same feature described in multiple documents with different details. */
  private checkDuplicates(
    docs: Array<{ name: string; content: string }>,
    findings: SpecFinding[],
  ): void {
    const featureKeywords = [
      'scale gateway', 'signalr', 'mcp server', 'audit trail',
      'multi-tenancy', 'mobile app', 'dispatch board', 'accounting sync',
      'rental billing', 'export compliance', 'offline sync',
    ];

    for (const keyword of featureKeywords) {
      const docsWithFeature = docs.filter(d =>
        d.content.toLowerCase().includes(keyword),
      );
      if (docsWithFeature.length > 1) {
        findings.push({
          category: 'duplicate',
          document: docsWithFeature.map(d => d.name).join(', '),
          location: `Feature: "${keyword}"`,
          issue: `"${keyword}" described in ${docsWithFeature.length} documents — risk of implementation drift`,
          resolution: 'Consolidate into a single source of truth',
          severity: 'medium',
        });
      }
    }
  }

  /** Check for features mentioned in one doc but absent from others. */
  private checkMissingDetails(
    docs: Array<{ name: string; content: string }>,
    findings: SpecFinding[],
  ): void {
    const criticalFeatures = [
      { keyword: 'edi', label: 'EDI integration (ANSI X12 850/856)' },
      { keyword: 'etl', label: 'Data migration / ETL pipeline' },
      { keyword: 'disaster recovery', label: 'Disaster recovery / failover strategy' },
      { keyword: 'rate limit', label: 'API rate limiting' },
      { keyword: 'notification', label: 'Push notification system' },
      { keyword: 'reporting', label: 'Reporting / BI module' },
      { keyword: 'acceptance criteria', label: 'Testable acceptance criteria' },
    ];

    for (const { keyword, label } of criticalFeatures) {
      const docsWithFeature = docs.filter(d =>
        d.content.toLowerCase().includes(keyword),
      );
      if (docsWithFeature.length === 0) {
        findings.push({
          category: 'missing_detail',
          document: 'ALL',
          location: 'Document-wide',
          issue: `${label} not found in any specification document`,
          resolution: `Add ${label} section with full requirements`,
          severity: 'high',
        });
      } else if (docsWithFeature.length < docs.length && docs.length > 1) {
        const missingFrom = docs
          .filter(d => !d.content.toLowerCase().includes(keyword))
          .map(d => d.name);
        findings.push({
          category: 'missing_detail',
          document: missingFrom.join(', '),
          location: 'Document-wide',
          issue: `${label} present in ${docsWithFeature.map(d => d.name).join(', ')} but missing from ${missingFrom.join(', ')}`,
          resolution: 'Cross-reference or consolidate into a single document',
          severity: 'low',
        });
      }
    }
  }

  // ── LLM-Powered Deep Validation ────────────────────────────

  /**
   * Uses the LLM to find subtle contradictions and gaps
   * that pattern matching alone can't catch.
   */
  private async deepValidateWithLLM(
    docs: Array<{ name: string; content: string }>,
    localReport: SpecValidationReport,
  ): Promise<SpecFinding[]> {
    const systemPrompt = await this.buildSystemPrompt();

    const docSummaries = docs.map(d =>
      `## ${d.name}\n${d.content.substring(0, 6000)}`,
    ).join('\n\n---\n\n');

    const localFindingSummary = localReport.findings
      .filter(f => f.severity === 'critical' || f.severity === 'high')
      .map(f => `- [${f.severity}] ${f.category}: ${f.issue}`)
      .join('\n');

    const userMessage = [
      '## Task: Deep Spec Validation',
      '',
      'The local validator already found these issues:',
      localFindingSummary || '(none)',
      '',
      'Now find ADDITIONAL issues that pattern matching missed:',
      '1. Subtle cross-document contradictions (same feature, different behavior)',
      '2. Business rules that reference each other inconsistently',
      '3. Missing transition guards on state machines',
      '4. Calculation rules without precision/rounding specs',
      '5. Integration points without error handling specs',
      '',
      'Return ONLY valid JSON — an array of findings.',
      '',
      '## Spec Documents',
      docSummaries,
    ].join('\n');

    const schema = {
      type: 'array' as const,
      items: {
        type: 'object' as const,
        properties: {
          category: { type: 'string', enum: ['contradiction', 'ambiguity', 'missing_detail', 'undefined_rule'] },
          document: { type: 'string' },
          location: { type: 'string' },
          issue: { type: 'string' },
          resolution: { type: 'string' },
          severity: { type: 'string', enum: ['critical', 'high', 'medium', 'low'] },
        },
        required: ['category', 'document', 'issue', 'resolution', 'severity'],
      },
    };

    try {
      const response = await this.callLLM(systemPrompt, userMessage, schema);
      return this.extractJSON<SpecFinding[]>(response);
    } catch {
      // LLM deep validation is best-effort; don't block on failure
      return [];
    }
  }

  // ── Stage 2: Intake Pack Generation ────────────────────────

  private async generateIntakePack(
    projectName: string,
    projectDescription: string,
    specDocuments: Array<{ name: string; content: string }> | undefined,
    validationReport: SpecValidationReport | null,
  ): Promise<IntakePack> {
    const systemPrompt = await this.buildSystemPrompt();

    const specContext = specDocuments
      ? specDocuments.map(d => `## ${d.name}\n${d.content}`).join('\n\n---\n\n')
      : '';

    const validationContext = validationReport
      ? [
          '## Spec Validation Results',
          `Findings: ${validationReport.totalFindings} (${validationReport.criticalCount} critical, ${validationReport.highCount} high)`,
          `Stack Aligned: ${validationReport.stackAligned}`,
          '',
          'Critical/High findings to address in Intake Pack:',
          ...validationReport.findings
            .filter(f => f.severity === 'critical' || f.severity === 'high')
            .map(f => `- [${f.severity}/${f.category}] ${f.issue} → Resolution: ${f.resolution}`),
        ].join('\n')
      : '';

    const userMessage = [
      '## Project',
      `**Name:** ${projectName}`,
      `**Description:** ${projectDescription}`,
      '',
      specContext ? '## Input Specifications\n' + specContext : '',
      '',
      validationContext,
      '',
      '## Instructions',
      'Generate a complete Intake Pack with ALL of the following sections.',
      'Resolve any stack conflicts using the authoritative stack (SQL Server/Dapper/React/Fluent UI/Entra ID/IIS).',
      'Flag any undefined business rules with [NEEDS DEFINITION] in acceptance criteria.',
      'Every domain operation must include the SP name (usp_{Entity}_{Action}).',
      'Every RBAC role must list explicit denials (what it CANNOT access).',
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
        domainOperations: { type: 'array', items: { type: 'object', properties: { entity: { type: 'string' }, operations: { type: 'array', items: { type: 'string' } }, roles: { type: 'array', items: { type: 'string' } }, storedProcedures: { type: 'array', items: { type: 'string' } } } } },
        rbacSketch: { type: 'array', items: { type: 'object', properties: { role: { type: 'string' }, permissions: { type: 'array', items: { type: 'string' } }, denials: { type: 'array', items: { type: 'string' } } } } },
        nfrs: { type: 'array', items: { type: 'object', properties: { category: { type: 'string' }, requirement: { type: 'string' }, target: { type: 'string' } } } },
        riskRegister: { type: 'array', items: { type: 'object', properties: { risk: { type: 'string' }, likelihood: { type: 'string' }, impact: { type: 'string' }, mitigation: { type: 'string' } } } },
        acceptanceCriteria: { type: 'array', items: { type: 'object', properties: { id: { type: 'string' }, feature: { type: 'string' }, description: { type: 'string' }, spOrEndpoint: { type: 'string' }, testable: { type: 'boolean' } } } },
        dependencies: { type: 'array', items: { type: 'string' } },
      },
      required: ['problemStatement', 'outcomes', 'stakeholders', 'domainOperations', 'acceptanceCriteria'],
    };

    const response = await this.callLLM(systemPrompt, userMessage, schema);
    return this.extractJSON<IntakePack>(response);
  }
}
