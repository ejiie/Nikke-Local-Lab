using NikkeLocalLab.Configuration;
using NikkeLocalLab.Persistence.PostgreSql;

return await ImportCli.RunAsync(args).ConfigureAwait(false);

internal static class ImportCli
{
  public static async Task<int> RunAsync(string[] args)
  {
    try
    {
      if (args.Length == 0)
      {
        return Fail("command_missing");
      }

      var command = args[0];
      var options = ParseOptions(args.Skip(1).ToArray());
      if (!options.TryGetValue("config", out var configPath) ||
          !options.TryGetValue("repository-root", out var repositoryRoot))
      {
        return Fail("required_option_missing");
      }

      var configuration = LabConfigurationLoader.Load(configPath, repositoryRoot);
      switch (command)
      {
        case "config-check":
          Console.WriteLine("configuration_valid");
          return 0;
        case "init":
          RuntimeRootInitializer.Initialize(configuration, repositoryRoot);
          Console.WriteLine("runtime_initialized");
          return 0;
        case "migrate":
          RuntimeRootInitializer.Initialize(configuration, repositoryRoot);
          var connectionString = PostgreSqlConnectionPolicy.ResolveFromEnvironment(
              configuration.DatabaseConnectionStringEnvironmentVariable);
          await using (var dataSource = PostgreSqlDataSourceFactory.Create(connectionString))
          {
            var applied = await new PostgreSqlMigrationRunner().MigrateAsync(dataSource).ConfigureAwait(false);
            Console.WriteLine(applied == 0 ? "migrations_current" : "migrations_applied");
          }

          return 0;
        default:
          return Fail("command_not_supported");
      }
    }
    catch (LabConfigurationException exception)
    {
      return Fail(exception.Code);
    }
    catch (PostgreSqlPolicyException exception)
    {
      return Fail(exception.Code);
    }
    catch (MigrationIntegrityException exception)
    {
      return Fail(exception.Code);
    }
    catch
    {
      return Fail("unexpected_failure");
    }
  }

  private static Dictionary<string, string> ParseOptions(string[] args)
  {
    var result = new Dictionary<string, string>(StringComparer.Ordinal);
    for (var index = 0; index < args.Length; index += 2)
    {
      if (index + 1 >= args.Length || !args[index].StartsWith("--", StringComparison.Ordinal))
      {
        throw new LabConfigurationException("option_invalid");
      }

      var name = args[index][2..];
      if (!result.TryAdd(name, args[index + 1]))
      {
        throw new LabConfigurationException("option_duplicate");
      }
    }

    return result;
  }

  private static int Fail(string code)
  {
    Console.Error.WriteLine($"error:{code}");
    return 1;
  }
}
