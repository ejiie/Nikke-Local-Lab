#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProfileCapturePath,
    [Parameter(Mandatory = $true)]
    [string]$SourceLocalLowRoot,
    [string]$ProgressionTemplateArchivePath = '',
    [Parameter(Mandatory = $true)]
    [string]$ParentSealReceiptPath,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedParentSealReceiptSha256,
    [string]$RuntimeRoot =
        'E:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64',
    [string]$DetachedParentGoldenRoot = '',
    [string]$OutputRoot =
        'D:\NikkeLocalLab\Backups\phase3b2-user-progression-source-v1'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True {
    param(
        [bool]$Condition,
        [string]$FailureCode
    )

    if (-not $Condition) {
        throw $FailureCode
    }
}

function Get-Sha256Hex {
    param([string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).
        Hash.ToLowerInvariant()
}

function Get-TextSha256Hex {
    param([string]$Value)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return (($sha.ComputeHash($bytes) | ForEach-Object {
                    $_.ToString('x2')
                }) -join '')
    }
    finally {
        $sha.Dispose()
    }
}

function Write-JsonUtf8NoBom {
    param(
        [string]$Path,
        [object]$Value
    )

    $json = $Value | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText(
        $Path,
        $json + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false))
}

function Get-PositiveInt32 {
    param(
        [object]$Value,
        [string]$FailureCode
    )

    $parsed = 0
    Assert-True ([int]::TryParse(
            [string]$Value,
            [System.Globalization.NumberStyles]::None,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref]$parsed) -and $parsed -gt 0) $FailureCode
    return $parsed
}

$profileCaptureResolved = [System.IO.Path]::GetFullPath($ProfileCapturePath)
$sourceLocalLowResolved = [System.IO.Path]::GetFullPath($SourceLocalLowRoot)
$parentSealReceiptResolved =
    [System.IO.Path]::GetFullPath($ParentSealReceiptPath)
$runtimeRootResolved = [System.IO.Path]::GetFullPath($RuntimeRoot)
$detachedParentGoldenRootResolved = if (
    [string]::IsNullOrWhiteSpace($DetachedParentGoldenRoot)) {
    $null
} else {
    [System.IO.Path]::GetFullPath($DetachedParentGoldenRoot)
}
$outputRootResolved = [System.IO.Path]::GetFullPath($OutputRoot)

Assert-True (Test-Path -LiteralPath $profileCaptureResolved -PathType Leaf) `
    'phase3b2_progression_source_profile_capture_missing'
Assert-True (Test-Path -LiteralPath $sourceLocalLowResolved `
        -PathType Container) `
    'phase3b2_progression_source_locallow_root_missing'
Assert-True (Test-Path -LiteralPath $parentSealReceiptResolved `
        -PathType Leaf) `
    'phase3b2_progression_source_parent_seal_missing'
if ($null -eq $detachedParentGoldenRootResolved) {
    Assert-True ($runtimeRootResolved.StartsWith(
            'E:\NLL\EpinelPS\',
            [System.StringComparison]::OrdinalIgnoreCase)) `
        'phase3b2_progression_source_runtime_root_invalid'
}
else {
    Assert-True ($detachedParentGoldenRootResolved.StartsWith(
            'D:\NikkeLocalLab\Backups\phase3b2-user-progression-parent-golden-v1\',
            [System.StringComparison]::OrdinalIgnoreCase)) `
        'phase3b2_progression_source_detached_parent_root_invalid'
}
Assert-True ($outputRootResolved.StartsWith(
        'D:\NikkeLocalLab\Backups\',
        [System.StringComparison]::OrdinalIgnoreCase)) `
    'phase3b2_progression_source_output_root_invalid'
Assert-True ($sourceLocalLowResolved.EndsWith(
        '\com_proximabeta\NIKKE',
        [System.StringComparison]::OrdinalIgnoreCase) -or
    $sourceLocalLowResolved.EndsWith(
        '\com.proximabeta\NIKKE',
        [System.StringComparison]::OrdinalIgnoreCase)) `
    'phase3b2_progression_source_locallow_role_invalid'

$runtimeProcessNames = @(
    'NIKKE',
    'EpinelPS',
    'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
)
$runningProcesses = @(
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $runtimeProcessNames -contains $_.ProcessName }
)
Assert-True ($runningProcesses.Count -eq 0) `
    'phase3b2_progression_source_runtime_not_cold'

$parentSealSha256 = Get-Sha256Hex $parentSealReceiptResolved
Assert-True ($parentSealSha256 -ceq
        $ExpectedParentSealReceiptSha256.ToLowerInvariant()) `
    'phase3b2_progression_source_parent_seal_digest_invalid'
$parentSeal = Get-Content -LiteralPath $parentSealReceiptResolved -Raw |
    ConvertFrom-Json
Assert-True ($parentSeal.contractId -ceq
        'nll/phase3b2-user-progression-parent-golden-seal/v1' -and
    [bool]$parentSeal.runtimeCold -and
    [bool]$parentSeal.databaseBackupVerified -and
    [bool]$parentSeal.sqliteAbsenceSealed) `
    'phase3b2_progression_source_parent_seal_shape_invalid'

$databaseRootResolved = if ($null -eq $detachedParentGoldenRootResolved) {
    $runtimeRootResolved
} else {
    $detachedParentGoldenRootResolved
}
$runtimeDatabasePath = Join-Path $databaseRootResolved 'db.json'
Assert-True (Test-Path -LiteralPath $runtimeDatabasePath -PathType Leaf) `
    'phase3b2_progression_source_runtime_database_missing'
Assert-True ((Get-Sha256Hex $runtimeDatabasePath) -ceq
        [string]$parentSeal.databaseSha256) `
    'phase3b2_progression_source_runtime_database_drifted'
$sqliteMembers = @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal')
Assert-True (@($sqliteMembers | Where-Object {
            Test-Path -LiteralPath (Join-Path $databaseRootResolved $_)
        }).Count -eq 0) `
    'phase3b2_progression_source_sqlite_runtime_not_absent'

$profileCaptureItem = Get-Item -LiteralPath $profileCaptureResolved
$profileCaptureSha256Before = Get-Sha256Hex $profileCaptureResolved
$profileText = [System.IO.File]::ReadAllText($profileCaptureResolved)
$profile = $profileText | ConvertFrom-Json
$packets = @($profile.phase_1_initial_load) +
    @($profile.phase_2_after_click)
$profilePackets = @($packets | Where-Object {
        $_.endpoint -ceq 'GetUserProfileBasicInfo'
    })
Assert-True ($profilePackets.Count -eq 1 -and
    $null -ne $profilePackets[0].data.basic_info) `
    'phase3b2_progression_source_profile_packet_shape_invalid'
$basicInfo = $profilePackets[0].data.basic_info
$normalStageId = Get-PositiveInt32 `
    -Value $basicInfo.progress_normal_campaign `
    -FailureCode 'phase3b2_progression_source_normal_stage_invalid'
$hardStageId = Get-PositiveInt32 `
    -Value $basicInfo.progress_hard_campaign `
    -FailureCode 'phase3b2_progression_source_hard_stage_invalid'
$storyStageId = Get-PositiveInt32 `
    -Value $basicInfo.progress_easy_campaign `
    -FailureCode 'phase3b2_progression_source_story_stage_invalid'

$archiveCandidates = @(
    Get-ChildItem -LiteralPath $sourceLocalLowResolved -File -ErrorAction Stop |
        Where-Object { $_.Name -like 'NKSD_TRIGGER_*' }
)
Assert-True ($archiveCandidates.Count -gt 0) `
    'phase3b2_progression_source_trigger_archive_missing'

$matchedArchives = @()
$operatorSelectedProgressionTemplate = $false
$sourceArchiveBindingCode = 'raw_identity_matched_archive'
foreach ($candidate in $archiveCandidates) {
    $suffix = $candidate.Name.Substring('NKSD_TRIGGER_'.Length)
    Assert-True (-not [string]::IsNullOrWhiteSpace($suffix) -and
        $suffix -match '^\d+_\d+$') `
        'phase3b2_progression_source_trigger_archive_leaf_invalid'
    if ([string]::IsNullOrWhiteSpace($ProgressionTemplateArchivePath)) {
        $identityToken = ($suffix -split '_')[-1]
        $pattern = '(?<!\d)' + [regex]::Escape($identityToken) + '(?!\d)'
        if ([regex]::IsMatch($profileText, $pattern)) {
            $matchedArchives += $candidate
        }
    }
}
if (-not [string]::IsNullOrWhiteSpace($ProgressionTemplateArchivePath)) {
    $templateResolved =
        [IO.Path]::GetFullPath($ProgressionTemplateArchivePath)
    $localLowPrefix = $sourceLocalLowResolved.
        TrimEnd([IO.Path]::DirectorySeparatorChar) +
        [IO.Path]::DirectorySeparatorChar
    Assert-True ($templateResolved.StartsWith(
            $localLowPrefix,
            [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $templateResolved -PathType Leaf) -and
        ([IO.Path]::GetFileName($templateResolved) -match
            '^NKSD_TRIGGER_\d+_\d+$')) `
        'phase3b2_progression_source_template_archive_invalid'
    $matchedArchives = @($archiveCandidates | Where-Object {
            $_.FullName -ceq $templateResolved
        })
    $operatorSelectedProgressionTemplate = $matchedArchives.Count -eq 1
    $sourceArchiveBindingCode = 'operator_selected_progression_template'
}
Assert-True ($matchedArchives.Count -eq 1) `
    'phase3b2_progression_source_trigger_archive_match_not_unique'

$sourceArchivePath = $matchedArchives[0].FullName
$sourceArchiveItem = Get-Item -LiteralPath $sourceArchivePath
$sourceArchiveSha256Before = Get-Sha256Hex $sourceArchivePath
$sourceArchiveIdentityDigest = Get-TextSha256Hex $matchedArchives[0].Name

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = $null
$reader = $null
$selectedRecords = New-Object System.Collections.Generic.List[object]
$selectedKeys = New-Object 'System.Collections.Generic.HashSet[string]'
$selectedCounts = [ordered]@{
    CampaignClear = 0
    ChapterClear = 0
    MainQuestClear = 0
    CampaignGroupClear = 0
    HardChapterClear = 0
}
$selectedTypes = @{
    2 = 'CampaignClear'
    3 = 'ChapterClear'
    22 = 'MainQuestClear'
    25 = 'CampaignGroupClear'
    35 = 'HardChapterClear'
}
$totalRecordCount = 0
$previousSourceSequence = [long]-1
$selectedOrder = 0
$entryMetadata = @()
try {
    $archive = [System.IO.Compression.ZipFile]::OpenRead($sourceArchivePath)
    $entryMetadata = @($archive.Entries | Sort-Object FullName |
        ForEach-Object {
            [ordered]@{
                roleCode = switch ($_.FullName) {
                    'trigger.txt' { 'trigger_records' }
                    'header' { 'opaque_header' }
                    'meta' { 'opaque_meta' }
                    default { 'unexpected' }
                }
                byteLength = [long]$_.Length
                compressedByteLength = [long]$_.CompressedLength
            }
        })
    $entryNames = @($archive.Entries | ForEach-Object { $_.FullName } |
        Sort-Object)
    Assert-True ($entryNames.Count -eq 3 -and
        $entryNames[0] -ceq 'header' -and
        $entryNames[1] -ceq 'meta' -and
        $entryNames[2] -ceq 'trigger.txt') `
        'phase3b2_progression_source_trigger_archive_shape_invalid'

    $triggerEntry = $archive.GetEntry('trigger.txt')
    Assert-True ($null -ne $triggerEntry -and $triggerEntry.Length -gt 0) `
        'phase3b2_progression_source_trigger_entry_missing'
    $reader = [System.IO.StreamReader]::new(
        $triggerEntry.Open(),
        [System.Text.Encoding]::UTF8,
        $true,
        65536,
        $false)
    while (($line = $reader.ReadLine()) -ne $null) {
        if ($line.Length -eq 0) {
            continue
        }
        $totalRecordCount++
        $parts = $line.Split(',')
        Assert-True ($parts.Count -eq 7 -and
            $parts[0] -ceq 's' -and $parts[6] -ceq 'e') `
            'phase3b2_progression_source_trigger_record_shape_invalid'

        $sourceSequence = [long]0
        $triggerType = 0
        $conditionId = 0
        $userValue = 0
        $createdAt = [long]0
        Assert-True ([long]::TryParse($parts[1], [ref]$sourceSequence) -and
            [int]::TryParse($parts[2], [ref]$triggerType) -and
            [int]::TryParse($parts[3], [ref]$conditionId) -and
            [int]::TryParse($parts[4], [ref]$userValue) -and
            [long]::TryParse($parts[5], [ref]$createdAt)) `
            'phase3b2_progression_source_trigger_record_numeric_invalid'
        Assert-True ($sourceSequence -gt $previousSourceSequence) `
            'phase3b2_progression_source_trigger_sequence_invalid'
        $previousSourceSequence = $sourceSequence

        if ($selectedTypes.ContainsKey($triggerType)) {
            $typeName = [string]$selectedTypes[$triggerType]
            $key = $triggerType.ToString() + ':' + $conditionId.ToString()
            Assert-True ($selectedKeys.Add($key)) `
                'phase3b2_progression_source_selected_trigger_duplicate'
            $selectedOrder++
            $selectedCounts[$typeName] =
                [int]$selectedCounts[$typeName] + 1
            $selectedRecords.Add([ordered]@{
                localOrder = $selectedOrder
                typeCode = $triggerType
                typeName = $typeName
                conditionId = $conditionId
                userValue = $userValue
                createdAt = $createdAt
            })
        }
    }
}
finally {
    if ($null -ne $reader) {
        $reader.Dispose()
    }
    if ($null -ne $archive) {
        $archive.Dispose()
    }
}

Assert-True ($totalRecordCount -gt 0 -and $selectedRecords.Count -gt 0) `
    'phase3b2_progression_source_trigger_selection_empty'
foreach ($typeName in $selectedCounts.Keys) {
    Assert-True ([int]$selectedCounts[$typeName] -gt 0) `
        ('phase3b2_progression_source_trigger_type_empty:' + $typeName)
}

$mainQuestData = @($selectedRecords |
    Where-Object { $_.typeCode -eq 22 } |
    Sort-Object conditionId |
    ForEach-Object {
        [ordered]@{
            questId = [int]$_.conditionId
            rewardClaimed = $true
        }
    })
Assert-True ($mainQuestData.Count -eq
    [int]$selectedCounts.MainQuestClear) `
    'phase3b2_progression_source_main_quest_projection_invalid'

$selectedCanonical = [System.Text.StringBuilder]::new()
foreach ($record in $selectedRecords) {
    [void]$selectedCanonical.Append($record.typeCode)
    [void]$selectedCanonical.Append("`t")
    [void]$selectedCanonical.Append($record.conditionId)
    [void]$selectedCanonical.Append("`t")
    [void]$selectedCanonical.Append($record.userValue)
    [void]$selectedCanonical.Append("`t")
    [void]$selectedCanonical.Append($record.createdAt)
    [void]$selectedCanonical.Append("`n")
}
$selectedCanonicalSha256 = Get-TextSha256Hex $selectedCanonical.ToString()
$mainQuestCanonical = [System.Text.StringBuilder]::new()
foreach ($quest in $mainQuestData) {
    [void]$mainQuestCanonical.Append($quest.questId)
    [void]$mainQuestCanonical.Append("`ttrue`n")
}
$mainQuestCanonicalSha256 = Get-TextSha256Hex $mainQuestCanonical.ToString()

$profileCaptureSha256After = Get-Sha256Hex $profileCaptureResolved
$sourceArchiveSha256After = Get-Sha256Hex $sourceArchivePath
Assert-True ($profileCaptureSha256After -ceq $profileCaptureSha256Before -and
    $sourceArchiveSha256After -ceq $sourceArchiveSha256Before) `
    'phase3b2_progression_source_input_mutation_detected'

Assert-True (Test-Path -LiteralPath (Split-Path -Parent $outputRootResolved) `
        -PathType Container) `
    'phase3b2_progression_source_output_parent_missing'
if (-not (Test-Path -LiteralPath $outputRootResolved -PathType Container)) {
    New-Item -ItemType Directory -Path $outputRootResolved | Out-Null
}
$extractionUid = [guid]::NewGuid().ToString()
$extractionRoot = Join-Path $outputRootResolved $extractionUid
Assert-True (-not (Test-Path -LiteralPath $extractionRoot)) `
    'phase3b2_progression_source_output_already_exists'
New-Item -ItemType Directory -Path $extractionRoot | Out-Null

$privateSource = [ordered]@{
    schemaVersion = 1
    contractId =
        'nll/phase3b2-user-progression-private-source/v1'
    extractionUid = $extractionUid
    provenanceCode =
        if ($operatorSelectedProgressionTemplate) {
            'operator_profile_capture_plus_selected_progression_template'
        } else {
            'operator_profile_capture_plus_matched_official_client_trigger_cache'
        }
    sourceProfile = [ordered]@{
        byteLength = [long]$profileCaptureItem.Length
        sha256 = $profileCaptureSha256Before
    }
    sourceTriggerArchive = [ordered]@{
        byteLength = [long]$sourceArchiveItem.Length
        sha256 = $sourceArchiveSha256Before
        identityDigest = $sourceArchiveIdentityDigest
        rawRecordCount = $totalRecordCount
        bindingCode = $sourceArchiveBindingCode
    }
    lastStageIds = [ordered]@{
        normal = $normalStageId
        hard = $hardStageId
        story = $storyStageId
    }
    selectedTriggers = $selectedRecords.ToArray()
    mainQuestData = $mainQuestData
    mainQuestRewardStateCode =
        'operator_attested_completed_and_reward_claimed'
    sourceSequencePersisted = $false
    officialUserIdentifierPersisted = $false
    credentialOrSessionFieldPersisted = $false
}
$privateSourcePath = Join-Path $extractionRoot 'progression.source.private.json'
Write-JsonUtf8NoBom -Path $privateSourcePath -Value $privateSource
$privateSourceItem = Get-Item -LiteralPath $privateSourcePath
$privateSourceSha256 = Get-Sha256Hex $privateSourcePath

$aggregateManifest = [ordered]@{
    schemaVersion = 1
    contractId =
        'nll/phase3b2-user-progression-source-free-aggregate/v1'
    extractionUid = $extractionUid
    parentGoldenSealReceiptSha256 = $parentSealSha256
    profileProgressFieldCount = 3
    triggerArchiveEntryCount = $entryMetadata.Count
    triggerArchiveEntries = $entryMetadata
    rawTriggerRecordCount = $totalRecordCount
    selectedTriggerRecordCount = $selectedRecords.Count
    selectedTriggerCounts = $selectedCounts
    selectedTriggerCanonicalSha256 = $selectedCanonicalSha256
    mainQuestCount = $mainQuestData.Count
    mainQuestRewardClaimedCount = @($mainQuestData |
        Where-Object { $_.rewardClaimed }).Count
    mainQuestCanonicalSha256 = $mainQuestCanonicalSha256
    mainQuestRewardsClaimedByOperatorAttestation = $true
    sourceArchiveLeafEmitted = $false
    sourceSequencePersisted = $false
    rawProfileCopied = $false
    rawTriggerArchiveCopied = $false
    officialUserIdentifierPersisted = $false
    credentialOrSessionFieldExtracted = $false
    credentialOrSessionFieldPersisted = $false
    intlAuthInspected = $false
}
$aggregateManifestPath = Join-Path $extractionRoot 'aggregate.manifest.json'
Write-JsonUtf8NoBom -Path $aggregateManifestPath -Value $aggregateManifest
$aggregateManifestItem = Get-Item -LiteralPath $aggregateManifestPath
$aggregateManifestSha256 = Get-Sha256Hex $aggregateManifestPath

$receipt = [ordered]@{
    schemaVersion = 1
    contractId =
        'nll/phase3b2-user-progression-source-extraction/v1'
    extractedAtUtc = [DateTime]::UtcNow.ToString('o')
    extractionUid = $extractionUid
    environmentCode = if ($null -eq $detachedParentGoldenRootResolved) {
        'samsung_runtime_cold_read_only_source_extraction'
    } else {
        'micron_runtime_cold_detached_parent_golden_read_only_source_extraction'
    }
    parentGoldenSealReceiptSha256 = $parentSealSha256
    sourceProfileByteLength = [long]$profileCaptureItem.Length
    sourceProfileSha256 = $profileCaptureSha256Before
    sourceTriggerArchiveByteLength = [long]$sourceArchiveItem.Length
    sourceTriggerArchiveSha256 = $sourceArchiveSha256Before
    sourceTriggerArchiveIdentityDigest = $sourceArchiveIdentityDigest
    sourceProfileMatchedArchiveCount = if (
        $operatorSelectedProgressionTemplate) { 0 } else { 1 }
    operatorSelectedProgressionTemplate =
        $operatorSelectedProgressionTemplate
    sourceArchiveBindingCode = $sourceArchiveBindingCode
    rawTriggerRecordCount = $totalRecordCount
    selectedTriggerRecordCount = $selectedRecords.Count
    campaignClearCount = [int]$selectedCounts.CampaignClear
    chapterClearCount = [int]$selectedCounts.ChapterClear
    hardChapterClearCount = [int]$selectedCounts.HardChapterClear
    campaignGroupClearCount = [int]$selectedCounts.CampaignGroupClear
    mainQuestClearCount = [int]$selectedCounts.MainQuestClear
    selectedTriggerCanonicalSha256 = $selectedCanonicalSha256
    mainQuestRewardClaimedCount = $mainQuestData.Count
    mainQuestCanonicalSha256 = $mainQuestCanonicalSha256
    privateSourceByteLength = [long]$privateSourceItem.Length
    privateSourceSha256 = $privateSourceSha256
    aggregateManifestByteLength = [long]$aggregateManifestItem.Length
    aggregateManifestSha256 = $aggregateManifestSha256
    sourceInputsUnchanged = $true
    runtimeCold = $true
    runtimeDatabaseModified = $false
    detachedParentGoldenDatabaseUsed =
        ($null -ne $detachedParentGoldenRootResolved)
    sqliteRuntimeCreated = $false
    localLowModified = $false
    rawProfileCopied = $false
    rawTriggerArchiveCopied = $false
    officialUserIdentifierPersisted = $false
    credentialOrSessionFieldExtracted = $false
    credentialOrSessionFieldPersisted = $false
    intlAuthInspected = $false
    officialOutboundUsed = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
    nextStepCode =
        'build_progression_candidate_from_parent_golden_and_private_source'
}
$receiptPath = Join-Path $extractionRoot 'extraction.receipt.json'
Write-JsonUtf8NoBom -Path $receiptPath -Value $receipt
$receiptItem = Get-Item -LiteralPath $receiptPath
$receiptSha256 = Get-Sha256Hex $receiptPath

[ordered]@{
    Receipt = $receipt
    ExtractionRoot = $extractionRoot
    ReceiptPath = $receiptPath
    ReceiptByteLength = [long]$receiptItem.Length
    ReceiptSha256 = $receiptSha256
} | ConvertTo-Json -Depth 16
