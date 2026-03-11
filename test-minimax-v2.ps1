$mmKey = [System.Environment]::GetEnvironmentVariable('MINIMAX_API_KEY', 'User')
$headers = @{ Authorization = "Bearer $mmKey"; 'Content-Type' = 'application/json' }

# Try different model names on the reachable endpoint
$models = @("abab6.5s-chat", "abab5.5-chat", "MiniMax-Text-01", "minimax-01")

foreach ($model in $models) {
    Write-Host "--- api.minimax.io model=$model ---" -ForegroundColor Yellow
    $body = "{`"model`":`"$model`",`"messages`":[{`"role`":`"user`",`"content`":`"Say hi`"}],`"max_tokens`":10}"
    try {
        $r = Invoke-RestMethod -Uri 'https://api.minimax.io/v1/chat/completions' -Method Post -Headers $headers -Body $body -TimeoutSec 15
        Write-Host "OK: $($r.choices[0].message.content)" -ForegroundColor Green
    } catch {
        $s = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "timeout" }
        $errBody = ""
        if ($_.Exception.Response) {
            try { $sr = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream()); $errBody = $sr.ReadToEnd(); $sr.Close() } catch {}
        }
        Write-Host "FAIL ($s)"
        if ($errBody) { Write-Host "Body: $errBody" }
    }
}

# Also try platform.minimax.io with same models
foreach ($model in $models) {
    Write-Host "`n--- platform.minimax.io model=$model ---" -ForegroundColor Yellow
    $body = "{`"model`":`"$model`",`"messages`":[{`"role`":`"user`",`"content`":`"Say hi`"}],`"max_tokens`":10}"
    try {
        $r = Invoke-RestMethod -Uri 'https://platform.minimax.io/v1/chat/completions' -Method Post -Headers $headers -Body $body -TimeoutSec 15
        Write-Host "OK: $($r.choices[0].message.content)" -ForegroundColor Green
    } catch {
        $s = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "timeout" }
        $errBody = ""
        if ($_.Exception.Response) {
            try { $sr = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream()); $errBody = $sr.ReadToEnd(); $sr.Close() } catch {}
        }
        Write-Host "FAIL ($s)"
        if ($errBody) { Write-Host "Body: $errBody" }
    }
}
