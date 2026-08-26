[CmdletBinding()]
param(
    [ValidatePattern('^[A-Z]$')]
    [string]$MicronDriveLetter = 'E',
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$DeploymentUid = 'd1087737-eae7-4e88-9fb5-9ced3e35aede',
    [ValidatePattern('^[0-9a-fA-F]{64}$')]
    [string]$ExpectedDeploymentReceiptSha256 =
        'ad416ccbec40aba0246b2983fb8afb5b9475020ba06b34a8bfd0a01c521c8d5e',
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$CorrectionUid = ([Guid]::NewGuid().ToString('D')),
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
        'phase3b2_locale_overlay_start_repair_source_invalid'
    $temporary = $Destination + '.partial-' +
        [Guid]::NewGuid().ToString('N')
    try {
        Copy-Item -LiteralPath $Source -Destination $temporary
        Assert-True (Test-Digest $temporary $ByteLength $Sha256) `
            'phase3b2_locale_overlay_start_repair_copy_invalid'
        Move-Item -LiteralPath $temporary -Destination $Destination
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Get-CacheInspection {
    param([string]$DotnetPath, [string]$VerifierPath, [string]$CacheRoot)

    $output = & $DotnetPath $VerifierPath 'inspect-cache-tree' `
        $CacheRoot 2>&1
    Assert-True ($LASTEXITCODE -eq 0) `
        'phase3b2_locale_overlay_start_repair_cache_inspection_failed'
    (($output | Out-String) | ConvertFrom-Json)
}

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
$verifierDllPath = Join-Path $micronDrive (
    'NLL\Tools\Phase3B2.NativeCacheVerifier-v1\' +
    'Phase3B2.NativeCacheMaterializer.dll'
)
$dotnetPath = Join-Path $micronDrive 'Program Files\dotnet\dotnet.exe'
$micronHostsPath = Join-Path $micronDrive `
    'Windows\System32\drivers\etc\hosts'
$sausBindingPath = Join-Path $micronDrive (
    'NLL\Evidence\Phase3B2\Physical\' +
    'epinel-saus-pair-staging-v1\tool-binding.receipt.json'
)
$micronLaneRoot = Join-Path $micronDrive (
    'NLL\Evidence\Phase3B2\Physical\' +
    'epinel-locale-catalog-overlay-v1\' + $DeploymentUid
)
$protectedLaneRoot = Join-Path $ProtectedDeploymentRoot $DeploymentUid
$micronDeploymentReceiptPath = Join-Path $micronLaneRoot `
    'deployment.receipt.json'
$protectedDeploymentReceiptPath = Join-Path $protectedLaneRoot `
    'deployment.receipt.json'
$rollbackPlanPath = Join-Path $micronLaneRoot 'rollback.plan.json'
$micronCorrectionPlanPath = Join-Path $micronLaneRoot `
    'start-correction.rollback-plan.json'
$protectedCorrectionPlanPath = Join-Path $protectedLaneRoot `
    'start-correction.rollback-plan.json'
$micronCorrectionReceiptPath = Join-Path $micronLaneRoot `
    'start-correction.receipt.json'
$protectedCorrectionReceiptPath = Join-Path $protectedLaneRoot `
    'start-correction.receipt.json'
$rejectedStartArchivePath = Join-Path $micronLaneRoot `
    'derived-start.v1-rejected.ps1'

$expectedDeploymentReceiptSha256 =
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
    )) 'phase3b2_locale_overlay_start_repair_requires_administrator'
$systemDisk = Get-Partition -DriveLetter C | Get-Disk
$micronDisk = Get-Partition -DriveLetter $MicronDriveLetter | Get-Disk
Assert-True (
    $env:SystemDrive -ceq 'C:' -and
    $systemDisk.FriendlyName -like 'Samsung SSD 980*' -and
    $micronDisk.FriendlyName -like 'Micron_2200*' -and
    (Test-Path -LiteralPath (
            Join-Path $micronDrive 'Windows\System32'
        ) -PathType Container)
) 'phase3b2_locale_overlay_start_repair_wrong_disk_boundary'

$requiredInputs = @(
    $derivationToolPath, $micronDeploymentReceiptPath,
    $protectedDeploymentReceiptPath, $rollbackPlanPath, $goldenStartPath,
    $innerStartPath, $completionWrapperPath, $innerCompletionPath,
    $databasePath, $serverDllPath, $verifierDllPath, $dotnetPath,
    $micronHostsPath, $sausBindingPath
)
Assert-True (@($requiredInputs | Where-Object {
            -not (Test-Path -LiteralPath $_ -PathType Leaf)
        }).Count -eq 0 -and
    -not (Test-Path -LiteralPath $activePointerPath) -and
    -not (Test-Path -LiteralPath $micronCorrectionPlanPath) -and
    -not (Test-Path -LiteralPath $protectedCorrectionPlanPath) -and
    -not (Test-Path -LiteralPath $micronCorrectionReceiptPath) -and
    -not (Test-Path -LiteralPath $protectedCorrectionReceiptPath) -and
    -not (Test-Path -LiteralPath $rejectedStartArchivePath) -and
    @(Get-Process -Name EpinelPS, nikke, nikke_launcher,
        NikkeLocalLab.Phase3B2.PhysicalBootstrap `
        -ErrorAction SilentlyContinue).Count -eq 0 -and
    @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal' |
        Where-Object { Test-Path -LiteralPath (Join-Path $serverRoot $_) }
    ).Count -eq 0
) 'phase3b2_locale_overlay_start_repair_input_or_runtime_invalid'

Assert-True (
    (Get-Sha256Hex $micronDeploymentReceiptPath) -ceq
        $expectedDeploymentReceiptSha256 -and
    (Get-Sha256Hex $protectedDeploymentReceiptPath) -ceq
        $expectedDeploymentReceiptSha256 -and
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
) 'phase3b2_locale_overlay_start_repair_digest_invalid'

$deployment = Get-Content -LiteralPath $micronDeploymentReceiptPath `
    -Raw -Encoding UTF8 | ConvertFrom-Json
$rollbackPlan = Get-Content -LiteralPath $rollbackPlanPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
$sausBinding = Get-Content -LiteralPath $sausBindingPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
$expectedBodyRelativePath = (
    'prdenv/150-b059c3f36c/StandaloneWindows64/pck/' +
    [string]$deployment.localeCode + '/' +
    [string]$deployment.revisionCode + '/asset-catalog.cat'
)
$expectedSignatureRelativePath = $expectedBodyRelativePath + '.nds'
Assert-True (
    $deployment.contractId -ceq
        'nll/phase3b2-epinel-locale-catalog-overlay/v1' -and
    $deployment.deploymentUid -ceq $DeploymentUid -and
    $deployment.localeCode -cmatch '^[a-z]{2}$' -and
    $deployment.revisionCode -cmatch '^[0-9a-f]{7}$' -and
    $deployment.exactExpressionReplacementCount -eq 2 -and
    $deployment.reverseProjectionVerified -and
    -not $deployment.runtimeToolBindingPerformed -and
    -not $deployment.serverExecutionStarted -and
    -not $deployment.clientExecutionStarted -and
    (Get-Sha256Hex $rollbackPlanPath) -ceq
        [string]$deployment.rollbackPlanSha256 -and
    $rollbackPlan.contractId -ceq
        'nll/phase3b2-epinel-locale-overlay-rollback-plan/v1' -and
    $rollbackPlan.deploymentUid -ceq $DeploymentUid -and
    $rollbackPlan.bodyRelativePath -ceq $expectedBodyRelativePath -and
    $rollbackPlan.signatureRelativePath -ceq
        $expectedSignatureRelativePath -and
    [long]$rollbackPlan.bodyByteLength -eq
        [long]$deployment.bodyByteLength -and
    $rollbackPlan.bodySha256 -ceq $deployment.bodySha256 -and
    [long]$rollbackPlan.signatureByteLength -eq
        [long]$deployment.signatureByteLength -and
    $rollbackPlan.signatureSha256 -ceq $deployment.signatureSha256 -and
    $sausBinding.contractId -ceq
        'nll/phase3b2-epinel-saus-pair-tool-binding/v1' -and
    $sausBinding.wrapperToolSha256 -ceq $expectedGoldenStartSha256
) 'phase3b2_locale_overlay_start_repair_contract_invalid'

$bodyPath = Join-Path $cacheRoot $expectedBodyRelativePath.Replace('/', '\')
$signaturePath = Join-Path $cacheRoot `
    $expectedSignatureRelativePath.Replace('/', '\')
$pairDirectory = Split-Path -Parent $bodyPath
Assert-True (
    (Test-Digest $bodyPath ([long]$deployment.bodyByteLength) `
        ([string]$deployment.bodySha256)) -and
    (Test-Digest $signaturePath ([long]$deployment.signatureByteLength) `
        ([string]$deployment.signatureSha256)) -and
    @(Get-ChildItem -LiteralPath $pairDirectory -File -Force).Count -eq 2 -and
    @(Get-ChildItem -LiteralPath $pairDirectory -Directory -Force).Count -eq 0
) 'phase3b2_locale_overlay_start_repair_pair_invalid'

$priorDerivedStartPath = Join-Path $micronDrive (
    'NLL\Tools\' + [string]$deployment.derivedStartLeaf
)
$correctedDerivedStartLeaf =
    'Start-Phase3B2-Epinel-LocaleOverlay-' +
    [string]$deployment.localeCode + '-v2.ps1'
$correctedDerivedStartPath = Join-Path $micronDrive (
    'NLL\Tools\' + $correctedDerivedStartLeaf
)
Assert-True (
    (Test-Digest $priorDerivedStartPath `
        ([long]$deployment.derivedStartByteLength) `
        ([string]$deployment.derivedStartSha256)) -and
    -not (Test-Path -LiteralPath $correctedDerivedStartPath)
) 'phase3b2_locale_overlay_start_repair_prior_start_invalid'
$priorText = [IO.File]::ReadAllText(
    $priorDerivedStartPath, [Text.Encoding]::UTF8
)
Assert-True ($priorText.Contains(
        '$sausToolBinding.wrapperToolSha256 -ceq ' +
        '(Get-Sha256Hex $PSCommandPath)'
    )) 'phase3b2_locale_overlay_start_repair_cause_not_present'

$inspection = Get-CacheInspection $dotnetPath $verifierDllPath $cacheRoot
Assert-True (
    $inspection.fileCount -eq $deployment.activeCacheFileCountAfter -and
    [long]$inspection.contentByteLength -eq
        [long]$deployment.activeCacheContentByteLengthAfter -and
    $inspection.partialMemberCount -eq 0
) 'phase3b2_locale_overlay_start_repair_cache_shape_invalid'

$correctionPlan = [ordered]@{
    schemaVersion = 1
    contractId =
        'nll/phase3b2-epinel-locale-overlay-start-correction-plan/v1'
    correctionUid = $CorrectionUid
    deploymentUid = $DeploymentUid
    deploymentReceiptSha256 = $expectedDeploymentReceiptSha256
    priorDerivedStartLeaf = [string]$deployment.derivedStartLeaf
    priorDerivedStartByteLength = [long]$deployment.derivedStartByteLength
    priorDerivedStartSha256 = [string]$deployment.derivedStartSha256
    correctedDerivedStartLeaf = $correctedDerivedStartLeaf
    expectedGoldenStartSha256 = $expectedGoldenStartSha256
    runtimeMustBeCold = $true
    cacheMutationRequired = $false
    restorePriorDerivedStartOnFailure = $true
}
$correctionPlanText = ($correctionPlan | ConvertTo-Json -Depth 6) + "`n"
$correctedCreated = $false
$priorArchived = $false
try {
    Write-AtomicUtf8NoBom $micronCorrectionPlanPath $correctionPlanText
    Write-AtomicUtf8NoBom $protectedCorrectionPlanPath $correctionPlanText
    $correctionPlanSha256 = Get-Sha256Hex $micronCorrectionPlanPath
    Assert-True ($correctionPlanSha256 -ceq
        (Get-Sha256Hex $protectedCorrectionPlanPath)) `
        'phase3b2_locale_overlay_start_repair_plan_dual_seal_invalid'

    $derivationJson = & $derivationToolPath `
        -GoldenStartPath $goldenStartPath `
        -DerivedStartPath $correctedDerivedStartPath `
        -ExpectedGoldenStartSha256 $expectedGoldenStartSha256 `
        -CacheFileCountBefore ([int]$deployment.activeCacheFileCountBefore) `
        -CacheContentByteLengthBefore `
            ([long]$deployment.activeCacheContentByteLengthBefore) `
        -CacheFileCountAfter ([int]$deployment.activeCacheFileCountAfter) `
        -CacheContentByteLengthAfter `
            ([long]$deployment.activeCacheContentByteLengthAfter)
    $correctedCreated = Test-Path -LiteralPath $correctedDerivedStartPath `
        -PathType Leaf
    $derivation = (($derivationJson | Out-String) | ConvertFrom-Json)
    Assert-True (
        $derivation.contractId -ceq
            'nll/phase3b2-epinel-locale-overlay-start-derivation/v1' -and
        $derivation.exactExpressionReplacementCount -eq 3 -and
        $derivation.reverseProjectionVerified -and
        $derivation.goldenStartUnchanged -and
        $derivation.derivedSelfHashCheckRemoved -and
        $derivation.parentGoldenBindingPreserved -and
        (Get-Sha256Hex $correctedDerivedStartPath) -ceq
            [string]$derivation.derivedStartSha256
    ) 'phase3b2_locale_overlay_start_repair_corrected_start_invalid'

    Move-Item -LiteralPath $priorDerivedStartPath `
        -Destination $rejectedStartArchivePath
    $priorArchived = $true
    Assert-True (
        (Test-Digest $rejectedStartArchivePath `
            ([long]$deployment.derivedStartByteLength) `
            ([string]$deployment.derivedStartSha256)) -and
        -not (Test-Path -LiteralPath $priorDerivedStartPath) -and
        (Get-Sha256Hex $goldenStartPath) -ceq
            $expectedGoldenStartSha256 -and
        (Get-Sha256Hex $databasePath) -ceq
            $expectedGoldenDatabaseSha256 -and
        (Get-Sha256Hex $serverDllPath) -ceq $expectedServerDllSha256 -and
        (Get-Sha256Hex $micronHostsPath) -ceq $expectedBaseHostsSha256
    ) 'phase3b2_locale_overlay_start_repair_postcondition_invalid'

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-locale-overlay-start-correction/v1'
        correctedAtUtc = [DateTimeOffset]::UtcNow.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'"
        )
        correctionUid = $CorrectionUid
        deploymentUid = $DeploymentUid
        deploymentReceiptSha256 = $expectedDeploymentReceiptSha256
        correctionPlanSha256 = $correctionPlanSha256
        causeCode = 'derived_start_inherited_saus_wrapper_self_hash'
        preventedFailureCode =
            'phase3b2_epinel_catalog_transport_start_saus_binding_invalid'
        sausBindingReceiptSha256 = Get-Sha256Hex $sausBindingPath
        sausBindingWrapperSha256 = [string]$sausBinding.wrapperToolSha256
        derivationToolSha256 = Get-Sha256Hex $derivationToolPath
        goldenStartSha256 = $expectedGoldenStartSha256
        priorDerivedStartLeaf = [string]$deployment.derivedStartLeaf
        priorDerivedStartByteLength =
            [long]$deployment.derivedStartByteLength
        priorDerivedStartSha256 = [string]$deployment.derivedStartSha256
        priorDerivedStartArchived = $true
        correctedDerivedStartLeaf = $correctedDerivedStartLeaf
        correctedDerivedStartByteLength =
            [long]$derivation.derivedStartByteLength
        correctedDerivedStartSha256 =
            [string]$derivation.derivedStartSha256
        exactExpressionReplacementCount = 3
        reverseProjectionVerified = $true
        derivedSelfHashCheckRemoved = $true
        parentGoldenBindingPreserved = $true
        activeCacheFileCount = [int]$inspection.fileCount
        activeCacheContentByteLength =
            [long]$inspection.contentByteLength
        cacheModified = $false
        goldenStartModified = $false
        innerStartModified = $false
        completionToolsModified = $false
        databaseModified = $false
        serverBinaryModified = $false
        hostsModified = $false
        runtimeToolBindingPerformed = $false
        existingOperatorCacheInspected = $false
        existingOperatorCacheModified = $false
        localLowInspected = $false
        localLowModified = $false
        officialOutboundUsed = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        singleValidationRunAuthorized = $true
        validationRunConsumed = $false
        nextStepCode =
            'review_then_boot_micron_run_corrected_locale_overlay_once'
    }
    $receiptText = ($receipt | ConvertTo-Json -Depth 7) + "`n"
    Write-AtomicUtf8NoBom $micronCorrectionReceiptPath $receiptText
    Write-AtomicUtf8NoBom $protectedCorrectionReceiptPath $receiptText
    $receiptSha256 = Get-Sha256Hex $micronCorrectionReceiptPath
    Assert-True ($receiptSha256 -ceq
        (Get-Sha256Hex $protectedCorrectionReceiptPath)) `
        'phase3b2_locale_overlay_start_repair_receipt_dual_seal_invalid'

    [pscustomobject]@{
        Receipt = $receipt
        MicronReceiptPath = $micronCorrectionReceiptPath
        MicronReceiptByteLength =
            [long](Get-Item -LiteralPath $micronCorrectionReceiptPath).Length
        MicronReceiptSha256 = $receiptSha256
        ProtectedReceiptPath = $protectedCorrectionReceiptPath
        MicronStartCommand =
            "& 'C:\NLL\Tools\$correctedDerivedStartLeaf'"
        MicronCompletionCommand =
            "& 'C:\NLL\Tools\Complete-Phase3B2-Epinel-Minimal.ps1' " +
            '-ObservedStageCode <stage> -OutcomeCode <outcome>'
    } | ConvertTo-Json -Depth 8
}
catch {
    $originalError = $_
    $rollbackFailures = @()
    foreach ($receiptPath in @(
            $micronCorrectionReceiptPath,
            $protectedCorrectionReceiptPath
        )) {
        if (Test-Path -LiteralPath $receiptPath -PathType Leaf) {
            try {
                Remove-Item -LiteralPath $receiptPath -Force
            }
            catch {
                $rollbackFailures += 'remove_receipt:' + $receiptPath
            }
        }
    }
    if ($priorArchived -and
        -not (Test-Path -LiteralPath $priorDerivedStartPath) -and
        (Test-Path -LiteralPath $rejectedStartArchivePath -PathType Leaf)) {
        try {
            Move-Item -LiteralPath $rejectedStartArchivePath `
                -Destination $priorDerivedStartPath
        }
        catch {
            $rollbackFailures += 'restore_prior_start'
        }
    }
    if ($correctedCreated -and
        (Test-Path -LiteralPath $correctedDerivedStartPath -PathType Leaf)) {
        try {
            Remove-Item -LiteralPath $correctedDerivedStartPath -Force
        }
        catch {
            $rollbackFailures += 'remove_corrected_start'
        }
    }
    foreach ($planPath in @(
            $micronCorrectionPlanPath,
            $protectedCorrectionPlanPath
        )) {
        if (Test-Path -LiteralPath $planPath -PathType Leaf) {
            try {
                Remove-Item -LiteralPath $planPath -Force
            }
            catch {
                $rollbackFailures += 'remove_plan:' + $planPath
            }
        }
    }
    if ($rollbackFailures.Count -ne 0) {
        throw (
            'phase3b2_locale_overlay_start_repair_rollback_failed:' +
            ($rollbackFailures -join ',') + ';original=' +
            [string]$originalError.Exception.Message
        )
    }
    throw $originalError
}
