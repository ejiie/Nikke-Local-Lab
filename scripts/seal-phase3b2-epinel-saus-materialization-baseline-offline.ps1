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
        'EpinelSausMaterializationBaseline-v1'
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

function Get-ByteArraySha256Hex {
    param([byte[]]$Bytes)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha.ComputeHash($Bytes)
        try {
            return (($digest | ForEach-Object {
                        $_.ToString('x2')
                    }) -join '')
        }
        finally {
            [Array]::Clear($digest, 0, $digest.Length)
        }
    }
    finally {
        $sha.Dispose()
    }
}

function Test-Digest {
    param(
        [string]$Path,
        [long]$ByteLength,
        [string]$Sha256
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    return (Get-Item -LiteralPath $Path).Length -eq $ByteLength -and
        (Get-Sha256Hex $Path) -ceq $Sha256
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

$micronDrive = $MicronDriveLetter + ':'
$runRoot = Join-Path $micronDrive (
    'NLL\Evidence\Phase3B2\Physical\epinel-minimal-reference-v1\' +
    $AssessmentUid
)
$runStartPath = Join-Path $runRoot 'run-start.receipt.json'
$completionPath = Join-Path $runRoot 'completion.receipt.json'
$bindingPath = Join-Path $runRoot 'native-cache.binding.receipt.json'
$activePointerPath = Join-Path $micronDrive (
    'NLL\Evidence\Phase3B2\Physical\epinel-minimal-reference-v1\' +
    'active-run.pointer.json'
)
$playerLogPath = Join-Path $micronDrive (
    'Users\nlloperator\AppData\LocalLow\com.proximabeta\NIKKE\' +
    'Player.log'
)
$cloneSausRoot = Join-Path $micronDrive (
    'NLL\Clients\NIKKE-150.6.9-Physical\Unity\' +
    'com_proximabeta_NIKKE\saus\saus'
)
$originalSausRoot = Join-Path $micronDrive (
    'NIKKE\Unity\com_proximabeta_NIKKE\saus\saus'
)
$derivedCatalogPath = Join-Path $cloneSausRoot 'asset-catalog-0.cat'
$derivedSignaturePath = $derivedCatalogPath + '.nds'
$numberedCatalogName = 'asset-catalog-2651531605.cat'
$numberedCatalogPath = Join-Path $cloneSausRoot $numberedCatalogName
$numberedSignaturePath = $numberedCatalogPath + '.nds'
$originalNumberedCatalogPath = Join-Path $originalSausRoot `
    $numberedCatalogName
$originalNumberedSignaturePath = $originalNumberedCatalogPath + '.nds'
$epinelAssemblyPath = Join-Path $micronDrive (
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\' +
    'EpinelPS.dll'
)
$micronReceiptRoot = Join-Path $micronDrive (
    'NLL\Evidence\Phase3B2\Physical\' +
    'epinel-saus-materialization-baseline-v1\' + $AssessmentUid
)
$protectedReceiptRoot = Join-Path $ProtectedRoot $AssessmentUid
$micronReceiptPath = Join-Path $micronReceiptRoot `
    'baseline.receipt.json'
$protectedReceiptPath = Join-Path $protectedReceiptRoot `
    'baseline.receipt.json'

$expectedRunStartSha256 =
    '62647b3939e65180ea0272a45577f65ae4eba9062f8ecc8b94cf560c3747a72a'
$expectedCompletionSha256 =
    '135f10e68a07f10b1fd5550be9333bdc1c2448e7af0946133162956625de11af'
$expectedBindingSha256 =
    'd38698828443318b150485ee0e5d17518f5ab4cdee06a8ba5da3980bb149fc92'
$expectedPlayerLogSha256 =
    'b0a5a75e08ec513e2ecb38fc45633ffc008c9b29d21d903d58d3322b41103cee'
$emptySha256 =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
$expectedNumberedCatalogSha256 =
    'a8ad0f199f5db1213658c3238369ad472a98db74bb3a15a274931119ca22d0df'
$expectedNumberedSignatureSha256 =
    '01de2cc79b8f04297faf262666a7701242a942ba74d48b513c0998ab08b91fa2'
$expectedDecryptedCatalogSha256 =
    'e81638c73f62bdffefa0b7bbe5465dd06ac4258c8318d2fd6beedd0d43982f41'

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
) 'phase3b2_saus_baseline_wrong_disk_boundary'

foreach ($path in @(
        $runStartPath,
        $completionPath,
        $bindingPath,
        $playerLogPath,
        $derivedCatalogPath,
        $derivedSignaturePath,
        $numberedCatalogPath,
        $numberedSignaturePath,
        $originalNumberedCatalogPath,
        $originalNumberedSignaturePath,
        $epinelAssemblyPath
    )) {
    Assert-True (Test-Path -LiteralPath $path -PathType Leaf) `
        'phase3b2_saus_baseline_input_missing'
}
Assert-True (
    -not (Test-Path -LiteralPath $activePointerPath) -and
    -not (Test-Path -LiteralPath $micronReceiptPath) -and
    -not (Test-Path -LiteralPath $protectedReceiptPath)
) 'phase3b2_saus_baseline_runtime_or_destination_shape_invalid'

Assert-True (
    (Test-Digest $runStartPath 2440L $expectedRunStartSha256) -and
    (Test-Digest $completionPath 1745L $expectedCompletionSha256) -and
    (Test-Digest $bindingPath 1531L $expectedBindingSha256) -and
    (Test-Digest $playerLogPath 72086L $expectedPlayerLogSha256) -and
    (Test-Digest $derivedCatalogPath 0L $emptySha256) -and
    (Test-Digest $derivedSignaturePath 0L $emptySha256) -and
    (Test-Digest $numberedCatalogPath 13476L `
        $expectedNumberedCatalogSha256) -and
    (Test-Digest $numberedSignaturePath 96L `
        $expectedNumberedSignatureSha256) -and
    (Test-Digest $originalNumberedCatalogPath 13476L `
        $expectedNumberedCatalogSha256) -and
    (Test-Digest $originalNumberedSignaturePath 96L `
        $expectedNumberedSignatureSha256)
) 'phase3b2_saus_baseline_pinned_digest_invalid'

$runStart = Get-Content -LiteralPath $runStartPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$completion = Get-Content -LiteralPath $completionPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$binding = Get-Content -LiteralPath $bindingPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True (
    $runStart.contractId -ceq
        'nll/phase3b2-epinel-minimal-reference-start/v1' -and
    $runStart.assessmentUid -ceq $AssessmentUid -and
    $runStart.requiredLocalAssetPreflightPerformed -and
    $runStart.requiredLocalCatalogPreflightPerformed -and
    $runStart.requiredLocalCatalogBodyCount -eq 3 -and
    $runStart.requiredLocalCatalogSignatureCount -eq 3 -and
    $runStart.requiredLocalCatalogAllSqlite -and
    $runStart.successfulNonLoopbackConnectionCount -eq 0 -and
    $completion.contractId -ceq
        'nll/phase3b2-epinel-minimal-reference-completion/v1' -and
    $completion.assessmentUid -ceq $AssessmentUid -and
    $completion.observedStageCode -ceq 'catalogue_path' -and
    $completion.outcomeCode -ceq 'system_error' -and
    $completion.databaseRestored -and
    $completion.sqliteRuntimeRemoved -and
    $completion.hostsRestored -and
    $completion.extensionFirewallRemoved -and
    $completion.runtimeColdAfterCompletion -and
    $completion.playerLogSha256 -ceq $expectedPlayerLogSha256 -and
    -not $completion.rawPlayerLogCopied -and
    $binding.contractId -ceq
        'nll/phase3b2-epinel-native-cache-run-binding/v4' -and
    $binding.assessmentUid -ceq $AssessmentUid -and
    $binding.catalogSqliteTransportVerifiedBeforeClientStart
) 'phase3b2_saus_baseline_receipt_contract_invalid'

$playerLog = [IO.File]::ReadAllText(
    $playerLogPath,
    [Text.Encoding]::UTF8
)
$malformedSqliteCount = [regex]::Matches(
    $playerLog,
    'SQLiteException: database disk image is malformed'
).Count
$zeroCatalogPathCount = [regex]::Matches(
    $playerLog,
    [regex]::Escape('asset-catalog-0.cat (0)')
).Count
$remoteCatalogLoadCount = [regex]::Matches(
    $playerLog,
    'LoadAllCatalogAsync\(\) catalogUrl:'
).Count
$resourceHostsSuccessCount = [regex]::Matches(
    $playerLog,
    'ResGetResourceHosts2, Result = Success'
).Count
$assetCatalogNotInitializedCount = [regex]::Matches(
    $playerLog,
    'AssetCatalogNotInitializedException'
).Count
Assert-True (
    $malformedSqliteCount -eq 4 -and
    $zeroCatalogPathCount -eq 4 -and
    $remoteCatalogLoadCount -eq 1 -and
    $resourceHostsSuccessCount -eq 1 -and
    $assetCatalogNotInitializedCount -eq 1
) 'phase3b2_saus_baseline_player_log_shape_invalid'
$playerLog = $null

Add-Type -Path $epinelAssemblyPath
$encrypted = [IO.File]::ReadAllBytes($numberedCatalogPath)
$decrypted = $null
try {
    $decrypted = [EpinelPS.Data.NkdbDecryptor]::Decrypt($encrypted)
    $decryptedSha256 = Get-ByteArraySha256Hex $decrypted
    $decryptedHeader = [Text.Encoding]::ASCII.GetString(
        $decrypted,
        0,
        [Math]::Min(16, $decrypted.Length)
    )
    Assert-True (
        $decrypted.Length -eq 114688L -and
        $decryptedSha256 -ceq $expectedDecryptedCatalogSha256 -and
        $decryptedHeader -ceq "SQLite format 3$([char]0)"
    ) 'phase3b2_saus_baseline_in_memory_decryption_invalid'
}
finally {
    if ($null -ne $decrypted) {
        [Array]::Clear($decrypted, 0, $decrypted.Length)
    }
    [Array]::Clear($encrypted, 0, $encrypted.Length)
}

$receipt = [ordered]@{
    schemaVersion = 1
    contractId =
        'nll/phase3b2-epinel-saus-materialization-baseline/v1'
    sealedAtUtc = [DateTimeOffset]::UtcNow.ToString(
        "yyyy-MM-dd'T'HH:mm:ss'Z'"
    )
    assessmentUid = $AssessmentUid
    environmentCode = 'samsung_boot_micron_offline_runtime_cold'
    runStartReceiptByteLength = 2440L
    runStartReceiptSha256 = $expectedRunStartSha256
    completionReceiptByteLength = 1745L
    completionReceiptSha256 = $expectedCompletionSha256
    nativeCacheBindingReceiptByteLength = 1531L
    nativeCacheBindingReceiptSha256 = $expectedBindingSha256
    observedStageCode = 'catalogue_path'
    outcomeCode = 'system_error'
    failureReasonCode =
        'local_saus_asset_catalog_zero_length_not_materialized'
    remoteCatalogTransportPreflightPassed = $true
    remoteCatalogBodyCount = 3
    remoteCatalogSignatureCount = 3
    remoteCatalogAllSqlite = $true
    successfulNonLoopbackConnectionCount = 0
    playerLogByteLength = 72086L
    playerLogSha256 = $expectedPlayerLogSha256
    malformedSqliteCount = $malformedSqliteCount
    zeroLengthDerivedCatalogPathMatchCount = $zeroCatalogPathCount
    remoteCatalogLoadCount = $remoteCatalogLoadCount
    resourceHostsSuccessCount = $resourceHostsSuccessCount
    assetCatalogNotInitializedCount = $assetCatalogNotInitializedCount
    rawPlayerLogCopied = $false
    derivedCatalogRelativePath = 'saus/saus/asset-catalog-0.cat'
    derivedCatalogByteLength = 0L
    derivedCatalogSha256 = $emptySha256
    derivedSignatureByteLength = 0L
    derivedSignatureSha256 = $emptySha256
    numberedCatalogRelativePath =
        'saus/saus/asset-catalog-2651531605.cat'
    numberedCatalogByteLength = 13476L
    numberedCatalogSha256 = $expectedNumberedCatalogSha256
    numberedSignatureByteLength = 96L
    numberedSignatureSha256 = $expectedNumberedSignatureSha256
    originalInstallNumberedPairMatchesClone = $true
    numberedCatalogDecryptedByteLength = 114688L
    numberedCatalogDecryptedSha256 = $expectedDecryptedCatalogSha256
    numberedCatalogDecryptedLooksLikeSqlite = $true
    decryptionModeCode = 'epinel_nkdb_decryptor_in_memory_only'
    rawDecryptedCatalogPersisted = $false
    derivedTargetMappingVerified = $false
    derivedSignatureSemanticsVerified = $false
    databaseRestored = $true
    sqliteRuntimeRemoved = $true
    hostsRestored = $true
    extensionFirewallRemoved = $true
    runtimeColdAtSeal = $true
    sourceCacheModified = $false
    clientInstallModified = $false
    officialOutboundUsed = $false
    officialApiUsed = $false
    officialLoginUsed = $false
    officialIdentityPersisted = $false
    officialCredentialPersisted = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
    retryAuthorized = $false
    nextStepCode =
        'offline_prove_saus_target_and_signature_mapping_before_repair'
}
$receiptText = ($receipt | ConvertTo-Json -Depth 7) + "`n"

$createdFiles = [Collections.Generic.List[string]]::new()
try {
    Write-AtomicUtf8NoBom $micronReceiptPath $receiptText
    $createdFiles.Add($micronReceiptPath)
    Write-AtomicUtf8NoBom $protectedReceiptPath $receiptText
    $createdFiles.Add($protectedReceiptPath)

    $micronSha256 = Get-Sha256Hex $micronReceiptPath
    $protectedSha256 = Get-Sha256Hex $protectedReceiptPath
    Assert-True (
        (Get-Item -LiteralPath $micronReceiptPath).Length -eq
            (Get-Item -LiteralPath $protectedReceiptPath).Length -and
        $micronSha256 -ceq $protectedSha256
    ) 'phase3b2_saus_baseline_dual_seal_mismatch'

    [pscustomobject]@{
        Receipt = $receipt
        MicronReceiptPath = $micronReceiptPath
        MicronReceiptByteLength =
            (Get-Item -LiteralPath $micronReceiptPath).Length
        MicronReceiptSha256 = $micronSha256
        SamsungProtectedReceiptPath = $protectedReceiptPath
        SamsungProtectedReceiptByteLength =
            (Get-Item -LiteralPath $protectedReceiptPath).Length
        SamsungProtectedReceiptSha256 = $protectedSha256
    } | ConvertTo-Json -Depth 8
}
catch {
    foreach ($path in $createdFiles) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force
        }
    }
    foreach ($directory in @($micronReceiptRoot, $protectedReceiptRoot)) {
        if ((Test-Path -LiteralPath $directory -PathType Container) -and
            @(Get-ChildItem -LiteralPath $directory -Force).Count -eq 0) {
            Remove-Item -LiteralPath $directory -Force
        }
    }
    throw
}
