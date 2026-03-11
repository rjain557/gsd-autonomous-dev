# Debug Responses API - use WebRequest to see full error body
$ok = [System.Environment]::GetEnvironmentVariable('OPENAI_API_KEY', 'User')

Write-Host "--- Responses API debug (codex-mini-latest) ---" -ForegroundColor Yellow
$body = '{"model":"codex-mini-latest","input":"Say hi","max_output_tokens":10}'
try {
    $r = Invoke-WebRequest -Uri 'https://api.openai.com/v1/responses' -Method Post `
        -Headers @{ Authorization = "Bearer $ok" } `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) `
        -ContentType 'application/json' -TimeoutSec 15 -UseBasicParsing
    Write-Host "  Status: $($r.StatusCode)" -ForegroundColor Green
    Write-Host "  Body: $($r.Content)"
} catch {
    if ($_.Exception.Response) {
        $sr = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream())
        $errBody = $sr.ReadToEnd()
        $sr.Close()
        Write-Host "  Status: $([int]$_.Exception.Response.StatusCode)" -ForegroundColor Red
        Write-Host "  Body: $errBody"
    } else {
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host "`n--- Chat Completions debug (gpt-5.1-codex-mini) ---" -ForegroundColor Yellow
$body2 = '{"model":"gpt-5.1-codex-mini","messages":[{"role":"user","content":"hi"}],"max_tokens":10}'
try {
    $r2 = Invoke-WebRequest -Uri 'https://api.openai.com/v1/chat/completions' -Method Post `
        -Headers @{ Authorization = "Bearer $ok" } `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($body2)) `
        -ContentType 'application/json' -TimeoutSec 15 -UseBasicParsing
    Write-Host "  Status: $($r2.StatusCode)" -ForegroundColor Green
    Write-Host "  Body: $($r2.Content)"
} catch {
    if ($_.Exception.Response) {
        $sr = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream())
        $errBody = $sr.ReadToEnd()
        $sr.Close()
        Write-Host "  Status: $([int]$_.Exception.Response.StatusCode)" -ForegroundColor Red
        Write-Host "  Body: $errBody"
    } else {
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}
