param([Parameter(Mandatory)][string]$PlanPath, [int[]]$Seasons = @())
# CLIENT_UPDATE step 8: rebuild every registered boss from the new sources with the common pipeline, in the order and
# conditions of scripts/invoke-nll-boss-onboarding-job.ps1 (candidate -> native candidate -> common delivery).
# Database registration and registry publication happen in the install step; the live registry is only read.
# Outputs go to plan.workRoot\bosses (acquisition refuses outputs under C:\NLL). Re-running skips sealed deliveries.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.ClientUpdate.ps1')
$plan = Read-NllClientUpdatePlan $PlanPath
function Hash([string]$Path) { Get-NllClientUpdateHash $Path }
function Need([bool]$Value, [string]$Code) { Assert-NllClientUpdate $Value $Code }
$scripts = Join-Path $plan.repositoryRoot 'scripts'
. (Join-Path $scripts 'Nll.BossNativeCandidate.ps1')
. (Join-Path $scripts 'Nll.CommonBossDelivery.ps1')

$bundle = Get-Content (Join-Path $plan.runtimeRoot 'bundle.private.json') -Raw | ConvertFrom-Json
Need ($bundle.clientBuildCode -ceq ('build_' + $plan.build)) 'bundle_invalid'
$server = [string]$bundle.serverRoot
$materializer = Join-Path $bundle.materializerRoot 'NikkeLocalLab.PhaseD.RuntimeMaterializer.exe'
$gameConfig = Join-Path $server 'gameconfig.json'
$cfg = Get-Content $gameConfig -Raw | ConvertFrom-Json
$cache = Join-Path $server 'cache'
$pack = Join-Path $cache ([Uri]$cfg.StaticDataMpk.Url).AbsolutePath.TrimStart('/')
$activeConfig = Get-Content ((Get-Content 'C:\NLL\ControlCenter\boss-pipeline.active.json' -Raw | ConvertFrom-Json).configurationPath) -Raw | ConvertFrom-Json
$python = [string]$activeConfig.pythonPath
$unityPy = [string]$activeConfig.unityPyRoot
$seed = Join-Path $plan.repositoryRoot 'tests\fixtures\synthetic\boss-variant-discovery-seed.json'
$registryRoot = 'C:\NLL\RuntimeInputs\CommonBossExecution\profiles'
$out = Join-Path $plan.workRoot 'bosses'
New-Item -ItemType Directory -Path $out -Force | Out-Null
$dotnet = (Get-Command dotnet -CommandType Application).Source
$nativePlan = Join-Path $plan.pipelineInputsRoot 'native-input-plan.private.json'
$tool = Join-Path $plan.pipelineInputsRoot 'catalog-tool\ResourceCatalogPreflight.dll'
$native = [pscustomobject][ordered]@{ inputPlanPath = $nativePlan; inputPlanSha256 = (Hash $nativePlan); catalogToolPath = $tool
    catalogToolSha256 = (Hash $tool); dotnetPath = $dotnet; dotnetSha256 = (Hash $dotnet) }
$store = $bundle.commonNativeStore
$registry = Get-Content (Join-Path $registryRoot 'registry.json') -Raw | ConvertFrom-Json
$rows = @()
foreach ($entry in $registry.profiles) {
    $season = [int]$entry.seasonNumber
    if ($Seasons.Count -and $season -notin $Seasons) { continue }
    $oldPath = Join-Path $registryRoot $entry.profileRelativePath
    Need ((Hash $oldPath) -ceq $entry.profileSha256) 'registered_profile_drift'
    $old = Get-Content $oldPath -Raw | ConvertFrom-Json
    $jobRoot = Join-Path $out ("season$season")
    $candidate = Join-Path $jobRoot 'candidate'
    $sealPath = Join-Path $candidate 'onboarding-verified-candidate.receipt.json'
    if (-not (Test-Path $sealPath)) {
        Need (-not (Test-Path $candidate)) 'partial_candidate_requires_review'
        New-Item -ItemType Directory -Path $jobRoot -Force | Out-Null
        & (Join-Path $scripts 'invoke-nll-boss-onboarding.ps1') -CandidateOnly -SeasonNumber $season -ProfileCode $entry.profileCode `
            -DisplayNameCode $old.displayNameCode -MaterializerPath $materializer -StaticDataPackPath $pack -GameConfigPath $gameConfig `
            -SourceDatabasePath $seed -AssetCacheRoot $cache -PythonPath $python -UnityPyRoot $unityPy -OutputRoot $candidate `
            -RegistryRoot $registryRoot -NativeConfiguration $native -FxSourceCacheRoot (Join-Path $out 'fx-source-cache') *> (Join-Path $jobRoot 'candidate.log')
    }
    $seal = Get-Content $sealPath -Raw | ConvertFrom-Json
    Need ($seal.contractId -ceq 'nll/boss-onboarding-verified-candidate/v1' -and $seal.seasonNumber -eq $season -and
        $seal.profileCode -ceq $entry.profileCode -and $seal.affinityVariantCount -eq 5 -and $seal.runtimeAdmissionStatusCode -ceq 'not_assessed') 'candidate_invalid'
    $profilePath = Join-Path $candidate 'boss-runtime-variant.profile.json'
    $profile = Get-Content $profilePath -Raw | ConvertFrom-Json
    $nativeRequired = $profile.schemaVersion -eq 3 -or ($profile.schemaVersion -eq 4 -and $profile.elementShield.modeCode -ceq 'dynamic_affinity_linked' -and
        @($profile.shieldFxPreparation.variants | Where-Object operationCode -CEQ 'adjust_candidate').Count -gt 0)
    $existingDelivery = Join-Path $jobRoot 'common-delivery\delivery.private.json'
    if (Test-Path $existingDelivery) {
        $delivery = [ordered]@{ path = $existingDelivery; length = (Get-Item $existingDelivery).Length; sha256 = (Hash $existingDelivery) }
    } else {
        if ($nativeRequired) {
            $fxCache = if (Test-Path (Join-Path $candidate 'acquired-fx') -PathType Container) { Join-Path $candidate 'acquired-fx' } else { $cache }
            $null = New-NllBossNativeCandidate -Configuration $native -JobRoot $jobRoot -CandidateRoot $candidate `
                -CandidateReceiptSha256 (Hash $sealPath) -NativeStore $store -PythonPath $python -UnityPyRoot $unityPy -CacheRoot $fxCache
        }
        $delivery = New-NllCommonBossDelivery -CandidateRoot $candidate -NativeRoot $jobRoot -NativeStore $store -MaterializerPath $materializer `
            -OutputRoot (Join-Path $jobRoot 'common-delivery')
    }
    # Same rule as the materializer's update equivalence: observation source and behavior bundle origin are archive origins.
    $same = $true; $differing = @()
    foreach ($k in @('seasonNumber', 'selectedManagerObservation', 'challengeSelector', 'sourceAffinity', 'skillClosure', 'behaviorAssembly', 'quickTimeEventAffinity')) {
        $av = if ($old.PSObject.Properties.Name -contains $k) { $old.$k } else { $null }
        $bv = if ($profile.PSObject.Properties.Name -contains $k) { $profile.$k } else { $null }
        $origin = @{ selectedManagerObservation = @('sourceObservationSha256'); behaviorAssembly = @('bundleSha256', 'bundleByteLength') }
        if ($origin.ContainsKey($k) -and $null -ne $av -and $null -ne $bv) {
            $av = $av | ConvertTo-Json -Depth 40 | ConvertFrom-Json; $bv = $bv | ConvertTo-Json -Depth 40 | ConvertFrom-Json
            foreach ($name in $origin[$k]) { $av.PSObject.Properties.Remove($name); $bv.PSObject.Properties.Remove($name) }
        }
        if (($av | ConvertTo-Json -Depth 40 -Compress) -cne ($bv | ConvertTo-Json -Depth 40 -Compress)) { $same = $false; $differing += $k }
    }
    $row = [ordered]@{ seasonNumber = $season; profileCode = $entry.profileCode; candidateRoot = $candidate; profilePath = $profilePath
        profileSha256 = (Hash $profilePath); schemaVersion = $profile.schemaVersion; nativeCandidate = $nativeRequired; delivery = $delivery
        previousProfilePath = $oldPath; equivalentCombatSource = $same; differingFields = $differing; databaseChanged = $false; registryChanged = $false }
    Write-NllClientUpdateJson (Join-Path $jobRoot 'rebuild.receipt.json') $row
    $rows += $row
    Write-Output ("Season {0}: delivery {1}, equivalent combat source {2} {3}" -f $season, $delivery.sha256.Substring(0, 12), $same, ($differing -join ','))
}
Write-NllClientUpdateJson (Join-Path $out ('rebuild-' + [DateTime]::UtcNow.ToString('yyyyMMddHHmmss') + '.receipt.json')) @{ status = 'prepared_not_published'; bosses = $rows }
