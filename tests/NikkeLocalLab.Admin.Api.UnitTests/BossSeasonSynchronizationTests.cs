using System.Security.Cryptography;
using System.Text.Json;

namespace NikkeLocalLab.Admin.Api.UnitTests;

public sealed class BossSeasonSynchronizationTests : IDisposable
{
  private readonly string root = Path.Combine(Path.GetTempPath(), "nll-sync-test-" + Guid.NewGuid().ToString("N"));
  private static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
  private string Config => Path.Combine(root, "initial.json");
  private static string Hash(string path) => Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path))).ToLowerInvariant();
  private static void Write(string path, object value) => File.WriteAllBytes(path, JsonSerializer.SerializeToUtf8Bytes(value, Json));
  private readonly StubSync runner = new();
  private readonly StubPipeline worker = new();
  public BossSeasonSynchronizationTests()
  {
    Directory.CreateDirectory(root);
    Directory.CreateDirectory(Path.Combine(root, "registry"));
    Write(Path.Combine(root, "registry", "registry.json"), new { schemaVersion = 1, contractId = "nll/boss-runtime-variant-registry/v1", profiles = Array.Empty<object>() });
    Candidate(root, Config, 40);
    runner.Action = (_, output, _) => Task.FromResult(Candidate(output, Path.Combine(output, "next.json"), 41));
  }
  private BossSeasonSyncCandidate Candidate(string directory, string config, int count, bool damageOld = false, bool missing = false)
  {
    var path = Path.Combine(directory, "catalog.json");
    Write(path, new BossSeasonSnapshot(1, "nll/boss-season-catalog/v1", new string('a', 64), new string('b', 64), count, "unresolved",
        Enumerable.Range(1, count).Select(n => missing && n == 19 ?
            new BossSeasonCard(n, null, null, "unresolved", "phase_d_boss_catalog_manager_unresolved", "unresolved", "unresolved", null) :
            new BossSeasonCard(n, damageOld && n == 1 ? "changed" : "Synthetic " + n,
            "water", "resolved", null, "resolved", "unresolved", null)).ToArray()));
    Write(config, new
    {
      schemaVersion = 1,
      contractId = "nll/boss-pipeline-config/v1",
      registryRoot = Path.Combine(root, "registry"),
      jobsRoot = Path.Combine(root, "jobs"),
      catalogPath = path,
      catalogSha256 = Hash(path),
      powerShellPath = "synthetic-shell",
      powerShellSha256 = new string('c', 64),
      repositoryRoot = root,
      workerSha256 = new string('d', 64),
      timeoutSeconds = 30
    });
    return new("updated", config, Hash(config));
  }
  private BossSeasonSynchronization Service() => new(Path.Combine(root, "sync"), Config, Hash(Config), runner,
      options => { worker.Options = options; return worker; });
  private sealed class StubSync : IBossSeasonSyncRunner
  {
    public Func<BossPipelineOptions, string, CancellationToken, Task<BossSeasonSyncCandidate>> Action { get; set; } = null!;
    public Task<BossSeasonSyncCandidate> RunAsync(BossPipelineOptions current, string output, CancellationToken token) => Action(current, output, token);
  }
  private sealed class StubPipeline : IBossPipelineRunner
  {
    public BossPipelineOptions? Options { get; set; }
    public Task<BossPipelineResult> RunAsync(BossOnboardingJob job, string outputRoot, CancellationToken token) =>
        Task.FromResult(new BossPipelineResult("awaiting_runtime_delivery", "boss_runtime_delivery_required", new string('e', 64)));
    public Task<bool> RecoverAsync(BossOnboardingJob job, CancellationToken token) => Task.FromResult(true);
  }
  [Fact]
  public async Task NewSeasonIsImportableAndQueuedOldRevisionSurvivesSyncAndRestart()
  {
    var service = Service();
    var old = service.Get();
    var onboarding = new FilesystemBossOnboardingService(Path.Combine(root, "jobs"), service, service);
    var queued = await onboarding.StartAsync(new(Guid.NewGuid(), 1, old.CatalogSha256!), default);
    Assert.Equal(new BossSeasonSyncResult("updated", 1), await service.SynchronizeAsync(default));
    var restarted = Service();
    Assert.Equal(41, restarted.Get().MaximumKnownSeason);
    Assert.Equal(40, restarted.GetRevision(old.CatalogSha256!).MaximumKnownSeason);
    onboarding = new(Path.Combine(root, "jobs"), restarted, restarted);
    Assert.True(await onboarding.RunNextAsync(default));
    Assert.Equal("awaiting_runtime_delivery", onboarding.Get(queued.JobUid)!.StatusCode);
    Assert.Equal(Config, worker.Options!.ConfigurationPath);
    await onboarding.StartAsync(new(Guid.NewGuid(), 41, restarted.Get().CatalogSha256!), default);
    Assert.True(await onboarding.RunNextAsync(default));
    Assert.NotEqual(Config, worker.Options!.ConfigurationPath);
  }
  [Fact]
  public async Task UnchangedOrFailedReadPreservesCatalog()
  {
    var service = Service(); var before = service.Get().CatalogSha256;
    runner.Action = (_, _, _) => Task.FromResult(new BossSeasonSyncCandidate("unchanged"));
    Assert.Equal("unchanged", (await service.SynchronizeAsync(default)).StatusCode);
    Assert.Equal(before, service.Get().CatalogSha256);
    runner.Action = (_, _, _) => throw new BossPipelineException("boss_catalog_sync_source_missing");
    Assert.Equal("boss_catalog_sync_source_missing", (await service.SynchronizeAsync(default)).FailureCode);
    Assert.Equal(before, Service().Get().CatalogSha256);
  }
  [Fact]
  public async Task CandidateCannotRewriteExistingSeasons()
  {
    var service = Service(); var before = service.Get().CatalogSha256;
    runner.Action = (_, output, _) => Task.FromResult(Candidate(output, Path.Combine(output, "next.json"), 41, true));
    Assert.Equal("failed", (await service.SynchronizeAsync(default)).StatusCode);
    Assert.Equal(before, Service().Get().CatalogSha256);
  }
  [Fact]
  public async Task ExistingUnresolvedSeasonCanRecoverWithoutAddingASeason()
  {
    Candidate(root, Config, 40, missing: true);
    var service = Service();
    var old = service.Get();
    runner.Action = (_, output, _) => Task.FromResult(Candidate(output, Path.Combine(output, "next.json"), 40));
    Assert.Equal(new BossSeasonSyncResult("updated", 0), await service.SynchronizeAsync(default));
    Assert.Equal("Synthetic 19", Service().Get().Seasons[18].DisplayName);
    Assert.Null(Service().GetRevision(old.CatalogSha256!).Seasons[18].DisplayName);
  }

  [Fact]
  public async Task ConcurrentClicksDoNotStartTwoImports()
  {
    var completion = new TaskCompletionSource<BossSeasonSyncCandidate>();
    runner.Action = (_, _, _) => completion.Task;
    var service = Service(); var first = service.SynchronizeAsync(default);
    Assert.Equal("busy", (await service.SynchronizeAsync(default)).StatusCode);
    completion.SetResult(new("unchanged"));
    Assert.Equal("unchanged", (await first).StatusCode);
  }
  public void Dispose() => Directory.Delete(root, true);
}
