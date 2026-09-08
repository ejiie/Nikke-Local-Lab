#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ $_ -ne [Guid]::Empty })]
    [Guid]$AssessmentUid,
    [ValidatePattern('^[A-Z]$')]
    [string]$MicronDriveLetter = 'E',
    [string]$ProtectedEvidenceRoot =
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\EpinelEnglishSausAB-v1',
    [switch]$RestoreOnly
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

function Get-BytesSha256Hex {
    param([byte[]]$Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $algorithm.ComputeHash($Bytes)
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

function Assert-SafeDirectoryRoot {
    param([string]$Path, [string]$FailureCode)
    Assert-True (Test-Path -LiteralPath $Path -PathType Container) `
        $FailureCode
    $item = Get-Item -LiteralPath $Path -Force
    Assert-True (
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0
    ) $FailureCode
}

function Test-BeforeTree {
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

function Get-DirectTreeState {
    param([string]$Root)
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return [pscustomobject][ordered]@{
            directoryPresent = $false
            directoryCount = 0
            reparseDirectoryCount = 0
            reparseFileCount = 0
            memberCount = 0
            contentByteLength = 0L
            members = @()
        }
    }
    Assert-SafeDirectoryRoot $Root `
        'phase3b2_english_saus_ab_postrun_root_reparse_point'
    $directories = @(Get-ChildItem -LiteralPath $Root -Directory -Force)
    $reparseDirectories = @($directories | Where-Object {
            ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
        })
    $files = @(Get-ChildItem -LiteralPath $Root -File -Force |
        Sort-Object Name)
    $reparseFiles = @($files | Where-Object {
            ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
        })
    Assert-True ($reparseFiles.Count -eq 0) `
        'phase3b2_english_saus_ab_postrun_file_reparse_point'
    Assert-True ($files.Count -le 16) `
        'phase3b2_english_saus_ab_postrun_member_count_excessive'
    $totalLength = [long](($files | Measure-Object Length -Sum).Sum)
    Assert-True ($totalLength -le 104857600L) `
        'phase3b2_english_saus_ab_postrun_content_length_excessive'
    $members = @(
        foreach ($file in $files) {
            [pscustomobject][ordered]@{
                leafName = $file.Name
                byteLength = [long]$file.Length
                sha256 = Get-Sha256Hex $file.FullName
                creationTimeUtc = $file.CreationTimeUtc.ToString('o')
                lastWriteTimeUtc = $file.LastWriteTimeUtc.ToString('o')
            }
        }
    )
    return [pscustomobject][ordered]@{
        directoryPresent = $true
        directoryCount = $directories.Count
        reparseDirectoryCount = $reparseDirectories.Count
        reparseFileCount = $reparseFiles.Count
        memberCount = $members.Count
        contentByteLength = $totalLength
        members = $members
    }
}

function Get-AppLogDeltaText {
    param([string]$LogRoot, [object[]]$BeforeSnapshot)
    $beforeByName = @{}
    foreach ($entry in $BeforeSnapshot) {
        $beforeByName[[string]$entry.leafName] = $entry
    }
    $afterByName = @{}
    $afterLogs = @(Get-ChildItem -LiteralPath $LogRoot -Filter 'app-*.log' `
        -File | Sort-Object Name)
    foreach ($log in $afterLogs) { $afterByName[$log.Name] = $log }
    foreach ($entry in $BeforeSnapshot) {
        Assert-True ($afterByName.ContainsKey([string]$entry.leafName)) `
            'phase3b2_english_saus_ab_app_log_removed'
    }
    $segments = [Collections.Generic.List[string]]::new()
    foreach ($log in $afterLogs) {
        $beforeLength = 0L
        if ($beforeByName.ContainsKey($log.Name)) {
            $before = $beforeByName[$log.Name]
            $beforeLength = [long]$before.byteLength
            Assert-True ($log.Length -ge $beforeLength) `
                'phase3b2_english_saus_ab_app_log_truncated'
        }
        $bytes = [IO.File]::ReadAllBytes($log.FullName)
        if ($beforeLength -gt 0) {
            $prefix = New-Object byte[] ([int]$beforeLength)
            [Array]::Copy($bytes, 0, $prefix, 0, [int]$beforeLength)
            Assert-True (
                (Get-BytesSha256Hex $prefix) -ceq
                    [string]$beforeByName[$log.Name].sha256
            ) 'phase3b2_english_saus_ab_app_log_prefix_drift'
        }
        $deltaLength = [int]($bytes.Length - $beforeLength)
        if ($deltaLength -gt 0) {
            $segments.Add(
                [Text.Encoding]::UTF8.GetString(
                    $bytes, [int]$beforeLength, $deltaLength
                )
            )
        }
    }
    return ($segments -join [Environment]::NewLine)
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
) 'phase3b2_english_saus_ab_classification_protected_boundary_invalid'
Assert-NoReparseAncestors $ProtectedEvidenceRoot `
    'phase3b2_english_saus_ab_classification_protected_reparse_invalid'
Assert-True ($env:SystemDrive -ceq 'C:') `
    'phase3b2_english_saus_ab_classification_wrong_samsung_boundary'
$micronDrive = $MicronDriveLetter + ':'
Assert-True (
    $micronDrive -cne $env:SystemDrive -and
    (Test-Path -LiteralPath (
        Join-Path $micronDrive 'Windows\explorer.exe'
    ) -PathType Leaf)
) 'phase3b2_english_saus_ab_classification_micron_not_offline'
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
) 'phase3b2_english_saus_ab_classification_volume_identity_invalid'
Assert-True (@(Get-Process -Name @(
        'nikke', 'EpinelPS', 'nikke_launcher',
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
    ) -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_english_saus_ab_classification_runtime_not_cold'

$uid = $AssessmentUid.ToString()
$physicalRoot = Join-Path $micronDrive 'NLL\Evidence\Phase3B2\Physical'
$runtimeRoot = Join-Path $micronDrive `
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
$toolsRoot = Join-Path $micronDrive 'NLL\Tools'
$micronRoot = Join-Path (
    Join-Path $physicalRoot 'epinel-english-saus-ab-v1'
) $uid
$protectedRoot = Join-Path $ProtectedEvidenceRoot $uid
Assert-NoReparseAncestors $micronRoot `
    'phase3b2_english_saus_ab_classification_micron_assessment_reparse_invalid'
Assert-NoReparseAncestors $protectedRoot `
    'phase3b2_english_saus_ab_classification_protected_assessment_reparse_invalid'
$quarantineReceiptPath = Join-Path $micronRoot `
    'quarantine.receipt.json'
$protectedQuarantineReceiptPath = Join-Path $protectedRoot `
    'quarantine.receipt.json'
$beforeManifestPath = Join-Path $micronRoot 'before.manifest.json'
$protectedBeforeManifestPath = Join-Path $protectedRoot `
    'before.manifest.json'
$rollbackPath = Join-Path $micronRoot 'rollback.plan.json'
$protectedRollbackPath = Join-Path $protectedRoot 'rollback.plan.json'
$preRunPath = Join-Path $micronRoot 'pre-run.audit.receipt.json'
$protectedPreRunPath = Join-Path $protectedRoot `
    'pre-run.audit.receipt.json'
$serverCachePreRunPath = Join-Path $micronRoot `
    'server-cache.pre-run.receipt.json'
$protectedServerCachePreRunPath = Join-Path $protectedRoot `
    'server-cache.pre-run.receipt.json'
$classificationPath = Join-Path $micronRoot `
    'classification-and-restore.receipt.json'
$protectedClassificationPath = Join-Path $protectedRoot `
    'classification-and-restore.receipt.json'
$restoreOnlyPath = Join-Path $micronRoot 'restore-only.receipt.json'
$protectedRestoreOnlyPath = Join-Path $protectedRoot `
    'restore-only.receipt.json'
$requiredPaths = @(
    $quarantineReceiptPath, $protectedQuarantineReceiptPath,
    $beforeManifestPath, $protectedBeforeManifestPath,
    $rollbackPath, $protectedRollbackPath
)
if (-not $RestoreOnly) {
    $requiredPaths += @(
        $preRunPath, $protectedPreRunPath,
        $serverCachePreRunPath, $protectedServerCachePreRunPath
    )
}
Assert-True (@($requiredPaths | Where-Object {
            -not (Test-Path -LiteralPath $_ -PathType Leaf)
        }).Count -eq 0) 'phase3b2_english_saus_ab_classification_input_missing'
$existingClassificationPaths = @(
    @($classificationPath, $protectedClassificationPath) | Where-Object {
        Test-Path -LiteralPath $_ -PathType Leaf
    }
)
if (-not $RestoreOnly) {
    Assert-True (
        -not (Test-Path -LiteralPath $restoreOnlyPath) -and
        -not (Test-Path -LiteralPath $protectedRestoreOnlyPath)
    ) 'phase3b2_english_saus_ab_restore_only_already_completed'
}
$baseDualSealMatched =
    (Get-Sha256Hex $quarantineReceiptPath) -ceq
        (Get-Sha256Hex $protectedQuarantineReceiptPath) -and
    (Get-Sha256Hex $beforeManifestPath) -ceq
        (Get-Sha256Hex $protectedBeforeManifestPath) -and
    (Get-Sha256Hex $rollbackPath) -ceq
        (Get-Sha256Hex $protectedRollbackPath)
Assert-True $baseDualSealMatched `
    'phase3b2_english_saus_ab_classification_dual_seal_drift'
$preRunPathsPresent = @(
    @($preRunPath, $protectedPreRunPath) | Where-Object {
        Test-Path -LiteralPath $_ -PathType Leaf
    }
)
$preRunAvailable =
    $preRunPathsPresent.Count -eq 2 -and
    (Get-Sha256Hex $preRunPath) -ceq
        (Get-Sha256Hex $protectedPreRunPath)
if (-not $RestoreOnly) {
    Assert-True $preRunAvailable `
        'phase3b2_english_saus_ab_classification_dual_seal_drift'
}
$serverCachePreRunPathsPresent = @(
    @($serverCachePreRunPath, $protectedServerCachePreRunPath) |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
)
$serverCachePreRunAvailable =
    $serverCachePreRunPathsPresent.Count -eq 2 -and
    (Get-Sha256Hex $serverCachePreRunPath) -ceq
        (Get-Sha256Hex $protectedServerCachePreRunPath)
if (-not $RestoreOnly) {
    Assert-True $serverCachePreRunAvailable `
        'phase3b2_english_saus_ab_classification_cache_identity_seal_drift'
}

$quarantineReceipt = Get-Content -LiteralPath $quarantineReceiptPath `
    -Raw -Encoding UTF8 | ConvertFrom-Json
$beforeManifest = Get-Content -LiteralPath $beforeManifestPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
$rollbackPlan = Get-Content -LiteralPath $rollbackPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
$preRun = if ($preRunAvailable) {
    Get-Content -LiteralPath $preRunPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
}
else {
    $null
}
$serverCachePreRun = if ($serverCachePreRunAvailable) {
    Get-Content -LiteralPath $serverCachePreRunPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
}
else {
    $null
}
Assert-True (
    $quarantineReceipt.contractId -ceq
        'nll/phase3b2-epinel-english-saus-ab-quarantine/v1' -and
    $quarantineReceipt.assessmentUid -ceq $uid -and
    $quarantineReceipt.beforeManifestSha256 -ceq
        (Get-Sha256Hex $beforeManifestPath) -and
    $quarantineReceipt.rollbackPlanSha256 -ceq
        (Get-Sha256Hex $rollbackPath) -and
    $quarantineReceipt.singleAbRunAuthorized -and
    -not $quarantineReceipt.validationRunConsumed -and
    $beforeManifest.contractId -ceq
        'nll/phase3b2-epinel-english-saus-before-manifest/v1' -and
    $beforeManifest.assessmentUid -ceq $uid -and
    $beforeManifest.memberCount -eq 2 -and
    $rollbackPlan.contractId -ceq
        'nll/phase3b2-epinel-english-saus-ab-rollback-plan/v1' -and
    $rollbackPlan.assessmentUid -ceq $uid -and
    $rollbackPlan.expectedBeforeManifestSha256 -ceq
        (Get-Sha256Hex $beforeManifestPath) -and
    -not $rollbackPlan.runtimeBinding -and
    -not $rollbackPlan.startupPreflightBinding
) 'phase3b2_english_saus_ab_classification_contract_invalid'
if ($preRunAvailable) {
    Assert-True (
    $preRun.contractId -ceq
        'nll/phase3b2-epinel-english-saus-ab-prerun-audit/v1' -and
    $preRun.assessmentUid -ceq $uid -and
    $preRun.quarantineReceiptSha256 -ceq
        (Get-Sha256Hex $quarantineReceiptPath) -and
    $preRun.beforeManifestSha256 -ceq
        (Get-Sha256Hex $beforeManifestPath) -and
    $preRun.activeEnglishRootAbsent -and
    $preRun.serverCacheFileCount -eq 40111 -and
    [long]$preRun.serverCacheContentByteLength -eq 39030643658L
    ) 'phase3b2_english_saus_ab_classification_prerun_contract_invalid'
}
if ($serverCachePreRunAvailable) {
    Assert-True (
        $serverCachePreRun.contractId -ceq
            'nll/phase3b2-epinel-english-saus-ab-server-cache-prerun-identity/v1' -and
        $serverCachePreRun.assessmentUid -ceq $uid -and
        $serverCachePreRun.preRunAuditReceiptSha256 -ceq
            (Get-Sha256Hex $preRunPath) -and
        $serverCachePreRun.quarantineReceiptSha256 -ceq
            (Get-Sha256Hex $quarantineReceiptPath) -and
        $serverCachePreRun.observedMemberCount -eq 40111 -and
        [long]$serverCachePreRun.observedContentByteLength -eq
            39030643658L -and
        $serverCachePreRun.activeCacheCanonicalSha256 -ceq
            '159b152960c35e8898bc1ea06dd17239b200f46e65095fa79b1aeead19dd8c56' -and
        $serverCachePreRun.memberDigestVerificationPerformed -and
        $serverCachePreRun.exactServerCacheIdentityVerified -and
        -not $serverCachePreRun.serverCacheModified -and
        -not $serverCachePreRun.networkUsed
    ) 'phase3b2_english_saus_ab_classification_cache_identity_contract_invalid'
}

if ($existingClassificationPaths.Count -gt 0) {
    $existingClassificationText = Get-Content -LiteralPath `
        $existingClassificationPaths[0] -Raw -Encoding UTF8
    $existingClassification = $existingClassificationText |
        ConvertFrom-Json
    $existingPostRunManifestPath = Join-Path $micronRoot `
        'post-run.manifest.json'
    $existingProtectedPostRunManifestPath = Join-Path $protectedRoot `
        'post-run.manifest.json'
    Assert-True (
        $existingClassification.contractId -ceq
            'nll/phase3b2-epinel-english-saus-ab-classification/v2' -and
        $existingClassification.assessmentUid -ceq $uid -and
        $existingClassification.quarantineReceiptSha256 -ceq
            (Get-Sha256Hex $quarantineReceiptPath) -and
        $existingClassification.preRunAuditReceiptSha256 -ceq
            (Get-Sha256Hex $preRunPath) -and
        $existingClassification.serverCachePreRunReceiptSha256 -ceq
            (Get-Sha256Hex $serverCachePreRunPath) -and
        $existingClassification.beforeManifestSha256 -ceq
            (Get-Sha256Hex $beforeManifestPath) -and
        $existingClassification.rollbackPlanSha256 -ceq
            (Get-Sha256Hex $rollbackPath) -and
        $existingClassification.originalEnglishTreeRestored -and
        $existingClassification.singleAbRunConsumed -and
        -not $existingClassification.retryAuthorized -and
        (Test-Path -LiteralPath $existingPostRunManifestPath `
            -PathType Leaf) -and
        (Test-Path -LiteralPath $existingProtectedPostRunManifestPath `
            -PathType Leaf) -and
        (Get-Sha256Hex $existingPostRunManifestPath) -ceq
            [string]$existingClassification.postRunManifestSha256 -and
        (Get-Sha256Hex $existingProtectedPostRunManifestPath) -ceq
            [string]$existingClassification.postRunManifestSha256
    ) 'phase3b2_english_saus_ab_existing_classification_invalid'
    if ($existingClassificationPaths.Count -eq 2) {
        Assert-True (
            (Get-Sha256Hex $classificationPath) -ceq
                (Get-Sha256Hex $protectedClassificationPath)
        ) 'phase3b2_english_saus_ab_existing_classification_drift'
    }
    elseif (Test-Path -LiteralPath $classificationPath -PathType Leaf) {
        Write-AtomicUtf8NoBom $protectedClassificationPath `
            $existingClassificationText
    }
    else {
        Write-AtomicUtf8NoBom $classificationPath `
            $existingClassificationText
    }
    $existingClassificationSha256 = Get-Sha256Hex $classificationPath
    Assert-True (
        (Get-Sha256Hex $protectedClassificationPath) -ceq
            $existingClassificationSha256
    ) 'phase3b2_english_saus_ab_existing_classification_copy_invalid'
    [ordered]@{
        Receipt = $existingClassification
        MicronReceiptPath = $classificationPath
        MicronReceiptByteLength =
            (Get-Item -LiteralPath $classificationPath).Length
        MicronReceiptSha256 = $existingClassificationSha256
        ProtectedReceiptPath = $protectedClassificationPath
        publicationResumeCode =
            'existing_valid_receipt_pair_verified_or_repaired'
    } | ConvertTo-Json -Depth 8
    return
}

$activePointerPaths = @(
    (Join-Path $physicalRoot `
        'epinel-minimal-reference-v1\active-run.pointer.json'),
    (Join-Path $physicalRoot `
        'epinel-user-progression-reference-v1\active-run.pointer.json')
)
$sqlitePaths = @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal' |
    ForEach-Object { Join-Path $runtimeRoot $_ })
$activePointerCountObserved = @($activePointerPaths | Where-Object {
        Test-Path -LiteralPath $_ -PathType Leaf
    }).Count
$sqliteRuntimeMemberCountObserved = @($sqlitePaths | Where-Object {
        Test-Path -LiteralPath $_ -PathType Leaf
    }).Count
if (-not $RestoreOnly) {
    Assert-True (
        $activePointerCountObserved -eq 0 -and
        $sqliteRuntimeMemberCountObserved -eq 0
    ) 'phase3b2_english_saus_ab_classification_runtime_residue_present'
}

# Refuse an accidental pre-run invocation without parsing mutable run
# contents. Filesystem timestamps are sufficient for this gate; the sealed
# receipts themselves are validated only after the client tree is restored.
$sealedAt = if ($preRunAvailable) {
    $preRunSealedAt = [DateTimeOffset]::Parse(
        [string]$preRun.sealedAtUtc
    )
    if ($serverCachePreRunAvailable) {
        $cacheSealedAt = [DateTimeOffset]::Parse(
            [string]$serverCachePreRun.sealedAtUtc
        )
        if ($cacheSealedAt -gt $preRunSealedAt) {
            $cacheSealedAt
        }
        else {
            $preRunSealedAt
        }
    }
    else {
        $preRunSealedAt
    }
}
else {
    # RestoreOnly is an emergency rollback lane.  It remains usable even if
    # the dual pre-run receipt publication was interrupted or never started.
    [DateTimeOffset]::Parse(
        [string]$quarantineReceipt.quarantinedAtUtc
    )
}
$runBase = Join-Path $physicalRoot 'epinel-minimal-reference-v1'
$postSealRunDirectories = @(
    foreach ($directory in @(
            Get-ChildItem -LiteralPath $runBase -Directory `
                -ErrorAction SilentlyContinue
        )) {
        $startPath = Join-Path $directory.FullName 'run-start.receipt.json'
        if (-not (Test-Path -LiteralPath $startPath -PathType Leaf)) {
            continue
        }
        $startItem = Get-Item -LiteralPath $startPath
        if ($startItem.LastWriteTimeUtc -le $sealedAt.UtcDateTime) {
            continue
        }
        [pscustomobject]@{
            directory = $directory
            startPath = $startPath
            completionPath = Join-Path $directory.FullName `
                'completion.receipt.json'
        }
    }
)
$postSealCompletionCount = @($postSealRunDirectories | Where-Object {
        Test-Path -LiteralPath $_.completionPath -PathType Leaf
    }).Count
if (-not $RestoreOnly) {
    Assert-True ($postSealRunDirectories.Count -eq 1 -and
        $postSealCompletionCount -eq 1) `
        'phase3b2_english_saus_ab_completed_single_run_not_present'
}

# Restore the exact pre-run client tree before inspecting post-run contents.
# The post-run root is preserved by a same-volume rename. A validated
# checkpoint makes every failure after restoration safely resumable.
$clientEnglishRoot = Join-Path $micronDrive (
    'NLL\Clients\NIKKE-150.6.9-Physical\Unity\' +
    'com_proximabeta_NIKKE\saus\en'
)
$clientEnglishParent = Split-Path -Parent $clientEnglishRoot
Assert-NoReparseAncestors $clientEnglishParent `
    'phase3b2_english_saus_ab_classification_client_parent_reparse_invalid'
$primaryRestoreRoot = Join-Path $micronRoot 'quarantine\en'
$micronFallbackRoot = Join-Path $micronRoot 'before-copy\en'
$protectedFallbackRoot = Join-Path $protectedRoot 'before-copy\en'
$beforeMembers = @($beforeManifest.members)
$postRunQuarantineParent = Join-Path $micronRoot `
    'post-run-quarantine'
$postRunQuarantineRoot = Join-Path $postRunQuarantineParent 'en'
$restoreTemporary = Join-Path $clientEnglishParent (
    '.english-saus-restore-' + $uid
)
$checkpointPath = Join-Path $micronRoot 'restore.checkpoint.json'
$protectedCheckpointPath = Join-Path $protectedRoot `
    'restore.checkpoint.json'
$beforeManifestSha256 = Get-Sha256Hex $beforeManifestPath
$postRunMoved = $false
$beforeRestored = $false
$restoreSourceCode = ''
$restoreCheckpoint = $null
$checkpointText = ''
$checkpointSha256 = ''

$existingCheckpointPaths = @(
    @($checkpointPath, $protectedCheckpointPath) | Where-Object {
        Test-Path -LiteralPath $_ -PathType Leaf
    }
)
if ($existingCheckpointPaths.Count -gt 0) {
    if ($existingCheckpointPaths.Count -eq 2) {
        Assert-True (
            (Get-Sha256Hex $existingCheckpointPaths[0]) -ceq
                (Get-Sha256Hex $existingCheckpointPaths[1])
        ) 'phase3b2_english_saus_ab_restore_checkpoint_drift'
    }
    $checkpointText = Get-Content -LiteralPath $existingCheckpointPaths[0] `
        -Raw -Encoding UTF8
    $restoreCheckpoint = $checkpointText | ConvertFrom-Json
    Assert-True (
        $restoreCheckpoint.contractId -ceq
            'nll/phase3b2-epinel-english-saus-ab-restore-checkpoint/v1' -and
        $restoreCheckpoint.assessmentUid -ceq $uid -and
        $restoreCheckpoint.beforeManifestSha256 -ceq
            $beforeManifestSha256 -and
        $restoreCheckpoint.originalEnglishTreeRestored -and
        -not $restoreCheckpoint.localLowMutationPerformedByThisTool -and
        -not $restoreCheckpoint.databaseModified -and
        -not $restoreCheckpoint.serverCacheModified -and
        -not $restoreCheckpoint.goldenToolsModified
    ) 'phase3b2_english_saus_ab_restore_checkpoint_invalid'
    Assert-True (Test-BeforeTree $clientEnglishRoot $beforeMembers) `
        'phase3b2_english_saus_ab_restored_tree_drift'
    $postRunMoved = [bool]$restoreCheckpoint.postRunTreeQuarantined
    Assert-True (
        $postRunMoved -eq
            (Test-Path -LiteralPath $postRunQuarantineRoot `
                -PathType Container)
    ) 'phase3b2_english_saus_ab_restore_checkpoint_postrun_drift'
    $restoreSourceCode = [string]$restoreCheckpoint.restoreSourceCode
    $beforeRestored = $true
    Write-AtomicUtf8NoBom $checkpointPath $checkpointText
    Write-AtomicUtf8NoBom $protectedCheckpointPath $checkpointText
}
else {
    $activeTreeMatchesBefore =
        Test-BeforeTree $clientEnglishRoot $beforeMembers
    $preservedPostRunRootPresent =
        Test-Path -LiteralPath $postRunQuarantineRoot -PathType Container
    $primaryRestoreTreeStillAvailable =
        Test-BeforeTree $primaryRestoreRoot $beforeMembers
    $resumeAfterPostRunMove =
        -not (Test-Path -LiteralPath $clientEnglishRoot) -and
        $preservedPostRunRootPresent
    $activeTreeAlreadyRestored =
        $activeTreeMatchesBefore -and
        (-not $primaryRestoreTreeStillAvailable -or
            $preservedPostRunRootPresent)

    if ($activeTreeAlreadyRestored) {
        $beforeRestored = $true
        $postRunMoved = $preservedPostRunRootPresent
        $restoreSourceCode = if ($postRunMoved) {
            'interrupted_post_restore_checkpoint_recovered'
        }
        else {
            'externally_restored_exact_before_tree'
        }
    }
    else {
        if ($resumeAfterPostRunMove) {
            $postRunMoved = $true
        }
        else {
            Assert-True (-not $preservedPostRunRootPresent) `
                'phase3b2_english_saus_ab_postrun_quarantine_collision'
        }
        Assert-True (-not (Test-Path -LiteralPath $restoreTemporary)) `
            'phase3b2_english_saus_ab_restore_temporary_collision'

        $restoreSource = ''
        $restoreByMove = $false
        if (Test-BeforeTree $primaryRestoreRoot $beforeMembers) {
            $restoreSource = $primaryRestoreRoot
            $restoreSourceCode = 'same_volume_primary_quarantine'
            $restoreByMove = $true
        }
        elseif (Test-BeforeTree $micronFallbackRoot $beforeMembers) {
            $restoreSource = $micronFallbackRoot
            $restoreSourceCode = 'same_volume_verified_backup_copy'
        }
        elseif (Test-BeforeTree $protectedFallbackRoot $beforeMembers) {
            $restoreSource = $protectedFallbackRoot
            $restoreSourceCode = 'protected_verified_backup_copy'
        }
        else {
            throw 'phase3b2_english_saus_ab_no_valid_restore_source'
        }

        try {
            if (-not $resumeAfterPostRunMove -and
                (Test-Path -LiteralPath $clientEnglishRoot)) {
                Assert-SafeDirectoryRoot $clientEnglishRoot `
                    'phase3b2_english_saus_ab_postrun_root_invalid'
                New-Item -ItemType Directory `
                    -Path $postRunQuarantineParent -Force | Out-Null
                Move-Item -LiteralPath $clientEnglishRoot `
                    -Destination $postRunQuarantineParent
                $postRunMoved = $true
            }
            if ($restoreByMove) {
                Move-Item -LiteralPath $restoreSource `
                    -Destination $clientEnglishParent
            }
            else {
                Copy-Item -LiteralPath $restoreSource `
                    -Destination $restoreTemporary -Recurse
                Assert-True (
                    Test-BeforeTree $restoreTemporary $beforeMembers
                ) 'phase3b2_english_saus_ab_fallback_copy_invalid'
                Move-Item -LiteralPath $restoreTemporary `
                    -Destination $clientEnglishRoot
            }
            $beforeRestored =
                Test-BeforeTree $clientEnglishRoot $beforeMembers
            Assert-True $beforeRestored `
                'phase3b2_english_saus_ab_before_tree_restore_invalid'
        }
        catch {
            $restoreFailure = $_
            if (Test-Path -LiteralPath $restoreTemporary `
                -PathType Container) {
                $resolvedTemporary =
                    [IO.Path]::GetFullPath($restoreTemporary)
                $resolvedParent =
                    [IO.Path]::GetFullPath($clientEnglishParent)
                if ($resolvedTemporary.StartsWith(
                        $resolvedParent +
                            [IO.Path]::DirectorySeparatorChar,
                        [StringComparison]::OrdinalIgnoreCase
                    )) {
                    Remove-Item -LiteralPath $restoreTemporary `
                        -Recurse -Force
                }
            }
            if (-not (Test-Path -LiteralPath $clientEnglishRoot) -and
                $postRunMoved -and
                (Test-Path -LiteralPath $postRunQuarantineRoot `
                    -PathType Container)) {
                Move-Item -LiteralPath $postRunQuarantineRoot `
                    -Destination $clientEnglishParent
            }
            throw $restoreFailure
        }
    }

    $restoreCheckpoint = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-english-saus-ab-restore-checkpoint/v1'
        restoredAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        assessmentUid = $uid
        beforeManifestSha256 = $beforeManifestSha256
        restoreSourceCode = $restoreSourceCode
        postRunDirectoryWasPresent = $postRunMoved
        postRunTreeQuarantined = $postRunMoved
        originalEnglishTreeRestored = $true
        localLowMutationPerformedByThisTool = $false
        databaseModified = $false
        serverCacheModified = $false
        goldenToolsModified = $false
    }
    $checkpointText = ($restoreCheckpoint | ConvertTo-Json -Depth 6) +
        [Environment]::NewLine
    Write-AtomicUtf8NoBom $checkpointPath $checkpointText
    Write-AtomicUtf8NoBom $protectedCheckpointPath $checkpointText
}

$checkpointSha256 = Get-Sha256Hex $checkpointPath
Assert-True (
    (Get-Sha256Hex $protectedCheckpointPath) -ceq $checkpointSha256 -and
    (Test-BeforeTree $clientEnglishRoot $beforeMembers)
) 'phase3b2_english_saus_ab_restore_checkpoint_copy_invalid'

if ($RestoreOnly) {
    $existingRestoreOnlyPaths = @(
        @($restoreOnlyPath, $protectedRestoreOnlyPath) | Where-Object {
            Test-Path -LiteralPath $_ -PathType Leaf
        }
    )
    if ($existingRestoreOnlyPaths.Count -gt 0) {
        if ($existingRestoreOnlyPaths.Count -eq 2) {
            Assert-True (
                (Get-Sha256Hex $existingRestoreOnlyPaths[0]) -ceq
                    (Get-Sha256Hex $existingRestoreOnlyPaths[1])
            ) 'phase3b2_english_saus_ab_restore_only_receipt_drift'
        }
        $restoreOnlyText = Get-Content `
            -LiteralPath $existingRestoreOnlyPaths[0] -Raw -Encoding UTF8
        $restoreOnlyReceipt = $restoreOnlyText | ConvertFrom-Json
        Assert-True (
            $restoreOnlyReceipt.contractId -ceq
                'nll/phase3b2-epinel-english-saus-ab-restore-only/v1' -and
            $restoreOnlyReceipt.assessmentUid -ceq $uid -and
            $restoreOnlyReceipt.beforeManifestSha256 -ceq
                $beforeManifestSha256 -and
            $restoreOnlyReceipt.restoreCheckpointSha256 -ceq
                $checkpointSha256 -and
            $restoreOnlyReceipt.originalEnglishTreeRestored -and
            -not $restoreOnlyReceipt.classificationPerformed
        ) 'phase3b2_english_saus_ab_restore_only_receipt_invalid'
        Write-AtomicUtf8NoBom $restoreOnlyPath $restoreOnlyText
        Write-AtomicUtf8NoBom $protectedRestoreOnlyPath $restoreOnlyText
        $restoreOnlySha256 = Get-Sha256Hex $restoreOnlyPath
        Assert-True (
            (Get-Sha256Hex $protectedRestoreOnlyPath) -ceq
                $restoreOnlySha256
        ) 'phase3b2_english_saus_ab_restore_only_receipt_copy_invalid'
        [ordered]@{
            Receipt = $restoreOnlyReceipt
            MicronReceiptPath = $restoreOnlyPath
            MicronReceiptByteLength =
                (Get-Item -LiteralPath $restoreOnlyPath).Length
            MicronReceiptSha256 = $restoreOnlySha256
            ProtectedReceiptPath = $protectedRestoreOnlyPath
        } | ConvertTo-Json -Depth 8
        return
    }

    $restoreOnlyReceipt = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-english-saus-ab-restore-only/v1'
        restoredAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        assessmentUid = $uid
        quarantineReceiptSha256 = Get-Sha256Hex $quarantineReceiptPath
        preRunAuditReceiptSha256 = if ($preRunAvailable) {
            Get-Sha256Hex $preRunPath
        }
        else {
            $null
        }
        preRunAuditStatusCode = if ($preRunAvailable) {
            'dual_seal_verified'
        }
        elseif ($preRunPathsPresent.Count -eq 1) {
            'partial_seal_not_required_for_restore'
        }
        else {
            'not_present_not_required_for_restore'
        }
        beforeManifestSha256 = $beforeManifestSha256
        rollbackPlanSha256 = Get-Sha256Hex $rollbackPath
        restoreCheckpointSha256 = $checkpointSha256
        restoreSourceCode = $restoreSourceCode
        postSealRunStartReceiptCount = $postSealRunDirectories.Count
        postSealCompletionReceiptCount = $postSealCompletionCount
        activeRunPointerCountObserved = $activePointerCountObserved
        sqliteRuntimeMemberCountObserved =
            $sqliteRuntimeMemberCountObserved
        postRunTreePreserved = $postRunMoved
        originalEnglishTreeRestored = $true
        classificationPerformed = $false
        retryAuthorized = $false
        postRunTreeContentInspected = $false
        localLowInspected = $false
        localLowMutationPerformedByThisTool = $false
        existingOperatorCacheInspected = $false
        existingOperatorCacheModified = $false
        databaseMutationPerformedByThisTool = $false
        serverCacheMutationPerformedByThisTool = $false
        goldenToolsMutationPerformedByThisTool = $false
        hostsMutationPerformedByThisTool = $false
        firewallMutationPerformedByThisTool = $false
        officialOutboundAssessmentCode = 'unresolved_not_classified'
        serverExecutionAssessmentCode = 'unresolved_not_classified'
        clientExecutionAssessmentCode = 'unresolved_not_classified'
        nextStepCode = 'stop_no_retry_return_to_samsung_manual_review'
    }
    $restoreOnlyText = ($restoreOnlyReceipt | ConvertTo-Json -Depth 8) +
        [Environment]::NewLine
    $micronRestoreOnlyPending = $restoreOnlyPath + '.pending'
    $protectedRestoreOnlyPending = $protectedRestoreOnlyPath + '.pending'
    try {
        Write-AtomicUtf8NoBom $micronRestoreOnlyPending $restoreOnlyText
        Write-AtomicUtf8NoBom $protectedRestoreOnlyPending $restoreOnlyText
        $restoreOnlySha256 = Get-Sha256Hex $micronRestoreOnlyPending
        Assert-True (
            (Get-Sha256Hex $protectedRestoreOnlyPending) -ceq
                $restoreOnlySha256
        ) 'phase3b2_english_saus_ab_restore_only_pending_drift'
        Move-Item -LiteralPath $protectedRestoreOnlyPending `
            -Destination $protectedRestoreOnlyPath
        Move-Item -LiteralPath $micronRestoreOnlyPending `
            -Destination $restoreOnlyPath
    }
    catch {
        $restoreOnlyPublishFailure = $_
        foreach ($pendingPath in @(
                $micronRestoreOnlyPending, $protectedRestoreOnlyPending
            )) {
            if (Test-Path -LiteralPath $pendingPath -PathType Leaf) {
                Remove-Item -LiteralPath $pendingPath -Force
            }
        }
        throw $restoreOnlyPublishFailure
    }
    Assert-True (
        (Get-Sha256Hex $restoreOnlyPath) -ceq $restoreOnlySha256 -and
        (Get-Sha256Hex $protectedRestoreOnlyPath) -ceq
            $restoreOnlySha256
    ) 'phase3b2_english_saus_ab_restore_only_publish_invalid'
    [ordered]@{
        Receipt = $restoreOnlyReceipt
        MicronReceiptPath = $restoreOnlyPath
        MicronReceiptByteLength =
            (Get-Item -LiteralPath $restoreOnlyPath).Length
        MicronReceiptSha256 = $restoreOnlySha256
        ProtectedReceiptPath = $protectedRestoreOnlyPath
    } | ConvertTo-Json -Depth 8
    return
}

$postRunState = Get-DirectTreeState $postRunQuarantineRoot

# Only now classify the single completed run. A failure below leaves the
# original pre-run client tree restored and the post-run tree preserved.
$runCandidates = @(
    foreach ($directory in @(Get-ChildItem -LiteralPath $runBase -Directory)) {
        $startPath = Join-Path $directory.FullName 'run-start.receipt.json'
        if (-not (Test-Path -LiteralPath $startPath -PathType Leaf)) {
            continue
        }
        $start = Get-Content -LiteralPath $startPath -Raw -Encoding UTF8 |
            ConvertFrom-Json
        $startedAt = [DateTimeOffset]::Parse([string]$start.startedAtUtc)
        if ($startedAt -le $sealedAt) { continue }
        [pscustomobject]@{
            directory = $directory
            startPath = $startPath
            start = $start
            startedAt = $startedAt
            completionPath = Join-Path $directory.FullName `
                'completion.receipt.json'
        }
    }
)
Assert-True ($runCandidates.Count -eq 1) `
    'phase3b2_english_saus_ab_single_run_contract_violated'
$run = $runCandidates[0]
Assert-True (Test-Path -LiteralPath $run.completionPath -PathType Leaf) `
    'phase3b2_english_saus_ab_completion_missing'
$completion = Get-Content -LiteralPath $run.completionPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
$completedAt = [DateTimeOffset]::Parse([string]$completion.completedAtUtc)
Assert-True (
    $run.start.contractId -ceq
        'nll/phase3b2-epinel-minimal-reference-start/v1' -and
    $completion.contractId -ceq
        'nll/phase3b2-epinel-minimal-reference-completion/v1' -and
    $completion.assessmentUid -ceq [string]$run.start.assessmentUid -and
    $completion.runStartReceiptSha256 -ceq
        (Get-Sha256Hex $run.startPath) -and
    $completion.runtimeColdAfterCompletion -and
    $completedAt -gt $run.startedAt
) 'phase3b2_english_saus_ab_run_receipt_invalid'
$runArguments = @($run.start.serverArguments)
$runLocalOnlyContractMatched =
    $runArguments.Count -eq 2 -and
    @(@('--headless', '--local-only') | Where-Object {
            $_ -cnotin $runArguments
        }).Count -eq 0 -and
    [int]$run.start.successfulNonLoopbackConnectionCount -eq 0 -and
    $run.start.globalMatchLoopbackMappingApplied -and
    $run.start.bootstrapOutboundBlockApplied -and
    $run.start.selectedManagerRuntimeBindingApplied -and
    -not $run.start.officialLauncherExecutionStarted -and
    -not $run.start.officialOutboundFallbackUsed -and
    -not $run.start.antiCheatSubstitutionApplied

$appLogDelta = Get-AppLogDeltaText (Join-Path $runtimeRoot 'logs') `
    @($preRun.appLogSnapshot)
$assetRequestCount = [regex]::Matches(
    $appLogDelta, 'local_only_asset_cache_request'
).Count
$assetMissCount = [regex]::Matches(
    $appLogDelta, 'local_only_asset_cache_miss'
).Count
$assetEventBuckets = @{}
foreach ($line in @($appLogDelta -split "`r?`n")) {
    $match = [regex]::Match(
        $line,
        '^(?<second>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}),\d{3} .* - (?<event>local_only_asset_cache_(?:request|miss))$'
    )
    if (-not $match.Success) { continue }
    $second = $match.Groups['second'].Value
    if (-not $assetEventBuckets.ContainsKey($second)) {
        $assetEventBuckets[$second] = [ordered]@{
            requestCount = 0
            missCount = 0
        }
    }
    if ($match.Groups['event'].Value -ceq
        'local_only_asset_cache_request') {
        $assetEventBuckets[$second].requestCount++
    }
    else {
        $assetEventBuckets[$second].missCount++
    }
}

$playerLogPath = Join-Path $micronDrive (
    'Users\nlloperator\AppData\LocalLow\com.proximabeta\NIKKE\Player.log'
)
Assert-True (Test-Path -LiteralPath $playerLogPath -PathType Leaf) `
    'phase3b2_english_saus_ab_player_log_missing'
$playerLogItem = Get-Item -LiteralPath $playerLogPath
$playerLogSha256 = Get-Sha256Hex $playerLogPath
$playerLogText = [IO.File]::ReadAllText($playerLogPath)
$playerLogMatchedCompletionReceipt =
    $completion.playerLogPresent -and
    [long]$completion.playerLogByteLength -eq [long]$playerLogItem.Length -and
    [string]$completion.playerLogSha256 -ceq $playerLogSha256
$engineInitializationCount = [regex]::Matches(
    $playerLogText, 'Initialize engine version:'
).Count
$playerLogSingleRunBoundaryVerified =
    $playerLogMatchedCompletionReceipt -and
    $playerLogSha256 -cne [string]$preRun.playerLogSnapshot.sha256 -and
    $playerLogItem.LastWriteTimeUtc -gt $sealedAt.UtcDateTime -and
    $playerLogItem.LastWriteTimeUtc -le $completedAt.UtcDateTime -and
    $engineInitializationCount -eq 1
$malformedCount = -1
$catalogNotInitializedCount = -1
$zeroCatalogReferenceCount = -1
$catalogUpdateEntryCount = -1
if ($playerLogSingleRunBoundaryVerified) {
    $malformedCount = [regex]::Matches(
        $playerLogText, 'database disk image is malformed'
    ).Count
    $catalogNotInitializedCount = [regex]::Matches(
        $playerLogText, 'AssetCatalogNotInitializedException'
    ).Count
    $zeroCatalogReferenceCount = [regex]::Matches(
        $playerLogText, 'asset-catalog-0\.cat'
    ).Count
    $catalogUpdateEntryCount = [regex]::Matches(
        $playerLogText, 'CatalogUpdateEntry'
    ).Count
}

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
$matchedGoldenPinCount = 0
$matchedGoldenRoles = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
foreach ($pin in $goldenPins) {
    if ((Test-Path -LiteralPath $pin.path -PathType Leaf) -and
        (Get-Sha256Hex $pin.path) -ceq [string]$pin.sha256) {
        $matchedGoldenPinCount++
        [void]$matchedGoldenRoles.Add([string]$pin.roleCode)
    }
}
$goldenPinsMatched = $matchedGoldenPinCount -eq $goldenPins.Count
$goldenDatabaseMatched = $matchedGoldenRoles.Contains('golden_database')
$goldenToolRoles = @(
    'golden_start_wrapper', 'golden_inner_start',
    'golden_completion_wrapper', 'golden_inner_completion'
)
$goldenToolsMatched = @($goldenToolRoles | Where-Object {
        -not $matchedGoldenRoles.Contains($_)
    }).Count -eq 0
$goldenServerBinaryMatched =
    $matchedGoldenRoles.Contains('golden_server_binary')

$cacheInspectionMatched = $false
$cacheInspectionFileCount = -1
$cacheInspectionByteLength = -1L
$cacheInspectionPartialMemberCount = -1
try {
    $dotnetPath = Join-Path $micronDrive 'Program Files\dotnet\dotnet.exe'
    $verifierPath = Join-Path $micronDrive (
        'NLL\Tools\Phase3B2.NativeCacheVerifier-v1\' +
        'Phase3B2.NativeCacheMaterializer.dll'
    )
    $inspectionText = (& $dotnetPath $verifierPath `
        'inspect-cache-tree' (Join-Path $runtimeRoot 'cache') 2>&1 |
        Out-String).Trim()
    if ($LASTEXITCODE -eq 0) {
        $inspection = $inspectionText | ConvertFrom-Json
        $cacheInspectionFileCount = [int]$inspection.fileCount
        $cacheInspectionByteLength = [long]$inspection.contentByteLength
        $cacheInspectionPartialMemberCount = [int]$inspection.partialMemberCount
        $cacheInspectionMatched =
            $inspection.contractId -ceq
                'nll/phase3b2-native-cache-tree-inspection/v1' -and
            $inspection.longPathSafeEnumerationUsed -and
            $cacheInspectionFileCount -eq [int]$preRun.serverCacheFileCount -and
            $cacheInspectionByteLength -eq
                [long]$preRun.serverCacheContentByteLength -and
            $cacheInspectionPartialMemberCount -eq 0
    }
}
catch {
    $cacheInspectionMatched = $false
}

$exactCacheIdentityMatched = $false
$postRunCacheCanonicalSha256 = $null
$exactCacheIdentityStatusCode = 'verification_not_completed'
try {
    $cacheIdentityToolPath = Join-Path $PSScriptRoot `
        'get-phase3b2-epinel-exact-server-cache-identity-offline.ps1'
    $expectedCacheIdentityToolSha256 =
        '67acfc27e3ab13257cdaa0c572dcdb3634d20634679521cbbe2060e3fe9f2754'
    Assert-True (
        (Test-Path -LiteralPath $cacheIdentityToolPath -PathType Leaf) -and
        (Get-Sha256Hex $cacheIdentityToolPath) -ceq
            $expectedCacheIdentityToolSha256
    ) 'phase3b2_english_saus_ab_cache_identity_tool_invalid'
    $postRunCacheIdentityText = (& $cacheIdentityToolPath `
        -MicronDriveLetter $MicronDriveLetter `
        -TemporaryRoot $protectedRoot 2>&1 | Out-String).Trim()
    $postRunCacheIdentity = $postRunCacheIdentityText | ConvertFrom-Json
    $postRunCacheCanonicalSha256 =
        [string]$postRunCacheIdentity.activeCacheCanonicalSha256
    $exactCacheIdentityMatched =
        $postRunCacheIdentity.contractId -ceq
            'nll/phase3b2-epinel-server-cache-exact-identity/v1' -and
        $postRunCacheIdentity.exactServerCacheIdentityVerified -and
        $postRunCacheIdentity.memberDigestVerificationPerformed -and
        $postRunCacheCanonicalSha256 -ceq
            [string]$serverCachePreRun.activeCacheCanonicalSha256
    $exactCacheIdentityStatusCode = if ($exactCacheIdentityMatched) {
        'exact_member_identity_still_matched_after_run'
    }
    else {
        'exact_member_identity_mismatch_after_run'
    }
}
catch {
    $exactCacheIdentityMatched = $false
    $postRunCacheCanonicalSha256 = $null
    $exactCacheIdentityStatusCode =
        'exact_member_identity_verification_failed_after_restore'
}

$expectedZeroPairLeafNames = @(
    'asset-catalog-0.cat', 'asset-catalog-0.cat.nds'
)
$postRunLeafNames = @($postRunState.members | ForEach-Object {
        [string]$_.leafName
    })
$postRunPairNamesMatched =
    $postRunLeafNames.Count -eq $expectedZeroPairLeafNames.Count -and
    @($expectedZeroPairLeafNames | Where-Object {
            $_ -cnotin $postRunLeafNames
        }).Count -eq 0
$postRunPairTimelineMatched =
    $postRunState.memberCount -eq 2 -and
    @($postRunState.members | Where-Object {
            $creation = [DateTimeOffset]::Parse(
                [string]$_.creationTimeUtc
            )
            $lastWrite = [DateTimeOffset]::Parse(
                [string]$_.lastWriteTimeUtc
            )
            $creation -lt $sealedAt -or $creation -gt $completedAt -or
            $lastWrite -lt $sealedAt -or $lastWrite -gt $completedAt
        }).Count -eq 0
$recreatedExpectedZeroPair =
    $postRunState.directoryPresent -and
    $postRunState.directoryCount -eq 0 -and
    $postRunState.reparseDirectoryCount -eq 0 -and
    $postRunState.reparseFileCount -eq 0 -and
    $postRunState.memberCount -eq 2 -and
    $postRunPairNamesMatched -and $postRunPairTimelineMatched -and
    @($postRunState.members | Where-Object {
            $_.byteLength -ne 0 -or
            $_.sha256 -cne
                'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
        }).Count -eq 0
$postRunLastWriteSecondCodes = @(
    $postRunState.members | ForEach-Object {
        [DateTimeOffset]::Parse([string]$_.lastWriteTimeUtc).
            ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
    } | Sort-Object -Unique
)
$failureSecondCode = if ($postRunLastWriteSecondCodes.Count -eq 1) {
    [string]$postRunLastWriteSecondCodes[0]
}
else {
    $null
}
$failureSecondRequestCount = -1
$failureSecondMissCount = -1
if ($null -ne $failureSecondCode -and
    $assetEventBuckets.ContainsKey($failureSecondCode)) {
    $failureSecondRequestCount =
        [int]$assetEventBuckets[$failureSecondCode].requestCount
    $failureSecondMissCount =
        [int]$assetEventBuckets[$failureSecondCode].missCount
}
$boundedFailureSecondMissShapeMatched =
    $recreatedExpectedZeroPair -and
    $failureSecondRequestCount -ge 2 -and
    $failureSecondMissCount -eq 2
$classificationPreconditionsMatched =
    $goldenPinsMatched -and $exactCacheIdentityMatched -and
    $runLocalOnlyContractMatched
$lobbyPass =
    $classificationPreconditionsMatched -and
    $playerLogSingleRunBoundaryVerified -and
    $completion.observedStageCode -ceq 'lobby' -and
    $completion.outcomeCode -ceq 'success' -and
    $malformedCount -eq 0 -and $catalogNotInitializedCount -eq 0
$sameFailure =
    $classificationPreconditionsMatched -and
    $playerLogSingleRunBoundaryVerified -and
    $completion.observedStageCode -ceq 'catalogue_path' -and
    $completion.outcomeCode -ceq 'system_error' -and
    $boundedFailureSecondMissShapeMatched -and
    $malformedCount -gt 0 -and $catalogNotInitializedCount -gt 0
$classificationCode = if (-not $classificationPreconditionsMatched) {
    'inconclusive_precondition_drift_stop_without_retry'
}
elseif (-not $playerLogSingleRunBoundaryVerified) {
    'inconclusive_player_log_boundary_stop_without_retry'
}
elseif ($lobbyPass) {
    'english_client_cache_quarantine_reached_lobby'
}
elseif ($sameFailure) {
    'english_revision_absent_recreated_zero_pair_same_failure'
}
elseif (-not $postRunState.directoryPresent -and
    $completion.observedStageCode -ceq 'catalogue_path' -and
    $completion.outcomeCode -ceq 'system_error') {
    'english_quarantine_not_sufficient_without_recreation'
}
else {
    'inconclusive_stop_without_retry'
}

$postRunManifest = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-epinel-english-saus-postrun-manifest/v1'
    sealedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    assessmentUid = $uid
    runAssessmentUid = [string]$run.start.assessmentUid
    sourceRelativePathCode = 'client_clone_saus_en_after_ab_run'
    directoryPresent = [bool]$postRunState.directoryPresent
    directoryCount = [int]$postRunState.directoryCount
    reparseDirectoryCount = [int]$postRunState.reparseDirectoryCount
    reparseFileCount = [int]$postRunState.reparseFileCount
    memberCount = [int]$postRunState.memberCount
    contentByteLength = [long]$postRunState.contentByteLength
    members = @($postRunState.members)
    rawContentEmitted = $false
}
$postRunManifestText = ($postRunManifest | ConvertTo-Json -Depth 8) +
    [Environment]::NewLine
$postRunManifestPath = Join-Path $micronRoot 'post-run.manifest.json'
$protectedPostRunManifestPath = Join-Path $protectedRoot `
    'post-run.manifest.json'
Write-AtomicUtf8NoBom $postRunManifestPath $postRunManifestText
Write-AtomicUtf8NoBom $protectedPostRunManifestPath $postRunManifestText
$postRunManifestSha256 = Get-Sha256Hex $postRunManifestPath
Assert-True ((Get-Sha256Hex $protectedPostRunManifestPath) -ceq
        $postRunManifestSha256) `
    'phase3b2_english_saus_ab_postrun_manifest_copy_invalid'

$classification = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-epinel-english-saus-ab-classification/v2'
    classifiedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    assessmentUid = $uid
    quarantineReceiptSha256 = Get-Sha256Hex $quarantineReceiptPath
    preRunAuditReceiptSha256 = Get-Sha256Hex $preRunPath
    serverCachePreRunReceiptSha256 =
        Get-Sha256Hex $serverCachePreRunPath
    beforeManifestSha256 = Get-Sha256Hex $beforeManifestPath
    rollbackPlanSha256 = Get-Sha256Hex $rollbackPath
    restoreCheckpointSha256 = $checkpointSha256
    postRunManifestSha256 = $postRunManifestSha256
    runAssessmentUid = [string]$run.start.assessmentUid
    runStartReceiptSha256 = Get-Sha256Hex $run.startPath
    completionReceiptSha256 = Get-Sha256Hex $run.completionPath
    observedStageCode = [string]$completion.observedStageCode
    outcomeCode = [string]$completion.outcomeCode
    appLogDeltaAssetRequestCount = $assetRequestCount
    appLogDeltaAssetMissCount = $assetMissCount
    appLogDeltaCountScopeCode = 'entire_single_run_delta_observation_only'
    recreatedPairFailureSecondCode = $failureSecondCode
    recreatedPairFailureSecondAssetRequestCount =
        $failureSecondRequestCount
    recreatedPairFailureSecondAssetMissCount = $failureSecondMissCount
    recreatedPairBoundedFailureSecondMissShapeMatched =
        $boundedFailureSecondMissShapeMatched
    runLocalOnlyNetworkContractMatched = $runLocalOnlyContractMatched
    playerLogByteLength = [long]$playerLogItem.Length
    playerLogSha256 = $playerLogSha256
    playerLogChangedFromPreRun =
        $playerLogSha256 -cne [string]$preRun.playerLogSnapshot.sha256
    playerLogEngineInitializationCount = $engineInitializationCount
    playerLogSingleRunBoundaryVerified =
        $playerLogSingleRunBoundaryVerified
    playerLogMatchedCompletionReceipt =
        $playerLogMatchedCompletionReceipt
    rawPlayerLogCopied = $false
    rawAppLogCopied = $false
    malformedDatabaseMatchCount = $malformedCount
    catalogNotInitializedMatchCount = $catalogNotInitializedCount
    zeroCatalogReferenceMatchCount = $zeroCatalogReferenceCount
    catalogUpdateEntryMatchCount = $catalogUpdateEntryCount
    clientEnglishDirectoryRecreated =
        [bool]$postRunState.directoryPresent
    recreatedPairExactLeafNamesMatched = $postRunPairNamesMatched
    recreatedPairRunTimelineMatched = $postRunPairTimelineMatched
    recreatedExpectedZeroPair = $recreatedExpectedZeroPair
    postRunEnglishMemberCount = [int]$postRunState.memberCount
    postRunEnglishContentByteLength =
        [long]$postRunState.contentByteLength
    postRunTreeQuarantined = $postRunMoved
    restoreSourceCode = $restoreSourceCode
    originalEnglishTreeRestored = $beforeRestored
    goldenPinCount = $goldenPins.Count
    matchedGoldenPinCount = $matchedGoldenPinCount
    goldenPinsStillMatchedSealedBaselineAfterRun = $goldenPinsMatched
    serverCacheFileCount = $cacheInspectionFileCount
    serverCacheContentByteLength = $cacheInspectionByteLength
    serverCachePartialMemberCount = $cacheInspectionPartialMemberCount
    serverCacheAggregateShapeStillMatchedAfterRun = $cacheInspectionMatched
    serverCachePreRunCanonicalSha256 =
        [string]$serverCachePreRun.activeCacheCanonicalSha256
    serverCachePostRunCanonicalSha256 = $postRunCacheCanonicalSha256
    serverCacheExactIdentityStatusCode = $exactCacheIdentityStatusCode
    serverCacheExactMemberIdentityStillMatchedAfterRun =
        $exactCacheIdentityMatched
    classificationPreconditionsMatched =
        $classificationPreconditionsMatched
    classificationCode = $classificationCode
    singleAbRunConsumed = $true
    retryAuthorized = $false
    originalInstallInspected = $false
    originalInstallMutationPerformedByThisTool = $false
    databaseStillMatchedSealedBaselineAfterRun = $goldenDatabaseMatched
    goldenToolsStillMatchedSealedBaselineAfterRun = $goldenToolsMatched
    serverBinaryStillMatchedSealedBaselineAfterRun =
        $goldenServerBinaryMatched
    localLowInspected = $true
    localLowMutationPerformedByThisTool = $false
    existingOperatorCacheInspected = $false
    existingOperatorCacheModified = $false
    runtimeBindingCreatedByThisTool = $false
    startupPreflightModifiedByThisTool = $false
    officialOutboundUsed = if ($runLocalOnlyContractMatched) {
        $false
    }
    else {
        $null
    }
    runtimeColdAfterCompletion = $true
    nextStepCode = if ($lobbyPass) {
        'return_to_samsung_preserve_success_and_choose_new_baseline'
    }
    elseif ($sameFailure) {
        'stop_no_retry_english_revision_closure_or_local_state_authority_required'
    }
    else {
        'stop_no_retry_manual_classification_required'
    }
}
$classificationText = ($classification | ConvertTo-Json -Depth 8) +
    [Environment]::NewLine
$micronPendingPath = $classificationPath + '.pending'
$protectedPendingPath = $protectedClassificationPath + '.pending'
try {
    Write-AtomicUtf8NoBom $micronPendingPath $classificationText
    Write-AtomicUtf8NoBom $protectedPendingPath $classificationText
    $classificationSha256 = Get-Sha256Hex $micronPendingPath
    Assert-True ((Get-Sha256Hex $protectedPendingPath) -ceq
            $classificationSha256) `
        'phase3b2_english_saus_ab_classification_pending_copy_invalid'
    Move-Item -LiteralPath $protectedPendingPath `
        -Destination $protectedClassificationPath
    Move-Item -LiteralPath $micronPendingPath `
        -Destination $classificationPath
    Assert-True (
        (Get-Sha256Hex $classificationPath) -ceq $classificationSha256 -and
        (Get-Sha256Hex $protectedClassificationPath) -ceq
            $classificationSha256
    ) 'phase3b2_english_saus_ab_classification_publish_invalid'
}
catch {
    $publishFailure = $_
    foreach ($path in @(
            $micronPendingPath, $protectedPendingPath
        )) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force
        }
    }
    throw $publishFailure
}

[ordered]@{
    Receipt = $classification
    MicronReceiptPath = $classificationPath
    MicronReceiptByteLength =
        (Get-Item -LiteralPath $classificationPath).Length
    MicronReceiptSha256 = $classificationSha256
    ProtectedReceiptPath = $protectedClassificationPath
} | ConvertTo-Json -Depth 8
