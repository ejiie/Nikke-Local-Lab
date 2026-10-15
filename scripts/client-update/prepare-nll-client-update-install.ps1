param([Parameter(Mandatory)][string]$PlanPath, [Parameter(Mandatory)][string]$ExpectedHead)
# CLIENT_UPDATE step 10b (cold, non-elevated, from the fast-forwarded main checkout). Seals every candidate the elevated
# install applies: pipeline configuration, season catalog, registry candidate, database registration plan, app delivery
# plan that activates the configuration, and the hash-pinned elevated launcher. Changes no active state.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.ClientUpdate.ps1')
$plan = Read-NllClientUpdatePlan $PlanPath
$repo = $plan.repositoryRoot
$install = 'C:\NLL\ControlCenter'
$registryRoot = 'C:\NLL\RuntimeInputs\CommonBossExecution\profiles'
$runtimeWork = Join-Path $plan.workRoot 'runtime'
$appWork = Join-Path $plan.workRoot 'app'
$official = Join-Path $plan.officialRoot 'Unity\com_proximabeta_NIKKE\com.shiftup.patch'
function Hash([string]$Path) { Get-NllClientUpdateHash $Path }
function Require([bool]$Value, [string]$Code) { Assert-NllClientUpdate $Value $Code }
function Json([string]$Path, $Value) { Write-NllClientUpdateJson $Path $Value }
function Cold {
    Require (@(Get-Process -Name nikke, nikke_launcher, EpinelPS, postgres, 'NikkeLocalLab.Admin.Api', 'NLL Control Center',
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap' -ErrorAction SilentlyContinue).Count -eq 0) 'runtime_not_cold'
    Require (@(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object LocalPort -in 17878, 55433).Count -eq 0) 'listener_present'
    $executions = Join-Path $repo 'artifacts/automation/phase-d-executions'
    foreach ($file in @(Get-ChildItem -LiteralPath $executions -Recurse -File -Filter 'execution-state.json' -ErrorAction SilentlyContinue)) {
        $state = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
        Require ($state.statusCode -cin @('completed', 'failed', 'rolled_back')) ('unfinished_execution_' + $file.Directory.Name)
    }
}
Require ($PSVersionTable.PSVersion.Major -ge 7) 'pwsh_required'
Require ((git -C $repo rev-parse HEAD).Trim() -ceq $ExpectedHead) 'repository_head_changed'
Require (@(git -C $repo status --porcelain --untracked-files=no).Count -eq 0) 'repository_dirty'
Cold
. (Join-Path $repo 'scripts/Nll.ResourceNative.ps1')
. (Join-Path $repo 'scripts/Nll.PhaseDRuntimeBundle.ps1')
. (Join-Path $repo 'scripts/Nll.BossPublication.ps1')
. (Join-Path $repo 'scripts/Nll.ControlCenterDelivery.ps1')
Require (-not (Test-Path $runtimeWork) -and -not (Test-Path $appWork)) 'preparation_exists'
New-Item -ItemType Directory -Path $runtimeWork, $appWork | Out-Null

# 0. Before images of every pointer the install replaces, and the selected candidate bundle.
$selectionPath = Join-Path $install 'runtime-selection.private.json'
$activationPath = Join-Path $install 'boss-pipeline.active.json'
Copy-Item -LiteralPath $selectionPath -Destination (Join-Path $runtimeWork 'selection.before.json')
Copy-Item -LiteralPath $activationPath -Destination (Join-Path $runtimeWork 'activation.before.json')
Copy-Item -LiteralPath (Join-Path $registryRoot 'registry.json') -Destination (Join-Path $runtimeWork 'registry.before.json')
$activation = Get-NllBossPipelineActivation $install $repo
$activeConfigPath = [string](Get-Content $activationPath -Raw | ConvertFrom-Json).configurationPath
Require ((Hash $activeConfigPath) -ceq $activation.sha256) 'activation_drifted'
$old = Get-Content $activeConfigPath -Raw | ConvertFrom-Json
$selectionNext = Join-Path $runtimeWork 'selection-next.private.json'
Copy-Item -LiteralPath (Join-Path $plan.stagingRoot "selection-$($plan.build).private.json") -Destination $selectionNext
$b = Read-PdRuntimeBundle $selectionNext -BeforeActivation
Require ($b.clientBuildCode -ceq ('build_' + $plan.build)) 'bundle_invalid'
$mat = Join-Path $b.materializerRoot 'NikkeLocalLab.PhaseD.RuntimeMaterializer.exe'
$serverConfig = Join-Path $b.serverRoot 'gameconfig.json'
$cache = Join-Path $b.serverRoot 'cache'
$packs = @($b.files | Where-Object { [IO.Path]::GetFileName([string]$_.path) -ceq 'StaticData.pack' })
Require ($packs.Count -eq 1) 'pack_ambiguous'
$pack = [string]$packs[0].path
$nativePlan = Join-Path $plan.pipelineInputsRoot 'native-input-plan.private.json'
$tool = Join-Path $plan.pipelineInputsRoot 'catalog-tool\ResourceCatalogPreflight.dll'
$dotnet = (Get-Command dotnet -CommandType Application).Source
$python = [string]$old.pythonPath

# 1. Pipeline configuration: version-bound paths move to the new bundle, clone inputs and the official install.
$c = $old | ConvertTo-Json -Depth 90 | ConvertFrom-Json
$oldMatDir = Split-Path ([string]$old.materializerPath) -Parent
$oldToolDir = Split-Path ([string]$old.nativePipeline.catalogToolPath) -Parent
$oldRuntime = Split-Path $oldMatDir -Parent
$c.materializerPath = $mat; $c.staticDataPackPath = $pack; $c.gameConfigPath = $serverConfig; $c.assetCacheRoot = $cache
$c.nativePipeline.inputPlanPath = $nativePlan; $c.nativePipeline.inputPlanSha256 = Hash $nativePlan
$c.nativePipeline.catalogToolPath = $tool; $c.nativePipeline.catalogToolSha256 = Hash $tool
$c.nativePipeline.dotnetPath = $dotnet; $c.nativePipeline.dotnetSha256 = Hash $dotnet
$c.commonDelivery.nativeStore = $b.commonNativeStore
# The Temp pack can be an NLL weakness variant; season intake reads the verified official pack of the selected bundle.
$c.seasonSync.sourcePackPath = $pack
$c.seasonSync.localeSourcePath = Join-Path $official 'saus'
$c.seasonSync.materializerPath = $mat
$c.characterSync.materializerPath = $mat
$c.characterSync.gameConfigArchivePath = Join-Path $plan.officialRoot 'NIKKE\game\nikke_Data\StreamingAssets\sd.bin'
$c.characterSync.toolPins = @($c.characterSync.toolPins | Where-Object { -not ([string]$_.path).StartsWith($oldMatDir + '\', [StringComparison]::OrdinalIgnoreCase) }) +
    @([pscustomobject]@{ path = $mat; sha256 = (Hash $mat) })
$c.bossImageExtraction.sourceRoot = Join-Path $official 'dp'

# 2. Season catalog. New seasons go through the normal sync; without them the same rows are rebound to the new pack
# after re-deriving them from that pack (the job runner requires catalog.sourceStaticDataSha256 = pinned pack).
Require ((Hash $old.catalogPath) -ceq $old.catalogSha256) 'catalog_drifted'
$previous = Get-Content $old.catalogPath -Raw | ConvertFrom-Json
$runs = Join-Path (Split-Path $old.jobsRoot -Parent) 'season-sync\runs'
$run = Join-Path $runs ("update-$($plan.build)-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run | Out-Null
$locales = Join-Path $run 'locales'
$sausBody = Join-Path $official 'saus\catalog.ndb'
& $dotnet $tool stage-boss-catalog-locales (Join-Path $official 'saus') $locales (Hash $sausBody) (Hash ($sausBody + '.nds')) *> (Join-Path $run 'locales.log')
Require ($LASTEXITCODE -eq 0) 'locales_unreadable'
try {
    & $mat --export-local-boss-season-catalog (Join-Path $run 'localized') --static-pack $pack --game-config $serverConfig --locale-root $locales *> (Join-Path $run 'localized.log')
    Require ($LASTEXITCODE -eq 0) 'catalog_unreadable'
} finally { [IO.Directory]::Delete([IO.Path]::GetFullPath($locales), $true) }
$derived = Get-Content (Join-Path $run 'localized\catalog.json') -Raw | ConvertFrom-Json
if ($derived.maximumKnownSeason -gt $previous.maximumKnownSeason) {
    $candidatePath = Join-Path $runtimeWork 'catalog-candidate.private.json'
    Json $candidatePath $c
    $syncRun = Join-Path $runs ("update-$($plan.build)-sync-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $syncRun | Out-Null
    & $c.seasonSync.scriptPath -ConfigurationPath $candidatePath -ExpectedConfigurationSha256 (Hash $candidatePath) -SourcePackPath $pack `
        -LocaleSourcePath $c.seasonSync.localeSourcePath -CatalogMaterializerPath $mat -OutputRoot $syncRun
    $result = Get-Content (Join-Path $syncRun 'sync-result.json') -Raw | ConvertFrom-Json
    Require ($result.statusCode -ceq 'updated') 'season_sync_not_updated'
    $catalogPath = [string](Get-Content $result.configurationPath -Raw | ConvertFrom-Json).catalogPath
    Require ((Get-Content $catalogPath -Raw | ConvertFrom-Json).sourceStaticDataSha256 -ceq (Hash $pack)) 'season_sync_pack_binding_invalid'
    $catalogMode = 'season_sync'
} else {
    Require ($derived.maximumKnownSeason -eq $previous.maximumKnownSeason -and @($derived.seasons).Count -eq @($previous.seasons).Count) 'season_set_changed'
    foreach ($row in $previous.seasons) {
        $match = @($derived.seasons | Where-Object seasonNumber -EQ $row.seasonNumber)
        Require ($match.Count -eq 1) 'season_missing'
        foreach ($name in @('defaultWeaknessCode', 'discoveryStatusCode', 'failureCode')) {
            Require (($match[0].$name | ConvertTo-Json -Compress) -ceq ($row.$name | ConvertTo-Json -Compress)) ('season_changed_' + $row.seasonNumber)
        }
    }
    $presentation = Join-Path $run 'presentation'
    New-Item -ItemType Directory -Path (Join-Path $presentation 'images') | Out-Null
    foreach ($row in $previous.seasons | Where-Object imageStatusCode -CEQ 'resolved') {
        $image = Join-Path (Split-Path $old.catalogPath -Parent) ('images/' + $row.imageSha256 + '.png')
        Require ((Hash $image) -ceq $row.imageSha256) 'image_changed'
        Copy-Item -LiteralPath $image -Destination (Join-Path $presentation ('images/' + $row.imageSha256 + '.png')) -Force
    }
    $previousImageSource = Join-Path (Split-Path $old.catalogPath -Parent) 'image-source.json'
    if (Test-Path $previousImageSource) { Copy-Item -LiteralPath $previousImageSource -Destination (Join-Path $presentation 'image-source.json') }
    $catalog = $previous | ConvertTo-Json -Depth 40 | ConvertFrom-Json
    $catalog.sourceStaticDataSha256 = Hash $pack
    $catalogPath = Join-Path $presentation 'catalog.json'
    Json $catalogPath $catalog
    $catalogMode = 'rebound_without_season_change'
}
Json (Join-Path $run 'catalog.receipt.json') ([ordered]@{ statusCode = $catalogMode; previousCatalogSha256 = $old.catalogSha256
    catalogPath = $catalogPath; catalogSha256 = (Hash $catalogPath); sourceStaticDataSha256 = (Hash $pack) })
$c.catalogPath = $catalogPath; $c.catalogSha256 = Hash $catalogPath

# 3. Input pins: drop the old materializer/tool/plan/catalog, map old runtime files to the new runtime where they exist.
$pins = [ordered]@{}
$dropped = @()
foreach ($pin in $old.inputPins) {
    $path = [string]$pin.path
    if ($path.StartsWith($oldMatDir + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $path.StartsWith($oldToolDir + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $path -ieq [string]$old.nativePipeline.inputPlanPath -or $path -ieq [string]$old.catalogPath) { continue }
    if ($path.StartsWith($oldRuntime + '\', [StringComparison]::OrdinalIgnoreCase)) {
        $mapped = Join-Path $plan.runtimeRoot $path.Substring($oldRuntime.Length + 1)
        if ($path -ieq [string]$old.staticDataPackPath) { $mapped = $pack }
        if (-not (Test-Path -LiteralPath $mapped -PathType Leaf)) { $dropped += $path; continue }
        $path = $mapped
    }
    Require (Test-Path -LiteralPath $path -PathType Leaf) ('pin_missing_' + [IO.Path]::GetFileName($path))
    $pins[$path] = $true
}
foreach ($file in Get-ChildItem $b.materializerRoot -File | Where-Object { $_.Extension -in '.exe', '.dll', '.json' }) { $pins[$file.FullName] = $true }
foreach ($file in Get-ChildItem (Split-Path $tool -Parent) -File) { $pins[$file.FullName] = $true }
foreach ($path in @($nativePlan, $pack, $serverConfig, $catalogPath)) { $pins[$path] = $true }
$c.inputPins = @($pins.Keys | Sort-Object | ForEach-Object { [pscustomobject][ordered]@{ path = $_; sha256 = (Hash $_) } })
# Re-pin every <x>Path/<x>Sha256 pair and path/sha256 node to the file it names (this file has no record-only nodes).
function Repin($node) {
    if ($null -eq $node -or $node -is [string] -or $node -is [ValueType]) { return }
    if ($node -is [System.Array]) { foreach ($n in $node) { Repin $n }; return }
    $names = @($node.PSObject.Properties.Name)
    if ($names -ccontains 'path' -and $names -ccontains 'sha256' -and $node.path -is [string] -and (Test-Path -LiteralPath $node.path -PathType Leaf)) {
        $node.sha256 = Hash $node.path
        if ($names -ccontains 'length') { $node.length = (Get-Item -LiteralPath $node.path).Length }
    }
    foreach ($name in $names) {
        if ($name.EndsWith('Sha256') -and $name.Length -gt 6) {
            $base = $name.Substring(0, $name.Length - 6)
            if ($names -ccontains ($base + 'Path') -and $node.($base + 'Path') -is [string] -and (Test-Path -LiteralPath $node.($base + 'Path') -PathType Leaf)) {
                $node.$name = Hash $node.($base + 'Path')
            }
        }
        Repin $node.$name
    }
}
Repin $c
$c.powerShellSha256 = Hash $c.powerShellPath
$c.workerSha256 = Hash (Join-Path $repo 'scripts\invoke-nll-boss-onboarding-job.ps1')
$configPath = Join-Path $runtimeWork 'configuration.private.json'
Json $configPath $c
$check = & $python -I (Join-Path $PSScriptRoot 'check-nll-config-pins.py') $configPath | Select-Object -Last 1 | ConvertFrom-Json
Require (($check.counts.PSObject.Properties.Name -join ',') -ceq 'ok') 'configuration_pin_not_live'

# 4. Registry candidate and database registration plan from the rebuilt bosses.
$registryNext = Join-Path $runtimeWork 'registry-next'
New-Item -ItemType Directory -Path $registryNext | Out-Null
foreach ($file in Get-ChildItem $registryRoot -File -Filter '*.json') { Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $registryNext $file.Name) }
$liveRegistry = Get-Content (Join-Path $registryRoot 'registry.json') -Raw | ConvertFrom-Json
$rows = @()
foreach ($entry in $liveRegistry.profiles) {
    $season = [int]$entry.seasonNumber
    $receipt = Get-Content (Join-Path $plan.workRoot ("bosses\season$season\rebuild.receipt.json")) -Raw | ConvertFrom-Json
    $candidate = [string]$receipt.candidateRoot
    $profilePath = Join-Path $candidate 'boss-runtime-variant.profile.json'
    Require ((Hash $profilePath) -ceq $receipt.profileSha256 -and (Hash $receipt.delivery.path) -ceq $receipt.delivery.sha256) 'rebuilt_boss_drifted'
    $seal = Get-Content (Join-Path $candidate 'onboarding-verified-candidate.receipt.json') -Raw | ConvertFrom-Json
    $validationLines = @(& $mat --validate-boss-variant-profile $profilePath)
    Require ($LASTEXITCODE -eq 0) ('profile_invalid_' + $season)
    $validation = $validationLines[-1] | ConvertFrom-Json
    $artifactPins = @{}; foreach ($pin in $seal.artifacts) { $artifactPins[(Join-Path $candidate $pin.relativePath)] = $pin.sha256 }
    $variants = @(foreach ($w in @('fire', 'water', 'wind', 'electric', 'iron')) {
        $p = Join-Path $candidate "five-affinity-variants/$w.receipt.json"; $v = Get-Content $p -Raw | ConvertFrom-Json
        [ordered]@{ weaknessCode = $w; targetBossElementCode = $v.targetBossElementCode; variantRequired = $v.variantRequired
            modifiedMonsterRecordCount = $v.modifiedMonsterRecordCount; modifiedFunctionRecordCount = $v.modifiedFunctionRecordCount; receiptSha256 = (Hash $p) }
    })
    Publish-NllBossProfile -ProfilePath $profilePath -Validation $validation -VariantReceipts $variants -ArtifactPins $artifactPins `
        -RegistryRoot $registryNext -ExpectedRegistrySha256 (Hash (Join-Path $registryNext 'registry.json')) `
        -AdmissionReceiptPath (Join-Path $candidate "$($plan.build)-admission.receipt.json") -ReplaceExistingProfile `
        -DeliveryPin $receipt.delivery -MaterializerPath $mat | Out-Null
    $rows += [ordered]@{ seasonNumber = $season; profilePath = $profilePath; profileSha256 = (Hash $profilePath); delivery = $receipt.delivery
        previousProfilePath = (Join-Path $registryRoot $entry.profileRelativePath); equivalentCombatSource = [bool]$receipt.equivalentCombatSource }
}
$nextRegistry = Get-Content (Join-Path $registryNext 'registry.json') -Raw | ConvertFrom-Json
Require (@($nextRegistry.profiles).Count -eq @($liveRegistry.profiles).Count -and
    @($nextRegistry.profiles | Where-Object operationalStatusCode -CNE 'enabled').Count -eq 0) 'registry_candidate_invalid'
Json (Join-Path $runtimeWork 'registration-plan.private.json') $rows

# 5. Admin API app and a delivery plan that activates the new configuration.
$app = Join-Path $appWork 'publish'
& dotnet publish (Join-Path $repo 'src/NikkeLocalLab.Admin.Api/NikkeLocalLab.Admin.Api.csproj') -c Release -o $app *> (Join-Path $appWork 'app-build.log')
Require ($LASTEXITCODE -eq 0) 'app_publish_failed'
& (Join-Path $repo 'scripts/prepare-nll-control-center-app-package.ps1') -PublishedRoot $app -OutputRoot (Join-Path $appWork 'app-package')
$package = Get-Content (Join-Path $appWork 'app-package/receipt.json') -Raw | ConvertFrom-Json
Require ($package.wholeAppRoundTripVerified -and $package.repeatedApplyRestoreVerified -and $package.addedFileRetirementVerified -and
    -not $package.installedFilesModified) 'app_rehearsal_invalid'
$protected = @([ordered]@{ path = [string]$b.manifestPath; pin = (Get-NllAppPin ([string]$b.manifestPath)) })
$delivery = New-NllControlCenterDeliveryPlan $install (Join-Path $appWork 'app-package/sealed-package') `
    $package.packageManifestSha256 $configPath (Hash $configPath) (Join-Path $repo 'scripts/start-nll-phase-d-control-center.ps1') `
    (Join-Path $appWork 'delivery') $protected
Write-NllAppNewJson (Join-Path $appWork 'delivery-preparation.receipt.json') $delivery

# 6. Preparation receipt (hashes only; the install derives paths from the plan) and the hash-pinned elevated launcher.
$prepared = [ordered]@{ status = 'prepared_not_installed'; build = $plan.build; repositoryHead = $ExpectedHead
    planSha256 = (Hash $PlanPath); selectionNext = (Get-NllAppPin $selectionNext); bundle = (Get-NllAppPin ([string]$b.manifestPath))
    configuration = (Get-NllAppPin $configPath); catalogPath = $catalogPath; catalog = (Get-NllAppPin $catalogPath); catalogMode = $catalogMode
    droppedRuntimePins = $dropped; registryNext = (Get-NllAppPin (Join-Path $registryNext 'registry.json'))
    registryBefore = (Get-NllAppPin (Join-Path $runtimeWork 'registry.before.json')); registrationPlan = (Get-NllAppPin (Join-Path $runtimeWork 'registration-plan.private.json'))
    deliveryPlanRoot = $delivery.planRoot; deliveryPlanSha256 = $delivery.planSha256
    selectionBefore = (Get-NllAppPin (Join-Path $runtimeWork 'selection.before.json')); activationBefore = (Get-NllAppPin (Join-Path $runtimeWork 'activation.before.json'))
    equivalentSeasons = @($rows | Where-Object equivalentCombatSource | ForEach-Object seasonNumber); resourceGuidance = 'not_supplied'
    clientStarted = $false; databaseTouched = $false }
Json (Join-Path $plan.workRoot 'install-preparation.receipt.json') $prepared
$installScript = Join-Path $PSScriptRoot 'install-nll-client-update.ps1'
$launcher = @(
    '$ErrorActionPreference = ''Stop''',
    "# Elevated launcher written by prepare-nll-client-update-install.ps1; refuses a changed install script or plan.",
    "`$script = '$installScript'",
    "`$plan = '$PlanPath'",
    "`$log = '$(Join-Path $plan.workRoot 'installation.log')'",
    "if ((Get-FileHash -LiteralPath `$script).Hash.ToLowerInvariant() -cne '$(Hash $installScript)' -or (Get-FileHash -LiteralPath `$plan).Hash.ToLowerInvariant() -cne '$(Hash $PlanPath)') { exit 2 }",
    'try { & $script -PlanPath $plan *> $log; exit 0 }',
    'catch { [IO.File]::WriteAllText(([IO.Path]::ChangeExtension($log, ''.launch-failure.txt'')), ($_.Exception.Message + '' line '' + $_.InvocationInfo.ScriptLineNumber)); exit 1 }')
[IO.File]::WriteAllText((Join-Path $plan.workRoot 'run-install-uac.ps1'), ($launcher -join "`r`n") + "`r`n", [Text.UTF8Encoding]::new($false))
$prepared | ConvertTo-Json -Depth 6
