# HIPAA — Health Insurance Portability and Accountability Act

**Scope**: Health information for any client classified as a Covered Entity or
Business Associate. Technijian is typically a Business Associate under a BAA.

**Authority**: 45 CFR Parts 160, 162, 164. HHS OCR enforcement.

**Total controls (Security Rule, the part Edge evidences)**: 45 implementation
specifications across Administrative (§164.308), Physical (§164.310), and
Technical (§164.312) safeguards.

## Sample control mappings (Security Rule, §164.308 — §164.312)

| Control | Description | Edge evidence source |
|---|---|---|
| §164.308(a)(1)(ii)(A) | Risk analysis | ComplianceAgent gap-analysis output |
| §164.308(a)(1)(ii)(B) | Risk management plan | Decisions log + remediation tickets |
| §164.308(a)(3)(ii)(B) | Workforce clearance | M365 license + role audit (existing) |
| §164.308(a)(5)(ii)(D) | Password / MFA | `endpoint.login.mfa_status` |
| §164.308(a)(6)(ii) | Response and reporting | Decision log + incident-response runbook |
| §164.308(a)(7) | Backup + disaster recovery | `backup.job_status`, `backup.restore_test` |
| §164.310(a)(2)(iii) | Workstation use | `useract.session`, `endpoint.policy_state` |
| §164.310(d)(1) | Disposal | `endpoint.hardware_fingerprint` retire event |
| §164.310(d)(2)(i) | Disposal — media sanitization | (GAP — needs HardwareDisposal event) |
| §164.310(d)(2)(ii) | Re-use of media | (GAP — needs sanitization-verification event) |
| §164.312(a)(1) | Access control | `endpoint.policy_state`, M365 conditional access |
| §164.312(a)(2)(i) | Unique user ID | `endpoint.login`, `endpoint.boot` |
| §164.312(a)(2)(iii) | Auto-logoff | `useract.session.idle_timeout` |
| §164.312(a)(2)(iv) | Encryption / decryption | `endpoint.disk_encryption` |
| §164.312(b) | Audit controls | `endpoint.audit_d` (Linux), Windows EventLog → SIEM |
| §164.312(c)(1) | Integrity | `selfguard.heartbeat`, file integrity monitoring |
| §164.312(d) | Authentication | `endpoint.login` |
| §164.312(e)(1) | Transmission security | TLS 1.3 enforced at all transport points |
| §164.312(e)(2)(i) | Integrity controls (transmission) | mTLS handshake records |
| §164.312(e)(2)(ii) | Encryption (transmission) | TLS cipher suite logs |

(Additional 25 implementation specs follow the same pattern. Reference HHS
documentation at https://www.hhs.gov/hipaa/for-professionals/security/ for
the complete enumeration.)

## Management assertion template

```
Technijian's management asserts that the controls relevant to the HIPAA
Security Rule administrative, physical, and technical safeguards for
client [CLIENT_NAME] were designed and operating effectively from [START]
to [END]. Evidence comprises [N] records from M365 audit logs, [N] records
from Edge endpoint telemetry, [N] records from CrowdStrike alerts, [N]
records from Huntress alerts, and [N] records from the Edge backup-plugin
RPO verification. Exceptions noted: [LIST] (see exceptions section).

Signed: [CEO name]
Title: [CEO/CISO]
Date: [DATE]
```

## Signing officer

Default: CISO if appointed, otherwise CEO (RJain). HIPAA requires a designated
Privacy Officer + Security Officer — Technijian must name these in client BAAs.

## Audit cycle

Continuous attestation preferred. Auditor assessments typically annual at
client request or pre-contract. Breach notification triggers on-demand.

## Retention

Documentation: 6 years from creation date or date last in effect, whichever is later (§164.316(b)(2)).

## Update log

- 2026-06-01: initial population of common Security Rule mappings.
