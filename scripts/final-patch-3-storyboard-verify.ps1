<#
.SYNOPSIS
    Final Integration Sub-Patch 3/6: Storyboard Verify Prompt
    Fixes GAP 3: Code passes build but fails spec - add logical verification
#>
param([string]$UserHome = $env:USERPROFILE)
$ErrorActionPreference = "Stop"
$BpPromptDir = Join-Path $UserHome ".gsd-global\blueprint\prompts\claude"

if (-not (Test-Path $BpPromptDir)) {
    New-Item -ItemType Directory -Path $BpPromptDir -Force | Out-Null
}

Write-Host "[BOOK] Sub-patch 3/6: Storyboard-aware verify prompt..." -ForegroundColor Yellow

$prompt = @'
# Verify Phase - Claude Code (Storyboard-Enhanced)
# Checks code for LOGICAL CORRECTNESS against storyboards, not just file existence

You are the VERIFIER. Check blueprint items AND trace storyboard flows.

## Context
- Iteration: {{ITERATION}}
- Health: {{HEALTH}}%
- Blueprint: {{GSD_DIR}}\blueprint\blueprint.json

{{INTERFACE_CONTEXT}}

## STEP 1: Standard Verification
For each blueprint item recently built:
- File exists? If no -> status "not_started"
- Meets acceptance criteria? Check each one:
  - ALL met -> "completed"
  - SOME met -> "partial" (note which failed)
  - NONE met -> "not_started"
- Calculate health = (completed / total) * 100

## STEP 2: Storyboard Logic Verification

For each interface with _analysis/09-storyboards.md, read the flows.
For flows involving files in the current batch, do STRUCTURAL TRACE:

### 2a. Data Path Trace
Trace each flow end-to-end through actual generated code:
- Frontend component -> calls which hook?
  CHECK: Does the hook file exist? Does it call the right endpoint?
- Hook -> calls which API endpoint?
  CHECK: Does the URL/method match 06-api-contracts.md?
- Controller -> calls which service method?
  CHECK: Does the service exist? Does method signature match?
- Service -> calls which stored procedure?
  CHECK: Does the SP exist? Do parameter names match?
- SP -> reads/writes which tables?
  CHECK: Do the tables exist in migrations?

If ANY link in the chain is broken (wrong name, missing file, mismatched
params), mark the originating blueprint item as "partial" with notes.

### 2b. State Handling Check
For each UI component, check against _analysis/10-screen-state-matrix.md:
- Does component handle loading state? (search for isLoading, loading, skeleton)
- Does component handle error state? (search for error, Error, catch)
- Does component handle empty state? (search for empty, no data, length === 0)

If a state defined in the matrix is missing from the code, mark "partial".

### 2c. Mock-to-Seed Consistency
If _analysis/08-mock-data-catalog.md exists:
- Do the seed SQL INSERTs produce the same IDs and key values as mock data?
- Are foreign key references consistent?

## STEP 3: Write Outputs
- UPDATE blueprint.json statuses (only status fields)
- WRITE health.json with new score
- APPEND health-history.jsonl
- WRITE next-batch.json (next items to build, respecting dependencies)

If items were downgraded due to storyboard checks:
- WRITE {{GSD_DIR}}\blueprint\storyboard-issues.md
  For each issue: which flow, which link broke, what the fix should be.
  This file helps Codex fix logical issues in the next build iteration.

## Token Budget
~3000 tokens. Storyboard traces should be quick structural checks
(does file X call function Y with parameter Z?), not deep code review.
'@

Set-Content -Path "$BpPromptDir\verify-storyboard.md" -Value $prompt -Encoding UTF8
Write-Host "   [OK] prompts\claude\verify-storyboard.md" -ForegroundColor DarkGreen
