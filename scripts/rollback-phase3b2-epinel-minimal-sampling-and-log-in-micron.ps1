param(
    [string]$ServerRoot =
        'C:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64',
    [string]$BackupRoot =
        'C:\NLL\Backups\Phase3B2\EpinelMinimalSamplingLogRepair-v1',
    [string]$EvidenceRoot =
        'C:\NLL\Evidence\Phase3B2\Physical\epinel-minimal-sampling-log-repair-v1'
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

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
Assert-True (
    $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
) 'phase3b2_epinel_minimal_sampling_log_rollback_requires_administrator'

$receiptPath = Join-Path $EvidenceRoot 'repair.receipt.json'
$serverRootBefore = Join-Path $BackupRoot 'server-root-before'
$startBackupPath = Join-Path $BackupRoot `
    'tools-before\start-phase3b2-epinel-minimal-reference-in-micron.ps1'
$completeBackupPath = Join-Path $BackupRoot `
    'tools-before\complete-phase3b2-epinel-minimal-reference-in-micron.ps1'
$startPath =
    'C:\NLL\Tools\start-phase3b2-epinel-minimal-reference-in-micron.ps1'
$completePath =
    'C:\NLL\Tools\complete-phase3b2-epinel-minimal-reference-in-micron.ps1'

Assert-True (
    (Test-Path -LiteralPath $receiptPath -PathType Leaf) -and
    (Test-Path -LiteralPath $serverRootBefore -PathType Container) -and
    (Test-Path -LiteralPath $startBackupPath -PathType Leaf) -and
    (Test-Path -LiteralPath $completeBackupPath -PathType Leaf) -and
    (Test-Path -LiteralPath $ServerRoot -PathType Container) -and
    @(Get-Process -Name EpinelPS, nikke, nikke_launcher,
        NikkeLocalLab.Phase3B2.PhysicalBootstrap `
        -ErrorAction SilentlyContinue).Count -eq 0
) 'phase3b2_epinel_minimal_sampling_log_rollback_input_invalid'

$receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True (
    $receipt.contractId -ceq `
        'nll/phase3b2-epinel-minimal-sampling-log-repair/v1' -and
    $receipt.deploymentApplied -and
    -not $receipt.serverExecutionStarted -and
    -not $receipt.clientExecutionStarted
) 'phase3b2_epinel_minimal_sampling_log_rollback_receipt_invalid'

$failedRoot = Join-Path $BackupRoot 'server-root-after-rollback'
Assert-True (-not (Test-Path -LiteralPath $failedRoot)) `
    'phase3b2_epinel_minimal_sampling_log_rollback_destination_exists'

Move-Item -LiteralPath $ServerRoot -Destination $failedRoot
Move-Item -LiteralPath $serverRootBefore -Destination $ServerRoot
Copy-Item -LiteralPath $startBackupPath -Destination $startPath -Force
Copy-Item -LiteralPath $completeBackupPath -Destination $completePath -Force

$rollbackReceipt = [ordered]@{
    schemaVersion = 1
    contractId = `
        'nll/phase3b2-epinel-minimal-sampling-log-rollback/v1'
    rolledBackAtUtc = [DateTimeOffset]::UtcNow.ToString(
        "yyyy-MM-dd'T'HH:mm:ss'Z'"
    )
    repairReceiptSha256 = Get-Sha256Hex $receiptPath
    priorServerRootRestored = $true
    repairedServerRootPreserved = $true
    priorStartToolRestored = $true
    priorCompletionToolRestored = $true
    serverExecutionStarted = $false
    clientExecutionStarted = $false
}
$rollbackReceiptPath = Join-Path $EvidenceRoot 'rollback.receipt.json'
[IO.File]::WriteAllText(
    $rollbackReceiptPath,
    (($rollbackReceipt | ConvertTo-Json) + "`n"),
    [Text.UTF8Encoding]::new($false)
)
$rollbackReceipt | ConvertTo-Json
