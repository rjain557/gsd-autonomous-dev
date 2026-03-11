$ok = [System.Environment]::GetEnvironmentVariable('OPENAI_API_KEY', 'User')
$headers = @{ Authorization = "Bearer $ok" }
$body = '{"model":"gpt-5.1-codex-mini","input":[{"role":"user","content":"Say hi"}],"max_output_tokens":50}'

Write-Host "Testing Invoke-RestMethod..."
try {
    $r = Invoke-RestMethod -Uri 'https://api.openai.com/v1/responses' -Method Post -Headers $headers -Body $body -TimeoutSec 15 -ContentType 'application/json'
    Write-Host "OK: $($r.output_text)" -ForegroundColor Green
    Write-Host "Status: $($r.status)"
} catch {
    $s = "unknown"
    if ($_.Exception.Response) { $s = [int]$_.Exception.Response.StatusCode }
    Write-Host "FAIL: Status=$s" -ForegroundColor Red
    Write-Host "Message: $($_.Exception.Message)"
}
