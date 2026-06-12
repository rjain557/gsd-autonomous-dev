/* ============================================================================
   GSD Dev Memory — local SQL Server persistence for the AI developer.
   Leverages the local SQL Server 2025 instance to remember WHAT is being built,
   HOW, and the state of each project's components + deployments.
   Isolated database (gsd_dev_memory) — does NOT touch jian_* databases.
   Idempotent: safe to re-run. Connect: sqlcmd -S localhost -E -C
   ============================================================================ */
IF DB_ID('gsd_dev_memory') IS NULL
BEGIN
    CREATE DATABASE gsd_dev_memory;
END
GO
ALTER DATABASE gsd_dev_memory SET RECOVERY SIMPLE;
GO
USE gsd_dev_memory;
GO

/* Projects the AI developer is building (one per repo / subdomain). */
IF OBJECT_ID('dbo.Projects') IS NULL
CREATE TABLE dbo.Projects (
    Id          INT IDENTITY(1,1) PRIMARY KEY,
    Name        NVARCHAR(100) NOT NULL,
    RepoPath    NVARCHAR(400) NULL,
    Subdomain   NVARCHAR(150) NULL,   -- DEV host on this box, e.g. myhr.rjain.technijian.com
    AlphaHost   AS (CONCAT('alpha-', Name, '.technijian.com')) PERSISTED, -- test-lab handover target
    Status      NVARCHAR(40)  NOT NULL DEFAULT 'planned', -- planned|building|deployed|failed|retired
    CreatedAt   DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    UpdatedAt   DATETIME2 NULL,
    CONSTRAINT UQ_Projects_Name UNIQUE (Name)
);
GO

/* Per-project components: the 5 deliverables the owner named. */
IF OBJECT_ID('dbo.Components') IS NULL
CREATE TABLE dbo.Components (
    Id          INT IDENTITY(1,1) PRIMARY KEY,
    ProjectId   INT NOT NULL REFERENCES dbo.Projects(Id),
    Kind        NVARCHAR(30) NOT NULL,  -- web | api | database | mcp-server | mcp-admin
    Name        NVARCHAR(120) NOT NULL,
    Path        NVARCHAR(400) NULL,     -- project/source/publish path
    BindingHost NVARCHAR(200) NULL,     -- IIS host header
    Port        INT NULL,               -- kestrel/node backend port (behind IIS)
    Framework   NVARCHAR(60) NULL,      -- net10.0 / React 18 / SQL Server 2025 / node ...
    Status      NVARCHAR(40) NOT NULL DEFAULT 'planned', -- planned|built|deployed|healthy|broken
    HealthUrl   NVARCHAR(400) NULL,
    LastCheckAt DATETIME2 NULL,
    CreatedAt   DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    UpdatedAt   DATETIME2 NULL
);
GO

/* Build/deploy runs — outcome of each attempt. */
IF OBJECT_ID('dbo.BuildRuns') IS NULL
CREATE TABLE dbo.BuildRuns (
    Id          INT IDENTITY(1,1) PRIMARY KEY,
    ProjectId   INT NULL REFERENCES dbo.Projects(Id),
    ComponentId INT NULL REFERENCES dbo.Components(Id),
    Phase       NVARCHAR(40) NOT NULL,  -- restore|build|test|publish|deploy|verify
    Result      NVARCHAR(20) NOT NULL,  -- ok|fail|skipped
    DurationMs  INT NULL,
    Detail      NVARCHAR(MAX) NULL,
    CreatedAt   DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

/* Free-form developer log — "remember what you are doing, how you are doing it". */
IF OBJECT_ID('dbo.DevLog') IS NULL
CREATE TABLE dbo.DevLog (
    Id          INT IDENTITY(1,1) PRIMARY KEY,
    ProjectId   INT NULL REFERENCES dbo.Projects(Id),
    Phase       NVARCHAR(60) NULL,      -- maps to SDLC phase A-G or build stage
    Action      NVARCHAR(200) NOT NULL,
    Detail      NVARCHAR(MAX) NULL,
    CreatedAt   DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

/* Decisions + rationale (mirrors the orchestrator decision discipline). */
IF OBJECT_ID('dbo.Decisions') IS NULL
CREATE TABLE dbo.Decisions (
    Id          INT IDENTITY(1,1) PRIMARY KEY,
    ProjectId   INT NULL REFERENCES dbo.Projects(Id),
    Decision    NVARCHAR(400) NOT NULL,
    Rationale   NVARCHAR(MAX) NULL,
    CreatedAt   DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

PRINT 'gsd_dev_memory ready: Projects, Components, BuildRuns, DevLog, Decisions';
GO
