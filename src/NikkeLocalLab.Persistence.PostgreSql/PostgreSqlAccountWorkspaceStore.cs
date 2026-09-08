using App = NikkeLocalLab.Application.ProfileManagement;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;
using Npgsql;
using NpgsqlTypes;

namespace NikkeLocalLab.Persistence.PostgreSql;

internal sealed class PostgreSqlAccountWorkspaceStore
{
  private readonly NpgsqlDataSource _dataSource;

  internal PostgreSqlAccountWorkspaceStore(NpgsqlDataSource dataSource)
  {
    _dataSource = dataSource ?? throw new ArgumentNullException(nameof(dataSource));
  }

  internal async Task<IReadOnlyList<App.AccountSummaryProjection>> ListAsync(
      CancellationToken cancellationToken)
  {
    await using var command = _dataSource.CreateCommand(SummarySql +
        " ORDER BY workspace.account_label COLLATE \"C\", account.local_account_uid;");
    var result = new List<App.AccountSummaryProjection>();
    await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      result.Add(ReadSummary(reader));
    }

    return result.AsReadOnly();
  }

  internal async Task<App.AccountSummaryProjection?> GetAsync(
      EntityUid accountUid,
      CancellationToken cancellationToken)
  {
    RequireUid(accountUid);
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken).ConfigureAwait(false);
    return await GetAsync(connection, null, accountUid, cancellationToken).ConfigureAwait(false);
  }

  internal static async Task<App.AccountSummaryProjection?> GetAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      EntityUid accountUid,
      CancellationToken cancellationToken)
  {
    RequireUid(accountUid);
    await using var command = new NpgsqlCommand(SummarySql +
        " WHERE account.local_account_uid = @account_uid;", connection, transaction);
    Add(command, "account_uid", NpgsqlDbType.Uuid, accountUid.Value);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    return await reader.ReadAsync(cancellationToken).ConfigureAwait(false)
        ? ReadSummary(reader)
        : null;
  }

  internal async Task<App.AccountRevisionHistoryProjection?> GetHistoryAsync(
      EntityUid accountUid,
      CancellationToken cancellationToken)
  {
    RequireUid(accountUid);
    const string sql = """
        SELECT
            workspace.account_label,
            revision.profile_template_revision_uid,
            revision.content_sha256,
            revision.revision_number,
            account_state.account_state_revision_uid,
            previous.profile_template_revision_uid,
            revision.revision_origin,
            revision.materialized_at_utc
        FROM lab_profile.local_account AS account
        JOIN lab_profile.account_workspace AS workspace
          ON workspace.local_account_id = account.local_account_id
        JOIN lab_profile.profile_template_revision AS revision
          ON revision.local_account_id = account.local_account_id
        JOIN lab_profile.account_state_revision AS account_state
          ON account_state.account_state_revision_id = revision.account_state_revision_id
        LEFT JOIN lab_profile.profile_template_revision AS previous
          ON previous.profile_template_revision_id = revision.previous_profile_template_revision_id
        WHERE account.local_account_uid = @account_uid
        ORDER BY revision.revision_number DESC;
        """;
    await using var command = _dataSource.CreateCommand(sql);
    Add(command, "account_uid", NpgsqlDbType.Uuid, accountUid.Value);
    var revisions = new List<App.AccountRevisionProjection>();
    string? label = null;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      label ??= reader.GetString(0);
      revisions.Add(new App.AccountRevisionProjection(
          new App.RevisionReference(
              new EntityUid(reader.GetGuid(1)),
              Sha256Digest.FromBytes((byte[])reader.GetValue(2)),
              reader.GetInt32(3)),
          new EntityUid(reader.GetGuid(4)),
          reader.IsDBNull(5) ? null : new EntityUid(reader.GetGuid(5)),
          reader.GetString(6),
          reader.GetFieldValue<DateTimeOffset>(7)));
    }

    return label is null
        ? null
        : new App.AccountRevisionHistoryProjection(accountUid, label, revisions.AsReadOnly());
  }

  internal async Task<App.AccountSummaryProjection> RenameAsync(
      App.RenameAccountCommand command,
      DateTimeOffset updatedAtUtc,
      CancellationToken cancellationToken)
  {
    ArgumentNullException.ThrowIfNull(command);
    RequireUid(command.AccountUid);
    var expected = App.ProfileManagementText.NormalizeAccountLabel(command.ExpectedAccountLabel);
    var replacement = App.ProfileManagementText.NormalizeAccountLabel(command.AccountLabel);
    const string sql = """
        UPDATE lab_profile.account_workspace AS workspace
        SET account_label = @replacement,
            updated_at_utc = @updated_at
        FROM lab_profile.local_account AS account
        WHERE account.local_account_id = workspace.local_account_id
          AND account.local_account_uid = @account_uid
          AND workspace.account_label = @expected;
        """;
    try
    {
      await using var update = _dataSource.CreateCommand(sql);
      Add(update, "replacement", NpgsqlDbType.Text, replacement);
      Add(update, "updated_at", NpgsqlDbType.TimestampTz, updatedAtUtc);
      Add(update, "account_uid", NpgsqlDbType.Uuid, command.AccountUid.Value);
      Add(update, "expected", NpgsqlDbType.Text, expected);
      if (await update.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false) != 1)
      {
        throw new LocalAccountProfileIntegrityException("account_label_conflict");
      }
    }
    catch (PostgresException exception) when (exception.SqlState == PostgresErrorCodes.UniqueViolation)
    {
      throw new LocalAccountProfileIntegrityException("account_label_conflict");
    }

    return await GetAsync(command.AccountUid, cancellationToken).ConfigureAwait(false) ??
        throw new LocalAccountProfileIntegrityException("profile_account_not_found");
  }

  private static App.AccountSummaryProjection ReadSummary(NpgsqlDataReader reader)
  {
    var issues = new List<string>();
    if (!reader.GetBoolean(14)) issues.Add("profile_selection_not_ready");
    if (!reader.GetBoolean(15)) issues.Add("profile_combat_semantics_incomplete");
    if (!string.Equals(reader.GetString(16), "ready", StringComparison.Ordinal))
    {
      issues.Add(reader.IsDBNull(17) ? "profile_game_legal_unresolved" : reader.GetString(17));
    }

    var status = issues.Count == 0 ? "ready" : "unresolved";
    return new App.AccountSummaryProjection(
        new EntityUid(reader.GetGuid(0)),
        new EntityUid(reader.GetGuid(1)),
        reader.GetString(2),
        new App.RevisionReference(
            new EntityUid(reader.GetGuid(3)),
            Sha256Digest.FromBytes((byte[])reader.GetValue(4)),
            reader.GetInt32(5)),
        new EntityUid(reader.GetGuid(6)),
        reader.GetFieldValue<DateTimeOffset>(7),
        reader.GetFieldValue<DateTimeOffset>(8),
        reader.IsDBNull(12) ? null : new EntityUid(reader.GetGuid(12)),
        reader.IsDBNull(9) ? null : reader.GetFieldValue<DateTimeOffset>(9),
        reader.IsDBNull(10) ? null : reader.GetString(10),
        status,
        issues.AsReadOnly(),
        reader.IsDBNull(11) ? null : new EntityUid(reader.GetGuid(11)));
  }

  private const string SummarySql = """
      SELECT
          workspace.workspace_uid,
          account.local_account_uid,
          workspace.account_label,
          profile.profile_template_revision_uid,
          profile.content_sha256,
          profile.revision_number,
          account_state.account_state_revision_uid,
          account.created_at_utc,
          profile.materialized_at_utc,
          workspace.last_fetched_at_utc,
          workspace.last_execution_result_code,
          workspace.save_as_parent_account_uid,
          workspace.fetched_snapshot_uid,
          account.current_profile_template_revision_id,
          profile.is_combat_ready,
          profile.has_complete_combat_semantics,
          profile.game_legal_readiness_status,
          profile.game_legal_issue_code
      FROM lab_profile.local_account AS account
      JOIN lab_profile.account_workspace AS workspace
        ON workspace.local_account_id = account.local_account_id
      JOIN lab_profile.profile_template_revision AS profile
        ON profile.profile_template_revision_id = account.current_profile_template_revision_id
       AND profile.local_account_id = account.local_account_id
      JOIN lab_profile.account_state_revision AS account_state
        ON account_state.account_state_revision_id = profile.account_state_revision_id
       AND account_state.local_account_id = account.local_account_id
      """;

  private static void RequireUid(EntityUid uid)
  {
    if (uid.Value == Guid.Empty)
    {
      throw new LocalAccountProfileIntegrityException("profile_account_uid_invalid");
    }
  }

  private static void Add(NpgsqlCommand command, string name, NpgsqlDbType type, object? value)
  {
    command.Parameters.Add(name, type).Value = value ?? DBNull.Value;
  }
}
