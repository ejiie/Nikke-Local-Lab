using System.Reflection;
using System.Text.RegularExpressions;
using NikkeLocalLab.Provenance;
using Npgsql;

namespace NikkeLocalLab.Persistence.PostgreSql;

public sealed record PostgreSqlMigration(
    int Version,
    string Name,
    string Sql,
    Sha256Digest ScriptSha256);

public sealed class MigrationIntegrityException : Exception
{
  public MigrationIntegrityException(string code)
      : base(code)
  {
    Code = code;
  }

  public string Code { get; }
}

public sealed partial class PostgreSqlMigrationRunner
{
  private const long AdvisoryLockKey = 4_824_703_378_421_116_977;
  private readonly IReadOnlyList<PostgreSqlMigration> _migrations;

  public PostgreSqlMigrationRunner()
      : this(LoadEmbeddedMigrations(typeof(PostgreSqlMigrationRunner).Assembly))
  {
  }

  public PostgreSqlMigrationRunner(IReadOnlyList<PostgreSqlMigration> migrations)
  {
    _migrations = migrations
        .OrderBy(migration => migration.Version)
        .ToArray();

    if (_migrations.Count == 0 ||
        !_migrations
            .Select(migration => migration.Version)
            .SequenceEqual(Enumerable.Range(1, _migrations.Count)))
    {
      throw new MigrationIntegrityException("migration_set_invalid");
    }
  }

  public async Task<int> MigrateAsync(
      NpgsqlDataSource dataSource,
      CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(dataSource);
    await using var connection = await dataSource.OpenConnectionAsync(cancellationToken).ConfigureAwait(false);
    await using var transaction = await connection.BeginTransactionAsync(cancellationToken).ConfigureAwait(false);

    await ExecuteAsync(
        connection,
        transaction,
        """
            CREATE SCHEMA IF NOT EXISTS lab_meta;
            CREATE TABLE IF NOT EXISTS lab_meta.schema_migration (
                version INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                script_sha256 BYTEA NOT NULL CHECK (octet_length(script_sha256) = 32),
                applied_at_utc TIMESTAMPTZ NOT NULL,
                application_version TEXT NOT NULL
            );
            """,
        cancellationToken).ConfigureAwait(false);

    await using (var lockCommand = new NpgsqlCommand(
                     "SELECT pg_advisory_xact_lock($1);",
                     connection,
                     transaction))
    {
      lockCommand.Parameters.AddWithValue(AdvisoryLockKey);
      await lockCommand.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    var applied = new Dictionary<int, (string Name, byte[] Checksum)>();
    await using (var readCommand = new NpgsqlCommand(
                     "SELECT version, name, script_sha256 FROM lab_meta.schema_migration ORDER BY version;",
                     connection,
                     transaction))
    await using (var reader = await readCommand.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false))
    {
      while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        applied.Add(reader.GetInt32(0), (reader.GetString(1), (byte[])reader[2]));
      }
    }

    var migrationByVersion = _migrations.ToDictionary(migration => migration.Version);
    foreach (var (version, appliedMigration) in applied)
    {
      if (!migrationByVersion.TryGetValue(version, out var knownMigration))
      {
        throw new MigrationIntegrityException("migration_history_unknown");
      }

      if (!string.Equals(appliedMigration.Name, knownMigration.Name, StringComparison.Ordinal))
      {
        throw new MigrationIntegrityException("migration_name_mismatch");
      }
    }

    if (!applied.Keys
            .OrderBy(version => version)
            .SequenceEqual(_migrations.Take(applied.Count).Select(migration => migration.Version)))
    {
      throw new MigrationIntegrityException("migration_history_gap");
    }

    var appliedCount = 0;
    foreach (var migration in _migrations)
    {
      if (applied.TryGetValue(migration.Version, out var existingMigration))
      {
        if (!existingMigration.Checksum.AsSpan().SequenceEqual(migration.ScriptSha256.ToByteArray()))
        {
          throw new MigrationIntegrityException("migration_checksum_mismatch");
        }

        continue;
      }

      await ExecuteAsync(connection, transaction, migration.Sql, cancellationToken).ConfigureAwait(false);
      await using var insert = new NpgsqlCommand(
          """
                INSERT INTO lab_meta.schema_migration
                    (version, name, script_sha256, applied_at_utc, application_version)
                VALUES ($1, $2, $3, $4, $5);
                """,
          connection,
          transaction);
      insert.Parameters.AddWithValue(migration.Version);
      insert.Parameters.AddWithValue(migration.Name);
      insert.Parameters.AddWithValue(migration.ScriptSha256.ToByteArray());
      insert.Parameters.AddWithValue(DateTimeOffset.UtcNow);
      insert.Parameters.AddWithValue("phase1a");
      await insert.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
      appliedCount++;
    }

    await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
    return appliedCount;
  }

  public static IReadOnlyList<PostgreSqlMigration> LoadEmbeddedMigrations(Assembly assembly)
  {
    ArgumentNullException.ThrowIfNull(assembly);
    var migrations = new List<PostgreSqlMigration>();
    foreach (var resourceName in assembly.GetManifestResourceNames().OrderBy(name => name, StringComparer.Ordinal))
    {
      var match = MigrationNamePattern().Match(resourceName);
      if (!match.Success)
      {
        continue;
      }

      using var stream = assembly.GetManifestResourceStream(resourceName)
          ?? throw new MigrationIntegrityException("migration_resource_missing");
      using var reader = new StreamReader(stream, detectEncodingFromByteOrderMarks: true);
      var sql = reader.ReadToEnd().Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n');
      var version = int.Parse(match.Groups["version"].Value, System.Globalization.CultureInfo.InvariantCulture);
      var name = match.Groups["name"].Value;
      migrations.Add(new PostgreSqlMigration(version, name, sql, Sha256Digest.ComputeUtf8(sql)));
    }

    return migrations;
  }

  private static async Task ExecuteAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      string sql,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(sql, connection, transaction);
    await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
  }

  [GeneratedRegex(@"\.Migrations\.V(?<version>[0-9]{4})__(?<name>[a-z][a-z0-9_]*)\.sql$", RegexOptions.CultureInvariant)]
  private static partial Regex MigrationNamePattern();
}
