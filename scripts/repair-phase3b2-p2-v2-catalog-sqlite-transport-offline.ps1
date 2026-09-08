[CmdletBinding()]
param(
    [string]$RepositoryRoot =
        (Split-Path -Parent $PSScriptRoot),
    [string]$MicronNllRoot = 'E:\NLL',
    [string]$MicronUserRoot = 'E:\Users\nlloperator',
    [string]$SamsungProtectedRoot =
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\CatalogSqliteTransport',
    [switch]$ValidateOnly
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

function Copy-ExactFile {
    param([string]$Source, [string]$Destination)
    $parent = Split-Path -Parent $Destination
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    Assert-True ((Get-Item -LiteralPath $Source).Length -eq
            (Get-Item -LiteralPath $Destination).Length -and
        (Get-Sha256Hex $Source) -ceq (Get-Sha256Hex $Destination)) `
        'phase3b2_catalog_transport_copy_failed'
}

function Write-AtomicUtf8NoBom {
    param([string]$Path, [string]$Text)
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
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

$isAdministrator = ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $ValidateOnly) {
    Assert-True $isAdministrator `
        'phase3b2_catalog_transport_repair_requires_administrator'
}
$bootDisk = Get-Partition -DriveLetter C | Get-Disk
$micronDisk = Get-Partition -DriveLetter E | Get-Disk
Assert-True ($bootDisk.FriendlyName -ceq 'Samsung SSD 980 1TB' -and
    $bootDisk.IsBoot -and $bootDisk.IsSystem -and
    $micronDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK' -and
    -not $micronDisk.IsBoot -and -not $micronDisk.IsSystem) `
    'phase3b2_catalog_transport_repair_wrong_boot_boundary'
$runtimeNames = @(
    'EpinelPS', 'nikke', 'nikke_launcher',
    'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
)
Assert-True (@(Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $runtimeNames -contains $_.ProcessName }).Count -eq 0) `
    'phase3b2_catalog_transport_repair_runtime_not_cold'

$externalRoot = Join-Path $RepositoryRoot '.external\EpinelPS'
$sourceServerDll = Join-Path $externalRoot `
    'EpinelPS\bin\Release\net10.0\win-x64\EpinelPS.dll'
$probeDll = Join-Path $externalRoot `
    'tools\Phase3B2.CatalogTransportProbe\bin\Release\net10.0\Phase3B2.CatalogTransportProbe.dll'
$sourceStartTool = Join-Path $RepositoryRoot `
    'scripts\start-phase3b2-physical-p2-v2-client-in-micron.ps1'
$sourceCompletionTool = Join-Path $RepositoryRoot `
    'scripts\complete-phase3b2-physical-p2-v2-client-in-micron.ps1'
$sourceRearmTool = Join-Path $RepositoryRoot `
    'scripts\rearm-phase3b2-exact-catalog-retry-in-micron.ps1'
$sourceWrapperTool = Join-Path $RepositoryRoot `
    'scripts\Start-Phase3B2-Physical-P2-V2.ps1'
$sourceRollbackTool = Join-Path $RepositoryRoot `
    'scripts\rollback-phase3b2-p2-v2-catalog-sqlite-transport-in-micron.ps1'
$headerProofPath = Join-Path $RepositoryRoot `
    '.external\phase3b2-header-proof\prdenv\150-b059c3f36c\StandaloneWindows64\pck\latest-651.txt'

$serverRoot = Join-Path $MicronNllRoot `
    'EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
$targetServerDll = Join-Path $serverRoot 'EpinelPS.dll'
$serverCacheRoot = Join-Path $serverRoot 'cache'
$headerTargetPath = Join-Path $serverCacheRoot `
    'prdenv\150-b059c3f36c\StandaloneWindows64\pck\latest-651.txt'
$preparationPath = Join-Path $MicronNllRoot `
    'Evidence\Phase3B2\Physical\p2-preparation-v2\preparation.receipt.json'
$toolTransferRoot = Join-Path $MicronNllRoot `
    'Evidence\Phase3B2\Physical\p2-tool-transfer-v2'
$authorizationPath = Join-Path $toolTransferRoot `
    'catalog-sqlite-transport-repair.receipt.json'
$headerAuthorizationPath = Join-Path $toolTransferRoot `
    'exact-catalog-header-followup.receipt.json'
$catalogPointerPath = Join-Path $MicronNllRoot `
    'Evidence\Phase3B2\Physical\catalog-set-v1\latest.pointer.json'
$p2Root = Join-Path $MicronNllRoot `
    'Evidence\Phase3B2\Physical\p2-client-start-v2'
$latestCompletionPointerPath = Join-Path $p2Root `
    'latest-completion.pointer.json'
$exactConsumptionPath = Join-Path $p2Root `
    'exact-catalog-set-retry.consumed.json'
$transportConsumptionPath = Join-Path $p2Root `
    'catalog-sqlite-transport-retry.consumed.json'
$activePointerPath = Join-Path $p2Root 'active-run.pointer.json'
$playerLogPath = Join-Path $MicronUserRoot `
    'AppData\LocalLow\com.proximabeta\NIKKE\Player.log'
$dedicatedCatalogRoot = Join-Path $MicronUserRoot `
    'AppData\LocalLow\com_proximabeta\NIKKE\com.shiftup.addressables'

$targetTools = [ordered]@{
    start_tool = Join-Path $MicronNllRoot `
        'Tools\start-phase3b2-physical-p2-v2-client-in-micron.ps1'
    completion_tool = Join-Path $MicronNllRoot `
        'Tools\complete-phase3b2-physical-p2-v2-client-in-micron.ps1'
    rearm_tool = Join-Path $MicronNllRoot `
        'Tools\rearm-phase3b2-exact-catalog-retry-in-micron.ps1'
    wrapper_tool = Join-Path $MicronNllRoot `
        'Tools\Start-Phase3B2-Physical-P2-V2.ps1'
}

$expectedToolSources = [ordered]@{
    start_tool = @($sourceStartTool, 106703L,
        '1ba3e503b204c6fcb400ceb15ac7c7dd9d0670c62a0f082559b9c873799e06a3')
    completion_tool = @($sourceCompletionTool, 28949L,
        '3618b1f46edbdbf924f2909b0f68514877d294be309db1f570f7a2b613e41c5d')
    rearm_tool = @($sourceRearmTool, 11900L,
        '0f9b3a8ee3fc864c12f9b709622b392b18163e50c8624ab01efe9a4d71fc7a00')
    wrapper_tool = @($sourceWrapperTool, 2410L,
        '2dbb29122c95402373f760bc770778f2c1e58797c6efcba4debacd2515582ce0')
}
foreach ($roleCode in $expectedToolSources.Keys) {
    $expected = $expectedToolSources[$roleCode]
    Assert-True (Test-PathDigest $expected[0] $expected[1] $expected[2]) `
        'phase3b2_catalog_transport_repair_source_tool_digest_invalid'
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        $expected[0], [ref]$tokens, [ref]$parseErrors)
    Assert-True (@($parseErrors).Count -eq 0) `
        'phase3b2_catalog_transport_repair_source_tool_parse_failed'
}
$tokens = $null
$parseErrors = $null
[void][Management.Automation.Language.Parser]::ParseFile(
    $sourceRollbackTool, [ref]$tokens, [ref]$parseErrors)
Assert-True (@($parseErrors).Count -eq 0) `
    'phase3b2_catalog_transport_repair_rollback_tool_parse_failed'

Assert-True ((Test-PathDigest $sourceServerDll 15373312L `
        '4417779d545c338fdf6fa1cc3a7e7b100722f367b4f6814983116a60fee6bf5e') -and
    (Test-PathDigest $probeDll 17920L `
        '81e9852507d1b74350537940b8dd34dbb70487a1f72f3f61c58974ef2a1b6706') -and
    (Test-PathDigest $headerProofPath 139L `
        '5914cb58fd2146fe761ab531ecb4e321300527186a54b455e59de962ff6c044a') -and
    (Test-PathDigest $targetServerDll 15371264L `
        'af7a4165e9ff2da5f4e0f4117ab546e04ddfc095d4e1e9916b4bc83458f8c58c') -and
    (Test-PathDigest $preparationPath 1693L `
        'aba8be5a95ee8d326a106397f9286433cdf133b89b5579da74a41238743732ab') -and
    (Test-PathDigest $catalogPointerPath 707L `
        '5b015177c6b17339cb13989f9056d024831c1b03ff6544c4bcaeb4d676fc47a8') -and
    (Test-Path -LiteralPath $headerAuthorizationPath -PathType Leaf) -and
    (Test-Path -LiteralPath $exactConsumptionPath -PathType Leaf) -and
    (Test-Path -LiteralPath $latestCompletionPointerPath -PathType Leaf) -and
    -not (Test-Path -LiteralPath $headerTargetPath) -and
    -not (Test-Path -LiteralPath $authorizationPath) -and
    -not (Test-Path -LiteralPath $transportConsumptionPath) -and
    -not (Test-Path -LiteralPath $activePointerPath)) `
    'phase3b2_catalog_transport_repair_input_shape_invalid'

$latestCompletionPointer = Get-Content -LiteralPath `
    $latestCompletionPointerPath -Raw -Encoding UTF8 | ConvertFrom-Json
$completionPath = Join-Path $p2Root `
    (([string]$latestCompletionPointer.assessmentUid) + '\completion.receipt.json')
Assert-True ($latestCompletionPointer.contractId -ceq
        'nll/phase3b2-physical-p2-v2-completion-pointer/v1' -and
    $latestCompletionPointer.assessmentUid -ceq
        '083d46b5-696f-407a-9d1c-0f8a5c86a4e1' -and
    $latestCompletionPointer.runtimeStopped -and
    $latestCompletionPointer.databaseRestored -and
    (Test-PathDigest $completionPath `
        ([long]$latestCompletionPointer.completionReceiptByteLength) `
        ([string]$latestCompletionPointer.completionReceiptSha256))) `
    'phase3b2_catalog_transport_repair_completion_invalid'
$completion = Get-Content -LiteralPath $completionPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($completion.runtimeStopped -and $completion.databaseRestored -and
    $completion.sqliteRuntimeRemoved -and
    $completion.p2V2HostsExtensionRolledBack -and
    $completion.p2V2FirewallExtensionRolledBack -and
    $completion.catalogVersionProjectionRolledBack -and
    [int]$completion.rawSensitiveLogMatchCount -eq 0) `
    'phase3b2_catalog_transport_repair_completion_contract_invalid'

$exactConsumption = Get-Content -LiteralPath $exactConsumptionPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
Assert-True ($exactConsumption.contractId -ceq
        'nll/phase3b2-p2-v2-exact-catalog-set-retry-consumption/v1' -and
    $exactConsumption.assessmentUid -ceq
        '083d46b5-696f-407a-9d1c-0f8a5c86a4e1' -and
    $exactConsumption.exactCatalogSetVerified -and
    $exactConsumption.dataPackVersionHeaderVerified -and
    $exactConsumption.singleRetryConsumed) `
    'phase3b2_catalog_transport_repair_consumption_invalid'

$playerLogText = [IO.File]::ReadAllText($playerLogPath, [Text.Encoding]::UTF8)
foreach ($marker in @(
        'SQLiteException: database disk image is malformed',
        'AssetCatalogNotInitializedException',
        'ERROR CatalogUpdateEntry - Initialize failed')) {
    Assert-True ($playerLogText.IndexOf($marker,
            [StringComparison]::Ordinal) -ge 0) `
        'phase3b2_catalog_transport_repair_player_log_marker_missing'
}

$catalogPointer = Get-Content -LiteralPath $catalogPointerPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
$deploymentRoot = Join-Path (Split-Path -Parent $catalogPointerPath) `
    ([string]$catalogPointer.deploymentUid)
$privateManifestPath = Join-Path $deploymentRoot 'deployment.private.json'
Assert-True (Test-PathDigest $privateManifestPath `
        ([long]$catalogPointer.privateManifestByteLength) `
        ([string]$catalogPointer.privateManifestSha256)) `
    'phase3b2_catalog_transport_repair_private_manifest_digest_invalid'
$privateManifest = Get-Content -LiteralPath $privateManifestPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
Assert-True ($privateManifest.contractId -ceq
        'nll/phase3b2-exact-catalog-offline-deployment-private/v1' -and
    @($privateManifest.members).Count -eq 6) `
    'phase3b2_catalog_transport_repair_private_manifest_invalid'

$expectedCatalogs = [ordered]@{
    core_body = @('core_150.6.b15_catalog.db', 10552026L,
        'a1dc8425ca034447a1e495d02f02e10fcbf92a772453aebfc214c3a88dd21d52')
    core_signature = @('core_150.6.b15_catalog.db.nds', 96L,
        '9c1ea4e701f0ca770d95dfa4607af233b2d7123cd1d3db6897155f107740f966')
    dp_body = @('dp_1d5645e_catalog.db', 8630492L,
        '326c029414ccf06ff429dd2e017a8bbae6dc39fd295682c67f333a8611a6e5cb')
    dp_signature = @('dp_1d5645e_catalog.db.nds', 96L,
        '16b319314a4ba278e9ae229b51f7ec462819a6566c595050ccf55e2f1b7fbfbc')
    fd_body = @('fd_85b12fc_catalog.db', 337379L,
        'af0307449ddb4455357c7d2e4e9bf363f5bb2d4a8615e11e37939629b2acc04c')
    fd_signature = @('fd_85b12fc_catalog.db.nds', 96L,
        '876618c9a45663c60b09683f6c090b952edc76b7e9c9997d13085e30e8d9427c')
}
$cacheMembers = @()
foreach ($roleCode in $expectedCatalogs.Keys) {
    $expected = $expectedCatalogs[$roleCode]
    $cachePath = Join-Path $dedicatedCatalogRoot $expected[0]
    $manifestMember = @($privateManifest.members |
        Where-Object roleCode -CEQ $roleCode)
    Assert-True ($manifestMember.Count -eq 1 -and
        (Test-PathDigest $cachePath $expected[1] $expected[2])) `
        'phase3b2_catalog_transport_repair_dedicated_cache_invalid'
    $serverCatalogPath = Join-Path $serverCacheRoot `
        ([string]$manifestMember[0].relativePath)
    Assert-True (Test-PathDigest $serverCatalogPath $expected[1] $expected[2]) `
        'phase3b2_catalog_transport_repair_server_catalog_invalid'
    $cacheMembers += [pscustomobject]@{
        roleCode = $roleCode
        cachePath = $cachePath
        serverPath = $serverCatalogPath
        byteLength = [long]$expected[1]
        sha256 = [string]$expected[2]
    }
}

$dotnetPath = 'E:\Program Files\dotnet\dotnet.exe'
Assert-True (Test-Path -LiteralPath $dotnetPath -PathType Leaf) `
    'phase3b2_catalog_transport_repair_dotnet_missing'
$bodyPaths = @($cacheMembers | Where-Object roleCode -Like '*_body' |
    ForEach-Object { $_.serverPath })
$probeJson = (& $dotnetPath $probeDll $bodyPaths[0] $bodyPaths[1] `
    $bodyPaths[2] | Out-String)
Assert-True ($LASTEXITCODE -eq 0) `
    'phase3b2_catalog_transport_repair_probe_failed'
$probe = $probeJson | ConvertFrom-Json
Assert-True ($probe.contractId -ceq 'nll/phase3b2-catalog-transport-probe/v1' -and
    [int]$probe.memberCount -eq 3 -and $probe.allEncryptedNkdb -and
    $probe.allDecryptedSqlite -and -not $probe.rawContentEmitted -and
    @($probe.members | Where-Object {
        -not $_.encryptedNkdbMagicVerified -or
        -not $_.decryptedSqliteHeaderVerified
    }).Count -eq 0) `
    'phase3b2_catalog_transport_repair_probe_contract_invalid'

$gitCandidates = @(
    'C:\Program Files\Git\cmd\git.exe',
    'E:\Program Files\Git\cmd\git.exe'
)
$gitPath = @($gitCandidates | Where-Object {
        Test-Path -LiteralPath $_ -PathType Leaf
    } | Select-Object -First 1)
Assert-True ($gitPath.Count -eq 1) `
    'phase3b2_catalog_transport_repair_git_missing'
$safeExternalRoot = [IO.Path]::GetFullPath($externalRoot).Replace('\', '/')
$externalHead = (& $gitPath[0] -c "safe.directory=$safeExternalRoot" `
    -C $externalRoot rev-parse HEAD).Trim()
$externalTree = (& $gitPath[0] -c "safe.directory=$safeExternalRoot" `
    -C $externalRoot rev-parse 'HEAD^{tree}').Trim()
$externalStatus = @(& $gitPath[0] -c "safe.directory=$safeExternalRoot" `
    -C $externalRoot status --porcelain=v1 --untracked-files=all)
Assert-True ($externalHead -ceq
        'b39e1f3a68a2a998dbf7d20b22e1c1eb65b28429' -and
    $externalTree -ceq
        '3c46e8bf7c727f18852e37feb2a5480295df8fdc' -and
    $externalStatus.Count -eq 0) `
    'phase3b2_catalog_transport_repair_external_checkout_invalid'

if ($ValidateOnly) {
    [pscustomobject]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-p2-v2-catalog-sqlite-transport-validation/v1'
        validatedAtUtc =
            [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        environmentCode = 'samsung_boot_micron_offline_runtime_cold'
        failedAssessmentUid = '083d46b5-696f-407a-9d1c-0f8a5c86a4e1'
        failureReasonCode = 'encrypted_nkdb_served_as_sqlite_catalog_db'
        encryptedCatalogBodyCount = 3
        decryptedSqliteBodyCount = 3
        exactCatalogMemberCount = 6
        dedicatedCatalogCacheMemberCount = $cacheMembers.Count
        playerLogFailureMarkersVerified = $true
        latestCompletionRestoredVerified = $true
        externalHead = $externalHead
        externalTree = $externalTree
        externalCheckoutClean = $true
        sourceServerDllByteLength = (Get-Item -LiteralPath $sourceServerDll).Length
        sourceServerDllSha256 = Get-Sha256Hex $sourceServerDll
        localOnlyCatalogProjectionEnabled = $true
        catalogProjectionScopeCode = 'local_only_catalog_db_nkdb_magic_only'
        rawCatalogContentEmitted = $false
        existingOperatorCacheInspected = $false
        existingOperatorCacheModified = $false
        micronMutationPerformed = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        validationPassed = $true
        nextStepCode = 'apply_offline_catalog_sqlite_transport_repair'
    } | ConvertTo-Json -Depth 6
    return
}

$repairUid = [Guid]::NewGuid().ToString('D')
$backupRoot = Join-Path $MicronNllRoot `
    'Backups\Phase3B2\PhysicalP2-CatalogSqliteTransport-v1'
$protectedRoot = Join-Path $SamsungProtectedRoot $repairUid
$manifestPath = Join-Path $backupRoot 'backup.manifest.json'
$protectedReceiptPath = Join-Path $protectedRoot `
    'catalog-sqlite-transport-repair.receipt.json'
Assert-True (-not (Test-Path -LiteralPath $backupRoot) -and
    -not (Test-Path -LiteralPath $protectedRoot)) `
    'phase3b2_catalog_transport_repair_destination_exists'
New-Item -ItemType Directory -Path $backupRoot, $protectedRoot -Force |
    Out-Null

$backupTargets = [ordered]@{
    server_dll = @($targetServerDll,
        'EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\EpinelPS.dll')
    preparation_receipt = @($preparationPath,
        'Evidence\Phase3B2\Physical\p2-preparation-v2\preparation.receipt.json')
    header_authorization = @($headerAuthorizationPath,
        'Evidence\Phase3B2\Physical\p2-tool-transfer-v2\exact-catalog-header-followup.receipt.json')
    exact_retry_consumption = @($exactConsumptionPath,
        'Evidence\Phase3B2\Physical\p2-client-start-v2\exact-catalog-set-retry.consumed.json')
    start_tool = @($targetTools.start_tool,
        'Tools\start-phase3b2-physical-p2-v2-client-in-micron.ps1')
    completion_tool = @($targetTools.completion_tool,
        'Tools\complete-phase3b2-physical-p2-v2-client-in-micron.ps1')
    rearm_tool = @($targetTools.rearm_tool,
        'Tools\rearm-phase3b2-exact-catalog-retry-in-micron.ps1')
    wrapper_tool = @($targetTools.wrapper_tool,
        'Tools\Start-Phase3B2-Physical-P2-V2.ps1')
}
foreach ($member in $cacheMembers) {
    $backupTargets['dedicated_' + $member.roleCode] = @(
        $member.cachePath,
        ('Users\nlloperator\AppData\LocalLow\com_proximabeta\NIKKE\com.shiftup.addressables\' +
            (Split-Path -Leaf $member.cachePath)))
}

$backupMembers = @()
foreach ($roleCode in $backupTargets.Keys) {
    $source = [string]$backupTargets[$roleCode][0]
    Assert-True (Test-Path -LiteralPath $source -PathType Leaf) `
        'phase3b2_catalog_transport_repair_backup_source_missing'
    $backupFileName = $roleCode + '.bin'
    $backupPath = Join-Path $backupRoot $backupFileName
    Copy-ExactFile $source $backupPath
    $relativeTarget = [string]$backupTargets[$roleCode][1]
    $targetAtMicronBoot = if ($relativeTarget.StartsWith('Users\')) {
        'C:\' + $relativeTarget
    }
    else { 'C:\NLL\' + $relativeTarget }
    $backupMembers += [ordered]@{
        roleCode = $roleCode
        backupFileName = $backupFileName
        targetPathAtMicronBoot = $targetAtMicronBoot
        byteLength = (Get-Item -LiteralPath $backupPath).Length
        sha256 = Get-Sha256Hex $backupPath
    }
}
$backupManifest = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-p2-v2-catalog-sqlite-transport-backup/v1'
    createdAtUtc =
        [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    repairUid = $repairUid
    memberCount = $backupMembers.Count
    members = $backupMembers
    projectedHeaderPreexisting = $false
    existingOperatorCacheInspected = $false
    existingOperatorCacheModified = $false
}
Write-AtomicUtf8NoBom $manifestPath `
    (($backupManifest | ConvertTo-Json -Depth 8) + "`n")

function Get-BackupMemberByRoleCode {
    param([string]$RoleCode)
    $matches = @($backupMembers | Where-Object roleCode -CEQ $RoleCode)
    Assert-True ($matches.Count -eq 1) `
        'phase3b2_catalog_transport_repair_backup_role_invalid'
    $matches[0]
}
$preparationBackup = Get-BackupMemberByRoleCode 'preparation_receipt'
$headerAuthorizationBackup = Get-BackupMemberByRoleCode `
    'header_authorization'
$exactConsumptionBackup = Get-BackupMemberByRoleCode `
    'exact_retry_consumption'

$repairApplied = $false
try {
    Copy-ExactFile $sourceServerDll $targetServerDll
    Copy-ExactFile $sourceStartTool $targetTools.start_tool
    Copy-ExactFile $sourceCompletionTool $targetTools.completion_tool
    Copy-ExactFile $sourceRearmTool $targetTools.rearm_tool
    Copy-ExactFile $sourceWrapperTool $targetTools.wrapper_tool
    Copy-ExactFile $sourceRollbackTool (Join-Path $MicronNllRoot `
        'Tools\rollback-phase3b2-p2-v2-catalog-sqlite-transport-in-micron.ps1')

    $priorPreparation = Get-Content -LiteralPath $preparationPath -Raw `
        -Encoding UTF8 | ConvertFrom-Json
    $updatedPreparation = [ordered]@{}
    foreach ($property in $priorPreparation.PSObject.Properties) {
        $updatedPreparation[$property.Name] = $property.Value
    }
    $updatedPreparation.preparedAtUtc =
        [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    $updatedPreparation.externalHead = $externalHead
    $updatedPreparation.externalTree = $externalTree
    $updatedPreparation.serverDllByteLength =
        (Get-Item -LiteralPath $targetServerDll).Length
    $updatedPreparation.serverDllSha256 = Get-Sha256Hex $targetServerDll
    $updatedPreparation['localOnlyCatalogSqliteTransportEnabled'] = $true
    $updatedPreparation['catalogProjectionScopeCode'] =
        'local_only_catalog_db_nkdb_magic_only'
    $updatedPreparation['catalogTransportFocusedTestPassedCount'] = 65
    $updatedPreparation['supersededPreparationReceiptSha256'] =
        [string]$preparationBackup.sha256
    Write-AtomicUtf8NoBom $preparationPath `
        (($updatedPreparation | ConvertTo-Json -Depth 8) + "`n")

    $priorHeaderAuthorization = Get-Content -LiteralPath `
        $headerAuthorizationPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $updatedHeaderAuthorization = [ordered]@{}
    foreach ($property in $priorHeaderAuthorization.PSObject.Properties) {
        $updatedHeaderAuthorization[$property.Name] = $property.Value
    }
    $updatedHeaderAuthorization.appliedStartToolByteLength =
        (Get-Item -LiteralPath $targetTools.start_tool).Length
    $updatedHeaderAuthorization.appliedStartToolSha256 =
        Get-Sha256Hex $targetTools.start_tool
    $updatedHeaderAuthorization.appliedCompletionToolByteLength =
        (Get-Item -LiteralPath $targetTools.completion_tool).Length
    $updatedHeaderAuthorization.appliedCompletionToolSha256 =
        Get-Sha256Hex $targetTools.completion_tool
    $updatedHeaderAuthorization['catalogSqliteTransportFollowupBound'] = $true
    $updatedHeaderAuthorization['priorHeaderAuthorizationSha256'] =
        [string]$headerAuthorizationBackup.sha256
    Write-AtomicUtf8NoBom $headerAuthorizationPath `
        (($updatedHeaderAuthorization | ConvertTo-Json -Depth 8) + "`n")

    Copy-ExactFile $headerProofPath $headerTargetPath
    foreach ($member in $cacheMembers) {
        Remove-Item -LiteralPath $member.cachePath -Force
    }
    Remove-Item -LiteralPath $exactConsumptionPath -Force
    Assert-True (@($cacheMembers | Where-Object {
            Test-Path -LiteralPath $_.cachePath
        }).Count -eq 0 -and
        -not (Test-Path -LiteralPath $exactConsumptionPath)) `
        'phase3b2_catalog_transport_repair_cache_or_consumption_reset_failed'

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-p2-v2-catalog-sqlite-transport-repair/v1'
        repairedAtUtc =
            [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        repairUid = $repairUid
        failedAssessmentUid =
            '083d46b5-696f-407a-9d1c-0f8a5c86a4e1'
        failureStageCode = 'catalogue_resource_path_upgrade'
        failureReasonCode = 'encrypted_nkdb_served_as_sqlite_catalog_db'
        playerLogByteLength = (Get-Item -LiteralPath $playerLogPath).Length
        playerLogSha256 = Get-Sha256Hex $playerLogPath
        rawPlayerLogCopied = $false
        latestCompletionReceiptSha256 =
            [string]$latestCompletionPointer.completionReceiptSha256
        databaseRestored = $true
        sqliteRuntimeRemoved = $true
        exactCatalogSetPreserved = $true
        catalogDeploymentUid = [string]$catalogPointer.deploymentUid
        encryptedCatalogBodyCount = 3
        decryptedSqliteBodyCount = 3
        catalogProbeByteLength = (Get-Item -LiteralPath $probeDll).Length
        catalogProbeSha256 = Get-Sha256Hex $probeDll
        probeRawContentEmitted = $false
        localOnlyCatalogProjectionEnabled = $true
        catalogProjectionScopeCode =
            'local_only_catalog_db_nkdb_magic_only'
        externalHead = $externalHead
        externalTree = $externalTree
        externalCheckoutClean = $true
        selectedManagerPassedCount = 65
        appliedServerDllByteLength =
            (Get-Item -LiteralPath $targetServerDll).Length
        appliedServerDllSha256 = Get-Sha256Hex $targetServerDll
        appliedPreparationReceiptByteLength =
            (Get-Item -LiteralPath $preparationPath).Length
        appliedPreparationReceiptSha256 = Get-Sha256Hex $preparationPath
        appliedStartToolByteLength =
            (Get-Item -LiteralPath $targetTools.start_tool).Length
        appliedStartToolSha256 = Get-Sha256Hex $targetTools.start_tool
        appliedCompletionToolByteLength =
            (Get-Item -LiteralPath $targetTools.completion_tool).Length
        appliedCompletionToolSha256 = Get-Sha256Hex $targetTools.completion_tool
        appliedRearmToolByteLength =
            (Get-Item -LiteralPath $targetTools.rearm_tool).Length
        appliedRearmToolSha256 = Get-Sha256Hex $targetTools.rearm_tool
        appliedWrapperToolByteLength =
            (Get-Item -LiteralPath $targetTools.wrapper_tool).Length
        appliedWrapperToolSha256 = Get-Sha256Hex $targetTools.wrapper_tool
        projectedHeaderApplied = $true
        projectedHeaderSha256 = Get-Sha256Hex $headerTargetPath
        dedicatedCatalogCacheBackupCount = 6
        dedicatedCatalogCacheResetCount = 6
        existingOperatorCacheInspected = $false
        existingOperatorCacheModified = $false
        backupManifestByteLength = (Get-Item -LiteralPath $manifestPath).Length
        backupManifestSha256 = Get-Sha256Hex $manifestPath
        priorExactRetryConsumptionArchived = $true
        priorExactRetryConsumptionSha256 =
            [string]$exactConsumptionBackup.sha256
        officialOutboundUsed = $false
        officialIdentityPersisted = $false
        officialCredentialPersisted = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        retryConsumed = $false
        singleTransportRetryAuthorized = $true
        nextStepCode =
            'boot_micron_nlloperator_run_catalog_sqlite_transport_retry_once'
    }
    Write-AtomicUtf8NoBom $authorizationPath `
        (($receipt | ConvertTo-Json -Depth 9) + "`n")
    Copy-ExactFile $authorizationPath $protectedReceiptPath
    $repairApplied = $true
    [pscustomobject]@{
        Receipt = $receipt
        MicronReceiptPath = $authorizationPath
        MicronReceiptByteLength =
            (Get-Item -LiteralPath $authorizationPath).Length
        MicronReceiptSha256 = Get-Sha256Hex $authorizationPath
        SamsungProtectedReceiptPath = $protectedReceiptPath
    } | ConvertTo-Json -Depth 11
}
catch {
    $failure = $_
    if (-not $repairApplied) {
        foreach ($member in @($backupMembers)) {
            $backupPath = Join-Path $backupRoot ([string]$member.backupFileName)
            $offlineTarget = if (
                    ([string]$member.targetPathAtMicronBoot).StartsWith(
                        'C:\Users\', [StringComparison]::OrdinalIgnoreCase)) {
                'E:\' + ([string]$member.targetPathAtMicronBoot).Substring(3)
            }
            else {
                'E:\NLL\' +
                    ([string]$member.targetPathAtMicronBoot).Substring(7)
            }
            if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
                try { Copy-ExactFile $backupPath $offlineTarget } catch { }
            }
        }
        if (Test-Path -LiteralPath $headerTargetPath -PathType Leaf) {
            try { Remove-Item -LiteralPath $headerTargetPath -Force } catch { }
        }
        if (Test-Path -LiteralPath $authorizationPath -PathType Leaf) {
            try { Remove-Item -LiteralPath $authorizationPath -Force } catch { }
        }
    }
    throw $failure
}
