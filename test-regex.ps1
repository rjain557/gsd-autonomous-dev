$text = Get-Content "D:/vscode/tech-web-chatai.v8/tech-web-chatai.v8/.gsd/plans/iteration-1.json" -Raw
Write-Host "Length: $($text.Length)"

# Simple string approach - strip code fences
$jsonText = $text.Trim()
if ($jsonText.StartsWith('```')) {
    $firstNewline = $jsonText.IndexOf("`n")
    $lastFence = $jsonText.LastIndexOf('```')
    if ($firstNewline -gt 0 -and $lastFence -gt $firstNewline) {
        $jsonText = $jsonText.Substring($firstNewline + 1, $lastFence - $firstNewline - 1).Trim()
    }
}

Write-Host "Extracted length: $($jsonText.Length)"
Write-Host "First 30 chars: $($jsonText.Substring(0, [Math]::Min(30, $jsonText.Length)))"

try {
    $parsed = $jsonText | ConvertFrom-Json
    Write-Host "SUCCESS! Plans count: $($parsed.plans.Count)"
    foreach ($p in $parsed.plans) {
        Write-Host "  - $($p.req_id): $($p.complexity) (confidence: $($p.confidence))"
    }
}
catch {
    Write-Host "JSON parse failed: $_"
}
