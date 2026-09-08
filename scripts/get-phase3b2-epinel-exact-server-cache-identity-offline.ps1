#requires -Version 5.1

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Z]$')]
    [string]$MicronDriveLetter = 'E',
    [Parameter(Mandatory = $true)]
    [string]$TemporaryRoot,
    [string]$ProtectedPhysicalRoot =
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.
        ToLowerInvariant()
}

function Get-TextSha256Hex {
    param([string]$Text)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
        return ($algorithm.ComputeHash($bytes) | ForEach-Object {
                $_.ToString('x2')
            }) -join ''
    }
    finally {
        $algorithm.Dispose()
    }
}

function Assert-NoReparseAncestors {
    param([string]$Path, [string]$FailureCode)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $volumeRoot = [IO.Path]::GetPathRoot($fullPath)
    $cursor = $fullPath.TrimEnd([IO.Path]::DirectorySeparatorChar)
    while ($true) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            Assert-True (
                ($item.Attributes -band
                    [IO.FileAttributes]::ReparsePoint) -eq 0
            ) $FailureCode
        }
        if ($cursor.TrimEnd([IO.Path]::DirectorySeparatorChar) -ieq
            $volumeRoot.TrimEnd([IO.Path]::DirectorySeparatorChar)) {
            break
        }
        $parent = [IO.Directory]::GetParent($cursor)
        Assert-True ($null -ne $parent) $FailureCode
        $cursor = $parent.FullName
    }
}

function Get-RelativeForwardPath {
    param([string]$Root, [string]$FullName)
    $prefix = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $full = [IO.Path]::GetFullPath($FullName)
    Assert-True (
        $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
    ) 'phase3b2_exact_cache_identity_relative_path_escape'
    $relative = $full.Substring($prefix.Length).Replace('\', '/')
    Assert-True (
        -not [string]::IsNullOrWhiteSpace($relative) -and
        -not [IO.Path]::IsPathRooted($relative) -and
        @($relative.Split('/') | Where-Object {
                $_ -eq '' -or $_ -eq '.' -or $_ -eq '..'
            }).Count -eq 0
    ) 'phase3b2_exact_cache_identity_relative_path_invalid'
    return $relative
}

function Get-SmallTreeCanonicalIdentity {
    param([string]$Root)
    Assert-NoReparseAncestors $Root `
        'phase3b2_exact_cache_identity_baseline_reparse_invalid'
    $directories = @(Get-ChildItem -LiteralPath $Root -Directory -Recurse `
        -Force)
    $files = @(Get-ChildItem -LiteralPath $Root -File -Recurse -Force)
    Assert-True (@($directories + $files | Where-Object {
                ($_.Attributes -band
                    [IO.FileAttributes]::ReparsePoint) -ne 0
            }).Count -eq 0) `
        'phase3b2_exact_cache_identity_baseline_member_reparse_invalid'
    $lines = @(
        foreach ($file in $files) {
            $relative = Get-RelativeForwardPath $Root $file.FullName
            "$relative`t$($file.Length)`t$(Get-Sha256Hex $file.FullName)"
        }
    )
    $canonical = (@($lines | Sort-Object -CaseSensitive) -join "`n") +
        "`n"
    return [pscustomobject]@{
        fileCount = $files.Count
        contentByteLength = [long](
            ($files | Measure-Object Length -Sum).Sum
        )
        canonicalSha256 = Get-TextSha256Hex $canonical
    }
}

$micronDrive = $MicronDriveLetter + ':'
$ProtectedPhysicalRoot = [IO.Path]::GetFullPath($ProtectedPhysicalRoot)
$TemporaryRoot = [IO.Path]::GetFullPath($TemporaryRoot)
Assert-True (
    $TemporaryRoot.StartsWith(
        $ProtectedPhysicalRoot.TrimEnd('\') + '\',
        [StringComparison]::OrdinalIgnoreCase
    ) -and
    (Test-Path -LiteralPath $TemporaryRoot -PathType Container)
) 'phase3b2_exact_cache_identity_temporary_boundary_invalid'
Assert-NoReparseAncestors $ProtectedPhysicalRoot `
    'phase3b2_exact_cache_identity_protected_reparse_invalid'
Assert-NoReparseAncestors $TemporaryRoot `
    'phase3b2_exact_cache_identity_temporary_reparse_invalid'

$runtimeRoot = Join-Path $micronDrive `
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
$activeCacheRoot = Join-Path $runtimeRoot 'cache'
$baselineRoot = Join-Path $micronDrive `
    'NLL\Backups\Phase3B2\EpinelNativeCacheMaterialization-v1\cache-before'
$materializationRoot = Join-Path $ProtectedPhysicalRoot `
    'NativeCacheMaterialization-v2'
$materializationReceiptPath = Join-Path $materializationRoot `
    'materialization.receipt.json'
$privateManifestPath = Join-Path $materializationRoot `
    'materialization.manifest.private.json'
$verifierRoot = Join-Path $micronDrive `
    'NLL\Tools\Phase3B2.NativeCacheVerifier-v1'
$verifierManifestPath = Join-Path $verifierRoot 'bundle.manifest.json'
$verifierDllPath = Join-Path $verifierRoot `
    'Phase3B2.NativeCacheMaterializer.dll'
$dotnetPath = Join-Path $micronDrive 'Program Files\dotnet\dotnet.exe'

foreach ($root in @($activeCacheRoot, $baselineRoot, $verifierRoot,
        $materializationRoot)) {
    Assert-NoReparseAncestors $root `
        'phase3b2_exact_cache_identity_input_reparse_invalid'
}
$requiredInputs = @($materializationReceiptPath, $privateManifestPath,
    $verifierManifestPath, $verifierDllPath, $dotnetPath)
Assert-True (@($requiredInputs | Where-Object {
            -not (Test-Path -LiteralPath $_ -PathType Leaf)
        }).Count -eq 0) 'phase3b2_exact_cache_identity_input_missing'

$expectedMaterializationReceiptSha256 =
    '89a76b1e5237ea3864d87303418e638d9ad7de0570ad456182568a17c5ead921'
$expectedPrivateManifestSha256 =
    'c1223ee05fec7cf3780171ead9a3e5da7f2942f129e0014995f10fabee0782a1'
$expectedVerifierManifestSha256 =
    '3305d52786315bc927c46cdb988ce35b067d704f0a562be7aa469a188da3541c'
Assert-True (
    (Get-Sha256Hex $materializationReceiptPath) -ceq
        $expectedMaterializationReceiptSha256 -and
    (Get-Sha256Hex $privateManifestPath) -ceq
        $expectedPrivateManifestSha256 -and
    (Get-Sha256Hex $verifierManifestPath) -ceq
        $expectedVerifierManifestSha256
) 'phase3b2_exact_cache_identity_source_digest_invalid'

$materializationReceipt = Get-Content -LiteralPath `
    $materializationReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
$privateManifest = Get-Content -LiteralPath $privateManifestPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
Assert-True (
    $materializationReceipt.contractId -ceq
        'nll/phase3b2-native-cache-materialization/v1' -and
    $materializationReceipt.assessmentUid -ceq
        '24ddf43f-ad59-464a-ae1b-c527441c203b' -and
    $materializationReceipt.materializedMemberCount -eq 40103 -and
    [long]$materializationReceipt.totalContentByteLength -eq
        39007142815L -and
    $materializationReceipt.privateManifestSha256 -ceq
        $expectedPrivateManifestSha256 -and
    $materializationReceipt.canonicalSha256 -ceq
        '95000d45cb52f4bdd81b6ca9caf7e2e13eeae7bbddfa67e33ed8ef8896f22ffe' -and
    $privateManifest.contractId -ceq
        'nll/phase3b2-native-cache-materialization-private-manifest/v1' -and
    $privateManifest.assessmentUid -ceq
        [string]$materializationReceipt.assessmentUid -and
    $privateManifest.memberCount -eq 40103 -and
    @($privateManifest.members).Count -eq 40103 -and
    [long]$privateManifest.totalContentByteLength -eq 39007142815L
) 'phase3b2_exact_cache_identity_source_contract_invalid'

$verifierManifest = Get-Content -LiteralPath $verifierManifestPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
Assert-True (
    $verifierManifest.contractId -ceq
        'nll/phase3b2-native-cache-long-path-verifier-manifest/v1' -and
    $verifierManifest.sdkVersion -ceq '10.0.400' -and
    $verifierManifest.compileInputCount -eq 11 -and
    $verifierManifest.compileInputCanonicalSha256 -ceq
        'eaf339d04519010b8379ad2c30ef4321d5e6e2623a5d90116f350f0eac32bba3' -and
    $verifierManifest.memberCount -eq 8 -and
    @($verifierManifest.members).Count -eq 8
) 'phase3b2_exact_cache_identity_verifier_contract_invalid'
$verifierRelativePaths = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
foreach ($member in @($verifierManifest.members)) {
    $relative = [string]$member.relativePath
    Assert-True (
        -not [string]::IsNullOrWhiteSpace($relative) -and
        -not [IO.Path]::IsPathRooted($relative) -and
        @($relative.Replace('\', '/').Split('/') | Where-Object {
                $_ -eq '' -or $_ -eq '.' -or $_ -eq '..'
            }).Count -eq 0 -and
        $verifierRelativePaths.Add($relative)
    ) 'phase3b2_exact_cache_identity_verifier_member_path_invalid'
    $path = Join-Path $verifierRoot $relative
    Assert-True (
        (Test-Path -LiteralPath $path -PathType Leaf) -and
        (Get-Item -LiteralPath $path).Length -eq
            [long]$member.byteLength -and
        (Get-Sha256Hex $path) -ceq [string]$member.sha256
    ) 'phase3b2_exact_cache_identity_verifier_member_invalid'
}

$sourceReceiptPairs = @(
    [ordered]@{
        micron = Join-Path $micronDrive `
            'NLL\Evidence\Phase3B2\Physical\epinel-native-cache-deployment-v1\deployment.receipt.json'
        protected = Join-Path $materializationRoot `
            'MicronOfflineDeployment-v1\deployment.receipt.json'
        sha256 =
            '14bf845aec4cded1d80e8efb57a3eb4f4639ef68bd1fdf7a8d9de462689aae7d'
    },
    [ordered]@{
        micron = Join-Path $micronDrive `
            'NLL\Evidence\Phase3B2\Physical\epinel-native-cache-header-closure-v1\repair.receipt.json'
        protected = Join-Path $ProtectedPhysicalRoot `
            'EpinelNativeCacheHeaderClosure-v1\cbce0850-d821-4f0a-99cc-fb3603c4722d\repair.receipt.json'
        sha256 =
            'bc5e9e0f8f45f17c4db0408cee3d8a88389e11d1578670e9733a2563535444ce'
    },
    [ordered]@{
        micron = Join-Path $micronDrive `
            'NLL\Evidence\Phase3B2\Physical\epinel-saus-pair-staging-v1\staging.receipt.json'
        protected = Join-Path $ProtectedPhysicalRoot `
            'EpinelSausPairStaging-v1\91e926f1-1073-4bb1-a0ae-6ad70dbab935\staging.receipt.json'
        sha256 =
            '2350aae3ba7320da21bb80a1eb26c118275b39b0678b3d844990742240f019e2'
    }
)
foreach ($pair in $sourceReceiptPairs) {
    Assert-NoReparseAncestors (Split-Path -Parent $pair.micron) `
        'phase3b2_exact_cache_identity_source_receipt_reparse_invalid'
    Assert-NoReparseAncestors (Split-Path -Parent $pair.protected) `
        'phase3b2_exact_cache_identity_source_receipt_reparse_invalid'
    Assert-True (
        (Test-Path -LiteralPath $pair.micron -PathType Leaf) -and
        (Test-Path -LiteralPath $pair.protected -PathType Leaf) -and
        (Get-Sha256Hex $pair.micron) -ceq [string]$pair.sha256 -and
        (Get-Sha256Hex $pair.protected) -ceq [string]$pair.sha256
    ) 'phase3b2_exact_cache_identity_source_receipt_invalid'
}

$baselineIdentity = Get-SmallTreeCanonicalIdentity $baselineRoot
Assert-True (
    $baselineIdentity.fileCount -eq 11 -and
    [long]$baselineIdentity.contentByteLength -eq 43007317L -and
    $baselineIdentity.canonicalSha256 -ceq
        '2f26e48f2243955d377a93bf4fcb6875b34d65aa0feb529eb2921801c3febf2e'
) 'phase3b2_exact_cache_identity_baseline_invalid'

$extras = @(
    [ordered]@{
        roleCode = 'version_header'
        kindCode = 'local_projection'
        cacheRelativePath =
            'prdenv/150-b059c3f36c/StandaloneWindows64/pck/latest-651.txt'
        declaredByteLength = 139L
        contentSha256 =
            '5914cb58fd2146fe761ab531ecb4e321300527186a54b455e59de962ff6c044a'
        sourceCode = 'sealed_local_projection'
    },
    [ordered]@{
        roleCode = 'saus_body'
        kindCode = 'catalog_body'
        cacheRelativePath =
            'prdenv/150-b059c3f36c/StandaloneWindows64/pck/saus/19e939d/asset-catalog.cat'
        declaredByteLength = 13476L
        contentSha256 =
            'a8ad0f199f5db1213658c3238369ad472a98db74bb3a15a274931119ca22d0df'
        sourceCode = 'sealed_saus_pair'
    },
    [ordered]@{
        roleCode = 'saus_signature'
        kindCode = 'detached_signature'
        cacheRelativePath =
            'prdenv/150-b059c3f36c/StandaloneWindows64/pck/saus/19e939d/asset-catalog.cat.nds'
        declaredByteLength = 96L
        contentSha256 =
            '01de2cc79b8f04297faf262666a7701242a942ba74d48b513c0998ab08b91fa2'
        sourceCode = 'sealed_saus_pair'
    }
)
$paths = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
foreach ($member in @($privateManifest.members)) {
    Assert-True ($paths.Add([string]$member.cacheRelativePath)) `
        'phase3b2_exact_cache_identity_manifest_duplicate'
}
foreach ($extra in $extras) {
    Assert-True ($paths.Add([string]$extra.cacheRelativePath)) `
        'phase3b2_exact_cache_identity_extra_collision'
    $path = Join-Path $activeCacheRoot (
        [string]$extra.cacheRelativePath
    ).Replace('/', '\')
    Assert-True (
        (Test-Path -LiteralPath $path -PathType Leaf) -and
        (Get-Item -LiteralPath $path).Length -eq
            [long]$extra.declaredByteLength -and
        (Get-Sha256Hex $path) -ceq [string]$extra.contentSha256
    ) 'phase3b2_exact_cache_identity_extra_member_invalid'
}

$derivedManifest = [ordered]@{
    schemaVersion = 1
    contractId =
        'nll/phase3b2-native-cache-materialization-private-manifest/v1'
    sealedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    assessmentUid = [string]$privateManifest.assessmentUid
    privatePlanSha256 = [string]$privateManifest.privatePlanSha256
    memberCount = 40106
    totalContentByteLength = 39007156526L
    members = @($privateManifest.members) + $extras
}
$temporaryManifestPath = Join-Path $TemporaryRoot (
    '.server-cache-identity-' + [Guid]::NewGuid().ToString('N') +
    '.private.json'
)
try {
    [IO.File]::WriteAllText(
        $temporaryManifestPath,
        (($derivedManifest | ConvertTo-Json -Depth 6) +
            [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
    $verificationText = (& $dotnetPath $verifierDllPath `
        'verify-combined-cache' $activeCacheRoot $temporaryManifestPath `
        $baselineRoot 2>&1 | Out-String).Trim()
    Assert-True ($LASTEXITCODE -eq 0) `
        'phase3b2_exact_cache_identity_verifier_failed'
    $verification = $verificationText | ConvertFrom-Json
}
finally {
    if (Test-Path -LiteralPath $temporaryManifestPath -PathType Leaf) {
        Remove-Item -LiteralPath $temporaryManifestPath -Force
    }
}

$expectedCanonicalSha256 =
    '159b152960c35e8898bc1ea06dd17239b200f46e65095fa79b1aeead19dd8c56'
Assert-True (
    $verification.contractId -ceq
        'nll/phase3b2-native-cache-combined-cache-verification/v1' -and
    $verification.verified -and
    $verification.longPathSafeEnumerationUsed -and
    $verification.memberDigestVerificationPerformed -and
    $verification.materializedMemberCount -eq 40106 -and
    $verification.baselineMemberCount -eq 11 -and
    $verification.overlappingBaselineMemberCount -eq 6 -and
    $verification.baselineOnlyMemberCount -eq 5 -and
    $verification.expectedMemberCount -eq 40111 -and
    $verification.observedMemberCount -eq 40111 -and
    [long]$verification.expectedContentByteLength -eq 39030643658L -and
    [long]$verification.observedContentByteLength -eq 39030643658L -and
    $verification.unexpectedMemberCount -eq 0 -and
    $verification.missingMemberCount -eq 0 -and
    $verification.activeCanonicalSha256 -ceq $expectedCanonicalSha256
) 'phase3b2_exact_cache_identity_verification_invalid'

[ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-epinel-server-cache-exact-identity/v1'
    verifiedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    materializationReceiptSha256 =
        $expectedMaterializationReceiptSha256
    materializationPrivateManifestSha256 =
        $expectedPrivateManifestSha256
    deploymentReceiptSha256 = [string]$sourceReceiptPairs[0].sha256
    headerRepairReceiptSha256 = [string]$sourceReceiptPairs[1].sha256
    sausStagingReceiptSha256 = [string]$sourceReceiptPairs[2].sha256
    baselineFileCount = [int]$baselineIdentity.fileCount
    baselineContentByteLength =
        [long]$baselineIdentity.contentByteLength
    baselineCanonicalSha256 = [string]$baselineIdentity.canonicalSha256
    derivedManifestMemberCount = 40106
    derivedManifestContentByteLength = 39007156526L
    appendedMemberCount = 3
    verifierBundleManifestSha256 = $expectedVerifierManifestSha256
    verifierDllSha256 = Get-Sha256Hex $verifierDllPath
    expectedMemberCount = 40111
    observedMemberCount = [int]$verification.observedMemberCount
    observedContentByteLength =
        [long]$verification.observedContentByteLength
    activeCacheCanonicalSha256 =
        [string]$verification.activeCanonicalSha256
    memberDigestVerificationPerformed = $true
    longPathSafeEnumerationUsed = $true
    exactServerCacheIdentityVerified = $true
    temporaryDerivedManifestPersisted = $false
    rawMemberListEmitted = $false
    serverCacheModified = $false
    networkUsed = $false
} | ConvertTo-Json -Depth 6
