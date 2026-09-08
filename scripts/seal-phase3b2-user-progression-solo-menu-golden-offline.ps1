#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidatePattern('^[A-Z]$')]
    [string]$MicronDriveLetter = 'E',
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$AssessmentUid =
        'ebd24444-3ac6-49de-9982-505737a6eccd',
    [string]$BackupRoot = (
        'D:\NikkeLocalLab\Backups\' +
        'phase3b2-user-progression-solo-menu-golden-v1'
    ),
    [string]$ParentFullGoldenRoot = (
        'D:\NikkeLocalLab\Backups\' +
        'phase3b2-lobby-en-d830a90d-20260826T103327Z'
    ),
    [string]$ProtectedRoot = (
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\' +
        'Micron-PrePhysicalLane-20260823\PhysicalP2\' +
        'EpinelUserProgressionSoloMenuGolden-v1'
    ),
    [string]$ConsoleTranscriptPath = (
        'C:\Users\zih44\.codex\attachments\' +
        '18942346-99a6-4c33-bbd6-5b1b3312a8d2\pasted-text.txt'
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

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllText(
        $Path,
        (($Value | ConvertTo-Json -Depth 16) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
}

function Copy-VerifiedFile {
    param(
        [string]$Source,
        [string]$Destination,
        [string]$ExpectedSha256 = ''
    )

    Assert-True (Test-Path -LiteralPath $Source -PathType Leaf) `
        ('phase3b2_solo_menu_golden_source_missing:' + $Source)
    $sourceSha256 = Get-Sha256Hex $Source
    if ($ExpectedSha256) {
        Assert-True (
            $sourceSha256 -ceq $ExpectedSha256.ToLowerInvariant()
        ) ('phase3b2_solo_menu_golden_source_drifted:' + $Source)
    }

    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $partial = $Destination + '.partial-' + [Guid]::NewGuid().ToString('N')
    Copy-Item -LiteralPath $Source -Destination $partial
    Assert-True ((Get-Sha256Hex $partial) -ceq $sourceSha256) `
        ('phase3b2_solo_menu_golden_copy_digest_invalid:' + $Destination)
    Move-Item -LiteralPath $partial -Destination $Destination
}

function Get-FileDescriptor {
    param([string]$Root, [string]$Path)

    $rootPrefix = $Root.TrimEnd('\') + '\'
    Assert-True ($Path.StartsWith(
            $rootPrefix,
            [StringComparison]::OrdinalIgnoreCase
        )) 'phase3b2_solo_menu_golden_manifest_path_outside_root'
    $item = Get-Item -LiteralPath $Path
    return [ordered]@{
        relativePath = $Path.Substring($rootPrefix.Length).
            Replace('\', '/')
        byteLength = [long]$item.Length
        sha256 = Get-Sha256Hex $Path
    }
}

$micronDrive = $MicronDriveLetter + ':'
$backupRootResolved = [IO.Path]::GetFullPath($BackupRoot)
$parentFullGoldenRootResolved = [IO.Path]::GetFullPath(
    $ParentFullGoldenRoot
)
$protectedRootResolved = [IO.Path]::GetFullPath($ProtectedRoot)
Assert-True ($backupRootResolved.StartsWith(
        'D:\NikkeLocalLab\Backups\',
        [StringComparison]::OrdinalIgnoreCase
    )) 'phase3b2_solo_menu_golden_backup_root_invalid'
Assert-True ($parentFullGoldenRootResolved.StartsWith(
        'D:\NikkeLocalLab\Backups\',
        [StringComparison]::OrdinalIgnoreCase
    )) 'phase3b2_solo_menu_golden_parent_root_invalid'
Assert-True ($protectedRootResolved.StartsWith(
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\',
        [StringComparison]::OrdinalIgnoreCase
    )) 'phase3b2_solo_menu_golden_protected_root_invalid'

$systemDisk = Get-Partition -DriveLetter C | Get-Disk
$micronDisk = Get-Partition -DriveLetter $MicronDriveLetter | Get-Disk
Assert-True (
    $env:SystemDrive -ceq 'C:' -and
    $systemDisk.FriendlyName -like 'Samsung SSD 980*' -and
    $micronDisk.FriendlyName -like 'Micron_2200*' -and
    (Test-Path -LiteralPath (
        Join-Path $micronDrive 'Windows\System32'
    ) -PathType Container)
) 'phase3b2_solo_menu_golden_wrong_disk_boundary'

$runtimeProcesses = @(Get-Process -Name @(
        'EpinelPS', 'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
    ) -ErrorAction SilentlyContinue)
Assert-True ($runtimeProcesses.Count -eq 0) `
    'phase3b2_solo_menu_golden_runtime_not_cold'
$currentBootOfficialProcessCount = @(Get-Process -Name @(
        'NIKKE', 'nikke_launcher'
    ) -ErrorAction SilentlyContinue).Count

$physicalRoot = Join-Path $micronDrive `
    'NLL\Evidence\Phase3B2\Physical\epinel-user-progression-v2'
$runRoot = Join-Path $physicalRoot $AssessmentUid
$activePointerPath = Join-Path $physicalRoot 'active-run.pointer.json'
$applicationPath = Join-Path $physicalRoot 'application.receipt.json'
$candidateReceiptPath = Join-Path $physicalRoot `
    'candidate-staging.receipt.json'
$strictAuditPath = Join-Path $physicalRoot 'strict-audit.receipt.json'
$runStartPath = Join-Path $runRoot 'run-start.receipt.json'
$bindingPath = Join-Path $runRoot 'native-cache.binding.receipt.json'
$measurementPath = Join-Path $runRoot 'startup.measurement.json'
$dbBeforePath = Join-Path $runRoot 'db.before.bin'
$completionPath = Join-Path $runRoot 'completion.receipt.json'
$serverRoot = Join-Path $micronDrive (
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
)
$activeDatabasePath = Join-Path $serverRoot 'db.json'
$serverDllPath = Join-Path $serverRoot 'EpinelPS.dll'
$hostsPath = Join-Path $micronDrive `
    'Windows\System32\drivers\etc\hosts'
$screenshotDirectory = Join-Path $micronDrive `
    'Users\nlloperator\Pictures\Screenshots'
$screenshotOne = @(Get-ChildItem -LiteralPath $screenshotDirectory `
    -File -Force | Where-Object {
        $_.Name.EndsWith(
            '2026-08-27 003357.png',
            [StringComparison]::OrdinalIgnoreCase
        )
    })
$screenshotTwo = @(Get-ChildItem -LiteralPath $screenshotDirectory `
    -File -Force | Where-Object {
        $_.Name.EndsWith(
            '2026-08-27 003703.png',
            [StringComparison]::OrdinalIgnoreCase
        )
    })
Assert-True (
    $screenshotOne.Count -eq 1 -and $screenshotTwo.Count -eq 1
) 'phase3b2_solo_menu_golden_screenshot_selection_ambiguous'
$screenshotPaths = @(
    $screenshotOne[0].FullName,
    $screenshotTwo[0].FullName
)

$expectedFiles = [ordered]@{
    $applicationPath =
        '1cdc62fc5a1c4f36d9b3845b2023057d0a0aa9246adcefc73b048d80f112958c'
    $candidateReceiptPath =
        'e63cec5246967c5b4c66fe95e23325d574a1c8bb356e3719bbd3022c4ffbf479'
    $strictAuditPath =
        'a3e4b02f6b97d4b7699b2b2420b4165af419b77dbc3b967cf5c1d3bb4d08a548'
    $runStartPath =
        'a758b03e61a878cfe2401fdb9ed2499279bd9389775d7d6184b5ebb48560ace6'
    $bindingPath =
        '53563cfc4b41c205f3818ea1d2078397eb451fb058ee03de186c7db095644cbf'
    $measurementPath =
        '9a4160547292af72d0ef6d7c63c32402369a2818c0d033ef027840dfe53490f8'
    $activePointerPath =
        'd272ca72da9de64546af1ef39394118fe05319897374a6a02e51434081b36a6e'
    $dbBeforePath =
        'd73e92c9e8159b347f42eff5c6c2270e3695e91cd542c05f45bcbb121cd9a1ee'
    $serverDllPath =
        'aaa1e49d7a879a6b5ec17ad4c4094ce7d98ce86f860c1529a9ab4d6aecb51f7c'
}
foreach ($entry in $expectedFiles.GetEnumerator()) {
    Assert-True (Test-Path -LiteralPath $entry.Key -PathType Leaf) `
        ('phase3b2_solo_menu_golden_required_input_missing:' + $entry.Key)
    Assert-True ((Get-Sha256Hex $entry.Key) -ceq $entry.Value) `
        ('phase3b2_solo_menu_golden_required_input_drifted:' + $entry.Key)
}
Assert-True (-not (Test-Path -LiteralPath $completionPath)) `
    'phase3b2_solo_menu_golden_completion_must_remain_unfabricated'

$pointer = Get-Content -LiteralPath $activePointerPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$runStart = Get-Content -LiteralPath $runStartPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$binding = Get-Content -LiteralPath $bindingPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$application = Get-Content -LiteralPath $applicationPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
$candidate = Get-Content -LiteralPath $candidateReceiptPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
$strictAudit = Get-Content -LiteralPath $strictAuditPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
Assert-True (
    $pointer.contractId -ceq
        'nll/phase3b2-epinel-minimal-active-run-pointer/v1' -and
    $pointer.assessmentUid -ceq $AssessmentUid -and
    $pointer.databaseBeforeSha256 -ceq $expectedFiles[$dbBeforePath] -and
    $runStart.contractId -ceq
        'nll/phase3b2-epinel-minimal-reference-start/v1' -and
    $runStart.assessmentUid -ceq $AssessmentUid -and
    $runStart.requiredLocalCatalogAllSqlite -and
    $runStart.requiredLocalSausBodyCrc32Matched -and
    $runStart.successfulNonLoopbackConnectionCount -eq 0 -and
    -not $runStart.officialOutboundFallbackUsed -and
    -not $runStart.officialLauncherExecutionStarted -and
    $binding.contractId -ceq
        'nll/phase3b2-epinel-user-progression-run-binding/v2' -and
    $binding.assessmentUid -ceq $AssessmentUid -and
    $binding.candidateDatabaseSha256 -ceq $expectedFiles[$dbBeforePath] -and
    $binding.activeCacheFileCount -eq 40113 -and
    [long]$binding.activeCacheContentByteLength -eq 39031656543L -and
    $application.contractId -ceq
        'nll/phase3b2-epinel-user-progression-v2-offline-application/v1' -and
    $application.applicationUid -ceq
        '45845cb4-85d0-490d-9cbe-a507700c2e00' -and
    $candidate.contractId -ceq
        'nll/phase3b2-user-progression-offline-candidate-staging/v2' -and
    $candidate.assessmentUid -ceq
        'a69002f5-14e9-4f05-b9ab-9ca58b13925a' -and
    $strictAudit.contractId -ceq
        'nll/phase3b2-user-progression-strict-offline-audit/v1' -and
    $strictAudit.verdictCode -ceq
        'strict_static_json_and_relational_gates_passed'
) 'phase3b2_solo_menu_golden_contract_shape_invalid'

$toolContracts = @(
    [ordered]@{
        roleCode = 'parent_golden_outer_start'
        leaf = 'Start-Phase3B2-Epinel-LocaleOverlay-en-v2.ps1'
        sha256 = '50ead5cce82a602d67ee3edd114449c8ceb19a178fa8ce921d3d42d565a6646c'
    },
    [ordered]@{
        roleCode = 'parent_golden_inner_start'
        leaf = 'start-phase3b2-epinel-minimal-reference-in-micron.ps1'
        sha256 = 'a039cd5186df92c16c0091f7d4b4c4bbb907d0bf2adc3ff94d8d425699bc5f69'
    },
    [ordered]@{
        roleCode = 'parent_golden_outer_completion'
        leaf = 'Complete-Phase3B2-Epinel-Minimal.ps1'
        sha256 = '16aa339bc83336b6bd3c72da21624eb890e336e22fb1c9672160fa745b0250c1'
    },
    [ordered]@{
        roleCode = 'parent_golden_inner_completion'
        leaf = 'complete-phase3b2-epinel-minimal-reference-in-micron.ps1'
        sha256 = '0ff9cc8285b46fe96d16fe1fe1aca532a6a2b39d89cc9a15f6c611444d63fe09'
    },
    [ordered]@{
        roleCode = 'derived_progression_outer_start'
        leaf = 'Start-Phase3B2-Epinel-UserProgression-v2.ps1'
        sha256 = 'dad26036cf2f9bb364c40869a0056c043ca6439352a36f08f456085f93f016f1'
    },
    [ordered]@{
        roleCode = 'derived_progression_inner_start'
        leaf = 'start-phase3b2-epinel-user-progression-v2-in-micron.ps1'
        sha256 = '6a503087ffa89d45631d13783351810f2633fb1e51b18faef44f1f9771eee8de'
    },
    [ordered]@{
        roleCode = 'derived_progression_outer_completion'
        leaf = 'Complete-Phase3B2-Epinel-UserProgression-v2.ps1'
        sha256 = 'a3521aa2c5b2ffec2e80068e2ead03b5c8976fe4d2d747c2c0990f09180d83f3'
    },
    [ordered]@{
        roleCode = 'derived_progression_inner_completion'
        leaf = 'complete-phase3b2-epinel-user-progression-v2-in-micron.ps1'
        sha256 = '96155783acae84d4dc3296f692a3227d485fec090a503c1782db535da2790356'
    }
)
foreach ($tool in $toolContracts) {
    $toolPath = Join-Path $micronDrive ('NLL\Tools\' + $tool.leaf)
    Assert-True (
        (Test-Path -LiteralPath $toolPath -PathType Leaf) -and
        (Get-Sha256Hex $toolPath) -ceq $tool.sha256
    ) ('phase3b2_solo_menu_golden_tool_drifted:' + $tool.roleCode)
}

$sqlitePaths = @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal' |
    ForEach-Object { Join-Path $serverRoot $_ })
$sqlitePresentCount = @($sqlitePaths | Where-Object {
    Test-Path -LiteralPath $_ -PathType Leaf
}).Count
Assert-True (
    (Get-Sha256Hex $activeDatabasePath) -ceq
        'b072a44b37ea9fadb99d21ecc45b1b8430e7c443e3799739ec3c3a7911d0f031' -and
    $sqlitePresentCount -eq 3 -and
    (Get-Sha256Hex $hostsPath) -ceq
        '3b0dcc4396373e9e9d623ef05c345f89330427ad5128727290c9f76138e22f64'
) 'phase3b2_solo_menu_golden_abandoned_runtime_shape_invalid'

$parentSealPath = Join-Path $parentFullGoldenRootResolved `
    'metadata\backup.seal.receipt.json'
$parentManifestPath = Join-Path $parentFullGoldenRootResolved `
    'metadata\content.sha256.tsv'
Assert-True (
    (Test-Path -LiteralPath $parentSealPath -PathType Leaf) -and
    (Get-Sha256Hex $parentSealPath) -ceq
        'e4c1f9af044387f1624a828421800b29c9a0aa4c015f4e82f3534f70484ea613' -and
    (Test-Path -LiteralPath $parentManifestPath -PathType Leaf) -and
    (Get-Sha256Hex $parentManifestPath) -ceq
        '5fbde8b30acf3f97ee90bc77e271161cd6e0fba23f474a5d1a845ee3fa2c0fc9'
) 'phase3b2_solo_menu_golden_parent_backup_invalid'

foreach ($path in @($screenshotPaths + $ConsoleTranscriptPath)) {
    Assert-True (Test-Path -LiteralPath $path -PathType Leaf) `
        ('phase3b2_solo_menu_golden_observation_missing:' + $path)
}

if (-not (Test-Path -LiteralPath $backupRootResolved -PathType Container)) {
    New-Item -ItemType Directory -Path $backupRootResolved -Force |
        Out-Null
}
if (-not (Test-Path -LiteralPath $protectedRootResolved `
        -PathType Container)) {
    New-Item -ItemType Directory -Path $protectedRootResolved -Force |
        Out-Null
}

$sealUid = [Guid]::NewGuid().ToString('D')
$sealRoot = Join-Path $backupRootResolved $sealUid
$partialRoot = Join-Path $backupRootResolved (
    '.staging-' + $sealUid.Substring(0, 8)
)
$protectedSealRoot = Join-Path $protectedRootResolved $sealUid
Assert-True (
    -not (Test-Path -LiteralPath $sealRoot) -and
    -not (Test-Path -LiteralPath $partialRoot) -and
    -not (Test-Path -LiteralPath $protectedSealRoot)
) 'phase3b2_solo_menu_golden_destination_collision'
New-Item -ItemType Directory -Path $partialRoot | Out-Null

Copy-VerifiedFile $dbBeforePath `
    (Join-Path $partialRoot 'artifacts\runtime\db.json') `
    $expectedFiles[$dbBeforePath]
foreach ($tool in $toolContracts) {
    Copy-VerifiedFile `
        (Join-Path $micronDrive ('NLL\Tools\' + $tool.leaf)) `
        (Join-Path $partialRoot ('artifacts\tools\' + $tool.leaf)) `
        $tool.sha256
}
Copy-VerifiedFile $serverDllPath `
    (Join-Path $partialRoot 'artifacts\runtime\EpinelPS.dll') `
    $expectedFiles[$serverDllPath]

foreach ($source in @(
        $applicationPath, $candidateReceiptPath, $strictAuditPath,
        $runStartPath, $bindingPath, $measurementPath
    )) {
    Copy-VerifiedFile $source (
        Join-Path $partialRoot ('evidence\receipts\' +
            (Split-Path -Leaf $source))
    ) $expectedFiles[$source]
}
Copy-VerifiedFile $screenshotPaths[0] `
    (Join-Path $partialRoot 'evidence\screenshots\solo-raid-ended.png')
Copy-VerifiedFile $screenshotPaths[1] `
    (Join-Path $partialRoot 'evidence\screenshots\solo-raid-menu.png')
Copy-VerifiedFile $ConsoleTranscriptPath `
    (Join-Path $partialRoot 'evidence\console\start-and-completion-attempt.txt')

$repositorySources = @(
    'scripts\Start-Phase3B2-Epinel-UserProgression-v2.ps1',
    'scripts\start-phase3b2-epinel-user-progression-v2-in-micron.ps1',
    'scripts\Complete-Phase3B2-Epinel-UserProgression-v2.ps1',
    'scripts\complete-phase3b2-epinel-user-progression-v2-in-micron.ps1',
    'scripts\deploy-phase3b2-epinel-user-progression-v2-offline.ps1',
    'scripts\rollback-phase3b2-epinel-user-progression-v2-offline.ps1',
    'scripts\build-phase3b2-user-progression-candidate-offline.ps1',
    'scripts\verify-phase3b2-user-progression-candidate-strict-offline.ps1',
    'scripts\seal-phase3b2-user-progression-solo-menu-golden-offline.ps1',
    'docs\archive\PHASE3B2_USER_PROGRESSION_RECONSTRUCTION_PLAN.md'
)
foreach ($relative in $repositorySources) {
    $source = Join-Path $PSScriptRoot ('..\' + $relative)
    Copy-VerifiedFile $source (
        Join-Path $partialRoot ('source\' + $relative)
    )
}

$observation = [ordered]@{
    schemaVersion = 1
    contractId =
        'nll/phase3b2-user-progression-solo-menu-observation/v1'
    observedAtLocal = '2026-08-27T00:33:57+09:00'
    assessmentUid = $AssessmentUid
    evidenceBasisCode = 'operator_report_plus_two_screenshots'
    lobbyReached = $true
    soloRaidMenuReached = $true
    displayedBossCode = 'providence'
    displayedSeasonEndingText = '4D 8H Left'
    challengeButtonVisible = $true
    battleEntryAttempted = $true
    battleEntrySucceeded = $false
    battleEntryBlockCode = 'season_ended_popup'
    battleEntryBlockText =
        'The season has ended. See you at the next season.'
    normalLevelStateCode = 'level_1_open_levels_2_through_7_locked'
    requiredNormalLevelStateCode = 'levels_1_through_7_cleared'
    normalLevelsOneThroughSevenClearVerified = $false
    soloRaidActualBattleVerified = $false
    goldenScopeCode = 'lobby_and_solo_raid_menu_entry_checkpoint'
    battleQualifiedGolden = $false
    outstandingIssueCodes = @(
        'solo_raid_season_admission_rejected',
        'solo_raid_normal_levels_1_through_7_not_cleared'
    )
}
Write-JsonUtf8NoBom `
    (Join-Path $partialRoot 'evidence\observation.receipt.json') `
    $observation

$parentReference = [ordered]@{
    schemaVersion = 1
    contractId =
        'nll/phase3b2-user-progression-solo-menu-parent-reference/v1'
    parentFullGoldenRoot = $parentFullGoldenRootResolved
    parentBackupSealReceiptSha256 = Get-Sha256Hex $parentSealPath
    parentContentManifestSha256 = Get-Sha256Hex $parentManifestPath
    parentModified = $false
    restoreCompositionCode =
        'restore_parent_full_golden_then_apply_this_verified_overlay'
}
Write-JsonUtf8NoBom `
    (Join-Path $partialRoot 'metadata\parent.reference.json') `
    $parentReference

$restorePlan = [ordered]@{
    schemaVersion = 1
    contractId =
        'nll/phase3b2-user-progression-solo-menu-restore-plan/v1'
    sealUid = $sealUid
    requiredEnvironmentCode =
        'samsung_boot_micron_offline_runtime_cold'
    restoreParentFirst = $true
    parentFullGoldenRoot = $parentFullGoldenRootResolved
    overlayDatabaseRelativePath = 'artifacts/runtime/db.json'
    overlayDatabaseTarget = $activeDatabasePath
    overlayToolDirectoryRelativePath = 'artifacts/tools'
    overlayToolTarget = Join-Path $micronDrive 'NLL\Tools'
    doNotRestoreRoleCodes = @(
        'active_run_pointer', 'sqlite_runtime', 'applied_hosts',
        'server_logs', 'operator_locallow'
    )
    requireSqliteAbsentBeforeNextRun = $true
    requireBaseHostsBeforeNextRun = $true
    requireExtensionFirewallAbsentBeforeNextRun = $true
    parentGoldenToolsMustRemainUnchanged = $true
}
Write-JsonUtf8NoBom `
    (Join-Path $partialRoot 'metadata\restore.plan.json') `
    $restorePlan

$manifestFiles = @(Get-ChildItem -LiteralPath $partialRoot -File -Recurse)
$manifestMembers = @($manifestFiles | ForEach-Object {
    Get-FileDescriptor -Root $partialRoot -Path $_.FullName
} | Sort-Object relativePath)
$canonical = (@($manifestMembers | ForEach-Object {
    '{0}`t{1}`t{2}`n' -f $_.relativePath, $_.byteLength, $_.sha256
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
$manifest = [ordered]@{
    schemaVersion = 1
    contractId =
        'nll/phase3b2-user-progression-solo-menu-overlay-manifest/v1'
    sealUid = $sealUid
    canonicalization = 'relative_path_tab_byte_length_tab_sha256_lf_v1'
    memberCount = $manifestMembers.Count
    canonicalSha256 = $canonicalSha256
    members = $manifestMembers
}
$manifestPath = Join-Path $partialRoot 'metadata\overlay.manifest.json'
Write-JsonUtf8NoBom $manifestPath $manifest
$manifestSha256 = Get-Sha256Hex $manifestPath

$receipt = [ordered]@{
    schemaVersion = 1
    contractId =
        'nll/phase3b2-user-progression-solo-menu-golden-seal/v1'
    sealedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    sealUid = $sealUid
    environmentCode = 'samsung_boot_micron_offline_runtime_cold'
    currentSamsungOfficialProcessCountIgnored =
        $currentBootOfficialProcessCount
    currentSamsungOfficialProcessesModified = $false
    assessmentUid = $AssessmentUid
    applicationUid = [string]$application.applicationUid
    candidateAssessmentUid = [string]$candidate.assessmentUid
    strictAuditUid = [string]$strictAudit.auditUid
    runStartReceiptSha256 = Get-Sha256Hex $runStartPath
    runBindingReceiptSha256 = Get-Sha256Hex $bindingPath
    candidateDatabaseByteLength = (Get-Item $dbBeforePath).Length
    candidateDatabaseSha256 = Get-Sha256Hex $dbBeforePath
    candidateDatabaseCopiedFromImmutableRunInput = $true
    mutatedRuntimeDatabaseCopied = $false
    sqliteRuntimeCopied = $false
    activeRunPointerCopied = $false
    appliedHostsCopied = $false
    serverLogCopied = $false
    parentFullGoldenReferenceVerified = $true
    parentFullGoldenModified = $false
    parentGoldenToolCount = 4
    derivedProgressionToolCount = 4
    serverDllSha256 = Get-Sha256Hex $serverDllPath
    cacheFileCount = [int]$binding.activeCacheFileCount
    cacheContentByteLength = [long]$binding.activeCacheContentByteLength
    cacheCopiedAgain = $false
    cacheInheritedFromParentFullGolden = $true
    cacheModified = $false
    localLowInspected = $false
    localLowModified = $false
    cccccCacheInspected = $false
    cccccCacheModified = $false
    officialOutboundUsed = $false
    lobbyReached = $true
    soloRaidMenuReached = $true
    soloRaidActualBattleVerified = $false
    normalLevelsOneThroughSevenClearVerified = $false
    goldenScopeCode = 'lobby_and_solo_raid_menu_entry_checkpoint'
    cleanupPending = $true
    cleanupPendingReasonCode =
        'operator_completion_command_had_trailing_backtick_before_reboot'
    overlayManifestByteLength = (Get-Item $manifestPath).Length
    overlayManifestSha256 = $manifestSha256
    overlayManifestCanonicalSha256 = $canonicalSha256
    nextStepCode =
        'finalize_abandoned_micron_run_then_classify_solo_raid_admission'
}
$receiptPath = Join-Path $partialRoot 'metadata\seal.receipt.json'
Write-JsonUtf8NoBom $receiptPath $receipt
$receiptSha256 = Get-Sha256Hex $receiptPath

Move-Item -LiteralPath $partialRoot -Destination $sealRoot
New-Item -ItemType Directory -Path $protectedSealRoot | Out-Null
Copy-VerifiedFile (Join-Path $sealRoot 'metadata\seal.receipt.json') `
    (Join-Path $protectedSealRoot 'seal.receipt.json') $receiptSha256
Copy-VerifiedFile (Join-Path $sealRoot 'metadata\overlay.manifest.json') `
    (Join-Path $protectedSealRoot 'overlay.manifest.json') $manifestSha256
Copy-VerifiedFile (Join-Path $sealRoot 'evidence\observation.receipt.json') `
    (Join-Path $protectedSealRoot 'observation.receipt.json')
Copy-VerifiedFile (Join-Path $sealRoot 'metadata\restore.plan.json') `
    (Join-Path $protectedSealRoot 'restore.plan.json')

Get-ChildItem -LiteralPath $sealRoot -File -Recurse | ForEach-Object {
    $_.IsReadOnly = $true
}
Get-ChildItem -LiteralPath $protectedSealRoot -File | ForEach-Object {
    $_.IsReadOnly = $true
}

[ordered]@{
    Receipt = $receipt
    BackupRoot = $sealRoot
    ReceiptPath = Join-Path $sealRoot 'metadata\seal.receipt.json'
    ReceiptByteLength = (Get-Item (
        Join-Path $sealRoot 'metadata\seal.receipt.json'
    )).Length
    ReceiptSha256 = $receiptSha256
    ProtectedReceiptPath = Join-Path $protectedSealRoot `
        'seal.receipt.json'
} | ConvertTo-Json -Depth 16
