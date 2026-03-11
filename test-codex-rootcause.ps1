# Root cause Codex Mini 429 -test every difference between standalone and pipeline
Write-Host "=== CODEX MINI 429 ROOT CAUSE ANALYSIS ===" -ForegroundColor Cyan

# Step 1: Check ALL possible API key sources (pipeline searches Process -> User -> Machine)
Write-Host "`n--- Step 1: API Key Sources ---" -ForegroundColor Yellow
$keyProcess = [System.Environment]::GetEnvironmentVariable('OPENAI_API_KEY', 'Process')
$keyUser = [System.Environment]::GetEnvironmentVariable('OPENAI_API_KEY', 'User')
$keyMachine = [System.Environment]::GetEnvironmentVariable('OPENAI_API_KEY', 'Machine')
Write-Host "  Process: $(if ($keyProcess) { $keyProcess.Substring(0,10) + '...' + $keyProcess.Substring($keyProcess.Length-4) } else { 'NOT SET' })"
Write-Host "  User:    $(if ($keyUser) { $keyUser.Substring(0,10) + '...' + $keyUser.Substring($keyUser.Length-4) } else { 'NOT SET' })"
Write-Host "  Machine: $(if ($keyMachine) { $keyMachine.Substring(0,10) + '...' + $keyMachine.Substring($keyMachine.Length-4) } else { 'NOT SET' })"

# Pipeline uses: Process first, then User, then Machine
$pipelineKey = if ($keyProcess) { $keyProcess } elseif ($keyUser) { $keyUser } else { $keyMachine }
Write-Host "  Pipeline would use: $(if ($pipelineKey) { $pipelineKey.Substring(0,10) + '...' } else { 'NONE' })"

if (-not $pipelineKey) { Write-Host "  FATAL: No API key found!"; exit 1 }

# Step 2: Test with exact pipeline headers (Content-Type in BOTH header dict AND -ContentType param)
Write-Host "`n--- Step 2: Pipeline-style headers (Content-Type in both) ---" -ForegroundColor Yellow
$headers = @{
    "Authorization" = "Bearer $pipelineKey"
    "Content-Type"  = "application/json"
}
$body = '{"model":"gpt-5.1-codex-mini","input":[{"role":"user","content":"Say hi"}],"max_output_tokens":50}'
try {
    $r = Invoke-RestMethod -Uri 'https://api.openai.com/v1/responses' -Method Post -Headers $headers -Body $body -TimeoutSec 15 -ContentType "application/json"
    Write-Host "  OK: status=$($r.status)" -ForegroundColor Green
} catch {
    $s = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "none" }
    $errDetail = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
    Write-Host "  FAIL: $s -$errDetail" -ForegroundColor Red
}

Start-Sleep -Seconds 2

# Step 3: Test with ConvertTo-Json (exactly how pipeline builds body)
Write-Host "`n--- Step 3: ConvertTo-Json body (pipeline-style) ---" -ForegroundColor Yellow
$bodyObj = @{
    model             = "gpt-5.1-codex-mini"
    input             = @(
        @{ role = "user"; content = "Write a hello world function in C#" }
    )
    max_output_tokens = 16384
    instructions      = "Generate production-quality C# code following conventions."
}
$bodyJson = $bodyObj | ConvertTo-Json -Depth 10 -Compress
Write-Host "  Body length: $($bodyJson.Length) chars"
try {
    $r2 = Invoke-RestMethod -Uri 'https://api.openai.com/v1/responses' -Method Post -Headers $headers -Body $bodyJson -TimeoutSec 30 -ContentType "application/json"
    Write-Host "  OK: status=$($r2.status), tokens=$($r2.usage.output_tokens)" -ForegroundColor Green
} catch {
    $s2 = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "none" }
    $errDetail2 = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
    Write-Host "  FAIL: $s2 -$errDetail2" -ForegroundColor Red
}

Start-Sleep -Seconds 2

# Step 4: Test with LARGE payload (mimicking actual pipeline execute payload)
Write-Host "`n--- Step 4: Large payload (pipeline-sized) ---" -ForegroundColor Yellow
$systemPrompt = "You are a code generator for a .NET 8 + React 18 application. Follow these conventions:`n" + ("- Use Dapper for data access`n" * 50) + ("- Use stored procedures`n" * 50)
$userMessage = "Generate a complete C# service implementing the following plan:`n" + (@{
    req_id = "CL-003"
    description = "JWT token service with refresh token rotation and blacklist support"
    files_to_create = @(
        @{ path = "backend/Auth/IJwtTokenService.cs"; purpose = "Interface" }
        @{ path = "backend/Auth/JwtTokenService.cs"; purpose = "Implementation" }
    )
    acceptance_tests = @("Token generation works", "Refresh rotation works", "Blacklisted tokens rejected")
} | ConvertTo-Json -Depth 5)

$bodyObj3 = @{
    model             = "gpt-5.1-codex-mini"
    input             = @(
        @{ role = "user"; content = $userMessage }
    )
    max_output_tokens = 16384
    instructions      = $systemPrompt
}
$bodyJson3 = $bodyObj3 | ConvertTo-Json -Depth 10 -Compress
Write-Host "  Body length: $($bodyJson3.Length) chars (~$([math]::Round($bodyJson3.Length / 4)) tokens)"
try {
    $r3 = Invoke-RestMethod -Uri 'https://api.openai.com/v1/responses' -Method Post -Headers $headers -Body $bodyJson3 -TimeoutSec 60 -ContentType "application/json"
    Write-Host "  OK: status=$($r3.status), tokens=$($r3.usage.output_tokens)" -ForegroundColor Green
} catch {
    $s3 = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "none" }
    $errDetail3 = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
    Write-Host "  FAIL: $s3 -$errDetail3" -ForegroundColor Red
}

Start-Sleep -Seconds 2

# Step 5: Rapid-fire test (5 calls back-to-back to trigger rate limit)
Write-Host "`n--- Step 5: Rapid-fire test, 5 calls no delay ---" -ForegroundColor Yellow
$body5 = '{"model":"gpt-5.1-codex-mini","input":[{"role":"user","content":"x"}],"max_output_tokens":16}'
for ($i = 1; $i -le 5; $i++) {
    try {
        $r5 = Invoke-RestMethod -Uri 'https://api.openai.com/v1/responses' -Method Post -Headers $headers -Body $body5 -TimeoutSec 15 -ContentType "application/json"
        Write-Host "  Call $i : OK (tokens=$($r5.usage.output_tokens))" -ForegroundColor Green
    } catch {
        $s5 = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "none" }
        $errDetail5 = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        Write-Host "  Call $i : FAIL $s5 -$errDetail5" -ForegroundColor Red
    }
}

# Step 6: Check rate limit headers from last successful call
Write-Host "`n--- Step 6: Rate limit headers check ---" -ForegroundColor Yellow
try {
    $resp = Invoke-WebRequest -Uri 'https://api.openai.com/v1/responses' -Method Post -Headers $headers -Body $body -TimeoutSec 15 -ContentType "application/json"
    Write-Host "  Status: $($resp.StatusCode)" -ForegroundColor Green
    $resp.Headers.Keys | Where-Object { $_ -match 'rate|limit|remaining|reset|retry' } | ForEach-Object {
        Write-Host "  $_ : $($resp.Headers[$_])"
    }
} catch {
    $s6 = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "none" }
    Write-Host "  Status: $s6" -ForegroundColor Red
    if ($_.Exception.Response -and $_.Exception.Response.Headers) {
        $_.Exception.Response.Headers | ForEach-Object {
            if ($_.Key -match 'rate|limit|remaining|reset|retry') {
                Write-Host "  $($_.Key) : $($_.Value)"
            }
        }
    }
    $errDetail6 = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
    Write-Host "  Body: $errDetail6" -ForegroundColor DarkGray
}

Write-Host "`n=== ANALYSIS COMPLETE ===" -ForegroundColor Cyan
