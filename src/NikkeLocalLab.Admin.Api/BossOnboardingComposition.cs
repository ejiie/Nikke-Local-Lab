using System.Text.Json;

namespace NikkeLocalLab.Admin.Api;

internal static class BossOnboardingComposition
{
  internal static void Configure(IServiceCollection services, string repositoryRoot)
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
    var catalog = new FilesystemBossSeasonCatalogService(Text("catalogPath"), Text("catalogSha256"), Text("registryRoot"));
    var runner = new PowerShellBossPipelineRunner(new(Text("powerShellPath"), Text("powerShellSha256"),
        Path.Combine(repositoryRoot, "scripts", "invoke-nll-boss-onboarding-job.ps1"), Text("workerSha256"), path!, digest!,
        root.GetProperty("timeoutSeconds").GetInt32()));
    services.AddSingleton<IBossSeasonCatalogService>(catalog);
    services.AddSingleton<IBossOnboardingService>(new FilesystemBossOnboardingService(Text("jobsRoot"), catalog, runner));
    services.AddHostedService<BossOnboardingWorker>();
  }
}
