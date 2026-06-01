# PCI-DSS — Payment Card Industry Data Security Standard

**Scope**: Any client (or Technijian itself) handling, processing, transmitting, or storing cardholder data. Most Technijian MSP clients are merchants requiring some level of PCI DSS compliance.

**Authority**: PCI Security Standards Council. Currently v4.0 (mandatory March 2025).

**Levels**: 12 high-level requirements, ~78 detailed sub-requirements at v4.0.

## Sample control mappings

| Req | Description | Edge evidence source |
|---|---|---|
| 1.x | Firewall configuration | `net.config_drift`, `net.acl_state` |
| 2.x | Hardened systems | `endpoint.policy_state` |
| 3.x | Protect stored cardholder data | `endpoint.disk_encryption`, encryption-at-rest evidence |
| 4.x | Encrypt in transit | TLS cipher logs, mTLS handshake records |
| 5.x | Anti-malware | `endpoint.av_state`, CrowdStrike/Huntress bridge |
| 6.x | Develop + maintain secure systems | Patch scan, SAST output, code review records |
| 7.x | Restrict access by business need | Role-based access in M365, `actuator.operation` |
| 8.x | Identify + authenticate access | `endpoint.login`, MFA evidence |
| 9.x | Restrict physical access | (org / datacenter — non-Edge) + USB control via `useract.usb_event` |
| 10.x | Track + monitor all access | Comprehensive audit log: `*.audit`, SIEM |
| 11.x | Regular security testing | Penetration test reports + vulnerability scans |
| 12.x | Information security policy | (org docs) + risk assessment artifacts |

## v4.0 customized approach requirements

PCI 4.0 adds the "customized approach" alternative to traditional requirements.
ComplianceAgent must capture both the customized approach controls AND the
underlying security objectives when this path is chosen.

## Management assertion template

```
Technijian's management asserts that, with respect to client [CLIENT_NAME]'s
cardholder data environment (CDE) as documented in the CDE diagram:
- The CDE scope is correctly identified
- All applicable PCI DSS v4.0 requirements were assessed
- The Self-Assessment Questionnaire / Report on Compliance reflects the
  state of controls during the reporting period
- Findings: [LIST]

Signed: [CFO + CISO co-sign]
Date: [DATE]
```

## Signing officer

CFO + CISO co-sign. RJain may sign as CEO if neither role is appointed.

## Audit cycle

Annual. QSA assessment required for Level 1 merchants; SAQ for lower levels.

## Retention

1 year minimum for audit logs; 3 months immediately accessible. Compliance docs retained as long as the relationship exists + 3 years.

## Update log

- 2026-06-01: initial stub aligned to PCI DSS v4.0
