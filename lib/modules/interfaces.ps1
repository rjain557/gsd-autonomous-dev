
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
