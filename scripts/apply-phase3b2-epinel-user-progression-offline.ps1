#requires -Version 5.1

param(
    [string]$MicronDrive = 'E:',
    [string]$ProtectedRoot =
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\EpinelUserProgression-v1',
    [switch]$GenerateOnly
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

function Copy-Atomic {
    param([string]$Source, [string]$Destination)
    $temporary = $Destination + '.partial-' + [Guid]::NewGuid().ToString('N')
    try {
        Copy-Item -LiteralPath $Source -Destination $temporary
        Move-Item -LiteralPath $temporary -Destination $Destination -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Replace-ExactOne {
    param(
        [string]$Text,
        [string]$OldValue,
        [string]$NewValue,
        [string]$FailureCode
    )
    $count = ([regex]::Matches(
            $Text, [regex]::Escape($OldValue)
        )).Count
    Assert-True ($count -eq 1) $FailureCode
    return $Text.Replace($OldValue, $NewValue)
}

function Replace-RegexExactOne {
    param(
        [string]$Text,
        [string]$Pattern,
        [string]$Replacement,
        [string]$FailureCode
    )
    $matches = [regex]::Matches($Text, $Pattern)
    Assert-True ($matches.Count -eq 1) $FailureCode
    return [regex]::Replace($Text, $Pattern, $Replacement)
}

function Assert-PowerShellSyntax {
    param([string]$Path, [string]$FailureCode)
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile(
        $Path, [ref]$tokens, [ref]$errors
    ) | Out-Null
    Assert-True (@($errors).Count -eq 0) $FailureCode
}

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
$expectedSourceSha256 =
    'efb1b38b4557e45cbefc1922649c22f6725071cb8c5cb2ad269650d7807fe605'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if ($GenerateOnly) {
    $generationRoot = [IO.Path]::GetFullPath($ProtectedRoot)
    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    Assert-True ($generationRoot.StartsWith(
            $temporaryRoot, [StringComparison]::OrdinalIgnoreCase
        )) 'phase3b2_user_progression_apply_generation_root_invalid'
}
else {
    Assert-True ($principal.IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator
        )) 'phase3b2_user_progression_apply_requires_administrator'
}
Assert-True ($env:SystemDrive -ceq 'C:') `
    'phase3b2_user_progression_apply_wrong_samsung_boot_boundary'
$micronRoot = $MicronDrive.TrimEnd('\')
$micronBoundaryMarker = $(if ($GenerateOnly) {
        Join-Path $micronRoot 'NLL\Tools\Start-Phase3B2-Epinel-NativeCache.ps1'
    } else {
        Join-Path $micronRoot 'Windows\System32\config\SYSTEM'
    })
Assert-True (
    $micronRoot -match '^[A-Za-z]:$' -and
    $micronRoot -cne $env:SystemDrive -and
    (Test-Path -LiteralPath $micronBoundaryMarker -PathType Leaf)
) 'phase3b2_user_progression_apply_wrong_micron_disk_boundary'
Assert-True (@(Get-Process -Name @(
            'nikke', 'EpinelPS',
            'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
        ) -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_user_progression_apply_runtime_not_cold'

$stagingPointerPath = Join-Path $ProtectedRoot `
    'latest-staging.pointer.json'
Assert-True (Test-Path -LiteralPath $stagingPointerPath -PathType Leaf) `
    'phase3b2_user_progression_apply_staging_pointer_missing'
$stagingPointer = Get-Content -LiteralPath $stagingPointerPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
$stagingPointerOriginalJson =
    (($stagingPointer | ConvertTo-Json -Depth 6) + "`n")
$stagingReceiptPath = [string]$stagingPointer.stagingReceiptPath
$candidateDatabasePath = [string]$stagingPointer.candidateDatabasePath
Assert-True (
    $stagingPointer.contractId -ceq
        'nll/phase3b2-epinel-user-progression-staging-pointer/v1' -and
    [Guid]::Parse([string]$stagingPointer.assessmentUid) -ne [Guid]::Empty -and
    -not $stagingPointer.consumed -and
    (Test-Path -LiteralPath $stagingReceiptPath -PathType Leaf) -and
    (Test-Path -LiteralPath $candidateDatabasePath -PathType Leaf) -and
    (Get-Sha256Hex $stagingReceiptPath) -ceq
        [string]$stagingPointer.stagingReceiptSha256 -and
    (Get-Sha256Hex $candidateDatabasePath) -ceq
        [string]$stagingPointer.candidateDatabaseSha256
) 'phase3b2_user_progression_apply_staging_pointer_invalid'
$staging = Get-Content -LiteralPath $stagingReceiptPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
Assert-True (
    $staging.contractId -ceq
        'nll/phase3b2-epinel-user-progression-offline-staging/v1' -and
    $staging.assessmentUid -ceq [string]$stagingPointer.assessmentUid -and
    $staging.sourceSha256 -ceq $expectedSourceSha256 -and
    $staging.goldenRestoreFinalizationReceiptSha256 -ceq
        $expectedFinalizationReceiptSha256 -and
    $staging.goldenDatabaseSha256 -ceq $expectedGoldenDatabaseSha256 -and
    $staging.goldenOuterWrapperSha256 -ceq $expectedGoldenWrapperSha256 -and
    $staging.goldenInnerStartSha256 -ceq
        $expectedGoldenInnerStartSha256 -and
    $staging.goldenInnerCompletionSha256 -ceq
        $expectedGoldenInnerCompletionSha256 -and
    $staging.goldenCompletionWrapperSha256 -ceq
        $expectedGoldenCompletionWrapperSha256 -and
    $staging.serverDllSha256 -ceq $expectedServerDllSha256 -and
    ($staging.deployable -or $GenerateOnly) -and
    $staging.userProgressNormalStageLabel -ceq '48-44' -and
    $staging.userProgressHardStageLabel -ceq '48-44' -and
    $staging.userProgressStoryStageLabel -ceq '48-6' -and
    $staging.soloRaidUnlockStageLabel -ceq '6-4' -and
    [int]$staging.tutorialGroupCount -eq 40 -and
    $staging.epinelRuntimeRoundTripVerified -and
    -not $staging.stageClearHistoryFabricated -and
    -not $staging.scenarioStateFabricated -and
    -not $staging.questStateFabricated -and
    -not $staging.rewardStateFabricated -and
    -not $staging.goldenDatabaseModified -and
    -not $staging.micronMutationPerformed
) 'phase3b2_user_progression_apply_staging_contract_invalid'

$runtimeRoot = Join-Path $micronRoot `
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
$databasePath = Join-Path $runtimeRoot 'db.json'
$serverDllPath = Join-Path $runtimeRoot 'EpinelPS.dll'
$toolRoot = Join-Path $micronRoot 'NLL\Tools'
$goldenWrapperPath = Join-Path $toolRoot `
    'Start-Phase3B2-Epinel-NativeCache.ps1'
$goldenInnerStartPath = Join-Path $toolRoot `
    'start-phase3b2-epinel-minimal-reference-in-micron.ps1'
$goldenCompletionWrapperPath = Join-Path $toolRoot `
    'Complete-Phase3B2-Epinel-Minimal.ps1'
$goldenInnerCompletionPath = Join-Path $toolRoot `
    'complete-phase3b2-epinel-minimal-reference-in-micron.ps1'
$derivedWrapperPath = Join-Path $toolRoot `
    'Start-Phase3B2-Epinel-UserProgression.ps1'
$derivedInnerStartPath = Join-Path $toolRoot `
    'start-phase3b2-epinel-user-progression-in-micron.ps1'
$derivedCompletionWrapperPath = Join-Path $toolRoot `
    'Complete-Phase3B2-Epinel-UserProgression.ps1'
$derivedInnerCompletionPath = Join-Path $toolRoot `
    'complete-phase3b2-epinel-user-progression-in-micron.ps1'
$finalizationReceiptPath = Join-Path $micronRoot `
    'NLL\Evidence\Phase3B2\Physical\epinel-lobby-golden-restore-v1\b8476bb3-b212-476c-81e2-0d9c56a92399\finalization.receipt.json'
$activeEvidenceRoot = Join-Path $micronRoot `
    'NLL\Evidence\Phase3B2\Physical\epinel-user-progression-active-v1'
$activeStagingReceiptPath = Join-Path $activeEvidenceRoot `
    'staging.receipt.json'
$applicationReceiptPath = Join-Path $activeEvidenceRoot `
    'application.receipt.json'
$goldenActivePointerPath = Join-Path $micronRoot `
    'NLL\Evidence\Phase3B2\Physical\epinel-minimal-reference-v1\active-run.pointer.json'
$progressionActivePointerPath = Join-Path $micronRoot `
    'NLL\Evidence\Phase3B2\Physical\epinel-user-progression-reference-v1\active-run.pointer.json'
$derivedToolPaths = @(
    $derivedWrapperPath, $derivedInnerStartPath,
    $derivedCompletionWrapperPath, $derivedInnerCompletionPath
)

$requiredGolden = @(
    $databasePath, $serverDllPath, $goldenWrapperPath,
    $goldenInnerStartPath, $goldenCompletionWrapperPath,
    $goldenInnerCompletionPath, $finalizationReceiptPath
)
Assert-True (@($requiredGolden | Where-Object {
            -not (Test-Path -LiteralPath $_ -PathType Leaf)
        }).Count -eq 0 -and
    (Get-Sha256Hex $databasePath) -ceq $expectedGoldenDatabaseSha256 -and
    (Get-Sha256Hex $serverDllPath) -ceq $expectedServerDllSha256 -and
    (Get-Sha256Hex $goldenWrapperPath) -ceq $expectedGoldenWrapperSha256 -and
    (Get-Sha256Hex $goldenInnerStartPath) -ceq
        $expectedGoldenInnerStartSha256 -and
    (Get-Sha256Hex $goldenCompletionWrapperPath) -ceq
        $expectedGoldenCompletionWrapperSha256 -and
    (Get-Sha256Hex $goldenInnerCompletionPath) -ceq
        $expectedGoldenInnerCompletionSha256 -and
    (Get-Sha256Hex $finalizationReceiptPath) -ceq
        $expectedFinalizationReceiptSha256 -and
    -not (Test-Path -LiteralPath $goldenActivePointerPath) -and
    -not (Test-Path -LiteralPath $progressionActivePointerPath) -and
    -not (Test-Path -LiteralPath $activeEvidenceRoot) -and
    @($derivedToolPaths | Where-Object {
            Test-Path -LiteralPath $_
        }).Count -eq 0
) 'phase3b2_user_progression_apply_golden_boundary_invalid'

$applicationUid = [Guid]::NewGuid().ToString()
$applicationRoot = Join-Path $ProtectedRoot ('a-' + $applicationUid)
$candidateToolRoot = Join-Path $applicationRoot 't'
$backupRoot = Join-Path $applicationRoot 'b'
Assert-True (-not (Test-Path -LiteralPath $applicationRoot)) `
    'phase3b2_user_progression_apply_application_collision'
New-Item -ItemType Directory -Path $candidateToolRoot -Force | Out-Null
New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
Copy-Item -LiteralPath $databasePath -Destination `
    (Join-Path $backupRoot 'g.json')
Copy-Item -LiteralPath $stagingReceiptPath -Destination `
    (Join-Path $applicationRoot 's.json')
Assert-True ((Get-Sha256Hex (Join-Path $backupRoot `
            'g.json')) -ceq $expectedGoldenDatabaseSha256) `
    'phase3b2_user_progression_apply_backup_invalid'

$candidateHash = [string]$staging.candidateDatabaseSha256
$stagingReceiptHash = Get-Sha256Hex $stagingReceiptPath
$newEvidenceRoot =
    'C:\NLL\Evidence\Phase3B2\Physical\epinel-user-progression-reference-v1'
$newBootstrapLane = 'p2-client-start-v2'
$newInnerStartClientPath =
    'C:\NLL\Tools\start-phase3b2-epinel-user-progression-in-micron.ps1'
$newInnerCompletionClientPath =
    'C:\NLL\Tools\complete-phase3b2-epinel-user-progression-in-micron.ps1'
$newCompletionWrapperClientPath =
    'C:\NLL\Tools\Complete-Phase3B2-Epinel-UserProgression.ps1'
$activeStagingReceiptClientPath =
    'C:\NLL\Evidence\Phase3B2\Physical\epinel-user-progression-active-v1\staging.receipt.json'
$databaseClientPath =
    'C:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\db.json'

$candidateInnerStartPath = Join-Path $candidateToolRoot `
    'si.ps1'
$candidateInnerCompletionPath = Join-Path $candidateToolRoot `
    'ci.ps1'
$candidateCompletionWrapperPath = Join-Path $candidateToolRoot `
    'cw.ps1'
$candidateWrapperPath = Join-Path $candidateToolRoot `
    'sw.ps1'

$innerStartText = [IO.File]::ReadAllText(
    $goldenInnerStartPath, [Text.Encoding]::UTF8
)
$innerStartText = Replace-ExactOne $innerStartText `
    $expectedGoldenDatabaseSha256 $candidateHash `
    'phase3b2_user_progression_apply_inner_start_db_marker_invalid'
$innerStartText = Replace-ExactOne $innerStartText `
    'C:\NLL\Evidence\Phase3B2\Physical\epinel-minimal-reference-v1' `
    $newEvidenceRoot `
    'phase3b2_user_progression_apply_inner_start_evidence_marker_invalid'
$innerStartText = Replace-ExactOne $innerStartText 'p2-client-start-v2' `
    $newBootstrapLane `
    'phase3b2_user_progression_apply_inner_start_lane_marker_invalid'
Write-AtomicUtf8NoBom $candidateInnerStartPath $innerStartText
Assert-PowerShellSyntax $candidateInnerStartPath `
    'phase3b2_user_progression_apply_inner_start_syntax_invalid'
$derivedInnerStartHash = Get-Sha256Hex $candidateInnerStartPath

$innerCompletionText = [IO.File]::ReadAllText(
    $goldenInnerCompletionPath, [Text.Encoding]::UTF8
)
$innerCompletionText = Replace-ExactOne $innerCompletionText `
    $expectedGoldenDatabaseSha256 $candidateHash `
    'phase3b2_user_progression_apply_inner_completion_db_marker_invalid'
$innerCompletionText = Replace-ExactOne $innerCompletionText `
    'C:\NLL\Evidence\Phase3B2\Physical\epinel-minimal-reference-v1' `
    $newEvidenceRoot `
    'phase3b2_user_progression_apply_inner_completion_evidence_marker_invalid'
Write-AtomicUtf8NoBom $candidateInnerCompletionPath $innerCompletionText
Assert-PowerShellSyntax $candidateInnerCompletionPath `
    'phase3b2_user_progression_apply_inner_completion_syntax_invalid'
$derivedInnerCompletionHash = Get-Sha256Hex $candidateInnerCompletionPath

$completionWrapperText = [IO.File]::ReadAllText(
    $goldenCompletionWrapperPath, [Text.Encoding]::UTF8
)
$completionWrapperText = Replace-ExactOne $completionWrapperText `
    'C:\NLL\Tools\complete-phase3b2-epinel-minimal-reference-in-micron.ps1' `
    $newInnerCompletionClientPath `
    'phase3b2_user_progression_apply_completion_wrapper_marker_invalid'
Write-AtomicUtf8NoBom $candidateCompletionWrapperPath `
    $completionWrapperText
Assert-PowerShellSyntax $candidateCompletionWrapperPath `
    'phase3b2_user_progression_apply_completion_wrapper_syntax_invalid'
$derivedCompletionWrapperHash = Get-Sha256Hex `
    $candidateCompletionWrapperPath

$outerText = [IO.File]::ReadAllText(
    $goldenWrapperPath, [Text.Encoding]::UTF8
)
$outerText = Replace-ExactOne $outerText `
    $expectedGoldenInnerStartSha256 $derivedInnerStartHash `
    'phase3b2_user_progression_apply_outer_inner_hash_marker_invalid'
$outerText = Replace-ExactOne $outerText `
    'C:\NLL\Tools\start-phase3b2-epinel-minimal-reference-in-micron.ps1' `
    $newInnerStartClientPath `
    'phase3b2_user_progression_apply_outer_inner_path_marker_invalid'
$outerText = Replace-ExactOne $outerText `
    'C:\NLL\Evidence\Phase3B2\Physical\epinel-minimal-reference-v1\' `
    ($newEvidenceRoot + '\') `
    'phase3b2_user_progression_apply_outer_binding_path_marker_invalid'
$outerText = Replace-ExactOne $outerText `
    'C:\NLL\Tools\Complete-Phase3B2-Epinel-Minimal.ps1' `
    $newCompletionWrapperClientPath `
    'phase3b2_user_progression_apply_outer_completion_path_marker_invalid'
$sausBindingPattern =
    '(?ms)(\$sausToolBinding\.minimalStartToolSha256\s+-ceq\s*)' +
    '\$expectedMinimalStartToolSha256(\s+-and)'
$sausBindingReplacement =
    ('$1''' + $expectedGoldenInnerStartSha256 + '''$2')
$outerText = Replace-RegexExactOne $outerText $sausBindingPattern `
    $sausBindingReplacement `
    'phase3b2_user_progression_apply_outer_saus_inner_binding_marker_invalid'
$outerText = Replace-ExactOne $outerText `
    '(Get-Sha256Hex $PSCommandPath)' `
    "'$expectedGoldenWrapperSha256'" `
    'phase3b2_user_progression_apply_outer_saus_wrapper_binding_marker_invalid'
$outerInsertionMarker =
    "`$expectedExternalTree = 'c324c11d32365b1524f266cba6bc014e89545204'"
$outerProgressionBlock = @"

`$progressionStagingReceiptPath =
    '$activeStagingReceiptClientPath'
`$progressionDatabasePath = '$databaseClientPath'
`$progressionInnerCompletionPath =
    '$newInnerCompletionClientPath'
`$progressionCompletionWrapperPath =
    '$newCompletionWrapperClientPath'
Assert-True (
    (Test-Path -LiteralPath `$progressionStagingReceiptPath -PathType Leaf) -and
    (Test-Path -LiteralPath `$progressionDatabasePath -PathType Leaf) -and
    (Test-Path -LiteralPath `$progressionInnerCompletionPath -PathType Leaf) -and
    (Test-Path -LiteralPath `$progressionCompletionWrapperPath -PathType Leaf) -and
    (Get-Sha256Hex `$progressionStagingReceiptPath) -ceq
        '$stagingReceiptHash' -and
    (Get-Sha256Hex `$progressionDatabasePath) -ceq '$candidateHash' -and
    (Get-Sha256Hex `$progressionInnerCompletionPath) -ceq
        '$derivedInnerCompletionHash' -and
    (Get-Sha256Hex `$progressionCompletionWrapperPath) -ceq
        '$derivedCompletionWrapperHash'
) 'phase3b2_epinel_user_progression_start_input_missing_or_drifted'
`$progressionStaging = Get-Content -LiteralPath `$progressionStagingReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True (
    `$progressionStaging.contractId -ceq
        'nll/phase3b2-epinel-user-progression-offline-staging/v1' -and
    `$progressionStaging.candidateDatabaseSha256 -ceq '$candidateHash' -and
    `$progressionStaging.userProgressNormalStageLabel -ceq '48-44' -and
    `$progressionStaging.userProgressHardStageLabel -ceq '48-44' -and
    `$progressionStaging.userProgressStoryStageLabel -ceq '48-6' -and
    `$progressionStaging.soloRaidUnlockStageLabel -ceq '6-4' -and
    [int]`$progressionStaging.tutorialGroupCount -eq 40 -and
    `$progressionStaging.epinelRuntimeRoundTripVerified -and
    -not `$progressionStaging.stageClearHistoryFabricated -and
    -not `$progressionStaging.scenarioStateFabricated -and
    -not `$progressionStaging.questStateFabricated -and
    -not `$progressionStaging.rewardStateFabricated
) 'phase3b2_epinel_user_progression_start_contract_invalid'
"@
$outerText = Replace-ExactOne $outerText $outerInsertionMarker `
    ($outerInsertionMarker + $outerProgressionBlock) `
    'phase3b2_user_progression_apply_outer_insertion_marker_invalid'
Write-AtomicUtf8NoBom $candidateWrapperPath $outerText
Assert-PowerShellSyntax $candidateWrapperPath `
    'phase3b2_user_progression_apply_outer_syntax_invalid'
$derivedWrapperHash = Get-Sha256Hex $candidateWrapperPath

$rollbackPlan = [ordered]@{
    schemaVersion = 1
    contractId =
        'nll/phase3b2-epinel-user-progression-rollback-plan/v1'
    applicationUid = $applicationUid
    goldenDatabaseSha256 = $expectedGoldenDatabaseSha256
    candidateDatabaseSha256 = $candidateHash
    addedToolLeafNames = @(
        [IO.Path]::GetFileName($derivedWrapperPath),
        [IO.Path]::GetFileName($derivedInnerStartPath),
        [IO.Path]::GetFileName($derivedCompletionWrapperPath),
        [IO.Path]::GetFileName($derivedInnerCompletionPath)
    )
    rollbackCode =
        'restore_golden_db_and_retire_only_progression_owned_tools'
}
$rollbackPlanPath = Join-Path $applicationRoot 'r-plan.json'
Write-AtomicUtf8NoBom $rollbackPlanPath `
    (($rollbackPlan | ConvertTo-Json -Depth 6) + "`n")

$dbApplied = $false
$activeEvidenceCreated = $false
$installedToolPaths = New-Object Collections.Generic.List[string]
$applicationPointerPath = Join-Path $ProtectedRoot `
    'latest-application.pointer.json'
if ($GenerateOnly) {
    [pscustomobject]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-user-progression-tool-generation-validation/v1'
        stagingAssessmentUid = [string]$staging.assessmentUid
        stagingReceiptSha256 = $stagingReceiptHash
        candidateDatabaseSha256 = $candidateHash
        derivedStartWrapperSha256 = $derivedWrapperHash
        derivedInnerStartSha256 = $derivedInnerStartHash
        derivedCompletionWrapperSha256 = $derivedCompletionWrapperHash
        derivedInnerCompletionSha256 = $derivedInnerCompletionHash
        generatedPowerShellSyntaxVerified = $true
        goldenDatabaseModified = $false
        micronMutationPerformed = $false
        nextStepCode = 'run_deployable_staging_as_administrator'
    } | ConvertTo-Json -Depth 6
    exit 0
}
try {
    New-Item -ItemType Directory -Path $activeEvidenceRoot -Force | Out-Null
    $activeEvidenceCreated = $true
    Copy-Atomic $stagingReceiptPath $activeStagingReceiptPath
    Copy-Atomic $candidateInnerStartPath $derivedInnerStartPath
    $installedToolPaths.Add($derivedInnerStartPath)
    Copy-Atomic $candidateInnerCompletionPath $derivedInnerCompletionPath
    $installedToolPaths.Add($derivedInnerCompletionPath)
    Copy-Atomic $candidateCompletionWrapperPath `
        $derivedCompletionWrapperPath
    $installedToolPaths.Add($derivedCompletionWrapperPath)
    Copy-Atomic $candidateWrapperPath $derivedWrapperPath
    $installedToolPaths.Add($derivedWrapperPath)
    Assert-True (
        (Get-Sha256Hex $activeStagingReceiptPath) -ceq
            $stagingReceiptHash -and
        (Get-Sha256Hex $derivedInnerStartPath) -ceq
            $derivedInnerStartHash -and
        (Get-Sha256Hex $derivedInnerCompletionPath) -ceq
            $derivedInnerCompletionHash -and
        (Get-Sha256Hex $derivedCompletionWrapperPath) -ceq
            $derivedCompletionWrapperHash -and
        (Get-Sha256Hex $derivedWrapperPath) -ceq $derivedWrapperHash -and
        (Get-Sha256Hex $databasePath) -ceq $expectedGoldenDatabaseSha256
    ) 'phase3b2_user_progression_apply_pre_db_verification_failed'

    Copy-Atomic $candidateDatabasePath $databasePath
    $dbApplied = $true
    Assert-True ((Get-Sha256Hex $databasePath) -ceq $candidateHash) `
        'phase3b2_user_progression_apply_database_verification_failed'

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-user-progression-offline-application/v1'
        appliedAtUtc = [DateTimeOffset]::UtcNow.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'"
        )
        applicationUid = $applicationUid
        stagingAssessmentUid = [string]$staging.assessmentUid
        stagingReceiptSha256 = $stagingReceiptHash
        goldenParentFinalizationReceiptSha256 =
            $expectedFinalizationReceiptSha256
        goldenDatabaseSha256 = $expectedGoldenDatabaseSha256
        appliedDatabaseByteLength =
            (Get-Item -LiteralPath $databasePath).Length
        appliedDatabaseSha256 = $candidateHash
        userProgressNormalStageLabel = '48-44'
        userProgressHardStageLabel = '48-44'
        userProgressStoryStageLabel = '48-6'
        soloRaidUnlockStageLabel = '6-4'
        tutorialGroupCount = 40
        derivedStartWrapperByteLength =
            (Get-Item -LiteralPath $derivedWrapperPath).Length
        derivedStartWrapperSha256 = $derivedWrapperHash
        derivedInnerStartByteLength =
            (Get-Item -LiteralPath $derivedInnerStartPath).Length
        derivedInnerStartSha256 = $derivedInnerStartHash
        derivedCompletionWrapperByteLength =
            (Get-Item -LiteralPath $derivedCompletionWrapperPath).Length
        derivedCompletionWrapperSha256 = $derivedCompletionWrapperHash
        derivedInnerCompletionByteLength =
            (Get-Item -LiteralPath $derivedInnerCompletionPath).Length
        derivedInnerCompletionSha256 = $derivedInnerCompletionHash
        goldenStartWrapperModified = $false
        goldenInnerStartModified = $false
        goldenCompletionWrapperModified = $false
        goldenInnerCompletionModified = $false
        serverBinaryModified = $false
        cacheModified = $false
        existingOperatorCacheInspected = $false
        existingOperatorCacheModified = $false
        officialOutboundUsed = $false
        officialIdentityPersisted = $false
        officialCredentialPersisted = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        validationRunConsumed = $false
        rollbackPlanSha256 = Get-Sha256Hex $rollbackPlanPath
        nextStepCode =
            'boot_micron_nlloperator_run_user_progression_validation_once'
    }
    Write-AtomicUtf8NoBom $applicationReceiptPath `
        (($receipt | ConvertTo-Json -Depth 7) + "`n")
    $applicationReceiptSha256 = Get-Sha256Hex $applicationReceiptPath
    Copy-Item -LiteralPath $applicationReceiptPath -Destination `
        (Join-Path $applicationRoot 'application.receipt.json')
    Assert-True ((Get-Sha256Hex (Join-Path $applicationRoot `
                'application.receipt.json')) -ceq $applicationReceiptSha256) `
        'phase3b2_user_progression_apply_protected_receipt_invalid'

    $applicationPointer = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-user-progression-application-pointer/v1'
        applicationUid = $applicationUid
        protectedApplicationRoot = $applicationRoot
        applicationReceiptPath = $applicationReceiptPath
        applicationReceiptSha256 = $applicationReceiptSha256
        appliedDatabaseSha256 = $candidateHash
        rolledBack = $false
    }
    Write-AtomicUtf8NoBom $applicationPointerPath `
        (($applicationPointer | ConvertTo-Json -Depth 6) + "`n")
    $stagingPointer.consumed = $true
    $stagingPointer | Add-Member -NotePropertyName applicationUid `
        -NotePropertyValue $applicationUid
    Write-AtomicUtf8NoBom $stagingPointerPath `
        (($stagingPointer | ConvertTo-Json -Depth 6) + "`n")

    [pscustomobject]@{
        Receipt = $receipt
        MicronReceiptPath = $applicationReceiptPath
        MicronReceiptByteLength =
            (Get-Item -LiteralPath $applicationReceiptPath).Length
        MicronReceiptSha256 = $applicationReceiptSha256
        MicronStartCommand =
            "& 'C:\NLL\Tools\Start-Phase3B2-Epinel-UserProgression.ps1'"
        MicronCompletionCommand =
            "& 'C:\NLL\Tools\Complete-Phase3B2-Epinel-UserProgression.ps1' -ObservedStageCode <stage> -OutcomeCode <outcome>"
    } | ConvertTo-Json -Depth 9
}
catch {
    if ($dbApplied -and
        (Test-Path -LiteralPath (Join-Path $backupRoot `
                'g.json') -PathType Leaf)) {
        Copy-Atomic (Join-Path $backupRoot 'g.json') `
            $databasePath
    }
    foreach ($path in @($installedToolPaths)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force
        }
    }
    if ($activeEvidenceCreated) {
        foreach ($path in @($applicationReceiptPath, $activeStagingReceiptPath)) {
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                Remove-Item -LiteralPath $path -Force
            }
        }
        if ((Test-Path -LiteralPath $activeEvidenceRoot -PathType Container) -and
            @(Get-ChildItem -LiteralPath $activeEvidenceRoot -Force).Count -eq 0) {
            Remove-Item -LiteralPath $activeEvidenceRoot -Force
        }
    }
    if (Test-Path -LiteralPath $applicationPointerPath -PathType Leaf) {
        Remove-Item -LiteralPath $applicationPointerPath -Force
    }
    if (Test-Path -LiteralPath $stagingPointerPath -PathType Leaf) {
        Write-AtomicUtf8NoBom $stagingPointerPath `
            $stagingPointerOriginalJson
    }
    throw
}
