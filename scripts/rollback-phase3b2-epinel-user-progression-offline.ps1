#requires -Version 5.1
#requires -RunAsAdministrator

param(
    [string]$MicronDrive = 'E:',
    [string]$ProtectedRoot =
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\EpinelUserProgression-v1'
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

Assert-True ($env:SystemDrive -ceq 'C:') `
    'phase3b2_user_progression_rollback_wrong_samsung_boot_boundary'
$micronRoot = $MicronDrive.TrimEnd('\')
Assert-True (
    $micronRoot -match '^[A-Za-z]:$' -and
    $micronRoot -cne $env:SystemDrive -and
    (Test-Path -LiteralPath (Join-Path $micronRoot 'Windows\System32\config\SYSTEM') `
        -PathType Leaf)
) 'phase3b2_user_progression_rollback_wrong_micron_disk_boundary'
Assert-True (@(Get-Process -Name @(
            'nikke', 'EpinelPS',
            'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
        ) -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_user_progression_rollback_runtime_not_cold'

$applicationPointerPath = Join-Path $ProtectedRoot `
    'latest-application.pointer.json'
Assert-True (Test-Path -LiteralPath $applicationPointerPath -PathType Leaf) `
    'phase3b2_user_progression_rollback_pointer_missing'
$applicationPointer = Get-Content -LiteralPath $applicationPointerPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
$applicationPointerOriginalJson =
    (($applicationPointer | ConvertTo-Json -Depth 6) + "`n")
$applicationUid = [string]$applicationPointer.applicationUid
$applicationRoot = [string]$applicationPointer.protectedApplicationRoot
$applicationReceiptPath = [string]$applicationPointer.applicationReceiptPath
Assert-True (
    $applicationPointer.contractId -ceq
        'nll/phase3b2-epinel-user-progression-application-pointer/v1' -and
    [Guid]::Parse($applicationUid) -ne [Guid]::Empty -and
    -not $applicationPointer.rolledBack -and
    (Test-Path -LiteralPath $applicationRoot -PathType Container) -and
    (Test-Path -LiteralPath $applicationReceiptPath -PathType Leaf) -and
    (Get-Sha256Hex $applicationReceiptPath) -ceq
        [string]$applicationPointer.applicationReceiptSha256
) 'phase3b2_user_progression_rollback_pointer_invalid'
$application = Get-Content -LiteralPath $applicationReceiptPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
Assert-True (
    $application.contractId -ceq
        'nll/phase3b2-epinel-user-progression-offline-application/v1' -and
    $application.applicationUid -ceq $applicationUid -and
    $application.goldenDatabaseSha256 -ceq
        $expectedGoldenDatabaseSha256 -and
    $application.appliedDatabaseSha256 -ceq
        [string]$applicationPointer.appliedDatabaseSha256 -and
    $application.userProgressNormalStageLabel -ceq '48-44' -and
    $application.userProgressHardStageLabel -ceq '48-44' -and
    $application.userProgressStoryStageLabel -ceq '48-6' -and
    [int]$application.tutorialGroupCount -eq 40 -and
    -not $application.goldenStartWrapperModified -and
    -not $application.goldenInnerStartModified -and
    -not $application.goldenCompletionWrapperModified -and
    -not $application.goldenInnerCompletionModified -and
    -not $application.serverBinaryModified -and
    -not $application.cacheModified
) 'phase3b2_user_progression_rollback_application_contract_invalid'

$runtimeRoot = Join-Path $micronRoot `
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
$databasePath = Join-Path $runtimeRoot 'db.json'
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
$derivedToolPaths = @(
    $derivedWrapperPath, $derivedInnerStartPath,
    $derivedCompletionWrapperPath, $derivedInnerCompletionPath
)
$goldenDatabaseBackupPath = Join-Path $applicationRoot `
    'b\g.json'
$candidateDatabasePath = Join-Path (Join-Path $ProtectedRoot `
        ([string]$application.stagingAssessmentUid)) 'candidate-db.json'
$finalizationReceiptPath = Join-Path $micronRoot `
    'NLL\Evidence\Phase3B2\Physical\epinel-lobby-golden-restore-v1\b8476bb3-b212-476c-81e2-0d9c56a92399\finalization.receipt.json'
$activeEvidenceRoot = Join-Path $micronRoot `
    'NLL\Evidence\Phase3B2\Physical\epinel-user-progression-active-v1'
$progressionActivePointerPath = Join-Path $micronRoot `
    'NLL\Evidence\Phase3B2\Physical\epinel-user-progression-reference-v1\active-run.pointer.json'
$retiredRoot = Join-Path (Join-Path $micronRoot `
        'NLL\Evidence\Phase3B2\Physical\epinel-user-progression-retired-v1') `
    $applicationUid

$required = @(
    $databasePath, $goldenWrapperPath, $goldenInnerStartPath,
    $goldenCompletionWrapperPath, $goldenInnerCompletionPath,
    $goldenDatabaseBackupPath, $candidateDatabasePath,
    $finalizationReceiptPath, $applicationReceiptPath
) + $derivedToolPaths
Assert-True (@($required | Where-Object {
            -not (Test-Path -LiteralPath $_ -PathType Leaf)
        }).Count -eq 0 -and
    (Get-Sha256Hex $databasePath) -ceq
        [string]$application.appliedDatabaseSha256 -and
    (Get-Sha256Hex $goldenDatabaseBackupPath) -ceq
        $expectedGoldenDatabaseSha256 -and
    (Get-Sha256Hex $candidateDatabasePath) -ceq
        [string]$application.appliedDatabaseSha256 -and
    (Get-Sha256Hex $goldenWrapperPath) -ceq
        $expectedGoldenWrapperSha256 -and
    (Get-Sha256Hex $goldenInnerStartPath) -ceq
        $expectedGoldenInnerStartSha256 -and
    (Get-Sha256Hex $goldenCompletionWrapperPath) -ceq
        $expectedGoldenCompletionWrapperSha256 -and
    (Get-Sha256Hex $goldenInnerCompletionPath) -ceq
        $expectedGoldenInnerCompletionSha256 -and
    (Get-Sha256Hex $derivedWrapperPath) -ceq
        [string]$application.derivedStartWrapperSha256 -and
    (Get-Sha256Hex $derivedInnerStartPath) -ceq
        [string]$application.derivedInnerStartSha256 -and
    (Get-Sha256Hex $derivedCompletionWrapperPath) -ceq
        [string]$application.derivedCompletionWrapperSha256 -and
    (Get-Sha256Hex $derivedInnerCompletionPath) -ceq
        [string]$application.derivedInnerCompletionSha256 -and
    (Get-Sha256Hex $finalizationReceiptPath) -ceq
        $expectedFinalizationReceiptSha256 -and
    -not (Test-Path -LiteralPath $progressionActivePointerPath) -and
    (Test-Path -LiteralPath $activeEvidenceRoot -PathType Container) -and
    -not (Test-Path -LiteralPath $retiredRoot)
) 'phase3b2_user_progression_rollback_boundary_invalid'

$candidateBeforeRollbackPath = Join-Path $applicationRoot `
    'c-before-rollback.json'
Assert-True (-not (Test-Path -LiteralPath $candidateBeforeRollbackPath)) `
    'phase3b2_user_progression_rollback_backup_collision'
Copy-Item -LiteralPath $databasePath -Destination `
    $candidateBeforeRollbackPath
Assert-True ((Get-Sha256Hex $candidateBeforeRollbackPath) -ceq
        [string]$application.appliedDatabaseSha256) `
    'phase3b2_user_progression_rollback_candidate_backup_invalid'

$retiredParent = Split-Path -Parent $retiredRoot
New-Item -ItemType Directory -Path $retiredParent -Force | Out-Null
$movedTools = New-Object Collections.Generic.List[object]
$evidenceMoved = $false
$goldenRestored = $false
try {
    Copy-Atomic $goldenDatabaseBackupPath $databasePath
    $goldenRestored = $true
    Assert-True ((Get-Sha256Hex $databasePath) -ceq
            $expectedGoldenDatabaseSha256) `
        'phase3b2_user_progression_rollback_database_restore_failed'

    Move-Item -LiteralPath $activeEvidenceRoot -Destination $retiredRoot
    $evidenceMoved = $true
    $retiredToolRoot = Join-Path $retiredRoot 'retired-tools'
    New-Item -ItemType Directory -Path $retiredToolRoot -Force | Out-Null
    foreach ($path in $derivedToolPaths) {
        $destination = Join-Path $retiredToolRoot `
            ([IO.Path]::GetFileName($path))
        Move-Item -LiteralPath $path -Destination $destination
        $movedTools.Add([pscustomobject]@{
                Source = $path
                Destination = $destination
            })
    }
    Assert-True (@($derivedToolPaths | Where-Object {
                Test-Path -LiteralPath $_
            }).Count -eq 0 -and
        (Get-Sha256Hex $goldenWrapperPath) -ceq
            $expectedGoldenWrapperSha256 -and
        (Get-Sha256Hex $goldenInnerStartPath) -ceq
            $expectedGoldenInnerStartSha256 -and
        (Get-Sha256Hex $goldenCompletionWrapperPath) -ceq
            $expectedGoldenCompletionWrapperSha256 -and
        (Get-Sha256Hex $goldenInnerCompletionPath) -ceq
            $expectedGoldenInnerCompletionSha256) `
        'phase3b2_user_progression_rollback_tool_retirement_failed'

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-user-progression-offline-rollback/v1'
        rolledBackAtUtc = [DateTimeOffset]::UtcNow.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'"
        )
        applicationUid = $applicationUid
        applicationReceiptSha256 =
            [string]$applicationPointer.applicationReceiptSha256
        retiredCandidateDatabaseSha256 =
            [string]$application.appliedDatabaseSha256
        restoredGoldenDatabaseSha256 = $expectedGoldenDatabaseSha256
        retiredDerivedToolCount = 4
        goldenStartWrapperModified = $false
        goldenInnerStartModified = $false
        goldenCompletionWrapperModified = $false
        goldenInnerCompletionModified = $false
        serverBinaryModified = $false
        cacheModified = $false
        activeProgressionEvidenceRetired = $true
        candidateDatabaseBackupPreserved = $true
        officialOutboundUsed = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        nextStepCode = 'golden_lobby_baseline_restored_offline'
    }
    $rollbackReceiptPath = Join-Path $retiredRoot 'rollback.receipt.json'
    Write-AtomicUtf8NoBom $rollbackReceiptPath `
        (($receipt | ConvertTo-Json -Depth 6) + "`n")
    $rollbackReceiptSha256 = Get-Sha256Hex $rollbackReceiptPath
    Copy-Item -LiteralPath $rollbackReceiptPath -Destination `
        (Join-Path $applicationRoot 'rollback.receipt.json')
    Assert-True ((Get-Sha256Hex (Join-Path $applicationRoot `
                'rollback.receipt.json')) -ceq $rollbackReceiptSha256) `
        'phase3b2_user_progression_rollback_protected_receipt_invalid'

    $applicationPointer.rolledBack = $true
    $applicationPointer | Add-Member -NotePropertyName rollbackReceiptPath `
        -NotePropertyValue $rollbackReceiptPath
    $applicationPointer | Add-Member `
        -NotePropertyName rollbackReceiptSha256 `
        -NotePropertyValue $rollbackReceiptSha256
    Write-AtomicUtf8NoBom $applicationPointerPath `
        (($applicationPointer | ConvertTo-Json -Depth 6) + "`n")

    [pscustomobject]@{
        Receipt = $receipt
        ReceiptPath = $rollbackReceiptPath
        ReceiptByteLength =
            (Get-Item -LiteralPath $rollbackReceiptPath).Length
        ReceiptSha256 = $rollbackReceiptSha256
        GoldenStartCommand =
            "& 'C:\NLL\Tools\Start-Phase3B2-Epinel-NativeCache.ps1'"
    } | ConvertTo-Json -Depth 8
}
catch {
    for ($index = $movedTools.Count - 1; $index -ge 0; $index--) {
        $member = $movedTools[$index]
        if (Test-Path -LiteralPath $member.Destination -PathType Leaf) {
            Move-Item -LiteralPath $member.Destination `
                -Destination $member.Source -Force
        }
    }
    if ($evidenceMoved -and
        (Test-Path -LiteralPath $retiredRoot -PathType Container) -and
        -not (Test-Path -LiteralPath $activeEvidenceRoot)) {
        Move-Item -LiteralPath $retiredRoot `
            -Destination $activeEvidenceRoot
    }
    if ($goldenRestored -and
        (Test-Path -LiteralPath $candidateBeforeRollbackPath -PathType Leaf)) {
        Copy-Atomic $candidateBeforeRollbackPath $databasePath
    }
    Write-AtomicUtf8NoBom $applicationPointerPath `
        $applicationPointerOriginalJson
    throw
}
