Add-Type -AssemblyName System.Net.Http
$ok = [System.Environment]::GetEnvironmentVariable('OPENAI_API_KEY', 'User')

$client = New-Object System.Net.Http.HttpClient
$client.DefaultRequestHeaders.Add("Authorization", "Bearer $ok")
$client.Timeout = [TimeSpan]::FromSeconds(30)

Write-Host "--- Codex Mini (Responses API, min 16 tokens) ---" -ForegroundColor Yellow
$body = '{"model":"codex-mini-latest","input":"Say hi in 3 words","max_output_tokens":50}'
$content = New-Object System.Net.Http.StringContent($body, [System.Text.Encoding]::UTF8, 'application/json')
try {
    $response = $client.PostAsync('https://api.openai.com/v1/responses', $content).Result
    $responseBody = $response.Content.ReadAsStringAsync().Result
    Write-Host "  Status: $($response.StatusCode) ($([int]$response.StatusCode))"
    $json = $responseBody | ConvertFrom-Json
    Write-Host "  Output: $($json.output_text)" -ForegroundColor Green
} catch {
    Write-Host "  Error: $($_.Exception.InnerException.Message)" -ForegroundColor Red
}

Write-Host "`n--- gpt-5.1-codex-mini (same test) ---" -ForegroundColor Yellow
$body2 = '{"model":"gpt-5.1-codex-mini","input":"Say hi in 3 words","max_output_tokens":50}'
$content2 = New-Object System.Net.Http.StringContent($body2, [System.Text.Encoding]::UTF8, 'application/json')
try {
    $response2 = $client.PostAsync('https://api.openai.com/v1/responses', $content2).Result
    $responseBody2 = $response2.Content.ReadAsStringAsync().Result
    Write-Host "  Status: $($response2.StatusCode) ($([int]$response2.StatusCode))"
    $json2 = $responseBody2 | ConvertFrom-Json
    Write-Host "  Output: $($json2.output_text)" -ForegroundColor Green
} catch {
    Write-Host "  Error: $($_.Exception.InnerException.Message)" -ForegroundColor Red
}

$client.Dispose()
