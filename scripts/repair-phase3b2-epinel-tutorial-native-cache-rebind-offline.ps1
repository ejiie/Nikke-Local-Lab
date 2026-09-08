#requires -Version 5.1

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Z]$')]
    [string]$MicronDriveLetter = 'E',
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$RevisionUid = '8ba2fb71-913c-4eaf-a56e-55c10c79d5c1',
    [string]$ProtectedRoot = (
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\' +
        'Micron-PrePhysicalLane-20260823\PhysicalP2\' +
        'EpinelTutorialNativeCacheRebind-v1'
    ),
    [switch]$AuditOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

throw 'phase3b2_tutorial_native_cache_rebind_v1_superseded_by_wrapper_correction_v2'

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
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha256.ComputeHash($bytes)
    }
    finally {
        $sha256.Dispose()
    }
    ([BitConverter]::ToString($digest) -replace '-', '').ToLowerInvariant()
}

function Test-Digest {
    param([string]$Path, [long]$ByteLength, [string]$Sha256)
    return (Test-Path -LiteralPath $Path -PathType Leaf) -and
        (Get-Item -LiteralPath $Path).Length -eq $ByteLength -and
        (Get-Sha256Hex $Path) -ceq $Sha256
}

function Write-AtomicUtf8NoBom {
    param([string]$Path, [string]$Text)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporary = $Path + '.partial-' + [Guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText(
        $temporary, $Text, [Text.UTF8Encoding]::new($false)
    )
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

$expectedRevisionUid = '8ba2fb71-913c-4eaf-a56e-55c10c79d5c1'
$expectedGoldenSealUid = '15089f3e-92f2-4833-ab1b-348d1463f9fc'
$expectedGoldenReceiptLength = 2596L
$expectedGoldenReceiptSha256 =
    'ebf5c2f7692e7de7ec9b8bcf3acba112cdb8efbfbb888967acde7e429e877f9c'
$expectedTutorialReceiptLength = 3186L
$expectedTutorialReceiptSha256 =
    '5685274460cd64bee2391a962ec0988b5938dbb0f3ee98ac64e16c8204e31f00'
$expectedTutorialBindingLength = 1358L
$expectedTutorialBindingSha256 =
    '6706cae31a8c3e08426c0470142ad20b3b02726ae39fe655ef911ca5ce591ede'
$expectedDatabaseLength = 416762L
$expectedDatabaseSha256 =
    'e8c6c7d299be04c91435391bd44e346ad3dd84f31697654f18b1aa8a47052330'
$expectedHistoricalSausBindingSha256 =
    '604ae318c4fefda2371e1e74eb648e008359758e8231ef95fbbbf3ff357c03a5'
$expectedHistoricalInnerLength = 39526L
$expectedHistoricalInnerSha256 =
    'a039cd5186df92c16c0091f7d4b4c4bbb907d0bf2adc3ff94d8d425699bc5f69'
$expectedHistoricalWrapperLength = 15147L
$expectedHistoricalWrapperSha256 =
    'fe667ba466ea27a5bfd55e09c4d0cd9ef94b04d434d95ac1590ccd7f813e493b'
$expectedActiveInnerLength = 41649L
$expectedActiveInnerSha256 =
    '00270a38140f4ace8e77192e285731909a172e4e587c80394bac7bb55650e7ae'
$expectedTemplateLength = 21347L
$expectedTemplateSha256 =
    '47ed968acfd3ad0b7bf0b32e5239935344846e62ef331ee0ade8977bd1879f03'
$expectedRepairedWrapperLength = 21624L
$expectedRepairedWrapperSha256 =
    '4711bf99fdbe74d503d1705c37ea175b24766ab1915972beb8e91b1ed7a600a8'
$expectedCacheFileCount = 40111
$expectedCacheByteLength = 39030643658L

$bindingValues = [ordered]@{
    '__NATIVE_CACHE_DEPLOYMENT_RECEIPT_SHA256__' =
        '14bf845aec4cded1d80e8efb57a3eb4f4639ef68bd1fdf7a8d9de462689aae7d'
    '__NATIVE_CACHE_VERIFIER_MANIFEST_SHA256__' =
        '3305d52786315bc927c46cdb988ce35b067d704f0a562be7aa469a188da3541c'
    '__NATIVE_CACHE_HEADER_CLOSURE_RECEIPT_SHA256__' =
        'bc5e9e0f8f45f17c4db0408cee3d8a88389e11d1578670e9733a2563535444ce'
    '__NATIVE_CACHE_CATALOG_TRANSPORT_REPAIR_RECEIPT_SHA256__' =
        'fcd146934c1b2d74657034d8f77d0b0663c630474c799149621c767f1f1da9f6'
    '__NATIVE_CACHE_CATALOG_TRANSPORT_CONTRACT_SHA256__' =
        '4e7903b52343e868711114462588e20ec3f19e2c75d23ce179155544dd024a7c'
    '__EPINEL_SAUS_STAGING_RECEIPT_SHA256__' =
        '2350aae3ba7320da21bb80a1eb26c118275b39b0678b3d844990742240f019e2'
    '__EPINEL_SAUS_CONTRACT_SHA256__' =
        '0a29dc7d5bfbfd53cba8735029f9fbcc708834d678c7e51ea5a84b234fc3a65d'
    '__EPINEL_HISTORICAL_SAUS_TOOL_BINDING_SHA256__' =
        $expectedHistoricalSausBindingSha256
    '__EPINEL_HISTORICAL_SAUS_MINIMAL_START_TOOL_SHA256__' =
        $expectedHistoricalInnerSha256
    '__EPINEL_HISTORICAL_SAUS_WRAPPER_TOOL_SHA256__' =
        $expectedHistoricalWrapperSha256
    '__NATIVE_CACHE_MINIMAL_START_TOOL_SHA256__' =
        $expectedActiveInnerSha256
    '__EPINEL_TUTORIAL_MATERIALIZATION_RECEIPT_SHA256__' =
        $expectedTutorialReceiptSha256
    '__EPINEL_TUTORIAL_START_BINDING_RECEIPT_SHA256__' =
        $expectedTutorialBindingSha256
    '__EPINEL_TUTORIAL_REVISION_UID__' = $expectedRevisionUid
    '__EPINEL_TUTORIAL_DATABASE_SHA256__' = $expectedDatabaseSha256
}

Assert-True ($RevisionUid -ceq $expectedRevisionUid) `
    'phase3b2_tutorial_native_cache_rebind_revision_invalid'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
Assert-True ($AuditOnly -or $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    'phase3b2_tutorial_native_cache_rebind_requires_administrator'

$micronDrive = $MicronDriveLetter + ':'
if ($AuditOnly) {
    Assert-True (
        $env:SystemDrive -ceq 'C:' -and
        (Test-Path -LiteralPath (Join-Path $micronDrive `
                'Windows\System32') -PathType Container)
    ) 'phase3b2_tutorial_native_cache_rebind_wrong_disk_boundary'
}
else {
    $systemDisk = Get-Partition -DriveLetter C | Get-Disk
    $micronDisk = Get-Partition -DriveLetter $MicronDriveLetter | Get-Disk
    Assert-True (
        $env:SystemDrive -ceq 'C:' -and
        $systemDisk.FriendlyName -like 'Samsung SSD 980*' -and
        $micronDisk.FriendlyName -like 'Micron_2200*' -and
        (Test-Path -LiteralPath (Join-Path $micronDrive `
                'Windows\System32') -PathType Container)
    ) 'phase3b2_tutorial_native_cache_rebind_wrong_disk_boundary'
}

$runtimeProcesses = @(Get-Process -Name @(
        'EpinelPS', 'NIKKE', 'nikke_launcher',
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
    ) -ErrorAction SilentlyContinue)
Assert-True ($runtimeProcesses.Count -eq 0) `
    'phase3b2_tutorial_native_cache_rebind_runtime_not_cold'

$physicalRoot = Join-Path $micronDrive 'NLL\Evidence\Phase3B2\Physical'
$goldenReceiptPath = Join-Path (
    $physicalRoot + '\epinel-lobby-golden-baseline-v1\' +
    $expectedGoldenSealUid
) 'golden-baseline.receipt.json'
$tutorialReceiptPath = Join-Path (
    $physicalRoot + '\epinel-tutorial-only-v1\' + $RevisionUid
) 'materialization.receipt.json'
$tutorialBindingPath = Join-Path (
    $physicalRoot + '\epinel-tutorial-start-binding-v1\' + $RevisionUid
) 'binding.receipt.json'
$sausBindingPath = Join-Path (
    $physicalRoot + '\epinel-saus-pair-staging-v1'
) 'tool-binding.receipt.json'
$activePointerPath = Join-Path (
    $physicalRoot + '\epinel-minimal-reference-v1'
) 'active-run.pointer.json'
$activeWrapperPath = Join-Path $micronDrive `
    'NLL\Tools\Start-Phase3B2-Epinel-NativeCache.ps1'
$activeInnerPath = Join-Path $micronDrive `
    'NLL\Tools\start-phase3b2-epinel-minimal-reference-in-micron.ps1'
$databasePath = Join-Path $micronDrive `
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\db.json'
$sqliteRuntimePaths = @(
    Join-Path $micronDrive `
        'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\epinelps.db'
    Join-Path $micronDrive `
        'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\epinelps.db-shm'
    Join-Path $micronDrive `
        'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\epinelps.db-wal'
)
$cacheRoot = Join-Path $micronDrive `
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\cache'
$verifierRoot = Join-Path $micronDrive `
    'NLL\Tools\Phase3B2.NativeCacheVerifier-v1'
$verifierDllPath = Join-Path $verifierRoot `
    'Phase3B2.NativeCacheMaterializer.dll'
$verifierManifestPath = Join-Path $verifierRoot 'bundle.manifest.json'
$dotnetPath = Join-Path $micronDrive 'Program Files\dotnet\dotnet.exe'
$templatePath = Join-Path $PSScriptRoot `
    'Start-Phase3B2-Epinel-NativeCache-CatalogTransport.ps1'
$evidenceRoot = Join-Path (
    $physicalRoot + '\epinel-tutorial-native-cache-rebind-v1'
) $RevisionUid
$repairReceiptPath = Join-Path $evidenceRoot 'repair.receipt.json'
$backupRoot = Join-Path $micronDrive (
    'NLL\Backups\Phase3B2\EpinelTutorialNativeCacheRebind-v1\' +
    $RevisionUid
)
$priorWrapperBackupPath = Join-Path $backupRoot `
    'Start-Phase3B2-Epinel-NativeCache.before.ps1'
$rollbackPlanPath = Join-Path $backupRoot 'rollback.plan.json'
$protectedRevisionRoot = Join-Path $ProtectedRoot $RevisionUid
$protectedReceiptPath = Join-Path $protectedRevisionRoot `
    'repair.receipt.json'

$requiredInputs = @(
    $goldenReceiptPath, $tutorialReceiptPath, $tutorialBindingPath,
    $sausBindingPath, $activeWrapperPath, $activeInnerPath,
    $databasePath, $verifierDllPath, $verifierManifestPath,
    $dotnetPath, $templatePath
)
Assert-True (
    @($requiredInputs | Where-Object {
            -not (Test-Path -LiteralPath $_ -PathType Leaf)
        }).Count -eq 0 -and
    (Test-Path -LiteralPath $cacheRoot -PathType Container) -and
    -not (Test-Path -LiteralPath $activePointerPath) -and
    @($sqliteRuntimePaths | Where-Object {
            Test-Path -LiteralPath $_
        }).Count -eq 0
) 'phase3b2_tutorial_native_cache_rebind_input_missing_or_runtime_dirty'

Assert-True (
    (Test-Digest $goldenReceiptPath $expectedGoldenReceiptLength `
        $expectedGoldenReceiptSha256) -and
    (Test-Digest $tutorialReceiptPath $expectedTutorialReceiptLength `
        $expectedTutorialReceiptSha256) -and
    (Test-Digest $tutorialBindingPath $expectedTutorialBindingLength `
        $expectedTutorialBindingSha256) -and
    (Get-Sha256Hex $sausBindingPath) -ceq
        $expectedHistoricalSausBindingSha256 -and
    (Test-Digest $activeWrapperPath $expectedHistoricalWrapperLength `
        $expectedHistoricalWrapperSha256) -and
    (Test-Digest $activeInnerPath $expectedActiveInnerLength `
        $expectedActiveInnerSha256) -and
    (Test-Digest $databasePath $expectedDatabaseLength `
        $expectedDatabaseSha256) -and
    (Test-Digest $templatePath $expectedTemplateLength `
        $expectedTemplateSha256)
) 'phase3b2_tutorial_native_cache_rebind_input_digest_invalid'

$golden = Get-Content -LiteralPath $goldenReceiptPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
$tutorial = Get-Content -LiteralPath $tutorialReceiptPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
$tutorialBinding = Get-Content -LiteralPath $tutorialBindingPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
$sausBinding = Get-Content -LiteralPath $sausBindingPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
Assert-True (
    $golden.contractId -ceq
        'nll/phase3b2-epinel-lobby-golden-baseline/v1' -and
    $golden.sealUid -ceq $expectedGoldenSealUid -and
    $golden.databaseSha256 -ceq
        'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194' -and
    $tutorial.contractId -ceq
        'nll/phase3b2-epinel-tutorial-only-materialization/v1' -and
    $tutorial.revisionUid -ceq $RevisionUid -and
    $tutorial.goldenSealUid -ceq $expectedGoldenSealUid -and
    $tutorial.goldenBaselineReceiptSha256 -ceq
        $expectedGoldenReceiptSha256 -and
    $tutorial.databaseAfterSha256 -ceq $expectedDatabaseSha256 -and
    $tutorial.tutorialGroupCountAfter -eq 40 -and
    -not $tutorial.nonTutorialStateChanged -and
    -not $tutorial.cacheMutationPerformed -and
    -not $tutorial.serverBinaryMutationPerformed -and
    $tutorial.validationRunConsumed -eq $false -and
    $tutorialBinding.contractId -ceq
        'nll/phase3b2-epinel-tutorial-start-binding/v1' -and
    $tutorialBinding.revisionUid -ceq $RevisionUid -and
    $tutorialBinding.tutorialMaterializationReceiptSha256 -ceq
        $expectedTutorialReceiptSha256 -and
    $tutorialBinding.databaseSha256 -ceq $expectedDatabaseSha256 -and
    $tutorialBinding.priorStartToolByteLength -eq
        $expectedHistoricalInnerLength -and
    $tutorialBinding.priorStartToolSha256 -ceq
        $expectedHistoricalInnerSha256 -and
    $tutorialBinding.boundStartToolByteLength -eq
        $expectedActiveInnerLength -and
    $tutorialBinding.boundStartToolSha256 -ceq
        $expectedActiveInnerSha256 -and
    $tutorialBinding.tutorialReceiptPreflightEnabled -and
    $tutorialBinding.tutorialDatabaseDigestPreflightEnabled -and
    $tutorialBinding.nonTutorialProgressionExpectedUnchanged -and
    -not $tutorialBinding.nativeCacheWrapperMutationPerformed -and
    $sausBinding.contractId -ceq
        'nll/phase3b2-epinel-saus-pair-tool-binding/v1' -and
    $sausBinding.minimalStartToolSha256 -ceq
        $expectedHistoricalInnerSha256 -and
    $sausBinding.wrapperToolSha256 -ceq
        $expectedHistoricalWrapperSha256 -and
    -not $sausBinding.clientExecutionStarted
) 'phase3b2_tutorial_native_cache_rebind_contract_invalid'

$inspectionOutput = & $dotnetPath $verifierDllPath `
    'inspect-cache-tree' $cacheRoot 2>&1
Assert-True ($LASTEXITCODE -eq 0) `
    'phase3b2_tutorial_native_cache_rebind_cache_inspection_failed'
$inspection = (($inspectionOutput | Out-String) | ConvertFrom-Json)
Assert-True (
    $inspection.contractId -ceq
        'nll/phase3b2-native-cache-tree-inspection/v1' -and
    $inspection.longPathSafeEnumerationUsed -and
    $inspection.fileCount -eq $expectedCacheFileCount -and
    [long]$inspection.contentByteLength -eq $expectedCacheByteLength -and
    $inspection.partialMemberCount -eq 0
) 'phase3b2_tutorial_native_cache_rebind_cache_shape_invalid'

$templateText = Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8
foreach ($entry in $bindingValues.GetEnumerator()) {
    $matchCount = ([regex]::Matches(
            $templateText, [regex]::Escape([string]$entry.Key)
        )).Count
    Assert-True ($matchCount -eq 1) `
        ('phase3b2_tutorial_native_cache_rebind_placeholder_invalid:' +
            [string]$entry.Key + ':' + $matchCount)
    $templateText = $templateText.Replace(
        [string]$entry.Key, [string]$entry.Value
    )
}
Assert-True (-not ($templateText -match '__[A-Z0-9_]+__')) `
    'phase3b2_tutorial_native_cache_rebind_unbound_placeholder'
$parseErrors = $null
[Management.Automation.Language.Parser]::ParseInput(
    $templateText, [ref]$null, [ref]$parseErrors
) | Out-Null
Assert-True (@($parseErrors).Count -eq 0) `
    'phase3b2_tutorial_native_cache_rebind_candidate_parse_failed'
$candidateByteLength =
    [Text.UTF8Encoding]::new($false).GetByteCount($templateText)
$candidateSha256 = Get-TextSha256Hex $templateText
Assert-True (
    $candidateByteLength -eq $expectedRepairedWrapperLength -and
    $candidateSha256 -ceq $expectedRepairedWrapperSha256
) 'phase3b2_tutorial_native_cache_rebind_candidate_digest_invalid'

$audit = [ordered]@{
    schemaVersion = 1
    contractId =
        'nll/phase3b2-epinel-tutorial-native-cache-rebind-audit/v1'
    auditedAtUtc = [DateTimeOffset]::UtcNow.ToString(
        "yyyy-MM-dd'T'HH:mm:ss'Z'"
    )
    revisionUid = $RevisionUid
    goldenBaselineReceiptSha256 = $expectedGoldenReceiptSha256
    tutorialMaterializationReceiptSha256 = $expectedTutorialReceiptSha256
    tutorialStartBindingReceiptSha256 = $expectedTutorialBindingSha256
    historicalSausToolBindingReceiptSha256 =
        $expectedHistoricalSausBindingSha256
    priorWrapperToolSha256 = $expectedHistoricalWrapperSha256
    activeMinimalStartToolSha256 = $expectedActiveInnerSha256
    databaseSha256 = $expectedDatabaseSha256
    repairedWrapperToolByteLength = $candidateByteLength
    repairedWrapperToolSha256 = $candidateSha256
    activeCacheFileCount = [int]$inspection.fileCount
    activeCacheContentByteLength = [long]$inspection.contentByteLength
    activeCachePartialMemberCount = [int]$inspection.partialMemberCount
    historicalSausEvidencePreserved = $true
    runtimeCold = $true
    targetOsOffline = $true
    mutationPerformed = $false
    verdictCode = 'all_transitive_inputs_and_candidate_verified'
}
if ($AuditOnly) {
    $audit | ConvertTo-Json -Depth 6
    return
}

Assert-True (
    -not (Test-Path -LiteralPath $evidenceRoot) -and
    -not (Test-Path -LiteralPath $backupRoot) -and
    -not (Test-Path -LiteralPath $protectedRevisionRoot)
) 'phase3b2_tutorial_native_cache_rebind_destination_exists'

$backupCreated = $false
$wrapperReplaced = $false
$evidenceCreated = $false
$protectedCreated = $false
try {
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    $backupCreated = $true
    Copy-Item -LiteralPath $activeWrapperPath `
        -Destination $priorWrapperBackupPath
    Assert-True ((Get-Sha256Hex $priorWrapperBackupPath) -ceq
        $expectedHistoricalWrapperSha256) `
        'phase3b2_tutorial_native_cache_rebind_backup_invalid'

    $rollbackPlan = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-tutorial-native-cache-rebind-rollback-plan/v1'
        revisionUid = $RevisionUid
        activeWrapperPath = $activeWrapperPath
        priorWrapperBackupPath = $priorWrapperBackupPath
        priorWrapperSha256 = $expectedHistoricalWrapperSha256
        repairedWrapperSha256 = $expectedRepairedWrapperSha256
        rollbackCode =
            'while_micron_offline_restore_prior_wrapper_only'
    }
    Write-AtomicUtf8NoBom $rollbackPlanPath `
        (($rollbackPlan | ConvertTo-Json -Depth 5) + "`n")

    Write-AtomicUtf8NoBom $activeWrapperPath $templateText
    $wrapperReplaced = $true
    Assert-True (
        (Get-Item -LiteralPath $activeWrapperPath).Length -eq
            $expectedRepairedWrapperLength -and
        (Get-Sha256Hex $activeWrapperPath) -ceq
            $expectedRepairedWrapperSha256 -and
        (Get-Sha256Hex $activeInnerPath) -ceq
            $expectedActiveInnerSha256 -and
        (Get-Sha256Hex $databasePath) -ceq $expectedDatabaseSha256
    ) 'phase3b2_tutorial_native_cache_rebind_post_apply_invalid'

    New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null
    $evidenceCreated = $true
    $receipt = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-tutorial-native-cache-rebind/v1'
        repairedAtUtc = [DateTimeOffset]::UtcNow.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'"
        )
        revisionUid = $RevisionUid
        goldenBaselineReceiptSha256 = $expectedGoldenReceiptSha256
        historicalSausToolBindingReceiptSha256 =
            $expectedHistoricalSausBindingSha256
        tutorialMaterializationReceiptSha256 =
            $expectedTutorialReceiptSha256
        tutorialStartBindingReceiptSha256 =
            $expectedTutorialBindingSha256
        priorWrapperToolByteLength = $expectedHistoricalWrapperLength
        priorWrapperToolSha256 = $expectedHistoricalWrapperSha256
        repairedWrapperToolByteLength = $expectedRepairedWrapperLength
        repairedWrapperToolSha256 = $expectedRepairedWrapperSha256
        activeMinimalStartToolByteLength = $expectedActiveInnerLength
        activeMinimalStartToolSha256 = $expectedActiveInnerSha256
        databaseByteLength = $expectedDatabaseLength
        databaseSha256 = $expectedDatabaseSha256
        activeCacheFileCount = [int]$inspection.fileCount
        activeCacheContentByteLength = [long]$inspection.contentByteLength
        activeCachePartialMemberCount = [int]$inspection.partialMemberCount
        historicalSausEvidencePreserved = $true
        goldenBaselinePreserved = $true
        cacheMutationPerformed = $false
        databaseMutationPerformed = $false
        serverBinaryMutationPerformed = $false
        activeInnerStartMutationPerformed = $false
        wrapperMutationPerformed = $true
        priorWrapperBackedUp = $true
        rollbackPlanByteLength =
            (Get-Item -LiteralPath $rollbackPlanPath).Length
        rollbackPlanSha256 = Get-Sha256Hex $rollbackPlanPath
        targetOsOfflineDuringRepair = $true
        officialOutboundUsed = $false
        officialApiUsed = $false
        officialLoginUsed = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        validationRunConsumed = $false
        nextStepCode =
            'boot_micron_nlloperator_run_tutorial_validation_once'
    }
    Write-AtomicUtf8NoBom $repairReceiptPath `
        (($receipt | ConvertTo-Json -Depth 7) + "`n")

    New-Item -ItemType Directory -Path $protectedRevisionRoot -Force |
        Out-Null
    Copy-Item -LiteralPath $repairReceiptPath `
        -Destination $protectedReceiptPath
    $protectedCreated = $true
    Assert-True ((Get-Sha256Hex $protectedReceiptPath) -ceq
        (Get-Sha256Hex $repairReceiptPath)) `
        'phase3b2_tutorial_native_cache_rebind_protected_copy_invalid'

    [pscustomobject]@{
        Receipt = $receipt
        Audit = $audit
        ReceiptPath = $repairReceiptPath
        ReceiptByteLength = (Get-Item -LiteralPath $repairReceiptPath).Length
        ReceiptSha256 = Get-Sha256Hex $repairReceiptPath
        ProtectedReceiptPath = $protectedReceiptPath
        MicronStartCommand =
            "& 'C:\NLL\Tools\Start-Phase3B2-Epinel-NativeCache.ps1'"
    } | ConvertTo-Json -Depth 9
}
catch {
    if ($wrapperReplaced -and
        (Test-Path -LiteralPath $priorWrapperBackupPath -PathType Leaf)) {
        Copy-Item -LiteralPath $priorWrapperBackupPath `
            -Destination $activeWrapperPath -Force
    }
    if ($evidenceCreated -and
        (Test-Path -LiteralPath $evidenceRoot -PathType Container)) {
        Remove-Item -LiteralPath $evidenceRoot -Recurse -Force
    }
    if ($protectedCreated -and
        (Test-Path -LiteralPath $protectedReceiptPath -PathType Leaf)) {
        Remove-Item -LiteralPath $protectedReceiptPath -Force
    }
    throw
}
