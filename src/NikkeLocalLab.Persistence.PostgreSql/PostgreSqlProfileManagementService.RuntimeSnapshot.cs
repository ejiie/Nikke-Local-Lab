using System.Data;
using App = NikkeLocalLab.Application.ProfileManagement;
using NikkeLocalLab.Identity;
using Npgsql;
using NpgsqlTypes;

namespace NikkeLocalLab.Persistence.PostgreSql;

public sealed partial class PostgreSqlProfileManagementService
{
  public Task<App.RuntimeProjectionSnapshot?> GetRuntimeProjectionSnapshotAsync(
      EntityUid accountUid,
      CancellationToken cancellationToken = default) => TranslateAsync(async () =>
  {
    var snapshot = await ReadAccountSnapshotAsync(accountUid, forRuntime: true, cancellationToken).ConfigureAwait(false);
    return snapshot is null ? null : new App.RuntimeProjectionSnapshot(
        CreateRuntimeCandidate(snapshot), snapshot.Lobby is null ? null : MapLobby(accountUid, snapshot.Lobby));
  });

  private async Task<AccountReadSnapshot?> ReadAccountSnapshotAsync(
      EntityUid accountUid,
      bool forRuntime,
      CancellationToken cancellationToken)
  {
    var dataSource = _workspaceDataSource ?? throw Failure(
        App.ProfileManagementFailureKind.Unavailable, "account_workspace_not_configured");
    await using var connection = await dataSource.OpenConnectionAsync(cancellationToken).ConfigureAwait(false);
    await using var transaction = await connection.BeginTransactionAsync(IsolationLevel.RepeatableRead, cancellationToken).ConfigureAwait(false);
    var summary = await PostgreSqlAccountWorkspaceStore.GetAsync(connection, transaction, accountUid, cancellationToken).ConfigureAwait(false);
    if (summary is null) return null;

    // Save children commit independently. A consistent MVCC view alone can still
    // contain half a workspace Save; reject it without mutating its recovery ledger.
    if (forRuntime)
      await RequireCompletedWorkspaceViewAsync(connection, transaction, summary, cancellationToken).ConfigureAwait(false);
    var profile = await PostgreSqlLocalAccountProfileStore.GetCurrentAsync(connection, transaction, accountUid, cancellationToken).ConfigureAwait(false)
        ?? throw Failure(App.ProfileManagementFailureKind.Conflict, "profile_current_revision_missing");
    if (profile.Revision.ProfileTemplateRevisionUid != summary.ProfileRevision.RevisionUid ||
        profile.Revision.AccountCombatStateRevisionUid != summary.AccountStateRevisionUid)
      throw Failure(App.ProfileManagementFailureKind.Conflict, "runtime_projection_snapshot_conflict");
    var lobby = forRuntime
        ? await PostgreSqlLocalGameStateStore.GetRuntimeLobbyAsync(connection, transaction, accountUid, cancellationToken).ConfigureAwait(false)
        : null;
    await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
    return new AccountReadSnapshot(summary, profile, lobby);
  }

  private static App.RuntimeProjectionCandidate CreateRuntimeCandidate(AccountReadSnapshot snapshot)
  {
    var summary = snapshot.Summary;
    var values = MapProfile(snapshot.Profile).Values;
    var readiness = ComputeRuntimeMaterializationReadiness(values);
    var revisions = new App.AccountWorkspaceBaseRevisions(
        summary.ProfileRevision.RevisionUid, summary.AccountStateRevisionUid, null,
        App.AccountWorkspaceCanonicalizer.ComputeRevisionSet(summary.ProfileRevision.RevisionUid, summary.AccountStateRevisionUid, null));
    return new App.RuntimeProjectionCandidate(1, "nll/runtime-projection-candidate/v1",
        App.AccountWorkspaceCanonicalizer.ComputeRuntimeCandidate(summary.AccountUid, summary.AccountLabel,
            revisions, readiness.StatusCode, readiness.ReasonCodes, values),
        summary.AccountUid, summary.AccountLabel, revisions, readiness.StatusCode, readiness.ReasonCodes, values);
  }

  private static async Task RequireCompletedWorkspaceViewAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      App.AccountSummaryProjection summary,
      CancellationToken cancellationToken)
  {
    // A Save As claim names its source, not its not-yet-created result. Match its
    // deterministic child write to this exact account; sibling copies stay usable.
    var copyWriteOperations = new List<Guid>();
    await using (var command = new NpgsqlCommand("""
        SELECT operation_uid, operation_kind
        FROM lab_profile.account_workspace_save_operation
        WHERE operation_status = 'pending'
          AND ((operation_kind = 'save' AND source_account_uid = @account_uid)
            OR (operation_kind = 'save_as' AND source_account_uid = @parent_uid));
        """, connection, transaction))
    {
      command.Parameters.AddWithValue("account_uid", summary.AccountUid.Value);
      command.Parameters.Add("parent_uid", NpgsqlDbType.Uuid).Value = (object?)summary.SaveAsParentAccountUid?.Value ?? DBNull.Value;
      await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
      while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        if (reader.GetString(1) == "save") throw PendingWorkspaceSave();
        copyWriteOperations.Add(DerivedOperationUid(new EntityUid(reader.GetGuid(0)), "profile").Value);
      }
    }
    if (copyWriteOperations.Count == 0) return;
    await using var match = new NpgsqlCommand("""
        SELECT EXISTS (
          SELECT 1 FROM lab_profile.profile_write_operation AS operation
          JOIN lab_profile.local_account AS account ON account.local_account_id = operation.local_account_id
          WHERE account.local_account_uid = @account_uid AND operation.operation_uid = ANY(@operation_uids)
        );
        """, connection, transaction);
    match.Parameters.AddWithValue("account_uid", summary.AccountUid.Value);
    match.Parameters.AddWithValue("operation_uids", copyWriteOperations.ToArray());
    if (Equals(true, await match.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false))) throw PendingWorkspaceSave();
  }

  private static App.ProfileManagementException PendingWorkspaceSave() =>
      Failure(App.ProfileManagementFailureKind.Conflict, "account_workspace_save_pending");

  private sealed record AccountReadSnapshot(
      App.AccountSummaryProjection Summary,
      LocalCurrentAccountProfile Profile,
      LocalLobbyPresentationReceipt? Lobby);
}
