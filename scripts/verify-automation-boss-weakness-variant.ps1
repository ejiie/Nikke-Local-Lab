[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-BossVariant {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Read-RequiredText {
    param([string]$Path)
    Assert-BossVariant (Test-Path -LiteralPath $Path -PathType Leaf) `
        'boss_weakness_automation_required_source_missing'
    [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$html = Read-RequiredText (Join-Path $repositoryRoot `
    'src\NikkeLocalLab.Admin.Api\wwwroot\editor\index.html')
$script = Read-RequiredText (Join-Path $repositoryRoot `
    'src\NikkeLocalLab.Admin.Api\wwwroot\editor\editor.js')
$executionApi = Read-RequiredText (Join-Path $repositoryRoot `
    'src\NikkeLocalLab.Admin.Api\PhaseDExecution.cs')
$coordinator = Read-RequiredText (Join-Path $repositoryRoot `
    'scripts\invoke-nll-phase-d-execution.ps1')
# Preparation moved out of the coordinator in S-04. Verify both owners.
$coordinator += Read-RequiredText (Join-Path $repositoryRoot `
    'scripts\Nll.PhaseDPreparation.ps1')
$coordinator += Read-RequiredText (Join-Path $repositoryRoot `
    'scripts\Nll.PhaseDRunnerStart.ps1')
$materializer = Read-RequiredText (Join-Path $repositoryRoot `
    'tools\NikkeLocalLab.PhaseD.RuntimeMaterializer\BossAffinityStaticDataVariant.cs')
$qteMaterializer = Read-RequiredText (Join-Path $repositoryRoot `
    'tools\NikkeLocalLab.PhaseD.RuntimeMaterializer\BossQuickTimeEventVariant.cs')
$variantProfileCode = Read-RequiredText (Join-Path $repositoryRoot `
    'tools\NikkeLocalLab.PhaseD.RuntimeMaterializer\BossRuntimeVariantProfile.cs')
$variantProfileSchemaPath = Join-Path $repositoryRoot `
    'contracts\boss-runtime-variant-profile.schema.json'
$variantProfileSchema = Read-RequiredText $variantProfileSchemaPath | ConvertFrom-Json
$variantProfileV2SchemaPath = Join-Path $repositoryRoot `
    'contracts\boss-runtime-variant-profile-v2.schema.json'
$variantProfileV2Schema = Read-RequiredText $variantProfileV2SchemaPath | ConvertFrom-Json
$variantRegistrySchemaPath = Join-Path $repositoryRoot `
    'contracts\boss-runtime-variant-registry.schema.json'
$variantRegistrySchema = Read-RequiredText $variantRegistrySchemaPath | ConvertFrom-Json
$variantRegistryPath = Join-Path $repositoryRoot `
    'config\boss-runtime-variants\registry.json'
$variantRegistry = Read-RequiredText $variantRegistryPath | ConvertFrom-Json
$season26VariantProfilePath = Join-Path $repositoryRoot `
    'config\boss-runtime-variants\season-26-providence.json'
$season26VariantProfile = Read-RequiredText $season26VariantProfilePath | ConvertFrom-Json
$season29VariantProfilePath = Join-Path $repositoryRoot `
    'config\boss-runtime-variants\season-29-mother-whale.json'
$season29VariantProfile = Read-RequiredText $season29VariantProfilePath | ConvertFrom-Json
Assert-BossVariant `
    (Test-Json -LiteralPath $variantRegistryPath `
        -SchemaFile $variantRegistrySchemaPath -ErrorAction SilentlyContinue) `
    'boss_weakness_automation_registry_schema_invalid'
Assert-BossVariant `
    (Test-Json -LiteralPath $season26VariantProfilePath `
        -SchemaFile $variantProfileSchemaPath -ErrorAction SilentlyContinue) `
    'boss_weakness_automation_profile_schema_invalid'
# The checked-in S29 v3 draft is deliberately NOT the registered v2 runtime.
# Do not update its registry pin or admit v3 merely to make source CI green.
& (Join-Path $PSScriptRoot 'test-nll-published-boss-preparation.ps1')
$onboarding = Read-RequiredText (Join-Path $repositoryRoot `
    'scripts\invoke-nll-boss-onboarding.ps1')
$behaviorInspector = Read-RequiredText (Join-Path $repositoryRoot `
    'scripts\inspect-nll-boss-behavior-assets.py')
$profileAssembler = Read-RequiredText (Join-Path $repositoryRoot `
    'scripts\materialize-nll-boss-runtime-profile.py')
$shieldAssessment = Read-RequiredText (Join-Path $repositoryRoot 'scripts\nll-shield-fx-assessment.py')
$shieldDiscovery = Read-RequiredText (Join-Path $repositoryRoot `
    'tools\NikkeLocalLab.PhaseD.RuntimeMaterializer\BossShieldPatternDiscovery.cs')
Assert-BossVariant `
    ($profileAssembler.Contains('assess_shield_patterns(') -and
     $profileAssembler.Contains('boss_profile_shield_assessment_review_required') -and
     $onboarding.Contains('--shield-assessment-output $shieldAssessmentPath') -and
     $onboarding.Contains('boss_onboarding_shield_preparation_review_required') -and
     $onboarding.Contains("'nll-shield-fx-assessment.py'") -and
     $shieldAssessment.Contains('full_hierarchy_correspondence_unresolved') -and
     $shieldAssessment.Contains('UseScaleHelper') -and
     $shieldDiscovery.Contains('bodyConditionInheritanceStatusCode = "unresolved"') -and
     $shieldDiscovery.Contains('fxAttachmentKey')) `
    'boss_shield_preparation_assessment_boundary_missing'
$shieldRecipes = Read-RequiredText (Join-Path $repositoryRoot 'scripts\nll-shield-fx-recipes.py')
Assert-BossVariant `
    ($profileAssembler.Contains('recipes.verify_delivery(') -and
     $profileAssembler.Contains('shieldFxRecipesSha256') -and
     $onboarding.Contains('boss_onboarding_shield_recipe_delivery_invalid') -and
     $onboarding.Contains("'nll-shield-fx-recipes.py'") -and
     $shieldRecipes.Contains('source_shield_size_candidate/v2') -and
     $shieldRecipes.Contains('reference_inputs_matched') -and
     $shieldRecipes.Contains('shield_recipe_preservation_failed') -and
     $shieldRecipes.Contains('shield_recipe_receipt_changed') -and
     $shieldRecipes.Contains('exist_ok=False')) `
    'boss_shield_recipe_delivery_boundary_missing'
$assetMaterializer = Read-RequiredText (Join-Path $repositoryRoot `
    'scripts\materialize-nll-phase-d-presentation-assets.ps1')
$repair = Read-RequiredText (Join-Path $repositoryRoot `
    'scripts\repair-nll-phase-d-control-center-application.ps1')
$deploy = Read-RequiredText (Join-Path $repositoryRoot `
    'scripts\deploy-nll-phase-d-control-center-offline.ps1')
$sourceManifestPath = Join-Path $repositoryRoot `
    'scripts\phase-d-weakness-variant-v10.source.manifest.tsv'
$sourceManifest = Read-RequiredText $sourceManifestPath

$codes = @('fire', 'water', 'wind', 'electric', 'iron')
foreach ($code in $codes) {
    Assert-BossVariant `
        ($html.Contains('data-weakness-code="' + $code + '"') -and
         $html.Contains('/editor/assets/ui/code-' + $code + '.png') -and
         $assetMaterializer.Contains("'code-$code.png'")) `
        'boss_weakness_automation_official_icon_contract_invalid'
}
Assert-BossVariant `
    ($script.Contains('weaknessCode: state.selectedWeaknessCode') -and
     $executionApi.Contains('NormalizeWeaknessCode(request.WeaknessCode)') -and
     $executionApi.Contains('"-SeasonNumber", request.SeasonNumber.ToString') -and
     $executionApi.Contains('"-WeaknessCode", weaknessCode') -and
     $coordinator.Contains("[ValidateSet('fire', 'water', 'wind', 'electric', 'iron')]") -and
     $coordinator.Contains('--weakness-code $WeaknessCode') -and
     $coordinator.Contains('--boss-variant-profile $bossRuntimeVariantProfile') -and
     $coordinator.Contains('config/boss-runtime-variants') -and
     $coordinator.Contains('Get-PhaseDPreparation') -and
     $coordinator.Contains('$_.seasonNumber -eq $SeasonNumber') -and
     $coordinator.Contains('--source-static-pack $sourceStaticDataPack') -and
     $coordinator.Contains('--variant-static-pack $variantStaticDataPack')) `
    'boss_weakness_automation_selection_flow_invalid'
Assert-BossVariant `
    ($variantProfileSchema.properties.contractId.const -ceq `
        'nll/boss-runtime-variant-profile/v1' -and
     $variantRegistrySchema.properties.contractId.const -ceq `
        'nll/boss-runtime-variant-registry/v1' -and
     $variantRegistry.contractId -ceq `
        'nll/boss-runtime-variant-registry/v1' -and
     $variantProfileV2Schema.properties.contractId.const -ceq `
        'nll/boss-runtime-variant-profile/v2' -and
     @($variantRegistry.profiles).Count -eq 2 -and
     [int]$variantRegistry.profiles[0].seasonNumber -eq 26 -and
     $variantRegistry.profiles[0].profileCode -ceq 'season-26-providence' -and
     $variantRegistry.profiles[0].profileRelativePath -ceq `
        'season-26-providence.json' -and
     $variantRegistry.profiles[0].operationalStatusCode -ceq 'enabled' -and
     $variantRegistry.profiles[0].profileSha256 -ceq `
        (Get-FileHash -LiteralPath $season26VariantProfilePath `
            -Algorithm SHA256).Hash.ToLowerInvariant() -and
     [int]$variantRegistry.profiles[1].seasonNumber -eq 29 -and
     $variantRegistry.profiles[1].profileCode -ceq 'season-29-mother-whale' -and
     $variantRegistry.profiles[1].profileRelativePath -ceq `
        'season-29-mother-whale.json' -and
     $variantRegistry.profiles[1].operationalStatusCode -ceq 'enabled' -and
     $variantRegistry.profiles[1].profileSha256 -cne `
        (Get-FileHash -LiteralPath $season29VariantProfilePath `
            -Algorithm SHA256).Hash.ToLowerInvariant() -and
     $season26VariantProfile.contractId -ceq `
        'nll/boss-runtime-variant-profile/v1' -and
     $season26VariantProfile.profileCode -ceq 'season-26-providence' -and
     $season26VariantProfile.elementShield.modeCode -ceq 'none' -and
     $season26VariantProfile.transformation.modeCode -ceq `
        'target_monster_element_reference' -and
     @($season26VariantProfile.transformation.allowedTableCodes).Count -eq 1 -and
     $season26VariantProfile.transformation.allowedTableCodes[0] -ceq 'monster' -and
     [bool]$season26VariantProfile.transformation.preserveElementTable -and
     [bool]$season26VariantProfile.transformation.restrictToTargetMonsterElementIds -and
     $season26VariantProfile.selectedManagerObservation.trustedSha256 -cmatch `
        '^[0-9a-f]{64}$' -and
     $variantProfileCode.Contains('BossRuntimeVariantProfile') -and
     $materializer.Contains('BossAffinityStaticDataVariant') -and
     $materializer.Contains('ElementTable.mpk') -and
     $materializer.Contains('MonsterTable.mpk') -and
     $materializer.Contains('profile.SelectedManagerObservation') -and
     $materializer.Contains('phase_d_boss_variant_source_affinity_mismatch') -and
     $materializer.Contains('dynamic_affinity_linked') -and
     $materializer.Contains('shieldFxMappingSetSha256') -and
     $materializer.Contains('target_monster_element_reference') -and
     $materializer.Contains('ValidateElementTableIndex') -and
     $materializer.Contains('phase_d_staticdata_target_monster_reference_not_isolated') -and
     $materializer.Contains('officialInstallModified = false') -and
     $materializer.Contains('serverStaticDataModified = false') -and
     $materializer.Contains('pending_original_client_runtime_observation') -and
     $coordinator.Contains('$staticDataVariantRequired = [bool]$staticDataVariant.variantRequired') -and
     $coordinator.Contains('phase_d_boss_behavior_asset_closure_invalid') -and
     $coordinator.Contains('phase_d_boss_shield_fx_asset_closure_invalid') -and
     $coordinator.Contains('$targetByWeakness = @{') -and
     $coordinator.Contains('bossVariantRegistrySha256') -and
     -not $coordinator.Contains('config\boss-runtime-variants\season-26-providence.json') -and
     -not $coordinator.Contains("--season-number '26'") -and
     $coordinator.Contains('parentServerDllSha256') -and
     $coordinator.Contains('parentRuntimeModified = $false') -and
     $coordinator.Contains('officialInstallModified = $false')) `
    'boss_weakness_automation_derived_lane_boundary_invalid'
Assert-BossVariant `
    ($season29VariantProfile.contractId -ceq `
        'nll/boss-runtime-variant-profile/v3' -and
     [int]$season29VariantProfile.seasonNumber -eq 29 -and
     $season29VariantProfile.skillClosure.missingReferenceCount -eq 0 -and
     $season29VariantProfile.behaviorAssembly.assetClosureStatusCode -ceq `
        'resolved' -and
     $season29VariantProfile.behaviorAssembly.graphMatchCount -eq `
        $season29VariantProfile.behaviorAssembly.rootReferenceCount -and
     $season29VariantProfile.elementShield.modeCode -ceq `
        'dynamic_affinity_linked' -and
     @($season29VariantProfile.elementShield.fxVariants).Count -eq 5 -and
     @($season29VariantProfile.elementShield.fxVariants | Where-Object {
        @($_.mappings).Count -gt 0 -and
        @($_.mappings | Where-Object { @($_.assetBundles).Count -gt 0 }).Count -eq
            @($_.mappings).Count
     }).Count -eq 5 -and
     $onboarding.Contains('--discover-boss-content') -and
     $onboarding.Contains('--validate-boss-variant-profile') -and
     $onboarding.Contains("@('fire', 'water', 'wind', 'electric', 'iron')") -and
     $onboarding.Contains('boss_onboarding_behavior_closure_not_unique') -and
     $behaviorInspector.Contains('preserve_exact_external_behavior_tree') -and
     $profileAssembler.Contains('sourceFxPrefabSetSha256') -and
     $profileAssembler.Contains('assetBundleSetSha256')) `
    'boss_onboarding_reusable_pipeline_invalid'
Assert-BossVariant `
    ($materializer.Contains('BossQuickTimeEventVariant.Apply') -and
     $materializer.Contains('BossQuickTimeEventVariant.VerifyBoundary') -and
     $materializer.Contains('modifiedQuickTimeEventRecordCount') -and
     $materializer.Contains('quickTimeEventAffinityContractVerified') -and
     $qteMaterializer.Contains('source_mismatch') -and
     $behaviorInspector.Contains('quickTimeEventNodeCount') -and
     $onboarding.Contains('--count-quick-time-event-nodes') -and
     $profileAssembler.Contains('behavior["quickTimeEventNodeCount"] > 0') -and
     $qteMaterializer.Contains('immutable_payload_changed') -and
     $qteMaterializer.Contains('foreign_row_changed') -and
     $profileAssembler.Contains('require_v2_qte_compatibility(source)') -and
     $profileAssembler.Contains('boss_profile_qte_v3_pipeline_required')) `
    'boss_onboarding_qte_boundary_missing'
$candidateVerifier = Read-RequiredText (Join-Path $repositoryRoot `
    'scripts\verify-nll-boss-onboarding-candidate.py')
Assert-BossVariant `
    ($onboarding.Contains('[switch]$CandidateOnly') -and
     $onboarding.Contains('boss_onboarding_v3_runtime_delivery_required') -and
     $onboarding.Contains('boss_onboarding_input_drifted') -and
     $profileAssembler.Contains('assemble_normalization(') -and
     $profileAssembler.Contains('boss_profile_v3_fx_family_unsupported') -and
     $candidateVerifier.Contains('verified_candidate_pending_runtime_delivery') -and
     $candidateVerifier.Contains('fx.inspect_or_restore(') -and
     $candidateVerifier.Contains('modifiedQuickTimeEventRecordCount') -and
     (Test-Path -LiteralPath (Join-Path $repositoryRoot 'scripts\test-nll-boss-onboarding-candidate.py')) -and
     (Test-Path -LiteralPath (Join-Path $repositoryRoot 'scripts\test-nll-boss-onboarding-local.ps1'))) `
    'boss_onboarding_v3_candidate_boundary_missing'
Assert-BossVariant `
    ($coordinator.Contains('EPINELPS_CLIENT_STATIC_DATA_VARIANT_PATH') -and
     $coordinator.Contains('EPINELPS_CLIENT_STATIC_DATA_VARIANT_SHA256') -and
     $coordinator.Contains('staticDataVariantReceiptSha256') -and
     $coordinator.Contains('weakness-variant-server-source.manifest.tsv') -and
     $repair.Contains('phase_d_application_repair_weakness_variant_source_drifted') -and
     $deploy.Contains('phase_d_weakness_variant_source_drifted')) `
    'boss_weakness_automation_provenance_contract_invalid'

$manifestRows = @($sourceManifest.TrimEnd([char[]]"`r`n") -split "`r?`n")
Assert-BossVariant ($manifestRows.Count -eq 25) `
    'boss_weakness_automation_source_manifest_invalid'
$manifestPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($row in $manifestRows) {
    $parts = @($row -split "`t")
    Assert-BossVariant `
        ($parts.Count -eq 3 -and
         $parts[0] -cmatch '^(EpinelPS|tests)/[A-Za-z0-9._/-]+$' -and
         $parts[1] -cmatch '^[1-9][0-9]*$' -and
         $parts[2] -cmatch '^[0-9a-f]{64}$' -and
         $manifestPaths.Add($parts[0])) `
        'boss_weakness_automation_source_manifest_invalid'
}
foreach ($requiredPath in @(
        'EpinelPS/Program.cs',
        'EpinelPS/Utils/AssetDownloadUtil.cs',
        'EpinelPS/Data/ClientStaticDataVariant.cs',
        'EpinelPS/SoloRaidSelection/ClassicSoloRaidTargetObservation.cs')) {
    Assert-BossVariant ($manifestPaths.Contains($requiredPath)) `
        'boss_weakness_automation_source_manifest_incomplete'
}

$externalRoot = Join-Path $repositoryRoot '.external\EpinelPS'
if (Test-Path -LiteralPath $externalRoot -PathType Container) {
    $externalRoot = [IO.Path]::GetFullPath($externalRoot).TrimEnd('\') + '\'
    foreach ($row in $manifestRows) {
        $parts = @($row -split "`t")
        $sourcePath = [IO.Path]::GetFullPath(
            (Join-Path $externalRoot $parts[0].Replace('/', '\')))
        Assert-BossVariant `
            ($sourcePath.StartsWith(
                $externalRoot, [StringComparison]::OrdinalIgnoreCase) -and
             (Test-Path -LiteralPath $sourcePath -PathType Leaf) -and
             (Get-Item -LiteralPath $sourcePath).Length -eq [long]$parts[1] -and
             (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant() -ceq
                $parts[2]) `
            'boss_weakness_automation_external_source_drifted'
    }
}

Write-Output 'Boss weakness variant automation contract passed.'
& (Join-Path $PSScriptRoot 'test-nll-phase-d-fx-closure.ps1')

$fxCandidate = Read-RequiredText (Join-Path $repositoryRoot 'scripts\materialize-nll-shield-fx-candidate.py')
$fxTransform = Read-RequiredText (Join-Path $repositoryRoot 'scripts\materialize-nll-shield-fx-transform-variant.py')
Assert-BossVariant `
    ($fxCandidate.Contains('nll/boss-shield-fx-isolated-candidate/v1') -and
     $fxCandidate.Contains('shield_fx_candidate_output_overlaps_input') -and
     $fxCandidate.Contains('shield_fx_candidate_manifest_drifted') -and
     $fxCandidate.Contains('shield_fx_candidate_restore_partial_drifted') -and
     $fxCandidate.Contains('runtimeAdmissionStatusCode') -and
     $fxTransform.Contains('shield_fx_variant_transform_boundary_invalid') -and
     (Test-Path -LiteralPath (Join-Path $repositoryRoot 'scripts\test-nll-shield-fx-candidate.py')) -and
     (Test-Path -LiteralPath (Join-Path $repositoryRoot 'scripts\test-nll-shield-fx-local.ps1'))) `
    'boss_shield_fx_isolated_candidate_boundary_missing'
Write-Output 'Shield FX isolated candidate source contract passed; client delivery remains unverified.'
