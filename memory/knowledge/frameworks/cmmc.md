# CMMC 2.0 — Cybersecurity Maturity Model Certification

**Scope**: DoD contractors handling Federal Contract Information (FCI) or
Controlled Unclassified Information (CUI). Applicable to Technijian clients
holding DoD contracts.

**Authority**: 32 CFR Part 170 (Final Rule, Oct 2024). DoD CIO + Cyber AB.

**Levels**:
- Level 1 (FCI handlers): 15 practices, annual self-assessment
- Level 2 (CUI handlers): 110 practices, triennial 3rd-party assessment
- Level 3 (high-value CUI): 110 + 24 additional, triennial DIBCAC

## Total controls

Level 2 is the working assumption: **110 practices** mapping to NIST SP 800-171
Rev 2 (which itself derives from NIST SP 800-53). 14 control families: AC, AT,
AU, CM, IA, IR, MA, MP, PE, PS, RA, CA, SC, SI.

## Sample control mappings

| Practice | Description | Edge evidence source |
|---|---|---|
| AC.L2-3.1.1 | Limit system access to authorized users | `endpoint.login`, M365 conditional access |
| AC.L2-3.1.2 | Limit system access to authorized transactions | `actuator.operation` catalog enforcer |
| AC.L2-3.1.20 | Verify connections to external systems | mTLS handshake records, DNS-pinning |
| AT.L2-3.2.1 | Provide security awareness training | (cross-system: Huntress SAT records) |
| AU.L2-3.3.1 | Create system audit logs | `endpoint.audit_d`, EventLog → SIEM |
| AU.L2-3.3.5 | Correlate audit record review | SIEM correlator output |
| CM.L2-3.4.1 | Establish baseline configurations | `endpoint.policy_state`, `net.config_drift` |
| CM.L2-3.4.2 | Establish/enforce security config settings | `endpoint.policy_state` |
| IA.L2-3.5.3 | Use MFA for privileged accounts | `endpoint.login.mfa_status` |
| IR.L2-3.6.1 | Establish incident-handling capability | Decisions log + IR runbook |
| MP.L2-3.8.3 | Sanitize media before disposal | (GAP — needs disposal-event plugin) |
| SC.L2-3.13.1 | Monitor + control communications | mTLS, ingest service per-client quota |
| SC.L2-3.13.11 | Use FIPS-validated cryptography | TLS cipher suite logs, HSM-stored keys |
| SI.L2-3.14.1 | Identify + report system flaws | `patch.scan`, vulnerability scan output |
| SI.L2-3.14.6 | Monitor + identify unauthorized use | SIEM correlator, `useract.*` events |

(See NIST SP 800-171 Rev 2 + CMMC 2.0 assessment guide for the full 110.)

## Management assertion template (Level 2 self-assessment)

```
Technijian's Senior Accountable Official affirms that for the scope covered
by client [CLIENT_NAME]'s DoD contract, all 110 CMMC Level 2 practices were
assessed and the assessed score is [N]/110. Practices NOT MET: [LIST] with
POA&M attached. Reference: CMMC Assessment Guide L2 v2.13 (DRAFT [DATE]).

Signed: [Senior Accountable Official]
Title: [TITLE]
Date: [DATE]
```

## Signing officer

CMMC requires a **Senior Accountable Official** — typically the CEO. RJain is
the default signer.

## Audit cycle

Level 2: triennial third-party CMMC assessment (C3PAO). Interim annual
self-assessments. Continuous monitoring expected.

## Retention

POA&Ms + audit evidence: 6 years (consistent with broader federal contracting
record-retention).

## Update log

- 2026-06-01: initial stub with common Level 2 mappings.
