# Run the actual watcher's outer try/catch, using synthetic files and service
# boundaries. This checks ordering; it is not original-game or database evidence.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$executionJob = $null
$physicalCleanupCommitted = $false
. (Join-Path $PSScriptRoot 'Nll.PhaseDProcessIdentity.ps1')
. (Join-Path $PSScriptRoot 'Nll.PhaseDRunnerSeal.ps1')
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
        Assert-Watcher (Test-Path -LiteralPath $SoloRaidPendingPayloadPath) 'pending_deleted_before_terminal_state'
    }
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 8))
}
function Get-PhaseDVerifiedProcess {
    param($Identity)
    if ($case -eq 'identity-failure' -or ($case -eq 'reused-server' -and $Identity.processId -eq 124 -and $script:queries -gt 0)) {
        throw 'synthetic_identity_mismatch'
    }
    if ($case -eq 'early-exit' -or ($case -eq 'server-exited' -and $Identity.processId -eq 124)) { return $null }
    $p = [pscustomobject]@{ roleId=$Identity.processId; HasExited=$false }
    $script:opened++
    $p | Add-Member ScriptMethod WaitForExit {
        param($Milliseconds)
        if ($this.roleId -ne 123) { throw 'waited_on_wrong_process' }
        if ($Milliseconds -eq 0) { return ($case -eq 'exit-before-sample') }
        Assert-Watcher ($Milliseconds -eq 30000) 'unexpected_sampling_interval'
        $script:waitCount++
        $script:waited=$true
        return ($case -notin @('long-run','reused-server','network-client','network-server','network-bootstrap') -or $script:waitCount -gt 1)
    }
    $p | Add-Member ScriptMethod Dispose { $script:closed++; if ($this.roleId -eq 123) { $script:disposed=$true } }
    $p
}
function Get-NetTCPConnection {
    param($ErrorAction)
    Assert-Watcher ($ErrorAction -ceq 'Stop') 'query_failure_would_be_hidden'
    $script:queries++
    if ($case -eq 'query-failure') { throw 'synthetic_tcp_query_failed' }
    # Ignore another process, incomplete connections, and both loopback families.
    [pscustomobject]@{OwningProcess=999;State='Established';RemoteAddress='192.0.2.1'}
    [pscustomobject]@{OwningProcess=123;State='SynSent';RemoteAddress='192.0.2.1'}
    [pscustomobject]@{OwningProcess=123;State='Established';RemoteAddress='127.0.0.1'}
    [pscustomobject]@{OwningProcess=125;State='Established';RemoteAddress='::1'}
    if ($case -eq 'server-exited') { [pscustomobject]@{OwningProcess=124;State='Established';RemoteAddress='192.0.2.1'} }
    if ($case -like 'network-*' -and $script:queries -eq 2) {
        $id=@{'network-client'=123;'network-server'=124;'network-bootstrap'=125}[$case]
        [pscustomobject]@{OwningProcess=$id;State='Established';RemoteAddress='192.0.2.1'}
    }
}
function Invoke-PhaseDChildScript {
    param($ScriptPath, $Arguments, $StandardOutputPath, $StandardErrorPath)
    Assert-Watcher ($Arguments.OutcomeCode -ceq 'client_exit' -and $Arguments.ObservedStageCode -ceq 'startup_only') 'automatic_exit_claimed_gameplay'
    Assert-Watcher ($Arguments.Phase -ceq 'completion' -and $Arguments.ExpectedBundleSha256 -ceq $ExpectedRunnerBundleSha256 -and
        $Arguments.LaunchRoot -ceq $LaunchRoot) 'watcher_changed_runner_binding'
    Assert-Watcher ($case -in @('early-exit','exit-before-sample') -or ($script:waited -and $script:disposed)) 'completion_before_client_exit'
 Assert-Watcher ($script:jobOrder -ceq 'zero,redact,fx') 'completion_before_job_cleanup'; $script:jobOrder+=',completion'
    [IO.File]::WriteAllText((Join-Path $EvidenceRoot 'active-run.pointer.archived.json'), 'synthetic-archived')
    [IO.File]::WriteAllText((Join-Path $EvidenceRoot 'completion.receipt.json'), '{"databaseRestored":true,"hostsRestored":true,"extensionFirewallRemoved":false}')
    [IO.File]::WriteAllText($SoloRaidPendingPayloadPath, 'synthetic-pending')
    [pscustomobject]@{ ExitCode = 0; StandardOutput = '{}' }
}
function Restore-ControlCenterHosts { $script:hostsRestored = $true }
function Ensure-PhaseDPostgresRunning {
    param($PgCtlPath, $DataPath, $LogPath, $OwnershipPath)
    Assert-Watcher $script:hostsRestored 'database_start_before_hosts_restore'
 Assert-Watcher $script:checkpointWritten 'database_start_before_cleanup_checkpoint'
    if ($case -eq 'pg-failure') { throw 'phase_d_control_center_database_restart_failed' }
    $script:databaseReady = $true
}
function Invoke-SoloRaidPersistence {
    param($LaunchContextUid)
    Assert-Watcher ($script:databaseReady -and (Test-Path -LiteralPath $SoloRaidPendingPayloadPath)) 'persistence_without_ready_database_or_pending'
 Assert-Watcher ($script:jobOrder -ceq 'zero,redact,fx,completion') 'persistence_before_job_completion'
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
function Write-PhaseDPhysicalCleanupCheckpoint {
    param($LaunchRoot,$ExpectedBundleSha256,$CompletionPath)
    Assert-Watcher ($script:jobOrder -ceq 'zero,redact,fx,completion') 'checkpoint_before_physical_completion'
    $receipt=Get-Content -LiteralPath $CompletionPath -Raw | ConvertFrom-Json
    Assert-Watcher (-not $receipt.extensionFirewallRemoved) 'child_claimed_firewall_cleanup'
    if($case -eq 'isolation-failure'){throw 'phase_d_shared_isolation_restore_failed'}
    $receipt.extensionFirewallRemoved=$true
    Write-AtomicJson $CompletionPath $receipt
    $script:checkpointWritten=$true
}
function Write-PhaseDRollbackCleanupCheckpoint { throw 'phase_d_shared_isolation_restore_failed' }
function Assert-PhaseDChildrenExited { }
try {
$ExpectedRunnerBundleSha256='a'*64
foreach ($case in @('early-exit', 'exit-before-sample', 'normal-exit', 'long-run', 'server-exited', 'pg-failure', 'persist-failure', 'isolation-failure', 'identity-failure', 'reused-server', 'network-client', 'network-server', 'network-bootstrap', 'query-failure')) {
    $script:queries=0; $script:waitCount=0; $script:opened=0; $script:closed=0; $script:jobOrder=''
    $physicalCleanupCommitted=$false
    $script:checkpointWritten=$false
    $LaunchRoot = Join-Path $taskRoot ('job-'+$case)
    $EvidenceRoot = Join-Path $LaunchRoot 'evidence'
    $null = New-Item -ItemType Directory -Path $EvidenceRoot
    $runRoot=Join-Path $EvidenceRoot 'synthetic-run'
    $null=New-Item -ItemType Directory -Path $runRoot
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
    Write-AtomicJson (Join-Path $EvidenceRoot 'active-run.pointer.json') @{runRoot=$runRoot;runStartReceiptSha256=$StartReceiptSha256}
    Write-AtomicJson (Join-Path $LaunchRoot 'runtime-processes.identity.json') ([ordered]@{
        schemaVersion = 1; contractId = 'nll/phase-d-runtime-process-identities/v1'
        launchContextUid = $case; startReceiptSha256 = $StartReceiptSha256; client = @{processId = 123}; server = @{processId = 124}; bootstrap = @{processId = 125}
    })
    Write-AtomicJson $statePath ([ordered]@{
        createdAtUtc = [DateTimeOffset]::UtcNow.AddSeconds(-20).ToString('o')
        statusCode = 'started'; clientProcessId = 123; watcherProcessId = 456; watcherProcessStartedAtUtc = 'synthetic'
        startReceiptSha256 = $null; completionReceiptSha256 = $null; failureCode = $null; updatedAtUtc = $null
    })
    Write-AtomicJson $contextPath @{statusCode = 'started'}
    & $action
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $context = Get-Content -LiteralPath $contextPath -Raw | ConvertFrom-Json
    $success = $case -in @('early-exit','exit-before-sample','normal-exit','long-run','server-exited')
    $expectedStatus = if ($success) { 'completed' } else { 'started' }
    Assert-Watcher ($state.statusCode -ceq $expectedStatus -and $context.statusCode -ceq $expectedStatus) 'watcher_completion_state_invalid'
    Assert-Watcher ((Test-Path -LiteralPath $SoloRaidPendingPayloadPath) -eq ($case -in @('pg-failure','persist-failure','isolation-failure'))) 'pending_deleted_before_acknowledgement'
    Assert-Watcher ($null -eq $state.clientProcessId -and $null -eq $state.watcherProcessId) 'exited_process_indicator_not_cleared'
    $progressPath=Join-Path $LaunchRoot 'execution-progress.json'
    $exitObserved=$false
    if (Test-Path -LiteralPath $progressPath) {
        $progress=Get-Content -LiteralPath $progressPath -Raw | ConvertFrom-Json
        $exitObserved=@($progress.events | Where-Object {$_.stageCode -ceq 'game_exited'}).Count -gt 0
    }
    Assert-Watcher ($exitObserved -eq ($success -or $case -in @('pg-failure','persist-failure','isolation-failure'))) ('unverified_exit_progress_' + $case)
    if ($case -eq 'identity-failure') {
        Assert-Watcher (-not $script:waited -and -not $script:disposed -and -not $script:hostsRestored -and
            -not $script:databaseReady -and -not $script:persisted) 'identity_failure_changed_runtime'
    }
    Assert-Watcher ($script:opened -eq $script:closed) ('leaked_process_handle_' + $case)
    $samples=(Get-Content -LiteralPath (Join-Path $runRoot 'startup.measurement.json') -Raw | ConvertFrom-Json).samples
    $expectedSamples=if ($case -in @('early-exit','exit-before-sample','identity-failure','query-failure')) {0}
        elseif ($case -like 'network-*' -or $case -eq 'long-run') {2} else {1}
    Assert-Watcher ($samples.Count -eq $expectedSamples) ('measurement_count_' + $case)
    if ($case -like 'network-*') {
        Assert-Watcher ($samples[0].nonLoopbackConnectionCount -eq 0 -and $samples[1].nonLoopbackConnectionCount -eq 1) 'network_observation_not_preserved'
    } else {
        Assert-Watcher (@($samples | Where-Object {$_.nonLoopbackConnectionCount -ne 0}).Count -eq 0) 'unrelated_connection_counted'
    }
    if ($case -like 'network-*' -or $case -in @('query-failure','reused-server')) {
        $detail=Get-Content -LiteralPath (Join-Path $LaunchRoot 'watcher-failure.detail.json') -Raw | ConvertFrom-Json
        $expectedFailure=if ($case -like 'network-*') {'phase_d_runtime_non_loopback_connection_detected'}
            elseif ($case -eq 'query-failure') {'synthetic_tcp_query_failed'} else {'synthetic_identity_mismatch'}
        Assert-Watcher ($detail.failureCode -ceq $expectedFailure -and $script:jobOrder -ceq 'zero,redact,fx') 'unsafe_network_failure_cleanup'
        Assert-Watcher (-not $script:persisted -and -not $script:hostsRestored) 'failed_rollback_released_state'
    }
    if($case -eq 'isolation-failure') {
        $receipt=Get-Content -LiteralPath (Join-Path $EvidenceRoot 'completion.receipt.json') -Raw | ConvertFrom-Json
        Assert-Watcher (-not $receipt.extensionFirewallRemoved -and -not $script:checkpointWritten -and
            -not $script:databaseReady -and -not $script:persisted) 'isolation_failure_released_state'
    }
    if($success) {
        $output=Get-Content -LiteralPath (Join-Path $LaunchRoot 'completion.output.json') -Raw | ConvertFrom-Json
        Assert-Watcher $output.extensionFirewallRemoved 'completion_output_preceded_firewall_verification'
    }
    if ($success) { Assert-Watcher ($null -eq $state.failureCode -and $script:databaseReady -and $script:persisted) 'completed_without_database_or_acknowledgement' }
    else { Assert-Watcher ($null -ne $state.failureCode) 'failure_not_reconcilable' }
}
}
finally {
    $resolved = [IO.Path]::GetFullPath($taskRoot)
    if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\') -ine ([IO.Path]::GetTempPath()).TrimEnd('\') -or
        [IO.Path]::GetFileName($resolved) -notlike 'nll-watcher-completion-*') { throw 'unsafe_test_cleanup' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
'Phase D watcher: 14 exit/network/identity/isolation/database/persistence cases passed; synthetic resources only.'
