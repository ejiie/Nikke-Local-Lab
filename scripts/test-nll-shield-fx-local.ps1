[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BundlePath,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedBundleSha256,
    [Parameter(Mandatory)][string]$PythonPath,
    [Parameter(Mandatory)][string]$UnityPyRoot
)

# Offline only: original cache reads, new ignored candidate, candidate-only restore.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repository = Split-Path -Parent $PSScriptRoot
function Require([bool]$Value, [string]$Code) { if (-not $Value) { throw $Code } }
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
Require ((Hash $BundlePath) -ceq $ExpectedBundleSha256) 'shield_fx_local_bundle_drifted'
$bundle = Get-Content -LiteralPath $BundlePath -Raw | ConvertFrom-Json
Require ($bundle.contractId -ceq 'nll/phase-d-runtime-bundle/v1') 'shield_fx_local_bundle_invalid'
$cache = Join-Path ([IO.Path]::GetFullPath([string]$bundle.serverRoot)) 'cache'
Require (-not $cache.StartsWith('C:\NIKKE', [StringComparison]::OrdinalIgnoreCase)) 'shield_fx_local_official_path_rejected'
foreach ($pin in $bundle.files) {
    Require ((Hash $pin.path) -ceq $pin.sha256 -and
        (Get-Item -LiteralPath $pin.path).Length -eq $pin.length) 'shield_fx_local_bundle_file_drifted'
}
$outputRoot = Join-Path $repository ('artifacts\shield-fx-checks\' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $outputRoot
$candidate = Join-Path $outputRoot 'candidate'
$profile = Join-Path $repository 'config\boss-runtime-variants\season-29-mother-whale.json'
$profileHash = Hash $profile
$registry = Join-Path $repository 'config\boss-runtime-variants\registry.json'
$registryHash = Hash $registry
$tool = Join-Path $PSScriptRoot 'materialize-nll-shield-fx-candidate.py'
$receipt = [ordered]@{
    contractId = 'nll/boss-shield-fx-local-check/v1'; status = 'failed'
    bundleSha256 = $ExpectedBundleSha256; profileSha256 = $profileHash; candidateManifestSha256 = $null
    variantCount = 0; restoreChecks = 0; restoredCandidateRejected = $false
    originalClientExecuted = $false; operatingDatabaseTouched = $false; deployed = $false
    runtimeAdmissionStatusCode = 'not_assessed'
}
try {
    $lines = @(& $PythonPath -B $tool create --profile $profile --profile-sha256 $profileHash `
        --asset-cache-root $cache --output-root $candidate --unitypy-root $UnityPyRoot)
    Require ($LASTEXITCODE -eq 0 -and $lines.Count -eq 1) 'shield_fx_local_create_failed'
    $created = $lines[0] | ConvertFrom-Json
    Require ($created.statusCode -ceq 'isolated_candidate_verified' -and $created.variantCount -eq 3 -and
        $created.runtimeAdmissionStatusCode -ceq 'not_assessed') 'shield_fx_local_create_receipt_invalid'
    $receipt.candidateManifestSha256 = $created.manifestSha256
    $receipt.variantCount = $created.variantCount
    $lines = @(& $PythonPath -B $tool verify --candidate-root $candidate --manifest-sha256 $created.manifestSha256)
    Require ($LASTEXITCODE -eq 0 -and ($lines[0] | ConvertFrom-Json).statusCode -ceq 'isolated_candidate_verified') 'shield_fx_local_verify_failed'
    foreach ($attempt in @(1, 2)) {
        $lines = @(& $PythonPath -B $tool restore --candidate-root $candidate --manifest-sha256 $created.manifestSha256)
        Require ($LASTEXITCODE -eq 0 -and ($lines[0] | ConvertFrom-Json).statusCode -ceq 'candidate_restored') 'shield_fx_local_restore_failed'
        $receipt.restoreChecks++
    }
    $lines = @(& $PythonPath -B $tool verify --candidate-root $candidate --manifest-sha256 $created.manifestSha256 2>&1)
    Require ($LASTEXITCODE -eq 1 -and [string]$lines[0] -ceq 'shield_fx_candidate_overlay_drifted') 'shield_fx_local_restored_candidate_admitted'
    $receipt.restoredCandidateRejected = $true
    foreach ($pin in $bundle.files) {
        Require ((Hash $pin.path) -ceq $pin.sha256) 'shield_fx_local_bundle_file_changed'
    }
    Require ((Hash $BundlePath) -ceq $ExpectedBundleSha256 -and (Hash $profile) -ceq $profileHash -and
        (Hash $registry) -ceq $registryHash) 'shield_fx_local_configuration_changed'
    $receipt.status = 'passed'
} finally {
    $receiptPath = Join-Path $outputRoot 'receipt.json'
    [IO.File]::WriteAllText($receiptPath, (($receipt | ConvertTo-Json -Depth 8) + "`n"), [Text.UTF8Encoding]::new($false))
    Write-Output "Shield FX local receipt: $receiptPath"
}
