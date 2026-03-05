# Codebase Assessment - Claude Code
# Run this BEFORE blueprint or convergence on a partially-built repo.
# Produces a complete inventory of what exists, what's partial, and what's missing.

You are the ASSESSOR. Your job: produce a thorough inventory of the existing
codebase so that the generation phases know exactly what to skip, what to fix,
and what to build from scratch.

## Context
- Project: {{REPO_ROOT}}
- Figma: {{FIGMA_PATH}} (version {{FIGMA_VERSION}})
- SDLC docs: docs\ (Phase A through Phase E)
- Output: {{GSD_DIR}}\assessment\


## Project Interfaces
{{INTERFACE_CONTEXT}}

## Multi-Interface Rules
- Assess EACH interface separately
- For interfaces WITH _analysis/: cross-reference code against deliverables
- Group work-classification by interface + shared backend
- Flag inconsistencies between interfaces

## STEP 1: Discovery Scan

Scan the full repository. For EVERY file in the project (excluding node_modules,
bin, obj, .git, packages, dist, build), catalog:

```
{{GSD_DIR}}\assessment\file-inventory.json
{
  "scan_timestamp": "...",
  "total_files": N,
  "by_type": {
    ".cs": { "count": N, "paths": ["..."] },
    ".sql": { "count": N, "paths": ["..."] },
    ".tsx": { "count": N, "paths": ["..."] },
    ".ts": { "count": N, "paths": ["..."] },
    ".json": { "count": N, "paths": ["..."] },
    ".css": { "count": N, "paths": ["..."] },
    ".md": { "count": N, "paths": ["..."] }
  },
  "folder_structure": "... tree output ..."
}
```

## STEP 2: Pattern Detection

Read a representative sample of existing files (at least 3-5 of each type) and detect:

```
{{GSD_DIR}}\assessment\detected-patterns.json
{
  "backend": {
    "framework": ".NET 8 | .NET 7 | .NET 6 | other",
    "orm": "Dapper | Entity Framework | ADO.NET | other",
    "data_access": "stored procedures | inline SQL | ORM queries | mixed",
    "architecture": "clean architecture | MVC | minimal API | other",
    "di_pattern": "constructor injection | service locator | none",
    "logging": "Serilog | NLog | ILogger | Console | none",
    "validation": "FluentValidation | DataAnnotations | manual | none",
    "example_files": ["path/to/representative.cs"]
  },
  "frontend": {
    "framework": "React 18 | React 17 | Angular | Vue | other",
    "component_style": "functional + hooks | class components | mixed",
    "state_management": "Redux | Context | Zustand | MobX | none",
    "styling": "CSS modules | Tailwind | styled-components | SCSS | inline",
    "routing": "React Router | Next.js | other | none",
    "example_files": ["path/to/representative.tsx"]
  },
  "database": {
    "engine": "SQL Server | PostgreSQL | MySQL | SQLite | other",
    "migrations": "EF migrations | SQL scripts | Flyway | none",
    "stored_procedures_exist": true/false,
    "stored_procedure_count": N,
    "inline_sql_detected": true/false,
    "example_files": ["path/to/representative.sql"]
  },
  "compliance": {
    "hipaa_patterns_detected": true/false,
    "audit_logging_exists": true/false,
    "rbac_implemented": true/false,
    "encryption_at_rest": true/false,
    "evidence": ["path/to/audit-logger.cs"]
  },
  "pattern_conflicts": [
    {
      "issue": "Mixed data access: 12 files use EF, 3 files use Dapper",
      "recommendation": "Standardize on Dapper + stored procedures per project standards",
      "affected_files": ["..."]
    }
  ]
}
```

## STEP 3: Spec Coverage Analysis

Read each specification document in docs\ and each Figma design. For every
requirement, check if existing code satisfies it:

```
{{GSD_DIR}}\assessment\coverage-analysis.json
{
  "spec_coverage": {
    "total_requirements_identified": N,
    "fully_implemented": N,
    "partially_implemented": N,
    "not_implemented": N,
    "coverage_percent": NN.N
  },
  "figma_coverage": {
    "total_components_identified": N,
    "fully_implemented": N,
    "partially_implemented": N,
    "not_implemented": N,
    "coverage_percent": NN.N
  },
  "requirements": [
    {
      "id": "REQ-001",
      "source": "spec",
      "spec_doc": "docs/Phase-B-API.md",
      "description": "User authentication endpoint",
      "status": "fully_implemented",
      "implemented_by": ["src/Controllers/AuthController.cs", "src/Services/AuthService.cs"],
      "quality_notes": "Working but uses inline SQL instead of stored procedure",
      "needs_refactor": true,
      "refactor_reason": "Must use stored procedure pattern per project standards"
    },
    {
      "id": "REQ-042",
      "source": "figma",
      "figma_frame": "Dashboard/CardGrid",
      "description": "Dashboard card grid layout",
      "status": "partially_implemented",
      "implemented_by": ["src/components/Dashboard/CardGrid.tsx"],
      "quality_notes": "Component exists but missing responsive breakpoints and hover states from Figma",
      "missing": ["responsive breakpoints", "hover elevation shadow", "loading skeleton"]
    }
  ]
}
```

## STEP 4: Refactor vs Build Decision Map

For each requirement, classify the work needed:

```
{{GSD_DIR}}\assessment\work-classification.json
{
  "summary": {
    "skip": N,
    "refactor": N,
    "extend": N,
    "build_new": N,
    "total": N
  },
  "items": [
    {
      "req_id": "REQ-001",
      "classification": "skip",
      "reason": "Fully implemented, meets all acceptance criteria and project patterns"
    },
    {
      "req_id": "REQ-002",
      "classification": "refactor",
      "reason": "Implemented but uses Entity Framework instead of Dapper + stored procs",
      "current_file": "src/Repositories/UserRepository.cs",
      "work_needed": "Rewrite data access layer to use Dapper calling stored procedures",
      "estimated_complexity": "medium"
    },
    {
      "req_id": "REQ-042",
      "classification": "extend",
      "reason": "Component exists but incomplete - missing responsive + hover states",
      "current_file": "src/components/Dashboard/CardGrid.tsx",
      "work_needed": "Add responsive breakpoints, hover elevation, loading skeleton",
      "estimated_complexity": "low"
    },
    {
      "req_id": "REQ-099",
      "classification": "build_new",
      "reason": "No implementation exists",
      "work_needed": "Create from scratch per spec",
      "estimated_complexity": "high"
    }
  ]
}
```

Classifications:
- **skip**: Fully done, correct patterns, meets acceptance criteria. Don't touch it.
- **refactor**: Code exists but uses wrong patterns (e.g. EF instead of Dapper, inline SQL instead of stored procs). Must be rewritten.
- **extend**: Code exists and is partially correct. Needs additions (missing features, states, validations).
- **build_new**: Nothing exists. Generate from scratch.

## STEP 5: Summary Report

```
{{GSD_DIR}}\assessment\assessment-summary.md

# Codebase Assessment Summary
- **Project**: <name>
- **Assessed**: <timestamp>
- **Figma**: <version>

## Coverage
- Spec requirements: NN% covered (N/N)
- Figma components: NN% covered (N/N)
- Overall: NN%

## Work Breakdown
- Skip (already done): N items
- Refactor (wrong patterns): N items
- Extend (partially done): N items
- Build new: N items

## Pattern Conflicts
<list any conflicts found>

## Estimated Effort
- Refactors: ~N files to rewrite
- Extensions: ~N files to modify
- New code: ~N files to create
- Total: ~N files affected

## Recommendations
- <specific recommendations based on what was found>
```

## Rules
- Scan EVERY file, not just a sample - the inventory must be complete
- Read actual file contents to determine patterns (don't guess from names)
- Be HONEST about quality - if code works but uses wrong patterns, flag it as refactor
- For Figma comparison, check actual component output vs design, not just file existence
- Pattern conflicts must list specific files so Codex knows what to fix
- This assessment feeds directly into blueprint.json or requirements-matrix.json

