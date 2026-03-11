$keys = @('DEEPSEEK_API_KEY','KIMI_API_KEY','GLM_API_KEY','MINIMAX_API_KEY','OPENAI_API_KEY','ANTHROPIC_API_KEY','ZHIPU_API_KEY','BIGMODEL_API_KEY')
foreach ($name in $keys) {
    $v = [System.Environment]::GetEnvironmentVariable($name,'User')
    if ($v) { Write-Host "$name = SET (len $($v.Length))" } else { Write-Host "$name = NOT SET" }
}
