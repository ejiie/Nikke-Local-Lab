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
      var phaseDControlCenter = string.Equals(
          Environment.GetEnvironmentVariable("NLL_PHASE_D_CONTROL_CENTER"),
          "1",
          StringComparison.Ordinal) ||
          (options.TryGetValue("phase-d-control-center", out var phaseDControlCenterValue) &&
           string.Equals(phaseDControlCenterValue, "true", StringComparison.Ordinal));
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
      await using PostgreSqlPrivateServerRuntime? privateServerRuntime = phaseDControlCenter
          ? null
          : await PostgreSqlPrivateServerRuntime.CreateAsync(
              connectionString,
              initialPolicy).ConfigureAwait(false);

      await using var app = AdminApiHost.Build(
          [],
          new AdminApiHostOptions
          {
            Port = configuration.AdminPort,
            BootstrapCodeSink = DeliverBootstrapCode,
            RequirePrivateServerAdministration = !phaseDControlCenter,
            RequirePhaseDExecution = true,
            ConfigureServices = services =>
            {
              services.AddSingleton(profileRuntime.Service);
              services.AddSingleton(_ => PostgreSqlDataSourceFactory.Create(connectionString));
              services.AddSingleton<AccountDirectoryStore>();
              services.AddSingleton<RaidRecordStore>();
              services.AddSingleton(new RaidCompositionPaths(
                  Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "NikkeLocalLab", "BattleLogs"),
                  Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "NikkeLocalLab", "BattleAnalysis")));
              services.AddSingleton<RaidCompositionStore>();
              var bossCatalogPath = Environment.GetEnvironmentVariable("NLL_BOSS_CATALOG_PATH");
              var bossCatalogSha256 = Environment.GetEnvironmentVariable("NLL_BOSS_CATALOG_SHA256");
              if (!string.IsNullOrWhiteSpace(bossCatalogPath) && !string.IsNullOrWhiteSpace(bossCatalogSha256))
                services.AddSingleton<IBossSeasonCatalogService>(new FilesystemBossSeasonCatalogService(bossCatalogPath,
                    bossCatalogSha256, Path.Combine(options["repository-root"], "config", "boss-runtime-variants")));
              BossOnboardingComposition.Configure(services, options["repository-root"], connectionString);
              if (privateServerRuntime is not null)
              {
                services.AddSingleton(privateServerRuntime.Service);
              }
              services.AddSingleton<IPhaseDPreparationService>(new PowerShellPhaseDPreparationService(
                  options["repository-root"], Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                      "System32", "WindowsPowerShell", "v1.0", "powershell.exe")));
              services.AddSingleton<IPhaseDExecutionService>(provider =>
                  new FilesystemPhaseDExecutionService(
                      provider.GetRequiredService<IProfileManagementService>(),
                      new PhaseDExecutionOptions(
                          options["repository-root"],
                          options["config"],
                          Path.Combine(
                              options["repository-root"],
                              "artifacts",
                              "automation",
                              "phase-d-executions"),
                          Path.Combine(
                              Directory.GetParent(
                                  Environment.GetEnvironmentVariable("NIKKE_LAB_HOME") ??
                                  throw new LabConfigurationException("runtime_root_missing"))?.FullName ??
                              throw new LabConfigurationException("runtime_root_missing"),
                              "state",
                              "phase-d-solo-raid"),
                           Path.Combine(
                               options["repository-root"],
                               "scripts",
                               "invoke-nll-phase-d-execution.ps1"),
                           Path.Combine(
                               options["repository-root"],
                               "scripts",
                               "recover-nll-phase-d-orphaned-execution.ps1"),
                           Path.Combine(
                              Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                              "System32",
                              "WindowsPowerShell",
                              "v1.0",
                              "powershell.exe")),
                      logger: provider.GetRequiredService<ILogger<FilesystemPhaseDExecutionService>>()));
              services.AddHostedService<PhaseDLifecycleWorker>();
              services.AddSingleton(new AccountImportOptions(
                          options["repository-root"],
                          options["config"],
                          Path.Combine(
                              options["repository-root"],
                              "scripts",
                              "invoke-nll-phase-c-fresh-account-fetch.ps1"),
                          Path.Combine(
                              options["repository-root"],
                              "src",
                              "NikkeLocalLab.Import.Cli",
                              "bin",
                              "Release",
                              "net8.0",
                              "NikkeLocalLab.Import.Cli.dll"),
                          Path.Combine(
                              Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                              "dotnet",
                              "dotnet.exe"),
                          Path.Combine(
                              Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                              "System32",
                              "WindowsPowerShell",
                              "v1.0",
                              "powershell.exe"),
                          Path.Combine(
                              Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                              "Database",
                              "raw",
                              "nikke_full_scroll_result.json"),
                          Environment.GetEnvironmentVariable("NIKKE_LAB_HOME") ??
                              throw new LabConfigurationException("runtime_root_missing")));

              services.AddSingleton<IAccountImportService, FilesystemAccountImportService>();
              services.AddSingleton<AccountConnectionService>();
              services.AddSingleton(provider => new AccountFrameArtwork(
                  provider.GetRequiredService<Npgsql.NpgsqlDataSource>(),
                  provider.GetRequiredService<AccountImportOptions>(),
                  configuration.IdentitySecretEnvironmentVariable,
                  provider.GetRequiredService<ILogger<AccountFrameArtwork>>()));
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
    if (args.Length is not (4 or 6))
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

    if (!result.ContainsKey("config") || !result.ContainsKey("repository-root") ||
        result.Keys.Any(static key => key is not (
            "config" or "repository-root" or "phase-d-control-center")) ||
        (result.TryGetValue("phase-d-control-center", out var phaseDValue) &&
         !string.Equals(phaseDValue, "true", StringComparison.Ordinal)))
    {
      throw new LabConfigurationException("required_option_missing");
    }

    return result;
  }

  private static void DeliverBootstrapCode(string code)
  {
    var sinkPath = Environment.GetEnvironmentVariable("NLL_CONTROL_CENTER_BOOTSTRAP_PATH");
    if (!string.IsNullOrWhiteSpace(sinkPath) && Path.IsPathFullyQualified(sinkPath))
    {
      Directory.CreateDirectory(Path.GetDirectoryName(sinkPath)!);
      File.WriteAllText(sinkPath, code, new System.Text.UTF8Encoding(false));
    }
    Console.Error.WriteLine($"Nikke Local Lab one-time admin code: {code}");
  }

  private static int Fail(string code)
  {
    Console.Error.WriteLine($"error:{code}");
    return 1;
  }
}
