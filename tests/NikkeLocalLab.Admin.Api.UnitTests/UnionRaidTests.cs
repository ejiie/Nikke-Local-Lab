using System.Security.Cryptography;
using System.Text.Json;

namespace NikkeLocalLab.Admin.Api.UnitTests;

public sealed class UnionRaidTests : IDisposable
{
  private readonly string root = Path.Combine(Path.GetTempPath(), "nll-union-test-" + Guid.NewGuid().ToString("N"));
  private readonly JsonSerializerOptions json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
  private UnionRaidSeasonView Season(int number, int count = 5) => new(number, "available", null, new string('c', 64),
      Enumerable.Range(1, count).Select(order => new UnionRaidBossView(order, "합성 보스")).ToArray());
  private UnionRaidCatalogService Service(params UnionRaidSeasonView[] seasons)
  {
    Directory.CreateDirectory(root);
    var path = Path.Combine(root, "catalog.json");
    File.WriteAllText(path, JsonSerializer.Serialize(new UnionRaidCatalogDocument(1, "nll/union-raid-hard-catalog/v1", new string('a', 64), seasons), json));
    var hash = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path))).ToLowerInvariant();
    return new(path, hash, Path.Combine(root, "registry"));
  }
  [Fact]
  public void CatalogOrdersNewestFirstAndRejectsPartialOrDuplicateSeasons()
  {
    Assert.Equal([3, 1], Service(Season(1), Season(3)).Read().Seasons.Select(s => s.SeasonNumber).ToArray());
    Assert.Throws<ApiRequestException>(() => Service(Season(3, 4)).Read());
    Assert.Throws<ApiRequestException>(() => Service(Season(3), Season(3)).Read());
  }
  [Fact]
  public async Task DurableWorkerKeepsFailedSeasonUnpublishedAndReplaysTheSameOperation()
  {
    var catalog = Service(Season(3));
    var jobs = new FilesystemBossOnboardingService(Path.Combine(root, "jobs"), catalog, new FailingRunner());
    var request = new BossOnboardingRequest(Guid.NewGuid(), 3, catalog.Read().CatalogSha256);
    var first = await jobs.StartAsync(request, default);
    Assert.Equal(first.JobUid, (await jobs.StartAsync(request, default)).JobUid);
    await jobs.RunNextAsync(default);
    Assert.Equal("failed", jobs.Get(first.JobUid)!.StatusCode);
    Assert.Equal("available", catalog.Read().Seasons.Single().StatusCode);
  }
  private sealed class FailingRunner : IBossPipelineRunner
  {
    public Task<BossPipelineResult> RunAsync(BossOnboardingJob job, string output, CancellationToken token) =>
        throw new BossPipelineException("boss_union_behavior_unresolved");
    public Task<bool> RecoverAsync(BossOnboardingJob job, CancellationToken token) => Task.FromResult(true);
  }
  public void Dispose() { if (Directory.Exists(root)) Directory.Delete(root, true); }
}
