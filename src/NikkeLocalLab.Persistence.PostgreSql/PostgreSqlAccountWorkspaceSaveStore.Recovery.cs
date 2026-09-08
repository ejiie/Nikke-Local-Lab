using System.Data;
using App = NikkeLocalLab.Application.ProfileManagement;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;
using Npgsql;
using NpgsqlTypes;

namespace NikkeLocalLab.Persistence.PostgreSql;

internal sealed partial class PostgreSqlAccountWorkspaceSaveStore
{
  private static async Task InsertRequestAsync(NpgsqlConnection connection, NpgsqlTransaction transaction,
      EntityUid operationUid, AccountWorkspaceSaveClaim claim, byte[] payload, CancellationToken cancellationToken)
  {
    ValidateEnvelope(operationUid, claim, payload);
    await using var insert = new NpgsqlCommand("""
        INSERT INTO lab_profile.account_workspace_save_request
          (operation_uid, source_account_uid, operation_kind, request_sha256, contract_id, request_payload, payload_sha256)
        VALUES (@operation, @account, @kind, @request_hash, @contract, @payload, sha256(@payload));
        """, connection, transaction);
    Add(insert, "operation", NpgsqlDbType.Uuid, operationUid.Value);
    Add(insert, "account", NpgsqlDbType.Uuid, claim.SourceAccountUid.Value);
    Add(insert, "kind", NpgsqlDbType.Text, claim.OperationKind);
    Add(insert, "request_hash", NpgsqlDbType.Bytea, claim.RequestSha256.ToByteArray());
    Add(insert, "contract", NpgsqlDbType.Text, App.WorkspaceSaveRequestCodec.ContractId);
    Add(insert, "payload", NpgsqlDbType.Bytea, payload);
    await insert.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
  }

  private static App.SaveAccountWorkspaceCommand ValidateEnvelope(
      EntityUid operationUid, AccountWorkspaceSaveClaim claim, byte[] payload)
  {
    var command = App.WorkspaceSaveRequestCodec.Decode(payload);
    if (command.OperationUid != operationUid) throw InvalidEnvelope();
    EnsureRequest(claim, command.SaveAs ? "save_as" : "save", command.RequestSha256, command.SourceAccountUid);
    return command;
  }

  private static async Task<byte[]?> ReadPayloadAsync(NpgsqlConnection connection, NpgsqlTransaction transaction,
      EntityUid operationUid, CancellationToken cancellationToken)
  {
    await using var query = new NpgsqlCommand("""
        SELECT request_payload, payload_sha256, contract_id
        FROM lab_profile.account_workspace_save_request WHERE operation_uid = @operation;
        """, connection, transaction);
    Add(query, "operation", NpgsqlDbType.Uuid, operationUid.Value);
    await using var reader = await query.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false)) return null;
    var payload = (byte[])reader.GetValue(0);
    if (reader.GetString(2) != App.WorkspaceSaveRequestCodec.ContractId ||
        Sha256Digest.Compute(payload) != Sha256Digest.FromBytes((byte[])reader.GetValue(1))) throw InvalidEnvelope();
    return payload;
  }

  internal async Task<(App.SaveAccountWorkspaceCommand? Request, App.SaveAccountWorkspaceReceipt? Receipt)> ReadRecoveryRequestAsync(
      App.ResumeWorkspaceSaveCommand command, CancellationToken cancellationToken)
  {
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken).ConfigureAwait(false);
    await using var transaction = await connection.BeginTransactionAsync(IsolationLevel.RepeatableRead, cancellationToken).ConfigureAwait(false);
    var claim = await ReadClaimAsync(connection, transaction, command.OperationUid, false, cancellationToken).ConfigureAwait(false);
    // Never let an operation UID select a different source account on this route.
    if (claim is null || claim.SourceAccountUid != command.SourceAccountUid)
      throw new App.ProfileManagementException(App.ProfileManagementFailureKind.NotFound, "account_workspace_save_not_found");
    if (claim.RequestSha256 != command.ExpectedRequestSha256)
      throw new App.ProfileManagementException(App.ProfileManagementFailureKind.Conflict, "account_workspace_save_operation_reuse_mismatch");
    if (claim.CompletedReceipt is not null) return (null, claim.CompletedReceipt);
    var payload = await ReadPayloadAsync(connection, transaction, command.OperationUid, cancellationToken).ConfigureAwait(false)
        ?? throw new App.ProfileManagementException(App.ProfileManagementFailureKind.Conflict, "account_workspace_save_original_request_required");
    return (ValidateEnvelope(command.OperationUid, claim, payload), null);
  }

  internal async Task<IReadOnlyList<App.WorkspaceSaveRecoveryProjection>> GetRecoveryAsync(
      EntityUid accountUid, CancellationToken cancellationToken)
  {
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken).ConfigureAwait(false);
    await using var transaction = await connection.BeginTransactionAsync(IsolationLevel.RepeatableRead, cancellationToken).ConfigureAwait(false);
    var operations = new List<EntityUid>();
    await using (var query = new NpgsqlCommand("""
        SELECT operation_uid FROM lab_profile.account_workspace_save_operation
        WHERE (operation_status = 'pending' AND
          (source_account_uid = @account OR source_account_uid = (
            SELECT save_as_parent_account_uid FROM lab_profile.account_workspace workspace
            JOIN lab_profile.local_account account USING (local_account_id) WHERE local_account_uid = @account)))
          OR operation_uid = (SELECT operation_uid FROM lab_profile.account_workspace_save_operation
            WHERE operation_status = 'completed' AND (source_account_uid = @account OR result_account_uid = @account)
            ORDER BY completed_at_utc DESC, operation_uid DESC LIMIT 1)
        ORDER BY created_at_utc DESC, operation_uid DESC LIMIT 101;
        """, connection, transaction))
    {
      Add(query, "account", NpgsqlDbType.Uuid, accountUid.Value);
      await using var reader = await query.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
      while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false)) operations.Add(new EntityUid(reader.GetGuid(0)));
    }
    if (operations.Count > 100)
      throw new App.ProfileManagementException(App.ProfileManagementFailureKind.Conflict, "account_workspace_save_recovery_limit");
    var result = new List<App.WorkspaceSaveRecoveryProjection>();
    foreach (var operation in operations)
    {
      var claim = (await ReadClaimAsync(connection, transaction, operation, false, cancellationToken).ConfigureAwait(false))!;
      if (claim.SourceAccountUid != accountUid && claim.CompletedReceipt?.AccountUid != accountUid)
      {
        if (claim.OperationKind != "save_as") continue;
        await using var match = new NpgsqlCommand("""
            SELECT EXISTS (SELECT 1 FROM lab_profile.profile_write_operation operation
              JOIN lab_profile.local_account account USING (local_account_id)
              WHERE operation.operation_uid = @child AND account.local_account_uid = @account);
            """, connection, transaction);
        Add(match, "child", NpgsqlDbType.Uuid, AccountWorkspaceSaveCoordinator.ChildOperationUid(operation, "profile").Value);
        Add(match, "account", NpgsqlDbType.Uuid, accountUid.Value);
        if (!Equals(true, await match.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false))) continue;
      }
      var recovery = "completed_receipt";
      if (claim.CompletedReceipt is null)
      {
        try
        {
          var payload = await ReadPayloadAsync(connection, transaction, operation, cancellationToken).ConfigureAwait(false);
          if (payload is not null) ValidateEnvelope(operation, claim, payload);
          recovery = payload is null ? "original_request_required" : "exact_request_available";
        }
        catch (Exception error) when (error is App.ProfileManagementException or LocalAccountProfileIntegrityException)
        {
          recovery = "request_invalid";
        }
      }
      result.Add(new App.WorkspaceSaveRecoveryProjection(operation, claim.SourceAccountUid, claim.OperationKind == "save_as",
          claim.CompletedReceipt is null ? "pending" : "completed", claim.RequestSha256, claim.CreatedAtUtc, recovery, claim.CompletedReceipt));
    }
    return result.AsReadOnly();
  }

  private static App.ProfileManagementException InvalidEnvelope() => new(
      App.ProfileManagementFailureKind.Conflict, "account_workspace_save_request_invalid");
}
