using NikkeLocalLab.Application.ProfileManagement;
using NikkeLocalLab.Identity;
using Npgsql;

namespace NikkeLocalLab.Persistence.PostgreSql;

public sealed class PostgreSqlProfileManagementRuntime : IAsyncDisposable
{
  private NpgsqlDataSource? _dataSource;

  private PostgreSqlProfileManagementRuntime(
      NpgsqlDataSource dataSource,
      PostgreSqlProfileManagementService service)
  {
    _dataSource = dataSource;
    Service = service;
  }

  public IProfileManagementService Service { get; }

  public static async Task<PostgreSqlProfileManagementRuntime> CreateAsync(
      string connectionString,
      TimeProvider? timeProvider = null,
      CancellationToken cancellationToken = default)
  {
    var dataSource = PostgreSqlDataSourceFactory.Create(connectionString);
    try
    {
      _ = await new PostgreSqlMigrationRunner().MigrateAsync(dataSource, cancellationToken)
          .ConfigureAwait(false);
      var service = new PostgreSqlProfileManagementService(
          dataSource,
          new RandomEntityUidGenerator(),
          timeProvider);
      _ = await service.EnsureBuiltInFeatureManifestAsync(cancellationToken)
          .ConfigureAwait(false);
      return new PostgreSqlProfileManagementRuntime(dataSource, service);
    }
    catch
    {
      await dataSource.DisposeAsync().ConfigureAwait(false);
      throw;
    }
  }

  public async ValueTask DisposeAsync()
  {
    var dataSource = Interlocked.Exchange(ref _dataSource, null);
    if (dataSource is not null)
    {
      await dataSource.DisposeAsync().ConfigureAwait(false);
    }
  }
}
