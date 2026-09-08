[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ExecutionRoot,
    [Parameter(Mandatory)] [ValidatePattern('^[0-9a-f-]{36}$')]
    [string]$LaunchContextUid,
    [Parameter(Mandatory)] [string]$ConfigurationPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.PhaseDProcessIdentity.ps1')

function Assert-Recovery {
    param([bool]$Condition, [string]$Code)
    if (-not $Condition) { throw $Code }
}

function Write-AtomicJson {
    param([string]$Path, [object]$Value, [int]$Depth = 8)
    $temporary = $Path + '.partial-' + [guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText(
        $temporary,
        (($Value | ConvertTo-Json -Depth $Depth) + "`n"),
        [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Get-Sha256Lower {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-DerivedStartRollbackProof {
    param(
        [string]$LaunchRoot,
        [string]$EvidenceRoot,
        [string]$RuntimeRoot
    )
    try {
        $pointerPath = Join-Path $EvidenceRoot 'active-run.pointer.json'
        if (Test-Path -LiteralPath $pointerPath -PathType Leaf) { return $false }
        $failures = @(Get-ChildItem -LiteralPath $EvidenceRoot -Recurse -File `
            -Filter 'run-failure.receipt.json')
        if ($failures.Count -ne 1) { return $false }
        $failure = Get-Content -LiteralPath $failures[0].FullName -Raw -Encoding UTF8 |
            ConvertFrom-Json
        $materialization = Get-Content `
            -LiteralPath (Join-Path $LaunchRoot 'materialization.receipt.json') `
            -Raw -Encoding UTF8 | ConvertFrom-Json
        $runtimeDatabasePath = Join-Path $RuntimeRoot 'db.json'
        $systemHostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
        $innerHostsBaselinePath = Join-Path $failures[0].Directory.FullName `
            'hosts.before.bin'
        $controlCenterHostsBaselinePath = Join-Path $LaunchRoot `
            'control-center-hosts.before.bin'
        $currentHostsSha256 = Get-Sha256Lower $systemHostsPath
        $hostsRollbackProven = @(
            $innerHostsBaselinePath,
            $controlCenterHostsBaselinePath
        ) | Where-Object {
            (Test-Path -LiteralPath $_ -PathType Leaf) -and
            (Get-Sha256Lower $_) -ceq $currentHostsSha256
        } | Select-Object -First 1
        $runtimeProcessesCold = @(
            Get-Process -Name nikke,EpinelPS,
                NikkeLocalLab.Phase3B2.PhysicalBootstrap `
                -ErrorAction SilentlyContinue
        ).Count -eq 0
        [string]$failure.contractId -in @(
            'nll/phase3b2-epinel-minimal-reference-failure/v1',
            'nll/phase3b2-epinel-solo-raid-ranking-prefix-failure/v9'
        ) -and
            [bool]$failure.automaticRollbackCompleted -and
            -not [bool]$failure.officialLauncherExecutionStarted -and
            -not [bool]$failure.officialOutboundFallbackUsed -and
            $runtimeProcessesCold -and
            $null -ne $hostsRollbackProven -and
            $materialization.contractId -ceq `
                'nll/phase-d-runtime-materialization/v1' -and
            [string]$materialization.runtimeDatabaseSha256 -cmatch '^[0-9a-f]{64}$' -and
            (Test-Path -LiteralPath $runtimeDatabasePath -PathType Leaf) -and
            (Get-Sha256Lower $runtimeDatabasePath) -ceq `
                [string]$materialization.runtimeDatabaseSha256
    }
    catch { $false }
}

function Invoke-RecoveryPgCtl {
    param(
        [string]$PgCtlPath,
        [string[]]$Arguments
    )
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $PgCtlPath
    $info.Arguments = (($Arguments | ForEach-Object {
        '"' + $_.Replace('"', '\"') + '"'
    }) -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($info)
    $process.WaitForExit()
    $exitCode = [int]$process.ExitCode
    $process.Dispose()
    $exitCode
}

function Read-SoloRaidPersistenceReceipt {
    param(
        [string]$Path,
        [string]$PendingPayloadPath,
        [string]$CaptureReceiptPath
    )
    Assert-Recovery (Test-Path -LiteralPath $Path -PathType Leaf) `
        'phase_d_raid_state_persistence_receipt_missing'
    Assert-Recovery `
        ((Test-Path -LiteralPath $PendingPayloadPath -PathType Leaf) -and
         (Test-Path -LiteralPath $CaptureReceiptPath -PathType Leaf)) `
        'phase_d_raid_state_persistence_proof_missing'
    $persistence = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 |
        ConvertFrom-Json
    $pending = Get-Content -LiteralPath $PendingPayloadPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    $capture = Get-Content -LiteralPath $CaptureReceiptPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    $context = Get-Content -LiteralPath (Join-Path $launchRoot 'launch-context.json') `
        -Raw -Encoding UTF8 | ConvertFrom-Json
    $headRevisionUid = [Guid]::Empty
    $headRevisionPresent = $null -ne $persistence.headRevisionUid -and
        [Guid]::TryParse([string]$persistence.headRevisionUid, [ref]$headRevisionUid) -and
        $headRevisionUid -ne [Guid]::Empty
    $resultCode = [string]$persistence.resultCode
    $expectedHeadPersistence = if (
        $null -eq $persistence.expectedHeadRevisionUid) {
        ''
    } else { [string]$persistence.expectedHeadRevisionUid }
    $expectedHeadCapture = if ($null -eq $capture.expectedHeadRevisionUid) {
        ''
    } else { [string]$capture.expectedHeadRevisionUid }
    Assert-Recovery `
        ($persistence.contractId -ceq `
            'nll/phase-d-classic-solo-raid-state-persistence/v1' -and
         $pending.contractId -ceq `
            'nll/phase-d-classic-solo-raid-state-pending/v1' -and
         $capture.contractId -ceq `
            'nll/phase-d-classic-solo-raid-state-capture/v1' -and
         -not [bool]$persistence.quarantined -and
         [string]$persistence.launchContextUid -ceq $LaunchContextUid -and
         [string]$capture.launchContextUid -ceq $LaunchContextUid -and
         [string]$pending.capture.launchContextUid -ceq $LaunchContextUid -and
         [string]$persistence.pendingPayloadSha256 -ceq `
            (Get-Sha256Lower $PendingPayloadPath) -and
         [string]$persistence.captureReceiptSha256 -ceq `
            (Get-Sha256Lower $CaptureReceiptPath) -and
         [string]$persistence.accountUid -ceq [string]$capture.accountUid -and
         [string]$persistence.accountUid -ceq [string]$context.accountUid -and
         [string]$persistence.accountRevisionSetSha256 -ceq `
            [string]$capture.accountRevisionSetSha256 -and
         [string]$persistence.accountRevisionSetSha256 -ceq `
            [string]$context.accountRevisionSetSha256 -and
         [int]$persistence.seasonNumber -eq [int]$capture.seasonNumber -and
         [int]$persistence.seasonNumber -eq [int]$context.seasonNumber -and
         [string]$persistence.raidSnapshotUid -ceq `
            [string]$capture.raidSnapshotUid -and
         [string]$persistence.raidSnapshotUid -ceq `
            [string]$context.raidSnapshotUid -and
         [string]$persistence.raidSnapshotSha256 -ceq `
            [string]$capture.raidSnapshotSha256 -and
         [string]$persistence.raidSnapshotSha256 -ceq `
            [string]$context.raidSnapshotSha256 -and
         [string]$persistence.clientBuildCode -ceq `
            [string]$capture.clientBuildCode -and
         [string]$persistence.clientBuildCode -ceq `
            [string]$context.clientBuildCode -and
         [string]$persistence.clientExecutableSha256 -ceq `
            [string]$capture.clientExecutableSha256 -and
         [string]$persistence.clientExecutableSha256 -ceq `
            [string]$context.clientExecutableSha256 -and
         $expectedHeadPersistence -ceq $expectedHeadCapture -and
         [string]$persistence.protectedPayloadSha256 -ceq `
            [string]$capture.protectedPayloadSha256 -and
         [string]$persistence.requestSha256 -ceq `
            [string]$capture.requestSha256 -and
         [string]$persistence.stateContentSha256 -ceq `
            [string]$capture.stateContentSha256 -and
         [string]$persistence.resultStateContentSha256 -ceq `
            [string]$persistence.stateContentSha256 -and
         $resultCode -in @('no_state','state_unchanged','state_advanced') -and
         (($resultCode -ceq 'no_state' -and -not $headRevisionPresent) -or
          ($resultCode -cne 'no_state' -and $headRevisionPresent)) -and
         [string]$persistence.requestSha256 -cmatch '^[0-9a-f]{64}$' -and
         [string]$persistence.pendingPayloadSha256 -cmatch '^[0-9a-f]{64}$' -and
         [string]$persistence.captureReceiptSha256 -cmatch '^[0-9a-f]{64}$' -and
         [string]$persistence.stateContentSha256 -cmatch '^[0-9a-f]{64}$' -and
         [string]$persistence.resultStateContentSha256 -cmatch '^[0-9a-f]{64}$') `
        'phase_d_raid_state_persistence_receipt_invalid'
    $persistence
}

function Invoke-SoloRaidPendingReplay {
    Assert-Recovery `
        ((Test-Path -LiteralPath $runtimeMaterializerPath -PathType Leaf) -and
         (Test-Path -LiteralPath $soloRaidPendingPayloadPath -PathType Leaf)) `
        'phase_d_raid_state_pending_input_invalid'
    $persistenceOutput = @(& $runtimeMaterializerPath `
        --persist-solo-raid-state true `
        --pending-payload $soloRaidPendingPayloadPath `
        --capture-receipt $soloRaidCaptureReceiptPath `
        --receipt $soloRaidPersistenceReceiptPath `
        --connection-string-env $connectionStringEnvironmentVariable `
        --identity-secret-env $identitySecretEnvironmentVariable 2>&1)
    $persistenceExitCode = $LASTEXITCODE
    if ($persistenceExitCode -ne 0) {
        $failureCode = @(
            $persistenceOutput |
                ForEach-Object { [string]$_ } |
                Where-Object { $_ -cmatch '^phase_d_[a-z0-9._-]{3,128}$' }
        ) | Select-Object -Last 1
        if ([string]::IsNullOrWhiteSpace([string]$failureCode)) {
            $failureCode = 'phase_d_raid_state_persistence_failed'
        }
        throw [string]$failureCode
    }
    $persistence = Read-SoloRaidPersistenceReceipt `
        -Path $soloRaidPersistenceReceiptPath `
        -PendingPayloadPath $soloRaidPendingPayloadPath `
        -CaptureReceiptPath $soloRaidCaptureReceiptPath
    $persistence
}

function Invoke-SoloRaidCapture {
    param([string]$SourceDatabasePath)
    Assert-Recovery `
        ((Test-Path -LiteralPath $runtimeMaterializerPath -PathType Leaf) -and
         (Test-Path -LiteralPath $SourceDatabasePath -PathType Leaf) -and
         -not (Test-Path -LiteralPath $SoloRaidPendingPayloadPath) -and
         -not (Test-Path -LiteralPath $soloRaidCaptureReceiptPath)) `
        'phase_d_raid_state_capture_input_invalid'
    $contextPath = Join-Path $launchRoot 'launch-context.json'
    $materializationReceiptPath = Join-Path $launchRoot `
        'materialization.receipt.json'
    Assert-Recovery `
        ((Test-Path -LiteralPath $contextPath -PathType Leaf) -and
         (Test-Path -LiteralPath $materializationReceiptPath -PathType Leaf)) `
        'phase_d_raid_state_capture_binding_missing'
    $context = Get-Content -LiteralPath $contextPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    $materialization = Get-Content -LiteralPath $materializationReceiptPath `
        -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Recovery `
        ($context.contractId -ceq 'nll/launch-context/v1' -and
         [string]$context.launchContextUid -ceq $LaunchContextUid -and
         [string]$context.accountUid -ceq [string]$materialization.accountUid -and
         [string]$context.accountRevisionSetSha256 -ceq `
            [string]$materialization.accountRevisionSetSha256 -and
         [int]$context.seasonNumber -eq [int]$materialization.raidSeasonNumber -and
         [string]$context.raidSnapshotUid -ceq `
            [string]$materialization.raidSnapshotUid -and
         [string]$context.raidSnapshotSha256 -ceq `
            [string]$materialization.raidSnapshotSha256 -and
         [string]$context.clientBuildCode -cmatch '^[a-z][a-z0-9._-]{0,63}$' -and
         [string]$context.clientExecutableSha256 -cmatch '^[0-9a-f]{64}$') `
        'phase_d_raid_state_capture_binding_invalid'
    $expectedHeadRevisionUid = if (
        $null -eq $materialization.soloRaidStateHeadRevisionUid) {
        'none'
    } else { [string]$materialization.soloRaidStateHeadRevisionUid }
    $captureOutput = @(& $runtimeMaterializerPath `
        --capture-solo-raid-state true `
        --source-db $SourceDatabasePath `
        --pending-payload $SoloRaidPendingPayloadPath `
        --receipt $soloRaidCaptureReceiptPath `
        --account-uid ([string]$context.accountUid) `
        --account-revision-set-sha256 `
            ([string]$context.accountRevisionSetSha256) `
        --season-number ([string]$context.seasonNumber) `
        --raid-snapshot-uid ([string]$context.raidSnapshotUid) `
        --raid-snapshot-sha256 ([string]$context.raidSnapshotSha256) `
        --client-build-code ([string]$context.clientBuildCode) `
        --client-executable-sha256 `
            ([string]$context.clientExecutableSha256) `
        --launch-context-uid $LaunchContextUid `
        --expected-head-revision-uid $expectedHeadRevisionUid `
        --identity-secret-env $identitySecretEnvironmentVariable 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $captureFailureCode = @(
            $captureOutput |
                ForEach-Object { [string]$_ } |
                Where-Object { $_ -cmatch '^phase_d_[a-z0-9._-]{3,128}$' }
        ) | Select-Object -Last 1
        if ([string]::IsNullOrWhiteSpace([string]$captureFailureCode)) {
            $captureFailureCode = 'phase_d_raid_state_capture_failed'
        }
        throw [string]$captureFailureCode
    }
    Assert-Recovery `
        ((Test-Path -LiteralPath $SoloRaidPendingPayloadPath -PathType Leaf) -and
         (Test-Path -LiteralPath $soloRaidCaptureReceiptPath -PathType Leaf)) `
        'phase_d_raid_state_capture_output_missing'
}

function Test-PinnedProcess {
    param([int]$Id, [string]$Name, [string]$StartedAtUtc)
    $process = Get-Process -Id $Id -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $false }
    try {
        if ([string]::IsNullOrWhiteSpace($StartedAtUtc)) {
            throw 'phase_d_orphan_recovery_watcher_identity_invalid'
        }
        $null = $process.Handle
        if ($process.StartTime.ToUniversalTime().ToString('o') -cne $StartedAtUtc) { return $false }
        $expectedPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if ($process.ProcessName -cne $Name -or -not [string]::Equals(
                $process.Path, $expectedPath, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'phase_d_orphan_recovery_watcher_identity_invalid'
        }
        return $true
    }
    finally { $process.Dispose() }
}

$ExecutionRoot = [IO.Path]::GetFullPath($ExecutionRoot).TrimEnd('\')
$ConfigurationPath = [IO.Path]::GetFullPath($ConfigurationPath)
$launchRoot = [IO.Path]::GetFullPath((Join-Path $ExecutionRoot $LaunchContextUid))
Assert-Recovery `
    ((Split-Path -Parent $launchRoot).TrimEnd('\') -ceq $ExecutionRoot) `
    'phase_d_orphan_recovery_target_invalid'
$statePath = Join-Path $launchRoot 'execution-state.json'
Assert-Recovery (Test-Path -LiteralPath $statePath -PathType Leaf) `
    'phase_d_orphan_recovery_state_missing'

$state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-Recovery `
    ($state.contractId -ceq 'nll/phase-d-execution-state/v1' -and
     [string]$state.launchContextUid -ceq $LaunchContextUid) `
    'phase_d_orphan_recovery_state_invalid'
$completedPendingPath = Join-Path `
    (Join-Path 'C:\NLL\ControlCenter\state\phase-d-solo-raid' $LaunchContextUid) 'payload.pending.json'
$completedNeedsReplay = [string]$state.statusCode -ceq 'completed' -and
    (Test-Path -LiteralPath $completedPendingPath -PathType Leaf)
if ([string]$state.statusCode -notin @('draft','validated','started','failed') -and
    -not $completedNeedsReplay) {
    [pscustomobject]@{ statusCode = [string]$state.statusCode; recovered = $false } |
        ConvertTo-Json -Compress
    exit 0
}
$priorStatusCode = [string]$state.statusCode

if (@(Get-Process -Name nikke,nikke_launcher,
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap' -ErrorAction SilentlyContinue).Count -gt 0) {
    exit 2 # client/bootstrap still own their lifetime; not a failed recovery
}

$watcherIdentityPath = Join-Path $launchRoot 'completion-watcher.identity.json'
if (Test-Path -LiteralPath $watcherIdentityPath -PathType Leaf) {
    $watcher = Get-Content -LiteralPath $watcherIdentityPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    Assert-Recovery `
        ($watcher.contractId -ceq 'nll/phase-d-completion-watcher-identity/v1') `
        'phase_d_orphan_recovery_watcher_identity_invalid'
    if (Test-PinnedProcess `
            -Id ([int]$watcher.processId) `
            -Name 'powershell' `
            -StartedAtUtc ([string]$watcher.processStartedAtUtc)) {
        [pscustomobject]@{ statusCode = 'active'; recovered = $false } |
            ConvertTo-Json -Compress
        exit 2
    }
}

$residualServerStopped = Stop-PhaseDResidualServer -LaunchRoot $launchRoot
Assert-Recovery `
    (@(Get-Process -Name EpinelPS,nikke,nikke_launcher,
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap' -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase_d_orphan_recovery_runtime_not_cold'

$evidenceRoot = Join-Path $launchRoot 'evidence'
$runtimeRoot = Join-Path $launchRoot 'runtime'
$runtimeMaterializerPath = Join-Path $runtimeRoot `
    'NikkeLocalLab.PhaseD.RuntimeMaterializer.exe'
$soloRaidPendingRoot = [IO.Path]::GetFullPath(
    'C:\NLL\ControlCenter\state\phase-d-solo-raid').TrimEnd('\')
$soloRaidLaunchRoot = Join-Path $soloRaidPendingRoot $LaunchContextUid
$SoloRaidPendingPayloadPath = Join-Path $soloRaidLaunchRoot 'payload.pending.json'
$soloRaidCaptureReceiptPath = Join-Path $soloRaidLaunchRoot 'capture.receipt.json'
$soloRaidPersistenceReceiptPath = Join-Path $soloRaidLaunchRoot `
    'persistence.receipt.json'
$configuration = Get-Content -LiteralPath $ConfigurationPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$connectionStringEnvironmentVariable =
    [string]$configuration.database.connectionStringEnvironmentVariable
$identitySecretEnvironmentVariable =
    [string]$configuration.identity.hmacSecretEnvironmentVariable
Assert-Recovery `
    ($connectionStringEnvironmentVariable -cmatch '^[A-Z][A-Z0-9_]{2,63}$' -and
     $identitySecretEnvironmentVariable -cmatch '^[A-Z][A-Z0-9_]{2,63}$' -and
     -not [string]::IsNullOrWhiteSpace(
        [Environment]::GetEnvironmentVariable(
            $connectionStringEnvironmentVariable)) -and
     -not [string]::IsNullOrWhiteSpace(
        [Environment]::GetEnvironmentVariable(
            $identitySecretEnvironmentVariable))) `
    'phase_d_orphan_recovery_environment_missing'
$pointer = Get-ChildItem -LiteralPath $evidenceRoot -Recurse -File `
    -Filter 'active-run.pointer.json' -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($priorStatusCode -ceq 'failed' -and $null -eq $pointer -and
    -not (Test-Path -LiteralPath $SoloRaidPendingPayloadPath -PathType Leaf) -and
    -not (Test-Path -LiteralPath $soloRaidCaptureReceiptPath -PathType Leaf) -and
    -not (Test-Path -LiteralPath $soloRaidPersistenceReceiptPath -PathType Leaf)) {
    [pscustomobject]@{ statusCode = 'failed'; recovered = $false } |
        ConvertTo-Json -Compress
    exit 0
}
$runtimeRolledBack = $false
$soloRaidCaptureAttempted = $false
if ($null -ne $pointer) {
    $active = Get-Content -LiteralPath $pointer.FullName -Raw -Encoding UTF8 |
        ConvertFrom-Json
    Assert-Recovery `
        ($active.contractId -ceq 'nll/phase3b2-epinel-minimal-active-run-pointer/v1') `
        'phase_d_orphan_recovery_pointer_invalid'
    $runRoot = [IO.Path]::GetFullPath([string]$active.runRoot)
    Assert-Recovery ($runRoot.StartsWith($evidenceRoot + '\',[StringComparison]::OrdinalIgnoreCase)) `
        'phase_d_orphan_recovery_run_root_invalid'
    $dbBefore = Join-Path $runRoot 'db.before.bin'
    Assert-Recovery (Test-Path -LiteralPath $dbBefore -PathType Leaf) `
        'phase_d_orphan_recovery_baseline_missing'
    $runtimeDbPath = Join-Path $runtimeRoot 'db.json'
    $runtimeChanged = (Test-Path -LiteralPath $runtimeDbPath -PathType Leaf) -and
        ((Get-Sha256Lower $runtimeDbPath) -cne (Get-Sha256Lower $dbBefore))
    if ($runtimeChanged -and
        -not (Test-Path -LiteralPath $SoloRaidPendingPayloadPath -PathType Leaf)) {
        $soloRaidCaptureAttempted = $true
        Invoke-SoloRaidCapture -SourceDatabasePath $runtimeDbPath
    }
    Assert-Recovery `
        (-not $runtimeChanged -or
         (Test-Path -LiteralPath $SoloRaidPendingPayloadPath -PathType Leaf)) `
        'phase_d_raid_state_capture_missing_before_rollback'
    [IO.File]::WriteAllBytes(
        $runtimeDbPath, [IO.File]::ReadAllBytes($dbBefore))
    Assert-Recovery `
        ((Get-Sha256Lower $runtimeDbPath) -ceq (Get-Sha256Lower $dbBefore)) `
        'phase_d_orphan_recovery_baseline_restore_failed'
    foreach ($name in @('epinelps.db','epinelps.db-shm','epinelps.db-wal')) {
        $path = Join-Path $runtimeRoot $name
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force
        }
    }
    $archiveName = 'active-run.pointer.orphan-recovery-' +
        [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ') + '.json'
    Move-Item -LiteralPath $pointer.FullName `
        -Destination (Join-Path $runRoot $archiveName) -Force
    $runtimeRolledBack = $true
}
elseif (Test-DerivedStartRollbackProof `
        -LaunchRoot $launchRoot -EvidenceRoot $evidenceRoot -RuntimeRoot $runtimeRoot) {
    $runtimeRolledBack = $true
}

$hostsBackupPath = Join-Path $launchRoot 'control-center-hosts.before.bin'
$hostsRestored = $false
if (Test-Path -LiteralPath $hostsBackupPath -PathType Leaf) {
    $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $hostsSha256 = (Get-FileHash -LiteralPath $hostsPath -Algorithm SHA256).Hash
    $backupSha256 = (Get-FileHash -LiteralPath $hostsBackupPath -Algorithm SHA256).Hash
    if ($hostsSha256 -cne $backupSha256) {
        [IO.File]::WriteAllBytes($hostsPath,[IO.File]::ReadAllBytes($hostsBackupPath))
        $hostsSha256 = (Get-FileHash -LiteralPath $hostsPath -Algorithm SHA256).Hash
    }
    $hostsRestored = $hostsSha256 -ceq $backupSha256
    Assert-Recovery $hostsRestored 'phase_d_orphan_recovery_hosts_restore_failed'
}

$firewallRules = @(Get-NetFirewallRule `
    -Group 'NLL Phase3B2 Epinel Minimal Extension' -ErrorAction SilentlyContinue)
if ($firewallRules.Count -gt 0) {
    $firewallRules | Remove-NetFirewallRule
}

$raidStatePersisted = $false
$persistenceReceiptSha256 = $null
$hasPendingPayload = Test-Path -LiteralPath $soloRaidPendingPayloadPath -PathType Leaf
$hasPersistenceReceipt = Test-Path -LiteralPath $soloRaidPersistenceReceiptPath -PathType Leaf
# A cold, proven runtime needs its management DB even when no raid data changed.
# Restart is not conditional on the presence of a pending payload.
if ($runtimeRolledBack -or $hasPendingPayload) {
    $controlCenterPgCtl =
        [Environment]::GetEnvironmentVariable('NLL_CONTROL_CENTER_PG_CTL')
    $controlCenterPgData =
        [Environment]::GetEnvironmentVariable('NLL_CONTROL_CENTER_PG_DATA')
    $controlCenterPgLog =
        [Environment]::GetEnvironmentVariable('NLL_CONTROL_CENTER_PG_LOG')
    Assert-Recovery `
        (-not [string]::IsNullOrWhiteSpace($controlCenterPgCtl) -and
         -not [string]::IsNullOrWhiteSpace($controlCenterPgData) -and
         -not [string]::IsNullOrWhiteSpace($controlCenterPgLog) -and
         (Test-Path -LiteralPath $controlCenterPgCtl -PathType Leaf) -and
         (Test-Path -LiteralPath $controlCenterPgData -PathType Container)) `
        'phase_d_orphan_recovery_database_binding_missing'
    $pgStatusExitCode = Invoke-RecoveryPgCtl `
        -PgCtlPath $controlCenterPgCtl `
        -Arguments @('status', '-D', $controlCenterPgData)
    if ($pgStatusExitCode -ne 0) {
        $pgStartExitCode = Invoke-RecoveryPgCtl `
            -PgCtlPath $controlCenterPgCtl `
            -Arguments @(
                'start', '-D', $controlCenterPgData,
                '-l', $controlCenterPgLog, '-w', '-t', '60')
        Assert-Recovery ($pgStartExitCode -eq 0) `
            'phase_d_orphan_recovery_database_start_failed'
        $pgStatusExitCode = Invoke-RecoveryPgCtl `
            -PgCtlPath $controlCenterPgCtl `
            -Arguments @('status', '-D', $controlCenterPgData)
    }
    Assert-Recovery ($pgStatusExitCode -eq 0) `
        'phase_d_orphan_recovery_database_not_ready'
}
if ($hasPendingPayload) {
    $persistence = Invoke-SoloRaidPendingReplay
    $raidStatePersisted = $true
    $persistenceReceiptSha256 = Get-Sha256Lower $soloRaidPersistenceReceiptPath
}
elseif ($hasPersistenceReceipt -or
        (Test-Path -LiteralPath $soloRaidCaptureReceiptPath -PathType Leaf)) {
    throw 'phase_d_raid_state_pending_input_missing'
}

Assert-Recovery `
    ($raidStatePersisted -or $runtimeRolledBack -or
     $priorStatusCode -in @('draft','failed')) `
    'phase_d_orphan_recovery_rollback_unproven'

$state.statusCode = if ($raidStatePersisted) { 'completed' } else { 'rolled_back' }
$state.clientProcessId = $null
if ($state.PSObject.Properties.Name -contains 'watcherProcessId') {
    $state.watcherProcessId = $null
}
if ($state.PSObject.Properties.Name -contains 'watcherProcessStartedAtUtc') {
    $state.watcherProcessStartedAtUtc = $null
}
$state.failureCode = if ($raidStatePersisted) { $null } else {
    'phase_d_orphaned_execution_recovered'
}
$state.updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')

$contextPath = Join-Path $launchRoot 'launch-context.json'
if (Test-Path -LiteralPath $contextPath -PathType Leaf) {
    $context = Get-Content -LiteralPath $contextPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    $context.statusCode = if ($raidStatePersisted) { 'completed' } else { 'rolled_back' }
    Write-AtomicJson $contextPath $context
}
# execution-state.json is the admission authority, so it becomes terminal only
# after the context has been updated and PostgreSQL replay has been proven.
Write-AtomicJson $statePath $state
$pendingCleanupSucceeded = $true
if (Test-Path -LiteralPath $soloRaidPendingPayloadPath -PathType Leaf) {
    try {
        Remove-Item -LiteralPath $soloRaidPendingPayloadPath -Force
    }
    catch {
        # The DB operation and terminal execution state are already durable.
        # Retaining encrypted pending is safer than reopening the launch.
        $pendingCleanupSucceeded = $false
    }
}
if (Test-Path -LiteralPath $watcherIdentityPath -PathType Leaf) {
    Move-Item -LiteralPath $watcherIdentityPath `
        -Destination (Join-Path $launchRoot 'completion-watcher.identity.orphan-archived.json') `
        -Force
}

$receipt = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase-d-orphan-recovery/v1'
    recoveredAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    launchContextUid = $LaunchContextUid
    priorStatusCode = $priorStatusCode
    runtimeProcessesObserved = 0
    residualServerStopped = [bool]$residualServerStopped
    runtimeRolledBack = $runtimeRolledBack
    soloRaidCaptureAttempted = $soloRaidCaptureAttempted
    raidStatePersisted = $raidStatePersisted
    persistenceReceiptSha256 = $persistenceReceiptSha256
    pendingPayloadRetained = Test-Path -LiteralPath `
        $soloRaidPendingPayloadPath -PathType Leaf
    pendingCleanupSucceeded = $pendingCleanupSucceeded
    hostsRestored = $hostsRestored
    finalStatusCode = if ($raidStatePersisted) { 'completed' } else { 'rolled_back' }
    failureCode = if ($raidStatePersisted) { $null } else {
        'phase_d_orphaned_execution_recovered'
    }
}
Write-AtomicJson (Join-Path $launchRoot 'orphan-recovery.receipt.json') $receipt
$receipt | ConvertTo-Json -Compress
