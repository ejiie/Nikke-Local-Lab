param(
    [Parameter(Mandatory)] [string]$LaunchRoot,
    [Parameter(Mandatory)] [string]$ServerRoot,
    [Parameter(Mandatory)] [string]$EvidenceRoot,
    [Parameter(Mandatory)] [string]$CompletionScriptPath,
    [Parameter(Mandatory)] [int]$ClientProcessId,
    [Parameter(Mandatory)] [ValidatePattern('^[0-9a-f]{64}$')]
    [string]$StartReceiptSha256,
    [Parameter(Mandatory)] [string]$ControlCenterPgCtlPath,
    [Parameter(Mandatory)] [string]$ControlCenterPgDataPath,
    [Parameter(Mandatory)] [string]$ControlCenterPgLogPath,
    [Parameter(Mandatory)] [string]$ControlCenterHostsBackupPath,
    [Parameter(Mandatory)] [ValidatePattern('^[0-9a-f]{64}$')]
    [string]$ControlCenterHostsOriginalSha256,
    [Parameter(Mandatory)] [string]$RuntimeMaterializerPath,
    [Parameter(Mandatory)] [string]$SoloRaidPendingPayloadPath,
    [Parameter(Mandatory)] [string]$SoloRaidCaptureReceiptPath,
    [Parameter(Mandatory)] [string]$SoloRaidPersistenceReceiptPath,
    [Parameter(Mandatory)] [ValidatePattern('^[A-Z][A-Z0-9_]{2,63}$')]
    [string]$ConnectionStringEnvironmentVariable,
    [Parameter(Mandatory)] [ValidatePattern('^[A-Z][A-Z0-9_]{2,63}$')]
    [string]$IdentitySecretEnvironmentVariable,
    [string]$ExpectedRunnerBundleSha256 = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$sealedRunner = $null
if ($ExpectedRunnerBundleSha256) {
    # Verify the verifier before importing it; the parent supplied the pin.
    $manifestPath = Join-Path $PSScriptRoot 'runner.bundle.json'
    if ((Get-FileHash -LiteralPath $manifestPath).Hash.ToLowerInvariant() -cne $ExpectedRunnerBundleSha256) { throw 'phase_d_runner_bundle_invalid' }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $seal = @($manifest.members | Where-Object { $_.name -ceq 'Nll.PhaseDRunnerSeal.ps1' })
    $sealPath = Join-Path $PSScriptRoot 'Nll.PhaseDRunnerSeal.ps1'
    if ($seal.Count -ne 1 -or (Get-FileHash -LiteralPath $sealPath).Hash.ToLowerInvariant() -cne $seal[0].sha256) { throw 'phase_d_runner_bundle_invalid' }
    . $sealPath
    $sealedRunner = Read-PhaseDRunnerBundle -LaunchRoot $LaunchRoot -ExpectedBundleSha256 $ExpectedRunnerBundleSha256
    if ([IO.Path]::GetFullPath($sealedRunner.root) -ine [IO.Path]::GetFullPath($PSScriptRoot) -or
        [IO.Path]::GetFullPath($CompletionScriptPath) -ine (Join-Path $PSScriptRoot 'invoke-nll-phase-d-runner.ps1')) { throw 'phase_d_runner_bundle_invalid' }
} elseif (Test-Path -LiteralPath (Join-Path $LaunchRoot 'tools/runner')) { throw 'phase_d_runner_binding_missing' }
. (Join-Path $PSScriptRoot 'Nll.PhaseDProcessIdentity.ps1')
. (Join-Path $PSScriptRoot 'Nll.PhaseDCompletion.ps1')
. (Join-Path $PSScriptRoot 'Nll.PhaseDChildProcess.ps1')

function Get-Sha256Lower {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}




function Restore-ControlCenterHosts {
    Assert-Watcher `
        (Test-Path -LiteralPath $ControlCenterHostsBackupPath -PathType Leaf) `
        'phase_d_control_center_hosts_backup_missing'
    Assert-Watcher `
        ((Get-Sha256Lower $ControlCenterHostsBackupPath) -ceq `
            $ControlCenterHostsOriginalSha256) `
        'phase_d_control_center_hosts_backup_invalid'
    $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    [IO.File]::WriteAllBytes(
        $hostsPath, [IO.File]::ReadAllBytes($ControlCenterHostsBackupPath))
    Assert-Watcher `
        ((Get-Sha256Lower $hostsPath) -ceq $ControlCenterHostsOriginalSha256) `
        'phase_d_control_center_hosts_restore_failed'
}

function Assert-Watcher {
    param([bool]$Condition, [string]$Code)
    if (-not $Condition) { throw $Code }
}

function Read-SoloRaidPersistenceReceipt {
    param([string]$Path, [string]$LaunchContextUid, [string]$PendingPayloadPath, [string]$CaptureReceiptPath)
    Read-PhaseDSoloRaidPersistenceReceipt -Path $Path -LaunchRoot $LaunchRoot -LaunchContextUid $LaunchContextUid `
        -PendingPayloadPath $PendingPayloadPath -CaptureReceiptPath $CaptureReceiptPath
}

function Invoke-SoloRaidPersistence {
    param([string]$LaunchContextUid)
    Assert-Watcher `
        ((Test-Path -LiteralPath $RuntimeMaterializerPath -PathType Leaf) -and
         (Test-Path -LiteralPath $SoloRaidPendingPayloadPath -PathType Leaf)) `
        'phase_d_raid_state_pending_input_invalid'
    $persistenceOutput = @(& $RuntimeMaterializerPath `
        --persist-solo-raid-state true `
        --pending-payload $SoloRaidPendingPayloadPath `
        --capture-receipt $SoloRaidCaptureReceiptPath `
        --receipt $SoloRaidPersistenceReceiptPath `
        --connection-string-env $ConnectionStringEnvironmentVariable `
        --identity-secret-env $IdentitySecretEnvironmentVariable 2>&1)
    $persistenceExitCode = $LASTEXITCODE
    if ($persistenceExitCode -ne 0) {
        $persistenceFailureCode = @(
            $persistenceOutput |
                ForEach-Object { [string]$_ } |
                Where-Object { $_ -cmatch '^phase_d_[a-z0-9._-]{3,128}$' }
        ) | Select-Object -Last 1
        if ([string]::IsNullOrWhiteSpace([string]$persistenceFailureCode)) {
            $persistenceFailureCode = 'phase_d_raid_state_persistence_failed'
        }
        throw [string]$persistenceFailureCode
    }
    $receipt = Read-SoloRaidPersistenceReceipt `
        -Path $SoloRaidPersistenceReceiptPath `
        -LaunchContextUid $LaunchContextUid `
        -PendingPayloadPath $SoloRaidPendingPayloadPath `
        -CaptureReceiptPath $SoloRaidCaptureReceiptPath
    $receipt
}

function Invoke-EmergencyRollback {
    $pointerPath = Join-Path $EvidenceRoot 'active-run.pointer.json'
    Assert-Watcher `
        (Test-Path -LiteralPath $pointerPath -PathType Leaf) `
        'phase_d_emergency_rollback_pointer_missing'
    $pointer = Get-Content -LiteralPath $pointerPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    Assert-Watcher `
        ($pointer.contractId -ceq `
            'nll/phase3b2-epinel-minimal-active-run-pointer/v1') `
        'phase_d_emergency_rollback_pointer_invalid'
    $runRoot = [IO.Path]::GetFullPath([string]$pointer.runRoot)
    Assert-Watcher `
        ($runRoot.StartsWith(
            $EvidenceRoot.TrimEnd('\') + '\',
            [StringComparison]::OrdinalIgnoreCase)) `
        'phase_d_emergency_rollback_run_root_invalid'
    if ($jobRequired) {
        Invoke-PhaseDWithJobZeroProof $LaunchRoot $ExpectedRunnerBundleSha256 { }
    } else { Stop-PhaseDVerifiedProcessSet -Pointer $pointer -Identities $runtimeProcessIdentities }
    $dbBefore = Join-Path $runRoot 'db.before.bin'
    $hostsBefore = Join-Path $runRoot 'hosts.before.bin'
    Assert-Watcher (Test-Path -LiteralPath $dbBefore -PathType Leaf) `
        'phase_d_emergency_rollback_baseline_missing'
    $runtimeDbPath = Join-Path $ServerRoot 'db.json'
    $runtimeChanged = (Test-Path -LiteralPath $runtimeDbPath -PathType Leaf) -and
        ((Get-Sha256Lower $runtimeDbPath) -cne (Get-Sha256Lower $dbBefore))
    if ($runtimeChanged -and
        -not (Test-Path -LiteralPath $SoloRaidPendingPayloadPath -PathType Leaf)) {
        # Never erase a changed runtime database unless its authenticated
        # Solo Raid envelope has already been captured outside the runtime.
        throw 'phase_d_raid_state_capture_missing_before_rollback'
    }
    [IO.File]::WriteAllBytes(
        $runtimeDbPath,
        [IO.File]::ReadAllBytes($dbBefore))
    Assert-Watcher `
        ((Get-Sha256Lower $runtimeDbPath) -ceq (Get-Sha256Lower $dbBefore)) `
        'phase_d_emergency_rollback_baseline_restore_failed'
    foreach ($name in @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal')) {
        $path = Join-Path $ServerRoot $name
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force
        }
    }
    if (Test-Path -LiteralPath $hostsBefore -PathType Leaf) {
        [IO.File]::WriteAllBytes(
            (Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'),
            [IO.File]::ReadAllBytes($hostsBefore))
    }
    Get-NetFirewallRule -Group 'NLL Phase3B2 Epinel Minimal Extension' `
        -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    Move-Item -LiteralPath $pointerPath `
        -Destination (Join-Path $runRoot 'active-run.pointer.emergency-archived.json') `
        -Force
    $true
}

$LaunchRoot = [IO.Path]::GetFullPath($LaunchRoot)
$ServerRoot = [IO.Path]::GetFullPath($ServerRoot)
$EvidenceRoot = [IO.Path]::GetFullPath($EvidenceRoot)
$CompletionScriptPath = [IO.Path]::GetFullPath($CompletionScriptPath)
$ControlCenterHostsBackupPath = [IO.Path]::GetFullPath(
    $ControlCenterHostsBackupPath)
$RuntimeMaterializerPath = [IO.Path]::GetFullPath($RuntimeMaterializerPath)
$SoloRaidPendingPayloadPath = [IO.Path]::GetFullPath($SoloRaidPendingPayloadPath)
$SoloRaidCaptureReceiptPath = [IO.Path]::GetFullPath($SoloRaidCaptureReceiptPath)
$SoloRaidPersistenceReceiptPath = [IO.Path]::GetFullPath(
    $SoloRaidPersistenceReceiptPath)
$soloRaidPendingRoot = [IO.Path]::GetFullPath(
    'C:\NLL\ControlCenter\state\phase-d-solo-raid').TrimEnd('\')
$launchContextUid = Split-Path -Leaf $LaunchRoot
$soloRaidLaunchRoot = Join-Path $soloRaidPendingRoot $launchContextUid
Assert-Watcher `
    ((Split-Path -Parent $SoloRaidPendingPayloadPath).TrimEnd('\') -ceq `
        $soloRaidLaunchRoot -and
     (Split-Path -Parent $SoloRaidCaptureReceiptPath).TrimEnd('\') -ceq `
        $soloRaidLaunchRoot -and
     (Split-Path -Parent $SoloRaidPersistenceReceiptPath).TrimEnd('\') -ceq `
        $soloRaidLaunchRoot -and
     (Split-Path -Leaf $SoloRaidPendingPayloadPath) -ceq 'payload.pending.json' -and
     (Split-Path -Leaf $SoloRaidCaptureReceiptPath) -ceq 'capture.receipt.json' -and
     (Split-Path -Leaf $SoloRaidPersistenceReceiptPath) -ceq `
        'persistence.receipt.json') `
    'phase_d_raid_state_pending_path_invalid'
$statePath = Join-Path $LaunchRoot 'execution-state.json'
$contextPath = Join-Path $LaunchRoot 'launch-context.json'
$watcherLogPath = Join-Path $LaunchRoot 'completion-watcher.log'
$databaseRestarted = $false
$controlCenterHostsRestored = $false
$completionApplied = $false
$raidStatePersisted = $false
$runtimeProcessIdentities = $null
$executionJob = $null
$physicalCleanupCommitted = $false
$jobRequired = $null -ne $sealedRunner -and $sealedRunner.specification.contractId -ceq 'nll/phase-d-runner-input/v3'
if ($jobRequired) {
    . (Join-Path $PSScriptRoot 'Nll.PhaseDRunnerContract.ps1')
    . (Join-Path $PSScriptRoot 'Nll.PhaseDJob.ps1')
    # No operational catch/rollback before the explicit handoff has committed.
    $executionJob = Receive-PhaseDJobHandoff $LaunchRoot $ExpectedRunnerBundleSha256
}

try {
    Assert-Watcher `
        (Test-Path -LiteralPath $ControlCenterHostsBackupPath -PathType Leaf) `
        'phase_d_control_center_hosts_backup_missing'
    Assert-Watcher `
        ((Get-Sha256Lower $ControlCenterHostsBackupPath) -ceq `
            $ControlCenterHostsOriginalSha256) `
        'phase_d_control_center_hosts_backup_invalid'
    $identityDocument = Get-Content -LiteralPath `
        (Join-Path $LaunchRoot 'runtime-processes.identity.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Watcher `
        ($identityDocument.schemaVersion -eq 1 -and
         $identityDocument.contractId -ceq 'nll/phase-d-runtime-process-identities/v1' -and
         $identityDocument.launchContextUid -ceq $launchContextUid -and
         $identityDocument.startReceiptSha256 -ceq $StartReceiptSha256 -and
         [int]$identityDocument.client.processId -eq $ClientProcessId) `
        'phase_d_process_identity_unresolved'
    $runtimeProcessIdentities = $identityDocument
    $client = Get-PhaseDVerifiedProcess -Identity $runtimeProcessIdentities.client
    if ($null -ne $client) {
        try { $client.WaitForExit() } finally { $client.Dispose() }
    }

    if ($jobRequired) {
        Stop-PhaseDExecutionJob $LaunchRoot $ExpectedRunnerBundleSha256
        Protect-PhaseDJobServerLog $LaunchRoot $ExpectedRunnerBundleSha256
        Invoke-PhaseDExecutionFxCleanup $LaunchRoot $ExpectedRunnerBundleSha256
    }
    $completionArguments = [ordered]@{
        ObservedStageCode = 'startup_only'; OutcomeCode = 'client_exit'
        ServerRoot = $ServerRoot; EvidenceRoot = $EvidenceRoot
    }
    if ($null -ne $sealedRunner) {
        $null = Read-PhaseDRunnerBundle -LaunchRoot $LaunchRoot -ExpectedBundleSha256 $ExpectedRunnerBundleSha256
        $completionArguments = [ordered]@{ Phase='completion'; LaunchRoot=$LaunchRoot
            ExpectedBundleSha256=$ExpectedRunnerBundleSha256; ObservedStageCode='startup_only'; OutcomeCode='client_exit' }
    }
    $completionResult = Invoke-PhaseDChildScript `
        -TimeoutSeconds 180 -OwnershipPath (Join-Path $LaunchRoot 'phase-d-child-completion.identity.json') `
        -ScriptPath $CompletionScriptPath `
        -Arguments $completionArguments `
        -StandardOutputPath (Join-Path $LaunchRoot 'derived-completion.stdout.log') `
        -StandardErrorPath (Join-Path $LaunchRoot 'derived-completion.stderr.log')
    if ($completionResult.ExitCode -ne 0) { throw 'phase_d_completion_failed' }
    $completionApplied = $true
    $completionOutput = $completionResult.StandardOutput
    [IO.File]::WriteAllText(
        (Join-Path $LaunchRoot 'completion.output.json'),
        ($completionOutput.TrimEnd() + "`n"),
        [Text.UTF8Encoding]::new($false))
    $archivedPointer = Get-ChildItem -LiteralPath $EvidenceRoot -Recurse `
        -Filter 'active-run.pointer.archived.json' -File | Select-Object -First 1
    if ($null -eq $archivedPointer) { throw 'phase_d_completion_pointer_archive_missing' }
    $completionPath = Join-Path $archivedPointer.DirectoryName 'completion.receipt.json'
    $completionSha256 = Get-Sha256Lower $completionPath
    Restore-ControlCenterHosts
    $controlCenterHostsRestored = $true
    Write-AtomicJson (Join-Path $LaunchRoot 'hosts-restoration.receipt.json') `
        ([ordered]@{
            schemaVersion = 1
            contractId = 'nll/phase-d-hosts-restoration/v1'
            restoredAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
            restoredToCapturedBaseline = $true
            officialDomainsUnboundAfterCompletion = $true
            finalSha256 = Get-Sha256Lower `
                (Join-Path $env:SystemRoot 'System32\drivers\etc\hosts')
            restorationOwnerCode = 'phase_d_completion_watcher'
        })
    if ($jobRequired) {
        Write-PhaseDPhysicalCleanupCheckpoint $LaunchRoot $ExpectedRunnerBundleSha256 $completionPath
        $physicalCleanupCommitted = $true
    }
    $pgStartExitCode = Invoke-PhaseDPgCtl `
        -OwnershipPath (Join-Path $LaunchRoot 'phase-d-child-pg.identity.json') `
        -PgCtlPath $ControlCenterPgCtlPath `
        -Arguments @(
            'start', '-D', $ControlCenterPgDataPath,
            '-l', $ControlCenterPgLogPath, '-w', '-t', '60')
    if ($pgStartExitCode -ne 0) {
        throw 'phase_d_control_center_database_restart_failed'
    }
    $databaseRestarted = $true
    $persistence = Invoke-SoloRaidPersistence -LaunchContextUid $launchContextUid
    $raidStatePersisted = $true
    $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    $state.statusCode = 'completed'
    $state.clientProcessId = $null
    if ($state.PSObject.Properties.Name -contains 'watcherProcessId') {
        $state.watcherProcessId = $null
    }
    if ($state.PSObject.Properties.Name -contains 'watcherProcessStartedAtUtc') {
        $state.watcherProcessStartedAtUtc = $null
    }
    $state.startReceiptSha256 = $StartReceiptSha256
    $state.completionReceiptSha256 = $completionSha256
    $state.failureCode = $null
    $state.updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    $context = Get-Content -LiteralPath $contextPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    $context.statusCode = 'completed'
    Invoke-PhaseDStateLock -LaunchRoot $LaunchRoot -Action {
        Write-AtomicJson $contextPath $context
        # execution-state.json is the admission authority. Make it terminal only
        # after the exact PostgreSQL replay and context update have succeeded.
        Write-AtomicJson $statePath $state
    }
    # The execution state is terminal only after PostgreSQL has acknowledged
    # the exact pending request. Pending cleanup happens afterwards so a crash
    # can never leave a non-terminal launch with its replay proof deleted.
    Remove-Item -LiteralPath $SoloRaidPendingPayloadPath -Force
    Assert-Watcher `
        (-not (Test-Path -LiteralPath $SoloRaidPendingPayloadPath)) `
        'phase_d_raid_state_pending_delete_failed'
    [IO.File]::WriteAllText(
        $watcherLogPath,
        "completed $completionSha256`n",
        [Text.UTF8Encoding]::new($false))
    $watcherIdentityPath = Join-Path $LaunchRoot 'completion-watcher.identity.json'
    if (Test-Path -LiteralPath $watcherIdentityPath -PathType Leaf) {
        Remove-Item -LiteralPath $watcherIdentityPath -Force
    }
}
catch {
    $primaryFailure = $_
    try { Write-PhaseDFirstFailure -LaunchRoot $LaunchRoot -Owner watcher -Stage completion -Failure $primaryFailure } catch { }
    $failureCode = if ($primaryFailure.Exception.Message -cmatch '^[a-z0-9._-]{3,128}$') {
        $primaryFailure.Exception.Message
    }
    else { 'phase_d_completion_uncontrolled_failure' }
    if ($failureCode -ceq 'phase_d_child_deadline_unproven') {
        Invoke-PhaseDStateLock -LaunchRoot $LaunchRoot -Action {
            $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $state.statusCode = 'started'
            $state.failureCode = $failureCode
            Write-AtomicJson $statePath $state
        }
        throw $failureCode
    }
    $rolledBack = $false
    if ($jobRequired -and -not $physicalCleanupCommitted) {
        try {
            Assert-PhaseDChildrenExited -LaunchRoot $LaunchRoot
            Stop-PhaseDExecutionJob $LaunchRoot $ExpectedRunnerBundleSha256
            Protect-PhaseDJobServerLog $LaunchRoot $ExpectedRunnerBundleSha256
            Invoke-PhaseDExecutionFxCleanup $LaunchRoot $ExpectedRunnerBundleSha256
        } catch {
            # No cleanup after an unproven late child, Job or FX retirement.
            Invoke-PhaseDStateLock -LaunchRoot $LaunchRoot -Action {
                $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
                $state.statusCode='started'; $state.failureCode='phase_d_job_cleanup_unproven'
                Write-AtomicJson $statePath $state
            }
            throw 'phase_d_job_cleanup_unproven'
        }
    }
    if (-not $completionApplied) {
        try {
            $rolledBack = [bool](Invoke-EmergencyRollback)
        }
        catch {
            try { Write-PhaseDFirstFailure -LaunchRoot $LaunchRoot -Owner watcher -Stage rollback -CleanupStage rollback -Failure $_ } catch { }
            $failureCode = 'phase_d_emergency_rollback_failed'
        }
    }
    if (($completionApplied -or $rolledBack) -and -not $controlCenterHostsRestored) {
        try {
            Restore-ControlCenterHosts
            $controlCenterHostsRestored = $true
        }
        catch {
            try { Write-PhaseDFirstFailure -LaunchRoot $LaunchRoot -Owner watcher -Stage hosts_restore -CleanupStage hosts_restore -Failure $_ } catch { }
            $failureCode = 'phase_d_control_center_hosts_restore_failed'
            $rolledBack = $false
        }
    }
    $finalHostsSha256 = try {
        Get-Sha256Lower (Join-Path $env:SystemRoot 'System32\drivers\etc\hosts')
    }
    catch { $null }
    if (-not $physicalCleanupCommitted) {
    Write-AtomicJson (Join-Path $LaunchRoot 'hosts-restoration.receipt.json') `
        ([ordered]@{
            schemaVersion = 1
            contractId = 'nll/phase-d-hosts-restoration/v1'
            restoredAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
            restoredToCapturedBaseline = `
                $finalHostsSha256 -ceq $ControlCenterHostsOriginalSha256
            officialDomainsUnboundAfterCompletion = `
                $finalHostsSha256 -ceq $ControlCenterHostsOriginalSha256
            finalSha256 = $finalHostsSha256
            restorationOwnerCode = 'phase_d_completion_watcher_failure_path'
        })
    }
    if (($completionApplied -or $rolledBack) -and $controlCenterHostsRestored -and -not $databaseRestarted) {
        try {
            if ($jobRequired -and -not $physicalCleanupCommitted) {
                Write-PhaseDRollbackCleanupCheckpoint $LaunchRoot $ExpectedRunnerBundleSha256
                $physicalCleanupCommitted=$true
            }
            $pgStartExitCode = Invoke-PhaseDPgCtl `
                -OwnershipPath (Join-Path $LaunchRoot 'phase-d-child-pg.identity.json') `
                -PgCtlPath $ControlCenterPgCtlPath `
                -Arguments @(
                    'start', '-D', $ControlCenterPgDataPath,
                    '-l', $ControlCenterPgLogPath, '-w', '-t', '60')
            if ($pgStartExitCode -ne 0) { throw 'restart_failed' }
            $databaseRestarted = $true
        }
        catch {
            try { Write-PhaseDFirstFailure -LaunchRoot $LaunchRoot -Owner watcher -Stage database_restart -CleanupStage database_restart -Failure $_ } catch { }
            $failureCode = 'phase_d_control_center_database_restart_failed'
        }
    }
    $pendingReplayRequired =
        -not $raidStatePersisted -and
        ((Test-Path -LiteralPath $SoloRaidPendingPayloadPath -PathType Leaf) -or
         (Test-Path -LiteralPath $SoloRaidCaptureReceiptPath -PathType Leaf))
    $orphanRecoveryRequired =
        -not $raidStatePersisted -and
        (-not ($completionApplied -or $rolledBack) -or
         -not $controlCenterHostsRestored -or -not $databaseRestarted)
    Invoke-PhaseDStateLock -LaunchRoot $LaunchRoot -Action {
        if (Test-Path -LiteralPath $statePath -PathType Leaf) {
            $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 |
                ConvertFrom-Json
            $state.statusCode = if ($raidStatePersisted) {
                'completed'
            }
            elseif ($pendingReplayRequired -or $orphanRecoveryRequired) {
                # Keep this launch reconcilable. Pending is replayed directly; a
                # changed runtime DB that capture/rollback could not finish is
                # recovered from its still-active pointer before the next launch.
                'started'
            }
            elseif ($rolledBack) { 'rolled_back' } else { 'failed' }
            $state.clientProcessId = $null
            if ($state.PSObject.Properties.Name -contains 'watcherProcessId') {
                $state.watcherProcessId = $null
            }
            if ($state.PSObject.Properties.Name -contains 'watcherProcessStartedAtUtc') {
                $state.watcherProcessStartedAtUtc = $null
            }
            $state.failureCode = $failureCode
            $state.updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
            Write-AtomicJson $statePath $state
        }
        if (Test-Path -LiteralPath $contextPath -PathType Leaf) {
            $context = Get-Content -LiteralPath $contextPath -Raw -Encoding UTF8 |
                ConvertFrom-Json
            $context.statusCode = if ($raidStatePersisted) {
                'completed'
            }
            elseif ($pendingReplayRequired -or $orphanRecoveryRequired) { 'started' }
            elseif ($rolledBack) { 'rolled_back' } else { 'failed' }
            Write-AtomicJson $contextPath $context
        }
    }
    $watcherIdentityPath = Join-Path $LaunchRoot 'completion-watcher.identity.json'
    if (Test-Path -LiteralPath $watcherIdentityPath -PathType Leaf) {
        Remove-Item -LiteralPath $watcherIdentityPath -Force
    }
    [IO.File]::WriteAllText(
        $watcherLogPath,
        "$failureCode`n",
        [Text.UTF8Encoding]::new($false))
}
finally { if ($null -ne $executionJob) { $executionJob.Dispose() } }
