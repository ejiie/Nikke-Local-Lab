using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;
using Npgsql;
using NpgsqlTypes;

namespace NikkeLocalLab.Persistence.PostgreSql;

internal sealed record FetchedProgressionObservationWrite(
    string CanonicalJson,
    Sha256Digest CanonicalSha256,
    string CompletenessStatusCode,
    int AvailableComponentCount,
    int DerivedComponentCount,
    int UnavailableComponentCount,
    int? CompletedScenarioCount,
    int? MainQuestCompletedCount,
    int? MainQuestRewardClaimedCount,
    int? ContentsOpenUnlockedCount,
    int? StageClearHistoryCount,
    int? TriggerCount);

internal sealed record FetchedProgressionObservationDocument(
    string CanonicalJson,
    Sha256Digest CanonicalSha256,
    string CompletenessStatusCode,
    int AvailableComponentCount,
    int DerivedComponentCount,
    int UnavailableComponentCount,
    int? CompletedScenarioCount,
    int? MainQuestCompletedCount,
    int? MainQuestRewardClaimedCount,
    int? ContentsOpenUnlockedCount,
    int? StageClearHistoryCount,
    int? TriggerCount,
    DateTimeOffset ImportedAtUtc);

internal sealed record FetchedAccountSnapshotWrite(
    EntityUid SnapshotUid,
    EntityUid TargetAccountUid,
    EntityUid SanitizedDraftUid,
    DateTimeOffset CapturedAtUtc,
    string CompletenessStatusCode,
    int RosterCount,
    int CharacterDetailCount,
    int EquipmentCharacterCount,
    int MissingCharacterCount,
    string CanonicalSnapshotJson,
    Sha256Digest CanonicalSnapshotSha256,
    int SourceArtifactByteLength,
    Sha256Digest SourceArtifactSha256,
    DateTimeOffset ImportedAtUtc,
    FetchedProgressionObservationWrite? Progression = null);

internal sealed record FetchedAccountSnapshotDocument(
    EntityUid SnapshotUid,
    EntityUid TargetAccountUid,
    EntityUid SanitizedDraftUid,
    DateTimeOffset CapturedAtUtc,
    string CompletenessStatusCode,
    int RosterCount,
    int CharacterDetailCount,
    int EquipmentCharacterCount,
    int MissingCharacterCount,
    string CanonicalSnapshotJson,
    Sha256Digest CanonicalSnapshotSha256,
    int SourceArtifactByteLength,
    Sha256Digest SourceArtifactSha256,
    DateTimeOffset ImportedAtUtc,
    bool IsCurrentWorkspaceSnapshot,
    FetchedProgressionObservationDocument? Progression);

internal sealed class PostgreSqlFetchedAccountSnapshotStore
{
  private readonly NpgsqlDataSource _dataSource;

  public PostgreSqlFetchedAccountSnapshotStore(NpgsqlDataSource dataSource)
  {
    _dataSource = dataSource ?? throw new ArgumentNullException(nameof(dataSource));
  }

  public async Task<FetchedAccountSnapshotDocument> RegisterAsync(
      FetchedAccountSnapshotWrite write,
      CancellationToken cancellationToken)
  {
    ArgumentNullException.ThrowIfNull(write);
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using var transaction = await connection.BeginTransactionAsync(cancellationToken)
        .ConfigureAwait(false);

    var existing = await GetAsync(
        connection,
        transaction,
        write.SnapshotUid,
        cancellationToken).ConfigureAwait(false);
    if (existing is not null)
    {
      EnsureReplay(existing, write);
      await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
      return existing;
    }

    var localAccountId = await RequireLocalAccountIdAsync(
        connection,
        transaction,
        write.TargetAccountUid,
        cancellationToken).ConfigureAwait(false);
    var draftId = await RequireDraftIdAsync(
        connection,
        transaction,
        write.SanitizedDraftUid,
        cancellationToken).ConfigureAwait(false);

    const string insertSql = """
        INSERT INTO lab_profile.fetched_account_snapshot (
            fetched_account_snapshot_uid,
            target_local_account_id,
            sanitized_profile_draft_id,
            snapshot_contract_id,
            captured_at_utc,
            completeness_status_code,
            roster_count,
            character_detail_count,
            equipment_character_count,
            missing_character_count,
            canonical_snapshot_json,
            canonical_snapshot_sha256,
            source_artifact_byte_length,
            source_artifact_sha256,
            imported_at_utc
        ) VALUES (
            @snapshot_uid,
            @account_id,
            @draft_id,
            'nll/fetched-account-snapshot/v1',
            @captured_at,
            @status,
            @roster_count,
            @detail_count,
            @equipment_count,
            @missing_count,
            @snapshot_json,
            @snapshot_sha,
            @artifact_length,
            @artifact_sha,
            @imported_at
        );
        """;
    await using (var command = new NpgsqlCommand(insertSql, connection, transaction))
    {
      command.Parameters.AddWithValue("snapshot_uid", NpgsqlDbType.Uuid, write.SnapshotUid.Value);
      command.Parameters.AddWithValue("account_id", NpgsqlDbType.Bigint, localAccountId);
      command.Parameters.AddWithValue("draft_id", NpgsqlDbType.Bigint, draftId);
      command.Parameters.AddWithValue("captured_at", NpgsqlDbType.TimestampTz, write.CapturedAtUtc);
      command.Parameters.AddWithValue("status", NpgsqlDbType.Text, write.CompletenessStatusCode);
      command.Parameters.AddWithValue("roster_count", NpgsqlDbType.Integer, write.RosterCount);
      command.Parameters.AddWithValue("detail_count", NpgsqlDbType.Integer, write.CharacterDetailCount);
      command.Parameters.AddWithValue("equipment_count", NpgsqlDbType.Integer, write.EquipmentCharacterCount);
      command.Parameters.AddWithValue("missing_count", NpgsqlDbType.Integer, write.MissingCharacterCount);
      command.Parameters.AddWithValue("snapshot_json", NpgsqlDbType.Text, write.CanonicalSnapshotJson);
      command.Parameters.AddWithValue("snapshot_sha", NpgsqlDbType.Bytea, write.CanonicalSnapshotSha256.ToByteArray());
      command.Parameters.AddWithValue("artifact_length", NpgsqlDbType.Integer, write.SourceArtifactByteLength);
      command.Parameters.AddWithValue("artifact_sha", NpgsqlDbType.Bytea, write.SourceArtifactSha256.ToByteArray());
      command.Parameters.AddWithValue("imported_at", NpgsqlDbType.TimestampTz, write.ImportedAtUtc);
      _ = await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    if (write.Progression is not null)
    {
      const string insertProgressionSql = """
          INSERT INTO lab_profile.fetched_progression_observation (
              fetched_account_snapshot_uid,
              observation_contract_id,
              captured_at_utc,
              completeness_status_code,
              available_component_count,
              derived_component_count,
              unavailable_component_count,
              completed_scenario_count,
              main_quest_completed_count,
              main_quest_reward_claimed_count,
              contents_open_unlocked_count,
              stage_clear_history_count,
              trigger_count,
              canonical_observation_json,
              canonical_observation_sha256,
              imported_at_utc
          ) VALUES (
              @snapshot_uid,
              'nll/fetched-progression-observation/v2',
              @captured_at,
              @status,
              @available_count,
              @derived_count,
              @unavailable_count,
              @scenario_count,
              @quest_count,
              @reward_count,
              @content_count,
              @stage_count,
              @trigger_count,
              @observation_json,
              @observation_sha,
              @imported_at
          );
          """;
      await using var command = new NpgsqlCommand(insertProgressionSql, connection, transaction);
      command.Parameters.AddWithValue("snapshot_uid", NpgsqlDbType.Uuid, write.SnapshotUid.Value);
      command.Parameters.AddWithValue("captured_at", NpgsqlDbType.TimestampTz, write.CapturedAtUtc);
      command.Parameters.AddWithValue("status", NpgsqlDbType.Text, write.Progression.CompletenessStatusCode);
      command.Parameters.AddWithValue("available_count", NpgsqlDbType.Integer, write.Progression.AvailableComponentCount);
      command.Parameters.AddWithValue("derived_count", NpgsqlDbType.Integer, write.Progression.DerivedComponentCount);
      command.Parameters.AddWithValue("unavailable_count", NpgsqlDbType.Integer, write.Progression.UnavailableComponentCount);
      AddNullableInteger(command, "scenario_count", write.Progression.CompletedScenarioCount);
      AddNullableInteger(command, "quest_count", write.Progression.MainQuestCompletedCount);
      AddNullableInteger(command, "reward_count", write.Progression.MainQuestRewardClaimedCount);
      AddNullableInteger(command, "content_count", write.Progression.ContentsOpenUnlockedCount);
      AddNullableInteger(command, "stage_count", write.Progression.StageClearHistoryCount);
      AddNullableInteger(command, "trigger_count", write.Progression.TriggerCount);
      command.Parameters.AddWithValue("observation_json", NpgsqlDbType.Text, write.Progression.CanonicalJson);
      command.Parameters.AddWithValue("observation_sha", NpgsqlDbType.Bytea, write.Progression.CanonicalSha256.ToByteArray());
      command.Parameters.AddWithValue("imported_at", NpgsqlDbType.TimestampTz, write.ImportedAtUtc);
      _ = await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    if (string.Equals(write.CompletenessStatusCode, "complete", StringComparison.Ordinal))
    {
      const string updateWorkspaceSql = """
          UPDATE lab_profile.account_workspace
          SET fetched_snapshot_uid = @snapshot_uid,
              last_fetched_at_utc = @captured_at,
              updated_at_utc = GREATEST(updated_at_utc, @imported_at)
          WHERE local_account_id = @account_id
            AND (last_fetched_at_utc IS NULL OR last_fetched_at_utc <= @captured_at);
          """;
      await using var command = new NpgsqlCommand(updateWorkspaceSql, connection, transaction);
      command.Parameters.AddWithValue("snapshot_uid", NpgsqlDbType.Uuid, write.SnapshotUid.Value);
      command.Parameters.AddWithValue("captured_at", NpgsqlDbType.TimestampTz, write.CapturedAtUtc);
      command.Parameters.AddWithValue("imported_at", NpgsqlDbType.TimestampTz, write.ImportedAtUtc);
      command.Parameters.AddWithValue("account_id", NpgsqlDbType.Bigint, localAccountId);
      _ = await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
    return await GetAsync(write.SnapshotUid, cancellationToken).ConfigureAwait(false) ??
        throw new LocalGameStateIntegrityException("fetched_snapshot_not_persisted");
  }

  public async Task<FetchedAccountSnapshotDocument?> GetAsync(
      EntityUid snapshotUid,
      CancellationToken cancellationToken)
  {
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    return await GetAsync(connection, transaction: null, snapshotUid, cancellationToken)
        .ConfigureAwait(false);
  }

  public async Task<FetchedAccountSnapshotDocument?> GetLatestForAccountAsync(
      EntityUid accountUid,
      CancellationToken cancellationToken)
  {
    const string sql = """
        SELECT snapshot.fetched_account_snapshot_uid
        FROM lab_profile.fetched_account_snapshot AS snapshot
        JOIN lab_profile.local_account AS account
          ON account.local_account_id = snapshot.target_local_account_id
        WHERE account.local_account_uid = @account_uid
        ORDER BY snapshot.captured_at_utc DESC,
                 snapshot.imported_at_utc DESC,
                 snapshot.fetched_account_snapshot_id DESC
        LIMIT 1;
        """;
    await using var command = _dataSource.CreateCommand(sql);
    command.Parameters.AddWithValue("account_uid", NpgsqlDbType.Uuid, accountUid.Value);
    var scalar = await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
    return scalar is Guid uid
        ? await GetAsync(new EntityUid(uid), cancellationToken).ConfigureAwait(false)
        : null;
  }

  public async Task<FetchedAccountSnapshotDocument?> GetLatestEffectiveForAccountAsync(
      EntityUid accountUid,
      CancellationToken cancellationToken)
  {
    const string sql = """
        SELECT COALESCE(
            (
                SELECT snapshot.fetched_account_snapshot_uid
                FROM lab_profile.fetched_account_snapshot AS snapshot
                JOIN lab_profile.local_account AS account
                  ON account.local_account_id = snapshot.target_local_account_id
                WHERE account.local_account_uid = @account_uid
                ORDER BY snapshot.captured_at_utc DESC,
                         snapshot.imported_at_utc DESC,
                         snapshot.fetched_account_snapshot_id DESC
                LIMIT 1
            ),
            (
                SELECT binding.source_snapshot_uid
                FROM lab_profile.account_observation_provenance_binding AS binding
                JOIN lab_profile.local_account AS account
                  ON account.local_account_id = binding.target_local_account_id
                WHERE account.local_account_uid = @account_uid
            )
        );
        """;
    await using var command = _dataSource.CreateCommand(sql);
    command.Parameters.AddWithValue("account_uid", NpgsqlDbType.Uuid, accountUid.Value);
    var scalar = await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
    return scalar is Guid uid
        ? await GetAsync(new EntityUid(uid), cancellationToken).ConfigureAwait(false)
        : null;
  }

  private static async Task<FetchedAccountSnapshotDocument?> GetAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      EntityUid snapshotUid,
      CancellationToken cancellationToken)
  {
    const string sql = """
        SELECT
            snapshot.fetched_account_snapshot_uid,
            account.local_account_uid,
            draft.sanitized_profile_draft_uid,
            snapshot.captured_at_utc,
            snapshot.completeness_status_code,
            snapshot.roster_count,
            snapshot.character_detail_count,
            snapshot.equipment_character_count,
            snapshot.missing_character_count,
            snapshot.canonical_snapshot_json,
            snapshot.canonical_snapshot_sha256,
            snapshot.source_artifact_byte_length,
            snapshot.source_artifact_sha256,
            snapshot.imported_at_utc,
            COALESCE(
                workspace.fetched_snapshot_uid = snapshot.fetched_account_snapshot_uid,
                FALSE),
            progression.completeness_status_code,
            progression.available_component_count,
            progression.derived_component_count,
            progression.unavailable_component_count,
            progression.completed_scenario_count,
            progression.main_quest_completed_count,
            progression.main_quest_reward_claimed_count,
            progression.contents_open_unlocked_count,
            progression.stage_clear_history_count,
            progression.trigger_count,
            progression.canonical_observation_json,
            progression.canonical_observation_sha256,
            progression.imported_at_utc
        FROM lab_profile.fetched_account_snapshot AS snapshot
        JOIN lab_profile.local_account AS account
          ON account.local_account_id = snapshot.target_local_account_id
        JOIN lab_local_game.sanitized_profile_draft AS draft
          ON draft.sanitized_profile_draft_id = snapshot.sanitized_profile_draft_id
        JOIN lab_profile.account_workspace AS workspace
          ON workspace.local_account_id = snapshot.target_local_account_id
        LEFT JOIN lab_profile.fetched_progression_observation AS progression
          ON progression.fetched_account_snapshot_uid = snapshot.fetched_account_snapshot_uid
        WHERE snapshot.fetched_account_snapshot_uid = @snapshot_uid;
        """;
    await using var command = new NpgsqlCommand(sql, connection, transaction);
    command.Parameters.AddWithValue("snapshot_uid", NpgsqlDbType.Uuid, snapshotUid.Value);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false)) return null;
    var progression = reader.IsDBNull(15)
        ? null
        : new FetchedProgressionObservationDocument(
            reader.GetString(25),
            Sha256Digest.FromBytes(reader.GetFieldValue<byte[]>(26)),
            reader.GetString(15),
            reader.GetInt32(16),
            reader.GetInt32(17),
            reader.GetInt32(18),
            GetNullableInt32(reader, 19),
            GetNullableInt32(reader, 20),
            GetNullableInt32(reader, 21),
            GetNullableInt32(reader, 22),
            GetNullableInt32(reader, 23),
            GetNullableInt32(reader, 24),
            reader.GetFieldValue<DateTimeOffset>(27));
    return new FetchedAccountSnapshotDocument(
        new EntityUid(reader.GetGuid(0)),
        new EntityUid(reader.GetGuid(1)),
        new EntityUid(reader.GetGuid(2)),
        reader.GetFieldValue<DateTimeOffset>(3),
        reader.GetString(4),
        reader.GetInt32(5),
        reader.GetInt32(6),
        reader.GetInt32(7),
        reader.GetInt32(8),
        reader.GetString(9),
        Sha256Digest.FromBytes(reader.GetFieldValue<byte[]>(10)),
        reader.GetInt32(11),
        Sha256Digest.FromBytes(reader.GetFieldValue<byte[]>(12)),
        reader.GetFieldValue<DateTimeOffset>(13),
        reader.GetBoolean(14),
        progression);
  }

  private static async Task<long> RequireLocalAccountIdAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid accountUid,
      CancellationToken cancellationToken)
  {
    const string sql = "SELECT local_account_id FROM lab_profile.local_account WHERE local_account_uid = @uid;";
    await using var command = new NpgsqlCommand(sql, connection, transaction);
    command.Parameters.AddWithValue("uid", NpgsqlDbType.Uuid, accountUid.Value);
    var value = await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
    return value is long id
        ? id
        : throw new LocalGameStateIntegrityException("fetched_snapshot_target_account_not_found");
  }

  private static async Task<long> RequireDraftIdAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid draftUid,
      CancellationToken cancellationToken)
  {
    const string sql = """
        SELECT sanitized_profile_draft_id
        FROM lab_local_game.sanitized_profile_draft
        WHERE sanitized_profile_draft_uid = @uid;
        """;
    await using var command = new NpgsqlCommand(sql, connection, transaction);
    command.Parameters.AddWithValue("uid", NpgsqlDbType.Uuid, draftUid.Value);
    var value = await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
    return value is long id
        ? id
        : throw new LocalGameStateIntegrityException("fetched_snapshot_sanitized_draft_not_found");
  }

  private static void EnsureReplay(
      FetchedAccountSnapshotDocument existing,
      FetchedAccountSnapshotWrite write)
  {
    if (existing.TargetAccountUid != write.TargetAccountUid ||
        existing.SanitizedDraftUid != write.SanitizedDraftUid ||
        existing.CanonicalSnapshotSha256 != write.CanonicalSnapshotSha256 ||
        existing.SourceArtifactSha256 != write.SourceArtifactSha256 ||
        existing.SourceArtifactByteLength != write.SourceArtifactByteLength ||
        !string.Equals(existing.CanonicalSnapshotJson, write.CanonicalSnapshotJson, StringComparison.Ordinal))
      throw new LocalGameStateIntegrityException("fetched_snapshot_uid_reuse_mismatch");

    if ((existing.Progression is null) != (write.Progression is null))
      throw new LocalGameStateIntegrityException("fetched_snapshot_progression_replay_mismatch");
    if (existing.Progression is not null && write.Progression is not null &&
        (existing.Progression.CanonicalSha256 != write.Progression.CanonicalSha256 ||
         !string.Equals(
             existing.Progression.CanonicalJson,
             write.Progression.CanonicalJson,
             StringComparison.Ordinal)))
      throw new LocalGameStateIntegrityException("fetched_snapshot_progression_replay_mismatch");
  }

  private static void AddNullableInteger(NpgsqlCommand command, string name, int? value) =>
      command.Parameters.AddWithValue(name, NpgsqlDbType.Integer, value is null ? DBNull.Value : value.Value);

  private static int? GetNullableInt32(NpgsqlDataReader reader, int ordinal) =>
      reader.IsDBNull(ordinal) ? null : reader.GetInt32(ordinal);
}
