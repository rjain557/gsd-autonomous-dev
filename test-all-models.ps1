# Test ALL 7 models (updated 2026-03-10)
$ErrorActionPreference = "Continue"

# 1. Anthropic Sonnet
Write-Host "1. Anthropic Sonnet" -ForegroundColor Yellow
$ak = [System.Environment]::GetEnvironmentVariable('ANTHROPIC_API_KEY', 'User')
$h = @{ 'x-api-key' = $ak; 'Content-Type' = 'application/json'; 'anthropic-version' = '2023-06-01' }
$b = '{"model":"claude-sonnet-4-20250514","messages":[{"role":"user","content":"Say hi in 3 words"}],"max_tokens":20}'
try {
    $r = Invoke-RestMethod -Uri 'https://api.anthropic.com/v1/messages' -Method Post -Headers $h -Body $b -TimeoutSec 15
    Write-Host "   OK: $($r.content[0].text)" -ForegroundColor Green
} catch {
    $s = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "timeout" }
    Write-Host "   FAIL ($s)" -ForegroundColor Red
}

# 2. OpenAI Codex Mini (Responses API)
Write-Host "2. OpenAI Codex Mini" -ForegroundColor Yellow
$ok = [System.Environment]::GetEnvironmentVariable('OPENAI_API_KEY', 'User')
$h2 = @{ Authorization = "Bearer $ok"; 'Content-Type' = 'application/json' }
$b2 = '{"model":"codex-mini-latest","input":"Say hi in 3 words","max_output_tokens":20}'
try {
    $r2 = Invoke-RestMethod -Uri 'https://api.openai.com/v1/responses' -Method Post -Headers $h2 -Body $b2 -TimeoutSec 15
    Write-Host "   OK: $($r2.output_text)" -ForegroundColor Green
} catch {
    $s2 = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "timeout" }
    $eb = ""; if ($_.Exception.Response) { try { $sr = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream()); $eb = $sr.ReadToEnd(); $sr.Close() } catch {} }
    Write-Host "   FAIL ($s2)" -ForegroundColor Red
    if ($eb) { Write-Host "   $eb" }
}

# 3. DeepSeek
Write-Host "3. DeepSeek" -ForegroundColor Yellow
$dk = [System.Environment]::GetEnvironmentVariable('DEEPSEEK_API_KEY', 'User')
$h3 = @{ Authorization = "Bearer $dk"; 'Content-Type' = 'application/json' }
$b3 = '{"model":"deepseek-chat","messages":[{"role":"user","content":"Say hi in 3 words"}],"max_tokens":20}'
try {
    $r3 = Invoke-RestMethod -Uri 'https://api.deepseek.com/v1/chat/completions' -Method Post -Headers $h3 -Body $b3 -TimeoutSec 15
    Write-Host "   OK: $($r3.choices[0].message.content)" -ForegroundColor Green
} catch {
    $s3 = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "timeout" }
    Write-Host "   FAIL ($s3)" -ForegroundColor Red
}

# 4. Kimi (api.moonshot.ai)
Write-Host "4. Kimi" -ForegroundColor Yellow
$kk = [System.Environment]::GetEnvironmentVariable('KIMI_API_KEY', 'User')
$h4 = @{ Authorization = "Bearer $kk"; 'Content-Type' = 'application/json' }
$b4 = '{"model":"moonshot-v1-8k","messages":[{"role":"user","content":"Say hi in 3 words"}],"max_tokens":20}'
try {
    $r4 = Invoke-RestMethod -Uri 'https://api.moonshot.ai/v1/chat/completions' -Method Post -Headers $h4 -Body $b4 -TimeoutSec 15
    Write-Host "   OK: $($r4.choices[0].message.content)" -ForegroundColor Green
} catch {
    $s4 = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "timeout" }
    $eb4 = ""; if ($_.Exception.Response) { try { $sr = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream()); $eb4 = $sr.ReadToEnd(); $sr.Close() } catch {} }
    Write-Host "   FAIL ($s4)" -ForegroundColor Red
    if ($eb4) { Write-Host "   $eb4" }
}

# 5. MiniMax (api.minimax.io - MiniMax-Text-01)
Write-Host "5. MiniMax" -ForegroundColor Yellow
$mk = [System.Environment]::GetEnvironmentVariable('MINIMAX_API_KEY', 'User')
$h5 = @{ Authorization = "Bearer $mk"; 'Content-Type' = 'application/json' }
$b5 = '{"model":"MiniMax-Text-01","messages":[{"role":"user","content":"Say hi in 3 words"}],"max_tokens":20}'
try {
    $r5 = Invoke-RestMethod -Uri 'https://api.minimax.io/v1/chat/completions' -Method Post -Headers $h5 -Body $b5 -TimeoutSec 15
    Write-Host "   OK: $($r5.choices[0].message.content)" -ForegroundColor Green
} catch {
    $s5 = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "timeout" }
    Write-Host "   FAIL ($s5)" -ForegroundColor Red
}

# 6. GLM5 (open.bigmodel.cn)
Write-Host "6. GLM5" -ForegroundColor Yellow
$gk = [System.Environment]::GetEnvironmentVariable('GLM_API_KEY', 'User')
$h6 = @{ Authorization = "Bearer $gk"; 'Content-Type' = 'application/json' }
$b6 = '{"model":"glm-4-flash","messages":[{"role":"user","content":"Say hi in 3 words"}]}'
try {
    $r6 = Invoke-RestMethod -Uri 'https://open.bigmodel.cn/api/paas/v4/chat/completions' -Method Post -Headers $h6 -Body $b6 -TimeoutSec 15
    Write-Host "   OK: $($r6.choices[0].message.content)" -ForegroundColor Green
} catch {
    $s6 = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "timeout" }
    $eb6 = ""; if ($_.Exception.Response) { try { $sr = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream()); $eb6 = $sr.ReadToEnd(); $sr.Close() } catch {} }
    Write-Host "   FAIL ($s6)" -ForegroundColor Red
    if ($eb6) { Write-Host "   $eb6" }
}

Write-Host "`n=== DONE ===" -ForegroundColor Cyan
