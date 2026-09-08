[CmdletBinding()]
param(
    [string]$CatalogPointerPath =
        'C:\NLL\Evidence\Phase3B2\Physical\catalog-set-v1\latest.pointer.json'
)

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
    'phase3b2_catalog_retry_tool_rollback_requires_administrator'
$runtimeNames = @(
    'EpinelPS', 'nikke', 'nikke_launcher',
    'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
)
Assert-True (@(Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $runtimeNames -contains $_.ProcessName }).Count -eq 0) `
    'phase3b2_catalog_retry_tool_rollback_runtime_not_cold'
Assert-True (Test-PathDigest $CatalogPointerPath 707L `
    '5b015177c6b17339cb13989f9056d024831c1b03ff6544c4bcaeb4d676fc47a8') `
    'phase3b2_catalog_retry_tool_rollback_pointer_invalid'
$pointer = Get-Content -LiteralPath $CatalogPointerPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($pointer.contractId -ceq
        'nll/phase3b2-exact-catalog-offline-deployment-pointer/v1' -and
    $pointer.deploymentUid -ceq 'bf669c3c-fcc8-4d57-9f18-32fee1288862') `
    'phase3b2_catalog_retry_tool_rollback_deployment_invalid'

$systemDriveRoot = [IO.Path]::GetFullPath($env:SystemDrive + '\')
$evidenceRoot = Join-Path $systemDriveRoot `
    'NLL\Evidence\Phase3B2\Physical\catalog-set-v1\bf669c3c-fcc8-4d57-9f18-32fee1288862'
$repairReceiptPath = Join-Path $evidenceRoot 'retry-tools.receipt.json'
$rollbackReceiptPath = Join-Path $evidenceRoot `
    'retry-tools.rollback.receipt.json'
$backupRoot = Join-Path $systemDriveRoot `
    'NLL\Backups\Phase3B2\PhysicalP2-ExactCatalogRetryTools-v1'
$backupStartPath = Join-Path $backupRoot `
    'start-phase3b2-physical-p2-v2-client-in-micron.ps1'
$targetStartPath = Join-Path $systemDriveRoot `
    'NLL\Tools\start-phase3b2-physical-p2-v2-client-in-micron.ps1'

Assert-True ((Test-Path -LiteralPath $repairReceiptPath -PathType Leaf) -and
    -not (Test-Path -LiteralPath $rollbackReceiptPath)) `
    'phase3b2_catalog_retry_tool_rollback_receipt_shape_invalid'
$repairReceipt = Get-Content -LiteralPath $repairReceiptPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
Assert-True ($repairReceipt.contractId -ceq
        'nll/phase3b2-exact-catalog-retry-tool-deployment/v1' -and
    $repairReceipt.catalogDeploymentUid -ceq $pointer.deploymentUid -and
    (Test-PathDigest $targetStartPath `
        ([long]$repairReceipt.appliedStartToolByteLength) `
        ([string]$repairReceipt.appliedStartToolSha256)) -and
    (Test-PathDigest $backupStartPath `
        ([long]$repairReceipt.originalStartToolByteLength) `
        ([string]$repairReceipt.originalStartToolSha256))) `
    'phase3b2_catalog_retry_tool_rollback_digest_invalid'

Copy-Item -LiteralPath $backupStartPath -Destination $targetStartPath -Force
Assert-True (Test-PathDigest $targetStartPath `
    ([long]$repairReceipt.originalStartToolByteLength) `
    ([string]$repairReceipt.originalStartToolSha256)) `
    'phase3b2_catalog_retry_tool_rollback_restore_failed'

$receipt = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-exact-catalog-retry-tool-rollback/v1'
    rolledBackAtUtc =
        [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    catalogDeploymentUid = [string]$pointer.deploymentUid
    restoredStartToolByteLength =
        [long]$repairReceipt.originalStartToolByteLength
    restoredStartToolSha256 = [string]$repairReceipt.originalStartToolSha256
    exactCatalogSetPreserved = $true
    runtimeStoppedBeforeRollback = $true
    physicalClientModified = $false
    primaryInstallModified = $false
    officialLauncherModified = $false
    officialOutboundUsed = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
}
Write-AtomicUtf8NoBom $rollbackReceiptPath `
    (($receipt | ConvertTo-Json -Depth 6) + "`n")
$receipt | ConvertTo-Json -Depth 6
