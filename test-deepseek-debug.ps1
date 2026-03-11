Add-Type -AssemblyName System.Net.Http
$dk = [System.Environment]::GetEnvironmentVariable('DEEPSEEK_API_KEY', 'User')

$client = New-Object System.Net.Http.HttpClient
$client.DefaultRequestHeaders.Add("Authorization", "Bearer $dk")
$client.Timeout = [TimeSpan]::FromSeconds(15)

# Test with large max_tokens (pipeline sends 16384)
Write-Host "--- DeepSeek with max_tokens=16384 ---" -ForegroundColor Yellow
$body = '{"model":"deepseek-chat","messages":[{"role":"system","content":"You are a coder"},{"role":"user","content":"Write a hello world function in C#"}],"max_tokens":16384}'
$content = New-Object System.Net.Http.StringContent($body, [System.Text.Encoding]::UTF8, 'application/json')
try {
    $response = $client.PostAsync('https://api.deepseek.com/v1/chat/completions', $content).Result
    $responseBody = $response.Content.ReadAsStringAsync().Result
    Write-Host "  Status: $($response.StatusCode) ($([int]$response.StatusCode))"
    if ($response.IsSuccessStatusCode) {
        $json = $responseBody | ConvertFrom-Json
        Write-Host "  OK: $($json.choices[0].message.content.Substring(0, [Math]::Min(100, $json.choices[0].message.content.Length)))" -ForegroundColor Green
    } else {
        Write-Host "  Body: $responseBody" -ForegroundColor Red
    }
} catch {
    Write-Host "  Error: $($_.Exception.InnerException.Message)" -ForegroundColor Red
}

# Test with max_tokens=4096
Write-Host "`n--- DeepSeek with max_tokens=4096 ---" -ForegroundColor Yellow
$body2 = '{"model":"deepseek-chat","messages":[{"role":"user","content":"Say hi"}],"max_tokens":4096}'
$content2 = New-Object System.Net.Http.StringContent($body2, [System.Text.Encoding]::UTF8, 'application/json')
try {
    $response2 = $client.PostAsync('https://api.deepseek.com/v1/chat/completions', $content2).Result
    $responseBody2 = $response2.Content.ReadAsStringAsync().Result
    Write-Host "  Status: $($response2.StatusCode) ($([int]$response2.StatusCode))"
    if ($response2.IsSuccessStatusCode) {
        $json2 = $responseBody2 | ConvertFrom-Json
        Write-Host "  OK: $($json2.choices[0].message.content)" -ForegroundColor Green
    } else {
        Write-Host "  Body: $responseBody2" -ForegroundColor Red
    }
} catch {
    Write-Host "  Error: $($_.Exception.InnerException.Message)" -ForegroundColor Red
}

$client.Dispose()
