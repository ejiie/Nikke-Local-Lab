#requires -Version 5.1

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Z]$')]
    [string]$MicronDriveLetter = 'E',
    [string]$ProtectedEvidenceRoot =
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\EpinelEnglishSausAB-v1',
    [switch]$AuditOnly
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

function Get-TextSha256Hex {
    param([string]$Text)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $algorithm.ComputeHash($bytes)
        return ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $algorithm.Dispose()
    }
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

function Get-EnglishCacheMembers {
    param([string]$Root)

    Assert-True (Test-Path -LiteralPath $Root -PathType Container) `
        'phase3b2_english_saus_ab_client_root_missing'
    $rootItem = Get-Item -LiteralPath $Root -Force
    Assert-True (
        ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0
    ) 'phase3b2_english_saus_ab_client_root_reparse_point'
    $directories = @(Get-ChildItem -LiteralPath $Root -Directory -Force)
    $files = @(Get-ChildItem -LiteralPath $Root -File -Force |
        Sort-Object Name)
    Assert-True ($directories.Count -eq 0 -and $files.Count -eq 2) `
        'phase3b2_english_saus_ab_client_shape_invalid'
    $expectedNames = @('asset-catalog-0.cat', 'asset-catalog-0.cat.nds')
    Assert-True (
        $files[0].Name -ceq $expectedNames[0] -and
        $files[1].Name -ceq $expectedNames[1]
    ) 'phase3b2_english_saus_ab_client_member_invalid'

    $emptySha256 =
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
    @(
        foreach ($file in $files) {
            Assert-True (
                ($file.Attributes -band
                    [IO.FileAttributes]::ReparsePoint) -eq 0 -and
                $file.Length -eq 0 -and
                (Get-Sha256Hex $file.FullName) -ceq $emptySha256
            ) 'phase3b2_english_saus_ab_client_member_digest_invalid'
            [pscustomobject][ordered]@{
                roleCode = if ($file.Name.EndsWith('.nds')) {
                    'english_asset_catalog_companion'
                } else {
                    'english_asset_catalog_body'
                }
                leafName = $file.Name
                byteLength = [long]$file.Length
                sha256 = Get-Sha256Hex $file.FullName
                creationTimeUtc = $file.CreationTimeUtc.ToString('o')
                lastWriteTimeUtc = $file.LastWriteTimeUtc.ToString('o')
            }
        }
    )
}

function Test-EnglishCacheCopy {
    param([string]$Root, [object[]]$ExpectedMembers)

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return $false
    }
    $rootItem = Get-Item -LiteralPath $Root -Force
    if (($rootItem.Attributes -band
            [IO.FileAttributes]::ReparsePoint) -ne 0) {
        return $false
    }
    $directories = @(Get-ChildItem -LiteralPath $Root -Directory -Force)
    $files = @(Get-ChildItem -LiteralPath $Root -File -Force |
        Sort-Object Name)
    if ($directories.Count -ne 0 -or $files.Count -ne 2) { return $false }
    if (@($files | Where-Object {
                ($_.Attributes -band
                    [IO.FileAttributes]::ReparsePoint) -ne 0
            }).Count -ne 0) {
        return $false
    }
    for ($index = 0; $index -lt $files.Count; $index++) {
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
$normalizedProtectedRoot = [IO.Path]::GetFullPath($ProtectedEvidenceRoot)
Assert-True (
    $normalizedProtectedRoot.StartsWith(
        $protectedBoundary + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    )
) 'phase3b2_english_saus_ab_protected_boundary_invalid'
$ProtectedEvidenceRoot = $normalizedProtectedRoot
Assert-NoReparseAncestors $ProtectedEvidenceRoot `
    'phase3b2_english_saus_ab_protected_reparse_boundary_invalid'

Assert-True ($env:SystemDrive -ceq 'C:') `
    'phase3b2_english_saus_ab_wrong_samsung_boot_boundary'
$micronDrive = $MicronDriveLetter + ':'
$boundaryMarker = if ($AuditOnly) {
    Join-Path $micronDrive 'NLL\Tools\Start-Phase3B2-Epinel-NativeCache.ps1'
} else {
    Join-Path $micronDrive 'Windows\explorer.exe'
}
Assert-True (
    $micronDrive -cne $env:SystemDrive -and
    (Test-Path -LiteralPath $boundaryMarker -PathType Leaf)
) 'phase3b2_english_saus_ab_micron_offline_boundary_invalid'

$boundaryVerificationCode = 'audit_only_exact_os_and_golden_markers'
if (-not $AuditOnly) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $administratorTokenVerified = $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
    $physicalDiskIdentityVerified = $false
    if ($administratorTokenVerified) {
        try {
            $systemDisk = Get-Partition -DriveLetter C | Get-Disk
            $micronDisk = Get-Partition -DriveLetter $MicronDriveLetter |
                Get-Disk
            $physicalDiskIdentityVerified =
                $systemDisk.Number -ne $micronDisk.Number -and
                $systemDisk.FriendlyName -like 'Samsung SSD 980*' -and
                $micronDisk.FriendlyName -like 'Micron_2200*'
        }
        catch {
            $physicalDiskIdentityVerified = $false
        }
    }
    if ($physicalDiskIdentityVerified) {
        $boundaryVerificationCode = 'administrator_physical_disk_identity'
    }
    else {
        $systemVolumeText = (& cmd.exe /d /c 'vol C:' 2>&1 | Out-String)
        $micronVolumeText = (& cmd.exe /d /c `
            ('vol ' + $micronDrive) 2>&1 | Out-String)
        $systemVolumeGuid = (& mountvol.exe C: /L 2>&1 | Out-String).Trim()
        $micronVolumeGuid = (& mountvol.exe $micronDrive /L 2>&1 |
            Out-String).Trim()
        Assert-True (
            $systemVolumeText.Contains('248A-C705') -and
            $micronVolumeText.Contains('A012-6422') -and
            $systemVolumeGuid -ceq
                '\\?\Volume{0fe78c09-8125-47ca-acba-18cf8b2f4c88}\' -and
            $micronVolumeGuid -ceq
                '\\?\Volume{cbdf64bb-193a-4389-8061-8dbef2bca563}\' -and
            $systemVolumeGuid -cne $micronVolumeGuid
        ) 'phase3b2_english_saus_ab_volume_identity_invalid'
        $boundaryVerificationCode =
            'exact_volume_identity_plus_offline_os_and_golden_pins'
    }
}

Assert-True (@(Get-Process -Name @(
        'nikke', 'EpinelPS', 'nikke_launcher',
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
    ) -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_english_saus_ab_runtime_not_cold'

$physicalRoot = Join-Path $micronDrive 'NLL\Evidence\Phase3B2\Physical'
$runtimeRoot = Join-Path $micronDrive `
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
$toolsRoot = Join-Path $micronDrive 'NLL\Tools'
$clientEnglishRoot = Join-Path $micronDrive (
    'NLL\Clients\NIKKE-150.6.9-Physical\Unity\' +
    'com_proximabeta_NIKKE\saus\en'
)
Assert-NoReparseAncestors (Split-Path -Parent $clientEnglishRoot) `
    'phase3b2_english_saus_ab_client_parent_reparse_invalid'
$activePointerPaths = @(
    (Join-Path $physicalRoot `
        'epinel-minimal-reference-v1\active-run.pointer.json'),
    (Join-Path $physicalRoot `
        'epinel-user-progression-reference-v1\active-run.pointer.json')
)
$sqlitePaths = @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal' |
    ForEach-Object { Join-Path $runtimeRoot $_ })

Assert-True (@($activePointerPaths | Where-Object {
            Test-Path -LiteralPath $_ -PathType Leaf
        }).Count -eq 0) 'phase3b2_english_saus_ab_active_pointer_present'
Assert-True (@($sqlitePaths | Where-Object {
            Test-Path -LiteralPath $_ -PathType Leaf
        }).Count -eq 0) 'phase3b2_english_saus_ab_sqlite_runtime_present'

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
    ) 'phase3b2_english_saus_ab_golden_pin_drift'
}

$headerPath = Join-Path $runtimeRoot (
    'cache\prdenv\150-b059c3f36c\StandaloneWindows64\pck\' +
    'latest-651.txt'
)
$expectedHeaderSha256 =
    '5914cb58fd2146fe761ab531ecb4e321300527186a54b455e59de962ff6c044a'
Assert-True (
    (Test-Path -LiteralPath $headerPath -PathType Leaf) -and
    (Get-Item -LiteralPath $headerPath).Length -eq 139 -and
    (Get-Sha256Hex $headerPath) -ceq $expectedHeaderSha256
) 'phase3b2_english_saus_ab_version_header_drift'
$headerText = [IO.File]::ReadAllText($headerPath, [Text.Encoding]::UTF8)
Assert-True ($headerText.Contains('en:dee9e75,552072')) `
    'phase3b2_english_saus_ab_english_revision_missing'

$bodyLookupKey =
    'prdenv/150-b059c3f36c/StandaloneWindows64/pck/en/dee9e75/' +
    'asset-catalog.cat'
$companionLookupKey = $bodyLookupKey + '.nds'
Assert-True (
    (Get-TextSha256Hex $bodyLookupKey) -ceq
        '3386466649d71013708ed4e6cf7ffdbae9a6cd8a944dfabc03c8c045da071471' -and
    (Get-TextSha256Hex $companionLookupKey) -ceq
        '82cba7b2087ef096e6d43457d7fe82dae867b579ffbd625e044e2ed3f01d6273'
) 'phase3b2_english_saus_ab_lookup_key_digest_invalid'
$englishCachePaths = @(
    (Join-Path (Join-Path $runtimeRoot 'cache') `
        $bodyLookupKey.Replace('/', '\')),
    (Join-Path (Join-Path $runtimeRoot 'cache') `
        $companionLookupKey.Replace('/', '\'))
)
Assert-True (@($englishCachePaths | Where-Object {
            Test-Path -LiteralPath $_ -PathType Leaf
        }).Count -eq 0) 'phase3b2_english_saus_ab_unexpected_english_server_cache'

$genericSausRoot = Join-Path $runtimeRoot (
    'cache\prdenv\150-b059c3f36c\StandaloneWindows64\pck\saus\19e939d'
)
Assert-True (
    (Get-Sha256Hex (Join-Path $genericSausRoot 'asset-catalog.cat')) -ceq
        'a8ad0f199f5db1213658c3238369ad472a98db74bb3a15a274931119ca22d0df' -and
    (Get-Sha256Hex (Join-Path $genericSausRoot 'asset-catalog.cat.nds')) -ceq
        '01de2cc79b8f04297faf262666a7701242a942ba74d48b513c0998ab08b91fa2'
) 'phase3b2_english_saus_ab_generic_saus_pair_drift'

$assetSourcePath = Join-Path $micronDrive `
    'NLL\EpinelPS\EpinelPS\Utils\AssetDownloadUtil.cs'
$programSourcePath = Join-Path $micronDrive `
    'NLL\EpinelPS\EpinelPS\Program.cs'
Assert-True (
    (Test-Path -LiteralPath $assetSourcePath -PathType Leaf) -and
    (Test-Path -LiteralPath $programSourcePath -PathType Leaf)
) 'phase3b2_english_saus_ab_static_source_missing'
$assetSourceText = [IO.File]::ReadAllText($assetSourcePath)
$programSourceText = [IO.File]::ReadAllText($programSourcePath)
Assert-True (
    $assetSourceText.Contains('context.Request.Path.Value ?? ""') -and
    $assetSourceText.Contains('if (!File.Exists(targetFile))') -and
    $assetSourceText.Contains('local_only_asset_cache_miss') -and
    $assetSourceText.Contains('context.Response.StatusCode = 404') -and
    $programSourceText.Contains(
        'app.MapGet("/prdenv/{**all}", AssetDownloadUtil.HandleReq)'
    )
) 'phase3b2_english_saus_ab_static_miss_contract_invalid'

$beforeMembers = @(Get-EnglishCacheMembers $clientEnglishRoot)
$appLogRoot = Join-Path $runtimeRoot 'logs'
$appLogSnapshot = @(
    Get-ChildItem -LiteralPath $appLogRoot -Filter 'app-*.log' -File |
        Sort-Object Name | ForEach-Object {
            [ordered]@{
                leafName = $_.Name
                byteLength = [long]$_.Length
                sha256 = Get-Sha256Hex $_.FullName
                lastWriteTimeUtc = $_.LastWriteTimeUtc.ToString('o')
            }
        }
)

$audit = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-epinel-english-saus-ab-audit/v1'
    auditedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    runtimeCold = $true
    boundaryVerificationCode = $boundaryVerificationCode
    activeRunPointerCount = 0
    sqliteRuntimeMemberCount = 0
    goldenPinCount = $goldenPins.Count
    goldenPinMatchedCount = $goldenPins.Count
    advertisedEnglishRevisionCode = 'dee9e75'
    englishRequestMemberCount = 2
    requestMethodCode = 'GET'
    requestHostCode = 'official_static_asset_host_cloud_nikke_kr'
    queryObserved = $false
    effectiveLookupQueryCode = 'not_applicable_handler_uses_path_only'
    englishServerCacheMemberCount = 0
    staticSourceExpectedMissHttpStatusCode = 404
    staticSourceExpectedMissResponseBodyByteLength = 0
    genericSausPairVerified = $true
    clientEnglishMemberCount = $beforeMembers.Count
    clientEnglishContentByteLength = [long](
        ($beforeMembers | Measure-Object byteLength -Sum).Sum
    )
    clientEnglishMembers = $beforeMembers
    appLogSnapshotCount = $appLogSnapshot.Count
    readyForReversibleQuarantine = $true
}
if ($AuditOnly) {
    [ordered]@{
        Audit = $audit
        mutationPerformed = $false
        nextStepCode = 'rerun_without_audit_only_to_backup_and_quarantine'
    } | ConvertTo-Json -Depth 8
    return
}

$abUid = [Guid]::NewGuid().ToString()
$micronEvidenceRoot = Join-Path $physicalRoot `
    'epinel-english-saus-ab-v1'
$micronAssessmentRoot = Join-Path $micronEvidenceRoot $abUid
$protectedAssessmentRoot = Join-Path $ProtectedEvidenceRoot $abUid
Assert-NoReparseAncestors $micronEvidenceRoot `
    'phase3b2_english_saus_ab_micron_evidence_reparse_invalid'
Assert-NoReparseAncestors $ProtectedEvidenceRoot `
    'phase3b2_english_saus_ab_protected_reparse_boundary_invalid'
Assert-True (
    -not (Test-Path -LiteralPath $micronAssessmentRoot) -and
    -not (Test-Path -LiteralPath $protectedAssessmentRoot)
) 'phase3b2_english_saus_ab_assessment_collision'

$micronBeforeParent = Join-Path $micronAssessmentRoot 'before-copy'
$protectedBeforeParent = Join-Path $protectedAssessmentRoot 'before-copy'
$micronBeforeRoot = Join-Path $micronBeforeParent 'en'
$protectedBeforeRoot = Join-Path $protectedBeforeParent 'en'
$quarantineParent = Join-Path $micronAssessmentRoot 'quarantine'
$quarantineRoot = Join-Path $quarantineParent 'en'
New-Item -ItemType Directory -Path $micronBeforeParent -Force | Out-Null
New-Item -ItemType Directory -Path $protectedBeforeParent -Force | Out-Null
New-Item -ItemType Directory -Path $quarantineParent -Force | Out-Null
Assert-NoReparseAncestors $protectedAssessmentRoot `
    'phase3b2_english_saus_ab_protected_reparse_boundary_invalid'
Assert-NoReparseAncestors $micronAssessmentRoot `
    'phase3b2_english_saus_ab_micron_evidence_reparse_invalid'
Copy-Item -LiteralPath $clientEnglishRoot -Destination $micronBeforeParent `
    -Recurse
Copy-Item -LiteralPath $clientEnglishRoot -Destination $protectedBeforeParent `
    -Recurse
Assert-True (
    (Test-EnglishCacheCopy $micronBeforeRoot $beforeMembers) -and
    (Test-EnglishCacheCopy $protectedBeforeRoot $beforeMembers)
) 'phase3b2_english_saus_ab_backup_verification_failed'

$manifest = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-epinel-english-saus-before-manifest/v1'
    sealedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    assessmentUid = $abUid
    sourceRoleCode = 'disposable_physical_client_saus_english'
    sourceRelativePathCode = 'client_clone_saus_en'
    memberCount = $beforeMembers.Count
    contentByteLength = [long](
        ($beforeMembers | Measure-Object byteLength -Sum).Sum
    )
    members = $beforeMembers
    rawOriginalGameContentPersisted = $false
}
$manifestText = ($manifest | ConvertTo-Json -Depth 8) +
    [Environment]::NewLine
$micronManifestPath = Join-Path $micronAssessmentRoot `
    'before.manifest.json'
$protectedManifestPath = Join-Path $protectedAssessmentRoot `
    'before.manifest.json'
Write-AtomicUtf8NoBom $micronManifestPath $manifestText
Write-AtomicUtf8NoBom $protectedManifestPath $manifestText
$manifestSha256 = Get-Sha256Hex $micronManifestPath
Assert-True ((Get-Sha256Hex $protectedManifestPath) -ceq $manifestSha256) `
    'phase3b2_english_saus_ab_manifest_copy_invalid'

$rollbackPlan = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-epinel-english-saus-ab-rollback-plan/v1'
    assessmentUid = $abUid
    targetRelativePathCode = 'client_clone_saus_en'
    primaryRollbackSourceRelativePath = 'quarantine/en'
    fallbackRollbackSourceRelativePath = 'before-copy/en'
    expectedBeforeManifestSha256 = $manifestSha256
    preserveRecreatedTreeBeforeRestore = $true
    runtimeBinding = $false
    startupPreflightBinding = $false
}
$rollbackText = ($rollbackPlan | ConvertTo-Json -Depth 6) +
    [Environment]::NewLine
$micronRollbackPath = Join-Path $micronAssessmentRoot 'rollback.plan.json'
$protectedRollbackPath = Join-Path $protectedAssessmentRoot `
    'rollback.plan.json'
Write-AtomicUtf8NoBom $micronRollbackPath $rollbackText
Write-AtomicUtf8NoBom $protectedRollbackPath $rollbackText
$rollbackSha256 = Get-Sha256Hex $micronRollbackPath
Assert-True ((Get-Sha256Hex $protectedRollbackPath) -ceq $rollbackSha256) `
    'phase3b2_english_saus_ab_rollback_copy_invalid'

$directoryMoved = $false
$transactionCommitted = $false
try {
    Move-Item -LiteralPath $clientEnglishRoot -Destination $quarantineParent
    $directoryMoved = $true
    Assert-True (
        -not (Test-Path -LiteralPath $clientEnglishRoot) -and
        (Test-EnglishCacheCopy $quarantineRoot $beforeMembers)
    ) 'phase3b2_english_saus_ab_quarantine_postcondition_invalid'

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-epinel-english-saus-ab-quarantine/v1'
        quarantinedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        assessmentUid = $abUid
        beforeManifestSha256 = $manifestSha256
        rollbackPlanSha256 = $rollbackSha256
        advertisedEnglishRevisionCode = 'dee9e75'
        englishRequestMemberCount = 2
        requestMethodCode = 'GET'
        requestHostCode = 'official_static_asset_host_cloud_nikke_kr'
        requestLookupKeySha256 = @(
            Get-TextSha256Hex $bodyLookupKey
            Get-TextSha256Hex $companionLookupKey
        )
        queryObserved = $false
        effectiveLookupQueryCode =
            'not_applicable_handler_uses_path_only'
        staticSourceMissHandlerShapeVerified = $true
        englishServerCacheMemberCount = 0
        staticSourceExpectedMissHttpStatusCode = 404
        staticSourceExpectedMissResponseBodyByteLength = 0
        genericSausPairVerified = $true
        clientEnglishMemberCountBefore = $beforeMembers.Count
        clientEnglishContentByteLengthBefore = 0L
        protectedBackupVerified = $true
        micronBackupVerified = $true
        sameVolumeQuarantineApplied = $true
        clientEnglishRootAbsentAfterQuarantine = $true
        preRunAppLogSnapshot = $appLogSnapshot
        goldenRuntimePinsVerified = $true
        boundaryVerificationCode = $boundaryVerificationCode
        originalInstallModified = $false
        serverCacheModified = $false
        databaseModified = $false
        goldenStartWrapperModified = $false
        goldenInnerStartModified = $false
        goldenCompletionToolsModified = $false
        localLowInspected = $false
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
            'run_samsung_prerun_seal_before_any_micron_execution'
    }
    $receiptText = ($receipt | ConvertTo-Json -Depth 8) +
        [Environment]::NewLine
    $micronReceiptPath = Join-Path $micronAssessmentRoot `
        'quarantine.receipt.json'
    $protectedReceiptPath = Join-Path $protectedAssessmentRoot `
        'quarantine.receipt.json'
    Write-AtomicUtf8NoBom $micronReceiptPath $receiptText
    Write-AtomicUtf8NoBom $protectedReceiptPath $receiptText
    $receiptSha256 = Get-Sha256Hex $micronReceiptPath
    Assert-True ((Get-Sha256Hex $protectedReceiptPath) -ceq $receiptSha256) `
        'phase3b2_english_saus_ab_receipt_copy_invalid'
    $transactionCommitted = $true

    [ordered]@{
        Receipt = $receipt
        MicronReceiptPath = $micronReceiptPath
        MicronReceiptByteLength =
            (Get-Item -LiteralPath $micronReceiptPath).Length
        MicronReceiptSha256 = $receiptSha256
        ProtectedReceiptPath = $protectedReceiptPath
        SamsungPreRunSealCommand =
            "& 'C:\Users\zih44\Documents\Github\Nikke-Local-Lab\scripts\seal-phase3b2-epinel-english-saus-ab-prerun-offline.ps1' -AssessmentUid '$abUid'"
        SamsungEmergencyRestoreOnlyCommand =
            "& 'C:\Users\zih44\Documents\Github\Nikke-Local-Lab\scripts\classify-and-restore-phase3b2-epinel-english-saus-ab-offline.ps1' -AssessmentUid '$abUid' -RestoreOnly"
    } | ConvertTo-Json -Depth 8
}
catch {
    $failure = $_
    if (-not $transactionCommitted -and $directoryMoved -and
        -not (Test-Path -LiteralPath $clientEnglishRoot) -and
        (Test-Path -LiteralPath $quarantineRoot -PathType Container)) {
        Move-Item -LiteralPath $quarantineRoot `
            -Destination (Split-Path -Parent $clientEnglishRoot)
    }
    throw $failure
}
