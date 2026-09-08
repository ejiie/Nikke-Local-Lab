[CmdletBinding()]
param(
    [string]$MicronDrive = 'E:',
    [string]$SamsungProtectedRoot =
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\HeaderFollowup'
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

function Write-AtomicBytes {
    param([string]$Path, [byte[]]$Bytes)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $temporaryPath = $Path + '.tmp.' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllBytes($temporaryPath, $Bytes)
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Write-AtomicUtf8NoBom {
    param([string]$Path, [string]$Text)
    Write-AtomicBytes $Path ([Text.UTF8Encoding]::new($false).GetBytes($Text))
}

function Copy-ExactFile {
    param([string]$Source, [string]$Destination)
    Write-AtomicBytes $Destination ([IO.File]::ReadAllBytes($Source))
    Assert-True ((Get-Item -LiteralPath $Source).Length -eq
            (Get-Item -LiteralPath $Destination).Length -and
        (Get-Sha256Hex $Source) -ceq (Get-Sha256Hex $Destination)) `
        'phase3b2_exact_catalog_header_followup_copy_failed'
}

function Get-ContainedPath {
    param([string]$Root, [string]$RelativePath, [string]$FailureCode)
    $canonicalRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $candidate = [IO.Path]::GetFullPath((Join-Path $Root $RelativePath))
    Assert-True ($candidate.StartsWith($canonicalRoot,
            [StringComparison]::OrdinalIgnoreCase)) $FailureCode
    $candidate
}

$micronLetter = $MicronDrive.TrimEnd(':')
$bootDisk = Get-Partition -DriveLetter C | Get-Disk
$micronDisk = Get-Partition -DriveLetter $micronLetter | Get-Disk
Assert-True ($bootDisk.FriendlyName -ceq 'Samsung SSD 980 1TB' -and
    $bootDisk.IsBoot -and $bootDisk.IsSystem -and
    $micronDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK' -and
    -not $micronDisk.IsBoot -and -not $micronDisk.IsSystem) `
    'phase3b2_exact_catalog_header_followup_disk_boundary_invalid'
$runtimeNames = @(
    'EpinelPS', 'nikke', 'nikke_launcher',
    'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
)
Assert-True (@(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $runtimeNames -contains $_.ProcessName
}).Count -eq 0) 'phase3b2_exact_catalog_header_followup_runtime_not_cold'

$repoRoot = Split-Path -Parent $PSScriptRoot
$micronNllRoot = Join-Path $MicronDrive 'NLL'
$p2Root = Join-Path $micronNllRoot `
    'Evidence\Phase3B2\Physical\p2-client-start-v2'
$runUid = '29083a6a-3f4e-4eec-a57a-4d28b1459524'
$runRoot = Join-Path $p2Root $runUid
$activePointerPath = Join-Path $p2Root 'active-run.pointer.json'
$consumptionPath = Join-Path $p2Root `
    'exact-catalog-set-retry.consumed.json'
$latestCompletionPath = Join-Path $p2Root `
    'latest-completion.pointer.json'
$archivedActivePath = Join-Path $runRoot `
    'active-run.before-exact-catalog-header-followup.json'
$archivedConsumptionPath = Join-Path $runRoot `
    'exact-catalog-set-retry.consumed.before-header-followup.json'
$runStartPath = Join-Path $runRoot 'run-start.receipt.json'
$bootstrapExitPath = Join-Path $runRoot 'bootstrap-exit.receipt.json'
$requestStagePath = Join-Path $runRoot 'server-request-stage.jsonl'
$databaseBeforePath = Join-Path $runRoot 'db.before.bin'
$databaseAfterMissPath = Join-Path $runRoot `
    'db.after-exact-catalog-header-miss.bin'
$serverRoot = Join-Path $micronNllRoot `
    'EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
$databasePath = Join-Path $serverRoot 'db.json'
$sqlitePaths = @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal') |
    ForEach-Object { Join-Path $serverRoot $_ }
$headerPath = Join-Path $serverRoot `
    'cache\prdenv\150-b059c3f36c\StandaloneWindows64\pck\latest-651.txt'
$headerProofPath = Join-Path $repoRoot `
    '.external\phase3b2-header-proof\prdenv\150-b059c3f36c\StandaloneWindows64\pck\latest-651.txt'
$playerLogPath = Join-Path $MicronDrive `
    'Users\nlloperator\AppData\LocalLow\com.proximabeta\NIKKE\Player.log'
$lcvPath = Join-Path $micronNllRoot `
    'Clients\NIKKE-150.6.9-Physical\Unity\com_proximabeta_NIKKE\.lcv.dat'
$gameConfigPath = Join-Path $micronNllRoot 'EpinelPS\EpinelPS\gameconfig.json'
$projectionReceiptPath = Join-Path $micronNllRoot `
    'Evidence\Phase3B2\Physical\p2-tool-transfer-v2\datapack-version-header-projection.receipt.json'
$authorizationPath = Join-Path $micronNllRoot `
    'Evidence\Phase3B2\Physical\p2-tool-transfer-v2\exact-catalog-header-followup.receipt.json'
$targetStartPath = Join-Path $micronNllRoot `
    'Tools\start-phase3b2-physical-p2-v2-client-in-micron.ps1'
$targetCompletionPath = Join-Path $micronNllRoot `
    'Tools\complete-phase3b2-physical-p2-v2-client-in-micron.ps1'
$sourceStartPath = Join-Path $repoRoot `
    'scripts\start-phase3b2-physical-p2-v2-client-in-micron.ps1'
$sourceCompletionPath = Join-Path $repoRoot `
    'scripts\complete-phase3b2-physical-p2-v2-client-in-micron.ps1'
$catalogPointerPath = Join-Path $micronNllRoot `
    'Evidence\Phase3B2\Physical\catalog-set-v1\latest.pointer.json'
$catalogDeploymentRoot = Join-Path $micronNllRoot `
    'Evidence\Phase3B2\Physical\catalog-set-v1\bf669c3c-fcc8-4d57-9f18-32fee1288862'
$catalogPrivateManifestPath = Join-Path $catalogDeploymentRoot `
    'deployment.private.json'
$hostsPath = Join-Path $MicronDrive 'Windows\System32\drivers\etc\hosts'
$hostsBackupPath = Join-Path $micronNllRoot `
    'Backups\Phase3B2\PhysicalP2-v2\hosts.before.bin'
$backupRoot = Join-Path $micronNllRoot `
    'Backups\Phase3B2\ExactCatalogHeaderFollowup-v1'

Assert-True ((Test-PathDigest $activePointerPath 1490L `
        'c928f5213a7497e280e983ab8dd159bd1b7064e93fc809e013a3688a8491e2e2') -and
    (Test-PathDigest $consumptionPath 1373L `
        '1d4c8d0350f50ad0662bd2ec6a1e288900d8725c91665654c375ac04ca38853c') -and
    (Test-PathDigest $latestCompletionPath 484L `
        '1e44f749e81155b4818575e5c5880741c9753aa0e944c0f8cf6ef0b1b838b25a') -and
    (Test-PathDigest $runStartPath 2947L `
        '4481b1186a9b17fbe06c70bcf2639860439423a76b300e2309710cfe55d4f10f') -and
    (Test-PathDigest $bootstrapExitPath 387L `
        '22af047ed864e0524d50bf22716753158778d7a6fba761c94fdcea4845b287d1') -and
    (Test-PathDigest $requestStagePath 7987L `
        '2f3e92ed86cb4e631e84c8d8af9a0e1ed9903f63d213caffb227801ab9e68116') -and
    (Test-PathDigest $databaseBeforePath 413327L `
        'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194') -and
    (Test-PathDigest $databasePath 413329L `
        'e524a3c8967af6bb8447fda0c50fc8a86ebccd02e1d1a45df73b2625430acc8d') -and
    (Test-PathDigest $sqlitePaths[0] 4096L `
        '5c9dec1886cc01f5f2307ee1ea87f9b32a4cef0f8f9a2c68beebc558013bedab') -and
    (Test-PathDigest $sqlitePaths[1] 32768L `
        '3595bbe23b8dd155b5bee6b46a6ecc04388edc8398707c22931546580c73fa6e') -and
    (Test-PathDigest $sqlitePaths[2] 111272L `
        'd44612eb6f8c21abae9b0b3001f49a4f8cf57de9a51f1bb1c63c208a92b65d0e') -and
    (Test-PathDigest $playerLogPath 67035L `
        '268ed945f33b0fcbbc72c3889810ca282f6656d43cba020347f5f8a65865779f') -and
    (Test-PathDigest $projectionReceiptPath 1383L `
        'c13074f78a27e435f1cb00def0d3c4ffe48216113107f625b1718a61f942e1f6') -and
    (Test-PathDigest $lcvPath 3775L `
        'ede45120d1531ea1639dc4237bb8ff0061b356ccefdf8fd53d9edcd98f2e9054') -and
    (Test-PathDigest $gameConfigPath 598L `
        '3a37e274562f80c7fdb1f6b58c579f4b1946c02f0c700ea40cea2f9b7801d152') -and
    (Test-PathDigest $headerProofPath 139L `
        '5914cb58fd2146fe761ab531ecb4e321300527186a54b455e59de962ff6c044a') -and
    (Test-PathDigest $hostsPath 1727L `
        '3b0dcc4396373e9e9d623ef05c345f89330427ad5128727290c9f76138e22f64') -and
    (Test-PathDigest $hostsBackupPath 1690L `
        'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0') -and
    (Test-PathDigest $catalogPointerPath 707L `
        '5b015177c6b17339cb13989f9056d024831c1b03ff6544c4bcaeb4d676fc47a8') -and
    (Test-PathDigest $catalogPrivateManifestPath 2677L `
        '919a8f6c658a839aa882e3f2e12a9bbedce6e7bec765a8765a160e52adecf39c') -and
    (Test-PathDigest $targetStartPath 99381L `
        '5417964589cbd0c4cf514e8e6fc887799d5cd056408d54041098a3b0f20bf579') -and
    (Test-PathDigest $targetCompletionPath 26140L `
        '21b08aa7170f65dc52250691e188191d5acdbe524e4dc1dd842fd7b94c18c67a') -and
    -not (Test-Path -LiteralPath $headerPath) -and
    -not (Test-Path -LiteralPath $authorizationPath) -and
    -not (Test-Path -LiteralPath $archivedActivePath) -and
    -not (Test-Path -LiteralPath $archivedConsumptionPath) -and
    -not (Test-Path -LiteralPath $databaseAfterMissPath) -and
    -not (Test-Path -LiteralPath $backupRoot)) `
    'phase3b2_exact_catalog_header_followup_input_shape_invalid'

$activePointer = Get-Content -LiteralPath $activePointerPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
$consumption = Get-Content -LiteralPath $consumptionPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
$latestCompletion = Get-Content -LiteralPath $latestCompletionPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
$projectionReceipt = Get-Content -LiteralPath $projectionReceiptPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
$bootstrapExit = Get-Content -LiteralPath $bootstrapExitPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
Assert-True ($activePointer.contractId -ceq
        'nll/phase3b2-physical-p2-v2-active-run-pointer/v1' -and
    $activePointer.assessmentUid -ceq $runUid -and
    $activePointer.exactCatalogSetVerified -and
    -not $activePointer.catalogVersionProjectionVerified -and
    -not $activePointer.dataPackVersionHeaderVerified -and
    $consumption.contractId -ceq
        'nll/phase3b2-p2-v2-exact-catalog-set-retry-consumption/v1' -and
    $consumption.assessmentUid -ceq $runUid -and
    $consumption.exactCatalogSetVerified -and
    $latestCompletion.contractId -ceq
        'nll/phase3b2-physical-p2-v2-completion-pointer/v1' -and
    $latestCompletion.assessmentUid -ceq
        '31741b96-84e8-407d-b56a-b32ab0b0e630' -and
    $bootstrapExit.contractId -ceq
        'nll/phase3b2-physical-bootstrap-client-exit/v1' -and
    $bootstrapExit.assessmentUid -ceq $runUid -and
    [int]$bootstrapExit.clientExitCode -eq 3 -and
    $projectionReceipt.contractId -ceq
        'nll/phase3b2-local-content-version-projection/v3' -and
    [long]$projectionReceipt.projectedByteLength -eq 139L -and
    $projectionReceipt.projectedSha256 -ceq
        '5914cb58fd2146fe761ab531ecb4e321300527186a54b455e59de962ff6c044a' -and
    -not $projectionReceipt.officialOutboundUsed) `
    'phase3b2_exact_catalog_header_followup_contract_invalid'

$playerLogText = [IO.File]::ReadAllText($playerLogPath, [Text.Encoding]::UTF8)
$failedRequest =
    'GetVersionAsync failed: https://cloud.nikke-kr.com/prdenv/150-b059c3f36c/StandaloneWindows64/pck/latest-651.txt'
$requestRows = @(Get-Content -LiteralPath $requestStagePath -Encoding UTF8 |
    ForEach-Object { $_ | ConvertFrom-Json })
Assert-True ($playerLogText.IndexOf($failedRequest,
        [StringComparison]::Ordinal) -ge 0 -and
    @($requestRows | Where-Object {
        $_.requestStageCode -ceq 'asset_prdenv' -and
        [int]$_.httpStatusCode -eq 404
    }).Count -eq 1) 'phase3b2_exact_catalog_header_followup_404_not_confirmed'

$catalogPrivateManifest = Get-Content -LiteralPath $catalogPrivateManifestPath `
    -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ($catalogPrivateManifest.contractId -ceq
        'nll/phase3b2-exact-catalog-offline-deployment-private/v1' -and
    $catalogPrivateManifest.deploymentUid -ceq
        'bf669c3c-fcc8-4d57-9f18-32fee1288862' -and
    @($catalogPrivateManifest.members).Count -eq 6) `
    'phase3b2_exact_catalog_header_followup_catalog_manifest_invalid'
$cacheRoot = Join-Path $serverRoot 'cache'
foreach ($member in @($catalogPrivateManifest.members)) {
    $target = Get-ContainedPath $cacheRoot ([string]$member.relativePath) `
        'phase3b2_exact_catalog_header_followup_catalog_path_invalid'
    Assert-True (Test-PathDigest $target ([long]$member.byteLength) `
        ([string]$member.sha256)) `
        'phase3b2_exact_catalog_header_followup_catalog_digest_invalid'
}

foreach ($sourceTool in @($sourceStartPath, $sourceCompletionPath)) {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        $sourceTool, [ref]$tokens, [ref]$parseErrors)
    Assert-True (@($parseErrors).Count -eq 0) `
        'phase3b2_exact_catalog_header_followup_source_tool_parse_failed'
}

$repairUid = [Guid]::NewGuid().ToString('D')
$protectedRoot = Join-Path $SamsungProtectedRoot $repairUid
$manifestPath = Join-Path $backupRoot 'backup.manifest.json'
$authorizationProtectedPath = Join-Path $protectedRoot `
    'exact-catalog-header-followup.receipt.json'
$backupFiles = [ordered]@{
    active_pointer = $activePointerPath
    retry_consumption = $consumptionPath
    latest_completion_pointer = $latestCompletionPath
    database_after_miss = $databasePath
    sqlite_main = $sqlitePaths[0]
    sqlite_shared_memory = $sqlitePaths[1]
    sqlite_write_ahead_log = $sqlitePaths[2]
    start_tool = $targetStartPath
    completion_tool = $targetCompletionPath
}

New-Item -ItemType Directory -Path $backupRoot, $protectedRoot -Force |
    Out-Null
$backupMembers = @()
foreach ($roleCode in $backupFiles.Keys) {
    $source = [string]$backupFiles[$roleCode]
    $destination = Join-Path $backupRoot ($roleCode + '.bin')
    Copy-ExactFile $source $destination
    $backupMembers += [ordered]@{
        roleCode = $roleCode
        sourcePathSha256 = (Get-Sha256Hex $source)
        byteLength = (Get-Item -LiteralPath $destination).Length
        sha256 = Get-Sha256Hex $destination
        backupFileName = Split-Path -Leaf $destination
    }
}
$backupManifest = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-exact-catalog-header-followup-backup/v1'
    createdAtUtc =
        [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    repairUid = $repairUid
    memberCount = $backupMembers.Count
    members = $backupMembers
    headerTargetPreexisting = $false
    exactCatalogSetModified = $false
    officialIdentityPersisted = $false
    officialCredentialPersisted = $false
}
Write-AtomicUtf8NoBom $manifestPath `
    (($backupManifest | ConvertTo-Json -Depth 8) + "`n")

$repairApplied = $false
try {
    Copy-ExactFile $activePointerPath $archivedActivePath
    Copy-ExactFile $consumptionPath $archivedConsumptionPath
    Copy-ExactFile $databasePath $databaseAfterMissPath

    Write-AtomicBytes $databasePath ([IO.File]::ReadAllBytes($databaseBeforePath))
    foreach ($sqlitePath in $sqlitePaths) {
        Remove-Item -LiteralPath $sqlitePath -Force
    }
    Assert-True ((Test-PathDigest $databasePath 413327L `
            'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194') -and
        @($sqlitePaths | Where-Object {
            Test-Path -LiteralPath $_
        }).Count -eq 0) `
        'phase3b2_exact_catalog_header_followup_database_restore_failed'

    Copy-ExactFile $headerProofPath $headerPath
    Assert-True (Test-PathDigest $headerPath 139L `
        '5914cb58fd2146fe761ab531ecb4e321300527186a54b455e59de962ff6c044a') `
        'phase3b2_exact_catalog_header_followup_header_stage_failed'

    Copy-ExactFile $sourceStartPath $targetStartPath
    Copy-ExactFile $sourceCompletionPath $targetCompletionPath
    $appliedStartToolSha256 = Get-Sha256Hex $targetStartPath
    $appliedCompletionToolSha256 = Get-Sha256Hex $targetCompletionPath

    Remove-Item -LiteralPath $activePointerPath -Force
    Remove-Item -LiteralPath $consumptionPath -Force
    Assert-True (-not (Test-Path -LiteralPath $activePointerPath) -and
        -not (Test-Path -LiteralPath $consumptionPath)) `
        'phase3b2_exact_catalog_header_followup_retry_rearm_failed'

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-exact-catalog-header-followup/v1'
        repairedAtUtc =
            [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        repairUid = $repairUid
        failedAssessmentUid = $runUid
        failureStageCode = 'catalogue_resource_path_upgrade'
        failureReasonCode = 'local_exact_content_version_header_404'
        failureRequestPathCode =
            'prdenv_150_b059c3f36c_standalonewindows64_pck_latest_651'
        playerLogByteLength = 67035L
        playerLogSha256 =
            '268ed945f33b0fcbbc72c3889810ca282f6656d43cba020347f5f8a65865779f'
        playerLogRawCopied = $false
        requestStageReceiptSha256 =
            '2f3e92ed86cb4e631e84c8d8af9a0e1ed9903f63d213caffb227801ab9e68116'
        confirmedAssetPrdenv404Count = 1
        catalogDeploymentUid =
            'bf669c3c-fcc8-4d57-9f18-32fee1288862'
        exactCatalogMemberCount = 6
        exactCatalogSetPreserved = $true
        sourceLcvByteLength = 3775L
        sourceLcvSha256 =
            'ede45120d1531ea1639dc4237bb8ff0061b356ccefdf8fd53d9edcd98f2e9054'
        projectionReceiptSha256 =
            'c13074f78a27e435f1cb00def0d3c4ffe48216113107f625b1718a61f942e1f6'
        projectedHeaderByteLength = 139L
        projectedHeaderSha256 =
            '5914cb58fd2146fe761ab531ecb4e321300527186a54b455e59de962ff6c044a'
        projectedHeaderApplied = $true
        databaseAfterMissByteLength = 413329L
        databaseAfterMissSha256 =
            'e524a3c8967af6bb8447fda0c50fc8a86ebccd02e1d1a45df73b2625430acc8d'
        databaseRestored = $true
        sqliteRuntimeRemoved = $true
        activePointerArchived = $true
        activePointerSha256 =
            'c928f5213a7497e280e983ab8dd159bd1b7064e93fc809e013a3688a8491e2e2'
        exactRetryConsumptionArchived = $true
        exactRetryConsumptionSha256 =
            '1d4c8d0350f50ad0662bd2ec6a1e288900d8725c91665654c375ac04ca38853c'
        priorCompletionPointerPreserved = $true
        priorCompletionPointerSha256 =
            '1e44f749e81155b4818575e5c5880741c9753aa0e944c0f8cf6ef0b1b838b25a'
        backupManifestByteLength = (Get-Item -LiteralPath $manifestPath).Length
        backupManifestSha256 = Get-Sha256Hex $manifestPath
        appliedStartToolByteLength = (Get-Item -LiteralPath $targetStartPath).Length
        appliedStartToolSha256 = $appliedStartToolSha256
        appliedCompletionToolByteLength =
            (Get-Item -LiteralPath $targetCompletionPath).Length
        appliedCompletionToolSha256 = $appliedCompletionToolSha256
        completionPointerCollisionFixed = $true
        hostsStateChanged = $false
        firewallStateChanged = $false
        officialOutboundUsed = $false
        officialApiUsed = $false
        officialLoginUsed = $false
        officialIdentityPersisted = $false
        officialCredentialPersisted = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        singleFollowupRetryAuthorized = $true
        nextStepCode =
            'boot_micron_nlloperator_run_exact_catalog_plus_header_followup_once'
    }
    Write-AtomicUtf8NoBom $authorizationPath `
        (($receipt | ConvertTo-Json -Depth 8) + "`n")
    Copy-ExactFile $authorizationPath $authorizationProtectedPath
    $repairApplied = $true
    [pscustomobject]@{
        Receipt = $receipt
        MicronReceiptPath = $authorizationPath
        MicronReceiptByteLength = (Get-Item -LiteralPath $authorizationPath).Length
        MicronReceiptSha256 = Get-Sha256Hex $authorizationPath
        SamsungProtectedReceiptPath = $authorizationProtectedPath
    } | ConvertTo-Json -Depth 10
}
catch {
    $failure = $_
    $ErrorActionPreference = 'Continue'
    try {
        if (Test-Path -LiteralPath (Join-Path $backupRoot 'database_after_miss.bin')) {
            Copy-ExactFile (Join-Path $backupRoot 'database_after_miss.bin') `
                $databasePath
        }
        foreach ($entry in @(
            @('sqlite_main.bin', $sqlitePaths[0]),
            @('sqlite_shared_memory.bin', $sqlitePaths[1]),
            @('sqlite_write_ahead_log.bin', $sqlitePaths[2]),
            @('start_tool.bin', $targetStartPath),
            @('completion_tool.bin', $targetCompletionPath),
            @('active_pointer.bin', $activePointerPath),
            @('retry_consumption.bin', $consumptionPath)
        )) {
            $backupPath = Join-Path $backupRoot $entry[0]
            if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
                Copy-ExactFile $backupPath $entry[1]
            }
        }
        if (Test-Path -LiteralPath $headerPath) {
            Remove-Item -LiteralPath $headerPath -Force
        }
        if (Test-Path -LiteralPath $authorizationPath) {
            Remove-Item -LiteralPath $authorizationPath -Force
        }
    }
    catch { }
    throw $failure
}
finally {
    if (-not $repairApplied) {
        $ErrorActionPreference = 'Stop'
    }
}
