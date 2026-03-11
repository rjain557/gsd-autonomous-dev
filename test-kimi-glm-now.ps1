# Test Kimi with new key
Write-Host "--- Kimi (new key) ---" -ForegroundColor Yellow
$kimiKey = [System.Environment]::GetEnvironmentVariable('KIMI_API_KEY', 'User')
Write-Host "Key: $($kimiKey.Substring(0,15))..."
$headers = @{ Authorization = "Bearer $kimiKey"; 'Content-Type' = 'application/json' }
$body = '{"model":"moonshot-v1-8k","messages":[{"role":"user","content":"Say hi in 3 words"}],"max_tokens":10}'
try {
    $r = Invoke-RestMethod -Uri 'https://api.moonshot.cn/v1/chat/completions' -Method Post -Headers $headers -Body $body -TimeoutSec 20
    Write-Host "KIMI OK: $($r.choices[0].message.content)"
} catch {
    $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "timeout" }
    $errBody = ""
    if ($_.Exception.Response) {
        try { $sr = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream()); $errBody = $sr.ReadToEnd(); $sr.Close() } catch {}
    }
    Write-Host "KIMI FAIL ($status): $($_.Exception.Message)"
    if ($errBody) { Write-Host "Body: $errBody" }
}

# Test GLM5 via platform.bigmodel.cn instead of open.bigmodel.cn
Write-Host "`n--- GLM5 (platform.bigmodel.cn) ---" -ForegroundColor Yellow
$glmKey = [System.Environment]::GetEnvironmentVariable('GLM_API_KEY', 'User')
Write-Host "Key: $($glmKey.Substring(0,15))..."
$headers = @{ Authorization = "Bearer $glmKey"; 'Content-Type' = 'application/json' }
$body = '{"model":"glm-4-flash","messages":[{"role":"user","content":"Say hi in 3 words"}]}'
try {
    $r = Invoke-RestMethod -Uri 'https://platform.bigmodel.cn/api/paas/v4/chat/completions' -Method Post -Headers $headers -Body $body -TimeoutSec 20
    Write-Host "GLM5 (platform) OK: $($r.choices[0].message.content)"
} catch {
    $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "timeout" }
    $errBody = ""
    if ($_.Exception.Response) {
        try { $sr = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream()); $errBody = $sr.ReadToEnd(); $sr.Close() } catch {}
    }
    Write-Host "GLM5 (platform) FAIL ($status): $($_.Exception.Message)"
    if ($errBody) { Write-Host "Body: $errBody" }
}

# Also try open.bigmodel.cn for comparison
Write-Host "`n--- GLM5 (open.bigmodel.cn) ---" -ForegroundColor Yellow
try {
    $r2 = Invoke-RestMethod -Uri 'https://open.bigmodel.cn/api/paas/v4/chat/completions' -Method Post -Headers $headers -Body $body -TimeoutSec 20
    Write-Host "GLM5 (open) OK: $($r2.choices[0].message.content)"
} catch {
    $status2 = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "timeout" }
    Write-Host "GLM5 (open) FAIL ($status2)"
}
