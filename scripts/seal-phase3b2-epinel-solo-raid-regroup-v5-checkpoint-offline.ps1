#requires -Version 5.1

[CmdletBinding()]
param(
    [ValidatePattern('^[D-Z]$')]
    [string]$MicronDriveLetter = 'E',
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$AssessmentUid =
        'd7d5b339-4b66-4403-9dda-229cab797abf',
    [string]$BackupRoot = (
        'D:\NikkeLocalLab\Backups\' +
        'phase3b2-season26-challenge-regroup-v5-checkpoint-v1'
    ),
    [string]$ParentFullGoldenRoot = (
        'D:\NikkeLocalLab\Backups\' +
        'phase3b2-lobby-en-d830a90d-20260826T103327Z'
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
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).
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
        (($Value | ConvertTo-Json -Depth 20) + [Environment]::NewLine),
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
        ('phase3b2_regroup_v5_checkpoint_source_missing:' + $Source)
    $sourceSha256 = Get-Sha256Hex $Source
    if ($ExpectedSha256) {
        Assert-True (
            $sourceSha256 -ceq $ExpectedSha256.ToLowerInvariant()
        ) ('phase3b2_regroup_v5_checkpoint_source_drifted:' + $Source)
    }

    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $partial = $Destination + '.partial-' + [Guid]::NewGuid().ToString('N')
    Copy-Item -LiteralPath $Source -Destination $partial
    Assert-True ((Get-Sha256Hex $partial) -ceq $sourceSha256) `
        ('phase3b2_regroup_v5_checkpoint_copy_invalid:' + $Destination)
    Move-Item -LiteralPath $partial -Destination $Destination
}

function Get-FileDescriptor {
    param([string]$Root, [string]$Path)

    $rootPrefix = $Root.TrimEnd('\') + '\'
    Assert-True ($Path.StartsWith(
            $rootPrefix,
            [StringComparison]::OrdinalIgnoreCase
        )) 'phase3b2_regroup_v5_checkpoint_manifest_path_outside_root'
    $item = Get-Item -LiteralPath $Path
    [ordered]@{
        relativePath = $Path.Substring($rootPrefix.Length).Replace('\', '/')
        byteLength = [long]$item.Length
        sha256 = Get-Sha256Hex $Path
    }
}

$micronDrive = $MicronDriveLetter + ':'
$backupRootResolved = [IO.Path]::GetFullPath($BackupRoot)
$parentRootResolved = [IO.Path]::GetFullPath($ParentFullGoldenRoot)
Assert-True ($backupRootResolved.StartsWith(
        'D:\NikkeLocalLab\Backups\',
        [StringComparison]::OrdinalIgnoreCase
    )) 'phase3b2_regroup_v5_checkpoint_backup_root_invalid'
Assert-True ($parentRootResolved.StartsWith(
        'D:\NikkeLocalLab\Backups\',
        [StringComparison]::OrdinalIgnoreCase
    )) 'phase3b2_regroup_v5_checkpoint_parent_root_invalid'
Assert-True (-not $backupRootResolved.Equals(
        $parentRootResolved,
        [StringComparison]::OrdinalIgnoreCase
    )) 'phase3b2_regroup_v5_checkpoint_parent_overwrite_forbidden'

$systemDisk = Get-Partition -DriveLetter C | Get-Disk
$micronDisk = Get-Partition -DriveLetter $MicronDriveLetter | Get-Disk
Assert-True (
    $env:SystemDrive -ceq 'C:' -and
    $env:USERNAME -ceq 'zih44' -and
    $systemDisk.FriendlyName -like 'Samsung SSD 980*' -and
    $micronDisk.FriendlyName -like 'Micron_2200*' -and
    (Test-Path -LiteralPath (
        Join-Path $micronDrive 'Windows\System32'
    ) -PathType Container)
) 'phase3b2_regroup_v5_checkpoint_wrong_disk_boundary'

Assert-True (@(Get-Process -Name @(
            'NIKKE', 'nikke_launcher', 'EpinelPS',
            'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
        ) -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_regroup_v5_checkpoint_runtime_not_cold'

$runtimeRoot = Join-Path $micronDrive `
    'NLL\Runtime\EpinelPS-SoloRaidRegroupRepair-v5'
$evidenceRoot = Join-Path $micronDrive 'NLL\E\P3SRGR5'
$deploymentRoot = Join-Path $micronDrive 'NLL\E\P3SRGR5D'
$runRoot = Join-Path $evidenceRoot $AssessmentUid
$deploymentPath = Join-Path $deploymentRoot 'deployment.receipt.json'
$sourceManifestPath = Join-Path $deploymentRoot 'source.manifest.tsv'
$repairPath = Join-Path $deploymentRoot (
    'completion-repair-v1\12983c84-a285-43f6-9a7e-0904a4b10948\' +
    'repair.receipt.json'
)
$runStartPath = Join-Path $runRoot 'run-start.receipt.json'
$completionPath = Join-Path $runRoot 'completion.receipt.json'
$markerPath = Join-Path $runRoot 'regroup.observations.json'
$measurementPath = Join-Path $runRoot 'startup.measurement.json'
$archivedPointerPath = Join-Path $runRoot 'active-run.pointer.archived.json'
$activePointerPath = Join-Path $evidenceRoot 'active-run.pointer.json'
$hostsPath = Join-Path $micronDrive 'Windows\System32\drivers\etc\hosts'
$cacheLinkPath = Join-Path $runtimeRoot 'cache'
$runtimeLogsPath = Join-Path $runtimeRoot 'logs'

$expected = [ordered]@{
    deployment =
        '90179010e5c82fba6ff4d699fb0f913fa0f878b1100938e74645a3555752dc8a'
    sourceManifest =
        '1a1cb7b110bcf2ba7cf3c4bb0a3c6f681df4d60112dd9bb523c71d3b3dc83030'
    completionRepair =
        'd3e80b6e8598b127a3f4515810c39df3f959fec5273c10336e8df56c281eabba'
    runStart =
        'e75322fd80a98c592edb6db377729b58fa3114c0cb6c3b45bfb67d73ec21f1b3'
    completion =
        '5817bc8b0c3861532e118570935f396e45175bc9e25edde2f01cd7e07ad36707'
    marker =
        '94e0237ca0e052a64edd2b80473b2a3195346580c19c393f45e1b80c0dcec047'
    runtimeDatabase =
        'dee9c6aa5421287ca030e325b81a90a302a5d9e113d57c3065e5d36f6e7c4019'
    serverDll =
        '9f350c9ba11df44365d890439f588fd29734e1ded14026934fea1c02bfed4c42'
    serverExe =
        'a28c7ff227a74d260a29389b82caeed3fe196f91eef3d28cabe9977b5ed9d07b'
    infoLogConfig =
        '31b873b3ad156436f0a55f54f1518fde9e2e6c0059cca3ec2e3b181c08c448b9'
    baseHosts =
        'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0'
    parentSeal =
        'e4c1f9af044387f1624a828421800b29c9a0aa4c015f4e82f3534f70484ea613'
    parentManifest =
        '5fbde8b30acf3f97ee90bc77e271161cd6e0fba23f474a5d1a845ee3fa2c0fc9'
}

$requiredEvidence = [ordered]@{
    $deploymentPath = $expected.deployment
    $sourceManifestPath = $expected.sourceManifest
    $repairPath = $expected.completionRepair
    $runStartPath = $expected.runStart
    $completionPath = $expected.completion
    $markerPath = $expected.marker
}
foreach ($entry in $requiredEvidence.GetEnumerator()) {
    Assert-True (
        (Test-Path -LiteralPath $entry.Key -PathType Leaf) -and
        (Get-Sha256Hex $entry.Key) -ceq $entry.Value
    ) ('phase3b2_regroup_v5_checkpoint_evidence_invalid:' + $entry.Key)
}
foreach ($path in @($measurementPath, $archivedPointerPath)) {
    Assert-True (Test-Path -LiteralPath $path -PathType Leaf) `
        ('phase3b2_regroup_v5_checkpoint_evidence_missing:' + $path)
}

$deployment = Get-Content -LiteralPath $deploymentPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$repair = Get-Content -LiteralPath $repairPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$runStart = Get-Content -LiteralPath $runStartPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$completion = Get-Content -LiteralPath $completionPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$marker = Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True (
    $deployment.contractId -ceq
        'nll/phase3b2-epinel-solo-raid-regroup-repair-deployment/v5' -and
    $deployment.deploymentUid -ceq
        '0d15b29e-3ff4-47cd-a129-c62f1e980567' -and
    [int]$deployment.selectedManagerPassedCount -eq 101 -and
    [int]$deployment.selectedManagerFailedCount -eq 0 -and
    [int]$deployment.observedRegroupBattleResult -eq 6 -and
    [int]$deployment.legacyRetryBattleResultPreserved -eq 4 -and
    -not $deployment.databaseModified -and
    -not $deployment.cacheModified -and
    -not $deployment.parentRuntimeModified -and
    -not $deployment.dLobbyGoldenModified -and
    $repair.contractId -ceq
        'nll/phase3b2-epinel-solo-raid-regroup-completion-repair/v1' -and
    $repair.assessmentUid -ceq $AssessmentUid -and
    $repair.repairedInnerCompletionSha256 -ceq
        'cbb2fb3dd75ca038e5da8afcd128ef20c07710973eadefa79866353b8b5f1a90' -and
    $runStart.contractId -ceq
        'nll/phase3b2-epinel-solo-raid-regroup-repair-start/v5' -and
    $runStart.assessmentUid -ceq $AssessmentUid -and
    $runStart.runIntentCode -ceq 'challenge' -and
    $runStart.successfulNonLoopbackConnectionCount -eq 0 -and
    -not $runStart.officialOutboundFallbackUsed -and
    -not $runStart.officialLauncherExecutionStarted -and
    $completion.contractId -ceq
        'nll/phase3b2-epinel-solo-raid-regroup-repair-completion/v5' -and
    $completion.assessmentUid -ceq $AssessmentUid -and
    $completion.databaseRestored -and
    $completion.hostsRestored -and
    $completion.extensionFirewallRemoved -and
    $completion.runtimeColdAfterCompletion -and
    $completion.regroupNonConsumptionVerified -and
    -not $completion.rawRequestPayloadPersistedAfterCompletion -and
    -not $completion.rawSensitiveServerLogPersisted -and
    $completion.runtimeAppLogsRemoved -and
    $marker.contractId -ceq
        'nll/phase3b2-epinel-solo-raid-regroup-marker-evidence/v5' -and
    $marker.assessmentUid -ceq $AssessmentUid -and
    -not $marker.rawRequestPayloadPersisted
) 'phase3b2_regroup_v5_checkpoint_contract_shape_invalid'

$observations = @($marker.observations)
$regroupCount = @($observations | Where-Object {
        [int]$_.battleResult -eq 6
    }).Count
$legacyRetryCount = @($observations | Where-Object {
        [int]$_.battleResult -eq 4
    }).Count
$invalidObservationCount = @($observations | Where-Object {
        [string]$_.route -cne 'soloraid_trial_setdamage' -or
        [int]$_.battleResult -notin @(4, 6)
    }).Count
$joinDelta = [long]$completion.trialMetricsAfter.raidJoinCount -
    [long]$completion.trialMetricsBefore.raidJoinCount
$recordDelta = [long]$completion.trialMetricsAfter.recordCount -
    [long]$completion.trialMetricsBefore.recordCount
$damageDelta = [long]$completion.trialMetricsAfter.totalDamage -
    [long]$completion.trialMetricsBefore.totalDamage
Assert-True (
    $observations.Count -eq 6 -and
    $regroupCount -eq 2 -and
    $legacyRetryCount -eq 4 -and
    $invalidObservationCount -eq 0 -and
    $joinDelta -eq 0 -and
    $recordDelta -eq 0 -and
    $damageDelta -eq 0
) 'phase3b2_regroup_v5_checkpoint_observation_invalid'

Assert-True (
    (Test-Path -LiteralPath $runtimeRoot -PathType Container) -and
    -not (Test-Path -LiteralPath $activePointerPath) -and
    (Get-Sha256Hex (Join-Path $runtimeRoot 'db.json')) -ceq
        $expected.runtimeDatabase -and
    (Get-Sha256Hex (Join-Path $runtimeRoot 'EpinelPS.dll')) -ceq
        $expected.serverDll -and
    (Get-Sha256Hex (Join-Path $runtimeRoot 'EpinelPS.exe')) -ceq
        $expected.serverExe -and
    (Get-Sha256Hex (Join-Path $runtimeRoot 'log4net.config')) -ceq
        $expected.infoLogConfig -and
    (Get-Sha256Hex $hostsPath) -ceq $expected.baseHosts
) 'phase3b2_regroup_v5_checkpoint_runtime_invalid'
$sqliteMemberCount = @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal' |
    ForEach-Object { Join-Path $runtimeRoot $_ } | Where-Object {
        Test-Path -LiteralPath $_ -PathType Leaf
    }).Count
$runtimeLogCount = @(Get-ChildItem -LiteralPath $runtimeLogsPath `
    -Recurse -File -Force -ErrorAction SilentlyContinue).Count
$cacheLink = Get-Item -LiteralPath $cacheLinkPath -Force
Assert-True (
    $sqliteMemberCount -eq 0 -and
    $runtimeLogCount -eq 0 -and
    ($cacheLink.Attributes -band [IO.FileAttributes]::ReparsePoint) -and
    $cacheLink.LinkType -ceq 'Junction' -and
    [string]$cacheLink.Target -ceq
        'C:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\cache'
) 'phase3b2_regroup_v5_checkpoint_cold_shape_invalid'

$parentSealPath = Join-Path $parentRootResolved `
    'metadata\backup.seal.receipt.json'
$parentManifestPath = Join-Path $parentRootResolved `
    'metadata\content.sha256.tsv'
Assert-True (
    (Test-Path -LiteralPath $parentSealPath -PathType Leaf) -and
    (Get-Sha256Hex $parentSealPath) -ceq $expected.parentSeal -and
    (Test-Path -LiteralPath $parentManifestPath -PathType Leaf) -and
    (Get-Sha256Hex $parentManifestPath) -ceq $expected.parentManifest
) 'phase3b2_regroup_v5_checkpoint_parent_invalid'

$toolContracts = @(
    [ordered]@{
        leaf = 'Start-Phase3B2-Epinel-SoloRaidRegroupRepair-v5.ps1'
        sha256 =
            'ae1c561eb813a3dd721f8aa9a2b8d0e41b75c788e6a39225b90b2b536a090c5e'
    },
    [ordered]@{
        leaf =
            'start-phase3b2-epinel-solo-raid-regroup-repair-v5-in-micron.ps1'
        sha256 =
            '9fc0d70f39b2569c3bea70e76b0e8b80aaea038b3615b863446cbf3f3fcc220c'
    },
    [ordered]@{
        leaf = 'Complete-Phase3B2-Epinel-SoloRaidRegroupRepair-v5.ps1'
        sha256 =
            '42f0dd1d9af9e34814baa1d7a4f3f760b57df861cb274a8449b872887420db69'
    },
    [ordered]@{
        leaf =
            'complete-phase3b2-epinel-solo-raid-regroup-repair-v5-in-micron.ps1'
        sha256 =
            'cbb2fb3dd75ca038e5da8afcd128ef20c07710973eadefa79866353b8b5f1a90'
    }
)
foreach ($tool in $toolContracts) {
    $toolPath = Join-Path $micronDrive ('NLL\Tools\' + $tool.leaf)
    Assert-True (
        (Test-Path -LiteralPath $toolPath -PathType Leaf) -and
        (Get-Sha256Hex $toolPath) -ceq $tool.sha256
    ) ('phase3b2_regroup_v5_checkpoint_tool_invalid:' + $tool.leaf)
}

$sourceContracts = @(
    [ordered]@{
        relative =
            '.external\EpinelPS\EpinelPS\LobbyServer\Soloraid\' +
            'SetDamageTrial.cs'
        sha256 =
            '85b2eea58be7ca84ca7dff32a8f22cd0933fe971ea19e7b5631de17c37633d73'
    },
    [ordered]@{
        relative =
            '.external\EpinelPS\EpinelPS\LobbyServer\Soloraid\' +
            'SoloRaidHelper.cs'
        sha256 =
            '58392657b4dd38537cf46903fd25302d421a5181aac04d63cbff2bc67f55908f'
    },
    [ordered]@{
        relative =
            '.external\EpinelPS\EpinelPS\LobbyServer\Soloraid\' +
            'ClassicSoloRaidRouteExecutor.cs'
        sha256 =
            'ebf52544c64df4de057913600edcf3a364d523c38e2ae37ae379fe4baa419e7c'
    },
    [ordered]@{
        relative =
            '.external\EpinelPS\tests\EpinelPS.SelectedManager.Tests\' +
            'SoloRaidRetrySemanticsTests.cs'
        sha256 =
            '83f2a101a45c2846b83947165de70200d7fb660fab44022ae9390d149c821a1f'
    }
)
foreach ($source in $sourceContracts) {
    $sourcePath = Join-Path $PSScriptRoot ('..\' + $source.relative)
    Assert-True (
        (Test-Path -LiteralPath $sourcePath -PathType Leaf) -and
        (Get-Sha256Hex $sourcePath) -ceq $source.sha256
    ) ('phase3b2_regroup_v5_checkpoint_source_invalid:' + $source.relative)
}

$inspectionScript = Join-Path $PSScriptRoot `
    'inspect-phase3b2-epinel-solo-raid-regroup-repair-v5-offline.ps1'
$inspectionRaw = (& $inspectionScript `
        -MicronDriveLetter $MicronDriveLetter `
        -AssessmentUid $AssessmentUid | Out-String)
$inspection = $inspectionRaw | ConvertFrom-Json
Assert-True (
    $inspection.contractId -ceq
        'nll/phase3b2-epinel-solo-raid-regroup-repair-inspection/v5' -and
    $inspection.verdictCode -ceq
        'observed_regroup_6_is_non_consuming_and_reentry_safe' -and
    $inspection.regroupNonConsumptionVerified
) 'phase3b2_regroup_v5_checkpoint_inspection_invalid'

if (-not (Test-Path -LiteralPath $backupRootResolved -PathType Container)) {
    New-Item -ItemType Directory -Path $backupRootResolved -Force | Out-Null
}
$sealUid = [Guid]::NewGuid().ToString('D')
$sealRoot = Join-Path $backupRootResolved $sealUid
$partialRoot = Join-Path $backupRootResolved (
    '.staging-' + $sealUid.Substring(0, 8)
)
Assert-True (
    -not (Test-Path -LiteralPath $sealRoot) -and
    -not (Test-Path -LiteralPath $partialRoot)
) 'phase3b2_regroup_v5_checkpoint_destination_collision'
New-Item -ItemType Directory -Path $partialRoot | Out-Null

$topLevelRuntimeFiles = @(Get-ChildItem -LiteralPath $runtimeRoot `
    -File -Force)
$runtimeDirectories = @(Get-ChildItem -LiteralPath $runtimeRoot `
    -Directory -Force | Where-Object {
        $_.Name -notin @('cache', 'logs')
    })
$runtimeFiles = @($topLevelRuntimeFiles)
foreach ($directory in $runtimeDirectories) {
    $runtimeFiles += @(Get-ChildItem -LiteralPath $directory.FullName `
        -Recurse -File -Force)
}
Assert-True (
    $runtimeFiles.Count -eq 578 -and
    [long]($runtimeFiles | Measure-Object Length -Sum).Sum -eq 195349065L
) 'phase3b2_regroup_v5_checkpoint_runtime_file_set_invalid'
foreach ($file in $runtimeFiles) {
    $relative = $file.FullName.Substring($runtimeRoot.Length + 1)
    Copy-VerifiedFile $file.FullName `
        (Join-Path $partialRoot ('artifacts\runtime\' + $relative))
}

foreach ($tool in $toolContracts) {
    Copy-VerifiedFile `
        (Join-Path $micronDrive ('NLL\Tools\' + $tool.leaf)) `
        (Join-Path $partialRoot ('artifacts\tools\' + $tool.leaf)) `
        $tool.sha256
}

foreach ($entry in $requiredEvidence.GetEnumerator()) {
    $leaf = Split-Path -Leaf $entry.Key
    $roleDirectory = if ($entry.Key -eq $repairPath) {
        'completion-repair'
    }
    elseif ($entry.Key -eq $deploymentPath -or
        $entry.Key -eq $sourceManifestPath) {
        'deployment'
    }
    else {
        'run'
    }
    Copy-VerifiedFile $entry.Key (
        Join-Path $partialRoot (
            'evidence\' + $roleDirectory + '\' + $leaf
        )
    ) $entry.Value
}
foreach ($path in @($measurementPath, $archivedPointerPath)) {
    Copy-VerifiedFile $path (
        Join-Path $partialRoot ('evidence\run\' + (Split-Path -Leaf $path))
    )
}
Write-JsonUtf8NoBom `
    (Join-Path $partialRoot 'evidence\final-inspection.receipt.json') `
    $inspection

foreach ($source in $sourceContracts) {
    Copy-VerifiedFile `
        (Join-Path $PSScriptRoot ('..\' + $source.relative)) `
        (Join-Path $partialRoot ('source\' + $source.relative)) `
        $source.sha256
}
$repositorySources = @(
    'scripts\deploy-phase3b2-epinel-solo-raid-regroup-repair-v5-offline.ps1',
    'scripts\inspect-phase3b2-epinel-solo-raid-regroup-repair-v5-offline.ps1',
    'scripts\seal-phase3b2-epinel-solo-raid-regroup-v5-checkpoint-offline.ps1',
    'docs\PHASE3B2_EPINEL_MINIMAL_PLAN.md',
    'docs\NEXT_STEPS.md',
    'docs\HANDOFF.md'
)
foreach ($relative in $repositorySources) {
    $sourcePath = Join-Path $PSScriptRoot ('..\' + $relative)
    Copy-VerifiedFile $sourcePath `
        (Join-Path $partialRoot ('source\' + $relative))
}

$operatorObservation = [ordered]@{
    schemaVersion = 1
    contractId =
        'nll/phase3b2-season26-challenge-regroup-operator-observation/v1'
    recordedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    assessmentUid = $AssessmentUid
    evidenceBasisCode =
        'operator_report_plus_start_completion_and_marker_receipts'
    originalClientBuild = '150.6.9'
    originalClassicSoloRaidChallengeBattleEntered = $true
    soloRaidMuseumUsed = $false
    regroupOperatorActionCount = 2
    challengeReentryAfterRegroupObserved = $true
    originalClientBattleCompletionObserved = $false
    originalClientResultScreenObserved = $false
    acceptanceScopeCode =
        'challenge_entry_and_regroup_non_consumption_only'
}
Write-JsonUtf8NoBom `
    (Join-Path $partialRoot 'evidence\operator.observation.json') `
    $operatorObservation

$parentReference = [ordered]@{
    schemaVersion = 1
    contractId =
        'nll/phase3b2-season26-challenge-regroup-parent-reference/v1'
    parentFullGoldenRoot = $parentRootResolved
    parentBackupSealReceiptSha256 = $expected.parentSeal
    parentContentManifestSha256 = $expected.parentManifest
    parentManifestRowCount = 180255
    parentManifestContentByteLength = 109198912557L
    parentModified = $false
    cacheCopiedAgain = $false
    cacheJunctionTarget = [string]$cacheLink.Target
    restoreCompositionCode =
        'restore_parent_full_golden_then_apply_verified_v5_overlay'
}
Write-JsonUtf8NoBom `
    (Join-Path $partialRoot 'metadata\parent.reference.json') `
    $parentReference

$restorePlan = [ordered]@{
    schemaVersion = 1
    contractId =
        'nll/phase3b2-season26-challenge-regroup-restore-plan/v1'
    sealUid = $sealUid
    requiredEnvironmentCode =
        'samsung_boot_micron_offline_runtime_cold'
    detachedBackupNotRuntimeBinding = $true
    restoreParentFirst = $true
    parentFullGoldenRoot = $parentRootResolved
    runtimeOverlayRelativePath = 'artifacts/runtime'
    runtimeOverlayTarget = $runtimeRoot
    toolsOverlayRelativePath = 'artifacts/tools'
    toolsOverlayTarget = Join-Path $micronDrive 'NLL\Tools'
    recreateCacheJunction = $true
    cacheJunctionTarget = [string]$cacheLink.Target
    doNotRestoreRoleCodes = @(
        'active_run_pointer', 'sqlite_runtime', 'runtime_logs',
        'applied_hosts', 'raw_player_log', 'raw_request_payload',
        'operator_locallow'
    )
    requireBaseHostsBeforeRun = $true
    requireExtensionFirewallAbsentBeforeRun = $true
    requireRuntimeColdBeforeRestore = $true
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
        'nll/phase3b2-season26-challenge-regroup-checkpoint-manifest/v1'
    sealUid = $sealUid
    canonicalization = 'relative_path_tab_byte_length_tab_sha256_lf_v1'
    memberCount = $manifestMembers.Count
    canonicalSha256 = $canonicalSha256
    members = $manifestMembers
}
$manifestPath = Join-Path $partialRoot 'metadata\content.manifest.json'
Write-JsonUtf8NoBom $manifestPath $manifest
$manifestSha256 = Get-Sha256Hex $manifestPath

$receipt = [ordered]@{
    schemaVersion = 1
    contractId =
        'nll/phase3b2-season26-challenge-regroup-v5-checkpoint-seal/v1'
    sealedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    sealUid = $sealUid
    assessmentUid = $AssessmentUid
    environmentCode = 'samsung_boot_micron_offline_runtime_cold'
    parentFullGoldenReferenceVerified = $true
    parentFullGoldenModified = $false
    dExistingBackupModified = $false
    detachedBackupNotRuntimeBinding = $true
    deploymentReceiptSha256 = $expected.deployment
    completionRepairReceiptSha256 = $expected.completionRepair
    completionReceiptSha256 = $expected.completion
    markerEvidenceSha256 = $expected.marker
    finalInspectionVerdictCode = [string]$inspection.verdictCode
    originalClassicChallengeBattleEntered = $true
    regroupBattleResult = 6
    legacyRetryBattleResult = 4
    regroupObservationCount = $regroupCount
    legacyRetryObservationCount = $legacyRetryCount
    raidJoinCountDelta = $joinDelta
    recordCountDelta = $recordDelta
    totalDamageDelta = $damageDelta
    regroupNonConsumptionVerified = $true
    challengeReentryObserved = $true
    originalBattleCompletionVerified = $false
    originalResultScreenVerified = $false
    runtimeFileCount = $runtimeFiles.Count
    runtimeContentByteLength =
        [long]($runtimeFiles | Measure-Object Length -Sum).Sum
    runtimeDatabaseSha256 = $expected.runtimeDatabase
    serverDllSha256 = $expected.serverDll
    runtimeLogsCopied = $false
    sqliteRuntimeCopied = $false
    activeRunPointerCopied = $false
    rawPlayerLogCopied = $false
    rawRequestPayloadCopied = $false
    cacheCopiedAgain = $false
    cacheInheritedFromParentFullGolden = $true
    localLowInspected = $false
    localLowModified = $false
    cccccCacheInspected = $false
    cccccCacheModified = $false
    officialOutboundUsed = $false
    contentManifestMemberCount = $manifestMembers.Count
    contentManifestByteLength = (Get-Item $manifestPath).Length
    contentManifestSha256 = $manifestSha256
    contentManifestCanonicalSha256 = $canonicalSha256
    checkpointScopeCode =
        'challenge_entry_and_regroup_non_consumption_candidate'
    nextStepCode =
        'verify_one_completed_challenge_result_without_mutating_checkpoint'
}
$receiptPath = Join-Path $partialRoot 'metadata\seal.receipt.json'
Write-JsonUtf8NoBom $receiptPath $receipt
$receiptSha256 = Get-Sha256Hex $receiptPath

Move-Item -LiteralPath $partialRoot -Destination $sealRoot
$sealedFiles = @(Get-ChildItem -LiteralPath $sealRoot -File -Recurse)
foreach ($file in $sealedFiles) {
    $file.IsReadOnly = $true
}

$sealedManifestPath = Join-Path $sealRoot 'metadata\content.manifest.json'
$sealedReceiptPath = Join-Path $sealRoot 'metadata\seal.receipt.json'
Assert-True (
    (Get-Sha256Hex $sealedManifestPath) -ceq $manifestSha256 -and
    (Get-Sha256Hex $sealedReceiptPath) -ceq $receiptSha256 -and
    @(Get-ChildItem -LiteralPath $sealRoot -File -Recurse).Count -eq
        ($manifestMembers.Count + 2)
) 'phase3b2_regroup_v5_checkpoint_post_seal_verification_failed'

[ordered]@{
    Receipt = $receipt
    BackupRoot = $sealRoot
    BackupFileCount = @(Get-ChildItem -LiteralPath $sealRoot `
        -File -Recurse).Count
    BackupContentByteLength = [long](Get-ChildItem -LiteralPath $sealRoot `
        -File -Recurse | Measure-Object Length -Sum).Sum
    ManifestPath = $sealedManifestPath
    ManifestSha256 = $manifestSha256
    ReceiptPath = $sealedReceiptPath
    ReceiptByteLength = (Get-Item $sealedReceiptPath).Length
    ReceiptSha256 = $receiptSha256
} | ConvertTo-Json -Depth 20
