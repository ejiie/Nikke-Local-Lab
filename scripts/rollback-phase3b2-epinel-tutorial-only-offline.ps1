#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$RevisionUid,
    [ValidatePattern('^[A-Z]$')]
    [string]$MicronDriveLetter = 'E'
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
) 'phase3b2_epinel_tutorial_rollback_wrong_disk_boundary'
$runtimeProcesses = @(Get-Process -Name @(
        'EpinelPS', 'NIKKE', 'nikke_launcher',
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
    ) -ErrorAction SilentlyContinue)
Assert-True ($runtimeProcesses.Count -eq 0) `
    'phase3b2_epinel_tutorial_rollback_runtime_not_cold'

$serverRoot = Join-Path $micronDrive (
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
)
$databasePath = Join-Path $serverRoot 'db.json'
$backupRoot = Join-Path $micronDrive (
    'NLL\Backups\Phase3B2\EpinelTutorialOnly-v1\' + $RevisionUid
)
$receiptPath = Join-Path $micronDrive (
    'NLL\Evidence\Phase3B2\Physical\epinel-tutorial-only-v1\' +
    $RevisionUid + '\materialization.receipt.json'
)
$beforePath = Join-Path $backupRoot 'db.before.json'
$afterPath = Join-Path $backupRoot 'db.after.json'
$rollbackReceiptPath = Join-Path $backupRoot 'rollback.receipt.json'
$activePointerPath = Join-Path $micronDrive (
    'NLL\Evidence\Phase3B2\Physical\epinel-minimal-reference-v1\' +
    'active-run.pointer.json'
)
Assert-True (
    (Test-Path -LiteralPath $databasePath -PathType Leaf) -and
    (Test-Path -LiteralPath $receiptPath -PathType Leaf) -and
    (Test-Path -LiteralPath $beforePath -PathType Leaf) -and
    (Test-Path -LiteralPath $afterPath -PathType Leaf) -and
    -not (Test-Path -LiteralPath $rollbackReceiptPath) -and
    -not (Test-Path -LiteralPath $activePointerPath)
) 'phase3b2_epinel_tutorial_rollback_input_shape_invalid'

$receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True (
    $receipt.contractId -ceq
        'nll/phase3b2-epinel-tutorial-only-materialization/v1' -and
    $receipt.revisionUid -ceq $RevisionUid -and
    (Get-Sha256Hex $databasePath) -ceq $receipt.databaseAfterSha256 -and
    (Get-Sha256Hex $afterPath) -ceq $receipt.databaseAfterSha256 -and
    (Get-Sha256Hex $beforePath) -ceq $receipt.databaseBeforeSha256
) 'phase3b2_epinel_tutorial_rollback_digest_invalid'

$candidatePath = Join-Path $serverRoot (
    '.db.tutorial-rollback-' + [Guid]::NewGuid().ToString('N') + '.json'
)
$swapPath = Join-Path $backupRoot 'db.rollback-swap.json'
try {
    Copy-Item -LiteralPath $beforePath -Destination $candidatePath
    [IO.File]::Replace($candidatePath, $databasePath, $swapPath)
    Assert-True (
        (Get-Sha256Hex $databasePath) -ceq $receipt.databaseBeforeSha256 -and
        (Get-Sha256Hex $swapPath) -ceq $receipt.databaseAfterSha256
    ) 'phase3b2_epinel_tutorial_rollback_replace_invalid'
    Remove-Item -LiteralPath $swapPath -Force
}
finally {
    if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
        Remove-Item -LiteralPath $candidatePath -Force
    }
}

$rollbackReceipt = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-epinel-tutorial-only-rollback/v1'
    rolledBackAtUtc = [DateTimeOffset]::UtcNow.ToString(
        "yyyy-MM-dd'T'HH:mm:ss'Z'"
    )
    revisionUid = $RevisionUid
    databaseBeforeTutorialSha256 = $receipt.databaseBeforeSha256
    databaseTutorialStateSha256 = $receipt.databaseAfterSha256
    databaseRestored = $true
    cacheMutationPerformed = $false
    serverBinaryMutationPerformed = $false
    officialOutboundUsed = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
    nextStepCode = 'golden_lobby_baseline_restored'
}
Write-AtomicUtf8NoBom $rollbackReceiptPath (
    ($rollbackReceipt | ConvertTo-Json -Depth 5) + "`n"
)
$rollbackReceipt | ConvertTo-Json -Depth 5
