# SOC 2 — Service Organization Controls, Type II

**Scope**: Service organizations (Technijian as MSP). Reports on the effectiveness of controls over the Trust Service Criteria (TSC).

**Authority**: AICPA. SOC 2 reports issued by licensed CPA firms.

**TSC categories**: Security (always), Availability, Processing Integrity, Confidentiality, Privacy. Technijian targets at minimum Security + Availability + Confidentiality for MSP scope.

## Total controls

~64 controls when scoped to Security + Availability + Confidentiality. Mapping to TSC reference 2017 (revised 2022).

## Sample control mappings

| TSC ref | Description | Edge evidence source |
|---|---|---|
| CC1.1 | Demonstrates commitment to integrity / values | (org docs — non-Edge) |
| CC2.1 | Information for objectives — internal communication | (org docs) |
| CC5.1 | Selects + develops control activities | (process artifacts) |
| CC6.1 | Implements logical access controls | `endpoint.login`, M365 conditional access |
| CC6.6 | Implements logical access for boundary | mTLS + `endpoint.boot` |
| CC6.7 | Restricts authorized software | `useract.process_exec`, app allow-list |
| CC6.8 | Prevents/detects malicious software | `endpoint.av_state`, CrowdStrike/Huntress bridge |
| CC7.1 | Monitors components for anomalies | SIEM correlator output |
| CC7.2 | Monitors and identifies security events | All `*.tamper`, `selfguard.*` events |
| CC7.3 | Evaluates events to determine response | Decisions log |
| CC7.4 | Responds to identified security events | IR runbook + Jian autonomous-remediation |
| CC8.1 | Authorizes changes — change management | Git history + PR approval records |
| CC9.1 | Identifies + selects + manages risk | RiskRegister + ComplianceAgent gap report |
| A1.1 | Availability — capacity management | `vsphere.host_health`, `sql.health` |
| A1.2 | Availability — environmental protections | (org docs + datacenter SOC reports) |
| C1.1 | Confidentiality — identifies + maintains classification | (data classification policy — org docs) |
| C1.2 | Confidentiality — disposes per policy | `endpoint.hardware_fingerprint` retire event |

## Management assertion template

```
Technijian's management asserts that:
- The system description in Section [N] presents the system accurately
- The controls were suitably designed throughout [START]–[END]
- The controls operated effectively throughout [START]–[END] to provide
  reasonable assurance that the Service Commitments and System Requirements
  were achieved relative to the Trust Service Criteria of Security,
  Availability, and Confidentiality
- Exceptions noted: [LIST]

Signed: [CEO]
Date: [DATE]
```

## Signing officer

CEO (RJain). Type II reports cover an audit period (typically 6-12 months); management assertion is signed at the end of the period.

## Audit cycle

Annual Type II audit by a licensed CPA firm. Continuous attestation feeds the auditor's testing.

## Retention

Audit period + 7 years recommended.

## Update log

- 2026-06-01: initial stub
