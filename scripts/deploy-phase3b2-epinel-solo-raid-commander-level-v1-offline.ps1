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

function Get-BytesSha256Hex {
    param([byte[]]$Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        (($algorithm.ComputeHash($Bytes) | ForEach-Object {
            $_.ToString('x2')
        }) -join '')
    }
    finally { $algorithm.Dispose() }
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

function Replace-ExactOnce {
    param(
        [string]$Text,
        [string]$OldValue,
        [string]$NewValue,
        [string]$FailureCode
    )
    $count = ([regex]::Matches(
        $Text, [regex]::Escape($OldValue)
    )).Count
    Assert-True ($count -eq 1) $FailureCode
    $Text.Replace($OldValue, $NewValue)
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText(
        $Path, $Text, [Text.UTF8Encoding]::new($false)
    )
}

function Write-AtomicJson {
    param([string]$Path, [object]$Value)
    $temporary = $Path + '.partial-' + [Guid]::NewGuid().ToString('N')
    try {
        Write-Utf8NoBom $temporary `
            (($Value | ConvertTo-Json -Depth 16) + [Environment]::NewLine)
        Move-Item -LiteralPath $temporary -Destination $Path
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

$expectedParentDatabaseByteLength = 1396707L
$expectedParentDatabaseSha256 =
    'd73e92c9e8159b347f42eff5c6c2270e3695e91cd542c05f45bcbb121cd9a1ee'
$expectedAppliedDatabaseByteLength = 1396709L
$expectedAppliedDatabaseSha256 =
    'dee9c6aa5421287ca030e325b81a90a302a5d9e113d57c3065e5d36f6e7c4019'
$expectedServerExeByteLength = 162304L
$expectedServerExeSha256 =
    'a28c7ff227a74d260a29389b82caeed3fe196f91eef3d28cabe9977b5ed9d07b'
$expectedServerDllByteLength = 15366144L
$expectedServerDllSha256 =
    'f602c58985a7a90cd206e2b58d793a4c7c2c0f1ea6ba778d0d74d61d68f9635b'
$expectedRawSourceSha256 =
    'efb1b38b4557e45cbefc1922649c22f6725071cb8c5cb2ad269650d7807fe605'

Assert-True ($env:SystemDrive -ceq 'C:') `
    'phase3b2_commander_level_deploy_wrong_samsung_boundary'
$micronDrive = $MicronDriveLetter + ':'
$systemDisk = Get-Partition -DriveLetter C | Get-Disk
$micronDisk = Get-Partition -DriveLetter $MicronDriveLetter | Get-Disk
Assert-True (
    $micronDrive -cne $env:SystemDrive -and
    $systemDisk.FriendlyName -like 'Samsung SSD 980*' -and
    $micronDisk.FriendlyName -like 'Micron_2200*'
) 'phase3b2_commander_level_deploy_physical_boundary_invalid'
Assert-True (@(Get-Process -Name @(
            'NIKKE', 'EpinelPS', 'nikke_launcher',
            'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
        ) -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_commander_level_deploy_runtime_not_cold'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$sourceToolRoot = Join-Path $repositoryRoot 'scripts'
$rawSourcePath = 'C:\Users\zih44\Downloads\nikke_full_scroll_result.json'
$parentRuntimeRoot = Join-Path $micronDrive `
    'NLL\Runtime\EpinelPS-SoloRaidUnlock-v1'
$derivedRuntimeRoot = Join-Path $micronDrive `
    'NLL\Runtime\EpinelPS-SoloRaidLevel-v1'
$offlineCacheTarget = Join-Path $micronDrive `
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\cache'
$toolRoot = Join-Path $micronDrive 'NLL\Tools'
$shortDeploymentRoot = Join-Path $micronDrive 'NLL\E\P3SRL1D'
$protectedRoot =
    'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\EpinelSoloRaidCommanderLevel-v1'

$parentDatabasePath = Join-Path $parentRuntimeRoot 'db.json'
$parentServerExePath = Join-Path $parentRuntimeRoot 'EpinelPS.exe'
$parentServerDllPath = Join-Path $parentRuntimeRoot 'EpinelPS.dll'
$sourceInnerStartPath = Join-Path $sourceToolRoot `
    'start-phase3b2-epinel-solo-raid-unlock-v1-in-micron.ps1'
$sourceInnerCompletionPath = Join-Path $sourceToolRoot `
    'complete-phase3b2-epinel-solo-raid-unlock-v1-in-micron.ps1'
$sourceOuterStartPath = Join-Path $sourceToolRoot `
    'Start-Phase3B2-Epinel-SoloRaidLevel-v1.ps1'
$sourceOuterCompletionPath = Join-Path $sourceToolRoot `
    'Complete-Phase3B2-Epinel-SoloRaidLevel-v1.ps1'

Assert-True (
    (Test-Digest $parentDatabasePath $expectedParentDatabaseByteLength `
        $expectedParentDatabaseSha256) -and
    (Test-Digest $parentServerExePath $expectedServerExeByteLength `
        $expectedServerExeSha256) -and
    (Test-Digest $parentServerDllPath $expectedServerDllByteLength `
        $expectedServerDllSha256) -and
    (Test-Digest $rawSourcePath 964036L $expectedRawSourceSha256) -and
    @($sourceInnerStartPath, $sourceInnerCompletionPath,
        $sourceOuterStartPath, $sourceOuterCompletionPath |
        Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) }
    ).Count -eq 0
) 'phase3b2_commander_level_deploy_input_invalid'

$rawSource = Get-Content -LiteralPath $rawSourcePath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True (
    @($rawSource.phase_1_initial_load).Count -gt 18 -and
    [int]$rawSource.phase_1_initial_load[18].data.player_level -eq 893
) 'phase3b2_commander_level_deploy_source_level_invalid'

$parentText = [IO.File]::ReadAllText(
    $parentDatabasePath, [Text.UTF8Encoding]::new($false, $true)
)
$levelMatches = [regex]::Matches(
    $parentText, '"UserLevel"\s*:\s*1(?=\s*[,}])'
)
Assert-True ($levelMatches.Count -eq 1) `
    'phase3b2_commander_level_deploy_user_level_shape_invalid'
$levelMatch = $levelMatches[0]
$replacement = '"UserLevel": 893'
$candidateText = $parentText.Substring(0, $levelMatch.Index) +
    $replacement +
    $parentText.Substring($levelMatch.Index + $levelMatch.Length)
$candidateBytes = [Text.UTF8Encoding]::new($false).GetBytes($candidateText)
Assert-True (
    $candidateBytes.Length -eq $expectedAppliedDatabaseByteLength -and
    (Get-BytesSha256Hex $candidateBytes) -ceq $expectedAppliedDatabaseSha256 -and
    $candidateText.Substring(0, $levelMatch.Index) -ceq
        $parentText.Substring(0, $levelMatch.Index) -and
    $candidateText.Substring($levelMatch.Index + $replacement.Length) -ceq
        $parentText.Substring($levelMatch.Index + $levelMatch.Length)
) 'phase3b2_commander_level_deploy_byte_boundary_invalid'

$parentDatabase = $parentText | ConvertFrom-Json
$candidateDatabase = $candidateText | ConvertFrom-Json
$parentLevel = [int]$parentDatabase.Users[0].userPointData.UserLevel
$candidateLevel = [int]$candidateDatabase.Users[0].userPointData.UserLevel
$parentExperience =
    [int]$parentDatabase.Users[0].userPointData.ExperiencePoint
$candidateExperience =
    [int]$candidateDatabase.Users[0].userPointData.ExperiencePoint
$candidateDatabase.Users[0].userPointData.UserLevel = $parentLevel
Assert-True (
    @($parentDatabase.Users).Count -eq 1 -and
    @($candidateDatabase.Users).Count -eq 1 -and
    $parentLevel -eq 1 -and $candidateLevel -eq 893 -and
    $parentExperience -eq 0 -and $candidateExperience -eq 0 -and
    (($parentDatabase | ConvertTo-Json -Depth 100 -Compress) -ceq
        ($candidateDatabase | ConvertTo-Json -Depth 100 -Compress))
) 'phase3b2_commander_level_deploy_semantic_boundary_invalid'

foreach ($sourcePath in @(
        $sourceInnerStartPath, $sourceInnerCompletionPath,
        $sourceOuterStartPath, $sourceOuterCompletionPath
    )) {
    Assert-PowerShellSyntax $sourcePath `
        'phase3b2_commander_level_deploy_source_tool_syntax_invalid'
}

Assert-True (
    -not (Test-Path -LiteralPath $derivedRuntimeRoot) -and
    -not (Test-Path -LiteralPath $shortDeploymentRoot) -and
    @(
        'Start-Phase3B2-Epinel-SoloRaidLevel-v1.ps1',
        'start-phase3b2-epinel-solo-raid-level-v1-in-micron.ps1',
        'Complete-Phase3B2-Epinel-SoloRaidLevel-v1.ps1',
        'complete-phase3b2-epinel-solo-raid-level-v1-in-micron.ps1' |
        Where-Object { Test-Path -LiteralPath (Join-Path $toolRoot $_) }
    ).Count -eq 0
) 'phase3b2_commander_level_deploy_target_collision'

if ($AuditOnly) {
    [pscustomobject]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-solo-raid-commander-level-audit/v1'
        auditedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        sourceCommanderLevel = $parentLevel
        appliedCommanderLevel = $candidateLevel
        sourceJsonPath =
            'phase_1_initial_load[18].data.player_level'
        sourceSha256 = $expectedRawSourceSha256
        parentDatabaseSha256 = $expectedParentDatabaseSha256
        appliedDatabaseSha256 = $expectedAppliedDatabaseSha256
        onlyUserLevelFieldChanged = $true
        experiencePointFabricated = $false
        deployable = $true
    } | ConvertTo-Json -Depth 6
    return
}

$deploymentUid = [Guid]::NewGuid().ToString('D')
$runtimeStagingRoot = $derivedRuntimeRoot + '.staging-' +
    [Guid]::NewGuid().ToString('N')
$toolStagingRoot = Join-Path $env:TEMP (
    'NLL-P3SRL1-' + [Guid]::NewGuid().ToString('N')
)
$installedToolPaths = [Collections.Generic.List[string]]::new()
$runtimeActivated = $false
$deploymentActivated = $false
try {
    New-Item -ItemType Directory -Path $runtimeStagingRoot | Out-Null
    foreach ($entry in @(Get-ChildItem -LiteralPath $parentRuntimeRoot -Force)) {
        if ($entry.Name -in @('cache', 'logs')) { continue }
        if (-not $entry.PSIsContainer -and $entry.Name -in @(
                'db.json', 'epinelps.db', 'epinelps.db-shm',
                'epinelps.db-wal'
            )) { continue }
        Copy-Item -LiteralPath $entry.FullName -Destination $runtimeStagingRoot `
            -Recurse
    }
    New-Item -ItemType Directory -Path (Join-Path $runtimeStagingRoot 'logs') |
        Out-Null
    [IO.File]::WriteAllBytes(
        (Join-Path $runtimeStagingRoot 'db.json'), $candidateBytes
    )
    New-Item -ItemType Junction -Path (Join-Path $runtimeStagingRoot 'cache') `
        -Target $offlineCacheTarget | Out-Null

    Assert-True (
        (Test-Digest (Join-Path $runtimeStagingRoot 'db.json') `
            $expectedAppliedDatabaseByteLength $expectedAppliedDatabaseSha256) -and
        (Test-Digest (Join-Path $runtimeStagingRoot 'EpinelPS.exe') `
            $expectedServerExeByteLength $expectedServerExeSha256) -and
        (Test-Digest (Join-Path $runtimeStagingRoot 'EpinelPS.dll') `
            $expectedServerDllByteLength $expectedServerDllSha256)
    ) 'phase3b2_commander_level_deploy_runtime_staging_invalid'

    New-Item -ItemType Directory -Path $toolStagingRoot | Out-Null
    $innerStartText = Get-Content -LiteralPath $sourceInnerStartPath -Raw `
        -Encoding UTF8
    $innerStartText = Replace-ExactOnce $innerStartText `
        'C:\NLL\Runtime\EpinelPS-SoloRaidUnlock-v1' `
        'C:\NLL\Runtime\EpinelPS-SoloRaidLevel-v1' `
        'phase3b2_commander_level_deploy_inner_start_root_shape_invalid'
    $innerStartText = Replace-ExactOnce $innerStartText `
        'C:\NLL\Evidence\Phase3B2\Physical\epinel-solo-raid-unlock-v1' `
        'C:\NLL\E\P3SRL1' `
        'phase3b2_commander_level_deploy_inner_start_evidence_shape_invalid'
    $innerStartText = Replace-ExactOnce $innerStartText `
        $expectedParentDatabaseSha256 $expectedAppliedDatabaseSha256 `
        'phase3b2_commander_level_deploy_inner_start_db_shape_invalid'
    $innerStartStagingPath = Join-Path $toolStagingRoot `
        'start-phase3b2-epinel-solo-raid-level-v1-in-micron.ps1'
    Write-Utf8NoBom $innerStartStagingPath $innerStartText

    $innerCompletionText = Get-Content `
        -LiteralPath $sourceInnerCompletionPath -Raw -Encoding UTF8
    $innerCompletionText = Replace-ExactOnce $innerCompletionText `
        'C:\NLL\Runtime\EpinelPS-SoloRaidUnlock-v1' `
        'C:\NLL\Runtime\EpinelPS-SoloRaidLevel-v1' `
        'phase3b2_commander_level_deploy_inner_completion_root_invalid'
    $innerCompletionText = Replace-ExactOnce $innerCompletionText `
        'C:\NLL\Evidence\Phase3B2\Physical\epinel-solo-raid-unlock-v1' `
        'C:\NLL\E\P3SRL1' `
        'phase3b2_commander_level_deploy_inner_completion_evidence_invalid'
    $innerCompletionText = Replace-ExactOnce $innerCompletionText `
        $expectedParentDatabaseSha256 $expectedAppliedDatabaseSha256 `
        'phase3b2_commander_level_deploy_inner_completion_db_invalid'
    $innerCompletionText = Replace-ExactOnce $innerCompletionText `
        'nll/phase3b2-epinel-solo-raid-unlock-completion/v1' `
        'nll/phase3b2-epinel-solo-raid-commander-level-completion/v1' `
        'phase3b2_commander_level_deploy_inner_completion_contract_invalid'
    $innerCompletionStagingPath = Join-Path $toolStagingRoot `
        'complete-phase3b2-epinel-solo-raid-level-v1-in-micron.ps1'
    Write-Utf8NoBom $innerCompletionStagingPath $innerCompletionText

    foreach ($path in @($innerStartStagingPath, $innerCompletionStagingPath)) {
        Assert-PowerShellSyntax $path `
            'phase3b2_commander_level_deploy_derived_tool_syntax_invalid'
    }

    Move-Item -LiteralPath $runtimeStagingRoot -Destination $derivedRuntimeRoot
    $runtimeActivated = $true
    $toolSourceMap = [ordered]@{
        'Start-Phase3B2-Epinel-SoloRaidLevel-v1.ps1' =
            $sourceOuterStartPath
        'start-phase3b2-epinel-solo-raid-level-v1-in-micron.ps1' =
            $innerStartStagingPath
        'Complete-Phase3B2-Epinel-SoloRaidLevel-v1.ps1' =
            $sourceOuterCompletionPath
        'complete-phase3b2-epinel-solo-raid-level-v1-in-micron.ps1' =
            $innerCompletionStagingPath
    }
    foreach ($entry in $toolSourceMap.GetEnumerator()) {
        $destination = Join-Path $toolRoot $entry.Key
        Copy-Item -LiteralPath $entry.Value -Destination $destination
        $installedToolPaths.Add($destination)
    }

    New-Item -ItemType Directory -Path $shortDeploymentRoot | Out-Null
    $deploymentActivated = $true
    $protectedRunRoot = Join-Path $protectedRoot $deploymentUid
    New-Item -ItemType Directory -Path $protectedRunRoot -Force | Out-Null

    $rollbackPlan = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-solo-raid-commander-level-rollback/v1'
        deploymentUid = $deploymentUid
        condition = 'runtime_cold_and_no_active_pointer'
        removeDerivedRuntimeRoot =
            'C:\NLL\Runtime\EpinelPS-SoloRaidLevel-v1'
        removeShortEvidenceRoots = @('C:\NLL\E\P3SRL1', 'C:\NLL\E\P3SRL1D')
        removeToolLeaves = @($toolSourceMap.Keys)
        parentRuntimeRestoreRequired = $false
        goldenRuntimeRestoreRequired = $false
        dDriveRestoreRequired = $false
    }
    $rollbackPath = Join-Path $shortDeploymentRoot 'rollback.plan.json'
    Write-AtomicJson $rollbackPath $rollbackPlan

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-solo-raid-commander-level-deployment/v1'
        deployedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        deploymentUid = $deploymentUid
        commanderLevelSourceCode =
            'operator_capture_phase_1_initial_load_18_data_player_level'
        sourceJsonPath = 'phase_1_initial_load[18].data.player_level'
        sourceByteLength = 964036L
        sourceSha256 = $expectedRawSourceSha256
        rawSourceCopied = $false
        sourceCommanderLevel = $parentLevel
        appliedCommanderLevel = $candidateLevel
        experiencePointBefore = $parentExperience
        experiencePointAfter = $candidateExperience
        experiencePointFabricated = $false
        onlyUserLevelFieldChanged = $true
        exactTextReplacementCount = 1
        bytePrefixAndSuffixPreserved = $true
        semanticRoundTripDifferenceCount = 1
        parentDatabaseByteLength = $expectedParentDatabaseByteLength
        parentDatabaseSha256 = $expectedParentDatabaseSha256
        appliedDatabaseByteLength = $expectedAppliedDatabaseByteLength
        appliedDatabaseSha256 = $expectedAppliedDatabaseSha256
        serverDllSha256 = $expectedServerDllSha256
        derivedRuntimeRoot =
            'C:\NLL\Runtime\EpinelPS-SoloRaidLevel-v1'
        shortRunEvidenceRoot = 'C:\NLL\E\P3SRL1'
        maxPlannedEvidencePathCharacterCount = 99
        outerRunBindingWritten = $false
        pathTooLongRegressionPrevented = $true
        parentRuntimeModified = $false
        goldenRuntimeModified = $false
        goldenToolsModified = $false
        cacheCopied = $false
        cacheModified = $false
        dDriveInspected = $false
        dDriveModified = $false
        localLowInspected = $false
        localLowModified = $false
        officialOutboundUsed = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        startWrapperSha256 = Get-Sha256Hex (Join-Path $toolRoot `
            'Start-Phase3B2-Epinel-SoloRaidLevel-v1.ps1')
        innerStartSha256 = Get-Sha256Hex (Join-Path $toolRoot `
            'start-phase3b2-epinel-solo-raid-level-v1-in-micron.ps1')
        completionWrapperSha256 = Get-Sha256Hex (Join-Path $toolRoot `
            'Complete-Phase3B2-Epinel-SoloRaidLevel-v1.ps1')
        innerCompletionSha256 = Get-Sha256Hex (Join-Path $toolRoot `
            'complete-phase3b2-epinel-solo-raid-level-v1-in-micron.ps1')
        rollbackPlanSha256 = Get-Sha256Hex $rollbackPath
        singleValidationRunAuthorized = $true
        validationRunConsumed = $false
        nextStepCode =
            'boot_micron_nlloperator_verify_commander_level_once'
    }
    $receiptPath = Join-Path $shortDeploymentRoot 'deployment.receipt.json'
    Write-AtomicJson $receiptPath $receipt
    Copy-Item -LiteralPath $rollbackPath -Destination `
        (Join-Path $protectedRunRoot 'rollback.plan.json')
    Copy-Item -LiteralPath $receiptPath -Destination `
        (Join-Path $protectedRunRoot 'deployment.receipt.json')

    [pscustomobject]@{
        Receipt = $receipt
        MicronReceiptPath = $receiptPath
        MicronReceiptByteLength = (Get-Item -LiteralPath $receiptPath).Length
        MicronReceiptSha256 = Get-Sha256Hex $receiptPath
        ProtectedReceiptPath = Join-Path $protectedRunRoot `
            'deployment.receipt.json'
        MicronStartCommand =
            "& 'C:\NLL\Tools\Start-Phase3B2-Epinel-SoloRaidLevel-v1.ps1'"
        MicronCompletionCommand =
            "& 'C:\NLL\Tools\Complete-Phase3B2-Epinel-SoloRaidLevel-v1.ps1' -ObservedStageCode <stage> -OutcomeCode <outcome>"
    } | ConvertTo-Json -Depth 10
}
catch {
    foreach ($path in @($installedToolPaths)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force
        }
    }
    if ($deploymentActivated -and
        (Test-Path -LiteralPath $shortDeploymentRoot -PathType Container)) {
        Remove-Item -LiteralPath $shortDeploymentRoot -Recurse -Force
    }
    if ($runtimeActivated -and
        (Test-Path -LiteralPath $derivedRuntimeRoot -PathType Container)) {
        Remove-Item -LiteralPath $derivedRuntimeRoot -Recurse -Force
    }
    throw
}
finally {
    if (Test-Path -LiteralPath $runtimeStagingRoot -PathType Container) {
        Remove-Item -LiteralPath $runtimeStagingRoot -Recurse -Force
    }
    if (Test-Path -LiteralPath $toolStagingRoot -PathType Container) {
        Remove-Item -LiteralPath $toolStagingRoot -Recurse -Force
    }
}
