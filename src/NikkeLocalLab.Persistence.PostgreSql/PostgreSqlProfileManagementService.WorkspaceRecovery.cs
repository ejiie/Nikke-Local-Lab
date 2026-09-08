using App = NikkeLocalLab.Application.ProfileManagement;
using NikkeLocalLab.Identity;

namespace NikkeLocalLab.Persistence.PostgreSql;

public sealed partial class PostgreSqlProfileManagementService
{
  public Task<IReadOnlyList<App.WorkspaceSaveRecoveryProjection>> GetWorkspaceSaveRecoveryAsync(
      EntityUid accountUid, CancellationToken cancellationToken = default) => TranslateAsync(
      () => RequireAccountSaveStore().GetRecoveryAsync(accountUid, cancellationToken));

  public Task<App.SaveAccountWorkspaceReceipt> ResumeWorkspaceSaveAsync(
      App.ResumeWorkspaceSaveCommand command, CancellationToken cancellationToken = default) => TranslateAsync(async () =>
  {
    var recovery = await RequireAccountSaveStore().ReadRecoveryRequestAsync(command, cancellationToken).ConfigureAwait(false);
    if (recovery.Receipt is not null) return recovery.Receipt;
    var request = NormalizeWorkspaceSave(recovery.Request!);
    if (request.RequestSha256 != command.ExpectedRequestSha256)
      throw Failure(App.ProfileManagementFailureKind.Conflict, "account_workspace_save_request_invalid");
    return await SaveAccountWorkspaceAsync(request, cancellationToken).ConfigureAwait(false);
  });
}
