param(
    [string]$MicronDrive = 'E:',
    [string]$ExternalRepositoryRoot = (
        Join-Path $PSScriptRoot '..\.external\EpinelPS'
    ),
    [string]$BuildEvidenceRoot = (
        Join-Path $env:LOCALAPPDATA `
            'NikkeLocalLab\Evidence\Phase3B2\Physical\EpinelMinimalBuild-v3'
    ),
    [string]$SamsungOutputRoot = (
        Join-Path $env:LOCALAPPDATA `
            'NikkeLocalLab\Evidence\Phase3B2\Physical\EpinelMinimalSamplingLogRepair-v1'
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
    finally { $algorithm.Dispose() }
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText(
        $Path, $Text, [Text.UTF8Encoding]::new($false)
    )
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
                    -not $relative.StartsWith(
                        'logs/', [StringComparison]::OrdinalIgnoreCase
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
        Text = $text
        Bytes = $bytes
        Sha256 = Get-BytesSha256Hex $bytes
        ContentByteLength = [long](
            ($files | Measure-Object Length -Sum).Sum
        )
    }
}

function Test-ExclusiveReadAccess {
    param([string]$Path)
    $stream = $null
    try {
        $stream = [IO.File]::Open(
            $Path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
            [IO.FileShare]::None
        )
        return $true
    }
    catch { return $false }
    finally { if ($null -ne $stream) { $stream.Dispose() } }
}

$expectedBuildReceiptSha256 = `
    '9fc554705e3d9778bf0d56e2bd5ea8399909bb8acf53ae39ba61668cd02af98d'
$expectedBuildManifestSha256 = `
    '44a5d022389d21138c79b7003173581ec5ddb0b4c7126cd4c52778f31f554e39'
$expectedFailureRecoverySha256 = `
    '4b37cac89e123351a25ba9f705cc6a3ddbecd488ef627f49e27a004bc20bf8e1'
$expectedPriorDeploymentSha256 = `
    '101a43a90791bf79f62ac661f35802ed53261cda37d22d7d68b6d4bff487befa'
$expectedPriorPreflightSha256 = `
    'f6699da26a55c95ab0d5ed250930910896b098b245907ac73d852fd700f36b0a'
$expectedPriorExeSha256 = `
    'f7aa2dc342e93157b620408b887603f62188c8d4a3ad75e94ab3b5b76547bc2d'
$expectedPriorDllSha256 = `
    '25b7251f860518418ae8f50c59c311f25cf3a2615ded34a12f07ab845168bb38'
$expectedAppliedExeSha256 = `
    'a28c7ff227a74d260a29389b82caeed3fe196f91eef3d28cabe9977b5ed9d07b'
$expectedAppliedDllSha256 = `
    'ba46ae42b59c2058c7c8e5b02e31af1fe32a28e70d685f3a470e63adefc60cfc'
$expectedDatabaseSha256 = `
    'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194'
$expectedCacheManifestSha256 = `
    '2f26e48f2243955d377a93bf4fcb6875b34d65aa0feb529eb2921801c3febf2e'

Assert-True ($env:SystemDrive -ceq 'C:') `
    'phase3b2_epinel_minimal_sampling_log_repair_wrong_boot_boundary'

$serverBuildRoot = Join-Path $ExternalRepositoryRoot `
    'EpinelPS\bin\Release\net10.0\win-x64'
$serverRoot = Join-Path $MicronDrive `
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
$buildReceiptPath = Join-Path $BuildEvidenceRoot 'build.receipt.json'
$buildManifestPath = Join-Path $BuildEvidenceRoot 'publish.manifest.tsv'
$priorDeploymentPath = Join-Path $MicronDrive `
    'NLL\Evidence\Phase3B2\Physical\epinel-minimal-deployment-v1\deployment.receipt.json'
$priorPreflightPath = Join-Path $MicronDrive `
    'NLL\Evidence\Phase3B2\Physical\epinel-minimal-preflight-v1\preflight.receipt.json'
$failureRecoveryPath = Join-Path $MicronDrive `
    'NLL\Evidence\Phase3B2\Physical\epinel-minimal-reference-v1\eae0f37c-6939-446f-93f6-d88c1c447311\offline-recovery.receipt.json'
$activePointerPath = Join-Path $MicronDrive `
    'NLL\Evidence\Phase3B2\Physical\epinel-minimal-reference-v1\active-run.pointer.json'
$micronOutputRoot = Join-Path $MicronDrive `
    'NLL\Evidence\Phase3B2\Physical\epinel-minimal-sampling-log-repair-v1'
$backupRoot = Join-Path $MicronDrive `
    'NLL\Backups\Phase3B2\EpinelMinimalSamplingLogRepair-v1'
$serverRootBefore = Join-Path $backupRoot 'server-root-before'
$toolsBefore = Join-Path $backupRoot 'tools-before'
$partialRoot = Join-Path $MicronDrive (
    'NLL\Staging\Phase3B2\.EpinelMinimalSamplingLogRepair-v1.partial-' +
    [Guid]::NewGuid().ToString('N')
)
$dbPath = Join-Path $serverRoot 'db.json'
$cacheRoot = Join-Path $serverRoot 'cache'
$startSourcePath = Join-Path $PSScriptRoot `
    'start-phase3b2-epinel-minimal-reference-in-micron.ps1'
$completeSourcePath = Join-Path $PSScriptRoot `
    'complete-phase3b2-epinel-minimal-reference-in-micron.ps1'
$startTargetPath = Join-Path $MicronDrive `
    'NLL\Tools\start-phase3b2-epinel-minimal-reference-in-micron.ps1'
$completeTargetPath = Join-Path $MicronDrive `
    'NLL\Tools\complete-phase3b2-epinel-minimal-reference-in-micron.ps1'
$rollbackSourcePath = Join-Path $PSScriptRoot `
    'rollback-phase3b2-epinel-minimal-sampling-and-log-in-micron.ps1'
$rollbackTargetPath = Join-Path $MicronDrive `
    'NLL\Tools\rollback-phase3b2-epinel-minimal-sampling-and-log-in-micron.ps1'

$requiredFiles = @(
    $buildReceiptPath, $buildManifestPath, $priorDeploymentPath,
    $priorPreflightPath, $failureRecoveryPath, $dbPath,
    (Join-Path $serverRoot 'EpinelPS.exe'),
    (Join-Path $serverRoot 'EpinelPS.dll'), $startSourcePath,
    $completeSourcePath, $startTargetPath, $completeTargetPath,
    $rollbackSourcePath
)
Assert-True (
    (Test-Path -LiteralPath (Join-Path $MicronDrive 'Windows\System32') `
        -PathType Container) -and
    @($requiredFiles | Where-Object {
        -not (Test-Path -LiteralPath $_ -PathType Leaf)
    }).Count -eq 0 -and
    -not (Test-Path -LiteralPath $activePointerPath) -and
    -not (Test-Path -LiteralPath $micronOutputRoot) -and
    -not (Test-Path -LiteralPath $backupRoot) -and
    -not (Test-Path -LiteralPath $SamsungOutputRoot) -and
    -not (Test-Path -LiteralPath $partialRoot) -and
    @(Get-Process -Name EpinelPS, nikke, nikke_launcher,
        NikkeLocalLab.Phase3B2.PhysicalBootstrap `
        -ErrorAction SilentlyContinue).Count -eq 0
) 'phase3b2_epinel_minimal_sampling_log_repair_input_invalid'

Assert-True (
    (Get-Sha256Hex $buildReceiptPath) -ceq `
        $expectedBuildReceiptSha256 -and
    (Get-Sha256Hex $buildManifestPath) -ceq `
        $expectedBuildManifestSha256 -and
    (Get-Sha256Hex $failureRecoveryPath) -ceq `
        $expectedFailureRecoverySha256 -and
    (Get-Sha256Hex $priorDeploymentPath) -ceq `
        $expectedPriorDeploymentSha256 -and
    (Get-Sha256Hex $priorPreflightPath) -ceq `
        $expectedPriorPreflightSha256 -and
    (Get-Sha256Hex (Join-Path $serverRoot 'EpinelPS.exe')) -ceq `
        $expectedPriorExeSha256 -and
    (Get-Sha256Hex (Join-Path $serverRoot 'EpinelPS.dll')) -ceq `
        $expectedPriorDllSha256 -and
    (Get-Sha256Hex $dbPath) -ceq $expectedDatabaseSha256 -and
    (Test-ExclusiveReadAccess $dbPath) -and
    @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal' |
        Where-Object { Test-Path -LiteralPath (Join-Path $serverRoot $_) }
    ).Count -eq 0
) 'phase3b2_epinel_minimal_sampling_log_repair_digest_or_cold_invalid'

$buildReceipt = Get-Content -LiteralPath $buildReceiptPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
$failureRecovery = Get-Content -LiteralPath $failureRecoveryPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
Assert-True (
    $buildReceipt.contractId -ceq `
        'nll/phase3b2-epinel-minimal-build/v3' -and
    $buildReceipt.checkoutClean -and
    -not $buildReceipt.localAuthTokenLoggingEnabled -and
    $buildReceipt.buildFileCount -eq 577 -and
    $failureRecovery.contractId -ceq `
        'nll/phase3b2-epinel-minimal-sampling-failure-recovery/v1' -and
    $failureRecovery.correctedClassificationCode -ceq `
        'healthy_runtime_false_negative_due_to_fixed_sample_count' -and
    -not $failureRecovery.rawSensitiveServerLogPersisted -and
    $failureRecovery.databaseRestored -and
    $failureRecovery.sqliteRuntimeRemoved
) 'phase3b2_epinel_minimal_sampling_log_repair_contract_invalid'

$sourceManifest = Get-ManifestResult -Root $serverBuildRoot `
    -ExcludeRuntimeState
$cacheManifest = Get-ManifestResult -Root $cacheRoot
Assert-True (
    $sourceManifest.Files.Count -eq 577 -and
    $sourceManifest.ContentByteLength -eq 193938021L -and
    $sourceManifest.Sha256 -ceq $expectedBuildManifestSha256 -and
    (Get-Sha256Hex (Join-Path $serverBuildRoot 'EpinelPS.exe')) -ceq `
        $expectedAppliedExeSha256 -and
    (Get-Sha256Hex (Join-Path $serverBuildRoot 'EpinelPS.dll')) -ceq `
        $expectedAppliedDllSha256 -and
    $cacheManifest.Files.Count -eq 11 -and
    $cacheManifest.Sha256 -ceq $expectedCacheManifestSha256
) 'phase3b2_epinel_minimal_sampling_log_repair_source_invalid'

New-Item -ItemType Directory -Path $partialRoot -Force | Out-Null
$oldRootMoved = $false
$newRootPlaced = $false
try {
    $sourcePrefix = [IO.Path]::GetFullPath($serverBuildRoot).TrimEnd('\') + '\'
    foreach ($sourceFile in $sourceManifest.Files) {
        $relative = $sourceFile.FullName.Substring($sourcePrefix.Length)
        $destination = Join-Path $partialRoot $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) `
            -Force | Out-Null
        Copy-Item -LiteralPath $sourceFile.FullName -Destination $destination
    }
    Copy-Item -LiteralPath $cacheRoot -Destination `
        (Join-Path $partialRoot 'cache') -Recurse
    Copy-Item -LiteralPath $dbPath -Destination `
        (Join-Path $partialRoot 'db.json')

    $stagedManifest = Get-ManifestResult -Root $partialRoot `
        -ExcludeRuntimeState
    $stagedCache = Get-ManifestResult -Root (Join-Path $partialRoot 'cache')
    Assert-True (
        $stagedManifest.Files.Count -eq 577 -and
        $stagedManifest.Sha256 -ceq $expectedBuildManifestSha256 -and
        $stagedCache.Sha256 -ceq $expectedCacheManifestSha256 -and
        (Get-Sha256Hex (Join-Path $partialRoot 'db.json')) -ceq `
            $expectedDatabaseSha256
    ) 'phase3b2_epinel_minimal_sampling_log_repair_staging_drift'

    New-Item -ItemType Directory -Path $backupRoot, $toolsBefore -Force |
        Out-Null
    Copy-Item -LiteralPath $startTargetPath -Destination $toolsBefore
    Copy-Item -LiteralPath $completeTargetPath -Destination $toolsBefore
    Move-Item -LiteralPath $serverRoot -Destination $serverRootBefore
    $oldRootMoved = $true
    Move-Item -LiteralPath $partialRoot -Destination $serverRoot
    $newRootPlaced = $true

    Copy-Item -LiteralPath $startSourcePath -Destination $startTargetPath `
        -Force
    Copy-Item -LiteralPath $completeSourcePath -Destination `
        $completeTargetPath -Force
    Copy-Item -LiteralPath $rollbackSourcePath -Destination `
        $rollbackTargetPath -Force

    $deployedManifest = Get-ManifestResult -Root $serverRoot `
        -ExcludeRuntimeState
    $deployedCache = Get-ManifestResult -Root (Join-Path $serverRoot 'cache')
    Assert-True (
        $deployedManifest.Files.Count -eq 577 -and
        $deployedManifest.Sha256 -ceq $expectedBuildManifestSha256 -and
        $deployedCache.Sha256 -ceq $expectedCacheManifestSha256 -and
        (Get-Sha256Hex (Join-Path $serverRoot 'db.json')) -ceq `
            $expectedDatabaseSha256 -and
        (Get-Sha256Hex $startTargetPath) -ceq `
            (Get-Sha256Hex $startSourcePath) -and
        (Get-Sha256Hex $completeTargetPath) -ceq `
            (Get-Sha256Hex $completeSourcePath)
    ) 'phase3b2_epinel_minimal_sampling_log_repair_post_apply_drift'

    New-Item -ItemType Directory -Path $micronOutputRoot, `
        $SamsungOutputRoot -Force | Out-Null
    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = `
            'nll/phase3b2-epinel-minimal-sampling-log-repair/v1'
        repairedAtUtc = [DateTimeOffset]::UtcNow.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'"
        )
        failedAssessmentUid = [string]$failureRecovery.assessmentUid
        failureRecoveryReceiptSha256 = $expectedFailureRecoverySha256
        correctedClassificationCode = `
            'healthy_runtime_false_negative_due_to_fixed_sample_count'
        samplingContractCode = `
            'minimum_ten_samples_and_twenty_eight_seconds'
        minimumAcceptedSampleCount = 10
        minimumAcceptedElapsedMilliseconds = 28000
        externalHead = [string]$buildReceipt.externalHead
        externalTree = [string]$buildReceipt.externalTree
        buildReceiptSha256 = $expectedBuildReceiptSha256
        buildFileCount = $deployedManifest.Files.Count
        buildContentByteLength = $deployedManifest.ContentByteLength
        buildManifestSha256 = $deployedManifest.Sha256
        priorServerExeSha256 = $expectedPriorExeSha256
        priorServerDllSha256 = $expectedPriorDllSha256
        appliedServerExeSha256 = $expectedAppliedExeSha256
        appliedServerDllSha256 = $expectedAppliedDllSha256
        localAuthTokenLoggingEnabled = $false
        serverLogDefenseInDepthRedactionEnabled = $true
        rawSensitiveServerLogPersisted = $false
        databaseBaselineSha256 = $expectedDatabaseSha256
        cacheMemberCount = $deployedCache.Files.Count
        cacheManifestSha256 = $deployedCache.Sha256
        priorServerRootPreserved = $true
        priorStartToolPreserved = $true
        priorCompletionToolPreserved = $true
        startToolByteLength = (Get-Item -LiteralPath $startTargetPath).Length
        startToolSha256 = Get-Sha256Hex $startTargetPath
        completionToolByteLength = (
            Get-Item -LiteralPath $completeTargetPath
        ).Length
        completionToolSha256 = Get-Sha256Hex $completeTargetPath
        rollbackToolSha256 = Get-Sha256Hex $rollbackTargetPath
        deploymentApplied = $true
        targetOsOfflineDuringRepair = $true
        officialOutboundUsed = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        nextStepCode = 'pin_repair_receipt_in_runtime_tools_then_retry_once'
    }
    $receiptText = ($receipt | ConvertTo-Json -Depth 7) + "`n"
    $micronReceiptPath = Join-Path $micronOutputRoot 'repair.receipt.json'
    $samsungReceiptPath = Join-Path $SamsungOutputRoot `
        'repair.receipt.json'
    Write-Utf8NoBom $micronReceiptPath $receiptText
    Write-Utf8NoBom $samsungReceiptPath $receiptText

    [pscustomobject]@{
        Receipt = $receipt
        MicronReceiptPath = $micronReceiptPath
        MicronReceiptSha256 = Get-Sha256Hex $micronReceiptPath
        SamsungReceiptPath = $samsungReceiptPath
        SamsungReceiptSha256 = Get-Sha256Hex $samsungReceiptPath
    } | ConvertTo-Json -Depth 8
}
catch {
    if ($newRootPlaced -and (Test-Path -LiteralPath $serverRoot)) {
        $failedRoot = Join-Path $backupRoot `
            'failed-new-server-root-before-automatic-rollback'
        if (-not (Test-Path -LiteralPath $failedRoot)) {
            Move-Item -LiteralPath $serverRoot -Destination $failedRoot
        }
    }
    if ($oldRootMoved -and (Test-Path -LiteralPath $serverRootBefore) -and
        -not (Test-Path -LiteralPath $serverRoot)) {
        Move-Item -LiteralPath $serverRootBefore -Destination $serverRoot
    }
    if (Test-Path -LiteralPath $partialRoot) {
        Remove-Item -LiteralPath $partialRoot -Recurse -Force
    }
    throw
}
