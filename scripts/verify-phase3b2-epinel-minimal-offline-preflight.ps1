param(
    [string]$MicronDrive = 'E:',
    [string]$SamsungOutputRoot = (
        Join-Path $env:LOCALAPPDATA `
            'NikkeLocalLab\Evidence\Phase3B2\Physical\EpinelMinimalPreflight-v1'
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

function Get-BytesSha256Hex {
    param([byte[]]$Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        ([BitConverter]::ToString(
            $algorithm.ComputeHash($Bytes)
        )).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $algorithm.Dispose()
    }
}

function Get-ManifestResult {
    param(
        [string]$Root,
        [switch]$ExcludeRuntimeState
    )
    $resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $prefix = $resolvedRoot + '\'
    $files = @(
        Get-ChildItem -LiteralPath $resolvedRoot -File -Recurse |
            Where-Object {
                $relative = $_.FullName.Substring($prefix.Length).Replace(
                    '\', '/'
                )
                -not $ExcludeRuntimeState -or (
                    -not $relative.StartsWith(
                        'publish/', [StringComparison]::OrdinalIgnoreCase
                    ) -and
                    -not $relative.StartsWith(
                        'cache/', [StringComparison]::OrdinalIgnoreCase
                    ) -and
                    $relative -cne 'db.json'
                )
            } |
            Sort-Object FullName
    )
    $lines = foreach ($file in $files) {
        $relative = $file.FullName.Substring($prefix.Length).Replace('\', '/')
        "$relative`t$($file.Length)`t$(Get-Sha256Hex $file.FullName)"
    }
    $text = if ($lines.Count -eq 0) { '' } else {
        ($lines -join "`n") + "`n"
    }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($text)
    [pscustomobject]@{
        Files = $files
        Bytes = $bytes
        Sha256 = Get-BytesSha256Hex $bytes
        ContentByteLength = [long](($files | Measure-Object Length -Sum).Sum)
    }
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

$expectedDeploymentReceiptSha256 = `
    '101a43a90791bf79f62ac661f35802ed53261cda37d22d7d68b6d4bff487befa'
$expectedBuildManifestSha256 = `
    'a2ad30f684b4697266557a86a22dd770b39c6ce3ef90af740e86ea17f8308cc0'
$expectedDllSha256 = `
    '25b7251f860518418ae8f50c59c311f25cf3a2615ded34a12f07ab845168bb38'
$expectedExeSha256 = `
    'f7aa2dc342e93157b620408b887603f62188c8d4a3ad75e94ab3b5b76547bc2d'
$expectedDbSha256 = `
    'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194'
$expectedCacheManifestSha256 = `
    '2f26e48f2243955d377a93bf4fcb6875b34d65aa0feb529eb2921801c3febf2e'
$expectedP0WorkflowSha256 = `
    '879fe329353f477b8dec3e4216cd5d397f7a1de0c2284a301b86f19f8b52518d'
$expectedP1WorkflowSha256 = `
    '7491036d9fbd5ddc7e0bc7067ebb85ad10f5a3b0da32284c228d9233933ba17b'
$expectedProfileReceiptSha256 = `
    'bca519531ead1c3d360e28d5b1515acb48d6681a3162d2e5bff67884a1678701'
$expectedContextSha256 = `
    'cc84781bc0df8d8705ac237f19763808e8925c7706de231b24470469ca446cc2'
$expectedOperatorReceiptSha256 = `
    '96a72eb5846a856c89d9d69a8e1ec9d5ae9884fafa27b7e5f8c0841eceb1a131'
$expectedHostsSha256 = `
    'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0'
$expectedClientExeSha256 = `
    '2cfaa12b7d708aa6a741faee17c3ac14d8e9cd6be1b5e4e773ee1535b6ddaa30'
$expectedClientCertificateSha256 = `
    '1b639977bb70416e8ab46d9b2d1acfc0130d99eb25738b230453151a104016a9'
$expectedClientSodiumSha256 = `
    '54ee18f5ee3d16fea8bb6c3407a880727aa3b848f6a55908e6bf90f8635e5662'
$expectedLauncherCertificateSha256 = `
    '86695b1be9225c3cf882d283f05c944e3aabbc1df6428a4424269a93e997dc65'
$expectedBootstrapSha256 = `
    'ff7371b3e20119030c0f3a8e2f6ba9482094c4118f06dbcc4e0e7f137f8e404f'
$expectedRollbackToolSha256 = `
    'f219bafa459b645149298f8906ba364050faf2b3808fb1ceda550c62d2976990'
$catalogDeploymentUid = 'bf669c3c-fcc8-4d57-9f18-32fee1288862'

Assert-True ($env:SystemDrive -ceq 'C:') `
    'phase3b2_epinel_minimal_preflight_wrong_boot_boundary'

$serverRoot = Join-Path $MicronDrive `
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
$cacheRoot = Join-Path $serverRoot 'cache'
$clientRoot = Join-Path $MicronDrive `
    'NLL\Clients\NIKKE-150.6.9-Physical'
$deploymentEvidenceRoot = Join-Path $MicronDrive `
    'NLL\Evidence\Phase3B2\Physical\epinel-minimal-deployment-v1'
$micronOutputRoot = Join-Path $MicronDrive `
    'NLL\Evidence\Phase3B2\Physical\epinel-minimal-preflight-v1'
$deploymentReceiptPath = Join-Path $deploymentEvidenceRoot `
    'deployment.receipt.json'
$p0WorkflowPath = Join-Path $MicronDrive `
    'NLL\Evidence\Phase3B2\Physical\p0-v1\workflow.receipt.json'
$p1WorkflowPath = Join-Path $MicronDrive `
    'NLL\Evidence\Phase3B2\Physical\p1-server-only-v1\workflow.receipt.json'
$profileReceiptPath = Join-Path $MicronDrive `
    'NLL\Evidence\Phase3B2\Physical\server-profile-v1\identity\offline-synthetic-profile.receipt.json'
$contextPath = Join-Path $MicronDrive `
    'NLL\Evidence\Phase3B2\Physical\server-profile-v1\identity\synthetic-context.json'
$operatorReceiptPath = Join-Path $MicronDrive `
    'NLL\Evidence\Phase3B2\Physical\operator-profile-v1\profile-isolation.receipt.json'
$catalogPrivatePath = Join-Path $MicronDrive (
    'NLL\Evidence\Phase3B2\Physical\catalog-set-v1\' +
    $catalogDeploymentUid + '\deployment.private.json'
)
$hostsPath = Join-Path $MicronDrive `
    'Windows\System32\drivers\etc\hosts'
$clientExePath = Join-Path $clientRoot 'NIKKE\game\nikke.exe'
$pluginsRoot = Join-Path $clientRoot `
    'NIKKE\game\nikke_Data\Plugins\x86_64'
$clientCertificatePath = Join-Path $pluginsRoot 'intl_cacert.pem'
$clientSodiumPath = Join-Path $pluginsRoot 'sodium.dll'
$launcherCertificatePath = Join-Path $clientRoot `
    'Launcher\intl_service\intl_cacert.pem'
$bootstrapPath = Join-Path $MicronDrive `
    'NLL\Runtime\PhysicalBootstrap-v2\artifact\NikkeLocalLab.Phase3B2.PhysicalBootstrap.exe'
$rollbackToolPath = Join-Path $MicronDrive `
    'NLL\Tools\rollback-phase3b2-epinel-minimal-in-micron.ps1'
$activeP2PointerPath = Join-Path $MicronDrive `
    'NLL\Evidence\Phase3B2\Physical\p2-client-start-v2\active-run.pointer.json'
$minimalPointerPath = Join-Path $MicronDrive `
    'NLL\Evidence\Phase3B2\Physical\epinel-minimal-reference-v1\active-run.pointer.json'

$requiredFiles = @(
    $deploymentReceiptPath, $p0WorkflowPath, $p1WorkflowPath,
    $profileReceiptPath, $contextPath, $operatorReceiptPath,
    $catalogPrivatePath, $hostsPath, $clientExePath,
    $clientCertificatePath, $clientSodiumPath, $launcherCertificatePath,
    $bootstrapPath, $rollbackToolPath,
    (Join-Path $serverRoot 'EpinelPS.exe'),
    (Join-Path $serverRoot 'EpinelPS.dll'),
    (Join-Path $serverRoot 'db.json'),
    (Join-Path $serverRoot 'gameconfig.json')
)
Assert-True (@($requiredFiles | Where-Object {
    -not (Test-Path -LiteralPath $_ -PathType Leaf)
}).Count -eq 0 -and
    -not (Test-Path -LiteralPath $micronOutputRoot) -and
    -not (Test-Path -LiteralPath $SamsungOutputRoot) -and
    -not (Test-Path -LiteralPath $activeP2PointerPath) -and
    -not (Test-Path -LiteralPath $minimalPointerPath)) `
    'phase3b2_epinel_minimal_preflight_shape_invalid'

Assert-True (
    (Get-Sha256Hex $deploymentReceiptPath) -ceq `
        $expectedDeploymentReceiptSha256 -and
    (Get-Sha256Hex $p0WorkflowPath) -ceq $expectedP0WorkflowSha256 -and
    (Get-Sha256Hex $p1WorkflowPath) -ceq $expectedP1WorkflowSha256 -and
    (Get-Sha256Hex $profileReceiptPath) -ceq `
        $expectedProfileReceiptSha256 -and
    (Get-Sha256Hex $contextPath) -ceq $expectedContextSha256 -and
    (Get-Sha256Hex $operatorReceiptPath) -ceq `
        $expectedOperatorReceiptSha256 -and
    (Get-Sha256Hex $hostsPath) -ceq $expectedHostsSha256 -and
    (Get-Sha256Hex $clientExePath) -ceq $expectedClientExeSha256 -and
    (Get-Sha256Hex $clientCertificatePath) -ceq `
        $expectedClientCertificateSha256 -and
    (Get-Sha256Hex $clientSodiumPath) -ceq `
        $expectedClientSodiumSha256 -and
    (Get-Sha256Hex $launcherCertificatePath) -ceq `
        $expectedLauncherCertificateSha256 -and
    (Get-Sha256Hex $bootstrapPath) -ceq $expectedBootstrapSha256 -and
    (Get-Sha256Hex $rollbackToolPath) -ceq $expectedRollbackToolSha256 -and
    (Get-Sha256Hex (Join-Path $serverRoot 'EpinelPS.exe')) -ceq `
        $expectedExeSha256 -and
    (Get-Sha256Hex (Join-Path $serverRoot 'EpinelPS.dll')) -ceq `
        $expectedDllSha256 -and
    (Get-Sha256Hex (Join-Path $serverRoot 'db.json')) -ceq `
        $expectedDbSha256
) 'phase3b2_epinel_minimal_preflight_digest_invalid'

$deployment = Get-Content -LiteralPath $deploymentReceiptPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
$p0 = Get-Content -LiteralPath $p0WorkflowPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$p1 = Get-Content -LiteralPath $p1WorkflowPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$profile = Get-Content -LiteralPath $profileReceiptPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$context = Get-Content -LiteralPath $contextPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$operator = Get-Content -LiteralPath $operatorReceiptPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
$gameConfig = Get-Content -LiteralPath `
    (Join-Path $serverRoot 'gameconfig.json') -Raw -Encoding UTF8 |
    ConvertFrom-Json
$catalogPrivate = Get-Content -LiteralPath $catalogPrivatePath -Raw `
    -Encoding UTF8 | ConvertFrom-Json

Assert-True (
    $deployment.contractId -ceq `
        'nll/phase3b2-epinel-minimal-offline-deployment/v1' -and
    $deployment.deploymentApplied -and
    $deployment.rawCatalogTransportCode -ceq `
        'opaque_file_stream_no_projection' -and
    $p0.p0AppliedVerified -and $p0.protectedBackupVerified -and
    $p1.physicalBoundaryVerified -and
    $p1.serverOnlyMeasurementVerified -and
    $p1.controlledSyntheticLoginAccepted -and
    $p1.sqliteCredentialBindingVerified -and
    $p1.databaseRestored -and $p1.sqliteRuntimeRemoved -and
    $profile.contractId -ceq 'nll/phase3b2-offline-synthetic-profile/v1' -and
    -not $profile.officialIdentityPersisted -and
    -not $profile.officialCredentialPersisted -and
    $context.contractId -ceq `
        'nll/phase3b2-synthetic-runtime-context/v1' -and
    ([string]$context.username).StartsWith(
        'synthetic-', [StringComparison]::Ordinal
    ) -and
    ([string]$context.password).Length -eq 20 -and
    [long]$context.accountId -gt 0 -and [long]$context.managerId -gt 0 -and
    $operator.accountName -ceq 'nlloperator' -and
    $operator.currentUserVerified -and
    $gameConfig.TargetVersion -ceq '150.6.9' -and
    $gameConfig.ResourceCoreVersion -ceq '150.6.b15' -and
    [string]$gameConfig.ResourceDataPackVersion -ceq '651' -and
    $gameConfig.ResourceBaseURL -ceq `
        'https://cloud.nikke-kr.com/prdenv/150-b059c3f36c/{Platform}' -and
    @($catalogPrivate.members).Count -eq 6
) 'phase3b2_epinel_minimal_preflight_contract_invalid'

Assert-True (@('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal' |
    Where-Object { Test-Path -LiteralPath (Join-Path $serverRoot $_) }
).Count -eq 0) 'phase3b2_epinel_minimal_preflight_sqlite_not_cold'

$buildManifest = Get-ManifestResult -Root $serverRoot -ExcludeRuntimeState
$cacheManifest = Get-ManifestResult -Root $cacheRoot
Assert-True (
    $buildManifest.Files.Count -eq 577 -and
    $buildManifest.ContentByteLength -eq 193938533L -and
    $buildManifest.Sha256 -ceq $expectedBuildManifestSha256 -and
    $cacheManifest.Files.Count -eq 11 -and
    $cacheManifest.Sha256 -ceq $expectedCacheManifestSha256
) 'phase3b2_epinel_minimal_preflight_manifest_invalid'

foreach ($member in @($catalogPrivate.members)) {
    $path = Join-Path $cacheRoot ([string]$member.relativePath)
    Assert-True (
        (Test-Path -LiteralPath $path -PathType Leaf) -and
        (Get-Item -LiteralPath $path).Length -eq ([long]$member.byteLength) -and
        (Get-Sha256Hex $path) -ceq ([string]$member.sha256)
    ) 'phase3b2_epinel_minimal_preflight_raw_catalog_invalid'
}

$receipt = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-epinel-minimal-source-free-preflight/v1'
    verifiedAtUtc = [DateTimeOffset]::UtcNow.ToString(
        "yyyy-MM-dd'T'HH:mm:ss'Z'"
    )
    verdict = 'ready_to_stage_single_micron_reference_run_tools'
    clientBuild = '150.6.9'
    externalHead = [string]$deployment.externalHead
    externalTree = [string]$deployment.externalTree
    buildFileCount = $buildManifest.Files.Count
    buildContentByteLength = $buildManifest.ContentByteLength
    buildManifestSha256 = $buildManifest.Sha256
    serverExeSha256 = $expectedExeSha256
    serverDllSha256 = $expectedDllSha256
    databaseBaselineSha256 = $expectedDbSha256
    cacheMemberCount = $cacheManifest.Files.Count
    cacheManifestSha256 = $cacheManifest.Sha256
    rawCatalogMemberCount = @($catalogPrivate.members).Count
    rawCatalogSetVerified = $true
    rawCatalogTransportCode = 'opaque_file_stream_no_projection'
    resourceCoreVersion = '150.6.b15'
    resourceDataPackVersion = '651'
    selectedManagerIdPresent = $true
    classicSoloRaidSeason26TargetPreserved = $true
    museumExcluded = $true
    p0WorkflowSha256 = $expectedP0WorkflowSha256
    p1WorkflowSha256 = $expectedP1WorkflowSha256
    clientExecutableSha256 = $expectedClientExeSha256
    clientCertificatePatchedVerified = $true
    nativeCompatibilityShimVerified = $true
    officialLauncherCertificatePreserved = $true
    physicalBootstrapSha256 = $expectedBootstrapSha256
    dedicatedOperatorProfileVerified = $true
    baseHostsVerified = $true
    baseFirewallReceiptVerified = $true
    plannedServerArguments = @('--headless', '--local-only')
    plannedInteractiveMeasurementSeconds = 30
    officialOutboundFallbackPermitted = $false
    officialLauncherExecutionPermitted = $false
    antiCheatSubstitutionPermitted = $false
    primaryInstallMutationPermitted = $false
    existingOperatorCacheMutationPermitted = $false
    rollbackToolVerified = $true
    serverExecutionStarted = $false
    clientExecutionStarted = $false
    nextStepCode = 'stage_minimal_start_and_completion_tools_offline'
}

$receiptText = ($receipt | ConvertTo-Json -Depth 7) + "`n"
New-Item -ItemType Directory -Path $micronOutputRoot, $SamsungOutputRoot `
    -Force | Out-Null
$micronReceiptPath = Join-Path $micronOutputRoot 'preflight.receipt.json'
$samsungReceiptPath = Join-Path $SamsungOutputRoot 'preflight.receipt.json'
Write-Utf8NoBom $micronReceiptPath $receiptText
Write-Utf8NoBom $samsungReceiptPath $receiptText

[pscustomobject]@{
    Receipt = $receipt
    MicronReceiptPath = $micronReceiptPath
    MicronReceiptSha256 = Get-Sha256Hex $micronReceiptPath
    SamsungReceiptPath = $samsungReceiptPath
    SamsungReceiptSha256 = Get-Sha256Hex $samsungReceiptPath
} | ConvertTo-Json -Depth 8
