param(
    [string]$MicronDrive = 'E:',
    [string]$ExternalRepositoryRoot = (
        Join-Path $PSScriptRoot '..\.external\EpinelPS'
    ),
    [string]$ServerBuildRoot = (
        Join-Path $PSScriptRoot `
            '..\.external\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
    ),
    [string]$BuildEvidenceRoot = (
        Join-Path $env:LOCALAPPDATA `
            'NikkeLocalLab\Evidence\Phase3B2\Physical\EpinelMinimalBuild-v2'
    ),
    [string]$RecoveryEvidenceRoot = (
        Join-Path $env:LOCALAPPDATA `
            'NikkeLocalLab\Evidence\Phase3B2\Physical\EpinelMinimalRecovery-v1'
    ),
    [string]$SamsungOutputRoot = (
        Join-Path $env:LOCALAPPDATA `
            'NikkeLocalLab\Evidence\Phase3B2\Physical\EpinelMinimalDeployment-v1'
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

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
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
        Text = $text
        Bytes = $bytes
        Sha256 = Get-BytesSha256Hex $bytes
        ContentByteLength = [long](($files | Measure-Object Length -Sum).Sum)
    }
}

function Test-ExclusiveReadAccess {
    param([string]$Path)
    $stream = $null
    try {
        $stream = [IO.File]::Open(
            $Path,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::None
        )
        return $true
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

$expectedBuildReceiptSha256 = `
    '6e83b0c13da61712e6505f9e2a8779db5c112e74d6ebc2c5adcc1fb3d6081092'
$expectedRecoveryReceiptSha256 = `
    'fcf155d15936c02796bbfbe8bbac37df9e2afecab6c9a2b40006f7049233ba41'
$expectedBuildManifestSha256 = `
    'a2ad30f684b4697266557a86a22dd770b39c6ce3ef90af740e86ea17f8308cc0'
$expectedDeployedDllSha256 = `
    '25b7251f860518418ae8f50c59c311f25cf3a2615ded34a12f07ab845168bb38'
$expectedDatabaseBaselineSha256 = `
    'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194'
$expectedPriorDllSha256 = `
    '4417779d545c338fdf6fa1cc3a7e7b100722f367b4f6814983116a60fee6bf5e'
$expectedHostsSha256 = `
    'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0'
$catalogDeploymentUid = 'bf669c3c-fcc8-4d57-9f18-32fee1288862'

Assert-True ($env:SystemDrive -ceq 'C:') `
    'phase3b2_epinel_minimal_deployment_wrong_boot_boundary'

$micronWindows = Join-Path $MicronDrive 'Windows\System32'
$serverRoot = Join-Path $MicronDrive `
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
$micronEvidenceRoot = Join-Path $MicronDrive `
    'NLL\Evidence\Phase3B2\Physical\epinel-minimal-deployment-v1'
$backupRoot = Join-Path $MicronDrive `
    'NLL\Backups\Phase3B2\EpinelMinimalDeployment-v1'
$serverRootBefore = Join-Path $backupRoot 'server-root-before'
$partialRoot = Join-Path $MicronDrive (
    'NLL\Staging\Phase3B2\.EpinelMinimalDeployment-v1.partial-' +
    [Guid]::NewGuid().ToString('N')
)
$buildReceiptPath = Join-Path $BuildEvidenceRoot 'build.receipt.json'
$buildManifestPath = Join-Path $BuildEvidenceRoot 'publish.manifest.tsv'
$recoveryReceiptPath = Join-Path $RecoveryEvidenceRoot `
    'recovery.receipt.json'
$catalogPrivatePath = Join-Path $MicronDrive (
    'NLL\Evidence\Phase3B2\Physical\catalog-set-v1\' +
    $catalogDeploymentUid + '\deployment.private.json'
)
$hostsPath = Join-Path $MicronDrive `
    'Windows\System32\drivers\etc\hosts'
$rollbackSourcePath = Join-Path $PSScriptRoot `
    'rollback-phase3b2-epinel-minimal-in-micron.ps1'
$rollbackTargetPath = Join-Path $MicronDrive `
    'NLL\Tools\rollback-phase3b2-epinel-minimal-in-micron.ps1'

Assert-True (
    (Test-Path -LiteralPath $micronWindows -PathType Container) -and
    (Test-Path -LiteralPath $serverRoot -PathType Container) -and
    (Test-Path -LiteralPath $ServerBuildRoot -PathType Container) -and
    (Test-Path -LiteralPath $buildReceiptPath -PathType Leaf) -and
    (Test-Path -LiteralPath $buildManifestPath -PathType Leaf) -and
    (Test-Path -LiteralPath $recoveryReceiptPath -PathType Leaf) -and
    (Test-Path -LiteralPath $catalogPrivatePath -PathType Leaf) -and
    (Test-Path -LiteralPath $rollbackSourcePath -PathType Leaf) -and
    -not (Test-Path -LiteralPath $backupRoot) -and
    -not (Test-Path -LiteralPath $micronEvidenceRoot) -and
    -not (Test-Path -LiteralPath $SamsungOutputRoot) -and
    -not (Test-Path -LiteralPath $partialRoot)
) 'phase3b2_epinel_minimal_deployment_input_shape_invalid'

Assert-True (
    (Get-Sha256Hex $buildReceiptPath) -ceq $expectedBuildReceiptSha256 -and
    (Get-Sha256Hex $recoveryReceiptPath) -ceq `
        $expectedRecoveryReceiptSha256 -and
    (Get-Sha256Hex $buildManifestPath) -ceq `
        $expectedBuildManifestSha256 -and
    (Get-Sha256Hex $hostsPath) -ceq $expectedHostsSha256
) 'phase3b2_epinel_minimal_deployment_receipt_or_hosts_drift'

$buildReceipt = Get-Content -LiteralPath $buildReceiptPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
$recoveryReceipt = Get-Content -LiteralPath $recoveryReceiptPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
$catalogPrivate = Get-Content -LiteralPath $catalogPrivatePath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
Assert-True (
    $buildReceipt.contractId -ceq 'nll/phase3b2-epinel-minimal-build/v2' -and
    $buildReceipt.buildFileCount -eq 577 -and
    $buildReceipt.rawCatalogTransportCode -ceq `
        'opaque_file_stream_no_projection' -and
    $recoveryReceipt.contractId -ceq `
        'nll/phase3b2-epinel-minimal-p2-offline-recovery/v1' -and
    $recoveryReceipt.databaseRestored -and
    $recoveryReceipt.sqliteRuntimeRemoved -and
    $catalogPrivate.contractId -ceq `
        'nll/phase3b2-exact-catalog-offline-deployment-private/v1' -and
    $catalogPrivate.deploymentUid -ceq $catalogDeploymentUid -and
    @($catalogPrivate.members).Count -eq 6
) 'phase3b2_epinel_minimal_deployment_contract_invalid'

$currentDbPath = Join-Path $serverRoot 'db.json'
$currentDllPath = Join-Path $serverRoot 'EpinelPS.dll'
$currentCacheRoot = Join-Path $serverRoot 'cache'
Assert-True (
    (Get-Sha256Hex $currentDbPath) -ceq $expectedDatabaseBaselineSha256 -and
    (Get-Sha256Hex $currentDllPath) -ceq $expectedPriorDllSha256 -and
    (Test-ExclusiveReadAccess $currentDbPath) -and
    (Test-ExclusiveReadAccess $currentDllPath) -and
    @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal' | Where-Object {
        Test-Path -LiteralPath (Join-Path $serverRoot $_)
    }).Count -eq 0
) 'phase3b2_epinel_minimal_deployment_target_not_cold_or_recovered'

foreach ($member in @($catalogPrivate.members)) {
    $catalogPath = Join-Path $currentCacheRoot ([string]$member.relativePath)
    Assert-True (
        (Test-Path -LiteralPath $catalogPath -PathType Leaf) -and
        (Get-Item -LiteralPath $catalogPath).Length -eq `
            ([long]$member.byteLength) -and
        (Get-Sha256Hex $catalogPath) -ceq ([string]$member.sha256) -and
        (Test-ExclusiveReadAccess $catalogPath)
    ) 'phase3b2_epinel_minimal_deployment_raw_catalog_drift'
}

$sourceManifest = Get-ManifestResult -Root $ServerBuildRoot `
    -ExcludeRuntimeState
$cacheManifestBefore = Get-ManifestResult -Root $currentCacheRoot
Assert-True (
    $sourceManifest.Files.Count -eq 577 -and
    $sourceManifest.ContentByteLength -eq 193938533L -and
    $sourceManifest.Sha256 -ceq $expectedBuildManifestSha256 -and
    (Get-Sha256Hex (Join-Path $ServerBuildRoot 'EpinelPS.dll')) -ceq `
        $expectedDeployedDllSha256 -and
    $cacheManifestBefore.Files.Count -eq 11
) 'phase3b2_epinel_minimal_deployment_source_or_cache_invalid'

$parent = Split-Path -Parent $partialRoot
New-Item -ItemType Directory -Path $parent -Force | Out-Null
New-Item -ItemType Directory -Path $partialRoot -Force | Out-Null
$oldRootMoved = $false
$newRootPlaced = $false

try {
    $robocopy = Join-Path $env:SystemRoot 'System32\robocopy.exe'
    & $robocopy $ServerBuildRoot $partialRoot /E /COPY:DAT /DCOPY:DAT `
        /R:1 /W:1 /XD publish cache /XF db.json /NFL /NDL /NJH /NJS `
        /NP | Out-Null
    $robocopyExitCode = $LASTEXITCODE
    Assert-True ($robocopyExitCode -ge 0 -and $robocopyExitCode -le 7) `
        'phase3b2_epinel_minimal_deployment_build_copy_failed'

    Copy-Item -LiteralPath $currentCacheRoot -Destination `
        (Join-Path $partialRoot 'cache') -Recurse
    Copy-Item -LiteralPath $currentDbPath -Destination `
        (Join-Path $partialRoot 'db.json')

    $stagedBuildManifest = Get-ManifestResult -Root $partialRoot `
        -ExcludeRuntimeState
    $stagedCacheManifest = Get-ManifestResult `
        -Root (Join-Path $partialRoot 'cache')
    Assert-True (
        $stagedBuildManifest.Files.Count -eq 577 -and
        $stagedBuildManifest.Sha256 -ceq $expectedBuildManifestSha256 -and
        $stagedCacheManifest.Files.Count -eq $cacheManifestBefore.Files.Count -and
        $stagedCacheManifest.Sha256 -ceq $cacheManifestBefore.Sha256 -and
        (Get-Sha256Hex (Join-Path $partialRoot 'db.json')) -ceq `
            $expectedDatabaseBaselineSha256
    ) 'phase3b2_epinel_minimal_deployment_staging_drift'

    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    Move-Item -LiteralPath $serverRoot -Destination $serverRootBefore
    $oldRootMoved = $true
    Move-Item -LiteralPath $partialRoot -Destination $serverRoot
    $newRootPlaced = $true

    $deployedBuildManifest = Get-ManifestResult -Root $serverRoot `
        -ExcludeRuntimeState
    $deployedCacheManifest = Get-ManifestResult `
        -Root (Join-Path $serverRoot 'cache')
    Assert-True (
        $deployedBuildManifest.Files.Count -eq 577 -and
        $deployedBuildManifest.Sha256 -ceq $expectedBuildManifestSha256 -and
        $deployedCacheManifest.Sha256 -ceq $cacheManifestBefore.Sha256 -and
        (Get-Sha256Hex (Join-Path $serverRoot 'db.json')) -ceq `
            $expectedDatabaseBaselineSha256 -and
        (Get-Sha256Hex (Join-Path $serverRoot 'EpinelPS.dll')) -ceq `
            $expectedDeployedDllSha256
    ) 'phase3b2_epinel_minimal_deployment_post_swap_drift'

    New-Item -ItemType Directory -Path $micronEvidenceRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $SamsungOutputRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $rollbackTargetPath) `
        -Force | Out-Null
    Copy-Item -LiteralPath $rollbackSourcePath -Destination $rollbackTargetPath `
        -Force

    $backupManifest = Get-ManifestResult -Root $serverRootBefore
    $backupManifestPath = Join-Path $micronEvidenceRoot `
        'server-root-before.manifest.tsv'
    Write-Utf8NoBom $backupManifestPath $backupManifest.Text

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-epinel-minimal-offline-deployment/v1'
        deployedAtUtc = [DateTimeOffset]::UtcNow.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'"
        )
        buildReceiptSha256 = $expectedBuildReceiptSha256
        recoveryReceiptSha256 = $expectedRecoveryReceiptSha256
        externalHead = [string]$buildReceipt.externalHead
        externalTree = [string]$buildReceipt.externalTree
        buildFileCount = $deployedBuildManifest.Files.Count
        buildContentByteLength = $deployedBuildManifest.ContentByteLength
        buildManifestSha256 = $deployedBuildManifest.Sha256
        deployedServerDllSha256 = Get-Sha256Hex (
            Join-Path $serverRoot 'EpinelPS.dll'
        )
        priorServerDllSha256 = $expectedPriorDllSha256
        databaseBaselineSha256 = $expectedDatabaseBaselineSha256
        cacheMemberCount = $deployedCacheManifest.Files.Count
        cacheContentByteLength = $deployedCacheManifest.ContentByteLength
        cacheManifestSha256 = $deployedCacheManifest.Sha256
        rawCatalogMemberCount = @($catalogPrivate.members).Count
        rawCatalogSetVerified = $true
        catalogDeploymentUid = $catalogDeploymentUid
        rawCatalogTransportCode = 'opaque_file_stream_no_projection'
        priorServerRootPreserved = $true
        priorServerRootBackupPath = $serverRootBefore
        backupManifestByteLength = $backupManifest.Bytes.Length
        backupManifestSha256 = $backupManifest.Sha256
        rollbackToolSha256 = Get-Sha256Hex $rollbackTargetPath
        baseHostsPreserved = $true
        deploymentApplied = $true
        targetOsOfflineDuringDeployment = $true
        officialOutboundUsed = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        nextStepCode = 'run_epinel_minimal_source_free_preflight'
    }
    $receiptText = ($receipt | ConvertTo-Json -Depth 6) + "`n"
    $micronReceiptPath = Join-Path $micronEvidenceRoot `
        'deployment.receipt.json'
    $samsungReceiptPath = Join-Path $SamsungOutputRoot `
        'deployment.receipt.json'
    Write-Utf8NoBom $micronReceiptPath $receiptText
    Write-Utf8NoBom $samsungReceiptPath $receiptText
    Copy-Item -LiteralPath $buildManifestPath -Destination `
        (Join-Path $micronEvidenceRoot 'deployed-build.manifest.tsv')

    [pscustomobject]@{
        Receipt = $receipt
        MicronReceiptPath = $micronReceiptPath
        MicronReceiptSha256 = Get-Sha256Hex $micronReceiptPath
        SamsungReceiptPath = $samsungReceiptPath
        SamsungReceiptSha256 = Get-Sha256Hex $samsungReceiptPath
    } | ConvertTo-Json -Depth 7
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
