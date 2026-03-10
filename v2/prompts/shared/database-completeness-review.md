# Database Completeness Standards

## Required Chain
```
API Endpoint -> Controller Method -> Repository/Service -> Stored Procedure
    -> Functions/Views (if complex) -> Tables -> Seed Data
```

## Enhanced Blueprint Tier Structure
| Tier | Name | Contents |
|------|------|----------|
| 1 | Database Foundation | Tables, migrations, indexes, constraints |
| 1.5 | Database Functions & Views | Views for complex reads, scalar/table-valued functions |
| 2 | Stored Procedures | All CRUD + business logic SPs |
| 2.5 | Seed Data | INSERT scripts per table group, FK-consistent, matching Figma mock data |
| 3 | API Layer | .NET 8 controllers, services, repositories, DTOs, validators |
| 4 | Frontend Components | React 18 components matching Figma exactly |
| 5 | Integration & Config | Routing, auth flows, middleware, DI, config files |
| 6 | Compliance & Polish | Audit logging, encryption, RBAC, error boundaries, accessibility |

## Verification Rules
1. Every endpoint in `_analysis/06-api-contracts.md` MUST have a stored procedure
2. Every row in `_analysis/11-api-to-sp-map.md` must be complete (no empty cells)
3. Every SP MUST reference tables that exist in migrations
4. Complex queries (3+ table JOINs) SHOULD use a view
5. Every table MUST have seed data matching Figma mock data exactly
6. Seed data FK references MUST point to existing parent records
7. No orphaned SPs or tables

## Cross-Reference Sources
- `_analysis/06-api-contracts.md` -- API endpoints
- `_analysis/11-api-to-sp-map.md` -- End-to-end chain map
- `_analysis/08-mock-data-catalog.md` -- Mock data values for seed scripts
- `_stubs/database/01-tables.sql`, `02-stored-procedures.sql`, `03-seed-data.sql`
