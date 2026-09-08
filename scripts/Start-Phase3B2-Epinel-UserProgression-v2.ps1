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
    '14bf845aec4cded1d80e8efb57a3eb4f4639ef68bd1fdf7a8d9de462689aae7d'
$expectedVerifierManifestSha256 =
    '3305d52786315bc927c46cdb988ce35b067d704f0a562be7aa469a188da3541c'
$expectedHeaderClosureReceiptSha256 =
    'bc5e9e0f8f45f17c4db0408cee3d8a88389e11d1578670e9733a2563535444ce'
$expectedTransportRepairReceiptSha256 =
    'fcd1469e6c348a91f2a9ef5bef02ad52d6a95099b20a3ff354c73fb36d40f430'
$expectedCatalogContractSha256 =
    '4e7903d912b3859691864b22a75a53e80881c744bd0fbee9e375036142d65654'
$expectedSausStagingReceiptSha256 =
    '2350aae3ba7320da21bb80a1eb26c118275b39b0678b3d844990742240f019e2'
$expectedSausContractSha256 =
    '0a29dc7d5bfbfd53cba8735029f9fbcc708834d678c7e51ea5a84b234fc3a65d'
$expectedGoldenMinimalStartToolSha256 =
    'a039cd5186df92c16c0091f7d4b4c4bbb907d0bf2adc3ff94d8d425699bc5f69'
$expectedCandidateDatabaseByteLength = 1396707L
$expectedCandidateDatabaseSha256 =
    'd73e92c9e8159b347f42eff5c6c2270e3695e91cd542c05f45bcbb121cd9a1ee'
$expectedCandidateAssessmentUid =
    'a69002f5-14e9-4f05-b9ab-9ca58b13925a'
$expectedStrictAuditUid =
    '8bd0bb59-0a75-44f8-8143-a689497486a8'
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
    'C:\NLL\Tools\start-phase3b2-epinel-user-progression-v2-in-micron.ps1'
$progressionEvidenceRoot =
    'C:\NLL\Evidence\Phase3B2\Physical\epinel-user-progression-v2'
$candidateStagingReceiptPath = Join-Path $progressionEvidenceRoot `
    'candidate-staging.receipt.json'
$strictAuditReceiptPath = Join-Path $progressionEvidenceRoot `
    'strict-audit.receipt.json'
$databasePath =
    'C:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\db.json'
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
    $sausToolBindingPath, $dotnetPath, $headerPath, $minimalStartPath,
    $serverDllPath, $candidateStagingReceiptPath, $strictAuditReceiptPath,
    $databasePath
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
    (Get-Sha256Hex $serverDllPath) -ceq $expectedServerDllSha256 -and
    (Get-Item -LiteralPath $databasePath).Length -eq
        $expectedCandidateDatabaseByteLength -and
    (Get-Sha256Hex $databasePath) -ceq
        $expectedCandidateDatabaseSha256 -and
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
        $expectedGoldenMinimalStartToolSha256 -and
    $sausToolBinding.wrapperToolSha256 -ceq 'fe667ba466ea27a5bfd55e09c4d0cd9ef94b04d434d95ac1590ccd7f813e493b'
) 'phase3b2_epinel_catalog_transport_start_saus_binding_invalid'

$candidateStaging = Get-Content -LiteralPath $candidateStagingReceiptPath `
    -Raw -Encoding UTF8 | ConvertFrom-Json
$strictAudit = Get-Content -LiteralPath $strictAuditReceiptPath `
    -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True (
    $candidateStaging.contractId -ceq
        'nll/phase3b2-user-progression-offline-candidate-staging/v2' -and
    $candidateStaging.assessmentUid -ceq
        $expectedCandidateAssessmentUid -and
    [long]$candidateStaging.candidateDatabaseByteLength -eq
        $expectedCandidateDatabaseByteLength -and
    $candidateStaging.candidateDatabaseSha256 -ceq
        $expectedCandidateDatabaseSha256 -and
    [int]$candidateStaging.completedScenarioCount -eq 611 -and
    [int]$candidateStaging.mainQuestCount -eq 595 -and
    [int]$candidateStaging.mainQuestRewardClaimedCount -eq 595 -and
    [int]$candidateStaging.contentsOpenUiStateCount -eq 73 -and
    $candidateStaging.soloRaidUiStateIncluded -and
    $candidateStaging.soloRaidMuseumExcluded -and
    [int]$candidateStaging.tutorialGroupCount -eq 40 -and
    [int]$candidateStaging.triggerCount -eq 4786 -and
    [int]$candidateStaging.stageClearHistoryCount -eq 0 -and
    -not $candidateStaging.unrelatedStateChanged -and
    -not $candidateStaging.wrapperModified -and
    -not $candidateStaging.wrapperBindingPerformed -and
    -not $candidateStaging.serverBinaryModified -and
    -not $candidateStaging.cacheModified -and
    -not $candidateStaging.localLowInspected -and
    -not $candidateStaging.localLowModified -and
    $strictAudit.contractId -ceq
        'nll/phase3b2-user-progression-strict-offline-audit/v1' -and
    $strictAudit.auditUid -ceq $expectedStrictAuditUid -and
    $strictAudit.candidateAssessmentUid -ceq
        $expectedCandidateAssessmentUid -and
    [long]$strictAudit.candidateDatabaseByteLength -eq
        $expectedCandidateDatabaseByteLength -and
    $strictAudit.candidateDatabaseSha256 -ceq
        $expectedCandidateDatabaseSha256 -and
    $strictAudit.scenarioReferencesVerifiedAgainstExactStageIndex -and
    $strictAudit.mainQuestReferencesVerified -and
    $strictAudit.contentsOpenReferencesVerified -and
    $strictAudit.allowedJsonChangeBoundaryVerified -and
    $strictAudit.sqliteOnlyTriggerRowsAndSequenceChanged -and
    $strictAudit.goldenSqliteIntegrityCode -ceq 'ok' -and
    $strictAudit.candidateSqliteIntegrityCode -ceq 'ok' -and
    [int]$strictAudit.foreignKeyViolationCount -eq 0 -and
    $strictAudit.verdictCode -ceq
        'strict_static_json_and_relational_gates_passed' -and
    -not $strictAudit.runtimeDatabaseModified -and
    -not $strictAudit.wrapperModified -and
    -not $strictAudit.wrapperBindingPerformed -and
    -not $strictAudit.innerStartModified -and
    -not $strictAudit.completionToolModified -and
    -not $strictAudit.serverBinaryModified -and
    -not $strictAudit.cacheModified -and
    -not $strictAudit.localLowInspected -and
    -not $strictAudit.localLowModified
) 'phase3b2_epinel_user_progression_contract_invalid'

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
    $inspection.fileCount -eq 40113 -and
    [long]$inspection.contentByteLength -eq 39031656543L -and
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
    'C:\NLL\Evidence\Phase3B2\Physical\epinel-user-progression-v2\' +
    [string]$start.assessmentUid
) 'native-cache.binding.receipt.json'
Assert-True (-not (Test-Path -LiteralPath $bindingPath)) `
    'phase3b2_epinel_catalog_transport_start_binding_collision'
$binding = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-epinel-user-progression-run-binding/v2'
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
    candidateAssessmentUid = $expectedCandidateAssessmentUid
    strictAuditUid = $expectedStrictAuditUid
    candidateDatabaseByteLength = $expectedCandidateDatabaseByteLength
    candidateDatabaseSha256 = $expectedCandidateDatabaseSha256
    progressionContractVerified = $true
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
        "& 'C:\NLL\Tools\Complete-Phase3B2-Epinel-UserProgression-v2.ps1' -ObservedStageCode <stage> -OutcomeCode <outcome>"
} | ConvertTo-Json -Depth 8
