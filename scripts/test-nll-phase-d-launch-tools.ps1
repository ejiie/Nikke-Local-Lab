param([string]$ReferenceCoordinatorPath = '', [string]$PinnedStartPath = '', [string]$PinnedCompletionPath = '')
# Compile strings only. Never execute a generated start/completion script.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.PhaseDLaunchTools.ps1')
. (Join-Path $PSScriptRoot 'Nll.PhaseDChildProcess.ps1')
function Assert-PhaseD([bool]$Condition, [string]$Code) { if (-not $Condition) { throw $Code } }
function Get-TextHash([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'test-nll-phase-d-completion-diagnostics.ps1'), [ref]$tokens, [ref]$errors)
$completionFixture = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$template' }, $true))[0].Right.Expression.Value
$startFixture = @'
# aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
# cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
$bootstrapRoot = 'C:\NLL\Runtime\PhysicalBootstrap-v2'
$bootstrapHash = 'ff7371b3e20119030c0f3a8e2f6ba9482094c4118f06dbcc4e0e7f137f8e404f'
$serverHash = 'a28c7ff227a74d260a29389b82caeed3fe196f91eef3d28cabe9977b5ed9d07b'
    $firewallApplied = $true
$valid = ($extensionRules.Count -eq 1 -and
    $extensionPrograms.Count -eq 1 -and
    $extensionPrograms[0].Program -ceq $bootstrapPath)
    $stageCode = 'physical_bootstrap_and_sail_observation'
    $env:EPINELPS_CLASSIC_SOLO_RAID_MANAGER_ID = [string]$context.managerId
Remove-Item `
            Env:\EPINELPS_CLASSIC_SOLO_RAID_MANAGER_ID `
            -ErrorAction SilentlyContinue
'@
$completionFixture = ('# ' + ('a' * 64) + "`n" + '# $expectedRankingWireScore' + "`n" +
    '$rankingWirePrefix = 1130781186L' + "`n" + "Assert-True (`$true) 'phase3b2_epinel_minimal_completion_runtime_stop_failed'`n") + $completionFixture
$completionFixture = $completionFixture.Replace("`r`n", "`n")
$startFixture = $startFixture.Replace("`r`n", "`n")
# Captured from the pre-extraction coordinator, using only these synthetic inputs.
$goldenStart = @{
    '150-False' = 'c95c0b009585d512dd23eb66d5d7a98c710093ac26fd5d379d5540e9d1d6109b'
    '150-True' = '512e4cebd0dd1ad176384454cea023299208a963557468b23f6a6d021c7ab113'
    '151-False' = 'f26c6529901645ae726402a94d91eebd22a615724f35d8e3eedfb3765167cf6f'
    '151-True' = 'a26184177d06089b06a7cc9285f3803c83ced68c76f13fac11aa87decaecb7f8'
}
$goldenCompletion = @{ '150' = 'a5a1edaf7fc9f734bbbe79f4d528ada78bdde6b2c6d7b123ed8115e3d2b55384'; '151' = '888e24b8625f53fb2a9114cb7e1f9684d9ee324e2efe883492dad7925cd573f7' }
if ($PinnedStartPath -or $PinnedCompletionPath) {
    Assert-PhaseD ((Get-PdBundleHash $PinnedStartPath) -ceq '8462e1d35bb019f77cdba27e9d2fe440edb90d510ef76222eaf53421d2c01c37' -and
        (Get-PdBundleHash $PinnedCompletionPath) -ceq '5277d6ea79410acbe79d7581461bc3e1d07fb6baa9d695b97d46237c839466d4') 'test_parent_pin_mismatch'
    $startFixture = [IO.File]::ReadAllText($PinnedStartPath)
    $completionFixture = [IO.File]::ReadAllText($PinnedCompletionPath)
}
$referenceBody = $null
$coordinator = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'invoke-nll-phase-d-execution.ps1'))
$mapBegin = $coordinator.IndexOf('    $launchToolInput =', [StringComparison]::Ordinal)
$mapEnd = $coordinator.IndexOf('    [IO.File]::WriteAllText($derivedStart', [StringComparison]::Ordinal)
Assert-PhaseD ($mapBegin -gt 0 -and $mapEnd -gt $mapBegin) 'coordinator_input_boundary_missing'
$mappingBody = [scriptblock]::Create($coordinator.Substring($mapBegin, $mapEnd - $mapBegin) +
    "`n[pscustomobject]@{ startText = `$startText; completionText = `$completionText }")
if ($ReferenceCoordinatorPath) {
    $reference = [IO.File]::ReadAllText($ReferenceCoordinatorPath)
    $begin = $reference.IndexOf('    $expectedParentDbPattern =', [StringComparison]::Ordinal)
    $end = $reference.IndexOf('    [IO.File]::WriteAllText($derivedStart', [StringComparison]::Ordinal)
    Assert-PhaseD ($begin -gt 0 -and $end -gt $begin) 'test_reference_block_missing'
    $reference = $reference.Substring($begin, $end - $begin)
    $begin = $reference.IndexOf('    $soloRaidStateRoot =', [StringComparison]::Ordinal)
    $end = $reference.IndexOf('    $captureAnchor =', [StringComparison]::Ordinal)
    Assert-PhaseD ($begin -gt 0 -and $end -gt $begin) 'test_reference_state_block_missing'
    # Exclude the sole filesystem mutation block from the old implementation.
    $referenceBody = [scriptblock]::Create($reference.Remove($begin, $end - $begin) +
        "`n[pscustomobject]@{ startText = `$startText; completionText = `$completionText }")
}
foreach ($build in @('150','151')) {
  foreach ($variant in @($false,$true)) {
    $spec = [ordered]@{
      schemaVersion = 1; contractId = 'nll/phase-d-launch-tools-input/v1'
      parentStartText = $startFixture; parentCompletionText = $completionFixture
      expectedParentDbSha256 = ('a' * 64); runtimeDbSha256 = ('b' * 64)
      expectedServerDllSha256 = ('c' * 64); expectedWeaknessVariantServerDllSha256 = ('d' * 64)
      runtimeBundle = $null
      resourcePreflightHelper = 'C:\synthetic\helper.ps1'; resourcePreflightHelperSha256 = ('e' * 64)
      resourcePreflightTool = 'C:\synthetic\preflight.exe'; resourceCatalogReceiptPath = 'C:\synthetic\catalog.json'
      resourceCatalogReceiptSha256 = ('e' * 64); resourcePreflightToolSha256 = ('e' * 64)
      launchRoot = 'C:\synthetic\launch'; bossRuntimeVariantProfile = "C:\synthetic\operator's profile.json"
      staticDataVariantRequired = $variant; variantStaticDataPack = 'C:\synthetic\pack'; variantStaticDataSha256 = ('f' * 64)
      runtimeMaterializer = 'C:\synthetic\materializer.exe'; soloRaidPendingPath = 'C:\synthetic\pending.json'
      soloRaidCaptureReceiptPath = 'C:\synthetic\capture.json'; accountUid = '00000000-0000-0000-0000-000000000001'
      accountRevisionSetSha256 = ('1' * 64); SeasonNumber = 26; raidSnapshotUid = '00000000-0000-0000-0000-000000000002'
      raidSnapshotSha256 = ('2' * 64); clientBuildCode = 'build_150.6.9'; clientExecutableSha256 = ('3' * 64)
      LaunchContextUid = '00000000-0000-0000-0000-000000000003'; expectedSoloRaidHeadRevisionUid = 'none'
      secretEnvironmentVariable = 'SYNTHETIC_SECRET_NAME_ONLY'
    }
    if ($PinnedStartPath) {
      $spec.expectedParentDbSha256 = 'dee9c6aa5421287ca030e325b81a90a302a5d9e113d57c3065e5d36f6e7c4019'
      $spec.expectedServerDllSha256 = '98d4f4d12ff83c694ee052f9eca3c63ae782f2c4747a80993ee257384eef2498'
    }
    if ($build -eq '151') {
      $spec.clientBuildCode = 'build_151.8.5'
      $spec.runtimeBundle = [pscustomobject]@{ bootstrapRoot = 'C:\synthetic\151'; bootstrap = @{ sha256 = ('e' * 64) }; serverExe = @{ sha256 = ('f' * 64) } }
    }
    $actual = New-PhaseDLaunchToolText $spec
    # Execute the actual coordinator's pure input mapping against synthetic data.
    # This catches misspelled/nested bindings, not just the adapter in isolation.
    $mapped = & {
      foreach ($key in $spec.Keys) { Set-Variable -Name $key -Value $spec[$key] -Scope Local }
      $candidate = [pscustomobject]@{ accountUid = $spec.accountUid; baseRevisions = @{ revisionSetSha256 = $spec.accountRevisionSetSha256 } }
      $materialization = [pscustomobject]@{ raidSnapshotUid = $spec.raidSnapshotUid; raidSnapshotSha256 = $spec.raidSnapshotSha256 }
      & $mappingBody
    }
    Assert-PhaseD ($mapped.startText -ceq $actual.startText -and $mapped.completionText -ceq $actual.completionText) 'coordinator_input_mapping_changed'
    if (-not $PinnedStartPath) {
      Assert-PhaseD ((Get-TextHash $actual.startText) -ceq $goldenStart["$build-$variant"] -and
          (Get-TextHash $actual.completionText) -ceq $goldenCompletion[$build]) 'golden_output_changed'
    }
    if ($referenceBody) {
      $expected = & {
        foreach ($key in $spec.Keys) { Set-Variable -Name $key -Value $spec[$key] -Scope Local }
        $candidate = [pscustomobject]@{ accountUid = $spec.accountUid; baseRevisions = @{ revisionSetSha256 = $spec.accountRevisionSetSha256 } }
        $materialization = [pscustomobject]@{ raidSnapshotUid = $spec.raidSnapshotUid; raidSnapshotSha256 = $spec.raidSnapshotSha256 }
        & $referenceBody
      }
      Assert-PhaseD ($actual.startText -ceq $expected.startText -and $actual.completionText -ceq $expected.completionText) 'legacy_output_changed'
    }
    foreach ($text in @($actual.startText, $actual.completionText)) {
      $null = [Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
      Assert-PhaseD ($errors.Count -eq 0) 'generated_script_parse_failed'
    }
    Assert-PhaseD ($actual.startText.Contains("operator''s profile.json")) 'literal_not_escaped'
    Assert-PhaseD (($actual.startText.Contains('required_resource_catalog_set_loopback_preflight')) -eq ($build -eq '150')) 'resource_lane_changed'
    Assert-PhaseD (($actual.startText.Contains('EPINELPS_CLIENT_STATIC_DATA_VARIANT_PATH')) -eq $variant) 'variant_lane_changed'
    $spec.contractId = 'unsupported'
    $rejected = $false
    try { $null = New-PhaseDLaunchToolText $spec } catch { $rejected = $_.Exception.Message -ceq 'phase_d_launch_tools_input_invalid' }
    Assert-PhaseD $rejected 'invalid_input_accepted'
    $spec.contractId = 'nll/phase-d-launch-tools-input/v1'
    $spec.unrecognized = 'unexpected'
    $rejected = $false
    try { $null = New-PhaseDLaunchToolText $spec } catch { $rejected = $_.Exception.Message -ceq 'phase_d_launch_tools_input_invalid' }
    Assert-PhaseD $rejected 'unknown_field_accepted'
    $spec.Remove('unrecognized')
    $spec.parentStartText += "`n    `$stageCode = 'physical_bootstrap_and_sail_observation'"
    $rejected = $false
    try { $null = New-PhaseDLaunchToolText $spec } catch { $rejected = $_.Exception.Message -ceq 'phase_d_resource_preflight_anchor_invalid' }
    Assert-PhaseD $rejected 'ambiguous_template_accepted'
    [pscustomobject]@{ build = $build; variant = $variant; startSha256 = Get-TextHash $actual.startText; completionSha256 = Get-TextHash $actual.completionText; goldenChecked = -not [bool]$PinnedStartPath; referenceComparisonPerformed = [bool]$referenceBody }
  }
}
