using System.Data;
using System.Globalization;
using System.Text.Json;
using App = NikkeLocalLab.Application.PrivateServer;
using PrivateServerDomain = global::NikkeLocalLab.Domain.PrivateServer;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;
using Npgsql;
using NpgsqlTypes;

namespace NikkeLocalLab.Persistence.PostgreSql;

public sealed partial class PostgreSqlPrivateServerService
{
  private const long PrivateServerProfileOperationLockSeed = 6_172_942_681_943_527_101;

  private static readonly string[] RuntimeGraphicsFieldCodes =
  [
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
  ];

  public async Task<App.RuntimeExecutionProfileProjection> SaveRuntimeExecutionProfileAsync(
      App.SaveRuntimeExecutionProfileCommand command,
      CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(command);
    RequireProfileCommand(
        command.OperationUid,
        command.AccountUid,
        command.ProfileUid,
        command.ExpectedCurrentRevisionUid);
    var content = command.Content ?? throw ProfileFailure(
        App.PrivateServerFailureKind.InvalidRequest,
        "runtime_execution_profile_content_required");
    var materializedAtUtc = NormalizeProfileTimestamp(command.MaterializedAtUtc);
    var requestSha256 = ComputeProfileRequestSha256(
        "save_runtime_profile",
        command.AccountUid,
        command.ProfileUid,
        command.ExpectedCurrentRevisionUid,
        content.ContentSha256);

    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using var transaction = await connection.BeginTransactionAsync(
        IsolationLevel.Serializable,
        cancellationToken).ConfigureAwait(false);
    try
    {
      await AcquirePrivateServerProfileOperationLockAsync(
          connection,
          transaction,
          command.OperationUid,
          cancellationToken).ConfigureAwait(false);
      var replay = await ReadPrivateServerProfileOperationAsync(
          connection,
          transaction,
          command.OperationUid,
          "save_runtime_profile",
          requestSha256,
          cancellationToken).ConfigureAwait(false);
      if (replay is not null)
      {
        var replayed = await LoadRuntimeExecutionProfileRevisionAsync(
            connection,
            transaction,
            replay.AccountId,
            replay.ResultRevisionUid,
            cancellationToken).ConfigureAwait(false) ?? throw ProfileFailure(
                App.PrivateServerFailureKind.Unavailable,
                "runtime_execution_profile_replay_missing");
        RequireRuntimeReplayBinding(replay, command, replayed);
        await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
        return new App.RuntimeExecutionProfileProjection(replayed);
      }

      var accountId = await LockPrivateServerProfileAccountAsync(
          connection,
          transaction,
          command.AccountUid,
          cancellationToken).ConfigureAwait(false);
      var head = await LockRuntimeExecutionProfileHeadAsync(
          connection,
          transaction,
          accountId,
          cancellationToken).ConfigureAwait(false);

      PrivateServerDomain.RuntimeExecutionProfileRevision result;
      long resultRevisionId;
      if (head is null)
      {
        if (command.ExpectedCurrentRevisionUid.HasValue)
        {
          throw ProfileFailure(
              App.PrivateServerFailureKind.Conflict,
              "runtime_execution_profile_revision_conflict");
        }

        var profileId = await InsertRuntimeExecutionProfileAsync(
            connection,
            transaction,
            command.ProfileUid,
            accountId,
            materializedAtUtc,
            cancellationToken).ConfigureAwait(false);
        result = PrivateServerDomain.RuntimeExecutionProfileRevision.Create(
            command.ProfileUid,
            _uidGenerator.NewUid(),
            command.AccountUid,
            materializedAtUtc,
            content);
        resultRevisionId = await InsertRuntimeExecutionProfileRevisionAsync(
            connection,
            transaction,
            profileId,
            accountId,
            previousRevisionId: null,
            result,
            cancellationToken).ConfigureAwait(false);
        await AdvanceRuntimeExecutionProfileHeadAsync(
            connection,
            transaction,
            profileId,
            resultRevisionId,
            cancellationToken).ConfigureAwait(false);
      }
      else
      {
        if (head.ProfileUid != command.ProfileUid ||
            !command.ExpectedCurrentRevisionUid.HasValue ||
            command.ExpectedCurrentRevisionUid.Value != head.RevisionUid)
        {
          throw ProfileFailure(
              App.PrivateServerFailureKind.Conflict,
              "runtime_execution_profile_revision_conflict");
        }

        var current = await LoadRuntimeExecutionProfileRevisionAsync(
            connection,
            transaction,
            accountId,
            head.RevisionUid,
            cancellationToken).ConfigureAwait(false) ?? throw ProfileFailure(
                App.PrivateServerFailureKind.Unavailable,
                "runtime_execution_profile_head_missing");
        if (current.ContentSha256 == content.ContentSha256)
        {
          result = current;
          resultRevisionId = head.RevisionId;
        }
        else
        {
          result = current.Revise(
              _uidGenerator.NewUid(),
              materializedAtUtc,
              content);
          resultRevisionId = await InsertRuntimeExecutionProfileRevisionAsync(
              connection,
              transaction,
              head.ProfileId,
              accountId,
              head.RevisionId,
              result,
              cancellationToken).ConfigureAwait(false);
          await AdvanceRuntimeExecutionProfileHeadAsync(
              connection,
              transaction,
              head.ProfileId,
              resultRevisionId,
              cancellationToken).ConfigureAwait(false);
        }
      }

      await RecordPrivateServerProfileOperationAsync(
          connection,
          transaction,
          command.OperationUid,
          "save_runtime_profile",
          requestSha256,
          accountId,
          command.ExpectedCurrentRevisionUid,
          result.ProfileUid,
          result.RevisionUid,
          result.ContentSha256,
          materializedAtUtc,
          cancellationToken).ConfigureAwait(false);
      await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
      return new App.RuntimeExecutionProfileProjection(result);
    }
    catch (PostgresException exception)
    {
      throw MapPrivateServerProfileDatabaseException(exception);
    }
    catch (NpgsqlException exception)
    {
      throw ProfileFailure(
          App.PrivateServerFailureKind.Unavailable,
          "private_server_profile_database_unavailable",
          exception);
    }
    catch (PrivateServerDomain.PrivateServerIntegrityException exception)
    {
      throw ProfileFailure(
          App.PrivateServerFailureKind.Unavailable,
          "private_server_profile_integrity_failed",
          exception);
    }
  }

  public async Task<App.CombatControlProfileProjection> SaveCombatControlProfileAsync(
      App.SaveCombatControlProfileCommand command,
      CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(command);
    RequireProfileCommand(
        command.OperationUid,
        command.AccountUid,
        command.ProfileUid,
        command.ExpectedCurrentRevisionUid);
    var content = command.Content ?? throw ProfileFailure(
        App.PrivateServerFailureKind.InvalidRequest,
        "combat_control_profile_content_required");
    var materializedAtUtc = NormalizeProfileTimestamp(command.MaterializedAtUtc);
    var requestSha256 = ComputeProfileRequestSha256(
        "save_control_profile",
        command.AccountUid,
        command.ProfileUid,
        command.ExpectedCurrentRevisionUid,
        content.ContentSha256);

    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using var transaction = await connection.BeginTransactionAsync(
        IsolationLevel.Serializable,
        cancellationToken).ConfigureAwait(false);
    try
    {
      await AcquirePrivateServerProfileOperationLockAsync(
          connection,
          transaction,
          command.OperationUid,
          cancellationToken).ConfigureAwait(false);
      var replay = await ReadPrivateServerProfileOperationAsync(
          connection,
          transaction,
          command.OperationUid,
          "save_control_profile",
          requestSha256,
          cancellationToken).ConfigureAwait(false);
      if (replay is not null)
      {
        var replayed = await LoadCombatControlProfileRevisionAsync(
            connection,
            transaction,
            replay.AccountId,
            replay.ResultRevisionUid,
            cancellationToken).ConfigureAwait(false) ?? throw ProfileFailure(
                App.PrivateServerFailureKind.Unavailable,
                "combat_control_profile_replay_missing");
        RequireControlReplayBinding(replay, command, replayed);
        await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
        return new App.CombatControlProfileProjection(replayed);
      }

      var accountId = await LockPrivateServerProfileAccountAsync(
          connection,
          transaction,
          command.AccountUid,
          cancellationToken).ConfigureAwait(false);
      var head = await LockCombatControlProfileHeadAsync(
          connection,
          transaction,
          accountId,
          cancellationToken).ConfigureAwait(false);

      PrivateServerDomain.CombatControlProfileRevision result;
      long resultRevisionId;
      if (head is null)
      {
        if (command.ExpectedCurrentRevisionUid.HasValue)
        {
          throw ProfileFailure(
              App.PrivateServerFailureKind.Conflict,
              "combat_control_profile_revision_conflict");
        }

        var profileId = await InsertCombatControlProfileAsync(
            connection,
            transaction,
            command.ProfileUid,
            accountId,
            materializedAtUtc,
            cancellationToken).ConfigureAwait(false);
        result = PrivateServerDomain.CombatControlProfileRevision.Create(
            command.ProfileUid,
            _uidGenerator.NewUid(),
            command.AccountUid,
            materializedAtUtc,
            content);
        resultRevisionId = await InsertCombatControlProfileRevisionAsync(
            connection,
            transaction,
            profileId,
            accountId,
            previousRevisionId: null,
            result,
            cancellationToken).ConfigureAwait(false);
        await AdvanceCombatControlProfileHeadAsync(
            connection,
            transaction,
            profileId,
            resultRevisionId,
            cancellationToken).ConfigureAwait(false);
      }
      else
      {
        if (head.ProfileUid != command.ProfileUid ||
            !command.ExpectedCurrentRevisionUid.HasValue ||
            command.ExpectedCurrentRevisionUid.Value != head.RevisionUid)
        {
          throw ProfileFailure(
              App.PrivateServerFailureKind.Conflict,
              "combat_control_profile_revision_conflict");
        }

        var current = await LoadCombatControlProfileRevisionAsync(
            connection,
            transaction,
            accountId,
            head.RevisionUid,
            cancellationToken).ConfigureAwait(false) ?? throw ProfileFailure(
                App.PrivateServerFailureKind.Unavailable,
                "combat_control_profile_head_missing");
        if (current.ContentSha256 == content.ContentSha256)
        {
          result = current;
          resultRevisionId = head.RevisionId;
        }
        else
        {
          result = current.Revise(
              _uidGenerator.NewUid(),
              materializedAtUtc,
              content);
          resultRevisionId = await InsertCombatControlProfileRevisionAsync(
              connection,
              transaction,
              head.ProfileId,
              accountId,
              head.RevisionId,
              result,
              cancellationToken).ConfigureAwait(false);
          await AdvanceCombatControlProfileHeadAsync(
              connection,
              transaction,
              head.ProfileId,
              resultRevisionId,
              cancellationToken).ConfigureAwait(false);
        }
      }

      await RecordPrivateServerProfileOperationAsync(
          connection,
          transaction,
          command.OperationUid,
          "save_control_profile",
          requestSha256,
          accountId,
          command.ExpectedCurrentRevisionUid,
          result.ProfileUid,
          result.RevisionUid,
          result.ContentSha256,
          materializedAtUtc,
          cancellationToken).ConfigureAwait(false);
      await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
      return new App.CombatControlProfileProjection(result);
    }
    catch (PostgresException exception)
    {
      throw MapPrivateServerProfileDatabaseException(exception);
    }
    catch (NpgsqlException exception)
    {
      throw ProfileFailure(
          App.PrivateServerFailureKind.Unavailable,
          "private_server_profile_database_unavailable",
          exception);
    }
    catch (PrivateServerDomain.PrivateServerIntegrityException exception)
    {
      throw ProfileFailure(
          App.PrivateServerFailureKind.Unavailable,
          "private_server_profile_integrity_failed",
          exception);
    }
  }

  internal static async Task<App.ChallengeRuntimeExecutionPinProjection?>
      LoadCurrentRuntimeExecutionPinAsync(
          NpgsqlConnection connection,
          NpgsqlTransaction? transaction,
          long accountId,
          CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT revision.runtime_execution_profile_revision_uid
        FROM lab_private_server.runtime_execution_profile profile
        JOIN lab_private_server.runtime_execution_profile_revision revision
          ON revision.runtime_execution_profile_revision_id =
             profile.current_runtime_execution_profile_revision_id
        WHERE profile.local_account_id = @account_id;
        """,
        connection,
        transaction);
    ProfileAdd(command, "account_id", NpgsqlDbType.Bigint, accountId);
    var storedRevisionUid = await command.ExecuteScalarAsync(cancellationToken)
        .ConfigureAwait(false);
    if (storedRevisionUid is null or DBNull)
    {
      return null;
    }

    var revisionUid = new EntityUid((Guid)storedRevisionUid);
    var revision = await LoadRuntimeExecutionProfileRevisionAsync(
        connection,
        transaction,
        accountId,
        revisionUid,
        cancellationToken).ConfigureAwait(false) ?? throw ProfileFailure(
            App.PrivateServerFailureKind.Unavailable,
            "runtime_execution_profile_head_missing");
    return new App.ChallengeRuntimeExecutionPinProjection(
        revision.RevisionUid,
        revision.ContentSha256,
        revision.Content.IsHarnessValidationReady);
  }

  internal static async Task<App.ChallengeCombatControlPinProjection?>
      LoadCurrentCombatControlPinAsync(
          NpgsqlConnection connection,
          NpgsqlTransaction? transaction,
          long accountId,
          CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT revision.combat_control_profile_revision_uid
        FROM lab_private_server.combat_control_profile profile
        JOIN lab_private_server.combat_control_profile_revision revision
          ON revision.combat_control_profile_revision_id =
             profile.current_combat_control_profile_revision_id
        WHERE profile.local_account_id = @account_id;
        """,
        connection,
        transaction);
    ProfileAdd(command, "account_id", NpgsqlDbType.Bigint, accountId);
    var storedRevisionUid = await command.ExecuteScalarAsync(cancellationToken)
        .ConfigureAwait(false);
    if (storedRevisionUid is null or DBNull)
    {
      return null;
    }

    var revisionUid = new EntityUid((Guid)storedRevisionUid);
    var revision = await LoadCombatControlProfileRevisionAsync(
        connection,
        transaction,
        accountId,
        revisionUid,
        cancellationToken).ConfigureAwait(false) ?? throw ProfileFailure(
            App.PrivateServerFailureKind.Unavailable,
            "combat_control_profile_head_missing");
    return new App.ChallengeCombatControlPinProjection(
        revision.RevisionUid,
        revision.ContentSha256,
        revision.Content.IsManualBattleReady);
  }

  internal static async Task<global::NikkeLocalLab.Domain.PrivateServer.RuntimeExecutionProfileRevision?>
      LoadRuntimeExecutionProfileRevisionAsync(
          NpgsqlConnection connection,
          NpgsqlTransaction? transaction,
          long accountId,
          EntityUid revisionUid,
          CancellationToken cancellationToken)
  {
    var stored = await ReadRuntimeExecutionRevisionRowAsync(
        connection,
        transaction,
        accountId,
        revisionUid,
        cancellationToken).ConfigureAwait(false);
    if (stored is null)
    {
      return null;
    }

    var facts = await ReadProfileFactsAsync(
        connection,
        transaction,
        "runtime_execution_profile_fact",
        "runtime_execution_profile_revision_id",
        stored.RevisionId,
        cancellationToken).ConfigureAwait(false);
    var requested = MaterializeRuntimeSettings(facts, useEffective: false);
    var effective = stored.EffectiveSnapshotPresent
        ? MaterializeRuntimeSettings(facts, useEffective: true)
        : null;
    var originalBuild = stored.OriginalRuntimeBuildStatus switch
    {
      "ready" => PrivateServerDomain.OriginalClientRuntimeBuildBinding.Ready(
          stored.OriginalRuntimeBuildUid ?? throw ProfileFailure(
              App.PrivateServerFailureKind.Unavailable,
              "runtime_execution_profile_build_binding_invalid"),
          stored.OriginalRuntimeBuildSha256 ?? throw ProfileFailure(
              App.PrivateServerFailureKind.Unavailable,
              "runtime_execution_profile_build_binding_invalid")),
      "unresolved" => PrivateServerDomain.OriginalClientRuntimeBuildBinding.Unresolved(
          stored.OriginalRuntimeBuildReasonCode ?? throw ProfileFailure(
              App.PrivateServerFailureKind.Unavailable,
              "runtime_execution_profile_build_binding_invalid")),
      _ => throw ProfileFailure(
          App.PrivateServerFailureKind.Unavailable,
          "runtime_execution_profile_build_binding_invalid")
    };
    var content = new PrivateServerDomain.RuntimeExecutionProfileContent(
        originalBuild,
        requested,
        effective);
    var canonicalFacts = BuildRuntimeFacts(requested, effective);
    RequireStoredFactsMatchCanonical(
        facts,
        canonicalFacts,
        "runtime_execution_profile_fact_content_mismatch");
    RequireProfilePayloadMatchesCanonical(
        stored.RequestedPayload,
        "nll/runtime-execution-settings/v1",
        canonicalFacts,
        useEffective: false,
        "runtime_execution_profile_payload_mismatch");
    RequireEffectivePayloadMatchesCanonical(
        stored.EffectivePayload,
        stored.EffectiveSnapshotPresent,
        "nll/runtime-execution-settings/v1",
        canonicalFacts,
        "runtime_execution_profile_payload_mismatch");
    if (content.ContentSha256 != stored.ContentSha256 ||
        !string.Equals(
            stored.SchemaVersion,
            "nll/runtime-execution-profile/v1",
            StringComparison.Ordinal) ||
        stored.FactCount != 21 ||
        content.IsHarnessValidationReady != stored.HarnessValidationReady ||
        content.IsOriginalClientLaunchReady != stored.OriginalClientLaunchReady ||
        content.IsEffectiveReadbackReady != stored.EffectiveReadbackReady ||
        !string.Equals(
            stored.ReadinessIssueCode,
            content.IsHarnessValidationReady
                ? null
                : "runtime_execution_profile_not_ready",
            StringComparison.Ordinal))
    {
      throw ProfileFailure(
          App.PrivateServerFailureKind.Unavailable,
          "runtime_execution_profile_content_mismatch");
    }

    return PrivateServerDomain.RuntimeExecutionProfileRevision.Restore(
        stored.ProfileUid,
        stored.RevisionUid,
        stored.AccountUid,
        stored.RevisionNumber,
        stored.PredecessorRevisionUid,
        stored.MaterializedAtUtc,
        content);
  }

  internal static async Task<PrivateServerDomain.CombatControlProfileRevision?>
      LoadCombatControlProfileRevisionAsync(
          NpgsqlConnection connection,
          NpgsqlTransaction? transaction,
          long accountId,
          EntityUid revisionUid,
          CancellationToken cancellationToken)
  {
    var stored = await ReadCombatControlRevisionRowAsync(
        connection,
        transaction,
        accountId,
        revisionUid,
        cancellationToken).ConfigureAwait(false);
    if (stored is null)
    {
      return null;
    }

    var facts = await ReadProfileFactsAsync(
        connection,
        transaction,
        "combat_control_profile_fact",
        "combat_control_profile_revision_id",
        stored.RevisionId,
        cancellationToken).ConfigureAwait(false);
    var requested = MaterializeCombatControlSettings(facts, useEffective: false);
    var effective = stored.EffectiveSnapshotPresent
        ? MaterializeCombatControlSettings(facts, useEffective: true)
        : null;
    var content = new PrivateServerDomain.CombatControlProfileContent(requested, effective);
    var canonicalFacts = BuildControlFacts(requested, effective);
    RequireStoredFactsMatchCanonical(
        facts,
        canonicalFacts,
        "combat_control_profile_fact_content_mismatch");
    RequireProfilePayloadMatchesCanonical(
        stored.RequestedPayload,
        "nll/combat-control-settings/v1",
        canonicalFacts,
        useEffective: false,
        "combat_control_profile_payload_mismatch");
    RequireEffectivePayloadMatchesCanonical(
        stored.EffectivePayload,
        stored.EffectiveSnapshotPresent,
        "nll/combat-control-settings/v1",
        canonicalFacts,
        "combat_control_profile_payload_mismatch");
    if (content.ContentSha256 != stored.ContentSha256 ||
        !string.Equals(
            stored.SchemaVersion,
            "nll/combat-control-profile/v1",
            StringComparison.Ordinal) ||
        stored.FactCount != 7 ||
        content.IsManualBattleReady != stored.ManualReady ||
        (content.Effective?.IsManualBattleReady ?? false) != stored.EffectiveManualReady ||
        content.IsEffectiveReadbackReady != stored.EffectiveReadbackReady ||
        !string.Equals(
            stored.ReadinessIssueCode,
            content.IsManualBattleReady ? null : "combat_control_profile_not_ready",
            StringComparison.Ordinal))
    {
      throw ProfileFailure(
          App.PrivateServerFailureKind.Unavailable,
          "combat_control_profile_content_mismatch");
    }

    return PrivateServerDomain.CombatControlProfileRevision.Restore(
        stored.ProfileUid,
        stored.RevisionUid,
        stored.AccountUid,
        stored.RevisionNumber,
        stored.PredecessorRevisionUid,
        stored.MaterializedAtUtc,
        content);
  }

  private static async Task AcquirePrivateServerProfileOperationLockAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid operationUid,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        "SELECT pg_advisory_xact_lock(hashtextextended(@value, @seed));",
        connection,
        transaction);
    ProfileAdd(command, "value", NpgsqlDbType.Text, operationUid.ToString());
    ProfileAdd(
        command,
        "seed",
        NpgsqlDbType.Bigint,
        PrivateServerProfileOperationLockSeed);
    await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
  }

  private static async Task<PrivateServerProfileOperationRow?>
      ReadPrivateServerProfileOperationAsync(
          NpgsqlConnection connection,
          NpgsqlTransaction transaction,
          EntityUid operationUid,
          string expectedKind,
          Sha256Digest expectedRequestSha256,
          CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT operation_kind,
               request_sha256,
               local_account_id,
               expected_revision_uid,
               result_entity_uid,
               result_revision_uid,
               result_content_sha256
        FROM lab_private_server.private_server_write_operation
        WHERE operation_uid = @operation_uid;
        """,
        connection,
        transaction);
    ProfileAdd(command, "operation_uid", NpgsqlDbType.Uuid, operationUid.Value);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken)
        .ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      return null;
    }

    if (!string.Equals(reader.GetString(0), expectedKind, StringComparison.Ordinal) ||
        ReadProfileDigest(reader, 1) != expectedRequestSha256 ||
        reader.IsDBNull(2) || reader.IsDBNull(5))
    {
      throw ProfileFailure(
          App.PrivateServerFailureKind.Conflict,
          "private_server_operation_reuse_mismatch");
    }

    return new PrivateServerProfileOperationRow(
        reader.GetInt64(2),
        reader.IsDBNull(3) ? null : new EntityUid(reader.GetGuid(3)),
        new EntityUid(reader.GetGuid(4)),
        new EntityUid(reader.GetGuid(5)),
        ReadProfileDigest(reader, 6));
  }

  private static async Task RecordPrivateServerProfileOperationAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid operationUid,
      string operationKind,
      Sha256Digest requestSha256,
      long accountId,
      EntityUid? expectedRevisionUid,
      EntityUid resultEntityUid,
      EntityUid resultRevisionUid,
      Sha256Digest resultContentSha256,
      DateTimeOffset completedAtUtc,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        INSERT INTO lab_private_server.private_server_write_operation (
            operation_uid,
            operation_kind,
            request_sha256,
            local_account_id,
            expected_revision_uid,
            result_entity_uid,
            result_revision_uid,
            result_content_sha256,
            completed_at_utc
        ) VALUES (
            @operation_uid,
            @operation_kind,
            @request_sha256,
            @account_id,
            @expected_revision_uid,
            @result_entity_uid,
            @result_revision_uid,
            @result_content_sha256,
            @completed_at_utc
        );
        """,
        connection,
        transaction);
    ProfileAdd(command, "operation_uid", NpgsqlDbType.Uuid, operationUid.Value);
    ProfileAdd(command, "operation_kind", NpgsqlDbType.Text, operationKind);
    ProfileAdd(
        command,
        "request_sha256",
        NpgsqlDbType.Bytea,
        requestSha256.ToByteArray());
    ProfileAdd(command, "account_id", NpgsqlDbType.Bigint, accountId);
    ProfileAdd(
        command,
        "expected_revision_uid",
        NpgsqlDbType.Uuid,
        expectedRevisionUid?.Value);
    ProfileAdd(command, "result_entity_uid", NpgsqlDbType.Uuid, resultEntityUid.Value);
    ProfileAdd(command, "result_revision_uid", NpgsqlDbType.Uuid, resultRevisionUid.Value);
    ProfileAdd(
        command,
        "result_content_sha256",
        NpgsqlDbType.Bytea,
        resultContentSha256.ToByteArray());
    ProfileAdd(command, "completed_at_utc", NpgsqlDbType.TimestampTz, completedAtUtc);
    await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
  }

  private static async Task<long> LockPrivateServerProfileAccountAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid accountUid,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT local_account_id
        FROM lab_profile.local_account
        WHERE local_account_uid = @account_uid
        FOR UPDATE;
        """,
        connection,
        transaction);
    ProfileAdd(command, "account_uid", NpgsqlDbType.Uuid, accountUid.Value);
    var value = await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
    if (value is null or DBNull)
    {
      throw ProfileFailure(
          App.PrivateServerFailureKind.NotFound,
          "private_server_account_not_found");
    }

    return Convert.ToInt64(value, CultureInfo.InvariantCulture);
  }

  private static async Task<PrivateServerProfileHead?> LockRuntimeExecutionProfileHeadAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long accountId,
      CancellationToken cancellationToken) =>
      await LockPrivateServerProfileHeadAsync(
          connection,
          transaction,
          "runtime_execution_profile",
          "runtime_execution_profile_id",
          "runtime_execution_profile_uid",
          "current_runtime_execution_profile_revision_id",
          "runtime_execution_profile_revision",
          "runtime_execution_profile_revision_id",
          "runtime_execution_profile_revision_uid",
          accountId,
          cancellationToken).ConfigureAwait(false);

  private static async Task<PrivateServerProfileHead?> LockCombatControlProfileHeadAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long accountId,
      CancellationToken cancellationToken) =>
      await LockPrivateServerProfileHeadAsync(
          connection,
          transaction,
          "combat_control_profile",
          "combat_control_profile_id",
          "combat_control_profile_uid",
          "current_combat_control_profile_revision_id",
          "combat_control_profile_revision",
          "combat_control_profile_revision_id",
          "combat_control_profile_revision_uid",
          accountId,
          cancellationToken).ConfigureAwait(false);

  private static async Task<PrivateServerProfileHead?> LockPrivateServerProfileHeadAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      string profileTable,
      string profileIdColumn,
      string profileUidColumn,
      string currentRevisionColumn,
      string revisionTable,
      string revisionIdColumn,
      string revisionUidColumn,
      long accountId,
      CancellationToken cancellationToken)
  {
    var sql = $"""
        SELECT profile.{profileIdColumn},
               profile.{profileUidColumn},
               revision.{revisionIdColumn},
               revision.{revisionUidColumn}
        FROM lab_private_server.{profileTable} profile
        LEFT JOIN lab_private_server.{revisionTable} revision
          ON revision.{revisionIdColumn} = profile.{currentRevisionColumn}
        WHERE profile.local_account_id = @account_id
        FOR UPDATE OF profile;
        """;
    await using var command = new NpgsqlCommand(sql, connection, transaction);
    ProfileAdd(command, "account_id", NpgsqlDbType.Bigint, accountId);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken)
        .ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      return null;
    }

    if (reader.IsDBNull(2) || reader.IsDBNull(3))
    {
      throw ProfileFailure(
          App.PrivateServerFailureKind.Unavailable,
          "private_server_profile_head_missing");
    }

    return new PrivateServerProfileHead(
        reader.GetInt64(0),
        new EntityUid(reader.GetGuid(1)),
        reader.GetInt64(2),
        new EntityUid(reader.GetGuid(3)));
  }

  private static async Task<long> InsertRuntimeExecutionProfileAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid profileUid,
      long accountId,
      DateTimeOffset createdAtUtc,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        INSERT INTO lab_private_server.runtime_execution_profile (
            runtime_execution_profile_uid,
            local_account_id,
            created_at_utc
        ) VALUES (
            @profile_uid,
            @account_id,
            @created_at_utc
        )
        RETURNING runtime_execution_profile_id;
        """,
        connection,
        transaction);
    ProfileAdd(command, "profile_uid", NpgsqlDbType.Uuid, profileUid.Value);
    ProfileAdd(command, "account_id", NpgsqlDbType.Bigint, accountId);
    ProfileAdd(command, "created_at_utc", NpgsqlDbType.TimestampTz, createdAtUtc);
    var value = await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
    return Convert.ToInt64(value, CultureInfo.InvariantCulture);
  }

  private static async Task<long> InsertCombatControlProfileAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid profileUid,
      long accountId,
      DateTimeOffset createdAtUtc,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        INSERT INTO lab_private_server.combat_control_profile (
            combat_control_profile_uid,
            local_account_id,
            created_at_utc
        ) VALUES (
            @profile_uid,
            @account_id,
            @created_at_utc
        )
        RETURNING combat_control_profile_id;
        """,
        connection,
        transaction);
    ProfileAdd(command, "profile_uid", NpgsqlDbType.Uuid, profileUid.Value);
    ProfileAdd(command, "account_id", NpgsqlDbType.Bigint, accountId);
    ProfileAdd(command, "created_at_utc", NpgsqlDbType.TimestampTz, createdAtUtc);
    var value = await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
    return Convert.ToInt64(value, CultureInfo.InvariantCulture);
  }

  private static async Task AdvanceRuntimeExecutionProfileHeadAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long profileId,
      long revisionId,
      CancellationToken cancellationToken) =>
      await AdvancePrivateServerProfileHeadAsync(
          connection,
          transaction,
          "runtime_execution_profile",
          "runtime_execution_profile_id",
          "current_runtime_execution_profile_revision_id",
          profileId,
          revisionId,
          cancellationToken).ConfigureAwait(false);

  private static async Task AdvanceCombatControlProfileHeadAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long profileId,
      long revisionId,
      CancellationToken cancellationToken) =>
      await AdvancePrivateServerProfileHeadAsync(
          connection,
          transaction,
          "combat_control_profile",
          "combat_control_profile_id",
          "current_combat_control_profile_revision_id",
          profileId,
          revisionId,
          cancellationToken).ConfigureAwait(false);

  private static async Task AdvancePrivateServerProfileHeadAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      string profileTable,
      string profileIdColumn,
      string currentRevisionColumn,
      long profileId,
      long revisionId,
      CancellationToken cancellationToken)
  {
    var sql = $"""
        UPDATE lab_private_server.{profileTable}
           SET {currentRevisionColumn} = @revision_id
         WHERE {profileIdColumn} = @profile_id;
        """;
    await using var command = new NpgsqlCommand(sql, connection, transaction);
    ProfileAdd(command, "revision_id", NpgsqlDbType.Bigint, revisionId);
    ProfileAdd(command, "profile_id", NpgsqlDbType.Bigint, profileId);
    if (await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false) != 1)
    {
      throw ProfileFailure(
          App.PrivateServerFailureKind.Conflict,
          "private_server_profile_revision_conflict");
    }
  }

  private static async Task<long> InsertRuntimeExecutionProfileRevisionAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long profileId,
      long accountId,
      long? previousRevisionId,
      PrivateServerDomain.RuntimeExecutionProfileRevision revision,
      CancellationToken cancellationToken)
  {
    var content = revision.Content;
    var facts = BuildRuntimeFacts(content.Requested, content.Effective);
    var originalRuntime = await ResolveOriginalRuntimeBuildAsync(
        connection,
        transaction,
        content.OriginalClientRuntimeBuild,
        cancellationToken).ConfigureAwait(false);
    var requestedGraphics = content.Requested.Graphics.Options.ToDictionary(
        static option => option.FieldCode,
        static option => option.Value,
        StringComparer.Ordinal);

    await using var command = new NpgsqlCommand(
        """
        INSERT INTO lab_private_server.runtime_execution_profile_revision (
            runtime_execution_profile_revision_uid,
            runtime_execution_profile_id,
            local_account_id,
            revision_number,
            previous_runtime_execution_profile_revision_id,
            schema_version,
            original_runtime_build_status,
            original_client_runtime_build_id,
            original_client_runtime_build_uid,
            original_runtime_source_artifact_id,
            original_runtime_build_sha256,
            original_runtime_build_unresolved_reason_code,
            requested_payload,
            effective_payload,
            target_fps,
            fixed_delta_denominator,
            vsync_enabled,
            multiplayer_enabled,
            time_scale_code,
            platform_code,
            display_mode_code,
            display_width,
            display_height,
            effective_refresh_hz,
            graphic_option_mode,
            default_quality_level,
            post_process_flags,
            volumetric_fog_quality,
            battle_effect_quality,
            battle_animation_physics_flags,
            spine_resolution,
            texture_quality,
            mesh_quality,
            anti_aliasing_enabled,
            anti_aliasing_step,
            fact_count,
            effective_snapshot_present,
            harness_validation_ready,
            original_client_launch_ready,
            effective_readback_ready,
            readiness_issue_code,
            content_sha256,
            materialized_at_utc
        ) VALUES (
            @revision_uid,
            @profile_id,
            @account_id,
            @revision_number,
            @previous_revision_id,
            'nll/runtime-execution-profile/v1',
            @original_runtime_build_status,
            @original_runtime_build_id,
            @original_runtime_build_uid,
            @original_runtime_source_artifact_id,
            @original_runtime_build_sha256,
            @original_runtime_build_reason_code,
            @requested_payload,
            @effective_payload,
            @target_fps,
            @fixed_delta_denominator,
            @vsync_enabled,
            @multiplayer_enabled,
            @time_scale_code,
            @platform_code,
            @display_mode_code,
            @display_width,
            @display_height,
            @effective_refresh_hz,
            @graphic_option_mode,
            @default_quality_level,
            @post_process_flags,
            @volumetric_fog_quality,
            @battle_effect_quality,
            @battle_animation_physics_flags,
            @spine_resolution,
            @texture_quality,
            @mesh_quality,
            @anti_aliasing_enabled,
            @anti_aliasing_step,
            21,
            @effective_snapshot_present,
            @harness_validation_ready,
            @original_client_launch_ready,
            @effective_readback_ready,
            @readiness_issue_code,
            @content_sha256,
            @materialized_at_utc
        )
        RETURNING runtime_execution_profile_revision_id;
        """,
        connection,
        transaction);
    ProfileAdd(command, "revision_uid", NpgsqlDbType.Uuid, revision.RevisionUid.Value);
    ProfileAdd(command, "profile_id", NpgsqlDbType.Bigint, profileId);
    ProfileAdd(command, "account_id", NpgsqlDbType.Bigint, accountId);
    ProfileAdd(command, "revision_number", NpgsqlDbType.Integer, checked((int)revision.RevisionNumber));
    ProfileAdd(command, "previous_revision_id", NpgsqlDbType.Bigint, previousRevisionId);
    ProfileAdd(
        command,
        "original_runtime_build_status",
        NpgsqlDbType.Text,
        FactStatusCode(content.OriginalClientRuntimeBuild.Status));
    ProfileAdd(command, "original_runtime_build_id", NpgsqlDbType.Bigint, originalRuntime?.BuildId);
    ProfileAdd(
        command,
        "original_runtime_build_uid",
        NpgsqlDbType.Uuid,
        content.OriginalClientRuntimeBuild.BuildUid?.Value);
    ProfileAdd(
        command,
        "original_runtime_source_artifact_id",
        NpgsqlDbType.Bigint,
        originalRuntime?.SourceArtifactId);
    ProfileAdd(
        command,
        "original_runtime_build_sha256",
        NpgsqlDbType.Bytea,
        content.OriginalClientRuntimeBuild.BuildSha256?.ToByteArray());
    ProfileAdd(
        command,
        "original_runtime_build_reason_code",
        NpgsqlDbType.Text,
        content.OriginalClientRuntimeBuild.UnresolvedReasonCode);
    ProfileAdd(
        command,
        "requested_payload",
        NpgsqlDbType.Jsonb,
        SerializeProfilePayload("nll/runtime-execution-settings/v1", facts, useEffective: false));
    ProfileAdd(
        command,
        "effective_payload",
        NpgsqlDbType.Jsonb,
        content.Effective is null
            ? null
            : SerializeProfilePayload("nll/runtime-execution-settings/v1", facts, useEffective: true));
    ProfileAdd(
        command,
        "target_fps",
        NpgsqlDbType.Smallint,
        ReadyValue(content.Requested.Scheduler.TargetFrameRate) is { } targetFrameRate
            ? checked((short)(int)targetFrameRate)
            : null);
    ProfileAdd(
        command,
        "fixed_delta_denominator",
        NpgsqlDbType.Integer,
        ReadyValue(content.Requested.Scheduler.FixedDeltaDenominator));
    ProfileAdd(command, "vsync_enabled", NpgsqlDbType.Boolean, ReadyValue(content.Requested.Scheduler.VsyncEnabled));
    ProfileAdd(
        command,
        "multiplayer_enabled",
        NpgsqlDbType.Boolean,
        ReadyValue(content.Requested.Scheduler.MultiplayerEnabled));
    ProfileAdd(
        command,
        "time_scale_code",
        NpgsqlDbType.Text,
        ReadyValue(content.Requested.Scheduler.TimeScale) is { } timeScale
            ? PrivateServerDomain.RuntimeExecutionSettingsSnapshot.TimeScaleCode(timeScale)
            : null);
    ProfileAdd(command, "platform_code", NpgsqlDbType.Text, ReadyCode(content.Requested.Display.Platform));
    ProfileAdd(command, "display_mode_code", NpgsqlDbType.Text, ReadyCode(content.Requested.Display.DisplayMode));
    ProfileAdd(command, "display_width", NpgsqlDbType.Integer, ReadyValue(content.Requested.Display.Width));
    ProfileAdd(command, "display_height", NpgsqlDbType.Integer, ReadyValue(content.Requested.Display.Height));
    ProfileAdd(
        command,
        "effective_refresh_hz",
        NpgsqlDbType.Numeric,
        ReadyValue(content.Requested.Display.RefreshRateHz));
    foreach (var fieldCode in RuntimeGraphicsFieldCodes)
    {
      ProfileAdd(
          command,
          fieldCode,
          NpgsqlDbType.Text,
          ReadyCode(requestedGraphics[fieldCode]));
    }

    ProfileAdd(command, "effective_snapshot_present", NpgsqlDbType.Boolean, content.Effective is not null);
    ProfileAdd(command, "harness_validation_ready", NpgsqlDbType.Boolean, content.IsHarnessValidationReady);
    ProfileAdd(command, "original_client_launch_ready", NpgsqlDbType.Boolean, content.IsOriginalClientLaunchReady);
    ProfileAdd(command, "effective_readback_ready", NpgsqlDbType.Boolean, content.IsEffectiveReadbackReady);
    ProfileAdd(
        command,
        "readiness_issue_code",
        NpgsqlDbType.Text,
        content.IsHarnessValidationReady ? null : "runtime_execution_profile_not_ready");
    ProfileAdd(command, "content_sha256", NpgsqlDbType.Bytea, content.ContentSha256.ToByteArray());
    ProfileAdd(command, "materialized_at_utc", NpgsqlDbType.TimestampTz, revision.MaterializedAtUtc);
    var value = await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
    var revisionId = Convert.ToInt64(value, CultureInfo.InvariantCulture);
    await InsertProfileFactsAsync(
        connection,
        transaction,
        "runtime_execution_profile_fact",
        "runtime_execution_profile_revision_id",
        revisionId,
        facts,
        cancellationToken).ConfigureAwait(false);
    return revisionId;
  }

  private static async Task<long> InsertCombatControlProfileRevisionAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long profileId,
      long accountId,
      long? previousRevisionId,
      PrivateServerDomain.CombatControlProfileRevision revision,
      CancellationToken cancellationToken)
  {
    var content = revision.Content;
    var facts = BuildControlFacts(content.Requested, content.Effective);
    await using var command = new NpgsqlCommand(
        """
        INSERT INTO lab_private_server.combat_control_profile_revision (
            combat_control_profile_revision_uid,
            combat_control_profile_id,
            local_account_id,
            revision_number,
            previous_combat_control_profile_revision_id,
            schema_version,
            requested_payload,
            effective_payload,
            aim_sensitivity,
            use_aim_assistant,
            aim_assistant_intensity,
            use_pc_aim_sync,
            max_per_shot_correct,
            auto_combat_status,
            auto_combat_value,
            auto_combat_unresolved_reason_code,
            auto_burst_status,
            auto_burst_value,
            auto_burst_unresolved_reason_code,
            fact_count,
            effective_snapshot_present,
            manual_ready,
            effective_manual_ready,
            effective_readback_ready,
            readiness_issue_code,
            content_sha256,
            materialized_at_utc
        ) VALUES (
            @revision_uid,
            @profile_id,
            @account_id,
            @revision_number,
            @previous_revision_id,
            'nll/combat-control-profile/v1',
            @requested_payload,
            @effective_payload,
            @aim_sensitivity,
            @use_aim_assistant,
            @aim_assistant_intensity,
            @use_pc_aim_sync,
            @max_per_shot_correct,
            @auto_combat_status,
            @auto_combat_value,
            @auto_combat_reason_code,
            @auto_burst_status,
            @auto_burst_value,
            @auto_burst_reason_code,
            7,
            @effective_snapshot_present,
            @manual_ready,
            @effective_manual_ready,
            @effective_readback_ready,
            @readiness_issue_code,
            @content_sha256,
            @materialized_at_utc
        )
        RETURNING combat_control_profile_revision_id;
        """,
        connection,
        transaction);
    ProfileAdd(command, "revision_uid", NpgsqlDbType.Uuid, revision.RevisionUid.Value);
    ProfileAdd(command, "profile_id", NpgsqlDbType.Bigint, profileId);
    ProfileAdd(command, "account_id", NpgsqlDbType.Bigint, accountId);
    ProfileAdd(command, "revision_number", NpgsqlDbType.Integer, checked((int)revision.RevisionNumber));
    ProfileAdd(command, "previous_revision_id", NpgsqlDbType.Bigint, previousRevisionId);
    ProfileAdd(
        command,
        "requested_payload",
        NpgsqlDbType.Jsonb,
        SerializeProfilePayload("nll/combat-control-settings/v1", facts, useEffective: false));
    ProfileAdd(
        command,
        "effective_payload",
        NpgsqlDbType.Jsonb,
        content.Effective is null
            ? null
            : SerializeProfilePayload("nll/combat-control-settings/v1", facts, useEffective: true));
    ProfileAdd(command, "aim_sensitivity", NpgsqlDbType.Numeric, ReadyValue(content.Requested.AimSensitivity));
    ProfileAdd(command, "use_aim_assistant", NpgsqlDbType.Boolean, ReadyValue(content.Requested.UseAimAssistant));
    ProfileAdd(
        command,
        "aim_assistant_intensity",
        NpgsqlDbType.Numeric,
        ReadyValue(content.Requested.AimAssistantIntensity));
    ProfileAdd(command, "use_pc_aim_sync", NpgsqlDbType.Boolean, ReadyValue(content.Requested.UsePcAimSync));
    ProfileAdd(command, "max_per_shot_correct", NpgsqlDbType.Boolean, ReadyValue(content.Requested.MaxPerShotCorrect));
    AddProjectedControlFact(command, "auto_combat", content.Requested.AutoCombat);
    AddProjectedControlFact(command, "auto_burst", content.Requested.AutoBurst);
    ProfileAdd(command, "effective_snapshot_present", NpgsqlDbType.Boolean, content.Effective is not null);
    ProfileAdd(command, "manual_ready", NpgsqlDbType.Boolean, content.IsManualBattleReady);
    ProfileAdd(
        command,
        "effective_manual_ready",
        NpgsqlDbType.Boolean,
        content.Effective?.IsManualBattleReady ?? false);
    ProfileAdd(command, "effective_readback_ready", NpgsqlDbType.Boolean, content.IsEffectiveReadbackReady);
    ProfileAdd(
        command,
        "readiness_issue_code",
        NpgsqlDbType.Text,
        content.IsManualBattleReady ? null : "combat_control_profile_not_ready");
    ProfileAdd(command, "content_sha256", NpgsqlDbType.Bytea, content.ContentSha256.ToByteArray());
    ProfileAdd(command, "materialized_at_utc", NpgsqlDbType.TimestampTz, revision.MaterializedAtUtc);
    var value = await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
    var revisionId = Convert.ToInt64(value, CultureInfo.InvariantCulture);
    await InsertProfileFactsAsync(
        connection,
        transaction,
        "combat_control_profile_fact",
        "combat_control_profile_revision_id",
        revisionId,
        facts,
        cancellationToken).ConfigureAwait(false);
    return revisionId;
  }

  private static async Task<OriginalRuntimeBuildRow?> ResolveOriginalRuntimeBuildAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      PrivateServerDomain.OriginalClientRuntimeBuildBinding binding,
      CancellationToken cancellationToken)
  {
    if (binding.Status == PrivateServerDomain.ExecutionFactStatus.Unresolved)
    {
      return null;
    }

    await using var command = new NpgsqlCommand(
        """
        SELECT runtime.client_runtime_build_id,
               runtime.source_artifact_id
        FROM lab_raid.client_runtime_build runtime
        JOIN lab_import.source_artifact artifact
          ON artifact.source_artifact_id = runtime.source_artifact_id
        WHERE runtime.client_runtime_build_uid = @runtime_build_uid
          AND artifact.content_sha256 = @runtime_build_sha256;
        """,
        connection,
        transaction);
    ProfileAdd(command, "runtime_build_uid", NpgsqlDbType.Uuid, binding.BuildUid?.Value);
    ProfileAdd(
        command,
        "runtime_build_sha256",
        NpgsqlDbType.Bytea,
        binding.BuildSha256?.ToByteArray());
    await using var reader = await command.ExecuteReaderAsync(cancellationToken)
        .ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      throw ProfileFailure(
          App.PrivateServerFailureKind.InvalidRequest,
          "original_client_runtime_build_not_found");
    }

    return new OriginalRuntimeBuildRow(reader.GetInt64(0), reader.GetInt64(1));
  }

  private static async Task InsertProfileFactsAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      string factTable,
      string revisionIdColumn,
      long revisionId,
      IReadOnlyList<ProfileFactWrite> facts,
      CancellationToken cancellationToken)
  {
    var sql = $"""
        INSERT INTO lab_private_server.{factTable} (
            {revisionIdColumn},
            field_code,
            requested_status,
            requested_value,
            requested_reason_code,
            effective_status,
            effective_value,
            effective_reason_code
        ) VALUES (
            @revision_id,
            @field_code,
            @requested_status,
            @requested_value,
            @requested_reason_code,
            @effective_status,
            @effective_value,
            @effective_reason_code
        );
        """;
    foreach (var fact in facts)
    {
      await using var command = new NpgsqlCommand(sql, connection, transaction);
      ProfileAdd(command, "revision_id", NpgsqlDbType.Bigint, revisionId);
      ProfileAdd(command, "field_code", NpgsqlDbType.Text, fact.FieldCode);
      ProfileAdd(command, "requested_status", NpgsqlDbType.Text, fact.Requested.Status);
      ProfileAdd(command, "requested_value", NpgsqlDbType.Text, fact.Requested.Value);
      ProfileAdd(command, "requested_reason_code", NpgsqlDbType.Text, fact.Requested.ReasonCode);
      ProfileAdd(command, "effective_status", NpgsqlDbType.Text, fact.Effective?.Status);
      ProfileAdd(command, "effective_value", NpgsqlDbType.Text, fact.Effective?.Value);
      ProfileAdd(command, "effective_reason_code", NpgsqlDbType.Text, fact.Effective?.ReasonCode);
      await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }
  }

  private static async Task<StoredRuntimeExecutionRevision?>
      ReadRuntimeExecutionRevisionRowAsync(
          NpgsqlConnection connection,
          NpgsqlTransaction? transaction,
          long accountId,
          EntityUid revisionUid,
          CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT revision.runtime_execution_profile_revision_id,
               profile.runtime_execution_profile_uid,
               revision.runtime_execution_profile_revision_uid,
               account.local_account_uid,
               revision.revision_number,
               predecessor.runtime_execution_profile_revision_uid,
               revision.schema_version,
               revision.original_runtime_build_status,
               revision.original_client_runtime_build_uid,
               revision.original_runtime_build_sha256,
               revision.original_runtime_build_unresolved_reason_code,
               revision.requested_payload::text,
               revision.effective_payload::text,
               revision.fact_count,
               revision.effective_snapshot_present,
               revision.harness_validation_ready,
               revision.original_client_launch_ready,
               revision.effective_readback_ready,
               revision.readiness_issue_code,
               revision.content_sha256,
               revision.materialized_at_utc
        FROM lab_private_server.runtime_execution_profile_revision revision
        JOIN lab_private_server.runtime_execution_profile profile
          ON profile.runtime_execution_profile_id = revision.runtime_execution_profile_id
        JOIN lab_profile.local_account account
          ON account.local_account_id = revision.local_account_id
        LEFT JOIN lab_private_server.runtime_execution_profile_revision predecessor
          ON predecessor.runtime_execution_profile_revision_id =
             revision.previous_runtime_execution_profile_revision_id
        WHERE revision.local_account_id = @account_id
          AND revision.runtime_execution_profile_revision_uid = @revision_uid;
        """,
        connection,
        transaction);
    ProfileAdd(command, "account_id", NpgsqlDbType.Bigint, accountId);
    ProfileAdd(command, "revision_uid", NpgsqlDbType.Uuid, revisionUid.Value);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken)
        .ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      return null;
    }

    return new StoredRuntimeExecutionRevision(
        reader.GetInt64(0),
        new EntityUid(reader.GetGuid(1)),
        new EntityUid(reader.GetGuid(2)),
        new EntityUid(reader.GetGuid(3)),
        reader.GetInt32(4),
        reader.IsDBNull(5) ? null : new EntityUid(reader.GetGuid(5)),
        reader.GetString(6),
        reader.GetString(7),
        reader.IsDBNull(8) ? null : new EntityUid(reader.GetGuid(8)),
        reader.IsDBNull(9) ? null : ReadProfileDigest(reader, 9),
        reader.IsDBNull(10) ? null : reader.GetString(10),
        reader.GetString(11),
        reader.IsDBNull(12) ? null : reader.GetString(12),
        reader.GetInt16(13),
        reader.GetBoolean(14),
        reader.GetBoolean(15),
        reader.GetBoolean(16),
        reader.GetBoolean(17),
        reader.IsDBNull(18) ? null : reader.GetString(18),
        ReadProfileDigest(reader, 19),
        NormalizeProfileTimestamp(reader.GetFieldValue<DateTimeOffset>(20)));
  }

  private static async Task<StoredCombatControlRevision?> ReadCombatControlRevisionRowAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      long accountId,
      EntityUid revisionUid,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT revision.combat_control_profile_revision_id,
               profile.combat_control_profile_uid,
               revision.combat_control_profile_revision_uid,
               account.local_account_uid,
               revision.revision_number,
               predecessor.combat_control_profile_revision_uid,
               revision.schema_version,
               revision.requested_payload::text,
               revision.effective_payload::text,
               revision.fact_count,
               revision.effective_snapshot_present,
               revision.manual_ready,
               revision.effective_manual_ready,
               revision.effective_readback_ready,
               revision.readiness_issue_code,
               revision.content_sha256,
               revision.materialized_at_utc
        FROM lab_private_server.combat_control_profile_revision revision
        JOIN lab_private_server.combat_control_profile profile
          ON profile.combat_control_profile_id = revision.combat_control_profile_id
        JOIN lab_profile.local_account account
          ON account.local_account_id = revision.local_account_id
        LEFT JOIN lab_private_server.combat_control_profile_revision predecessor
          ON predecessor.combat_control_profile_revision_id =
             revision.previous_combat_control_profile_revision_id
        WHERE revision.local_account_id = @account_id
          AND revision.combat_control_profile_revision_uid = @revision_uid;
        """,
        connection,
        transaction);
    ProfileAdd(command, "account_id", NpgsqlDbType.Bigint, accountId);
    ProfileAdd(command, "revision_uid", NpgsqlDbType.Uuid, revisionUid.Value);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken)
        .ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      return null;
    }

    return new StoredCombatControlRevision(
        reader.GetInt64(0),
        new EntityUid(reader.GetGuid(1)),
        new EntityUid(reader.GetGuid(2)),
        new EntityUid(reader.GetGuid(3)),
        reader.GetInt32(4),
        reader.IsDBNull(5) ? null : new EntityUid(reader.GetGuid(5)),
        reader.GetString(6),
        reader.GetString(7),
        reader.IsDBNull(8) ? null : reader.GetString(8),
        reader.GetInt16(9),
        reader.GetBoolean(10),
        reader.GetBoolean(11),
        reader.GetBoolean(12),
        reader.GetBoolean(13),
        reader.IsDBNull(14) ? null : reader.GetString(14),
        ReadProfileDigest(reader, 15),
        NormalizeProfileTimestamp(reader.GetFieldValue<DateTimeOffset>(16)));
  }

  private static async Task<IReadOnlyList<StoredProfileFact>> ReadProfileFactsAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      string factTable,
      string revisionIdColumn,
      long revisionId,
      CancellationToken cancellationToken)
  {
    var sql = $"""
        SELECT field_code,
               requested_status,
               requested_value,
               requested_reason_code,
               effective_status,
               effective_value,
               effective_reason_code
        FROM lab_private_server.{factTable}
        WHERE {revisionIdColumn} = @revision_id
        ORDER BY field_code;
        """;
    await using var command = new NpgsqlCommand(sql, connection, transaction);
    ProfileAdd(command, "revision_id", NpgsqlDbType.Bigint, revisionId);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken)
        .ConfigureAwait(false);
    var facts = new List<StoredProfileFact>();
    while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      facts.Add(new StoredProfileFact(
          reader.GetString(0),
          reader.GetString(1),
          reader.IsDBNull(2) ? null : reader.GetString(2),
          reader.IsDBNull(3) ? null : reader.GetString(3),
          reader.IsDBNull(4) ? null : reader.GetString(4),
          reader.IsDBNull(5) ? null : reader.GetString(5),
          reader.IsDBNull(6) ? null : reader.GetString(6)));
    }

    return facts;
  }

  private static PrivateServerDomain.RuntimeExecutionSettingsSnapshot MaterializeRuntimeSettings(
      IReadOnlyList<StoredProfileFact> facts,
      bool useEffective)
  {
    if (facts.Count != 21 ||
        facts.Select(static fact => fact.FieldCode)
            .Distinct(StringComparer.Ordinal)
            .Count() != facts.Count)
    {
      throw ProfileFailure(
          App.PrivateServerFailureKind.Unavailable,
          "runtime_execution_profile_fact_set_invalid");
    }

    var indexed = facts.ToDictionary(static fact => fact.FieldCode, StringComparer.Ordinal);
    var scheduler = new PrivateServerDomain.RuntimeSchedulerSettings(
        ReadStoredFact(
            RequireStoredFact(indexed, "target_fps"),
            useEffective,
            static value => ParseTargetFrameRate(value)),
        ReadStoredFact(
            RequireStoredFact(indexed, "fixed_delta_denominator"),
            useEffective,
            static value => ParseInt32(value)),
        ReadStoredFact(
            RequireStoredFact(indexed, "vsync_enabled"),
            useEffective,
            static value => ParseBoolean(value)),
        ReadStoredFact(
            RequireStoredFact(indexed, "multiplayer_enabled"),
            useEffective,
            static value => ParseBoolean(value)),
        ReadStoredFact(
            RequireStoredFact(indexed, "time_scale"),
            useEffective,
            static value => ParseTimeScale(value)));
    var display = new PrivateServerDomain.RuntimeDisplaySettings(
        ReadStoredCodeFact(RequireStoredFact(indexed, "platform"), useEffective),
        ReadStoredCodeFact(RequireStoredFact(indexed, "display_mode"), useEffective),
        ReadStoredFact(
            RequireStoredFact(indexed, "display_width"),
            useEffective,
            static value => ParseInt32(value)),
        ReadStoredFact(
            RequireStoredFact(indexed, "display_height"),
            useEffective,
            static value => ParseInt32(value)),
        ReadStoredFact(
            RequireStoredFact(indexed, "effective_refresh_rate"),
            useEffective,
            static value => ParseDecimal(value)));
    var graphics = new PrivateServerDomain.RuntimeGraphicsSettings(RuntimeGraphicsFieldCodes.Select(
        fieldCode => new PrivateServerDomain.RuntimeGraphicsOption(
            fieldCode,
            ReadStoredCodeFact(RequireStoredFact(indexed, fieldCode), useEffective))));
    return new PrivateServerDomain.RuntimeExecutionSettingsSnapshot(scheduler, display, graphics);
  }

  private static PrivateServerDomain.CombatControlSettingsSnapshot MaterializeCombatControlSettings(
      IReadOnlyList<StoredProfileFact> facts,
      bool useEffective)
  {
    if (facts.Count != 7 ||
        facts.Select(static fact => fact.FieldCode)
            .Distinct(StringComparer.Ordinal)
            .Count() != facts.Count)
    {
      throw ProfileFailure(
          App.PrivateServerFailureKind.Unavailable,
          "combat_control_profile_fact_set_invalid");
    }

    var indexed = facts.ToDictionary(static fact => fact.FieldCode, StringComparer.Ordinal);
    return new PrivateServerDomain.CombatControlSettingsSnapshot(
        ReadStoredFact(
            RequireStoredFact(indexed, "aim_sensitivity"),
            useEffective,
            static value => ParseDecimal(value)),
        ReadStoredFact(
            RequireStoredFact(indexed, "use_aim_assistant"),
            useEffective,
            static value => ParseBoolean(value)),
        ReadStoredFact(
            RequireStoredFact(indexed, "aim_assistant_intensity"),
            useEffective,
            static value => ParseDecimal(value)),
        ReadStoredFact(
            RequireStoredFact(indexed, "use_pc_aim_sync"),
            useEffective,
            static value => ParseBoolean(value)),
        ReadStoredFact(
            RequireStoredFact(indexed, "max_per_shot_correct"),
            useEffective,
            static value => ParseBoolean(value)),
        ReadStoredFact(
            RequireStoredFact(indexed, "auto_combat"),
            useEffective,
            static value => ParseBoolean(value)),
        ReadStoredFact(
            RequireStoredFact(indexed, "auto_burst"),
            useEffective,
            static value => ParseBoolean(value)));
  }

  private static StoredProfileFact RequireStoredFact(
      IReadOnlyDictionary<string, StoredProfileFact> facts,
      string fieldCode)
  {
    if (!facts.TryGetValue(fieldCode, out var fact))
    {
      throw ProfileFailure(
          App.PrivateServerFailureKind.Unavailable,
          "private_server_profile_fact_set_invalid");
    }

    return fact;
  }

  private static PrivateServerDomain.ExecutionFact<T> ReadStoredFact<T>(
      StoredProfileFact fact,
      bool useEffective,
      Func<string, T> parse)
      where T : struct
  {
    var status = useEffective ? fact.EffectiveStatus : fact.RequestedStatus;
    var value = useEffective ? fact.EffectiveValue : fact.RequestedValue;
    var reasonCode = useEffective ? fact.EffectiveReasonCode : fact.RequestedReasonCode;
    return status switch
    {
      "ready" when value is not null && reasonCode is null =>
          PrivateServerDomain.ExecutionFact<T>.Ready(parse(value)),
      "unresolved" when value is null && reasonCode is not null =>
          PrivateServerDomain.ExecutionFact<T>.Unresolved(reasonCode),
      "not_applicable" when value is null && reasonCode is null =>
          PrivateServerDomain.ExecutionFact<T>.NotApplicable(),
      _ => throw ProfileFailure(
          App.PrivateServerFailureKind.Unavailable,
          "private_server_profile_fact_shape_invalid")
    };
  }

  private static PrivateServerDomain.ExecutionCodeFact ReadStoredCodeFact(
      StoredProfileFact fact,
      bool useEffective)
  {
    var status = useEffective ? fact.EffectiveStatus : fact.RequestedStatus;
    var value = useEffective ? fact.EffectiveValue : fact.RequestedValue;
    var reasonCode = useEffective ? fact.EffectiveReasonCode : fact.RequestedReasonCode;
    return status switch
    {
      "ready" when value is not null && reasonCode is null =>
          PrivateServerDomain.ExecutionCodeFact.Ready(value),
      "unresolved" when value is null && reasonCode is not null =>
          PrivateServerDomain.ExecutionCodeFact.Unresolved(reasonCode),
      "not_applicable" when value is null && reasonCode is null =>
          PrivateServerDomain.ExecutionCodeFact.NotApplicable(),
      _ => throw ProfileFailure(
          App.PrivateServerFailureKind.Unavailable,
          "private_server_profile_fact_shape_invalid")
    };
  }

  private static IReadOnlyList<ProfileFactWrite> BuildRuntimeFacts(
      PrivateServerDomain.RuntimeExecutionSettingsSnapshot requested,
      PrivateServerDomain.RuntimeExecutionSettingsSnapshot? effective)
  {
    var requestedGraphics = requested.Graphics.Options.ToDictionary(
        static option => option.FieldCode,
        static option => option.Value,
        StringComparer.Ordinal);
    var effectiveGraphics = effective?.Graphics.Options.ToDictionary(
        static option => option.FieldCode,
        static option => option.Value,
        StringComparer.Ordinal);
    var facts = new List<ProfileFactWrite>(21)
    {
      BuildProfileFact(
          "platform",
          requested.Display.Platform,
          effective?.Display.Platform),
      BuildProfileFact(
          "target_fps",
          requested.Scheduler.TargetFrameRate,
          effective?.Scheduler.TargetFrameRate,
          static value => ((int)value).ToString(CultureInfo.InvariantCulture)),
      BuildProfileFact(
          "fixed_delta_denominator",
          requested.Scheduler.FixedDeltaDenominator,
          effective?.Scheduler.FixedDeltaDenominator,
          static value => value.ToString(CultureInfo.InvariantCulture)),
      BuildProfileFact(
          "vsync_enabled",
          requested.Scheduler.VsyncEnabled,
          effective?.Scheduler.VsyncEnabled,
          static value => FormatBoolean(value)),
      BuildProfileFact(
          "multiplayer_enabled",
          requested.Scheduler.MultiplayerEnabled,
          effective?.Scheduler.MultiplayerEnabled,
          static value => FormatBoolean(value)),
      BuildProfileFact(
          "time_scale",
          requested.Scheduler.TimeScale,
          effective?.Scheduler.TimeScale,
          static value => PrivateServerDomain.RuntimeExecutionSettingsSnapshot.TimeScaleCode(value)),
      BuildProfileFact(
          "display_mode",
          requested.Display.DisplayMode,
          effective?.Display.DisplayMode),
      BuildProfileFact(
          "display_width",
          requested.Display.Width,
          effective?.Display.Width,
          static value => value.ToString(CultureInfo.InvariantCulture)),
      BuildProfileFact(
          "display_height",
          requested.Display.Height,
          effective?.Display.Height,
          static value => value.ToString(CultureInfo.InvariantCulture)),
      BuildProfileFact(
          "effective_refresh_rate",
          requested.Display.RefreshRateHz,
          effective?.Display.RefreshRateHz,
          static value => value.ToString("G29", CultureInfo.InvariantCulture))
    };
    foreach (var fieldCode in RuntimeGraphicsFieldCodes)
    {
      facts.Add(BuildProfileFact(
          fieldCode,
          requestedGraphics[fieldCode],
          effectiveGraphics is null ? null : effectiveGraphics[fieldCode]));
    }

    return facts;
  }

  private static IReadOnlyList<ProfileFactWrite> BuildControlFacts(
      PrivateServerDomain.CombatControlSettingsSnapshot requested,
      PrivateServerDomain.CombatControlSettingsSnapshot? effective) =>
  [
    BuildProfileFact(
        "aim_sensitivity",
        requested.AimSensitivity,
        effective?.AimSensitivity,
        static value => value.ToString("G29", CultureInfo.InvariantCulture)),
    BuildProfileFact(
        "use_aim_assistant",
        requested.UseAimAssistant,
        effective?.UseAimAssistant,
        static value => FormatBoolean(value)),
    BuildProfileFact(
        "aim_assistant_intensity",
        requested.AimAssistantIntensity,
        effective?.AimAssistantIntensity,
        static value => value.ToString("G29", CultureInfo.InvariantCulture)),
    BuildProfileFact(
        "use_pc_aim_sync",
        requested.UsePcAimSync,
        effective?.UsePcAimSync,
        static value => FormatBoolean(value)),
    BuildProfileFact(
        "max_per_shot_correct",
        requested.MaxPerShotCorrect,
        effective?.MaxPerShotCorrect,
        static value => FormatBoolean(value)),
    BuildProfileFact(
        "auto_combat",
        requested.AutoCombat,
        effective?.AutoCombat,
        static value => FormatBoolean(value)),
    BuildProfileFact(
        "auto_burst",
        requested.AutoBurst,
        effective?.AutoBurst,
        static value => FormatBoolean(value))
  ];

  private static ProfileFactWrite BuildProfileFact<T>(
      string fieldCode,
      PrivateServerDomain.ExecutionFact<T> requested,
      PrivateServerDomain.ExecutionFact<T>? effective,
      Func<T, string> format)
      where T : struct =>
      new(
          fieldCode,
          BuildProfileFactValue(requested, format),
          effective is null ? null : BuildProfileFactValue(effective, format));

  private static ProfileFactWrite BuildProfileFact(
      string fieldCode,
      PrivateServerDomain.ExecutionCodeFact requested,
      PrivateServerDomain.ExecutionCodeFact? effective) =>
      new(
          fieldCode,
          BuildProfileFactValue(requested),
          effective is null ? null : BuildProfileFactValue(effective));

  private static ProfileFactValue BuildProfileFactValue<T>(
      PrivateServerDomain.ExecutionFact<T> fact,
      Func<T, string> format)
      where T : struct =>
      new(
          FactStatusCode(fact.Status),
          fact.Value.HasValue ? format(fact.Value.Value) : null,
          fact.ReasonCode);

  private static ProfileFactValue BuildProfileFactValue(PrivateServerDomain.ExecutionCodeFact fact) =>
      new(FactStatusCode(fact.Status), fact.ValueCode, fact.ReasonCode);

  private static void RequireStoredFactsMatchCanonical(
      IReadOnlyList<StoredProfileFact> storedFacts,
      IReadOnlyList<ProfileFactWrite> canonicalFacts,
      string errorCode)
  {
    var stored = storedFacts
        .OrderBy(static fact => fact.FieldCode, StringComparer.Ordinal)
        .ToArray();
    var canonical = canonicalFacts
        .OrderBy(static fact => fact.FieldCode, StringComparer.Ordinal)
        .ToArray();
    if (stored.Length != canonical.Length)
    {
      throw ProfileFailure(App.PrivateServerFailureKind.Unavailable, errorCode);
    }

    for (var index = 0; index < stored.Length; index++)
    {
      var actual = stored[index];
      var expected = canonical[index];
      if (!string.Equals(actual.FieldCode, expected.FieldCode, StringComparison.Ordinal) ||
          !ProfileFactValueMatches(
              actual.RequestedStatus,
              actual.RequestedValue,
              actual.RequestedReasonCode,
              expected.Requested) ||
          !ProfileFactValueMatches(
              actual.EffectiveStatus,
              actual.EffectiveValue,
              actual.EffectiveReasonCode,
              expected.Effective))
      {
        throw ProfileFailure(App.PrivateServerFailureKind.Unavailable, errorCode);
      }
    }
  }

  private static bool ProfileFactValueMatches(
      string? status,
      string? value,
      string? reasonCode,
      ProfileFactValue? expected) =>
      string.Equals(status, expected?.Status, StringComparison.Ordinal) &&
      string.Equals(value, expected?.Value, StringComparison.Ordinal) &&
      string.Equals(reasonCode, expected?.ReasonCode, StringComparison.Ordinal);

  private static void RequireEffectivePayloadMatchesCanonical(
      string? storedPayload,
      bool effectiveSnapshotPresent,
      string contractId,
      IReadOnlyList<ProfileFactWrite> canonicalFacts,
      string errorCode)
  {
    if (effectiveSnapshotPresent != (storedPayload is not null))
    {
      throw ProfileFailure(App.PrivateServerFailureKind.Unavailable, errorCode);
    }

    if (storedPayload is not null)
    {
      RequireProfilePayloadMatchesCanonical(
          storedPayload,
          contractId,
          canonicalFacts,
          useEffective: true,
          errorCode);
    }
  }

  private static void RequireProfilePayloadMatchesCanonical(
      string storedPayload,
      string contractId,
      IReadOnlyList<ProfileFactWrite> canonicalFacts,
      bool useEffective,
      string errorCode)
  {
    JsonDocument document;
    try
    {
      document = JsonDocument.Parse(storedPayload);
    }
    catch (JsonException exception)
    {
      throw ProfileFailure(App.PrivateServerFailureKind.Unavailable, errorCode, exception);
    }

    using (document)
    {
      var root = document.RootElement;
      if (!HasExactJsonProperties(root, "ContractId", "Facts") ||
          !root.TryGetProperty("ContractId", out var storedContract) ||
          storedContract.ValueKind != JsonValueKind.String ||
          !string.Equals(storedContract.GetString(), contractId, StringComparison.Ordinal) ||
          !root.TryGetProperty("Facts", out var storedFacts) ||
          storedFacts.ValueKind != JsonValueKind.Array)
      {
        throw ProfileFailure(App.PrivateServerFailureKind.Unavailable, errorCode);
      }

      var expectedFacts = canonicalFacts
          .OrderBy(static fact => fact.FieldCode, StringComparer.Ordinal)
          .ToArray();
      var actualFacts = storedFacts.EnumerateArray().ToArray();
      if (actualFacts.Length != expectedFacts.Length)
      {
        throw ProfileFailure(App.PrivateServerFailureKind.Unavailable, errorCode);
      }

      for (var index = 0; index < actualFacts.Length; index++)
      {
        var actual = actualFacts[index];
        var expectedFact = expectedFacts[index];
        var expectedValue = useEffective
            ? expectedFact.Effective ?? throw ProfileFailure(
                App.PrivateServerFailureKind.Unavailable,
                errorCode)
            : expectedFact.Requested;
        if (!HasExactJsonProperties(
                actual,
                "FieldCode",
                "Status",
                "Value",
                "ReasonCode") ||
            !JsonStringMatches(actual, "FieldCode", expectedFact.FieldCode) ||
            !JsonStringMatches(actual, "Status", expectedValue.Status) ||
            !JsonStringMatches(actual, "Value", expectedValue.Value) ||
            !JsonStringMatches(actual, "ReasonCode", expectedValue.ReasonCode))
        {
          throw ProfileFailure(App.PrivateServerFailureKind.Unavailable, errorCode);
        }
      }
    }
  }

  private static bool HasExactJsonProperties(
      JsonElement element,
      params string[] expectedNames)
  {
    if (element.ValueKind != JsonValueKind.Object)
    {
      return false;
    }

    var actualNames = element.EnumerateObject()
        .Select(static property => property.Name)
        .ToArray();
    return actualNames.Length == expectedNames.Length &&
        actualNames.Distinct(StringComparer.Ordinal).Count() == actualNames.Length &&
        expectedNames.All(expectedName =>
            actualNames.Contains(expectedName, StringComparer.Ordinal));
  }

  private static bool JsonStringMatches(
      JsonElement element,
      string propertyName,
      string? expected)
  {
    if (!element.TryGetProperty(propertyName, out var property))
    {
      return false;
    }

    return expected is null
        ? property.ValueKind == JsonValueKind.Null
        : property.ValueKind == JsonValueKind.String &&
            string.Equals(property.GetString(), expected, StringComparison.Ordinal);
  }

  private static string SerializeProfilePayload(
      string contractId,
      IReadOnlyList<ProfileFactWrite> facts,
      bool useEffective)
  {
    var payloadFacts = facts
        .OrderBy(static fact => fact.FieldCode, StringComparer.Ordinal)
        .Select(fact =>
        {
          var value = useEffective
              ? fact.Effective ?? throw ProfileFailure(
                  App.PrivateServerFailureKind.Unavailable,
                  "private_server_profile_effective_fact_missing")
              : fact.Requested;
          return new ProfilePayloadFact(
              fact.FieldCode,
              value.Status,
              value.Value,
              value.ReasonCode);
        })
        .ToArray();
    return JsonSerializer.Serialize(new ProfileSettingsPayload(contractId, payloadFacts));
  }

  private static T? ReadyValue<T>(PrivateServerDomain.ExecutionFact<T> fact)
      where T : struct =>
      fact.Status == PrivateServerDomain.ExecutionFactStatus.Ready ? fact.Value : null;

  private static string? ReadyCode(PrivateServerDomain.ExecutionCodeFact fact) =>
      fact.Status == PrivateServerDomain.ExecutionFactStatus.Ready ? fact.ValueCode : null;

  private static void AddProjectedControlFact(
      NpgsqlCommand command,
      string prefix,
      PrivateServerDomain.ExecutionFact<bool> fact)
  {
    ProfileAdd(command, $"{prefix}_status", NpgsqlDbType.Text, FactStatusCode(fact.Status));
    ProfileAdd(
        command,
        $"{prefix}_value",
        NpgsqlDbType.Boolean,
        ReadyValue(fact));
    ProfileAdd(
        command,
        $"{prefix}_reason_code",
        NpgsqlDbType.Text,
        fact.ReasonCode);
  }

  private static string FactStatusCode(PrivateServerDomain.ExecutionFactStatus status) =>
      PrivateServerDomain.RuntimeExecutionSettingsSnapshot.FactStatusCode(status);

  private static string FormatBoolean(bool value) => value ? "true" : "false";

  private static bool ParseBoolean(string value) => value switch
  {
    "true" => true,
    "false" => false,
    _ => throw ProfileFailure(
        App.PrivateServerFailureKind.Unavailable,
        "private_server_profile_boolean_invalid")
  };

  private static int ParseInt32(string value)
  {
    if (!int.TryParse(
        value,
        NumberStyles.AllowLeadingSign,
        CultureInfo.InvariantCulture,
        out var parsed))
    {
      throw ProfileFailure(
          App.PrivateServerFailureKind.Unavailable,
          "private_server_profile_integer_invalid");
    }

    return parsed;
  }

  private static decimal ParseDecimal(string value)
  {
    if (!decimal.TryParse(
        value,
        NumberStyles.Number | NumberStyles.AllowExponent,
        CultureInfo.InvariantCulture,
        out var parsed))
    {
      throw ProfileFailure(
          App.PrivateServerFailureKind.Unavailable,
          "private_server_profile_decimal_invalid");
    }

    return parsed;
  }

  private static PrivateServerDomain.TargetFrameRate ParseTargetFrameRate(string value) =>
      ParseInt32(value) switch
      {
        30 => PrivateServerDomain.TargetFrameRate.Fps30,
        60 => PrivateServerDomain.TargetFrameRate.Fps60,
        _ => throw ProfileFailure(
            App.PrivateServerFailureKind.Unavailable,
            "private_server_profile_target_fps_invalid")
      };

  private static PrivateServerDomain.TimeScalePolicy ParseTimeScale(string value) => value switch
  {
    "normal_1x" => PrivateServerDomain.TimeScalePolicy.NormalOneX,
    _ => throw ProfileFailure(
        App.PrivateServerFailureKind.Unavailable,
        "private_server_profile_time_scale_invalid")
  };

  private static void RequireRuntimeReplayBinding(
      PrivateServerProfileOperationRow replay,
      App.SaveRuntimeExecutionProfileCommand command,
      PrivateServerDomain.RuntimeExecutionProfileRevision revision)
  {
    if (replay.ExpectedRevisionUid != command.ExpectedCurrentRevisionUid ||
        replay.ResultEntityUid != command.ProfileUid ||
        replay.ResultRevisionUid != revision.RevisionUid ||
        replay.ResultContentSha256 != revision.ContentSha256 ||
        revision.ProfileUid != command.ProfileUid ||
        revision.AccountUid != command.AccountUid ||
        revision.ContentSha256 != command.Content.ContentSha256)
    {
      throw ProfileFailure(
          App.PrivateServerFailureKind.Conflict,
          "private_server_operation_reuse_mismatch");
    }
  }

  private static void RequireControlReplayBinding(
      PrivateServerProfileOperationRow replay,
      App.SaveCombatControlProfileCommand command,
      PrivateServerDomain.CombatControlProfileRevision revision)
  {
    if (replay.ExpectedRevisionUid != command.ExpectedCurrentRevisionUid ||
        replay.ResultEntityUid != command.ProfileUid ||
        replay.ResultRevisionUid != revision.RevisionUid ||
        replay.ResultContentSha256 != revision.ContentSha256 ||
        revision.ProfileUid != command.ProfileUid ||
        revision.AccountUid != command.AccountUid ||
        revision.ContentSha256 != command.Content.ContentSha256)
    {
      throw ProfileFailure(
          App.PrivateServerFailureKind.Conflict,
          "private_server_operation_reuse_mismatch");
    }
  }

  private static void RequireProfileCommand(
      EntityUid operationUid,
      EntityUid accountUid,
      EntityUid profileUid,
      EntityUid? expectedRevisionUid)
  {
    if (operationUid.Value == Guid.Empty ||
        accountUid.Value == Guid.Empty ||
        profileUid.Value == Guid.Empty ||
        (expectedRevisionUid.HasValue && expectedRevisionUid.Value.Value == Guid.Empty))
    {
      throw ProfileFailure(
          App.PrivateServerFailureKind.InvalidRequest,
          "private_server_profile_command_invalid");
    }
  }

  private static DateTimeOffset NormalizeProfileTimestamp(DateTimeOffset value)
  {
    if (value == default)
    {
      throw ProfileFailure(
          App.PrivateServerFailureKind.InvalidRequest,
          "private_server_profile_timestamp_invalid");
    }

    var utc = value.ToUniversalTime();
    return new DateTimeOffset(utc.Ticks - (utc.Ticks % 10), TimeSpan.Zero);
  }

  private static Sha256Digest ComputeProfileRequestSha256(
      string operationKind,
      EntityUid accountUid,
      EntityUid profileUid,
      EntityUid? expectedRevisionUid,
      Sha256Digest contentSha256) =>
      RequestHash(
          "nll/private-server-profile-save-request/v1",
          operationKind,
          accountUid,
          profileUid,
          expectedRevisionUid,
          contentSha256);

  private static Sha256Digest ReadProfileDigest(NpgsqlDataReader reader, int ordinal)
  {
    try
    {
      return Sha256Digest.FromBytes(reader.GetFieldValue<byte[]>(ordinal));
    }
    catch (ArgumentException)
    {
      throw ProfileFailure(
          App.PrivateServerFailureKind.Unavailable,
          "private_server_profile_digest_invalid");
    }
  }

  private static void ProfileAdd(
      NpgsqlCommand command,
      string name,
      NpgsqlDbType type,
      object? value) =>
      command.Parameters.Add(new NpgsqlParameter(name, type)
      {
        Value = value ?? DBNull.Value
      });

  private static App.PrivateServerApplicationException MapPrivateServerProfileDatabaseException(
      PostgresException exception) =>
      MapDatabaseException(exception);

  private static App.PrivateServerApplicationException ProfileFailure(
      App.PrivateServerFailureKind kind,
      string code,
      Exception? exception = null)
  {
    _ = exception;
    return new App.PrivateServerApplicationException(kind, code);
  }

  private sealed record PrivateServerProfileHead(
      long ProfileId,
      EntityUid ProfileUid,
      long RevisionId,
      EntityUid RevisionUid);

  private sealed record PrivateServerProfileOperationRow(
      long AccountId,
      EntityUid? ExpectedRevisionUid,
      EntityUid ResultEntityUid,
      EntityUid ResultRevisionUid,
      Sha256Digest ResultContentSha256);

  private sealed record OriginalRuntimeBuildRow(long BuildId, long SourceArtifactId);

  private sealed record StoredRuntimeExecutionRevision(
      long RevisionId,
      EntityUid ProfileUid,
      EntityUid RevisionUid,
      EntityUid AccountUid,
      long RevisionNumber,
      EntityUid? PredecessorRevisionUid,
      string SchemaVersion,
      string OriginalRuntimeBuildStatus,
      EntityUid? OriginalRuntimeBuildUid,
      Sha256Digest? OriginalRuntimeBuildSha256,
      string? OriginalRuntimeBuildReasonCode,
      string RequestedPayload,
      string? EffectivePayload,
      short FactCount,
      bool EffectiveSnapshotPresent,
      bool HarnessValidationReady,
      bool OriginalClientLaunchReady,
      bool EffectiveReadbackReady,
      string? ReadinessIssueCode,
      Sha256Digest ContentSha256,
      DateTimeOffset MaterializedAtUtc);

  private sealed record StoredCombatControlRevision(
      long RevisionId,
      EntityUid ProfileUid,
      EntityUid RevisionUid,
      EntityUid AccountUid,
      long RevisionNumber,
      EntityUid? PredecessorRevisionUid,
      string SchemaVersion,
      string RequestedPayload,
      string? EffectivePayload,
      short FactCount,
      bool EffectiveSnapshotPresent,
      bool ManualReady,
      bool EffectiveManualReady,
      bool EffectiveReadbackReady,
      string? ReadinessIssueCode,
      Sha256Digest ContentSha256,
      DateTimeOffset MaterializedAtUtc);

  private sealed record StoredProfileFact(
      string FieldCode,
      string RequestedStatus,
      string? RequestedValue,
      string? RequestedReasonCode,
      string? EffectiveStatus,
      string? EffectiveValue,
      string? EffectiveReasonCode);

  private sealed record ProfileFactValue(
      string Status,
      string? Value,
      string? ReasonCode);

  private sealed record ProfileFactWrite(
      string FieldCode,
      ProfileFactValue Requested,
      ProfileFactValue? Effective);

  private sealed record ProfileSettingsPayload(
      string ContractId,
      IReadOnlyList<ProfilePayloadFact> Facts);

  private sealed record ProfilePayloadFact(
      string FieldCode,
      string Status,
      string? Value,
      string? ReasonCode);
}
