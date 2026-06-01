# Jurisdiction Matrix

Per-jurisdiction map of which statutes apply to which capability. LegalAgent
loads this to identify controlling law before drafting.

Sources: most-recent revisions as of 2026-06-01. Statute citations include
effective dates so freshness can be verified at draft time.

## Employee monitoring (UserActivity plugin)

| Jurisdiction | Controlling statute(s) | Effective | Key requirement |
|---|---|---|---|
| US-CA | CA Labor Code §435; CA Penal Code §632; CCPA §1798.100 et seq | 1995 / 1967 / 2020 | Notice required; one-party consent insufficient for electronic monitoring per CA Penal §632 (two-party). CCPA "personal information" + "purpose limitation" applies. |
| US-IL | IL Biometric Information Privacy Act (BIPA) 740 ILCS 14; IL Personnel Record Review Act | 2008 / various | BIPA requires explicit written consent + retention schedule + destruction. Per-employee statutory damages. |
| US-NY | NY Labor Law §52-c | 2022 | Written notice + acknowledgment before monitoring; provided upon hire and on system change |
| US-CT | CT Gen Stat §31-48d | 1998 | Posted notice of monitoring in conspicuous workplace location |
| US-CO | CO Privacy Act (CPA) §6-1-1301 et seq | 2023 | CCPA-style consumer privacy; "employment data" carve-out narrowing |
| US-WA | WA RCW Title 49 + 19.375 (Biometric) | various | Biometric consent + employment-data protections |
| US-VA | VA CDPA §59.1-575 et seq | 2023 | CCPA-style; employment data exemption (currently) |
| US-TX | TX Capture/Use of Biometric Identifiers §503.001 | 2009 | Biometric consent (not as strict as IL BIPA) |
| US-FL | FL CDPA (FDPA effective 2024) | 2024 | Consumer privacy; small-business carve-out |
| EU | GDPR (Reg 2016/679) + ePrivacy Directive | 2018 / 2002 | Lawful basis required; data subject rights; DPIA for high-risk processing; employee monitoring typically requires legitimate-interest balancing test + works council consultation in DE/FR/IT |
| UK | UK GDPR + Data Protection Act 2018 | 2021 | Same as EU GDPR for substance; ICO guidance specific on employee monitoring |
| CA (Canada) | PIPEDA + provincial (BC PIPA, AB PIPA, QC Law 25) | various / 2024 | Consent-based; QC Law 25 has expanded consent requirements |
| AU | Privacy Act 1988 + Workplace Surveillance Acts (state-specific NSW, ACT, VIC) | various | Notice + consent + transparency obligations |

## Health information

| Jurisdiction | Controlling statute(s) | Effective | Key requirement |
|---|---|---|---|
| US-FEDERAL | HIPAA Privacy + Security Rules; HITECH | 2003 / 2009 | BAA required for processors; breach notification |
| US-CA | CMIA + CCPA medical-info carve-out | 1981 / 2020 | Stricter than HIPAA in some provisions; CMIA private right of action |
| US-TX | TX HB300 | 2012 | Stricter consent + training requirements than HIPAA |
| EU | GDPR Art 9 (special category) | 2018 | Explicit consent or other Art 9 lawful basis |

## Card data

| Jurisdiction | Controlling | Effective | Note |
|---|---|---|---|
| US-FEDERAL | PCI DSS (industry contract, not statute) | v4.0 mandatory 2025 | Contractual obligation via card brand rules |
| US-FEDERAL | FTC Safeguards Rule (financial institutions) | 2023 revisions | Encryption + MFA + risk assessment |
| EU | PSD2 | 2018 | Strong customer authentication |

## Children's data

| Jurisdiction | Controlling | Effective | Note |
|---|---|---|---|
| US-FEDERAL | COPPA (15 USC §6501) | 2000 / 2013 update | Under 13 — verifiable parental consent |
| US-CA | CCPA + CalAB 1281 (under-16 opt-in) | 2020 | Under 16 — opt-in for sale of PI |
| EU | GDPR Art 8 (under 16, MS may lower to 13) | 2018 | Parental consent for under-16 (varies by MS) |

## Breach notification (high-level — stricter rule applies)

| Jurisdiction | Statute | Notification deadline |
|---|---|---|
| US-FEDERAL | HIPAA Breach Notification Rule | Without unreasonable delay, no later than 60 days |
| US-CA | CA Civil Code §1798.82 | Most expedient time possible + without unreasonable delay |
| US-NY | SHIELD Act §899-aa | Most expedient time + without unreasonable delay (parallels CA) |
| US-FEDERAL | SEC Cybersecurity Disclosure Rule (Public Companies) | 4 business days from materiality determination |
| US-FEDERAL | DFARS 252.204-7012 | 72 hours (DC3) |
| EU | GDPR Art 33 | 72 hours to supervisory authority |

(StateRAMP, NERC CIP, CJIS, ITAR each have separate incident-reporting deadlines — see those framework files.)

## Update protocol

- LegalAgent flags `statute_verification_recommended: true` if any cited statute's effective date is >2 years old AND no `freshness_verified_at` within 6 months
- WebFetch verification recommended for any statute the agent has not freshly cited within 12 months
- Add new jurisdictions on first encounter — never draft for an uncovered jurisdiction without first extending this matrix

## Update log

- 2026-06-01: initial matrix covering Edge UserActivity scope (CA, IL, NY, CT, CO, WA, VA, TX, FL, EU, UK, CA, AU) + healthcare + cards + children + breach notification
