[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repository = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $repository
if (@(& git status --porcelain).Count -ne 0) { throw 'stabilization_verification_committed_source_required' }
$head = (& git rev-parse HEAD).Trim()
$uid = [guid]::NewGuid().ToString('N')
$result = Join-Path $repository ('artifacts/stabilization/final-verification/' + $uid)
$null = New-Item -ItemType Directory -Path $result
$checks = [Collections.Generic.List[object]]::new()
function Check([string]$Name, [string]$Executable, [string[]]$Arguments) {
    & $Executable @Arguments *> (Join-Path $result ($Name + '.log'))
    $code = $LASTEXITCODE
    $checks.Add([ordered]@{ name=$Name; exitCode=$code })
    Write-Output ($Name + ': ' + $code)
    if ($code -ne 0) { throw 'stabilization_verification_gate_failed' }
}
$passed = $false
try {
    Check 'repository' 'pwsh' @('-NoProfile','-File','scripts/verify-repository.ps1','-Mode','working','-AllowRemote')
    Check 'phase0' 'pwsh' @('-NoProfile','-File','scripts/verify-phase0-contract.ps1')
    Check 'phase3b1-chain' 'pwsh' @('-NoProfile','-File','scripts/verify-phase3b1.ps1')
    Check 'automation' 'dotnet' @('test','tests/NikkeLocalLab.Automation.UnitTests','-c','Release','--no-restore','--verbosity','minimal')
    Check 'phase3b2' 'pwsh' @('-NoProfile','-File','scripts/verify-phase3b2.ps1','-ContractOnly')
    Check 'weakness' 'pwsh' @('-NoProfile','-File','scripts/verify-automation-boss-weakness-variant.ps1')
    Check 'actions' 'pwsh' @('-NoProfile','-File','scripts/verify-actions-contract.ps1')
    Check 'desktop' 'dotnet' @('build','tools/NikkeLocalLab.ControlCenter.Desktop','-c','Release','--no-restore','--verbosity','minimal')
    Check 'release-behavior' 'pwsh' @('-NoProfile','-File','scripts/test-nll-stabilization-release.ps1')
    # Includes every PostgreSQL integration test, not a filter or an operational DB.
    Check 'postgresql' 'pwsh' @('-NoProfile','-File','scripts/test-nll-lifecycle-postgresql.ps1','-ShutdownTimeoutSeconds','60')
    if (@(& git status --porcelain).Count -ne 0 -or (& git rev-parse HEAD).Trim() -cne $head) { throw 'stabilization_verification_source_changed' }
    $passed = $true
}
finally {
    [ordered]@{
        contractId='nll/stabilization-verification/v1'; verificationUid=$uid; sourceHead=$head
        passed=$passed; checks=@($checks.ToArray()); completedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')
        originalClientExecuted=$false; operatingDatabaseUsed=$false
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $result 'receipt.json') -Encoding UTF8
    Write-Output ('Verification receipt: ' + $result)
}
