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
function Get-PhaseDPreparation {
    param([string]$RepositoryRoot, [int]$SeasonNumber, [string]$WeaknessCode,
        [string]$RuntimeSelectionPath = 'C:\NLL\ControlCenter\runtime-selection.private.json')
    $result = [ordered]@{
        schemaVersion = 1; contractId = 'nll/phase-d-preparation/v1'
        seasonNumber = $SeasonNumber; weaknessCode = $WeaknessCode
        statusCode = 'blocked'; failureCode = $null; bindingSha256 = $null
        clientBuildCode = $null; plan = $null
    }
    try {
        $targetByWeakness = @{ fire = 'wind'; water = 'fire'; wind = 'iron'; electric = 'water'; iron = 'electric' }
        if ($SeasonNumber -le 0 -or $WeaknessCode -cnotin @('fire', 'water', 'wind', 'electric', 'iron')) { throw 'phase_d_launch_request_invalid' }
        $configRoot = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'config/boss-runtime-variants')).TrimEnd('\')
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
            ($boss.schemaVersion -eq 2 -and $boss.contractId -ceq 'nll/boss-runtime-variant-profile/v2')) -or
            $boss.seasonNumber -ne $SeasonNumber -or $boss.profileCode -cne $entry.profileCode -or
            -not $targetByWeakness.ContainsKey([string]$boss.sourceAffinity.bossElementCode) -or
            -not $targetByWeakness.ContainsKey([string]$boss.sourceAffinity.weaknessCode)) { throw 'phase_d_boss_variant_profile_invalid' }
        $targetElement = $targetByWeakness[$WeaknessCode]
        $fx = @()
        if ($boss.elementShield.modeCode -ceq 'dynamic_affinity_linked') {
            $fx = @($boss.elementShield.fxVariants | Where-Object { $_.bossElementCode -ceq $targetElement })
            if ($fx.Count -ne 1) { throw 'phase_d_boss_variant_element_shield_fx_unresolved' }
        }
        $selection = if (Test-Path -LiteralPath $RuntimeSelectionPath) {
            Read-PhaseDPreparationJson $RuntimeSelectionPath 'phase_d_bundle_selection_invalid'
        } else { $null }
        # UI checks local pins only; the coordinator additionally verifies the
        # applied overlay/firewall at activation, just as before.
        $bundle = Read-PdRuntimeBundle $RuntimeSelectionPath -FilePinsOnly
        $bundleHash = if ($null -ne $bundle) { Get-PdBundleHash $bundle.manifestPath } else { $null }
        if ($null -ne $selection -and (Get-PdBundleHash $RuntimeSelectionPath) -cne $selection.sha256) { throw 'phase_d_preparation_changed' }
        if (($null -eq $selection) -ne ($null -eq $bundle)) { throw 'phase_d_preparation_changed' }
        if ($null -ne $selection -and $selection.value.manifest.sha256 -cne $bundleHash) { throw 'phase_d_preparation_changed' }
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
        $result.plan = [pscustomobject]@{ registry = $registry; profile = $profile; bundle = $bundle; selectionSha256 = $(if ($selection) { $selection.sha256 } else { $null }); bundleSha256 = $bundleHash; targetElementCode = $targetElement; shieldFxVariants = $fx }
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
