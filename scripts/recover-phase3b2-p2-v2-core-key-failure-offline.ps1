[CmdletBinding()]
param(
    [string]$MicronDrive = 'E:',
    [string]$AssessmentUid =
        'cf8433fe-ea3d-4594-94d3-863bd0846cd3',
    [string]$ScreenshotPath,
    [string]$SamsungProtectedRoot =
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\RunsV2',
    [switch]$AllowVerifiedNonAdministratorOfflineMutation
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

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

$isAdministrator = [Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
Assert-True ($isAdministrator -or
    $AllowVerifiedNonAdministratorOfflineMutation.IsPresent) `
    'phase3b2_core_key_recovery_requires_administrator'

$micronLetter = $MicronDrive.TrimEnd(':')
$systemDisk = Get-Partition -DriveLetter C | Get-Disk
$micronDisk = Get-Partition -DriveLetter $micronLetter | Get-Disk
Assert-True ($systemDisk.FriendlyName -ceq 'Samsung SSD 980 1TB' -and
    $systemDisk.IsBoot -and $systemDisk.IsSystem -and
    $micronDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK' -and
    -not $micronDisk.IsBoot -and -not $micronDisk.IsSystem) `
    'phase3b2_core_key_recovery_disk_boundary_invalid'
Assert-True (@(Get-Process -Name EpinelPS, nikke, nikke_launcher,
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap' `
        -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_core_key_recovery_runtime_not_cold'

$p2Root = Join-Path $MicronDrive `
    'NLL\Evidence\Phase3B2\Physical\p2-client-start-v2'
$runRoot = Join-Path $p2Root $AssessmentUid
$activePointerPath = Join-Path $p2Root 'active-run.pointer.json'
$consumptionPath = Join-Path $p2Root `
    'catalog-parser-exact-retry.consumed.json'
$runStartPath = Join-Path $runRoot 'run-start.receipt.json'
$measurementPath = Join-Path $runRoot 'ten-minute-measurement.receipt.json'
$databaseBeforePath = Join-Path $runRoot 'db.before.bin'
$requestStagePath = Join-Path $runRoot 'server-request-stage.jsonl'
$bootstrapExitPath = Join-Path $runRoot 'bootstrap-exit.receipt.json'
$playerLogPath = Join-Path $MicronDrive `
    'Users\nlloperator\AppData\LocalLow\com.proximabeta\NIKKE\Player.log'
$archivedPointerPath = Join-Path $runRoot `
    'active-run.before-core-key-cold-recovery.json'
$databaseAfterFailurePath = Join-Path $runRoot `
    'db.after-core-key-failure.bin'
$failureReceiptPath = Join-Path $runRoot 'core-key-failure.receipt.json'
$recoveryReceiptPath = Join-Path $runRoot `
    'core-key-cold-recovery.receipt.json'
$latestFailurePath = Join-Path $p2Root `
    'latest-core-key-failure.pointer.json'
$protectedRunRoot = Join-Path $SamsungProtectedRoot $AssessmentUid

if ([string]::IsNullOrWhiteSpace($ScreenshotPath)) {
    $screenshotRoot = Join-Path $MicronDrive `
        'Users\nlloperator\Pictures\Screenshots'
    $screenshotMatches = @(Get-ChildItem -LiteralPath $screenshotRoot `
            -File -Filter '*.png' -ErrorAction Stop | Where-Object {
            $_.Length -eq 435095L -and
            (Get-Sha256Hex $_.FullName) -ceq
                '58e9f5e4ef52b4871b6aac769a837da7761e5722e35ebe7d44ce2ac183e571c2'
        })
    Assert-True ($screenshotMatches.Count -eq 1) `
        'phase3b2_core_key_recovery_screenshot_resolution_invalid'
    $ScreenshotPath = $screenshotMatches[0].FullName
}

$requiredPaths = @($activePointerPath, $consumptionPath, $runStartPath,
    $measurementPath, $databaseBeforePath, $requestStagePath,
    $bootstrapExitPath, $playerLogPath, $ScreenshotPath)
$missingRequiredPaths = @($requiredPaths | Where-Object {
    -not (Test-Path -LiteralPath $_ -PathType Leaf)
})
$preexistingOutputPaths = @(
    @($archivedPointerPath, $failureReceiptPath, $recoveryReceiptPath) |
        Where-Object { Test-Path -LiteralPath $_ }
)
$databaseAfterFailurePresent = Test-Path -LiteralPath `
    $databaseAfterFailurePath -PathType Leaf
$databaseAfterFailureValid = -not $databaseAfterFailurePresent -or
    (Test-PathDigest $databaseAfterFailurePath 413329L `
        'e524a3c8967af6bb8447fda0c50fc8a86ebccd02e1d1a45df73b2625430acc8d')
if ($missingRequiredPaths.Count -ne 0 -or
    $preexistingOutputPaths.Count -ne 0 -or
    -not $databaseAfterFailureValid) {
    $missingNames = @($missingRequiredPaths | ForEach-Object {
        Split-Path -Leaf $_
    }) -join ','
    $preexistingNames = @($preexistingOutputPaths | ForEach-Object {
        Split-Path -Leaf $_
    }) -join ','
    throw ('phase3b2_core_key_recovery_evidence_shape_invalid:' +
        "missing=[$missingNames];preexisting=[$preexistingNames];" +
        "database_after_valid=$databaseAfterFailureValid")
}

Assert-True ((Test-PathDigest $activePointerPath 1240L `
        'c0fdf24657331f2163ba0df1fabe357d98498e790b4d547b9c515c96e470f0ba') -and
    (Test-PathDigest $consumptionPath 1022L `
        'da5c1a73d878b6c5eb2c11d0bb2063a2f1d51eb10c9320bfc4c9fad112a8099e') -and
    (Test-PathDigest $runStartPath 2545L `
        '6396d5094768f5daa1ae6a6ac6726913e878a6a425b8d4cfff6d49e7c3de8c70') -and
    (Test-PathDigest $measurementPath 3010L `
        'c6756ddfc941298e3c6692960d61f6f5023f21d1ecac89344dabe60d51217229') -and
    (Test-PathDigest $databaseBeforePath 413327L `
        'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194') -and
    (Test-PathDigest $requestStagePath 11978L `
        '5c102fadc84ef59320f7790f73b236ba56262a56d309881af1cf222f0d957d98') -and
    (Test-PathDigest $bootstrapExitPath 386L `
        '5d012afbe71bcf951d9c092cbdaa0d51689ecf75e5a41862fec769ea3e5e0116') -and
    (Test-PathDigest $playerLogPath 53613L `
        'f5a5957da14c5706ffbe7a09aff23f8b869f6d47a3579e7e61822a2a3a622b94') -and
    (Test-PathDigest $ScreenshotPath 435095L `
        '58e9f5e4ef52b4871b6aac769a837da7761e5722e35ebe7d44ce2ac183e571c2')) `
    'phase3b2_core_key_recovery_evidence_pin_invalid'

$pointer = Get-Content -LiteralPath $activePointerPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$consumption = Get-Content -LiteralPath $consumptionPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$runStart = Get-Content -LiteralPath $runStartPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($pointer.contractId -ceq
        'nll/phase3b2-physical-p2-v2-active-run-pointer/v1' -and
    $pointer.assessmentUid -ceq $AssessmentUid -and
    $pointer.catalogParserExactFormatVerified -and
    $pointer.catalogVersionProjectionSha256 -ceq
        'd7898079fa23b140396a952afc3881b51876827a852aa723492f2a6149ead805' -and
    $consumption.contractId -ceq
        'nll/phase3b2-p2-v2-catalog-parser-exact-retry-consumption/v1' -and
    $consumption.assessmentUid -ceq $AssessmentUid -and
    $consumption.singleRetryConsumed -and
    $runStart.assessmentUid -ceq $AssessmentUid -and
    $runStart.dedicatedCacheStateCode -ceq
        'preserved_catalog_parser_exact_retry') `
    'phase3b2_core_key_recovery_contract_invalid'

$playerLogBytes = [IO.File]::ReadAllBytes($playerLogPath)
$playerLogText = [Text.UTF8Encoding]::new($false, $false).GetString(
    $playerLogBytes)
$requiredSignals = @(
    "KeyNotFoundException: The given key 'core' was not present in the dictionary.",
    'NK.Addressable.Host.<GetVersion>g__MakeCatalogGroup|13_0',
    'NK.Addressable.Manager.ProcessHosts',
    'NK.GameInitialize.CatalogUpdateEntry.InitializeAsync'
)
Assert-True (@($requiredSignals | Where-Object {
    $playerLogText.IndexOf($_, [StringComparison]::Ordinal) -lt 0
}).Count -eq 0) 'phase3b2_core_key_recovery_player_signal_missing'

$stageRecords = @(Get-Content -LiteralPath $requestStagePath -Encoding UTF8 |
    Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
$assetSuccessCount = @($stageRecords | Where-Object {
    $_.transitionCode -ceq 'request_completed' -and
    $_.requestStageCode -ceq 'asset_prdenv' -and
    [int]$_.httpStatusCode -eq 200
}).Count
Assert-True ($assetSuccessCount -eq 2) `
    'phase3b2_core_key_recovery_asset_response_shape_invalid'

$serverRoot = Join-Path $MicronDrive `
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
$databasePath = Join-Path $serverRoot 'db.json'
$sqlitePaths = @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal') |
    ForEach-Object { Join-Path $serverRoot $_ }
$projectionPath = Join-Path $serverRoot `
    'cache\prdenv\150-b059c3f36c\StandaloneWindows64\pck\latest-651.txt'
$hostsPath = Join-Path $MicronDrive 'Windows\System32\drivers\etc\hosts'
$hostsBackupPath = Join-Path $MicronDrive `
    'NLL\Backups\Phase3B2\PhysicalP2-v2\hosts.before.bin'
$initialRuntimeState =
    (Test-PathDigest $databasePath 413329L `
        'e524a3c8967af6bb8447fda0c50fc8a86ebccd02e1d1a45df73b2625430acc8d') -and
    -not (Test-Path -LiteralPath $databaseAfterFailurePath)
$partialRecoveryState =
    (Test-PathDigest $databasePath 413327L `
        'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194') -and
    (Test-PathDigest $databaseAfterFailurePath 413329L `
        'e524a3c8967af6bb8447fda0c50fc8a86ebccd02e1d1a45df73b2625430acc8d') -and
    @($sqlitePaths | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0
Assert-True (($initialRuntimeState -or $partialRecoveryState) -and
    (Test-PathDigest $projectionPath 131L `
        'd7898079fa23b140396a952afc3881b51876827a852aa723492f2a6149ead805') -and
    (Test-PathDigest $hostsPath 1727L `
        '3b0dcc4396373e9e9d623ef05c345f89330427ad5128727290c9f76138e22f64') -and
    (Test-PathDigest $hostsBackupPath 1690L `
        'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0')) `
    'phase3b2_core_key_recovery_runtime_state_invalid'

if ($initialRuntimeState) {
    [IO.File]::WriteAllBytes(
        $databaseAfterFailurePath, [IO.File]::ReadAllBytes($databasePath))
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
    foreach ($path in $sqlitePaths) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force
        }
    }
    [IO.File]::WriteAllBytes(
        $databasePath, [IO.File]::ReadAllBytes($databaseBeforePath))
}
else {
    $sqliteMembers = @(
        [ordered]@{
            roleCode = 'sqlite_main'
            byteLength = 4096L
            sha256 = '5c9dec1886cc01f5f2307ee1ea87f9b32a4cef0f8f9a2c68beebc558013bedab'
        },
        [ordered]@{
            roleCode = 'sqlite_shared_memory'
            byteLength = 32768L
            sha256 = '0642355dbe966fb845ce39254b59595549980aedc324fd9aea38e8f5eb0c657c'
        },
        [ordered]@{
            roleCode = 'sqlite_write_ahead_log'
            byteLength = 111272L
            sha256 = '5cb2d0d381c90e75da19097df5b6bb426f57639badb28b4d4732e95e961ca960'
        }
    )
}
[IO.File]::WriteAllBytes(
    $hostsPath, [IO.File]::ReadAllBytes($hostsBackupPath))
Remove-Item -LiteralPath $projectionPath -Force
Assert-True ((Get-Sha256Hex $databasePath) -ceq
        'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194' -and
    (Get-Sha256Hex $hostsPath) -ceq
        'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0' -and
    @($sqlitePaths | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0 -and
    -not (Test-Path -LiteralPath $projectionPath)) `
    'phase3b2_core_key_recovery_rollback_failed'

Copy-Item -LiteralPath $activePointerPath -Destination $archivedPointerPath
Assert-True ((Get-Sha256Hex $archivedPointerPath) -ceq
    (Get-Sha256Hex $activePointerPath)) `
    'phase3b2_core_key_recovery_pointer_archive_failed'

$failure = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-p2-v2-core-key-failure/v1'
    failedAtUtc =
        [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    assessmentUid = $AssessmentUid
    failureStageCode = 'catalogue_resource_path_upgrade'
    reasonCode = 'addressable_catalog_group_core_key_missing'
    priorProjectionParserFailureResolved = $true
    assetPrdenvSuccessfulResponseCount = $assetSuccessCount
    projectedBodyByteLength = 131
    projectedBodySha256 =
        'd7898079fa23b140396a952afc3881b51876827a852aa723492f2a6149ead805'
    playerExceptionType = 'System.Collections.Generic.KeyNotFoundException'
    missingDictionaryKeyCode = 'core'
    playerMethodCode = 'nk_addressable_host_make_catalog_group'
    playerLogByteLength = $playerLogBytes.LongLength
    playerLogSha256 = Get-Sha256Hex $playerLogPath
    rawPlayerLogCopied = $false
    screenshotByteLength = (Get-Item -LiteralPath $ScreenshotPath).Length
    screenshotSha256 = Get-Sha256Hex $ScreenshotPath
    rawScreenshotCopied = $false
    upstreamIssueCode = 'epinelps_issue_41_same_4_of_7_stage'
    officialOutboundUsed = $false
    officialIdentityPersisted = $false
    officialCredentialPersisted = $false
    nextStepCode = 'classify_content_version_to_host_catalog_group_contract'
}
Write-AtomicUtf8NoBom $failureReceiptPath `
    (($failure | ConvertTo-Json -Depth 7) + "`n")

$recovery = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-p2-v2-core-key-cold-recovery/v1'
    recoveredAtUtc =
        [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    failedAssessmentUid = $AssessmentUid
    failureReceiptByteLength = (Get-Item $failureReceiptPath).Length
    failureReceiptSha256 = Get-Sha256Hex $failureReceiptPath
    runtimeColdAtRecovery = $true
    databaseAfterFailureByteLength =
        (Get-Item $databaseAfterFailurePath).Length
    databaseAfterFailureSha256 = Get-Sha256Hex $databaseAfterFailurePath
    databaseRestored = $true
    partialRecoveryResumed = $partialRecoveryState
    sqliteRuntimeObservedMemberCount = $sqliteMembers.Count
    sqliteRuntimeMembers = $sqliteMembers
    sqliteRuntimeRemoved = $true
    exactProjectionRemoved = $true
    p2V2HostsExtensionRolledBack = $true
    p2V2FirewallExtensionRollbackDeferredToMicronBoot = $true
    retryConsumptionPreserved = $true
    retryConsumptionSha256 = Get-Sha256Hex $consumptionPath
    dedicatedNllOperatorCacheModified = $false
    primaryInstallModified = $false
    officialLauncherModified = $false
    officialOutboundUsed = $false
    officialIdentityPersisted = $false
    officialCredentialPersisted = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
    nextStepCode = 'resolve_core_host_group_contract_before_new_retry'
}
Write-AtomicUtf8NoBom $recoveryReceiptPath `
    (($recovery | ConvertTo-Json -Depth 8) + "`n")

New-Item -ItemType Directory -Path $protectedRunRoot -Force | Out-Null
foreach ($path in @($failureReceiptPath, $recoveryReceiptPath,
        $archivedPointerPath, $databaseAfterFailurePath)) {
    Copy-Item -LiteralPath $path -Destination $protectedRunRoot -Force
    $copy = Join-Path $protectedRunRoot (Split-Path -Leaf $path)
    Assert-True ((Get-Sha256Hex $copy) -ceq (Get-Sha256Hex $path)) `
        'phase3b2_core_key_recovery_protected_copy_failed'
}

$latest = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-p2-v2-core-key-failure-pointer/v1'
    assessmentUid = $AssessmentUid
    failureReceiptByteLength = (Get-Item $failureReceiptPath).Length
    failureReceiptSha256 = Get-Sha256Hex $failureReceiptPath
    recoveryReceiptByteLength = (Get-Item $recoveryReceiptPath).Length
    recoveryReceiptSha256 = Get-Sha256Hex $recoveryReceiptPath
    retryConsumed = $true
    runtimeCold = $true
    nextStepCode = 'resolve_core_host_group_contract_before_new_retry'
}
Write-AtomicUtf8NoBom $latestFailurePath `
    (($latest | ConvertTo-Json -Depth 6) + "`n")
Copy-Item -LiteralPath $latestFailurePath -Destination $protectedRunRoot -Force
Remove-Item -LiteralPath $activePointerPath -Force
Assert-True (-not (Test-Path -LiteralPath $activePointerPath)) `
    'phase3b2_core_key_recovery_pointer_retirement_failed'

[pscustomobject]@{
    Receipt = $recovery
    FailureReceiptByteLength = (Get-Item $failureReceiptPath).Length
    FailureReceiptSha256 = Get-Sha256Hex $failureReceiptPath
    RecoveryReceiptByteLength = (Get-Item $recoveryReceiptPath).Length
    RecoveryReceiptSha256 = Get-Sha256Hex $recoveryReceiptPath
    ProtectedRunRoot = $protectedRunRoot
} | ConvertTo-Json -Depth 9
