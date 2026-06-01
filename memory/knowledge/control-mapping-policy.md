# Control Mapping Policy

How ComplianceAgent maps Edge telemetry → framework controls.

## Mapping principles

1. **N-to-1 is the default**: a single Edge event typically maps to many
   framework controls (an MFA event satisfies HIPAA, PCI, SOC2, CMMC, ISO
   simultaneously). Express this with `control_mapping_groups`, not by
   duplicating evidence across frameworks.

2. **Strictest applies on conflict**: when two frameworks disagree (e.g., EU
   GDPR data-minimization vs CMMC comprehensive logging), document the
   conflict in the evidence pack and apply the stricter standard. Route to
   LegalAgent for resolution if it impacts a contractual deliverable.

3. **No silent gaps**: if a control has no mapped evidence source, output it
   as a `Gap` with a remediation_task. Never claim a control is "met" without
   an evidence source pointer.

4. **Evidence pack is auditor-facing**: every record in the pack must include
   the SQL query / file path / API endpoint that produced it, so an auditor
   can independently reproduce the evidence.

5. **Continuous attestation is the goal**: point-in-time evidence is acceptable
   for audit cycles but each control should target continuous (≤24h cadence)
   evidence. AttestationDriftItem fires when cadence is missed.

## Control mapping group naming

Group IDs use kebab-case domain identifiers:
- `mfa-enforcement`
- `disk-encryption-at-rest`
- `endpoint-malware-protection`
- `network-segmentation`
- `backup-rpo-verification`
- `audit-log-retention`
- `change-management-approval`
- `vulnerability-management`
- `access-review-quarterly`
- `incident-response-playbook`

(Extend this list as new groups emerge.)

## Per-framework signing officer defaults

| Framework | Signing officer | Cadence |
|---|---|---|
| HIPAA | CISO (if appointed) or CEO | Annual + breach trigger |
| PCI-DSS | CFO + CISO co-sign | Annual |
| SOC 2 | CEO management assertion | Per audit window |
| SOX | CFO management assertion | Quarterly + annual |
| GLBA | CISO | Annual |
| CMMC | Senior accountable official (RJain) | Triennial + interim self-assessment |
| FedRAMP / FISMA / DFARS | RJain + designated FedRAMP POC | Continuous monitoring + annual |
| ITAR | RJain + Empowered Official | Annual |
| CJIS | CJIS Systems Officer + RJain | Annual |
| ISO 27001 | RJain + ISMS owner | Annual |
| NIST 800-53 | Authorizing Official | Per ATO (3 years) |
| StateRAMP | RJain + state POC | Per state cycle |
| NERC CIP | CIP Senior Manager | Quarterly + annual |
| FERPA | RJain or designated official | Annual |

Default to CEO (RJain) if no role specified.

## Evidence retention

| Framework | Min retention |
|---|---|
| HIPAA | 6 years |
| PCI-DSS | 1 year minimum, 3 months immediately accessible |
| SOC 2 | Audit period + 7 years recommended |
| SOX | 7 years |
| FedRAMP | 3 years post-ATO |
| ITAR | 5 years |
| CJIS | Per FBI guidance (5+ years typical) |
| All others | 7 years (conservative default) |

ComplianceAgent flags evidence approaching retention boundary as a separate
type of finding (not a gap, but an action item for the retention policy).

## Update log

- 2026-06-01: initial policy
