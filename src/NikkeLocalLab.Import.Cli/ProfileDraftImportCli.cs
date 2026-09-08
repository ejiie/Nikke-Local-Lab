using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using NikkeLocalLab.Configuration;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Import.Profile;
using NikkeLocalLab.Persistence.PostgreSql;
using NikkeLocalLab.Provenance;

internal static class ProfileDraftImportCli
{
  private const string ImportedAtFormat = "yyyy-MM-dd'T'HH:mm:ss.ffffff'Z'";
  private static readonly HashSet<string> SupportedOptions = new(StringComparer.Ordinal)
  {
    "config",
    "repository-root",
    "level-authority",
    "operation-uid",
    "imported-at-utc",
    "output-draft"
  };

  public static async Task<int> ImportAsync(
      ResolvedLabConfiguration configuration,
      string repositoryRoot,
      IReadOnlyDictionary<string, string> options)
  {
    ArgumentNullException.ThrowIfNull(configuration);
    ArgumentException.ThrowIfNullOrWhiteSpace(repositoryRoot);
    ArgumentNullException.ThrowIfNull(options);
    var request = ParseRequest(
        options,
        TimeProvider.System,
        new RandomEntityUidGenerator());
    var sourcePath = ProfileSanitizerCli.ResolveSourcePath(configuration, repositoryRoot);
    var outputDraftPath = ResolveOutputDraftPath(configuration, options);
    var secret = RequireIdentitySecret(configuration);
    try
    {
      RuntimeRootInitializer.Initialize(configuration, repositoryRoot);
      var transformerBinarySha256 = await ComputeTransformerBinarySha256Async()
          .ConfigureAwait(false);
      var importOptions = new OfflineProfileImportOptions(
          request.ImportedAtUtc,
          transformerBinarySha256,
          request.LevelAuthority);
      var connectionString = PostgreSqlConnectionPolicy.ResolveFromEnvironment(
          configuration.DatabaseConnectionStringEnvironmentVariable);
      await using var dataSource = PostgreSqlDataSourceFactory.Create(connectionString);
      _ = await new PostgreSqlMigrationRunner().MigrateAsync(dataSource).ConfigureAwait(false);
      var resolver = await new PostgreSqlProfileCatalogAliasResolverFactory(dataSource)
          .CreateCurrentAsync()
          .ConfigureAwait(false);

      SanitizedProfileImportResult result;
      try
      {
        using var source = new FileStream(
            sourcePath,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read);
        result = new CredentialBearingProfileSanitizer().Sanitize(
            source,
            secret,
            resolver,
            importOptions);
      }
      catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or
          NotSupportedException)
      {
        throw new LabConfigurationException("profile_source_unavailable");
      }

      if (!result.Succeeded || result.Draft is null)
      {
        return Fail(SelectFailureCode(result.Diagnostics));
      }

      var canonicalUtf8 = SanitizedProfileDraftJsonCodec.Encode(result.Draft);
      var strictDraft = SanitizedProfileDraftJsonCodec.Decode(canonicalUtf8);
      var draftWrite = new SanitizedProfileDraftWrite(
          SanitizedProfileDraftDerivationKind.OfflineSanitizedImport,
          previousDraftUid: null,
          strictDraft.Provenance.SourceSchemaSha256,
          strictDraft.Provenance.TransformerBinarySha256,
          strictDraft.Provenance.SemanticOptionsSha256,
          ToPersistenceBinding(strictDraft.CharacterCatalog),
          ToPersistenceBinding(strictDraft.CombatSupportCatalog),
          Encoding.UTF8.GetString(canonicalUtf8));
      var command = new ImportSanitizedProfileDraftCommand(
          request.OperationUid,
          draftWrite,
          request.ImportedAtUtc);
      var receipt = await new PostgreSqlProfileImportStore(
          dataSource,
          new RandomEntityUidGenerator()).ImportDraftAsync(command).ConfigureAwait(false);
      if (outputDraftPath is not null)
      {
        await using var output = new FileStream(
            outputDraftPath,
            FileMode.CreateNew,
            FileAccess.Write,
            FileShare.None,
            bufferSize: 64 * 1024,
            FileOptions.Asynchronous | FileOptions.WriteThrough);
        await output.WriteAsync(canonicalUtf8).ConfigureAwait(false);
        await output.FlushAsync().ConfigureAwait(false);
      }
      WriteReceipt(Console.Out, receipt, strictDraft, result.Diagnostics);
      if (outputDraftPath is not null)
      {
        Console.WriteLine("sanitized_draft_exported=true");
      }
      return 0;
    }
    catch (Npgsql.NpgsqlException)
    {
      return Fail("profile_import_database_unavailable");
    }
    finally
    {
      CryptographicOperations.ZeroMemory(secret);
    }
  }

  internal static ProfileDraftImportRequest ParseRequest(
      IReadOnlyDictionary<string, string> options,
      TimeProvider timeProvider,
      IEntityUidGenerator uidGenerator)
  {
    ArgumentNullException.ThrowIfNull(options);
    ArgumentNullException.ThrowIfNull(timeProvider);
    ArgumentNullException.ThrowIfNull(uidGenerator);
    if (options.Keys.Any(static key => !SupportedOptions.Contains(key)))
    {
      throw new LabConfigurationException("profile_import_option_not_supported");
    }

    if (!options.TryGetValue("level-authority", out var levelAuthority))
    {
      throw new LabConfigurationException("profile_level_authority_required");
    }

    var authority = levelAuthority switch
    {
      CharacterLevelAuthorityPolicyCodes.RosterObservationV1 =>
          CharacterLevelAuthorityPolicy.RosterObservationV1,
      CharacterLevelAuthorityPolicyCodes.DetailObservationV1 =>
          CharacterLevelAuthorityPolicy.DetailObservationV1,
      _ => throw new LabConfigurationException("profile_level_authority_invalid")
    };
    var hasOperationUid = options.TryGetValue("operation-uid", out var operationUidText);
    var hasImportedAt = options.TryGetValue("imported-at-utc", out var importedAtText);
    if (hasOperationUid != hasImportedAt)
    {
      throw new LabConfigurationException("profile_import_idempotency_option_incomplete");
    }

    if (!hasOperationUid)
    {
      return new ProfileDraftImportRequest(
          authority,
          uidGenerator.NewUid(),
          ToPostgreSqlSafeUtc(timeProvider.GetUtcNow()),
          IsIdempotencyKeyExplicit: false);
    }

    if (!Guid.TryParseExact(operationUidText, "D", out var operationGuid) ||
        operationGuid == Guid.Empty)
    {
      throw new LabConfigurationException("profile_import_operation_uid_invalid");
    }

    if (!DateTimeOffset.TryParseExact(
            importedAtText,
            ImportedAtFormat,
            CultureInfo.InvariantCulture,
            DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
            out var importedAt) ||
        importedAt.Offset != TimeSpan.Zero)
    {
      throw new LabConfigurationException("profile_import_timestamp_invalid");
    }

    return new ProfileDraftImportRequest(
        authority,
        new EntityUid(operationGuid),
        importedAt,
        IsIdempotencyKeyExplicit: true);
  }

  internal static string SelectFailureCode(IReadOnlyList<ProfileImportDiagnostic> diagnostics)
  {
    ArgumentNullException.ThrowIfNull(diagnostics);
    return diagnostics
        .Where(static diagnostic =>
            diagnostic.Severity == ProfileImportDiagnosticSeverity.Error)
        .OrderBy(static diagnostic => diagnostic.Code, StringComparer.Ordinal)
        .ThenBy(static diagnostic => diagnostic.Scope)
        .Select(static diagnostic => diagnostic.Code)
        .FirstOrDefault() ?? "profile_source_invalid";
  }

  internal static void WriteReceipt(
      TextWriter writer,
      SanitizedProfileDraftReceipt receipt,
      SanitizedProfileDraft draft,
      IReadOnlyList<ProfileImportDiagnostic> diagnostics)
  {
    ArgumentNullException.ThrowIfNull(writer);
    ArgumentNullException.ThrowIfNull(receipt);
    ArgumentNullException.ThrowIfNull(draft);
    ArgumentNullException.ThrowIfNull(diagnostics);
    var status = receipt.IsIdempotentReplay
        ? "idempotent_replay"
        : receipt.IsContentReused
            ? "content_reused"
            : "succeeded";
    writer.WriteLine("profile_draft_imported");
    writer.WriteLine($"status={status}");
    writer.WriteLine($"operation_uid={receipt.OperationUid}");
    writer.WriteLine($"draft_uid={receipt.DraftUid}");
    writer.WriteLine($"sanitized_payload_sha256={draft.Provenance.SanitizedPayloadSha256}");
    writer.WriteLine($"canonical_payload_sha256={receipt.CanonicalPayloadSha256}");
    WriteCatalogBinding(writer, "character", draft.CharacterCatalog);
    WriteCatalogBinding(writer, "combat_support", draft.CombatSupportCatalog);
    writer.WriteLine(
        $"completed_at_utc={receipt.CreatedAtUtc.ToUniversalTime().ToString(ImportedAtFormat, CultureInfo.InvariantCulture)}");
    writer.WriteLine($"build_count={draft.Builds.Count}");
    writer.WriteLine($"console_count={draft.AccountState.Consoles.Count}");
    writer.WriteLine($"equipment_coordinate_count={draft.Builds.Sum(static build => build.Equipment.Count)}");
    writer.WriteLine(
        $"overload_line_count={draft.Builds.Sum(static build => build.Equipment.Sum(static equipment => equipment.OverloadLines.Count))}");
    writer.WriteLine($"diagnostic_count={diagnostics.Count}");
    writer.WriteLine(
        $"warning_count={diagnostics.Count(static diagnostic => diagnostic.Severity == ProfileImportDiagnosticSeverity.Warning)}");
    writer.WriteLine($"can_materialize_local_profile={draft.CanMaterializeLocalAccountProfile.ToString().ToLowerInvariant()}");
    writer.WriteLine($"local_profile_write_ready={draft.IsLocalAccountProfileWriteReady.ToString().ToLowerInvariant()}");
    writer.WriteLine("result_scope=sanitized_draft_only");
    writer.WriteLine("next_step=review_draft_then_create_local_profile");
  }

  private static byte[] RequireIdentitySecret(ResolvedLabConfiguration configuration)
  {
    var text = Environment.GetEnvironmentVariable(configuration.IdentitySecretEnvironmentVariable);
    if (string.IsNullOrWhiteSpace(text))
    {
      throw new LabConfigurationException("identity_secret_missing");
    }

    byte[] secret;
    try
    {
      secret = Convert.FromBase64String(text);
    }
    catch (FormatException)
    {
      throw new LabConfigurationException("identity_secret_invalid");
    }

    if (secret.Length < 32)
    {
      CryptographicOperations.ZeroMemory(secret);
      throw new LabConfigurationException("identity_secret_invalid");
    }

    return secret;
  }

  private static async Task<Sha256Digest> ComputeTransformerBinarySha256Async()
  {
    var assemblyPath = typeof(CredentialBearingProfileSanitizer).Assembly.Location;
    if (string.IsNullOrWhiteSpace(assemblyPath))
    {
      throw new LabConfigurationException("profile_transformer_binary_unavailable");
    }

    try
    {
      using var stream = new FileStream(
          assemblyPath,
          FileMode.Open,
          FileAccess.Read,
          FileShare.Read);
      return await Sha256Digest.ComputeAsync(stream).ConfigureAwait(false);
    }
    catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or
        NotSupportedException)
    {
      throw new LabConfigurationException("profile_transformer_binary_unavailable");
    }
  }

  private static string? ResolveOutputDraftPath(
      ResolvedLabConfiguration configuration,
      IReadOnlyDictionary<string, string> options)
  {
    if (!options.TryGetValue("output-draft", out var configuredPath))
    {
      return null;
    }

    string outputPath;
    try
    {
      outputPath = PathBoundary.NormalizeAbsoluteLocalPath(
          configuredPath,
          "profile_draft_output_path_invalid");
    }
    catch (LabConfigurationException)
    {
      throw;
    }

    if (!PathBoundary.IsWithinOrEqual(outputPath, configuration.RuntimeRoot))
    {
      throw new LabConfigurationException("profile_draft_output_boundary_invalid");
    }
    if (File.Exists(outputPath) || Directory.Exists(outputPath))
    {
      throw new LabConfigurationException("profile_draft_output_exists");
    }

    var parent = Path.GetDirectoryName(outputPath);
    if (string.IsNullOrWhiteSpace(parent) ||
        !PathBoundary.IsWithinOrEqual(parent, configuration.RuntimeRoot))
    {
      throw new LabConfigurationException("profile_draft_output_boundary_invalid");
    }
    Directory.CreateDirectory(parent);
    PathBoundary.EnsureNoReparsePoints(
        parent,
        requireFinalExists: true,
        "profile_draft_output_reparse_rejected");
    return outputPath;
  }

  private static DateTimeOffset ToPostgreSqlSafeUtc(DateTimeOffset value)
  {
    var utc = value.ToUniversalTime();
    return new DateTimeOffset(utc.Ticks - utc.Ticks % 10, TimeSpan.Zero);
  }

  private static LocalProfileCatalogBindingWrite ToPersistenceBinding(
      ProfileImportCatalogBinding binding) => new(
          binding.CatalogSnapshotUid,
          binding.DatasetSnapshotUid,
          binding.ManifestSha256);

  private static void WriteCatalogBinding(
      TextWriter writer,
      string prefix,
      ProfileImportCatalogBinding binding)
  {
    writer.WriteLine($"{prefix}_catalog_snapshot_uid={binding.CatalogSnapshotUid}");
    writer.WriteLine($"{prefix}_dataset_snapshot_uid={binding.DatasetSnapshotUid}");
    writer.WriteLine($"{prefix}_catalog_manifest_sha256={binding.ManifestSha256}");
  }

  private static int Fail(string code)
  {
    Console.Error.WriteLine($"error:{code}");
    return 1;
  }
}

internal sealed record ProfileDraftImportRequest(
    CharacterLevelAuthorityPolicy LevelAuthority,
    EntityUid OperationUid,
    DateTimeOffset ImportedAtUtc,
    bool IsIdempotencyKeyExplicit);
