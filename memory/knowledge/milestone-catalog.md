# Milestone Catalog — Edge Platform Coverage

Aligned to the 14-phase rollout in myJian platform-coverage decision §6.
PMAgent reads this to report milestone status.

## Phase 0 — Ratify ADR-0009 (Single Shared Edge Agent)
- status: complete (2026-06-01 via myJian §11 decisions)
- artifacts: docs/jian-remote-agent/platform-coverage-decision-2026-06-01.md
- owner: rjain

## Phase 1 — Edge core + WindowsEndpoint + LinuxEndpoint plugins
- status: in-progress
- percent_complete: 5 (gsd scaffolding + design doc complete; code not started)
- eta: 2026-09
- blocking_dependencies: none
- owner: gsd pipeline + RemediationAgent + SecurityAgent

## Phase 2 — SqlServer plugin (tiered monitoring 3m/15m/60m/12h/weekly)
- status: pending
- percent_complete: 0
- eta: 2026-10
- blocking_dependencies: Phase 1
- owner: gsd pipeline

## Phase 3 — vCenter + SnmpPoller plugins
- status: pending
- percent_complete: 0
- eta: 2026-11
- blocking_dependencies: Phase 1
- owner: gsd pipeline

## Phase 4 — Backup plugins (Nakivo + Veeam)
- status: pending
- percent_complete: 0
- eta: 2027-01
- blocking_dependencies: Phase 1
- owner: gsd pipeline

## Phase 5a — HostRemediator (L1 actuator + catalog enforcer)
- status: pending
- percent_complete: 0
- eta: 2027-02
- blocking_dependencies: Phase 1 + security-engineer signoff on catalog enforcer (SecurityAgent owns)
- owner: gsd pipeline + SecurityAgent

## Phase 5b — LanIpActuator
- status: pending
- percent_complete: 0
- eta: 2027-03
- blocking_dependencies: Phase 5a
- owner: gsd pipeline

## Phase 6 — JianChat REMOVED from scope (chat stays in MS Teams)
- status: complete (decision)
- artifacts: myJian platform-coverage decision
- owner: rjain

## Phase 7 — UserActivity plugin (Teramind capability replacement)
- status: pending
- percent_complete: 0
- eta: 2027-04 (after legal templates ready)
- blocking_dependencies: LegalAgent forward-looking templates (per §11 q5) + per-jurisdiction consent flow design
- owner: gsd pipeline + LegalAgent

## Phase 8 — PatchManager (ME-EC replacement)
- status: pending
- percent_complete: 0
- eta: ~2027-04 (aligned to ME-EC fleet cutover per §11 q6)
- blocking_dependencies: ME-EC current subscription end date
- owner: gsd pipeline + PMAgent

## Phase 9 — TicketShortcut REMOVED from scope (per myJian decision)
- status: complete (decision)
- owner: rjain

## Phase 10 — Fleet rollout (Edge to all client endpoints)
- status: pending
- percent_complete: 0
- eta: 2027-Q2 onward
- blocking_dependencies: Phases 1-5 + customer onboarding plumbing (per §10.6)
- owner: pm-agent

## Phase 11 — Desktop variants (per OS-specific polish)
- status: pending
- percent_complete: 0
- eta: 2027-Q3
- owner: gsd pipeline

## Phase 12 — Nexus module plugins (GovernEvidencePack, AssessVulnScanner, ShieldEdr, etc.)
- status: pending
- percent_complete: 0
- eta: 2027-Q4
- blocking_dependencies: Phase 1 + Nexus framework-mapping layer (per §11 q2 — all 16 frameworks)
- owner: ComplianceAgent + Nexus team

## Phase 13 — Pen-test grid (AWS/Azure VMs + India office sources, NOT endpoint agents per §4.3)
- status: pending
- percent_complete: 0
- eta: 2027-Q4
- blocking_dependencies: independent of Edge agent (pen testing runs from separate infrastructure)
- owner: SecurityAgent + PMAgent

## Phase 14 — ITSM WebRTC remote control OUT OF SCOPE (per myJian — autonomous remediation only, no human remote)
- status: complete (decision)
- owner: rjain

## MDM Phases (parallel to Phase 1 — vendor relationships run on calendar time per §11 q4)

### MDM-A — Apple MDM developer account
- status: in-progress (vendor application week-1 per §11 q4)
- eta: 2026-09 (3-month vendor process)
- owner: pm-agent + rjain

### MDM-B — Android Enterprise EMM partner
- status: in-progress
- eta: 2026-08 (2-3 month vendor process)
- owner: pm-agent + rjain

### MDM-C — Samsung Knox partner
- status: in-progress
- eta: 2026-08
- owner: pm-agent + rjain

### MDM-D — MdmIos plugin (depends on MDM-A)
- status: pending
- eta: 2026-10 (after Apple cert clears)
- owner: gsd pipeline

### MDM-E — MdmAndroid plugin (depends on MDM-B + MDM-C)
- status: pending
- eta: 2026-10
- owner: gsd pipeline

## Identity + Vault Stages (per §11 q1 — staged migration)

### Stage 1 — bearer-token + DPAPI (Edge Phase 1 ships with this)
- status: in-progress
- eta: 2026-09 (with Edge Phase 1)
- owner: gsd pipeline + SecurityAgent

### Stage 1.5 — Platform Identity Service + mTLS auto-enrollment
- status: pending
- eta: 2027-Q1
- owner: tech-web-shared team
- blocking_dependencies: Platform Identity Service shipped by tech-web-shared

### Stage 2 — Vault + JIT credential leases
- status: pending
- eta: 2027-Q3
- owner: tech-web-shared team
- blocking_dependencies: Vault shipped by tech-web-shared

## SelfGuard (per §10.13 — mandatory Phase 1 deliverable)
- status: pending
- eta: 2026-09 (with Edge Phase 1)
- owner: gsd pipeline + SecurityAgent

## Update log

- 2026-06-01: initial catalog from myJian §6 + §11 + §10 timelines
