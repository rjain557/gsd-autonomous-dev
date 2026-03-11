# Detailed test for Kimi and GLM5

# Kimi - test with error body
Write-Host "--- Kimi ---" -ForegroundColor Yellow
$kimiKey = [System.Environment]::GetEnvironmentVariable('KIMI_API_KEY', 'User')
Write-Host "Key: $($kimiKey.Substring(0,15))..."
$headers = @{ Authorization = "Bearer $kimiKey"; 'Content-Type' = 'application/json' }
$body = '{"model":"moonshot-v1-8k","messages":[{"role":"user","content":"hi"}],"max_tokens":5}'
try {
    $r = Invoke-WebRequest -Uri 'https://api.moonshot.cn/v1/chat/completions' -Method Post -Headers $headers -Body $body -TimeoutSec 15
    Write-Host "OK: $($r.Content)"
} catch {
    $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "timeout" }
    $errBody = ""
    if ($_.Exception.Response) {
        try { $sr = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream()); $errBody = $sr.ReadToEnd(); $sr.Close() } catch {}
    }
    Write-Host "FAIL ($status)"
    Write-Host "Body: $errBody"
}

# GLM5 - try different model names and auth format
Write-Host "`n--- GLM5 (try JWT auth) ---" -ForegroundColor Yellow
$glmKey = [System.Environment]::GetEnvironmentVariable('GLM_API_KEY', 'User')
Write-Host "Key: $($glmKey.Substring(0,15))..."

# GLM uses JWT-based auth, not simple bearer. The key format is: {id}.{secret}
# Try simple bearer first
$headers = @{ Authorization = "Bearer $glmKey"; 'Content-Type' = 'application/json' }
# Try glm-4-flash
$body = '{"model":"glm-4-flash","messages":[{"role":"user","content":"hi"}]}'
try {
    $r = Invoke-WebRequest -Uri 'https://open.bigmodel.cn/api/paas/v4/chat/completions' -Method Post -Headers $headers -Body $body -TimeoutSec 15
    Write-Host "glm-4-flash OK: $($r.Content.Substring(0,100))"
} catch {
    $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "timeout" }
    $errBody = ""
    if ($_.Exception.Response) {
        try { $sr = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream()); $errBody = $sr.ReadToEnd(); $sr.Close() } catch {}
    }
    Write-Host "FAIL ($status)"
    Write-Host "Body: $errBody"
}

# MiniMax - get full response
Write-Host "`n--- MiniMax (detail) ---" -ForegroundColor Yellow
$mmKey = [System.Environment]::GetEnvironmentVariable('MINIMAX_API_KEY', 'User')
Write-Host "Key prefix: $($mmKey.Substring(0,15))..."
$headers = @{ Authorization = "Bearer $mmKey"; 'Content-Type' = 'application/json' }
$body = '{"model":"abab6.5s-chat","messages":[{"role":"user","content":"hi"}],"max_tokens":10}'
try {
    $r = Invoke-WebRequest -Uri 'https://api.minimax.chat/v1/text/chatcompletion_v2' -Method Post -Headers $headers -Body $body -TimeoutSec 15
    Write-Host "OK: $($r.Content.Substring(0,200))"
} catch {
    $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "timeout" }
    $errBody = ""
    if ($_.Exception.Response) {
        try { $sr = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream()); $errBody = $sr.ReadToEnd(); $sr.Close() } catch {}
    }
    Write-Host "FAIL ($status)"
    Write-Host "Body: $errBody"
}
