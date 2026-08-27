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
    Write-Utf8NoBom $temporary (($Value | ConvertTo-Json -Depth 12) + "`n")
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
    param([string]$Path, [Collections.Specialized.OrderedDictionary]$Replacements)
    $text = (Get-Content -LiteralPath $Path -Raw -Encoding UTF8).Replace("`r`n", "`n")
    foreach ($before in $Replacements.Keys) {
        if ($text.Contains([string]$before)) {
            $text = $text.Replace([string]$before, [string]$Replacements[$before])
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
    foreach ($leaf in @('db.json', 'EpinelPS.exe', 'EpinelPS.dll', 'log4net.config')) {
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
        $item.LinkType -ceq 'Junction' -and [string]$item.Target -ceq $Target
    ) ($FailureCode + '_verification_failed')
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
Assert-True ($AuditOnly -or $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    'phase3b2_score_ranking_v6_requires_administrator'
Assert-True ($env:SystemDrive -ceq 'C:' -and $env:USERNAME -ceq 'zih44') `
    'phase3b2_score_ranking_v6_wrong_samsung_boundary'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$externalRoot = Join-Path $repositoryRoot '.external\EpinelPS'
$micronDrive = $MicronDriveLetter + ':'
$toolRoot = Join-Path $micronDrive 'NLL\Tools'
$parentRuntimeRoot = Join-Path $micronDrive `
    'NLL\Runtime\EpinelPS-SoloRaidRegroupRepair-v5'
$parentEvidenceRoot = Join-Path $micronDrive 'NLL\E\P3SRGR5'
$targetRuntimeRoot = Join-Path $micronDrive `
    'NLL\Runtime\EpinelPS-SoloRaidScoreRanking-v6'
$targetEvidenceRoot = Join-Path $micronDrive 'NLL\E\P3SRSR6'
$targetDeploymentRoot = Join-Path $micronDrive 'NLL\E\P3SRSR6D'
$candidateDllPath = Join-Path $externalRoot `
    'EpinelPS\bin\Release\net10.0\win-x64\EpinelPS.dll'
$bootCacheTarget =
    'C:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\cache'
$protectedBase =
    'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\EpinelSoloRaidScoreRanking-v6'

$parentToolNames = [ordered]@{
    outerStart = 'Start-Phase3B2-Epinel-SoloRaidRegroupRepair-v5.ps1'
    innerStart = 'start-phase3b2-epinel-solo-raid-regroup-repair-v5-in-micron.ps1'
    outerCompletion = 'Complete-Phase3B2-Epinel-SoloRaidRegroupRepair-v5.ps1'
    innerCompletion = 'complete-phase3b2-epinel-solo-raid-regroup-repair-v5-in-micron.ps1'
}
$targetToolNames = [ordered]@{
    outerStart = 'Start-Phase3B2-Epinel-SoloRaidScoreRanking-v6.ps1'
    innerStart = 'start-phase3b2-epinel-solo-raid-score-ranking-v6-in-micron.ps1'
    outerCompletion = 'Complete-Phase3B2-Epinel-SoloRaidScoreRanking-v6.ps1'
    innerCompletion = 'complete-phase3b2-epinel-solo-raid-score-ranking-v6-in-micron.ps1'
}
$parentToolPaths = [ordered]@{}
foreach ($role in $parentToolNames.Keys) {
    $parentToolPaths[$role] = Join-Path $toolRoot $parentToolNames[$role]
}
$expectedParentToolHashes = [ordered]@{
    outerStart = 'ae1c561eb813a3dd721f8aa9a2b8d0e41b75c788e6a39225b90b2b536a090c5e'
    innerStart = '9fc0d70f39b2569c3bea70e76b0e8b80aaea038b3615b863446cbf3f3fcc220c'
    outerCompletion = '42f0dd1d9af9e34814baa1d7a4f3f760b57df861cb274a8449b872887420db69'
    innerCompletion = 'cbb2fb3dd75ca038e5da8afcd128ef20c07710973eadefa79866353b8b5f1a90'
}
$expectedDatabaseSha256 =
    'dee9c6aa5421287ca030e325b81a90a302a5d9e113d57c3065e5d36f6e7c4019'
$expectedServerExeSha256 =
    'a28c7ff227a74d260a29389b82caeed3fe196f91eef3d28cabe9977b5ed9d07b'
$expectedParentDllSha256 =
    '9f350c9ba11df44365d890439f588fd29734e1ded14026934fea1c02bfed4c42'
$expectedLogConfigSha256 =
    '31b873b3ad156436f0a55f54f1518fde9e2e6c0059cca3ec2e3b181c08c448b9'
$candidateDllByteLength = 15382016L
$candidateDllSha256 =
    'a9fcd79c1655fe130a13966dc3bac338ce41ab162e4e8cd32747e5d6487be746'
$expectedSourceManifestSha256 =
    'ca72c8933e0cc7f3c037dbca042d78dcdb98cbd2201e569e6ae744d5080fb207'

$micronGoldenReceipt = Join-Path $micronDrive `
    'NLL\Evidence\Phase3B2\Physical\epinel-lobby-golden-baseline-v1\15089f3e-92f2-4833-ab1b-348d1463f9fc\golden-baseline.receipt.json'
$micronGoldenManifest = Join-Path $micronDrive `
    'NLL\Backups\Phase3B2\EpinelLobbyGoldenBaseline-v1\15089f3e-92f2-4833-ab1b-348d1463f9fc\artifact.manifest.json'
$dCheckpointRoot =
    'D:\NikkeLocalLab\Backups\phase3b2-season26-challenge-regroup-v5-checkpoint-v1\e40c70a0-16a3-4a83-9d30-b16f368ce73a'
$dCheckpointReceipt = Join-Path $dCheckpointRoot 'metadata\seal.receipt.json'
$dCheckpointManifest = Join-Path $dCheckpointRoot 'metadata\content.manifest.json'
$goldenSentinels = @(
    $micronGoldenReceipt, $micronGoldenManifest,
    $dCheckpointReceipt, $dCheckpointManifest
)
$expectedGoldenHashes = @(
    'ebf5c2f7692e7de7ec9b8bcf3acba112cdb8efbfbb888967acde7e429e877f9c',
    '25a3a7696c486098bedf5184c31d80380543c3ab4809467e71b0a4594c332be7',
    'e69ee9020abf5c77fc61f433ae56729d36c82c10289b385ee1bdde30604e3753',
    'bed4e1ba8a58b42d3ae8e4b1d5409c0966efc19d53f6ec87cd6d426252e82b59'
)

$sourceManifestText = @'
EpinelPS/LobbyServer/Soloraid/ClassicSoloRaidPeriodProvider.cs	2361	1b94449d3b5743481d87104e861c162dea6329d4cf967a495d028bce64fe1c51
EpinelPS/LobbyServer/Soloraid/ClassicSoloRaidRouteExecutor.cs	14635	a0c4a97a7f138b311c4f2a6afc47694bcc9bfeba2cdff270d224ebd5e0201a11
EpinelPS/LobbyServer/Soloraid/ClassicSoloRaidRoutePolicy.cs	3964	f8b0e461e8245db78528de2b2bcbb35f8c6788d5c58ce720676b282038a0bbb2
EpinelPS/LobbyServer/Soloraid/ClosePractice.cs	483	008fb87bd9886ee98c800839551165ca1725ee7f792c73a7496b2e7957d1f1ce
EpinelPS/LobbyServer/Soloraid/GetLevelPractice.cs	408	3269e71a731f88f1798b349955b2087a016407b5fd48e827a430f988944eef91
EpinelPS/LobbyServer/Soloraid/GetRankerSquad.cs	476	e6dd92346baae503135c02050ad1f717f21dbbb9a024d8b2bec7e759d09a365f
EpinelPS/LobbyServer/Soloraid/GetRanking.cs	359	dabf3f94903c369533d55482c850279b5d754c5795687a99d8b9640b2ef0c44c
EpinelPS/LobbyServer/Soloraid/OpenPractice.cs	513	d04b2622940a9cc9e4a44c77b5f27434356a48f8e14615c90fb17e4701371e3d
EpinelPS/LobbyServer/Soloraid/SetDamagePractice.cs	402	2bcccbdefcb7646e116e5685f070b6a87b18385f8c443a40ce76e1705b7cd25c
EpinelPS/LobbyServer/Soloraid/SetDamageTrial.cs	768	85b2eea58be7ca84ca7dff32a8f22cd0933fe971ea19e7b5631de17c37633d73
EpinelPS/LobbyServer/Soloraid/SoloRaidHelper.cs	33090	8404a6c4eec383553ad9639a6ce887765fb909dbf646ccf971c00c6f809e9815
EpinelPS/SoloRaidSelection/SoloRaidManagerSelectionResolver.cs	5962	995c084ad7eb3ea1102375ffd307acce9ad614eba35c2045aa0750d934126991
tests/EpinelPS.SelectedManager.Tests/BaselineRouteAuditTests.cs	3581	3cd4992411140f28796abd2703b7744149c8e59a839373dd445731db8c46f6aa
tests/EpinelPS.SelectedManager.Tests/ClassicSoloRaidPeriodProviderTests.cs	5305	542f27a26ae655d6609bfcf18b7af494846d6a3ba346d5e8693faa460a355e4e
tests/EpinelPS.SelectedManager.Tests/RoutePolicyFixture.cs	2453	6f685be3a309005742197139ed93fc4c6d8d779cb841aa4b58308fd71cec5002
tests/EpinelPS.SelectedManager.Tests/RoutePolicyRedTests.cs	5779	b95e4a23ba63d36a162e27149218695d499fac4a3aa0634d1be5e032089f8e2d
tests/EpinelPS.SelectedManager.Tests/SelectionPersistenceTests.cs	13828	ba7ca00dbf59b278753d79b476b16488260e86516492ce708d0fd19100f2744c
tests/EpinelPS.SelectedManager.Tests/SoloRaidRetrySemanticsTests.cs	11728	1ba1b4e00c9189f5062a867131d3ee7fe16bdc57fb75d42c7a3c27e75a7f2813
tests/EpinelPS.SelectedManager.Tests/TrialPracticeWireOrderCharacterizationTests.cs	31112	9c4fe48c5c3826217b30e78ae0a109703893e959dc9dd3e8da05f5659e37902e
tests/EpinelPS.SelectedManager.Tests/WireShapeCharacterizationTests.cs	8109	a0fac6c1f2211905fa4076e88e5f3cf96c68e65da39b178bac9c604c25089be8
'@.Replace("`r`n", "`n")

$sourceRows = @($sourceManifestText.TrimEnd("`n") -split "`n")
foreach ($row in $sourceRows) {
    $parts = $row -split "`t"
    Assert-True ($parts.Count -eq 3) 'phase3b2_score_ranking_v6_source_manifest_shape_invalid'
    $path = Join-Path $externalRoot ($parts[0].Replace('/', '\'))
    Assert-True (
        (Test-Path -LiteralPath $path -PathType Leaf) -and
        (Get-Item -LiteralPath $path).Length -eq [long]$parts[1] -and
        (Get-Sha256Hex $path) -ceq $parts[2]
    ) ('phase3b2_score_ranking_v6_source_drift:' + $parts[0])
}
$sourceManifestText += "`n"
Assert-True (
    (Get-BytesSha256Hex ([Text.UTF8Encoding]::new($false).GetBytes(
                $sourceManifestText))) -ceq $expectedSourceManifestSha256
) 'phase3b2_score_ranking_v6_source_manifest_digest_invalid'

$requiredPaths = @(
    $DotnetPath,
    (Join-Path $parentRuntimeRoot 'db.json'),
    (Join-Path $parentRuntimeRoot 'EpinelPS.exe'),
    (Join-Path $parentRuntimeRoot 'EpinelPS.dll'),
    (Join-Path $parentRuntimeRoot 'log4net.config')
) + @($parentToolPaths.Values) + $goldenSentinels
Assert-True (@($requiredPaths | Where-Object {
            -not (Test-Path -LiteralPath $_ -PathType Leaf)
        }).Count -eq 0) 'phase3b2_score_ranking_v6_input_missing'
Assert-True (
    @(Get-Process EpinelPS, nikke, NikkeLocalLab.Phase3B2.PhysicalBootstrap `
        -ErrorAction SilentlyContinue).Count -eq 0 -and
    -not (Test-Path -LiteralPath (Join-Path $parentEvidenceRoot `
                'active-run.pointer.json'))
) 'phase3b2_score_ranking_v6_runtime_not_cold'

Assert-True (
    (Get-Sha256Hex (Join-Path $parentRuntimeRoot 'db.json')) -ceq
        $expectedDatabaseSha256 -and
    (Get-Sha256Hex (Join-Path $parentRuntimeRoot 'EpinelPS.exe')) -ceq
        $expectedServerExeSha256 -and
    (Get-Sha256Hex (Join-Path $parentRuntimeRoot 'EpinelPS.dll')) -ceq
        $expectedParentDllSha256 -and
    (Get-Sha256Hex (Join-Path $parentRuntimeRoot 'log4net.config')) -ceq
        $expectedLogConfigSha256
) 'phase3b2_score_ranking_v6_parent_runtime_drift'
foreach ($role in $parentToolPaths.Keys) {
    Assert-True (
        (Get-Sha256Hex $parentToolPaths[$role]) -ceq
            $expectedParentToolHashes[$role]
    ) ('phase3b2_score_ranking_v6_parent_tool_drift:' + $role)
}
$parentCache = Get-Item -LiteralPath (Join-Path $parentRuntimeRoot 'cache') `
    -Force -ErrorAction SilentlyContinue
Assert-True (
    $null -ne $parentCache -and $parentCache.LinkType -ceq 'Junction' -and
    [string]$parentCache.Target -ceq $bootCacheTarget
) 'phase3b2_score_ranking_v6_parent_cache_invalid'
for ($index = 0; $index -lt $goldenSentinels.Count; $index++) {
    Assert-True (
        (Get-Sha256Hex $goldenSentinels[$index]) -ceq $expectedGoldenHashes[$index]
    ) ('phase3b2_score_ranking_v6_golden_sentinel_drift:' + $index)
}

$parentFingerprintBefore = Get-CriticalFingerprint `
    -RuntimeRoot $parentRuntimeRoot -ToolPaths $parentToolPaths `
    -SentinelPaths $goldenSentinels

Push-Location $externalRoot
try {
    $testOutput = (& $DotnetPath test `
        'tests\EpinelPS.SelectedManager.Tests\EpinelPS.SelectedManager.Tests.csproj' `
        --no-restore --configuration Release 2>&1 | Out-String).Trim()
    $testExitCode = $LASTEXITCODE
}
finally {
    Pop-Location
}
Assert-True ($testExitCode -eq 0 -and $testOutput -match '106') `
    'phase3b2_score_ranking_v6_selected_manager_tests_failed'
Assert-True (
    (Get-Item -LiteralPath $candidateDllPath).Length -eq $candidateDllByteLength -and
    (Get-Sha256Hex $candidateDllPath) -ceq $candidateDllSha256
) 'phase3b2_score_ranking_v6_candidate_dll_drift'

$audit = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-epinel-solo-raid-score-ranking-audit/v6'
    auditedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    sourceManifestMemberCount = $sourceRows.Count
    sourceManifestSha256 = $expectedSourceManifestSha256
    selectedManagerPassedCount = 106
    selectedManagerFailedCount = 0
    candidateServerDllByteLength = $candidateDllByteLength
    candidateServerDllSha256 = $candidateDllSha256
    parentFingerprintSha256 = $parentFingerprintBefore
    parentRuntimeCold = $true
    parentV5ReadOnly = $true
    micronGoldenReadOnly = $true
    dGoldenReadOnly = $true
    rankingTotalSourceCode = 'best_completed_challenge_five_deck_total_damage'
    rankingDetailSourceCode = 'same_best_record_five_logs_in_deck_order'
    lowerScorePreservesBestRecord = $true
    completedBattleResult = 1
    completedBattleResultPolicyCode = 'completed_consuming'
    retryBattleResult = 4
    regroupBattleResult = 6
    nonConsumingBattleResultPolicyCode = 'retry_4_or_regroup_6'
    historicalReceiptBindingApplied = $false
    wrapperSelfHashBindingApplied = $false
    deployable = $true
}
if ($AuditOnly) {
    [pscustomobject]@{ Audit = $audit; TestOutput = $testOutput } |
        ConvertTo-Json -Depth 8
    return
}

Assert-True (
    -not (Test-Path -LiteralPath $targetRuntimeRoot) -and
    -not (Test-Path -LiteralPath $targetEvidenceRoot) -and
    -not (Test-Path -LiteralPath $targetDeploymentRoot) -and
    @($targetToolNames.Values | Where-Object {
            Test-Path -LiteralPath (Join-Path $toolRoot $_)
        }).Count -eq 0
) 'phase3b2_score_ranking_v6_target_collision'

$deploymentUid = [Guid]::NewGuid().ToString('D')
$runtimeStagingRoot = $targetRuntimeRoot + '.staging-' +
    [Guid]::NewGuid().ToString('N')
$deploymentStagingRoot = $targetDeploymentRoot + '.staging-' +
    [Guid]::NewGuid().ToString('N')
$toolStagingRoot = Join-Path $env:TEMP `
    ('NLL-Phase3B2-ScoreRanking-v6-' + [Guid]::NewGuid().ToString('N'))
$protectedRoot = Join-Path $protectedBase $deploymentUid

try {
    New-Item -ItemType Directory -Path $runtimeStagingRoot | Out-Null
    foreach ($entry in @(Get-ChildItem -LiteralPath $parentRuntimeRoot -Force)) {
        if ($entry.Name -in @('cache', 'logs', 'EpinelPS.dll')) { continue }
        Copy-Item -LiteralPath $entry.FullName -Destination $runtimeStagingRoot -Recurse
    }
    Copy-Item -LiteralPath $candidateDllPath -Destination `
        (Join-Path $runtimeStagingRoot 'EpinelPS.dll')
    New-Item -ItemType Directory -Path (Join-Path $runtimeStagingRoot 'logs') |
        Out-Null
    New-ExactJunction -Path (Join-Path $runtimeStagingRoot 'cache') `
        -Target $bootCacheTarget `
        -FailureCode 'phase3b2_score_ranking_v6_cache_link_failed'

    New-Item -ItemType Directory -Path $toolStagingRoot | Out-Null
    $replacements = [ordered]@{
        'EpinelPS-SoloRaidRegroupRepair-v5' = 'EpinelPS-SoloRaidScoreRanking-v6'
        'P3SRGR5' = 'P3SRSR6'
        'SoloRaidRegroupRepair-v5' = 'SoloRaidScoreRanking-v6'
        'solo-raid-regroup-repair-v5' = 'solo-raid-score-ranking-v6'
        'solo-raid-regroup-repair-start/v5' = 'solo-raid-score-ranking-start/v6'
        'solo-raid-regroup-repair-failure/v5' = 'solo-raid-score-ranking-failure/v6'
        'solo-raid-regroup-repair-completion/v5' = 'solo-raid-score-ranking-completion/v6'
        'solo-raid-regroup-repair-validation/v5' = 'solo-raid-score-ranking-validation/v6'
        'solo-raid-regroup-marker-evidence/v5' = 'solo-raid-score-ranking-marker-evidence/v6'
        'regroup_repair_v5' = 'score_ranking_v6'
        '15378432L' = '15382016L'
        $expectedParentDllSha256 = $candidateDllSha256
        '1a1cb7b110bcf2ba7cf3c4bb0a3c6f681df4d60112dd9bb523c71d3b3dc83030' =
            $expectedSourceManifestSha256
    }
    $stagedToolPaths = [ordered]@{}
    foreach ($role in $parentToolPaths.Keys) {
        $text = Get-DerivedToolText -Path $parentToolPaths[$role] `
            -Replacements $replacements
        Assert-True (
            -not $text.Contains('SoloRaidRegroupRepair-v5') -and
            -not $text.Contains('solo-raid-regroup-repair-v5') -and
            -not $text.Contains('P3SRGR5')
        ) ('phase3b2_score_ranking_v6_old_lane_reference_retained:' + $role)
        $path = Join-Path $toolStagingRoot $targetToolNames[$role]
        Write-Utf8NoBom $path $text
        $stagedToolPaths[$role] = $path
    }

    $innerCompletionPath = [string]$stagedToolPaths.innerCompletion
    $innerCompletionText = Get-Content -LiteralPath $innerCompletionPath `
        -Raw -Encoding UTF8
    $classificationBefore = @'
$observedRegroupCount = @($observations | Where-Object {
        [int]$_.battleResult -eq 6
    }).Count
$observedLegacyRetryCount = @($observations | Where-Object {
        [int]$_.battleResult -eq 4
    }).Count
$unsupportedBattleResultCount = @($observations | Where-Object {
        [int]$_.battleResult -notin @(4, 6)
    }).Count
'@
    $classificationAfter = @'
$observedCompletedCount = @($observations | Where-Object {
        [int]$_.battleResult -eq 1
    }).Count
$observedRegroupCount = @($observations | Where-Object {
        [int]$_.battleResult -eq 6
    }).Count
$observedLegacyRetryCount = @($observations | Where-Object {
        [int]$_.battleResult -eq 4
    }).Count
$unsupportedBattleResultCount = @($observations | Where-Object {
        [int]$_.battleResult -notin @(1, 4, 6)
    }).Count
$battleResultClassificationValid = $unsupportedBattleResultCount -eq 0
'@
    $innerCompletionText = Replace-ExactlyOnce `
        -Text $innerCompletionText -Before $classificationBefore `
        -After $classificationAfter `
        -FailureCode 'phase3b2_score_ranking_v6_classification_shape_invalid'
    $receiptBefore = @'
    observedRegroupResultCount = $observedRegroupCount
    observedLegacyRetryResultCount = $observedLegacyRetryCount
    unsupportedBattleResultCount = $unsupportedBattleResultCount
'@
    $receiptAfter = @'
    observedCompletedResultCount = $observedCompletedCount
    observedRegroupResultCount = $observedRegroupCount
    observedLegacyRetryResultCount = $observedLegacyRetryCount
    unsupportedBattleResultCount = $unsupportedBattleResultCount
    battleResultClassificationValid = $battleResultClassificationValid
    battleResultPolicyCode = 'completed_1_consuming_retry_4_or_regroup_6_nonconsuming'
'@
    $innerCompletionText = Replace-ExactlyOnce `
        -Text $innerCompletionText -Before $receiptBefore -After $receiptAfter `
        -FailureCode 'phase3b2_score_ranking_v6_receipt_shape_invalid'
    Write-Utf8NoBom $innerCompletionPath $innerCompletionText

    foreach ($role in $stagedToolPaths.Keys) {
        Assert-PowerShellSyntax -Path $stagedToolPaths[$role] `
            -FailureCode ('phase3b2_score_ranking_v6_tool_syntax_invalid:' + $role)
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
    ) 'phase3b2_score_ranking_v6_runtime_staging_invalid'

    New-Item -ItemType Directory -Path $deploymentStagingRoot | Out-Null
    Write-Utf8NoBom (Join-Path $deploymentStagingRoot 'source.manifest.tsv') `
        $sourceManifestText
    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-epinel-solo-raid-score-ranking-deployment/v6'
        deployedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        deploymentUid = $deploymentUid
        parentLaneCode = 'epinel_solo_raid_regroup_repair_v5'
        derivedLaneCode = 'epinel_solo_raid_score_ranking_v6'
        parentFingerprintSha256 = $parentFingerprintBefore
        sourceManifestMemberCount = $sourceRows.Count
        sourceManifestSha256 = $expectedSourceManifestSha256
        parentServerDllSha256 = $expectedParentDllSha256
        appliedServerDllByteLength = $candidateDllByteLength
        appliedServerDllSha256 = $candidateDllSha256
        selectedManagerPassedCount = 106
        selectedManagerFailedCount = 0
        rankingLocalUserCount = 1
        rankingLocalUserRank = 1
        rankingTotalSourceCode = 'best_completed_challenge_five_deck_total_damage'
        rankingDetailRouteCode = 'soloraid_getrankersquad'
        rankingDetailSourceCode = 'same_best_record_five_logs_in_deck_order'
        rankingDetailExpectedLogCount = 5
        lowerScorePreservesBestRecord = $true
        completedBattleResult = 1
        completedBattleResultPolicyCode = 'completed_consuming'
        retryBattleResult = 4
        regroupBattleResult = 6
        nonConsumingBattleResultPolicyCode = 'retry_4_or_regroup_6'
        historicalReceiptBindingApplied = $false
        wrapperSelfHashBindingApplied = $false
        parentV5Modified = $false
        micronLobbyGoldenModified = $false
        dLobbyGoldenModified = $false
        databaseModified = $false
        cacheModified = $false
        installedTools = $toolManifest
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        validationRunConsumed = $false
        rollbackCode = 'leave_v6_inert_and_select_untouched_v5'
        nextStepCode = 'boot_micron_nlloperator_run_one_five_deck_score_ranking_validation'
    }
    Write-AtomicJson (Join-Path $deploymentStagingRoot `
        'deployment.receipt.json') $receipt
    Write-AtomicJson (Join-Path $deploymentStagingRoot 'audit.receipt.json') $audit

    Move-Item -LiteralPath $runtimeStagingRoot -Destination $targetRuntimeRoot
    $runtimeStagingRoot = $null
    New-Item -ItemType Directory -Path $targetEvidenceRoot | Out-Null
    Move-Item -LiteralPath $deploymentStagingRoot -Destination $targetDeploymentRoot
    $deploymentStagingRoot = $null
    foreach ($role in $stagedToolPaths.Keys) {
        Copy-Item -LiteralPath $stagedToolPaths[$role] -Destination `
            (Join-Path $toolRoot $targetToolNames[$role])
    }
    New-Item -ItemType Directory -Path $protectedRoot -Force | Out-Null
    foreach ($leaf in @('deployment.receipt.json', 'audit.receipt.json',
            'source.manifest.tsv')) {
        Copy-Item -LiteralPath (Join-Path $targetDeploymentRoot $leaf) `
            -Destination $protectedRoot
    }

    $parentFingerprintAfter = Get-CriticalFingerprint `
        -RuntimeRoot $parentRuntimeRoot -ToolPaths $parentToolPaths `
        -SentinelPaths $goldenSentinels
    Assert-True (
        $parentFingerprintAfter -ceq $parentFingerprintBefore -and
        -not (Test-Path -LiteralPath (Join-Path $targetEvidenceRoot `
                'active-run.pointer.json')) -and
        @($targetToolNames.Values | Where-Object {
                -not (Test-Path -LiteralPath (Join-Path $toolRoot $_) -PathType Leaf)
            }).Count -eq 0
    ) 'phase3b2_score_ranking_v6_post_deploy_invalid'

    $receiptPath = Join-Path $targetDeploymentRoot 'deployment.receipt.json'
    [pscustomobject]@{
        Receipt = $receipt
        MicronReceiptPath = $receiptPath
        MicronReceiptByteLength = (Get-Item -LiteralPath $receiptPath).Length
        MicronReceiptSha256 = Get-Sha256Hex $receiptPath
        ProtectedReceiptPath = Join-Path $protectedRoot 'deployment.receipt.json'
        MicronStartCommand =
            "& 'C:\NLL\Tools\Start-Phase3B2-Epinel-SoloRaidScoreRanking-v6.ps1' -ValidationKind Challenge"
        MicronCompletionCommand =
            "& 'C:\NLL\Tools\Complete-Phase3B2-Epinel-SoloRaidScoreRanking-v6.ps1' -ObservedStageCode battle_result -OutcomeCode success"
    } | ConvertTo-Json -Depth 12
}
finally {
    foreach ($path in @($runtimeStagingRoot, $deploymentStagingRoot, $toolStagingRoot)) {
        if ($null -ne $path -and (Test-Path -LiteralPath $path)) {
            Remove-Item -LiteralPath $path -Recurse -Force
        }
    }
}
