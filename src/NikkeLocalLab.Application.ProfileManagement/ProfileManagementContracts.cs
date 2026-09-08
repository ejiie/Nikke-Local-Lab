using System.Buffers;
using System.Globalization;
using System.Text;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Application.ProfileManagement;

public enum ProfileManagementFailureKind
{
  InvalidRequest,
  NotFound,
  Conflict,
  Unprocessable,
  Unavailable
}

public sealed class ProfileManagementException : Exception
{
  public ProfileManagementException(ProfileManagementFailureKind kind, string code)
      : base(ControlledCode.Require(code, nameof(code)))
  {
    Kind = kind;
    Code = code;
  }

  public ProfileManagementFailureKind Kind { get; }

  public string Code { get; }
}

public sealed record RevisionReference(
    EntityUid RevisionUid,
    Sha256Digest ContentSha256,
    int RevisionNumber);

public sealed record CatalogBindingProjection(
    EntityUid CatalogSnapshotUid,
    EntityUid DatasetSnapshotUid,
    Sha256Digest ManifestSha256);

public sealed record ProfileIssueProjection(
    string Code,
    string Severity,
    string? FieldCode = null,
    EntityUid? SubjectUid = null);

public sealed record ProfileValueProjection(
    string FieldCode,
    EntityUid? SubjectUid,
    string Status,
    long? IntegerValue = null,
    bool? BooleanValue = null,
    EntityUid? ReferenceUid = null,
    long? UnscaledValue = null,
    int? DecimalScale = null,
    string? ControlledValue = null,
    string? ReasonCode = null);

public sealed record ProfileEditOperation(
    string FieldCode,
    EntityUid? SubjectUid,
    string ValueKind,
    long? IntegerValue = null,
    bool? BooleanValue = null,
    EntityUid? ReferenceUid = null,
    long? UnscaledValue = null,
    int? DecimalScale = null,
    string? ControlledValue = null)
{
  public void Validate()
  {
    ControlledCode.Require(FieldCode, nameof(FieldCode));
    ControlledCode.Require(ValueKind, nameof(ValueKind));
    if (ControlledValue is not null)
    {
      ControlledCode.Require(ControlledValue, nameof(ControlledValue));
    }

    var scalarCount = (IntegerValue is null ? 0 : 1) +
        (BooleanValue is null ? 0 : 1) +
        (ReferenceUid is null ? 0 : 1) +
        (UnscaledValue is null && DecimalScale is null ? 0 : 1) +
        (ControlledValue is null ? 0 : 1);
    if (scalarCount != 1 || (UnscaledValue is null) != (DecimalScale is null) || DecimalScale is < 0 or > 12)
    {
      throw new ProfileManagementException(
          ProfileManagementFailureKind.InvalidRequest,
          "profile_edit_value_invalid");
    }

    var kindMatchesValue = ValueKind switch
    {
      "integer" => IntegerValue is not null,
      "boolean" => BooleanValue is not null,
      "reference" => ReferenceUid is not null,
      "exact_decimal" => UnscaledValue is not null && DecimalScale is not null,
      "controlled" => ControlledValue is not null,
      _ => false
    };
    if (!kindMatchesValue)
    {
      throw new ProfileManagementException(
          ProfileManagementFailureKind.InvalidRequest,
          "profile_edit_value_kind_mismatch");
    }
  }
}

public sealed record CurrentProfileProjection(
    EntityUid AccountUid,
    RevisionReference ProfileRevision,
    CatalogBindingProjection CharacterCatalog,
    CatalogBindingProjection CombatSupportCatalog,
    bool IsSelectionReady,
    bool HasCompleteCombatSemantics,
    bool IsGameLegalReady,
    IReadOnlyList<ProfileValueProjection> Values,
    IReadOnlyList<ProfileIssueProjection> Issues);

public sealed record ProfileDiffEntry(
    string FieldCode,
    EntityUid? SubjectUid,
    ProfileValueProjection? Before,
    ProfileValueProjection? After);

public sealed record ProfileDiffProjection(
    Sha256Digest DiffSha256,
    EntityUid TargetAccountUid,
    EntityUid ExpectedProfileRevisionUid,
    EntityUid CandidateDraftUid,
    Sha256Digest CandidateSha256,
    IReadOnlyList<ProfileDiffEntry> Changes,
    IReadOnlyList<ProfileIssueProjection> Issues);

public sealed record ProfileEditPreviewCommand(
    EntityUid OperationUid,
    EntityUid AccountUid,
    EntityUid ExpectedProfileRevisionUid,
    IReadOnlyList<ProfileEditOperation> Operations);

public sealed record SaveProfileCommand(
    EntityUid OperationUid,
    EntityUid AccountUid,
    EntityUid ExpectedProfileRevisionUid,
    EntityUid CandidateDraftUid,
    Sha256Digest CandidateSha256,
    Sha256Digest ExpectedDiffSha256);

public sealed record SaveAsProfileCommand(
    EntityUid OperationUid,
    EntityUid SourceAccountUid,
    EntityUid ExpectedSourceProfileRevisionUid,
    EntityUid? CandidateDraftUid,
    Sha256Digest? CandidateSha256,
    Sha256Digest ExpectedDiffSha256,
    string? AccountLabel = null);

public sealed record ProfileWriteReceipt(
    EntityUid OperationUid,
    bool IsIdempotentReplay,
    EntityUid AccountUid,
    RevisionReference ProfileRevision,
    IReadOnlyList<ProfileIssueProjection> Issues);

public sealed record SourceFreeImportDraftProjection(
    string ContractId,
    EntityUid DraftUid,
    Sha256Digest DraftSha256,
    DateTimeOffset MaterializedAtUtc,
    CatalogBindingProjection CharacterCatalog,
    CatalogBindingProjection CombatSupportCatalog,
    IReadOnlyList<ProfileObservationProjection> Observations,
    IReadOnlyList<ProfileValueProjection> Values,
    IReadOnlyList<ProfileIssueProjection> Issues,
    string DerivationKind,
    EntityUid? PreviousDraftUid,
    IReadOnlyList<ImportReviewedOverrideProjection> ReviewedOverrides);

public sealed record FetchedAccountSnapshotProjection(
    EntityUid SnapshotUid,
    EntityUid TargetAccountUid,
    EntityUid SanitizedDraftUid,
    DateTimeOffset CapturedAtUtc,
    string? DisplayName,
    int? CommanderLevel,
    string CompletenessStatusCode,
    int RosterCount,
    int CharacterDetailCount,
    int EquipmentCharacterCount,
    int MissingCharacterCount,
    Sha256Digest CanonicalSnapshotSha256,
    DateTimeOffset ImportedAtUtc,
    bool IsCurrentWorkspaceSnapshot,
    FetchedProgressionObservationProjection? Progression);

public sealed record FetchedLobbyFieldDiffProjection(
    string FieldCode,
    string ValueKind,
    string? BeforeText,
    string? AfterText,
    int? BeforeInteger,
    int? AfterInteger);

public sealed record FetchedLobbyDiffProjection(
    Sha256Digest DiffSha256,
    EntityUid SnapshotUid,
    Sha256Digest SnapshotSha256,
    EntityUid TargetAccountUid,
    EntityUid ExpectedLobbyRevisionUid,
    IReadOnlyList<string> Fields,
    IReadOnlyList<FetchedLobbyFieldDiffProjection> Changes);

public sealed record PreviewFetchedLobbyDiffCommand(
    EntityUid OperationUid,
    EntityUid SnapshotUid,
    EntityUid TargetAccountUid,
    EntityUid ExpectedLobbyRevisionUid,
    IReadOnlyList<string> Fields);

public sealed record ApplyFetchedLobbyCommand(
    EntityUid OperationUid,
    EntityUid SnapshotUid,
    EntityUid TargetAccountUid,
    EntityUid ExpectedLobbyRevisionUid,
    Sha256Digest ExpectedDiffSha256,
    IReadOnlyList<string> Fields);

public sealed record ApplyFetchedLobbyProjection(
    FetchedLobbyDiffProjection Diff,
    LobbyPresentationProjection Lobby);

public sealed record FetchedProgressionObservationProjection(
    string ContractId,
    string CompletenessStatusCode,
    int AvailableComponentCount,
    int DerivedComponentCount,
    int UnavailableComponentCount,
    int? CompletedScenarioCount,
    int? MainQuestCompletedCount,
    int? MainQuestRewardClaimedCount,
    int? ContentsOpenUnlockedCount,
    int? StageClearHistoryCount,
    int? TriggerCount,
    Sha256Digest CanonicalObservationSha256);

public sealed record RegisterFetchedAccountSnapshotCommand(
    EntityUid TargetAccountUid,
    EntityUid ExpectedProfileRevisionUid,
    string CanonicalSnapshotJson,
    string CanonicalSanitizedDraftJson,
    string? CanonicalProgressionObservationJson = null);

public sealed record ProfileObservationProjection(
    EntityUid CharacterUid,
    string ObservationKind,
    long? ObservedValue,
    string Status,
    string? ReasonCode = null);

public sealed record ImportDiffCommand(
    EntityUid OperationUid,
    EntityUid DraftUid,
    Sha256Digest ExpectedDraftSha256,
    EntityUid TargetAccountUid,
    EntityUid ExpectedProfileRevisionUid,
    string LevelAuthorityPolicy,
    IReadOnlyList<string> Scopes);

public sealed record CreateImportDiffCommand(
    EntityUid OperationUid,
    EntityUid DraftUid,
    Sha256Digest ExpectedDraftSha256,
    string LevelAuthorityPolicy,
    IReadOnlyList<string> Scopes);

public sealed record CreateImportDiffProjection(
    Sha256Digest DiffSha256,
    EntityUid DraftUid,
    Sha256Digest DraftSha256,
    IReadOnlyList<ProfileDiffEntry> Changes,
    IReadOnlyList<ProfileIssueProjection> Issues);

public sealed record ApplyImportCommand(
    EntityUid OperationUid,
    EntityUid DraftUid,
    Sha256Digest ExpectedDraftSha256,
    EntityUid TargetAccountUid,
    EntityUid ExpectedProfileRevisionUid,
    Sha256Digest ExpectedDiffSha256,
    string LevelAuthorityPolicy,
    IReadOnlyList<string> Scopes);

public sealed record CreateFromImportCommand(
    EntityUid OperationUid,
    EntityUid DraftUid,
    Sha256Digest ExpectedDraftSha256,
    Sha256Digest ExpectedDiffSha256,
    string LevelAuthorityPolicy,
    IReadOnlyList<string> Scopes);

public sealed record RebaseImportCommand(
    EntityUid OperationUid,
    EntityUid DraftUid,
    Sha256Digest ExpectedDraftSha256,
    CatalogBindingProjection TargetCharacterCatalog,
    CatalogBindingProjection TargetCombatSupportCatalog,
    IReadOnlyDictionary<EntityUid, EntityUid> ExplicitMappings,
    Sha256Digest? ExpectedDiffSha256 = null);

public sealed record RebasePreviewProjection(
    EntityUid SourceDraftUid,
    Sha256Digest SourceDraftSha256,
    Sha256Digest DiffSha256,
    CatalogBindingProjection TargetCharacterCatalog,
    CatalogBindingProjection TargetCombatSupportCatalog,
    IReadOnlyList<ProfileDiffEntry> Changes,
    IReadOnlyList<ProfileIssueProjection> Issues);

public enum ImportReviewedOverrideKind
{
  BondLevel,
  EquipmentManufacturerMatched
}

public enum ImportEquipmentSlot
{
  Head,
  Torso,
  Arms,
  Legs
}

public sealed record ImportReviewedOverrideRequest(
    ImportReviewedOverrideKind Kind,
    EntityUid CharacterUid,
    ImportEquipmentSlot? EquipmentSlot,
    int? IntegerValue,
    bool? BooleanValue,
    string ReasonCode);

public sealed record ImportReviewedOverrideProjection(
    string KindCode,
    EntityUid CharacterUid,
    string? EquipmentSlotCode,
    int? IntegerValue,
    bool? BooleanValue,
    string OriginalReasonCode,
    string ReasonCode);

public sealed record ReviewImportDraftCommand(
    EntityUid OperationUid,
    EntityUid DraftUid,
    Sha256Digest ExpectedDraftSha256,
    IReadOnlyList<ImportReviewedOverrideRequest> Overrides,
    Sha256Digest? ExpectedDiffSha256 = null);

public sealed record ReviewImportDraftPreviewProjection(
    EntityUid SourceDraftUid,
    Sha256Digest SourceDraftSha256,
    Sha256Digest DiffSha256,
    IReadOnlyList<ProfileDiffEntry> Changes,
    IReadOnlyList<ProfileIssueProjection> Issues);

public sealed record LobbyPresentationProjection(
    EntityUid AccountUid,
    RevisionReference Revision,
    string DisplayName,
    int CommanderLevel,
    EntityUid? ProfileIconSelectionUid,
    EntityUid? ProfileFrameSelectionUid,
    EntityUid? LobbyCharacterSelectionUid,
    EntityUid? LobbyBackgroundSelectionUid);

public sealed record SaveLobbyPresentationCommand
{
  public SaveLobbyPresentationCommand(
      EntityUid operationUid,
      EntityUid accountUid,
      EntityUid expectedRevisionUid,
      string displayName,
      int commanderLevel,
      EntityUid? profileIconSelectionUid,
      EntityUid? profileFrameSelectionUid,
      EntityUid? lobbyCharacterSelectionUid,
      EntityUid? lobbyBackgroundSelectionUid)
  {
    if (operationUid.Value == Guid.Empty || accountUid.Value == Guid.Empty ||
        expectedRevisionUid.Value == Guid.Empty || commanderLevel is < 1 or > 1_000_000)
    {
      throw new ProfileManagementException(
          ProfileManagementFailureKind.InvalidRequest,
          "lobby_presentation_value_invalid");
    }

    OperationUid = operationUid;
    AccountUid = accountUid;
    ExpectedRevisionUid = expectedRevisionUid;
    DisplayName = ProfileManagementText.NormalizeDisplayName(displayName);
    CommanderLevel = commanderLevel;
    ProfileIconSelectionUid = RequireOptionalUid(profileIconSelectionUid);
    ProfileFrameSelectionUid = RequireOptionalUid(profileFrameSelectionUid);
    LobbyCharacterSelectionUid = RequireOptionalUid(lobbyCharacterSelectionUid);
    LobbyBackgroundSelectionUid = RequireOptionalUid(lobbyBackgroundSelectionUid);
  }

  public EntityUid OperationUid { get; }

  public EntityUid AccountUid { get; }

  public EntityUid ExpectedRevisionUid { get; }

  public string DisplayName { get; }

  public int CommanderLevel { get; }

  public EntityUid? ProfileIconSelectionUid { get; }

  public EntityUid? ProfileFrameSelectionUid { get; }

  public EntityUid? LobbyCharacterSelectionUid { get; }

  public EntityUid? LobbyBackgroundSelectionUid { get; }

  private static EntityUid? RequireOptionalUid(EntityUid? value)
  {
    if (value is { Value: var uid } && uid == Guid.Empty)
    {
      throw new ProfileManagementException(
          ProfileManagementFailureKind.InvalidRequest,
          "lobby_presentation_value_invalid");
    }

    return value;
  }
}

public static class ProfileManagementText
{
  public static string NormalizeAccountLabel(string value) =>
      NormalizeHumanLabel(value, 64, "account_label_invalid");

  public static string NormalizeDisplayName(string value)
      => NormalizeHumanLabel(value, 32, "lobby_presentation_value_invalid");

  private static string NormalizeHumanLabel(string value, int maximumLength, string failureCode)
  {
    if (value is null)
    {
      throw new ProfileManagementException(
          ProfileManagementFailureKind.InvalidRequest,
          failureCode);
    }

    var normalized = value.Trim().Normalize(NormalizationForm.FormC);
    if (normalized.Contains('/') || normalized.Contains('\\') || normalized.Contains(':') ||
        normalized.StartsWith("file:", StringComparison.OrdinalIgnoreCase))
    {
      throw new ProfileManagementException(
          ProfileManagementFailureKind.InvalidRequest,
          failureCode);
    }

    var count = 0;
    var remaining = normalized.AsSpan();
    while (!remaining.IsEmpty)
    {
      var status = Rune.DecodeFromUtf16(remaining, out var rune, out var consumed);
      if (status != OperationStatus.Done)
      {
        throw new ProfileManagementException(
            ProfileManagementFailureKind.InvalidRequest,
            failureCode);
      }

      var category = Rune.GetUnicodeCategory(rune);
      if (category is UnicodeCategory.Control or UnicodeCategory.Format or UnicodeCategory.Surrogate)
      {
        throw new ProfileManagementException(
            ProfileManagementFailureKind.InvalidRequest,
            failureCode);
      }

      count++;
      remaining = remaining[consumed..];
    }

    if (count < 1 || count > maximumLength)
    {
      throw new ProfileManagementException(
          ProfileManagementFailureKind.InvalidRequest,
          failureCode);
    }

    return normalized;
  }
}

public sealed record WalletBalanceProjection(string CurrencyCode, long Balance);

public sealed record WalletProjection(
    EntityUid AccountUid,
    RevisionReference Revision,
    IReadOnlyList<WalletBalanceProjection> Balances);

public sealed record SaveWalletCommand(
    EntityUid OperationUid,
    EntityUid AccountUid,
    EntityUid ExpectedRevisionUid,
    IReadOnlyList<WalletBalanceProjection> Balances);

public sealed record InitializeLocalStateCommand(
    EntityUid OperationUid,
    EntityUid AccountUid,
    EntityUid ExpectedProfileRevisionUid,
    EntityUid FeatureManifestUid,
    Sha256Digest ExpectedFeatureManifestSha256,
    string DisplayName,
    int CommanderLevel,
    EntityUid? ProfileIconSelectionUid,
    EntityUid? ProfileFrameSelectionUid,
    EntityUid? LobbyCharacterSelectionUid,
    EntityUid? LobbyBackgroundSelectionUid,
    IReadOnlyList<WalletBalanceProjection> Balances);

public sealed record FeatureCapabilityProjection(
    string FeatureCode,
    string Availability,
    bool ReadOnly,
    string? InteractionCode = null);

public sealed record ClientFeatureManifestProjection(
    EntityUid ManifestUid,
    string ContractId,
    int Version,
    Sha256Digest ContentSha256,
    IReadOnlyList<FeatureCapabilityProjection> Features);

public sealed record InventoryItemProjection(
    EntityUid? InventoryItemUid,
    string ItemKind,
    EntityUid CharacterUid,
    EntityUid BuildRevisionUid,
    string? SlotCode,
    string State,
    EntityUid? DefinitionUid,
    EntityUid? DefinitionVersionUid,
    IReadOnlyList<ProfileValueProjection> Values);

public sealed record InventorySubsetProjection(
    string ProjectionKind,
    RevisionReference ProfileRevision,
    bool IsCompleteInventory,
    bool IsReadOnly,
    IReadOnlyList<InventoryItemProjection> Items);

public sealed record RosterEntryProjection(
    EntityUid CharacterUid,
    EntityUid CharacterBuildUid,
    EntityUid BuildRevisionUid,
    Sha256Digest BuildContentSha256,
    bool IsSelectionReady,
    bool HasCompleteCombatSemantics);

public sealed record SquadMemberProjection(
    int Position,
    EntityUid CharacterUid,
    EntityUid CharacterBuildUid,
    EntityUid BuildRevisionUid);

public sealed record SquadProjection(
    EntityUid SquadUid,
    EntityUid SquadRevisionUid,
    IReadOnlyList<SquadMemberProjection> Members);

public sealed record LocalSessionProjection(
    EntityUid SessionUid,
    EntityUid AccountUid,
    DateTimeOffset IssuedAtUtc,
    DateTimeOffset ExpiresAtUtc,
    DateTimeOffset? RevokedAtUtc,
    string Status);

public sealed record AccountBootstrapProjection(
    EntityUid AccountUid,
    Sha256Digest RevisionSetSha256,
    CurrentProfileProjection Profile,
    LobbyPresentationProjection Lobby,
    WalletProjection Wallet,
    ClientFeatureManifestProjection FeatureManifest,
    IReadOnlyList<RosterEntryProjection> Roster,
    SquadProjection? Squad,
    InventorySubsetProjection Inventory);

public interface IProfileManagementService
{
  Task<IReadOnlyList<AccountSummaryProjection>> ListAccountsAsync(
      CancellationToken cancellationToken = default);

  Task<AccountWorkspaceProjection?> GetAccountWorkspaceAsync(
      EntityUid accountUid,
      CancellationToken cancellationToken = default);

  Task<AccountRevisionHistoryProjection?> GetAccountRevisionHistoryAsync(
      EntityUid accountUid,
      CancellationToken cancellationToken = default);

  Task<AccountSummaryProjection> RenameAccountAsync(
      RenameAccountCommand command,
      CancellationToken cancellationToken = default);

  Task<SaveAccountWorkspaceReceipt> SaveAccountWorkspaceAsync(
      SaveAccountWorkspaceCommand command,
      CancellationToken cancellationToken = default);

  Task<IReadOnlyList<WorkspaceSaveRecoveryProjection>> GetWorkspaceSaveRecoveryAsync(
      EntityUid accountUid, CancellationToken cancellationToken = default);

  Task<SaveAccountWorkspaceReceipt> ResumeWorkspaceSaveAsync(
      ResumeWorkspaceSaveCommand command, CancellationToken cancellationToken = default);

  Task<RuntimeProjectionCandidate?> ExportRuntimeProjectionCandidateAsync(
      EntityUid accountUid,
      CancellationToken cancellationToken = default);

  Task<RuntimeProjectionSnapshot?> GetRuntimeProjectionSnapshotAsync(
      EntityUid accountUid,
      CancellationToken cancellationToken = default);

  Task<AccountBootstrapProjection?> GetCurrentBootstrapAsync(
      EntityUid accountUid,
      CancellationToken cancellationToken = default);

  Task<AccountBootstrapProjection> InitializeLocalStateAsync(
      InitializeLocalStateCommand command,
      CancellationToken cancellationToken = default);

  Task<CurrentProfileProjection?> GetCurrentProfileAsync(
      EntityUid accountUid,
      CancellationToken cancellationToken = default);

  Task<LocalSessionProjection?> GetSessionAsync(
      EntityUid sessionUid,
      DateTimeOffset observedAtUtc,
      CancellationToken cancellationToken = default);

  Task<ProfileDiffProjection> PreviewProfileEditsAsync(
      ProfileEditPreviewCommand command,
      CancellationToken cancellationToken = default);

  Task<ProfileWriteReceipt> SaveProfileAsync(
      SaveProfileCommand command,
      CancellationToken cancellationToken = default);

  Task<ProfileWriteReceipt> SaveAsProfileAsync(
      SaveAsProfileCommand command,
      CancellationToken cancellationToken = default);

  Task<SourceFreeImportDraftProjection?> GetImportDraftAsync(
      EntityUid draftUid,
      CancellationToken cancellationToken = default);

  Task<FetchedAccountSnapshotProjection> RegisterFetchedAccountSnapshotAsync(
      RegisterFetchedAccountSnapshotCommand command,
      CancellationToken cancellationToken = default);

  Task<FetchedAccountSnapshotProjection?> GetFetchedAccountSnapshotAsync(
      EntityUid snapshotUid,
      CancellationToken cancellationToken = default);

  Task<FetchedAccountSnapshotProjection?> GetLatestFetchedAccountSnapshotAsync(
      EntityUid accountUid,
      CancellationToken cancellationToken = default);

  Task<FetchedLobbyDiffProjection> PreviewFetchedLobbyDiffAsync(
      PreviewFetchedLobbyDiffCommand command,
      CancellationToken cancellationToken = default);

  Task<ApplyFetchedLobbyProjection> ApplyFetchedLobbyAsync(
      ApplyFetchedLobbyCommand command,
      CancellationToken cancellationToken = default);

  Task<ProfileDiffProjection> PreviewImportDiffAsync(
      ImportDiffCommand command,
      CancellationToken cancellationToken = default);

  Task<CreateImportDiffProjection> PreviewCreateFromImportAsync(
      CreateImportDiffCommand command,
      CancellationToken cancellationToken = default);

  Task<ProfileWriteReceipt> ApplyImportAsync(
      ApplyImportCommand command,
      CancellationToken cancellationToken = default);

  Task<ProfileWriteReceipt> CreateFromImportAsync(
      CreateFromImportCommand command,
      CancellationToken cancellationToken = default);

  Task<RebasePreviewProjection> PreviewRebaseAsync(
      RebaseImportCommand command,
      CancellationToken cancellationToken = default);

  Task<SourceFreeImportDraftProjection> RebaseImportAsync(
      RebaseImportCommand command,
      CancellationToken cancellationToken = default);

  Task<ReviewImportDraftPreviewProjection> PreviewReviewImportDraftAsync(
      ReviewImportDraftCommand command,
      CancellationToken cancellationToken = default);

  Task<SourceFreeImportDraftProjection> ReviewImportDraftAsync(
      ReviewImportDraftCommand command,
      CancellationToken cancellationToken = default);

  Task<LobbyPresentationProjection?> GetLobbyPresentationAsync(
      EntityUid accountUid,
      CancellationToken cancellationToken = default);

  Task<LobbyPresentationProjection> SaveLobbyPresentationAsync(
      SaveLobbyPresentationCommand command,
      CancellationToken cancellationToken = default);

  Task<WalletProjection?> GetWalletAsync(
      EntityUid accountUid,
      CancellationToken cancellationToken = default);

  Task<WalletProjection> SaveWalletAsync(
      SaveWalletCommand command,
      CancellationToken cancellationToken = default);

  Task<ClientFeatureManifestProjection> GetFeatureManifestAsync(
      CancellationToken cancellationToken = default);
}

public sealed class UnavailableProfileManagementService : IProfileManagementService
{
  private static ProfileManagementException Unavailable() => new(
      ProfileManagementFailureKind.Unavailable,
      "profile_management_not_configured");

  public Task<IReadOnlyList<AccountSummaryProjection>> ListAccountsAsync(
      CancellationToken cancellationToken = default) => throw Unavailable();

  public Task<AccountWorkspaceProjection?> GetAccountWorkspaceAsync(
      EntityUid accountUid,
      CancellationToken cancellationToken = default) => throw Unavailable();

  public Task<AccountRevisionHistoryProjection?> GetAccountRevisionHistoryAsync(
      EntityUid accountUid,
      CancellationToken cancellationToken = default) => throw Unavailable();

  public Task<AccountSummaryProjection> RenameAccountAsync(
      RenameAccountCommand command,
      CancellationToken cancellationToken = default) => throw Unavailable();

  public Task<SaveAccountWorkspaceReceipt> SaveAccountWorkspaceAsync(
      SaveAccountWorkspaceCommand command,
      CancellationToken cancellationToken = default) => throw Unavailable();

  public Task<IReadOnlyList<WorkspaceSaveRecoveryProjection>> GetWorkspaceSaveRecoveryAsync(
      EntityUid accountUid, CancellationToken cancellationToken = default) => throw Unavailable();

  public Task<SaveAccountWorkspaceReceipt> ResumeWorkspaceSaveAsync(
      ResumeWorkspaceSaveCommand command, CancellationToken cancellationToken = default) => throw Unavailable();

  public Task<RuntimeProjectionCandidate?> ExportRuntimeProjectionCandidateAsync(
      EntityUid accountUid,
      CancellationToken cancellationToken = default) => throw Unavailable();

  public Task<RuntimeProjectionSnapshot?> GetRuntimeProjectionSnapshotAsync(
      EntityUid accountUid,
      CancellationToken cancellationToken = default) => throw Unavailable();

  public Task<AccountBootstrapProjection?> GetCurrentBootstrapAsync(
      EntityUid accountUid,
      CancellationToken cancellationToken = default) => throw Unavailable();

  public Task<AccountBootstrapProjection> InitializeLocalStateAsync(
      InitializeLocalStateCommand command,
      CancellationToken cancellationToken = default) => throw Unavailable();

  public Task<CurrentProfileProjection?> GetCurrentProfileAsync(
      EntityUid accountUid,
      CancellationToken cancellationToken = default) => throw Unavailable();

  public Task<LocalSessionProjection?> GetSessionAsync(
      EntityUid sessionUid,
      DateTimeOffset observedAtUtc,
      CancellationToken cancellationToken = default) => throw Unavailable();

  public Task<ProfileDiffProjection> PreviewProfileEditsAsync(
      ProfileEditPreviewCommand command,
      CancellationToken cancellationToken = default) => throw Unavailable();

  public Task<ProfileWriteReceipt> SaveProfileAsync(
      SaveProfileCommand command,
      CancellationToken cancellationToken = default) => throw Unavailable();

  public Task<ProfileWriteReceipt> SaveAsProfileAsync(
      SaveAsProfileCommand command,
      CancellationToken cancellationToken = default) => throw Unavailable();

  public Task<SourceFreeImportDraftProjection?> GetImportDraftAsync(
      EntityUid draftUid,
      CancellationToken cancellationToken = default) => throw Unavailable();

  public Task<FetchedAccountSnapshotProjection> RegisterFetchedAccountSnapshotAsync(
      RegisterFetchedAccountSnapshotCommand command,
      CancellationToken cancellationToken = default) => throw Unavailable();

  public Task<FetchedAccountSnapshotProjection?> GetFetchedAccountSnapshotAsync(
      EntityUid snapshotUid,
      CancellationToken cancellationToken = default) => throw Unavailable();

  public Task<FetchedAccountSnapshotProjection?> GetLatestFetchedAccountSnapshotAsync(
      EntityUid accountUid,
      CancellationToken cancellationToken = default) => throw Unavailable();

  public Task<FetchedLobbyDiffProjection> PreviewFetchedLobbyDiffAsync(
      PreviewFetchedLobbyDiffCommand command,
      CancellationToken cancellationToken = default) => throw Unavailable();

  public Task<ApplyFetchedLobbyProjection> ApplyFetchedLobbyAsync(
      ApplyFetchedLobbyCommand command,
      CancellationToken cancellationToken = default) => throw Unavailable();

  public Task<ProfileDiffProjection> PreviewImportDiffAsync(
      ImportDiffCommand command,
      CancellationToken cancellationToken = default) => throw Unavailable();

  public Task<CreateImportDiffProjection> PreviewCreateFromImportAsync(
      CreateImportDiffCommand command,
      CancellationToken cancellationToken = default) => throw Unavailable();

  public Task<ProfileWriteReceipt> ApplyImportAsync(
      ApplyImportCommand command,
      CancellationToken cancellationToken = default) => throw Unavailable();

  public Task<ProfileWriteReceipt> CreateFromImportAsync(
      CreateFromImportCommand command,
      CancellationToken cancellationToken = default) => throw Unavailable();

  public Task<RebasePreviewProjection> PreviewRebaseAsync(
      RebaseImportCommand command,
      CancellationToken cancellationToken = default) => throw Unavailable();

  public Task<SourceFreeImportDraftProjection> RebaseImportAsync(
      RebaseImportCommand command,
      CancellationToken cancellationToken = default) => throw Unavailable();

  public Task<ReviewImportDraftPreviewProjection> PreviewReviewImportDraftAsync(
      ReviewImportDraftCommand command,
      CancellationToken cancellationToken = default) => throw Unavailable();

  public Task<SourceFreeImportDraftProjection> ReviewImportDraftAsync(
      ReviewImportDraftCommand command,
      CancellationToken cancellationToken = default) => throw Unavailable();

  public Task<LobbyPresentationProjection?> GetLobbyPresentationAsync(
      EntityUid accountUid,
      CancellationToken cancellationToken = default) => throw Unavailable();

  public Task<LobbyPresentationProjection> SaveLobbyPresentationAsync(
      SaveLobbyPresentationCommand command,
      CancellationToken cancellationToken = default) => throw Unavailable();

  public Task<WalletProjection?> GetWalletAsync(
      EntityUid accountUid,
      CancellationToken cancellationToken = default) => throw Unavailable();

  public Task<WalletProjection> SaveWalletAsync(
      SaveWalletCommand command,
      CancellationToken cancellationToken = default) => throw Unavailable();

  public Task<ClientFeatureManifestProjection> GetFeatureManifestAsync(
      CancellationToken cancellationToken = default) => throw Unavailable();
}
