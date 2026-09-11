using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Npgsql;
using NpgsqlTypes;

namespace NikkeLocalLab.Persistence.PostgreSql;

public sealed record RuntimePreferencesKey(Guid AccountUid, string ClientBuildCode, byte[] ClientExecutableSha256);
public sealed record RuntimePreferencesHead(Guid RevisionUid, int RevisionNumber, byte[] ProtectedPayload,
    byte[] ProtectedPayloadSha256, byte[] ContentSha256);
public sealed record RuntimePreferencesCapture(RuntimePreferencesKey Key, Guid LaunchContextUid,
    Guid? ExpectedRevisionUid, byte[] ProtectedPayload, byte[] ProtectedPayloadSha256,
    byte[] ContentSha256, DateTimeOffset CapturedAtUtc);
public sealed record RuntimePreferencesResult(string ResultCode, Guid? RevisionUid, bool ExactReplay)
{
  public bool Quarantined => ResultCode == "stale_head_quarantined";
}

public sealed class RuntimePreferencesStore(NpgsqlDataSource dataSource)
{
  public async Task<RuntimePreferencesHead?> GetHeadAsync(RuntimePreferencesKey key,
      CancellationToken cancellationToken = default)
  {
    ValidateKey(key);
    await using var connection = await dataSource.OpenConnectionAsync(cancellationToken);
    await using var command = connection.CreateCommand();
    command.CommandText = """
        SELECT revision.revision_uid, revision.revision_number, revision.protected_payload,
               revision.protected_payload_sha256, revision.content_sha256
          FROM lab_private_server.runtime_preferences state
          JOIN lab_private_server.runtime_preferences_revision revision ON revision.revision_uid = state.current_revision_uid
         WHERE state.local_account_uid = $1 AND state.client_build_code = $2 AND state.client_executable_sha256 = $3;
        """;
    BindKey(command, key);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    if (!await reader.ReadAsync(cancellationToken)) return null;
    var head = new RuntimePreferencesHead(reader.GetGuid(0), reader.GetInt32(1), reader.GetFieldValue<byte[]>(2),
        reader.GetFieldValue<byte[]>(3), reader.GetFieldValue<byte[]>(4));
    Require(head.ProtectedPayload.Length is >= 53 and <= 16_777_216 && head.ContentSha256.Length == 32 &&
        SHA256.HashData(head.ProtectedPayload).AsSpan().SequenceEqual(head.ProtectedPayloadSha256), "runtime_preferences_head_invalid");
    return head;
  }

  public async Task<RuntimePreferencesResult> PersistAsync(RuntimePreferencesCapture capture,
      CancellationToken cancellationToken = default)
  {
    ValidateKey(capture.Key);
    Require(capture.LaunchContextUid != Guid.Empty && capture.ExpectedRevisionUid != Guid.Empty &&
        capture.ProtectedPayload.Length is >= 53 and <= 16_777_216 && capture.ContentSha256.Length == 32 &&
        SHA256.HashData(capture.ProtectedPayload).AsSpan().SequenceEqual(capture.ProtectedPayloadSha256), "runtime_preferences_capture_invalid");
    var requestHash = ComputeRequestSha256(capture);
    await using var connection = await dataSource.OpenConnectionAsync(cancellationToken);
    await using var transaction = await connection.BeginTransactionAsync(cancellationToken);
    // Serialize operation identity first, including accidental reuse on another account.
    await using (var mutex = connection.CreateCommand())
    {
      mutex.CommandText = "SELECT pg_advisory_xact_lock(hashtextextended($1, 0));";
      mutex.Parameters.AddWithValue("nll/runtime-preferences/" + capture.LaunchContextUid.ToString("D"));
      await mutex.ExecuteNonQueryAsync(cancellationToken);
    }
    await using (var replay = connection.CreateCommand())
    {
      replay.CommandText = """
          SELECT request_sha256, result_code, result_revision_uid FROM lab_private_server.runtime_preferences_operation
           WHERE launch_context_uid = $1;
          """;
      replay.Parameters.AddWithValue(capture.LaunchContextUid);
      await using var reader = await replay.ExecuteReaderAsync(cancellationToken);
      if (await reader.ReadAsync(cancellationToken))
      {
        Require(requestHash.AsSpan().SequenceEqual(reader.GetFieldValue<byte[]>(0)), "runtime_preferences_operation_reuse");
        return new RuntimePreferencesResult(reader.GetString(1), reader.IsDBNull(2) ? null : reader.GetGuid(2), true);
      }
    }
    await using (var create = connection.CreateCommand())
    {
      create.CommandText = """
          INSERT INTO lab_private_server.runtime_preferences
              (local_account_uid, client_build_code, client_executable_sha256, preferences_uid)
          VALUES ($1, $2, $3, $4) ON CONFLICT (local_account_uid, client_build_code, client_executable_sha256) DO NOTHING;
          """;
      BindKey(create, capture.Key);
      create.Parameters.AddWithValue(Guid.NewGuid());
      await create.ExecuteNonQueryAsync(cancellationToken);
    }
    Guid preferencesUid;
    Guid? currentUid;
    var revisionNumber = 0;
    byte[]? currentHash = null;
    await using (var read = connection.CreateCommand())
    {
      read.CommandText = """
          SELECT state.preferences_uid, state.current_revision_uid, revision.revision_number, revision.content_sha256
            FROM lab_private_server.runtime_preferences state
            LEFT JOIN lab_private_server.runtime_preferences_revision revision ON revision.revision_uid = state.current_revision_uid
           WHERE state.local_account_uid = $1 AND state.client_build_code = $2 AND state.client_executable_sha256 = $3
           FOR UPDATE OF state;
          """;
      BindKey(read, capture.Key);
      await using var reader = await read.ExecuteReaderAsync(cancellationToken);
      Require(await reader.ReadAsync(cancellationToken), "runtime_preferences_missing");
      preferencesUid = reader.GetGuid(0);
      currentUid = reader.IsDBNull(1) ? null : reader.GetGuid(1);
      if (currentUid.HasValue)
      {
        revisionNumber = reader.GetInt32(2);
        currentHash = reader.GetFieldValue<byte[]>(3);
      }
    }
    var stale = currentUid != capture.ExpectedRevisionUid;
    var unchanged = !stale && currentHash is not null && currentHash.AsSpan().SequenceEqual(capture.ContentSha256);
    var code = stale ? "stale_head_quarantined" : unchanged ? "state_unchanged" : "state_advanced";
    var resultUid = currentUid;
    if (!stale && !unchanged)
    {
      resultUid = Guid.NewGuid();
      await using var append = connection.CreateCommand();
      append.CommandText = """
          INSERT INTO lab_private_server.runtime_preferences_revision
              (revision_uid, preferences_uid, previous_revision_uid, revision_number, launch_context_uid,
               protected_payload, protected_payload_sha256, content_sha256, captured_at_utc)
          VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9);
          """;
      append.Parameters.AddWithValue(resultUid.Value);
      append.Parameters.AddWithValue(preferencesUid);
      AddNullable(append, NpgsqlDbType.Uuid, currentUid);
      append.Parameters.AddWithValue(checked(revisionNumber + 1));
      append.Parameters.AddWithValue(capture.LaunchContextUid);
      append.Parameters.AddWithValue(capture.ProtectedPayload);
      append.Parameters.AddWithValue(capture.ProtectedPayloadSha256);
      append.Parameters.AddWithValue(capture.ContentSha256);
      append.Parameters.AddWithValue(capture.CapturedAtUtc.ToUniversalTime());
      await append.ExecuteNonQueryAsync(cancellationToken);
      await using var advance = connection.CreateCommand();
      advance.CommandText = "UPDATE lab_private_server.runtime_preferences SET current_revision_uid = $1 WHERE preferences_uid = $2;";
      advance.Parameters.AddWithValue(resultUid.Value);
      advance.Parameters.AddWithValue(preferencesUid);
      await advance.ExecuteNonQueryAsync(cancellationToken);
    }
    await using (var operation = connection.CreateCommand())
    {
      operation.CommandText = """
          INSERT INTO lab_private_server.runtime_preferences_operation
              (launch_context_uid, preferences_uid, request_sha256, expected_revision_uid, result_revision_uid,
               result_code, quarantined_payload, content_sha256, captured_at_utc)
          VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9);
          """;
      operation.Parameters.AddWithValue(capture.LaunchContextUid);
      operation.Parameters.AddWithValue(preferencesUid);
      operation.Parameters.AddWithValue(requestHash);
      AddNullable(operation, NpgsqlDbType.Uuid, capture.ExpectedRevisionUid);
      AddNullable(operation, NpgsqlDbType.Uuid, resultUid);
      operation.Parameters.AddWithValue(code);
      AddNullable(operation, NpgsqlDbType.Bytea, stale ? capture.ProtectedPayload : null);
      operation.Parameters.AddWithValue(capture.ContentSha256);
      operation.Parameters.AddWithValue(capture.CapturedAtUtc.ToUniversalTime());
      await operation.ExecuteNonQueryAsync(cancellationToken);
    }
    await transaction.CommitAsync(cancellationToken);
    return new RuntimePreferencesResult(code, resultUid, false);
  }

  public static byte[] ComputeRequestSha256(RuntimePreferencesCapture capture) => SHA256.HashData(Encoding.UTF8.GetBytes(
      string.Join('\n', "nll/runtime-preferences-capture/v1", capture.Key.AccountUid.ToString("D"),
          capture.Key.ClientBuildCode, Convert.ToHexString(capture.Key.ClientExecutableSha256),
          capture.LaunchContextUid.ToString("D"), capture.ExpectedRevisionUid?.ToString("D") ?? "none",
          Convert.ToHexString(capture.ProtectedPayloadSha256), Convert.ToHexString(capture.ContentSha256),
          capture.CapturedAtUtc.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture)) + "\n"));

  private static void AddNullable(NpgsqlCommand command, NpgsqlDbType type, object? value) =>
      command.Parameters.Add(new NpgsqlParameter { NpgsqlDbType = type, Value = value ?? DBNull.Value });

  private static void BindKey(NpgsqlCommand command, RuntimePreferencesKey key)
  {
    command.Parameters.AddWithValue(key.AccountUid);
    command.Parameters.AddWithValue(key.ClientBuildCode);
    command.Parameters.AddWithValue(key.ClientExecutableSha256);
  }

  private static void ValidateKey(RuntimePreferencesKey key) => Require(key.AccountUid != Guid.Empty &&
      key.ClientExecutableSha256.Length == 32 && key.ClientBuildCode.Length is >= 1 and <= 64 &&
      key.ClientBuildCode[0] is >= 'a' and <= 'z' && key.ClientBuildCode.All(character =>
          character is >= 'a' and <= 'z' or >= '0' and <= '9' or '.' or '-' or '_'), "runtime_preferences_key_invalid");

  private static void Require(bool condition, string code)
  {
    if (!condition) throw new InvalidOperationException(code);
  }
}
