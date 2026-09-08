[CmdletBinding()]
param(
    [string]$RepositoryRoot = '',
    [string]$MicronDrive = 'E:',
    [string]$FailedAssessmentUid =
        'bba01e6c-b457-4705-b251-4959006e0bef',
    [string]$BaselineAssessmentUid =
        '78c37245-ea49-442d-becf-b1e871f98d68',
    [string]$SamsungProtectedRoot =
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2',
    [switch]$AllowVerifiedNonAdministratorOfflineMutation,
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if (-not $RepositoryRoot) {
    $RepositoryRoot = Split-Path -Parent $PSScriptRoot
}

$mutationStarted = $false
$backupCreated = $false
$projectionCreated = $false
$preparationArchived = $false
$runtimeBackupArchived = $false
$protectedPreparationArchived = $false

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

function Get-ManifestLines {
    param([string[]]$Paths, [string]$BasePath)
    $canonicalBase = [IO.Path]::GetFullPath($BasePath).TrimEnd('\') + '\'
    @($Paths | Sort-Object | ForEach-Object {
        $item = Get-Item -LiteralPath $_
        $canonicalPath = [IO.Path]::GetFullPath($item.FullName)
        Assert-True ($canonicalPath.StartsWith(
                $canonicalBase, [StringComparison]::OrdinalIgnoreCase)) `
            'phase3b2_catalog_projection_manifest_member_outside_base'
        $relative = $canonicalPath.Substring($canonicalBase.Length).
            Replace('\', '/')
        "{0}`t{1}`t{2}" -f $relative, $item.Length,
            (Get-Sha256Hex $item.FullName)
    })
}

try {
    $isAdministrator = [Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    $micronLetter = $MicronDrive.TrimEnd(':')
    $systemDisk = Get-Partition -DriveLetter C | Get-Disk
    $micronDisk = Get-Partition -DriveLetter $micronLetter | Get-Disk
    Assert-True ($systemDisk.FriendlyName -ceq 'Samsung SSD 980 1TB' -and
        $systemDisk.IsBoot -and $systemDisk.IsSystem -and
        $micronDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK' -and
        -not $micronDisk.IsBoot -and -not $micronDisk.IsSystem) `
        'phase3b2_catalog_projection_repair_disk_boundary_invalid'
    $diskBoundaryVerified = $true
    if (-not $ValidateOnly) {
        Assert-True ($isAdministrator -or
            $AllowVerifiedNonAdministratorOfflineMutation) `
            'phase3b2_catalog_projection_repair_mutation_authority_invalid'
    }
    Assert-True (@(Get-Process -Name EpinelPS, nikke, nikke_launcher,
            'NikkeLocalLab.Phase3B2.PhysicalBootstrap' `
            -ErrorAction SilentlyContinue).Count -eq 0) `
        'phase3b2_catalog_projection_repair_runtime_not_cold'

    $toolRoot = Join-Path $MicronDrive 'NLL\Tools'
    $runtimeRoot = Join-Path $MicronDrive 'NLL\Runtime\PhysicalBootstrap-v2'
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

    $sourceStartPath = Join-Path $RepositoryRoot `
        'scripts\start-phase3b2-physical-p2-v2-client-in-micron.ps1'
    $sourceCompletionPath = Join-Path $RepositoryRoot `
        'scripts\complete-phase3b2-physical-p2-v2-client-in-micron.ps1'
    $targetStartPath = Join-Path $toolRoot `
        'start-phase3b2-physical-p2-v2-client-in-micron.ps1'
    $targetCompletionPath = Join-Path $toolRoot `
        'complete-phase3b2-physical-p2-v2-client-in-micron.ps1'
    $manifestPath = Join-Path $runtimeRoot 'evidence\tools.manifest.tsv'
    $deploymentPath = Join-Path $transferRoot 'deployment.receipt.json'
    $projectionReceiptPath = Join-Path $transferRoot `
        'catalog-version-projection.receipt.json'
    $authorizationPath = Join-Path $transferRoot `
        'catalog-version-projection-repair.receipt.json'

    $protectedDeploymentRoot = Join-Path $SamsungProtectedRoot 'V2Deployment'
    $protectedDeploymentPath = Join-Path $protectedDeploymentRoot `
        'offline-deployment.receipt.json'
    $protectedProjectionPath = Join-Path $protectedDeploymentRoot `
        'catalog-version-projection.receipt.json'
    $protectedAuthorizationPath = Join-Path $protectedDeploymentRoot `
        'catalog-version-projection-repair.receipt.json'

    $coldRecoveryPath = Join-Path (Join-Path $p2EvidenceRoot `
        $FailedAssessmentUid) 'cold-recovery-and-catalog-extraction.receipt.json'
    $priorInteractiveConsumptionPath = Join-Path $p2EvidenceRoot `
        'baseline-backed-interactive-retry.consumed.json'
    $newRetryConsumptionPath = Join-Path $p2EvidenceRoot `
        'catalog-version-projection-retry.consumed.json'
    $activePointerPath = Join-Path $p2EvidenceRoot 'active-run.pointer.json'
    $baselineMeasurementPath = Join-Path (Join-Path $p2EvidenceRoot `
        $BaselineAssessmentUid) 'ten-minute-measurement.receipt.json'

    $preparationRoot = Join-Path $MicronDrive `
        'NLL\Evidence\Phase3B2\Physical\p2-preparation-v2'
    $preparationReceiptPath = Join-Path $preparationRoot `
        'preparation.receipt.json'
    $runtimeBackupRoot = Join-Path $MicronDrive `
        'NLL\Backups\Phase3B2\PhysicalP2-v2'
    $protectedPreparationRoot = Join-Path $SamsungProtectedRoot 'PreparationV2'
    $protectedPreparationReceiptPath = Join-Path $protectedPreparationRoot `
        'preparation.receipt.json'
    $archiveSuffix = '.catalog-projection-' + $FailedAssessmentUid
    $preparationArchive = $preparationRoot + $archiveSuffix
    $runtimeBackupArchive = $runtimeBackupRoot + $archiveSuffix
    $protectedPreparationArchive = $protectedPreparationRoot + $archiveSuffix

    $backupRoot = Join-Path $MicronDrive `
        'NLL\Backups\Phase3B2\PhysicalP2-CatalogVersionProjection-v1'
    $backupToolRoot = Join-Path $backupRoot 'tools'
    $backupReceiptRoot = Join-Path $backupRoot 'receipts'
    $backupStartPath = Join-Path $backupToolRoot `
        'start-phase3b2-physical-p2-v2-client-in-micron.ps1'
    $backupCompletionPath = Join-Path $backupToolRoot `
        'complete-phase3b2-physical-p2-v2-client-in-micron.ps1'
    $backupManifestPath = Join-Path $backupReceiptRoot 'tools.manifest.tsv'
    $backupDeploymentPath = Join-Path $backupReceiptRoot `
        'micron-deployment.receipt.json'
    $backupProtectedDeploymentPath = Join-Path $backupReceiptRoot `
        'samsung-offline-deployment.receipt.json'
    $rollbackManifestPath = Join-Path $backupRoot 'rollback.manifest.json'

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

    Assert-True ((Test-PathDigest $coldRecoveryPath 1605L `
            '0f79f2e295635c5b39bb2523c7cff55403e48d6b10a64e228faa1c05e7029b6d') -and
        (Test-PathDigest $priorInteractiveConsumptionPath 825L `
            '9a31e53b91fe3c4da4c3c0929573e27f2d946ab5bc985ea76925cb703c32e304') -and
        (Test-PathDigest $baselineMeasurementPath 2696L `
            '8af3acdf40a741b6998ff0c2f9278a14b7a2c48246798abf1f1e4214d4bf6538') -and
        (Test-PathDigest $lcvPath 3775L `
            'ede45120d1531ea1639dc4237bb8ff0061b356ccefdf8fd53d9edcd98f2e9054') -and
        (Test-PathDigest $gameConfigPath 598L `
            '3a37e274562f80c7fdb1f6b58c579f4b1946c02f0c700ea40cea2f9b7801d152')) `
        'phase3b2_catalog_projection_input_or_evidence_pin_invalid'
    $coldRecovery = Get-Content -LiteralPath $coldRecoveryPath -Raw `
        -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($coldRecovery.contractId -ceq
            'nll/phase3b2-p2-v2-cold-recovery-and-catalog-extraction/v1' -and
        $coldRecovery.failedAssessmentUid -ceq $FailedAssessmentUid -and
        $coldRecovery.failureReasonCode -ceq
            'local_exact_content_version_cache_miss' -and
        $coldRecovery.runtimeColdAtRecovery -and
        $coldRecovery.databaseRestored -and
        $coldRecovery.sqliteRuntimeRemoved -and
        $coldRecovery.p2V2HostsExtensionRolledBack -and
        $coldRecovery.p2V2FirewallExtensionRolledBack -and
        [int]$coldRecovery.sourceCandidateCount -eq 0 -and
        $coldRecovery.catalogSourceStatusCode -ceq
            'exact_named_source_not_found' -and
        -not $coldRecovery.officialOutboundUsed) `
        'phase3b2_catalog_projection_cold_recovery_invalid'

    $sqlitePaths = @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal') |
        ForEach-Object { Join-Path $serverRoot $_ }
    Assert-True (-not (Test-Path -LiteralPath $activePointerPath) -and
        -not (Test-Path -LiteralPath $newRetryConsumptionPath) -and
        -not (Test-Path -LiteralPath $projectionPath) -and
        @($sqlitePaths | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0) `
        'phase3b2_catalog_projection_cold_state_invalid'

    Assert-True ((Test-PathDigest $targetStartPath 59278L `
            '96105d2cdc092467dbb3bfb66b8b1b2ac8f60a80f73def68406ae4ec9827b0eb') -and
        (Test-PathDigest $targetCompletionPath 19339L `
            '09d3be7ea6001af887b8cce6350988881481e13a57cb14ce1d96e43cb15ff58e') -and
        (Test-PathDigest $manifestPath 799L `
            'c1d78e09db430f83e6600576d416ccceb9ab09a80a111fd7582c829378b8829a') -and
        (Test-PathDigest $deploymentPath 6861L `
            'b1cbe3821bc41809094b0f9637fd2585aac86dbde5689c20fb7bbb547e11b542') -and
        (Test-PathDigest $protectedDeploymentPath 6861L `
            'b1cbe3821bc41809094b0f9637fd2585aac86dbde5689c20fb7bbb547e11b542') -and
        (Test-PathDigest $preparationReceiptPath 1693L `
            '74424f899b2df82545a1f15efa076db41400141a35173f71a7613b348681d2a8') -and
        (Test-PathDigest $protectedPreparationReceiptPath 1693L `
            '74424f899b2df82545a1f15efa076db41400141a35173f71a7613b348681d2a8') -and
        (Test-Path -LiteralPath $runtimeBackupRoot -PathType Container)) `
        'phase3b2_catalog_projection_deployment_or_preparation_pin_invalid'

    Assert-True ((Test-Path -LiteralPath $sourceStartPath -PathType Leaf) -and
        (Test-Path -LiteralPath $sourceCompletionPath -PathType Leaf) -and
        (Test-Path -LiteralPath $projectionProject -PathType Leaf) -and
        $dotnet.Count -eq 1 -and
        (Test-Path -LiteralPath $dotnet[0] -PathType Leaf)) `
        'phase3b2_catalog_projection_source_or_toolchain_missing'
    $dotnet = [string]$dotnet[0]
    $sourceStartText = Get-Content -LiteralPath $sourceStartPath -Raw `
        -Encoding UTF8
    $sourceCompletionText = Get-Content -LiteralPath $sourceCompletionPath `
        -Raw -Encoding UTF8
    Assert-True ($sourceStartText.Contains(
            'singleCatalogProjectionRetryAuthorized') -and
        $sourceStartText.Contains('preserved_catalog_version_projection_retry') -and
        $sourceCompletionText.Contains(
            'phase3b2_physical_p2_v2_catalog_projection_rollback_pin_invalid') -and
        $sourceCompletionText.Contains('taskkill.exe')) `
        'phase3b2_catalog_projection_source_contract_missing'
    $sdkList = @(& $dotnet --list-sdks)
    Assert-True ($LASTEXITCODE -eq 0 -and
        @($sdkList | Where-Object {
            $_ -cmatch '^10\.0\.400\s+\['
        }).Count -eq 1) `
        'phase3b2_catalog_projection_sdk_invalid'

    foreach ($path in @($backupRoot, $projectionReceiptPath,
            $authorizationPath, $protectedProjectionPath,
            $protectedAuthorizationPath, $preparationArchive,
            $runtimeBackupArchive, $protectedPreparationArchive)) {
        Assert-True (-not (Test-Path -LiteralPath $path)) `
            'phase3b2_catalog_projection_destination_already_exists'
    }

    if ($ValidateOnly) {
        [pscustomobject]@{
            ContractId =
                'nll/phase3b2-p2-v2-catalog-version-projection-repair-preflight/v1'
            FailedAssessmentUid = $FailedAssessmentUid
            BaselineAssessmentUid = $BaselineAssessmentUid
            ExactNamedSourceFound = $false
            LocalProjectionInputVerified = $true
            ProjectedByteLengthExpected = 132
            ProjectedSha256Expected =
                '63f5ddcd289e55717ed0087b44d673837da14423e28bf363fa5f2092ca1a3502'
            PriorInteractiveRetryConsumptionPreserved = $true
            NewSingleRetryAuthorized = $true
            MutationRequiresAdministrator = $false
            MutationAuthorityCode = if ($isAdministrator) {
                'administrator_token'
            }
            else { 'verified_offline_filesystem_orchestrator' }
            CurrentProcessIsAdministrator = $isAdministrator
            VerifiedNonAdministratorOfflineMutationAllowed =
                [bool]$AllowVerifiedNonAdministratorOfflineMutation
            DiskBoundaryVerified = $diskBoundaryVerified
            MutationPerformed = $false
        } | ConvertTo-Json -Depth 6
        return
    }

    Push-Location (Split-Path -Parent $projectionProject)
    try {
        & $dotnet build (Split-Path -Leaf $projectionProject) -c Release `
            --nologo
        Assert-True ($LASTEXITCODE -eq 0 -and
            (Test-Path -LiteralPath $projectionDll -PathType Leaf)) `
            'phase3b2_catalog_projection_helper_build_failed'
    }
    finally { Pop-Location }

    New-Item -ItemType Directory -Path $backupToolRoot, $backupReceiptRoot `
        -Force | Out-Null
    Copy-Item -LiteralPath $targetStartPath -Destination $backupStartPath
    Copy-Item -LiteralPath $targetCompletionPath `
        -Destination $backupCompletionPath
    Copy-Item -LiteralPath $manifestPath -Destination $backupManifestPath
    Copy-Item -LiteralPath $deploymentPath -Destination $backupDeploymentPath
    Copy-Item -LiteralPath $protectedDeploymentPath `
        -Destination $backupProtectedDeploymentPath
    $backupCreated = $true

    $rollbackManifest = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-local-content-version-projection-rollback/v1'
        preparedAtUtc =
            [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        targetRoleCode = 'epinelps_local_content_version_cache'
        targetRelativePathSha256 =
            '2aac55feeb61d4178d82b2ed38151750c10d297df71538d936d5533288291032'
        targetWasAbsentBeforeProjection = $true
        projectedByteLength = 132
        projectedSha256 =
            '63f5ddcd289e55717ed0087b44d673837da14423e28bf363fa5f2092ca1a3502'
        removeOnlyWhenExactDigestMatches = $true
        automaticFailureHandlerCode = 'p2_v2_start_failure_handler'
        successfulCompletionHandlerCode = 'p2_v2_completion_handler'
        officialOutboundUsed = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
    }
    Write-AtomicUtf8NoBom $rollbackManifestPath `
        (($rollbackManifest | ConvertTo-Json -Depth 6) + "`n")

    $mutationStarted = $true
    $projectionOutput = & $dotnet $projectionDll $lcvPath $gameConfigPath `
        $cacheRoot 2>&1
    Assert-True ($LASTEXITCODE -eq 0) `
        'phase3b2_catalog_projection_execution_failed'
    $projectionText = ($projectionOutput | Out-String).TrimEnd() + "`n"
    $projection = $projectionText | ConvertFrom-Json
    Assert-True ($projection.contractId -ceq
            'nll/phase3b2-local-content-version-projection/v1' -and
        [int]$projection.entryCount -eq 7 -and
        $projection.aggregateRevisionMatchesDp -and
        [long]$projection.projectedByteLength -eq 132L -and
        $projection.projectedSha256 -ceq
            '63f5ddcd289e55717ed0087b44d673837da14423e28bf363fa5f2092ca1a3502' -and
        -not $projection.targetAlreadyMatched -and
        -not $projection.officialOutboundUsed -and
        (Test-PathDigest $projectionPath 132L `
            '63f5ddcd289e55717ed0087b44d673837da14423e28bf363fa5f2092ca1a3502')) `
        'phase3b2_catalog_projection_output_invalid'
    $projectionCreated = $true
    Write-AtomicUtf8NoBom $projectionReceiptPath $projectionText
    Copy-Item -LiteralPath $projectionReceiptPath `
        -Destination $protectedProjectionPath

    Copy-Item -LiteralPath $sourceStartPath -Destination $targetStartPath -Force
    Copy-Item -LiteralPath $sourceCompletionPath `
        -Destination $targetCompletionPath -Force

    $deployment = Get-Content -LiteralPath $deploymentPath -Raw `
        -Encoding UTF8 | ConvertFrom-Json
    foreach ($toolUpdate in @(
            [pscustomobject]@{
                Name = 'start-phase3b2-physical-p2-v2-client-in-micron.ps1'
                Path = $targetStartPath
            },
            [pscustomobject]@{
                Name = 'complete-phase3b2-physical-p2-v2-client-in-micron.ps1'
                Path = $targetCompletionPath
            })) {
        $entry = @($deployment.tools | Where-Object {
            $_.name -ceq $toolUpdate.Name
        })
        Assert-True ($entry.Count -eq 1) `
            'phase3b2_catalog_projection_deployment_tool_entry_invalid'
        $entry[0].byteLength = (Get-Item -LiteralPath $toolUpdate.Path).Length
        $entry[0].sha256 = Get-Sha256Hex $toolUpdate.Path
    }
    $toolPaths = @($deployment.tools | ForEach-Object {
        Join-Path $toolRoot ([string]$_.name)
    })
    Assert-True (@($toolPaths | Where-Object {
        -not (Test-Path -LiteralPath $_ -PathType Leaf)
    }).Count -eq 0) 'phase3b2_catalog_projection_tool_shape_invalid'
    $manifestText = (Get-ManifestLines $toolPaths $toolRoot) -join "`n"
    Write-AtomicUtf8NoBom $manifestPath ($manifestText + "`n")
    $deployment.toolManifestByteLength = (Get-Item $manifestPath).Length
    $deployment.toolManifestSha256 = Get-Sha256Hex $manifestPath
    $deployment.minimumMeasurementSeconds = 30
    $deployment.latestFailedAssessmentUid = $FailedAssessmentUid
    $deployment | Add-Member -NotePropertyName catalogVersionProjectionApplied `
        -NotePropertyValue $true -Force
    $deployment | Add-Member -NotePropertyName catalogVersionProjectionByteLength `
        -NotePropertyValue 132 -Force
    $deployment | Add-Member -NotePropertyName catalogVersionProjectionSha256 `
        -NotePropertyValue `
            '63f5ddcd289e55717ed0087b44d673837da14423e28bf363fa5f2092ca1a3502' -Force
    $deployment | Add-Member -NotePropertyName catalogVersionSourceCode `
        -NotePropertyValue 'installed_client_lcv_record_projection' -Force
    $deployment | Add-Member -NotePropertyName catalogVersionRollbackManifestSha256 `
        -NotePropertyValue (Get-Sha256Hex $rollbackManifestPath) -Force
    $deployment | Add-Member -NotePropertyName `
        completionRuntimeStopHardeningApplied -NotePropertyValue $true -Force
    $deployment | Add-Member -NotePropertyName `
        priorInteractiveRetryConsumptionPreserved -NotePropertyValue $true -Force
    $deployment | Add-Member -NotePropertyName `
        singleCatalogProjectionRetryAuthorized -NotePropertyValue $true -Force
    $deployment.endpointContractChanged = $false
    $deployment.nextStepCode =
        'boot_micron_as_nlloperator_and_run_catalog_projection_retry_once'
    Write-AtomicUtf8NoBom $deploymentPath `
        (($deployment | ConvertTo-Json -Depth 12) + "`n")
    Copy-Item -LiteralPath $deploymentPath `
        -Destination $protectedDeploymentPath -Force

    $preparationReceiptSha256 = Get-Sha256Hex $preparationReceiptPath
    Move-Item -LiteralPath $preparationRoot -Destination $preparationArchive
    $preparationArchived = $true
    Move-Item -LiteralPath $runtimeBackupRoot -Destination $runtimeBackupArchive
    $runtimeBackupArchived = $true
    Move-Item -LiteralPath $protectedPreparationRoot `
        -Destination $protectedPreparationArchive
    $protectedPreparationArchived = $true

    $authorization = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-p2-v2-catalog-version-projection-repair/v1'
        repairedAtUtc =
            [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
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
        priorPreparationReceiptSha256 = $preparationReceiptSha256
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

    Assert-True ((Get-Sha256Hex $targetStartPath) -ceq
            (Get-Sha256Hex $sourceStartPath) -and
        (Get-Sha256Hex $targetCompletionPath) -ceq
            (Get-Sha256Hex $sourceCompletionPath) -and
        (Get-Sha256Hex $deploymentPath) -ceq
            (Get-Sha256Hex $protectedDeploymentPath) -and
        (Get-Sha256Hex $projectionReceiptPath) -ceq
            (Get-Sha256Hex $protectedProjectionPath) -and
        (Get-Sha256Hex $authorizationPath) -ceq
            (Get-Sha256Hex $protectedAuthorizationPath) -and
        (Test-PathDigest $projectionPath 132L `
            '63f5ddcd289e55717ed0087b44d673837da14423e28bf363fa5f2092ca1a3502') -and
        -not (Test-Path -LiteralPath $preparationRoot) -and
        -not (Test-Path -LiteralPath $runtimeBackupRoot) -and
        -not (Test-Path -LiteralPath $protectedPreparationRoot)) `
        'phase3b2_catalog_projection_post_apply_invalid'

    [pscustomobject]@{
        Receipt = $authorization
        MicronReceiptPath = $authorizationPath
        MicronReceiptByteLength = (Get-Item $authorizationPath).Length
        MicronReceiptSha256 = Get-Sha256Hex $authorizationPath
        ProjectionReceiptSha256 = Get-Sha256Hex $projectionReceiptPath
        RollbackManifestSha256 = Get-Sha256Hex $rollbackManifestPath
        DeploymentReceiptSha256 = Get-Sha256Hex $deploymentPath
        ToolManifestSha256 = Get-Sha256Hex $manifestPath
        SamsungProtectedReceiptPath = $protectedAuthorizationPath
    } | ConvertTo-Json -Depth 10
}
catch {
    if ($mutationStarted -and $backupCreated) {
        Copy-Item -LiteralPath $backupStartPath -Destination $targetStartPath `
            -Force -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath $backupCompletionPath `
            -Destination $targetCompletionPath -Force `
            -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath $backupManifestPath -Destination $manifestPath `
            -Force -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath $backupDeploymentPath `
            -Destination $deploymentPath -Force -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath $backupProtectedDeploymentPath `
            -Destination $protectedDeploymentPath -Force `
            -ErrorAction SilentlyContinue
    }
    if ($protectedPreparationArchived -and
        (Test-Path -LiteralPath $protectedPreparationArchive) -and
        -not (Test-Path -LiteralPath $protectedPreparationRoot)) {
        Move-Item -LiteralPath $protectedPreparationArchive `
            -Destination $protectedPreparationRoot -ErrorAction SilentlyContinue
    }
    if ($runtimeBackupArchived -and
        (Test-Path -LiteralPath $runtimeBackupArchive) -and
        -not (Test-Path -LiteralPath $runtimeBackupRoot)) {
        Move-Item -LiteralPath $runtimeBackupArchive `
            -Destination $runtimeBackupRoot -ErrorAction SilentlyContinue
    }
    if ($preparationArchived -and
        (Test-Path -LiteralPath $preparationArchive) -and
        -not (Test-Path -LiteralPath $preparationRoot)) {
        Move-Item -LiteralPath $preparationArchive `
            -Destination $preparationRoot -ErrorAction SilentlyContinue
    }
    if ($projectionCreated -and
        (Test-PathDigest $projectionPath 132L `
            '63f5ddcd289e55717ed0087b44d673837da14423e28bf363fa5f2092ca1a3502')) {
        Remove-Item -LiteralPath $projectionPath -Force `
            -ErrorAction SilentlyContinue
    }
    foreach ($path in @($projectionReceiptPath, $authorizationPath,
            $protectedProjectionPath, $protectedAuthorizationPath)) {
        if ($path) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
    throw
}
