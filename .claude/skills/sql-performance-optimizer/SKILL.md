---
name: sql-performance-optimizer
description:
  MS SQL Server performance analysis and optimization. Use when asked to
  "optimize this query", "why is this slow", "analyze execution plan",
  "add indexes", "fix N+1", or "tune this stored procedure". Covers execution
  plans, index strategies, statistics, query rewrites, and bottleneck resolution.
metadata:
  source: mcpmarket.com/tools/skills/sql-performance-optimizer-2
  dialect: MS SQL Server (T-SQL)
  version: '1.0.0'
---

# SQL Server Performance Optimizer

Systematic performance analysis for Microsoft SQL Server. Always diagnose
before prescribing — read the execution plan before suggesting an index.

## When to Activate

- "This query is slow" / "taking too long"
- "Analyze this execution plan"
- "What indexes do I need?"
- "Fix N+1 queries"
- "Optimize this stored procedure"
- "Why is CPU/IO high on this query?"

## Workflow

1. **Read the query** — understand what it does logically
2. **Check the execution plan** — identify costly operators (Table Scan, Hash Join, Sort, RID Lookup)
3. **Identify the bottleneck** — IO-bound vs CPU-bound vs blocking vs parameter sniffing
4. **Prescribe the fix** — rewrite, index, statistics update, or plan guide
5. **Validate** — estimate improvement via estimated subtree cost reduction

## Execution Plan Operators to Watch

| Operator | Cost Signal | Common Fix |
|---|---|---|
| Table Scan / Clustered Index Scan | Missing covering index | Add filtered/covering index |
| Key Lookup / RID Lookup | Index missing INCLUDE columns | Add INCLUDEd columns to index |
| Hash Match (Join) | Missing join index, bad stats | Index on join columns, UPDATE STATISTICS |
| Sort | No supporting index for ORDER BY | Index with matching key order |
| Nested Loops (outer) | N+1 pattern | Batch with `IN` / `JOIN` |
| Spool | Repeated sub-expression | CTE or temp table |
| Parallelism (excessive) | MAXDOP issue | `OPTION (MAXDOP N)` hint |

## Index Design Rules

```sql
-- Covering index pattern: equality first, range second, INCLUDE non-key columns
CREATE NONCLUSTERED INDEX IX_Orders_TenantId_Status_CreatedAt
    ON dbo.Orders (TenantId, Status)
    INCLUDE (CustomerId, TotalAmount, CreatedAt)
    WHERE IsDeleted = 0;  -- filtered index for soft-delete pattern

-- Never index low-cardinality columns alone (e.g., IsActive BIT)
-- Never create duplicate indexes (check sys.indexes first)
```

## Query Rewrite Patterns

### Replace correlated subquery with JOIN
```sql
-- Slow: correlated subquery runs once per row
SELECT o.Id, (SELECT COUNT(*) FROM dbo.OrderItems oi WHERE oi.OrderId = o.Id) AS ItemCount
FROM dbo.Orders o;

-- Fast: aggregated JOIN
SELECT o.Id, ISNULL(agg.ItemCount, 0) AS ItemCount
FROM dbo.Orders o
LEFT JOIN (SELECT OrderId, COUNT(*) AS ItemCount FROM dbo.OrderItems GROUP BY OrderId) agg
    ON agg.OrderId = o.Id;
```

### Use EXISTS instead of COUNT for existence checks
```sql
-- Slow
IF (SELECT COUNT(*) FROM dbo.Orders WHERE CustomerId = @id) > 0

-- Fast
IF EXISTS (SELECT 1 FROM dbo.Orders WHERE CustomerId = @id)
```

### Parameter sniffing fix
```sql
-- Symptom: fast first run, slow on reuse (or vice versa)
CREATE PROCEDURE dbo.usp_GetOrdersByDate @StartDate DATE, @EndDate DATE
AS BEGIN
    -- Fix: local variable breaks sniffing; RECOMPILE is nuclear option
    DECLARE @s DATE = @StartDate, @e DATE = @EndDate;
    SELECT * FROM dbo.Orders WHERE CreatedAt BETWEEN @s AND @e;
END;
```

## Statistics

```sql
-- Check when stats were last updated
SELECT name, stats_date(object_id, stats_id) AS last_updated
FROM sys.stats WHERE object_id = OBJECT_ID('dbo.Orders');

-- Update stats (non-blocking with FULLSCAN)
UPDATE STATISTICS dbo.Orders WITH FULLSCAN;

-- Auto-update stats threshold: default 20% row change (bad for large tables)
-- Enable trace flag 2371 or use ASYNC_STATS_UPDATE
```

## Stored Procedure Performance Checklist

- [ ] `SET NOCOUNT ON` at top
- [ ] All parameters typed with explicit length (`NVARCHAR(100)` not `NVARCHAR(MAX)`)
- [ ] No implicit conversions (parameter type must match column type exactly)
- [ ] No `SELECT *` — explicit column list only
- [ ] Temp tables preferred over table variables for >1000 rows (stats available)
- [ ] `WITH (NOLOCK)` only on reporting queries where dirty reads are acceptable
- [ ] `TRY/CATCH` with `THROW` for error propagation
- [ ] Test with `SET STATISTICS IO ON; SET STATISTICS TIME ON;`

## Blocking and Deadlock Analysis

```sql
-- Find blocking chains
SELECT blocking_session_id, session_id, wait_type, wait_time, status, sql_handle
FROM sys.dm_exec_requests
WHERE blocking_session_id > 0;

-- Common fix: keep transactions short, acquire locks in consistent order
-- For read-heavy reporting: READ COMMITTED SNAPSHOT ISOLATION (RCSI)
ALTER DATABASE [YourDb] SET READ_COMMITTED_SNAPSHOT ON;
```
