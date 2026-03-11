$ok = [System.Environment]::GetEnvironmentVariable('OPENAI_API_KEY', 'User')
if (-not $ok) { Write-Host "NO API KEY"; exit 1 }
$h = @{ Authorization = "Bearer $ok" }
$b = '{"model":"gpt-5.1-codex-mini","input":[{"role":"user","content":"Say hi"}],"max_output_tokens":50}'
Write-Host "Testing Codex Mini..."
try {
    $r = Invoke-RestMethod -Uri 'https://api.openai.com/v1/responses' -Method Post -Headers $h -Body $b -TimeoutSec 15 -ContentType 'application/json'
    Write-Host "OK: status=$($r.status), tokens=$($r.usage.output_tokens)"
    Write-Host "Output: $($r.output_text)"
} catch {
    $s = "none"
    if ($_.Exception.Response) { $s = [int]$_.Exception.Response.StatusCode }
    Write-Host "FAIL: Status=$s"
    try {
        $stream = $_.Exception.Response.GetResponseStream()
        $reader = [System.IO.StreamReader]::new($stream)
        $errBody = $reader.ReadToEnd()
        Write-Host "Error body: $errBody"
    } catch {
        Write-Host "Could not read error body: $($_.Exception.Message)"
    }
}

# Now test with a LARGE payload like the pipeline sends
Write-Host "`n--- Test 2: Large payload (like pipeline) ---"
$largeContent = "You are a code generator. Generate a complete C# service class with CRUD operations for a User entity. Include:" + ("x" * 2000)
$b2 = @{
    model = "gpt-5.1-codex-mini"
    input = @(
        @{ role = "user"; content = $largeContent }
    )
    max_output_tokens = 16384
    instructions = "Generate production-quality C# code."
} | ConvertTo-Json -Depth 10 -Compress
Write-Host "Payload size: $($b2.Length) chars"
try {
    $r2 = Invoke-RestMethod -Uri 'https://api.openai.com/v1/responses' -Method Post -Headers $h -Body $b2 -TimeoutSec 60 -ContentType 'application/json'
    Write-Host "OK: status=$($r2.status), tokens=$($r2.usage.output_tokens)"
} catch {
    $s2 = "none"
    if ($_.Exception.Response) { $s2 = [int]$_.Exception.Response.StatusCode }
    Write-Host "FAIL: Status=$s2"
    try {
        $stream2 = $_.Exception.Response.GetResponseStream()
        $reader2 = [System.IO.StreamReader]::new($stream2)
        Write-Host "Error body: $($reader2.ReadToEnd())"
    } catch {
        Write-Host "Could not read error body"
    }
}
