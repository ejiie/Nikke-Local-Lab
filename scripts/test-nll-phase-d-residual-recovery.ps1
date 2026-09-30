# Real identity publication with synthetic files/processes; never touches game/DB/hosts/firewall.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.PhaseDProcessIdentity.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('nll-residual-' + [guid]::NewGuid().ToString('D'))
$null = New-Item -ItemType Directory -Path (Join-Path $testRoot 'evidence\synthetic-run'),(Join-Path $testRoot 'runtime')
function Assert-Test([bool]$Value,[string]$Code) { if (-not $Value) { throw $Code } }
function Json([string]$Path,[object]$Value) { [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 8)) }
try {
    $identityPath = Join-Path $testRoot 'runtime-processes.identity.json'
    # Exercise the actual publication helper: client failure leaves the independent server pin durable.
    function New-PhaseDProcessIdentity {
        param($Id,$ExecutablePath,$NotBeforeUtc,$NotAfterUtc)
        if ($Id -eq 789) { throw 'synthetic_client_identity_denied' }
        [pscustomobject]@{ processId = $Id; processStartedAtUtc = '2026-09-07T01:00:00.0000000Z'; executablePath = $ExecutablePath }
    }
    $capture = [ordered]@{ server = $null; bootstrap = $null; client = $null }
    $captureFailure = $null
    try {
        Initialize-PhaseDProcessIdentitySet -Document $capture -Pointer ([pscustomobject]@{serverProcessId=123;bootstrapProcessId=456;clientProcessId=789}) `
            -ExecutablePaths @{server='C:\synthetic\server.exe';bootstrap='C:\synthetic\bootstrap.exe';client='C:\synthetic\client.exe'} `
            -NotBeforeUtc ([DateTime]::MinValue) -NotAfterUtc ([DateTime]::MaxValue) -Publish { param($value) Json $identityPath $value }
    } catch { $captureFailure = $_ }
    Assert-Test ($null -ne $captureFailure) 'expected_capture_failure_missing'
    $saved = Get-Content -LiteralPath $identityPath -Raw | ConvertFrom-Json
    Assert-Test ($saved.server.processId -eq 123 -and $saved.bootstrap.processId -eq 456 -and $null -eq $saved.client) 'partial_ownership_lost'
    Write-PhaseDFirstFailure -LaunchRoot $testRoot -Owner coordinator -Stage runtime_identity_capture -Failure $captureFailure
    $first = Get-Content -LiteralPath (Join-Path $testRoot 'coordinator-failure.detail.json') -Raw
    Assert-Test (($first | ConvertFrom-Json).failureCode -ceq 'synthetic_client_identity_denied') 'first_failure_lost'
    Assert-Test (($first | ConvertFrom-Json).processRole -ceq 'client') 'failure_role_missing'
    try { throw 'synthetic_cleanup_failure' } catch { Write-PhaseDFirstFailure -LaunchRoot $testRoot -Owner coordinator -Stage cleanup -Failure $_ }
    Assert-Test ((Get-Content -LiteralPath (Join-Path $testRoot 'coordinator-failure.detail.json') -Raw) -ceq $first) 'cleanup_overwrote_first_failure'
    try { throw 'synthetic_cleanup_failure' } catch { Write-PhaseDFirstFailure -LaunchRoot $testRoot -Owner coordinator -Stage rollback -CleanupStage rollback -Failure $_ }
    $secondaryPath = Join-Path $testRoot 'coordinator-cleanup-rollback-failure.detail.json'
    $secondary = Get-Content -LiteralPath $secondaryPath -Raw
    try { throw 'synthetic_replay_failure' } catch { Write-PhaseDFirstFailure -LaunchRoot $testRoot -Owner coordinator -Stage rollback -CleanupStage rollback -Failure $_ }
    Assert-Test ((Get-Content -LiteralPath $secondaryPath -Raw) -ceq $secondary) 'replay_overwrote_secondary_failure'
    Assert-Test ((Get-Content -LiteralPath (Join-Path $testRoot 'coordinator-failure.detail.json') -Raw) -ceq $first) 'secondary_overwrote_primary_failure'
    try { throw 'synthetic private password=do-not-log' } catch { Write-PhaseDFirstFailure -LaunchRoot $testRoot -Owner watcher -Stage completion -Failure $_ }
    Assert-Test (-not (Get-Content -LiteralPath (Join-Path $testRoot 'watcher-failure.detail.json') -Raw).Contains('do-not-log')) 'raw_exception_leaked'
}
finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\') -ine ([IO.Path]::GetTempPath()).TrimEnd('\') -or
        [IO.Path]::GetFileName($resolved) -notlike 'nll-residual-*') { throw 'unsafe_test_cleanup' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
'Phase D identity publication: partial capture and safe first-failure cases passed.'
