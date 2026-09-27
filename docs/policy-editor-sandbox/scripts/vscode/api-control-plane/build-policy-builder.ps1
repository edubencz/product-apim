# Build completo do Policy Builder: carbon-apimgt -> apim-apps (publisher) -> distribuicao (acp ou aio).
# Uso: build-policy-builder.ps1 -Target acp|aio [-SkipCarbon] [-SkipUi]
param(
    [ValidateSet('acp', 'aio')] [string] $Target = 'acp',
    [switch] $SkipCarbon,
    [switch] $SkipUi
)
$ErrorActionPreference = 'Stop'

$workspace = 'C:\workspace'
$carbon = Join-Path $workspace 'carbon-apimgt'
$apps = Join-Path $workspace 'apim-apps'
$product = Join-Path $workspace 'wso2-product-apim'

$env:JAVA_HOME = 'C:\Program Files\Java\jdk-21.0.10'
$env:PATH = (Join-Path $env:JAVA_HOME 'bin') + ';' + $env:PATH

function Invoke-Step([string] $title, [string] $dir, [string[]] $mvnArgs) {
    Write-Host "`n=== $title ($dir) ===" -ForegroundColor Cyan
    $started = Get-Date
    Push-Location $dir
    try {
        & mvn @mvnArgs
        if ($LASTEXITCODE -ne 0) { throw "Falhou: $title (exit $LASTEXITCODE)" }
    } finally { Pop-Location }
    Write-Host ("=== OK: {0} em {1:mm\:ss} ===" -f $title, ((Get-Date) - $started)) -ForegroundColor Green
}

function Assert-NotRunning([string] $pattern, [string] $what) {
    $running = Get-CimInstance Win32_Process -Filter "Name='java.exe'" | Where-Object { $_.CommandLine -match $pattern }
    if ($running) { throw "$what esta rodando (PID $($running.ProcessId -join ', ')). Pare antes do build." }
}

if ($Target -eq 'acp') { Assert-NotRunning 'API-CO|api-control-plane' 'O Control Plane' }
else { Assert-NotRunning 'ALL-IN~1|all-in-one-apim' 'O All-in-one' }

if (-not $SkipCarbon) {
    Invoke-Step 'carbon-apimgt' $carbon @('install', '-DskipTests', '-Dcheckstyle.skip=true',
        '-Dfindbugs.skip=true', '-Dspotbugs.skip=true', '-Djacoco.skip=true')
}

if (-not $SkipUi) {
    # Scripts npm usam atribuicao inline (NODE_OPTIONS=...), que exige bash no Windows.
    $env:npm_config_script_shell = 'C:\Program Files\Git\bin\bash.exe'
    # O extrator de i18n do build regrava o en.json; restauramos se ele estava limpo antes.
    $enJson = 'portals/publisher/src/main/webapp/site/public/locales/en.json'
    $enJsonWasClean = -not (git -C $apps status --porcelain -- $enJson)
    try {
        # admin/devportal nao mudam e ja estao no ~/.m2; so o publisher e o agregador sao rebuildados.
        Invoke-Step 'apim-apps (publisher)' $apps @('install', '-DskipTests', '-Dcheckstyle.skip=true',
            '-pl', '.,portals/publisher,portals')
    } finally {
        Remove-Item Env:npm_config_script_shell -ErrorAction SilentlyContinue
        if ($enJsonWasClean) { git -C $apps checkout -- $enJson }
    }
}

if ($Target -eq 'acp') {
    $acp = Join-Path $product 'api-control-plane'
    Invoke-Step 'api-control-plane' $acp @('clean', 'install', '-DskipTests', '-Dcheckstyle.skip=true')

    $target = Join-Path $acp 'modules\distribution\product\target'
    $run = Join-Path $target 'run'
    Write-Host "`nExtraindo distribuicao em $run..."
    New-Item -ItemType Directory -Force -Path $run | Out-Null
    Expand-Archive -Path (Join-Path $target 'wso2am-acp-4.7.0-SNAPSHOT.zip') -DestinationPath $run -Force
    & (Join-Path $PSScriptRoot 'enable-policy-sandbox.ps1')
    Write-Host "`nPronto. Suba com 'ACP: Start Server' e 'GW: Start Gateway'." -ForegroundColor Green
} else {
    $aio = Join-Path $product 'all-in-one-apim'
    Invoke-Step 'all-in-one-apim' $aio @('clean', 'install', '-DskipTests', '-Dcheckstyle.skip=true',
        '-pl', 'modules/p2-profile/product,modules/distribution/product', '-am')
    Write-Host "`nPronto. Suba com 'All in One: Iniciar' (extrai o zip novo e habilita o sandbox)." -ForegroundColor Green
}
