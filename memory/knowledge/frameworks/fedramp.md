# FedRAMP — Federal Risk and Authorization Management Program

**Scope**: Cloud services used by US federal agencies. Applicable when Technijian provides cloud services (Edge platform itself, M365 GCC, hosted Jian) to federal-adjacent customers.

**Authority**: OMB Memorandum M-22-09, FedRAMP PMO. Authorization through JAB (cross-agency) or Agency ATO.

**Impact levels**: Low (~125 controls), Moderate (~325 controls), High (~421 controls). Edge platform Moderate is the working target.

**Baseline**: NIST SP 800-53 Rev 5. FedRAMP applies additional parameters.

## Sample control mappings (Moderate baseline)

| Control | Description | Edge evidence source |
|---|---|---|
| AC-2 | Account management | `endpoint.login` + M365 conditional access |
| AC-3 | Access enforcement | `actuator.operation` allow-list |
| AC-6 | Least privilege | M365 role + endpoint policy state |
| AU-2 | Event logging | All `*` events with `event_id` + hash chain |
| AU-6 | Audit review | SIEM correlator output |
| CA-7 | Continuous monitoring | Edge heartbeat + SelfGuard |
| CM-2 | Baseline configuration | `endpoint.policy_state`, `net.config_drift` |
| CM-8 | System component inventory | Asset entity (hardware_fingerprint) |
| CP-9 | System backup | `backup.job_status`, `backup.restore_test` |
| IA-2(1)(2) | MFA — privileged / non-privileged | `endpoint.login.mfa_status` |
| IR-4 | Incident handling | Decisions log + Jian autonomous IR |
| RA-5 | Vulnerability scanning | `patch.scan` + Semgrep/CodeQL output |
| SC-7 | Boundary protection | mTLS, ingest service quotas |
| SC-13 | Cryptographic protection | FIPS-validated cipher suites |
| SI-2 | Flaw remediation | `patch.applied`, `patch.deferred` |
| SI-4 | System monitoring | SIEM correlator, SelfGuard tamper detection |
| SI-7 | Software/firmware integrity | `selfguard.heartbeat`, code-signing verify |

(See FedRAMP Moderate baseline spreadsheet at fedramp.gov for full 325.)

## Management assertion template (Continuous Monitoring)

```
Technijian, as Cloud Service Provider for [CSO_NAME], affirms that:
- The boundary as defined in SSP §9 is unchanged this reporting period
- All required NIST SP 800-53 Rev 5 Moderate controls are operating effectively
- POA&Ms tracked: [N] open, [N] closed this period
- Vulnerabilities by severity: critical=[N], high=[N], moderate=[N]
- All critical/high meet POA&M remediation timeline

Signed: [Authorizing Official designate or CEO]
Date: [DATE]
```

## Signing officer

Authorizing Official from the sponsoring agency for ATO. Annual reauthorization. CEO (RJain) signs CSP-side artifacts. Designated FedRAMP POC manages day-to-day artifacts.

## Audit cycle

Initial: full assessment by 3PAO (typically 6-12 months). Continuous monitoring: monthly POA&M updates + quarterly scans + annual assessment.

## Retention

3 years post-ATO termination. Continuous monitoring artifacts retained per FedRAMP Continuous Monitoring Strategy Guide.

## Update log

- 2026-06-01: initial stub
