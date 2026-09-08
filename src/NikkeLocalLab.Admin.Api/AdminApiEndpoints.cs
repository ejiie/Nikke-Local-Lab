using NikkeLocalLab.Application.ProfileManagement;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Admin.Api;

internal static class AdminApiEndpoints
{
  private const string SourceFreeDraftContract = "nll/sanitized-profile-draft/v1";
  private const string NoLevelAuthority = "unresolved/no_apply";
  private const string RosterLevelAuthority = "roster_observation/v1";
  private const string DetailLevelAuthority = "detail_observation/v1";

  public static void MapAdminApiEndpoints(this WebApplication app)
  {
    var api = app.MapGroup("/admin-api/v1");

    api.MapGet("/accounts", ListAccountsAsync);
    api.MapGet("/accounts/{accountUid}/workspace", GetAccountWorkspaceAsync);
    api.MapPut("/accounts/{accountUid}/workspace", SaveAccountWorkspaceAsync);
    api.MapPost("/accounts/{accountUid}/workspace/save-as", SaveAccountWorkspaceAsAsync);
    api.MapGet("/accounts/{accountUid}/workspace/saves", GetWorkspaceSaveRecoveryAsync);
    api.MapPost("/accounts/{accountUid}/workspace/saves/resume", ResumeWorkspaceSaveAsync);
    api.MapGet("/accounts/{accountUid}/revisions", GetAccountRevisionsAsync);
    api.MapPut("/accounts/{accountUid}/label", RenameAccountAsync);
    api.MapGet(
        "/accounts/{accountUid}/runtime-projection-candidate",
        ExportRuntimeProjectionCandidateAsync);
    api.MapGet("/accounts/{accountUid}/bootstrap", GetBootstrapAsync);
    api.MapPost("/accounts/{accountUid}/local-state", InitializeLocalStateAsync);
    api.MapGet("/accounts/{accountUid}/profile", GetProfileAsync);
    api.MapGet("/sessions/{sessionUid}", GetSessionAsync);
    api.MapPost("/accounts/{accountUid}/profile/preview", PreviewProfileAsync);
    api.MapPut("/accounts/{accountUid}/profile", SaveProfileAsync);
    api.MapPost("/accounts/{accountUid}/save-as", SaveAsProfileAsync);
    api.MapPost("/accounts/{accountUid}/fetched-snapshots", RegisterFetchedSnapshotAsync);
    api.MapGet("/accounts/{accountUid}/fetched-snapshots/latest", GetLatestFetchedSnapshotAsync);
    api.MapGet("/fetched-snapshots/{snapshotUid}", GetFetchedSnapshotAsync);
    api.MapPost("/fetched-snapshots/{snapshotUid}/lobby/diff", PreviewFetchedLobbyDiffAsync);
    api.MapPost("/fetched-snapshots/{snapshotUid}/lobby/apply", ApplyFetchedLobbyAsync);

    api.MapGet("/import-drafts/{draftUid}", GetImportDraftAsync);
    api.MapPost("/import-drafts/{draftUid}/diff", PreviewImportDiffAsync);
    api.MapPost("/import-drafts/{draftUid}/apply", ApplyImportAsync);
    api.MapPost("/import-drafts/{draftUid}/create/preview", PreviewCreateFromImportAsync);
    api.MapPost("/import-drafts/{draftUid}/create", CreateFromImportAsync);
    api.MapPost("/import-drafts/{draftUid}/rebase/preview", PreviewRebaseAsync);
    api.MapPost("/import-drafts/{draftUid}/rebase", RebaseImportAsync);
    api.MapPost("/import-drafts/{draftUid}/review/preview", PreviewReviewImportDraftAsync);
    api.MapPost("/import-drafts/{draftUid}/review", ReviewImportDraftAsync);

    api.MapGet("/accounts/{accountUid}/lobby", GetLobbyAsync);
    api.MapPut("/accounts/{accountUid}/lobby", SaveLobbyAsync);
    api.MapGet("/accounts/{accountUid}/wallet", GetWalletAsync);
    api.MapPut("/accounts/{accountUid}/wallet", SaveWalletAsync);
    api.MapGet("/client-feature-manifest", GetFeatureManifestAsync);
  }

  private static async Task<IResult> ListAccountsAsync(
      IProfileManagementService service,
      CancellationToken cancellationToken)
  {
    var result = await service.ListAccountsAsync(cancellationToken).ConfigureAwait(false);
    return Results.Json(result);
  }

  private static async Task<IResult> GetWorkspaceSaveRecoveryAsync(
      string accountUid, IProfileManagementService service, CancellationToken cancellationToken) =>
      Results.Json(await service.GetWorkspaceSaveRecoveryAsync(ParseUid(accountUid), cancellationToken).ConfigureAwait(false));

  private static async Task<IResult> ResumeWorkspaceSaveAsync(
      string accountUid, ResumeWorkspaceSaveRequest request, HttpContext context,
      IProfileManagementService service, CancellationToken cancellationToken)
  {
    var receipt = await service.ResumeWorkspaceSaveAsync(new ResumeWorkspaceSaveCommand(
        ParseUid(accountUid), ParseUid(request.OperationUid), RequireIfMatchDigest(context.Request)), cancellationToken).ConfigureAwait(false);
    context.Response.Headers.ETag = QuoteEtag(receipt.RevisionSetSha256.ToString());
    return Results.Json(receipt, statusCode: receipt.SaveAs ? StatusCodes.Status201Created : StatusCodes.Status200OK);
  }

  private static async Task<IResult> GetAccountWorkspaceAsync(
      string accountUid,
      IProfileManagementService service,
      HttpContext context,
      CancellationToken cancellationToken)
  {
    var result = await service.GetAccountWorkspaceAsync(ParseUid(accountUid), cancellationToken)
        .ConfigureAwait(false) ?? throw NotFound("account_not_found");
    context.Response.Headers.ETag = QuoteEtag(result.BaseRevisions.RevisionSetSha256.ToString());
    return Results.Json(result);
  }

  private static async Task<IResult> GetAccountRevisionsAsync(
      string accountUid,
      IProfileManagementService service,
      CancellationToken cancellationToken)
  {
    var result = await service.GetAccountRevisionHistoryAsync(
        ParseUid(accountUid), cancellationToken).ConfigureAwait(false);
    return result is null ? throw NotFound("account_not_found") : Results.Json(result);
  }

  private static async Task<IResult> RenameAccountAsync(
      string accountUid,
      RenameAccountRequest request,
      IProfileManagementService service,
      CancellationToken cancellationToken)
  {
    var result = await service.RenameAccountAsync(
        new RenameAccountCommand(
            ParseUid(accountUid),
            ProfileManagementText.NormalizeAccountLabel(
                request.ExpectedAccountLabel ?? throw Invalid("account_label_invalid")),
            ProfileManagementText.NormalizeAccountLabel(
                request.AccountLabel ?? throw Invalid("account_label_invalid"))),
        cancellationToken).ConfigureAwait(false);
    return Results.Json(result);
  }

  private static Task<IResult> SaveAccountWorkspaceAsync(
      string accountUid,
      SaveAccountWorkspaceRequest request,
      IProfileManagementService service,
      HttpContext context,
      CancellationToken cancellationToken) =>
      SaveAccountWorkspaceCoreAsync(
          accountUid,
          request,
          saveAs: false,
          service,
          context,
          cancellationToken);

  private static Task<IResult> SaveAccountWorkspaceAsAsync(
      string accountUid,
      SaveAccountWorkspaceRequest request,
      IProfileManagementService service,
      HttpContext context,
      CancellationToken cancellationToken) =>
      SaveAccountWorkspaceCoreAsync(
          accountUid,
          request,
          saveAs: true,
          service,
          context,
          cancellationToken);

  private static async Task<IResult> SaveAccountWorkspaceCoreAsync(
      string accountUid,
      SaveAccountWorkspaceRequest request,
      bool saveAs,
      IProfileManagementService service,
      HttpContext context,
      CancellationToken cancellationToken)
  {
    var result = await service.SaveAccountWorkspaceAsync(
        new SaveAccountWorkspaceCommand(
            ParseUid(request.OperationUid),
            saveAs,
            ParseUid(accountUid),
            RequireIfMatchDigest(context.Request),
            ParseUid(request.ExpectedProfileRevisionUid),
            ParseUid(request.ExpectedLobbyRevisionUid),
            ParseUid(request.ExpectedWalletRevisionUid),
            ParseUid(request.CandidateDraftUid),
            ParseDigest(request.CandidateSha256),
            ParseDigest(request.ExpectedDiffSha256),
            ProfileManagementText.NormalizeAccountLabel(
                request.ExpectedAccountLabel ?? throw Invalid("account_label_invalid")),
            ProfileManagementText.NormalizeAccountLabel(
                request.AccountLabel ?? throw Invalid("account_label_invalid")),
            ProfileManagementText.NormalizeDisplayName(
                request.DisplayName ?? throw Invalid("lobby_presentation_value_invalid")),
            request.CommanderLevel ?? throw Invalid("lobby_presentation_value_invalid"),
            ParseOptionalUid(request.ProfileIconSelectionUid),
            ParseOptionalUid(request.ProfileFrameSelectionUid),
            ParseOptionalUid(request.LobbyCharacterSelectionUid),
            ParseOptionalUid(request.LobbyBackgroundSelectionUid),
            MapWalletBalances(request.Balances)),
        cancellationToken).ConfigureAwait(false);
    context.Response.Headers.ETag = QuoteEtag(result.RevisionSetSha256.ToString());
    return Results.Json(
        result,
        statusCode: saveAs ? StatusCodes.Status201Created : StatusCodes.Status200OK);
  }

  private static async Task<IResult> ExportRuntimeProjectionCandidateAsync(
      string accountUid,
      IProfileManagementService service,
      HttpContext context,
      CancellationToken cancellationToken)
  {
    var result = await service.ExportRuntimeProjectionCandidateAsync(
        ParseUid(accountUid), cancellationToken).ConfigureAwait(false) ??
        throw NotFound("account_not_found");
    context.Response.Headers.ETag = QuoteEtag(result.CandidateSha256.ToString());
    return Results.Json(result);
  }

  private static async Task<IResult> GetBootstrapAsync(
      string accountUid,
      IProfileManagementService service,
      HttpContext context,
      CancellationToken cancellationToken)
  {
    var result = await service.GetCurrentBootstrapAsync(ParseUid(accountUid), cancellationToken)
        .ConfigureAwait(false);
    if (result is null)
    {
      throw NotFound("account_not_found");
    }

    context.Response.Headers.ETag = QuoteEtag(result.RevisionSetSha256.ToString());
    return Results.Json(result);
  }

  private static async Task<IResult> InitializeLocalStateAsync(
      string accountUid,
      InitializeLocalStateRequest request,
      IProfileManagementService service,
      HttpContext context,
      CancellationToken cancellationToken)
  {
    var commanderLevel = request.CommanderLevel ??
        throw Invalid("lobby_presentation_value_invalid");
    if (commanderLevel is < 1 or > 1_000_000)
    {
      throw Invalid("lobby_presentation_value_invalid");
    }

    var result = await service.InitializeLocalStateAsync(
        new InitializeLocalStateCommand(
            ParseUid(request.OperationUid),
            ParseUid(accountUid),
            RequireIfMatchUid(context.Request),
            ParseUid(request.FeatureManifestUid),
            ParseDigest(request.ExpectedFeatureManifestSha256),
            ProfileManagementText.NormalizeDisplayName(
                request.DisplayName ?? throw Invalid("lobby_presentation_value_invalid")),
            commanderLevel,
            ParseOptionalUid(request.ProfileIconSelectionUid),
            ParseOptionalUid(request.ProfileFrameSelectionUid),
            ParseOptionalUid(request.LobbyCharacterSelectionUid),
            ParseOptionalUid(request.LobbyBackgroundSelectionUid),
            MapWalletBalances(request.Balances)),
        cancellationToken).ConfigureAwait(false);
    context.Response.Headers.ETag = QuoteEtag(result.RevisionSetSha256.ToString());
    return Results.Json(result, statusCode: StatusCodes.Status201Created);
  }

  private static async Task<IResult> GetProfileAsync(
      string accountUid,
      IProfileManagementService service,
      HttpContext context,
      CancellationToken cancellationToken)
  {
    var result = await service.GetCurrentProfileAsync(ParseUid(accountUid), cancellationToken)
        .ConfigureAwait(false);
    if (result is null)
    {
      throw NotFound("account_not_found");
    }

    SetRevisionEtag(context, result.ProfileRevision.RevisionUid);
    return Results.Json(result);
  }

  private static async Task<IResult> GetSessionAsync(
      string sessionUid,
      IProfileManagementService service,
      TimeProvider timeProvider,
      CancellationToken cancellationToken)
  {
    var result = await service.GetSessionAsync(
        ParseUid(sessionUid),
        timeProvider.GetUtcNow(),
        cancellationToken).ConfigureAwait(false);
    return result is null ? throw NotFound("session_not_found") : Results.Json(result);
  }

  private static async Task<IResult> PreviewProfileAsync(
      string accountUid,
      ProfileEditPreviewRequest request,
      IProfileManagementService service,
      HttpContext context,
      CancellationToken cancellationToken)
  {
    var expectedRevision = RequireIfMatchUid(context.Request);
    var operations = request.Operations?.Select(MapEditOperation).ToArray() ??
        throw Invalid("profile_edit_operations_missing");
    if (operations.Length > 512)
    {
      throw Invalid("profile_edit_operation_count_invalid");
    }

    foreach (var operation in operations)
    {
      operation.Validate();
    }

    var result = await service.PreviewProfileEditsAsync(
        new ProfileEditPreviewCommand(
            ParseUid(request.OperationUid),
            ParseUid(accountUid),
            expectedRevision,
            operations),
        cancellationToken).ConfigureAwait(false);
    return Results.Json(result);
  }

  private static async Task<IResult> SaveProfileAsync(
      string accountUid,
      SaveProfileRequest request,
      IProfileManagementService service,
      HttpContext context,
      CancellationToken cancellationToken)
  {
    var result = await service.SaveProfileAsync(
        new SaveProfileCommand(
            ParseUid(request.OperationUid),
            ParseUid(accountUid),
            RequireIfMatchUid(context.Request),
            ParseUid(request.CandidateDraftUid),
            ParseDigest(request.CandidateSha256),
            ParseDigest(request.ExpectedDiffSha256)),
        cancellationToken).ConfigureAwait(false);
    SetRevisionEtag(context, result.ProfileRevision.RevisionUid);
    return Results.Json(result);
  }

  private static async Task<IResult> SaveAsProfileAsync(
      string accountUid,
      SaveAsProfileRequest request,
      IProfileManagementService service,
      HttpContext context,
      CancellationToken cancellationToken)
  {
    var candidateUid = ParseOptionalUid(request.CandidateDraftUid);
    var candidateSha256 = ParseOptionalDigest(request.CandidateSha256);
    if ((candidateUid is null) != (candidateSha256 is null))
    {
      throw Invalid("save_as_candidate_shape_invalid");
    }

    var result = await service.SaveAsProfileAsync(
        new SaveAsProfileCommand(
            ParseUid(request.OperationUid),
            ParseUid(accountUid),
            RequireIfMatchUid(context.Request),
            candidateUid,
            candidateSha256,
            ParseDigest(request.ExpectedDiffSha256),
            ProfileManagementText.NormalizeAccountLabel(
                request.AccountLabel ?? throw Invalid("account_label_invalid"))),
        cancellationToken).ConfigureAwait(false);
    SetRevisionEtag(context, result.ProfileRevision.RevisionUid);
    return Results.Json(result, statusCode: StatusCodes.Status201Created);
  }

  private static async Task<IResult> GetImportDraftAsync(
      string draftUid,
      IProfileManagementService service,
      HttpContext context,
      CancellationToken cancellationToken)
  {
    var result = await service.GetImportDraftAsync(ParseUid(draftUid), cancellationToken)
        .ConfigureAwait(false);
    if (result is null)
    {
      throw NotFound("import_draft_not_found");
    }

    EnsureDraftContract(result);
    SetRevisionEtag(context, result.DraftUid);
    return Results.Json(result);
  }

  private static async Task<IResult> RegisterFetchedSnapshotAsync(
      string accountUid,
      RegisterFetchedAccountSnapshotRequest request,
      IProfileManagementService service,
      HttpContext context,
      CancellationToken cancellationToken)
  {
    var result = await service.RegisterFetchedAccountSnapshotAsync(
        new RegisterFetchedAccountSnapshotCommand(
            ParseUid(accountUid),
            RequireIfMatchUid(context.Request),
            request.CanonicalSnapshotJson ?? throw Invalid("fetched_snapshot_payload_missing"),
            request.CanonicalSanitizedDraftJson ??
                throw Invalid("fetched_snapshot_sanitized_draft_missing"),
            request.CanonicalProgressionObservationJson),
        cancellationToken).ConfigureAwait(false);
    SetRevisionEtag(context, result.SnapshotUid);
    return Results.Json(result, statusCode: StatusCodes.Status201Created);
  }

  private static async Task<IResult> GetFetchedSnapshotAsync(
      string snapshotUid,
      IProfileManagementService service,
      HttpContext context,
      CancellationToken cancellationToken)
  {
    var result = await service.GetFetchedAccountSnapshotAsync(
        ParseUid(snapshotUid), cancellationToken).ConfigureAwait(false) ??
        throw NotFound("fetched_snapshot_not_found");
    SetRevisionEtag(context, result.SnapshotUid);
    return Results.Json(result);
  }

  private static async Task<IResult> GetLatestFetchedSnapshotAsync(
      string accountUid,
      IProfileManagementService service,
      HttpContext context,
      CancellationToken cancellationToken)
  {
    var result = await service.GetLatestFetchedAccountSnapshotAsync(
        ParseUid(accountUid), cancellationToken).ConfigureAwait(false) ??
        throw NotFound("fetched_snapshot_observation_not_found");
    SetRevisionEtag(context, result.SnapshotUid);
    return Results.Json(result);
  }

  private static async Task<IResult> PreviewFetchedLobbyDiffAsync(
      string snapshotUid,
      FetchedLobbyDiffRequest request,
      IProfileManagementService service,
      HttpContext context,
      CancellationToken cancellationToken)
  {
    var result = await service.PreviewFetchedLobbyDiffAsync(
        new PreviewFetchedLobbyDiffCommand(
            ParseUid(request.OperationUid),
            ParseUid(snapshotUid),
            ParseUid(request.TargetAccountUid),
            RequireIfMatchUid(context.Request),
            NormalizeFetchedLobbyFields(request.Fields)),
        cancellationToken).ConfigureAwait(false);
    return Results.Json(result);
  }

  private static async Task<IResult> ApplyFetchedLobbyAsync(
      string snapshotUid,
      ApplyFetchedLobbyRequest request,
      IProfileManagementService service,
      HttpContext context,
      CancellationToken cancellationToken)
  {
    var result = await service.ApplyFetchedLobbyAsync(
        new ApplyFetchedLobbyCommand(
            ParseUid(request.OperationUid),
            ParseUid(snapshotUid),
            ParseUid(request.TargetAccountUid),
            RequireIfMatchUid(context.Request),
            ParseDigest(request.ExpectedDiffSha256),
            NormalizeFetchedLobbyFields(request.Fields)),
        cancellationToken).ConfigureAwait(false);
    SetRevisionEtag(context, result.Lobby.Revision.RevisionUid);
    return Results.Json(result);
  }

  private static async Task<IResult> PreviewImportDiffAsync(
      string draftUid,
      ImportDiffRequest request,
      IProfileManagementService service,
      HttpContext context,
      CancellationToken cancellationToken)
  {
    var result = await service.PreviewImportDiffAsync(
        new ImportDiffCommand(
            ParseUid(request.OperationUid),
            ParseUid(draftUid),
            ParseDigest(request.ExpectedDraftSha256),
            ParseUid(request.TargetAccountUid),
            RequireIfMatchUid(context.Request),
            NormalizeLevelAuthority(request.LevelAuthorityPolicy, allowUnresolved: true),
            NormalizeScopes(request.Scopes)),
        cancellationToken).ConfigureAwait(false);
    return Results.Json(result);
  }

  private static async Task<IResult> ApplyImportAsync(
      string draftUid,
      ApplyImportRequest request,
      IProfileManagementService service,
      HttpContext context,
      CancellationToken cancellationToken)
  {
    var scopes = NormalizeScopes(request.Scopes);
    var levelAuthority = NormalizeLevelAuthority(
        request.LevelAuthorityPolicy,
        allowUnresolved: scopes.Count == 1 && scopes[0] == "account_state_only");
    var result = await service.ApplyImportAsync(
        new ApplyImportCommand(
            ParseUid(request.OperationUid),
            ParseUid(draftUid),
            ParseDigest(request.ExpectedDraftSha256),
            ParseUid(request.TargetAccountUid),
            RequireIfMatchUid(context.Request),
            ParseDigest(request.ExpectedDiffSha256),
            levelAuthority,
            scopes),
        cancellationToken).ConfigureAwait(false);
    SetRevisionEtag(context, result.ProfileRevision.RevisionUid);
    return Results.Json(result);
  }

  private static async Task<IResult> PreviewCreateFromImportAsync(
      string draftUid,
      CreateImportDiffRequest request,
      IProfileManagementService service,
      HttpContext context,
      CancellationToken cancellationToken)
  {
    var parsedDraftUid = RequireDraftIfMatch(draftUid, context.Request);
    var result = await service.PreviewCreateFromImportAsync(
        new CreateImportDiffCommand(
            ParseUid(request.OperationUid),
            parsedDraftUid,
            ParseDigest(request.ExpectedDraftSha256),
            NormalizeLevelAuthority(request.LevelAuthorityPolicy, allowUnresolved: false),
            NormalizeScopes(request.Scopes)),
        cancellationToken).ConfigureAwait(false);
    return Results.Json(result);
  }

  private static async Task<IResult> CreateFromImportAsync(
      string draftUid,
      CreateFromImportRequest request,
      IProfileManagementService service,
      HttpContext context,
      CancellationToken cancellationToken)
  {
    var parsedDraftUid = RequireDraftIfMatch(draftUid, context.Request);
    var result = await service.CreateFromImportAsync(
        new CreateFromImportCommand(
            ParseUid(request.OperationUid),
            parsedDraftUid,
            ParseDigest(request.ExpectedDraftSha256),
            ParseDigest(request.ExpectedDiffSha256),
            NormalizeLevelAuthority(request.LevelAuthorityPolicy, allowUnresolved: false),
            NormalizeScopes(request.Scopes)),
        cancellationToken).ConfigureAwait(false);
    SetRevisionEtag(context, result.ProfileRevision.RevisionUid);
    return Results.Json(result, statusCode: StatusCodes.Status201Created);
  }

  private static Task<IResult> PreviewRebaseAsync(
      string draftUid,
      RebaseImportRequest request,
      IProfileManagementService service,
      HttpContext context,
      CancellationToken cancellationToken) => RebaseAsync(
          draftUid,
          request,
          service,
          context,
          previewOnly: true,
          cancellationToken);

  private static Task<IResult> RebaseImportAsync(
      string draftUid,
      RebaseImportRequest request,
      IProfileManagementService service,
      HttpContext context,
      CancellationToken cancellationToken) => RebaseAsync(
          draftUid,
          request,
          service,
          context,
          previewOnly: false,
          cancellationToken);

  private static async Task<IResult> RebaseAsync(
      string draftUid,
      RebaseImportRequest request,
      IProfileManagementService service,
      HttpContext context,
      bool previewOnly,
      CancellationToken cancellationToken)
  {
    var parsedDraftUid = ParseUid(draftUid);
    if (RequireIfMatchUid(context.Request) != parsedDraftUid)
    {
      throw Conflict("import_draft_revision_conflict");
    }

    if (request.ExplicitMappings?.Count > 4096)
    {
      throw Invalid("rebase_mapping_set_invalid");
    }

    var mappings = new Dictionary<EntityUid, EntityUid>();
    foreach (var mapping in request.ExplicitMappings ?? [])
    {
      if (mapping is null ||
          !mappings.TryAdd(ParseUid(mapping.FromUid), ParseUid(mapping.ToUid)))
      {
        throw Invalid("rebase_mapping_set_invalid");
      }
    }
    var command = new RebaseImportCommand(
        ParseUid(request.OperationUid),
        parsedDraftUid,
        ParseDigest(request.ExpectedDraftSha256),
        MapCatalog(request.TargetCharacterCatalog),
        MapCatalog(request.TargetCombatSupportCatalog),
        mappings,
        ParseOptionalDigest(request.ExpectedDiffSha256));
    if (previewOnly)
    {
      return Results.Json(await service.PreviewRebaseAsync(command, cancellationToken)
          .ConfigureAwait(false));
    }

    if (command.ExpectedDiffSha256 is null)
    {
      throw Invalid("expected_diff_sha256_missing");
    }

    var result = await service.RebaseImportAsync(command, cancellationToken).ConfigureAwait(false);
    EnsureDraftContract(result);
    SetRevisionEtag(context, result.DraftUid);
    return Results.Json(result);
  }

  private static Task<IResult> PreviewReviewImportDraftAsync(
      string draftUid,
      ReviewImportDraftRequest request,
      IProfileManagementService service,
      HttpContext context,
      CancellationToken cancellationToken) => ReviewImportDraftCoreAsync(
          draftUid,
          request,
          service,
          context,
          previewOnly: true,
          cancellationToken);

  private static Task<IResult> ReviewImportDraftAsync(
      string draftUid,
      ReviewImportDraftRequest request,
      IProfileManagementService service,
      HttpContext context,
      CancellationToken cancellationToken) => ReviewImportDraftCoreAsync(
          draftUid,
          request,
          service,
          context,
          previewOnly: false,
          cancellationToken);

  private static async Task<IResult> ReviewImportDraftCoreAsync(
      string draftUid,
      ReviewImportDraftRequest request,
      IProfileManagementService service,
      HttpContext context,
      bool previewOnly,
      CancellationToken cancellationToken)
  {
    var parsedDraftUid = RequireDraftIfMatch(draftUid, context.Request);
    var overrides = request.Overrides?.Select(MapReviewedOverride).ToArray() ??
        throw Invalid("import_review_overrides_missing");
    if (overrides.Length is < 1 or > 512)
    {
      throw Invalid("import_review_override_count_invalid");
    }

    var command = new ReviewImportDraftCommand(
        ParseUid(request.OperationUid),
        parsedDraftUid,
        ParseDigest(request.ExpectedDraftSha256),
        overrides,
        ParseOptionalDigest(request.ExpectedDiffSha256));
    if (previewOnly)
    {
      return Results.Json(await service.PreviewReviewImportDraftAsync(command, cancellationToken)
          .ConfigureAwait(false));
    }

    if (command.ExpectedDiffSha256 is null)
    {
      throw Invalid("expected_diff_sha256_missing");
    }

    var result = await service.ReviewImportDraftAsync(command, cancellationToken)
        .ConfigureAwait(false);
    EnsureDraftContract(result);
    SetRevisionEtag(context, result.DraftUid);
    return Results.Json(result);
  }

  private static async Task<IResult> GetLobbyAsync(
      string accountUid,
      IProfileManagementService service,
      HttpContext context,
      CancellationToken cancellationToken)
  {
    var result = await service.GetLobbyPresentationAsync(ParseUid(accountUid), cancellationToken)
        .ConfigureAwait(false);
    if (result is null)
    {
      throw NotFound("lobby_presentation_not_found");
    }

    SetRevisionEtag(context, result.Revision.RevisionUid);
    return Results.Json(result);
  }

  private static async Task<IResult> SaveLobbyAsync(
      string accountUid,
      SaveLobbyPresentationRequest request,
      IProfileManagementService service,
      HttpContext context,
      CancellationToken cancellationToken)
  {
    var result = await service.SaveLobbyPresentationAsync(
        new SaveLobbyPresentationCommand(
            ParseUid(request.OperationUid),
            ParseUid(accountUid),
            RequireIfMatchUid(context.Request),
            request.DisplayName ?? throw Invalid("lobby_presentation_value_invalid"),
            request.CommanderLevel ?? throw Invalid("lobby_presentation_value_invalid"),
            ParseOptionalUid(request.ProfileIconSelectionUid),
            ParseOptionalUid(request.ProfileFrameSelectionUid),
            ParseOptionalUid(request.LobbyCharacterSelectionUid),
            ParseOptionalUid(request.LobbyBackgroundSelectionUid)),
        cancellationToken).ConfigureAwait(false);
    SetRevisionEtag(context, result.Revision.RevisionUid);
    return Results.Json(result);
  }

  private static async Task<IResult> GetWalletAsync(
      string accountUid,
      IProfileManagementService service,
      HttpContext context,
      CancellationToken cancellationToken)
  {
    var result = await service.GetWalletAsync(ParseUid(accountUid), cancellationToken)
        .ConfigureAwait(false);
    if (result is null)
    {
      throw NotFound("wallet_not_found");
    }

    SetRevisionEtag(context, result.Revision.RevisionUid);
    return Results.Json(result);
  }

  private static async Task<IResult> SaveWalletAsync(
      string accountUid,
      SaveWalletRequest request,
      IProfileManagementService service,
      HttpContext context,
      CancellationToken cancellationToken)
  {
    var balances = MapWalletBalances(request.Balances);

    var result = await service.SaveWalletAsync(
        new SaveWalletCommand(
            ParseUid(request.OperationUid),
            ParseUid(accountUid),
            RequireIfMatchUid(context.Request),
            balances),
        cancellationToken).ConfigureAwait(false);
    SetRevisionEtag(context, result.Revision.RevisionUid);
    return Results.Json(result);
  }

  private static IReadOnlyList<WalletBalanceProjection> MapWalletBalances(
      IReadOnlyList<WalletBalanceRequest>? requestedBalances)
  {
    var balances = requestedBalances?.Select(balance =>
    {
      if (balance is null)
      {
        throw Invalid("wallet_balance_invalid");
      }

      var code = ControlledCode.Require(balance.CurrencyCode, nameof(balance.CurrencyCode));
      if (balance.Balance is null or < 0)
      {
        throw Invalid("wallet_balance_invalid");
      }

      return new WalletBalanceProjection(code, balance.Balance.Value);
    }).OrderBy(balance => balance.CurrencyCode, StringComparer.Ordinal).ToArray() ??
        throw Invalid("wallet_balances_missing");
    if (balances.Length != 2 ||
        balances.Select(balance => balance.CurrencyCode).Distinct(StringComparer.Ordinal).Count() != 2 ||
        !balances.Select(balance => balance.CurrencyCode).SequenceEqual(
            ["credit", "jewel"],
            StringComparer.Ordinal))
    {
      throw Invalid("wallet_balance_set_invalid");
    }

    return balances;
  }

  private static async Task<IResult> GetFeatureManifestAsync(
      IProfileManagementService service,
      HttpContext context,
      CancellationToken cancellationToken)
  {
    var result = await service.GetFeatureManifestAsync(cancellationToken).ConfigureAwait(false);
    context.Response.Headers.ETag = QuoteEtag(result.ContentSha256.ToString());
    return Results.Json(result);
  }

  private static ProfileEditOperation MapEditOperation(ProfileEditOperationRequest? request)
  {
    if (request is null)
    {
      throw Invalid("profile_edit_operation_invalid");
    }

    return new ProfileEditOperation(
        request.FieldCode ?? throw Invalid("profile_edit_field_missing"),
        ParseOptionalUid(request.SubjectUid),
        request.ValueKind ?? throw Invalid("profile_edit_value_kind_missing"),
        request.IntegerValue,
        request.BooleanValue,
        ParseOptionalUid(request.ReferenceUid),
        request.UnscaledValue,
        request.DecimalScale,
        request.ControlledValue);
  }

  private static CatalogBindingProjection MapCatalog(CatalogBindingRequest? request)
  {
    if (request is null)
    {
      throw Invalid("catalog_binding_missing");
    }

    return new CatalogBindingProjection(
        ParseUid(request.CatalogSnapshotUid),
        ParseUid(request.DatasetSnapshotUid),
        ParseDigest(request.ManifestSha256));
  }

  private static ImportReviewedOverrideRequest MapReviewedOverride(ReviewedOverrideRequest? request)
  {
    if (request is null)
    {
      throw Invalid("import_review_override_invalid");
    }

    var kind = request.Kind switch
    {
      "bond_level" => ImportReviewedOverrideKind.BondLevel,
      "equipment_manufacturer_matched" =>
          ImportReviewedOverrideKind.EquipmentManufacturerMatched,
      _ => throw Invalid("import_review_override_kind_invalid")
    };
    var slot = request.EquipmentSlot switch
    {
      null => (ImportEquipmentSlot?)null,
      "head" => ImportEquipmentSlot.Head,
      "torso" => ImportEquipmentSlot.Torso,
      "arms" => ImportEquipmentSlot.Arms,
      "legs" => ImportEquipmentSlot.Legs,
      _ => throw Invalid("import_review_equipment_slot_invalid")
    };
    var reason = request.ReasonCode switch
    {
      "user_reviewed_override" => request.ReasonCode,
      "original_client_verified_override" => request.ReasonCode,
      _ => throw Invalid("import_review_reason_invalid")
    };

    if ((kind == ImportReviewedOverrideKind.BondLevel &&
         (slot is not null || request.IntegerValue is null || request.BooleanValue is not null)) ||
        (kind == ImportReviewedOverrideKind.EquipmentManufacturerMatched &&
         (slot is null || request.IntegerValue is not null || request.BooleanValue is null)))
    {
      throw Invalid("import_review_override_value_invalid");
    }

    return new ImportReviewedOverrideRequest(
        kind,
        ParseUid(request.CharacterUid),
        slot,
        request.IntegerValue,
        request.BooleanValue,
        reason);
  }

  private static IReadOnlyList<string> NormalizeScopes(IReadOnlyList<string>? scopes)
  {
    var result = scopes?.Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToArray() ?? [];
    if (result.Length == 0 || result.Length > 3 ||
        result.Any(scope => scope is not ("full_profile" or "builds_only" or "account_state_only")) ||
        (result.Contains("full_profile", StringComparer.Ordinal) && result.Length != 1))
    {
      throw Invalid("import_scope_set_invalid");
    }

    return result;
  }

  private static IReadOnlyList<string> NormalizeFetchedLobbyFields(
      IReadOnlyList<string>? fields)
  {
    var result = fields?.Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToArray() ?? [];
    if (result.Length == 0 || result.Length > 2 ||
        result.Any(field => field is not ("commander_level" or "display_name")))
    {
      throw Invalid("fetched_lobby_field_set_invalid");
    }

    return result;
  }

  private static string NormalizeLevelAuthority(string? value, bool allowUnresolved)
  {
    value ??= NoLevelAuthority;
    if (value == NoLevelAuthority && allowUnresolved)
    {
      return value;
    }

    if (value is RosterLevelAuthority or DetailLevelAuthority)
    {
      return value;
    }

    throw new ApiRequestException(StatusCodes.Status409Conflict, "level_authority_required");
  }

  private static void EnsureDraftContract(SourceFreeImportDraftProjection draft)
  {
    if (!string.Equals(draft.ContractId, SourceFreeDraftContract, StringComparison.Ordinal))
    {
      throw new ApiRequestException(StatusCodes.Status500InternalServerError, "draft_contract_invalid");
    }
  }

  private static EntityUid RequireIfMatchUid(HttpRequest request)
  {
    if (!request.Headers.TryGetValue("If-Match", out var values) || values.Count != 1)
    {
      throw new ApiRequestException(StatusCodes.Status428PreconditionRequired, "if_match_required");
    }

    var value = values[0];
    if (value is null || value.Length != 38 || value[0] != '"' || value[^1] != '"')
    {
      throw Invalid("if_match_invalid");
    }

    return ParseUid(value[1..^1]);
  }

  private static Sha256Digest RequireIfMatchDigest(HttpRequest request)
  {
    if (!request.Headers.TryGetValue("If-Match", out var values) || values.Count != 1)
    {
      throw new ApiRequestException(StatusCodes.Status428PreconditionRequired, "if_match_required");
    }

    var value = values[0];
    if (value is null || value.Length != 66 || value[0] != '"' || value[^1] != '"')
    {
      throw Invalid("if_match_invalid");
    }

    return ParseDigest(value[1..^1]);
  }

  private static EntityUid RequireDraftIfMatch(string draftUid, HttpRequest request)
  {
    var parsedDraftUid = ParseUid(draftUid);
    if (RequireIfMatchUid(request) != parsedDraftUid)
    {
      throw Conflict("import_draft_revision_conflict");
    }

    return parsedDraftUid;
  }

  private static void SetRevisionEtag(HttpContext context, EntityUid revisionUid) =>
      context.Response.Headers.ETag = QuoteEtag(revisionUid.ToString());

  private static string QuoteEtag(string value) => $"\"{value}\"";

  private static EntityUid ParseUid(string? value)
  {
    if (!Guid.TryParseExact(value, "D", out var guid) || guid == Guid.Empty)
    {
      throw Invalid("entity_uid_invalid");
    }

    return new EntityUid(guid);
  }

  private static EntityUid? ParseOptionalUid(string? value) =>
      value is null ? null : ParseUid(value);

  private static Sha256Digest ParseDigest(string? value)
  {
    if (!Sha256Digest.TryParse(value, out var digest))
    {
      throw Invalid("sha256_invalid");
    }

    return digest;
  }

  private static Sha256Digest? ParseOptionalDigest(string? value) =>
      value is null ? null : ParseDigest(value);

  private static ApiRequestException Invalid(string code) =>
      new(StatusCodes.Status400BadRequest, code);

  private static ApiRequestException NotFound(string code) =>
      new(StatusCodes.Status404NotFound, code);

  private static ApiRequestException Conflict(string code) =>
      new(StatusCodes.Status409Conflict, code);
}
