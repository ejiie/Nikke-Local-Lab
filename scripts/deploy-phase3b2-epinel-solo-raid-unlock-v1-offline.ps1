#requires -Version 5.1

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Z]$')]
    [string]$MicronDriveLetter = 'E',
    [switch]$AuditOnly
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
    (Test-Path -LiteralPath $Path -PathType Leaf) -and
        (Get-Item -LiteralPath $Path).Length -eq $ByteLength -and
        (Get-Sha256Hex $Path) -ceq $Sha256
}

function Assert-PowerShellSyntax {
    param([string]$Path, [string]$FailureCode)
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile(
        $Path, [ref]$tokens, [ref]$errors
    ) | Out-Null
    Assert-True (@($errors).Count -eq 0) $FailureCode
}

function Copy-Atomic {
    param([string]$Source, [string]$Destination)
    $temporary = $Destination + '.partial-' + [Guid]::NewGuid().ToString('N')
    try {
        Copy-Item -LiteralPath $Source -Destination $temporary
        Move-Item -LiteralPath $temporary -Destination $Destination
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Write-AtomicJson {
    param([string]$Path, [object]$Value)
    $temporary = $Path + '.partial-' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText(
            $temporary,
            (($Value | ConvertTo-Json -Depth 16) + [Environment]::NewLine),
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

function Get-RuntimeManifest {
    param([string]$Root)

    $members = [Collections.Generic.List[object]]::new()
    foreach ($entry in @(Get-ChildItem -LiteralPath $Root -Force)) {
        if ($entry.Name -in @('cache', 'logs')) { continue }
        if (-not $entry.PSIsContainer -and $entry.Name -in @(
                'db.json', 'epinelps.db', 'epinelps.db-shm',
                'epinelps.db-wal', 'EpinelPS.dll'
            )) { continue }

        $files = if ($entry.PSIsContainer) {
            @(Get-ChildItem -LiteralPath $entry.FullName -File -Recurse -Force)
        } else { @($entry) }
        foreach ($file in $files) {
            $relativePath = $file.FullName.Substring($Root.Length).
                TrimStart([char]'\')
            $members.Add([pscustomobject]@{
                relativePath = $relativePath.Replace('\', '/')
                byteLength = [long]$file.Length
                sha256 = Get-Sha256Hex $file.FullName
            })
        }
    }
    @($members | Sort-Object relativePath)
}

function Get-CanonicalManifestSha256 {
    param([object[]]$Members)
    $canonical = (@($Members | ForEach-Object {
        '{0}`t{1}`t{2}' -f $_.relativePath, $_.byteLength, $_.sha256
    }) -join "`n") + "`n"
    $bytes = [Text.Encoding]::UTF8.GetBytes($canonical)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        (($algorithm.ComputeHash($bytes) | ForEach-Object {
            $_.ToString('x2')
        }) -join '')
    }
    finally { $algorithm.Dispose() }
}

$expectedGoldenServerExeLength = 162304L
$expectedGoldenServerExeSha256 =
    'a28c7ff227a74d260a29389b82caeed3fe196f91eef3d28cabe9977b5ed9d07b'
$expectedGoldenServerDllLength = 15366144L
$expectedGoldenServerDllSha256 =
    'aaa1e49d7a879a6b5ec17ad4c4094ce7d98ce86f860c1529a9ab4d6aecb51f7c'
$expectedCandidateDatabaseLength = 1396707L
$expectedCandidateDatabaseSha256 =
    'd73e92c9e8159b347f42eff5c6c2270e3695e91cd542c05f45bcbb121cd9a1ee'
$expectedDerivedServerDllLength = 15366144L
$expectedDerivedServerDllSha256 =
    'f602c58985a7a90cd206e2b58d793a4c7c2c0f1ea6ba778d0d74d61d68f9635b'
$expectedExternalHead = '317c4f352b91e76470e2b035ada426ff443f9de4'
$expectedExternalTree = 'e429f0ac08cde7561456e158c9403abb7d9d0362'
$expectedHelperLength = 21232L
$expectedHelperSha256 =
    'c27ab88cb692ab9f229aeae0df511ddc85bbe150a506332caa9c71d30e5a7a5b'
$expectedProjectionTestLength = 1717L
$expectedProjectionTestSha256 =
    '8eeb8d351359a0e37e0ca95f0e820a17a9dbd869db2b2f243f84a77d01e2c37c'
$expectedHeaderLength = 139L
$expectedHeaderSha256 =
    '5914cb58fd2146fe761ab531ecb4e321300527186a54b455e59de962ff6c044a'

$goldenToolDigests = [ordered]@{
    'Start-Phase3B2-Epinel-LocaleOverlay-en-v2.ps1' = @(
        15183L, '50ead5cce82a602d67ee3edd114449c8ceb19a178fa8ce921d3d42d565a6646c')
    'start-phase3b2-epinel-minimal-reference-in-micron.ps1' = @(
        39526L, 'a039cd5186df92c16c0091f7d4b4c4bbb907d0bf2adc3ff94d8d425699bc5f69')
    'Complete-Phase3B2-Epinel-Minimal.ps1' = @(
        576L, '16aa339bc83336b6bd3c72da21624eb890e336e22fb1c9672160fa745b0250c1')
    'complete-phase3b2-epinel-minimal-reference-in-micron.ps1' = @(
        9968L, '0ff9cc8285b46fe96d16fe1fe1aca532a6a2b39d89cc9a15f6c611444d63fe09')
}
$progressionToolDigests = [ordered]@{
    'Start-Phase3B2-Epinel-UserProgression-v2.ps1' = @(
        19352L, 'dad26036cf2f9bb364c40869a0056c043ca6439352a36f08f456085f93f016f1')
    'start-phase3b2-epinel-user-progression-v2-in-micron.ps1' = @(
        39525L, '6a503087ffa89d45631d13783351810f2633fb1e51b18faef44f1f9771eee8de')
    'Complete-Phase3B2-Epinel-UserProgression-v2.ps1' = @(
        578L, 'a3521aa2c5b2ffec2e80068e2ead03b5c8976fe4d2d747c2c0990f09180d83f3')
    'complete-phase3b2-epinel-user-progression-v2-in-micron.ps1' = @(
        9966L, '96155783acae84d4dc3296f692a3227d485fec090a503c1782db535da2790356')
}
$derivedToolDigests = [ordered]@{
    'Start-Phase3B2-Epinel-SoloRaidUnlock-v1.ps1' = @(
        21042L, 'dbe477ce58176c842215c969ec98edbf0b9000ed83cc3fb62109d84f888e90c7')
    'start-phase3b2-epinel-solo-raid-unlock-v1-in-micron.ps1' = @(
        39796L, 'cd399f2e3e422638a6c8dcd619f86d3866b7e557c24adb8cf18068c055660ea3')
    'Complete-Phase3B2-Epinel-SoloRaidUnlock-v1.ps1' = @(
        578L, 'e7a552acfb1e1ae7f121d8ac04572d2d0f1456371f0a1963833560666f7795f7')
    'complete-phase3b2-epinel-solo-raid-unlock-v1-in-micron.ps1' = @(
        9955L, '54942d98c5ba5ef57c1a1e3895fd719c196b34873e803286b7b9763612a2cea3')
}

Assert-True ($env:SystemDrive -ceq 'C:') `
    'phase3b2_solo_raid_unlock_deploy_wrong_samsung_boundary'
$micronDrive = $MicronDriveLetter + ':'
$systemDisk = Get-Partition -DriveLetter C | Get-Disk
$micronDisk = Get-Partition -DriveLetter $MicronDriveLetter | Get-Disk
Assert-True (
    $micronDrive -cne $env:SystemDrive -and
    $systemDisk.FriendlyName -like 'Samsung SSD 980*' -and
    $micronDisk.FriendlyName -like 'Micron_2200*'
) 'phase3b2_solo_raid_unlock_deploy_physical_boundary_invalid'
Assert-True (@(Get-Process -Name @(
            'NIKKE', 'EpinelPS', 'nikke_launcher',
            'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
        ) -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_solo_raid_unlock_deploy_runtime_not_cold'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$sourceToolRoot = Join-Path $repositoryRoot 'scripts'
$externalRoot = Join-Path $repositoryRoot '.external\EpinelPS'
$sourceServerDllPath = Join-Path $externalRoot `
    'EpinelPS\bin\Release\net10.0\win-x64\EpinelPS.dll'
$helperPath = Join-Path $externalRoot `
    'EpinelPS\LobbyServer\Soloraid\SoloRaidHelper.cs'
$projectionTestPath = Join-Path $externalRoot `
    'tests\EpinelPS.SelectedManager.Tests\SoloRaidCompatibilityProjectionTests.cs'
$goldenRuntimeRoot = Join-Path $micronDrive `
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
$goldenCacheRoot = Join-Path $goldenRuntimeRoot 'cache'
$goldenServerExePath = Join-Path $goldenRuntimeRoot 'EpinelPS.exe'
$goldenServerDllPath = Join-Path $goldenRuntimeRoot 'EpinelPS.dll'
$goldenDatabasePath = Join-Path $goldenRuntimeRoot 'db.json'
$headerPath = Join-Path $goldenCacheRoot `
    'prdenv\150-b059c3f36c\StandaloneWindows64\pck\latest-651.txt'
$toolRoot = Join-Path $micronDrive 'NLL\Tools'
$parallelRuntimeRoot = Join-Path $micronDrive `
    'NLL\Runtime\EpinelPS-SoloRaidUnlock-v1'
$parallelEvidenceRoot = Join-Path $micronDrive `
    'NLL\Evidence\Phase3B2\Physical\epinel-solo-raid-unlock-v1'
$offlineCacheTarget = $goldenCacheRoot
$protectedRoot =
    'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\EpinelSoloRaidUnlock-v1'

Assert-True (
    (Test-Digest $goldenServerExePath $expectedGoldenServerExeLength `
        $expectedGoldenServerExeSha256) -and
    (Test-Digest $goldenServerDllPath $expectedGoldenServerDllLength `
        $expectedGoldenServerDllSha256) -and
    (Test-Digest $goldenDatabasePath $expectedCandidateDatabaseLength `
        $expectedCandidateDatabaseSha256) -and
    (Test-Digest $headerPath $expectedHeaderLength $expectedHeaderSha256) -and
    (Test-Digest $sourceServerDllPath $expectedDerivedServerDllLength `
        $expectedDerivedServerDllSha256) -and
    (Test-Digest $helperPath $expectedHelperLength $expectedHelperSha256) -and
    (Test-Digest $projectionTestPath $expectedProjectionTestLength `
        $expectedProjectionTestSha256)
) 'phase3b2_solo_raid_unlock_deploy_core_input_invalid'

foreach ($entry in $goldenToolDigests.GetEnumerator()) {
    Assert-True (Test-Digest (Join-Path $toolRoot $entry.Key) `
        ([long]$entry.Value[0]) ([string]$entry.Value[1])) `
        'phase3b2_solo_raid_unlock_deploy_golden_tool_drifted'
}
foreach ($entry in $progressionToolDigests.GetEnumerator()) {
    Assert-True (Test-Digest (Join-Path $toolRoot $entry.Key) `
        ([long]$entry.Value[0]) ([string]$entry.Value[1])) `
        'phase3b2_solo_raid_unlock_deploy_progression_tool_drifted'
}
foreach ($entry in $derivedToolDigests.GetEnumerator()) {
    $sourcePath = Join-Path $sourceToolRoot $entry.Key
    Assert-True (Test-Digest $sourcePath ([long]$entry.Value[0]) `
        ([string]$entry.Value[1])) `
        'phase3b2_solo_raid_unlock_deploy_derived_tool_invalid'
    Assert-PowerShellSyntax $sourcePath `
        'phase3b2_solo_raid_unlock_deploy_derived_tool_syntax_invalid'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $toolRoot $entry.Key))) `
        'phase3b2_solo_raid_unlock_deploy_derived_tool_collision'
}

Assert-True (-not (Test-Path -LiteralPath $parallelRuntimeRoot)) `
    'phase3b2_solo_raid_unlock_deploy_parallel_runtime_collision'
Assert-True (-not (Test-Path -LiteralPath $parallelEvidenceRoot)) `
    'phase3b2_solo_raid_unlock_deploy_evidence_collision'
Assert-True (@('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal' |
        Where-Object { Test-Path -LiteralPath (Join-Path $goldenRuntimeRoot $_) }
    ).Count -eq 0) 'phase3b2_solo_raid_unlock_deploy_golden_sqlite_present'

$goldenManifestBefore = @(Get-RuntimeManifest $goldenRuntimeRoot)
$goldenManifestBeforeSha256 =
    Get-CanonicalManifestSha256 $goldenManifestBefore

if ($AuditOnly) {
    [pscustomobject]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-epinel-solo-raid-unlock-deployment-audit/v1'
        auditedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        micronDrive = $micronDrive
        goldenRuntimeManifestMemberCount = $goldenManifestBefore.Count
        goldenRuntimeManifestSha256 = $goldenManifestBeforeSha256
        derivedServerDllSha256 = $expectedDerivedServerDllSha256
        externalHead = $expectedExternalHead
        externalTree = $expectedExternalTree
        normalCompatibilityLastClearLevel = 7
        goldenMutationPerformed = $false
        dDriveMutationPerformed = $false
        deployable = $true
    } | ConvertTo-Json -Depth 6
    return
}

$deploymentUid = [Guid]::NewGuid().ToString('D')
$stagingRuntimeRoot = $parallelRuntimeRoot + '.staging-' +
    [Guid]::NewGuid().ToString('N')
$movedToolPaths = [Collections.Generic.List[string]]::new()
$runtimeActivated = $false
try {
    New-Item -ItemType Directory -Path $stagingRuntimeRoot | Out-Null
    foreach ($entry in @(Get-ChildItem -LiteralPath $goldenRuntimeRoot -Force)) {
        if ($entry.Name -in @('cache', 'logs')) { continue }
        if (-not $entry.PSIsContainer -and $entry.Name -in @(
                'db.json', 'epinelps.db', 'epinelps.db-shm',
                'epinelps.db-wal'
            )) { continue }
        Copy-Item -LiteralPath $entry.FullName -Destination $stagingRuntimeRoot `
            -Recurse
    }
    New-Item -ItemType Directory -Path (Join-Path $stagingRuntimeRoot 'logs') |
        Out-Null
    Copy-Item -LiteralPath $goldenDatabasePath -Destination `
        (Join-Path $stagingRuntimeRoot 'db.json')
    Copy-Item -LiteralPath $sourceServerDllPath -Destination `
        (Join-Path $stagingRuntimeRoot 'EpinelPS.dll') -Force

    New-Item -ItemType Junction -Path (Join-Path $stagingRuntimeRoot 'cache') `
        -Target $offlineCacheTarget | Out-Null

    $cacheLink = Get-Item -LiteralPath (Join-Path $stagingRuntimeRoot 'cache') `
        -Force
    Assert-True (
        $cacheLink.LinkType -ceq 'Junction' -and
        @($cacheLink.Target).Count -eq 1 -and
        [string]$cacheLink.Target -ceq $offlineCacheTarget -and
        (Test-Path -LiteralPath (Join-Path $stagingRuntimeRoot `
            'cache\prdenv\150-b059c3f36c\StandaloneWindows64\pck\latest-651.txt') `
            -PathType Leaf) -and
        (Test-Digest (Join-Path $stagingRuntimeRoot 'EpinelPS.exe') `
            $expectedGoldenServerExeLength $expectedGoldenServerExeSha256) -and
        (Test-Digest (Join-Path $stagingRuntimeRoot 'EpinelPS.dll') `
            $expectedDerivedServerDllLength $expectedDerivedServerDllSha256) -and
        (Test-Digest (Join-Path $stagingRuntimeRoot 'db.json') `
            $expectedCandidateDatabaseLength $expectedCandidateDatabaseSha256)
    ) 'phase3b2_solo_raid_unlock_deploy_staging_shape_invalid'

    $parallelManifest = @(Get-RuntimeManifest $stagingRuntimeRoot)
    $parallelManifestSha256 = Get-CanonicalManifestSha256 $parallelManifest
    Assert-True (
        $parallelManifest.Count -eq $goldenManifestBefore.Count -and
        $parallelManifestSha256 -ceq $goldenManifestBeforeSha256
    ) 'phase3b2_solo_raid_unlock_deploy_parallel_runtime_drifted'

    Move-Item -LiteralPath $stagingRuntimeRoot `
        -Destination $parallelRuntimeRoot
    $runtimeActivated = $true
    foreach ($entry in $derivedToolDigests.GetEnumerator()) {
        $destination = Join-Path $toolRoot $entry.Key
        Copy-Atomic (Join-Path $sourceToolRoot $entry.Key) $destination
        $movedToolPaths.Add($destination)
    }

    $goldenManifestAfter = @(Get-RuntimeManifest $goldenRuntimeRoot)
    $goldenManifestAfterSha256 =
        Get-CanonicalManifestSha256 $goldenManifestAfter
    Assert-True (
        $goldenManifestAfter.Count -eq $goldenManifestBefore.Count -and
        $goldenManifestAfterSha256 -ceq $goldenManifestBeforeSha256 -and
        (Test-Digest $goldenServerDllPath $expectedGoldenServerDllLength `
            $expectedGoldenServerDllSha256) -and
        (Test-Digest $goldenDatabasePath $expectedCandidateDatabaseLength `
            $expectedCandidateDatabaseSha256)
    ) 'phase3b2_solo_raid_unlock_deploy_golden_changed'

    New-Item -ItemType Directory -Path $parallelEvidenceRoot | Out-Null
    $evidenceRunRoot = Join-Path $parallelEvidenceRoot $deploymentUid
    New-Item -ItemType Directory -Path $evidenceRunRoot | Out-Null
    $protectedRunRoot = Join-Path $protectedRoot $deploymentUid
    New-Item -ItemType Directory -Path $protectedRunRoot -Force | Out-Null

    $rollbackPlan = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-epinel-solo-raid-unlock-rollback-plan/v1'
        deploymentUid = $deploymentUid
        condition = 'runtime_cold_and_validation_not_in_progress'
        removeParallelRuntimeRoot =
            'C:\NLL\Runtime\EpinelPS-SoloRaidUnlock-v1'
        removeDerivedToolLeaves = @($derivedToolDigests.Keys)
        goldenRuntimeRestoreRequired = $false
        goldenToolRestoreRequired = $false
        dDriveRestoreRequired = $false
    }
    $rollbackPath = Join-Path $evidenceRunRoot 'rollback.plan.json'
    Write-AtomicJson $rollbackPath $rollbackPlan

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-epinel-solo-raid-unlock-deployment/v1'
        deployedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        deploymentUid = $deploymentUid
        purposeCode = 'verify_trial_open_after_last_clear_level_projection'
        externalHead = $expectedExternalHead
        externalTree = $expectedExternalTree
        selectedManagerTestCount = 67
        selectedManagerPassedCount = 67
        projectionMethodCode = 'response_only_floor_without_database_mutation'
        normalCompatibilityLastClearLevel = 7
        normalBattleImplemented = $false
        normalRewardImplemented = $false
        quickBattleImplemented = $false
        durationPolicyChanged = $false
        commanderLevelChanged = $false
        derivedServerDllByteLength = $expectedDerivedServerDllLength
        derivedServerDllSha256 = $expectedDerivedServerDllSha256
        candidateDatabaseByteLength = $expectedCandidateDatabaseLength
        candidateDatabaseSha256 = $expectedCandidateDatabaseSha256
        cacheBindingCode = 'offline_drive_junction_rebound_on_micron_start'
        offlineCacheLinkTarget = $offlineCacheTarget.Replace('\', '/')
        micronBootCacheLinkTarget =
            'C:/NLL/EpinelPS/EpinelPS/bin/Release/net10.0/win-x64/cache'
        cacheCopied = $false
        goldenRuntimeManifestMemberCount = $goldenManifestAfter.Count
        goldenRuntimeManifestSha256 = $goldenManifestAfterSha256
        parallelRuntimeManifestMemberCount = $parallelManifest.Count
        parallelRuntimeManifestSha256 = $parallelManifestSha256
        goldenRuntimeModified = $false
        goldenDatabaseModified = $false
        goldenToolsModified = $false
        progressionToolsModified = $false
        cacheModified = $false
        dDriveInspected = $false
        dDriveModified = $false
        localLowInspected = $false
        localLowModified = $false
        hostsModified = $false
        officialOutboundUsed = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        singleValidationRunAuthorized = $true
        validationRunConsumed = $false
        rollbackPlanSha256 = Get-Sha256Hex $rollbackPath
        nextStepCode = 'boot_micron_nlloperator_run_trial_open_validation_once'
    }
    $receiptPath = Join-Path $evidenceRunRoot 'deployment.receipt.json'
    Write-AtomicJson $receiptPath $receipt
    Copy-Atomic $rollbackPath (Join-Path $protectedRunRoot 'rollback.plan.json')
    Copy-Atomic $receiptPath (Join-Path $protectedRunRoot 'deployment.receipt.json')

    [pscustomobject]@{
        Receipt = $receipt
        MicronReceiptPath = $receiptPath
        MicronReceiptByteLength = (Get-Item -LiteralPath $receiptPath).Length
        MicronReceiptSha256 = Get-Sha256Hex $receiptPath
        ProtectedReceiptPath = Join-Path $protectedRunRoot `
            'deployment.receipt.json'
        MicronStartCommand =
            "& 'C:\NLL\Tools\Start-Phase3B2-Epinel-SoloRaidUnlock-v1.ps1'"
        MicronCompletionCommand =
            "& 'C:\NLL\Tools\Complete-Phase3B2-Epinel-SoloRaidUnlock-v1.ps1' -ObservedStageCode solo_raid_menu -OutcomeCode success"
    } | ConvertTo-Json -Depth 12
}
catch {
    if (-not $runtimeActivated -and
        (Test-Path -LiteralPath $stagingRuntimeRoot)) {
        Remove-Item -LiteralPath $stagingRuntimeRoot -Recurse -Force
    }
    throw
}
