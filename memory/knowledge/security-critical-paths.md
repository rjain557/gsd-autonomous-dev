# Security-Critical Paths

Paths in this list trigger BINDING security-agent signoff. PRs touching these
files cannot pass QualityGate without an explicit `signoffGranted: true` from
SecurityAgent. Block-on-critical-or-high on these paths.

For paths NOT in this list, SecurityAgent runs advisory only (warnings logged,
doesn't block the gate).

## Path patterns

```
/security/*
/auth/*
/crypto/*
/transport/*
/sandbox/*
/catalog/*
/peer-repair/*
/self-guard/*
*HSM*
*Signing*
*KeyRotation*
*Attest*
*Credential*
*Token*
*mTLS*
*CertPin*
```

## Pattern semantics

- `prefix/*` — any file whose path contains the prefix
- `*SUBSTRING*` — case-insensitive substring match in filename
- Both styles can coexist

## What "security-critical" means here

A finding on a critical path is BLOCKING if severity ≥ HIGH. The same finding
on a non-critical path becomes advisory. The reason: errors in the
authentication/transport/sandbox surface are catastrophic and not easily
caught post-deploy; errors in business logic are usually visible in
production and recoverable.

## Patterns SecurityAgent looks for on these paths

| Pattern | Severity | Note |
|---|---|---|
| `TLS verify=false` or `rejectUnauthorized: false` | CRITICAL | Even behind a dev/staging gate |
| Secret-in-log (`password=`, `token=`, `sk-…`, `BEGIN PRIVATE KEY`) | CRITICAL | Includes log statements |
| Path traversal in any file-handling | CRITICAL | Even when reading "trusted" config |
| SQL injection (string-concat queries) | CRITICAL | Including in stored-proc generation |
| HSM-bypass code path (test-only flag that could ship) | CRITICAL | Removed entirely, no env-gating |
| Missing audit-log on sensitive operation | MEDIUM | Adds to finding pile but doesn't block alone |
| Race condition in cred compare | CRITICAL | Use constant-time compare |
| Off-by-one in allow-list enforcer | CRITICAL | Catalog operations especially |
| Timing side-channel (== for cred) | HIGH | Use crypto.timingSafeEqual |
| Missing rate limit on sensitive endpoint | HIGH | Brute-force, enumeration |
| Insufficient input validation on actuator input | HIGH | Peer-repair, catalog ops |
| Untrusted deserialization without allow-list | HIGH | Pickle, BinaryFormatter, eval |

## When to extend this list

- New plugin family that handles credentials, network handshake, or process spawn
- New trust boundary (e.g., service exposed to peer network)
- New external dependency that handles cryptographic material
- Migration where a previously-internal path becomes exposed

Update via PR + SecurityAgent reviews its own update.

## Update history

- 2026-06-01: initial population aligned with myJian platform-coverage decision
