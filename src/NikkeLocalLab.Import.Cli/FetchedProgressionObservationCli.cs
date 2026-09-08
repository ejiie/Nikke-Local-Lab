using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;
using NikkeLocalLab.Configuration;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Import.Profile;
using NikkeLocalLab.Provenance;

internal static class FetchedProgressionObservationCli
{
  private const string TimestampFormat = "yyyy-MM-dd'T'HH:mm:ss.ffffff'Z'";
  private static readonly HashSet<string> SupportedOptions = new(StringComparer.Ordinal)
  {
    "config",
    "repository-root",
    "private-source",
    "source-receipt",
    "derived-candidate-database",
    "snapshot-uid"
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
      throw new LabConfigurationException("fetched_progression_option_not_supported");

    var snapshotUid = ParseUid(Require(options, "snapshot-uid"));
    var privateSourcePath = ResolveExistingFile(
        Require(options, "private-source"),
        "fetched_progression_private_source_missing");
    var sourceReceiptPath = ResolveExistingFile(
        Require(options, "source-receipt"),
        "fetched_progression_source_receipt_missing");
    var sourceReceipt = await ReadSourceReceiptAsync(sourceReceiptPath).ConfigureAwait(false);
    var candidatePath = options.TryGetValue("derived-candidate-database", out var suppliedCandidate)
        ? ResolveExistingFile(suppliedCandidate, "fetched_progression_candidate_missing")
        : null;

    RuntimeRootInitializer.Initialize(configuration, repositoryRoot);
    var outputRoot = Path.GetFullPath(Path.Combine(
        configuration.RuntimeRoot,
        "FetchedProgressionObservations",
        snapshotUid.ToString()));
    if (!PathBoundary.IsWithinOrEqual(outputRoot, configuration.RuntimeRoot))
      throw new LabConfigurationException("fetched_progression_output_root_invalid");
    if (Directory.Exists(outputRoot) && Directory.EnumerateFileSystemEntries(outputRoot).Any())
      throw new LabConfigurationException("fetched_progression_output_exists");

    var secret = RequireIdentitySecret(configuration);
    try
    {
      FetchedProgressionObservationV2 observation;
      try
      {
        await using var privateSource = new FileStream(
            privateSourcePath,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read);
        await using var candidate = candidatePath is null
            ? null
            : new FileStream(candidatePath, FileMode.Open, FileAccess.Read, FileShare.Read);
        observation = LegacyProgressionObservationMaterializerV2.Materialize(
            new LegacyProgressionMaterializationCommandV2(
                snapshotUid,
                sourceReceipt.CapturedAtUtc,
                privateSource,
                candidate,
                secret,
                sourceReceipt.ExtractionUid));
      }
      catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException or InvalidDataException)
      {
        throw new LabConfigurationException("fetched_progression_materialization_invalid");
      }

      var canonical = FetchedProgressionObservationV2JsonCodec.Encode(observation);
      Directory.CreateDirectory(outputRoot);
      var observationPath = Path.Combine(outputRoot, "fetched-progression.observation.json");
      var receiptPath = Path.Combine(outputRoot, "materialization.receipt.json");
      await File.WriteAllBytesAsync(observationPath, canonical).ConfigureAwait(false);
      var receipt = new
      {
        schemaVersion = 1,
        contractId = "nll/fetched-progression-observation-materialization-receipt/v1",
        materializedAtUtc = DateTimeOffset.UtcNow.ToString(TimestampFormat, CultureInfo.InvariantCulture),
        snapshotUid = observation.SnapshotUid.ToString(),
        capturedAtUtc = observation.CapturedAtUtc.ToString(TimestampFormat, CultureInfo.InvariantCulture),
        completenessStatusCode = observation.Completeness.StatusCode,
        availableComponentCount = observation.Completeness.AvailableComponentCount,
        derivedComponentCount = observation.Completeness.DerivedComponentCount,
        unavailableComponentCount = observation.Completeness.UnavailableComponentCount,
        reasonCodes = observation.Completeness.ReasonCodes,
        completedScenarioCount = observation.CompletedScenarios.Summary.ItemCount,
        mainQuestCompletedCount = observation.MainQuestData.CompletedCount,
        mainQuestRewardClaimedCount = observation.MainQuestData.RewardClaimedCount,
        contentsOpenUnlockedCount = observation.ContentsOpenUnlocked.Summary.ItemCount,
        stageClearHistoryCount = observation.StageClearHistorys.Summary.ItemCount,
        triggerCount = observation.Triggers.Summary.ItemCount,
        canonicalObservationByteLength = canonical.Length,
        canonicalObservationSha256 = Sha256Digest.Compute(canonical).ToString(),
        rawSourcesReadOnly = true,
        rawSourcePathPersisted = false,
        rawSourceHashPersisted = false,
        officialUserIdentifierPersisted = false,
        credentialOrSessionPersisted = false,
        officialOutboundUsed = false,
        nextStepCode = observation.Completeness.StatusCode == "complete"
            ? "merge_with_bound_fetched_account_snapshot"
            : "merge_available_components_without_promoting_unavailable_components"
      };
      await File.WriteAllBytesAsync(
          receiptPath,
          JsonSerializer.SerializeToUtf8Bytes(receipt, new JsonSerializerOptions { WriteIndented = true }))
          .ConfigureAwait(false);

      Console.WriteLine("fetched_progression_observation_materialized");
      Console.WriteLine($"snapshot_uid={observation.SnapshotUid}");
      Console.WriteLine($"completeness={observation.Completeness.StatusCode}");
      Console.WriteLine($"available_component_count={observation.Completeness.AvailableComponentCount}");
      Console.WriteLine($"derived_component_count={observation.Completeness.DerivedComponentCount}");
      Console.WriteLine($"unavailable_component_count={observation.Completeness.UnavailableComponentCount}");
      Console.WriteLine($"output_root={outputRoot}");
      return 0;
    }
    finally
    {
      CryptographicOperations.ZeroMemory(secret);
    }
  }

  private static byte[] RequireIdentitySecret(ResolvedLabConfiguration configuration)
  {
    var text = Environment.GetEnvironmentVariable(configuration.IdentitySecretEnvironmentVariable);
    if (string.IsNullOrWhiteSpace(text))
      throw new LabConfigurationException("identity_secret_missing");
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

  private static string ResolveExistingFile(string path, string code)
  {
    string fullPath;
    try
    {
      fullPath = Path.GetFullPath(path);
    }
    catch (Exception exception) when (exception is ArgumentException or NotSupportedException or PathTooLongException)
    {
      throw new LabConfigurationException(code);
    }
    if (!File.Exists(fullPath)) throw new LabConfigurationException(code);
    return fullPath;
  }

  private static EntityUid ParseUid(string text) =>
      Guid.TryParseExact(text, "D", out var value) && value != Guid.Empty
          ? new EntityUid(value)
          : throw new LabConfigurationException("fetched_progression_snapshot_uid_invalid");

  private static async Task<LegacySourceReceipt> ReadSourceReceiptAsync(string path)
  {
    try
    {
      var utf8 = await File.ReadAllBytesAsync(path).ConfigureAwait(false);
      using var document = JsonDocument.Parse(utf8);
      var root = document.RootElement;
      if (root.ValueKind != JsonValueKind.Object ||
          root.GetProperty("schemaVersion").GetInt32() != 1 ||
          root.GetProperty("contractId").GetString() !=
              "nll/phase3b2-user-progression-source-extraction/v1" ||
          root.GetProperty("officialUserIdentifierPersisted").GetBoolean() ||
          root.GetProperty("credentialOrSessionFieldPersisted").GetBoolean() ||
          root.GetProperty("officialOutboundUsed").GetBoolean())
        throw new InvalidDataException();
      var extractionUid = root.GetProperty("extractionUid").GetString();
      var timestampText = root.GetProperty("extractedAtUtc").GetString();
      if (string.IsNullOrWhiteSpace(extractionUid) ||
          !Guid.TryParseExact(extractionUid, "D", out _) ||
          !DateTimeOffset.TryParse(
              timestampText,
              CultureInfo.InvariantCulture,
              DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
              out var timestamp) ||
          timestamp.Offset != TimeSpan.Zero)
        throw new InvalidDataException();
      var normalized = new DateTimeOffset(timestamp.Ticks - (timestamp.Ticks % 10), TimeSpan.Zero);
      return new LegacySourceReceipt(extractionUid, normalized);
    }
    catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException or InvalidDataException or KeyNotFoundException)
    {
      throw new LabConfigurationException("fetched_progression_source_receipt_invalid");
    }
  }

  private static string Require(IReadOnlyDictionary<string, string> options, string name) =>
      options.TryGetValue(name, out var value) && !string.IsNullOrWhiteSpace(value)
          ? value
          : throw new LabConfigurationException("fetched_progression_required_option_missing");

  private sealed record LegacySourceReceipt(string ExtractionUid, DateTimeOffset CapturedAtUtc);
}
