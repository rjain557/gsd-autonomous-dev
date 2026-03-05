<#
.SYNOPSIS
    GSD Council Requirements Verification - Partitioned Extract + Cross-Verify
    Run AFTER patch-gsd-partitioned-code-review.ps1.

.DESCRIPTION
    Two-phase council requirements extraction with cross-verification:

    Phase 1 - EXTRACT (partitioned, chunked):
    - PowerShell scans docs/ and design/ for spec files
    - Files are divided into 3 equal partitions (one per agent)
    - Each partition is chunked into batches of ~10 files per LLM call
    - Each agent processes its chunks sequentially, appending results

    Phase 2 - VERIFY (cross-agent):
    - A DIFFERENT agent reviews each extraction against the original files
    - Claude extracts -> Codex verifies
    - Codex extracts -> Gemini verifies
    - Gemini extracts -> Claude verifies
    - Verifier can: add missed requirements, correct statuses, flag false positives

    Phase 3 - SYNTHESIZE:
    - Claude merges all verified outputs into requirements-matrix.json
    - Requirements confirmed by both extractor AND verifier get "high" confidence
    - Requirements added by verifier get "medium" confidence
    - Requirements flagged by verifier get reviewed

.INSTALL_ORDER
    1-35. (existing scripts)
    36. patch-gsd-council-requirements.ps1  <- this file

.NOTES
    Schema changes are additive (backward compatible):
    - New fields per requirement: confidence, found_by, verified_by
    - New meta fields: extraction_method, agents_participated, timestamp
#>

param([string]$UserHome = $env:USERPROFILE)
$ErrorActionPreference = "Stop"

$GsdGlobalDir = Join-Path $UserHome ".gsd-global"

if (-not (Test-Path "$GsdGlobalDir\lib\modules\resilience.ps1")) {
    Write-Host "[XX] Resilience library not found. Run install-gsd-global.ps1 first." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "  GSD Council Requirements Verification" -ForegroundColor Cyan
Write-Host "  Partitioned Extract + Cross-Verify (3 agents)" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""

# ========================================================
# 1. Add council_requirements config
# ========================================================

$configPath = Join-Path $GsdGlobalDir "config\global-config.json"
if (Test-Path $configPath) {
    $config = Get-Content $configPath -Raw | ConvertFrom-Json

    $needsUpdate = $false
    if (-not $config.council_requirements) {
        $config | Add-Member -NotePropertyName "council_requirements" -NotePropertyValue ([PSCustomObject]@{
            enabled                = $true
            agents                 = @("claude", "codex", "gemini")
            min_agents_for_merge   = 2
            chunk_size             = 10
            timeout_seconds        = 600
            cooldown_between_agents = 5
            fallback_to_single     = $true
        })
        $needsUpdate = $true
    } elseif (-not $config.council_requirements.chunk_size) {
        $config.council_requirements | Add-Member -NotePropertyName "chunk_size" -NotePropertyValue 10
        $needsUpdate = $true
    }

    if ($needsUpdate) {
        $config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath -Encoding UTF8
        Write-Host "  [OK] Added/updated council_requirements config" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] council_requirements config already exists" -ForegroundColor DarkGray
    }
}

# ========================================================
# 2. Create prompt templates
# ========================================================

$promptDir = Join-Path $GsdGlobalDir "prompts\council"
if (-not (Test-Path $promptDir)) {
    New-Item -Path $promptDir -ItemType Directory -Force | Out-Null
}

# Template: Chunk extraction (Phase 1)
$chunkExtract = @'
# Requirements Extraction -- Chunk {{CHUNK_NUM}}/{{TOTAL_CHUNKS}} ({{AGENT_NAME}})

You are extracting requirements from a SUBSET of project specification files.
Read ONLY the files listed below and extract every discrete requirement from them.

## Context
- Project: {{REPO_ROOT}}
- GSD dir: {{GSD_DIR}}

{{INTERFACE_CONTEXT}}

## Files To Read (YOUR PARTITION -- read ALL of these completely)
{{FILE_LIST}}

## Also Read (for context only -- do NOT extract requirements from these)
- {{GSD_DIR}}\file-map-tree.md (repo structure, if it exists)

## Scan Source Code For Status
After extracting requirements from the files above, scan the source code to determine
whether each requirement is satisfied, partial, or not_started:
- Look in src\, design\web\v*\src\, or equivalent project directories
- Check for actual implementations, not just file existence

## Output (max 5000 tokens)
Write ONLY a JSON file to {{OUTPUT_PATH}}:

```json
{
  "agent": "{{AGENT_NAME}}",
  "chunk": {{CHUNK_NUM}},
  "total_chunks": {{TOTAL_CHUNKS}},
  "files_read": ["list of files you actually read"],
  "requirements": [
    {
      "id": "{{ID_PREFIX}}-001",
      "description": "One sentence requirement description",
      "source": "spec|figma|compliance|code",
      "spec_doc": "relative/path/to/source-file.md",
      "sdlc_phase": "intake|architecture|phase-c|phase-d|phase-e|phase-f|spec|review",
      "pattern": "backend|frontend|database|integration|security",
      "priority": "high|medium|low",
      "status": "satisfied|partial|not_started",
      "satisfied_by": "path/to/file (if satisfied or partial)",
      "notes": "Brief evidence"
    }
  ],
  "total_found": 0
}
```

Rules:
- Be EXHAUSTIVE -- every missed requirement is a gap that won't get built
- One sentence per description. No prose paragraphs.
- READ actual source files to determine status accurately
- Prefix IDs with {{ID_PREFIX}} (e.g., {{ID_PREFIX}}-001, {{ID_PREFIX}}-002)
- Number IDs starting from {{ID_START}} (e.g., {{ID_PREFIX}}-{{ID_START}})
'@

Set-Content -Path (Join-Path $promptDir "requirements-extract-chunk.md") -Value $chunkExtract -Encoding UTF8
Write-Host "  [OK] Created requirements-extract-chunk.md" -ForegroundColor Green

# Template: Cross-verification (Phase 2)
$verifyTemplate = @'
# Requirements Cross-Verification ({{VERIFIER_NAME}} verifying {{EXTRACTOR_NAME}})

You are VERIFYING requirements extracted by {{EXTRACTOR_NAME}}.
Your job is to read the SAME source spec files and the extraction output, then:
1. CONFIRM correct requirements (mark verified=true)
2. CORRECT wrong statuses (e.g., marked satisfied but code doesn't exist)
3. ADD any requirements that {{EXTRACTOR_NAME}} missed
4. FLAG false positives (requirements that don't actually exist in the specs)

## Context
- Project: {{REPO_ROOT}}
- GSD dir: {{GSD_DIR}}

{{INTERFACE_CONTEXT}}

## Step 1: Read the extraction to verify
{{EXTRACTION_PATH}}

## Step 2: Read the SAME source spec files that were extracted from
{{FILE_LIST}}

## Step 3: Scan source code to verify statuses
- Look in src\, design\web\v*\src\, or equivalent project directories
- Check actual implementations, not just file names

## Output (max 5000 tokens)
Write ONLY a JSON file to {{OUTPUT_PATH}}:

```json
{
  "verifier": "{{VERIFIER_NAME}}",
  "extractor": "{{EXTRACTOR_NAME}}",
  "verified_requirements": [
    {
      "original_id": "CL-001",
      "verified": true,
      "status_corrected": false,
      "new_status": null,
      "notes": "Confirmed - implementation found at path/to/file"
    }
  ],
  "missed_requirements": [
    {
      "id": "VCX-001",
      "description": "Requirement that extractor missed",
      "source": "spec|figma|compliance|code",
      "spec_doc": "relative/path/to/source-file.md",
      "sdlc_phase": "intake|architecture|phase-c|phase-d|phase-e|phase-f|spec|review",
      "pattern": "backend|frontend|database|integration|security",
      "priority": "high|medium|low",
      "status": "satisfied|partial|not_started",
      "satisfied_by": "path/to/file (if satisfied or partial)",
      "notes": "Evidence"
    }
  ],
  "false_positives": ["CL-003", "CL-007"],
  "status_corrections": {
    "CL-005": { "old_status": "satisfied", "new_status": "partial", "reason": "Missing validation logic" }
  },
  "summary": {
    "total_reviewed": 0,
    "confirmed": 0,
    "corrected": 0,
    "missed_added": 0,
    "false_positives_flagged": 0
  }
}
```

Rules:
- Read EVERY spec file listed -- do not skip any
- Be thorough but fair -- only flag genuine misses or errors
- Prefix missed requirement IDs with V{{ID_PREFIX}} (e.g., VCX-001)
- If the extraction is solid, say so -- don't invent problems
'@

Set-Content -Path (Join-Path $promptDir "requirements-verify.md") -Value $verifyTemplate -Encoding UTF8
Write-Host "  [OK] Created requirements-verify.md" -ForegroundColor Green

# Template: Synthesis (merge all verified outputs)
$synthesize = @'
# Council Requirements Synthesis -- Merge Verified Outputs

You are merging requirement extractions from {{AGENT_COUNT}} agents,
each cross-verified by a different agent.

## Agent Extractions (with verification results)
Read ALL of these files:

{{AGENT_OUTPUTS}}

## Your Task
1. **START** with all extracted requirements from each agent
2. **APPLY VERIFIER CORRECTIONS**:
   - Remove false positives flagged by verifiers
   - Update statuses where verifiers corrected them
   - Add missed requirements found by verifiers
3. **DEDUPLICATE**: Merge requirements describing the same thing
4. **ASSIGN SEQUENTIAL IDS**: Renumber as REQ-001, REQ-002, etc.
5. **SCORE CONFIDENCE**:
   - Confirmed by verifier = "high" (extractor + verifier agree)
   - Added by verifier (missed by extractor) = "medium"
   - Status corrected by verifier = "medium"
   - Not verified (verifier failed) = "low"

## Output (max 5000 tokens)
Write the FINAL requirements-matrix.json to {{GSD_DIR}}\health\requirements-matrix.json:

```json
{
  "meta": {
    "total_requirements": 0,
    "satisfied": 0,
    "partial": 0,
    "not_started": 0,
    "health_score": 0,
    "iteration": 0,
    "extraction_method": "council-verified",
    "agents_participated": [],
    "timestamp": "ISO-8601"
  },
  "requirements": [
    {
      "id": "REQ-001",
      "description": "Best description",
      "source": "spec|figma|compliance|code",
      "spec_doc": "docs/X.md",
      "sdlc_phase": "intake|architecture|phase-c|phase-d|phase-e|phase-f|spec|review",
      "pattern": "backend|frontend|database|integration|security",
      "priority": "high|medium|low",
      "status": "satisfied|partial|not_started",
      "satisfied_by": "file path if satisfied",
      "notes": "Evidence notes",
      "confidence": "high|medium|low",
      "found_by": ["extractor_agent"],
      "verified_by": "verifier_agent"
    }
  ]
}
```

Also write {{GSD_DIR}}\health\council-requirements-report.md with:
- Total requirements, confidence breakdown, verification statistics
- Table of corrected statuses and added requirements

Also write {{GSD_DIR}}\health\health-current.json:
```json
{ "health_score": X, "total_requirements": N, "satisfied": N, "partial": N, "not_started": N, "iteration": 0 }
```

Also write {{GSD_DIR}}\health\drift-report.md listing all not_started and partial requirements.

Rules:
- Calculate health_score = (satisfied / total) * 100
- Sort requirements by: sdlc_phase, priority desc, pattern
'@

Set-Content -Path (Join-Path $promptDir "requirements-synthesize.md") -Value $synthesize -Encoding UTF8
Write-Host "  [OK] Created requirements-synthesize.md" -ForegroundColor Green

# Partial synthesis template
$synthesizePartial = @'
# Council Requirements Synthesis -- Partial ({{AGENT_COUNT}} of 3 agents)

You are merging requirement extractions. Only {{AGENT_COUNT}} of 3 agents succeeded.

## Agent Extractions
{{AGENT_OUTPUTS}}

## Missing Agent
{{MISSING_AGENT}} did not complete extraction. Its spec partition was NOT analyzed.
Flag this in the report as a coverage gap.

## Your Task
Same as full synthesis. Write to:
- {{GSD_DIR}}\health\requirements-matrix.json
- {{GSD_DIR}}\health\council-requirements-report.md
- {{GSD_DIR}}\health\health-current.json
- {{GSD_DIR}}\health\drift-report.md
'@

Set-Content -Path (Join-Path $promptDir "requirements-synthesize-partial.md") -Value $synthesizePartial -Encoding UTF8
Write-Host "  [OK] Created requirements-synthesize-partial.md" -ForegroundColor Green

# ========================================================
# 3. Append functions to resilience library
# ========================================================

Write-Host ""
Write-Host "[SCALES] Adding Council Requirements module to resilience library..." -ForegroundColor Yellow

$councilReqCode = @'

# ===============================================================
# GSD COUNCIL REQUIREMENTS MODULE - appended to resilience.ps1
# Partitioned extract + cross-verify: each agent reads 1/3,
# then a different agent verifies the extraction
# ===============================================================

function Get-SpecFiles {
    <#
    .SYNOPSIS
        Scans docs/ and design/ for spec files to partition across agents.
        Returns array of relative file paths.
    #>
    param([string]$RepoRoot)

    $specFiles = @()

    # Scan docs/ recursively for .md files
    $docsDir = Join-Path $RepoRoot "docs"
    if (Test-Path $docsDir) {
        Get-ChildItem -Path $docsDir -Recurse -Filter "*.md" -File | ForEach-Object {
            $rel = $_.FullName.Substring($RepoRoot.Length).TrimStart('\', '/')
            $specFiles += $rel
        }
    }

    # Scan design/ for _analysis .md files (latest version only)
    $designDir = Join-Path $RepoRoot "design"
    if (Test-Path $designDir) {
        $versions = Get-ChildItem -Path $designDir -Recurse -Directory | Where-Object {
            $_.Name -match '^v\d+$'
        } | Sort-Object { [int]($_.Name -replace 'v','') } -Descending

        if ($versions.Count -gt 0) {
            $latestVersion = $versions[0].FullName
            Get-ChildItem -Path $latestVersion -Recurse -Filter "*.md" -File | Where-Object {
                $_.FullName -like "*_analysis*" -or $_.FullName -like "*_stubs*"
            } | ForEach-Object {
                $rel = $_.FullName.Substring($RepoRoot.Length).TrimStart('\', '/')
                $specFiles += $rel
            }
        }
    }

    return $specFiles
}

function Split-IntoChunks {
    <#
    .SYNOPSIS Splits an array into chunks of specified size.
    #>
    param([array]$Items, [int]$ChunkSize = 10)

    $chunks = @()
    for ($i = 0; $i -lt $Items.Count; $i += $ChunkSize) {
        $end = [math]::Min($i + $ChunkSize, $Items.Count)
        $chunk = @($Items[$i..($end - 1)])
        $chunks += ,@($chunk)
    }
    return $chunks
}

function Invoke-CouncilRequirements {
    <#
    .SYNOPSIS
        Two-phase council requirements: partitioned extract + cross-verify.
        Phase 1: Each agent extracts from 1/3 of specs (chunked).
        Phase 2: A different agent verifies each extraction.
        Phase 3: Claude synthesizes all verified outputs.
    .RETURNS
        @{ Success = bool; MatrixPath = string; AgentsSucceeded = int; Error = string }
    #>
    param(
        [string]$RepoRoot,
        [string]$GsdDir,
        [switch]$DryRun,
        [bool]$UseJobs = $false,
        [string]$SkipAgent = "",
        [switch]$SkipVerify
    )

    $result = @{
        Success         = $false
        MatrixPath      = Join-Path $GsdDir "health\requirements-matrix.json"
        AgentsSucceeded = 0
        Error           = ""
    }

    $globalDir = Join-Path $env:USERPROFILE ".gsd-global"
    $promptDir = Join-Path $globalDir "prompts\council"
    $healthDir = Join-Path $GsdDir "health"
    $logDir    = Join-Path $GsdDir "logs"

    foreach ($d in @($healthDir, $logDir)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }

    # Initialize ntfy notifications (so push notifications work standalone)
    if (Get-Command Initialize-GsdNotifications -ErrorAction SilentlyContinue) {
        if (-not $script:NTFY_TOPIC) {
            Initialize-GsdNotifications -GsdGlobalDir $globalDir
        }
    }

    # Load config
    $crConfig = $null
    $configPath = Join-Path $globalDir "config\global-config.json"
    if (Test-Path $configPath) {
        try { $crConfig = (Get-Content $configPath -Raw | ConvertFrom-Json).council_requirements } catch {}
    }
    $timeout   = if ($crConfig -and $crConfig.timeout_seconds) { [int]$crConfig.timeout_seconds } else { 600 }
    $cooldown  = if ($crConfig -and $crConfig.cooldown_between_agents) { [int]$crConfig.cooldown_between_agents } else { 5 }
    $minAgents = if ($crConfig -and $crConfig.min_agents_for_merge) { [int]$crConfig.min_agents_for_merge } else { 2 }
    $chunkSize = if ($crConfig -and $crConfig.chunk_size) { [int]$crConfig.chunk_size } else { 10 }

    # Build interface context
    $InterfaceContext = ""
    if (Get-Command Initialize-ProjectInterfaces -ErrorAction SilentlyContinue) {
        try {
            $ifaceResult = Initialize-ProjectInterfaces -RepoRoot $RepoRoot -GsdDir $GsdDir
            $InterfaceContext = $ifaceResult.Context
        } catch {}
    }

    # Agent definitions with cross-verify assignments
    $agents = @(
        @{ Name = "claude";  Prefix = "CL";  Verifier = "codex";  AllowedTools = "Read,Write,Bash"; GeminiMode = $null }
        @{ Name = "codex";   Prefix = "CX";  Verifier = "gemini"; AllowedTools = $null;             GeminiMode = $null }
        @{ Name = "gemini";  Prefix = "GM";  Verifier = "claude"; AllowedTools = $null;             GeminiMode = "--approval-mode yolo" }
    )

    # Filter out skipped agent and adjust verifier chain
    if ($SkipAgent) {
        $agents = @($agents | Where-Object { $_.Name -ne $SkipAgent })
        # Fix broken verifier chain
        foreach ($agent in $agents) {
            if ($agent.Verifier -eq $SkipAgent) {
                $otherAgent = $agents | Where-Object { $_.Name -ne $agent.Name } | Select-Object -First 1
                $agent.Verifier = $otherAgent.Name
            }
        }
        Write-Host "  [SKIP] $SkipAgent excluded -- running with $($agents.Count) agents" -ForegroundColor DarkYellow
    }

    # Check CLI availability
    $availableAgents = @()
    foreach ($agent in $agents) {
        $cliAvailable = $null -ne (Get-Command $agent.Name -ErrorAction SilentlyContinue)
        if ($cliAvailable) {
            $availableAgents += $agent
        } else {
            Write-Host "  [!!] $($agent.Name) CLI not found -- skipping" -ForegroundColor DarkYellow
        }
    }
    $agents = $availableAgents

    # Fix verifier chain for unavailable agents
    foreach ($agent in $agents) {
        $verifierAvailable = $agents | Where-Object { $_.Name -eq $agent.Verifier }
        if (-not $verifierAvailable) {
            $otherAgent = $agents | Where-Object { $_.Name -ne $agent.Name } | Select-Object -First 1
            if ($otherAgent) { $agent.Verifier = $otherAgent.Name }
        }
    }

    if ($agents.Count -lt $minAgents) {
        $result.Error = "Only $($agents.Count) agents available (need $minAgents)"
        Write-Host "  [XX] $($result.Error)" -ForegroundColor Red
        return $result
    }

    # Scan for spec files
    Write-Host "  [SCAN] Scanning for specification files..." -ForegroundColor Cyan
    $specFiles = @(Get-SpecFiles -RepoRoot $RepoRoot)
    Write-Host "  [SCAN] Found $($specFiles.Count) spec files" -ForegroundColor Cyan

    if ($specFiles.Count -eq 0) {
        $result.Error = "No spec files found in docs/ or design/"
        Write-Host "  [XX] $($result.Error)" -ForegroundColor Red
        return $result
    }

    # Partition files across available agents (round-robin)
    $partitions = @{}
    foreach ($agent in $agents) { $partitions[$agent.Name] = @() }
    for ($i = 0; $i -lt $specFiles.Count; $i++) {
        $agentIndex = $i % $agents.Count
        $partitions[$agents[$agentIndex].Name] += $specFiles[$i]
    }

    foreach ($agent in $agents) {
        $count = $partitions[$agent.Name].Count
        $chunks = [math]::Ceiling($count / $chunkSize)
        Write-Host "  [PARTITION] $($agent.Name): $count files in $chunks chunk(s) -- verified by $($agent.Verifier)" -ForegroundColor DarkGray
    }

    # Update file map
    if (Get-Command Update-FileMap -ErrorAction SilentlyContinue) {
        Update-FileMap -Root $RepoRoot -GsdPath $GsdDir 2>$null | Out-Null
    }

    if ($DryRun) {
        Write-Host "  [DRY RUN] Would dispatch $($agents.Count) agents across $($specFiles.Count) files" -ForegroundColor DarkGray
        Write-Host "  [DRY RUN] Then cross-verify each extraction with a different agent" -ForegroundColor DarkGray
        $result.Success = $true
        return $result
    }

    # Load prompt templates
    $extractTemplatePath = Join-Path $promptDir "requirements-extract-chunk.md"
    $verifyTemplatePath  = Join-Path $promptDir "requirements-verify.md"
    if (-not (Test-Path $extractTemplatePath)) {
        $result.Error = "Prompt template not found: requirements-extract-chunk.md"
        Write-Host "  [XX] $($result.Error)" -ForegroundColor Red
        return $result
    }
    $extractTemplate = Get-Content $extractTemplatePath -Raw
    $verifyTemplate  = if (Test-Path $verifyTemplatePath) { Get-Content $verifyTemplatePath -Raw } else { $null }

    # ================================================================
    # PHASE 1: EXTRACT (parallel -- agents run simultaneously)
    # ================================================================
    Write-Host ""
    Write-Host "  ============================================" -ForegroundColor Cyan
    Write-Host "  PHASE 1: EXTRACT (parallel, partitioned, chunked)" -ForegroundColor Cyan
    Write-Host "  ============================================" -ForegroundColor Cyan

    $agentNames = @($agents | ForEach-Object { $_.Name }) -join ", "
    if (Get-Command Send-GsdNotification -ErrorAction SilentlyContinue) {
        Send-GsdNotification -Title "Council Phase 1: EXTRACT" `
            -Message "$($agents.Count) agents ($agentNames) extracting from $($specFiles.Count) spec files in parallel" `
            -Priority "default" -Tags "rocket"
    }

    $completedAgents = @()
    $failedAgents = @()
    $resiliencePath = Join-Path $env:USERPROFILE ".gsd-global\lib\modules\resilience.ps1"
    $fileTreePath = Join-Path $GsdDir "file-map-tree.md"
    $fileTreeExists = Test-Path $fileTreePath

    # Launch one background job per agent (agents run in parallel, chunks sequential within each)
    $extractJobs = @()
    foreach ($agent in $agents) {
        $agentFiles = @($partitions[$agent.Name])
        if ($agentFiles.Count -eq 0) {
            Write-Host "    $($agent.Name.ToUpper()) -> no files assigned, skipping" -ForegroundColor DarkYellow
            continue
        }

        $totalChunks = [math]::Ceiling($agentFiles.Count / $chunkSize)
        Write-Host "    $($agent.Name.ToUpper()) -> $($agentFiles.Count) files in $totalChunks chunk(s) [LAUNCHING]" -ForegroundColor Magenta

        # Serialize file list as pipe-delimited string (avoids JSON single-item array issues)
        $filesStr = $agentFiles -join "|"

        $job = Start-Job -ScriptBlock {
            param($resPath, $aName, $aPrefix, $aTools, $aGeminiMode,
                  $filesStr, $chunkSz, $cooldownSec, $template,
                  $hDir, $lDir, $rRoot, $gDir, $iCtx, $ftPath, $ftExists)

            try { . $resPath } catch {
                return @{ AgentName = $aName; Success = $false; Error = "Failed to load resilience: $($_.Exception.Message)"; ReqCount = 0; ChunksFailed = 0 }
            }

            $agentFiles = @($filesStr -split '\|')
            $agentChunks = @(Split-IntoChunks -Items $agentFiles -ChunkSize $chunkSz)
            $totalChunks = $agentChunks.Count
            $agentAllReqs = @()
            $chunksFailed = 0
            $idCounter = 1

            for ($c = 0; $c -lt $totalChunks; $c++) {
                $chunkFiles = $agentChunks[$c]
                $chunkNum = $c + 1

                $fileListLines = @()
                foreach ($f in $chunkFiles) {
                    $fullPath = Join-Path $rRoot $f
                    $fileListLines += "- Read: $fullPath"
                }
                $fileList = $fileListLines -join "`n"

                $outputPath = Join-Path $hDir "council-extract-$aName-chunk$chunkNum.json"

                $prompt = $template
                $prompt = $prompt.Replace("{{CHUNK_NUM}}", "$chunkNum")
                $prompt = $prompt.Replace("{{TOTAL_CHUNKS}}", "$totalChunks")
                $prompt = $prompt.Replace("{{AGENT_NAME}}", $aName)
                $prompt = $prompt.Replace("{{REPO_ROOT}}", $rRoot)
                $prompt = $prompt.Replace("{{GSD_DIR}}", $gDir)
                $prompt = $prompt.Replace("{{INTERFACE_CONTEXT}}", $iCtx)
                $prompt = $prompt.Replace("{{FILE_LIST}}", $fileList)
                $prompt = $prompt.Replace("{{OUTPUT_PATH}}", $outputPath)
                $prompt = $prompt.Replace("{{ID_PREFIX}}", $aPrefix)
                $idStart = "{0:D3}" -f $idCounter
                $prompt = $prompt.Replace("{{ID_START}}", $idStart)

                if ($ftExists) {
                    $prompt += "`n`n## Repository File Map`nRead: $ftPath"
                }

                $logFile = Join-Path $lDir "council-requirements-$aName-chunk$chunkNum.log"

                try {
                    $invokeParams = @{
                        Agent   = $aName
                        Prompt  = $prompt
                        Phase   = "council-requirements"
                        LogFile = $logFile
                        CurrentBatchSize = 1
                        GsdDir  = $gDir
                    }
                    if ($aTools) { $invokeParams["AllowedTools"] = $aTools }
                    if ($aGeminiMode) { $invokeParams["GeminiMode"] = $aGeminiMode }

                    Invoke-WithRetry @invokeParams | Out-Null

                    # Read chunk output
                    if (Test-Path $outputPath) {
                        try {
                            $chunkData = Get-Content $outputPath -Raw | ConvertFrom-Json
                            if ($chunkData.requirements) {
                                $reqCount = @($chunkData.requirements).Count
                                $agentAllReqs += @($chunkData.requirements)
                                $idCounter += $reqCount
                            }
                        } catch { $chunksFailed++ }
                    } else {
                        # Try parsing from log
                        if (Test-Path $logFile) {
                            $logContent = Get-Content $logFile -Raw -ErrorAction SilentlyContinue
                            if ($logContent -match '\{[\s\S]*"requirements"\s*:\s*\[[\s\S]*\][\s\S]*\}') {
                                try {
                                    $chunkData = $Matches[0] | ConvertFrom-Json
                                    if ($chunkData.requirements) {
                                        $reqCount = @($chunkData.requirements).Count
                                        $agentAllReqs += @($chunkData.requirements)
                                        $idCounter += $reqCount
                                    }
                                } catch { $chunksFailed++ }
                            } else { $chunksFailed++ }
                        } else { $chunksFailed++ }
                    }
                } catch { $chunksFailed++ }

                if ($c -lt ($totalChunks - 1) -and $cooldownSec -gt 0) {
                    Start-Sleep -Seconds $cooldownSec
                }
            }

            # Write combined agent output to disk
            if ($agentAllReqs.Count -gt 0) {
                $combinedOutput = [PSCustomObject]@{
                    agent         = $aName
                    focus         = "partitioned"
                    requirements  = $agentAllReqs
                    total_found   = $agentAllReqs.Count
                    chunks_total  = $totalChunks
                    chunks_failed = $chunksFailed
                }
                $combinedPath = Join-Path $hDir "council-extract-$aName.json"
                $combinedOutput | ConvertTo-Json -Depth 10 | Set-Content $combinedPath -Encoding UTF8
            }

            return @{
                AgentName    = $aName
                Success      = ($agentAllReqs.Count -gt 0)
                ReqCount     = $agentAllReqs.Count
                ChunksFailed = $chunksFailed
                Error        = ""
            }
        } -ArgumentList @(
            $resiliencePath, $agent.Name, $agent.Prefix,
            $agent.AllowedTools, $agent.GeminiMode,
            $filesStr, $chunkSize, $cooldown, $extractTemplate,
            $healthDir, $logDir, $RepoRoot, $GsdDir, $InterfaceContext,
            $fileTreePath, $fileTreeExists
        )

        $extractJobs += @{ Job = $job; Agent = $agent }
    }

    # Wait for all extraction jobs with live progress monitoring
    if ($extractJobs.Count -gt 0) {
        $maxChunksPerAgent = [math]::Max(1, [math]::Ceiling($specFiles.Count / ([math]::Max(1, $agents.Count) * $chunkSize)))
        $totalTimeout = ($timeout * $maxChunksPerAgent) + 120
        Write-Host ""
        Write-Host "  Waiting for $($extractJobs.Count) parallel agents (timeout: ~${totalTimeout}s)..." -ForegroundColor DarkGray

        # Poll for progress by watching chunk output files on disk
        $allJobs = @($extractJobs | ForEach-Object { $_.Job })
        $pollInterval = 15
        $elapsed = 0
        $lastSeen = @{}
        foreach ($ej in $extractJobs) { $lastSeen[$ej.Agent.Name] = 0 }

        while ($elapsed -lt $totalTimeout) {
            $running = @($allJobs | Where-Object { $_.State -eq "Running" })
            if ($running.Count -eq 0) { break }

            Start-Sleep -Seconds $pollInterval
            $elapsed += $pollInterval

            # Check each agent for new chunk files
            foreach ($ej in $extractJobs) {
                $aName = $ej.Agent.Name
                if ($ej.Job.State -ne "Running") { continue }
                $chunkFiles = @(Get-ChildItem -Path $healthDir -Filter "council-extract-$aName-chunk*.json" -ErrorAction SilentlyContinue)
                $currentChunks = $chunkFiles.Count
                if ($currentChunks -gt $lastSeen[$aName]) {
                    $totalExpected = [math]::Ceiling($partitions[$aName].Count / $chunkSize)
                    $reqsSoFar = 0
                    foreach ($cf in $chunkFiles) {
                        try {
                            $cd = Get-Content $cf.FullName -Raw | ConvertFrom-Json
                            if ($cd.requirements) { $reqsSoFar += @($cd.requirements).Count }
                        } catch {}
                    }
                    Write-Host "    [PROGRESS] ${aName}: chunk $currentChunks/$totalExpected done ($reqsSoFar reqs so far) [${elapsed}s]" -ForegroundColor DarkCyan
                    if (Get-Command Send-GsdNotification -ErrorAction SilentlyContinue) {
                        Send-GsdNotification -Title "Extract: ${aName} chunk $currentChunks/$totalExpected" `
                            -Message "$reqsSoFar requirements so far (${elapsed}s elapsed)" `
                            -Priority "low" -Tags "mag"
                    }
                    $lastSeen[$aName] = $currentChunks
                }
            }

            # Show per-agent heartbeat every 60s with chunk counts and working indicators
            if (($elapsed % 60) -lt $pollInterval) {
                $statusParts = @()
                foreach ($ej in $extractJobs) {
                    $aName = $ej.Agent.Name
                    $totalExpected = [math]::Ceiling($partitions[$aName].Count / $chunkSize)
                    $doneChunks = $lastSeen[$aName]
                    $state = $ej.Job.State
                    if ($state -eq "Running") {
                        # Check for log files as "working" indicator (log created before chunk completes)
                        $logFiles = @(Get-ChildItem -Path $logDir -Filter "council-requirements-$aName-chunk*.log" -ErrorAction SilentlyContinue)
                        $activeChunk = $logFiles.Count
                        if ($activeChunk -gt $doneChunks) {
                            $statusParts += "${aName}: chunk $doneChunks/$totalExpected done (working on chunk $activeChunk)"
                        } else {
                            # Check if agent process is alive
                            $agentProc = Get-Process -Name $aName -ErrorAction SilentlyContinue
                            $procStatus = if ($agentProc) { "process alive" } else { "waiting" }
                            $statusParts += "${aName}: chunk $doneChunks/$totalExpected done ($procStatus)"
                        }
                    } else {
                        $statusParts += "${aName}: $state ($doneChunks/$totalExpected)"
                    }
                }
                Write-Host "    [HEARTBEAT] ${elapsed}s -- $($statusParts -join ' | ')" -ForegroundColor DarkGray
            }
        }

        # Final check for stragglers
        $stillRunning = @($allJobs | Where-Object { $_.State -eq "Running" })
        if ($stillRunning.Count -gt 0) {
            Write-Host "    [TIMEOUT] $($stillRunning.Count) job(s) still running after ${totalTimeout}s -- stopping" -ForegroundColor DarkYellow
            $stillRunning | Stop-Job -ErrorAction SilentlyContinue
        }

        foreach ($ej in $extractJobs) {
            $agentName = $ej.Agent.Name

            if ($ej.Job.State -eq "Completed") {
                $jobResult = Receive-Job -Job $ej.Job
                if ($jobResult.Success) {
                    Write-Host "    [PASS] ${agentName}: $($jobResult.ReqCount) requirements ($($jobResult.ChunksFailed) chunk failures)" -ForegroundColor Green
                    $completedAgents += $agentName
                } else {
                    $errMsg = if ($jobResult.Error) { $jobResult.Error } else { "no requirements extracted" }
                    Write-Host "    [FAIL] ${agentName}: $errMsg" -ForegroundColor Red
                    $failedAgents += $agentName
                }
            } else {
                Write-Host "    [FAIL] ${agentName}: job state=$($ej.Job.State) (timeout or error)" -ForegroundColor Red
                $failedAgents += $agentName
                # Check if partial results were written to disk before timeout
                $partialPath = Join-Path $healthDir "council-extract-$agentName.json"
                if (Test-Path $partialPath) {
                    try {
                        $pd = Get-Content $partialPath -Raw | ConvertFrom-Json
                        if ($pd.requirements -and @($pd.requirements).Count -gt 0) {
                            Write-Host "    [PARTIAL] ${agentName}: $(@($pd.requirements).Count) requirements recovered from disk" -ForegroundColor DarkYellow
                            $completedAgents += $agentName
                            $failedAgents = @($failedAgents | Where-Object { $_ -ne $agentName })
                        }
                    } catch {}
                }
            }
            Remove-Job -Job $ej.Job -Force -ErrorAction SilentlyContinue
        }
    }

    $result.AgentsSucceeded = $completedAgents.Count
    Write-Host ""
    Write-Host "  Phase 1 complete: $($completedAgents.Count)/$($agents.Count) agents succeeded" -ForegroundColor Cyan

    if (Get-Command Send-GsdNotification -ErrorAction SilentlyContinue) {
        $p1Tag = if ($completedAgents.Count -eq $agents.Count) { "white_check_mark" } else { "warning" }
        $p1Details = @()
        foreach ($a in $completedAgents) { $p1Details += "$a OK" }
        foreach ($a in $failedAgents) { $p1Details += "$a FAILED" }
        $p1Cost = ""
        if (Get-Command Get-CostNotificationText -ErrorAction SilentlyContinue) {
            $p1Cost = Get-CostNotificationText -GsdDir $GsdDir -Detailed
        }
        $p1Msg = ($p1Details -join " | ")
        if ($p1Cost) { $p1Msg += "`n$p1Cost" }
        Send-GsdNotification -Title "Phase 1 Done: $($completedAgents.Count)/$($agents.Count) agents" `
            -Message $p1Msg -Priority "default" -Tags $p1Tag
    }

    if ($completedAgents.Count -eq 0) {
        $result.Error = "No agent produced valid requirement output"
        Write-Host "  [XX] $($result.Error)" -ForegroundColor Red
        return $result
    }

    # ================================================================
    # PHASE 2: CROSS-VERIFY (parallel -- verifiers run simultaneously)
    # ================================================================
    $verifiedAgents = @()

    if (-not $SkipVerify -and $verifyTemplate -and $completedAgents.Count -ge 2) {
        Write-Host ""
        Write-Host "  ============================================" -ForegroundColor Yellow
        Write-Host "  PHASE 2: CROSS-VERIFY (parallel)" -ForegroundColor Yellow
        Write-Host "  ============================================" -ForegroundColor Yellow

        if (Get-Command Send-GsdNotification -ErrorAction SilentlyContinue) {
            Send-GsdNotification -Title "Council Phase 2: CROSS-VERIFY" `
                -Message "$($completedAgents.Count) extractions being cross-verified in parallel" `
                -Priority "default" -Tags "eyes"
        }

        $verifyJobs = @()
        foreach ($agent in $agents) {
            if ($agent.Name -notin $completedAgents) { continue }

            $verifierName = $agent.Verifier
            $verifierAvailable = $null -ne (Get-Command $verifierName -ErrorAction SilentlyContinue)
            if (-not $verifierAvailable) {
                Write-Host "    [SKIP] Cannot verify $($agent.Name) -- $verifierName not available" -ForegroundColor DarkYellow
                continue
            }

            $extractionPath = Join-Path $healthDir "council-extract-$($agent.Name).json"
            if (-not (Test-Path $extractionPath)) { continue }

            # Build file list of the same spec files
            $agentFiles = @($partitions[$agent.Name])
            $fileListLines = @()
            foreach ($f in $agentFiles) {
                $fullPath = Join-Path $RepoRoot $f
                $fileListLines += "- Read: $fullPath"
            }
            $fileList = $fileListLines -join "`n"

            $verifyOutputPath = Join-Path $healthDir "council-verify-$($agent.Name)-by-$verifierName.json"

            $verifierAgent = $agents | Where-Object { $_.Name -eq $verifierName }
            $vPrefix = if ($verifierAgent) { $verifierAgent.Prefix } else { "V" }
            $vTools = if ($verifierAgent) { $verifierAgent.AllowedTools } else { $null }
            $vGemini = if ($verifierAgent) { $verifierAgent.GeminiMode } else { $null }

            $prompt = $verifyTemplate
            $prompt = $prompt.Replace("{{VERIFIER_NAME}}", $verifierName)
            $prompt = $prompt.Replace("{{EXTRACTOR_NAME}}", $agent.Name)
            $prompt = $prompt.Replace("{{REPO_ROOT}}", $RepoRoot)
            $prompt = $prompt.Replace("{{GSD_DIR}}", $GsdDir)
            $prompt = $prompt.Replace("{{INTERFACE_CONTEXT}}", $InterfaceContext)
            $prompt = $prompt.Replace("{{EXTRACTION_PATH}}", "Read: $extractionPath")
            $prompt = $prompt.Replace("{{FILE_LIST}}", $fileList)
            $prompt = $prompt.Replace("{{OUTPUT_PATH}}", $verifyOutputPath)
            $prompt = $prompt.Replace("{{ID_PREFIX}}", $vPrefix)

            Write-Host "    $($verifierName.ToUpper()) verifying $($agent.Name)'s extraction [LAUNCHING]" -ForegroundColor Yellow

            $job = Start-Job -ScriptBlock {
                param($resPath, $vName, $vToolsArg, $vGeminiArg, $promptText,
                      $vLogFile, $gDir, $vOutPath, $extractorName)

                try { . $resPath } catch {
                    return @{ ExtractorName = $extractorName; Success = $false; Error = "Failed to load resilience: $($_.Exception.Message)" }
                }

                try {
                    $invokeParams = @{
                        Agent   = $vName
                        Prompt  = $promptText
                        Phase   = "council-verify"
                        LogFile = $vLogFile
                        CurrentBatchSize = 1
                        GsdDir  = $gDir
                    }
                    if ($vToolsArg) { $invokeParams["AllowedTools"] = $vToolsArg }
                    if ($vGeminiArg) { $invokeParams["GeminiMode"] = $vGeminiArg }

                    Invoke-WithRetry @invokeParams | Out-Null

                    if (Test-Path $vOutPath) {
                        try {
                            $verifyData = Get-Content $vOutPath -Raw | ConvertFrom-Json
                            $confirmed = if ($verifyData.summary) { $verifyData.summary.confirmed } else { 0 }
                            $missed    = if ($verifyData.missed_requirements) { @($verifyData.missed_requirements).Count } else { 0 }
                            $corrected = if ($verifyData.summary) { $verifyData.summary.corrected } else { 0 }
                            $flagged   = if ($verifyData.false_positives) { @($verifyData.false_positives).Count } else { 0 }
                            return @{ ExtractorName = $extractorName; Success = $true; Confirmed = $confirmed; Missed = $missed; Corrected = $corrected; Flagged = $flagged; Error = "" }
                        } catch {
                            return @{ ExtractorName = $extractorName; Success = $false; Error = "invalid JSON output" }
                        }
                    } else {
                        # Try parsing from log
                        if (Test-Path $vLogFile) {
                            $logContent = Get-Content $vLogFile -Raw -ErrorAction SilentlyContinue
                            if ($logContent -match '\{[\s\S]*"verified_requirements"\s*:\s*\[[\s\S]*\][\s\S]*\}') {
                                try {
                                    $verifyData = $Matches[0] | ConvertFrom-Json
                                    $verifyData | ConvertTo-Json -Depth 10 | Set-Content $vOutPath -Encoding UTF8
                                    return @{ ExtractorName = $extractorName; Success = $true; Confirmed = 0; Missed = 0; Corrected = 0; Flagged = 0; Error = "" }
                                } catch {}
                            }
                        }
                        return @{ ExtractorName = $extractorName; Success = $false; Error = "no output file produced" }
                    }
                } catch {
                    return @{ ExtractorName = $extractorName; Success = $false; Error = $_.Exception.Message }
                }
            } -ArgumentList @(
                $resiliencePath, $verifierName, $vTools, $vGemini, $prompt,
                (Join-Path $logDir "council-verify-$($agent.Name)-by-$verifierName.log"),
                $GsdDir, $verifyOutputPath, $agent.Name
            )

            $verifyJobs += @{ Job = $job; Agent = $agent; Verifier = $verifierName }
        }

        # Wait for all verification jobs with progress monitoring
        if ($verifyJobs.Count -gt 0) {
            $verifyTimeout = $timeout + 120
            Write-Host ""
            Write-Host "  Waiting for $($verifyJobs.Count) parallel verifiers (timeout: ${verifyTimeout}s)..." -ForegroundColor DarkGray

            $allVJobs = @($verifyJobs | ForEach-Object { $_.Job })
            $vElapsed = 0
            $vPoll = 15
            $vSeen = @{}

            while ($vElapsed -lt $verifyTimeout) {
                $vRunning = @($allVJobs | Where-Object { $_.State -eq "Running" })
                if ($vRunning.Count -eq 0) { break }

                Start-Sleep -Seconds $vPoll
                $vElapsed += $vPoll

                # Check for completed verification output files
                foreach ($vj in $verifyJobs) {
                    $eName = $vj.Agent.Name
                    $vName = $vj.Verifier
                    $vKey = "$eName-by-$vName"
                    if ($vSeen[$vKey]) { continue }
                    if ($vj.Job.State -ne "Running") {
                        if (-not $vSeen[$vKey]) {
                            Write-Host "    [PROGRESS] ${vName} verifying ${eName}: completed [${vElapsed}s]" -ForegroundColor DarkCyan
                            $vSeen[$vKey] = $true
                        }
                        continue
                    }
                    $vOutFile = Join-Path $healthDir "council-verify-$eName-by-$vName.json"
                    if (Test-Path $vOutFile) {
                        Write-Host "    [PROGRESS] ${vName} verifying ${eName}: output written [${vElapsed}s]" -ForegroundColor DarkCyan
                        $vSeen[$vKey] = $true
                    }
                }

                # Heartbeat every 60s
                if (($vElapsed % 60) -lt $vPoll) {
                    $vStates = @($verifyJobs | ForEach-Object { "$($_.Verifier)->$($_.Agent.Name)=$($_.Job.State)" })
                    Write-Host "    [HEARTBEAT] ${vElapsed}s elapsed -- $($vStates -join ', ')" -ForegroundColor DarkGray
                }
            }

            $vStillRunning = @($allVJobs | Where-Object { $_.State -eq "Running" })
            if ($vStillRunning.Count -gt 0) {
                Write-Host "    [TIMEOUT] $($vStillRunning.Count) verifier(s) still running -- stopping" -ForegroundColor DarkYellow
                $vStillRunning | Stop-Job -ErrorAction SilentlyContinue
            }

            foreach ($vj in $verifyJobs) {
                $extractorName = $vj.Agent.Name
                $verifierName = $vj.Verifier

                if ($vj.Job.State -eq "Completed") {
                    $vjResult = Receive-Job -Job $vj.Job
                    if ($vjResult.Success) {
                        Write-Host "    [OK] ${verifierName} verified ${extractorName}: $($vjResult.Confirmed) confirmed, $($vjResult.Missed) missed, $($vjResult.Corrected) corrected, $($vjResult.Flagged) flagged" -ForegroundColor Green
                        $verifiedAgents += $extractorName
                    } else {
                        Write-Host "    [WARN] ${verifierName} verify of ${extractorName}: $($vjResult.Error) -- extraction accepted as-is" -ForegroundColor DarkYellow
                    }
                } else {
                    Write-Host "    [WARN] ${verifierName} verify of ${extractorName}: job $($vj.Job.State) -- extraction accepted as-is" -ForegroundColor DarkYellow
                    # Check if output was written to disk before timeout
                    $vOutCheck = Join-Path $healthDir "council-verify-$extractorName-by-$verifierName.json"
                    if (Test-Path $vOutCheck) {
                        Write-Host "    [PARTIAL] Verification output found on disk" -ForegroundColor DarkYellow
                        $verifiedAgents += $extractorName
                    }
                }
                Remove-Job -Job $vj.Job -Force -ErrorAction SilentlyContinue
            }
        }

        Write-Host ""
        Write-Host "  Phase 2 complete: $($verifiedAgents.Count)/$($completedAgents.Count) extractions verified" -ForegroundColor Yellow
        if (Get-Command Send-GsdNotification -ErrorAction SilentlyContinue) {
            $p2Cost = ""
            if (Get-Command Get-CostNotificationText -ErrorAction SilentlyContinue) {
                $p2Cost = Get-CostNotificationText -GsdDir $GsdDir -Detailed
            }
            $p2Msg = "Cross-verification complete"
            if ($p2Cost) { $p2Msg += "`n$p2Cost" }
            Send-GsdNotification -Title "Phase 2 Done: $($verifiedAgents.Count)/$($completedAgents.Count) verified" `
                -Message $p2Msg -Priority "default" -Tags "white_check_mark"
        }
    } else {
        if ($SkipVerify) {
            Write-Host ""
            Write-Host "  [SKIP] Phase 2 (verification) skipped by user" -ForegroundColor DarkYellow
        }
    }

    # ================================================================
    # PHASE 3: SYNTHESIS (Claude merges all verified outputs)
    # ================================================================
    Write-Host ""
    Write-Host "  ============================================" -ForegroundColor Green
    Write-Host "  PHASE 3: SYNTHESIZE" -ForegroundColor Green
    Write-Host "  ============================================" -ForegroundColor Green

    if (Get-Command Send-GsdNotification -ErrorAction SilentlyContinue) {
        Send-GsdNotification -Title "Council Phase 3: SYNTHESIZE" `
            -Message "Merging $($completedAgents.Count) agent outputs into requirements matrix" `
            -Priority "default" -Tags "gear"
    }

    # Collect outputs for synthesis
    $agentOutputs = @{}
    foreach ($agentName in $completedAgents) {
        $extractPath = Join-Path $healthDir "council-extract-$agentName.json"
        if (Test-Path $extractPath) {
            try {
                $parsed = Get-Content $extractPath -Raw | ConvertFrom-Json
                if ($parsed.requirements -and @($parsed.requirements).Count -gt 0) {
                    $agentOutputs[$agentName] = $parsed
                    Write-Host "    ${agentName}: $(@($parsed.requirements).Count) requirements" -ForegroundColor DarkGray
                }
            } catch {}
        }
    }

    if ($agentOutputs.Count -eq 0) {
        $result.Error = "No agent produced valid requirement output"
        Write-Host "  [XX] $($result.Error)" -ForegroundColor Red
        return $result
    }

    Write-Host "  [SCALES] Claude synthesizing merged requirements matrix..." -ForegroundColor Cyan

    $isPartial = $agentOutputs.Count -lt $agents.Count
    $synthTemplateName = if ($isPartial) { "requirements-synthesize-partial.md" } else { "requirements-synthesize.md" }
    $synthTemplatePath = Join-Path $promptDir $synthTemplateName

    if (-not (Test-Path $synthTemplatePath)) {
        $synthTemplatePath = Join-Path $promptDir "requirements-synthesize.md"
    }

    $synthPrompt = if (Test-Path $synthTemplatePath) {
        (Get-Content $synthTemplatePath -Raw)
    } else {
        "Read the agent extraction files below. Merge and write requirements-matrix.json to {{GSD_DIR}}\health\requirements-matrix.json"
    }

    $synthPrompt = $synthPrompt.Replace("{{GSD_DIR}}", $GsdDir)
    $synthPrompt = $synthPrompt.Replace("{{AGENT_COUNT}}", "$($agentOutputs.Count)")

    # Build agent output section (extractions + verification results)
    $outputSection = ""
    foreach ($agentName in $agentOutputs.Keys) {
        $extractPath = Join-Path $healthDir "council-extract-$agentName.json"
        if (Test-Path $extractPath) {
            $outputSection += "`n## $($agentName.ToUpper()) Extraction`nRead: $extractPath`n"
        }
        # Include verification results if they exist
        $verifyFiles = Get-ChildItem -Path $healthDir -Filter "council-verify-$agentName-by-*.json" -ErrorAction SilentlyContinue
        foreach ($vf in $verifyFiles) {
            $outputSection += "`n## Verification of $($agentName.ToUpper())`nRead: $($vf.FullName)`n"
        }
    }
    $synthPrompt = $synthPrompt.Replace("{{AGENT_OUTPUTS}}", $outputSection)

    if ($isPartial) {
        $allAgentNames = @($agents | ForEach-Object { $_.Name })
        $missing = @($allAgentNames | Where-Object { $_ -notin $agentOutputs.Keys })
        $synthPrompt = $synthPrompt.Replace("{{MISSING_AGENT}}", ($missing -join ", "))
    }

    $synthLogFile = Join-Path $logDir "council-requirements-synthesis.log"

    $synthResult = Invoke-WithRetry -Agent "claude" -Prompt $synthPrompt -Phase "council-requirements-synthesis" `
        -LogFile $synthLogFile -MaxAttempts 2 -CurrentBatchSize 1 -GsdDir $GsdDir `
        -AllowedTools "Read,Write"

    # Verify matrix was written
    $matrixPath = Join-Path $healthDir "requirements-matrix.json"
    if (Test-Path $matrixPath) {
        try {
            $matrix = Get-Content $matrixPath -Raw | ConvertFrom-Json
            if ($matrix.requirements -and @($matrix.requirements).Count -gt 0) {
                $result.Success = $true
                Write-Host "  [OK] Requirements matrix: $(@($matrix.requirements).Count) requirements" -ForegroundColor Green
                Write-Host "  [OK] Health: $($matrix.meta.health_score)%" -ForegroundColor Green
            } else {
                Write-Host "  [WARN] Synthesis produced empty matrix -- trying local merge" -ForegroundColor DarkYellow
                $localResult = Merge-CouncilRequirementsLocal -AgentOutputs $agentOutputs -GsdDir $GsdDir
                $result.Success = $localResult.Success
            }
        } catch {
            Write-Host "  [WARN] Matrix file invalid -- trying local merge" -ForegroundColor DarkYellow
            $localResult = Merge-CouncilRequirementsLocal -AgentOutputs $agentOutputs -GsdDir $GsdDir
            $result.Success = $localResult.Success
        }
    } else {
        Write-Host "  [WARN] Synthesis did not write matrix -- trying local merge" -ForegroundColor DarkYellow
        $localResult = Merge-CouncilRequirementsLocal -AgentOutputs $agentOutputs -GsdDir $GsdDir
        $result.Success = $localResult.Success
    }

    # Final ntfy notification with cost summary
    if (Get-Command Send-GsdNotification -ErrorAction SilentlyContinue) {
        $finalCost = ""
        if (Get-Command Get-CostNotificationText -ErrorAction SilentlyContinue) {
            $finalCost = Get-CostNotificationText -GsdDir $GsdDir -Detailed
        }
        if ($result.Success) {
            $reqCount = 0
            try { $reqCount = @((Get-Content (Join-Path $healthDir "requirements-matrix.json") -Raw | ConvertFrom-Json).requirements).Count } catch {}
            $finalMsg = "Requirements matrix: $reqCount requirements"
            if ($finalCost) { $finalMsg += "`n$finalCost" }
            Send-GsdNotification -Title "Council COMPLETE" `
                -Message $finalMsg -Priority "high" -Tags "tada"
        } else {
            $finalMsg = "Error: $($result.Error)"
            if ($finalCost) { $finalMsg += "`n$finalCost" }
            Send-GsdNotification -Title "Council FAILED" `
                -Message $finalMsg -Priority "high" -Tags "x"
        }
    }

    return $result
}


function Merge-CouncilRequirementsLocal {
    <#
    .SYNOPSIS
        Local PowerShell fallback: merges agent outputs using token-overlap deduplication
        when the Claude synthesis agent fails or produces invalid output.
    #>
    param(
        [hashtable]$AgentOutputs,
        [string]$GsdDir
    )

    $result = @{ Success = $false }

    $allReqs = @()
    foreach ($agentName in $AgentOutputs.Keys) {
        $output = $AgentOutputs[$agentName]
        foreach ($req in @($output.requirements)) {
            $allReqs += @{
                Agent       = $agentName
                Description = $req.description
                Source      = $req.source
                SpecDoc     = $req.spec_doc
                SdlcPhase   = $req.sdlc_phase
                Pattern     = $req.pattern
                Priority    = $req.priority
                Status      = $req.status
                SatisfiedBy = $req.satisfied_by
                Notes       = $req.notes
            }
        }
    }

    if ($allReqs.Count -eq 0) {
        Write-Host "  [XX] No requirements to merge" -ForegroundColor Red
        return $result
    }

    # Deduplication via Jaccard similarity
    $groups = @()
    $assigned = @{}

    for ($i = 0; $i -lt $allReqs.Count; $i++) {
        if ($assigned.ContainsKey($i)) { continue }
        $group = @($allReqs[$i])
        $assigned[$i] = $true

        $descA = $allReqs[$i].Description.ToLower() -replace '[^a-z0-9\s]', ''
        $tokensA = @($descA -split '\s+' | Where-Object { $_.Length -gt 2 })

        for ($j = $i + 1; $j -lt $allReqs.Count; $j++) {
            if ($assigned.ContainsKey($j)) { continue }
            $descB = $allReqs[$j].Description.ToLower() -replace '[^a-z0-9\s]', ''
            $tokensB = @($descB -split '\s+' | Where-Object { $_.Length -gt 2 })

            if ($tokensA.Count -gt 0 -and $tokensB.Count -gt 0) {
                $setA = [System.Collections.Generic.HashSet[string]]::new([string[]]$tokensA)
                $setB = [System.Collections.Generic.HashSet[string]]::new([string[]]$tokensB)
                $intersection = [System.Collections.Generic.HashSet[string]]::new($setA)
                $intersection.IntersectWith($setB)
                $union = [System.Collections.Generic.HashSet[string]]::new($setA)
                $union.UnionWith($setB)
                $similarity = if ($union.Count -gt 0) { $intersection.Count / $union.Count } else { 0 }
                if ($similarity -gt 0.5) {
                    $group += $allReqs[$j]
                    $assigned[$j] = $true
                }
            }
        }
        $groups += ,@($group)
    }

    $mergedReqs = @()
    $reqNum = 1
    $priorityRank = @{ "high" = 3; "medium" = 2; "low" = 1 }
    $statusRank   = @{ "not_started" = 3; "partial" = 2; "satisfied" = 1 }

    foreach ($group in $groups) {
        $bestDesc = ($group | Sort-Object { $_.Description.Length } -Descending | Select-Object -First 1).Description
        $bestStatus = "satisfied"
        foreach ($member in $group) {
            $s = $member.Status
            if ($s -and $statusRank.ContainsKey($s) -and $statusRank[$s] -gt $statusRank[$bestStatus]) { $bestStatus = $s }
        }
        $bestPriority = "low"
        foreach ($member in $group) {
            $p = $member.Priority
            if ($p -and $priorityRank.ContainsKey($p) -and $priorityRank[$p] -gt $priorityRank[$bestPriority]) { $bestPriority = $p }
        }
        $foundBy = @($group | ForEach-Object { $_.Agent } | Select-Object -Unique)
        $confidence = switch ($foundBy.Count) { 3 { "high" } 2 { "medium" } default { "low" } }

        $id = "REQ-{0:D3}" -f $reqNum
        $mergedReqs += [PSCustomObject]@{
            id           = $id
            description  = $bestDesc
            source       = ($group[0].Source)
            spec_doc     = ($group[0].SpecDoc)
            sdlc_phase   = ($group[0].SdlcPhase)
            pattern      = ($group[0].Pattern)
            priority     = $bestPriority
            status       = $bestStatus
            satisfied_by = ($group | Where-Object { $_.SatisfiedBy } | Select-Object -First 1 -ExpandProperty SatisfiedBy)
            notes        = ($group | Where-Object { $_.Notes } | Select-Object -First 1 -ExpandProperty Notes)
            confidence   = $confidence
            found_by     = $foundBy
        }
        $reqNum++
    }

    $total = $mergedReqs.Count
    $satisfied = @($mergedReqs | Where-Object { $_.status -eq "satisfied" }).Count
    $partial = @($mergedReqs | Where-Object { $_.status -eq "partial" }).Count
    $notStarted = @($mergedReqs | Where-Object { $_.status -eq "not_started" }).Count
    $healthScore = if ($total -gt 0) { [math]::Round(($satisfied / $total) * 100, 1) } else { 0 }

    $matrix = [PSCustomObject]@{
        meta = [PSCustomObject]@{
            total_requirements  = $total; satisfied = $satisfied; partial = $partial
            not_started = $notStarted; health_score = $healthScore; iteration = 0
            extraction_method   = "council-local-merge"
            agents_participated = @($AgentOutputs.Keys | Sort-Object)
            timestamp           = (Get-Date).ToUniversalTime().ToString("o")
        }
        requirements = $mergedReqs
    }

    $matrixPath = Join-Path $GsdDir "health\requirements-matrix.json"
    $matrix | ConvertTo-Json -Depth 10 | Set-Content $matrixPath -Encoding UTF8

    $healthPath = Join-Path $GsdDir "health\health-current.json"
    @{ health_score = $healthScore; total_requirements = $total; satisfied = $satisfied; partial = $partial; not_started = $notStarted; iteration = 0 } | ConvertTo-Json | Set-Content $healthPath -Encoding UTF8

    $high = @($mergedReqs | Where-Object { $_.confidence -eq "high" }).Count
    $med = @($mergedReqs | Where-Object { $_.confidence -eq "medium" }).Count
    $low = @($mergedReqs | Where-Object { $_.confidence -eq "low" }).Count

    $report = @(
        "# Council Requirements Report (Local Merge)", ""
        "| Metric | Value |", "|--------|-------|"
        "| Total requirements | $total |", "| High confidence | $high |"
        "| Medium confidence | $med |", "| Low confidence | $low |"
        "| Agents participated | $($AgentOutputs.Keys -join ', ') |"
        "| Health score | ${healthScore}% |", ""
    )
    $reportPath = Join-Path $GsdDir "health\council-requirements-report.md"
    ($report -join "`n") | Set-Content $reportPath -Encoding UTF8

    Write-Host "  [OK] Local merge: $total requirements (${healthScore}% health)" -ForegroundColor Green
    $result.Success = $true
    return $result
}

Write-Host "  Council Requirements module loaded." -ForegroundColor DarkGray
'@

# Replace or append to resilience library
$resiliencePath = "$GsdGlobalDir\lib\modules\resilience.ps1"
$existingResilience = Get-Content $resiliencePath -Raw

if ($existingResilience -like "*function Invoke-CouncilRequirements*") {
    $startIdx = $existingResilience.IndexOf("# GSD COUNCIL REQUIREMENTS MODULE")
    if ($startIdx -gt 0) {
        $blockStart = $existingResilience.LastIndexOf("`n# =====", $startIdx)
        if ($blockStart -lt 0) { $blockStart = $startIdx - 2 }

        $endIdx = $existingResilience.IndexOf("Council Requirements module loaded.", $startIdx)
        if ($endIdx -gt 0) {
            $endIdx = $existingResilience.IndexOf("`n", $endIdx)
            if ($endIdx -gt 0) {
                $before = $existingResilience.Substring(0, $blockStart)
                $after = $existingResilience.Substring($endIdx)
                $existingResilience = $before + $after
            }
        }
    }
    $existingResilience += $councilReqCode
    Set-Content -Path $resiliencePath -Value $existingResilience -Encoding UTF8
    Write-Host "[OK] Council Requirements module REPLACED in resilience.ps1" -ForegroundColor Green
} else {
    Add-Content -Path $resiliencePath -Value $councilReqCode -Encoding UTF8
    Write-Host "[OK] Council Requirements module appended to resilience.ps1" -ForegroundColor Green
}

# ========================================================
# 4. Update gsd-verify-requirements in profile functions
# ========================================================

Write-Host ""
Write-Host "[CLIP] Updating gsd-verify-requirements command..." -ForegroundColor Yellow

$profileFunctions = Join-Path $GsdGlobalDir "scripts\gsd-profile-functions.ps1"
if (Test-Path $profileFunctions) {
    $pfContent = Get-Content $profileFunctions -Raw

    # Remove old version if exists
    if ($pfContent -like "*function gsd-verify-requirements*") {
        $startIdx = $pfContent.IndexOf("function gsd-verify-requirements")
        if ($startIdx -gt 0) {
            $blockStart = $pfContent.LastIndexOf("`n", $startIdx)
            if ($blockStart -lt 0) { $blockStart = $startIdx }
            $braceCount = 0; $inFunc = $false; $endIdx = $startIdx
            for ($ci = $startIdx; $ci -lt $pfContent.Length; $ci++) {
                if ($pfContent[$ci] -eq '{') { $braceCount++; $inFunc = $true }
                if ($pfContent[$ci] -eq '}') { $braceCount-- }
                if ($inFunc -and $braceCount -eq 0) { $endIdx = $ci + 1; break }
            }
            $pfContent = $pfContent.Substring(0, $blockStart) + $pfContent.Substring($endIdx)
        }
    }

    $verifyFunction = @'

function gsd-verify-requirements {
    <#
    .SYNOPSIS
        Partitioned extract + cross-verify requirements extraction.
        Each of 3 agents reads 1/3 of spec files, then a different agent verifies.
    .EXAMPLE
        gsd-verify-requirements
        gsd-verify-requirements -DryRun
        gsd-verify-requirements -SkipAgent gemini
        gsd-verify-requirements -ChunkSize 5
        gsd-verify-requirements -SkipVerify
    #>
    param(
        [string]$SkipAgent = "",
        [int]$ChunkSize = 0,
        [switch]$DryRun,
        [switch]$PreserveExisting,
        [switch]$SkipVerify
    )

    $repoRoot = (Get-Location).Path
    $gsdDir = Join-Path $repoRoot ".gsd"
    $globalDir = Join-Path $env:USERPROFILE ".gsd-global"

    @($gsdDir, "$gsdDir\health", "$gsdDir\logs", "$gsdDir\specs",
      "$gsdDir\code-review", "$gsdDir\research", "$gsdDir\generation-queue",
      "$gsdDir\agent-handoff") | ForEach-Object {
        if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
    }

    $healthFile = Join-Path $gsdDir "health\health-current.json"
    if (-not (Test-Path $healthFile)) {
        @{ health_score=0; total_requirements=0; satisfied=0; partial=0; not_started=0; iteration=0 } |
            ConvertTo-Json | Set-Content $healthFile -Encoding UTF8
    }

    . "$globalDir\lib\modules\resilience.ps1"
    if (Test-Path "$globalDir\lib\modules\interfaces.ps1") { . "$globalDir\lib\modules\interfaces.ps1" }
    if (Test-Path "$globalDir\lib\modules\interface-wrapper.ps1") { . "$globalDir\lib\modules\interface-wrapper.ps1" }

    # Override chunk size if specified
    if ($ChunkSize -gt 0) {
        $cfgPath = Join-Path $globalDir "config\global-config.json"
        if (Test-Path $cfgPath) {
            try {
                $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
                if ($cfg.council_requirements) {
                    $cfg.council_requirements.chunk_size = $ChunkSize
                    $cfg | ConvertTo-Json -Depth 10 | Set-Content $cfgPath -Encoding UTF8
                }
            } catch {}
        }
    }

    Write-Host ""
    Write-Host "=========================================================" -ForegroundColor Cyan
    Write-Host "  GSD Council Requirements Verification" -ForegroundColor Cyan
    Write-Host "  Partitioned Extract + Cross-Verify" -ForegroundColor Cyan
    Write-Host "=========================================================" -ForegroundColor Cyan
    Write-Host "  Repo: $repoRoot" -ForegroundColor White
    Write-Host ""

    $cliChecks = @("claude", "codex", "gemini") | Where-Object { $_ -ne $SkipAgent }
    foreach ($cli in $cliChecks) {
        $available = $null -ne (Get-Command $cli -ErrorAction SilentlyContinue)
        if ($available) {
            Write-Host "  [OK] $cli available" -ForegroundColor Green
        } else {
            Write-Host "  [!!] $cli not found (optional)" -ForegroundColor DarkYellow
        }
    }
    Write-Host ""

    $matrixFile = Join-Path $gsdDir "health\requirements-matrix.json"
    if ($PreserveExisting -and (Test-Path $matrixFile)) {
        $backupPath = "$matrixFile.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item $matrixFile $backupPath
        Write-Host "  [OK] Existing matrix backed up" -ForegroundColor DarkGreen
    }

    if (Get-Command Update-FileMap -ErrorAction SilentlyContinue) {
        Write-Host "  [MAP] Generating file map..." -ForegroundColor DarkGray
        Update-FileMap -Root $repoRoot -GsdPath $gsdDir 2>$null | Out-Null
    }

    $callResult = Invoke-CouncilRequirements -RepoRoot $repoRoot -GsdDir $gsdDir `
        -DryRun:$DryRun -UseJobs $false -SkipAgent $SkipAgent -SkipVerify:$SkipVerify

    Write-Host ""
    if ($callResult.Success -and -not $DryRun -and (Test-Path $matrixFile)) {
        $matrix = Get-Content $matrixFile -Raw | ConvertFrom-Json
        Write-Host "  ========================================" -ForegroundColor Green
        Write-Host "  REQUIREMENTS VERIFIED SUCCESSFULLY" -ForegroundColor Green
        Write-Host "  ========================================" -ForegroundColor Green
        Write-Host ""
        Write-Host "  Total:      $($matrix.meta.total_requirements) requirements" -ForegroundColor White
        Write-Host "  Health:     $($matrix.meta.health_score)%" -ForegroundColor White
        Write-Host "  Agents:     $($callResult.AgentsSucceeded) participated" -ForegroundColor White
        Write-Host ""

        $high = @($matrix.requirements | Where-Object { $_.confidence -eq "high" }).Count
        $med  = @($matrix.requirements | Where-Object { $_.confidence -eq "medium" }).Count
        $low  = @($matrix.requirements | Where-Object { $_.confidence -eq "low" }).Count

        Write-Host "  Confidence:" -ForegroundColor Yellow
        Write-Host "    High:   $high (confirmed by verifier)" -ForegroundColor Green
        Write-Host "    Medium: $med (added or corrected by verifier)" -ForegroundColor Yellow
        Write-Host "    Low:    $low (unverified)" -ForegroundColor DarkGray
        Write-Host ""

        Write-Host "  Output:" -ForegroundColor DarkGray
        Write-Host "    Matrix: $matrixFile" -ForegroundColor DarkGray
        Write-Host "    Report: $(Join-Path $gsdDir 'health\council-requirements-report.md')" -ForegroundColor DarkGray
        Write-Host ""
    } elseif ($callResult.Success -and $DryRun) {
        Write-Host "  [DRY RUN] Pre-flight passed." -ForegroundColor Green
        Write-Host "  Run without -DryRun to execute." -ForegroundColor DarkGray
        Write-Host ""
    } else {
        Write-Host "  [FAIL] Requirements extraction failed" -ForegroundColor Red
        Write-Host "  Error: $($callResult.Error)" -ForegroundColor Red
        Write-Host ""
        Write-Host "  Try:" -ForegroundColor DarkGray
        Write-Host "    gsd-verify-requirements -ChunkSize 5         # Smaller chunks" -ForegroundColor DarkGray
        Write-Host "    gsd-verify-requirements -SkipVerify          # Extract only, no cross-check" -ForegroundColor DarkGray
        Write-Host "    gsd-verify-requirements -SkipAgent gemini    # Skip unavailable agent" -ForegroundColor DarkGray
    }
}
'@

    $pfContent += $verifyFunction
    Set-Content -Path $profileFunctions -Value $pfContent -Encoding UTF8
    Write-Host "  [OK] Updated gsd-verify-requirements in profile functions" -ForegroundColor Green
}

# ========================================================
# 5. Patch convergence pipeline Phase 0 (if not already done)
# ========================================================

Write-Host ""
Write-Host "[SYNC] Checking convergence pipeline for council Phase 0..." -ForegroundColor Yellow

$convergenceScript = Join-Path $GsdGlobalDir "scripts\convergence-loop.ps1"
if (Test-Path $convergenceScript) {
    $convContent = Get-Content $convergenceScript -Raw
    if ($convContent -like "*council-create-phases*") {
        Write-Host "  [SKIP] Council Phase 0 already patched" -ForegroundColor DarkGray
    } else {
        $oldLine = '    Write-Host "[CLIP] Phase 0: CREATE PHASES" -ForegroundColor Magenta'
        $newBlock = @'
    Write-Host "[CLIP] Phase 0: CREATE PHASES" -ForegroundColor Magenta

    $useCouncilReqs = $false
    if (Get-Command Invoke-CouncilRequirements -ErrorAction SilentlyContinue) {
        $crCfgPath = Join-Path $GlobalDir "config\global-config.json"
        if (Test-Path $crCfgPath) {
            try {
                $crCfg = (Get-Content $crCfgPath -Raw | ConvertFrom-Json).council_requirements
                if ($crCfg -and $crCfg.enabled) { $useCouncilReqs = $true }
            } catch {}
        }
    }

    if ($useCouncilReqs -and -not $DryRun) {
        Write-Host "  [SCALES] Council requirements extraction (partitioned + cross-verify)" -ForegroundColor Cyan
        Save-Checkpoint -GsdDir $GsdDir -Pipeline "converge" -Iteration 0 -Phase "council-create-phases" -Health 0 -BatchSize $CurrentBatchSize
        $crResult = Invoke-CouncilRequirements -RepoRoot $RepoRoot -GsdDir $GsdDir
        if (-not $crResult.Success) {
            Write-Host "  [WARN] Council extraction failed. Falling back to single-agent." -ForegroundColor Yellow
            $useCouncilReqs = $false
        }
    }

    if (-not $useCouncilReqs) {
'@

        if ($convContent -like "*Phase 0: CREATE PHASES*") {
            $convContent = $convContent.Replace($oldLine, $newBlock)
            $outNullLine = '            -LogFile "$GsdDir\logs\phase0.log" -CurrentBatchSize $CurrentBatchSize -GsdDir $GsdDir | Out-Null'
            $convContent = $convContent.Replace($outNullLine, "$outNullLine`n    }")
            Set-Content -Path $convergenceScript -Value $convContent -Encoding UTF8
            Write-Host "  [OK] Convergence pipeline Phase 0 patched" -ForegroundColor Green
        } else {
            Write-Host "  [WARN] Could not locate Phase 0 in convergence-loop.ps1" -ForegroundColor Yellow
        }
    }
} else {
    Write-Host "  [SKIP] convergence-loop.ps1 not found" -ForegroundColor DarkGray
}

# ========================================================
# Done
# ========================================================

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Green
Write-Host "  Council Requirements Verification installed!" -ForegroundColor Green
Write-Host "=========================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Flow:" -ForegroundColor White
Write-Host "    Phase 1: Each agent extracts from 1/3 of specs (chunked)" -ForegroundColor DarkGray
Write-Host "    Phase 2: Different agent cross-verifies each extraction" -ForegroundColor DarkGray
Write-Host "      Claude extracts -> Codex verifies" -ForegroundColor DarkGray
Write-Host "      Codex extracts  -> Gemini verifies" -ForegroundColor DarkGray
Write-Host "      Gemini extracts -> Claude verifies" -ForegroundColor DarkGray
Write-Host "    Phase 3: Claude synthesizes verified matrix" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Usage:" -ForegroundColor White
Write-Host "    gsd-verify-requirements                     # Full extract + verify" -ForegroundColor DarkGray
Write-Host "    gsd-verify-requirements -DryRun             # Preview partitions" -ForegroundColor DarkGray
Write-Host "    gsd-verify-requirements -ChunkSize 5        # Smaller chunks" -ForegroundColor DarkGray
Write-Host "    gsd-verify-requirements -SkipVerify         # Extract only" -ForegroundColor DarkGray
Write-Host "    gsd-verify-requirements -SkipAgent gemini   # 2-agent mode" -ForegroundColor DarkGray
Write-Host ""
