[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigurationPath,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedConfigurationSha256,
    [Parameter(Mandatory)][string]$JobRoot
)
# Offline worker only. No game/server startup, UAC, service/firewall/driver calls,
# operating DB connection, native patch or live resource download exists here.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Require([bool]$Value, [string]$Code) { if (-not $Value) { throw ('boss_pipeline_' + $Code) } }
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Plain([string]$Path) {
    Require ([IO.Path]::IsPathFullyQualified($Path) -and -not $Path.StartsWith('\\')) 'path_invalid'
    $resolved = [IO.Path]::GetFullPath($Path)
    Require (-not $resolved.Substring([IO.Path]::GetPathRoot($resolved).Length).Contains(':')) 'path_invalid'
    for ($cursor = $resolved; $cursor; $cursor = [IO.Path]::GetDirectoryName($cursor)) {
        if (Test-Path -LiteralPath $cursor) {
            Require (((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'reparse_forbidden'
        }
    }
    $resolved
}
Require ($PSVersionTable.PSVersion.Major -ge 7) 'powershell7_required'
$ConfigurationPath = Plain $ConfigurationPath
$JobRoot = Plain $JobRoot
Require ((Get-Item -LiteralPath $ConfigurationPath).Length -le 1048576 -and
    (Hash $ConfigurationPath) -ceq $ExpectedConfigurationSha256) 'configuration_drifted'
$config = Get-Content -LiteralPath $ConfigurationPath -Raw -Encoding UTF8 | ConvertFrom-Json
Require ($config.schemaVersion -eq 1 -and $config.contractId -ceq 'nll/boss-pipeline-config/v1') 'configuration_invalid'
$repository = Plain ([string]$config.repositoryRoot)
$scriptRoot = Join-Path $repository 'scripts'
Require ([IO.Path]::GetFullPath($PSScriptRoot) -ieq [IO.Path]::GetFullPath($scriptRoot)) 'worker_path_invalid'
$pins = @{}
foreach ($pin in @($config.inputPins)) {
    $path = Plain ([string]$pin.path)
    Require (-not $pins.ContainsKey($path) -and [string]$pin.sha256 -cmatch '^[a-f0-9]{64}$') 'pin_invalid'
    Require (-not ($path -imatch '^C:[\\/]NIKKE([\\/]|$)')) 'official_input_forbidden'
    $pins[$path] = [string]$pin.sha256
}
function Verify-Pins {
    Require ((Hash $ConfigurationPath) -ceq $ExpectedConfigurationSha256) 'configuration_drifted'
    foreach ($path in $pins.Keys) { $null = Plain $path; Require ((Hash $path) -ceq $pins[$path]) 'input_drifted' }
}
$required = @($PSCommandPath, [string]$config.materializerPath, [string]$config.pythonPath,
    [string]$config.staticDataPackPath, [string]$config.gameConfigPath, [string]$config.sourceDatabasePath,
    [string]$config.catalogPath)
$required += @('invoke-nll-boss-onboarding.ps1', 'Nll.BossPublication.ps1', 'inspect-nll-boss-behavior-assets.py',
    'materialize-nll-boss-runtime-profile.py', 'materialize-nll-shield-fx-candidate.py',
    'materialize-nll-shield-fx-transform-variant.py', 'verify-nll-boss-onboarding-candidate.py') | ForEach-Object { Join-Path $scriptRoot $_ }
foreach ($path in $required) { Require ($pins.ContainsKey((Plain $path))) 'required_pin_missing' }
Verify-Pins
$requestPath = Join-Path $JobRoot 'request.json'
Require ((Get-Item -LiteralPath $requestPath).Length -le 16384) 'request_invalid'
$requestHash = Hash $requestPath
$request = Get-Content -LiteralPath $requestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$jobUid = [guid]::ParseExact([string]$request.jobUid, 'D')
$jobsRoot = Plain ([string]$config.jobsRoot)
$expectedOutput = Join-Path (Join-Path $jobsRoot $jobUid.ToString('D')) 'output'
Require ($JobRoot -ieq $expectedOutput -and $jobUid -ne [guid]::Empty -and
    $request.schemaVersion -eq 1 -and $request.contractId -ceq 'nll/boss-onboarding-job/v1' -and
    $request.statusCode -ceq 'running' -and $request.seasonNumber -ge 1 -and $request.seasonNumber -le 1000 -and
    $request.catalogSha256 -ceq $config.catalogSha256 -and
    (Hash $config.catalogPath) -ceq $config.catalogSha256) 'request_invalid'
$catalog = Get-Content -LiteralPath $config.catalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
Require ($catalog.contractId -ceq 'nll/boss-season-catalog/v1' -and
    $catalog.sourceStaticDataSha256 -ceq $pins[(Plain $config.staticDataPackPath)]) 'catalog_binding_invalid'
$selected = @($catalog.seasons | Where-Object { $_.seasonNumber -eq $request.seasonNumber })
Require ($selected.Count -eq 1 -and $selected[0].discoveryStatusCode -ceq 'resolved') 'season_unresolved'
$registryRoot = Plain ([string]$config.registryRoot)
Require ($registryRoot -ieq (Join-Path $repository 'config\boss-runtime-variants')) 'registry_scope_invalid'
foreach ($boundary in @($registryRoot, [string]$config.assetCacheRoot, [string]$config.unityPyRoot,
        (Split-Path -Parent $config.staticDataPackPath), (Split-Path -Parent $config.sourceDatabasePath))) {
    $boundary = (Plain $boundary).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $outputPrefix = $JobRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    Require (-not $outputPrefix.StartsWith($boundary, [StringComparison]::OrdinalIgnoreCase) -and
        -not $boundary.StartsWith($outputPrefix, [StringComparison]::OrdinalIgnoreCase)) 'output_overlaps_input'
}
$registryPath = Join-Path $registryRoot 'registry.json'
$registryHash = Hash $registryPath
$registry = Get-Content -LiteralPath $registryPath -Raw -Encoding UTF8 | ConvertFrom-Json
$registered = @($registry.profiles | Where-Object { $_.seasonNumber -eq $request.seasonNumber })
Require ($registered.Count -le 1) 'registry_ambiguous'
$profileCode = if ($registered.Count) { [string]$registered[0].profileCode } else { 'season-' + $request.seasonNumber + '-boss' }
Require ($profileCode -cmatch '^[a-z][a-z0-9._-]{0,63}$') 'profile_code_invalid'
$displayNameCode = $profileCode
if ($registered.Count) {
    $relative = [string]$registered[0].profileRelativePath
    Require ($relative -cmatch '^[a-z][a-z0-9._-]{0,140}\.json$') 'registry_profile_path_invalid'
    $existingPath = Plain (Join-Path $registryRoot $relative)
    # A drifted/draft profile remains inadmissible, but does not prevent NEW
    # discovery. Never read its metadata as authoritative or repair the old pin.
    if ((Test-Path -LiteralPath $existingPath -PathType Leaf) -and (Hash $existingPath) -ceq $registered[0].profileSha256) {
        $existingProfile = Get-Content -LiteralPath $existingPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Require ($existingProfile.seasonNumber -eq $request.seasonNumber -and $existingProfile.profileCode -ceq $profileCode) 'registry_profile_binding_invalid'
        $displayNameCode = [string]$existingProfile.displayNameCode
        Require ($displayNameCode -cmatch '^[a-z][a-z0-9._-]{0,63}$') 'display_name_code_invalid'
    }
}
$candidateRoot = Join-Path $JobRoot 'candidate'
& (Join-Path $scriptRoot 'invoke-nll-boss-onboarding.ps1') -CandidateOnly -SeasonNumber $request.seasonNumber `
    -ProfileCode $profileCode -DisplayNameCode $displayNameCode -MaterializerPath $config.materializerPath `
    -StaticDataPackPath $config.staticDataPackPath -GameConfigPath $config.gameConfigPath `
    -SourceDatabasePath $config.sourceDatabasePath -AssetCacheRoot $config.assetCacheRoot `
    -PythonPath $config.pythonPath -UnityPyRoot $config.unityPyRoot -OutputRoot $candidateRoot -RegistryRoot $registryRoot | Out-Null
Verify-Pins
Require ((Hash $requestPath) -ceq $requestHash) 'request_drifted'
$sealPath = Join-Path $candidateRoot 'onboarding-verified-candidate.receipt.json'
$seal = Get-Content -LiteralPath $sealPath -Raw -Encoding UTF8 | ConvertFrom-Json
Require ($seal.contractId -ceq 'nll/boss-onboarding-verified-candidate/v1' -and
    $seal.seasonNumber -eq $request.seasonNumber -and $seal.profileCode -ceq $profileCode -and
    $seal.affinityVariantCount -eq 5 -and $seal.runtimeAdmissionStatusCode -ceq 'not_assessed') 'candidate_invalid'
$profilePath = Join-Path $candidateRoot 'boss-runtime-variant.profile.json'
$profile = Get-Content -LiteralPath $profilePath -Raw -Encoding UTF8 | ConvertFrom-Json
$status = 'awaiting_runtime_delivery'
$admissionHash = $null
$nativePackageHash = $null
if ($profile.schemaVersion -eq 3 -and $config.PSObject.Properties.Name -contains 'nativePipeline' -and $null -ne $config.nativePipeline) {
    $nativeHelper = Join-Path $scriptRoot 'Nll.BossNativeCandidate.ps1'
    foreach ($path in @($nativeHelper, $config.nativePipeline.inputPlanPath, $config.nativePipeline.catalogToolPath,
            $config.nativePipeline.dotnetPath, (Join-Path $scriptRoot 'stage-nll-native-fx.py'),
            (Join-Path $scriptRoot 'materialize-nll-native-fx-layout.py'))) {
        Require ($pins.ContainsKey((Plain $path))) 'native_pin_missing'
    }
    Verify-Pins
    . $nativeHelper
    $native = New-NllBossNativeCandidate -Configuration $config.nativePipeline -JobRoot $JobRoot `
        -CandidateRoot $candidateRoot -CandidateReceiptSha256 (Hash $sealPath) `
        -PythonPath $config.pythonPath -UnityPyRoot $config.unityPyRoot
    $nativePackageHash = $native.chunkReceiptSha256
    Verify-Pins
}
if ($profile.schemaVersion -eq 2 -and $config.allowLegacyPublication -eq $true) {
    $validationLines = @(& $config.materializerPath --validate-boss-variant-profile $profilePath)
    Require ($LASTEXITCODE -eq 0 -and $validationLines.Count -gt 0) 'validation_failed'
    $validation = $validationLines[-1] | ConvertFrom-Json
    $artifactPins = @{}
    foreach ($artifact in $seal.artifacts) {
        $path = Plain (Join-Path $candidateRoot ([string]$artifact.relativePath))
        Require ($path.StartsWith($candidateRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) 'artifact_path_invalid'
        $artifactPins[$path] = [string]$artifact.sha256
    }
    $variants = @('fire', 'water', 'wind', 'electric', 'iron') | ForEach-Object {
        $path = Join-Path $candidateRoot ('five-affinity-variants/' + $_ + '.receipt.json')
        $row = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        [ordered]@{ weaknessCode = $_; targetBossElementCode = $row.targetBossElementCode; variantRequired = $row.variantRequired
            modifiedMonsterRecordCount = $row.modifiedMonsterRecordCount; modifiedFunctionRecordCount = $row.modifiedFunctionRecordCount
            receiptSha256 = Hash $path }
    }
    Verify-Pins
    . (Join-Path $scriptRoot 'Nll.BossPublication.ps1')
    $admissionPath = Join-Path $candidateRoot 'onboarding-admission.receipt.json'
    Publish-NllBossProfile -ProfilePath $profilePath -Validation $validation -VariantReceipts @($variants) `
        -ArtifactPins $artifactPins -RegistryRoot $registryRoot -ExpectedRegistrySha256 $registryHash `
        -AdmissionReceiptPath $admissionPath -ReplaceExistingProfile:($registered.Count -eq 1) | Out-Null
    $admissionHash = Hash $admissionPath
    $status = 'completed'
}
# v3 never reaches a legacy publisher. Native delivery and the operator's actual
# game validation have separate gates; generating a candidate is not completion.
$result = [ordered]@{ schemaVersion = 1; contractId = 'nll/boss-pipeline-result/v1'; jobUid = $jobUid.ToString('D')
    seasonNumber = $request.seasonNumber; catalogSha256 = $request.catalogSha256; statusCode = $status
    candidateReceiptSha256 = Hash $sealPath; admissionReceiptSha256 = $admissionHash
    nativeChunkReceiptSha256 = $nativePackageHash; nativeClientExecuted = $false }
$stream = [IO.File]::Open((Join-Path $JobRoot 'pipeline-result.json'), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try { $stream.Write([Text.Encoding]::UTF8.GetBytes(($result | ConvertTo-Json -Depth 8) + "`n")); $stream.Flush($true) }
finally { $stream.Dispose() }
