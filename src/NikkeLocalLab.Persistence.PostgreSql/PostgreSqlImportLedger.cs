using System.Buffers.Binary;
using NikkeLocalLab.Application.Importing;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;
using Npgsql;

namespace NikkeLocalLab.Persistence.PostgreSql;

public sealed class ImportLedgerIntegrityException : Exception
{
  public ImportLedgerIntegrityException(string code)
      : base(code)
  {
    Code = code;
  }

  public string Code { get; }
}

public sealed class PostgreSqlImportLedger : IImportLedger
{
  private readonly NpgsqlDataSource _dataSource;
  private readonly IEntityUidGenerator _uidGenerator;

  public PostgreSqlImportLedger(NpgsqlDataSource dataSource, IEntityUidGenerator uidGenerator)
  {
    _dataSource = dataSource ?? throw new ArgumentNullException(nameof(dataSource));
    _uidGenerator = uidGenerator ?? throw new ArgumentNullException(nameof(uidGenerator));
  }

  public Task<ImportReceipt> RecordCompletedAsync(
      CompletedImportAttempt attempt,
      CancellationToken cancellationToken = default) =>
      RecordAsync(attempt, null, null, cancellationToken);

  public Task<ImportReceipt> RecordFailedAsync(
      FailedImportAttempt attempt,
      CancellationToken cancellationToken = default) =>
      RecordAsync(null, attempt, null, cancellationToken);

  internal Task<ImportReceipt> RecordCompletedAtomicallyAsync(
      CompletedImportAttempt attempt,
      Func<PostgreSqlCompletedImportContext, CancellationToken, Task> projectionWriter,
      CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(attempt);
    ArgumentNullException.ThrowIfNull(projectionWriter);
    return RecordAsync(attempt, null, projectionWriter, cancellationToken);
  }

  private async Task<ImportReceipt> RecordAsync(
      CompletedImportAttempt? completed,
      FailedImportAttempt? failed,
      Func<PostgreSqlCompletedImportContext, CancellationToken, Task>? projectionWriter,
      CancellationToken cancellationToken)
  {
    if ((completed is null) == (failed is null))
    {
      throw new ArgumentException("Exactly one import outcome is required.");
    }

    var runUid = completed?.ImportRunUid ?? failed!.ImportRunUid;
    var artifacts = completed?.Artifacts ?? failed!.Artifacts;
    var manifest = completed?.DatasetManifest ?? failed!.DatasetManifest;
    var extractor = completed?.Extractor ?? failed!.Extractor;
    var optionsSha256 = completed?.SemanticOptionsSha256 ?? failed!.SemanticOptionsSha256;
    var requestSha256 = completed?.RequestSha256 ?? failed!.RequestSha256;
    var startedAt = completed?.StartedAtUtc ?? failed!.StartedAtUtc;
    var finishedAt = completed?.FinishedAtUtc ?? failed!.FinishedAtUtc;

    ValidateAttemptConsistency(
        artifacts,
        manifest,
        extractor,
        optionsSha256,
        requestSha256,
        startedAt,
        finishedAt);

    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken).ConfigureAwait(false);
    await using var transaction = await connection.BeginTransactionAsync(cancellationToken).ConfigureAwait(false);
    await AcquireRequestLockAsync(connection, transaction, requestSha256, cancellationToken).ConfigureAwait(false);

    var storedArtifacts = await RegisterArtifactsAsync(
        connection,
        transaction,
        artifacts,
        startedAt,
        cancellationToken).ConfigureAwait(false);
    var candidateSnapshotUid = completed?.CandidateDatasetSnapshotUid ?? _uidGenerator.NewUid();
    var storedSnapshot = await RegisterSnapshotAsync(
        connection,
        transaction,
        candidateSnapshotUid,
        manifest,
        storedArtifacts,
        startedAt,
        cancellationToken).ConfigureAwait(false);

    var priorSucceededRun = completed is null
        ? null
        : await FindSucceededRunAsync(
            connection,
            transaction,
            requestSha256,
            cancellationToken).ConfigureAwait(false);
    if (completed is not null && priorSucceededRun is not null &&
        priorSucceededRun.OutputManifestSha256 != completed.OutputManifestSha256)
    {
      throw new ImportLedgerIntegrityException("extractor_nondeterministic_output");
    }

    var status = completed is null
        ? "failed"
        : priorSucceededRun is not null ? "reused" : "succeeded";
    var resultCode = completed is null
        ? failed!.Diagnostic.DiagnosticCode
        : priorSucceededRun is not null ? "import_reused" : "import_succeeded";
    var outputSha256 = completed?.OutputManifestSha256;

    var runId = await InsertRunAsync(
        connection,
        transaction,
        runUid,
        storedSnapshot.Id,
        extractor,
        optionsSha256,
        requestSha256,
        outputSha256,
        status,
        resultCode,
        priorSucceededRun?.Id,
        startedAt,
        finishedAt,
        cancellationToken).ConfigureAwait(false);

    await InsertRunArtifactsAsync(
        connection,
        transaction,
        runId,
        storedArtifacts,
        cancellationToken).ConfigureAwait(false);

    var diagnostics = completed?.Diagnostics ?? [failed!.Diagnostic];
    await InsertDiagnosticsAsync(
        connection,
        transaction,
        runId,
        diagnostics,
        finishedAt,
        cancellationToken).ConfigureAwait(false);

    if (completed is not null && projectionWriter is not null)
    {
      await projectionWriter(
          new PostgreSqlCompletedImportContext(
              connection,
              transaction,
              storedSnapshot.Id,
              storedSnapshot.Uid,
              runId,
              priorSucceededRun is not null),
          cancellationToken).ConfigureAwait(false);
    }

    await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);

    return new ImportReceipt(
        runUid,
        completed is null ? null : storedSnapshot.Uid,
        storedArtifacts.Select(artifact => artifact.Uid).ToArray(),
        manifest.CanonicalSha256,
        outputSha256,
        completed is null
            ? ImportReceiptStatus.Failed
            : priorSucceededRun is not null ? ImportReceiptStatus.Reused : ImportReceiptStatus.Succeeded,
    diagnostics.Select(diagnostic => diagnostic.DiagnosticCode).ToArray());
  }

  private static void ValidateAttemptConsistency(
      IReadOnlyList<ArtifactRegistration> registrations,
      CanonicalDatasetManifest manifest,
      ExtractorDescriptor extractor,
      Sha256Digest semanticOptionsSha256,
      Sha256Digest requestSha256,
      DateTimeOffset startedAt,
      DateTimeOffset finishedAt)
  {
    var orderedRegistrations = registrations
        .OrderBy(registration => registration.ManifestArtifact.Ordinal)
        .ToArray();
    if (orderedRegistrations.Length != manifest.Artifacts.Count ||
        !orderedRegistrations
            .Select(registration => registration.ManifestArtifact)
            .SequenceEqual(manifest.Artifacts) ||
        orderedRegistrations
            .Select(registration => registration.CandidateArtifactUid)
            .Distinct()
            .Count() != orderedRegistrations.Length)
    {
      throw new ImportLedgerIntegrityException("artifact_registration_mismatch");
    }

    var expectedRequestSha256 = ImportRequestFingerprint.Create(
        manifest.CanonicalSha256,
        extractor.FingerprintSha256,
        semanticOptionsSha256);
    if (expectedRequestSha256 != requestSha256)
    {
      throw new ImportLedgerIntegrityException("request_fingerprint_mismatch");
    }

    if (finishedAt < startedAt)
    {
      throw new ImportLedgerIntegrityException("import_timestamp_invalid");
    }
  }

  private static async Task AcquireRequestLockAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      Sha256Digest requestSha256,
      CancellationToken cancellationToken)
  {
    var lockKey = BinaryPrimitives.ReadInt64BigEndian(requestSha256.ToByteArray());
    await using var command = new NpgsqlCommand("SELECT pg_advisory_xact_lock($1);", connection, transaction);
    command.Parameters.AddWithValue(lockKey);
    await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
  }

  private static async Task<IReadOnlyList<StoredArtifact>> RegisterArtifactsAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      IReadOnlyList<ArtifactRegistration> artifacts,
      DateTimeOffset observedAt,
      CancellationToken cancellationToken)
  {
    var result = new List<StoredArtifact>(artifacts.Count);
    foreach (var registration in artifacts.OrderBy(item => item.ManifestArtifact.Ordinal))
    {
      var observation = registration.ManifestArtifact.Artifact;
      await using var command = new NpgsqlCommand(
          """
                INSERT INTO lab_import.source_artifact
                    (source_artifact_uid, artifact_kind, content_sha256, byte_length, first_observed_at_utc)
                VALUES ($1, $2, $3, $4, $5)
                ON CONFLICT (content_sha256) DO UPDATE
                    SET content_sha256 = EXCLUDED.content_sha256
                RETURNING source_artifact_id, source_artifact_uid, artifact_kind, byte_length;
                """,
          connection,
          transaction);
      command.Parameters.AddWithValue(registration.CandidateArtifactUid.Value);
      command.Parameters.AddWithValue(observation.ArtifactKind);
      command.Parameters.AddWithValue(observation.ContentSha256.ToByteArray());
      command.Parameters.AddWithValue(observation.ByteLength);
      command.Parameters.AddWithValue(observedAt);

      await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
      if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        throw new ImportLedgerIntegrityException("artifact_upsert_failed");
      }

      var stored = new StoredArtifact(
          reader.GetInt64(0),
          new EntityUid(reader.GetGuid(1)),
          reader.GetString(2),
          reader.GetInt64(3),
          registration.ManifestArtifact.RoleCode,
          registration.ManifestArtifact.Ordinal);
      if (!string.Equals(stored.ArtifactKind, observation.ArtifactKind, StringComparison.Ordinal) ||
          stored.ByteLength != observation.ByteLength)
      {
        throw new ImportLedgerIntegrityException("artifact_digest_collision");
      }

      result.Add(stored);
    }

    return result;
  }

  private static async Task<StoredSnapshot> RegisterSnapshotAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid candidateUid,
      CanonicalDatasetManifest manifest,
      IReadOnlyList<StoredArtifact> artifacts,
      DateTimeOffset createdAt,
      CancellationToken cancellationToken)
  {
    long snapshotId;
    EntityUid snapshotUid;
    await using (var command = new NpgsqlCommand(
                     """
                         INSERT INTO lab_import.dataset_snapshot
                             (dataset_snapshot_uid, manifest_version, canonical_sha256, created_at_utc)
                         VALUES ($1, 1, $2, $3)
                         ON CONFLICT (canonical_sha256) DO UPDATE
                             SET canonical_sha256 = EXCLUDED.canonical_sha256
                         RETURNING dataset_snapshot_id, dataset_snapshot_uid;
                         """,
                     connection,
                     transaction))
    {
      command.Parameters.AddWithValue(candidateUid.Value);
      command.Parameters.AddWithValue(manifest.CanonicalSha256.ToByteArray());
      command.Parameters.AddWithValue(createdAt);
      await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
      if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        throw new ImportLedgerIntegrityException("snapshot_upsert_failed");
      }

      snapshotId = reader.GetInt64(0);
      snapshotUid = new EntityUid(reader.GetGuid(1));
    }

    var existingMembership = new List<(string Role, int Ordinal, long ArtifactId)>();
    await using (var readMembership = new NpgsqlCommand(
                     """
                         SELECT role_code, ordinal, source_artifact_id
                         FROM lab_import.dataset_snapshot_source_artifact
                         WHERE dataset_snapshot_id = $1
                         ORDER BY role_code, ordinal;
                         """,
                     connection,
                     transaction))
    {
      readMembership.Parameters.AddWithValue(snapshotId);
      await using var reader = await readMembership.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
      while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        existingMembership.Add((reader.GetString(0), reader.GetInt32(1), reader.GetInt64(2)));
      }
    }

    var expectedMembership = artifacts
        .OrderBy(artifact => artifact.RoleCode, StringComparer.Ordinal)
        .ThenBy(artifact => artifact.Ordinal)
        .Select(artifact => (artifact.RoleCode, artifact.Ordinal, artifact.Id))
        .ToArray();

    if (existingMembership.Count == 0)
    {
      foreach (var artifact in artifacts)
      {
        await using var insert = new NpgsqlCommand(
            """
                    INSERT INTO lab_import.dataset_snapshot_source_artifact
                        (dataset_snapshot_id, source_artifact_id, role_code, ordinal)
                    VALUES ($1, $2, $3, $4);
                    """,
            connection,
            transaction);
        insert.Parameters.AddWithValue(snapshotId);
        insert.Parameters.AddWithValue(artifact.Id);
        insert.Parameters.AddWithValue(artifact.RoleCode);
        insert.Parameters.AddWithValue(artifact.Ordinal);
        await insert.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
      }
    }
    else if (!existingMembership.SequenceEqual(expectedMembership))
    {
      throw new ImportLedgerIntegrityException("snapshot_membership_mismatch");
    }

    return new StoredSnapshot(snapshotId, snapshotUid);
  }

  private static async Task<StoredSucceededRun?> FindSucceededRunAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      Sha256Digest requestSha256,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
            SELECT import_run_id, output_manifest_sha256
            FROM lab_import.import_run
            WHERE request_sha256 = $1 AND status = 'succeeded'
            ORDER BY import_run_id
            LIMIT 1;
            """,
        connection,
        transaction);
    command.Parameters.AddWithValue(requestSha256.ToByteArray());
    await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      return null;
    }

    return new StoredSucceededRun(
        reader.GetInt64(0),
        Sha256Digest.FromBytes((byte[])reader[1]));
  }

  private static async Task<long> InsertRunAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid runUid,
      long snapshotId,
      ExtractorDescriptor extractor,
      Sha256Digest semanticOptionsSha256,
      Sha256Digest requestSha256,
      Sha256Digest? outputSha256,
      string status,
      string resultCode,
      long? reusedFromRunId,
      DateTimeOffset startedAt,
      DateTimeOffset finishedAt,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
            INSERT INTO lab_import.import_run
                (import_run_uid, dataset_snapshot_id, extractor_id, extractor_version,
                 extractor_contract_sha256, semantic_options_sha256, request_sha256,
                 output_manifest_sha256, status, result_code, reused_from_import_run_id,
                 started_at_utc, finished_at_utc)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
            RETURNING import_run_id;
            """,
        connection,
        transaction);
    command.Parameters.AddWithValue(runUid.Value);
    command.Parameters.AddWithValue(snapshotId);
    command.Parameters.AddWithValue(extractor.ExtractorId);
    command.Parameters.AddWithValue(extractor.ExtractorVersion);
    command.Parameters.AddWithValue(extractor.ContractSha256.ToByteArray());
    command.Parameters.AddWithValue(semanticOptionsSha256.ToByteArray());
    command.Parameters.AddWithValue(requestSha256.ToByteArray());
    command.Parameters.AddWithValue((object?)outputSha256?.ToByteArray() ?? DBNull.Value);
    command.Parameters.AddWithValue(status);
    command.Parameters.AddWithValue(resultCode);
    command.Parameters.AddWithValue((object?)reusedFromRunId ?? DBNull.Value);
    command.Parameters.AddWithValue(startedAt);
    command.Parameters.AddWithValue(finishedAt);
    var value = await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
    return Convert.ToInt64(value, System.Globalization.CultureInfo.InvariantCulture);
  }

  private static async Task InsertRunArtifactsAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long runId,
      IReadOnlyList<StoredArtifact> artifacts,
      CancellationToken cancellationToken)
  {
    foreach (var artifact in artifacts.OrderBy(item => item.Ordinal))
    {
      await using var command = new NpgsqlCommand(
          """
                INSERT INTO lab_import.import_run_source_artifact
                    (import_run_id, source_artifact_id, ordinal)
                VALUES ($1, $2, $3);
                """,
          connection,
          transaction);
      command.Parameters.AddWithValue(runId);
      command.Parameters.AddWithValue(artifact.Id);
      command.Parameters.AddWithValue(artifact.Ordinal);
      await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }
  }

  private async Task InsertDiagnosticsAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long runId,
      IReadOnlyList<SafeDiagnostic> diagnostics,
      DateTimeOffset createdAt,
      CancellationToken cancellationToken)
  {
    for (var sequence = 0; sequence < diagnostics.Count; sequence++)
    {
      var diagnostic = diagnostics[sequence];
      await using var command = new NpgsqlCommand(
          """
                INSERT INTO lab_import.import_diagnostic
                    (import_diagnostic_uid, import_run_id, sequence_number, severity,
                     stage_code, diagnostic_code, occurrence_count, created_at_utc)
                VALUES ($1, $2, $3, $4, $5, $6, $7, $8);
                """,
          connection,
          transaction);
      command.Parameters.AddWithValue(_uidGenerator.NewUid().Value);
      command.Parameters.AddWithValue(runId);
      command.Parameters.AddWithValue(sequence);
      command.Parameters.AddWithValue(diagnostic.Severity.ToString().ToLowerInvariant());
      command.Parameters.AddWithValue(diagnostic.StageCode);
      command.Parameters.AddWithValue(diagnostic.DiagnosticCode);
      command.Parameters.AddWithValue(diagnostic.OccurrenceCount);
      command.Parameters.AddWithValue(createdAt);
      await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }
  }

  private sealed record StoredArtifact(
      long Id,
      EntityUid Uid,
      string ArtifactKind,
      long ByteLength,
      string RoleCode,
      int Ordinal);

  private sealed record StoredSnapshot(long Id, EntityUid Uid);

  private sealed record StoredSucceededRun(long Id, Sha256Digest OutputManifestSha256);
}

internal sealed record PostgreSqlCompletedImportContext(
    NpgsqlConnection Connection,
    NpgsqlTransaction Transaction,
    long DatasetSnapshotId,
    EntityUid DatasetSnapshotUid,
    long ImportRunId,
    bool IsReusedImport);
