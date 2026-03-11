# Compare Invoke-RestMethod body encoding
$ok = [System.Environment]::GetEnvironmentVariable('OPENAI_API_KEY', 'User')

# Build the EXACT same body the pipeline builds
$bodyObj = @{
    model = "gpt-5.1-codex-mini"
    input = @(
        @{ role = "user"; content = "Write hello world in C#" }
    )
    max_output_tokens = 500
    instructions = "Code only"
}
$body = $bodyObj | ConvertTo-Json -Depth 10 -Compress
Write-Host "Body length: $($body.Length)"
Write-Host "Body: $body"

# Test 1: Invoke-RestMethod with Content-Type in headers AND as param (like pipeline)
Write-Host "`n--- Test 1: Content-Type in headers + -ContentType param ---" -ForegroundColor Yellow
$headers = @{
    "Authorization" = "Bearer $ok"
    "Content-Type"  = "application/json"
}
try {
    $r = Invoke-RestMethod -Uri 'https://api.openai.com/v1/responses' -Method Post -Headers $headers -Body $body -TimeoutSec 30 -ContentType "application/json"
    Write-Host "  OK: status=$($r.status)" -ForegroundColor Green
} catch {
    $s = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "none" }
    Write-Host "  FAIL: $s" -ForegroundColor Red
}

# Test 2: Invoke-RestMethod with ONLY -ContentType param (no Content-Type in headers)
Write-Host "`n--- Test 2: Only -ContentType param (no header) ---" -ForegroundColor Yellow
$headers2 = @{
    "Authorization" = "Bearer $ok"
}
try {
    $r2 = Invoke-RestMethod -Uri 'https://api.openai.com/v1/responses' -Method Post -Headers $headers2 -Body $body -TimeoutSec 30 -ContentType "application/json"
    Write-Host "  OK: status=$($r2.status)" -ForegroundColor Green
} catch {
    $s2 = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "none" }
    Write-Host "  FAIL: $s2" -ForegroundColor Red
}

# Test 3: With UTF-8 byte array body
Write-Host "`n--- Test 3: UTF-8 byte array body ---" -ForegroundColor Yellow
$bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
try {
    $r3 = Invoke-RestMethod -Uri 'https://api.openai.com/v1/responses' -Method Post -Headers $headers2 -Body $bodyBytes -TimeoutSec 30 -ContentType "application/json; charset=utf-8"
    Write-Host "  OK: status=$($r3.status)" -ForegroundColor Green
} catch {
    $s3 = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "none" }
    Write-Host "  FAIL: $s3" -ForegroundColor Red
}
