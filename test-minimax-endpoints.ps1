$mmKey = [System.Environment]::GetEnvironmentVariable('MINIMAX_API_KEY', 'User')
Write-Host "Key prefix: $($mmKey.Substring(0,15))..."
$headers = @{ Authorization = "Bearer $mmKey"; 'Content-Type' = 'application/json' }
$body = '{"model":"abab6.5s-chat","messages":[{"role":"user","content":"Say hi"}],"max_tokens":10}'

Write-Host "--- platform.minimax.io/v1/text/chatcompletion_v2 ---" -ForegroundColor Yellow
try {
    $r = Invoke-RestMethod -Uri 'https://platform.minimax.io/v1/text/chatcompletion_v2' -Method Post -Headers $headers -Body $body -TimeoutSec 15
    Write-Host "OK: $($r.choices[0].message.content)"
} catch {
    $s = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "timeout" }
    $errBody = ""
    if ($_.Exception.Response) {
        try { $sr = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream()); $errBody = $sr.ReadToEnd(); $sr.Close() } catch {}
    }
    Write-Host "FAIL ($s): $($_.Exception.Message)"
    if ($errBody) { Write-Host "Body: $errBody" }
}

Write-Host "`n--- platform.minimax.io/v1/chat/completions ---" -ForegroundColor Yellow
try {
    $r2 = Invoke-RestMethod -Uri 'https://platform.minimax.io/v1/chat/completions' -Method Post -Headers $headers -Body $body -TimeoutSec 15
    Write-Host "OK: $($r2.choices[0].message.content)"
} catch {
    $s2 = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "timeout" }
    $errBody2 = ""
    if ($_.Exception.Response) {
        try { $sr = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream()); $errBody2 = $sr.ReadToEnd(); $sr.Close() } catch {}
    }
    Write-Host "FAIL ($s2)"
    if ($errBody2) { Write-Host "Body: $errBody2" }
}

Write-Host "`n--- api.minimax.io/v1/chat/completions ---" -ForegroundColor Yellow
try {
    $r3 = Invoke-RestMethod -Uri 'https://api.minimax.io/v1/chat/completions' -Method Post -Headers $headers -Body $body -TimeoutSec 15
    Write-Host "OK: $($r3.choices[0].message.content)"
} catch {
    $s3 = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "timeout" }
    $errBody3 = ""
    if ($_.Exception.Response) {
        try { $sr = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream()); $errBody3 = $sr.ReadToEnd(); $sr.Close() } catch {}
    }
    Write-Host "FAIL ($s3)"
    if ($errBody3) { Write-Host "Body: $errBody3" }
}
