# Threat Model — Edge Agent + GSD-Generated Code

Living document. Updated by SecurityAgent's threat-model-delta pass. Format:
STRIDE per component + per-trust-boundary attack surface enumeration.

## Components in scope

| Component | Trust level | Owner |
|---|---|---|
| Edge agent core (myJian/Edge) | TRUSTED — runs as SYSTEM/root on client endpoints | SecurityAgent |
| Edge plugins (Telemetry, Actuator, UserInteraction) | TRUSTED-IF-SIGNED | SecurityAgent |
| Edge → Platform transport (mTLS) | TRUSTED post-handshake | SecurityAgent |
| Peer-repair channel (agent-to-agent within same SiteId) | LIMITED-TRUST (rate-limited, audit-logged) | SecurityAgent |
| HSM-stored release signing key | HIGHEST-TRUST (2-of-3 multi-party ceremony) | SecurityAgent + RJain |
| Platform Identity Service (Stage 1.5) | TRUSTED | SecurityAgent |
| Vault JIT credential lease (Stage 2) | TRUSTED | SecurityAgent |
| Per-client signed manifest | TRUSTED (Ed25519 signed by HSM) | SecurityAgent |
| Multi-DC fallback URL list | TRUSTED-IF-SIGNATURE-VERIFIES | SecurityAgent |

## Trust boundaries

1. **Platform ↔ Edge agent** — mTLS terminated; payload format strictly typed
2. **Edge agent core ↔ Plugin** — IPC over named pipe; plugin runs in sandboxed process (Stage 2+)
3. **Edge ↔ Peer Edge (peer-repair)** — platform-mediated; ratelimited; signed intent
4. **HSM ↔ Build pipeline** — multi-party 2-of-3 ceremony; transparency log
5. **DR cutover IRV → Vegas** — DNS update + agent reconnection; no live data plane

## STRIDE per component (Edge agent core)

| Threat | Mitigation | Owner |
|---|---|---|
| **S**poofing of Platform → Edge | mTLS w/ certificate pinning; signed URL list; DNS pinning in SelfGuard | SecurityAgent |
| **S**poofing of Edge → Platform | Client cert + JIT enrollment token (Stage 1) → mTLS (Stage 1.5) | SecurityAgent |
| **T**ampering of Edge binary | Code-signing verification on startup; SelfGuard hash chain on Edge files | SecurityAgent |
| **R**epudiation of Edge actions | Tamper-evident hash-chained local log; replicated to platform on every heartbeat | SecurityAgent |
| **I**nfo disclosure (creds, telemetry) | DPAPI cred storage (Stage 1); JIT Vault leases (Stage 2); TLS in transit | SecurityAgent |
| **D**oS (Edge swamps platform / vice versa) | Rate-limited heartbeat; backoff with jitter; ingest service per-client quota | SecurityAgent |
| **E**levation of privilege (plugin escapes core) | Process isolation (Stage 1); seccomp/AppContainer (Stage 2); WASM sandbox (Stage 3) | SecurityAgent |

## Attack surfaces

### Attack surface 1: Peer-repair lateral movement
The peer-repair feature lets one agent uninstall/reinstall another agent in the
same SiteId. Without hardening, this is a lateral-movement primitive.

**Mitigations** (all required, defense in depth):
- Platform decides when repair is warranted (3+ missed heartbeats, no maintenance window)
- Peer signs intent + platform countersigns before issuing JIT lease
- JIT lease scoped to: specific installer SHA-256 + specific target host + 1h TTL
- Installer SHA MUST match per-client signed manifest
- Rate-limited: 1 peer-repair/peer/hr, 5/site/day max
- Audit log entries replicated in real-time to platform; on-call ticket auto-opens

### Attack surface 2: Plugin sandbox escape
Plugins run with capabilities to read files, monitor processes, optionally write
config. A buggy or malicious plugin escaping the sandbox = endpoint compromise.

**Mitigations** (staged):
- Stage 1: child process per plugin; if plugin crashes, only that plugin dies
- Stage 2: capability-dropping (Linux seccomp, Windows AppContainer, macOS sandbox-exec)
- Stage 3: WASM sandbox for highest-risk actuator plugins

### Attack surface 3: Catalog operation abuse
The L1 remediation catalog is the allowed-set of automated actions Edge can
take. If catalog enforcement has a bug (off-by-one, type-confusion), arbitrary
actions become reachable.

**Mitigations**:
- Catalog operations are explicit allow-list, never a deny-list
- Catalog enforcer is on the security-critical paths list (binding SecurityAgent signoff)
- Dry-run mode for any new operation; perf-impact + risk-band validation
- Catalog change requires SecurityAgent signoff + RJain approval

### Attack surface 4: Supply-chain (npm/NuGet/PyPI deps)
**Mitigations**:
- SCA scan on every PR (npm audit + dotnet vulnerable + license deny-list)
- Lockfiles required, lockfile changes get extra SecurityAgent attention
- Vendored dependencies for highest-risk libraries (crypto, transport)

### Attack surface 5: HSM root-of-trust ceremony
**Mitigations**:
- 2-of-3 multi-party (separate roles: signing officer, witness officer, audit officer)
- Transparency log: every signing operation logged immutably
- Per-client pinning: each client's installer signed with HSM key + client-specific salt
- Annual cert rotation; signing key rotation per agreed schedule

## STRIDE deltas requiring threat-model refresh

The following PR types trigger a mandatory threat-model-delta entry from SecurityAgent:

- New trust boundary (e.g., service newly exposed to peer network)
- New external dependency that handles cryptographic material
- New IPC channel between Edge core and external
- New network listener
- New credential storage path
- New plugin capability that previously didn't exist
- HSM/signing key lifecycle change
- DR architecture change

## Update log

- 2026-06-01: initial population from myJian §4.4 (Security model) + §4.5 (Resilience model) + §4.6 (DR architecture)
