using System.Text;
using System.Text.Json;
using App = NikkeLocalLab.Application.ProfileManagement;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Import.Profile;
using NikkeLocalLab.Persistence.PostgreSql;

const string DetailLevelAuthority = "detail_observation/v1";

try
{
  var options = ParseOptions(args);
  var draftPath = RequiredPath(options, "draft");
  var snapshotPath = RequiredPath(options, "snapshot");
  var receiptPath = RequiredOutputPath(options, "receipt");
  var accountLabel = App.ProfileManagementText.NormalizeAccountLabel(
      RequiredText(options, "account-label"));
  var connectionEnvironmentVariable = RequiredText(options, "connection-string-env");
  var connectionString = Environment.GetEnvironmentVariable(connectionEnvironmentVariable);
  Require(!string.IsNullOrWhiteSpace(connectionString), "control_center_bootstrap_database_missing");
  Require(File.Exists(draftPath) && File.Exists(snapshotPath),
      "control_center_bootstrap_input_missing");
  Require(!File.Exists(receiptPath), "control_center_bootstrap_receipt_exists");

  var draftUtf8 = await File.ReadAllBytesAsync(draftPath);
  var snapshotUtf8 = await File.ReadAllBytesAsync(snapshotPath);
  var draft = SanitizedProfileDraftJsonCodec.Decode(draftUtf8);
  var snapshot = FetchedAccountSnapshotJsonCodec.Decode(snapshotUtf8);
  Require(snapshot.Source.ArtifactSha256 == NikkeLocalLab.Provenance.Sha256Digest.Compute(draftUtf8),
      "control_center_bootstrap_snapshot_draft_mismatch");
  Require(snapshot.Account.CommanderLevel is >= 1 and <= 1_000_000 &&
          !string.IsNullOrWhiteSpace(snapshot.Account.DisplayName),
      "control_center_bootstrap_lobby_source_missing");

  await using var dataSource = PostgreSqlDataSourceFactory.Create(connectionString!);
  _ = await new PostgreSqlMigrationRunner().MigrateAsync(dataSource);
  var uidGenerator = new RandomEntityUidGenerator();
  var imported = await new PostgreSqlProfileImportStore(dataSource, uidGenerator).ImportDraftAsync(
      new ImportSanitizedProfileDraftCommand(
          EntityUid.New(),
          new SanitizedProfileDraftWrite(
              SanitizedProfileDraftDerivationKind.OfflineSanitizedImport,
              null,
              draft.Provenance.SourceSchemaSha256,
              draft.Provenance.TransformerBinarySha256,
              draft.Provenance.SemanticOptionsSha256,
              new LocalProfileCatalogBindingWrite(
                  draft.CharacterCatalog.CatalogSnapshotUid,
                  draft.CharacterCatalog.DatasetSnapshotUid,
                  draft.CharacterCatalog.ManifestSha256),
              new LocalProfileCatalogBindingWrite(
                  draft.CombatSupportCatalog.CatalogSnapshotUid,
                  draft.CombatSupportCatalog.DatasetSnapshotUid,
                  draft.CombatSupportCatalog.ManifestSha256),
              Encoding.UTF8.GetString(draftUtf8)),
          snapshot.CapturedAtUtc));

  var service = new PostgreSqlProfileManagementService(dataSource, uidGenerator);
  var createPreview = await service.PreviewCreateFromImportAsync(
      new App.CreateImportDiffCommand(
          EntityUid.New(),
          imported.DraftUid,
          imported.CanonicalPayloadSha256,
          DetailLevelAuthority,
          ["full_profile"]));
  Require(createPreview.Issues.All(static issue => issue.Severity != "error"),
      "control_center_bootstrap_create_preview_blocked");
  var created = await service.CreateFromImportAsync(
      new App.CreateFromImportCommand(
          EntityUid.New(),
          imported.DraftUid,
          imported.CanonicalPayloadSha256,
          createPreview.DiffSha256,
          DetailLevelAuthority,
          ["full_profile"]));
  var manifest = await service.EnsureBuiltInFeatureManifestAsync();
  _ = await service.InitializeLocalStateAsync(
      new App.InitializeLocalStateCommand(
          EntityUid.New(),
          created.AccountUid,
          created.ProfileRevision.RevisionUid,
          manifest.ManifestUid,
          manifest.ContentSha256,
          App.ProfileManagementText.NormalizeDisplayName(snapshot.Account.DisplayName!),
          snapshot.Account.CommanderLevel!.Value,
          null,
          null,
          null,
          null,
          [
            new App.WalletBalanceProjection("credit", 0),
            new App.WalletBalanceProjection("jewel", 0)
          ]));
  _ = await service.RegisterFetchedAccountSnapshotAsync(
      new App.RegisterFetchedAccountSnapshotCommand(
          created.AccountUid,
          created.ProfileRevision.RevisionUid,
          Encoding.UTF8.GetString(snapshotUtf8),
          Encoding.UTF8.GetString(draftUtf8)));
  var currentSummary = (await service.ListAccountsAsync())
      .Single(item => item.AccountUid == created.AccountUid);
  var renamed = await service.RenameAccountAsync(
      new App.RenameAccountCommand(
          created.AccountUid,
          currentSummary.AccountLabel,
          accountLabel));
  var candidate = await service.ExportRuntimeProjectionCandidateAsync(created.AccountUid) ??
      throw new InvalidOperationException("control_center_bootstrap_candidate_missing");
  var candidateObservationPath = Path.Combine(
      Path.GetDirectoryName(receiptPath)!,
      "bootstrap.runtime-candidate.json");
  await WriteAtomicAsync(
      candidateObservationPath,
      JsonSerializer.Serialize(candidate, new JsonSerializerOptions { WriteIndented = true }) + "\n");
  var candidateReady = candidate.ValidationStatusCode == "ready" &&
      candidate.ValidationReasonCodes.Count == 0 &&
      candidate.Values.All(static value => value.Status is "ready" or "not_applicable");

  var receipt = new
  {
    schemaVersion = 1,
    contractId = "nll/control-center-persistent-bootstrap/v1",
    completedAtUtc = DateTimeOffset.UtcNow,
    accountUid = created.AccountUid.ToString(),
    accountLabel = renamed.AccountLabel,
    snapshotUid = snapshot.SnapshotUid.ToString(),
    profileRevisionUid = created.ProfileRevision.RevisionUid.ToString(),
    runtimeCandidateSha256 = candidate.CandidateSha256.ToString(),
    runtimeCandidateValueCount = candidate.Values.Count,
    runtimeCandidateReady = candidateReady,
    validationStatusCode = candidate.ValidationStatusCode,
    validationReasonCodes = candidate.ValidationReasonCodes,
    snapshotCompleteness = snapshot.Completeness.StatusCode,
    snapshotReasonCodes = snapshot.Completeness.ReasonCodes,
    commanderLevel = snapshot.Account.CommanderLevel,
    rawSourcePersisted = false,
    officialUserIdentifierPersisted = false,
    credentialOrSessionPersisted = false,
    officialOutboundUsed = false,
    nextStepCode = candidateReady
        ? "operator_open_control_center_and_review_ready_candidate"
        : "operator_open_control_center_resolve_candidate_then_launch"
  };
  await WriteAtomicAsync(
      receiptPath,
      JsonSerializer.Serialize(receipt, new JsonSerializerOptions { WriteIndented = true }) + "\n");
  Console.WriteLine(JsonSerializer.Serialize(receipt));
  return 0;
}
catch (Exception exception)
{
  var code = exception.Message is { Length: >= 3 and <= 128 } message &&
      message.All(static value => char.IsAsciiLetterOrDigit(value) || value is '_' or '-' or '.')
          ? message
          : "control_center_bootstrap_failed";
  Console.Error.WriteLine($"error:{code}");
  return 1;
}

static Dictionary<string, string> ParseOptions(string[] args)
{
  Require(args.Length % 2 == 0, "control_center_bootstrap_arguments_invalid");
  var result = new Dictionary<string, string>(StringComparer.Ordinal);
  for (var index = 0; index < args.Length; index += 2)
  {
    Require(args[index].StartsWith("--", StringComparison.Ordinal) &&
            result.TryAdd(args[index][2..], args[index + 1]),
        "control_center_bootstrap_arguments_invalid");
  }
  return result;
}

static string RequiredText(IReadOnlyDictionary<string, string> options, string name)
{
  Require(options.TryGetValue(name, out var value) && !string.IsNullOrWhiteSpace(value),
      "control_center_bootstrap_option_missing");
  return value!;
}

static string RequiredPath(IReadOnlyDictionary<string, string> options, string name) =>
    Path.GetFullPath(RequiredText(options, name));

static string RequiredOutputPath(IReadOnlyDictionary<string, string> options, string name)
{
  var path = RequiredPath(options, name);
  Directory.CreateDirectory(Path.GetDirectoryName(path)!);
  return path;
}

static async Task WriteAtomicAsync(string path, string value)
{
  var temporary = path + ".partial-" + Guid.NewGuid().ToString("N");
  await File.WriteAllTextAsync(temporary, value, new UTF8Encoding(false));
  File.Move(temporary, path);
}

static void Require(bool condition, string code)
{
  if (!condition) throw new InvalidOperationException(code);
}
