#requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateSet('Challenge', 'Practice')]
    [string]$ValidationKind = 'Challenge'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Set-ExecutionPolicy -Scope Process Bypass -Force

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

$serverRoot = 'C:\NLL\Runtime\EpinelPS-SoloRaidTrialPractice-v1'
$evidenceRoot = 'C:\NLL\E\P3SRTP1'
$innerStartPath =
    'C:\NLL\Tools\start-phase3b2-epinel-solo-raid-trial-practice-v1-in-micron.ps1'
$expectedDatabaseByteLength = 1396709L
$expectedDatabaseSha256 =
    'dee9c6aa5421287ca030e325b81a90a302a5d9e113d57c3065e5d36f6e7c4019'
$expectedServerExeByteLength = 162304L
$expectedServerExeSha256 =
    'a28c7ff227a74d260a29389b82caeed3fe196f91eef3d28cabe9977b5ed9d07b'
$expectedServerDllByteLength = 15377408L
$expectedServerDllSha256 =
    'a28965089f0fcf68d063e6d36fe137e19e68b8618bc01e2e1008c51b18fc64ef'
$derivedSourceManifestSha256 =
    '1c58deb41bef14e2d8c64699198e291898238319155c3cbd1b05f9d4f2fd54e5'
$expectedHeaderByteLength = 139L
$expectedHeaderSha256 =
    '5914cb58fd2146fe761ab531ecb4e321300527186a54b455e59de962ff6c044a'
$expectedCatalogContractSha256 =
    '4e7903d912b3859691864b22a75a53e80881c744bd0fbee9e375036142d65654'
$expectedSausContractSha256 =
    '0a29dc7d5bfbfd53cba8735029f9fbcc708834d678c7e51ea5a84b234fc3a65d'

$databasePath = Join-Path $serverRoot 'db.json'
$serverExePath = Join-Path $serverRoot 'EpinelPS.exe'
$serverDllPath = Join-Path $serverRoot 'EpinelPS.dll'
$cacheLinkPath = Join-Path $serverRoot 'cache'
$expectedCacheTarget =
    'C:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\cache'
$headerPath = Join-Path $expectedCacheTarget `
    'prdenv\150-b059c3f36c\StandaloneWindows64\pck\latest-651.txt'
$headerUrl =
    'https://cloud.nikke-kr.com/prdenv/150-b059c3f36c/StandaloneWindows64/pck/latest-651.txt'
$catalogContractPath =
    'C:\NLL\Evidence\Phase3B2\Physical\epinel-native-cache-catalog-transport-v1\catalog-transport.contract.json'
$sausContractPath =
    'C:\NLL\Evidence\Phase3B2\Physical\epinel-saus-pair-staging-v1\saus-http-pair.contract.json'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
Assert-True ($principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    'phase3b2_solo_raid_trial_practice_start_requires_administrator'
Assert-True ($env:SystemDrive -ceq 'C:' -and $env:USERNAME -ceq 'nlloperator') `
    'phase3b2_solo_raid_trial_practice_start_wrong_operator_or_boot_boundary'

$requiredFiles = @(
    $innerStartPath, $databasePath, $serverExePath, $serverDllPath,
    $catalogContractPath, $sausContractPath, $headerPath
)
Assert-True (@($requiredFiles | Where-Object {
            -not (Test-Path -LiteralPath $_ -PathType Leaf)
        }).Count -eq 0) `
    'phase3b2_solo_raid_trial_practice_start_input_missing'
Assert-True (
    (Get-Item -LiteralPath $databasePath).Length -eq
        $expectedDatabaseByteLength -and
    (Get-Sha256Hex $databasePath) -ceq $expectedDatabaseSha256 -and
    (Get-Item -LiteralPath $serverExePath).Length -eq
        $expectedServerExeByteLength -and
    (Get-Sha256Hex $serverExePath) -ceq $expectedServerExeSha256 -and
    (Get-Item -LiteralPath $serverDllPath).Length -eq
        $expectedServerDllByteLength -and
    (Get-Sha256Hex $serverDllPath) -ceq $expectedServerDllSha256 -and
    (Get-Item -LiteralPath $headerPath).Length -eq
        $expectedHeaderByteLength -and
    (Get-Sha256Hex $headerPath) -ceq $expectedHeaderSha256 -and
    (Get-Sha256Hex $catalogContractPath) -ceq
        $expectedCatalogContractSha256 -and
    (Get-Sha256Hex $sausContractPath) -ceq $expectedSausContractSha256
) 'phase3b2_solo_raid_trial_practice_start_content_drifted'

$database = Get-Content -LiteralPath $databasePath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True (
    @($database.Users).Count -eq 1 -and
    [int]$database.Users[0].userPointData.UserLevel -eq 893 -and
    [int]$database.Users[0].LastNormalStageCleared -eq 6048044 -and
    [int]$database.Users[0].LastHardStageCleared -eq 7048044 -and
    [int]$database.Users[0].LastStoryStageCleared -eq 8048044
) 'phase3b2_solo_raid_trial_practice_start_parent_state_invalid'

$cacheLink = Get-Item -LiteralPath $cacheLinkPath -Force `
    -ErrorAction SilentlyContinue
Assert-True (
    $null -ne $cacheLink -and $cacheLink.LinkType -ceq 'Junction' -and
    [string]$cacheLink.Target -ceq $expectedCacheTarget
) 'phase3b2_solo_raid_trial_practice_start_cache_link_invalid'

$runDirectories = @(
    Get-ChildItem -LiteralPath $evidenceRoot -Directory `
        -ErrorAction SilentlyContinue
)
if ($ValidationKind -ceq 'Challenge') {
    Assert-True ($runDirectories.Count -eq 0) `
        'phase3b2_solo_raid_trial_practice_challenge_already_consumed'
}
else {
    Assert-True ($runDirectories.Count -eq 1) `
        'phase3b2_solo_raid_trial_practice_practice_requires_one_challenge_run'
    $priorCompletionPath = Join-Path $runDirectories[0].FullName `
        'completion.receipt.json'
    Assert-True (Test-Path -LiteralPath $priorCompletionPath -PathType Leaf) `
        'phase3b2_solo_raid_trial_practice_prior_completion_missing'
    $priorCompletion = Get-Content -LiteralPath $priorCompletionPath -Raw `
        -Encoding UTF8 | ConvertFrom-Json
    Assert-True (
        $priorCompletion.contractId -ceq
            'nll/phase3b2-epinel-solo-raid-trial-practice-completion/v1' -and
        $priorCompletion.outcomeCode -ceq 'success' -and
        [string]$priorCompletion.observedStageCode -in @(
            'season26_challenge_squad',
            'season26_challenge_battle',
            'battle_result'
        ) -and
        $priorCompletion.databaseRestored -and
        $priorCompletion.runtimeColdAfterCompletion
    ) 'phase3b2_solo_raid_trial_practice_challenge_not_accepted'
}

$runIntentCode = $ValidationKind.ToLowerInvariant()
$startText = (& $innerStartPath `
    -ServerRoot $serverRoot `
    -EvidenceRoot $evidenceRoot `
    -DerivedSourceManifestSha256 $derivedSourceManifestSha256 `
    -RunIntentCode $runIntentCode `
    -RequiredLocalAssetUrl $headerUrl `
    -RequiredLocalAssetByteLength $expectedHeaderByteLength `
    -RequiredLocalAssetSha256 $expectedHeaderSha256 `
    -RequiredLocalCatalogContractPath $catalogContractPath `
    -RequiredLocalCatalogContractSha256 $expectedCatalogContractSha256 `
    -RequiredLocalSausContractPath $sausContractPath `
    -RequiredLocalSausContractSha256 $expectedSausContractSha256 |
    Out-String).Trim()
$start = $startText | ConvertFrom-Json
Assert-True (
    $start.contractId -ceq
        'nll/phase3b2-epinel-solo-raid-trial-practice-start/v1' -and
    [Guid]::Parse([string]$start.assessmentUid) -ne [Guid]::Empty -and
    $start.runIntentCode -ceq $runIntentCode -and
    $start.derivedSourceManifestSha256 -ceq
        $derivedSourceManifestSha256 -and
    -not $start.historicalReceiptBindingApplied -and
    -not $start.selfHashBindingApplied -and
    $start.serverRunning -and $start.physicalBootstrapRunning -and
    $start.clientExecutionStarted -and
    [int]$start.successfulNonLoopbackConnectionCount -eq 0 -and
    $start.requiredLocalAssetPreflightPerformed -and
    $start.requiredLocalCatalogPreflightPerformed -and
    $start.requiredLocalSausPreflightPerformed
) 'phase3b2_solo_raid_trial_practice_start_inner_receipt_invalid'

[pscustomobject]@{
    StartReceipt = $start
    Validation = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-solo-raid-trial-practice-validation/v1'
        validationKind = $runIntentCode
        validationOrdinal = if ($runIntentCode -ceq 'challenge') { 1 } else { 2 }
        maximumValidationRunCount = 2
        deploymentReceiptBindingApplied = $false
        wrapperSelfHashBindingApplied = $false
        goldenRuntimeModified = $false
        nextStepCode = if ($runIntentCode -ceq 'challenge') {
            'enter_challenge_squad_or_battle_close_client_then_complete'
        } else {
            'enter_practice_squad_or_battle_close_client_then_complete'
        }
    }
    CompletionCommand =
        "& 'C:\NLL\Tools\Complete-Phase3B2-Epinel-SoloRaidTrialPractice-v1.ps1' -ObservedStageCode <stage> -OutcomeCode <outcome>"
} | ConvertTo-Json -Depth 9
