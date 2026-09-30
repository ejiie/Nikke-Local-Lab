param(
    [Parameter(Mandatory)][ValidateSet('start','completion')][string]$Phase,
    [Parameter(Mandatory)][string]$LaunchRoot,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedBundleSha256,
    [string]$ObservedStageCode = 'startup_only', [string]$OutcomeCode = 'client_exit'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# Bootstrap trust before importing even the seal verifier. The coordinator/watcher
# pass the pinned hash, never a version selected afresh from current configuration.
$manifestPath = Join-Path $PSScriptRoot 'runner.bundle.json'
if ((Get-FileHash -LiteralPath $manifestPath).Hash.ToLowerInvariant() -cne $ExpectedBundleSha256) { throw 'phase_d_runner_bundle_invalid' }
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$seal = @($manifest.members | Where-Object { $_.name -ceq 'Nll.PhaseDRunnerSeal.ps1' })
$sealPath = Join-Path $PSScriptRoot 'Nll.PhaseDRunnerSeal.ps1'
if ($seal.Count -ne 1 -or (Get-FileHash -LiteralPath $sealPath).Hash.ToLowerInvariant() -cne $seal[0].sha256) { throw 'phase_d_runner_bundle_invalid' }
. $sealPath
$bundle = Read-PhaseDRunnerBundle -LaunchRoot $LaunchRoot -ExpectedBundleSha256 $ExpectedBundleSha256
if ([IO.Path]::GetFullPath($bundle.root) -ine [IO.Path]::GetFullPath($PSScriptRoot)) { throw 'phase_d_runner_bundle_invalid' }
. (Join-Path $PSScriptRoot 'Nll.PhaseDRunnerContract.ps1')
Assert-PhaseDRunnerSpecification $bundle.specification
$script:PhaseDVerifiedRunnerBundle = $bundle
. (Join-Path $PSScriptRoot 'Nll.PhaseDProcessIdentity.ps1')
. (Join-Path $PSScriptRoot 'Nll.PhaseDJob.ps1')
if ($Phase -ceq 'start') { Assert-PhaseDJobMember $LaunchRoot $ExpectedBundleSha256 }
. (Join-Path $PSScriptRoot 'Nll.PhaseDRunnerOperations.ps1')
if ($Phase -ceq 'start') {
    Assert-PhaseDRunnerStartDependencies $bundle.specification
    . (Join-Path $PSScriptRoot 'Nll.PhaseDRunnerStart.ps1')
    Invoke-PhaseDRunnerStart $bundle.specification
} else {
    . (Join-Path $PSScriptRoot 'Nll.PhaseDRunnerComplete.ps1')
    Invoke-PhaseDWithJobZeroProof $LaunchRoot $ExpectedBundleSha256 {
        Invoke-PhaseDRunnerComplete $bundle.specification -ObservedStageCode $ObservedStageCode -OutcomeCode $OutcomeCode
    }
}
