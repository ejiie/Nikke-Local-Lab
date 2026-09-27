# Synthetic PowerShell executables only; no native asset, game, service or DB.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.BossNativeCandidate.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('nll-boss-native-test-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot
$count = 0
function Require-Test([bool]$Value) { if (-not $Value) { throw 'boss_native_test_failed' } }
function Hash-Test([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Write-Test([string]$Path, [object]$Value) {
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
}
function Case-Test([string]$Mode) {
    $caseRoot = Join-Path $testRoot ([guid]::NewGuid().ToString('N'))
    $candidate = Join-Path $caseRoot 'candidate'
    $fx = Join-Path $candidate 'shield-fx-candidate'
    $null = New-Item -ItemType Directory -Path $fx
    Write-Test (Join-Path $fx 'manifest.json') @{ synthetic = $true }
    $profilePath = Join-Path $candidate 'boss-runtime-variant.profile.json'
    Write-Test $profilePath @{ schemaVersion = 3; synthetic = $true }
    $seal = @{ contractId = 'nll/boss-onboarding-verified-candidate/v1'; affinityVariantCount = 5
        fiveAffinityVariantStatusCode = 'passed'; runtimeAdmissionStatusCode = 'not_assessed'; clientStarted = $false
        shieldFxCandidateManifestSha256 = Hash-Test (Join-Path $fx 'manifest.json'); profileSha256 = Hash-Test $profilePath }
    switch ($Mode) {
        'count' { $seal.affinityVariantCount = 4 }
        'variant' { $seal.fiveAffinityVariantStatusCode = 'failed' }
        'admitted' { $seal.runtimeAdmissionStatusCode = 'passed' }
        'client' { $seal.clientStarted = $true }
        'fx-drift' { $seal.shieldFxCandidateManifestSha256 = 'a' * 64 }
    }
    $sealPath = Join-Path $candidate 'onboarding-verified-candidate.receipt.json'
    Write-Test $sealPath $seal
    $python = Join-Path $caseRoot 'synthetic-python.ps1'
    $dotnet = Join-Path $caseRoot 'synthetic-dotnet.ps1'
    $script = @'
$global:LASTEXITCODE = 0
$mode = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'mode.txt'))
if ($args -contains '--fx-candidate-root') {
    if ($mode -eq 'export') { $global:LASTEXITCODE=1; return }
} elseif ($args -contains '--source-root') {
    if ($mode -eq 'layout') { $global:LASTEXITCODE=1; return }
} else { throw 'synthetic_arguments_invalid' }
$index = [Array]::IndexOf([object[]]$args, '--output-root')
$destination = $args[$index + 1]
$null = New-Item -ItemType Directory -Path $destination
[IO.File]::WriteAllText((Join-Path $destination 'receipt.json'), '{"synthetic":true}')
'@
    [IO.File]::WriteAllText($python, $script)
    $script = @'
$global:LASTEXITCODE = 0
$mode = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'mode.txt'))
if ($mode -eq 'chunks') { $global:LASTEXITCODE=1; return }
$destination = $args[-1]
$null = New-Item -ItemType Directory -Path $destination
$result = @{contractId='nll/native-fx-chunk-candidate/v1';statusCode='offline_chunk_candidate_verified';
 nativeClientExecuted=$false;installedFilesModified=$false;oldChunkDigestsMatch=$false;
 sourceFilesUnchanged=$true;runtimeAdmissionStatusCode='not_assessed'}
if ($mode -eq 'false-native-claim') {$result.nativeClientExecuted=$true}
if ($mode -eq 'false-integrity-claim') {$result.oldChunkDigestsMatch=$true}
if ($mode -eq 'source-changed') {$result.sourceFilesUnchanged=$false}
[IO.File]::WriteAllText((Join-Path $destination 'receipt.json'), ($result|ConvertTo-Json))
'@
    [IO.File]::WriteAllText($dotnet, $script)
    [IO.File]::WriteAllText((Join-Path $caseRoot 'mode.txt'), $Mode)
    $plan = Join-Path $caseRoot 'plan.json'
    $tool = Join-Path $caseRoot 'tool.synthetic.txt'
    Write-Test $plan @{ synthetic = $true }
    Write-Test $tool @{ synthetic = $true }
    $config = @{ inputPlanPath=$plan; inputPlanSha256=Hash-Test $plan; catalogToolPath=$tool; catalogToolSha256=Hash-Test $tool
        dotnetPath=$dotnet; dotnetSha256=Hash-Test $dotnet }
    if ($Mode -eq 'tool-drift') { $config.catalogToolSha256 = 'a'*64 }
    $originalPin = Hash-Test $sealPath
    $pin = if ($Mode -eq 'candidate-drift') { 'a'*64 } else { $originalPin }
    $pathBefore = $env:PATH
    $caught = $false
    try {
        $result = New-NllBossNativeCandidate -Configuration $config -JobRoot $caseRoot -CandidateRoot $candidate `
            -CandidateReceiptSha256 $pin -PythonPath $python -UnityPyRoot $caseRoot
        Require-Test ($Mode -eq 'success' -and $result.runtimeAdmissionStatusCode -eq 'not_assessed' -and
            -not $result.nativeClientExecuted -and $result.chunkReceiptSha256 -eq (Hash-Test (Join-Path $caseRoot 'native-chunks/receipt.json')))
    } catch {
        $caught = $true
        Require-Test ($_.Exception.Message -cmatch '^boss_native_[a-z_]+$' -and $_.Exception.Message -ne 'boss_native_test_failed')
    }
    Require-Test ($caught -eq ($Mode -ne 'success') -and $env:PATH -ceq $pathBefore -and (Hash-Test $sealPath) -eq $originalPin)
    $script:count++
}
try {
    foreach ($mode in @('success','count','variant','admitted','client','fx-drift','tool-drift','candidate-drift',
            'export','layout','chunks','false-native-claim','false-integrity-claim','source-changed')) { Case-Test $mode }
    Write-Output ('Boss native composition: {0} synthetic stage/failure/provenance/PATH restoration checks passed.' -f $count)
}
finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    Require-Test ([IO.Path]::GetDirectoryName($resolved) -ieq [IO.Path]::GetTempPath().TrimEnd('\','/') -and
        [IO.Path]::GetFileName($resolved).StartsWith('nll-boss-native-test-') -and
        ((Get-Item -LiteralPath $resolved).Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
