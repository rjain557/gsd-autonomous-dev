
# ── Invoke-PartialDecompose (patch-gsd-partial-decompose) ────────────────────
# Runs before each plan phase (iteration > 1).
# Finds requirements that were in the previous batch and are still partial,
# then uses Claude to split each into 2-4 atomic implementable sub-requirements.
function Invoke-PartialDecompose {
    param(
        [string]$GsdDir,
        [string]$GlobalDir,
        [int]$Iteration
    )

    $matrixFile = "$GsdDir\health\requirements-matrix.json"
    $queueFile  = "$GsdDir\generation-queue\queue-current.json"
    $logFile    = "$GsdDir\logs\partial-decompose-iter${Iteration}.json"

    if (-not (Test-Path $matrixFile)) {
        Write-Host "  [DECOMPOSE] No requirements-matrix.json found - skipping" -ForegroundColor DarkGray
        return
    }
    if (-not (Test-Path $queueFile)) {
        Write-Host "  [DECOMPOSE] No previous queue-current.json - skipping (iter 1 or fresh run)" -ForegroundColor DarkGray
        return
    }

    # Read previous batch IDs from queue-current.json
    $qRaw    = Get-Content $queueFile -Raw | ConvertFrom-Json
    $prevIds = @()
    if ($qRaw.batch)           { $prevIds = @($qRaw.batch | ForEach-Object { $_.req_id } | Where-Object { $_ }) }
    elseif ($qRaw -is [array]) { $prevIds = @($qRaw        | ForEach-Object { $_.req_id } | Where-Object { $_ }) }

    if ($prevIds.Count -eq 0) {
        Write-Host "  [DECOMPOSE] Previous batch is empty - skipping" -ForegroundColor DarkGray
        return
    }

    # Find stuck partials: were in previous batch, still partial, not already decomposed
    $matrix = Get-Content $matrixFile -Raw | ConvertFrom-Json
    $stuck  = @($matrix.requirements | Where-Object {
        $_.status -eq 'partial' -and
        $_.id -in $prevIds -and
        -not $_.decomposed
    })

    if ($stuck.Count -eq 0) {
        Write-Host "  [DECOMPOSE] No stuck partials from previous batch - nothing to decompose" -ForegroundColor DarkGray
        return
    }

    Write-Host ("  [DECOMPOSE] " + $stuck.Count + " stuck partial(s) found - decomposing into atomic sub-requirements...") -ForegroundColor Yellow

    $newReqs       = [System.Collections.Generic.List[object]]::new()
    $decomposedIds = [System.Collections.Generic.List[string]]::new()
    $claudeModel   = if ($script:CLAUDE_MODEL) { $script:CLAUDE_MODEL } else { 'claude-sonnet-4-6' }

    foreach ($req in $stuck) {
        $shortDesc = $req.description.Substring(0, [Math]::Min(70, $req.description.Length))
        Write-Host ("    Decomposing [" + $req.id + "] " + $shortDesc + "...") -ForegroundColor Cyan

        $promptLines = @(
            "You are decomposing a partially-implemented software requirement into atomic sub-requirements.",
            "",
            "PARENT REQUIREMENT:",
            "- ID: " + $req.id,
            "- Description: " + $req.description,
            "- Pattern: " + $req.pattern,
            "- Priority: " + $req.priority,
            "- Agent: " + $req.agent,
            "- Spec doc: " + $req.spec_doc,
            "",
            "This requirement was attempted in the last iteration but remained only PARTIALLY satisfied.",
            "The agent implemented some but not all of it.",
            "",
            "YOUR TASK:",
            "Break it into 2-4 ATOMIC sub-requirements. Each sub-requirement must:",
            "1. Be independently implementable in a single agent iteration",
            "2. Be a concrete coding task (not vague)",
            "3. Have clear implicit acceptance criteria",
            "4. Not duplicate work already done (parent is partial, some parts exist)",
            "",
            "SUB-REQUIREMENT ID PATTERN: " + $req.id + "-1, " + $req.id + "-2, etc.",
            "",
            "Return ONLY a valid JSON array with NO other text, markdown, or explanation:",
            "[",
            "  {",
            '    "id": "' + $req.id + '-1",',
            '    "description": "Specific atomic task description",',
            '    "pattern": "' + $req.pattern + '",',
            '    "priority": "' + $req.priority + '",',
            '    "agent": "' + $req.agent + '",',
            '    "spec_doc": "' + $req.spec_doc + '",',
            '    "status": "not_started",',
            '    "parent_id": "' + $req.id + '"',
            "  }",
            "]"
        )
        $decomposePrompt = $promptLines -join "`n"

        try {
            $tmpFile = [System.IO.Path]::GetTempFileName()
            [System.IO.File]::WriteAllText($tmpFile, $decomposePrompt, [System.Text.Encoding]::UTF8)
            $rawOut = Get-Content $tmpFile -Raw | claude --print --model $claudeModel --output-format text 2>&1
            Remove-Item $tmpFile -ErrorAction SilentlyContinue

            # Extract JSON array from output
            if ($rawOut -match '(?s)(\[[\s\S]+?\])') {
                $jsonStr = $Matches[1]
                $subReqs = $jsonStr | ConvertFrom-Json
                $added   = 0
                foreach ($sr in $subReqs) {
                    if ($sr.id -and $sr.description -and $sr.status) {
                        $newReqs.Add($sr)
                        $added++
                        $srDesc = $sr.description.Substring(0, [Math]::Min(60, $sr.description.Length))
                        Write-Host ("      + " + $sr.id + ": " + $srDesc) -ForegroundColor Green
                    }
                }
                if ($added -gt 0) { $decomposedIds.Add($req.id) }
            } else {
                Write-Host ("    [WARN] No JSON array in Claude response for " + $req.id) -ForegroundColor Yellow
            }
        } catch {
            Write-Host ("    [WARN] Decompose failed for " + $req.id + ": " + $_) -ForegroundColor Yellow
        }
    }

    if ($newReqs.Count -gt 0) {
        # Mark parents decomposed=true (keep status=partial so health formula unchanged)
        foreach ($r in $matrix.requirements) {
            if ($r.id -in $decomposedIds) {
                $r | Add-Member -NotePropertyName 'decomposed' -NotePropertyValue $true -Force
            }
        }

        # Append sub-requirements to matrix
        $allReqs = [System.Collections.Generic.List[object]]::new()
        $matrix.requirements | ForEach-Object { $allReqs.Add($_) }
        $newReqs | ForEach-Object { $allReqs.Add($_) }
        $matrix.requirements = $allReqs.ToArray()
        $matrix | ConvertTo-Json -Depth 10 | Set-Content $matrixFile -Encoding UTF8

        # Write decompose log
        @{
            iteration        = $Iteration
            timestamp        = (Get-Date -Format 'o')
            decomposed_ids   = $decomposedIds.ToArray()
            new_requirements = @($newReqs | ForEach-Object { $_.id })
        } | ConvertTo-Json -Depth 5 | Set-Content $logFile -Encoding UTF8

        Write-Host ("  [DECOMPOSE] Done: " + $newReqs.Count + " sub-reqs added from " + $decomposedIds.Count + " parent(s)") -ForegroundColor Green
    } else {
        Write-Host "  [DECOMPOSE] No sub-requirements generated (Claude responses unparseable)" -ForegroundColor Yellow
    }
}
# ── end Invoke-PartialDecompose ───────────────────────────────────────────────
