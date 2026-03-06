# ===============================================================
# GSD Interface-Aware Pipeline Wrapper
# Dot-source this in pipeline scripts to get interface detection
# Usage: . "$env:USERPROFILE\.gsd-global\lib\modules\interface-wrapper.ps1"
# ===============================================================

# Load interface module
. "$env:USERPROFILE\.gsd-global\lib\modules\interfaces.ps1"

# 3b: Template cache for prompt resolution
$script:TemplateCache = @{}

function Initialize-ProjectInterfaces {
    <#
    .SYNOPSIS
        Detects interfaces, selects correct prompts (Figma Make vs standard),
        and builds the interface context block for prompt injection.
        3a: Supports -IfStale to skip re-detection if interface-map.json is fresh.
        3b: Does NOT call Show-InterfaceSummary - caller decides when to display.
    #>
    param(
        [string]$RepoRoot,
        [string]$GsdDir,
        [int]$StaleMinutes = 5
    )

    $mapDir = Join-Path $GsdDir "blueprint"
    $mapFile = Join-Path $mapDir "interface-map.json"

    # 3a: Check freshness - skip re-detection if interface-map.json is recent
    if ((Test-Path $mapFile)) {
        $mapAge = (Get-Date) - (Get-Item $mapFile).LastWriteTime
        if ($mapAge.TotalMinutes -lt $StaleMinutes) {
            # Load cached result
            try {
                $cached = Get-Content $mapFile -Raw | ConvertFrom-Json
                $interfaces = Find-ProjectInterfaces -RepoRoot $RepoRoot
                $interfaceContext = Build-InterfacePromptContext -Interfaces $interfaces
                $hasAnyAnalysis = ($interfaces | Where-Object { $_.HasAnalysis }).Count -gt 0
                return @{
                    Interfaces = $interfaces
                    Context = $interfaceContext
                    UseFigmaMakePrompts = $hasAnyAnalysis
                    InterfaceCount = $interfaces.Count
                    FromCache = $true
                }
            } catch {
                # Fall through to full detection on parse error
            }
        }
    }

    $interfaces = Find-ProjectInterfaces -RepoRoot $RepoRoot

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

    if (-not (Test-Path $mapDir)) { New-Item -ItemType Directory -Path $mapDir -Force | Out-Null }
    Set-Content -Path $mapFile -Value $interfaceMap -Encoding UTF8

    return @{
        Interfaces = $interfaces
        Context = $interfaceContext
        UseFigmaMakePrompts = $hasAnyAnalysis
        InterfaceCount = $interfaces.Count
        FromCache = $false
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
        6b: Caches template file reads since they don't change during a run.
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

    # 6b: Cache template reads
    if (-not $script:TemplateCache[$TemplatePath]) {
        $script:TemplateCache[$TemplatePath] = Get-Content $TemplatePath -Raw
    }
    $text = $script:TemplateCache[$TemplatePath]

    return $text.Replace("{{ITERATION}}", "$Iteration").Replace("{{HEALTH}}", "$Health").Replace("{{GSD_DIR}}", $GsdDir).Replace("{{REPO_ROOT}}", $RepoRoot).Replace("{{BATCH_SIZE}}", "$BatchSize").Replace("{{INTERFACE_CONTEXT}}", $InterfaceContext).Replace("{{FIGMA_PATH}}", "(see interface context above)").Replace("{{FIGMA_VERSION}}", "(multi-interface)")
}
