using App = NikkeLocalLab.Application.ProfileManagement;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;
using Npgsql;
using NpgsqlTypes;

namespace NikkeLocalLab.Persistence.PostgreSql;

internal sealed record AccountWorkspaceSaveClaim(
    string OperationKind,
    Sha256Digest RequestSha256,
    EntityUid SourceAccountUid,
    EntityUid? ResolvedLobbyRevisionUid,
    bool ObservationProvenanceResolved,
    EntityUid? ResolvedObservationSnapshotUid,
    DateTimeOffset CreatedAtUtc,
    App.SaveAccountWorkspaceReceipt? CompletedReceipt);

internal sealed partial class PostgreSqlAccountWorkspaceSaveStore
{
  private readonly NpgsqlDataSource _dataSource;

  internal PostgreSqlAccountWorkspaceSaveStore(NpgsqlDataSource dataSource)
  {
    _dataSource = dataSource ?? throw new ArgumentNullException(nameof(dataSource));
  }

  internal async Task<AccountWorkspaceSaveClaim?> FindAsync(
      App.SaveAccountWorkspaceCommand request, CancellationToken cancellationToken)
  {
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken).ConfigureAwait(false);
    await using var transaction = await connection.BeginTransactionAsync(cancellationToken).ConfigureAwait(false);
    var claim = await ReadClaimAsync(connection, transaction, request.OperationUid, false, cancellationToken).ConfigureAwait(false);
    if (claim is not null)
    {
      EnsureRequest(claim, request.SaveAs ? "save_as" : "save", request.RequestSha256, request.SourceAccountUid);
      var payload = await ReadPayloadAsync(connection, transaction, request.OperationUid, cancellationToken).ConfigureAwait(false);
      if (payload is not null) ValidateEnvelope(request.OperationUid, claim, payload);
    }
    await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
    return claim;
  }

  internal async Task<IAsyncDisposable> AcquireAccountLeaseAsync(EntityUid accountUid, CancellationToken cancellationToken)
  {
    var connection = await _dataSource.OpenConnectionAsync(cancellationToken).ConfigureAwait(false);
    try
    {
      var transaction = await connection.BeginTransactionAsync(cancellationToken).ConfigureAwait(false);
      await using var command = new NpgsqlCommand(
          "SELECT pg_try_advisory_xact_lock(hashtextextended(@key, 0));", connection, transaction);
      Add(command, "key", NpgsqlDbType.Text, "nll/account-workspace-save/v1/" + accountUid);
      if (!Equals(true, await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false)))
        throw new App.ProfileManagementException(App.ProfileManagementFailureKind.Conflict, "account_workspace_save_in_progress");
      // Disposal rolls back the read-only transaction and releases the lock on
      // cancellation/failure too, before this connection returns to the pool.
      return connection;
    }
    catch
    {
      await connection.DisposeAsync().ConfigureAwait(false);
      throw;
    }
  }

  internal async Task<bool> HasCommittedProfileAsync(EntityUid childOperationUid, CancellationToken cancellationToken)
  {
    await using var command = _dataSource.CreateCommand(
        "SELECT EXISTS (SELECT 1 FROM lab_profile.profile_write_operation WHERE operation_uid = @operation_uid);");
    Add(command, "operation_uid", NpgsqlDbType.Uuid, childOperationUid.Value);
    return Equals(true, await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false));
  }

  internal async Task RequireNoPendingSaveAsync(EntityUid accountUid, CancellationToken cancellationToken)
  {
    var pendingCopies = new List<Guid>();
    await using (var query = _dataSource.CreateCommand("""
        SELECT operation.operation_uid, operation.source_account_uid
        FROM lab_profile.account_workspace_save_operation AS operation
        WHERE operation.operation_status = 'pending'
          AND (operation.source_account_uid = @account_uid
            OR (operation.operation_kind = 'save_as' AND operation.source_account_uid = (
              SELECT workspace.save_as_parent_account_uid
              FROM lab_profile.account_workspace AS workspace
              JOIN lab_profile.local_account AS account USING (local_account_id)
              WHERE account.local_account_uid = @account_uid)));
        """))
    {
      Add(query, "account_uid", NpgsqlDbType.Uuid, accountUid.Value);
      await using var reader = await query.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
      while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        if (reader.GetGuid(1) == accountUid.Value) throw PendingSave();
        pendingCopies.Add(AccountWorkspaceSaveCoordinator.ChildOperationUid(new EntityUid(reader.GetGuid(0)), "profile").Value);
      }
    }
    if (pendingCopies.Count == 0) return;
    await using var match = _dataSource.CreateCommand("""
        SELECT EXISTS (
          SELECT 1 FROM lab_profile.profile_write_operation AS operation
          JOIN lab_profile.local_account AS account USING (local_account_id)
          WHERE account.local_account_uid = @account_uid AND operation.operation_uid = ANY(@operations));
        """);
    Add(match, "account_uid", NpgsqlDbType.Uuid, accountUid.Value);
    Add(match, "operations", NpgsqlDbType.Array | NpgsqlDbType.Uuid, pendingCopies.ToArray());
    if (Equals(true, await match.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false))) throw PendingSave();
  }

  private static App.ProfileManagementException PendingSave() =>
      new(App.ProfileManagementFailureKind.Conflict, "account_workspace_save_pending");

  internal async Task<AccountWorkspaceSaveClaim> BeginAsync(
      EntityUid operationUid,
      string operationKind,
      Sha256Digest requestSha256,
      EntityUid sourceAccountUid,
      DateTimeOffset createdAtUtc,
      CancellationToken cancellationToken,
      byte[]? recoveryPayload = null)
  {
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using var transaction = await connection.BeginTransactionAsync(cancellationToken)
        .ConfigureAwait(false);
    var inserted = 0;
    await using (var insert = new NpgsqlCommand(
        """
        INSERT INTO lab_profile.account_workspace_save_operation (
            operation_uid,
            operation_kind,
            request_sha256,
            source_account_uid,
            operation_status,
            created_at_utc
        ) VALUES (
            @operation_uid,
            @operation_kind,
            @request_sha256,
            @source_account_uid,
            'pending',
            @created_at_utc
        )
        ON CONFLICT (operation_uid) DO NOTHING;
        """,
        connection,
        transaction))
    {
      Add(insert, "operation_uid", NpgsqlDbType.Uuid, operationUid.Value);
      Add(insert, "operation_kind", NpgsqlDbType.Text, operationKind);
      Add(insert, "request_sha256", NpgsqlDbType.Bytea, requestSha256.ToByteArray());
      Add(insert, "source_account_uid", NpgsqlDbType.Uuid, sourceAccountUid.Value);
      Add(insert, "created_at_utc", NpgsqlDbType.TimestampTz, createdAtUtc);
      inserted = await insert.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    var result = await ReadClaimAsync(
        connection,
        transaction,
        operationUid,
        forUpdate: true,
        cancellationToken).ConfigureAwait(false) ??
        throw new LocalAccountProfileIntegrityException("account_workspace_save_operation_missing");
    EnsureRequest(result, operationKind, requestSha256, sourceAccountUid);
    if (inserted == 1 && recoveryPayload is not null)
      await InsertRequestAsync(connection, transaction, operationUid, result, recoveryPayload, cancellationToken)
          .ConfigureAwait(false);
    await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
    return result;
  }

  internal async Task<EntityUid> ResolveLobbyRevisionAsync(
      EntityUid operationUid,
      Sha256Digest requestSha256,
      EntityUid lobbyRevisionUid,
      CancellationToken cancellationToken)
  {
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using var transaction = await connection.BeginTransactionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using (var update = new NpgsqlCommand(
        """
        UPDATE lab_profile.account_workspace_save_operation
        SET resolved_lobby_revision_uid = @lobby_revision_uid
        WHERE operation_uid = @operation_uid
          AND operation_status = 'pending'
          AND request_sha256 = @request_sha256
          AND operation_kind = 'save'
          AND resolved_lobby_revision_uid IS NULL;
        """,
        connection,
        transaction))
    {
      Add(update, "lobby_revision_uid", NpgsqlDbType.Uuid, lobbyRevisionUid.Value);
      Add(update, "operation_uid", NpgsqlDbType.Uuid, operationUid.Value);
      Add(update, "request_sha256", NpgsqlDbType.Bytea, requestSha256.ToByteArray());
      _ = await update.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    EntityUid? resolved = null;
    await using (var read = new NpgsqlCommand(
        """
        SELECT resolved_lobby_revision_uid
        FROM lab_profile.account_workspace_save_operation
        WHERE operation_uid = @operation_uid
          AND request_sha256 = @request_sha256
          AND operation_kind = 'save';
        """,
        connection,
        transaction))
    {
      Add(read, "operation_uid", NpgsqlDbType.Uuid, operationUid.Value);
      Add(read, "request_sha256", NpgsqlDbType.Bytea, requestSha256.ToByteArray());
      var value = await read.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
      if (value is Guid uid) resolved = new EntityUid(uid);
    }

    await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
    return resolved ?? throw new LocalAccountProfileIntegrityException(
        "account_workspace_save_lobby_resolution_missing");
  }

  internal async Task<EntityUid?> ResolveObservationSnapshotAsync(
      EntityUid operationUid,
      Sha256Digest requestSha256,
      EntityUid sourceAccountUid,
      CancellationToken cancellationToken)
  {
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using var transaction = await connection.BeginTransactionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using (var update = new NpgsqlCommand(
        """
        UPDATE lab_profile.account_workspace_save_operation AS operation
        SET observation_provenance_resolved = TRUE,
            resolved_observation_snapshot_uid = COALESCE(
                (
                    SELECT snapshot.fetched_account_snapshot_uid
                    FROM lab_profile.fetched_account_snapshot AS snapshot
                    JOIN lab_profile.local_account AS account
                      ON account.local_account_id = snapshot.target_local_account_id
                    WHERE account.local_account_uid = @source_account_uid
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
                    WHERE account.local_account_uid = @source_account_uid
                )
            )
        WHERE operation.operation_uid = @operation_uid
          AND operation.operation_status = 'pending'
          AND operation.operation_kind = 'save_as'
          AND operation.request_sha256 = @request_sha256
          AND operation.source_account_uid = @source_account_uid
          AND operation.observation_provenance_resolved = FALSE;
        """,
        connection,
        transaction))
    {
      Add(update, "operation_uid", NpgsqlDbType.Uuid, operationUid.Value);
      Add(update, "request_sha256", NpgsqlDbType.Bytea, requestSha256.ToByteArray());
      Add(update, "source_account_uid", NpgsqlDbType.Uuid, sourceAccountUid.Value);
      _ = await update.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    var claim = await ReadClaimAsync(
        connection,
        transaction,
        operationUid,
        forUpdate: true,
        cancellationToken).ConfigureAwait(false) ??
        throw new LocalAccountProfileIntegrityException("account_workspace_save_operation_missing");
    EnsureRequest(claim, "save_as", requestSha256, sourceAccountUid);
    if (!claim.ObservationProvenanceResolved)
    {
      throw new LocalAccountProfileIntegrityException(
          "account_workspace_save_observation_resolution_missing");
    }

    await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
    return claim.ResolvedObservationSnapshotUid;
  }

  internal async Task BindObservationProvenanceAsync(
      EntityUid operationUid,
      Sha256Digest requestSha256,
      EntityUid sourceAccountUid,
      EntityUid targetAccountUid,
      EntityUid? sourceSnapshotUid,
      DateTimeOffset boundAtUtc,
      CancellationToken cancellationToken)
  {
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using var transaction = await connection.BeginTransactionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using (var insert = new NpgsqlCommand(
        """
        INSERT INTO lab_profile.account_observation_provenance_binding (
            target_local_account_id,
            save_as_source_account_uid,
            source_snapshot_uid,
            binding_kind,
            save_operation_uid,
            bound_at_utc
        )
        SELECT target.local_account_id,
               @source_account_uid,
               @source_snapshot_uid,
               'save_as/v1',
               operation.operation_uid,
               @bound_at_utc
        FROM lab_profile.local_account AS target
        JOIN lab_profile.account_workspace_save_operation AS operation
          ON operation.operation_uid = @operation_uid
         AND operation.operation_status = 'pending'
         AND operation.operation_kind = 'save_as'
         AND operation.request_sha256 = @request_sha256
         AND operation.source_account_uid = @source_account_uid
         AND operation.observation_provenance_resolved = TRUE
         AND operation.resolved_observation_snapshot_uid IS NOT DISTINCT FROM @source_snapshot_uid
        WHERE target.local_account_uid = @target_account_uid
          AND (
              @source_snapshot_uid IS NULL
              OR EXISTS (
                  SELECT 1
                  FROM lab_profile.fetched_account_snapshot AS snapshot
                  WHERE snapshot.fetched_account_snapshot_uid = @source_snapshot_uid
              )
          )
        ON CONFLICT (target_local_account_id) DO NOTHING;
        """,
        connection,
        transaction))
    {
      Add(insert, "source_account_uid", NpgsqlDbType.Uuid, sourceAccountUid.Value);
      Add(insert, "source_snapshot_uid", NpgsqlDbType.Uuid, sourceSnapshotUid?.Value);
      Add(insert, "bound_at_utc", NpgsqlDbType.TimestampTz, boundAtUtc);
      Add(insert, "operation_uid", NpgsqlDbType.Uuid, operationUid.Value);
      Add(insert, "request_sha256", NpgsqlDbType.Bytea, requestSha256.ToByteArray());
      Add(insert, "target_account_uid", NpgsqlDbType.Uuid, targetAccountUid.Value);
      _ = await insert.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    await using (var read = new NpgsqlCommand(
        """
        SELECT binding.save_as_source_account_uid,
               binding.source_snapshot_uid,
               binding.binding_kind,
               binding.save_operation_uid
        FROM lab_profile.account_observation_provenance_binding AS binding
        JOIN lab_profile.local_account AS account
          ON account.local_account_id = binding.target_local_account_id
        WHERE account.local_account_uid = @target_account_uid;
        """,
        connection,
        transaction))
    {
      Add(read, "target_account_uid", NpgsqlDbType.Uuid, targetAccountUid.Value);
      await using var reader = await read.ExecuteReaderAsync(cancellationToken)
          .ConfigureAwait(false);
      if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false) ||
          new EntityUid(reader.GetGuid(0)) != sourceAccountUid ||
          (reader.IsDBNull(1) ? (EntityUid?)null : new EntityUid(reader.GetGuid(1))) !=
              sourceSnapshotUid ||
          !string.Equals(reader.GetString(2), "save_as/v1", StringComparison.Ordinal) ||
          new EntityUid(reader.GetGuid(3)) != operationUid)
      {
        throw new LocalAccountProfileIntegrityException(
            "account_workspace_save_observation_binding_mismatch");
      }
    }

    await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
  }

  internal async Task<App.SaveAccountWorkspaceReceipt> CompleteAsync(
      EntityUid operationUid,
      string operationKind,
      Sha256Digest requestSha256,
      EntityUid sourceAccountUid,
      App.SaveAccountWorkspaceReceipt receipt,
      DateTimeOffset completedAtUtc,
      CancellationToken cancellationToken)
  {
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using var transaction = await connection.BeginTransactionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using (var update = new NpgsqlCommand(
        """
        UPDATE lab_profile.account_workspace_save_operation
        SET operation_status = 'completed',
            result_account_uid = @result_account_uid,
            result_account_label = @result_account_label,
            result_profile_revision_uid = @result_profile_revision_uid,
            result_lobby_revision_uid = @result_lobby_revision_uid,
            result_wallet_revision_uid = @result_wallet_revision_uid,
            result_revision_set_sha256 = @result_revision_set_sha256,
            completed_at_utc = @completed_at_utc
        WHERE operation_uid = @operation_uid
          AND operation_status = 'pending'
          AND operation_kind = @operation_kind
          AND request_sha256 = @request_sha256
          AND source_account_uid = @source_account_uid;
        """,
        connection,
        transaction))
    {
      Add(update, "result_account_uid", NpgsqlDbType.Uuid, receipt.AccountUid.Value);
      Add(update, "result_account_label", NpgsqlDbType.Text, receipt.AccountLabel);
      Add(update, "result_profile_revision_uid", NpgsqlDbType.Uuid,
          receipt.ProfileRevision.RevisionUid.Value);
      Add(update, "result_lobby_revision_uid", NpgsqlDbType.Uuid,
          receipt.LobbyRevision.RevisionUid.Value);
      Add(update, "result_wallet_revision_uid", NpgsqlDbType.Uuid,
          receipt.WalletRevision.RevisionUid.Value);
      Add(update, "result_revision_set_sha256", NpgsqlDbType.Bytea,
          receipt.RevisionSetSha256.ToByteArray());
      Add(update, "completed_at_utc", NpgsqlDbType.TimestampTz, completedAtUtc);
      Add(update, "operation_uid", NpgsqlDbType.Uuid, operationUid.Value);
      Add(update, "operation_kind", NpgsqlDbType.Text, operationKind);
      Add(update, "request_sha256", NpgsqlDbType.Bytea, requestSha256.ToByteArray());
      Add(update, "source_account_uid", NpgsqlDbType.Uuid, sourceAccountUid.Value);
      _ = await update.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    var stored = await ReadClaimAsync(
        connection,
        transaction,
        operationUid,
        forUpdate: true,
        cancellationToken).ConfigureAwait(false) ??
        throw new LocalAccountProfileIntegrityException("account_workspace_save_operation_missing");
    EnsureRequest(stored, operationKind, requestSha256, sourceAccountUid);
    var completed = stored.CompletedReceipt ??
        throw new LocalAccountProfileIntegrityException("account_workspace_save_completion_missing");
    if (completed with { IsIdempotentReplay = false } !=
        receipt with { IsIdempotentReplay = false })
    {
      throw new LocalAccountProfileIntegrityException("account_workspace_save_result_mismatch");
    }

    await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
    return completed;
  }

  private static void EnsureRequest(
      AccountWorkspaceSaveClaim claim,
      string operationKind,
      Sha256Digest requestSha256,
      EntityUid sourceAccountUid)
  {
    if (!string.Equals(claim.OperationKind, operationKind, StringComparison.Ordinal) ||
        claim.RequestSha256 != requestSha256 ||
        claim.SourceAccountUid != sourceAccountUid)
    {
      throw new LocalAccountProfileIntegrityException(
          "account_workspace_save_operation_reuse_mismatch");
    }
  }

  private static async Task<AccountWorkspaceSaveClaim?> ReadClaimAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid operationUid,
      bool forUpdate,
      CancellationToken cancellationToken)
  {
    var sql =
        """
        SELECT operation.operation_kind,
               operation.request_sha256,
               operation.source_account_uid,
               operation.operation_status,
               operation.resolved_lobby_revision_uid,
               operation.observation_provenance_resolved,
               operation.resolved_observation_snapshot_uid,
               operation.created_at_utc,
               operation.result_account_uid,
               operation.result_account_label,
               profile.profile_template_revision_uid,
               profile.content_sha256,
               profile.revision_number,
               lobby.lobby_presentation_revision_uid,
               lobby.content_sha256,
               lobby.revision_number,
               wallet.wallet_revision_uid,
               wallet.content_sha256,
               wallet.revision_number,
               operation.result_revision_set_sha256
        FROM lab_profile.account_workspace_save_operation AS operation
        LEFT JOIN lab_profile.profile_template_revision AS profile
          ON profile.profile_template_revision_uid = operation.result_profile_revision_uid
        LEFT JOIN lab_local_game.lobby_presentation_revision AS lobby
          ON lobby.lobby_presentation_revision_uid = operation.result_lobby_revision_uid
        LEFT JOIN lab_local_game.wallet_revision AS wallet
          ON wallet.wallet_revision_uid = operation.result_wallet_revision_uid
        WHERE operation.operation_uid = @operation_uid
        """ + (forUpdate ? " FOR UPDATE OF operation;" : ";");
    await using var command = new NpgsqlCommand(sql, connection, transaction);
    Add(command, "operation_uid", NpgsqlDbType.Uuid, operationUid.Value);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken)
        .ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false)) return null;

    var kind = reader.GetString(0);
    var requestSha256 = Sha256Digest.FromBytes((byte[])reader.GetValue(1));
    var sourceAccountUid = new EntityUid(reader.GetGuid(2));
    var resolvedLobbyRevisionUid = reader.IsDBNull(4)
        ? (EntityUid?)null
        : new EntityUid(reader.GetGuid(4));
    App.SaveAccountWorkspaceReceipt? receipt = null;
    if (string.Equals(reader.GetString(3), "completed", StringComparison.Ordinal))
    {
      var resultAccountUid = new EntityUid(reader.GetGuid(8));
      var profile = new App.RevisionReference(
          new EntityUid(reader.GetGuid(10)),
          Sha256Digest.FromBytes((byte[])reader.GetValue(11)),
          reader.GetInt32(12));
      var lobby = new App.RevisionReference(
          new EntityUid(reader.GetGuid(13)),
          Sha256Digest.FromBytes((byte[])reader.GetValue(14)),
          reader.GetInt32(15));
      var wallet = new App.RevisionReference(
          new EntityUid(reader.GetGuid(16)),
          Sha256Digest.FromBytes((byte[])reader.GetValue(17)),
          reader.GetInt32(18));
      receipt = new App.SaveAccountWorkspaceReceipt(
          operationUid,
          true,
          string.Equals(kind, "save_as", StringComparison.Ordinal),
          sourceAccountUid,
          resultAccountUid,
          reader.GetString(9),
          profile,
          lobby,
          wallet,
          Sha256Digest.FromBytes((byte[])reader.GetValue(19)),
          reader.IsDBNull(6) ? null : new EntityUid(reader.GetGuid(6)));
    }

    return new AccountWorkspaceSaveClaim(
        kind,
        requestSha256,
        sourceAccountUid,
        resolvedLobbyRevisionUid,
        reader.GetBoolean(5),
        reader.IsDBNull(6) ? null : new EntityUid(reader.GetGuid(6)),
        reader.GetFieldValue<DateTimeOffset>(7),
        receipt);
  }

  private static void Add(NpgsqlCommand command, string name, NpgsqlDbType type, object? value)
  {
    command.Parameters.Add(name, type).Value = value ?? DBNull.Value;
  }
}
