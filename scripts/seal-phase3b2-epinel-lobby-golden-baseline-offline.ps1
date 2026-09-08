#requires -Version 7.0

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Z]$')]
    [string]$MicronDriveLetter = 'E',
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$SuccessfulAssessmentUid =
        'e3f33bd6-49bb-4f5f-a0b4-a7646f59108c',
    [string]$ProtectedRoot = (
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\' +
        'Micron-PrePhysicalLane-20260823\PhysicalP2\' +
        'EpinelLobbyGoldenBaseline-v1'
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
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.
        ToLowerInvariant()
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

function Get-CanonicalManifestSha256 {
    param([object[]]$Members)

    $canonical = (@($Members | Sort-Object roleCode | ForEach-Object {
                '{0}`t{1}`t{2}`n' -f $_.roleCode,
                ([long]$_.byteLength), ([string]$_.sha256)
            }) -join '')
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($canonical)
        return (($algorithm.ComputeHash($bytes) | ForEach-Object {
                    $_.ToString('x2')
                }) -join '')
    }
    finally {
        $algorithm.Dispose()
    }
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
$administratorTokenPresent = $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

$micronDrive = $MicronDriveLetter + ':'
$systemDisk = Get-Partition -DriveLetter C | Get-Disk
$micronDisk = Get-Partition -DriveLetter $MicronDriveLetter | Get-Disk
Assert-True (
    $env:SystemDrive -ceq 'C:' -and
    $systemDisk.FriendlyName -like 'Samsung SSD 980*' -and
    $micronDisk.FriendlyName -like 'Micron_2200*' -and
    (Test-Path -LiteralPath (
            Join-Path $micronDrive 'Windows\System32'
        ) -PathType Container)
) 'phase3b2_epinel_lobby_golden_wrong_disk_boundary'
$runtimeProcesses = @(Get-Process -Name @(
        'EpinelPS', 'NIKKE', 'nikke_launcher',
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
    ) -ErrorAction SilentlyContinue)
Assert-True ($runtimeProcesses.Count -eq 0) `
    'phase3b2_epinel_lobby_golden_runtime_not_cold'

$serverRoot = Join-Path $micronDrive (
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
)
$runRoot = Join-Path $micronDrive (
    'NLL\Evidence\Phase3B2\Physical\epinel-minimal-reference-v1\' +
    $SuccessfulAssessmentUid
)
$runStartPath = Join-Path $runRoot 'run-start.receipt.json'
$completionPath = Join-Path $runRoot 'completion.receipt.json'
$bindingPath = Join-Path $runRoot 'native-cache.binding.receipt.json'
$activePointerPath = Join-Path $micronDrive (
    'NLL\Evidence\Phase3B2\Physical\epinel-minimal-reference-v1\' +
    'active-run.pointer.json'
)
$databasePath = Join-Path $serverRoot 'db.json'
$serverDllPath = Join-Path $serverRoot 'EpinelPS.dll'
$nativeDeploymentPath = Join-Path $micronDrive (
    'NLL\Evidence\Phase3B2\Physical\' +
    'epinel-native-cache-deployment-v1\deployment.receipt.json'
)
$sausStagingPath = Join-Path $micronDrive (
    'NLL\Evidence\Phase3B2\Physical\' +
    'epinel-saus-pair-staging-v1\staging.receipt.json'
)
$externalRepositoryRoot = [IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..\.external\EpinelPS')
)
$toolPaths = [ordered]@{
    native_cache_start = Join-Path $micronDrive `
        'NLL\Tools\Start-Phase3B2-Epinel-NativeCache.ps1'
    minimal_start = Join-Path $micronDrive `
        'NLL\Tools\start-phase3b2-epinel-minimal-reference-in-micron.ps1'
    completion_wrapper = Join-Path $micronDrive `
        'NLL\Tools\Complete-Phase3B2-Epinel-Minimal.ps1'
    completion_inner = Join-Path $micronDrive `
        'NLL\Tools\complete-phase3b2-epinel-minimal-reference-in-micron.ps1'
    physical_bootstrap = Join-Path $micronDrive (
        'NLL\Runtime\PhysicalBootstrap-v2\artifact\' +
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap.exe'
    )
}

$expected = [ordered]@{
    runStartLength = 2731L
    runStartSha256 =
        'b6f53d34daafd53e133fbd803834ae8d3b043f8b1da268bafb3515f761ef899b'
    completionLength = 1735L
    completionSha256 =
        'da485e2e0acb72ac6772473b5e7a151be476177071ab8145c4ff1e371c838350'
    bindingLength = 1895L
    bindingSha256 =
        'e4d504f43ef6640f146afc428862cef218374cf0d5356bd2d4aa489bd8f8ecf7'
    databaseLength = 413327L
    databaseSha256 =
        'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194'
    serverDllLength = 15366144L
    serverDllSha256 =
        'aaa1e49d7a879a6b5ec17ad4c4094ce7d98ce86f860c1529a9ab4d6aecb51f7c'
    externalHead = 'aa01ad90b807be1c2ceffe958519cb529622d472'
    externalTree = 'c324c11d32365b1524f266cba6bc014e89545204'
    nativeDeploymentSha256 =
        '14bf845aec4cded1d80e8efb57a3eb4f4639ef68bd1fdf7a8d9de462689aae7d'
    sausStagingSha256 =
        '2350aae3ba7320da21bb80a1eb26c118275b39b0678b3d844990742240f019e2'
}

$requiredFiles = @(
    $runStartPath, $completionPath, $bindingPath, $databasePath,
    $serverDllPath, $nativeDeploymentPath, $sausStagingPath
) + @($toolPaths.Values)
Assert-True (
    @($requiredFiles | Where-Object {
            -not (Test-Path -LiteralPath $_ -PathType Leaf)
        }).Count -eq 0 -and
    (Test-Path -LiteralPath $externalRepositoryRoot -PathType Container) -and
    -not (Test-Path -LiteralPath $activePointerPath)
) 'phase3b2_epinel_lobby_golden_input_shape_invalid'
Assert-True (
    (Get-Item -LiteralPath $runStartPath).Length -eq
        $expected.runStartLength -and
    (Get-Sha256Hex $runStartPath) -ceq $expected.runStartSha256 -and
    (Get-Item -LiteralPath $completionPath).Length -eq
        $expected.completionLength -and
    (Get-Sha256Hex $completionPath) -ceq $expected.completionSha256 -and
    (Get-Item -LiteralPath $bindingPath).Length -eq
        $expected.bindingLength -and
    (Get-Sha256Hex $bindingPath) -ceq $expected.bindingSha256 -and
    (Get-Item -LiteralPath $databasePath).Length -eq
        $expected.databaseLength -and
    (Get-Sha256Hex $databasePath) -ceq $expected.databaseSha256 -and
    (Get-Item -LiteralPath $serverDllPath).Length -eq
        $expected.serverDllLength -and
    (Get-Sha256Hex $serverDllPath) -ceq $expected.serverDllSha256 -and
    (Get-Sha256Hex $nativeDeploymentPath) -ceq
        $expected.nativeDeploymentSha256 -and
    (Get-Sha256Hex $sausStagingPath) -ceq $expected.sausStagingSha256
) 'phase3b2_epinel_lobby_golden_pinned_digest_invalid'

$runStart = Get-Content -LiteralPath $runStartPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$completion = Get-Content -LiteralPath $completionPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$binding = Get-Content -LiteralPath $bindingPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True (
    $runStart.contractId -ceq
        'nll/phase3b2-epinel-minimal-reference-start/v1' -and
    $runStart.assessmentUid -ceq $SuccessfulAssessmentUid -and
    $runStart.requiredLocalAssetPreflightPerformed -and
    $runStart.requiredLocalCatalogAllSqlite -and
    $runStart.requiredLocalSausBodyCrc32Matched -and
    $runStart.successfulNonLoopbackConnectionCount -eq 0 -and
    -not $runStart.officialOutboundFallbackUsed -and
    -not $runStart.officialLauncherExecutionStarted -and
    $completion.contractId -ceq
        'nll/phase3b2-epinel-minimal-reference-completion/v1' -and
    $completion.assessmentUid -ceq $SuccessfulAssessmentUid -and
    $completion.observedStageCode -ceq 'lobby' -and
    $completion.outcomeCode -ceq 'success' -and
    $completion.databaseRestored -and
    $completion.sqliteRuntimeRemoved -and
    $completion.hostsRestored -and
    $completion.extensionFirewallRemoved -and
    $completion.runtimeColdAfterCompletion -and
    $binding.contractId -ceq
        'nll/phase3b2-epinel-native-cache-run-binding/v5' -and
    $binding.assessmentUid -ceq $SuccessfulAssessmentUid -and
    $binding.activeCacheFileCount -eq 40111 -and
    [long]$binding.activeCacheContentByteLength -eq 39030643658L
) 'phase3b2_epinel_lobby_golden_success_contract_invalid'

$database = Get-Content -LiteralPath $databasePath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True (
    @($database.Users).Count -eq 1 -and
    @($database.Users[0].Characters).Count -eq 193 -and
    @($database.Users[0].ClearedTutorialDataNew.PSObject.Properties).
        Count -eq 0 -and
    $database.Users[0].LastNormalStageCleared -eq 0 -and
    $database.Users[0].LastStoryStageCleared -eq 0 -and
    $database.Users[0].LastHardStageCleared -eq 0 -and
    @($database.Users[0].StageClearHistorys).Count -eq 0
) 'phase3b2_epinel_lobby_golden_database_shape_invalid'

$gitCommand = Get-Command git -ErrorAction SilentlyContinue |
    Select-Object -First 1
$gitCandidates = @(
    (Join-Path $micronDrive 'Program Files\Git\cmd\git.exe'),
    $(if ($null -ne $gitCommand) { $gitCommand.Source })
) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } |
    Select-Object -Unique
Assert-True ($gitCandidates.Count -ge 1) `
    'phase3b2_epinel_lobby_golden_git_missing'
$gitPath = $gitCandidates[0]
$safeRepository = $externalRepositoryRoot.Replace('\', '/')
$sourceStatus = @(
    & $gitPath -c "safe.directory=$safeRepository" -C `
        $externalRepositoryRoot status --porcelain
)
$externalHead = ((
        & $gitPath -c "safe.directory=$safeRepository" -C `
            $externalRepositoryRoot rev-parse HEAD
    ) | Out-String).Trim()
$externalTree = ((
        & $gitPath -c "safe.directory=$safeRepository" -C `
            $externalRepositoryRoot rev-parse 'HEAD^{tree}'
    ) | Out-String).Trim()
Assert-True (
    $LASTEXITCODE -eq 0 -and $sourceStatus.Count -eq 0 -and
    $externalHead -ceq $expected.externalHead -and
    $externalTree -ceq $expected.externalTree
) 'phase3b2_epinel_lobby_golden_external_source_invalid'

$sealUid = [Guid]::NewGuid().ToString('D')
$backupRoot = Join-Path $micronDrive (
    'NLL\Backups\Phase3B2\EpinelLobbyGoldenBaseline-v1\' + $sealUid
)
$evidenceRoot = Join-Path $micronDrive (
    'NLL\Evidence\Phase3B2\Physical\' +
    'epinel-lobby-golden-baseline-v1\' + $sealUid
)
$protectedSealRoot = Join-Path $ProtectedRoot $sealUid
Assert-True (
    -not (Test-Path -LiteralPath $backupRoot) -and
    -not (Test-Path -LiteralPath $evidenceRoot) -and
    -not (Test-Path -LiteralPath $protectedSealRoot)
) 'phase3b2_epinel_lobby_golden_destination_collision'

$backupPartial = $backupRoot + '.partial-' +
    [Guid]::NewGuid().ToString('N')
try {
    $runtimeBackupRoot = Join-Path $backupPartial 'runtime-top-level'
    $toolBackupRoot = Join-Path $backupPartial 'tools'
    $receiptBackupRoot = Join-Path $backupPartial 'success-receipts'
    New-Item -ItemType Directory -Path $runtimeBackupRoot, $toolBackupRoot,
        $receiptBackupRoot -Force | Out-Null

    $members = [Collections.Generic.List[object]]::new()
    foreach ($source in @(Get-ChildItem -LiteralPath $serverRoot -File -Force |
            Sort-Object Name)) {
        $destination = Join-Path $runtimeBackupRoot $source.Name
        Copy-Item -LiteralPath $source.FullName -Destination $destination
        $members.Add([pscustomobject]@{
                roleCode = 'runtime_top_level/' + $source.Name
                byteLength = [long]$source.Length
                sha256 = Get-Sha256Hex $destination
            })
    }
    foreach ($entry in $toolPaths.GetEnumerator()) {
        $destination = Join-Path $toolBackupRoot (
            $entry.Key + [IO.Path]::GetExtension([string]$entry.Value)
        )
        Copy-Item -LiteralPath $entry.Value -Destination $destination
        $members.Add([pscustomobject]@{
                roleCode = 'tool/' + $entry.Key
                byteLength = [long](Get-Item -LiteralPath $destination).Length
                sha256 = Get-Sha256Hex $destination
            })
    }
    $receiptSources = [ordered]@{
            run_start = $runStartPath
            completion = $completionPath
            native_cache_binding = $bindingPath
            native_cache_deployment = $nativeDeploymentPath
            saus_staging = $sausStagingPath
        }
    foreach ($entry in $receiptSources.GetEnumerator()) {
        $destination = Join-Path $receiptBackupRoot ($entry.Key + '.json')
        Copy-Item -LiteralPath $entry.Value -Destination $destination
        $members.Add([pscustomobject]@{
                roleCode = 'receipt/' + $entry.Key
                byteLength = [long](Get-Item -LiteralPath $destination).Length
                sha256 = Get-Sha256Hex $destination
            })
    }

    $bundlePath = Join-Path $backupPartial 'epinel-source.bundle'
    & $gitPath -c "safe.directory=$safeRepository" -C `
        $externalRepositoryRoot bundle create $bundlePath HEAD | Out-Null
    Assert-True ($LASTEXITCODE -eq 0 -and
        (Test-Path -LiteralPath $bundlePath -PathType Leaf)) `
        'phase3b2_epinel_lobby_golden_source_bundle_failed'
    & $gitPath bundle verify $bundlePath 2>&1 | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) `
        'phase3b2_epinel_lobby_golden_source_bundle_invalid'
    $members.Add([pscustomobject]@{
            roleCode = 'source/epinel_bundle'
            byteLength = [long](Get-Item -LiteralPath $bundlePath).Length
            sha256 = Get-Sha256Hex $bundlePath
        })

    $manifest = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-lobby-golden-artifact-manifest/v1'
        sealUid = $sealUid
        memberCount = $members.Count
        members = @($members)
    }
    $manifestPath = Join-Path $backupPartial 'artifact.manifest.json'
    Write-AtomicUtf8NoBom $manifestPath (
        ($manifest | ConvertTo-Json -Depth 7) + "`n"
    )
    $manifestCanonicalSha256 = Get-CanonicalManifestSha256 @($members)
    $manifestSha256 = Get-Sha256Hex $manifestPath

    $rollback = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-lobby-golden-rollback-plan/v1'
        sealUid = $sealUid
        requiresSamsungBoot = $true
        requiresMicronOffline = $true
        runtimeMustBeCold = $true
        restoreDatabaseFirst = $true
        restoreRuntimeTopLevelFrom = 'runtime-top-level'
        restoreToolsFrom = 'tools'
        cacheMutationRequired = $false
        sourceRecoveryBundle = 'epinel-source.bundle'
        automaticRollbackPerformed = $false
    }
    Write-AtomicUtf8NoBom (Join-Path $backupPartial 'rollback.plan.json') (
        ($rollback | ConvertTo-Json -Depth 5) + "`n"
    )

    Move-Item -LiteralPath $backupPartial -Destination $backupRoot
}
finally {
    if (Test-Path -LiteralPath $backupPartial) {
        Remove-Item -LiteralPath $backupPartial -Recurse -Force
    }
}

$sealedManifestPath = Join-Path $backupRoot 'artifact.manifest.json'
$sealedRollbackPath = Join-Path $backupRoot 'rollback.plan.json'
$manifest = Get-Content -LiteralPath $sealedManifestPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True (
    $manifest.memberCount -eq @($manifest.members).Count -and
    (Get-CanonicalManifestSha256 @($manifest.members)) -ceq
        $manifestCanonicalSha256
) 'phase3b2_epinel_lobby_golden_manifest_recheck_failed'

$runtimeTopLevelFileCount = @(
    Get-ChildItem -LiteralPath (
        Join-Path $backupRoot 'runtime-top-level'
    ) -File
).Count
$artifactManifestByteLength = [long](
    Get-Item -LiteralPath $sealedManifestPath
).Length
$rollbackPlanByteLength = [long](
    Get-Item -LiteralPath $sealedRollbackPath
).Length

$receipt = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-epinel-lobby-golden-baseline/v1'
    sealedAtUtc = [DateTimeOffset]::UtcNow.ToString(
        "yyyy-MM-dd'T'HH:mm:ss'Z'"
    )
    sealUid = $sealUid
    successfulAssessmentUid = $SuccessfulAssessmentUid
    runStartReceiptSha256 = $expected.runStartSha256
    completionReceiptSha256 = $expected.completionSha256
    nativeCacheBindingReceiptSha256 = $expected.bindingSha256
    nativeCacheDeploymentReceiptSha256 =
        $expected.nativeDeploymentSha256
    sausStagingReceiptSha256 = $expected.sausStagingSha256
    externalHead = $externalHead
    externalTree = $externalTree
    externalCheckoutClean = $true
    sourceBundleByteLength = [long](Get-Item -LiteralPath (
            Join-Path $backupRoot 'epinel-source.bundle'
        )).Length
    sourceBundleSha256 = Get-Sha256Hex (
        Join-Path $backupRoot 'epinel-source.bundle'
    )
    databaseByteLength = $expected.databaseLength
    databaseSha256 = $expected.databaseSha256
    serverDllByteLength = $expected.serverDllLength
    serverDllSha256 = $expected.serverDllSha256
    characterCount = 193
    clearedTutorialGroupCount = 0
    contentsOpenUnlockCount = 0
    stageClearHistoryCount = 0
    lastNormalStageCleared = 0
    lastStoryStageCleared = 0
    lastHardStageCleared = 0
    lobbyReached = $true
    activeCacheFileCount = 40111
    activeCacheContentByteLength = 39030643658L
    runtimeTopLevelFileCount = $runtimeTopLevelFileCount
    artifactManifestByteLength = $artifactManifestByteLength
    artifactManifestSha256 = Get-Sha256Hex $sealedManifestPath
    artifactManifestCanonicalSha256 = $manifestCanonicalSha256
    rollbackPlanByteLength = $rollbackPlanByteLength
    rollbackPlanSha256 = Get-Sha256Hex $sealedRollbackPath
    cacheRecopyPerformed = $false
    activeCacheMutationPerformed = $false
    databaseMutationPerformed = $false
    existingOperatorCacheModified = $false
    officialOutboundUsed = $false
    officialApiUsed = $false
    officialLoginUsed = $false
    officialIdentityPersisted = $false
    officialCredentialPersisted = $false
    targetOsOfflineDuringSeal = $true
    administratorTokenPresent = $administratorTokenPresent
    serverExecutionStarted = $false
    clientExecutionStarted = $false
    nextStepCode = 'materialize_exact_build_tutorial_only_revision_offline'
}

$micronReceiptPath = Join-Path $evidenceRoot 'golden-baseline.receipt.json'
$protectedReceiptPath = Join-Path $protectedSealRoot (
    'golden-baseline.receipt.json'
)
$protectedBackupRoot = Join-Path $protectedSealRoot 'artifacts'
New-Item -ItemType Directory -Path $evidenceRoot, $protectedSealRoot -Force |
    Out-Null
Write-AtomicUtf8NoBom $micronReceiptPath (
    ($receipt | ConvertTo-Json -Depth 7) + "`n"
)
Copy-Item -LiteralPath $backupRoot -Destination $protectedBackupRoot -Recurse
Copy-Item -LiteralPath $micronReceiptPath -Destination $protectedReceiptPath
$protectedManifestPath = Join-Path $protectedBackupRoot `
    'artifact.manifest.json'
$protectedBundlePath = Join-Path $protectedBackupRoot 'epinel-source.bundle'
$micronBundlePath = Join-Path $backupRoot 'epinel-source.bundle'
Assert-True (
    (Get-Sha256Hex $micronReceiptPath) -ceq
        (Get-Sha256Hex $protectedReceiptPath) -and
    (Get-Sha256Hex $sealedManifestPath) -ceq
        (Get-Sha256Hex $protectedManifestPath) -and
    (Get-Sha256Hex $micronBundlePath) -ceq
        (Get-Sha256Hex $protectedBundlePath)
) 'phase3b2_epinel_lobby_golden_protected_copy_invalid'

$micronReceiptByteLength = (
    Get-Item -LiteralPath $micronReceiptPath
).Length
[pscustomobject]@{
    Receipt = $receipt
    MicronReceiptPath = $micronReceiptPath
    MicronReceiptByteLength = $micronReceiptByteLength
    MicronReceiptSha256 = Get-Sha256Hex $micronReceiptPath
    MicronBackupRoot = $backupRoot
    SamsungProtectedReceiptPath = $protectedReceiptPath
    SamsungProtectedBackupRoot = $protectedBackupRoot
} | ConvertTo-Json -Depth 8
