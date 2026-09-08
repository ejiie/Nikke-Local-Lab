[CmdletBinding()]
param(
    [string]$EpinelRoot = 'C:\NLL\EpinelPS',
    [string]$P2EvidenceRoot =
        'C:\NLL\Evidence\Phase3B2\Physical\p2-client-start-v2',
    [string]$BackupRoot =
        'C:\NLL\Backups\Phase3B2\PhysicalP2-v2',
    [string]$SamsungProtectedRoot =
        'E:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\RunsV2'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$activePointerPath = Join-Path $P2EvidenceRoot 'active-run.pointer.json'
$latestCompletionPath = Join-Path $P2EvidenceRoot `
    'latest-completion.pointer.json'
$extensionFirewallGroup = 'NLL Phase3B2 Physical P2 V2 Extension'
$catalogProjectionRolledBack = $false
$catalogParserExactAuthorizationPath =
    'C:\NLL\Evidence\Phase3B2\Physical\p2-tool-transfer-v2\catalog-parser-exact-repair.receipt.json'
$resourceHostMapAuthorizationPath =
    'C:\NLL\Evidence\Phase3B2\Physical\p2-tool-transfer-v2\resource-host-map-repair.receipt.json'
$dataPackVersionHeaderAuthorizationPath =
    'C:\NLL\Evidence\Phase3B2\Physical\p2-tool-transfer-v2\datapack-version-header-repair.receipt.json'
$catalogHeaderFollowupAuthorizationPath =
    'C:\NLL\Evidence\Phase3B2\Physical\p2-tool-transfer-v2\exact-catalog-header-followup.receipt.json'
$catalogSqliteTransportAuthorizationPath =
    'C:\NLL\Evidence\Phase3B2\Physical\p2-tool-transfer-v2\catalog-sqlite-transport-repair.receipt.json'
$catalogProjectionAuthorizationPath =
    'C:\NLL\Evidence\Phase3B2\Physical\p2-tool-transfer-v2\catalog-version-projection-repair.receipt.json'

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-PathDigest {
    param([string]$Path, [long]$ByteLength, [string]$Sha256)
    (Test-Path -LiteralPath $Path -PathType Leaf) -and
        (Get-Item -LiteralPath $Path).Length -eq $ByteLength -and
        (Get-Sha256Hex $Path) -ceq $Sha256
}

function Write-AtomicUtf8NoBom {
    param([string]$Path, [string]$Text)
    $temporaryPath = $Path + '.tmp.' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText(
            $temporaryPath, $Text, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Get-PinnedProcess {
    param([int]$ProcessId, [string]$ExpectedName)
    if ($ProcessId -le 0) { return $null }
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $process -or $process.ProcessName -cne $ExpectedName) {
        return $null
    }
    $process
}

function Stop-PinnedProcess {
    param([int]$ProcessId, [string]$ExpectedName)
    $process = Get-PinnedProcess $ProcessId $ExpectedName
    if ($null -eq $process) { return }

    # Prefer the application's normal window-close path.  The original client
    # may reject forced termination while its protection service is active,
    # whereas WM_CLOSE lets it unwind that protection and exit cleanly.
    if ($process.MainWindowHandle -ne [IntPtr]::Zero) {
        $null = $process.CloseMainWindow()
        Wait-Process -Id $ProcessId -Timeout 20 -ErrorAction SilentlyContinue
    }
    if ($null -eq (Get-PinnedProcess $ProcessId $ExpectedName)) { return }

    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
    Wait-Process -Id $ProcessId -Timeout 15 -ErrorAction SilentlyContinue
    if ($null -ne (Get-PinnedProcess $ProcessId $ExpectedName)) {
        $taskKill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
        # taskkill writes common race outcomes (for example, a child that
        # exited between enumeration and termination) to stderr.  With the
        # script-wide Stop preference PowerShell promotes that diagnostic to
        # a terminating NativeCommandError before the authoritative process
        # re-check below can run.  Suppress only the native diagnostic and
        # decide success from the pinned PID/name observation instead.
        $priorErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & $taskKill /PID $ProcessId /T /F 2>$null | Out-Null
        }
        finally {
            $ErrorActionPreference = $priorErrorActionPreference
        }
        Wait-Process -Id $ProcessId -Timeout 20 -ErrorAction SilentlyContinue
    }
    if ($null -ne (Get-PinnedProcess $ProcessId $ExpectedName)) {
        Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
        Wait-Process -Id $ProcessId -Timeout 10 -ErrorAction SilentlyContinue
    }
}

Assert-True ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    'phase3b2_physical_p2_v2_completion_requires_administrator'
$bootDisk = Get-Partition -DriveLetter C | Get-Disk
$samsungDisk = Get-Partition -DriveLetter E | Get-Disk
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$profileRoot = [Environment]::GetFolderPath(
    [Environment+SpecialFolder]::UserProfile)
Assert-True ($bootDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK' -and
    $bootDisk.IsBoot -and $bootDisk.IsSystem -and
    $samsungDisk.FriendlyName -ceq 'Samsung SSD 980 1TB' -and
    (($identity.Name -split '\\')[-1] -ceq 'nlloperator') -and
    [IO.Path]::GetFullPath($profileRoot).TrimEnd('\') -ceq
        'C:\Users\nlloperator') `
    'phase3b2_physical_p2_v2_completion_boundary_or_profile_invalid'
if (-not (Test-Path -LiteralPath $activePointerPath -PathType Leaf)) {
    $latestFailurePath = @(Get-ChildItem -LiteralPath $P2EvidenceRoot `
        -Recurse -File -Filter 'run-failure.receipt.json' `
        -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1 -ExpandProperty FullName)
    if ($latestFailurePath.Count -eq 1) {
        $latestFailure = Get-Content -LiteralPath $latestFailurePath[0] -Raw `
            -Encoding UTF8 | ConvertFrom-Json
        throw ('phase3b2_physical_p2_v2_completion_unavailable_' +
            [string]$latestFailure.failureCode)
    }
}
Assert-True (Test-Path -LiteralPath $activePointerPath -PathType Leaf) `
    'phase3b2_physical_p2_v2_completion_pointer_shape_invalid'

$pointer = Get-Content -LiteralPath $activePointerPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$baselineAssessmentUid = '78c37245-ea49-442d-becf-b1e871f98d68'
$baselineMeasurementSha256 =
    '8af3acdf40a741b6998ff0c2f9278a14b7a2c48246798abf1f1e4214d4bf6538'
$baselineBackedInteractiveMode = $pointer.measurementModeCode -ceq
    'verified_ten_minute_baseline_backed_interactive_startup'
$catalogParserExactRunMode = [bool]$pointer.catalogParserExactFormatVerified
$dataPackVersionHeaderRunMode = [bool]$pointer.dataPackVersionHeaderVerified
$resourceHostMapRunMode = [bool]$pointer.resourceHostVersionMapVerified
$catalogProjectionRunMode = [bool]$pointer.catalogVersionProjectionVerified
$catalogSqliteTransportRunMode =
    [bool]$pointer.catalogSqliteTransportVerified
$pointerCatalogProjectionValid = if ($dataPackVersionHeaderRunMode) {
    $catalogParserExactRunMode -and $catalogProjectionRunMode -and
        -not $resourceHostMapRunMode -and
        $pointer.catalogVersionProjectionSha256 -ceq
            '5914cb58fd2146fe761ab531ecb4e321300527186a54b455e59de962ff6c044a' -and
        ((Test-Path -LiteralPath $dataPackVersionHeaderAuthorizationPath `
                -PathType Leaf) -or
            (Test-Path -LiteralPath $catalogHeaderFollowupAuthorizationPath `
                -PathType Leaf))
}
elseif ($resourceHostMapRunMode) {
    $catalogParserExactRunMode -and $catalogProjectionRunMode -and
        $pointer.catalogVersionProjectionSha256 -ceq
            'd7898079fa23b140396a952afc3881b51876827a852aa723492f2a6149ead805' -and
        (Test-Path -LiteralPath $resourceHostMapAuthorizationPath `
            -PathType Leaf)
}
elseif ($catalogParserExactRunMode) {
    $catalogProjectionRunMode -and
        $pointer.catalogVersionProjectionSha256 -ceq
            'd7898079fa23b140396a952afc3881b51876827a852aa723492f2a6149ead805' -and
        (Test-Path -LiteralPath $catalogParserExactAuthorizationPath `
            -PathType Leaf)
}
elseif ($catalogProjectionRunMode) {
    $pointer.catalogVersionProjectionSha256 -ceq
        '63f5ddcd289e55717ed0087b44d673837da14423e28bf363fa5f2092ca1a3502' -and
        (Test-Path -LiteralPath $catalogProjectionAuthorizationPath `
            -PathType Leaf)
}
else { $true }
$pointerMeasurementValid = if ($baselineBackedInteractiveMode) {
    [int]$pointer.minimumMeasurementSeconds -eq 30 -and
        $pointer.baselineTenMinuteMeasurementVerified -and
        $pointer.baselineTenMinuteMeasurementSha256 -ceq
            $baselineMeasurementSha256
}
else {
    $pointer.measurementModeCode -ceq 'full_ten_minute_baseline' -and
        [int]$pointer.minimumMeasurementSeconds -ge 600
}
$pointerCatalogSqliteTransportValid = if ($catalogSqliteTransportRunMode) {
    $dataPackVersionHeaderRunMode -and
        [bool]$pointer.exactCatalogSetVerified -and
        [bool]$pointer.dedicatedCatalogCacheResetApplied -and
        (Test-Path -LiteralPath $catalogSqliteTransportAuthorizationPath `
            -PathType Leaf)
}
else { $true }
Assert-True ($pointer.contractId -ceq
        'nll/phase3b2-physical-p2-v2-active-run-pointer/v1' -and
    $pointerMeasurementValid -and
    $pointerCatalogProjectionValid -and
    $pointerCatalogSqliteTransportValid -and
    $pointer.dedicatedWindowsAccountVerified -and
    $pointer.serverRunning -and $pointer.clientExecutionStarted) `
    'phase3b2_physical_p2_v2_active_pointer_invalid'
$assessmentUid = [string]$pointer.assessmentUid
$runRoot = Join-Path $P2EvidenceRoot $assessmentUid
$protectedRunRoot = Join-Path $SamsungProtectedRoot $assessmentUid
$runStartPath = Join-Path $runRoot 'run-start.receipt.json'
$measurementPath = Join-Path $runRoot 'ten-minute-measurement.receipt.json'
$completionPath = Join-Path $runRoot 'completion.receipt.json'
$databaseBeforePath = Join-Path $runRoot 'db.before.bin'
$databaseAfterPath = Join-Path $runRoot 'db.after-run.bin'
$sqliteObservationPath = Join-Path $runRoot 'sqlite-after-run.json'
$cacheObservationPath = Join-Path $runRoot 'dedicated-locallow-after-run.json'
$priorLatestCompletionPresent = $false
$priorLatestCompletionByteLength = 0L
$priorLatestCompletionSha256 = ''
if (Test-Path -LiteralPath $latestCompletionPath -PathType Leaf) {
    $priorLatestCompletion = Get-Content -LiteralPath $latestCompletionPath `
        -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($priorLatestCompletion.contractId -ceq
            'nll/phase3b2-physical-p2-v2-completion-pointer/v1' -and
        $priorLatestCompletion.assessmentUid -cne $assessmentUid -and
        $priorLatestCompletion.runtimeStopped -and
        $priorLatestCompletion.databaseRestored) `
        'phase3b2_physical_p2_v2_prior_completion_pointer_invalid'
    $priorLatestCompletionArchivePath = Join-Path $runRoot `
        'prior-latest-completion.pointer.json'
    Assert-True (-not (Test-Path -LiteralPath `
            $priorLatestCompletionArchivePath)) `
        'phase3b2_physical_p2_v2_prior_completion_archive_collision'
    [IO.File]::WriteAllBytes($priorLatestCompletionArchivePath,
        [IO.File]::ReadAllBytes($latestCompletionPath))
    $priorLatestCompletionPresent = $true
    $priorLatestCompletionByteLength =
        (Get-Item -LiteralPath $priorLatestCompletionArchivePath).Length
    $priorLatestCompletionSha256 =
        Get-Sha256Hex $priorLatestCompletionArchivePath
}

$runStart = Get-Content -LiteralPath $runStartPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$measurement = Get-Content -LiteralPath $measurementPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$measurementSha256 = Get-Sha256Hex $measurementPath
$fullMeasurementValid =
    $measurement.contractId -ceq
        'nll/phase3b2-physical-p2-v2-ten-minute-measurement/v1' -and
    $measurement.measurementModeCode -ceq 'full_ten_minute_baseline' -and
    [double]$measurement.measuredDurationSeconds -ge 600
$interactiveMeasurementValid =
    $measurement.contractId -ceq
        'nll/phase3b2-physical-p2-v2-startup-health-measurement/v1' -and
    $measurement.measurementModeCode -ceq
        'verified_ten_minute_baseline_backed_interactive_startup' -and
    [double]$measurement.measuredDurationSeconds -ge 30 -and
    [int]$measurement.minimumRequiredSeconds -eq 30 -and
    $measurement.baselineAssessmentUid -ceq $baselineAssessmentUid -and
    $measurement.baselineTenMinuteMeasurementVerified -and
    $measurement.baselineTenMinuteMeasurementSha256 -ceq
        $baselineMeasurementSha256
Assert-True ($runStart.contractId -ceq
        'nll/phase3b2-physical-p2-v2-client-start/v1' -and
    $runStart.assessmentUid -ceq $assessmentUid -and
    $runStart.sailNamedPipeConnected -and
    $runStart.sailNamedPipePayloadWritten -and
    $runStart.sailNamedPipeClosedAfterPayload -and
    $runStart.sailPayloadClearedAfterWrite -and
    $runStart.sailSharedMemoryRetainedForClientLifetime -and
    $runStart.sailHandoffLifecycleCode -ceq
        'payload_then_pipe_eof_shared_memory_retained' -and
    $runStart.measurementReceiptSha256 -ceq $measurementSha256 -and
    $runStart.measurementContractId -ceq $measurement.contractId -and
    $runStart.measurementModeCode -ceq $measurement.measurementModeCode -and
    (($baselineBackedInteractiveMode -and $interactiveMeasurementValid -and
            $runStart.baselineTenMinuteObservationVerified -and
            -not $runStart.minimumTenMinuteObservationCompleted -and
            $runStart.tenMinuteMeasurementReceiptSha256 -ceq
                $baselineMeasurementSha256) -or
        (-not $baselineBackedInteractiveMode -and $fullMeasurementValid -and
            $runStart.minimumTenMinuteObservationCompleted)) -and
    $measurement.assessmentUid -ceq $assessmentUid -and
    $measurement.auditPolicyRestored -and
    $measurement.dnsChannelRestored -and
    [int]$measurement.successfulNonLoopbackConnectionCount -eq 0) `
    'phase3b2_physical_p2_v2_measurement_receipt_invalid'

$serverId = [int]$pointer.serverProcessId
$bootstrapId = [int]$pointer.bootstrapProcessId
$clientId = [int]$pointer.clientProcessId
$server = Get-PinnedProcess $serverId 'EpinelPS'
$bootstrap = Get-PinnedProcess $bootstrapId `
    'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
$client = Get-PinnedProcess $clientId 'nikke'
$clientProcesses = @(Get-Process -Name nikke -ErrorAction SilentlyContinue)
$clientWasRunningAtCompletion = $null -ne $client
Assert-True ($null -ne $server -and $null -ne $bootstrap -and
    (($clientWasRunningAtCompletion -and $clientProcesses.Count -eq 1 -and
            $clientProcesses[0].Id -eq $clientId) -or
        (-not $clientWasRunningAtCompletion -and
            $clientProcesses.Count -eq 0)) -and
    @(Get-Process -Name nikke_launcher `
        -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_physical_p2_v2_completion_runtime_shape_invalid'
$connections = @(Get-NetTCPConnection -ErrorAction SilentlyContinue |
    Where-Object OwningProcess -In @($serverId, $bootstrapId, $clientId))
$successfulNonLoopback = @($connections | Where-Object {
    $_.State -eq 'Established' -and $_.RemoteAddress -and
    $_.RemoteAddress -notin @('0.0.0.0', '127.0.0.1', '::', '::1')
})
Assert-True ($successfulNonLoopback.Count -eq 0) `
    'phase3b2_physical_p2_v2_completion_nonloopback_success_observed'

$serverRoot = Join-Path $EpinelRoot 'EpinelPS\bin\Release\net10.0\win-x64'
$dbPath = Join-Path $serverRoot 'db.json'
$sqlitePaths = @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal') |
    ForEach-Object { Join-Path $serverRoot $_ }
Assert-True (Test-PathDigest $databaseBeforePath 413327L `
    'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194') `
    'phase3b2_physical_p2_v2_completion_database_backup_invalid'

if ($clientWasRunningAtCompletion) {
    Stop-PinnedProcess $clientId 'nikke'
}
Stop-PinnedProcess $bootstrapId 'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
Stop-PinnedProcess $serverId 'EpinelPS'
Start-Sleep -Milliseconds 750
Assert-True ($null -eq (Get-PinnedProcess $clientId 'nikke') -and
    $null -eq (Get-PinnedProcess $bootstrapId `
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap') -and
    $null -eq (Get-PinnedProcess $serverId 'EpinelPS')) `
    'phase3b2_physical_p2_v2_completion_runtime_stop_failed'

[IO.File]::WriteAllBytes($databaseAfterPath, [IO.File]::ReadAllBytes($dbPath))
$sqliteMembers = @($sqlitePaths | Where-Object {
    Test-Path -LiteralPath $_ -PathType Leaf
} | ForEach-Object {
    [ordered]@{
        roleCode = switch ([IO.Path]::GetFileName($_)) {
            'epinelps.db' { 'sqlite_main' }
            'epinelps.db-shm' { 'sqlite_shared_memory' }
            'epinelps.db-wal' { 'sqlite_write_ahead_log' }
        }
        byteLength = (Get-Item -LiteralPath $_).Length
        sha256 = Get-Sha256Hex $_
    }
})
$sqliteObservation = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-physical-p2-v2-sqlite-after-run/v1'
    observedAtUtc =
        [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    assessmentUid = $assessmentUid
    memberCount = $sqliteMembers.Count
    members = $sqliteMembers
    cleanupCompleted = $false
}
Write-AtomicUtf8NoBom $sqliteObservationPath `
    (($sqliteObservation | ConvertTo-Json -Depth 7) + "`n")
foreach ($path in $sqlitePaths) {
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Remove-Item -LiteralPath $path -Force
    }
}
Assert-True (@($sqlitePaths | Where-Object {
    Test-Path -LiteralPath $_
}).Count -eq 0) 'phase3b2_physical_p2_v2_sqlite_cleanup_failed'
[IO.File]::WriteAllBytes($dbPath, [IO.File]::ReadAllBytes($databaseBeforePath))
Assert-True (Test-PathDigest $dbPath 413327L `
    'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194') `
    'phase3b2_physical_p2_v2_database_restore_failed'

$localLowRoot = Join-Path $profileRoot 'AppData\LocalLow'
$localLowFiles = @(Get-ChildItem -LiteralPath $localLowRoot -File -Recurse `
    -Force -ErrorAction SilentlyContinue)
$cacheCandidates = @(Get-ChildItem -LiteralPath $localLowRoot -Directory `
    -Recurse -Force -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match '(?i)nikke|shift[ _-]*up|level[ _-]*infinite'
    })
$cacheObservation = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-physical-p2-v2-dedicated-locallow-after-run/v1'
    observedAtUtc =
        [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    assessmentUid = $assessmentUid
    profileRoleCode = 'dedicated_nlloperator_profile'
    totalFileCount = $localLowFiles.Count
    totalContentByteLength = [long](($localLowFiles |
        Measure-Object Length -Sum).Sum)
    candidateCacheDirectoryCount = $cacheCandidates.Count
    cacheDeletionPerformed = $false
    existingOperatorProfileInspected = $false
    existingOperatorNikkeCacheMutationPerformed = $false
}
Write-AtomicUtf8NoBom $cacheObservationPath `
    (($cacheObservation | ConvertTo-Json -Depth 6) + "`n")

$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$hostsBackupPath = Join-Path $BackupRoot 'hosts.before.bin'
$extensionRules = @(Get-NetFirewallRule -Group $extensionFirewallGroup `
    -ErrorAction SilentlyContinue)
Assert-True ($extensionRules.Count -eq 1 -and
    (Test-PathDigest $hostsBackupPath 1690L `
        'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0')) `
    'phase3b2_physical_p2_v2_rollback_precondition_invalid'
$extensionRules | Remove-NetFirewallRule
[IO.File]::WriteAllBytes($hostsPath,
    [IO.File]::ReadAllBytes($hostsBackupPath))
Assert-True (@(Get-NetFirewallRule -Group $extensionFirewallGroup `
        -ErrorAction SilentlyContinue).Count -eq 0 -and
    @(Get-NetFirewallRule -Group 'NLL Phase3B2 Physical Isolation' `
        -ErrorAction SilentlyContinue).Count -eq 17 -and
    (Test-PathDigest $hostsPath 1690L `
        'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0')) `
    'phase3b2_physical_p2_v2_extension_rollback_failed'

if ($dataPackVersionHeaderRunMode) {
    Assert-True ((Test-Path -LiteralPath `
                $dataPackVersionHeaderAuthorizationPath -PathType Leaf) -or
            (Test-Path -LiteralPath `
                $catalogHeaderFollowupAuthorizationPath -PathType Leaf)) `
        'phase3b2_physical_p2_v2_datapack_header_authorization_missing'
    $catalogProjectionPath = Join-Path $serverRoot `
        'cache\prdenv\150-b059c3f36c\StandaloneWindows64\pck\latest-651.txt'
    Assert-True (Test-PathDigest $catalogProjectionPath 139L `
            '5914cb58fd2146fe761ab531ecb4e321300527186a54b455e59de962ff6c044a') `
        'phase3b2_physical_p2_v2_datapack_header_rollback_pin_invalid'
    Remove-Item -LiteralPath $catalogProjectionPath -Force
    Assert-True (-not (Test-Path -LiteralPath $catalogProjectionPath)) `
        'phase3b2_physical_p2_v2_datapack_header_rollback_failed'
    $catalogProjectionRolledBack = $true
}
elseif ($catalogParserExactRunMode) {
    $requiredAuthorizationPath = if ($resourceHostMapRunMode) {
        $resourceHostMapAuthorizationPath
    }
    else { $catalogParserExactAuthorizationPath }
    Assert-True (Test-Path -LiteralPath $requiredAuthorizationPath `
            -PathType Leaf) `
        'phase3b2_physical_p2_v2_catalog_parser_exact_authorization_missing'
    $catalogProjectionPath = Join-Path $serverRoot `
        'cache\prdenv\150-b059c3f36c\StandaloneWindows64\pck\latest-651.txt'
    Assert-True (Test-PathDigest $catalogProjectionPath 131L `
            'd7898079fa23b140396a952afc3881b51876827a852aa723492f2a6149ead805') `
        'phase3b2_physical_p2_v2_catalog_parser_exact_rollback_pin_invalid'
    Remove-Item -LiteralPath $catalogProjectionPath -Force
    Assert-True (-not (Test-Path -LiteralPath $catalogProjectionPath)) `
        'phase3b2_physical_p2_v2_catalog_parser_exact_rollback_failed'
    $catalogProjectionRolledBack = $true
}
elseif ($catalogProjectionRunMode) {
    Assert-True (Test-Path -LiteralPath $catalogProjectionAuthorizationPath `
            -PathType Leaf) `
        'phase3b2_physical_p2_v2_catalog_projection_authorization_missing'
    $catalogProjectionPath = Join-Path $serverRoot `
        'cache\prdenv\150-b059c3f36c\StandaloneWindows64\pck\latest-651.txt'
    Assert-True (Test-PathDigest $catalogProjectionPath 132L `
            '63f5ddcd289e55717ed0087b44d673837da14423e28bf363fa5f2092ca1a3502') `
        'phase3b2_physical_p2_v2_catalog_projection_rollback_pin_invalid'
    Remove-Item -LiteralPath $catalogProjectionPath -Force
    Assert-True (-not (Test-Path -LiteralPath $catalogProjectionPath)) `
        'phase3b2_physical_p2_v2_catalog_projection_rollback_failed'
    $catalogProjectionRolledBack = $true
}

$contextPath =
    'C:\NLL\Evidence\Phase3B2\Physical\server-profile-v1\identity\synthetic-context.json'
$context = Get-Content -LiteralPath $contextPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$md5 = [Security.Cryptography.MD5]::Create()
try {
    $passwordHash = (($md5.ComputeHash(
        [Text.Encoding]::ASCII.GetBytes([string]$context.password)) |
        ForEach-Object { $_.ToString('x2') }) -join '')
}
finally { $md5.Dispose() }
$logText = ''
foreach ($path in @((Join-Path $runRoot 'server.stdout.log'),
        (Join-Path $runRoot 'server.stderr.log'),
        (Join-Path $runRoot 'server-request-stage.jsonl'))) {
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $logText += [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
    }
}
$sensitiveValues = @([string]$context.accountId,
    [string]$context.managerId, [string]$context.username,
    [string]$context.password, $passwordHash,
    'C:\NLL', 'C:\NIKKE', 'E:\Recovered_OldSSD')
$rawSensitiveLogMatchCount = @($sensitiveValues | Where-Object {
    $_ -and $logText.IndexOf($_,
        [StringComparison]::OrdinalIgnoreCase) -ge 0
}).Count

$completion = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-physical-p2-v2-client-completion/v1'
    completedAtUtc =
        [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    assessmentUid = $assessmentUid
    runStartReceiptSha256 = Get-Sha256Hex $runStartPath
    measurementContractId = [string]$measurement.contractId
    measurementModeCode = [string]$measurement.measurementModeCode
    measurementReceiptSha256 = $measurementSha256
    measurementDurationSeconds =
        [double]$measurement.measuredDurationSeconds
    tenMinuteMeasurementReceiptSha256 = if (
            $baselineBackedInteractiveMode) {
        $baselineMeasurementSha256
    }
    else { $measurementSha256 }
    minimumTenMinuteObservationCompleted =
        (-not $baselineBackedInteractiveMode)
    baselineTenMinuteObservationVerified =
        $baselineBackedInteractiveMode
    baselineAssessmentUid = if ($baselineBackedInteractiveMode) {
        $baselineAssessmentUid
    }
    else { '' }
    liveRuntimeFilesCollectedAfterStop = $true
    successfulNonLoopbackConnectionCount = 0
    sailNamedPipePayloadWritten = $true
    sailNamedPipeClosedAfterPayload = $true
    sailSharedMemoryRetainedForClientLifetime = $true
    sailHandoffLifecycleCode =
        'payload_then_pipe_eof_shared_memory_retained'
    clientWasRunningAtCompletion = $clientWasRunningAtCompletion
    clientExitObservationCode = if ($clientWasRunningAtCompletion) {
        'completion_requested_process_stop'
    }
    else { 'operator_or_natural_exit_before_completion' }
    dataPackVersionHeaderVerified = $dataPackVersionHeaderRunMode
    exactCatalogSetVerified = [bool]$pointer.exactCatalogSetVerified
    catalogSqliteTransportVerified = $catalogSqliteTransportRunMode
    dedicatedCatalogCacheResetApplied =
        [bool]$pointer.dedicatedCatalogCacheResetApplied
    dedicatedCachePreservedAfterAuthorizedReset =
        $catalogSqliteTransportRunMode
    priorLatestCompletionPointerPreserved = $priorLatestCompletionPresent
    priorLatestCompletionPointerByteLength =
        $priorLatestCompletionByteLength
    priorLatestCompletionPointerSha256 = $priorLatestCompletionSha256
    rawSensitiveLogMatchCount = $rawSensitiveLogMatchCount
    dedicatedLocalLowObservationByteLength =
        (Get-Item $cacheObservationPath).Length
    dedicatedLocalLowObservationSha256 = Get-Sha256Hex $cacheObservationPath
    dedicatedCachePreserved = $true
    existingOperatorProfileInspected = $false
    existingOperatorNikkeCacheMutationPerformed = $false
    runtimeStopped = $true
    databaseRestored = $true
    sqliteRuntimeRemoved = $true
    p2V2HostsExtensionRolledBack = $true
    p2V2FirewallExtensionRolledBack = $true
    catalogVersionProjectionRolledBack = $catalogProjectionRolledBack
    baseP0Preserved = $true
    primaryInstallModified = $false
    officialLauncherModified = $false
    officialLauncherExecutionStarted = $false
    antiCheatSubstitutionApplied = $false
    clientExecutionStarted = $true
    officialIdentityPersisted = $false
    officialCredentialPersisted = $false
    verdict = if ($rawSensitiveLogMatchCount -eq 0) {
        'physical_p2_v2_observation_completed_runtime_restored'
    } else { 'physical_p2_v2_completed_with_log_safety_failure' }
    nextStepCode = 'return_to_samsung_and_classify_p2_v2_observations'
}
Write-AtomicUtf8NoBom $completionPath `
    (($completion | ConvertTo-Json -Depth 8) + "`n")

$protectedMembers = @(Get-ChildItem -LiteralPath $runRoot -File |
    Select-Object -ExpandProperty FullName)
foreach ($path in $protectedMembers) {
    Copy-Item -LiteralPath $path -Destination $protectedRunRoot -Force
    $copy = Join-Path $protectedRunRoot (Split-Path -Leaf $path)
    Assert-True ((Get-Sha256Hex $copy) -ceq (Get-Sha256Hex $path)) `
        'phase3b2_physical_p2_v2_completion_protected_copy_failed'
}
$latest = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-physical-p2-v2-completion-pointer/v1'
    assessmentUid = $assessmentUid
    completionReceiptByteLength = (Get-Item $completionPath).Length
    completionReceiptSha256 = Get-Sha256Hex $completionPath
    verdict = $completion.verdict
    runtimeStopped = $true
    databaseRestored = $true
    clientExecutionStarted = $true
}
Write-AtomicUtf8NoBom $latestCompletionPath `
    (($latest | ConvertTo-Json -Depth 6) + "`n")
Copy-Item -LiteralPath $latestCompletionPath -Destination $protectedRunRoot -Force
Remove-Item -LiteralPath $activePointerPath -Force
Assert-True ($rawSensitiveLogMatchCount -eq 0) `
    'phase3b2_physical_p2_v2_sensitive_log_exposure'
$completion | ConvertTo-Json -Depth 9
