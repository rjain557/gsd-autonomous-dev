<#
.SYNOPSIS
    GSD V3 Traceability Matrix Updater - Pure file-scanning, no LLM calls
.DESCRIPTION
    Regenerates .gsd/compliance/traceability-matrix.json by scanning the codebase
    for evidence files that implement each requirement. Handles FIGMA-derived reqs
    (SCR, RTE, API, CMP) and standard reqs (FR, NFR, etc.) with keyword + target_files matching.
    Zero LLM cost -- runs in <5 seconds on typical repos.
#>

# ============================================================
# PATH RESOLUTION - Ensures evidence_files always contain valid repo-relative paths
# ============================================================

function Resolve-EvidencePath {
    <#
    .SYNOPSIS
        Resolves a potentially short/incomplete relative path to a verified repo-relative path.
        If the path exists directly, returns it. Otherwise searches the file index by filename.
        Returns $null if the file cannot be found anywhere.
    #>
    [CmdletBinding()]
    param(
        [string]$RelPath,
        [string]$RepoRoot,
        [array]$FileIndex
    )

    if (-not $RelPath) { return $null }

    # 1. Try direct path from repo root
    $fullCheck = Join-Path $RepoRoot ($RelPath -replace '/', '\')
    if (Test-Path $fullCheck) { return $RelPath }

    # 2. Search file index by filename match
    $fileName = [System.IO.Path]::GetFileName($RelPath)
    $fileNameLower = $fileName.ToLower()
    $matches = @($FileIndex | Where-Object { $_.Name -eq $fileNameLower })

    if ($matches.Count -eq 0) { return $null }
    if ($matches.Count -eq 1) { return $matches[0].RelPath }

    # 3. Multiple matches -- pick best by path similarity
    #    Prefer src/ over generated/, prefer paths that share directory segments with RelPath
    $relParts = @($RelPath -split '[/\\]' | Where-Object { $_ })
    $bestMatch = $null
    $bestScore = -1

    foreach ($m in $matches) {
        $mParts = @($m.RelPath -split '[/\\]' | Where-Object { $_ })
        $score = 0
        # Count shared path segments (excluding filename)
        foreach ($rp in $relParts) {
            if ($mParts -contains $rp) { $score++ }
        }
        # Prefer src/ over generated/ (real code over stubs)
        if ($m.RelPath -match '^src/') { $score += 2 }
        # Prefer longer paths (more specific)
        if ($m.RelPath.Length -gt 50) { $score++ }

        if ($score -gt $bestScore) {
            $bestScore = $score
            $bestMatch = $m.RelPath
        }
    }

    return $bestMatch
}

function Invoke-TraceabilityUpdate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$GsdDir,
        [object]$Config
    )

    if (-not $GsdDir) { $GsdDir = Join-Path $RepoRoot ".gsd" }

    $matrixPath = Join-Path $GsdDir "requirements/requirements-matrix.json"
    if (-not (Test-Path $matrixPath)) {
        Write-Host "    [TRACE] No requirements-matrix.json found -- skipping traceability" -ForegroundColor DarkYellow
        return @{ Success = $false; Reason = "No requirements matrix" }
    }

    $startTime = Get-Date
    Write-Host "    [TRACE] Regenerating traceability matrix..." -ForegroundColor Cyan

    # ------------------------------------------------------------------
    # 1. Load requirements matrix
    # ------------------------------------------------------------------
    try {
        $matrix = Get-Content $matrixPath -Raw -ErrorAction Stop | ConvertFrom-Json
        $allReqs = @($matrix.requirements)
    } catch {
        Write-Host "    [TRACE] Failed to parse requirements matrix: $($_.Exception.Message)" -ForegroundColor Red
        return @{ Success = $false; Reason = "Parse error: $($_.Exception.Message)" }
    }

    if ($allReqs.Count -eq 0) {
        Write-Host "    [TRACE] Requirements matrix is empty" -ForegroundColor DarkYellow
        return @{ Success = $false; Reason = "Empty matrix" }
    }

    # ------------------------------------------------------------------
    # 2. Build file index (one-time scan, exclude junk dirs)
    # ------------------------------------------------------------------
    $excludeDirs = @("node_modules", "dist", "build", ".gsd", ".git", "bin", "obj", ".next", ".nuxt", "coverage", "__pycache__", ".vs")
    $sourceExtensions = @(".tsx", ".jsx", ".ts", ".js", ".cs", ".sql", ".css", ".scss", ".less", ".json", ".py", ".go", ".java")

    $allFiles = @()
    try {
        $allFiles = @(Get-ChildItem -Path $RepoRoot -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object {
                $relPath = $_.FullName.Substring($RepoRoot.Length).TrimStart('\', '/')
                $parts = $relPath -split '[/\\]'
                $dominated = $false
                foreach ($ex in $excludeDirs) {
                    if ($parts -contains $ex) { $dominated = $true; break }
                }
                (-not $dominated) -and ($sourceExtensions -contains $_.Extension.ToLower())
            })
    } catch {
        Write-Host "    [TRACE] File scan error: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }

    # Build lookup: relative paths (forward slashes) and lowercase filenames
    $fileIndex = @()
    foreach ($f in $allFiles) {
        $rel = $f.FullName.Substring($RepoRoot.Length).TrimStart('\', '/') -replace '\\', '/'
        $fileIndex += [PSCustomObject]@{
            RelPath  = $rel
            Name     = $f.Name.ToLower()
            BaseName = $f.BaseName.ToLower()
            FullPath = $f.FullName
            Extension = $f.Extension.ToLower()
        }
    }

    Write-Host "    [TRACE] Indexed $($fileIndex.Count) source files" -ForegroundColor DarkGray

    # ------------------------------------------------------------------
    # 3. For each requirement, find evidence files
    # ------------------------------------------------------------------
    $traceEntries = @()
    $mappedCount = 0
    $unmappedCount = 0

    foreach ($req in $allReqs) {
        $reqId = if ($req.id) { $req.id } else { $req.requirement_id }
        $desc = if ($req.description) { $req.description } else { "" }
        $iface = if ($req.interface) { $req.interface } else { "unknown" }
        $status = if ($req.status) { $req.status } else { "unknown" }
        $priority = if ($req.priority) { $req.priority } else { "normal" }
        $satisfiedBy = if ($req.satisfied_by) { $req.satisfied_by } else { "" }
        $targetFiles = if ($req.target_files) { $req.target_files } else { "" }

        $evidenceFiles = @()

        # -- Strategy A: Use satisfied_by field (most reliable for existing reqs)
        if ($satisfiedBy -and $satisfiedBy.Trim()) {
            $sbFiles = @($satisfiedBy -split ',\s*' | Where-Object { $_.Trim() })
            foreach ($sbf in $sbFiles) {
                $sbfClean = $sbf.Trim() -replace '\\', '/'
                if ($sbfClean) {
                    $resolved = Resolve-EvidencePath -RelPath $sbfClean -RepoRoot $RepoRoot -FileIndex $fileIndex
                    if ($resolved) { $evidenceFiles += $resolved }
                }
            }
        }

        # -- Strategy B: Use target_files field
        if ($targetFiles -and $targetFiles.Trim() -and $evidenceFiles.Count -eq 0) {
            $tfFiles = @()
            if ($targetFiles -is [array]) {
                $tfFiles = $targetFiles
            } else {
                $tfFiles = @($targetFiles -split ',\s*' | Where-Object { $_.Trim() })
            }
            foreach ($tf in $tfFiles) {
                $tfClean = $tf.Trim() -replace '\\', '/'
                if ($tfClean) {
                    $resolved = Resolve-EvidencePath -RelPath $tfClean -RepoRoot $RepoRoot -FileIndex $fileIndex
                    if ($resolved) { $evidenceFiles += $resolved }
                }
            }
        }

        # -- Strategy C: FIGMA requirement pattern matching
        if ($evidenceFiles.Count -eq 0 -and $reqId -match '^FIGMA-') {
            $evidenceFiles = @(Find-FigmaReqFiles -ReqId $reqId -Description $desc -FileIndex $fileIndex)
        }

        # -- Strategy D: Keyword-based scan for remaining unmapped reqs
        if ($evidenceFiles.Count -eq 0) {
            $evidenceFiles = @(Find-KeywordFiles -ReqId $reqId -Description $desc -Interface $iface -FileIndex $fileIndex)
        }

        # Deduplicate
        $evidenceFiles = @($evidenceFiles | Select-Object -Unique)

        if ($evidenceFiles.Count -gt 0) { $mappedCount++ } else { $unmappedCount++ }

        $traceEntries += [PSCustomObject]@{
            requirement_id = $reqId
            description    = $desc
            interface      = $iface
            priority       = $priority
            status         = $status
            evidence_files = $evidenceFiles
            file_count     = $evidenceFiles.Count
            last_updated   = (Get-Date -Format "o")
        }
    }

    # ------------------------------------------------------------------
    # 4. Write traceability matrix
    # ------------------------------------------------------------------
    $complianceDir = Join-Path $GsdDir "compliance"
    if (-not (Test-Path $complianceDir)) {
        New-Item -ItemType Directory -Path $complianceDir -Force | Out-Null
    }

    $outputPath = Join-Path $complianceDir "traceability-matrix.json"

    $statusCounts = [PSCustomObject]@{
        satisfied   = @($allReqs | Where-Object { $_.status -eq "satisfied" }).Count
        partial     = @($allReqs | Where-Object { $_.status -eq "partial" }).Count
        not_started = @($allReqs | Where-Object { $_.status -eq "not_started" }).Count
        deferred    = @($allReqs | Where-Object { $_.status -eq "deferred" }).Count
    }

    $traceMatrix = [PSCustomObject]@{
        generated_at = (Get-Date -Format "o")
        generator    = "traceability-updater.ps1"
        project      = (Split-Path $RepoRoot -Leaf)
        summary      = [PSCustomObject]@{
            total           = $allReqs.Count
            satisfied       = $statusCounts.satisfied
            partial         = $statusCounts.partial
            not_started     = $statusCounts.not_started
            deferred        = $statusCounts.deferred
            mapped_to_files = $mappedCount
            unmapped        = $unmappedCount
            total_files     = $fileIndex.Count
        }
        requirements = $traceEntries
    }

    try {
        $traceMatrix | ConvertTo-Json -Depth 10 | Set-Content $outputPath -Encoding UTF8
        $elapsed = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)
        Write-Host "    [TRACE] Traceability matrix written: $($allReqs.Count) reqs, $mappedCount mapped, $unmappedCount unmapped ($elapsed`s)" -ForegroundColor Green
    } catch {
        Write-Host "    [TRACE] Failed to write traceability matrix: $($_.Exception.Message)" -ForegroundColor Red
        return @{ Success = $false; Reason = "Write error: $($_.Exception.Message)" }
    }

    return @{
        Success      = $true
        Total        = $allReqs.Count
        Mapped       = $mappedCount
        Unmapped     = $unmappedCount
        OutputPath   = $outputPath
        ElapsedSec   = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)
    }
}

# ============================================================
# FIGMA REQUIREMENT FILE MATCHING
# ============================================================

function Find-FigmaReqFiles {
    [CmdletBinding()]
    param(
        [string]$ReqId,
        [string]$Description,
        [array]$FileIndex
    )

    $foundFiles = [System.Collections.Generic.List[string]]::new()

    # Parse FIGMA ID: e.g., FIGMA-001-SCR-014, FIGMA-002-RTE-003, FIGMA-001-API-005
    $figmaType = ""
    $figmaNum = ""
    if ($ReqId -match 'FIGMA-\d+-(\w+)-(\d+)') {
        $figmaType = $Matches[1].ToUpper()
        $figmaNum = $Matches[2]
    } elseif ($ReqId -match 'FIGMA-(\w+)-(\d+)') {
        $figmaType = $Matches[1].ToUpper()
        $figmaNum = $Matches[2]
    }

    # Extract meaningful keywords from description
    $descKeywords = Get-DescriptionKeywords -Description $Description

    switch ($figmaType) {
        "SCR" {
            # Screen reqs: look for .tsx/.jsx page/screen files
            foreach ($f in $FileIndex) {
                if ($f.Extension -in @(".tsx", ".jsx")) {
                    $isPage = $f.RelPath -match '(?i)(pages|screens|views)/'
                    $nameMatch = $false
                    foreach ($kw in $descKeywords) {
                        if ($f.BaseName -match "(?i)$([regex]::Escape($kw))") { $nameMatch = $true; break }
                    }
                    if ($isPage -and $nameMatch) { $foundFiles.Add($f.RelPath) }
                }
            }
        }
        "RTE" {
            # Route reqs: look for router/route config files + App.tsx
            foreach ($f in $FileIndex) {
                if ($f.BaseName -match '(?i)(router|routes|app|routing|navigation)' -and $f.Extension -in @(".tsx", ".jsx", ".ts", ".js")) {
                    $foundFiles.Add($f.RelPath)
                }
            }
            # Also match page files by description keywords
            foreach ($f in $FileIndex) {
                if ($f.Extension -in @(".tsx", ".jsx") -and $f.RelPath -match '(?i)(pages|screens)/') {
                    foreach ($kw in $descKeywords) {
                        if ($f.BaseName -match "(?i)$([regex]::Escape($kw))") { $foundFiles.Add($f.RelPath); break }
                    }
                }
            }
        }
        "API" {
            # API reqs: look for API service files, hooks, controllers
            foreach ($f in $FileIndex) {
                $isApiFile = $f.RelPath -match '(?i)(api|services|hooks|controllers|endpoints)/' -or
                             $f.BaseName -match '(?i)(api|service|hook|client|controller)'
                if ($isApiFile) {
                    foreach ($kw in $descKeywords) {
                        if ($f.BaseName -match "(?i)$([regex]::Escape($kw))" -or $f.RelPath -match "(?i)$([regex]::Escape($kw))") {
                            $foundFiles.Add($f.RelPath); break
                        }
                    }
                }
            }
        }
        "CMP" {
            # Component reqs: look for component .tsx files
            foreach ($f in $FileIndex) {
                if ($f.Extension -in @(".tsx", ".jsx") -and $f.RelPath -match '(?i)components/') {
                    foreach ($kw in $descKeywords) {
                        if ($f.BaseName -match "(?i)$([regex]::Escape($kw))") { $foundFiles.Add($f.RelPath); break }
                    }
                }
            }
        }
        default {
            # Generic FIGMA req -- keyword scan
            foreach ($f in $FileIndex) {
                foreach ($kw in $descKeywords) {
                    if ($f.BaseName -match "(?i)$([regex]::Escape($kw))") { $foundFiles.Add($f.RelPath); break }
                }
            }
        }
    }

    return @($foundFiles | Select-Object -Unique)
}

# ============================================================
# KEYWORD-BASED FILE MATCHING (non-FIGMA reqs)
# ============================================================

function Find-KeywordFiles {
    [CmdletBinding()]
    param(
        [string]$ReqId,
        [string]$Description,
        [string]$Interface,
        [array]$FileIndex
    )

    $foundFiles = [System.Collections.Generic.List[string]]::new()
    $descKeywords = Get-DescriptionKeywords -Description $Description

    if ($descKeywords.Count -eq 0) { return @() }

    # Filter by interface to narrow scope
    $candidates = $FileIndex
    switch -Regex ($Interface) {
        '(?i)^(backend|server|api)$' {
            $candidates = @($FileIndex | Where-Object {
                $_.Extension -in @(".cs", ".sql", ".py", ".go", ".java") -or
                $_.RelPath -match '(?i)(server|api|backend|controllers|services|repositories|data)/'
            })
        }
        '(?i)^(web|frontend|client|ui)$' {
            $candidates = @($FileIndex | Where-Object {
                $_.Extension -in @(".tsx", ".jsx", ".ts", ".js", ".css", ".scss") -or
                $_.RelPath -match '(?i)(client|web|frontend|src|pages|components)/'
            })
        }
        '(?i)^(database|db|sql)$' {
            $candidates = @($FileIndex | Where-Object {
                $_.Extension -eq ".sql" -or
                $_.RelPath -match '(?i)(migrations|stored.?proc|database|sql|data)/'
            })
        }
        '(?i)^(design.?system|theme|style)$' {
            $candidates = @($FileIndex | Where-Object {
                $_.Extension -in @(".css", ".scss", ".less") -or
                $_.BaseName -match '(?i)(theme|design|token|style|tailwind)'
            })
        }
    }

    # Match by keywords -- require at least one strong match
    foreach ($f in $candidates) {
        $hitCount = 0
        foreach ($kw in $descKeywords) {
            if ($kw.Length -lt 3) { continue }  # Skip very short keywords
            $escaped = [regex]::Escape($kw)
            if ($f.BaseName -match "(?i)$escaped" -or $f.RelPath -match "(?i)$escaped") {
                $hitCount++
            }
        }
        # Require at least 1 keyword hit
        if ($hitCount -ge 1) { $foundFiles.Add($f.RelPath) }
    }

    # Cap at 10 files per requirement to avoid noise
    return @($foundFiles | Select-Object -Unique | Select-Object -First 10)
}

# ============================================================
# KEYWORD EXTRACTION
# ============================================================

function Get-DescriptionKeywords {
    [CmdletBinding()]
    param([string]$Description)

    if (-not $Description) { return @() }

    # Remove common stop words and extract meaningful terms
    $stopWords = @("the", "a", "an", "and", "or", "but", "in", "on", "at", "to", "for",
                   "of", "with", "by", "from", "as", "is", "was", "are", "were", "be",
                   "been", "being", "have", "has", "had", "do", "does", "did", "will",
                   "would", "could", "should", "may", "might", "must", "shall", "can",
                   "that", "this", "which", "what", "where", "when", "who", "whom",
                   "how", "not", "no", "nor", "both", "each", "every", "all", "any",
                   "few", "more", "most", "other", "some", "such", "than", "too", "very",
                   "just", "also", "into", "over", "after", "before", "between", "through",
                   "during", "without", "within", "about", "above", "across", "along",
                   "around", "behind", "below", "beneath", "beside", "beyond", "upon",
                   "per", "via", "including", "based", "using", "etc", "its", "their",
                   "your", "our", "his", "her", "implementation", "implement", "support",
                   "ensure", "provide", "enable", "allow", "include", "manage", "handle",
                   "create", "display", "show", "functionality", "feature", "system",
                   "proper", "appropriate", "comprehensive", "real", "time", "operations",
                   "crud")

    # Split on non-alphanumeric, filter stopwords and short terms
    $words = @($Description -split '[^a-zA-Z0-9]+' |
        Where-Object { $_ -and $_.Length -ge 3 } |
        ForEach-Object { $_.ToLower() } |
        Where-Object { $_ -notin $stopWords })

    # Also extract compound terms (e.g., "exam-taking" -> "examtaking", "ExamTaking")
    $compounds = @()
    if ($Description -match '([A-Z][a-z]+(?:[A-Z][a-z]+)+)') {
        # CamelCase extraction
        $compounds += $Matches[1].ToLower()
    }

    $result = @($words + $compounds | Select-Object -Unique | Select-Object -First 8)
    return $result
}
