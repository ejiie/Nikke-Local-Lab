using System.Globalization;
using System.Text;
using System.Text.Json;
using NikkeLocalLab.Configuration;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Import.Profile;
using NikkeLocalLab.Provenance;

internal static class FetchedAccountSnapshotCli
{
  private const string TimestampFormat = "yyyy-MM-dd'T'HH:mm:ss.ffffff'Z'";
  private static readonly HashSet<string> SupportedOptions = new(StringComparer.Ordinal)
  {
    "config",
    "repository-root",
    "sanitized-draft",
    "progression-observation",
    "snapshot-uid",
    "captured-at-utc"
  };

  public static async Task<int> MaterializeAsync(
      ResolvedLabConfiguration configuration,
      string repositoryRoot,
      IReadOnlyDictionary<string, string> options)
  {
    ArgumentNullException.ThrowIfNull(configuration);
    ArgumentException.ThrowIfNullOrWhiteSpace(repositoryRoot);
    ArgumentNullException.ThrowIfNull(options);
    if (options.Keys.Any(static key => !SupportedOptions.Contains(key)))
      throw new LabConfigurationException("fetched_snapshot_option_not_supported");
    var snapshotUid = ParseUid(Require(options, "snapshot-uid"));
    var capturedAtUtc = ParseTimestamp(Require(options, "captured-at-utc"));
    var draftPath = Path.GetFullPath(Require(options, "sanitized-draft"));
    if (!File.Exists(draftPath))
      throw new LabConfigurationException("fetched_snapshot_sanitized_draft_missing");

    RuntimeRootInitializer.Initialize(configuration, repositoryRoot);
    var sourcePath = ProfileSanitizerCli.ResolveSourcePath(configuration, repositoryRoot);
    var outputRoot = Path.GetFullPath(Path.Combine(
        configuration.RuntimeRoot,
        "FetchedAccountSnapshots",
        snapshotUid.ToString()));
    if (!PathBoundary.IsWithinOrEqual(outputRoot, configuration.RuntimeRoot))
      throw new LabConfigurationException("fetched_snapshot_output_root_invalid");
    if (Directory.Exists(outputRoot) && Directory.EnumerateFileSystemEntries(outputRoot).Any())
      throw new LabConfigurationException("fetched_snapshot_output_exists");

    byte[] draftUtf8;
    try
    {
      draftUtf8 = await File.ReadAllBytesAsync(draftPath).ConfigureAwait(false);
    }
    catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
    {
      throw new LabConfigurationException("fetched_snapshot_sanitized_draft_unavailable");
    }
    var draft = SanitizedProfileDraftJsonCodec.Decode(draftUtf8);
    var canonicalDraftUtf8 = SanitizedProfileDraftJsonCodec.Encode(draft);
    if (!draftUtf8.AsSpan().SequenceEqual(canonicalDraftUtf8))
      throw new LabConfigurationException("fetched_snapshot_sanitized_draft_not_canonical");

    CredentialBearingProfileCoverageResult coverageResult;
    FetchedBasicAccountObservationResult basicResult;
    try
    {
      using (var source = new FileStream(sourcePath, FileMode.Open, FileAccess.Read, FileShare.Read))
        coverageResult = new CredentialBearingProfileSanitizer().InspectCoverage(source);
      using (var source = new FileStream(sourcePath, FileMode.Open, FileAccess.Read, FileShare.Read))
        basicResult = CredentialBearingBasicInfoSanitizer.Sanitize(source);
    }
    catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or NotSupportedException)
    {
      throw new LabConfigurationException("fetched_snapshot_raw_source_unavailable");
    }
    if (!coverageResult.Succeeded || coverageResult.Coverage is null)
      throw new LabConfigurationException(SelectCoverageFailure(coverageResult.Diagnostics));

    var progressionResult = options.TryGetValue("progression-observation", out var progressionPath)
        ? await ReadProgressionAsync(progressionPath, snapshotUid, capturedAtUtc).ConfigureAwait(false)
        : new ProgressionReadResult(
            new FetchedProgressionObservation(null, null, null, null),
            null);
    var progression = progressionResult.Observation;
    var basic = basicResult.Observation ?? new FetchedBasicAccountObservation(null, null, null, null, null);
    var snapshot = FetchedAccountSnapshotMaterializer.Materialize(
        new FetchedAccountSnapshotMaterializationCommand(
            snapshotUid,
            capturedAtUtc,
            draft,
            coverageResult.Coverage,
            basic,
            progression,
            coverageResult.Diagnostics));
    var snapshotUtf8 = FetchedAccountSnapshotJsonCodec.Encode(snapshot);

    Directory.CreateDirectory(outputRoot);
    var snapshotPath = Path.Combine(outputRoot, "fetched-account.snapshot.json");
    var outputDraftPath = Path.Combine(outputRoot, "sanitized-profile.draft.json");
    var receiptPath = Path.Combine(outputRoot, "materialization.receipt.json");
    await File.WriteAllBytesAsync(snapshotPath, snapshotUtf8).ConfigureAwait(false);
    await File.WriteAllBytesAsync(outputDraftPath, canonicalDraftUtf8).ConfigureAwait(false);
    if (progressionResult.CanonicalV2 is not null)
    {
      await File.WriteAllBytesAsync(
          Path.Combine(outputRoot, "fetched-progression.observation.json"),
          progressionResult.CanonicalV2).ConfigureAwait(false);
    }
    var receipt = new
    {
      schemaVersion = 1,
      contractId = "nll/fetched-account-snapshot-materialization-receipt/v1",
      materializedAtUtc = DateTimeOffset.UtcNow.ToString(TimestampFormat, CultureInfo.InvariantCulture),
      snapshotUid = snapshot.SnapshotUid.ToString(),
      capturedAtUtc = snapshot.CapturedAtUtc.ToString(TimestampFormat, CultureInfo.InvariantCulture),
      completenessStatusCode = snapshot.Completeness.StatusCode,
      reasonCodes = snapshot.Completeness.ReasonCodes,
      rosterCount = snapshot.Completeness.RosterCount,
      characterDetailCount = snapshot.Completeness.CharacterDetailCount,
      equipmentCharacterCount = snapshot.Completeness.EquipmentCharacterCount,
      missingCharacterCount = snapshot.Completeness.MissingCharacterCount,
      canonicalSnapshotByteLength = snapshotUtf8.Length,
      canonicalSnapshotSha256 = Sha256Digest.Compute(snapshotUtf8).ToString(),
      canonicalSanitizedDraftByteLength = canonicalDraftUtf8.Length,
      canonicalSanitizedDraftSha256 = Sha256Digest.Compute(canonicalDraftUtf8).ToString(),
      detailedProgressionContractId = progressionResult.CanonicalV2 is null
          ? null
          : FetchedProgressionObservationV2Contract.ContractId,
      detailedProgressionByteLength = progressionResult.CanonicalV2?.Length,
      detailedProgressionSha256 = progressionResult.CanonicalV2 is null
          ? null
          : Sha256Digest.Compute(progressionResult.CanonicalV2).ToString(),
      detailedProgressionStatusCode = progression.DetailedStatusCode,
      stageClearHistoryCount = progression.StageClearHistoryCount,
      triggerCount = progression.TriggerCount,
      rawSourceReadOnly = true,
      rawSourcePathPersisted = false,
      rawSourceHashPersisted = false,
      officialUserIdentifierPersisted = false,
      credentialOrSessionPersisted = false,
      nextStepCode = snapshot.Completeness.StatusCode == "complete"
          ? "register_snapshot_then_preview_selective_import_diff"
          : "review_incomplete_snapshot_without_replacing_current"
    };
    var receiptUtf8 = JsonSerializer.SerializeToUtf8Bytes(receipt, new JsonSerializerOptions
    {
      WriteIndented = true
    });
    await File.WriteAllBytesAsync(receiptPath, receiptUtf8).ConfigureAwait(false);

    Console.WriteLine("fetched_account_snapshot_materialized");
    Console.WriteLine($"snapshot_uid={snapshot.SnapshotUid}");
    Console.WriteLine($"completeness={snapshot.Completeness.StatusCode}");
    Console.WriteLine($"roster_count={snapshot.Completeness.RosterCount}");
    Console.WriteLine($"detail_count={snapshot.Completeness.CharacterDetailCount}");
    Console.WriteLine($"output_root={outputRoot}");
    return 0;
  }

  private static async Task<ProgressionReadResult> ReadProgressionAsync(
      string path,
      EntityUid snapshotUid,
      DateTimeOffset capturedAtUtc)
  {
    byte[] utf8;
    try
    {
      utf8 = await File.ReadAllBytesAsync(Path.GetFullPath(path)).ConfigureAwait(false);
    }
    catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
    {
      throw new LabConfigurationException("fetched_progression_observation_unavailable");
    }
    try
    {
      using var document = JsonDocument.Parse(utf8);
      var root = document.RootElement;
      if (root.ValueKind != JsonValueKind.Object ||
          !root.TryGetProperty("schemaVersion", out var version) ||
          !version.TryGetInt32(out var schemaVersion) ||
          !root.TryGetProperty("contractId", out var contract))
        throw new LabConfigurationException("fetched_progression_observation_invalid");
      if (schemaVersion == 1 && contract.GetString() == "nll/fetched-progression-observation/v1")
      {
        if (root.GetProperty("officialUserIdentifierPersisted").GetBoolean() ||
            root.GetProperty("credentialOrSessionPersisted").GetBoolean())
          throw new LabConfigurationException("fetched_progression_observation_invalid");
        return new ProgressionReadResult(
            new FetchedProgressionObservation(
                OptionalDigest(root, "mainQuestDataSha256"),
                OptionalNonNegativeInt32(root, "mainQuestCompletedCount"),
                OptionalNonNegativeInt32(root, "completedScenarioCount"),
                OptionalNonNegativeInt32(root, "contentsOpenUnlockedCount")),
            null);
      }
      if (schemaVersion == 2 && contract.GetString() == FetchedProgressionObservationV2Contract.ContractId)
      {
        var detailed = FetchedProgressionObservationV2JsonCodec.Decode(utf8);
        var canonical = FetchedProgressionObservationV2JsonCodec.Encode(detailed);
        if (!utf8.AsSpan().SequenceEqual(canonical))
          throw new LabConfigurationException("fetched_progression_observation_not_canonical");
        if (detailed.SnapshotUid != snapshotUid)
          throw new LabConfigurationException("fetched_progression_observation_snapshot_uid_mismatch");
        if (detailed.CapturedAtUtc != capturedAtUtc)
          throw new LabConfigurationException("fetched_progression_observation_capture_time_mismatch");
        return new ProgressionReadResult(
            new FetchedProgressionObservation(
                detailed.MainQuestData.Summary.CanonicalEntriesSha256,
                detailed.MainQuestData.CompletedCount,
                detailed.CompletedScenarios.Summary.ItemCount,
                detailed.ContentsOpenUnlocked.Summary.ItemCount,
                detailed.SnapshotUid,
                Sha256Digest.Compute(canonical),
                detailed.Completeness.StatusCode,
                detailed.Completeness.ReasonCodes,
                detailed.StageClearHistorys.Summary.ItemCount,
                detailed.Triggers.Summary.ItemCount,
                detailed.CapturedAtUtc),
            canonical);
      }
      throw new LabConfigurationException("fetched_progression_observation_invalid");
    }
    catch (LabConfigurationException)
    {
      throw;
    }
    catch (Exception exception) when (exception is JsonException or InvalidDataException or KeyNotFoundException)
    {
      throw new LabConfigurationException("fetched_progression_observation_invalid");
    }
  }

  private static Sha256Digest? OptionalDigest(JsonElement root, string name)
  {
    var value = root.GetProperty(name);
    if (value.ValueKind == JsonValueKind.Null) return null;
    return Sha256Digest.TryParse(value.GetString(), out var digest)
        ? digest
        : throw new LabConfigurationException("fetched_progression_observation_invalid");
  }

  private static int? OptionalNonNegativeInt32(JsonElement root, string name)
  {
    var value = root.GetProperty(name);
    if (value.ValueKind == JsonValueKind.Null) return null;
    return value.TryGetInt32(out var result) && result >= 0
        ? result
        : throw new LabConfigurationException("fetched_progression_observation_invalid");
  }

  private static EntityUid ParseUid(string text) =>
      Guid.TryParseExact(text, "D", out var value) && value != Guid.Empty
          ? new EntityUid(value)
          : throw new LabConfigurationException("fetched_snapshot_uid_invalid");

  private static DateTimeOffset ParseTimestamp(string text) =>
      DateTimeOffset.TryParseExact(
          text,
          TimestampFormat,
          CultureInfo.InvariantCulture,
          DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
          out var value) && value.Offset == TimeSpan.Zero
          ? value
          : throw new LabConfigurationException("fetched_snapshot_capture_time_invalid");

  private static string Require(IReadOnlyDictionary<string, string> options, string name) =>
      options.TryGetValue(name, out var value) && !string.IsNullOrWhiteSpace(value)
          ? value
          : throw new LabConfigurationException("fetched_snapshot_required_option_missing");

  private static string SelectCoverageFailure(IReadOnlyList<ProfileImportDiagnostic> diagnostics) =>
      diagnostics.Where(static item => item.Severity == ProfileImportDiagnosticSeverity.Error)
          .OrderBy(static item => item.Code, StringComparer.Ordinal)
          .Select(static item => item.Code)
          .FirstOrDefault() ?? "fetched_snapshot_coverage_invalid";

  private sealed record ProgressionReadResult(
      FetchedProgressionObservation Observation,
      byte[]? CanonicalV2);
}
