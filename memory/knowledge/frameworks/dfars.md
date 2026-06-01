# DFARS — Defense Federal Acquisition Regulation Supplement

**Scope**: DoD contractor flow-down. Most prominent: DFARS 252.204-7012 (Safeguarding Covered Defense Information) + 252.204-7019/7020 (NIST SP 800-171 self-assessment) + 252.204-7021 (CMMC).

**Authority**: DoD.

**Total controls**: ~48 (encompassing 800-171 plus additional incident reporting + cloud computing requirements).

## Key clauses

| Clause | Requirement | Edge evidence source |
|---|---|---|
| 252.204-7012 | Adequate security per NIST SP 800-171 | See [[cmmc]] mappings |
| 252.204-7012(b)(2) | Incident reporting within 72 hours to DC3 | Decisions log + IR-4 records |
| 252.204-7012(b)(3) | Submit malware code if requested | (one-time per incident) |
| 252.204-7019 | Submit Basic Assessment score to SPRS | CMMC self-assessment output |
| 252.204-7020 | NIST SP 800-171 DoD Assessment | Triennial 3PAO + interim self |
| 252.204-7021 | CMMC Level (per contract) | See [[cmmc]] |

## Management assertion template

```
Technijian, as a [PRIME|SUBCONTRACTOR] on contract [CONTRACT_NUMBER], affirms
that all DFARS 252.204-7012 / 7019 / 7020 / 7021 obligations have been met
for the reporting period [START]–[END]. CDI handling scope is documented at
[SSP reference]. Incidents reported: [N]. Cloud services used: [LIST per
DFARS 252.239-7010 if applicable].

Signed: [Senior Accountable Official]
Date: [DATE]
```

## Signing officer

Senior Accountable Official (CEO/RJain default). Empowered Official for ITAR-overlap content.

## Audit cycle

Triennial 3PAO via CMMC. Annual SPRS score refresh. Per-incident reporting.

## Retention

6 years post-contract.

## Update log

- 2026-06-01: stub
