# GSD v6.2 — Hard-5% Domain Agents

**Version**: 6.2
**Effective**: 2026-06-01
**Status**: Live (compiles clean against TS 5 + @types/node; needs runtime smoke test)

## What changed in v6.2

V6.0/6.1 covered the SDLC + pipeline agents that drive *code* generation
(Requirements → Architecture → Figma → Blueprint → Contracts → Review →
Remediate → Gate → E2E → Deploy → Post-Deploy). V6.2 adds **four
non-code domain agents** that handle the parts of platform engineering
that traditionally require human hires:

| Agent | Replaces | Annual cost saved (vs. hires) |
|---|---|---|
| `security-agent` | Senior security engineer | ~$180–250K |
| `compliance-agent` | Compliance lead (1099, part-time) | ~$150–300K |
| `legal-agent` | Retained outside counsel time | ~$50–100K |
| `pm-agent` | Calendar-time program manager | ~$80–120K |

**Estimated steady-state human-of-record load on RJain (CEO):** <10 hours/week
signing what the AI agents drafted, vs. 4 full-time-equivalent hires.

## Origin: myJian §10.15 → §11 q3 decision

These agents were specified in response to the platform-coverage decision
for the Edge agent in tech-web-myjian, specifically:

- `docs/jian-remote-agent/platform-coverage-decision-2026-06-01.md` §10.15 — original recommendation to hire 4 humans
- §11 q3 (resolved 2026-06-01) — RJain elected AI agents instead
- §12 (in that same doc) — concretely maps each human role to its AI replacement
- §13 — full file manifest

## Agent contract pattern

All four follow the existing V6 BaseAgent contract:
- Vault note at `memory/agents/<name>.md` with frontmatter (model, tools, forbidden_tools, reads, writes, max_retries, timeout_seconds, escalate_after_retries) + Role + System prompt + Input/Output schema + Failure modes + Example
- TypeScript class at `src/agents/<name>.ts` extending `BaseAgent`, implementing `run(input)`, using `callLLM` + `extractJSON` for typed output
- I/O interfaces added to `src/harness/types.ts`
- AgentId added to the `AgentId` union in `types.ts`

## SecurityAgent

**Role**: Security-engineer-of-record. Read-only. BINDING signoff on PRs
touching security-critical paths.

**Security-critical paths** (signoff binding):
`/security`, `/auth`, `/crypto`, `/transport`, `/sandbox`, `/catalog`,
`/peer-repair`, `/self-guard`, plus filename patterns `*HSM*`,
`*Signing*`, `*KeyRotation*`, `*Attest*`, `*Credential*`, `*Token*`,
`*mTLS*`, `*CertPin*`.

**External tools**: Semgrep (security-audit + owasp-top-ten + secrets configs), CodeQL when available, `npm audit`, `dotnet list package --vulnerable`, license allow-list / deny-list (GPL-3 / AGPL-3 / LGPL-3 / SSPL-1 blocked).

**Output**: `SecurityReviewResult` with `signoffGranted`, `findings[]`, `threatModelDelta`, `scaResults`, `signatoryActions[]`, `evidence[]`.

**Defense-in-depth signoff**: the agent reports `signoffGranted` AND the harness independently re-computes it from findings — the more restrictive of the two wins. An LLM that lies about signoff cannot bypass.

**Routing**: signoff=false → RemediationAgent (with `suggestedRemediation` text). `signatoryActions` of category `{hsm, cert-rotation, vendor-application}` → PMAgent for calendar tracking.

## ComplianceAgent

**Role**: All-16-framework mapping (per myJian §11 q2). Reads framework
reference docs + Edge telemetry catalog. Generates evidence packs.

**Frameworks covered**: CMMC 2.0, FedRAMP, FISMA, DFARS, ITAR, CJIS, HIPAA, PCI-DSS, GLBA, SOX, SOC 2, NIST 800-53 Rev 5, ISO 27001, StateRAMP, NERC CIP, FERPA.

**Cross-framework consolidation**: many controls map to the same Edge evidence (MFA satisfies 5+ frameworks at once). Expressed via `control_mapping_groups` to avoid duplicating evaluation per-framework.

**Output**: `ComplianceArtifacts` with `framework_results[]`, `control_mapping_groups[]`, `gaps[]`, `continuous_attestation_drift[]`, `signatoryActions[]`, `evidence_pack_path`.

**Signing officer mapping**: per-framework defaults in `memory/knowledge/control-mapping-policy.md` (e.g., HIPAA → CISO/CEO, SOX → CFO, CMMC → Senior Accountable Official).

## LegalAgent

**Role**: Drafts MSA amendments / BAA updates / EULAs / privacy notices /
employment-monitoring notices / consent forms / breach-notification
templates / vendor-contract-summaries. UPL (Unauthorized Practice of
Law) boundary enforced.

**Document types**: `msa-amendment`, `baa-update`, `eula`, `privacy-notice`, `employment-monitoring-notice`, `consent-form`, `breach-notification`, `data-processing-addendum`, `vendor-contract-summary`, `state-law-summary`, `sub-processor-disclosure`, `nda`.

**Jurisdiction coverage**: US states (CA, IL, NY, CT, CO, WA, VA, TX, FL), US federal, EU, UK, Canada, Australia, `ALL-US-STATES` (warranty).

**UPL boundary** (binding): every output carries `requires_licensed_attorney_review`. Tactical advice / court filings / regulator-facing letters are REFUSED — the agent returns a `boundary_violation` entry instead. Statute citations are dated and verifiable.

**Source-of-truth templates**: reads from `D:/VSCode/tech-legal/templates/`.

**Output**: `LegalArtifact` with `draft_path`, `citations[]`, `jurisdiction_specific_sections[]`, `signatoryActions[]`, `boundary_violations[]`, `draft_body`, `plain_english_summary`.

## PMAgent

**Role**: Program manager for calendar-time work. Tracks vendor
relationships, renewal calendar, milestone progress. Consolidates
upstream `signatoryActions` from Security/Compliance/Legal into a
weekly RJain action list.

**Inputs**: `report_type` (`weekly-status` | `vendor-only` | `milestone-only` | `rjain-action-items` | `full`), optional window.

**Output**: `PMStatusReport` with `status_report_markdown` (full markdown report ready for posting to Teams), `rjain_action_items[]`, `vendor_relationships[]`, `urgent_renewals[]`, `milestone_status[]`, `blockers[]`, `artifacts_awaiting_signature[]`.

**Cross-agent ingest**: reads the last 7 days of `memory/decisions/*.json` files looking for `signatoryActions` arrays from the other 3 agents. Folds them into `rjain_action_items` if not already present.

## Knowledge files added

**Security**:
- `memory/knowledge/security-policy.md` — severities, license deny-list, secret patterns, constant-time-compare requirements, pen-test scope constraints, HSM ceremony procedure
- `memory/knowledge/security-critical-paths.md` — binding signoff paths + patterns SecurityAgent checks for on those paths
- `memory/knowledge/threat-model.md` — STRIDE per component + 5 attack surfaces + which PR types trigger mandatory threat-model-delta

**Compliance**:
- `memory/knowledge/edge-telemetry-catalog.md` — canonical event catalog for all Edge plugins (WindowsEndpoint, LinuxEndpoint, SqlServer, Nakivo, Veeam, vCenter, SnmpPoller, UserActivity, MdmIos, MdmAndroid, HostRemediator, LanIpActuator, PatchManager, SelfGuard) + cross-plugin correlation rules
- `memory/knowledge/control-mapping-policy.md` — N-to-1 mapping principles, per-framework signing-officer defaults, evidence retention table
- `memory/knowledge/frameworks/*.md` — 16 framework reference stubs

**Legal**:
- `memory/knowledge/jurisdiction-matrix.md` — per-jurisdiction statute citations (employee monitoring, healthcare, card data, children's data, breach notification) with effective dates
- `memory/knowledge/upl-boundaries.md` — what LegalAgent must refuse vs. what's safe to draft
- `memory/knowledge/legal-policy.md` — document-type → default attorney-review-level table; default Technijian signatory per document

**PM**:
- `memory/knowledge/vendor-relationships.md` — per-vendor status registry (Apple MDM, Android EMM, Samsung Knox, DigiCert HSM, AV vendors, ME-EC, future FedRAMP/StateRAMP)
- `memory/knowledge/renewal-calendar.md` — quarterly drills + cert rotations + audit cycles
- `memory/knowledge/milestone-catalog.md` — 14-phase platform-coverage rollout + Identity/Vault stages + MDM phases + SelfGuard
- `memory/knowledge/calendar-time-tracks.md` — 11 parallel tracks running on calendar time

## Type system changes

`src/harness/types.ts` extended:

```typescript
// Added AgentId union values:
| 'security-agent' | 'compliance-agent' | 'legal-agent' | 'pm-agent';

// New shared type:
interface SignatoryAction {
  category: 'hsm' | 'cert-rotation' | 'compliance-attestation' | 'vendor-application' | 'incident-response' | 'legal-execution';
  description: string;
  signatory: 'CEO' | 'CISO' | 'GC' | 'named-officer';
  dueDate?: string;
  blocking: boolean;
  artifactPath?: string;
}

// Per-agent I/O interfaces:
SecurityAgentInput, SecurityFinding, ThreatModelDelta, SecurityReviewResult
ComplianceAgentInput, ComplianceFramework, FrameworkResult, ControlMappingGroup, ComplianceGap, AttestationDriftItem, ComplianceArtifacts
LegalAgentInput, LegalDocumentType, LegalJurisdiction, LegalCitation, JurisdictionSection, BoundaryViolation, LegalArtifact
PMAgentInput, PMReportType, PMActionItem, VendorStatus, RenewalItem, MilestoneStatus, PMBlocker, SignatoryItem, PMStatusReport
```

## Type-check status

Verified 2026-06-01 against TypeScript 5 + `@types/node`:

```
src/agents/security-agent.ts:      0 errors
src/agents/compliance-agent.ts:    0 errors
src/agents/legal-agent.ts:         0 errors
src/agents/pm-agent.ts:            0 errors
src/harness/types.ts:              0 errors
```

(8 unrelated errors remain in the broader codebase — all are missing
3rd-party deps in isolated test rigs: `@anthropic-ai/sdk`, `uuid`,
`better-sqlite3`, `proper-lockfile`. These are present in the real
install via `npm install`.)

## How to invoke (once registered in the orchestrator)

```bash
# Security review on a PR
npx ts-node src/index.ts run security-agent --changed-files <file1,file2,...> --critical-paths-config memory/knowledge/security-critical-paths.md

# Compliance evidence pack for a window
npx ts-node src/index.ts run compliance-agent --frameworks HIPAA,SOC2 --client AAVA --start 2026-01-01 --end 2026-06-30

# Legal draft for a UserActivity rollout
npx ts-node src/index.ts run legal-agent --document-type msa-amendment --triggering-capability "Edge UserActivity plugin" --jurisdictions US-CA,US-IL

# PM weekly status report
npx ts-node src/index.ts run pm-agent --report-type weekly-status
```

## Routing into the existing pipeline (TODO — v6.2.1)

These agents are present but not yet wired into the main task graph in
`memory/architecture/agent-system-design.md`. The recommended wiring:

1. **Pre-Review gate**: SecurityAgent runs in parallel with CodeReviewAgent. If `signoffGranted=false`, QualityGate fails regardless of test/coverage.
2. **Post-Deploy** (or scheduled): ComplianceAgent runs per-window per-client to refresh evidence packs.
3. **Scheduled (weekly)**: PMAgent emits the status report.
4. **On-demand**: LegalAgent invoked from Operator chat when a triggering capability is detected.

A future v6.2.1 release will add these routing entries + the
`agent-system-design.md` graph update.

## File manifest

Added in v6.2:
- 4 vault notes: `memory/agents/{security,compliance,legal,pm}-agent.md`
- 4 TypeScript classes: `src/agents/{security,compliance,legal,pm}-agent.ts`
- 1 type system extension: `src/harness/types.ts` (additive)
- 12 knowledge files in `memory/knowledge/`
- 16 framework reference stubs in `memory/knowledge/frameworks/`
- Registry updates in `AGENTS.md` + `CLAUDE.md`

## Update log

- 2026-06-01: v6.2 ship. SDLC + pipeline agents unchanged from v6.1.
