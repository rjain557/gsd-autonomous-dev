# Security Policy — GSD Pipeline

## Severity definitions

- **critical**: ships to prod = company-ending. Examples: hardcoded secret in repo, TLS verify=false in transport, hands-off HSM bypass, SQL injection in any catalog/auth path.
- **high**: ships to prod = major incident. Examples: timing side-channel in cred compare, missing audit log on actuator op, deserialization of untrusted input.
- **medium**: should fix before next release. Examples: missing rate limit on non-sensitive endpoint, stale dependency one minor version behind a fix.
- **low**: log as evidence, fix in normal cadence. Examples: missing CSP header on internal-only page, deprecated API usage.

## SCA license deny-list

Any of these licenses in transitive dependencies → BLOCK:
- GPL-3.0, GPL-2.0
- AGPL-3.0
- LGPL-3.0 (LGPL-2.1 reviewed case-by-case)
- SSPL-1.0
- Commons Clause variants
- BSL (Business Source License)
- Any unrecognized non-OSI license string

Allow-list (no review needed):
- MIT, Apache-2.0, BSD-2-Clause, BSD-3-Clause, ISC, MPL-2.0, CC0-1.0, Unlicense, 0BSD

## SCA review pattern

When SecurityAgent detects a new dependency:
1. Check license against allow-list → deny-list → unrecognized
2. If allow-list: pass
3. If deny-list: BLOCK + remediation = "find alternative library"
4. If unrecognized: route to LegalAgent for license review

## OWASP coverage

Semgrep configs that MUST be present in every CI run:
- `p/security-audit`
- `p/owasp-top-ten` (current is 2025)
- `p/secrets`
- `p/javascript` + `p/typescript` + `p/csharp` (per language in project)

## Secret patterns SecurityAgent looks for in source

```
password\s*=\s*['"][^'"]+['"]
secret\s*=\s*['"][^'"]+['"]
api[_-]?key\s*=\s*['"][^'"]+['"]
token\s*=\s*['"][^'"]+['"]
sk-[a-zA-Z0-9_]{20,}
ghp_[a-zA-Z0-9]{36}
xoxp-[a-zA-Z0-9-]+
-----BEGIN (RSA |EC |DSA |OPENSSH |)PRIVATE KEY-----
```

## Constant-time-compare-required APIs

These calls MUST use constant-time comparison:
- credential validation
- bearer-token equality
- HMAC verification
- CSRF token check

C#: `CryptographicOperations.FixedTimeEquals(byte[], byte[])`
TypeScript/Node: `crypto.timingSafeEqual(Buffer, Buffer)`

== or `string.Equals` for these triggers HIGH severity finding.

## Pen testing

Pen testing must NOT run from client endpoint agents — only from Technijian-owned
AWS/Azure VMs at various locations OR from the India office as a remote pen-test source.
This is a hard scope constraint from myJian §4.3.

## Code-signing ceremony

Annual + on-rotation procedures:
1. 2-of-3 multi-party (signing officer + witness officer + audit officer)
2. HSM offline mode; physical separation
3. Transparency log entry: timestamp, witnesses, hash of signed artifact, ceremony ID
4. Per-client salted signing key derivation (so a compromised single signature can't impersonate multiple clients)

PMAgent reminds SecurityAgent + RJain 60 days before scheduled rotation.

## Update log

- 2026-06-01: initial policy aligned with myJian platform-coverage decision §10.5, §10.7, §10.11
