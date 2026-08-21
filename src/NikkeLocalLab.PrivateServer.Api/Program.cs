using NikkeLocalLab.Application.PrivateServer;
using NikkeLocalLab.Configuration;
using NikkeLocalLab.Persistence.PostgreSql;
using NikkeLocalLab.PrivateServer.Api;

return await PrivateServerApiProgram.RunAsync(args).ConfigureAwait(false);

public partial class Program;

internal static class PrivateServerApiProgram
{
  public static async Task<int> RunAsync(string[] args)
  {
    try
    {
      var options = ParseOptions(args);
      var configuration = LabConfigurationLoader.Load(
          options["config"],
          options["repository-root"]);
      RuntimeRootInitializer.Initialize(configuration, options["repository-root"]);
      var connectionString = PostgreSqlConnectionPolicy.ResolveFromEnvironment(
          configuration.DatabaseConnectionStringEnvironmentVariable);
      var policyOptions = configuration.ChallengeOperationalPolicy;
      var initialPolicy =
          global::NikkeLocalLab.Domain.PrivateServer.ChallengeOperationalPolicy
              .CreateFromControlledCodes(
                  global::NikkeLocalLab.Identity.EntityUid.New(),
                  policyOptions.PolicyId,
                  policyOptions.ResolutionStatus,
                  policyOptions.DailyEntryLimit,
                  policyOptions.EntryConsumptionPoint,
                  policyOptions.ActiveRunAtReset,
                  policyOptions.DailyCounterScope,
                  policyOptions.MockBattleCapability,
                  policyOptions.LocalRankingCapability);
      await using var runtime = await PostgreSqlPrivateServerRuntime.CreateAsync(
          connectionString,
          initialPolicy).ConfigureAwait(false);
      await using var app = PrivateServerApiHost.Build(
          [],
          new PrivateServerApiHostOptions
          {
            Port = configuration.PrivateServerPort,
            ConfigureServices = services => services.AddSingleton(runtime.Service)
          });
      await app.RunAsync().ConfigureAwait(false);
      return 0;
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
    catch (PrivateServerApplicationException exception)
    {
      return Fail(exception.Code);
    }
    catch
    {
      return Fail("private_server_start_failed");
    }
  }

  private static IReadOnlyDictionary<string, string> ParseOptions(string[] args)
  {
    if (args.Length != 4)
    {
      throw new LabConfigurationException("required_option_missing");
    }

    var result = new Dictionary<string, string>(StringComparer.Ordinal);
    for (var index = 0; index < args.Length; index += 2)
    {
      if (!args[index].StartsWith("--", StringComparison.Ordinal) ||
          string.IsNullOrWhiteSpace(args[index + 1]) ||
          !result.TryAdd(args[index][2..], args[index + 1]))
      {
        throw new LabConfigurationException("option_invalid");
      }
    }

    if (result.Count != 2 || !result.ContainsKey("config") ||
        !result.ContainsKey("repository-root"))
    {
      throw new LabConfigurationException("required_option_missing");
    }

    return result;
  }

  private static int Fail(string code)
  {
    Console.Error.WriteLine($"error:{code}");
    return 1;
  }
}
