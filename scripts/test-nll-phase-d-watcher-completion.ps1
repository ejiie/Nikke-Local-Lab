# Run the actual watcher's outer try/catch, using synthetic files and service
# boundaries. This checks ordering; it is not original-game or database evidence.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$sealedRunner = $null # Legacy fixture; sealed-route cases are below.
$executionJob = $null
$jobRequired = $false
$physicalCleanupCommitted = $false
. (Join-Path $PSScriptRoot 'Nll.PhaseDProcessIdentity.ps1')
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot 'watch-nll-phase-d-execution.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw 'watcher_parse_failed' }
$outerTry = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })[-1]
$action = [scriptblock]::Create($outerTry.Extent.Text)
$taskRoot = Join-Path ([IO.Path]::GetTempPath()) ('nll-watcher-completion-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $taskRoot
function Assert-Watcher([bool]$Condition, [string]$Code) { if (-not $Condition) { throw $Code } }
function Get-Sha256Lower { 'synthetic-hash' }
function Read-PhaseDRunnerBundle { param($LaunchRoot,$ExpectedBundleSha256) @{sha256=$ExpectedBundleSha256} }
function Write-AtomicJson($Path, $Value) {
    if ($Path -ceq $statePath -and $Value.statusCode -ceq 'completed') {
        Assert-Watcher $script:persisted 'terminal_state_before_persistence'
    }
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 8))
}
function Get-PhaseDVerifiedProcess {
    param($Identity)
    if ($case -eq 'early-exit') { return $null }
    $p = [pscustomobject]@{}
    $p | Add-Member ScriptMethod WaitForExit { $script:waited = $true }
    $p | Add-Member ScriptMethod Dispose { $script:disposed = $true }
    $p
}
function Invoke-PhaseDChildScript {
    param($ScriptPath, $Arguments, $StandardOutputPath, $StandardErrorPath)
    Assert-Watcher ($Arguments.OutcomeCode -ceq 'client_exit' -and $Arguments.ObservedStageCode -ceq 'startup_only') 'automatic_exit_claimed_gameplay'
    if ($null -ne $sealedRunner) {
        Assert-Watcher ($Arguments.Phase -ceq 'completion' -and $Arguments.ExpectedBundleSha256 -ceq $ExpectedRunnerBundleSha256 -and
            $Arguments.LaunchRoot -ceq $LaunchRoot) 'watcher_changed_runner_binding'
    } else { Assert-Watcher ($Arguments.ServerRoot -ceq $ServerRoot -and $Arguments.EvidenceRoot -ceq $EvidenceRoot) 'watcher_changed_legacy_binding' }
    Assert-Watcher ($case -eq 'early-exit' -or ($script:waited -and $script:disposed)) 'completion_before_client_exit'
    if ($jobRequired) { Assert-Watcher ($script:jobOrder -ceq 'zero,redact,fx') 'completion_before_job_cleanup'; $script:jobOrder+=',completion' }
    [IO.File]::WriteAllText((Join-Path $EvidenceRoot 'active-run.pointer.archived.json'), 'synthetic-archived')
    [IO.File]::WriteAllText((Join-Path $EvidenceRoot 'completion.receipt.json'), '{"diagnosticObservationStatus":"not_observed"}')
    [IO.File]::WriteAllText($SoloRaidPendingPayloadPath, 'synthetic-pending')
    [pscustomobject]@{ ExitCode = 0; StandardOutput = '{}' }
}
function Restore-ControlCenterHosts { $script:hostsRestored = $true }
function Invoke-PhaseDPgCtl {
    param($PgCtlPath, $Arguments)
    Assert-Watcher $script:hostsRestored 'database_start_before_hosts_restore'
    if ($case -eq 'pg-failure') { return 1 }
    $script:databaseReady = $true
    return 0
}
function Invoke-SoloRaidPersistence {
    param($LaunchContextUid)
    Assert-Watcher ($script:databaseReady -and (Test-Path -LiteralPath $SoloRaidPendingPayloadPath)) 'persistence_without_ready_database_or_pending'
    if ($jobRequired) { Assert-Watcher ($script:jobOrder -ceq 'zero,redact,fx,completion') 'persistence_before_job_completion' }
    $current = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    Assert-Watcher ($current.statusCode -ceq 'started') 'state_released_before_replay'
    if ($case -eq 'persist-failure') { throw 'phase_d_synthetic_persist_failed' }
    $script:persisted = $true
    [pscustomobject]@{ resultCode = 'state_unchanged' }
}
function Invoke-EmergencyRollback { throw 'unexpected_emergency_rollback' }
function Stop-PhaseDExecutionJob { $script:jobOrder='zero' }
function Protect-PhaseDJobServerLog { $script:jobOrder+=',redact' }
function Invoke-PhaseDExecutionFxCleanup { Assert-Watcher ($script:jobOrder -ceq 'zero,redact') 'fx_before_job_zero'; $script:jobOrder+=',fx' }
function Write-PhaseDPhysicalCleanupCheckpoint { Assert-Watcher ($script:jobOrder -ceq 'zero,redact,fx,completion') 'checkpoint_before_physical_completion'; $script:checkpointWritten=$true }
function Assert-PhaseDChildrenExited { }
try {
  foreach ($engine in @('legacy','sealed','job')) {
    $sealedRunner=if ($engine -ne 'legacy') { @{sha256=('a'*64)} } else { $null }
    $jobRequired=$engine -eq 'job'
    $ExpectedRunnerBundleSha256='a'*64
    foreach ($case in @('early-exit', 'normal-exit', 'pg-failure', 'persist-failure')) {
        $physicalCleanupCommitted=$false
        $script:checkpointWritten=$false
        $LaunchRoot = Join-Path $taskRoot ($engine+'-'+$case)
        $EvidenceRoot = Join-Path $LaunchRoot 'evidence'
        $null = New-Item -ItemType Directory -Path $EvidenceRoot
        $ServerRoot = Join-Path $LaunchRoot 'runtime'
        $CompletionScriptPath = Join-Path $LaunchRoot 'never-executed.ps1'
        $launchContextUid = $case; $StartReceiptSha256 = 'synthetic-start'; $ClientProcessId = 123
        $statePath = Join-Path $LaunchRoot 'execution-state.json'
        $contextPath = Join-Path $LaunchRoot 'launch-context.json'
        $watcherLogPath = Join-Path $LaunchRoot 'completion-watcher.log'
        $SoloRaidPendingPayloadPath = Join-Path $LaunchRoot 'payload.pending.json'
        $SoloRaidCaptureReceiptPath = Join-Path $LaunchRoot 'capture.receipt.json'
        $ControlCenterHostsBackupPath = Join-Path $LaunchRoot 'synthetic-hosts.before'
        $ControlCenterHostsOriginalSha256 = 'synthetic-hash'
        $ControlCenterPgCtlPath = 'synthetic-pgctl'; $ControlCenterPgDataPath = 'synthetic-data'; $ControlCenterPgLogPath = 'synthetic-log'
        $databaseRestarted = $false; $controlCenterHostsRestored = $false; $completionApplied = $false; $raidStatePersisted = $false
        $script:waited = $false; $script:disposed = $false; $script:persisted = $false; $script:databaseReady = $false; $script:hostsRestored = $false
        [IO.File]::WriteAllText($ControlCenterHostsBackupPath, 'synthetic-hosts')
        Write-AtomicJson (Join-Path $LaunchRoot 'runtime-processes.identity.json') ([ordered]@{
            schemaVersion = 1; contractId = 'nll/phase-d-runtime-process-identities/v1'
            launchContextUid = $case; startReceiptSha256 = $StartReceiptSha256; client = @{processId = 123}
        })
        Write-AtomicJson $statePath ([ordered]@{
            statusCode = 'started'; clientProcessId = 123; watcherProcessId = 456; watcherProcessStartedAtUtc = 'synthetic'
            startReceiptSha256 = $null; completionReceiptSha256 = $null; failureCode = $null; updatedAtUtc = $null
        })
        Write-AtomicJson $contextPath @{statusCode = 'started'}
        & $action
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        $context = Get-Content -LiteralPath $contextPath -Raw | ConvertFrom-Json
        $success = $case -in @('early-exit','normal-exit')
        $expectedStatus = if ($success) { 'completed' } else { 'started' }
        Assert-Watcher ($state.statusCode -ceq $expectedStatus -and $context.statusCode -ceq $expectedStatus) 'watcher_completion_state_invalid'
        Assert-Watcher ((Test-Path -LiteralPath $SoloRaidPendingPayloadPath) -eq (-not $success)) 'pending_deleted_before_acknowledgement'
        Assert-Watcher ($null -eq $state.clientProcessId -and $null -eq $state.watcherProcessId) 'exited_process_indicator_not_cleared'
        if ($success) { Assert-Watcher ($null -eq $state.failureCode -and $script:databaseReady -and $script:persisted) 'completed_without_database_or_acknowledgement' }
        else { Assert-Watcher ($null -ne $state.failureCode) 'failure_not_reconcilable' }
    }
  }
}
finally {
    $resolved = [IO.Path]::GetFullPath($taskRoot)
    if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\') -ine ([IO.Path]::GetTempPath()).TrimEnd('\') -or
        [IO.Path]::GetFileName($resolved) -notlike 'nll-watcher-completion-*') { throw 'unsafe_test_cleanup' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
'Phase D watcher: early/normal exit, database failure and persistence failure ordering passed; synthetic resources only.'
