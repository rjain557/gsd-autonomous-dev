# SOX — Sarbanes-Oxley Act

**Scope**: Public-company financial reporting + ITGCs. Some Technijian clients are SOX-applicable (publicly traded or pre-IPO + Section 404 audited).

**Authority**: 15 U.S.C. § 7241 + § 7262. PCAOB AS-5 + AS-2201 for ITGC scope.

**Total controls**: ~28 (ITGC-focused, mapping to AS-2201).

## Sample ITGC mappings

| ITGC area | Description | Edge evidence source |
|---|---|---|
| Access security | Provisioning + deprovisioning + reviews | `endpoint.login`, M365 role audits, decommission events |
| Change management | Authorized + tested changes | PR approval records + deployment audit |
| Computer operations | Backup + recovery + scheduling | `backup.job_status`, `backup.restore_test` |
| Program development | SDLC controls | gsd pipeline + QualityGate evidence |

## SOX-specific note: Segregation of duties

Auditors expect SoD between dev / ops / approver. gsd's BaseAgent + RoleSeparation in deployment gates enforces this — ComplianceAgent surfaces SoD-violation evidence when a single human approves AND deploys.

## Management assertion template

```
Technijian's management asserts, with respect to client [CLIENT_NAME]'s
ICFR scope:
- ITGCs covering access security, change management, computer operations,
  and program development were operating effectively during [PERIOD]
- Deficiencies identified: [LIST]
- Material weaknesses: [LIST] (or "none identified")

Signed: [CFO]
Date: [DATE]
```

## Signing officer

CFO + CEO co-sign per Section 302 / 906 certifications (if direct attestation).

## Audit cycle

Quarterly management certifications + annual external audit. Continuous monitoring.

## Retention

7 years (SOX Section 802).

## Update log

- 2026-06-01: stub
