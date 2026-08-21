using App = NikkeLocalLab.Application.PrivateServer;
using ProfileApp = NikkeLocalLab.Application.ProfileManagement;
using NikkeLocalLab.Identity;
using Npgsql;

namespace NikkeLocalLab.Persistence.PostgreSql;

public sealed partial class PostgreSqlPrivateServerService : App.IPrivateServerService
{
  private readonly NpgsqlDataSource _dataSource;
  private readonly ProfileApp.IProfileManagementService _profiles;
  private readonly IEntityUidGenerator _uidGenerator;
  private readonly TimeProvider _timeProvider;

  public PostgreSqlPrivateServerService(
      NpgsqlDataSource dataSource,
      ProfileApp.IProfileManagementService profiles,
      IEntityUidGenerator uidGenerator,
      TimeProvider? timeProvider = null)
  {
    _dataSource = dataSource ?? throw new ArgumentNullException(nameof(dataSource));
    _profiles = profiles ?? throw new ArgumentNullException(nameof(profiles));
    _uidGenerator = uidGenerator ?? throw new ArgumentNullException(nameof(uidGenerator));
    _timeProvider = timeProvider ?? TimeProvider.System;
  }

  private static App.PrivateServerApplicationException Failure(
      App.PrivateServerFailureKind kind,
      string code) => new(kind, code);
}
