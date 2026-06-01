# Calendar-Time Tracks

Parallel tracks that run on calendar time independent of code progress.
PMAgent monitors these; they typically gate downstream code milestones.

## Track 1 — Apple MDM Vendor Relationship
- Owner: rjain (signatory) + pm-agent (tracking)
- Start: 2026-06-01 (week-1 per §11 q4)
- ETA: ~2026-09
- Steps:
  - [ ] D-U-N-S number verified (likely existing)
  - [ ] business.apple.com account created
  - [ ] APN cert request submitted
  - [ ] (vendor) Apple SE assigned + verification call
  - [ ] APN cert granted
  - [ ] First annual rotation date logged in renewal-calendar
- Downstream unlock: Phase MDM-D (MdmIos plugin pilot)

## Track 2 — Android Enterprise EMM Partner
- Owner: rjain + pm-agent
- Start: 2026-06-01
- ETA: ~2026-08
- Steps:
  - [ ] EMM partner application submitted
  - [ ] D-U-N-S verification
  - [ ] Test app submitted for review
  - [ ] EMM partner status granted
- Downstream unlock: Phase MDM-E (MdmAndroid plugin pilot)

## Track 3 — Samsung Knox Partner
- Owner: rjain + pm-agent
- Start: 2026-06-15
- ETA: ~2026-08
- Steps:
  - [ ] Knox partner application
  - [ ] Knox MDM API access
- Downstream unlock: Knox-specific features in MdmAndroid

## Track 4 — Code-Signing EV HSM Procurement
- Owner: rjain + (future security engineer or SecurityAgent operations)
- Start: 2026-06-01 (week-1, per §11 q3 — SecurityAgent role replaces hire)
- ETA: ~2026-08
- Steps:
  - [ ] Select vendor: DigiCert vs Sectigo vs Entrust
  - [ ] Select HSM: YubiHSM 2 vs Thales Luna vs cloud HSM (AWS CloudHSM)
  - [ ] EV cert request + phone verification (RJain on call)
  - [ ] HSM provisioning + 2-of-3 ceremony documented
  - [ ] Transparency log infrastructure set up
- Downstream unlock: signed Edge releases for production

## Track 5 — AV Vendor Allow-Listing
- Owner: pm-agent + future security engineer / SecurityAgent
- Start: 2026-07-01
- ETA: rolling (per-vendor 4-12 weeks)
- Steps (per AV vendor):
  - [ ] Identify AV products in customer fleet
  - [ ] Submit Edge agent for allow-listing
  - [ ] Acquire vendor signed allow-list entries
  - [ ] Periodic recertification setup
- AV vendors to engage: Microsoft Defender (telemetry submission), CrowdStrike, Huntress, Sophos, ESET, Bitdefender, Kaspersky (if applicable to fleet), Trend Micro
- Downstream unlock: Edge agent runs without 3rd-party AV interference

## Track 6 — Forward-Looking Legal Templates (Edge UserActivity)
- Owner: legal-agent + rjain (review/signoff)
- Start: 2026-06-01 (per §11 q5 — no client uses Teramind, so this is future-looking only)
- ETA: 2026-08
- Steps:
  - [ ] MSA UserActivity amendment template per jurisdiction (CA, IL, NY, CT, CO, WA, EU, UK, AU)
  - [ ] BAA UserActivity addendum for HIPAA-covered clients
  - [ ] Per-jurisdiction consent form template
  - [ ] Per-state employment-monitoring notice template
  - [ ] Multi-jurisdiction consolidated privacy notice
  - [ ] Outside counsel review of all templates
- Downstream unlock: Phase 7 UserActivity plugin client-side deployment

## Track 7 — Platform Identity Service (tech-web-shared dependency)
- Owner: tech-web-shared team (external)
- Start: TBD by tech-web-shared
- ETA: 2027-Q1
- Steps:
  - [ ] ADR-0007 finalized
  - [ ] Identity Service shipped
  - [ ] Edge Stage 1.5 migration testing
  - [ ] Edge agents auto-enroll mTLS
- Downstream unlock: Identity Service Stage 1.5 (per §11 q1)

## Track 8 — Platform Vault (tech-web-shared dependency)
- Owner: tech-web-shared team (external)
- Start: TBD
- ETA: 2027-Q3
- Steps:
  - [ ] Vault service shipped
  - [ ] Edge Stage 2 JIT credential lease integration
  - [ ] DPAPI credential purge per-agent
- Downstream unlock: full Stage 2 security posture

## Track 9 — DR Drill Cadence (per §11 q7)
- Owner: pm-agent + security-agent
- Start: 2026-09-01 (Q3 drill)
- ETA: continuous quarterly cadence
- Steps:
  - [ ] DR runbook written and signed off
  - [ ] Vegas pre-staged (cert + DNS automation + IaC)
  - [ ] Q3 2026 drill executed
  - [ ] Q4 2026 drill executed
  - [ ] Q1 2027 drill executed
  - [ ] (repeat quarterly)

## Track 10 — Compliance Framework Mapping (per §11 q2 — all 16 frameworks at once)
- Owner: compliance-agent + rjain (final signoff)
- Start: 2026-06-01
- ETA: 2027-Q2 (rough estimate — ComplianceAgent will refine)
- Steps:
  - [ ] Framework reference files populated (16 stubs in place 2026-06-01)
  - [ ] Per-framework control mapping to edge-telemetry-catalog
  - [ ] Evidence pack templates per framework
  - [ ] Management assertion drafts per framework
  - [ ] Gap remediation tasks routed to RemediationAgent
- Downstream unlock: Nexus Phase 12 plugins (GovernEvidencePack)

## Track 11 — FedRAMP / StateRAMP (only if first federal/state customer signed)
- Owner: rjain
- Status: not-started (no critical-path trigger yet)
- Notes: 12-24 months. Park until first customer signed.

## Update log

- 2026-06-01: initial tracks aligned to §11 decisions
