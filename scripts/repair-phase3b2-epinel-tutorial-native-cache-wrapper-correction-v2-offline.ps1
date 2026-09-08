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
        'EpinelTutorialNativeCacheWrapperCorrection-v2'
    ),
    [switch]$AuditOnly
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
$expectedPriorRebindReceiptSha256 =
    '673b1e9104ce15f44bb04097aac9a1215ee3a61a3a7b86804546fe722fec7845'
$expectedPriorWrapperLength = 21624L
$expectedPriorWrapperSha256 =
    '4711bf99fdbe74d503d1705c37ea175b24766ab1915972beb8e91b1ed7a600a8'
$expectedCorrectedWrapperLength = 23779L
$expectedCorrectedWrapperSha256 =
    '26dccd12c7f0daaa35ac225b0fbdb0abf7767cd0ab529a0958663efaaccf2fbc'
$expectedTemplateLength = 23478L
$expectedTemplateSha256 =
    'edb33a9d4e981d002ea184a889285d9b49905bddfbefe405fec2b227fb5cee39'
$expectedTransportRepairSha256 =
    'fcd1469e6c348a91f2a9ef5bef02ad52d6a95099b20a3ff354c73fb36d40f430'
$expectedCatalogContractSha256 =
    '4e7903d912b3859691864b22a75a53e80881c744bd0fbee9e375036142d65654'
$expectedDatabaseSha256 =
    'e8c6c7d299be04c91435391bd44e346ad3dd84f31697654f18b1aa8a47052330'
$expectedInnerStartSha256 =
    '00270a38140f4ace8e77192e285731909a172e4e587c80394bac7bb55650e7ae'
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
        $expectedTransportRepairSha256
    '__NATIVE_CACHE_CATALOG_TRANSPORT_CONTRACT_SHA256__' =
        $expectedCatalogContractSha256
    '__EPINEL_SAUS_STAGING_RECEIPT_SHA256__' =
        '2350aae3ba7320da21bb80a1eb26c118275b39b0678b3d844990742240f019e2'
    '__EPINEL_SAUS_CONTRACT_SHA256__' =
        '0a29dc7d5bfbfd53cba8735029f9fbcc708834d678c7e51ea5a84b234fc3a65d'
    '__EPINEL_HISTORICAL_SAUS_TOOL_BINDING_SHA256__' =
        '604ae318c4fefda2371e1e74eb648e008359758e8231ef95fbbbf3ff357c03a5'
    '__EPINEL_HISTORICAL_SAUS_MINIMAL_START_TOOL_SHA256__' =
        'a039cd5186df92c16c0091f7d4b4c4bbb907d0bf2adc3ff94d8d425699bc5f69'
    '__EPINEL_HISTORICAL_SAUS_WRAPPER_TOOL_SHA256__' =
        'fe667ba466ea27a5bfd55e09c4d0cd9ef94b04d434d95ac1590ccd7f813e493b'
    '__NATIVE_CACHE_MINIMAL_START_TOOL_SHA256__' =
        $expectedInnerStartSha256
    '__EPINEL_TUTORIAL_MATERIALIZATION_RECEIPT_SHA256__' =
        '5685274460cd64bee2391a962ec0988b5938dbb0f3ee98ac64e16c8204e31f00'
    '__EPINEL_TUTORIAL_START_BINDING_RECEIPT_SHA256__' =
        '6706cae31a8c3e08426c0470142ad20b3b02726ae39fe655ef911ca5ce591ede'
    '__EPINEL_TUTORIAL_WRAPPER_REBIND_V1_RECEIPT_SHA256__' =
        $expectedPriorRebindReceiptSha256
    '__EPINEL_TUTORIAL_WRAPPER_REBIND_V1_WRAPPER_SHA256__' =
        $expectedPriorWrapperSha256
    '__EPINEL_TUTORIAL_REVISION_UID__' = $expectedRevisionUid
    '__EPINEL_TUTORIAL_DATABASE_SHA256__' = $expectedDatabaseSha256
}

Assert-True ($RevisionUid -ceq $expectedRevisionUid) `
    'phase3b2_tutorial_wrapper_correction_v2_revision_invalid'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
Assert-True ($AuditOnly -or $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    'phase3b2_tutorial_wrapper_correction_v2_requires_administrator'

$micronDrive = $MicronDriveLetter + ':'
if ($AuditOnly) {
    Assert-True (
        $env:SystemDrive -ceq 'C:' -and
        (Test-Path -LiteralPath (Join-Path $micronDrive `
                'Windows\System32') -PathType Container)
    ) 'phase3b2_tutorial_wrapper_correction_v2_wrong_disk_boundary'
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
    ) 'phase3b2_tutorial_wrapper_correction_v2_wrong_disk_boundary'
}
Assert-True (@(Get-Process -Name @(
        'EpinelPS', 'NIKKE', 'nikke_launcher',
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
    ) -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_tutorial_wrapper_correction_v2_runtime_not_cold'

$physicalRoot = Join-Path $micronDrive 'NLL\Evidence\Phase3B2\Physical'
$runtimeRoot = Join-Path $micronDrive `
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
$verifierRoot = Join-Path $micronDrive `
    'NLL\Tools\Phase3B2.NativeCacheVerifier-v1'
$activePointerPath = Join-Path (
    $physicalRoot + '\epinel-minimal-reference-v1'
) 'active-run.pointer.json'
$cacheRoot = Join-Path $runtimeRoot 'cache'
$activeWrapperPath = Join-Path $micronDrive `
    'NLL\Tools\Start-Phase3B2-Epinel-NativeCache.ps1'
$activeInnerPath = Join-Path $micronDrive `
    'NLL\Tools\start-phase3b2-epinel-minimal-reference-in-micron.ps1'
$databasePath = Join-Path $runtimeRoot 'db.json'
$serverDllPath = Join-Path $runtimeRoot 'EpinelPS.dll'
$hostsPath = Join-Path $micronDrive `
    'Windows\System32\drivers\etc\hosts'
$dotnetPath = Join-Path $micronDrive 'Program Files\dotnet\dotnet.exe'
$verifierManifestPath = Join-Path $verifierRoot 'bundle.manifest.json'
$verifierDllPath = Join-Path $verifierRoot `
    'Phase3B2.NativeCacheMaterializer.dll'
$headerPath = Join-Path $cacheRoot `
    'prdenv\150-b059c3f36c\StandaloneWindows64\pck\latest-651.txt'
$transportRoot = Join-Path $physicalRoot `
    'epinel-native-cache-catalog-transport-v1'
$priorRebindPath = Join-Path (
    $physicalRoot + '\epinel-tutorial-native-cache-rebind-v1\' +
    $RevisionUid
) 'repair.receipt.json'
$templatePath = Join-Path $PSScriptRoot `
    'Start-Phase3B2-Epinel-NativeCache-CatalogTransport.ps1'
$evidenceRoot = Join-Path (
    $physicalRoot + '\epinel-tutorial-native-cache-wrapper-correction-v2'
) $RevisionUid
$repairReceiptPath = Join-Path $evidenceRoot 'repair.receipt.json'
$backupRoot = Join-Path $micronDrive (
    'NLL\Backups\Phase3B2\EpinelTutorialNativeCacheWrapperCorrection-v2\' +
    $RevisionUid
)
$priorWrapperBackupPath = Join-Path $backupRoot `
    'Start-Phase3B2-Epinel-NativeCache.before-v2.ps1'
$rollbackPlanPath = Join-Path $backupRoot 'rollback.plan.json'
$protectedRevisionRoot = Join-Path $ProtectedRoot $RevisionUid
$protectedReceiptPath = Join-Path $protectedRevisionRoot `
    'repair.receipt.json'
$sqliteRuntimePaths = @(
    (Join-Path $runtimeRoot 'epinelps.db'),
    (Join-Path $runtimeRoot 'epinelps.db-shm'),
    (Join-Path $runtimeRoot 'epinelps.db-wal')
)

$inputSpecs = @(
    [pscustomobject]@{ Role='deployment'; Path=(Join-Path $physicalRoot 'epinel-native-cache-deployment-v1\deployment.receipt.json'); Length=3537L; Sha256=[string]$bindingValues['__NATIVE_CACHE_DEPLOYMENT_RECEIPT_SHA256__'] },
    [pscustomobject]@{ Role='verifier_manifest'; Path=$verifierManifestPath; Length=3285L; Sha256=[string]$bindingValues['__NATIVE_CACHE_VERIFIER_MANIFEST_SHA256__'] },
    [pscustomobject]@{ Role='verifier_dll'; Path=$verifierDllPath; Length=136704L; Sha256='11697a3d55259483a7f078a98c2fc7a3d04e7def1cfe0e65530c303b8f07243e' },
    [pscustomobject]@{ Role='header_closure'; Path=(Join-Path $physicalRoot 'epinel-native-cache-header-closure-v1\repair.receipt.json'); Length=2585L; Sha256=[string]$bindingValues['__NATIVE_CACHE_HEADER_CLOSURE_RECEIPT_SHA256__'] },
    [pscustomobject]@{ Role='transport_repair'; Path=(Join-Path $transportRoot 'repair.receipt.json'); Length=3382L; Sha256=$expectedTransportRepairSha256 },
    [pscustomobject]@{ Role='catalog_contract'; Path=(Join-Path $transportRoot 'catalog-transport.contract.json'); Length=3385L; Sha256=$expectedCatalogContractSha256 },
    [pscustomobject]@{ Role='saus_staging'; Path=(Join-Path $physicalRoot 'epinel-saus-pair-staging-v1\staging.receipt.json'); Length=2139L; Sha256=[string]$bindingValues['__EPINEL_SAUS_STAGING_RECEIPT_SHA256__'] },
    [pscustomobject]@{ Role='saus_contract'; Path=(Join-Path $physicalRoot 'epinel-saus-pair-staging-v1\saus-http-pair.contract.json'); Length=1197L; Sha256=[string]$bindingValues['__EPINEL_SAUS_CONTRACT_SHA256__'] },
    [pscustomobject]@{ Role='saus_binding'; Path=(Join-Path $physicalRoot 'epinel-saus-pair-staging-v1\tool-binding.receipt.json'); Length=740L; Sha256=[string]$bindingValues['__EPINEL_HISTORICAL_SAUS_TOOL_BINDING_SHA256__'] },
    [pscustomobject]@{ Role='tutorial_materialization'; Path=(Join-Path ($physicalRoot + '\epinel-tutorial-only-v1\' + $RevisionUid) 'materialization.receipt.json'); Length=3186L; Sha256=[string]$bindingValues['__EPINEL_TUTORIAL_MATERIALIZATION_RECEIPT_SHA256__'] },
    [pscustomobject]@{ Role='tutorial_binding'; Path=(Join-Path ($physicalRoot + '\epinel-tutorial-start-binding-v1\' + $RevisionUid) 'binding.receipt.json'); Length=1358L; Sha256=[string]$bindingValues['__EPINEL_TUTORIAL_START_BINDING_RECEIPT_SHA256__'] },
    [pscustomobject]@{ Role='prior_rebind'; Path=$priorRebindPath; Length=2176L; Sha256=$expectedPriorRebindReceiptSha256 },
    [pscustomobject]@{ Role='database'; Path=$databasePath; Length=416762L; Sha256=$expectedDatabaseSha256 },
    [pscustomobject]@{ Role='header'; Path=$headerPath; Length=139L; Sha256='5914cb58fd2146fe761ab531ecb4e321300527186a54b455e59de962ff6c044a' },
    [pscustomobject]@{ Role='inner_start'; Path=$activeInnerPath; Length=41649L; Sha256=$expectedInnerStartSha256 },
    [pscustomobject]@{ Role='server_dll'; Path=$serverDllPath; Length=15366144L; Sha256='aaa1e49d7a879a6b5ec17ad4c4094ce7d98ce86f860c1529a9ab4d6aecb51f7c' },
    [pscustomobject]@{ Role='prior_wrapper'; Path=$activeWrapperPath; Length=$expectedPriorWrapperLength; Sha256=$expectedPriorWrapperSha256 },
    [pscustomobject]@{ Role='dotnet'; Path=$dotnetPath; Length=167208L; Sha256='ab1b71fd3dd71062e074c9fab8312081a81b7f2b3e0327c48c4d249c8d1a3135' },
    [pscustomobject]@{ Role='hosts'; Path=$hostsPath; Length=1690L; Sha256='dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0' },
    [pscustomobject]@{ Role='template'; Path=$templatePath; Length=$expectedTemplateLength; Sha256=$expectedTemplateSha256 }
)

Assert-True (
    -not (Test-Path -LiteralPath $activePointerPath) -and
    @($sqliteRuntimePaths | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0 -and
    (Test-Path -LiteralPath $cacheRoot -PathType Container)
) 'phase3b2_tutorial_wrapper_correction_v2_runtime_state_invalid'
$inputAudit = @(
    foreach ($spec in $inputSpecs) {
        $exists = Test-Path -LiteralPath $spec.Path -PathType Leaf
        $observedLength = if ($exists) {
            (Get-Item -LiteralPath $spec.Path).Length
        } else { -1L }
        $observedSha256 = if ($exists) {
            Get-Sha256Hex $spec.Path
        } else { '' }
        [pscustomobject]@{
            role = $spec.Role
            exists = $exists
            expectedLength = [long]$spec.Length
            observedLength = [long]$observedLength
            expectedSha256 = [string]$spec.Sha256
            observedSha256 = [string]$observedSha256
            matched = $exists -and $observedLength -eq [long]$spec.Length -and
                $observedSha256 -ceq [string]$spec.Sha256
        }
    }
)
Assert-True (@($inputAudit | Where-Object { -not $_.matched }).Count -eq 0) `
    'phase3b2_tutorial_wrapper_correction_v2_required_input_audit_failed'

$transportRepair = Get-Content -LiteralPath `
    (Join-Path $transportRoot 'repair.receipt.json') -Raw -Encoding UTF8 |
    ConvertFrom-Json
$catalogContract = Get-Content -LiteralPath `
    (Join-Path $transportRoot 'catalog-transport.contract.json') -Raw `
    -Encoding UTF8 | ConvertFrom-Json
$priorRebind = Get-Content -LiteralPath $priorRebindPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
Assert-True (
    $transportRepair.contractId -ceq
        'nll/phase3b2-epinel-native-cache-catalog-transport-repair/v1' -and
    $transportRepair.catalogTransportContractSha256 -ceq
        $expectedCatalogContractSha256 -and
    $transportRepair.decryptedSqliteBodyCount -eq 3 -and
    $transportRepair.signatureMemberCount -eq 3 -and
    -not $transportRepair.rawDecryptedCatalogPersisted -and
    -not $transportRepair.serverExecutionStarted -and
    -not $transportRepair.clientExecutionStarted -and
    $catalogContract.contractId -ceq
        'nll/phase3b2-epinel-native-cache-catalog-transport-contract/v1' -and
    $catalogContract.memberCount -eq 3 -and
    @($catalogContract.members).Count -eq 3 -and
    -not $catalogContract.rawDecryptedCatalogPersisted -and
    $priorRebind.contractId -ceq
        'nll/phase3b2-epinel-tutorial-native-cache-rebind/v1' -and
    $priorRebind.revisionUid -ceq $RevisionUid -and
    $priorRebind.repairedWrapperToolSha256 -ceq
        $expectedPriorWrapperSha256 -and
    $priorRebind.databaseSha256 -ceq $expectedDatabaseSha256 -and
    $priorRebind.historicalSausEvidencePreserved -and
    $priorRebind.goldenBaselinePreserved -and
    -not $priorRebind.validationRunConsumed
) 'phase3b2_tutorial_wrapper_correction_v2_contract_audit_failed'

$verifierManifest = Get-Content -LiteralPath $verifierManifestPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
Assert-True (
    $verifierManifest.contractId -ceq
        'nll/phase3b2-native-cache-long-path-verifier-manifest/v1' -and
    $verifierManifest.memberCount -eq 8 -and
    @($verifierManifest.members).Count -eq 8
) 'phase3b2_tutorial_wrapper_correction_v2_verifier_manifest_invalid'
foreach ($member in @($verifierManifest.members)) {
    $memberPath = Join-Path $verifierRoot ([string]$member.relativePath)
    Assert-True (
        (Test-Path -LiteralPath $memberPath -PathType Leaf) -and
        (Get-Item -LiteralPath $memberPath).Length -eq
            [long]$member.byteLength -and
        (Get-Sha256Hex $memberPath) -ceq [string]$member.sha256
    ) 'phase3b2_tutorial_wrapper_correction_v2_verifier_member_invalid'
}
$inspectionOutput = & $dotnetPath $verifierDllPath `
    'inspect-cache-tree' $cacheRoot 2>&1
Assert-True ($LASTEXITCODE -eq 0) `
    'phase3b2_tutorial_wrapper_correction_v2_cache_inspection_failed'
$inspection = (($inspectionOutput | Out-String) | ConvertFrom-Json)
Assert-True (
    $inspection.contractId -ceq
        'nll/phase3b2-native-cache-tree-inspection/v1' -and
    $inspection.longPathSafeEnumerationUsed -and
    $inspection.fileCount -eq $expectedCacheFileCount -and
    [long]$inspection.contentByteLength -eq $expectedCacheByteLength -and
    $inspection.partialMemberCount -eq 0
) 'phase3b2_tutorial_wrapper_correction_v2_cache_shape_invalid'

$candidateText = Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8
foreach ($entry in $bindingValues.GetEnumerator()) {
    $count = ([regex]::Matches(
            $candidateText, [regex]::Escape([string]$entry.Key)
        )).Count
    Assert-True ($count -eq 1) `
        ('phase3b2_tutorial_wrapper_correction_v2_placeholder_invalid:' +
            [string]$entry.Key + ':' + $count)
    $candidateText = $candidateText.Replace(
        [string]$entry.Key, [string]$entry.Value
    )
}
Assert-True (-not ($candidateText -match '__[A-Z0-9_]+__')) `
    'phase3b2_tutorial_wrapper_correction_v2_unbound_placeholder'
$parseErrors = $null
[Management.Automation.Language.Parser]::ParseInput(
    $candidateText, [ref]$null, [ref]$parseErrors
) | Out-Null
Assert-True (@($parseErrors).Count -eq 0) `
    'phase3b2_tutorial_wrapper_correction_v2_candidate_parse_failed'
$candidateLength = [Text.UTF8Encoding]::new($false).GetByteCount(
    $candidateText
)
$candidateSha256 = Get-TextSha256Hex $candidateText
Assert-True (
    $candidateLength -eq $expectedCorrectedWrapperLength -and
    $candidateSha256 -ceq $expectedCorrectedWrapperSha256
) 'phase3b2_tutorial_wrapper_correction_v2_candidate_digest_invalid'

$audit = [ordered]@{
    schemaVersion = 1
    contractId =
        'nll/phase3b2-epinel-tutorial-native-cache-wrapper-correction-audit/v2'
    auditedAtUtc = [DateTimeOffset]::UtcNow.ToString(
        "yyyy-MM-dd'T'HH:mm:ss'Z'"
    )
    revisionUid = $RevisionUid
    requiredInputCount = $inputAudit.Count
    requiredInputMatchedCount = @($inputAudit | Where-Object matched).Count
    correctedTransportRepairReceiptSha256 = $expectedTransportRepairSha256
    correctedCatalogContractSha256 = $expectedCatalogContractSha256
    priorRebindReceiptSha256 = $expectedPriorRebindReceiptSha256
    priorWrapperToolSha256 = $expectedPriorWrapperSha256
    correctedWrapperToolByteLength = $candidateLength
    correctedWrapperToolSha256 = $candidateSha256
    databaseSha256 = $expectedDatabaseSha256
    activeCacheFileCount = [int]$inspection.fileCount
    activeCacheContentByteLength = [long]$inspection.contentByteLength
    activeCachePartialMemberCount = [int]$inspection.partialMemberCount
    runtimeCold = $true
    targetOsOffline = $true
    mutationPerformed = $false
    verdictCode = 'full_required_input_audit_and_candidate_verified'
}
if ($AuditOnly) {
    [pscustomobject]@{
        Audit = $audit
        InputAudit = $inputAudit
    } | ConvertTo-Json -Depth 7
    return
}

Assert-True (
    -not (Test-Path -LiteralPath $evidenceRoot) -and
    -not (Test-Path -LiteralPath $backupRoot) -and
    -not (Test-Path -LiteralPath $protectedRevisionRoot)
) 'phase3b2_tutorial_wrapper_correction_v2_destination_exists'

$wrapperReplaced = $false
$evidenceCreated = $false
$protectedCreated = $false
try {
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    Copy-Item -LiteralPath $activeWrapperPath `
        -Destination $priorWrapperBackupPath
    Assert-True ((Get-Sha256Hex $priorWrapperBackupPath) -ceq
        $expectedPriorWrapperSha256) `
        'phase3b2_tutorial_wrapper_correction_v2_backup_invalid'
    $rollbackPlan = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-tutorial-native-cache-wrapper-correction-rollback-plan/v2'
        revisionUid = $RevisionUid
        activeWrapperPath = $activeWrapperPath
        priorWrapperBackupPath = $priorWrapperBackupPath
        priorWrapperSha256 = $expectedPriorWrapperSha256
        correctedWrapperSha256 = $expectedCorrectedWrapperSha256
        rollbackCode = 'while_micron_offline_restore_prior_v1_wrapper_only'
    }
    Write-AtomicUtf8NoBom $rollbackPlanPath `
        (($rollbackPlan | ConvertTo-Json -Depth 5) + "`n")

    Write-AtomicUtf8NoBom $activeWrapperPath $candidateText
    $wrapperReplaced = $true
    Assert-True (
        (Get-Item -LiteralPath $activeWrapperPath).Length -eq
            $expectedCorrectedWrapperLength -and
        (Get-Sha256Hex $activeWrapperPath) -ceq
            $expectedCorrectedWrapperSha256 -and
        (Get-Sha256Hex $databasePath) -ceq $expectedDatabaseSha256 -and
        (Get-Sha256Hex $activeInnerPath) -ceq $expectedInnerStartSha256
    ) 'phase3b2_tutorial_wrapper_correction_v2_post_apply_invalid'

    New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null
    $evidenceCreated = $true
    $receipt = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-tutorial-native-cache-wrapper-correction/v2'
        correctedAtUtc = [DateTimeOffset]::UtcNow.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'"
        )
        revisionUid = $RevisionUid
        causeCode = 'two_precursor_sha256_values_misbound_in_v1_wrapper'
        priorRebindReceiptSha256 = $expectedPriorRebindReceiptSha256
        priorWrapperToolByteLength = $expectedPriorWrapperLength
        priorWrapperToolSha256 = $expectedPriorWrapperSha256
        correctedTransportRepairReceiptSha256 =
            $expectedTransportRepairSha256
        correctedCatalogContractSha256 = $expectedCatalogContractSha256
        correctedWrapperToolByteLength = $expectedCorrectedWrapperLength
        correctedWrapperToolSha256 = $expectedCorrectedWrapperSha256
        requiredInputCount = $inputAudit.Count
        requiredInputMatchedCount = @($inputAudit | Where-Object matched).Count
        fullRequiredInputAuditPassed = $true
        historicalEvidencePreserved = $true
        activeMinimalStartToolSha256 = $expectedInnerStartSha256
        databaseSha256 = $expectedDatabaseSha256
        activeCacheFileCount = [int]$inspection.fileCount
        activeCacheContentByteLength = [long]$inspection.contentByteLength
        activeCachePartialMemberCount = [int]$inspection.partialMemberCount
        cacheMutationPerformed = $false
        databaseMutationPerformed = $false
        serverBinaryMutationPerformed = $false
        activeInnerStartMutationPerformed = $false
        wrapperMutationPerformed = $true
        priorWrapperBackedUp = $true
        rollbackPlanByteLength =
            (Get-Item -LiteralPath $rollbackPlanPath).Length
        rollbackPlanSha256 = Get-Sha256Hex $rollbackPlanPath
        targetOsOfflineDuringCorrection = $true
        officialOutboundUsed = $false
        officialApiUsed = $false
        officialLoginUsed = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        validationRunConsumed = $false
        nextStepCode =
            'boot_micron_nlloperator_run_tutorial_validation_once_after_v2_review'
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
        'phase3b2_tutorial_wrapper_correction_v2_protected_copy_invalid'

    [pscustomobject]@{
        Receipt = $receipt
        Audit = $audit
        ReceiptPath = $repairReceiptPath
        ReceiptByteLength = (Get-Item -LiteralPath $repairReceiptPath).Length
        ReceiptSha256 = Get-Sha256Hex $repairReceiptPath
        ProtectedReceiptPath = $protectedReceiptPath
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
