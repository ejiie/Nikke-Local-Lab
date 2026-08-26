[CmdletBinding()]
param(
    [ValidatePattern('^[A-Z]$')]
    [string]$MicronDriveLetter = 'E',
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$DeploymentUid,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{64}$')]
    [string]$ExpectedDeploymentReceiptSha256,
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
        'phase3b2_locale_overlay_rollback_source_invalid'
    $temporary = $Destination + '.partial-' +
        [Guid]::NewGuid().ToString('N')
    try {
        Copy-Item -LiteralPath $Source -Destination $temporary
        Assert-True (Test-Digest $temporary $ByteLength $Sha256) `
            'phase3b2_locale_overlay_rollback_archive_invalid'
        Move-Item -LiteralPath $temporary -Destination $Destination
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

function Get-CacheInspection {
    param([string]$DotnetPath, [string]$VerifierPath, [string]$CacheRoot)

    $output = & $DotnetPath $VerifierPath 'inspect-cache-tree' `
        $CacheRoot 2>&1
    Assert-True ($LASTEXITCODE -eq 0) `
        'phase3b2_locale_overlay_rollback_cache_inspection_failed'
    (($output | Out-String) | ConvertFrom-Json)
}

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
$verifierRoot = Join-Path $micronDrive `
    'NLL\Tools\Phase3B2.NativeCacheVerifier-v1'
$verifierDllPath = Join-Path $verifierRoot `
    'Phase3B2.NativeCacheMaterializer.dll'
$dotnetPath = Join-Path $micronDrive 'Program Files\dotnet\dotnet.exe'
$micronHostsPath = Join-Path $micronDrive `
    'Windows\System32\drivers\etc\hosts'
$micronLaneRoot = Join-Path $micronDrive (
    'NLL\Evidence\Phase3B2\Physical\' +
    'epinel-locale-catalog-overlay-v1\' + $DeploymentUid
)
$protectedLaneRoot = Join-Path $ProtectedDeploymentRoot $DeploymentUid
$micronReceiptPath = Join-Path $micronLaneRoot `
    'deployment.receipt.json'
$protectedReceiptPath = Join-Path $protectedLaneRoot `
    'deployment.receipt.json'
$micronPlanPath = Join-Path $micronLaneRoot 'rollback.plan.json'
$protectedPlanPath = Join-Path $protectedLaneRoot 'rollback.plan.json'
$micronRollbackReceiptPath = Join-Path $micronLaneRoot `
    'rollback.receipt.json'
$protectedRollbackReceiptPath = Join-Path $protectedLaneRoot `
    'rollback.receipt.json'
$derivedArchivePath = Join-Path $micronLaneRoot `
    'derived-start.before-rollback.ps1'
$pairArchiveRoot = Join-Path $micronLaneRoot 'pair.before-rollback'
$bodyArchivePath = Join-Path $pairArchiveRoot 'asset-catalog.cat'
$signatureArchivePath = Join-Path $pairArchiveRoot `
    'asset-catalog.cat.nds'

$expectedReceiptSha256 =
    $ExpectedDeploymentReceiptSha256.ToLowerInvariant()
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
$expectedBaseHostsSha256 =
    'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
Assert-True ($principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )) 'phase3b2_locale_overlay_rollback_requires_administrator'
$systemDisk = Get-Partition -DriveLetter C | Get-Disk
$micronDisk = Get-Partition -DriveLetter $MicronDriveLetter | Get-Disk
Assert-True (
    $env:SystemDrive -ceq 'C:' -and
    $systemDisk.FriendlyName -like 'Samsung SSD 980*' -and
    $micronDisk.FriendlyName -like 'Micron_2200*' -and
    (Test-Path -LiteralPath (
            Join-Path $micronDrive 'Windows\System32'
        ) -PathType Container)
) 'phase3b2_locale_overlay_rollback_wrong_disk_boundary'

$requiredInputs = @(
    $micronReceiptPath, $protectedReceiptPath, $micronPlanPath,
    $protectedPlanPath, $databasePath, $serverDllPath, $goldenStartPath,
    $innerStartPath, $completionWrapperPath, $innerCompletionPath,
    $verifierDllPath, $dotnetPath, $micronHostsPath
)
Assert-True (@($requiredInputs | Where-Object {
            -not (Test-Path -LiteralPath $_ -PathType Leaf)
        }).Count -eq 0 -and
    -not (Test-Path -LiteralPath $micronRollbackReceiptPath) -and
    -not (Test-Path -LiteralPath $protectedRollbackReceiptPath) -and
    -not (Test-Path -LiteralPath $derivedArchivePath) -and
    -not (Test-Path -LiteralPath $pairArchiveRoot) -and
    -not (Test-Path -LiteralPath $activePointerPath) -and
    @(Get-Process -Name EpinelPS, nikke, nikke_launcher,
        NikkeLocalLab.Phase3B2.PhysicalBootstrap `
        -ErrorAction SilentlyContinue).Count -eq 0 -and
    @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal' |
        Where-Object { Test-Path -LiteralPath (Join-Path $serverRoot $_) }
    ).Count -eq 0
) 'phase3b2_locale_overlay_rollback_input_or_runtime_invalid'
Assert-True (
    (Get-Sha256Hex $micronReceiptPath) -ceq $expectedReceiptSha256 -and
    (Get-Sha256Hex $protectedReceiptPath) -ceq $expectedReceiptSha256 -and
    (Get-Sha256Hex $micronPlanPath) -ceq
        (Get-Sha256Hex $protectedPlanPath) -and
    (Get-Sha256Hex $databasePath) -ceq
        $expectedGoldenDatabaseSha256 -and
    (Get-Sha256Hex $goldenStartPath) -ceq $expectedGoldenStartSha256 -and
    (Get-Sha256Hex $innerStartPath) -ceq $expectedInnerStartSha256 -and
    (Get-Sha256Hex $completionWrapperPath) -ceq
        $expectedCompletionWrapperSha256 -and
    (Get-Sha256Hex $innerCompletionPath) -ceq
        $expectedInnerCompletionSha256 -and
    (Get-Sha256Hex $serverDllPath) -ceq $expectedServerDllSha256 -and
    (Get-Sha256Hex $micronHostsPath) -ceq $expectedBaseHostsSha256
) 'phase3b2_locale_overlay_rollback_digest_invalid'

$deployment = Get-Content -LiteralPath $micronReceiptPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
$plan = Get-Content -LiteralPath $micronPlanPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True (
    $deployment.contractId -ceq
        'nll/phase3b2-epinel-locale-catalog-overlay/v1' -and
    $deployment.deploymentUid -ceq $DeploymentUid -and
    $deployment.localeCode -cmatch '^[a-z]{2}$' -and
    $deployment.revisionCode -cmatch '^[0-9a-f]{7}$' -and
    $deployment.pairAppliedBySameVolumeDirectoryRename -and
    $deployment.exactExpressionReplacementCount -eq 2 -and
    $deployment.reverseProjectionVerified -and
    -not $deployment.goldenStartModified -and
    -not $deployment.innerStartModified -and
    -not $deployment.completionToolsModified -and
    -not $deployment.runtimeToolBindingPerformed -and
    $plan.contractId -ceq
        'nll/phase3b2-epinel-locale-overlay-rollback-plan/v1' -and
    $plan.deploymentUid -ceq $DeploymentUid -and
    $plan.acquisitionAssessmentUid -ceq
        $deployment.acquisitionAssessmentUid -and
    $plan.acquisitionReceiptSha256 -ceq
        $deployment.acquisitionReceiptSha256 -and
    $plan.localeCode -ceq $deployment.localeCode -and
    $plan.revisionCode -ceq $deployment.revisionCode -and
    $plan.bodyByteLength -eq $deployment.bodyByteLength -and
    $plan.bodySha256 -ceq $deployment.bodySha256 -and
    $plan.signatureByteLength -eq $deployment.signatureByteLength -and
    $plan.signatureSha256 -ceq $deployment.signatureSha256 -and
    $plan.derivedStartLeaf -ceq $deployment.derivedStartLeaf -and
    $plan.expectedGoldenStartSha256 -ceq $expectedGoldenStartSha256 -and
    $plan.removeOnlyIfExact -and
    $deployment.rollbackPlanSha256 -ceq
        (Get-Sha256Hex $micronPlanPath)
) 'phase3b2_locale_overlay_rollback_contract_invalid'

$bodyRelativeWindows = ([string]$plan.bodyRelativePath).Replace('/', '\')
$signatureRelativeWindows =
    ([string]$plan.signatureRelativePath).Replace('/', '\')
$bodyPath = Join-Path $cacheRoot $bodyRelativeWindows
$signaturePath = Join-Path $cacheRoot $signatureRelativeWindows
$targetRoot = Split-Path -Parent $bodyPath
$derivedStartPath = Join-Path $micronDrive `
    ('NLL\Tools\' + [string]$plan.derivedStartLeaf)
Assert-StrictChildPath $cacheRoot $bodyPath `
    'phase3b2_locale_overlay_rollback_target_escaped'
Assert-StrictChildPath $cacheRoot $signaturePath `
    'phase3b2_locale_overlay_rollback_target_escaped'
Assert-True (
    [string]$plan.derivedStartLeaf -cmatch
        '^Start-Phase3B2-Epinel-LocaleOverlay-[a-z]{2}\.ps1$' -and
    (Test-Digest $bodyPath ([long]$plan.bodyByteLength) `
        ([string]$plan.bodySha256)) -and
    (Test-Digest $signaturePath ([long]$plan.signatureByteLength) `
        ([string]$plan.signatureSha256)) -and
    (Test-Digest $derivedStartPath `
        ([long]$deployment.derivedStartByteLength) `
        ([string]$deployment.derivedStartSha256)) -and
    @(Get-ChildItem -LiteralPath $targetRoot -File -Force).Count -eq 2 -and
    @(Get-ChildItem -LiteralPath $targetRoot -Directory -Force).Count -eq 0
) 'phase3b2_locale_overlay_rollback_active_overlay_invalid'

$before = Get-CacheInspection $dotnetPath $verifierDllPath $cacheRoot
Assert-True (
    $before.fileCount -eq $deployment.activeCacheFileCountAfter -and
    [long]$before.contentByteLength -eq
        [long]$deployment.activeCacheContentByteLengthAfter -and
    $before.partialMemberCount -eq 0
) 'phase3b2_locale_overlay_rollback_before_cache_shape_invalid'

Copy-AtomicVerified $derivedStartPath $derivedArchivePath `
    ([long]$deployment.derivedStartByteLength) `
    ([string]$deployment.derivedStartSha256)
New-Item -ItemType Directory -Path $pairArchiveRoot | Out-Null
$pairMoved = $false
try {
    Move-Item -LiteralPath $bodyPath -Destination $bodyArchivePath
    Move-Item -LiteralPath $signaturePath -Destination $signatureArchivePath
    $pairMoved = $true
    Assert-True (
        (Test-Digest $bodyArchivePath ([long]$plan.bodyByteLength) `
            ([string]$plan.bodySha256)) -and
        (Test-Digest $signatureArchivePath `
            ([long]$plan.signatureByteLength) `
            ([string]$plan.signatureSha256)) -and
        @(Get-ChildItem -LiteralPath $targetRoot -Force).Count -eq 0
    ) 'phase3b2_locale_overlay_rollback_pair_archive_invalid'
    if (-not [bool]$plan.targetDirectoryPreexistedEmpty) {
        Remove-Item -LiteralPath $targetRoot -Force
    }

    $after = Get-CacheInspection $dotnetPath $verifierDllPath $cacheRoot
    Assert-True (
        $after.fileCount -eq $plan.expectedCacheFileCountAfterRollback -and
        [long]$after.contentByteLength -eq
            [long]$plan.expectedCacheContentByteLengthAfterRollback -and
        $after.partialMemberCount -eq 0
    ) 'phase3b2_locale_overlay_rollback_after_cache_shape_invalid'
}
catch {
    $originalError = $_
    if ($pairMoved) {
        if (-not (Test-Path -LiteralPath $targetRoot -PathType Container)) {
            New-Item -ItemType Directory -Path $targetRoot | Out-Null
        }
        if (Test-Path -LiteralPath $bodyArchivePath -PathType Leaf) {
            Move-Item -LiteralPath $bodyArchivePath -Destination $bodyPath
        }
        if (Test-Path -LiteralPath $signatureArchivePath -PathType Leaf) {
            Move-Item -LiteralPath $signatureArchivePath `
                -Destination $signaturePath
        }
    }
    if ((Test-Path -LiteralPath $pairArchiveRoot -PathType Container) -and
        @(Get-ChildItem -LiteralPath $pairArchiveRoot -Force).Count -eq 0) {
        Remove-Item -LiteralPath $pairArchiveRoot -Force
    }
    throw $originalError
}
Remove-Item -LiteralPath $derivedStartPath -Force

Assert-True (
    -not (Test-Path -LiteralPath $bodyPath) -and
    -not (Test-Path -LiteralPath $signaturePath) -and
    -not (Test-Path -LiteralPath $derivedStartPath) -and
    (Test-Digest $bodyArchivePath ([long]$plan.bodyByteLength) `
        ([string]$plan.bodySha256)) -and
    (Test-Digest $signatureArchivePath `
        ([long]$plan.signatureByteLength) `
        ([string]$plan.signatureSha256)) -and
    (Test-Digest $derivedArchivePath `
        ([long]$deployment.derivedStartByteLength) `
        ([string]$deployment.derivedStartSha256)) -and
    (Get-Sha256Hex $goldenStartPath) -ceq $expectedGoldenStartSha256 -and
    (Get-Sha256Hex $innerStartPath) -ceq $expectedInnerStartSha256 -and
    (Get-Sha256Hex $completionWrapperPath) -ceq
        $expectedCompletionWrapperSha256 -and
    (Get-Sha256Hex $innerCompletionPath) -ceq
        $expectedInnerCompletionSha256 -and
    (Get-Sha256Hex $databasePath) -ceq
        $expectedGoldenDatabaseSha256 -and
    (Get-Sha256Hex $serverDllPath) -ceq $expectedServerDllSha256 -and
    (Get-Sha256Hex $micronHostsPath) -ceq $expectedBaseHostsSha256
) 'phase3b2_locale_overlay_rollback_postcondition_invalid'

$receipt = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-epinel-locale-catalog-overlay-rollback/v1'
    rolledBackAtUtc = [DateTimeOffset]::UtcNow.ToString(
        "yyyy-MM-dd'T'HH:mm:ss'Z'"
    )
    deploymentUid = $DeploymentUid
    deploymentReceiptSha256 = $expectedReceiptSha256
    rollbackPlanSha256 = Get-Sha256Hex $micronPlanPath
    localeCode = [string]$deployment.localeCode
    revisionCode = [string]$deployment.revisionCode
    exactBodyRemoved = $true
    exactSignatureRemoved = $true
    exactPairArchived = $true
    derivedStartRemoved = $true
    derivedStartArchived = $true
    targetDirectoryPreexistingShapeRestored = $true
    activeCacheFileCountBefore = [int]$before.fileCount
    activeCacheContentByteLengthBefore = [long]$before.contentByteLength
    activeCacheFileCountAfter = [int]$after.fileCount
    activeCacheContentByteLengthAfter = [long]$after.contentByteLength
    goldenStartModified = $false
    innerStartModified = $false
    completionToolsModified = $false
    databaseModified = $false
    serverBinaryModified = $false
    hostsModified = $false
    existingOperatorCacheInspected = $false
    existingOperatorCacheModified = $false
    localLowInspected = $false
    localLowModified = $false
    officialOutboundUsed = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
    runtimeColdAfterRollback = $true
    nextStepCode = 'golden_lobby_baseline_restored_for_locale_switch'
}
$receiptText = ($receipt | ConvertTo-Json -Depth 6) + "`n"
Write-AtomicUtf8NoBom $micronRollbackReceiptPath $receiptText
Write-AtomicUtf8NoBom $protectedRollbackReceiptPath $receiptText
$rollbackReceiptSha256 = Get-Sha256Hex $micronRollbackReceiptPath
Assert-True ($rollbackReceiptSha256 -ceq
    (Get-Sha256Hex $protectedRollbackReceiptPath)) `
    'phase3b2_locale_overlay_rollback_receipt_dual_seal_invalid'

[pscustomobject]@{
    Receipt = $receipt
    MicronReceiptPath = $micronRollbackReceiptPath
    MicronReceiptByteLength =
        [long](Get-Item -LiteralPath $micronRollbackReceiptPath).Length
    MicronReceiptSha256 = $rollbackReceiptSha256
    ProtectedReceiptPath = $protectedRollbackReceiptPath
    GoldenStartCommand =
        "& 'C:\NLL\Tools\Start-Phase3B2-Epinel-NativeCache.ps1'"
} | ConvertTo-Json -Depth 8
