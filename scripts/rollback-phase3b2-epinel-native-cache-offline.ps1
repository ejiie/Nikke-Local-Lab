param(
    [string]$ServerRoot =
        'C:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64',
    [string]$EvidenceRoot =
        'C:\NLL\Evidence\Phase3B2\Physical\epinel-native-cache-deployment-v1',
    [string]$BackupRoot =
        'C:\NLL\Backups\Phase3B2\EpinelNativeCacheMaterialization-v1'
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

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText(
        $Path, $Text, [Text.UTF8Encoding]::new($false)
    )
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
Assert-True (
    $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
) 'phase3b2_epinel_native_cache_rollback_requires_administrator'
Assert-True ($env:SystemDrive -ceq 'C:') `
    'phase3b2_epinel_native_cache_rollback_wrong_boot_boundary'

$deploymentPath = Join-Path $EvidenceRoot 'deployment.receipt.json'
$activeCacheRoot = Join-Path $ServerRoot 'cache'
$backupCacheRoot = Join-Path $BackupRoot 'cache-before'
$quarantineRoot = Join-Path $BackupRoot (
    'cache-after-rollback-' +
    [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssZ')
)
$rollbackReceiptPath = Join-Path $EvidenceRoot 'rollback.receipt.json'
$nativeWrapperPath = 'C:\NLL\Tools\Start-Phase3B2-Epinel-NativeCache.ps1'

Assert-True (
    @(Get-Process -Name EpinelPS, nikke, nikke_launcher,
        NikkeLocalLab.Phase3B2.PhysicalBootstrap `
        -ErrorAction SilentlyContinue).Count -eq 0
) 'phase3b2_epinel_native_cache_rollback_runtime_not_cold'
Assert-True (
    (Test-Path -LiteralPath $deploymentPath -PathType Leaf) -and
    (Test-Path -LiteralPath $activeCacheRoot -PathType Container) -and
    (Test-Path -LiteralPath $backupCacheRoot -PathType Container) -and
    -not (Test-Path -LiteralPath $quarantineRoot) -and
    -not (Test-Path -LiteralPath $rollbackReceiptPath)
) 'phase3b2_epinel_native_cache_rollback_shape_invalid'

$deployment = Get-Content -LiteralPath $deploymentPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True (
    $deployment.contractId -ceq `
        'nll/phase3b2-epinel-native-cache-offline-deployment/v1' -and
    $deployment.nativeCacheDeploymentVerified -and
    $deployment.backupCacheFileCount -eq 11 -and
    $deployment.activeCacheFileCount -eq 40108
) 'phase3b2_epinel_native_cache_rollback_contract_invalid'

Move-Item -LiteralPath $activeCacheRoot -Destination $quarantineRoot
try {
    Move-Item -LiteralPath $backupCacheRoot -Destination $activeCacheRoot
}
catch {
    Move-Item -LiteralPath $quarantineRoot -Destination $activeCacheRoot
    throw
}

$restoredFiles = @(Get-ChildItem -LiteralPath $activeCacheRoot -File -Recurse)
Assert-True (
    $restoredFiles.Count -eq 11 -and
    [long](($restoredFiles | Measure-Object Length -Sum).Sum) -eq `
        ([long]$deployment.backupCacheContentByteLength)
) 'phase3b2_epinel_native_cache_rollback_restore_invalid'

if (Test-Path -LiteralPath $nativeWrapperPath -PathType Leaf) {
    Remove-Item -LiteralPath $nativeWrapperPath -Force
}
$receipt = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-epinel-native-cache-rollback/v1'
    rolledBackAtUtc = [DateTimeOffset]::UtcNow.ToString(
        "yyyy-MM-dd'T'HH:mm:ss'Z'"
    )
    deploymentReceiptSha256 = Get-Sha256Hex $deploymentPath
    restoredCacheFileCount = $restoredFiles.Count
    restoredCacheContentByteLength = [long](
        ($restoredFiles | Measure-Object Length -Sum).Sum
    )
    deployedCacheQuarantined = $true
    quarantinePath = $quarantineRoot
    nativeStartWrapperRemoved = $true
    serverExecutionStarted = $false
    clientExecutionStarted = $false
}
Write-Utf8NoBom $rollbackReceiptPath `
    (($receipt | ConvertTo-Json -Depth 5) + "`n")
$receipt | ConvertTo-Json -Depth 5
