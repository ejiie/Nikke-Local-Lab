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

public sealed class PostgreSqlPrivateServerContextReplayTests
{
  private const string ResetToken = "allow-phase1a-disposable-schema-reset";
  private static readonly DateTimeOffset TestInstant =
      new(2026, 8, 20, 1, 0, 0, TimeSpan.Zero);

  [Fact]
  public async Task EnterLobbyReplayRestoresSealedBootstrapAfterLobbyHeadAdvances()
  {
    var connectionString = ConnectionString();
    EntityUid accountUid;
    await using (var dataSource = PostgreSqlDataSourceFactory.Create(connectionString))
    {
      await ResetSchemasAsync(dataSource);
      Assert.Equal(MigrationBaseline.Count, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));
      await PublishSixSeasonRaidCatalogAsync(dataSource);
      var account = await CreateInitializedAccountAsync(dataSource);
      accountUid = account.AccountUid;
    }

    await using var runtime = await PostgreSqlPrivateServerRuntime.CreateAsync(
        connectionString,
        new ManualTimeProvider(TestInstant));
    var service = runtime.Service;
    var boot = await service.GetBootAsync(new App.BootQuery(TestInstant));
    var loading = await service.OpenSessionAsync(new App.OpenLocalSessionCommand(
        EntityUid.New(),
        accountUid,
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
    var enterCommand = new App.EnterLobbyCommand(
        EntityUid.New(),
        Pin(connected, TestInstant.AddSeconds(3)));
    var first = await service.EnterLobbyAsync(enterCommand);

    await using (var managementDataSource =
        PostgreSqlDataSourceFactory.Create(connectionString))
    {
      var management = new PostgreSqlProfileManagementService(
          managementDataSource,
          new RandomEntityUidGenerator(),
          new ManualTimeProvider(TestInstant.AddSeconds(10)));
      var current = await management.GetCurrentBootstrapAsync(accountUid) ??
          throw new InvalidOperationException("Current bootstrap was not available.");
      var lobby = current.Lobby;
      var advanced = await management.SaveLobbyPresentationAsync(
          new ProfileApp.SaveLobbyPresentationCommand(
              EntityUid.New(),
              accountUid,
              lobby.Revision.RevisionUid,
              "Phase Two B Advanced",
              lobby.CommanderLevel,
              lobby.ProfileIconSelectionUid,
              lobby.ProfileFrameSelectionUid,
              lobby.LobbyCharacterSelectionUid,
              lobby.LobbyBackgroundSelectionUid));
      Assert.NotEqual(first.Account.Lobby.Revision.RevisionUid, advanced.Revision.RevisionUid);
      Assert.NotEqual(first.Account.Lobby.DisplayName, advanced.DisplayName);
    }

    var replay = await service.EnterLobbyAsync(enterCommand with
    {
      RequestPin = Pin(connected, TestInstant.AddSeconds(20))
    });
    Assert.Equivalent(first, replay, strict: true);
    Assert.Equal("Phase Two B", replay.Account.Lobby.DisplayName);

    var currentLobby = await service.GetLobbyBootstrapAsync(
        new App.LobbyBootstrapQuery(
            first.Context.SessionUid,
            first.Context.ClientContextUid,
            first.Context.Revision.RevisionUid,
            TestInstant.AddSeconds(21)));
    Assert.Equivalent(first, currentLobby, strict: true);

    var alternateFeature = await CreateAlternateFeatureManifestAsync(connectionString);
    await AssertLobbyCloseFeaturePinMutationRejectedAsync(
        connectionString,
        first.Context.Revision.RevisionUid,
        alternateFeature);
    Assert.NotNull(first.Account.Squad);
    await AssertLobbyCloseSquadPinMutationRejectedAsync(
        connectionString,
        first.Context.Revision.RevisionUid,
        alternateFeature);

    var guardLoading = await service.OpenSessionAsync(new App.OpenLocalSessionCommand(
        EntityUid.New(),
        accountUid,
        boot.Revision.RevisionUid,
        boot.Revision.ContentSha256,
        TestInstant.AddSeconds(22),
        TestInstant.AddMinutes(30)));
    var guardDirectory = await service.GetSeasonDirectoryAsync(new App.SeasonDirectoryQuery(
        guardLoading.SessionUid,
        guardLoading.ClientContextUid,
        guardLoading.Revision.RevisionUid,
        TestInstant.AddSeconds(23)));
    var guardMember = guardDirectory.Directory.RequireMember(40);
    var guardConnected = await service.ConnectSessionAsync(new App.ConnectLocalSessionCommand(
        EntityUid.New(),
        Pin(guardLoading, TestInstant.AddSeconds(24)),
        guardDirectory.Directory.DirectoryUid,
        guardDirectory.Directory.ContentSha256,
        guardMember.RaidSnapshotUid));
    await AssertInitialLobbyFeaturePinMismatchRejectedAsync(
        connectionString,
        guardConnected.Revision.RevisionUid,
        alternateFeature);
  }

  [Fact]
  public async Task ActiveRunBlocksSeasonChangeUntilTheRunIsTerminal()
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
        "challenge-operational-policy/context-selection-guard/v1",
        3,
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
    var season40 = directory.Directory.RequireMember(40);
    var connected = await service.ConnectSessionAsync(new App.ConnectLocalSessionCommand(
        EntityUid.New(),
        Pin(loading, TestInstant.AddSeconds(2)),
        directory.Directory.DirectoryUid,
        directory.Directory.ContentSha256,
        season40.RaidSnapshotUid));
    var lobby = await service.EnterLobbyAsync(new App.EnterLobbyCommand(
        EntityUid.New(),
        Pin(connected, TestInstant.AddSeconds(3))));
    var squad = Assert.IsType<ProfileApp.SquadProjection>(lobby.Account.Squad);
    var solo = await service.GetSoloRaidStateAsync(new App.SoloRaidStateQuery(
        lobby.Context.SessionUid,
        lobby.Context.ClientContextUid,
        lobby.Context.Revision.RevisionUid,
        TestInstant.AddSeconds(4)));
    var opened = await service.OpenChallengeRunAsync(new App.OpenChallengeRunCommand(
        EntityUid.New(),
        Pin(solo.Context, TestInstant.AddSeconds(5)),
        solo.Selection.Selection.SelectionRevisionUid,
        solo.AdmissionPins.ProfileRevisionUid,
        solo.AdmissionPins.AccountCombatStateRevisionUid,
        runtimeProfile.Revision.RevisionUid,
        controlProfile.Revision.RevisionUid,
        [squad.SquadRevisionUid],
        false));

    var season7 = directory.Directory.RequireMember(7);
    var blocked = await Assert.ThrowsAsync<App.PrivateServerApplicationException>(() =>
        service.SelectSeasonAsync(new App.SelectRaidSeasonCommand(
            EntityUid.New(),
            Pin(solo.Context, TestInstant.AddSeconds(6)),
            solo.Selection.Selection.SelectionRevisionUid,
            directory.Directory.DirectoryUid,
            directory.Directory.ContentSha256,
            season7.RaidSnapshotUid)));
    Assert.Equal(App.PrivateServerFailureKind.Conflict, blocked.Kind);
    Assert.Equal("active_challenge_run_blocks_season_selection", blocked.Code);

    var unchanged = await service.GetSoloRaidStateAsync(new App.SoloRaidStateQuery(
        solo.Context.SessionUid,
        solo.Context.ClientContextUid,
        solo.Context.Revision.RevisionUid,
        TestInstant.AddSeconds(7)));
    Assert.Equal(solo.Context.Revision, unchanged.Context.Revision);
    Assert.Equal(
        solo.Selection.Selection.SelectionRevisionUid,
        unchanged.Selection.Selection.SelectionRevisionUid);
    Assert.Equal(40, unchanged.Selection.Selection.Member.SeasonNumber);

    var abandoned = await service.AbandonChallengeRunAsync(
        new App.AbandonChallengeRunCommand(
            EntityUid.New(),
            Pin(solo.Context, TestInstant.AddSeconds(8)),
            opened.Run.RunUid,
            opened.Run.RunRevisionUid,
            EntityUid.New(),
            "test_terminal_release"));
    Assert.Equal(PrivateServerDomain.ChallengeRunState.Abandoned, abandoned.Run.State);

    var selected = await service.SelectSeasonAsync(new App.SelectRaidSeasonCommand(
        EntityUid.New(),
        Pin(solo.Context, TestInstant.AddSeconds(9)),
        solo.Selection.Selection.SelectionRevisionUid,
        directory.Directory.DirectoryUid,
        directory.Directory.ContentSha256,
        season7.RaidSnapshotUid));
    Assert.Equal(7, selected.Selection.Member.SeasonNumber);
    Assert.NotEqual(solo.Context.Revision.RevisionUid, selected.Context.Revision.RevisionUid);
  }

  private static async Task<FeaturePin> CreateAlternateFeatureManifestAsync(
      string connectionString)
  {
    var uid = EntityUid.New();
    var contentSha256 = Sha256Digest.ComputeUtf8("alternate-v0006-feature-manifest");
    await using var dataSource = PostgreSqlDataSourceFactory.Create(connectionString);
    await using var connection = await dataSource.OpenConnectionAsync();
    await using var transaction = await connection.BeginTransactionAsync();
    long id;
    await using (var insert = new NpgsqlCommand(
        """
        INSERT INTO lab_local_game.client_feature_manifest (
            client_feature_manifest_uid, contract_version, entry_count,
            content_sha256, published_at_utc
        ) VALUES (
            @uid, 'nll/client-feature-manifest/v99', 1,
            @content_sha256, @published_at_utc
        )
        RETURNING client_feature_manifest_id
        """,
        connection,
        transaction))
    {
      insert.Parameters.AddWithValue("uid", uid.Value);
      insert.Parameters.AddWithValue("content_sha256", contentSha256.ToByteArray());
      insert.Parameters.AddWithValue("published_at_utc", TestInstant.AddSeconds(25));
      id = Convert.ToInt64(
          await insert.ExecuteScalarAsync(),
          System.Globalization.CultureInfo.InvariantCulture);
    }

    await using (var entry = new NpgsqlCommand(
        """
        INSERT INTO lab_local_game.client_feature_manifest_entry (
            client_feature_manifest_id, route_code, capability_code
        ) VALUES (@id, 'test.alternate', 'hidden')
        """,
        connection,
        transaction))
    {
      entry.Parameters.AddWithValue("id", id);
      _ = await entry.ExecuteNonQueryAsync();
    }

    await transaction.CommitAsync();
    return new FeaturePin(id, uid, contentSha256);
  }

  private static async Task AssertLobbyCloseFeaturePinMutationRejectedAsync(
      string connectionString,
      EntityUid contextRevisionUid,
      FeaturePin alternateFeature)
  {
    await using var dataSource = PostgreSqlDataSourceFactory.Create(connectionString);
    await using var connection = await dataSource.OpenConnectionAsync();
    await using var command = new NpgsqlCommand(
        CloneContextRevisionSql(
            "'closed'",
            "revision.lobby_ready_at_utc",
            "revision.account_revision_set_sha256",
            "@feature_id",
            "@feature_uid",
            "@feature_sha256",
            closedAtExpression: "@materialized_at_utc"),
        connection);
    AddCloneParameters(
        command,
        contextRevisionUid,
        TestInstant.AddSeconds(26),
        alternateFeature);
    var exception = await Assert.ThrowsAsync<PostgresException>(
        () => command.ExecuteNonQueryAsync());
    Assert.Equal(PostgresErrorCodes.RaiseException, exception.SqlState);
    Assert.Equal("private_server_context_close_pin_mutation", exception.MessageText);
  }

  private static async Task AssertInitialLobbyFeaturePinMismatchRejectedAsync(
      string connectionString,
      EntityUid connectedContextRevisionUid,
      FeaturePin alternateFeature)
  {
    await using var dataSource = PostgreSqlDataSourceFactory.Create(connectionString);
    await using var connection = await dataSource.OpenConnectionAsync();
    await using var command = new NpgsqlCommand(
        CloneContextRevisionSql(
            "'lobby_ready'",
            "@materialized_at_utc",
            "@synthetic_revision_set_sha256",
            "@feature_id",
            "@feature_uid",
            "@feature_sha256",
            bindCurrentAccountHeads: true),
        connection);
    AddCloneParameters(
        command,
        connectedContextRevisionUid,
        TestInstant.AddSeconds(27),
        alternateFeature);
    command.Parameters.AddWithValue(
        "synthetic_revision_set_sha256",
        Sha256Digest.ComputeUtf8("synthetic-wrong-revision-set").ToByteArray());
    var exception = await Assert.ThrowsAsync<PostgresException>(
        () => command.ExecuteNonQueryAsync());
    Assert.Equal(PostgresErrorCodes.RaiseException, exception.SqlState);
    Assert.Equal(
        "private_server_context_account_revision_set_mismatch",
        exception.MessageText);
  }

  private static async Task AssertLobbyCloseSquadPinMutationRejectedAsync(
      string connectionString,
      EntityUid contextRevisionUid,
      FeaturePin unusedFeatureParameters)
  {
    await using var dataSource = PostgreSqlDataSourceFactory.Create(connectionString);
    await using var connection = await dataSource.OpenConnectionAsync();
    await using var command = new NpgsqlCommand(
        CloneContextRevisionSql(
            "'closed'",
            "revision.lobby_ready_at_utc",
            "revision.account_revision_set_sha256",
            "revision.client_feature_manifest_id",
            "revision.client_feature_manifest_uid",
            "revision.client_feature_manifest_content_sha256",
            clearSquadPins: true,
            closedAtExpression: "@materialized_at_utc"),
        connection);
    AddCloneParameters(
        command,
        contextRevisionUid,
        TestInstant.AddSeconds(27),
        unusedFeatureParameters);
    var exception = await Assert.ThrowsAsync<PostgresException>(
        () => command.ExecuteNonQueryAsync());
    Assert.Equal(PostgresErrorCodes.RaiseException, exception.SqlState);
    Assert.Equal("private_server_context_close_pin_mutation", exception.MessageText);
  }

  private static string CloneContextRevisionSql(
      string stageExpression,
      string lobbyReadyExpression,
      string revisionSetExpression,
      string featureIdExpression,
      string featureUidExpression,
      string featureShaExpression,
      bool bindCurrentAccountHeads = false,
      bool clearSquadPins = false,
      string closedAtExpression = "revision.closed_at_utc")
  {
    var accountState = bindCurrentAccountHeads
        ? "account.current_account_state_revision_id"
        : "revision.account_state_revision_id";
    var profileRevision = bindCurrentAccountHeads
        ? "account.current_profile_template_revision_id"
        : "revision.profile_template_revision_id";
    var lobbyRevision = bindCurrentAccountHeads
        ? "client.current_lobby_presentation_revision_id"
        : "revision.lobby_presentation_revision_id";
    var walletRevision = bindCurrentAccountHeads
        ? "client.current_wallet_revision_id"
        : "revision.wallet_revision_id";
    var squadRevision = clearSquadPins
        ? "NULL"
        : bindCurrentAccountHeads
            ? "profile.squad_revision_id"
            : "revision.squad_revision_id";
    var squadUid = clearSquadPins
        ? "NULL"
        : bindCurrentAccountHeads
            ? "squad.squad_revision_uid"
            : "revision.squad_revision_uid";
    var squadSha = clearSquadPins
        ? "NULL"
        : bindCurrentAccountHeads
            ? "squad.content_sha256"
            : "revision.squad_revision_content_sha256";
    return $"""
        INSERT INTO lab_private_server.local_client_context_revision (
            local_client_context_revision_uid, local_client_context_id,
            local_session_id, local_account_id, revision_number,
            previous_local_client_context_revision_id,
            private_server_boot_revision_id, private_server_boot_content_sha256,
            capability_manifest_id, capability_manifest_content_sha256,
            application_build_id, application_build_sha256, application_contract_id,
            issued_at_utc, expires_at_utc, stage, connected_at_utc,
            lobby_ready_at_utc, account_revision_set_sha256,
            account_state_revision_id, profile_template_revision_id,
            lobby_presentation_revision_id, wallet_revision_id,
            client_feature_manifest_id, client_feature_manifest_uid,
            client_feature_manifest_content_sha256,
            squad_revision_id, squad_revision_uid, squad_revision_content_sha256,
            selected_raid_season_revision_id, selected_season_content_sha256,
            closed_at_utc, content_sha256, materialized_at_utc
        )
        SELECT @new_revision_uid, revision.local_client_context_id,
               revision.local_session_id, revision.local_account_id,
               revision.revision_number + 1,
               revision.local_client_context_revision_id,
               revision.private_server_boot_revision_id,
               revision.private_server_boot_content_sha256,
               revision.capability_manifest_id,
               revision.capability_manifest_content_sha256,
               revision.application_build_id, revision.application_build_sha256,
               revision.application_contract_id,
               revision.issued_at_utc, revision.expires_at_utc,
               {stageExpression}, revision.connected_at_utc,
               {lobbyReadyExpression}, {revisionSetExpression},
               {accountState}, {profileRevision}, {lobbyRevision}, {walletRevision},
               {featureIdExpression}, {featureUidExpression}, {featureShaExpression},
               {squadRevision}, {squadUid}, {squadSha},
               revision.selected_raid_season_revision_id,
               revision.selected_season_content_sha256,
               {closedAtExpression}, revision.content_sha256,
               @materialized_at_utc
          FROM lab_private_server.local_client_context_revision revision
          JOIN lab_profile.local_account account
            ON account.local_account_id = revision.local_account_id
          JOIN lab_profile.profile_template_revision profile
            ON profile.profile_template_revision_id =
               account.current_profile_template_revision_id
          JOIN lab_local_game.account_client_state client
            ON client.local_account_id = account.local_account_id
          LEFT JOIN lab_profile.squad_revision squad
            ON squad.squad_revision_id = profile.squad_revision_id
         WHERE revision.local_client_context_revision_uid = @source_revision_uid
        """;
  }

  private static void AddCloneParameters(
      NpgsqlCommand command,
      EntityUid sourceRevisionUid,
      DateTimeOffset materializedAtUtc,
      FeaturePin feature)
  {
    command.Parameters.AddWithValue("new_revision_uid", EntityUid.New().Value);
    command.Parameters.AddWithValue("source_revision_uid", sourceRevisionUid.Value);
    command.Parameters.AddWithValue("materialized_at_utc", materializedAtUtc);
    command.Parameters.AddWithValue("feature_id", feature.Id);
    command.Parameters.AddWithValue("feature_uid", feature.Uid.Value);
    command.Parameters.AddWithValue("feature_sha256", feature.ContentSha256.ToByteArray());
  }

  private static App.SessionRequestPin Pin(
      App.ClientContextProjection context,
      DateTimeOffset observedAtUtc) => new(
      context.SessionUid,
      context.ClientContextUid,
      context.Revision.RevisionUid,
      observedAtUtc);

  private static async Task PublishSixSeasonRaidCatalogAsync(
      NpgsqlDataSource dataSource)
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
    var characterUids = Property<IReadOnlyList<EntityUid>>(
        sourceFixture,
        "CharacterUids");
    var profile = (LocalAccountProfileWrite)typeof(PostgreSqlLocalGameStateTests)
        .GetMethod(
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
    _ = await management.InitializeLocalStateAsync(
        new ProfileApp.InitializeLocalStateCommand(
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
    return new AccountFixture(created.AccountUid);
  }

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
          PrivateServerDomain.ExecutionFact<bool>.Unresolved(
              "optional_setting_unresolved"),
          PrivateServerDomain.ExecutionFact<bool>.Unresolved(
              "optional_setting_unresolved")),
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

  private sealed class ManualTimeProvider(DateTimeOffset value) : TimeProvider
  {
    public override DateTimeOffset GetUtcNow() => value;
  }

  private sealed record FeaturePin(
      long Id,
      EntityUid Uid,
      Sha256Digest ContentSha256);

  private sealed record AccountFixture(EntityUid AccountUid);
}
