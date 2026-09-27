# LOCAL dev helper (not committed): enables the policy sandbox in the extracted ACP distribution
# and points the Default gateway environment to the standalone gateway (portOffset=1).
param(
    [string]$Toml = "$PSScriptRoot\..\modules\distribution\product\target\run\wso2am-acp-4.7.0-SNAPSHOT\repository\conf\deployment.toml",
    [string]$SandboxUrl = 'https://localhost:9444/api/am/gateway/v2'
)
$text = [System.IO.File]::ReadAllText($Toml)
if ($text -notmatch '(?m)^\s*sandbox_url\s*=') {
    $regex = [regex]'(?m)^(service_url\s*=\s*"https://localhost:9443/services/"\s*)$'
    $text = $regex.Replace($text, "`$1`nsandbox_url = `"$SandboxUrl`"", 1)
}
if ($text -notmatch '(?m)^\[apim\.policy_sandbox\]') {
    $text = $text.TrimEnd() + "`n`n[apim.policy_sandbox]`nenable = true`n"
}
[System.IO.File]::WriteAllText($Toml, $text, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Policy sandbox enabled in $Toml (sandbox_url=$SandboxUrl)"
