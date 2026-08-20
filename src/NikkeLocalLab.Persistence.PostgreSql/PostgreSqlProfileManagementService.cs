using System.Text.Json;
using System.Security.Cryptography;
using App = NikkeLocalLab.Application.ProfileManagement;
using ImportProfile = NikkeLocalLab.Import.Profile;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;
using Npgsql;

namespace NikkeLocalLab.Persistence.PostgreSql;

public sealed partial class PostgreSqlProfileManagementService : App.IProfileManagementService
{
  private const string CandidateKind = "profile_edit_candidate/v1";
  private const string CandidateDiffContract = "profile_edit_diff.v1";
  private const string ImportDiffContract = "sanitized_import_diff.v1";
  private const string CreateImportDiffContract = "sanitized_import_create_diff.v1";
  private const string FeatureContract = "nll/client-feature-manifest/v1";
  private const string NoLevelAuthority = "unresolved/no_apply";
  private const string RosterLevelAuthority = "roster_observation/v1";
  private const string DetailLevelAuthority = "detail_observation/v1";

  private static readonly JsonSerializerOptions JsonOptions = new()
  {
    PropertyNamingPolicy = JsonNamingPolicy.CamelCase
  };

  private static readonly Sha256Digest EditorSanitizerContract =
      Sha256Digest.ComputeUtf8("nll/profile-editor-source-free-contract/v1");
  private static readonly Sha256Digest EditorTransformer =
      Sha256Digest.ComputeUtf8("nll/profile-editor-candidate-transformer/v1");
  private static readonly Sha256Digest EditorSemanticOptions =
      Sha256Digest.ComputeUtf8("nll/profile-editor-candidate-options/v1");
  private static readonly EntityUid BuiltInManifestOperationUid = new(
      Guid.ParseExact("2a2f0001-0000-4000-8000-000000000001", "D"));
  private static readonly DateTimeOffset BuiltInManifestTimestamp = new(
      2026,
      1,
      1,
      0,
      0,
      0,
      TimeSpan.Zero);

  private readonly PostgreSqlLocalAccountProfileStore _profileStore;
  private readonly PostgreSqlLocalGameStateStore _gameStateStore;
  private readonly PostgreSqlProfileImportStore _importStore;
  private readonly PostgreSqlProfileCatalogAliasResolverFactory? _catalogResolverFactory;
  private readonly TimeProvider _timeProvider;
  private readonly Sha256Digest _transformerBinarySha256;

  public PostgreSqlProfileManagementService(
      NpgsqlDataSource dataSource,
      IEntityUidGenerator uidGenerator,
      TimeProvider? timeProvider = null,
      Sha256Digest? transformerBinarySha256 = null)
      : this(
          new PostgreSqlLocalAccountProfileStore(dataSource, uidGenerator),
          new PostgreSqlLocalGameStateStore(dataSource, uidGenerator),
          new PostgreSqlProfileImportStore(dataSource, uidGenerator),
          timeProvider,
          transformerBinarySha256,
          new PostgreSqlProfileCatalogAliasResolverFactory(dataSource))
  {
  }

  public PostgreSqlProfileManagementService(
      PostgreSqlLocalAccountProfileStore profileStore,
      PostgreSqlLocalGameStateStore gameStateStore,
      PostgreSqlProfileImportStore importStore,
      TimeProvider? timeProvider = null,
      Sha256Digest? transformerBinarySha256 = null,
      PostgreSqlProfileCatalogAliasResolverFactory? catalogResolverFactory = null)
  {
    _profileStore = profileStore ?? throw new ArgumentNullException(nameof(profileStore));
    _gameStateStore = gameStateStore ?? throw new ArgumentNullException(nameof(gameStateStore));
    _importStore = importStore ?? throw new ArgumentNullException(nameof(importStore));
    _catalogResolverFactory = catalogResolverFactory;
    _timeProvider = timeProvider ?? TimeProvider.System;
    _transformerBinarySha256 = transformerBinarySha256 ?? ComputeTransformerBinarySha256();
  }

  public Task<App.ClientFeatureManifestProjection> EnsureBuiltInFeatureManifestAsync(
      CancellationToken cancellationToken = default) => TranslateAsync(async () =>
  {
    var write = new LocalClientFeatureManifestWrite(
        FeatureContract,
        BuiltInFeatures());
    var published = await _gameStateStore.PublishFeatureManifestAsync(
        new PublishLocalClientFeatureManifestCommand(
            BuiltInManifestOperationUid,
            write,
            BuiltInManifestTimestamp),
        cancellationToken).ConfigureAwait(false);
    var latest = await _gameStateStore.GetLatestFeatureManifestAsync(cancellationToken)
        .ConfigureAwait(false) ??
        throw Failure(App.ProfileManagementFailureKind.Unavailable, "client_feature_manifest_not_persisted");
    if (latest.ManifestUid != published.ManifestUid ||
        latest.ContentSha256 != write.ContentSha256 ||
        !string.Equals(latest.ContractVersion, FeatureContract, StringComparison.Ordinal))
    {
      throw Failure(App.ProfileManagementFailureKind.Conflict, "client_feature_manifest_head_conflict");
    }

    return MapFeatureManifest(latest);
  });

  public Task<App.AccountBootstrapProjection?> GetCurrentBootstrapAsync(
      EntityUid accountUid,
      CancellationToken cancellationToken = default) => TranslateAsync(async () =>
  {
    for (var attempt = 0; attempt < 2; attempt++)
    {
      var profile = await _profileStore.GetCurrentAsync(accountUid, cancellationToken)
          .ConfigureAwait(false);
      if (profile is null)
      {
        return null;
      }

      LocalClientBootstrapProjection? bootstrap;
      try
      {
        bootstrap = await _gameStateStore.GetBootstrapAsync(accountUid, cancellationToken)
            .ConfigureAwait(false);
      }
      catch (LocalGameStateIntegrityException exception)
          when (attempt == 0 && exception.Code == "local_game_lobby_profile_stale")
      {
        continue;
      }

      if (bootstrap is null)
      {
        return null;
      }

      if (bootstrap.ProfileTemplateRevisionUid == profile.Revision.ProfileTemplateRevisionUid)
      {
        return MapBootstrap(bootstrap, MapProfile(profile));
      }
    }

    throw Failure(App.ProfileManagementFailureKind.Conflict, "bootstrap_profile_snapshot_conflict");
  });

  public Task<App.AccountBootstrapProjection> InitializeLocalStateAsync(
      App.InitializeLocalStateCommand command,
      CancellationToken cancellationToken = default) => TranslateAsync(async () =>
  {
    ArgumentNullException.ThrowIfNull(command);
    var balances = RequireWalletBalances(command.Balances);
    _ = App.ProfileManagementText.NormalizeDisplayName(command.DisplayName);
    if (command.CommanderLevel is < 1 or > 1_000_000)
    {
      throw Failure(App.ProfileManagementFailureKind.InvalidRequest, "lobby_presentation_value_invalid");
    }

    var initialize = new InitializeLocalGameStateCommand(
        command.OperationUid,
        command.AccountUid,
        command.ExpectedProfileRevisionUid,
        command.FeatureManifestUid,
        new LocalLobbyPresentationWrite(
            command.DisplayName,
            LocalGameIntFact.Ready(command.CommanderLevel),
            UidFact(command.LobbyCharacterSelectionUid),
            UidFact(command.ProfileIconSelectionUid),
            UidFact(command.ProfileFrameSelectionUid),
            UidFact(command.LobbyBackgroundSelectionUid),
            LocalGameRevisionOrigin.SystemDefault),
        new LocalWalletWrite(
            balances.Select(static item => new LocalWalletBalance(
                item.CurrencyCode == "credit"
                    ? LocalWalletCurrency.Credit
                    : LocalWalletCurrency.Jewel,
                item.Balance)),
            LocalGameRevisionOrigin.SystemDefault),
        Now());
    var replay = await _gameStateStore.TryReplayInitializeAsync(
        initialize,
        cancellationToken).ConfigureAwait(false);
    if (replay is not null)
    {
      if (replay.FeatureManifest.ManifestUid != command.FeatureManifestUid ||
          replay.FeatureManifest.ContentSha256 != command.ExpectedFeatureManifestSha256)
      {
        throw Failure(
            App.ProfileManagementFailureKind.Conflict,
            "client_feature_manifest_conflict");
      }

      return await RequireCurrentBootstrapAsync(command.AccountUid, cancellationToken)
          .ConfigureAwait(false);
    }

    _ = await RequireCurrentAsync(
        command.AccountUid,
        command.ExpectedProfileRevisionUid,
        cancellationToken).ConfigureAwait(false);
    var manifest = await _gameStateStore.GetLatestFeatureManifestAsync(cancellationToken)
        .ConfigureAwait(false) ??
        throw Failure(App.ProfileManagementFailureKind.NotFound, "client_feature_manifest_not_found");
    if (manifest.ManifestUid != command.FeatureManifestUid ||
        manifest.ContentSha256 != command.ExpectedFeatureManifestSha256)
    {
      throw Failure(App.ProfileManagementFailureKind.Conflict, "client_feature_manifest_conflict");
    }

    await _gameStateStore.InitializeAsync(initialize, cancellationToken).ConfigureAwait(false);
    return await RequireCurrentBootstrapAsync(command.AccountUid, cancellationToken)
        .ConfigureAwait(false);
  });

  public Task<App.CurrentProfileProjection?> GetCurrentProfileAsync(
      EntityUid accountUid,
      CancellationToken cancellationToken = default) => TranslateAsync(async () =>
  {
    var current = await _profileStore.GetCurrentAsync(accountUid, cancellationToken)
        .ConfigureAwait(false);
    return current is null ? null : MapProfile(current);
  });

  public Task<App.LocalSessionProjection?> GetSessionAsync(
      EntityUid sessionUid,
      DateTimeOffset observedAtUtc,
      CancellationToken cancellationToken = default) => TranslateAsync(async () =>
  {
    var receipt = await _profileStore.GetLocalSessionAsync(
        sessionUid,
        observedAtUtc,
        cancellationToken).ConfigureAwait(false);
    return receipt is null
        ? null
        : new App.LocalSessionProjection(
            receipt.SessionUid,
            receipt.AccountUid,
            receipt.IssuedAtUtc,
            receipt.ExpiresAtUtc,
            receipt.RevokedAtUtc,
            SessionCode(receipt.Status));
  });

  public Task<App.ProfileDiffProjection> PreviewProfileEditsAsync(
      App.ProfileEditPreviewCommand command,
      CancellationToken cancellationToken = default) => TranslateAsync(async () =>
  {
    ArgumentNullException.ThrowIfNull(command);
    if (command.OperationUid.Value == Guid.Empty || command.AccountUid.Value == Guid.Empty ||
        command.ExpectedProfileRevisionUid.Value == Guid.Empty ||
        command.Operations is null || command.Operations.Count > 512)
    {
      throw Failure(App.ProfileManagementFailureKind.InvalidRequest, "profile_edit_request_invalid");
    }

    foreach (var operation in command.Operations)
    {
      operation.Validate();
    }

    if (command.Operations
        .GroupBy(static operation => (operation.FieldCode, operation.SubjectUid))
        .Any(static group => group.Count() != 1))
    {
      throw Failure(App.ProfileManagementFailureKind.InvalidRequest, "profile_edit_coordinate_duplicate");
    }

    var canonicalOperations = command.Operations
        .OrderBy(static operation => operation.FieldCode, StringComparer.Ordinal)
        .ThenBy(static operation => operation.SubjectUid?.ToString(), StringComparer.Ordinal)
        .ToArray();

    var current = await RequireCurrentAsync(
        command.AccountUid,
        command.ExpectedProfileRevisionUid,
        cancellationToken).ConfigureAwait(false);
    var edited = ApplyOperations(current, canonicalOperations);
    var changes = BuildAllChanges(current.Profile, edited);
    var candidateJson = SerializeCandidate(command, canonicalOperations);
    var draft = await _importStore.SaveProfileEditCandidateAsync(
        command.OperationUid,
        command.AccountUid,
        command.ExpectedProfileRevisionUid,
        candidateJson,
        canonicalOperations.Length,
        Now(),
        cancellationToken).ConfigureAwait(false);

    var diffJson = SerializeDiff(
        "profile_edit_diff/v1",
        draft.CandidateUid,
        draft.CanonicalOperationsSha256,
        command.AccountUid,
        command.ExpectedProfileRevisionUid,
        levelAuthorityPolicy: null,
        scopes: null,
        changes);
    var existingDiff = await _importStore.GetDiffAsync(command.OperationUid, cancellationToken)
        .ConfigureAwait(false);
    ProfileDraftDiffDocument diff;
    if (existingDiff is null)
    {
      var created = await _importStore.CreateDiffAsync(
          new CreateProfileDraftDiffCommand(
              command.OperationUid,
              draft.CandidateUid,
              command.AccountUid,
              command.ExpectedProfileRevisionUid,
              new ProfileDraftDiffWrite(
                  CandidateDiffContract,
                  diffJson,
                  changes.Count,
                  hasConflicts: false),
              draft.CreatedAtUtc),
          cancellationToken).ConfigureAwait(false);
      diff = await _importStore.GetDiffAsync(created.DiffUid, cancellationToken)
          .ConfigureAwait(false) ??
          throw Failure(App.ProfileManagementFailureKind.Unavailable, "profile_diff_not_persisted");
    }
    else
    {
      diff = existingDiff;
      EnsureDiffTopology(
          diff,
          draft.CandidateUid,
          command.AccountUid,
          command.ExpectedProfileRevisionUid);
      if (!string.Equals(diff.CanonicalDiffJson, diffJson, StringComparison.Ordinal))
      {
        throw Failure(App.ProfileManagementFailureKind.Conflict, "profile_diff_operation_reuse_mismatch");
      }
    }

    return new App.ProfileDiffProjection(
        diff.CanonicalDiffSha256,
        command.AccountUid,
        command.ExpectedProfileRevisionUid,
        draft.CandidateUid,
        draft.CanonicalOperationsSha256,
        changes,
        MapIssues(current.Revision.IssueCodes));
  });

  public Task<App.ProfileWriteReceipt> SaveProfileAsync(
      App.SaveProfileCommand command,
      CancellationToken cancellationToken = default) => TranslateAsync(async () =>
  {
    ArgumentNullException.ThrowIfNull(command);
    var draft = await RequireEditCandidateAsync(
        command.CandidateDraftUid,
        command.CandidateSha256,
        cancellationToken).ConfigureAwait(false);
    var candidate = ParseCandidate(draft.CanonicalOperationsJson);
    EnsureCandidate(candidate, command.AccountUid, command.ExpectedProfileRevisionUid);
    var resolution = await ResolveWriteDiffAsync(
        command.OperationUid,
        ProfileDraftApplicationKind.Apply,
        draft.CandidateUid,
        command.AccountUid,
        command.ExpectedProfileRevisionUid,
        command.ExpectedDiffSha256,
        CandidateDiffContract,
        cancellationToken).ConfigureAwait(false);
    if (resolution.Recovered is not null)
    {
      return resolution.Recovered;
    }

    var diff = resolution.Diff;

    var current = await RequireCurrentAsync(
        command.AccountUid,
        command.ExpectedProfileRevisionUid,
        cancellationToken).ConfigureAwait(false);
    var operations = candidate.Operations.Select(MapOperation).ToArray();
    var profile = ApplyOperations(current, operations);
    var changes = BuildAllChanges(current.Profile, profile);
    var expectedDiffJson = SerializeDiff(
        "profile_edit_diff/v1",
        draft.CandidateUid,
        draft.CanonicalOperationsSha256,
        command.AccountUid,
        command.ExpectedProfileRevisionUid,
        levelAuthorityPolicy: null,
        scopes: null,
        changes);
    EnsureEditorDiff(diff, expectedDiffJson, changes.Count);
    var prepared = await BeginOrAdoptApplicationAsync(
        command.OperationUid,
        ProfileDraftApplicationKind.Apply,
        diff,
        draft.CandidateUid,
        command.AccountUid,
        command.ExpectedProfileRevisionUid,
        command.ExpectedDiffSha256,
        CandidateDiffContract,
        expectedDiffJson,
        changes.Count,
        cancellationToken).ConfigureAwait(false);
    var application = prepared.Application;
    var receipt = await _profileStore.SaveAsync(
        new SaveLocalAccountProfileCommand(
            command.OperationUid,
            command.AccountUid,
            command.ExpectedProfileRevisionUid,
            profile,
            prepared.Diff.CreatedAtUtc),
        cancellationToken).ConfigureAwait(false);
    await _importStore.LinkApplicationAsync(application, cancellationToken).ConfigureAwait(false);
    return MapWriteReceipt(command.OperationUid, receipt);
  });

  public Task<App.ProfileWriteReceipt> SaveAsProfileAsync(
      App.SaveAsProfileCommand command,
      CancellationToken cancellationToken = default) => TranslateAsync(async () =>
  {
    ArgumentNullException.ThrowIfNull(command);
    if (command.CandidateDraftUid is null || command.CandidateSha256 is null)
    {
      throw Failure(App.ProfileManagementFailureKind.InvalidRequest, "save_as_candidate_required");
    }

    var draft = await RequireEditCandidateAsync(
        command.CandidateDraftUid.Value,
        command.CandidateSha256.Value,
        cancellationToken).ConfigureAwait(false);
    var candidate = ParseCandidate(draft.CanonicalOperationsJson);
    EnsureCandidate(candidate, command.SourceAccountUid, command.ExpectedSourceProfileRevisionUid);
    var resolution = await ResolveWriteDiffAsync(
        command.OperationUid,
        ProfileDraftApplicationKind.SaveAs,
        draft.CandidateUid,
        command.SourceAccountUid,
        command.ExpectedSourceProfileRevisionUid,
        command.ExpectedDiffSha256,
        CandidateDiffContract,
        cancellationToken).ConfigureAwait(false);
    if (resolution.Recovered is not null)
    {
      return resolution.Recovered;
    }

    var diff = resolution.Diff;

    var current = await RequireCurrentAsync(
        command.SourceAccountUid,
        command.ExpectedSourceProfileRevisionUid,
        cancellationToken).ConfigureAwait(false);
    var operations = candidate.Operations.Select(MapOperation).ToArray();
    var profile = ApplyOperations(current, operations);
    var changes = BuildAllChanges(current.Profile, profile);
    var expectedDiffJson = SerializeDiff(
        "profile_edit_diff/v1",
        draft.CandidateUid,
        draft.CanonicalOperationsSha256,
        command.SourceAccountUid,
        command.ExpectedSourceProfileRevisionUid,
        levelAuthorityPolicy: null,
        scopes: null,
        changes);
    EnsureEditorDiff(diff, expectedDiffJson, changes.Count);
    var prepared = await BeginOrAdoptApplicationAsync(
        command.OperationUid,
        ProfileDraftApplicationKind.SaveAs,
        diff,
        draft.CandidateUid,
        command.SourceAccountUid,
        command.ExpectedSourceProfileRevisionUid,
        command.ExpectedDiffSha256,
        CandidateDiffContract,
        expectedDiffJson,
        changes.Count,
        cancellationToken).ConfigureAwait(false);
    var application = prepared.Application;
    var receipt = await _profileStore.CreateAsync(
        new CreateLocalAccountProfileCommand(
            command.OperationUid,
            profile,
            prepared.Diff.CreatedAtUtc),
        cancellationToken).ConfigureAwait(false);
    await _importStore.LinkApplicationAsync(application, cancellationToken).ConfigureAwait(false);
    return MapWriteReceipt(command.OperationUid, receipt);
  });

  public Task<App.SourceFreeImportDraftProjection?> GetImportDraftAsync(
      EntityUid draftUid,
      CancellationToken cancellationToken = default) => TranslateAsync(async () =>
  {
    var draft = await _importStore.GetDraftAsync(draftUid, cancellationToken)
        .ConfigureAwait(false);
    return draft is null ? null : ProjectDraft(draft);
  });

  public Task<App.ProfileDiffProjection> PreviewImportDiffAsync(
      App.ImportDiffCommand command,
      CancellationToken cancellationToken = default) => TranslateAsync(async () =>
  {
    ArgumentNullException.ThrowIfNull(command);
    ValidateImportPolicy(command.LevelAuthorityPolicy, command.Scopes);
    var draft = await RequireDraftAsync(
        command.DraftUid,
        command.ExpectedDraftSha256,
        cancellationToken).ConfigureAwait(false);
    var current = await RequireCurrentAsync(
        command.TargetAccountUid,
        command.ExpectedProfileRevisionUid,
        cancellationToken).ConfigureAwait(false);
    var decoded = DecodeSanitizedDraft(draft);
    var replacesBuilds = ReplacesBuilds(command.Scopes);
    var issues = MapIssues(current.Revision.IssueCodes).ToList();
    if (replacesBuilds && command.LevelAuthorityPolicy == NoLevelAuthority)
    {
      issues.Add(new App.ProfileIssueProjection("level_authority_not_selected", "error"));
    }
    else if (replacesBuilds && (!decoded.CanMaterializeLocalAccountProfile ||
             decoded.Builds.Any(build =>
                 !string.Equals(
                     build.Level.AuthorityPolicyCode,
                     command.LevelAuthorityPolicy,
                     StringComparison.Ordinal))))
    {
      issues.Add(new App.ProfileIssueProjection("level_authority_draft_mismatch", "error"));
    }

    var hasConflicts = issues.Any(static issue => issue.Severity == "error");
    var changes = hasConflicts
        ? []
        : BuildAllChanges(
            current.Profile,
            MaterializeImportProfile(
                current,
                decoded,
                command.LevelAuthorityPolicy,
                command.Scopes));
    var diffJson = SerializeDiff(
        "sanitized_import_diff/v1",
        draft.DraftUid,
        draft.CanonicalPayloadSha256,
        command.TargetAccountUid,
        command.ExpectedProfileRevisionUid,
        command.LevelAuthorityPolicy,
        command.Scopes,
        changes);
    var existing = await _importStore.GetDiffAsync(command.OperationUid, cancellationToken)
        .ConfigureAwait(false);
    ProfileDraftDiffDocument diff;
    if (existing is null)
    {
      var created = await _importStore.CreateDiffAsync(
          new CreateProfileDraftDiffCommand(
              command.OperationUid,
              draft.DraftUid,
              command.TargetAccountUid,
              command.ExpectedProfileRevisionUid,
              new ProfileDraftDiffWrite(
                  ImportDiffContract,
                  diffJson,
                  changes.Count,
                  hasConflicts),
              Now()),
          cancellationToken).ConfigureAwait(false);
      diff = await _importStore.GetDiffAsync(created.DiffUid, cancellationToken)
          .ConfigureAwait(false) ??
          throw Failure(App.ProfileManagementFailureKind.Unavailable, "profile_diff_not_persisted");
    }
    else
    {
      diff = existing;
      EnsureDiffTopology(
          diff,
          draft,
          command.TargetAccountUid,
          command.ExpectedProfileRevisionUid);
      if (!string.Equals(diff.CanonicalDiffJson, diffJson, StringComparison.Ordinal) ||
          diff.HasConflicts != hasConflicts || diff.ChangeCount != changes.Count)
      {
        throw Failure(App.ProfileManagementFailureKind.Conflict, "profile_diff_operation_reuse_mismatch");
      }
    }

    return new App.ProfileDiffProjection(
        diff.CanonicalDiffSha256,
        command.TargetAccountUid,
        command.ExpectedProfileRevisionUid,
        draft.DraftUid,
        draft.CanonicalPayloadSha256,
        changes,
        issues);
  });

  public Task<App.ProfileWriteReceipt> ApplyImportAsync(
      App.ApplyImportCommand command,
      CancellationToken cancellationToken = default) => TranslateAsync(async () =>
  {
    ArgumentNullException.ThrowIfNull(command);
    ValidateImportPolicy(command.LevelAuthorityPolicy, command.Scopes);
    var draft = await RequireDraftAsync(
        command.DraftUid,
        command.ExpectedDraftSha256,
        cancellationToken).ConfigureAwait(false);
    var decoded = DecodeSanitizedDraft(draft);
    if (ReplacesBuilds(command.Scopes) && (!decoded.CanMaterializeLocalAccountProfile ||
        decoded.Builds.Any(build => !string.Equals(
            build.Level.AuthorityPolicyCode,
            command.LevelAuthorityPolicy,
            StringComparison.Ordinal))))
    {
      throw Failure(App.ProfileManagementFailureKind.Unprocessable, "level_authority_draft_mismatch");
    }
    var applicationKind = draft.DerivationKind == SanitizedProfileDraftDerivationKind.Rebase
        ? ProfileDraftApplicationKind.Rebase
        : ProfileDraftApplicationKind.Apply;
    var resolution = await ResolveWriteDiffAsync(
        command.OperationUid,
        applicationKind,
        draft.DraftUid,
        command.TargetAccountUid,
        command.ExpectedProfileRevisionUid,
        command.ExpectedDiffSha256,
        ImportDiffContract,
        cancellationToken).ConfigureAwait(false);
    if (resolution.Recovered is not null)
    {
      return resolution.Recovered;
    }


    var diff = resolution.Diff;

    var current = await RequireCurrentAsync(
        command.TargetAccountUid,
        command.ExpectedProfileRevisionUid,
        cancellationToken).ConfigureAwait(false);
    var candidate = MaterializeImportProfile(
        current,
        decoded,
        command.LevelAuthorityPolicy,
        command.Scopes,
        draft.DerivationKind == SanitizedProfileDraftDerivationKind.Rebase
            ? LocalProfileRevisionOrigin.Rebase
            : LocalProfileRevisionOrigin.OfflineSanitizedImport);
    var changes = BuildAllChanges(current.Profile, candidate);
    var expectedDiffJson = SerializeDiff(
        "sanitized_import_diff/v1",
        draft.DraftUid,
        draft.CanonicalPayloadSha256,
        command.TargetAccountUid,
        command.ExpectedProfileRevisionUid,
        command.LevelAuthorityPolicy,
        command.Scopes,
        changes);
    if (!string.Equals(diff.ContractVersion, ImportDiffContract, StringComparison.Ordinal) ||
        !string.Equals(diff.CanonicalDiffJson, expectedDiffJson, StringComparison.Ordinal) ||
        diff.ChangeCount != changes.Count)
    {
      throw Failure(App.ProfileManagementFailureKind.Conflict, "profile_diff_content_conflict");
    }

    var prepared = await BeginOrAdoptApplicationAsync(
        command.OperationUid,
        applicationKind,
        diff,
        draft.DraftUid,
        command.TargetAccountUid,
        command.ExpectedProfileRevisionUid,
        command.ExpectedDiffSha256,
        ImportDiffContract,
        expectedDiffJson,
        changes.Count,
        cancellationToken).ConfigureAwait(false);
    var application = prepared.Application;
    var receipt = await _profileStore.SaveAsync(
        new SaveLocalAccountProfileCommand(
            command.OperationUid,
            command.TargetAccountUid,
            command.ExpectedProfileRevisionUid,
            candidate,
            prepared.Diff.CreatedAtUtc),
        cancellationToken).ConfigureAwait(false);
    await _importStore.LinkApplicationAsync(application, cancellationToken).ConfigureAwait(false);
    return MapWriteReceipt(command.OperationUid, receipt);
  });

  public Task<App.CreateImportDiffProjection> PreviewCreateFromImportAsync(
      App.CreateImportDiffCommand command,
      CancellationToken cancellationToken = default) => TranslateAsync(async () =>
  {
    ArgumentNullException.ThrowIfNull(command);
    ValidateCreateImportPolicy(command.LevelAuthorityPolicy, command.Scopes);
    var draft = await RequireDraftAsync(
        command.DraftUid,
        command.ExpectedDraftSha256,
        cancellationToken).ConfigureAwait(false);
    var decoded = DecodeSanitizedDraft(draft);
    var issues = new List<App.ProfileIssueProjection>();
    if (!decoded.CanMaterializeLocalAccountProfile ||
        decoded.Builds.Any(build => !string.Equals(
            build.Level.AuthorityPolicyCode,
            command.LevelAuthorityPolicy,
            StringComparison.Ordinal)))
    {
      issues.Add(new App.ProfileIssueProjection("level_authority_draft_mismatch", "error"));
    }

    var hasConflicts = issues.Count != 0;
    var changes = hasConflicts
        ? []
        : BuildCreateChanges(MaterializeNewImportProfile(
            decoded,
            command.LevelAuthorityPolicy));
    var diffJson = SerializeCreateImportDiff(
        draft.DraftUid,
        draft.CanonicalPayloadSha256,
        command.LevelAuthorityPolicy,
        command.Scopes,
        changes);
    var existing = await _importStore.GetDiffAsync(command.OperationUid, cancellationToken)
        .ConfigureAwait(false);
    ProfileDraftDiffDocument diff;
    if (existing is null)
    {
      var created = await _importStore.CreateImportDiffAsync(
          new CreateImportProfileDraftDiffCommand(
              command.OperationUid,
              draft.DraftUid,
              new ProfileDraftDiffWrite(
                  CreateImportDiffContract,
                  diffJson,
                  changes.Count,
                  hasConflicts),
              Now()),
          cancellationToken).ConfigureAwait(false);
      diff = await _importStore.GetDiffAsync(created.DiffUid, cancellationToken)
          .ConfigureAwait(false) ??
          throw Failure(App.ProfileManagementFailureKind.Unavailable, "profile_diff_not_persisted");
    }
    else
    {
      diff = existing;
      EnsureCreateDiffTopology(diff, draft.DraftUid);
      if (!string.Equals(diff.CanonicalDiffJson, diffJson, StringComparison.Ordinal) ||
          diff.HasConflicts != hasConflicts || diff.ChangeCount != changes.Count)
      {
        throw Failure(App.ProfileManagementFailureKind.Conflict, "profile_diff_operation_reuse_mismatch");
      }
    }

    return new App.CreateImportDiffProjection(
        diff.CanonicalDiffSha256,
        draft.DraftUid,
        draft.CanonicalPayloadSha256,
        changes,
        issues);
  });

  public Task<App.ProfileWriteReceipt> CreateFromImportAsync(
      App.CreateFromImportCommand command,
      CancellationToken cancellationToken = default) => TranslateAsync(async () =>
  {
    ArgumentNullException.ThrowIfNull(command);
    ValidateCreateImportPolicy(command.LevelAuthorityPolicy, command.Scopes);
    var draft = await RequireDraftAsync(
        command.DraftUid,
        command.ExpectedDraftSha256,
        cancellationToken).ConfigureAwait(false);
    var decoded = DecodeSanitizedDraft(draft);
    if (!decoded.CanMaterializeLocalAccountProfile ||
        decoded.Builds.Any(build => !string.Equals(
            build.Level.AuthorityPolicyCode,
            command.LevelAuthorityPolicy,
            StringComparison.Ordinal)))
    {
      throw Failure(App.ProfileManagementFailureKind.Unprocessable, "level_authority_draft_mismatch");
    }

    var resolution = await ResolveWriteDiffAsync(
        command.OperationUid,
        ProfileDraftApplicationKind.Create,
        draft.DraftUid,
        accountUid: null,
        baseRevisionUid: null,
        expectedDiffSha256: command.ExpectedDiffSha256,
        expectedContractVersion: CreateImportDiffContract,
        cancellationToken).ConfigureAwait(false);
    if (resolution.Recovered is not null)
    {
      return resolution.Recovered;
    }


    var diff = resolution.Diff;

    var candidate = MaterializeNewImportProfile(
        decoded,
        command.LevelAuthorityPolicy,
        draft.DerivationKind == SanitizedProfileDraftDerivationKind.Rebase
            ? LocalProfileRevisionOrigin.Rebase
            : LocalProfileRevisionOrigin.OfflineSanitizedImport);
    var changes = BuildCreateChanges(candidate);
    var expectedDiffJson = SerializeCreateImportDiff(
        draft.DraftUid,
        draft.CanonicalPayloadSha256,
        command.LevelAuthorityPolicy,
        command.Scopes,
        changes);
    if (!string.Equals(diff.ContractVersion, CreateImportDiffContract, StringComparison.Ordinal) ||
        !string.Equals(diff.CanonicalDiffJson, expectedDiffJson, StringComparison.Ordinal) ||
        diff.ChangeCount != changes.Count)
    {
      throw Failure(App.ProfileManagementFailureKind.Conflict, "profile_diff_content_conflict");
    }

    var prepared = await BeginOrAdoptApplicationAsync(
        command.OperationUid,
        ProfileDraftApplicationKind.Create,
        diff,
        draft.DraftUid,
        accountUid: null,
        baseRevisionUid: null,
        expectedDiffSha256: command.ExpectedDiffSha256,
        expectedContractVersion: CreateImportDiffContract,
        expectedCanonicalJson: expectedDiffJson,
        expectedChangeCount: changes.Count,
        cancellationToken).ConfigureAwait(false);
    var application = prepared.Application;
    var receipt = await _profileStore.CreateAsync(
        new CreateLocalAccountProfileCommand(
            command.OperationUid,
            candidate,
            prepared.Diff.CreatedAtUtc),
        cancellationToken).ConfigureAwait(false);
    await _importStore.LinkApplicationAsync(application, cancellationToken).ConfigureAwait(false);
    return MapWriteReceipt(command.OperationUid, receipt);
  });

  public Task<App.RebasePreviewProjection> PreviewRebaseAsync(
      App.RebaseImportCommand command,
      CancellationToken cancellationToken = default) => TranslateAsync(async () =>
  {
    ArgumentNullException.ThrowIfNull(command);
    var draft = await RequireDraftAsync(
        command.DraftUid,
        command.ExpectedDraftSha256,
        cancellationToken).ConfigureAwait(false);
    var decoded = DecodeSanitizedDraft(draft);
    ValidateRebaseMappings(decoded, command.ExplicitMappings);
    var previewRebase = RebaseSanitizedDraft(decoded, command, Now());
    await RequireCatalogResolverFactory().ValidateRebaseAsync(
        decoded,
        previewRebase,
        command.ExplicitMappings,
        cancellationToken).ConfigureAwait(false);
    var diffHash = ComputeRebaseDiff(command);
    return new App.RebasePreviewProjection(
        draft.DraftUid,
        draft.CanonicalPayloadSha256,
        diffHash,
        command.TargetCharacterCatalog,
        command.TargetCombatSupportCatalog,
        RebaseChanges(command.ExplicitMappings),
        []);
  });

  public Task<App.SourceFreeImportDraftProjection> RebaseImportAsync(
      App.RebaseImportCommand command,
      CancellationToken cancellationToken = default) => TranslateAsync(async () =>
  {
    ArgumentNullException.ThrowIfNull(command);
    var source = await RequireDraftAsync(
        command.DraftUid,
        command.ExpectedDraftSha256,
        cancellationToken).ConfigureAwait(false);
    var expected = command.ExpectedDiffSha256 ??
        throw Failure(App.ProfileManagementFailureKind.InvalidRequest, "expected_diff_sha256_missing");
    if (ComputeRebaseDiff(command) != expected)
    {
      throw Failure(App.ProfileManagementFailureKind.Conflict, "import_rebase_diff_conflict");
    }

    var existing = await _importStore.GetDraftByOperationAsync(
        command.OperationUid,
        cancellationToken).ConfigureAwait(false);
    var sourceDraft = DecodeSanitizedDraft(source);
    ValidateRebaseMappings(sourceDraft, command.ExplicitMappings);
    var materializedAt = existing?.CreatedAtUtc ?? Now();
    var rebasedDraft = RebaseSanitizedDraft(sourceDraft, command, materializedAt);
    await RequireCatalogResolverFactory().ValidateRebaseAsync(
        sourceDraft,
        rebasedDraft,
        command.ExplicitMappings,
        cancellationToken).ConfigureAwait(false);
    var rebasedJson = System.Text.Encoding.UTF8.GetString(
        ImportProfile.SanitizedProfileDraftJsonCodec.Encode(rebasedDraft));
    SanitizedProfileDraftDocument rebased;
    if (existing is null)
    {
      var imported = await _importStore.ImportDraftAsync(
          new ImportSanitizedProfileDraftCommand(
              command.OperationUid,
              new SanitizedProfileDraftWrite(
                  SanitizedProfileDraftDerivationKind.Rebase,
                  source.DraftUid,
                  rebasedDraft.Provenance.SourceSchemaSha256,
                  rebasedDraft.Provenance.TransformerBinarySha256,
                  rebasedDraft.Provenance.SemanticOptionsSha256,
                  MapBinding(command.TargetCharacterCatalog),
                  MapBinding(command.TargetCombatSupportCatalog),
                  rebasedJson),
              materializedAt),
          cancellationToken).ConfigureAwait(false);
      rebased = await _importStore.GetDraftAsync(imported.DraftUid, cancellationToken)
          .ConfigureAwait(false) ??
          throw Failure(App.ProfileManagementFailureKind.Unavailable, "profile_rebase_not_persisted");
    }
    else
    {
      rebased = existing;
      if (rebased.PreviousDraftUid != source.DraftUid ||
          !BindingEquals(rebased.CharacterCatalog, rebasedDraft.CharacterCatalog) ||
          !BindingEquals(rebased.CombatSupportCatalog, rebasedDraft.CombatSupportCatalog) ||
          !string.Equals(rebased.CanonicalPayloadJson, rebasedJson, StringComparison.Ordinal))
      {
        throw Failure(App.ProfileManagementFailureKind.Conflict, "profile_rebase_operation_reuse_mismatch");
      }
    }

    return ProjectDraft(rebased);
  });

  public Task<App.ReviewImportDraftPreviewProjection> PreviewReviewImportDraftAsync(
      App.ReviewImportDraftCommand command,
      CancellationToken cancellationToken = default) => TranslateAsync(async () =>
  {
    ArgumentNullException.ThrowIfNull(command);
    var source = await RequireDraftAsync(
        command.DraftUid,
        command.ExpectedDraftSha256,
        cancellationToken).ConfigureAwait(false);
    var sourceDraft = DecodeSanitizedDraft(source);
    var requests = MapReviewedOverrideRequests(command.Overrides);
    var reviewedDraft = ApplyReviewedOverrides(sourceDraft, requests, Now());
    return new App.ReviewImportDraftPreviewProjection(
        source.DraftUid,
        source.CanonicalPayloadSha256,
        ComputeReviewedOverrideDiff(command),
        ReviewedOverrideChanges(sourceDraft, reviewedDraft, requests),
        []);
  });

  public Task<App.SourceFreeImportDraftProjection> ReviewImportDraftAsync(
      App.ReviewImportDraftCommand command,
      CancellationToken cancellationToken = default) => TranslateAsync(async () =>
  {
    ArgumentNullException.ThrowIfNull(command);
    var source = await RequireDraftAsync(
        command.DraftUid,
        command.ExpectedDraftSha256,
        cancellationToken).ConfigureAwait(false);
    var requests = MapReviewedOverrideRequests(command.Overrides);
    var expected = command.ExpectedDiffSha256 ??
        throw Failure(App.ProfileManagementFailureKind.InvalidRequest, "expected_diff_sha256_missing");
    if (ComputeReviewedOverrideDiff(command) != expected)
    {
      throw Failure(App.ProfileManagementFailureKind.Conflict, "import_review_diff_conflict");
    }

    var existing = await _importStore.GetDraftByOperationAsync(
        command.OperationUid,
        cancellationToken).ConfigureAwait(false);
    var sourceDraft = DecodeSanitizedDraft(source);
    var materializedAt = existing?.CreatedAtUtc ?? Now();
    var reviewedDraft = ApplyReviewedOverrides(sourceDraft, requests, materializedAt);
    var reviewedJson = System.Text.Encoding.UTF8.GetString(
        ImportProfile.SanitizedProfileDraftJsonCodec.Encode(reviewedDraft));
    SanitizedProfileDraftDocument reviewed;
    if (existing is null)
    {
      var imported = await _importStore.ImportDraftAsync(
          new ImportSanitizedProfileDraftCommand(
              command.OperationUid,
              new SanitizedProfileDraftWrite(
                  SanitizedProfileDraftDerivationKind.ReviewedOverride,
                  source.DraftUid,
                  reviewedDraft.Provenance.SourceSchemaSha256,
                  reviewedDraft.Provenance.TransformerBinarySha256,
                  reviewedDraft.Provenance.SemanticOptionsSha256,
                  source.CharacterCatalog,
                  source.CombatSupportCatalog,
                  reviewedJson),
              materializedAt),
          cancellationToken).ConfigureAwait(false);
      reviewed = await _importStore.GetDraftAsync(imported.DraftUid, cancellationToken)
          .ConfigureAwait(false) ??
          throw Failure(App.ProfileManagementFailureKind.Unavailable, "profile_review_not_persisted");
    }
    else
    {
      reviewed = existing;
      if (reviewed.DerivationKind != SanitizedProfileDraftDerivationKind.ReviewedOverride ||
          reviewed.PreviousDraftUid != source.DraftUid ||
          !BindingEquals(reviewed.CharacterCatalog, reviewedDraft.CharacterCatalog) ||
          !BindingEquals(reviewed.CombatSupportCatalog, reviewedDraft.CombatSupportCatalog) ||
          !string.Equals(reviewed.CanonicalPayloadJson, reviewedJson, StringComparison.Ordinal))
      {
        throw Failure(App.ProfileManagementFailureKind.Conflict, "profile_review_operation_reuse_mismatch");
      }
    }

    return ProjectDraft(reviewed);
  });

  public Task<App.LobbyPresentationProjection?> GetLobbyPresentationAsync(
      EntityUid accountUid,
      CancellationToken cancellationToken = default) => TranslateAsync(async () =>
  {
    var lobby = await _gameStateStore.GetLobbyPresentationHeadAsync(accountUid, cancellationToken)
        .ConfigureAwait(false);
    return lobby is null ? null : MapLobby(accountUid, lobby);
  });

  public Task<App.LobbyPresentationProjection> SaveLobbyPresentationAsync(
      App.SaveLobbyPresentationCommand command,
      CancellationToken cancellationToken = default) => TranslateAsync(async () =>
  {
    ArgumentNullException.ThrowIfNull(command);
    var lobby = new LocalLobbyPresentationWrite(
        command.DisplayName,
        LocalGameIntFact.Ready(command.CommanderLevel),
        UidFact(command.LobbyCharacterSelectionUid),
        UidFact(command.ProfileIconSelectionUid),
        UidFact(command.ProfileFrameSelectionUid),
        UidFact(command.LobbyBackgroundSelectionUid));
    var replay = await _gameStateStore.TryReplayLobbyPresentationAsync(
        command.OperationUid,
        command.AccountUid,
        command.ExpectedRevisionUid,
        lobby,
        cancellationToken).ConfigureAwait(false);
    if (replay is not null)
    {
      return MapLobby(command.AccountUid, replay);
    }

    var current = await _profileStore.GetCurrentAsync(command.AccountUid, cancellationToken)
        .ConfigureAwait(false) ??
        throw Failure(App.ProfileManagementFailureKind.NotFound, "account_not_found");
    LocalLobbyPresentationReceipt receipt;
    try
    {
      receipt = await _gameStateStore.SaveLobbyPresentationAsync(
          new global::NikkeLocalLab.Persistence.PostgreSql.SaveLobbyPresentationCommand(
              command.OperationUid,
              command.AccountUid,
              command.ExpectedRevisionUid,
              current.Revision.ProfileTemplateRevisionUid,
              lobby,
              Now()),
          cancellationToken).ConfigureAwait(false);
    }
    catch (LocalGameStateIntegrityException exception)
        when (exception.Code == "local_game_operation_reuse_mismatch")
    {
      var racedReplay = await _gameStateStore.TryReplayLobbyPresentationAsync(
          command.OperationUid,
          command.AccountUid,
          command.ExpectedRevisionUid,
          lobby,
          cancellationToken).ConfigureAwait(false);
      if (racedReplay is null)
      {
        throw;
      }

      receipt = racedReplay;
    }

    return MapLobby(command.AccountUid, receipt);
  });

  public Task<App.WalletProjection?> GetWalletAsync(
      EntityUid accountUid,
      CancellationToken cancellationToken = default) => TranslateAsync(async () =>
  {
    var wallet = await _gameStateStore.GetWalletHeadAsync(accountUid, cancellationToken)
        .ConfigureAwait(false);
    return wallet is null ? null : MapWallet(accountUid, wallet);
  });

  public Task<App.WalletProjection> SaveWalletAsync(
      App.SaveWalletCommand command,
      CancellationToken cancellationToken = default) => TranslateAsync(async () =>
  {
    ArgumentNullException.ThrowIfNull(command);
    var balances = command.Balances?.OrderBy(static item => item.CurrencyCode, StringComparer.Ordinal)
        .ToArray() ?? [];
    balances = RequireWalletBalances(balances);

    var wallet = new LocalWalletWrite(balances.Select(static item => new LocalWalletBalance(
        item.CurrencyCode == "credit" ? LocalWalletCurrency.Credit : LocalWalletCurrency.Jewel,
        item.Balance)));
    var receipt = await _gameStateStore.SaveWalletAsync(
        new global::NikkeLocalLab.Persistence.PostgreSql.SaveWalletCommand(
            command.OperationUid,
            command.AccountUid,
            command.ExpectedRevisionUid,
            wallet,
            Now()),
        cancellationToken).ConfigureAwait(false);
    return MapWallet(command.AccountUid, receipt);
  });

  public Task<App.ClientFeatureManifestProjection> GetFeatureManifestAsync(
      CancellationToken cancellationToken = default) => TranslateAsync(async () =>
  {
    var receipt = await _gameStateStore.GetLatestFeatureManifestAsync(cancellationToken)
        .ConfigureAwait(false) ??
        throw Failure(App.ProfileManagementFailureKind.NotFound, "client_feature_manifest_not_found");
    return MapFeatureManifest(receipt);
  });

  private async Task<LocalCurrentAccountProfile> RequireCurrentAsync(
      EntityUid accountUid,
      EntityUid expectedRevisionUid,
      CancellationToken cancellationToken)
  {
    var current = await _profileStore.GetCurrentAsync(accountUid, cancellationToken)
        .ConfigureAwait(false) ??
        throw Failure(App.ProfileManagementFailureKind.NotFound, "account_not_found");
    if (current.Revision.ProfileTemplateRevisionUid != expectedRevisionUid)
    {
      throw Failure(App.ProfileManagementFailureKind.Conflict, "profile_revision_conflict");
    }

    return current;
  }

  private async Task<App.AccountBootstrapProjection> RequireCurrentBootstrapAsync(
      EntityUid accountUid,
      CancellationToken cancellationToken) =>
      await GetCurrentBootstrapAsync(accountUid, cancellationToken).ConfigureAwait(false) ??
      throw Failure(App.ProfileManagementFailureKind.Unavailable, "local_state_not_persisted");

  private async Task<SanitizedProfileDraftDocument> RequireDraftAsync(
      EntityUid draftUid,
      Sha256Digest expectedSha256,
      CancellationToken cancellationToken)
  {
    var draft = await _importStore.GetDraftAsync(draftUid, cancellationToken)
        .ConfigureAwait(false) ??
        throw Failure(App.ProfileManagementFailureKind.NotFound, "import_draft_not_found");
    if (draft.CanonicalPayloadSha256 != expectedSha256)
    {
      throw Failure(App.ProfileManagementFailureKind.Conflict, "import_draft_hash_conflict");
    }

    return draft;
  }

  private async Task<ProfileEditCandidateDocument> RequireEditCandidateAsync(
      EntityUid candidateUid,
      Sha256Digest expectedSha256,
      CancellationToken cancellationToken)
  {
    var candidate = await _importStore.GetProfileEditCandidateAsync(candidateUid, cancellationToken)
        .ConfigureAwait(false) ??
        throw Failure(App.ProfileManagementFailureKind.NotFound, "profile_edit_candidate_not_found");
    if (candidate.CanonicalOperationsSha256 != expectedSha256 ||
        candidate.ContractVersion != "nll/profile-edit-candidate/v1")
    {
      throw Failure(App.ProfileManagementFailureKind.Conflict, "profile_edit_candidate_hash_conflict");
    }

    return candidate;
  }

  private async Task<ProfileDraftDiffDocument> RequireDiffAsync(
      EntityUid candidateUid,
      EntityUid accountUid,
      EntityUid baseRevisionUid,
      Sha256Digest diffSha256,
      CancellationToken cancellationToken)
  {
    var diff = await _importStore.FindDiffAsync(
        candidateUid,
        accountUid,
        baseRevisionUid,
        diffSha256,
        cancellationToken).ConfigureAwait(false) ??
        throw Failure(App.ProfileManagementFailureKind.Conflict, "profile_diff_not_found");
    if (diff.HasConflicts)
    {
      throw Failure(App.ProfileManagementFailureKind.Unprocessable, "profile_diff_has_conflicts");
    }

    return diff;
  }

  private async Task<ProfileDraftDiffDocument> RequireCreateDiffAsync(
      EntityUid draftUid,
      Sha256Digest diffSha256,
      CancellationToken cancellationToken)
  {
    var diff = await _importStore.FindCreateDiffAsync(
        draftUid,
        diffSha256,
        cancellationToken).ConfigureAwait(false) ??
        throw Failure(App.ProfileManagementFailureKind.Conflict, "profile_diff_not_found");
    EnsureCreateDiffTopology(diff, draftUid);
    if (diff.HasConflicts)
    {
      throw Failure(App.ProfileManagementFailureKind.Unprocessable, "profile_diff_has_conflicts");
    }

    return diff;
  }

  private async Task<WriteDiffResolution> ResolveWriteDiffAsync(
      EntityUid operationUid,
      ProfileDraftApplicationKind applicationKind,
      EntityUid draftUid,
      EntityUid? accountUid,
      EntityUid? baseRevisionUid,
      Sha256Digest expectedDiffSha256,
      string expectedContractVersion,
      CancellationToken cancellationToken)
  {
    var intent = await _importStore.GetApplicationIntentAsync(
        operationUid,
        cancellationToken).ConfigureAwait(false);
    if (intent is null)
    {
      var selected = accountUid is null && baseRevisionUid is null
          ? await RequireCreateDiffAsync(
              draftUid,
              expectedDiffSha256,
              cancellationToken).ConfigureAwait(false)
          : await RequireDiffAsync(
              draftUid,
              accountUid ?? throw Failure(
                  App.ProfileManagementFailureKind.InvalidRequest,
                  "profile_diff_topology_conflict"),
              baseRevisionUid ?? throw Failure(
                  App.ProfileManagementFailureKind.InvalidRequest,
                  "profile_diff_topology_conflict"),
              expectedDiffSha256,
              cancellationToken).ConfigureAwait(false);
      EnsureSelectedWriteDiff(
          selected,
          draftUid,
          accountUid,
          baseRevisionUid,
          expectedDiffSha256,
          expectedContractVersion);
      return new WriteDiffResolution(selected, null);
    }

    EnsureApplicationIntent(intent, operationUid, applicationKind);
    var diff = await RequireApplicationIntentDiffAsync(
        intent,
        draftUid,
        accountUid,
        baseRevisionUid,
        expectedDiffSha256,
        expectedContractVersion,
        cancellationToken).ConfigureAwait(false);
    var recovered = await TryRecoverWriteAsync(
        operationUid,
        applicationKind,
        diff.DiffUid,
        cancellationToken).ConfigureAwait(false);
    return new WriteDiffResolution(diff, recovered);
  }

  private async Task<ApplicationPreparation> BeginOrAdoptApplicationAsync(
      EntityUid operationUid,
      ProfileDraftApplicationKind applicationKind,
      ProfileDraftDiffDocument selectedDiff,
      EntityUid draftUid,
      EntityUid? accountUid,
      EntityUid? baseRevisionUid,
      Sha256Digest expectedDiffSha256,
      string expectedContractVersion,
      string expectedCanonicalJson,
      int expectedChangeCount,
      CancellationToken cancellationToken)
  {
    var command = new LinkProfileDraftApplicationCommand(
        operationUid,
        applicationKind,
        selectedDiff.DiffUid,
        operationUid,
        selectedDiff.CreatedAtUtc);
    ProfileDraftApplicationIntentReceipt intent;
    try
    {
      intent = await _importStore.BeginApplicationAsync(command, cancellationToken)
          .ConfigureAwait(false);
    }
    catch (LocalGameStateIntegrityException exception)
        when (exception.Code == "profile_draft_application_intent_reuse_mismatch")
    {
      var existingIntent = await _importStore.GetApplicationIntentAsync(
          operationUid,
          cancellationToken)
          .ConfigureAwait(false);
      if (existingIntent is null)
      {
        throw;
      }

      intent = existingIntent;
      EnsureApplicationIntent(intent, operationUid, applicationKind);
    }

    var actualDiff = intent.DiffUid == selectedDiff.DiffUid
        ? selectedDiff
        : await RequireApplicationIntentDiffAsync(
            intent,
            draftUid,
            accountUid,
            baseRevisionUid,
            expectedDiffSha256,
            expectedContractVersion,
            cancellationToken).ConfigureAwait(false);
    EnsureSelectedWriteDiff(
        actualDiff,
        draftUid,
        accountUid,
        baseRevisionUid,
        expectedDiffSha256,
        expectedContractVersion);
    if (!string.Equals(
            actualDiff.CanonicalDiffJson,
            expectedCanonicalJson,
            StringComparison.Ordinal) ||
        actualDiff.ChangeCount != expectedChangeCount)
    {
      throw Failure(
          App.ProfileManagementFailureKind.Conflict,
          "profile_diff_content_conflict");
    }

    var canonical = new LinkProfileDraftApplicationCommand(
        operationUid,
        applicationKind,
        actualDiff.DiffUid,
        operationUid,
        intent.RequestedAtUtc);
    if (canonical.RequestSha256 == command.RequestSha256)
    {
      return new ApplicationPreparation(canonical, actualDiff);
    }

    await _importStore.BeginApplicationAsync(canonical, cancellationToken).ConfigureAwait(false);
    return new ApplicationPreparation(canonical, actualDiff);
  }

  private async Task<ProfileDraftDiffDocument> RequireApplicationIntentDiffAsync(
      ProfileDraftApplicationIntentReceipt intent,
      EntityUid draftUid,
      EntityUid? accountUid,
      EntityUid? baseRevisionUid,
      Sha256Digest expectedDiffSha256,
      string expectedContractVersion,
      CancellationToken cancellationToken)
  {
    var diff = await _importStore.GetDiffAsync(intent.DiffUid, cancellationToken)
        .ConfigureAwait(false) ??
        throw Failure(App.ProfileManagementFailureKind.Unavailable, "profile_diff_not_persisted");
    EnsureSelectedWriteDiff(
        diff,
        draftUid,
        accountUid,
        baseRevisionUid,
        expectedDiffSha256,
        expectedContractVersion);
    return diff;
  }

  private static void EnsureApplicationIntent(
      ProfileDraftApplicationIntentReceipt intent,
      EntityUid operationUid,
      ProfileDraftApplicationKind applicationKind)
  {
    if (intent.ApplicationUid != operationUid ||
        intent.ProfileWriteOperationUid != operationUid ||
        intent.ApplicationKind != applicationKind)
    {
      throw Failure(
          App.ProfileManagementFailureKind.Conflict,
          "profile_draft_application_intent_reuse_mismatch");
    }
  }

  private static void EnsureSelectedWriteDiff(
      ProfileDraftDiffDocument diff,
      EntityUid draftUid,
      EntityUid? accountUid,
      EntityUid? baseRevisionUid,
      Sha256Digest expectedDiffSha256,
      string expectedContractVersion)
  {
    if (diff.DraftUid != draftUid || diff.AccountUid != accountUid ||
        diff.BaseProfileTemplateRevisionUid != baseRevisionUid ||
        diff.CanonicalDiffSha256 != expectedDiffSha256 ||
        !string.Equals(diff.ContractVersion, expectedContractVersion, StringComparison.Ordinal))
    {
      throw Failure(App.ProfileManagementFailureKind.Conflict, "profile_diff_topology_conflict");
    }

    if (diff.HasConflicts)
    {
      throw Failure(App.ProfileManagementFailureKind.Unprocessable, "profile_diff_has_conflicts");
    }
  }

  private async Task<App.ProfileWriteReceipt?> TryRecoverWriteAsync(
      EntityUid operationUid,
      ProfileDraftApplicationKind applicationKind,
      EntityUid diffUid,
      CancellationToken cancellationToken)
  {
    var application = await _importStore.TryRecoverApplicationAsync(
        operationUid,
        applicationKind,
        diffUid,
        operationUid,
        cancellationToken).ConfigureAwait(false);
    if (application is null)
    {
      return null;
    }

    var receipt = await _profileStore.GetByOperationAsync(operationUid, cancellationToken)
        .ConfigureAwait(false) ??
        throw Failure(App.ProfileManagementFailureKind.Unavailable, "profile_write_recovery_missing");
    if (receipt.AccountUid != application.ResultAccountUid ||
        receipt.ProfileTemplateRevisionUid != application.ResultProfileTemplateRevisionUid)
    {
      throw Failure(App.ProfileManagementFailureKind.Conflict, "profile_write_recovery_mismatch");
    }

    return MapWriteReceipt(operationUid, receipt);
  }

  private static void EnsureDiffTopology(
      ProfileDraftDiffDocument diff,
      SanitizedProfileDraftDocument draft,
      EntityUid accountUid,
      EntityUid baseRevisionUid) => EnsureDiffTopology(
          diff,
          draft.DraftUid,
          accountUid,
          baseRevisionUid);

  private static void EnsureDiffTopology(
      ProfileDraftDiffDocument diff,
      EntityUid candidateUid,
      EntityUid accountUid,
      EntityUid baseRevisionUid)
  {
    if (diff.DraftUid != candidateUid || diff.AccountUid != accountUid ||
        diff.BaseProfileTemplateRevisionUid != baseRevisionUid)
    {
      throw Failure(App.ProfileManagementFailureKind.Conflict, "profile_diff_topology_conflict");
    }
  }

  private static void EnsureCreateDiffTopology(
      ProfileDraftDiffDocument diff,
      EntityUid draftUid)
  {
    if (diff.DraftUid != draftUid || diff.AccountUid is not null ||
        diff.BaseProfileTemplateRevisionUid is not null)
    {
      throw Failure(App.ProfileManagementFailureKind.Conflict, "profile_diff_topology_conflict");
    }
  }

  private static void EnsureEditorDiff(
      ProfileDraftDiffDocument diff,
      string expectedCanonicalJson,
      int expectedChangeCount)
  {
    if (diff.ContractVersion != CandidateDiffContract || diff.HasConflicts ||
        diff.ChangeCount != expectedChangeCount ||
        !string.Equals(diff.CanonicalDiffJson, expectedCanonicalJson, StringComparison.Ordinal))
    {
      throw Failure(App.ProfileManagementFailureKind.Conflict, "profile_edit_diff_content_conflict");
    }
  }

  private static ImportProfile.SanitizedProfileDraft DecodeSanitizedDraft(
      SanitizedProfileDraftDocument document)
  {
    ImportProfile.SanitizedProfileDraft decoded;
    try
    {
      decoded = ImportProfile.SanitizedProfileDraftJsonCodec.Decode(
          System.Text.Encoding.UTF8.GetBytes(document.CanonicalPayloadJson));
    }
    catch (ImportProfile.SanitizedProfileDraftCodecException exception)
    {
      throw Failure(App.ProfileManagementFailureKind.Unprocessable, exception.Code);
    }

    if (!BindingEquals(document.CharacterCatalog, decoded.CharacterCatalog) ||
        !BindingEquals(document.CombatSupportCatalog, decoded.CombatSupportCatalog) ||
        document.SanitizerContractSha256 != decoded.Provenance.SourceSchemaSha256 ||
        document.TransformerSha256 != decoded.Provenance.TransformerBinarySha256 ||
        document.SemanticOptionsSha256 != decoded.Provenance.SemanticOptionsSha256 ||
        document.CreatedAtUtc != decoded.Provenance.ImportedAtUtc)
    {
      throw Failure(App.ProfileManagementFailureKind.Unprocessable, "sanitized_profile_storage_parity_invalid");
    }

    return decoded;
  }

  private static LocalAccountProfileWrite MaterializeImportProfile(
      LocalCurrentAccountProfile current,
      ImportProfile.SanitizedProfileDraft draft,
      string levelAuthorityPolicy,
      IReadOnlyList<string> scopes,
      LocalProfileRevisionOrigin origin = LocalProfileRevisionOrigin.OfflineSanitizedImport)
  {
    if (!BindingEquals(current.Profile.CharacterCatalog, draft.CharacterCatalog) ||
        !BindingEquals(current.Profile.CombatSupportCatalog, draft.CombatSupportCatalog))
    {
      throw Failure(App.ProfileManagementFailureKind.Conflict, "sanitized_profile_catalog_rebase_required");
    }

    var normalizedScopes = scopes.Distinct(StringComparer.Ordinal).ToHashSet(StringComparer.Ordinal);
    var replaceAccount = normalizedScopes.Contains("full_profile") ||
        normalizedScopes.Contains("account_state_only");
    var replaceBuilds = normalizedScopes.Contains("full_profile") ||
        normalizedScopes.Contains("builds_only");
    var builds = replaceBuilds
        ? draft.Builds.Select(build => MaterializeBuild(
            build,
            levelAuthorityPolicy,
            origin)).ToArray()
        : current.Profile.Builds;
    var buildUids = builds.Select(static item => item.CharacterUid).ToHashSet();
    var squad = current.Profile.SquadCharacterUids is not null &&
        current.Profile.SquadCharacterUids.All(buildUids.Contains)
          ? current.Profile.SquadCharacterUids
          : null;

    return new LocalAccountProfileWrite(
        current.Profile.CharacterCatalog,
        current.Profile.CombatSupportCatalog,
        replaceAccount ? MaterializeAccountState(draft.AccountState, origin) : current.Profile.AccountState,
        builds,
        squad,
        origin,
        origin);
  }

  private static LocalAccountProfileWrite MaterializeNewImportProfile(
      ImportProfile.SanitizedProfileDraft draft,
      string levelAuthorityPolicy,
      LocalProfileRevisionOrigin origin = LocalProfileRevisionOrigin.OfflineSanitizedImport) => new(
          new LocalProfileCatalogBindingWrite(
              draft.CharacterCatalog.CatalogSnapshotUid,
              draft.CharacterCatalog.DatasetSnapshotUid,
              draft.CharacterCatalog.ManifestSha256),
          new LocalProfileCatalogBindingWrite(
              draft.CombatSupportCatalog.CatalogSnapshotUid,
              draft.CombatSupportCatalog.DatasetSnapshotUid,
              draft.CombatSupportCatalog.ManifestSha256),
          MaterializeAccountState(draft.AccountState, origin),
          draft.Builds.Select(build => MaterializeBuild(build, levelAuthorityPolicy, origin)),
          squadCharacterUids: null,
          squadOrigin: origin,
          profileTemplateOrigin: origin);

  private static bool ReplacesBuilds(IReadOnlyList<string> scopes) =>
      scopes.Contains("full_profile", StringComparer.Ordinal) ||
      scopes.Contains("builds_only", StringComparer.Ordinal);

  private static LocalAccountCombatStateWrite MaterializeAccountState(
      ImportProfile.SanitizedAccountCombatStateDraft state,
      LocalProfileRevisionOrigin origin) => new(
          LocalProfileFact<int>.Ready(state.SynchroLevel),
          state.Consoles.Select(static console => new LocalConsoleStateWrite(
              MapConsole(console.Coordinate),
              console.DefinitionUid,
              LocalProfileFact<int>.Ready(console.Level),
              LocalProfileFact<long>.Ready(console.ObservedExperience))),
          LocalProfileValidationMode.GameLegal,
          origin);

  private static LocalCharacterBuildWrite MaterializeBuild(
      ImportProfile.SanitizedCharacterBuildDraft build,
      string levelAuthorityPolicy,
      LocalProfileRevisionOrigin origin = LocalProfileRevisionOrigin.OfflineSanitizedImport)
  {
    var characterLevel = levelAuthorityPolicy == RosterLevelAuthority
        ? build.Level.RosterLevel
        : build.Level.DetailLevel;
    return new LocalCharacterBuildWrite(
        build.CharacterUid,
        characterLevel,
        LocalProfileFact<int>.Ready(build.LimitBreak),
        LocalProfileFact<int>.Ready(build.CoreLevel),
        MapFact(build.ResolvedBondLevel),
        LocalProfileFact<int>.Ready(build.Skill1Level),
        LocalProfileFact<int>.Ready(build.Skill2Level),
        LocalProfileFact<int>.Ready(build.BurstLevel),
        build.Equipment.Select(MaterializeEquipment),
        MaterializeCube(build.Cube),
        MaterializeCollection(build.Collection),
        IsFullyResolvedImportBuild(build)
            ? LocalProfileValidationMode.GameLegal
            : LocalProfileValidationMode.Research,
        LocalProfileMaterializationPolicy.ExplicitV1,
        origin);
  }

  private static bool IsFullyResolvedImportBuild(
      ImportProfile.SanitizedCharacterBuildDraft build) =>
      build.ResolvedBondLevel.Status == ImportProfile.ProfileImportFactStatus.Ready &&
      build.Equipment.All(static equipment =>
          equipment.State == ImportProfile.ProfileImportAttachmentState.Unequipped ||
          equipment.ResolvedManufacturerMatched?.Status ==
              ImportProfile.ProfileImportFactStatus.Ready);

  private static LocalEquipmentWrite MaterializeEquipment(
      ImportProfile.SanitizedEquipmentSelection equipment)
  {
    if (equipment.State == ImportProfile.ProfileImportAttachmentState.Unequipped)
    {
      return new LocalEquipmentWrite(
          MapEquipmentSlot(equipment.Slot),
          LocalEquipmentState.Unequipped,
          manufacturerMatched: LocalProfileFact<bool>.NotApplicable());
    }

    return new LocalEquipmentWrite(
        slot: MapEquipmentSlot(equipment.Slot),
        state: LocalEquipmentState.Equipped,
        equipmentDefinitionUid: equipment.DefinitionUid,
        enhancementLevel: LocalProfileFact<int>.Ready(equipment.EnhancementLevel!.Value),
        manufacturerMatched: MapFact(equipment.ResolvedManufacturerMatched!),
        overloadLines: equipment.OverloadLines.Select(static line => new LocalOverloadLineWrite(
            line.LineIndex,
            line.OptionDefinitionUid,
            MapValueUnit(line.Unit),
            new LocalProfileExactValue(
                line.ExactValue.UnscaledValue,
                line.ExactValue.DecimalScale))));
  }

  private static LocalCubeSelectionWrite MaterializeCube(
      ImportProfile.SanitizedCubeSelection cube) =>
      cube.State == ImportProfile.ProfileImportAttachmentState.Unequipped
          ? new LocalCubeSelectionWrite(LocalOptionalSelectionState.Unequipped)
          : new LocalCubeSelectionWrite(
              LocalOptionalSelectionState.Equipped,
              cube.DefinitionUid,
              LocalProfileFact<int>.Ready(cube.Level!.Value));

  private static LocalCollectionSelectionWrite MaterializeCollection(
      ImportProfile.SanitizedCollectionSelection collection) => collection.Kind switch
      {
        ImportProfile.ProfileImportCollectionKind.Detached =>
            new LocalCollectionSelectionWrite(LocalCollectionSelectionKind.Detached),
        ImportProfile.ProfileImportCollectionKind.GenericCollection =>
            new LocalCollectionSelectionWrite(
                LocalCollectionSelectionKind.GenericCollection,
                collection.DefinitionUid,
                LocalProfileFact<int>.Ready(collection.Level!.Value)),
        ImportProfile.ProfileImportCollectionKind.Favorite =>
            new LocalCollectionSelectionWrite(
                LocalCollectionSelectionKind.Favorite,
                collection.DefinitionUid,
                LocalProfileFact<int>.Ready(collection.Level!.Value)),
        _ => throw Failure(App.ProfileManagementFailureKind.Unprocessable, "sanitized_profile_collection_invalid")
      };

  private static LocalProfileFact<T> MapFact<T>(ImportProfile.ProfileImportFact<T> fact)
      where T : struct => fact.Status switch
      {
        ImportProfile.ProfileImportFactStatus.Ready => LocalProfileFact<T>.Ready(fact.Value!.Value),
        ImportProfile.ProfileImportFactStatus.Unresolved => LocalProfileFact<T>.Unresolved(
            new LocalProfileReasonCode(fact.ReasonCode!)),
        _ => throw Failure(App.ProfileManagementFailureKind.Unprocessable, "sanitized_profile_fact_invalid")
      };

  private static LocalEquipmentSlot MapEquipmentSlot(
      ImportProfile.ProfileImportEquipmentSlot value) => value switch
      {
        ImportProfile.ProfileImportEquipmentSlot.Head => LocalEquipmentSlot.Head,
        ImportProfile.ProfileImportEquipmentSlot.Torso => LocalEquipmentSlot.Torso,
        ImportProfile.ProfileImportEquipmentSlot.Arms => LocalEquipmentSlot.Arms,
        ImportProfile.ProfileImportEquipmentSlot.Legs => LocalEquipmentSlot.Legs,
        _ => throw Failure(App.ProfileManagementFailureKind.Unprocessable, "sanitized_profile_equipment_slot_invalid")
      };

  private static LocalConsoleCoordinate MapConsole(
      ImportProfile.ProfileImportConsoleCoordinate value) => value switch
      {
        ImportProfile.ProfileImportConsoleCoordinate.Common => LocalConsoleCoordinate.Common,
        ImportProfile.ProfileImportConsoleCoordinate.Attacker => LocalConsoleCoordinate.Attacker,
        ImportProfile.ProfileImportConsoleCoordinate.Defender => LocalConsoleCoordinate.Defender,
        ImportProfile.ProfileImportConsoleCoordinate.Supporter => LocalConsoleCoordinate.Supporter,
        ImportProfile.ProfileImportConsoleCoordinate.Elysion => LocalConsoleCoordinate.Elysion,
        ImportProfile.ProfileImportConsoleCoordinate.Missilis => LocalConsoleCoordinate.Missilis,
        ImportProfile.ProfileImportConsoleCoordinate.Tetra => LocalConsoleCoordinate.Tetra,
        ImportProfile.ProfileImportConsoleCoordinate.Pilgrim => LocalConsoleCoordinate.Pilgrim,
        ImportProfile.ProfileImportConsoleCoordinate.Abnormal => LocalConsoleCoordinate.Abnormal,
        _ => throw Failure(App.ProfileManagementFailureKind.Unprocessable, "sanitized_profile_console_invalid")
      };

  private static LocalProfileValueUnit MapValueUnit(
      ImportProfile.ProfileImportValueUnit value) => value switch
      {
        ImportProfile.ProfileImportValueUnit.Absolute => LocalProfileValueUnit.Absolute,
        ImportProfile.ProfileImportValueUnit.Ratio => LocalProfileValueUnit.Ratio,
        ImportProfile.ProfileImportValueUnit.Percent => LocalProfileValueUnit.Percent,
        ImportProfile.ProfileImportValueUnit.Count => LocalProfileValueUnit.Count,
        _ => throw Failure(App.ProfileManagementFailureKind.Unprocessable, "sanitized_profile_value_unit_invalid")
      };

  private static bool BindingEquals(
      LocalProfileCatalogBindingWrite stored,
      ImportProfile.ProfileImportCatalogBinding decoded) =>
      stored.CatalogSnapshotUid == decoded.CatalogSnapshotUid &&
      stored.DatasetSnapshotUid == decoded.DatasetSnapshotUid &&
      stored.CatalogManifestSha256 == decoded.ManifestSha256;

  private static LocalAccountProfileWrite ApplyOperations(
      LocalCurrentAccountProfile current,
      IReadOnlyList<App.ProfileEditOperation> operations)
  {
    if (operations.Count == 0)
    {
      return current.Profile;
    }

    if (operations.GroupBy(static operation => (operation.FieldCode, operation.SubjectUid))
        .Any(static group => group.Count() != 1))
    {
      throw Failure(App.ProfileManagementFailureKind.InvalidRequest, "profile_edit_coordinate_duplicate");
    }

    var accountState = current.Profile.AccountState;
    var builds = current.Profile.Builds.ToDictionary(static item => item.CharacterUid);
    var consoles = accountState.Consoles.ToArray();
    var accountChanged = false;
    var buildOperations = new List<App.ProfileEditOperation>();
    foreach (var operation in operations)
    {
      operation.Validate();
      if (operation.FieldCode == "synchro_level" && operation.SubjectUid is null &&
          operation is { ValueKind: "integer", IntegerValue: { } synchro })
      {
        accountState = new LocalAccountCombatStateWrite(
            LocalProfileFact<int>.Ready(CheckedInt(synchro, "profile_edit_value_out_of_range")),
            consoles,
            accountState.ValidationMode,
            LocalProfileRevisionOrigin.UserEdit);
        accountChanged = true;
        continue;
      }

      if (operation.FieldCode is "console_level" or "console_experience")
      {
        if (operation.SubjectUid is not { } consoleUid ||
            operation is not { ValueKind: "integer", IntegerValue: { } rawConsoleValue })
        {
          throw Failure(App.ProfileManagementFailureKind.Unprocessable, "profile_edit_field_not_supported");
        }

        var index = Array.FindIndex(
            consoles,
            console => console.ConsoleDefinitionUid == consoleUid);
        if (index < 0)
        {
          throw Failure(App.ProfileManagementFailureKind.Unprocessable, "profile_edit_subject_not_found");
        }

        var console = consoles[index];
        consoles[index] = operation.FieldCode == "console_level"
            ? new LocalConsoleStateWrite(
                console.Coordinate,
                console.ConsoleDefinitionUid,
                LocalProfileFact<int>.Ready(CheckedInt(
                    rawConsoleValue,
                    "profile_edit_value_out_of_range")),
                console.ObservedExperience)
            : new LocalConsoleStateWrite(
                console.Coordinate,
                console.ConsoleDefinitionUid,
                console.Level,
                LocalProfileFact<long>.Ready(rawConsoleValue));
        accountChanged = true;
        continue;
      }

      buildOperations.Add(operation);
    }

    if (accountChanged)
    {
      accountState = new LocalAccountCombatStateWrite(
          accountState.SynchroLevel,
          consoles,
          accountState.ValidationMode,
          LocalProfileRevisionOrigin.UserEdit);
    }

    foreach (var group in buildOperations.GroupBy(static operation => operation.SubjectUid))
    {
      if (group.Key is not { } characterUid || !builds.TryGetValue(characterUid, out var build))
      {
        throw Failure(App.ProfileManagementFailureKind.Unprocessable, "profile_edit_subject_not_found");
      }

      builds[characterUid] = ApplyBuildOperations(build, group.ToArray());
    }

    return new LocalAccountProfileWrite(
        current.Profile.CharacterCatalog,
        current.Profile.CombatSupportCatalog,
        accountState,
        builds.Values,
        current.Profile.SquadCharacterUids,
        current.Profile.SquadOrigin,
        LocalProfileRevisionOrigin.UserEdit);
  }

  private static LocalCharacterBuildWrite ApplyBuildOperations(
      LocalCharacterBuildWrite source,
      IReadOnlyList<App.ProfileEditOperation> operations)
  {
    var characterLevel = source.CharacterLevel;
    var limitBreak = source.LimitBreak;
    var coreLevel = source.CoreLevel;
    var bondLevel = source.BondLevel;
    var skill1 = source.Skill1Level;
    var skill2 = source.Skill2Level;
    var burst = source.BurstLevel;
    var equipment = source.Equipment.ToDictionary(
        static item => EquipmentSlotCode(item.Slot),
        static item => new EquipmentEditStage(item),
        StringComparer.Ordinal);
    var cube = new CubeEditStage(source.Cube);
    var collection = new CollectionEditStage(source.Collection);

    foreach (var operation in operations)
    {
      if (operation.FieldCode is "character_level" or "limit_break" or "core_level" or
          "bond_level" or "skill_1_level" or "skill_2_level" or "burst_level")
      {
        var value = RequireInteger(operation);
        switch (operation.FieldCode)
        {
          case "character_level": characterLevel = value; break;
          case "limit_break": limitBreak = LocalProfileFact<int>.Ready(value); break;
          case "core_level": coreLevel = LocalProfileFact<int>.Ready(value); break;
          case "bond_level": bondLevel = LocalProfileFact<int>.Ready(value); break;
          case "skill_1_level": skill1 = LocalProfileFact<int>.Ready(value); break;
          case "skill_2_level": skill2 = LocalProfileFact<int>.Ready(value); break;
          case "burst_level": burst = LocalProfileFact<int>.Ready(value); break;
        }

        continue;
      }

      var parts = operation.FieldCode.Split('.', StringSplitOptions.None);
      if (parts.Length >= 3 && parts[0] == "equipment" &&
          equipment.TryGetValue(parts[1], out var equipmentStage))
      {
        equipmentStage.Apply(parts, operation);
        continue;
      }

      if (parts.Length == 2 && parts[0] == "cube")
      {
        cube.Apply(parts[1], operation);
        continue;
      }

      if (parts.Length == 2 && parts[0] == "collection")
      {
        collection.Apply(parts[1], operation);
        continue;
      }

      throw Failure(App.ProfileManagementFailureKind.Unprocessable, "profile_edit_field_not_supported");
    }

    return new LocalCharacterBuildWrite(
        source.CharacterUid,
        characterLevel,
        limitBreak,
        coreLevel,
        bondLevel,
        skill1,
        skill2,
        burst,
        source.Equipment.Select(item => equipment[EquipmentSlotCode(item.Slot)].Build()),
        cube.Build(),
        collection.Build(),
        source.ValidationMode,
        LocalProfileMaterializationPolicy.ExplicitV1,
        LocalProfileRevisionOrigin.UserEdit);
  }

  private static int RequireInteger(App.ProfileEditOperation operation) =>
      operation is { ValueKind: "integer", IntegerValue: { } value }
          ? CheckedInt(value, "profile_edit_value_out_of_range")
          : throw Failure(App.ProfileManagementFailureKind.Unprocessable, "profile_edit_value_kind_mismatch");

  private static string RequireControlled(App.ProfileEditOperation operation) =>
      operation is { ValueKind: "controlled", ControlledValue: { } value }
          ? value
          : throw Failure(App.ProfileManagementFailureKind.Unprocessable, "profile_edit_value_kind_mismatch");

  private static EntityUid RequireReference(App.ProfileEditOperation operation) =>
      operation is { ValueKind: "reference", ReferenceUid: { } value }
          ? value
          : throw Failure(App.ProfileManagementFailureKind.Unprocessable, "profile_edit_value_kind_mismatch");

  private static bool RequireBoolean(App.ProfileEditOperation operation) =>
      operation is { ValueKind: "boolean", BooleanValue: { } value }
          ? value
          : throw Failure(App.ProfileManagementFailureKind.Unprocessable, "profile_edit_value_kind_mismatch");

  private sealed class EquipmentEditStage
  {
    private readonly LocalEquipmentWrite _source;
    private readonly Dictionary<int, OverloadEditStage> _lines;
    private LocalEquipmentState _state;
    private EntityUid? _definitionUid;
    private LocalProfileFact<int>? _enhancement;
    private LocalProfileFact<bool>? _manufacturer;
    private bool _nonStateTouched;

    internal EquipmentEditStage(LocalEquipmentWrite source)
    {
      _source = source;
      _state = source.State;
      _definitionUid = source.EquipmentDefinitionUid;
      _enhancement = source.EnhancementLevel;
      _manufacturer = source.ManufacturerMatched;
      _lines = Enumerable.Range(1, 3).ToDictionary(
          static index => index,
          index => new OverloadEditStage(
              index,
              source.OverloadLines.SingleOrDefault(line => line.LineIndex == index)));
    }

    private bool Touched { get; set; }

    internal void Apply(string[] parts, App.ProfileEditOperation operation)
    {
      Touched = true;
      if (parts.Length == 3)
      {
        switch (parts[2])
        {
          case "state":
            _state = RequireControlled(operation) switch
            {
              "equipped" => LocalEquipmentState.Equipped,
              "unequipped" => LocalEquipmentState.Unequipped,
              _ => throw Failure(App.ProfileManagementFailureKind.Unprocessable, "profile_edit_controlled_value_invalid")
            };
            return;
          case "definition":
            _definitionUid = RequireReference(operation);
            _nonStateTouched = true;
            return;
          case "enhancement_level":
            _enhancement = LocalProfileFact<int>.Ready(RequireInteger(operation));
            _nonStateTouched = true;
            return;
          case "manufacturer_matched":
            _manufacturer = LocalProfileFact<bool>.Ready(RequireBoolean(operation));
            _nonStateTouched = true;
            return;
        }
      }

      if (parts.Length == 5 && parts[2] == "overload" &&
          int.TryParse(parts[3], out var lineIndex) && lineIndex is >= 1 and <= 3)
      {
        _lines[lineIndex].Apply(parts[4], operation);
        _nonStateTouched = true;
        return;
      }

      throw Failure(App.ProfileManagementFailureKind.Unprocessable, "profile_edit_field_not_supported");
    }

    internal LocalEquipmentWrite Build()
    {
      if (!Touched)
      {
        return _source;
      }

      if (_state == LocalEquipmentState.Unequipped)
      {
        if (_nonStateTouched)
        {
          throw Failure(App.ProfileManagementFailureKind.Unprocessable, "profile_edit_final_shape_invalid");
        }

        return new LocalEquipmentWrite(
            _source.Slot,
            LocalEquipmentState.Unequipped,
            manufacturerMatched: LocalProfileFact<bool>.NotApplicable());
      }

      if (_state != LocalEquipmentState.Equipped || _definitionUid is null ||
          _enhancement is null || _manufacturer is null)
      {
        throw Failure(App.ProfileManagementFailureKind.Unprocessable, "profile_edit_final_shape_invalid");
      }

      return new LocalEquipmentWrite(
          _source.Slot,
          LocalEquipmentState.Equipped,
          _definitionUid,
          _enhancement,
          _manufacturer,
          _lines.Values.SelectMany(static line => line.Build()));
    }
  }

  private sealed class OverloadEditStage
  {
    private bool _present;
    private EntityUid? _definitionUid;
    private LocalProfileValueUnit? _unit;
    private LocalProfileExactValue? _value;
    private bool _touched;
    private bool _nonStateTouched;

    internal OverloadEditStage(int lineIndex, LocalOverloadLineWrite? source)
    {
      _present = source is not null;
      _definitionUid = source?.OptionDefinitionUid;
      _unit = source?.Unit;
      _value = source?.ExactValue;
      LineIndex = lineIndex;
    }

    private int LineIndex { get; }

    internal void Apply(string field, App.ProfileEditOperation operation)
    {
      _touched = true;
      switch (field)
      {
        case "state":
          _present = RequireControlled(operation) switch
          {
            "present" => true,
            "absent" => false,
            _ => throw Failure(App.ProfileManagementFailureKind.Unprocessable, "profile_edit_controlled_value_invalid")
          };
          return;
        case "definition":
          _definitionUid = RequireReference(operation);
          _nonStateTouched = true;
          return;
        case "unit":
          _unit = RequireControlled(operation) switch
          {
            "absolute" => LocalProfileValueUnit.Absolute,
            "ratio" => LocalProfileValueUnit.Ratio,
            "percent" => LocalProfileValueUnit.Percent,
            "count" => LocalProfileValueUnit.Count,
            _ => throw Failure(App.ProfileManagementFailureKind.Unprocessable, "profile_edit_controlled_value_invalid")
          };
          _nonStateTouched = true;
          return;
        case "value" when operation is
        { ValueKind: "exact_decimal", UnscaledValue: { } raw, DecimalScale: { } scale }:
          _value = new LocalProfileExactValue(raw, scale);
          _nonStateTouched = true;
          return;
        default:
          throw Failure(App.ProfileManagementFailureKind.Unprocessable, "profile_edit_value_kind_mismatch");
      }
    }

    internal IEnumerable<LocalOverloadLineWrite> Build()
    {
      if (!_present)
      {
        if (_touched && _nonStateTouched)
        {
          throw Failure(App.ProfileManagementFailureKind.Unprocessable, "profile_edit_final_shape_invalid");
        }

        return [];
      }

      if (_definitionUid is null || _unit is null || _value is null)
      {
        throw Failure(App.ProfileManagementFailureKind.Unprocessable, "profile_edit_final_shape_invalid");
      }

      // Untouched present lines retain their source line index. Newly-present lines have the
      // index assigned by the owning dictionary immediately before this method is called.
      return [new LocalOverloadLineWrite(LineIndex, _definitionUid.Value, _unit.Value, _value.Value)];
    }
  }

  private sealed class CubeEditStage
  {
    private readonly LocalCubeSelectionWrite _source;
    private LocalOptionalSelectionState _state;
    private EntityUid? _definitionUid;
    private LocalProfileFact<int>? _level;
    private bool _touched;
    private bool _nonStateTouched;

    internal CubeEditStage(LocalCubeSelectionWrite source)
    {
      _source = source;
      _state = source.State;
      _definitionUid = source.DefinitionUid;
      _level = source.Level;
    }

    internal void Apply(string field, App.ProfileEditOperation operation)
    {
      _touched = true;
      switch (field)
      {
        case "state":
          _state = RequireControlled(operation) switch
          {
            "equipped" => LocalOptionalSelectionState.Equipped,
            "unequipped" => LocalOptionalSelectionState.Unequipped,
            _ => throw Failure(App.ProfileManagementFailureKind.Unprocessable, "profile_edit_controlled_value_invalid")
          };
          break;
        case "definition": _definitionUid = RequireReference(operation); _nonStateTouched = true; break;
        case "level": _level = LocalProfileFact<int>.Ready(RequireInteger(operation)); _nonStateTouched = true; break;
        default: throw Failure(App.ProfileManagementFailureKind.Unprocessable, "profile_edit_field_not_supported");
      }
    }

    internal LocalCubeSelectionWrite Build()
    {
      if (!_touched) return _source;
      if (_state == LocalOptionalSelectionState.Unequipped)
      {
        if (_nonStateTouched) throw Failure(App.ProfileManagementFailureKind.Unprocessable, "profile_edit_final_shape_invalid");
        return new LocalCubeSelectionWrite(LocalOptionalSelectionState.Unequipped);
      }

      return _state == LocalOptionalSelectionState.Equipped && _definitionUid is not null && _level is not null
          ? new LocalCubeSelectionWrite(_state, _definitionUid, _level)
          : throw Failure(App.ProfileManagementFailureKind.Unprocessable, "profile_edit_final_shape_invalid");
    }
  }

  private sealed class CollectionEditStage
  {
    private readonly LocalCollectionSelectionWrite _source;
    private LocalCollectionSelectionKind _kind;
    private EntityUid? _definitionUid;
    private LocalProfileFact<int>? _level;
    private bool _touched;
    private bool _nonKindTouched;

    internal CollectionEditStage(LocalCollectionSelectionWrite source)
    {
      _source = source;
      _kind = source.Kind;
      _definitionUid = source.DefinitionUid;
      _level = source.Level;
    }

    internal void Apply(string field, App.ProfileEditOperation operation)
    {
      _touched = true;
      switch (field)
      {
        case "kind":
          _kind = RequireControlled(operation) switch
          {
            "detached" => LocalCollectionSelectionKind.Detached,
            "generic_collection" => LocalCollectionSelectionKind.GenericCollection,
            "favorite" => LocalCollectionSelectionKind.Favorite,
            _ => throw Failure(App.ProfileManagementFailureKind.Unprocessable, "profile_edit_controlled_value_invalid")
          };
          break;
        case "definition": _definitionUid = RequireReference(operation); _nonKindTouched = true; break;
        case "level": _level = LocalProfileFact<int>.Ready(RequireInteger(operation)); _nonKindTouched = true; break;
        default: throw Failure(App.ProfileManagementFailureKind.Unprocessable, "profile_edit_field_not_supported");
      }
    }

    internal LocalCollectionSelectionWrite Build()
    {
      if (!_touched) return _source;
      if (_kind == LocalCollectionSelectionKind.Detached)
      {
        if (_nonKindTouched) throw Failure(App.ProfileManagementFailureKind.Unprocessable, "profile_edit_final_shape_invalid");
        return new LocalCollectionSelectionWrite(LocalCollectionSelectionKind.Detached);
      }

      return _kind is LocalCollectionSelectionKind.GenericCollection or LocalCollectionSelectionKind.Favorite &&
          _definitionUid is not null && _level is not null
          ? new LocalCollectionSelectionWrite(_kind, _definitionUid, _level)
          : throw Failure(App.ProfileManagementFailureKind.Unprocessable, "profile_edit_final_shape_invalid");
    }
  }

  private static LocalCharacterBuildWrite CloneBuild(
      LocalCharacterBuildWrite build,
      string fieldCode,
      int value) => fieldCode switch
      {
        "character_level" => NewBuild(build, characterLevel: value),
        "limit_break" => NewBuild(build, limitBreak: LocalProfileFact<int>.Ready(value)),
        "core_level" => NewBuild(build, coreLevel: LocalProfileFact<int>.Ready(value)),
        "bond_level" => NewBuild(build, bondLevel: LocalProfileFact<int>.Ready(value)),
        "skill_1_level" => NewBuild(build, skill1: LocalProfileFact<int>.Ready(value)),
        "skill_2_level" => NewBuild(build, skill2: LocalProfileFact<int>.Ready(value)),
        "burst_level" => NewBuild(build, burst: LocalProfileFact<int>.Ready(value)),
        _ => throw Failure(App.ProfileManagementFailureKind.Unprocessable, "profile_edit_field_not_supported")
      };

  private static LocalCharacterBuildWrite NewBuild(
      LocalCharacterBuildWrite source,
      int? characterLevel = null,
      LocalProfileFact<int>? limitBreak = null,
      LocalProfileFact<int>? coreLevel = null,
      LocalProfileFact<int>? bondLevel = null,
      LocalProfileFact<int>? skill1 = null,
      LocalProfileFact<int>? skill2 = null,
      LocalProfileFact<int>? burst = null) => new(
          source.CharacterUid,
          characterLevel ?? source.CharacterLevel,
          limitBreak ?? source.LimitBreak,
          coreLevel ?? source.CoreLevel,
          bondLevel ?? source.BondLevel,
          skill1 ?? source.Skill1Level,
          skill2 ?? source.Skill2Level,
          burst ?? source.BurstLevel,
          source.Equipment,
          source.Cube,
          source.Collection,
          source.ValidationMode,
          LocalProfileMaterializationPolicy.ExplicitV1,
          LocalProfileRevisionOrigin.UserEdit);

  private static IReadOnlyList<App.ProfileDiffEntry> BuildChanges(
      LocalAccountProfileWrite before,
      LocalAccountProfileWrite after,
      IReadOnlyList<App.ProfileEditOperation> operations)
  {
    var beforeValues = ProfileValues(before).ToDictionary(ValueKey);
    var afterValues = ProfileValues(after).ToDictionary(ValueKey);
    return operations.Select(static operation => (operation.FieldCode, operation.SubjectUid))
        .Distinct()
        .Select(key => new App.ProfileDiffEntry(
            key.FieldCode,
            key.SubjectUid,
            beforeValues.GetValueOrDefault(key),
            afterValues.GetValueOrDefault(key)))
        .ToArray();
  }

  private static IReadOnlyList<App.ProfileDiffEntry> BuildAllChanges(
      LocalAccountProfileWrite before,
      LocalAccountProfileWrite after)
  {
    var beforeValues = ProfileValues(before).ToDictionary(ValueKey);
    var afterValues = ProfileValues(after).ToDictionary(ValueKey);
    return beforeValues.Keys.Concat(afterValues.Keys)
        .Distinct()
        .OrderBy(static key => key.FieldCode, StringComparer.Ordinal)
        .ThenBy(static key => key.SubjectUid?.ToString(), StringComparer.Ordinal)
        .Where(key => !Equals(
            beforeValues.GetValueOrDefault(key),
            afterValues.GetValueOrDefault(key)))
        .Select(key => new App.ProfileDiffEntry(
            key.FieldCode,
            key.SubjectUid,
            beforeValues.GetValueOrDefault(key),
            afterValues.GetValueOrDefault(key)))
        .ToArray();
  }

  private static IReadOnlyList<App.ProfileDiffEntry> BuildCreateChanges(
      LocalAccountProfileWrite profile) => ProfileValues(profile)
          .OrderBy(static value => value.FieldCode, StringComparer.Ordinal)
          .ThenBy(static value => value.SubjectUid?.ToString(), StringComparer.Ordinal)
          .Select(static value => new App.ProfileDiffEntry(
              value.FieldCode,
              value.SubjectUid,
              Before: null,
              After: value))
          .ToArray();

  private static (string FieldCode, EntityUid? SubjectUid) ValueKey(
      App.ProfileValueProjection value) => (value.FieldCode, value.SubjectUid);

  private static IReadOnlyList<App.ProfileValueProjection> ProfileValues(
      LocalAccountProfileWrite profile)
  {
    var result = new List<App.ProfileValueProjection>
    {
      FactValue("synchro_level", null, profile.AccountState.SynchroLevel)
    };
    foreach (var console in profile.AccountState.Consoles)
    {
      result.Add(FactValue("console_level", console.ConsoleDefinitionUid, console.Level));
      result.Add(FactValue(
          "console_experience",
          console.ConsoleDefinitionUid,
          console.ObservedExperience));
    }

    foreach (var build in profile.Builds)
    {
      result.Add(new App.ProfileValueProjection(
          "character_level",
          build.CharacterUid,
          "ready",
          IntegerValue: build.CharacterLevel));
      result.Add(FactValue("limit_break", build.CharacterUid, build.LimitBreak));
      result.Add(FactValue("core_level", build.CharacterUid, build.CoreLevel));
      result.Add(FactValue("bond_level", build.CharacterUid, build.BondLevel));
      result.Add(FactValue("skill_1_level", build.CharacterUid, build.Skill1Level));
      result.Add(FactValue("skill_2_level", build.CharacterUid, build.Skill2Level));
      result.Add(FactValue("burst_level", build.CharacterUid, build.BurstLevel));
      foreach (var equipment in build.Equipment)
      {
        var prefix = $"equipment.{EquipmentSlotCode(equipment.Slot)}";
        result.Add(new App.ProfileValueProjection(
            $"{prefix}.state",
            build.CharacterUid,
            "ready",
            ControlledValue: EquipmentStateCode(equipment.State)));
        result.Add(new App.ProfileValueProjection(
            $"{prefix}.definition",
            build.CharacterUid,
            equipment.EquipmentDefinitionUid.HasValue ? "ready" : "not_applicable",
            ReferenceUid: equipment.EquipmentDefinitionUid));
        if (equipment.EnhancementLevel is not null)
        {
          result.Add(FactValue(
              $"{prefix}.enhancement_level",
              build.CharacterUid,
              equipment.EnhancementLevel));
        }

        if (equipment.ManufacturerMatched is not null)
        {
          result.Add(FactValue(
              $"{prefix}.manufacturer_matched",
              build.CharacterUid,
              equipment.ManufacturerMatched));
        }

        for (var lineIndex = 1; lineIndex <= 3; lineIndex++)
        {
          var line = equipment.OverloadLines.SingleOrDefault(item => item.LineIndex == lineIndex);
          result.Add(new App.ProfileValueProjection(
              $"{prefix}.overload.{lineIndex}.state",
              build.CharacterUid,
              "ready",
              ControlledValue: line is null ? "absent" : "present"));
          if (line is null)
          {
            continue;
          }

          result.Add(new App.ProfileValueProjection(
              $"{prefix}.overload.{line.LineIndex}.definition",
              build.CharacterUid,
              "ready",
              ReferenceUid: line.OptionDefinitionUid));
          result.Add(new App.ProfileValueProjection(
              $"{prefix}.overload.{line.LineIndex}.value",
              build.CharacterUid,
              "ready",
              UnscaledValue: line.ExactValue.UnscaledValue,
              DecimalScale: line.ExactValue.DecimalScale));
          result.Add(new App.ProfileValueProjection(
              $"{prefix}.overload.{line.LineIndex}.unit",
              build.CharacterUid,
              "ready",
              ControlledValue: ValueUnitCode(line.Unit)));
        }
      }

      result.Add(new App.ProfileValueProjection(
          "cube.state",
          build.CharacterUid,
          "ready",
          ControlledValue: OptionalStateCode(build.Cube.State)));
      if (build.Cube.DefinitionUid is { } cubeUid)
      {
        result.Add(new App.ProfileValueProjection(
            "cube.definition",
            build.CharacterUid,
            "ready",
            ReferenceUid: cubeUid));
      }

      if (build.Cube.Level is not null)
      {
        result.Add(FactValue("cube.level", build.CharacterUid, build.Cube.Level));
      }

      result.Add(new App.ProfileValueProjection(
          "collection.kind",
          build.CharacterUid,
          "ready",
          ControlledValue: CollectionKindCode(build.Collection.Kind)));
      if (build.Collection.DefinitionUid is { } collectionUid)
      {
        result.Add(new App.ProfileValueProjection(
            "collection.definition",
            build.CharacterUid,
            "ready",
            ReferenceUid: collectionUid));
      }

      if (build.Collection.Level is not null)
      {
        result.Add(FactValue("collection.level", build.CharacterUid, build.Collection.Level));
      }
    }

    return result;
  }

  private static string EquipmentSlotCode(LocalEquipmentSlot value) => value switch
  {
    LocalEquipmentSlot.Head => "head",
    LocalEquipmentSlot.Torso => "torso",
    LocalEquipmentSlot.Arms => "arms",
    LocalEquipmentSlot.Legs => "legs",
    _ => throw Failure(App.ProfileManagementFailureKind.Unprocessable, "profile_equipment_slot_invalid")
  };

  private static string EquipmentStateCode(LocalEquipmentState value) => value switch
  {
    LocalEquipmentState.Equipped => "equipped",
    LocalEquipmentState.Unequipped => "unequipped",
    LocalEquipmentState.Unresolved => "unresolved",
    _ => throw Failure(App.ProfileManagementFailureKind.Unprocessable, "profile_equipment_state_invalid")
  };

  private static string OptionalStateCode(LocalOptionalSelectionState value) => value switch
  {
    LocalOptionalSelectionState.Equipped => "equipped",
    LocalOptionalSelectionState.Unequipped => "unequipped",
    LocalOptionalSelectionState.Unresolved => "unresolved",
    _ => throw Failure(App.ProfileManagementFailureKind.Unprocessable, "profile_selection_state_invalid")
  };

  private static string CollectionKindCode(LocalCollectionSelectionKind value) => value switch
  {
    LocalCollectionSelectionKind.Detached => "detached",
    LocalCollectionSelectionKind.GenericCollection => "generic_collection",
    LocalCollectionSelectionKind.Favorite => "favorite",
    LocalCollectionSelectionKind.Unresolved => "unresolved",
    LocalCollectionSelectionKind.NotApplicable => "not_applicable",
    _ => throw Failure(App.ProfileManagementFailureKind.Unprocessable, "profile_collection_kind_invalid")
  };

  private static string ValueUnitCode(LocalProfileValueUnit value) => value switch
  {
    LocalProfileValueUnit.Absolute => "absolute",
    LocalProfileValueUnit.Ratio => "ratio",
    LocalProfileValueUnit.Percent => "percent",
    LocalProfileValueUnit.Count => "count",
    _ => throw Failure(App.ProfileManagementFailureKind.Unprocessable, "profile_value_unit_invalid")
  };

  private static string ImportEquipmentSlotCode(
      ImportProfile.ProfileImportEquipmentSlot value) => value switch
      {
        ImportProfile.ProfileImportEquipmentSlot.Head => "head",
        ImportProfile.ProfileImportEquipmentSlot.Torso => "torso",
        ImportProfile.ProfileImportEquipmentSlot.Arms => "arms",
        ImportProfile.ProfileImportEquipmentSlot.Legs => "legs",
        _ => throw Failure(App.ProfileManagementFailureKind.Unprocessable, "sanitized_profile_equipment_slot_invalid")
      };

  private static string ImportConsoleCode(
      ImportProfile.ProfileImportConsoleCoordinate value) => value switch
      {
        ImportProfile.ProfileImportConsoleCoordinate.Common => "common",
        ImportProfile.ProfileImportConsoleCoordinate.Attacker => "attacker",
        ImportProfile.ProfileImportConsoleCoordinate.Defender => "defender",
        ImportProfile.ProfileImportConsoleCoordinate.Supporter => "supporter",
        ImportProfile.ProfileImportConsoleCoordinate.Elysion => "elysion",
        ImportProfile.ProfileImportConsoleCoordinate.Missilis => "missilis",
        ImportProfile.ProfileImportConsoleCoordinate.Tetra => "tetra",
        ImportProfile.ProfileImportConsoleCoordinate.Pilgrim => "pilgrim",
        ImportProfile.ProfileImportConsoleCoordinate.Abnormal => "abnormal",
        _ => throw Failure(App.ProfileManagementFailureKind.Unprocessable, "sanitized_profile_console_invalid")
      };

  private static string ImportCollectionKindCode(
      ImportProfile.ProfileImportCollectionKind value) => value switch
      {
        ImportProfile.ProfileImportCollectionKind.Detached => "detached",
        ImportProfile.ProfileImportCollectionKind.GenericCollection => "generic_collection",
        ImportProfile.ProfileImportCollectionKind.Favorite => "favorite",
        _ => throw Failure(App.ProfileManagementFailureKind.Unprocessable, "sanitized_profile_collection_invalid")
      };

  private static string ImportValueUnitCode(
      ImportProfile.ProfileImportValueUnit value) => value switch
      {
        ImportProfile.ProfileImportValueUnit.Absolute => "absolute",
        ImportProfile.ProfileImportValueUnit.Ratio => "ratio",
        ImportProfile.ProfileImportValueUnit.Percent => "percent",
        ImportProfile.ProfileImportValueUnit.Count => "count",
        _ => throw Failure(App.ProfileManagementFailureKind.Unprocessable, "sanitized_profile_value_unit_invalid")
      };

  private static App.ProfileValueProjection FactValue<T>(
      string fieldCode,
      EntityUid? subjectUid,
      LocalProfileFact<T> fact)
      where T : struct
  {
    var value = fact.Value;
    return new App.ProfileValueProjection(
        fieldCode,
        subjectUid,
        ProfileFactStatus(fact.Status),
        IntegerValue: value is int intValue ? intValue : value is long longValue ? longValue : null,
        BooleanValue: value is bool boolValue ? boolValue : null,
        ReasonCode: fact.ReasonCode?.Code);
  }

  private static App.CurrentProfileProjection MapProfile(LocalCurrentAccountProfile current) => new(
      current.Revision.AccountUid,
      new App.RevisionReference(
          current.Revision.ProfileTemplateRevisionUid,
          current.Revision.ProfileContentSha256,
          current.Revision.ProfileTemplateLineage.RevisionNumber),
      MapBinding(current.Profile.CharacterCatalog),
      MapBinding(current.Profile.CombatSupportCatalog),
      current.Revision.IsCombatReady,
      current.Revision.HasCompleteCombatSemantics,
      current.Revision.IsGameLegalReady,
      ProfileValues(current.Profile),
      MapIssues(current.Revision.IssueCodes));

  private static App.AccountBootstrapProjection MapBootstrap(
      LocalClientBootstrapProjection bootstrap,
      App.CurrentProfileProjection profile)
  {
    if (bootstrap.ProfileTemplateRevisionUid != profile.ProfileRevision.RevisionUid)
    {
      throw Failure(App.ProfileManagementFailureKind.Conflict, "bootstrap_profile_snapshot_conflict");
    }

    return new(
          bootstrap.AccountUid,
          bootstrap.RevisionSetSha256,
          profile,
          MapLobby(bootstrap.AccountUid, bootstrap.Lobby),
          MapWallet(bootstrap.AccountUid, bootstrap.Wallet),
          MapFeatureManifest(bootstrap.FeatureManifest),
          bootstrap.Roster.Select(static item => new App.RosterEntryProjection(
              item.CharacterUid,
              item.CharacterBuildUid,
              item.BuildRevisionUid,
              item.BuildContentSha256,
              item.IsSelectionReady,
              item.HasCombatSemantics)).ToArray(),
          bootstrap.Squad is null
              ? null
              : new App.SquadProjection(
                  bootstrap.Squad.SquadUid,
                  bootstrap.Squad.SquadRevisionUid,
                  bootstrap.Squad.Members.Select(static item => new App.SquadMemberProjection(
                      item.Position,
                      item.CharacterUid,
                      item.CharacterBuildUid,
                      item.BuildRevisionUid)).ToArray()),
          new App.InventorySubsetProjection(
              bootstrap.Inventory.ScopeCode,
              profile.ProfileRevision,
              bootstrap.Inventory.IsCompleteInventory,
              bootstrap.Inventory.IsReadOnly,
              bootstrap.Inventory.Items.Select(MapInventoryItem).ToArray()));
  }

  private static App.InventoryItemProjection MapInventoryItem(
      LocalClientInventoryItemProjection item)
  {
    var values = new List<App.ProfileValueProjection>();
    if (item.LevelStatus is not null)
    {
      values.Add(new App.ProfileValueProjection(
          "level",
          item.ProjectionUid,
          item.LevelStatus,
          IntegerValue: item.Level,
          ReasonCode: item.LevelUnresolvedReasonCode));
    }

    if (item.Values is not null)
    {
      values.AddRange(item.Values
          .OrderBy(static value => value.FieldCode, StringComparer.Ordinal)
          .Select(value => new App.ProfileValueProjection(
          value.FieldCode,
          item.ProjectionUid,
          value.StatusCode,
          IntegerValue: value.IntegerValue,
          BooleanValue: value.BooleanValue,
          ReferenceUid: value.ReferenceUid,
          UnscaledValue: value.UnscaledValue,
          DecimalScale: value.DecimalScale,
          ControlledValue: value.ControlledValue,
          ReasonCode: value.UnresolvedReasonCode)));
    }

    return new App.InventoryItemProjection(
        item.ProjectionUid,
        item.ItemKind,
        item.CharacterUid,
        item.BuildRevisionUid,
        item.SlotCode,
        item.StateCode,
        item.DefinitionUid,
        item.DefinitionVersionUid,
        values);
  }

  private static App.LobbyPresentationProjection MapLobby(
      EntityUid accountUid,
      LocalLobbyPresentationReceipt receipt)
  {
    if (receipt.Content.CommanderLevel.Value is not { } commanderLevel)
    {
      throw Failure(App.ProfileManagementFailureKind.Unprocessable, "lobby_commander_level_unresolved");
    }

    return new App.LobbyPresentationProjection(
        accountUid,
        new App.RevisionReference(
            receipt.RevisionUid,
            receipt.ContentSha256,
            receipt.Lineage.RevisionNumber),
        receipt.Content.DisplayName,
        commanderLevel,
        receipt.Content.ProfileIcon.Value,
        receipt.Content.ProfileFrame.Value,
        receipt.Content.LobbyCharacter.Value,
        receipt.Content.LobbyBackground.Value);
  }

  private static App.WalletProjection MapWallet(
      EntityUid accountUid,
      LocalWalletReceipt receipt) => new(
          accountUid,
          new App.RevisionReference(
              receipt.RevisionUid,
              receipt.ContentSha256,
              receipt.Lineage.RevisionNumber),
          receipt.Content.Balances
              .Select(static item => new App.WalletBalanceProjection(
                  LocalGameStateContractCanonicalizer.Code(item.Currency),
                  item.Amount))
              .OrderBy(static item => item.CurrencyCode, StringComparer.Ordinal)
              .ToArray());

  private static App.ClientFeatureManifestProjection MapFeatureManifest(
      LocalClientFeatureManifestReceipt receipt) => new(
          receipt.ManifestUid,
          FeatureContract,
          ParseVersion(receipt.ContractVersion),
          receipt.ContentSha256,
          receipt.Entries.Select(static entry => new App.FeatureCapabilityProjection(
              entry.RouteCode,
              LocalGameStateContractCanonicalizer.Code(entry.Capability),
              entry.Capability != LocalClientFeatureCapability.Supported ||
                  entry.RouteCode == "lobby.inventory",
              entry.Capability == LocalClientFeatureCapability.VisibleNoOp
                  ? "visible_no_op"
                  : null)).ToArray());

  private static App.ProfileWriteReceipt MapWriteReceipt(
      EntityUid operationUid,
      LocalAccountProfileReceipt receipt) => new(
          operationUid,
          receipt.IsIdempotentReplay,
          receipt.AccountUid,
          new App.RevisionReference(
              receipt.ProfileTemplateRevisionUid,
              receipt.ProfileContentSha256,
              receipt.ProfileTemplateLineage.RevisionNumber),
          MapIssues(receipt.IssueCodes));

  private static IReadOnlyList<App.ProfileIssueProjection> MapIssues(
      IReadOnlyList<string> codes) => codes
          .Distinct(StringComparer.Ordinal)
          .Select(static code => new App.ProfileIssueProjection(code, "warning"))
          .ToArray();

  private static App.SourceFreeImportDraftProjection ProjectDraft(
      SanitizedProfileDraftDocument draft)
  {
    var decoded = DecodeSanitizedDraft(draft);
    var observations = new List<App.ProfileObservationProjection>();
    var values = new List<App.ProfileValueProjection>
    {
      new("synchro_level", null, "ready", IntegerValue: decoded.AccountState.SynchroLevel),
      new(
          "occupied_synchro_slot_count_observation",
          null,
          "ready",
          IntegerValue: decoded.AccountState.OccupiedSynchroSlotCountObservation)
    };
    var issues = new List<App.ProfileIssueProjection>();
    foreach (var console in decoded.AccountState.Consoles)
    {
      values.Add(new App.ProfileValueProjection(
          "console_coordinate",
          console.DefinitionUid,
          "ready",
          ControlledValue: ImportConsoleCode(console.Coordinate)));
      values.Add(new App.ProfileValueProjection(
          "console_level",
          console.DefinitionUid,
          "ready",
          IntegerValue: console.Level));
      values.Add(new App.ProfileValueProjection(
          "console_experience",
          console.DefinitionUid,
          "ready",
          IntegerValue: console.ObservedExperience));
    }

    foreach (var build in decoded.Builds)
    {
      observations.Add(new App.ProfileObservationProjection(
          build.CharacterUid,
          RosterLevelAuthority,
          build.Level.RosterLevel,
          "ready"));
      observations.Add(new App.ProfileObservationProjection(
          build.CharacterUid,
          DetailLevelAuthority,
          build.Level.DetailLevel,
          "ready"));
      observations.Add(new App.ProfileObservationProjection(
          build.CharacterUid,
          "bond_level_observation",
          build.BondLevelObservation,
          "ready"));
      values.Add(ImportFactValue(
          "character_level",
          build.CharacterUid,
          build.Level.ResolvedBattleLevel));
      values.Add(new App.ProfileValueProjection(
          "limit_break",
          build.CharacterUid,
          "ready",
          IntegerValue: build.LimitBreak));
      values.Add(new App.ProfileValueProjection(
          "core_level",
          build.CharacterUid,
          "ready",
          IntegerValue: build.CoreLevel));
      values.Add(ImportFactValue("bond_level", build.CharacterUid, build.ResolvedBondLevel));
      values.Add(new App.ProfileValueProjection(
          "skill_1_level",
          build.CharacterUid,
          "ready",
          IntegerValue: build.Skill1Level));
      values.Add(new App.ProfileValueProjection(
          "skill_2_level",
          build.CharacterUid,
          "ready",
          IntegerValue: build.Skill2Level));
      values.Add(new App.ProfileValueProjection(
          "burst_level",
          build.CharacterUid,
          "ready",
          IntegerValue: build.BurstLevel));
      values.Add(new App.ProfileValueProjection(
          "roster_combat_power_observation",
          build.CharacterUid,
          "ready",
          IntegerValue: build.RosterCombatPowerObservation));
      values.Add(new App.ProfileValueProjection(
          "detail_combat_power_observation",
          build.CharacterUid,
          "ready",
          IntegerValue: build.DetailCombatPowerObservation));
      foreach (var equipment in build.Equipment)
      {
        var prefix = $"equipment.{ImportEquipmentSlotCode(equipment.Slot)}";
        values.Add(new App.ProfileValueProjection(
            $"{prefix}.state",
            build.CharacterUid,
            "ready",
            ControlledValue: equipment.State == ImportProfile.ProfileImportAttachmentState.Equipped
                ? "equipped"
                : "unequipped"));
        if (equipment.DefinitionUid is { } definitionUid)
        {
          values.Add(new App.ProfileValueProjection(
              $"{prefix}.definition",
              build.CharacterUid,
              "ready",
              ReferenceUid: definitionUid));
          values.Add(new App.ProfileValueProjection(
              $"{prefix}.enhancement_level",
              build.CharacterUid,
              "ready",
              IntegerValue: equipment.EnhancementLevel));
          values.Add(ImportFactValue(
              $"{prefix}.manufacturer_matched_observation",
              build.CharacterUid,
              equipment.ManufacturerMatchedObservation!));
          values.Add(ImportFactValue(
              $"{prefix}.manufacturer_matched",
              build.CharacterUid,
              equipment.ResolvedManufacturerMatched!));
        }

        for (var lineIndex = 1; lineIndex <= 3; lineIndex++)
        {
          var line = equipment.OverloadLines.SingleOrDefault(item => item.LineIndex == lineIndex);
          values.Add(new App.ProfileValueProjection(
              $"{prefix}.overload.{lineIndex}.state",
              build.CharacterUid,
              "ready",
              ControlledValue: line is null ? "absent" : "present"));
          if (line is null)
          {
            continue;
          }

          values.Add(new App.ProfileValueProjection(
              $"{prefix}.overload.{line.LineIndex}.definition",
              build.CharacterUid,
              "ready",
              ReferenceUid: line.OptionDefinitionUid));
          values.Add(new App.ProfileValueProjection(
              $"{prefix}.overload.{line.LineIndex}.value",
              build.CharacterUid,
              "ready",
              UnscaledValue: line.ExactValue.UnscaledValue,
              DecimalScale: line.ExactValue.DecimalScale));
          values.Add(new App.ProfileValueProjection(
              $"{prefix}.overload.{line.LineIndex}.unit",
              build.CharacterUid,
              "ready",
              ControlledValue: ImportValueUnitCode(line.Unit)));
        }
      }

      values.Add(new App.ProfileValueProjection(
          "cube.state",
          build.CharacterUid,
          "ready",
          ControlledValue: build.Cube.State == ImportProfile.ProfileImportAttachmentState.Equipped
              ? "equipped"
              : "unequipped"));
      if (build.Cube.DefinitionUid is { } cubeUid)
      {
        values.Add(new App.ProfileValueProjection(
            "cube.definition",
            build.CharacterUid,
            "ready",
            ReferenceUid: cubeUid));
        values.Add(new App.ProfileValueProjection(
            "cube.level",
            build.CharacterUid,
            "ready",
            IntegerValue: build.Cube.Level));
      }

      values.Add(new App.ProfileValueProjection(
          "collection.kind",
          build.CharacterUid,
          "ready",
          ControlledValue: ImportCollectionKindCode(build.Collection.Kind)));
      if (build.Collection.DefinitionUid is { } collectionUid)
      {
        values.Add(new App.ProfileValueProjection(
            "collection.definition",
            build.CharacterUid,
            "ready",
            ReferenceUid: collectionUid));
        values.Add(new App.ProfileValueProjection(
            "collection.level",
            build.CharacterUid,
            "ready",
            IntegerValue: build.Collection.Level));
      }

      issues.AddRange(values
          .Where(value => value.SubjectUid == build.CharacterUid && value.Status == "unresolved")
          .Select(value => new App.ProfileIssueProjection(
              value.ReasonCode ?? "sanitized_profile_value_unresolved",
              "warning",
              value.FieldCode,
              value.SubjectUid)));
    }

    return new App.SourceFreeImportDraftProjection(
        draft.PayloadSchemaCode,
        draft.DraftUid,
        draft.CanonicalPayloadSha256,
        draft.CreatedAtUtc,
        MapBinding(draft.CharacterCatalog),
        MapBinding(draft.CombatSupportCatalog),
        observations,
        values,
        issues.Distinct().ToArray(),
        draft.DerivationKind switch
        {
          SanitizedProfileDraftDerivationKind.OfflineSanitizedImport =>
              "offline_sanitized_import",
          SanitizedProfileDraftDerivationKind.Rebase => "rebase",
          SanitizedProfileDraftDerivationKind.ReviewedOverride => "reviewed_override",
          _ => throw Failure(
              App.ProfileManagementFailureKind.Unprocessable,
              "sanitized_profile_draft_kind_invalid")
        },
        draft.PreviousDraftUid,
        decoded.ReviewedOverrides.Select(static item => new App.ImportReviewedOverrideProjection(
            item.Kind switch
            {
              ImportProfile.SanitizedProfileReviewedOverrideKind.BondLevel =>
                  "bond_level",
              ImportProfile.SanitizedProfileReviewedOverrideKind.EquipmentManufacturerMatched =>
                  "equipment_manufacturer_matched",
              _ => throw Failure(
                  App.ProfileManagementFailureKind.Unprocessable,
                  "import_review_override_kind_invalid")
            },
            item.CharacterUid,
            item.EquipmentSlot switch
            {
              ImportProfile.ProfileImportEquipmentSlot.Head => "head",
              ImportProfile.ProfileImportEquipmentSlot.Torso => "torso",
              ImportProfile.ProfileImportEquipmentSlot.Arms => "arms",
              ImportProfile.ProfileImportEquipmentSlot.Legs => "legs",
              null => null,
              _ => throw Failure(
                  App.ProfileManagementFailureKind.Unprocessable,
                  "import_review_equipment_slot_invalid")
            },
            item.IntegerValue,
            item.BooleanValue,
            item.OriginalReasonCode,
            item.ReasonCode)).ToArray());
  }

  private static App.ProfileValueProjection ImportFactValue<T>(
      string fieldCode,
      EntityUid? subjectUid,
      ImportProfile.ProfileImportFact<T> fact)
      where T : struct
  {
    var value = fact.Value;
    return new App.ProfileValueProjection(
        fieldCode,
        subjectUid,
        fact.Status == ImportProfile.ProfileImportFactStatus.Ready ? "ready" : "unresolved",
        IntegerValue: value is int intValue ? intValue : value is long longValue ? longValue : null,
        BooleanValue: value is bool boolValue ? boolValue : null,
        ReasonCode: fact.ReasonCode);
  }

  private static string SerializeCandidate(
      App.ProfileEditPreviewCommand command,
      IReadOnlyList<App.ProfileEditOperation> operations) => JsonSerializer.Serialize(
          new CandidateEnvelope(
              CandidateKind,
              command.AccountUid.ToString(),
              command.ExpectedProfileRevisionUid.ToString(),
              operations.Select(MapOperation).ToArray()),
          JsonOptions);

  private static CandidateEnvelope ParseCandidate(string json)
  {
    var value = JsonSerializer.Deserialize<CandidateEnvelope>(json, JsonOptions) ??
        throw Failure(App.ProfileManagementFailureKind.Unprocessable, "profile_candidate_invalid");
    if (!string.Equals(value.DraftKind, CandidateKind, StringComparison.Ordinal) ||
        value.Operations is null)
    {
      throw Failure(App.ProfileManagementFailureKind.Unprocessable, "profile_candidate_invalid");
    }

    return value;
  }

  private static void EnsureCandidate(
      CandidateEnvelope candidate,
      EntityUid accountUid,
      EntityUid expectedRevisionUid)
  {
    if (!string.Equals(candidate.AccountUid, accountUid.ToString(), StringComparison.Ordinal) ||
        !string.Equals(
            candidate.BaseProfileRevisionUid,
            expectedRevisionUid.ToString(),
            StringComparison.Ordinal))
    {
      throw Failure(App.ProfileManagementFailureKind.Conflict, "profile_candidate_topology_conflict");
    }
  }

  private static string SerializeDiff(
      string diffKind,
      EntityUid draftUid,
      Sha256Digest draftSha256,
      EntityUid accountUid,
      EntityUid baseRevisionUid,
      string? levelAuthorityPolicy,
      IReadOnlyList<string>? scopes,
      IReadOnlyList<App.ProfileDiffEntry> changes) => JsonSerializer.Serialize(
          new DiffEnvelope(
              diffKind,
              draftUid.ToString(),
              draftSha256.ToString(),
              accountUid.ToString(),
              baseRevisionUid.ToString(),
              levelAuthorityPolicy,
              scopes?.ToArray(),
              changes.Select(static item => new DiffEntryWire(
                  item.FieldCode,
                  item.SubjectUid?.ToString())).ToArray()),
          JsonOptions);

  private static string SerializeCreateImportDiff(
      EntityUid draftUid,
      Sha256Digest draftSha256,
      string levelAuthorityPolicy,
      IReadOnlyList<string> scopes,
      IReadOnlyList<App.ProfileDiffEntry> changes) => JsonSerializer.Serialize(
          new CreateImportDiffEnvelope(
              "sanitized_import_create_diff/v1",
              draftUid.ToString(),
              draftSha256.ToString(),
              levelAuthorityPolicy,
              scopes.Order(StringComparer.Ordinal).ToArray(),
              changes.Select(static item => new DiffEntryWire(
                  item.FieldCode,
                  item.SubjectUid?.ToString())).ToArray()),
          JsonOptions);

  private static ProfileEditOperationWire MapOperation(App.ProfileEditOperation operation) => new(
      operation.FieldCode,
      operation.SubjectUid?.ToString(),
      operation.ValueKind,
      operation.IntegerValue,
      operation.BooleanValue,
      operation.ReferenceUid?.ToString(),
      operation.UnscaledValue,
      operation.DecimalScale,
      operation.ControlledValue);

  private static App.ProfileEditOperation MapOperation(ProfileEditOperationWire operation) => new(
      operation.FieldCode,
      ParseOptionalUid(operation.SubjectUid),
      operation.ValueKind,
      operation.IntegerValue,
      operation.BooleanValue,
      ParseOptionalUid(operation.ReferenceUid),
      operation.UnscaledValue,
      operation.DecimalScale,
      operation.ControlledValue);

  private static IReadOnlyList<ImportProfile.SanitizedProfileReviewedOverrideRequest>
      MapReviewedOverrideRequests(IReadOnlyList<App.ImportReviewedOverrideRequest> requests)
  {
    if (requests is null || requests.Count is <= 0 or > 5120 || requests.Any(static item => item is null))
    {
      throw Failure(App.ProfileManagementFailureKind.InvalidRequest, "import_review_override_set_invalid");
    }

    return requests.Select(static request => new ImportProfile.SanitizedProfileReviewedOverrideRequest(
        request.Kind switch
        {
          App.ImportReviewedOverrideKind.BondLevel =>
              ImportProfile.SanitizedProfileReviewedOverrideKind.BondLevel,
          App.ImportReviewedOverrideKind.EquipmentManufacturerMatched =>
              ImportProfile.SanitizedProfileReviewedOverrideKind.EquipmentManufacturerMatched,
          _ => throw Failure(
              App.ProfileManagementFailureKind.InvalidRequest,
              "import_review_override_kind_invalid")
        },
        request.CharacterUid,
        request.EquipmentSlot switch
        {
          App.ImportEquipmentSlot.Head => ImportProfile.ProfileImportEquipmentSlot.Head,
          App.ImportEquipmentSlot.Torso => ImportProfile.ProfileImportEquipmentSlot.Torso,
          App.ImportEquipmentSlot.Arms => ImportProfile.ProfileImportEquipmentSlot.Arms,
          App.ImportEquipmentSlot.Legs => ImportProfile.ProfileImportEquipmentSlot.Legs,
          null => null,
          _ => throw Failure(
              App.ProfileManagementFailureKind.InvalidRequest,
              "import_review_equipment_slot_invalid")
        },
        request.IntegerValue,
        request.BooleanValue,
        request.ReasonCode)).ToArray();
  }

  private ImportProfile.SanitizedProfileDraft ApplyReviewedOverrides(
      ImportProfile.SanitizedProfileDraft source,
      IReadOnlyList<ImportProfile.SanitizedProfileReviewedOverrideRequest> requests,
      DateTimeOffset materializedAtUtc)
  {
    try
    {
      return ImportProfile.SanitizedProfileDraftJsonCodec.ApplyReviewedOverrides(
          source,
          materializedAtUtc,
          _transformerBinarySha256,
          requests);
    }
    catch (ImportProfile.SanitizedProfileDraftCodecException exception)
    {
      throw Failure(App.ProfileManagementFailureKind.Unprocessable, exception.Code);
    }
  }

  private static Sha256Digest ComputeReviewedOverrideDiff(App.ReviewImportDraftCommand command)
  {
    var descriptor = JsonSerializer.Serialize(
        new ReviewedOverrideDescriptor(
            command.DraftUid.ToString(),
            command.ExpectedDraftSha256.ToString(),
            command.Overrides
                .OrderBy(static item => ReviewedOverrideKindCode(item.Kind), StringComparer.Ordinal)
                .ThenBy(static item => item.CharacterUid.ToString(), StringComparer.Ordinal)
                .ThenBy(static item => ReviewedOverrideSlotCode(item.EquipmentSlot), StringComparer.Ordinal)
                .Select(static item => new ReviewedOverrideWire(
                    ReviewedOverrideKindCode(item.Kind),
                    item.CharacterUid.ToString(),
                    ReviewedOverrideSlotCode(item.EquipmentSlot),
                    item.IntegerValue,
                    item.BooleanValue,
                    item.ReasonCode))
                .ToArray()),
        JsonOptions);
    return Sha256Digest.ComputeUtf8(descriptor);
  }

  private static IReadOnlyList<App.ProfileDiffEntry> ReviewedOverrideChanges(
      ImportProfile.SanitizedProfileDraft source,
      ImportProfile.SanitizedProfileDraft reviewed,
      IReadOnlyList<ImportProfile.SanitizedProfileReviewedOverrideRequest> requests)
  {
    var sourceBuilds = source.Builds.ToDictionary(static build => build.CharacterUid);
    var reviewedBuilds = reviewed.Builds.ToDictionary(static build => build.CharacterUid);
    return requests
        .OrderBy(static item => item.Kind)
        .ThenBy(static item => item.CharacterUid.ToString(), StringComparer.Ordinal)
        .ThenBy(static item => item.EquipmentSlot)
        .Select(request =>
        {
          var sourceBuild = sourceBuilds[request.CharacterUid];
          var reviewedBuild = reviewedBuilds[request.CharacterUid];
          if (request.Kind == ImportProfile.SanitizedProfileReviewedOverrideKind.BondLevel)
          {
            return new App.ProfileDiffEntry(
                "bond_level",
                request.CharacterUid,
                ImportFactValue("bond_level", request.CharacterUid, sourceBuild.ResolvedBondLevel),
                ImportFactValue("bond_level", request.CharacterUid, reviewedBuild.ResolvedBondLevel));
          }

          var slot = request.EquipmentSlot ??
              throw Failure(
                  App.ProfileManagementFailureKind.InvalidRequest,
                  "import_review_equipment_slot_missing");
          var fieldCode = $"equipment.{ImportEquipmentSlotCode(slot)}.manufacturer_matched";
          var sourceEquipment = sourceBuild.Equipment.Single(item => item.Slot == slot);
          var reviewedEquipment = reviewedBuild.Equipment.Single(item => item.Slot == slot);
          return new App.ProfileDiffEntry(
              fieldCode,
              request.CharacterUid,
              ImportFactValue(
                  fieldCode,
                  request.CharacterUid,
                  sourceEquipment.ResolvedManufacturerMatched!),
              ImportFactValue(
                  fieldCode,
                  request.CharacterUid,
                  reviewedEquipment.ResolvedManufacturerMatched!));
        }).ToArray();
  }

  private static string ReviewedOverrideKindCode(App.ImportReviewedOverrideKind value) => value switch
  {
    App.ImportReviewedOverrideKind.BondLevel => "bond_level",
    App.ImportReviewedOverrideKind.EquipmentManufacturerMatched =>
        "equipment_manufacturer_matched",
    _ => throw Failure(App.ProfileManagementFailureKind.InvalidRequest, "import_review_override_kind_invalid")
  };

  private static string? ReviewedOverrideSlotCode(App.ImportEquipmentSlot? value) => value switch
  {
    App.ImportEquipmentSlot.Head => "head",
    App.ImportEquipmentSlot.Torso => "torso",
    App.ImportEquipmentSlot.Arms => "arms",
    App.ImportEquipmentSlot.Legs => "legs",
    null => null,
    _ => throw Failure(App.ProfileManagementFailureKind.InvalidRequest, "import_review_equipment_slot_invalid")
  };

  private static Sha256Digest ComputeRebaseDiff(App.RebaseImportCommand command)
  {
    var descriptor = JsonSerializer.Serialize(
        new RebaseDescriptor(
            command.DraftUid.ToString(),
            command.ExpectedDraftSha256.ToString(),
            command.TargetCharacterCatalog.CatalogSnapshotUid.ToString(),
            command.TargetCharacterCatalog.DatasetSnapshotUid.ToString(),
            command.TargetCharacterCatalog.ManifestSha256.ToString(),
            command.TargetCombatSupportCatalog.CatalogSnapshotUid.ToString(),
            command.TargetCombatSupportCatalog.DatasetSnapshotUid.ToString(),
            command.TargetCombatSupportCatalog.ManifestSha256.ToString(),
            command.ExplicitMappings
                .OrderBy(static item => item.Key.ToString(), StringComparer.Ordinal)
                .Select(static item => new UidMappingWire(
                    item.Key.ToString(),
                    item.Value.ToString()))
                .ToArray()),
        JsonOptions);
    return Sha256Digest.ComputeUtf8(descriptor);
  }

  private static IReadOnlyList<App.ProfileDiffEntry> RebaseChanges(
      IReadOnlyDictionary<EntityUid, EntityUid> mappings) => mappings
      .OrderBy(static item => item.Key.ToString(), StringComparer.Ordinal)
      .Select(static item => new App.ProfileDiffEntry(
          "catalog_uid_mapping",
          item.Key,
          new App.ProfileValueProjection(
              "catalog_uid_mapping",
              item.Key,
              "ready",
              ReferenceUid: item.Key),
          new App.ProfileValueProjection(
              "catalog_uid_mapping",
              item.Key,
              "ready",
              ReferenceUid: item.Value)))
      .ToArray();

  private static void ValidateRebaseMappings(
      ImportProfile.SanitizedProfileDraft source,
      IReadOnlyDictionary<EntityUid, EntityUid> mappings)
  {
    ArgumentNullException.ThrowIfNull(mappings);
    if (mappings.Count > 8192 || mappings.Any(static item =>
        item.Key.Value == Guid.Empty || item.Value.Value == Guid.Empty))
    {
      throw Failure(App.ProfileManagementFailureKind.InvalidRequest, "import_rebase_mapping_invalid");
    }

    var referenced = new HashSet<EntityUid>();
    foreach (var console in source.AccountState.Consoles)
    {
      referenced.Add(console.DefinitionUid);
    }

    foreach (var build in source.Builds)
    {
      referenced.Add(build.CharacterUid);
      foreach (var equipment in build.Equipment)
      {
        if (equipment.DefinitionUid is { } definitionUid)
        {
          referenced.Add(definitionUid);
        }

        foreach (var line in equipment.OverloadLines)
        {
          referenced.Add(line.OptionDefinitionUid);
        }
      }

      if (build.Cube.DefinitionUid is { } cubeUid)
      {
        referenced.Add(cubeUid);
      }

      if (build.Collection.DefinitionUid is { } collectionUid)
      {
        referenced.Add(collectionUid);
      }
    }

    if (mappings.Keys.Any(key => !referenced.Contains(key)))
    {
      throw Failure(App.ProfileManagementFailureKind.Unprocessable, "import_rebase_mapping_source_not_found");
    }
  }

  private ImportProfile.SanitizedProfileDraft RebaseSanitizedDraft(
      ImportProfile.SanitizedProfileDraft source,
      App.RebaseImportCommand command,
      DateTimeOffset materializedAtUtc)
  {
    try
    {
      return ImportProfile.SanitizedProfileDraftJsonCodec.Rebase(
          source,
          materializedAtUtc,
          _transformerBinarySha256,
          new ImportProfile.ProfileImportCatalogBinding(
              command.TargetCharacterCatalog.CatalogSnapshotUid,
              command.TargetCharacterCatalog.DatasetSnapshotUid,
              command.TargetCharacterCatalog.ManifestSha256),
          new ImportProfile.ProfileImportCatalogBinding(
              command.TargetCombatSupportCatalog.CatalogSnapshotUid,
              command.TargetCombatSupportCatalog.DatasetSnapshotUid,
              command.TargetCombatSupportCatalog.ManifestSha256),
          command.ExplicitMappings);
    }
    catch (ImportProfile.SanitizedProfileDraftCodecException exception)
    {
      throw Failure(App.ProfileManagementFailureKind.Unprocessable, exception.Code);
    }
  }

  private static void ValidateImportPolicy(
      string levelAuthorityPolicy,
      IReadOnlyList<string> scopes)
  {
    var ordered = scopes?.Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToArray() ?? [];
    if (ordered.Length == 0 || ordered.Length > 3 ||
        ordered.Any(static item => item is not ("full_profile" or "builds_only" or "account_state_only")) ||
        (ordered.Contains("full_profile", StringComparer.Ordinal) && ordered.Length != 1))
    {
      throw Failure(App.ProfileManagementFailureKind.InvalidRequest, "import_scope_set_invalid");
    }

    var replacesBuilds = ordered.Contains("full_profile", StringComparer.Ordinal) ||
        ordered.Contains("builds_only", StringComparer.Ordinal);
    if (replacesBuilds
        ? levelAuthorityPolicy is not (RosterLevelAuthority or DetailLevelAuthority)
        : levelAuthorityPolicy is not (RosterLevelAuthority or DetailLevelAuthority or NoLevelAuthority))
    {
      throw Failure(App.ProfileManagementFailureKind.InvalidRequest, "level_authority_invalid");
    }
  }

  private static void ValidateCreateImportPolicy(
      string levelAuthorityPolicy,
      IReadOnlyList<string> scopes)
  {
    if (scopes is null || scopes.Count != 1 ||
        !string.Equals(scopes[0], "full_profile", StringComparison.Ordinal))
    {
      throw Failure(App.ProfileManagementFailureKind.InvalidRequest, "import_create_scope_invalid");
    }

    if (levelAuthorityPolicy is not (RosterLevelAuthority or DetailLevelAuthority))
    {
      throw Failure(App.ProfileManagementFailureKind.InvalidRequest, "level_authority_invalid");
    }
  }

  private static App.WalletBalanceProjection[] RequireWalletBalances(
      IReadOnlyList<App.WalletBalanceProjection>? values)
  {
    var balances = values?.OrderBy(static item => item.CurrencyCode, StringComparer.Ordinal)
        .ToArray() ?? [];
    if (balances.Length != 2 ||
        !balances.Select(static item => item.CurrencyCode)
            .SequenceEqual(["credit", "jewel"], StringComparer.Ordinal) ||
        balances.Any(static item => item.Balance < 0))
    {
      throw Failure(App.ProfileManagementFailureKind.InvalidRequest, "wallet_balance_set_invalid");
    }

    return balances;
  }

  private static LocalGameUidFact UidFact(EntityUid? value) => value is { } uid
      ? LocalGameUidFact.Ready(uid)
      : LocalGameUidFact.Unresolved("presentation_binding_unresolved");

  private static IReadOnlyList<LocalClientFeatureEntry> BuiltInFeatures()
  {
    static LocalClientFeatureEntry Entry(
        string route,
        LocalClientFeatureCapability capability) => new(route, capability);

    return
    [
      Entry("lobby.profile", LocalClientFeatureCapability.Supported),
      Entry("lobby.wallet", LocalClientFeatureCapability.Supported),
      Entry("lobby.nikke", LocalClientFeatureCapability.Supported),
      Entry("lobby.squad", LocalClientFeatureCapability.Supported),
      Entry("lobby.inventory", LocalClientFeatureCapability.Supported),
      Entry("lobby.recruit", LocalClientFeatureCapability.VisibleNoOp),
      Entry("lobby.messenger", LocalClientFeatureCapability.Hidden),
      Entry("lobby.tracing_the_stars", LocalClientFeatureCapability.Hidden),
      Entry("lobby.costume_pick", LocalClientFeatureCapability.Hidden),
      Entry("lobby.trail_marker", LocalClientFeatureCapability.Hidden),
      Entry("lobby.more", LocalClientFeatureCapability.Hidden),
      Entry("lobby.pickup_banner", LocalClientFeatureCapability.Hidden),
      Entry("lobby.right_side", LocalClientFeatureCapability.Hidden),
      Entry("lobby.shop", LocalClientFeatureCapability.Hidden),
      Entry("lobby.cash_shop", LocalClientFeatureCapability.Hidden),
      Entry("lobby.outpost", LocalClientFeatureCapability.Hidden),
      Entry("lobby.outpost_defense", LocalClientFeatureCapability.Hidden),
      Entry("lobby.solo_raid", LocalClientFeatureCapability.Hidden),
      Entry("solo_raid.normal_battle", LocalClientFeatureCapability.NotSupported),
      Entry("solo_raid.quick_battle", LocalClientFeatureCapability.NotSupported),
      Entry("solo_raid.challenge", LocalClientFeatureCapability.NotSupported)
    ];
  }

  private static App.CatalogBindingProjection MapBinding(
      LocalProfileCatalogBindingWrite value) => new(
          value.CatalogSnapshotUid,
          value.DatasetSnapshotUid,
          value.CatalogManifestSha256);

  private static LocalProfileCatalogBindingWrite MapBinding(
      App.CatalogBindingProjection value) => new(
          value.CatalogSnapshotUid,
          value.DatasetSnapshotUid,
          value.ManifestSha256);

  private DateTimeOffset Now()
  {
    var now = _timeProvider.GetUtcNow().ToUniversalTime();
    return new DateTimeOffset(now.Ticks - now.Ticks % 10, TimeSpan.Zero);
  }

  private static Sha256Digest ComputeTransformerBinarySha256()
  {
    var location = typeof(ImportProfile.SanitizedProfileDraftJsonCodec).Assembly.Location;
    if (string.IsNullOrWhiteSpace(location) || !File.Exists(location))
    {
      throw new InvalidOperationException("profile_transformer_binary_unavailable");
    }

    return Sha256Digest.FromBytes(SHA256.HashData(File.ReadAllBytes(location)));
  }

  private static int CheckedInt(long value, string code)
  {
    if (value is < int.MinValue or > int.MaxValue)
    {
      throw Failure(App.ProfileManagementFailureKind.InvalidRequest, code);
    }

    return (int)value;
  }

  private static int ParseVersion(string value)
  {
    var index = value.LastIndexOf('v');
    return index >= 0 && int.TryParse(value[(index + 1)..], out var version) && version > 0
        ? version
        : 1;
  }

  private static string ProfileFactStatus(LocalProfileFactStatus value) => value switch
  {
    LocalProfileFactStatus.Ready => "ready",
    LocalProfileFactStatus.Unresolved => "unresolved",
    LocalProfileFactStatus.NotApplicable => "not_applicable",
    _ => throw Failure(App.ProfileManagementFailureKind.Unprocessable, "profile_fact_status_invalid")
  };

  private static string SessionCode(LocalSessionStatus value) => value switch
  {
    LocalSessionStatus.Active => "active",
    LocalSessionStatus.Expired => "expired",
    LocalSessionStatus.Revoked => "revoked",
    _ => throw Failure(App.ProfileManagementFailureKind.Unprocessable, "session_status_invalid")
  };

  private static EntityUid? ParseOptionalUid(string? value)
  {
    if (value is null)
    {
      return null;
    }

    if (!Guid.TryParseExact(value, "D", out var uid) || uid == Guid.Empty)
    {
      throw Failure(App.ProfileManagementFailureKind.Unprocessable, "profile_candidate_uid_invalid");
    }

    return new EntityUid(uid);
  }

  private static JsonElement? FindProperty(JsonElement element, string name)
  {
    if (element.ValueKind != JsonValueKind.Object)
    {
      return null;
    }

    foreach (var property in element.EnumerateObject())
    {
      if (string.Equals(property.Name, name, StringComparison.OrdinalIgnoreCase))
      {
        return property.Value;
      }
    }

    return null;
  }

  private static EntityUid? ReadUid(JsonElement? element)
  {
    if (element is not { } value)
    {
      return null;
    }

    string? text = value.ValueKind == JsonValueKind.String
        ? value.GetString()
        : FindProperty(value, "value")?.GetString();
    return Guid.TryParseExact(text, "D", out var uid) && uid != Guid.Empty
        ? new EntityUid(uid)
        : null;
  }

  private static async Task<T> TranslateAsync<T>(Func<Task<T>> action)
  {
    try
    {
      return await action().ConfigureAwait(false);
    }
    catch (App.ProfileManagementException)
    {
      throw;
    }
    catch (LocalGameStateIntegrityException exception)
    {
      throw MapFailure(exception.Code);
    }
    catch (LocalAccountProfileIntegrityException exception)
    {
      throw MapFailure(exception.Code);
    }
    catch (NpgsqlException)
    {
      throw Failure(App.ProfileManagementFailureKind.Unavailable, "profile_database_unavailable");
    }
  }

  private static App.ProfileManagementException MapFailure(string code)
  {
    var kind = code.Contains("not_found", StringComparison.Ordinal)
        ? App.ProfileManagementFailureKind.NotFound
        : code.Contains("conflict", StringComparison.Ordinal) ||
          code.Contains("reuse_mismatch", StringComparison.Ordinal) ||
          code.Contains("stale", StringComparison.Ordinal)
            ? App.ProfileManagementFailureKind.Conflict
            : code.Contains("database", StringComparison.Ordinal)
                ? App.ProfileManagementFailureKind.Unavailable
                : App.ProfileManagementFailureKind.Unprocessable;
    return Failure(kind, code);
  }

  private static App.ProfileManagementException Failure(
      App.ProfileManagementFailureKind kind,
      string code) => new(kind, code);

  private PostgreSqlProfileCatalogAliasResolverFactory RequireCatalogResolverFactory() =>
      _catalogResolverFactory ?? throw Failure(
          App.ProfileManagementFailureKind.Unavailable,
          "profile_catalog_validator_not_configured");

  private sealed record WriteDiffResolution(
      ProfileDraftDiffDocument Diff,
      App.ProfileWriteReceipt? Recovered);

  private sealed record ApplicationPreparation(
      LinkProfileDraftApplicationCommand Application,
      ProfileDraftDiffDocument Diff);

  private sealed record CandidateEnvelope(
      string DraftKind,
      string AccountUid,
      string BaseProfileRevisionUid,
      IReadOnlyList<ProfileEditOperationWire> Operations);

  private sealed record ProfileEditOperationWire(
      string FieldCode,
      string? SubjectUid,
      string ValueKind,
      long? IntegerValue,
      bool? BooleanValue,
      string? ReferenceUid,
      long? UnscaledValue,
      int? DecimalScale,
      string? ControlledValue);

  private sealed record DiffEnvelope(
      string DiffKind,
      string CandidateDraftUid,
      string CandidateSha256,
      string TargetAccountUid,
      string BaseProfileRevisionUid,
      string? LevelAuthorityPolicy,
      IReadOnlyList<string>? Scopes,
      IReadOnlyList<DiffEntryWire> Changes);

  private sealed record CreateImportDiffEnvelope(
      string DiffKind,
      string DraftUid,
      string DraftSha256,
      string LevelAuthorityPolicy,
      IReadOnlyList<string> Scopes,
      IReadOnlyList<DiffEntryWire> Changes);

  private sealed record DiffEntryWire(string FieldCode, string? SubjectUid);

  private sealed record RebaseDescriptor(
      string SourceDraftUid,
      string SourceDraftSha256,
      string CharacterCatalogUid,
      string CharacterDatasetUid,
      string CharacterManifestSha256,
      string SupportCatalogUid,
      string SupportDatasetUid,
      string SupportManifestSha256,
      IReadOnlyList<UidMappingWire> Mappings);

  private sealed record UidMappingWire(string FromUid, string ToUid);

  private sealed record ReviewedOverrideDescriptor(
      string SourceDraftUid,
      string SourceDraftSha256,
      IReadOnlyList<ReviewedOverrideWire> Overrides);

  private sealed record ReviewedOverrideWire(
      string Kind,
      string CharacterUid,
      string? EquipmentSlot,
      int? IntegerValue,
      bool? BooleanValue,
      string ReasonCode);
}
