# Read-only configuration preparation shared by the UI query and coordinator.
# This is NOT account readiness, runtime coldness or permission to start a game.
. (Join-Path $PSScriptRoot 'Nll.PhaseDRuntimeBundle.ps1')
function Read-PhaseDPreparationJson {
    param([string]$Path, [string]$FailureCode)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw $FailureCode }
    if ((Get-Item -LiteralPath $Path).Length -gt 1048576) { throw $FailureCode }
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -gt 1048576) { throw $FailureCode }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    [pscustomobject]@{ value = ([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json); sha256 = $hash; length = $bytes.Length; path = $Path }
}
function Resolve-PhaseDPreparedShieldFx {
    param([object]$Profile, [string]$TargetElement)
    # Format/selection only. Full profile validation and installed delivery remain
    # mandatory at admission; this function never makes Get-PhaseDPreparation ready.
    if ($Profile.schemaVersion -ne 4) { return $null }
    if ($Profile.elementShield.modeCode -ceq 'none') { return $null }
    $plan = $Profile.shieldFxPreparation
    if ($plan.contractId -cne 'nll/boss-shield-fx-preparation/v1' -or
        $plan.policyCode -cnotin @('source_shield_size_candidate/v2', 'source_shield_size_candidate/v3') -or
        $plan.sourceBossElementCode -cne $Profile.sourceAffinity.bossElementCode -or
        $plan.recipeManifestSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'phase_d_boss_variant_profile_invalid' }
    $rows = @($plan.variants | Where-Object { $_.bossElementCode -ceq $TargetElement })
    $target = @($Profile.elementShield.fxVariants | Where-Object { $_.bossElementCode -ceq $TargetElement })
    if ($target.Count -ne 1 -or $rows.Count -ne @($target[0].mappings).Count) { throw 'phase_d_boss_variant_profile_invalid' }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($row in $rows) {
        $mapping = @($target[0].mappings | Where-Object { $_.sourceFxPrefabSetSha256 -ceq $row.sourceFxPrefabSetSha256 })
        if (-not $seen.Add($row.sourceFxPrefabSetSha256) -or $mapping.Count -ne 1 -or
            $mapping[0].targetFxPrefabSetSha256 -cne $row.targetFxPrefabSetSha256 -or
            @($mapping[0].assetBundles).Count -ne 1 -or
            $mapping[0].assetBundles[0].sha256 -cne $row.targetBundle.sha256 -or
            $mapping[0].assetBundles[0].byteLength -ne $row.targetBundle.byteLength -or
            $row.operationCode -cnotin @('reuse', 'adjust_candidate') -or
            $row.outputBundle.sha256 -cnotmatch '^[0-9a-f]{64}$' -or $row.outputBundle.byteLength -le 0) {
            throw 'phase_d_boss_variant_profile_invalid'
        }
        if ($row.operationCode -ceq 'reuse' -and
            ($row.targetBundle.sha256 -cne $row.outputBundle.sha256 -or
             $row.targetBundle.byteLength -ne $row.outputBundle.byteLength)) { throw 'phase_d_boss_variant_profile_invalid' }
    }
    [pscustomobject]@{ recipeManifestSha256 = $plan.recipeManifestSha256; variants = $rows }
}
function Resolve-PhaseDBossAffinity {
    param([object]$Profile, [string]$WeaknessCode)
    # Pure selection from existing profile fields. This does not validate asset
    # contents, decide transform requirements, or grant runtime admission.
    $targetByWeakness = @{ fire = 'wind'; water = 'fire'; wind = 'iron'; electric = 'water'; iron = 'electric' }
    $elements = @('fire', 'water', 'wind', 'electric', 'iron')
    if ($WeaknessCode -cnotin $elements) { throw 'phase_d_launch_request_invalid' }
    try {
        $sourceElement = [string]$Profile.sourceAffinity.bossElementCode
        $sourceWeakness = [string]$Profile.sourceAffinity.weaknessCode
        if ($sourceElement -cnotin $elements -or $sourceWeakness -cnotin $elements -or
            $targetByWeakness[$sourceWeakness] -cne $sourceElement) { throw 'phase_d_boss_variant_profile_invalid' }
        $targetElement = $targetByWeakness[$WeaknessCode]
        $variants = @(); $sourceFx = $null; $targetFx = $null
        if ($Profile.elementShield.modeCode -ceq 'dynamic_affinity_linked') {
            $variants = @($Profile.elementShield.fxVariants)
            $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            if ($variants.Count -ne $elements.Count) { throw 'phase_d_boss_variant_element_shield_fx_unresolved' }
            foreach ($variant in $variants) {
                if ($variant.bossElementCode -cnotin $elements -or -not $seen.Add($variant.bossElementCode) -or
                    @($variant.mappings).Count -eq 0) { throw 'phase_d_boss_variant_element_shield_fx_unresolved' }
                foreach ($mapping in $variant.mappings) {
                    if ($mapping.sourceKindCode -cnotin @('boss_specific', 'common') -or
                        $mapping.sourceFxPrefabSetSha256 -cnotmatch '^[0-9a-f]{64}$' -or
                        $mapping.targetFxPrefabSetSha256 -cnotmatch '^[0-9a-f]{64}$' -or
                        @($mapping.assetBundles).Count -eq 0) { throw 'phase_d_boss_variant_element_shield_fx_unresolved' }
                    foreach ($bundle in $mapping.assetBundles) {
                        if ($bundle.sha256 -cnotmatch '^[0-9a-f]{64}$' -or $bundle.byteLength -le 0) {
                            throw 'phase_d_boss_variant_element_shield_fx_unresolved'
                        }
                    }
                }
            }
            $sourceFx = @($variants | Where-Object { $_.bossElementCode -ceq $sourceElement })[0]
            $targetFx = @($variants | Where-Object { $_.bossElementCode -ceq $targetElement })[0]
        }
        elseif ($Profile.elementShield.modeCode -cne 'none') { throw 'phase_d_boss_variant_element_shield_fx_unresolved' }
        [pscustomobject]@{
            sourceBossElementCode = $sourceElement; sourceWeaknessCode = $sourceWeakness
            selectedWeaknessCode = $WeaknessCode; targetBossElementCode = $targetElement
            shieldFxVariants = $variants; sourceShieldFxVariant = $sourceFx; targetShieldFxVariant = $targetFx
            preparedShieldFx = $(if ($Profile.PSObject.Properties.Name -contains 'schemaVersion') {
                Resolve-PhaseDPreparedShieldFx -Profile $Profile -TargetElement $targetElement
            } else { $null })
        }
    }
    catch {
        if ($_.Exception.Message -cin @('phase_d_boss_variant_profile_invalid', 'phase_d_boss_variant_element_shield_fx_unresolved')) { throw }
        throw 'phase_d_boss_variant_profile_invalid'
    }
}
function Get-PhaseDPreparation {
    param([string]$RepositoryRoot, [int]$SeasonNumber, [string]$WeaknessCode,
        [string]$RuntimeSelectionPath = 'C:\NLL\ControlCenter\runtime-selection.private.json',
        [switch]$StageDelivery)
    $result = [ordered]@{
        schemaVersion = 1; contractId = 'nll/phase-d-preparation/v1'
        seasonNumber = $SeasonNumber; weaknessCode = $WeaknessCode
        statusCode = 'blocked'; failureCode = $null; bindingSha256 = $null
        clientBuildCode = $null; plan = $null
    }
    try {
        if ($SeasonNumber -le 0 -or $WeaknessCode -cnotin @('fire', 'water', 'wind', 'electric', 'iron')) { throw 'phase_d_launch_request_invalid' }
        $selectedBundle = Read-PdRuntimeBundle $RuntimeSelectionPath -FilePinsOnly
        $selectedBundleSha256 = if ($null -ne $selectedBundle) { Get-PdBundleHash $selectedBundle.manifestPath } else { $null }
        $configRoot = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'config/boss-runtime-variants')).TrimEnd('\')
        if ($null -ne $selectedBundle -and $selectedBundle.PSObject.Properties.Name -ccontains 'commonBossRegistryRoot') {
            $configRoot = [IO.Path]::GetFullPath([string]$selectedBundle.commonBossRegistryRoot).TrimEnd('\')
            if ($configRoot -cne 'C:\NLL\RuntimeInputs\CommonBossExecution\profiles') { throw 'phase_d_boss_variant_registry_invalid' }
        }
        $registry = Read-PhaseDPreparationJson (Join-Path $configRoot 'registry.json') 'phase_d_boss_variant_registry_missing'
        if ($registry.value.contractId -cne 'nll/boss-runtime-variant-registry/v1' -or $registry.value.schemaVersion -ne 1) { throw 'phase_d_boss_variant_registry_invalid' }
        $entries = @($registry.value.profiles | Where-Object { $_.seasonNumber -eq $SeasonNumber -and $_.operationalStatusCode -ceq 'enabled' })
        if ($entries.Count -ne 1) { throw 'phase_d_boss_variant_profile_not_enabled' }
        $entry = $entries[0]
        $relativePath = [string]$entry.profileRelativePath
        if ([IO.Path]::IsPathRooted($relativePath) -or $relativePath.Contains(':')) { throw 'phase_d_boss_variant_profile_path_invalid' }
        $profilePath = [IO.Path]::GetFullPath((Join-Path $configRoot $relativePath))
        if (-not $profilePath.StartsWith($configRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'phase_d_boss_variant_profile_path_invalid' }
        for ($path = $profilePath; $path -ine $configRoot; $path = [IO.Path]::GetDirectoryName($path)) {
            if ((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'phase_d_boss_variant_profile_path_invalid' }
        }
        $profile = Read-PhaseDPreparationJson $profilePath 'phase_d_boss_variant_profile_path_invalid'
        if ($profile.sha256 -cne $entry.profileSha256) { throw 'phase_d_boss_variant_profile_drifted' }
        $boss = $profile.value
        if (-not (($boss.schemaVersion -eq 1 -and $boss.contractId -ceq 'nll/boss-runtime-variant-profile/v1') -or
            ($boss.schemaVersion -eq 2 -and $boss.contractId -ceq 'nll/boss-runtime-variant-profile/v2') -or
            ($boss.schemaVersion -eq 4 -and $boss.contractId -ceq 'nll/boss-runtime-variant-profile/v4')) -or
            $boss.seasonNumber -ne $SeasonNumber -or $boss.profileCode -cne $entry.profileCode) { throw 'phase_d_boss_variant_profile_invalid' }
        $affinity = Resolve-PhaseDBossAffinity -Profile $boss -WeaknessCode $WeaknessCode
        $targetElement = $affinity.targetBossElementCode
        $fx = @(); if ($null -ne $affinity.targetShieldFxVariant) { $fx = @($affinity.targetShieldFxVariant) }
        $selection = if (Test-Path -LiteralPath $RuntimeSelectionPath) {
            Read-PhaseDPreparationJson $RuntimeSelectionPath 'phase_d_bundle_selection_invalid'
        } else { $null }
        # UI checks local pins only; the coordinator additionally verifies the
        # applied overlay/firewall at activation, just as before.
        $bundle = $selectedBundle
        $bundleHash = $selectedBundleSha256
        if ($null -ne $bundle -and (Get-PdBundleHash $bundle.manifestPath) -cne $bundleHash) { throw 'phase_d_preparation_changed' }
        if ($null -ne $selection -and (Get-PdBundleHash $RuntimeSelectionPath) -cne $selection.sha256) { throw 'phase_d_preparation_changed' }
        if (($null -eq $selection) -ne ($null -eq $bundle)) { throw 'phase_d_preparation_changed' }
        if ($null -ne $selection -and $selection.value.manifest.sha256 -cne $bundleHash) { throw 'phase_d_preparation_changed' }
        $delivery = $null
        if ($boss.schemaVersion -eq 4 -or $entry.PSObject.Properties.Name -contains 'delivery') {
            if ($null -eq $bundle -or $entry.PSObject.Properties.Name -cnotcontains 'delivery') {
                throw 'phase_d_boss_runtime_delivery_required'
            }
            $delivery = $entry.delivery
            Assert-PdBundlePin $delivery
            if (-not $StageDelivery) {
                $validator = Join-Path $bundle.materializerRoot 'NikkeLocalLab.PhaseD.RuntimeMaterializer.exe'
                $validationOutput = @(& $validator --validate-common-boss-delivery true --delivery-path $delivery.path `
                    --delivery-sha256 $delivery.sha256 --boss-variant-profile $profile.path --weakness-code $WeaknessCode `
                    --full-delivery-verification false --require-native-fx-baseline true 2>&1)
                if ($LASTEXITCODE -ne 0) { throw 'phase_d_boss_runtime_delivery_invalid' }
                $validation = ($validationOutput -join "`n") | ConvertFrom-Json
                if ($validation.statusCode -cne 'prepared' -or $validation.profileSha256 -cne $profile.sha256) {
                    throw 'phase_d_boss_runtime_delivery_invalid'
                }
            }
        }
        $build = if ($null -ne $bundle) { [string]$bundle.clientBuildCode } else { 'build_150.6.9' }
        $binding = [ordered]@{
            contractId = 'nll/phase-d-preparation-binding/v1'; seasonNumber = $SeasonNumber; weaknessCode = $WeaknessCode
            registrySha256 = $registry.sha256; profileSha256 = $profile.sha256; clientBuildCode = $build
            selectionSha256 = if ($selection) { $selection.sha256 } else { $null }; bundleSha256 = $bundleHash
        } | ConvertTo-Json -Compress
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $result.bindingSha256 = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($binding)))).Replace('-', '').ToLowerInvariant() }
        finally { $sha.Dispose() }
        $result.clientBuildCode = $build
        $result.plan = [pscustomobject]@{ registry = $registry; profile = $profile; bundle = $bundle; selectionSha256 = $(if ($selection) { $selection.sha256 } else { $null }); bundleSha256 = $bundleHash; affinity = $affinity; targetElementCode = $targetElement; shieldFxVariants = $fx; commonDelivery = $delivery }
        $result.statusCode = 'ready'
    }
    catch {
        $code = $_.Exception.Message
        $result.failureCode = if ($code -cmatch '^phase_d_[a-z0-9_]{3,120}$') { $code } else { 'phase_d_preparation_invalid' }
    }
    [pscustomobject]$result
}
function ConvertTo-PhaseDPreparationProjection {
    param([object]$Preparation)
    # Never return paths, profiles, original resource fields or raw exceptions.
    [ordered]@{
        schemaVersion = 1; contractId = 'nll/phase-d-preparation/v1'
        seasonNumber = $Preparation.seasonNumber; weaknessCode = $Preparation.weaknessCode
        statusCode = $Preparation.statusCode; failureCode = $Preparation.failureCode
        bindingSha256 = $Preparation.bindingSha256; clientBuildCode = $Preparation.clientBuildCode
    }
}

function Assert-PhaseDDatabaseBinding {
    param([object]$Preparation, [string]$ConnectionEnvironment = 'NIKKE_LAB_DB')
    if ($Preparation.statusCode -cne 'ready' -or $null -eq $Preparation.plan.bundle) { return }
    # UI and coordinator use this same small DB lookup after file preparation.
    # Immutable profile bindings need no large client verification or DB writes.
    $tool = Join-Path $Preparation.plan.bundle.materializerRoot 'NikkeLocalLab.PhaseD.RuntimeMaterializer.exe'
    $capture = & {
        $ErrorActionPreference = 'Continue'
        $PSNativeCommandUseErrorActionPreference = $false
        $global:LASTEXITCODE = $null
        $output = @(& $tool --verify-common-boss-database true --boss-variant-profile $Preparation.plan.profile.path `
            --connection-string-env $ConnectionEnvironment 2>&1)
        [pscustomobject]@{Output=$output;ExitCode=$global:LASTEXITCODE}
    }
    if ($null -eq $capture.ExitCode -or $capture.ExitCode -ne 0) {
        $code = @($capture.Output | ForEach-Object { [string]$_ } | Where-Object { $_ -cmatch '^phase_d_[a-z0-9_]{3,120}$' }) | Select-Object -Last 1
        if (-not $code) { $code = 'phase_d_boss_database_binding_unavailable' }
        throw $code
    }
    $receipt = ($capture.Output -join "`n") | ConvertFrom-Json
    if ($receipt.statusCode -cne 'registered') { throw 'phase_d_boss_database_binding_invalid' }
}
