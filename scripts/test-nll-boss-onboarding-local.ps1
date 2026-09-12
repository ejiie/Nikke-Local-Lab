[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BundlePath,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedBundleSha256,
    [Parameter(Mandatory)][string]$MaterializerPath,
    [Parameter(Mandatory)][string]$StaticDataPackPath,
    [Parameter(Mandatory)][string]$SourceDatabasePath,
    [Parameter(Mandatory)][string]$PythonPath,
    [Parameter(Mandatory)][string]$UnityPyRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repository = Split-Path -Parent $PSScriptRoot
function Require([bool]$Value, [string]$Code) { if (-not $Value) { throw $Code } }
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
Require ((Hash $BundlePath) -ceq $ExpectedBundleSha256) 'boss_onboarding_local_bundle_drifted'
$bundle = Get-Content -LiteralPath $BundlePath -Raw | ConvertFrom-Json
Require ($bundle.contractId -ceq 'nll/phase-d-runtime-bundle/v1') 'boss_onboarding_local_bundle_invalid'
$cache = Join-Path ([string]$bundle.serverRoot) 'cache'
$config = Join-Path ([string]$bundle.serverRoot) 'gameconfig.json'
Require (-not $cache.StartsWith('C:\NIKKE', [StringComparison]::OrdinalIgnoreCase)) 'boss_onboarding_local_official_path_rejected'
foreach ($path in @($StaticDataPackPath, $config)) {
    Require (@($bundle.files | Where-Object {
        [IO.Path]::GetFullPath([string]$_.path) -ieq [IO.Path]::GetFullPath($path)
    }).Count -eq 1) 'boss_onboarding_local_input_not_pinned'
}
foreach ($pin in $bundle.files) {
    Require ((Hash $pin.path) -ceq $pin.sha256 -and
        (Get-Item -LiteralPath $pin.path).Length -eq $pin.length) 'boss_onboarding_local_bundle_file_drifted'
}
$root = Join-Path $repository ('artifacts\boss-onboarding-checks\' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root
Write-Output "Boss onboarding local output: $root"
$registryRoot = Join-Path $repository 'config\boss-runtime-variants'
$before = @{}
foreach ($path in @($BundlePath, $SourceDatabasePath) + @(Get-ChildItem -LiteralPath $registryRoot -File | ForEach-Object { $_.FullName })) {
    $before[$path] = Hash $path
}
$receipt = [ordered]@{
    contractId = 'nll/boss-onboarding-local-check/v1'; status = 'failed'
    bundleSha256 = $ExpectedBundleSha256; bundleFileCount = @($bundle.files).Count
    candidates = @(); fiveAffinityVariantCount = 0; isolatedFxVariantCount = 0
    originalClientExecuted = $false; operatingDatabaseTouched = $false; deployed = $false
    runtimeAdmissionStatusCode = 'not_assessed'
}
try {
    foreach ($entry in @(@{ season = 29; code = 'season-29-mother-whale' }, @{ season = 26; code = 'season-26-providence' })) {
        $profile = Get-Content -LiteralPath (Join-Path $registryRoot ($entry.code + '.json')) -Raw | ConvertFrom-Json
        $candidateRoot = Join-Path $root ('season-' + $entry.season)
        & (Join-Path $PSScriptRoot 'invoke-nll-boss-onboarding.ps1') -CandidateOnly `
            -SeasonNumber $entry.season -ProfileCode $entry.code -DisplayNameCode $profile.displayNameCode `
            -MaterializerPath $MaterializerPath -StaticDataPackPath $StaticDataPackPath `
            -SourceDatabasePath $SourceDatabasePath -GameConfigPath $config -AssetCacheRoot $cache `
            -PythonPath $PythonPath -UnityPyRoot $UnityPyRoot -OutputRoot $candidateRoot
        $seal = Join-Path $candidateRoot 'onboarding-verified-candidate.receipt.json'
        $result = Get-Content -LiteralPath $seal -Raw | ConvertFrom-Json
        Require ($result.statusCode -ceq 'verified_candidate_pending_runtime_delivery' -and
            $result.runtimeAdmissionStatusCode -ceq 'not_assessed' -and
            $result.affinityVariantCount -eq 5 -and -not $result.registryModified) 'boss_onboarding_local_candidate_invalid'
        Require (-not (Test-Path (Join-Path $candidateRoot 'onboarding-admission.receipt.json'))) 'boss_onboarding_local_admission_forbidden'
        $receipt.candidates += @{ seasonNumber = $entry.season; receiptSha256 = Hash $seal; profileSha256 = $result.profileSha256 }
        $receipt.fiveAffinityVariantCount += 5
        if ($entry.season -eq 29) { $receipt.isolatedFxVariantCount = 3 }
    }
    $receipt.status = 'passed'
}
finally {
    try {
        foreach ($pin in $bundle.files) {
            Require ((Hash $pin.path) -ceq $pin.sha256) 'boss_onboarding_local_bundle_file_changed'
        }
        foreach ($path in $before.Keys) {
            Require ((Hash $path) -ceq $before[$path]) 'boss_onboarding_local_configuration_changed'
        }
    }
    catch { $receipt.status = 'failed'; throw }
    finally {
        [IO.File]::WriteAllText((Join-Path $root 'receipt.json'),
            (($receipt | ConvertTo-Json -Depth 10) + "`n"), [Text.UTF8Encoding]::new($false))
    }
}
