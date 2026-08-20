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

public sealed class PostgreSqlPrivateServerRunInvariantTests
{
  private const string ResetToken = "allow-phase1a-disposable-schema-reset";
  private static readonly DateTimeOffset TestInstant =
      new(2026, 8, 19, 19, 50, 0, TimeSpan.Zero);
  private static readonly DateTimeOffset RaidDayBoundary =
      new(2026, 8, 19, 20, 0, 0, TimeSpan.Zero);

  [Fact]
  public async Task DirectSqlCannotBypassRunReceiptDailyOrAdmissionPins()
  {
    var connectionString = ConnectionString();
    AccountFixture account;
    await using (var dataSource = PostgreSqlDataSourceFactory.Create(connectionString))
    {
      await ResetSchemasAsync(dataSource);
      Assert.Equal(7, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));
      await PublishSixSeasonRaidCatalogAsync(dataSource);
      account = await CreateInitializedAccountAsync(dataSource);
    }

    var initialPolicy = PrivateServerDomain.ChallengeOperationalPolicy.CreateConfiguredV1(
        EntityUid.New(),
        "challenge-operational-policy/run-invariant-integration/v1",
        dailyEntryLimit: 5,
        PrivateServerDomain.ChallengeEntryConsumptionPoint.FirstTeamEntered,
        PrivateServerDomain.ActiveRunAtResetPolicy.PinOpeningRaidDay,
        PrivateServerDomain.DailyCounterScope.PerSeason,
        PrivateServerDomain.MockBattleCapability.Unsupported,
        PrivateServerDomain.LocalRankingCapability.LocalRecordsOnly);
    await using var runtime = await PostgreSqlPrivateServerRuntime.CreateAsync(
        connectionString,
        initialPolicy,
        new ManualTimeProvider(TestInstant));
    var service = runtime.Service;
    var ready = await CreateReadyChallengeFixtureAsync(
        service,
        account,
        TestInstant,
        RaidDayBoundary.AddMinutes(20));
    var applicationSelectionState =
        await ReadApplicationBuildSelectionStateAsync(connectionString);
    await AssertCustomRejectedAsync(
        connectionString,
        "private_server_write_operation_inverse_missing",
        InsertDuplicateApplicationBuildSelectionAsync);
    Assert.Equal(
        applicationSelectionState,
        await ReadApplicationBuildSelectionStateAsync(connectionString));
    var contextState = await ReadContextStateAsync(
        connectionString,
        ready.Solo.Context.ClientContextUid);
    await AssertCustomRejectedAsync(
        connectionString,
        "private_server_context_transition_invalid",
        (connection, transaction) => InsertRepeatedLobbyRevisionAsync(
            connection,
            transaction,
            ready.Solo.Context.ClientContextUid,
            TestInstant.AddSeconds(4)));
    Assert.Equal(
        contextState,
        await ReadContextStateAsync(
            connectionString,
            ready.Solo.Context.ClientContextUid));
    var writeOperationCount = await ReadWriteOperationCountAsync(connectionString);
    await AssertCustomRejectedAsync(
        connectionString,
        "private_server_write_operation_result_mismatch",
        (connection, transaction) => InsertMismatchedPolicyWriteOperationAsync(
            connection,
            transaction,
            TestInstant.AddSeconds(4)));
    Assert.Equal(writeOperationCount, await ReadWriteOperationCountAsync(connectionString));
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

    var enteredState = await ReadStateAsync(connectionString, entered.Run.RunUid);
    Assert.Equal(1, enteredState.ConsumedEntries);
    await AssertCustomRejectedAsync(
        connectionString,
        "raid_season_selection_active_run",
        (connection, transaction) => InsertSelectionRevisionDuringActiveRunAsync(
            connection,
            transaction,
            entered.Run.RunUid,
            TestInstant.AddSeconds(7)));
    Assert.Equal(enteredState, await ReadStateAsync(connectionString, entered.Run.RunUid));
    await AssertCustomRejectedAsync(
        connectionString,
        "private_server_context_active_run",
        (connection, transaction) => InsertContextRevisionDuringActiveRunAsync(
            connection,
            transaction,
            entered.Run.RunUid,
            TestInstant.AddSeconds(7)));
    Assert.Equal(enteredState, await ReadStateAsync(connectionString, entered.Run.RunUid));
    await AssertCustomRejectedAsync(
        connectionString,
        "challenge_run_operation_team_ordinal_mismatch",
        (connection, transaction) => RewriteEnterOperationOrdinalAsync(
            connection,
            transaction,
            entered.Run.RunUid));
    Assert.Equal(enteredState, await ReadStateAsync(connectionString, entered.Run.RunUid));
    await AssertCustomRejectedAsync(
        connectionString,
        "challenge_run_operation_owner_session_inactive",
        (connection, transaction) => ReplayOrdinaryOperationWithRevokedOwnerAsync(
            connection,
            transaction,
            entered.Run.RunUid,
            TestInstant.AddSeconds(7)));
    Assert.Equal(enteredState, await ReadStateAsync(connectionString, entered.Run.RunUid));

    await AssertCustomRejectedAsync(
        connectionString,
        "private_server_revision_head_invalid",
        (connection, transaction) => InsertOrphanRunRevisionAsync(
            connection,
            transaction,
            entered.Run.RunUid,
            TestInstant.AddSeconds(7)));
    Assert.Equal(enteredState, await ReadStateAsync(connectionString, entered.Run.RunUid));

    await AssertCustomRejectedAsync(
        connectionString,
        "challenge_daily_consumption_operation_mismatch",
        (connection, transaction) => InsertArbitraryDailyConsumptionAsync(
            connection,
            transaction,
            entered.Run.RunUid,
            TestInstant.AddSeconds(7)));
    Assert.Equal(enteredState, await ReadStateAsync(connectionString, entered.Run.RunUid));

    await AssertCustomRejectedAsync(
        connectionString,
        "challenge_damage_receipt_graph_invalid",
        (connection, transaction) => InsertOrphanReceiptGraphAsync(
            connection,
            transaction,
            entered.Run.RunUid,
            TestInstant.AddSeconds(7)));
    Assert.Equal(enteredState, await ReadStateAsync(connectionString, entered.Run.RunUid));

    var currentRuntime = await service.SaveRuntimeExecutionProfileAsync(
        new App.SaveRuntimeExecutionProfileCommand(
            EntityUid.New(),
            account.AccountUid,
            ready.RuntimeProfile.Revision.ProfileUid,
            ready.RuntimeProfile.Revision.RevisionUid,
            ReadyRuntimeContent(width: 1919),
            TestInstant.AddSeconds(8)));
    var currentControl = await service.SaveCombatControlProfileAsync(
        new App.SaveCombatControlProfileCommand(
            EntityUid.New(),
            account.AccountUid,
            ready.ControlProfile.Revision.ProfileUid,
            ready.ControlProfile.Revision.RevisionUid,
            ReadyControlContent(aimSensitivity: 2m),
            TestInstant.AddSeconds(8)));
    await AssertCustomRejectedAsync(
        connectionString,
        "challenge_damage_receipt_graph_invalid",
        (connection, transaction) => InsertMismatchedExecutionReceiptAsync(
            connection,
            transaction,
            entered.Run.RunUid,
            currentRuntime.Revision.RevisionUid,
            currentControl.Revision.RevisionUid,
            TestInstant.AddSeconds(9)));
    Assert.Equal(enteredState, await ReadStateAsync(connectionString, entered.Run.RunUid));

    var damage = PrivateServerDomain.NonNegativeIntegerDamage.Parse("7");
    var accepted = await service.SubmitChallengeTeamResultAsync(
        new App.SubmitChallengeTeamResultCommand(
            EntityUid.New(),
            Pin(ready.Solo.Context, TestInstant.AddSeconds(10)),
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
            []));
    var acceptedState = await ReadStateAsync(connectionString, accepted.Run.RunUid);
    await AssertCustomRejectedAsync(
        connectionString,
        "challenge_run_result_graph_invalid",
        (connection, transaction) => InsertOrphanRunResultAsync(
            connection,
            transaction,
            accepted.Run.RunUid,
            TestInstant.AddSeconds(11)));
    Assert.Equal(acceptedState, await ReadStateAsync(connectionString, accepted.Run.RunUid));

    var abandoned = await service.AbandonChallengeRunAsync(new App.AbandonChallengeRunCommand(
        EntityUid.New(),
        Pin(ready.Solo.Context, TestInstant.AddSeconds(12)),
        accepted.Run.RunUid,
        accepted.Run.RunRevisionUid,
        EntityUid.New(),
        "invariant_fixture_cleanup"));
    Assert.Equal(PrivateServerDomain.ChallengeRunState.Abandoned, abandoned.Run.State);
    var terminalState = await ReadStateAsync(connectionString, abandoned.Run.RunUid);

    var inverseProbe = await service.OpenChallengeRunAsync(new App.OpenChallengeRunCommand(
        EntityUid.New(),
        Pin(ready.Solo.Context, TestInstant.AddSeconds(13)),
        ready.Solo.Selection.Selection.SelectionRevisionUid,
        ready.Solo.AdmissionPins.ProfileRevisionUid,
        ready.Solo.AdmissionPins.AccountCombatStateRevisionUid,
        currentRuntime.Revision.RevisionUid,
        currentControl.Revision.RevisionUid,
        [ready.Lobby.Account.Squad!.SquadRevisionUid],
        false));
    var inverseProbeState = await ReadStateAsync(connectionString, inverseProbe.Run.RunUid);
    await AssertCustomRejectedAsync(
        connectionString,
        "challenge_run_revision_operation_mismatch",
        (connection, transaction) => InsertIntermediateRunRevisionWithoutOperationAsync(
            connection,
            transaction,
            inverseProbe.Run.RunUid,
            TestInstant.AddSeconds(14)));
    Assert.Equal(
        inverseProbeState,
        await ReadStateAsync(connectionString, inverseProbe.Run.RunUid));
    _ = await service.AbandonChallengeRunAsync(new App.AbandonChallengeRunCommand(
        EntityUid.New(),
        Pin(ready.Solo.Context, TestInstant.AddSeconds(15)),
        inverseProbe.Run.RunUid,
        inverseProbe.Run.RunRevisionUid,
        EntityUid.New(),
        "inverse_probe_cleanup"));

    var changedProfile = CreateSyntheticProfile(account.SourceFixture, 203);
    await using var profileDataSource = PostgreSqlDataSourceFactory.Create(connectionString);
    var savedProfile = await new PostgreSqlLocalAccountProfileStore(
        profileDataSource,
        new RandomEntityUidGenerator()).SaveAsync(new SaveLocalAccountProfileCommand(
        EntityUid.New(),
        account.AccountUid,
        account.ProfileRevisionUid,
        changedProfile,
        TestInstant.AddSeconds(16)));
    await AssertConstraintRejectedAsync(
        connectionString,
        "fk_challenge_run_team_member_profile_pin",
        (connection, transaction) => RebindRunMemberToMismatchedProfileAsync(
            connection,
            transaction,
            abandoned.Run.RunUid,
            savedProfile.ProfileTemplateRevisionUid));
    Assert.Equal(terminalState, await ReadStateAsync(connectionString, abandoned.Run.RunUid));

    await AssertCustomRejectedAsync(
        connectionString,
        "challenge_run_execution_profile_not_ready",
        (connection, transaction) => InsertStaleExecutionProfileRunAsync(
            connection,
            transaction,
            abandoned.Run.RunUid,
            ready.RuntimeProfile.Revision.RevisionUid,
            currentControl.Revision.RevisionUid,
            TestInstant.AddSeconds(17)));
    Assert.Equal(terminalState, await ReadStateAsync(connectionString, abandoned.Run.RunUid));
    await AssertCustomRejectedAsync(
        connectionString,
        "challenge_run_execution_profile_not_ready",
        (connection, transaction) => InsertStaleExecutionProfileRunAsync(
            connection,
            transaction,
            abandoned.Run.RunUid,
            currentRuntime.Revision.RevisionUid,
            ready.ControlProfile.Revision.RevisionUid,
            TestInstant.AddSeconds(18)));
    Assert.Equal(terminalState, await ReadStateAsync(connectionString, abandoned.Run.RunUid));

    var replacementPolicy = PrivateServerDomain.ChallengeOperationalPolicy.CreateConfiguredV1(
        EntityUid.New(),
        "challenge-operational-policy/run-invariant-replacement/v1",
        dailyEntryLimit: 4,
        PrivateServerDomain.ChallengeEntryConsumptionPoint.FirstTeamEntered,
        PrivateServerDomain.ActiveRunAtResetPolicy.PinOpeningRaidDay,
        PrivateServerDomain.DailyCounterScope.PerSeason,
        PrivateServerDomain.MockBattleCapability.Unsupported,
        PrivateServerDomain.LocalRankingCapability.LocalRecordsOnly);
    _ = await service.PublishChallengeOperationalPolicyAsync(
        new App.PublishChallengeOperationalPolicyCommand(
            EntityUid.New(),
            replacementPolicy,
            TestInstant.AddSeconds(19)));
    var policyState = await service.GetChallengeOperationalPolicyAsync(
        new App.ChallengePolicyStateQuery(TestInstant.AddSeconds(19)));
    _ = await service.ActivateChallengeOperationalPolicyAsync(
        new App.ActivateChallengeOperationalPolicyCommand(
            EntityUid.New(),
            replacementPolicy.PolicyUid,
            replacementPolicy.ContentSha256,
            PrivateServerDomain.AsiaSeoulRaidDay.GetKey(RaidDayBoundary),
            policyState.Activation.Revision.RevisionUid,
            TestInstant.AddSeconds(20)));
    await AssertCustomRejectedAsync(
        connectionString,
        "challenge_run_context_capability_policy_mismatch",
        (connection, transaction) => InsertStaleContextPolicyRunAsync(
            connection,
            transaction,
            abandoned.Run.RunUid,
            currentRuntime.Revision.RevisionUid,
            currentControl.Revision.RevisionUid,
            RaidDayBoundary.AddSeconds(1)));
    Assert.Equal(terminalState, await ReadStateAsync(connectionString, abandoned.Run.RunUid));
  }

  private static async Task InsertMismatchedPolicyWriteOperationAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      DateTimeOffset completedAtUtc)
  {
    await using var command = new NpgsqlCommand(
        """
        INSERT INTO lab_private_server.private_server_write_operation (
            operation_uid, operation_kind, request_sha256,
            local_account_id, expected_revision_uid,
            result_entity_uid, result_revision_uid,
            result_content_sha256, completed_at_utc
        )
        SELECT @operation_uid, 'publish_operational_policy', @request_sha256,
               NULL, NULL, policy.challenge_operational_policy_uid, NULL,
               @mismatched_content_sha256, @completed_at_utc
          FROM lab_private_server.challenge_operational_policy policy
         ORDER BY policy.challenge_operational_policy_id
         LIMIT 1
        """,
        connection,
        transaction);
    command.Parameters.AddWithValue("operation_uid", EntityUid.New().Value);
    command.Parameters.AddWithValue("request_sha256", Hash(97));
    command.Parameters.AddWithValue("mismatched_content_sha256", Hash(98));
    command.Parameters.AddWithValue("completed_at_utc", completedAtUtc);
    Assert.Equal(1, await command.ExecuteNonQueryAsync());
  }

  private static async Task InsertDuplicateApplicationBuildSelectionAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction)
  {
    long insertedRevisionId;
    DateTimeOffset selectedAtUtc;
    await using (var insert = new NpgsqlCommand(
        """
        INSERT INTO lab_private_server.application_build_selection_revision (
            application_build_selection_revision_uid, revision_number,
            previous_application_build_selection_revision_id,
            application_build_id, application_build_sha256,
            content_sha256, selected_at_utc
        )
        SELECT @revision_uid, current.revision_number + 1,
               current.application_build_selection_revision_id,
               current.application_build_id,
               current.application_build_sha256,
               @content_sha256, current.selected_at_utc
          FROM lab_private_server.application_build_state state
          JOIN lab_private_server.application_build_selection_revision current
            ON current.application_build_selection_revision_id =
               state.current_application_build_selection_revision_id
         WHERE state.singleton
        RETURNING application_build_selection_revision_id, selected_at_utc
        """,
        connection,
        transaction))
    {
      insert.Parameters.AddWithValue("revision_uid", EntityUid.New().Value);
      insert.Parameters.AddWithValue("content_sha256", Hash(95));
      await using var reader = await insert.ExecuteReaderAsync();
      Assert.True(await reader.ReadAsync());
      insertedRevisionId = reader.GetInt64(0);
      selectedAtUtc = reader.GetFieldValue<DateTimeOffset>(1);
      Assert.False(await reader.ReadAsync());
    }

    await using var update = new NpgsqlCommand(
        """
        UPDATE lab_private_server.application_build_state
           SET current_application_build_selection_revision_id = @revision_id,
               updated_at_utc = @selected_at_utc
         WHERE singleton
        """,
        connection,
        transaction);
    update.Parameters.AddWithValue("revision_id", insertedRevisionId);
    update.Parameters.AddWithValue("selected_at_utc", selectedAtUtc);
    Assert.Equal(1, await update.ExecuteNonQueryAsync());
  }

  private static async Task InsertRepeatedLobbyRevisionAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid contextUid,
      DateTimeOffset observedAtUtc)
  {
    await using var command = new NpgsqlCommand(
        """
        INSERT INTO lab_private_server.local_client_context_revision (
            local_client_context_revision_uid, local_client_context_id,
            local_session_id, local_account_id, revision_number,
            previous_local_client_context_revision_id,
            private_server_boot_revision_id,
            private_server_boot_content_sha256,
            capability_manifest_id, capability_manifest_content_sha256,
            application_build_id, application_build_sha256,
            application_contract_id, issued_at_utc, expires_at_utc,
            stage, connected_at_utc, lobby_ready_at_utc,
            account_revision_set_sha256, account_state_revision_id,
            profile_template_revision_id, lobby_presentation_revision_id,
            wallet_revision_id, client_feature_manifest_id,
            client_feature_manifest_uid,
            client_feature_manifest_content_sha256,
            squad_revision_id, squad_revision_uid,
            squad_revision_content_sha256,
            selected_raid_season_revision_id,
            selected_season_content_sha256, closed_at_utc,
            content_sha256, materialized_at_utc
        )
        SELECT @revision_uid, current.local_client_context_id,
               current.local_session_id, current.local_account_id,
               current.revision_number + 1,
               current.local_client_context_revision_id,
               current.private_server_boot_revision_id,
               current.private_server_boot_content_sha256,
               current.capability_manifest_id,
               current.capability_manifest_content_sha256,
               current.application_build_id,
               current.application_build_sha256,
               current.application_contract_id,
               current.issued_at_utc, current.expires_at_utc,
               'lobby_ready', current.connected_at_utc,
               current.lobby_ready_at_utc,
               current.account_revision_set_sha256,
               current.account_state_revision_id,
               current.profile_template_revision_id,
               current.lobby_presentation_revision_id,
               current.wallet_revision_id,
               current.client_feature_manifest_id,
               current.client_feature_manifest_uid,
               current.client_feature_manifest_content_sha256,
               current.squad_revision_id, current.squad_revision_uid,
               current.squad_revision_content_sha256,
               current.selected_raid_season_revision_id,
               current.selected_season_content_sha256,
               NULL, @content_sha256, @observed_at_utc
          FROM lab_private_server.local_client_context context
          JOIN lab_private_server.local_client_context_revision current
            ON current.local_client_context_revision_id =
               context.current_local_client_context_revision_id
         WHERE context.local_client_context_uid = @context_uid
        """,
        connection,
        transaction);
    command.Parameters.AddWithValue("revision_uid", EntityUid.New().Value);
    command.Parameters.AddWithValue("content_sha256", Hash(96));
    command.Parameters.AddWithValue("observed_at_utc", observedAtUtc);
    command.Parameters.AddWithValue("context_uid", contextUid.Value);
    Assert.Equal(1, await command.ExecuteNonQueryAsync());
  }

  private static async Task InsertSelectionRevisionDuringActiveRunAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid runUid,
      DateTimeOffset observedAtUtc)
  {
    await using var command = new NpgsqlCommand(
        """
        INSERT INTO lab_private_server.selected_raid_season_revision (
            selected_raid_season_revision_uid, raid_season_selection_id,
            local_client_context_id, local_session_id, local_account_id,
            revision_number, previous_selected_raid_season_revision_id,
            raid_season_directory_id, directory_content_sha256,
            raid_snapshot_id, season_number, raid_snapshot_content_sha256,
            content_sha256, materialized_at_utc
        )
        SELECT @revision_uid, selection.raid_season_selection_id,
               current.local_client_context_id, current.local_session_id,
               current.local_account_id, current.revision_number + 1,
               current.selected_raid_season_revision_id,
               current.raid_season_directory_id,
               current.directory_content_sha256,
               current.raid_snapshot_id, current.season_number,
               current.raid_snapshot_content_sha256,
               @content_sha256, @observed_at_utc
          FROM lab_private_server.challenge_run run
          JOIN lab_private_server.raid_season_selection selection
            ON selection.local_client_context_id = run.local_client_context_id
          JOIN lab_private_server.selected_raid_season_revision current
            ON current.selected_raid_season_revision_id =
               selection.current_selected_raid_season_revision_id
         WHERE run.challenge_run_uid = @run_uid
        """,
        connection,
        transaction);
    command.Parameters.AddWithValue("revision_uid", EntityUid.New().Value);
    command.Parameters.AddWithValue("content_sha256", Hash(1));
    command.Parameters.AddWithValue("observed_at_utc", observedAtUtc);
    command.Parameters.AddWithValue("run_uid", runUid.Value);
    Assert.Equal(1, await command.ExecuteNonQueryAsync());
  }

  private static async Task InsertContextRevisionDuringActiveRunAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid runUid,
      DateTimeOffset observedAtUtc)
  {
    await using var command = new NpgsqlCommand(
        """
        INSERT INTO lab_private_server.local_client_context_revision (
            local_client_context_revision_uid, local_client_context_id,
            local_session_id, local_account_id, revision_number,
            previous_local_client_context_revision_id,
            private_server_boot_revision_id,
            private_server_boot_content_sha256,
            capability_manifest_id, capability_manifest_content_sha256,
            application_build_id, application_build_sha256,
            application_contract_id, issued_at_utc, expires_at_utc,
            stage, connected_at_utc, lobby_ready_at_utc,
            account_revision_set_sha256, account_state_revision_id,
            profile_template_revision_id, lobby_presentation_revision_id,
            wallet_revision_id, client_feature_manifest_id,
            client_feature_manifest_uid,
            client_feature_manifest_content_sha256,
            squad_revision_id, squad_revision_uid,
            squad_revision_content_sha256,
            selected_raid_season_revision_id,
            selected_season_content_sha256, closed_at_utc,
            content_sha256, materialized_at_utc
        )
        SELECT @revision_uid, current.local_client_context_id,
               current.local_session_id, current.local_account_id,
               current.revision_number + 1,
               current.local_client_context_revision_id,
               current.private_server_boot_revision_id,
               current.private_server_boot_content_sha256,
               current.capability_manifest_id,
               current.capability_manifest_content_sha256,
               current.application_build_id,
               current.application_build_sha256,
               current.application_contract_id,
               current.issued_at_utc, current.expires_at_utc,
               'closed', current.connected_at_utc,
               current.lobby_ready_at_utc,
               current.account_revision_set_sha256,
               current.account_state_revision_id,
               current.profile_template_revision_id,
               current.lobby_presentation_revision_id,
               current.wallet_revision_id,
               current.client_feature_manifest_id,
               current.client_feature_manifest_uid,
               current.client_feature_manifest_content_sha256,
               current.squad_revision_id, current.squad_revision_uid,
               current.squad_revision_content_sha256,
               current.selected_raid_season_revision_id,
               current.selected_season_content_sha256,
               @observed_at_utc, @content_sha256, @observed_at_utc
          FROM lab_private_server.challenge_run run
          JOIN lab_private_server.local_client_context context
            ON context.local_client_context_id = run.local_client_context_id
          JOIN lab_private_server.local_client_context_revision current
            ON current.local_client_context_revision_id =
               context.current_local_client_context_revision_id
         WHERE run.challenge_run_uid = @run_uid
        """,
        connection,
        transaction);
    command.Parameters.AddWithValue("revision_uid", EntityUid.New().Value);
    command.Parameters.AddWithValue("content_sha256", Hash(2));
    command.Parameters.AddWithValue("observed_at_utc", observedAtUtc);
    command.Parameters.AddWithValue("run_uid", runUid.Value);
    Assert.Equal(1, await command.ExecuteNonQueryAsync());
  }

  private static async Task RewriteEnterOperationOrdinalAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid runUid)
  {
    await using (var disable = new NpgsqlCommand(
        """
        ALTER TABLE lab_private_server.challenge_run_operation
            DISABLE TRIGGER trg_reject_immutable_mutation
        """,
        connection,
        transaction))
    {
      _ = await disable.ExecuteNonQueryAsync();
    }

    await using var update = new NpgsqlCommand(
        """
        UPDATE lab_private_server.challenge_run_operation
           SET team_ordinal = 2
         WHERE challenge_run_uid = @run_uid
           AND operation_kind = 'enter_team'
        """,
        connection,
        transaction);
    update.Parameters.AddWithValue("run_uid", runUid.Value);
    Assert.Equal(1, await update.ExecuteNonQueryAsync());
  }

  private static async Task ReplayOrdinaryOperationWithRevokedOwnerAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid runUid,
      DateTimeOffset revokedAtUtc)
  {
    await using (var revoke = new NpgsqlCommand(
        """
        UPDATE lab_profile.local_session session
           SET revoked_at_utc = @revoked_at_utc
          FROM lab_private_server.local_client_context context,
               lab_private_server.challenge_run run
         WHERE run.challenge_run_uid = @run_uid
           AND context.local_client_context_id = run.local_client_context_id
           AND session.local_session_id = context.local_session_id
        """,
        connection,
        transaction))
    {
      revoke.Parameters.AddWithValue("revoked_at_utc", revokedAtUtc);
      revoke.Parameters.AddWithValue("run_uid", runUid.Value);
      Assert.Equal(1, await revoke.ExecuteNonQueryAsync());
    }

    await using (var disable = new NpgsqlCommand(
        """
        ALTER TABLE lab_private_server.challenge_run_operation
            DISABLE TRIGGER trg_reject_immutable_mutation
        """,
        connection,
        transaction))
    {
      _ = await disable.ExecuteNonQueryAsync();
    }

    await using var touch = new NpgsqlCommand(
        """
        UPDATE lab_private_server.challenge_run_operation
           SET request_sha256 = request_sha256
         WHERE challenge_run_uid = @run_uid
           AND operation_kind = 'enter_team'
        """,
        connection,
        transaction);
    touch.Parameters.AddWithValue("run_uid", runUid.Value);
    Assert.Equal(1, await touch.ExecuteNonQueryAsync());
  }

  private static async Task InsertOrphanRunRevisionAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid runUid,
      DateTimeOffset observedAtUtc)
  {
    await using var command = new NpgsqlCommand(
        """
        INSERT INTO lab_private_server.challenge_run_revision (
            challenge_run_revision_uid, challenge_run_id, challenge_run_uid,
            local_account_id, revision_number,
            previous_challenge_run_revision_id, status,
            next_team_ordinal, active_team_ordinal, accepted_team_count,
            canonical_cumulative_damage, cumulative_damage,
            final_result_uid, abandonment_uid, abandon_reason_code,
            opened_at_utc, updated_at_utc, content_sha256
        )
        SELECT @revision_uid, run.challenge_run_id, run.challenge_run_uid,
               run.local_account_id, current.revision_number + 1,
               current.challenge_run_revision_id, 'abandoned',
               NULL, NULL, current.accepted_team_count,
               current.canonical_cumulative_damage, current.cumulative_damage,
               NULL, @abandonment_uid, 'orphan_revision_probe',
               current.opened_at_utc, @observed_at_utc, @content_sha256
          FROM lab_private_server.challenge_run run
          JOIN lab_private_server.challenge_run_revision current
            ON current.challenge_run_revision_id =
               run.current_challenge_run_revision_id
         WHERE run.challenge_run_uid = @run_uid
        """,
        connection,
        transaction);
    command.Parameters.AddWithValue("revision_uid", EntityUid.New().Value);
    command.Parameters.AddWithValue("abandonment_uid", EntityUid.New().Value);
    command.Parameters.AddWithValue("observed_at_utc", observedAtUtc);
    command.Parameters.AddWithValue("content_sha256", Hash(11));
    command.Parameters.AddWithValue("run_uid", runUid.Value);
    Assert.Equal(1, await command.ExecuteNonQueryAsync());
  }

  private static async Task InsertIntermediateRunRevisionWithoutOperationAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid runUid,
      DateTimeOffset observedAtUtc)
  {
    long runId;
    long currentRevisionId;
    int currentStateVersion;
    DateTimeOffset openedAtUtc;
    byte[] teamContentSha256;
    await using (var read = new NpgsqlCommand(
        """
        SELECT run.challenge_run_id,
               current.challenge_run_revision_id,
               current.revision_number, current.opened_at_utc,
               team.team_content_sha256
          FROM lab_private_server.challenge_run run
          JOIN lab_private_server.challenge_run_revision current
            ON current.challenge_run_revision_id =
               run.current_challenge_run_revision_id
          JOIN lab_private_server.challenge_run_team team
            ON team.challenge_run_id = run.challenge_run_id
           AND team.team_ordinal = 1
         WHERE run.challenge_run_uid = @run_uid
        """,
        connection,
        transaction))
    {
      read.Parameters.AddWithValue("run_uid", runUid.Value);
      await using var reader = await read.ExecuteReaderAsync();
      Assert.True(await reader.ReadAsync());
      runId = reader.GetInt64(0);
      currentRevisionId = reader.GetInt64(1);
      currentStateVersion = reader.GetInt32(2);
      openedAtUtc = reader.GetFieldValue<DateTimeOffset>(3);
      teamContentSha256 = reader.GetFieldValue<byte[]>(4);
      Assert.False(await reader.ReadAsync());
    }

    var intermediateRevisionUid = EntityUid.New();
    var intermediateContentSha256 = Hash(13);
    var intermediateStateVersion = checked(currentStateVersion + 1);
    long intermediateRevisionId;
    await using (var insertRevision = new NpgsqlCommand(
        """
        INSERT INTO lab_private_server.challenge_run_revision (
            challenge_run_revision_uid, challenge_run_id, challenge_run_uid,
            local_account_id, revision_number,
            previous_challenge_run_revision_id, status,
            next_team_ordinal, active_team_ordinal, accepted_team_count,
            canonical_cumulative_damage, cumulative_damage,
            final_result_uid, abandonment_uid, abandon_reason_code,
            opened_at_utc, updated_at_utc, content_sha256
        )
        SELECT @revision_uid, run.challenge_run_id, run.challenge_run_uid,
               run.local_account_id, @revision_number,
               @previous_revision_id, 'team_in_progress',
               1, 1, 0, '0', 0, NULL, NULL, NULL,
               @opened_at_utc, @updated_at_utc, @content_sha256
          FROM lab_private_server.challenge_run run
         WHERE run.challenge_run_id = @run_id
        RETURNING challenge_run_revision_id
        """,
        connection,
        transaction))
    {
      insertRevision.Parameters.AddWithValue(
          "revision_uid",
          intermediateRevisionUid.Value);
      insertRevision.Parameters.AddWithValue("revision_number", intermediateStateVersion);
      insertRevision.Parameters.AddWithValue("previous_revision_id", currentRevisionId);
      insertRevision.Parameters.AddWithValue("opened_at_utc", openedAtUtc);
      insertRevision.Parameters.AddWithValue("updated_at_utc", observedAtUtc);
      insertRevision.Parameters.AddWithValue(
          "content_sha256",
          intermediateContentSha256);
      insertRevision.Parameters.AddWithValue("run_id", runId);
      intermediateRevisionId = Convert.ToInt64(
          await insertRevision.ExecuteScalarAsync(),
          System.Globalization.CultureInfo.InvariantCulture);
    }

    await using (var insertAttempt = new NpgsqlCommand(
        """
        INSERT INTO lab_private_server.challenge_run_revision_attempt (
            challenge_run_revision_id, challenge_run_id,
            attempt_ordinal, team_ordinal, team_content_sha256,
            entered_at_utc, challenge_team_damage_receipt_id, receipt_sha256
        ) VALUES (
            @revision_id, @run_id, 1, 1, @team_sha256,
            @entered_at_utc, NULL, NULL
        )
        """,
        connection,
        transaction))
    {
      insertAttempt.Parameters.AddWithValue("revision_id", intermediateRevisionId);
      insertAttempt.Parameters.AddWithValue("run_id", runId);
      insertAttempt.Parameters.AddWithValue("team_sha256", teamContentSha256);
      insertAttempt.Parameters.AddWithValue("entered_at_utc", observedAtUtc);
      Assert.Equal(1, await insertAttempt.ExecuteNonQueryAsync());
    }

    await using (var advanceIntermediate = new NpgsqlCommand(
        """
        UPDATE lab_private_server.challenge_run
           SET status = 'team_in_progress', state_version = @state_version,
               next_team_ordinal = 1, active_team_ordinal = 1,
               accepted_team_count = 0,
               canonical_cumulative_damage = '0', cumulative_damage = 0,
               final_result_uid = NULL, abandonment_uid = NULL,
               abandon_reason_code = NULL,
               last_operation_uid = @transient_operation_uid,
               current_challenge_run_revision_id = @revision_id,
               updated_at_utc = @updated_at_utc
         WHERE challenge_run_id = @run_id
        """,
        connection,
        transaction))
    {
      advanceIntermediate.Parameters.AddWithValue("state_version", intermediateStateVersion);
      advanceIntermediate.Parameters.AddWithValue(
          "transient_operation_uid",
          EntityUid.New().Value);
      advanceIntermediate.Parameters.AddWithValue("revision_id", intermediateRevisionId);
      advanceIntermediate.Parameters.AddWithValue("updated_at_utc", observedAtUtc);
      advanceIntermediate.Parameters.AddWithValue("run_id", runId);
      Assert.Equal(1, await advanceIntermediate.ExecuteNonQueryAsync());
    }

    var finalUpdatedAtUtc = observedAtUtc.AddMilliseconds(1);
    var finalRevisionUid = EntityUid.New();
    var finalContentSha256 = Hash(14);
    var finalStateVersion = checked(intermediateStateVersion + 1);
    var abandonmentUid = EntityUid.New();
    const string reasonCode = "intermediate_revision_probe";
    long finalRevisionId;
    await using (var insertFinalRevision = new NpgsqlCommand(
        """
        INSERT INTO lab_private_server.challenge_run_revision (
            challenge_run_revision_uid, challenge_run_id, challenge_run_uid,
            local_account_id, revision_number,
            previous_challenge_run_revision_id, status,
            next_team_ordinal, active_team_ordinal, accepted_team_count,
            canonical_cumulative_damage, cumulative_damage,
            final_result_uid, abandonment_uid, abandon_reason_code,
            opened_at_utc, updated_at_utc, content_sha256
        )
        SELECT @revision_uid, run.challenge_run_id, run.challenge_run_uid,
               run.local_account_id, @revision_number,
               @previous_revision_id, 'abandoned',
               NULL, NULL, 0, '0', 0, NULL,
               @abandonment_uid, @reason_code,
               @opened_at_utc, @updated_at_utc, @content_sha256
          FROM lab_private_server.challenge_run run
         WHERE run.challenge_run_id = @run_id
        RETURNING challenge_run_revision_id
        """,
        connection,
        transaction))
    {
      insertFinalRevision.Parameters.AddWithValue("revision_uid", finalRevisionUid.Value);
      insertFinalRevision.Parameters.AddWithValue("revision_number", finalStateVersion);
      insertFinalRevision.Parameters.AddWithValue(
          "previous_revision_id",
          intermediateRevisionId);
      insertFinalRevision.Parameters.AddWithValue("abandonment_uid", abandonmentUid.Value);
      insertFinalRevision.Parameters.AddWithValue("reason_code", reasonCode);
      insertFinalRevision.Parameters.AddWithValue("opened_at_utc", openedAtUtc);
      insertFinalRevision.Parameters.AddWithValue("updated_at_utc", finalUpdatedAtUtc);
      insertFinalRevision.Parameters.AddWithValue("content_sha256", finalContentSha256);
      insertFinalRevision.Parameters.AddWithValue("run_id", runId);
      finalRevisionId = Convert.ToInt64(
          await insertFinalRevision.ExecuteScalarAsync(),
          System.Globalization.CultureInfo.InvariantCulture);
    }

    await using (var insertFinalAttempt = new NpgsqlCommand(
        """
        INSERT INTO lab_private_server.challenge_run_revision_attempt (
            challenge_run_revision_id, challenge_run_id,
            attempt_ordinal, team_ordinal, team_content_sha256,
            entered_at_utc, challenge_team_damage_receipt_id, receipt_sha256
        ) VALUES (
            @revision_id, @run_id, 1, 1, @team_sha256,
            @entered_at_utc, NULL, NULL
        )
        """,
        connection,
        transaction))
    {
      insertFinalAttempt.Parameters.AddWithValue("revision_id", finalRevisionId);
      insertFinalAttempt.Parameters.AddWithValue("run_id", runId);
      insertFinalAttempt.Parameters.AddWithValue("team_sha256", teamContentSha256);
      insertFinalAttempt.Parameters.AddWithValue("entered_at_utc", observedAtUtc);
      Assert.Equal(1, await insertFinalAttempt.ExecuteNonQueryAsync());
    }

    var operationUid = EntityUid.New();
    await using (var insertOperation = new NpgsqlCommand(
        """
        INSERT INTO lab_private_server.challenge_run_operation (
            operation_uid, operation_kind, request_sha256,
            challenge_run_uid, expected_run_revision_uid,
            expected_state_version, result_challenge_run_revision_id,
            result_run_revision_uid, result_run_content_sha256,
            result_state_version, result_status, team_ordinal,
            challenge_team_damage_receipt_id, challenge_run_result_id,
            consumed_daily_attempt, result_daily_state_revision_id,
            abandonment_uid, abandon_reason_code,
            requesting_local_account_id,
            requesting_local_client_context_revision_id,
            completed_at_utc
        ) VALUES (
            @operation_uid, 'abandon_run', @request_sha256,
            @run_uid, @expected_revision_uid, @expected_state_version,
            @result_revision_id, @result_revision_uid,
            @result_content_sha256, @result_state_version, 'abandoned',
            NULL, NULL, NULL, FALSE, NULL,
            @abandonment_uid, @reason_code, NULL, NULL,
            @completed_at_utc
        )
        """,
        connection,
        transaction))
    {
      insertOperation.Parameters.AddWithValue("operation_uid", operationUid.Value);
      insertOperation.Parameters.AddWithValue("request_sha256", Hash(15));
      insertOperation.Parameters.AddWithValue("run_uid", runUid.Value);
      insertOperation.Parameters.AddWithValue(
          "expected_revision_uid",
          intermediateRevisionUid.Value);
      insertOperation.Parameters.AddWithValue(
          "expected_state_version",
          intermediateStateVersion);
      insertOperation.Parameters.AddWithValue("result_revision_id", finalRevisionId);
      insertOperation.Parameters.AddWithValue("result_revision_uid", finalRevisionUid.Value);
      insertOperation.Parameters.AddWithValue("result_content_sha256", finalContentSha256);
      insertOperation.Parameters.AddWithValue("result_state_version", finalStateVersion);
      insertOperation.Parameters.AddWithValue("abandonment_uid", abandonmentUid.Value);
      insertOperation.Parameters.AddWithValue("reason_code", reasonCode);
      insertOperation.Parameters.AddWithValue("completed_at_utc", finalUpdatedAtUtc);
      Assert.Equal(1, await insertOperation.ExecuteNonQueryAsync());
    }

    await using var advanceFinal = new NpgsqlCommand(
        """
        UPDATE lab_private_server.challenge_run
           SET status = 'abandoned', state_version = @state_version,
               next_team_ordinal = NULL, active_team_ordinal = NULL,
               accepted_team_count = 0,
               canonical_cumulative_damage = '0', cumulative_damage = 0,
               final_result_uid = NULL,
               abandonment_uid = @abandonment_uid,
               abandon_reason_code = @reason_code,
               last_operation_uid = @operation_uid,
               current_challenge_run_revision_id = @revision_id,
               updated_at_utc = @updated_at_utc
         WHERE challenge_run_id = @run_id
        """,
        connection,
        transaction);
    advanceFinal.Parameters.AddWithValue("state_version", finalStateVersion);
    advanceFinal.Parameters.AddWithValue("abandonment_uid", abandonmentUid.Value);
    advanceFinal.Parameters.AddWithValue("reason_code", reasonCode);
    advanceFinal.Parameters.AddWithValue("operation_uid", operationUid.Value);
    advanceFinal.Parameters.AddWithValue("revision_id", finalRevisionId);
    advanceFinal.Parameters.AddWithValue("updated_at_utc", finalUpdatedAtUtc);
    advanceFinal.Parameters.AddWithValue("run_id", runId);
    Assert.Equal(1, await advanceFinal.ExecuteNonQueryAsync());
  }

  private static async Task InsertArbitraryDailyConsumptionAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid runUid,
      DateTimeOffset observedAtUtc)
  {
    await using var insert = new NpgsqlCommand(
        """
        INSERT INTO lab_private_server.challenge_daily_state_revision (
            challenge_daily_state_revision_uid, challenge_daily_state_id,
            local_account_id, challenge_operational_policy_id,
            raid_season_directory_id, raid_day_key, counter_scope,
            raid_snapshot_id, revision_number,
            previous_challenge_daily_state_revision_id,
            consumed_entries, consumption_operation_uid,
            content_sha256, materialized_at_utc
        )
        SELECT @revision_uid, state.challenge_daily_state_id,
               state.local_account_id, state.challenge_operational_policy_id,
               state.raid_season_directory_id, state.raid_day_key,
               state.counter_scope, state.raid_snapshot_id,
               current.revision_number + 1,
               current.challenge_daily_state_revision_id,
               current.consumed_entries + 1, open_operation.operation_uid,
               @content_sha256, @observed_at_utc
          FROM lab_private_server.challenge_run run
          JOIN lab_private_server.challenge_daily_state state
            ON state.challenge_daily_state_id = run.challenge_daily_state_id
          JOIN lab_private_server.challenge_daily_state_revision current
            ON current.challenge_daily_state_revision_id =
               state.current_challenge_daily_state_revision_id
          JOIN lab_private_server.challenge_run_operation open_operation
            ON open_operation.challenge_run_uid = run.challenge_run_uid
           AND open_operation.operation_kind = 'open_run'
         WHERE run.challenge_run_uid = @run_uid
        RETURNING challenge_daily_state_revision_id, challenge_daily_state_id
        """,
        connection,
        transaction);
    insert.Parameters.AddWithValue("revision_uid", EntityUid.New().Value);
    insert.Parameters.AddWithValue("content_sha256", Hash(12));
    insert.Parameters.AddWithValue("observed_at_utc", observedAtUtc);
    insert.Parameters.AddWithValue("run_uid", runUid.Value);
    long revisionId;
    long stateId;
    await using (var reader = await insert.ExecuteReaderAsync())
    {
      Assert.True(await reader.ReadAsync());
      revisionId = reader.GetInt64(0);
      stateId = reader.GetInt64(1);
    }

    await using var update = new NpgsqlCommand(
        """
        UPDATE lab_private_server.challenge_daily_state
           SET current_challenge_daily_state_revision_id = @revision_id
         WHERE challenge_daily_state_id = @state_id
        """,
        connection,
        transaction);
    update.Parameters.AddWithValue("revision_id", revisionId);
    update.Parameters.AddWithValue("state_id", stateId);
    Assert.Equal(1, await update.ExecuteNonQueryAsync());
  }

  private static async Task InsertOrphanReceiptGraphAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid runUid,
      DateTimeOffset observedAtUtc)
  {
    var receiptId = await InsertReceiptAsync(
        connection,
        transaction,
        runUid,
        observedAtUtc,
        receiptSha256: Hash(21),
        telemetrySha256: Hash(22));
    await InsertExecutionSegmentAsync(
        connection,
        transaction,
        runUid,
        receiptId,
        runtimeRevisionUid: null,
        controlRevisionUid: null);
  }

  private static async Task<long> InsertReceiptAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid runUid,
      DateTimeOffset observedAtUtc,
      byte[] receiptSha256,
      byte[] telemetrySha256)
  {
    await using var command = new NpgsqlCommand(
        """
        INSERT INTO lab_private_server.challenge_team_damage_receipt (
            challenge_team_damage_receipt_uid, challenge_run_id,
            team_ordinal, local_account_id, observation_source,
            canonical_damage, damage_value,
            canonical_cumulative_damage, cumulative_damage_value,
            telemetry_contract_id, telemetry_sha256,
            render_frame_count, behavior_tick_count, fixed_update_count,
            wall_clock_microseconds,
            frame_time_median_milliseconds,
            frame_time_p95_milliseconds, frame_time_p99_milliseconds,
            dropped_frame_count, stalled_frame_count,
            telemetry_warning_count, segment_count, warning_count,
            receipt_sha256, observed_at_utc
        )
        SELECT @receipt_uid, run.challenge_run_id, 1, run.local_account_id,
               'lab_harness_observation/v1',
               '7', 7, '7', 7,
               'nll/battle-frame-telemetry/v1', @telemetry_sha256,
               1, 1, 1, 1, 1.000, 1.000, 1.000,
               0, 0, 0, 1, 0, @receipt_sha256, @observed_at_utc
          FROM lab_private_server.challenge_run run
         WHERE run.challenge_run_uid = @run_uid
        RETURNING challenge_team_damage_receipt_id
        """,
        connection,
        transaction);
    command.Parameters.AddWithValue("receipt_uid", EntityUid.New().Value);
    command.Parameters.AddWithValue("telemetry_sha256", telemetrySha256);
    command.Parameters.AddWithValue("receipt_sha256", receiptSha256);
    command.Parameters.AddWithValue("observed_at_utc", observedAtUtc);
    command.Parameters.AddWithValue("run_uid", runUid.Value);
    return Convert.ToInt64(
        await command.ExecuteScalarAsync(),
        System.Globalization.CultureInfo.InvariantCulture);
  }

  private static async Task InsertExecutionSegmentAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid runUid,
      long receiptId,
      EntityUid? runtimeRevisionUid,
      EntityUid? controlRevisionUid)
  {
    await using var command = new NpgsqlCommand(
        """
        INSERT INTO lab_private_server.challenge_execution_segment (
            challenge_team_damage_receipt_id, challenge_run_id,
            team_ordinal, local_account_id, segment_ordinal,
            runtime_execution_profile_revision_id,
            combat_control_profile_revision_id,
            start_render_frame, end_render_frame,
            start_behavior_tick, end_behavior_tick,
            start_fixed_update, end_fixed_update,
            start_wall_clock_microseconds, end_wall_clock_microseconds,
            canonical_start_damage, start_damage,
            canonical_end_damage, end_damage
        )
        SELECT @receipt_id, run.challenge_run_id, 1, run.local_account_id, 1,
               COALESCE(runtime_revision.runtime_execution_profile_revision_id,
                        run.runtime_execution_profile_revision_id),
               COALESCE(control_revision.combat_control_profile_revision_id,
                        run.combat_control_profile_revision_id),
               0, 1, 0, 1, 0, 1, 0, 1, '0', 0, '7', 7
          FROM lab_private_server.challenge_run run
          LEFT JOIN lab_private_server.runtime_execution_profile_revision runtime_revision
            ON runtime_revision.runtime_execution_profile_revision_uid = @runtime_revision_uid
          LEFT JOIN lab_private_server.combat_control_profile_revision control_revision
            ON control_revision.combat_control_profile_revision_uid = @control_revision_uid
         WHERE run.challenge_run_uid = @run_uid
        """,
        connection,
        transaction);
    command.Parameters.AddWithValue("receipt_id", receiptId);
    command.Parameters.AddWithValue(
        "runtime_revision_uid",
        (object?)runtimeRevisionUid?.Value ?? DBNull.Value);
    command.Parameters.AddWithValue(
        "control_revision_uid",
        (object?)controlRevisionUid?.Value ?? DBNull.Value);
    command.Parameters.AddWithValue("run_uid", runUid.Value);
    Assert.Equal(1, await command.ExecuteNonQueryAsync());
  }

  private static async Task InsertMismatchedExecutionReceiptAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid runUid,
      EntityUid runtimeRevisionUid,
      EntityUid controlRevisionUid,
      DateTimeOffset observedAtUtc)
  {
    var receiptSha256 = Hash(31);
    var receiptId = await InsertReceiptAsync(
        connection,
        transaction,
        runUid,
        observedAtUtc,
        receiptSha256,
        Hash(32));
    await InsertExecutionSegmentAsync(
        connection,
        transaction,
        runUid,
        receiptId,
        runtimeRevisionUid,
        controlRevisionUid);

    var revisionUid = EntityUid.New();
    var revisionSha256 = Hash(33);
    long revisionId;
    EntityUid expectedRevisionUid;
    int expectedStateVersion;
    await using (var command = new NpgsqlCommand(
        """
        SELECT current.challenge_run_revision_uid, current.revision_number
          FROM lab_private_server.challenge_run run
          JOIN lab_private_server.challenge_run_revision current
            ON current.challenge_run_revision_id =
               run.current_challenge_run_revision_id
         WHERE run.challenge_run_uid = @run_uid
        """,
        connection,
        transaction))
    {
      command.Parameters.AddWithValue("run_uid", runUid.Value);
      await using var reader = await command.ExecuteReaderAsync();
      Assert.True(await reader.ReadAsync());
      expectedRevisionUid = new EntityUid(reader.GetGuid(0));
      expectedStateVersion = reader.GetInt32(1);
    }

    await using (var command = new NpgsqlCommand(
        """
        INSERT INTO lab_private_server.challenge_run_revision (
            challenge_run_revision_uid, challenge_run_id, challenge_run_uid,
            local_account_id, revision_number,
            previous_challenge_run_revision_id, status,
            next_team_ordinal, active_team_ordinal, accepted_team_count,
            canonical_cumulative_damage, cumulative_damage,
            final_result_uid, abandonment_uid, abandon_reason_code,
            opened_at_utc, updated_at_utc, content_sha256
        )
        SELECT @revision_uid, run.challenge_run_id, run.challenge_run_uid,
               run.local_account_id, current.revision_number + 1,
               current.challenge_run_revision_id, 'team_result_accepted',
               1, 1, 1, '7', 7, NULL, NULL, NULL,
               current.opened_at_utc, @observed_at_utc, @content_sha256
          FROM lab_private_server.challenge_run run
          JOIN lab_private_server.challenge_run_revision current
            ON current.challenge_run_revision_id =
               run.current_challenge_run_revision_id
         WHERE run.challenge_run_uid = @run_uid
        RETURNING challenge_run_revision_id
        """,
        connection,
        transaction))
    {
      command.Parameters.AddWithValue("revision_uid", revisionUid.Value);
      command.Parameters.AddWithValue("observed_at_utc", observedAtUtc);
      command.Parameters.AddWithValue("content_sha256", revisionSha256);
      command.Parameters.AddWithValue("run_uid", runUid.Value);
      await using var reader = await command.ExecuteReaderAsync();
      Assert.True(await reader.ReadAsync());
      revisionId = reader.GetInt64(0);
    }

    await using (var command = new NpgsqlCommand(
        """
        INSERT INTO lab_private_server.challenge_run_revision_attempt (
            challenge_run_revision_id, challenge_run_id,
            attempt_ordinal, team_ordinal, team_content_sha256,
            entered_at_utc, challenge_team_damage_receipt_id, receipt_sha256
        )
        SELECT @revision_id, run.challenge_run_id, 1, 1,
               team.team_content_sha256, prior_attempt.entered_at_utc,
               @receipt_id, @receipt_sha256
          FROM lab_private_server.challenge_run run
          JOIN lab_private_server.challenge_run_team team
            ON team.challenge_run_id = run.challenge_run_id
           AND team.team_ordinal = 1
          JOIN lab_private_server.challenge_run_revision_attempt prior_attempt
            ON prior_attempt.challenge_run_revision_id =
               run.current_challenge_run_revision_id
           AND prior_attempt.team_ordinal = 1
         WHERE run.challenge_run_uid = @run_uid
        """,
        connection,
        transaction))
    {
      command.Parameters.AddWithValue("revision_id", revisionId);
      command.Parameters.AddWithValue("receipt_id", receiptId);
      command.Parameters.AddWithValue("receipt_sha256", receiptSha256);
      command.Parameters.AddWithValue("run_uid", runUid.Value);
      Assert.Equal(1, await command.ExecuteNonQueryAsync());
    }

    var operationUid = EntityUid.New();
    await using (var command = new NpgsqlCommand(
        """
        INSERT INTO lab_private_server.challenge_run_operation (
            operation_uid, operation_kind, request_sha256,
            challenge_run_uid, expected_run_revision_uid,
            expected_state_version, result_challenge_run_revision_id,
            result_run_revision_uid, result_run_content_sha256,
            result_state_version, result_status, team_ordinal,
            challenge_team_damage_receipt_id, challenge_run_result_id,
            consumed_daily_attempt, result_daily_state_revision_id,
            abandonment_uid, abandon_reason_code,
            requesting_local_account_id,
            requesting_local_client_context_revision_id,
            completed_at_utc
        ) VALUES (
            @operation_uid, 'accept_team_damage', @request_sha256,
            @run_uid, @expected_revision_uid, @expected_state_version,
            @result_revision_id, @result_revision_uid, @result_sha256,
            @result_state_version, 'team_result_accepted', 1,
            @receipt_id, NULL, FALSE, NULL, NULL, NULL, NULL, NULL,
            @completed_at_utc
        )
        """,
        connection,
        transaction))
    {
      command.Parameters.AddWithValue("operation_uid", operationUid.Value);
      command.Parameters.AddWithValue("request_sha256", Hash(34));
      command.Parameters.AddWithValue("run_uid", runUid.Value);
      command.Parameters.AddWithValue("expected_revision_uid", expectedRevisionUid.Value);
      command.Parameters.AddWithValue("expected_state_version", expectedStateVersion);
      command.Parameters.AddWithValue("result_revision_id", revisionId);
      command.Parameters.AddWithValue("result_revision_uid", revisionUid.Value);
      command.Parameters.AddWithValue("result_sha256", revisionSha256);
      command.Parameters.AddWithValue("result_state_version", expectedStateVersion + 1);
      command.Parameters.AddWithValue("receipt_id", receiptId);
      command.Parameters.AddWithValue("completed_at_utc", observedAtUtc);
      Assert.Equal(1, await command.ExecuteNonQueryAsync());
    }

    await using (var command = new NpgsqlCommand(
        """
        UPDATE lab_private_server.challenge_run
           SET status = 'team_result_accepted', state_version = state_version + 1,
               next_team_ordinal = 1, active_team_ordinal = 1,
               accepted_team_count = 1,
               canonical_cumulative_damage = '7', cumulative_damage = 7,
               final_result_uid = NULL, abandonment_uid = NULL,
               abandon_reason_code = NULL, last_operation_uid = @operation_uid,
               current_challenge_run_revision_id = @revision_id,
               updated_at_utc = @updated_at_utc
         WHERE challenge_run_uid = @run_uid
        """,
        connection,
        transaction))
    {
      command.Parameters.AddWithValue("operation_uid", operationUid.Value);
      command.Parameters.AddWithValue("revision_id", revisionId);
      command.Parameters.AddWithValue("updated_at_utc", observedAtUtc);
      command.Parameters.AddWithValue("run_uid", runUid.Value);
      Assert.Equal(1, await command.ExecuteNonQueryAsync());
    }
  }

  private static async Task InsertOrphanRunResultAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid runUid,
      DateTimeOffset completedAtUtc)
  {
    await using var command = new NpgsqlCommand(
        """
        INSERT INTO lab_private_server.challenge_run_result (
            challenge_run_result_uid, challenge_run_id,
            accepted_team_count, canonical_total_damage, total_damage,
            result_sha256, completed_at_utc
        )
        SELECT @result_uid, run.challenge_run_id,
               run.accepted_team_count, run.canonical_cumulative_damage,
               run.cumulative_damage, @result_sha256, @completed_at_utc
          FROM lab_private_server.challenge_run run
         WHERE run.challenge_run_uid = @run_uid
        """,
        connection,
        transaction);
    command.Parameters.AddWithValue("result_uid", EntityUid.New().Value);
    command.Parameters.AddWithValue("result_sha256", Hash(41));
    command.Parameters.AddWithValue("completed_at_utc", completedAtUtc);
    command.Parameters.AddWithValue("run_uid", runUid.Value);
    Assert.Equal(1, await command.ExecuteNonQueryAsync());
  }

  private static async Task RebindRunMemberToMismatchedProfileAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid runUid,
      EntityUid mismatchedProfileRevisionUid)
  {
    await using var command = new NpgsqlCommand(
        """
        ALTER TABLE lab_private_server.challenge_run_team_member
            DISABLE TRIGGER trg_reject_immutable_mutation;
        UPDATE lab_private_server.challenge_run_team_member member
           SET profile_template_revision_id = profile.profile_template_revision_id
          FROM lab_private_server.challenge_run run,
               lab_profile.profile_template_revision profile
         WHERE member.challenge_run_id = run.challenge_run_id
           AND run.challenge_run_uid = @run_uid
           AND member.position = 2
           AND profile.profile_template_revision_uid = @profile_revision_uid;
        """,
        connection,
        transaction);
    command.Parameters.AddWithValue("run_uid", runUid.Value);
    command.Parameters.AddWithValue("profile_revision_uid", mismatchedProfileRevisionUid.Value);
    Assert.Equal(1, await command.ExecuteNonQueryAsync());
  }

  private static async Task InsertStaleExecutionProfileRunAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid sourceRunUid,
      EntityUid runtimeRevisionUid,
      EntityUid controlRevisionUid,
      DateTimeOffset openedAtUtc)
  {
    await using var command = new NpgsqlCommand(
        """
        INSERT INTO lab_private_server.challenge_run (
            challenge_run_uid, local_account_id,
            local_client_context_id, local_client_context_revision_id,
            selected_raid_season_revision_id, raid_season_directory_id,
            raid_snapshot_id, profile_template_revision_id,
            account_state_revision_id,
            runtime_execution_profile_revision_id,
            combat_control_profile_revision_id,
            challenge_policy_activation_revision_id,
            challenge_operational_policy_id, challenge_daily_state_id,
            admission_daily_state_revision_id,
            admission_daily_state_content_sha256, opening_raid_day_key,
            execution_lane, is_mock_battle, configured_team_count,
            status, state_version, next_team_ordinal, active_team_ordinal,
            accepted_team_count, canonical_cumulative_damage,
            cumulative_damage, final_result_uid, abandonment_uid,
            abandon_reason_code, last_operation_uid, binding_sha256,
            current_challenge_run_revision_id, opened_at_utc, updated_at_utc
        )
        SELECT @new_run_uid, source.local_account_id,
               source.local_client_context_id,
               source.local_client_context_revision_id,
               source.selected_raid_season_revision_id,
               source.raid_season_directory_id, source.raid_snapshot_id,
               source.profile_template_revision_id,
               source.account_state_revision_id,
               runtime_revision.runtime_execution_profile_revision_id,
               control_revision.combat_control_profile_revision_id,
               source.challenge_policy_activation_revision_id,
               source.challenge_operational_policy_id,
               source.challenge_daily_state_id,
               daily.current_challenge_daily_state_revision_id,
               daily_revision.content_sha256,
               lab_private_server.raid_day_key(@opened_at_utc),
               'lab_harness_observation/v1', FALSE,
               source.configured_team_count,
               'open', 1, 1, NULL, 0, '0', 0,
               NULL, NULL, NULL, @operation_uid, @binding_sha256,
               NULL, @opened_at_utc, @opened_at_utc
          FROM lab_private_server.challenge_run source
          JOIN lab_private_server.challenge_daily_state daily
            ON daily.challenge_daily_state_id = source.challenge_daily_state_id
          JOIN lab_private_server.challenge_daily_state_revision daily_revision
            ON daily_revision.challenge_daily_state_revision_id =
               daily.current_challenge_daily_state_revision_id
          JOIN lab_private_server.runtime_execution_profile_revision runtime_revision
            ON runtime_revision.runtime_execution_profile_revision_uid =
               @runtime_revision_uid
          JOIN lab_private_server.combat_control_profile_revision control_revision
            ON control_revision.combat_control_profile_revision_uid =
               @control_revision_uid
         WHERE source.challenge_run_uid = @source_run_uid
        """,
        connection,
        transaction);
    command.Parameters.AddWithValue("new_run_uid", EntityUid.New().Value);
    command.Parameters.AddWithValue("operation_uid", EntityUid.New().Value);
    command.Parameters.AddWithValue("binding_sha256", Hash(51));
    command.Parameters.AddWithValue("opened_at_utc", openedAtUtc);
    command.Parameters.AddWithValue("runtime_revision_uid", runtimeRevisionUid.Value);
    command.Parameters.AddWithValue("control_revision_uid", controlRevisionUid.Value);
    command.Parameters.AddWithValue("source_run_uid", sourceRunUid.Value);
    Assert.Equal(1, await command.ExecuteNonQueryAsync());
  }

  private static async Task InsertStaleContextPolicyRunAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid sourceRunUid,
      EntityUid runtimeRevisionUid,
      EntityUid controlRevisionUid,
      DateTimeOffset openedAtUtc)
  {
    await using var command = new NpgsqlCommand(
        """
        INSERT INTO lab_private_server.challenge_run (
            challenge_run_uid, local_account_id,
            local_client_context_id, local_client_context_revision_id,
            selected_raid_season_revision_id, raid_season_directory_id,
            raid_snapshot_id, profile_template_revision_id,
            account_state_revision_id,
            runtime_execution_profile_revision_id,
            combat_control_profile_revision_id,
            challenge_policy_activation_revision_id,
            challenge_operational_policy_id, challenge_daily_state_id,
            admission_daily_state_revision_id,
            admission_daily_state_content_sha256, opening_raid_day_key,
            execution_lane, is_mock_battle, configured_team_count,
            status, state_version, next_team_ordinal, active_team_ordinal,
            accepted_team_count, canonical_cumulative_damage,
            cumulative_damage, final_result_uid, abandonment_uid,
            abandon_reason_code, last_operation_uid, binding_sha256,
            current_challenge_run_revision_id, opened_at_utc, updated_at_utc
        )
        SELECT @new_run_uid, source.local_account_id,
               source.local_client_context_id,
               source.local_client_context_revision_id,
               source.selected_raid_season_revision_id,
               source.raid_season_directory_id, source.raid_snapshot_id,
               source.profile_template_revision_id,
               source.account_state_revision_id,
               runtime_revision.runtime_execution_profile_revision_id,
               control_revision.combat_control_profile_revision_id,
               active.challenge_policy_activation_revision_id,
               active.challenge_operational_policy_id,
               source.challenge_daily_state_id,
               daily.current_challenge_daily_state_revision_id,
               daily_revision.content_sha256,
               lab_private_server.raid_day_key(@opened_at_utc),
               'lab_harness_observation/v1', FALSE,
               source.configured_team_count,
               'open', 1, 1, NULL, 0, '0', 0,
               NULL, NULL, NULL, @operation_uid, @binding_sha256,
               NULL, @opened_at_utc, @opened_at_utc
          FROM lab_private_server.challenge_run source
          JOIN LATERAL (
              SELECT activation.challenge_policy_activation_revision_id,
                     activation.challenge_operational_policy_id
                FROM lab_private_server.challenge_policy_activation_revision activation
               WHERE activation.effective_raid_day_key <=
                     lab_private_server.raid_day_key(@opened_at_utc)
               ORDER BY activation.effective_raid_day_key DESC,
                        activation.revision_number DESC
               LIMIT 1
          ) active ON TRUE
          JOIN lab_private_server.challenge_daily_state daily
            ON daily.challenge_daily_state_id = source.challenge_daily_state_id
          JOIN lab_private_server.challenge_daily_state_revision daily_revision
            ON daily_revision.challenge_daily_state_revision_id =
               daily.current_challenge_daily_state_revision_id
          JOIN lab_private_server.runtime_execution_profile_revision runtime_revision
            ON runtime_revision.runtime_execution_profile_revision_uid =
               @runtime_revision_uid
          JOIN lab_private_server.combat_control_profile_revision control_revision
            ON control_revision.combat_control_profile_revision_uid =
               @control_revision_uid
         WHERE source.challenge_run_uid = @source_run_uid
        """,
        connection,
        transaction);
    command.Parameters.AddWithValue("new_run_uid", EntityUid.New().Value);
    command.Parameters.AddWithValue("operation_uid", EntityUid.New().Value);
    command.Parameters.AddWithValue("binding_sha256", Hash(52));
    command.Parameters.AddWithValue("opened_at_utc", openedAtUtc);
    command.Parameters.AddWithValue("runtime_revision_uid", runtimeRevisionUid.Value);
    command.Parameters.AddWithValue("control_revision_uid", controlRevisionUid.Value);
    command.Parameters.AddWithValue("source_run_uid", sourceRunUid.Value);
    Assert.Equal(1, await command.ExecuteNonQueryAsync());
  }

  private static async Task AssertCustomRejectedAsync(
      string connectionString,
      string expectedMessage,
      Func<NpgsqlConnection, NpgsqlTransaction, Task> mutation)
  {
    var failure = await AssertRejectedAsync(connectionString, mutation);
    Assert.Equal("P0001", failure.SqlState);
    Assert.Equal(expectedMessage, failure.MessageText);
  }

  private static async Task AssertConstraintRejectedAsync(
      string connectionString,
      string expectedConstraint,
      Func<NpgsqlConnection, NpgsqlTransaction, Task> mutation)
  {
    var failure = await AssertRejectedAsync(connectionString, mutation);
    Assert.Equal(PostgresErrorCodes.ForeignKeyViolation, failure.SqlState);
    Assert.Equal(expectedConstraint, failure.ConstraintName);
  }

  private static async Task<PostgresException> AssertRejectedAsync(
      string connectionString,
      Func<NpgsqlConnection, NpgsqlTransaction, Task> mutation)
  {
    await using var dataSource = PostgreSqlDataSourceFactory.Create(connectionString);
    await using var connection = await dataSource.OpenConnectionAsync();
    await using var transaction = await connection.BeginTransactionAsync();
    return await Assert.ThrowsAsync<PostgresException>(async () =>
    {
      await mutation(connection, transaction);
      await transaction.CommitAsync();
    });
  }

  private static async Task<RunDatabaseState> ReadStateAsync(
      string connectionString,
      EntityUid runUid)
  {
    await using var dataSource = PostgreSqlDataSourceFactory.Create(connectionString);
    await using var command = dataSource.CreateCommand(
        """
        SELECT run.current_challenge_run_revision_id,
               run.state_version, run.status,
               (SELECT count(*)
                  FROM lab_private_server.challenge_run_revision revision
                 WHERE revision.challenge_run_id = run.challenge_run_id),
               (SELECT count(*)
                  FROM lab_private_server.challenge_team_damage_receipt receipt
                 WHERE receipt.challenge_run_id = run.challenge_run_id),
               (SELECT count(*)
                  FROM lab_private_server.challenge_run_result result
                 WHERE result.challenge_run_id = run.challenge_run_id),
               daily.current_challenge_daily_state_revision_id,
               daily_revision.consumed_entries,
               (SELECT count(*)
                  FROM lab_private_server.challenge_run active
                 WHERE active.local_account_id = run.local_account_id
                   AND active.status NOT IN ('completed', 'abandoned'))
          FROM lab_private_server.challenge_run run
          JOIN lab_private_server.challenge_daily_state daily
            ON daily.challenge_daily_state_id = run.challenge_daily_state_id
          JOIN lab_private_server.challenge_daily_state_revision daily_revision
            ON daily_revision.challenge_daily_state_revision_id =
               daily.current_challenge_daily_state_revision_id
         WHERE run.challenge_run_uid = @run_uid
        """);
    command.Parameters.AddWithValue("run_uid", runUid.Value);
    await using var reader = await command.ExecuteReaderAsync();
    Assert.True(await reader.ReadAsync());
    return new RunDatabaseState(
        reader.GetInt64(0),
        reader.GetInt32(1),
        reader.GetString(2),
        reader.GetInt64(3),
        reader.GetInt64(4),
        reader.GetInt64(5),
        reader.GetInt64(6),
        reader.GetInt32(7),
        reader.GetInt64(8));
  }

  private static async Task<long> ReadWriteOperationCountAsync(string connectionString)
  {
    await using var dataSource = PostgreSqlDataSourceFactory.Create(connectionString);
    await using var command = dataSource.CreateCommand(
        "SELECT count(*) FROM lab_private_server.private_server_write_operation");
    return Convert.ToInt64(
        await command.ExecuteScalarAsync(),
        System.Globalization.CultureInfo.InvariantCulture);
  }

  private static async Task<ApplicationBuildSelectionState>
      ReadApplicationBuildSelectionStateAsync(string connectionString)
  {
    await using var dataSource = PostgreSqlDataSourceFactory.Create(connectionString);
    await using var command = dataSource.CreateCommand(
        """
        SELECT state.current_application_build_selection_revision_id,
               (SELECT count(*)
                  FROM lab_private_server.application_build_selection_revision)
          FROM lab_private_server.application_build_state state
         WHERE state.singleton
        """);
    await using var reader = await command.ExecuteReaderAsync();
    Assert.True(await reader.ReadAsync());
    var result = new ApplicationBuildSelectionState(
        reader.GetInt64(0),
        reader.GetInt64(1));
    Assert.False(await reader.ReadAsync());
    return result;
  }

  private static async Task<ClientContextState> ReadContextStateAsync(
      string connectionString,
      EntityUid contextUid)
  {
    await using var dataSource = PostgreSqlDataSourceFactory.Create(connectionString);
    await using var command = dataSource.CreateCommand(
        """
        SELECT context.current_local_client_context_revision_id,
               (SELECT count(*)
                  FROM lab_private_server.local_client_context_revision revision
                 WHERE revision.local_client_context_id =
                       context.local_client_context_id)
          FROM lab_private_server.local_client_context context
         WHERE context.local_client_context_uid = @context_uid
        """);
    command.Parameters.AddWithValue("context_uid", contextUid.Value);
    await using var reader = await command.ExecuteReaderAsync();
    Assert.True(await reader.ReadAsync());
    var result = new ClientContextState(
        reader.GetInt64(0),
        reader.GetInt64(1));
    Assert.False(await reader.ReadAsync());
    return result;
  }

  private static async Task PublishSixSeasonRaidCatalogAsync(NpgsqlDataSource dataSource)
  {
    var testType = typeof(PostgreSqlRaidSnapshotTests);
    var artifact = (RaidEvidenceArtifactPublication)testType.GetMethod(
        "Artifact",
        BindingFlags.NonPublic | BindingFlags.Static)!.Invoke(
            null,
            ["phase2b-run-invariant-static-data"])!;
    var publication = (RaidCatalogPublication)testType.GetMethod(
        "CreateStaticPublication",
        BindingFlags.NonPublic | BindingFlags.Static)!.Invoke(
            null,
            [artifact, "phase2b_higher_tier_evidence_unresolved"])!;
    var attempt = (CompletedImportAttempt)testType.GetMethod(
        "CreateAttempt",
        BindingFlags.NonPublic | BindingFlags.Static)!.Invoke(
            null,
            [publication, new[] { artifact }, "phase2b-run-invariant", null, null])!;
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
        5);
    var characterUids = Property<IReadOnlyList<EntityUid>>(
        sourceFixture,
        "CharacterUids");
    var profile = CreateSyntheticProfile(sourceFixture, firstCharacterLevel: null);
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
            "Invariant Lab",
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
        sourceFixture);
  }

  private static LocalAccountProfileWrite CreateSyntheticProfile(
      object sourceFixture,
      int? firstCharacterLevel)
  {
    var sourceCatalogFixture = Property<object>(sourceFixture, "SourceCatalogFixture");
    var sourceSupportSelections = Property<object>(sourceFixture, "SourceSupportSelections");
    var method = typeof(PostgreSqlLocalAccountProfileTests).GetMethod(
        "CreateProfile",
        BindingFlags.NonPublic | BindingFlags.Static)!;
    return (LocalAccountProfileWrite)method.Invoke(
        null,
        [
          sourceCatalogFixture,
          sourceSupportSelections,
          200,
          firstCharacterLevel,
          false
        ])!;
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

  private static PrivateServerDomain.RuntimeExecutionProfileContent ReadyRuntimeContent(
      int width = 1920)
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
            PrivateServerDomain.ExecutionFact<int>.Ready(width),
            PrivateServerDomain.ExecutionFact<int>.Ready(1080),
            PrivateServerDomain.ExecutionFact<decimal>.Ready(60m)),
        new PrivateServerDomain.RuntimeGraphicsSettings(graphics));
    return new PrivateServerDomain.RuntimeExecutionProfileContent(
        PrivateServerDomain.OriginalClientRuntimeBuildBinding.Unresolved(),
        settings,
        null);
  }

  private static PrivateServerDomain.CombatControlProfileContent ReadyControlContent(
      decimal aimSensitivity = 1m) => new(
      new PrivateServerDomain.CombatControlSettingsSnapshot(
          PrivateServerDomain.ExecutionFact<decimal>.Ready(aimSensitivity),
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

  private static byte[] Hash(byte value) => Enumerable.Repeat(value, 32).ToArray();

  private sealed class ManualTimeProvider(DateTimeOffset value) : TimeProvider
  {
    public override DateTimeOffset GetUtcNow() => value;
  }

  private sealed record AccountFixture(
      EntityUid AccountUid,
      EntityUid ProfileRevisionUid,
      object SourceFixture);

  private sealed record ReadyChallengeFixture(
      App.RuntimeExecutionProfileProjection RuntimeProfile,
      App.CombatControlProfileProjection ControlProfile,
      App.LobbyBootstrapProjection Lobby,
      App.SoloRaidStateProjection Solo);

  private sealed record RunDatabaseState(
      long CurrentRunRevisionId,
      int StateVersion,
      string Status,
      long RunRevisionCount,
      long ReceiptCount,
      long ResultCount,
      long CurrentDailyRevisionId,
      int ConsumedEntries,
      long ActiveRunCount);

  private sealed record ApplicationBuildSelectionState(
      long CurrentRevisionId,
      long RevisionCount);

  private sealed record ClientContextState(
      long CurrentRevisionId,
      long RevisionCount);
}
