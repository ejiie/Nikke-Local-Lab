using System.Data;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Npgsql;
using NpgsqlTypes;

namespace NikkeLocalLab.Persistence.PostgreSql;

public sealed record ClassicSoloRaidRuntimeOperationalBinding(
    Guid LocalAccountUid,
    int SeasonNumber,
    Guid RaidSnapshotUid,
    byte[] RaidSnapshotSha256);

public sealed record ClassicSoloRaidRuntimeStateKey(
    Guid LocalAccountUid,
    int SeasonNumber,
    Guid RaidSnapshotUid,
    byte[] RaidSnapshotSha256,
    string ClientBuildCode,
    byte[] ClientExecutableSha256,
    string SelectedWeaknessCode = "unresolved");

public sealed record ClassicSoloRaidRuntimeStateHead(
    Guid RevisionUid,
    int RevisionNumber,
    byte[] SourceProfileRevisionSetSha256,
    byte[] ProtectedPayload,
    byte[] ProtectedPayloadSha256,
    byte[] StateContentSha256,
    bool StatePresent,
    bool HasOpenRun,
    long? CompletedBestTotalDamage,
    int CompletedBestTeamCount,
    int OpenTeamCount,
    int? RaidDateDay,
    DateTimeOffset CapturedAtUtc);

public sealed record ClassicSoloRaidRuntimeStateCapture(
    ClassicSoloRaidRuntimeStateKey Key,
    Guid LaunchContextUid,
    Guid? ExpectedHeadRevisionUid,
    byte[] RequestSha256,
    byte[] SourceProfileRevisionSetSha256,
    byte[] ProtectedPayload,
    byte[] ProtectedPayloadSha256,
    byte[] StateContentSha256,
    bool StatePresent,
    bool HasOpenRun,
    long? CompletedBestTotalDamage,
    int CompletedBestTeamCount,
    int OpenTeamCount,
    int? RaidDateDay,
    DateTimeOffset CapturedAtUtc);

public sealed record ClassicSoloRaidRuntimeStatePersistResult(
    string ResultCode,
    Guid? HeadRevisionUid,
    byte[] ResultStateContentSha256,
    bool StateAdvanced,
    bool Quarantined,
    bool ExactReplay);

public sealed class ClassicSoloRaidRuntimeStateStore
{
  private readonly NpgsqlDataSource _dataSource;

  public ClassicSoloRaidRuntimeStateStore(NpgsqlDataSource dataSource)
  {
    _dataSource = dataSource;
  }

  public async Task<ClassicSoloRaidRuntimeOperationalBinding> ResolveOperationalBindingAsync(
      Guid localAccountUid,
      int seasonNumber,
      DateTimeOffset? observedAtUtc = null,
      CancellationToken cancellationToken = default)
  {
    Require(localAccountUid != Guid.Empty && seasonNumber > 0,
        "phase_d_raid_state_operational_binding_invalid");
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken);
    await using var command = connection.CreateCommand();
    var observedAt = observedAtUtc ?? DateTimeOffset.UtcNow;
    command.CommandText = """
        WITH effective_boot AS MATERIALIZED (
            SELECT candidate.raid_season_directory_id,
                   candidate.directory_content_sha256
              FROM lab_private_server.private_server_boot_revision candidate
             WHERE candidate.effective_raid_day_key <=
                   lab_private_server.raid_day_key($3)
             ORDER BY candidate.effective_raid_day_key DESC,
                      candidate.revision_number DESC
             LIMIT 1
        ),
        boot_binding AS (
            SELECT snapshot.raid_snapshot_uid,
                   member.raid_snapshot_content_sha256
              FROM effective_boot boot
              JOIN lab_private_server.raid_season_directory directory
                ON directory.raid_season_directory_id = boot.raid_season_directory_id
               AND directory.content_sha256 = boot.directory_content_sha256
              JOIN lab_private_server.raid_season_directory_member member
                ON member.raid_season_directory_id = directory.raid_season_directory_id
               AND member.raid_catalog_snapshot_id = directory.raid_catalog_snapshot_id
               AND member.season_number = $2
              JOIN lab_raid.raid_snapshot snapshot
                ON snapshot.raid_snapshot_id = member.raid_snapshot_id
               AND snapshot.season_number = member.season_number
               AND snapshot.content_sha256 = member.raid_snapshot_content_sha256
        ),
        eligible_catalog AS (
            SELECT catalog.raid_catalog_snapshot_id
              FROM lab_raid.raid_catalog_snapshot catalog
              JOIN lab_raid.raid_catalog_snapshot_member catalog_member
                ON catalog_member.raid_catalog_snapshot_id =
                   catalog.raid_catalog_snapshot_id
              JOIN lab_raid.raid_snapshot candidate
                ON candidate.raid_snapshot_id = catalog_member.raid_snapshot_id
             WHERE candidate.readiness_status = 'ready'
               AND candidate.admission_status = 'supported'
               AND candidate.admission_policy_id = 'challenge-boss-support/v1'
               AND candidate.mode = 'challenge'
               AND candidate.difficulty_type = 2
               AND candidate.wave_order = 8
             GROUP BY catalog.raid_catalog_snapshot_id, catalog.member_count
            HAVING catalog.member_count = 6
               AND count(*) = 6
               AND array_agg(candidate.season_number ORDER BY candidate.season_number) =
                   ARRAY[7,13,26,29,34,40]::integer[]
        ),
        catalog_binding AS (
            SELECT snapshot.raid_snapshot_uid,
                   snapshot.content_sha256 AS raid_snapshot_content_sha256
              FROM eligible_catalog catalog
              JOIN lab_raid.raid_catalog_snapshot_member member
                ON member.raid_catalog_snapshot_id = catalog.raid_catalog_snapshot_id
              JOIN lab_raid.raid_snapshot snapshot
                ON snapshot.raid_snapshot_id = member.raid_snapshot_id
               AND snapshot.season_number = $2
        ),
        selected_binding AS (
            SELECT raid_snapshot_uid, raid_snapshot_content_sha256
              FROM boot_binding
            UNION ALL
            SELECT raid_snapshot_uid, raid_snapshot_content_sha256
              FROM catalog_binding
             WHERE NOT EXISTS (SELECT 1 FROM effective_boot)
        )
        SELECT binding.raid_snapshot_uid,
               binding.raid_snapshot_content_sha256
          FROM lab_profile.local_account account
          CROSS JOIN selected_binding binding
         WHERE account.local_account_uid = $1;
        """;
    command.Parameters.AddWithValue(localAccountUid);
    command.Parameters.AddWithValue(seasonNumber);
    command.Parameters.AddWithValue(observedAt);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    if (!await reader.ReadAsync(cancellationToken))
    {
      throw new InvalidOperationException("phase_d_raid_state_operational_binding_missing");
    }
    var result = new ClassicSoloRaidRuntimeOperationalBinding(
        localAccountUid,
        seasonNumber,
        reader.GetGuid(0),
        reader.GetFieldValue<byte[]>(1));
    if (await reader.ReadAsync(cancellationToken))
    {
      throw new InvalidOperationException(
          "phase_d_raid_state_operational_binding_cardinality_invalid");
    }
    Require(result.RaidSnapshotUid != Guid.Empty &&
            IsSha256(result.RaidSnapshotSha256),
        "phase_d_raid_state_operational_binding_invalid");
    return result;
  }

  public async Task<ClassicSoloRaidRuntimeStateHead?> GetHeadAsync(
      ClassicSoloRaidRuntimeStateKey key,
      CancellationToken cancellationToken = default)
  {
    ValidateKey(key);
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken);
    await using var command = connection.CreateCommand();
    command.CommandText = """
        SELECT revision.classic_solo_raid_runtime_state_revision_uid,
               revision.revision_number,
               revision.source_profile_revision_set_sha256,
               revision.protected_payload,
               revision.protected_payload_sha256,
               revision.state_content_sha256,
               revision.state_present,
               revision.has_open_run,
               revision.completed_best_total_damage,
               revision.completed_best_team_count,
               revision.open_team_count,
               revision.raid_date_day,
               revision.captured_at_utc
          FROM lab_private_server.classic_solo_raid_runtime_state state
          JOIN lab_profile.local_account account
            ON account.local_account_id = state.local_account_id
          JOIN lab_raid.raid_snapshot snapshot
            ON snapshot.raid_snapshot_id = state.raid_snapshot_id
          JOIN lab_private_server.classic_solo_raid_runtime_state_revision revision
            ON revision.classic_solo_raid_runtime_state_revision_id =
               state.current_classic_solo_raid_runtime_state_revision_id
         WHERE account.local_account_uid = $1
           AND snapshot.season_number = $2
           AND snapshot.raid_snapshot_uid = $3
           AND snapshot.content_sha256 = $4
           AND state.client_build_code = $5
           AND state.client_executable_sha256 = $6
           AND state.selected_weakness_code = $7;
        """;
    command.Parameters.AddWithValue(key.LocalAccountUid);
    command.Parameters.AddWithValue(key.SeasonNumber);
    command.Parameters.AddWithValue(key.RaidSnapshotUid);
    command.Parameters.AddWithValue(key.RaidSnapshotSha256);
    command.Parameters.AddWithValue(key.ClientBuildCode);
    command.Parameters.AddWithValue(key.ClientExecutableSha256);
    command.Parameters.AddWithValue(key.SelectedWeaknessCode);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    if (!await reader.ReadAsync(cancellationToken)) return null;
    var head = ReadHead(reader);
    if (await reader.ReadAsync(cancellationToken))
    {
      throw new InvalidOperationException("phase_d_raid_state_head_cardinality_invalid");
    }
    ValidateStoredHead(head);
    return head;
  }

  public async Task<ClassicSoloRaidRuntimeStatePersistResult> PersistAsync(
      ClassicSoloRaidRuntimeStateCapture capture,
      CancellationToken cancellationToken = default)
  {
    ValidateCapture(capture);
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken);
    await using var transaction = await connection.BeginTransactionAsync(
        IsolationLevel.Serializable,
        cancellationToken);

    var replay = await ReadOperationAsync(connection, transaction, capture.LaunchContextUid,
        cancellationToken);
    if (replay is not null)
    {
      if (!CryptographicOperations.FixedTimeEquals(replay.RequestSha256, capture.RequestSha256))
      {
        throw new InvalidOperationException("phase_d_raid_state_operation_uid_reuse");
      }
      if (replay.Status == "pending")
      {
        throw new InvalidOperationException("phase_d_raid_state_operation_pending");
      }
      await transaction.CommitAsync(cancellationToken);
      return new ClassicSoloRaidRuntimeStatePersistResult(
          replay.ResultCode!,
          replay.ResultRevisionUid,
          replay.ResultStateContentSha256!,
          replay.ResultCode == "state_advanced",
          replay.Status == "quarantined",
          true);
    }

    var resolved = await ResolveBindingAsync(connection, transaction, capture.Key,
        cancellationToken);
    var aggregate = await LockOrCreateAggregateAsync(
        connection,
        transaction,
        capture.Key,
        resolved.LocalAccountId,
        resolved.RaidSnapshotId,
        cancellationToken);
    var current = await ReadHeadForUpdateAsync(
        connection,
        transaction,
        aggregate.StateId,
        cancellationToken);

    await InsertPendingOperationAsync(
        connection,
        transaction,
        capture,
        aggregate.StateId,
        cancellationToken);

    if (!capture.StatePresent)
    {
      var resultHash = current?.StateContentSha256 ?? capture.StateContentSha256;
      var code = current is null ? "no_state" : "unexpected_absence_quarantined";
      var status = current is null ? "applied" : "quarantined";
      await CompleteOperationAsync(
          connection, transaction, capture.LaunchContextUid, status, code,
          current?.RevisionUid, resultHash, cancellationToken);
      await transaction.CommitAsync(cancellationToken);
      return new ClassicSoloRaidRuntimeStatePersistResult(
          code, current?.RevisionUid, resultHash, false, current is not null, false);
    }

    // V0015 briefly admitted operator-abandoned 1..4 team Trials as completed
    // bests. Those immutable revisions remain readable for audit, but they are
    // not score authority and must be replaceable by the next valid capture.
    if (current?.CompletedBestTeamCount == 5 &&
        current.CompletedBestTotalDamage is long currentBest &&
        (capture.CompletedBestTotalDamage is null ||
         capture.CompletedBestTotalDamage.Value < currentBest))
    {
      await CompleteOperationAsync(
          connection, transaction, capture.LaunchContextUid, "quarantined",
          "completed_best_regression_quarantined", current.RevisionUid,
          current.StateContentSha256, cancellationToken);
      await transaction.CommitAsync(cancellationToken);
      return new ClassicSoloRaidRuntimeStatePersistResult(
          "completed_best_regression_quarantined", current.RevisionUid,
          current.StateContentSha256, false, true, false);
    }

    if (current is not null && CryptographicOperations.FixedTimeEquals(
            current.StateContentSha256,
            capture.StateContentSha256))
    {
      await CompleteOperationAsync(
          connection, transaction, capture.LaunchContextUid, "applied", "state_unchanged",
          current.RevisionUid, current.StateContentSha256, cancellationToken);
      await transaction.CommitAsync(cancellationToken);
      return new ClassicSoloRaidRuntimeStatePersistResult(
          "state_unchanged", current.RevisionUid, current.StateContentSha256,
          false, false, false);
    }

    if (capture.ExpectedHeadRevisionUid != current?.RevisionUid)
    {
      var resultHash = current?.StateContentSha256 ?? capture.StateContentSha256;
      await CompleteOperationAsync(
          connection, transaction, capture.LaunchContextUid, "quarantined",
          "stale_head_quarantined", current?.RevisionUid, resultHash, cancellationToken);
      await transaction.CommitAsync(cancellationToken);
      return new ClassicSoloRaidRuntimeStatePersistResult(
          "stale_head_quarantined", current?.RevisionUid, resultHash,
          false, true, false);
    }

    var newRevisionUid = Guid.NewGuid();
    var newRevisionId = await InsertRevisionAsync(
        connection,
        transaction,
        aggregate.StateId,
        newRevisionUid,
        current,
        capture,
        cancellationToken);
    await UpdateHeadAsync(
        connection,
        transaction,
        aggregate.StateId,
        newRevisionId,
        current?.RevisionUid,
        cancellationToken);
    await CompleteOperationAsync(
        connection, transaction, capture.LaunchContextUid, "applied", "state_advanced",
        newRevisionUid, capture.StateContentSha256, cancellationToken);
    await transaction.CommitAsync(cancellationToken);
    return new ClassicSoloRaidRuntimeStatePersistResult(
        "state_advanced", newRevisionUid, capture.StateContentSha256,
        true, false, false);
  }

  public static byte[] ComputeRequestSha256(ClassicSoloRaidRuntimeStateCapture capture)
  {
    var canonical = string.Join('\n',
        "nll/classic-solo-raid-runtime-state-persist-request/v1",
        capture.Key.LocalAccountUid.ToString("D"),
        capture.Key.SeasonNumber.ToString(CultureInfo.InvariantCulture),
        capture.Key.RaidSnapshotUid.ToString("D"),
        LowerHex(capture.Key.RaidSnapshotSha256),
        capture.Key.ClientBuildCode,
        LowerHex(capture.Key.ClientExecutableSha256),
        capture.LaunchContextUid.ToString("D"),
        capture.ExpectedHeadRevisionUid?.ToString("D") ?? "none",
        LowerHex(capture.SourceProfileRevisionSetSha256),
        capture.ProtectedPayload.Length.ToString(CultureInfo.InvariantCulture),
        LowerHex(capture.ProtectedPayloadSha256),
        LowerHex(capture.StateContentSha256),
        capture.StatePresent ? "true" : "false",
        capture.HasOpenRun ? "true" : "false",
        capture.CompletedBestTotalDamage?.ToString(CultureInfo.InvariantCulture) ?? "none",
        capture.CompletedBestTeamCount.ToString(CultureInfo.InvariantCulture),
        capture.OpenTeamCount.ToString(CultureInfo.InvariantCulture),
        capture.RaidDateDay?.ToString(CultureInfo.InvariantCulture) ?? "none",
        capture.CapturedAtUtc.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture)) + "\n";
    // Keep historical pending replay byte-identical. New scoped operations bind
    // the selected weakness with a distinct domain, even if ciphertext matches.
    if (capture.Key.SelectedWeaknessCode != "unresolved")
    {
      canonical = "nll/classic-solo-raid-runtime-state-persist-request/v2\n" +
          capture.Key.SelectedWeaknessCode + "\n" + canonical;
    }
    return SHA256.HashData(Encoding.UTF8.GetBytes(canonical));
  }

  private static async Task<BindingIds> ResolveBindingAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      ClassicSoloRaidRuntimeStateKey key,
      CancellationToken cancellationToken)
  {
    await using var command = connection.CreateCommand();
    command.Transaction = transaction;
    command.CommandText = """
        SELECT account.local_account_id, snapshot.raid_snapshot_id
          FROM lab_profile.local_account account
          CROSS JOIN lab_raid.raid_snapshot snapshot
         WHERE account.local_account_uid = $1
           AND snapshot.season_number = $2
           AND snapshot.raid_snapshot_uid = $3
           AND snapshot.content_sha256 = $4;
        """;
    command.Parameters.AddWithValue(key.LocalAccountUid);
    command.Parameters.AddWithValue(key.SeasonNumber);
    command.Parameters.AddWithValue(key.RaidSnapshotUid);
    command.Parameters.AddWithValue(key.RaidSnapshotSha256);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    if (!await reader.ReadAsync(cancellationToken))
    {
      throw new InvalidOperationException("phase_d_raid_state_binding_missing");
    }
    var result = new BindingIds(reader.GetInt64(0), reader.GetInt64(1));
    if (await reader.ReadAsync(cancellationToken))
    {
      throw new InvalidOperationException("phase_d_raid_state_binding_cardinality_invalid");
    }
    return result;
  }

  private static async Task<AggregateRow> LockOrCreateAggregateAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      ClassicSoloRaidRuntimeStateKey key,
      long localAccountId,
      long raidSnapshotId,
      CancellationToken cancellationToken)
  {
    async Task<AggregateRow?> ReadAsync()
    {
      await using var read = connection.CreateCommand();
      read.Transaction = transaction;
      read.CommandText = """
          SELECT classic_solo_raid_runtime_state_id,
                 classic_solo_raid_runtime_state_uid
            FROM lab_private_server.classic_solo_raid_runtime_state
           WHERE local_account_id = $1
             AND raid_snapshot_id = $2
             AND season_number = $3
             AND client_build_code = $4
             AND client_executable_sha256 = $5
             AND selected_weakness_code = $6
           FOR UPDATE;
          """;
      read.Parameters.AddWithValue(localAccountId);
      read.Parameters.AddWithValue(raidSnapshotId);
      read.Parameters.AddWithValue(key.SeasonNumber);
      read.Parameters.AddWithValue(key.ClientBuildCode);
      read.Parameters.AddWithValue(key.ClientExecutableSha256);
      read.Parameters.AddWithValue(key.SelectedWeaknessCode);
      await using var reader = await read.ExecuteReaderAsync(cancellationToken);
      return await reader.ReadAsync(cancellationToken)
          ? new AggregateRow(reader.GetInt64(0), reader.GetGuid(1))
          : null;
    }

    var existing = await ReadAsync();
    if (existing is not null) return existing;
    await using (var insert = connection.CreateCommand())
    {
      insert.Transaction = transaction;
      insert.CommandText = """
          INSERT INTO lab_private_server.classic_solo_raid_runtime_state (
              classic_solo_raid_runtime_state_uid,
              local_account_id,
              raid_snapshot_id,
              season_number,
              client_build_code,
              client_executable_sha256,
              current_classic_solo_raid_runtime_state_revision_id,
              created_at_utc,
              selected_weakness_code
          ) VALUES ($1, $2, $3, $4, $5, $6, NULL, $7, $8)
          ON CONFLICT (
              local_account_id,
              raid_snapshot_id,
              season_number,
              client_build_code,
              client_executable_sha256,
              selected_weakness_code
          ) DO NOTHING;
          """;
      insert.Parameters.AddWithValue(Guid.NewGuid());
      insert.Parameters.AddWithValue(localAccountId);
      insert.Parameters.AddWithValue(raidSnapshotId);
      insert.Parameters.AddWithValue(key.SeasonNumber);
      insert.Parameters.AddWithValue(key.ClientBuildCode);
      insert.Parameters.AddWithValue(key.ClientExecutableSha256);
      insert.Parameters.AddWithValue(DateTimeOffset.UtcNow);
      insert.Parameters.AddWithValue(key.SelectedWeaknessCode);
      await insert.ExecuteNonQueryAsync(cancellationToken);
    }
    return await ReadAsync() ??
        throw new InvalidOperationException("phase_d_raid_state_aggregate_create_failed");
  }

  private static async Task<ClassicSoloRaidRuntimeStateHead?> ReadHeadForUpdateAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long stateId,
      CancellationToken cancellationToken)
  {
    await using var command = connection.CreateCommand();
    command.Transaction = transaction;
    command.CommandText = """
        SELECT revision.classic_solo_raid_runtime_state_revision_uid,
               revision.revision_number,
               revision.source_profile_revision_set_sha256,
               revision.protected_payload,
               revision.protected_payload_sha256,
               revision.state_content_sha256,
               revision.state_present,
               revision.has_open_run,
               revision.completed_best_total_damage,
               revision.completed_best_team_count,
               revision.open_team_count,
               revision.raid_date_day,
               revision.captured_at_utc
          FROM lab_private_server.classic_solo_raid_runtime_state state
          LEFT JOIN lab_private_server.classic_solo_raid_runtime_state_revision revision
            ON revision.classic_solo_raid_runtime_state_revision_id =
               state.current_classic_solo_raid_runtime_state_revision_id
         WHERE state.classic_solo_raid_runtime_state_id = $1
         FOR UPDATE OF state;
        """;
    command.Parameters.AddWithValue(stateId);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    if (!await reader.ReadAsync(cancellationToken))
    {
      throw new InvalidOperationException("phase_d_raid_state_aggregate_missing");
    }
    if (reader.IsDBNull(0)) return null;
    var head = ReadHead(reader);
    ValidateStoredHead(head);
    return head;
  }

  private static async Task InsertPendingOperationAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      ClassicSoloRaidRuntimeStateCapture capture,
      long stateId,
      CancellationToken cancellationToken)
  {
    await using var command = connection.CreateCommand();
    command.Transaction = transaction;
    command.CommandText = """
        INSERT INTO lab_private_server.classic_solo_raid_runtime_state_operation (
            source_launch_context_uid,
            request_sha256,
            classic_solo_raid_runtime_state_id,
            expected_head_revision_uid,
            operation_status,
            created_at_utc
        ) VALUES ($1, $2, $3, $4, 'pending', $5);
        """;
    command.Parameters.AddWithValue(capture.LaunchContextUid);
    command.Parameters.AddWithValue(capture.RequestSha256);
    command.Parameters.AddWithValue(stateId);
    command.Parameters.AddWithValue(
        NpgsqlDbType.Uuid,
        capture.ExpectedHeadRevisionUid.HasValue
            ? capture.ExpectedHeadRevisionUid.Value
            : DBNull.Value);
    command.Parameters.AddWithValue(DateTimeOffset.UtcNow);
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

  private static async Task<long> InsertRevisionAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long stateId,
      Guid revisionUid,
      ClassicSoloRaidRuntimeStateHead? current,
      ClassicSoloRaidRuntimeStateCapture capture,
      CancellationToken cancellationToken)
  {
    await using var command = connection.CreateCommand();
    command.Transaction = transaction;
    command.CommandText = """
        INSERT INTO lab_private_server.classic_solo_raid_runtime_state_revision (
            classic_solo_raid_runtime_state_revision_uid,
            classic_solo_raid_runtime_state_id,
            revision_number,
            previous_classic_solo_raid_runtime_state_revision_id,
            source_launch_context_uid,
            source_profile_revision_set_sha256,
            state_schema_version,
            protected_payload,
            protected_payload_byte_length,
            protected_payload_sha256,
            state_content_sha256,
            state_present,
            has_open_run,
            completed_best_total_damage,
            completed_best_team_count,
            open_team_count,
            raid_date_day,
            captured_at_utc,
            persisted_at_utc
        ) VALUES (
            $1, $2, $3,
            (SELECT classic_solo_raid_runtime_state_revision_id
               FROM lab_private_server.classic_solo_raid_runtime_state_revision
              WHERE classic_solo_raid_runtime_state_revision_uid = $4),
            $5, $6, 1, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18
        )
        RETURNING classic_solo_raid_runtime_state_revision_id;
        """;
    command.Parameters.AddWithValue(revisionUid);
    command.Parameters.AddWithValue(stateId);
    command.Parameters.AddWithValue((current?.RevisionNumber ?? 0) + 1);
    command.Parameters.AddWithValue(
        NpgsqlDbType.Uuid,
        current is null ? DBNull.Value : current.RevisionUid);
    command.Parameters.AddWithValue(capture.LaunchContextUid);
    command.Parameters.AddWithValue(capture.SourceProfileRevisionSetSha256);
    command.Parameters.AddWithValue(capture.ProtectedPayload);
    command.Parameters.AddWithValue(capture.ProtectedPayload.Length);
    command.Parameters.AddWithValue(capture.ProtectedPayloadSha256);
    command.Parameters.AddWithValue(capture.StateContentSha256);
    command.Parameters.AddWithValue(capture.StatePresent);
    command.Parameters.AddWithValue(capture.HasOpenRun);
    command.Parameters.AddWithValue(
        NpgsqlDbType.Bigint,
        capture.CompletedBestTotalDamage.HasValue
            ? capture.CompletedBestTotalDamage.Value
            : DBNull.Value);
    command.Parameters.AddWithValue(capture.CompletedBestTeamCount);
    command.Parameters.AddWithValue(capture.OpenTeamCount);
    command.Parameters.AddWithValue(
        NpgsqlDbType.Integer,
        capture.RaidDateDay.HasValue ? capture.RaidDateDay.Value : DBNull.Value);
    command.Parameters.AddWithValue(capture.CapturedAtUtc);
    command.Parameters.AddWithValue(DateTimeOffset.UtcNow);
    return (long)(await command.ExecuteScalarAsync(cancellationToken) ??
        throw new InvalidOperationException("phase_d_raid_state_revision_create_failed"));
  }

  private static async Task UpdateHeadAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long stateId,
      long revisionId,
      Guid? expectedRevisionUid,
      CancellationToken cancellationToken)
  {
    await using var command = connection.CreateCommand();
    command.Transaction = transaction;
    command.CommandText = """
        UPDATE lab_private_server.classic_solo_raid_runtime_state
           SET current_classic_solo_raid_runtime_state_revision_id = $1
         WHERE classic_solo_raid_runtime_state_id = $2
           AND (
               ($3::uuid IS NULL
                   AND current_classic_solo_raid_runtime_state_revision_id IS NULL)
               OR current_classic_solo_raid_runtime_state_revision_id = (
                   SELECT classic_solo_raid_runtime_state_revision_id
                     FROM lab_private_server.classic_solo_raid_runtime_state_revision
                    WHERE classic_solo_raid_runtime_state_revision_uid = $3
               )
           );
        """;
    command.Parameters.AddWithValue(revisionId);
    command.Parameters.AddWithValue(stateId);
    command.Parameters.AddWithValue(
        NpgsqlDbType.Uuid,
        expectedRevisionUid.HasValue ? expectedRevisionUid.Value : DBNull.Value);
    if (await command.ExecuteNonQueryAsync(cancellationToken) != 1)
    {
      throw new InvalidOperationException("phase_d_raid_state_head_update_failed");
    }
  }

  private static async Task CompleteOperationAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      Guid launchContextUid,
      string status,
      string resultCode,
      Guid? resultRevisionUid,
      byte[] resultHash,
      CancellationToken cancellationToken)
  {
    await using var command = connection.CreateCommand();
    command.Transaction = transaction;
    command.CommandText = """
        UPDATE lab_private_server.classic_solo_raid_runtime_state_operation
           SET operation_status = $1,
               result_code = $2,
               result_revision_uid = $3,
               result_state_content_sha256 = $4,
               completed_at_utc = $5
         WHERE source_launch_context_uid = $6
           AND operation_status = 'pending';
        """;
    command.Parameters.AddWithValue(status);
    command.Parameters.AddWithValue(resultCode);
    command.Parameters.AddWithValue(
        NpgsqlDbType.Uuid,
        resultRevisionUid.HasValue ? resultRevisionUid.Value : DBNull.Value);
    command.Parameters.AddWithValue(resultHash);
    command.Parameters.AddWithValue(DateTimeOffset.UtcNow);
    command.Parameters.AddWithValue(launchContextUid);
    if (await command.ExecuteNonQueryAsync(cancellationToken) != 1)
    {
      throw new InvalidOperationException("phase_d_raid_state_operation_complete_failed");
    }
  }

  private static async Task<OperationRow?> ReadOperationAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      Guid launchContextUid,
      CancellationToken cancellationToken)
  {
    await using var command = connection.CreateCommand();
    command.Transaction = transaction;
    command.CommandText = """
        SELECT request_sha256,
               operation_status,
               result_code,
               result_revision_uid,
               result_state_content_sha256
          FROM lab_private_server.classic_solo_raid_runtime_state_operation
         WHERE source_launch_context_uid = $1
         FOR UPDATE;
        """;
    command.Parameters.AddWithValue(launchContextUid);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    if (!await reader.ReadAsync(cancellationToken)) return null;
    return new OperationRow(
        reader.GetFieldValue<byte[]>(0),
        reader.GetString(1),
        reader.IsDBNull(2) ? null : reader.GetString(2),
        reader.IsDBNull(3) ? null : reader.GetGuid(3),
        reader.IsDBNull(4) ? null : reader.GetFieldValue<byte[]>(4));
  }

  private static ClassicSoloRaidRuntimeStateHead ReadHead(NpgsqlDataReader reader) => new(
      reader.GetGuid(0),
      reader.GetInt32(1),
      reader.GetFieldValue<byte[]>(2),
      reader.GetFieldValue<byte[]>(3),
      reader.GetFieldValue<byte[]>(4),
      reader.GetFieldValue<byte[]>(5),
      reader.GetBoolean(6),
      reader.GetBoolean(7),
      reader.IsDBNull(8) ? null : reader.GetInt64(8),
      reader.GetInt16(9),
      reader.GetInt16(10),
      reader.IsDBNull(11) ? null : reader.GetInt32(11),
      reader.GetFieldValue<DateTimeOffset>(12));

  private static void ValidateKey(ClassicSoloRaidRuntimeStateKey key)
  {
    Require(key.LocalAccountUid != Guid.Empty && key.RaidSnapshotUid != Guid.Empty &&
            key.SeasonNumber > 0 && IsSha256(key.RaidSnapshotSha256) &&
            IsSha256(key.ClientExecutableSha256) &&
            IsControlledCode(key.ClientBuildCode) &&
            key.SelectedWeaknessCode is "unresolved" or "iron" or "water" or "fire" or "wind" or "electric",
        "phase_d_raid_state_key_invalid");
  }

  private static void ValidateCapture(ClassicSoloRaidRuntimeStateCapture capture)
  {
    ValidateKey(capture.Key);
    Require(capture.LaunchContextUid != Guid.Empty && IsSha256(capture.RequestSha256) &&
            IsSha256(capture.SourceProfileRevisionSetSha256) &&
            capture.ProtectedPayload.Length is >= 53 and <= 67_108_864 &&
            IsSha256(capture.ProtectedPayloadSha256) &&
            IsSha256(capture.StateContentSha256) &&
            CryptographicOperations.FixedTimeEquals(
                SHA256.HashData(capture.ProtectedPayload),
                capture.ProtectedPayloadSha256) &&
            (!capture.HasOpenRun || capture.StatePresent) &&
            capture.CompletedBestTotalDamage is null or >= 0 &&
            capture.CompletedBestTeamCount is >= 0 and <= 5 &&
            capture.OpenTeamCount is >= 0 and <= 4 &&
            (capture.HasOpenRun || capture.OpenTeamCount == 0) &&
            ((capture.CompletedBestTotalDamage is null &&
                capture.CompletedBestTeamCount == 0) ||
             (capture.CompletedBestTotalDamage is not null &&
                capture.CompletedBestTeamCount == 5)) &&
            (capture.StatePresent ||
                (capture.CompletedBestTotalDamage is null &&
                 capture.CompletedBestTeamCount == 0 &&
                 capture.OpenTeamCount == 0 &&
                 capture.RaidDateDay is null)) &&
            capture.RaidDateDay is null or >= 0,
        "phase_d_raid_state_capture_invalid");
    Require(CryptographicOperations.FixedTimeEquals(
            ComputeRequestSha256(capture),
            capture.RequestSha256),
        "phase_d_raid_state_request_hash_invalid");
  }

  private static void ValidateStoredHead(ClassicSoloRaidRuntimeStateHead head)
  {
    Require(head.RevisionUid != Guid.Empty && head.RevisionNumber >= 1 &&
            IsSha256(head.SourceProfileRevisionSetSha256) &&
            head.ProtectedPayload.Length is >= 53 and <= 67_108_864 &&
            IsSha256(head.ProtectedPayloadSha256) &&
            IsSha256(head.StateContentSha256) &&
            CryptographicOperations.FixedTimeEquals(
                SHA256.HashData(head.ProtectedPayload),
                head.ProtectedPayloadSha256) &&
            (!head.HasOpenRun || head.StatePresent) &&
            head.CompletedBestTotalDamage is null or >= 0 &&
            head.CompletedBestTeamCount is >= 0 and <= 5 &&
            head.OpenTeamCount is >= 0 and <= 4 &&
            (head.HasOpenRun || head.OpenTeamCount == 0) &&
            ((head.CompletedBestTotalDamage is null &&
                head.CompletedBestTeamCount == 0) ||
             (head.CompletedBestTotalDamage is not null &&
                head.CompletedBestTeamCount is >= 1 and <= 5)) &&
            (head.StatePresent ||
                (head.CompletedBestTotalDamage is null &&
                 head.CompletedBestTeamCount == 0 &&
                 head.OpenTeamCount == 0 &&
                 head.RaidDateDay is null)) &&
            head.RaidDateDay is null or >= 0,
        "phase_d_raid_state_head_invalid");
  }

  private static bool IsSha256(byte[] value) => value.Length == 32;

  private static string LowerHex(byte[] value) =>
      Convert.ToHexString(value).ToLowerInvariant();

  private static bool IsControlledCode(string value) =>
      value.Length is >= 1 and <= 64 &&
      value[0] is >= 'a' and <= 'z' &&
      value.All(static character =>
          character is >= 'a' and <= 'z' or >= '0' and <= '9' or '.' or '_' or '-');

  private static void Require(bool condition, string code)
  {
    if (!condition) throw new InvalidOperationException(code);
  }

  private sealed record BindingIds(long LocalAccountId, long RaidSnapshotId);
  private sealed record AggregateRow(long StateId, Guid StateUid);
  private sealed record OperationRow(
      byte[] RequestSha256,
      string Status,
      string? ResultCode,
      Guid? ResultRevisionUid,
      byte[]? ResultStateContentSha256);
}
