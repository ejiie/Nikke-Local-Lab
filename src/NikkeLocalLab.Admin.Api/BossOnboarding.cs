using System.Text.Json;

namespace NikkeLocalLab.Admin.Api;

public sealed record BossOnboardingRequest(Guid OperationUid, int SeasonNumber, string CatalogSha256);
public sealed record BossOnboardingJob(int SchemaVersion, string ContractId, Guid JobUid, Guid OperationUid,
    int SeasonNumber, string CatalogSha256, string StatusCode, string? FailureCode, DateTimeOffset CreatedAtUtc,
    DateTimeOffset UpdatedAtUtc, string? CandidateReceiptSha256 = null, string? AdmissionReceiptSha256 = null);
public sealed record BossPipelineResult(string StatusCode, string? FailureCode, string CandidateReceiptSha256,
    string? AdmissionReceiptSha256 = null);
public interface IBossOnboardingService
{
  Task<BossOnboardingJob> StartAsync(BossOnboardingRequest request, CancellationToken cancellationToken);
  BossOnboardingJob[] List();
  BossOnboardingJob? Get(Guid uid);
}
public interface IBossPipelineRunner
{
  Task<BossPipelineResult> RunAsync(BossOnboardingJob job, string outputRoot, CancellationToken cancellationToken);
  // Recovery concerns only this runner's randomly named offline-tool process Job.
  Task<bool> RecoverAsync(BossOnboardingJob job, CancellationToken cancellationToken);
}
public sealed class UnavailableBossOnboardingService : IBossOnboardingService
{
  public Task<BossOnboardingJob> StartAsync(BossOnboardingRequest request, CancellationToken cancellationToken) =>
      throw new ApiRequestException(503, "boss_onboarding_not_configured");
  public BossOnboardingJob[] List() => [];
  public BossOnboardingJob? Get(Guid uid) => null;
}

// Durable request identity, separate worker ownership, immutable output roots.
// Status GETs only read; HTTP disconnection cannot cancel an accepted operation.
public sealed class FilesystemBossOnboardingService : IBossOnboardingService
{
  private sealed record RequestAlias(Guid OperationUid, Guid JobUid, int SeasonNumber, string CatalogSha256);
  private readonly string root;
  private readonly IBossSeasonCatalogService catalog;
  private readonly IBossPipelineRunner runner;
  private readonly TimeProvider time;
  private readonly SemaphoreSlim requests = new(1, 1);
  public FilesystemBossOnboardingService(string root, IBossSeasonCatalogService catalog, IBossPipelineRunner runner, TimeProvider? time = null)
  {
    this.root = FilesystemBossSeasonCatalogService.Plain(root);
    if (Path.TrimEndingDirectorySeparator(this.root) == Path.TrimEndingDirectorySeparator(Path.GetPathRoot(this.root)!) ||
        this.root.StartsWith(@"C:\NIKKE", StringComparison.OrdinalIgnoreCase)) throw new ArgumentException("boss_job_root_invalid");
    this.catalog = catalog; this.runner = runner; this.time = time ?? TimeProvider.System;
    Directory.CreateDirectory(this.root);
  }
  private string JobRoot(Guid uid) => FilesystemBossSeasonCatalogService.Plain(Path.Combine(root, uid.ToString("D")));
  private static bool Active(BossOnboardingJob job) => job.StatusCode is "queued" or "running";
  private FileStream? TryLease(string name)
  {
    try
    {
      return new FileStream(FilesystemBossSeasonCatalogService.Plain(Path.Combine(root, name)), FileMode.OpenOrCreate,
        FileAccess.ReadWrite, FileShare.None);
    }
    catch (IOException) { return null; }
  }
  public async Task<BossOnboardingJob> StartAsync(BossOnboardingRequest request, CancellationToken cancellationToken)
  {
    if (request.OperationUid == Guid.Empty || request.SeasonNumber is < 1 or > 1000 || !FilesystemBossSeasonCatalogService.IsHash(request.CatalogSha256))
      throw new ApiRequestException(422, "boss_job_request_invalid");
    await requests.WaitAsync(cancellationToken).ConfigureAwait(false);
    try
    {
      using var lease = TryLease(".requests.lock") ?? throw new ApiRequestException(409, "boss_job_request_busy");
      var aliasPath = FilesystemBossSeasonCatalogService.Plain(Path.Combine(root, "requests", request.OperationUid.ToString("D") + ".json"));
      if (File.Exists(aliasPath))
      {
        var alias = JsonSerializer.Deserialize<RequestAlias>(FilesystemBossSeasonCatalogService.ReadFile(aliasPath, 4096),
            FilesystemBossSeasonCatalogService.JsonOptions);
        if (alias is null || alias.OperationUid != request.OperationUid || alias.JobUid == Guid.Empty)
          throw new ApiRequestException(503, "boss_job_store_invalid");
        if (alias.SeasonNumber != request.SeasonNumber || alias.CatalogSha256 != request.CatalogSha256)
          throw new ApiRequestException(409, "boss_job_operation_conflict");
        var aliased = Get(alias.JobUid) ?? throw new ApiRequestException(503, "boss_job_store_invalid");
        if (aliased.SeasonNumber != alias.SeasonNumber || aliased.CatalogSha256 != alias.CatalogSha256)
          throw new ApiRequestException(503, "boss_job_store_invalid");
        return aliased;
      }
      var jobs = List();
      var replay = jobs.SingleOrDefault(job => job.OperationUid == request.OperationUid);
      if (replay is not null)
      {
        if (replay.SeasonNumber != request.SeasonNumber || replay.CatalogSha256 != request.CatalogSha256)
          throw new ApiRequestException(409, "boss_job_operation_conflict");
        return replay;
      }
      var existing = jobs.FirstOrDefault(job => job.SeasonNumber == request.SeasonNumber && Active(job));
      if (existing is not null)
      {
        if (existing.CatalogSha256 != request.CatalogSha256) throw new ApiRequestException(409, "boss_job_inputs_changed");
        Directory.CreateDirectory(FilesystemBossSeasonCatalogService.Plain(Path.GetDirectoryName(aliasPath)!));
        using (var stream = new FileStream(aliasPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
        {
          JsonSerializer.Serialize(stream, new RequestAlias(request.OperationUid, existing.JobUid, request.SeasonNumber,
              request.CatalogSha256), FilesystemBossSeasonCatalogService.JsonOptions);
          stream.Flush(true);
        }
        return existing;
      }
      var snapshot = catalog.Get();
      var selected = snapshot.Seasons.SingleOrDefault(row => row.SeasonNumber == request.SeasonNumber);
      if (snapshot.StatusCode != "ready" || snapshot.CatalogSha256 != request.CatalogSha256 || selected is null ||
          selected.ProcessingStatusCode == "unresolved") throw new ApiRequestException(422, "boss_job_catalog_not_ready");
      if (selected.ProcessingStatusCode == "processed") throw new ApiRequestException(409, "boss_job_already_processed");
      if (jobs.Length >= 1000 || jobs.Count(Active) >= 16) throw new ApiRequestException(409, "boss_job_capacity_reached");
      var now = time.GetUtcNow();
      var job = new BossOnboardingJob(1, "nll/boss-onboarding-job/v1", Guid.NewGuid(), request.OperationUid,
          request.SeasonNumber, request.CatalogSha256, "queued", null, now, now);
      Directory.CreateDirectory(JobRoot(job.JobUid));
      Write(job); // Linearization point: accepted work is durable before 202 response.
      return job;
    }
    finally { requests.Release(); }
  }
  public BossOnboardingJob[] List()
  {
    var directories = Directory.GetDirectories(FilesystemBossSeasonCatalogService.Plain(root));
    if (directories.Length > 1001) throw new ApiRequestException(503, "boss_job_store_limit");
    return directories.Where(path => Guid.TryParseExact(Path.GetFileName(path), "D", out _))
        .Select(path => Get(Guid.Parse(Path.GetFileName(path))))
        .Where(job => job is not null).Cast<BossOnboardingJob>().OrderByDescending(job => job.CreatedAtUtc)
        .ThenBy(job => job.JobUid).ToArray();
  }
  public BossOnboardingJob? Get(Guid uid)
  {
    if (uid == Guid.Empty) return null;
    var path = Path.Combine(JobRoot(uid), "job.json");
    if (!File.Exists(path)) return null;
    try
    {
      var job = JsonSerializer.Deserialize<BossOnboardingJob>(FilesystemBossSeasonCatalogService.ReadFile(path, 16384),
          FilesystemBossSeasonCatalogService.JsonOptions);
      if (job is null || job.SchemaVersion != 1 || job.ContractId != "nll/boss-onboarding-job/v1" || job.JobUid != uid ||
          job.OperationUid == Guid.Empty || job.SeasonNumber is < 1 or > 1000 || !FilesystemBossSeasonCatalogService.IsHash(job.CatalogSha256) ||
          job.StatusCode is not ("queued" or "running" or "failed" or "blocked" or "completed" or "awaiting_runtime_delivery" or "awaiting_game_validation") ||
          job.CreatedAtUtc == default || job.UpdatedAtUtc < job.CreatedAtUtc ||
          (job.FailureCode is not null && !System.Text.RegularExpressions.Regex.IsMatch(job.FailureCode, "\\Aboss_[a-z0-9_]{1,100}\\z")) ||
          (job.CandidateReceiptSha256 is not null && !FilesystemBossSeasonCatalogService.IsHash(job.CandidateReceiptSha256)) ||
          (job.AdmissionReceiptSha256 is not null && !FilesystemBossSeasonCatalogService.IsHash(job.AdmissionReceiptSha256)) ||
          (job.StatusCode == "completed" && (job.FailureCode is not null || job.CandidateReceiptSha256 is null || job.AdmissionReceiptSha256 is null)))
        throw new JsonException();
      return job;
    }
    catch (Exception error) when (FilesystemBossSeasonCatalogService.IsReadFailure(error))
    { throw new ApiRequestException(503, "boss_job_store_invalid"); }
  }
  private void Write(BossOnboardingJob job)
  {
    var path = FilesystemBossSeasonCatalogService.Plain(Path.Combine(JobRoot(job.JobUid), "job.json"));
    var partial = path + ".partial-" + Guid.NewGuid().ToString("N");
    using (var stream = new FileStream(partial, FileMode.CreateNew, FileAccess.Write, FileShare.None))
    {
      JsonSerializer.Serialize(stream, job, FilesystemBossSeasonCatalogService.JsonOptions);
      stream.Flush(true);
    }
    File.Move(partial, path, overwrite: true);
  }
  public async Task<bool> RunNextAsync(CancellationToken stoppingToken)
  {
    using var lease = TryLease(".worker.lock");
    if (lease is null) return false;
    var jobs = List();
    // A preceding owner exited without a terminal write. Never overwrite/reuse its
    // partial candidate and never equate a released lock with zero child processes.
    foreach (var interrupted in jobs.Where(job => job.StatusCode == "running"))
    {
      if (!await runner.RecoverAsync(interrupted, stoppingToken).ConfigureAwait(false)) return false;
      Write(interrupted with { StatusCode = "failed", FailureCode = "boss_job_interrupted", UpdatedAtUtc = time.GetUtcNow() });
    }
    var next = jobs.Where(job => job.StatusCode == "queued").OrderBy(job => job.CreatedAtUtc).FirstOrDefault();
    if (next is null) return false;
    var snapshot = catalog.Get();
    if (snapshot.StatusCode != "ready" || snapshot.CatalogSha256 != next.CatalogSha256 ||
        snapshot.Seasons.SingleOrDefault(row => row.SeasonNumber == next.SeasonNumber)?.ProcessingStatusCode is null or "unresolved")
    {
      Write(next with { StatusCode = "blocked", FailureCode = "boss_job_inputs_changed", UpdatedAtUtc = time.GetUtcNow() });
      return true;
    }
    var running = next with { StatusCode = "running", UpdatedAtUtc = time.GetUtcNow() };
    Write(running);
    try
    {
      var result = await runner.RunAsync(running, Path.Combine(JobRoot(next.JobUid), "output"), stoppingToken).ConfigureAwait(false);
      if (result.StatusCode is not ("completed" or "awaiting_runtime_delivery" or "awaiting_game_validation") ||
          !FilesystemBossSeasonCatalogService.IsHash(result.CandidateReceiptSha256) ||
          (result.AdmissionReceiptSha256 is not null && !FilesystemBossSeasonCatalogService.IsHash(result.AdmissionReceiptSha256)) ||
          (result.FailureCode is not null && !System.Text.RegularExpressions.Regex.IsMatch(result.FailureCode, "\\Aboss_[a-z0-9_]{1,100}\\z")) ||
          (result.StatusCode == "completed" && (!FilesystemBossSeasonCatalogService.IsHash(result.AdmissionReceiptSha256) || result.FailureCode is not null)))
        throw new InvalidOperationException("boss_pipeline_result_invalid");
      Write(running with
      {
        StatusCode = result.StatusCode,
        FailureCode = result.FailureCode,
        CandidateReceiptSha256 = result.CandidateReceiptSha256,
        AdmissionReceiptSha256 = result.AdmissionReceiptSha256,
        UpdatedAtUtc = time.GetUtcNow()
      });
    }
    catch
    {
      // Runner must prove its owned tool tree is cold before allowing another job.
      // If recovery fails, leave 'running' for the next worker recovery pass.
      if (await runner.RecoverAsync(running, CancellationToken.None).ConfigureAwait(false))
        Write(running with { StatusCode = "failed", FailureCode = "boss_pipeline_failed", UpdatedAtUtc = time.GetUtcNow() });
    }
    return true;
  }
}

public sealed class BossOnboardingWorker(IBossOnboardingService service, ILogger<BossOnboardingWorker> logger) : BackgroundService
{
  protected override async Task ExecuteAsync(CancellationToken stoppingToken)
  {
    if (service is not FilesystemBossOnboardingService files) return;
    while (!stoppingToken.IsCancellationRequested)
    {
      try { await files.RunNextAsync(stoppingToken).ConfigureAwait(false); }
      catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { break; }
      catch { logger.LogWarning("boss_onboarding_worker_unavailable"); }
      try { await Task.Delay(TimeSpan.FromSeconds(3), stoppingToken).ConfigureAwait(false); }
      catch (OperationCanceledException) { break; }
    }
  }
}
