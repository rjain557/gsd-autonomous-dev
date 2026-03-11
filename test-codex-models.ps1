# Test different OpenAI Codex model IDs
$ok = [System.Environment]::GetEnvironmentVariable('OPENAI_API_KEY', 'User')
$headers = @{ Authorization = "Bearer $ok"; 'Content-Type' = 'application/json' }

$models = @("gpt-5.1-codex-mini", "codex-mini-latest", "o4-mini", "gpt-4.1-mini")

foreach ($model in $models) {
    Write-Host "--- $model (Responses API) ---" -ForegroundColor Yellow
    $body = "{`"model`":`"$model`",`"input`":`"Say hi`",`"max_output_tokens`":10}"
    try {
        $r = Invoke-RestMethod -Uri 'https://api.openai.com/v1/responses' -Method Post -Headers $headers -Body $body -TimeoutSec 15
        Write-Host "  OK: $($r.output_text)" -ForegroundColor Green
    } catch {
        $s = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "timeout" }
        $eb = ""
        if ($_.Exception.Response) { try { $sr = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream()); $eb = $sr.ReadToEnd(); $sr.Close() } catch {} }
        Write-Host "  FAIL ($s)" -ForegroundColor Red
        if ($eb) { Write-Host "  $eb" }
    }
}

# Also try chat completions for gpt-4.1-mini
Write-Host "`n--- gpt-4.1-mini (Chat Completions) ---" -ForegroundColor Yellow
$body2 = '{"model":"gpt-4.1-mini","messages":[{"role":"user","content":"Say hi"}],"max_tokens":10}'
try {
    $r2 = Invoke-RestMethod -Uri 'https://api.openai.com/v1/chat/completions' -Method Post -Headers $headers -Body $body2 -TimeoutSec 15
    Write-Host "  OK: $($r2.choices[0].message.content)" -ForegroundColor Green
} catch {
    $s2 = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "timeout" }
    Write-Host "  FAIL ($s2)" -ForegroundColor Red
}
