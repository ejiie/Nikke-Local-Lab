using System.Text.Json;

namespace NikkeLocalLab.Admin.Api;

internal static class BossOnboardingComposition
{
  internal static void Configure(IServiceCollection services, string repositoryRoot, string connectionString)
  {
    var path = Environment.GetEnvironmentVariable("NLL_BOSS_PIPELINE_CONFIG_PATH");
    var digest = Environment.GetEnvironmentVariable("NLL_BOSS_PIPELINE_CONFIG_SHA256");
    if (string.IsNullOrWhiteSpace(path) && string.IsNullOrWhiteSpace(digest)) return;
    var bytes = FilesystemBossSeasonCatalogService.ReadFile(path!, 1048576);
    FilesystemBossSeasonCatalogService.Require(FilesystemBossSeasonCatalogService.IsHash(digest) &&
        FilesystemBossSeasonCatalogService.Hash(bytes) == digest);
    using var document = JsonDocument.Parse(bytes);
    var root = document.RootElement;
    string Text(string key) => root.GetProperty(key).GetString() ?? throw new JsonException("boss_pipeline_configuration_invalid");
    FilesystemBossSeasonCatalogService.Require(root.GetProperty("schemaVersion").GetInt32() == 1 &&
        Text("contractId") == "nll/boss-pipeline-config/v1" &&
        FilesystemBossSeasonCatalogService.Plain(Text("repositoryRoot")) == FilesystemBossSeasonCatalogService.Plain(repositoryRoot));
    UserValidationDelivery? delivery = null;
    if (root.TryGetProperty("userValidationDelivery", out var deliveryPin))
    {
      delivery = new(deliveryPin.GetProperty("path").GetString()!, deliveryPin.GetProperty("sha256").GetString()!);
      services.AddSingleton(delivery);
      services.AddSingleton(new UserValidationExecution(delivery));
    }
    var catalog = new FilesystemBossSeasonCatalogService(Text("catalogPath"), Text("catalogSha256"), Text("registryRoot"), delivery);
    if (root.TryGetProperty("characterSync", out var characterSync))
      services.AddSingleton<ICharacterCatalogSynchronizer>(new CharacterCatalogSynchronization(
          characterSync.Deserialize<CharacterCatalogSyncOptions>(FilesystemBossSeasonCatalogService.JsonOptions)
              ?? throw new JsonException("character_catalog_sync_configuration_invalid"),
          path!, digest!, Text("powerShellPath"), Text("powerShellSha256")));
    var runner = new PowerShellBossPipelineRunner(new(Text("powerShellPath"), Text("powerShellSha256"),
        Path.Combine(repositoryRoot, "scripts", "invoke-nll-boss-onboarding-job.ps1"), Text("workerSha256"), path!, digest!,
        root.GetProperty("timeoutSeconds").GetInt32()), delivery);
    if (root.TryGetProperty("seasonSync", out var syncEntry))
    {
      var options = syncEntry.Deserialize<BossSeasonSyncOptions>(FilesystemBossSeasonCatalogService.JsonOptions)
          ?? throw new JsonException("boss_catalog_sync_configuration_invalid");
      var synchronization = new BossSeasonSynchronization(options.Root, path!, digest!, new PowerShellBossSeasonSyncRunner(options), delivery: delivery);
      services.AddSingleton<IBossSeasonCatalogService>(synchronization);
      services.AddSingleton<IBossSeasonSynchronizer>(synchronization);
      services.AddSingleton<IBossOnboardingService>(new FilesystemBossOnboardingService(Text("jobsRoot"), synchronization, synchronization, userValidation: delivery));
    }
    else
    {
      services.AddSingleton<IBossSeasonCatalogService>(catalog);
      services.AddSingleton<IBossOnboardingService>(new FilesystemBossOnboardingService(Text("jobsRoot"), catalog, runner, userValidation: delivery));
    }
    services.AddHostedService<BossOnboardingWorker>();
    if (root.TryGetProperty("unionRaid", out var union))
    {
      string U(string key) => union.GetProperty(key).GetString() ?? throw new JsonException("boss_union_configuration_invalid");
      var unionRegistryRoot = U("registryRoot");
      var unionCatalog = new UnionRaidCatalogService(U("catalogPath"), U("catalogSha256"), unionRegistryRoot);
      var unionRunner = new PowerShellBossPipelineRunner(new(Text("powerShellPath"), Text("powerShellSha256"),
          Path.Combine(repositoryRoot, "scripts", "invoke-nll-union-raid-job.ps1"), U("workerSha256"), path!, digest!,
          root.GetProperty("timeoutSeconds").GetInt32()), resultReader: async (output, job) =>
          {
            var result = UnionRaidService.ReadResult(output, job);
            var publication = Path.Combine(unionRegistryRoot, $"{job.SeasonNumber}-{job.CatalogSha256}");
            var bytes = FilesystemBossSeasonCatalogService.ReadFile(Path.Combine(publication, "receipt.json"), 16384);
            if (FilesystemBossSeasonCatalogService.Hash(bytes) != result.CandidateReceiptSha256)
              throw new InvalidOperationException("boss_union_publication_changed");
            await using var source = Npgsql.NpgsqlDataSource.Create(connectionString);
            await NikkeLocalLab.Persistence.PostgreSql.LocalUnionStore.SelectAsync(source, job.SeasonNumber,
                job.CatalogSha256, publication, result.CandidateReceiptSha256).ConfigureAwait(false);
            return result;
          });
      services.AddSingleton(new UnionRaidService(unionCatalog,
          new FilesystemBossOnboardingService(U("jobsRoot"), unionCatalog, unionRunner)));
      services.AddHostedService<UnionRaidWorker>();
    }
  }
}
