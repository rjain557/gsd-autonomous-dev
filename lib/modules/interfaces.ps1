
# ===============================================================
# GSD MULTI-INTERFACE MODULE
# Detects and manages: web, mcp, browser, mobile, agent interfaces
# ===============================================================

# 10b: Module loading guard - prevent re-sourcing
if ($script:INTERFACES_MODULE_LOADED) { return }
$script:INTERFACES_MODULE_LOADED = $true

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
        2a: Single recursive scan, then filter in-memory.
    #>
    param([string]$RepoRoot)

    $detected = @()

    # 2a: Do ONE recursive scan of the design tree, then partition by interface type
    $designRoot = Join-Path $RepoRoot "design"
    $allDesignDirs = @()
    $allDesignFiles = @()
    $designRootExists = Test-Path $designRoot

    if ($designRootExists) {
        $allDesignDirs = @(Get-ChildItem -Path $designRoot -Directory -Recurse -Depth 4 -ErrorAction SilentlyContinue)
        $allDesignFiles = @(Get-ChildItem -Path $designRoot -File -Recurse -Depth 5 -ErrorAction SilentlyContinue)
    }

    # Also scan for nested design dirs (e.g., repo\projectname\design\)
    $nestedDesignDirs = @()
    $nestedDesignFiles = @()
    if (-not $designRootExists) {
        $nestedDesignRoots = @(Get-ChildItem -Path $RepoRoot -Directory -Recurse -Depth 3 -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq "design" })
        foreach ($nd in $nestedDesignRoots) {
            $nestedDesignDirs += @(Get-ChildItem -Path $nd.FullName -Directory -Recurse -Depth 4 -ErrorAction SilentlyContinue)
            $nestedDesignFiles += @(Get-ChildItem -Path $nd.FullName -File -Recurse -Depth 5 -ErrorAction SilentlyContinue)
        }
    }

    foreach ($iface in $script:INTERFACE_TYPES) {
        $designLeaf = Split-Path $iface.DesignDir -Leaf   # "web", "mcp", etc.
        $baseDir = Join-Path $RepoRoot $iface.DesignDir

        # Try direct path first, then search in scanned dirs
        if (-not (Test-Path $baseDir)) {
            $found = ($allDesignDirs + $nestedDesignDirs) |
                Where-Object { $_.Name -eq $designLeaf -and $_.Parent.Name -eq "design" } |
                Select-Object -First 1
            if ($found) {
                $baseDir = $found.FullName
            }
        }

        if (-not (Test-Path $baseDir)) { continue }

        # Find latest version
        $versions = Get-ChildItem -Path $baseDir -Directory |
            Where-Object { $_.Name -match '^v(\d+)$' } |
            Sort-Object { [int]($_.Name -replace '^v', '') } -Descending

        if ($versions.Count -eq 0) { continue }

        $latest = $versions[0]
        $versionNum = $latest.Name
        $fullPath = $latest.FullName
        $versionPath = $fullPath.Substring($RepoRoot.Length).TrimStart('\')

        # 2a: Filter from the single scan instead of rescanning per-interface
        $allDirs = @(($allDesignDirs + $nestedDesignDirs) | Where-Object { $_.FullName.StartsWith($fullPath) })
        $allFiles = @(($allDesignFiles + $nestedDesignFiles) | Where-Object { $_.FullName.StartsWith($fullPath) })

        # If the single-scan didn't cover this path (edge case), do a targeted scan
        if ($allDirs.Count -eq 0 -and $allFiles.Count -eq 0) {
            $allDirs = @(Get-ChildItem -Path $fullPath -Directory -Recurse -ErrorAction SilentlyContinue)
            $allFiles = @(Get-ChildItem -Path $fullPath -File -Recurse -ErrorAction SilentlyContinue)
        }

        # Find _analysis and _stubs from already-collected dirs
        $analysisDir = $null
        $analysisDirObj = $allDirs | Where-Object { $_.Name -eq '_analysis' } | Select-Object -First 1
        if ($analysisDirObj) { $analysisDir = $analysisDirObj.FullName }

        $stubsDir = $null
        $stubsDirObj = $allDirs | Where-Object { $_.Name -eq '_stubs' } | Select-Object -First 1
        if ($stubsDirObj) { $stubsDir = $stubsDirObj.FullName }

        # 2d: No redundant Test-Path - we found these from the dir listing, they exist
        $hasAnalysis = $null -ne $analysisDir
        $hasStubs = $null -ne $stubsDir

        # Count analysis files from in-memory collection
        $analysisFiles = @()
        if ($hasAnalysis) {
            $analysisFiles = @($allFiles | Where-Object { $_.FullName.StartsWith($analysisDir) })
        }

        # Count design files (non-analysis, non-stubs)
        $designFiles = $allFiles | Where-Object { $_.FullName -notmatch '(_analysis|_stubs)' }

        # 2b: Build folder inventory using Group-Object instead of per-dir Get-ChildItem
        $folderInventory = @{}
        $filesByDir = $allFiles | Group-Object DirectoryName
        foreach ($group in $filesByDir) {
            $relPath = $group.Name.Replace($fullPath, '').TrimStart('\')
            if ($relPath -and $group.Count -gt 0) {
                $folderInventory[$relPath] = $group.Count
            }
        }

        # 2c: Detect notable content folders using in-memory $allDirs + grouped file counts
        $contentFolders = @{}
        $knownFolders = @('src','api','backend','frontend','components','database','db',
                          'config','contexts','data','docs','guidelines','assets','models',
                          'Controllers','Services','Models','Repositories','Middleware')
        $knownSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$knownFolders, [System.StringComparer]::OrdinalIgnoreCase)

        foreach ($d in $allDirs) {
            if ($knownSet.Contains($d.Name)) {
                $rel = $d.FullName.Replace($fullPath, '').TrimStart('\')
                # Count files under this dir from grouped data
                $fc = ($filesByDir | Where-Object { $_.Name.StartsWith($d.FullName) } | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum
                if ($fc -gt 0) { $contentFolders[$rel] = $fc }
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
                $exists = ($analysisFiles | Where-Object { $_.Name -eq $ef.Name }).Count -gt 0
                $filePath = if ($exists) { Join-Path $analysisDir $ef.Name } else { $null }
                $info.AnalysisFiles[$ef.Key] = @{
                    Expected = $ef.Name
                    Exists = $exists
                    Path = $filePath
                }
            }
        }

        # Map stubs
        if ($hasStubs) {
            $stubFiles = @($allFiles | Where-Object { $_.FullName.StartsWith($stubsDir) })
            $stubDirs = @($allDirs | Where-Object { $_.FullName.StartsWith($stubsDir) })
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
