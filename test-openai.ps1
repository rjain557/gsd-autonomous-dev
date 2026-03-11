$key = [System.Environment]::GetEnvironmentVariable('OPENAI_API_KEY','User')
if (-not $key) { $key = [System.Environment]::GetEnvironmentVariable('OPENAI_API_KEY','Process') }
if (-not $key) { $key = [System.Environment]::GetEnvironmentVariable('OPENAI_API_KEY','Machine') }
if (-not $key) { Write-Host "NO OPENAI_API_KEY FOUND"; exit 1 }
Write-Host "Key found: $($key.Substring(0,8))..."

try {
    $headers = @{
        Authorization = "Bearer $key"
        "Content-Type" = "application/json"
    }
    $body = @{
        model = "gpt-5.1-codex-mini"
        messages = @(@{ role = "user"; content = "Say OK" })
        max_tokens = 5
    } | ConvertTo-Json -Depth 5

    $response = Invoke-RestMethod "https://api.openai.com/v1/chat/completions" -Method Post -Headers $headers -Body $body -TimeoutSec 15
    Write-Host "SUCCESS: $($response.choices[0].message.content)"
    Write-Host "Model: $($response.model)"
}
catch {
    $statusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "N/A" }
    Write-Host "ERROR HTTP $statusCode"
    Write-Host $_.Exception.Message.Substring(0, [Math]::Min(300, $_.Exception.Message.Length))
}
