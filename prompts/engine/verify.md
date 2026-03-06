# Verify Phase

You are verifying that the execute phase correctly implemented the queued requirements.

## Inputs
- Work queue (what was attempted): `{{gsd_dir}}/generation-queue/queue-current.json`
- Requirements matrix: `{{gsd_dir}}/health/requirements-matrix.json`
- Full repository scan (post-execute)

## Your Task

1. **Check each queued requirement** against its acceptance criteria
2. **Verify the code actually works** — correct syntax, proper imports, valid references
3. **Update requirement statuses** in the matrix
4. **Recalculate health score**
5. **Flag regressions** — requirements that were satisfied but are now broken

## Output Files

### `{{gsd_dir}}/health/health-current.json`
Updated health score and counts.

### `{{gsd_dir}}/health/requirements-matrix.json`
Updated `status` and `satisfied_by` for each verified requirement.

## Verification Checklist
For each requirement, check:
- [ ] Target files exist and are non-empty
- [ ] Code compiles / has valid syntax
- [ ] Acceptance criteria are met
- [ ] No regressions in previously satisfied requirements
- [ ] {{patterns.compliance}} compliance maintained
- [ ] Database objects match spec (if applicable)
- [ ] API contracts match spec (if applicable)
- [ ] UI matches Figma (if applicable)

## Rules
- Be **strict** — don't mark satisfied unless fully verified
- If execute created partial work, mark as `partial` not `satisfied`
- Report regressions prominently — these need immediate fix
- Check that file references in `satisfied_by` are accurate
