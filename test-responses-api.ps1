# Test Responses API with different input formats
$ok = [System.Environment]::GetEnvironmentVariable('OPENAI_API_KEY', 'User')
$headers = @{ Authorization = "Bearer $ok"; 'Content-Type' = 'application/json' }

# Format 1: input as array of messages (like the api-client.ps1 does)
Write-Host "--- codex-mini-latest: input as message array ---" -ForegroundColor Yellow
$body1 = '{"model":"codex-mini-latest","input":[{"role":"user","content":"Say hi"}],"max_output_tokens":10}'
try {
    $r = Invoke-RestMethod -Uri 'https://api.openai.com/v1/responses' -Method Post -Headers $headers -Body $body1 -TimeoutSec 15
    Write-Host "  OK: $($r.output_text)" -ForegroundColor Green
} catch {
    $s = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "timeout" }
    $eb = ""; if ($_.Exception.Response) { try { $sr = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream()); $eb = $sr.ReadToEnd(); $sr.Close() } catch {} }
    Write-Host "  FAIL ($s)" -ForegroundColor Red
    if ($eb) { Write-Host "  Body: $eb" }
}

# Format 2: input as plain string
Write-Host "`n--- codex-mini-latest: input as string ---" -ForegroundColor Yellow
$body2 = '{"model":"codex-mini-latest","input":"Say hi","max_output_tokens":10}'
try {
    $r = Invoke-RestMethod -Uri 'https://api.openai.com/v1/responses' -Method Post -Headers $headers -Body $body2 -TimeoutSec 15
    Write-Host "  OK: $($r.output_text)" -ForegroundColor Green
} catch {
    $s = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "timeout" }
    $eb = ""; if ($_.Exception.Response) { try { $sr = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream()); $eb = $sr.ReadToEnd(); $sr.Close() } catch {} }
    Write-Host "  FAIL ($s)" -ForegroundColor Red
    if ($eb) { Write-Host "  Body: $eb" }
}

# Format 3: try gpt-4.1-mini on Responses API
Write-Host "`n--- gpt-4.1-mini: Responses API ---" -ForegroundColor Yellow
$body3 = '{"model":"gpt-4.1-mini","input":[{"role":"user","content":"Say hi"}],"max_output_tokens":10}'
try {
    $r = Invoke-RestMethod -Uri 'https://api.openai.com/v1/responses' -Method Post -Headers $headers -Body $body3 -TimeoutSec 15
    Write-Host "  OK: $($r.output_text)" -ForegroundColor Green
} catch {
    $s = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "timeout" }
    $eb = ""; if ($_.Exception.Response) { try { $sr = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream()); $eb = $sr.ReadToEnd(); $sr.Close() } catch {} }
    Write-Host "  FAIL ($s)" -ForegroundColor Red
    if ($eb) { Write-Host "  Body: $eb" }
}

# List available models (first 10)
Write-Host "`n--- Available OpenAI Models (codex/gpt related) ---" -ForegroundColor Yellow
try {
    $models = Invoke-RestMethod -Uri 'https://api.openai.com/v1/models' -Method Get -Headers $headers -TimeoutSec 15
    $relevant = $models.data | Where-Object { $_.id -match 'codex|gpt-4|gpt-5|o4' } | Sort-Object id | Select-Object -ExpandProperty id
    $relevant | ForEach-Object { Write-Host "  $_" }
} catch {
    Write-Host "  FAIL: $($_.Exception.Message)" -ForegroundColor Red
}
