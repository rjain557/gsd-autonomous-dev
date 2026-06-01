# GLBA — Gramm-Leach-Bliley Act

**Scope**: Financial institutions handling consumer financial information. Many Technijian financial-services clients trigger GLBA Safeguards Rule.

**Authority**: 15 U.S.C. §§ 6801-6809 (Title V). FTC + bank regulators enforce. Safeguards Rule revisions effective 2023.

**Total controls**: ~32 across the Safeguards Rule (16 CFR Part 314).

## Sample mappings (Safeguards Rule, 16 CFR § 314.4)

| Requirement | Edge evidence source |
|---|---|
| Designate Qualified Individual | (org docs) |
| Written risk assessment | ComplianceAgent gap analysis output |
| Access controls | `endpoint.login`, RBAC |
| Encryption of customer info in transit + at rest | TLS + `endpoint.disk_encryption` |
| MFA for accessing customer info | `endpoint.login.mfa_status` |
| Continuous monitoring or annual pen testing + semi-annual vulnerability scans | `patch.scan`, `selfguard.*`, pen-test artifacts |
| Procedures for retention + secure disposal | Hardware disposal events + retention policy docs |
| Service-provider oversight | (vendor management records) |
| Written incident response plan | IR runbook |
| Annual board report by Qualified Individual | (org docs) |

## Management assertion template

```
Technijian's Qualified Individual (Information Security Program Coordinator)
affirms that for the reporting period [START]–[END]:
- The Information Security Program was implemented per 16 CFR § 314.3
- Risk assessment was conducted/updated
- Required controls per § 314.4 were in effect
- Incidents notified per § 314.5: [N]

Signed: [Qualified Individual]
Date: [DATE]
```

## Signing officer

Qualified Individual (Information Security Program Coordinator) — typically CISO or designated officer. CEO co-signs board report.

## Audit cycle

Annual board report + ongoing continuous monitoring. Independent attestation as required by primary regulator.

## Retention

Per institution's records-retention policy + 5 years minimum recommended.

## Update log

- 2026-06-01: stub
