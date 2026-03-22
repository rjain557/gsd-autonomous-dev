<#
.SYNOPSIS
    GSD V3 Integration Smoke Test - Post-convergence integration checks
.DESCRIPTION
    Runs lightweight static-analysis checks after convergence to catch
    integration gaps the pipeline can't see from individual file reviews:
    - Mock/hardcoded data left in production components
    - Missing DI registrations for service/repository interfaces
    - Placeholder or missing connection strings
    - Backend endpoints without matching frontend API calls
    - Stored procedures referenced in code but missing SQL files
#>

# ============================================================
# 1. MOCK DATA SCANNER
# ============================================================

function Test-MockDataPresence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot
    )

    $violations = @()

    # Find all src/ directories that contain .tsx files
    $srcDirs = @()
    foreach ($candidate in @("src", "client", "frontend", "app")) {
        $dir = Join-Path $RepoRoot $candidate
        if (Test-Path $dir) { $srcDirs += $dir }
    }
    if ($srcDirs.Count -eq 0) { return $violations }

    # Patterns that indicate mock/inline data
    $mockPatterns = @(
        'const\s+\w*[Dd]ata\s*=\s*\['
        'const\s+mock\w*\s*='
        'const\s+fake\w*\s*='
        'const\s+dummy\w*\s*='
        'const\s+sample\w*\s*='
        'const\s+stub\w*\s*='
    )

    # Patterns that indicate real API usage
    $apiPatterns = @(
        'useQuery', 'useMutation', 'useInfiniteQuery',
        'fetch\s*\(', 'apiClient', 'axios',
        'useSWR', 'createApi', 'baseQuery'
    )

    foreach ($srcDir in $srcDirs) {
        $tsxFiles = Get-ChildItem -Path $srcDir -Filter "*.tsx" -Recurse -ErrorAction SilentlyContinue
        if (-not $tsxFiles) { continue }

        foreach ($file in $tsxFiles) {
            try {
                $content = Get-Content -Path $file.FullName -Raw -ErrorAction Stop
                $lines = Get-Content -Path $file.FullName -ErrorAction Stop

                # Check for mock data patterns
                foreach ($pattern in $mockPatterns) {
                    for ($i = 0; $i -lt $lines.Count; $i++) {
                        if ($lines[$i] -match $pattern) {
                            # Check if file also has API calls
                            $hasApi = $false
                            foreach ($ap in $apiPatterns) {
                                if ($content -match $ap) { $hasApi = $true; break }
                            }
                            if (-not $hasApi) {
                                $violations += [PSCustomObject]@{
                                    File        = $file.FullName.Replace($RepoRoot, '').TrimStart('\', '/')
                                    Line        = $i + 1
                                    Pattern     = $pattern
                                    Description = "Inline data array without API hook"
                                }
                            }
                        }
                    }
                }

                # Check page components with zero API calls
                $relPath = $file.FullName.Replace($RepoRoot, '').TrimStart('\', '/')
                if ($relPath -match '(pages|screens)[/\\]') {
                    $hasApi = $false
                    foreach ($ap in $apiPatterns) {
                        if ($content -match $ap) { $hasApi = $true; break }
                    }
                    if (-not $hasApi -and $content.Length -gt 200) {
                        $violations += [PSCustomObject]@{
                            File        = $relPath
                            Line        = 1
                            Pattern     = "(no API calls in page component)"
                            Description = "Page component has no API/fetch/useQuery calls"
                        }
                    }
                }
            }
            catch {
                # Skip unreadable files
            }
        }
    }

    return $violations
}

# ============================================================
# 2. DI WIRING CHECKER
# ============================================================

function Test-DIRegistration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot
    )

    $violations = @()

    # Find interface files
    $interfaceFiles = Get-ChildItem -Path $RepoRoot -Recurse -Include "I*Service.cs", "I*Repository.cs" -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '(bin|obj|node_modules)[/\\]' }

    if (-not $interfaceFiles -or $interfaceFiles.Count -eq 0) { return $violations }

    # Find Program.cs or Startup.cs
    $registrationFile = $null
    $registrationContent = ""
    foreach ($name in @("Program.cs", "Startup.cs")) {
        $found = Get-ChildItem -Path $RepoRoot -Filter $name -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '(bin|obj|node_modules|test)[/\\]' } |
            Select-Object -First 1
        if ($found) {
            $registrationFile = $found.FullName
            $registrationContent = Get-Content -Path $found.FullName -Raw -ErrorAction SilentlyContinue
            break
        }
    }

    if (-not $registrationFile) {
        $violations += [PSCustomObject]@{
            Interface = "(none)"
            File      = "Program.cs / Startup.cs"
            Message   = "No DI registration file found"
        }
        return $violations
    }

    foreach ($iface in $interfaceFiles) {
        # Extract interface name from filename: IUserService.cs -> IUserService
        $interfaceName = [System.IO.Path]::GetFileNameWithoutExtension($iface.Name)

        # Check for AddScoped<IFoo>, AddTransient<IFoo>, AddSingleton<IFoo>
        $registered = $registrationContent -match "Add(Scoped|Transient|Singleton)\s*<\s*$interfaceName"
        # Also check for extension method registrations like services.AddXxx() that might register it
        if (-not $registered) {
            $registered = $registrationContent -match "$interfaceName\s*,"
        }
        if (-not $registered) {
            $registered = $registrationContent -match "$interfaceName\s*>"
        }

        if (-not $registered) {
            $violations += [PSCustomObject]@{
                Interface = $interfaceName
                File      = $iface.FullName.Replace($RepoRoot, '').TrimStart('\', '/')
                Message   = "No AddScoped/AddTransient/AddSingleton registration found in $($registrationFile.Replace($RepoRoot, '').TrimStart('\', '/'))"
            }
        }
    }

    return $violations
}

# ============================================================
# 3. CONNECTION STRING VALIDATOR
# ============================================================

function Test-ConnectionStringConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot
    )

    $results = @()

    $placeholderPatterns = @(
        '^Server=\.;Database=\w+$',
        '^Server=\(localdb\)',
        'your[-_]?connection[-_]?string',
        'REPLACE_ME',
        'TODO',
        '^\s*$'
    )

    $configFiles = @("appsettings.json", "appsettings.Development.json")

    foreach ($configName in $configFiles) {
        $found = Get-ChildItem -Path $RepoRoot -Filter $configName -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '(bin|obj|node_modules)[/\\]' } |
            Select-Object -First 1

        if (-not $found) { continue }

        try {
            $json = Get-Content -Path $found.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop

            if (-not $json.ConnectionStrings) {
                $results += [PSCustomObject]@{
                    File    = $found.FullName.Replace($RepoRoot, '').TrimStart('\', '/')
                    Status  = "fail"
                    Message = "Missing ConnectionStrings section"
                }
                continue
            }

            $connStrings = $json.ConnectionStrings
            $props = $connStrings.PSObject.Properties
            if ($props.Count -eq 0) {
                $results += [PSCustomObject]@{
                    File    = $found.FullName.Replace($RepoRoot, '').TrimStart('\', '/')
                    Status  = "fail"
                    Message = "ConnectionStrings section is empty"
                }
                continue
            }

            foreach ($prop in $props) {
                $value = "$($prop.Value)"
                $isPlaceholder = $false
                foreach ($pp in $placeholderPatterns) {
                    if ($value -match $pp) { $isPlaceholder = $true; break }
                }

                if ([string]::IsNullOrWhiteSpace($value)) {
                    $results += [PSCustomObject]@{
                        File    = $found.FullName.Replace($RepoRoot, '').TrimStart('\', '/')
                        Status  = "fail"
                        Message = "ConnectionStrings.$($prop.Name) is empty"
                    }
                }
                elseif ($isPlaceholder) {
                    $results += [PSCustomObject]@{
                        File    = $found.FullName.Replace($RepoRoot, '').TrimStart('\', '/')
                        Status  = "warn"
                        Message = "ConnectionStrings.$($prop.Name) looks like a placeholder"
                    }
                }
                else {
                    $results += [PSCustomObject]@{
                        File    = $found.FullName.Replace($RepoRoot, '').TrimStart('\', '/')
                        Status  = "pass"
                        Message = "ConnectionStrings.$($prop.Name) is configured"
                    }
                }
            }
        }
        catch {
            $results += [PSCustomObject]@{
                File    = $found.FullName.Replace($RepoRoot, '').TrimStart('\', '/')
                Status  = "fail"
                Message = "Failed to parse JSON: $($_.Exception.Message)"
            }
        }
    }

    return $results
}

# ============================================================
# 4. API CLIENT COMPLETENESS
# ============================================================

function Test-ApiClientCompleteness {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot
    )

    $violations = @()

    # Find controller files
    $controllers = Get-ChildItem -Path $RepoRoot -Filter "*Controller.cs" -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '(bin|obj|node_modules|test)[/\\]' }

    if (-not $controllers -or $controllers.Count -eq 0) { return $violations }

    # Extract endpoints from controllers
    $endpoints = @()
    $httpVerbs = @('HttpGet', 'HttpPost', 'HttpPut', 'HttpDelete', 'HttpPatch')

    foreach ($ctrl in $controllers) {
        try {
            $lines = Get-Content -Path $ctrl.FullName -ErrorAction Stop
            $controllerName = [System.IO.Path]::GetFileNameWithoutExtension($ctrl.Name) -replace 'Controller$', ''

            # Extract route prefix
            $routePrefix = ""
            foreach ($line in $lines) {
                if ($line -match '\[Route\(\s*"([^"]+)"\s*\)\]') {
                    $routePrefix = $matches[1] -replace '\[controller\]', $controllerName.ToLower()
                    break
                }
            }

            for ($i = 0; $i -lt $lines.Count; $i++) {
                foreach ($verb in $httpVerbs) {
                    if ($lines[$i] -match "\[$verb(\(`"([^`"]*)`"\))?\]") {
                        $route = if ($matches[2]) { $matches[2] } else { "" }
                        $fullRoute = if ($routePrefix) { "$routePrefix/$route".TrimEnd('/') } else { $route }

                        # Get method name from next non-attribute line
                        $methodName = ""
                        for ($j = $i + 1; $j -lt [Math]::Min($i + 5, $lines.Count); $j++) {
                            if ($lines[$j] -match '(public|private|protected)\s+.*?\s+(\w+)\s*\(') {
                                $methodName = $matches[2]
                                break
                            }
                        }

                        $endpoints += [PSCustomObject]@{
                            Controller = $controllerName
                            Verb       = $verb -replace 'Http', ''
                            Route      = $fullRoute
                            Method     = $methodName
                            File       = $ctrl.FullName.Replace($RepoRoot, '').TrimStart('\', '/')
                        }
                    }
                }
            }
        }
        catch {
            # Skip unreadable controller
        }
    }

    if ($endpoints.Count -eq 0) { return $violations }

    # Find frontend API client/service files
    $apiFilePatterns = @("*api*", "*Api*", "*service*", "*Service*", "*client*", "*Client*")
    $frontendContent = ""

    foreach ($srcDir in @("src", "client", "frontend", "app")) {
        $dir = Join-Path $RepoRoot $srcDir
        if (-not (Test-Path $dir)) { continue }

        foreach ($pat in $apiFilePatterns) {
            $apiFiles = Get-ChildItem -Path $dir -Filter "$pat.ts" -Recurse -ErrorAction SilentlyContinue
            $apiFiles += Get-ChildItem -Path $dir -Filter "$pat.tsx" -Recurse -ErrorAction SilentlyContinue
            foreach ($af in $apiFiles) {
                try {
                    $frontendContent += "`n" + (Get-Content -Path $af.FullName -Raw -ErrorAction Stop)
                }
                catch { }
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($frontendContent)) { return $violations }

    # Check each endpoint for a matching frontend call
    foreach ($ep in $endpoints) {
        $found = $false
        # Search by route segments or method name
        $searchTerms = @($ep.Method)
        if ($ep.Route) {
            # Add route segments (last meaningful part)
            $segments = $ep.Route -split '/' | Where-Object { $_ -and $_ -notmatch '^\{' -and $_ -ne 'api' }
            $searchTerms += $segments
        }

        foreach ($term in $searchTerms) {
            if ($term -and $frontendContent -match [regex]::Escape($term)) {
                $found = $true
                break
            }
        }

        if (-not $found) {
            $violations += [PSCustomObject]@{
                Controller = $ep.Controller
                Verb       = $ep.Verb
                Route      = $ep.Route
                Method     = $ep.Method
                File       = $ep.File
                Message    = "No matching frontend API call found"
            }
        }
    }

    return $violations
}

# ============================================================
# 5. STORED PROCEDURE DEPLOYMENT CHECK
# ============================================================

function Test-StoredProcDeployment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot
    )

    $violations = @()

    # Find all usp_ references in C# files
    $csFiles = Get-ChildItem -Path $RepoRoot -Filter "*.cs" -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '(bin|obj|node_modules)[/\\]' }

    if (-not $csFiles -or $csFiles.Count -eq 0) { return $violations }

    $referencedProcs = @{}

    foreach ($cs in $csFiles) {
        try {
            $content = Get-Content -Path $cs.FullName -Raw -ErrorAction Stop
            $procMatches = [regex]::Matches($content, 'usp_\w+')
            foreach ($m in $procMatches) {
                $procName = $m.Value
                if (-not $referencedProcs.ContainsKey($procName)) {
                    $referencedProcs[$procName] = @()
                }
                $referencedProcs[$procName] += $cs.FullName.Replace($RepoRoot, '').TrimStart('\', '/')
            }
        }
        catch { }
    }

    if ($referencedProcs.Count -eq 0) { return $violations }

    # Check if sqlcmd is available and we have a connection string
    $useSqlcmd = $false
    $connString = ""

    try {
        $sqlcmdPath = Get-Command sqlcmd -ErrorAction Stop
        # Try to get connection string from appsettings
        $appSettings = Get-ChildItem -Path $RepoRoot -Filter "appsettings.json" -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '(bin|obj|node_modules)[/\\]' } |
            Select-Object -First 1
        if ($appSettings) {
            $json = Get-Content -Path $appSettings.FullName -Raw | ConvertFrom-Json -ErrorAction Stop
            if ($json.ConnectionStrings) {
                $firstConn = $json.ConnectionStrings.PSObject.Properties | Select-Object -First 1
                if ($firstConn -and $firstConn.Value -and $firstConn.Value -notmatch '(TODO|REPLACE|placeholder)') {
                    $connString = $firstConn.Value
                    $useSqlcmd = $true
                }
            }
        }
    }
    catch {
        $useSqlcmd = $false
    }

    if ($useSqlcmd -and $connString) {
        # Live DB check
        try {
            foreach ($procName in $referencedProcs.Keys) {
                $query = "SELECT COUNT(*) FROM sys.procedures WHERE name = '$procName'"
                $result = sqlcmd -S ($connString -replace '.*Server=([^;]+).*', '$1') -Q $query -h -1 2>$null
                $count = ($result | Select-String '\d+' | Select-Object -First 1).Matches[0].Value
                if ([int]$count -eq 0) {
                    $violations += [PSCustomObject]@{
                        ProcName     = $procName
                        ReferencedIn = $referencedProcs[$procName]
                        CheckType    = "live-db"
                        Message      = "Stored procedure not found in database"
                    }
                }
            }
        }
        catch {
            # Fall back to static check on error
            $useSqlcmd = $false
        }
    }

    if (-not $useSqlcmd) {
        # Static check: look for matching .sql files
        $sqlFiles = Get-ChildItem -Path $RepoRoot -Filter "*.sql" -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '(bin|obj|node_modules)[/\\]' }

        $sqlContent = ""
        foreach ($sf in $sqlFiles) {
            try {
                $sqlContent += "`n" + (Get-Content -Path $sf.FullName -Raw -ErrorAction Stop)
            }
            catch { }
        }

        foreach ($procName in $referencedProcs.Keys) {
            if (-not ($sqlContent -match $procName)) {
                $violations += [PSCustomObject]@{
                    ProcName     = $procName
                    ReferencedIn = $referencedProcs[$procName]
                    CheckType    = "static-file"
                    Message      = "No .sql file found containing this stored procedure"
                }
            }
        }
    }

    return $violations
}

# ============================================================
# 6. MAIN ENTRY POINT
# ============================================================

function Invoke-IntegrationSmokeTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot
    )

    $details = @()
    $totalChecks = 0
    $passed = 0
    $failed = 0
    $warnings = 0

    # --- Check 1: Mock Data ---
    $totalChecks++
    try {
        $mockResults = Test-MockDataPresence -RepoRoot $RepoRoot
        if ($mockResults.Count -eq 0) {
            $passed++
            $details += [PSCustomObject]@{
                CheckName = "MockDataPresence"
                Status    = "pass"
                Message   = "No mock/inline data violations found"
                Files     = @()
            }
        }
        else {
            $failed++
            $affectedFiles = @($mockResults | ForEach-Object { $_.File } | Select-Object -Unique)
            $details += [PSCustomObject]@{
                CheckName = "MockDataPresence"
                Status    = "fail"
                Message   = "$($mockResults.Count) violation(s) in $($affectedFiles.Count) file(s)"
                Files     = $affectedFiles
            }
        }
    }
    catch {
        $warnings++
        $details += [PSCustomObject]@{
            CheckName = "MockDataPresence"
            Status    = "warn"
            Message   = "Check error: $($_.Exception.Message)"
            Files     = @()
        }
    }

    # --- Check 2: DI Registration ---
    $totalChecks++
    try {
        $diResults = Test-DIRegistration -RepoRoot $RepoRoot
        if ($diResults.Count -eq 0) {
            $passed++
            $details += [PSCustomObject]@{
                CheckName = "DIRegistration"
                Status    = "pass"
                Message   = "All interfaces have DI registrations (or no backend found)"
                Files     = @()
            }
        }
        else {
            $failed++
            $affectedFiles = @($diResults | ForEach-Object { $_.File } | Select-Object -Unique)
            $details += [PSCustomObject]@{
                CheckName = "DIRegistration"
                Status    = "fail"
                Message   = "$($diResults.Count) interface(s) missing DI registration"
                Files     = $affectedFiles
            }
        }
    }
    catch {
        $warnings++
        $details += [PSCustomObject]@{
            CheckName = "DIRegistration"
            Status    = "warn"
            Message   = "Check error: $($_.Exception.Message)"
            Files     = @()
        }
    }

    # --- Check 3: Connection String ---
    $totalChecks++
    try {
        $connResults = Test-ConnectionStringConfig -RepoRoot $RepoRoot
        if ($connResults.Count -eq 0) {
            $passed++
            $details += [PSCustomObject]@{
                CheckName = "ConnectionStringConfig"
                Status    = "pass"
                Message   = "No appsettings.json found (no backend, or non-.NET project)"
                Files     = @()
            }
        }
        else {
            $hasFail = $connResults | Where-Object { $_.Status -eq "fail" }
            $hasWarn = $connResults | Where-Object { $_.Status -eq "warn" }
            $affectedFiles = @($connResults | ForEach-Object { $_.File } | Select-Object -Unique)

            if ($hasFail) {
                $failed++
                $details += [PSCustomObject]@{
                    CheckName = "ConnectionStringConfig"
                    Status    = "fail"
                    Message   = ($hasFail | ForEach-Object { $_.Message }) -join "; "
                    Files     = $affectedFiles
                }
            }
            elseif ($hasWarn) {
                $warnings++
                $details += [PSCustomObject]@{
                    CheckName = "ConnectionStringConfig"
                    Status    = "warn"
                    Message   = ($hasWarn | ForEach-Object { $_.Message }) -join "; "
                    Files     = $affectedFiles
                }
            }
            else {
                $passed++
                $details += [PSCustomObject]@{
                    CheckName = "ConnectionStringConfig"
                    Status    = "pass"
                    Message   = "Connection strings configured"
                    Files     = $affectedFiles
                }
            }
        }
    }
    catch {
        $warnings++
        $details += [PSCustomObject]@{
            CheckName = "ConnectionStringConfig"
            Status    = "warn"
            Message   = "Check error: $($_.Exception.Message)"
            Files     = @()
        }
    }

    # --- Check 4: API Client Completeness ---
    $totalChecks++
    try {
        $apiResults = Test-ApiClientCompleteness -RepoRoot $RepoRoot
        if ($apiResults.Count -eq 0) {
            $passed++
            $details += [PSCustomObject]@{
                CheckName = "ApiClientCompleteness"
                Status    = "pass"
                Message   = "All backend endpoints have frontend coverage (or no controllers found)"
                Files     = @()
            }
        }
        else {
            $warnings++
            $affectedFiles = @($apiResults | ForEach-Object { $_.File } | Select-Object -Unique)
            $details += [PSCustomObject]@{
                CheckName = "ApiClientCompleteness"
                Status    = "warn"
                Message   = "$($apiResults.Count) endpoint(s) without matching frontend calls"
                Files     = $affectedFiles
            }
        }
    }
    catch {
        $warnings++
        $details += [PSCustomObject]@{
            CheckName = "ApiClientCompleteness"
            Status    = "warn"
            Message   = "Check error: $($_.Exception.Message)"
            Files     = @()
        }
    }

    # --- Check 5: Stored Proc Deployment ---
    $totalChecks++
    try {
        $spResults = Test-StoredProcDeployment -RepoRoot $RepoRoot
        if ($spResults.Count -eq 0) {
            $passed++
            $details += [PSCustomObject]@{
                CheckName = "StoredProcDeployment"
                Status    = "pass"
                Message   = "All referenced stored procedures have matching SQL files (or none referenced)"
                Files     = @()
            }
        }
        else {
            $failed++
            $refFiles = @()
            foreach ($sp in $spResults) {
                $refFiles += $sp.ReferencedIn
            }
            $refFiles = @($refFiles | Select-Object -Unique)
            $details += [PSCustomObject]@{
                CheckName = "StoredProcDeployment"
                Status    = "fail"
                Message   = "$($spResults.Count) stored proc(s) missing: $(($spResults | ForEach-Object { $_.ProcName }) -join ', ')"
                Files     = $refFiles
            }
        }
    }
    catch {
        $warnings++
        $details += [PSCustomObject]@{
            CheckName = "StoredProcDeployment"
            Status    = "warn"
            Message   = "Check error: $($_.Exception.Message)"
            Files     = @()
        }
    }

    # --- Summary ---
    return [PSCustomObject]@{
        TotalChecks = $totalChecks
        Passed      = $passed
        Failed      = $failed
        Warnings    = $warnings
        Details     = $details
    }
}
