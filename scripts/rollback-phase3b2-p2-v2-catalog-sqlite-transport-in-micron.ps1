[CmdletBinding()]
param(
    [string]$BackupRoot =
        'C:\NLL\Backups\Phase3B2\PhysicalP2-CatalogSqliteTransport-v1'
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

function Copy-ExactFile {
    param([string]$Source, [string]$Destination)
    $parent = Split-Path -Parent $Destination
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    Assert-True ((Get-Item -LiteralPath $Source).Length -eq
            (Get-Item -LiteralPath $Destination).Length -and
        (Get-Sha256Hex $Source) -ceq (Get-Sha256Hex $Destination)) `
        'phase3b2_catalog_transport_rollback_copy_failed'
}

Assert-True (([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    'phase3b2_catalog_transport_rollback_requires_administrator'
$bootDisk = Get-Partition -DriveLetter C | Get-Disk
Assert-True ($bootDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK' -and
    $bootDisk.IsBoot -and $bootDisk.IsSystem) `
    'phase3b2_catalog_transport_rollback_wrong_boot_disk'
$runtimeNames = @(
    'EpinelPS', 'nikke', 'nikke_launcher',
    'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
)
Assert-True (@(Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $runtimeNames -contains $_.ProcessName }).Count -eq 0) `
    'phase3b2_catalog_transport_rollback_runtime_not_cold'

$manifestPath = Join-Path $BackupRoot 'backup.manifest.json'
Assert-True (Test-Path -LiteralPath $manifestPath -PathType Leaf) `
    'phase3b2_catalog_transport_rollback_manifest_missing'
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($manifest.contractId -ceq
        'nll/phase3b2-p2-v2-catalog-sqlite-transport-backup/v1' -and
    @($manifest.members).Count -eq [int]$manifest.memberCount) `
    'phase3b2_catalog_transport_rollback_manifest_invalid'

foreach ($member in @($manifest.members)) {
    $backupPath = Join-Path $BackupRoot ([string]$member.backupFileName)
    Assert-True ((Test-Path -LiteralPath $backupPath -PathType Leaf) -and
        (Get-Item -LiteralPath $backupPath).Length -eq
            [long]$member.byteLength -and
        (Get-Sha256Hex $backupPath) -ceq [string]$member.sha256) `
        'phase3b2_catalog_transport_rollback_backup_digest_invalid'
    Copy-ExactFile $backupPath ([string]$member.targetPathAtMicronBoot)
}

$headerPath =
    'C:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\cache\prdenv\150-b059c3f36c\StandaloneWindows64\pck\latest-651.txt'
if (-not [bool]$manifest.projectedHeaderPreexisting -and
        (Test-Path -LiteralPath $headerPath -PathType Leaf)) {
    Remove-Item -LiteralPath $headerPath -Force
}
$authorizationPath =
    'C:\NLL\Evidence\Phase3B2\Physical\p2-tool-transfer-v2\catalog-sqlite-transport-repair.receipt.json'
if (Test-Path -LiteralPath $authorizationPath -PathType Leaf) {
    Remove-Item -LiteralPath $authorizationPath -Force
}
$transportConsumptionPath =
    'C:\NLL\Evidence\Phase3B2\Physical\p2-client-start-v2\catalog-sqlite-transport-retry.consumed.json'
if (Test-Path -LiteralPath $transportConsumptionPath -PathType Leaf) {
    Remove-Item -LiteralPath $transportConsumptionPath -Force
}

[ordered]@{
    contractId = 'nll/phase3b2-p2-v2-catalog-sqlite-transport-rollback/v1'
    rolledBackAtUtc =
        [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    restoredMemberCount = @($manifest.members).Count
    projectedHeaderRemoved = -not [bool]$manifest.projectedHeaderPreexisting
    authorizationRemoved = $true
    transportConsumptionRemoved = $true
    runtimeStarted = $false
    clientExecutionStarted = $false
} | ConvertTo-Json -Depth 6
