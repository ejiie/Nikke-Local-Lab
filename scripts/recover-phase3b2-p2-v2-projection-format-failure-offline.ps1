[CmdletBinding()]
param(
    [string]$MicronDrive = 'E:',
    [string]$AssessmentUid =
        'f7e2bb4a-e661-42bf-b055-d0b2c8a536d3',
    [string]$ScreenshotPath =
        'E:\Users\nlloperator\Pictures\Screenshots\스크린샷 2026-08-23 205258.png',
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
    'phase3b2_projection_format_recovery_requires_administrator'

$micronLetter = $MicronDrive.TrimEnd(':')
$systemDisk = Get-Partition -DriveLetter C | Get-Disk
$micronDisk = Get-Partition -DriveLetter $micronLetter | Get-Disk
Assert-True ($systemDisk.FriendlyName -ceq 'Samsung SSD 980 1TB' -and
    $systemDisk.IsBoot -and $systemDisk.IsSystem -and
    $micronDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK' -and
    -not $micronDisk.IsBoot -and -not $micronDisk.IsSystem) `
    'phase3b2_projection_format_recovery_disk_boundary_invalid'
Assert-True (@(Get-Process -Name EpinelPS, nikke, nikke_launcher,
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap' `
        -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_projection_format_recovery_runtime_not_cold'

$p2Root = Join-Path $MicronDrive `
    'NLL\Evidence\Phase3B2\Physical\p2-client-start-v2'
$runRoot = Join-Path $p2Root $AssessmentUid
$activePointerPath = Join-Path $p2Root 'active-run.pointer.json'
$consumptionPath = Join-Path $p2Root `
    'catalog-version-projection-retry.consumed.json'
$runStartPath = Join-Path $runRoot 'run-start.receipt.json'
$measurementPath = Join-Path $runRoot 'ten-minute-measurement.receipt.json'
$databaseBeforePath = Join-Path $runRoot 'db.before.bin'
$requestStagePath = Join-Path $runRoot 'server-request-stage.jsonl'
$wfpPath = Join-Path $runRoot 'wfp-observation.json'
$playerLogPath = Join-Path $MicronDrive `
    'Users\nlloperator\AppData\LocalLow\com.proximabeta\NIKKE\Player.log'
$archivedPointerPath = Join-Path $runRoot `
    'active-run.before-projection-format-cold-recovery.json'
$databaseAfterFailurePath = Join-Path $runRoot `
    'db.after-projection-format-failure.bin'
$failureReceiptPath = Join-Path $runRoot `
    'projection-format-failure.receipt.json'
$recoveryReceiptPath = Join-Path $runRoot `
    'projection-format-cold-recovery.receipt.json'
$latestFailurePath = Join-Path $p2Root `
    'latest-projection-format-failure.pointer.json'
$protectedRunRoot = Join-Path $SamsungProtectedRoot $AssessmentUid

Assert-True ((Test-Path -LiteralPath $activePointerPath -PathType Leaf) -and
    (Test-Path -LiteralPath $consumptionPath -PathType Leaf) -and
    (Test-Path -LiteralPath $runStartPath -PathType Leaf) -and
    (Test-Path -LiteralPath $measurementPath -PathType Leaf) -and
    (Test-Path -LiteralPath $requestStagePath -PathType Leaf) -and
    (Test-Path -LiteralPath $wfpPath -PathType Leaf) -and
    (Test-Path -LiteralPath $playerLogPath -PathType Leaf) -and
    (Test-Path -LiteralPath $ScreenshotPath -PathType Leaf) -and
    -not (Test-Path -LiteralPath $archivedPointerPath) -and
    -not (Test-Path -LiteralPath $failureReceiptPath) -and
    -not (Test-Path -LiteralPath $recoveryReceiptPath)) `
    'phase3b2_projection_format_recovery_evidence_shape_invalid'

$pointer = Get-Content -LiteralPath $activePointerPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$consumption = Get-Content -LiteralPath $consumptionPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$runStart = Get-Content -LiteralPath $runStartPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$wfp = Get-Content -LiteralPath $wfpPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($pointer.contractId -ceq
        'nll/phase3b2-physical-p2-v2-active-run-pointer/v1' -and
    $pointer.assessmentUid -ceq $AssessmentUid -and
    $pointer.runStartReceiptSha256 -ceq (Get-Sha256Hex $runStartPath) -and
    $pointer.measurementReceiptSha256 -ceq
        (Get-Sha256Hex $measurementPath) -and
    $pointer.catalogVersionProjectionVerified -and
    $pointer.catalogVersionProjectionSha256 -ceq
        '63f5ddcd289e55717ed0087b44d673837da14423e28bf363fa5f2092ca1a3502' -and
    $consumption.contractId -ceq
        'nll/phase3b2-p2-v2-catalog-version-projection-retry-consumption/v1' -and
    $consumption.assessmentUid -ceq $AssessmentUid -and
    $consumption.singleRetryConsumed -and
    $runStart.assessmentUid -ceq $AssessmentUid -and
    $runStart.dedicatedCacheStateCode -ceq
        'preserved_catalog_version_projection_retry' -and
    [int]$wfp.allowedNonLoopbackCount -eq 0) `
    'phase3b2_projection_format_recovery_contract_invalid'

$stageRecords = @(Get-Content -LiteralPath $requestStagePath -Encoding UTF8 |
    Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
$assetSuccessCount = @($stageRecords | Where-Object {
    $_.transitionCode -ceq 'request_completed' -and
    $_.requestStageCode -ceq 'asset_prdenv' -and
    [int]$_.httpStatusCode -eq 200
}).Count
$localNotFoundCount = @($stageRecords | Where-Object {
    $_.transitionCode -ceq 'request_completed' -and
    [int]$_.httpStatusCode -eq 404
}).Count
Assert-True ($assetSuccessCount -ge 1) `
    'phase3b2_projection_format_recovery_asset_200_missing'

$playerLogBytes = [IO.File]::ReadAllBytes($playerLogPath)
$playerLogText = [Text.UTF8Encoding]::new($false, $false).GetString(
    $playerLogBytes)
$requiredSignals = @(
    'GetVersionAsync failed: https://cloud.nikke-kr.com/prdenv/150-b059c3f36c/StandaloneWindows64/pck/latest-651.txt',
    'ArgumentOutOfRangeException: Length cannot be less than zero.',
    'System.String.Substring',
    'ContentVersion2+DataPackEntry.GetVersionAsync'
)
Assert-True (@($requiredSignals | Where-Object {
    $playerLogText.IndexOf($_, [StringComparison]::Ordinal) -lt 0
}).Count -eq 0) 'phase3b2_projection_format_recovery_player_signal_missing'

$serverRoot = Join-Path $MicronDrive `
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
$databasePath = Join-Path $serverRoot 'db.json'
$sqlitePaths = @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal') |
    ForEach-Object { Join-Path $serverRoot $_ }
$projectionPath = Join-Path $serverRoot `
    'cache\prdenv\150-b059c3f36c\StandaloneWindows64\pck\latest-651.txt'
Assert-True (Test-PathDigest $databaseBeforePath 413327L `
        'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194') `
    'phase3b2_projection_format_recovery_database_backup_invalid'
Assert-True ((Test-Path -LiteralPath $databasePath -PathType Leaf) -and
    (Test-PathDigest $projectionPath 132L `
        '63f5ddcd289e55717ed0087b44d673837da14423e28bf363fa5f2092ca1a3502')) `
    'phase3b2_projection_format_recovery_runtime_state_invalid'

[IO.File]::WriteAllBytes(
    $databaseAfterFailurePath, [IO.File]::ReadAllBytes($databasePath))
$sqliteMembers = @($sqlitePaths | Where-Object {
    Test-Path -LiteralPath $_ -PathType Leaf
} | ForEach-Object {
    [ordered]@{
        roleCode = switch -Wildcard (Split-Path -Leaf $_) {
            '*.db-shm' { 'sqlite_shared_memory' }
            '*.db-wal' { 'sqlite_write_ahead_log' }
            default { 'sqlite_main' }
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
Remove-Item -LiteralPath $projectionPath -Force
Assert-True ((Get-Sha256Hex $databasePath) -ceq
        'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194' -and
    @($sqlitePaths | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0 -and
    -not (Test-Path -LiteralPath $projectionPath)) `
    'phase3b2_projection_format_recovery_rollback_failed'

Copy-Item -LiteralPath $activePointerPath -Destination $archivedPointerPath
Assert-True ((Get-Sha256Hex $archivedPointerPath) -ceq
        (Get-Sha256Hex $activePointerPath)) `
    'phase3b2_projection_format_recovery_pointer_archive_failed'

$failure = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-p2-v2-projection-format-failure/v1'
    failedAtUtc =
        [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    assessmentUid = $AssessmentUid
    failureStageCode = 'catalogue_resource_path_upgrade'
    reasonCode = 'local_projection_http_200_body_parser_mismatch'
    catalogRequestHttpStatusCode = 200
    assetPrdenvSuccessfulResponseCount = $assetSuccessCount
    otherLocalNotFoundResponseCount = $localNotFoundCount
    playerExceptionType = 'System.ArgumentOutOfRangeException'
    playerExceptionMessageCode = 'substring_length_less_than_zero'
    playerMethodCode = 'content_version_datapack_entry_get_version_async'
    priorMissingFileFailureResolved = $true
    projectedBodyAcceptedByHttpClient = $true
    projectedBodyAcceptedByContentVersionParser = $false
    projectionCanonicalizationCode =
        'entry_name_colon_revision_comma_tag_lf_v1'
    projectionByteLength = 132
    projectionSha256 =
        '63f5ddcd289e55717ed0087b44d673837da14423e28bf363fa5f2092ca1a3502'
    playerLogByteLength = $playerLogBytes.LongLength
    playerLogSha256 = Get-Sha256Hex $playerLogPath
    rawPlayerLogCopied = $false
    screenshotByteLength = (Get-Item -LiteralPath $ScreenshotPath).Length
    screenshotSha256 = Get-Sha256Hex $ScreenshotPath
    rawScreenshotCopied = $false
    officialOutboundUsed = $false
    officialIdentityPersisted = $false
    officialCredentialPersisted = $false
    nextStepCode = 'statically_determine_exact_catalog_text_framing'
}
Write-AtomicUtf8NoBom $failureReceiptPath `
    (($failure | ConvertTo-Json -Depth 7) + "`n")

$recovery = [ordered]@{
    schemaVersion = 1
    contractId =
        'nll/phase3b2-p2-v2-projection-format-cold-recovery/v1'
    recoveredAtUtc =
        [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    failedAssessmentUid = $AssessmentUid
    failureReceiptByteLength =
        (Get-Item -LiteralPath $failureReceiptPath).Length
    failureReceiptSha256 = Get-Sha256Hex $failureReceiptPath
    runtimeColdAtRecovery = $true
    databaseAfterFailureByteLength =
        (Get-Item -LiteralPath $databaseAfterFailurePath).Length
    databaseAfterFailureSha256 = Get-Sha256Hex $databaseAfterFailurePath
    databaseRestored = $true
    sqliteRuntimeObservedMemberCount = $sqliteMembers.Count
    sqliteRuntimeMembers = $sqliteMembers
    sqliteRuntimeRemoved = $true
    invalidProjectionRemoved = $true
    catalogProjectionRetryConsumptionPreserved = $true
    catalogProjectionRetryConsumptionSha256 = Get-Sha256Hex $consumptionPath
    p2V2NetworkPreparationPreserved = $true
    p2V2HostsExtensionPreserved = $true
    p2V2FirewallExtensionPreservedForNextColdPreparation = $true
    dedicatedNllOperatorCacheModified = $false
    primaryInstallModified = $false
    officialLauncherModified = $false
    officialOutboundUsed = $false
    officialIdentityPersisted = $false
    officialCredentialPersisted = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
    nextStepCode = 'return_to_samsung_static_catalog_format_classification'
}
Write-AtomicUtf8NoBom $recoveryReceiptPath `
    (($recovery | ConvertTo-Json -Depth 8) + "`n")

New-Item -ItemType Directory -Path $protectedRunRoot -Force | Out-Null
foreach ($path in @($failureReceiptPath, $recoveryReceiptPath,
        $archivedPointerPath, $databaseAfterFailurePath)) {
    Copy-Item -LiteralPath $path -Destination $protectedRunRoot -Force
    $copy = Join-Path $protectedRunRoot (Split-Path -Leaf $path)
    Assert-True ((Get-Sha256Hex $copy) -ceq (Get-Sha256Hex $path)) `
        'phase3b2_projection_format_recovery_protected_copy_failed'
}

$latest = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-p2-v2-projection-format-failure-pointer/v1'
    assessmentUid = $AssessmentUid
    failureReceiptByteLength =
        (Get-Item -LiteralPath $failureReceiptPath).Length
    failureReceiptSha256 = Get-Sha256Hex $failureReceiptPath
    recoveryReceiptByteLength =
        (Get-Item -LiteralPath $recoveryReceiptPath).Length
    recoveryReceiptSha256 = Get-Sha256Hex $recoveryReceiptPath
    retryConsumed = $true
    runtimeCold = $true
    nextStepCode = 'statically_determine_exact_catalog_text_framing'
}
Write-AtomicUtf8NoBom $latestFailurePath `
    (($latest | ConvertTo-Json -Depth 6) + "`n")
Copy-Item -LiteralPath $latestFailurePath -Destination $protectedRunRoot -Force
Assert-True ((Get-Sha256Hex (Join-Path $protectedRunRoot `
            (Split-Path -Leaf $latestFailurePath))) -ceq
        (Get-Sha256Hex $latestFailurePath)) `
    'phase3b2_projection_format_recovery_latest_copy_failed'

Remove-Item -LiteralPath $activePointerPath -Force
Assert-True (-not (Test-Path -LiteralPath $activePointerPath)) `
    'phase3b2_projection_format_recovery_pointer_retirement_failed'

[pscustomobject]@{
    Receipt = $recovery
    FailureReceiptByteLength = (Get-Item $failureReceiptPath).Length
    FailureReceiptSha256 = Get-Sha256Hex $failureReceiptPath
    RecoveryReceiptByteLength = (Get-Item $recoveryReceiptPath).Length
    RecoveryReceiptSha256 = Get-Sha256Hex $recoveryReceiptPath
    ProtectedRunRoot = $protectedRunRoot
} | ConvertTo-Json -Depth 9
