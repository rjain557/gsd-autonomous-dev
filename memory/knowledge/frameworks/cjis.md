# CJIS — Criminal Justice Information Services Security Policy

**Scope**: Any system processing, storing, or transmitting Criminal Justice Information (CJI). Applicable to law-enforcement-adjacent Technijian clients.

**Authority**: FBI CJIS Division. Latest: CJIS Security Policy v5.9.x.

**Total controls**: ~72 policy areas across 13 sections.

## Sample mappings

| Section | Title | Edge evidence source |
|---|---|---|
| 5.1 | Information Exchange Agreements | (org docs / contracts) |
| 5.2 | Security Awareness Training | (cross-system: Huntress SAT) |
| 5.3 | Incident Response | Decisions log + IR runbook |
| 5.4 | Auditing and Accountability | All `*.audit` events |
| 5.5 | Access Control | `endpoint.login`, M365 RBAC |
| 5.6 | Identification and Authentication | MFA evidence (`endpoint.login.mfa_status`); CJIS advanced authentication 5.6.2.2 requires MFA |
| 5.7 | Configuration Management | `endpoint.policy_state`, `net.config_drift` |
| 5.8 | Media Protection | `useract.usb_event`, disposal events |
| 5.9 | Physical Protection | (org/datacenter docs) |
| 5.10 | System and Communications Protection | mTLS, encryption-at-rest evidence |
| 5.11 | Formal Audits | (org docs + annual triennial audit) |
| 5.12 | Personnel Security | Background-check records (org docs) |
| 5.13 | Mobile Devices | MDM plugin evidence |

## CJIS-specific quirk: FIPS 140-2 cryptography

CJIS REQUIRES FIPS 140-2 (or successor 140-3) validated cryptographic modules
for encryption. Edge transport stack must use validated modules — verified
via `selfguard.crypto_attestation` event.

## Management assertion template

```
Technijian's CJIS Systems Officer affirms, with respect to client
[CLIENT_NAME]'s CJI environment, that controls in CJIS Security Policy v5.x
sections 5.1–5.13 are in effect for the reporting period [START]–[END].
Findings + remediation: [LIST]. FIPS 140-2/3 cryptographic modules validated:
[LIST cert numbers].

Signed: [CSO / CJIS Systems Officer]
Date: [DATE]
```

## Signing officer

CJIS Systems Officer (CSO) — typically designated per CJIS contractual model. CEO co-signs.

## Audit cycle

Triennial CJIS audit by state CSO + annual triennial audit by FBI CJIS APB.

## Retention

5 years (FBI guidance). Some state CSOs require longer.

## Update log

- 2026-06-01: stub
