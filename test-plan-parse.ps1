$text = Get-Content "D:/vscode/tech-web-chatai.v8/tech-web-chatai.v8/.gsd/plans/iteration-1.json" -Raw
Write-Host "Raw length: $($text.Length)"
Write-Host "First 20: $($text.Substring(0,20))"

$jsonText = $text.Trim()
if ($jsonText.StartsWith('```')) {
    Write-Host "Starts with code fence"
    $firstNl = $jsonText.IndexOf("`n")
    Write-Host "First newline at: $firstNl"
    if ($firstNl -gt 0) {
        $jsonText = $jsonText.Substring($firstNl + 1)
    }
    $lastFence = $jsonText.LastIndexOf('```')
    Write-Host "Last fence at: $lastFence (of $($jsonText.Length))"
    if ($lastFence -gt 0) {
        $jsonText = $jsonText.Substring(0, $lastFence)
    }
    $jsonText = $jsonText.Trim()
}

Write-Host "Cleaned length: $($jsonText.Length)"
Write-Host "First 30: $($jsonText.Substring(0, [Math]::Min(30, $jsonText.Length)))"
Write-Host "Last 30: $($jsonText.Substring([Math]::Max(0, $jsonText.Length - 30)))"

try {
    $parsed = $jsonText | ConvertFrom-Json
    Write-Host "`nSUCCESS! Parsed OK" -ForegroundColor Green
    Write-Host "Plans count: $($parsed.plans.Count)"
    foreach ($p in $parsed.plans) {
        Write-Host "  $($p.req_id): $($p.complexity) (confidence: $($p.confidence))"
    }
}
catch {
    Write-Host "`nFAILED: $_" -ForegroundColor Red
}
