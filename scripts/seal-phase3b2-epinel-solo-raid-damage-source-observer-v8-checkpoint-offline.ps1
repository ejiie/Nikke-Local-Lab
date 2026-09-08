#requires -Version 5.1

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Z]$')]
    [string]$MicronDriveLetter = 'E',

    [string]$BackupRoot =
        'D:\NikkeLocalLab\Backups\' +
        'phase3b2-season26-challenge-damage-observer-v8-checkpoint-v1',

    [switch]$AuditOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$FailureCode
    )

    if (-not $Condition) {
        throw $FailureCode
    }
}

function Get-Sha256Hex {
    param([Parameter(Mandatory = $true)][string]$Path)

    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-JsonUtf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllText(
        $Path,
        ($Value | ConvertTo-Json -Depth 30),
        [Text.UTF8Encoding]::new($false)
    )
}

function Copy-VerifiedFile {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [string]$ExpectedSha256 = ''
    )

    Assert-True (Test-Path -LiteralPath $Source -PathType Leaf) `
        ('phase3b2_v8_checkpoint_source_missing:' + $Source)
    if ($ExpectedSha256) {
        Assert-True ((Get-Sha256Hex $Source) -ceq $ExpectedSha256) `
            ('phase3b2_v8_checkpoint_source_drifted:' + $Source)
    }
    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Copy-Item -LiteralPath $Source -Destination $Destination
    Assert-True (
        (Get-Sha256Hex $Destination) -ceq (Get-Sha256Hex $Source)
    ) ('phase3b2_v8_checkpoint_copy_verification_failed:' + $Destination)
}

function Get-FileDescriptor {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $relative = $Path.Substring($Root.Length + 1).Replace('\', '/')
    $item = Get-Item -LiteralPath $Path
    [ordered]@{
        relativePath = $relative
        byteLength = [long]$item.Length
        sha256 = Get-Sha256Hex $Path
    }
}

$micronDrive = $MicronDriveLetter + ':\'
$runtimeRoot = Join-Path $micronDrive `
    'NLL\Runtime\EpinelPS-SoloRaidDamageSourceObserver-v8'
$deploymentRoot = Join-Path $micronDrive 'NLL\E\P3SRDSO8D'
$runLaneRoot = Join-Path $micronDrive 'NLL\E\P3SRDSO8'
$pointerPath = Join-Path $runLaneRoot 'active-run.pointer.json'
$deploymentPath = Join-Path $deploymentRoot 'deployment.receipt.json'
$auditPath = Join-Path $deploymentRoot 'audit.receipt.json'
$sourceManifestPath = Join-Path $deploymentRoot 'source.manifest.tsv'

foreach ($path in @(
    $runtimeRoot, $deploymentRoot, $runLaneRoot,
    (Join-Path $micronDrive 'Windows\System32')
)) {
    Assert-True (Test-Path -LiteralPath $path -PathType Container) `
        ('phase3b2_v8_checkpoint_environment_invalid:' + $path)
}
foreach ($path in @(
    $pointerPath, $deploymentPath, $auditPath, $sourceManifestPath
)) {
    Assert-True (Test-Path -LiteralPath $path -PathType Leaf) `
        ('phase3b2_v8_checkpoint_input_missing:' + $path)
}

$deployment = Get-Content -LiteralPath $deploymentPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$audit = Get-Content -LiteralPath $auditPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$pointer = Get-Content -LiteralPath $pointerPath -Raw -Encoding UTF8 |
    ConvertFrom-Json

Assert-True (
    $deployment.contractId -ceq
        'nll/phase3b2-epinel-solo-raid-damage-source-observer-deployment/v8' -and
    $deployment.derivedLaneCode -ceq
        'epinel_solo_raid_damage_source_observer_v8' -and
    -not $deployment.responseSemanticsChanged -and
    -not $deployment.v7ParentModified -and
    -not $deployment.micronLobbyGoldenModified -and
    -not $deployment.dLobbyGoldenModified
) 'phase3b2_v8_checkpoint_deployment_invalid'
Assert-True (
    $audit.contractId -ceq
        'nll/phase3b2-epinel-solo-raid-damage-source-observer-audit/v8' -and
    $audit.selectedManagerFailedCount -eq 0 -and
    -not $audit.serverBehaviorChanged
) 'phase3b2_v8_checkpoint_audit_invalid'
Assert-True (
    (Get-Sha256Hex $sourceManifestPath) -ceq
        ([string]$deployment.sourceManifestSha256)
) 'phase3b2_v8_checkpoint_source_manifest_drifted'

$assessmentUid = [string]$pointer.assessmentUid
Assert-True (
    $assessmentUid -match
        '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
) 'phase3b2_v8_checkpoint_assessment_uid_invalid'
$runRoot = Join-Path $runLaneRoot $assessmentUid
$runStartPath = Join-Path $runRoot 'run-start.receipt.json'
$markerPath = Join-Path $runRoot 'regroup.observations.json'
$measurementPath = Join-Path $runRoot 'startup.measurement.json'
$databaseBeforePath = Join-Path $runRoot 'db.before.bin'
$hostsBeforePath = Join-Path $runRoot 'hosts.before.bin'
$databaseObservedPath = Join-Path $runtimeRoot 'db.json'
$serverDllPath = Join-Path $runtimeRoot 'EpinelPS.dll'

foreach ($path in @(
    $runStartPath, $markerPath, $measurementPath, $databaseBeforePath,
    $hostsBeforePath, $databaseObservedPath, $serverDllPath
)) {
    Assert-True (Test-Path -LiteralPath $path -PathType Leaf) `
        ('phase3b2_v8_checkpoint_run_input_missing:' + $path)
}

$runStart = Get-Content -LiteralPath $runStartPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$marker = Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True (
    $runStart.assessmentUid -ceq $assessmentUid -and
    (Get-Sha256Hex $runStartPath) -ceq
        ([string]$pointer.runStartReceiptSha256) -and
    -not $runStart.officialLauncherExecutionStarted -and
    -not $runStart.officialOutboundFallbackUsed
) 'phase3b2_v8_checkpoint_run_start_invalid'
Assert-True (
    $marker.assessmentUid -ceq $assessmentUid -and
    -not $marker.rawRequestPayloadPersisted -and
    [int]$marker.damageSourceObservationCount -gt 0
) 'phase3b2_v8_checkpoint_marker_invalid'
Assert-True (
    (Get-Sha256Hex $databaseBeforePath) -ceq
        ([string]$pointer.databaseBeforeSha256)
) 'phase3b2_v8_checkpoint_baseline_database_invalid'
Assert-True (
    (Get-Item -LiteralPath $serverDllPath).Length -eq
        [long]$deployment.appliedServerDllByteLength -and
    (Get-Sha256Hex $serverDllPath) -ceq
        ([string]$deployment.appliedServerDllSha256)
) 'phase3b2_v8_checkpoint_server_dll_invalid'

$toolRoot = Join-Path $micronDrive 'NLL\Tools'
foreach ($tool in @($deployment.installedTools)) {
    $toolPath = Join-Path $toolRoot ([string]$tool.leaf)
    Assert-True (
        (Test-Path -LiteralPath $toolPath -PathType Leaf) -and
        (Get-Item -LiteralPath $toolPath).Length -eq [long]$tool.byteLength -and
        (Get-Sha256Hex $toolPath) -ceq ([string]$tool.sha256)
    ) ('phase3b2_v8_checkpoint_tool_invalid:' + $tool.leaf)
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$externalRoot = Join-Path $repoRoot '.external\EpinelPS'
$sourceRows = @(Get-Content -LiteralPath $sourceManifestPath -Encoding UTF8 |
    Where-Object { $_.Trim().Length -gt 0 } | ForEach-Object {
        $parts = $_ -split "`t"
        Assert-True ($parts.Count -eq 3) `
            'phase3b2_v8_checkpoint_source_manifest_row_invalid'
        [pscustomobject]@{
            relativePath = $parts[0]
            byteLength = [long]$parts[1]
            sha256 = $parts[2]
        }
    })
Assert-True ($sourceRows.Count -eq [int]$deployment.sourceManifestMemberCount) `
    'phase3b2_v8_checkpoint_source_manifest_count_invalid'
foreach ($row in $sourceRows) {
    $sourcePath = Join-Path $externalRoot `
        ($row.relativePath.Replace('/', '\'))
    Assert-True (
        (Test-Path -LiteralPath $sourcePath -PathType Leaf) -and
        (Get-Item -LiteralPath $sourcePath).Length -eq $row.byteLength -and
        (Get-Sha256Hex $sourcePath) -ceq $row.sha256
    ) ('phase3b2_v8_checkpoint_source_invalid:' + $row.relativePath)
}

$cacheLink = Get-Item -LiteralPath (Join-Path $runtimeRoot 'cache') -Force
Assert-True (
    $cacheLink.LinkType -eq 'Junction' -and
    -not [string]::IsNullOrWhiteSpace([string]$cacheLink.Target)
) 'phase3b2_v8_checkpoint_cache_link_invalid'

$auditResult = [ordered]@{
    schemaVersion = 1
    contractId =
        'nll/phase3b2-season26-challenge-damage-observer-checkpoint-audit/v1'
    auditedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    assessmentUid = $assessmentUid
    environmentCode = 'samsung_boot_micron_offline'
    deploymentReceiptSha256 = Get-Sha256Hex $deploymentPath
    sourceManifestSha256 = Get-Sha256Hex $sourceManifestPath
    serverDllSha256 = Get-Sha256Hex $serverDllPath
    baselineDatabaseSha256 = Get-Sha256Hex $databaseBeforePath
    observedDatabaseSha256 = Get-Sha256Hex $databaseObservedPath
    markerEvidenceSha256 = Get-Sha256Hex $markerPath
    damageSourceObservationCount = [int]$marker.damageSourceObservationCount
    activeRunPointerPresent = $true
    completionReceiptPresent = Test-Path -LiteralPath (
        Join-Path $runRoot 'completion.receipt.json'
    ) -PathType Leaf
    checkpointPromotionCode = 'detached_observation_checkpoint_not_golden'
    originalScoreUiDiscrepancyPreserved = $true
    rawRequestPayloadPersisted = $false
    deployableSnapshotInputsVerified = $true
}

if ($AuditOnly) {
    [ordered]@{ Audit = $auditResult } | ConvertTo-Json -Depth 20
    exit 0
}

$backupRootFull = [IO.Path]::GetFullPath($BackupRoot).TrimEnd('\')
$requiredBackupPrefix =
    [IO.Path]::GetFullPath('D:\NikkeLocalLab\Backups').TrimEnd('\') + '\'
Assert-True ($backupRootFull.StartsWith(
        $requiredBackupPrefix,
        [StringComparison]::OrdinalIgnoreCase
    )) 'phase3b2_v8_checkpoint_backup_root_invalid'

if (-not (Test-Path -LiteralPath $backupRootFull -PathType Container)) {
    New-Item -ItemType Directory -Path $backupRootFull -Force | Out-Null
}
$sealUid = [Guid]::NewGuid().ToString('D')
$sealRoot = Join-Path $backupRootFull $sealUid
$partialRoot = Join-Path $backupRootFull `
    ('.staging-' + $sealUid.Substring(0, 8))
Assert-True (
    [IO.Path]::GetFullPath($sealRoot).StartsWith(
        $backupRootFull + '\', [StringComparison]::OrdinalIgnoreCase
    ) -and
    [IO.Path]::GetFullPath($partialRoot).StartsWith(
        $backupRootFull + '\', [StringComparison]::OrdinalIgnoreCase
    ) -and
    -not (Test-Path -LiteralPath $sealRoot) -and
    -not (Test-Path -LiteralPath $partialRoot)
) 'phase3b2_v8_checkpoint_destination_invalid'
New-Item -ItemType Directory -Path $partialRoot | Out-Null

$excludedRuntimeLeaves = @(
    'db.json', 'epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal'
)
$runtimeFiles = @(Get-ChildItem -LiteralPath $runtimeRoot -File -Force |
    Where-Object { $_.Name -notin $excludedRuntimeLeaves })
$runtimeDirectories = @(Get-ChildItem -LiteralPath $runtimeRoot -Directory -Force |
    Where-Object { $_.Name -notin @('cache', 'logs') })
foreach ($directory in $runtimeDirectories) {
    $runtimeFiles += @(Get-ChildItem -LiteralPath $directory.FullName `
        -Recurse -File -Force)
}
foreach ($file in $runtimeFiles) {
    $relative = $file.FullName.Substring($runtimeRoot.Length + 1)
    Copy-VerifiedFile $file.FullName `
        (Join-Path $partialRoot ('artifacts\runtime\' + $relative))
}
Copy-VerifiedFile $databaseBeforePath `
    (Join-Path $partialRoot 'artifacts\runtime\db.json') `
    ([string]$pointer.databaseBeforeSha256)

foreach ($tool in @($deployment.installedTools)) {
    Copy-VerifiedFile (Join-Path $toolRoot ([string]$tool.leaf)) `
        (Join-Path $partialRoot ('artifacts\tools\' + $tool.leaf)) `
        ([string]$tool.sha256)
}

foreach ($path in @(
    $deploymentPath, $auditPath, $sourceManifestPath
)) {
    Copy-VerifiedFile $path (
        Join-Path $partialRoot ('evidence\deployment\' + (Split-Path -Leaf $path))
    )
}
foreach ($path in @(
    $runStartPath, $markerPath, $measurementPath, $databaseBeforePath,
    $hostsBeforePath, $pointerPath
)) {
    Copy-VerifiedFile $path (
        Join-Path $partialRoot ('evidence\run\' + (Split-Path -Leaf $path))
    )
}
Copy-VerifiedFile $databaseObservedPath `
    (Join-Path $partialRoot 'evidence\run\db.after-observed.bin')

foreach ($row in $sourceRows) {
    $relative = $row.relativePath.Replace('/', '\')
    Copy-VerifiedFile (Join-Path $externalRoot $relative) `
        (Join-Path $partialRoot ('source\.external\EpinelPS\' + $relative)) `
        $row.sha256
}
$repositorySources = @(
    'scripts\deploy-phase3b2-epinel-solo-raid-damage-source-observer-v8-offline.ps1',
    'scripts\repair-phase3b2-epinel-solo-raid-damage-source-observer-v8-completion-offline.ps1',
    'scripts\seal-phase3b2-epinel-solo-raid-damage-source-observer-v8-checkpoint-offline.ps1',
    'docs\archive\PHASE3B2_SOLO_RAID_TRIAL_PRACTICE_RECOVERY_PLAN.md',
    'docs\NEXT_STEPS.md',
    'docs\HANDOFF.md'
)
foreach ($relative in $repositorySources) {
    Copy-VerifiedFile (Join-Path $repoRoot $relative) `
        (Join-Path $partialRoot ('source\repository\' + $relative))
}

$operatorObservation = [ordered]@{
    schemaVersion = 1
    contractId =
        'nll/phase3b2-season26-challenge-damage-observer-operator-observation/v1'
    recordedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    assessmentUid = $assessmentUid
    originalClientBuild = '150.6.9'
    originalClassicSoloRaidChallengeFiveDeckCompletionObserved = $true
    blueCurrentRunScore = 16220800876L
    yellowDisplayedHighScore = 15090019690L
    yellowDisplayedRankingScore = 15090019690L
    scoreUiDiscrepancyUnresolved = $true
    battleEntryAndFiveDeckCompletionWorking = $true
    regroupSemanticsWorking = $true
    backupPromotionCode = 'operator_requested_detached_checkpoint'
}
Write-JsonUtf8NoBom `
    (Join-Path $partialRoot 'evidence\operator.observation.json') `
    $operatorObservation

$restorePlan = [ordered]@{
    schemaVersion = 1
    contractId =
        'nll/phase3b2-season26-challenge-damage-observer-restore-plan/v1'
    sealUid = $sealUid
    detachedBackupNotRuntimeBinding = $true
    checkpointIsGolden = $false
    checkpointContainsIncompleteRunEvidence = $true
    requireSamsungBootMicronOffline = $true
    runtimeOverlayRelativePath = 'artifacts/runtime'
    runtimeOverlayTarget = $runtimeRoot
    toolsOverlayRelativePath = 'artifacts/tools'
    toolsOverlayTarget = $toolRoot
    runtimeDatabaseSourceCode = 'clean_pre_run_db_before_snapshot'
    observedPostRunDatabaseEvidenceRelativePath =
        'evidence/run/db.after-observed.bin'
    recreateCacheJunction = $true
    cacheJunctionTarget = [string]$cacheLink.Target
    doNotRestoreRelativePaths = @(
        'evidence/run/active-run.pointer.json',
        'evidence/run/db.after-observed.bin',
        'evidence/run/hosts.before.bin'
    )
    doNotRestoreRoleCodes = @(
        'active_run_pointer', 'sqlite_runtime', 'runtime_logs',
        'applied_hosts', 'raw_player_log', 'raw_request_payload'
    )
    requireManualReviewBeforeRestore = $true
}
Write-JsonUtf8NoBom `
    (Join-Path $partialRoot 'metadata\restore.plan.json') `
    $restorePlan
Write-JsonUtf8NoBom `
    (Join-Path $partialRoot 'metadata\audit.receipt.json') `
    $auditResult

$manifestFiles = @(Get-ChildItem -LiteralPath $partialRoot -File -Recurse)
$manifestMembers = @($manifestFiles | ForEach-Object {
    Get-FileDescriptor -Root $partialRoot -Path $_.FullName
} | Sort-Object relativePath)
$canonical = (@($manifestMembers | ForEach-Object {
    '{0}`t{1}`t{2}`n' -f $_.relativePath, $_.byteLength, $_.sha256
}) -join '')
$algorithm = [Security.Cryptography.SHA256]::Create()
try {
    $canonicalSha256 = (($algorithm.ComputeHash(
        [Text.UTF8Encoding]::new($false).GetBytes($canonical)
    ) | ForEach-Object { $_.ToString('x2') }) -join '')
}
finally {
    $algorithm.Dispose()
}
$manifest = [ordered]@{
    schemaVersion = 1
    contractId =
        'nll/phase3b2-season26-challenge-damage-observer-checkpoint-manifest/v1'
    sealUid = $sealUid
    canonicalization = 'relative_path_tab_byte_length_tab_sha256_lf_v1'
    memberCount = $manifestMembers.Count
    canonicalSha256 = $canonicalSha256
    members = $manifestMembers
}
$manifestPath = Join-Path $partialRoot 'metadata\content.manifest.json'
Write-JsonUtf8NoBom $manifestPath $manifest
$manifestSha256 = Get-Sha256Hex $manifestPath

$receipt = [ordered]@{
    schemaVersion = 1
    contractId =
        'nll/phase3b2-season26-challenge-damage-observer-v8-checkpoint-seal/v1'
    sealedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    sealUid = $sealUid
    assessmentUid = $assessmentUid
    environmentCode = 'samsung_boot_micron_offline'
    detachedBackupNotRuntimeBinding = $true
    checkpointIsGolden = $false
    currentRunCompletionPending = $true
    existingDBackupsModified = $false
    micronGoldenModified = $false
    dGoldenModified = $false
    deploymentReceiptSha256 = Get-Sha256Hex $deploymentPath
    auditReceiptSha256 = Get-Sha256Hex $auditPath
    sourceManifestSha256 = Get-Sha256Hex $sourceManifestPath
    runStartReceiptSha256 = Get-Sha256Hex $runStartPath
    markerEvidenceSha256 = Get-Sha256Hex $markerPath
    activePointerEvidenceSha256 = Get-Sha256Hex $pointerPath
    runtimeFileCount = $runtimeFiles.Count + 1
    runtimeContentByteLength = [long](
        ($runtimeFiles | Measure-Object Length -Sum).Sum +
        (Get-Item -LiteralPath $databaseBeforePath).Length
    )
    baselineDatabaseSha256 = Get-Sha256Hex $databaseBeforePath
    observedDatabaseSha256 = Get-Sha256Hex $databaseObservedPath
    serverDllSha256 = Get-Sha256Hex $serverDllPath
    sourceFileCount = $sourceRows.Count
    toolFileCount = @($deployment.installedTools).Count
    cacheCopiedAgain = $false
    cacheJunctionTarget = [string]$cacheLink.Target
    runtimeLogsCopied = $false
    sqliteRuntimeCopied = $false
    rawPlayerLogCopied = $false
    rawRequestPayloadCopied = $false
    activeRunPointerCopiedAsEvidenceOnly = $true
    observedPostRunDatabaseCopiedAsEvidenceOnly = $true
    blueCurrentRunScore = 16220800876L
    yellowDisplayedHighScore = 15090019690L
    scoreUiDiscrepancyUnresolved = $true
    originalClassicChallengeFiveDeckCompletionObserved = $true
    regroupSemanticsWorking = $true
    contentManifestMemberCount = $manifestMembers.Count
    contentManifestByteLength = (Get-Item -LiteralPath $manifestPath).Length
    contentManifestSha256 = $manifestSha256
    contentManifestCanonicalSha256 = $canonicalSha256
    checkpointScopeCode =
        'playable_v8_code_clean_baseline_plus_incomplete_run_observation'
    nextStepCode = 'operator_discussion_without_mutating_checkpoint'
}
$receiptPath = Join-Path $partialRoot 'metadata\seal.receipt.json'
Write-JsonUtf8NoBom $receiptPath $receipt
$receiptSha256 = Get-Sha256Hex $receiptPath

Move-Item -LiteralPath $partialRoot -Destination $sealRoot
$sealedFiles = @(Get-ChildItem -LiteralPath $sealRoot -File -Recurse)
foreach ($file in $sealedFiles) {
    $file.IsReadOnly = $true
}

$sealedManifestPath = Join-Path $sealRoot 'metadata\content.manifest.json'
$sealedReceiptPath = Join-Path $sealRoot 'metadata\seal.receipt.json'
Assert-True (
    (Get-Sha256Hex $sealedManifestPath) -ceq $manifestSha256 -and
    (Get-Sha256Hex $sealedReceiptPath) -ceq $receiptSha256 -and
    @(Get-ChildItem -LiteralPath $sealRoot -File -Recurse).Count -eq
        ($manifestMembers.Count + 2)
) 'phase3b2_v8_checkpoint_post_seal_verification_failed'

[ordered]@{
    Receipt = $receipt
    BackupRoot = $sealRoot
    BackupFileCount = @(Get-ChildItem -LiteralPath $sealRoot `
        -File -Recurse).Count
    BackupContentByteLength = [long](Get-ChildItem -LiteralPath $sealRoot `
        -File -Recurse | Measure-Object Length -Sum).Sum
    ManifestPath = $sealedManifestPath
    ManifestSha256 = $manifestSha256
    ReceiptPath = $sealedReceiptPath
    ReceiptSha256 = $receiptSha256
} | ConvertTo-Json -Depth 30
