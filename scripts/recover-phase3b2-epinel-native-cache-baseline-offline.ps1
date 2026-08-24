[CmdletBinding()]
param(
    [ValidatePattern('^[A-Z]$')]
    [string]$MicronDriveLetter = 'E',
    [string]$AssessmentUid = '0f37da44-dc19-4f5e-b7a8-25556a9f52b3',
    [string]$SamsungEvidenceRoot = (
        Join-Path $env:LOCALAPPDATA (
            'NikkeLocalLab\Evidence\Phase3B2\Physical\' +
            'EpinelNativeCacheBaseline-v1'
        )
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
    param(
        [string]$Path,
        [long]$ByteLength,
        [string]$Sha256
    )

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
    catch {
        return $false
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

function Protect-ServerLog {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 0 }
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    $pattern = '(?m)^(?<prefix>\s*authtoken:\s*)\S+\s*$'
    $matchCount = [regex]::Matches($text, $pattern).Count
    if ($matchCount -gt 0) {
        $protected = [regex]::Replace(
            $text,
            $pattern,
            '${prefix}[REDACTED]'
        )
        Write-AtomicUtf8NoBom $Path $protected
    }
    return $matchCount
}

$micronDrive = $MicronDriveLetter + ':'
$serverRoot = Join-Path $micronDrive `
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
$evidenceRoot = Join-Path $micronDrive `
    'NLL\Evidence\Phase3B2\Physical\epinel-minimal-reference-v1'
$runRoot = Join-Path $evidenceRoot $AssessmentUid
$activePointerPath = Join-Path $evidenceRoot 'active-run.pointer.json'
$runStartPath = Join-Path $runRoot 'run-start.receipt.json'
$dbBeforePath = Join-Path $runRoot 'db.before.bin'
$hostsBeforePath = Join-Path $runRoot 'hosts.before.bin'
$stdoutPath = Join-Path $runRoot 'server.stdout.log'
$stderrPath = Join-Path $runRoot 'server.stderr.log'
$offlineCompletionPath = Join-Path $runRoot `
    'native-cache-baseline.offline-completion.receipt.json'
$archivedPointerPath = Join-Path $runRoot `
    'active-run.pointer.archived-offline.json'
$databasePath = Join-Path $serverRoot 'db.json'
$sqlitePaths = @(
    (Join-Path $serverRoot 'epinelps.db'),
    (Join-Path $serverRoot 'epinelps.db-shm'),
    (Join-Path $serverRoot 'epinelps.db-wal')
)
$hostsPath = Join-Path $micronDrive 'Windows\System32\drivers\etc\hosts'
$backupRoot = Join-Path $micronDrive (
    'NLL\Backups\Phase3B2\EpinelNativeCacheBaseline-v1\' +
    $AssessmentUid
)
$stateBackupRoot = Join-Path $backupRoot 'runtime-state'
$micronReceiptRoot = Join-Path $micronDrive (
    'NLL\Evidence\Phase3B2\Physical\epinel-native-cache-baseline-v1\' +
    $AssessmentUid
)
$samsungReceiptRoot = Join-Path $SamsungEvidenceRoot $AssessmentUid
$transactionDirectories = @(
    $stateBackupRoot,
    $backupRoot,
    $micronReceiptRoot,
    $samsungReceiptRoot
)

foreach ($directory in $transactionDirectories) {
    if (Test-Path -LiteralPath $directory -PathType Container) {
        Assert-True (
            @(Get-ChildItem -LiteralPath $directory -Force).Count -eq 0
        ) 'phase3b2_native_cache_baseline_preexisting_directory_not_empty'
        Remove-Item -LiteralPath $directory -Force
    }
}

$expectedRunStartSha256 = `
    'dfc787bc3c1041b0a241b453fceecaf54e0d41f7860fb1b741b159ba2379729d'
$expectedDbBeforeSha256 = `
    'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194'
$expectedDbAfterSha256 = `
    'e524a3c8967af6bb8447fda0c50fc8a86ebccd02e1d1a45df73b2625430acc8d'
$expectedHostsBeforeSha256 = `
    'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0'
$expectedHostsAfterSha256 = `
    '3b0dcc4396373e9e9d623ef05c345f89330427ad5128727290c9f76138e22f64'
$expectedSqliteDigests = @(
    [pscustomobject]@{
        Name = 'epinelps.db'
        ByteLength = 4096L
        Sha256 = `
            '5c9dec1886cc01f5f2307ee1ea87f9b32a4cef0f8f9a2c68beebc558013bedab'
    },
    [pscustomobject]@{
        Name = 'epinelps.db-shm'
        ByteLength = 32768L
        Sha256 = `
            '1968781d9dc4a0309c290b7e2261b37a25872a6f7d134de16e1626fe66cbeb3a'
    },
    [pscustomobject]@{
        Name = 'epinelps.db-wal'
        ByteLength = 111272L
        Sha256 = `
            '403393060c8154a1ad38e744f8594d4bbb1b5528c76dd902cb930de4a9405836'
    }
)

$systemPartition = Get-Partition -DriveLetter C
$systemDisk = $systemPartition | Get-Disk
$micronPartition = Get-Partition -DriveLetter $MicronDriveLetter
$micronDisk = $micronPartition | Get-Disk
Assert-True (
    $env:SystemDrive -ceq 'C:' -and
    $systemDisk.FriendlyName -like 'Samsung SSD 980*' -and
    $micronDisk.FriendlyName -like 'Micron_2200*'
) 'phase3b2_native_cache_baseline_wrong_disk_boundary'
Assert-True (
    Test-Path -LiteralPath (Join-Path $micronDrive 'Windows\System32') `
        -PathType Container
) 'phase3b2_native_cache_baseline_micron_windows_missing'

foreach ($path in @(
        $activePointerPath,
        $runStartPath,
        $dbBeforePath,
        $hostsBeforePath,
        $stdoutPath,
        $stderrPath,
        $databasePath,
        $hostsPath
    ) + $sqlitePaths) {
    Assert-True (Test-Path -LiteralPath $path -PathType Leaf) `
        'phase3b2_native_cache_baseline_input_missing'
}
Assert-True (
    -not (Test-Path -LiteralPath $offlineCompletionPath) -and
    -not (Test-Path -LiteralPath $archivedPointerPath) -and
    -not (Test-Path -LiteralPath $backupRoot) -and
    -not (Test-Path -LiteralPath $micronReceiptRoot) -and
    -not (Test-Path -LiteralPath $samsungReceiptRoot)
) 'phase3b2_native_cache_baseline_destination_exists'
foreach ($path in @($databasePath, $hostsPath) + $sqlitePaths) {
    Assert-True (Test-ExclusiveAccess $path) `
        'phase3b2_native_cache_baseline_target_file_in_use'
}

$pointer = Get-Content -LiteralPath $activePointerPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$runStart = Get-Content -LiteralPath $runStartPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True (
    $pointer.contractId -ceq `
        'nll/phase3b2-epinel-minimal-active-run-pointer/v1' -and
    $pointer.assessmentUid -ceq $AssessmentUid -and
    $pointer.runStartReceiptSha256 -ceq $expectedRunStartSha256 -and
    $pointer.databaseBeforeSha256 -ceq $expectedDbBeforeSha256 -and
    $pointer.hostsBeforeSha256 -ceq $expectedHostsBeforeSha256 -and
    $runStart.contractId -ceq `
        'nll/phase3b2-epinel-minimal-reference-start/v1' -and
    $runStart.assessmentUid -ceq $AssessmentUid -and
    $runStart.serverRunning -and
    $runStart.clientExecutionStarted
) 'phase3b2_native_cache_baseline_pointer_or_run_start_invalid'

Assert-True (
    (Test-Digest $runStartPath 1830L $expectedRunStartSha256) -and
    (Test-Digest $dbBeforePath 413327L $expectedDbBeforeSha256) -and
    (Test-Digest $databasePath 413329L $expectedDbAfterSha256) -and
    (Test-Digest $hostsBeforePath 1690L $expectedHostsBeforeSha256) -and
    (Test-Digest $hostsPath 1727L $expectedHostsAfterSha256)
) 'phase3b2_native_cache_baseline_primary_digest_invalid'
for ($index = 0; $index -lt $sqlitePaths.Count; $index++) {
    $expected = $expectedSqliteDigests[$index]
    Assert-True (
        (Split-Path -Leaf $sqlitePaths[$index]) -ceq $expected.Name -and
        (Test-Digest $sqlitePaths[$index] $expected.ByteLength `
            $expected.Sha256)
    ) 'phase3b2_native_cache_baseline_sqlite_digest_invalid'
}

$databaseAfterByteLength = (Get-Item -LiteralPath $databasePath).Length
$databaseAfterSha256 = Get-Sha256Hex $databasePath
$hostsAfterByteLength = (Get-Item -LiteralPath $hostsPath).Length
$hostsAfterSha256 = Get-Sha256Hex $hostsPath
$stdoutBeforeByteLength = (Get-Item -LiteralPath $stdoutPath).Length
$stdoutBeforeSha256 = Get-Sha256Hex $stdoutPath
$redactedServerLogMatchCount = Protect-ServerLog $stdoutPath
$stdoutAfterByteLength = (Get-Item -LiteralPath $stdoutPath).Length
$stdoutAfterSha256 = Get-Sha256Hex $stdoutPath
Assert-True (
    [regex]::Matches(
        [IO.File]::ReadAllText($stdoutPath, [Text.Encoding]::UTF8),
        '(?m)^\s*authtoken:\s+(?!\[REDACTED\]\s*$)\S+'
    ).Count -eq 0
) 'phase3b2_native_cache_baseline_sensitive_log_persisted'

$createdPaths = [Collections.Generic.List[string]]::new()
$movedEntries = [Collections.Generic.List[object]]::new()

try {
    New-Item -ItemType Directory -Path $stateBackupRoot,
        $micronReceiptRoot, $samsungReceiptRoot -Force | Out-Null

    foreach ($source in @($databasePath) + $sqlitePaths + @(
            $hostsPath,
            $activePointerPath
        )) {
        $roleCode = switch (Split-Path -Leaf $source) {
            'db.json' { 'database.after.json' }
            'hosts' { 'hosts.applied.bin' }
            'active-run.pointer.json' { 'active-run.pointer.json' }
            default { Split-Path -Leaf $source }
        }
        $destination = Join-Path $stateBackupRoot $roleCode
        Assert-True (-not (Test-Path -LiteralPath $destination)) `
            'phase3b2_native_cache_baseline_backup_collision'
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
    Copy-Item -LiteralPath (
        Join-Path $stateBackupRoot 'active-run.pointer.json'
    ) -Destination $archivedPointerPath
    $createdPaths.Add($archivedPointerPath)

    Assert-True (
        (Test-Digest $databasePath 413327L $expectedDbBeforeSha256) -and
        @($sqlitePaths | Where-Object {
            Test-Path -LiteralPath $_
        }).Count -eq 0 -and
        (Test-Digest $hostsPath 1690L $expectedHostsBeforeSha256) -and
        -not (Test-Path -LiteralPath $activePointerPath) -and
        (Get-Sha256Hex $archivedPointerPath) -ceq (
            Get-Sha256Hex (
                Join-Path $stateBackupRoot 'active-run.pointer.json'
            )
        )
    ) 'phase3b2_native_cache_baseline_restore_verification_failed'

    $manifestMembers = @(
        Get-ChildItem -LiteralPath $stateBackupRoot -File |
            Sort-Object Name
    )
    $manifestLines = foreach ($file in $manifestMembers) {
        "$($file.Name)`t$($file.Length)`t$(Get-Sha256Hex $file.FullName)"
    }
    $manifestPath = Join-Path $backupRoot 'backup.manifest.tsv'
    Write-AtomicUtf8NoBom $manifestPath `
        (($manifestLines -join "`n") + "`n")
    $createdPaths.Add($manifestPath)

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = `
            'nll/phase3b2-epinel-native-cache-baseline-offline-recovery/v1'
        recoveredAtUtc = [DateTimeOffset]::UtcNow.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'"
        )
        assessmentUid = $AssessmentUid
        runStartReceiptByteLength = (Get-Item $runStartPath).Length
        runStartReceiptSha256 = $expectedRunStartSha256
        observedStageCode = 'catalogue_path'
        outcomeCode = 'system_error'
        databaseAfterByteLength = $databaseAfterByteLength
        databaseAfterSha256 = $databaseAfterSha256
        databaseBaselineSha256 = $expectedDbBeforeSha256
        databaseRestored = $true
        sqliteRuntimeArchivedMemberCount = 3
        sqliteRuntimeRemoved = $true
        hostsAfterByteLength = $hostsAfterByteLength
        hostsAfterSha256 = $hostsAfterSha256
        hostsBaselineSha256 = $expectedHostsBeforeSha256
        hostsRestored = $true
        activeRunPointerArchived = $true
        serverStdoutBeforeByteLength = $stdoutBeforeByteLength
        serverStdoutBeforeSha256 = $stdoutBeforeSha256
        redactedServerLogMatchCount = $redactedServerLogMatchCount
        serverStdoutAfterByteLength = $stdoutAfterByteLength
        serverStdoutAfterSha256 = $stdoutAfterSha256
        rawSensitiveServerLogPersisted = $false
        serverStderrByteLength = (Get-Item $stderrPath).Length
        serverStderrSha256 = Get-Sha256Hex $stderrPath
        extensionFirewallGroup = `
            'NLL Phase3B2 Epinel Minimal Extension'
        extensionFirewallCleanupDeferred = $true
        extensionFirewallCleanupBoundaryCode = `
            'micron_registry_offline_no_privileged_hive_mutation'
        backupManifestByteLength = (Get-Item $manifestPath).Length
        backupManifestSha256 = Get-Sha256Hex $manifestPath
        targetOsOfflineDuringRecovery = $true
        runtimeColdAtRecovery = $true
        officialOutboundUsed = $false
        officialIdentityPersisted = $false
        officialCredentialPersisted = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        retryAuthorized = $false
        nextStepCode = `
            'materialize_complete_native_cache_on_samsung_before_retry'
    }
    $receiptText = ($receipt | ConvertTo-Json -Depth 7) + "`n"
    Write-AtomicUtf8NoBom $offlineCompletionPath $receiptText
    $createdPaths.Add($offlineCompletionPath)
    $micronReceiptPath = Join-Path $micronReceiptRoot `
        'baseline-recovery.receipt.json'
    Write-AtomicUtf8NoBom $micronReceiptPath $receiptText
    $createdPaths.Add($micronReceiptPath)
    $samsungReceiptPath = Join-Path $samsungReceiptRoot `
        'baseline-recovery.receipt.json'
    Write-AtomicUtf8NoBom $samsungReceiptPath $receiptText
    $createdPaths.Add($samsungReceiptPath)

    [pscustomobject]@{
        Receipt = $receipt
        MicronReceiptPath = $micronReceiptPath
        MicronReceiptByteLength = (Get-Item $micronReceiptPath).Length
        MicronReceiptSha256 = Get-Sha256Hex $micronReceiptPath
        SamsungReceiptPath = $samsungReceiptPath
        SamsungReceiptByteLength = (Get-Item $samsungReceiptPath).Length
        SamsungReceiptSha256 = Get-Sha256Hex $samsungReceiptPath
    } | ConvertTo-Json -Depth 8
}
catch {
    for ($index = $createdPaths.Count - 1; $index -ge 0; $index--) {
        $created = $createdPaths[$index]
        if (Test-Path -LiteralPath $created -PathType Leaf) {
            Remove-Item -LiteralPath $created -Force
        }
    }
    for ($index = $movedEntries.Count - 1; $index -ge 0; $index--) {
        $entry = $movedEntries[$index]
        if (Test-Path -LiteralPath $entry.Destination -PathType Leaf) {
            Move-Item -LiteralPath $entry.Destination `
                -Destination $entry.Source -Force
        }
    }
    foreach ($directory in @($transactionDirectories | Sort-Object {
                $_.Length
            } -Descending)) {
        if ((Test-Path -LiteralPath $directory -PathType Container) -and
            @(Get-ChildItem -LiteralPath $directory -Force).Count -eq 0) {
            Remove-Item -LiteralPath $directory -Force
        }
    }
    throw
}
