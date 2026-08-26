[CmdletBinding()]
param(
    [ValidatePattern('^[A-Z]$')]
    [string]$MicronDriveLetter = 'E',
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$AcquisitionAssessmentUid =
        'b376a40d-dac1-45cb-a0b6-7b066d95ebcc',
    [ValidatePattern('^[0-9a-fA-F]{64}$')]
    [string]$ExpectedAcquisitionReceiptSha256 =
        'bbd7c02d523072ea264888033ad8e6ad9a143a9f6353e8a5750f550878617e4e',
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$DeploymentUid = ([Guid]::NewGuid().ToString('D')),
    [string]$ProtectedAcquisitionRoot = (
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\' +
        'Micron-PrePhysicalLane-20260823\PhysicalP2\' +
        'LocaleCatalogAcquisition\Sealed'
    ),
    [string]$ProtectedDeploymentRoot = (
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\' +
        'Micron-PrePhysicalLane-20260823\PhysicalP2\' +
        'EpinelLocaleCatalogOverlay-v1'
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
        Move-Item -LiteralPath $temporary -Destination $Path
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
        'phase3b2_locale_overlay_source_digest_invalid'
    $temporary = $Destination + '.partial-' +
        [Guid]::NewGuid().ToString('N')
    try {
        Copy-Item -LiteralPath $Source -Destination $temporary
        Assert-True (Test-Digest $temporary $ByteLength $Sha256) `
            'phase3b2_locale_overlay_temporary_digest_invalid'
        Move-Item -LiteralPath $temporary -Destination $Destination
        Assert-True (Test-Digest $Destination $ByteLength $Sha256) `
            'phase3b2_locale_overlay_destination_digest_invalid'
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Assert-StrictChildPath {
    param([string]$Parent, [string]$Child, [string]$FailureCode)

    $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
    $childFull = [IO.Path]::GetFullPath($Child)
    Assert-True ($childFull.StartsWith(
            $parentFull, [StringComparison]::OrdinalIgnoreCase
        )) $FailureCode
}

function Test-NkdbMagic {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    $stream = [IO.File]::Open(
        $Path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    try {
        $bytes = [byte[]]::new(4)
        if ($stream.Read($bytes, 0, 4) -ne 4) { return $false }
        return [Text.Encoding]::ASCII.GetString($bytes) -ceq 'NKDB'
    }
    finally { $stream.Dispose() }
}

function Get-CacheInspection {
    param([string]$DotnetPath, [string]$VerifierPath, [string]$CacheRoot)

    $output = & $DotnetPath $VerifierPath 'inspect-cache-tree' `
        $CacheRoot 2>&1
    Assert-True ($LASTEXITCODE -eq 0) `
        'phase3b2_locale_overlay_cache_inspection_failed'
    (($output | Out-String) | ConvertFrom-Json)
}

function Test-SafeVerifierLeafName {
    param([string]$RelativePath)
    -not [string]::IsNullOrWhiteSpace($RelativePath) -and
        -not [IO.Path]::IsPathRooted($RelativePath) -and
        $RelativePath -ceq [IO.Path]::GetFileName($RelativePath) -and
        -not $RelativePath.Contains('/') -and
        -not $RelativePath.Contains('\')
}

function Remove-ExactOverlayPair {
    param(
        [string]$TargetRoot,
        [string]$BodyPath,
        [long]$BodyLength,
        [string]$BodySha256,
        [string]$SignaturePath,
        [long]$SignatureLength,
        [string]$SignatureSha256,
        [bool]$KeepEmptyTargetDirectory
    )

    Assert-True (
        (Test-Digest $BodyPath $BodyLength $BodySha256) -and
        (Test-Digest $SignaturePath $SignatureLength $SignatureSha256) -and
        @(Get-ChildItem -LiteralPath $TargetRoot -Force).Count -eq 2 -and
        @(Get-ChildItem -LiteralPath $TargetRoot -Directory -Force).Count -eq 0
    ) 'phase3b2_locale_overlay_cleanup_target_not_exact'
    Remove-Item -LiteralPath $BodyPath -Force
    Remove-Item -LiteralPath $SignaturePath -Force
    Assert-True (@(Get-ChildItem -LiteralPath $TargetRoot -Force).Count -eq 0) `
        'phase3b2_locale_overlay_cleanup_target_not_empty'
    if (-not $KeepEmptyTargetDirectory) {
        Remove-Item -LiteralPath $TargetRoot -Force
    }
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$derivationToolPath = Join-Path $PSScriptRoot `
    'new-phase3b2-epinel-locale-overlay-start.ps1'
$micronDrive = $MicronDriveLetter + ':'
$serverRoot = Join-Path $micronDrive (
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
)
$cacheRoot = Join-Path $serverRoot 'cache'
$databasePath = Join-Path $serverRoot 'db.json'
$serverDllPath = Join-Path $serverRoot 'EpinelPS.dll'
$goldenStartPath = Join-Path $micronDrive `
    'NLL\Tools\Start-Phase3B2-Epinel-NativeCache.ps1'
$innerStartPath = Join-Path $micronDrive `
    'NLL\Tools\start-phase3b2-epinel-minimal-reference-in-micron.ps1'
$completionWrapperPath = Join-Path $micronDrive `
    'NLL\Tools\Complete-Phase3B2-Epinel-Minimal.ps1'
$innerCompletionPath = Join-Path $micronDrive `
    'NLL\Tools\complete-phase3b2-epinel-minimal-reference-in-micron.ps1'
$activePointerPath = Join-Path $micronDrive (
    'NLL\Evidence\Phase3B2\Physical\epinel-minimal-reference-v1\' +
    'active-run.pointer.json'
)
$goldenFinalizationPath = Join-Path $micronDrive (
    'NLL\Evidence\Phase3B2\Physical\epinel-lobby-golden-restore-v1\' +
    'b8476bb3-b212-476c-81e2-0d9c56a92399\' +
    'finalization.receipt.json'
)
$verifierRoot = Join-Path $micronDrive `
    'NLL\Tools\Phase3B2.NativeCacheVerifier-v1'
$verifierManifestPath = Join-Path $verifierRoot 'bundle.manifest.json'
$verifierDllPath = Join-Path $verifierRoot `
    'Phase3B2.NativeCacheMaterializer.dll'
$dotnetPath = Join-Path $micronDrive 'Program Files\dotnet\dotnet.exe'
$micronHostsPath = Join-Path $micronDrive `
    'Windows\System32\drivers\etc\hosts'
$sealedRoot = Join-Path $ProtectedAcquisitionRoot `
    $AcquisitionAssessmentUid
$acquisitionReceiptPath = Join-Path $sealedRoot `
    'acquisition.receipt.json'
$privateTransportPath = Join-Path $sealedRoot 'transport.private.json'
$sourceFreeManifestPath = Join-Path $sealedRoot `
    'source-free.manifest.tsv'
$sourceContentRoot = Join-Path $sealedRoot 'content'
$micronLaneRoot = Join-Path $micronDrive (
    'NLL\Evidence\Phase3B2\Physical\' +
    'epinel-locale-catalog-overlay-v1\' + $DeploymentUid
)
$protectedLaneRoot = Join-Path $ProtectedDeploymentRoot $DeploymentUid
$micronRollbackPlanPath = Join-Path $micronLaneRoot 'rollback.plan.json'
$protectedRollbackPlanPath = Join-Path $protectedLaneRoot `
    'rollback.plan.json'
$micronReceiptPath = Join-Path $micronLaneRoot `
    'deployment.receipt.json'
$protectedReceiptPath = Join-Path $protectedLaneRoot `
    'deployment.receipt.json'

$expectedAcquisitionReceiptSha256 =
    $ExpectedAcquisitionReceiptSha256.ToLowerInvariant()
$expectedGoldenFinalizationSha256 =
    '6d4c9fadd0c500cca3a95f3c2eeae7a141eacacc073167874c1eff2989d4a4e3'
$expectedGoldenDatabaseSha256 =
    'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194'
$expectedGoldenStartSha256 =
    'fe667ba466ea27a5bfd55e09c4d0cd9ef94b04d434d95ac1590ccd7f813e493b'
$expectedInnerStartSha256 =
    'a039cd5186df92c16c0091f7d4b4c4bbb907d0bf2adc3ff94d8d425699bc5f69'
$expectedCompletionWrapperSha256 =
    '16aa339bc83336b6bd3c72da21624eb890e336e22fb1c9672160fa745b0250c1'
$expectedInnerCompletionSha256 =
    '0ff9cc8285b46fe96d16fe1fe1aca532a6a2b39d89cc9a15f6c611444d63fe09'
$expectedServerDllSha256 =
    'aaa1e49d7a879a6b5ec17ad4c4094ce7d98ce86f860c1529a9ab4d6aecb51f7c'
$expectedVerifierManifestSha256 =
    '3305d52786315bc927c46cdb988ce35b067d704f0a562be7aa469a188da3541c'
$expectedBaseHostsSha256 =
    'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0'
$goldenCacheFileCount = 40111
$goldenCacheContentByteLength = 39030643658L

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
Assert-True ($principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )) 'phase3b2_locale_overlay_requires_administrator'

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
) 'phase3b2_locale_overlay_wrong_disk_boundary'

$requiredInputs = @(
    $derivationToolPath, $acquisitionReceiptPath, $privateTransportPath,
    $sourceFreeManifestPath, $goldenFinalizationPath, $goldenStartPath,
    $innerStartPath, $completionWrapperPath, $innerCompletionPath,
    $databasePath, $serverDllPath, $verifierManifestPath,
    $verifierDllPath, $dotnetPath, $micronHostsPath
)
Assert-True (@($requiredInputs | Where-Object {
            -not (Test-Path -LiteralPath $_ -PathType Leaf)
        }).Count -eq 0) 'phase3b2_locale_overlay_input_missing'
Assert-True (
    -not (Test-Path -LiteralPath $activePointerPath) -and
    @(Get-Process -Name EpinelPS, nikke, nikke_launcher,
        NikkeLocalLab.Phase3B2.PhysicalBootstrap `
        -ErrorAction SilentlyContinue).Count -eq 0 -and
    @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal' |
        Where-Object { Test-Path -LiteralPath (Join-Path $serverRoot $_) }
    ).Count -eq 0 -and
    -not (Test-Path -LiteralPath $micronLaneRoot) -and
    -not (Test-Path -LiteralPath $protectedLaneRoot)
) 'phase3b2_locale_overlay_runtime_or_destination_not_clean'

Assert-True (
    (Get-Sha256Hex $acquisitionReceiptPath) -ceq
        $expectedAcquisitionReceiptSha256 -and
    (Get-Sha256Hex $goldenFinalizationPath) -ceq
        $expectedGoldenFinalizationSha256 -and
    (Test-Digest $databasePath 413327L $expectedGoldenDatabaseSha256) -and
    (Test-Digest $goldenStartPath 15147L $expectedGoldenStartSha256) -and
    (Test-Digest $innerStartPath 39526L $expectedInnerStartSha256) -and
    (Test-Digest $completionWrapperPath 576L `
        $expectedCompletionWrapperSha256) -and
    (Test-Digest $innerCompletionPath 9968L `
        $expectedInnerCompletionSha256) -and
    (Get-Sha256Hex $serverDllPath) -ceq $expectedServerDllSha256 -and
    (Get-Sha256Hex $verifierManifestPath) -ceq
        $expectedVerifierManifestSha256 -and
    (Get-Sha256Hex $micronHostsPath) -ceq $expectedBaseHostsSha256
) 'phase3b2_locale_overlay_golden_or_acquisition_digest_invalid'

$goldenFinalization = Get-Content -LiteralPath $goldenFinalizationPath `
    -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True (
    $goldenFinalization.contractId -ceq
        'nll/phase3b2-epinel-lobby-golden-restore-finalization/v1' -and
    $goldenFinalization.goldenBaselineActive -and
    -not $goldenFinalization.tutorialRevisionActive -and
    -not $goldenFinalization.activeRunPointerPresent -and
    $goldenFinalization.sqliteRuntimeMemberCount -eq 0 -and
    $goldenFinalization.databaseSha256 -ceq
        $expectedGoldenDatabaseSha256 -and
    $goldenFinalization.outerWrapperSha256 -ceq
        $expectedGoldenStartSha256 -and
    $goldenFinalization.innerStartSha256 -ceq
        $expectedInnerStartSha256 -and
    -not $goldenFinalization.officialOutboundUsed -and
    -not $goldenFinalization.serverExecutionStarted -and
    -not $goldenFinalization.clientExecutionStarted
) 'phase3b2_locale_overlay_golden_contract_invalid'

$acquisition = Get-Content -LiteralPath $acquisitionReceiptPath `
    -Raw -Encoding UTF8 | ConvertFrom-Json
$transport = Get-Content -LiteralPath $privateTransportPath `
    -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True (
    $acquisition.contractId -ceq
        'nll/phase3b2-static-locale-catalog-acquisition/v1' -and
    $acquisition.assessmentUid -ceq $AcquisitionAssessmentUid -and
    $acquisition.environmentCode -ceq
        'samsung_boot_micron_offline_runtime_cold' -and
    $acquisition.clientBuild -ceq '150.6.9' -and
    $acquisition.requestedMemberCount -eq 2 -and
    $acquisition.acquiredMemberCount -eq 2 -and
    $acquisition.nkdbBodyCount -eq 1 -and
    $acquisition.detachedSignatureCount -eq 1 -and
    $acquisition.detachedSignatureByteLength -eq 96 -and
    $acquisition.signatureShapeVerified -and
    $acquisition.nkdbMagicVerified -and
    -not $acquisition.signatureCryptographicVerificationPerformed -and
    -not $acquisition.micronMutationPerformed -and
    -not $acquisition.serverExecutionStarted -and
    -not $acquisition.clientExecutionStarted -and
    $acquisition.verdictCode -ceq
        'exact_locale_catalog_pair_acquired_and_sealed' -and
    (Test-Digest $privateTransportPath `
        ([long]$acquisition.privateTransportManifestByteLength) `
        ([string]$acquisition.privateTransportManifestSha256)) -and
    (Test-Digest $sourceFreeManifestPath `
        ([long]$acquisition.canonicalByteLength) `
        ([string]$acquisition.canonicalSha256))
) 'phase3b2_locale_overlay_acquisition_contract_invalid'
Assert-True (
    $transport.contractId -ceq
        'nll/phase3b2-static-locale-catalog-private-transport/v1' -and
    $transport.assessmentUid -ceq $AcquisitionAssessmentUid -and
    $transport.requestSetUid -ceq $acquisition.requestSetUid -and
    $transport.requestManifestSha256 -ceq
        $acquisition.requestManifestSha256 -and
    $transport.versionMapSha256 -ceq $acquisition.versionMapSha256 -and
    $transport.localeCode -ceq $acquisition.localeCode -and
    $transport.revisionCode -ceq $acquisition.revisionCode -and
    @($transport.members).Count -eq 2
) 'phase3b2_locale_overlay_transport_contract_invalid'

$localeCode = [string]$acquisition.localeCode
$revisionCode = [string]$acquisition.revisionCode
Assert-True (
    $localeCode -cmatch '^[a-z]{2}$' -and
    $revisionCode -cmatch '^[0-9a-f]{7}$'
) 'phase3b2_locale_overlay_locale_or_revision_invalid'
$body = @($transport.members)[0]
$signature = @($transport.members)[1]
$expectedRelativeBase =
    'prdenv/150-b059c3f36c/StandaloneWindows64/pck/' +
    $localeCode + '/' + $revisionCode + '/asset-catalog.cat'
Assert-True (
    $body.roleCode -ceq 'locale_catalog_body' -and
    $body.kindCode -ceq 'nkdb_body' -and
    $body.relativePath -ceq $expectedRelativeBase -and
    $body.uri -ceq ('https://cloud.nikke-kr.com/' +
        $expectedRelativeBase) -and
    [long]$body.byteLength -gt 4 -and
    [string]$body.sha256 -cmatch '^[0-9a-f]{64}$' -and
    $body.httpStatusCode -eq 200 -and
    $signature.roleCode -ceq 'locale_catalog_signature' -and
    $signature.kindCode -ceq 'detached_signature_96' -and
    $signature.relativePath -ceq ($expectedRelativeBase + '.nds') -and
    $signature.uri -ceq ('https://cloud.nikke-kr.com/' +
        $expectedRelativeBase + '.nds') -and
    [long]$signature.byteLength -eq 96 -and
    [string]$signature.sha256 -cmatch '^[0-9a-f]{64}$' -and
    $signature.httpStatusCode -eq 200 -and
    ([long]$body.byteLength + [long]$signature.byteLength) -eq
        [long]$acquisition.totalContentByteLength
) 'phase3b2_locale_overlay_member_contract_invalid'

$bodyRelativeWindows = ([string]$body.relativePath).Replace('/', '\')
$signatureRelativeWindows =
    ([string]$signature.relativePath).Replace('/', '\')
$sourceBodyPath = Join-Path $sourceContentRoot $bodyRelativeWindows
$sourceSignaturePath = Join-Path $sourceContentRoot `
    $signatureRelativeWindows
$targetBodyPath = Join-Path $cacheRoot $bodyRelativeWindows
$targetSignaturePath = Join-Path $cacheRoot $signatureRelativeWindows
$targetRoot = Split-Path -Parent $targetBodyPath
$targetParent = Split-Path -Parent $targetRoot
$derivedStartLeaf =
    'Start-Phase3B2-Epinel-LocaleOverlay-' + $localeCode + '.ps1'
$derivedStartPath = Join-Path $micronDrive `
    ('NLL\Tools\' + $derivedStartLeaf)

Assert-StrictChildPath $sourceContentRoot $sourceBodyPath `
    'phase3b2_locale_overlay_source_path_escaped'
Assert-StrictChildPath $sourceContentRoot $sourceSignaturePath `
    'phase3b2_locale_overlay_source_path_escaped'
Assert-StrictChildPath $cacheRoot $targetBodyPath `
    'phase3b2_locale_overlay_target_path_escaped'
Assert-StrictChildPath $cacheRoot $targetSignaturePath `
    'phase3b2_locale_overlay_target_path_escaped'
Assert-True (
    (Test-Digest $sourceBodyPath ([long]$body.byteLength) `
        ([string]$body.sha256)) -and
    (Test-Digest $sourceSignaturePath ([long]$signature.byteLength) `
        ([string]$signature.sha256)) -and
    (Test-NkdbMagic $sourceBodyPath)
) 'phase3b2_locale_overlay_sealed_member_invalid'

$targetDirectoryPreexistedEmpty = Test-Path -LiteralPath $targetRoot `
    -PathType Container
if ($targetDirectoryPreexistedEmpty) {
    Assert-True (@(Get-ChildItem -LiteralPath $targetRoot -Force).Count -eq 0) `
        'phase3b2_locale_overlay_target_directory_not_empty'
}
Assert-True (
    -not (Test-Path -LiteralPath $targetBodyPath) -and
    -not (Test-Path -LiteralPath $targetSignaturePath) -and
    -not (Test-Path -LiteralPath $derivedStartPath) -and
    @(Get-ChildItem -LiteralPath (Split-Path -Parent $derivedStartPath) `
        -Filter 'Start-Phase3B2-Epinel-LocaleOverlay-*.ps1' -File `
        -ErrorAction SilentlyContinue).Count -eq 0
) 'phase3b2_locale_overlay_already_active_or_target_present'

$verifierManifest = Get-Content -LiteralPath $verifierManifestPath `
    -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True (
    $verifierManifest.contractId -ceq
        'nll/phase3b2-native-cache-long-path-verifier-manifest/v1' -and
    $verifierManifest.memberCount -eq 8 -and
    @($verifierManifest.members).Count -eq 8
) 'phase3b2_locale_overlay_verifier_manifest_invalid'
foreach ($member in @($verifierManifest.members)) {
    $relativePath = [string]$member.relativePath
    Assert-True (Test-SafeVerifierLeafName $relativePath) `
        'phase3b2_locale_overlay_verifier_path_invalid'
    Assert-True (Test-Digest (Join-Path $verifierRoot $relativePath) `
        ([long]$member.byteLength) ([string]$member.sha256)) `
        'phase3b2_locale_overlay_verifier_member_invalid'
}

$before = Get-CacheInspection $dotnetPath $verifierDllPath $cacheRoot
Assert-True (
    $before.contractId -ceq
        'nll/phase3b2-native-cache-tree-inspection/v1' -and
    $before.longPathSafeEnumerationUsed -and
    $before.fileCount -eq $goldenCacheFileCount -and
    [long]$before.contentByteLength -eq
        $goldenCacheContentByteLength -and
    $before.partialMemberCount -eq 0
) 'phase3b2_locale_overlay_before_cache_shape_invalid'

$afterFileCount = $goldenCacheFileCount + 2
$afterContentByteLength = $goldenCacheContentByteLength +
    [long]$acquisition.totalContentByteLength
$derivationToolSha256 = Get-Sha256Hex $derivationToolPath
$rollbackPlan = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-epinel-locale-overlay-rollback-plan/v1'
    deploymentUid = $DeploymentUid
    acquisitionAssessmentUid = $AcquisitionAssessmentUid
    acquisitionReceiptSha256 = $expectedAcquisitionReceiptSha256
    localeCode = $localeCode
    revisionCode = $revisionCode
    bodyRelativePath = [string]$body.relativePath
    bodyByteLength = [long]$body.byteLength
    bodySha256 = [string]$body.sha256
    signatureRelativePath = [string]$signature.relativePath
    signatureByteLength = [long]$signature.byteLength
    signatureSha256 = [string]$signature.sha256
    derivedStartLeaf = $derivedStartLeaf
    targetDirectoryPreexistedEmpty = $targetDirectoryPreexistedEmpty
    expectedCacheFileCountAfterRollback = $goldenCacheFileCount
    expectedCacheContentByteLengthAfterRollback =
        $goldenCacheContentByteLength
    expectedGoldenStartSha256 = $expectedGoldenStartSha256
    runtimeMustBeCold = $true
    removeOnlyIfExact = $true
}
$rollbackPlanText = ($rollbackPlan | ConvertTo-Json -Depth 6) + "`n"
Write-AtomicUtf8NoBom $micronRollbackPlanPath $rollbackPlanText
Write-AtomicUtf8NoBom $protectedRollbackPlanPath $rollbackPlanText
$rollbackPlanSha256 = Get-Sha256Hex $micronRollbackPlanPath
Assert-True (
    $rollbackPlanSha256 -ceq
        (Get-Sha256Hex $protectedRollbackPlanPath)
) 'phase3b2_locale_overlay_rollback_plan_dual_seal_invalid'

$stagingRoot = Join-Path $targetParent (
    '.locale-overlay-staging-' + $DeploymentUid.Replace('-', '')
)
Assert-StrictChildPath $cacheRoot $stagingRoot `
    'phase3b2_locale_overlay_staging_path_escaped'
$pairApplied = $false
$derivedStartCreated = $false
try {
    New-Item -ItemType Directory -Path $stagingRoot | Out-Null
    $stagedBodyPath = Join-Path $stagingRoot 'asset-catalog.cat'
    $stagedSignaturePath = Join-Path $stagingRoot `
        'asset-catalog.cat.nds'
    Copy-AtomicVerified $sourceBodyPath $stagedBodyPath `
        ([long]$body.byteLength) ([string]$body.sha256)
    Copy-AtomicVerified $sourceSignaturePath $stagedSignaturePath `
        ([long]$signature.byteLength) ([string]$signature.sha256)
    Assert-True (
        @(Get-ChildItem -LiteralPath $stagingRoot -File -Force).Count -eq 2 -and
        @(Get-ChildItem -LiteralPath $stagingRoot -Directory -Force).Count -eq 0
    ) 'phase3b2_locale_overlay_staging_directory_shape_invalid'

    if ($targetDirectoryPreexistedEmpty) {
        Remove-Item -LiteralPath $targetRoot -Force
    }
    try {
        Move-Item -LiteralPath $stagingRoot -Destination $targetRoot
    }
    catch {
        if ($targetDirectoryPreexistedEmpty -and
            -not (Test-Path -LiteralPath $targetRoot)) {
            New-Item -ItemType Directory -Path $targetRoot | Out-Null
        }
        throw
    }
    $pairApplied = $true

    $derivationJson = & $derivationToolPath `
        -GoldenStartPath $goldenStartPath `
        -DerivedStartPath $derivedStartPath `
        -ExpectedGoldenStartSha256 $expectedGoldenStartSha256 `
        -CacheFileCountBefore $goldenCacheFileCount `
        -CacheContentByteLengthBefore $goldenCacheContentByteLength `
        -CacheFileCountAfter $afterFileCount `
        -CacheContentByteLengthAfter $afterContentByteLength
    $derivedStartCreated = Test-Path -LiteralPath $derivedStartPath `
        -PathType Leaf
    $derivation = (($derivationJson | Out-String) | ConvertFrom-Json)
    Assert-True (
        $derivation.contractId -ceq
            'nll/phase3b2-epinel-locale-overlay-start-derivation/v1' -and
        $derivation.exactExpressionReplacementCount -eq 2 -and
        $derivation.reverseProjectionVerified -and
        $derivation.goldenStartUnchanged -and
        (Get-Sha256Hex $derivedStartPath) -ceq
            [string]$derivation.derivedStartSha256
    ) 'phase3b2_locale_overlay_derived_start_invalid'

    $after = Get-CacheInspection $dotnetPath $verifierDllPath $cacheRoot
    Assert-True (
        $after.contractId -ceq
            'nll/phase3b2-native-cache-tree-inspection/v1' -and
        $after.longPathSafeEnumerationUsed -and
        $after.fileCount -eq $afterFileCount -and
        [long]$after.contentByteLength -eq $afterContentByteLength -and
        $after.partialMemberCount -eq 0 -and
        (Test-Digest $targetBodyPath ([long]$body.byteLength) `
            ([string]$body.sha256)) -and
        (Test-Digest $targetSignaturePath ([long]$signature.byteLength) `
            ([string]$signature.sha256))
    ) 'phase3b2_locale_overlay_after_cache_shape_invalid'

    Assert-True (
        (Get-Sha256Hex $goldenStartPath) -ceq
            $expectedGoldenStartSha256 -and
        (Get-Sha256Hex $innerStartPath) -ceq $expectedInnerStartSha256 -and
        (Get-Sha256Hex $completionWrapperPath) -ceq
            $expectedCompletionWrapperSha256 -and
        (Get-Sha256Hex $innerCompletionPath) -ceq
            $expectedInnerCompletionSha256 -and
        (Get-Sha256Hex $databasePath) -ceq
            $expectedGoldenDatabaseSha256 -and
        (Get-Sha256Hex $serverDllPath) -ceq $expectedServerDllSha256 -and
        (Get-Sha256Hex $micronHostsPath) -ceq $expectedBaseHostsSha256
    ) 'phase3b2_locale_overlay_golden_changed_during_staging'

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-epinel-locale-catalog-overlay/v1'
        stagedAtUtc = [DateTimeOffset]::UtcNow.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'"
        )
        deploymentUid = $DeploymentUid
        acquisitionAssessmentUid = $AcquisitionAssessmentUid
        acquisitionReceiptSha256 = $expectedAcquisitionReceiptSha256
        privateTransportManifestSha256 =
            [string]$acquisition.privateTransportManifestSha256
        sourceFreeManifestSha256 = [string]$acquisition.canonicalSha256
        clientBuild = [string]$acquisition.clientBuild
        localeCode = $localeCode
        revisionCode = $revisionCode
        contentVersion = [long]$acquisition.contentVersion
        bodyByteLength = [long]$body.byteLength
        bodySha256 = [string]$body.sha256
        signatureByteLength = [long]$signature.byteLength
        signatureSha256 = [string]$signature.sha256
        nkdbMagicVerified = $true
        signatureShapeVerified = $true
        signatureCryptographicVerificationPerformed = $false
        targetDirectoryPreexistedEmpty = $targetDirectoryPreexistedEmpty
        pairAppliedBySameVolumeDirectoryRename = $true
        activeCacheFileCountBefore = [int]$before.fileCount
        activeCacheContentByteLengthBefore =
            [long]$before.contentByteLength
        activeCacheFileCountAfter = [int]$after.fileCount
        activeCacheContentByteLengthAfter =
            [long]$after.contentByteLength
        activeCachePartialMemberCountAfter =
            [int]$after.partialMemberCount
        derivationToolSha256 = $derivationToolSha256
        goldenStartByteLength = [long]$derivation.goldenStartByteLength
        goldenStartSha256 = $expectedGoldenStartSha256
        derivedStartLeaf = $derivedStartLeaf
        derivedStartByteLength = [long]$derivation.derivedStartByteLength
        derivedStartSha256 = [string]$derivation.derivedStartSha256
        exactExpressionReplacementCount = 2
        reverseProjectionVerified = $true
        goldenStartModified = $false
        innerStartModified = $false
        completionToolsModified = $false
        completionCompatibilityCode =
            'existing_golden_completion_uses_inner_active_pointer'
        runtimeToolBindingPerformed = $false
        databaseModified = $false
        serverBinaryModified = $false
        hostsModified = $false
        existingOperatorCacheInspected = $false
        existingOperatorCacheModified = $false
        localLowInspected = $false
        localLowModified = $false
        officialOutboundUsed = $false
        officialApiUsed = $false
        officialLoginUsed = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        rollbackPlanSha256 = $rollbackPlanSha256
        singleValidationRunAuthorized = $true
        validationRunConsumed = $false
        nextStepCode =
            'review_then_boot_micron_run_locale_overlay_validation_once'
    }
    $receiptText = ($receipt | ConvertTo-Json -Depth 7) + "`n"
    Write-AtomicUtf8NoBom $micronReceiptPath $receiptText
    Write-AtomicUtf8NoBom $protectedReceiptPath $receiptText
    $receiptSha256 = Get-Sha256Hex $micronReceiptPath
    Assert-True ($receiptSha256 -ceq
        (Get-Sha256Hex $protectedReceiptPath)) `
        'phase3b2_locale_overlay_receipt_dual_seal_invalid'

    [pscustomobject]@{
        Receipt = $receipt
        MicronReceiptPath = $micronReceiptPath
        MicronReceiptByteLength =
            [long](Get-Item -LiteralPath $micronReceiptPath).Length
        MicronReceiptSha256 = $receiptSha256
        ProtectedReceiptPath = $protectedReceiptPath
        MicronStartCommand =
            "& 'C:\NLL\Tools\$derivedStartLeaf'"
        MicronCompletionCommand =
            "& 'C:\NLL\Tools\Complete-Phase3B2-Epinel-Minimal.ps1' " +
            '-ObservedStageCode <stage> -OutcomeCode <outcome>'
    } | ConvertTo-Json -Depth 8
}
catch {
    $originalError = $_
    if (Test-Path -LiteralPath $derivedStartPath -PathType Leaf) {
        Remove-Item -LiteralPath $derivedStartPath -Force
    }
    if ($pairApplied -and
        (Test-Path -LiteralPath $targetRoot -PathType Container)) {
        Remove-ExactOverlayPair -TargetRoot $targetRoot `
            -BodyPath $targetBodyPath -BodyLength ([long]$body.byteLength) `
            -BodySha256 ([string]$body.sha256) `
            -SignaturePath $targetSignaturePath `
            -SignatureLength ([long]$signature.byteLength) `
            -SignatureSha256 ([string]$signature.sha256) `
            -KeepEmptyTargetDirectory $targetDirectoryPreexistedEmpty
    }
    throw $originalError
}
finally {
    if (Test-Path -LiteralPath $stagingRoot -PathType Container) {
        $stagingItems = @(Get-ChildItem -LiteralPath $stagingRoot -Force)
        Assert-True (
            @($stagingItems | Where-Object { $_.PSIsContainer }).Count -eq 0 -and
            @($stagingItems).Count -le 2
        ) 'phase3b2_locale_overlay_temporary_cleanup_not_safe'
        foreach ($item in $stagingItems) {
            Remove-Item -LiteralPath $item.FullName -Force
        }
        Remove-Item -LiteralPath $stagingRoot -Force
    }
}
