#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ $_ -ne [Guid]::Empty })]
    [Guid]$AssessmentUid,
    [ValidatePattern('^[A-Z]$')]
    [string]$MicronDriveLetter = 'E',
    [string]$ProtectedEvidenceRoot =
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\EpinelEnglishSausAB-v1'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Assert-NoReparseAncestors {
    param([string]$Path, [string]$FailureCode)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $volumeRoot = [IO.Path]::GetPathRoot($fullPath)
    $cursor = $fullPath.TrimEnd([IO.Path]::DirectorySeparatorChar)
    while ($true) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            Assert-True (
                ($item.Attributes -band
                    [IO.FileAttributes]::ReparsePoint) -eq 0
            ) $FailureCode
        }
        if ($cursor.TrimEnd([IO.Path]::DirectorySeparatorChar) -ieq
            $volumeRoot.TrimEnd([IO.Path]::DirectorySeparatorChar)) {
            break
        }
        $parent = [IO.Directory]::GetParent($cursor)
        Assert-True ($null -ne $parent) $FailureCode
        $cursor = $parent.FullName
    }
}

function Get-Sha256Hex {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-AtomicUtf8NoBom {
    param([string]$Path, [string]$Text)
    $temporary = $Path + '.partial-' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText(
            $temporary, $Text, [Text.UTF8Encoding]::new($false)
        )
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Assert-SafeDirectoryRoot {
    param([string]$Path, [string]$FailureCode)
    Assert-True (Test-Path -LiteralPath $Path -PathType Container) `
        $FailureCode
    $item = Get-Item -LiteralPath $Path -Force
    Assert-True (
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0
    ) $FailureCode
}

function Test-ExpectedTree {
    param([string]$Root, [object[]]$ExpectedMembers)
    Assert-SafeDirectoryRoot $Root `
        'phase3b2_english_saus_prerun_tree_root_invalid'
    $directories = @(Get-ChildItem -LiteralPath $Root -Directory -Force)
    $files = @(Get-ChildItem -LiteralPath $Root -File -Force |
        Sort-Object Name)
    if ($directories.Count -ne 0 -or $files.Count -ne 2 -or
        $ExpectedMembers.Count -ne 2) {
        return $false
    }
    if (@($files | Where-Object {
                ($_.Attributes -band
                    [IO.FileAttributes]::ReparsePoint) -ne 0
            }).Count -ne 0) {
        return $false
    }
    for ($index = 0; $index -lt 2; $index++) {
        $expected = $ExpectedMembers[$index]
        if ($files[$index].Name -cne [string]$expected.leafName -or
            $files[$index].Length -ne [long]$expected.byteLength -or
            (Get-Sha256Hex $files[$index].FullName) -cne
                [string]$expected.sha256) {
            return $false
        }
    }
    return $true
}

$protectedBoundary = [IO.Path]::GetFullPath(
    'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\' +
    'Micron-PrePhysicalLane-20260823\PhysicalP2'
)
$ProtectedEvidenceRoot = [IO.Path]::GetFullPath($ProtectedEvidenceRoot)
Assert-True (
    $ProtectedEvidenceRoot.StartsWith(
        $protectedBoundary + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    )
) 'phase3b2_english_saus_prerun_protected_boundary_invalid'
Assert-NoReparseAncestors $ProtectedEvidenceRoot `
    'phase3b2_english_saus_prerun_protected_reparse_boundary_invalid'
Assert-True ($env:SystemDrive -ceq 'C:') `
    'phase3b2_english_saus_prerun_wrong_samsung_boundary'
$micronDrive = $MicronDriveLetter + ':'
Assert-True (
    $micronDrive -cne $env:SystemDrive -and
    (Test-Path -LiteralPath (
        Join-Path $micronDrive 'Windows\explorer.exe'
    ) -PathType Leaf)
) 'phase3b2_english_saus_prerun_micron_not_offline'
$systemVolumeText = (& cmd.exe /d /c 'vol C:' 2>&1 | Out-String)
$micronVolumeText = (& cmd.exe /d /c ('vol ' + $micronDrive) 2>&1 |
    Out-String)
$systemVolumeGuid = (& mountvol.exe C: /L 2>&1 | Out-String).Trim()
$micronVolumeGuid = (& mountvol.exe $micronDrive /L 2>&1 |
    Out-String).Trim()
Assert-True (
    $systemVolumeText.Contains('248A-C705') -and
    $micronVolumeText.Contains('A012-6422') -and
    $systemVolumeGuid -ceq
        '\\?\Volume{0fe78c09-8125-47ca-acba-18cf8b2f4c88}\' -and
    $micronVolumeGuid -ceq
        '\\?\Volume{cbdf64bb-193a-4389-8061-8dbef2bca563}\'
) 'phase3b2_english_saus_prerun_volume_identity_invalid'
Assert-True (@(Get-Process -Name @(
        'nikke', 'EpinelPS', 'nikke_launcher',
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
    ) -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_english_saus_prerun_runtime_not_cold'

$uid = $AssessmentUid.ToString()
$physicalRoot = Join-Path $micronDrive 'NLL\Evidence\Phase3B2\Physical'
$runtimeRoot = Join-Path $micronDrive `
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
$toolsRoot = Join-Path $micronDrive 'NLL\Tools'
$micronRoot = Join-Path (
    Join-Path $physicalRoot 'epinel-english-saus-ab-v1'
) $uid
$protectedRoot = Join-Path $ProtectedEvidenceRoot $uid
$quarantineReceiptPath = Join-Path $micronRoot `
    'quarantine.receipt.json'
$protectedQuarantineReceiptPath = Join-Path $protectedRoot `
    'quarantine.receipt.json'
$manifestPath = Join-Path $micronRoot 'before.manifest.json'
$protectedManifestPath = Join-Path $protectedRoot 'before.manifest.json'
$rollbackPath = Join-Path $micronRoot 'rollback.plan.json'
$protectedRollbackPath = Join-Path $protectedRoot 'rollback.plan.json'
$prerunPath = Join-Path $micronRoot 'pre-run.audit.receipt.json'
$protectedPrerunPath = Join-Path $protectedRoot `
    'pre-run.audit.receipt.json'
$serverCachePreRunPath = Join-Path $micronRoot `
    'server-cache.pre-run.receipt.json'
$protectedServerCachePreRunPath = Join-Path $protectedRoot `
    'server-cache.pre-run.receipt.json'
Assert-NoReparseAncestors $micronRoot `
    'phase3b2_english_saus_prerun_micron_assessment_reparse_invalid'
Assert-NoReparseAncestors $protectedRoot `
    'phase3b2_english_saus_prerun_protected_assessment_reparse_invalid'
Assert-True (
    (Test-Path -LiteralPath $quarantineReceiptPath -PathType Leaf) -and
    (Test-Path -LiteralPath $protectedQuarantineReceiptPath -PathType Leaf) -and
    (Test-Path -LiteralPath $manifestPath -PathType Leaf) -and
    (Test-Path -LiteralPath $protectedManifestPath -PathType Leaf) -and
    (Test-Path -LiteralPath $rollbackPath -PathType Leaf) -and
    (Test-Path -LiteralPath $protectedRollbackPath -PathType Leaf)
) 'phase3b2_english_saus_prerun_input_shape_invalid'
Assert-True (
    (Get-Sha256Hex $quarantineReceiptPath) -ceq
        (Get-Sha256Hex $protectedQuarantineReceiptPath) -and
    (Get-Sha256Hex $manifestPath) -ceq
        (Get-Sha256Hex $protectedManifestPath) -and
    (Get-Sha256Hex $rollbackPath) -ceq
        (Get-Sha256Hex $protectedRollbackPath)
) 'phase3b2_english_saus_prerun_dual_seal_drift'
$quarantineReceipt = Get-Content -LiteralPath $quarantineReceiptPath `
    -Raw -Encoding UTF8 | ConvertFrom-Json
$beforeManifest = Get-Content -LiteralPath $manifestPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
$rollbackPlan = Get-Content -LiteralPath $rollbackPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
Assert-True (
    $quarantineReceipt.contractId -ceq
        'nll/phase3b2-epinel-english-saus-ab-quarantine/v1' -and
    $quarantineReceipt.assessmentUid -ceq $uid -and
    $quarantineReceipt.beforeManifestSha256 -ceq
        (Get-Sha256Hex $manifestPath) -and
    $quarantineReceipt.rollbackPlanSha256 -ceq
        (Get-Sha256Hex $rollbackPath) -and
    $beforeManifest.contractId -ceq
        'nll/phase3b2-epinel-english-saus-before-manifest/v1' -and
    $beforeManifest.assessmentUid -ceq $uid -and
    $rollbackPlan.contractId -ceq
        'nll/phase3b2-epinel-english-saus-ab-rollback-plan/v1' -and
    $rollbackPlan.assessmentUid -ceq $uid -and
    $rollbackPlan.expectedBeforeManifestSha256 -ceq
        (Get-Sha256Hex $manifestPath)
) 'phase3b2_english_saus_prerun_contract_invalid'

$clientEnglishRoot = Join-Path $micronDrive (
    'NLL\Clients\NIKKE-150.6.9-Physical\Unity\' +
    'com_proximabeta_NIKKE\saus\en'
)
Assert-NoReparseAncestors (Split-Path -Parent $clientEnglishRoot) `
    'phase3b2_english_saus_prerun_client_parent_reparse_invalid'
$quarantineRoot = Join-Path $micronRoot 'quarantine\en'
$micronBeforeRoot = Join-Path $micronRoot 'before-copy\en'
$protectedBeforeRoot = Join-Path $protectedRoot 'before-copy\en'
$beforeMembers = @($beforeManifest.members)
Assert-True (
    -not (Test-Path -LiteralPath $clientEnglishRoot) -and
    (Test-ExpectedTree $quarantineRoot $beforeMembers) -and
    (Test-ExpectedTree $micronBeforeRoot $beforeMembers) -and
    (Test-ExpectedTree $protectedBeforeRoot $beforeMembers)
) 'phase3b2_english_saus_prerun_quarantine_or_backup_invalid'

$activePointerPaths = @(
    (Join-Path $physicalRoot `
        'epinel-minimal-reference-v1\active-run.pointer.json'),
    (Join-Path $physicalRoot `
        'epinel-user-progression-reference-v1\active-run.pointer.json')
)
$sqlitePaths = @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal' |
    ForEach-Object { Join-Path $runtimeRoot $_ })
Assert-True (
    @($activePointerPaths | Where-Object {
            Test-Path -LiteralPath $_ -PathType Leaf
        }).Count -eq 0 -and
    @($sqlitePaths | Where-Object {
            Test-Path -LiteralPath $_ -PathType Leaf
        }).Count -eq 0
) 'phase3b2_english_saus_prerun_runtime_residue_present'

$goldenPins = @(
    [ordered]@{
        roleCode = 'golden_start_wrapper'
        path = Join-Path $toolsRoot 'Start-Phase3B2-Epinel-NativeCache.ps1'
        sha256 = 'fe667ba466ea27a5bfd55e09c4d0cd9ef94b04d434d95ac1590ccd7f813e493b'
    },
    [ordered]@{
        roleCode = 'golden_inner_start'
        path = Join-Path $toolsRoot `
            'start-phase3b2-epinel-minimal-reference-in-micron.ps1'
        sha256 = 'a039cd5186df92c16c0091f7d4b4c4bbb907d0bf2adc3ff94d8d425699bc5f69'
    },
    [ordered]@{
        roleCode = 'golden_completion_wrapper'
        path = Join-Path $toolsRoot 'Complete-Phase3B2-Epinel-Minimal.ps1'
        sha256 = '16aa339bc83336b6bd3c72da21624eb890e336e22fb1c9672160fa745b0250c1'
    },
    [ordered]@{
        roleCode = 'golden_inner_completion'
        path = Join-Path $toolsRoot `
            'complete-phase3b2-epinel-minimal-reference-in-micron.ps1'
        sha256 = '0ff9cc8285b46fe96d16fe1fe1aca532a6a2b39d89cc9a15f6c611444d63fe09'
    },
    [ordered]@{
        roleCode = 'golden_database'
        path = Join-Path $runtimeRoot 'db.json'
        sha256 = 'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194'
    },
    [ordered]@{
        roleCode = 'golden_server_binary'
        path = Join-Path $runtimeRoot 'EpinelPS.dll'
        sha256 = 'aaa1e49d7a879a6b5ec17ad4c4094ce7d98ce86f860c1529a9ab4d6aecb51f7c'
    }
)
foreach ($pin in $goldenPins) {
    Assert-True (
        (Test-Path -LiteralPath $pin.path -PathType Leaf) -and
        (Get-Sha256Hex $pin.path) -ceq [string]$pin.sha256
    ) 'phase3b2_english_saus_prerun_golden_pin_drift'
}

$dotnetPath = Join-Path $micronDrive 'Program Files\dotnet\dotnet.exe'
$verifierPath = Join-Path $micronDrive (
    'NLL\Tools\Phase3B2.NativeCacheVerifier-v1\' +
    'Phase3B2.NativeCacheMaterializer.dll'
)
$cacheRoot = Join-Path $runtimeRoot 'cache'
$inspectionText = (& $dotnetPath $verifierPath `
    'inspect-cache-tree' $cacheRoot 2>&1 | Out-String).Trim()
Assert-True ($LASTEXITCODE -eq 0) `
    'phase3b2_english_saus_prerun_cache_inspection_failed'
$inspection = $inspectionText | ConvertFrom-Json
Assert-True (
    $inspection.contractId -ceq
        'nll/phase3b2-native-cache-tree-inspection/v1' -and
    $inspection.longPathSafeEnumerationUsed -and
    $inspection.fileCount -eq 40111 -and
    [long]$inspection.contentByteLength -eq 39030643658L -and
    $inspection.partialMemberCount -eq 0
) 'phase3b2_english_saus_prerun_cache_shape_invalid'

$playerLogPath = Join-Path $micronDrive (
    'Users\nlloperator\AppData\LocalLow\com.proximabeta\NIKKE\Player.log'
)
Assert-True (Test-Path -LiteralPath $playerLogPath -PathType Leaf) `
    'phase3b2_english_saus_prerun_player_log_missing'
$playerLog = Get-Item -LiteralPath $playerLogPath
$playerSnapshot = [ordered]@{
    byteLength = [long]$playerLog.Length
    sha256 = Get-Sha256Hex $playerLogPath
    creationTimeUtc = $playerLog.CreationTimeUtc.ToString('o')
    lastWriteTimeUtc = $playerLog.LastWriteTimeUtc.ToString('o')
}

$currentAppLogs = @(
    Get-ChildItem -LiteralPath (Join-Path $runtimeRoot 'logs') `
        -Filter 'app-*.log' -File | Sort-Object Name
)
$priorAppLogs = @($quarantineReceipt.preRunAppLogSnapshot)
Assert-True ($currentAppLogs.Count -eq $priorAppLogs.Count) `
    'phase3b2_english_saus_prerun_app_log_set_drift'
for ($index = 0; $index -lt $currentAppLogs.Count; $index++) {
    Assert-True (
        $currentAppLogs[$index].Name -ceq
            [string]$priorAppLogs[$index].leafName -and
        $currentAppLogs[$index].Length -eq
            [long]$priorAppLogs[$index].byteLength -and
        (Get-Sha256Hex $currentAppLogs[$index].FullName) -ceq
            [string]$priorAppLogs[$index].sha256
    ) 'phase3b2_english_saus_prerun_app_log_drift'
}

$receipt = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-epinel-english-saus-ab-prerun-audit/v1'
    sealedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    assessmentUid = $uid
    quarantineReceiptSha256 = Get-Sha256Hex $quarantineReceiptPath
    beforeManifestSha256 = Get-Sha256Hex $manifestPath
    rollbackPlanSha256 = Get-Sha256Hex $rollbackPath
    boundaryVerificationCode =
        'exact_volume_identity_plus_offline_os_and_golden_pins'
    runtimeCold = $true
    activeRunPointerCount = 0
    sqliteRuntimeMemberCount = 0
    activeEnglishRootAbsent = $true
    quarantineRootReparsePoint = $false
    backupRootReparsePointCount = 0
    goldenPinCount = $goldenPins.Count
    goldenPinMatchedCount = $goldenPins.Count
    serverCacheFileCount = [int]$inspection.fileCount
    serverCacheContentByteLength = [long]$inspection.contentByteLength
    serverCachePartialMemberCount = [int]$inspection.partialMemberCount
    playerLogSnapshot = $playerSnapshot
    rawPlayerLogCopied = $false
    appLogSnapshot = $priorAppLogs
    originalInstallInspected = $false
    originalInstallModified = $false
    databaseModified = $false
    serverCacheModified = $false
    goldenToolsModified = $false
    localLowInspected = $true
    localLowMutationPerformedByThisTool = $false
    existingOperatorCacheInspected = $false
    existingOperatorCacheModified = $false
    runtimeBindingCreated = $false
    startupPreflightModified = $false
    officialOutboundUsed = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
    singleAbRunAuthorized = $true
    validationRunConsumed = $false
    nextStepCode =
        'boot_micron_run_existing_golden_once_then_complete_and_return_samsung'
}
$receiptText = ($receipt | ConvertTo-Json -Depth 8) +
    [Environment]::NewLine
$existingPrerunPaths = @(
    @($prerunPath, $protectedPrerunPath) | Where-Object {
        Test-Path -LiteralPath $_ -PathType Leaf
    }
)
if ($existingPrerunPaths.Count -gt 0) {
    # Publication is deliberately resumable.  If the first of the two final
    # copies was committed before an interruption, validate it against the
    # still-cold state above and copy those exact bytes to the missing side.
    $existingReceiptText = Get-Content -LiteralPath $existingPrerunPaths[0] `
        -Raw -Encoding UTF8
    $existingReceipt = $existingReceiptText | ConvertFrom-Json
    $existingRollbackProperty =
        $existingReceipt.PSObject.Properties['rollbackPlanSha256']
    # The first immutable v1 receipt predates the explicit rollback-plan
    # cross-link.  Its rollback plan is still authenticated above through the
    # dual quarantine receipt and the dual rollback-plan bytes.  Preserve that
    # historical receipt rather than rewriting it; validate the cross-link
    # when the optional field is present.
    $existingRollbackBindingValid =
        $null -eq $existingRollbackProperty -or
        [string]$existingRollbackProperty.Value -ceq
            (Get-Sha256Hex $rollbackPath)
    Assert-True (
        $existingReceipt.contractId -ceq
            'nll/phase3b2-epinel-english-saus-ab-prerun-audit/v1' -and
        $existingReceipt.assessmentUid -ceq $uid -and
        $existingReceipt.quarantineReceiptSha256 -ceq
            (Get-Sha256Hex $quarantineReceiptPath) -and
        $existingReceipt.beforeManifestSha256 -ceq
            (Get-Sha256Hex $manifestPath) -and
        $existingRollbackBindingValid -and
        $existingReceipt.runtimeCold -and
        $existingReceipt.activeEnglishRootAbsent -and
        $existingReceipt.goldenPinMatchedCount -eq $goldenPins.Count -and
        $existingReceipt.serverCacheFileCount -eq
            [int]$inspection.fileCount -and
        [long]$existingReceipt.serverCacheContentByteLength -eq
            [long]$inspection.contentByteLength -and
        $existingReceipt.playerLogSnapshot.sha256 -ceq
            [string]$playerSnapshot.sha256 -and
        $existingReceipt.playerLogSnapshot.byteLength -eq
            [long]$playerSnapshot.byteLength -and
        $existingReceipt.singleAbRunAuthorized -and
        -not $existingReceipt.validationRunConsumed
    ) 'phase3b2_english_saus_prerun_existing_receipt_invalid'
    if ($existingPrerunPaths.Count -eq 2) {
        Assert-True (
            (Get-Sha256Hex $prerunPath) -ceq
                (Get-Sha256Hex $protectedPrerunPath)
        ) 'phase3b2_english_saus_prerun_existing_receipt_drift'
    }
    elseif (Test-Path -LiteralPath $prerunPath -PathType Leaf) {
        Write-AtomicUtf8NoBom $protectedPrerunPath $existingReceiptText
    }
    else {
        Write-AtomicUtf8NoBom $prerunPath $existingReceiptText
    }
    $receipt = $existingReceipt
}
else {
    Write-AtomicUtf8NoBom $prerunPath $receiptText
    Write-AtomicUtf8NoBom $protectedPrerunPath $receiptText
}
$receiptSha256 = Get-Sha256Hex $prerunPath
Assert-True ((Get-Sha256Hex $protectedPrerunPath) -ceq $receiptSha256) `
    'phase3b2_english_saus_prerun_receipt_copy_invalid'

$cacheIdentityToolPath = Join-Path $PSScriptRoot `
    'get-phase3b2-epinel-exact-server-cache-identity-offline.ps1'
$expectedCacheIdentityToolSha256 =
    '67acfc27e3ab13257cdaa0c572dcdb3634d20634679521cbbe2060e3fe9f2754'
Assert-True (
    (Test-Path -LiteralPath $cacheIdentityToolPath -PathType Leaf) -and
    (Get-Sha256Hex $cacheIdentityToolPath) -ceq
        $expectedCacheIdentityToolSha256
) 'phase3b2_english_saus_prerun_cache_identity_tool_invalid'
$cacheIdentityText = (& $cacheIdentityToolPath `
    -MicronDriveLetter $MicronDriveLetter `
    -TemporaryRoot $protectedRoot 2>&1 | Out-String).Trim()
$cacheIdentity = $cacheIdentityText | ConvertFrom-Json
Assert-True (
    $cacheIdentity.contractId -ceq
        'nll/phase3b2-epinel-server-cache-exact-identity/v1' -and
    $cacheIdentity.exactServerCacheIdentityVerified -and
    $cacheIdentity.memberDigestVerificationPerformed -and
    $cacheIdentity.activeCacheCanonicalSha256 -ceq
        '159b152960c35e8898bc1ea06dd17239b200f46e65095fa79b1aeead19dd8c56'
) 'phase3b2_english_saus_prerun_cache_identity_invalid'
$serverCachePreRunReceipt = [ordered]@{
    schemaVersion = 1
    contractId =
        'nll/phase3b2-epinel-english-saus-ab-server-cache-prerun-identity/v1'
    sealedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    assessmentUid = $uid
    preRunAuditReceiptSha256 = $receiptSha256
    quarantineReceiptSha256 = Get-Sha256Hex $quarantineReceiptPath
    materializationReceiptSha256 =
        [string]$cacheIdentity.materializationReceiptSha256
    materializationPrivateManifestSha256 =
        [string]$cacheIdentity.materializationPrivateManifestSha256
    deploymentReceiptSha256 =
        [string]$cacheIdentity.deploymentReceiptSha256
    headerRepairReceiptSha256 =
        [string]$cacheIdentity.headerRepairReceiptSha256
    sausStagingReceiptSha256 =
        [string]$cacheIdentity.sausStagingReceiptSha256
    baselineFileCount = [int]$cacheIdentity.baselineFileCount
    baselineContentByteLength =
        [long]$cacheIdentity.baselineContentByteLength
    baselineCanonicalSha256 =
        [string]$cacheIdentity.baselineCanonicalSha256
    derivedManifestMemberCount =
        [int]$cacheIdentity.derivedManifestMemberCount
    derivedManifestContentByteLength =
        [long]$cacheIdentity.derivedManifestContentByteLength
    appendedMemberCount = [int]$cacheIdentity.appendedMemberCount
    verifierBundleManifestSha256 =
        [string]$cacheIdentity.verifierBundleManifestSha256
    verifierDllSha256 = [string]$cacheIdentity.verifierDllSha256
    expectedMemberCount = [int]$cacheIdentity.expectedMemberCount
    observedMemberCount = [int]$cacheIdentity.observedMemberCount
    observedContentByteLength =
        [long]$cacheIdentity.observedContentByteLength
    activeCacheCanonicalSha256 =
        [string]$cacheIdentity.activeCacheCanonicalSha256
    memberDigestVerificationPerformed = $true
    longPathSafeEnumerationUsed = $true
    exactServerCacheIdentityVerified = $true
    temporaryDerivedManifestPersisted = $false
    rawMemberListEmitted = $false
    serverCacheModified = $false
    networkUsed = $false
}
$serverCachePreRunText = (
    $serverCachePreRunReceipt | ConvertTo-Json -Depth 8
) + [Environment]::NewLine
$existingCacheIdentityPaths = @(
    @($serverCachePreRunPath, $protectedServerCachePreRunPath) |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
)
if ($existingCacheIdentityPaths.Count -gt 0) {
    $existingCacheIdentityText = Get-Content -LiteralPath `
        $existingCacheIdentityPaths[0] -Raw -Encoding UTF8
    $existingCacheIdentity = $existingCacheIdentityText | ConvertFrom-Json
    Assert-True (
        $existingCacheIdentity.contractId -ceq
            'nll/phase3b2-epinel-english-saus-ab-server-cache-prerun-identity/v1' -and
        $existingCacheIdentity.assessmentUid -ceq $uid -and
        $existingCacheIdentity.preRunAuditReceiptSha256 -ceq
            $receiptSha256 -and
        $existingCacheIdentity.quarantineReceiptSha256 -ceq
            (Get-Sha256Hex $quarantineReceiptPath) -and
        $existingCacheIdentity.activeCacheCanonicalSha256 -ceq
            [string]$cacheIdentity.activeCacheCanonicalSha256 -and
        $existingCacheIdentity.exactServerCacheIdentityVerified -and
        $existingCacheIdentity.memberDigestVerificationPerformed
    ) 'phase3b2_english_saus_prerun_existing_cache_identity_invalid'
    if ($existingCacheIdentityPaths.Count -eq 2) {
        Assert-True (
            (Get-Sha256Hex $serverCachePreRunPath) -ceq
                (Get-Sha256Hex $protectedServerCachePreRunPath)
        ) 'phase3b2_english_saus_prerun_cache_identity_copy_drift'
    }
    elseif (Test-Path -LiteralPath $serverCachePreRunPath -PathType Leaf) {
        Write-AtomicUtf8NoBom $protectedServerCachePreRunPath `
            $existingCacheIdentityText
    }
    else {
        Write-AtomicUtf8NoBom $serverCachePreRunPath `
            $existingCacheIdentityText
    }
    $serverCachePreRunReceipt = $existingCacheIdentity
}
else {
    Write-AtomicUtf8NoBom $serverCachePreRunPath $serverCachePreRunText
    Write-AtomicUtf8NoBom $protectedServerCachePreRunPath `
        $serverCachePreRunText
}
$serverCachePreRunSha256 = Get-Sha256Hex $serverCachePreRunPath
Assert-True (
    (Get-Sha256Hex $protectedServerCachePreRunPath) -ceq
        $serverCachePreRunSha256
) 'phase3b2_english_saus_prerun_cache_identity_copy_invalid'

[ordered]@{
    Receipt = $receipt
    MicronReceiptPath = $prerunPath
    MicronReceiptByteLength = (Get-Item -LiteralPath $prerunPath).Length
    MicronReceiptSha256 = $receiptSha256
    ProtectedReceiptPath = $protectedPrerunPath
    ServerCachePreRunReceipt = $serverCachePreRunReceipt
    ServerCachePreRunReceiptPath = $serverCachePreRunPath
    ServerCachePreRunReceiptSha256 = $serverCachePreRunSha256
    ProtectedServerCachePreRunReceiptPath =
        $protectedServerCachePreRunPath
    MicronStartCommand =
        "& 'C:\NLL\Tools\Start-Phase3B2-Epinel-NativeCache.ps1'"
    MicronCompletionOnFailureCommand =
        "& 'C:\NLL\Tools\Complete-Phase3B2-Epinel-Minimal.ps1' -ObservedStageCode catalogue_path -OutcomeCode system_error"
    MicronCompletionOnLobbyCommand =
        "& 'C:\NLL\Tools\Complete-Phase3B2-Epinel-Minimal.ps1' -ObservedStageCode lobby -OutcomeCode success"
    SamsungClassificationCommand =
        "& 'C:\Users\zih44\Documents\Github\Nikke-Local-Lab\scripts\classify-and-restore-phase3b2-epinel-english-saus-ab-offline.ps1' -AssessmentUid '$uid'"
    SamsungEmergencyRestoreOnlyCommand =
        "& 'C:\Users\zih44\Documents\Github\Nikke-Local-Lab\scripts\classify-and-restore-phase3b2-epinel-english-saus-ab-offline.ps1' -AssessmentUid '$uid' -RestoreOnly"
} | ConvertTo-Json -Depth 8
