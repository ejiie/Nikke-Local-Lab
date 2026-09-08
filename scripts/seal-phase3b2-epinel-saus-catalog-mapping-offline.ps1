#requires -Version 7.0

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Z]$')]
    [string]$MicronDriveLetter = 'E',
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$AssessmentUid = 'd78b3434-6d86-4479-b1d4-23dfd170483a',
    [string]$ProtectedRoot = (
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\' +
        'Micron-PrePhysicalLane-20260823\PhysicalP2\' +
        'EpinelSausCatalogMapping-v1'
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

function Get-Crc32Unsigned {
    param([byte[]]$Bytes)

    [uint32]$crc = [uint32]::MaxValue
    foreach ($value in $Bytes) {
        $crc = $crc -bxor [uint32]$value
        for ($bit = 0; $bit -lt 8; $bit++) {
            if (($crc -band 1) -ne 0) {
                $crc = ($crc -shr 1) -bxor [uint32]3988292384
            }
            else {
                $crc = $crc -shr 1
            }
        }
    }
    return [uint32]($crc -bxor [uint32]::MaxValue)
}

function Write-AtomicUtf8NoBom {
    param([string]$Path, [string]$Text)

    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporary = $Path + '.partial-' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText(
            $temporary,
            $Text,
            [Text.UTF8Encoding]::new($false)
        )
        Move-Item -LiteralPath $temporary -Destination $Path
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$micronDrive = $MicronDriveLetter + ':'
$baselinePath = Join-Path $micronDrive (
    'NLL\Evidence\Phase3B2\Physical\' +
    'epinel-saus-materialization-baseline-v1\' +
    $AssessmentUid + '\baseline.receipt.json'
)
$activePointerPath = Join-Path $micronDrive (
    'NLL\Evidence\Phase3B2\Physical\epinel-minimal-reference-v1\' +
    'active-run.pointer.json'
)
$cloneSausRoot = Join-Path $micronDrive (
    'NLL\Clients\NIKKE-150.6.9-Physical\Unity\' +
    'com_proximabeta_NIKKE\saus\saus'
)
$originalSausRoot = Join-Path $micronDrive (
    'NIKKE\Unity\com_proximabeta_NIKKE\saus\saus'
)
$derivedBodyPath = Join-Path $cloneSausRoot 'asset-catalog-0.cat'
$derivedSignaturePath = $derivedBodyPath + '.nds'
$numberedName = 'asset-catalog-2651531605.cat'
$numberedBodyPath = Join-Path $cloneSausRoot $numberedName
$numberedSignaturePath = $numberedBodyPath + '.nds'
$originalNumberedBodyPath = Join-Path $originalSausRoot $numberedName
$originalNumberedSignaturePath = $originalNumberedBodyPath + '.nds'
$streamingBodyPath = Join-Path $micronDrive (
    'NLL\Clients\NIKKE-150.6.9-Physical\NIKKE\game\' +
    'nikke_Data\StreamingAssets\aa\catalog.db'
)
$streamingSignaturePath = $streamingBodyPath + '.nds'
$serverRoot = Join-Path $micronDrive (
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
)
$serverLogPath = Join-Path $serverRoot 'logs\app-20260825.log'
$latestPath = Join-Path $serverRoot (
    'cache\prdenv\150-b059c3f36c\StandaloneWindows64\pck\' +
    'latest-651.txt'
)
$serverSausRevisionRoot = Join-Path $serverRoot (
    'cache\prdenv\150-b059c3f36c\StandaloneWindows64\pck\' +
    'saus\19e939d'
)
$inspectorRoot = Join-Path $repositoryRoot (
    'tools\Phase3B2\SausCatalogMemoryInspector'
)
$inspectorProgramPath = Join-Path $inspectorRoot 'Program.cs'
$inspectorProjectPath = Join-Path $inspectorRoot (
    'SausCatalogMemoryInspector.csproj'
)
$inspectorAssemblyPath = Join-Path $inspectorRoot (
    'bin\Release\net10.0\win-x64\' +
    'SausCatalogMemoryInspector.dll'
)
$dotnetPath = Join-Path $micronDrive 'Program Files\dotnet\dotnet.exe'
$receiptRoot = Join-Path $micronDrive (
    'NLL\Evidence\Phase3B2\Physical\' +
    'epinel-saus-catalog-mapping-v1\' + $AssessmentUid
)
$protectedReceiptRoot = Join-Path $ProtectedRoot $AssessmentUid
$receiptPath = Join-Path $receiptRoot 'mapping.receipt.json'
$protectedReceiptPath = Join-Path $protectedReceiptRoot `
    'mapping.receipt.json'

$expectedBaselineSha256 =
    'b342004950de0b9c0bd708b470f7d22e54f8057a78d41cbb27a12dcc94b390be'
$expectedNumberedBodySha256 =
    'a8ad0f199f5db1213658c3238369ad472a98db74bb3a15a274931119ca22d0df'
$expectedNumberedSignatureSha256 =
    '01de2cc79b8f04297faf262666a7701242a942ba74d48b513c0998ab08b91fa2'
$expectedStreamingBodySha256 =
    '808a4b6bfcc8ed579bbe8601c41c6c8fc50170327761ee0f9c8d385b72ae2839'
$expectedStreamingSignatureSha256 =
    '81285efa5ba789eec9a9377a94405f44c0d21089af13f42e08ee612a9cc7137e'
$expectedInspectorProgramSha256 =
    'c4a5445e0ba2e78c967b0e848fc5574ad8ba8a4a2391e4c61ae6a0936f578319'
$expectedInspectorProjectSha256 =
    '95e24a51393d90a58bbe2e1a74c78408224073cfe9b3f369241ebfb092fed6ac'
$expectedInspectorAssemblySha256 =
    '6d938f98994d396c2a8833ea4717a3da571e7dac05f0426e4654001e264c9fa6'
$expectedServerLogSha256 =
    '503fb15660f1e197b21acc600652b0b539dd2175da35076a4f7adb5bd6643368'
$emptySha256 =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'

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
) 'phase3b2_saus_mapping_wrong_disk_boundary'

foreach ($path in @(
        $baselinePath,
        $derivedBodyPath,
        $derivedSignaturePath,
        $numberedBodyPath,
        $numberedSignaturePath,
        $originalNumberedBodyPath,
        $originalNumberedSignaturePath,
        $streamingBodyPath,
        $streamingSignaturePath,
        $serverLogPath,
        $latestPath,
        $inspectorProgramPath,
        $inspectorProjectPath,
        $inspectorAssemblyPath,
        $dotnetPath
    )) {
    Assert-True (Test-Path -LiteralPath $path -PathType Leaf) `
        'phase3b2_saus_mapping_input_missing'
}
Assert-True (
    -not (Test-Path -LiteralPath $activePointerPath) -and
    -not (Test-Path -LiteralPath $receiptPath) -and
    -not (Test-Path -LiteralPath $protectedReceiptPath)
) 'phase3b2_saus_mapping_runtime_or_destination_shape_invalid'

Assert-True (
    (Test-Digest $baselinePath 3103L $expectedBaselineSha256) -and
    (Test-Digest $derivedBodyPath 0L $emptySha256) -and
    (Test-Digest $derivedSignaturePath 0L $emptySha256) -and
    (Test-Digest $numberedBodyPath 13476L $expectedNumberedBodySha256) -and
    (Test-Digest $numberedSignaturePath 96L `
        $expectedNumberedSignatureSha256) -and
    (Test-Digest $originalNumberedBodyPath 13476L `
        $expectedNumberedBodySha256) -and
    (Test-Digest $originalNumberedSignaturePath 96L `
        $expectedNumberedSignatureSha256) -and
    (Test-Digest $streamingBodyPath 10521463L `
        $expectedStreamingBodySha256) -and
    (Test-Digest $streamingSignaturePath 96L `
        $expectedStreamingSignatureSha256) -and
    (Test-Digest $serverLogPath 3033L $expectedServerLogSha256) -and
    (Test-Digest $inspectorProgramPath 6949L `
        $expectedInspectorProgramSha256) -and
    (Test-Digest $inspectorProjectPath 1687L `
        $expectedInspectorProjectSha256) -and
    (Test-Digest $inspectorAssemblyPath 32768L `
        $expectedInspectorAssemblySha256)
) 'phase3b2_saus_mapping_pinned_digest_invalid'

$baseline = Get-Content -LiteralPath $baselinePath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True (
    $baseline.contractId -ceq
        'nll/phase3b2-epinel-saus-materialization-baseline/v1' -and
    $baseline.assessmentUid -ceq $AssessmentUid -and
    -not $baseline.derivedTargetMappingVerified -and
    -not $baseline.derivedSignatureSemanticsVerified -and
    $baseline.runtimeColdAtSeal -and
    -not $baseline.retryAuthorized
) 'phase3b2_saus_mapping_baseline_contract_invalid'

$numberedInspectionText = & $dotnetPath $inspectorAssemblyPath `
    'saus_numbered_2651531605' $numberedBodyPath $numberedSignaturePath
Assert-True ($LASTEXITCODE -eq 0) `
    'phase3b2_saus_mapping_numbered_inspector_failed'
$numberedInspection = $numberedInspectionText | Out-String | ConvertFrom-Json

$streamingInspectionText = & $dotnetPath $inspectorAssemblyPath `
    'streamingassets_aa_catalog' $streamingBodyPath `
    $streamingSignaturePath
Assert-True ($LASTEXITCODE -eq 0) `
    'phase3b2_saus_mapping_streaming_inspector_failed'
$streamingInspection = $streamingInspectionText | Out-String |
    ConvertFrom-Json

$numberedTableNames = @($numberedInspection.tables.name)
$streamingTableNames = @($streamingInspection.tables.name)
Assert-True (
    $numberedInspection.contractId -ceq
        'nll/phase3b2-saus-catalog-memory-inspection/v1' -and
    $numberedInspection.encryptedCrc32UnsignedDecimal -ceq '2651531605' -and
    $numberedInspection.decryptedSqliteByteLength -eq 114688L -and
    $numberedInspection.decryptedSqliteSha256 -ceq
        'e81638c73f62bdffefa0b7bbe5465dd06ac4258c8318d2fd6beedd0d43982f41' -and
    $numberedInspection.sqliteIntegrityCheck -ceq 'ok' -and
    $numberedInspection.sqliteQuickCheck -ceq 'ok' -and
    $numberedInspection.tableCount -eq 5 -and
    (@($numberedTableNames) -join ',') -ceq
        'AssetEntity,DependencyGroup,FileInfoEntity,LabelToUnionEntity,TableVersion' -and
    -not $numberedInspection.decryptedContentPersisted -and
    -not $numberedInspection.rawTableRowsEmitted -and
    -not $numberedInspection.sourceMutationPerformed -and
    $streamingInspection.contractId -ceq
        'nll/phase3b2-saus-catalog-memory-inspection/v1' -and
    $streamingInspection.decryptedSqliteByteLength -eq 24707072L -and
    $streamingInspection.decryptedSqliteSha256 -ceq
        'bfeab43b74ec145d24aaf3b24849ad1ec829e2076e875cebaf90baa6aea15308' -and
    $streamingInspection.sqliteIntegrityCheck -ceq 'ok' -and
    $streamingInspection.sqliteQuickCheck -ceq 'ok' -and
    $streamingInspection.tableCount -eq 9 -and
    (@($streamingTableNames) -join ',') -ceq
        'entries,entry_data,hashes_by_label,internal_ids,key_entries,keys,provider_ids,resource_prov,types' -and
    -not $streamingInspection.decryptedContentPersisted -and
    -not $streamingInspection.rawTableRowsEmitted -and
    -not $streamingInspection.sourceMutationPerformed
) 'phase3b2_saus_mapping_memory_inspection_invalid'

$numberedBytes = [IO.File]::ReadAllBytes($numberedBodyPath)
try {
    $numberedCrc32 = Get-Crc32Unsigned $numberedBytes
}
finally {
    [Array]::Clear($numberedBytes, 0, $numberedBytes.Length)
}
$emptyCrc32 = Get-Crc32Unsigned ([byte[]]::new(0))
Assert-True (
    $numberedCrc32 -eq [uint32]2651531605 -and
    $emptyCrc32 -eq [uint32]0
) 'phase3b2_saus_mapping_crc32_derivation_invalid'

$derivedBody = Get-Item -LiteralPath $derivedBodyPath
$derivedSignature = Get-Item -LiteralPath $derivedSignaturePath
$modifiedDeltaMilliseconds = [Math]::Abs((
        $derivedBody.LastWriteTimeUtc -
        $derivedSignature.LastWriteTimeUtc
    ).TotalMilliseconds)
$createdDeltaMilliseconds = [Math]::Abs((
        $derivedBody.CreationTimeUtc -
        $derivedSignature.CreationTimeUtc
    ).TotalMilliseconds)
$modifiedInFailureSecond = @(
    Get-ChildItem -LiteralPath $cloneSausRoot -File -Recurse |
        Where-Object {
            $_.LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ss') -ceq
                '2026-08-24T15:04:45'
        }
)
Assert-True (
    $modifiedDeltaMilliseconds -lt 20 -and
    $createdDeltaMilliseconds -lt 20 -and
    $modifiedInFailureSecond.Count -eq 2 -and
    (@($modifiedInFailureSecond.Name | Sort-Object) -join ',') -ceq
        'asset-catalog-0.cat,asset-catalog-0.cat.nds'
) 'phase3b2_saus_mapping_derived_pair_timeline_invalid'

$serverLog = [IO.File]::ReadAllText($serverLogPath, [Text.Encoding]::UTF8)
$failureSecondLines = @($serverLog -split "`r?`n" | Where-Object {
        $_.StartsWith('2026-08-25 00:04:45,', [StringComparison]::Ordinal)
    })
$failureSecondRequestCount = @($failureSecondLines | Where-Object {
        $_ -match 'local_only_asset_cache_request$'
    }).Count
$failureSecondMissCount = @($failureSecondLines | Where-Object {
        $_ -match 'local_only_asset_cache_miss$'
    }).Count
Assert-True (
    $failureSecondRequestCount -eq 6 -and
    $failureSecondMissCount -eq 2
) 'phase3b2_saus_mapping_server_miss_timeline_invalid'
$serverLog = $null

$latestText = [IO.File]::ReadAllText($latestPath, [Text.Encoding]::UTF8)
$sausRevisionMatch = [regex]::Match(
    $latestText,
    '(?m)^saus:(?<revision>[0-9a-f]{7}),(?<stamp>[0-9]+)$'
)
Assert-True (
    $sausRevisionMatch.Success -and
    $sausRevisionMatch.Groups['revision'].Value -ceq '19e939d' -and
    (Test-Path -LiteralPath $serverSausRevisionRoot -PathType Container) -and
    @(Get-ChildItem -LiteralPath $serverSausRevisionRoot -File -Recurse).Count -eq 0
) 'phase3b2_saus_mapping_server_saus_cache_shape_invalid'
$latestText = $null

$signatureSamplePaths = @(
    $numberedSignaturePath,
    $streamingSignaturePath,
    (Join-Path $serverRoot (
        'cache\prdenv\150-b059c3f36c\StandaloneWindows64\pck\' +
        'core\150.6.b15\catalog.db.nds'
    )),
    (Join-Path $serverRoot (
        'cache\prdenv\150-b059c3f36c\StandaloneWindows64\pck\' +
        'dp\1d5645e\catalog.db.nds'
    )),
    (Join-Path $serverRoot (
        'cache\prdenv\150-b059c3f36c\StandaloneWindows64\pck\' +
        'fd\85b12fc\catalog.db.nds'
    ))
)
$signaturePrefixHashes = [Collections.Generic.List[string]]::new()
$signatureFullHashes = [Collections.Generic.List[string]]::new()
foreach ($path in $signatureSamplePaths) {
    Assert-True ((Get-Item -LiteralPath $path).Length -eq 96L) `
        'phase3b2_saus_mapping_signature_family_shape_invalid'
    $bytes = [IO.File]::ReadAllBytes($path)
    try {
        $prefix = [byte[]]$bytes[0..31]
        try {
            $prefixDigest = [Convert]::ToHexString(
                [Security.Cryptography.SHA256]::HashData($prefix)
            ).ToLowerInvariant()
            $signaturePrefixHashes.Add($prefixDigest)
            $signatureFullHashes.Add((Get-Sha256Hex $path))
        }
        finally {
            [Array]::Clear($prefix, 0, $prefix.Length)
        }
    }
    finally {
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
}
$uniquePrefixHashes = @($signaturePrefixHashes | Sort-Object -Unique)
$uniqueFullHashes = @($signatureFullHashes | Sort-Object -Unique)
Assert-True (
    $uniquePrefixHashes.Count -eq 1 -and
    $uniquePrefixHashes[0] -ceq
        'ff732921037bc74584f8dd8454535ee5bae3f04fa2f5121b91846771e657e02f' -and
    $uniqueFullHashes.Count -eq 5
) 'phase3b2_saus_mapping_signature_family_invalid'

$receipt = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-epinel-saus-catalog-mapping/v1'
    sealedAtUtc = [DateTimeOffset]::UtcNow.ToString(
        "yyyy-MM-dd'T'HH:mm:ss'Z'"
    )
    assessmentUid = $AssessmentUid
    environmentCode = 'samsung_boot_micron_offline_runtime_cold'
    baselineReceiptByteLength = 3103L
    baselineReceiptSha256 = $expectedBaselineSha256
    inspectorContractId =
        'nll/phase3b2-saus-catalog-memory-inspection/v1'
    inspectorProgramByteLength = 6949L
    inspectorProgramSha256 = $expectedInspectorProgramSha256
    inspectorProjectByteLength = 1687L
    inspectorProjectSha256 = $expectedInspectorProjectSha256
    inspectorAssemblyByteLength = 32768L
    inspectorAssemblySha256 = $expectedInspectorAssemblySha256
    numberedCatalogByteLength = 13476L
    numberedCatalogSha256 = $expectedNumberedBodySha256
    numberedCatalogFileSuffixUnsignedDecimal = '2651531605'
    numberedCatalogEncryptedCrc32UnsignedDecimal =
        $numberedCrc32.ToString()
    numberedCatalogFilenameCrc32Matched = $true
    numberedCatalogDecryptedByteLength = 114688L
    numberedCatalogDecryptedSha256 =
        $numberedInspection.decryptedSqliteSha256
    numberedCatalogSqliteIntegrityCheck =
        $numberedInspection.sqliteIntegrityCheck
    numberedCatalogSqliteQuickCheck =
        $numberedInspection.sqliteQuickCheck
    numberedCatalogSchemaCanonicalSha256 =
        $numberedInspection.schemaCanonicalSha256
    numberedCatalogTableCount = $numberedInspection.tableCount
    numberedCatalogTableNames = $numberedTableNames
    streamingCatalogByteLength = 10521463L
    streamingCatalogSha256 = $expectedStreamingBodySha256
    streamingCatalogDecryptedByteLength = 24707072L
    streamingCatalogDecryptedSha256 =
        $streamingInspection.decryptedSqliteSha256
    streamingCatalogSchemaCanonicalSha256 =
        $streamingInspection.schemaCanonicalSha256
    streamingCatalogTableCount = $streamingInspection.tableCount
    streamingCatalogTableNames = $streamingTableNames
    numberedAndStreamingCatalogRolesDistinct = $true
    derivedCatalogByteLength = 0L
    derivedCatalogSha256 = $emptySha256
    derivedCatalogFileSuffixUnsignedDecimal = '0'
    emptyBodyCrc32UnsignedDecimal = $emptyCrc32.ToString()
    derivedCatalogFilenameCrc32Matched = $true
    targetMappingCode =
        'asset_catalog_suffix_is_unsigned_crc32_of_encrypted_body'
    derivedTargetMappingVerified = $true
    numberedSignatureByteLength = 96L
    numberedSignatureSha256 = $expectedNumberedSignatureSha256
    originalInstallNumberedPairMatchesClone = $true
    derivedSignatureByteLength = 0L
    derivedSignatureSha256 = $emptySha256
    derivedBodyAndSignatureCreationDeltaMilliseconds =
        $createdDeltaMilliseconds
    derivedBodyAndSignatureWriteDeltaMilliseconds =
        $modifiedDeltaMilliseconds
    failureSecondClientModifiedMemberCount =
        $modifiedInFailureSecond.Count
    failureSecondLocalAssetRequestCount = $failureSecondRequestCount
    failureSecondLocalAssetCacheMissCount = $failureSecondMissCount
    serverSausRevision = $sausRevisionMatch.Groups['revision'].Value
    serverSausRevisionFileCount = 0
    signatureFamilySampleCount = $signatureSamplePaths.Count
    signatureFamilyCommonPrefixByteLength = 32
    signatureFamilyCommonPrefixSha256 = $uniquePrefixHashes[0]
    signatureFamilyUniqueMemberCount = $uniqueFullHashes.Count
    signaturePairMappingCode =
        'exact_body_basename_plus_nds_sidecar'
    derivedSignaturePairMappingVerified = $true
    signatureCryptographicVerificationPerformed = $false
    signatureCryptographicAuthorityClaimed = $false
    decryptionModeCode =
        'epinel_nkdb_decryptor_and_sqlite_deserialize_in_memory_only'
    rawDecryptedCatalogPersisted = $false
    rawTableRowsEmitted = $false
    sourceCacheModified = $false
    clientInstallModified = $false
    databaseRestored = $true
    sqliteRuntimeRemoved = $true
    hostsRestored = $true
    extensionFirewallRemoved = $true
    runtimeColdAtSeal = $true
    officialOutboundUsed = $false
    officialApiUsed = $false
    officialLoginUsed = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
    retryAuthorized = $false
    repairAdmissionCode =
        'stage_exact_official_encrypted_saus_body_and_nds_in_local_only_server_cache'
    nextStepCode =
        'offline_stage_exact_saus_http_pair_and_preflight_before_single_retry'
}
$receiptText = ($receipt | ConvertTo-Json -Depth 9) + "`n"

$createdFiles = [Collections.Generic.List[string]]::new()
try {
    Write-AtomicUtf8NoBom $receiptPath $receiptText
    $createdFiles.Add($receiptPath)
    Write-AtomicUtf8NoBom $protectedReceiptPath $receiptText
    $createdFiles.Add($protectedReceiptPath)

    $receiptSha256 = Get-Sha256Hex $receiptPath
    $protectedSha256 = Get-Sha256Hex $protectedReceiptPath
    Assert-True (
        (Get-Item -LiteralPath $receiptPath).Length -eq
            (Get-Item -LiteralPath $protectedReceiptPath).Length -and
        $receiptSha256 -ceq $protectedSha256
    ) 'phase3b2_saus_mapping_dual_seal_mismatch'

    [pscustomobject]@{
        Receipt = $receipt
        MicronReceiptPath = $receiptPath
        MicronReceiptByteLength = (Get-Item -LiteralPath $receiptPath).Length
        MicronReceiptSha256 = $receiptSha256
        SamsungProtectedReceiptPath = $protectedReceiptPath
        SamsungProtectedReceiptByteLength =
            (Get-Item -LiteralPath $protectedReceiptPath).Length
        SamsungProtectedReceiptSha256 = $protectedSha256
    } | ConvertTo-Json -Depth 10
}
catch {
    foreach ($path in $createdFiles) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force
        }
    }
    foreach ($directory in @($receiptRoot, $protectedReceiptRoot)) {
        if ((Test-Path -LiteralPath $directory -PathType Container) -and
            @(Get-ChildItem -LiteralPath $directory -Force).Count -eq 0) {
            Remove-Item -LiteralPath $directory -Force
        }
    }
    throw
}
