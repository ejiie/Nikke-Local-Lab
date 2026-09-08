# Pure compatibility adapter for the pinned legacy templates. No files/processes are changed.
# Text substitution is quarantined here pending a separately verified parameterized runner.
. (Join-Path $PSScriptRoot 'Nll.PhaseDRuntimeBundle.ps1')
. (Join-Path $PSScriptRoot 'Nll.PhaseDCompletion.ps1')
function New-PhaseDLaunchToolText {
    param([System.Collections.IDictionary]$Specification)
    function Assert-PhaseD([bool]$Condition, [string]$Code) { if (-not $Condition) { throw $Code } }
    function ConvertTo-PhaseDPowerShellLiteral([string]$Value) { "'" + $Value.Replace("'", "''") + "'" }
    $fields = @('parentStartText', 'parentCompletionText', 'expectedParentDbSha256', 'runtimeDbSha256', 'expectedServerDllSha256', 'expectedWeaknessVariantServerDllSha256', 'runtimeBundle', 'resourcePreflightHelper', 'resourcePreflightHelperSha256', 'resourcePreflightTool', 'resourceCatalogReceiptPath', 'resourceCatalogReceiptSha256', 'resourcePreflightToolSha256', 'launchRoot', 'bossRuntimeVariantProfile', 'staticDataVariantRequired', 'variantStaticDataPack', 'variantStaticDataSha256', 'runtimeMaterializer', 'soloRaidPendingPath', 'soloRaidCaptureReceiptPath', 'accountUid', 'accountRevisionSetSha256', 'SeasonNumber', 'raidSnapshotUid', 'raidSnapshotSha256', 'clientBuildCode', 'clientExecutableSha256', 'LaunchContextUid', 'expectedSoloRaidHeadRevisionUid', 'secretEnvironmentVariable')
    Assert-PhaseD ($null -ne $Specification -and $Specification.schemaVersion -eq 1 -and
        $Specification.contractId -ceq 'nll/phase-d-launch-tools-input/v1' -and
        $Specification.Count -eq $fields.Count + 2 -and
        @($fields | Where-Object { -not $Specification.Contains($_) }).Count -eq 0) 'phase_d_launch_tools_input_invalid'
    $parentStartText = $Specification.parentStartText
    $parentCompletionText = $Specification.parentCompletionText
    $expectedParentDbSha256 = $Specification.expectedParentDbSha256
    $runtimeDbSha256 = $Specification.runtimeDbSha256
    $expectedServerDllSha256 = $Specification.expectedServerDllSha256
    $expectedWeaknessVariantServerDllSha256 = $Specification.expectedWeaknessVariantServerDllSha256
    $runtimeBundle = $Specification.runtimeBundle
    $resourcePreflightHelper = $Specification.resourcePreflightHelper
    $resourcePreflightHelperSha256 = $Specification.resourcePreflightHelperSha256
    $resourcePreflightTool = $Specification.resourcePreflightTool
    $resourceCatalogReceiptPath = $Specification.resourceCatalogReceiptPath
    $resourceCatalogReceiptSha256 = $Specification.resourceCatalogReceiptSha256
    $resourcePreflightToolSha256 = $Specification.resourcePreflightToolSha256
    $launchRoot = $Specification.launchRoot
    $bossRuntimeVariantProfile = $Specification.bossRuntimeVariantProfile
    $staticDataVariantRequired = $Specification.staticDataVariantRequired
    $variantStaticDataPack = $Specification.variantStaticDataPack
    $variantStaticDataSha256 = $Specification.variantStaticDataSha256
    $runtimeMaterializer = $Specification.runtimeMaterializer
    $soloRaidPendingPath = $Specification.soloRaidPendingPath
    $soloRaidCaptureReceiptPath = $Specification.soloRaidCaptureReceiptPath
    $accountUid = $Specification.accountUid
    $accountRevisionSetSha256 = $Specification.accountRevisionSetSha256
    $SeasonNumber = $Specification.SeasonNumber
    $raidSnapshotUid = $Specification.raidSnapshotUid
    $raidSnapshotSha256 = $Specification.raidSnapshotSha256
    $clientBuildCode = $Specification.clientBuildCode
    $clientExecutableSha256 = $Specification.clientExecutableSha256
    $LaunchContextUid = $Specification.LaunchContextUid
    $expectedSoloRaidHeadRevisionUid = $Specification.expectedSoloRaidHeadRevisionUid
    $secretEnvironmentVariable = $Specification.secretEnvironmentVariable
    foreach ($hash in @($expectedParentDbSha256, $runtimeDbSha256, $expectedServerDllSha256,
        $expectedWeaknessVariantServerDllSha256, $accountRevisionSetSha256, $raidSnapshotSha256, $clientExecutableSha256)) {
        Assert-PhaseD ($hash -is [string] -and $hash -cmatch '^[0-9a-f]{64}$') 'phase_d_launch_tools_input_invalid'
    }
    Assert-PhaseD ($parentStartText -is [string] -and $parentCompletionText -is [string] -and
        $staticDataVariantRequired -is [bool] -and $SeasonNumber -gt 0 -and
        $clientBuildCode -cin @('build_150.6.9', 'build_151.8.5')) 'phase_d_launch_tools_input_invalid'
    $expectedParentDbPattern = [regex]::Escape($expectedParentDbSha256)
    Assert-PhaseD `
        (([regex]::Matches($parentStartText, $expectedParentDbPattern)).Count -eq 1 -and
         ([regex]::Matches($parentCompletionText, $expectedParentDbPattern)).Count -eq 1) `
        'phase_d_tool_source_contract_invalid'
    $startText = $parentStartText.Replace($expectedParentDbSha256, $runtimeDbSha256)
    $completionText = $parentCompletionText.Replace(
        $expectedParentDbSha256, $runtimeDbSha256)
    $startText = $startText.Replace(
        $expectedServerDllSha256, $expectedWeaknessVariantServerDllSha256)
    if ($null -ne $runtimeBundle) {
        $startText = Convert-PdBundleStart $startText $runtimeBundle
    }
    $resourceBootstrapAnchor = "    `$stageCode = 'physical_bootstrap_and_sail_observation'"
    Assert-PhaseD `
        (([regex]::Matches($startText, [regex]::Escape($resourceBootstrapAnchor))).Count -eq 1) `
        'phase_d_resource_preflight_anchor_invalid'
    $resourceBootstrapCheck = @(
        '    $stageCode = ''required_resource_catalog_set_loopback_preflight'''
        '    if ((Get-Sha256Hex ' + (ConvertTo-PhaseDPowerShellLiteral $resourcePreflightHelper) +
            ') -cne ' + (ConvertTo-PhaseDPowerShellLiteral $resourcePreflightHelperSha256) +
            ') { throw ''phase_d_resource_preflight_helper_drifted'' }'
        '    . ' + (ConvertTo-PhaseDPowerShellLiteral $resourcePreflightHelper)
        '    Assert-NllResourceTransportBeforeClient -ToolPath ' +
            (ConvertTo-PhaseDPowerShellLiteral $resourcePreflightTool) +
            ' -ReceiptPath ' + (ConvertTo-PhaseDPowerShellLiteral $resourceCatalogReceiptPath) +
            ' -ReceiptSha256 ' + (ConvertTo-PhaseDPowerShellLiteral $resourceCatalogReceiptSha256) +
            ' -ToolSha256 ' + (ConvertTo-PhaseDPowerShellLiteral $resourcePreflightToolSha256) +
            ' -TransportReceiptPath ' + (ConvertTo-PhaseDPowerShellLiteral (Join-Path $launchRoot 'resource-loopback-preflight.receipt.json'))
    ) -join "`r`n"
    if ($null -eq $runtimeBundle) { $startText = $startText.Replace($resourceBootstrapAnchor,
        $resourceBootstrapCheck + "`r`n" + $resourceBootstrapAnchor)
    }
    $variantEnvironmentAnchor =
        '    $env:EPINELPS_CLASSIC_SOLO_RAID_MANAGER_ID = [string]$context.managerId'
    Assert-PhaseD `
        (([regex]::Matches(
            $startText, [regex]::Escape($variantEnvironmentAnchor))).Count -eq 1) `
        'phase_d_staticdata_variant_environment_anchor_invalid'
    $variantEnvironmentAssignments = @(
        '    $env:EPINELPS_CLASSIC_SOLO_RAID_MANAGER_SELECTION = ' +
            (ConvertTo-PhaseDPowerShellLiteral 'profile_trusted_unique/v1')
        '    $env:EPINELPS_CLASSIC_SOLO_RAID_TARGET_PROFILE_PATH = ' +
            (ConvertTo-PhaseDPowerShellLiteral $bossRuntimeVariantProfile)
    )
    if ($staticDataVariantRequired) {
        $variantEnvironmentAssignments += @(
            '    $env:EPINELPS_CLIENT_STATIC_DATA_VARIANT_PATH = ' +
                (ConvertTo-PhaseDPowerShellLiteral $variantStaticDataPack)
            '    $env:EPINELPS_CLIENT_STATIC_DATA_VARIANT_SHA256 = ' +
                (ConvertTo-PhaseDPowerShellLiteral $variantStaticDataSha256)
        )
    }
    $startText = $startText.Replace(
        $variantEnvironmentAnchor,
        $variantEnvironmentAnchor + "`r`n" +
            ($variantEnvironmentAssignments -join "`r`n"))
    $variantEnvironmentRemovalAnchor =
        '            Env:\EPINELPS_CLASSIC_SOLO_RAID_MANAGER_ID `'
    Assert-PhaseD `
        (([regex]::Matches(
            $startText,
            [regex]::Escape($variantEnvironmentRemovalAnchor))).Count -eq 1) `
        'phase_d_staticdata_variant_cleanup_anchor_invalid'
    $variantEnvironmentRemoval = @(
        '            Env:\EPINELPS_CLASSIC_SOLO_RAID_MANAGER_ID,'
        '            Env:\EPINELPS_CLASSIC_SOLO_RAID_MANAGER_SELECTION,'
        '            Env:\EPINELPS_CLASSIC_SOLO_RAID_TARGET_PROFILE_PATH'
    )
    if ($staticDataVariantRequired) {
        $variantEnvironmentRemoval[-1] += ','
        $variantEnvironmentRemoval += @(
            '            Env:\EPINELPS_CLIENT_STATIC_DATA_VARIANT_PATH,'
            '            Env:\EPINELPS_CLIENT_STATIC_DATA_VARIANT_SHA256 `'
        )
    }
    else {
        $variantEnvironmentRemoval[-1] += ' `'
    }
    $startText = $startText.Replace(
        $variantEnvironmentRemovalAnchor,
        ($variantEnvironmentRemoval -join "`r`n"))
    $captureAnchor =
        ") 'phase3b2_epinel_minimal_completion_runtime_stop_failed'"
    Assert-PhaseD `
        (([regex]::Matches(
            $completionText, [regex]::Escape($captureAnchor))).Count -eq 1) `
        'phase_d_raid_state_capture_anchor_invalid'
    $captureCommand = @(
        '    $captureOutput = @(& ' +
            (ConvertTo-PhaseDPowerShellLiteral $runtimeMaterializer) +
            ' --capture-solo-raid-state true' +
            ' --source-db $dbPath' +
            ' --pending-payload ' +
            (ConvertTo-PhaseDPowerShellLiteral $soloRaidPendingPath) +
            ' --receipt ' +
            (ConvertTo-PhaseDPowerShellLiteral $soloRaidCaptureReceiptPath) +
            ' --account-uid ' +
            (ConvertTo-PhaseDPowerShellLiteral $accountUid) +
            ' --account-revision-set-sha256 ' +
             (ConvertTo-PhaseDPowerShellLiteral `
                 $accountRevisionSetSha256) +
             ' --season-number ' +
             (ConvertTo-PhaseDPowerShellLiteral ([string]$SeasonNumber)) +
             ' --raid-snapshot-uid ' +
             (ConvertTo-PhaseDPowerShellLiteral `
                 $raidSnapshotUid) +
             ' --raid-snapshot-sha256 ' +
             (ConvertTo-PhaseDPowerShellLiteral `
                 $raidSnapshotSha256) +
            ' --client-build-code ' + (ConvertTo-PhaseDPowerShellLiteral $clientBuildCode) +
            ' --client-executable-sha256 ' +
            (ConvertTo-PhaseDPowerShellLiteral $clientExecutableSha256) +
            ' --launch-context-uid ' +
            (ConvertTo-PhaseDPowerShellLiteral $LaunchContextUid) +
            ' --expected-head-revision-uid ' +
            (ConvertTo-PhaseDPowerShellLiteral $expectedSoloRaidHeadRevisionUid) +
            ' --identity-secret-env ' +
            (ConvertTo-PhaseDPowerShellLiteral $secretEnvironmentVariable) +
            ' 2>&1)'
        '    $captureExitCode = $LASTEXITCODE'
        '    if ($captureExitCode -ne 0) {'
        '        $captureFailureCode = @($captureOutput | ForEach-Object { [string]$_ } | Where-Object { $_ -cmatch ''^phase_d_[a-z0-9._-]{3,128}$'' }) | Select-Object -Last 1'
        '        if ([string]::IsNullOrWhiteSpace([string]$captureFailureCode)) { $captureFailureCode = ''phase_d_raid_state_capture_failed'' }'
        '        throw [string]$captureFailureCode'
        '    }'
        '    if (-not (Test-Path -LiteralPath ' +
            (ConvertTo-PhaseDPowerShellLiteral $soloRaidPendingPath) +
            ' -PathType Leaf) -or -not (Test-Path -LiteralPath ' +
            (ConvertTo-PhaseDPowerShellLiteral $soloRaidCaptureReceiptPath) +
            ' -PathType Leaf)) { throw ''phase_d_raid_state_capture_output_missing'' }'
    ) -join "`r`n"
    $completionText = $completionText.Replace(
        $captureAnchor,
        $captureAnchor + "`r`n" + $captureCommand)
    $completionText = ConvertTo-PhaseDCompletionText -Text $completionText
    Assert-PhaseD `
        ($parentCompletionText.Contains('$expectedRankingWireScore') -and
         $parentCompletionText.Contains('$rankingWirePrefix = 1130781186L')) `
        'phase_d_ranking_prefix_tool_contract_invalid'
    $runtimeDbPattern = [regex]::Escape($runtimeDbSha256)
    Assert-PhaseD `
        (($startText -cne $parentStartText) -and
         ($completionText -cne $parentCompletionText) -and
         -not $startText.Contains($expectedParentDbSha256) -and
         -not $completionText.Contains($expectedParentDbSha256) -and
         -not $startText.Contains($expectedServerDllSha256) -and
         $startText.Contains($expectedWeaknessVariantServerDllSha256) -and
         $completionText.Contains('$expectedRankingWireScore') -and
         ([regex]::Matches($startText, $runtimeDbPattern)).Count -eq 1 -and
         ([regex]::Matches($completionText, $runtimeDbPattern)).Count -eq 1) `
        'phase_d_tool_derivation_invalid'

    [pscustomobject]@{ schemaVersion = 1; contractId = 'nll/phase-d-launch-tools/v1'; startText = $startText; completionText = $completionText }
}
