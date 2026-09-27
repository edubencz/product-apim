param(
    [Parameter(Mandatory = $true)]
    [string] $WorkspaceFolder
)

$ErrorActionPreference = 'Stop'

$pom = [xml] (Get-Content -LiteralPath (Join-Path $WorkspaceFolder 'pom.xml') -Raw)
$version = [string] $pom.project.version
$name = "wso2am-$version"
$target = Join-Path $WorkspaceFolder 'modules\distribution\product\target'
$run = Join-Path $target 'run'
$distributionHome = Join-Path $run $name
$launcher = Join-Path $distributionHome 'bin\api-manager.bat'

if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
    $archive = Join-Path $target "$name.zip"
    if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) {
        throw "Distribuicao nao encontrada: $archive. Execute a tarefa 'All in One: Compilar' primeiro."
    }

    Write-Host "Extraindo $archive para $run..."
    New-Item -ItemType Directory -Path $run -Force | Out-Null
    Expand-Archive -LiteralPath $archive -DestinationPath $run -Force
}

# Habilita o sandbox do Policy Builder em toda inicializacao (idempotente; a secao precisa ficar depois de [apim]).
$toml = Join-Path $distributionHome 'repository\conf\deployment.toml'
if (Test-Path -LiteralPath $toml -PathType Leaf) {
    $content = [System.IO.File]::ReadAllText($toml)
    if ($content -notmatch '(?m)^\[apim\.policy_sandbox\]') {
        $content = $content.TrimEnd() + "`n`n[apim.policy_sandbox]`nenable = true`n"
        [System.IO.File]::WriteAllText($toml, $content, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "Policy sandbox habilitado em $toml"
    }
}

if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
    throw "Script de inicializacao nao encontrado: $launcher"
}

if (Test-Path -LiteralPath 'C:\Program Files\Java\jdk-21.0.10\bin\java.exe') {
    $env:JAVA_HOME = 'C:\Program Files\Java\jdk-21.0.10'
    $env:PATH = (Join-Path $env:JAVA_HOME 'bin') + ';' + $env:PATH
}

Write-Host "Iniciando All in One em $distributionHome"
Set-Location -LiteralPath (Join-Path $distributionHome 'bin')
& $launcher
exit $LASTEXITCODE
