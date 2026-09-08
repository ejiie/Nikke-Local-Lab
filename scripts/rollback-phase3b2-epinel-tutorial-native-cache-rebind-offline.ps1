#requires -Version 5.1

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Z]$')]
    [string]$MicronDriveLetter = 'E',
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$RevisionUid = '8ba2fb71-913c-4eaf-a56e-55c10c79d5c1',
    [string]$ProtectedRoot = (
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\' +
        'Micron-PrePhysicalLane-20260823\PhysicalP2\' +
        'EpinelTutorialNativeCacheRebind-v1'
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

function Write-AtomicUtf8NoBom {
    param([string]$Path, [string]$Text)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporary = $Path + '.partial-' + [Guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText(
        $temporary, $Text, [Text.UTF8Encoding]::new($false)
    )
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

$expectedRevisionUid = '8ba2fb71-913c-4eaf-a56e-55c10c79d5c1'
$expectedPriorWrapperSha256 =
    'fe667ba466ea27a5bfd55e09c4d0cd9ef94b04d434d95ac1590ccd7f813e493b'
$expectedRepairedWrapperSha256 =
    '4711bf99fdbe74d503d1705c37ea175b24766ab1915972beb8e91b1ed7a600a8'
$expectedActiveInnerSha256 =
    '00270a38140f4ace8e77192e285731909a172e4e587c80394bac7bb55650e7ae'
$expectedDatabaseSha256 =
    'e8c6c7d299be04c91435391bd44e346ad3dd84f31697654f18b1aa8a47052330'
Assert-True ($RevisionUid -ceq $expectedRevisionUid) `
    'phase3b2_tutorial_native_cache_rebind_rollback_revision_invalid'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
Assert-True ($principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    'phase3b2_tutorial_native_cache_rebind_rollback_requires_administrator'

$micronDrive = $MicronDriveLetter + ':'
$systemDisk = Get-Partition -DriveLetter C | Get-Disk
$micronDisk = Get-Partition -DriveLetter $MicronDriveLetter | Get-Disk
Assert-True (
    $env:SystemDrive -ceq 'C:' -and
    $systemDisk.FriendlyName -like 'Samsung SSD 980*' -and
    $micronDisk.FriendlyName -like 'Micron_2200*' -and
    (Test-Path -LiteralPath (Join-Path $micronDrive 'Windows\System32') `
        -PathType Container)
) 'phase3b2_tutorial_native_cache_rebind_rollback_wrong_disk_boundary'
Assert-True (@(Get-Process -Name @(
        'EpinelPS', 'NIKKE', 'nikke_launcher',
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
    ) -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_tutorial_native_cache_rebind_rollback_runtime_not_cold'

$physicalRoot = Join-Path $micronDrive 'NLL\Evidence\Phase3B2\Physical'
$activePointerPath = Join-Path (
    $physicalRoot + '\epinel-minimal-reference-v1'
) 'active-run.pointer.json'
$activeWrapperPath = Join-Path $micronDrive `
    'NLL\Tools\Start-Phase3B2-Epinel-NativeCache.ps1'
$activeInnerPath = Join-Path $micronDrive `
    'NLL\Tools\start-phase3b2-epinel-minimal-reference-in-micron.ps1'
$databasePath = Join-Path $micronDrive `
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\db.json'
$sqliteRuntimePaths = @(
    Join-Path $micronDrive `
        'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\epinelps.db'
    Join-Path $micronDrive `
        'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\epinelps.db-shm'
    Join-Path $micronDrive `
        'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\epinelps.db-wal'
)
$evidenceRoot = Join-Path (
    $physicalRoot + '\epinel-tutorial-native-cache-rebind-v1'
) $RevisionUid
$repairReceiptPath = Join-Path $evidenceRoot 'repair.receipt.json'
$rollbackReceiptPath = Join-Path $evidenceRoot 'rollback.receipt.json'
$backupRoot = Join-Path $micronDrive (
    'NLL\Backups\Phase3B2\EpinelTutorialNativeCacheRebind-v1\' +
    $RevisionUid
)
$priorWrapperBackupPath = Join-Path $backupRoot `
    'Start-Phase3B2-Epinel-NativeCache.before.ps1'
$protectedRevisionRoot = Join-Path $ProtectedRoot $RevisionUid
$protectedRollbackReceiptPath = Join-Path $protectedRevisionRoot `
    'rollback.receipt.json'

Assert-True (
    -not (Test-Path -LiteralPath $activePointerPath) -and
    @($sqliteRuntimePaths | Where-Object {
            Test-Path -LiteralPath $_
        }).Count -eq 0 -and
    (Test-Path -LiteralPath $activeWrapperPath -PathType Leaf) -and
    (Test-Path -LiteralPath $activeInnerPath -PathType Leaf) -and
    (Test-Path -LiteralPath $databasePath -PathType Leaf) -and
    (Test-Path -LiteralPath $repairReceiptPath -PathType Leaf) -and
    (Test-Path -LiteralPath $priorWrapperBackupPath -PathType Leaf) -and
    -not (Test-Path -LiteralPath $rollbackReceiptPath) -and
    -not (Test-Path -LiteralPath $protectedRollbackReceiptPath)
) 'phase3b2_tutorial_native_cache_rebind_rollback_input_invalid'
Assert-True (
    (Get-Sha256Hex $activeWrapperPath) -ceq
        $expectedRepairedWrapperSha256 -and
    (Get-Sha256Hex $priorWrapperBackupPath) -ceq
        $expectedPriorWrapperSha256 -and
    (Get-Sha256Hex $activeInnerPath) -ceq $expectedActiveInnerSha256 -and
    (Get-Sha256Hex $databasePath) -ceq $expectedDatabaseSha256
) 'phase3b2_tutorial_native_cache_rebind_rollback_digest_invalid'

$repair = Get-Content -LiteralPath $repairReceiptPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
Assert-True (
    $repair.contractId -ceq
        'nll/phase3b2-epinel-tutorial-native-cache-rebind/v1' -and
    $repair.revisionUid -ceq $RevisionUid -and
    $repair.priorWrapperToolSha256 -ceq $expectedPriorWrapperSha256 -and
    $repair.repairedWrapperToolSha256 -ceq
        $expectedRepairedWrapperSha256 -and
    $repair.activeMinimalStartToolSha256 -ceq
        $expectedActiveInnerSha256 -and
    $repair.databaseSha256 -ceq $expectedDatabaseSha256 -and
    $repair.historicalSausEvidencePreserved -and
    $repair.goldenBaselinePreserved -and
    $repair.targetOsOfflineDuringRepair -and
    -not $repair.serverExecutionStarted -and
    -not $repair.clientExecutionStarted -and
    -not $repair.validationRunConsumed
) 'phase3b2_tutorial_native_cache_rebind_rollback_contract_invalid'

$repairReceiptSha256 = Get-Sha256Hex $repairReceiptPath
Write-AtomicUtf8NoBom $activeWrapperPath (
    Get-Content -LiteralPath $priorWrapperBackupPath -Raw -Encoding UTF8
)
Assert-True ((Get-Sha256Hex $activeWrapperPath) -ceq
    $expectedPriorWrapperSha256) `
    'phase3b2_tutorial_native_cache_rebind_rollback_restore_failed'

$receipt = [ordered]@{
    schemaVersion = 1
    contractId =
        'nll/phase3b2-epinel-tutorial-native-cache-rebind-rollback/v1'
    rolledBackAtUtc = [DateTimeOffset]::UtcNow.ToString(
        "yyyy-MM-dd'T'HH:mm:ss'Z'"
    )
    revisionUid = $RevisionUid
    repairReceiptSha256 = $repairReceiptSha256
    removedWrapperToolSha256 = $expectedRepairedWrapperSha256
    restoredWrapperToolSha256 = $expectedPriorWrapperSha256
    activeMinimalStartToolSha256 = $expectedActiveInnerSha256
    databaseSha256 = $expectedDatabaseSha256
    databaseMutationPerformed = $false
    cacheMutationPerformed = $false
    serverBinaryMutationPerformed = $false
    activeInnerStartMutationPerformed = $false
    targetOsOfflineDuringRollback = $true
    serverExecutionStarted = $false
    clientExecutionStarted = $false
    nextStepCode = 'return_to_samsung_before_any_new_validation_run'
}
Write-AtomicUtf8NoBom $rollbackReceiptPath `
    (($receipt | ConvertTo-Json -Depth 6) + "`n")
New-Item -ItemType Directory -Path $protectedRevisionRoot -Force | Out-Null
Copy-Item -LiteralPath $rollbackReceiptPath `
    -Destination $protectedRollbackReceiptPath
Assert-True ((Get-Sha256Hex $protectedRollbackReceiptPath) -ceq
    (Get-Sha256Hex $rollbackReceiptPath)) `
    'phase3b2_tutorial_native_cache_rebind_rollback_protected_copy_invalid'

[pscustomobject]@{
    Receipt = $receipt
    ReceiptPath = $rollbackReceiptPath
    ReceiptByteLength = (Get-Item -LiteralPath $rollbackReceiptPath).Length
    ReceiptSha256 = Get-Sha256Hex $rollbackReceiptPath
    ProtectedReceiptPath = $protectedRollbackReceiptPath
} | ConvertTo-Json -Depth 8
