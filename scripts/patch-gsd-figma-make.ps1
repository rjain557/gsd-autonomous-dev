<#
.SYNOPSIS
    GSD Figma Make Integration Patch
    Updates for multi-interface projects and Figma Make deliverable integration.

.DESCRIPTION
    1. Updates directory detection: web, mcp, browser, mobile, agent interfaces
    2. Integrates Figma Make _analysis/ deliverables as machine-readable specs
    3. Updates prompts to reference _analysis/ docs instead of raw Figma files
    4. Updates known-limitations with revised fixability matrix
    5. Adds per-interface convergence support

.INSTALL_ORDER
    1. install-gsd-global.ps1
    2. install-gsd-blueprint.ps1
    3. patch-gsd-partial-repo.ps1
    4. patch-gsd-resilience.ps1
    5. patch-gsd-hardening.ps1
    6. patch-gsd-figma-make.ps1          <- this file
#>

param(
    [string]$UserHome = $env:USERPROFILE
)

$ErrorActionPreference = "Stop"
$GsdGlobalDir = Join-Path $UserHome ".gsd-global"
$BlueprintDir = Join-Path $GsdGlobalDir "blueprint"

if (-not (Test-Path $GsdGlobalDir)) {
    Write-Host "[XX] GSD not installed." -ForegroundColor Red; exit 1
}

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "  GSD Figma Make Integration Patch" -ForegroundColor Cyan
Write-Host "  Multi-interface support + _analysis/ deliverable integration" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""

# ========================================================
# STEP 1: Interface detection library
# ========================================================

Write-Host "[ART] Creating multi-interface detection module..." -ForegroundColor Yellow

$interfaceLib = @'

# ===============================================================
# GSD MULTI-INTERFACE MODULE
# Detects and manages: web, mcp, browser, mobile, agent interfaces
# ===============================================================

$script:INTERFACE_TYPES = @(
    @{ Key="web";     Label="Web Application";         DesignDir="design\web";     Color="Cyan" },
    @{ Key="mcp";     Label="MCP Admin Portal";        DesignDir="design\mcp";     Color="Magenta" },
    @{ Key="browser"; Label="Browser Extension";       DesignDir="design\browser"; Color="Yellow" },
    @{ Key="mobile";  Label="Mobile App (iOS/Android)"; DesignDir="design\mobile"; Color="Green" },
    @{ Key="agent";   Label="Remote Agent";            DesignDir="design\agent";   Color="DarkCyan" }
)

function Find-ProjectInterfaces {
    <#
    .SYNOPSIS
        Scans a repo for all interface types and their latest versions.
        Returns array of detected interfaces with paths and analysis status.
    #>
    param([string]$RepoRoot)

    $detected = @()

    foreach ($iface in $script:INTERFACE_TYPES) {
        $baseDir = Join-Path $RepoRoot $iface.DesignDir

        # If not found at repo root, search for it under subdirectories
        # Handles repos where project is nested (e.g., repo\projectname\design\web\)
        if (-not (Test-Path $baseDir)) {
            $designLeaf = Split-Path $iface.DesignDir -Leaf   # "web", "mcp", etc.
            $found = Get-ChildItem -Path $RepoRoot -Directory -Recurse -Depth 3 -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -eq $designLeaf -and $_.Parent.Name -eq "design" } |
                Select-Object -First 1
            if ($found) {
                $baseDir = $found.FullName
            }
        }

        if (Test-Path $baseDir) {
            # Find latest version
            $versions = Get-ChildItem -Path $baseDir -Directory |
                Where-Object { $_.Name -match '^v(\d+)$' } |
                Sort-Object { [int]($_.Name -replace '^v', '') } -Descending

            if ($versions.Count -gt 0) {
                $latest = $versions[0]
                $versionNum = $latest.Name
                $fullPath = $latest.FullName
                # Build relative path from repo root
                $versionPath = $fullPath.Substring($RepoRoot.Length).TrimStart('\')

                # Check for Figma Make _analysis/ deliverables
                # Auto-discover: recursively scan version folder for _analysis and _stubs
                $allDirs = @(Get-ChildItem -Path $fullPath -Directory -Recurse -ErrorAction SilentlyContinue)
                $allFiles = @(Get-ChildItem -Path $fullPath -File -Recurse -ErrorAction SilentlyContinue)

                # Find _analysis wherever it lives under the version folder
                $analysisDir = $null
                $analysisDirObj = $allDirs | Where-Object { $_.Name -eq '_analysis' } | Select-Object -First 1
                if ($analysisDirObj) { $analysisDir = $analysisDirObj.FullName }

                # Find _stubs wherever it lives under the version folder
                $stubsDir = $null
                $stubsDirObj = $allDirs | Where-Object { $_.Name -eq '_stubs' } | Select-Object -First 1
                if ($stubsDirObj) { $stubsDir = $stubsDirObj.FullName }

                $hasAnalysis = ($null -ne $analysisDir) -and (Test-Path $analysisDir)
                $hasStubs = ($null -ne $stubsDir) -and (Test-Path $stubsDir)

                # Count analysis files
                $analysisFiles = @()
                if ($hasAnalysis) {
                    $analysisFiles = @(Get-ChildItem -Path $analysisDir -File -ErrorAction SilentlyContinue)
                }

                # Count design files (non-analysis, non-stubs)
                $designFiles = $allFiles | Where-Object { $_.FullName -notmatch '(_analysis|_stubs)' }

                # Build folder inventory so the engine knows the full layout
                $folderInventory = @{}
                foreach ($d in $allDirs) {
                    $relPath = $d.FullName.Replace($fullPath, '').TrimStart('\')
                    $fileCount = @(Get-ChildItem -Path $d.FullName -File -ErrorAction SilentlyContinue).Count
                    if ($fileCount -gt 0) {
                        $folderInventory[$relPath] = $fileCount
                    }
                }

                # Detect notable content folders
                $contentFolders = @{}
                $knownFolders = @('src','api','backend','frontend','components','database','db',
                                  'config','contexts','data','docs','guidelines','assets','models',
                                  'Controllers','Services','Models','Repositories','Middleware')
                foreach ($known in $knownFolders) {
                    $found = $allDirs | Where-Object { $_.Name -eq $known }
                    if ($found) {
                        foreach ($fld in $found) {
                            $rel = $fld.FullName.Replace($fullPath, '').TrimStart('\')
                            $fc = @(Get-ChildItem -Path $fld.FullName -File -Recurse -ErrorAction SilentlyContinue).Count
                            $contentFolders[$rel] = $fc
                        }
                    }
                }

                $info = @{
                    Key = $iface.Key
                    Label = $iface.Label
                    Color = $iface.Color
                    DesignDir = $iface.DesignDir
                    Version = $versionNum
                    VersionPath = $versionPath
                    FullPath = $fullPath
                    AllVersions = $versions.Count
                    HasAnalysis = $hasAnalysis
                    HasStubs = $hasStubs
                    AnalysisDir = $analysisDir
                    StubsDir = $stubsDir
                    AnalysisFileCount = $analysisFiles.Count
                    DesignFileCount = $designFiles.Count
                    TotalFiles = $allFiles.Count
                    TotalFolders = $allDirs.Count
                    FolderInventory = $folderInventory
                    ContentFolders = $contentFolders
                    AnalysisFiles = @{}
                }

                # Map known analysis deliverables
                if ($hasAnalysis) {
                    $expectedFiles = @(
                        @{ Name="01-screen-inventory.md";     Key="screens" },
                        @{ Name="02-component-inventory.md";  Key="components" },
                        @{ Name="03-design-system.md";        Key="design_system" },
                        @{ Name="04-navigation-routing.md";   Key="navigation" },
                        @{ Name="05-data-types.md";           Key="types" },
                        @{ Name="06-api-contracts.md";        Key="api" },
                        @{ Name="07-hooks-state.md";          Key="hooks" },
                        @{ Name="08-mock-data-catalog.md";    Key="mock_data" },
                        @{ Name="09-storyboards.md";          Key="storyboards" },
                        @{ Name="10-screen-state-matrix.md";  Key="states" },
                        @{ Name="11-api-to-sp-map.md";        Key="api_sp_map" },
                        @{ Name="12-implementation-guide.md"; Key="impl_guide" }
                    )

                    foreach ($ef in $expectedFiles) {
                        $filePath = Join-Path $analysisDir $ef.Name
                        $info.AnalysisFiles[$ef.Key] = @{
                            Expected = $ef.Name
                            Exists = (Test-Path $filePath)
                            Path = if (Test-Path $filePath) { $filePath } else { $null }
                        }
                    }
                }

                # Map stubs
                if ($hasStubs) {
                    $stubFiles = @(Get-ChildItem -Path $stubsDir -File -Recurse -ErrorAction SilentlyContinue)
                    $stubDirs = @(Get-ChildItem -Path $stubsDir -Directory -Recurse -ErrorAction SilentlyContinue)
                    $info["HasControllerStubs"] = ($stubFiles | Where-Object { $_.Name -match 'Controller' -and $_.Extension -eq '.cs' }).Count -gt 0
                    $info["HasDtoStubs"] = ($stubFiles | Where-Object { $_.Name -match '(Dto|Model|DTO)' -and $_.Extension -eq '.cs' }).Count -gt 0
                    $info["HasTableSql"] = ($stubFiles | Where-Object { $_.Name -match 'table' -and $_.Extension -eq '.sql' }).Count -gt 0
                    $info["HasSpSql"] = ($stubFiles | Where-Object { $_.Name -match '(stored|proc|sp)' -and $_.Extension -eq '.sql' }).Count -gt 0
                    $info["HasSeedSql"] = ($stubFiles | Where-Object { $_.Name -match 'seed' -and $_.Extension -eq '.sql' }).Count -gt 0
                    $info["StubFileCount"] = $stubFiles.Count
                    # Build stubs inventory
                    $stubInventory = @{}
                    foreach ($sf in $stubFiles) {
                        $rel = $sf.FullName.Replace($stubsDir, '').TrimStart('\')
                        $stubInventory[$rel] = $sf.Length
                    }
                    $info["StubInventory"] = $stubInventory
                }

                $detected += $info
            }
        }
    }

    return $detected
}

function Show-InterfaceSummary {
    <#
    .SYNOPSIS
        Pretty-prints detected interfaces with analysis status.
    #>
    param([array]$Interfaces)

    if ($Interfaces.Count -eq 0) {
        Write-Host "  [!!]  No design interfaces detected" -ForegroundColor DarkYellow
        Write-Host "  Expected: design\web\v##, design\mcp\v##, etc." -ForegroundColor DarkGray
        return
    }

    Write-Host "  Detected $($Interfaces.Count) interface(s):" -ForegroundColor White
    Write-Host ""

    foreach ($iface in $Interfaces) {
        $analysisStatus = if ($iface.HasAnalysis) {
            $found = ($iface.AnalysisFiles.Values | Where-Object { $_.Exists }).Count
            $total = $iface.AnalysisFiles.Count
            "[OK] _analysis/ ($found/$total deliverables)"
        } else {
            "[!!]  No _analysis/ (Figma Make deliverables missing)"
        }

        $stubsStatus = if ($iface.HasStubs) { "[OK] _stubs/" } else { "-" }

        Write-Host "  $($iface.Label)" -ForegroundColor $iface.Color
        Write-Host "    Version:    $($iface.Version) ($($iface.AllVersions) total versions)" -ForegroundColor DarkGray
        Write-Host "    Path:       $($iface.VersionPath)" -ForegroundColor DarkGray
        Write-Host "    Total:      $($iface.TotalFiles) files in $($iface.TotalFolders) folders" -ForegroundColor DarkGray
        Write-Host "    Analysis:   $analysisStatus" -ForegroundColor $(if ($iface.HasAnalysis) { "DarkGreen" } else { "DarkYellow" })
        if ($iface.HasAnalysis) {
            $relAnalysis = $iface.AnalysisDir.Replace($iface.FullPath, '').TrimStart('\')
            Write-Host "    Found at:   $relAnalysis" -ForegroundColor DarkGray
        }
        Write-Host "    Stubs:      $stubsStatus" -ForegroundColor DarkGray
        if ($iface.HasStubs) {
            $relStubs = $iface.StubsDir.Replace($iface.FullPath, '').TrimStart('\')
            Write-Host "    Found at:   $relStubs ($($iface.StubFileCount) files)" -ForegroundColor DarkGray
        }
        # Show discovered content folders
        if ($iface.ContentFolders.Count -gt 0) {
            Write-Host "    Layout:" -ForegroundColor DarkGray
            foreach ($folder in ($iface.ContentFolders.GetEnumerator() | Sort-Object Name)) {
                Write-Host "      $($folder.Key)\ ($($folder.Value) files)" -ForegroundColor DarkGray
            }
        }
        Write-Host ""
    }
}

function Build-InterfacePromptContext {
    <#
    .SYNOPSIS
        Builds the prompt context block for all detected interfaces.
        Agents read this to know what interfaces exist and where their specs are.
    #>
    param([array]$Interfaces)

    $lines = @("## Project Interfaces")
    $lines += ""
    $lines += "This project has $($Interfaces.Count) interface(s):"
    $lines += ""

    foreach ($iface in $Interfaces) {
        $lines += "### $($iface.Label) ($($iface.Key))"
        $lines += "- Design: $($iface.VersionPath)"
        $lines += "- Version: $($iface.Version)"

        if ($iface.HasAnalysis) {
            $lines += "- **Figma Make Analysis (MACHINE-READABLE - USE THESE AS PRIMARY SPEC):**"

            $deliverableMap = @{
                screens      = "Screen inventory - every screen, route, layout, sections, interactions"
                components   = "Component inventory - every component with props, states, variants"
                design_system = "Design system - colors, typography, spacing, tokens, shadows, motion"
                navigation   = "Navigation & routing - route table, nav tree, deep linking"
                types        = "TypeScript types - every interface, enum, data relationship"
                api          = "API contracts - every endpoint, params, request/response bodies"
                hooks        = "Hooks & state - every custom hook with returns and side effects"
                mock_data    = "Mock data catalog - exact shapes, values, relationships"
                storyboards  = "Storyboards - step-by-step user flows for every feature"
                states       = "Screen state matrix - every screen x every state (loading, error, empty...)"
                api_sp_map   = "API-to-SP mapping - frontend hook -> API -> stored procedure -> table"
                impl_guide   = "Implementation guide - build order, architecture decisions, fidelity checklist"
            }

            foreach ($key in $iface.AnalysisFiles.Keys) {
                $af = $iface.AnalysisFiles[$key]
                if ($af.Exists) {
                    $desc = if ($deliverableMap.ContainsKey($key)) { $deliverableMap[$key] } else { $key }
                    $lines += "  - ``$($af.Expected)``: $desc"
                }
            }
        } else {
            $lines += "- [!!] No _analysis/ deliverables. Agent must work from raw design files only."
        }

        if ($iface.HasStubs) {
            $lines += "- **Backend/Database Stubs:**"
            if ($iface.HasControllerStubs) { $lines += "  - Controller stubs (.cs)" }
            if ($iface.HasDtoStubs) { $lines += "  - DTO model stubs (.cs)" }
            if ($iface.HasTableSql) { $lines += "  - Table creation SQL" }
            if ($iface.HasSpSql) { $lines += "  - Stored procedure stubs SQL" }
            if ($iface.HasSeedSql) { $lines += "  - Seed data SQL" }
        }

        # Include discovered folder layout so agents know the structure
        if ($iface.ContentFolders -and $iface.ContentFolders.Count -gt 0) {
            $lines += "- **Discovered folder layout under $($iface.VersionPath):**"
            foreach ($folder in ($iface.ContentFolders.GetEnumerator() | Sort-Object Name)) {
                $lines += "  - $($folder.Key)\ ($($folder.Value) files)"
            }
        }

        $lines += ""
    }

    return ($lines -join "`n")
}
'@

$libDir = Join-Path $GsdGlobalDir "lib\modules"
Set-Content -Path "$libDir\interfaces.ps1" -Value $interfaceLib -Encoding UTF8
Write-Host "   [OK] lib\modules\interfaces.ps1" -ForegroundColor DarkGreen

Write-Host ""

# ========================================================
# STEP 2: Updated blueprint prompt (Figma Make aware)
# ========================================================

Write-Host "[CLIP] Creating Figma Make-aware blueprint prompt..." -ForegroundColor Yellow

$blueprintFigmaMake = @'
# Blueprint Phase - Claude Code (Figma Make Edition)
# Reads Figma Make _analysis/ deliverables as PRIMARY specification source

You are the ARCHITECT. Produce blueprint.json from specs, Figma Make analysis, and stubs.

## Context
- Project: {{REPO_ROOT}}
- SDLC docs: docs\ (Phase A through Phase E)
- Output: {{GSD_DIR}}\blueprint\blueprint.json

{{INTERFACE_CONTEXT}}

## CRITICAL: Figma Make _analysis/ Is Your Primary Spec

For each interface that has _analysis/ deliverables, these are MACHINE-READABLE,
EXHAUSTIVE specifications. They are MORE RELIABLE than raw design files because
they contain exact values, complete type definitions, and API contracts.

### Reading Priority (highest to lowest):
1. **_analysis/ deliverables** - screen inventory, components, design system, API contracts,
   types, hooks, storyboards, state matrix, implementation guide
2. **_stubs/ files** - controller stubs, DTO stubs, SQL table/SP/seed scripts
3. **docs\ SDLC specs** - business logic, compliance, architecture decisions
4. **Raw design files** - only if _analysis/ is incomplete

### How to Use Each Deliverable:

| Deliverable | Blueprint Use |
|---|---|
| 01-screen-inventory.md | One blueprint item per screen (React component) |
| 02-component-inventory.md | One blueprint item per reusable component |
| 03-design-system.md | Extract as figma-tokens.md - Codex references for exact values |
| 04-navigation-routing.md | Blueprint items for routing config, nav components, guards |
| 05-data-types.md | Blueprint items for TypeScript type files |
| 06-api-contracts.md | Blueprint items for .NET controllers + services per endpoint group |
| 07-hooks-state.md | Blueprint items for each custom hook (real API version) |
| 08-mock-data-catalog.md | Blueprint items for seed data SQL matching mock data exactly |
| 09-storyboards.md | Validation criteria - each flow must work end-to-end |
| 10-screen-state-matrix.md | Blueprint items for loading/error/empty states per screen |
| 11-api-to-sp-map.md | Blueprint items for stored procedures, maps controller->SP->table |
| 12-implementation-guide.md | Use the build order directly as your tier structure |

### If _stubs/ Exist:
The stubs are STARTING POINTS, not final code. Blueprint items that have stubs should:
- Set status to "partial" (stub exists but needs implementation)
- Reference the stub file as existing_file
- Set work_type to "extend" (fill in the stub bodies)

## Produce blueprint.json

Use the implementation guide (D12) build order as your tier structure.
Each tier maps to a phase from the guide.

For EACH interface detected, prefix items with the interface key:
- Blueprint item IDs: web-001, mcp-001, browser-001, mobile-001, agent-001
- File paths include the interface context: src\Web\..., src\MCP\..., etc.

### Multi-Interface Shared Components
Some items are shared across interfaces:
- Database tables and stored procedures (shared backend)
- DTOs and service layer (shared backend)
- Type definitions may be shared

These get their own tier (Tier 0: Shared Backend) with no interface prefix.

```json
{
  "project": "...",
  "interfaces": ["web", "mcp", "browser"],
  "tiers": [
    {
      "tier": 0,
      "name": "Shared Backend",
      "description": "Database, stored procedures, services shared by all interfaces",
      "items": [...]
    },
    {
      "tier": 1,
      "name": "Database Foundation",
      "interface": "shared",
      "items": [
        {
          "id": "shared-001",
          "path": "src/Database/Migrations/V001__CreateTables.sql",
          "type": "migration",
          "spec_source": "design/web/v03/_analysis/05-data-types.md",
          "stub_source": "design/web/v03/_stubs/database/01-tables.sql",
          "status": "partial",
          "work_type": "extend",
          "existing_file": "design/web/v03/_stubs/database/01-tables.sql",
          "description": "Create all tables from type definitions",
          "acceptance": ["All entities from 05-data-types.md have corresponding tables", "Audit columns on every table", "Foreign keys match data relationship diagram"]
        }
      ]
    },
    {
      "tier": 3,
      "name": "Web Frontend Components",
      "interface": "web",
      "items": [
        {
          "id": "web-042",
          "path": "src/Web/ClientApp/src/components/Dashboard/CardGrid.tsx",
          "type": "react-component",
          "spec_source": "design/web/v03/_analysis/02-component-inventory.md#CardGrid",
          "figma_states": "design/web/v03/_analysis/10-screen-state-matrix.md#Dashboard",
          "design_tokens": "design/web/v03/_analysis/03-design-system.md",
          "description": "Dashboard card grid with responsive breakpoints",
          "acceptance": [
            "Matches component inventory: props interface, all states rendered",
            "Responsive breakpoints from design system",
            "Loading skeleton matches state matrix",
            "Colors/spacing/typography from design tokens"
          ]
        }
      ]
    }
  ]
}
```

## Also Write
- {{GSD_DIR}}\blueprint\health.json
- {{GSD_DIR}}\blueprint\figma-tokens.md (extracted from 03-design-system.md for each interface)
- {{GSD_DIR}}\blueprint\interface-map.json (which interfaces exist, their versions, analysis status)

Be EXHAUSTIVE. Cross-reference every screen in 01-screen-inventory with every
component in 02-component-inventory with every API call in 06-api-contracts
with every stored procedure in 11-api-to-sp-map. Nothing should be missed.
'@

Set-Content -Path "$BlueprintDir\prompts\claude\blueprint-figmamake.md" -Value $blueprintFigmaMake -Encoding UTF8
Write-Host "   [OK] prompts\claude\blueprint-figmamake.md" -ForegroundColor DarkGreen

Write-Host ""

# ========================================================
# STEP 3: Updated Codex build prompt (Figma Make aware)
# ========================================================

Write-Host "[WRENCH] Creating Figma Make-aware Codex build prompt..." -ForegroundColor Yellow

$codexFigmaMake = @'
# Build Phase - Codex (Figma Make Edition)
# Has access to _analysis/ deliverables with exact specifications

You are the DEVELOPER. You have UNLIMITED tokens and ACCESS TO EXACT SPECS.

## Context
- Iteration: {{ITERATION}}
- Health: {{HEALTH}}%

{{INTERFACE_CONTEXT}}

## YOUR ADVANTAGE: _analysis/ Deliverables

Unlike working from vague specs, you have MACHINE-READABLE, EXACT specifications
generated by Figma Make. USE THEM for every file you generate:

### For React Components:
1. Read **02-component-inventory.md** for the exact props interface and state table
2. Read **03-design-system.md** for exact color hex values, spacing px, typography
3. Read **10-screen-state-matrix.md** for exactly what each state looks like
4. Read **01-screen-inventory.md** for layout structure and responsive behavior

### For API / Backend:
1. Read **06-api-contracts.md** for exact endpoint signatures, request/response bodies
2. Read **11-api-to-sp-map.md** for exact SP name and table mapping
3. Read **_stubs/backend/Controllers/** for controller signatures (fill in bodies)
4. Read **_stubs/backend/Models/** for DTO definitions (enhance with validation)

### For Database:
1. Read **_stubs/database/01-tables.sql** for table structure (review and fix)
2. Read **_stubs/database/02-stored-procedures.sql** for SP signatures (fill in bodies)
3. Read **_stubs/database/03-seed-data.sql** for seed data (verify matches mock data)
4. Read **08-mock-data-catalog.md** for exact mock data values the seed must produce

### For Hooks / State:
1. Read **07-hooks-state.md** for exact hook return shapes and API calls made
2. Replace mock data returns with real API calls
3. Match the exact TypeScript types from **05-data-types.md**

### For User Flows:
1. Read **09-storyboards.md** - every step must work end-to-end
2. Each storyboard is an integration test scenario

## Stubs Are Starting Points
If a blueprint item references a stub file in _stubs/:
- READ the stub first
- EXTEND it (fill in method bodies, add validation, add error handling)
- DO NOT rewrite from scratch - preserve the structure and signatures

## Design Fidelity
Read **12-implementation-guide.md** -> "Design Fidelity Checklist" section.
Every pixel dimension, color value, spacing value, and typography choice must
match EXACTLY. The _analysis/ deliverables contain exact values - use them.

## Read These Files
1. {{GSD_DIR}}\blueprint\next-batch.json - your work order
2. {{GSD_DIR}}\blueprint\blueprint.json - full context
3. {{GSD_DIR}}\blueprint\figma-tokens.md - extracted design tokens
4. The _analysis/ and _stubs/ directories for each interface (paths in blueprint items)
5. docs\ - SDLC specification documents

## Boundaries
DO NOT modify {{GSD_DIR}}\blueprint\blueprint.json
DO NOT modify {{GSD_DIR}}\blueprint\health.json
DO NOT modify {{GSD_DIR}}\blueprint\next-batch.json
DO NOT modify anything in _analysis/ or _stubs/ (those are source-of-truth references)
WRITE source code + append to {{GSD_DIR}}\blueprint\build-log.jsonl ONLY
'@

Set-Content -Path "$BlueprintDir\prompts\codex\build-figmamake.md" -Value $codexFigmaMake -Encoding UTF8
Write-Host "   [OK] prompts\codex\build-figmamake.md" -ForegroundColor DarkGreen

Write-Host ""

# ========================================================
# STEP 4: Update pipeline to detect interfaces + use right prompts
# ========================================================

Write-Host "[SYNC] Creating interface-aware pipeline wrapper..." -ForegroundColor Yellow

$interfaceWrapper = @'
# ===============================================================
# GSD Interface-Aware Pipeline Wrapper
# Dot-source this in pipeline scripts to get interface detection
# Usage: . "$env:USERPROFILE\.gsd-global\lib\modules\interface-wrapper.ps1"
# ===============================================================

# Load interface module
. "$env:USERPROFILE\.gsd-global\lib\modules\interfaces.ps1"

function Initialize-ProjectInterfaces {
    <#
    .SYNOPSIS
        Detects interfaces, selects correct prompts (Figma Make vs standard),
        and builds the interface context block for prompt injection.
    #>
    param(
        [string]$RepoRoot,
        [string]$GsdDir
    )

    $interfaces = Find-ProjectInterfaces -RepoRoot $RepoRoot

    # Display summary
    Show-InterfaceSummary -Interfaces $interfaces

    # Build prompt context
    $interfaceContext = Build-InterfacePromptContext -Interfaces $interfaces

    # Determine which prompt variant to use
    $hasAnyAnalysis = ($interfaces | Where-Object { $_.HasAnalysis }).Count -gt 0

    # Save interface map to project
    $interfaceMap = @{
        detected = $interfaces | ForEach-Object {
            @{
                key = $_.Key
                label = $_.Label
                version = $_.Version
                path = $_.VersionPath
                has_analysis = $_.HasAnalysis
                has_stubs = $_.HasStubs
                analysis_file_count = $_.AnalysisFileCount
            }
        }
        has_figma_make_analysis = $hasAnyAnalysis
        scan_timestamp = (Get-Date -Format "o")
    } | ConvertTo-Json -Depth 4

    $mapDir = Join-Path $GsdDir "blueprint"
    if (-not (Test-Path $mapDir)) { New-Item -ItemType Directory -Path $mapDir -Force | Out-Null }
    Set-Content -Path (Join-Path $mapDir "interface-map.json") -Value $interfaceMap -Encoding UTF8

    return @{
        Interfaces = $interfaces
        Context = $interfaceContext
        UseFigmaMakePrompts = $hasAnyAnalysis
        InterfaceCount = $interfaces.Count
    }
}

function Select-BlueprintPrompt {
    <#
    .SYNOPSIS
        Returns the correct blueprint prompt path based on whether
        Figma Make _analysis/ deliverables exist.
    #>
    param([bool]$HasFigmaMakeAnalysis)

    $globalDir = Join-Path $env:USERPROFILE ".gsd-global\blueprint\prompts\claude"

    if ($HasFigmaMakeAnalysis -and (Test-Path "$globalDir\blueprint-figmamake.md")) {
        return "$globalDir\blueprint-figmamake.md"
    }
    return "$globalDir\blueprint.md"
}

function Select-BuildPrompt {
    param([bool]$HasFigmaMakeAnalysis)

    $globalDir = Join-Path $env:USERPROFILE ".gsd-global\blueprint\prompts\codex"

    if ($HasFigmaMakeAnalysis -and (Test-Path "$globalDir\build-figmamake.md")) {
        return "$globalDir\build-figmamake.md"
    }
    return "$globalDir\build.md"
}

function Resolve-PromptWithInterfaces {
    <#
    .SYNOPSIS
        Resolves a prompt template, injecting interface context.
    #>
    param(
        [string]$TemplatePath,
        [int]$Iteration,
        [double]$Health,
        [string]$GsdDir,
        [string]$RepoRoot,
        [string]$InterfaceContext,
        [int]$BatchSize = 15
    )

    $text = Get-Content $TemplatePath -Raw
    return $text.Replace("{{ITERATION}}", "$Iteration").Replace("{{HEALTH}}", "$Health").Replace("{{GSD_DIR}}", $GsdDir).Replace("{{REPO_ROOT}}", $RepoRoot).Replace("{{BATCH_SIZE}}", "$BatchSize").Replace("{{INTERFACE_CONTEXT}}", $InterfaceContext).Replace("{{FIGMA_PATH}}", "(see interface context above)").Replace("{{FIGMA_VERSION}}", "(multi-interface)")
}
'@

Set-Content -Path "$libDir\interface-wrapper.ps1" -Value $interfaceWrapper -Encoding UTF8
Write-Host "   [OK] lib\modules\interface-wrapper.ps1" -ForegroundColor DarkGreen

Write-Host ""

# ========================================================
# STEP 5: Updated global config
# ========================================================

Write-Host "[GEAR]  Updating global config for multi-interface..." -ForegroundColor Yellow

$updatedConfig = @{
    version = "2.0.0"
    engine = "blueprint-pipeline"
    interfaces = @{
        types = @("web", "mcp", "browser", "mobile", "agent")
        base_path = "design"
        version_pattern = "^v(\d+)$"
        auto_detect_latest = $true
        figma_make_analysis_dir = "_analysis"
        figma_make_stubs_dir = "_stubs"
    }
    figma_make_deliverables = @{
        analysis = @(
            "01-screen-inventory.md",
            "02-component-inventory.md",
            "03-design-system.md",
            "04-navigation-routing.md",
            "05-data-types.md",
            "06-api-contracts.md",
            "07-hooks-state.md",
            "08-mock-data-catalog.md",
            "09-storyboards.md",
            "10-screen-state-matrix.md",
            "11-api-to-sp-map.md",
            "12-implementation-guide.md"
        )
        stubs = @(
            "backend/Controllers/*.cs",
            "backend/Models/*.cs",
            "database/01-tables.sql",
            "database/02-stored-procedures.sql",
            "database/03-seed-data.sql"
        )
    }
    defaults = @{
        max_iterations = 30
        stall_threshold = 3
        batch_size = 15
        target_health = 100
    }
    sdlc_docs = @{
        path = "docs"
        phases = @("Phase-A", "Phase-B", "Phase-C", "Phase-D", "Phase-E")
    }
    patterns = @{
        backend = ".NET 8 with Dapper"
        database = "SQL Server stored procedures only"
        frontend_web = "React 18"
        frontend_mobile = "React Native or MAUI"
        api = "Contract-first, API-first"
        compliance = @("HIPAA", "SOC 2", "PCI", "GDPR")
    }
} | ConvertTo-Json -Depth 5

Set-Content -Path "$BlueprintDir\config\blueprint-config.json" -Value $updatedConfig -Encoding UTF8
Write-Host "   [OK] config\blueprint-config.json (v2.0 multi-interface)" -ForegroundColor DarkGreen

Write-Host ""

# ========================================================
# STEP 6: Updated KNOWN-LIMITATIONS.md
# ========================================================

Write-Host "[CLIP] Updating known limitations matrix..." -ForegroundColor Yellow

$updatedLimitations = @"
# GSD Autonomous Operation - Known Limitations
# Updated: $(Get-Date -Format "yyyy-MM-dd") - with Figma Make integration

## Status Legend
- [OK] = Fully automated, no human intervention needed
- [SYNC] = Automated with self-healing (may retry/sleep/recover)
- [!!] = Partially automated (system does its best, may need human for edge cases)
- [XX] = Requires human intervention

---

## INFRASTRUCTURE FAILURES

| # | Scenario | Status | How It's Handled |
|---|----------|--------|------------------|
| 1 | Agent CLI crash / exit code non-zero | [SYNC] | Retry 3x with 50% batch reduction each time |
| 2 | Token / context window limit hit | [SYNC] | Reduce batch size (15->8->4->2), retry |
| 3 | Per-minute rate limit (429) | [SYNC] | Sleep 2 min, retry. Doesn't count as attempt |
| 4 | Monthly quota exhausted | [SYNC] | Sleep 1 hour, test with ping, repeat up to 24h |
| 5 | Network outage | [SYNC] | Poll every 30s for up to 1 hour, resume when online |
| 6 | Disk full | [SYNC] | Auto-clean caches, bin/obj, old logs. Fail if still full |
| 7 | Corrupt JSON from agent output | [SYNC] | Restore from .last-good backup, continue |
| 8 | Crash mid-iteration | [SYNC] | Checkpoint file enables resume at exact phase |
| 9 | Concurrent run attempt | [OK] | Lock file blocks second instance |
| 10 | Stale lock from previous crash | [OK] | Auto-clear locks older than 2 hours |
| 11 | Auth / API key expired | [XX] | Detected immediately, logged clearly. Human must re-auth |
| 12 | CLI breaking changes (flag rename) | [XX] | Pre-flight version check warns. Human must update scripts |
| 13 | Quota exhausted > 24 hours | [XX] | Stops with clear message. Wait for billing cycle |

---

## CODE QUALITY FAILURES

| # | Scenario | Status | How It's Handled |
|---|----------|--------|------------------|
| 14 | dotnet build compilation errors | [SYNC] | Errors sent to Codex for auto-fix, re-verify |
| 15 | npm / React build errors | [SYNC] | Errors sent to Codex for auto-fix, re-verify |
| 16 | SQL pattern violations | [SYNC] | Lint detects, Codex auto-fixes (TRY/CATCH, audit cols, params) |
| 17 | Health regression > 5% | [SYNC] | Auto-revert git to pre-iteration snapshot |
| 18 | Agent writes outside boundary | [SYNC] | Auto-revert unauthorized file changes |
| 19 | Code compiles but logically wrong | [!!] | **WITH _analysis/:** storyboards (D9) provide flow tests - verify phase can check logic against storyboard steps. **WITHOUT _analysis/:** no runtime tests, may falsely pass |
| 20 | Generated code doesn't match design | [!!] | **WITH _analysis/:** design system (D3) has exact values, state matrix (D10) has exact states - verify phase checks against these. **WITHOUT _analysis/:** visual fidelity is unverifiable |

---

## SPECIFICATION FAILURES

| # | Scenario | Status | How It's Handled |
|---|----------|--------|------------------|
| 21 | Contradictory specs (docs conflict) | [XX] | Stall diagnosis identifies specific conflict. Human resolves |
| 22 | Ambiguous specs (unclear requirements) | [!!] | Agent makes best judgment, may need iteration. Stall diagnosis flags |
| 23 | Missing specs (feature not documented) | [!!] | **WITH _analysis/:** unlikely - D1-D12 are exhaustive. **WITHOUT:** agent can only build what's specified |
| 24 | Spec changed mid-run | [!!] | Next iteration picks up changes. May cause one stall cycle |

---

## FIGMA / DESIGN FAILURES - BEFORE vs AFTER Figma Make

| # | Scenario | Before Figma Make | After Figma Make (_analysis/ exists) |
|---|----------|-------------------|---------------------------------------|
| 25 | Can't read .fig binary files | [XX] Human must export + fill mapping | [OK] **SOLVED** - _analysis/ has all specs in markdown |
| 26 | Unknown component props/states | [XX] Agent guesses from file names | [OK] **SOLVED** - D2 has full props interfaces + state tables |
| 27 | Unknown design tokens (colors, spacing) | [XX] Agent approximates | [OK] **SOLVED** - D3 has exact hex values, px sizes, font stacks |
| 28 | Unknown screen layouts | [XX] Agent guesses structure | [OK] **SOLVED** - D1 has panel breakdown, sections, responsive rules |
| 29 | Unknown navigation structure | [XX] Agent infers from file names | [OK] **SOLVED** - D4 has complete route table + nav tree |
| 30 | Unknown data types | [XX] Agent invents types | [OK] **SOLVED** - D5 has complete TypeScript interfaces |
| 31 | Unknown API contracts | [XX] Agent designs API from scratch | [OK] **SOLVED** - D6 has every endpoint, params, bodies |
| 32 | Unknown user flows | [XX] Agent can't verify behavior | [OK] **SOLVED** - D9 has step-by-step storyboards |
| 33 | Unknown screen states (loading/error/empty) | [XX] Agent forgets edge states | [OK] **SOLVED** - D10 has every screen x every state |
| 34 | No API-to-database mapping | [XX] Agent must infer | [OK] **SOLVED** - D11 maps frontend->API->SP->table end-to-end |
| 35 | No build order guidance | [!!] Agent figures out dependencies | [OK] **SOLVED** - D12 has prioritized build order |
| 36 | Backend stubs don't exist | [XX] Generated from scratch | [OK] **SOLVED** - _stubs/ has controller + DTO + SQL starting points |
| 37 | Seed data doesn't match UI | [XX] Agent invents test data | [OK] **SOLVED** - D8 + _stubs/03-seed-data.sql match mock data exactly |

---

## MULTI-INTERFACE SCENARIOS

| # | Scenario | Status | How It's Handled |
|---|----------|--------|------------------|
| 38 | Multiple interfaces (web + mcp + browser + mobile + agent) | [OK] | Auto-detected from design\ subdirs. Each gets own blueprint tier |
| 39 | Shared backend across interfaces | [OK] | Tier 0 "Shared Backend" in blueprint, built before any interface |
| 40 | Interface-specific components | [OK] | Prefixed IDs (web-001, mcp-001). Separate tiers per interface |
| 41 | Mixed _analysis/ coverage (some have it, some don't) | [OK] | Figma Make prompts used for interfaces WITH _analysis/, standard for others |
| 42 | New interface added mid-project | [!!] | Re-run gsd-blueprint (regenerates blueprint with new interface) |
| 43 | Design version updated (v03 -> v04) | [OK] | Auto-detects latest. Blueprint regeneration picks up changes |

---

## SUMMARY: What Changed with Figma Make

**Before Figma Make (12 items required human intervention):**
Scenarios 25-37 were all [XX] or [!!]. The agents were essentially blind to
the design - working from file names and guesses.

**After Figma Make (1 item requires human intervention):**
Only scenario 21 (contradictory specs) truly requires human intervention.
Everything else is either fully automated or has meaningful self-healing.

### The Remaining Gap: Runtime Correctness (#19)

The _analysis/ deliverables (especially D9: storyboards) provide the SPEC for
correct behavior. The verify phase can check code against storyboard steps.
But without actually RUNNING the code (hitting real endpoints, rendering real UI),
we can't guarantee runtime correctness.

**Potential future fix:** Add a "smoke test" phase that:
1. Starts dotnet run + npm start
2. Uses a headless browser (Playwright) to walk through D9 storyboards
3. Verifies each step produces expected screen state from D10

This would close the last meaningful gap. It requires Playwright + a running
database, but it's technically feasible.

---

## COMPLETE REMAINING HUMAN REQUIREMENTS

After all patches, the ONLY scenarios requiring human action:

| # | Scenario | When It Happens | What Human Does | How Often |
|---|----------|-----------------|-----------------|-----------|
| 11 | API key expired | Auth error detected | Re-run 'claude auth' or 'codex auth' | Rare (months) |
| 12 | CLI breaking changes | Pre-flight version mismatch | Update script flags | Rare (major releases) |
| 13 | Quota > 24 hours | Monthly budget hit | Wait for billing cycle or upgrade | Monthly worst case |
| 21 | Contradictory specs | Stall with diagnosis | Fix docs\ to resolve conflict | Per-project, one-time |

**Everything else runs autonomously.**
"@

Set-Content -Path "$GsdGlobalDir\KNOWN-LIMITATIONS.md" -Value $updatedLimitations -Encoding UTF8
Write-Host "   [OK] KNOWN-LIMITATIONS.md (updated with Figma Make)" -ForegroundColor DarkGreen

Write-Host ""

# ========================================================
# STEP 7: Update .gitignore template for new structure
# ========================================================

Write-Host "[MEMO] Updating gitignore for multi-interface..." -ForegroundColor Yellow

$gitignoreUpdate = @"

# GSD - do NOT ignore _analysis/ and _stubs/ (they are source-of-truth specs)
# design\*\_analysis\ -> KEEP IN GIT
# design\*\_stubs\ -> KEEP IN GIT
"@

$gitignoreTemplate = Join-Path $GsdGlobalDir "templates\gitignore-additions.txt"
if (Test-Path $gitignoreTemplate) {
    $existing = Get-Content $gitignoreTemplate -Raw
    if ($existing -notmatch "_analysis") {
        Add-Content -Path $gitignoreTemplate -Value $gitignoreUpdate -Encoding UTF8
    }
}
Write-Host "   [OK] gitignore updated (preserves _analysis/ and _stubs/)" -ForegroundColor DarkGreen

Write-Host ""

# ========================================================
# DONE
# ========================================================

Write-Host "=========================================================" -ForegroundColor Green
Write-Host "  [OK] Figma Make Integration Patch Applied" -ForegroundColor Green
Write-Host "=========================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  DIRECTORY STRUCTURE (updated):" -ForegroundColor Yellow
Write-Host "    your-repo\" -ForegroundColor DarkGray
Write-Host "    +-- design\" -ForegroundColor DarkGray
Write-Host "    |   +-- web\v03\              <- Web application designs" -ForegroundColor Cyan
Write-Host "    |   |   +-- _analysis\        <- 12 Figma Make deliverables" -ForegroundColor Green
Write-Host "    |   |   +-- _stubs\           <- Controller, DTO, SQL stubs" -ForegroundColor Green
Write-Host "    |   +-- mcp\v02\              <- MCP Admin Portal designs" -ForegroundColor Magenta
Write-Host "    |   |   +-- _analysis\" -ForegroundColor Green
Write-Host "    |   |   +-- _stubs\" -ForegroundColor Green
Write-Host "    |   +-- browser\v01\          <- Browser Extension designs" -ForegroundColor Yellow
Write-Host "    |   +-- mobile\v01\           <- Mobile App designs" -ForegroundColor Green
Write-Host "    |   +-- agent\v01\            <- Remote Agent designs" -ForegroundColor DarkCyan
Write-Host "    +-- docs\                     <- SDLC Phase A-E specs" -ForegroundColor DarkGray
Write-Host "    +-- src\                      <- Generated code" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  WHAT FIGMA MAKE SOLVED:" -ForegroundColor Yellow
Write-Host "    Before: 12 scenarios needed human intervention" -ForegroundColor Red
Write-Host "    After:   4 scenarios need human (auth, CLI, quota, spec conflicts)" -ForegroundColor Green
Write-Host ""
Write-Host "  SEE: ~\.gsd-global\KNOWN-LIMITATIONS.md for full matrix" -ForegroundColor DarkGray
Write-Host ""
