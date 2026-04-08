# Phase B — Technical Design Specification

## REQ-003: JWT Refresh Token Flow
The system must implement JWT access + refresh token pairs.
- Access tokens expire after 15 minutes
- Refresh tokens expire after 7 days
- Refresh endpoint: POST /api/auth/refresh

## REQ-005: Audit Logging
All mutation operations (create, update, delete) must produce audit records with:
- UserId, TenantId, Action, EntityType, EntityId, Timestamp, OldValue, NewValue
