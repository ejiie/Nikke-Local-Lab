[CmdletBinding()]
param(
    [ValidatePattern('^[A-Z]$')]
    [string]$MicronDriveLetter = 'E',
    [string]$SamsungEvidenceRoot = (
        Join-Path $env:LOCALAPPDATA `
            'NikkeLocalLab\Evidence\Phase3B2\Physical\EpinelMinimalRecovery-v1'
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

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText(
        $Path,
        $Text,
        [Text.UTF8Encoding]::new($false)
    )
}

function Test-ExclusiveReadAccess {
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

$micronDrive = $MicronDriveLetter + ':'
$activeAssessmentUid = '8a38765e-4d53-4bc2-9207-df8b0e6bcba5'
$activeRunRoot = Join-Path $micronDrive `
    "NLL\Evidence\Phase3B2\Physical\p2-client-start-v2\$activeAssessmentUid"
$activePointerPath = Join-Path $micronDrive `
    'NLL\Evidence\Phase3B2\Physical\p2-client-start-v2\active-run.pointer.json'
$runStartPath = Join-Path $activeRunRoot 'run-start.receipt.json'
$databaseBeforePath = Join-Path $activeRunRoot 'db.before.bin'
$serverRoot = Join-Path $micronDrive `
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
$databasePath = Join-Path $serverRoot 'db.json'
$sqlitePaths = @(
    (Join-Path $serverRoot 'epinelps.db'),
    (Join-Path $serverRoot 'epinelps.db-shm'),
    (Join-Path $serverRoot 'epinelps.db-wal')
)
$serverDllPath = Join-Path $serverRoot 'EpinelPS.dll'
$hostsPath = Join-Path $micronDrive 'Windows\System32\drivers\etc\hosts'
$deploymentPrivatePath = Join-Path $micronDrive `
    'NLL\Evidence\Phase3B2\Physical\catalog-set-v1\bf669c3c-fcc8-4d57-9f18-32fee1288862\deployment.private.json'
$micronEvidenceRoot = Join-Path $micronDrive `
    'NLL\Evidence\Phase3B2\Physical\epinel-minimal-recovery-v1'
$backupRoot = Join-Path $micronDrive `
    'NLL\Backups\Phase3B2\EpinelMinimalRecovery-v1'

Assert-True ($env:SystemDrive -ceq 'C:') `
    'phase3b2_epinel_minimal_recovery_not_samsung_system_drive'
Assert-True (
    Test-Path -LiteralPath (Join-Path $micronDrive 'Windows\System32') `
        -PathType Container
) 'phase3b2_epinel_minimal_recovery_micron_windows_missing'
Assert-True (
    -not (Test-Path -LiteralPath $micronEvidenceRoot) -and
    -not (Test-Path -LiteralPath $backupRoot) -and
    -not (Test-Path -LiteralPath $SamsungEvidenceRoot)
) 'phase3b2_epinel_minimal_recovery_destination_exists'

foreach ($path in @(
        $activePointerPath,
        $runStartPath,
        $databaseBeforePath,
        $databasePath,
        $serverDllPath,
        $hostsPath,
        $deploymentPrivatePath
    ) + $sqlitePaths) {
    Assert-True (Test-Path -LiteralPath $path -PathType Leaf) `
        'phase3b2_epinel_minimal_recovery_input_missing'
}
foreach ($path in @($databasePath, $serverDllPath) + $sqlitePaths) {
    Assert-True (Test-ExclusiveReadAccess $path) `
        'phase3b2_epinel_minimal_recovery_target_file_in_use'
}

$activePointer = Get-Content -LiteralPath $activePointerPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
$runStart = Get-Content -LiteralPath $runStartPath -Raw -Encoding UTF8 |
    ConvertFrom-Json

Assert-True (
    $activePointer.contractId -ceq `
        'nll/phase3b2-physical-p2-v2-active-run-pointer/v1' -and
    $activePointer.assessmentUid -ceq $activeAssessmentUid -and
    $runStart.contractId -ceq `
        'nll/phase3b2-physical-p2-v2-client-start/v1' -and
    $runStart.assessmentUid -ceq $activeAssessmentUid -and
    $runStart.clientExecutionStarted
) 'phase3b2_epinel_minimal_recovery_active_run_invalid'
Assert-True (
    Test-Digest $databaseBeforePath 413327L `
        'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194'
) 'phase3b2_epinel_minimal_recovery_database_baseline_invalid'
Assert-True (
    Test-Digest $databasePath 413329L `
        'e524a3c8967af6bb8447fda0c50fc8a86ebccd02e1d1a45df73b2625430acc8d'
) 'phase3b2_epinel_minimal_recovery_database_after_invalid'
Assert-True (
    (Test-Digest $sqlitePaths[0] 4096L `
        '5c9dec1886cc01f5f2307ee1ea87f9b32a4cef0f8f9a2c68beebc558013bedab') -and
    (Test-Digest $sqlitePaths[1] 32768L `
        'c7040d918057afc793b28d8042835e3ad743127a030a513f6077cea657c16d78') -and
    (Test-Digest $sqlitePaths[2] 111272L `
        'e7f7e22e54ab4e0db5ef06895f18e19380cf68b33095b0cf30eafe87441beadc')
) 'phase3b2_epinel_minimal_recovery_sqlite_state_invalid'
Assert-True (
    Test-Digest $serverDllPath 15373312L `
        '4417779d545c338fdf6fa1cc3a7e7b100722f367b4f6814983116a60fee6bf5e'
) 'phase3b2_epinel_minimal_recovery_prior_server_invalid'
Assert-True (
    Test-Digest $hostsPath 1690L `
        'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0'
) 'phase3b2_epinel_minimal_recovery_hosts_not_base'

$deploymentPrivate = Get-Content -LiteralPath $deploymentPrivatePath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
Assert-True (
    $deploymentPrivate.contractId -ceq `
        'nll/phase3b2-exact-catalog-offline-deployment-private/v1' -and
    @($deploymentPrivate.members).Count -eq 6
) 'phase3b2_epinel_minimal_recovery_catalog_manifest_invalid'

foreach ($member in @($deploymentPrivate.members)) {
    $target = Join-Path $deploymentPrivate.serverCacheRoot `
        $member.relativePath
    Assert-True (
        Test-Digest $target ([long]$member.byteLength) `
            ([string]$member.sha256)
    ) 'phase3b2_epinel_minimal_recovery_raw_catalog_drift'
}

New-Item -ItemType Directory -Path $backupRoot, $micronEvidenceRoot,
    $SamsungEvidenceRoot -Force | Out-Null
$stateBackupRoot = Join-Path $backupRoot 'runtime-state'
New-Item -ItemType Directory -Path $stateBackupRoot -Force | Out-Null

$moved = [Collections.Generic.List[object]]::new()
$restoredDatabaseCreated = $false

try {
    foreach ($source in @($databasePath) + $sqlitePaths + @($activePointerPath)) {
        $destination = Join-Path $stateBackupRoot (Split-Path -Leaf $source)
        Assert-True (-not (Test-Path -LiteralPath $destination)) `
            'phase3b2_epinel_minimal_recovery_backup_collision'
        Move-Item -LiteralPath $source -Destination $destination
        $moved.Add([pscustomobject]@{
            Source = $source
            Destination = $destination
        })
    }

    Copy-Item -LiteralPath $databaseBeforePath -Destination $databasePath
    $restoredDatabaseCreated = $true

    Assert-True (
        Test-Digest $databasePath 413327L `
            'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194'
    ) 'phase3b2_epinel_minimal_recovery_database_restore_failed'
    Assert-True (@($sqlitePaths | Where-Object {
            Test-Path -LiteralPath $_
        }).Count -eq 0) `
        'phase3b2_epinel_minimal_recovery_sqlite_remove_failed'
    Assert-True (-not (Test-Path -LiteralPath $activePointerPath)) `
        'phase3b2_epinel_minimal_recovery_pointer_archive_failed'

    $manifestMembers = @(
        Get-ChildItem -LiteralPath $stateBackupRoot -File |
            Sort-Object Name
    )
    $manifestLines = foreach ($file in $manifestMembers) {
        "$($file.Name)`t$($file.Length)`t$(Get-Sha256Hex $file.FullName)"
    }
    $manifestPath = Join-Path $backupRoot 'backup.manifest.tsv'
    Write-Utf8NoBom $manifestPath (($manifestLines -join "`n") + "`n")

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-epinel-minimal-p2-offline-recovery/v1'
        recoveredAtUtc = [DateTimeOffset]::UtcNow.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'"
        )
        failedAssessmentUid = $activeAssessmentUid
        failedRunStartReceiptSha256 = Get-Sha256Hex $runStartPath
        databaseAfterFailureSha256 = `
            'e524a3c8967af6bb8447fda0c50fc8a86ebccd02e1d1a45df73b2625430acc8d'
        databaseBaselineSha256 = `
            'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194'
        databaseRestored = $true
        sqliteRuntimeArchivedMemberCount = 3
        sqliteRuntimeRemoved = $true
        activeRunPointerArchived = $true
        baseHostsPreserved = $true
        rawCatalogMemberCount = 6
        rawCatalogSetVerified = $true
        priorProjectedServerDllPreserved = $true
        priorProjectedServerDllSha256 = `
            '4417779d545c338fdf6fa1cc3a7e7b100722f367b4f6814983116a60fee6bf5e'
        backupManifestByteLength = (Get-Item $manifestPath).Length
        backupManifestSha256 = Get-Sha256Hex $manifestPath
        targetOsOfflineDuringRecovery = $true
        officialOutboundUsed = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        nextStepCode = 'deploy_clean_epinel_minimal_build_and_reseal'
    }

    $receiptText = ($receipt | ConvertTo-Json) + "`n"
    $micronReceiptPath = Join-Path $micronEvidenceRoot 'recovery.receipt.json'
    $samsungReceiptPath = Join-Path $SamsungEvidenceRoot `
        'recovery.receipt.json'
    Write-Utf8NoBom $micronReceiptPath $receiptText
    Write-Utf8NoBom $samsungReceiptPath $receiptText

    [pscustomobject]@{
        Receipt = $receipt
        MicronReceiptPath = $micronReceiptPath
        MicronReceiptSha256 = Get-Sha256Hex $micronReceiptPath
        SamsungReceiptPath = $samsungReceiptPath
        SamsungReceiptSha256 = Get-Sha256Hex $samsungReceiptPath
    } | ConvertTo-Json -Depth 6
}
catch {
    if ($restoredDatabaseCreated -and (Test-Path -LiteralPath $databasePath)) {
        $failedRestorePath = Join-Path $stateBackupRoot `
            'failed-restored-db.json'
        Move-Item -LiteralPath $databasePath -Destination $failedRestorePath `
            -Force
    }

    for ($index = $moved.Count - 1; $index -ge 0; $index--) {
        $entry = $moved[$index]
        if (Test-Path -LiteralPath $entry.Destination) {
            Move-Item -LiteralPath $entry.Destination `
                -Destination $entry.Source -Force
        }
    }

    throw
}
