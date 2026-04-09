---
type: knowledge
description: Quality gate thresholds for pipeline pass/fail decisions
---

# Quality Gates

## Build Gate

| Check | Threshold | Block on Fail |
|---|---|---|
| dotnet build | 0 errors | Yes |
| npm run build | 0 errors | Yes |
| Build warnings | < 50 | No (warn) |

## Coverage Gate

| Metric | Threshold | Block on Fail |
|---|---|---|
| Line coverage | >= 80% | Yes |
| Branch coverage | >= 60% | No (warn) |
| New code coverage | >= 90% | No (warn) |

## Security Gate

| Check | Threshold | Block on Fail |
|---|---|---|
| Critical vulnerabilities | 0 | Yes |
| High vulnerabilities | 0 | Yes |
| Medium vulnerabilities | < 5 | No (warn) |
| Hardcoded secrets | 0 | Yes |
| PII in logs | 0 | Yes |

## Code Review Gate

| Metric | Threshold | Block on Fail |
|---|---|---|
| Critical issues | 0 | Yes |
| High issues | 0 | Yes |
| Medium issues | < 10 | No (warn) |
| Convergence drift (high) | 0 | Yes |

## Compliance (from global-config.json)

| Framework | Requirement |
|---|---|
| HIPAA | PII fields encrypted, audit logging, access control |
| SOC 2 | Change management, monitoring, incident response |
| PCI | Card data isolation, encryption, key management |
| GDPR | Consent management, data portability, right to erasure |

## Database Gate

| Check | Threshold | Block on Fail |
|---|---|---|
| DB completeness | >= 90% | Yes |
| Seed data present | Required | Yes |
| Foreign key integrity | All valid | Yes |
| Index coverage | All queries covered | No (warn) |

## E2E Validation Gate

| Check | Threshold | Block on Fail |
|---|---|---|
| E2E pass rate | >= 95% | Yes |
| API contract compliance | 100% (all documented endpoints exist) | Yes |
| Mock data detected | 0 patterns in non-test files | No (warn) |
| Browser render | Page loads, no console errors | No (warn) |

## Spec Quality Gate

| Check | Threshold | Block on Fail |
|---|---|---|
| Clarity score | >= 70 | Warn |
| Cross-artifact consistency | No conflicts | Block on critical |
| Spec drift contamination | 0 | Block |
