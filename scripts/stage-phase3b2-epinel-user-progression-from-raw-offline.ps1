#requires -Version 5.1

param(
    [string]$RawSourcePath = (Join-Path $env:USERPROFILE `
        'Downloads\nikke_full_scroll_result.json'),
    [string]$MicronDrive = 'E:',
    [string]$ProtectedRoot =
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\EpinelUserProgression-v1',
    [switch]$ValidationOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
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

function Get-NativeJson {
    param([object[]]$Output, [string]$FailureCode)
    $text = (($Output | Out-String).Trim())
    Assert-True (-not [string]::IsNullOrWhiteSpace($text)) $FailureCode
    try { return ($text | ConvertFrom-Json) }
    catch { throw $FailureCode }
}

$expectedRawSourceByteLength = 964036L
$expectedRawSourceSha256 =
    'efb1b38b4557e45cbefc1922649c22f6725071cb8c5cb2ad269650d7807fe605'
$expectedFinalizationReceiptSha256 =
    '6d4c9fadd0c500cca3a95f3c2eeae7a141eacacc073167874c1eff2989d4a4e3'
$expectedGoldenDatabaseSha256 =
    'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194'
$expectedGoldenWrapperSha256 =
    'fe667ba466ea27a5bfd55e09c4d0cd9ef94b04d434d95ac1590ccd7f813e493b'
$expectedGoldenInnerStartSha256 =
    'a039cd5186df92c16c0091f7d4b4c4bbb907d0bf2adc3ff94d8d425699bc5f69'
$expectedGoldenInnerCompletionSha256 =
    '0ff9cc8285b46fe96d16fe1fe1aca532a6a2b39d89cc9a15f6c611444d63fe09'
$expectedGoldenCompletionWrapperSha256 =
    '16aa339bc83336b6bd3c72da21624eb890e336e22fb1c9672160fa745b0250c1'
$expectedServerDllSha256 =
    'aaa1e49d7a879a6b5ec17ad4c4094ce7d98ce86f860c1529a9ab4d6aecb51f7c'
$expectedStaticDataPackSha256 =
    '8c0dfdcaf17446d0d25ecf2c5910272b1c1fc906191e6926037a81d94ef858e3'
$expectedStaticDataPackByteLength = 17177168L

$repoRoot = Split-Path -Parent $PSScriptRoot
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if ($ValidationOnly) {
    $validationRoot = [IO.Path]::GetFullPath($ProtectedRoot)
    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    Assert-True ($validationRoot.StartsWith(
            $temporaryRoot, [StringComparison]::OrdinalIgnoreCase
        )) 'phase3b2_user_progression_stage_validation_root_invalid'
}
else {
    Assert-True ($principal.IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator
        )) 'phase3b2_user_progression_stage_requires_administrator'
}
Assert-True ($env:SystemDrive -ceq 'C:') `
    'phase3b2_user_progression_stage_wrong_samsung_boot_boundary'
$micronRoot = $MicronDrive.TrimEnd('\')
$micronBoundaryMarker = $(if ($ValidationOnly) {
        Join-Path $micronRoot 'NLL\Tools\Start-Phase3B2-Epinel-NativeCache.ps1'
    } else {
        Join-Path $micronRoot 'Windows\System32\config\SYSTEM'
    })
Assert-True (
    $micronRoot -match '^[A-Za-z]:$' -and
    $micronRoot -cne $env:SystemDrive -and
    (Test-Path -LiteralPath $micronBoundaryMarker -PathType Leaf)
) 'phase3b2_user_progression_stage_wrong_micron_disk_boundary'
Assert-True (@(Get-Process -Name @(
            'nikke', 'EpinelPS',
            'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
        ) -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_user_progression_stage_runtime_not_cold'

$projectPath = Join-Path $repoRoot `
    'tools\Phase3B2.UserProgressionProjection\Phase3B2.UserProgressionProjection.csproj'
$dotnetPath = Join-Path $micronRoot 'Program Files\dotnet\dotnet.exe'
$runtimeRoot = Join-Path $micronRoot `
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
$databasePath = Join-Path $runtimeRoot 'db.json'
$serverDllPath = Join-Path $runtimeRoot 'EpinelPS.dll'
$staticDataPackPath = Join-Path $runtimeRoot `
    'cache\prdenv\150-cebfae1ecb\staticdata\data\qa-260813-08b\553116\mpk\StaticData.pack'
$outerWrapperPath = Join-Path $micronRoot `
    'NLL\Tools\Start-Phase3B2-Epinel-NativeCache.ps1'
$innerStartPath = Join-Path $micronRoot `
    'NLL\Tools\start-phase3b2-epinel-minimal-reference-in-micron.ps1'
$completionWrapperPath = Join-Path $micronRoot `
    'NLL\Tools\Complete-Phase3B2-Epinel-Minimal.ps1'
$innerCompletionPath = Join-Path $micronRoot `
    'NLL\Tools\complete-phase3b2-epinel-minimal-reference-in-micron.ps1'
$finalizationReceiptPath = Join-Path $micronRoot `
    'NLL\Evidence\Phase3B2\Physical\epinel-lobby-golden-restore-v1\b8476bb3-b212-476c-81e2-0d9c56a92399\finalization.receipt.json'

$required = @(
    $RawSourcePath, $projectPath, $dotnetPath, $databasePath, $serverDllPath,
    $staticDataPackPath, $outerWrapperPath, $innerStartPath,
    $completionWrapperPath, $innerCompletionPath, $finalizationReceiptPath
)
Assert-True (@($required | Where-Object {
            -not (Test-Path -LiteralPath $_ -PathType Leaf)
        }).Count -eq 0) 'phase3b2_user_progression_stage_input_missing'
Assert-True (
    (Get-Item -LiteralPath $RawSourcePath).Length -eq
        $expectedRawSourceByteLength -and
    (Get-Sha256Hex $RawSourcePath) -ceq $expectedRawSourceSha256 -and
    (Get-Sha256Hex $finalizationReceiptPath) -ceq
        $expectedFinalizationReceiptSha256 -and
    (Get-Sha256Hex $databasePath) -ceq $expectedGoldenDatabaseSha256 -and
    (Get-Sha256Hex $outerWrapperPath) -ceq $expectedGoldenWrapperSha256 -and
    (Get-Sha256Hex $innerStartPath) -ceq $expectedGoldenInnerStartSha256 -and
    (Get-Sha256Hex $completionWrapperPath) -ceq
        $expectedGoldenCompletionWrapperSha256 -and
    (Get-Sha256Hex $innerCompletionPath) -ceq
        $expectedGoldenInnerCompletionSha256 -and
    (Get-Sha256Hex $serverDllPath) -ceq $expectedServerDllSha256 -and
    (Get-Item -LiteralPath $staticDataPackPath).Length -eq
        $expectedStaticDataPackByteLength -and
    (Get-Sha256Hex $staticDataPackPath) -ceq
        $expectedStaticDataPackSha256
) 'phase3b2_user_progression_stage_golden_input_drifted'

$finalization = Get-Content -LiteralPath $finalizationReceiptPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
Assert-True (
    $finalization.contractId -ceq
        'nll/phase3b2-epinel-lobby-golden-restore-finalization/v1' -and
    $finalization.restoreUid -ceq
        'b8476bb3-b212-476c-81e2-0d9c56a92399' -and
    $finalization.databaseSha256 -ceq $expectedGoldenDatabaseSha256 -and
    $finalization.outerWrapperSha256 -ceq $expectedGoldenWrapperSha256 -and
    $finalization.innerStartSha256 -ceq $expectedGoldenInnerStartSha256 -and
    $finalization.goldenBaselineActive -and
    -not $finalization.tutorialRevisionActive -and
    -not $finalization.activeRunPointerPresent -and
    [int]$finalization.sqliteRuntimeMemberCount -eq 0 -and
    -not $finalization.serverExecutionStarted -and
    -not $finalization.clientExecutionStarted
) 'phase3b2_user_progression_stage_finalization_contract_invalid'

$projectRoot = Split-Path -Parent $projectPath
Push-Location $projectRoot
try {
    $selectedSdk = (& $dotnetPath --version 2>&1 | Out-String).Trim()
    Assert-True ($LASTEXITCODE -eq 0 -and $selectedSdk -ceq '10.0.400') `
        'phase3b2_user_progression_stage_sdk_version_invalid'
    $restoreOutput = & $dotnetPath restore `
        '.\Phase3B2.UserProgressionProjection.csproj' --locked-mode `
        --ignore-failed-sources 2>&1
    Assert-True ($LASTEXITCODE -eq 0) `
        'phase3b2_user_progression_stage_tool_restore_failed'
    $buildOutput = & $dotnetPath build `
        '.\Phase3B2.UserProgressionProjection.csproj' -c Release `
        --no-restore 2>&1
    Assert-True ($LASTEXITCODE -eq 0) `
        'phase3b2_user_progression_stage_tool_build_failed'
}
finally {
    Pop-Location
}
$toolDllPath = Join-Path $projectRoot `
    'bin\Release\net10.0\Phase3B2.UserProgressionProjection.dll'
Assert-True (Test-Path -LiteralPath $toolDllPath -PathType Leaf) `
    'phase3b2_user_progression_stage_tool_output_missing'

$assessmentUid = [Guid]::NewGuid().ToString()
$assessmentRoot = Join-Path $ProtectedRoot $assessmentUid
Assert-True (-not (Test-Path -LiteralPath $assessmentRoot)) `
    'phase3b2_user_progression_stage_assessment_collision'
New-Item -ItemType Directory -Path $assessmentRoot -Force | Out-Null
$privateProjectionPath = Join-Path $assessmentRoot `
    'private-static-projection.json'
$candidateDatabasePath = Join-Path $assessmentRoot 'candidate-db.json'
$inspectionSummaryPath = Join-Path $assessmentRoot `
    'static-inspection.summary.json'
$materializationSummaryPath = Join-Path $assessmentRoot `
    'materialization.summary.json'
$receiptPath = Join-Path $assessmentRoot 'staging.receipt.json'
$pointerPath = Join-Path $ProtectedRoot 'latest-staging.pointer.json'

try {
    $inspectionOutput = & $dotnetPath $toolDllPath inspect `
        $staticDataPackPath $privateProjectionPath 2>&1
    Assert-True ($LASTEXITCODE -eq 0) `
        'phase3b2_user_progression_stage_static_inspection_failed'
    $inspection = Get-NativeJson $inspectionOutput `
        'phase3b2_user_progression_stage_static_inspection_invalid'
    Assert-True (
        $inspection.contractId -ceq
            'nll/phase3b2-epinel-user-progression-projection-summary/v1' -and
        $inspection.staticDataPackSha256 -ceq
            $expectedStaticDataPackSha256 -and
        @($inspection.soloRaidOpenStageLabels).Count -eq 1 -and
        [string]$inspection.soloRaidOpenStageLabels[0] -ceq '6-4' -and
        [int]$inspection.campaignMainStageCount -eq 4007 -and
        [int]$inspection.tutorialGroupCount -eq 40 -and
        $inspection.soloRaidMuseumExcluded -and
        -not $inspection.rawOriginalIdentifiersEmittedToStdout
    ) 'phase3b2_user_progression_stage_static_contract_invalid'
    Write-AtomicUtf8NoBom $inspectionSummaryPath `
        (($inspection | ConvertTo-Json -Depth 8) + "`n")

    $materializationOutput = & $dotnetPath $toolDllPath materialize `
        $privateProjectionPath $RawSourcePath $databasePath `
        $candidateDatabasePath 2>&1
    Assert-True ($LASTEXITCODE -eq 0) `
        'phase3b2_user_progression_stage_materialization_failed'
    $materialization = Get-NativeJson $materializationOutput `
        'phase3b2_user_progression_stage_materialization_invalid'
    $resolved = @($materialization.resolvedProgress)
    $normal = @($resolved | Where-Object { $_.mode -ceq 'Normal' })
    $hard = @($resolved | Where-Object { $_.mode -ceq 'Hard' })
    $story = @($resolved | Where-Object { $_.mode -ceq 'Story' })
    Assert-True (
        $materialization.contractId -ceq
            'nll/phase3b2-epinel-user-progression-candidate-materialization-summary/v1' -and
        $materialization.sourceSha256 -ceq $expectedRawSourceSha256 -and
        $materialization.databaseBeforeSha256 -ceq
            $expectedGoldenDatabaseSha256 -and
        $normal.Count -eq 1 -and $normal[0].stageLabel -ceq '48-44' -and
        $hard.Count -eq 1 -and $hard[0].stageLabel -ceq '48-44' -and
        $story.Count -eq 1 -and $story[0].stageLabel -ceq '48-6' -and
        [int]$materialization.completedMainStageCounts.Normal -eq 1787 -and
        [int]$materialization.completedMainStageCounts.Hard -eq 1787 -and
        [int]$materialization.completedMainStageCounts.Story -eq 433 -and
        [int]$materialization.fieldMapCount -eq 147 -and
        [int]$materialization.tutorialGroupCount -eq 40 -and
        $materialization.epinelRuntimeRoundTripVerified -and
        -not $materialization.stageClearHistoryFabricated -and
        -not $materialization.scenarioStateFabricated -and
        -not $materialization.questStateFabricated -and
        -not $materialization.rewardStateFabricated -and
        -not $materialization.unrelatedStateChanged -and
        -not $materialization.rawOriginalIdentifiersEmittedToStdout -and
        (Get-Sha256Hex $candidateDatabasePath) -ceq
            [string]$materialization.candidateDatabaseSha256
    ) 'phase3b2_user_progression_stage_candidate_contract_invalid'
    Write-AtomicUtf8NoBom $materializationSummaryPath `
        (($materialization | ConvertTo-Json -Depth 8) + "`n")

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-user-progression-offline-staging/v1'
        stagedAtUtc = [DateTimeOffset]::UtcNow.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'"
        )
        assessmentUid = $assessmentUid
        stagingPurposeCode = $(if ($ValidationOnly) {
                'generation_validation_only'
            } else { 'offline_micron_application' })
        deployable = -not [bool]$ValidationOnly
        sourceRoleCode =
            'operator_supplied_profile_capture_progress_fields_only'
        sourceByteLength = $expectedRawSourceByteLength
        sourceSha256 = $expectedRawSourceSha256
        credentialOrSessionFieldExtracted = $false
        credentialOrSessionFieldPersisted = $false
        rawSourceCopied = $false
        rawOriginalIdentifierEmitted = $false
        goldenRestoreFinalizationReceiptSha256 =
            $expectedFinalizationReceiptSha256
        goldenDatabaseSha256 = $expectedGoldenDatabaseSha256
        goldenOuterWrapperSha256 = $expectedGoldenWrapperSha256
        goldenInnerStartSha256 = $expectedGoldenInnerStartSha256
        goldenInnerCompletionSha256 =
            $expectedGoldenInnerCompletionSha256
        goldenCompletionWrapperSha256 =
            $expectedGoldenCompletionWrapperSha256
        serverDllSha256 = $expectedServerDllSha256
        staticDataPackByteLength = $expectedStaticDataPackByteLength
        staticDataPackSha256 = $expectedStaticDataPackSha256
        staticProjectionSha256 = Get-Sha256Hex $privateProjectionPath
        staticProjectionPersistedOnlyInProtectedEvidence = $true
        soloRaidUnlockStageLabel = '6-4'
        soloRaidMuseumExcluded = $true
        userProgressNormalStageLabel = '48-44'
        userProgressHardStageLabel = '48-44'
        userProgressStoryStageLabel = '48-6'
        completedNormalMainStageCount = 1787
        completedHardMainStageCount = 1787
        completedStoryMainStageCount = 433
        fieldMapCount = 147
        tutorialCompletionSourceCode =
            'local_synthetic_terminal_groups_from_exact_client_table'
        tutorialGroupCount = 40
        candidateDatabaseByteLength =
            (Get-Item -LiteralPath $candidateDatabasePath).Length
        candidateDatabaseSha256 = Get-Sha256Hex $candidateDatabasePath
        epinelRuntimeRoundTripVerified = $true
        stageClearHistoryFabricated = $false
        scenarioStateFabricated = $false
        questStateFabricated = $false
        rewardStateFabricated = $false
        unrelatedStateChanged = $false
        unrelatedStateCanonicalSha256 =
            [string]$materialization.unrelatedStateCanonicalSha256
        goldenDatabaseModified = $false
        micronMutationPerformed = $false
        existingOperatorCacheInspected = $false
        existingOperatorCacheModified = $false
        officialOutboundUsed = $false
        officialIdentityPersisted = $false
        officialCredentialPersisted = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        nextStepCode =
            $(if ($ValidationOnly) {
                    'discard_validation_staging_after_generation_test'
                } else {
                    'review_then_apply_golden_parent_user_progression_offline'
                })
    }
    Write-AtomicUtf8NoBom $receiptPath `
        (($receipt | ConvertTo-Json -Depth 8) + "`n")
    $receiptSha256 = Get-Sha256Hex $receiptPath
    $pointer = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-user-progression-staging-pointer/v1'
        assessmentUid = $assessmentUid
        protectedAssessmentRoot = $assessmentRoot
        stagingReceiptPath = $receiptPath
        stagingReceiptSha256 = $receiptSha256
        candidateDatabasePath = $candidateDatabasePath
        candidateDatabaseSha256 = [string]$receipt.candidateDatabaseSha256
        consumed = $false
    }
    New-Item -ItemType Directory -Path $ProtectedRoot -Force | Out-Null
    Write-AtomicUtf8NoBom $pointerPath `
        (($pointer | ConvertTo-Json -Depth 6) + "`n")

    [pscustomobject]@{
        Receipt = $receipt
        ReceiptPath = $receiptPath
        ReceiptByteLength = (Get-Item -LiteralPath $receiptPath).Length
        ReceiptSha256 = $receiptSha256
        ApplyCommand =
            "& '$repoRoot\scripts\apply-phase3b2-epinel-user-progression-offline.ps1'"
    } | ConvertTo-Json -Depth 9
}
catch {
    if (Test-Path -LiteralPath $assessmentRoot -PathType Container) {
        $failedPath = Join-Path $assessmentRoot 'staging.failure.txt'
        if (-not (Test-Path -LiteralPath $failedPath)) {
            Write-AtomicUtf8NoBom $failedPath ([string]$_.Exception.Message + "`n")
        }
    }
    throw
}
