#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RuntimeRoot =
        'E:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64',
    [string]$ParentSealRoot =
        'D:\NikkeLocalLab\Backups\phase3b2-user-progression-parent-golden-v1\0cd733dc-118d-49f2-9973-d0fbda47ef8c',
    [string]$SourceRoot =
        'D:\NikkeLocalLab\Backups\phase3b2-user-progression-source-v1\344b4a0b-16f8-4921-a681-608818bb1e1d',
    [string]$OutputRoot =
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\EpinelUserProgressionCandidate-v2'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).
        Hash.ToLowerInvariant()
}

function Write-JsonUtf8NoBom {
    param([string]$Path, [object]$Value)
    $json = $Value | ConvertTo-Json -Depth 20
    [IO.File]::WriteAllText(
        $Path,
        $json + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false))
}

function Get-NativeJson {
    param([object[]]$Output, [string]$FailureCode)
    $text = (($Output | Out-String).Trim())
    Assert-True (-not [string]::IsNullOrWhiteSpace($text)) $FailureCode
    try { return ($text | ConvertFrom-Json) }
    catch { throw $FailureCode }
}

$runtimeRootResolved = [IO.Path]::GetFullPath($RuntimeRoot)
$parentSealRootResolved = [IO.Path]::GetFullPath($ParentSealRoot)
$sourceRootResolved = [IO.Path]::GetFullPath($SourceRoot)
$outputRootResolved = [IO.Path]::GetFullPath($OutputRoot)
$repoRoot = Split-Path -Parent $PSScriptRoot

Assert-True ($env:SystemDrive -ceq 'C:') `
    'phase3b2_progression_candidate_wrong_samsung_boot_boundary'
Assert-True ($runtimeRootResolved.StartsWith(
        'E:\NLL\EpinelPS\',
        [StringComparison]::OrdinalIgnoreCase)) `
    'phase3b2_progression_candidate_runtime_root_invalid'
Assert-True ($parentSealRootResolved.StartsWith(
        'D:\NikkeLocalLab\Backups\',
        [StringComparison]::OrdinalIgnoreCase) -and
    $sourceRootResolved.StartsWith(
        'D:\NikkeLocalLab\Backups\',
        [StringComparison]::OrdinalIgnoreCase)) `
    'phase3b2_progression_candidate_read_only_source_root_invalid'
Assert-True ($outputRootResolved.StartsWith(
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\',
        [StringComparison]::OrdinalIgnoreCase)) `
    'phase3b2_progression_candidate_output_root_invalid'
Assert-True (@(Get-Process -Name @(
            'NIKKE', 'EpinelPS',
            'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
        ) -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_progression_candidate_runtime_not_cold'

$parentReceiptPath = Join-Path $parentSealRootResolved 'seal.receipt.json'
$goldenDatabasePath = Join-Path $parentSealRootResolved 'db.json'
$sourcePath = Join-Path $sourceRootResolved 'progression.source.private.json'
$aggregatePath = Join-Path $sourceRootResolved 'aggregate.manifest.json'
$extractionReceiptPath = Join-Path $sourceRootResolved `
    'extraction.receipt.json'
$runtimeDatabasePath = Join-Path $runtimeRootResolved 'db.json'
$staticDataPackPath = Join-Path $runtimeRootResolved `
    'cache\prdenv\150-cebfae1ecb\staticdata\data\qa-260813-08b\553116\mpk\StaticData.pack'
$dotnetPath = 'E:\Program Files\dotnet\dotnet.exe'
$projectRoot = Join-Path $repoRoot `
    'tools\Phase3B2.UserProgressionCandidateV2'
$projectPath = Join-Path $projectRoot `
    'Phase3B2.UserProgressionCandidateV2.csproj'

$requiredInputs = @(
    $parentReceiptPath, $goldenDatabasePath, $sourcePath, $aggregatePath,
    $extractionReceiptPath, $runtimeDatabasePath, $staticDataPackPath,
    $dotnetPath, $projectPath
)
Assert-True (@($requiredInputs | Where-Object {
            -not (Test-Path -LiteralPath $_ -PathType Leaf)
        }).Count -eq 0) 'phase3b2_progression_candidate_input_missing'

$parentReceiptSha256Before = Get-Sha256Hex $parentReceiptPath
$goldenDatabaseSha256Before = Get-Sha256Hex $goldenDatabasePath
$sourceSha256Before = Get-Sha256Hex $sourcePath
$aggregateSha256Before = Get-Sha256Hex $aggregatePath
$extractionReceiptSha256Before = Get-Sha256Hex $extractionReceiptPath
$runtimeDatabaseSha256Before = Get-Sha256Hex $runtimeDatabasePath
$staticDataPackSha256Before = Get-Sha256Hex $staticDataPackPath

Assert-True ($parentReceiptSha256Before -ceq
        'c4d5239fedf6520fd23043e963b704831689a3cf3baf35a533bd340a8cb5c3b0' -and
    $goldenDatabaseSha256Before -ceq
        'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194' -and
    $sourceSha256Before -ceq
        'a9aedc9fababd392a44c533821c5626806d6eafec7bea43fa2dd4c2e9a1fb695' -and
    $aggregateSha256Before -ceq
        'ed7bae4ea1866e2e9135c5a20ba976d01e78d162be5b3330052ad54e2b22c9eb' -and
    $extractionReceiptSha256Before -ceq
        '7b75e0b155efb5bc0834a5d72b3a8245d2c87702ddbd36b9a09ebe2d417e7bf6' -and
    $runtimeDatabaseSha256Before -ceq $goldenDatabaseSha256Before -and
    $staticDataPackSha256Before -ceq
        '8c0dfdcaf17446d0d25ecf2c5910272b1c1fc906191e6926037a81d94ef858e3') `
    'phase3b2_progression_candidate_input_digest_invalid'

$parentReceipt = Get-Content -LiteralPath $parentReceiptPath -Raw |
    ConvertFrom-Json
$aggregate = Get-Content -LiteralPath $aggregatePath -Raw | ConvertFrom-Json
$extractionReceipt = Get-Content -LiteralPath $extractionReceiptPath -Raw |
    ConvertFrom-Json
Assert-True ($parentReceipt.contractId -ceq
        'nll/phase3b2-user-progression-parent-golden-seal/v1' -and
    [bool]$parentReceipt.runtimeCold -and
    [bool]$parentReceipt.sqliteAbsenceSealed -and
    $aggregate.contractId -ceq
        'nll/phase3b2-user-progression-source-free-aggregate/v1' -and
    [int]$aggregate.selectedTriggerRecordCount -eq 4786 -and
    [int]$aggregate.mainQuestCount -eq 595 -and
    [int]$aggregate.mainQuestRewardClaimedCount -eq 595 -and
    $extractionReceipt.contractId -ceq
        'nll/phase3b2-user-progression-source-extraction/v1' -and
    [bool]$extractionReceipt.runtimeCold -and
    -not [bool]$extractionReceipt.sqliteRuntimeCreated) `
    'phase3b2_progression_candidate_source_contract_invalid'

$sqliteMembers = @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal')
Assert-True (@($sqliteMembers | Where-Object {
            Test-Path -LiteralPath (Join-Path $runtimeRootResolved $_)
        }).Count -eq 0) `
    'phase3b2_progression_candidate_micron_sqlite_not_absent'

Push-Location $projectRoot
try {
    $sdkVersion = (& $dotnetPath --version 2>&1 | Out-String).Trim()
    Assert-True ($LASTEXITCODE -eq 0 -and $sdkVersion -ceq '10.0.400') `
        'phase3b2_progression_candidate_sdk_invalid'
    $restoreOutput = & $dotnetPath restore `
        '.\Phase3B2.UserProgressionCandidateV2.csproj' --locked-mode `
        --ignore-failed-sources 2>&1
    Assert-True ($LASTEXITCODE -eq 0) `
        'phase3b2_progression_candidate_restore_failed'
    $buildOutput = & $dotnetPath build `
        '.\Phase3B2.UserProgressionCandidateV2.csproj' -c Release `
        --no-restore 2>&1
    Assert-True ($LASTEXITCODE -eq 0) `
        'phase3b2_progression_candidate_build_failed'
}
finally {
    Pop-Location
}

$toolOutputRoot = Join-Path $projectRoot 'bin\Release\net10.0'
$toolDllPath = Join-Path $toolOutputRoot `
    'Phase3B2.UserProgressionCandidateV2.dll'
Assert-True (Test-Path -LiteralPath $toolDllPath -PathType Leaf) `
    'phase3b2_progression_candidate_tool_output_missing'

if (-not (Test-Path -LiteralPath $outputRootResolved -PathType Container)) {
    New-Item -ItemType Directory -Path $outputRootResolved | Out-Null
}
$assessmentUid = [guid]::NewGuid().ToString()
$assessmentRoot = Join-Path $outputRootResolved $assessmentUid
Assert-True (-not (Test-Path -LiteralPath $assessmentRoot)) `
    'phase3b2_progression_candidate_assessment_collision'
New-Item -ItemType Directory -Path $assessmentRoot | Out-Null

$candidateRoot = Join-Path $assessmentRoot 'candidate'
$candidateOutput = & $dotnetPath $toolDllPath build `
    $staticDataPackPath $sourcePath $goldenDatabasePath $candidateRoot 2>&1
Assert-True ($LASTEXITCODE -eq 0) `
    'phase3b2_progression_candidate_materialization_failed'
$candidateSummary = Get-NativeJson $candidateOutput `
    'phase3b2_progression_candidate_summary_invalid'
$candidateDatabasePath = Join-Path $candidateRoot 'candidate-db.json'
$projectionPath = Join-Path $candidateRoot `
    'private-static-projection.json'
$candidateSummaryPath = Join-Path $candidateRoot 'candidate.summary.json'
Assert-True ($candidateSummary.contractId -ceq
        'nll/phase3b2-user-progression-candidate-summary/v2' -and
    -not [bool]$candidateSummary.unrelatedStateChanged -and
    [bool]$candidateSummary.epinelRuntimeRoundTripVerified -and
    [int]$candidateSummary.mainQuestCount -eq 595 -and
    [int]$candidateSummary.triggerCount -eq 4786 -and
    [int]$candidateSummary.stageClearHistoryCount -eq 0 -and
    [bool]$candidateSummary.soloRaidUiStateIncluded -and
    [bool]$candidateSummary.soloRaidMuseumExcluded -and
    (Get-Sha256Hex $candidateDatabasePath) -ceq
        [string]$candidateSummary.candidateDatabaseSha256) `
    'phase3b2_progression_candidate_materialization_contract_invalid'

$verifierRoot = Join-Path $assessmentRoot 'migration-verifier'
New-Item -ItemType Directory -Path $verifierRoot | Out-Null
Copy-Item -Path (Join-Path $toolOutputRoot '*') -Destination $verifierRoot `
    -Recurse -Force
$verifierDatabasePath = Join-Path $verifierRoot 'db.json'
Copy-Item -LiteralPath $candidateDatabasePath -Destination $verifierDatabasePath
$proofSqlitePath = Join-Path $assessmentRoot 'trigger-migration-proof.db'
$migrationOutput = & $dotnetPath (Join-Path $verifierRoot `
        'Phase3B2.UserProgressionCandidateV2.dll') verify-migration `
    $sourcePath $verifierDatabasePath $proofSqlitePath 2>&1
Assert-True ($LASTEXITCODE -eq 0) `
    'phase3b2_progression_candidate_migration_proof_failed'
$migrationSummary = Get-NativeJson $migrationOutput `
    'phase3b2_progression_candidate_migration_summary_invalid'
Assert-True ($migrationSummary.contractId -ceq
        'nll/phase3b2-user-progression-trigger-migration-proof/v1' -and
    [int]$migrationSummary.triggerRowCount -eq 4786 -and
    [bool]$migrationSummary.exactEpinelDbInitializerUsed -and
    [bool]$migrationSummary.triggerPaginationSequenceContinuous -and
    $migrationSummary.sqliteIntegrityCode -ceq 'ok' -and
    $migrationSummary.sourceTriggerCanonicalSha256 -ceq
        $migrationSummary.migratedTriggerCanonicalSha256) `
    'phase3b2_progression_candidate_migration_contract_invalid'
$migrationSummaryPath = Join-Path $assessmentRoot 'migration.summary.json'
Write-JsonUtf8NoBom -Path $migrationSummaryPath -Value $migrationSummary

Assert-True ((Get-Sha256Hex $parentReceiptPath) -ceq
        $parentReceiptSha256Before -and
    (Get-Sha256Hex $goldenDatabasePath) -ceq $goldenDatabaseSha256Before -and
    (Get-Sha256Hex $sourcePath) -ceq $sourceSha256Before -and
    (Get-Sha256Hex $aggregatePath) -ceq $aggregateSha256Before -and
    (Get-Sha256Hex $extractionReceiptPath) -ceq
        $extractionReceiptSha256Before -and
    (Get-Sha256Hex $runtimeDatabasePath) -ceq
        $runtimeDatabaseSha256Before -and
    (Get-Sha256Hex $staticDataPackPath) -ceq
        $staticDataPackSha256Before -and
    @($sqliteMembers | Where-Object {
            Test-Path -LiteralPath (Join-Path $runtimeRootResolved $_)
        }).Count -eq 0 -and
    @(Get-Process -Name @(
            'NIKKE', 'EpinelPS',
            'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
        ) -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_progression_candidate_postcondition_invalid'

$receipt = [ordered]@{
    schemaVersion = 1
    contractId =
        'nll/phase3b2-user-progression-offline-candidate-staging/v2'
    stagedAtUtc = [DateTime]::UtcNow.ToString('o')
    assessmentUid = $assessmentUid
    environmentCode = 'samsung_protected_working_staging_runtime_cold'
    parentGoldenSealReceiptSha256 = $parentReceiptSha256Before
    privateSourceSha256 = $sourceSha256Before
    aggregateManifestSha256 = $aggregateSha256Before
    extractionReceiptSha256 = $extractionReceiptSha256Before
    staticDataPackSha256 = $staticDataPackSha256Before
    candidateDatabaseByteLength =
        (Get-Item -LiteralPath $candidateDatabasePath).Length
    candidateDatabaseSha256 = Get-Sha256Hex $candidateDatabasePath
    privateStaticProjectionByteLength =
        (Get-Item -LiteralPath $projectionPath).Length
    privateStaticProjectionSha256 = Get-Sha256Hex $projectionPath
    candidateSummarySha256 = Get-Sha256Hex $candidateSummaryPath
    sourceProgressStageLabels = $candidateSummary.sourceProgressStageLabels
    profileTargetMissingFromTriggerCount =
        [int]$candidateSummary.profileTargetMissingFromTriggerCount
    projectedStageCountsByMode =
        $candidateSummary.projectedStageCountsByMode
    completedMainStageCount = [int]$candidateSummary.completedMainStageCount
    fieldMapCount = [int]$candidateSummary.fieldMapCount
    completedScenarioCount = [int]$candidateSummary.completedScenarioCount
    mainQuestCount = [int]$candidateSummary.mainQuestCount
    mainQuestRewardClaimedCount = 595
    contentsOpenUiStateCount =
        [int]$candidateSummary.contentsOpenUiStateCount
    soloRaidUiStateIncluded = [bool]$candidateSummary.soloRaidUiStateIncluded
    soloRaidMuseumExcluded = [bool]$candidateSummary.soloRaidMuseumExcluded
    tutorialGroupCount = [int]$candidateSummary.tutorialGroupCount
    triggerCount = [int]$candidateSummary.triggerCount
    unresolvedCampaignClearTriggerCount =
        [int]$candidateSummary.unresolvedCampaignClearTriggerCount
    stageClearHistoryCount = 0
    sqliteProofByteLength = (Get-Item -LiteralPath $proofSqlitePath).Length
    sqliteProofSha256 = Get-Sha256Hex $proofSqlitePath
    sqliteIntegrityCode = [string]$migrationSummary.sqliteIntegrityCode
    exactEpinelDbInitializerUsed =
        [bool]$migrationSummary.exactEpinelDbInitializerUsed
    triggerPaginationSequenceContinuous =
        [bool]$migrationSummary.triggerPaginationSequenceContinuous
    unrelatedStateChanged = $false
    runtimeDatabaseModified = $false
    micronSqliteCreated = $false
    wrapperModified = $false
    wrapperBindingPerformed = $false
    innerStartModified = $false
    completionToolModified = $false
    serverBinaryModified = $false
    cacheModified = $false
    hostsModified = $false
    localLowInspected = $false
    localLowModified = $false
    dDriveWritePerformed = $false
    dDriveBackupCreated = $false
    officialOutboundUsed = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
    nextStepCode =
        'review_then_data_only_apply_to_micron_without_tool_binding'
}
$receiptPath = Join-Path $assessmentRoot 'staging.receipt.json'
Write-JsonUtf8NoBom -Path $receiptPath -Value $receipt

$pointer = [ordered]@{
    schemaVersion = 1
    contractId =
        'nll/phase3b2-user-progression-offline-candidate-pointer/v2'
    assessmentUid = $assessmentUid
    receiptPath = $receiptPath
    receiptSha256 = Get-Sha256Hex $receiptPath
    candidateDatabasePath = $candidateDatabasePath
    candidateDatabaseSha256 = [string]$receipt.candidateDatabaseSha256
    nextStepCode = [string]$receipt.nextStepCode
}
$pointerPath = Join-Path $outputRootResolved 'latest-candidate.pointer.json'
Write-JsonUtf8NoBom -Path $pointerPath -Value $pointer

[ordered]@{
    Receipt = $receipt
    ReceiptPath = $receiptPath
    ReceiptByteLength = (Get-Item -LiteralPath $receiptPath).Length
    ReceiptSha256 = Get-Sha256Hex $receiptPath
    PointerPath = $pointerPath
    PointerSha256 = Get-Sha256Hex $pointerPath
} | ConvertTo-Json -Depth 20
