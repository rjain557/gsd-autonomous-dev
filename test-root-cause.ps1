# Root cause analysis for all model API failures
Write-Host "=== ROOT CAUSE ANALYSIS ===" -ForegroundColor Cyan

# 1. OpenAI - Test with detailed error body
Write-Host "`n--- OpenAI Codex Mini ---" -ForegroundColor Yellow
$key = [System.Environment]::GetEnvironmentVariable('OPENAI_API_KEY', 'User')
Write-Host "Key prefix: $($key.Substring(0, [math]::Min(10, $key.Length)))..."

# Test Responses API
$headers = @{ Authorization = "Bearer $key"; 'Content-Type' = 'application/json' }
$body = '{"model":"gpt-5.1-codex-mini","input":"Say hi","max_output_tokens":10}'
try {
    $r = Invoke-WebRequest -Uri 'https://api.openai.com/v1/responses' -Method Post -Headers $headers -Body $body -TimeoutSec 15
    Write-Host "Responses API: OK ($([int]$r.StatusCode))"
} catch {
    $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "timeout" }
    $errBody = ""
    if ($_.Exception.Response) {
        try { $sr = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream()); $errBody = $sr.ReadToEnd(); $sr.Close() } catch {}
    }
    Write-Host "Responses API: FAIL ($status)"
    if ($errBody) { Write-Host "Error body: $errBody" }
}

# Test Chat Completions API
$body2 = '{"model":"gpt-5.1-codex-mini","messages":[{"role":"user","content":"hi"}],"max_tokens":5}'
try {
    $r2 = Invoke-WebRequest -Uri 'https://api.openai.com/v1/chat/completions' -Method Post -Headers $headers -Body $body2 -TimeoutSec 15
    Write-Host "Chat API: OK"
} catch {
    $status2 = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "timeout" }
    $errBody2 = ""
    if ($_.Exception.Response) {
        try { $sr = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream()); $errBody2 = $sr.ReadToEnd(); $sr.Close() } catch {}
    }
    Write-Host "Chat API: FAIL ($status2)"
    if ($errBody2) { Write-Host "Error body: $errBody2" }
}

# Test with a known model (gpt-4o-mini)
$body3 = '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"hi"}],"max_tokens":5}'
try {
    $r3 = Invoke-WebRequest -Uri 'https://api.openai.com/v1/chat/completions' -Method Post -Headers $headers -Body $body3 -TimeoutSec 15
    Write-Host "GPT-4o-mini: OK (key works, model-specific issue)"
} catch {
    $status3 = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "timeout" }
    Write-Host "GPT-4o-mini: FAIL ($status3) (key may be invalid)"
}

# 2. Kimi - detailed error
Write-Host "`n--- Kimi (Moonshot) ---" -ForegroundColor Yellow
$kimiKey = [System.Environment]::GetEnvironmentVariable('KIMI_API_KEY', 'User')
Write-Host "Key prefix: $($kimiKey.Substring(0, [math]::Min(10, $kimiKey.Length)))..."
$headers = @{ Authorization = "Bearer $kimiKey"; 'Content-Type' = 'application/json' }
$body = '{"model":"moonshot-v1-8k","messages":[{"role":"user","content":"hi"}],"max_tokens":5}'
try {
    $r = Invoke-WebRequest -Uri 'https://api.moonshot.cn/v1/chat/completions' -Method Post -Headers $headers -Body $body -TimeoutSec 20
    Write-Host "OK"
} catch {
    $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "timeout/network" }
    Write-Host "FAIL ($status): $($_.Exception.Message)"
}

# 3. GLM5 - detailed error
Write-Host "`n--- GLM5 (Zhipu/BigModel) ---" -ForegroundColor Yellow
$glmKey = [System.Environment]::GetEnvironmentVariable('GLM_API_KEY', 'User')
Write-Host "Key prefix: $($glmKey.Substring(0, [math]::Min(10, $glmKey.Length)))..."
$headers = @{ Authorization = "Bearer $glmKey"; 'Content-Type' = 'application/json' }
$body = '{"model":"glm-4-flash","messages":[{"role":"user","content":"hi"}],"max_tokens":5}'
try {
    $r = Invoke-WebRequest -Uri 'https://open.bigmodel.cn/api/paas/v4/chat/completions' -Method Post -Headers $headers -Body $body -TimeoutSec 20
    Write-Host "OK"
} catch {
    $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "timeout/network" }
    Write-Host "FAIL ($status): $($_.Exception.Message)"
}

# 4. MiniMax - detailed error
Write-Host "`n--- MiniMax ---" -ForegroundColor Yellow
$mmKey = [System.Environment]::GetEnvironmentVariable('MINIMAX_API_KEY', 'User')
Write-Host "Key prefix: $($mmKey.Substring(0, [math]::Min(10, $mmKey.Length)))..."
$headers = @{ Authorization = "Bearer $mmKey"; 'Content-Type' = 'application/json' }
$body = '{"model":"abab6.5s-chat","messages":[{"role":"user","content":"hi"}],"max_tokens":5}'
try {
    $r = Invoke-WebRequest -Uri 'https://api.minimax.chat/v1/text/chatcompletion_v2' -Method Post -Headers $headers -Body $body -TimeoutSec 20
    Write-Host "OK"
} catch {
    $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "timeout/network" }
    Write-Host "FAIL ($status): $($_.Exception.Message)"
}

# 5. DeepSeek (confirmed working)
Write-Host "`n--- DeepSeek (CONTROL) ---" -ForegroundColor Yellow
$dsKey = [System.Environment]::GetEnvironmentVariable('DEEPSEEK_API_KEY', 'User')
$headers = @{ Authorization = "Bearer $dsKey"; 'Content-Type' = 'application/json' }
$body = '{"model":"deepseek-chat","messages":[{"role":"user","content":"hi"}],"max_tokens":5}'
try {
    $r = Invoke-RestMethod -Uri 'https://api.deepseek.com/v1/chat/completions' -Method Post -Headers $headers -Body $body -TimeoutSec 15
    Write-Host "OK: $($r.choices[0].message.content)"
} catch {
    Write-Host "FAIL: $($_.Exception.Message)"
}
