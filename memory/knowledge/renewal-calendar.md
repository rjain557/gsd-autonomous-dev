# Renewal Calendar

Dated calendar of certs/licenses/recertifications/audit cycles. PMAgent
elevates items <60 days from due as `urgent_renewals`.

## Schema

```
## YYYY-MM-DD — <Item>
- type: cert-rotation | license-renewal | recertification | audit | drill | submission
- owner: pm-agent | security-agent | legal-agent | compliance-agent | rjain
- preparation_status: not-started | in-progress | ready-for-signature | complete
- artifact_path: (when applicable)
- notes: free-form
```

## Upcoming items

### 2026-Q3

#### 2026-07-01 — ME-EC renewal-cycle-end +9 months marker (cutover prep window opens)
- type: submission
- owner: pm-agent
- preparation_status: not-started
- notes: Per §11 q6 — single fleet cutover at end of current ME-EC subscription. Renewal was 2 months before 2026-06-01 → expires ~2027-04. Marker fires at the 9-month-pre-cutover point so prep work can begin.

#### 2026-09-01 — DR Drill Q3
- type: drill
- owner: pm-agent + security-agent
- preparation_status: not-started
- notes: Per §11 q7 — quarterly business-hours DR drill. IRV → Vegas full cutover + back. Notify customers in advance.

### 2026-Q4

#### 2026-12-01 — DR Drill Q4
- type: drill
- owner: pm-agent + security-agent

#### 2026-12-31 — Annual HIPAA Security Officer certification (if HIPAA-applicable clients audit-ready)
- type: recertification
- owner: compliance-agent + security-agent
- preparation_status: not-started

### 2027-Q1

#### 2027-03-01 — DR Drill Q1
- type: drill
- owner: pm-agent + security-agent

#### 2027-03-01 — ME-EC cutover preparation window opens (60 days pre-cutover)
- type: submission
- owner: pm-agent
- preparation_status: not-started

### 2027-Q2

#### ~2027-04-XX — ME-EC subscription end + fleet cutover to Edge PatchManager
- type: license-renewal (NOT renewing — cutting over)
- owner: pm-agent + rjain
- preparation_status: not-started
- notes: Confirm exact subscription end date from vendor contract. Cutover happens within 30 days of end date.

### Continuous / annual repeating

#### Annual — Apple Push Notification certificate rotation
- type: cert-rotation
- owner: pm-agent + rjain
- notes: Once granted (after vendor application), rotates annually. PMAgent fires 60 days before expiry.

#### Annual — Code-signing EV cert renewal (DigiCert/Sectigo)
- type: cert-rotation
- owner: security-agent + rjain
- notes: Phone verification with vendor SE required. RJain takes the call.

#### Annual — AV vendor allow-list recertifications (per-vendor)
- type: recertification
- owner: pm-agent
- notes: Per-vendor cadence; typically annual.

#### Annual — HSM root-of-trust ceremony review
- type: cert-rotation
- owner: security-agent
- notes: 2-of-3 multi-party ceremony procedure review.

#### Per-audit-cycle — Compliance management assertions
- type: submission
- owner: compliance-agent + rjain
- notes: Auditor-driven. SOC 2 Type II annual. HIPAA per-client. PCI annual.

## Update log

- 2026-06-01: initial population from §11 decisions + §10 timelines
