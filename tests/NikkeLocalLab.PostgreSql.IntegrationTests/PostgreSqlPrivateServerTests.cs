using System.Reflection;
using App = NikkeLocalLab.Application.PrivateServer;
using ProfileApp = NikkeLocalLab.Application.ProfileManagement;
using PrivateServerDomain = global::NikkeLocalLab.Domain.PrivateServer;
using NikkeLocalLab.Application.Importing;
using NikkeLocalLab.Domain.Raid;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Persistence.PostgreSql;
using NikkeLocalLab.Provenance;
using Npgsql;

namespace NikkeLocalLab.PostgreSql.IntegrationTests;

public sealed class PostgreSqlPrivateServerTests
{
  private const string ResetToken = "allow-phase1a-disposable-schema-reset";
  private static readonly DateTimeOffset TestInstant =
      new(2026, 8, 20, 1, 0, 0, TimeSpan.Zero);

  [Fact]
  public async Task ColdBootstrapPublishesExactDirectoryAndFailClosedPolicy()
  {
    var connectionString = ConnectionString();
    await using (var dataSource = PostgreSqlDataSourceFactory.Create(connectionString))
    {
      await ResetSchemasAsync(dataSource);
      Assert.Equal(MigrationBaseline.Count, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));
      await PublishSixSeasonRaidCatalogAsync(dataSource);
    }

    var time = new ManualTimeProvider(TestInstant);
    App.PrivateServerBootProjection first;
    await using (var runtime = await PostgreSqlPrivateServerRuntime.CreateAsync(
        connectionString,
        time))
    {
      first = await runtime.Service.GetBootAsync(new App.BootQuery(TestInstant));
      Assert.Equal(
          new[] { 7, 13, 26, 29, 34, 40 },
          first.Directory.Directory.Members.Select(static item => item.SeasonNumber));
      Assert.All(first.Directory.Directory.Members, member =>
      {
        Assert.Equal(PrivateServerDomain.SeasonAvailability.Permanent, member.Availability);
        Assert.Null(member.SeasonEndsAtUtc);
      });
      Assert.False(first.FixedCapabilities.NormalStagesImplemented);
      Assert.Equal(7, first.FixedCapabilities.NormalLastClearLevel);
      Assert.True(first.FixedCapabilities.ChallengeUnlocked);
      Assert.Equal("unsupported", first.FixedCapabilities.NormalCombatCapabilityCode);
      Assert.Equal("unsupported", first.FixedCapabilities.QuickBattleCapabilityCode);
      Assert.False(first.OperationalPolicy.Policy.IsAdmissionReady);
      Assert.Equal(
          PrivateServerDomain.PrivateServerCapabilityStatus.Unresolved,
          first.CapabilityManifest.Manifest.Get("solo_raid.challenge_run").Status);
      Assert.Equal(
          PrivateServerDomain.PrivateServerCapabilityStatus.BlockedByGate,
          first.CapabilityManifest.Manifest.Get("original_client.wire_adapter").Status);
      Assert.Equal(
          PrivateServerDomain.PrivateServerCapabilityStatus.BlockedByGate,
          first.CapabilityManifest.Manifest.Get("original_client.presentation_adapter").Status);
    }

    await using (var replayRuntime = await PostgreSqlPrivateServerRuntime.CreateAsync(
        connectionString,
        time))
    {
      var replay = await replayRuntime.Service.GetBootAsync(new App.BootQuery(TestInstant));
      Assert.Equal(first.Revision, replay.Revision);
      Assert.Equal(first.Directory.Directory.DirectoryUid, replay.Directory.Directory.DirectoryUid);
      Assert.Equal(first.OperationalPolicy.Policy.PolicyUid, replay.OperationalPolicy.Policy.PolicyUid);
      Assert.Equal(first.CapabilityManifest.Manifest.ManifestUid,
          replay.CapabilityManifest.Manifest.ManifestUid);
    }

    await using var check = PostgreSqlDataSourceFactory.Create(connectionString);
    await using var connection = await check.OpenConnectionAsync();
    Assert.Equal(6L, await ScalarAsync(
        connection,
        "SELECT count(*) FROM lab_private_server.raid_season_directory_member;"));
    Assert.Equal(1L, await ScalarAsync(
        connection,
        "SELECT count(*) FROM lab_private_server.private_server_boot_revision;"));
    Assert.Equal(1L, await ScalarAsync(
        connection,
        "SELECT count(*) FROM lab_private_server.challenge_policy_activation_revision;"));
    await Assert.ThrowsAsync<PostgresException>(async () =>
    {
      await using var command = new NpgsqlCommand(
          "DELETE FROM lab_private_server.challenge_policy_state;",
          connection);
      _ = await command.ExecuteNonQueryAsync();
    });
  }

  [Fact]
  public async Task RaidDayKeyChangesAtExactlyFiveInAsiaSeoul()
  {
    await using var dataSource = CreateDataSource();
    await ResetSchemasAsync(dataSource);
    Assert.Equal(MigrationBaseline.Count, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));
    await using var connection = await dataSource.OpenConnectionAsync();

    Assert.Equal(
        new DateOnly(2026, 8, 19),
        await RaidDayAsync(connection, new DateTimeOffset(2026, 8, 19, 19, 59, 59, 999, TimeSpan.Zero)));
    Assert.Equal(
        new DateOnly(2026, 8, 20),
        await RaidDayAsync(connection, new DateTimeOffset(2026, 8, 19, 20, 0, 0, TimeSpan.Zero)));
  }

  [Fact]
  public async Task ConfiguredPolicyActivatesOnlyOnItsExplicitNextRaidDay()
  {
    var connectionString = ConnectionString();
    await using (var dataSource = PostgreSqlDataSourceFactory.Create(connectionString))
    {
      await ResetSchemasAsync(dataSource);
      Assert.Equal(MigrationBaseline.Count, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));
      await PublishSixSeasonRaidCatalogAsync(dataSource);
    }

    var nextInstant = TestInstant.AddDays(1);
    await using var runtime = await PostgreSqlPrivateServerRuntime.CreateAsync(
        connectionString,
        new ManualTimeProvider(TestInstant));
    var initial = await runtime.Service.GetChallengeOperationalPolicyAsync(
        new App.ChallengePolicyStateQuery(TestInstant));
    Assert.False(initial.Current.Policy.IsAdmissionReady);
    Assert.Null(initial.Scheduled);

    var configured = PrivateServerDomain.ChallengeOperationalPolicy.CreateConfiguredV1(
        EntityUid.New(),
        "challenge-operational-policy/integration/v1",
        dailyEntryLimit: 3,
        PrivateServerDomain.ChallengeEntryConsumptionPoint.RunClosed,
        PrivateServerDomain.ActiveRunAtResetPolicy.PinOpeningRaidDay,
        PrivateServerDomain.DailyCounterScope.PerSeason,
        PrivateServerDomain.MockBattleCapability.Unsupported,
        PrivateServerDomain.LocalRankingCapability.LocalRecordsOnly);
    var published = await runtime.Service.PublishChallengeOperationalPolicyAsync(
        new App.PublishChallengeOperationalPolicyCommand(
            EntityUid.New(),
            configured,
            TestInstant));
    Assert.False(published.IsActive);

    var activateCommand = new App.ActivateChallengeOperationalPolicyCommand(
        EntityUid.New(),
        configured.PolicyUid,
        configured.ContentSha256,
        PrivateServerDomain.AsiaSeoulRaidDay.GetKey(nextInstant),
        initial.Activation.Revision.RevisionUid,
        TestInstant);
    var scheduled = await runtime.Service.ActivateChallengeOperationalPolicyAsync(activateCommand);
    Assert.False(scheduled.Current.Policy.IsAdmissionReady);
    Assert.NotNull(scheduled.Scheduled);
    Assert.True(scheduled.Scheduled!.Policy.IsAdmissionReady);
    Assert.Equal(
        PrivateServerDomain.AsiaSeoulRaidDay.GetKey(nextInstant),
        scheduled.Scheduled.EffectiveRaidDayKey);

    var currentBoot = await runtime.Service.GetBootAsync(new App.BootQuery(TestInstant));
    Assert.False(currentBoot.OperationalPolicy.Policy.IsAdmissionReady);
    var nextBoot = await runtime.Service.GetBootAsync(new App.BootQuery(nextInstant));
    Assert.True(nextBoot.OperationalPolicy.Policy.IsAdmissionReady);
    Assert.Equal(configured.PolicyUid, nextBoot.OperationalPolicy.Policy.PolicyUid);
    Assert.Equal(
        PrivateServerDomain.PrivateServerCapabilityStatus.Supported,
        nextBoot.CapabilityManifest.Manifest.Get("solo_raid.challenge_run").Status);

    var replay = await runtime.Service.ActivateChallengeOperationalPolicyAsync(activateCommand);
    Assert.Equal(scheduled.Activation, replay.Activation);
    Assert.Equal(scheduled.Current.Policy.PolicyUid, replay.Current.Policy.PolicyUid);
    Assert.Equal(scheduled.Scheduled?.Policy.PolicyUid, replay.Scheduled?.Policy.PolicyUid);
  }

  [Fact]
  public async Task SessionConnectLobbyAndSelectionAreDurableAndExplicit()
  {
    var connectionString = ConnectionString();
    AccountFixture account;
    await using (var dataSource = PostgreSqlDataSourceFactory.Create(connectionString))
    {
      await ResetSchemasAsync(dataSource);
      Assert.Equal(MigrationBaseline.Count, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));
      await PublishSixSeasonRaidCatalogAsync(dataSource);
      account = await CreateInitializedAccountAsync(dataSource);
    }

    await using var runtime = await PostgreSqlPrivateServerRuntime.CreateAsync(
        connectionString,
        new ManualTimeProvider(TestInstant));
    var service = runtime.Service;
    var boot = await service.GetBootAsync(new App.BootQuery(TestInstant));
    var openOperationUid = EntityUid.New();
    var openCommand = new App.OpenLocalSessionCommand(
        openOperationUid,
        account.AccountUid,
        boot.Revision.RevisionUid,
        boot.Revision.ContentSha256,
        TestInstant,
        TestInstant.AddMinutes(30));
    var loading = await service.OpenSessionAsync(openCommand);
    Assert.Equal("loading", loading.StageCode);
    Assert.Null(loading.SelectedSeasonRevisionUid);

    var delayedReplay = await service.OpenSessionAsync(openCommand with
    {
      IssuedAtUtc = TestInstant.AddSeconds(10),
      ExpiresAtUtc = TestInstant.AddMinutes(30).AddSeconds(10)
    });
    Assert.Equal(loading, delayedReplay);
    await service.ValidateSessionAccessAsync(
        new App.ValidateLocalSessionAccessQuery(loading.SessionUid, TestInstant.AddMinutes(1)));

    var directory = await service.GetSeasonDirectoryAsync(new App.SeasonDirectoryQuery(
        loading.SessionUid,
        loading.ClientContextUid,
        loading.Revision.RevisionUid,
        TestInstant.AddSeconds(1)));
    var season40 = directory.Directory.RequireMember(40);
    var connected = await service.ConnectSessionAsync(new App.ConnectLocalSessionCommand(
        EntityUid.New(),
        Pin(loading, TestInstant.AddSeconds(2)),
        directory.Directory.DirectoryUid,
        directory.Directory.ContentSha256,
        season40.RaidSnapshotUid));
    Assert.Equal("local_connected", connected.StageCode);
    Assert.NotNull(connected.SelectedSeasonRevisionUid);

    var lobbyOperationUid = EntityUid.New();
    var lobbyCommand = new App.EnterLobbyCommand(
        lobbyOperationUid,
        Pin(connected, TestInstant.AddSeconds(3)));
    var lobby = await service.EnterLobbyAsync(lobbyCommand);
    Assert.Equal("lobby_ready", lobby.Context.StageCode);
    Assert.Equal(account.AccountUid, lobby.Account.AccountUid);
    Assert.Equal(account.ProfileRevisionUid, lobby.Account.Profile.ProfileRevision.RevisionUid);
    Assert.Equal(40, lobby.Selection.Selection.Member.SeasonNumber);

    await using (var stateDataSource = PostgreSqlDataSourceFactory.Create(connectionString))
    {
      var profileManagement = new PostgreSqlProfileManagementService(
          stateDataSource,
          new RandomEntityUidGenerator(),
          new ManualTimeProvider(TestInstant.AddSeconds(4)));
      _ = await profileManagement.SaveWalletAsync(new ProfileApp.SaveWalletCommand(
          EntityUid.New(),
          account.AccountUid,
          lobby.Account.Wallet.Revision.RevisionUid,
          lobby.Account.Wallet.Balances.Select(static balance => balance with
          {
            Balance = balance.CurrencyCode == "jewel" ? balance.Balance + 1 : balance.Balance
          }).ToArray()));
    }

    var lobbyReplay = await service.EnterLobbyAsync(lobbyCommand with
    {
      RequestPin = Pin(connected, TestInstant.AddSeconds(5))
    });
    Assert.Equal(lobby.Context.Revision, lobbyReplay.Context.Revision);
    Assert.Equal(lobby.Account.RevisionSetSha256, lobbyReplay.Account.RevisionSetSha256);
    Assert.Equal(lobby.Account.Wallet.Revision, lobbyReplay.Account.Wallet.Revision);
    Assert.Equal(lobby.Account.Wallet.Balances, lobbyReplay.Account.Wallet.Balances);

    var solo = await service.GetSoloRaidStateAsync(new App.SoloRaidStateQuery(
        lobby.Context.SessionUid,
        lobby.Context.ClientContextUid,
        lobby.Context.Revision.RevisionUid,
        TestInstant.AddSeconds(6)));
    Assert.Equal(account.ProfileRevisionUid, solo.AdmissionPins.ProfileRevisionUid);
    Assert.Null(solo.AdmissionPins.RuntimeExecution);
    Assert.Null(solo.AdmissionPins.CombatControl);
    Assert.Null(solo.DailyState);
    Assert.Null(solo.ActiveRun);

    var season7 = directory.Directory.RequireMember(7);
    var selected = await service.SelectSeasonAsync(new App.SelectRaidSeasonCommand(
        EntityUid.New(),
        Pin(solo.Context, TestInstant.AddSeconds(7)),
        solo.Selection.Selection.SelectionRevisionUid,
        directory.Directory.DirectoryUid,
        directory.Directory.ContentSha256,
        season7.RaidSnapshotUid));
    Assert.Equal(7, selected.Selection.Member.SeasonNumber);
    Assert.Equal("lobby_ready", selected.Context.StageCode);
    Assert.NotEqual(
        solo.Selection.Selection.SelectionRevisionUid,
        selected.Selection.SelectionRevisionUid);

    var reloaded = await service.GetSoloRaidStateAsync(new App.SoloRaidStateQuery(
        selected.Context.SessionUid,
        selected.Context.ClientContextUid,
        selected.Context.Revision.RevisionUid,
        TestInstant.AddSeconds(8)));
    Assert.Equal(7, reloaded.Selection.Selection.Member.SeasonNumber);
    Assert.Equal(selected.Selection.ContentSha256, reloaded.Selection.Selection.ContentSha256);
  }

  [Fact]
  public async Task ExecutionProfilesRoundTripReplayCasAndAppearInAdmissionPins()
  {
    var connectionString = ConnectionString();
    AccountFixture account;
    await using (var dataSource = PostgreSqlDataSourceFactory.Create(connectionString))
    {
      await ResetSchemasAsync(dataSource);
      Assert.Equal(MigrationBaseline.Count, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));
      await PublishSixSeasonRaidCatalogAsync(dataSource);
      account = await CreateInitializedAccountAsync(dataSource);
    }

    await using var runtime = await PostgreSqlPrivateServerRuntime.CreateAsync(
        connectionString,
        new ManualTimeProvider(TestInstant));
    var service = runtime.Service;
    var runtimeProfileUid = EntityUid.New();
    var runtimeOperationUid = EntityUid.New();
    var runtimeContent = ReadyRuntimeContent();
    var runtimeCommand = new App.SaveRuntimeExecutionProfileCommand(
        runtimeOperationUid,
        account.AccountUid,
        runtimeProfileUid,
        null,
        runtimeContent,
        TestInstant);
    var runtimeProfile = await service.SaveRuntimeExecutionProfileAsync(runtimeCommand);
    Assert.Equal(1, runtimeProfile.Revision.RevisionNumber);
    Assert.True(runtimeProfile.Revision.Content.IsHarnessValidationReady);
    Assert.False(runtimeProfile.Revision.Content.IsOriginalClientLaunchReady);
    Assert.Equal(runtimeContent.ContentSha256, runtimeProfile.Revision.ContentSha256);

    var delayedRuntimeReplay = await service.SaveRuntimeExecutionProfileAsync(
        runtimeCommand with { MaterializedAtUtc = TestInstant.AddSeconds(30) });
    Assert.Equal(runtimeProfile.Revision.RevisionUid, delayedRuntimeReplay.Revision.RevisionUid);
    Assert.Equal(runtimeProfile.Revision.ContentSha256, delayedRuntimeReplay.Revision.ContentSha256);
    Assert.Equal(runtimeProfile.Revision.MaterializedAtUtc, delayedRuntimeReplay.Revision.MaterializedAtUtc);
    var noOpRuntime = await service.SaveRuntimeExecutionProfileAsync(
        runtimeCommand with
        {
          OperationUid = EntityUid.New(),
          ExpectedCurrentRevisionUid = runtimeProfile.Revision.RevisionUid,
          MaterializedAtUtc = TestInstant.AddMinutes(1)
        });
    Assert.Equal(runtimeProfile.Revision.RevisionUid, noOpRuntime.Revision.RevisionUid);
    Assert.Equal(runtimeProfile.Revision.ContentSha256, noOpRuntime.Revision.ContentSha256);

    var runtimeConflict = await Assert.ThrowsAsync<App.PrivateServerApplicationException>(() =>
        service.SaveRuntimeExecutionProfileAsync(runtimeCommand with
        {
          OperationUid = EntityUid.New(),
          ProfileUid = EntityUid.New(),
          MaterializedAtUtc = TestInstant.AddMinutes(2)
        }));
    Assert.Equal(App.PrivateServerFailureKind.Conflict, runtimeConflict.Kind);
    Assert.Equal("runtime_execution_profile_revision_conflict", runtimeConflict.Code);

    var invalidOriginalBinding = new PrivateServerDomain.RuntimeExecutionProfileContent(
        PrivateServerDomain.OriginalClientRuntimeBuildBinding.Ready(
            EntityUid.New(),
            Sha256Digest.ComputeUtf8("missing-original-runtime-build")),
        runtimeContent.Requested,
        null);
    var missingBuild = await Assert.ThrowsAsync<App.PrivateServerApplicationException>(() =>
        service.SaveRuntimeExecutionProfileAsync(new App.SaveRuntimeExecutionProfileCommand(
            EntityUid.New(),
            account.AccountUid,
            runtimeProfileUid,
            runtimeProfile.Revision.RevisionUid,
            invalidOriginalBinding,
            TestInstant.AddMinutes(3))));
    Assert.Equal(App.PrivateServerFailureKind.InvalidRequest, missingBuild.Kind);
    Assert.Equal("original_client_runtime_build_not_found", missingBuild.Code);

    var effectiveRuntimeContent = new PrivateServerDomain.RuntimeExecutionProfileContent(
        PrivateServerDomain.OriginalClientRuntimeBuildBinding.Unresolved(),
        runtimeContent.Requested,
        runtimeContent.Requested);
    var effectiveOperation = new App.SaveRuntimeExecutionProfileCommand(
        EntityUid.New(),
        account.AccountUid,
        runtimeProfileUid,
        runtimeProfile.Revision.RevisionUid,
        effectiveRuntimeContent,
        TestInstant.AddMinutes(4));
    var currentRuntimeProfile = await service.SaveRuntimeExecutionProfileAsync(effectiveOperation);
    Assert.Equal(2, currentRuntimeProfile.Revision.RevisionNumber);
    Assert.NotNull(currentRuntimeProfile.Revision.Content.Effective);
    var effectiveReplay = await service.SaveRuntimeExecutionProfileAsync(
        effectiveOperation with { MaterializedAtUtc = TestInstant.AddMinutes(5) });
    Assert.Equal(currentRuntimeProfile.Revision.RevisionUid, effectiveReplay.Revision.RevisionUid);
    Assert.Equal(currentRuntimeProfile.Revision.ContentSha256, effectiveReplay.Revision.ContentSha256);
    Assert.NotNull(effectiveReplay.Revision.Content.Effective);

    var controlProfileUid = EntityUid.New();
    var controlOperationUid = EntityUid.New();
    var controlContent = ReadyControlContent();
    var controlCommand = new App.SaveCombatControlProfileCommand(
        controlOperationUid,
        account.AccountUid,
        controlProfileUid,
        null,
        controlContent,
        TestInstant);
    var controlProfile = await service.SaveCombatControlProfileAsync(controlCommand);
    Assert.Equal(1, controlProfile.Revision.RevisionNumber);
    Assert.True(controlProfile.Revision.Content.IsManualBattleReady);
    Assert.Equal(controlContent.ContentSha256, controlProfile.Revision.ContentSha256);
    var delayedControlReplay = await service.SaveCombatControlProfileAsync(
        controlCommand with { MaterializedAtUtc = TestInstant.AddSeconds(30) });
    Assert.Equal(controlProfile.Revision.RevisionUid, delayedControlReplay.Revision.RevisionUid);
    Assert.Equal(controlProfile.Revision.ContentSha256, delayedControlReplay.Revision.ContentSha256);
    Assert.Equal(controlProfile.Revision.MaterializedAtUtc, delayedControlReplay.Revision.MaterializedAtUtc);

    await using (var factsDataSource = PostgreSqlDataSourceFactory.Create(connectionString))
    await using (var factsConnection = await factsDataSource.OpenConnectionAsync())
    {
      Assert.Equal(21L, await ScalarForUidAsync(
          factsConnection,
          """
          SELECT count(*)
          FROM lab_private_server.runtime_execution_profile_fact fact
          JOIN lab_private_server.runtime_execution_profile_revision revision
            ON revision.runtime_execution_profile_revision_id =
               fact.runtime_execution_profile_revision_id
          WHERE revision.runtime_execution_profile_revision_uid = @uid;
          """,
          currentRuntimeProfile.Revision.RevisionUid));
      Assert.Equal(7L, await ScalarForUidAsync(
          factsConnection,
          """
          SELECT count(*)
          FROM lab_private_server.combat_control_profile_fact fact
          JOIN lab_private_server.combat_control_profile_revision revision
            ON revision.combat_control_profile_revision_id =
               fact.combat_control_profile_revision_id
          WHERE revision.combat_control_profile_revision_uid = @uid;
          """,
          controlProfile.Revision.RevisionUid));
    }

    var boot = await service.GetBootAsync(new App.BootQuery(TestInstant));
    var loading = await service.OpenSessionAsync(new App.OpenLocalSessionCommand(
        EntityUid.New(),
        account.AccountUid,
        boot.Revision.RevisionUid,
        boot.Revision.ContentSha256,
        TestInstant,
        TestInstant.AddMinutes(30)));
    var directory = await service.GetSeasonDirectoryAsync(new App.SeasonDirectoryQuery(
        loading.SessionUid,
        loading.ClientContextUid,
        loading.Revision.RevisionUid,
        TestInstant.AddSeconds(1)));
    var season = directory.Directory.RequireMember(40);
    var connected = await service.ConnectSessionAsync(new App.ConnectLocalSessionCommand(
        EntityUid.New(),
        Pin(loading, TestInstant.AddSeconds(2)),
        directory.Directory.DirectoryUid,
        directory.Directory.ContentSha256,
        season.RaidSnapshotUid));
    var lobby = await service.EnterLobbyAsync(new App.EnterLobbyCommand(
        EntityUid.New(),
        Pin(connected, TestInstant.AddSeconds(3))));
    var solo = await service.GetSoloRaidStateAsync(new App.SoloRaidStateQuery(
        lobby.Context.SessionUid,
        lobby.Context.ClientContextUid,
        lobby.Context.Revision.RevisionUid,
        TestInstant.AddSeconds(4)));

    Assert.NotNull(solo.AdmissionPins.RuntimeExecution);
    Assert.Equal(
        currentRuntimeProfile.Revision.RevisionUid,
        solo.AdmissionPins.RuntimeExecution!.RevisionUid);
    Assert.Equal(
        currentRuntimeProfile.Revision.ContentSha256,
        solo.AdmissionPins.RuntimeExecution.ContentSha256);
    Assert.True(solo.AdmissionPins.RuntimeExecution.IsHarnessValidationReady);
    Assert.NotNull(solo.AdmissionPins.CombatControl);
    Assert.Equal(
        controlProfile.Revision.RevisionUid,
        solo.AdmissionPins.CombatControl!.RevisionUid);
    Assert.Equal(
        controlProfile.Revision.ContentSha256,
        solo.AdmissionPins.CombatControl.ContentSha256);
    Assert.True(solo.AdmissionPins.CombatControl.IsManualBattleReady);
  }

  [Fact]
  public async Task ExecutionProfileReplayRejectsFactAndPayloadCorruption()
  {
    var connectionString = ConnectionString();
    AccountFixture account;
    await using (var dataSource = PostgreSqlDataSourceFactory.Create(connectionString))
    {
      await ResetSchemasAsync(dataSource);
      Assert.Equal(MigrationBaseline.Count, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));
      await PublishSixSeasonRaidCatalogAsync(dataSource);
      account = await CreateInitializedAccountAsync(dataSource);
    }

    await using var runtime = await PostgreSqlPrivateServerRuntime.CreateAsync(
        connectionString,
        new ManualTimeProvider(TestInstant));
    var runtimeCommand = new App.SaveRuntimeExecutionProfileCommand(
        EntityUid.New(),
        account.AccountUid,
        EntityUid.New(),
        null,
        ReadyRuntimeContent(),
        TestInstant);
    var runtimeProfile = await runtime.Service.SaveRuntimeExecutionProfileAsync(runtimeCommand);
    var controlCommand = new App.SaveCombatControlProfileCommand(
        EntityUid.New(),
        account.AccountUid,
        EntityUid.New(),
        null,
        ReadyControlContent(),
        TestInstant);
    var controlProfile = await runtime.Service.SaveCombatControlProfileAsync(controlCommand);

    await using (var corruptionDataSource = PostgreSqlDataSourceFactory.Create(connectionString))
    await using (var connection = await corruptionDataSource.OpenConnectionAsync())
    await using (var command = new NpgsqlCommand(
        """
        ALTER TABLE lab_private_server.runtime_execution_profile_fact
            DISABLE TRIGGER trg_reject_immutable_mutation;
        UPDATE lab_private_server.runtime_execution_profile_fact fact
           SET requested_value = '030'
          FROM lab_private_server.runtime_execution_profile_revision revision
         WHERE revision.runtime_execution_profile_revision_id =
               fact.runtime_execution_profile_revision_id
           AND revision.runtime_execution_profile_revision_uid = @runtime_revision_uid
           AND fact.field_code = 'target_fps';
        ALTER TABLE lab_private_server.runtime_execution_profile_fact
            ENABLE TRIGGER trg_reject_immutable_mutation;

        ALTER TABLE lab_private_server.combat_control_profile_revision
            DISABLE TRIGGER trg_reject_immutable_mutation;
        UPDATE lab_private_server.combat_control_profile_revision
           SET requested_payload =
               requested_payload || '{"Unexpected":"value"}'::jsonb
         WHERE combat_control_profile_revision_uid = @control_revision_uid;
        ALTER TABLE lab_private_server.combat_control_profile_revision
            ENABLE TRIGGER trg_reject_immutable_mutation;
        """,
        connection))
    {
      command.Parameters.AddWithValue(
          "runtime_revision_uid",
          runtimeProfile.Revision.RevisionUid.Value);
      command.Parameters.AddWithValue(
          "control_revision_uid",
          controlProfile.Revision.RevisionUid.Value);
      Assert.Equal(2, await command.ExecuteNonQueryAsync());
    }

    var runtimeFailure = await Assert.ThrowsAsync<App.PrivateServerApplicationException>(() =>
        runtime.Service.SaveRuntimeExecutionProfileAsync(runtimeCommand));
    Assert.Equal(App.PrivateServerFailureKind.Unavailable, runtimeFailure.Kind);
    Assert.Equal("private_server_profile_integrity_failed", runtimeFailure.Code);

    var controlFailure = await Assert.ThrowsAsync<App.PrivateServerApplicationException>(() =>
        runtime.Service.SaveCombatControlProfileAsync(controlCommand));
    Assert.Equal(App.PrivateServerFailureKind.Unavailable, controlFailure.Kind);
    Assert.Equal("combat_control_profile_payload_mismatch", controlFailure.Code);
  }

  [Fact]
  public async Task ChallengeRunPersistsHarnessReceiptAndConsumesOnClose()
  {
    var connectionString = ConnectionString();
    AccountFixture account;
    await using (var dataSource = PostgreSqlDataSourceFactory.Create(connectionString))
    {
      await ResetSchemasAsync(dataSource);
      Assert.Equal(MigrationBaseline.Count, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));
      await PublishSixSeasonRaidCatalogAsync(dataSource);
      account = await CreateInitializedAccountAsync(dataSource);
    }

    var policy = PrivateServerDomain.ChallengeOperationalPolicy.CreateConfiguredV1(
        EntityUid.New(),
        "challenge-operational-policy/run-integration/v1",
        dailyEntryLimit: 3,
        PrivateServerDomain.ChallengeEntryConsumptionPoint.RunClosed,
        PrivateServerDomain.ActiveRunAtResetPolicy.PinOpeningRaidDay,
        PrivateServerDomain.DailyCounterScope.PerSeason,
        PrivateServerDomain.MockBattleCapability.Unsupported,
        PrivateServerDomain.LocalRankingCapability.LocalRecordsOnly);
    await using var runtime = await PostgreSqlPrivateServerRuntime.CreateAsync(
        connectionString,
        policy,
        new ManualTimeProvider(TestInstant));
    var service = runtime.Service;
    var runtimeProfile = await service.SaveRuntimeExecutionProfileAsync(
        new App.SaveRuntimeExecutionProfileCommand(
            EntityUid.New(),
            account.AccountUid,
            EntityUid.New(),
            null,
            ReadyRuntimeContent(),
            TestInstant));
    var controlProfile = await service.SaveCombatControlProfileAsync(
        new App.SaveCombatControlProfileCommand(
            EntityUid.New(),
            account.AccountUid,
            EntityUid.New(),
            null,
            ReadyControlContent(),
            TestInstant));

    var boot = await service.GetBootAsync(new App.BootQuery(TestInstant));
    Assert.True(boot.OperationalPolicy.Policy.IsAdmissionReady);
    var loading = await service.OpenSessionAsync(new App.OpenLocalSessionCommand(
        EntityUid.New(),
        account.AccountUid,
        boot.Revision.RevisionUid,
        boot.Revision.ContentSha256,
        TestInstant,
        TestInstant.AddMinutes(30)));
    var directory = await service.GetSeasonDirectoryAsync(new App.SeasonDirectoryQuery(
        loading.SessionUid,
        loading.ClientContextUid,
        loading.Revision.RevisionUid,
        TestInstant.AddSeconds(1)));
    var member = directory.Directory.RequireMember(40);
    var connected = await service.ConnectSessionAsync(new App.ConnectLocalSessionCommand(
        EntityUid.New(),
        Pin(loading, TestInstant.AddSeconds(2)),
        directory.Directory.DirectoryUid,
        directory.Directory.ContentSha256,
        member.RaidSnapshotUid));
    var lobby = await service.EnterLobbyAsync(new App.EnterLobbyCommand(
        EntityUid.New(),
        Pin(connected, TestInstant.AddSeconds(3))));
    Assert.NotNull(lobby.Account.Squad);
    var solo = await service.GetSoloRaidStateAsync(new App.SoloRaidStateQuery(
        lobby.Context.SessionUid,
        lobby.Context.ClientContextUid,
        lobby.Context.Revision.RevisionUid,
        TestInstant.AddSeconds(4)));
    Assert.NotNull(solo.AdmissionPins.RuntimeExecution);
    Assert.NotNull(solo.AdmissionPins.CombatControl);

    var opened = await service.OpenChallengeRunAsync(new App.OpenChallengeRunCommand(
        EntityUid.New(),
        Pin(solo.Context, TestInstant.AddSeconds(5)),
        solo.Selection.Selection.SelectionRevisionUid,
        solo.AdmissionPins.ProfileRevisionUid,
        solo.AdmissionPins.AccountCombatStateRevisionUid,
        runtimeProfile.Revision.RevisionUid,
        controlProfile.Revision.RevisionUid,
        [lobby.Account.Squad!.SquadRevisionUid],
        false));
    Assert.Equal(PrivateServerDomain.ChallengeRunState.Open, opened.Run.State);
    Assert.Equal(PrivateServerDomain.LabHarnessTeamResultReceipt.ObservationContractId,
        opened.Run.Binding.ExecutionSourceCode);

    var enterOperationUid = EntityUid.New();
    var enterCommand = new App.EnterChallengeTeamCommand(
        enterOperationUid,
        Pin(solo.Context, TestInstant.AddSeconds(6)),
        opened.Run.RunUid,
        opened.Run.RunRevisionUid,
        1);
    var entered = await service.EnterChallengeTeamAsync(enterCommand);
    Assert.Equal(PrivateServerDomain.ChallengeRunState.TeamInProgress, entered.Run.State);
    var delayedEnterReplay = await service.EnterChallengeTeamAsync(enterCommand with
    {
      RequestPin = Pin(solo.Context, TestInstant.AddSeconds(20))
    });
    Assert.Equal(entered.Run.RunRevisionUid, delayedEnterReplay.Run.RunRevisionUid);
    Assert.Equal(entered.Run.ContentSha256, delayedEnterReplay.Run.ContentSha256);

    var observedDamage = PrivateServerDomain.NonNegativeIntegerDamage.Parse(
        "999999999999999999");
    var telemetry = new PrivateServerDomain.BattleFrameTelemetry(
        60,
        60,
        60,
        1_000_000,
        16m,
        17m,
        18m,
        0,
        0);
    var segment = new PrivateServerDomain.ExecutionSegment(
        1,
        runtimeProfile.Revision.RevisionUid,
        controlProfile.Revision.RevisionUid,
        0,
        60,
        0,
        60,
        0,
        60,
        0,
        1_000_000,
        PrivateServerDomain.NonNegativeIntegerDamage.Zero,
        observedDamage);
    var submitOperationUid = EntityUid.New();
    var submitCommand = new App.SubmitChallengeTeamResultCommand(
            submitOperationUid,
            Pin(solo.Context, TestInstant.AddSeconds(7)),
            entered.Run.RunUid,
            entered.Run.RunRevisionUid,
            1,
            observedDamage,
            telemetry,
            [segment],
            ["zeta_warning", "alpha_warning"]);
    var accepted = await service.SubmitChallengeTeamResultAsync(submitCommand);
    Assert.Equal(PrivateServerDomain.ChallengeRunState.TeamResultAccepted, accepted.Run.State);
    var receipt = Assert.Single(accepted.Run.Attempts).ResultReceipt;
    Assert.NotNull(receipt);
    Assert.Equal(
        PrivateServerDomain.LabHarnessTeamResultReceipt.ObservationContractId,
        receipt!.ObservationSourceCode);
    Assert.False(receipt.IsOriginalClientRuntimeObservation);
    Assert.Equal(observedDamage, receipt.ObservedDamage);
    Assert.Equal(new[] { "alpha_warning", "zeta_warning" }, receipt.WarningCodes);
    var acceptedReplay = await service.SubmitChallengeTeamResultAsync(submitCommand with
    {
      RequestPin = Pin(solo.Context, TestInstant.AddSeconds(20)),
      WarningCodes = ["alpha_warning", "zeta_warning", "alpha_warning"]
    });
    Assert.Equal(accepted.Run.RunRevisionUid, acceptedReplay.Run.RunRevisionUid);
    Assert.Equal(accepted.Run.ContentSha256, acceptedReplay.Run.ContentSha256);
    Assert.Equal(observedDamage, acceptedReplay.Run.CumulativeDamage);

    var completed = await service.CloseChallengeRunAsync(new App.CloseChallengeRunCommand(
        EntityUid.New(),
        Pin(solo.Context, TestInstant.AddSeconds(8)),
        accepted.Run.RunUid,
        accepted.Run.RunRevisionUid,
        EntityUid.New()));
    Assert.Equal(PrivateServerDomain.ChallengeRunState.Completed, completed.Run.State);
    Assert.Equal(observedDamage, completed.Run.CumulativeDamage);
    Assert.NotNull(completed.Run.FinalResultUid);

    var reloadedCompleted = await service.GetChallengeRunAsync(new App.GetChallengeRunQuery(
        solo.Context.SessionUid,
        solo.Context.ClientContextUid,
        solo.Context.Revision.RevisionUid,
        completed.Run.RunUid,
        TestInstant.AddSeconds(9)));
    Assert.NotNull(reloadedCompleted);
    Assert.Equal(completed.Run.RunRevisionUid, reloadedCompleted!.Run.RunRevisionUid);
    Assert.Equal(completed.Run.ContentSha256, reloadedCompleted.Run.ContentSha256);
    Assert.Equal(observedDamage, reloadedCompleted.Run.CumulativeDamage);

    var refreshed = await service.GetSoloRaidStateAsync(new App.SoloRaidStateQuery(
        solo.Context.SessionUid,
        solo.Context.ClientContextUid,
        solo.Context.Revision.RevisionUid,
        TestInstant.AddSeconds(10)));
    Assert.Null(refreshed.ActiveRun);
    Assert.NotNull(refreshed.DailyState);
    Assert.Equal(1, refreshed.DailyState!.ConsumedEntries);
    Assert.Equal(3, refreshed.DailyState.DailyEntryLimit);
  }

  [Fact]
  public async Task ExpiredOwnerRunRequiresSameAccountRecoveryAndReleasesTheActiveSlot()
  {
    var connectionString = ConnectionString();
    AccountFixture account;
    await using (var dataSource = PostgreSqlDataSourceFactory.Create(connectionString))
    {
      await ResetSchemasAsync(dataSource);
      Assert.Equal(MigrationBaseline.Count, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));
      await PublishSixSeasonRaidCatalogAsync(dataSource);
      account = await CreateInitializedAccountAsync(dataSource);
    }

    var policy = PrivateServerDomain.ChallengeOperationalPolicy.CreateConfiguredV1(
        EntityUid.New(),
        "challenge-operational-policy/recovery-integration/v1",
        dailyEntryLimit: 3,
        PrivateServerDomain.ChallengeEntryConsumptionPoint.RunClosed,
        PrivateServerDomain.ActiveRunAtResetPolicy.PinOpeningRaidDay,
        PrivateServerDomain.DailyCounterScope.PerSeason,
        PrivateServerDomain.MockBattleCapability.Unsupported,
        PrivateServerDomain.LocalRankingCapability.LocalRecordsOnly);
    await using var runtime = await PostgreSqlPrivateServerRuntime.CreateAsync(
        connectionString,
        policy,
        new ManualTimeProvider(TestInstant));
    var service = runtime.Service;
    var runtimeProfile = await service.SaveRuntimeExecutionProfileAsync(
        new App.SaveRuntimeExecutionProfileCommand(
            EntityUid.New(),
            account.AccountUid,
            EntityUid.New(),
            null,
            ReadyRuntimeContent(),
            TestInstant));
    var controlProfile = await service.SaveCombatControlProfileAsync(
        new App.SaveCombatControlProfileCommand(
            EntityUid.New(),
            account.AccountUid,
            EntityUid.New(),
            null,
            ReadyControlContent(),
            TestInstant));
    var boot = await service.GetBootAsync(new App.BootQuery(TestInstant));

    var ownerLoading = await service.OpenSessionAsync(new App.OpenLocalSessionCommand(
        EntityUid.New(),
        account.AccountUid,
        boot.Revision.RevisionUid,
        boot.Revision.ContentSha256,
        TestInstant,
        TestInstant.AddMinutes(10)));
    var directory = await service.GetSeasonDirectoryAsync(new App.SeasonDirectoryQuery(
        ownerLoading.SessionUid,
        ownerLoading.ClientContextUid,
        ownerLoading.Revision.RevisionUid,
        TestInstant.AddSeconds(1)));
    var member = directory.Directory.RequireMember(40);
    var ownerConnected = await service.ConnectSessionAsync(
        new App.ConnectLocalSessionCommand(
            EntityUid.New(),
            Pin(ownerLoading, TestInstant.AddSeconds(2)),
            directory.Directory.DirectoryUid,
            directory.Directory.ContentSha256,
            member.RaidSnapshotUid));
    var ownerLobby = await service.EnterLobbyAsync(new App.EnterLobbyCommand(
        EntityUid.New(),
        Pin(ownerConnected, TestInstant.AddSeconds(3))));
    var ownerSolo = await service.GetSoloRaidStateAsync(new App.SoloRaidStateQuery(
        ownerLobby.Context.SessionUid,
        ownerLobby.Context.ClientContextUid,
        ownerLobby.Context.Revision.RevisionUid,
        TestInstant.AddSeconds(4)));
    var opened = await service.OpenChallengeRunAsync(new App.OpenChallengeRunCommand(
        EntityUid.New(),
        Pin(ownerSolo.Context, TestInstant.AddSeconds(5)),
        ownerSolo.Selection.Selection.SelectionRevisionUid,
        ownerSolo.AdmissionPins.ProfileRevisionUid,
        ownerSolo.AdmissionPins.AccountCombatStateRevisionUid,
        runtimeProfile.Revision.RevisionUid,
        controlProfile.Revision.RevisionUid,
        [ownerLobby.Account.Squad!.SquadRevisionUid],
        false));
    var entered = await service.EnterChallengeTeamAsync(new App.EnterChallengeTeamCommand(
        EntityUid.New(),
        Pin(ownerSolo.Context, TestInstant.AddSeconds(6)),
        opened.Run.RunUid,
        opened.Run.RunRevisionUid,
        1));

    var requesterLoading = await service.OpenSessionAsync(new App.OpenLocalSessionCommand(
        EntityUid.New(),
        account.AccountUid,
        boot.Revision.RevisionUid,
        boot.Revision.ContentSha256,
        TestInstant.AddMinutes(7),
        TestInstant.AddHours(1)));
    var requesterConnected = await service.ConnectSessionAsync(
        new App.ConnectLocalSessionCommand(
            EntityUid.New(),
            Pin(requesterLoading, TestInstant.AddMinutes(7).AddSeconds(1)),
            directory.Directory.DirectoryUid,
            directory.Directory.ContentSha256,
            member.RaidSnapshotUid));
    var requesterLobby = await service.EnterLobbyAsync(new App.EnterLobbyCommand(
        EntityUid.New(),
        Pin(requesterConnected, TestInstant.AddMinutes(7).AddSeconds(2))));

    var activeOwnerFailure = await Assert.ThrowsAsync<App.PrivateServerApplicationException>(() =>
        service.RecoverStrandedChallengeRunAsync(
            new App.RecoverStrandedChallengeRunCommand(
                EntityUid.New(),
                Pin(requesterLobby.Context, TestInstant.AddMinutes(8)),
                entered.Run.RunUid,
                entered.Run.RunRevisionUid)));
    Assert.Equal(App.PrivateServerFailureKind.Forbidden, activeOwnerFailure.Kind);
    Assert.Equal("challenge_run_owning_session_still_active", activeOwnerFailure.Code);

    var recoveryOperationUid = EntityUid.New();
    var recovered = await service.RecoverStrandedChallengeRunAsync(
        new App.RecoverStrandedChallengeRunCommand(
            recoveryOperationUid,
            Pin(requesterLobby.Context, TestInstant.AddMinutes(11)),
            entered.Run.RunUid,
            entered.Run.RunRevisionUid));
    Assert.Equal(requesterLobby.Context.Revision, recovered.RequestingContext.Revision);
    Assert.Equal(PrivateServerDomain.ChallengeRunState.Abandoned, recovered.Run.Run.State);
    Assert.Equal(
        PrivateServerDomain.ChallengeRun.OwningSessionInactiveRecoveryReasonCode,
        recovered.Run.Run.AbandonReasonCode);
    Assert.NotNull(recovered.Run.Run.AbandonmentUid);

    var recoveredReplay = await service.RecoverStrandedChallengeRunAsync(
        new App.RecoverStrandedChallengeRunCommand(
            // Recovery replay stays bound to the sealed requesting context and run revision.
            recoveryOperationUid,
            Pin(requesterLobby.Context, TestInstant.AddMinutes(12)),
            entered.Run.RunUid,
            entered.Run.RunRevisionUid));
    Assert.Equal(recovered.Run.Run.RunRevisionUid, recoveredReplay.Run.Run.RunRevisionUid);
    Assert.Equal(recovered.Run.Run.ContentSha256, recoveredReplay.Run.Run.ContentSha256);

    var requesterSolo = await service.GetSoloRaidStateAsync(new App.SoloRaidStateQuery(
        requesterLobby.Context.SessionUid,
        requesterLobby.Context.ClientContextUid,
        requesterLobby.Context.Revision.RevisionUid,
        TestInstant.AddMinutes(13)));
    Assert.Null(requesterSolo.ActiveRun);
    Assert.NotNull(requesterSolo.DailyState);
    Assert.Equal(1, requesterSolo.DailyState!.ConsumedEntries);

    var replacement = await service.OpenChallengeRunAsync(new App.OpenChallengeRunCommand(
        EntityUid.New(),
        Pin(requesterSolo.Context, TestInstant.AddMinutes(14)),
        requesterSolo.Selection.Selection.SelectionRevisionUid,
        requesterSolo.AdmissionPins.ProfileRevisionUid,
        requesterSolo.AdmissionPins.AccountCombatStateRevisionUid,
        runtimeProfile.Revision.RevisionUid,
        controlProfile.Revision.RevisionUid,
        [requesterLobby.Account.Squad!.SquadRevisionUid],
        false));
    Assert.Equal(PrivateServerDomain.ChallengeRunState.Open, replacement.Run.State);
    Assert.NotEqual(opened.Run.RunUid, replacement.Run.RunUid);
  }

  [Fact]
  public async Task FirstTeamEntryConsumesOnceWhileLabMockBypassesAnExhaustedQuota()
  {
    var connectionString = ConnectionString();
    AccountFixture account;
    await using (var dataSource = PostgreSqlDataSourceFactory.Create(connectionString))
    {
      await ResetSchemasAsync(dataSource);
      Assert.Equal(MigrationBaseline.Count, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));
      await PublishSixSeasonRaidCatalogAsync(dataSource);
      account = await CreateInitializedAccountAsync(dataSource);
    }

    var policy = PrivateServerDomain.ChallengeOperationalPolicy.CreateConfiguredV1(
        EntityUid.New(),
        "challenge-operational-policy/first-entry-mock-integration/v1",
        dailyEntryLimit: 1,
        PrivateServerDomain.ChallengeEntryConsumptionPoint.FirstTeamEntered,
        PrivateServerDomain.ActiveRunAtResetPolicy.PinOpeningRaidDay,
        PrivateServerDomain.DailyCounterScope.PerSeason,
        PrivateServerDomain.MockBattleCapability.LabOwnedOnly,
        PrivateServerDomain.LocalRankingCapability.LocalRecordsOnly);
    await using var runtime = await PostgreSqlPrivateServerRuntime.CreateAsync(
        connectionString,
        policy,
        new ManualTimeProvider(TestInstant));
    var service = runtime.Service;
    var ready = await CreateReadyChallengeFixtureAsync(
        service,
        account,
        TestInstant,
        TestInstant.AddHours(1));

    var opened = await service.OpenChallengeRunAsync(new App.OpenChallengeRunCommand(
        EntityUid.New(),
        Pin(ready.Solo.Context, TestInstant.AddSeconds(5)),
        ready.Solo.Selection.Selection.SelectionRevisionUid,
        ready.Solo.AdmissionPins.ProfileRevisionUid,
        ready.Solo.AdmissionPins.AccountCombatStateRevisionUid,
        ready.RuntimeProfile.Revision.RevisionUid,
        ready.ControlProfile.Revision.RevisionUid,
        [ready.Lobby.Account.Squad!.SquadRevisionUid],
        false));
    var entered = await service.EnterChallengeTeamAsync(new App.EnterChallengeTeamCommand(
        EntityUid.New(),
        Pin(ready.Solo.Context, TestInstant.AddSeconds(6)),
        opened.Run.RunUid,
        opened.Run.RunRevisionUid,
        1));
    var abandoned = await service.AbandonChallengeRunAsync(new App.AbandonChallengeRunCommand(
        EntityUid.New(),
        Pin(ready.Solo.Context, TestInstant.AddSeconds(7)),
        entered.Run.RunUid,
        entered.Run.RunRevisionUid,
        EntityUid.New(),
        "integration_cleanup"));
    Assert.Equal(PrivateServerDomain.ChallengeRunState.Abandoned, abandoned.Run.State);

    var afterFirstEntry = await service.GetSoloRaidStateAsync(new App.SoloRaidStateQuery(
        ready.Solo.Context.SessionUid,
        ready.Solo.Context.ClientContextUid,
        ready.Solo.Context.Revision.RevisionUid,
        TestInstant.AddSeconds(8)));
    Assert.NotNull(afterFirstEntry.DailyState);
    Assert.Equal(1, afterFirstEntry.DailyState!.ConsumedEntries);

    var exhausted = await Assert.ThrowsAsync<App.PrivateServerApplicationException>(() =>
        service.OpenChallengeRunAsync(new App.OpenChallengeRunCommand(
            EntityUid.New(),
            Pin(afterFirstEntry.Context, TestInstant.AddSeconds(9)),
            afterFirstEntry.Selection.Selection.SelectionRevisionUid,
            afterFirstEntry.AdmissionPins.ProfileRevisionUid,
            afterFirstEntry.AdmissionPins.AccountCombatStateRevisionUid,
            ready.RuntimeProfile.Revision.RevisionUid,
            ready.ControlProfile.Revision.RevisionUid,
            [ready.Lobby.Account.Squad!.SquadRevisionUid],
            false)));
    Assert.Equal(App.PrivateServerFailureKind.Conflict, exhausted.Kind);
    Assert.Equal("challenge_daily_entry_limit_reached", exhausted.Code);

    var mockOpened = await service.OpenChallengeRunAsync(new App.OpenChallengeRunCommand(
        EntityUid.New(),
        Pin(afterFirstEntry.Context, TestInstant.AddSeconds(10)),
        afterFirstEntry.Selection.Selection.SelectionRevisionUid,
        afterFirstEntry.AdmissionPins.ProfileRevisionUid,
        afterFirstEntry.AdmissionPins.AccountCombatStateRevisionUid,
        ready.RuntimeProfile.Revision.RevisionUid,
        ready.ControlProfile.Revision.RevisionUid,
        [ready.Lobby.Account.Squad!.SquadRevisionUid],
        true));
    Assert.True(mockOpened.Run.Binding.IsMockBattle);
    var mockEntered = await service.EnterChallengeTeamAsync(new App.EnterChallengeTeamCommand(
        EntityUid.New(),
        Pin(afterFirstEntry.Context, TestInstant.AddSeconds(11)),
        mockOpened.Run.RunUid,
        mockOpened.Run.RunRevisionUid,
        1));
    _ = await service.AbandonChallengeRunAsync(new App.AbandonChallengeRunCommand(
        EntityUid.New(),
        Pin(afterFirstEntry.Context, TestInstant.AddSeconds(12)),
        mockEntered.Run.RunUid,
        mockEntered.Run.RunRevisionUid,
        EntityUid.New(),
        "integration_cleanup"));

    var afterMock = await service.GetSoloRaidStateAsync(new App.SoloRaidStateQuery(
        afterFirstEntry.Context.SessionUid,
        afterFirstEntry.Context.ClientContextUid,
        afterFirstEntry.Context.Revision.RevisionUid,
        TestInstant.AddSeconds(13)));
    Assert.NotNull(afterMock.DailyState);
    Assert.Equal(1, afterMock.DailyState!.ConsumedEntries);
  }

  [Fact]
  public async Task PinOpeningRaidDayClosesAcrossFiveAndNextRunUsesIndependentDayState()
  {
    var connectionString = ConnectionString();
    AccountFixture account;
    await using (var dataSource = PostgreSqlDataSourceFactory.Create(connectionString))
    {
      await ResetSchemasAsync(dataSource);
      Assert.Equal(MigrationBaseline.Count, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));
      await PublishSixSeasonRaidCatalogAsync(dataSource);
      account = await CreateInitializedAccountAsync(dataSource);
    }

    var boundary = new DateTimeOffset(2026, 8, 19, 20, 0, 0, TimeSpan.Zero);
    var policy = PrivateServerDomain.ChallengeOperationalPolicy.CreateConfiguredV1(
        EntityUid.New(),
        "challenge-operational-policy/pin-opening-boundary-integration/v1",
        dailyEntryLimit: 3,
        PrivateServerDomain.ChallengeEntryConsumptionPoint.RunClosed,
        PrivateServerDomain.ActiveRunAtResetPolicy.PinOpeningRaidDay,
        PrivateServerDomain.DailyCounterScope.PerSeason,
        PrivateServerDomain.MockBattleCapability.Unsupported,
        PrivateServerDomain.LocalRankingCapability.LocalRecordsOnly);
    await using var runtime = await PostgreSqlPrivateServerRuntime.CreateAsync(
        connectionString,
        policy,
        new ManualTimeProvider(boundary.AddMinutes(-10)));
    var service = runtime.Service;
    var ready = await CreateReadyChallengeFixtureAsync(
        service,
        account,
        boundary.AddMinutes(-10),
        boundary.AddMinutes(30));

    var opened = await service.OpenChallengeRunAsync(new App.OpenChallengeRunCommand(
        EntityUid.New(),
        Pin(ready.Solo.Context, boundary.AddMilliseconds(-3)),
        ready.Solo.Selection.Selection.SelectionRevisionUid,
        ready.Solo.AdmissionPins.ProfileRevisionUid,
        ready.Solo.AdmissionPins.AccountCombatStateRevisionUid,
        ready.RuntimeProfile.Revision.RevisionUid,
        ready.ControlProfile.Revision.RevisionUid,
        [ready.Lobby.Account.Squad!.SquadRevisionUid],
        false));
    Assert.Equal(new DateOnly(2026, 8, 19), opened.Run.Binding.RaidDayKey.Date);
    var entered = await service.EnterChallengeTeamAsync(new App.EnterChallengeTeamCommand(
        EntityUid.New(),
        Pin(ready.Solo.Context, boundary.AddMilliseconds(-2)),
        opened.Run.RunUid,
        opened.Run.RunRevisionUid,
        1));
    var observedDamage = PrivateServerDomain.NonNegativeIntegerDamage.Parse("123456789");
    var accepted = await service.SubmitChallengeTeamResultAsync(
        new App.SubmitChallengeTeamResultCommand(
            EntityUid.New(),
            Pin(ready.Solo.Context, boundary.AddSeconds(1)),
            entered.Run.RunUid,
            entered.Run.RunRevisionUid,
            1,
            observedDamage,
            new PrivateServerDomain.BattleFrameTelemetry(
                60,
                60,
                60,
                1_000_000,
                16m,
                17m,
                18m,
                0,
                0),
            [new PrivateServerDomain.ExecutionSegment(
                1,
                ready.RuntimeProfile.Revision.RevisionUid,
                ready.ControlProfile.Revision.RevisionUid,
                0,
                60,
                0,
                60,
                0,
                60,
                0,
                1_000_000,
                PrivateServerDomain.NonNegativeIntegerDamage.Zero,
                observedDamage)],
            []));
    var closed = await service.CloseChallengeRunAsync(new App.CloseChallengeRunCommand(
        EntityUid.New(),
        Pin(ready.Solo.Context, boundary.AddSeconds(2)),
        accepted.Run.RunUid,
        accepted.Run.RunRevisionUid,
        EntityUid.New()));
    Assert.Equal(PrivateServerDomain.ChallengeRunState.Completed, closed.Run.State);
    Assert.Equal(new DateOnly(2026, 8, 19), closed.Run.Binding.RaidDayKey.Date);

    var nextDaySolo = await service.GetSoloRaidStateAsync(new App.SoloRaidStateQuery(
        ready.Solo.Context.SessionUid,
        ready.Solo.Context.ClientContextUid,
        ready.Solo.Context.Revision.RevisionUid,
        boundary.AddSeconds(3)));
    var nextDayRun = await service.OpenChallengeRunAsync(new App.OpenChallengeRunCommand(
        EntityUid.New(),
        Pin(nextDaySolo.Context, boundary.AddSeconds(4)),
        nextDaySolo.Selection.Selection.SelectionRevisionUid,
        nextDaySolo.AdmissionPins.ProfileRevisionUid,
        nextDaySolo.AdmissionPins.AccountCombatStateRevisionUid,
        ready.RuntimeProfile.Revision.RevisionUid,
        ready.ControlProfile.Revision.RevisionUid,
        [ready.Lobby.Account.Squad!.SquadRevisionUid],
        false));
    Assert.Equal(new DateOnly(2026, 8, 20), nextDayRun.Run.Binding.RaidDayKey.Date);

    await using var check = PostgreSqlDataSourceFactory.Create(connectionString);
    await using var connection = await check.OpenConnectionAsync();
    Assert.Equal(2L, await ScalarAsync(
        connection,
        "SELECT count(*) FROM lab_private_server.challenge_daily_state;"));
    Assert.Equal(1L, await ScalarAsync(
        connection,
        "SELECT sum(consumed_entries) FROM lab_private_server.challenge_daily_state_revision " +
        "WHERE challenge_daily_state_revision_id IN " +
        "(SELECT current_challenge_daily_state_revision_id " +
        "FROM lab_private_server.challenge_daily_state);"));
  }

  [Fact]
  public async Task RejectBoundaryBlocksProgressButStillAllowsTerminalAbandonment()
  {
    var connectionString = ConnectionString();
    AccountFixture account;
    await using (var dataSource = PostgreSqlDataSourceFactory.Create(connectionString))
    {
      await ResetSchemasAsync(dataSource);
      Assert.Equal(MigrationBaseline.Count, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));
      await PublishSixSeasonRaidCatalogAsync(dataSource);
      account = await CreateInitializedAccountAsync(dataSource);
    }

    var boundary = new DateTimeOffset(2026, 8, 19, 20, 0, 0, TimeSpan.Zero);
    var policy = PrivateServerDomain.ChallengeOperationalPolicy.CreateConfiguredV1(
        EntityUid.New(),
        "challenge-operational-policy/reject-boundary-integration/v1",
        dailyEntryLimit: 3,
        PrivateServerDomain.ChallengeEntryConsumptionPoint.RunClosed,
        PrivateServerDomain.ActiveRunAtResetPolicy.RejectPostBoundaryProgress,
        PrivateServerDomain.DailyCounterScope.PerSeason,
        PrivateServerDomain.MockBattleCapability.Unsupported,
        PrivateServerDomain.LocalRankingCapability.LocalRecordsOnly);
    await using var runtime = await PostgreSqlPrivateServerRuntime.CreateAsync(
        connectionString,
        policy,
        new ManualTimeProvider(boundary.AddMinutes(-10)));
    var service = runtime.Service;
    var ready = await CreateReadyChallengeFixtureAsync(
        service,
        account,
        boundary.AddMinutes(-10),
        boundary.AddMinutes(30));
    var opened = await service.OpenChallengeRunAsync(new App.OpenChallengeRunCommand(
        EntityUid.New(),
        Pin(ready.Solo.Context, boundary.AddMilliseconds(-3)),
        ready.Solo.Selection.Selection.SelectionRevisionUid,
        ready.Solo.AdmissionPins.ProfileRevisionUid,
        ready.Solo.AdmissionPins.AccountCombatStateRevisionUid,
        ready.RuntimeProfile.Revision.RevisionUid,
        ready.ControlProfile.Revision.RevisionUid,
        [ready.Lobby.Account.Squad!.SquadRevisionUid],
        false));
    var entered = await service.EnterChallengeTeamAsync(new App.EnterChallengeTeamCommand(
        EntityUid.New(),
        Pin(ready.Solo.Context, boundary.AddMilliseconds(-2)),
        opened.Run.RunUid,
        opened.Run.RunRevisionUid,
        1));
    var damage = PrivateServerDomain.NonNegativeIntegerDamage.Parse("1");
    var crossed = await Assert.ThrowsAsync<App.PrivateServerApplicationException>(() =>
        service.SubmitChallengeTeamResultAsync(new App.SubmitChallengeTeamResultCommand(
            EntityUid.New(),
            Pin(ready.Solo.Context, boundary.AddSeconds(1)),
            entered.Run.RunUid,
            entered.Run.RunRevisionUid,
            1,
            damage,
            new PrivateServerDomain.BattleFrameTelemetry(
                1,
                1,
                1,
                1,
                1m,
                1m,
                1m,
                0,
                0),
            [new PrivateServerDomain.ExecutionSegment(
                1,
                ready.RuntimeProfile.Revision.RevisionUid,
                ready.ControlProfile.Revision.RevisionUid,
                0,
                1,
                0,
                1,
                0,
                1,
                0,
                1,
                PrivateServerDomain.NonNegativeIntegerDamage.Zero,
                damage)],
            [])));
    Assert.Equal(App.PrivateServerFailureKind.Conflict, crossed.Kind);
    Assert.Equal("private_server_challenge_run_integrity_conflict", crossed.Code);

    var abandoned = await service.AbandonChallengeRunAsync(new App.AbandonChallengeRunCommand(
        EntityUid.New(),
        Pin(ready.Solo.Context, boundary.AddSeconds(2)),
        entered.Run.RunUid,
        entered.Run.RunRevisionUid,
        EntityUid.New(),
        "boundary_cleanup"));
    Assert.Equal(PrivateServerDomain.ChallengeRunState.Abandoned, abandoned.Run.State);
    Assert.Equal(new DateOnly(2026, 8, 19), abandoned.Run.Binding.RaidDayKey.Date);

    await using var check = PostgreSqlDataSourceFactory.Create(connectionString);
    await using var connection = await check.OpenConnectionAsync();
    Assert.Equal(1L, await ScalarAsync(
        connection,
        "SELECT consumed_entries FROM lab_private_server.challenge_daily_state_revision " +
        "WHERE challenge_daily_state_revision_id = " +
        "(SELECT current_challenge_daily_state_revision_id " +
        "FROM lab_private_server.challenge_daily_state);"));
  }

  [Fact]
  public async Task ConcurrentOpenCreatesOneDailyAggregateAndOneAccountActiveRun()
  {
    var connectionString = ConnectionString();
    AccountFixture account;
    await using (var dataSource = PostgreSqlDataSourceFactory.Create(connectionString))
    {
      await ResetSchemasAsync(dataSource);
      Assert.Equal(MigrationBaseline.Count, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));
      await PublishSixSeasonRaidCatalogAsync(dataSource);
      account = await CreateInitializedAccountAsync(dataSource);
    }

    var policy = PrivateServerDomain.ChallengeOperationalPolicy.CreateConfiguredV1(
        EntityUid.New(),
        "challenge-operational-policy/concurrent-open-integration/v1",
        dailyEntryLimit: 3,
        PrivateServerDomain.ChallengeEntryConsumptionPoint.RunOpened,
        PrivateServerDomain.ActiveRunAtResetPolicy.PinOpeningRaidDay,
        PrivateServerDomain.DailyCounterScope.PerSeason,
        PrivateServerDomain.MockBattleCapability.Unsupported,
        PrivateServerDomain.LocalRankingCapability.LocalRecordsOnly);
    await using var runtime = await PostgreSqlPrivateServerRuntime.CreateAsync(
        connectionString,
        policy,
        new ManualTimeProvider(TestInstant));
    var service = runtime.Service;
    var ready = await CreateReadyChallengeFixtureAsync(
        service,
        account,
        TestInstant,
        TestInstant.AddHours(1));

    App.OpenChallengeRunCommand Command() => new(
        EntityUid.New(),
        Pin(ready.Solo.Context, TestInstant.AddSeconds(5)),
        ready.Solo.Selection.Selection.SelectionRevisionUid,
        ready.Solo.AdmissionPins.ProfileRevisionUid,
        ready.Solo.AdmissionPins.AccountCombatStateRevisionUid,
        ready.RuntimeProfile.Revision.RevisionUid,
        ready.ControlProfile.Revision.RevisionUid,
        [ready.Lobby.Account.Squad!.SquadRevisionUid],
        false);

    static async Task<(App.ChallengeRunProjection? Result, Exception? Failure)> TryOpenAsync(
        App.IPrivateServerService target,
        App.OpenChallengeRunCommand command)
    {
      try
      {
        return (await target.OpenChallengeRunAsync(command), null);
      }
      catch (Exception exception)
      {
        return (null, exception);
      }
    }

    var outcomes = await Task.WhenAll(
        TryOpenAsync(service, Command()),
        TryOpenAsync(service, Command()));
    var success = Assert.Single(outcomes, static outcome => outcome.Result is not null);
    Assert.Equal(PrivateServerDomain.ChallengeRunState.Open, success.Result!.Run.State);
    var failure = Assert.IsType<App.PrivateServerApplicationException>(
        Assert.Single(outcomes, static outcome => outcome.Failure is not null).Failure);
    Assert.Equal(App.PrivateServerFailureKind.Conflict, failure.Kind);

    await using var check = PostgreSqlDataSourceFactory.Create(connectionString);
    await using var connection = await check.OpenConnectionAsync();
    Assert.Equal(1L, await ScalarAsync(
        connection,
        "SELECT count(*) FROM lab_private_server.challenge_daily_state;"));
    Assert.Equal(1L, await ScalarAsync(
        connection,
        "SELECT count(*) FROM lab_private_server.challenge_run " +
        "WHERE status NOT IN ('completed', 'abandoned');"));
    Assert.Equal(1L, await ScalarAsync(
        connection,
        "SELECT consumed_entries FROM lab_private_server.challenge_daily_state_revision " +
        "WHERE challenge_daily_state_revision_id = " +
        "(SELECT current_challenge_daily_state_revision_id " +
        "FROM lab_private_server.challenge_daily_state);"));
  }

  private static async Task PublishSixSeasonRaidCatalogAsync(NpgsqlDataSource dataSource)
  {
    var testType = typeof(PostgreSqlRaidSnapshotTests);
    var artifact = (RaidEvidenceArtifactPublication)testType.GetMethod(
        "Artifact",
        BindingFlags.NonPublic | BindingFlags.Static)!.Invoke(
            null,
            ["phase2b-six-season-static-data"])!;
    var publication = (RaidCatalogPublication)testType.GetMethod(
        "CreateStaticPublication",
        BindingFlags.NonPublic | BindingFlags.Static)!.Invoke(
            null,
            [artifact, "phase2b_higher_tier_evidence_unresolved"])!;
    var attempt = (CompletedImportAttempt)testType.GetMethod(
        "CreateAttempt",
        BindingFlags.NonPublic | BindingFlags.Static)!.Invoke(
            null,
            [publication, new[] { artifact }, "phase2b-directory", null, null])!;
    var receipt = await new PostgreSqlRaidSnapshotImportStore(
        dataSource,
        new RandomEntityUidGenerator()).RecordCompletedAndPublishAsync(
            attempt,
            publication);
    Assert.Equal(6, receipt.Members.Count);
  }

  private static async Task<AccountFixture> CreateInitializedAccountAsync(
      NpgsqlDataSource dataSource)
  {
    var sourceFixture = await InvokeTaskResultAsync(
        typeof(PostgreSqlLocalGameStateTests).GetMethod(
            "PublishCatalogFixtureAsync",
            BindingFlags.NonPublic | BindingFlags.Static)!,
        dataSource,
        5,
        "profile-character");
    var characterUids = Property<IReadOnlyList<EntityUid>>(sourceFixture, "CharacterUids");
    var profile = (LocalAccountProfileWrite)typeof(PostgreSqlLocalGameStateTests).GetMethod(
        "CreateSyntheticProfile",
        BindingFlags.NonPublic | BindingFlags.Static)!.Invoke(
            null,
            [sourceFixture, null])!;
    var created = await new PostgreSqlLocalAccountProfileStore(
        dataSource,
        new RandomEntityUidGenerator()).CreateAsync(
            new CreateLocalAccountProfileCommand(
                EntityUid.New(),
                profile,
                TestInstant));
    var management = new PostgreSqlProfileManagementService(
        dataSource,
        new RandomEntityUidGenerator(),
        new ManualTimeProvider(TestInstant));
    var manifest = await management.EnsureBuiltInFeatureManifestAsync();
    _ = await management.InitializeLocalStateAsync(new ProfileApp.InitializeLocalStateCommand(
        EntityUid.New(),
        created.AccountUid,
        created.ProfileTemplateRevisionUid,
        manifest.ManifestUid,
        manifest.ContentSha256,
        "Phase Two B",
        833,
        null,
        null,
        characterUids[0],
        null,
        [
          new ProfileApp.WalletBalanceProjection("credit", 10_037_000),
          new ProfileApp.WalletBalanceProjection("jewel", 1_771)
        ]));
    return new AccountFixture(
        created.AccountUid,
        created.ProfileTemplateRevisionUid,
        characterUids);
  }

  private static async Task<ReadyChallengeFixture> CreateReadyChallengeFixtureAsync(
      App.IPrivateServerService service,
      AccountFixture account,
      DateTimeOffset issuedAtUtc,
      DateTimeOffset expiresAtUtc)
  {
    var runtimeProfile = await service.SaveRuntimeExecutionProfileAsync(
        new App.SaveRuntimeExecutionProfileCommand(
            EntityUid.New(),
            account.AccountUid,
            EntityUid.New(),
            null,
            ReadyRuntimeContent(),
            issuedAtUtc));
    var controlProfile = await service.SaveCombatControlProfileAsync(
        new App.SaveCombatControlProfileCommand(
            EntityUid.New(),
            account.AccountUid,
            EntityUid.New(),
            null,
            ReadyControlContent(),
            issuedAtUtc));
    var boot = await service.GetBootAsync(new App.BootQuery(issuedAtUtc));
    var loading = await service.OpenSessionAsync(new App.OpenLocalSessionCommand(
        EntityUid.New(),
        account.AccountUid,
        boot.Revision.RevisionUid,
        boot.Revision.ContentSha256,
        issuedAtUtc,
        expiresAtUtc));
    var directory = await service.GetSeasonDirectoryAsync(new App.SeasonDirectoryQuery(
        loading.SessionUid,
        loading.ClientContextUid,
        loading.Revision.RevisionUid,
        issuedAtUtc.AddSeconds(1)));
    var member = directory.Directory.RequireMember(40);
    var connected = await service.ConnectSessionAsync(new App.ConnectLocalSessionCommand(
        EntityUid.New(),
        Pin(loading, issuedAtUtc.AddSeconds(2)),
        directory.Directory.DirectoryUid,
        directory.Directory.ContentSha256,
        member.RaidSnapshotUid));
    var lobby = await service.EnterLobbyAsync(new App.EnterLobbyCommand(
        EntityUid.New(),
        Pin(connected, issuedAtUtc.AddSeconds(3))));
    var solo = await service.GetSoloRaidStateAsync(new App.SoloRaidStateQuery(
        lobby.Context.SessionUid,
        lobby.Context.ClientContextUid,
        lobby.Context.Revision.RevisionUid,
        issuedAtUtc.AddSeconds(4)));
    return new ReadyChallengeFixture(runtimeProfile, controlProfile, lobby, solo);
  }

  private static App.SessionRequestPin Pin(
      App.ClientContextProjection context,
      DateTimeOffset observedAtUtc) => new(
      context.SessionUid,
      context.ClientContextUid,
      context.Revision.RevisionUid,
      observedAtUtc);

  private static PrivateServerDomain.RuntimeExecutionProfileContent ReadyRuntimeContent()
  {
    var graphics = new[]
    {
      "anti_aliasing_enabled",
      "anti_aliasing_step",
      "battle_animation_physics_flags",
      "battle_effect_quality",
      "default_quality_level",
      "graphic_option_mode",
      "mesh_quality",
      "post_process_flags",
      "spine_resolution",
      "texture_quality",
      "volumetric_fog_quality"
    }.Select(static code => new PrivateServerDomain.RuntimeGraphicsOption(
        code,
        PrivateServerDomain.ExecutionCodeFact.Ready("controlled")));
    var settings = new PrivateServerDomain.RuntimeExecutionSettingsSnapshot(
        new PrivateServerDomain.RuntimeSchedulerSettings(
            PrivateServerDomain.ExecutionFact<PrivateServerDomain.TargetFrameRate>.Ready(
                PrivateServerDomain.TargetFrameRate.Fps60),
            PrivateServerDomain.ExecutionFact<int>.Ready(60),
            PrivateServerDomain.ExecutionFact<bool>.Ready(false),
            PrivateServerDomain.ExecutionFact<bool>.Ready(false),
            PrivateServerDomain.ExecutionFact<PrivateServerDomain.TimeScalePolicy>.Ready(
                PrivateServerDomain.TimeScalePolicy.NormalOneX)),
        new PrivateServerDomain.RuntimeDisplaySettings(
            PrivateServerDomain.ExecutionCodeFact.Ready("windows"),
            PrivateServerDomain.ExecutionCodeFact.Ready("fullscreen"),
            PrivateServerDomain.ExecutionFact<int>.Ready(1920),
            PrivateServerDomain.ExecutionFact<int>.Ready(1080),
            PrivateServerDomain.ExecutionFact<decimal>.Ready(60m)),
        new PrivateServerDomain.RuntimeGraphicsSettings(graphics));
    return new PrivateServerDomain.RuntimeExecutionProfileContent(
        PrivateServerDomain.OriginalClientRuntimeBuildBinding.Unresolved(),
        settings,
        null);
  }

  private static PrivateServerDomain.CombatControlProfileContent ReadyControlContent() => new(
      new PrivateServerDomain.CombatControlSettingsSnapshot(
          PrivateServerDomain.ExecutionFact<decimal>.Ready(1m),
          PrivateServerDomain.ExecutionFact<bool>.Ready(false),
          PrivateServerDomain.ExecutionFact<decimal>.NotApplicable(),
          PrivateServerDomain.ExecutionFact<bool>.Ready(false),
          PrivateServerDomain.ExecutionFact<bool>.Ready(true),
          PrivateServerDomain.ExecutionFact<bool>.Unresolved("optional_setting_unresolved"),
          PrivateServerDomain.ExecutionFact<bool>.Unresolved("optional_setting_unresolved")),
      null);

  private static async Task<object> InvokeTaskResultAsync(
      MethodInfo method,
      params object?[] arguments)
  {
    var task = (Task)(method.Invoke(null, arguments) ??
        throw new InvalidOperationException("Fixture task was not created."));
    await task.ConfigureAwait(false);
    return task.GetType().GetProperty("Result")?.GetValue(task) ??
        throw new InvalidOperationException("Fixture task did not return a value.");
  }

  private static T Property<T>(object value, string name) =>
      (T)(value.GetType().GetProperty(
          name,
          BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic)?.GetValue(value) ??
          throw new InvalidOperationException($"Fixture property {name} was not found."));

  private static string ConnectionString()
  {
    var source = Environment.GetEnvironmentVariable("NIKKE_LAB_TEST_DB") ??
        throw new InvalidOperationException(
            "NIKKE_LAB_TEST_DB is required for PostgreSQL integration tests.");
    var validated = PostgreSqlConnectionPolicy.Validate(source);
    PostgreSqlTestDatabaseGuard.RequireDisposableDatabase(
        new NpgsqlConnectionStringBuilder(validated));
    return validated;
  }

  private static NpgsqlDataSource CreateDataSource() =>
      PostgreSqlDataSourceFactory.Create(ConnectionString());

  private static async Task ResetSchemasAsync(NpgsqlDataSource dataSource)
  {
    if (!string.Equals(
            Environment.GetEnvironmentVariable("NIKKE_LAB_TEST_RESET_TOKEN"),
            ResetToken,
            StringComparison.Ordinal))
    {
      throw new InvalidOperationException("The disposable PostgreSQL reset token is required.");
    }

    await using var command = dataSource.CreateCommand(
        """
        DROP SCHEMA IF EXISTS lab_private_server CASCADE;
        DROP SCHEMA IF EXISTS lab_local_game CASCADE;
        DROP SCHEMA IF EXISTS lab_profile CASCADE;
        DROP SCHEMA IF EXISTS lab_combat_support CASCADE;
        DROP SCHEMA IF EXISTS lab_raid CASCADE;
        DROP SCHEMA IF EXISTS lab_private CASCADE;
        DROP SCHEMA IF EXISTS lab_catalog CASCADE;
        DROP SCHEMA IF EXISTS lab_import CASCADE;
        DROP SCHEMA IF EXISTS lab_meta CASCADE;
        """);
    _ = await command.ExecuteNonQueryAsync();
  }

  private static async Task<long> ScalarAsync(NpgsqlConnection connection, string sql)
  {
    await using var command = new NpgsqlCommand(sql, connection);
    return Convert.ToInt64(
        await command.ExecuteScalarAsync(),
        System.Globalization.CultureInfo.InvariantCulture);
  }

  private static async Task<long> ScalarForUidAsync(
      NpgsqlConnection connection,
      string sql,
      EntityUid uid)
  {
    await using var command = new NpgsqlCommand(sql, connection);
    command.Parameters.AddWithValue("uid", uid.Value);
    return Convert.ToInt64(
        await command.ExecuteScalarAsync(),
        System.Globalization.CultureInfo.InvariantCulture);
  }

  private static async Task<DateOnly> RaidDayAsync(
      NpgsqlConnection connection,
      DateTimeOffset observedAtUtc)
  {
    await using var command = new NpgsqlCommand(
        "SELECT lab_private_server.raid_day_key(@observed_at_utc);",
        connection);
    command.Parameters.AddWithValue("observed_at_utc", observedAtUtc);
    var result = await command.ExecuteScalarAsync();
    return result switch
    {
      DateOnly value => value,
      DateTime value => DateOnly.FromDateTime(value),
      _ => throw new InvalidOperationException("PostgreSQL date value was not recognized.")
    };
  }

  private sealed class ManualTimeProvider(DateTimeOffset value) : TimeProvider
  {
    public override DateTimeOffset GetUtcNow() => value;
  }

  private sealed record AccountFixture(
      EntityUid AccountUid,
      EntityUid ProfileRevisionUid,
      IReadOnlyList<EntityUid> CharacterUids);

  private sealed record ReadyChallengeFixture(
      App.RuntimeExecutionProfileProjection RuntimeProfile,
      App.CombatControlProfileProjection ControlProfile,
      App.LobbyBootstrapProjection Lobby,
      App.SoloRaidStateProjection Solo);
}
