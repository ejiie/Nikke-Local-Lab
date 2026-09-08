#requires -Version 7.0

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Z]$')]
    [string]$MicronDriveLetter = 'E',
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$RevisionUid = '8ba2fb71-913c-4eaf-a56e-55c10c79d5c1',
    [string]$ProtectedRoot = (
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\' +
        'Micron-PrePhysicalLane-20260823\PhysicalP2\' +
        'EpinelTutorialStartBinding-v1'
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
    [IO.File]::WriteAllText(
        $temporary, $Text, [Text.UTF8Encoding]::new($false)
    )
    Move-Item -LiteralPath $temporary -Destination $Path
}

$micronDrive = $MicronDriveLetter + ':'
$systemDisk = Get-Partition -DriveLetter C | Get-Disk
$micronDisk = Get-Partition -DriveLetter $MicronDriveLetter | Get-Disk
Assert-True (
    $env:SystemDrive -ceq 'C:' -and
    $systemDisk.FriendlyName -like 'Samsung SSD 980*' -and
    $micronDisk.FriendlyName -like 'Micron_2200*'
) 'phase3b2_epinel_tutorial_start_binding_wrong_disk_boundary'
$runtimeProcesses = @(Get-Process -Name @(
        'EpinelPS', 'NIKKE', 'nikke_launcher',
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
    ) -ErrorAction SilentlyContinue)
Assert-True ($runtimeProcesses.Count -eq 0) `
    'phase3b2_epinel_tutorial_start_binding_runtime_not_cold'

$sourcePath = Join-Path $PSScriptRoot `
    'start-phase3b2-epinel-minimal-reference-in-micron.ps1'
$targetPath = Join-Path $micronDrive `
    'NLL\Tools\start-phase3b2-epinel-minimal-reference-in-micron.ps1'
$databasePath = Join-Path $micronDrive (
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\db.json'
)
$tutorialReceiptPath = Join-Path $micronDrive (
    'NLL\Evidence\Phase3B2\Physical\epinel-tutorial-only-v1\' +
    $RevisionUid + '\materialization.receipt.json'
)
$activePointerPath = Join-Path $micronDrive (
    'NLL\Evidence\Phase3B2\Physical\epinel-minimal-reference-v1\' +
    'active-run.pointer.json'
)
$expectedOldToolLength = 39526L
$expectedOldToolSha256 =
    'a039cd5186df92c16c0091f7d4b4c4bbb907d0bf2adc3ff94d8d425699bc5f69'
$expectedNewToolLength = 41649L
$expectedNewToolSha256 =
    '00270a38140f4ace8e77192e285731909a172e4e587c80394bac7bb55650e7ae'
$expectedDatabaseSha256 =
    'e8c6c7d299be04c91435391bd44e346ad3dd84f31697654f18b1aa8a47052330'
$expectedTutorialReceiptSha256 =
    '5685274460cd64bee2391a962ec0988b5938dbb0f3ee98ac64e16c8204e31f00'

$bindingInputValid =
    -not (Test-Path -LiteralPath $activePointerPath) -and
    (Test-Digest -Path $sourcePath -ByteLength $expectedNewToolLength -Sha256 $expectedNewToolSha256) -and
    (Test-Digest -Path $targetPath -ByteLength $expectedOldToolLength -Sha256 $expectedOldToolSha256) -and
    (Get-Sha256Hex $databasePath) -ceq $expectedDatabaseSha256 -and
    (Get-Sha256Hex $tutorialReceiptPath) -ceq $expectedTutorialReceiptSha256
Assert-True $bindingInputValid `
    'phase3b2_epinel_tutorial_start_binding_input_invalid'
$tutorialReceipt = Get-Content -LiteralPath $tutorialReceiptPath `
    -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True (
    $tutorialReceipt.contractId -ceq
        'nll/phase3b2-epinel-tutorial-only-materialization/v1' -and
    $tutorialReceipt.revisionUid -ceq $RevisionUid -and
    $tutorialReceipt.databaseAfterSha256 -ceq $expectedDatabaseSha256 -and
    $tutorialReceipt.tutorialGroupCountAfter -eq 40 -and
    -not $tutorialReceipt.nonTutorialStateChanged -and
    $tutorialReceipt.singleTutorialValidationRunAuthorized -and
    -not $tutorialReceipt.validationRunConsumed
) 'phase3b2_epinel_tutorial_start_binding_receipt_invalid'

$backupRoot = Join-Path $micronDrive (
    'NLL\Backups\Phase3B2\EpinelTutorialStartBinding-v1\' + $RevisionUid
)
$evidenceRoot = Join-Path $micronDrive (
    'NLL\Evidence\Phase3B2\Physical\' +
    'epinel-tutorial-start-binding-v1\' + $RevisionUid
)
$protectedRevisionRoot = Join-Path $ProtectedRoot $RevisionUid
Assert-True (
    -not (Test-Path -LiteralPath $backupRoot) -and
    -not (Test-Path -LiteralPath $evidenceRoot) -and
    -not (Test-Path -LiteralPath $protectedRevisionRoot)
) 'phase3b2_epinel_tutorial_start_binding_destination_collision'

$partialRoot = $backupRoot + '.partial-' + [Guid]::NewGuid().ToString('N')
try {
    New-Item -ItemType Directory -Path $partialRoot -Force | Out-Null
    $beforePath = Join-Path $partialRoot 'start.before.ps1'
    $afterPath = Join-Path $partialRoot 'start.after.ps1'
    Copy-Item -LiteralPath $targetPath -Destination $beforePath
    Copy-Item -LiteralPath $sourcePath -Destination $afterPath
    $targetPartial = $targetPath + '.partial-' +
        [Guid]::NewGuid().ToString('N')
    try {
        Copy-Item -LiteralPath $sourcePath -Destination $targetPartial
        Move-Item -LiteralPath $targetPartial -Destination $targetPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $targetPartial -PathType Leaf) {
            Remove-Item -LiteralPath $targetPartial -Force
        }
    }
    $boundToolValid = Test-Digest -Path $targetPath `
        -ByteLength $expectedNewToolLength -Sha256 $expectedNewToolSha256
    Assert-True $boundToolValid `
        'phase3b2_epinel_tutorial_start_binding_apply_invalid'

    $rollback = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-tutorial-start-binding-rollback-plan/v1'
        revisionUid = $RevisionUid
        activeToolBeforeRelativePath = 'start.before.ps1'
        activeToolBeforeByteLength = $expectedOldToolLength
        activeToolBeforeSha256 = $expectedOldToolSha256
        activeToolAfterRelativePath = 'start.after.ps1'
        activeToolAfterByteLength = $expectedNewToolLength
        activeToolAfterSha256 = $expectedNewToolSha256
        databaseRollbackRequired = $false
        cacheRollbackRequired = $false
        requiresSamsungBoot = $true
        requiresMicronOffline = $true
        runtimeMustBeCold = $true
    }
    Write-AtomicUtf8NoBom (Join-Path $partialRoot 'rollback.plan.json') (
        ($rollback | ConvertTo-Json -Depth 5) + "`n"
    )
    Move-Item -LiteralPath $partialRoot -Destination $backupRoot
}
catch {
    $partialBeforePath = Join-Path $partialRoot 'start.before.ps1'
    if (Test-Path -LiteralPath $partialBeforePath -PathType Leaf) {
        Copy-Item -LiteralPath $partialBeforePath `
            -Destination $targetPath -Force
    }
    throw
}
finally {
    if (Test-Path -LiteralPath $partialRoot) {
        Remove-Item -LiteralPath $partialRoot -Recurse -Force
    }
}

$rollbackPlanPath = Join-Path $backupRoot 'rollback.plan.json'
$receipt = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-epinel-tutorial-start-binding/v1'
    boundAtUtc = [DateTimeOffset]::UtcNow.ToString(
        "yyyy-MM-dd'T'HH:mm:ss'Z'"
    )
    revisionUid = $RevisionUid
    tutorialMaterializationReceiptSha256 =
        $expectedTutorialReceiptSha256
    databaseSha256 = $expectedDatabaseSha256
    priorStartToolByteLength = $expectedOldToolLength
    priorStartToolSha256 = $expectedOldToolSha256
    boundStartToolByteLength = $expectedNewToolLength
    boundStartToolSha256 = $expectedNewToolSha256
    tutorialReceiptPreflightEnabled = $true
    tutorialDatabaseDigestPreflightEnabled = $true
    tutorialGroupCountExpected = 40
    nonTutorialProgressionExpectedUnchanged = $true
    rollbackPlanByteLength = [long](
        Get-Item -LiteralPath $rollbackPlanPath
    ).Length
    rollbackPlanSha256 = Get-Sha256Hex $rollbackPlanPath
    databaseMutationPerformed = $false
    cacheMutationPerformed = $false
    serverBinaryMutationPerformed = $false
    nativeCacheWrapperMutationPerformed = $false
    targetOsOfflineDuringBinding = $true
    officialOutboundUsed = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
    nextStepCode =
        'boot_micron_nlloperator_run_tutorial_validation_once'
}
$micronReceiptPath = Join-Path $evidenceRoot 'binding.receipt.json'
$protectedReceiptPath = Join-Path $protectedRevisionRoot `
    'binding.receipt.json'
$protectedBackupRoot = Join-Path $protectedRevisionRoot 'artifacts'
New-Item -ItemType Directory -Path $evidenceRoot, $protectedRevisionRoot -Force |
    Out-Null
Write-AtomicUtf8NoBom $micronReceiptPath (
    ($receipt | ConvertTo-Json -Depth 6) + "`n"
)
Copy-Item -LiteralPath $backupRoot -Destination $protectedBackupRoot -Recurse
Copy-Item -LiteralPath $micronReceiptPath -Destination $protectedReceiptPath
Assert-True (
    (Get-Sha256Hex $micronReceiptPath) -ceq
        (Get-Sha256Hex $protectedReceiptPath) -and
    (Get-Sha256Hex (Join-Path $backupRoot 'start.before.ps1')) -ceq
        (Get-Sha256Hex (Join-Path $protectedBackupRoot 'start.before.ps1')) -and
    (Get-Sha256Hex (Join-Path $backupRoot 'start.after.ps1')) -ceq
        (Get-Sha256Hex (Join-Path $protectedBackupRoot 'start.after.ps1'))
) 'phase3b2_epinel_tutorial_start_binding_protected_copy_invalid'

[pscustomobject]@{
    Receipt = $receipt
    MicronReceiptPath = $micronReceiptPath
    MicronReceiptByteLength = (Get-Item -LiteralPath $micronReceiptPath).Length
    MicronReceiptSha256 = Get-Sha256Hex $micronReceiptPath
    SamsungProtectedReceiptPath = $protectedReceiptPath
    MicronValidationCommand =
        "& 'C:\NLL\Tools\Start-Phase3B2-Epinel-NativeCache.ps1'"
} | ConvertTo-Json -Depth 7
