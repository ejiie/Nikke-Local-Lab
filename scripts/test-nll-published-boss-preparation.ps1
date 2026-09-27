# Source-only regression: no installed runtime, account, game or database is read.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.PhaseDPreparation.ps1')
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$absentSelection = Join-Path ([IO.Path]::GetTempPath()) ('nll-ci-no-selection-' + [guid]::NewGuid().ToString('N') + '.json')
if (Test-Path -LiteralPath $absentSelection) { throw 'published_preparation_selection_must_be_absent' }
$s29 = Get-Content -LiteralPath (Join-Path $repositoryRoot 'config/boss-runtime-variants/season-29-mother-whale.json') -Raw | ConvertFrom-Json
$s29Before = $s29 | ConvertTo-Json -Depth 30 -Compress
$expectedTargets = @{ fire = 'wind'; water = 'fire'; wind = 'iron'; electric = 'water'; iron = 'electric' }
foreach ($weakness in @('fire', 'water', 'wind', 'electric', 'iron')) {
    $ready = Get-PhaseDPreparation $repositoryRoot 26 $weakness $absentSelection
    if ($ready.statusCode -cne 'ready' -or $null -ne $ready.failureCode -or
        $ready.bindingSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'published_s26_source_preparation_not_ready'
    }
    $blocked = Get-PhaseDPreparation $repositoryRoot 29 $weakness $absentSelection
    if ($blocked.statusCode -cne 'blocked' -or
        $blocked.failureCode -cne 'phase_d_boss_variant_profile_drifted' -or
        $null -ne $blocked.bindingSha256 -or $null -ne $blocked.plan) {
        throw 'published_s29_draft_must_remain_blocked'
    }
    # Interpret checked-in v3 fields offline without relaxing the preparation gate.
    $affinity = Resolve-PhaseDBossAffinity -Profile $s29 -WeaknessCode $weakness
    $dedicated = @($affinity.shieldFxVariants | Where-Object { $_.mappings[0].sourceKindCode -ceq 'boss_specific' } | ForEach-Object { $_.bossElementCode })
    if ($affinity.sourceBossElementCode -cne 'electric' -or $affinity.sourceWeaknessCode -cne 'iron' -or
        $affinity.targetBossElementCode -cne $expectedTargets[$weakness] -or
        $affinity.targetShieldFxVariant.bossElementCode -cne $expectedTargets[$weakness] -or
        $affinity.sourceShieldFxVariant.bossElementCode -cne 'electric' -or
        ($dedicated -join ',') -cne 'water,electric' -or
        ($s29 | ConvertTo-Json -Depth 30 -Compress) -cne $s29Before) { throw 'published_s29_affinity_fx_selection_invalid' }
}
Write-Output 'Published source preparation: S26 ready / S29 draft blocked for all five weaknesses; not a runtime admission.'
Write-Output 'P2-1: S29 electric/water dedicated FX mappings selected from profile fields for all five weaknesses; source preserved.'

# V4 pure selection carries original reuse and derived pins without enabling the
# published admission path. Full semantic profile validation is exercised in C#.
$common = $s29Before | ConvertFrom-Json
$common.schemaVersion = 4
$common.contractId = 'nll/boss-runtime-variant-profile/v4'
$common.PSObject.Properties.Remove('shieldFxTransformNormalization')
$sourceBundle = @($common.elementShield.fxVariants | Where-Object { $_.bossElementCode -ceq 'electric' })[0].mappings[0].assetBundles[0]
$preparedRows = foreach ($variant in $common.elementShield.fxVariants) {
    foreach ($mapping in $variant.mappings) {
        $reuse = $mapping.sourceKindCode -ceq 'boss_specific'
        [pscustomobject]@{ bossElementCode = $variant.bossElementCode
            sourceFxPrefabSetSha256 = $mapping.sourceFxPrefabSetSha256; targetFxPrefabSetSha256 = $mapping.targetFxPrefabSetSha256
            operationCode = $(if ($reuse) { 'reuse' } else { 'adjust_candidate' })
            sourceBundle = $sourceBundle; targetBundle = $mapping.assetBundles[0]
            outputBundle = $(if ($reuse) { $mapping.assetBundles[0] } else { [pscustomobject]@{ sha256 = ('1' * 64); byteLength = 64 } }) }
    }
}
$common | Add-Member -NotePropertyName shieldFxPreparation -NotePropertyValue ([pscustomobject]@{
    contractId = 'nll/boss-shield-fx-preparation/v1'; policyCode = 'source_shield_size_candidate/v2'
    sourceBossElementCode = 'electric'; recipeManifestSha256 = ('2' * 64); variants = @($preparedRows) })
foreach ($weakness in $expectedTargets.Keys) {
    $selected = (Resolve-PhaseDBossAffinity -Profile $common -WeaknessCode $weakness).preparedShieldFx
    if ($selected.recipeManifestSha256 -cne ('2' * 64) -or @($selected.variants).Count -ne 1 -or
        $selected.variants[0].bossElementCode -cne $expectedTargets[$weakness]) { throw 'common_fx_binding_selection_failed' }
}
$common.shieldFxPreparation.variants[0].targetFxPrefabSetSha256 = '0' * 64
$rejected = $false
try { Resolve-PhaseDPreparedShieldFx $common $common.shieldFxPreparation.variants[0].bossElementCode | Out-Null }
catch { $rejected = $_.Exception.Message -ceq 'phase_d_boss_variant_profile_invalid' }
if (-not $rejected) { throw 'common_fx_cross_mapping_not_rejected' }
Write-Output 'Common FX preparation: five selections and cross-mapping rejection passed; admission unchanged.'
