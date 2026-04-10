// ═══════════════════════════════════════════════════════════
// GSD Agent System — SDLC Types & Schemas
// Types for Phases A-E of the Technijian SDLC v6.0 lifecycle.
// These phases produce artifacts consumed by the v4.1 pipeline.
// ═══════════════════════════════════════════════════════════

// ── SDLC Phase Identity ─────────────────────────────────────

export type SdlcPhase =
  | 'phase-a'           // Requirements gathering
  | 'phase-b'           // Architecture specification
  | 'phase-c'           // Figma integration + code generation
  | 'phase-ab-reconcile' // Update A/B based on Figma output
  | 'phase-d'           // Blueprint freeze
  | 'phase-e'           // Contract freeze (SCG1)
  | 'pipeline';         // Hand off to existing v4.1 pipeline

export type SdlcStatus = 'pending' | 'running' | 'paused' | 'failed' | 'complete';

// ── Phase A: Requirements (Intake Pack) ─────────────────────

export interface IntakePack {
  [key: string]: unknown;
  problemStatement: string;
  outcomes: string[];
  successMetrics: string[];
  stakeholders: Array<{ name: string; role: string; raci: 'R' | 'A' | 'C' | 'I' }>;
  dataClassification: string;
  regulatoryScope: string[];   // e.g., ['HIPAA', 'SOC2', 'PCI', 'GDPR']
  domainOperations: Array<{
    entity: string;
    operations: string[];
    roles: string[];
    storedProcedures?: string[];   // SP names (usp_{Entity}_{Action})
  }>;
  rbacSketch: Array<{
    role: string;
    permissions: string[];
    denials?: string[];             // Explicit denials (what this role CANNOT access)
  }>;
  nfrs: Array<{ category: string; requirement: string; target: string }>;
  riskRegister: Array<{ risk: string; likelihood: string; impact: string; mitigation: string }>;
  acceptanceCriteria: Array<{
    id: string;
    feature?: string;               // Feature area (e.g., "Trade Management", "Scale Integration")
    description: string;
    spOrEndpoint?: string;           // SP or API endpoint under test
    testable: boolean;
  }>;
  dependencies: string[];
}

// ── Phase B: Architecture Pack ──────────────────────────────

export interface ArchitecturePack {
  [key: string]: unknown;
  systemContextDiagram: string;  // Mermaid markdown
  componentDiagrams: string[];   // Mermaid markdown per component
  sequenceDiagrams: string[];    // Mermaid markdown per flow
  dataFlowDiagram: string;       // Mermaid markdown
  openApiDraft: string;          // YAML string
  dataModelInventory: Array<{ entity: string; fields: Array<{ name: string; type: string; nullable: boolean }> }>;
  threatModel: Array<{ threat: string; boundary: string; mitigation: string; severity: string }>;
  observabilityPlan: { logging: string; metrics: string; tracing: string; alerting: string };
  promotionModel: { environments: string[]; strategy: string; rollbackPlan: string };
}

// ── Phase C: Figma Integration ──────────────────────────────

export interface FigmaDeliverables {
  [key: string]: unknown;
  analysisPath: string;           // Path to _analysis/ directory
  stubsPath: string;              // Path to _stubs/ directory
  generatedPath: string;          // Path to /generated/ directory
  analysisFiles: {                // 12/12 required
    screenInventory: boolean;     // 01-screen-inventory.md
    componentInventory: boolean;  // 02-component-inventory.md
    designSystem: boolean;        // 03-design-system.md
    navigationRouting: boolean;   // 04-navigation-routing.md
    dataTypes: boolean;           // 05-data-types.md
    apiContracts: boolean;        // 06-api-contracts.md
    hooksState: boolean;          // 07-hooks-state.md
    mockDataCatalog: boolean;     // 08-mock-data-catalog.md
    storyboards: boolean;         // 09-storyboards.md
    screenStateMatrix: boolean;   // 10-screen-state-matrix.md
    apiSpMap: boolean;            // 11-api-to-sp-map.md
    implementationGuide: boolean; // 12-implementation-guide.md
  };
  completeness: number;           // 0-12 count of present files
  dtoValidation: { passed: boolean; mismatches: string[] };
  buildVerification: { dotnetBuild: boolean; npmBuild: boolean };
}

// ── Phase AB-Reconcile ──────────────────────────────────────

export interface ReconciliationReport {
  [key: string]: unknown;
  gapsFound: Array<{ source: 'figma' | 'phase-a' | 'phase-b'; description: string; resolution: string }>;
  newRequirements: string[];      // Requirements discovered during prototyping
  updatedEndpoints: string[];     // API endpoints added/changed from Figma analysis
  updatedDataModels: string[];    // Data models added/changed
  alignmentScore: number;         // 0-100 alignment between Phase A/B and Figma output
  updatedIntakePack: IntakePack;
  updatedArchitecturePack: ArchitecturePack;
}

// ── Phase D: Frozen Blueprint ───────────────────────────────

export interface FrozenBlueprint {
  [key: string]: unknown;
  screenInventory: Array<{ route: string; name: string; layout: string; roles: string[]; states: string[] }>;
  componentInventory: Array<{ name: string; category: string; screens: string[]; variants: number }>;
  designTokens: { colors: number; typography: number; spacing: number; icons: number };
  navigationArchitecture: { routes: number; nestedLevels: number; authRequired: number };
  rbacMatrix: Array<{ role: string; screens: string[]; operations: string[] }>;
  accessibilityRequirements: string[];
  copyDeck: Array<{ screen: string; titles: string[]; emptyStates: string[]; errorMessages: string[] }>;
  approvalStatus: { productLead: boolean; uxOwner: boolean; techArchitect: boolean };
  frozenAt: string;  // ISO timestamp
}

// ── Phase E: Contract Artifacts (SCG1) ──────────────────────

export interface ContractArtifacts {
  [key: string]: unknown;
  uiContractPath: string;       // /docs/spec/ui-contract.csv
  openApiPath: string;          // /docs/spec/openapi.yaml
  apiSpMapPath: string;         // /docs/spec/apitospmap.csv
  dbPlanPath: string;           // /docs/spec/db-plan.md
  testPlanPath: string;         // /docs/spec/test-plan.md
  ciGatesPath: string;          // /docs/spec/ci-gates.md
  validationReportPath: string; // /docs/spec/validation-report.md
  routes: number;               // Count of UI contract routes
  endpoints: number;            // Count of OpenAPI endpoints
  storedProcedures: number;     // Count of SPs in API↔SP map
  gaps: Array<{ id: string; layer: string; issue: string; action: string }>;
  scg1Passed: boolean;          // All sign-offs obtained
}

// ── SDLC State ──────────────────────────────────────────────

export interface SdlcState {
  sdlcRunId: string;
  currentPhase: SdlcPhase;
  status: SdlcStatus;
  intakePack: IntakePack | null;
  architecturePack: ArchitecturePack | null;
  figmaDeliverables: FigmaDeliverables | null;
  reconciliationReport: ReconciliationReport | null;
  frozenBlueprint: FrozenBlueprint | null;
  contractArtifacts: ContractArtifacts | null;
  decisions: Array<{ phase: string; action: string; reason: string; timestamp: string }>;
  costAccumulator: Array<{ phase: string; agentId: string; estimatedTokens: number; estimatedCostUsd: number }>;
  startedAt: string;
  completedAt: string | null;
}

// ── SDLC Trigger ────────────────────────────────────────────

export interface SdlcTrigger {
  trigger: 'manual' | 'schedule';
  fromPhase?: SdlcPhase;
  projectName: string;
  projectDescription: string;
  designPath?: string;          // Path to Figma Make output (design/web/v##/src/)
  vaultPath: string;
  review?: boolean;             // Pause after each phase for human review
}
