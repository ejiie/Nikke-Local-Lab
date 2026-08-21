using NikkeLocalLab.Application.ProfileManagement;
using NikkeLocalLab.Admin.Api;
using NikkeLocalLab.Configuration;
using NikkeLocalLab.Persistence.PostgreSql;

return await AdminApiProgram.RunAsync(args).ConfigureAwait(false);

public partial class Program;

internal static class AdminApiProgram
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
      await using var profileRuntime = await PostgreSqlProfileManagementRuntime.CreateAsync(
          connectionString).ConfigureAwait(false);
      await using var privateServerRuntime = await PostgreSqlPrivateServerRuntime.CreateAsync(
          connectionString,
          initialPolicy).ConfigureAwait(false);

      await using var app = AdminApiHost.Build(
          [],
          new AdminApiHostOptions
          {
            Port = configuration.AdminPort,
            BootstrapCodeSink = DeliverBootstrapCode,
            RequirePrivateServerAdministration = true,
            ConfigureServices = services =>
            {
              services.AddSingleton(profileRuntime.Service);
              services.AddSingleton(privateServerRuntime.Service);
            }
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
    catch (ProfileManagementException exception)
    {
      return Fail(exception.Code);
    }
    catch (NikkeLocalLab.Application.PrivateServer.PrivateServerApplicationException exception)
    {
      return Fail(exception.Code);
    }
    catch
    {
      return Fail("admin_start_failed");
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

  private static void DeliverBootstrapCode(string code)
  {
    Console.Error.WriteLine($"Nikke Local Lab one-time admin code: {code}");
  }

  private static int Fail(string code)
  {
    Console.Error.WriteLine($"error:{code}");
    return 1;
  }
}
