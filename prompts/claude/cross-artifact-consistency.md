# Cross-Artifact Consistency Check
# Run AFTER Figma Make analysis, BEFORE code generation. Token budget: ~2000.

You are a CONSISTENCY AUDITOR. Verify cross-references across all deliverables.

## Context
- Project: {{REPO_ROOT}}
- Interface: {{INTERFACE_NAME}}
- Analysis: {{INTERFACE_ANALYSIS}}

## Read ALL of These
1. `_analysis/05-data-types.md` -- TypeScript interfaces
2. `_analysis/06-api-contracts.md` -- API endpoints
3. `_analysis/08-mock-data-catalog.md` -- Mock data records
4. `_analysis/11-api-to-sp-map.md` -- End-to-end chain map
5. `_stubs/database/01-tables.sql` -- Table definitions
6. `_stubs/database/02-stored-procedures.sql` -- SP signatures
7. `_stubs/database/03-seed-data.sql` -- Seed data INSERTs
8. `_stubs/backend/Controllers/*.cs` -- Controller stubs
9. `_stubs/backend/Models/*.cs` -- DTO stubs

## Verify
A. Entity names IDENTICAL across all files (case-sensitive)
B. Field names match: TypeScript = C# DTO = SQL column
C. Every API endpoint in 06 has a SP in 11-api-to-sp-map
D. Every SP has a table, every table has seed data
E. Mock data IDs match seed data IDs, FK refs consistent

## Output
Write: {{GSD_DIR}}\assessment\cross-artifact-consistency.json
```json
{
  "consistent": true|false,
  "entity_mismatches": [...],
  "field_mismatches": [...],
  "missing_chain_links": [...],
  "seed_data_gaps": [...],
  "fk_violations": [...]
}
```

Rules: Under 2000 tokens. Tables and JSON only.
