# ITAR — International Traffic in Arms Regulations

**Scope**: Defense articles + technical data on the US Munitions List (USML). Any client handling USML technical data triggers ITAR.

**Authority**: 22 CFR §§ 120-130. DDTC enforcement (State Dept).

**Total controls**: ~56 (cross-cutting: registration, export control, foreign-person access, technical-data segmentation, encrypted transit, secure storage, audit log).

## Key requirements

| Requirement | Edge evidence source |
|---|---|
| Registration with DDTC | (org-level — not Edge) |
| Empowered Official designation | (org docs) |
| Foreign-person access control | M365 conditional access geo + nationality attribute + `endpoint.login` |
| Technical-data segmentation | `endpoint.policy_state` + DLP labels |
| Encryption in transit | TLS cipher logs, mTLS handshake records |
| Encryption at rest | `endpoint.disk_encryption` |
| Audit log of access to technical data | `useract.session`, `endpoint.audit_d`, file access audit |
| Export-record keeping | (manual + ComplianceAgent assertion) |
| Reportable incidents | Decisions log + IR runbook |

## Carve-out: 22 CFR § 120.54 (encrypted technical data)

End-to-end encrypted technical data with US-only access keys may not constitute an "export" for ITAR purposes, but this is a narrow legal interpretation; LegalAgent + outside counsel required for any reliance on this carve-out.

## Management assertion template

```
Technijian, as an ITAR-registrant with DDTC registration code [CODE], affirms
that during the reporting period [START]–[END]:
- All foreign-person access to ITAR technical data was per Authorized
  License or exemption [LIST]
- All required encryption controls were in place
- No unauthorized exports occurred (or reportable incidents documented: [LIST])

Signed: [Empowered Official] / [CEO]
Date: [DATE]
```

## Signing officer

Empowered Official + CEO. ITAR specifically requires the Empowered Official designation.

## Audit cycle

Annual self-attestation + per-incident reporting + per-license-condition reviews.

## Retention

5 years per export-record-keeping requirements.

## Update log

- 2026-06-01: stub
