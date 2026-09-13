using System.Text.Json;

namespace NikkeLocalLab.Admin.Api.UnitTests;

public sealed class BossOnboardingTests : IDisposable
{
  private readonly string root = Path.Combine(Path.GetTempPath(), "nll-boss-jobs-test-" + Guid.NewGuid().ToString("N"));
  private readonly Catalog catalog = new();
  private readonly Runner runner = new();
  private FilesystemBossOnboardingService Service() => new(root, catalog, runner);
  private BossOnboardingRequest Request(int season = 1) => new(Guid.NewGuid(), season, catalog.Hash);
  private static readonly CancellationToken None = CancellationToken.None;
  [Fact]
  public async Task RequestIsDurableAndReplayAfterRestartDoesNotRunAProcess()
  {
    var request = Request();
    var job = await Service().StartAsync(request, None);
    Assert.Equal("queued", job.StatusCode);
    Assert.Equal(job, await Service().StartAsync(request, None));
    Assert.Equal(job, Service().Get(job.JobUid));
    Assert.Single(Service().List()); Assert.Equal(0, runner.Runs);
  }
  [Fact]
  public async Task DifferentClicksShareTheJobAndTheirAliasesSurviveCompletionAndRestart()
  {
    var first = Request(); var second = Request();
    var job = await Service().StartAsync(first, None);
    Assert.Equal(job.JobUid, (await Service().StartAsync(second, None)).JobUid);
    Assert.True(await Service().RunNextAsync(None));
    Assert.Equal("awaiting_runtime_delivery", Service().Get(job.JobUid)!.StatusCode);
    Assert.Equal(job.JobUid, (await Service().StartAsync(second, None)).JobUid);
    Assert.Equal(job.JobUid, (await Service().StartAsync(first, None)).JobUid);
    Assert.Equal(1, runner.Runs);
    Assert.Equal("boss_job_operation_conflict", (await Assert.ThrowsAnyAsync<Exception>(() => Service().StartAsync(second with { SeasonNumber = 3 }, None))).Message);
  }
  [Theory]
  [InlineData(0)]
  [InlineData(1001)]
  [InlineData(2)]
  public async Task InvalidOrUnresolvedSeasonCreatesNoJob(int season)
  {
    var error = await Assert.ThrowsAnyAsync<Exception>(() => Service().StartAsync(Request(season), None));
    Assert.Equal("ApiRequestException", error.GetType().Name);
    Assert.Empty(Service().List()); Assert.Equal(0, runner.Runs);
  }
  [Fact]
  public async Task RequestUidConflictAndCatalogDriftFailClosed()
  {
    var request = Request();
    await Service().StartAsync(request, None);
    Assert.Equal("boss_job_operation_conflict", (await Assert.ThrowsAnyAsync<Exception>(() => Service().StartAsync(request with { SeasonNumber = 3 }, None))).Message);
    catalog.Hash = new string('b', 64);
    Assert.True(await Service().RunNextAsync(None));
    Assert.Equal("blocked", Assert.Single(Service().List()).StatusCode);
    Assert.Equal(0, runner.Runs);
  }
  [Fact]
  public async Task TwoWorkersCannotOwnOnePipelineAndReadsDoNotScheduleWork()
  {
    var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var finish = new TaskCompletionSource<BossPipelineResult>(TaskCreationOptions.RunContinuationsAsynchronously);
    runner.Action = (_, _, _) => { entered.SetResult(); return finish.Task; };
    var job = await Service().StartAsync(Request(), None);
    var work = Service().RunNextAsync(None);
    await entered.Task;
    Assert.False(await Service().RunNextAsync(None));
    Assert.Equal("running", Service().Get(job.JobUid)!.StatusCode);
    Assert.Single(Service().List()); Assert.Equal(1, runner.Runs);
    finish.SetResult(Runner.Pending()); await work;
  }
  [Fact]
  public async Task RestartReconcilesInterruptedOwnerOnlyAfterToolTreeRecovery()
  {
    var job = await Service().StartAsync(Request(), None);
    var path = Path.Combine(root, job.JobUid.ToString("D"), "job.json");
    File.WriteAllText(path, JsonSerializer.Serialize(job with { StatusCode = "running" }, new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase }));
    runner.Recovered = false;
    Assert.False(await Service().RunNextAsync(None));
    Assert.Equal("running", Service().Get(job.JobUid)!.StatusCode);
    runner.Recovered = true;
    Assert.False(await Service().RunNextAsync(None));
    Assert.Equal("failed", Service().Get(job.JobUid)!.StatusCode);
    Assert.Equal("boss_job_interrupted", Service().Get(job.JobUid)!.FailureCode);
    Assert.Equal(0, runner.Runs);
  }
  [Fact]
  public async Task FailurePreservesPartialOutputAndRetryUsesANewRoot()
  {
    var outputs = new List<string>();
    runner.Action = (_, output, _) =>
    {
      outputs.Add(output); Directory.CreateDirectory(output); File.WriteAllText(Path.Combine(output, "owned.txt"), "partial synthetic");
      throw new InvalidOperationException("do-not-expose-private-path");
    };
    var first = await Service().StartAsync(Request(), None); await Service().RunNextAsync(None);
    var second = await Service().StartAsync(Request(), None); await Service().RunNextAsync(None);
    Assert.NotEqual(first.JobUid, second.JobUid);
    Assert.NotEqual(outputs[0], outputs[1]);
    Assert.All(outputs, output => Assert.Equal("partial synthetic", File.ReadAllText(Path.Combine(output, "owned.txt"))));
    Assert.All(Service().List(), job => Assert.Equal("boss_pipeline_failed", job.FailureCode));
  }
  [Fact]
  public async Task CompletionWithoutAdmissionReceiptIsRejected()
  {
    runner.Action = (_, _, _) => Task.FromResult(new BossPipelineResult("completed", null, new string('a', 64)));
    var job = await Service().StartAsync(Request(), None); await Service().RunNextAsync(None);
    Assert.Equal("failed", Service().Get(job.JobUid)!.StatusCode);
  }
  [Fact]
  public async Task CandidateAndCompletedAreDifferentTerminalStates()
  {
    runner.Action = (_, _, _) => Task.FromResult(new BossPipelineResult("completed", null, new string('a', 64), new string('b', 64)));
    var job = await Service().StartAsync(Request(), None); await Service().RunNextAsync(None);
    Assert.Equal("completed", Service().Get(job.JobUid)!.StatusCode);
    Assert.Equal(new string('b', 64), Service().Get(job.JobUid)!.AdmissionReceiptSha256);
  }
  [Fact]
  public async Task CorruptJobCannotCauseAWorkerToGuessPathsOrRestart()
  {
    var job = await Service().StartAsync(Request(), None);
    File.WriteAllText(Path.Combine(root, job.JobUid.ToString("D"), "job.json"), "{broken-private-data");
    Assert.Equal("boss_job_store_invalid", Assert.ThrowsAny<Exception>(() => Service().Get(job.JobUid)).Message);
    Assert.Equal("boss_job_store_invalid", (await Assert.ThrowsAnyAsync<Exception>(() => Service().RunNextAsync(None))).Message);
    Assert.Equal(0, runner.Runs);
  }
  private sealed class Catalog : IBossSeasonCatalogService
  {
    public string Hash = new('a', 64);
    public BossSeasonCatalogProjection Get() => new(1, "nll/boss-season-catalog-view/v1", "ready", null, Hash, 3, "unresolved",
        [new(1, "Synthetic", "iron", "unprocessed", null, null),
          new(2, null, null, "unresolved", "boss_missing", null),
          new(3, "Synthetic", "fire", "unprocessed", null, null)]);
    public byte[]? GetImage(int season, string hash) => null;
  }
  private sealed class Runner : IBossPipelineRunner
  {
    public int Runs;
    public bool Recovered = true;
    public Func<BossOnboardingJob, string, CancellationToken, Task<BossPipelineResult>> Action = (_, _, _) => Task.FromResult(Pending());
    public static BossPipelineResult Pending() => new("awaiting_runtime_delivery", "boss_runtime_delivery_required", new string('a', 64));
    public Task<BossPipelineResult> RunAsync(BossOnboardingJob job, string output, CancellationToken token) { Runs++; return Action(job, output, token); }
    public Task<bool> RecoverAsync(BossOnboardingJob job, CancellationToken token) => Task.FromResult(Recovered);
  }
  public void Dispose()
  {
    if (!Directory.Exists(root)) return;
    if (Path.GetDirectoryName(root) != Path.TrimEndingDirectorySeparator(Path.GetTempPath()) ||
        !Path.GetFileName(root).StartsWith("nll-boss-jobs-test-", StringComparison.Ordinal) ||
        (File.GetAttributes(root) & FileAttributes.ReparsePoint) != 0) throw new InvalidOperationException("synthetic_cleanup_boundary_invalid");
    Directory.Delete(root, recursive: true);
  }
}
