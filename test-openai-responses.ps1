# Test OpenAI Responses API (what the pipeline actually uses)
$key = [System.Environment]::GetEnvironmentVariable('OPENAI_API_KEY', 'User')
$headers = @{ Authorization = "Bearer $key"; 'Content-Type' = 'application/json' }
$body = @{
    model = 'gpt-5.1-codex-mini'
    input = 'Say hi'
    max_output_tokens = 10
} | ConvertTo-Json -Depth 5

try {
    $r = Invoke-RestMethod -Uri 'https://api.openai.com/v1/responses' -Method Post -Headers $headers -Body $body -TimeoutSec 15
    Write-Host "RESPONSES API OK: $($r.output[0].content[0].text)"
} catch {
    $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "timeout" }
    Write-Host "RESPONSES API FAIL ($status): $($_.Exception.Message)"
    # Also try chat completions for comparison
    try {
        $body2 = '{"model":"gpt-5.1-codex-mini","messages":[{"role":"user","content":"hi"}],"max_tokens":5}'
        $r2 = Invoke-RestMethod -Uri 'https://api.openai.com/v1/chat/completions' -Method Post -Headers $headers -Body $body2 -TimeoutSec 15
        Write-Host "CHAT API OK"
    } catch {
        $status2 = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "timeout" }
        Write-Host "CHAT API FAIL ($status2)"
    }
}
