---
type: evals
description: Golden input/output test cases for each agent
---

# Agent Test Cases

## BlueprintAnalysisAgent

### TC-BA-001: Detect 3 intentional drift items

**Input:**
```json
{
  "blueprintPath": "test-fixtures/blueprint-with-drift.json",
  "specPaths": ["test-fixtures/spec-phase-a.md", "test-fixtures/spec-phase-b.md"],
  "repoRoot": "test-fixtures/repo-with-drift"
}
```

**Expected Output:**
```json
{
  "aligned": ["REQ-001", "REQ-002"],
  "drifted": [
    { "requirementId": "REQ-003", "severity": "high" },
    { "requirementId": "REQ-005", "severity": "medium" },
    { "requirementId": "REQ-007", "severity": "low" }
  ],
  "missing": ["REQ-004"],
  "riskLevel": "medium"
}
```

**Scoring:** drifted.length === 3, each drifted item has matching requirementId

---

## CodeReviewAgent

### TC-CR-001: Detect 2 lint violations and 1 security issue

**Input:**
```json
{
  "convergenceReport": { "aligned": [], "drifted": [], "missing": [], "riskLevel": "low" },
  "changedFiles": ["test-fixtures/code-with-issues/AuthService.cs", "test-fixtures/code-with-issues/App.tsx"],
  "qualityGates": { "minCoverage": 80, "blockOnCritical": true, "warnOnHigh": true }
}
```

**Expected Output:**
- `passed` === false
- `issues.length` >= 3
- At least 1 issue with category "security"
- At least 2 issues with category "style"

**Scoring:** passed===false (exact), issues.length >= 3 (threshold), security issue present (boolean)

---

## QualityGateAgent

### TC-QG-001: Pass when all thresholds met

**Input:**
```json
{
  "patchSet": { "patches": [], "testsPassed": true },
  "qualityThresholds": { "minCoverage": 80, "blockOnCritical": true, "securityScanEnabled": true }
}
```

**Expected Output:**
- `passed` === true
- `coverage` >= 80
- `evidence.length` >= 3

**Scoring:** passed===true (exact), coverage >= threshold (threshold)

---

### TC-QG-002: Fail when coverage below threshold

**Input:**
```json
{
  "patchSet": { "patches": [], "testsPassed": true },
  "qualityThresholds": { "minCoverage": 95, "blockOnCritical": true, "securityScanEnabled": true }
}
```

**Expected Output:**
- `passed` === false
- `coverage` < 95
- evidence contains "coverage" failure entry

**Scoring:** passed===false (exact)

---

## DeployAgent

### TC-DA-001: Reject when GateResult.passed is false

**Input:**
```json
{
  "gateResult": { "passed": false, "coverage": 70, "securityScore": 50, "evidence": ["tests failed"] },
  "deployConfig": { "environment": "alpha", "target": "10.100.253.131", "healthEndpoint": "/api/health" },
  "commitSha": "abc123"
}
```

**Expected Output:**
- Throws `HardGateViolation` error
- DeployRecord is NOT created
- No deploy commands are executed

**Scoring:** Error thrown (boolean), error type matches (exact)

---

## RemediationAgent

### TC-RA-001: Fix a single critical issue

**Input:**
```json
{
  "reviewResult": {
    "passed": false,
    "issues": [{ "id": "ISS-001", "file": "test-fixtures/fixable/Service.cs", "line": 10, "severity": "critical", "category": "security", "message": "Hardcoded connection string" }],
    "coveragePercent": 85,
    "securityFlags": ["hardcoded-secret"]
  },
  "repoRoot": "test-fixtures/fixable"
}
```

**Expected Output:**
- `patches.length` === 1
- `patches[0].issueId` === "ISS-001"
- `testsPassed` is boolean

**Scoring:** patches.length===1 (exact), issueId matches (exact)
