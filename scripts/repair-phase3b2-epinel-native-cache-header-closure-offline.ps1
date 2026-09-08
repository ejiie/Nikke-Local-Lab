[CmdletBinding()]
param(
    [ValidatePattern('^[A-Z]$')]
    [string]$MicronDriveLetter = 'E',
    [string]$FailedAssessmentUid =
        'cbce0850-d821-4f0a-99cc-fb3603c4722d',
    [string]$ProtectedRoot =
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\EpinelNativeCacheHeaderClosure-v1'
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
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $item = Get-Item -LiteralPath $Path
    return $item.Length -eq $ByteLength -and
        (Get-Sha256Hex $Path) -ceq $Sha256
}

function Test-ExclusiveAccess {
    param([string]$Path)
    try {
        $stream = [IO.File]::Open(
            $Path,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::None
        )
        $stream.Dispose()
        return $true
    }
    catch { return $false }
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

function Protect-ServerLog {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 0 }
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    $pattern = '(?m)^(?<prefix>\s*authtoken:\s*)\S+\s*$'
    $matchCount = [regex]::Matches($text, $pattern).Count
    if ($matchCount -gt 0) {
        Write-AtomicUtf8NoBom $Path ([regex]::Replace(
                $text,
                $pattern,
                '${prefix}[REDACTED]'
            ))
    }
    return $matchCount
}

function Invoke-CacheInspection {
    param(
        [string]$DotnetPath,
        [string]$VerifierDllPath,
        [string]$CacheRoot
    )
    $output = & $DotnetPath $VerifierDllPath `
        'inspect-cache-tree' $CacheRoot 2>&1
    Assert-True ($LASTEXITCODE -eq 0) `
        'phase3b2_epinel_header_closure_cache_inspection_failed'
    return (($output | Out-String) | ConvertFrom-Json)
}

$expectedFailedRunStartSha256 =
    'dcae81e2298c873a5af97b60e2aa1c5e89be6829a92a76611e8cad74936e39a5'
$expectedFailedPointerSha256 =
    '69b9d000e450150d19836dfff1a2a092e15a30af074a5c6895254127655d6f5f'
$expectedFailedBindingSha256 =
    'b37b754059cdea2b43d3ee227ddc5f24b3b3f618c030383dfb45a097ed25e08b'
$expectedDatabaseBeforeSha256 =
    'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194'
$expectedDatabaseAfterSha256 =
    'e524a3c8967af6bb8447fda0c50fc8a86ebccd02e1d1a45df73b2625430acc8d'
$expectedHostsBeforeSha256 =
    'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0'
$expectedHostsAfterSha256 =
    '3b0dcc4396373e9e9d623ef05c345f89330427ad5128727290c9f76138e22f64'
$expectedDeploymentReceiptSha256 =
    '14bf845aec4cded1d80e8efb57a3eb4f4639ef68bd1fdf7a8d9de462689aae7d'
$expectedLongPathRepairReceiptSha256 =
    'ed337fea541f3807664e18925477ae3f464c8a388901fc881bd93fbc4da32dc1'
$expectedVerifierManifestSha256 =
    '3305d52786315bc927c46cdb988ce35b067d704f0a562be7aa469a188da3541c'
$expectedPriorStartToolSha256 =
    '08b60d20d91db91a0e5f2dd82e9bd87acfeaf9f2fd00ae4c5f9a1a44aeee3c58'
$expectedPriorMinimalStartToolSha256 =
    'b3880687d7c92b22af340fb433de77c6786dd1950c8717ee3db5ac83db6626c2'
$expectedProjectionReceiptSha256 =
    'c13074f78a27e435f1cb00def0d3c4ffe48216113107f625b1718a61f942e1f6'
$expectedStaticAnalysisReceiptSha256 =
    '5b52bb79c2fa92f0341c059ff825609409a044e1bde22db2e740196970251fb9'
$expectedHeaderByteLength = 139L
$expectedHeaderSha256 =
    '5914cb58fd2146fe761ab531ecb4e321300527186a54b455e59de962ff6c044a'
$expectedCacheFileCountBefore = 40108
$expectedCacheByteLengthBefore = 39030629947L
$expectedCacheFileCountAfter = 40109
$expectedCacheByteLengthAfter = 39030630086L

$micronDrive = $MicronDriveLetter + ':'
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$currentPrincipal = [Security.Principal.WindowsPrincipal]::new(
    $currentIdentity
)
Assert-True (
    $currentPrincipal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
) 'phase3b2_epinel_header_closure_administrator_required'

$systemDisk = Get-Partition -DriveLetter C | Get-Disk
$micronDisk = Get-Partition -DriveLetter $MicronDriveLetter | Get-Disk
Assert-True (
    $env:SystemDrive -ceq 'C:' -and
    $systemDisk.FriendlyName -like 'Samsung SSD 980*' -and
    $micronDisk.FriendlyName -like 'Micron_2200*' -and
    (Test-Path -LiteralPath (Join-Path $micronDrive 'Windows\System32') `
        -PathType Container)
) 'phase3b2_epinel_header_closure_wrong_disk_boundary'
Assert-True (
    @(Get-Process -Name EpinelPS, nikke, nikke_launcher,
        NikkeLocalLab.Phase3B2.PhysicalBootstrap `
        -ErrorAction SilentlyContinue).Count -eq 0
) 'phase3b2_epinel_header_closure_runtime_not_cold'

$serverRoot = Join-Path $micronDrive `
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
$cacheRoot = Join-Path $serverRoot 'cache'
$headerRelativePath =
    'prdenv/150-b059c3f36c/StandaloneWindows64/pck/latest-651.txt'
$headerPath = Join-Path $cacheRoot $headerRelativePath.Replace('/', '\')
$databasePath = Join-Path $serverRoot 'db.json'
$sqlitePaths = @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal' |
    ForEach-Object { Join-Path $serverRoot $_ })
$hostsPath = Join-Path $micronDrive 'Windows\System32\drivers\etc\hosts'
$evidenceRoot = Join-Path $micronDrive `
    'NLL\Evidence\Phase3B2\Physical\epinel-minimal-reference-v1'
$runRoot = Join-Path $evidenceRoot $FailedAssessmentUid
$pointerPath = Join-Path $evidenceRoot 'active-run.pointer.json'
$runStartPath = Join-Path $runRoot 'run-start.receipt.json'
$bindingPath = Join-Path $runRoot 'native-cache.binding.receipt.json'
$dbBeforePath = Join-Path $runRoot 'db.before.bin'
$hostsBeforePath = Join-Path $runRoot 'hosts.before.bin'
$stdoutPath = Join-Path $runRoot 'server.stdout.log'
$stderrPath = Join-Path $runRoot 'server.stderr.log'
$archivedPointerPath = Join-Path $runRoot `
    'active-run.pointer.archived-header-closure.json'
$offlineCompletionPath = Join-Path $runRoot `
    'header-closure.offline-completion.receipt.json'
$playerLogPath = Join-Path $micronDrive `
    'Users\nlloperator\AppData\LocalLow\com.proximabeta\NIKKE\Player.log'

$deploymentReceiptPath = Join-Path $micronDrive `
    'NLL\Evidence\Phase3B2\Physical\epinel-native-cache-deployment-v1\deployment.receipt.json'
$longPathRepairReceiptPath = Join-Path $micronDrive `
    'NLL\Evidence\Phase3B2\Physical\epinel-native-cache-start-long-path-repair-v1\repair.receipt.json'
$verifierRoot = Join-Path $micronDrive `
    'NLL\Tools\Phase3B2.NativeCacheVerifier-v1'
$verifierManifestPath = Join-Path $verifierRoot 'bundle.manifest.json'
$verifierDllPath = Join-Path $verifierRoot `
    'Phase3B2.NativeCacheMaterializer.dll'
$dotnetCandidates = @(
    (Join-Path $micronDrive 'Program Files\dotnet\dotnet.exe'),
    (Join-Path $env:ProgramFiles 'dotnet\dotnet.exe')
)
$dotnetPath = @($dotnetCandidates | Where-Object {
        Test-Path -LiteralPath $_ -PathType Leaf
    } | Select-Object -First 1)

$projectionReceiptPath = Join-Path $micronDrive `
    'NLL\Evidence\Phase3B2\Physical\p2-tool-transfer-v2\datapack-version-header-projection.receipt.json'
$staticAnalysisReceiptPath = Join-Path $micronDrive `
    'NLL\Evidence\Phase3B2\Physical\p2-tool-transfer-v2\datapack-version-header-static-analysis.receipt.json'
$headerProofPath = Join-Path $PSScriptRoot (
    '..\.external\phase3b2-header-proof\' + $headerRelativePath.Replace('/', '\')
)
$activeStartToolPath = Join-Path $micronDrive `
    'NLL\Tools\Start-Phase3B2-Epinel-NativeCache.ps1'
$activeMinimalStartToolPath = Join-Path $micronDrive `
    'NLL\Tools\start-phase3b2-epinel-minimal-reference-in-micron.ps1'
$minimalStartTemplatePath = Join-Path $PSScriptRoot `
    'start-phase3b2-epinel-minimal-reference-in-micron.ps1'
$nativeStartTemplatePath = Join-Path $PSScriptRoot `
    'Start-Phase3B2-Epinel-NativeCache-LongPath.ps1'

$backupRoot = Join-Path $micronDrive (
    'NLL\Backups\Phase3B2\EpinelNativeCacheHeaderClosure-v1\' +
    $FailedAssessmentUid
)
$stateBackupRoot = Join-Path $backupRoot 'runtime-state'
$priorStartBackupPath = Join-Path $backupRoot `
    'Start-Phase3B2-Epinel-NativeCache.before.ps1'
$priorMinimalStartBackupPath = Join-Path $backupRoot `
    'start-phase3b2-epinel-minimal-reference-in-micron.before.ps1'
$backupManifestPath = Join-Path $backupRoot 'backup.manifest.tsv'
$rollbackPlanPath = Join-Path $backupRoot 'rollback.plan.json'
$repairEvidenceRoot = Join-Path $micronDrive `
    'NLL\Evidence\Phase3B2\Physical\epinel-native-cache-header-closure-v1'
$repairReceiptPath = Join-Path $repairEvidenceRoot 'repair.receipt.json'
$toolBindingReceiptPath = Join-Path $repairEvidenceRoot `
    'tool-binding.receipt.json'
$protectedAssessmentRoot = Join-Path $ProtectedRoot $FailedAssessmentUid
$protectedReceiptPath = Join-Path $protectedAssessmentRoot `
    'repair.receipt.json'
$protectedToolBindingReceiptPath = Join-Path $protectedAssessmentRoot `
    'tool-binding.receipt.json'

$requiredInputs = @(
    $pointerPath, $runStartPath, $bindingPath, $dbBeforePath,
    $hostsBeforePath, $stdoutPath, $stderrPath, $playerLogPath,
    $databasePath, $hostsPath, $deploymentReceiptPath,
    $longPathRepairReceiptPath, $verifierManifestPath, $verifierDllPath,
    $projectionReceiptPath, $staticAnalysisReceiptPath, $headerProofPath,
    $activeStartToolPath, $activeMinimalStartToolPath,
    $minimalStartTemplatePath, $nativeStartTemplatePath
) + $sqlitePaths
Assert-True (
    @($requiredInputs | Where-Object {
            -not (Test-Path -LiteralPath $_ -PathType Leaf)
        }).Count -eq 0 -and
    $dotnetPath.Count -eq 1 -and
    (Test-Path -LiteralPath $cacheRoot -PathType Container) -and
    -not (Test-Path -LiteralPath $headerPath) -and
    -not (Test-Path -LiteralPath $archivedPointerPath) -and
    -not (Test-Path -LiteralPath $offlineCompletionPath) -and
    -not (Test-Path -LiteralPath $backupRoot) -and
    -not (Test-Path -LiteralPath $repairEvidenceRoot) -and
    -not (Test-Path -LiteralPath $protectedAssessmentRoot)
) 'phase3b2_epinel_header_closure_input_or_destination_invalid'

Assert-True (
    (Test-Digest $pointerPath 872L $expectedFailedPointerSha256) -and
    (Test-Digest $runStartPath 1830L $expectedFailedRunStartSha256) -and
    (Test-Digest $bindingPath 837L $expectedFailedBindingSha256) -and
    (Test-Digest $dbBeforePath 413327L $expectedDatabaseBeforeSha256) -and
    (Test-Digest $databasePath 413329L $expectedDatabaseAfterSha256) -and
    (Test-Digest $hostsBeforePath 1690L $expectedHostsBeforeSha256) -and
    (Test-Digest $hostsPath 1727L $expectedHostsAfterSha256) -and
    (Get-Sha256Hex $deploymentReceiptPath) -ceq `
        $expectedDeploymentReceiptSha256 -and
    (Get-Sha256Hex $longPathRepairReceiptPath) -ceq `
        $expectedLongPathRepairReceiptSha256 -and
    (Get-Sha256Hex $verifierManifestPath) -ceq `
        $expectedVerifierManifestSha256 -and
    (Get-Sha256Hex $activeStartToolPath) -ceq `
        $expectedPriorStartToolSha256 -and
    (Get-Sha256Hex $activeMinimalStartToolPath) -ceq `
        $expectedPriorMinimalStartToolSha256 -and
    (Get-Sha256Hex $projectionReceiptPath) -ceq `
        $expectedProjectionReceiptSha256 -and
    (Get-Sha256Hex $staticAnalysisReceiptPath) -ceq `
        $expectedStaticAnalysisReceiptSha256 -and
    (Test-Digest $headerProofPath $expectedHeaderByteLength `
        $expectedHeaderSha256)
) 'phase3b2_epinel_header_closure_input_digest_invalid'

$expectedSqlite = @(
    @('epinelps.db', 4096L,
        '5c9dec1886cc01f5f2307ee1ea87f9b32a4cef0f8f9a2c68beebc558013bedab'),
    @('epinelps.db-shm', 32768L,
        'de6ae89a1aa32636e6c505ae130bbe2ab39809169c12394e706cbfcd2911eddd'),
    @('epinelps.db-wal', 111272L,
        '3c50fc9018637dcb0332cddeb2bffc7db8371584edc8669d7b5be2a1c51d4841')
)
for ($index = 0; $index -lt $sqlitePaths.Count; $index++) {
    Assert-True (
        (Split-Path -Leaf $sqlitePaths[$index]) -ceq `
            $expectedSqlite[$index][0] -and
        (Test-Digest $sqlitePaths[$index] `
            ([long]$expectedSqlite[$index][1]) `
            ([string]$expectedSqlite[$index][2]))
    ) 'phase3b2_epinel_header_closure_sqlite_digest_invalid'
}
foreach ($path in @($databasePath, $hostsPath) + $sqlitePaths) {
    Assert-True (Test-ExclusiveAccess $path) `
        'phase3b2_epinel_header_closure_target_file_in_use'
}

$pointer = Get-Content -LiteralPath $pointerPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$runStart = Get-Content -LiteralPath $runStartPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$binding = Get-Content -LiteralPath $bindingPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$projection = Get-Content -LiteralPath $projectionReceiptPath `
    -Raw -Encoding UTF8 | ConvertFrom-Json
$staticAnalysis = Get-Content -LiteralPath $staticAnalysisReceiptPath `
    -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True (
    $pointer.contractId -ceq `
        'nll/phase3b2-epinel-minimal-active-run-pointer/v1' -and
    $pointer.assessmentUid -ceq $FailedAssessmentUid -and
    $pointer.runStartReceiptSha256 -ceq $expectedFailedRunStartSha256 -and
    $runStart.contractId -ceq `
        'nll/phase3b2-epinel-minimal-reference-start/v1' -and
    $runStart.assessmentUid -ceq $FailedAssessmentUid -and
    $binding.contractId -ceq `
        'nll/phase3b2-epinel-native-cache-run-binding/v2' -and
    $binding.assessmentUid -ceq $FailedAssessmentUid -and
    $binding.activeCacheFileCount -eq $expectedCacheFileCountBefore -and
    [long]$binding.activeCacheContentByteLength -eq `
        $expectedCacheByteLengthBefore -and
    $projection.contractId -ceq `
        'nll/phase3b2-local-content-version-projection/v3' -and
    $projection.sourceRoleCode -ceq `
        'installed_client_serialized_content_version' -and
    $projection.projectedByteLength -eq $expectedHeaderByteLength -and
    $projection.projectedSha256 -ceq $expectedHeaderSha256 -and
    -not $projection.officialOutboundUsed -and
    $staticAnalysis.contractId -ceq `
        'nll/phase3b2-datapack-version-header-static-analysis/v1' -and
    $staticAnalysis.nativeFirstLineConsumedAsVersion -and
    $staticAnalysis.coreEntryPresentAfterHeader -and
    -not $staticAnalysis.officialOutboundUsed
) 'phase3b2_epinel_header_closure_contract_invalid'

$playerLogBytes = [IO.File]::ReadAllBytes($playerLogPath)
$playerLogText = [Text.Encoding]::UTF8.GetString($playerLogBytes)
Assert-True (
    $playerLogBytes.Length -eq 84681 -and
    (Get-Sha256Hex $playerLogPath) -ceq `
        'e12288a01f1bb952392a5a1d40e9352151d6bc2b99b5ae6466b8e1be74c87864' -and
    $playerLogText.Contains(
        'GetVersionAsync failed: https://cloud.nikke-kr.com/prdenv/' +
        '150-b059c3f36c/StandaloneWindows64/pck/latest-651.txt'
    ) -and
    $playerLogText.Contains('404 (Not Found)')
) 'phase3b2_epinel_header_closure_failure_evidence_invalid'

$beforeInspection = Invoke-CacheInspection `
    -DotnetPath $dotnetPath[0] -VerifierDllPath $verifierDllPath `
    -CacheRoot $cacheRoot
Assert-True (
    $beforeInspection.contractId -ceq `
        'nll/phase3b2-native-cache-tree-inspection/v1' -and
    $beforeInspection.longPathSafeEnumerationUsed -and
    $beforeInspection.fileCount -eq $expectedCacheFileCountBefore -and
    [long]$beforeInspection.contentByteLength -eq `
        $expectedCacheByteLengthBefore -and
    $beforeInspection.partialMemberCount -eq 0
) 'phase3b2_epinel_header_closure_cache_before_invalid'

$movedEntries = [Collections.Generic.List[object]]::new()
$createdPaths = [Collections.Generic.List[string]]::new()
$headerApplied = $false
$startReplaced = $false
$minimalStartReplaced = $false
try {
    New-Item -ItemType Directory -Path $stateBackupRoot,
        $repairEvidenceRoot, $protectedAssessmentRoot -Force | Out-Null

    Copy-Item -LiteralPath $activeStartToolPath `
        -Destination $priorStartBackupPath
    Copy-Item -LiteralPath $activeMinimalStartToolPath `
        -Destination $priorMinimalStartBackupPath

    foreach ($source in @($databasePath) + $sqlitePaths + @(
            $hostsPath, $pointerPath
        )) {
        $roleCode = switch (Split-Path -Leaf $source) {
            'db.json' { 'database.after.json' }
            'hosts' { 'hosts.applied.bin' }
            'active-run.pointer.json' { 'active-run.pointer.json' }
            default { Split-Path -Leaf $source }
        }
        $destination = Join-Path $stateBackupRoot $roleCode
        Move-Item -LiteralPath $source -Destination $destination
        $movedEntries.Add([pscustomobject]@{
                Source = $source
                Destination = $destination
            })
    }

    Copy-Item -LiteralPath $dbBeforePath -Destination $databasePath
    $createdPaths.Add($databasePath)
    Copy-Item -LiteralPath $hostsBeforePath -Destination $hostsPath
    $createdPaths.Add($hostsPath)
    Copy-Item -LiteralPath (Join-Path $stateBackupRoot `
            'active-run.pointer.json') -Destination $archivedPointerPath
    $createdPaths.Add($archivedPointerPath)
    $redactedServerLogMatchCount = Protect-ServerLog $stdoutPath

    New-Item -ItemType Directory -Path (Split-Path -Parent $headerPath) `
        -Force | Out-Null
    [IO.File]::WriteAllBytes(
        $headerPath,
        [IO.File]::ReadAllBytes($headerProofPath)
    )
    $createdPaths.Add($headerPath)
    $headerApplied = $true
    Assert-True (Test-Digest $headerPath $expectedHeaderByteLength `
            $expectedHeaderSha256) `
        'phase3b2_epinel_header_closure_header_apply_failed'

    $afterInspection = Invoke-CacheInspection `
        -DotnetPath $dotnetPath[0] -VerifierDllPath $verifierDllPath `
        -CacheRoot $cacheRoot
    Assert-True (
        $afterInspection.contractId -ceq `
            'nll/phase3b2-native-cache-tree-inspection/v1' -and
        $afterInspection.longPathSafeEnumerationUsed -and
        $afterInspection.fileCount -eq $expectedCacheFileCountAfter -and
        [long]$afterInspection.contentByteLength -eq `
            $expectedCacheByteLengthAfter -and
        $afterInspection.partialMemberCount -eq 0 -and
        (Test-Digest $databasePath 413327L `
            $expectedDatabaseBeforeSha256) -and
        @($sqlitePaths | Where-Object {
                Test-Path -LiteralPath $_
            }).Count -eq 0 -and
        (Test-Digest $hostsPath 1690L $expectedHostsBeforeSha256) -and
        -not (Test-Path -LiteralPath $pointerPath)
    ) 'phase3b2_epinel_header_closure_post_apply_invalid'

    $backupMembers = @(Get-ChildItem -LiteralPath $backupRoot -File `
        -Recurse | Sort-Object FullName)
    $backupLines = foreach ($file in $backupMembers) {
        $relative = $file.FullName.Substring($backupRoot.Length).
            TrimStart('\').Replace('\', '/')
        "$relative`t$($file.Length)`t$(Get-Sha256Hex $file.FullName)"
    }
    Write-AtomicUtf8NoBom $backupManifestPath `
        (($backupLines -join "`n") + "`n")

    $rollbackPlan = [ordered]@{
        schemaVersion = 1
        contractId = `
            'nll/phase3b2-epinel-native-cache-header-closure-rollback-plan/v1'
        failedAssessmentUid = $FailedAssessmentUid
        versionHeaderPathAtMicronBoot =
            'C:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\cache\' +
            $headerRelativePath.Replace('/', '\')
        versionHeaderPreviouslyPresent = $false
        priorStartToolPath = $priorStartBackupPath
        priorStartToolSha256 = $expectedPriorStartToolSha256
        priorMinimalStartToolPath = $priorMinimalStartBackupPath
        priorMinimalStartToolSha256 = $expectedPriorMinimalStartToolSha256
        rollbackCode = `
            'remove_header_restore_tools_then_recover_runtime_from_pinned_backup'
    }
    Write-AtomicUtf8NoBom $rollbackPlanPath `
        (($rollbackPlan | ConvertTo-Json -Depth 6) + "`n")

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = `
            'nll/phase3b2-epinel-native-cache-header-closure-repair/v1'
        repairedAtUtc = [DateTimeOffset]::UtcNow.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'"
        )
        failedAssessmentUid = $FailedAssessmentUid
        failureStageCode = 'catalogue_resource_path_upgrade'
        failureReasonCode = 'local_version_header_not_in_native_cache_closure'
        failedRunStartReceiptSha256 = $expectedFailedRunStartSha256
        failedNativeCacheBindingReceiptSha256 = $expectedFailedBindingSha256
        playerLogByteLength = $playerLogBytes.Length
        playerLogSha256 = Get-Sha256Hex $playerLogPath
        rawPlayerLogCopied = $false
        projectionReceiptSha256 = $expectedProjectionReceiptSha256
        staticAnalysisReceiptSha256 = $expectedStaticAnalysisReceiptSha256
        versionHeaderSourceCode = `
            'installed_client_serialized_content_version_offline_projection'
        versionHeaderRelativePath = $headerRelativePath
        versionHeaderByteLength = $expectedHeaderByteLength
        versionHeaderSha256 = $expectedHeaderSha256
        versionHeaderApplied = $true
        activeCacheFileCountBefore = $expectedCacheFileCountBefore
        activeCacheContentByteLengthBefore = $expectedCacheByteLengthBefore
        activeCacheFileCountAfter = $expectedCacheFileCountAfter
        activeCacheContentByteLengthAfter = $expectedCacheByteLengthAfter
        activeCacheLongPathInspectionVerified = $true
        cacheRecopyPerformed = $false
        databaseRestored = $true
        sqliteRuntimeRemoved = $true
        hostsRestored = $true
        activeRunPointerArchived = $true
        redactedServerLogMatchCount = $redactedServerLogMatchCount
        rawSensitiveServerLogPersisted = $false
        backupManifestByteLength = (Get-Item $backupManifestPath).Length
        backupManifestSha256 = Get-Sha256Hex $backupManifestPath
        rollbackPlanByteLength = (Get-Item $rollbackPlanPath).Length
        rollbackPlanSha256 = Get-Sha256Hex $rollbackPlanPath
        targetOsOfflineDuringRepair = $true
        existingOperatorCacheInspected = $false
        existingOperatorCacheModified = $false
        officialOutboundUsed = $false
        officialApiUsed = $false
        officialLoginUsed = $false
        officialIdentityPersisted = $false
        officialCredentialPersisted = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        nextStepCode = `
            'bind_header_preflight_tools_before_micron_retry'
    }
    $receiptText = ($receipt | ConvertTo-Json -Depth 7) + "`n"
    Write-AtomicUtf8NoBom $repairReceiptPath $receiptText
    $createdPaths.Add($repairReceiptPath)
    Copy-Item -LiteralPath $repairReceiptPath `
        -Destination $protectedReceiptPath
    $createdPaths.Add($protectedReceiptPath)
    Write-AtomicUtf8NoBom $offlineCompletionPath $receiptText
    $createdPaths.Add($offlineCompletionPath)
    $repairReceiptSha256 = Get-Sha256Hex $repairReceiptPath

    $templateText = Get-Content -LiteralPath $nativeStartTemplatePath `
        -Raw -Encoding UTF8
    $deploymentPlaceholder =
        '__NATIVE_CACHE_DEPLOYMENT_RECEIPT_SHA256__'
    $verifierPlaceholder =
        '__NATIVE_CACHE_VERIFIER_MANIFEST_SHA256__'
    $headerPlaceholder =
        '__NATIVE_CACHE_HEADER_CLOSURE_RECEIPT_SHA256__'
    Assert-True (
        ([regex]::Matches($templateText,
            [regex]::Escape($deploymentPlaceholder))).Count -eq 1 -and
        ([regex]::Matches($templateText,
            [regex]::Escape($verifierPlaceholder))).Count -eq 1 -and
        ([regex]::Matches($templateText,
            [regex]::Escape($headerPlaceholder))).Count -eq 1
    ) 'phase3b2_epinel_header_closure_start_template_invalid'
    $boundStartText = $templateText.
        Replace($deploymentPlaceholder, $expectedDeploymentReceiptSha256).
        Replace($verifierPlaceholder, $expectedVerifierManifestSha256).
        Replace($headerPlaceholder, $repairReceiptSha256)
    $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseInput(
        $boundStartText,
        [ref]$null,
        [ref]$parseErrors
    ) | Out-Null
    Assert-True (@($parseErrors).Count -eq 0) `
        'phase3b2_epinel_header_closure_bound_start_parse_failed'

    Copy-Item -LiteralPath $minimalStartTemplatePath `
        -Destination $activeMinimalStartToolPath -Force
    $minimalStartReplaced = $true
    Write-AtomicUtf8NoBom $activeStartToolPath $boundStartText
    $startReplaced = $true

    $toolBinding = [ordered]@{
        schemaVersion = 1
        contractId = `
            'nll/phase3b2-epinel-native-cache-header-closure-tool-binding/v1'
        boundAtUtc = [DateTimeOffset]::UtcNow.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'"
        )
        repairReceiptSha256 = $repairReceiptSha256
        deploymentReceiptSha256 = $expectedDeploymentReceiptSha256
        verifierManifestSha256 = $expectedVerifierManifestSha256
        priorStartToolSha256 = $expectedPriorStartToolSha256
        boundStartToolByteLength = (Get-Item $activeStartToolPath).Length
        boundStartToolSha256 = Get-Sha256Hex $activeStartToolPath
        priorMinimalStartToolSha256 = $expectedPriorMinimalStartToolSha256
        boundMinimalStartToolByteLength = `
            (Get-Item $activeMinimalStartToolPath).Length
        boundMinimalStartToolSha256 = `
            Get-Sha256Hex $activeMinimalStartToolPath
        localHttpPreflightEnabled = $true
        localHttpPreflightBoundaryCode = `
            'server_listener_ready_before_bootstrap_and_original_client_start'
        localHttpPreflightExpectedStatusCode = 200
        localHttpPreflightExpectedByteLength = $expectedHeaderByteLength
        localHttpPreflightExpectedSha256 = $expectedHeaderSha256
        targetOsOfflineDuringToolBinding = $true
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        nextStepCode = `
            'boot_micron_nlloperator_run_epinel_native_cache_header_retry_once'
    }
    $toolBindingText = ($toolBinding | ConvertTo-Json -Depth 7) + "`n"
    Write-AtomicUtf8NoBom $toolBindingReceiptPath $toolBindingText
    $createdPaths.Add($toolBindingReceiptPath)
    Copy-Item -LiteralPath $toolBindingReceiptPath `
        -Destination $protectedToolBindingReceiptPath
    $createdPaths.Add($protectedToolBindingReceiptPath)

    Assert-True (
        (Test-Digest $headerPath $expectedHeaderByteLength `
            $expectedHeaderSha256) -and
        (Get-Sha256Hex $repairReceiptPath) -ceq $repairReceiptSha256 -and
        (Get-Sha256Hex $activeMinimalStartToolPath) -ceq `
            (Get-Sha256Hex $minimalStartTemplatePath) -and
        -not (Test-Path -LiteralPath $pointerPath) -and
        @($sqlitePaths | Where-Object {
                Test-Path -LiteralPath $_
            }).Count -eq 0
    ) 'phase3b2_epinel_header_closure_final_verification_failed'

    [pscustomobject]@{
        Receipt = $receipt
        ReceiptPath = $repairReceiptPath
        ReceiptByteLength = (Get-Item $repairReceiptPath).Length
        ReceiptSha256 = $repairReceiptSha256
        ToolBindingReceiptPath = $toolBindingReceiptPath
        ToolBindingReceiptByteLength = `
            (Get-Item $toolBindingReceiptPath).Length
        ToolBindingReceiptSha256 = Get-Sha256Hex $toolBindingReceiptPath
        MicronStartCommand =
            "& 'C:\NLL\Tools\Start-Phase3B2-Epinel-NativeCache.ps1'"
    } | ConvertTo-Json -Depth 9
}
catch {
    if ($startReplaced -and
        (Test-Path -LiteralPath $priorStartBackupPath -PathType Leaf)) {
        Copy-Item -LiteralPath $priorStartBackupPath `
            -Destination $activeStartToolPath -Force
    }
    if ($minimalStartReplaced -and
        (Test-Path -LiteralPath $priorMinimalStartBackupPath -PathType Leaf)) {
        Copy-Item -LiteralPath $priorMinimalStartBackupPath `
            -Destination $activeMinimalStartToolPath -Force
    }
    if ($headerApplied -and (Test-Path -LiteralPath $headerPath)) {
        Remove-Item -LiteralPath $headerPath -Force
    }
    for ($index = $createdPaths.Count - 1; $index -ge 0; $index--) {
        $created = $createdPaths[$index]
        if (Test-Path -LiteralPath $created -PathType Leaf) {
            Remove-Item -LiteralPath $created -Force
        }
    }
    for ($index = $movedEntries.Count - 1; $index -ge 0; $index--) {
        $entry = $movedEntries[$index]
        if (Test-Path -LiteralPath $entry.Source -PathType Leaf) {
            Remove-Item -LiteralPath $entry.Source -Force
        }
        if (Test-Path -LiteralPath $entry.Destination -PathType Leaf) {
            Move-Item -LiteralPath $entry.Destination `
                -Destination $entry.Source -Force
        }
    }
    throw
}
