# mock-data-detector.ps1
# Scans a codebase for mock/static data patterns, placeholder configs,
# and stub implementations that indicate incomplete integration.

# OPTIMIZATION: Detect ripgrep availability once at module load
$script:UseRipgrep = $null -ne (Get-Command rg -ErrorAction SilentlyContinue)

function Find-MockDataPatterns {
    <#
    .SYNOPSIS
        Scans source files for mock/static data patterns that indicate
        the code is not wired to real backends.
    .PARAMETER RepoRoot
        Root directory of the repository to scan.
    .PARAMETER ExcludeDirs
        Directories to exclude from scanning.
    .OUTPUTS
        Array of PSCustomObject with: File, Line, Pattern, Severity, Suggestion
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string[]]$ExcludeDirs = @("node_modules", ".git", "bin", "obj", "dist", ".gsd", "coverage", ".next", "__pycache__", "design", "generated", "docs", ".planning", ".claude", "wwwroot", "packages", "TestResults")
    )

    $results = [System.Collections.ArrayList]::new()

    # Define patterns: regex, description, severity, suggestion
    $patterns = @(
        @{
            Regex       = 'useState\s*\(\s*\[.*?\{.*?(id|name|title).*?\}.*?\]'
            Description = 'useState with hardcoded array of objects (mock data)'
            Severity    = 'high'
            Suggestion  = 'Replace with API call using useQuery/useEffect + fetch'
            Extensions  = @('.tsx', '.ts', '.jsx', '.js')
            RgTypes     = @('ts', 'js')
        },
        @{
            Regex       = '(?i)(const|let|var)\s+mock\w*\s*=\s*\['
            Description = 'Mock data variable (array)'
            Severity    = 'high'
            Suggestion  = 'Remove mock data; fetch from real API endpoint'
            Extensions  = @('.tsx', '.ts', '.jsx', '.js')
            RgTypes     = @('ts', 'js')
        },
        @{
            Regex       = '(?i)(const|let|var)\s+mock\w*\s*=\s*\{'
            Description = 'Mock data variable (object)'
            Severity    = 'high'
            Suggestion  = 'Remove mock data; fetch from real API endpoint'
            Extensions  = @('.tsx', '.ts', '.jsx', '.js')
            RgTypes     = @('ts', 'js')
        },
        @{
            Regex       = '(?i)(TODO|FIXME|HACK|XXX|FILL|PLACEHOLDER|CHANGEME)'
            Description = 'TODO/FIXME/PLACEHOLDER marker found'
            Severity    = 'medium'
            Suggestion  = 'Implement the actual functionality'
            Extensions  = @('.tsx', '.ts', '.jsx', '.js', '.cs', '.json', '.sql')
            RgTypes     = @('ts', 'js', 'cs', 'json')
            RgGlobs     = @('*.sql')
        },
        @{
            Regex       = 'console\.(log|error|warn|debug|info)\s*\('
            Description = 'Console statement in production code'
            Severity    = 'low'
            Suggestion  = 'Remove console statements or use a proper logger'
            Extensions  = @('.tsx', '.ts', '.jsx', '.js')
            RgTypes     = @('ts', 'js')
        },
        @{
            Regex       = '(?i)(https?://localhost:\d{4}|https?://example\.com|https?://your-?api|http://0\.0\.0\.0)'
            Description = 'Placeholder URL detected'
            Severity    = 'critical'
            Suggestion  = 'Replace with real API base URL from environment config'
            Extensions  = @('.tsx', '.ts', '.jsx', '.js', '.cs', '.json', '.env')
            RgTypes     = @('ts', 'js', 'cs', 'json')
            RgGlobs     = @('*.env', '*.env.*')
        },
        @{
            Regex       = '(?i)(password\s*[:=]\s*["\x27](?!<).{1,30}["\x27]|secret\s*[:=]\s*["\x27].{1,50}["\x27]|apikey\s*[:=]\s*["\x27].{1,50}["\x27])'
            Description = 'Possible hardcoded credential'
            Severity    = 'critical'
            Suggestion  = 'Move to environment variable or secure configuration'
            Extensions  = @('.tsx', '.ts', '.jsx', '.js', '.cs', '.json')
            RgTypes     = @('ts', 'js', 'cs', 'json')
        },
        @{
            Regex       = '(?i)import\s+.*mock'
            Description = 'Import of mock data module'
            Severity    = 'high'
            Suggestion  = 'Replace mock import with real API service import'
            Extensions  = @('.tsx', '.ts', '.jsx', '.js')
            RgTypes     = @('ts', 'js')
        },
        @{
            Regex       = 'Promise\.resolve\s*\(\s*[\[\{]'
            Description = 'Promise.resolve with static data (fake async)'
            Severity    = 'high'
            Suggestion  = 'Replace with real API call using fetch/axios'
            Extensions  = @('.tsx', '.ts', '.jsx', '.js')
            RgTypes     = @('ts', 'js')
        },
        @{
            Regex       = '(?i)(Server|Data Source)\s*=\s*(YOUR_SERVER|localhost\\\\SQLEXPRESS|YOURSERVER|\(localdb\))'
            Description = 'Placeholder database connection string'
            Severity    = 'critical'
            Suggestion  = 'Configure real database connection string'
            Extensions  = @('.json', '.cs', '.config')
            RgTypes     = @('json', 'cs')
            RgGlobs     = @('*.config')
        },
        @{
            Regex       = '(?i)(ClientId|TenantId|Authority)\s*["'']*\s*[:=]\s*["'']\s*(your-|00000000-|xxxxxxxx|CHANGE)'
            Description = 'Placeholder Azure AD / auth configuration'
            Severity    = 'critical'
            Suggestion  = 'Configure real Azure AD application credentials'
            Extensions  = @('.json', '.ts', '.tsx', '.js', '.cs')
            RgTypes     = @('json', 'ts', 'js', 'cs')
        },
        @{
            Regex       = '(?i)role\s*[:=]\s*["\x27](admin|user|manager)["\x27]\s*[,\};\)]'
            Description = 'Hardcoded role assignment (may be mock data)'
            Severity    = 'medium'
            Suggestion  = 'Roles should come from auth token claims, not hardcoded'
            Extensions  = @('.tsx', '.ts', '.jsx', '.js')
            RgTypes     = @('ts', 'js')
        }
    )

    # OPTIMIZATION: Use ripgrep for fast scanning when available
    if ($script:UseRipgrep) {
        # Build rg exclude args
        $rgExcludes = @($ExcludeDirs | ForEach-Object { "--glob=!$_/**" })

        foreach ($p in $patterns) {
            try {
                # Build type/glob args for this pattern
                $typeArgs = @()
                if ($p.RgTypes) { foreach ($t in $p.RgTypes) { $typeArgs += "--type=$t" } }
                if ($p.RgGlobs) { foreach ($g in $p.RgGlobs) { $typeArgs += "--glob=$g" } }

                $rgArgs = @("--json", "--no-heading") + $rgExcludes + $typeArgs + @("-e", $p.Regex, $RepoRoot)
                $rgOutput = & rg @rgArgs 2>$null

                foreach ($line in $rgOutput) {
                    if (-not $line) { continue }
                    try {
                        $match = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
                        if ($match.type -eq 'match') {
                            $relPath = $match.data.path.text -replace [regex]::Escape($RepoRoot), '' -replace '^[\\/]', ''
                            $matchText = if ($match.data.lines.text) { $match.data.lines.text.Trim() } else { "" }
                            if ($matchText.Length -gt 80) { $matchText = $matchText.Substring(0, 80) }
                            [void]$results.Add([PSCustomObject]@{
                                File       = $relPath
                                Line       = $match.data.line_number
                                Pattern    = $p.Description
                                Severity   = $p.Severity
                                Suggestion = $p.Suggestion
                                Match      = $matchText
                            })
                        }
                    } catch { }
                }
            } catch {
                # Pattern failed in rg — will be caught by PowerShell fallback below if needed
            }
        }
    } else {
        # Fallback: PowerShell file scanning (original implementation)
        $excludePattern = ($ExcludeDirs | ForEach-Object { [regex]::Escape($_) }) -join '|'
        $allExtensions = ($patterns | ForEach-Object { $_.Extensions }) | Select-Object -Unique

        foreach ($ext in $allExtensions) {
            $files = Get-ChildItem -Path $RepoRoot -Recurse -Filter "*$ext" -File -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch "[\\/]($excludePattern)[\\/]" }

            foreach ($file in $files) {
                try {
                    $lines = [System.IO.File]::ReadAllLines($file.FullName)
                }
                catch {
                    continue
                }

                for ($i = 0; $i -lt $lines.Count; $i++) {
                    $line = $lines[$i]
                    foreach ($p in $patterns) {
                        if ($p.Extensions -notcontains $ext) { continue }
                        if ($line -match $p.Regex) {
                            [void]$results.Add([PSCustomObject]@{
                                File       = $file.FullName.Replace($RepoRoot, '').TrimStart('\', '/')
                                Line       = $i + 1
                                Pattern    = $p.Description
                                Severity   = $p.Severity
                                Suggestion = $p.Suggestion
                                Match      = ($Matches[0]).Substring(0, [Math]::Min(80, $Matches[0].Length))
                            })
                        }
                    }
                }
            }
        }
    }

    return $results
}


function Find-StubImplementations {
    <#
    .SYNOPSIS
        Finds functions/methods with empty bodies, hooks returning static data,
        and API service methods that don't actually call fetch/axios.
    .PARAMETER RepoRoot
        Root directory of the repository to scan.
    .OUTPUTS
        Array of PSCustomObject with: File, Line, Type, Description, Suggestion
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string[]]$ExcludeDirs = @("node_modules", ".git", "bin", "obj", "dist", ".gsd", "coverage", ".next", "__pycache__", "design", "generated", "docs", ".planning", ".claude", "wwwroot", "packages", "TestResults")
    )

    $results = [System.Collections.ArrayList]::new()
    $excludePattern = ($ExcludeDirs | ForEach-Object { [regex]::Escape($_) }) -join '|'

    # OPTIMIZATION: Use ripgrep for fast pattern-based stub detection
    if ($script:UseRipgrep) {
        $rgExcludes = @($ExcludeDirs | ForEach-Object { "--glob=!$_/**" })

        # --- TypeScript/JavaScript stubs via rg ---
        $stubPatterns = @(
            @{ pattern = '=>\s*\{\s*\}'; type = 'empty_function'; desc = 'Empty arrow function body'; suggestion = 'Implement the function body with real logic'; types = @('ts', 'js') }
            @{ pattern = 'throw\s+new\s+NotImplementedException'; type = 'not_implemented'; desc = 'Method throws NotImplementedException'; suggestion = 'Implement the method with real logic'; types = @('cs') }
            @{ pattern = 'return\s+new\s+List<.*>\s*\{'; type = 'hardcoded_return'; desc = 'Repository/service returns hardcoded list'; suggestion = 'Use Dapper/EF to query real database via stored procedure'; types = @('cs'); fileFilter = '(?i)(repository|service|repo)' }
        )

        foreach ($sp in $stubPatterns) {
            try {
                $typeArgs = @($sp.types | ForEach-Object { "--type=$_" })
                $rgArgs = @("--json", "--no-heading") + $rgExcludes + $typeArgs + @("-e", $sp.pattern, $RepoRoot)
                $rgOutput = & rg @rgArgs 2>$null

                foreach ($line in $rgOutput) {
                    if (-not $line) { continue }
                    try {
                        $match = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
                        if ($match.type -eq 'match') {
                            $relPath = $match.data.path.text -replace [regex]::Escape($RepoRoot), '' -replace '^[\\/]', ''
                            # Apply file filter if specified
                            if ($sp.fileFilter -and $relPath -notmatch $sp.fileFilter) { continue }
                            [void]$results.Add([PSCustomObject]@{
                                File        = $relPath
                                Line        = $match.data.line_number
                                Type        = $sp.type
                                Description = $sp.desc
                                Suggestion  = $sp.suggestion
                            })
                        }
                    } catch { }
                }
            } catch { }
        }

        # Static hooks and fake services still need file-content analysis (multi-line checks)
        # Use rg to find candidate files quickly, then do targeted analysis
        try {
            $hookCandidates = & rg --files-with-matches --type ts --type js @rgExcludes -e '(function|const)\s+use[A-Z]' $RepoRoot 2>$null
            foreach ($filePath in $hookCandidates) {
                if (-not $filePath) { continue }
                try {
                    $lines = [System.IO.File]::ReadAllLines($filePath)
                    $relPath = $filePath -replace [regex]::Escape($RepoRoot), '' -replace '^[\\/]', ''
                    for ($i = 0; $i -lt $lines.Count; $i++) {
                        if ($lines[$i] -match '^\s*(export\s+)?(function|const)\s+use[A-Z]') {
                            $hookEnd = [Math]::Min($i + 30, $lines.Count - 1)
                            for ($j = $i; $j -le $hookEnd; $j++) {
                                if ($lines[$j] -match 'return\s+\[.*\{') {
                                    [void]$results.Add([PSCustomObject]@{
                                        File        = $relPath
                                        Line        = $j + 1
                                        Type        = 'static_hook'
                                        Description = 'Custom hook returns static/hardcoded data'
                                        Suggestion  = 'Hook should fetch from API using useQuery or useEffect+fetch'
                                    })
                                    break
                                }
                            }
                        }
                    }
                } catch { }
            }
        } catch { }

        # Fake service detection via rg
        try {
            $serviceCandidates = & rg --files-with-matches --type ts --type js @rgExcludes -e '(export|module\.exports)' --glob='*service*' --glob='*api*' --glob='*client*' $RepoRoot 2>$null
            foreach ($filePath in $serviceCandidates) {
                if (-not $filePath) { continue }
                try {
                    $content = [System.IO.File]::ReadAllText($filePath)
                    $relPath = $filePath -replace [regex]::Escape($RepoRoot), '' -replace '^[\\/]', ''
                    $hasFetch = $content -match '(fetch\s*\(|axios\.|\.get\(|\.post\(|\.put\(|\.delete\(|\.patch\(|httpClient|apiClient)'
                    if (-not $hasFetch) {
                        [void]$results.Add([PSCustomObject]@{
                            File        = $relPath
                            Line        = 1
                            Type        = 'fake_service'
                            Description = 'Service/API file does not contain any HTTP calls'
                            Suggestion  = 'Service must use fetch/axios to call real backend endpoints'
                        })
                    }
                } catch { }
            }
        } catch { }

        # Controller DI check via rg
        try {
            $controllerFiles = & rg --files-with-matches --type cs @rgExcludes --glob='*[Cc]ontroller*' -e '\[(HttpGet|HttpPost|HttpPut|HttpDelete|HttpPatch)\]' $RepoRoot 2>$null
            foreach ($filePath in $controllerFiles) {
                if (-not $filePath) { continue }
                try {
                    $content = [System.IO.File]::ReadAllText($filePath)
                    $relPath = $filePath -replace [regex]::Escape($RepoRoot), '' -replace '^[\\/]', ''
                    $hasInjection = $content -match 'private\s+readonly\s+I\w+'
                    if (-not $hasInjection) {
                        [void]$results.Add([PSCustomObject]@{
                            File        = $relPath
                            Line        = 1
                            Type        = 'no_di'
                            Description = 'Controller has actions but no injected services'
                            Suggestion  = 'Inject repository/service via constructor and use in actions'
                        })
                    }
                } catch { }
            }
        } catch { }

    } else {
        # Fallback: Original PowerShell file scanning

        # --- TypeScript/JavaScript stubs ---
        $tsFiles = Get-ChildItem -Path $RepoRoot -Recurse -Include *.ts, *.tsx, *.js, *.jsx -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch "[\\/]($excludePattern)[\\/]" }

        foreach ($file in $tsFiles) {
            try {
                $content = [System.IO.File]::ReadAllText($file.FullName)
                $lines = [System.IO.File]::ReadAllLines($file.FullName)
            }
            catch { continue }

            $relPath = $file.FullName.Replace($RepoRoot, '').TrimStart('\', '/')

            # Empty arrow functions: () => {} or () => { }
            $emptyArrowMatches = [regex]::Matches($content, '(?m)=>\s*\{\s*\}')
            foreach ($m in $emptyArrowMatches) {
                $lineNum = ($content.Substring(0, $m.Index) -split "`n").Count
                [void]$results.Add([PSCustomObject]@{
                    File        = $relPath
                    Line        = $lineNum
                    Type        = 'empty_function'
                    Description = 'Empty arrow function body'
                    Suggestion  = 'Implement the function body with real logic'
                })
            }

            # Custom hooks returning static arrays
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '^\s*(export\s+)?(function|const)\s+use[A-Z]') {
                    $hookEnd = [Math]::Min($i + 30, $lines.Count - 1)
                    for ($j = $i; $j -le $hookEnd; $j++) {
                        if ($lines[$j] -match 'return\s+\[.*\{') {
                            [void]$results.Add([PSCustomObject]@{
                                File        = $relPath
                                Line        = $j + 1
                                Type        = 'static_hook'
                                Description = 'Custom hook returns static/hardcoded data'
                                Suggestion  = 'Hook should fetch from API using useQuery or useEffect+fetch'
                            })
                            break
                        }
                    }
                }
            }

            # Service functions that don't call fetch/axios/api
            if ($relPath -match '(?i)(service|api|client)') {
                $hasFetch = $content -match '(fetch\s*\(|axios\.|\.get\(|\.post\(|\.put\(|\.delete\(|\.patch\(|httpClient|apiClient)'
                if (-not $hasFetch -and $content -match '(export|module\.exports)') {
                    [void]$results.Add([PSCustomObject]@{
                        File        = $relPath
                        Line        = 1
                        Type        = 'fake_service'
                        Description = 'Service/API file does not contain any HTTP calls'
                        Suggestion  = 'Service must use fetch/axios to call real backend endpoints'
                    })
                }
            }
        }

        # --- C# stubs ---
        $csFiles = Get-ChildItem -Path $RepoRoot -Recurse -Include *.cs -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch "[\\/]($excludePattern)[\\/]" }

        foreach ($file in $csFiles) {
            try {
                $content = [System.IO.File]::ReadAllText($file.FullName)
                $lines = [System.IO.File]::ReadAllLines($file.FullName)
            }
            catch { continue }

            $relPath = $file.FullName.Replace($RepoRoot, '').TrimStart('\', '/')

            # Methods that throw NotImplementedException
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match 'throw\s+new\s+NotImplementedException') {
                    [void]$results.Add([PSCustomObject]@{
                        File        = $relPath
                        Line        = $i + 1
                        Type        = 'not_implemented'
                        Description = 'Method throws NotImplementedException'
                        Suggestion  = 'Implement the method with real logic'
                    })
                }
            }

            # Repository/service methods returning hardcoded data
            if ($relPath -match '(?i)(repository|service|repo)') {
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    if ($lines[$i] -match 'return\s+new\s+List<.*>\s*\{') {
                        [void]$results.Add([PSCustomObject]@{
                            File        = $relPath
                            Line        = $i + 1
                            Type        = 'hardcoded_return'
                            Description = 'Repository/service returns hardcoded list'
                            Suggestion  = 'Use Dapper/EF to query real database via stored procedure'
                        })
                    }
                }
            }

            # Controller actions not using injected services
            if ($relPath -match '(?i)controller') {
                $hasInjection = $content -match 'private\s+readonly\s+I\w+'
                $hasAction = $content -match '\[(HttpGet|HttpPost|HttpPut|HttpDelete|HttpPatch)\]'
                if ($hasAction -and -not $hasInjection) {
                    [void]$results.Add([PSCustomObject]@{
                        File        = $relPath
                        Line        = 1
                        Type        = 'no_di'
                        Description = 'Controller has actions but no injected services'
                        Suggestion  = 'Inject repository/service via constructor and use in actions'
                    })
                }
            }
        }
    }

    return $results
}


function Find-PlaceholderConfigs {
    <#
    .SYNOPSIS
        Finds configuration files with placeholder values that will prevent
        the application from connecting to real services.
    .PARAMETER RepoRoot
        Root directory of the repository to scan.
    .OUTPUTS
        Array of PSCustomObject with: File, Line, ConfigKey, PlaceholderValue, Suggestion
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string[]]$ExcludeDirs = @("node_modules", ".git", "bin", "obj", "dist", ".gsd")
    )

    $results = [System.Collections.ArrayList]::new()
    $excludePattern = ($ExcludeDirs | ForEach-Object { [regex]::Escape($_) }) -join '|'

    # Placeholder patterns for config files
    $configPatterns = @(
        @{
            Regex   = '(?i)"(ConnectionString|DefaultConnection)"\s*:\s*"[^"]*?(YOUR_SERVER|YOURSERVER|localhost\\\\SQLEXPRESS|changeme|placeholder)'
            Key     = 'Database Connection String'
            Suggestion = 'Set real SQL Server connection string with valid server, database, and credentials'
        },
        @{
            Regex   = '(?i)"(ClientId|client_id)"\s*:\s*"(your-|00000000-0000|xxxxxxxx|CHANGE|placeholder|<)'
            Key     = 'Azure AD Client ID'
            Suggestion = 'Set real Azure AD application (client) ID'
        },
        @{
            Regex   = '(?i)"(TenantId|tenant_id)"\s*:\s*"(your-|00000000-0000|xxxxxxxx|CHANGE|placeholder|common|<)'
            Key     = 'Azure AD Tenant ID'
            Suggestion = 'Set real Azure AD tenant ID'
        },
        @{
            Regex   = '(?i)"(Authority|Instance)"\s*:\s*"[^"]*?(your-tenant|placeholder|example)'
            Key     = 'Auth Authority'
            Suggestion = 'Set real authentication authority URL'
        },
        @{
            Regex   = '(?i)"(ApiBaseUrl|BaseUrl|API_URL|REACT_APP_API_URL|VITE_API_URL)"\s*:\s*"(https?://localhost:0+|https?://example\.com|https?://your-api|placeholder|changeme|<)'
            Key     = 'API Base URL'
            Suggestion = 'Set real API base URL pointing to backend server'
        },
        @{
            Regex   = '(?i)"(Secret|SecretKey|JwtSecret|SigningKey)"\s*:\s*"(changeme|your-secret|placeholder|secret|<|xxx)'
            Key     = 'Secret/Signing Key'
            Suggestion = 'Generate and set a real cryptographic secret (min 256-bit)'
        },
        @{
            Regex   = '(?i)"(RedirectUri|redirect_uri|PostLogoutRedirectUri)"\s*:\s*"(https?://localhost:0+|https?://example\.com|placeholder|changeme|<)'
            Key     = 'Redirect URI'
            Suggestion = 'Set real redirect URI matching Azure AD app registration'
        }
    )

    # OPTIMIZATION: Use ripgrep for fast config file scanning
    if ($script:UseRipgrep) {
        $rgExcludes = @($ExcludeDirs | ForEach-Object { "--glob=!$_/**" })

        foreach ($p in $configPatterns) {
            try {
                $rgArgs = @("--json", "--no-heading") + $rgExcludes + @(
                    "--glob=*.json", "--glob=*.config", "--glob=*.env", "--glob=*.env.*",
                    "--glob=!package-lock.json", "--glob=!package.json",
                    "-e", $p.Regex, $RepoRoot
                )
                $rgOutput = & rg @rgArgs 2>$null

                foreach ($line in $rgOutput) {
                    if (-not $line) { continue }
                    try {
                        $match = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
                        if ($match.type -eq 'match') {
                            $relPath = $match.data.path.text -replace [regex]::Escape($RepoRoot), '' -replace '^[\\/]', ''
                            $matchText = if ($match.data.lines.text) { $match.data.lines.text.Trim() } else { "" }
                            if ($matchText.Length -gt 80) { $matchText = $matchText.Substring(0, 80) }
                            [void]$results.Add([PSCustomObject]@{
                                File             = $relPath
                                Line             = $match.data.line_number
                                ConfigKey        = $p.Key
                                PlaceholderValue = $matchText
                                Suggestion       = $p.Suggestion
                            })
                        }
                    } catch { }
                }
            } catch { }
        }

        # .env placeholder scan via rg
        try {
            $envPattern = '(?i)^(REACT_APP_|VITE_|NEXT_PUBLIC_)?\w*(API|URL|SECRET|KEY|TOKEN|PASSWORD|CONNECTION)\w*\s*=\s*(changeme|placeholder|your-|xxxx|TODO|<)'
            $rgArgs = @("--json", "--no-heading") + $rgExcludes + @(
                "--glob=.env", "--glob=.env.*",
                "-e", $envPattern, $RepoRoot
            )
            $rgOutput = & rg @rgArgs 2>$null

            foreach ($line in $rgOutput) {
                if (-not $line) { continue }
                try {
                    $match = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
                    if ($match.type -eq 'match') {
                        $relPath = $match.data.path.text -replace [regex]::Escape($RepoRoot), '' -replace '^[\\/]', ''
                        $matchText = if ($match.data.lines.text) { $match.data.lines.text.Trim() } else { "" }
                        $parts = $matchText -split '=', 2
                        [void]$results.Add([PSCustomObject]@{
                            File             = $relPath
                            Line             = $match.data.line_number
                            ConfigKey        = $parts[0].Trim()
                            PlaceholderValue = if ($parts.Count -gt 1) { $parts[1].Trim() } else { "" }
                            Suggestion       = 'Set real value for this environment variable'
                        })
                    }
                } catch { }
            }
        } catch { }

    } else {
        # Fallback: Original PowerShell scanning

        # Scan JSON and config files
        $configFiles = Get-ChildItem -Path $RepoRoot -Recurse -Include *.json, *.config, *.env, *.env.*, appsettings*.json -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch "[\\/]($excludePattern)[\\/]" -and $_.Name -ne 'package-lock.json' -and $_.Name -ne 'package.json' }

        foreach ($file in $configFiles) {
            try {
                $lines = [System.IO.File]::ReadAllLines($file.FullName)
            }
            catch { continue }

            $relPath = $file.FullName.Replace($RepoRoot, '').TrimStart('\', '/')

            for ($i = 0; $i -lt $lines.Count; $i++) {
                foreach ($p in $configPatterns) {
                    if ($lines[$i] -match $p.Regex) {
                        [void]$results.Add([PSCustomObject]@{
                            File             = $relPath
                            Line             = $i + 1
                            ConfigKey        = $p.Key
                            PlaceholderValue = ($Matches[0]).Substring(0, [Math]::Min(80, $Matches[0].Length))
                            Suggestion       = $p.Suggestion
                        })
                    }
                }
            }
        }

        # Also scan .env files specifically
        $envFiles = Get-ChildItem -Path $RepoRoot -Recurse -Include .env, .env.local, .env.development, .env.production -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch "[\\/]($excludePattern)[\\/]" }

        foreach ($file in $envFiles) {
            try {
                $lines = [System.IO.File]::ReadAllLines($file.FullName)
            }
            catch { continue }

            $relPath = $file.FullName.Replace($RepoRoot, '').TrimStart('\', '/')

            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '(?i)^(REACT_APP_|VITE_|NEXT_PUBLIC_)?\w*(API|URL|SECRET|KEY|TOKEN|PASSWORD|CONNECTION)\w*\s*=\s*(changeme|placeholder|your-|xxxx|TODO|<|$)') {
                    [void]$results.Add([PSCustomObject]@{
                        File             = $relPath
                        Line             = $i + 1
                        ConfigKey        = ($Matches[0] -split '=')[0].Trim()
                        PlaceholderValue = ($Matches[0] -split '=', 2)[1].Trim()
                        Suggestion       = 'Set real value for this environment variable'
                    })
                }
            }
        }
    }

    return $results
}


function Get-MockDataSeverity {
    <#
    .SYNOPSIS
        Assigns severity to mock data findings locally based on pattern type.
        No LLM needed — pure algorithmic classification.
    .PARAMETER Finding
        A PSCustomObject from Find-MockDataPatterns, Find-StubImplementations, or Find-PlaceholderConfigs.
    .OUTPUTS
        String: "critical", "high", "medium", or "low"
    #>
    param(
        [Parameter(Mandatory)]$Finding
    )

    # If the finding already has a severity from the pattern definition, use it
    if ($Finding.Severity) {
        return $Finding.Severity
    }

    $desc = ""
    if ($Finding.Description) { $desc = $Finding.Description }
    if ($Finding.Pattern) { $desc = $Finding.Pattern }
    if ($Finding.Type) { $desc += " $($Finding.Type)" }

    # CRITICAL: hardcoded credentials, secrets in code, placeholder connection strings
    if ($desc -match '(?i)(credential|password|secret|apikey|connection.?string|placeholder.*(url|uri|connection))') {
        return 'critical'
    }
    if ($Finding.ConfigKey -and $Finding.ConfigKey -match '(?i)(secret|password|key|connection)') {
        return 'critical'
    }

    # HIGH: mock/static data in production pages, fake services, stub hooks
    if ($desc -match '(?i)(mock.?data|fake.?service|static.?hook|hardcoded.?(return|list|array)|no.?http|import.*mock|promise\.resolve)') {
        return 'high'
    }
    if ($Finding.Type -and $Finding.Type -in @('fake_service', 'static_hook', 'hardcoded_return', 'not_implemented', 'no_di')) {
        return 'high'
    }

    # MEDIUM: TODO/FIXME markers, console.log statements, empty functions
    if ($desc -match '(?i)(TODO|FIXME|HACK|PLACEHOLDER|console\.|empty.?function|empty.?arrow)') {
        return 'medium'
    }
    if ($Finding.Type -and $Finding.Type -eq 'empty_function') {
        return 'medium'
    }

    # LOW: unused imports, commented-out code, hardcoded role assignments
    if ($desc -match '(?i)(unused|commented|dead.?code|role.?assignment|low)') {
        return 'low'
    }

    # Default to medium if unknown
    return 'medium'
}


function Invoke-MockDataScan {
    <#
    .SYNOPSIS
        Runs all mock data detection scans and produces a consolidated report.
    .PARAMETER RepoRoot
        Root directory of the repository to scan.
    .PARAMETER OutputFile
        Optional path to write JSON results.
    .OUTPUTS
        PSCustomObject with MockPatterns, StubImplementations, PlaceholderConfigs, and Summary.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$OutputFile
    )

    Write-Host "=== Mock Data Detector ===" -ForegroundColor Cyan
    Write-Host "Scanning: $RepoRoot" -ForegroundColor Gray

    Write-Host "`n[1/3] Scanning for mock data patterns..." -ForegroundColor Yellow
    $mockPatterns = Find-MockDataPatterns -RepoRoot $RepoRoot
    Write-Host "  Found $($mockPatterns.Count) mock data patterns"

    Write-Host "[2/3] Scanning for stub implementations..." -ForegroundColor Yellow
    $stubs = Find-StubImplementations -RepoRoot $RepoRoot
    Write-Host "  Found $($stubs.Count) stub implementations"

    Write-Host "[3/3] Scanning for placeholder configs..." -ForegroundColor Yellow
    $placeholders = Find-PlaceholderConfigs -RepoRoot $RepoRoot
    Write-Host "  Found $($placeholders.Count) placeholder configs"

    # Build summary
    $criticalCount = @($mockPatterns | Where-Object Severity -eq 'critical').Count +
                     @($placeholders).Count
    $highCount = @($mockPatterns | Where-Object Severity -eq 'high').Count +
                 @($stubs).Count

    $report = [PSCustomObject]@{
        MockPatterns        = $mockPatterns
        StubImplementations = $stubs
        PlaceholderConfigs  = $placeholders
        Summary             = [PSCustomObject]@{
            TotalIssues     = $mockPatterns.Count + $stubs.Count + $placeholders.Count
            CriticalCount   = $criticalCount
            HighCount       = $highCount
            MediumCount     = @($mockPatterns | Where-Object Severity -eq 'medium').Count
            LowCount        = @($mockPatterns | Where-Object Severity -eq 'low').Count
            IntegrationReady = ($criticalCount -eq 0 -and $highCount -eq 0)
        }
    }

    Write-Host "`n=== Summary ===" -ForegroundColor Cyan
    Write-Host "  Total issues:  $($report.Summary.TotalIssues)"
    Write-Host "  Critical:      $($report.Summary.CriticalCount)" -ForegroundColor $(if ($report.Summary.CriticalCount -gt 0) { 'Red' } else { 'Green' })
    Write-Host "  High:          $($report.Summary.HighCount)" -ForegroundColor $(if ($report.Summary.HighCount -gt 0) { 'Yellow' } else { 'Green' })
    Write-Host "  Medium:        $($report.Summary.MediumCount)"
    Write-Host "  Low:           $($report.Summary.LowCount)"
    Write-Host "  Integration-ready: $($report.Summary.IntegrationReady)" -ForegroundColor $(if ($report.Summary.IntegrationReady) { 'Green' } else { 'Red' })

    if ($OutputFile) {
        $report | ConvertTo-Json -Depth 5 | Set-Content -Path $OutputFile -Encoding UTF8
        Write-Host "`nResults written to: $OutputFile" -ForegroundColor Gray
    }

    return $report
}
