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
