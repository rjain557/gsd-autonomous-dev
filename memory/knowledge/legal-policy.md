# Legal Policy — LegalAgent operating rules

## Document type → default attorney review level

| Document type | Default review level | Rationale |
|---|---|---|
| msa-amendment | outside-counsel-general | Touches contractual relationship |
| baa-update | outside-counsel-general | HIPAA compliance + executed contract |
| eula | outside-counsel-general | Binding on end users |
| privacy-notice | outside-counsel-general | Regulator-facing + jurisdictional |
| employment-monitoring-notice | outside-counsel-specialist | State employment law specialty |
| consent-form | outside-counsel-general | Establishes lawful basis |
| breach-notification | outside-counsel-specialist | Regulator + class-action exposure |
| data-processing-addendum | outside-counsel-specialist | GDPR/CCPA specialty |
| vendor-contract-summary | in-house OR outside-counsel-general | Internal use |
| state-law-summary | in-house OR outside-counsel-general | Informational, not executed |
| sub-processor-disclosure | outside-counsel-general | Contractual notice |
| nda | in-house OR outside-counsel-general | Standard contract |

LegalAgent may upgrade the level (e.g., NDA with ITAR-impacted counterparty → specialist) but should never downgrade below this table.

## Counterparty handling

When the counterparty type is `regulator` or `litigation`, LegalAgent must:
1. Set `requires_licensed_attorney_review: true`
2. Set `attorney_review_level: outside-counsel-specialist`
3. Refuse drafting any communication that would be sent to the regulator/opposing counsel; instead produce a brief for outside counsel

## Default Technijian signatory by document

| Document type | Default signatory |
|---|---|
| MSA / Amendment | CEO (RJain) |
| BAA / Update | CEO + Privacy Officer (if appointed) |
| EULA | CEO |
| Privacy notice | CEO + Privacy Officer |
| Employment monitoring notice | HR officer or CEO |
| Consent form | (counterparty signs; Technijian acknowledges) |
| Breach notification | CEO + Privacy Officer + CISO co-sign |
| Data processing addendum | CEO + Privacy Officer |
| Sub-processor disclosure | CEO |
| NDA | CEO |

## Redlines

When amending an executed agreement:
- `redline_against` field points to the prior version
- Draft body shows full text with [STRIKE/INSERT] markup
- LegalAgent does NOT publish redlined drafts to external counterparties; the redline is for internal review only

## Update log

- 2026-06-01: initial policy
