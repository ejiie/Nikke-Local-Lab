[CmdletBinding()]
param(
    [string]$MicronDrive = 'E:',
    [string]$CatalogDeploymentUid =
        'bf669c3c-fcc8-4d57-9f18-32fee1288862'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

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
    'phase3b2_catalog_retry_tool_deploy_runtime_not_cold'
$bootDisk = Get-Partition -DriveLetter C | Get-Disk
$micronDisk = Get-Partition -DriveLetter $MicronDrive.TrimEnd(':') | Get-Disk
Assert-True ($bootDisk.FriendlyName -ceq 'Samsung SSD 980 1TB' -and
    $bootDisk.IsBoot -and $bootDisk.IsSystem -and
    $micronDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK' -and
    -not $micronDisk.IsBoot -and -not $micronDisk.IsSystem) `
    'phase3b2_catalog_retry_tool_deploy_disk_boundary_invalid'

$pointerPath = Join-Path $MicronDrive `
    'NLL\Evidence\Phase3B2\Physical\catalog-set-v1\latest.pointer.json'
Assert-True (Test-PathDigest $pointerPath 707L `
    '5b015177c6b17339cb13989f9056d024831c1b03ff6544c4bcaeb4d676fc47a8') `
    'phase3b2_catalog_retry_tool_deploy_pointer_invalid'
$pointer = Get-Content -LiteralPath $pointerPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($pointer.contractId -ceq
        'nll/phase3b2-exact-catalog-offline-deployment-pointer/v1' -and
    $pointer.deploymentUid -ceq $CatalogDeploymentUid -and
    [long]$pointer.deploymentReceiptByteLength -eq 1464L -and
    $pointer.deploymentReceiptSha256 -ceq
        '27ec27253b56fae39967a5714a315a862908a268a62a7083d45f85df9de592f6' -and
    [long]$pointer.privateManifestByteLength -eq 2677L -and
    $pointer.privateManifestSha256 -ceq
        '919a8f6c658a839aa882e3f2e12a9bbedce6e7bec765a8765a160e52adecf39c') `
    'phase3b2_catalog_retry_tool_deploy_pointer_contract_invalid'

$catalogBase = Split-Path -Parent $pointerPath
$deploymentRoot = Get-ContainedPath $catalogBase $CatalogDeploymentUid `
    'phase3b2_catalog_retry_tool_deploy_evidence_path_invalid'
$deploymentReceiptPath = Join-Path $deploymentRoot 'deployment.receipt.json'
$privateManifestPath = Join-Path $deploymentRoot 'deployment.private.json'
Assert-True ((Test-PathDigest $deploymentReceiptPath 1464L `
        '27ec27253b56fae39967a5714a315a862908a268a62a7083d45f85df9de592f6') -and
    (Test-PathDigest $privateManifestPath 2677L `
        '919a8f6c658a839aa882e3f2e12a9bbedce6e7bec765a8765a160e52adecf39c')) `
    'phase3b2_catalog_retry_tool_deploy_evidence_digest_invalid'
$deployment = Get-Content -LiteralPath $deploymentReceiptPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
$manifest = Get-Content -LiteralPath $privateManifestPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
Assert-True ($deployment.contractId -ceq
        'nll/phase3b2-exact-catalog-offline-deployment/v1' -and
    $deployment.deploymentUid -ceq $CatalogDeploymentUid -and
    $deployment.acquisitionAssessmentUid -ceq
        '3307c851-bd77-4f38-8808-91ddb3b7800d' -and
    $deployment.acquisitionReceiptSha256 -ceq
        '87d22ab630bea3851ad3af6b8a2b3be009c7f49b9320529186261bb38c24ae92' -and
    [int]$deployment.appliedMemberCount -eq 6 -and
    [int]$deployment.exactAppliedTargetCount -eq 6 -and
    -not $deployment.officialOutboundUsed -and
    -not $deployment.clientExecutionStarted -and
    $manifest.contractId -ceq
        'nll/phase3b2-exact-catalog-offline-deployment-private/v1' -and
    $manifest.deploymentUid -ceq $CatalogDeploymentUid -and
    @($manifest.members).Count -eq 6) `
    'phase3b2_catalog_retry_tool_deploy_catalog_contract_invalid'

$runtimeCacheRoot = Join-Path $MicronDrive `
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\cache'
foreach ($member in @($manifest.members)) {
    $runtimePath = Get-ContainedPath $runtimeCacheRoot `
        ([string]$member.relativePath) `
        'phase3b2_catalog_retry_tool_deploy_runtime_path_invalid'
    Assert-True (Test-PathDigest $runtimePath ([long]$member.byteLength) `
        ([string]$member.sha256)) `
        'phase3b2_catalog_retry_tool_deploy_runtime_digest_invalid'
}

$sourceStartPath = Join-Path $PSScriptRoot `
    'start-phase3b2-physical-p2-v2-client-in-micron.ps1'
$sourceCatalogRollbackPath = Join-Path $PSScriptRoot `
    'rollback-phase3b2-sealed-catalog-set-in-micron.ps1'
$sourceToolRollbackPath = Join-Path $PSScriptRoot `
    'rollback-phase3b2-exact-catalog-retry-tools-in-micron.ps1'
$targetToolsRoot = Join-Path $MicronDrive 'NLL\Tools'
$targetStartPath = Join-Path $targetToolsRoot `
    'start-phase3b2-physical-p2-v2-client-in-micron.ps1'
$targetCatalogRollbackPath = Join-Path $targetToolsRoot `
    'Rollback-Phase3B2-Sealed-Catalog-Set-Portable.ps1'
$targetToolRollbackPath = Join-Path $targetToolsRoot `
    'Rollback-Phase3B2-Exact-Catalog-Retry-Tools.ps1'
$backupRoot = Join-Path $MicronDrive `
    'NLL\Backups\Phase3B2\PhysicalP2-ExactCatalogRetryTools-v1'
$backupStartPath = Join-Path $backupRoot `
    'start-phase3b2-physical-p2-v2-client-in-micron.ps1'
$backupManifestPath = Join-Path $backupRoot 'backup.manifest.json'
$repairReceiptPath = Join-Path $deploymentRoot 'retry-tools.receipt.json'

Assert-True ((Test-PathDigest $sourceStartPath 99381L `
        '5417964589cbd0c4cf514e8e6fc887799d5cd056408d54041098a3b0f20bf579') -and
    (Test-PathDigest $sourceCatalogRollbackPath 5998L `
        'aeb63d356fdd92136f4a6332651e7f0c60ef343a41c222307f13d1afe7fb0f74') -and
    (Test-PathDigest $sourceToolRollbackPath 4980L `
        '5a3c9e807edce8ea500d83b01344c53aad85996d2737980d2576e899d0c1271c') -and
    (Test-PathDigest $targetStartPath 88527L `
        '5331e6bf6c2b8b4c9261fe4d614f1003d2b8865f75463090298e676fd13e91d7') -and
    -not (Test-Path -LiteralPath $backupRoot) -and
    -not (Test-Path -LiteralPath $repairReceiptPath) -and
    -not (Test-Path -LiteralPath $targetCatalogRollbackPath) -and
    -not (Test-Path -LiteralPath $targetToolRollbackPath)) `
    'phase3b2_catalog_retry_tool_deploy_source_or_target_invalid'

New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
Copy-Item -LiteralPath $targetStartPath -Destination $backupStartPath
$backupManifest = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-exact-catalog-retry-tool-backup/v1'
    catalogDeploymentUid = $CatalogDeploymentUid
    originalStartToolByteLength = 88527L
    originalStartToolSha256 =
        '5331e6bf6c2b8b4c9261fe4d614f1003d2b8865f75463090298e676fd13e91d7'
    appliedStartToolByteLength = 99381L
    appliedStartToolSha256 =
        '5417964589cbd0c4cf514e8e6fc887799d5cd056408d54041098a3b0f20bf579'
}
Write-AtomicUtf8NoBom $backupManifestPath `
    (($backupManifest | ConvertTo-Json -Depth 6) + "`n")

Copy-Item -LiteralPath $sourceStartPath -Destination $targetStartPath -Force
Copy-Item -LiteralPath $sourceCatalogRollbackPath `
    -Destination $targetCatalogRollbackPath
Copy-Item -LiteralPath $sourceToolRollbackPath `
    -Destination $targetToolRollbackPath
Assert-True ((Test-PathDigest $targetStartPath 99381L `
        '5417964589cbd0c4cf514e8e6fc887799d5cd056408d54041098a3b0f20bf579') -and
    (Test-PathDigest $targetCatalogRollbackPath 5998L `
        'aeb63d356fdd92136f4a6332651e7f0c60ef343a41c222307f13d1afe7fb0f74') -and
    (Test-PathDigest $targetToolRollbackPath 4980L `
        '5a3c9e807edce8ea500d83b01344c53aad85996d2737980d2576e899d0c1271c')) `
    'phase3b2_catalog_retry_tool_deploy_copy_invalid'

$receipt = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-exact-catalog-retry-tool-deployment/v1'
    deployedAtUtc =
        [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    catalogDeploymentUid = $CatalogDeploymentUid
    catalogDeploymentReceiptSha256 = [string]$pointer.deploymentReceiptSha256
    catalogPrivateManifestSha256 = [string]$pointer.privateManifestSha256
    exactCatalogMemberCount = 6
    originalStartToolByteLength = 88527L
    originalStartToolSha256 =
        '5331e6bf6c2b8b4c9261fe4d614f1003d2b8865f75463090298e676fd13e91d7'
    appliedStartToolByteLength = 99381L
    appliedStartToolSha256 =
        '5417964589cbd0c4cf514e8e6fc887799d5cd056408d54041098a3b0f20bf579'
    portableCatalogRollbackToolByteLength = 5998L
    portableCatalogRollbackToolSha256 =
        'aeb63d356fdd92136f4a6332651e7f0c60ef343a41c222307f13d1afe7fb0f74'
    retryToolRollbackByteLength = 4980L
    retryToolRollbackSha256 =
        '5a3c9e807edce8ea500d83b01344c53aad85996d2737980d2576e899d0c1271c'
    backupManifestByteLength = (Get-Item $backupManifestPath).Length
    backupManifestSha256 = Get-Sha256Hex $backupManifestPath
    singleExactCatalogRetryAuthorized = $true
    retryConsumed = $false
    targetOsOfflineDuringDeployment = $true
    exactCatalogSetPreserved = $true
    physicalClientModified = $false
    primaryInstallModified = $false
    officialLauncherModified = $false
    officialOutboundUsed = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
    nextStepCode = 'boot_micron_as_nlloperator_and_run_exact_catalog_retry_once'
}
Write-AtomicUtf8NoBom $repairReceiptPath `
    (($receipt | ConvertTo-Json -Depth 8) + "`n")
[pscustomobject]@{
    Receipt = $receipt
    ReceiptPath = $repairReceiptPath
    ReceiptByteLength = (Get-Item $repairReceiptPath).Length
    ReceiptSha256 = Get-Sha256Hex $repairReceiptPath
} | ConvertTo-Json -Depth 10
