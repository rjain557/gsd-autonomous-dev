# NERC CIP — Critical Infrastructure Protection

**Scope**: Bulk Electric System operators + supporting vendors. Applicable to any Technijian client classified as Registered Entity or vendor supplying low-/medium-/high-impact BES Cyber Systems.

**Authority**: NERC Reliability Standards (FERC-approved).

**Total controls**: ~92 across CIP-002 through CIP-014 + CIP-007/CIP-010 v8/v9 (the v9 revision is the current target).

## Standard families

- CIP-002 BES Cyber System Categorization
- CIP-003 Security Management Controls
- CIP-004 Personnel and Training
- CIP-005 Electronic Security Perimeter(s)
- CIP-006 Physical Security
- CIP-007 System Security Management
- CIP-008 Incident Reporting and Response Planning
- CIP-009 Recovery Plans
- CIP-010 Configuration Change Management and Vulnerability Assessments
- CIP-011 Information Protection
- CIP-013 Supply Chain Risk Management
- CIP-014 Physical Security

## Sample mappings

| Standard | Edge evidence source |
|---|---|
| CIP-005 R1 | mTLS handshake records, network segmentation evidence |
| CIP-007 R1 (ports/services) | `endpoint.policy_state` net.listening_ports |
| CIP-007 R2 (security patch mgmt) | `patch.scan`, `patch.applied` |
| CIP-007 R3 (malicious code) | `endpoint.av_state`, CrowdStrike/Huntress |
| CIP-007 R4 (security event monitoring) | All `*.audit` events, SIEM |
| CIP-008 R1 (incident response plan) | IR runbook + decisions log |
| CIP-010 R1 (config change mgmt) | `net.config_drift`, PR approval records |
| CIP-013 R1 (supply chain) | SCA scan output + SBOM |

## Management assertion template

```
[Registered Entity Name], NCR-[NUMBER], affirms that for the
applicable BES Cyber Systems in scope, controls per NERC CIP-002 through
CIP-014 are operating effectively for the reporting period [START]–[END].

Signed: [CIP Senior Manager]
Date: [DATE]
```

## Signing officer

CIP Senior Manager (NERC-defined role). CEO co-signs.

## Audit cycle

Per NERC Compliance Monitoring Enforcement Program — typically 3-year audit cycle + ongoing self-monitoring + spot checks.

## Retention

3 years minimum for compliance evidence per NERC.

## Update log

- 2026-06-01: stub
