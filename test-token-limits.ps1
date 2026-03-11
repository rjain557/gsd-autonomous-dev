Add-Type -AssemblyName System.Net.Http

# Test max_tokens limits for Kimi and MiniMax
$kimiKey = [System.Environment]::GetEnvironmentVariable('KIMI_API_KEY', 'User')
$mmKey = [System.Environment]::GetEnvironmentVariable('MINIMAX_API_KEY', 'User')

$client = New-Object System.Net.Http.HttpClient
$client.Timeout = [TimeSpan]::FromSeconds(15)

# Kimi with 16384
Write-Host "--- Kimi max_tokens=16384 ---" -ForegroundColor Yellow
$client.DefaultRequestHeaders.Clear()
$client.DefaultRequestHeaders.Add("Authorization", "Bearer $kimiKey")
$body = '{"model":"moonshot-v1-8k","messages":[{"role":"user","content":"Say hi"}],"max_tokens":16384}'
$content = New-Object System.Net.Http.StringContent($body, [System.Text.Encoding]::UTF8, 'application/json')
$response = $client.PostAsync('https://api.moonshot.ai/v1/chat/completions', $content).Result
$rb = $response.Content.ReadAsStringAsync().Result
Write-Host "  Status: $([int]$response.StatusCode)"
if (-not $response.IsSuccessStatusCode) { Write-Host "  $rb" }
else { Write-Host "  OK" -ForegroundColor Green }

# MiniMax with 16384
Write-Host "`n--- MiniMax max_tokens=16384 ---" -ForegroundColor Yellow
$client.DefaultRequestHeaders.Clear()
$client.DefaultRequestHeaders.Add("Authorization", "Bearer $mmKey")
$body2 = '{"model":"MiniMax-Text-01","messages":[{"role":"user","content":"Say hi"}],"max_tokens":16384}'
$content2 = New-Object System.Net.Http.StringContent($body2, [System.Text.Encoding]::UTF8, 'application/json')
$response2 = $client.PostAsync('https://api.minimax.io/v1/chat/completions', $content2).Result
$rb2 = $response2.Content.ReadAsStringAsync().Result
Write-Host "  Status: $([int]$response2.StatusCode)"
if (-not $response2.IsSuccessStatusCode) { Write-Host "  $rb2" }
else { Write-Host "  OK" -ForegroundColor Green }

$client.Dispose()
