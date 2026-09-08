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

$expectedDatabaseByteLength = 1396709L
$expectedDatabaseSha256 =
    'dee9c6aa5421287ca030e325b81a90a302a5d9e113d57c3065e5d36f6e7c4019'
$expectedServerDllSha256 =
    'f602c58985a7a90cd206e2b58d793a4c7c2c0f1ea6ba778d0d74d61d68f9635b'
$expectedHeaderByteLength = 139L
$expectedHeaderSha256 =
    '5914cb58fd2146fe761ab531ecb4e321300527186a54b455e59de962ff6c044a'
$expectedCatalogContractSha256 =
    '4e7903d912b3859691864b22a75a53e80881c744bd0fbee9e375036142d65654'
$expectedSausContractSha256 =
    '0a29dc7d5bfbfd53cba8735029f9fbcc708834d678c7e51ea5a84b234fc3a65d'

$serverRoot = 'C:\NLL\Runtime\EpinelPS-SoloRaidLevel-v1'
$evidenceRoot = 'C:\NLL\E\P3SRL1'
$deploymentPath = 'C:\NLL\E\P3SRL1D\deployment.receipt.json'
$innerStartPath =
    'C:\NLL\Tools\start-phase3b2-epinel-solo-raid-level-v1-in-micron.ps1'
$databasePath = Join-Path $serverRoot 'db.json'
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
    'phase3b2_solo_raid_level_start_requires_administrator'
Assert-True ($env:SystemDrive -ceq 'C:' -and $env:USERNAME -ceq 'nlloperator') `
    'phase3b2_solo_raid_level_start_wrong_operator_or_boot_boundary'

$requiredFiles = @(
    $deploymentPath, $innerStartPath, $databasePath, $serverDllPath,
    $catalogContractPath, $sausContractPath
)
Assert-True (@($requiredFiles | Where-Object {
            -not (Test-Path -LiteralPath $_ -PathType Leaf)
        }).Count -eq 0) 'phase3b2_solo_raid_level_start_input_missing'

$deployment = Get-Content -LiteralPath $deploymentPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True (
    $deployment.contractId -ceq
        'nll/phase3b2-epinel-solo-raid-commander-level-deployment/v1' -and
    [int]$deployment.sourceCommanderLevel -eq 1 -and
    [int]$deployment.appliedCommanderLevel -eq 893 -and
    $deployment.commanderLevelSourceCode -ceq
        'operator_capture_phase_1_initial_load_18_data_player_level' -and
    $deployment.appliedDatabaseSha256 -ceq $expectedDatabaseSha256 -and
    [long]$deployment.appliedDatabaseByteLength -eq
        $expectedDatabaseByteLength -and
    $deployment.onlyUserLevelFieldChanged -and
    -not $deployment.experiencePointFabricated -and
    -not $deployment.parentRuntimeModified -and
    -not $deployment.goldenRuntimeModified -and
    -not $deployment.cacheModified -and
    -not $deployment.dDriveModified
) 'phase3b2_solo_raid_level_start_deployment_contract_invalid'

Assert-True (
    (Get-Item -LiteralPath $databasePath).Length -eq
        $expectedDatabaseByteLength -and
    (Get-Sha256Hex $databasePath) -ceq $expectedDatabaseSha256 -and
    (Get-Sha256Hex $serverDllPath) -ceq $expectedServerDllSha256 -and
    (Get-Sha256Hex $catalogContractPath) -ceq
        $expectedCatalogContractSha256 -and
    (Get-Sha256Hex $sausContractPath) -ceq
        $expectedSausContractSha256
) 'phase3b2_solo_raid_level_start_digest_invalid'

$database = Get-Content -LiteralPath $databasePath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True (
    @($database.Users).Count -eq 1 -and
    [int]$database.Users[0].userPointData.UserLevel -eq 893 -and
    [int]$database.Users[0].userPointData.ExperiencePoint -eq 0
) 'phase3b2_solo_raid_level_start_database_projection_invalid'

$cacheLink = Get-Item -LiteralPath $cacheLinkPath -Force `
    -ErrorAction SilentlyContinue
Assert-True ($null -ne $cacheLink -and $cacheLink.LinkType -ceq 'Junction') `
    'phase3b2_solo_raid_level_start_cache_link_invalid'
$cacheJunctionRebound = $false
if ([string]$cacheLink.Target -cne $expectedCacheTarget) {
    Remove-Item -LiteralPath $cacheLinkPath -Force
    New-Item -ItemType Junction -Path $cacheLinkPath `
        -Target $expectedCacheTarget | Out-Null
    $cacheJunctionRebound = $true
}
$cacheLink = Get-Item -LiteralPath $cacheLinkPath -Force
Assert-True (
    $cacheLink.LinkType -ceq 'Junction' -and
    [string]$cacheLink.Target -ceq $expectedCacheTarget -and
    (Test-Path -LiteralPath $headerPath -PathType Leaf) -and
    (Get-Item -LiteralPath $headerPath).Length -eq $expectedHeaderByteLength -and
    (Get-Sha256Hex $headerPath) -ceq $expectedHeaderSha256
) 'phase3b2_solo_raid_level_start_cache_rebind_failed'

$startText = (& $innerStartPath `
    -ServerRoot $serverRoot `
    -EvidenceRoot $evidenceRoot `
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
    $start.contractId -ceq 'nll/phase3b2-epinel-minimal-reference-start/v1' -and
    [Guid]::Parse([string]$start.assessmentUid) -ne [Guid]::Empty -and
    $start.serverRunning -and $start.physicalBootstrapRunning -and
    $start.clientExecutionStarted -and
    [int]$start.successfulNonLoopbackConnectionCount -eq 0 -and
    $start.requiredLocalAssetPreflightPerformed -and
    $start.requiredLocalCatalogPreflightPerformed -and
    $start.requiredLocalSausPreflightPerformed
) 'phase3b2_solo_raid_level_start_inner_receipt_invalid'

[pscustomobject]@{
    StartReceipt = $start
    CommanderLevelProjection = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-solo-raid-commander-level-run/v1'
        assessmentUid = [string]$start.assessmentUid
        sourceCommanderLevel = 1
        appliedCommanderLevel = 893
        experiencePointChanged = $false
        cacheJunctionRebound = $cacheJunctionRebound
        evidenceRoot = $evidenceRoot
        outerRunBindingWritten = $false
        pathTooLongRegressionPrevented = $true
        nextStepCode =
            'observe_commander_level_then_close_client_and_complete'
    }
    CompletionCommand =
        "& 'C:\NLL\Tools\Complete-Phase3B2-Epinel-SoloRaidLevel-v1.ps1' -ObservedStageCode <stage> -OutcomeCode <outcome>"
} | ConvertTo-Json -Depth 8
