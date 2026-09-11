# Data-only input to the fixed runner. Import and validation have no side effects.
function Assert-PhaseDRunnerSpecification {
    param([object]$Specification)
    try {
        $fields = @('schemaVersion','contractId','engineCode','launchContextUid','launchRoot','preparationBindingSha256',
            'accountUid','accountRevisionSetSha256','seasonNumber','raidSnapshotUid','raidSnapshotSha256',
            'expectedSoloRaidHeadRevisionUid','clientBuildCode','clientExecutableSha256','runtimeDbSha256',
            'serverExeSha256','serverDllSha256','bootstrapRoot','bootstrapSha256','bossRuntimeVariantProfile',
            'bossRuntimeVariantProfileSha256','staticDataVariantRequired','variantStaticDataPack','variantStaticDataSha256',
            'resourcePreflightRequired','resourcePreflightHelper','resourcePreflightHelperSha256','resourcePreflightTool',
            'resourcePreflightToolSha256','resourceCatalogReceiptPath','resourceCatalogReceiptSha256','runtimeMaterializer',
            'soloRaidPendingPath','soloRaidCaptureReceiptPath','secretEnvironmentVariable','derivedSourceManifestSha256','runIntentCode')
        if ($null -eq $Specification) { throw 'invalid' }
        $versionTwo = $Specification.contractId -ceq 'nll/phase-d-runner-input/v2'
        if ($versionTwo) {
            $fields += 'weaknessCode'
            if ($Specification.weaknessCode -cnotin @('iron','water','fire','wind','electric')) { throw 'invalid' }
        }
        $names = if ($Specification -is [Collections.IDictionary]) { @($Specification.Keys) } else { @($Specification.PSObject.Properties.Name) }
        if ($names.Count -ne $fields.Count -or @($names | Where-Object { $_ -cnotin $fields }).Count -ne 0) { throw 'invalid' }
        if (($Specification.schemaVersion -isnot [int] -and $Specification.schemaVersion -isnot [long]) -or
            $Specification.schemaVersion -ne 1 -or ($Specification.contractId -cne 'nll/phase-d-runner-input/v1' -and -not $versionTwo) -or
            $Specification.engineCode -cne 'parameterized/v1' -or
            $Specification.clientBuildCode -cnotin @('build_150.6.9','build_151.8.5') -or
            $Specification.runIntentCode -cnotin @('challenge','practice')) { throw 'invalid' }
        foreach ($name in @('launchContextUid','accountUid','raidSnapshotUid')) {
            $value = $Specification.$name
            if ($value -isnot [string] -or $value -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -or
                [guid]::Parse($value) -eq [guid]::Empty) { throw 'invalid' }
        }
        $head = $Specification.expectedSoloRaidHeadRevisionUid
        if ($head -isnot [string] -or ($head -cne 'none' -and
            ($head -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -or [guid]::Parse($head) -eq [guid]::Empty))) { throw 'invalid' }
        if (($Specification.seasonNumber -isnot [int] -and $Specification.seasonNumber -isnot [long]) -or
            $Specification.seasonNumber -lt 1 -or $Specification.seasonNumber -gt [int]::MaxValue) { throw 'invalid' }
        foreach ($name in @('preparationBindingSha256','accountRevisionSetSha256','raidSnapshotSha256','clientExecutableSha256',
            'runtimeDbSha256','serverExeSha256','serverDllSha256','bootstrapSha256','bossRuntimeVariantProfileSha256','derivedSourceManifestSha256')) {
            if ($Specification.$name -isnot [string] -or $Specification.$name -cnotmatch '^[0-9a-f]{64}$') { throw 'invalid' }
        }
        $paths = @('launchRoot','bootstrapRoot','bossRuntimeVariantProfile','runtimeMaterializer','soloRaidPendingPath','soloRaidCaptureReceiptPath')
        foreach ($name in @('staticDataVariantRequired','resourcePreflightRequired')) {
            if ($Specification.$name -isnot [bool]) { throw 'invalid' }
        }
        if ($Specification.resourcePreflightRequired -ne ($Specification.clientBuildCode -ceq 'build_150.6.9')) { throw 'invalid' }
        foreach ($group in @(
            @{enabled=$Specification.staticDataVariantRequired; paths=@('variantStaticDataPack'); hashes=@('variantStaticDataSha256')},
            @{enabled=$Specification.resourcePreflightRequired; paths=@('resourcePreflightHelper','resourcePreflightTool','resourceCatalogReceiptPath');
                hashes=@('resourcePreflightHelperSha256','resourcePreflightToolSha256','resourceCatalogReceiptSha256')}
        )) {
            if ($group.enabled) {
                $paths += $group.paths
                foreach ($name in $group.hashes) {
                    if ($Specification.$name -isnot [string] -or $Specification.$name -cnotmatch '^[0-9a-f]{64}$') { throw 'invalid' }
                }
            } else {
                foreach ($name in @($group.paths) + @($group.hashes)) { if ($null -ne $Specification.$name) { throw 'invalid' } }
            }
        }
        foreach ($name in $paths) {
            $value = $Specification.$name
            if ($value -isnot [string] -or $value -notmatch '^[A-Za-z]:[\\/]' -or -not [IO.Path]::IsPathRooted($value) -or $value -match '[\x00-\x1f]' -or
                $value -match '(^|[\\/])\.\.([\\/]|$)' -or $value.StartsWith('\\')) { throw 'invalid' }
            $null = [IO.Path]::GetFullPath($value)
        }
        if ([IO.Path]::GetFileName($Specification.launchRoot.TrimEnd([IO.Path]::DirectorySeparatorChar)) -cne $Specification.launchContextUid -or
            $Specification.secretEnvironmentVariable -isnot [string] -or
            $Specification.secretEnvironmentVariable -cnotmatch '^[A-Z][A-Z0-9_]{2,63}$') { throw 'invalid' }
    } catch { throw 'phase_d_runner_input_invalid' }
}

function New-PhaseDRunnerSpecification {
    param([Collections.IDictionary]$LaunchInput, [string]$PreparationBindingSha256,
        [string]$ProfileSha256, [string]$SourceManifestSha256, [string]$RunIntentCode)
    $bundle = $LaunchInput.runtimeBundle
    $spec = [ordered]@{
        schemaVersion=1; contractId='nll/phase-d-runner-input/v1'; engineCode='parameterized/v1'
        launchContextUid=$LaunchInput.LaunchContextUid; launchRoot=$LaunchInput.launchRoot
        preparationBindingSha256=$PreparationBindingSha256; accountUid=$LaunchInput.accountUid
        accountRevisionSetSha256=$LaunchInput.accountRevisionSetSha256; seasonNumber=$LaunchInput.SeasonNumber
        raidSnapshotUid=$LaunchInput.raidSnapshotUid; raidSnapshotSha256=$LaunchInput.raidSnapshotSha256
        expectedSoloRaidHeadRevisionUid=$LaunchInput.expectedSoloRaidHeadRevisionUid
        clientBuildCode=$LaunchInput.clientBuildCode; clientExecutableSha256=$LaunchInput.clientExecutableSha256
        runtimeDbSha256=$LaunchInput.runtimeDbSha256; serverDllSha256=$LaunchInput.expectedWeaknessVariantServerDllSha256
        serverExeSha256=if ($null -ne $bundle) { [string]$bundle.serverExe.sha256 } else { 'a28c7ff227a74d260a29389b82caeed3fe196f91eef3d28cabe9977b5ed9d07b' }
        bootstrapRoot=if ($null -ne $bundle) { [string]$bundle.bootstrapRoot } else { 'C:\NLL\Runtime\PhysicalBootstrap-v2' }
        bootstrapSha256=if ($null -ne $bundle) { [string]$bundle.bootstrap.sha256 } else { 'ff7371b3e20119030c0f3a8e2f6ba9482094c4118f06dbcc4e0e7f137f8e404f' }
        bossRuntimeVariantProfile=$LaunchInput.bossRuntimeVariantProfile; bossRuntimeVariantProfileSha256=$ProfileSha256
        staticDataVariantRequired=$LaunchInput.staticDataVariantRequired
        variantStaticDataPack=if ($LaunchInput.staticDataVariantRequired) { $LaunchInput.variantStaticDataPack } else { $null }
        variantStaticDataSha256=if ($LaunchInput.staticDataVariantRequired) { $LaunchInput.variantStaticDataSha256 } else { $null }
        resourcePreflightRequired=($null -eq $bundle)
        resourcePreflightHelper=if ($null -eq $bundle) { $LaunchInput.resourcePreflightHelper } else { $null }
        resourcePreflightHelperSha256=if ($null -eq $bundle) { $LaunchInput.resourcePreflightHelperSha256 } else { $null }
        resourcePreflightTool=if ($null -eq $bundle) { $LaunchInput.resourcePreflightTool } else { $null }
        resourcePreflightToolSha256=if ($null -eq $bundle) { $LaunchInput.resourcePreflightToolSha256 } else { $null }
        resourceCatalogReceiptPath=if ($null -eq $bundle) { $LaunchInput.resourceCatalogReceiptPath } else { $null }
        resourceCatalogReceiptSha256=if ($null -eq $bundle) { $LaunchInput.resourceCatalogReceiptSha256 } else { $null }
        runtimeMaterializer=$LaunchInput.runtimeMaterializer; soloRaidPendingPath=$LaunchInput.soloRaidPendingPath
        soloRaidCaptureReceiptPath=$LaunchInput.soloRaidCaptureReceiptPath; secretEnvironmentVariable=$LaunchInput.secretEnvironmentVariable
        derivedSourceManifestSha256=$SourceManifestSha256; runIntentCode=$RunIntentCode
    }
    if ($LaunchInput.Contains('weaknessCode')) {
        $spec.contractId = 'nll/phase-d-runner-input/v2'
        $spec.weaknessCode = $LaunchInput.weaknessCode
    }
    Assert-PhaseDRunnerSpecification $spec
    return $spec
}
