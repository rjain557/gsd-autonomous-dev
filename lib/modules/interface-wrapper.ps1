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
