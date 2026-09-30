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
function Set-DynamicFixture([string]$SourceElement = 'electric') {
    Reset-Fixture
    $profile.schemaVersion = 2; $profile.contractId = 'nll/boss-runtime-variant-profile/v2'
    $weaknessByElement = @{ fire = 'water'; water = 'electric'; wind = 'fire'; electric = 'iron'; iron = 'wind' }
    $profile.sourceAffinity = @{ bossElementCode = $SourceElement; weaknessCode = $weaknessByElement[$SourceElement] }
    $roles = @('fire', 'water', 'wind', 'electric', 'iron')
    $secondary = $roles[([array]::IndexOf($roles, $SourceElement) + 1) % $roles.Count]
    $profile.elementShield = @{ modeCode = 'dynamic_affinity_linked'; fxVariants = @(
        foreach ($role in $roles) {
            @{ bossElementCode = $role; mappings = @(@{
                sourceKindCode = $(if ($role -ceq $SourceElement -or $role -ceq $secondary) { 'boss_specific' } else { 'common' })
                sourceFxPrefabSetSha256 = ('a' * 64); targetFxPrefabSetSha256 = ('b' * 64)
                assetBundles = @(@{ sha256 = ('c' * 64); byteLength = 64 })
            }) }
        }
    ) }
}
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
    Set-DynamicFixture
    Save-Fixture
    Assert-Test ((Read-Fixture).statusCode -ceq 'ready') 'v2_variant_rejected'
    $profile.elementShield.fxVariants = @($profile.elementShield.fxVariants | Where-Object { $_.bossElementCode -cne 'wind' }); Save-Fixture
    Assert-Test ((Read-Fixture 'fire').failureCode -ceq 'phase_d_boss_variant_element_shield_fx_unresolved') 'missing_fx_accepted'
    Set-DynamicFixture
    $profile.elementShield.fxVariants[1] = $profile.elementShield.fxVariants[0]; Save-Fixture
    Assert-Test ((Read-Fixture).failureCode -ceq 'phase_d_boss_variant_element_shield_fx_unresolved') 'duplicate_fx_accepted'
    $p21Checks = 0
    # Every source element has two dedicated FX roles; their identities change
    # with the source. These checks use the real preparation path, not a stub.
    $expectedTargets = @{ fire = 'wind'; water = 'fire'; wind = 'iron'; electric = 'water'; iron = 'electric' }
    foreach ($sourceElement in @('fire', 'water', 'wind', 'electric', 'iron')) {
        Set-DynamicFixture $sourceElement; Save-Fixture
        $original = [IO.File]::ReadAllText($profilePath)
        $parsed = $original | ConvertFrom-Json
        $before = $parsed | ConvertTo-Json -Depth 20 -Compress
        foreach ($selected in @('fire', 'water', 'wind', 'electric', 'iron')) {
            $prepared = Read-Fixture $selected
            Assert-Test ($prepared.statusCode -ceq 'ready') 'p21_preparation_rejected'
            $resolved = $prepared.plan.affinity
            $direct = Resolve-PhaseDBossAffinity $parsed $selected
            $expected = @($profile.elementShield.fxVariants | Where-Object { $_.bossElementCode -ceq $expectedTargets[$selected] })[0]
            Assert-Test ($resolved.sourceBossElementCode -ceq $sourceElement -and
                $resolved.sourceWeaknessCode -ceq $profile.sourceAffinity.weaknessCode -and
                $resolved.selectedWeaknessCode -ceq $selected -and
                $resolved.targetBossElementCode -ceq $expectedTargets[$selected] -and
                $resolved.sourceShieldFxVariant.bossElementCode -ceq $sourceElement -and
                $resolved.targetShieldFxVariant.bossElementCode -ceq $expectedTargets[$selected] -and
                $resolved.targetShieldFxVariant.mappings[0].sourceKindCode -ceq $expected.mappings[0].sourceKindCode -and
                @($resolved.shieldFxVariants | Where-Object { $_.mappings[0].sourceKindCode -ceq 'boss_specific' }).Count -eq 2 -and
                ($direct | ConvertTo-Json -Depth 20 -Compress) -ceq ($resolved | ConvertTo-Json -Depth 20 -Compress) -and
                $prepared.plan.targetElementCode -ceq $resolved.targetBossElementCode -and
                $prepared.plan.shieldFxVariants[0].bossElementCode -ceq $resolved.targetBossElementCode) 'p21_affinity_or_fx_selection_wrong'
            Assert-Test (($parsed | ConvertTo-Json -Depth 20 -Compress) -ceq $before -and
                [IO.File]::ReadAllText($profilePath) -ceq $original) 'p21_source_mutated'
            $p21Checks++
        }
    }
    Set-DynamicFixture 'water'
    # Source kind belongs to each mapping, not to the whole boss or FX role.
    $profile.elementShield.fxVariants[0].mappings += @{
        sourceKindCode = 'boss_specific'; sourceFxPrefabSetSha256 = ('d' * 64)
        targetFxPrefabSetSha256 = ('e' * 64); assetBundles = @(@{ sha256 = ('f' * 64); byteLength = 128 })
    }
    [array]::Reverse($profile.elementShield.fxVariants)
    Save-Fixture
    $mixed = Read-Fixture 'water'
    Assert-Test ($mixed.statusCode -ceq 'ready' -and $mixed.plan.affinity.sourceBossElementCode -ceq 'water' -and
        $mixed.plan.affinity.targetBossElementCode -ceq 'fire' -and
        ($mixed.plan.affinity.targetShieldFxVariant.mappings.sourceKindCode -join ',') -ceq 'common,boss_specific' -and
        $mixed.plan.affinity.targetShieldFxVariant.mappings[1].assetBundles[0].sha256 -ceq ('f' * 64)) 'p21_mapping_order_or_origin_collapsed'
    $p21Checks++
    # Mutate an unselected role too: selection must not conceal an incomplete map.
    foreach ($fault in @('kind', 'empty_mappings', 'missing_mappings', 'empty_assets', 'bad_hash', 'bad_length', 'unknown_element', 'source_pair', 'unknown_mode')) {
        Set-DynamicFixture
        $row = $profile.elementShield.fxVariants[1]
        switch ($fault) {
            'kind' { $row.mappings[0].sourceKindCode = 'assumed' }
            'empty_mappings' { $row.mappings = @() }
            'missing_mappings' { $row.Remove('mappings') }
            'empty_assets' { $row.mappings[0].assetBundles = @() }
            'bad_hash' { $row.mappings[0].assetBundles[0].sha256 = 'invalid' }
            'bad_length' { $row.mappings[0].assetBundles[0].byteLength = 0 }
            'unknown_element' { $row.bossElementCode = 'unknown' }
            'source_pair' { $profile.sourceAffinity.weaknessCode = 'water' }
            'unknown_mode' { $profile.elementShield.modeCode = 'unknown' }
        }
        Save-Fixture
        $rejected = Read-Fixture 'water'
        Assert-Test ($rejected.statusCode -ceq 'blocked' -and $null -eq $rejected.plan -and
            $null -eq $rejected.bindingSha256 -and $rejected.failureCode -cin @(
                'phase_d_boss_variant_profile_invalid', 'phase_d_boss_variant_element_shield_fx_unresolved')) ('p21_invalid_mapping_accepted_' + $fault)
        $p21Checks++
    }
    Reset-Fixture; Save-Fixture
    # Runtime bundle I/O is a synthetic map, never the installed C:\NLL tree.
    & {
        $manifest='C:\NLL\Runtime\PhaseD152-v99\bundle.private.json'
        $pointer='C:\NLL\ControlCenter\runtime-selection.private.json'
        $client='C:\NLL\Clients\NIKKE-152.8.11-ResourceProbe\NIKKE\game\nikke.exe'
        $native='C:\NLL\Clients\NIKKE-152.8.11-ResourceProbe\NIKKE\game\sodium.dll'
        $certificate='C:\NLL\Clients\NIKKE-152.8.11-ResourceProbe\certificate.pem'
        $asset='C:\NLL\Runtime\PhaseD152-v99\server\cache\synthetic.bundle'
        $launcher='C:\NIKKE\Launcher\nikke_launcher.exe'
        $files=@{}
        foreach($path in @($manifest,$pointer,$client,$native,$certificate,$asset,$launcher)) {
            $files[$path]=@{length=32;sha256=('a'*64);content=''}
        }
        $files[$client].sha256='9c50d1e5e2312783b7ae908237081ff2976e06dcb0d90ae1d59f563afc5c73ef'
        $files[$native].sha256='54ee18f5ee3d16fea8bb6c3407a880727aa3b848f6a55908e6bf90f8635e5662'
        function Pin-Test($Path) { @{path=$Path;length=$files[$Path].length;sha256=$files[$Path].sha256} }
        $value=@{contractId='nll/phase-d-runtime-bundle/v1';clientBuildCode='build_152.8.11'
            serverRoot='C:\NLL\Runtime\PhaseD152-v99\server';bootstrapRoot='C:\NLL\Runtime\PhaseD152-v99\bootstrap'
            client=(Pin-Test $client);native=(Pin-Test $native);certificate=(Pin-Test $certificate)
            files=@((Pin-Test $asset),(Pin-Test $native),(Pin-Test $certificate),(Pin-Test $client))
            clientPrograms=@((Pin-Test $client),(Pin-Test $launcher));blockOnlyPrograms=@()
            overlay=@();preserveExistingAccount=$true;syntheticRegistration=$false;httpDiagnosticLayer=$false}
        $files[$manifest].content=$value | ConvertTo-Json -Depth 8
        $files[$pointer].content=@{contractId='nll/phase-d-runtime-selection/v1';manifest=(Pin-Test $manifest)} | ConvertTo-Json
        $hashes=[Collections.Generic.List[string]]::new()
        function Test-Path { param($LiteralPath,$PathType) $files.ContainsKey($LiteralPath) }
        function Get-Item { param($LiteralPath) [pscustomobject]@{Length=$files[$LiteralPath].length} }
        function Get-Content { param($LiteralPath,[switch]$Raw,$Encoding) $files[$LiteralPath].content }
        function Get-PdBundleHash($Path) { $hashes.Add($Path); $files[$Path].sha256 }
        function Get-NetFirewallRule { throw 'bundle_reader_must_not_query_firewall' }
        $null=Read-PdRuntimeBundle $pointer
        Assert-Test ($hashes.Count -eq 4 -and $asset -cnotin $hashes -and $launcher -cnotin $hashes) 'launch_hash_scope_changed'
        foreach($path in @($manifest,$client,$native,$certificate)) {
            $before=$files[$path].sha256; $files[$path].sha256='b'*64
            $caught=$false; try { $null=Read-PdRuntimeBundle $pointer } catch { $caught=$_.Exception.Message -ceq 'phase_d_bundle_file_drifted' }
            Assert-Test $caught 'security_pin_drift_accepted'; $files[$path].sha256=$before
        }
        $files[$asset].length++
        $caught=$false; try { $null=Read-PdRuntimeBundle $pointer } catch { $caught=$_.Exception.Message -ceq 'phase_d_bundle_file_drifted' }
        Assert-Test $caught 'asset_length_drift_accepted'; $files[$asset].length--
        $files[$asset].sha256='b'*64
        $null=Read-PdRuntimeBundle $pointer
        $caught=$false; try { $null=Read-PdRuntimeBundle $pointer -FullVerification } catch { $caught=$_.Exception.Message -ceq 'phase_d_bundle_file_drifted' }
        Assert-Test $caught 'full_verification_lost_asset_hash'
        $caught=$false; try { $null=Read-PdRuntimeBundle $pointer -BeforeActivation } catch { $caught=$_.Exception.Message -ceq 'phase_d_bundle_file_drifted' }
        Assert-Test $caught 'installation_lost_asset_hash'
        Write-Output 'Runtime bundle: 9 synthetic length/security-pin/full-verification checks passed; zero firewall queries.'
    }

    # Exercise error sanitization without invoking any operating-system boundary.
    function Read-PdRuntimeBundle { param($PointerPath, [switch]$FilePinsOnly) throw 'C:\private\sensitive-data' }
    Assert-Test ((Read-Fixture).failureCode -ceq 'phase_d_preparation_invalid') 'raw_exception_leaked'
    Write-Output 'Phase D preparation: 16 synthetic configuration, binding and sanitization checks passed.'
    Write-Output ('P2-1: ' + $p21Checks + ' source/weakness/FX selection and rejection cases passed; no asset suitability or runtime admission claimed.')
}
finally {
    $resolved = [IO.Path]::GetFullPath($taskRoot)
    Assert-Test ($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved).StartsWith('nll-preparation-')) 'test_cleanup_path_invalid'
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
