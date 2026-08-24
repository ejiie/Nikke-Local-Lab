[CmdletBinding()]
param(
    [ValidatePattern('^[A-Z]$')]
    [string]$MicronDriveLetter = 'E',
    [string]$MaterializationRoot =
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\NativeCacheMaterialization-v2',
    [string]$BaselineAssessmentUid =
        '0f37da44-dc19-4f5e-b7a8-25556a9f52b3'
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

function Write-AtomicUtf8NoBom {
    param([string]$Path, [string]$Text)

    $temporary = $Path + '.partial-' + [Guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText(
        $temporary,
        $Text,
        [Text.UTF8Encoding]::new($false)
    )
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Get-RelativeCachePath {
    param([string]$Root, [string]$FullName)

    Assert-True (
        $FullName.StartsWith(
            $Root.TrimEnd('\') + '\',
            [StringComparison]::OrdinalIgnoreCase
        )
    ) 'phase3b2_native_cache_deployment_path_escape_detected'
    return $FullName.Substring($Root.TrimEnd('\').Length).
        TrimStart('\').Replace('\', '/')
}

function Test-SafeCacheRelativePath {
    param([string]$RelativePath)

    if ([string]::IsNullOrWhiteSpace($RelativePath)) { return $false }
    if ([IO.Path]::IsPathRooted($RelativePath)) { return $false }
    $segments = @($RelativePath.Replace('\', '/').Split('/'))
    return @($segments | Where-Object {
            $_ -eq '' -or $_ -eq '.' -or $_ -eq '..'
        }).Count -eq 0
}

function Invoke-RobocopyChecked {
    param([string]$Source, [string]$Destination)

    & "$env:SystemRoot\System32\robocopy.exe" `
        $Source $Destination /E /COPY:DAT /DCOPY:DAT /R:2 /W:1 `
        /MT:8 /NFL /NDL /NP /NJH /NJS | Out-Null
    $exitCode = $LASTEXITCODE
    Assert-True ($exitCode -lt 8) `
        'phase3b2_native_cache_deployment_robocopy_failed'
    return $exitCode
}

$expectedMaterializationReceiptSha256 =
    '89a76b1e5237ea3864d87303418e638d9ad7de0570ad456182568a17c5ead921'
$expectedPrivateManifestSha256 =
    'c1223ee05fec7cf3780171ead9a3e5da7f2942f129e0014995f10fabee0782a1'
$expectedMaterializationCanonicalSha256 =
    '95000d45cb52f4bdd81b6ca9caf7e2e13eeae7bbddfa67e33ed8ef8896f22ffe'
$expectedBaselineCacheCanonicalSha256 =
    '2f26e48f2243955d377a93bf4fcb6875b34d65aa0feb529eb2921801c3febf2e'
$expectedDatabaseSha256 =
    'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194'
$expectedHostsSha256 =
    'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0'
$expectedMaterializedMemberCount = 40103
$expectedMaterializedByteLength = 39007142815L
$expectedActiveCacheFileCount = 40108
$expectedActiveCacheByteLength = 39030629947L
$expectedBaselineCacheFileCount = 11
$expectedBaselineCacheByteLength = 43007317L

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
Assert-True (
    $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
) 'phase3b2_native_cache_deployment_requires_administrator'

$micronDrive = $MicronDriveLetter + ':'
$systemDisk = Get-Partition -DriveLetter C | Get-Disk
$micronDisk = Get-Partition -DriveLetter $MicronDriveLetter | Get-Disk
Assert-True (
    $env:SystemDrive -ceq 'C:' -and
    $systemDisk.FriendlyName -like 'Samsung SSD 980*' -and
    $micronDisk.FriendlyName -like 'Micron_2200*' -and
    (Test-Path -LiteralPath (Join-Path $micronDrive 'Windows\System32') `
        -PathType Container)
) 'phase3b2_native_cache_deployment_wrong_disk_boundary'
Assert-True (
    @(Get-Process -Name EpinelPS, nikke, nikke_launcher,
        NikkeLocalLab.Phase3B2.PhysicalBootstrap `
        -ErrorAction SilentlyContinue).Count -eq 0
) 'phase3b2_native_cache_deployment_runtime_not_cold'
Assert-True ((Get-PSDrive $MicronDriveLetter).Free -ge 45GB) `
    'phase3b2_native_cache_deployment_insufficient_micron_space'

$recoveryTool = Join-Path $PSScriptRoot `
    'recover-phase3b2-epinel-native-cache-baseline-offline.ps1'
$nativeStartTemplate = Join-Path $PSScriptRoot `
    'Start-Phase3B2-Epinel-NativeCache.ps1'
$rollbackTemplate = Join-Path $PSScriptRoot `
    'rollback-phase3b2-epinel-native-cache-offline.ps1'
$materializationReceiptPath = Join-Path $MaterializationRoot `
    'materialization.receipt.json'
$privateManifestPath = Join-Path $MaterializationRoot `
    'materialization.manifest.private.json'
$sourceCacheRoot = Join-Path $MaterializationRoot 'cache'
$protectedDeploymentRoot = Join-Path $MaterializationRoot `
    'MicronOfflineDeployment-v1'

$serverRoot = Join-Path $micronDrive `
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
$activeCacheRoot = Join-Path $serverRoot 'cache'
$databasePath = Join-Path $serverRoot 'db.json'
$sqlitePaths = @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal' |
    ForEach-Object { Join-Path $serverRoot $_ })
$hostsPath = Join-Path $micronDrive 'Windows\System32\drivers\etc\hosts'
$minimalEvidenceRoot = Join-Path $micronDrive `
    'NLL\Evidence\Phase3B2\Physical\epinel-minimal-reference-v1'
$activePointerPath = Join-Path $minimalEvidenceRoot 'active-run.pointer.json'
$baselineReceiptPath = Join-Path $micronDrive (
    'NLL\Evidence\Phase3B2\Physical\' +
    'epinel-native-cache-baseline-v1\' + $BaselineAssessmentUid +
    '\baseline-recovery.receipt.json'
)
$backupRoot = Join-Path $micronDrive `
    'NLL\Backups\Phase3B2\EpinelNativeCacheMaterialization-v1'
$backupCacheRoot = Join-Path $backupRoot 'cache-before'
$deploymentEvidenceRoot = Join-Path $micronDrive `
    'NLL\Evidence\Phase3B2\Physical\epinel-native-cache-deployment-v1'
$deploymentReceiptPath = Join-Path $deploymentEvidenceRoot `
    'deployment.receipt.json'
$toolReceiptPath = Join-Path $deploymentEvidenceRoot `
    'tool-binding.receipt.json'
$protectedDeploymentReceiptPath = Join-Path $protectedDeploymentRoot `
    'deployment.receipt.json'
$protectedToolReceiptPath = Join-Path $protectedDeploymentRoot `
    'tool-binding.receipt.json'
$stagingRoot = Join-Path $serverRoot (
    '.cache-native-materialization-staging-' +
    [Guid]::NewGuid().ToString('N')
)
$micronToolsRoot = Join-Path $micronDrive 'NLL\Tools'
$nativeStartDestination = Join-Path $micronToolsRoot `
    'Start-Phase3B2-Epinel-NativeCache.ps1'
$rollbackDestination = Join-Path $micronToolsRoot `
    'Rollback-Phase3B2-Epinel-NativeCache.ps1'

Assert-True (
    @(@($recoveryTool, $nativeStartTemplate, $rollbackTemplate,
            $materializationReceiptPath, $privateManifestPath) |
        Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) }
    ).Count -eq 0 -and
    (Test-Path -LiteralPath $sourceCacheRoot -PathType Container) -and
    (Test-Path -LiteralPath $activeCacheRoot -PathType Container) -and
    (Test-Path -LiteralPath $databasePath -PathType Leaf) -and
    (Test-Path -LiteralPath $hostsPath -PathType Leaf)
) 'phase3b2_native_cache_deployment_input_missing'
Assert-True (
    -not (Test-Path -LiteralPath $backupRoot) -and
    -not (Test-Path -LiteralPath $deploymentEvidenceRoot) -and
    -not (Test-Path -LiteralPath $protectedDeploymentRoot) -and
    -not (Test-Path -LiteralPath $stagingRoot)
) 'phase3b2_native_cache_deployment_destination_exists'

if (-not (Test-Path -LiteralPath $baselineReceiptPath -PathType Leaf)) {
    & $recoveryTool -MicronDriveLetter $MicronDriveLetter `
        -AssessmentUid $BaselineAssessmentUid | Out-Null
}
Assert-True (
    Test-Path -LiteralPath $baselineReceiptPath -PathType Leaf
) 'phase3b2_native_cache_deployment_baseline_recovery_missing'
$baselineReceipt = Get-Content -LiteralPath $baselineReceiptPath `
    -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True (
    $baselineReceipt.contractId -ceq `
        'nll/phase3b2-epinel-native-cache-baseline-offline-recovery/v1' -and
    $baselineReceipt.assessmentUid -ceq $BaselineAssessmentUid -and
    $baselineReceipt.databaseRestored -and
    $baselineReceipt.sqliteRuntimeRemoved -and
    $baselineReceipt.hostsRestored -and
    $baselineReceipt.activeRunPointerArchived -and
    $baselineReceipt.runtimeColdAtRecovery -and
    -not $baselineReceipt.retryAuthorized -and
    -not $baselineReceipt.clientExecutionStarted -and
    -not $baselineReceipt.serverExecutionStarted -and
    -not (Test-Path -LiteralPath $activePointerPath) -and
    @($sqlitePaths | Where-Object { Test-Path -LiteralPath $_ }).Count `
        -eq 0 -and
    (Get-Sha256Hex $databasePath) -ceq $expectedDatabaseSha256 -and
    (Get-Sha256Hex $hostsPath) -ceq $expectedHostsSha256
) 'phase3b2_native_cache_deployment_baseline_invalid'

Assert-True (
    (Get-Sha256Hex $materializationReceiptPath) -ceq `
        $expectedMaterializationReceiptSha256 -and
    (Get-Sha256Hex $privateManifestPath) -ceq `
        $expectedPrivateManifestSha256
) 'phase3b2_native_cache_deployment_materialization_digest_invalid'
$materializationReceipt = Get-Content -LiteralPath `
    $materializationReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
$privateManifest = Get-Content -LiteralPath $privateManifestPath `
    -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True (
    $materializationReceipt.contractId -ceq `
        'nll/phase3b2-native-cache-materialization/v1' -and
    $materializationReceipt.verdictCode -ceq `
        'exact_epinel_native_cache_materialized_and_sealed' -and
    $materializationReceipt.materializedMemberCount -eq `
        $expectedMaterializedMemberCount -and
    [long]$materializationReceipt.totalContentByteLength -eq `
        $expectedMaterializedByteLength -and
    $materializationReceipt.canonicalSha256 -ceq `
        $expectedMaterializationCanonicalSha256 -and
    -not $materializationReceipt.micronMutationPerformed -and
    $privateManifest.contractId -ceq `
        'nll/phase3b2-native-cache-materialization-private-manifest/v1' -and
    $privateManifest.memberCount -eq $expectedMaterializedMemberCount -and
    [long]$privateManifest.totalContentByteLength -eq `
        $expectedMaterializedByteLength -and
    @($privateManifest.members).Count -eq `
        $expectedMaterializedMemberCount
) 'phase3b2_native_cache_deployment_materialization_contract_invalid'

$baselineFiles = @(Get-ChildItem -LiteralPath $activeCacheRoot -File -Recurse)
$baselineLines = foreach ($file in $baselineFiles) {
    $relative = Get-RelativeCachePath $activeCacheRoot $file.FullName
    "$relative`t$($file.Length)`t$(Get-Sha256Hex $file.FullName)"
}
$baselineCanonicalText = (@($baselineLines | Sort-Object) -join "`n") + "`n"
Assert-True (
    $baselineFiles.Count -eq $expectedBaselineCacheFileCount -and
    [long](($baselineFiles | Measure-Object Length -Sum).Sum) -eq `
        $expectedBaselineCacheByteLength -and
    (Get-TextSha256Hex $baselineCanonicalText) -ceq `
        $expectedBaselineCacheCanonicalSha256
) 'phase3b2_native_cache_deployment_baseline_cache_invalid'

$materializedPaths = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
foreach ($member in @($privateManifest.members)) {
    $relative = [string]$member.cacheRelativePath
    Assert-True (
        (Test-SafeCacheRelativePath $relative) -and
        $materializedPaths.Add($relative)
    ) 'phase3b2_native_cache_deployment_manifest_path_invalid'
}

$stagingCreated = $false
$baselineMoved = $false
$activeInstalled = $false
$createdEvidence = $false
$createdProtectedEvidence = $false
try {
    New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
    $stagingCreated = $true
    $baselineRobocopyExitCode = Invoke-RobocopyChecked `
        $activeCacheRoot $stagingRoot
    $materializationRobocopyExitCode = Invoke-RobocopyChecked `
        $sourceCacheRoot $stagingRoot

    $stagedFiles = @(Get-ChildItem -LiteralPath $stagingRoot -File -Recurse)
    Assert-True (
        $stagedFiles.Count -eq $expectedActiveCacheFileCount -and
        [long](($stagedFiles | Measure-Object Length -Sum).Sum) -eq `
            $expectedActiveCacheByteLength
    ) 'phase3b2_native_cache_deployment_staged_shape_invalid'

    $activeCanonicalLines = [Collections.Generic.List[string]]::new()
    foreach ($member in @($privateManifest.members)) {
        $relative = [string]$member.cacheRelativePath
        $target = Join-Path $stagingRoot $relative.Replace('/', '\')
        Assert-True (
            (Test-Path -LiteralPath $target -PathType Leaf) -and
            (Get-Item -LiteralPath $target).Length -eq `
                [long]$member.declaredByteLength
        ) 'phase3b2_native_cache_deployment_staged_member_shape_invalid'
        $sha256 = Get-Sha256Hex $target
        Assert-True ($sha256 -ceq [string]$member.contentSha256) `
            'phase3b2_native_cache_deployment_staged_member_digest_invalid'
        $activeCanonicalLines.Add(
            "$relative`t$([long]$member.declaredByteLength)`t$sha256"
        )
    }
    foreach ($file in $baselineFiles) {
        $relative = Get-RelativeCachePath $activeCacheRoot $file.FullName
        if (-not $materializedPaths.Contains($relative)) {
            $target = Join-Path $stagingRoot $relative.Replace('/', '\')
            $sha256 = Get-Sha256Hex $target
            Assert-True (
                (Get-Item -LiteralPath $target).Length -eq $file.Length -and
                $sha256 -ceq (Get-Sha256Hex $file.FullName)
            ) 'phase3b2_native_cache_deployment_baseline_member_drifted'
            $activeCanonicalLines.Add(
                "$relative`t$($file.Length)`t$sha256"
            )
        }
    }
    Assert-True (
        $activeCanonicalLines.Count -eq $expectedActiveCacheFileCount
    ) 'phase3b2_native_cache_deployment_active_manifest_count_invalid'
    $activeCanonicalText = (
        @($activeCanonicalLines | Sort-Object) -join "`n"
    ) + "`n"
    $activeCanonicalSha256 = Get-TextSha256Hex $activeCanonicalText

    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    Move-Item -LiteralPath $activeCacheRoot -Destination $backupCacheRoot
    $baselineMoved = $true
    Move-Item -LiteralPath $stagingRoot -Destination $activeCacheRoot
    $stagingCreated = $false
    $activeInstalled = $true

    $activeFiles = @(Get-ChildItem -LiteralPath $activeCacheRoot `
        -File -Recurse)
    Assert-True (
        $activeFiles.Count -eq $expectedActiveCacheFileCount -and
        [long](($activeFiles | Measure-Object Length -Sum).Sum) -eq `
            $expectedActiveCacheByteLength -and
        @($activeFiles | Where-Object {
                $_.Name -like '*.partial-*'
            }).Count -eq 0
    ) 'phase3b2_native_cache_deployment_post_swap_shape_invalid'

    New-Item -ItemType Directory -Path $deploymentEvidenceRoot -Force |
        Out-Null
    $createdEvidence = $true
    New-Item -ItemType Directory -Path $protectedDeploymentRoot -Force |
        Out-Null
    $createdProtectedEvidence = $true

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = `
            'nll/phase3b2-epinel-native-cache-offline-deployment/v1'
        deployedAtUtc = [DateTimeOffset]::UtcNow.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'"
        )
        deploymentUid = [Guid]::NewGuid().ToString()
        environmentCode = 'samsung_boot_micron_offline_runtime_cold'
        baselineAssessmentUid = $BaselineAssessmentUid
        baselineRecoveryReceiptByteLength = `
            (Get-Item $baselineReceiptPath).Length
        baselineRecoveryReceiptSha256 = Get-Sha256Hex $baselineReceiptPath
        materializationAssessmentUid = `
            [string]$materializationReceipt.assessmentUid
        materializationReceiptByteLength = `
            (Get-Item $materializationReceiptPath).Length
        materializationReceiptSha256 = `
            $expectedMaterializationReceiptSha256
        materializationPrivateManifestByteLength = `
            (Get-Item $privateManifestPath).Length
        materializationPrivateManifestSha256 = `
            $expectedPrivateManifestSha256
        materializationCanonicalSha256 = `
            $expectedMaterializationCanonicalSha256
        catalogEntryDataCount = 40281
        remoteMaterializationMemberCount = 40097
        nonRemoteEntryDataCount = 184
        fixedCatalogMemberCount = 6
        materializedMemberCount = $expectedMaterializedMemberCount
        materializedContentByteLength = $expectedMaterializedByteLength
        baselineCacheFileCount = $expectedBaselineCacheFileCount
        baselineCacheContentByteLength = $expectedBaselineCacheByteLength
        baselineCacheCanonicalSha256 = `
            $expectedBaselineCacheCanonicalSha256
        overlappingCatalogMemberCount = 6
        activeCacheFileCount = $expectedActiveCacheFileCount
        activeCacheContentByteLength = $expectedActiveCacheByteLength
        activeCacheCanonicalSha256 = $activeCanonicalSha256
        backupCacheFileCount = $expectedBaselineCacheFileCount
        backupCacheContentByteLength = $expectedBaselineCacheByteLength
        backupCacheCanonicalSha256 = `
            $expectedBaselineCacheCanonicalSha256
        baselineRobocopyExitCode = $baselineRobocopyExitCode
        materializationRobocopyExitCode = `
            $materializationRobocopyExitCode
        targetCachePathAtMicronBoot = `
            'C:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\cache'
        databaseRestored = $true
        sqliteRuntimeRemoved = $true
        hostsRestored = $true
        activeRunPointerArchived = $true
        nativeCacheDeploymentVerified = $true
        targetOsOfflineDuringDeployment = $true
        existingOperatorCacheInspected = $false
        existingOperatorCacheModified = $false
        officialStaticAssetCdnUsedDuringDeployment = $false
        officialApiUsed = $false
        officialLoginUsed = $false
        officialIdentityPersisted = $false
        officialCredentialPersisted = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        rollbackCode = 'directory_swap_restore_cache_before'
        nextStepCode = `
            'boot_micron_nlloperator_run_epinel_native_cache_once'
    }
    $receiptText = ($receipt | ConvertTo-Json -Depth 7) + "`n"
    Write-AtomicUtf8NoBom $deploymentReceiptPath $receiptText
    $deploymentReceiptSha256 = Get-Sha256Hex $deploymentReceiptPath
    Copy-Item -LiteralPath $deploymentReceiptPath `
        -Destination $protectedDeploymentReceiptPath

    $templateText = Get-Content -LiteralPath $nativeStartTemplate `
        -Raw -Encoding UTF8
    $placeholder = '__NATIVE_CACHE_DEPLOYMENT_RECEIPT_SHA256__'
    Assert-True (
        ([regex]::Matches(
            $templateText,
            [regex]::Escape($placeholder)
        )).Count -eq 1
    ) 'phase3b2_native_cache_deployment_wrapper_template_invalid'
    $boundStartText = $templateText.Replace(
        $placeholder,
        $deploymentReceiptSha256
    )
    Write-AtomicUtf8NoBom $nativeStartDestination $boundStartText
    Copy-Item -LiteralPath $rollbackTemplate `
        -Destination $rollbackDestination

    $tokens = $null
    $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseFile(
        $nativeStartDestination,
        [ref]$tokens,
        [ref]$parseErrors
    ) | Out-Null
    Assert-True (@($parseErrors).Count -eq 0) `
        'phase3b2_native_cache_deployment_bound_wrapper_parse_failed'

    $toolReceipt = [ordered]@{
        schemaVersion = 1
        contractId = `
            'nll/phase3b2-epinel-native-cache-tool-binding/v1'
        boundAtUtc = [DateTimeOffset]::UtcNow.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'"
        )
        deploymentReceiptByteLength = `
            (Get-Item $deploymentReceiptPath).Length
        deploymentReceiptSha256 = $deploymentReceiptSha256
        trackedStartTemplateByteLength = `
            (Get-Item $nativeStartTemplate).Length
        trackedStartTemplateSha256 = Get-Sha256Hex $nativeStartTemplate
        boundStartToolByteLength = `
            (Get-Item $nativeStartDestination).Length
        boundStartToolSha256 = Get-Sha256Hex $nativeStartDestination
        rollbackToolByteLength = (Get-Item $rollbackDestination).Length
        rollbackToolSha256 = Get-Sha256Hex $rollbackDestination
        deploymentReceiptHashBoundExactlyOnce = $true
        targetOsOfflineDuringToolBinding = $true
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        nextStepCode = `
            'boot_micron_nlloperator_run_epinel_native_cache_once'
    }
    $toolReceiptText = ($toolReceipt | ConvertTo-Json -Depth 6) + "`n"
    Write-AtomicUtf8NoBom $toolReceiptPath $toolReceiptText
    Copy-Item -LiteralPath $toolReceiptPath `
        -Destination $protectedToolReceiptPath

    [pscustomobject]@{
        Receipt = $receipt
        DeploymentReceiptPath = $deploymentReceiptPath
        DeploymentReceiptByteLength = `
            (Get-Item $deploymentReceiptPath).Length
        DeploymentReceiptSha256 = $deploymentReceiptSha256
        ToolBindingReceiptPath = $toolReceiptPath
        ToolBindingReceiptByteLength = (Get-Item $toolReceiptPath).Length
        ToolBindingReceiptSha256 = Get-Sha256Hex $toolReceiptPath
        MicronStartCommand = `
            "& 'C:\NLL\Tools\Start-Phase3B2-Epinel-NativeCache.ps1'"
    } | ConvertTo-Json -Depth 9
}
catch {
    if ($activeInstalled -and
        (Test-Path -LiteralPath $activeCacheRoot -PathType Container) -and
        (Test-Path -LiteralPath $backupCacheRoot -PathType Container)) {
        $failedCacheRoot = Join-Path $backupRoot (
            'cache-failed-deployment-' +
            [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssZ')
        )
        Move-Item -LiteralPath $activeCacheRoot `
            -Destination $failedCacheRoot
        Move-Item -LiteralPath $backupCacheRoot `
            -Destination $activeCacheRoot
    }
    elseif ($baselineMoved -and
        -not (Test-Path -LiteralPath $activeCacheRoot) -and
        (Test-Path -LiteralPath $backupCacheRoot -PathType Container)) {
        Move-Item -LiteralPath $backupCacheRoot `
            -Destination $activeCacheRoot
    }
    if ($stagingCreated -and
        (Test-Path -LiteralPath $stagingRoot -PathType Container)) {
        $failedStagingRoot = Join-Path $backupRoot (
            'staging-failed-' +
            [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssZ')
        )
        New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
        Move-Item -LiteralPath $stagingRoot `
            -Destination $failedStagingRoot
    }
    foreach ($path in @(
            $nativeStartDestination,
            $rollbackDestination,
            $toolReceiptPath,
            $deploymentReceiptPath,
            $protectedToolReceiptPath,
            $protectedDeploymentReceiptPath
        )) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force
        }
    }
    if ($createdEvidence -and
        (Test-Path -LiteralPath $deploymentEvidenceRoot `
            -PathType Container) -and
        @(Get-ChildItem -LiteralPath $deploymentEvidenceRoot -Force).Count `
            -eq 0) {
        Remove-Item -LiteralPath $deploymentEvidenceRoot -Force
    }
    if ($createdProtectedEvidence -and
        (Test-Path -LiteralPath $protectedDeploymentRoot `
            -PathType Container) -and
        @(Get-ChildItem -LiteralPath $protectedDeploymentRoot -Force).Count `
            -eq 0) {
        Remove-Item -LiteralPath $protectedDeploymentRoot -Force
    }
    throw
}
