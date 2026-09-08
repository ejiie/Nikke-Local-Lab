#requires -Version 7.0

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Z]$')]
    [string]$MicronDriveLetter = 'E',
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$GoldenSealUid = '15089f3e-92f2-4833-ab1b-348d1463f9fc',
    [string]$ProtectedRoot = (
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\' +
        'Micron-PrePhysicalLane-20260823\PhysicalP2\' +
        'EpinelTutorialOnly-v1'
    )
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.
        ToLowerInvariant()
}

function Test-Digest {
    param([string]$Path, [long]$ByteLength, [string]$Sha256)
    return (Test-Path -LiteralPath $Path -PathType Leaf) -and
        (Get-Item -LiteralPath $Path).Length -eq $ByteLength -and
        (Get-Sha256Hex $Path) -ceq $Sha256
}

function Write-AtomicUtf8NoBom {
    param([string]$Path, [string]$Text)

    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporary = $Path + '.partial-' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText(
            $temporary,
            $Text,
            [Text.UTF8Encoding]::new($false)
        )
        Move-Item -LiteralPath $temporary -Destination $Path
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Get-UserShape {
    param([string]$DatabasePath)

    $database = Get-Content -LiteralPath $DatabasePath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    Assert-True (@($database.Users).Count -eq 1) `
        'phase3b2_epinel_tutorial_database_user_shape_invalid'
    $user = $database.Users[0]
    return [pscustomobject]@{
        userCount = @($database.Users).Count
        characterCount = @($user.Characters).Count
        tutorialGroupCount = @(
            $user.ClearedTutorialDataNew.PSObject.Properties
        ).Count
        contentsOpenUnlockCount = @(
            $user.ContentsOpenUnlocked.PSObject.Properties
        ).Count
        stageClearHistoryCount = @($user.StageClearHistorys).Count
        lastNormalStageCleared = [int]$user.LastNormalStageCleared
        lastStoryStageCleared = [int]$user.LastStoryStageCleared
        lastHardStageCleared = [int]$user.LastHardStageCleared
        completedScenarioCount = @($user.CompletedScenarios).Count
        mainQuestCount = @($user.MainQuestData.PSObject.Properties).Count
        fieldStateCount = @($user.FieldInfoNew.PSObject.Properties).Count
    }
}

$micronDrive = $MicronDriveLetter + ':'
$systemDisk = Get-Partition -DriveLetter C | Get-Disk
$micronDisk = Get-Partition -DriveLetter $MicronDriveLetter | Get-Disk
Assert-True (
    $env:SystemDrive -ceq 'C:' -and
    $systemDisk.FriendlyName -like 'Samsung SSD 980*' -and
    $micronDisk.FriendlyName -like 'Micron_2200*' -and
    (Test-Path -LiteralPath (
            Join-Path $micronDrive 'Windows\System32'
        ) -PathType Container)
) 'phase3b2_epinel_tutorial_wrong_disk_boundary'
$runtimeProcesses = @(Get-Process -Name @(
        'EpinelPS', 'NIKKE', 'nikke_launcher',
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
    ) -ErrorAction SilentlyContinue)
Assert-True ($runtimeProcesses.Count -eq 0) `
    'phase3b2_epinel_tutorial_runtime_not_cold'

$serverRoot = Join-Path $micronDrive (
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
)
$databasePath = Join-Path $serverRoot 'db.json'
$serverDllPath = Join-Path $serverRoot 'EpinelPS.dll'
$activePointerPath = Join-Path $micronDrive (
    'NLL\Evidence\Phase3B2\Physical\epinel-minimal-reference-v1\' +
    'active-run.pointer.json'
)
$sqlitePaths = @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal' |
    ForEach-Object { Join-Path $serverRoot $_ })
$goldenReceiptPath = Join-Path $micronDrive (
    'NLL\Evidence\Phase3B2\Physical\' +
    'epinel-lobby-golden-baseline-v1\' + $GoldenSealUid +
    '\golden-baseline.receipt.json'
)
$goldenBackupRoot = Join-Path $micronDrive (
    'NLL\Backups\Phase3B2\EpinelLobbyGoldenBaseline-v1\' +
    $GoldenSealUid
)
$staticDataPackPath = Join-Path $serverRoot (
    'cache\prdenv\150-cebfae1ecb\staticdata\data\' +
    'qa-260813-08b\553116\mpk\StaticData.pack'
)
$dotnetPath = Join-Path $micronDrive 'Program Files\dotnet\dotnet.exe'
$toolProjectRoot = Join-Path $PSScriptRoot `
    '..\tools\Phase3B2.TutorialProjection'
$toolOutputRoot = Join-Path $toolProjectRoot 'bin\Release\net10.0'
$toolDllPath = Join-Path $toolOutputRoot `
    'Phase3B2.TutorialProjection.dll'
$toolDepsPath = Join-Path $toolOutputRoot `
    'Phase3B2.TutorialProjection.deps.json'
$toolRuntimeConfigPath = Join-Path $toolOutputRoot `
    'Phase3B2.TutorialProjection.runtimeconfig.json'
$toolProgramPath = Join-Path $toolProjectRoot 'Program.cs'
$toolProjectPath = Join-Path $toolProjectRoot `
    'Phase3B2.TutorialProjection.csproj'
$toolGlobalJsonPath = Join-Path $toolProjectRoot 'global.json'
$toolEpinelAssemblyPath = Join-Path $toolOutputRoot 'EpinelPS.dll'

$expected = [ordered]@{
    goldenReceiptLength = 2596L
    goldenReceiptSha256 =
        'ebf5c2f7692e7de7ec9b8bcf3acba112cdb8efbfbb888967acde7e429e877f9c'
    databaseBeforeLength = 413327L
    databaseBeforeSha256 =
        'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194'
    databaseAfterLength = 416762L
    databaseAfterSha256 =
        'e8c6c7d299be04c91435391bd44e346ad3dd84f31697654f18b1aa8a47052330'
    serverDllLength = 15366144L
    serverDllSha256 =
        'aaa1e49d7a879a6b5ec17ad4c4094ce7d98ce86f860c1529a9ab4d6aecb51f7c'
    staticDataPackLength = 17177168L
    staticDataPackSha256 =
        '8c0dfdcaf17446d0d25ecf2c5910272b1c1fc906191e6926037a81d94ef858e3'
    tutorialRecordCount = 448
    tutorialGroupCount = 40
    tutorialGroupCanonicalSha256 =
        '70686be8a7bcbef6b343c0b2c1fb23e1ea9a204bae0fa4c11da401b3c8276d6a'
    nonTutorialCanonicalSha256 =
        '5c0c5cc8e223d15f85a55e62857ac0f26400279edf509e01a67baa7a879fc2b7'
    programLength = 9889L
    programSha256 =
        '4ee820f0e5a98e51c329bed7b09f6e6e021736ac4edf9525eaab61777b30d3c7'
    projectLength = 1140L
    projectSha256 =
        '791a3b2df0405aff772f6928e696d0105f509608ccc22fe07cf65d9084fa8b73'
    globalJsonLength = 105L
    globalJsonSha256 =
        'c39786ab1a147662bbe4db015f900165178875ec4a872ddae53bc0c90771ac34'
    toolDllLength = 34304L
    toolDllSha256 =
        '13a751201a13e11b6aa39d56489558ffdb64553b0952e11e8284615d314dfc5d'
    toolDepsLength = 59743L
    toolDepsSha256 =
        '6dd6e69fa176163711c546c6b7e7c555cc7513c2be4419312fcb7ab63e1d8786'
    toolRuntimeConfigLength = 342L
    toolRuntimeConfigSha256 =
        'c230a317a54dd960bcbeb5f347f52e18dc665a26f7efda2159fced9a5ac7e097'
}

$requiredFiles = @(
    $databasePath, $serverDllPath, $goldenReceiptPath,
    (Join-Path $goldenBackupRoot 'artifact.manifest.json'),
    (Join-Path $goldenBackupRoot 'epinel-source.bundle'),
    $staticDataPackPath, $dotnetPath, $toolDllPath, $toolDepsPath,
    $toolRuntimeConfigPath, $toolProgramPath, $toolProjectPath,
    $toolGlobalJsonPath, $toolEpinelAssemblyPath
)
Assert-True (
    @($requiredFiles | Where-Object {
            -not (Test-Path -LiteralPath $_ -PathType Leaf)
        }).Count -eq 0 -and
    -not (Test-Path -LiteralPath $activePointerPath) -and
    @($sqlitePaths | Where-Object {
            Test-Path -LiteralPath $_
        }).Count -eq 0
) 'phase3b2_epinel_tutorial_input_shape_invalid'
$pinnedDigestsValid =
    (Test-Digest -Path $goldenReceiptPath -ByteLength $expected.goldenReceiptLength -Sha256 $expected.goldenReceiptSha256) -and
    (Test-Digest -Path $databasePath -ByteLength $expected.databaseBeforeLength -Sha256 $expected.databaseBeforeSha256) -and
    (Test-Digest -Path $serverDllPath -ByteLength $expected.serverDllLength -Sha256 $expected.serverDllSha256) -and
    (Test-Digest -Path $staticDataPackPath -ByteLength $expected.staticDataPackLength -Sha256 $expected.staticDataPackSha256) -and
    (Test-Digest -Path $toolProgramPath -ByteLength $expected.programLength -Sha256 $expected.programSha256) -and
    (Test-Digest -Path $toolProjectPath -ByteLength $expected.projectLength -Sha256 $expected.projectSha256) -and
    (Test-Digest -Path $toolGlobalJsonPath -ByteLength $expected.globalJsonLength -Sha256 $expected.globalJsonSha256) -and
    (Test-Digest -Path $toolDllPath -ByteLength $expected.toolDllLength -Sha256 $expected.toolDllSha256) -and
    (Test-Digest -Path $toolDepsPath -ByteLength $expected.toolDepsLength -Sha256 $expected.toolDepsSha256) -and
    (Test-Digest -Path $toolRuntimeConfigPath -ByteLength $expected.toolRuntimeConfigLength -Sha256 $expected.toolRuntimeConfigSha256) -and
    (Test-Digest -Path $toolEpinelAssemblyPath -ByteLength $expected.serverDllLength -Sha256 $expected.serverDllSha256)
Assert-True $pinnedDigestsValid `
    'phase3b2_epinel_tutorial_pinned_digest_invalid'

$golden = Get-Content -LiteralPath $goldenReceiptPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True (
    $golden.contractId -ceq
        'nll/phase3b2-epinel-lobby-golden-baseline/v1' -and
    $golden.sealUid -ceq $GoldenSealUid -and
    $golden.lobbyReached -and
    $golden.databaseSha256 -ceq $expected.databaseBeforeSha256 -and
    $golden.serverDllSha256 -ceq $expected.serverDllSha256 -and
    $golden.clearedTutorialGroupCount -eq 0 -and
    $golden.contentsOpenUnlockCount -eq 0 -and
    $golden.stageClearHistoryCount -eq 0 -and
    -not $golden.databaseMutationPerformed -and
    -not $golden.activeCacheMutationPerformed
) 'phase3b2_epinel_tutorial_golden_contract_invalid'

$beforeShape = Get-UserShape $databasePath
Assert-True (
    $beforeShape.userCount -eq 1 -and
    $beforeShape.characterCount -eq 193 -and
    $beforeShape.tutorialGroupCount -eq 0 -and
    $beforeShape.contentsOpenUnlockCount -eq 0 -and
    $beforeShape.stageClearHistoryCount -eq 0 -and
    $beforeShape.lastNormalStageCleared -eq 0 -and
    $beforeShape.lastStoryStageCleared -eq 0 -and
    $beforeShape.lastHardStageCleared -eq 0 -and
    $beforeShape.completedScenarioCount -eq 0 -and
    $beforeShape.mainQuestCount -eq 0 -and
    $beforeShape.fieldStateCount -eq 0
) 'phase3b2_epinel_tutorial_baseline_shape_invalid'

$revisionUid = [Guid]::NewGuid().ToString('D')
$backupRoot = Join-Path $micronDrive (
    'NLL\Backups\Phase3B2\EpinelTutorialOnly-v1\' + $revisionUid
)
$evidenceRoot = Join-Path $micronDrive (
    'NLL\Evidence\Phase3B2\Physical\epinel-tutorial-only-v1\' +
    $revisionUid
)
$protectedRevisionRoot = Join-Path $ProtectedRoot $revisionUid
Assert-True (
    -not (Test-Path -LiteralPath $backupRoot) -and
    -not (Test-Path -LiteralPath $evidenceRoot) -and
    -not (Test-Path -LiteralPath $protectedRevisionRoot)
) 'phase3b2_epinel_tutorial_destination_collision'

$backupPartial = $backupRoot + '.partial-' +
    [Guid]::NewGuid().ToString('N')
$databaseApplied = $false
$databaseBeforePath = Join-Path $backupPartial 'db.before.json'
$databaseAfterPath = Join-Path $backupPartial 'db.after.json'
$privateProjectionPath = Join-Path $backupPartial `
    'tutorial.private-projection.json'
$candidatePath = Join-Path $backupPartial 'db.candidate.json'
$swapBackupPath = Join-Path $backupPartial 'db.swap-before.json'
try {
    New-Item -ItemType Directory -Path $backupPartial -Force | Out-Null
    Copy-Item -LiteralPath $databasePath -Destination $databaseBeforePath

    $projectionArguments = @(
        $toolDllPath, 'project', $staticDataPackPath, $privateProjectionPath
    )
    $projectionOutput = (& $dotnetPath @projectionArguments 2>&1 |
        Out-String).Trim()
    Assert-True ($LASTEXITCODE -eq 0) `
        'phase3b2_epinel_tutorial_projection_failed'
    $projectionSummary = $projectionOutput | ConvertFrom-Json
    Assert-True (
        $projectionSummary.contractId -ceq
            'nll/phase3b2-epinel-exact-build-tutorial-projection-summary/v1' -and
        $projectionSummary.staticDataPackByteLength -eq
            $expected.staticDataPackLength -and
        $projectionSummary.staticDataPackSha256 -ceq
            $expected.staticDataPackSha256 -and
        $projectionSummary.tutorialRecordCount -eq
            $expected.tutorialRecordCount -and
        $projectionSummary.tutorialGroupCount -eq
            $expected.tutorialGroupCount -and
        $projectionSummary.tutorialGroupCanonicalSha256 -ceq
            $expected.tutorialGroupCanonicalSha256 -and
        -not $projectionSummary.rawTutorialIdentifiersEmittedToStdout
    ) 'phase3b2_epinel_tutorial_projection_summary_invalid'

    $materializationArguments = @(
        $toolDllPath, 'apply', $privateProjectionPath, $databasePath,
        $candidatePath
    )
    $materializationOutput = (& $dotnetPath @materializationArguments 2>&1 |
        Out-String).Trim()
    Assert-True ($LASTEXITCODE -eq 0) `
        'phase3b2_epinel_tutorial_candidate_materialization_failed'
    $materializationSummary = $materializationOutput | ConvertFrom-Json
    Assert-True (
        $materializationSummary.contractId -ceq
            'nll/phase3b2-epinel-tutorial-only-db-materialization-summary/v1' -and
        $materializationSummary.databaseBeforeSha256 -ceq
            $expected.databaseBeforeSha256 -and
        $materializationSummary.databaseAfterByteLength -eq
            $expected.databaseAfterLength -and
        $materializationSummary.databaseAfterSha256 -ceq
            $expected.databaseAfterSha256 -and
        $materializationSummary.tutorialGroupCount -eq
            $expected.tutorialGroupCount -and
        $materializationSummary.tutorialGroupCanonicalSha256 -ceq
            $expected.tutorialGroupCanonicalSha256 -and
        $materializationSummary.nonTutorialCanonicalSha256 -ceq
            $expected.nonTutorialCanonicalSha256 -and
        -not $materializationSummary.nonTutorialStateChanged -and
        -not $materializationSummary.rawTutorialIdentifiersEmittedToStdout
    ) 'phase3b2_epinel_tutorial_materialization_summary_invalid'
    $candidateDigestValid = Test-Digest -Path $candidatePath `
        -ByteLength $expected.databaseAfterLength `
        -Sha256 $expected.databaseAfterSha256
    Assert-True $candidateDigestValid `
        'phase3b2_epinel_tutorial_candidate_digest_invalid'

    Remove-Item -LiteralPath $privateProjectionPath -Force
    $projectionSummaryOutputPath = Join-Path $backupPartial `
        'projection.summary.json'
    $materializationSummaryOutputPath = Join-Path $backupPartial `
        'materialization.summary.json'
    Write-AtomicUtf8NoBom $projectionSummaryOutputPath `
        ($projectionOutput + "`n")
    Write-AtomicUtf8NoBom $materializationSummaryOutputPath `
        ($materializationOutput + "`n")
    Copy-Item -LiteralPath $toolProgramPath -Destination (
        Join-Path $backupPartial 'TutorialProjection.Program.cs'
    )
    Copy-Item -LiteralPath $toolProjectPath -Destination (
        Join-Path $backupPartial 'TutorialProjection.csproj'
    )
    Copy-Item -LiteralPath $toolGlobalJsonPath -Destination (
        Join-Path $backupPartial 'TutorialProjection.global.json'
    )
    Copy-Item -LiteralPath $toolDllPath -Destination (
        Join-Path $backupPartial 'TutorialProjection.dll'
    )

    [IO.File]::Replace($candidatePath, $databasePath, $swapBackupPath)
    $databaseApplied = $true
    $atomicReplaceValid =
        (Test-Digest -Path $databasePath -ByteLength $expected.databaseAfterLength -Sha256 $expected.databaseAfterSha256) -and
        (Test-Digest -Path $swapBackupPath -ByteLength $expected.databaseBeforeLength -Sha256 $expected.databaseBeforeSha256)
    Assert-True $atomicReplaceValid `
        'phase3b2_epinel_tutorial_atomic_replace_invalid'
    Copy-Item -LiteralPath $databasePath -Destination $databaseAfterPath
    Remove-Item -LiteralPath $swapBackupPath -Force

    $afterShape = Get-UserShape $databasePath
    Assert-True (
        $afterShape.userCount -eq $beforeShape.userCount -and
        $afterShape.characterCount -eq $beforeShape.characterCount -and
        $afterShape.tutorialGroupCount -eq $expected.tutorialGroupCount -and
        $afterShape.contentsOpenUnlockCount -eq
            $beforeShape.contentsOpenUnlockCount -and
        $afterShape.stageClearHistoryCount -eq
            $beforeShape.stageClearHistoryCount -and
        $afterShape.lastNormalStageCleared -eq
            $beforeShape.lastNormalStageCleared -and
        $afterShape.lastStoryStageCleared -eq
            $beforeShape.lastStoryStageCleared -and
        $afterShape.lastHardStageCleared -eq
            $beforeShape.lastHardStageCleared -and
        $afterShape.completedScenarioCount -eq
            $beforeShape.completedScenarioCount -and
        $afterShape.mainQuestCount -eq $beforeShape.mainQuestCount -and
        $afterShape.fieldStateCount -eq $beforeShape.fieldStateCount
    ) 'phase3b2_epinel_tutorial_post_apply_shape_invalid'

    $rollback = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-epinel-tutorial-only-rollback-plan/v1'
        revisionUid = $revisionUid
        databaseBeforeRelativePath = 'db.before.json'
        databaseBeforeByteLength = $expected.databaseBeforeLength
        databaseBeforeSha256 = $expected.databaseBeforeSha256
        databaseAfterRelativePath = 'db.after.json'
        databaseAfterByteLength = $expected.databaseAfterLength
        databaseAfterSha256 = $expected.databaseAfterSha256
        requiresSamsungBoot = $true
        requiresMicronOffline = $true
        runtimeMustBeCold = $true
        cacheRollbackRequired = $false
        serverRollbackRequired = $false
        toolRollbackRequired = $false
    }
    Write-AtomicUtf8NoBom (Join-Path $backupPartial 'rollback.plan.json') (
        ($rollback | ConvertTo-Json -Depth 5) + "`n"
    )
    Move-Item -LiteralPath $backupPartial -Destination $backupRoot
}
catch {
    if ($databaseApplied -and
        (Test-Path -LiteralPath $databaseBeforePath -PathType Leaf)) {
        Copy-Item -LiteralPath $databaseBeforePath `
            -Destination $databasePath -Force
    }
    throw
}
finally {
    if (Test-Path -LiteralPath $backupPartial) {
        if (Test-Path -LiteralPath $privateProjectionPath -PathType Leaf) {
            Remove-Item -LiteralPath $privateProjectionPath -Force
        }
        Remove-Item -LiteralPath $backupPartial -Recurse -Force
    }
}

$projectionSummaryPath = Join-Path $backupRoot 'projection.summary.json'
$materializationSummaryPath = Join-Path $backupRoot `
    'materialization.summary.json'
$rollbackPlanPath = Join-Path $backupRoot 'rollback.plan.json'
$receipt = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-epinel-tutorial-only-materialization/v1'
    materializedAtUtc = [DateTimeOffset]::UtcNow.ToString(
        "yyyy-MM-dd'T'HH:mm:ss'Z'"
    )
    revisionUid = $revisionUid
    goldenSealUid = $GoldenSealUid
    goldenBaselineReceiptSha256 = $expected.goldenReceiptSha256
    staticDataPackByteLength = $expected.staticDataPackLength
    staticDataPackSha256 = $expected.staticDataPackSha256
    tutorialRecordCount = $expected.tutorialRecordCount
    tutorialGroupCountBefore = 0
    tutorialGroupCountAfter = $expected.tutorialGroupCount
    tutorialGroupCanonicalSha256 =
        $expected.tutorialGroupCanonicalSha256
    databaseBeforeByteLength = $expected.databaseBeforeLength
    databaseBeforeSha256 = $expected.databaseBeforeSha256
    databaseAfterByteLength = $expected.databaseAfterLength
    databaseAfterSha256 = $expected.databaseAfterSha256
    nonTutorialCanonicalSha256 = $expected.nonTutorialCanonicalSha256
    nonTutorialStateChanged = $false
    characterCountBefore = $beforeShape.characterCount
    characterCountAfter = $afterShape.characterCount
    contentsOpenUnlockCountBefore = $beforeShape.contentsOpenUnlockCount
    contentsOpenUnlockCountAfter = $afterShape.contentsOpenUnlockCount
    stageClearHistoryCountBefore = $beforeShape.stageClearHistoryCount
    stageClearHistoryCountAfter = $afterShape.stageClearHistoryCount
    lastNormalStageClearedBefore = $beforeShape.lastNormalStageCleared
    lastNormalStageClearedAfter = $afterShape.lastNormalStageCleared
    lastStoryStageClearedBefore = $beforeShape.lastStoryStageCleared
    lastStoryStageClearedAfter = $afterShape.lastStoryStageCleared
    lastHardStageClearedBefore = $beforeShape.lastHardStageCleared
    lastHardStageClearedAfter = $afterShape.lastHardStageCleared
    completedScenarioCountBefore = $beforeShape.completedScenarioCount
    completedScenarioCountAfter = $afterShape.completedScenarioCount
    mainQuestCountBefore = $beforeShape.mainQuestCount
    mainQuestCountAfter = $afterShape.mainQuestCount
    fieldStateCountBefore = $beforeShape.fieldStateCount
    fieldStateCountAfter = $afterShape.fieldStateCount
    projectionSummaryByteLength = [long](
        Get-Item -LiteralPath $projectionSummaryPath
    ).Length
    projectionSummarySha256 = Get-Sha256Hex $projectionSummaryPath
    materializationSummaryByteLength = [long](
        Get-Item -LiteralPath $materializationSummaryPath
    ).Length
    materializationSummarySha256 = Get-Sha256Hex $materializationSummaryPath
    toolProgramSha256 = $expected.programSha256
    toolProjectSha256 = $expected.projectSha256
    toolDllSha256 = $expected.toolDllSha256
    rollbackPlanByteLength = [long](
        Get-Item -LiteralPath $rollbackPlanPath
    ).Length
    rollbackPlanSha256 = Get-Sha256Hex $rollbackPlanPath
    privateProjectionPersisted = $false
    rawTutorialIdentifiersEmitted = $false
    cacheMutationPerformed = $false
    serverBinaryMutationPerformed = $false
    startToolMutationPerformed = $false
    existingOperatorCacheInspected = $false
    existingOperatorCacheModified = $false
    officialOutboundUsed = $false
    officialApiUsed = $false
    officialLoginUsed = $false
    officialIdentityPersisted = $false
    officialCredentialPersisted = $false
    targetOsOfflineDuringMaterialization = $true
    serverExecutionStarted = $false
    clientExecutionStarted = $false
    singleTutorialValidationRunAuthorized = $true
    validationRunConsumed = $false
    nextStepCode =
        'boot_micron_nlloperator_run_epinel_native_cache_tutorial_validation_once'
}

$micronReceiptPath = Join-Path $evidenceRoot 'materialization.receipt.json'
$protectedReceiptPath = Join-Path $protectedRevisionRoot `
    'materialization.receipt.json'
$protectedBackupRoot = Join-Path $protectedRevisionRoot 'artifacts'
New-Item -ItemType Directory -Path $evidenceRoot, $protectedRevisionRoot -Force |
    Out-Null
Write-AtomicUtf8NoBom $micronReceiptPath (
    ($receipt | ConvertTo-Json -Depth 7) + "`n"
)
Copy-Item -LiteralPath $backupRoot -Destination $protectedBackupRoot -Recurse
Copy-Item -LiteralPath $micronReceiptPath -Destination $protectedReceiptPath
Assert-True (
    (Get-Sha256Hex $micronReceiptPath) -ceq
        (Get-Sha256Hex $protectedReceiptPath) -and
    (Get-Sha256Hex (Join-Path $backupRoot 'db.before.json')) -ceq
        (Get-Sha256Hex (Join-Path $protectedBackupRoot 'db.before.json')) -and
    (Get-Sha256Hex (Join-Path $backupRoot 'db.after.json')) -ceq
        (Get-Sha256Hex (Join-Path $protectedBackupRoot 'db.after.json'))
) 'phase3b2_epinel_tutorial_protected_copy_invalid'

$micronReceiptByteLength = (
    Get-Item -LiteralPath $micronReceiptPath
).Length
[pscustomobject]@{
    Receipt = $receipt
    MicronReceiptPath = $micronReceiptPath
    MicronReceiptByteLength = $micronReceiptByteLength
    MicronReceiptSha256 = Get-Sha256Hex $micronReceiptPath
    MicronBackupRoot = $backupRoot
    SamsungProtectedReceiptPath = $protectedReceiptPath
    SamsungProtectedBackupRoot = $protectedBackupRoot
    MicronValidationCommand =
        "& 'C:\NLL\Tools\Start-Phase3B2-Epinel-NativeCache.ps1'"
} | ConvertTo-Json -Depth 8
