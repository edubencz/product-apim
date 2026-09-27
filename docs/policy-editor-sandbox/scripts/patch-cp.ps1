# Hot-patches the local ACP runtime with newly compiled classes for the policy-editor + sandbox feature,
# WITHOUT rebuilding/repackaging the whole product. The Control Plane (ACP) process MUST be stopped before
# running this script.
#
# It generalizes stage/patch-cp-render.ps1 (which only patched the publisher.v1.common bundle for /render)
# to also patch:
#   - org.wso2.carbon.apimgt.api            (Environment.sandboxURL)
#   - org.wso2.carbon.apimgt.impl           (APIManagerConfiguration, APIConstants, new dto/ and
#                                             policy/sandbox/ packages)
#   - org.wso2.carbon.apimgt.rest.api.publisher.v1.common (SettingsMappingUtil, SettingsDTO, ...)
#   - the api#am#publisher WAR (publisher.v1 module: new/changed REST impl + gen classes)
#
# IMPORTANT (lesson learned the hard way): do NOT assume a bundle's Export-Package already covers a
# newly-added package just because it looks like it exports "the whole component" - these manifests are
# bnd/felix-generated at build time from an EXPLICIT list of the packages that existed then. There is no
# wildcard. A brand-new package (e.g. org.wso2.carbon.apimgt.impl.policy.sandbox, added for
# GatewaySandboxClient) is invisible to every other OSGi bundle - including the webapp that does
# `new OperationPoliciesApiServiceImpl()` - until Export-Package explicitly lists it. This script now
# verifies that itself instead of trusting a comment: for every bundle it patches, it computes the Java
# package of each injected class, checks it against the CURRENT Export-Package header, and appends any
# package that's missing (with the bundle's own Bundle-Version). It does the mirror check for
# Import-Package against the injected classes' own `import` statements, and warns (without hard-failing,
# since DynamicImport-Package: * on several of these bundles provides a safety net at runtime) about any
# import whose package isn't statically imported and isn't covered by that fallback.
#
# Usage:
#   pwsh -File patch-cp.ps1 [-RuntimeDir <path to wso2am-acp-...>]
#
# Safety: every path touched is verified to be inside the given runtime directory before being modified.
# The first time a given bundle jar is patched in a runtime, an untouched copy is saved under
# api-control-plane\stage\plugin-backups (OUTSIDE repository\components\plugins, so OSGi never scans it).

param(
    [string]$RuntimeDir = 'C:\workspace\wso2-product-apim\api-control-plane\modules\distribution\product\target\run\wso2am-acp-4.7.0-SNAPSHOT',
    [string]$BackupDir = 'C:\workspace\wso2-product-apim\api-control-plane\stage\plugin-backups'
)

$ErrorActionPreference = 'Stop'
$jar = 'C:\Program Files\Java\jdk-21.0.10\bin\jar.exe'
$carbon = 'C:\workspace\carbon-apimgt\components\apimgt'
$runtime = (Resolve-Path -LiteralPath $RuntimeDir).Path
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
$BackupDir = (Resolve-Path -LiteralPath $BackupDir).Path

function Assert-InRuntime([string]$path) {
    $full = [System.IO.Path]::GetFullPath($path)
    if (!$full.StartsWith($runtime + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to touch a path outside the runtime: $full"
    }
    return $full
}

# ---------------------------------------------------------------------------
# MANIFEST.MF helpers (RFC-style manifest: 72-byte-max lines, single-space
# continuation, CRLF line endings, trailing newline).
# ---------------------------------------------------------------------------

# Reads a MANIFEST.MF file and returns its logical (unfolded) header lines, one string per header,
# continuation lines already joined back onto the header they belong to.
function Read-ManifestUnfolded([string]$path) {
    $raw = Get-Content -LiteralPath $path -Raw
    $rawLines = $raw -replace "`r`n", "`n" -replace "`r", "`n" -split "`n"
    $unfolded = New-Object System.Collections.Generic.List[string]
    foreach ($line in $rawLines) {
        if ($line.Length -eq 0) { continue }
        if ($line[0] -eq ' ') {
            if ($unfolded.Count -eq 0) { throw "Malformed manifest: continuation line with no preceding header: $path" }
            $unfolded[$unfolded.Count - 1] += $line.Substring(1)
        } else {
            $unfolded.Add($line)
        }
    }
    return , $unfolded
}

function Get-ManifestHeader([System.Collections.Generic.List[string]]$lines, [string]$name) {
    $prefix = "$name`: "
    foreach ($l in $lines) {
        if ($l.StartsWith($prefix, [StringComparison]::Ordinal)) { return $l.Substring($prefix.Length) }
    }
    return $null
}

function Set-ManifestHeader([System.Collections.Generic.List[string]]$lines, [string]$name, [string]$value) {
    $prefix = "$name`: "
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].StartsWith($prefix, [StringComparison]::Ordinal)) { $lines[$i] = $prefix + $value; return }
    }
    $lines.Add($prefix + $value)
}

# Splits a manifest header VALUE (e.g. an Export-Package value) into its top-level comma-separated
# clauses, respecting double-quoted attribute values (which themselves may contain commas, though
# version ranges here don't - this is still correct either way).
function Split-ManifestClauses([string]$value) {
    $clauses = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrEmpty($value)) { return $clauses }
    $inQuote = $false
    $cur = New-Object System.Text.StringBuilder
    foreach ($ch in $value.ToCharArray()) {
        if ($ch -eq '"') { $inQuote = -not $inQuote }
        if ($ch -eq ',' -and -not $inQuote) {
            $clauses.Add($cur.ToString())
            $cur = New-Object System.Text.StringBuilder
        } else {
            [void]$cur.Append($ch)
        }
    }
    if ($cur.Length -gt 0) { $clauses.Add($cur.ToString()) }
    return , $clauses
}

function Get-ClausePackageName([string]$clause) {
    return ($clause -split ';')[0].Trim()
}

# Writes the (possibly modified) unfolded header lines back to a manifest file: 72-byte-max line length
# (bytes, per the manifest spec), continuation lines starting with exactly one space, CRLF endings, and
# a trailing newline.
function Write-ManifestFile([string]$path, [System.Collections.Generic.List[string]]$lines) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($line in $lines) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($line)
        if ($bytes.Length -le 72) {
            [void]$sb.Append($line).Append("`r`n")
            continue
        }
        $offset = 0
        $first = $true
        while ($offset -lt $bytes.Length) {
            $chunkLen = if ($first) { 72 } else { 71 }
            $take = [Math]::Min($chunkLen, $bytes.Length - $offset)
            $chunkStr = [System.Text.Encoding]::UTF8.GetString($bytes, $offset, $take)
            if ($first) { [void]$sb.Append($chunkStr) } else { [void]$sb.Append(' ').Append($chunkStr) }
            [void]$sb.Append("`r`n")
            $offset += $take
            $first = $false
        }
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, $sb.ToString(), $utf8NoBom)
}

# Given a set of relative .class paths, returns the distinct Java package names (dotted).
function Get-PackagesOf([string[]]$relPaths) {
    $set = New-Object System.Collections.Generic.HashSet[string]
    foreach ($r in $relPaths) {
        $dir = Split-Path $r -Parent
        if ($dir) { [void]$set.Add(($dir -replace '[\\/]', '.')) }
    }
    # -NoEnumerate: guarantees exactly one pipeline object (the array itself), so the caller's
    # assignment always gets back a real string[] - even when it has 0 or 1 elements, which a bare
    # `return $arr` would otherwise scalarize/drop via PowerShell's pipeline unrolling.
    Write-Output -NoEnumerate ([string[]]$set)
}

# Best-effort: reads the `import` statements out of the .java source for each *top-level* class in
# $relPaths (inner/anonymous classes are skipped - their imports are already covered by the outer
# class's source file), and returns the set of imported package names, excluding java.* (boot
# delegation) and packages under $ownPackagePrefixes (provided by this same bundle already).
function Get-SourceImportedPackages([string]$classesDir, [string[]]$relPaths, [string[]]$ownPackagePrefixes) {
    $srcDir = $classesDir -replace '\\target\\classes$', '\src\main\java'
    $imports = New-Object System.Collections.Generic.HashSet[string]
    foreach ($rel in $relPaths) {
        if ($rel -notlike '*.class') { continue }
        $base = [System.IO.Path]::GetFileNameWithoutExtension($rel)
        if ($base -match '\$') { continue } # inner/anonymous class - covered by its outer class's .java
        $javaRel = [System.IO.Path]::ChangeExtension($rel, 'java')
        $javaPath = Join-Path $srcDir $javaRel
        if (!(Test-Path -LiteralPath $javaPath)) { continue }
        Get-Content -LiteralPath $javaPath | ForEach-Object {
            if ($_ -match '^\s*import\s+(?:static\s+)?([\w\.]+)\.[\w\*]+\s*;') {
                $pkg = $Matches[1]
                if ($pkg.StartsWith('java.')) { return }
                foreach ($own in $ownPackagePrefixes) {
                    if ($pkg -eq $own -or $pkg.StartsWith("$own.")) { return }
                }
                [void]$imports.Add($pkg)
            }
        }
    }
    Write-Output -NoEnumerate ([string[]]$imports)
}

# Add-Type is required in Windows PowerShell 5.1 (the .NET Framework "Desktop" CLR this host runs on)
# before System.IO.Compression.ZipFile is usable - without it, every ZipFile::OpenRead call below throws
# and gets silently swallowed by the catch/continue, making every lookup falsely report "not found".
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Lazily builds (once) an index of every package exported by any OSGi bundle jar under the runtime's
# plugins directory, mapping package name -> version attribute (or $null if the clause had none).
# Building it once and reusing it is both far faster than re-scanning ~250 jars per lookup, and immune
# to per-jar transient failures masking a real match found in a later jar.
$script:ExportedPackageIndex = $null
function Build-ExportedPackageIndex {
    $index = @{}
    $pluginsDir = Join-Path $runtime 'repository\components\plugins'
    foreach ($f in Get-ChildItem -LiteralPath $pluginsDir -Filter '*.jar') {
        $archive = $null
        try {
            $archive = [System.IO.Compression.ZipFile]::OpenRead($f.FullName)
            $entry = $archive.GetEntry('META-INF/MANIFEST.MF')
            if (-not $entry) { continue }
            $reader = New-Object System.IO.StreamReader($entry.Open())
            $text = $reader.ReadToEnd()
            $reader.Dispose()
        } catch {
            Write-Warning "  Could not read manifest of $($f.Name): $($_.Exception.Message)"
            continue
        } finally {
            if ($archive) { $archive.Dispose() }
        }
        $text = $text -replace "`r`n", "`n" -replace "`r", "`n"
        $unfolded = New-Object System.Collections.Generic.List[string]
        foreach ($line in ($text -split "`n")) {
            if ($line.Length -eq 0) { continue }
            if ($line[0] -eq ' ') { if ($unfolded.Count -gt 0) { $unfolded[$unfolded.Count - 1] += $line.Substring(1) } }
            else { $unfolded.Add($line) }
        }
        $exportVal = Get-ManifestHeader $unfolded 'Export-Package'
        if (-not $exportVal) { continue }
        foreach ($clause in (Split-ManifestClauses $exportVal)) {
            $pkgName = Get-ClausePackageName $clause
            if (-not $pkgName -or $index.ContainsKey($pkgName)) { continue }
            $version = $null
            if ($clause -match 'version="([^"]+)"') { $version = $Matches[1] }
            $index[$pkgName] = $version
        }
    }
    return $index
}

function Find-ExportedPackageVersion([string]$pkg) {
    if (-not $script:ExportedPackageIndex) { $script:ExportedPackageIndex = Build-ExportedPackageIndex }
    if ($script:ExportedPackageIndex.ContainsKey($pkg)) { return $script:ExportedPackageIndex[$pkg] }
    return $null
}

# Ensures every package in $neededPackages is present in the bundle's Export-Package header (adding
# `pkg;version="$bundleVersion"` for any that's missing). Returns the list of packages actually added.
function Add-MissingExportedPackages([System.Collections.Generic.List[string]]$manifestLines, [string[]]$neededPackages, [string]$bundleVersion) {
    $exportVal = Get-ManifestHeader $manifestLines 'Export-Package'
    $clauses = Split-ManifestClauses $exportVal
    $existing = New-Object System.Collections.Generic.HashSet[string]
    foreach ($c in $clauses) { [void]$existing.Add((Get-ClausePackageName $c)) }
    $added = @()
    foreach ($pkg in $neededPackages) {
        if (-not $existing.Contains($pkg)) {
            $clauses.Add("$pkg;version=`"$bundleVersion`"")
            $added += $pkg
        }
    }
    if ($added.Count -gt 0) {
        Set-ManifestHeader $manifestLines 'Export-Package' (($clauses -join ','))
    }
    return $added
}

# Reports (and, when a version can be resolved from some other bundle in the runtime, also adds)
# any package imported by the injected classes' source that isn't already in Import-Package. Never
# hard-fails: DynamicImport-Package (when present as "*") is a documented fallback for these bundles.
function Reconcile-ImportedPackages([System.Collections.Generic.List[string]]$manifestLines, [string[]]$neededPackages, [string]$bundleLabel) {
    if ($neededPackages.Count -eq 0) { return }
    $importVal = Get-ManifestHeader $manifestLines 'Import-Package'
    $clauses = Split-ManifestClauses $importVal
    $existing = New-Object System.Collections.Generic.HashSet[string]
    foreach ($c in $clauses) { [void]$existing.Add((Get-ClausePackageName $c)) }
    $dynamicVal = Get-ManifestHeader $manifestLines 'DynamicImport-Package'
    $hasDynamicWildcard = ($dynamicVal -and ($dynamicVal.Trim() -eq '*' -or ($dynamicVal -split ',') -contains '*'))

    $missing = $neededPackages | Where-Object { -not $existing.Contains($_) }
    if ($missing.Count -eq 0) { return }

    $added = @()
    $unresolved = @()
    foreach ($pkg in $missing) {
        $version = Find-ExportedPackageVersion $pkg
        if ($version) {
            $clauses.Add("$pkg;version=`"$version`"")
            $added += "$pkg (version=$version, from another runtime bundle)"
        } else {
            $unresolved += $pkg
        }
    }
    if ($added.Count -gt 0) {
        Set-ManifestHeader $manifestLines 'Import-Package' (($clauses -join ','))
        Write-Output "  [$bundleLabel] Added to Import-Package: $($added -join '; ')"
    }
    if ($unresolved.Count -gt 0) {
        $fallback = if ($hasDynamicWildcard) { '(covered by DynamicImport-Package: * as a runtime fallback)' } else { '(NOT covered by any DynamicImport-Package wildcard - verify manually)' }
        Write-Warning "  [$bundleLabel] Import-Package: could not find an exporting bundle in this runtime for: $($unresolved -join ', ') $fallback"
    }
}

function Patch-Bundle {
    param(
        [string]$BundleGlob,        # e.g. 'org.wso2.carbon.apimgt.api_*.jar'
        [string]$ClassesDir,        # module's target/classes
        [string[]]$ClassRelPaths,   # class files (and inner classes), relative to ClassesDir
        [string[]]$OwnPackagePrefixes = @()  # packages this bundle already provides itself (skip for Import-Package check)
    )
    $bundlePath = Get-ChildItem -LiteralPath (Join-Path $runtime 'repository\components\plugins') -Filter $BundleGlob |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not $bundlePath) { throw "Bundle not found: $BundleGlob" }
    $bundlePath = Assert-InRuntime $bundlePath
    $bundleLabel = Split-Path $bundlePath -Leaf

    # One-time backup of the untouched jar, kept outside repository\components\plugins so OSGi never
    # scans it as a second copy of the same bundle.
    $backupPath = Join-Path $BackupDir $bundleLabel
    if (!(Test-Path -LiteralPath $backupPath)) {
        Copy-Item -LiteralPath $bundlePath -Destination $backupPath
        Write-Output "  Backed up original $bundleLabel -> $backupPath"
    }

    $work = Join-Path $env:TEMP ('cp-patch-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    try {
        $unpacked = Join-Path $work 'unpacked'
        New-Item -ItemType Directory -Force -Path $unpacked | Out-Null
        Push-Location $unpacked
        try { & $jar xf $bundlePath; if ($LASTEXITCODE -ne 0) { throw 'jar xf failed' } }
        finally { Pop-Location }

        foreach ($rel in $ClassRelPaths) {
            $src = Join-Path $ClassesDir $rel
            if (!(Test-Path -LiteralPath $src)) { throw "Compiled class missing (build the module first): $src" }
            # Guard against patching in JaCoCo-instrumented classes: `mvn test` performs offline
            # instrumentation of target/classes (injecting a $jacocoInit call to a class that is not on
            # the OSGi bundle's classpath), which crashes the bundle's DS component on activation with a
            # ClassNotFoundException for org.jacoco.agent.rt.internal_*.Offline. Always rebuild with
            # `mvn install -DskipTests` (never leave a `mvn test` run's output as the patch source) before
            # running this script.
            $bytes = [System.IO.File]::ReadAllBytes($src)
            $text = [System.Text.Encoding]::ASCII.GetString($bytes)
            if ($text.Contains('jacocoInit') -or $text.Contains('jacoco')) {
                throw "Refusing to patch a JaCoCo-instrumented class: $src`nRebuild the module with 'mvn install -DskipTests' (not 'mvn test') and retry."
            }
            $dst = Join-Path $unpacked $rel
            New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
            Copy-Item -LiteralPath $src -Destination $dst -Force
        }

        # --- MANIFEST.MF reconciliation: Export-Package for the injected classes' own packages, and a
        #     best-effort Import-Package reconciliation for what those classes import. ---
        $manifestPath = Join-Path $unpacked 'META-INF\MANIFEST.MF'
        $manifestLines = Read-ManifestUnfolded $manifestPath
        $bundleVersion = Get-ManifestHeader $manifestLines 'Bundle-Version'
        if (-not $bundleVersion) { throw "Bundle-Version header missing in $bundleLabel" }

        $neededExports = Get-PackagesOf $ClassRelPaths
        $addedExports = Add-MissingExportedPackages $manifestLines $neededExports $bundleVersion
        if ($addedExports.Count -gt 0) {
            Write-Output "  [$bundleLabel] Added to Export-Package (version=$bundleVersion): $($addedExports -join ', ')"
        } else {
            Write-Output "  [$bundleLabel] Export-Package already covers all injected packages"
        }

        $allOwnPrefixes = $OwnPackagePrefixes + $neededExports
        $importedPkgs = Get-SourceImportedPackages $ClassesDir $ClassRelPaths $allOwnPrefixes
        Reconcile-ImportedPackages $manifestLines $importedPkgs $bundleLabel

        Write-ManifestFile $manifestPath $manifestLines

        $patched = Join-Path $work 'patched.jar'
        & $jar cfm $patched $manifestPath -C $unpacked .
        if ($LASTEXITCODE -ne 0) { throw 'jar cfm failed' }
        Copy-Item -LiteralPath $patched -Destination $bundlePath -Force
        Write-Output "Patched $bundleLabel with $($ClassRelPaths.Count) class file(s)"
    } finally {
        $resolvedWork = [System.IO.Path]::GetFullPath($work)
        if ($resolvedWork.StartsWith([System.IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase) `
                -and (Test-Path -LiteralPath $resolvedWork)) {
            Remove-Item -LiteralPath $resolvedWork -Recurse -Force
        }
    }
}

# Expand every top-level class into its own class + any $Inner.class / $1.class siblings.
function Expand-WithInnerClasses([string]$classesDir, [string]$relPath) {
    $dir = Split-Path $relPath
    $base = [System.IO.Path]::GetFileNameWithoutExtension($relPath)
    $full = Join-Path $classesDir $dir
    if (!(Test-Path -LiteralPath $full)) { return @($relPath) }
    Get-ChildItem -LiteralPath $full -Filter ($base + '*.class') |
        ForEach-Object { if ($dir) { Join-Path $dir $_.Name } else { $_.Name } }
}

Write-Output "Runtime: $runtime"
Write-Output "Plugin backups: $BackupDir"

# --- org.wso2.carbon.apimgt.api: Environment.sandboxURL ---
$apiClasses = Join-Path $carbon 'org.wso2.carbon.apimgt.api\target\classes'
$apiRel = Expand-WithInnerClasses $apiClasses 'org\wso2\carbon\apimgt\api\model\Environment.class'
Patch-Bundle -BundleGlob 'org.wso2.carbon.apimgt.api_*.jar' -ClassesDir $apiClasses -ClassRelPaths $apiRel `
    -OwnPackagePrefixes @('org.wso2.carbon.apimgt.api')

# --- org.wso2.carbon.apimgt.impl: config parsing + GatewaySandboxClient ---
$implClasses = Join-Path $carbon 'org.wso2.carbon.apimgt.impl\target\classes'
$implRel = @()
$implRel += Expand-WithInnerClasses $implClasses 'org\wso2\carbon\apimgt\impl\APIConstants.class'
$implRel += Expand-WithInnerClasses $implClasses 'org\wso2\carbon\apimgt\impl\APIManagerConfiguration.class'
$implRel += Expand-WithInnerClasses $implClasses 'org\wso2\carbon\apimgt\impl\dto\OperationPolicySandboxConfig.class'
Get-ChildItem -LiteralPath (Join-Path $implClasses 'org\wso2\carbon\apimgt\impl\policy\sandbox') -Filter '*.class' |
    ForEach-Object { $implRel += "org\wso2\carbon\apimgt\impl\policy\sandbox\$($_.Name)" }
Patch-Bundle -BundleGlob 'org.wso2.carbon.apimgt.impl_*.jar' -ClassesDir $implClasses -ClassRelPaths $implRel `
    -OwnPackagePrefixes @('org.wso2.carbon.apimgt.impl')

# --- org.wso2.carbon.apimgt.rest.api.publisher.v1.common: SettingsMappingUtil / SettingsDTO / OperationPolicyRenderer
#     / all of the operation-policy sandbox DTOs (named schemas: OperationPolicyRenderRequest/Response/Error,
#     OperationPolicyTestRequest/Response, OperationPolicySandboxEnvironment/List). Patches the WHOLE dto/
#     package (recursively) rather than an explicit list, since this module's DTO surface changes often
#     (named-schema refactors, new fields) and a partial list silently goes stale.
$commonClasses = Join-Path $carbon 'org.wso2.carbon.apimgt.rest.api.publisher.v1.common\target\classes'
$commonRel = @()
$commonRel += Expand-WithInnerClasses $commonClasses 'org\wso2\carbon\apimgt\rest\api\publisher\v1\common\mappings\SettingsMappingUtil.class'
$commonRel += Expand-WithInnerClasses $commonClasses 'org\wso2\carbon\apimgt\rest\api\publisher\v1\common\OperationPolicyRenderer.class'
$dtoDir = Join-Path $commonClasses 'org\wso2\carbon\apimgt\rest\api\publisher\v1\dto'
if (Test-Path -LiteralPath $dtoDir) {
    Get-ChildItem -LiteralPath $dtoDir -Filter '*.class' -Recurse |
        ForEach-Object { $commonRel += $_.FullName.Substring($commonClasses.Length + 1) }
}
Patch-Bundle -BundleGlob 'org.wso2.carbon.apimgt.rest.api.publisher.v1.common_*.jar' -ClassesDir $commonClasses -ClassRelPaths $commonRel `
    -OwnPackagePrefixes @('org.wso2.carbon.apimgt.rest.api.publisher.v1.common', 'org.wso2.carbon.apimgt.rest.api.publisher.v1.dto')

# --- org.wso2.carbon.apimgt.rest.api.common: publisher-api.yaml (scopes + URL templates read at runtime
#     by RestApiCommonUtil for the new /operation-policies/test*, /definition endpoints and their scopes) ---
$commonYamlBundle = Get-ChildItem -LiteralPath (Join-Path $runtime 'repository\components\plugins') -Filter 'org.wso2.carbon.apimgt.rest.api.common_*.jar' |
    Select-Object -First 1 -ExpandProperty FullName
if (-not $commonYamlBundle) { throw 'Bundle not found: org.wso2.carbon.apimgt.rest.api.common_*.jar' }
$commonYamlBundle = Assert-InRuntime $commonYamlBundle
$yamlSrc = Join-Path $carbon 'org.wso2.carbon.apimgt.rest.api.common\target\classes\publisher-api.yaml'
if (!(Test-Path -LiteralPath $yamlSrc)) { throw "Compiled resource missing (build the module first): $yamlSrc" }

$yamlBundleLabel = Split-Path $commonYamlBundle -Leaf
$yamlBackupPath = Join-Path $BackupDir $yamlBundleLabel
if (!(Test-Path -LiteralPath $yamlBackupPath)) {
    Copy-Item -LiteralPath $commonYamlBundle -Destination $yamlBackupPath
    Write-Output "  Backed up original $yamlBundleLabel -> $yamlBackupPath"
}

$workYaml = Join-Path $env:TEMP ('cp-patch-yaml-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $workYaml | Out-Null
try {
    $unpackedYaml = Join-Path $workYaml 'unpacked'
    New-Item -ItemType Directory -Force -Path $unpackedYaml | Out-Null
    Push-Location $unpackedYaml
    try { & $jar xf $commonYamlBundle; if ($LASTEXITCODE -ne 0) { throw 'jar xf failed' } }
    finally { Pop-Location }
    Copy-Item -LiteralPath $yamlSrc -Destination (Join-Path $unpackedYaml 'publisher-api.yaml') -Force
    $manifestPathYaml = Join-Path $unpackedYaml 'META-INF\MANIFEST.MF'
    $patchedYaml = Join-Path $workYaml 'patched.jar'
    & $jar cfm $patchedYaml $manifestPathYaml -C $unpackedYaml .
    if ($LASTEXITCODE -ne 0) { throw 'jar cfm failed' }
    Copy-Item -LiteralPath $patchedYaml -Destination $commonYamlBundle -Force
    Write-Output "Patched $(Split-Path $commonYamlBundle -Leaf) with publisher-api.yaml"
} finally {
    $resolvedWorkYaml = [System.IO.Path]::GetFullPath($workYaml)
    if ($resolvedWorkYaml.StartsWith([System.IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase) `
            -and (Test-Path -LiteralPath $resolvedWorkYaml)) {
        Remove-Item -LiteralPath $resolvedWorkYaml -Recurse -Force
    }
}

# --- Publisher WAR: full replace (new endpoints, DTOs, impls) ---
$war = Join-Path $carbon 'org.wso2.carbon.apimgt.rest.api.publisher.v1\target\api#am#publisher.war'
if (!(Test-Path -LiteralPath $war)) { throw "Publisher WAR missing: $war" }
$warDest = Assert-InRuntime (Join-Path $runtime 'repository\deployment\server\webapps\api#am#publisher.war')
$expandedWar = Assert-InRuntime (Join-Path $runtime 'repository\deployment\server\webapps\api#am#publisher')
if (Test-Path -LiteralPath $expandedWar) { Remove-Item -LiteralPath $expandedWar -Recurse -Force }
Copy-Item -LiteralPath $war -Destination $warDest -Force
Write-Output 'Replaced api#am#publisher.war'

# --- OSGi bundle cache: must be cleared so the patched jars are re-read. Equinox otherwise trusts its
#     on-disk state cache (including cached manifest headers / resolved wiring) and ignores the fact
#     that a plugins/*.jar changed underneath it. ---
$cache = Assert-InRuntime (Join-Path $runtime 'repository\components\default\configuration\org.eclipse.osgi')
if (Test-Path -LiteralPath $cache) { Remove-Item -LiteralPath $cache -Recurse -Force }
Write-Output 'Cleared OSGi bundle cache (repository\components\default\configuration\org.eclipse.osgi) - Carbon regenerates it on next start.'

Write-Output 'Done. Start the Control Plane to pick up the patched classes.'
