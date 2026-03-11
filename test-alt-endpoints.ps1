# Test alternative endpoints
Write-Host "--- Kimi (platform.moonshot.ai) ---" -ForegroundColor Yellow
$kimiKey = [System.Environment]::GetEnvironmentVariable('KIMI_API_KEY', 'User')
$headers = @{ Authorization = "Bearer $kimiKey"; 'Content-Type' = 'application/json' }
$body = '{"model":"moonshot-v1-8k","messages":[{"role":"user","content":"Say hi"}],"max_tokens":10}'
try {
    $r = Invoke-RestMethod -Uri 'https://platform.moonshot.ai/v1/chat/completions' -Method Post -Headers $headers -Body $body -TimeoutSec 15
    Write-Host "OK: $($r.choices[0].message.content)"
} catch {
    $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "timeout" }
    $errBody = ""
    if ($_.Exception.Response) {
        try { $sr = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream()); $errBody = $sr.ReadToEnd(); $sr.Close() } catch {}
    }
    Write-Host "FAIL ($status): $($_.Exception.Message)"
    if ($errBody) { Write-Host "Body: $errBody" }
}

# Also try api.moonshot.ai
Write-Host "`n--- Kimi (api.moonshot.ai) ---" -ForegroundColor Yellow
try {
    $r2 = Invoke-RestMethod -Uri 'https://api.moonshot.ai/v1/chat/completions' -Method Post -Headers $headers -Body $body -TimeoutSec 15
    Write-Host "OK: $($r2.choices[0].message.content)"
} catch {
    $status2 = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "timeout" }
    $errBody2 = ""
    if ($_.Exception.Response) {
        try { $sr = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream()); $errBody2 = $sr.ReadToEnd(); $sr.Close() } catch {}
    }
    Write-Host "FAIL ($status2)"
    if ($errBody2) { Write-Host "Body: $errBody2" }
}

# MiniMax with new key
Write-Host "`n--- MiniMax (new key) ---" -ForegroundColor Yellow
$mmKey = [System.Environment]::GetEnvironmentVariable('MINIMAX_API_KEY', 'User')
$headers2 = @{ Authorization = "Bearer $mmKey"; 'Content-Type' = 'application/json' }
$body2 = '{"model":"abab6.5s-chat","messages":[{"role":"user","content":"Say hi"}],"max_tokens":10}'
try {
    $r3 = Invoke-RestMethod -Uri 'https://api.minimax.chat/v1/text/chatcompletion_v2' -Method Post -Headers $headers2 -Body $body2 -TimeoutSec 15
    Write-Host "OK: $($r3.choices[0].message.content)"
} catch {
    $status3 = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "timeout" }
    $errBody3 = ""
    if ($_.Exception.Response) {
        try { $sr = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream()); $errBody3 = $sr.ReadToEnd(); $sr.Close() } catch {}
    }
    Write-Host "FAIL ($status3)"
    if ($errBody3) { Write-Host "Body: $errBody3" }
}
