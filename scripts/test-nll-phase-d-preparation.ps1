# Synthetic-only tests. No private runtime, registry, firewall or database is changed.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.PhaseDPreparation.ps1')
function Assert-Test([bool]$Condition, [string]$Code) { if (-not $Condition) { throw $Code } }
$taskRoot = Join-Path ([IO.Path]::GetTempPath()) ('nll-preparation-' + [guid]::NewGuid().ToString('N'))
$configRoot = Join-Path $taskRoot 'config/boss-runtime-variants'
$null = New-Item -ItemType Directory -Path $configRoot
$pointerPath = Join-Path $taskRoot 'selection.json'
$profilePath = Join-Path $configRoot 'boss.json'
$registryPath = Join-Path $configRoot 'registry.json'
function Write-TestJson($Path, $Value) { [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false)) }
function Reset-Fixture {
    $script:profile = [ordered]@{ schemaVersion = 1; contractId = 'nll/boss-runtime-variant-profile/v1'; seasonNumber = 26; profileCode = 'synthetic-boss'
        sourceAffinity = @{ bossElementCode = 'electric'; weaknessCode = 'iron' }; elementShield = @{ modeCode = 'none' } }
    $script:entry = [ordered]@{ seasonNumber = 26; profileCode = 'synthetic-boss'; operationalStatusCode = 'enabled'; profileRelativePath = 'boss.json'; profileSha256 = '' }
}
function Save-Fixture {
    Write-TestJson $profilePath $script:profile
    $script:entry.profileSha256 = Get-PdBundleHash $profilePath
    Write-TestJson $registryPath @{ schemaVersion = 1; contractId = 'nll/boss-runtime-variant-registry/v1'; profiles = @($script:entry) }
}
function Read-Fixture([string]$Weakness = 'water') { Get-PhaseDPreparation $taskRoot 26 $Weakness $pointerPath }
try {
    Reset-Fixture; Save-Fixture
    $ready = Read-Fixture
    Assert-Test ($ready.statusCode -ceq 'ready' -and $ready.clientBuildCode -ceq 'build_150.6.9') 'absent_pointer_legacy_changed'
    Assert-Test ($ready.bindingSha256 -ceq (Read-Fixture).bindingSha256) 'binding_not_deterministic'
    Assert-Test ($ready.bindingSha256 -cne (Read-Fixture 'fire').bindingSha256) 'weakness_not_bound'
    $projection = ConvertTo-PhaseDPreparationProjection $ready
    Assert-Test ($projection.Count -eq 8 -and -not $projection.Contains('plan')) 'private_plan_leaked'
    Assert-Test ((Read-Fixture 'WATER').failureCode -ceq 'phase_d_launch_request_invalid') 'noncanonical_code_accepted'
    Write-TestJson $pointerPath @{ contractId = 'unsupported'; manifest = @{ path = 'invalid' } }
    Assert-Test ((Read-Fixture).failureCode -ceq 'phase_d_bundle_selection_invalid') 'invalid_pointer_fell_back'
    Remove-Item -LiteralPath $pointerPath
    [IO.File]::AppendAllText($profilePath, ' ')
    Assert-Test ((Read-Fixture).failureCode -ceq 'phase_d_boss_variant_profile_drifted') 'drift_accepted'
    Reset-Fixture; Save-Fixture
    Write-TestJson $registryPath @{ schemaVersion = 1; contractId = 'nll/boss-runtime-variant-registry/v1'; profiles = @($entry,$entry) }
    Assert-Test ((Read-Fixture).failureCode -ceq 'phase_d_boss_variant_profile_not_enabled') 'duplicate_accepted'
    Reset-Fixture; $entry.profileRelativePath = '../outside.json'; Save-Fixture
    Assert-Test ((Read-Fixture).failureCode -ceq 'phase_d_boss_variant_profile_path_invalid') 'escape_accepted'
    Reset-Fixture; $profile.schemaVersion = 3; $profile.contractId = 'nll/boss-runtime-variant-profile/v3'; Save-Fixture
    Assert-Test ((Read-Fixture).failureCode -ceq 'phase_d_boss_variant_profile_invalid') 'unimplemented_schema_accepted'
    Reset-Fixture; $profile.profileCode = 'different'; Save-Fixture
    Assert-Test ((Read-Fixture).failureCode -ceq 'phase_d_boss_variant_profile_invalid') 'profile_identity_accepted'
    Reset-Fixture; $profile.sourceAffinity.bossElementCode = 'unknown'; Save-Fixture
    Assert-Test ((Read-Fixture).failureCode -ceq 'phase_d_boss_variant_profile_invalid') 'unknown_affinity_accepted'
    Reset-Fixture
    $profile.schemaVersion = 2; $profile.contractId = 'nll/boss-runtime-variant-profile/v2'
    $profile.elementShield = @{ modeCode = 'dynamic_affinity_linked'; fxVariants = @(@{ bossElementCode = 'fire' }) }
    Save-Fixture
    Assert-Test ((Read-Fixture).statusCode -ceq 'ready') 'v2_variant_rejected'
    Assert-Test ((Read-Fixture 'fire').failureCode -ceq 'phase_d_boss_variant_element_shield_fx_unresolved') 'missing_fx_accepted'
    $profile.elementShield.fxVariants += @{ bossElementCode = 'fire' }; Save-Fixture
    Assert-Test ((Read-Fixture).failureCode -ceq 'phase_d_boss_variant_element_shield_fx_unresolved') 'duplicate_fx_accepted'
    Reset-Fixture; Save-Fixture
    # Exercise error sanitization without invoking any operating-system boundary.
    function Read-PdRuntimeBundle { param($PointerPath, [switch]$FilePinsOnly) throw 'C:\private\sensitive-data' }
    Assert-Test ((Read-Fixture).failureCode -ceq 'phase_d_preparation_invalid') 'raw_exception_leaked'
    Write-Output 'Phase D preparation: 16 synthetic configuration, binding and sanitization checks passed.'
}
finally {
    $resolved = [IO.Path]::GetFullPath($taskRoot)
    Assert-Test ($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved).StartsWith('nll-preparation-')) 'test_cleanup_path_invalid'
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
