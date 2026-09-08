[CmdletBinding()]
param(
    [ValidatePattern('^[A-Z]$')]
    [string]$MicronDriveLetter = 'E',
    [string]$FailedAssessmentUid =
        '33edfa6a-9b3c-408d-898a-88c9cf34baee',
    [string]$ProtectedRoot =
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\EpinelNativeCacheCatalogTransport-v1'
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
    return (Get-Item -LiteralPath $Path).Length -eq $ByteLength -and
        (Get-Sha256Hex $Path) -ceq $Sha256
}

function Test-ExclusiveAccess {
    param([string]$Path)
    try {
        $stream = [IO.File]::Open(
            $Path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
            [IO.FileShare]::None
        )
        $stream.Dispose()
        return $true
    }
    catch { return $false }
}

function Write-AtomicUtf8NoBom {
    param([string]$Path, [string]$Text)
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $temporary = $Path + '.partial-' + [Guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText(
        $temporary, $Text, [Text.UTF8Encoding]::new($false)
    )
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Copy-ExactFile {
    param([string]$Source, [string]$Destination)
    $parent = Split-Path -Parent $Destination
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    Assert-True ((Get-Item -LiteralPath $Source).Length -eq
            (Get-Item -LiteralPath $Destination).Length -and
        (Get-Sha256Hex $Source) -ceq (Get-Sha256Hex $Destination)) `
        'phase3b2_epinel_catalog_transport_copy_failed'
}

function Protect-ServerLog {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 0 }
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    $pattern = '(?m)^(?<prefix>\s*authtoken:\s*)\S+\s*$'
    $count = [regex]::Matches($text, $pattern).Count
    if ($count -gt 0) {
        Write-AtomicUtf8NoBom $Path ([regex]::Replace(
                $text, $pattern, '${prefix}[REDACTED]'
            ))
    }
    return $count
}

$expectedPointerSha256 =
    'd62579e1d370e6c9981a7782c314540cffb2da41bf1a4e905b1b9f34a95eb12b'
$expectedRunStartSha256 =
    'ef9b5fb8af18c421e54ee0248fbfce04cbe49d2da29f87934e04638ff8fec56f'
$expectedBindingSha256 =
    '1e90a47a540de4a926e0243c2308bcbff4a930b63632adf5e157cda53bd7cf0a'
$expectedDatabaseBeforeSha256 =
    'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194'
$expectedDatabaseAfterSha256 =
    'e524a3c8967af6bb8447fda0c50fc8a86ebccd02e1d1a45df73b2625430acc8d'
$expectedHostsBeforeSha256 =
    'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0'
$expectedHostsAfterSha256 =
    '3b0dcc4396373e9e9d623ef05c345f89330427ad5128727290c9f76138e22f64'
$expectedPlayerLogSha256 =
    'e0f3dc129cb76865c4842ff1b0e0b39477da17bf4caa23723cbeb1861eccea1f'
$expectedPriorServerDllSha256 =
    'ba46ae42b59c2058c7c8e5b02e31af1fe32a28e70d685f3a470e63adefc60cfc'
$expectedPriorWrapperSha256 =
    '1c9c053508e093df2ed3febb8e0d57ad39d5bb6b1ce2c8b96a782c35ea8874a7'
$expectedPriorMinimalStartSha256 =
    '695a65a2ba64e07706dd95da28fcfcd197b9b584fb9f581b3a22953a5d758ea7'
$expectedSourceServerDllSha256 =
    'aaa1e49d7a879a6b5ec17ad4c4094ce7d98ce86f860c1529a9ab4d6aecb51f7c'
$expectedProbeSha256 =
    '8505cdae029149993cd4dd8937583b97bed3f615ee778639e1d7ce6665bcbf2b'
$expectedSourceMinimalStartSha256 =
    '385b5c41c1102e67cb31cd5372462933d22e0c7d26fda8b5dde659ec3637e5c9'
$expectedWrapperTemplateSha256 =
    '73ec1c40ab8393f38f89aef1b9df1bad31192ba1bfbf70dc61c1bad0c7284b4f'
$expectedExternalHead = 'aa01ad90b807be1c2ceffe958519cb529622d472'
$expectedExternalTree = 'c324c11d32365b1524f266cba6bc014e89545204'
$expectedHeaderClosureReceiptSha256 =
    'bc5e9e0f8f45f17c4db0408cee3d8a88389e11d1578670e9733a2563535444ce'
$expectedDeploymentReceiptSha256 =
    '14bf845aec4cded1d80e8efb57a3eb4f4639ef68bd1fdf7a8d9de462689aae7d'
$expectedVerifierManifestSha256 =
    '3305d52786315bc927c46cdb988ce35b067d704f0a562be7aa469a188da3541c'

$micronDrive = $MicronDriveLetter + ':'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
Assert-True ($principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    'phase3b2_epinel_catalog_transport_repair_requires_administrator'
$systemDisk = Get-Partition -DriveLetter C | Get-Disk
$micronDisk = Get-Partition -DriveLetter $MicronDriveLetter | Get-Disk
Assert-True ($env:SystemDrive -ceq 'C:' -and
    $systemDisk.FriendlyName -like 'Samsung SSD 980*' -and
    $systemDisk.IsBoot -and $systemDisk.IsSystem -and
    $micronDisk.FriendlyName -like 'Micron_2200*' -and
    -not $micronDisk.IsBoot -and -not $micronDisk.IsSystem -and
    (Test-Path -LiteralPath (Join-Path $micronDrive 'Windows\System32') `
        -PathType Container)) `
    'phase3b2_epinel_catalog_transport_repair_wrong_disk_boundary'
$runtimeNames = @('EpinelPS', 'nikke', 'nikke_launcher',
    'NikkeLocalLab.Phase3B2.PhysicalBootstrap')
Assert-True (@(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $runtimeNames -contains $_.ProcessName
        }).Count -eq 0) `
    'phase3b2_epinel_catalog_transport_repair_runtime_not_cold'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$externalRoot = Join-Path $repositoryRoot '.external\EpinelPS'
$sourceServerDll = Join-Path $externalRoot `
    'EpinelPS\bin\Release\net10.0\win-x64\EpinelPS.dll'
$sourceProbeDll = Join-Path $externalRoot `
    'tools\Phase3B2.CatalogTransportProbe\bin\Release\net10.0\Phase3B2.CatalogTransportProbe.dll'
$sourceMinimalStart = Join-Path $repositoryRoot `
    'scripts\start-phase3b2-epinel-minimal-reference-in-micron.ps1'
$sourceWrapperTemplate = Join-Path $repositoryRoot `
    'scripts\Start-Phase3B2-Epinel-NativeCache-CatalogTransport.ps1'
$dotnetPath = Join-Path $micronDrive 'Program Files\dotnet\dotnet.exe'

Assert-True ((Test-Digest $sourceServerDll 15366144L `
        $expectedSourceServerDllSha256) -and
    (Test-Digest $sourceProbeDll 17920L $expectedProbeSha256) -and
    (Test-Digest $sourceMinimalStart 33053L `
        $expectedSourceMinimalStartSha256) -and
    (Test-Digest $sourceWrapperTemplate 11916L `
        $expectedWrapperTemplateSha256) -and
    (Test-Path -LiteralPath $dotnetPath -PathType Leaf)) `
    'phase3b2_epinel_catalog_transport_repair_source_input_invalid'
foreach ($path in @($sourceMinimalStart, $sourceWrapperTemplate)) {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        $path, [ref]$tokens, [ref]$parseErrors
    )
    Assert-True (@($parseErrors).Count -eq 0) `
        'phase3b2_epinel_catalog_transport_repair_source_parse_failed'
}

$gitCandidates = @(
    'C:\Program Files\Git\cmd\git.exe',
    'E:\Program Files\Git\cmd\git.exe'
)
$gitPath = @($gitCandidates | Where-Object {
        Test-Path -LiteralPath $_ -PathType Leaf
    } | Select-Object -First 1)
Assert-True ($gitPath.Count -eq 1) `
    'phase3b2_epinel_catalog_transport_repair_git_missing'
$safeExternalRoot = [IO.Path]::GetFullPath($externalRoot).Replace('\', '/')
$externalHead = (& $gitPath[0] -c "safe.directory=$safeExternalRoot" `
    -C $externalRoot rev-parse HEAD).Trim()
$externalTree = (& $gitPath[0] -c "safe.directory=$safeExternalRoot" `
    -C $externalRoot rev-parse 'HEAD^{tree}').Trim()
$externalStatus = @(& $gitPath[0] -c "safe.directory=$safeExternalRoot" `
    -C $externalRoot status --porcelain=v1 --untracked-files=all)
Assert-True ($externalHead -ceq $expectedExternalHead -and
    $externalTree -ceq $expectedExternalTree -and
    $externalStatus.Count -eq 0) `
    'phase3b2_epinel_catalog_transport_repair_external_checkout_invalid'

$serverRoot = Join-Path $micronDrive `
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
$cacheRoot = Join-Path $serverRoot 'cache'
$targetServerDll = Join-Path $serverRoot 'EpinelPS.dll'
$databasePath = Join-Path $serverRoot 'db.json'
$sqlitePaths = @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal' |
    ForEach-Object { Join-Path $serverRoot $_ })
$hostsPath = Join-Path $micronDrive 'Windows\System32\drivers\etc\hosts'
$targetWrapper = Join-Path $micronDrive `
    'NLL\Tools\Start-Phase3B2-Epinel-NativeCache.ps1'
$targetMinimalStart = Join-Path $micronDrive `
    'NLL\Tools\start-phase3b2-epinel-minimal-reference-in-micron.ps1'
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
    'active-run.pointer.archived-catalog-transport.json'
$playerLogPath = Join-Path $micronDrive `
    'Users\nlloperator\AppData\LocalLow\com.proximabeta\NIKKE\Player.log'
$sideCatalogPath = Join-Path $micronDrive `
    'NLL\Clients\NIKKE-150.6.9-Physical\Unity\com_proximabeta_NIKKE\saus\saus\asset-catalog-0.cat'
$deploymentReceiptPath = Join-Path $micronDrive `
    'NLL\Evidence\Phase3B2\Physical\epinel-native-cache-deployment-v1\deployment.receipt.json'
$verifierManifestPath = Join-Path $micronDrive `
    'NLL\Tools\Phase3B2.NativeCacheVerifier-v1\bundle.manifest.json'
$headerClosureReceiptPath = Join-Path $micronDrive `
    'NLL\Evidence\Phase3B2\Physical\epinel-native-cache-header-closure-v1\repair.receipt.json'
$repairRoot = Join-Path $micronDrive `
    'NLL\Evidence\Phase3B2\Physical\epinel-native-cache-catalog-transport-v1'
$repairReceiptPath = Join-Path $repairRoot 'repair.receipt.json'
$catalogContractPath = Join-Path $repairRoot 'catalog-transport.contract.json'
$toolBindingPath = Join-Path $repairRoot 'tool-binding.receipt.json'
$rollbackPlanPath = Join-Path $repairRoot 'rollback-plan.json'
$backupRoot = Join-Path $micronDrive `
    'NLL\Backups\Phase3B2\EpinelNativeCacheCatalogTransport-v1'
$backupManifestPath = Join-Path $backupRoot 'backup.manifest.json'

Assert-True ((Test-Digest $pointerPath 874L $expectedPointerSha256) -and
    (Test-Digest $runStartPath 2142L $expectedRunStartSha256) -and
    (Test-Digest $bindingPath 1320L $expectedBindingSha256) -and
    (Test-Digest $dbBeforePath 413327L $expectedDatabaseBeforeSha256) -and
    (Test-Digest $hostsBeforePath 1690L $expectedHostsBeforeSha256) -and
    (Test-Digest $databasePath 413329L $expectedDatabaseAfterSha256) -and
    (Test-Digest $hostsPath 1727L $expectedHostsAfterSha256) -and
    (Test-Digest $targetServerDll 15364096L `
        $expectedPriorServerDllSha256) -and
    (Test-Digest $targetWrapper 10462L $expectedPriorWrapperSha256) -and
    (Test-Digest $targetMinimalStart 25588L `
        $expectedPriorMinimalStartSha256) -and
    (Test-Digest $stdoutPath 7038L `
        '7bd0ac435ff3607b653e45ac688fa89bf285b54cb842448fd7f40acb1dd39c4b') -and
    (Test-Digest $stderrPath 0L `
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855') -and
    (Test-Digest $deploymentReceiptPath 3537L `
        $expectedDeploymentReceiptSha256) -and
    (Get-Sha256Hex $verifierManifestPath) -ceq
        $expectedVerifierManifestSha256 -and
    (Get-Sha256Hex $headerClosureReceiptPath) -ceq
        $expectedHeaderClosureReceiptSha256 -and
    -not (Test-Path -LiteralPath $archivedPointerPath) -and
    -not (Test-Path -LiteralPath $repairRoot) -and
    -not (Test-Path -LiteralPath $backupRoot) -and
    -not (Test-Path -LiteralPath $ProtectedRoot)) `
    'phase3b2_epinel_catalog_transport_repair_runtime_evidence_invalid'

$pointer = Get-Content -LiteralPath $pointerPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$runStart = Get-Content -LiteralPath $runStartPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$binding = Get-Content -LiteralPath $bindingPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($pointer.contractId -ceq
        'nll/phase3b2-epinel-minimal-active-run-pointer/v1' -and
    $pointer.assessmentUid -ceq $FailedAssessmentUid -and
    $pointer.runStartReceiptSha256 -ceq $expectedRunStartSha256 -and
    $runStart.contractId -ceq
        'nll/phase3b2-epinel-minimal-reference-start/v1' -and
    $runStart.assessmentUid -ceq $FailedAssessmentUid -and
    $runStart.requiredLocalAssetPreflightPerformed -and
    $runStart.requiredLocalAssetHttpStatusCode -eq 200 -and
    $binding.contractId -ceq
        'nll/phase3b2-epinel-native-cache-run-binding/v3' -and
    $binding.assessmentUid -ceq $FailedAssessmentUid -and
    $binding.headerClosureReceiptSha256 -ceq
        $expectedHeaderClosureReceiptSha256) `
    'phase3b2_epinel_catalog_transport_repair_runtime_contract_invalid'

Assert-True ((Test-Digest $playerLogPath 40711L $expectedPlayerLogSha256) -and
    (Test-ExclusiveAccess $playerLogPath)) `
    'phase3b2_epinel_catalog_transport_repair_player_log_invalid'
$playerLogText = [IO.File]::ReadAllText($playerLogPath, [Text.Encoding]::UTF8)
Assert-True ($playerLogText.Contains(
        'SQLiteException: database disk image is malformed') -and
    $playerLogText.Contains('Retry loading catalog') -and
    -not $playerLogText.Contains('latest-651.txt') -and
    -not $playerLogText.Contains('404 (Not Found)')) `
    'phase3b2_epinel_catalog_transport_repair_failure_marker_invalid'

$sideCatalogPresent = Test-Path -LiteralPath $sideCatalogPath -PathType Leaf
$sideCatalogByteLength = if ($sideCatalogPresent) {
    (Get-Item -LiteralPath $sideCatalogPath).Length
} else { 0L }
$sideCatalogSha256 = if ($sideCatalogPresent) {
    Get-Sha256Hex $sideCatalogPath
} else { '' }
Assert-True ($sideCatalogPresent -and $sideCatalogByteLength -eq 0L -and
    $sideCatalogSha256 -ceq
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855') `
    'phase3b2_epinel_catalog_transport_repair_side_catalog_shape_invalid'

$catalogDefinitions = @(
    [ordered]@{
        roleCode = 'core'
        relativePath = 'prdenv\150-b059c3f36c\StandaloneWindows64\pck\core\150.6.b15\catalog.db'
        encryptedByteLength = 10552026L
        encryptedSha256 = 'a1dc8425ca034447a1e495d02f02e10fcbf92a772453aebfc214c3a88dd21d52'
        decryptedByteLength = 24707072L
        decryptedSha256 = 'a9129fdade089805b23b389801e300921d52a7bf10a3fb4fa43d66a41ae23804'
        signatureSha256 = '9c1ea4e701f0ca770d95dfa4607af233b2d7123cd1d3db6897155f107740f966'
    },
    [ordered]@{
        roleCode = 'dp'
        relativePath = 'prdenv\150-b059c3f36c\StandaloneWindows64\pck\dp\1d5645e\catalog.db'
        encryptedByteLength = 8630492L
        encryptedSha256 = '326c029414ccf06ff429dd2e017a8bbae6dc39fd295682c67f333a8611a6e5cb'
        decryptedByteLength = 19005440L
        decryptedSha256 = '8616dbff5eeadaf7326a6e9c64c7a4983ca2d591b52ee2c299d1ffe37493b306'
        signatureSha256 = '16b319314a4ba278e9ae229b51f7ec462819a6566c595050ccf55e2f1b7fbfbc'
    },
    [ordered]@{
        roleCode = 'fd'
        relativePath = 'prdenv\150-b059c3f36c\StandaloneWindows64\pck\fd\85b12fc\catalog.db'
        encryptedByteLength = 337379L
        encryptedSha256 = 'af0307449ddb4455357c7d2e4e9bf363f5bb2d4a8615e11e37939629b2acc04c'
        decryptedByteLength = 1310720L
        decryptedSha256 = '81e120aebfb192355e56d1aad8e50317c7ca38d40b52e58c862a09c1c33fa502'
        signatureSha256 = '876618c9a45663c60b09683f6c090b952edc76b7e9c9997d13085e30e8d9427c'
    }
)
$bodyPaths = @()
foreach ($definition in $catalogDefinitions) {
    $bodyPath = Join-Path $cacheRoot $definition.relativePath
    $signaturePath = $bodyPath + '.nds'
    Assert-True ((Test-Digest $bodyPath `
            ([long]$definition.encryptedByteLength) `
            ([string]$definition.encryptedSha256)) -and
        (Test-Digest $signaturePath 96L `
            ([string]$definition.signatureSha256))) `
        'phase3b2_epinel_catalog_transport_repair_catalog_member_invalid'
    $bodyPaths += $bodyPath
}
$probeOutput = & $dotnetPath $sourceProbeDll $bodyPaths[0] $bodyPaths[1] `
    $bodyPaths[2] 2>&1
Assert-True ($LASTEXITCODE -eq 0) `
    'phase3b2_epinel_catalog_transport_repair_probe_failed'
$probe = (($probeOutput | Out-String) | ConvertFrom-Json)
Assert-True ($probe.contractId -ceq
        'nll/phase3b2-catalog-transport-probe/v1' -and
    $probe.memberCount -eq 3 -and $probe.allEncryptedNkdb -and
    $probe.allDecryptedSqlite -and -not $probe.rawContentEmitted) `
    'phase3b2_epinel_catalog_transport_repair_probe_contract_invalid'
foreach ($definition in $catalogDefinitions) {
    $member = @($probe.members | Where-Object {
            $_.roleCode -ceq $definition.roleCode
        })
    Assert-True ($member.Count -eq 1 -and
        [long]$member[0].encryptedByteLength -eq
            [long]$definition.encryptedByteLength -and
        $member[0].encryptedSha256 -ceq $definition.encryptedSha256 -and
        $member[0].encryptedNkdbMagicVerified -and
        [long]$member[0].decryptedByteLength -eq
            [long]$definition.decryptedByteLength -and
        $member[0].decryptedSha256 -ceq $definition.decryptedSha256 -and
        $member[0].decryptedSqliteHeaderVerified) `
        'phase3b2_epinel_catalog_transport_repair_probe_member_invalid'
}

$existingSqlite = @($sqlitePaths | Where-Object {
        Test-Path -LiteralPath $_ -PathType Leaf
    })
Assert-True ($existingSqlite.Count -eq 1 -and
    (Test-Digest $existingSqlite[0] 36864L `
        'bda14664b52c480ad7b5c7b4ab4693919c10bf2e030ff93f3483e4582c8f3483')) `
    'phase3b2_epinel_catalog_transport_repair_sqlite_state_invalid'
foreach ($path in @($databasePath, $hostsPath, $pointerPath) +
    $existingSqlite) {
    Assert-True (Test-ExclusiveAccess $path) `
        'phase3b2_epinel_catalog_transport_repair_target_in_use'
}

$createdRootPaths = @()
$mutated = $false
try {
    New-Item -ItemType Directory -Path $repairRoot, $backupRoot,
        $ProtectedRoot -Force | Out-Null
    $createdRootPaths = @($repairRoot, $backupRoot, $ProtectedRoot)

    $backupTargets = [ordered]@{
        server_dll = @($targetServerDll, 'server\EpinelPS.dll')
        wrapper_tool = @($targetWrapper, 'tools\Start-Phase3B2-Epinel-NativeCache.ps1')
        minimal_start_tool = @($targetMinimalStart,
            'tools\start-phase3b2-epinel-minimal-reference-in-micron.ps1')
        database_after = @($databasePath, 'runtime\db.after.json')
        hosts_applied = @($hostsPath, 'runtime\hosts.applied.bin')
        active_pointer = @($pointerPath, 'runtime\active-run.pointer.json')
        sqlite_main = @($existingSqlite[0], 'runtime\epinelps.db')
    }
    $backupMembers = @()
    foreach ($roleCode in $backupTargets.Keys) {
        $source = [string]$backupTargets[$roleCode][0]
        $relative = [string]$backupTargets[$roleCode][1]
        $destination = Join-Path $backupRoot $relative
        Copy-ExactFile $source $destination
        $backupMembers += [ordered]@{
            roleCode = $roleCode
            relativePath = $relative.Replace('\', '/')
            byteLength = (Get-Item -LiteralPath $destination).Length
            sha256 = Get-Sha256Hex $destination
        }
    }
    $backupManifest = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-native-cache-catalog-transport-backup-manifest/v1'
        failedAssessmentUid = $FailedAssessmentUid
        memberCount = $backupMembers.Count
        members = $backupMembers
        rawPlayerLogCopied = $false
        rawDecryptedCatalogPersisted = $false
    }
    Write-AtomicUtf8NoBom $backupManifestPath `
        (($backupManifest | ConvertTo-Json -Depth 7) + "`n")

    # From this point onward every write is covered by the sealed backup.
    $mutated = $true
    Copy-ExactFile $dbBeforePath $databasePath
    foreach ($path in $existingSqlite) {
        Remove-Item -LiteralPath $path -Force
    }
    Copy-ExactFile $hostsBeforePath $hostsPath
    Copy-ExactFile $pointerPath $archivedPointerPath
    Remove-Item -LiteralPath $pointerPath -Force
    $redactedServerLogMatchCount = Protect-ServerLog $stdoutPath
    Copy-ExactFile $sourceServerDll $targetServerDll
    Copy-ExactFile $sourceMinimalStart $targetMinimalStart

    $contractMembers = foreach ($definition in $catalogDefinitions) {
        $urlPath = ([string]$definition.relativePath).Replace('\', '/')
        [ordered]@{
            roleCode = [string]$definition.roleCode
            bodyUrl = 'https://cloud.nikke-kr.com/' + $urlPath
            encryptedByteLength = [long]$definition.encryptedByteLength
            encryptedSha256 = [string]$definition.encryptedSha256
            decryptedByteLength = [long]$definition.decryptedByteLength
            decryptedSha256 = [string]$definition.decryptedSha256
            signatureUrl = 'https://cloud.nikke-kr.com/' + $urlPath + '.nds'
            signatureByteLength = 96L
            signatureSha256 = [string]$definition.signatureSha256
        }
    }
    $catalogContract = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-native-cache-catalog-transport-contract/v1'
        createdAtUtc = [DateTimeOffset]::UtcNow.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'"
        )
        externalHead = $externalHead
        externalTree = $externalTree
        serverDllByteLength = (Get-Item -LiteralPath $sourceServerDll).Length
        serverDllSha256 = Get-Sha256Hex $sourceServerDll
        memberCount = $contractMembers.Count
        members = $contractMembers
        projectionScopeCode = 'local_only_catalog_db_nkdb_magic_only'
        signaturesProjected = $false
        rawDecryptedCatalogPersisted = $false
        preflightBoundaryCode =
            'all_three_catalog_bodies_and_signatures_before_original_client_start'
    }
    Write-AtomicUtf8NoBom $catalogContractPath `
        (($catalogContract | ConvertTo-Json -Depth 7) + "`n")
    $catalogContractSha256 = Get-Sha256Hex $catalogContractPath

    $rollbackPlan = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-native-cache-catalog-transport-rollback-plan/v1'
        failedAssessmentUid = $FailedAssessmentUid
        backupRootAtMicronBoot =
            'C:\NLL\Backups\Phase3B2\EpinelNativeCacheCatalogTransport-v1'
        restoreMemberCount = $backupMembers.Count
        removeEvidenceRootAtMicronBoot =
            'C:\NLL\Evidence\Phase3B2\Physical\epinel-native-cache-catalog-transport-v1'
        rollbackCode =
            'restore_seven_pinned_members_remove_catalog_transport_evidence'
    }
    Write-AtomicUtf8NoBom $rollbackPlanPath `
        (($rollbackPlan | ConvertTo-Json -Depth 6) + "`n")

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-native-cache-catalog-transport-repair/v1'
        repairedAtUtc = [DateTimeOffset]::UtcNow.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'"
        )
        failedAssessmentUid = $FailedAssessmentUid
        failureStageCode = 'catalogue_resource_path_upgrade'
        failureReasonCode = 'encrypted_nkdb_served_as_sqlite_catalog_db'
        priorHeaderFailureAbsent = $true
        headerLoopbackPreflightPreviouslyPassed = $true
        failedRunStartReceiptSha256 = $expectedRunStartSha256
        failedNativeCacheBindingReceiptSha256 = $expectedBindingSha256
        playerLogByteLength = 40711L
        playerLogSha256 = $expectedPlayerLogSha256
        playerLogMalformedSqliteObserved = $true
        playerLogCatalogRetryObserved = $true
        rawPlayerLogCopied = $false
        sideCatalogInspectedReadOnly = $true
        sideCatalogByteLength = $sideCatalogByteLength
        sideCatalogSha256 = $sideCatalogSha256
        sideCatalogMutationPerformed = $false
        encryptedCatalogBodyCount = 3
        decryptedSqliteBodyCount = 3
        signatureMemberCount = 3
        catalogTransportContractByteLength =
            (Get-Item -LiteralPath $catalogContractPath).Length
        catalogTransportContractSha256 = $catalogContractSha256
        catalogProjectionScopeCode =
            'local_only_catalog_db_nkdb_magic_only'
        rawDecryptedCatalogPersisted = $false
        externalHead = $externalHead
        externalTree = $externalTree
        externalCheckoutClean = $true
        selectedManagerPassedCount = 65
        handlerIsolationPassedCount = 6
        appliedServerDllByteLength =
            (Get-Item -LiteralPath $targetServerDll).Length
        appliedServerDllSha256 = Get-Sha256Hex $targetServerDll
        appliedMinimalStartToolByteLength =
            (Get-Item -LiteralPath $targetMinimalStart).Length
        appliedMinimalStartToolSha256 = Get-Sha256Hex $targetMinimalStart
        wrapperTemplateByteLength =
            (Get-Item -LiteralPath $sourceWrapperTemplate).Length
        wrapperTemplateSha256 = Get-Sha256Hex $sourceWrapperTemplate
        databaseRestored = $true
        sqliteRuntimeRemoved = $true
        hostsRestored = $true
        activeRunPointerArchived = $true
        redactedServerLogMatchCount = $redactedServerLogMatchCount
        rawSensitiveServerLogPersisted = $false
        backupManifestByteLength =
            (Get-Item -LiteralPath $backupManifestPath).Length
        backupManifestSha256 = Get-Sha256Hex $backupManifestPath
        rollbackPlanByteLength =
            (Get-Item -LiteralPath $rollbackPlanPath).Length
        rollbackPlanSha256 = Get-Sha256Hex $rollbackPlanPath
        targetOsOfflineDuringRepair = $true
        cacheMutationPerformed = $false
        clientInstallMutationPerformed = $false
        existingOperatorCacheInspected = $false
        existingOperatorCacheModified = $false
        officialOutboundUsed = $false
        officialApiUsed = $false
        officialLoginUsed = $false
        officialIdentityPersisted = $false
        officialCredentialPersisted = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        singleCatalogTransportRetryAuthorized = $true
        retryConsumed = $false
        nextStepCode =
            'bind_catalog_transport_preflight_then_boot_micron_once'
    }
    Write-AtomicUtf8NoBom $repairReceiptPath `
        (($receipt | ConvertTo-Json -Depth 8) + "`n")
    $repairReceiptSha256 = Get-Sha256Hex $repairReceiptPath

    $templateText = Get-Content -LiteralPath $sourceWrapperTemplate -Raw `
        -Encoding UTF8
    $replacements = [ordered]@{
        '__NATIVE_CACHE_DEPLOYMENT_RECEIPT_SHA256__' =
            $expectedDeploymentReceiptSha256
        '__NATIVE_CACHE_VERIFIER_MANIFEST_SHA256__' =
            $expectedVerifierManifestSha256
        '__NATIVE_CACHE_HEADER_CLOSURE_RECEIPT_SHA256__' =
            $expectedHeaderClosureReceiptSha256
        '__NATIVE_CACHE_CATALOG_TRANSPORT_REPAIR_RECEIPT_SHA256__' =
            $repairReceiptSha256
        '__NATIVE_CACHE_CATALOG_TRANSPORT_CONTRACT_SHA256__' =
            $catalogContractSha256
        '__NATIVE_CACHE_MINIMAL_START_TOOL_SHA256__' =
            $expectedSourceMinimalStartSha256
    }
    foreach ($placeholder in $replacements.Keys) {
        Assert-True (([regex]::Matches(
                    $templateText, [regex]::Escape($placeholder)
                )).Count -eq 1) `
            'phase3b2_epinel_catalog_transport_repair_wrapper_placeholder_invalid'
        $templateText = $templateText.Replace(
            $placeholder, [string]$replacements[$placeholder]
        )
    }
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseInput(
        $templateText, [ref]$tokens, [ref]$parseErrors
    )
    Assert-True (@($parseErrors).Count -eq 0) `
        'phase3b2_epinel_catalog_transport_repair_bound_wrapper_parse_failed'
    Write-AtomicUtf8NoBom $targetWrapper $templateText

    $toolBinding = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-native-cache-catalog-transport-tool-binding/v1'
        boundAtUtc = [DateTimeOffset]::UtcNow.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'"
        )
        repairReceiptSha256 = $repairReceiptSha256
        catalogTransportContractSha256 = $catalogContractSha256
        serverDllSha256 = Get-Sha256Hex $targetServerDll
        minimalStartToolByteLength =
            (Get-Item -LiteralPath $targetMinimalStart).Length
        minimalStartToolSha256 = Get-Sha256Hex $targetMinimalStart
        boundWrapperToolByteLength =
            (Get-Item -LiteralPath $targetWrapper).Length
        boundWrapperToolSha256 = Get-Sha256Hex $targetWrapper
        catalogBodyPreflightCount = 3
        catalogSignaturePreflightCount = 3
        originalClientStartBlockedUntilPreflightPasses = $true
        targetOsOfflineDuringToolBinding = $true
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        nextStepCode =
            'boot_micron_nlloperator_run_epinel_native_cache_catalog_transport_once'
    }
    Write-AtomicUtf8NoBom $toolBindingPath `
        (($toolBinding | ConvertTo-Json -Depth 7) + "`n")

    Copy-ExactFile $catalogContractPath `
        (Join-Path $ProtectedRoot 'catalog-transport.contract.json')
    Copy-ExactFile $repairReceiptPath `
        (Join-Path $ProtectedRoot 'repair.receipt.json')
    Copy-ExactFile $toolBindingPath `
        (Join-Path $ProtectedRoot 'tool-binding.receipt.json')
    Copy-ExactFile $rollbackPlanPath `
        (Join-Path $ProtectedRoot 'rollback-plan.json')

    Assert-True ((Test-Digest $databasePath 413327L `
            $expectedDatabaseBeforeSha256) -and
        @($sqlitePaths | Where-Object {
                Test-Path -LiteralPath $_
            }).Count -eq 0 -and
        (Test-Digest $hostsPath 1690L $expectedHostsBeforeSha256) -and
        -not (Test-Path -LiteralPath $pointerPath) -and
        (Test-Digest $targetServerDll 15366144L `
            $expectedSourceServerDllSha256) -and
        (Test-Digest $targetMinimalStart 33053L `
            $expectedSourceMinimalStartSha256) -and
        (Get-Sha256Hex $repairReceiptPath) -ceq $repairReceiptSha256 -and
        (Get-Sha256Hex $catalogContractPath) -ceq $catalogContractSha256) `
        'phase3b2_epinel_catalog_transport_repair_final_verification_failed'

    [pscustomobject]@{
        Receipt = $receipt
        ReceiptPath = $repairReceiptPath
        ReceiptByteLength = (Get-Item -LiteralPath $repairReceiptPath).Length
        ReceiptSha256 = $repairReceiptSha256
        CatalogTransportContractPath = $catalogContractPath
        CatalogTransportContractSha256 = $catalogContractSha256
        ToolBindingReceiptPath = $toolBindingPath
        ToolBindingReceiptSha256 = Get-Sha256Hex $toolBindingPath
        MicronStartCommand =
            "& 'C:\NLL\Tools\Start-Phase3B2-Epinel-NativeCache.ps1'"
    } | ConvertTo-Json -Depth 9
}
catch {
    if ($mutated -and (Test-Path -LiteralPath $backupRoot)) {
        $restoreTargets = [ordered]@{
            'server\EpinelPS.dll' = $targetServerDll
            'tools\Start-Phase3B2-Epinel-NativeCache.ps1' = $targetWrapper
            'tools\start-phase3b2-epinel-minimal-reference-in-micron.ps1' =
                $targetMinimalStart
            'runtime\db.after.json' = $databasePath
            'runtime\hosts.applied.bin' = $hostsPath
            'runtime\active-run.pointer.json' = $pointerPath
            'runtime\epinelps.db' = $existingSqlite[0]
        }
        foreach ($relative in $restoreTargets.Keys) {
            $backup = Join-Path $backupRoot $relative
            if (Test-Path -LiteralPath $backup -PathType Leaf) {
                Copy-Item -LiteralPath $backup `
                    -Destination $restoreTargets[$relative] -Force
            }
        }
        if (Test-Path -LiteralPath $archivedPointerPath -PathType Leaf) {
            Remove-Item -LiteralPath $archivedPointerPath -Force
        }
    }
    foreach ($root in @($repairRoot, $ProtectedRoot)) {
        if (Test-Path -LiteralPath $root -PathType Container) {
            Remove-Item -LiteralPath $root -Recurse -Force
        }
    }
    throw
}
