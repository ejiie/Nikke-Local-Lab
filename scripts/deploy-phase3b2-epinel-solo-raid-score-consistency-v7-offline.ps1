#requires -Version 5.1

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Z]$')]
    [string]$MicronDriveLetter = 'E',
    [string]$DotnetPath = 'E:\Program Files\dotnet\dotnet.exe',
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
    'phase3b2_score_consistency_v7_requires_administrator'
Assert-True ($env:SystemDrive -ceq 'C:' -and $env:USERNAME -ceq 'zih44') `
    'phase3b2_score_consistency_v7_wrong_samsung_boundary'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$externalRoot = Join-Path $repositoryRoot '.external\EpinelPS'
$micronDrive = $MicronDriveLetter + ':'
$toolRoot = Join-Path $micronDrive 'NLL\Tools'
$parentRuntimeRoot = Join-Path $micronDrive `
    'NLL\Runtime\EpinelPS-SoloRaidScoreRanking-v6'
$parentEvidenceRoot = Join-Path $micronDrive 'NLL\E\P3SRSR6'
$targetRuntimeRoot = Join-Path $micronDrive `
    'NLL\Runtime\EpinelPS-SoloRaidScoreConsistency-v7'
$targetEvidenceRoot = Join-Path $micronDrive 'NLL\E\P3SRSC7'
$targetDeploymentRoot = Join-Path $micronDrive 'NLL\E\P3SRSC7D'
$candidateDllPath = Join-Path $externalRoot `
    'EpinelPS\bin\Release\net10.0\win-x64\EpinelPS.dll'
$bootCacheTarget =
    'C:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\cache'
$protectedBase =
    'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\EpinelSoloRaidScoreConsistency-v7'

$parentToolNames = [ordered]@{
    outerStart = 'Start-Phase3B2-Epinel-SoloRaidScoreRanking-v6.ps1'
    innerStart = 'start-phase3b2-epinel-solo-raid-score-ranking-v6-in-micron.ps1'
    outerCompletion = 'Complete-Phase3B2-Epinel-SoloRaidScoreRanking-v6.ps1'
    innerCompletion = 'complete-phase3b2-epinel-solo-raid-score-ranking-v6-in-micron.ps1'
}
$targetToolNames = [ordered]@{
    outerStart = 'Start-Phase3B2-Epinel-SoloRaidScoreConsistency-v7.ps1'
    innerStart = 'start-phase3b2-epinel-solo-raid-score-consistency-v7-in-micron.ps1'
    outerCompletion = 'Complete-Phase3B2-Epinel-SoloRaidScoreConsistency-v7.ps1'
    innerCompletion = 'complete-phase3b2-epinel-solo-raid-score-consistency-v7-in-micron.ps1'
}
$parentToolPaths = [ordered]@{}
foreach ($role in $parentToolNames.Keys) {
    $parentToolPaths[$role] = Join-Path $toolRoot $parentToolNames[$role]
}
$expectedParentToolHashes = [ordered]@{
    outerStart = 'e14803076b8e14c6bb6b6daf729d334a19d17b8180962bac6f87ae3c617923a0'
    innerStart = '177971e583f659dfcf746bb474cb0219ead8a571ef69de0b1fe6599a45c0fd85'
    outerCompletion = '4157074c7713eee31e48619eeace4b8e1011ee4b7dba65d3d7d5f2642f785839'
    innerCompletion = '3b3acd7fbbe5aeca32ecc39f91f9a4a0f356ede44a2488eee5f3fc0d0f5fd6e7'
}
$expectedDatabaseSha256 =
    'dee9c6aa5421287ca030e325b81a90a302a5d9e113d57c3065e5d36f6e7c4019'
$expectedServerExeSha256 =
    'a28c7ff227a74d260a29389b82caeed3fe196f91eef3d28cabe9977b5ed9d07b'
$expectedParentDllSha256 =
    'f9bb3696e8e2b550cebf01bd0065c3757cc9eb2fb064d93b000885f13fa0dba2'
$expectedLogConfigSha256 =
    '31b873b3ad156436f0a55f54f1518fde9e2e6c0059cca3ec2e3b181c08c448b9'
$candidateDllByteLength = 15383552L
$candidateDllSha256 =
    '39949e0d490d5d4996cd26fb1cd6a990ff57c20bfd99676c14878b9dba4e0a39'
$expectedSourceManifestSha256 =
    'caf873d9b353a4879ab4ef4ace596d478d3c3b6c65b3e33103d400b66d7ef4dd'

$micronGoldenReceipt = Join-Path $micronDrive `
    'NLL\Evidence\Phase3B2\Physical\epinel-lobby-golden-baseline-v1\15089f3e-92f2-4833-ab1b-348d1463f9fc\golden-baseline.receipt.json'
$micronGoldenManifest = Join-Path $micronDrive `
    'NLL\Backups\Phase3B2\EpinelLobbyGoldenBaseline-v1\15089f3e-92f2-4833-ab1b-348d1463f9fc\artifact.manifest.json'
$dCheckpointRoot =
    'D:\NikkeLocalLab\Backups\phase3b2-season26-challenge-regroup-v5-checkpoint-v1\e40c70a0-16a3-4a83-9d30-b16f368ce73a'
$v6DeploymentRoot = Join-Path $micronDrive 'NLL\E\P3SRSR6D'
$sentinelPaths = @(
    $micronGoldenReceipt,
    $micronGoldenManifest,
    (Join-Path $dCheckpointRoot 'metadata\seal.receipt.json'),
    (Join-Path $dCheckpointRoot 'metadata\content.manifest.json'),
    (Join-Path $v6DeploymentRoot 'deployment.receipt.json'),
    (Join-Path $v6DeploymentRoot 'audit.receipt.json'),
    (Join-Path $v6DeploymentRoot 'source.manifest.tsv')
)
$expectedSentinelHashes = @(
    'ebf5c2f7692e7de7ec9b8bcf3acba112cdb8efbfbb888967acde7e429e877f9c',
    '25a3a7696c486098bedf5184c31d80380543c3ab4809467e71b0a4594c332be7',
    'e69ee9020abf5c77fc61f433ae56729d36c82c10289b385ee1bdde30604e3753',
    'bed4e1ba8a58b42d3ae8e4b1d5409c0966efc19d53f6ec87cd6d426252e82b59',
    '3aa96e0002c7661215c4d397f29e4137852d81e31a17353f584f22de75f63791',
    'c87166f049dffbe10c636301772250beb30d8aaa94a3d7cbe9b26819e4b9de2a',
    'ca72c8933e0cc7f3c037dbca042d78dcdb98cbd2201e569e6ae744d5080fb207'
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
EpinelPS/LobbyServer/Soloraid/SetDamageTrial.cs	1186	af91244bf7194609434622dfe8345e98ac3cac950f05cba514891eb5a731858d
EpinelPS/LobbyServer/Soloraid/SoloRaidHelper.cs	34328	0b89ff0c06881c6c2e86896e5d67577437a91a64ff7d30d235f5682a70752f9a
EpinelPS/SoloRaidSelection/SoloRaidManagerSelectionResolver.cs	5962	995c084ad7eb3ea1102375ffd307acce9ad614eba35c2045aa0750d934126991
tests/EpinelPS.SelectedManager.Tests/BaselineRouteAuditTests.cs	3581	3cd4992411140f28796abd2703b7744149c8e59a839373dd445731db8c46f6aa
tests/EpinelPS.SelectedManager.Tests/ClassicSoloRaidPeriodProviderTests.cs	5305	542f27a26ae655d6609bfcf18b7af494846d6a3ba346d5e8693faa460a355e4e
tests/EpinelPS.SelectedManager.Tests/RoutePolicyFixture.cs	2453	6f685be3a309005742197139ed93fc4c6d8d779cb841aa4b58308fd71cec5002
tests/EpinelPS.SelectedManager.Tests/RoutePolicyRedTests.cs	5779	b95e4a23ba63d36a162e27149218695d499fac4a3aa0634d1be5e032089f8e2d
tests/EpinelPS.SelectedManager.Tests/SelectionPersistenceTests.cs	13828	ba7ca00dbf59b278753d79b476b16488260e86516492ce708d0fd19100f2744c
tests/EpinelPS.SelectedManager.Tests/SoloRaidRetrySemanticsTests.cs	13003	c5732996bef661bae561d8cabf84ed75b840e812871935fd38598acdea57f08b
tests/EpinelPS.SelectedManager.Tests/TrialPracticeWireOrderCharacterizationTests.cs	31112	9c4fe48c5c3826217b30e78ae0a109703893e959dc9dd3e8da05f5659e37902e
tests/EpinelPS.SelectedManager.Tests/WireShapeCharacterizationTests.cs	8109	a0fac6c1f2211905fa4076e88e5f3cf96c68e65da39b178bac9c604c25089be8
'@.Replace("`r`n", "`n")

$sourceRows = @($sourceManifestText.TrimEnd("`n") -split "`n")
foreach ($row in $sourceRows) {
    $parts = $row -split "`t"
    Assert-True ($parts.Count -eq 3) `
        'phase3b2_score_consistency_v7_source_manifest_shape_invalid'
    $path = Join-Path $externalRoot ($parts[0].Replace('/', '\'))
    Assert-True (
        (Test-Path -LiteralPath $path -PathType Leaf) -and
        (Get-Item -LiteralPath $path).Length -eq [long]$parts[1] -and
        (Get-Sha256Hex $path) -ceq $parts[2]
    ) ('phase3b2_score_consistency_v7_source_drift:' + $parts[0])
}
$sourceManifestText += "`n"
Assert-True (
    (Get-BytesSha256Hex ([Text.UTF8Encoding]::new($false).GetBytes(
                $sourceManifestText))) -ceq $expectedSourceManifestSha256
) 'phase3b2_score_consistency_v7_source_manifest_digest_invalid'

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
        }).Count -eq 0) 'phase3b2_score_consistency_v7_input_missing'
Assert-True (
    @(Get-Process EpinelPS, nikke, NikkeLocalLab.Phase3B2.PhysicalBootstrap `
        -ErrorAction SilentlyContinue).Count -eq 0 -and
    -not (Test-Path -LiteralPath (Join-Path $parentEvidenceRoot `
                'active-run.pointer.json'))
) 'phase3b2_score_consistency_v7_runtime_not_cold'

Assert-True (
    (Get-Sha256Hex (Join-Path $parentRuntimeRoot 'db.json')) -ceq
        $expectedDatabaseSha256 -and
    (Get-Sha256Hex (Join-Path $parentRuntimeRoot 'EpinelPS.exe')) -ceq
        $expectedServerExeSha256 -and
    (Get-Sha256Hex (Join-Path $parentRuntimeRoot 'EpinelPS.dll')) -ceq
        $expectedParentDllSha256 -and
    (Get-Sha256Hex (Join-Path $parentRuntimeRoot 'log4net.config')) -ceq
        $expectedLogConfigSha256
) 'phase3b2_score_consistency_v7_parent_runtime_drift'
foreach ($role in $parentToolPaths.Keys) {
    Assert-True (
        (Get-Sha256Hex $parentToolPaths[$role]) -ceq
            $expectedParentToolHashes[$role]
    ) ('phase3b2_score_consistency_v7_parent_tool_drift:' + $role)
}
$parentCache = Get-Item -LiteralPath (Join-Path $parentRuntimeRoot 'cache') `
    -Force -ErrorAction SilentlyContinue
Assert-True (
    $null -ne $parentCache -and $parentCache.LinkType -ceq 'Junction' -and
    [string]$parentCache.Target -ceq $bootCacheTarget
) 'phase3b2_score_consistency_v7_parent_cache_invalid'
for ($index = 0; $index -lt $sentinelPaths.Count; $index++) {
    Assert-True (
        (Get-Sha256Hex $sentinelPaths[$index]) -ceq
            $expectedSentinelHashes[$index]
    ) ('phase3b2_score_consistency_v7_sentinel_drift:' + $index)
}
Assert-True (
    (Get-Item -LiteralPath $candidateDllPath).Length -eq
        $candidateDllByteLength -and
    (Get-Sha256Hex $candidateDllPath) -ceq $candidateDllSha256
) 'phase3b2_score_consistency_v7_candidate_dll_drift'

$parentFingerprintBefore = Get-CriticalFingerprint `
    -RuntimeRoot $parentRuntimeRoot -ToolPaths $parentToolPaths `
    -SentinelPaths $sentinelPaths

Push-Location $externalRoot
try {
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
Assert-True ($testExitCode -eq 0 -and $testOutput -match '106') `
    'phase3b2_score_consistency_v7_selected_manager_tests_failed'
Assert-True (
    (Get-Item -LiteralPath $candidateDllPath).Length -eq
        $candidateDllByteLength -and
    (Get-Sha256Hex $candidateDllPath) -ceq $candidateDllSha256
) 'phase3b2_score_consistency_v7_post_test_dll_drift'

$audit = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-epinel-solo-raid-score-consistency-audit/v7'
    auditedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    parentLaneCode = 'epinel_solo_raid_score_ranking_v6'
    sourceManifestMemberCount = $sourceRows.Count
    sourceManifestSha256 = $expectedSourceManifestSha256
    selectedManagerPassedCount = 106
    selectedManagerFailedCount = 0
    candidateServerDllByteLength = $candidateDllByteLength
    candidateServerDllSha256 = $candidateDllSha256
    candidateBuildIdentityCode =
        'source_revision_excluded_from_informational_version'
    parentFingerprintSha256 = $parentFingerprintBefore
    parentRuntimeCold = $true
    v6ParentReadOnly = $true
    micronGoldenReadOnly = $true
    dGoldenReadOnly = $true
    scoreAuthorityCode = 'best_completed_challenge_five_deck_total_damage'
    setDamageRankingSummaryProjected = $true
    infoSummaryUsesSameAuthority = $true
    rankingSummaryUsesSameAuthority = $true
    rankerSquadDetailUsesSameAuthority = $true
    expectedLocalRank = 1
    expectedLocalUserCount = 1
    hardCodedHistoricalScore = $false
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
) 'phase3b2_score_consistency_v7_target_collision'

$deploymentUid = [Guid]::NewGuid().ToString('D')
$runtimeStagingRoot = $targetRuntimeRoot + '.staging-' +
    [Guid]::NewGuid().ToString('N')
$deploymentStagingRoot = $targetDeploymentRoot + '.staging-' +
    [Guid]::NewGuid().ToString('N')
$toolStagingRoot = Join-Path $env:TEMP `
    ('NLL-Phase3B2-ScoreConsistency-v7-' + [Guid]::NewGuid().ToString('N'))
$protectedRoot = Join-Path $protectedBase $deploymentUid

try {
    New-Item -ItemType Directory -Path $runtimeStagingRoot | Out-Null
    foreach ($entry in @(
            Get-ChildItem -LiteralPath $parentRuntimeRoot -Force
        )) {
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
        -FailureCode 'phase3b2_score_consistency_v7_cache_link_failed'

    New-Item -ItemType Directory -Path $toolStagingRoot | Out-Null
    $replacements = [ordered]@{
        'EpinelPS-SoloRaidScoreRanking-v6' =
            'EpinelPS-SoloRaidScoreConsistency-v7'
        'P3SRSR6' = 'P3SRSC7'
        'SoloRaidScoreRanking-v6' = 'SoloRaidScoreConsistency-v7'
        'solo-raid-score-ranking-v6' = 'solo-raid-score-consistency-v7'
        'solo-raid-score-ranking-start/v6' =
            'solo-raid-score-consistency-start/v7'
        'solo-raid-score-ranking-failure/v6' =
            'solo-raid-score-consistency-failure/v7'
        'solo-raid-score-ranking-completion/v6' =
            'solo-raid-score-consistency-completion/v7'
        'solo-raid-score-ranking-validation/v6' =
            'solo-raid-score-consistency-validation/v7'
        'solo-raid-score-ranking-marker-evidence/v6' =
            'solo-raid-score-consistency-marker-evidence/v7'
        'score_ranking_v6' = 'score_consistency_v7'
        'phase3b2_score_ranking_v6' = 'phase3b2_score_consistency_v7'
        '15382016L' = '15383552L'
        $expectedParentDllSha256 = $candidateDllSha256
        'ca72c8933e0cc7f3c037dbca042d78dcdb98cbd2201e569e6ae744d5080fb207' =
            $expectedSourceManifestSha256
    }
    $stagedToolPaths = [ordered]@{}
    foreach ($role in $parentToolPaths.Keys) {
        $text = Get-DerivedToolText -Path $parentToolPaths[$role] `
            -Replacements $replacements
        Assert-True (
            -not $text.Contains('SoloRaidScoreRanking-v6') -and
            -not $text.Contains('solo-raid-score-ranking-v6') -and
            -not $text.Contains('P3SRSR6')
        ) ('phase3b2_score_consistency_v7_parent_reference_retained:' + $role)
        $path = Join-Path $toolStagingRoot $targetToolNames[$role]
        Write-Utf8NoBom $path $text
        $stagedToolPaths[$role] = $path
    }

    $innerCompletionPath = [string]$stagedToolPaths.innerCompletion
    $innerCompletionText = Get-Content -LiteralPath $innerCompletionPath `
        -Raw -Encoding UTF8
    $scoreParser = @'
    $scoreObservations = @()
    $setDamageScorePattern =
        'NLL_SOLO_RAID_SCORE_RESPONSE/v1\s+' +
        'utc=(?<utc>\S+)\s+sequence=(?<sequence>\d+)\s+' +
        'route=soloraid_trial_setdamage\s+' +
        'battleResult=(?<battleResult>-?\d+)\s+' +
        'infoDamage=(?<infoDamage>\d+)\s+' +
        'userDamage=(?<userDamage>\d+)\s+' +
        'totalUserCount=(?<totalUserCount>\d+)'
    foreach ($match in [regex]::Matches($appLogText, $setDamageScorePattern)) {
        $scoreObservations += [ordered]@{
            utc = [string]$match.Groups['utc'].Value
            sequence = [long]$match.Groups['sequence'].Value
            route = 'soloraid_trial_setdamage'
            battleResult = [int]$match.Groups['battleResult'].Value
            infoDamage = [long]$match.Groups['infoDamage'].Value
            userDamage = [long]$match.Groups['userDamage'].Value
            totalUserCount = [int]$match.Groups['totalUserCount'].Value
        }
    }
    $getInfoScorePattern =
        'NLL_SOLO_RAID_SCORE_RESPONSE/v1\s+' +
        'utc=(?<utc>\S+)\s+route=soloraid_get\s+' +
        'trialDamage=(?<trialDamage>\d+)'
    foreach ($match in [regex]::Matches($appLogText, $getInfoScorePattern)) {
        $scoreObservations += [ordered]@{
            utc = [string]$match.Groups['utc'].Value
            sequence = 0L
            route = 'soloraid_get'
            trialDamage = [long]$match.Groups['trialDamage'].Value
        }
    }
    $rankingScorePattern =
        'NLL_SOLO_RAID_SCORE_RESPONSE/v1\s+' +
        'utc=(?<utc>\S+)\s+route=soloraid_getranking\s+' +
        'rankingDamage=(?<rankingDamage>\d+)\s+' +
        'userDamage=(?<userDamage>\d+)\s+' +
        'totalUserCount=(?<totalUserCount>\d+)'
    foreach ($match in [regex]::Matches($appLogText, $rankingScorePattern)) {
        $scoreObservations += [ordered]@{
            utc = [string]$match.Groups['utc'].Value
            sequence = 0L
            route = 'soloraid_getranking'
            rankingDamage = [long]$match.Groups['rankingDamage'].Value
            userDamage = [long]$match.Groups['userDamage'].Value
            totalUserCount = [int]$match.Groups['totalUserCount'].Value
        }
    }
    $rankerSquadScorePattern =
        'NLL_SOLO_RAID_SCORE_RESPONSE/v1\s+' +
        'utc=(?<utc>\S+)\s+route=soloraid_getrankersquad\s+' +
        'logCount=(?<logCount>\d+)\s+' +
        'logDamageSum=(?<logDamageSum>\d+)'
    foreach ($match in [regex]::Matches($appLogText, $rankerSquadScorePattern)) {
        $scoreObservations += [ordered]@{
            utc = [string]$match.Groups['utc'].Value
            sequence = 0L
            route = 'soloraid_getrankersquad'
            logCount = [int]$match.Groups['logCount'].Value
            logDamageSum = [long]$match.Groups['logDamageSum'].Value
        }
    }

'@
    $innerCompletionText = Replace-ExactlyOnce `
        -Text $innerCompletionText `
        -Before '    $markerEvidence = [ordered]@{' `
        -After ($scoreParser + '    $markerEvidence = [ordered]@{') `
        -FailureCode 'phase3b2_score_consistency_v7_score_parser_shape_invalid'
    $innerCompletionText = Replace-ExactlyOnce `
        -Text $innerCompletionText `
        -Before '        observations = $observations' `
        -After @'
        observations = $observations
        scoreObservationCount = $scoreObservations.Count
        scoreObservations = $scoreObservations
'@ `
        -FailureCode 'phase3b2_score_consistency_v7_marker_receipt_shape_invalid'
    $innerCompletionText = Replace-ExactlyOnce `
        -Text $innerCompletionText `
        -Before '    $observations = @($markerEvidence.observations)' `
        -After @'
    $observations = @($markerEvidence.observations)
    $scoreObservations = @($markerEvidence.scoreObservations)
'@ `
        -FailureCode 'phase3b2_score_consistency_v7_partial_completion_shape_invalid'

    $scoreVerificationBlock = @'
$authoritativeScore = [long]$trialMetricsAfter.totalDamage
$completedScoreResponses = @($scoreObservations | Where-Object {
        [string]$_.route -ceq 'soloraid_trial_setdamage' -and
        [int]$_.battleResult -eq 1
    } | Sort-Object { [long]$_.sequence })
$finalCompletedScoreResponse = if ($completedScoreResponses.Count -gt 0) {
    $completedScoreResponses[-1]
} else { $null }
$setDamageScoreConsistent = $null -ne $finalCompletedScoreResponse -and
    $authoritativeScore -gt 0 -and
    [long]$finalCompletedScoreResponse.infoDamage -eq $authoritativeScore -and
    [long]$finalCompletedScoreResponse.userDamage -eq $authoritativeScore -and
    [int]$finalCompletedScoreResponse.totalUserCount -eq 1
function ConvertTo-ScoreObservationUtc {
    param([object]$Value)
    if ($Value -is [DateTimeOffset]) { return [DateTimeOffset]$Value }
    if ($Value -is [DateTime]) { return [DateTimeOffset]$Value }
    return [DateTimeOffset]::Parse(
        [string]$Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
    )
}
$finalCompletedScoreUtc = if ($null -ne $finalCompletedScoreResponse) {
    ConvertTo-ScoreObservationUtc $finalCompletedScoreResponse.utc
} else { [DateTimeOffset]::MinValue }
$infoScoreResponses = @($scoreObservations | Where-Object {
        [string]$_.route -ceq 'soloraid_get' -and
        (ConvertTo-ScoreObservationUtc $_.utc) -ge $finalCompletedScoreUtc
    })
$infoScoreConsistent = $infoScoreResponses.Count -gt 0 -and
    @($infoScoreResponses | Where-Object {
        [long]$_.trialDamage -ne $authoritativeScore
    }).Count -eq 0
$rankingScoreResponses = @($scoreObservations | Where-Object {
        [string]$_.route -ceq 'soloraid_getranking' -and
        (ConvertTo-ScoreObservationUtc $_.utc) -ge $finalCompletedScoreUtc
    })
$rankingScoreConsistent = $rankingScoreResponses.Count -gt 0 -and
    @($rankingScoreResponses | Where-Object {
        [long]$_.rankingDamage -ne $authoritativeScore -or
        [long]$_.userDamage -ne $authoritativeScore -or
        [int]$_.totalUserCount -ne 1
    }).Count -eq 0
$rankerSquadScoreResponses = @($scoreObservations | Where-Object {
        [string]$_.route -ceq 'soloraid_getrankersquad' -and
        (ConvertTo-ScoreObservationUtc $_.utc) -ge $finalCompletedScoreUtc
    })
$rankerSquadScoreConsistent = $rankerSquadScoreResponses.Count -gt 0 -and
    @($rankerSquadScoreResponses | Where-Object {
        [int]$_.logCount -ne 5 -or
        [long]$_.logDamageSum -ne $authoritativeScore
    }).Count -eq 0
$scoreProjectionRequired = $OutcomeCode -ceq 'success' -and
    $ObservedStageCode -ceq 'battle_result'
$scoreProjectionVerified = $markerEvidenceSafe -and
    $setDamageScoreConsistent -and $infoScoreConsistent -and
    $rankingScoreConsistent -and $rankerSquadScoreConsistent
if ($scoreProjectionRequired) {
    Assert-True $scoreProjectionVerified `
        'phase3b2_score_consistency_v7_projection_verification_failed'
}

'@
    $innerCompletionText = Replace-ExactlyOnce `
        -Text $innerCompletionText `
        -Before '$databaseAfterByteLength = (Get-Item -LiteralPath $dbPath).Length' `
        -After ($scoreVerificationBlock +
            '$databaseAfterByteLength = (Get-Item -LiteralPath $dbPath).Length') `
        -FailureCode 'phase3b2_score_consistency_v7_verification_shape_invalid'
    $scoreReceiptFields = @'
    scoreObservationCount = $scoreObservations.Count
    completedScoreResponseCount = $completedScoreResponses.Count
    authoritativeFiveDeckScore = $authoritativeScore
    finalSetDamageInfoScore = if ($null -ne $finalCompletedScoreResponse) {
        [long]$finalCompletedScoreResponse.infoDamage
    } else { 0L }
    finalSetDamageUserScore = if ($null -ne $finalCompletedScoreResponse) {
        [long]$finalCompletedScoreResponse.userDamage
    } else { 0L }
    finalSetDamageTotalUserCount = if ($null -ne $finalCompletedScoreResponse) {
        [int]$finalCompletedScoreResponse.totalUserCount
    } else { 0 }
    getInfoObservationCount = $infoScoreResponses.Count
    getRankingObservationCount = $rankingScoreResponses.Count
    getRankerSquadObservationCount = $rankerSquadScoreResponses.Count
    setDamageScoreConsistent = $setDamageScoreConsistent
    infoScoreConsistent = $infoScoreConsistent
    rankingScoreConsistent = $rankingScoreConsistent
    rankerSquadScoreConsistent = $rankerSquadScoreConsistent
    scoreProjectionRequired = $scoreProjectionRequired
    scoreProjectionVerified = $scoreProjectionVerified
    scoreAuthorityCode = 'best_completed_challenge_five_deck_total_damage'
'@
    $innerCompletionText = Replace-ExactlyOnce `
        -Text $innerCompletionText `
        -Before '    regroupNonConsumptionVerified = $regroupNonConsumptionVerified' `
        -After ('    regroupNonConsumptionVerified = ' +
            '$regroupNonConsumptionVerified' + "`n" + $scoreReceiptFields) `
        -FailureCode 'phase3b2_score_consistency_v7_receipt_shape_invalid'
    Write-Utf8NoBom $innerCompletionPath $innerCompletionText

    foreach ($role in $stagedToolPaths.Keys) {
        Assert-PowerShellSyntax -Path $stagedToolPaths[$role] `
            -FailureCode (
                'phase3b2_score_consistency_v7_tool_syntax_invalid:' + $role
            )
    }
    $toolManifest = @(
        foreach ($role in $stagedToolPaths.Keys) {
            $path = [string]$stagedToolPaths[$role]
            [ordered]@{
                roleCode = $role
                leaf = [IO.Path]::GetFileName($path)
                byteLength = (Get-Item -LiteralPath $path).Length
                sha256 = Get-Sha256Hex $path
            }
        }
    )

    Assert-True (
        (Get-Sha256Hex (Join-Path $runtimeStagingRoot 'db.json')) -ceq
            $expectedDatabaseSha256 -and
        (Get-Sha256Hex (Join-Path $runtimeStagingRoot 'EpinelPS.exe')) -ceq
            $expectedServerExeSha256 -and
        (Get-Sha256Hex (Join-Path $runtimeStagingRoot 'EpinelPS.dll')) -ceq
            $candidateDllSha256 -and
        (Get-Sha256Hex (Join-Path $runtimeStagingRoot 'log4net.config')) -ceq
            $expectedLogConfigSha256 -and
        @(Get-ChildItem -LiteralPath (Join-Path $runtimeStagingRoot 'logs') `
            -Force).Count -eq 0
    ) 'phase3b2_score_consistency_v7_runtime_staging_invalid'

    New-Item -ItemType Directory -Path $deploymentStagingRoot | Out-Null
    Write-Utf8NoBom (Join-Path $deploymentStagingRoot 'source.manifest.tsv') `
        $sourceManifestText
    $receipt = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-solo-raid-score-consistency-deployment/v7'
        deployedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        deploymentUid = $deploymentUid
        parentLaneCode = 'epinel_solo_raid_score_ranking_v6'
        derivedLaneCode = 'epinel_solo_raid_score_consistency_v7'
        parentFingerprintSha256 = $parentFingerprintBefore
        sourceManifestMemberCount = $sourceRows.Count
        sourceManifestSha256 = $expectedSourceManifestSha256
        parentServerDllSha256 = $expectedParentDllSha256
        appliedServerDllByteLength = $candidateDllByteLength
        appliedServerDllSha256 = $candidateDllSha256
        selectedManagerPassedCount = 106
        selectedManagerFailedCount = 0
        scoreAuthorityCode =
            'best_completed_challenge_five_deck_total_damage'
        setDamageRankingSummaryProjected = $true
        expectedLocalRank = 1
        expectedLocalUserCount = 1
        dedicatedScoreRoutesShareAuthority = $true
        hardCodedHistoricalScore = $false
        v6ParentModified = $false
        micronLobbyGoldenModified = $false
        dLobbyGoldenModified = $false
        databaseModified = $false
        cacheModified = $false
        installedTools = $toolManifest
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        validationRunConsumed = $false
        rollbackCode = 'leave_v7_inert_and_select_untouched_v6'
        nextStepCode =
            'boot_micron_nlloperator_run_one_five_deck_score_consistency_validation'
    }
    Write-AtomicJson (Join-Path $deploymentStagingRoot `
        'deployment.receipt.json') $receipt
    Write-AtomicJson (Join-Path $deploymentStagingRoot 'audit.receipt.json') `
        $audit

    Move-Item -LiteralPath $runtimeStagingRoot -Destination $targetRuntimeRoot
    $runtimeStagingRoot = $null
    New-Item -ItemType Directory -Path $targetEvidenceRoot | Out-Null
    Move-Item -LiteralPath $deploymentStagingRoot `
        -Destination $targetDeploymentRoot
    $deploymentStagingRoot = $null
    foreach ($role in $stagedToolPaths.Keys) {
        Copy-Item -LiteralPath $stagedToolPaths[$role] -Destination `
            (Join-Path $toolRoot $targetToolNames[$role])
    }
    New-Item -ItemType Directory -Path $protectedRoot -Force | Out-Null
    foreach ($leaf in @(
            'deployment.receipt.json', 'audit.receipt.json',
            'source.manifest.tsv'
        )) {
        Copy-Item -LiteralPath (Join-Path $targetDeploymentRoot $leaf) `
            -Destination $protectedRoot
    }

    $parentFingerprintAfter = Get-CriticalFingerprint `
        -RuntimeRoot $parentRuntimeRoot -ToolPaths $parentToolPaths `
        -SentinelPaths $sentinelPaths
    Assert-True (
        $parentFingerprintAfter -ceq $parentFingerprintBefore -and
        -not (Test-Path -LiteralPath (Join-Path $targetEvidenceRoot `
                'active-run.pointer.json')) -and
        @($targetToolNames.Values | Where-Object {
                -not (Test-Path -LiteralPath (Join-Path $toolRoot $_) `
                    -PathType Leaf)
            }).Count -eq 0
    ) 'phase3b2_score_consistency_v7_post_deploy_invalid'

    $receiptPath = Join-Path $targetDeploymentRoot 'deployment.receipt.json'
    [pscustomobject]@{
        Receipt = $receipt
        MicronReceiptPath = $receiptPath
        MicronReceiptByteLength = (Get-Item -LiteralPath $receiptPath).Length
        MicronReceiptSha256 = Get-Sha256Hex $receiptPath
        ProtectedReceiptPath = Join-Path $protectedRoot `
            'deployment.receipt.json'
        MicronStartCommand =
            "& 'C:\NLL\Tools\Start-Phase3B2-Epinel-SoloRaidScoreConsistency-v7.ps1' -ValidationKind Challenge"
        MicronCompletionCommand =
            "& 'C:\NLL\Tools\Complete-Phase3B2-Epinel-SoloRaidScoreConsistency-v7.ps1' -ObservedStageCode battle_result -OutcomeCode success"
    } | ConvertTo-Json -Depth 14
}
finally {
    foreach ($path in @(
            $runtimeStagingRoot, $deploymentStagingRoot, $toolStagingRoot
        )) {
        if ($null -ne $path -and (Test-Path -LiteralPath $path)) {
            Remove-Item -LiteralPath $path -Recurse -Force
        }
    }
}
