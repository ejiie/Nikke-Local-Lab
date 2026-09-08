#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidatePattern('^[A-Z]$')]
    [string]$MicronDriveLetter = 'E',
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$AssessmentUid =
        'ebd24444-3ac6-49de-9982-505737a6eccd',
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$SealUid =
        '0f3a28ce-fb15-4b15-9a09-4de7174ac5c4',
    [string]$BackupRoot = (
        'D:\NikkeLocalLab\Backups\' +
        'phase3b2-user-progression-solo-menu-golden-v1'
    ),
    [string]$ProtectedRoot = (
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\' +
        'Micron-PrePhysicalLane-20260823\PhysicalP2\' +
        'EpinelUserProgressionSoloMenuGolden-v1'
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
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).
        Hash.ToLowerInvariant()
}

function Write-JsonUtf8NoBom {
    param([string]$Path, [object]$Value)
    [IO.File]::WriteAllText(
        $Path,
        (($Value | ConvertTo-Json -Depth 12) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
}

function Copy-VerifiedFile {
    param(
        [string]$Source,
        [string]$Destination,
        [string]$ExpectedSha256
    )
    Assert-True (Test-Path -LiteralPath $Source -PathType Leaf) `
        ('phase3b2_solo_menu_completion_source_missing:' + $Source)
    Assert-True ((Get-Sha256Hex $Source) -ceq $ExpectedSha256) `
        ('phase3b2_solo_menu_completion_source_drifted:' + $Source)
    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $partial = $Destination + '.partial-' + [Guid]::NewGuid().ToString('N')
    Copy-Item -LiteralPath $Source -Destination $partial
    Assert-True ((Get-Sha256Hex $partial) -ceq $ExpectedSha256) `
        ('phase3b2_solo_menu_completion_copy_invalid:' + $Destination)
    Move-Item -LiteralPath $partial -Destination $Destination
}

$micronDrive = $MicronDriveLetter + ':'
$sealRoot = Join-Path ([IO.Path]::GetFullPath($BackupRoot)) $SealUid
$protectedSealRoot = Join-Path ([IO.Path]::GetFullPath($ProtectedRoot)) `
    $SealUid
Assert-True ($sealRoot.StartsWith(
        'D:\NikkeLocalLab\Backups\',
        [StringComparison]::OrdinalIgnoreCase
    )) 'phase3b2_solo_menu_completion_backup_root_invalid'
Assert-True ($protectedSealRoot.StartsWith(
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\',
        [StringComparison]::OrdinalIgnoreCase
    )) 'phase3b2_solo_menu_completion_protected_root_invalid'

$systemDisk = Get-Partition -DriveLetter C | Get-Disk
$micronDisk = Get-Partition -DriveLetter $MicronDriveLetter | Get-Disk
Assert-True (
    $env:SystemDrive -ceq 'C:' -and
    $systemDisk.FriendlyName -like 'Samsung SSD 980*' -and
    $micronDisk.FriendlyName -like 'Micron_2200*'
) 'phase3b2_solo_menu_completion_wrong_disk_boundary'
Assert-True (@(Get-Process -Name @(
        'EpinelPS', 'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
    ) -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_solo_menu_completion_runtime_not_cold'
$currentBootOfficialProcessCount = @(Get-Process -Name @(
        'NIKKE', 'nikke_launcher'
    ) -ErrorAction SilentlyContinue).Count

$physicalRoot = Join-Path $micronDrive `
    'NLL\Evidence\Phase3B2\Physical\epinel-user-progression-v2'
$runRoot = Join-Path $physicalRoot $AssessmentUid
$activePointerPath = Join-Path $physicalRoot 'active-run.pointer.json'
$archivedPointerPath = Join-Path $runRoot `
    'active-run.pointer.archived.json'
$completionPath = Join-Path $runRoot 'completion.receipt.json'
$serverRoot = Join-Path $micronDrive (
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
)
$databasePath = Join-Path $serverRoot 'db.json'
$hostsPath = Join-Path $micronDrive `
    'Windows\System32\drivers\etc\hosts'
$sqlitePaths = @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal' |
    ForEach-Object { Join-Path $serverRoot $_ })

$expected = [ordered]@{
    completion =
        '2d8f9dfb7206ad03d9c4509dede6bd46ae8c125873a30e8b8674ec879fe8b0db'
    archivedPointer =
        'd272ca72da9de64546af1ef39394118fe05319897374a6a02e51434081b36a6e'
    database =
        'd73e92c9e8159b347f42eff5c6c2270e3695e91cd542c05f45bcbb121cd9a1ee'
    hosts =
        'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0'
    baseSeal =
        'ca1fafd7b56c7ca0c4865561e5b4609778a193b529a5f3b9dcc0608c6a613fe2'
    baseManifest =
        'f6e5294cbea7adff513942fba2f78a2c8d18152b7331905825b663b45d626961'
}
Assert-True (-not (Test-Path -LiteralPath $activePointerPath)) `
    'phase3b2_solo_menu_completion_active_pointer_still_present'
Assert-True (
    (Get-Sha256Hex $completionPath) -ceq $expected.completion -and
    (Get-Sha256Hex $archivedPointerPath) -ceq
        $expected.archivedPointer -and
    (Get-Sha256Hex $databasePath) -ceq $expected.database -and
    (Get-Sha256Hex $hostsPath) -ceq $expected.hosts -and
    @($sqlitePaths | Where-Object {
        Test-Path -LiteralPath $_ -PathType Leaf
    }).Count -eq 0
) 'phase3b2_solo_menu_completion_cold_state_invalid'

$completion = Get-Content -LiteralPath $completionPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
Assert-True (
    $completion.contractId -ceq
        'nll/phase3b2-epinel-user-progression-completion/v2' -and
    $completion.assessmentUid -ceq $AssessmentUid -and
    $completion.observedStageCode -ceq 'solo_raid_menu' -and
    $completion.outcomeCode -ceq 'success' -and
    $completion.databaseRestored -and
    $completion.sqliteRuntimeObservedMemberCount -eq 3 -and
    $completion.sqliteRuntimeRemoved -and
    $completion.hostsRestored -and
    $completion.extensionFirewallRemoved -and
    $completion.runtimeColdAfterCompletion -and
    -not $completion.officialOutboundFallbackUsed -and
    -not $completion.officialLauncherExecutionStarted
) 'phase3b2_solo_menu_completion_contract_invalid'

$baseSealPath = Join-Path $sealRoot 'metadata\seal.receipt.json'
$baseManifestPath = Join-Path $sealRoot 'metadata\overlay.manifest.json'
Assert-True (
    (Get-Sha256Hex $baseSealPath) -ceq $expected.baseSeal -and
    (Get-Sha256Hex $baseManifestPath) -ceq $expected.baseManifest
) 'phase3b2_solo_menu_completion_base_seal_drifted'

$backupCompletionPath = Join-Path $sealRoot `
    'evidence\receipts\completion.receipt.json'
$backupArchivedPointerPath = Join-Path $sealRoot `
    'evidence\receipts\active-run.pointer.archived.json'
$extensionManifestPath = Join-Path $sealRoot `
    'metadata\post-completion.manifest.json'
$auditPath = Join-Path $sealRoot `
    'metadata\post-completion.audit.receipt.json'
Assert-True (
    -not (Test-Path -LiteralPath $backupCompletionPath) -and
    -not (Test-Path -LiteralPath $backupArchivedPointerPath) -and
    -not (Test-Path -LiteralPath $extensionManifestPath) -and
    -not (Test-Path -LiteralPath $auditPath)
) 'phase3b2_solo_menu_completion_extension_already_present'

Copy-VerifiedFile $completionPath $backupCompletionPath `
    $expected.completion
Copy-VerifiedFile $archivedPointerPath $backupArchivedPointerPath `
    $expected.archivedPointer

$extensionMembers = @(
    [ordered]@{
        relativePath = 'evidence/receipts/completion.receipt.json'
        byteLength = (Get-Item $backupCompletionPath).Length
        sha256 = Get-Sha256Hex $backupCompletionPath
    },
    [ordered]@{
        relativePath =
            'evidence/receipts/active-run.pointer.archived.json'
        byteLength = (Get-Item $backupArchivedPointerPath).Length
        sha256 = Get-Sha256Hex $backupArchivedPointerPath
    }
)
$canonical = (@($extensionMembers | ForEach-Object {
    "{0}`t{1}`t{2}`n" -f $_.relativePath, $_.byteLength, $_.sha256
}) -join '')
$algorithm = [Security.Cryptography.SHA256]::Create()
try {
    $canonicalSha256 = (($algorithm.ComputeHash(
        [Text.UTF8Encoding]::new($false).GetBytes($canonical)
    ) | ForEach-Object { $_.ToString('x2') }) -join '')
}
finally {
    $algorithm.Dispose()
}
$extensionManifest = [ordered]@{
    schemaVersion = 1
    contractId =
        'nll/phase3b2-user-progression-solo-menu-completion-manifest/v1'
    sealUid = $SealUid
    assessmentUid = $AssessmentUid
    canonicalization =
        'manifest_order_relative_path_tab_byte_length_tab_sha256_lf_v1'
    memberCount = $extensionMembers.Count
    canonicalSha256 = $canonicalSha256
    members = $extensionMembers
}
Write-JsonUtf8NoBom $extensionManifestPath $extensionManifest
$extensionManifestSha256 = Get-Sha256Hex $extensionManifestPath

$audit = [ordered]@{
    schemaVersion = 1
    contractId =
        'nll/phase3b2-user-progression-solo-menu-post-completion-audit/v1'
    auditedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    sealUid = $SealUid
    assessmentUid = $AssessmentUid
    baseSealReceiptSha256 = $expected.baseSeal
    baseOverlayManifestSha256 = $expected.baseManifest
    baseSealModified = $false
    completionReceiptSha256 = $expected.completion
    archivedPointerSha256 = $expected.archivedPointer
    activePointerPresent = $false
    activeDatabaseByteLength = (Get-Item $databasePath).Length
    activeDatabaseSha256 = $expected.database
    activeDatabaseRestoredToCandidate = $true
    sqliteRuntimeMemberCount = 0
    hostsSha256 = $expected.hosts
    hostsRestored = $true
    extensionFirewallRemovedByCompletionReceipt = $true
    runtimeCold = $true
    currentSamsungOfficialProcessCountIgnored =
        $currentBootOfficialProcessCount
    currentSamsungOfficialProcessesModified = $false
    micronMutationPerformedDuringAudit = $false
    cccccCacheInspected = $false
    cccccCacheModified = $false
    localLowInspected = $false
    localLowModified = $false
    extensionManifestByteLength =
        (Get-Item $extensionManifestPath).Length
    extensionManifestSha256 = $extensionManifestSha256
    extensionManifestCanonicalSha256 = $canonicalSha256
    battleQualifiedGolden = $false
    nextStepCode =
        'classify_solo_raid_normal_clear_and_season_admission_without_retry'
}
Write-JsonUtf8NoBom $auditPath $audit
$auditSha256 = Get-Sha256Hex $auditPath

foreach ($path in @(
        $backupCompletionPath, $backupArchivedPointerPath,
        $extensionManifestPath, $auditPath
    )) {
    (Get-Item -LiteralPath $path).IsReadOnly = $true
}

Copy-VerifiedFile $extensionManifestPath (
    Join-Path $protectedSealRoot 'post-completion.manifest.json'
) $extensionManifestSha256
Copy-VerifiedFile $auditPath (
    Join-Path $protectedSealRoot 'post-completion.audit.receipt.json'
) $auditSha256
foreach ($path in @(
        (Join-Path $protectedSealRoot 'post-completion.manifest.json'),
        (Join-Path $protectedSealRoot `
            'post-completion.audit.receipt.json')
    )) {
    (Get-Item -LiteralPath $path).IsReadOnly = $true
}

[ordered]@{
    Audit = $audit
    AuditPath = $auditPath
    AuditByteLength = (Get-Item $auditPath).Length
    AuditSha256 = $auditSha256
    ExtensionManifestPath = $extensionManifestPath
    ExtensionManifestSha256 = $extensionManifestSha256
    ProtectedAuditPath = Join-Path $protectedSealRoot `
        'post-completion.audit.receipt.json'
} | ConvertTo-Json -Depth 12
