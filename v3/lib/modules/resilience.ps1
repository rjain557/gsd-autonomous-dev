<#
.SYNOPSIS
    GSD V3 Resilience - Pre-flight validation, file inventory, retry logic, budget enforcement
.DESCRIPTION
    Validates the project environment before pipeline starts.
    Fixes V2 issues:
    - V2 checked for CLI tools (claude, codex, gemini) that no longer exist in V3
    - V2 pre-flight was fragile (silently continued on missing tools)
    - V2 had no file inventory (couldn't find project files dynamically)
    - V2 had hardcoded paths (Windows-only backslashes, $env:USERPROFILE)
    - V2 didn't validate API key format or connectivity
#>

# ============================================================
# FILE INVENTORY
# ============================================================

function Build-FileInventory {
    <#
    .SYNOPSIS
        Scan the repo to discover ALL project files, organized by type and interface.
        This is the FIRST thing the pipeline does — everything else depends on this.
    .PARAMETER RepoRoot
        Repository root path.
    .PARAMETER GsdDir
        Path to .gsd directory.
    .PARAMETER ExcludePatterns
        Glob patterns to exclude from inventory.
    #>
    param(
        [string]$RepoRoot,
        [string]$GsdDir,
        [array]$ExcludePatterns = @(
            ".gsd", "node_modules", "bin", "obj", "dist", "build",
            ".vs", ".idea", ".git", "*.min.*", "*.bundle.*",
            "package-lock.json", "yarn.lock", ".next", "__pycache__",
            "*.pyc", ".venv", "venv"
        )
    )

    Write-Host "  [INVENTORY] Scanning repository..." -ForegroundColor DarkGray

    $inventory = @{
        timestamp      = (Get-Date -Format "o")
        repo_root      = $RepoRoot
        total_files    = 0
        by_extension   = @{}
        by_directory   = @{}
        by_interface   = @{}
        design_files   = @{}
        spec_files     = @()
        config_files   = @()
        source_files   = @()
        test_files     = @()
        sql_files      = @()
        all_files      = @()
    }

    # Recursively scan
    $allFiles = Get-ChildItem -Path $RepoRoot -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        $relativePath = $_.FullName.Substring($RepoRoot.Length).TrimStart('\', '/')
        $relativePathNorm = $relativePath.Replace('\', '/')

        # Check exclusions
        $excluded = $false
        foreach ($pattern in $ExcludePatterns) {
            if ($relativePathNorm -like "*$pattern*") {
                $excluded = $true
                break
            }
        }
        if ($excluded) { return }

        @{
            FullPath     = $_.FullName
            RelativePath = $relativePathNorm
            Extension    = $_.Extension.ToLower()
            Directory    = (Split-Path $relativePathNorm -Parent).Replace('\', '/')
            Size         = $_.Length
            LastModified = $_.LastWriteTime
        }
    }

    foreach ($file in $allFiles) {
        if (-not $file) { continue }

        $inventory.total_files++
        $inventory.all_files += $file.RelativePath

        # By extension
        $ext = $file.Extension
        if (-not $inventory.by_extension[$ext]) { $inventory.by_extension[$ext] = @() }
        $inventory.by_extension[$ext] += $file.RelativePath

        # By top-level directory
        $topDir = ($file.Directory -split '/')[0]
        if ($topDir) {
            if (-not $inventory.by_directory[$topDir]) { $inventory.by_directory[$topDir] = 0 }
            $inventory.by_directory[$topDir]++
        }

        # Categorize
        $rp = $file.RelativePath

        # Design files (Figma analysis, stubs)
        if ($rp -like "design/*") {
            $parts = $rp -split '/'
            if ($parts.Count -ge 2) {
                $ifaceKey = $parts[1]  # web, mcp-admin, browser, mobile, agent
                if (-not $inventory.design_files[$ifaceKey]) { $inventory.design_files[$ifaceKey] = @() }
                $inventory.design_files[$ifaceKey] += $rp
            }
        }
        # Spec/doc files
        elseif ($rp -like "docs/*" -or $rp -like "specs/*" -or ($ext -in @(".md", ".txt") -and $rp -notlike "src/*")) {
            $inventory.spec_files += $rp
        }
        # Source files
        elseif ($ext -in @(".cs", ".ts", ".tsx", ".js", ".jsx", ".py", ".ps1")) {
            $inventory.source_files += $rp

            # Detect interface from path
            $iface = Get-InterfaceFromPath -RelativePath $rp
            if ($iface) {
                if (-not $inventory.by_interface[$iface]) { $inventory.by_interface[$iface] = @() }
                $inventory.by_interface[$iface] += $rp
            }
        }
        # Test files
        if ($rp -match '\.(test|spec)\.(ts|tsx|js|jsx)$' -or $rp -like "*Tests/*" -or $rp -like "*__tests__/*") {
            $inventory.test_files += $rp
        }
        # SQL files
        if ($ext -eq ".sql") {
            $inventory.sql_files += $rp
        }
        # Config files
        if ($ext -in @(".json", ".yaml", ".yml", ".toml", ".env") -and $rp -notlike "src/*") {
            $inventory.config_files += $rp
        }
    }

    # Save inventory
    $inventoryPath = Join-Path $GsdDir "file-inventory.json"
    $inventory | ConvertTo-Json -Depth 5 | Set-Content $inventoryPath -Encoding UTF8

    # Save tree view
    $treePath = Join-Path $GsdDir "file-map-tree.md"
    $treeContent = Build-FileTree -AllFiles $inventory.all_files -RepoRoot $RepoRoot
    Set-Content $treePath -Value $treeContent -Encoding UTF8

    Write-Host "  [INVENTORY] Found $($inventory.total_files) files across $($inventory.by_directory.Count) directories" -ForegroundColor Green
    foreach ($ext in ($inventory.by_extension.Keys | Sort-Object)) {
        $count = $inventory.by_extension[$ext].Count
        if ($count -gt 5) {
            Write-Host "    $ext : $count files" -ForegroundColor DarkGray
        }
    }

    return $inventory
}

function Get-InterfaceFromPath {
    <#
    .SYNOPSIS
        Determine which interface a file belongs to based on its path.
    #>
    param([string]$RelativePath)

    $rp = $RelativePath.ToLower()

    if ($rp -like "src/web/*")          { return "web" }
    if ($rp -like "src/mcp-admin/*")    { return "mcp-admin" }
    if ($rp -like "src/browser/*")      { return "browser" }
    if ($rp -like "src/mobile/*")       { return "mobile" }
    if ($rp -like "src/mobile-maui/*")  { return "mobile-maui" }
    if ($rp -like "src/agent/*")        { return "agent" }
    if ($rp -like "src/shared/*")       { return "shared" }
    if ($rp -like "backend/*")          { return "backend" }
    if ($rp -like "database/*")         { return "database" }

    return $null
}

function Build-FileTree {
    <#
    .SYNOPSIS
        Generate a markdown tree view of the repository.
    #>
    param(
        [array]$AllFiles,
        [string]$RepoRoot
    )

    $tree = "# File Map - $(Split-Path $RepoRoot -Leaf)`n`n"
    $tree += "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')`n`n"
    $tree += '```' + "`n"

    $dirs = @{}
    foreach ($file in $AllFiles) {
        $parts = $file -split '/'
        $current = ""
        for ($i = 0; $i -lt $parts.Count - 1; $i++) {
            $current = if ($current) { "$current/$($parts[$i])" } else { $parts[$i] }
            if (-not $dirs[$current]) {
                $indent = "  " * $i
                $tree += "${indent}$($parts[$i])/`n"
                $dirs[$current] = $true
            }
        }
        $indent = "  " * ($parts.Count - 1)
        $tree += "${indent}$($parts[-1])`n"
    }

    $tree += '```' + "`n"
    return $tree
}

# ============================================================
# PRE-FLIGHT VALIDATION
# ============================================================

function Test-PreFlightV3 {
    <#
    .SYNOPSIS
        Validate environment before pipeline starts. Fail fast with actionable messages.
    .PARAMETER RepoRoot
        Repository root path.
    .PARAMETER GsdDir
        Path to .gsd directory.
    .PARAMETER Mode
        Pipeline mode (greenfield, bug_fix, feature_update).
    #>
    param(
        [string]$RepoRoot,
        [string]$GsdDir,
        [string]$Mode = "greenfield"
    )

    $checks = @()

    # 1. Repository exists
    $checks += Test-Check "Repo exists" (Test-Path $RepoRoot) "Repository not found: $RepoRoot"

    # 2. API keys present (Get-ApiKey uses throw, so wrap in try/catch)
    $anthropicKey = $null
    $openaiKey = $null
    try { $anthropicKey = Get-ApiKey -Provider "Anthropic" } catch {}
    try { $openaiKey = Get-ApiKey -Provider "OpenAI" } catch {}
    $checks += Test-Check "ANTHROPIC_API_KEY" ($null -ne $anthropicKey) "Set ANTHROPIC_API_KEY environment variable"
    $checks += Test-Check "OPENAI_API_KEY" ($null -ne $openaiKey) "Set OPENAI_API_KEY environment variable"

    # 3. API key format validation (basic)
    if ($anthropicKey) {
        $checks += Test-Check "Anthropic key format" ($anthropicKey -match "^sk-ant-") "ANTHROPIC_API_KEY should start with 'sk-ant-'"
    }

    # 4. Required tools
    $requiredTools = @("git")
    foreach ($tool in $requiredTools) {
        $found = Get-Command $tool -ErrorAction SilentlyContinue
        $checks += Test-Check "$tool available" ($null -ne $found) "Install $tool and ensure it's in PATH"
    }

    # 5. Optional tools (check what's available for local validation)
    $optionalTools = @{
        "dotnet" = ".NET build/test"
        "node"   = "Node.js for TypeScript/React projects"
        "npm"    = "npm for package management"
        "npx"    = "npx for running local tools"
    }
    foreach ($tool in $optionalTools.Keys) {
        $found = Get-Command $tool -ErrorAction SilentlyContinue
        if ($found) {
            Write-Host "    [OK] $tool ($($optionalTools[$tool]))" -ForegroundColor DarkGreen
        }
        else {
            Write-Host "    [--] $tool not found ($($optionalTools[$tool])) - some validators will be skipped" -ForegroundColor DarkGray
        }
    }

    # 6. .gsd directory structure
    $subdirs = @(
        "specs", "requirements", "research", "plans",
        "iterations", "iterations/execution-log", "iterations/build-results", "iterations/reviews",
        "health", "costs", "supervisor", "logs", "cache", "blueprint"
    )
    foreach ($sub in $subdirs) {
        $dir = Join-Path $GsdDir $sub
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }
    $checks += Test-Check ".gsd directory" $true ""

    # 7. Mode-specific checks
    if ($Mode -eq "bug_fix") {
        # Bug fix needs existing requirements-matrix.json
        $matrixPath = Join-Path $GsdDir "requirements/requirements-matrix.json"
        $checks += Test-Check "Requirements matrix exists" (Test-Path $matrixPath) "Run gsd-blueprint first to create initial requirements"
    }
    elseif ($Mode -eq "feature_update") {
        $matrixPath = Join-Path $GsdDir "requirements/requirements-matrix.json"
        $checks += Test-Check "Requirements matrix exists" (Test-Path $matrixPath) "Run gsd-blueprint first to create initial requirements"
    }

    # 8. Git repo check
    $isGitRepo = Test-Path (Join-Path $RepoRoot ".git")
    $checks += Test-Check "Git repository" $isGitRepo "Initialize git: git init"

    # 9. No lock file
    $lockPath = Join-Path $GsdDir ".gsd-lock.json"
    if (Test-Path $lockPath) {
        $lock = Get-Content $lockPath -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
        $lockAge = if ($lock.timestamp) { ((Get-Date) - [datetime]$lock.timestamp).TotalMinutes } else { 999 }

        if ($lockAge -gt 60) {
            Write-Host "    [WARN] Stale lock file (${lockAge}min old), removing..." -ForegroundColor DarkYellow
            Remove-Item $lockPath -Force
        }
        else {
            $checks += Test-Check "No lock file" $false "Another pipeline is running (locked ${lockAge}min ago). Wait or remove $lockPath"
        }
    }

    # Report
    $failed = $checks | Where-Object { -not $_.Passed }
    if ($failed.Count -gt 0) {
        Write-Host "`n  [XX] Pre-flight FAILED:" -ForegroundColor Red
        foreach ($f in $failed) {
            Write-Host "    - $($f.Name): $($f.Fix)" -ForegroundColor Red
        }
        return $false
    }

    Write-Host "  [OK] Pre-flight passed ($($checks.Count) checks)" -ForegroundColor Green
    return $true
}

function Test-Check {
    param([string]$Name, [bool]$Passed, [string]$Fix)
    return @{ Name = $Name; Passed = $Passed; Fix = $Fix }
}

# ============================================================
# API CONNECTIVITY TEST
# ============================================================

function Test-ApiConnectivity {
    <#
    .SYNOPSIS
        Quick API connectivity test (optional, called during pre-flight if --verify-api flag).
    #>
    param()

    Write-Host "  [API] Testing connectivity..." -ForegroundColor DarkGray

    # Test Anthropic
    try {
        $result = Invoke-SonnetApi `
            -SystemPrompt "You are a test." `
            -UserMessage "Respond with exactly: OK" `
            -MaxTokens 5 `
            -Phase "connectivity-test"

        if ($result.Success) {
            Write-Host "    [OK] Anthropic API" -ForegroundColor DarkGreen
        }
        else {
            Write-Host "    [XX] Anthropic API: $($result.Message)" -ForegroundColor Red
            return $false
        }
    }
    catch {
        Write-Host "    [XX] Anthropic API: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }

    # Test OpenAI
    try {
        $result = Invoke-CodexMiniApi `
            -SystemPrompt "You are a test." `
            -UserMessage "Respond with exactly: OK" `
            -MaxTokens 5 `
            -Phase "connectivity-test"

        if ($result.Success) {
            Write-Host "    [OK] OpenAI API" -ForegroundColor DarkGreen
        }
        else {
            Write-Host "    [XX] OpenAI API: $($result.Message)" -ForegroundColor Red
            return $false
        }
    }
    catch {
        Write-Host "    [XX] OpenAI API: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }

    return $true
}

# ============================================================
# LOCK MANAGEMENT
# ============================================================

function New-GsdLock {
    param([string]$GsdDir, [string]$Pipeline = "v3", [string]$Mode = "greenfield")

    $lockPath = Join-Path $GsdDir ".gsd-lock.json"
    @{
        pipeline  = $Pipeline
        mode      = $Mode
        pid       = $PID
        timestamp = (Get-Date -Format "o")
        hostname  = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } elseif ($env:HOSTNAME) { $env:HOSTNAME } else { hostname }
    } | ConvertTo-Json | Set-Content $lockPath -Encoding UTF8
}

function Remove-GsdLock {
    param([string]$GsdDir)

    $lockPath = Join-Path $GsdDir ".gsd-lock.json"
    Remove-Item $lockPath -Force -ErrorAction SilentlyContinue
}

# ============================================================
# CHECKPOINT RECOVERY
# ============================================================

function Save-Checkpoint {
    param(
        [string]$GsdDir,
        [string]$Pipeline = "v3",
        [int]$Iteration,
        [string]$Phase,
        [double]$Health,
        [int]$BatchSize,
        [string]$Status = "running",
        [string]$Mode = "greenfield"
    )

    $checkpoint = @{
        pipeline   = $Pipeline
        mode       = $Mode
        iteration  = $Iteration
        phase      = $Phase
        health     = $Health
        batch_size = $BatchSize
        status     = $Status
        timestamp  = (Get-Date -Format "o")
    }

    $checkpointPath = Join-Path $GsdDir ".gsd-checkpoint.json"
    $checkpoint | ConvertTo-Json | Set-Content $checkpointPath -Encoding UTF8
}

function Get-Checkpoint {
    param([string]$GsdDir)

    $checkpointPath = Join-Path $GsdDir ".gsd-checkpoint.json"
    if (-not (Test-Path $checkpointPath)) { return $null }

    try {
        return Get-Content $checkpointPath -Raw | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Clear-Checkpoint {
    param([string]$GsdDir)

    $checkpointPath = Join-Path $GsdDir ".gsd-checkpoint.json"
    Remove-Item $checkpointPath -Force -ErrorAction SilentlyContinue
}
