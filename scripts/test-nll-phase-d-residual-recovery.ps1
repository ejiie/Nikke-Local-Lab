# Real recovery helpers with synthetic files/processes; never touches game/DB/hosts/firewall.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.PhaseDProcessIdentity.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('nll-residual-' + [guid]::NewGuid().ToString('D'))
$null = New-Item -ItemType Directory -Path (Join-Path $testRoot 'evidence\synthetic-run'),(Join-Path $testRoot 'runtime')
$script:kills = 0
$script:clientLive = $false
$script:extraServer = $false
$script:shiftedStart = $false
function Assert-Test([bool]$Value,[string]$Code) { if (-not $Value) { throw $Code } }
function Fake-Process([int]$Id) {
    $p = [pscustomobject]@{ Id = $Id; Path = (Join-Path $testRoot 'runtime\EpinelPS.exe'); StartTime = [DateTime]::Parse('2026-09-07T01:00:00Z').ToUniversalTime().AddSeconds([int]$script:shiftedStart); HasExited = $false }
    $p | Add-Member ScriptMethod Dispose { }
    $p | Add-Member ScriptMethod get_Path { $this.Path }
    $p | Add-Member ScriptMethod Kill { $script:kills++ }
    $p | Add-Member ScriptMethod WaitForExit { param($Milliseconds) $true }
    $p
}
function Get-Process {
    param($Name,$Id,$ErrorAction)
    if ($null -ne $Id) { return (Fake-Process $Id) }
    if ('EpinelPS' -in $Name) { Fake-Process 123; if ($script:extraServer) { Fake-Process 456 } }
    elseif ($script:clientLive) { Fake-Process 789 }
}
function Open-PhaseDProcess { param([int]$Id,[switch]$ForTermination) Fake-Process $Id }
function Json([string]$Path,[object]$Value) { [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 8)) }
function Reject([scriptblock]$Action) {
    $before = $script:kills
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert-Test ($rejected -and $script:kills -eq $before) 'unproven_process_was_stopped'
}
try {
    $runRoot = Join-Path $testRoot 'evidence\synthetic-run'
    $receiptPath = Join-Path $runRoot 'run-start.receipt.json'
    [IO.File]::WriteAllText($receiptPath,'synthetic-start-receipt')
    $pointer = [pscustomobject]@{ contractId = 'nll/phase3b2-epinel-minimal-active-run-pointer/v1'; runRoot = $runRoot; serverProcessId = 123 }
    Json (Join-Path $testRoot 'evidence\active-run.pointer.json') $pointer
    $identityPath = Join-Path $testRoot 'runtime-processes.identity.json'
    $document = [ordered]@{
        schemaVersion = 1; contractId = 'nll/phase-d-runtime-process-identities/v1'; launchContextUid = (Split-Path -Leaf $testRoot)
        startReceiptSha256 = (Get-FileHash -LiteralPath $receiptPath).Hash.ToLowerInvariant()
        client = $null; bootstrap = $null
        server = [pscustomobject]@{ processId = 123; processStartedAtUtc = '2026-09-07T01:00:00.0000000Z'; executablePath = (Join-Path $testRoot 'runtime\EpinelPS.exe') }
    }
    Json $identityPath $document
    Assert-Test (Stop-PhaseDResidualServer $testRoot) 'owned_residual_not_stopped'
    Assert-Test ($script:kills -eq 1) 'owned_residual_stop_count_invalid'
    $script:clientLive = $true; Reject { Stop-PhaseDResidualServer $testRoot }; $script:clientLive = $false
    $script:extraServer = $true; Reject { Stop-PhaseDResidualServer $testRoot }; $script:extraServer = $false
    $script:shiftedStart = $true; Reject { Stop-PhaseDResidualServer $testRoot }; $script:shiftedStart = $false
    $document.server.processId = 456; Json $identityPath $document; Reject { Stop-PhaseDResidualServer $testRoot }
    $document.server.processId = 123
    $document.server.executablePath = 'C:\synthetic\other.exe'; Json $identityPath $document; Reject { Stop-PhaseDResidualServer $testRoot }
    $document.server.executablePath = Join-Path $testRoot 'runtime\EpinelPS.exe'
    $document.startReceiptSha256 = 'wrong-receipt'; Json $identityPath $document; Reject { Stop-PhaseDResidualServer $testRoot }
    Remove-Item -LiteralPath $identityPath
    Reject { Stop-PhaseDResidualServer $testRoot }

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
'Phase D residual recovery: ownership, live-client exclusion, PID reuse, partial capture and safe first-failure cases passed.'
