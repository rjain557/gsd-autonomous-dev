// ═══════════════════════════════════════════════════════════
// ArchitectureAgent (Phase B)
// Two-stage process:
//   Stage 1: Generate Architecture Pack from Intake Pack
//   Stage 2: Self-validate output for conflicts, vagueness,
//            completeness, and traceability back to Phase A
// ═══════════════════════════════════════════════════════════

import { BaseAgent } from '../harness/base-agent';
import type { AgentInput, AgentOutput } from '../harness/types';
import type { IntakePack, ArchitecturePack } from '../harness/sdlc-types';

// ── Validation Types ───────────────────────────────────────

export interface ArchValidationFinding {
  category:
    | 'coverage_gap'
    | 'inconsistency'
    | 'missing_detail'
    | 'vagueness'
    | 'stack_violation'
    | 'security_gap';
  location: string;
  issue: string;
  resolution: string;
  severity: 'critical' | 'high' | 'medium' | 'low';
}

export interface ArchValidationReport {
  totalFindings: number;
  criticalCount: number;
  highCount: number;
  findings: ArchValidationFinding[];
  traceability: {
    entitiesCovered: number;
    entitiesTotal: number;
    acceptanceCriteriaCovered: number;
    acceptanceCriteriaTotal: number;
    spsCovered: number;
    spsTotal: number;
  };
  passedValidation: boolean;
}

// ── Banned tech patterns (shared with RequirementsAgent) ───

const BANNED_PATTERNS = [
  { pattern: /\bpostgre(sql|s)\b/i, label: 'PostgreSQL' },
  { pattern: /\b(entity\s*framework|ef\s*core|dbcontext)\b/i, label: 'EF Core' },
  { pattern: /\bvue\.?js\b/i, label: 'Vue.js' },
  { pattern: /\bmediatr\b/i, label: 'MediatR' },
  { pattern: /\bcqrs\b/i, label: 'CQRS' },
  { pattern: /\brtk\s*query\b/i, label: 'RTK Query' },
  { pattern: /\bidentity\s*server\b/i, label: 'IdentityServer' },
  { pattern: /\b(docker|k8s|kubernetes)\b/i, label: 'Docker/K8s' },
  { pattern: /\bpgvector\b/i, label: 'pgvector' },
  { pattern: /\bncalc\b/i, label: 'NCalc' },
];

const VAGUE_PATTERNS = [
  { pattern: /\bas\s+needed\b/i, label: '"as needed"' },
  { pattern: /\betc\.?\b/i, label: '"etc."' },
  { pattern: /\bvarious\b/i, label: '"various"' },
  { pattern: /\bflexible\b/i, label: '"flexible"' },
  { pattern: /\bTBD\b/, label: '"TBD"' },
  { pattern: /\bto\s+be\s+determined\b/i, label: '"to be determined"' },
  { pattern: /\bsome\s+kind\s+of\b/i, label: '"some kind of"' },
  { pattern: /\bappropriate\b/i, label: '"appropriate" (unspecified)' },
  { pattern: /\bsuitable\b/i, label: '"suitable" (unspecified)' },
];

// ── Agent Implementation ───────────────────────────────────

export class ArchitectureAgent extends BaseAgent {
  protected async run(input: AgentInput): Promise<AgentOutput> {
    const { intakePack, specDocuments } = input as {
      intakePack: IntakePack;
      specDocuments?: Array<{ name: string; content: string }>;
    };

    // Stage 1: Generate Architecture Pack
    const archPack = await this.generateArchitecturePack(intakePack, specDocuments);

    // Stage 2: Self-validate
    const localReport = this.localValidate(archPack, intakePack);

    // If local validation finds critical/high issues, run LLM deep validation
    if (localReport.criticalCount > 0 || localReport.highCount > 3) {
      const deepFindings = await this.deepValidateWithLLM(archPack, intakePack, localReport);
      localReport.findings.push(...deepFindings);
      localReport.totalFindings = localReport.findings.length;
      localReport.criticalCount = localReport.findings.filter(f => f.severity === 'critical').length;
      localReport.highCount = localReport.findings.filter(f => f.severity === 'high').length;
      localReport.passedValidation = localReport.criticalCount === 0;
    }

    return {
      architecturePack: archPack,
      validationReport: localReport,
    } as unknown as AgentOutput;
  }

  // ── Stage 1: Generate Architecture Pack ────────────────────

  private async generateArchitecturePack(
    intakePack: IntakePack,
    specDocuments?: Array<{ name: string; content: string }>,
  ): Promise<ArchitecturePack> {
    const systemPrompt = await this.buildSystemPrompt();

    // Build context from spec docs if available
    const specContext = specDocuments
      ? specDocuments
          .map(d => `## ${d.name}\n${d.content.substring(0, 4000)}`)
          .join('\n\n---\n\n')
      : '';

    const intakeJson = JSON.stringify(intakePack, null, 2);
    // Truncate if too large, prioritizing domain operations and acceptance criteria
    const truncatedIntake = intakeJson.length > 12000
      ? intakeJson.substring(0, 12000) + '\n... (truncated)'
      : intakeJson;

    const userMessage = [
      '## Intake Pack (Phase A)',
      '```json',
      truncatedIntake,
      '```',
      '',
      specContext ? '## Spec Documents (for additional context)\n' + specContext : '',
      '',
      '## Instructions',
      'Generate a complete Architecture Pack. Requirements:',
      '',
      '1. **System Context Diagram** (Mermaid C4): Show all actors (Trader, Weighmaster, Driver, AI Agent, etc.), external systems (Fastmarkets, QuickBooks, Mapbox, Azure Blob, ECB FX, EDI partners), and the NexGen ERP boundary.',
      '2. **Component Diagrams** (Mermaid): One per subsystem (CTBE, POST, LDAM, ITEC, MEBE, AFI, AAIO, CIS, LDM). Show IIS API layer, Dapper DAL, SP layer, tables.',
      '3. **Sequence Diagrams** (Mermaid): Order-to-cash flow, Scale capture flow, Dispatch assignment, MCP HITL flow, Mobile offline sync, ETL migration. Show exact SP names.',
      '4. **Data Flow Diagram** (Mermaid): React > API Controller > Dapper > SP > SQL Table > Response DTO. Plus SignalR path for scale streaming.',
      '5. **OpenAPI 3.0 YAML**: Every endpoint from domain operations. Include request/response DTO schemas, path params, query params, status codes (200, 201, 400, 401, 403, 404, 202 for HITL). Group by subsystem tags.',
      '6. **Data Model Inventory**: Every entity with ALL fields, SQL types (UNIQUEIDENTIFIER, NVARCHAR(n), DECIMAL(18,x), BIT, DATETIME2, TINYINT), nullable flags, FK references. MUST include Id, TenantId, CreatedAt, CreatedBy, UpdatedAt, UpdatedBy, IsDeleted on every entity.',
      '7. **Threat Model**: STRIDE classification at each trust boundary (Browser>API, API>DB, API>MCP, MobileApp>API, EdgeDaemon>SignalR, B2B Portal>API, EDI>API). Every threat needs a mitigation.',
      '8. **Observability Plan**: Serilog structured JSON logging, IIS request metrics, SQL DMV monitoring, correlation ID propagation (HTTP > SP > Audit), alerting thresholds for each KPI.',
      '9. **Promotion Model**: Dev > QA > Staging > Prod environments. DACPAC migration strategy. IIS WebDeploy. Rollback plan (DACPAC rollback script + IIS previous deployment).',
      '',
      'SP naming: usp_{Entity}_{Action}. DTO naming: Create{Entity}Dto, Update{Entity}Dto, {Entity}ResponseDto.',
      'Every entity from the Intake Pack MUST appear in the data model.',
      'Every SP from the Intake Pack MUST appear in at least one sequence diagram or OpenAPI endpoint.',
      'No vague language (TBD, as needed, various, etc.). Every statement must be specific.',
      'No banned tech (PostgreSQL, EF Core, Vue.js, MediatR, CQRS, RTK Query, IdentityServer, Docker/K8s).',
      '',
      'Return ONLY valid JSON matching the ArchitecturePack schema.',
    ].join('\n');

    const schema = {
      type: 'object' as const,
      properties: {
        systemContextDiagram: { type: 'string' },
        componentDiagrams: { type: 'array', items: { type: 'string' } },
        sequenceDiagrams: { type: 'array', items: { type: 'string' } },
        dataFlowDiagram: { type: 'string' },
        openApiDraft: { type: 'string' },
        dataModelInventory: {
          type: 'array',
          items: {
            type: 'object',
            properties: {
              entity: { type: 'string' },
              fields: {
                type: 'array',
                items: {
                  type: 'object',
                  properties: {
                    name: { type: 'string' },
                    type: { type: 'string' },
                    nullable: { type: 'boolean' },
                    fkReference: { type: 'string' },
                  },
                  required: ['name', 'type', 'nullable'],
                },
              },
            },
            required: ['entity', 'fields'],
          },
        },
        threatModel: {
          type: 'array',
          items: {
            type: 'object',
            properties: {
              threat: { type: 'string' },
              boundary: { type: 'string' },
              mitigation: { type: 'string' },
              severity: { type: 'string' },
              stride: { type: 'string' },
            },
            required: ['threat', 'boundary', 'mitigation', 'severity'],
          },
        },
        observabilityPlan: {
          type: 'object',
          properties: {
            logging: { type: 'string' },
            metrics: { type: 'string' },
            tracing: { type: 'string' },
            alerting: { type: 'string' },
          },
          required: ['logging', 'metrics', 'tracing', 'alerting'],
        },
        promotionModel: {
          type: 'object',
          properties: {
            environments: { type: 'array', items: { type: 'string' } },
            strategy: { type: 'string' },
            rollbackPlan: { type: 'string' },
          },
          required: ['environments', 'strategy', 'rollbackPlan'],
        },
      },
      required: [
        'systemContextDiagram',
        'componentDiagrams',
        'sequenceDiagrams',
        'dataFlowDiagram',
        'openApiDraft',
        'dataModelInventory',
        'threatModel',
        'observabilityPlan',
        'promotionModel',
      ],
    };

    const response = await this.callLLM(systemPrompt, userMessage, schema);
    return this.extractJSON<ArchitecturePack>(response);
  }

  // ── Stage 2: Local Validation ──────────────────────────────

  private localValidate(
    archPack: ArchitecturePack,
    intakePack: IntakePack,
  ): ArchValidationReport {
    const findings: ArchValidationFinding[] = [];

    // 1. Traceability: Intake entities → Data model
    const traceability = this.checkTraceability(archPack, intakePack, findings);

    // 2. Stack compliance
    this.checkStackCompliance(archPack, findings);

    // 3. Vagueness scan
    this.checkVagueness(archPack, findings);

    // 4. Data model completeness (mandatory columns)
    this.checkDataModelCompleteness(archPack, findings);

    // 5. Threat model coverage
    this.checkThreatModelCoverage(archPack, findings);

    // 6. OpenAPI completeness
    this.checkOpenApiCompleteness(archPack, intakePack, findings);

    // 7. Internal consistency
    this.checkInternalConsistency(archPack, findings);

    const criticalCount = findings.filter(f => f.severity === 'critical').length;
    const highCount = findings.filter(f => f.severity === 'high').length;

    return {
      totalFindings: findings.length,
      criticalCount,
      highCount,
      findings,
      traceability,
      passedValidation: criticalCount === 0,
    };
  }

  /** Check that every Intake Pack entity/SP/AC has a corresponding architecture artifact. */
  private checkTraceability(
    archPack: ArchitecturePack,
    intakePack: IntakePack,
    findings: ArchValidationFinding[],
  ): ArchValidationReport['traceability'] {
    // Flatten all text in arch pack for search
    const archText = this.flattenToSearchable(archPack);

    // Entity coverage
    const intakeEntities = intakePack.domainOperations?.map(d => d.entity) ?? [];
    const modelEntities = archPack.dataModelInventory?.map(m => m.entity.toLowerCase()) ?? [];
    let entitiesCovered = 0;
    for (const entity of intakeEntities) {
      if (modelEntities.some(m => m.includes(entity.toLowerCase()) || entity.toLowerCase().includes(m))) {
        entitiesCovered++;
      } else {
        findings.push({
          category: 'coverage_gap',
          location: `Data Model Inventory`,
          issue: `Entity "${entity}" from Intake Pack not found in data model inventory`,
          resolution: `Add "${entity}" with all fields, types, FKs, and audit columns`,
          severity: 'high',
        });
      }
    }

    // SP coverage
    const intakeSPs: string[] = [];
    for (const op of intakePack.domainOperations ?? []) {
      if (op.storedProcedures) intakeSPs.push(...op.storedProcedures);
    }
    let spsCovered = 0;
    for (const sp of intakeSPs) {
      if (archText.includes(sp.toLowerCase())) {
        spsCovered++;
      } else {
        findings.push({
          category: 'coverage_gap',
          location: 'Sequence Diagrams / OpenAPI',
          issue: `SP "${sp}" from Intake Pack not referenced in any architecture artifact`,
          resolution: `Add "${sp}" to relevant sequence diagram and/or OpenAPI endpoint`,
          severity: 'medium',
        });
      }
    }

    // Acceptance criteria coverage
    const intakeACs = intakePack.acceptanceCriteria ?? [];
    let acsCovered = 0;
    for (const ac of intakeACs) {
      const searchTerms = [
        ac.feature?.toLowerCase(),
        ac.spOrEndpoint?.toLowerCase(),
      ].filter(Boolean) as string[];

      if (searchTerms.some(term => archText.includes(term))) {
        acsCovered++;
      }
      // Don't create findings for every AC — too noisy. Track the count.
    }

    return {
      entitiesCovered,
      entitiesTotal: intakeEntities.length,
      acceptanceCriteriaCovered: acsCovered,
      acceptanceCriteriaTotal: intakeACs.length,
      spsCovered,
      spsTotal: intakeSPs.length,
    };
  }

  /** Scan all arch pack text fields for banned technology references. */
  private checkStackCompliance(
    archPack: ArchitecturePack,
    findings: ArchValidationFinding[],
  ): void {
    const searchable = this.flattenToSearchable(archPack);

    for (const { pattern, label } of BANNED_PATTERNS) {
      if (pattern.test(searchable)) {
        findings.push({
          category: 'stack_violation',
          location: 'Architecture Pack (global)',
          issue: `References banned technology: ${label}`,
          resolution: `Remove all references to ${label} and replace with authoritative stack equivalent`,
          severity: 'critical',
        });
      }
    }
  }

  /** Scan for vague/ambiguous language in all text fields. */
  private checkVagueness(
    archPack: ArchitecturePack,
    findings: ArchValidationFinding[],
  ): void {
    const fieldsToCheck: Array<{ name: string; value: string }> = [
      { name: 'systemContextDiagram', value: archPack.systemContextDiagram ?? '' },
      { name: 'dataFlowDiagram', value: archPack.dataFlowDiagram ?? '' },
      { name: 'openApiDraft', value: archPack.openApiDraft ?? '' },
      { name: 'observabilityPlan.logging', value: archPack.observabilityPlan?.logging ?? '' },
      { name: 'observabilityPlan.metrics', value: archPack.observabilityPlan?.metrics ?? '' },
      { name: 'observabilityPlan.alerting', value: archPack.observabilityPlan?.alerting ?? '' },
      { name: 'promotionModel.strategy', value: archPack.promotionModel?.strategy ?? '' },
      { name: 'promotionModel.rollbackPlan', value: archPack.promotionModel?.rollbackPlan ?? '' },
    ];

    for (const diagram of archPack.componentDiagrams ?? []) {
      fieldsToCheck.push({ name: 'componentDiagram', value: diagram });
    }
    for (const diagram of archPack.sequenceDiagrams ?? []) {
      fieldsToCheck.push({ name: 'sequenceDiagram', value: diagram });
    }

    for (const field of fieldsToCheck) {
      for (const { pattern, label } of VAGUE_PATTERNS) {
        if (pattern.test(field.value)) {
          findings.push({
            category: 'vagueness',
            location: field.name,
            issue: `Contains vague language: ${label}`,
            resolution: `Replace ${label} with specific, actionable detail`,
            severity: 'medium',
          });
        }
      }
    }
  }

  /** Verify every entity in data model has mandatory audit columns. */
  private checkDataModelCompleteness(
    archPack: ArchitecturePack,
    findings: ArchValidationFinding[],
  ): void {
    const mandatoryColumns = ['Id', 'TenantId', 'CreatedAt', 'CreatedBy', 'UpdatedAt', 'UpdatedBy', 'IsDeleted'];

    for (const model of archPack.dataModelInventory ?? []) {
      const fieldNames = model.fields.map(f => f.name.toLowerCase());

      for (const col of mandatoryColumns) {
        if (!fieldNames.includes(col.toLowerCase())) {
          findings.push({
            category: 'missing_detail',
            location: `Data Model: ${model.entity}`,
            issue: `Missing mandatory column "${col}"`,
            resolution: `Add "${col}" with correct type (see SP standards)`,
            severity: col === 'TenantId' || col === 'Id' ? 'critical' : 'high',
          });
        }
      }

      // Check for fields with no type
      for (const field of model.fields) {
        if (!field.type || field.type.trim() === '') {
          findings.push({
            category: 'missing_detail',
            location: `Data Model: ${model.entity}.${field.name}`,
            issue: `Field has no SQL type defined`,
            resolution: `Specify exact SQL type (e.g., NVARCHAR(100), DECIMAL(18,2), UNIQUEIDENTIFIER)`,
            severity: 'high',
          });
        }
      }
    }
  }

  /** Verify threat model covers all required trust boundaries. */
  private checkThreatModelCoverage(
    archPack: ArchitecturePack,
    findings: ArchValidationFinding[],
  ): void {
    const requiredBoundaries = [
      'Browser > API',
      'API > Database',
      'API > MCP',
      'Mobile > API',
      'Edge Daemon > SignalR',
      'B2B Portal > API',
    ];

    const threatBoundaries = (archPack.threatModel ?? [])
      .map(t => t.boundary.toLowerCase());

    for (const boundary of requiredBoundaries) {
      const found = threatBoundaries.some(tb =>
        tb.includes(boundary.toLowerCase().replace(' > ', '')) ||
        tb.includes(boundary.toLowerCase().split(' > ')[0]) && tb.includes(boundary.toLowerCase().split(' > ')[1]),
      );

      if (!found) {
        findings.push({
          category: 'security_gap',
          location: 'Threat Model',
          issue: `Missing threat analysis for trust boundary: "${boundary}"`,
          resolution: `Add STRIDE-classified threats for the ${boundary} boundary with specific mitigations`,
          severity: 'high',
        });
      }
    }

    // Every threat must have a non-empty mitigation
    for (const threat of archPack.threatModel ?? []) {
      if (!threat.mitigation || threat.mitigation.trim().length < 10) {
        findings.push({
          category: 'security_gap',
          location: `Threat Model: "${threat.threat?.substring(0, 60)}"`,
          issue: `Threat has no meaningful mitigation (empty or too short)`,
          resolution: `Provide specific mitigation strategy with implementation details`,
          severity: 'high',
        });
      }
    }
  }

  /** Check OpenAPI covers the Intake Pack domain operations. */
  private checkOpenApiCompleteness(
    archPack: ArchitecturePack,
    intakePack: IntakePack,
    findings: ArchValidationFinding[],
  ): void {
    const openApi = (archPack.openApiDraft ?? '').toLowerCase();

    if (!openApi || openApi.length < 100) {
      findings.push({
        category: 'missing_detail',
        location: 'OpenAPI Draft',
        issue: 'OpenAPI draft is empty or too short to be useful',
        resolution: 'Generate full OpenAPI 3.0 YAML with all endpoints, schemas, and status codes',
        severity: 'critical',
      });
      return;
    }

    // Check for key structural elements
    if (!openApi.includes('openapi:') && !openApi.includes('openapi :')) {
      findings.push({
        category: 'missing_detail',
        location: 'OpenAPI Draft',
        issue: 'Missing OpenAPI version declaration',
        resolution: 'Add openapi: "3.0.3" at the top of the spec',
        severity: 'high',
      });
    }

    if (!openApi.includes('paths:')) {
      findings.push({
        category: 'missing_detail',
        location: 'OpenAPI Draft',
        issue: 'Missing paths section',
        resolution: 'Add paths section with all API endpoints',
        severity: 'critical',
      });
    }

    // Check that primary entities have endpoints
    const primaryEntities = ['worksheet', 'scale', 'ticket', 'dispatch', 'inventory', 'booking', 'rental'];
    for (const entity of primaryEntities) {
      if (!openApi.includes(entity)) {
        findings.push({
          category: 'coverage_gap',
          location: 'OpenAPI Draft',
          issue: `No endpoints found for primary entity "${entity}"`,
          resolution: `Add CRUD endpoints for ${entity} resources`,
          severity: 'medium',
        });
      }
    }
  }

  /** Check internal consistency between architecture artifacts. */
  private checkInternalConsistency(
    archPack: ArchitecturePack,
    findings: ArchValidationFinding[],
  ): void {
    // Diagrams should exist and not be empty
    if (!archPack.systemContextDiagram || archPack.systemContextDiagram.length < 50) {
      findings.push({
        category: 'missing_detail',
        location: 'System Context Diagram',
        issue: 'System context diagram is missing or too short',
        resolution: 'Generate Mermaid C4 diagram showing actors, external systems, and application boundary',
        severity: 'critical',
      });
    }

    if (!archPack.componentDiagrams || archPack.componentDiagrams.length === 0) {
      findings.push({
        category: 'missing_detail',
        location: 'Component Diagrams',
        issue: 'No component diagrams generated',
        resolution: 'Generate one Mermaid component diagram per subsystem',
        severity: 'high',
      });
    }

    if (!archPack.sequenceDiagrams || archPack.sequenceDiagrams.length === 0) {
      findings.push({
        category: 'missing_detail',
        location: 'Sequence Diagrams',
        issue: 'No sequence diagrams generated',
        resolution: 'Generate sequence diagrams for: order-to-cash, scale capture, dispatch, MCP HITL, offline sync, ETL',
        severity: 'high',
      });
    }

    // Promotion model should have all environments
    const requiredEnvs = ['dev', 'qa', 'staging', 'prod'];
    const envs = (archPack.promotionModel?.environments ?? []).map(e => e.toLowerCase());
    for (const env of requiredEnvs) {
      if (!envs.some(e => e.includes(env))) {
        findings.push({
          category: 'missing_detail',
          location: 'Promotion Model',
          issue: `Missing environment: "${env}"`,
          resolution: `Add "${env}" environment to the promotion model`,
          severity: 'medium',
        });
      }
    }

    // Observability must have specifics, not just categories
    const obsPlan = archPack.observabilityPlan;
    if (obsPlan) {
      for (const [key, value] of Object.entries(obsPlan)) {
        if (typeof value === 'string' && value.length < 30) {
          findings.push({
            category: 'vagueness',
            location: `Observability Plan: ${key}`,
            issue: `${key} description is too brief to be actionable (${value.length} chars)`,
            resolution: `Expand ${key} with specific tools, thresholds, and implementation details`,
            severity: 'medium',
          });
        }
      }
    }
  }

  // ── LLM Deep Validation ────────────────────────────────────

  private async deepValidateWithLLM(
    archPack: ArchitecturePack,
    intakePack: IntakePack,
    localReport: ArchValidationReport,
  ): Promise<ArchValidationFinding[]> {
    const systemPrompt = await this.buildSystemPrompt();

    const localSummary = localReport.findings
      .filter(f => f.severity === 'critical' || f.severity === 'high')
      .map(f => `- [${f.severity}/${f.category}] ${f.location}: ${f.issue}`)
      .join('\n');

    // Send a compact summary of the arch pack to the LLM
    const archSummary = [
      `Entities in data model: ${(archPack.dataModelInventory ?? []).map(m => m.entity).join(', ')}`,
      `Component diagrams: ${(archPack.componentDiagrams ?? []).length}`,
      `Sequence diagrams: ${(archPack.sequenceDiagrams ?? []).length}`,
      `Threat model entries: ${(archPack.threatModel ?? []).length}`,
      `OpenAPI length: ${(archPack.openApiDraft ?? '').length} chars`,
      `Environments: ${(archPack.promotionModel?.environments ?? []).join(', ')}`,
      '',
      'Traceability:',
      `  Entities: ${localReport.traceability.entitiesCovered}/${localReport.traceability.entitiesTotal}`,
      `  SPs: ${localReport.traceability.spsCovered}/${localReport.traceability.spsTotal}`,
      `  ACs: ${localReport.traceability.acceptanceCriteriaCovered}/${localReport.traceability.acceptanceCriteriaTotal}`,
    ].join('\n');

    const intakeEntities = (intakePack.domainOperations ?? [])
      .map(d => `${d.entity}: ${(d.storedProcedures ?? []).join(', ')}`)
      .join('\n');

    const userMessage = [
      '## Task: Deep Architecture Validation',
      '',
      'Local validator already found these critical/high issues:',
      localSummary || '(none)',
      '',
      '## Architecture Pack Summary',
      archSummary,
      '',
      '## Intake Pack Entities & SPs',
      intakeEntities,
      '',
      'Find ADDITIONAL issues the local validator missed:',
      '1. Logical inconsistencies between diagrams (e.g., sequence shows a flow but component diagram lacks that component)',
      '2. Data model relationships that are missing FK definitions',
      '3. Security flows where RLS injection is missing from the sequence',
      '4. OpenAPI endpoints that lack proper error response codes',
      '5. Threat model gaps where a known attack vector is unaddressed',
      '6. Observability blind spots (what can fail silently?)',
      '',
      'Return ONLY valid JSON — an array of findings.',
    ].join('\n');

    const schema = {
      type: 'array' as const,
      items: {
        type: 'object' as const,
        properties: {
          category: { type: 'string', enum: ['coverage_gap', 'inconsistency', 'missing_detail', 'vagueness', 'stack_violation', 'security_gap'] },
          location: { type: 'string' },
          issue: { type: 'string' },
          resolution: { type: 'string' },
          severity: { type: 'string', enum: ['critical', 'high', 'medium', 'low'] },
        },
        required: ['category', 'location', 'issue', 'resolution', 'severity'],
      },
    };

    try {
      const response = await this.callLLM(systemPrompt, userMessage, schema);
      return this.extractJSON<ArchValidationFinding[]>(response);
    } catch {
      // Deep validation is best-effort
      return [];
    }
  }

  // ── Helpers ────────────────────────────────────────────────

  /** Flatten all string fields in the arch pack into one searchable lowercase string. */
  private flattenToSearchable(archPack: ArchitecturePack): string {
    const parts: string[] = [];

    parts.push(archPack.systemContextDiagram ?? '');
    parts.push(archPack.dataFlowDiagram ?? '');
    parts.push(archPack.openApiDraft ?? '');
    parts.push(...(archPack.componentDiagrams ?? []));
    parts.push(...(archPack.sequenceDiagrams ?? []));

    for (const model of archPack.dataModelInventory ?? []) {
      parts.push(model.entity);
      for (const field of model.fields) {
        parts.push(field.name);
      }
    }

    for (const threat of archPack.threatModel ?? []) {
      parts.push(threat.threat ?? '');
      parts.push(threat.boundary ?? '');
      parts.push(threat.mitigation ?? '');
    }

    if (archPack.observabilityPlan) {
      parts.push(archPack.observabilityPlan.logging ?? '');
      parts.push(archPack.observabilityPlan.metrics ?? '');
      parts.push(archPack.observabilityPlan.tracing ?? '');
      parts.push(archPack.observabilityPlan.alerting ?? '');
    }

    if (archPack.promotionModel) {
      parts.push(archPack.promotionModel.strategy ?? '');
      parts.push(archPack.promotionModel.rollbackPlan ?? '');
      parts.push(...(archPack.promotionModel.environments ?? []));
    }

    return parts.join(' ').toLowerCase();
  }
}
