# FERPA — Family Educational Rights and Privacy Act

**Scope**: Education records at any institution receiving funding from the US Department of Education. Applicable to Technijian education-sector clients.

**Authority**: 20 U.S.C. § 1232g + 34 CFR Part 99. ED enforces.

**Total controls**: ~24 across the disclosure/consent/access framework (FERPA itself is principle-based; mapped controls derive from common-practice + sector overlays like NIST SP 800-171 for student data systems).

## Key requirements

| Requirement | Edge evidence source |
|---|---|
| Annual notification of rights | (org docs) |
| Directory information designation | (institutional policy) |
| Consent before disclosure | (consent forms + audit log of disclosure) |
| Audit log of disclosures | `*.audit` events with disclosure context |
| Access controls on PII | `endpoint.login`, RBAC, file-access audits |
| Encryption (sector-recommended) | `endpoint.disk_encryption`, TLS |
| Personnel training | (cross-system: SAT records) |
| Record retention + secure disposal | Hardware disposal events + record-retention policy |
| Breach notification (institutional policy) | IR runbook + breach-notification template (LegalAgent) |

## Management assertion template

```
[Institution Name] affirms, in connection with services provided by
Technijian, that:
- Access to education records was limited to school officials with
  legitimate educational interests
- Disclosures were either with consent or under a FERPA exception
  (documented per § 99.30 / § 99.31)
- Audit log of disclosures is maintained per § 99.32
- Annual notification of rights was provided

Signed: [Institutional Records Officer / CEO]
Date: [DATE]
```

## Signing officer

Institutional Records Officer (school side). Technijian-side: CEO (RJain).

## Audit cycle

Annual + on-demand on complaint. FPCO investigates complaints.

## Retention

Per institutional record-retention schedule; FERPA disclosure log retention varies by state.

## Update log

- 2026-06-01: stub
