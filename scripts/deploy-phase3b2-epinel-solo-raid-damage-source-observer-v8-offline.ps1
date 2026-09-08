#requires -Version 5.1

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Z]$')]
    [string]$MicronDriveLetter = 'E',
    [string]$DotnetPath = '',
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
        return ($algorithm.ComputeHash($Bytes) | ForEach-Object {
                $_.ToString('x2')
            }) -join ''
    }
    finally {
        $algorithm.Dispose()
    }
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Write-AtomicJson {
    param([string]$Path, [object]$Value)
    $temporary = $Path + '.partial-' + [Guid]::NewGuid().ToString('N')
    Write-Utf8NoBom $temporary (($Value | ConvertTo-Json -Depth 14) + "`n")
    Move-Item -LiteralPath $temporary -Destination $Path -Force
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

function Replace-ExactlyOnce {
    param(
        [string]$Text,
        [string]$Before,
        [string]$After,
        [string]$FailureCode
    )
    $count = [regex]::Matches($Text, [regex]::Escape($Before)).Count
    Assert-True ($count -eq 1) ($FailureCode + ':count=' + $count)
    $Text.Replace($Before, $After)
}

function Get-DerivedToolText {
    param(
        [string]$Path,
        [Collections.Specialized.OrderedDictionary]$Replacements
    )
    $text = (Get-Content -LiteralPath $Path -Raw -Encoding UTF8).Replace(
        "`r`n", "`n"
    )
    foreach ($before in $Replacements.Keys) {
        if ($text.Contains([string]$before)) {
            $text = $text.Replace(
                [string]$before,
                [string]$Replacements[$before]
            )
        }
    }
    return $text
}

function Get-CriticalFingerprint {
    param(
        [string]$RuntimeRoot,
        [Collections.Specialized.OrderedDictionary]$ToolPaths,
        [string[]]$SentinelPaths
    )
    $rows = [Collections.Generic.List[string]]::new()
    foreach ($leaf in @(
            'db.json', 'EpinelPS.exe', 'EpinelPS.dll', 'log4net.config'
        )) {
        $path = Join-Path $RuntimeRoot $leaf
        $rows.Add($path + "`t" + (Get-Sha256Hex $path))
    }
    foreach ($role in $ToolPaths.Keys) {
        $path = [string]$ToolPaths[$role]
        $rows.Add($path + "`t" + (Get-Sha256Hex $path))
    }
    foreach ($path in $SentinelPaths) {
        $rows.Add($path + "`t" + (Get-Sha256Hex $path))
    }
    $canonical = (($rows | Sort-Object) -join "`n") + "`n"
    Get-BytesSha256Hex ([Text.UTF8Encoding]::new($false).GetBytes($canonical))
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
    'phase3b2_damage_source_observer_v8_requires_administrator'
Assert-True ($env:SystemDrive -ceq 'C:' -and $env:USERNAME -ceq 'zih44') `
    'phase3b2_damage_source_observer_v8_wrong_samsung_boundary'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$externalRoot = Join-Path $repositoryRoot '.external\EpinelPS'
if ([string]::IsNullOrWhiteSpace($DotnetPath)) {
    $DotnetPath = Join-Path $repositoryRoot `
        '.tmp-dotnet-sdk-10.0.400\dotnet.exe'
}
$micronDrive = $MicronDriveLetter + ':'
$toolRoot = Join-Path $micronDrive 'NLL\Tools'
$parentRuntimeRoot = Join-Path $micronDrive `
    'NLL\Runtime\EpinelPS-SoloRaidScoreConsistency-v7'
$parentEvidenceRoot = Join-Path $micronDrive 'NLL\E\P3SRSC7'
$targetRuntimeRoot = Join-Path $micronDrive `
    'NLL\Runtime\EpinelPS-SoloRaidDamageSourceObserver-v8'
$targetEvidenceRoot = Join-Path $micronDrive 'NLL\E\P3SRDSO8'
$targetDeploymentRoot = Join-Path $micronDrive 'NLL\E\P3SRDSO8D'
$candidateDllPath = Join-Path $externalRoot `
    'EpinelPS\bin\Release\net10.0\win-x64\EpinelPS.dll'
$bootCacheTarget =
    'C:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\cache'
$protectedBase =
    'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\EpinelSoloRaidDamageSourceObserver-v8'

$parentToolNames = [ordered]@{
    outerStart = 'Start-Phase3B2-Epinel-SoloRaidScoreConsistency-v7.ps1'
    innerStart = 'start-phase3b2-epinel-solo-raid-score-consistency-v7-in-micron.ps1'
    outerCompletion = 'Complete-Phase3B2-Epinel-SoloRaidScoreConsistency-v7.ps1'
    innerCompletion = 'complete-phase3b2-epinel-solo-raid-score-consistency-v7-in-micron.ps1'
}
$targetToolNames = [ordered]@{
    outerStart = 'Start-Phase3B2-Epinel-SoloRaidDamageSourceObserver-v8.ps1'
    innerStart = 'start-phase3b2-epinel-solo-raid-damage-source-observer-v8-in-micron.ps1'
    outerCompletion = 'Complete-Phase3B2-Epinel-SoloRaidDamageSourceObserver-v8.ps1'
    innerCompletion = 'complete-phase3b2-epinel-solo-raid-damage-source-observer-v8-in-micron.ps1'
}
$parentToolPaths = [ordered]@{}
foreach ($role in $parentToolNames.Keys) {
    $parentToolPaths[$role] = Join-Path $toolRoot $parentToolNames[$role]
}
$expectedParentToolHashes = [ordered]@{
    outerStart = 'ecb0cec6ba3ef94a7dd4eb791136417898c19e02e6d8e21fb4cfe236ddbca859'
    innerStart = 'a6de987367d314e97d9d37e3d6a07e866977a6d243daa836722b0d36ae448a23'
    outerCompletion = '29b19f4653f3d66c123076001092cbcf1de2add63eeac91716e11b6d71288f7d'
    innerCompletion = '6b84316b208f125e4c74aa7982eed754935b19be640ad54e65ce8df79c3549b2'
}
$expectedDatabaseSha256 =
    'dee9c6aa5421287ca030e325b81a90a302a5d9e113d57c3065e5d36f6e7c4019'
$expectedServerExeSha256 =
    'a28c7ff227a74d260a29389b82caeed3fe196f91eef3d28cabe9977b5ed9d07b'
$expectedParentDllSha256 =
    '39949e0d490d5d4996cd26fb1cd6a990ff57c20bfd99676c14878b9dba4e0a39'
$expectedLogConfigSha256 =
    '31b873b3ad156436f0a55f54f1518fde9e2e6c0059cca3ec2e3b181c08c448b9'
$candidateDllByteLength = 15392256L
$candidateDllSha256 =
    '7220be7819121c38acfe9b221bfa6a89b7f894e737bd5df97a955289e2417519'
$expectedSourceManifestSha256 =
    '4a0a1f71fe9b7a235703293d6a9c6adb9626ab18b0a8d8daf885c01008fe1f02'

$micronGoldenReceipt = Join-Path $micronDrive `
    'NLL\Evidence\Phase3B2\Physical\epinel-lobby-golden-baseline-v1\15089f3e-92f2-4833-ab1b-348d1463f9fc\golden-baseline.receipt.json'
$micronGoldenManifest = Join-Path $micronDrive `
    'NLL\Backups\Phase3B2\EpinelLobbyGoldenBaseline-v1\15089f3e-92f2-4833-ab1b-348d1463f9fc\artifact.manifest.json'
$dCheckpointRoot =
    'D:\NikkeLocalLab\Backups\phase3b2-season26-challenge-regroup-v5-checkpoint-v1\e40c70a0-16a3-4a83-9d30-b16f368ce73a'
$v7DeploymentRoot = Join-Path $micronDrive 'NLL\E\P3SRSC7D'
$sentinelPaths = @(
    $micronGoldenReceipt,
    $micronGoldenManifest,
    (Join-Path $dCheckpointRoot 'metadata\seal.receipt.json'),
    (Join-Path $dCheckpointRoot 'metadata\content.manifest.json'),
    (Join-Path $v7DeploymentRoot 'deployment.receipt.json'),
    (Join-Path $v7DeploymentRoot 'audit.receipt.json'),
    (Join-Path $v7DeploymentRoot 'source.manifest.tsv')
)
$expectedSentinelHashes = @(
    'ebf5c2f7692e7de7ec9b8bcf3acba112cdb8efbfbb888967acde7e429e877f9c',
    '25a3a7696c486098bedf5184c31d80380543c3ab4809467e71b0a4594c332be7',
    'e69ee9020abf5c77fc61f433ae56729d36c82c10289b385ee1bdde30604e3753',
    'bed4e1ba8a58b42d3ae8e4b1d5409c0966efc19d53f6ec87cd6d426252e82b59',
    'dc9b7cce0b14bf6203f7f4c406699878ee7a2525bf30b51fb9843a0bb374c35e',
    'ded4fe950a57212543670a9585477e139581018625c65814e409ae33d49b7da9',
    'caf873d9b353a4879ab4ef4ace596d478d3c3b6c65b3e33103d400b66d7ef4dd'
)

$sourceManifestText = @'
EpinelPS/LobbyServer/Soloraid/ClassicSoloRaidPeriodProvider.cs	2361	1b94449d3b5743481d87104e861c162dea6329d4cf967a495d028bce64fe1c51
EpinelPS/LobbyServer/Soloraid/ClassicSoloRaidRouteExecutor.cs	14837	77fe00a83b8a03e6b6dc0bf94289affcecd54d376c74a2a053ab38dcd9d15c69
EpinelPS/LobbyServer/Soloraid/ClassicSoloRaidRoutePolicy.cs	3964	f8b0e461e8245db78528de2b2bcbb35f8c6788d5c58ce720676b282038a0bbb2
EpinelPS/LobbyServer/Soloraid/ClosePractice.cs	483	008fb87bd9886ee98c800839551165ca1725ee7f792c73a7496b2e7957d1f1ce
EpinelPS/LobbyServer/Soloraid/GetInfo.cs	576	43d29fc4e29a09844acc1a7eabeecf38ff6fc3097b924c527a5c34d837034de8
EpinelPS/LobbyServer/Soloraid/GetLevelPractice.cs	408	3269e71a731f88f1798b349955b2087a016407b5fd48e827a430f988944eef91
EpinelPS/LobbyServer/Soloraid/GetRankerSquad.cs	749	86439465fc9d61020d0e206e4527f6846e5b0842d7abd2c778579a56c40585dd
EpinelPS/LobbyServer/Soloraid/GetRanking.cs	730	1110f2de667bee4bc593c803d03eb3e80bc3ba6414c3771acbfb8515d6aba64e
EpinelPS/LobbyServer/Soloraid/OpenPractice.cs	513	d04b2622940a9cc9e4a44c77b5f27434356a48f8e14615c90fb17e4701371e3d
EpinelPS/LobbyServer/Soloraid/SetDamagePractice.cs	402	2bcccbdefcb7646e116e5685f070b6a87b18385f8c443a40ce76e1705b7cd25c
EpinelPS/LobbyServer/Soloraid/SetDamageTrial.cs	2666	d6c973c7f0fc027ccb6c80fbfbd043b15f1ba6869e254b4ea9e1b4a7980d80a8
EpinelPS/LobbyServer/Soloraid/SoloRaidHelper.cs	37699	cc228e1526de6b2ec831c7dbbddd30f769d567ac722dad9f59d402e9a1a3687d
EpinelPS/SoloRaidSelection/SoloRaidManagerSelectionResolver.cs	5962	995c084ad7eb3ea1102375ffd307acce9ad614eba35c2045aa0750d934126991
tests/EpinelPS.SelectedManager.Tests/BaselineRouteAuditTests.cs	3581	3cd4992411140f28796abd2703b7744149c8e59a839373dd445731db8c46f6aa
tests/EpinelPS.SelectedManager.Tests/ClassicSoloRaidPeriodProviderTests.cs	5305	542f27a26ae655d6609bfcf18b7af494846d6a3ba346d5e8693faa460a355e4e
tests/EpinelPS.SelectedManager.Tests/RoutePolicyFixture.cs	2453	6f685be3a309005742197139ed93fc4c6d8d779cb841aa4b58308fd71cec5002
tests/EpinelPS.SelectedManager.Tests/RoutePolicyRedTests.cs	5779	b95e4a23ba63d36a162e27149218695d499fac4a3aa0634d1be5e032089f8e2d
tests/EpinelPS.SelectedManager.Tests/SelectionPersistenceTests.cs	13828	ba7ca00dbf59b278753d79b476b16488260e86516492ce708d0fd19100f2744c
tests/EpinelPS.SelectedManager.Tests/SoloRaidRetrySemanticsTests.cs	13003	c5732996bef661bae561d8cabf84ed75b840e812871935fd38598acdea57f08b
tests/EpinelPS.SelectedManager.Tests/TrialPracticeWireOrderCharacterizationTests.cs	31112	9c4fe48c5c3826217b30e78ae0a109703893e959dc9dd3e8da05f5659e37902e
tests/EpinelPS.SelectedManager.Tests/WireShapeCharacterizationTests.cs	8109	a0fac6c1f2211905fa4076e88e5f3cf96c68e65da39b178bac9c604c25089be8
tests/EpinelPS.SelectedManager.Tests/SoloRaidDamageSourceObservationTests.cs	3986	30bd58c500fd8fb4d7fae09de2366f3d295dbd0f858fd863ff37e50d9413b049
'@.Replace("`r`n", "`n")

$sourceRows = @($sourceManifestText.TrimEnd("`n") -split "`n")
foreach ($row in $sourceRows) {
    $parts = $row -split "`t"
    Assert-True ($parts.Count -eq 3) `
        'phase3b2_damage_source_observer_v8_source_manifest_shape_invalid'
    $path = Join-Path $externalRoot ($parts[0].Replace('/', '\'))
    Assert-True (
        (Test-Path -LiteralPath $path -PathType Leaf) -and
        (Get-Item -LiteralPath $path).Length -eq [long]$parts[1] -and
        (Get-Sha256Hex $path) -ceq $parts[2]
    ) ('phase3b2_damage_source_observer_v8_source_drift:' + $parts[0])
}
$sourceManifestText += "`n"
Assert-True (
    (Get-BytesSha256Hex ([Text.UTF8Encoding]::new($false).GetBytes(
                $sourceManifestText))) -ceq $expectedSourceManifestSha256
) 'phase3b2_damage_source_observer_v8_source_manifest_digest_invalid'

$requiredPaths = @(
    $DotnetPath,
    (Join-Path $parentRuntimeRoot 'db.json'),
    (Join-Path $parentRuntimeRoot 'EpinelPS.exe'),
    (Join-Path $parentRuntimeRoot 'EpinelPS.dll'),
    (Join-Path $parentRuntimeRoot 'log4net.config'),
    $candidateDllPath
) + @($parentToolPaths.Values) + $sentinelPaths
Assert-True (@($requiredPaths | Where-Object {
            -not (Test-Path -LiteralPath $_ -PathType Leaf)
        }).Count -eq 0) 'phase3b2_damage_source_observer_v8_input_missing'
Assert-True (
    @(Get-Process EpinelPS, nikke, NikkeLocalLab.Phase3B2.PhysicalBootstrap `
        -ErrorAction SilentlyContinue).Count -eq 0 -and
    -not (Test-Path -LiteralPath (Join-Path $parentEvidenceRoot `
                'active-run.pointer.json'))
) 'phase3b2_damage_source_observer_v8_parent_run_not_completed'

Assert-True (
    (Get-Sha256Hex (Join-Path $parentRuntimeRoot 'db.json')) -ceq
        $expectedDatabaseSha256 -and
    (Get-Sha256Hex (Join-Path $parentRuntimeRoot 'EpinelPS.exe')) -ceq
        $expectedServerExeSha256 -and
    (Get-Sha256Hex (Join-Path $parentRuntimeRoot 'EpinelPS.dll')) -ceq
        $expectedParentDllSha256 -and
    (Get-Sha256Hex (Join-Path $parentRuntimeRoot 'log4net.config')) -ceq
        $expectedLogConfigSha256
) 'phase3b2_damage_source_observer_v8_parent_runtime_drift'
foreach ($role in $parentToolPaths.Keys) {
    Assert-True (
        (Get-Sha256Hex $parentToolPaths[$role]) -ceq
            $expectedParentToolHashes[$role]
    ) ('phase3b2_damage_source_observer_v8_parent_tool_drift:' + $role)
}
$parentCache = Get-Item -LiteralPath (Join-Path $parentRuntimeRoot 'cache') `
    -Force -ErrorAction SilentlyContinue
Assert-True (
    $null -ne $parentCache -and $parentCache.LinkType -ceq 'Junction' -and
    [string]$parentCache.Target -ceq $bootCacheTarget
) 'phase3b2_damage_source_observer_v8_parent_cache_invalid'
for ($index = 0; $index -lt $sentinelPaths.Count; $index++) {
    Assert-True (
        (Get-Sha256Hex $sentinelPaths[$index]) -ceq
            $expectedSentinelHashes[$index]
    ) ('phase3b2_damage_source_observer_v8_sentinel_drift:' + $index)
}
Assert-True (
    (Get-Item -LiteralPath $candidateDllPath).Length -eq
        $candidateDllByteLength -and
    (Get-Sha256Hex $candidateDllPath) -ceq $candidateDllSha256
) 'phase3b2_damage_source_observer_v8_candidate_dll_drift'

$parentFingerprintBefore = Get-CriticalFingerprint `
    -RuntimeRoot $parentRuntimeRoot -ToolPaths $parentToolPaths `
    -SentinelPaths $sentinelPaths

Push-Location $externalRoot
try {
    $dotnetSdkVersion = (& $DotnetPath --version 2>&1 | Out-String).Trim()
    $testOutput = (& $DotnetPath test `
        'tests\EpinelPS.SelectedManager.Tests\EpinelPS.SelectedManager.Tests.csproj' `
        --no-restore --configuration Release `
        '-p:IncludeSourceRevisionInInformationalVersion=false' `
        2>&1 | Out-String).Trim()
    $testExitCode = $LASTEXITCODE
}
finally {
    Pop-Location
}
Assert-True ($dotnetSdkVersion -match '^10\.') `
    'phase3b2_damage_source_observer_v8_dotnet_sdk_unsupported'
Assert-True ($testExitCode -eq 0 -and $testOutput -match '108') `
    'phase3b2_damage_source_observer_v8_selected_manager_tests_failed'
Assert-True (
    (Get-Item -LiteralPath $candidateDllPath).Length -eq
        $candidateDllByteLength -and
    (Get-Sha256Hex $candidateDllPath) -ceq $candidateDllSha256
) 'phase3b2_damage_source_observer_v8_post_test_dll_drift'

$audit = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-epinel-solo-raid-damage-source-observer-audit/v8'
    auditedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    parentLaneCode = 'epinel_solo_raid_score_consistency_v7'
    sourceManifestMemberCount = $sourceRows.Count
    sourceManifestSha256 = $expectedSourceManifestSha256
    selectedManagerPassedCount = 108
    selectedManagerFailedCount = 0
    dotnetSdkVersion = $dotnetSdkVersion
    candidateServerDllByteLength = $candidateDllByteLength
    candidateServerDllSha256 = $candidateDllSha256
    parentFingerprintSha256 = $parentFingerprintBefore
    observationCode = 'aggregate_only_raw_actual_damage_candidates'
    requestPayloadPersisted = $false
    serverBehaviorChanged = $false
    parentV7ReadOnly = $true
    micronGoldenReadOnly = $true
    dGoldenReadOnly = $true
    deployable = $true
}
if ($AuditOnly) {
    [pscustomobject]@{ Audit = $audit; TestOutput = $testOutput } |
        ConvertTo-Json -Depth 10
    return
}

Assert-True (
    -not (Test-Path -LiteralPath $targetRuntimeRoot) -and
    -not (Test-Path -LiteralPath $targetEvidenceRoot) -and
    -not (Test-Path -LiteralPath $targetDeploymentRoot) -and
    @($targetToolNames.Values | Where-Object {
            Test-Path -LiteralPath (Join-Path $toolRoot $_)
        }).Count -eq 0
) 'phase3b2_damage_source_observer_v8_target_collision'

$deploymentUid = [Guid]::NewGuid().ToString('D')
$runtimeStagingRoot = $targetRuntimeRoot + '.staging-' +
    [Guid]::NewGuid().ToString('N')
$deploymentStagingRoot = $targetDeploymentRoot + '.staging-' +
    [Guid]::NewGuid().ToString('N')
$toolStagingRoot = Join-Path $env:TEMP `
    ('NLL-Phase3B2-DamageSourceObserver-v8-' + [Guid]::NewGuid().ToString('N'))
$protectedRoot = Join-Path $protectedBase $deploymentUid
$runtimeCommitted = $false
$evidenceRootCreated = $false
$deploymentCommitted = $false
$protectedRootCreated = $false
$installedTargetToolPaths = [Collections.Generic.List[string]]::new()

try {
    New-Item -ItemType Directory -Path $runtimeStagingRoot | Out-Null
    foreach ($entry in @(Get-ChildItem -LiteralPath $parentRuntimeRoot -Force)) {
        if ($entry.Name -in @('cache', 'logs', 'EpinelPS.dll')) { continue }
        Copy-Item -LiteralPath $entry.FullName -Destination `
            $runtimeStagingRoot -Recurse
    }
    Copy-Item -LiteralPath $candidateDllPath -Destination `
        (Join-Path $runtimeStagingRoot 'EpinelPS.dll')
    New-Item -ItemType Directory -Path (Join-Path $runtimeStagingRoot 'logs') |
        Out-Null
    New-ExactJunction -Path (Join-Path $runtimeStagingRoot 'cache') `
        -Target $bootCacheTarget `
        -FailureCode 'phase3b2_damage_source_observer_v8_cache_link_failed'

    New-Item -ItemType Directory -Path $toolStagingRoot | Out-Null
    $replacements = [ordered]@{
        'EpinelPS-SoloRaidScoreConsistency-v7' =
            'EpinelPS-SoloRaidDamageSourceObserver-v8'
        'P3SRSC7' = 'P3SRDSO8'
        'SoloRaidScoreConsistency-v7' = 'SoloRaidDamageSourceObserver-v8'
        'solo-raid-score-consistency-v7' =
            'solo-raid-damage-source-observer-v8'
        'solo-raid-score-consistency-start/v7' =
            'solo-raid-damage-source-observer-start/v8'
        'solo-raid-score-consistency-failure/v7' =
            'solo-raid-damage-source-observer-failure/v8'
        'solo-raid-score-consistency-completion/v7' =
            'solo-raid-damage-source-observer-completion/v8'
        'solo-raid-score-consistency-validation/v7' =
            'solo-raid-damage-source-observer-validation/v8'
        'solo-raid-score-consistency-marker-evidence/v7' =
            'solo-raid-damage-source-observer-marker-evidence/v8'
        'score_consistency_v7' = 'damage_source_observer_v8'
        'phase3b2_score_consistency_v7' =
            'phase3b2_damage_source_observer_v8'
        '15383552L' = '15392256L'
        $expectedParentDllSha256 = $candidateDllSha256
        'caf873d9b353a4879ab4ef4ace596d478d3c3b6c65b3e33103d400b66d7ef4dd' =
            $expectedSourceManifestSha256
    }
    $stagedToolPaths = [ordered]@{}
    foreach ($role in $parentToolPaths.Keys) {
        $text = Get-DerivedToolText -Path $parentToolPaths[$role] `
            -Replacements $replacements
        Assert-True (
            -not $text.Contains('SoloRaidScoreConsistency-v7') -and
            -not $text.Contains('solo-raid-score-consistency') -and
            -not $text.Contains('P3SRSC7')
        ) ('phase3b2_damage_source_observer_v8_parent_reference_retained:' + $role)
        $path = Join-Path $toolStagingRoot $targetToolNames[$role]
        Write-Utf8NoBom $path $text
        $stagedToolPaths[$role] = $path
    }

    $innerCompletionPath = [string]$stagedToolPaths.innerCompletion
    $innerCompletionText = Get-Content -LiteralPath $innerCompletionPath `
        -Raw -Encoding UTF8
    $damageSourceParser = @'
    $damageSourceObservations = @()
    $damageSourcePattern =
        'NLL_SOLO_RAID_DAMAGE_SOURCE_OBSERVATION/v1\s+' +
        'utc=(?<utc>\S+)\s+sequence=(?<sequence>\d+)\s+' +
        'route=soloraid_trial_setdamage\s+' +
        'battleResult=(?<battleResult>-?\d+)\s+' +
        'requestDamage=(?<requestDamage>\d+)\s+' +
        'characterCount=(?<characterCount>\d+)\s+' +
        'characterAttackDamage=(?<characterAttackDamage>\d+)\s+' +
        'characterAttackActualDamage=(?<characterAttackActualDamage>\d+)\s+' +
        'characterSkillDamage=(?<characterSkillDamage>\d+)\s+' +
        'characterSkillActualDamage=(?<characterSkillActualDamage>\d+)\s+' +
        'characterStatFunctionDamage=(?<characterStatFunctionDamage>\d+)\s+' +
        'characterStatFunctionActualDamage=(?<characterStatFunctionActualDamage>\d+)\s+' +
        'monsterCount=(?<monsterCount>\d+)\s+' +
        'monsterHpDamageReceived=(?<monsterHpDamageReceived>\d+)\s+' +
        'monsterHpActualDamageReceived=(?<monsterHpActualDamageReceived>\d+)\s+' +
        'monsterPartsDamageReceived=(?<monsterPartsDamageReceived>\d+)\s+' +
        'monsterProjectileDamageReceived=(?<monsterProjectileDamageReceived>\d+)\s+' +
        'reportDataByteLength=(?<reportDataByteLength>\d+)'
    foreach ($match in [regex]::Matches($appLogText, $damageSourcePattern)) {
        $damageSourceObservations += [ordered]@{
            utc = [string]$match.Groups['utc'].Value
            sequence = [long]$match.Groups['sequence'].Value
            battleResult = [int]$match.Groups['battleResult'].Value
            requestDamage = [long]$match.Groups['requestDamage'].Value
            characterCount = [int]$match.Groups['characterCount'].Value
            characterAttackDamage = [long]$match.Groups['characterAttackDamage'].Value
            characterAttackActualDamage = [long]$match.Groups['characterAttackActualDamage'].Value
            characterSkillDamage = [long]$match.Groups['characterSkillDamage'].Value
            characterSkillActualDamage = [long]$match.Groups['characterSkillActualDamage'].Value
            characterStatFunctionDamage = [long]$match.Groups['characterStatFunctionDamage'].Value
            characterStatFunctionActualDamage = [long]$match.Groups['characterStatFunctionActualDamage'].Value
            monsterCount = [int]$match.Groups['monsterCount'].Value
            monsterHpDamageReceived = [long]$match.Groups['monsterHpDamageReceived'].Value
            monsterHpActualDamageReceived = [long]$match.Groups['monsterHpActualDamageReceived'].Value
            monsterPartsDamageReceived = [long]$match.Groups['monsterPartsDamageReceived'].Value
            monsterProjectileDamageReceived = [long]$match.Groups['monsterProjectileDamageReceived'].Value
            reportDataByteLength = [int]$match.Groups['reportDataByteLength'].Value
        }
    }

'@
    $innerCompletionText = Replace-ExactlyOnce `
        -Text $innerCompletionText `
        -Before '    $markerEvidence = [ordered]@{' `
        -After ($damageSourceParser + '    $markerEvidence = [ordered]@{') `
        -FailureCode 'phase3b2_damage_source_observer_v8_parser_shape_invalid'
    $innerCompletionText = Replace-ExactlyOnce `
        -Text $innerCompletionText `
        -Before '        scoreObservations = $scoreObservations' `
        -After @'
        scoreObservations = $scoreObservations
        damageSourceObservationCount = $damageSourceObservations.Count
        damageSourceObservations = $damageSourceObservations
'@ `
        -FailureCode 'phase3b2_damage_source_observer_v8_marker_shape_invalid'
    $innerCompletionText = Replace-ExactlyOnce `
        -Text $innerCompletionText `
        -Before '    $scoreObservations = @($markerEvidence.scoreObservations)' `
        -After @'
    $scoreObservations = @($markerEvidence.scoreObservations)
    $damageSourceObservations = @($markerEvidence.damageSourceObservations)
'@ `
        -FailureCode 'phase3b2_damage_source_observer_v8_partial_shape_invalid'

    $damageSourceVerification = @'
function Get-DamageSourceSum {
    param([object[]]$Rows, [string]$Property)
    [long]$sum = 0
    foreach ($row in @($Rows)) {
        if ($row -is [Collections.IDictionary]) {
            Assert-True $row.Contains($Property) `
                ('phase3b2_damage_source_observer_v8_property_missing:' +
                    $Property)
            $value = $row[$Property]
        }
        else {
            $propertyValue = $row.PSObject.Properties[$Property]
            Assert-True ($null -ne $propertyValue) `
                ('phase3b2_damage_source_observer_v8_property_missing:' +
                    $Property)
            $value = $propertyValue.Value
        }
        $sum += [long]$value
    }
    return $sum
}
$completedDamageSources = @($damageSourceObservations | Where-Object {
        [int]$_.battleResult -eq 1
    } | Sort-Object { [long]$_.sequence })
$damageSourceSums = [ordered]@{
    requestDamage = Get-DamageSourceSum $completedDamageSources 'requestDamage'
    characterAttackDamage = Get-DamageSourceSum $completedDamageSources 'characterAttackDamage'
    characterAttackActualDamage = Get-DamageSourceSum $completedDamageSources 'characterAttackActualDamage'
    characterSkillDamage = Get-DamageSourceSum $completedDamageSources 'characterSkillDamage'
    characterSkillActualDamage = Get-DamageSourceSum $completedDamageSources 'characterSkillActualDamage'
    characterStatFunctionDamage = Get-DamageSourceSum $completedDamageSources 'characterStatFunctionDamage'
    characterStatFunctionActualDamage = Get-DamageSourceSum $completedDamageSources 'characterStatFunctionActualDamage'
    monsterHpDamageReceived = Get-DamageSourceSum $completedDamageSources 'monsterHpDamageReceived'
    monsterHpActualDamageReceived = Get-DamageSourceSum $completedDamageSources 'monsterHpActualDamageReceived'
    monsterPartsDamageReceived = Get-DamageSourceSum $completedDamageSources 'monsterPartsDamageReceived'
    monsterProjectileDamageReceived = Get-DamageSourceSum $completedDamageSources 'monsterProjectileDamageReceived'
}
$damageSourceObservationComplete = $completedDamageSources.Count -eq 5 -and
    [long]$damageSourceSums.requestDamage -eq $authoritativeScore
$damageSourceObservationRequired = $OutcomeCode -ceq 'success' -and
    $ObservedStageCode -ceq 'battle_result'
if ($damageSourceObservationRequired) {
    Assert-True $damageSourceObservationComplete `
        'phase3b2_damage_source_observer_v8_observation_incomplete'
}

'@
    $innerCompletionText = Replace-ExactlyOnce `
        -Text $innerCompletionText `
        -Before '$databaseAfterByteLength = (Get-Item -LiteralPath $dbPath).Length' `
        -After ($damageSourceVerification +
            '$databaseAfterByteLength = (Get-Item -LiteralPath $dbPath).Length') `
        -FailureCode 'phase3b2_damage_source_observer_v8_verification_shape_invalid'
    $innerCompletionText = Replace-ExactlyOnce `
        -Text $innerCompletionText `
        -Before '    scoreProjectionVerified = $scoreProjectionVerified' `
        -After @'
    scoreProjectionVerified = $scoreProjectionVerified
    damageSourceObservationCount = $damageSourceObservations.Count
    completedDamageSourceObservationCount = $completedDamageSources.Count
    damageSourceObservationRequired = $damageSourceObservationRequired
    damageSourceObservationComplete = $damageSourceObservationComplete
    damageSourceSums = $damageSourceSums
    rawDamageRequestPayloadPersisted = $false
'@ `
        -FailureCode 'phase3b2_damage_source_observer_v8_receipt_shape_invalid'
    Write-Utf8NoBom $innerCompletionPath $innerCompletionText

    foreach ($role in $stagedToolPaths.Keys) {
        Assert-PowerShellSyntax -Path ([string]$stagedToolPaths[$role]) `
            -FailureCode ('phase3b2_damage_source_observer_v8_tool_syntax:' + $role)
    }

    $derivedTools = @()
    foreach ($role in $stagedToolPaths.Keys) {
        $path = [string]$stagedToolPaths[$role]
        $derivedTools += [ordered]@{
            roleCode = $role
            leaf = Split-Path -Leaf $path
            byteLength = (Get-Item -LiteralPath $path).Length
            sha256 = Get-Sha256Hex $path
        }
    }

    New-Item -ItemType Directory -Path $deploymentStagingRoot | Out-Null
    Write-Utf8NoBom (Join-Path $deploymentStagingRoot 'source.manifest.tsv') `
        $sourceManifestText
    Write-AtomicJson (Join-Path $deploymentStagingRoot 'audit.receipt.json') $audit

    Move-Item -LiteralPath $runtimeStagingRoot -Destination $targetRuntimeRoot
    $runtimeCommitted = $true
    New-Item -ItemType Directory -Path $targetEvidenceRoot | Out-Null
    $evidenceRootCreated = $true
    foreach ($role in $stagedToolPaths.Keys) {
        $targetToolPath = Join-Path $toolRoot $targetToolNames[$role]
        Move-Item -LiteralPath ([string]$stagedToolPaths[$role]) `
            -Destination $targetToolPath
        $installedTargetToolPaths.Add($targetToolPath)
    }
    Move-Item -LiteralPath $deploymentStagingRoot `
        -Destination $targetDeploymentRoot
    $deploymentCommitted = $true

    $targetToolPaths = [ordered]@{}
    foreach ($role in $targetToolNames.Keys) {
        $targetToolPaths[$role] = Join-Path $toolRoot $targetToolNames[$role]
    }
    $targetCache = Get-Item -LiteralPath (Join-Path $targetRuntimeRoot 'cache') `
        -Force
    Assert-True (
        (Get-Sha256Hex (Join-Path $targetRuntimeRoot 'db.json')) -ceq
            $expectedDatabaseSha256 -and
        (Get-Sha256Hex (Join-Path $targetRuntimeRoot 'EpinelPS.dll')) -ceq
            $candidateDllSha256 -and
        $targetCache.LinkType -ceq 'Junction' -and
        [string]$targetCache.Target -ceq $bootCacheTarget -and
        @($targetToolPaths.Values | Where-Object {
                -not (Test-Path -LiteralPath $_ -PathType Leaf)
            }).Count -eq 0
    ) 'phase3b2_damage_source_observer_v8_post_deploy_invalid'

    $parentFingerprintAfter = Get-CriticalFingerprint `
        -RuntimeRoot $parentRuntimeRoot -ToolPaths $parentToolPaths `
        -SentinelPaths $sentinelPaths
    Assert-True ($parentFingerprintAfter -ceq $parentFingerprintBefore) `
        'phase3b2_damage_source_observer_v8_parent_mutated'

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-solo-raid-damage-source-observer-deployment/v8'
        deployedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        deploymentUid = $deploymentUid
        parentLaneCode = 'epinel_solo_raid_score_consistency_v7'
        derivedLaneCode = 'epinel_solo_raid_damage_source_observer_v8'
        parentFingerprintSha256 = $parentFingerprintBefore
        sourceManifestMemberCount = $sourceRows.Count
        sourceManifestSha256 = $expectedSourceManifestSha256
        parentServerDllSha256 = $expectedParentDllSha256
        appliedServerDllByteLength = $candidateDllByteLength
        appliedServerDllSha256 = $candidateDllSha256
        selectedManagerPassedCount = 108
        selectedManagerFailedCount = 0
        observationCode = 'aggregate_only_raw_actual_damage_candidates'
        candidateAggregateCount = 11
        requestPayloadPersisted = $false
        responseSemanticsChanged = $false
        v7ParentModified = $false
        micronLobbyGoldenModified = $false
        dLobbyGoldenModified = $false
        databaseModified = $false
        cacheModified = $false
        installedTools = $derivedTools
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        validationRunConsumed = $false
        rollbackCode = 'leave_v8_inert_and_select_untouched_v7'
        nextStepCode =
            'boot_micron_run_one_five_deck_damage_source_observation'
    }
    $receiptPath = Join-Path $targetDeploymentRoot 'deployment.receipt.json'
    Write-AtomicJson $receiptPath $receipt
    New-Item -ItemType Directory -Path $protectedRoot | Out-Null
    $protectedRootCreated = $true
    Copy-Item -LiteralPath $receiptPath -Destination `
        (Join-Path $protectedRoot 'deployment.receipt.json')
    Copy-Item -LiteralPath (Join-Path $targetDeploymentRoot `
            'source.manifest.tsv') -Destination `
        (Join-Path $protectedRoot 'source.manifest.tsv')

    [pscustomobject]@{
        Receipt = $receipt
        MicronReceiptPath = $receiptPath
        MicronReceiptByteLength = (Get-Item -LiteralPath $receiptPath).Length
        MicronReceiptSha256 = Get-Sha256Hex $receiptPath
        ProtectedReceiptPath = Join-Path $protectedRoot `
            'deployment.receipt.json'
        MicronStartCommand =
            "& 'C:\NLL\Tools\Start-Phase3B2-Epinel-SoloRaidDamageSourceObserver-v8.ps1' -ValidationKind Challenge"
        MicronCompletionCommand =
            "& 'C:\NLL\Tools\Complete-Phase3B2-Epinel-SoloRaidDamageSourceObserver-v8.ps1' -ObservedStageCode battle_result -OutcomeCode success"
    } | ConvertTo-Json -Depth 14
}
catch {
    foreach ($path in @($installedTargetToolPaths)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force
        }
    }
    foreach ($committedTarget in @(
            [pscustomobject]@{
                Committed = $deploymentCommitted
                Path = $targetDeploymentRoot
            },
            [pscustomobject]@{
                Committed = $evidenceRootCreated
                Path = $targetEvidenceRoot
            },
            [pscustomobject]@{
                Committed = $runtimeCommitted
                Path = $targetRuntimeRoot
            },
            [pscustomobject]@{
                Committed = $protectedRootCreated
                Path = $protectedRoot
            }
        )) {
        if ($committedTarget.Committed -and
            (Test-Path -LiteralPath $committedTarget.Path)) {
            Remove-Item -LiteralPath $committedTarget.Path -Recurse -Force
        }
    }
    foreach ($path in @($runtimeStagingRoot, $deploymentStagingRoot, $toolStagingRoot)) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force
        }
    }
    throw
}
finally {
    if (Test-Path -LiteralPath $toolStagingRoot) {
        Remove-Item -LiteralPath $toolStagingRoot -Recurse -Force
    }
}
