# Security & Compliance Standards Reference
# Source: OWASP Cheat Sheets, Microsoft .NET Conventions, HIPAA/SOC2/PCI/GDPR

All generated code MUST comply with these rules. Violations are caught by
council review and final validation scans.

---

## .NET 8 Backend Security

### Authentication & Authorization
| ID | Rule |
|----|------|
| SEC-NET-01 | `[Authorize]` attribute on ALL controller classes |
| SEC-NET-02 | `[ValidateAntiForgeryToken]` on POST/PUT/DELETE actions |
| SEC-NET-03 | HttpOnly + Secure + SameSite=Strict on all cookies |
| SEC-NET-04 | Session timeout max 60 minutes, no sliding expiration |
| SEC-NET-05 | JWT: 15-min access token, 7-day refresh token, signed with RS256 |
| SEC-NET-06 | Login throttling: rate limit on auth endpoints |
| SEC-NET-07 | Identical error messages for bad username vs bad password |
| SEC-NET-08 | ASP.NET Core Identity for auth -- never custom implementations |
| SEC-NET-09 | Verify user access to the specific resource, not just existence |

### Input Validation
| ID | Rule |
|----|------|
| SEC-NET-10 | Whitelist validation: accept known-good, reject everything else |
| SEC-NET-11 | `SqlParameter` or Dapper `@params` for ALL database queries |
| SEC-NET-12 | `IPAddress.TryParse()` and `Uri.CheckHostName()` for IP/URL input |
| SEC-NET-13 | Never use `[AllowHtml]` without proven safe content |
| SEC-NET-14 | FluentValidation or DataAnnotations on all request DTOs |

### Data Protection & Cryptography
| ID | Rule |
|----|------|
| SEC-NET-15 | AES-256 for PII/PHI encryption at rest (Data Protection API) |
| SEC-NET-16 | TLS 1.2+ enforced in Program.cs -- never SSL |
| SEC-NET-17 | PBKDF2 or bcrypt for password hashing with unique salt |
| SEC-NET-18 | SHA-512 for non-password hashing |
| SEC-NET-19 | Never implement custom cryptography |
| SEC-NET-20 | Keys in Azure Key Vault or DPAPI -- never in code or config files |
| SEC-NET-21 | Unique nonce for every encryption operation |
| SEC-NET-22 | Connection strings in environment variables or secret manager |

### Security Headers
| ID | Rule |
|----|------|
| SEC-NET-23 | `X-Content-Type-Options: nosniff` |
| SEC-NET-24 | `X-Frame-Options: DENY` |
| SEC-NET-25 | `Content-Security-Policy: default-src 'self'` (strict, no inline scripts) |
| SEC-NET-26 | `Strict-Transport-Security: max-age=15768000` (HSTS, 6 months) |
| SEC-NET-27 | Remove server version headers |

### Error Handling & Logging
| ID | Rule |
|----|------|
| SEC-NET-28 | Catch specific exception types -- never bare `catch (Exception)` |
| SEC-NET-29 | `ILogger<T>` with structured logging (Serilog pattern) |
| SEC-NET-30 | Never log passwords, tokens, API keys, SSN, card numbers, PHI |
| SEC-NET-31 | Log context: userId, requestId, timestamp, operation |
| SEC-NET-32 | Production: no debug flags, no stack traces in responses |
| SEC-NET-33 | `async/await` for all I/O; `.ConfigureAwait(false)` in library code |

### Deserialization & SSRF
| ID | Rule |
|----|------|
| SEC-NET-34 | Never use `BinaryFormatter` (CVE risk) |
| SEC-NET-35 | Use `System.Text.Json` or `DataContractSerializer` |
| SEC-NET-36 | Validate integrity before deserializing untrusted data |
| SEC-NET-37 | Validate/whitelist URLs before server-side HTTP requests |
| SEC-NET-38 | Never auto-follow redirects to prevent internal resource access |

---

## SQL Server Security

### Access Control
| ID | Rule |
|----|------|
| SEC-SQL-01 | Stored procedures ONLY -- no inline SQL from application layer |
| SEC-SQL-02 | All parameters use `SqlDbType` with explicit size |
| SEC-SQL-03 | No dynamic SQL (`sp_executesql`) with unvalidated input |
| SEC-SQL-04 | Row-level security via WHERE clause on TenantId/OrgId |
| SEC-SQL-05 | Least privilege: app account has EXECUTE only, never db_owner |
| SEC-SQL-06 | Windows Integrated Auth when possible |

### Structure & Patterns
| ID | Rule |
|----|------|
| SEC-SQL-07 | `BEGIN TRY / END TRY / BEGIN CATCH / THROW / END CATCH` in all SPs |
| SEC-SQL-08 | Audit columns on every table: CreatedAt, CreatedBy, ModifiedAt, ModifiedBy |
| SEC-SQL-09 | Audit log INSERT on all INSERT/UPDATE/DELETE of sensitive data |
| SEC-SQL-10 | Explicit column lists in SELECT -- never `SELECT *` |
| SEC-SQL-11 | Strong typing for all parameters |
| SEC-SQL-12 | IF EXISTS checks for idempotent migrations |
| SEC-SQL-13 | GRANT EXECUTE permissions explicitly in each SP |
| SEC-SQL-14 | Proper indexing on foreign keys and lookup columns |
| SEC-SQL-15 | `SET NOCOUNT ON` at top of every SP |

### Encryption & Backup
| ID | Rule |
|----|------|
| SEC-SQL-16 | TDE for PHI/PII databases |
| SEC-SQL-17 | TLS 1.2+ for all database connections |
| SEC-SQL-18 | Encrypted backups stored separately with restricted access |

---

## React 18 Frontend Security

### XSS Prevention
| ID | Rule |
|----|------|
| SEC-FE-01 | No `dangerouslySetInnerHTML` without DOMPurify sanitization |
| SEC-FE-02 | No `eval()` or `new Function()` anywhere |
| SEC-FE-03 | JSX auto-escaping for all text content |
| SEC-FE-04 | DOMPurify for any user-generated HTML rendering |

### Data & Token Handling
| ID | Rule |
|----|------|
| SEC-FE-05 | HTTPS only for all API calls |
| SEC-FE-06 | Never store tokens, PII, passwords in `localStorage` |
| SEC-FE-07 | Use httpOnly + Secure + SameSite=Strict cookies for auth tokens |
| SEC-FE-08 | `Authorization: Bearer <token>` header -- never in URL parameters |
| SEC-FE-09 | Token refresh/rotation mechanism |

### Error Handling
| ID | Rule |
|----|------|
| SEC-FE-10 | Error boundaries at route level -- never expose stack traces |
| SEC-FE-11 | User-friendly error messages, no technical details |
| SEC-FE-12 | Remove `console.log` debug statements before production |
| SEC-FE-13 | Never log sensitive data to console |

### Dependencies
| ID | Rule |
|----|------|
| SEC-FE-14 | `npm audit` in CI/CD -- fix high/critical vulnerabilities |
| SEC-FE-15 | Exact version pinning in package.json |
| SEC-FE-16 | Subresource Integrity (SRI) hashes for CDN-hosted libraries |

---

## Compliance Patterns

### HIPAA
| ID | Rule |
|----|------|
| COMP-HIPAA-01 | PHI encrypted at rest (AES-256 / TDE) and in transit (TLS 1.2+) |
| COMP-HIPAA-02 | Audit trail for all PHI access: who, what, when, from where |
| COMP-HIPAA-03 | Role-based access control for PHI endpoints |
| COMP-HIPAA-04 | Minimum necessary: grant only permissions needed for role |
| COMP-HIPAA-05 | Data isolation by organization/practice |
| COMP-HIPAA-06 | 6+ year log retention |
| COMP-HIPAA-07 | Incident reporting within 24 hours |

### SOC 2
| ID | Rule |
|----|------|
| COMP-SOC2-01 | Change control: log all production changes with approval |
| COMP-SOC2-02 | Security monitoring: failed logins, privilege escalation |
| COMP-SOC2-03 | Incident response playbook documented |
| COMP-SOC2-04 | Backup tested regularly, RTO/RPO targets defined |
| COMP-SOC2-05 | Code review mandatory for all production changes |
| COMP-SOC2-06 | Vulnerability scan + patch within SLA (critical: 24-48 hrs) |

### PCI DSS
| ID | Rule |
|----|------|
| COMP-PCI-01 | Never store raw card numbers -- use payment processor tokens |
| COMP-PCI-02 | Card data encrypted in transit (TLS 1.2+) and at rest (AES-256) |
| COMP-PCI-03 | Isolate payment systems via firewall/VLAN |
| COMP-PCI-04 | Multi-factor auth for admin access |
| COMP-PCI-05 | Never log card numbers |
| COMP-PCI-06 | Quarterly external penetration testing |

### GDPR
| ID | Rule |
|----|------|
| COMP-GDPR-01 | APIs for data export, deletion, portability |
| COMP-GDPR-02 | Explicit consent tracking for data processing |
| COMP-GDPR-03 | Data minimization: collect only necessary data |
| COMP-GDPR-04 | Privacy by design: encrypt PII by default |
| COMP-GDPR-05 | Breach notification within 72 hours |
| COMP-GDPR-06 | Data retention/deletion schedules enforced |
