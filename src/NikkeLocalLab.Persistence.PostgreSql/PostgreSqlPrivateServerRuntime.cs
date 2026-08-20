using NikkeLocalLab.Application.PrivateServer;
using NikkeLocalLab.Domain.PrivateServer;
using NikkeLocalLab.Identity;
using Npgsql;

namespace NikkeLocalLab.Persistence.PostgreSql;

public sealed class PostgreSqlPrivateServerRuntime : IAsyncDisposable
{
  private NpgsqlDataSource? _dataSource;

  private PostgreSqlPrivateServerRuntime(
      NpgsqlDataSource dataSource,
      PostgreSqlPrivateServerService service)
  {
    _dataSource = dataSource;
    Service = service;
  }

  public IPrivateServerService Service { get; }

  public static Task<PostgreSqlPrivateServerRuntime> CreateAsync(
      string connectionString,
      CancellationToken cancellationToken = default) =>
      CreateAsync(connectionString, initialOperationalPolicy: null, TimeProvider.System, cancellationToken);

  public static async Task<PostgreSqlPrivateServerRuntime> CreateAsync(
      string connectionString,
      TimeProvider timeProvider,
      CancellationToken cancellationToken = default)
      => await CreateAsync(
          connectionString,
          initialOperationalPolicy: null,
          timeProvider,
          cancellationToken).ConfigureAwait(false);

  public static Task<PostgreSqlPrivateServerRuntime> CreateAsync(
      string connectionString,
      ChallengeOperationalPolicy initialOperationalPolicy,
      CancellationToken cancellationToken = default) =>
      CreateAsync(
          connectionString,
          initialOperationalPolicy,
          TimeProvider.System,
          cancellationToken);

  public static async Task<PostgreSqlPrivateServerRuntime> CreateAsync(
      string connectionString,
      ChallengeOperationalPolicy? initialOperationalPolicy,
      TimeProvider timeProvider,
      CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(timeProvider);
    var dataSource = PostgreSqlDataSourceFactory.Create(connectionString);
    try
    {
      _ = await new PostgreSqlMigrationRunner().MigrateAsync(dataSource, cancellationToken)
          .ConfigureAwait(false);
      var uidGenerator = new RandomEntityUidGenerator();
      var profiles = new PostgreSqlProfileManagementService(
          dataSource,
          uidGenerator,
          timeProvider);
      var service = new PostgreSqlPrivateServerService(
          dataSource,
          profiles,
          uidGenerator,
          timeProvider);
      await service.InitializeAsync(initialOperationalPolicy, cancellationToken)
          .ConfigureAwait(false);
      return new PostgreSqlPrivateServerRuntime(dataSource, service);
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
