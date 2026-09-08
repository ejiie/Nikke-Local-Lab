using App = NikkeLocalLab.Application.ProfileManagement;
using NikkeLocalLab.Identity;

namespace NikkeLocalLab.Persistence.PostgreSql;

public sealed partial class PostgreSqlProfileManagementService
{
  private static App.SaveAccountWorkspaceCommand NormalizeWorkspaceSave(App.SaveAccountWorkspaceCommand command)
  {
    ArgumentNullException.ThrowIfNull(command);
    if (command.OperationUid.Value == Guid.Empty ||
        command.SourceAccountUid.Value == Guid.Empty ||
        command.ExpectedProfileRevisionUid.Value == Guid.Empty ||
        command.ExpectedLobbyRevisionUid.Value == Guid.Empty ||
        command.ExpectedWalletRevisionUid.Value == Guid.Empty ||
        command.CandidateDraftUid.Value == Guid.Empty)
    {
      throw Failure(
          App.ProfileManagementFailureKind.InvalidRequest,
          "account_workspace_save_request_invalid");
    }

    var lobby = new App.SaveLobbyPresentationCommand(
        DerivedOperationUid(command.OperationUid, "validate-lobby"),
        command.SourceAccountUid,
        command.ExpectedLobbyRevisionUid,
        command.DisplayName,
        command.CommanderLevel,
        command.ProfileIconSelectionUid,
        command.ProfileFrameSelectionUid,
        command.LobbyCharacterSelectionUid,
        command.LobbyBackgroundSelectionUid);
    var balances = RequireWalletBalances(command.Balances);
    return command with
    {
      ExpectedAccountLabel = App.ProfileManagementText.NormalizeAccountLabel(
          command.ExpectedAccountLabel),
      AccountLabel = App.ProfileManagementText.NormalizeAccountLabel(command.AccountLabel),
      DisplayName = lobby.DisplayName,
      CommanderLevel = lobby.CommanderLevel,
      ProfileIconSelectionUid = lobby.ProfileIconSelectionUid,
      ProfileFrameSelectionUid = lobby.ProfileFrameSelectionUid,
      LobbyCharacterSelectionUid = lobby.LobbyCharacterSelectionUid,
      LobbyBackgroundSelectionUid = lobby.LobbyBackgroundSelectionUid,
      Balances = balances
    };
  }

  private async Task ValidateWorkspaceSavePreconditionsAsync(
      App.SaveAccountWorkspaceCommand command,
      CancellationToken cancellationToken)
  {
    var workspace = await RequireWorkspaceStore().GetAsync(
        command.SourceAccountUid,
        cancellationToken).ConfigureAwait(false) ??
        throw Failure(App.ProfileManagementFailureKind.NotFound, "account_not_found");
    var actualWorkspaceRevisionSet = App.AccountWorkspaceCanonicalizer.ComputeRevisionSet(
        workspace.ProfileRevision.RevisionUid,
        workspace.AccountStateRevisionUid,
        progressionRevisionUid: null);
    if (actualWorkspaceRevisionSet != command.ExpectedWorkspaceRevisionSetSha256 ||
        workspace.ProfileRevision.RevisionUid != command.ExpectedProfileRevisionUid)
    {
      throw Failure(
          App.ProfileManagementFailureKind.Conflict,
          "account_workspace_revision_conflict");
    }

    if (!string.Equals(
        workspace.AccountLabel,
        command.ExpectedAccountLabel,
        StringComparison.Ordinal))
    {
      throw Failure(App.ProfileManagementFailureKind.Conflict, "account_label_conflict");
    }

    var lobby = await _gameStateStore.GetLobbyPresentationHeadAsync(
        command.SourceAccountUid,
        cancellationToken).ConfigureAwait(false) ??
        throw Failure(
            App.ProfileManagementFailureKind.NotFound,
            "lobby_presentation_not_found");
    if (lobby.RevisionUid != command.ExpectedLobbyRevisionUid)
    {
      throw Failure(
          App.ProfileManagementFailureKind.Conflict,
          "local_game_lobby_revision_conflict");
    }

    var wallet = await _gameStateStore.GetWalletHeadAsync(
        command.SourceAccountUid,
        cancellationToken).ConfigureAwait(false) ??
        throw Failure(App.ProfileManagementFailureKind.NotFound, "wallet_not_found");
    if (wallet.RevisionUid != command.ExpectedWalletRevisionUid)
    {
      throw Failure(
          App.ProfileManagementFailureKind.Conflict,
          "local_game_wallet_revision_conflict");
    }
  }

  // Adapts existing transactional writers to the coordinator. Child operation IDs,
  // timestamps, normalization and no-op receipts retain their original contracts.
  private sealed class WorkspaceSaveStages(PostgreSqlProfileManagementService service) : IAccountWorkspaceSaveStages
  {
    public Task ValidatePreconditionsAsync(App.SaveAccountWorkspaceCommand command, CancellationToken cancellationToken) =>
        service.ValidateWorkspaceSavePreconditionsAsync(command, cancellationToken);

    public Task<App.ProfileWriteReceipt> SaveProfileAsync(App.SaveAccountWorkspaceCommand command, CancellationToken cancellationToken) =>
        command.SaveAs
            ? service.SaveAsProfileAsync(new App.SaveAsProfileCommand(
                DerivedOperationUid(command.OperationUid, "profile"), command.SourceAccountUid,
                command.ExpectedProfileRevisionUid, command.CandidateDraftUid, command.CandidateSha256,
                command.ExpectedDiffSha256, command.AccountLabel), cancellationToken)
            : service.SaveProfileAsync(new App.SaveProfileCommand(
                DerivedOperationUid(command.OperationUid, "profile"), command.SourceAccountUid,
                command.ExpectedProfileRevisionUid, command.CandidateDraftUid, command.CandidateSha256,
                command.ExpectedDiffSha256), cancellationToken);

    public async Task<(App.LobbyPresentationProjection Lobby, App.WalletProjection Wallet)> InitializeCopyAsync(
        App.SaveAccountWorkspaceCommand command, App.ProfileWriteReceipt profile, CancellationToken cancellationToken)
    {
      var manifest = await service.EnsureBuiltInFeatureManifestAsync(cancellationToken).ConfigureAwait(false);
      var initialized = await service.InitializeLocalStateAsync(new App.InitializeLocalStateCommand(
          DerivedOperationUid(command.OperationUid, "initialize"), profile.AccountUid, profile.ProfileRevision.RevisionUid,
          manifest.ManifestUid, manifest.ContentSha256, command.DisplayName, command.CommanderLevel,
          command.ProfileIconSelectionUid, command.ProfileFrameSelectionUid, command.LobbyCharacterSelectionUid,
          command.LobbyBackgroundSelectionUid, command.Balances), cancellationToken).ConfigureAwait(false);
      return (initialized.Lobby, initialized.Wallet);
    }

    public async Task<EntityUid> ResolveLobbyRevisionAsync(App.ProfileWriteReceipt profile, CancellationToken cancellationToken)
    {
      var currentProfile = await service._profileStore.GetCurrentAsync(profile.AccountUid, cancellationToken).ConfigureAwait(false)
          ?? throw Failure(App.ProfileManagementFailureKind.NotFound, "account_not_found");
      if (currentProfile.Revision.ProfileTemplateRevisionUid != profile.ProfileRevision.RevisionUid)
        throw Failure(App.ProfileManagementFailureKind.Conflict, "account_workspace_save_incomplete_superseded");
      var currentLobby = await service._gameStateStore.GetLobbyPresentationHeadAsync(profile.AccountUid, cancellationToken).ConfigureAwait(false)
          ?? throw Failure(App.ProfileManagementFailureKind.NotFound, "lobby_presentation_not_found");
      return currentLobby.RevisionUid;
    }

    public async Task<App.LobbyPresentationProjection> SaveLobbyAsync(
        App.SaveAccountWorkspaceCommand command, App.ProfileWriteReceipt profile,
        EntityUid expectedLobbyRevisionUid, DateTimeOffset createdAtUtc, CancellationToken cancellationToken)
    {
      var write = new LocalLobbyPresentationWrite(command.DisplayName, LocalGameIntFact.Ready(command.CommanderLevel),
          UidFact(command.LobbyCharacterSelectionUid), UidFact(command.ProfileIconSelectionUid),
          UidFact(command.ProfileFrameSelectionUid), UidFact(command.LobbyBackgroundSelectionUid));
      var receipt = await service._gameStateStore.SaveLobbyPresentationAsync(
          new global::NikkeLocalLab.Persistence.PostgreSql.SaveLobbyPresentationCommand(
              DerivedOperationUid(command.OperationUid, "lobby"), profile.AccountUid, expectedLobbyRevisionUid,
              profile.ProfileRevision.RevisionUid, write, createdAtUtc), cancellationToken).ConfigureAwait(false);
      return MapLobby(profile.AccountUid, receipt);
    }

    public async Task<App.WalletProjection> SaveWalletAsync(
        App.SaveAccountWorkspaceCommand command, DateTimeOffset createdAtUtc, CancellationToken cancellationToken)
    {
      var write = new LocalWalletWrite(command.Balances.Select(static item => new LocalWalletBalance(
          item.CurrencyCode == "credit" ? LocalWalletCurrency.Credit : LocalWalletCurrency.Jewel, item.Balance)));
      var receipt = await service._gameStateStore.SaveWalletAsync(
          new global::NikkeLocalLab.Persistence.PostgreSql.SaveWalletCommand(
              DerivedOperationUid(command.OperationUid, "wallet"), command.SourceAccountUid,
              command.ExpectedWalletRevisionUid, write, createdAtUtc), cancellationToken).ConfigureAwait(false);
      return MapWallet(command.SourceAccountUid, receipt);
    }

    public async Task RenameAsync(App.SaveAccountWorkspaceCommand command, DateTimeOffset createdAtUtc, CancellationToken cancellationToken)
    {
      var workspace = await service.RequireWorkspaceStore().GetAsync(command.SourceAccountUid, cancellationToken).ConfigureAwait(false)
          ?? throw Failure(App.ProfileManagementFailureKind.NotFound, "account_not_found");
      if (string.Equals(workspace.AccountLabel, command.AccountLabel, StringComparison.Ordinal)) return;
      if (!string.Equals(workspace.AccountLabel, command.ExpectedAccountLabel, StringComparison.Ordinal))
        throw Failure(App.ProfileManagementFailureKind.Conflict, "account_label_conflict");
      _ = await service.RequireWorkspaceStore().RenameAsync(new App.RenameAccountCommand(
          command.SourceAccountUid, command.ExpectedAccountLabel, command.AccountLabel), createdAtUtc, cancellationToken).ConfigureAwait(false);
    }
  }
}
