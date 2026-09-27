param(
    [Parameter(Mandatory)] [string]$RepositoryRoot,
    [Parameter(Mandatory)] [string]$ConfigurationPath,
    [Parameter(Mandatory)] [string]$ExecutionRoot,
    [Parameter(Mandatory)] [ValidatePattern('^[0-9a-f-]{36}$')]
    [string]$LaunchContextUid,
    [Parameter(Mandatory)] [string]$RuntimeCandidatePath,
    [Parameter(Mandatory)] [string]$LobbyProjectionPath,
    [Parameter(Mandatory)] [ValidateRange(1, 2147483647)]
    [int]$SeasonNumber,
    [Parameter(Mandatory)] [ValidateSet('challenge', 'practice')]
    [string]$ValidationKind,
    [Parameter(Mandatory)] [ValidateSet('fire', 'water', 'wind', 'electric', 'iron')]
    [string]$WeaknessCode,
    [switch]$ValidateOnly,
    [ValidatePattern('^[0-9a-f]{64}$')] [string]$ExpectedPreparationBindingSha256,
    [string]$RuntimeSelectionPath = 'C:\NLL\ControlCenter\runtime-selection.private.json',
    [ValidateSet('parameterized/v1')][string]$RunnerEngine = 'parameterized/v1'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.PhaseDProcessIdentity.ps1')
. (Join-Path $PSScriptRoot 'Nll.PhaseDCompletion.ps1')
. (Join-Path $PSScriptRoot 'Nll.PhaseDChildProcess.ps1')
. (Join-Path $PSScriptRoot 'Nll.PhaseDPreparation.ps1')
. (Join-Path $PSScriptRoot 'Nll.PhaseDRunnerContract.ps1')
. (Join-Path $PSScriptRoot 'Nll.PhaseDRunnerSeal.ps1')

function Assert-PhaseD {
    param([bool]$Condition, [string]$Code)
    if (-not $Condition) { throw $Code }
}

function Get-Sha256Lower {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-PhaseDCacheArtifactIdentity {
    param(
        [string]$CacheRoot,
        [long]$ByteLength,
        [string]$Sha256,
        [string]$FailureCode,
        [object]$CommonDelivery = $null,
        [string]$ProfileSha256,
        [ValidateSet('fx', 'behavior')][string]$AssetRole = 'fx'
    )
    # Onboarding may acquire FX from the native client without adding it to the
    # server cache. Follow the published delivery seal to those exact originals.
    # Derived FX delivery is still checked/staged separately by the materializer.
    if ($null -ne $CommonDelivery) {
        try {
            $descriptor = Read-PhaseDPreparationJson $CommonDelivery.path $FailureCode
            Assert-PhaseD ($descriptor.sha256 -ceq $CommonDelivery.sha256 -and
                $descriptor.length -eq $CommonDelivery.length -and
                $descriptor.value.contractId -ceq 'nll/common-boss-delivery/v1' -and
                $descriptor.value.profileSha256 -ceq $ProfileSha256) $FailureCode
            $sealPin = $descriptor.value.candidateSeal
            $seal = Read-PhaseDPreparationJson $sealPin.path $FailureCode
            Assert-PhaseD ($seal.sha256 -ceq $sealPin.sha256 -and $seal.length -eq $sealPin.length -and
                $seal.value.contractId -ceq 'nll/boss-onboarding-verified-candidate/v1' -and
                $seal.value.profileSha256 -ceq $ProfileSha256) $FailureCode
            $artifacts = @($seal.value.artifacts)
            if (@($artifacts | Where-Object relativePath -CEQ ($AssetRole + '-acquisition.receipt.json')).Count -gt 0) {
                $sealedAssets = @($artifacts | Where-Object {
                    $_.relativePath.StartsWith(('acquired-' + $AssetRole + '/'), [StringComparison]::Ordinal) -and
                    $_.sha256 -ceq $Sha256
                })
                Assert-PhaseD ($ByteLength -gt 0 -and $Sha256 -cmatch '^[0-9a-f]{64}$' -and $sealedAssets.Count -gt 0) $FailureCode
                $root = [IO.Path]::GetFullPath((Split-Path -Parent $sealPin.path)).TrimEnd('\') + '\'
                foreach ($row in $sealedAssets) {
                    $relative = [string]$row.relativePath
                    Assert-PhaseD (-not [IO.Path]::IsPathRooted($relative) -and -not $relative.Contains(':') -and
                        @($relative.Replace('\', '/').Split('/') | Where-Object { $_ -cin @('', '.', '..') }).Count -eq 0) $FailureCode
                    $path = [IO.Path]::GetFullPath((Join-Path $root $relative))
                    Assert-PhaseD ($path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) $FailureCode
                    for ($cursor = $path; $cursor; $cursor = [IO.Path]::GetDirectoryName($cursor)) {
                        Assert-PhaseD (((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) $FailureCode
                    }
                    Assert-PhaseD ((Get-Item -LiteralPath $path).Length -eq $ByteLength -and
                        (Get-Sha256Lower $path) -ceq $Sha256) $FailureCode
                }
                return $sealedAssets.Count
            }
        }
        catch { throw $FailureCode }
    }
    Assert-PhaseD `
        ((Test-Path -LiteralPath $CacheRoot -PathType Container) -and
         $ByteLength -gt 0 -and $Sha256 -cmatch '^[0-9a-f]{64}$') `
        $FailureCode
    $matchCount = 0
    foreach ($candidate in Get-ChildItem -LiteralPath $CacheRoot -File -Recurse) {
        if ($candidate.Length -eq $ByteLength -and
            (Get-Sha256Lower $candidate.FullName) -ceq $Sha256) {
            $matchCount++
        }
    }
    Assert-PhaseD ($matchCount -gt 0) $FailureCode
    $matchCount
}




function Invoke-PhaseDEmergencyRollback {
    param([string]$EvidencePath, [string]$RuntimePath)
    $pointerPath = Join-Path $EvidencePath 'active-run.pointer.json'
    if (-not $jobAttempted) {
        # Stopping the management DB precedes any runtime Job. A failure in
        # between has no run pointer or runtime baseline to restore.
        Assert-PhaseD (-not (Test-Path -LiteralPath $pointerPath) -and
            -not (Test-Path -LiteralPath (Join-Path $launchRoot 'job-reservation.json')) -and
            -not (Test-Path -LiteralPath (Join-Path $launchRoot 'phase-d-child-start.identity.json')) -and
            (Get-Sha256Lower (Join-Path $RuntimePath 'db.json')) -ceq $runtimeDbSha256) `
            'phase_d_prestart_runtime_drifted'
        return $true
    }
    if ($jobAttempted -and -not (Test-Path -LiteralPath $pointerPath -PathType Leaf)) {
        # New start publishes its baseline before any mutation. No pointer means
        # no mutable start phase, but still require live same-job zero proof.
        Invoke-PhaseDWithJobZeroProof $launchRoot $runnerBundle.sha256 {
            Assert-PhaseD ((Get-Sha256Lower $runtimeDbPath) -ceq $runtimeDbSha256) 'phase_d_job_unjournaled_runtime_drift'
        }
        return $true
    }
    Assert-PhaseD `
        (Test-Path -LiteralPath $pointerPath -PathType Leaf) `
        'phase_d_emergency_rollback_pointer_missing'
    $pointer = Get-Content -LiteralPath $pointerPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    Assert-PhaseD `
        ($pointer.contractId -ceq `
            'nll/phase3b2-epinel-minimal-active-run-pointer/v1') `
        'phase_d_emergency_rollback_pointer_invalid'
    $runRoot = [IO.Path]::GetFullPath([string]$pointer.runRoot)
    Assert-PhaseD `
        ($runRoot.StartsWith(
            ([IO.Path]::GetFullPath($EvidencePath).TrimEnd('\') + '\'),
            [StringComparison]::OrdinalIgnoreCase)) `
        'phase_d_emergency_rollback_run_root_invalid'
    if ($jobAttempted) {
        Invoke-PhaseDWithJobZeroProof $launchRoot $runnerBundle.sha256 { }
        Assert-PhaseDChildrenExited -LaunchRoot $launchRoot -RuntimeStartJob $executionJob
        Protect-PhaseDJobServerLog $launchRoot $runnerBundle.sha256
        Invoke-PhaseDExecutionFxCleanup $launchRoot $runnerBundle.sha256
    } else { Stop-PhaseDVerifiedProcessSet -Pointer $pointer -Identities $runtimeProcessIdentities }
    $dbBefore = Join-Path $runRoot 'db.before.bin'
    $hostsBefore = Join-Path $runRoot 'hosts.before.bin'
    Assert-PhaseD (Test-Path -LiteralPath $dbBefore -PathType Leaf) `
        'phase_d_emergency_rollback_baseline_missing'
    $runtimeDbPath = Join-Path $RuntimePath 'db.json'
    $runtimeChanged = (Test-Path -LiteralPath $runtimeDbPath -PathType Leaf) -and
        ((Get-Sha256Lower $runtimeDbPath) -cne (Get-Sha256Lower $dbBefore))
    if ($runtimeChanged -and
        -not (Test-Path -LiteralPath $soloRaidPendingPath -PathType Leaf)) {
        if ($jobAttempted) {
            . (Join-Path $runnerBundle.root 'Nll.PhaseDRunnerOperations.ps1')
            Invoke-PhaseDRunnerCapture -Specification $runnerSpec -SourceDatabasePath $runtimeDbPath
        }
        # The recovery path owns capture when the coordinator has not received
        # an authenticated pending envelope. Never overwrite changed state here.
        if (-not (Test-Path -LiteralPath $soloRaidPendingPath -PathType Leaf)) { throw 'phase_d_raid_state_capture_missing_before_rollback' }
    }
    [IO.File]::WriteAllBytes(
        $runtimeDbPath, [IO.File]::ReadAllBytes($dbBefore))
    Assert-PhaseD `
        ((Get-Sha256Lower $runtimeDbPath) -ceq (Get-Sha256Lower $dbBefore)) `
        'phase_d_emergency_rollback_baseline_restore_failed'
    foreach ($name in @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal')) {
        $path = Join-Path $RuntimePath $name
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force
        }
    }
    if (Test-Path -LiteralPath $hostsBefore -PathType Leaf) {
        [IO.File]::WriteAllBytes(
            (Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'),
            [IO.File]::ReadAllBytes($hostsBefore))
    }
    Get-NetFirewallRule -Group 'NLL Phase3B2 Epinel Minimal Extension' `
        -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    Move-Item -LiteralPath $pointerPath `
        -Destination (Join-Path $runRoot `
            'active-run.pointer.coordinator-emergency-archived.json') -Force
    $true
}

function Test-PhaseDDerivedStartRollbackProof {
    param(
        [string]$EvidencePath,
        [string]$RuntimeDatabasePath,
        [string]$ExpectedRuntimeDatabaseSha256
    )
    try {
        $pointerPath = Join-Path $EvidencePath 'active-run.pointer.json'
        if (Test-Path -LiteralPath $pointerPath -PathType Leaf) { return $false }
        $failures = @(Get-ChildItem -LiteralPath $EvidencePath -Recurse -File `
            -Filter 'run-failure.receipt.json')
        if ($failures.Count -ne 1) { return $false }
        $failure = Get-Content -LiteralPath $failures[0].FullName -Raw -Encoding UTF8 |
            ConvertFrom-Json
        $failureRunRoot = $failures[0].Directory.FullName
        $innerHostsBaselinePath = Join-Path $failureRunRoot 'hosts.before.bin'
        $systemHostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
        $runtimeProcessesCold = @(
            Get-Process -Name nikke,EpinelPS,
                NikkeLocalLab.Phase3B2.PhysicalBootstrap `
                -ErrorAction SilentlyContinue
        ).Count -eq 0
        $innerHostsRestored =
            (Test-Path -LiteralPath $innerHostsBaselinePath -PathType Leaf) -and
            (Test-Path -LiteralPath $systemHostsPath -PathType Leaf) -and
            ((Get-Sha256Lower $systemHostsPath) -ceq
                (Get-Sha256Lower $innerHostsBaselinePath))
        $acceptedFailureContracts = @(
            'nll/phase3b2-epinel-minimal-reference-failure/v1',
            'nll/phase3b2-epinel-solo-raid-ranking-prefix-failure/v9'
        )
        if ([string]$failure.contractId -notin $acceptedFailureContracts -or
            -not [bool]$failure.automaticRollbackCompleted -or
            [bool]$failure.officialLauncherExecutionStarted -or
            [bool]$failure.officialOutboundFallbackUsed -or
            -not $runtimeProcessesCold -or
            -not $innerHostsRestored) {
            return $false
        }
        # A client may have started before a fail-closed health check rejects
        # the run. Accept the derived rollback only when the pointer is absent,
        # all pinned runtime processes are gone, hosts are restored, and the
        # runtime database exactly matches the pre-run materialization hash.
        (Test-Path -LiteralPath $RuntimeDatabasePath -PathType Leaf) -and
            ((Get-Sha256Lower $RuntimeDatabasePath) -ceq `
                $ExpectedRuntimeDatabaseSha256)
    }
    catch { $false }
}

function Set-ExecutionState {
    param(
        [string]$StatusCode,
        [Nullable[int]]$ClientProcessId = $null,
        [Nullable[int]]$WatcherProcessId = $null,
        [string]$WatcherProcessStartedAtUtc = $null,
        [string]$StartReceiptSha256 = $null,
        [string]$CompletionReceiptSha256 = $null,
        [string]$FailureCode = $null
    )
    $state = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase-d-execution-state/v1'
        launchContextUid = $LaunchContextUid
        createdAtUtc = $createdAtUtc
        accountUid = [string]$candidate.accountUid
        accountLabel = [string]$candidate.accountLabel
        accountRevisionSetSha256 = [string]$candidate.baseRevisions.revisionSetSha256
        seasonNumber = $SeasonNumber
        validationKind = $ValidationKind
        weaknessCode = $WeaknessCode
        statusCode = $StatusCode
        clientProcessId = $ClientProcessId
        watcherProcessId = $WatcherProcessId
        watcherProcessStartedAtUtc = if (
            [string]::IsNullOrWhiteSpace($WatcherProcessStartedAtUtc)) {
            $null
        } else { $WatcherProcessStartedAtUtc }
        startReceiptSha256 = if (
            [string]::IsNullOrWhiteSpace($StartReceiptSha256)) {
            $null
        } else { $StartReceiptSha256 }
        completionReceiptSha256 = if (
            [string]::IsNullOrWhiteSpace($CompletionReceiptSha256)) {
            $null
        } else { $CompletionReceiptSha256 }
        failureCode = $FailureCode
        updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    Write-AtomicJson $statePath $state
}

$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$ConfigurationPath = [IO.Path]::GetFullPath($ConfigurationPath)
$ExecutionRoot = [IO.Path]::GetFullPath($ExecutionRoot)
if ($ValidateOnly) {
    Assert-PhaseD (-not $ExecutionRoot.StartsWith(
        (Join-Path $RepositoryRoot 'artifacts\automation\phase-d-executions'),
        [StringComparison]::OrdinalIgnoreCase)) 'phase_d_validation_root_must_be_separate'
}
$RuntimeCandidatePath = [IO.Path]::GetFullPath($RuntimeCandidatePath)
$LobbyProjectionPath = [IO.Path]::GetFullPath($LobbyProjectionPath)
$launchRoot = Join-Path $ExecutionRoot $LaunchContextUid
$statePath = Join-Path $launchRoot 'execution-state.json'
$contextPath = Join-Path $launchRoot 'launch-context.json'
$runtimeRoot = Join-Path $launchRoot 'runtime'
$evidenceRoot = Join-Path $launchRoot 'evidence'
$toolsRoot = Join-Path $launchRoot 'tools'
$parentRoot = 'C:\NLL\Runtime\EpinelPS-SoloRaidRankingPrefix-v9'
$rankingPrefixDeploymentReceipt =
    'C:\NLL\E\P3SRRP9D\deployment.receipt.json'
$rankingPrefixSourceManifest = 'C:\NLL\E\P3SRRP9D\source.manifest.tsv'
$materializer = Join-Path $RepositoryRoot `
    'artifacts\phase-d\runtime-materializer\NikkeLocalLab.PhaseD.RuntimeMaterializer.exe'
$weaknessVariantArtifactRoot = Join-Path $RepositoryRoot `
    'artifacts\phase-d\weakness-variant-server'
$weaknessVariantServerDll = Join-Path $weaknessVariantArtifactRoot 'EpinelPS.dll'
$weaknessVariantSourceManifest = Join-Path $weaknessVariantArtifactRoot `
    'source.manifest.tsv'
$bossRuntimeVariantRegistry = Join-Path $RepositoryRoot `
    'config\boss-runtime-variants\registry.json'
$watcher = Join-Path $RepositoryRoot 'scripts\watch-nll-phase-d-execution.ps1'
$resourcePreflightHelper = Join-Path $RepositoryRoot 'scripts\Nll.ResourcePreflight.ps1'
$resourcePreflightTool = Join-Path $RepositoryRoot `
    'artifacts\phase-d\resource-preflight\ResourceCatalogPreflight.exe'
$clientExecutable = 'C:\NLL\Clients\NIKKE-150.6.9-Physical\NIKKE\game\nikke.exe'
$clientBuildCode = 'build_150.6.9'
$runtimeBaseRoot = $parentRoot
$runtimeBundle = $null
$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$cleanHostsReference = `
    'C:\NLL\Backups\Phase3B2\Physical-P0-v1\hosts.original.bin'
$phase3B2BaseHostsReference = `
    'C:\NLL\Backups\Phase3B2\PhysicalP2-v2\hosts.before.bin'
$expectedParentDbSha256 = 'dee9c6aa5421287ca030e325b81a90a302a5d9e113d57c3065e5d36f6e7c4019'
$expectedServerDllSha256 = '98d4f4d12ff83c694ee052f9eca3c63ae782f2c4747a80993ee257384eef2498'
$expectedServerDllByteLength = 15398400L
$expectedWeaknessVariantServerDllSha256 =
    'a364b9211efc1b60d23efc50075e101b0212f09b96a311b167743d01583939e6'
$expectedWeaknessVariantServerDllByteLength = 15406592L
$expectedWeaknessVariantSourceManifestSha256 =
    '0ebd23987384fde1537b88efcfdd5b19fc18176f185d9cd1e9fa743914d24bbf'
$expectedWeaknessVariantSourceManifestByteLength = 3270L
$rankingWirePrefix = 1130781186L
$expectedRankingPrefixSourceManifestSha256 =
    'be2b0107ecec425d3c6dc4538d33306f81c55e0142f312fa3da9bd10ed29a1d7'
$expectedRankingPrefixSourceManifestByteLength = 2559L
$expectedRankingPrefixDeploymentReceiptSha256 =
    'd360b29ca19fa36c6c1504d7b29a30d541621bf5855b45810f87e43d9e63a269'
$expectedRankingPrefixDeploymentReceiptByteLength = 3501L
$expectedCleanHostsSha256 = '565955a47a890e8090a2987a234ba05e2624c84a587ba86e8648f912678984b9'
$expectedPostDockerUninstallCleanHostsSha256 =
    'ce44d858ef28f09073edcb5bb805fc1800663e94eb540518a66680cb0d08fdda'
$expectedPhase3B2BaseHostsSha256 = 'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0'
$createdAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
$controlCenterPgCtl = [Environment]::GetEnvironmentVariable('NLL_CONTROL_CENTER_PG_CTL')
$controlCenterPgData = [Environment]::GetEnvironmentVariable('NLL_CONTROL_CENTER_PG_DATA')
$controlCenterPgLog = [Environment]::GetEnvironmentVariable('NLL_CONTROL_CENTER_PG_LOG')
$runtimeLifecycleEntered = $false
$runtimeProcessIdentities = $null
$coordinatorStage = 'preparation'
$controlCenterHostsPrepared = $false
$watcherOwnershipTransferred = $false
$watcherSpawned = $false
$executionJob = $null
$jobAttempted = $false
$controlCenterHostsOriginalSha256 = $null
$controlCenterHostsBackupPath = Join-Path $launchRoot 'control-center-hosts.before.bin'

$candidate = Get-Content -LiteralPath $RuntimeCandidatePath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$lobby = Get-Content -LiteralPath $LobbyProjectionPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
New-Item -ItemType Directory -Path $launchRoot -Force | Out-Null
Set-ExecutionState -StatusCode 'draft'

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    Assert-PhaseD `
        ($ValidateOnly -or $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) `
        'phase_d_requires_administrator'
    Assert-PhaseD `
        ($env:SystemDrive -ceq 'C:' -and $env:USERNAME -ceq 'nlloperator') `
        'phase_d_wrong_operator_or_boot_boundary'
    Assert-PhaseD `
        ($candidate.contractId -ceq 'nll/runtime-projection-candidate/v1' -and
         [string]$candidate.accountUid -ceq [string]$lobby.accountUid -and
         [string]$candidate.validationStatusCode -ceq 'ready' -and
         @($candidate.validationReasonCodes).Count -eq 0) `
        'phase_d_candidate_not_ready'
    $preparation = Get-PhaseDPreparation -RepositoryRoot $RepositoryRoot `
        -SeasonNumber $SeasonNumber -WeaknessCode $WeaknessCode -RuntimeSelectionPath $RuntimeSelectionPath
    Assert-PhaseD ($preparation.statusCode -ceq 'ready') ([string]$preparation.failureCode)
    Assert-PhaseDDatabaseBinding $preparation
    Assert-PhaseD ([string]::IsNullOrEmpty($ExpectedPreparationBindingSha256) -or
        $ExpectedPreparationBindingSha256 -ceq $preparation.bindingSha256) 'phase_d_preparation_changed'
    $bossRuntimeVariantRegistrySha256 = $preparation.plan.registry.sha256
    $bossRuntimeVariantRegistry = $preparation.plan.registry.path
    $bossRuntimeVariantProfile = $preparation.plan.profile.path
    $bossRuntimeVariantProfileSha256 = $preparation.plan.profile.sha256
    $bossRuntimeVariantProfileByteLength = $preparation.plan.profile.length
    $bossVariantProfile = $preparation.plan.profile.value
    $sourceBossElementCode = [string]$preparation.plan.affinity.sourceBossElementCode
    $sourceBossWeaknessCode = [string]$preparation.plan.affinity.sourceWeaknessCode
    $targetBossElementCode = $preparation.plan.targetElementCode
    $targetShieldFxVariants = @($preparation.plan.shieldFxVariants)
    # The old seed/account/persistence pipeline remains authoritative. A selected
    # version bundle replaces only the runtime/data/bootstrap inputs, never the DB.
    $runtimeBundle = $preparation.plan.bundle
    if ($null -ne $runtimeBundle) {
        $runtimeBaseRoot = [string]$runtimeBundle.serverRoot
        $clientExecutable = [string]$runtimeBundle.client.path
        $clientBuildCode = [string]$runtimeBundle.clientBuildCode
        $materializer = Join-Path $runtimeBundle.materializerRoot 'NikkeLocalLab.PhaseD.RuntimeMaterializer.exe'
        $weaknessVariantServerDll = [string]$runtimeBundle.serverDll.path
        $expectedWeaknessVariantServerDllSha256 = [string]$runtimeBundle.serverDll.sha256
        $expectedWeaknessVariantServerDllByteLength = [long]$runtimeBundle.serverDll.length
        $weaknessVariantSourceManifest = [string]$runtimeBundle.serverSourceManifest.path
        $expectedWeaknessVariantSourceManifestSha256 = [string]$runtimeBundle.serverSourceManifest.sha256
        $expectedWeaknessVariantSourceManifestByteLength = [long]$runtimeBundle.serverSourceManifest.length
    }

    foreach ($path in @(
            $ConfigurationPath, $RuntimeCandidatePath, $LobbyProjectionPath,
            $materializer, $watcher,
            $rankingPrefixDeploymentReceipt, $rankingPrefixSourceManifest,
            $weaknessVariantServerDll, $weaknessVariantSourceManifest,
            $bossRuntimeVariantRegistry, $bossRuntimeVariantProfile,
            $clientExecutable,
            $hostsPath, $cleanHostsReference, $phase3B2BaseHostsReference,
            (Join-Path $parentRoot 'db.json'),
            (Join-Path $parentRoot 'EpinelPS.exe'),
            (Join-Path $parentRoot 'EpinelPS.dll'))) {
        Assert-PhaseD (Test-Path -LiteralPath $path -PathType Leaf) `
            'phase_d_required_input_missing'
    }
    Assert-PhaseD `
        ((Get-Sha256Lower (Join-Path $parentRoot 'db.json')) -ceq $expectedParentDbSha256 -and
         (Get-Item -LiteralPath (Join-Path $parentRoot 'EpinelPS.dll')).Length -eq `
            $expectedServerDllByteLength -and
         (Get-Sha256Lower (Join-Path $parentRoot 'EpinelPS.dll')) -ceq `
            $expectedServerDllSha256) `
        'phase_d_parent_runtime_drifted'
    Assert-PhaseD `
        ((Get-Item -LiteralPath $rankingPrefixDeploymentReceipt).Length -eq `
            $expectedRankingPrefixDeploymentReceiptByteLength -and
         (Get-Sha256Lower $rankingPrefixDeploymentReceipt) -ceq `
            $expectedRankingPrefixDeploymentReceiptSha256 -and
         (Get-Item -LiteralPath $rankingPrefixSourceManifest).Length -eq `
            $expectedRankingPrefixSourceManifestByteLength -and
         (Get-Sha256Lower $rankingPrefixSourceManifest) -ceq `
            $expectedRankingPrefixSourceManifestSha256) `
        'phase_d_ranking_prefix_deployment_drifted'
    Assert-PhaseD `
        ((Get-Item -LiteralPath $weaknessVariantServerDll).Length -eq `
            $expectedWeaknessVariantServerDllByteLength -and
         (Get-Sha256Lower $weaknessVariantServerDll) -ceq `
            $expectedWeaknessVariantServerDllSha256 -and
         (Get-Item -LiteralPath $weaknessVariantSourceManifest).Length -eq `
            $expectedWeaknessVariantSourceManifestByteLength -and
         (Get-Sha256Lower $weaknessVariantSourceManifest) -ceq `
            $expectedWeaknessVariantSourceManifestSha256) `
        'phase_d_weakness_variant_server_artifact_drifted'
    $rankingPrefixDeployment = Get-Content `
        -LiteralPath $rankingPrefixDeploymentReceipt -Raw -Encoding UTF8 |
        ConvertFrom-Json
    Assert-PhaseD `
        ($rankingPrefixDeployment.contractId -ceq `
            'nll/phase3b2-epinel-solo-raid-ranking-prefix-deployment/v9' -and
         $rankingPrefixDeployment.appliedServerDllSha256 -ceq `
            $expectedServerDllSha256 -and
         [long]$rankingPrefixDeployment.rankingWirePrefix -eq $rankingWirePrefix -and
         $rankingPrefixDeployment.responseSemanticsCode -ceq `
            'ranking_wire_domain_encoded_common_prefix' -and
         $rankingPrefixDeployment.persistedChallengeDamageRemainsRaw -and
         $rankingPrefixDeployment.rankingWireFieldsAreCumulative -and
         $rankingPrefixDeployment.completionVerifierSeparatesRawAndWireDomains -and
         -not $rankingPrefixDeployment.serverExecutionStarted -and
         -not $rankingPrefixDeployment.clientExecutionStarted) `
        'phase_d_ranking_prefix_deployment_contract_invalid'
    Assert-PhaseD `
        ((Get-Sha256Lower $cleanHostsReference) -ceq $expectedCleanHostsSha256 -and
         (Get-Sha256Lower $phase3B2BaseHostsReference) -ceq `
            $expectedPhase3B2BaseHostsSha256) `
        'phase_d_hosts_reference_drifted'
    $controlCenterHostsOriginalSha256 = Get-Sha256Lower $hostsPath
    Assert-PhaseD `
        ($controlCenterHostsOriginalSha256 -in @(
            $expectedCleanHostsSha256,
            $expectedPostDockerUninstallCleanHostsSha256)) `
        'phase_d_hosts_baseline_invalid'
    Assert-PhaseD `
        (@(Get-Process -Name EpinelPS, nikke, nikke_launcher,
            NikkeLocalLab.Phase3B2.PhysicalBootstrap -ErrorAction SilentlyContinue).Count -eq 0) `
        'phase_d_runtime_not_cold'
    Assert-PhaseD `
        (-not (Test-Path -LiteralPath $runtimeRoot) -and
         -not (Test-Path -LiteralPath $evidenceRoot) -and
         -not (Test-Path -LiteralPath $toolsRoot)) `
        'phase_d_launch_root_not_clean'

    if (-not $ValidateOnly -and $null -ne $runtimeBundle) {
        $activeBundle = Read-PdRuntimeBundle $RuntimeSelectionPath
        Assert-PhaseD ($activeBundle.manifestPath -ceq $runtimeBundle.manifestPath -and
            (Get-PdBundleHash $activeBundle.manifestPath) -ceq $preparation.plan.bundleSha256 -and
            (Get-PdBundleHash $RuntimeSelectionPath) -ceq $preparation.plan.selectionSha256) 'phase_d_preparation_changed'
    }

    # Mandatory local input check before copying a runtime, stopping PostgreSQL,
    # changing hosts, or starting either EpinelPS or the native client.
    Assert-PhaseD (Test-Path -LiteralPath $resourcePreflightHelper -PathType Leaf) `
        'phase_d_resource_preflight_helper_missing'
    . $resourcePreflightHelper
    $resourceSelection = Get-NllVoiceResourceSelection
    if ($null -eq $runtimeBundle) {
      $resourceCatalogReceipt = Invoke-NllResourceCatalogPreflight `
        -ToolPath $resourcePreflightTool -ServerRoot $parentRoot `
        -ClientExecutable $clientExecutable -Selection $resourceSelection
      $resourcePreflightToolSha256 = Get-NllResourcePreflightToolSetSha256 $resourcePreflightTool
    }
    else {
      # 151 native initialization was verified with installed chunk resources.
      # Do not run the 150 five-catalog/HTTP diagnostic contract against it.
      $resourceCatalogReceipt = [ordered]@{
        contractId = 'nll/phase-d-installed-runtime-inputs/v1'
        clientBuildCode = $clientBuildCode
        referenceAssessmentUid = $runtimeBundle.referenceAssessmentUid
        localFilePinsVerified = $true
        voiceSelection = $resourceSelection
        voicePreferencesChanged = $false
        httpDiagnosticLayer = $false
        nativeGameplayValidated = $false
      }
      $resourcePreflightToolSha256 = $null
    }
    $resourceCatalogReceiptPath = Join-Path $launchRoot 'resource-catalog-preflight.receipt.json'
    Write-AtomicJson $resourceCatalogReceiptPath $resourceCatalogReceipt -Depth 8
    $resourceCatalogReceiptSha256 = Get-Sha256Lower $resourceCatalogReceiptPath
    $resourcePreflightHelperSha256 = Get-Sha256Lower $resourcePreflightHelper

    New-Item -ItemType Directory -Path $runtimeRoot, $evidenceRoot, $toolsRoot -Force |
        Out-Null
    $copyLog = Join-Path $launchRoot 'runtime-copy.log'
    $robocopy = Join-Path $env:SystemRoot 'System32\robocopy.exe'
    & $robocopy $runtimeBaseRoot $runtimeRoot /E /XJ /R:0 /W:0 /COPY:DAT `
        /XD cache logs /XF db.json epinelps.db epinelps.db-shm epinelps.db-wal `
        /NFL /NDL /NJH /NJS /NP /LOG:$copyLog | Out-Null
    Assert-PhaseD ($LASTEXITCODE -lt 8) 'phase_d_runtime_copy_failed'
    $parentCache = Get-Item -LiteralPath (Join-Path $runtimeBaseRoot 'cache') -Force
    $parentCacheTargets = @($parentCache.Target)
    if ($null -ne $runtimeBundle) { $parentCacheTargets = @($parentCache.FullName) }
    else { Assert-PhaseD `
        ($parentCache.LinkType -ceq 'Junction' -and $parentCacheTargets.Count -eq 1) `
        'phase_d_parent_cache_link_invalid' }
    New-Item -ItemType Junction -Path (Join-Path $runtimeRoot 'cache') `
        -Target ([string]$parentCacheTargets[0]) | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $runtimeRoot 'logs') -Force |
        Out-Null
    if ($null -eq $runtimeBundle) { Assert-PhaseD `
        ((Get-Item -LiteralPath (Join-Path $runtimeRoot 'EpinelPS.dll')).Length -eq `
            $expectedServerDllByteLength -and
         (Get-Sha256Lower (Join-Path $runtimeRoot 'EpinelPS.dll')) -ceq `
            $expectedServerDllSha256) `
        'phase_d_ranking_prefix_server_copy_failed' }
    Copy-Item -LiteralPath $weaknessVariantServerDll `
        -Destination (Join-Path $runtimeRoot 'EpinelPS.dll') -Force
    Assert-PhaseD `
        ((Get-Item -LiteralPath (Join-Path $runtimeRoot 'EpinelPS.dll')).Length -eq `
            $expectedWeaknessVariantServerDllByteLength -and
         (Get-Sha256Lower (Join-Path $runtimeRoot 'EpinelPS.dll')) -ceq `
            $expectedWeaknessVariantServerDllSha256) `
        'phase_d_weakness_variant_server_overlay_failed'

    foreach ($leaf in @(
            'NikkeLocalLab.PhaseD.RuntimeMaterializer.exe',
            'NikkeLocalLab.PhaseD.RuntimeMaterializer.dll',
            'NikkeLocalLab.PhaseD.RuntimeMaterializer.deps.json',
            'NikkeLocalLab.PhaseD.RuntimeMaterializer.runtimeconfig.json')) {
        $source = Join-Path (Split-Path -Parent $materializer) $leaf
        Assert-PhaseD (Test-Path -LiteralPath $source -PathType Leaf) `
            'phase_d_materializer_member_missing'
        Copy-Item -LiteralPath $source -Destination $runtimeRoot
    }
    $runtimeMaterializer = Join-Path $runtimeRoot `
        'NikkeLocalLab.PhaseD.RuntimeMaterializer.exe'

    $configuration = Get-Content -LiteralPath $ConfigurationPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    $connectionEnvironmentVariable = [string]$configuration.database.connectionStringEnvironmentVariable
    $secretEnvironmentVariable = [string]$configuration.identity.hmacSecretEnvironmentVariable
    Assert-PhaseD `
        ($connectionEnvironmentVariable -cmatch '^[A-Z][A-Z0-9_]{2,63}$' -and
         $secretEnvironmentVariable -cmatch '^[A-Z][A-Z0-9_]{2,63}$' -and
         -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable(
            $connectionEnvironmentVariable)) -and
         -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable(
            $secretEnvironmentVariable))) `
        'phase_d_runtime_environment_missing'

    $materializationReceiptPath = Join-Path $launchRoot 'materialization.receipt.json'
    $runtimeDbPath = Join-Path $runtimeRoot 'db.json'
    $clientExecutableSha256 = Get-Sha256Lower $clientExecutable
    $runtimeGameConfiguration = Get-Content `
        -LiteralPath (Join-Path $runtimeRoot 'gameconfig.json') -Raw -Encoding UTF8 |
        ConvertFrom-Json
    $staticDataUri = [Uri]([string]$runtimeGameConfiguration.StaticDataMpk.Url)
    Assert-PhaseD `
        ($staticDataUri.IsAbsoluteUri -and
         $staticDataUri.Scheme -ceq 'https' -and
         $staticDataUri.Host -ceq 'cloud.nikke-kr.com' -and
         -not [string]::IsNullOrWhiteSpace($staticDataUri.AbsolutePath)) `
        'phase_d_staticdata_source_uri_invalid'
    $runtimeCacheRoot = [IO.Path]::GetFullPath(
        (Join-Path $runtimeRoot 'cache')).TrimEnd('\') + '\'
    $staticDataRelativePath = [Uri]::UnescapeDataString(
        $staticDataUri.AbsolutePath.TrimStart('/')).Replace('/', '\')
    $sourceStaticDataPack = [IO.Path]::GetFullPath(
        (Join-Path $runtimeCacheRoot $staticDataRelativePath))
    Assert-PhaseD `
        ($sourceStaticDataPack.StartsWith(
            $runtimeCacheRoot, [StringComparison]::OrdinalIgnoreCase) -and
         (Test-Path -LiteralPath $sourceStaticDataPack -PathType Leaf)) `
        'phase_d_staticdata_source_pack_invalid'
    $behaviorAssetBundleSha256 = $null
    $behaviorAssetBundleByteLength = 0L
    $behaviorAssetMatchCount = 0
    $selectedShieldFxMappingSetSha256 = $null
    $selectedShieldFxAssetBundles = @()
    $shieldFxAssetMatchCount = 0
    if ([int]$bossVariantProfile.schemaVersion -eq 2) {
        Assert-PhaseD `
            ([string]$bossVariantProfile.behaviorAssembly.modeCode -ceq `
                'preserve_exact_external_behavior_tree' -and
             [string]$bossVariantProfile.behaviorAssembly.assetClosureStatusCode -ceq `
                'resolved' -and
             [int]$bossVariantProfile.behaviorAssembly.rootReferenceCount -gt 0 -and
             [int]$bossVariantProfile.behaviorAssembly.graphMatchCount -eq `
                [int]$bossVariantProfile.behaviorAssembly.rootReferenceCount) `
            'phase_d_boss_behavior_contract_invalid'
        $behaviorAssetBundleSha256 =
            [string]$bossVariantProfile.behaviorAssembly.bundleSha256
        $behaviorAssetBundleByteLength =
            [long]$bossVariantProfile.behaviorAssembly.bundleByteLength
        $behaviorAssetMatchCount = Assert-PhaseDCacheArtifactIdentity `
            -CacheRoot $runtimeCacheRoot `
            -ByteLength $behaviorAssetBundleByteLength `
            -Sha256 $behaviorAssetBundleSha256 `
            -CommonDelivery $preparation.plan.commonDelivery -AssetRole behavior `
            -ProfileSha256 $bossRuntimeVariantProfileSha256 `
            -FailureCode 'phase_d_boss_behavior_asset_closure_invalid'
    }
    if ($targetShieldFxVariants.Count -eq 1) {
        $selectedShieldFxMappingSetSha256 =
            [string]$targetShieldFxVariants[0].mappingSetSha256
        $selectedShieldFxAssetBundles = @(
            $targetShieldFxVariants[0].mappings |
                ForEach-Object { $_.assetBundles } |
                Group-Object { ([string]$_.byteLength) + ':' + [string]$_.sha256 } |
                ForEach-Object { $_.Group[0] })
        Assert-PhaseD `
            ($selectedShieldFxMappingSetSha256 -cmatch '^[0-9a-f]{64}$' -and
             $selectedShieldFxAssetBundles.Count -gt 0) `
            'phase_d_boss_shield_fx_asset_contract_invalid'
        foreach ($bundle in $selectedShieldFxAssetBundles) {
            $shieldFxAssetMatchCount += Assert-PhaseDCacheArtifactIdentity `
                -CacheRoot $runtimeCacheRoot `
                -ByteLength ([long]$bundle.byteLength) `
                -Sha256 ([string]$bundle.sha256) `
                -CommonDelivery $preparation.plan.commonDelivery `
                -ProfileSha256 $bossRuntimeVariantProfileSha256 `
                -FailureCode 'phase_d_boss_shield_fx_asset_closure_invalid'
        }
    }
    $variantStaticDataRoot = Join-Path $runtimeRoot 'static-data-variant'
    New-Item -ItemType Directory -Path $variantStaticDataRoot -Force | Out-Null
    $variantStaticDataPack = Join-Path $variantStaticDataRoot 'StaticData.pack'
    $variantStaticDataReceiptPath = Join-Path $launchRoot `
        'static-data-variant.receipt.json'
    $materializerInvocation = & {
      # Windows PowerShell 5.1 turns redirected stderr into ErrorRecords.
      # Capture all diagnostics before classifying the exit code; keep these
      # preferences local so coordinator/rollback errors still stop normally.
      $ErrorActionPreference = 'Continue'
      $PSNativeCommandUseErrorActionPreference = $false
      $global:LASTEXITCODE = $null
      $output = @(& $runtimeMaterializer `
        --candidate $RuntimeCandidatePath `
        --lobby $LobbyProjectionPath `
        --source-db (Join-Path $parentRoot 'db.json') `
        --output-db $runtimeDbPath `
        --receipt $materializationReceiptPath `
        --connection-string-env $connectionEnvironmentVariable `
        --identity-secret-env $secretEnvironmentVariable `
        --season-number ([string]$SeasonNumber) `
        --boss-variant-profile $bossRuntimeVariantProfile `
        --weakness-code $WeaknessCode `
        --source-static-pack $sourceStaticDataPack `
        --variant-static-pack $variantStaticDataPack `
        --variant-static-data-receipt $variantStaticDataReceiptPath `
        --client-build-code $clientBuildCode `
        --client-executable-sha256 $clientExecutableSha256 2>&1)
      if ($null -eq $global:LASTEXITCODE) { throw 'phase_d_materializer_start_failed' }
      [pscustomobject]@{ Output = $output; ExitCode = $global:LASTEXITCODE }
    }
    $materializerOutput = @($materializerInvocation.Output)
    $materializerExitCode = $materializerInvocation.ExitCode
    if ($materializerExitCode -ne 0) {
        $safePreparationDiagnostics = @($materializerOutput | ForEach-Object { [string]$_ } |
            Where-Object { $_ -cmatch '^\{"preparationExceptionType":' })
        if ($safePreparationDiagnostics.Count -gt 0) {
            [IO.File]::WriteAllLines((Join-Path $launchRoot 'materializer-failure.types.jsonl'),
                [string[]]$safePreparationDiagnostics, [Text.UTF8Encoding]::new($false))
        }
        $materializerFailureCode = @(
            $materializerOutput |
                ForEach-Object { [string]$_ } |
                Where-Object { $_ -cmatch '^phase_d_[a-z0-9._-]{3,128}$' }
        ) | Select-Object -Last 1
        if ([string]::IsNullOrWhiteSpace([string]$materializerFailureCode)) {
            $materializerFailureCode = 'phase_d_materialization_failed'
        }
        throw [string]$materializerFailureCode
    }
    $materialization = Get-Content -LiteralPath $materializationReceiptPath `
        -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-PhaseD `
        ($materialization.contractId -ceq 'nll/phase-d-runtime-materialization/v1' -and
         [string]$materialization.accountUid -ceq [string]$candidate.accountUid -and
         [string]$materialization.accountRevisionSetSha256 -ceq `
            [string]$candidate.baseRevisions.revisionSetSha256 -and
         [int]$materialization.raidSeasonNumber -eq $SeasonNumber -and
         [string]$materialization.raidSnapshotUid -cmatch `
            '^[0-9a-f-]{36}$' -and
         [string]$materialization.raidSnapshotSha256 -cmatch `
            '^[0-9a-f]{64}$' -and
         [string]$materialization.raidWeaknessCode -ceq $WeaknessCode -and
         [string]$materialization.sourceBossElementCode -ceq `
            $sourceBossElementCode -and
         [string]$materialization.sourceBossWeaknessCode -ceq `
            $sourceBossWeaknessCode -and
         [string]$materialization.targetBossElementCode -ceq `
            $targetBossElementCode -and
         [string]$materialization.bossVariantProfileCode -ceq `
            [string]$bossVariantProfile.profileCode -and
         [string]$materialization.bossVariantProfileSha256 -ceq `
            $bossRuntimeVariantProfileSha256) `
        'phase_d_materialization_receipt_invalid'
    $staticDataVariant = Get-Content -LiteralPath $variantStaticDataReceiptPath `
        -Raw -Encoding UTF8 | ConvertFrom-Json
    $expectedAffinityVariantRequired = $WeaknessCode -cne $sourceBossWeaknessCode
    $staticDataVariantRequired = [bool]$staticDataVariant.variantRequired
    Assert-PhaseD `
        ($staticDataVariant.contractId -ceq `
            'nll/boss-affinity-static-data-variant/v1' -and
         [string]$staticDataVariant.variantProfileCode -ceq `
            [string]$bossVariantProfile.profileCode -and
         [string]$staticDataVariant.variantProfileSha256 -ceq `
            $bossRuntimeVariantProfileSha256 -and
         [int]$staticDataVariant.seasonNumber -eq $SeasonNumber -and
         [string]$staticDataVariant.weaknessCode -ceq $WeaknessCode -and
         [string]$staticDataVariant.sourceBossWeaknessCode -ceq `
            $sourceBossWeaknessCode -and
         [string]$staticDataVariant.sourceBossElementCode -ceq `
            $sourceBossElementCode -and
         [string]$staticDataVariant.targetBossElementCode -ceq `
            $targetBossElementCode -and
         [string]$staticDataVariant.elementShieldModeCode -ceq `
            [string]$bossVariantProfile.elementShield.modeCode -and
         [bool]$staticDataVariant.fxVariantRequired -eq `
            [bool]$bossVariantProfile.elementShield.fxVariantRequired -and
         [string]$staticDataVariant.fxVariantStatusCode -ceq `
            [string]$bossVariantProfile.elementShield.fxVariantStatusCode -and
         $staticDataVariantRequired -eq $expectedAffinityVariantRequired -and
         [bool]$materialization.staticDataVariantRequired -eq `
            $staticDataVariantRequired -and
         -not [bool]$staticDataVariant.serverStaticDataModified -and
         -not [bool]$staticDataVariant.officialInstallModified -and
         -not [bool]$staticDataVariant.rawSourceIdentifierPersisted) `
        'phase_d_staticdata_variant_receipt_invalid'
    if ([string]$bossVariantProfile.elementShield.modeCode -ceq `
            'dynamic_affinity_linked') {
        $expectedMinimumModifiedFunctionCount = if ($staticDataVariantRequired) {
            1
        }
        else {
            0
        }
        $receiptShieldFxAssetBundles = @($staticDataVariant.shieldFxAssetBundles)
        $shieldFxReceiptAssetSetValid =
            $receiptShieldFxAssetBundles.Count -eq `
                $selectedShieldFxAssetBundles.Count
        foreach ($expectedBundle in $selectedShieldFxAssetBundles) {
            $matchingReceiptBundles = @($receiptShieldFxAssetBundles | Where-Object {
                [string]$_.sha256 -ceq [string]$expectedBundle.sha256 -and
                [long]$_.byteLength -eq [long]$expectedBundle.byteLength
            })
            $shieldFxReceiptAssetSetValid =
                $shieldFxReceiptAssetSetValid -and
                $matchingReceiptBundles.Count -eq 1
        }
        Assert-PhaseD `
            ($targetShieldFxVariants.Count -eq 1 -and
             [string]$staticDataVariant.shieldFxMappingSetSha256 -ceq `
                $selectedShieldFxMappingSetSha256 -and
             $shieldFxReceiptAssetSetValid -and
             [int]$staticDataVariant.modifiedFunctionRecordCount -ge `
                $expectedMinimumModifiedFunctionCount -and
             [int]$staticDataVariant.modifiedFunctionRecordCount -le `
                [int]$bossVariantProfile.elementShield.functionRecordCount -and
             [bool]$staticDataVariant.shieldFxVariantApplied -eq `
                $staticDataVariantRequired) `
            'phase_d_staticdata_variant_shield_receipt_invalid'
    }
    $variantStaticDataSha256 = $null
    if ($staticDataVariantRequired) {
        $variantStaticDataSha256 = Get-Sha256Lower $variantStaticDataPack
        Assert-PhaseD `
            ((Test-Path -LiteralPath $variantStaticDataPack -PathType Leaf) -and
             $variantStaticDataSha256 -ceq `
                [string]$staticDataVariant.variantStaticDataSha256 -and
             $variantStaticDataSha256 -ceq `
                [string]$materialization.staticDataVariantSha256 -and
             [string]$staticDataVariant.signatureStatusCode -ceq `
                'original_signature_not_valid_for_derived_payload' -and
             [string]$staticDataVariant.clientAcceptanceStatusCode -ceq `
                'pending_original_client_runtime_observation') `
            'phase_d_staticdata_variant_output_invalid'
    }
    else {
        Assert-PhaseD `
            (-not (Test-Path -LiteralPath $variantStaticDataPack) -and
             $null -eq $staticDataVariant.variantStaticDataSha256 -and
             $null -eq $materialization.staticDataVariantSha256) `
            'phase_d_staticdata_baseline_output_invalid'
    }
    $runtimeDbSha256 = Get-Sha256Lower $runtimeDbPath

    $sourceManifestPath = Join-Path $launchRoot 'source.manifest.tsv'
    $sealedRankingPrefixSourceManifestPath = Join-Path $launchRoot `
        'ranking-prefix-server-source.manifest.tsv'
    Copy-Item -LiteralPath $rankingPrefixSourceManifest `
        -Destination $sealedRankingPrefixSourceManifestPath
    $sealedWeaknessVariantSourceManifestPath = Join-Path $launchRoot `
        'weakness-variant-server-source.manifest.tsv'
    Copy-Item -LiteralPath $weaknessVariantSourceManifest `
        -Destination $sealedWeaknessVariantSourceManifestPath
    Assert-PhaseD `
        ((Get-Sha256Lower $sealedRankingPrefixSourceManifestPath) -ceq `
            $expectedRankingPrefixSourceManifestSha256) `
        'phase_d_ranking_prefix_source_manifest_copy_failed'
    Assert-PhaseD `
        ((Get-Sha256Lower $sealedWeaknessVariantSourceManifestPath) -ceq `
            $expectedWeaknessVariantSourceManifestSha256) `
        'phase_d_weakness_variant_source_manifest_copy_failed'
    $sourceLines = @(
        "role_code`tbyte_length`tsha256"
        "candidate`t$((Get-Item -LiteralPath $RuntimeCandidatePath).Length)`t$(Get-Sha256Lower $RuntimeCandidatePath)"
        "lobby`t$((Get-Item -LiteralPath $LobbyProjectionPath).Length)`t$(Get-Sha256Lower $LobbyProjectionPath)"
        "materializer`t$((Get-Item -LiteralPath $materializer).Length)`t$(Get-Sha256Lower $materializer)"
        "parent_db`t$((Get-Item -LiteralPath (Join-Path $parentRoot 'db.json')).Length)`t$expectedParentDbSha256"
        "parent_server_dll`t$expectedServerDllByteLength`t$expectedServerDllSha256"
        "server_dll`t$expectedWeaknessVariantServerDllByteLength`t$expectedWeaknessVariantServerDllSha256"
        "parent_server_source_manifest`t$expectedRankingPrefixSourceManifestByteLength`t$expectedRankingPrefixSourceManifestSha256"
        "server_source_manifest`t$expectedWeaknessVariantSourceManifestByteLength`t$expectedWeaknessVariantSourceManifestSha256"
        "server_deployment_receipt`t$expectedRankingPrefixDeploymentReceiptByteLength`t$expectedRankingPrefixDeploymentReceiptSha256"
        "boss_runtime_variant_registry`t$((Get-Item -LiteralPath $bossRuntimeVariantRegistry).Length)`t$(Get-Sha256Lower $bossRuntimeVariantRegistry)"
        "boss_runtime_variant_profile`t$bossRuntimeVariantProfileByteLength`t$bossRuntimeVariantProfileSha256"
        "static_data_source`t$((Get-Item -LiteralPath $sourceStaticDataPack).Length)`t$(Get-Sha256Lower $sourceStaticDataPack)"
        "static_data_variant_receipt`t$((Get-Item -LiteralPath $variantStaticDataReceiptPath).Length)`t$(Get-Sha256Lower $variantStaticDataReceiptPath)"
        "hosts_original`t$((Get-Item -LiteralPath $hostsPath).Length)`t$controlCenterHostsOriginalSha256"
        "hosts_phase3b2_base`t$((Get-Item -LiteralPath $phase3B2BaseHostsReference).Length)`t$expectedPhase3B2BaseHostsSha256"
    )
    if ($staticDataVariantRequired) {
        $sourceLines += "static_data_variant`t$((Get-Item -LiteralPath $variantStaticDataPack).Length)`t$variantStaticDataSha256"
    }
    if (-not [string]::IsNullOrWhiteSpace($behaviorAssetBundleSha256)) {
        $sourceLines += "boss_behavior_asset`t$behaviorAssetBundleByteLength`t$behaviorAssetBundleSha256"
    }
    for ($index = 0; $index -lt $selectedShieldFxAssetBundles.Count; $index++) {
        $bundle = $selectedShieldFxAssetBundles[$index]
        $sourceLines += "boss_shield_fx_asset_$($index.ToString('D2'))`t$([long]$bundle.byteLength)`t$([string]$bundle.sha256)"
    }
    [IO.File]::WriteAllText(
        $sourceManifestPath,
        (($sourceLines -join "`n") + "`n"),
        [Text.UTF8Encoding]::new($false))
    $sourceManifestSha256 = Get-Sha256Lower $sourceManifestPath

    $soloRaidStateRoot = 'C:\NLL\ControlCenter\state\phase-d-solo-raid'
    $soloRaidLaunchStateRoot = Join-Path $soloRaidStateRoot $LaunchContextUid
    Assert-PhaseD `
        (([IO.Path]::GetFullPath($soloRaidLaunchStateRoot)).StartsWith(
            ([IO.Path]::GetFullPath($soloRaidStateRoot).TrimEnd('\') + '\'),
            [StringComparison]::OrdinalIgnoreCase)) `
        'phase_d_raid_state_staging_path_invalid'
    New-Item -ItemType Directory -Path $soloRaidLaunchStateRoot -Force |
        Out-Null
    $soloRaidPendingPath = Join-Path $soloRaidLaunchStateRoot `
        'payload.pending.json'
    $soloRaidCaptureReceiptPath = Join-Path $soloRaidLaunchStateRoot `
        'capture.receipt.json'
    $soloRaidPersistenceReceiptPath = Join-Path $soloRaidLaunchStateRoot `
        'persistence.receipt.json'
    Assert-PhaseD `
        (-not (Test-Path -LiteralPath $soloRaidPendingPath) -and
         -not (Test-Path -LiteralPath $soloRaidCaptureReceiptPath) -and
         -not (Test-Path -LiteralPath $soloRaidPersistenceReceiptPath)) `
        'phase_d_raid_state_staging_not_empty'
    $expectedSoloRaidHeadRevisionUid =
        if ($null -eq $materialization.soloRaidStateHeadRevisionUid) {
            'none'
        }
        else { [string]$materialization.soloRaidStateHeadRevisionUid }
    $executionFx = $null
    Write-PhaseDProgress $launchRoot 'fx_stage'
    if ($null -ne $preparation.plan.commonDelivery) {
        $delivery = $preparation.plan.commonDelivery
        $fxOutput = @(& $runtimeMaterializer --stage-common-boss-delivery true --delivery-path $delivery.path `
            --delivery-sha256 $delivery.sha256 --boss-variant-profile $bossRuntimeVariantProfile `
            --weakness-code $WeaknessCode --launch-root $launchRoot 2>&1)
        Assert-PhaseD ($LASTEXITCODE -eq 0) 'phase_d_boss_runtime_delivery_stage_failed'
        $executionFx = ($fxOutput -join "`n") | ConvertFrom-Json
    }
    Write-PhaseDProgress $launchRoot 'runtime_preparation'
    $runnerLaunchInput = [ordered]@{
        weaknessCode = $WeaknessCode
        jobNonce = [guid]::NewGuid().ToString('N')
        executionFx = $executionFx
        runtimeDbSha256 = $runtimeDbSha256
        expectedWeaknessVariantServerDllSha256 = $expectedWeaknessVariantServerDllSha256
        runtimeBundle = $runtimeBundle
        resourcePreflightHelper = $resourcePreflightHelper
        resourcePreflightHelperSha256 = $resourcePreflightHelperSha256
        resourcePreflightTool = $resourcePreflightTool
        resourceCatalogReceiptPath = $resourceCatalogReceiptPath
        resourceCatalogReceiptSha256 = $resourceCatalogReceiptSha256
        resourcePreflightToolSha256 = $resourcePreflightToolSha256
        launchRoot = $launchRoot
        bossRuntimeVariantProfile = $bossRuntimeVariantProfile
        staticDataVariantRequired = $staticDataVariantRequired
        variantStaticDataPack = $variantStaticDataPack
        variantStaticDataSha256 = $variantStaticDataSha256
        runtimeMaterializer = $runtimeMaterializer
        soloRaidPendingPath = $soloRaidPendingPath
        soloRaidCaptureReceiptPath = $soloRaidCaptureReceiptPath
        accountUid = ([string]$candidate.accountUid)
        accountRevisionSetSha256 = ([string]$candidate.baseRevisions.revisionSetSha256)
        SeasonNumber = $SeasonNumber
        raidSnapshotUid = ([string]$materialization.raidSnapshotUid)
        raidSnapshotSha256 = ([string]$materialization.raidSnapshotSha256)
        clientBuildCode = $clientBuildCode
        clientExecutableSha256 = $clientExecutableSha256
        LaunchContextUid = $LaunchContextUid
        expectedSoloRaidHeadRevisionUid = $expectedSoloRaidHeadRevisionUid
        secretEnvironmentVariable = $secretEnvironmentVariable
    }
    $runnerSpec = New-PhaseDRunnerSpecification -LaunchInput $runnerLaunchInput `
        -PreparationBindingSha256 $preparation.bindingSha256 -ProfileSha256 $bossRuntimeVariantProfileSha256 `
        -SourceManifestSha256 $sourceManifestSha256 -RunIntentCode $ValidationKind
    $runnerBundle = New-PhaseDRunnerBundle -Specification $runnerSpec -ScriptsRoot $PSScriptRoot
    $derivedStart = Join-Path $runnerBundle.root 'invoke-nll-phase-d-runner.ps1'
    $derivedCompletion = $derivedStart
    $watcher = Join-Path $runnerBundle.root 'watch-nll-phase-d-execution.ps1'

    $toolManifestPath = Join-Path $launchRoot 'tool.manifest.tsv'
    $toolLines = @(
        "role_code`tbyte_length`tsha256"
        "derived_start`t$((Get-Item -LiteralPath $derivedStart).Length)`t$(Get-Sha256Lower $derivedStart)"
        "derived_completion`t$((Get-Item -LiteralPath $derivedCompletion).Length)`t$(Get-Sha256Lower $derivedCompletion)"
        "watcher`t$((Get-Item -LiteralPath $watcher).Length)`t$(Get-Sha256Lower $watcher)"
        "source_manifest`t$((Get-Item -LiteralPath $sourceManifestPath).Length)`t$sourceManifestSha256"
    )
    $toolLines += "runner_bundle`t$((Get-Item -LiteralPath $runnerBundle.manifestPath).Length)`t$($runnerBundle.sha256)"
    [IO.File]::WriteAllText(
        $toolManifestPath,
        (($toolLines -join "`n") + "`n"),
        [Text.UTF8Encoding]::new($false))
    $toolManifestSha256 = Get-Sha256Lower $toolManifestPath

    $validationReceiptPath = Join-Path $launchRoot 'validation.receipt.json'
    $validation = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase-d-prelaunch-validation/v1'
        validatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        launchContextUid = $LaunchContextUid
        accountUid = [string]$candidate.accountUid
        accountRevisionSetSha256 = [string]$candidate.baseRevisions.revisionSetSha256
        runtimeDatabaseSha256 = $runtimeDbSha256
        weaknessCode = $WeaknessCode
        bossVariantRegistrySha256 = $bossRuntimeVariantRegistrySha256
        bossVariantProfileCode = [string]$materialization.bossVariantProfileCode
        bossVariantProfileSha256 = [string]$materialization.bossVariantProfileSha256
        sourceBossElementCode = [string]$materialization.sourceBossElementCode
        sourceBossWeaknessCode = [string]$materialization.sourceBossWeaknessCode
        targetBossElementCode = [string]$materialization.targetBossElementCode
        staticDataVariantRequired = $staticDataVariantRequired
        staticDataSourceSha256 = Get-Sha256Lower $sourceStaticDataPack
        staticDataVariantSha256 = $variantStaticDataSha256
        staticDataVariantReceiptSha256 = Get-Sha256Lower $variantStaticDataReceiptPath
        behaviorAssetBundleSha256 = $behaviorAssetBundleSha256
        behaviorAssetBundleByteLength = $behaviorAssetBundleByteLength
        behaviorAssetMatchCount = $behaviorAssetMatchCount
        shieldFxMappingSetSha256 = $selectedShieldFxMappingSetSha256
        shieldFxAssetBundleCount = $selectedShieldFxAssetBundles.Count
        shieldFxAssetMatchCount = $shieldFxAssetMatchCount
        serverDllSha256 = $expectedWeaknessVariantServerDllSha256
        serverSourceManifestSha256 = $expectedWeaknessVariantSourceManifestSha256
        parentServerDllSha256 = $expectedServerDllSha256
        parentServerSourceManifestSha256 = $expectedRankingPrefixSourceManifestSha256
        serverDeploymentReceiptSha256 =
            $expectedRankingPrefixDeploymentReceiptSha256
        sourceManifestSha256 = $sourceManifestSha256
        toolManifestSha256 = $toolManifestSha256
        resourceCatalogPreflightSha256 = $resourceCatalogReceiptSha256
        resourcePreflightToolSetSha256 = $resourcePreflightToolSha256
        resourcePreflightHelperSha256 = $resourcePreflightHelperSha256
        resourceVoiceLanguage = [string]$resourceSelection.language
        resourceDownloadScope = [string]$resourceSelection.scope
        resourcePayloadClosureStatusCode = 'not_evaluated'
        parentRuntimeModified = $false
        goldenModified = $false
        officialInstallModified = $false
        hostsOriginalSha256 = $controlCenterHostsOriginalSha256
        hostsPreparedSha256 = $expectedPhase3B2BaseHostsSha256
        hostsRestoreRequired = $true
        runtimeCold = $true
        verdictCode = 'ready_for_operator_authorized_launch'
    }
    Write-AtomicJson $validationReceiptPath $validation
    $validationReceiptSha256 = Get-Sha256Lower $validationReceiptPath
    $launchContext = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/launch-context/v1'
        runtimePersistenceContractId = 'nll/runtime-persistence/v2'
        launchContextUid = $LaunchContextUid
        createdAtUtc = $createdAtUtc
        accountUid = [string]$candidate.accountUid
        accountRevisionSetSha256 = [string]$candidate.baseRevisions.revisionSetSha256
        seasonNumber = $SeasonNumber
        weaknessCode = $WeaknessCode
        bossVariantRegistrySha256 = $bossRuntimeVariantRegistrySha256
        bossVariantProfileCode = [string]$materialization.bossVariantProfileCode
        bossVariantProfileSha256 = [string]$materialization.bossVariantProfileSha256
        raidSnapshotUid = [string]$materialization.raidSnapshotUid
        raidSnapshotSha256 = [string]$materialization.raidSnapshotSha256
        clientBuildCode = $clientBuildCode
        clientExecutableSha256 = $clientExecutableSha256
        sourceBossElementCode = [string]$materialization.sourceBossElementCode
        sourceBossWeaknessCode = [string]$materialization.sourceBossWeaknessCode
        targetBossElementCode = [string]$materialization.targetBossElementCode
        staticDataVariantRequired = $staticDataVariantRequired
        staticDataSourceSha256 = Get-Sha256Lower $sourceStaticDataPack
        staticDataVariantSha256 = $variantStaticDataSha256
        staticDataVariantReceiptSha256 = Get-Sha256Lower $variantStaticDataReceiptPath
        behaviorAssetBundleSha256 = $behaviorAssetBundleSha256
        behaviorAssetBundleByteLength = $behaviorAssetBundleByteLength
        shieldFxMappingSetSha256 = $selectedShieldFxMappingSetSha256
        shieldFxAssetBundleCount = $selectedShieldFxAssetBundles.Count
        serverDllSha256 = $expectedWeaknessVariantServerDllSha256
        serverSourceManifestSha256 = $expectedWeaknessVariantSourceManifestSha256
        parentServerDllSha256 = $expectedServerDllSha256
        parentServerSourceManifestSha256 = $expectedRankingPrefixSourceManifestSha256
        runtimeDatabaseSha256 = $runtimeDbSha256
        cacheManifestSha256 = if ($null -eq $runtimeBundle) {
            '4fbbe7132de0ed0d489bdae6f647a0dc98c4559328de057fd4f4dc891dc9b26e'
        } else { Get-Sha256Lower ([string]$runtimeBundle.manifestPath) }
        toolManifestSha256 = $toolManifestSha256
        validationReceiptSha256 = $validationReceiptSha256
        statusCode = 'validated'
    }
    Write-AtomicJson $contextPath $launchContext
    $null = Read-PhaseDRunnerBundle -LaunchRoot $launchRoot -ExpectedBundleSha256 $runnerBundle.sha256
    Assert-PhaseDRunnerStartDependencies $runnerSpec
    Set-ExecutionState -StatusCode 'validated'

    if ($ValidateOnly) {
        Assert-PhaseD (-not ([IO.Path]::GetFullPath($ExecutionRoot).StartsWith(
            (Join-Path $RepositoryRoot 'artifacts\automation\phase-d-executions'),
            [StringComparison]::OrdinalIgnoreCase))) 'phase_d_validation_root_must_be_separate'
        [ordered]@{ statusCode = 'validated_not_started'; clientBuildCode = $clientBuildCode;
            launchContextUid = $LaunchContextUid; progressionPreserved = $materialization.progressionPreserved;
            inheritedBestFromBuild = $materialization.soloRaidInheritedCompletedRecordFromBuild;
            clientStarted = $false; systemChanged = $false } | ConvertTo-Json
        return
    }

    [IO.File]::WriteAllBytes(
        $controlCenterHostsBackupPath, [IO.File]::ReadAllBytes($hostsPath))
    Assert-PhaseD `
        ((Get-Sha256Lower $controlCenterHostsBackupPath) -ceq `
            $controlCenterHostsOriginalSha256) `
        'phase_d_hosts_backup_invalid'
    if ($controlCenterHostsOriginalSha256 -cne $expectedPhase3B2BaseHostsSha256) {
        [IO.File]::WriteAllBytes(
            $hostsPath, [IO.File]::ReadAllBytes($phase3B2BaseHostsReference))
    }
    Assert-PhaseD `
        ((Get-Sha256Lower $hostsPath) -ceq $expectedPhase3B2BaseHostsSha256) `
        'phase_d_hosts_prepare_failed'
    $controlCenterHostsPrepared = $true
    Write-AtomicJson (Join-Path $launchRoot 'hosts-preparation.receipt.json') `
        ([ordered]@{
            schemaVersion = 1
            contractId = 'nll/phase-d-hosts-preparation/v1'
            preparedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
            launchContextUid = $LaunchContextUid
            originalSha256 = $controlCenterHostsOriginalSha256
            preparedSha256 = $expectedPhase3B2BaseHostsSha256
            backupSha256 = Get-Sha256Lower $controlCenterHostsBackupPath
            restoreOwnerCode = 'phase_d_completion_watcher'
            officialOutboundFallbackUsed = $false
        })

    Assert-PhaseD `
        (-not [string]::IsNullOrWhiteSpace($controlCenterPgCtl) -and
         -not [string]::IsNullOrWhiteSpace($controlCenterPgData) -and
         -not [string]::IsNullOrWhiteSpace($controlCenterPgLog) -and
         (Test-Path -LiteralPath $controlCenterPgCtl -PathType Leaf) -and
         (Test-Path -LiteralPath $controlCenterPgData -PathType Container)) `
        'phase_d_control_center_database_binding_missing'
    # The common runtime uses PostgreSQL for transactional API persistence.
    # Keep it alive for all seasons/modes, including startup information reads.
    Assert-PhaseDPostgresRunning -PgCtlPath $controlCenterPgCtl -DataPath $controlCenterPgData `
        -OwnershipPath (Join-Path $launchRoot 'phase-d-child-pg.identity.json')

    # The sealed runner owns the bootstrap lane and per-run assessment UID.
    $runtimeLifecycleEntered = $true
    $coordinatorStage = 'derived_start'
    $null = Read-PhaseDRunnerBundle -LaunchRoot $launchRoot -ExpectedBundleSha256 $runnerBundle.sha256
    $startArguments = [ordered]@{ Phase='start'; LaunchRoot=$launchRoot; ExpectedBundleSha256=$runnerBundle.sha256 }
    . (Join-Path $runnerBundle.root 'Nll.PhaseDJob.ps1')
    $jobAttempted = $true
    $executionJob = New-PhaseDExecutionJob -LaunchRoot $launchRoot -ExpectedBundleSha256 $runnerBundle.sha256
    Enter-PhaseDSharedIsolation -LaunchRoot $launchRoot -ExpectedBundleSha256 $runnerBundle.sha256 -RuntimeBundle $runtimeBundle
    $startToolResult = Invoke-PhaseDChildScript `
        -ExecutionJob $executionJob `
        -TimeoutSeconds 300 -OwnershipPath (Join-Path $launchRoot 'phase-d-child-start.identity.json') `
        -ScriptPath $derivedStart `
        -Arguments $startArguments `
        -StandardOutputPath (Join-Path $launchRoot 'derived-start.stdout.log') `
        -StandardErrorPath (Join-Path $launchRoot 'derived-start.stderr.log')
    Assert-PhaseD ($startToolResult.ExitCode -eq 0) 'phase_d_derived_start_failed'
    $coordinatorStage = 'runtime_identity_capture'
    $startReceipt = $startToolResult.StandardOutput | ConvertFrom-Json
    $activePointerPath = Join-Path $evidenceRoot 'active-run.pointer.json'
    $activePointer = Get-Content -LiteralPath $activePointerPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    $runRoot = [string]$activePointer.runRoot
    $runStartPath = Join-Path $runRoot 'run-start.receipt.json'
    $startReceiptSha256 = Get-Sha256Lower $runStartPath
    Assert-PhaseD `
        ([IO.Path]::GetFullPath($runRoot).StartsWith(
            $evidenceRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) `
        'phase_d_process_identity_run_root_invalid'
    $bootstrapExecutable = if ($null -ne $runtimeBundle) {
        Join-Path $runtimeBundle.bootstrapRoot 'artifact\NikkeLocalLab.Phase3B2.PhysicalBootstrap.exe'
    } else {
        'C:\NLL\Runtime\PhysicalBootstrap-v2\artifact\NikkeLocalLab.Phase3B2.PhysicalBootstrap.exe'
    }
    $identityLowerBound = [DateTime]::Parse($createdAtUtc).ToUniversalTime()
    $identityUpperBound = (Get-Item -LiteralPath $runStartPath).LastWriteTimeUtc
    $runtimeProcessIdentities = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase-d-runtime-process-identities/v1'
        launchContextUid = $LaunchContextUid
        startReceiptSha256 = $startReceiptSha256
        client = $null; bootstrap = $null; server = $null
    }
    Initialize-PhaseDProcessIdentitySet -Document $runtimeProcessIdentities -Pointer $activePointer `
        -ExecutablePaths @{ client = $clientExecutable; bootstrap = $bootstrapExecutable; server = (Join-Path $runtimeRoot 'EpinelPS.exe') } `
        -NotBeforeUtc $identityLowerBound -NotAfterUtc $identityUpperBound -Publish {
            param($document)
            Write-AtomicJson (Join-Path $launchRoot 'runtime-processes.identity.json') $document
        }
    $coordinatorStage = 'watcher_start'
    $powershell = Join-Path $env:SystemRoot `
        'System32\WindowsPowerShell\v1.0\powershell.exe'
    $watcherArguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $watcher,
        '-LaunchRoot', $launchRoot,
        '-ServerRoot', $runtimeRoot,
        '-EvidenceRoot', $evidenceRoot,
        '-CompletionScriptPath', $derivedCompletion,
        '-ClientProcessId', [string]$startReceipt.clientProcessId,
        '-StartReceiptSha256', $startReceiptSha256,
        '-ControlCenterPgCtlPath', $controlCenterPgCtl,
        '-ControlCenterPgDataPath', $controlCenterPgData,
        '-ControlCenterPgLogPath', $controlCenterPgLog,
        '-ControlCenterHostsBackupPath', $controlCenterHostsBackupPath,
        '-ControlCenterHostsOriginalSha256', $controlCenterHostsOriginalSha256,
        '-RuntimeMaterializerPath', $runtimeMaterializer,
        '-SoloRaidPendingPayloadPath', $soloRaidPendingPath,
        '-SoloRaidCaptureReceiptPath', $soloRaidCaptureReceiptPath,
        '-SoloRaidPersistenceReceiptPath', $soloRaidPersistenceReceiptPath,
        '-ConnectionStringEnvironmentVariable', $connectionEnvironmentVariable,
        '-IdentitySecretEnvironmentVariable', $secretEnvironmentVariable
    )
    $null = Read-PhaseDRunnerBundle -LaunchRoot $launchRoot -ExpectedBundleSha256 $runnerBundle.sha256
    $watcherArguments += @('-ExpectedRunnerBundleSha256', $runnerBundle.sha256)
    $watcherProcess = Start-Process -FilePath $powershell `
        -ArgumentList $watcherArguments -WindowStyle Hidden -PassThru
    # Spawn alone grants NO mutable ownership; watcher waits for explicit commit.
    $watcherSpawned = $true
    Confirm-PhaseDJobHandoff -LaunchRoot $launchRoot -ExpectedBundleSha256 $runnerBundle.sha256 -Watcher $watcherProcess
    $watcherOwnershipTransferred = $true
    $executionJob.Dispose()
    $executionJob = $null
    $watcherProcessStartedAtUtc = $watcherProcess.StartTime.ToUniversalTime().ToString('o')
    Write-AtomicJson (Join-Path $launchRoot 'completion-watcher.identity.json') `
        ([ordered]@{
            schemaVersion = 1
            contractId = 'nll/phase-d-completion-watcher-identity/v1'
            processId = $watcherProcess.Id
            processStartedAtUtc = $watcherProcessStartedAtUtc
            executablePath = $powershell
        })
    Start-Sleep -Milliseconds 500
    if ($watcherProcess.HasExited) {
        $settledState = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 |
            ConvertFrom-Json
        if ([string]$settledState.statusCode -in
            @('completed','rolled_back','failed')) {
            $settledState | ConvertTo-Json -Depth 8
            return
        }
        throw 'phase_d_completion_watcher_exited_before_handoff'
    }
    # The watcher can finish between HasExited and publication. Share a tiny
    # state-write lock and never overwrite its terminal state with 'started'.
    $coordinatorStage = 'started_transition'
    Invoke-PhaseDStartedTransition -LaunchRoot $launchRoot -Action {
        $launchContext.statusCode = 'started'
        Write-AtomicJson $contextPath $launchContext
        Set-ExecutionState `
            -StatusCode 'started' `
            -ClientProcessId ([int]$startReceipt.clientProcessId) `
            -WatcherProcessId $watcherProcess.Id `
            -WatcherProcessStartedAtUtc $watcherProcessStartedAtUtc `
            -StartReceiptSha256 $startReceiptSha256
    }
    $controlCenterHostsPrepared = $false

    $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    $state | ConvertTo-Json -Depth 8
}
catch {
    $primaryFailure = $_
    Write-PhaseDProgress $launchRoot 'recovery_required'
    try { Write-PhaseDFirstFailure -LaunchRoot $launchRoot -Owner coordinator -Stage $coordinatorStage -Failure $primaryFailure } catch { }
    $failureCode = if ($primaryFailure.Exception.Message -cmatch '^[a-z0-9._-]{3,128}$') {
        $primaryFailure.Exception.Message
    }
    else { 'phase_d_uncontrolled_failure' }
    if ($watcherSpawned -and -not $watcherOwnershipTransferred) {
        try {
            $watcherOwnershipTransferred=Test-PhaseDJobHandoffCommitted $launchRoot $runnerBundle.sha256 $watcherProcess
            if (-not $watcherOwnershipTransferred) {
                # Before commit the watcher cannot run any cleanup/child. Retain
                # the exact created handle and prove its exit before coordinator takeover.
                if (-not $watcherProcess.HasExited) { $watcherProcess.Kill() }
                if (-not $watcherProcess.WaitForExit(10000)) { throw 'phase_d_job_handoff_unproven' }
            }
        } catch {
            Set-ExecutionState -StatusCode 'started' -FailureCode 'phase_d_job_handoff_unproven'
            throw 'phase_d_job_handoff_unproven'
        }
    }
    if ($jobAttempted -and -not $watcherOwnershipTransferred) {
        try { Stop-PhaseDExecutionJob -LaunchRoot $launchRoot -ExpectedBundleSha256 $runnerBundle.sha256 }
        catch {
            Set-ExecutionState -StatusCode 'started' -FailureCode 'phase_d_job_zero_unproven'
            throw 'phase_d_job_zero_unproven'
        }
    }
    if ($failureCode -ceq 'phase_d_child_deadline_unproven' -and -not $jobAttempted) {
        Set-ExecutionState -StatusCode 'started' -FailureCode $failureCode
        throw $failureCode
    }
    if ($watcherOwnershipTransferred) {
        # A live or reconcilable watcher owns every mutable resource after the
        # identity handoff. Preserve its state/evidence and fail this request only.
        throw $failureCode
    }
    $coordinatorRollbackProven = -not $runtimeLifecycleEntered
    if ($runtimeLifecycleEntered) {
        if (Test-PhaseDDerivedStartRollbackProof `
                -EvidencePath $evidenceRoot `
                -RuntimeDatabasePath $runtimeDbPath `
                -ExpectedRuntimeDatabaseSha256 $runtimeDbSha256) {
            $coordinatorRollbackProven = $true
            if ($failureCode -ceq 'phase_d_uncontrolled_failure') {
                $failureCode = 'phase_d_derived_start_failed'
            }
        }
        else {
            try {
                $coordinatorRolledBack = [bool](Invoke-PhaseDEmergencyRollback `
                    -EvidencePath $evidenceRoot -RuntimePath $runtimeRoot
                )
                Assert-PhaseD $coordinatorRolledBack `
                    'phase_d_emergency_rollback_unproven'
                $coordinatorRollbackProven = $true
            }
            catch {
                try { Write-PhaseDFirstFailure -LaunchRoot $launchRoot -Owner coordinator -Stage rollback -CleanupStage rollback -Failure $_ } catch { }
                $failureCode = 'phase_d_emergency_rollback_failed'
                $coordinatorRollbackProven = $false
            }
        }
    }
    if ($coordinatorRollbackProven -and $controlCenterHostsPrepared -and
        (Test-Path -LiteralPath $controlCenterHostsBackupPath -PathType Leaf)) {
        try {
            [IO.File]::WriteAllBytes(
                $hostsPath, [IO.File]::ReadAllBytes($controlCenterHostsBackupPath))
            Assert-PhaseD `
                ((Get-Sha256Lower $hostsPath) -ceq $controlCenterHostsOriginalSha256) `
                'phase_d_hosts_restore_failed'
            $controlCenterHostsPrepared = $false
        }
        catch {
            try { Write-PhaseDFirstFailure -LaunchRoot $launchRoot -Owner coordinator -Stage hosts_restore -CleanupStage hosts_restore -Failure $_ } catch { }
            $failureCode = 'phase_d_hosts_restore_failed'
            $coordinatorRollbackProven = $false
        }
    }
    $finalHostsSha256 = try { Get-Sha256Lower $hostsPath } catch { $null }
    Write-AtomicJson (Join-Path $launchRoot 'hosts-restoration.receipt.json') `
        ([ordered]@{
            schemaVersion = 1
            contractId = 'nll/phase-d-hosts-restoration/v1'
            restoredAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
            launchContextUid = $LaunchContextUid
            restoredToCapturedBaseline = `
                $finalHostsSha256 -ceq $controlCenterHostsOriginalSha256
            officialDomainsUnboundAfterCompletion = `
                $finalHostsSha256 -in @(
                    $expectedCleanHostsSha256,
                    $expectedPostDockerUninstallCleanHostsSha256)
            finalSha256 = $finalHostsSha256
            restorationOwnerCode = 'phase_d_coordinator_failure_path'
        })
    # An unproven rollback remains reconcilable and therefore blocks admission.
    # Only a proven rollback or a pre-runtime failure may become terminal failed.
    $failureStatusCode = if ($coordinatorRollbackProven) { 'failed' } else { 'started' }
    if ($coordinatorRollbackProven -and $runtimeLifecycleEntered) {
        try {
            if ($jobAttempted) { Write-PhaseDRollbackCleanupCheckpoint $launchRoot $runnerBundle.sha256 }
            Ensure-PhaseDPostgresRunning `
                -OwnershipPath (Join-Path $launchRoot 'phase-d-child-pg.identity.json') `
                -PgCtlPath $controlCenterPgCtl `
                -DataPath $controlCenterPgData -LogPath $controlCenterPgLog
        }
        catch {
            try { Write-PhaseDFirstFailure -LaunchRoot $launchRoot -Owner coordinator -Stage database_restart -CleanupStage database_restart -Failure $_ } catch { }
            $failureCode = 'phase_d_control_center_database_restart_failed'
            $failureStatusCode = 'started'
        }
    }
    Set-ExecutionState -StatusCode $failureStatusCode -FailureCode $failureCode
    throw $failureCode
}
finally {
    if ($null -ne $executionJob) { $executionJob.Dispose() }
}
