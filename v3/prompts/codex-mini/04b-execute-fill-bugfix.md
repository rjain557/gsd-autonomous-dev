# Phase 4b: Execute - Fill Pass (Bug Fix Mode)

Fix the bug with MINIMAL, TARGETED changes. Generate a regression test.

## Bug: {{REQ_ID}}

## Root Cause

{{ROOT_CAUSE}}

## Plan

{{PLAN}}

## Instructions

1. Fix ONLY the root cause identified in the plan.
2. Make the MINIMUM changes necessary — do not refactor, do not improve surrounding code.
3. Generate a regression test that:
   - FAILS before the fix (reproduces the bug)
   - PASSES after the fix (verifies the fix)
4. Ensure all imports are correct and complete.
5. Handle errors explicitly. No empty catch blocks.
6. Use the `--- FILE: path/to/file ---` marker format for each file.

## Quality Checks

Before outputting each file, verify:
- The fix addresses the root cause, not just the symptom
- The regression test actually tests the specific bug scenario
- No unrelated code was changed
- All imports resolve to real modules
- TypeScript types are correct and complete
- No `any` types unless absolutely necessary

## Required Output

You MUST output:
1. The fixed source file(s) — complete file contents
2. A regression test file — complete test contents

Generate the fix and test now. Output ONLY file contents with `--- FILE: path ---` markers.
