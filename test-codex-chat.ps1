# Test Codex models via Chat Completions (NOT Responses API)
$ok = [System.Environment]::GetEnvironmentVariable('OPENAI_API_KEY', 'User')
$headers = @{ Authorization = "Bearer $ok"; 'Content-Type' = 'application/json' }

$models = @("gpt-5.1-codex-mini", "gpt-5.4", "gpt-5-mini", "o4-mini")

foreach ($model in $models) {
    Write-Host "--- $model (Chat Completions) ---" -ForegroundColor Yellow
    $body = "{`"model`":`"$model`",`"messages`":[{`"role`":`"system`",`"content`":`"You are a coder`"},{`"role`":`"user`",`"content`":`"Say hi`"}],`"max_tokens`":10}"
    try {
        $r = Invoke-RestMethod -Uri 'https://api.openai.com/v1/chat/completions' -Method Post -Headers $headers -Body $body -TimeoutSec 15
        Write-Host "  OK: $($r.choices[0].message.content)" -ForegroundColor Green
    } catch {
        $s = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "timeout" }
        $eb = ""; if ($_.Exception.Response) { try { $sr = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream()); $eb = $sr.ReadToEnd(); $sr.Close() } catch {} }
        Write-Host "  FAIL ($s)" -ForegroundColor Red
        if ($eb) { Write-Host "  $eb" }
    }
}
