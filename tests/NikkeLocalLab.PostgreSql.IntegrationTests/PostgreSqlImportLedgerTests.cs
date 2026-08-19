using System.Text.Json;
using NikkeLocalLab.Application.Importing;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Import.Sources;
using NikkeLocalLab.Persistence.PostgreSql;
using NikkeLocalLab.Provenance;
using Npgsql;

namespace NikkeLocalLab.PostgreSql.IntegrationTests;

public sealed class PostgreSqlImportLedgerTests
{
  private const string RawCanary = "SYNTHETIC-RAW-ID-MUST-NOT-LEAK";
  private const string DecodedCanary = "SYNTHETIC-DECODED-CONTENT-MUST-NOT-LEAK";
  private const string ResetToken = "allow-phase1a-disposable-schema-reset";

  [Fact]
  public async Task MigrationAndEndToEndImportAreIdempotentPathFreeAndChecksumGuarded()
  {
    var connectionString = Environment.GetEnvironmentVariable("NIKKE_LAB_TEST_DB")
        ?? throw new InvalidOperationException("NIKKE_LAB_TEST_DB is required for PostgreSQL integration tests.");
    var validated = PostgreSqlConnectionPolicy.Validate(connectionString);
    var builder = new NpgsqlConnectionStringBuilder(validated);
    Assert.Equal("nikke_local_lab_test", builder.Database);

    await using var dataSource = PostgreSqlDataSourceFactory.Create(validated);
    await ResetSchemasAsync(dataSource);

    var migrations = new PostgreSqlMigrationRunner();
    Assert.Equal(5, await migrations.MigrateAsync(dataSource));
    Assert.Equal(0, await migrations.MigrateAsync(dataSource));
    await AssertMigrationChecksumDriftFailsAsync(dataSource);

    var ledger = new PostgreSqlImportLedger(dataSource, new RandomEntityUidGenerator());
    using var temporary = new TemporaryDirectory();
    var sourceRoot = temporary.CreateDirectory("source");
    var repositoryRoot = temporary.CreateDirectory("repository");
    var runtimeRoot = temporary.CreateDirectory("runtime");
    var fixturePath = Path.Combine(AppContext.BaseDirectory, "Fixtures", "import-source.phase1a.json");
    var privateSourcePath = Path.Combine(sourceRoot, "private-source-name.json");
    File.Copy(fixturePath, privateSourcePath);
    var source = new ReadOnlySourceRoot(sourceRoot, repositoryRoot, runtimeRoot)
        .Bind(SourceRelativePath.Parse("private-source-name.json"), "synthetic_catalog");
    var coordinator = new ImportCoordinator(ledger, new RandomEntityUidGenerator());
    var extractor = new IntegrationFixtureExtractor();

    var first = await coordinator.ImportSingleAsync(source, "catalog", extractor);
    var second = await coordinator.ImportSingleAsync(source, "catalog", extractor);

    Assert.Equal(ImportReceiptStatus.Succeeded, first.Status);
    Assert.Equal(ImportReceiptStatus.Reused, second.Status);
    Assert.Equal(first.DatasetSnapshotUid, second.DatasetSnapshotUid);
    Assert.Equal(first.SourceArtifactUids, second.SourceArtifactUids);
    Assert.NotEqual(first.ImportRunUid, second.ImportRunUid);

    var multiRoleAttempt = CreateMultiRoleAttempt();
    var multiRole = await ledger.RecordCompletedAsync(multiRoleAttempt);
    Assert.Equal(ImportReceiptStatus.Succeeded, multiRole.Status);
    Assert.Equal(2, multiRole.SourceArtifactUids.Count);
    Assert.Equal(multiRole.SourceArtifactUids[0], multiRole.SourceArtifactUids[1]);

    var inconsistentAttempt = CreateMultiRoleAttempt() with
    {
      Artifacts = [CreateArtifactRegistration("different", "different-bytes", 15, 0)]
    };
    var inconsistent = await Assert.ThrowsAsync<ImportLedgerIntegrityException>(() =>
        ledger.RecordCompletedAsync(inconsistentAttempt));
    Assert.Equal("artifact_registration_mismatch", inconsistent.Code);

    await using var connection = await dataSource.OpenConnectionAsync();
    Assert.Equal(2L, await ScalarInt64Async(connection, "SELECT count(*) FROM lab_import.source_artifact;"));
    Assert.Equal(2L, await ScalarInt64Async(connection, "SELECT count(*) FROM lab_import.dataset_snapshot;"));
    Assert.Equal(3L, await ScalarInt64Async(connection, "SELECT count(*) FROM lab_import.dataset_snapshot_source_artifact;"));
    Assert.Equal(3L, await ScalarInt64Async(connection, "SELECT count(*) FROM lab_import.import_run;"));
    Assert.Equal(4L, await ScalarInt64Async(connection, "SELECT count(*) FROM lab_import.import_run_source_artifact;"));

    await AssertSchemaHasNoLeakageColumnsAsync(connection);
    var storedText = await ReadStoredTextAsync(connection);
    var publicJson = JsonSerializer.Serialize(new { first, second, multiRole });
    foreach (var projection in new[] { storedText, publicJson })
    {
      Assert.DoesNotContain(RawCanary, projection, StringComparison.Ordinal);
      Assert.DoesNotContain(DecodedCanary, projection, StringComparison.Ordinal);
      Assert.DoesNotContain("synthetic-private-alpha", projection, StringComparison.Ordinal);
      Assert.DoesNotContain("private-source-name", projection, StringComparison.Ordinal);
      Assert.DoesNotContain(sourceRoot, projection, StringComparison.OrdinalIgnoreCase);
    }

    await AssertMigrationHistoryDriftFailsAsync(dataSource);
  }

  private static CompletedImportAttempt CreateMultiRoleAttempt()
  {
    var observation = new SourceArtifactObservation(
        "synthetic_catalog",
        Sha256Digest.ComputeUtf8("shared-synthetic-source"),
        23);
    var manifest = CanonicalDatasetManifest.Create(
    [
      new DatasetArtifactInput("primary", observation),
      new DatasetArtifactInput("secondary", observation)
    ]);
    var extractor = new ExtractorDescriptor(
        "synthetic_fixture",
        "v1",
        Sha256Digest.ComputeUtf8("nll/synthetic-fixture-contract/v1"));
    var request = ImportRequestFingerprint.Create(
        manifest.CanonicalSha256,
        extractor.FingerprintSha256,
        SemanticOptionsFingerprint.Empty);
    var now = DateTimeOffset.UtcNow;

    return new CompletedImportAttempt(
        EntityUid.New(),
        EntityUid.New(),
        manifest.Artifacts.Select(item => new ArtifactRegistration(EntityUid.New(), item)).ToArray(),
        manifest,
        extractor,
        SemanticOptionsFingerprint.Empty,
        request,
        Sha256Digest.ComputeUtf8("synthetic-multi-role-output"),
        [],
        now,
        now.AddMilliseconds(1));
  }

  private static ArtifactRegistration CreateArtifactRegistration(
      string role,
      string content,
      long length,
      int ordinal)
  {
    var artifact = new CanonicalDatasetArtifact(
        ordinal,
        role,
        new SourceArtifactObservation("synthetic_catalog", Sha256Digest.ComputeUtf8(content), length));
    return new ArtifactRegistration(EntityUid.New(), artifact);
  }

  private static async Task AssertMigrationChecksumDriftFailsAsync(NpgsqlDataSource dataSource)
  {
    var embedded = PostgreSqlMigrationRunner.LoadEmbeddedMigrations(typeof(PostgreSqlMigrationRunner).Assembly);
    var invalidSet = Assert.Throws<MigrationIntegrityException>(() =>
        new PostgreSqlMigrationRunner([embedded[0] with { Version = 2 }]));
    Assert.Equal("migration_set_invalid", invalidSet.Code);

    var changed = embedded[0] with
    {
      Sql = embedded[0].Sql + "\nSELECT 1;",
      ScriptSha256 = Sha256Digest.ComputeUtf8(embedded[0].Sql + "\nSELECT 1;")
    };
    var changedSet = embedded
        .Select(item => item.Version == changed.Version ? changed : item)
        .ToArray();
    var driftRunner = new PostgreSqlMigrationRunner(changedSet);
    var drift = await Assert.ThrowsAsync<MigrationIntegrityException>(() => driftRunner.MigrateAsync(dataSource));
    Assert.Equal("migration_checksum_mismatch", drift.Code);
  }

  private static async Task AssertMigrationHistoryDriftFailsAsync(NpgsqlDataSource dataSource)
  {
    await using (var updateName = dataSource.CreateCommand(
                     "UPDATE lab_meta.schema_migration SET name = 'unexpected_name' WHERE version = 1;"))
    {
      await updateName.ExecuteNonQueryAsync();
    }

    var nameDrift = await Assert.ThrowsAsync<MigrationIntegrityException>(() =>
        new PostgreSqlMigrationRunner().MigrateAsync(dataSource));
    Assert.Equal("migration_name_mismatch", nameDrift.Code);

    await using (var restoreName = dataSource.CreateCommand(
                     "UPDATE lab_meta.schema_migration SET name = 'import_ledger' WHERE version = 1;"))
    {
      await restoreName.ExecuteNonQueryAsync();
    }

    await using (var insertFuture = dataSource.CreateCommand(
                     """
                     INSERT INTO lab_meta.schema_migration
                         (version, name, script_sha256, applied_at_utc, application_version)
                     VALUES (9999, 'future_schema', decode(repeat('00', 32), 'hex'), now(), 'synthetic-test');
                     """))
    {
      await insertFuture.ExecuteNonQueryAsync();
    }

    var unknown = await Assert.ThrowsAsync<MigrationIntegrityException>(() =>
        new PostgreSqlMigrationRunner().MigrateAsync(dataSource));
    Assert.Equal("migration_history_unknown", unknown.Code);
  }

  private static async Task AssertSchemaHasNoLeakageColumnsAsync(NpgsqlConnection connection)
  {
    var forbiddenColumns = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    {
      "source_path",
      "file_name",
      "raw_id",
      "payload",
      "message",
      "details",
      "exception_message",
      "stack_trace"
    };
    await using var command = new NpgsqlCommand(
        """
        SELECT column_name
        FROM information_schema.columns
        WHERE table_schema IN ('lab_import', 'lab_catalog', 'lab_private', 'lab_meta');
        """,
        connection);
    await using var reader = await command.ExecuteReaderAsync();
    while (await reader.ReadAsync())
    {
      Assert.DoesNotContain(reader.GetString(0), forbiddenColumns);
    }
  }

  private static async Task<string> ReadStoredTextAsync(NpgsqlConnection connection)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT string_agg(value, E'\n')
        FROM (
            SELECT artifact_kind AS value FROM lab_import.source_artifact
            UNION ALL SELECT extractor_id FROM lab_import.import_run
            UNION ALL SELECT extractor_version FROM lab_import.import_run
            UNION ALL SELECT status FROM lab_import.import_run
            UNION ALL SELECT result_code FROM lab_import.import_run
            UNION ALL SELECT severity FROM lab_import.import_diagnostic
            UNION ALL SELECT stage_code FROM lab_import.import_diagnostic
            UNION ALL SELECT diagnostic_code FROM lab_import.import_diagnostic
        ) AS stored_text;
        """,
        connection);
    return (string?)await command.ExecuteScalarAsync() ?? string.Empty;
  }

  private static async Task ResetSchemasAsync(NpgsqlDataSource dataSource)
  {
    if (!string.Equals(
            Environment.GetEnvironmentVariable("NIKKE_LAB_TEST_RESET_TOKEN"),
            ResetToken,
            StringComparison.Ordinal))
    {
      throw new InvalidOperationException("The disposable PostgreSQL reset token is required.");
    }

    await using var command = dataSource.CreateCommand(
        """
        DROP SCHEMA IF EXISTS lab_profile CASCADE;
        DROP SCHEMA IF EXISTS lab_combat_support CASCADE;
        DROP SCHEMA IF EXISTS lab_raid CASCADE;
        DROP SCHEMA IF EXISTS lab_private CASCADE;
        DROP SCHEMA IF EXISTS lab_catalog CASCADE;
        DROP SCHEMA IF EXISTS lab_import CASCADE;
        DROP SCHEMA IF EXISTS lab_meta CASCADE;
        """);
    await command.ExecuteNonQueryAsync();
  }

  private static async Task<long> ScalarInt64Async(NpgsqlConnection connection, string sql)
  {
    await using var command = new NpgsqlCommand(sql, connection);
    var value = await command.ExecuteScalarAsync();
    return Convert.ToInt64(value, System.Globalization.CultureInfo.InvariantCulture);
  }

  private sealed class IntegrationFixtureExtractor : IImportExtractor
  {
    private static readonly byte[] SyntheticSecret = Enumerable.Range(1, 32).Select(value => (byte)value).ToArray();

    public ExtractorDescriptor Descriptor { get; } = new(
        "synthetic_fixture",
        "v1",
        Sha256Digest.ComputeUtf8("nll/synthetic-fixture-contract/v1"));

    public async Task<ExtractionResult> ExtractAsync(
        Stream source,
        CancellationToken cancellationToken = default)
    {
      using var document = await JsonDocument.ParseAsync(source, cancellationToken: cancellationToken);
      var root = document.RootElement;
      if (root.GetProperty("fixtureKind").GetString() != "phase1a-catalog" ||
          root.GetProperty("privateSourceToken").GetString() != RawCanary ||
          root.GetProperty("decodedMarker").GetString() != DecodedCanary)
      {
        throw new SafeImportFailureException("extract", "fixture_kind_invalid");
      }

      var entityUids = root.GetProperty("entities")
          .EnumerateArray()
          .Select(entity => SourceIdentityEncoder.Encode(
              SyntheticSecret,
              "phase1a.synthetic",
              entity.GetProperty("kind").GetString()!,
              entity.GetProperty("sourceAlias").GetString()!).ToString())
          .OrderBy(value => value, StringComparer.Ordinal)
          .ToArray();
      var canonical = JsonSerializer.SerializeToUtf8Bytes(new
      {
        schemaVersion = 1,
        entityUids
      });
      return ExtractionResult.Create(canonical);
    }
  }

  private sealed class TemporaryDirectory : IDisposable
  {
    public TemporaryDirectory()
    {
      Path = System.IO.Path.Combine(
          System.IO.Path.GetTempPath(),
          "nikke-local-lab-postgresql-tests",
          Guid.NewGuid().ToString("N"));
      Directory.CreateDirectory(Path);
    }

    public string Path { get; }

    public string CreateDirectory(string relativePath)
    {
      var path = System.IO.Path.Combine(Path, relativePath);
      Directory.CreateDirectory(path);
      return path;
    }

    public void Dispose()
    {
      if (Directory.Exists(Path))
      {
        Directory.Delete(Path, recursive: true);
      }
    }
  }
}
