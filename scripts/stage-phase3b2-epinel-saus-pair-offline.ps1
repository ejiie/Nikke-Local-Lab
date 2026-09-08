#requires -Version 7.0

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Z]$')]
    [string]$MicronDriveLetter = 'E',
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$StagingUid = '91e926f1-1073-4bb1-a0ae-6ad70dbab935',
    [string]$ProtectedRoot = (
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\' +
        'Micron-PrePhysicalLane-20260823\PhysicalP2\' +
        'EpinelSausPairStaging-v1'
    )
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

function Test-Digest {
    param([string]$Path, [long]$ByteLength, [string]$Sha256)
    (Test-Path -LiteralPath $Path -PathType Leaf) -and
        (Get-Item -LiteralPath $Path).Length -eq $ByteLength -and
        (Get-Sha256Hex $Path) -ceq $Sha256
}

function Write-AtomicUtf8NoBom {
    param([string]$Path, [string]$Text)

    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporary = $Path + '.partial-' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText(
            $temporary, $Text, [Text.UTF8Encoding]::new($false)
        )
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Copy-AtomicVerified {
    param(
        [string]$Source,
        [string]$Destination,
        [long]$ByteLength,
        [string]$Sha256
    )

    Assert-True (Test-Digest $Source $ByteLength $Sha256) `
        'phase3b2_saus_staging_source_digest_invalid'
    $parent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporary = $Destination + '.partial-' + [Guid]::NewGuid().ToString('N')
    try {
        Copy-Item -LiteralPath $Source -Destination $temporary
        Assert-True (Test-Digest $temporary $ByteLength $Sha256) `
            'phase3b2_saus_staging_temporary_digest_invalid'
        Move-Item -LiteralPath $temporary -Destination $Destination -Force
        Assert-True (Test-Digest $Destination $ByteLength $Sha256) `
            'phase3b2_saus_staging_destination_digest_invalid'
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$micronDrive = $MicronDriveLetter + ':'
$mappingAssessmentUid = 'd78b3434-6d86-4479-b1d4-23dfd170483a'
$mappingRoot = Join-Path $micronDrive (
    'NLL\Evidence\Phase3B2\Physical\' +
    'epinel-saus-catalog-mapping-v1\' + $mappingAssessmentUid
)
$mappingReceiptPath = Join-Path $mappingRoot 'mapping.receipt.json'
$baselineReceiptPath = Join-Path $micronDrive (
    'NLL\Evidence\Phase3B2\Physical\' +
    'epinel-saus-materialization-baseline-v1\' +
    $mappingAssessmentUid + '\baseline.receipt.json'
)
$activePointerPath = Join-Path $micronDrive (
    'NLL\Evidence\Phase3B2\Physical\' +
    'epinel-minimal-reference-v1\active-run.pointer.json'
)
$sourceRoot = Join-Path $micronDrive (
    'NLL\Clients\NIKKE-150.6.9-Physical\Unity\' +
    'com_proximabeta_NIKKE\saus\saus'
)
$sourceBodyPath = Join-Path $sourceRoot 'asset-catalog-2651531605.cat'
$sourceSignaturePath = $sourceBodyPath + '.nds'
$serverRoot = Join-Path $micronDrive (
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
)
$cacheRoot = Join-Path $serverRoot 'cache'
$targetRoot = Join-Path $cacheRoot (
    'prdenv\150-b059c3f36c\StandaloneWindows64\pck\' +
    'saus\19e939d'
)
$targetBodyPath = Join-Path $targetRoot 'asset-catalog.cat'
$targetSignaturePath = $targetBodyPath + '.nds'
$minimalStartSourcePath = Join-Path $repositoryRoot (
    'scripts\start-phase3b2-epinel-minimal-reference-in-micron.ps1'
)
$wrapperTemplatePath = Join-Path $repositoryRoot (
    'scripts\Start-Phase3B2-Epinel-NativeCache-CatalogTransport.ps1'
)
$minimalStartTargetPath = Join-Path $micronDrive (
    'NLL\Tools\start-phase3b2-epinel-minimal-reference-in-micron.ps1'
)
$wrapperTargetPath = Join-Path $micronDrive (
    'NLL\Tools\Start-Phase3B2-Epinel-NativeCache.ps1'
)
$verifierRoot = Join-Path $micronDrive 'NLL\Tools\Phase3B2.NativeCacheVerifier-v1'
$verifierDllPath = Join-Path $verifierRoot 'Phase3B2.NativeCacheMaterializer.dll'
$verifierManifestPath = Join-Path $verifierRoot 'bundle.manifest.json'
$dotnetPath = Join-Path $micronDrive 'Program Files\dotnet\dotnet.exe'
$deploymentReceiptPath = Join-Path $micronDrive (
    'NLL\Evidence\Phase3B2\Physical\' +
    'epinel-native-cache-deployment-v1\deployment.receipt.json'
)
$headerReceiptPath = Join-Path $micronDrive (
    'NLL\Evidence\Phase3B2\Physical\' +
    'epinel-native-cache-header-closure-v1\repair.receipt.json'
)
$transportRoot = Join-Path $micronDrive (
    'NLL\Evidence\Phase3B2\Physical\' +
    'epinel-native-cache-catalog-transport-v1'
)
$transportReceiptPath = Join-Path $transportRoot 'repair.receipt.json'
$catalogContractPath = Join-Path $transportRoot 'catalog-transport.contract.json'
$laneRoot = Join-Path $micronDrive (
    'NLL\Evidence\Phase3B2\Physical\epinel-saus-pair-staging-v1'
)
$contractPath = Join-Path $laneRoot 'saus-http-pair.contract.json'
$stagingReceiptPath = Join-Path $laneRoot 'staging.receipt.json'
$toolBindingPath = Join-Path $laneRoot 'tool-binding.receipt.json'
$protectedLaneRoot = Join-Path $ProtectedRoot $StagingUid
$protectedContractPath = Join-Path $protectedLaneRoot `
    'saus-http-pair.contract.json'
$protectedReceiptPath = Join-Path $protectedLaneRoot 'staging.receipt.json'
$protectedToolBindingPath = Join-Path $protectedLaneRoot `
    'tool-binding.receipt.json'
$backupRoot = Join-Path $micronDrive (
    'NLL\Backups\Phase3B2\EpinelSausPair-v1\' + $StagingUid
)
$backupMinimalStartPath = Join-Path $backupRoot `
    'start-phase3b2-epinel-minimal-reference-in-micron.ps1'
$backupWrapperPath = Join-Path $backupRoot `
    'Start-Phase3B2-Epinel-NativeCache.ps1'
$rollbackPlanPath = Join-Path $backupRoot 'rollback.plan.json'

$expectedMappingReceiptSha256 =
    'b9f2d7dbb2c266d983c3ff5088c2ca9749d2f13370172bf0dcdd9c80efbd8589'
$expectedBaselineReceiptSha256 =
    'b342004950de0b9c0bd708b470f7d22e54f8057a78d41cbb27a12dcc94b390be'
$expectedBodySha256 =
    'a8ad0f199f5db1213658c3238369ad472a98db74bb3a15a274931119ca22d0df'
$expectedSignatureSha256 =
    '01de2cc79b8f04297faf262666a7701242a942ba74d48b513c0998ab08b91fa2'
$expectedPriorMinimalStartSha256 =
    '385b5c41c1102e67cb31cd5372462933d22e0c7d26fda8b5dde659ec3637e5c9'
$expectedPriorWrapperSha256 =
    '310659582f0571f53c2a87789ab855ac8000931b618f585f02f5e7fb0c471e00'
$expectedMinimalStartSourceSha256 =
    'a039cd5186df92c16c0091f7d4b4c4bbb907d0bf2adc3ff94d8d425699bc5f69'
$expectedWrapperTemplateSha256 =
    '9aea17d6bafd5a01871e309799adf9626980b6262dfb6d9bfeee8ecbdcbd27b1'
$expectedDeploymentReceiptSha256 =
    '14bf845aec4cded1d80e8efb57a3eb4f4639ef68bd1fdf7a8d9de462689aae7d'
$expectedVerifierManifestSha256 =
    '3305d52786315bc927c46cdb988ce35b067d704f0a562be7aa469a188da3541c'
$expectedHeaderReceiptSha256 =
    'bc5e9e0f8f45f17c4db0408cee3d8a88389e11d1578670e9733a2563535444ce'
$expectedTransportReceiptSha256 =
    'fcd1469e6c348a91f2a9ef5bef02ad52d6a95099b20a3ff354c73fb36d40f430'
$expectedCatalogContractSha256 =
    '4e7903d912b3859691864b22a75a53e80881c744bd0fbee9e375036142d65654'

$systemPartition = Get-Partition -DriveLetter C
$systemDisk = $systemPartition | Get-Disk
$micronPartition = Get-Partition -DriveLetter $MicronDriveLetter
$micronDisk = $micronPartition | Get-Disk
Assert-True (
    $env:SystemDrive -ceq 'C:' -and
    $systemDisk.FriendlyName -like 'Samsung SSD 980*' -and
    $micronDisk.FriendlyName -like 'Micron_2200*' -and
    (Test-Path -LiteralPath (
            Join-Path $micronDrive 'Windows\System32'
        ) -PathType Container)
) 'phase3b2_saus_staging_wrong_disk_boundary'

$requiredInputs = @(
    $mappingReceiptPath, $baselineReceiptPath, $sourceBodyPath,
    $sourceSignaturePath, $minimalStartSourcePath, $wrapperTemplatePath,
    $minimalStartTargetPath, $wrapperTargetPath, $verifierDllPath,
    $verifierManifestPath, $dotnetPath, $deploymentReceiptPath,
    $headerReceiptPath, $transportReceiptPath, $catalogContractPath
)
Assert-True (@($requiredInputs | Where-Object {
            -not (Test-Path -LiteralPath $_ -PathType Leaf)
        }).Count -eq 0) 'phase3b2_saus_staging_input_missing'
Assert-True (
    -not (Test-Path -LiteralPath $activePointerPath) -and
    @(Get-Process -Name EpinelPS, nikke, nikke_launcher,
        NikkeLocalLab.Phase3B2.PhysicalBootstrap `
        -ErrorAction SilentlyContinue).Count -eq 0 -and
    @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal' |
        Where-Object { Test-Path -LiteralPath (Join-Path $serverRoot $_) }
    ).Count -eq 0 -and
    -not (Test-Path -LiteralPath $targetBodyPath) -and
    -not (Test-Path -LiteralPath $targetSignaturePath) -and
    -not (Test-Path -LiteralPath $laneRoot) -and
    -not (Test-Path -LiteralPath $protectedLaneRoot) -and
    -not (Test-Path -LiteralPath $backupRoot)
) 'phase3b2_saus_staging_runtime_or_destination_shape_invalid'

Assert-True (
    (Test-Digest $mappingReceiptPath 4735L $expectedMappingReceiptSha256) -and
    (Test-Digest $baselineReceiptPath 3103L $expectedBaselineReceiptSha256) -and
    (Test-Digest $sourceBodyPath 13476L $expectedBodySha256) -and
    (Test-Digest $sourceSignaturePath 96L $expectedSignatureSha256) -and
    (Test-Digest $minimalStartTargetPath 33053L `
        $expectedPriorMinimalStartSha256) -and
    (Test-Digest $wrapperTargetPath 12023L $expectedPriorWrapperSha256) -and
    (Get-Sha256Hex $minimalStartSourcePath) -ceq
        $expectedMinimalStartSourceSha256 -and
    (Get-Sha256Hex $wrapperTemplatePath) -ceq
        $expectedWrapperTemplateSha256 -and
    (Get-Sha256Hex $deploymentReceiptPath) -ceq
        $expectedDeploymentReceiptSha256 -and
    (Get-Sha256Hex $verifierManifestPath) -ceq
        $expectedVerifierManifestSha256 -and
    (Get-Sha256Hex $headerReceiptPath) -ceq
        $expectedHeaderReceiptSha256 -and
    (Get-Sha256Hex $transportReceiptPath) -ceq
        $expectedTransportReceiptSha256 -and
    (Get-Sha256Hex $catalogContractPath) -ceq
        $expectedCatalogContractSha256
) 'phase3b2_saus_staging_pinned_digest_invalid'

$mapping = Get-Content -LiteralPath $mappingReceiptPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True (
    $mapping.contractId -ceq
        'nll/phase3b2-epinel-saus-catalog-mapping/v1' -and
    $mapping.assessmentUid -ceq $mappingAssessmentUid -and
    $mapping.numberedCatalogFilenameCrc32Matched -and
    $mapping.derivedTargetMappingVerified -and
    $mapping.derivedSignaturePairMappingVerified -and
    -not $mapping.signatureCryptographicVerificationPerformed -and
    $mapping.runtimeColdAtSeal -and
    -not $mapping.retryAuthorized
) 'phase3b2_saus_staging_mapping_contract_invalid'

$beforeOutput = & $dotnetPath $verifierDllPath `
    'inspect-cache-tree' $cacheRoot 2>&1
Assert-True ($LASTEXITCODE -eq 0) `
    'phase3b2_saus_staging_before_cache_inspection_failed'
$before = ($beforeOutput | Out-String) | ConvertFrom-Json
Assert-True (
    $before.contractId -ceq 'nll/phase3b2-native-cache-tree-inspection/v1' -and
    $before.longPathSafeEnumerationUsed -and
    $before.fileCount -eq 40109 -and
    [long]$before.contentByteLength -eq 39030630086L -and
    $before.partialMemberCount -eq 0
) 'phase3b2_saus_staging_before_cache_shape_invalid'

$contract = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-epinel-saus-http-pair-contract/v1'
    createdAtUtc = [DateTimeOffset]::UtcNow.ToString(
        "yyyy-MM-dd'T'HH:mm:ss'Z'"
    )
    stagingUid = $StagingUid
    mappingReceiptSha256 = $expectedMappingReceiptSha256
    clientBuild = '150.6.9'
    sausRevision = '19e939d'
    bodyUrl =
        'https://cloud.nikke-kr.com/prdenv/150-b059c3f36c/' +
        'StandaloneWindows64/pck/saus/19e939d/asset-catalog.cat'
    bodyByteLength = 13476L
    bodySha256 = $expectedBodySha256
    bodyCrc32UnsignedDecimal = '2651531605'
    expectedClientMaterializedBasename =
        'asset-catalog-2651531605.cat'
    signatureUrl =
        'https://cloud.nikke-kr.com/prdenv/150-b059c3f36c/' +
        'StandaloneWindows64/pck/saus/19e939d/asset-catalog.cat.nds'
    signatureByteLength = 96L
    signatureSha256 = $expectedSignatureSha256
    targetMappingVerified = $true
    signaturePairMappingVerified = $true
    signatureCryptographicVerificationPerformed = $false
    rawEncryptedBodyPreserved = $true
    localOnlyRequired = $true
    officialOutboundFallbackPermitted = $false
}
$contractText = ($contract | ConvertTo-Json -Depth 5) + "`n"

$createdPaths = [Collections.Generic.List[string]]::new()
$toolsBackedUp = $false
$toolsDeployed = $false
try {
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    Copy-Item -LiteralPath $minimalStartTargetPath `
        -Destination $backupMinimalStartPath
    Copy-Item -LiteralPath $wrapperTargetPath -Destination $backupWrapperPath
    $toolsBackedUp = $true
    Assert-True (
        (Get-Sha256Hex $backupMinimalStartPath) -ceq
            $expectedPriorMinimalStartSha256 -and
        (Get-Sha256Hex $backupWrapperPath) -ceq
            $expectedPriorWrapperSha256
    ) 'phase3b2_saus_staging_tool_backup_invalid'

    Write-AtomicUtf8NoBom $contractPath $contractText
    $createdPaths.Add($contractPath)
    Write-AtomicUtf8NoBom $protectedContractPath $contractText
    $createdPaths.Add($protectedContractPath)
    $contractSha256 = Get-Sha256Hex $contractPath
    Assert-True (
        $contractSha256 -ceq (Get-Sha256Hex $protectedContractPath)
    ) 'phase3b2_saus_staging_contract_dual_seal_invalid'

    Copy-AtomicVerified $sourceBodyPath $targetBodyPath 13476L `
        $expectedBodySha256
    $createdPaths.Add($targetBodyPath)
    Copy-AtomicVerified $sourceSignaturePath $targetSignaturePath 96L `
        $expectedSignatureSha256
    $createdPaths.Add($targetSignaturePath)

    $afterOutput = & $dotnetPath $verifierDllPath `
        'inspect-cache-tree' $cacheRoot 2>&1
    Assert-True ($LASTEXITCODE -eq 0) `
        'phase3b2_saus_staging_after_cache_inspection_failed'
    $after = ($afterOutput | Out-String) | ConvertFrom-Json
    Assert-True (
        $after.contractId -ceq
            'nll/phase3b2-native-cache-tree-inspection/v1' -and
        $after.longPathSafeEnumerationUsed -and
        $after.fileCount -eq 40111 -and
        [long]$after.contentByteLength -eq 39030643658L -and
        $after.partialMemberCount -eq 0 -and
        (Test-Digest $targetBodyPath 13476L $expectedBodySha256) -and
        (Test-Digest $targetSignaturePath 96L $expectedSignatureSha256)
    ) 'phase3b2_saus_staging_after_cache_shape_invalid'

    Copy-AtomicVerified $minimalStartSourcePath $minimalStartTargetPath `
        (Get-Item -LiteralPath $minimalStartSourcePath).Length `
        $expectedMinimalStartSourceSha256
    $toolsDeployed = $true
    $newMinimalStartSha256 = Get-Sha256Hex $minimalStartTargetPath

    $rollbackPlan = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-epinel-saus-pair-rollback-plan/v1'
        stagingUid = $StagingUid
        removeOnlyIfExact = @(
            [ordered]@{ role = 'body'; byteLength = 13476L; sha256 = $expectedBodySha256 },
            [ordered]@{ role = 'signature'; byteLength = 96L; sha256 = $expectedSignatureSha256 }
        )
        restoreMinimalStartSha256 = $expectedPriorMinimalStartSha256
        restoreWrapperSha256 = $expectedPriorWrapperSha256
        expectedCacheFileCountAfterRollback = 40109
        expectedCacheContentByteLengthAfterRollback = 39030630086L
        runtimeMustBeCold = $true
    }
    Write-AtomicUtf8NoBom $rollbackPlanPath `
        (($rollbackPlan | ConvertTo-Json -Depth 6) + "`n")
    $rollbackPlanSha256 = Get-Sha256Hex $rollbackPlanPath

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-epinel-saus-pair-staging/v1'
        stagedAtUtc = [DateTimeOffset]::UtcNow.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'"
        )
        stagingUid = $StagingUid
        environmentCode = 'samsung_boot_micron_offline_runtime_cold'
        mappingReceiptByteLength = 4735L
        mappingReceiptSha256 = $expectedMappingReceiptSha256
        sausContractByteLength = (Get-Item -LiteralPath $contractPath).Length
        sausContractSha256 = $contractSha256
        sausRevision = '19e939d'
        bodyByteLength = 13476L
        bodySha256 = $expectedBodySha256
        bodyCrc32UnsignedDecimal = '2651531605'
        signatureByteLength = 96L
        signatureSha256 = $expectedSignatureSha256
        bodyStaged = $true
        signatureStaged = $true
        targetRemoteBasenameCode = 'asset_catalog_cat_and_nds'
        cacheFileCountBefore = [int]$before.fileCount
        cacheContentByteLengthBefore = [long]$before.contentByteLength
        cacheFileCountAfter = [int]$after.fileCount
        cacheContentByteLengthAfter = [long]$after.contentByteLength
        cacheTreeVerifiedAfterStaging = $true
        minimalStartToolBeforeSha256 = $expectedPriorMinimalStartSha256
        minimalStartToolAfterSha256 = $newMinimalStartSha256
        wrapperToolBeforeSha256 = $expectedPriorWrapperSha256
        wrapperTemplateSha256 = $expectedWrapperTemplateSha256
        loopbackResponsePreflightBoundIntoStartTool = $true
        rollbackPlanByteLength = (Get-Item -LiteralPath $rollbackPlanPath).Length
        rollbackPlanSha256 = $rollbackPlanSha256
        sourceCatalogModified = $false
        primaryInstallModified = $false
        existingOperatorCacheModified = $false
        officialOutboundUsed = $false
        officialApiUsed = $false
        officialLoginUsed = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        singleRetryPrepared = $true
        retryConsumed = $false
        nextStepCode =
            'operator_review_then_boot_micron_for_single_saus_pair_retry'
    }
    $receiptText = ($receipt | ConvertTo-Json -Depth 7) + "`n"
    Write-AtomicUtf8NoBom $stagingReceiptPath $receiptText
    $createdPaths.Add($stagingReceiptPath)
    Write-AtomicUtf8NoBom $protectedReceiptPath $receiptText
    $createdPaths.Add($protectedReceiptPath)
    $stagingReceiptSha256 = Get-Sha256Hex $stagingReceiptPath
    Assert-True (
        $stagingReceiptSha256 -ceq (Get-Sha256Hex $protectedReceiptPath)
    ) 'phase3b2_saus_staging_receipt_dual_seal_invalid'

    $wrapperText = [IO.File]::ReadAllText(
        $wrapperTemplatePath, [Text.Encoding]::UTF8
    )
    $replacementMap = [ordered]@{
        '__NATIVE_CACHE_DEPLOYMENT_RECEIPT_SHA256__' =
            $expectedDeploymentReceiptSha256
        '__NATIVE_CACHE_VERIFIER_MANIFEST_SHA256__' =
            $expectedVerifierManifestSha256
        '__NATIVE_CACHE_HEADER_CLOSURE_RECEIPT_SHA256__' =
            $expectedHeaderReceiptSha256
        '__NATIVE_CACHE_CATALOG_TRANSPORT_REPAIR_RECEIPT_SHA256__' =
            $expectedTransportReceiptSha256
        '__NATIVE_CACHE_CATALOG_TRANSPORT_CONTRACT_SHA256__' =
            $expectedCatalogContractSha256
        '__EPINEL_SAUS_STAGING_RECEIPT_SHA256__' =
            $stagingReceiptSha256
        '__EPINEL_SAUS_CONTRACT_SHA256__' = $contractSha256
        '__NATIVE_CACHE_MINIMAL_START_TOOL_SHA256__' =
            $newMinimalStartSha256
    }
    foreach ($placeholder in $replacementMap.Keys) {
        Assert-True ($wrapperText.Contains($placeholder)) `
            'phase3b2_saus_staging_wrapper_placeholder_missing'
        $wrapperText = $wrapperText.Replace(
            $placeholder, [string]$replacementMap[$placeholder]
        )
    }
    Assert-True (-not [regex]::IsMatch(
            $wrapperText, '__[A-Z0-9_]+__'
        )) 'phase3b2_saus_staging_wrapper_placeholder_remained'
    Write-AtomicUtf8NoBom $wrapperTargetPath $wrapperText
    $newWrapperSha256 = Get-Sha256Hex $wrapperTargetPath

    $toolBinding = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-epinel-saus-pair-tool-binding/v1'
        boundAtUtc = [DateTimeOffset]::UtcNow.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'"
        )
        stagingUid = $StagingUid
        stagingReceiptSha256 = $stagingReceiptSha256
        sausContractSha256 = $contractSha256
        minimalStartToolSha256 = $newMinimalStartSha256
        wrapperToolSha256 = $newWrapperSha256
        loopbackSausBodyPreflightRequired = $true
        loopbackSausSignaturePreflightRequired = $true
        bodyCrc32PreflightRequired = $true
        clientExecutionStarted = $false
    }
    $toolBindingText = ($toolBinding | ConvertTo-Json -Depth 5) + "`n"
    Write-AtomicUtf8NoBom $toolBindingPath $toolBindingText
    $createdPaths.Add($toolBindingPath)
    Write-AtomicUtf8NoBom $protectedToolBindingPath $toolBindingText
    $createdPaths.Add($protectedToolBindingPath)
    $toolBindingSha256 = Get-Sha256Hex $toolBindingPath
    Assert-True (
        $toolBindingSha256 -ceq (Get-Sha256Hex $protectedToolBindingPath)
    ) 'phase3b2_saus_staging_binding_dual_seal_invalid'

    [pscustomobject]@{
        Receipt = $receipt
        MicronReceiptPath = $stagingReceiptPath
        MicronReceiptByteLength = (Get-Item $stagingReceiptPath).Length
        MicronReceiptSha256 = $stagingReceiptSha256
        SausContractPath = $contractPath
        SausContractSha256 = $contractSha256
        ToolBindingPath = $toolBindingPath
        ToolBindingSha256 = $toolBindingSha256
        ProtectedReceiptPath = $protectedReceiptPath
        NextStepCode = $receipt.nextStepCode
    } | ConvertTo-Json -Depth 9
}
catch {
    if ($toolsBackedUp) {
        if (Test-Path -LiteralPath $backupMinimalStartPath -PathType Leaf) {
            Copy-Item -LiteralPath $backupMinimalStartPath `
                -Destination $minimalStartTargetPath -Force
        }
        if (Test-Path -LiteralPath $backupWrapperPath -PathType Leaf) {
            Copy-Item -LiteralPath $backupWrapperPath `
                -Destination $wrapperTargetPath -Force
        }
    }
    foreach ($path in @($targetSignaturePath, $targetBodyPath)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force
        }
    }
    foreach ($path in $createdPaths) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force
        }
    }
    foreach ($directory in @($laneRoot, $protectedLaneRoot)) {
        if ((Test-Path -LiteralPath $directory -PathType Container) -and
            @(Get-ChildItem -LiteralPath $directory -Force).Count -eq 0) {
            Remove-Item -LiteralPath $directory -Force
        }
    }
    throw
}
