[CmdletBinding()]
param(
    [string]$MicronDrive = 'E:',
    [string]$AssessmentUid =
        'deafa3e3-d889-4a09-8a66-fc7dc3e27305',
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
    'phase3b2_resource_host_failure_recovery_requires_administrator'

$micronLetter = $MicronDrive.TrimEnd(':')
$systemDisk = Get-Partition -DriveLetter C | Get-Disk
$micronDisk = Get-Partition -DriveLetter $micronLetter | Get-Disk
Assert-True ($systemDisk.FriendlyName -ceq 'Samsung SSD 980 1TB' -and
    $systemDisk.IsBoot -and $systemDisk.IsSystem -and
    $micronDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK' -and
    -not $micronDisk.IsBoot -and -not $micronDisk.IsSystem) `
    'phase3b2_resource_host_failure_recovery_disk_boundary_invalid'
Assert-True (@(Get-Process -Name EpinelPS, nikke, nikke_launcher,
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap' `
        -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_resource_host_failure_recovery_runtime_not_cold'

$p2Root = Join-Path $MicronDrive `
    'NLL\Evidence\Phase3B2\Physical\p2-client-start-v2'
$runRoot = Join-Path $p2Root $AssessmentUid
$activePointerPath = Join-Path $p2Root 'active-run.pointer.json'
$consumptionPath = Join-Path $p2Root `
    'resource-host-map-retry.consumed.json'
$runStartPath = Join-Path $runRoot 'run-start.receipt.json'
$measurementPath = Join-Path $runRoot 'ten-minute-measurement.receipt.json'
$databaseBeforePath = Join-Path $runRoot 'db.before.bin'
$requestStagePath = Join-Path $runRoot 'server-request-stage.jsonl'
$playerLogPath = Join-Path $MicronDrive `
    'Users\nlloperator\AppData\LocalLow\com.proximabeta\NIKKE\Player.log'
$archivedPointerPath = Join-Path $runRoot `
    'active-run.before-resource-host-map-cold-recovery.json'
$databaseAfterFailurePath = Join-Path $runRoot `
    'db.after-resource-host-map-failure.bin'
$preRollbackManifestPath = Join-Path $runRoot `
    'resource-host-map.pre-rollback.manifest.json'
$failureReceiptPath = Join-Path $runRoot `
    'resource-host-map-failure.receipt.json'
$recoveryReceiptPath = Join-Path $runRoot `
    'resource-host-map-cold-recovery.receipt.json'
$latestFailurePath = Join-Path $p2Root `
    'latest-resource-host-map-failure.pointer.json'
$protectedRunRoot = Join-Path $SamsungProtectedRoot $AssessmentUid

if ([string]::IsNullOrWhiteSpace($ScreenshotPath)) {
    $screenshotRoot = Join-Path $MicronDrive `
        'Users\nlloperator\Pictures\Screenshots'
    $screenshotMatches = @(Get-ChildItem -LiteralPath $screenshotRoot `
            -File -Filter '*.png' -ErrorAction Stop | Where-Object {
            $_.Length -eq 603775L -and
            (Get-Sha256Hex $_.FullName) -ceq
                '6046cc9a22e0aa0620069eb1fa84f5395580db92bf88eb0a1eb2ba450fe56d09'
        })
    Assert-True ($screenshotMatches.Count -eq 1) `
        'phase3b2_resource_host_failure_screenshot_resolution_invalid'
    $ScreenshotPath = $screenshotMatches[0].FullName
}

$requiredPins = @(
    @($activePointerPath, 1288L,
        'b37fee022f4795ceaf4924ed3e64e844999c78af7514251d146ff15aab8bcea5'),
    @($consumptionPath, 1065L,
        '003e7c815adff246d29f31c348ecd3d0775dc793c74b9657d1dd978f6e2a3779'),
    @($runStartPath, 2544L,
        'bc67d1c1d306da376e983400941c27f27d8af1644ad4c42f276594ccd1e6cdb0'),
    @($measurementPath, 3010L,
        '127f7574bf15197ccbd8eb68b4deaa4d40eb1c20625112d178ca7475d8f77256'),
    @($databaseBeforePath, 413327L,
        'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194'),
    @($requestStagePath, 7540L,
        'd55f59282eda854fcbc51d81650df0ff914673fd920f7fe5cc4fcb71e4401fc4'),
    @($playerLogPath, 14653L,
        'c7d2f455ca578763a05f10d8fde89e757bdca9672e1b55089edd00b923c31ccf'),
    @($ScreenshotPath, 603775L,
        '6046cc9a22e0aa0620069eb1fa84f5395580db92bf88eb0a1eb2ba450fe56d09')
)
$pinMismatches = @($requiredPins | Where-Object {
    -not (Test-PathDigest ([string]$_[0]) ([long]$_[1]) ([string]$_[2]))
})
if ($pinMismatches.Count -ne 0) {
    throw ('phase3b2_resource_host_failure_evidence_pin_invalid:' +
        (@($pinMismatches | ForEach-Object {
            Split-Path -Leaf ([string]$_[0])
        }) -join ','))
}
$outputPaths = @($archivedPointerPath, $failureReceiptPath,
    $recoveryReceiptPath)
Assert-True (@($outputPaths | Where-Object {
        Test-Path -LiteralPath $_
    }).Count -eq 0) `
    'phase3b2_resource_host_failure_output_already_present'

$pointer = Get-Content -LiteralPath $activePointerPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$consumption = Get-Content -LiteralPath $consumptionPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$runStart = Get-Content -LiteralPath $runStartPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($pointer.contractId -ceq
        'nll/phase3b2-physical-p2-v2-active-run-pointer/v1' -and
    $pointer.assessmentUid -ceq $AssessmentUid -and
    $pointer.resourceHostVersionMapVerified -and
    $pointer.catalogVersionProjectionSha256 -ceq
        'd7898079fa23b140396a952afc3881b51876827a852aa723492f2a6149ead805' -and
    $consumption.contractId -ceq
        'nll/phase3b2-p2-v2-resource-host-map-retry-consumption/v1' -and
    $consumption.assessmentUid -ceq $AssessmentUid -and
    $consumption.singleRetryConsumed -and
    $runStart.assessmentUid -ceq $AssessmentUid -and
    $runStart.dedicatedCacheStateCode -ceq
        'preserved_resource_host_map_retry') `
    'phase3b2_resource_host_failure_contract_invalid'

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
}).Count -eq 0) `
    'phase3b2_resource_host_failure_player_signal_missing'

$stageRecords = @(Get-Content -LiteralPath $requestStagePath -Encoding UTF8 |
    Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
$assetSuccessCount = @($stageRecords | Where-Object {
    $_.transitionCode -ceq 'request_completed' -and
    $_.requestStageCode -ceq 'asset_prdenv' -and
    [int]$_.httpStatusCode -eq 200
}).Count
Assert-True ($assetSuccessCount -eq 1) `
    'phase3b2_resource_host_failure_asset_response_shape_invalid'

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
$resourceBackupRoot = Join-Path $MicronDrive `
    'NLL\Backups\Phase3B2\PhysicalP2-ResourceHostMap-v1'
$rollbackManifestPath = Join-Path $resourceBackupRoot 'rollback.manifest.json'

$initialRuntimeState =
    (Test-PathDigest $databasePath 413329L `
        'e524a3c8967af6bb8447fda0c50fc8a86ebccd02e1d1a45df73b2625430acc8d') -and
    -not (Test-Path -LiteralPath $databaseAfterFailurePath) -and
    -not (Test-Path -LiteralPath $preRollbackManifestPath)
$partialRuntimeState =
    (Test-PathDigest $databasePath 413327L `
        'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194') -and
    (Test-PathDigest $databaseAfterFailurePath 413329L `
        'e524a3c8967af6bb8447fda0c50fc8a86ebccd02e1d1a45df73b2625430acc8d') -and
    (Test-PathDigest $preRollbackManifestPath 2977L `
        '9d8d9e4ac147a60b12320ea68a707567208a15fd68b5cad934764b2dca9b87f6') -and
    @($sqlitePaths | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0
Assert-True (($initialRuntimeState -or $partialRuntimeState) -and
    (Test-PathDigest $projectionPath 131L `
        'd7898079fa23b140396a952afc3881b51876827a852aa723492f2a6149ead805') -and
    (Test-PathDigest $hostsPath 1727L `
        '3b0dcc4396373e9e9d623ef05c345f89330427ad5128727290c9f76138e22f64') -and
    (Test-PathDigest $hostsBackupPath 1690L `
        'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0') -and
    (Test-PathDigest $rollbackManifestPath 4582L `
        '2e025205f2cf7da820b8f87bacf18950467cd96e21afcd7f92cbc7d864bf4326')) `
    'phase3b2_resource_host_failure_runtime_state_invalid'

$expectedSqlite = @{
    'epinelps.db' = @(4096L,
        '5c9dec1886cc01f5f2307ee1ea87f9b32a4cef0f8f9a2c68beebc558013bedab')
    'epinelps.db-shm' = @(32768L,
        '010b5d4fa6bee5e3a76e36619957bf5fec49b6f00508341afaeda6766e0ea50e')
    'epinelps.db-wal' = @(111272L,
        'bab154957b323351a527ea018d8c5c6acd1421d1d540ddc2405f263a184a303b')
}
if ($initialRuntimeState) {
    Assert-True (@($sqlitePaths | Where-Object {
        $name = [IO.Path]::GetFileName($_)
        -not (Test-PathDigest $_ ([long]$expectedSqlite[$name][0]) `
            ([string]$expectedSqlite[$name][1]))
    }).Count -eq 0) 'phase3b2_resource_host_failure_sqlite_state_invalid'
}

$currentDestinationPins = @{
    'EpinelPS.dll' = '0032fdf60e31e4bd0887389a58dffbc88924638bca85e5489be8f556ea4424bf'
    'gameconfig.runtime.json' = '1f0c3d30c9e113c8a90c88e239e44396bfb2ac0256259291c168ccfbd984baf1'
    'deployment.receipt.json' = 'd4eeb621fbf6d8affc3470803e1d7e753be805079de2b8f2597315abbaaf81bc'
    'tools.manifest.tsv' = '99a056843377b446622157045b3f4eeb65e736b0f94895d52585116462c1b02c'
    'tool.start-phase3b2-physical-p2-v2-client-in-micron.ps1' = 'ffc28fe29f1b0a6db59f5f6a51b59d18f76b4b12db42b81e3edccc9a5b0b74dc'
    'tool.complete-phase3b2-physical-p2-v2-client-in-micron.ps1' = '7801f6800a730bac8a69131f695c533fac474085cbd643d1a31a7d39257859b8'
    'tool.Start-Phase3B2-Physical-P2-V2.ps1' = '4cc5bb3bae775b86f0caae56436b202e9c1355c77e8c0424b25fd2459359b056'
    'source.EpinelPS.Utils.GameConfig.cs' = '67121506117bb4cc1d2c23b145988265f4dc9aa83efd5e01407bdf9c9f7b1784'
    'source.EpinelPS.LobbyServer.Controllers.SystemController.cs' = '60dbcf94166490fd96520d3470578858ae4dfe0f41d3efdb6599e3c75f23c320'
    'source.EpinelPS.gameconfig.json' = '1f0c3d30c9e113c8a90c88e239e44396bfb2ac0256259291c168ccfbd984baf1'
}
$rollback = Get-Content -LiteralPath $rollbackManifestPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($rollback.contractId -ceq
        'nll/phase3b2-p2-v2-resource-host-map-rollback/v1' -and
    @($rollback.backupMembers).Count -eq 10) `
    'phase3b2_resource_host_failure_rollback_manifest_invalid'

$preRollbackMembers = @($rollback.backupMembers | ForEach-Object {
    $destinationPath = [string]$_.destinationPath
    Assert-True ($destinationPath.StartsWith(
            ($MicronDrive.TrimEnd(':') + ':\NLL\'),
            [StringComparison]::OrdinalIgnoreCase)) `
        'phase3b2_resource_host_failure_rollback_destination_invalid'
    Assert-True ((Test-Path -LiteralPath $destinationPath -PathType Leaf) -and
        (Get-Sha256Hex $destinationPath) -ceq
            $currentDestinationPins[[string]$_.roleCode]) `
        'phase3b2_resource_host_failure_current_destination_invalid'
    [ordered]@{
        roleCode = [string]$_.roleCode
        destinationPath = $destinationPath
        byteLength = (Get-Item -LiteralPath $destinationPath).Length
        sha256 = Get-Sha256Hex $destinationPath
    }
})
if ($initialRuntimeState) {
    Write-AtomicUtf8NoBom $preRollbackManifestPath `
        (([ordered]@{
            schemaVersion = 1
            contractId = 'nll/phase3b2-p2-v2-resource-host-map-pre-rollback/v1'
            assessmentUid = $AssessmentUid
            members = $preRollbackMembers
        } | ConvertTo-Json -Depth 7) + "`n")

    [IO.File]::WriteAllBytes(
        $databaseAfterFailurePath, [IO.File]::ReadAllBytes($databasePath))
    $sqliteMembers = @($sqlitePaths | ForEach-Object {
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
        Remove-Item -LiteralPath $path -Force
    }
    [IO.File]::WriteAllBytes(
        $databasePath, [IO.File]::ReadAllBytes($databaseBeforePath))
}
else {
    $sqliteMembers = @($expectedSqlite.GetEnumerator() | Sort-Object Name |
        ForEach-Object {
            [ordered]@{
                roleCode = switch ($_.Name) {
                    'epinelps.db' { 'sqlite_main' }
                    'epinelps.db-shm' { 'sqlite_shared_memory' }
                    'epinelps.db-wal' { 'sqlite_write_ahead_log' }
                }
                byteLength = [long]$_.Value[0]
                sha256 = [string]$_.Value[1]
            }
        })
}
[IO.File]::WriteAllBytes(
    $hostsPath, [IO.File]::ReadAllBytes($hostsBackupPath))
Remove-Item -LiteralPath $projectionPath -Force

foreach ($member in $rollback.backupMembers) {
    $sourcePath = Join-Path $resourceBackupRoot ([string]$member.roleCode)
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        $sourcePath = Join-Path $resourceBackupRoot `
            (([string]$member.roleCode) -replace '^tool\.', 'tool.' -replace
                '^source\.', 'source.')
    }
    Assert-True (Test-PathDigest $sourcePath ([long]$member.byteLength) `
        ([string]$member.sha256)) `
        'phase3b2_resource_host_failure_rollback_source_invalid'
    Copy-Item -LiteralPath $sourcePath `
        -Destination ([string]$member.destinationPath) -Force
    Assert-True (Test-PathDigest ([string]$member.destinationPath) `
        ([long]$member.byteLength) ([string]$member.sha256)) `
        'phase3b2_resource_host_failure_rollback_copy_invalid'
}

Assert-True ((Get-Sha256Hex $databasePath) -ceq
        'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194' -and
    (Get-Sha256Hex $hostsPath) -ceq
        'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0' -and
    @($sqlitePaths | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0 -and
    -not (Test-Path -LiteralPath $projectionPath)) `
    'phase3b2_resource_host_failure_rollback_failed'

Copy-Item -LiteralPath $activePointerPath -Destination $archivedPointerPath
Assert-True ((Get-Sha256Hex $archivedPointerPath) -ceq
    (Get-Sha256Hex $activePointerPath)) `
    'phase3b2_resource_host_failure_pointer_archive_failed'

$failure = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-p2-v2-resource-host-map-failure/v1'
    failedAtUtc =
        [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    assessmentUid = $AssessmentUid
    failureStageCode = 'catalogue_resource_path_upgrade'
    reasonCode = 'core_key_missing_after_resource_host_version_map_projection'
    resourceHostVersionMapHypothesisFalsified = $true
    projectedBodyByteLength = 131
    projectedBodySha256 =
        'd7898079fa23b140396a952afc3881b51876827a852aa723492f2a6149ead805'
    assetPrdenvSuccessfulResponseCount = $assetSuccessCount
    playerExceptionType = 'System.Collections.Generic.KeyNotFoundException'
    missingDictionaryKeyCode = 'core'
    playerMethodCode = 'nk_addressable_host_make_catalog_group'
    playerLogByteLength = $playerLogBytes.LongLength
    playerLogSha256 = Get-Sha256Hex $playerLogPath
    rawPlayerLogCopied = $false
    screenshotByteLength = (Get-Item -LiteralPath $ScreenshotPath).Length
    screenshotSha256 = Get-Sha256Hex $ScreenshotPath
    rawScreenshotCopied = $false
    completionRuntimeStopFailureObserved = $true
    officialOutboundUsed = $false
    officialIdentityPersisted = $false
    officialCredentialPersisted = $false
    nextStepCode = 'inspect_exact_local_catalog_source_before_new_retry'
}
Write-AtomicUtf8NoBom $failureReceiptPath `
    (($failure | ConvertTo-Json -Depth 7) + "`n")

$recovery = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-p2-v2-resource-host-map-cold-recovery/v1'
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
    partialRecoveryResumed = $partialRuntimeState
    sqliteRuntimeObservedMemberCount = $sqliteMembers.Count
    sqliteRuntimeMembers = $sqliteMembers
    sqliteRuntimeRemoved = $true
    exactProjectionRemoved = $true
    p2V2HostsExtensionRolledBack = $true
    resourceHostMapMutationRolledBack = $true
    resourceHostMapRollbackManifestSha256 = Get-Sha256Hex $rollbackManifestPath
    resourceHostMapPreRollbackManifestSha256 =
        Get-Sha256Hex $preRollbackManifestPath
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
    nextStepCode = 'inspect_exact_local_catalog_source_before_new_retry'
}
Write-AtomicUtf8NoBom $recoveryReceiptPath `
    (($recovery | ConvertTo-Json -Depth 8) + "`n")

New-Item -ItemType Directory -Path $protectedRunRoot -Force | Out-Null
foreach ($path in @($failureReceiptPath, $recoveryReceiptPath,
        $archivedPointerPath, $databaseAfterFailurePath,
        $preRollbackManifestPath)) {
    Copy-Item -LiteralPath $path -Destination $protectedRunRoot -Force
    $copy = Join-Path $protectedRunRoot (Split-Path -Leaf $path)
    Assert-True ((Get-Sha256Hex $copy) -ceq (Get-Sha256Hex $path)) `
        'phase3b2_resource_host_failure_protected_copy_failed'
}

$latest = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-p2-v2-resource-host-map-failure-pointer/v1'
    assessmentUid = $AssessmentUid
    failureReceiptByteLength = (Get-Item $failureReceiptPath).Length
    failureReceiptSha256 = Get-Sha256Hex $failureReceiptPath
    recoveryReceiptByteLength = (Get-Item $recoveryReceiptPath).Length
    recoveryReceiptSha256 = Get-Sha256Hex $recoveryReceiptPath
    retryConsumed = $true
    runtimeCold = $true
    resourceHostVersionMapHypothesisFalsified = $true
    nextStepCode = 'inspect_exact_local_catalog_source_before_new_retry'
}
Write-AtomicUtf8NoBom $latestFailurePath `
    (($latest | ConvertTo-Json -Depth 6) + "`n")
Copy-Item -LiteralPath $latestFailurePath -Destination $protectedRunRoot -Force
Remove-Item -LiteralPath $activePointerPath -Force
Assert-True (-not (Test-Path -LiteralPath $activePointerPath)) `
    'phase3b2_resource_host_failure_pointer_retirement_failed'

[pscustomobject]@{
    Receipt = $recovery
    FailureReceiptByteLength = (Get-Item $failureReceiptPath).Length
    FailureReceiptSha256 = Get-Sha256Hex $failureReceiptPath
    RecoveryReceiptByteLength = (Get-Item $recoveryReceiptPath).Length
    RecoveryReceiptSha256 = Get-Sha256Hex $recoveryReceiptPath
    ProtectedRunRoot = $protectedRunRoot
} | ConvertTo-Json -Depth 9
