[CmdletBinding()]
param(
    [string]$PointerPath =
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

function Write-AtomicUtf8NoBom {
    param([string]$Path, [string]$Text)
    $temporaryPath = $Path + '.tmp.' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText(
            $temporaryPath, $Text, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $Path
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Get-ContainedPath {
    param([string]$Root, [string]$RelativePath, [string]$FailureCode)
    $normalized = $RelativePath.Replace('/', '\')
    Assert-True (-not [IO.Path]::IsPathRooted($normalized) -and
        $normalized -notmatch '(^|\\)\.\.(\\|$)' -and
        $normalized -notmatch ':') $FailureCode
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $fullPath = [IO.Path]::GetFullPath((Join-Path $fullRoot $normalized))
    Assert-True ($fullPath.StartsWith(
        $fullRoot + '\', [StringComparison]::OrdinalIgnoreCase)) $FailureCode
    $fullPath
}

Assert-True (([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    'phase3b2_catalog_rollback_requires_administrator'
$runtimeNames = @(
    'EpinelPS', 'nikke', 'nikke_launcher',
    'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
)
Assert-True (@(Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $runtimeNames -contains $_.ProcessName }).Count -eq 0) `
    'phase3b2_catalog_rollback_runtime_not_cold'
Assert-True (Test-Path -LiteralPath $PointerPath -PathType Leaf) `
    'phase3b2_catalog_rollback_pointer_missing'
$pointer = Get-Content -LiteralPath $PointerPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($pointer.contractId -ceq
    'nll/phase3b2-exact-catalog-offline-deployment-pointer/v1') `
    'phase3b2_catalog_rollback_pointer_invalid'
$evidenceRoot = Split-Path -Parent $PointerPath
$deploymentRoot = Get-ContainedPath $evidenceRoot `
    ([string]$pointer.deploymentUid) `
    'phase3b2_catalog_rollback_deployment_path_invalid'
$privateManifestPath = Join-Path $deploymentRoot 'deployment.private.json'
Assert-True (
    (Get-Item -LiteralPath $privateManifestPath).Length -eq
        $pointer.privateManifestByteLength -and
    (Get-Sha256Hex $privateManifestPath) -ceq
        $pointer.privateManifestSha256
) 'phase3b2_catalog_rollback_private_manifest_invalid'
$manifest = Get-Content -LiteralPath $privateManifestPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
Assert-True ($manifest.contractId -ceq
        'nll/phase3b2-exact-catalog-offline-deployment-private/v1' -and
    $manifest.deploymentUid -ceq $pointer.deploymentUid) `
    'phase3b2_catalog_rollback_contract_invalid'
$systemDriveRoot = [IO.Path]::GetFullPath($env:SystemDrive + '\')
$serverCacheRoot = Join-Path $systemDriveRoot `
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\cache'
$backupRoot = Join-Path $systemDriveRoot `
    'NLL\Backups\Phase3B2\PhysicalP2-CatalogSet-v1'

foreach ($member in @($manifest.members)) {
    $runtimePath = Get-ContainedPath $serverCacheRoot `
        $member.relativePath 'phase3b2_catalog_rollback_target_path_invalid'
    Assert-True (Test-Path -LiteralPath $runtimePath -PathType Leaf) `
        'phase3b2_catalog_rollback_applied_target_missing'
    Assert-True (
        (Get-Item -LiteralPath $runtimePath).Length -eq $member.byteLength -and
        (Get-Sha256Hex $runtimePath) -ceq $member.sha256
    ) 'phase3b2_catalog_rollback_applied_target_changed'
}

$reverseMembers = @($manifest.members)
[Array]::Reverse($reverseMembers)
foreach ($member in $reverseMembers) {
    $runtimePath = Get-ContainedPath $serverCacheRoot `
        $member.relativePath 'phase3b2_catalog_rollback_target_path_invalid'
    if ($member.targetPreexisting) {
        $backupPath = Get-ContainedPath $backupRoot `
            $member.relativePath 'phase3b2_catalog_rollback_backup_path_invalid'
        Assert-True (Test-Path -LiteralPath $backupPath -PathType Leaf) `
            'phase3b2_catalog_rollback_backup_missing'
        Assert-True (
            (Get-Item -LiteralPath $backupPath).Length -eq
                $member.backupByteLength -and
            (Get-Sha256Hex $backupPath) -ceq $member.backupSha256
        ) 'phase3b2_catalog_rollback_backup_changed'
        Copy-Item -LiteralPath $backupPath -Destination $runtimePath -Force
    }
    else { Remove-Item -LiteralPath $runtimePath -Force }
}

$receipt = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-exact-catalog-offline-rollback/v1'
    rolledBackAtUtc =
        [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    deploymentUid = $manifest.deploymentUid
    restoredPreexistingMemberCount = @(
        $manifest.members | Where-Object targetPreexisting).Count
    removedCreatedMemberCount = @(
        $manifest.members | Where-Object { -not $_.targetPreexisting }).Count
    runtimeStoppedBeforeRollback = $true
    physicalClientModified = $false
    primaryInstallModified = $false
    officialLauncherModified = $false
    officialOutboundUsed = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
}
$receiptPath = Join-Path $deploymentRoot `
    'rollback.receipt.json'
Assert-True (-not (Test-Path -LiteralPath $receiptPath)) `
    'phase3b2_catalog_rollback_receipt_already_exists'
Write-AtomicUtf8NoBom $receiptPath `
    (($receipt | ConvertTo-Json -Depth 6) + "`n")
$receipt | ConvertTo-Json -Depth 6
