---
type: knowledge
description: Deploy configuration for alpha environment
---

# Deploy Configuration

## Alpha Environment

| Setting | Value |
|---|---|
| Server | 10.100.253.131 |
| SQL Server | 10.100.253.13 |
| Deploy Path | X:\deploy\alpha |
| IIS Site | Default Web Site/alpha |
| Health Endpoint | /api/health |
| Frontend Port | 443 (IIS) |
| Backend Port | 5000 (Kestrel behind IIS) |

## Deploy Sequence

1. `git tag deploy-alpha-{date}` — Create deploy tag
2. `dotnet publish -c Release -o ./publish` — Build release artifacts
3. `npm run build` — Build frontend
4. Copy `./publish/*` to deploy path via SMB
5. Copy frontend `dist/*` to IIS wwwroot
6. `iisreset /noforce` — Recycle app pool (NOT full reset)
7. Health check: `GET /api/health` → expect 200
8. Smoke check: `GET /api/auth/me` with test token → expect 200

## Pre-Deploy Checklist

- [ ] GateResult.passed === true
- [ ] Connection string configured in appsettings
- [ ] Azure AD config matches alpha tenant
- [ ] IIS kernel cache disabled for HTML (web.config URL rewrite)
- [ ] No pending database migrations

## Post-Deploy Verification

- Health endpoint returns 200
- Login flow completes with test user
- Dashboard loads with real data (not mock)
- No 500 errors in IIS logs for 5 minutes
