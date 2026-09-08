[CmdletBinding()]
param(
    [string]$EpinelRoot = 'C:\NLL\EpinelPS',
    [string]$P2EvidenceRoot =
        'C:\NLL\Evidence\Phase3B2\Physical\p2-client-start-v2',
    [string]$BackupRoot =
        'C:\NLL\Backups\Phase3B2\PhysicalP2-v2',
    [string]$ExtractionRoot =
        'C:\NLL\Staging\Phase3B2\ContentVersion'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$extensionFirewallGroup = 'NLL Phase3B2 Physical P2 V2 Extension'
$baseFirewallGroup = 'NLL Phase3B2 Physical Isolation'
$activePointerPath = Join-Path $P2EvidenceRoot 'active-run.pointer.json'
$consumptionPath = Join-Path $P2EvidenceRoot `
    'baseline-backed-interactive-retry.consumed.json'
$expectedDatabaseSha256 =
    'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194'
$expectedHostsBackupSha256 =
    'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0'

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-StringSha256Hex {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)) |
            ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $sha.Dispose() }
}

function Test-PathDigest {
    param([string]$Path, [long]$ByteLength, [string]$Sha256)
    (Test-Path -LiteralPath $Path -PathType Leaf) -and
        (Get-Item -LiteralPath $Path).Length -eq $ByteLength -and
        (Get-Sha256Hex $Path) -ceq $Sha256
}

function Write-AtomicUtf8NoBom {
    param([string]$Path, [string]$Text)
    $temporaryPath = $Path + '.tmp.' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText(
            $temporaryPath, $Text, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Read-SharedBytes {
    param([string]$Path)
    $stream = [IO.File]::Open(
        $Path,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    try {
        $bytes = [byte[]]::new($stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -le 0) { throw 'phase3b2_catalog_source_short_read' }
            $offset += $read
        }
        $bytes
    }
    finally { $stream.Dispose() }
}

Assert-True ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    'phase3b2_catalog_recovery_requires_administrator'
$bootDisk = Get-Partition -DriveLetter C | Get-Disk
$samsungDisk = Get-Partition -DriveLetter E | Get-Disk
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$accountName = ($identity.Name -split '\\')[-1]
$profileRoot = [Environment]::GetFolderPath(
    [Environment+SpecialFolder]::UserProfile)
Assert-True ($bootDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK' -and
    $bootDisk.IsBoot -and $bootDisk.IsSystem -and
    $samsungDisk.FriendlyName -ceq 'Samsung SSD 980 1TB' -and
    $accountName -ceq 'ccccc' -and
    [IO.Path]::GetFullPath($profileRoot).TrimEnd('\') -ceq
        'C:\Users\ccccc') `
    'phase3b2_catalog_recovery_boundary_or_account_invalid'

$runtimeProcesses = @(Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessName -in @(
        'EpinelPS',
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap',
        'nikke',
        'nikke_launcher') })
Assert-True ($runtimeProcesses.Count -eq 0) `
    'phase3b2_catalog_recovery_runtime_not_cold'
Assert-True ((Test-Path -LiteralPath $activePointerPath -PathType Leaf) -and
    (Test-Path -LiteralPath $consumptionPath -PathType Leaf)) `
    'phase3b2_catalog_recovery_pointer_shape_invalid'

$pointer = Get-Content -LiteralPath $activePointerPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$consumption = Get-Content -LiteralPath $consumptionPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$assessmentUid = [string]$pointer.assessmentUid
$runRoot = Join-Path $P2EvidenceRoot $assessmentUid
$runStartPath = Join-Path $runRoot 'run-start.receipt.json'
$measurementPath = Join-Path $runRoot 'ten-minute-measurement.receipt.json'
$databaseBeforePath = Join-Path $runRoot 'db.before.bin'
$databaseAfterFailurePath = Join-Path $runRoot `
    'db.after-completion-stop-failure.bin'
$archivedPointerPath = Join-Path $runRoot `
    'active-run.before-cold-recovery.json'
$recoveryReceiptPath = Join-Path $runRoot `
    'cold-recovery-and-catalog-extraction.receipt.json'
Assert-True ($pointer.contractId -ceq
        'nll/phase3b2-physical-p2-v2-active-run-pointer/v1' -and
    $assessmentUid -and
    $pointer.runStartReceiptSha256 -ceq (Get-Sha256Hex $runStartPath) -and
    $pointer.measurementReceiptSha256 -ceq
        (Get-Sha256Hex $measurementPath) -and
    $consumption.contractId -ceq
        'nll/phase3b2-p2-v2-baseline-backed-interactive-retry-consumption/v1' -and
    $consumption.assessmentUid -ceq $assessmentUid -and
    -not (Test-Path -LiteralPath $archivedPointerPath) -and
    -not (Test-Path -LiteralPath $recoveryReceiptPath)) `
    'phase3b2_catalog_recovery_evidence_invalid'
Assert-True (Test-PathDigest $databaseBeforePath 413327L `
        $expectedDatabaseSha256) `
    'phase3b2_catalog_recovery_database_backup_invalid'

$serverRoot = Join-Path $EpinelRoot 'EpinelPS\bin\Release\net10.0\win-x64'
$databasePath = Join-Path $serverRoot 'db.json'
$sqlitePaths = @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal') |
    ForEach-Object { Join-Path $serverRoot $_ }
Assert-True ((Test-Path -LiteralPath $databasePath -PathType Leaf) -and
    -not (Test-Path -LiteralPath $databaseAfterFailurePath)) `
    'phase3b2_catalog_recovery_runtime_database_invalid'
[IO.File]::WriteAllBytes(
    $databaseAfterFailurePath,
    [IO.File]::ReadAllBytes($databasePath))
$sqliteObservedCount = @($sqlitePaths | Where-Object {
    Test-Path -LiteralPath $_ -PathType Leaf
}).Count
foreach ($path in $sqlitePaths) {
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Remove-Item -LiteralPath $path -Force
    }
}
[IO.File]::WriteAllBytes(
    $databasePath,
    [IO.File]::ReadAllBytes($databaseBeforePath))
Assert-True ((Get-Sha256Hex $databasePath) -ceq $expectedDatabaseSha256 -and
    @($sqlitePaths | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0) `
    'phase3b2_catalog_recovery_database_restore_failed'

$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$hostsBackupPath = Join-Path $BackupRoot 'hosts.before.bin'
Assert-True (Test-PathDigest $hostsBackupPath 1690L `
        $expectedHostsBackupSha256) `
    'phase3b2_catalog_recovery_hosts_backup_invalid'
$extensionRulesBefore = @(Get-NetFirewallRule -Group $extensionFirewallGroup `
    -ErrorAction SilentlyContinue)
Assert-True ($extensionRulesBefore.Count -le 1) `
    'phase3b2_catalog_recovery_extension_firewall_shape_invalid'
if ($extensionRulesBefore.Count -eq 1) {
    $extensionRulesBefore | Remove-NetFirewallRule
}
[IO.File]::WriteAllBytes(
    $hostsPath,
    [IO.File]::ReadAllBytes($hostsBackupPath))
Assert-True ((Get-Sha256Hex $hostsPath) -ceq $expectedHostsBackupSha256 -and
    @(Get-NetFirewallRule -Group $extensionFirewallGroup `
        -ErrorAction SilentlyContinue).Count -eq 0 -and
    @(Get-NetFirewallRule -Group $baseFirewallGroup `
        -ErrorAction SilentlyContinue).Count -eq 17) `
    'phase3b2_catalog_recovery_network_restore_failed'

$localLowRoot = Join-Path $profileRoot 'AppData\LocalLow'
$sourceCandidates = @(Get-ChildItem -LiteralPath $localLowRoot -Recurse -File `
    -Filter 'latest-651.txt' -Force -ErrorAction SilentlyContinue)
$candidateDigests = @($sourceCandidates | ForEach-Object {
    [pscustomobject]@{
        File = $_
        Sha256 = Get-Sha256Hex $_.FullName
    }
})
$uniqueDigests = @($candidateDigests | Select-Object -ExpandProperty Sha256 `
    -Unique)
$catalogSourceStatusCode = if ($sourceCandidates.Count -eq 0) {
    'exact_named_source_not_found'
}
elseif ($uniqueDigests.Count -ne 1) {
    'exact_named_sources_diverged'
}
else { 'exact_named_source_verified' }
$source = $null
$extractedPath = $null
if ($catalogSourceStatusCode -ceq 'exact_named_source_verified') {
    $source = $candidateDigests | Sort-Object {
        $_.File.LastWriteTimeUtc
    } -Descending | Select-Object -First 1
    $sourceBytes = Read-SharedBytes $source.File.FullName
    Assert-True ($sourceBytes.Length -gt 0 -and $sourceBytes.Length -le 65536) `
        'phase3b2_catalog_source_length_invalid'

    New-Item -ItemType Directory -Path $ExtractionRoot -Force | Out-Null
    $extractedPath = Join-Path $ExtractionRoot 'latest-651.txt'
    if (Test-Path -LiteralPath $extractedPath -PathType Leaf) {
        if ((Get-Sha256Hex $extractedPath) -cne $uniqueDigests[0]) {
            $extractedPath = Join-Path $ExtractionRoot (
                'latest-651.' + $uniqueDigests[0] + '.txt')
        }
    }
    if (-not (Test-Path -LiteralPath $extractedPath -PathType Leaf)) {
        $temporaryPath = $extractedPath + '.tmp.' +
            [Guid]::NewGuid().ToString('N')
        try {
            [IO.File]::WriteAllBytes($temporaryPath, $sourceBytes)
            Move-Item -LiteralPath $temporaryPath -Destination $extractedPath
        }
        finally {
            if (Test-Path -LiteralPath $temporaryPath) {
                Remove-Item -LiteralPath $temporaryPath -Force
            }
        }
    }
    Assert-True ((Get-Sha256Hex $extractedPath) -ceq $uniqueDigests[0]) `
        'phase3b2_catalog_extraction_verification_failed'
}

Copy-Item -LiteralPath $activePointerPath -Destination $archivedPointerPath
Assert-True ((Get-Sha256Hex $archivedPointerPath) -ceq
        (Get-Sha256Hex $activePointerPath)) `
    'phase3b2_catalog_recovery_pointer_archive_failed'
$receipt = [ordered]@{
    schemaVersion = 1
    contractId =
        'nll/phase3b2-p2-v2-cold-recovery-and-catalog-extraction/v1'
    completedAtUtc =
        [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    failedAssessmentUid = $assessmentUid
    failureStageCode = 'catalogue_resource_path_upgrade'
    failureReasonCode = 'local_exact_content_version_cache_miss'
    runtimeColdAtRecovery = $true
    databaseAfterFailureByteLength =
        (Get-Item -LiteralPath $databaseAfterFailurePath).Length
    databaseAfterFailureSha256 = Get-Sha256Hex $databaseAfterFailurePath
    databaseRestored = $true
    sqliteRuntimeObservedMemberCount = $sqliteObservedCount
    sqliteRuntimeRemoved = $true
    p2V2HostsExtensionRolledBack = $true
    p2V2FirewallExtensionRolledBack = $true
    retryConsumptionPreserved = $true
    retryConsumptionSha256 = Get-Sha256Hex $consumptionPath
    sourceProfileRoleCode = 'existing_operator_ccccc_locallow_read_only'
    sourceCandidateCount = $sourceCandidates.Count
    sourceUniqueDigestCount = $uniqueDigests.Count
    catalogSourceStatusCode = $catalogSourceStatusCode
    sourceRelativePathSha256 = if ($null -ne $source) {
        Get-StringSha256Hex (
            [IO.Path]::GetFullPath($source.File.FullName).ToLowerInvariant())
    }
    else { '' }
    extractedByteLength = if ($null -ne $extractedPath) {
        (Get-Item -LiteralPath $extractedPath).Length
    }
    else { 0 }
    extractedSha256 = if ($null -ne $extractedPath) {
        Get-Sha256Hex $extractedPath
    }
    else { '' }
    rawContentEmitted = $false
    sourceCacheModified = $false
    dedicatedNllOperatorCacheModified = $false
    officialOutboundUsed = $false
    officialIdentityPersisted = $false
    officialCredentialPersisted = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
    nextStepCode = if ($catalogSourceStatusCode -ceq
            'exact_named_source_verified') {
        'return_to_samsung_validate_exact_catalog_then_reseal'
    }
    else {
        'return_to_samsung_classify_existing_cache_without_retry'
    }
}
Write-AtomicUtf8NoBom $recoveryReceiptPath `
    (($receipt | ConvertTo-Json -Depth 8) + "`n")
Remove-Item -LiteralPath $activePointerPath -Force
Assert-True (-not (Test-Path -LiteralPath $activePointerPath)) `
    'phase3b2_catalog_recovery_pointer_retirement_failed'
$receipt | ConvertTo-Json -Depth 9
