$key = [System.Environment]::GetEnvironmentVariable('DEEPSEEK_API_KEY','User')
if (-not $key) { Write-Host "NO DEEPSEEK KEY"; exit 1 }
Write-Host "Key found (length: $($key.Length))"
$headers = @{ Authorization = "Bearer $key"; 'Content-Type' = 'application/json' }
$body = '{"model":"deepseek-chat","messages":[{"role":"user","content":"Say hi"}],"max_tokens":10}'
try {
    $r = Invoke-RestMethod -Uri 'https://api.deepseek.com/v1/chat/completions' -Method Post -Headers $headers -Body $body -TimeoutSec 15
    Write-Host "DEEPSEEK OK: $($r.choices[0].message.content)"
} catch {
    Write-Host "DEEPSEEK ERROR: $($_.Exception.Message)"
}

# Also test Kimi
$kimiKey = [System.Environment]::GetEnvironmentVariable('KIMI_API_KEY','User')
if ($kimiKey) {
    $headers2 = @{ Authorization = "Bearer $kimiKey"; 'Content-Type' = 'application/json' }
    $body2 = '{"model":"moonshot-v1-8k","messages":[{"role":"user","content":"Say hi"}],"max_tokens":10}'
    try {
        $r2 = Invoke-RestMethod -Uri 'https://api.moonshot.cn/v1/chat/completions' -Method Post -Headers $headers2 -Body $body2 -TimeoutSec 15
        Write-Host "KIMI OK: $($r2.choices[0].message.content)"
    } catch {
        Write-Host "KIMI ERROR: $($_.Exception.Message)"
    }
} else { Write-Host "NO KIMI KEY" }
