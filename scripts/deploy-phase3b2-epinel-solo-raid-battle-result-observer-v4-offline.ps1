#requires -Version 5.1

[CmdletBinding()]
param(
    [ValidatePattern('^[D-Z]$')]
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
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace(
            '-', ''
        ).ToLowerInvariant()
    }
    finally { $sha.Dispose() }
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
            (($Value | ConvertTo-Json -Depth 12) + [Environment]::NewLine)
        Move-Item -LiteralPath $temporary -Destination $Path
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
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

function Get-DerivedText {
    param(
        [string]$Path,
        [Collections.Specialized.OrderedDictionary]$Replacements,
        [string]$FailureCode
    )
    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    foreach ($key in $Replacements.Keys) {
        $count = [regex]::Matches(
            $text, [regex]::Escape([string]$key)
        ).Count
        Assert-True ($count -gt 0) ($FailureCode + ':missing=' + $key)
        $text = $text.Replace([string]$key, [string]$Replacements[$key])
    }
    return $text
}

function Get-CriticalFingerprint {
    param(
        [string]$RuntimeRoot,
        [Collections.Specialized.OrderedDictionary]$ToolPaths,
        [string[]]$ReceiptPaths
    )
    $rows = [Collections.Generic.List[string]]::new()
    foreach ($leaf in @('db.json', 'EpinelPS.exe', 'EpinelPS.dll')) {
        $path = Join-Path $RuntimeRoot $leaf
        $rows.Add($path + "`t" + (Get-Sha256Hex $path))
    }
    foreach ($role in $ToolPaths.Keys) {
        $path = [string]$ToolPaths[$role]
        $rows.Add($path + "`t" + (Get-Sha256Hex $path))
    }
    foreach ($path in $ReceiptPaths) {
        $rows.Add($path + "`t" + (Get-Sha256Hex $path))
    }
    $text = (($rows | Sort-Object) -join "`n") + "`n"
    Get-BytesSha256Hex ([Text.UTF8Encoding]::new($false).GetBytes($text))
}

function New-ExactJunction {
    param([string]$Path, [string]$Target, [string]$FailureCode)
    & $env:ComSpec /d /c mklink /J $Path $Target | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) $FailureCode
    $item = Get-Item -LiteralPath $Path -Force
    Assert-True (
        $item.LinkType -ceq 'Junction' -and
        [string]$item.Target -ceq $Target
    ) ($FailureCode + '_verification_failed')
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
Assert-True ($AuditOnly -or $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    'phase3b2_battle_result_observer_v4_requires_administrator'
Assert-True ($env:SystemDrive -ceq 'C:' -and $env:USERNAME -ceq 'zih44') `
    'phase3b2_battle_result_observer_v4_wrong_samsung_boundary'

$micronDrive = $MicronDriveLetter + ':'
if ($AuditOnly) {
    Assert-True (
        $micronDrive -cne $env:SystemDrive -and
        (Test-Path -LiteralPath ($micronDrive + '\') -PathType Container)
    ) 'phase3b2_battle_result_observer_v4_audit_volume_invalid'
}
else {
    $systemDisk = Get-Partition -DriveLetter C | Get-Disk
    $micronDisk = Get-Partition -DriveLetter $MicronDriveLetter | Get-Disk
    Assert-True (
        $micronDrive -cne $env:SystemDrive -and
        $systemDisk.FriendlyName -like 'Samsung SSD 980*' -and
        $micronDisk.FriendlyName -like 'Micron_2200*'
    ) 'phase3b2_battle_result_observer_v4_physical_boundary_invalid'
}
Assert-True (@(Get-Process -Name @(
            'NIKKE', 'EpinelPS', 'nikke_launcher',
            'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
        ) -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_battle_result_observer_v4_runtime_not_cold'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$externalRoot = Join-Path $repositoryRoot '.external\EpinelPS'
$sourcePath = Join-Path $externalRoot `
    'EpinelPS\LobbyServer\Soloraid\SetDamageTrial.cs'
$candidateDllPath = Join-Path $externalRoot `
    'EpinelPS\bin\Release\net10.0\win-x64\EpinelPS.dll'

$parentRuntimeRoot = Join-Path $micronDrive `
    'NLL\Runtime\EpinelPS-SoloRaidTrialPractice-v3'
$observerRuntimeRoot = Join-Path $micronDrive `
    'NLL\Runtime\EpinelPS-SoloRaidBattleResultObserver-v4'
$parentEvidenceRoot = Join-Path $micronDrive 'NLL\E\P3SRTP3'
$observerEvidenceRoot = Join-Path $micronDrive 'NLL\E\P3SROB4'
$observerDeploymentRoot = Join-Path $micronDrive 'NLL\E\P3SROB4D'
$toolRoot = Join-Path $micronDrive 'NLL\Tools'
$parentDeploymentReceiptPath = Join-Path $micronDrive `
    'NLL\E\P3SRTP3D\deployment.receipt.json'
$parentCorrectionReceiptPath = Join-Path $micronDrive `
    'NLL\E\P3SRTP3D\start-content-length-correction.receipt.json'
$parentCompletionPath = Join-Path $parentEvidenceRoot `
    'e765cdf9-2db4-44f2-a127-36189ff24c0b\completion.receipt.json'
$protectedBase =
    'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\EpinelSoloRaidBattleResultObserver-v4'
$bootCacheTarget =
    'C:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\cache'

$parentToolNames = [ordered]@{
    outerStart = 'Start-Phase3B2-Epinel-SoloRaidTrialPractice-v3.ps1'
    innerStart =
        'start-phase3b2-epinel-solo-raid-trial-practice-v3-in-micron.ps1'
    outerCompletion =
        'Complete-Phase3B2-Epinel-SoloRaidTrialPractice-v3.ps1'
    innerCompletion =
        'complete-phase3b2-epinel-solo-raid-trial-practice-v3-in-micron.ps1'
}
$observerToolNames = [ordered]@{
    outerStart = 'Start-Phase3B2-Epinel-BattleResultObserver-v4.ps1'
    innerStart =
        'start-phase3b2-epinel-battle-result-observer-v4-in-micron.ps1'
    outerCompletion =
        'Complete-Phase3B2-Epinel-BattleResultObserver-v4.ps1'
    innerCompletion =
        'complete-phase3b2-epinel-battle-result-observer-v4-in-micron.ps1'
}
$parentToolPaths = [ordered]@{}
foreach ($role in $parentToolNames.Keys) {
    $parentToolPaths[$role] = Join-Path $toolRoot $parentToolNames[$role]
}

$expectedSourceByteLength = 768L
$expectedSourceSha256 =
    '85b2eea58be7ca84ca7dff32a8f22cd0933fe971ea19e7b5631de17c37633d73'
$expectedSourceManifestSha256 =
    'f1baf07687370cab97983458942c3e50b7ee859b92216e4aa384f8697d22c79b'
$expectedCandidateDllByteLength = 15378432L
$expectedCandidateDllSha256 =
    'ac93f0333c3a0f495fae4834fb1b8dc5d2ec79f811d72f5872be0bfe63b0bd6c'
$expectedDatabaseByteLength = 1396709L
$expectedDatabaseSha256 =
    'dee9c6aa5421287ca030e325b81a90a302a5d9e113d57c3065e5d36f6e7c4019'
$expectedParentDllByteLength = 15377920L
$expectedParentDllSha256 =
    '79e499169b42e58e73677fc99c77217f15d6056529bd6f583ce2152127ec28be'
$expectedServerExeByteLength = 162304L
$expectedServerExeSha256 =
    'a28c7ff227a74d260a29389b82caeed3fe196f91eef3d28cabe9977b5ed9d07b'
$expectedParentDeploymentSha256 =
    '71b0ac36178e994ec0a1e4d45d80461fd350e93226f7abf38586ca4b98ede58a'
$expectedParentCorrectionSha256 =
    '2930f7c6aeb68e2028ca3b0b45e86ffb018ad8f2b66f8a0b7116a773b438d928'
$expectedParentCompletionSha256 =
    '84ad5f78ef55ed296ee287b0ddfa19a26c49011b949f32c808616421bfba5f53'
$expectedParentToolDigests = [ordered]@{
    outerStart = 'ef93a21dc6555ea1fac5af5f3f69264d7bf6d62399a4db56aea857dd93e0589d'
    innerStart = 'd5aa8089e0a6c6075f85f527262a4825a465d48050412f0e3a8c025b92319d69'
    outerCompletion = '5ea5f9f4d0883c3ae2f0437ec42cfc6584b7abf5ebdfd5906d3d6bd666ef86fa'
    innerCompletion = 'c3bc7a5259f6a7228b75a103338488a7543a8b53fd6aee940d41ae9d83fe17d9'
}

$requiredFiles = @(
    $sourcePath, $candidateDllPath, $parentDeploymentReceiptPath,
    $parentCorrectionReceiptPath, $parentCompletionPath
) + @($parentToolPaths.Values) + @(
    (Join-Path $parentRuntimeRoot 'db.json'),
    (Join-Path $parentRuntimeRoot 'EpinelPS.exe'),
    (Join-Path $parentRuntimeRoot 'EpinelPS.dll')
)
Assert-True (@($requiredFiles | Where-Object {
            -not (Test-Path -LiteralPath $_ -PathType Leaf)
        }).Count -eq 0) `
    'phase3b2_battle_result_observer_v4_input_missing'
Assert-True (
    (Get-Item -LiteralPath $sourcePath).Length -eq $expectedSourceByteLength -and
    (Get-Sha256Hex $sourcePath) -ceq $expectedSourceSha256 -and
    (Get-Item -LiteralPath $candidateDllPath).Length -eq
        $expectedCandidateDllByteLength -and
    (Get-Sha256Hex $candidateDllPath) -ceq $expectedCandidateDllSha256 -and
    (Get-Item -LiteralPath (Join-Path $parentRuntimeRoot 'db.json')).Length -eq
        $expectedDatabaseByteLength -and
    (Get-Sha256Hex (Join-Path $parentRuntimeRoot 'db.json')) -ceq
        $expectedDatabaseSha256 -and
    (Get-Item -LiteralPath (Join-Path $parentRuntimeRoot 'EpinelPS.exe')).Length -eq
        $expectedServerExeByteLength -and
    (Get-Sha256Hex (Join-Path $parentRuntimeRoot 'EpinelPS.exe')) -ceq
        $expectedServerExeSha256 -and
    (Get-Item -LiteralPath (Join-Path $parentRuntimeRoot 'EpinelPS.dll')).Length -eq
        $expectedParentDllByteLength -and
    (Get-Sha256Hex (Join-Path $parentRuntimeRoot 'EpinelPS.dll')) -ceq
        $expectedParentDllSha256 -and
    (Get-Sha256Hex $parentDeploymentReceiptPath) -ceq
        $expectedParentDeploymentSha256 -and
    (Get-Sha256Hex $parentCorrectionReceiptPath) -ceq
        $expectedParentCorrectionSha256 -and
    (Get-Sha256Hex $parentCompletionPath) -ceq
        $expectedParentCompletionSha256
) 'phase3b2_battle_result_observer_v4_input_drifted'
foreach ($role in $parentToolPaths.Keys) {
    Assert-True (
        (Get-Sha256Hex $parentToolPaths[$role]) -ceq
            $expectedParentToolDigests[$role]
    ) ('phase3b2_battle_result_observer_v4_parent_tool_drifted:' + $role)
}
$parentCache = Get-Item -LiteralPath (Join-Path $parentRuntimeRoot 'cache') `
    -Force -ErrorAction SilentlyContinue
Assert-True (
    $null -ne $parentCache -and $parentCache.LinkType -ceq 'Junction' -and
    [string]$parentCache.Target -ceq $bootCacheTarget
) 'phase3b2_battle_result_observer_v4_parent_cache_invalid'

$sourceRelativePath = 'EpinelPS/LobbyServer/Soloraid/SetDamageTrial.cs'
$sourceManifestText = $sourceRelativePath + "`t" +
    $expectedSourceByteLength + "`t" + $expectedSourceSha256 + "`n"
Assert-True (
    (Get-BytesSha256Hex ([Text.UTF8Encoding]::new($false).GetBytes(
                $sourceManifestText))) -ceq $expectedSourceManifestSha256
) 'phase3b2_battle_result_observer_v4_source_manifest_invalid'

$parentFingerprintBefore = Get-CriticalFingerprint `
    -RuntimeRoot $parentRuntimeRoot `
    -ToolPaths $parentToolPaths `
    -ReceiptPaths @(
        $parentDeploymentReceiptPath, $parentCorrectionReceiptPath,
        $parentCompletionPath
    )

$toolStagingRoot = Join-Path $env:TEMP (
    'NLL-P3SROB4-' + [Guid]::NewGuid().ToString('N')
)
$runtimeStagingRoot = $null
$deploymentStagingRoot = $null
New-Item -ItemType Directory -Path $toolStagingRoot | Out-Null
try {
    $commonReplacements = [ordered]@{
        'EpinelPS-SoloRaidTrialPractice-v3' =
            'EpinelPS-SoloRaidBattleResultObserver-v4'
        'P3SRTP3' = 'P3SROB4'
        '15377920L' = '15378432L'
        '79e499169b42e58e73677fc99c77217f15d6056529bd6f583ce2152127ec28be' =
            $expectedCandidateDllSha256
        'b1061afda20654421c527330ae5bd739efb78f027fe6ae66d48d7a276999c66c' =
            $expectedSourceManifestSha256
        'Start-Phase3B2-Epinel-SoloRaidTrialPractice-v3.ps1' =
            $observerToolNames.outerStart
        'start-phase3b2-epinel-solo-raid-trial-practice-v3-in-micron.ps1' =
            $observerToolNames.innerStart
        'Complete-Phase3B2-Epinel-SoloRaidTrialPractice-v3.ps1' =
            $observerToolNames.outerCompletion
        'complete-phase3b2-epinel-solo-raid-trial-practice-v3-in-micron.ps1' =
            $observerToolNames.innerCompletion
        'nll/phase3b2-epinel-solo-raid-regroup-semantics-start/v3' =
            'nll/phase3b2-epinel-battle-result-observer-start/v4'
        'nll/phase3b2-epinel-solo-raid-regroup-semantics-completion/v3' =
            'nll/phase3b2-epinel-battle-result-observer-completion/v4'
        'nll/phase3b2-epinel-solo-raid-regroup-semantics-validation/v3' =
            'nll/phase3b2-epinel-battle-result-observer-validation/v4'
        'nll/phase3b2-epinel-solo-raid-regroup-semantics-failure/v3' =
            'nll/phase3b2-epinel-battle-result-observer-failure/v4'
    }
    $roleKeys = [ordered]@{
        outerStart = @(
            'EpinelPS-SoloRaidTrialPractice-v3', 'P3SRTP3',
            '15377920L',
            '79e499169b42e58e73677fc99c77217f15d6056529bd6f583ce2152127ec28be',
            'b1061afda20654421c527330ae5bd739efb78f027fe6ae66d48d7a276999c66c',
            'start-phase3b2-epinel-solo-raid-trial-practice-v3-in-micron.ps1',
            'Complete-Phase3B2-Epinel-SoloRaidTrialPractice-v3.ps1',
            'nll/phase3b2-epinel-solo-raid-regroup-semantics-start/v3',
            'nll/phase3b2-epinel-solo-raid-regroup-semantics-completion/v3',
            'nll/phase3b2-epinel-solo-raid-regroup-semantics-validation/v3'
        )
        innerStart = @(
            'EpinelPS-SoloRaidTrialPractice-v3', 'P3SRTP3',
            '79e499169b42e58e73677fc99c77217f15d6056529bd6f583ce2152127ec28be',
            'nll/phase3b2-epinel-solo-raid-regroup-semantics-start/v3',
            'nll/phase3b2-epinel-solo-raid-regroup-semantics-failure/v3'
        )
        outerCompletion = @(
            'complete-phase3b2-epinel-solo-raid-trial-practice-v3-in-micron.ps1'
        )
        innerCompletion = @(
            'EpinelPS-SoloRaidTrialPractice-v3', 'P3SRTP3',
            'nll/phase3b2-epinel-solo-raid-regroup-semantics-start/v3',
            'nll/phase3b2-epinel-solo-raid-regroup-semantics-completion/v3'
        )
    }

    $stagedToolPaths = [ordered]@{}
    foreach ($role in $parentToolNames.Keys) {
        $replacements = [ordered]@{}
        foreach ($key in $roleKeys[$role]) {
            $replacements[$key] = $commonReplacements[$key]
        }
        $stagedPath = Join-Path $toolStagingRoot $observerToolNames[$role]
        Write-Utf8NoBom $stagedPath (Get-DerivedText `
                -Path $parentToolPaths[$role] `
                -Replacements $replacements `
                -FailureCode ('phase3b2_battle_result_observer_v4_projection_invalid:' + $role))
        Assert-PowerShellSyntax $stagedPath `
            ('phase3b2_battle_result_observer_v4_tool_syntax_invalid:' + $role)
        $stagedToolPaths[$role] = $stagedPath
    }
    $toolManifest = @($stagedToolPaths.Keys | ForEach-Object {
            $path = $stagedToolPaths[$_]
            [pscustomobject]@{
                roleCode = $_
                leaf = [IO.Path]::GetFileName($path)
                byteLength = [long](Get-Item -LiteralPath $path).Length
                sha256 = Get-Sha256Hex $path
            }
        })

    if ($AuditOnly) {
        [pscustomobject]@{
            schemaVersion = 1
            contractId =
                'nll/phase3b2-epinel-battle-result-observer-deployment-audit/v4'
            auditedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
            parentFingerprintSha256 = $parentFingerprintBefore
            observerSourceSha256 = $expectedSourceSha256
            observerSourceManifestSha256 = $expectedSourceManifestSha256
            observerDllByteLength = $expectedCandidateDllByteLength
            observerDllSha256 = $expectedCandidateDllSha256
            observedFields = @(
                'utc', 'sequence', 'route', 'battleResult'
            )
            excludedFields = @(
                'account_id', 'identity', 'credential', 'team',
                'damage', 'raw_request_payload'
            )
            semanticsModified = $false
            projectedTools = $toolManifest
            deployable = $true
        } | ConvertTo-Json -Depth 8
        return
    }

    Assert-True (
        -not (Test-Path -LiteralPath $observerRuntimeRoot) -and
        -not (Test-Path -LiteralPath $observerEvidenceRoot) -and
        -not (Test-Path -LiteralPath $observerDeploymentRoot) -and
        @($observerToolNames.Values | Where-Object {
                Test-Path -LiteralPath (Join-Path $toolRoot $_)
            }).Count -eq 0
    ) 'phase3b2_battle_result_observer_v4_target_collision'

    $deploymentUid = [Guid]::NewGuid().ToString('D')
    $runtimeStagingRoot = $observerRuntimeRoot + '.staging-' +
        [Guid]::NewGuid().ToString('N')
    $deploymentStagingRoot = $observerDeploymentRoot + '.staging-' +
        [Guid]::NewGuid().ToString('N')
    $protectedRoot = Join-Path $protectedBase $deploymentUid

    New-Item -ItemType Directory -Path $runtimeStagingRoot | Out-Null
    foreach ($entry in @(Get-ChildItem -LiteralPath $parentRuntimeRoot -Force)) {
        if ($entry.Name -in @('cache', 'logs', 'EpinelPS.dll')) { continue }
        Copy-Item -LiteralPath $entry.FullName -Destination $runtimeStagingRoot `
            -Recurse
    }
    Copy-Item -LiteralPath $candidateDllPath -Destination `
        (Join-Path $runtimeStagingRoot 'EpinelPS.dll')
    New-Item -ItemType Directory -Path `
        (Join-Path $runtimeStagingRoot 'logs') | Out-Null
    New-ExactJunction -Path (Join-Path $runtimeStagingRoot 'cache') `
        -Target $bootCacheTarget `
        -FailureCode 'phase3b2_battle_result_observer_v4_cache_link_failed'

    Assert-True (
        (Get-Sha256Hex (Join-Path $runtimeStagingRoot 'db.json')) -ceq
            $expectedDatabaseSha256 -and
        (Get-Sha256Hex (Join-Path $runtimeStagingRoot 'EpinelPS.exe')) -ceq
            $expectedServerExeSha256 -and
        (Get-Item -LiteralPath (Join-Path $runtimeStagingRoot 'EpinelPS.dll')).Length -eq
            $expectedCandidateDllByteLength -and
        (Get-Sha256Hex (Join-Path $runtimeStagingRoot 'EpinelPS.dll')) -ceq
            $expectedCandidateDllSha256
    ) 'phase3b2_battle_result_observer_v4_runtime_staging_invalid'

    New-Item -ItemType Directory -Path $deploymentStagingRoot | Out-Null
    Write-Utf8NoBom (Join-Path $deploymentStagingRoot 'source.manifest.tsv') `
        $sourceManifestText

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-battle-result-observer-deployment/v4'
        deployedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        deploymentUid = $deploymentUid
        parentLaneCode = 'epinel_solo_raid_regroup_semantics_v3'
        derivedLaneCode = 'epinel_solo_raid_battle_result_observer_v4'
        purposeCode = 'observe_deserialized_battle_result_without_assumption'
        parentFingerprintSha256 = $parentFingerprintBefore
        parentCompletionAssessmentUid =
            'e765cdf9-2db4-44f2-a127-36189ff24c0b'
        parentCompletionReceiptSha256 = $expectedParentCompletionSha256
        observerSourceByteLength = $expectedSourceByteLength
        observerSourceSha256 = $expectedSourceSha256
        observerSourceManifestSha256 = $expectedSourceManifestSha256
        parentServerDllByteLength = $expectedParentDllByteLength
        parentServerDllSha256 = $expectedParentDllSha256
        observerServerDllByteLength = $expectedCandidateDllByteLength
        observerServerDllSha256 = $expectedCandidateDllSha256
        selectedManagerPassedCount = 100
        selectedManagerFailedCount = 0
        observedFields = @('utc', 'sequence', 'route', 'battleResult')
        excludedFields = @(
            'account_id', 'identity', 'credential', 'team',
            'damage', 'raw_request_payload'
        )
        requestPayloadPersisted = $false
        battleSemanticsModified = $false
        resultFilterAdded = $false
        databaseModified = $false
        cacheModified = $false
        parentRuntimeModified = $false
        parentToolsModified = $false
        micronLobbyGoldenModified = $false
        dLobbyGoldenModified = $false
        historicalReceiptBindingApplied = $false
        wrapperSelfHashBindingApplied = $false
        installedTools = $toolManifest
        rollbackCode = 'leave_observer_lane_inert_and_select_untouched_v3'
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        observationRunConsumed = $false
        nextStepCode =
            'boot_micron_nlloperator_run_one_regroup_only_observation'
    }
    Write-AtomicJson (Join-Path $deploymentStagingRoot `
        'deployment.receipt.json') $receipt

    Move-Item -LiteralPath $runtimeStagingRoot `
        -Destination $observerRuntimeRoot
    $runtimeStagingRoot = $null
    New-Item -ItemType Directory -Path $observerEvidenceRoot | Out-Null
    Move-Item -LiteralPath $deploymentStagingRoot `
        -Destination $observerDeploymentRoot
    $deploymentStagingRoot = $null
    foreach ($role in $stagedToolPaths.Keys) {
        Copy-Item -LiteralPath $stagedToolPaths[$role] -Destination `
            (Join-Path $toolRoot $observerToolNames[$role])
    }

    New-Item -ItemType Directory -Path $protectedRoot -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $observerDeploymentRoot `
        'deployment.receipt.json') -Destination $protectedRoot
    Copy-Item -LiteralPath (Join-Path $observerDeploymentRoot `
        'source.manifest.tsv') -Destination $protectedRoot

    $parentFingerprintAfter = Get-CriticalFingerprint `
        -RuntimeRoot $parentRuntimeRoot `
        -ToolPaths $parentToolPaths `
        -ReceiptPaths @(
            $parentDeploymentReceiptPath, $parentCorrectionReceiptPath,
            $parentCompletionPath
        )
    Assert-True (
        $parentFingerprintAfter -ceq $parentFingerprintBefore -and
        -not (Test-Path -LiteralPath (Join-Path $observerEvidenceRoot `
                'active-run.pointer.json')) -and
        @($observerToolNames.Values | Where-Object {
                -not (Test-Path -LiteralPath (Join-Path $toolRoot $_) `
                    -PathType Leaf)
            }).Count -eq 0
    ) 'phase3b2_battle_result_observer_v4_post_deploy_invalid'

    $receiptPath = Join-Path $observerDeploymentRoot `
        'deployment.receipt.json'
    [pscustomobject]@{
        Receipt = $receipt
        MicronReceiptPath = $receiptPath
        MicronReceiptByteLength = (Get-Item -LiteralPath $receiptPath).Length
        MicronReceiptSha256 = Get-Sha256Hex $receiptPath
        ProtectedReceiptPath = Join-Path $protectedRoot `
            'deployment.receipt.json'
        MicronStartCommand =
            "& 'C:\NLL\Tools\Start-Phase3B2-Epinel-BattleResultObserver-v4.ps1' -ValidationKind Challenge"
        MicronCompletionCommand =
            "& 'C:\NLL\Tools\Complete-Phase3B2-Epinel-BattleResultObserver-v4.ps1' -ObservedStageCode season26_challenge_squad -OutcomeCode operator_abort"
    } | ConvertTo-Json -Depth 10
}
finally {
    if ($runtimeStagingRoot -and
        (Test-Path -LiteralPath $runtimeStagingRoot -PathType Container)) {
        Remove-Item -LiteralPath $runtimeStagingRoot -Recurse -Force
    }
    if ($deploymentStagingRoot -and
        (Test-Path -LiteralPath $deploymentStagingRoot -PathType Container)) {
        Remove-Item -LiteralPath $deploymentStagingRoot -Recurse -Force
    }
    if (Test-Path -LiteralPath $toolStagingRoot -PathType Container) {
        Remove-Item -LiteralPath $toolStagingRoot -Recurse -Force
    }
}
