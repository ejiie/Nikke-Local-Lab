using System.Buffers.Binary;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using App = NikkeLocalLab.Application.PrivateServer;
using Domain = NikkeLocalLab.Domain.PrivateServer;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;
using Npgsql;
using NpgsqlTypes;

namespace NikkeLocalLab.Persistence.PostgreSql;

public sealed partial class PostgreSqlPrivateServerService
{
  private const System.Data.IsolationLevel WriteIsolation =
      System.Data.IsolationLevel.Serializable;

  private sealed record StoredWriteOperation(
      string Kind,
      Sha256Digest RequestSha256,
      long? LocalAccountId,
      EntityUid? ExpectedRevisionUid,
      EntityUid ResultEntityUid,
      EntityUid? ResultRevisionUid,
      Sha256Digest ResultContentSha256,
      DateTimeOffset CompletedAtUtc);

  private static DateTimeOffset NormalizeInstant(DateTimeOffset value)
  {
    var utc = value.ToUniversalTime();
    return new DateTimeOffset(utc.Ticks - (utc.Ticks % 10), TimeSpan.Zero);
  }

  private DateTimeOffset Now() => NormalizeInstant(_timeProvider.GetUtcNow());

  private static EntityUid Uid(object value) => new((Guid)value);

  private static EntityUid? NullableUid(object value) =>
      value is DBNull ? null : Uid(value);

  private static Sha256Digest Digest(object value) =>
      Sha256Digest.FromBytes((byte[])value);

  private static Sha256Digest? NullableDigest(object value) =>
      value is DBNull ? null : Digest(value);

  private static DateTimeOffset Instant(object value) => value switch
  {
    DateTimeOffset instant => NormalizeInstant(instant),
    DateTime { Kind: DateTimeKind.Utc } instant =>
        NormalizeInstant(new DateTimeOffset(instant)),
    DateTime { Kind: DateTimeKind.Unspecified } instant =>
        NormalizeInstant(new DateTimeOffset(
            DateTime.SpecifyKind(instant, DateTimeKind.Utc))),
    DateTime instant => NormalizeInstant(new DateTimeOffset(instant.ToUniversalTime())),
    _ => throw new InvalidOperationException(
        "PostgreSQL timestamp value was not recognized.")
  };

  private static DateOnly Date(object value) => value switch
  {
    DateOnly date => date,
    DateTime dateTime => DateOnly.FromDateTime(dateTime),
    _ => throw new InvalidOperationException("PostgreSQL date value was not recognized.")
  };

  private static Sha256Digest RequestHash(string contract, params object?[] values)
  {
    using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
    AppendHash(hash, contract);
    foreach (var value in values)
    {
      AppendHash(hash, Canonical(value));
    }

    return Sha256Digest.FromBytes(hash.GetHashAndReset());
  }

  private static string Canonical(object? value) => value switch
  {
    null => string.Empty,
    EntityUid uid => uid.ToString(),
    Sha256Digest digest => digest.ToString(),
    DateOnly date => date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
    NikkeLocalLab.Domain.PrivateServer.RaidDayKey day => day.Value,
    DateTimeOffset instant => NormalizeInstant(instant).ToString("O", CultureInfo.InvariantCulture),
    bool boolean => boolean ? "true" : "false",
    IFormattable formattable => formattable.ToString(null, CultureInfo.InvariantCulture) ??
        string.Empty,
    _ => value.ToString() ?? string.Empty
  };

  private static void AppendHash(IncrementalHash hash, string value)
  {
    var bytes = Encoding.UTF8.GetBytes(value);
    Span<byte> length = stackalloc byte[4];
    BinaryPrimitives.WriteInt32BigEndian(length, bytes.Length);
    hash.AppendData(length);
    hash.AppendData(bytes);
  }

  private static void Add(
      NpgsqlCommand command,
      string name,
      NpgsqlDbType type,
      object? value) =>
      command.Parameters.Add(new NpgsqlParameter(name, type)
      {
        Value = value ?? DBNull.Value
      });

  private static async Task TakeBootstrapLockAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        "SELECT pg_advisory_xact_lock(563_224_007)",
        connection,
        transaction);
    _ = await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
  }

  private static async Task<StoredWriteOperation?> LoadWriteOperationAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      EntityUid operationUid,
      CancellationToken cancellationToken)
  {
    const string sql = """
        SELECT operation_kind, request_sha256, local_account_id,
               expected_revision_uid, result_entity_uid, result_revision_uid,
               result_content_sha256, completed_at_utc
          FROM lab_private_server.private_server_write_operation
         WHERE operation_uid = @operation_uid
        """;
    await using var command = new NpgsqlCommand(sql, connection, transaction);
    Add(command, "operation_uid", NpgsqlDbType.Uuid, operationUid.Value);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken)
        .ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      return null;
    }

    return new StoredWriteOperation(
        reader.GetString(0),
        Digest(reader.GetValue(1)),
        reader.IsDBNull(2) ? null : reader.GetInt64(2),
        NullableUid(reader.GetValue(3)),
        Uid(reader.GetValue(4)),
        NullableUid(reader.GetValue(5)),
        Digest(reader.GetValue(6)),
        Instant(reader.GetValue(7)));
  }

  private static async Task InsertWriteOperationAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid operationUid,
      string operationKind,
      Sha256Digest requestSha256,
      long? localAccountId,
      EntityUid? expectedRevisionUid,
      EntityUid resultEntityUid,
      EntityUid? resultRevisionUid,
      Sha256Digest resultContentSha256,
      DateTimeOffset completedAtUtc,
      CancellationToken cancellationToken)
  {
    const string sql = """
        INSERT INTO lab_private_server.private_server_write_operation (
            operation_uid, operation_kind, request_sha256, local_account_id,
            expected_revision_uid, result_entity_uid, result_revision_uid,
            result_content_sha256, completed_at_utc
        ) VALUES (
            @operation_uid, @operation_kind, @request_sha256, @local_account_id,
            @expected_revision_uid, @result_entity_uid, @result_revision_uid,
            @result_content_sha256, @completed_at_utc
        )
        """;
    await using var command = new NpgsqlCommand(sql, connection, transaction);
    Add(command, "operation_uid", NpgsqlDbType.Uuid, operationUid.Value);
    Add(command, "operation_kind", NpgsqlDbType.Text, operationKind);
    Add(command, "request_sha256", NpgsqlDbType.Bytea, requestSha256.ToByteArray());
    Add(command, "local_account_id", NpgsqlDbType.Bigint, localAccountId);
    Add(
        command,
        "expected_revision_uid",
        NpgsqlDbType.Uuid,
        expectedRevisionUid?.Value);
    Add(command, "result_entity_uid", NpgsqlDbType.Uuid, resultEntityUid.Value);
    Add(command, "result_revision_uid", NpgsqlDbType.Uuid, resultRevisionUid?.Value);
    Add(
        command,
        "result_content_sha256",
        NpgsqlDbType.Bytea,
        resultContentSha256.ToByteArray());
    Add(command, "completed_at_utc", NpgsqlDbType.TimestampTz, NormalizeInstant(completedAtUtc));
    _ = await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
  }

  private static void RequireReplay(
      StoredWriteOperation operation,
      string expectedKind,
      Sha256Digest expectedRequestSha256)
  {
    if (!string.Equals(operation.Kind, expectedKind, StringComparison.Ordinal) ||
        operation.RequestSha256 != expectedRequestSha256)
    {
      throw Failure(App.PrivateServerFailureKind.Conflict, "operation_uid_payload_conflict");
    }
  }

  private static App.PrivateServerApplicationException MapDatabaseException(
      PostgresException exception)
  {
    if (exception.SqlState is PostgresErrorCodes.UniqueViolation or
        PostgresErrorCodes.SerializationFailure or PostgresErrorCodes.DeadlockDetected)
    {
      return Failure(App.PrivateServerFailureKind.Conflict, "private_server_write_conflict");
    }

    if (exception.SqlState is PostgresErrorCodes.ForeignKeyViolation)
    {
      return Failure(App.PrivateServerFailureKind.Conflict, "private_server_reference_conflict");
    }

    if (exception.SqlState is PostgresErrorCodes.CheckViolation or
        PostgresErrorCodes.RaiseException)
    {
      return Failure(App.PrivateServerFailureKind.Conflict, "private_server_integrity_conflict");
    }

    return Failure(App.PrivateServerFailureKind.Unavailable, "private_server_store_unavailable");
  }

  private static App.PrivateServerApplicationException MapDatabaseException(
      NpgsqlException exception) =>
      Failure(App.PrivateServerFailureKind.Unavailable, "private_server_store_unavailable");
}
