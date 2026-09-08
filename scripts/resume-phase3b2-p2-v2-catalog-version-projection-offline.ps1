[CmdletBinding()]
param(
    [string]$RepositoryRoot = '',
    [string]$MicronDrive = 'E:',
    [string]$FailedAssessmentUid =
        'bba01e6c-b457-4705-b251-4959006e0bef',
    [string]$BaselineAssessmentUid =
        '78c37245-ea49-442d-becf-b1e871f98d68',
    [string]$SamsungProtectedRoot =
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if (-not $RepositoryRoot) {
    $RepositoryRoot = Split-Path -Parent $PSScriptRoot
}

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

$micronLetter = $MicronDrive.TrimEnd(':')
$systemDisk = Get-Partition -DriveLetter C | Get-Disk
$micronDisk = Get-Partition -DriveLetter $micronLetter | Get-Disk
Assert-True ($systemDisk.FriendlyName -ceq 'Samsung SSD 980 1TB' -and
    $systemDisk.IsBoot -and $systemDisk.IsSystem -and
    $micronDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK' -and
    -not $micronDisk.IsBoot -and -not $micronDisk.IsSystem) `
    'phase3b2_catalog_projection_resume_disk_boundary_invalid'
Assert-True (@(Get-Process -Name EpinelPS, nikke, nikke_launcher,
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap' `
        -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_catalog_projection_resume_runtime_not_cold'

$transferRoot = Join-Path $MicronDrive `
    'NLL\Evidence\Phase3B2\Physical\p2-tool-transfer-v2'
$p2EvidenceRoot = Join-Path $MicronDrive `
    'NLL\Evidence\Phase3B2\Physical\p2-client-start-v2'
$serverRoot = Join-Path $MicronDrive `
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
$cacheRoot = Join-Path $serverRoot 'cache'
$projectionPath = Join-Path $cacheRoot `
    'prdenv\150-b059c3f36c\StandaloneWindows64\pck\latest-651.txt'
$lcvPath = Join-Path $MicronDrive `
    'NLL\Clients\NIKKE-150.6.9-Physical\Unity\com_proximabeta_NIKKE\.lcv.dat'
$gameConfigPath = Join-Path $MicronDrive `
    'NLL\EpinelPS\EpinelPS\gameconfig.json'
$projectionReceiptPath = Join-Path $transferRoot `
    'catalog-version-projection.receipt.json'
$authorizationPath = Join-Path $transferRoot `
    'catalog-version-projection-repair.receipt.json'
$protectedDeploymentRoot = Join-Path $SamsungProtectedRoot 'V2Deployment'
$protectedProjectionPath = Join-Path $protectedDeploymentRoot `
    'catalog-version-projection.receipt.json'
$protectedAuthorizationPath = Join-Path $protectedDeploymentRoot `
    'catalog-version-projection-repair.receipt.json'
$deploymentPath = Join-Path $transferRoot 'deployment.receipt.json'
$protectedDeploymentPath = Join-Path $protectedDeploymentRoot `
    'offline-deployment.receipt.json'
$manifestPath = Join-Path $MicronDrive `
    'NLL\Runtime\PhysicalBootstrap-v2\evidence\tools.manifest.tsv'
$rollbackRoot = Join-Path $MicronDrive `
    'NLL\Backups\Phase3B2\PhysicalP2-CatalogVersionProjection-v1'
$rollbackManifestPath = Join-Path $rollbackRoot 'rollback.manifest.json'
$coldRecoveryPath = Join-Path (Join-Path $p2EvidenceRoot `
    $FailedAssessmentUid) 'cold-recovery-and-catalog-extraction.receipt.json'
$priorInteractiveConsumptionPath = Join-Path $p2EvidenceRoot `
    'baseline-backed-interactive-retry.consumed.json'
$newRetryConsumptionPath = Join-Path $p2EvidenceRoot `
    'catalog-version-projection-retry.consumed.json'
$activePointerPath = Join-Path $p2EvidenceRoot 'active-run.pointer.json'
$archiveSuffix = '.catalog-projection-' + $FailedAssessmentUid
$preparationArchive = Join-Path $MicronDrive `
    ('NLL\Evidence\Phase3B2\Physical\p2-preparation-v2' + $archiveSuffix)
$runtimeBackupArchive = Join-Path $MicronDrive `
    ('NLL\Backups\Phase3B2\PhysicalP2-v2' + $archiveSuffix)
$protectedPreparationArchive =
    (Join-Path $SamsungProtectedRoot 'PreparationV2') + $archiveSuffix
$archivedPreparationReceiptPath = Join-Path $preparationArchive `
    'preparation.receipt.json'

$sourceStartPath = Join-Path $RepositoryRoot `
    'scripts\start-phase3b2-physical-p2-v2-client-in-micron.ps1'
$sourceCompletionPath = Join-Path $RepositoryRoot `
    'scripts\complete-phase3b2-physical-p2-v2-client-in-micron.ps1'
$targetStartPath = Join-Path $MicronDrive `
    'NLL\Tools\start-phase3b2-physical-p2-v2-client-in-micron.ps1'
$targetCompletionPath = Join-Path $MicronDrive `
    'NLL\Tools\complete-phase3b2-physical-p2-v2-client-in-micron.ps1'
$projectionProject = Join-Path $RepositoryRoot `
    'tools\Phase3B2\ContentVersionProjection\NikkeLocalLab.Phase3B2.ContentVersionProjection.csproj'
$projectionDll = Join-Path $RepositoryRoot `
    'tools\Phase3B2\ContentVersionProjection\bin\Release\net10.0\NikkeLocalLab.Phase3B2.ContentVersionProjection.dll'
$dotnetCandidates = @(
    (Join-Path $env:ProgramFiles 'dotnet\dotnet.exe'),
    (Join-Path $MicronDrive 'Program Files\dotnet\dotnet.exe'))
$dotnet = @($dotnetCandidates | Where-Object {
    Test-Path -LiteralPath $_ -PathType Leaf
} | Select-Object -First 1)
Assert-True ($dotnet.Count -eq 1) `
    'phase3b2_catalog_projection_resume_dotnet_missing'
$dotnet = [string]$dotnet[0]

Assert-True ((Test-PathDigest $projectionPath 132L `
        '63f5ddcd289e55717ed0087b44d673837da14423e28bf363fa5f2092ca1a3502') -and
    (Test-PathDigest $lcvPath 3775L `
        'ede45120d1531ea1639dc4237bb8ff0061b356ccefdf8fd53d9edcd98f2e9054') -and
    (Test-PathDigest $gameConfigPath 598L `
        '3a37e274562f80c7fdb1f6b58c579f4b1946c02f0c700ea40cea2f9b7801d152') -and
    (Test-PathDigest $coldRecoveryPath 1605L `
        '0f79f2e295635c5b39bb2523c7cff55403e48d6b10a64e228faa1c05e7029b6d') -and
    (Test-PathDigest $priorInteractiveConsumptionPath 825L `
        '9a31e53b91fe3c4da4c3c0929573e27f2d946ab5bc985ea76925cb703c32e304') -and
    (Test-PathDigest $rollbackManifestPath 798L `
        '1568c0c7586f3b650d912bc11caf1c5b2b6e25746d4952106e7a0899f4a58142') -and
    (Test-PathDigest $manifestPath 799L `
        '0df0687f3b084ac7e75736dd98a6626a7d60f42c47132042f0198d1aad4bda7b') -and
    (Test-PathDigest $deploymentPath 7410L `
        'b562c0336270299a299e9f2b8040351fcc61c46a4eadd345a5fc88ff574e941e') -and
    (Test-PathDigest $protectedDeploymentPath 7410L `
        'b562c0336270299a299e9f2b8040351fcc61c46a4eadd345a5fc88ff574e941e') -and
    (Get-Sha256Hex $targetStartPath) -ceq (Get-Sha256Hex $sourceStartPath) -and
    (Get-Sha256Hex $targetCompletionPath) -ceq
        (Get-Sha256Hex $sourceCompletionPath)) `
    'phase3b2_catalog_projection_resume_applied_state_invalid'
Assert-True ((Test-Path -LiteralPath $preparationArchive -PathType Container) -and
    (Test-Path -LiteralPath $runtimeBackupArchive -PathType Container) -and
    (Test-Path -LiteralPath $protectedPreparationArchive `
        -PathType Container) -and
    -not (Test-Path -LiteralPath (Join-Path $MicronDrive `
        'NLL\Evidence\Phase3B2\Physical\p2-preparation-v2')) -and
    -not (Test-Path -LiteralPath (Join-Path $MicronDrive `
        'NLL\Backups\Phase3B2\PhysicalP2-v2')) -and
    -not (Test-Path -LiteralPath (Join-Path $SamsungProtectedRoot `
        'PreparationV2')) -and
    -not (Test-Path -LiteralPath $activePointerPath) -and
    -not (Test-Path -LiteralPath $newRetryConsumptionPath) -and
    -not (Test-Path -LiteralPath $projectionReceiptPath) -and
    -not (Test-Path -LiteralPath $authorizationPath) -and
    -not (Test-Path -LiteralPath $protectedProjectionPath) -and
    -not (Test-Path -LiteralPath $protectedAuthorizationPath)) `
    'phase3b2_catalog_projection_resume_archive_or_destination_invalid'

$projectionOutput = & $dotnet $projectionDll $lcvPath $gameConfigPath `
    $cacheRoot 2>&1
Assert-True ($LASTEXITCODE -eq 0) `
    'phase3b2_catalog_projection_resume_helper_failed'
$projectionText = ($projectionOutput | Out-String).TrimEnd() + "`n"
$projection = $projectionText | ConvertFrom-Json
Assert-True ($projection.contractId -ceq
        'nll/phase3b2-local-content-version-projection/v1' -and
    [int]$projection.entryCount -eq 7 -and
    $projection.aggregateRevisionMatchesDp -and
    [long]$projection.projectedByteLength -eq 132L -and
    $projection.projectedSha256 -ceq
        '63f5ddcd289e55717ed0087b44d673837da14423e28bf363fa5f2092ca1a3502' -and
    $projection.targetAlreadyMatched -and
    -not $projection.officialOutboundUsed) `
    'phase3b2_catalog_projection_resume_projection_invalid'
Write-AtomicUtf8NoBom $projectionReceiptPath $projectionText
Copy-Item -LiteralPath $projectionReceiptPath `
    -Destination $protectedProjectionPath

$authorization = [ordered]@{
    schemaVersion = 1
    contractId =
        'nll/phase3b2-p2-v2-catalog-version-projection-repair/v1'
    repairedAtUtc =
        [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    repairResumeCode =
        'interrupted_after_apply_before_authorization_receipt'
    failedAssessmentUid = $FailedAssessmentUid
    baselineAssessmentUid = $BaselineAssessmentUid
    sourceCacheMissConfirmed = $true
    coldRecoveryReceiptByteLength = (Get-Item $coldRecoveryPath).Length
    coldRecoveryReceiptSha256 = Get-Sha256Hex $coldRecoveryPath
    localProjectionVerified = $true
    projectionSourceRoleCode =
        'installed_client_serialized_content_version'
    projectedByteLength = 132
    projectedSha256 =
        '63f5ddcd289e55717ed0087b44d673837da14423e28bf363fa5f2092ca1a3502'
    projectionReceiptByteLength = (Get-Item $projectionReceiptPath).Length
    projectionReceiptSha256 = Get-Sha256Hex $projectionReceiptPath
    rollbackManifestByteLength = (Get-Item $rollbackManifestPath).Length
    rollbackManifestSha256 = Get-Sha256Hex $rollbackManifestPath
    baselineTenMinuteMeasurementVerified = $true
    baselineTenMinuteMeasurementSha256 =
        '8af3acdf40a741b6998ff0c2f9278a14b7a2c48246798abf1f1e4214d4bf6538'
    interactiveMeasurementSeconds = 30
    interactiveSampleIntervalSeconds = 2
    liveRuntimeFilesDeferredToCompletion = $true
    endpointContractChanged = $false
    priorInteractiveRetryConsumptionPreserved = $true
    priorInteractiveRetryConsumptionSha256 =
        Get-Sha256Hex $priorInteractiveConsumptionPath
    priorPreparationReceiptSha256 =
        Get-Sha256Hex $archivedPreparationReceiptPath
    priorPreparationArchived = $true
    singleCatalogProjectionRetryAuthorized = $true
    retryConsumed = $false
    completionRuntimeStopHardeningApplied = $true
    officialOutboundUsed = $false
    officialIdentityPersisted = $false
    officialCredentialPersisted = $false
    serverExecutionStarted = $false
    clientExecutionStartedAfterRepair = $false
    nextStepCode =
        'boot_micron_as_nlloperator_and_run_catalog_projection_retry_once'
}
Write-AtomicUtf8NoBom $authorizationPath `
    (($authorization | ConvertTo-Json -Depth 8) + "`n")
Copy-Item -LiteralPath $authorizationPath `
    -Destination $protectedAuthorizationPath

Assert-True ((Get-Sha256Hex $projectionReceiptPath) -ceq
        (Get-Sha256Hex $protectedProjectionPath) -and
    (Get-Sha256Hex $authorizationPath) -ceq
        (Get-Sha256Hex $protectedAuthorizationPath) -and
    (Test-PathDigest $projectionPath 132L `
        '63f5ddcd289e55717ed0087b44d673837da14423e28bf363fa5f2092ca1a3502')) `
    'phase3b2_catalog_projection_resume_post_apply_invalid'

[pscustomobject]@{
    Receipt = $authorization
    MicronReceiptPath = $authorizationPath
    MicronReceiptByteLength = (Get-Item $authorizationPath).Length
    MicronReceiptSha256 = Get-Sha256Hex $authorizationPath
    ProjectionReceiptByteLength = (Get-Item $projectionReceiptPath).Length
    ProjectionReceiptSha256 = Get-Sha256Hex $projectionReceiptPath
    RollbackManifestSha256 = Get-Sha256Hex $rollbackManifestPath
    DeploymentReceiptSha256 = Get-Sha256Hex $deploymentPath
    ToolManifestSha256 = Get-Sha256Hex $manifestPath
    SamsungProtectedReceiptPath = $protectedAuthorizationPath
    ServerExecutionStarted = $false
    ClientExecutionStarted = $false
} | ConvertTo-Json -Depth 10
