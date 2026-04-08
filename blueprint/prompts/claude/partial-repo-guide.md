
## CRITICAL: Partial Repo Handling

This repo may ALREADY have code. You MUST assess what exists before generating
the blueprint. Do NOT assume a greenfield project.

### Pre-Blueprint Assessment

BEFORE writing blueprint.json, perform this assessment:

1. **Scan the full codebase** - list every source file that exists
2. **Read representative files** - understand the patterns already in use
3. **Detect pattern conflicts** - flag any code using wrong patterns
   (e.g. Entity Framework when the standard is Dapper + stored procs)
4. **Cross-reference with specs** - for each spec requirement, check if
   code already exists that satisfies it

### Blueprint Item Status Rules for Partial Repos

When writing each blueprint item, set the initial status based on what you find:

- **"completed"** - File exists, correct patterns, meets ALL acceptance criteria.
  Set `satisfied_by` to the existing file path. Codex will SKIP this item.

- **"partial"** - File exists but incomplete or wrong patterns. Set status to
  "partial" and add a `partial_notes` field explaining what's wrong/missing:
  ```json
  {
    "id": 42,
    "path": "src/components/Dashboard/CardGrid.tsx",
    "status": "partial",
    "partial_notes": "Component exists but missing responsive breakpoints and hover states from Figma v03. Also using class component - must convert to functional + hooks.",
    "existing_file": "src/components/Dashboard/CardGrid.tsx",
    "work_type": "extend"
  }
  ```

- **"refactor"** - File exists but uses fundamentally wrong patterns. Set
  status to "refactor" with details:
  ```json
  {
    "id": 15,
    "path": "src/Repositories/UserRepository.cs",
    "status": "refactor",
    "partial_notes": "Currently uses Entity Framework. Must rewrite to Dapper + stored procedures. Keep the same interface (IUserRepository) but change implementation.",
    "existing_file": "src/Repositories/UserRepository.cs",
    "work_type": "refactor",
    "preserve": ["IUserRepository interface", "method signatures", "DI registration"]
  }
  ```

- **"not_started"** - Nothing exists. Codex builds from scratch.

### The `preserve` Field

For refactor and extend items, include a `preserve` array listing things
Codex must NOT break or change:
- Interface contracts that other code depends on
- DI registrations
- Route paths that the frontend calls
- Database column names that stored procs reference
- CSS class names that other components use

### Work Type Priorities

In the tier structure, order items within each tier by work_type:
1. **refactor** items first (fix wrong patterns before building on them)
2. **extend** items second (complete partial implementations)
3. **not_started** items last (new code)

This ensures the foundation is solid before building on top of it.

### Assessment Output

Also write: {{GSD_DIR}}\blueprint\pre-assessment.json
```json
{
  "assessed_at": "...",
  "existing_files_scanned": N,
  "pattern_conflicts": [...],
  "coverage": {
    "spec_coverage_percent": NN.N,
    "figma_coverage_percent": NN.N
  },
  "work_breakdown": {
    "skip_completed": N,
    "refactor": N,
    "extend": N,
    "build_new": N
  },
  "initial_health": NN.N
}
```
