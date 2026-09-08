$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Set-ExecutionPolicy -Scope Process Bypass -Force

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

function Test-SafeLeafName {
    param([string]$RelativePath)
    if ([string]::IsNullOrWhiteSpace($RelativePath)) { return $false }
    if ([IO.Path]::IsPathRooted($RelativePath)) { return $false }
    return $RelativePath -ceq [IO.Path]::GetFileName($RelativePath) -and
        -not $RelativePath.Contains('/') -and
        -not $RelativePath.Contains('\')
}

$expectedDeploymentReceiptSha256 =
    '__NATIVE_CACHE_DEPLOYMENT_RECEIPT_SHA256__'
$expectedVerifierManifestSha256 =
    '__NATIVE_CACHE_VERIFIER_MANIFEST_SHA256__'
$expectedHeaderClosureReceiptSha256 =
    '__NATIVE_CACHE_HEADER_CLOSURE_RECEIPT_SHA256__'
$expectedTransportRepairReceiptSha256 =
    '__NATIVE_CACHE_CATALOG_TRANSPORT_REPAIR_RECEIPT_SHA256__'
$expectedCatalogContractSha256 =
    '__NATIVE_CACHE_CATALOG_TRANSPORT_CONTRACT_SHA256__'
$expectedSausStagingReceiptSha256 =
    '__EPINEL_SAUS_STAGING_RECEIPT_SHA256__'
$expectedSausContractSha256 =
    '__EPINEL_SAUS_CONTRACT_SHA256__'
$expectedHistoricalSausToolBindingSha256 =
    '__EPINEL_HISTORICAL_SAUS_TOOL_BINDING_SHA256__'
$expectedHistoricalSausMinimalStartToolSha256 =
    '__EPINEL_HISTORICAL_SAUS_MINIMAL_START_TOOL_SHA256__'
$expectedHistoricalSausWrapperToolSha256 =
    '__EPINEL_HISTORICAL_SAUS_WRAPPER_TOOL_SHA256__'
$expectedMinimalStartToolSha256 =
    '__NATIVE_CACHE_MINIMAL_START_TOOL_SHA256__'
$expectedTutorialMaterializationReceiptSha256 =
    '__EPINEL_TUTORIAL_MATERIALIZATION_RECEIPT_SHA256__'
$expectedTutorialStartBindingReceiptSha256 =
    '__EPINEL_TUTORIAL_START_BINDING_RECEIPT_SHA256__'
$expectedTutorialWrapperRebindV1ReceiptSha256 =
    '__EPINEL_TUTORIAL_WRAPPER_REBIND_V1_RECEIPT_SHA256__'
$expectedTutorialWrapperRebindV1WrapperSha256 =
    '__EPINEL_TUTORIAL_WRAPPER_REBIND_V1_WRAPPER_SHA256__'
$expectedTutorialRevisionUid =
    '__EPINEL_TUTORIAL_REVISION_UID__'
$expectedTutorialDatabaseSha256 =
    '__EPINEL_TUTORIAL_DATABASE_SHA256__'
$expectedServerDllSha256 =
    'aaa1e49d7a879a6b5ec17ad4c4094ce7d98ce86f860c1529a9ab4d6aecb51f7c'
$expectedExternalHead = 'aa01ad90b807be1c2ceffe958519cb529622d472'
$expectedExternalTree = 'c324c11d32365b1524f266cba6bc014e89545204'

$deploymentPath =
    'C:\NLL\Evidence\Phase3B2\Physical\epinel-native-cache-deployment-v1\deployment.receipt.json'
$verifierRoot = 'C:\NLL\Tools\Phase3B2.NativeCacheVerifier-v1'
$verifierManifestPath = Join-Path $verifierRoot 'bundle.manifest.json'
$verifierDllPath = Join-Path $verifierRoot `
    'Phase3B2.NativeCacheMaterializer.dll'
$headerClosureReceiptPath =
    'C:\NLL\Evidence\Phase3B2\Physical\epinel-native-cache-header-closure-v1\repair.receipt.json'
$transportRoot =
    'C:\NLL\Evidence\Phase3B2\Physical\epinel-native-cache-catalog-transport-v1'
$transportRepairReceiptPath = Join-Path $transportRoot 'repair.receipt.json'
$catalogContractPath = Join-Path $transportRoot 'catalog-transport.contract.json'
$sausRoot =
    'C:\NLL\Evidence\Phase3B2\Physical\epinel-saus-pair-staging-v1'
$sausStagingReceiptPath = Join-Path $sausRoot 'staging.receipt.json'
$sausContractPath = Join-Path $sausRoot 'saus-http-pair.contract.json'
$sausToolBindingPath = Join-Path $sausRoot 'tool-binding.receipt.json'
$tutorialMaterializationReceiptPath = Join-Path (
    'C:\NLL\Evidence\Phase3B2\Physical\epinel-tutorial-only-v1\' +
    $expectedTutorialRevisionUid
) 'materialization.receipt.json'
$tutorialStartBindingReceiptPath = Join-Path (
    'C:\NLL\Evidence\Phase3B2\Physical\' +
    'epinel-tutorial-start-binding-v1\' + $expectedTutorialRevisionUid
) 'binding.receipt.json'
$tutorialWrapperRebindV1ReceiptPath = Join-Path (
    'C:\NLL\Evidence\Phase3B2\Physical\' +
    'epinel-tutorial-native-cache-rebind-v1\' +
    $expectedTutorialRevisionUid
) 'repair.receipt.json'
$tutorialWrapperCorrectionReceiptPath = Join-Path (
    'C:\NLL\Evidence\Phase3B2\Physical\' +
    'epinel-tutorial-native-cache-wrapper-correction-v2\' +
    $expectedTutorialRevisionUid
) 'repair.receipt.json'
$databasePath =
    'C:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\db.json'
$dotnetPath = 'C:\Program Files\dotnet\dotnet.exe'
$cacheRoot =
    'C:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\cache'
$serverDllPath =
    'C:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\EpinelPS.dll'
$headerPath = Join-Path $cacheRoot `
    'prdenv\150-b059c3f36c\StandaloneWindows64\pck\latest-651.txt'
$headerUrl =
    'https://cloud.nikke-kr.com/prdenv/150-b059c3f36c/StandaloneWindows64/pck/latest-651.txt'
$expectedHeaderByteLength = 139L
$expectedHeaderSha256 =
    '5914cb58fd2146fe761ab531ecb4e321300527186a54b455e59de962ff6c044a'
$minimalStartPath =
    'C:\NLL\Tools\start-phase3b2-epinel-minimal-reference-in-micron.ps1'
$extensionFirewallGroup = 'NLL Phase3B2 Epinel Minimal Extension'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
Assert-True ($principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    'phase3b2_epinel_catalog_transport_start_requires_administrator'
Assert-True ($env:SystemDrive -ceq 'C:' -and $env:USERNAME -ceq 'nlloperator') `
    'phase3b2_epinel_catalog_transport_start_wrong_operator_or_boot_boundary'

$requiredInputs = @(
    $deploymentPath, $verifierManifestPath, $verifierDllPath,
    $headerClosureReceiptPath, $transportRepairReceiptPath,
    $catalogContractPath, $sausStagingReceiptPath, $sausContractPath,
    $sausToolBindingPath, $tutorialMaterializationReceiptPath,
    $tutorialStartBindingReceiptPath, $tutorialWrapperRebindV1ReceiptPath,
    $tutorialWrapperCorrectionReceiptPath,
    $databasePath, $dotnetPath, $headerPath, $minimalStartPath, $serverDllPath
)
Assert-True (@($requiredInputs | Where-Object {
            -not (Test-Path -LiteralPath $_ -PathType Leaf)
        }).Count -eq 0 -and
    (Get-Sha256Hex $deploymentPath) -ceq
        $expectedDeploymentReceiptSha256 -and
    (Get-Sha256Hex $verifierManifestPath) -ceq
        $expectedVerifierManifestSha256 -and
    (Get-Sha256Hex $headerClosureReceiptPath) -ceq
        $expectedHeaderClosureReceiptSha256 -and
    (Get-Sha256Hex $transportRepairReceiptPath) -ceq
        $expectedTransportRepairReceiptSha256 -and
    (Get-Sha256Hex $catalogContractPath) -ceq
        $expectedCatalogContractSha256 -and
    (Get-Sha256Hex $sausStagingReceiptPath) -ceq
        $expectedSausStagingReceiptSha256 -and
    (Get-Sha256Hex $sausContractPath) -ceq
        $expectedSausContractSha256 -and
    (Get-Sha256Hex $sausToolBindingPath) -ceq
        $expectedHistoricalSausToolBindingSha256 -and
    (Get-Sha256Hex $tutorialMaterializationReceiptPath) -ceq
        $expectedTutorialMaterializationReceiptSha256 -and
    (Get-Sha256Hex $tutorialStartBindingReceiptPath) -ceq
        $expectedTutorialStartBindingReceiptSha256 -and
    (Get-Sha256Hex $tutorialWrapperRebindV1ReceiptPath) -ceq
        $expectedTutorialWrapperRebindV1ReceiptSha256 -and
    (Get-Sha256Hex $databasePath) -ceq
        $expectedTutorialDatabaseSha256 -and
    (Get-Sha256Hex $minimalStartPath) -ceq
        $expectedMinimalStartToolSha256 -and
    (Get-Sha256Hex $serverDllPath) -ceq $expectedServerDllSha256 -and
    (Get-Item -LiteralPath $headerPath).Length -eq
        $expectedHeaderByteLength -and
    (Get-Sha256Hex $headerPath) -ceq $expectedHeaderSha256) `
    'phase3b2_epinel_catalog_transport_start_input_missing_or_drifted'

$sausStaging = Get-Content -LiteralPath $sausStagingReceiptPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
$sausContract = Get-Content -LiteralPath $sausContractPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
$sausToolBinding = Get-Content -LiteralPath $sausToolBindingPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
Assert-True (
    $sausStaging.contractId -ceq
        'nll/phase3b2-epinel-saus-pair-staging/v1' -and
    $sausStaging.mappingReceiptSha256 -ceq
        'b9f2d7dbb2c266d983c3ff5088c2ca9749d2f13370172bf0dcdd9c80efbd8589' -and
    $sausStaging.sausContractSha256 -ceq $expectedSausContractSha256 -and
    $sausStaging.bodyStaged -and $sausStaging.signatureStaged -and
    $sausStaging.cacheTreeVerifiedAfterStaging -and
    -not $sausStaging.serverExecutionStarted -and
    -not $sausStaging.clientExecutionStarted -and
    $sausContract.contractId -ceq
        'nll/phase3b2-epinel-saus-http-pair-contract/v1' -and
    $sausContract.bodySha256 -ceq
        'a8ad0f199f5db1213658c3238369ad472a98db74bb3a15a274931119ca22d0df' -and
    $sausContract.signatureSha256 -ceq
        '01de2cc79b8f04297faf262666a7701242a942ba74d48b513c0998ab08b91fa2' -and
    $sausToolBinding.contractId -ceq
        'nll/phase3b2-epinel-saus-pair-tool-binding/v1' -and
    $sausToolBinding.stagingReceiptSha256 -ceq
        $expectedSausStagingReceiptSha256 -and
    $sausToolBinding.sausContractSha256 -ceq
        $expectedSausContractSha256 -and
    $sausToolBinding.minimalStartToolSha256 -ceq
        $expectedHistoricalSausMinimalStartToolSha256 -and
    $sausToolBinding.wrapperToolSha256 -ceq
        $expectedHistoricalSausWrapperToolSha256
) 'phase3b2_epinel_catalog_transport_start_saus_binding_invalid'

$tutorialMaterialization = Get-Content -LiteralPath `
    $tutorialMaterializationReceiptPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$tutorialStartBinding = Get-Content -LiteralPath `
    $tutorialStartBindingReceiptPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$tutorialWrapperRebindV1 = Get-Content -LiteralPath `
    $tutorialWrapperRebindV1ReceiptPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$tutorialWrapperCorrection = Get-Content -LiteralPath `
    $tutorialWrapperCorrectionReceiptPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True (
    $tutorialMaterialization.contractId -ceq
        'nll/phase3b2-epinel-tutorial-only-materialization/v1' -and
    $tutorialMaterialization.revisionUid -ceq
        $expectedTutorialRevisionUid -and
    $tutorialMaterialization.databaseAfterSha256 -ceq
        $expectedTutorialDatabaseSha256 -and
    $tutorialMaterialization.tutorialGroupCountAfter -eq 40 -and
    -not $tutorialMaterialization.nonTutorialStateChanged -and
    -not $tutorialMaterialization.cacheMutationPerformed -and
    -not $tutorialMaterialization.serverBinaryMutationPerformed -and
    -not $tutorialMaterialization.serverExecutionStarted -and
    -not $tutorialMaterialization.clientExecutionStarted -and
    $tutorialStartBinding.contractId -ceq
        'nll/phase3b2-epinel-tutorial-start-binding/v1' -and
    $tutorialStartBinding.revisionUid -ceq
        $expectedTutorialRevisionUid -and
    $tutorialStartBinding.tutorialMaterializationReceiptSha256 -ceq
        $expectedTutorialMaterializationReceiptSha256 -and
    $tutorialStartBinding.databaseSha256 -ceq
        $expectedTutorialDatabaseSha256 -and
    $tutorialStartBinding.priorStartToolSha256 -ceq
        $expectedHistoricalSausMinimalStartToolSha256 -and
    $tutorialStartBinding.boundStartToolSha256 -ceq
        $expectedMinimalStartToolSha256 -and
    $tutorialStartBinding.tutorialReceiptPreflightEnabled -and
    $tutorialStartBinding.tutorialDatabaseDigestPreflightEnabled -and
    $tutorialStartBinding.nonTutorialProgressionExpectedUnchanged -and
    -not $tutorialStartBinding.nativeCacheWrapperMutationPerformed -and
    -not $tutorialStartBinding.serverExecutionStarted -and
    -not $tutorialStartBinding.clientExecutionStarted -and
    $tutorialWrapperRebindV1.contractId -ceq
        'nll/phase3b2-epinel-tutorial-native-cache-rebind/v1' -and
    $tutorialWrapperRebindV1.revisionUid -ceq
        $expectedTutorialRevisionUid -and
    $tutorialWrapperRebindV1.historicalSausToolBindingReceiptSha256 -ceq
        $expectedHistoricalSausToolBindingSha256 -and
    $tutorialWrapperRebindV1.tutorialMaterializationReceiptSha256 -ceq
        $expectedTutorialMaterializationReceiptSha256 -and
    $tutorialWrapperRebindV1.tutorialStartBindingReceiptSha256 -ceq
        $expectedTutorialStartBindingReceiptSha256 -and
    $tutorialWrapperRebindV1.priorWrapperToolSha256 -ceq
        $expectedHistoricalSausWrapperToolSha256 -and
    $tutorialWrapperRebindV1.activeMinimalStartToolSha256 -ceq
        $expectedMinimalStartToolSha256 -and
    $tutorialWrapperRebindV1.databaseSha256 -ceq
        $expectedTutorialDatabaseSha256 -and
    $tutorialWrapperRebindV1.repairedWrapperToolSha256 -ceq
        $expectedTutorialWrapperRebindV1WrapperSha256 -and
    $tutorialWrapperRebindV1.historicalSausEvidencePreserved -and
    $tutorialWrapperRebindV1.cacheMutationPerformed -eq $false -and
    $tutorialWrapperRebindV1.databaseMutationPerformed -eq $false -and
    $tutorialWrapperRebindV1.serverBinaryMutationPerformed -eq $false -and
    $tutorialWrapperRebindV1.targetOsOfflineDuringRepair -and
    -not $tutorialWrapperRebindV1.serverExecutionStarted -and
    -not $tutorialWrapperRebindV1.clientExecutionStarted -and
    $tutorialWrapperCorrection.contractId -ceq
        'nll/phase3b2-epinel-tutorial-native-cache-wrapper-correction/v2' -and
    $tutorialWrapperCorrection.revisionUid -ceq
        $expectedTutorialRevisionUid -and
    $tutorialWrapperCorrection.priorRebindReceiptSha256 -ceq
        $expectedTutorialWrapperRebindV1ReceiptSha256 -and
    $tutorialWrapperCorrection.priorWrapperToolSha256 -ceq
        $expectedTutorialWrapperRebindV1WrapperSha256 -and
    $tutorialWrapperCorrection.correctedTransportRepairReceiptSha256 -ceq
        $expectedTransportRepairReceiptSha256 -and
    $tutorialWrapperCorrection.correctedCatalogContractSha256 -ceq
        $expectedCatalogContractSha256 -and
    $tutorialWrapperCorrection.correctedWrapperToolSha256 -ceq
        (Get-Sha256Hex $PSCommandPath) -and
    $tutorialWrapperCorrection.fullRequiredInputAuditPassed -and
    $tutorialWrapperCorrection.historicalEvidencePreserved -and
    $tutorialWrapperCorrection.cacheMutationPerformed -eq $false -and
    $tutorialWrapperCorrection.databaseMutationPerformed -eq $false -and
    $tutorialWrapperCorrection.serverBinaryMutationPerformed -eq $false -and
    $tutorialWrapperCorrection.targetOsOfflineDuringCorrection -and
    -not $tutorialWrapperCorrection.serverExecutionStarted -and
    -not $tutorialWrapperCorrection.clientExecutionStarted
) 'phase3b2_epinel_catalog_transport_start_tutorial_rebind_invalid'

$repair = Get-Content -LiteralPath $transportRepairReceiptPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
$catalogContract = Get-Content -LiteralPath $catalogContractPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
Assert-True ($repair.contractId -ceq
        'nll/phase3b2-epinel-native-cache-catalog-transport-repair/v1' -and
    $repair.failureReasonCode -ceq
        'encrypted_nkdb_served_as_sqlite_catalog_db' -and
    $repair.catalogTransportContractSha256 -ceq
        $expectedCatalogContractSha256 -and
    $repair.decryptedSqliteBodyCount -eq 3 -and
    $repair.signatureMemberCount -eq 3 -and
    $repair.databaseRestored -and $repair.sqliteRuntimeRemoved -and
    $repair.hostsRestored -and $repair.activeRunPointerArchived -and
    $repair.externalHead -ceq $expectedExternalHead -and
    $repair.externalTree -ceq $expectedExternalTree -and
    $repair.appliedServerDllSha256 -ceq $expectedServerDllSha256 -and
    -not $repair.rawDecryptedCatalogPersisted -and
    -not $repair.serverExecutionStarted -and
    -not $repair.clientExecutionStarted) `
    'phase3b2_epinel_catalog_transport_start_repair_contract_invalid'
Assert-True ($catalogContract.contractId -ceq
        'nll/phase3b2-epinel-native-cache-catalog-transport-contract/v1' -and
    $catalogContract.externalHead -ceq $expectedExternalHead -and
    $catalogContract.externalTree -ceq $expectedExternalTree -and
    $catalogContract.serverDllSha256 -ceq $expectedServerDllSha256 -and
    [int]$catalogContract.memberCount -eq 3 -and
    @($catalogContract.members).Count -eq 3 -and
    -not $catalogContract.rawDecryptedCatalogPersisted) `
    'phase3b2_epinel_catalog_transport_start_catalog_contract_invalid'

$verifierManifest = Get-Content -LiteralPath $verifierManifestPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
Assert-True ($verifierManifest.contractId -ceq
        'nll/phase3b2-native-cache-long-path-verifier-manifest/v1' -and
    $verifierManifest.memberCount -eq 8 -and
    @($verifierManifest.members).Count -eq 8 -and
    $verifierManifest.sdkVersion -ceq '10.0.400') `
    'phase3b2_epinel_catalog_transport_start_verifier_manifest_invalid'
foreach ($member in @($verifierManifest.members)) {
    $relativePath = [string]$member.relativePath
    Assert-True (Test-SafeLeafName $relativePath) `
        'phase3b2_epinel_catalog_transport_start_verifier_path_invalid'
    $memberPath = Join-Path $verifierRoot $relativePath
    Assert-True ((Test-Path -LiteralPath $memberPath -PathType Leaf) -and
        (Get-Item -LiteralPath $memberPath).Length -eq
            [long]$member.byteLength -and
        (Get-Sha256Hex $memberPath) -ceq [string]$member.sha256) `
        'phase3b2_epinel_catalog_transport_start_verifier_member_invalid'
}

$inspectionOutput = & $dotnetPath $verifierDllPath `
    'inspect-cache-tree' $cacheRoot 2>&1
Assert-True ($LASTEXITCODE -eq 0) `
    'phase3b2_epinel_catalog_transport_start_cache_inspection_failed'
$inspection = (($inspectionOutput | Out-String) | ConvertFrom-Json)
Assert-True ($inspection.contractId -ceq
        'nll/phase3b2-native-cache-tree-inspection/v1' -and
    $inspection.longPathSafeEnumerationUsed -and
    $inspection.fileCount -eq 40111 -and
    [long]$inspection.contentByteLength -eq 39030643658L -and
    $inspection.partialMemberCount -eq 0) `
    'phase3b2_epinel_catalog_transport_start_cache_shape_invalid'

Get-NetFirewallRule -Group $extensionFirewallGroup `
    -ErrorAction SilentlyContinue | Remove-NetFirewallRule
Assert-True (@(Get-NetFirewallRule -Group $extensionFirewallGroup `
        -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_epinel_catalog_transport_start_stale_firewall_cleanup_failed'

$startText = (& $minimalStartPath `
    -RequiredLocalAssetUrl $headerUrl `
    -RequiredLocalAssetByteLength $expectedHeaderByteLength `
    -RequiredLocalAssetSha256 $expectedHeaderSha256 `
    -RequiredLocalCatalogContractPath $catalogContractPath `
    -RequiredLocalCatalogContractSha256 $expectedCatalogContractSha256 `
    -RequiredLocalSausContractPath $sausContractPath `
    -RequiredLocalSausContractSha256 $expectedSausContractSha256 |
    Out-String).Trim()
$start = $startText | ConvertFrom-Json
Assert-True ($start.contractId -ceq
        'nll/phase3b2-epinel-minimal-reference-start/v1' -and
    [Guid]::Parse([string]$start.assessmentUid) -ne [Guid]::Empty -and
    $start.tutorialOnlyRevisionVerified -and
    $start.tutorialOnlyRevisionUid -ceq $expectedTutorialRevisionUid -and
    $start.tutorialOnlyRevisionReceiptSha256 -ceq
        $expectedTutorialMaterializationReceiptSha256 -and
    $start.tutorialGroupCount -eq 40 -and
    $start.accountProgressionStateCode -ceq
        'tutorial_only_no_campaign_or_contents_open_projection' -and
    $start.externalHead -ceq $expectedExternalHead -and
    $start.externalTree -ceq $expectedExternalTree -and
    $start.serverRunning -and $start.physicalBootstrapRunning -and
    $start.clientExecutionStarted -and
    $start.successfulNonLoopbackConnectionCount -eq 0 -and
    $start.requiredLocalAssetPreflightPerformed -and
    $start.requiredLocalAssetLoopbackResolved -and
    $start.requiredLocalAssetHttpStatusCode -eq 200 -and
    $start.requiredLocalAssetObservedByteLength -eq
        $expectedHeaderByteLength -and
    $start.requiredLocalAssetObservedSha256 -ceq $expectedHeaderSha256 -and
    $start.requiredLocalCatalogContractSha256 -ceq
        $expectedCatalogContractSha256 -and
    $start.requiredLocalCatalogPreflightPerformed -and
    $start.requiredLocalCatalogBodyCount -eq 3 -and
    $start.requiredLocalCatalogSignatureCount -eq 3 -and
    $start.requiredLocalCatalogAllSqlite -and
    $start.requiredLocalSausContractSha256 -ceq
        $expectedSausContractSha256 -and
    $start.requiredLocalSausPreflightPerformed -and
    $start.requiredLocalSausBodyCount -eq 1 -and
    $start.requiredLocalSausSignatureCount -eq 1 -and
    $start.requiredLocalSausBodyCrc32Matched) `
    'phase3b2_epinel_catalog_transport_start_inner_receipt_invalid'

$bindingPath = Join-Path (
    'C:\NLL\Evidence\Phase3B2\Physical\epinel-minimal-reference-v1\' +
    [string]$start.assessmentUid
) 'native-cache.binding.receipt.json'
Assert-True (-not (Test-Path -LiteralPath $bindingPath)) `
    'phase3b2_epinel_catalog_transport_start_binding_collision'
$binding = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-epinel-native-cache-run-binding/v5'
    boundAtUtc = [DateTimeOffset]::UtcNow.ToString(
        "yyyy-MM-dd'T'HH:mm:ss'Z'"
    )
    assessmentUid = [string]$start.assessmentUid
    deploymentReceiptSha256 = $expectedDeploymentReceiptSha256
    verifierManifestSha256 = $expectedVerifierManifestSha256
    headerClosureReceiptSha256 = $expectedHeaderClosureReceiptSha256
    catalogTransportRepairReceiptSha256 =
        $expectedTransportRepairReceiptSha256
    catalogTransportContractSha256 = $expectedCatalogContractSha256
    sausStagingReceiptSha256 = $expectedSausStagingReceiptSha256
    sausContractSha256 = $expectedSausContractSha256
    tutorialOnlyRevisionVerified = $true
    tutorialOnlyRevisionUid = $expectedTutorialRevisionUid
    tutorialOnlyRevisionReceiptSha256 =
        $expectedTutorialMaterializationReceiptSha256
    tutorialStartBindingReceiptSha256 =
        $expectedTutorialStartBindingReceiptSha256
    tutorialWrapperRebindReceiptSha256 =
        Get-Sha256Hex $tutorialWrapperCorrectionReceiptPath
    tutorialGroupCount = 40
    accountProgressionStateCode =
        'tutorial_only_no_campaign_or_contents_open_projection'
    externalHead = $expectedExternalHead
    externalTree = $expectedExternalTree
    serverDllSha256 = $expectedServerDllSha256
    catalogBodyPreflightCount = 3
    catalogSignaturePreflightCount = 3
    catalogSqliteTransportVerifiedBeforeClientStart = $true
    sausEncryptedBodyVerifiedBeforeClientStart = $true
    sausSignatureVerifiedBeforeClientStart = $true
    sausBodyCrc32VerifiedBeforeClientStart = $true
    cacheInspectionContractId = [string]$inspection.contractId
    longPathSafeEnumerationUsed = $true
    activeCacheFileCount = [int]$inspection.fileCount
    activeCacheContentByteLength = [long]$inspection.contentByteLength
    officialOutboundFallbackUsed = $false
    officialLauncherExecutionStarted = $false
    clientExecutionStarted = $true
    nextStepCode =
        'select_global_observe_or_play_close_client_then_complete'
}
Write-Utf8NoBom $bindingPath (($binding | ConvertTo-Json -Depth 6) + "`n")

[pscustomobject]@{
    StartReceipt = $start
    NativeCacheBinding = $binding
    CompletionCommand =
        "& 'C:\NLL\Tools\Complete-Phase3B2-Epinel-Minimal.ps1' -ObservedStageCode <stage> -OutcomeCode <outcome>"
} | ConvertTo-Json -Depth 8
