namespace NikkeLocalLab.Admin.Api;

internal sealed record AdminBootstrapRequest(string? Code);

internal sealed record ProfileEditOperationRequest(
    string? FieldCode,
    string? SubjectUid,
    string? ValueKind,
    long? IntegerValue,
    bool? BooleanValue,
    string? ReferenceUid,
    long? UnscaledValue,
    int? DecimalScale,
    string? ControlledValue);

internal sealed record ProfileEditPreviewRequest(
    string? OperationUid,
    IReadOnlyList<ProfileEditOperationRequest>? Operations);

internal sealed record SaveProfileRequest(
    string? OperationUid,
    string? CandidateDraftUid,
    string? CandidateSha256,
    string? ExpectedDiffSha256);

internal sealed record SaveAsProfileRequest(
    string? OperationUid,
    string? CandidateDraftUid,
    string? CandidateSha256,
    string? ExpectedDiffSha256,
    string? AccountLabel);

internal sealed record RenameAccountRequest(
    string? ExpectedAccountLabel,
    string? AccountLabel);

internal sealed record ResumeWorkspaceSaveRequest(string? OperationUid);

internal sealed record SaveAccountWorkspaceRequest(
    string? OperationUid,
    string? ExpectedProfileRevisionUid,
    string? ExpectedLobbyRevisionUid,
    string? ExpectedWalletRevisionUid,
    string? CandidateDraftUid,
    string? CandidateSha256,
    string? ExpectedDiffSha256,
    string? ExpectedAccountLabel,
    string? AccountLabel,
    string? DisplayName,
    int? CommanderLevel,
    string? ProfileIconSelectionUid,
    string? ProfileFrameSelectionUid,
    string? LobbyCharacterSelectionUid,
    string? LobbyBackgroundSelectionUid,
    IReadOnlyList<WalletBalanceRequest>? Balances);

internal sealed record RegisterFetchedAccountSnapshotRequest(
    string? CanonicalSnapshotJson,
    string? CanonicalSanitizedDraftJson,
    string? CanonicalProgressionObservationJson);

internal sealed record FetchedLobbyDiffRequest(
    string? OperationUid,
    string? TargetAccountUid,
    IReadOnlyList<string>? Fields);

internal sealed record ApplyFetchedLobbyRequest(
    string? OperationUid,
    string? TargetAccountUid,
    string? ExpectedDiffSha256,
    IReadOnlyList<string>? Fields);

internal sealed record ImportDiffRequest(
    string? OperationUid,
    string? ExpectedDraftSha256,
    string? TargetAccountUid,
    string? LevelAuthorityPolicy,
    IReadOnlyList<string>? Scopes);

internal sealed record ApplyImportRequest(
    string? OperationUid,
    string? ExpectedDraftSha256,
    string? TargetAccountUid,
    string? ExpectedDiffSha256,
    string? LevelAuthorityPolicy,
    IReadOnlyList<string>? Scopes);

internal sealed record CreateImportDiffRequest(
    string? OperationUid,
    string? ExpectedDraftSha256,
    string? LevelAuthorityPolicy,
    IReadOnlyList<string>? Scopes);

internal sealed record CreateFromImportRequest(
    string? OperationUid,
    string? ExpectedDraftSha256,
    string? ExpectedDiffSha256,
    string? LevelAuthorityPolicy,
    IReadOnlyList<string>? Scopes);

internal sealed record CatalogBindingRequest(
    string? CatalogSnapshotUid,
    string? DatasetSnapshotUid,
    string? ManifestSha256);

internal sealed record ExplicitMappingRequest(string? FromUid, string? ToUid);

internal sealed record RebaseImportRequest(
    string? OperationUid,
    string? ExpectedDraftSha256,
    CatalogBindingRequest? TargetCharacterCatalog,
    CatalogBindingRequest? TargetCombatSupportCatalog,
    IReadOnlyList<ExplicitMappingRequest>? ExplicitMappings,
    string? ExpectedDiffSha256);

internal sealed record ReviewedOverrideRequest(
    string? Kind,
    string? CharacterUid,
    string? EquipmentSlot,
    int? IntegerValue,
    bool? BooleanValue,
    string? ReasonCode);

internal sealed record ReviewImportDraftRequest(
    string? OperationUid,
    string? ExpectedDraftSha256,
    IReadOnlyList<ReviewedOverrideRequest>? Overrides,
    string? ExpectedDiffSha256);

internal sealed record SaveLobbyPresentationRequest(
    string? OperationUid,
    string? DisplayName,
    int? CommanderLevel,
    string? ProfileIconSelectionUid,
    string? ProfileFrameSelectionUid,
    string? LobbyCharacterSelectionUid,
    string? LobbyBackgroundSelectionUid);

internal sealed record WalletBalanceRequest(string? CurrencyCode, long? Balance);

internal sealed record SaveWalletRequest(
    string? OperationUid,
    IReadOnlyList<WalletBalanceRequest>? Balances);

internal sealed record InitializeLocalStateRequest(
    string? OperationUid,
    string? FeatureManifestUid,
    string? ExpectedFeatureManifestSha256,
    string? DisplayName,
    int? CommanderLevel,
    string? ProfileIconSelectionUid,
    string? ProfileFrameSelectionUid,
    string? LobbyCharacterSelectionUid,
    string? LobbyBackgroundSelectionUid,
    IReadOnlyList<WalletBalanceRequest>? Balances);
