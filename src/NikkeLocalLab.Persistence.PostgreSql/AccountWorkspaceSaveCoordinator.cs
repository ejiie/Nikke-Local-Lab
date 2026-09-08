using System.Security.Cryptography;
using System.Text;
using App = NikkeLocalLab.Application.ProfileManagement;
using NikkeLocalLab.Identity;

namespace NikkeLocalLab.Persistence.PostgreSql;

// Owns the resumable sequence, not the profile/lobby/wallet transactions themselves.
// A child receipt is the durable checkpoint; no process-local progress is authoritative.
internal sealed class AccountWorkspaceSaveCoordinator(
    PostgreSqlAccountWorkspaceSaveStore store,
    IAccountWorkspaceSaveStages stages,
    Func<DateTimeOffset> now)
{
  internal async Task<App.SaveAccountWorkspaceReceipt> ExecuteAsync(
      App.SaveAccountWorkspaceCommand command, CancellationToken cancellationToken)
  {
    var kind = command.SaveAs ? "save_as" : "save";
    var claim = await store.FindAsync(command, cancellationToken).ConfigureAwait(false);
    if (claim?.CompletedReceipt is not null) return claim.CompletedReceipt;

    // Database-scoped, including other service instances. Fail promptly instead of
    // queuing many connections behind one interrupted or slow multi-stage save.
    await using var lease = await store.AcquireAccountLeaseAsync(command.SourceAccountUid, cancellationToken)
        .ConfigureAwait(false);
    claim = await store.FindAsync(command, cancellationToken).ConfigureAwait(false);
    if (claim?.CompletedReceipt is not null) return claim.CompletedReceipt;
    if (claim is null)
    {
      await store.RequireNoPendingSaveAsync(command.SourceAccountUid, cancellationToken).ConfigureAwait(false);
      await stages.ValidatePreconditionsAsync(command, cancellationToken).ConfigureAwait(false);
      claim = await store.BeginAsync(command.OperationUid, kind, command.RequestSha256,
          command.SourceAccountUid, now(), cancellationToken,
          App.WorkspaceSaveRequestCodec.Encode(command)).ConfigureAwait(false);
    }
    else if (!await store.HasCommittedProfileAsync(ChildOperationUid(command.OperationUid, "profile"), cancellationToken)
        .ConfigureAwait(false))
    {
      // A claim alone does not prove preconditions ran. Once the profile child has
      // committed, its own exact replay contract validates recovery after head advance.
      await stages.ValidatePreconditionsAsync(command, cancellationToken).ConfigureAwait(false);
    }

    var observation = command.SaveAs
        ? claim.ObservationProvenanceResolved
            ? claim.ResolvedObservationSnapshotUid
            : await store.ResolveObservationSnapshotAsync(command.OperationUid, command.RequestSha256,
                command.SourceAccountUid, cancellationToken).ConfigureAwait(false)
        : null;
    var profile = await stages.SaveProfileAsync(command, cancellationToken).ConfigureAwait(false);
    App.LobbyPresentationProjection lobby;
    App.WalletProjection wallet;
    if (command.SaveAs)
    {
      (lobby, wallet) = await stages.InitializeCopyAsync(command, profile, cancellationToken).ConfigureAwait(false);
      await store.BindObservationProvenanceAsync(command.OperationUid, command.RequestSha256,
          command.SourceAccountUid, profile.AccountUid, observation, claim.CreatedAtUtc, cancellationToken)
          .ConfigureAwait(false);
    }
    else
    {
      var lobbyRevision = claim.ResolvedLobbyRevisionUid;
      if (lobbyRevision is null)
      {
        var current = await stages.ResolveLobbyRevisionAsync(profile, cancellationToken).ConfigureAwait(false);
        lobbyRevision = await store.ResolveLobbyRevisionAsync(command.OperationUid, command.RequestSha256,
            current, cancellationToken).ConfigureAwait(false);
      }
      lobby = await stages.SaveLobbyAsync(command, profile, lobbyRevision.Value, claim.CreatedAtUtc, cancellationToken)
          .ConfigureAwait(false);
      wallet = await stages.SaveWalletAsync(command, claim.CreatedAtUtc, cancellationToken).ConfigureAwait(false);
      await stages.RenameAsync(command, claim.CreatedAtUtc, cancellationToken).ConfigureAwait(false);
    }

    var receipt = new App.SaveAccountWorkspaceReceipt(command.OperationUid, false, command.SaveAs,
        command.SourceAccountUid, profile.AccountUid, command.AccountLabel, profile.ProfileRevision,
        lobby.Revision, wallet.Revision,
        App.AccountWorkspaceCanonicalizer.ComputeSaveRevisionSet(profile.AccountUid, command.AccountLabel,
            profile.ProfileRevision, lobby.Revision, wallet.Revision), observation);
    var completed = await store.CompleteAsync(command.OperationUid, kind, command.RequestSha256,
        command.SourceAccountUid, receipt, now(), cancellationToken).ConfigureAwait(false);
    return completed with { IsIdempotentReplay = false };
  }

  internal static EntityUid ChildOperationUid(EntityUid rootOperationUid, string role)
  {
    var bytes = SHA256.HashData(Encoding.UTF8.GetBytes(string.Join("\n",
        "nll/account-workspace-save-child/v1", rootOperationUid.ToString(), role)));
    bytes[6] = (byte)((bytes[6] & 0x0f) | 0x50);
    bytes[8] = (byte)((bytes[8] & 0x3f) | 0x80);
    return new EntityUid(new Guid(bytes[..16]));
  }
}

internal interface IAccountWorkspaceSaveStages
{
  Task ValidatePreconditionsAsync(App.SaveAccountWorkspaceCommand command, CancellationToken cancellationToken);
  Task<App.ProfileWriteReceipt> SaveProfileAsync(App.SaveAccountWorkspaceCommand command, CancellationToken cancellationToken);
  Task<(App.LobbyPresentationProjection Lobby, App.WalletProjection Wallet)> InitializeCopyAsync(
      App.SaveAccountWorkspaceCommand command, App.ProfileWriteReceipt profile, CancellationToken cancellationToken);
  Task<EntityUid> ResolveLobbyRevisionAsync(App.ProfileWriteReceipt profile, CancellationToken cancellationToken);
  Task<App.LobbyPresentationProjection> SaveLobbyAsync(App.SaveAccountWorkspaceCommand command,
      App.ProfileWriteReceipt profile, EntityUid expectedLobbyRevisionUid, DateTimeOffset createdAtUtc, CancellationToken cancellationToken);
  Task<App.WalletProjection> SaveWalletAsync(App.SaveAccountWorkspaceCommand command, DateTimeOffset createdAtUtc, CancellationToken cancellationToken);
  Task RenameAsync(App.SaveAccountWorkspaceCommand command, DateTimeOffset createdAtUtc, CancellationToken cancellationToken);
}
