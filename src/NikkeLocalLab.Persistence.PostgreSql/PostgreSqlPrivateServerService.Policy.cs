using App = NikkeLocalLab.Application.PrivateServer;
using PrivateServerDomain = global::NikkeLocalLab.Domain.PrivateServer;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;
using Npgsql;
using NpgsqlTypes;

namespace NikkeLocalLab.Persistence.PostgreSql;

public sealed partial class PostgreSqlPrivateServerService
{
  public async Task<App.ChallengeOperationalPolicyProjection>
      PublishChallengeOperationalPolicyAsync(
          App.PublishChallengeOperationalPolicyCommand command,
          CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(command);
    ArgumentNullException.ThrowIfNull(command.Policy);
    var requestHash = RequestHash(
        "nll/private-server/publish-policy-request/v1",
        command.Policy.PolicyUid,
        command.Policy.ContentSha256);
    try
    {
      await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
          .ConfigureAwait(false);
      var replay = await LoadWriteOperationAsync(
          connection,
          transaction: null,
          command.OperationUid,
          cancellationToken).ConfigureAwait(false);
      if (replay is not null)
      {
        RequireReplay(replay, "publish_operational_policy", requestHash);
        var storedReplay = await LoadPolicyByUidAsync(
            connection,
            transaction: null,
            replay.ResultEntityUid,
            cancellationToken).ConfigureAwait(false) ??
            throw Failure(App.PrivateServerFailureKind.Unavailable, "challenge_policy_replay_not_found");
        RequirePolicyPublicationReplayBinding(replay, command.Policy, storedReplay);
        return await ProjectPolicyAtAsync(
            connection,
            transaction: null,
            storedReplay,
            replay.CompletedAtUtc,
            cancellationToken).ConfigureAwait(false);
      }

      await using var transaction = await connection.BeginTransactionAsync(
          WriteIsolation,
          cancellationToken).ConfigureAwait(false);
      replay = await LoadWriteOperationAsync(
          connection,
          transaction,
          command.OperationUid,
          cancellationToken).ConfigureAwait(false);
      if (replay is not null)
      {
        RequireReplay(replay, "publish_operational_policy", requestHash);
        var storedReplay = await LoadPolicyByUidAsync(
            connection,
            transaction,
            replay.ResultEntityUid,
            cancellationToken).ConfigureAwait(false) ??
            throw Failure(App.PrivateServerFailureKind.Unavailable, "challenge_policy_replay_not_found");
        RequirePolicyPublicationReplayBinding(replay, command.Policy, storedReplay);
        await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
        return await ProjectPolicyAtAsync(
            connection,
            transaction: null,
            storedReplay,
            replay.CompletedAtUtc,
            cancellationToken).ConfigureAwait(false);
      }

      var published = NormalizeInstant(command.PublishedAtUtc);
      var stored = await InsertPolicyAsync(
          connection,
          transaction,
          command.Policy,
          published,
          command.OperationUid,
          cancellationToken,
          requestHash).ConfigureAwait(false);
      await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
      return new App.ChallengeOperationalPolicyProjection(
          stored.Policy,
          stored.PublishedAtUtc,
          false,
          null);
    }
    catch (PostgresException exception)
    {
      throw MapDatabaseException(exception);
    }
    catch (NpgsqlException exception)
    {
      throw MapDatabaseException(exception);
    }
  }

  public async Task<App.ChallengePolicyStateProjection> GetChallengeOperationalPolicyAsync(
      App.ChallengePolicyStateQuery query,
      CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(query);
    try
    {
      await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
          .ConfigureAwait(false);
      return await LoadPolicyStateAsync(
          connection,
          transaction: null,
          NormalizeInstant(query.ObservedAtUtc),
          headRevisionId: null,
          cancellationToken).ConfigureAwait(false);
    }
    catch (PostgresException exception)
    {
      throw MapDatabaseException(exception);
    }
    catch (NpgsqlException exception)
    {
      throw MapDatabaseException(exception);
    }
  }

  public async Task<App.ChallengePolicyStateProjection>
      ActivateChallengeOperationalPolicyAsync(
          App.ActivateChallengeOperationalPolicyCommand command,
          CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(command);
    var requestHash = RequestHash(
        "nll/private-server/activate-policy-request/v1",
        command.PolicyUid,
        command.ExpectedPolicySha256,
        command.EffectiveRaidDayKey,
        command.ExpectedActivationRevisionUid);
    try
    {
      await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
          .ConfigureAwait(false);
      var replay = await LoadWriteOperationAsync(
          connection,
          transaction: null,
          command.OperationUid,
          cancellationToken).ConfigureAwait(false);
      if (replay is not null)
      {
        RequireReplay(replay, "schedule_operational_policy", requestHash);
        var replayActivation = await LoadActivationByRevisionUidAsync(
            connection,
            transaction: null,
            replay.ResultRevisionUid ??
                throw Failure(App.PrivateServerFailureKind.Unavailable, "policy_activation_replay_invalid"),
            cancellationToken).ConfigureAwait(false);
        RequirePolicyActivationReplayBinding(replay, command, replayActivation.Revision);
        return await LoadPolicyStateAsync(
            connection,
            transaction: null,
            replay.CompletedAtUtc,
            replayActivation.Id,
            cancellationToken).ConfigureAwait(false);
      }

      await using var transaction = await connection.BeginTransactionAsync(
          WriteIsolation,
          cancellationToken).ConfigureAwait(false);
      await TakeBootstrapLockAsync(connection, transaction, cancellationToken)
          .ConfigureAwait(false);
      replay = await LoadWriteOperationAsync(
          connection,
          transaction,
          command.OperationUid,
          cancellationToken).ConfigureAwait(false);
      if (replay is not null)
      {
        RequireReplay(replay, "schedule_operational_policy", requestHash);
        var replayActivation = await LoadActivationByRevisionUidAsync(
            connection,
            transaction,
            replay.ResultRevisionUid ??
                throw Failure(App.PrivateServerFailureKind.Unavailable, "policy_activation_replay_invalid"),
            cancellationToken).ConfigureAwait(false);
        RequirePolicyActivationReplayBinding(replay, command, replayActivation.Revision);
        await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
        return await LoadPolicyStateAsync(
            connection,
            transaction: null,
            replay.CompletedAtUtc,
            replayActivation.Id,
            cancellationToken).ConfigureAwait(false);
      }

      var observed = NormalizeInstant(command.ObservedAtUtc);
      var policy = await LoadPolicyByUidAsync(
          connection,
          transaction,
          command.PolicyUid,
          cancellationToken).ConfigureAwait(false) ??
          throw Failure(App.PrivateServerFailureKind.NotFound, "challenge_policy_not_found");
      if (policy.Policy.ContentSha256 != command.ExpectedPolicySha256)
      {
        throw Failure(App.PrivateServerFailureKind.Conflict, "challenge_policy_content_conflict");
      }

      var head = await LoadLatestActivationForUpdateAsync(
          connection,
          transaction,
          cancellationToken).ConfigureAwait(false) ??
          throw Failure(App.PrivateServerFailureKind.Unavailable, "challenge_policy_activation_not_initialized");
      if (!command.ExpectedActivationRevisionUid.HasValue ||
          command.ExpectedActivationRevisionUid.Value != head.Revision.ActivationRevisionUid)
      {
        throw Failure(App.PrivateServerFailureKind.Conflict, "challenge_policy_activation_revision_conflict");
      }

      PrivateServerDomain.ChallengeOperationalPolicyActivationRevision next;
      try
      {
        next = head.Revision.Activate(
            _uidGenerator.NewUid(),
            policy.Policy,
            command.EffectiveRaidDayKey,
            observed,
            PrivateServerDomain.AsiaSeoulRaidDay.GetKey(observed));
      }
      catch (PrivateServerDomain.PrivateServerIntegrityException exception)
      {
        throw Failure(App.PrivateServerFailureKind.InvalidRequest, exception.Code);
      }

      if (next.ActivationRevisionUid == head.Revision.ActivationRevisionUid)
      {
        await InsertWriteOperationAsync(
            connection,
            transaction,
            command.OperationUid,
            "schedule_operational_policy",
            requestHash,
            null,
            command.ExpectedActivationRevisionUid,
            head.Revision.ActivationUid,
            head.Revision.ActivationRevisionUid,
            head.Revision.ContentSha256,
            observed,
            cancellationToken).ConfigureAwait(false);
        await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
        return await LoadPolicyStateAsync(
            connection,
            transaction: null,
            observed,
            head.Id,
            cancellationToken).ConfigureAwait(false);
      }

      var nextId = await InsertActivationRevisionAsync(
          connection,
          transaction,
          next,
          policy.Id,
          head.Id,
          cancellationToken).ConfigureAwait(false);
      const string updateState = """
          UPDATE lab_private_server.challenge_policy_state
             SET latest_scheduled_activation_revision_id = @id,
                 updated_at_utc = @updated
           WHERE singleton
          """;
      await using (var update = new NpgsqlCommand(updateState, connection, transaction))
      {
        Add(update, "id", NpgsqlDbType.Bigint, nextId);
        Add(update, "updated", NpgsqlDbType.TimestampTz, observed);
        _ = await update.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
      }

      var feature = await LoadFeatureManifestByContentAsync(
          connection,
          transaction,
          Phase2BFeatureManifest().ContentSha256,
          cancellationToken).ConfigureAwait(false) ??
          throw Failure(App.PrivateServerFailureKind.Unavailable, "phase2b_feature_manifest_not_found");
      var application = await LoadCurrentApplicationSelectionAsync(
          connection,
          transaction,
          cancellationToken).ConfigureAwait(false) ??
          throw Failure(App.PrivateServerFailureKind.Unavailable, "application_build_not_selected");
      var directory = await LoadDirectoryByContractAsync(
          connection,
          transaction,
          cancellationToken).ConfigureAwait(false) ??
          throw Failure(App.PrivateServerFailureKind.Unavailable, "raid_season_directory_not_found");
      var capability = await EnsureCapabilityManifestAsync(
          connection,
          transaction,
          feature,
          policy,
          observed,
          cancellationToken).ConfigureAwait(false);
      var storedNext = new StoredActivation(nextId, next);
      _ = await EnsureBootRevisionAsync(
          connection,
          transaction,
          application,
          directory,
          capability,
          policy,
          storedNext,
          observed,
          cancellationToken).ConfigureAwait(false);
      await InsertWriteOperationAsync(
          connection,
          transaction,
          command.OperationUid,
          "schedule_operational_policy",
          requestHash,
          null,
          command.ExpectedActivationRevisionUid,
          next.ActivationUid,
          next.ActivationRevisionUid,
          next.ContentSha256,
          observed,
          cancellationToken).ConfigureAwait(false);
      await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
      return await LoadPolicyStateAsync(
          connection,
          transaction: null,
          observed,
          nextId,
          cancellationToken).ConfigureAwait(false);
    }
    catch (PostgresException exception)
    {
      throw MapDatabaseException(exception);
    }
    catch (NpgsqlException exception)
    {
      throw MapDatabaseException(exception);
    }
  }

  private async Task<StoredPolicy> InsertPolicyAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      PrivateServerDomain.ChallengeOperationalPolicy policy,
      DateTimeOffset publishedAtUtc,
      EntityUid operationUid,
      CancellationToken cancellationToken,
      Sha256Digest? requestHash = null)
  {
    var existing = await LoadPolicyByUidAsync(
        connection,
        transaction,
        policy.PolicyUid,
        cancellationToken).ConfigureAwait(false);
    if (existing is not null)
    {
      if (existing.Policy.ContentSha256 != policy.ContentSha256)
      {
        throw Failure(App.PrivateServerFailureKind.Conflict, "challenge_policy_uid_conflict");
      }
      await InsertWriteOperationAsync(
          connection,
          transaction,
          operationUid,
          "publish_operational_policy",
          requestHash ?? RequestHash(
              "nll/private-server/publish-policy-request/v1",
              policy.PolicyUid,
          policy.ContentSha256),
          null,
          null,
          policy.PolicyUid,
          null,
          policy.ContentSha256,
          publishedAtUtc,
          cancellationToken).ConfigureAwait(false);
      return existing;
    }

    const string sql = """
        INSERT INTO lab_private_server.challenge_operational_policy (
            challenge_operational_policy_uid, policy_id, resolution_status,
            daily_entry_limit, daily_entry_limit_unresolved_reason_code,
            entry_consumption_point, entry_consumption_point_unresolved_reason_code,
            active_run_at_reset, active_run_at_reset_unresolved_reason_code,
            counter_scope, counter_scope_unresolved_reason_code,
            mock_battle_capability, mock_battle_unresolved_reason_code,
            local_ranking_capability, local_ranking_unresolved_reason_code,
            content_sha256, published_at_utc
        ) VALUES (
            @uid, @policy_id, @resolution,
            @daily_limit, @daily_reason,
            @consumption, @consumption_reason,
            @reset, @reset_reason,
            @scope, @scope_reason,
            @mock, @mock_reason,
            @ranking, @ranking_reason,
            @content, @published
        ) RETURNING challenge_operational_policy_id
        """;
    long id;
    await using (var command = new NpgsqlCommand(sql, connection, transaction))
    {
      Add(command, "uid", NpgsqlDbType.Uuid, policy.PolicyUid.Value);
      Add(command, "policy_id", NpgsqlDbType.Text, policy.PolicyId);
      Add(command, "resolution", NpgsqlDbType.Text, PrivateServerDomain.ChallengeOperationalPolicy.Code(policy.ResolutionStatus));
      Add(command, "daily_limit", NpgsqlDbType.Integer, policy.DailyEntryLimit.Value);
      Add(command, "daily_reason", NpgsqlDbType.Text, policy.DailyEntryLimit.UnresolvedReasonCode);
      Add(command, "consumption", NpgsqlDbType.Text, policy.EntryConsumptionPoint.Value.HasValue
          ? PrivateServerDomain.ChallengeOperationalPolicy.Code(policy.EntryConsumptionPoint.Value.Value)
          : null);
      Add(command, "consumption_reason", NpgsqlDbType.Text, policy.EntryConsumptionPoint.UnresolvedReasonCode);
      Add(command, "reset", NpgsqlDbType.Text, policy.ActiveRunAtReset.Value.HasValue
          ? PrivateServerDomain.ChallengeOperationalPolicy.Code(policy.ActiveRunAtReset.Value.Value)
          : null);
      Add(command, "reset_reason", NpgsqlDbType.Text, policy.ActiveRunAtReset.UnresolvedReasonCode);
      Add(command, "scope", NpgsqlDbType.Text, policy.DailyCounterScope.Value.HasValue
          ? PrivateServerDomain.ChallengeOperationalPolicy.Code(policy.DailyCounterScope.Value.Value)
          : null);
      Add(command, "scope_reason", NpgsqlDbType.Text, policy.DailyCounterScope.UnresolvedReasonCode);
      Add(command, "mock", NpgsqlDbType.Text, policy.MockBattleCapability.Value.HasValue
          ? PrivateServerDomain.ChallengeOperationalPolicy.Code(policy.MockBattleCapability.Value.Value)
          : null);
      Add(command, "mock_reason", NpgsqlDbType.Text, policy.MockBattleCapability.UnresolvedReasonCode);
      Add(command, "ranking", NpgsqlDbType.Text, policy.LocalRankingCapability.Value.HasValue
          ? PrivateServerDomain.ChallengeOperationalPolicy.Code(policy.LocalRankingCapability.Value.Value)
          : null);
      Add(command, "ranking_reason", NpgsqlDbType.Text, policy.LocalRankingCapability.UnresolvedReasonCode);
      Add(command, "content", NpgsqlDbType.Bytea, policy.ContentSha256.ToByteArray());
      Add(command, "published", NpgsqlDbType.TimestampTz, publishedAtUtc);
      id = (long)(await command.ExecuteScalarAsync(cancellationToken)
          .ConfigureAwait(false) ?? throw new InvalidOperationException());
    }

    var stableRequest = requestHash ?? RequestHash(
        "nll/private-server/publish-policy-request/v1",
        policy.PolicyUid,
        policy.ContentSha256);
    await InsertWriteOperationAsync(
        connection,
        transaction,
        operationUid,
        "publish_operational_policy",
        stableRequest,
        null,
        null,
        policy.PolicyUid,
        null,
        policy.ContentSha256,
        publishedAtUtc,
        cancellationToken).ConfigureAwait(false);
    return new StoredPolicy(id, policy, publishedAtUtc);
  }

  private static void RequirePolicyPublicationReplayBinding(
      StoredWriteOperation operation,
      PrivateServerDomain.ChallengeOperationalPolicy requestedPolicy,
      StoredPolicy storedPolicy)
  {
    if (operation.LocalAccountId.HasValue ||
        operation.ExpectedRevisionUid.HasValue ||
        operation.ResultRevisionUid.HasValue ||
        operation.ResultEntityUid != requestedPolicy.PolicyUid ||
        operation.ResultContentSha256 != requestedPolicy.ContentSha256 ||
        storedPolicy.Policy.PolicyUid != requestedPolicy.PolicyUid ||
        storedPolicy.Policy.ContentSha256 != requestedPolicy.ContentSha256)
    {
      throw Failure(
          App.PrivateServerFailureKind.Conflict,
          "challenge_policy_replay_binding_conflict");
    }
  }

  private static void RequirePolicyActivationReplayBinding(
      StoredWriteOperation operation,
      App.ActivateChallengeOperationalPolicyCommand command,
      PrivateServerDomain.ChallengeOperationalPolicyActivationRevision revision)
  {
    if (operation.LocalAccountId.HasValue ||
        !operation.ResultRevisionUid.HasValue ||
        operation.ResultEntityUid != revision.ActivationUid ||
        operation.ResultRevisionUid.Value != revision.ActivationRevisionUid ||
        operation.ResultContentSha256 != revision.ContentSha256 ||
        operation.ExpectedRevisionUid != command.ExpectedActivationRevisionUid ||
        revision.PolicyUid != command.PolicyUid ||
        revision.PolicyContentSha256 != command.ExpectedPolicySha256 ||
        revision.EffectiveRaidDayKey != command.EffectiveRaidDayKey ||
        !(operation.ExpectedRevisionUid == revision.ActivationRevisionUid ||
            operation.ExpectedRevisionUid == revision.PredecessorRevisionUid))
    {
      throw Failure(
          App.PrivateServerFailureKind.Conflict,
          "challenge_policy_activation_replay_binding_conflict");
    }
  }

  private static async Task<IReadOnlyList<StoredPolicy>> LoadAllPoliciesAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      CancellationToken cancellationToken)
  {
    const string sql = """
        SELECT challenge_operational_policy_id
          FROM lab_private_server.challenge_operational_policy
         ORDER BY challenge_operational_policy_id
        """;
    var ids = new List<long>();
    await using (var command = new NpgsqlCommand(sql, connection, transaction))
    await using (var reader = await command.ExecuteReaderAsync(cancellationToken)
        .ConfigureAwait(false))
    {
      while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        ids.Add(reader.GetInt64(0));
      }
    }
    var result = new List<StoredPolicy>(ids.Count);
    foreach (var id in ids)
    {
      result.Add(await LoadPolicyByIdAsync(connection, transaction, id, cancellationToken)
          .ConfigureAwait(false));
    }
    return result;
  }

  private static Task<StoredPolicy?> LoadPolicyByUidAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      EntityUid uid,
      CancellationToken cancellationToken) =>
      LoadPolicyAsync(
          connection,
          transaction,
          "challenge_operational_policy_uid = @value",
          NpgsqlDbType.Uuid,
          uid.Value,
          cancellationToken);

  private static async Task<StoredPolicy> LoadPolicyByIdAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      long id,
      CancellationToken cancellationToken) =>
      await LoadPolicyAsync(
          connection,
          transaction,
          "challenge_operational_policy_id = @value",
          NpgsqlDbType.Bigint,
          id,
          cancellationToken).ConfigureAwait(false) ??
      throw Failure(App.PrivateServerFailureKind.Unavailable, "challenge_policy_not_found");

  private static async Task<StoredPolicy?> LoadPolicyAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      string predicate,
      NpgsqlDbType parameterType,
      object value,
      CancellationToken cancellationToken)
  {
    var sql = $"""
        SELECT challenge_operational_policy_id, challenge_operational_policy_uid,
               policy_id, resolution_status,
               daily_entry_limit, daily_entry_limit_unresolved_reason_code,
               entry_consumption_point, entry_consumption_point_unresolved_reason_code,
               active_run_at_reset, active_run_at_reset_unresolved_reason_code,
               counter_scope, counter_scope_unresolved_reason_code,
               mock_battle_capability, mock_battle_unresolved_reason_code,
               local_ranking_capability, local_ranking_unresolved_reason_code,
               content_sha256, published_at_utc
          FROM lab_private_server.challenge_operational_policy
         WHERE {predicate}
        """;
    await using var command = new NpgsqlCommand(sql, connection, transaction);
    Add(command, "value", parameterType, value);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken)
        .ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      return null;
    }

    var configured = string.Equals(reader.GetString(3), "configured", StringComparison.Ordinal);
    var policy = new PrivateServerDomain.ChallengeOperationalPolicy(
        Uid(reader.GetValue(1)),
        reader.GetString(2),
        configured
            ? PrivateServerDomain.PolicyFact<int>.Configured(reader.GetInt32(4))
            : PrivateServerDomain.PolicyFact<int>.Unresolved(reader.GetString(5)),
        configured
            ? PrivateServerDomain.PolicyFact<PrivateServerDomain.ChallengeEntryConsumptionPoint>.Configured(
                ParseConsumption(reader.GetString(6)))
            : PrivateServerDomain.PolicyFact<PrivateServerDomain.ChallengeEntryConsumptionPoint>.Unresolved(reader.GetString(7)),
        configured
            ? PrivateServerDomain.PolicyFact<PrivateServerDomain.ActiveRunAtResetPolicy>.Configured(
                ParseReset(reader.GetString(8)))
            : PrivateServerDomain.PolicyFact<PrivateServerDomain.ActiveRunAtResetPolicy>.Unresolved(reader.GetString(9)),
        configured
            ? PrivateServerDomain.PolicyFact<PrivateServerDomain.DailyCounterScope>.Configured(ParseScope(reader.GetString(10)))
            : PrivateServerDomain.PolicyFact<PrivateServerDomain.DailyCounterScope>.Unresolved(reader.GetString(11)),
        configured
            ? PrivateServerDomain.PolicyFact<PrivateServerDomain.MockBattleCapability>.Configured(ParseMock(reader.GetString(12)))
            : PrivateServerDomain.PolicyFact<PrivateServerDomain.MockBattleCapability>.Unresolved(reader.GetString(13)),
        configured
            ? PrivateServerDomain.PolicyFact<PrivateServerDomain.LocalRankingCapability>.Configured(ParseRanking(reader.GetString(14)))
            : PrivateServerDomain.PolicyFact<PrivateServerDomain.LocalRankingCapability>.Unresolved(reader.GetString(15)));
    if (policy.ContentSha256 != Digest(reader.GetValue(16)))
    {
      throw Failure(App.PrivateServerFailureKind.Unavailable, "challenge_policy_content_invalid");
    }
    return new StoredPolicy(reader.GetInt64(0), policy, Instant(reader.GetValue(17)));
  }

  private static PrivateServerDomain.ChallengeEntryConsumptionPoint ParseConsumption(string value) => value switch
  {
    "run_opened" => PrivateServerDomain.ChallengeEntryConsumptionPoint.RunOpened,
    "first_team_entered" => PrivateServerDomain.ChallengeEntryConsumptionPoint.FirstTeamEntered,
    "run_closed" => PrivateServerDomain.ChallengeEntryConsumptionPoint.RunClosed,
    _ => throw Failure(App.PrivateServerFailureKind.Unavailable, "challenge_policy_consumption_invalid")
  };

  private static PrivateServerDomain.ActiveRunAtResetPolicy ParseReset(string value) => value switch
  {
    "pin_opening_raid_day" => PrivateServerDomain.ActiveRunAtResetPolicy.PinOpeningRaidDay,
    "reject_post_boundary_progress" => PrivateServerDomain.ActiveRunAtResetPolicy.RejectPostBoundaryProgress,
    _ => throw Failure(App.PrivateServerFailureKind.Unavailable, "challenge_policy_reset_invalid")
  };

  private static PrivateServerDomain.DailyCounterScope ParseScope(string value) => value switch
  {
    "per_season" => PrivateServerDomain.DailyCounterScope.PerSeason,
    "shared_across_directory" => PrivateServerDomain.DailyCounterScope.SharedAcrossDirectory,
    _ => throw Failure(App.PrivateServerFailureKind.Unavailable, "challenge_policy_scope_invalid")
  };

  private static PrivateServerDomain.MockBattleCapability ParseMock(string value) => value switch
  {
    "unsupported" => PrivateServerDomain.MockBattleCapability.Unsupported,
    "lab_owned_only" => PrivateServerDomain.MockBattleCapability.LabOwnedOnly,
    _ => throw Failure(App.PrivateServerFailureKind.Unavailable, "challenge_policy_mock_invalid")
  };

  private static PrivateServerDomain.LocalRankingCapability ParseRanking(string value) => value switch
  {
    "unsupported" => PrivateServerDomain.LocalRankingCapability.Unsupported,
    "local_records_only" => PrivateServerDomain.LocalRankingCapability.LocalRecordsOnly,
    _ => throw Failure(App.PrivateServerFailureKind.Unavailable, "challenge_policy_ranking_invalid")
  };

  private static async Task<long> InsertActivationRevisionAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      PrivateServerDomain.ChallengeOperationalPolicyActivationRevision revision,
      long policyId,
      long? previousId,
      CancellationToken cancellationToken)
  {
    const string sql = """
        INSERT INTO lab_private_server.challenge_policy_activation_revision (
            challenge_policy_activation_uid,
            challenge_policy_activation_revision_uid, revision_number,
            previous_activation_revision_id, challenge_operational_policy_id,
            policy_content_sha256, effective_raid_day_key, content_sha256,
            scheduled_at_utc
        ) VALUES (
            @activation_uid, @revision_uid, @number, @previous, @policy_id,
            @policy_sha, @day, @content, @scheduled
        ) RETURNING challenge_policy_activation_revision_id
        """;
    await using var command = new NpgsqlCommand(sql, connection, transaction);
    Add(command, "activation_uid", NpgsqlDbType.Uuid, revision.ActivationUid.Value);
    Add(command, "revision_uid", NpgsqlDbType.Uuid, revision.ActivationRevisionUid.Value);
    Add(command, "number", NpgsqlDbType.Integer, checked((int)revision.RevisionNumber));
    Add(command, "previous", NpgsqlDbType.Bigint, previousId);
    Add(command, "policy_id", NpgsqlDbType.Bigint, policyId);
    Add(command, "policy_sha", NpgsqlDbType.Bytea, revision.PolicyContentSha256.ToByteArray());
    Add(command, "day", NpgsqlDbType.Date, revision.EffectiveRaidDayKey.Date);
    Add(command, "content", NpgsqlDbType.Bytea, revision.ContentSha256.ToByteArray());
    Add(command, "scheduled", NpgsqlDbType.TimestampTz, revision.MaterializedAtUtc);
    return (long)(await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false) ??
        throw new InvalidOperationException());
  }

  private static async Task<StoredActivation?> LoadLatestActivationAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      CancellationToken cancellationToken)
  {
    const string sql = """
        SELECT latest_scheduled_activation_revision_id
          FROM lab_private_server.challenge_policy_state
         WHERE singleton
        """;
    await using var command = new NpgsqlCommand(sql, connection, transaction);
    var value = await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
    return value is null
        ? null
        : await LoadActivationByIdAsync(
            connection,
            transaction,
            (long)value,
            cancellationToken).ConfigureAwait(false);
  }

  private static async Task<StoredActivation?> LoadLatestActivationForUpdateAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      CancellationToken cancellationToken)
  {
    const string sql = """
        SELECT latest_scheduled_activation_revision_id
          FROM lab_private_server.challenge_policy_state
         WHERE singleton
         FOR UPDATE
        """;
    await using var command = new NpgsqlCommand(sql, connection, transaction);
    var value = await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
    return value is null
        ? null
        : await LoadActivationByIdAsync(connection, transaction, (long)value, cancellationToken)
            .ConfigureAwait(false);
  }

  private static async Task<StoredActivation> LoadActivationByRevisionUidAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      EntityUid revisionUid,
      CancellationToken cancellationToken)
  {
    const string sql = """
        SELECT challenge_policy_activation_revision_id
          FROM lab_private_server.challenge_policy_activation_revision
         WHERE challenge_policy_activation_revision_uid = @uid
        """;
    await using var command = new NpgsqlCommand(sql, connection, transaction);
    Add(command, "uid", NpgsqlDbType.Uuid, revisionUid.Value);
    var value = await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false) ??
        throw Failure(App.PrivateServerFailureKind.Unavailable, "challenge_policy_activation_not_found");
    return await LoadActivationByIdAsync(connection, transaction, (long)value, cancellationToken)
        .ConfigureAwait(false);
  }

  private static async Task<StoredActivation> LoadActivationByIdAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      long id,
      CancellationToken cancellationToken)
  {
    const string sql = """
        SELECT current.challenge_policy_activation_uid,
               current.challenge_policy_activation_revision_uid,
               current.revision_number,
               previous.challenge_policy_activation_revision_uid,
               policy.challenge_operational_policy_uid,
               current.policy_content_sha256, current.effective_raid_day_key,
               current.content_sha256, current.scheduled_at_utc
          FROM lab_private_server.challenge_policy_activation_revision current
          JOIN lab_private_server.challenge_operational_policy policy
            ON policy.challenge_operational_policy_id =
               current.challenge_operational_policy_id
          LEFT JOIN lab_private_server.challenge_policy_activation_revision previous
            ON previous.challenge_policy_activation_revision_id =
               current.previous_activation_revision_id
         WHERE current.challenge_policy_activation_revision_id = @id
        """;
    await using var command = new NpgsqlCommand(sql, connection, transaction);
    Add(command, "id", NpgsqlDbType.Bigint, id);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken)
        .ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      throw Failure(App.PrivateServerFailureKind.Unavailable, "challenge_policy_activation_not_found");
    }
    var revision = PrivateServerDomain.ChallengeOperationalPolicyActivationRevision.Restore(
        Uid(reader.GetValue(0)),
        Uid(reader.GetValue(1)),
        reader.GetInt64(2),
        NullableUid(reader.GetValue(3)),
        Uid(reader.GetValue(4)),
        Digest(reader.GetValue(5)),
        PrivateServerDomain.RaidDayKey.FromDate(Date(reader.GetValue(6))),
        Instant(reader.GetValue(8)));
    if (revision.ContentSha256 != Digest(reader.GetValue(7)))
    {
      throw Failure(App.PrivateServerFailureKind.Unavailable, "challenge_policy_activation_content_invalid");
    }
    return new StoredActivation(id, revision);
  }

  private static async Task<App.ChallengeOperationalPolicyProjection> ProjectPolicyAtAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      StoredPolicy policy,
      DateTimeOffset observedAtUtc,
      CancellationToken cancellationToken)
  {
    var day = PrivateServerDomain.AsiaSeoulRaidDay.GetKey(observedAtUtc);
    const string sql = """
        SELECT a.effective_raid_day_key
          FROM lab_private_server.challenge_policy_activation_revision a
         WHERE a.challenge_operational_policy_id = @policy_id
           AND a.scheduled_at_utc <= @observed
           AND a.effective_raid_day_key <= @day
         ORDER BY a.revision_number DESC
         LIMIT 1
        """;
    await using var command = new NpgsqlCommand(sql, connection, transaction);
    Add(command, "policy_id", NpgsqlDbType.Bigint, policy.Id);
    Add(command, "observed", NpgsqlDbType.TimestampTz, observedAtUtc);
    Add(command, "day", NpgsqlDbType.Date, day.Date);
    var value = await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
    return new App.ChallengeOperationalPolicyProjection(
        policy.Policy,
        policy.PublishedAtUtc,
        value is not null,
        value is null ? null : PrivateServerDomain.RaidDayKey.FromDate(Date(value)));
  }

  private static async Task<App.ChallengePolicyStateProjection> LoadPolicyStateAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      DateTimeOffset observedAtUtc,
      long? headRevisionId,
      CancellationToken cancellationToken)
  {
    var head = headRevisionId.HasValue
        ? await LoadActivationByIdAsync(
            connection,
            transaction,
            headRevisionId.Value,
            cancellationToken).ConfigureAwait(false)
        : await LoadLatestActivationAsync(connection, transaction, cancellationToken)
            .ConfigureAwait(false) ??
          throw Failure(App.PrivateServerFailureKind.Unavailable, "challenge_policy_activation_not_initialized");
    var day = PrivateServerDomain.AsiaSeoulRaidDay.GetKey(observedAtUtc);
    const string currentSql = """
        SELECT challenge_policy_activation_revision_id
          FROM lab_private_server.challenge_policy_activation_revision
         WHERE revision_number <= @head_number
           AND effective_raid_day_key <= @day
         ORDER BY revision_number DESC
         LIMIT 1
        """;
    long currentId;
    await using (var command = new NpgsqlCommand(currentSql, connection, transaction))
    {
      Add(command, "head_number", NpgsqlDbType.Integer, checked((int)head.Revision.RevisionNumber));
      Add(command, "day", NpgsqlDbType.Date, day.Date);
      currentId = (long)(await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false) ??
          throw Failure(App.PrivateServerFailureKind.Unavailable, "challenge_policy_current_not_found"));
    }
    var currentActivation = await LoadActivationByIdAsync(
        connection,
        transaction,
        currentId,
        cancellationToken).ConfigureAwait(false);
    var currentPolicy = await LoadPolicyByUidAsync(
        connection,
        transaction,
        currentActivation.Revision.PolicyUid,
        cancellationToken).ConfigureAwait(false) ??
        throw Failure(App.PrivateServerFailureKind.Unavailable, "challenge_policy_current_not_found");
    var currentProjection = new App.ChallengeOperationalPolicyProjection(
        currentPolicy.Policy,
        currentPolicy.PublishedAtUtc,
        true,
        currentActivation.Revision.EffectiveRaidDayKey);

    App.ChallengeOperationalPolicyProjection? scheduled = null;
    if (head.Id != currentActivation.Id)
    {
      var scheduledPolicy = await LoadPolicyByUidAsync(
          connection,
          transaction,
          head.Revision.PolicyUid,
          cancellationToken).ConfigureAwait(false) ??
          throw Failure(App.PrivateServerFailureKind.Unavailable, "challenge_policy_scheduled_not_found");
      scheduled = new App.ChallengeOperationalPolicyProjection(
          scheduledPolicy.Policy,
          scheduledPolicy.PublishedAtUtc,
          false,
          head.Revision.EffectiveRaidDayKey);
    }

    return new App.ChallengePolicyStateProjection(
        currentProjection,
        scheduled,
        new App.ChallengePolicyActivationProjection(
            head.Revision.ActivationUid,
            new App.RevisionProjection(
                head.Revision.ActivationRevisionUid,
                head.Revision.RevisionNumber,
                head.Revision.ContentSha256),
            head.Revision.PolicyUid,
            head.Revision.PolicyContentSha256,
            head.Revision.EffectiveRaidDayKey));
  }
}
