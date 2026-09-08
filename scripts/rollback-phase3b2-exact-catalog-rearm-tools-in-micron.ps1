[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-PathDigest {
    param([string]$Path, [long]$ByteLength, [string]$Sha256)
    (Test-Path -LiteralPath $Path -PathType Leaf) -and
        (Get-Item -LiteralPath $Path).Length -eq $ByteLength -and
        (Get-Sha256Hex $Path) -ceq $Sha256
}

function Write-AtomicUtf8NoBom {
    param([string]$Path, [string]$Text)
    $temporaryPath = $Path + '.tmp.' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText(
            $temporaryPath, $Text, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

Assert-True (([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    'phase3b2_catalog_rearm_tool_rollback_requires_administrator'
$runtimeNames = @(
    'EpinelPS', 'nikke', 'nikke_launcher',
    'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
)
Assert-True (@(Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $runtimeNames -contains $_.ProcessName }).Count -eq 0) `
    'phase3b2_catalog_rearm_tool_rollback_runtime_not_cold'

$systemDriveRoot = [IO.Path]::GetFullPath($env:SystemDrive + '\')
$backupRoot = Join-Path $systemDriveRoot `
    'NLL\Backups\Phase3B2\PhysicalP2-ExactCatalogRearmTools-v1'
$backupWrapperPath = Join-Path $backupRoot `
    'Start-Phase3B2-Physical-P2-V2.ps1'
$targetWrapperPath = Join-Path $systemDriveRoot `
    'NLL\Tools\Start-Phase3B2-Physical-P2-V2.ps1'
$deploymentRoot = Join-Path $systemDriveRoot `
    'NLL\Evidence\Phase3B2\Physical\catalog-set-v1\bf669c3c-fcc8-4d57-9f18-32fee1288862'
$repairReceiptPath = Join-Path $deploymentRoot `
    'rearm-tools.receipt.json'
$rollbackReceiptPath = Join-Path $deploymentRoot `
    'rearm-tools.rollback.receipt.json'

Assert-True ((Test-Path -LiteralPath $repairReceiptPath -PathType Leaf) -and
    -not (Test-Path -LiteralPath $rollbackReceiptPath)) `
    'phase3b2_catalog_rearm_tool_rollback_receipt_shape_invalid'
$repair = Get-Content -LiteralPath $repairReceiptPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($repair.contractId -ceq
        'nll/phase3b2-exact-catalog-rearm-tool-deployment/v1' -and
    (Test-PathDigest $targetWrapperPath `
        ([long]$repair.appliedWrapperByteLength) `
        ([string]$repair.appliedWrapperSha256)) -and
    (Test-PathDigest $backupWrapperPath `
        ([long]$repair.originalWrapperByteLength) `
        ([string]$repair.originalWrapperSha256))) `
    'phase3b2_catalog_rearm_tool_rollback_digest_invalid'
Copy-Item -LiteralPath $backupWrapperPath -Destination $targetWrapperPath -Force
Assert-True (Test-PathDigest $targetWrapperPath `
    ([long]$repair.originalWrapperByteLength) `
    ([string]$repair.originalWrapperSha256)) `
    'phase3b2_catalog_rearm_tool_rollback_restore_failed'

$receipt = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-exact-catalog-rearm-tool-rollback/v1'
    rolledBackAtUtc =
        [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    restoredWrapperByteLength = [long]$repair.originalWrapperByteLength
    restoredWrapperSha256 = [string]$repair.originalWrapperSha256
    exactCatalogSetPreserved = $true
    exactCatalogRetryToolPreserved = $true
    runtimeStoppedBeforeRollback = $true
    physicalClientModified = $false
    officialOutboundUsed = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
}
Write-AtomicUtf8NoBom $rollbackReceiptPath `
    (($receipt | ConvertTo-Json -Depth 5) + "`n")
$receipt | ConvertTo-Json -Depth 5
