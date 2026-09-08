#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$DotnetPath = 'C:\Program Files\dotnet\dotnet.exe',
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

function Get-TextSha256Hex {
    param([string]$Text)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
        return ($algorithm.ComputeHash($bytes) | ForEach-Object {
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

function Assert-PowerShellTextSyntax {
    param([string]$Text, [string]$FailureCode)
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseInput(
        $Text, [ref]$tokens, [ref]$errors) | Out-Null
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

function New-ExactJunction {
    param([string]$Path, [string]$Target)
    & $env:ComSpec /d /c mklink /J $Path $Target | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) 'phase3b2_ranking_prefix_v9_cache_link_failed'
    $item = Get-Item -LiteralPath $Path -Force
    Assert-True (
        $item.LinkType -ceq 'Junction' -and
        [string]$item.Target -ceq $Target
    ) 'phase3b2_ranking_prefix_v9_cache_link_verification_failed'
}

function Get-ParentFingerprint {
    param(
        [string]$RuntimeRoot,
        [Collections.Specialized.OrderedDictionary]$ToolPaths
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
    Get-TextSha256Hex ((($rows | Sort-Object) -join "`n") + "`n")
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
Assert-True (
    $AuditOnly -or
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
) 'phase3b2_ranking_prefix_v9_requires_administrator'
Assert-True ($env:SystemDrive -ceq 'C:' -and $env:USERNAME -ceq 'nlloperator') `
    'phase3b2_ranking_prefix_v9_wrong_operator_or_boot_boundary'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$externalRoot = Join-Path $repositoryRoot '.external\EpinelPS'
$candidateDllPath = Join-Path $externalRoot `
    'EpinelPS\bin\Release\net10.0\win-x64\EpinelPS.dll'
$sourceManifestPath = Join-Path $repositoryRoot `
    'scripts\phase-d-ranking-prefix-v9.source.manifest.tsv'
$parentRuntimeRoot = 'C:\NLL\Runtime\EpinelPS-SoloRaidDamageSourceObserver-v8'
$targetRuntimeRoot = 'C:\NLL\Runtime\EpinelPS-SoloRaidRankingPrefix-v9'
$parentEvidenceRoot = 'C:\NLL\E\P3SRDSO8'
$parentDeploymentReceiptPath = 'C:\NLL\E\P3SRDSO8D\deployment.receipt.json'
$parentSourceManifestPath = 'C:\NLL\E\P3SRDSO8D\source.manifest.tsv'
$parentRepairReceiptPath =
    'C:\NLL\E\P3SRDSO8D\completion-repair-v1\fa0a5b60-fa43-46b7-ac79-426501b86cfb\repair.receipt.json'
$parentCompletionReceiptPath =
    'C:\NLL\E\P3SRDSO8\9db13331-aa5b-469e-aaa5-d92bcb11c16e\completion.receipt.json'
$targetEvidenceRoot = 'C:\NLL\E\P3SRRP9'
$targetDeploymentRoot = 'C:\NLL\E\P3SRRP9D'
$toolRoot = 'C:\NLL\Tools'
$cacheTarget =
    'C:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\cache'

$parentToolNames = [ordered]@{
    outerStart = 'Start-Phase3B2-Epinel-SoloRaidDamageSourceObserver-v8.ps1'
    innerStart = 'start-phase3b2-epinel-solo-raid-damage-source-observer-v8-in-micron.ps1'
    outerCompletion = 'Complete-Phase3B2-Epinel-SoloRaidDamageSourceObserver-v8.ps1'
    innerCompletion = 'complete-phase3b2-epinel-solo-raid-damage-source-observer-v8-in-micron.ps1'
}
$targetToolNames = [ordered]@{
    outerStart = 'Start-Phase3B2-Epinel-SoloRaidRankingPrefix-v9.ps1'
    innerStart = 'start-phase3b2-epinel-solo-raid-ranking-prefix-v9-in-micron.ps1'
    outerCompletion = 'Complete-Phase3B2-Epinel-SoloRaidRankingPrefix-v9.ps1'
    innerCompletion = 'complete-phase3b2-epinel-solo-raid-ranking-prefix-v9-in-micron.ps1'
}
$parentToolPaths = [ordered]@{}
$targetToolPaths = [ordered]@{}
foreach ($role in $parentToolNames.Keys) {
    $parentToolPaths[$role] = Join-Path $toolRoot $parentToolNames[$role]
    $targetToolPaths[$role] = Join-Path $toolRoot $targetToolNames[$role]
}

$expectedParentHashes = [ordered]@{
    database = 'dee9c6aa5421287ca030e325b81a90a302a5d9e113d57c3065e5d36f6e7c4019'
    serverExe = 'a28c7ff227a74d260a29389b82caeed3fe196f91eef3d28cabe9977b5ed9d07b'
    serverDll = '7220be7819121c38acfe9b221bfa6a89b7f894e737bd5df97a955289e2417519'
    logConfig = '31b873b3ad156436f0a55f54f1518fde9e2e6c0059cca3ec2e3b181c08c448b9'
}
$expectedParentToolHashes = [ordered]@{
    outerStart = '2819d06387aee08a959a1c6e9f8d9c79e26e4bd4dec88bce091440d712b62071'
    innerStart = '190d1583e306bf71e93dee01bcdfda37a4cb9b748cb548760a98f81a77426faa'
    outerCompletion = 'c22e3f87d46abff37dd2da2c394b02f8c4d24402f7d4562b3a2d11da3545d661'
    innerCompletion = 'd33167a474af8a4e58c8382f8032165ef5d9f7964faf88320a83c2e19a68487c'
}
$expectedParentEvidence = [ordered]@{
    deploymentReceiptLength = 3205L
    deploymentReceiptSha256 =
        '8f88367eb79582be6c491ce04515dde5c2ccbbbbb2469262f42d76ddc4e0c51c'
    sourceManifestLength = 2833L
    sourceManifestSha256 =
        '4a0a1f71fe9b7a235703293d6a9c6adb9626ab18b0a8d8daf885c01008fe1f02'
    repairReceiptLength = 1758L
    repairReceiptSha256 =
        'e1133e09cc528f10218c9702ecc78949f57cd2757612afdf4288702b641acfba'
    completionReceiptLength = 5210L
    completionReceiptSha256 =
        'd5179bac2db5114204cc124db64fdf062d6be75c2fa8ea5a8115844f587130b7'
}
$expectedCandidateDllByteLength = 15398400L
$expectedCandidateDllSha256 =
    '98d4f4d12ff83c694ee052f9eca3c63ae782f2c4747a80993ee257384eef2498'
$expectedSourceManifestByteLength = 2559L
$expectedSourceManifestSha256 =
    'be2b0107ecec425d3c6dc4538d33306f81c55e0142f312fa3da9bd10ed29a1d7'
$expectedSourceManifestRowCount = 19
$rankingWirePrefix = 1130781186L

$requiredFiles = @(
    $DotnetPath,
    $candidateDllPath,
    $sourceManifestPath,
    (Join-Path $parentRuntimeRoot 'db.json'),
    (Join-Path $parentRuntimeRoot 'EpinelPS.exe'),
    (Join-Path $parentRuntimeRoot 'EpinelPS.dll'),
    (Join-Path $parentRuntimeRoot 'log4net.config'),
    $parentDeploymentReceiptPath,
    $parentSourceManifestPath,
    $parentRepairReceiptPath,
    $parentCompletionReceiptPath
) + @($parentToolPaths.Values)
Assert-True (@($requiredFiles | Where-Object {
            -not (Test-Path -LiteralPath $_ -PathType Leaf)
        }).Count -eq 0) 'phase3b2_ranking_prefix_v9_input_missing'
Assert-True (
    @(Get-Process -Name EpinelPS, nikke, nikke_launcher,
        NikkeLocalLab.Phase3B2.PhysicalBootstrap -ErrorAction SilentlyContinue
    ).Count -eq 0 -and
    -not (Test-Path -LiteralPath (Join-Path $parentEvidenceRoot `
                'active-run.pointer.json'))
) 'phase3b2_ranking_prefix_v9_runtime_not_cold'
Assert-True (
    -not (Test-Path -LiteralPath (Join-Path $parentRuntimeRoot 'epinelps.db')) -and
    -not (Test-Path -LiteralPath (Join-Path $parentRuntimeRoot 'epinelps.db-shm')) -and
    -not (Test-Path -LiteralPath (Join-Path $parentRuntimeRoot 'epinelps.db-wal'))
) 'phase3b2_ranking_prefix_v9_parent_database_not_cold'

Assert-True (
    (Get-Sha256Hex (Join-Path $parentRuntimeRoot 'db.json')) -ceq
        $expectedParentHashes.database -and
    (Get-Sha256Hex (Join-Path $parentRuntimeRoot 'EpinelPS.exe')) -ceq
        $expectedParentHashes.serverExe -and
    (Get-Sha256Hex (Join-Path $parentRuntimeRoot 'EpinelPS.dll')) -ceq
        $expectedParentHashes.serverDll -and
    (Get-Sha256Hex (Join-Path $parentRuntimeRoot 'log4net.config')) -ceq
        $expectedParentHashes.logConfig
) 'phase3b2_ranking_prefix_v9_parent_runtime_drifted'
foreach ($role in $parentToolPaths.Keys) {
    Assert-True (
        (Get-Sha256Hex $parentToolPaths[$role]) -ceq
            $expectedParentToolHashes[$role]
    ) ('phase3b2_ranking_prefix_v9_parent_tool_drifted:' + $role)
}
$parentCache = Get-Item -LiteralPath (Join-Path $parentRuntimeRoot 'cache') `
    -Force -ErrorAction SilentlyContinue
Assert-True (
    $null -ne $parentCache -and
    $parentCache.LinkType -ceq 'Junction' -and
    [string]$parentCache.Target -ceq $cacheTarget
) 'phase3b2_ranking_prefix_v9_parent_cache_invalid'
Assert-True (
    (Get-Item -LiteralPath $parentDeploymentReceiptPath).Length -eq
        $expectedParentEvidence.deploymentReceiptLength -and
    (Get-Sha256Hex $parentDeploymentReceiptPath) -ceq
        $expectedParentEvidence.deploymentReceiptSha256 -and
    (Get-Item -LiteralPath $parentSourceManifestPath).Length -eq
        $expectedParentEvidence.sourceManifestLength -and
    (Get-Sha256Hex $parentSourceManifestPath) -ceq
        $expectedParentEvidence.sourceManifestSha256 -and
    (Get-Item -LiteralPath $parentRepairReceiptPath).Length -eq
        $expectedParentEvidence.repairReceiptLength -and
    (Get-Sha256Hex $parentRepairReceiptPath) -ceq
        $expectedParentEvidence.repairReceiptSha256 -and
    (Get-Item -LiteralPath $parentCompletionReceiptPath).Length -eq
        $expectedParentEvidence.completionReceiptLength -and
    (Get-Sha256Hex $parentCompletionReceiptPath) -ceq
        $expectedParentEvidence.completionReceiptSha256
) 'phase3b2_ranking_prefix_v9_parent_evidence_drifted'
$parentDeployment = Get-Content -LiteralPath $parentDeploymentReceiptPath `
    -Raw -Encoding UTF8 | ConvertFrom-Json
$parentRepair = Get-Content -LiteralPath $parentRepairReceiptPath `
    -Raw -Encoding UTF8 | ConvertFrom-Json
$parentCompletion = Get-Content -LiteralPath $parentCompletionReceiptPath `
    -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True (
    $parentDeployment.contractId -ceq
        'nll/phase3b2-epinel-solo-raid-damage-source-observer-deployment/v8' -and
    $parentDeployment.appliedServerDllSha256 -ceq
        $expectedParentHashes.serverDll -and
    -not $parentDeployment.v7ParentModified -and
    $parentRepair.contractId -ceq
        'nll/phase3b2-epinel-solo-raid-damage-source-observer-completion-repair/v1' -and
    $parentRepair.repairedInnerCompletionSha256 -ceq
        $expectedParentToolHashes.innerCompletion -and
    -not $parentRepair.runtimeModified -and
    -not $parentRepair.databaseModified -and
    $parentCompletion.contractId -ceq
        'nll/phase3b2-epinel-solo-raid-damage-source-observer-completion/v8' -and
    $parentCompletion.outcomeCode -ceq 'success' -and
    $parentCompletion.observedStageCode -ceq 'battle_result' -and
    $parentCompletion.databaseRestored -and
    $parentCompletion.hostsRestored -and
    $parentCompletion.runtimeColdAfterCompletion -and
    $parentCompletion.scoreProjectionVerified -and
    $parentCompletion.damageSourceObservationComplete
) 'phase3b2_ranking_prefix_v9_parent_evidence_invalid'

Assert-True (
    (Get-Item -LiteralPath $candidateDllPath).Length -eq
        $expectedCandidateDllByteLength -and
    (Get-Sha256Hex $candidateDllPath) -ceq $expectedCandidateDllSha256
) 'phase3b2_ranking_prefix_v9_candidate_drifted'
$sourceRows = @(Get-Content -LiteralPath $sourceManifestPath -Encoding UTF8)
Assert-True (
    (Get-Item -LiteralPath $sourceManifestPath).Length -eq
        $expectedSourceManifestByteLength -and
    (Get-Sha256Hex $sourceManifestPath) -ceq $expectedSourceManifestSha256 -and
    $sourceRows.Count -eq $expectedSourceManifestRowCount
) 'phase3b2_ranking_prefix_v9_source_manifest_drifted'
$sourceRootWithSeparator = [IO.Path]::GetFullPath($externalRoot).TrimEnd(
    [IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
foreach ($row in $sourceRows) {
    $parts = @($row -split "`t")
    Assert-True (
        $parts.Count -eq 3 -and
        $parts[0] -cmatch '^[A-Za-z0-9._/-]+$' -and
        $parts[1] -cmatch '^[1-9][0-9]*$' -and
        $parts[2] -cmatch '^[0-9a-f]{64}$'
    ) 'phase3b2_ranking_prefix_v9_source_manifest_row_invalid'
    $sourcePath = [IO.Path]::GetFullPath((Join-Path `
        $externalRoot ($parts[0].Replace('/', '\'))))
    Assert-True (
        $sourcePath.StartsWith(
            $sourceRootWithSeparator,
            [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $sourcePath -PathType Leaf) -and
        (Get-Item -LiteralPath $sourcePath).Length -eq [long]$parts[1] -and
        (Get-Sha256Hex $sourcePath) -ceq $parts[2]
    ) 'phase3b2_ranking_prefix_v9_source_drifted'
}

Assert-True (
    -not (Test-Path -LiteralPath $targetRuntimeRoot) -and
    -not (Test-Path -LiteralPath $targetEvidenceRoot) -and
    -not (Test-Path -LiteralPath $targetDeploymentRoot) -and
    @($targetToolPaths.Values | Where-Object {
            Test-Path -LiteralPath $_
        }).Count -eq 0
) 'phase3b2_ranking_prefix_v9_target_collision'

$parentFingerprintBefore = Get-ParentFingerprint `
    -RuntimeRoot $parentRuntimeRoot -ToolPaths $parentToolPaths
$priorDotnetHome = $env:DOTNET_CLI_HOME
$priorNugetPackages = $env:NUGET_PACKAGES
$priorSkipFirstTime = $env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE
try {
    $env:DOTNET_CLI_HOME = Join-Path $repositoryRoot '.dotnet-cli-home'
    $env:NUGET_PACKAGES = Join-Path $repositoryRoot '.nuget-packages'
    $env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
    Push-Location $externalRoot
    try {
        $dotnetVersion = (& $DotnetPath --version 2>&1 | Out-String).Trim()
        $testOutput = (& $DotnetPath test `
            'tests\EpinelPS.SelectedManager.Tests\EpinelPS.SelectedManager.Tests.csproj' `
            --no-restore --configuration Release `
            '-p:ManagePackageVersionsCentrally=false' `
            '-p:IncludeSourceRevisionInInformationalVersion=false' `
            2>&1 | Out-String).Trim()
        $testExitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
}
finally {
    $env:DOTNET_CLI_HOME = $priorDotnetHome
    $env:NUGET_PACKAGES = $priorNugetPackages
    $env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = $priorSkipFirstTime
}
Assert-True ($dotnetVersion -cmatch '^10\.') `
    'phase3b2_ranking_prefix_v9_dotnet_sdk_unsupported'
Assert-True ($testExitCode -eq 0 -and $testOutput -match '114') `
    'phase3b2_ranking_prefix_v9_selected_manager_tests_failed'
Assert-True (
    (Get-Item -LiteralPath $candidateDllPath).Length -eq
        $expectedCandidateDllByteLength -and
    (Get-Sha256Hex $candidateDllPath) -ceq $expectedCandidateDllSha256
) 'phase3b2_ranking_prefix_v9_post_test_candidate_drifted'

$derivedToolTexts = [ordered]@{}
foreach ($role in $parentToolPaths.Keys) {
    $text = [IO.File]::ReadAllText(
        [string]$parentToolPaths[$role], [Text.Encoding]::UTF8)
    $text = $text.Replace(
        'EpinelPS-SoloRaidDamageSourceObserver-v8',
        'EpinelPS-SoloRaidRankingPrefix-v9')
    $text = $text.Replace(
        'SoloRaidDamageSourceObserver-v8',
        'SoloRaidRankingPrefix-v9')
    $text = $text.Replace(
        'solo-raid-damage-source-observer-start/v8',
        'solo-raid-ranking-prefix-start/v9')
    $text = $text.Replace(
        'solo-raid-damage-source-observer-failure/v8',
        'solo-raid-ranking-prefix-failure/v9')
    $text = $text.Replace(
        'solo-raid-damage-source-observer-completion/v8',
        'solo-raid-ranking-prefix-completion/v9')
    $text = $text.Replace(
        'solo-raid-damage-source-observer-validation/v8',
        'solo-raid-ranking-prefix-validation/v9')
    $text = $text.Replace(
        'solo-raid-damage-source-observer-marker-evidence/v8',
        'solo-raid-ranking-prefix-marker-evidence/v9')
    $text = $text.Replace('phase3b2_damage_source_observer_v8',
        'phase3b2_ranking_prefix_v9')
    $text = $text.Replace('damage_source_observer_v8', 'ranking_prefix_v9')
    $text = $text.Replace('P3SRDSO8', 'P3SRRP9')
    $text = $text.Replace(
        'start-phase3b2-epinel-solo-raid-damage-source-observer-v8-in-micron.ps1',
        'start-phase3b2-epinel-solo-raid-ranking-prefix-v9-in-micron.ps1')
    $text = $text.Replace(
        'complete-phase3b2-epinel-solo-raid-damage-source-observer-v8-in-micron.ps1',
        'complete-phase3b2-epinel-solo-raid-ranking-prefix-v9-in-micron.ps1')
    $text = $text.Replace('15392256L', '15398400L')
    $text = $text.Replace(
        $expectedParentHashes.serverDll, $expectedCandidateDllSha256)
    $text = $text.Replace(
        '4a0a1f71fe9b7a235703293d6a9c6adb9626ab18b0a8d8daf885c01008fe1f02',
        $expectedSourceManifestSha256)
    $derivedToolTexts[$role] = $text
}

$completionText = [string]$derivedToolTexts.innerCompletion
$prefixDeclarationBefore =
    '$authoritativeScore = [long]$trialMetricsAfter.totalDamage'
$prefixDeclarationAfter = @'
$authoritativeScore = [long]$trialMetricsAfter.totalDamage
$rankingWirePrefix = __RANKING_WIRE_PREFIX__L
Assert-True (
    $authoritativeScore -le ([long]::MaxValue - $rankingWirePrefix)
) 'phase3b2_ranking_prefix_v9_wire_overflow'
$expectedRankingWireScore = $authoritativeScore + $rankingWirePrefix
'@.TrimEnd([char[]]"`r`n").Replace(
    '__RANKING_WIRE_PREFIX__', [string]$rankingWirePrefix)
$wireReplacements = [ordered]@{
    $prefixDeclarationBefore = $prefixDeclarationAfter
    '[long]$finalCompletedScoreResponse.userDamage -eq $authoritativeScore' =
        '[long]$finalCompletedScoreResponse.userDamage -eq $expectedRankingWireScore'
    '[long]$_.trialDamage -ne $authoritativeScore' =
        '[long]$_.trialDamage -ne $expectedRankingWireScore'
    '[long]$_.rankingDamage -ne $authoritativeScore -or' =
        '[long]$_.rankingDamage -ne $expectedRankingWireScore -or'
    '[long]$_.userDamage -ne $authoritativeScore -or' =
        '[long]$_.userDamage -ne $expectedRankingWireScore -or'
    '    authoritativeFiveDeckScore = $authoritativeScore' = @'
    authoritativeFiveDeckScore = $authoritativeScore
    rankingWirePrefix = $rankingWirePrefix
    expectedRankingWireScore = $expectedRankingWireScore
'@.TrimEnd([char[]]"`r`n")
}
foreach ($before in $wireReplacements.Keys) {
    $completionText = Replace-ExactlyOnce `
        -Text $completionText `
        -Before ([string]$before) `
        -After ([string]$wireReplacements[$before]) `
        -FailureCode 'phase3b2_ranking_prefix_v9_completion_contract_invalid'
}
$derivedToolTexts.innerCompletion = $completionText

$derivedTools = @()
foreach ($role in $derivedToolTexts.Keys) {
    $text = [string]$derivedToolTexts[$role]
    Assert-PowerShellTextSyntax -Text $text `
        -FailureCode ('phase3b2_ranking_prefix_v9_tool_syntax_invalid:' + $role)
    Assert-True (
        -not $text.Contains('SoloRaidDamageSourceObserver-v8') -and
        -not $text.Contains('solo-raid-damage-source-observer') -and
        -not $text.Contains('P3SRDSO8') -and
        -not $text.Contains($expectedParentHashes.serverDll)
    ) ('phase3b2_ranking_prefix_v9_parent_reference_retained:' + $role)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($text)
    $derivedTools += [ordered]@{
        roleCode = $role
        leaf = [string]$targetToolNames[$role]
        byteLength = $bytes.Length
        sha256 = Get-TextSha256Hex $text
    }
}

$audit = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-epinel-solo-raid-ranking-prefix-audit/v9'
    auditedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    parentLaneCode = 'epinel_solo_raid_damage_source_observer_v8'
    derivedLaneCode = 'epinel_solo_raid_ranking_prefix_v9'
    parentFingerprintSha256 = $parentFingerprintBefore
    sourceManifestMemberCount = $sourceRows.Count
    sourceManifestSha256 = $expectedSourceManifestSha256
    candidateServerDllByteLength = $expectedCandidateDllByteLength
    candidateServerDllSha256 = $expectedCandidateDllSha256
    selectedManagerPassedCount = 114
    selectedManagerFailedCount = 0
    rankingWirePrefix = $rankingWirePrefix
    prefixResolutionCode = 'selected_manager_common_i_vii_full_hp_v1'
    responseSemanticsChanged = $true
    responseSemanticsCode = 'ranking_wire_domain_encoded_common_prefix'
    rawDamageSemanticsChanged = $false
    persistedChallengeDamageRemainsRaw = $true
    rankingWireFieldsAreCumulative = $true
    normalPrefixResolvedFromStaticData = $true
    parentV8ReadOnly = $true
    officialInstallModified = $false
    deployable = $true
}
if ($AuditOnly) {
    [pscustomobject]@{
        Audit = $audit
        DerivedTools = $derivedTools
        TestOutput = $testOutput
    } | ConvertTo-Json -Depth 12
    exit 0
}

$deploymentUid = [Guid]::NewGuid().ToString()
$runtimeStagingRoot = $targetRuntimeRoot + '.staging-' + $deploymentUid
$deploymentStagingRoot = $targetDeploymentRoot + '.staging-' + $deploymentUid
$toolStagingRoot = Join-Path $toolRoot ('.ranking-prefix-v9-' + $deploymentUid)
$runtimeCommitted = $false
$evidenceCommitted = $false
$deploymentCommitted = $false
$installedTools = [Collections.Generic.List[string]]::new()
$ownedRollbackPaths = @(
    $runtimeStagingRoot,
    $deploymentStagingRoot,
    $toolStagingRoot,
    $targetRuntimeRoot,
    $targetEvidenceRoot,
    $targetDeploymentRoot
)
foreach ($path in $ownedRollbackPaths) {
    $fullPath = [IO.Path]::GetFullPath($path)
    $allowedRoot = if ($fullPath.StartsWith(
            'C:\NLL\Runtime\', [StringComparison]::OrdinalIgnoreCase)) {
        'C:\NLL\Runtime\'
    }
    elseif ($fullPath.StartsWith(
            'C:\NLL\Tools\', [StringComparison]::OrdinalIgnoreCase)) {
        'C:\NLL\Tools\'
    }
    elseif ($fullPath.StartsWith(
            'C:\NLL\E\', [StringComparison]::OrdinalIgnoreCase)) {
        'C:\NLL\E\'
    }
    else { $null }
    Assert-True (
        $null -ne $allowedRoot -and
        $fullPath.Length -gt $allowedRoot.Length -and
        (Split-Path -Leaf $fullPath) -cmatch
            '^(EpinelPS-SoloRaidRankingPrefix-v9|P3SRRP9D?|\.ranking-prefix-v9-)(\.staging-[0-9a-f-]+)?[0-9a-f-]*$'
    ) 'phase3b2_ranking_prefix_v9_rollback_path_invalid'
}

try {
    New-Item -ItemType Directory -Path $runtimeStagingRoot | Out-Null
    foreach ($entry in @(Get-ChildItem -LiteralPath $parentRuntimeRoot -Force)) {
        if ($entry.Name -in @(
                'cache',
                'logs',
                'EpinelPS.dll',
                'epinelps.db',
                'epinelps.db-shm',
                'epinelps.db-wal'
            )) { continue }
        Copy-Item -LiteralPath $entry.FullName -Destination $runtimeStagingRoot `
            -Recurse
    }
    Copy-Item -LiteralPath $candidateDllPath `
        -Destination (Join-Path $runtimeStagingRoot 'EpinelPS.dll')
    New-Item -ItemType Directory -Path (Join-Path $runtimeStagingRoot 'logs') |
        Out-Null
    New-ExactJunction -Path (Join-Path $runtimeStagingRoot 'cache') `
        -Target $cacheTarget

    New-Item -ItemType Directory -Path $toolStagingRoot | Out-Null
    foreach ($role in $derivedToolTexts.Keys) {
        Write-Utf8NoBom (Join-Path $toolStagingRoot $targetToolNames[$role]) `
            ([string]$derivedToolTexts[$role])
    }
    New-Item -ItemType Directory -Path $deploymentStagingRoot | Out-Null
    Copy-Item -LiteralPath $sourceManifestPath `
        -Destination (Join-Path $deploymentStagingRoot 'source.manifest.tsv')
    Write-AtomicJson (Join-Path $deploymentStagingRoot 'audit.receipt.json') $audit

    Move-Item -LiteralPath $runtimeStagingRoot -Destination $targetRuntimeRoot
    $runtimeCommitted = $true
    New-Item -ItemType Directory -Path $targetEvidenceRoot | Out-Null
    $evidenceCommitted = $true
    foreach ($role in $targetToolPaths.Keys) {
        $target = [string]$targetToolPaths[$role]
        Move-Item -LiteralPath (Join-Path $toolStagingRoot $targetToolNames[$role]) `
            -Destination $target
        $installedTools.Add($target)
    }
    Remove-Item -LiteralPath $toolStagingRoot -Force
    Move-Item -LiteralPath $deploymentStagingRoot `
        -Destination $targetDeploymentRoot
    $deploymentCommitted = $true

    $targetCache = Get-Item -LiteralPath (Join-Path $targetRuntimeRoot 'cache') `
        -Force
    Assert-True (
        (Get-Sha256Hex (Join-Path $targetRuntimeRoot 'db.json')) -ceq
            $expectedParentHashes.database -and
        (Get-Sha256Hex (Join-Path $targetRuntimeRoot 'EpinelPS.exe')) -ceq
            $expectedParentHashes.serverExe -and
        (Get-Item -LiteralPath (Join-Path $targetRuntimeRoot 'EpinelPS.dll')).Length -eq
            $expectedCandidateDllByteLength -and
        (Get-Sha256Hex (Join-Path $targetRuntimeRoot 'EpinelPS.dll')) -ceq
            $expectedCandidateDllSha256 -and
        (Get-Sha256Hex (Join-Path $targetRuntimeRoot 'log4net.config')) -ceq
            $expectedParentHashes.logConfig -and
        (Get-Item -LiteralPath (Join-Path $targetDeploymentRoot `
                    'source.manifest.tsv')).Length -eq
            $expectedSourceManifestByteLength -and
        (Get-Sha256Hex (Join-Path $targetDeploymentRoot `
                    'source.manifest.tsv')) -ceq
            $expectedSourceManifestSha256 -and
        $targetCache.LinkType -ceq 'Junction' -and
        [string]$targetCache.Target -ceq $cacheTarget
    ) 'phase3b2_ranking_prefix_v9_post_deploy_runtime_invalid'
    foreach ($tool in $derivedTools) {
        $path = Join-Path $toolRoot ([string]$tool.leaf)
        Assert-True (
            (Get-Item -LiteralPath $path).Length -eq [long]$tool.byteLength -and
            (Get-Sha256Hex $path) -ceq [string]$tool.sha256
        ) 'phase3b2_ranking_prefix_v9_post_deploy_tool_invalid'
    }
    $parentFingerprintAfter = Get-ParentFingerprint `
        -RuntimeRoot $parentRuntimeRoot -ToolPaths $parentToolPaths
    Assert-True ($parentFingerprintAfter -ceq $parentFingerprintBefore) `
        'phase3b2_ranking_prefix_v9_parent_mutated'

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-solo-raid-ranking-prefix-deployment/v9'
        deployedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        deploymentUid = $deploymentUid
        parentLaneCode = 'epinel_solo_raid_damage_source_observer_v8'
        derivedLaneCode = 'epinel_solo_raid_ranking_prefix_v9'
        parentFingerprintSha256 = $parentFingerprintBefore
        sourceManifestMemberCount = $sourceRows.Count
        sourceManifestSha256 = $expectedSourceManifestSha256
        parentServerDllSha256 = $expectedParentHashes.serverDll
        appliedServerDllByteLength = $expectedCandidateDllByteLength
        appliedServerDllSha256 = $expectedCandidateDllSha256
        selectedManagerPassedCount = 114
        selectedManagerFailedCount = 0
        rankingWirePrefix = $rankingWirePrefix
        prefixResolutionCode = 'selected_manager_common_i_vii_full_hp_v1'
        responseSemanticsChanged = $true
        responseSemanticsCode =
            'ranking_wire_domain_encoded_common_prefix'
        rawDamageSemanticsChanged = $false
        persistedChallengeDamageRemainsRaw = $true
        netTrialSoloRaidDamageRemainsRaw = $true
        rankerSquadLogsRemainRaw = $true
        rankingWireFieldsAreCumulative = $true
        completionVerifierSeparatesRawAndWireDomains = $true
        verifiesEncodedRankingWire = $true
        parentV8Modified = $false
        officialInstallModified = $false
        databaseModified = $false
        cacheModified = $false
        installedTools = $derivedTools
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        validationRunConsumed = $false
        rollbackCode = 'leave_v9_inert_and_select_untouched_repaired_v8'
        nextStepCode = 'bind_control_center_to_sealed_v9_then_run_actual_client'
    }
    Write-AtomicJson (Join-Path $targetDeploymentRoot 'deployment.receipt.json') `
        $receipt
    [pscustomobject]@{
        Receipt = $receipt
        ReceiptPath = Join-Path $targetDeploymentRoot 'deployment.receipt.json'
        ReceiptSha256 = Get-Sha256Hex (
            Join-Path $targetDeploymentRoot 'deployment.receipt.json')
        RuntimeRoot = $targetRuntimeRoot
        EvidenceRoot = $targetEvidenceRoot
    } | ConvertTo-Json -Depth 12
}
catch {
    foreach ($path in @($installedTools)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force
        }
    }
    foreach ($path in @(
            $toolStagingRoot,
            $deploymentStagingRoot,
            $runtimeStagingRoot,
            $(if ($deploymentCommitted) { $targetDeploymentRoot }),
            $(if ($evidenceCommitted) { $targetEvidenceRoot }),
            $(if ($runtimeCommitted) { $targetRuntimeRoot })
        )) {
        if (-not [string]::IsNullOrWhiteSpace([string]$path) -and
            (Test-Path -LiteralPath $path)) {
            Remove-Item -LiteralPath $path -Recurse -Force
        }
    }
    throw
}
