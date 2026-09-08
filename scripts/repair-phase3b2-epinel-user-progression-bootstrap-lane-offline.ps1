#requires -Version 5.1

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Z]$')]
    [string]$MicronDriveLetter = 'E',
    [string]$FailedAssessmentUid =
        'ea00cdc1-efea-412a-8ed9-fee4ab6038e3',
    [string]$ProtectedRoot =
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\EpinelUserProgressionBootstrapLane-v1',
    [switch]$ValidateOnly
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

function Test-Digest {
    param([string]$Path, [long]$ByteLength, [string]$Sha256)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $item = Get-Item -LiteralPath $Path
    return $item.Length -eq $ByteLength -and
        (Get-Sha256Hex $Path) -ceq $Sha256
}

function Test-ExclusiveAccess {
    param([string]$Path)
    try {
        $stream = [IO.File]::Open(
            $Path,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::None
        )
        $stream.Dispose()
        return $true
    }
    catch { return $false }
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

function Assert-PowerShellSyntax {
    param([string]$Path, [string]$FailureCode)
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile(
        $Path, [ref]$tokens, [ref]$errors
    ) | Out-Null
    Assert-True (@($errors).Count -eq 0) $FailureCode
}

$expectedApplicationReceiptSha256 =
    'c6bfdc4a982d8341b88b03509a9e1252896031b75061388d039539efd95f1fce'
$expectedStagingReceiptSha256 =
    'a327f63b38fd417f920788d30742e0b6f8321785fdacd610832ce38bb753576a'
$expectedFailureReceiptSha256 =
    '4c951815438e38d34bdf132b3ed4095f8e41c8bc61e2a1934900c469551e848d'
$expectedDatabaseByteLength = 545413L
$expectedDatabaseSha256 =
    '3009a738fa809d16e4b5026c70ff39fbd71a6c95e5ad1270727aaff02e277f96'
$expectedServerDllSha256 =
    'aaa1e49d7a879a6b5ec17ad4c4094ce7d98ce86f860c1529a9ab4d6aecb51f7c'
$expectedInnerStartByteLength = 39556L
$expectedInnerStartSha256 =
    '397b4b7b5c7e3a41ff57ebfaba54acf23c2741637a0272476c004d560da7b22e'
$expectedOuterWrapperByteLength = 17637L
$expectedOuterWrapperSha256 =
    '18bbf93ed7ab0a4a6119c390075926de9aece046ba0af2ac5cac4ed2c859ec96'
$expectedInnerCompletionSha256 =
    '5128eeeec62d7d61517cc952de9d5ad98530c8d43eb3c6265792f2a3408d8a2e'
$expectedCompletionWrapperSha256 =
    '8c5ac3c766e5a0f053de567c9158986ff84759174394fa8b420d10245ee24b7f'
$expectedBaseHostsSha256 =
    'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0'
$unsupportedLane = 'epinel-user-progression-client-start-v1'
$supportedLane = 'p2-client-start-v2'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $ValidateOnly) {
    Assert-True ($principal.IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator
        )) 'phase3b2_user_progression_lane_repair_requires_administrator'
}
Assert-True ($env:SystemDrive -ceq 'C:') `
    'phase3b2_user_progression_lane_repair_wrong_samsung_boot_boundary'

$micronDrive = $MicronDriveLetter + ':'
$micronBoundaryMarker = $(if ($ValidateOnly) {
        Join-Path $micronDrive `
            'NLL\Tools\Start-Phase3B2-Epinel-UserProgression.ps1'
    } else {
        Join-Path $micronDrive 'Windows\System32\config\SYSTEM'
    })
Assert-True (
    $micronDrive -cne $env:SystemDrive -and
    (Test-Path -LiteralPath $micronBoundaryMarker -PathType Leaf)
) 'phase3b2_user_progression_lane_repair_micron_offline_boundary_invalid'
Assert-True (@(Get-Process -Name @(
        'EpinelPS', 'NIKKE', 'nikke_launcher',
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
    ) -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_user_progression_lane_repair_runtime_not_cold'

$physicalRoot = Join-Path $micronDrive 'NLL\Evidence\Phase3B2\Physical'
$runtimeRoot = Join-Path $micronDrive `
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
$toolsRoot = Join-Path $micronDrive 'NLL\Tools'
$activeEvidenceRoot = Join-Path $physicalRoot `
    'epinel-user-progression-active-v1'
$runEvidenceRoot = Join-Path $physicalRoot `
    'epinel-user-progression-reference-v1'
$applicationReceiptPath = Join-Path $activeEvidenceRoot `
    'application.receipt.json'
$stagingReceiptPath = Join-Path $activeEvidenceRoot 'staging.receipt.json'
$failureReceiptPath = Join-Path (
    Join-Path $runEvidenceRoot $FailedAssessmentUid
) 'run-failure.receipt.json'
$activePointerPath = Join-Path $runEvidenceRoot 'active-run.pointer.json'
$databasePath = Join-Path $runtimeRoot 'db.json'
$serverDllPath = Join-Path $runtimeRoot 'EpinelPS.dll'
$hostsPath = Join-Path $micronDrive 'Windows\System32\drivers\etc\hosts'
$innerStartPath = Join-Path $toolsRoot `
    'start-phase3b2-epinel-user-progression-in-micron.ps1'
$outerWrapperPath = Join-Path $toolsRoot `
    'Start-Phase3B2-Epinel-UserProgression.ps1'
$innerCompletionPath = Join-Path $toolsRoot `
    'complete-phase3b2-epinel-user-progression-in-micron.ps1'
$completionWrapperPath = Join-Path $toolsRoot `
    'Complete-Phase3B2-Epinel-UserProgression.ps1'
$sqlitePaths = @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal' |
    ForEach-Object { Join-Path $runtimeRoot $_ })

$requiredPaths = @(
    $applicationReceiptPath, $stagingReceiptPath, $failureReceiptPath,
    $databasePath, $serverDllPath, $hostsPath, $innerStartPath,
    $outerWrapperPath, $innerCompletionPath, $completionWrapperPath
)
Assert-True (@($requiredPaths | Where-Object {
            -not (Test-Path -LiteralPath $_ -PathType Leaf)
        }).Count -eq 0) `
    'phase3b2_user_progression_lane_repair_input_missing'
Assert-True (@($requiredPaths | Where-Object {
            -not (Test-ExclusiveAccess $_)
        }).Count -eq 0) `
    'phase3b2_user_progression_lane_repair_input_in_use'
Assert-True (
    -not (Test-Path -LiteralPath $activePointerPath) -and
    @($sqlitePaths | Where-Object {
            Test-Path -LiteralPath $_ -PathType Leaf
        }).Count -eq 0
) 'phase3b2_user_progression_lane_repair_runtime_residue_present'

Assert-True (
    (Get-Sha256Hex $applicationReceiptPath) -ceq
        $expectedApplicationReceiptSha256 -and
    (Get-Sha256Hex $stagingReceiptPath) -ceq
        $expectedStagingReceiptSha256 -and
    (Get-Sha256Hex $failureReceiptPath) -ceq
        $expectedFailureReceiptSha256 -and
    (Test-Digest $databasePath $expectedDatabaseByteLength `
        $expectedDatabaseSha256) -and
    (Get-Sha256Hex $serverDllPath) -ceq $expectedServerDllSha256 -and
    (Get-Sha256Hex $hostsPath) -ceq $expectedBaseHostsSha256 -and
    (Test-Digest $innerStartPath $expectedInnerStartByteLength `
        $expectedInnerStartSha256) -and
    (Test-Digest $outerWrapperPath $expectedOuterWrapperByteLength `
        $expectedOuterWrapperSha256) -and
    (Get-Sha256Hex $innerCompletionPath) -ceq
        $expectedInnerCompletionSha256 -and
    (Get-Sha256Hex $completionWrapperPath) -ceq
        $expectedCompletionWrapperSha256
) 'phase3b2_user_progression_lane_repair_input_drifted'

$application = Get-Content -LiteralPath $applicationReceiptPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
$failure = Get-Content -LiteralPath $failureReceiptPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
Assert-True (
    $application.contractId -ceq
        'nll/phase3b2-epinel-user-progression-offline-application/v1' -and
    $application.applicationUid -ceq
        '072cfb5c-d0a1-4a00-b307-cc78b9c981e2' -and
    -not $application.validationRunConsumed -and
    $failure.contractId -ceq
        'nll/phase3b2-epinel-minimal-reference-failure/v1' -and
    $failure.assessmentUid -ceq $FailedAssessmentUid -and
    $failure.failedStageCode -ceq
        'physical_bootstrap_and_sail_observation' -and
    $failure.failureMessage -ceq 'bootstrap_exited_before_receipt' -and
    $failure.automaticRollbackCompleted -and
    -not $failure.clientExecutionStarted
) 'phase3b2_user_progression_lane_repair_evidence_invalid'

$repairUid = [Guid]::NewGuid().ToString()
$protectedRepairRoot = $(if ($ValidateOnly) {
        Join-Path ([IO.Path]::GetTempPath()) (
            'nll-progression-lane-validation-' + $repairUid
        )
    } else {
        Join-Path $ProtectedRoot $repairUid
    })
Assert-True (-not (Test-Path -LiteralPath $protectedRepairRoot)) `
    'phase3b2_user_progression_lane_repair_collision'
New-Item -ItemType Directory -Path $protectedRepairRoot -Force | Out-Null
$candidateRoot = Join-Path $protectedRepairRoot 'candidate'
New-Item -ItemType Directory -Path $candidateRoot -Force | Out-Null

$candidateInnerPath = Join-Path $candidateRoot 'inner-start.ps1'
$candidateOuterPath = Join-Path $candidateRoot 'outer-wrapper.ps1'
$innerTextBefore = [IO.File]::ReadAllText(
    $innerStartPath, [Text.Encoding]::UTF8
)
$innerTextAfter = Replace-ExactOne $innerTextBefore `
    ("[string]`$BootstrapEvidenceLane = '" + $unsupportedLane + "'") `
    ("[string]`$BootstrapEvidenceLane = '" + $supportedLane + "'") `
    'phase3b2_user_progression_lane_repair_inner_marker_invalid'
Write-AtomicUtf8NoBom $candidateInnerPath $innerTextAfter
Assert-PowerShellSyntax $candidateInnerPath `
    'phase3b2_user_progression_lane_repair_inner_syntax_invalid'
$newInnerStartSha256 = Get-Sha256Hex $candidateInnerPath
$newInnerStartByteLength = (Get-Item -LiteralPath $candidateInnerPath).Length
Assert-True (
    $newInnerStartSha256 -cne $expectedInnerStartSha256 -and
    $innerTextAfter.Replace(
        ("[string]`$BootstrapEvidenceLane = '" + $supportedLane + "'"),
        ("[string]`$BootstrapEvidenceLane = '" + $unsupportedLane + "'")
    ) -ceq $innerTextBefore
) 'phase3b2_user_progression_lane_repair_inner_scope_invalid'

$outerTextBefore = [IO.File]::ReadAllText(
    $outerWrapperPath, [Text.Encoding]::UTF8
)
$outerTextAfter = Replace-ExactOne $outerTextBefore `
    $expectedInnerStartSha256 $newInnerStartSha256 `
    'phase3b2_user_progression_lane_repair_outer_marker_invalid'
Write-AtomicUtf8NoBom $candidateOuterPath $outerTextAfter
Assert-PowerShellSyntax $candidateOuterPath `
    'phase3b2_user_progression_lane_repair_outer_syntax_invalid'
$newOuterWrapperSha256 = Get-Sha256Hex $candidateOuterPath
$newOuterWrapperByteLength = (Get-Item -LiteralPath $candidateOuterPath).Length
Assert-True (
    $newOuterWrapperSha256 -cne $expectedOuterWrapperSha256 -and
    $outerTextAfter.Replace(
        $newInnerStartSha256, $expectedInnerStartSha256
    ) -ceq $outerTextBefore
) 'phase3b2_user_progression_lane_repair_outer_scope_invalid'

if ($ValidateOnly) {
    $validationResult = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-user-progression-bootstrap-lane-repair-validation/v1'
        validatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        failedAssessmentUid = $FailedAssessmentUid
        validationOnly = $true
        targetMutationPerformed = $false
        priorInnerStartSha256 = $expectedInnerStartSha256
        candidateInnerStartByteLength = $newInnerStartByteLength
        candidateInnerStartSha256 = $newInnerStartSha256
        priorOuterWrapperSha256 = $expectedOuterWrapperSha256
        candidateOuterWrapperByteLength = $newOuterWrapperByteLength
        candidateOuterWrapperSha256 = $newOuterWrapperSha256
        innerChangeCount = 1
        outerChangeCount = 1
        innerInverseComparisonPassed = $true
        outerInverseComparisonPassed = $true
        powershellSyntaxVerified = $true
        databaseSha256 = $expectedDatabaseSha256
        completionToolsModified = $false
        cacheModified = $false
        serverBinaryModified = $false
        nextStepCode = 'rerun_same_tool_as_samsung_administrator_without_validate_only'
    }
    $validationJson = $validationResult | ConvertTo-Json -Depth 8
    Remove-Item -LiteralPath $protectedRepairRoot -Recurse -Force
    $validationJson
    return
}

$micronRepairRoot = Join-Path (
    Join-Path $physicalRoot `
        'epinel-user-progression-bootstrap-lane-repair-v1'
) $repairUid
Assert-True (-not (Test-Path -LiteralPath $micronRepairRoot)) `
    'phase3b2_user_progression_lane_repair_collision'
New-Item -ItemType Directory -Path $micronRepairRoot -Force | Out-Null
$backupRoot = Join-Path $protectedRepairRoot 'backup'
$micronBackupRoot = Join-Path $micronRepairRoot 'backup'
New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
New-Item -ItemType Directory -Path $micronBackupRoot -Force | Out-Null

$backupInnerPath = Join-Path $backupRoot 'inner-start.before.ps1'
$backupOuterPath = Join-Path $backupRoot 'outer-wrapper.before.ps1'
$micronBackupInnerPath = Join-Path $micronBackupRoot `
    'inner-start.before.ps1'
$micronBackupOuterPath = Join-Path $micronBackupRoot `
    'outer-wrapper.before.ps1'
Copy-Item -LiteralPath $innerStartPath -Destination $backupInnerPath
Copy-Item -LiteralPath $outerWrapperPath -Destination $backupOuterPath
Copy-Item -LiteralPath $innerStartPath -Destination $micronBackupInnerPath
Copy-Item -LiteralPath $outerWrapperPath -Destination $micronBackupOuterPath
Assert-True (
    (Get-Sha256Hex $backupInnerPath) -ceq $expectedInnerStartSha256 -and
    (Get-Sha256Hex $backupOuterPath) -ceq $expectedOuterWrapperSha256 -and
    (Get-Sha256Hex $micronBackupInnerPath) -ceq
        $expectedInnerStartSha256 -and
    (Get-Sha256Hex $micronBackupOuterPath) -ceq
        $expectedOuterWrapperSha256
) 'phase3b2_user_progression_lane_repair_backup_invalid'

$rollbackPlan = [ordered]@{
    schemaVersion = 1
    contractId =
        'nll/phase3b2-epinel-user-progression-bootstrap-lane-rollback-plan/v1'
    repairUid = $repairUid
    innerStartPath = $innerStartPath.Replace($micronDrive, 'C:')
    outerWrapperPath = $outerWrapperPath.Replace($micronDrive, 'C:')
    backupInnerStartRelativePath = 'backup/inner-start.before.ps1'
    backupOuterWrapperRelativePath = 'backup/outer-wrapper.before.ps1'
    expectedBackupInnerStartSha256 = $expectedInnerStartSha256
    expectedBackupOuterWrapperSha256 = $expectedOuterWrapperSha256
    expectedAppliedInnerStartSha256 = $newInnerStartSha256
    expectedAppliedOuterWrapperSha256 = $newOuterWrapperSha256
    restoreOrder = @('inner_start', 'outer_wrapper')
}
$rollbackPlanPath = Join-Path $protectedRepairRoot 'rollback.plan.json'
$micronRollbackPlanPath = Join-Path $micronRepairRoot 'rollback.plan.json'
Write-AtomicUtf8NoBom $rollbackPlanPath `
    (($rollbackPlan | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
Copy-Item -LiteralPath $rollbackPlanPath -Destination $micronRollbackPlanPath
$rollbackPlanSha256 = Get-Sha256Hex $rollbackPlanPath
Assert-True ((Get-Sha256Hex $micronRollbackPlanPath) -ceq
        $rollbackPlanSha256) `
    'phase3b2_user_progression_lane_repair_rollback_plan_invalid'

$innerApplied = $false
$outerApplied = $false
try {
    Copy-Atomic $candidateInnerPath $innerStartPath
    $innerApplied = $true
    Copy-Atomic $candidateOuterPath $outerWrapperPath
    $outerApplied = $true

    Assert-True (
        (Test-Digest $innerStartPath $newInnerStartByteLength `
            $newInnerStartSha256) -and
        (Test-Digest $outerWrapperPath $newOuterWrapperByteLength `
            $newOuterWrapperSha256) -and
        (Get-Sha256Hex $applicationReceiptPath) -ceq
            $expectedApplicationReceiptSha256 -and
        (Get-Sha256Hex $stagingReceiptPath) -ceq
            $expectedStagingReceiptSha256 -and
        (Get-Sha256Hex $failureReceiptPath) -ceq
            $expectedFailureReceiptSha256 -and
        (Test-Digest $databasePath $expectedDatabaseByteLength `
            $expectedDatabaseSha256) -and
        (Get-Sha256Hex $serverDllPath) -ceq $expectedServerDllSha256 -and
        (Get-Sha256Hex $hostsPath) -ceq $expectedBaseHostsSha256 -and
        (Get-Sha256Hex $innerCompletionPath) -ceq
            $expectedInnerCompletionSha256 -and
        (Get-Sha256Hex $completionWrapperPath) -ceq
            $expectedCompletionWrapperSha256 -and
        -not (Test-Path -LiteralPath $activePointerPath) -and
        @($sqlitePaths | Where-Object {
                Test-Path -LiteralPath $_ -PathType Leaf
            }).Count -eq 0
    ) 'phase3b2_user_progression_lane_repair_postcondition_invalid'

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-user-progression-bootstrap-lane-repair/v1'
        repairedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        repairUid = $repairUid
        applicationUid = [string]$application.applicationUid
        failedAssessmentUid = $FailedAssessmentUid
        failureReceiptSha256 = $expectedFailureReceiptSha256
        failureCauseCode = 'unsupported_physical_bootstrap_evidence_lane'
        priorInnerStartByteLength = $expectedInnerStartByteLength
        priorInnerStartSha256 = $expectedInnerStartSha256
        repairedInnerStartByteLength = $newInnerStartByteLength
        repairedInnerStartSha256 = $newInnerStartSha256
        innerStartChangeCode =
            'restore_bootstrap_evidence_lane_to_p2_client_start_v2'
        priorOuterWrapperByteLength = $expectedOuterWrapperByteLength
        priorOuterWrapperSha256 = $expectedOuterWrapperSha256
        repairedOuterWrapperByteLength = $newOuterWrapperByteLength
        repairedOuterWrapperSha256 = $newOuterWrapperSha256
        outerWrapperChangeCode = 'update_expected_inner_start_sha256_only'
        runtimeTargetMutationCount = 2
        bootstrapEvidenceLaneBefore = $unsupportedLane
        bootstrapEvidenceLaneAfter = $supportedLane
        supportedBootstrapLaneVerified = $true
        applicationReceiptPreserved = $true
        stagingReceiptPreserved = $true
        failureEvidencePreserved = $true
        databaseSha256 = $expectedDatabaseSha256
        databaseModified = $false
        serverDllSha256 = $expectedServerDllSha256
        serverBinaryModified = $false
        innerCompletionSha256 = $expectedInnerCompletionSha256
        completionWrapperSha256 = $expectedCompletionWrapperSha256
        completionToolsModified = $false
        cacheModified = $false
        hostsModified = $false
        activeRunPointerPresent = $false
        sqliteRuntimeMemberCount = 0
        priorAutomaticRollbackVerified = $true
        clientExecutionStartedDuringFailedRun = $false
        officialOutboundUsed = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        singleValidationRetryAuthorized = $true
        validationRetryConsumed = $false
        rollbackPlanSha256 = $rollbackPlanSha256
        nextStepCode =
            'boot_micron_nlloperator_run_user_progression_validation_once'
    }
    $receiptText = ($receipt | ConvertTo-Json -Depth 8) +
        [Environment]::NewLine
    $protectedReceiptPath = Join-Path $protectedRepairRoot `
        'repair.receipt.json'
    $micronReceiptPath = Join-Path $micronRepairRoot 'repair.receipt.json'
    Write-AtomicUtf8NoBom $protectedReceiptPath $receiptText
    Write-AtomicUtf8NoBom $micronReceiptPath $receiptText
    $receiptSha256 = Get-Sha256Hex $protectedReceiptPath
    Assert-True ((Get-Sha256Hex $micronReceiptPath) -ceq
            $receiptSha256) `
        'phase3b2_user_progression_lane_repair_receipt_copy_invalid'

    [ordered]@{
        Receipt = $receipt
        ProtectedReceiptPath = $protectedReceiptPath
        ProtectedReceiptByteLength =
            (Get-Item -LiteralPath $protectedReceiptPath).Length
        ProtectedReceiptSha256 = $receiptSha256
        MicronReceiptPath = $micronReceiptPath
        MicronStartCommand =
            "& 'C:\NLL\Tools\Start-Phase3B2-Epinel-UserProgression.ps1'"
    } | ConvertTo-Json -Depth 8
}
catch {
    if ($innerApplied -or $outerApplied) {
        Copy-Atomic $backupInnerPath $innerStartPath
        Copy-Atomic $backupOuterPath $outerWrapperPath
    }
    throw
}
