namespace NikkeLocalLab.Admin.Api.UnitTests;

public sealed class PhaseDArtifactSafetyTests
{
  [Fact]
  public void PhaseDExecutionUsesDerivedRuntimeAndOnDemandPersistentDatabase()
  {
    var root = FindRepositoryRoot();
    var coordinator = File.ReadAllText(Path.Combine(root, "scripts", "invoke-nll-phase-d-execution.ps1"));
    Assert.Contains("New-PhaseDRunnerSpecification -LaunchInput $runnerLaunchInput", coordinator, StringComparison.Ordinal);
    Assert.DoesNotContain("Nll.PhaseDLaunchTools.ps1", coordinator, StringComparison.Ordinal);
    Assert.DoesNotContain("$parentStart", coordinator, StringComparison.Ordinal);
    Assert.DoesNotContain("$parentCompletion", coordinator, StringComparison.Ordinal);
    Assert.Contains("Get-PhaseDPreparation -RepositoryRoot $RepositoryRoot", coordinator, StringComparison.Ordinal);
    coordinator += File.ReadAllText(Path.Combine(root, "scripts", "Nll.PhaseDRunnerStart.ps1"));
    coordinator += File.ReadAllText(Path.Combine(root, "scripts", "Nll.PhaseDRunnerComplete.ps1"));
    coordinator += File.ReadAllText(Path.Combine(root, "scripts", "Nll.PhaseDPreparation.ps1"));
    var watcher = File.ReadAllText(Path.Combine(root, "scripts", "watch-nll-phase-d-execution.ps1"));
    var recovery = File.ReadAllText(Path.Combine(
        root, "scripts", "recover-nll-phase-d-orphaned-execution.ps1"));
    var installer = File.ReadAllText(Path.Combine(root, "scripts", "deploy-nll-phase-d-control-center-offline.ps1"));
    var repair = File.ReadAllText(Path.Combine(
        root, "scripts", "repair-nll-phase-d-control-center-application.ps1"));
    var raidBindingRepair = File.ReadAllText(Path.Combine(
        root, "scripts", "repair-nll-phase-d-raid-catalog-binding.ps1"));
    var repairAndSmoke = File.ReadAllText(Path.Combine(
        root, "scripts", "invoke-nll-phase-d-repair-and-smoke.ps1"));
    var installationSmoke = File.ReadAllText(Path.Combine(
        root, "scripts", "test-nll-phase-d-control-center-installation.ps1"));
    var start = File.ReadAllText(Path.Combine(root, "scripts", "start-nll-phase-d-control-center.ps1"));
    var stop = File.ReadAllText(Path.Combine(root, "scripts", "stop-nll-phase-d-control-center.ps1"));
    var lifecycleSmoke = File.ReadAllText(Path.Combine(
        root, "scripts", "test-nll-phase-d-control-center-lifecycle.ps1"));
    var overloadStateEffectSmoke = File.ReadAllText(Path.Combine(
        root, "scripts", "test-nll-phase-d-overload-state-effect-materialization.ps1"));
    var clientStartScripts = new[]
    {
      "start-phase3b2-epinel-minimal-reference-in-micron.ps1",
      "start-phase3b2-epinel-user-progression-v2-in-micron.ps1",
      "start-phase3b2-epinel-solo-raid-unlock-v1-in-micron.ps1"
    }.Select(name => File.ReadAllText(Path.Combine(root, "scripts", name))).ToArray();
    var presentationAssets = File.ReadAllText(
        Path.Combine(root, "scripts", "materialize-nll-phase-d-presentation-assets.ps1"));
    var materializer = File.ReadAllText(
        Path.Combine(root, "tools", "NikkeLocalLab.PhaseD.RuntimeMaterializer", "Program.cs"));
    var weaknessVariantMaterializer = File.ReadAllText(Path.Combine(
        root,
        "tools",
        "NikkeLocalLab.PhaseD.RuntimeMaterializer",
        "BossAffinityStaticDataVariant.cs"));
    var materializerState = File.ReadAllText(Path.Combine(
        root,
        "tools",
        "NikkeLocalLab.PhaseD.RuntimeMaterializer",
        "ClassicSoloRaidRuntimeState.cs"));
    var runtimeStateStore = File.ReadAllText(Path.Combine(
        root,
        "src",
        "NikkeLocalLab.Persistence.PostgreSql",
        "ClassicSoloRaidRuntimeStateStore.cs"));
    var executionService = File.ReadAllText(
        Path.Combine(root, "src", "NikkeLocalLab.Admin.Api", "PhaseDExecution.cs"));
    var documentContract = File.ReadAllText(Path.Combine(
        root,
        "src",
        "NikkeLocalLab.Application.ProfileManagement",
        "PhaseDExecutionDocuments.cs"));

    Assert.Contains("EpinelPS-SoloRaidRankingPrefix-v9", coordinator, StringComparison.Ordinal);
    Assert.DoesNotContain("rankingPrefixServerDll", coordinator, StringComparison.Ordinal);
    Assert.DoesNotContain("phase_d_ranking_prefix_server_overlay_failed", coordinator,
        StringComparison.Ordinal);
    Assert.Contains("phase_d_ranking_prefix_server_copy_failed", coordinator,
        StringComparison.Ordinal);
    Assert.Contains("$rankingWirePrefix = 1130781186L", coordinator,
        StringComparison.Ordinal);
    Assert.Contains("$expectedRankingWireScore", coordinator, StringComparison.Ordinal);
    Assert.Contains("Assert-PhaseDRunnerStartDependencies $runnerSpec", coordinator,
        StringComparison.Ordinal);
    Assert.Contains("parent_server_dll", coordinator, StringComparison.Ordinal);
    Assert.DoesNotContain("applied_server_dll", coordinator, StringComparison.Ordinal);
    Assert.Contains("server_dll", coordinator, StringComparison.Ordinal);
    Assert.Contains("phase_d_weakness_variant_server_overlay_failed", coordinator,
        StringComparison.Ordinal);
    Assert.Contains("phase-d\\weakness-variant-server", coordinator,
        StringComparison.Ordinal);
    Assert.Contains("--weakness-code $WeaknessCode", coordinator,
        StringComparison.Ordinal);
    Assert.Contains("[int]$SeasonNumber", coordinator, StringComparison.Ordinal);
    Assert.Contains("boss-runtime-variants\\registry.json", coordinator,
        StringComparison.Ordinal);
    Assert.Contains("$_.seasonNumber -eq $SeasonNumber", coordinator,
        StringComparison.Ordinal);
    Assert.DoesNotContain("config\\boss-runtime-variants\\season-26-providence.json",
        coordinator, StringComparison.Ordinal);
    Assert.DoesNotContain("--season-number '26'", coordinator, StringComparison.Ordinal);
    Assert.Contains("$staticDataVariantRequired = [bool]$staticDataVariant.variantRequired",
        coordinator, StringComparison.Ordinal);
    Assert.Contains("phase_d_boss_behavior_asset_closure_invalid",
        coordinator, StringComparison.Ordinal);
    Assert.Contains("phase_d_boss_shield_fx_asset_closure_invalid",
        coordinator, StringComparison.Ordinal);
    Assert.Contains("targetBossElementCode", coordinator, StringComparison.Ordinal);
    Assert.Contains("bossVariantRegistrySha256", coordinator, StringComparison.Ordinal);
    Assert.Contains("--source-static-pack $sourceStaticDataPack", coordinator,
        StringComparison.Ordinal);
    Assert.Contains("--variant-static-pack $variantStaticDataPack", coordinator,
        StringComparison.Ordinal);
    Assert.Contains("EPINELPS_CLIENT_STATIC_DATA_VARIANT_PATH", coordinator,
        StringComparison.Ordinal);
    Assert.Contains("EPINELPS_CLIENT_STATIC_DATA_VARIANT_SHA256", coordinator,
        StringComparison.Ordinal);
    Assert.Contains("staticDataVariantReceiptSha256", coordinator,
        StringComparison.Ordinal);
    Assert.Contains("nll/boss-affinity-static-data-variant/v1",
        weaknessVariantMaterializer, StringComparison.Ordinal);
    Assert.Contains("BossAffinityStaticDataVariant", weaknessVariantMaterializer,
        StringComparison.Ordinal);
    Assert.Contains("profile.SelectedManagerObservation", weaknessVariantMaterializer,
        StringComparison.Ordinal);
    Assert.Contains("phase_d_boss_variant_source_affinity_mismatch",
        weaknessVariantMaterializer, StringComparison.Ordinal);
    Assert.Contains("ValidateElementTableIndex",
        weaknessVariantMaterializer, StringComparison.Ordinal);
    Assert.Contains("phase_d_staticdata_target_monster_reference_not_isolated",
        weaknessVariantMaterializer, StringComparison.Ordinal);
    Assert.Contains("target_monster_element_reference", weaknessVariantMaterializer,
        StringComparison.Ordinal);
    Assert.Contains("officialInstallModified = false", weaknessVariantMaterializer,
        StringComparison.Ordinal);
    Assert.Contains("pending_original_client_runtime_observation",
        weaknessVariantMaterializer, StringComparison.Ordinal);
    Assert.Contains("P3SRRP9D\\source.manifest.tsv", coordinator,
        StringComparison.Ordinal);
    Assert.Contains("P3SRRP9D\\deployment.receipt.json", coordinator,
        StringComparison.Ordinal);
    Assert.Contains(
        "d360b29ca19fa36c6c1504d7b29a30d541621bf5855b45810f87e43d9e63a269",
        coordinator,
        StringComparison.Ordinal);
    Assert.Contains("completionVerifierSeparatesRawAndWireDomains", coordinator,
        StringComparison.Ordinal);
    Assert.Contains("phase_d_ranking_prefix_deployment_drifted", coordinator,
        StringComparison.Ordinal);
    Assert.Contains("phase_d_ranking_prefix_deployment_contract_invalid", coordinator,
        StringComparison.Ordinal);
    Assert.DoesNotContain("wireProjectionReplacements", coordinator,
        StringComparison.Ordinal);
    Assert.Contains("serverSourceManifestSha256", coordinator, StringComparison.Ordinal);
    Assert.Contains("$runtimeRoot", coordinator, StringComparison.Ordinal);
    Assert.Contains("/XJ", coordinator, StringComparison.Ordinal);
    Assert.Contains("New-Item -ItemType Junction", coordinator, StringComparison.Ordinal);
    Assert.Contains("NLL_CONTROL_CENTER_PG_CTL", coordinator, StringComparison.Ordinal);
    Assert.DoesNotContain("@('stop', '-D', $controlCenterPgData, '-m', 'fast'", coordinator,
        StringComparison.Ordinal);
    Assert.Contains("$BootstrapEvidenceLane = 'p2-client-start-v2'", coordinator, StringComparison.Ordinal);
    Assert.DoesNotContain("'phase-d-client-start-' + $LaunchContextUid", coordinator,
        StringComparison.Ordinal);
    Assert.Contains("Assert-PhaseDPostgresRunning", coordinator, StringComparison.Ordinal);
    Assert.Contains("Ensure-PhaseDPostgresRunning", watcher, StringComparison.Ordinal);
    Assert.DoesNotContain("'-t' '60' |", coordinator + watcher, StringComparison.Ordinal);
    Assert.DoesNotContain("Start-Process -FilePath $PgCtlPath", coordinator + watcher,
        StringComparison.Ordinal);
    Assert.Contains("'Nll.PhaseDChildProcess.ps1'", coordinator, StringComparison.Ordinal);
    Assert.Contains("'Nll.PhaseDChildProcess.ps1'", watcher, StringComparison.Ordinal);
    // Shared helper's real exit-code/argument/descendant behavior is exercised
    // by the exact-child and shared-state checks, not by its spelling here.
    Assert.Contains(
        "$failureStatusCode = if ($coordinatorRollbackProven) { 'failed' } else { 'started' }",
        coordinator,
        StringComparison.Ordinal);
    Assert.Contains("Test-PhaseDDerivedStartRollbackProof", coordinator,
        StringComparison.Ordinal);
    Assert.Contains("Test-DerivedStartRollbackProof", recovery,
        StringComparison.Ordinal);
    Assert.Contains("nll/phase3b2-epinel-solo-raid-ranking-prefix-failure/v9",
        coordinator + recovery,
        StringComparison.Ordinal);
    Assert.DoesNotContain("-not [bool]$failure.clientExecutionStarted",
        coordinator + recovery,
        StringComparison.Ordinal);
    Assert.Contains("$runtimeProcessesCold", coordinator + recovery,
        StringComparison.Ordinal);
    Assert.Contains("$innerHostsRestored", coordinator, StringComparison.Ordinal);
    Assert.Contains("$hostsRollbackProven", recovery, StringComparison.Ordinal);
    foreach (var clientStartScript in clientStartScripts)
    {
      Assert.Contains(
          "$measurementElapsedMilliseconds = [long]$deadline.Elapsed.TotalMilliseconds",
          clientStartScript,
          StringComparison.Ordinal);
      Assert.Contains("Record a terminal sample", clientStartScript,
          StringComparison.Ordinal);
      Assert.DoesNotContain("[long]$samples[-1].offsetMilliseconds",
          clientStartScript,
          StringComparison.Ordinal);
    }
    Assert.Contains("profile_trusted_unique/v1", coordinator, StringComparison.Ordinal);
    Assert.Contains(
        "Set-ExecutionState -StatusCode $failureStatusCode -FailureCode $failureCode",
        coordinator,
        StringComparison.Ordinal);
    // Failure-state publication versus PG restart is covered by the actual
    // coordinator failure-block behavior tests, not a fixed source ordering.
    Assert.Contains("ControlCenterPgCtlPath", watcher, StringComparison.Ordinal);
    Assert.Contains("-DataPath $ControlCenterPgDataPath -LogPath $ControlCenterPgLogPath", watcher,
        StringComparison.Ordinal);
    Assert.Contains("ProtectedData]::Protect", installer, StringComparison.Ordinal);
    Assert.Contains("ProtectedData]::Unprotect", start, StringComparison.Ordinal);
    Assert.Contains("C:\\NLL\\ControlCenter", installer, StringComparison.Ordinal);
    Assert.Contains("EpinelPS-SoloRaidRankingPrefix-v9", installer,
        StringComparison.Ordinal);
    Assert.Contains("'raid-catalog-import'", installer,
        StringComparison.Ordinal);
    Assert.Contains("'raid-catalog-import'", raidBindingRepair,
        StringComparison.Ordinal);
    Assert.Contains("--verify-solo-raid-binding", raidBindingRepair,
        StringComparison.Ordinal);
    Assert.Contains("$process.WaitForExit()", repairAndSmoke,
        StringComparison.Ordinal);
    Assert.DoesNotContain("-Wait `", repairAndSmoke, StringComparison.Ordinal);
    Assert.Contains("if ($SmokeOnly) { $command += ' -SmokeOnly' }", repairAndSmoke,
        StringComparison.Ordinal);
    Assert.Contains("if (-not $SmokeOnly)", repairAndSmoke, StringComparison.Ordinal);
    Assert.Contains("phase_d_installation_smoke_passed", repairAndSmoke,
        StringComparison.Ordinal);
    Assert.Contains("$postgresStartAttempted = $true", raidBindingRepair,
        StringComparison.Ordinal);
    Assert.Contains("$operationFailure = $_", raidBindingRepair,
        StringComparison.Ordinal);
    Assert.True(
        raidBindingRepair.IndexOf(
            "[Environment]::SetEnvironmentVariable($name, $null, 'Process')",
            StringComparison.Ordinal) <
        raidBindingRepair.IndexOf(
            "if ($null -ne $postgresStopFailure) { throw $postgresStopFailure }",
            StringComparison.Ordinal));
    Assert.True(
        raidBindingRepair.IndexOf(
            "if (-not $runtimeColdAfterCleanup)",
            StringComparison.Ordinal) <
        raidBindingRepair.IndexOf(
            "if ($null -ne $operationFailure) { throw $operationFailure }",
            StringComparison.Ordinal));
    Assert.Contains("--verify-solo-raid-binding", installationSmoke,
        StringComparison.Ordinal);
    Assert.Contains("installation-smoke-materializer", installationSmoke,
        StringComparison.Ordinal);
    Assert.Contains("hostpolicy.dll", installationSmoke, StringComparison.Ordinal);
    Assert.Contains("Get-ChildItem -LiteralPath $MaterializerBuildRoot -File",
        installationSmoke, StringComparison.Ordinal);
    Assert.DoesNotContain(
        "$materializer = Join-Path $RepositoryRoot `\n        'artifacts\\phase-d\\runtime-materializer",
        installationSmoke,
        StringComparison.Ordinal);
    Assert.Contains("IsVerifyBindingMode", materializer + materializerState,
        StringComparison.Ordinal);
    Assert.Contains("eligible_catalog AS", runtimeStateStore,
        StringComparison.Ordinal);
    Assert.Contains("ARRAY[7,13,26,29,34,40]::integer[]", runtimeStateStore,
        StringComparison.Ordinal);
    Assert.Contains("WHERE NOT EXISTS (SELECT 1 FROM effective_boot)", runtimeStateStore,
        StringComparison.Ordinal);
    Assert.DoesNotContain("3b100000-0000-4000-8000-000000000026",
        runtimeStateStore + materializer + materializerState + installer +
        repair + raidBindingRepair,
        StringComparison.OrdinalIgnoreCase);
    Assert.Contains("EpinelPS-SoloRaidRankingPrefix-v9", overloadStateEffectSmoke,
        StringComparison.Ordinal);
    Assert.Contains("AssetDownloadUtil.ConfigureOfficialOutbound(false)", materializer, StringComparison.Ordinal);
    Assert.Contains("favoriteCharacterUid", materializer, StringComparison.Ordinal);
    Assert.DoesNotContain("favoriteCharacterNameCode", materializer, StringComparison.Ordinal);
    Assert.Contains("FavoriteItemRare.SR => \"sr\"", materializer, StringComparison.Ordinal);
    Assert.Contains("phase_d_presentation_collection_rarity_invalid", materializer,
        StringComparison.Ordinal);
    Assert.Contains("StatType.Atk => \"공격력\"", materializer, StringComparison.Ordinal);
    Assert.Contains("StatType.Defence => \"방어력\"", materializer, StringComparison.Ordinal);
    Assert.Contains("PhaseDExecutionDocumentJson.CreateOptions()", materializer, StringComparison.Ordinal);
    Assert.Contains("phase_d_materializer_uncontrolled_failure", materializer, StringComparison.Ordinal);
    // Cube selection/deduplication is exercised against actual compiled output
    // by the pinned Materializer.BehaviorChecks local gate, not source spelling.
    Assert.Contains("IntegerOrZeroWhenNotApplicable(values, \"core_level\"", materializer,
        StringComparison.Ordinal);
    Assert.Contains("IntegerOrZeroWhenNotApplicable(values, \"bond_level\"", materializer,
        StringComparison.Ordinal);
    Assert.Contains("BooleanOrFalseWhenNotApplicable", materializer, StringComparison.Ordinal);
    Assert.Contains("stateEffect.StateEffectId);", materializer, StringComparison.Ordinal);
    Assert.DoesNotContain("row.DecimalScale), option.Id", materializer, StringComparison.Ordinal);
    Assert.Contains("phase_d_overload_state_effect_mapping_invalid", materializer,
        StringComparison.Ordinal);
    Assert.Contains("character.Level = user.SynchroDeviceLevel;", materializer,
        StringComparison.Ordinal);
    Assert.DoesNotContain(
        "character.Level = CheckedInteger(RequiredValue(values, \"character_level\", subject));",
        materializer,
        StringComparison.Ordinal);
    Assert.Contains("$materializerFailureCode", coordinator, StringComparison.Ordinal);
    Assert.Contains("ExpectedBundleSha256=$runnerBundle.sha256", coordinator, StringComparison.Ordinal);
    Assert.Contains("(Get-Sha256Hex $dbPath) -ceq $expectedDbSha256", coordinator, StringComparison.Ordinal);
    Assert.Contains("'phase3b2_epinel_minimal_start_digest_invalid'", coordinator, StringComparison.Ordinal);
    Assert.DoesNotContain("$completionText", coordinator, StringComparison.Ordinal);
    Assert.Contains("Physical-P0-v1\\hosts.original.bin", coordinator, StringComparison.Ordinal);
    Assert.Contains("PhysicalP2-v2\\hosts.before.bin", coordinator, StringComparison.Ordinal);
    Assert.Contains("phase_d_hosts_baseline_invalid", coordinator, StringComparison.Ordinal);
    Assert.Contains("$expectedPostDockerUninstallCleanHostsSha256", coordinator,
        StringComparison.Ordinal);
    Assert.Contains("$controlCenterHostsOriginalSha256 -in @(", coordinator,
        StringComparison.Ordinal);
    Assert.Contains("$finalHostsSha256 -in @(", coordinator,
        StringComparison.Ordinal);
    Assert.Contains("control-center-hosts.before.bin", coordinator, StringComparison.Ordinal);
    Assert.Contains("hosts-restoration.receipt.json", coordinator, StringComparison.Ordinal);
    Assert.Contains("officialDomainsUnboundAfterCompletion", coordinator,
        StringComparison.Ordinal);
    Assert.Contains("Invoke-PhaseDChildScript", coordinator, StringComparison.Ordinal);
    Assert.DoesNotContain("$startOutput = & $derivedStart", coordinator, StringComparison.Ordinal);
    Assert.DoesNotContain("-RedirectStandardOutput $StandardOutputPath", coordinator,
        StringComparison.Ordinal);
    // Exact-child lifetime (including inherited pipes and a live descendant)
    // is verified by PhaseDProcessRunnerTests using the shared helper itself.
    Assert.Contains("ControlCenterHostsBackupPath", watcher, StringComparison.Ordinal);
    Assert.Contains("Restore-ControlCenterHosts", watcher, StringComparison.Ordinal);
    Assert.Contains("officialDomainsUnboundAfterCompletion", watcher,
        StringComparison.Ordinal);
    Assert.DoesNotContain("$completionOutput = & $CompletionScriptPath", watcher,
        StringComparison.Ordinal);
    Assert.Contains("completion-watcher.identity.json", coordinator, StringComparison.Ordinal);
    Assert.Contains("watcherProcessStartedAtUtc", coordinator + watcher + executionService,
        StringComparison.Ordinal);
    Assert.Contains("phase_d_emergency_rollback_baseline_missing", coordinator + watcher,
        StringComparison.Ordinal);
    Assert.Contains("phase_d_emergency_rollback_baseline_restore_failed",
        coordinator + watcher, StringComparison.Ordinal);
    Assert.Contains("phase_d_raid_state_capture_missing_before_rollback",
        coordinator + watcher + recovery, StringComparison.Ordinal);
    Assert.Contains("phase_d_orphan_recovery_rollback_unproven", recovery,
        StringComparison.Ordinal);
    Assert.DoesNotContain(
        "if (-not (Test-Path -LiteralPath $pointerPath -PathType Leaf)) { return }",
        coordinator + watcher,
        StringComparison.Ordinal);
    Assert.True(
        coordinator.IndexOf("$watcherOwnershipTransferred = $true", StringComparison.Ordinal) <
        coordinator.IndexOf("Start-Sleep -Milliseconds 500", StringComparison.Ordinal));
    Assert.Contains("if ($watcherOwnershipTransferred)", coordinator,
        StringComparison.Ordinal);
    Assert.Contains("phase_d_completion_watcher_exited_before_handoff", coordinator,
        StringComparison.Ordinal);
    Assert.Contains("phase_d_orphaned_execution_recovered", recovery, StringComparison.Ordinal);
    Assert.Contains("phase_d_orphan_recovery_runtime_not_cold", recovery,
        StringComparison.Ordinal);
    Assert.Contains("active-run.pointer.orphan-recovery-", recovery, StringComparison.Ordinal);
    Assert.Contains("control-center-hosts.before.bin", recovery, StringComparison.Ordinal);
    // Recovery timing and read-only GET behavior are exercised by
    // PhaseDExecutionStateTests, not pinned to a particular method name here.
    Assert.Contains("RequiresOrphanRecovery", executionService, StringComparison.Ordinal);
    Assert.Contains("active-run.pointer.json", executionService, StringComparison.Ordinal);
    Assert.Contains("payload.pending.json", executionService, StringComparison.Ordinal);
    Assert.Contains("capture.receipt.json", executionService, StringComparison.Ordinal);
    Assert.Contains("persistence.receipt.json", executionService, StringComparison.Ordinal);
    Assert.Contains("SoloRaidStateRoot", executionService, StringComparison.Ordinal);
    Assert.Contains("hostProcessStartedAtUtc", start, StringComparison.Ordinal);
    Assert.Contains("control_center_orphan_postgresql_stop_failed", start,
        StringComparison.Ordinal);
    Assert.Contains("adminProcessStartedAtUtc", stop, StringComparison.Ordinal);
    Assert.Contains("sessionPinnedToHostAndAdmin=$true", lifecycleSmoke,
        StringComparison.Ordinal);
    Assert.Contains("sessionRemovedAfterStop=$true", lifecycleSmoke,
        StringComparison.Ordinal);
    Assert.Contains("staleSessionRecovered=$true", lifecycleSmoke,
        StringComparison.Ordinal);
    Assert.Contains("phase_d_overload_smoke_parent_option_id_persisted",
        overloadStateEffectSmoke, StringComparison.Ordinal);
    Assert.Contains("phase_d_synchro_level_projection_mismatch",
        overloadStateEffectSmoke, StringComparison.Ordinal);
    Assert.Contains("materializerStateEffectAdmissionPassed = $true",
        overloadStateEffectSmoke, StringComparison.Ordinal);
    Assert.Contains("sourceDatabaseModified = $false", overloadStateEffectSmoke,
        StringComparison.Ordinal);
    Assert.Contains("derivedDatabaseRetained = $false", overloadStateEffectSmoke,
        StringComparison.Ordinal);
    Assert.Contains("failedProjection?.FailureCode", executionService, StringComparison.Ordinal);
    Assert.Contains("PropertyNamingPolicy = JsonNamingPolicy.CamelCase", documentContract,
        StringComparison.Ordinal);
    Assert.Contains("UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow", documentContract,
        StringComparison.Ordinal);
    // A negative guard is not an official installation input/output. Require the
    // exact rejection and exempt only that expression, not other path references.
    const string officialPathRejection = """
        Require(!path.StartsWith(@"C:\NIKKE", StringComparison.OrdinalIgnoreCase),
              "phase_d_user_validation_official_path_rejected");
        """;
    Assert.Contains(officialPathRejection, materializer, StringComparison.Ordinal);
    Assert.DoesNotContain("C:\\NIKKE", coordinator + watcher + recovery + installer + start + stop +
        materializer.Replace(officialPathRejection, string.Empty, StringComparison.Ordinal),
        StringComparison.OrdinalIgnoreCase);
    Assert.DoesNotContain("D:\\", coordinator + watcher + recovery + installer + start + stop + materializer,
        StringComparison.OrdinalIgnoreCase);
    Assert.DoesNotContain("New-Service", installer + start, StringComparison.OrdinalIgnoreCase);
    Assert.DoesNotContain("ScheduledTask", installer + start, StringComparison.OrdinalIgnoreCase);
    Assert.Contains("sg-tools-cdn.blablalink.com", presentationAssets, StringComparison.Ordinal);
    Assert.Contains("official_blablalink_shiftys_pad_mi_image", presentationAssets,
        StringComparison.Ordinal);
    Assert.DoesNotContain("nikke-db", presentationAssets, StringComparison.OrdinalIgnoreCase);
  }

  [Fact]
  public void RuntimeMaterializerRestoresSoloRaidStateBeforeWritingTheDerivedDatabase()
  {
    var root = FindRepositoryRoot();
    var materializer = File.ReadAllText(Path.Combine(
        root,
        "tools",
        "NikkeLocalLab.PhaseD.RuntimeMaterializer",
        "Program.cs"));

    var profileMaterialization = RequiredIndex(
        materializer,
        "Materialize(user, candidate, lobby, mappings);");
    var soloRaidRestore = RequiredIndex(
        materializer,
        "var restoredSoloRaidState = await ClassicSoloRaidRuntimeState.RestoreAsync(",
        profileMaterialization);
    var derivedDatabaseWrite = RequiredIndex(
        materializer,
        "Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(outputDatabasePath))!);",
        soloRaidRestore);
    var materializationReceiptWrite = RequiredIndex(
        materializer,
        "soloRaidStateHeadRevisionUid = restoredSoloRaidState.HeadRevisionUid",
        derivedDatabaseWrite);

    Assert.True(profileMaterialization < soloRaidRestore);
    Assert.True(soloRaidRestore < derivedDatabaseWrite);
    Assert.True(derivedDatabaseWrite < materializationReceiptWrite);
  }

  [Fact]
  public void ProfileRevisionChangeClosesOpenChallengeWithoutRefundingAttempt()
  {
    var root = FindRepositoryRoot();
    var source = File.ReadAllText(Path.Combine(
        root,
        "tools",
        "NikkeLocalLab.PhaseD.RuntimeMaterializer",
        "ClassicSoloRaidRuntimeState.cs"));

    Assert.Contains("var removedOpenRuns = payload.Raid!.SoloRaidLevels.RemoveAll", source,
        StringComparison.Ordinal);
    Assert.Contains("removedOpenRuns == 1 && payload.Raid.TrialCount >= 0", source,
        StringComparison.Ordinal);
    Assert.DoesNotContain("payload.Raid.TrialCount--", source, StringComparison.Ordinal);
    Assert.Contains("openRunDiscardedForProfileRevisionMismatch = true;", source,
        StringComparison.Ordinal);
    Assert.DoesNotContain(
        "throw new InvalidOperationException(\n            \"phase_d_active_raid_profile_revision_mismatch\")",
        source,
        StringComparison.Ordinal);
  }

  [Fact]
  public void PhaseDCompletionCapturesSoloRaidStateOnlyAfterRuntimeStopAndBeforeDatabaseRestore()
  {
    var root = FindRepositoryRoot();
    var coordinator = NormalizeLineEndings(File.ReadAllText(Path.Combine(
        root,
        "scripts",
        "invoke-nll-phase-d-execution.ps1")));
    var completion = NormalizeLineEndings(File.ReadAllText(Path.Combine(
        root, "scripts", "Nll.PhaseDRunnerComplete.ps1")));
    var operations = File.ReadAllText(Path.Combine(root, "scripts", "Nll.PhaseDRunnerOperations.ps1"));
    var stopped = RequiredIndex(completion, "phase3b2_epinel_minimal_completion_runtime_stop_failed");
    var capture = RequiredIndex(completion,
        "Invoke-PhaseDRunnerCapture -Specification $Specification -SourceDatabasePath $dbPath", stopped);
    var restore = RequiredIndex(completion,
        "[IO.File]::WriteAllBytes($dbPath, [IO.File]::ReadAllBytes($dbBeforePath))", capture);
    Assert.True(stopped < capture && capture < restore);
    Assert.Equal(1, CountOccurrences(completion, "Invoke-PhaseDRunnerCapture -Specification"));
    Assert.Contains("--capture-solo-raid-state true", operations, StringComparison.Ordinal);
    Assert.Contains("--source-db $SourceDatabasePath", operations, StringComparison.Ordinal);
    Assert.DoesNotContain("$captureAnchor", coordinator + completion, StringComparison.Ordinal);
    Assert.Contains(
        "C:\\NLL\\ControlCenter\\state\\phase-d-solo-raid",
        coordinator,
        StringComparison.Ordinal);
    Assert.DoesNotContain(
        "Join-Path $launchRoot 'solo-raid-state.pending.bin'",
        coordinator,
        StringComparison.Ordinal);
  }

  [Fact]
  public void CompletionWatcherReplaysPendingBeforeCompletionAndDeletesItAfterTerminalState()
  {
    var root = FindRepositoryRoot();
    var watcher = NormalizeLineEndings(File.ReadAllText(Path.Combine(
        root,
        "scripts",
        "watch-nll-phase-d-execution.ps1")));

    var persistenceFunction = RequiredIndex(watcher, "function Invoke-SoloRaidPersistence {");
    var persistenceInvocation = RequiredIndex(
        watcher,
        "$persistence = Invoke-SoloRaidPersistence -LaunchContextUid $launchContextUid",
        persistenceFunction);
    var databaseRestart = watcher.LastIndexOf(
        "Ensure-PhaseDPostgresRunning",
        persistenceInvocation,
        StringComparison.Ordinal);
    var receiptValidation = RequiredIndex(
        watcher,
        "$receipt = Read-SoloRaidPersistenceReceipt",
        persistenceFunction);
    var pendingDeletion = RequiredIndex(
        watcher,
        "Remove-Item -LiteralPath $SoloRaidPendingPayloadPath -Force",
        receiptValidation);
    var pendingDeletionProof = RequiredIndex(
        watcher,
        "phase_d_raid_state_pending_delete_failed",
        pendingDeletion);
    var executionCompleted = RequiredIndex(
        watcher,
        "$state.statusCode = 'completed'",
        persistenceInvocation);
    var failurePath = RequiredIndex(watcher, "catch {", executionCompleted);

    Assert.True(databaseRestart >= 0 && databaseRestart < persistenceInvocation);
    Assert.True(receiptValidation < pendingDeletion);
    Assert.True(pendingDeletion < pendingDeletionProof);
    Assert.True(persistenceInvocation < executionCompleted);
    Assert.True(executionCompleted < pendingDeletion);
    Assert.Equal(
        1,
        CountOccurrences(
            watcher,
            "Remove-Item -LiteralPath $SoloRaidPendingPayloadPath -Force"));
    Assert.DoesNotContain(
        "Remove-Item -LiteralPath $SoloRaidPendingPayloadPath -Force",
        watcher[failurePath..],
        StringComparison.Ordinal);

    var persistenceFunctionEnd = RequiredIndex(
        watcher,
        "function Invoke-EmergencyRollback {",
        persistenceFunction);
    var persistenceBody = watcher[persistenceFunction..persistenceFunctionEnd];
    Assert.Contains(
        "Test-Path -LiteralPath $SoloRaidPendingPayloadPath -PathType Leaf",
        persistenceBody,
        StringComparison.Ordinal);
    Assert.Contains(
        "--persist-solo-raid-state true",
        persistenceBody,
        StringComparison.Ordinal);
    Assert.DoesNotContain(
        "if (-not (Test-Path -LiteralPath $SoloRaidPersistenceReceiptPath",
        persistenceBody,
        StringComparison.Ordinal);
    // Binding checks only: shared-state PowerShell behavior tests mutate the
    // actual validator's files/hashes/contexts, rather than trusting token presence.
    Assert.Contains("'Nll.PhaseDCompletion.ps1'", watcher, StringComparison.Ordinal);
    Assert.Contains("Read-PhaseDSoloRaidPersistenceReceipt -Path $Path -LaunchRoot $LaunchRoot -LaunchContextUid $LaunchContextUid",
        watcher, StringComparison.Ordinal);
    Assert.Contains("$orphanRecoveryRequired", watcher, StringComparison.Ordinal);
    Assert.Contains(
        "$pendingReplayRequired -or $orphanRecoveryRequired",
        watcher,
        StringComparison.Ordinal);
  }

  [Fact]
  public void OrphanRecoveryCapturesChangedRuntimeDatabaseBeforeRestoringDbBeforeImage()
  {
    var root = FindRepositoryRoot();
    var recovery = NormalizeLineEndings(File.ReadAllText(Path.Combine(
        root,
        "scripts",
        "recover-nll-phase-d-orphaned-execution.ps1")));

    Assert.Contains("--capture-solo-raid-state true", recovery, StringComparison.Ordinal);
    Assert.Contains(
        "C:\\NLL\\ControlCenter\\state\\phase-d-solo-raid",
        recovery,
        StringComparison.Ordinal);

    var dbBefore = RequiredIndex(recovery, "$dbBefore = Join-Path $runRoot 'db.before.bin'");
    var changedCheck = RequiredIndex(recovery, "$runtimeChanged =", dbBefore);
    var captureInvocation = RequiredIndex(
        recovery,
        "Invoke-SoloRaidCapture -SourceDatabasePath $runtimeDbPath",
        changedCheck);
    var databaseRestore = RequiredIndex(
        recovery,
        "[IO.File]::WriteAllBytes(",
        dbBefore);
    var preRestoreBlock = recovery[dbBefore..databaseRestore];
    Assert.True(
        preRestoreBlock.Contains("capture", StringComparison.OrdinalIgnoreCase),
        "Orphan recovery must invoke authenticated Solo Raid capture before restoring db.before.bin.");
    Assert.Contains("$SoloRaidPendingPayloadPath", preRestoreBlock, StringComparison.Ordinal);
    Assert.True(changedCheck < captureInvocation);
    Assert.True(captureInvocation < databaseRestore);
    Assert.Contains(
        "if ($runtimeChanged -and",
        preRestoreBlock,
        StringComparison.Ordinal);
    Assert.Contains(
        "@('draft','validated','started','failed')",
        recovery,
        StringComparison.Ordinal);
  }

  [Fact]
  public void CompletedSoloRaidCaptureRequiresAFullFiveTeamRun()
  {
    var root = FindRepositoryRoot();
    var materializerState = File.ReadAllText(Path.Combine(
        root,
        "tools",
        "NikkeLocalLab.PhaseD.RuntimeMaterializer",
        "ClassicSoloRaidRuntimeState.cs"));

    Assert.Contains(
        "level.RaidJoinCount == 5 && level.Logs.Count == 5",
        materializerState,
        StringComparison.Ordinal);
    Assert.Contains(
        "allowLegacyPartialCompletion",
        materializerState,
        StringComparison.Ordinal);
  }

  private static int RequiredIndex(string text, string value, int startIndex = 0)
  {
    var index = text.IndexOf(value, startIndex, StringComparison.Ordinal);
    Assert.True(index >= 0, $"Required artifact fragment was not found: {value}");
    return index;
  }

  private static int CountOccurrences(string text, string value)
  {
    var count = 0;
    var startIndex = 0;
    while ((startIndex = text.IndexOf(value, startIndex, StringComparison.Ordinal)) >= 0)
    {
      count++;
      startIndex += value.Length;
    }

    return count;
  }

  private static string NormalizeLineEndings(string value) =>
      value.Replace("\r\n", "\n", StringComparison.Ordinal);

  private static string FindRepositoryRoot()
  {
    var current = new DirectoryInfo(AppContext.BaseDirectory);
    while (current is not null && !File.Exists(Path.Combine(current.FullName, "NikkeLocalLab.sln")))
    {
      current = current.Parent;
    }

    return current?.FullName ?? throw new InvalidOperationException("repository_root_not_found");
  }
}
