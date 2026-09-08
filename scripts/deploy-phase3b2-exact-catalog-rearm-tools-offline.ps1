[CmdletBinding()]
param([string]$MicronDrive = 'E:')

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

$runtimeNames = @(
    'EpinelPS', 'nikke', 'nikke_launcher',
    'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
)
Assert-True (@(Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $runtimeNames -contains $_.ProcessName }).Count -eq 0) `
    'phase3b2_catalog_rearm_tool_deploy_runtime_not_cold'
$bootDisk = Get-Partition -DriveLetter C | Get-Disk
$micronDisk = Get-Partition -DriveLetter $MicronDrive.TrimEnd(':') | Get-Disk
Assert-True ($bootDisk.FriendlyName -ceq 'Samsung SSD 980 1TB' -and
    $bootDisk.IsBoot -and $bootDisk.IsSystem -and
    $micronDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK' -and
    -not $micronDisk.IsBoot -and -not $micronDisk.IsSystem) `
    'phase3b2_catalog_rearm_tool_deploy_disk_boundary_invalid'

$deploymentRoot = Join-Path $MicronDrive `
    'NLL\Evidence\Phase3B2\Physical\catalog-set-v1\bf669c3c-fcc8-4d57-9f18-32fee1288862'
$catalogRetryToolReceiptPath = Join-Path $deploymentRoot `
    'retry-tools.receipt.json'
$priorFailurePath = Join-Path $MicronDrive `
    'NLL\Evidence\Phase3B2\Physical\p2-client-start-v2\1797ba14-cdd4-45e7-9002-b77ddbee3227\run-failure.receipt.json'
$retryConsumptionPath = Join-Path $MicronDrive `
    'NLL\Evidence\Phase3B2\Physical\p2-client-start-v2\exact-catalog-set-retry.consumed.json'
$activePointerPath = Join-Path $MicronDrive `
    'NLL\Evidence\Phase3B2\Physical\p2-client-start-v2\active-run.pointer.json'
$offlineHostsPath = Join-Path $MicronDrive `
    'Windows\System32\drivers\etc\hosts'
Assert-True ((Test-PathDigest $catalogRetryToolReceiptPath 1606L `
        '6d181c40d7da412de9f7861f6e12814a304e848adcb4ebe7b1ab2b69ec6dec19') -and
    (Test-PathDigest $priorFailurePath 1752L `
        '03a6021e6d84d83ad967b5ce4cb6e74abfc01d28fa902ed45aa4182769fdcc76') -and
    (Test-PathDigest $offlineHostsPath 1690L `
        'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0') -and
    -not (Test-Path -LiteralPath $retryConsumptionPath) -and
    -not (Test-Path -LiteralPath $activePointerPath)) `
    'phase3b2_catalog_rearm_tool_deploy_failure_state_invalid'

$sourceWrapperPath = Join-Path $PSScriptRoot `
    'Start-Phase3B2-Physical-P2-V2.ps1'
$sourceRearmPath = Join-Path $PSScriptRoot `
    'rearm-phase3b2-exact-catalog-retry-in-micron.ps1'
$sourceRollbackPath = Join-Path $PSScriptRoot `
    'rollback-phase3b2-exact-catalog-rearm-tools-in-micron.ps1'
$targetToolsRoot = Join-Path $MicronDrive 'NLL\Tools'
$targetWrapperPath = Join-Path $targetToolsRoot `
    'Start-Phase3B2-Physical-P2-V2.ps1'
$targetRearmPath = Join-Path $targetToolsRoot `
    'rearm-phase3b2-exact-catalog-retry-in-micron.ps1'
$targetRollbackPath = Join-Path $targetToolsRoot `
    'Rollback-Phase3B2-Exact-Catalog-Rearm-Tools.ps1'
$backupRoot = Join-Path $MicronDrive `
    'NLL\Backups\Phase3B2\PhysicalP2-ExactCatalogRearmTools-v1'
$backupWrapperPath = Join-Path $backupRoot `
    'Start-Phase3B2-Physical-P2-V2.ps1'
$backupManifestPath = Join-Path $backupRoot 'backup.manifest.json'
$repairReceiptPath = Join-Path $deploymentRoot `
    'rearm-tools.receipt.json'

Assert-True ((Test-PathDigest $sourceWrapperPath 2410L `
        '2dbb29122c95402373f760bc770778f2c1e58797c6efcba4debacd2515582ce0') -and
    (Test-PathDigest $sourceRearmPath 9605L `
        '0c5b5d44d006ce529c7494c2cfda5e0110cae6cf0f91815d7e99714b9d6df9f1') -and
    (Test-PathDigest $sourceRollbackPath 4061L `
        '035b060075c9b32516d5d3fb5ad76e901b8f9c33b99baaf7e7f008ebf3aa844f') -and
    (Test-PathDigest $targetWrapperPath 1745L `
        '4cc5bb3bae775b86f0caae56436b202e9c1355c77e8c0424b25fd2459359b056') -and
    -not (Test-Path -LiteralPath $targetRearmPath) -and
    -not (Test-Path -LiteralPath $targetRollbackPath) -and
    -not (Test-Path -LiteralPath $backupRoot) -and
    -not (Test-Path -LiteralPath $repairReceiptPath)) `
    'phase3b2_catalog_rearm_tool_deploy_source_or_target_invalid'

New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
Copy-Item -LiteralPath $targetWrapperPath -Destination $backupWrapperPath
$backupManifest = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-exact-catalog-rearm-tool-backup/v1'
    originalWrapperByteLength = 1745L
    originalWrapperSha256 =
        '4cc5bb3bae775b86f0caae56436b202e9c1355c77e8c0424b25fd2459359b056'
    appliedWrapperByteLength = 2410L
    appliedWrapperSha256 =
        '2dbb29122c95402373f760bc770778f2c1e58797c6efcba4debacd2515582ce0'
}
Write-AtomicUtf8NoBom $backupManifestPath `
    (($backupManifest | ConvertTo-Json -Depth 5) + "`n")
Copy-Item -LiteralPath $sourceWrapperPath -Destination $targetWrapperPath -Force
Copy-Item -LiteralPath $sourceRearmPath -Destination $targetRearmPath
Copy-Item -LiteralPath $sourceRollbackPath -Destination $targetRollbackPath
Assert-True ((Test-PathDigest $targetWrapperPath 2410L `
        '2dbb29122c95402373f760bc770778f2c1e58797c6efcba4debacd2515582ce0') -and
    (Test-PathDigest $targetRearmPath 9605L `
        '0c5b5d44d006ce529c7494c2cfda5e0110cae6cf0f91815d7e99714b9d6df9f1') -and
    (Test-PathDigest $targetRollbackPath 4061L `
        '035b060075c9b32516d5d3fb5ad76e901b8f9c33b99baaf7e7f008ebf3aa844f')) `
    'phase3b2_catalog_rearm_tool_deploy_copy_invalid'

$receipt = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-exact-catalog-rearm-tool-deployment/v1'
    deployedAtUtc =
        [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    catalogDeploymentUid = 'bf669c3c-fcc8-4d57-9f18-32fee1288862'
    priorFailureAssessmentUid = '1797ba14-cdd4-45e7-9002-b77ddbee3227'
    priorFailureReceiptSha256 =
        '03a6021e6d84d83ad967b5ce4cb6e74abfc01d28fa902ed45aa4182769fdcc76'
    failureCauseCode = 'restored_hosts_with_stale_preparation_receipt'
    originalWrapperByteLength = 1745L
    originalWrapperSha256 =
        '4cc5bb3bae775b86f0caae56436b202e9c1355c77e8c0424b25fd2459359b056'
    appliedWrapperByteLength = 2410L
    appliedWrapperSha256 =
        '2dbb29122c95402373f760bc770778f2c1e58797c6efcba4debacd2515582ce0'
    rearmToolByteLength = 9605L
    rearmToolSha256 =
        '0c5b5d44d006ce529c7494c2cfda5e0110cae6cf0f91815d7e99714b9d6df9f1'
    rollbackToolByteLength = 4061L
    rollbackToolSha256 =
        '035b060075c9b32516d5d3fb5ad76e901b8f9c33b99baaf7e7f008ebf3aa844f'
    backupManifestByteLength = (Get-Item $backupManifestPath).Length
    backupManifestSha256 = Get-Sha256Hex $backupManifestPath
    exactCatalogRetryConsumed = $false
    targetOsOfflineDuringDeployment = $true
    physicalClientModified = $false
    exactCatalogSetModified = $false
    officialOutboundUsed = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
    nextStepCode = 'boot_micron_as_nlloperator_and_run_wrapper_once'
}
Write-AtomicUtf8NoBom $repairReceiptPath `
    (($receipt | ConvertTo-Json -Depth 6) + "`n")
[pscustomobject]@{
    Receipt = $receipt
    ReceiptPath = $repairReceiptPath
    ReceiptByteLength = (Get-Item $repairReceiptPath).Length
    ReceiptSha256 = Get-Sha256Hex $repairReceiptPath
} | ConvertTo-Json -Depth 8
