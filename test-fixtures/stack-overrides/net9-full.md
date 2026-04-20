# Stack Overrides — Technijian ITSM

Sample complete override matching the Technijian Platform standard (net9.0 per tech-web-shared ADR-0004).

## Backend

| Field | Value | Notes |
|-------|-------|-------|
| Backend framework | net9.0 | ADR-0004 mandate |
| Backend SDK | .NET 10 SDK | SDK can build net9.0 targets |
| Solution file format | slnx | XML-based solution format |
| Data access | Dapper + stored procedures | SP-only pattern |
| Database | SQL Server | 2019+ |

## Frontend

| Field | Value | Notes |
|-------|-------|-------|
| Frontend framework | React 18 | |
| Frontend UI library | Fluent UI v9 | Azure portal parity |
| Frontend build tool | Vite | |

## Mobile

| Field | Value |
|-------|-------|
| Mobile framework | React Native |
| Mobile toolchain | Expo managed workflow |

## Agents

| Field | Value |
|-------|-------|
| Remote agent language | Go |

## Compliance

| Field | Value |
|-------|-------|
| Compliance | SOC 2, HIPAA, PCI, GDPR |
