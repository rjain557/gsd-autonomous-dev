---
name: sql-expert
description:
  MS SQL Server schema design, T-SQL authoring, and query crafting. Use when
  asked to "design a schema", "write a stored procedure", "normalize this table",
  "write a CTE", "use window functions", or "model this relationship". Covers
  normalization, CTEs, window functions, temporal tables, and multi-dialect
  awareness.
metadata:
  source: mcpmarket.com/tools/skills/sql-expert
  dialect: MS SQL Server (T-SQL) primary; PostgreSQL / MySQL awareness
  version: '1.0.0'
---

# SQL Expert — MS SQL Server

Advanced T-SQL authoring and schema design for SQL Server. This project uses
**stored procedures only** — no inline SQL from the application layer.

## When to Activate

- "Design a table / schema for..."
- "Write a stored procedure for..."
- "Normalize this data model"
- "Write a CTE / recursive query"
- "Use window functions to..."
- "How do I model this relationship?"
- "Generate a migration script"

## Schema Design Principles

### Naming Conventions (this project)
| Object | Convention | Example |
|---|---|---|
| Tables | PascalCase, plural | `dbo.Orders`, `dbo.NavigationModules` |
| Columns | PascalCase | `CreatedAt`, `TenantId`, `IsActive` |
| PKs | `Id` (INT IDENTITY or NVARCHAR GUID) | `Id INT IDENTITY(1,1)` |
| FKs | `{TableName}Id` | `TenantId`, `UserId` |
| Indexes | `IX_{Table}_{Columns}` | `IX_Orders_TenantId_Status` |
| SPs | `usp_{Entity}_{Action}` | `usp_Order_Create`, `usp_Order_ListByTenant` |
| Constraints | `UQ_`, `CK_`, `FK_`, `DF_` prefixes | `UQ_Users_Email` |

### Mandatory Audit Columns
Every table must have:
```sql
CreatedAt   DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
CreatedBy   NVARCHAR(100) NOT NULL,
UpdatedAt   DATETIME2 NULL,
UpdatedBy   NVARCHAR(100) NULL,
IsDeleted   BIT NOT NULL DEFAULT 0  -- soft delete pattern
```

### Multi-Tenant Isolation
All data tables include `TenantId NVARCHAR(50) NOT NULL` and all SPs filter by it:
```sql
-- Every SELECT on tenant-scoped data
WHERE TenantId = @TenantId AND IsDeleted = 0
```

## Stored Procedure Template

```sql
CREATE OR ALTER PROCEDURE dbo.usp_{Entity}_{Action}
    @Param1 NVARCHAR(100),
    @TenantId NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        -- Validate inputs
        IF @TenantId IS NULL OR @Param1 IS NULL
            THROW 50001, 'Required parameters cannot be null.', 1;

        -- Business logic here
        SELECT
            col1,
            col2
        FROM dbo.{Table}
        WHERE TenantId = @TenantId
          AND IsDeleted = 0
        ORDER BY CreatedAt DESC;

    END TRY
    BEGIN CATCH
        THROW;  -- Re-raise to caller; application layer logs
    END CATCH
END;
GO

GRANT EXECUTE ON dbo.usp_{Entity}_{Action} TO [AppRole];
GO
```

## CTEs and Window Functions

### Recursive CTE (hierarchy)
```sql
WITH HierarchyCTE AS (
    -- Anchor: root nodes
    SELECT Id, ParentId, Name, 0 AS Depth
    FROM dbo.Categories
    WHERE ParentId IS NULL

    UNION ALL

    -- Recursive: children
    SELECT c.Id, c.ParentId, c.Name, h.Depth + 1
    FROM dbo.Categories c
    INNER JOIN HierarchyCTE h ON h.Id = c.ParentId
)
SELECT * FROM HierarchyCTE ORDER BY Depth, Name;
```

### Window Functions
```sql
-- Running total, rank, lag/lead
SELECT
    OrderId,
    CustomerId,
    TotalAmount,
    SUM(TotalAmount) OVER (PARTITION BY CustomerId ORDER BY CreatedAt
                           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS RunningTotal,
    ROW_NUMBER() OVER (PARTITION BY CustomerId ORDER BY TotalAmount DESC) AS RankBySpend,
    LAG(TotalAmount, 1, 0) OVER (PARTITION BY CustomerId ORDER BY CreatedAt) AS PrevOrderAmount
FROM dbo.Orders
WHERE TenantId = @TenantId AND IsDeleted = 0;
```

### MERGE (upsert pattern)
```sql
MERGE dbo.NavigationModules AS target
USING (VALUES (@ModuleKey, @Label, @Href, @SortOrder))
    AS source (ModuleKey, Label, Href, SortOrder)
ON target.ModuleKey = source.ModuleKey
WHEN MATCHED THEN
    UPDATE SET Label = source.Label, Href = source.Href, SortOrder = source.SortOrder,
               UpdatedAt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN
    INSERT (ModuleKey, Label, Href, SortOrder, CreatedAt)
    VALUES (source.ModuleKey, source.Label, source.Href, source.SortOrder, SYSUTCDATETIME());
```

## Normalization Quick Reference

| Form | Rule | Check |
|---|---|---|
| 1NF | Atomic values, no repeating groups | No comma-separated lists in columns |
| 2NF | No partial dependency on composite PK | Every non-key column depends on full PK |
| 3NF | No transitive dependency | No column depends on another non-key column |
| BCNF | Every determinant is a candidate key | Rare; only fix if proven anomaly exists |

## Migration Script Pattern

```sql
-- Always idempotent (safe to re-run)
IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES
               WHERE TABLE_SCHEMA = 'dbo' AND TABLE_NAME = 'NewTable')
BEGIN
    CREATE TABLE dbo.NewTable (
        Id          INT IDENTITY(1,1) PRIMARY KEY,
        TenantId    NVARCHAR(50)  NOT NULL,
        Name        NVARCHAR(200) NOT NULL,
        IsActive    BIT           NOT NULL DEFAULT 1,
        CreatedAt   DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
        CreatedBy   NVARCHAR(100) NOT NULL
    );

    CREATE NONCLUSTERED INDEX IX_NewTable_TenantId
        ON dbo.NewTable (TenantId)
        INCLUDE (Name, IsActive);
END;
GO
```

## JSON in SQL Server (2016+)

```sql
-- Store JSON, query with JSON_VALUE / OPENJSON
SELECT Id, JSON_VALUE(ConfigJSON, '$.timeout') AS Timeout
FROM dbo.Connectors
WHERE TenantId = @TenantId;

-- Shred JSON array to rows
SELECT value AS Tag
FROM dbo.Assets
CROSS APPLY OPENJSON(TagsJSON) WITH (value NVARCHAR(100) '$');
```
