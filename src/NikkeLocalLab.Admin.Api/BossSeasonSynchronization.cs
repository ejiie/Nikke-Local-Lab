using System.Text;
using System.Text.Json;
using Nll.PhaseD;
using static NikkeLocalLab.Admin.Api.FilesystemBossSeasonCatalogService;

namespace NikkeLocalLab.Admin.Api;

public sealed record BossSeasonSyncOptions(string Root, string SourcePackPath, string LocaleSourcePath,
    string ScriptPath, string ScriptSha256, string MaterializerPath, string MaterializerSha256);
public sealed record BossSeasonSyncResult(string StatusCode, int AddedSeasonCount, string? FailureCode = null);
public sealed record BossSeasonSyncCandidate(string StatusCode, string? ConfigurationPath = null, string? ConfigurationSha256 = null);
public interface IBossSeasonSynchronizer
{
  Task<BossSeasonSyncResult> SynchronizeAsync(CancellationToken cancellationToken);
}
public interface IBossSeasonSyncRunner
{
  Task<BossSeasonSyncCandidate> RunAsync(BossPipelineOptions current, string output, CancellationToken cancellationToken);
}

// Catalog and import inputs switch together. Jobs already accepted keep their
// catalog revision, including after an API restart. Published profiles stay put.
public sealed class BossSeasonSynchronization : IBossSeasonCatalogService, IBossPipelineRunner, IBossSeasonSynchronizer
{
  private sealed record Revision(string ConfigurationPath, string ConfigurationSha256);
  private sealed record Bound(IBossSeasonCatalogService Catalog, BossPipelineOptions Options);
  private readonly string root;
  private readonly Bound initial;
  private readonly string initialHash;
  private readonly string registryRoot;
  private readonly string jobsRoot;
  private readonly IBossSeasonSyncRunner sync;
  private readonly Func<BossPipelineOptions, IBossPipelineRunner> pipeline;
  private readonly UserValidationDelivery? delivery;
  private readonly SemaphoreSlim gate = new(1, 1);
  private string currentHash;

  public BossSeasonSynchronization(string root, string configurationPath, string configurationSha256,
      IBossSeasonSyncRunner sync, Func<BossPipelineOptions, IBossPipelineRunner>? pipeline = null,
      UserValidationDelivery? delivery = null)
  {
    this.root = Plain(root); this.sync = sync; this.delivery = delivery;
    this.pipeline = pipeline ?? (options => new PowerShellBossPipelineRunner(options, delivery));
    using var document = ReadConfiguration(new(configurationPath, configurationSha256));
    registryRoot = document.RootElement.GetProperty("registryRoot").GetString()!;
    jobsRoot = document.RootElement.GetProperty("jobsRoot").GetString()!;
    initial = Bind(new(configurationPath, configurationSha256));
    initialHash = initial.Catalog.Get().CatalogSha256 ?? throw new JsonException("boss_catalog_unavailable");
    Directory.CreateDirectory(Plain(Path.Combine(root, "revisions")));
    currentHash = File.Exists(Path.Combine(root, "current.json"))
        ? JsonSerializer.Deserialize<string>(ReadFile(Path.Combine(root, "current.json"), 256))! : initialHash;
    _ = Resolve(currentHash);
  }

  private static JsonDocument ReadConfiguration(Revision revision)
  {
    var bytes = ReadFile(revision.ConfigurationPath, 1048576);
    Require(IsHash(revision.ConfigurationSha256) && Hash(bytes) == revision.ConfigurationSha256);
    return JsonDocument.Parse(bytes);
  }
  private Bound Bind(Revision revision)
  {
    using var document = ReadConfiguration(revision);
    var c = document.RootElement;
    string Text(string key) => c.GetProperty(key).GetString()!;
    Require(Text("contractId") == "nll/boss-pipeline-config/v1" && c.GetProperty("schemaVersion").GetInt32() == 1 &&
        Text("registryRoot") == registryRoot && Text("jobsRoot") == jobsRoot);
    return new(new FilesystemBossSeasonCatalogService(Text("catalogPath"), Text("catalogSha256"), registryRoot, delivery),
        new(Text("powerShellPath"), Text("powerShellSha256"),
            Path.Combine(Text("repositoryRoot"), "scripts", "invoke-nll-boss-onboarding-job.ps1"), Text("workerSha256"),
            revision.ConfigurationPath, revision.ConfigurationSha256, c.GetProperty("timeoutSeconds").GetInt32()));
  }
  private Bound Resolve(string hash)
  {
    Require(IsHash(hash));
    if (hash == initialHash) return initial;
    var revision = JsonSerializer.Deserialize<Revision>(ReadFile(Path.Combine(root, "revisions", hash + ".json"), 8192), JsonOptions);
    Require(revision is not null && Path.GetFullPath(revision.ConfigurationPath).StartsWith(
        root.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase));
    var bound = Bind(revision!);
    Require(bound.Catalog.Get().CatalogSha256 == hash);
    return bound;
  }
  public BossSeasonCatalogProjection Get() => Resolve(Volatile.Read(ref currentHash)).Catalog.Get();
  public BossSeasonCatalogProjection GetRevision(string hash) => Resolve(hash).Catalog.Get();
  public byte[]? GetImage(int season, string hash)
  {
    try { return Resolve(hash).Catalog.GetImage(season, hash); }
    catch (Exception error) when (IsReadFailure(error)) { return null; }
  }
  public Task<BossPipelineResult> RunAsync(BossOnboardingJob job, string outputRoot, CancellationToken token) =>
      pipeline(Resolve(job.CatalogSha256).Options).RunAsync(job, outputRoot, token);
  public Task<bool> RecoverAsync(BossOnboardingJob job, CancellationToken token) => pipeline(initial.Options).RecoverAsync(job, token);

  public async Task<BossSeasonSyncResult> SynchronizeAsync(CancellationToken token)
  {
    if (!await gate.WaitAsync(0, token).ConfigureAwait(false)) return new("busy", 0, "boss_catalog_sync_busy");
    try
    {
      var previous = Resolve(currentHash);
      var before = previous.Catalog.Get();
      var output = Plain(Path.Combine(root, "runs", Guid.NewGuid().ToString("N")));
      Directory.CreateDirectory(output);
      var result = await sync.RunAsync(previous.Options, output, token).ConfigureAwait(false);
      if (result.StatusCode == "unchanged") return new("unchanged", 0);
      Require(result.StatusCode == "updated" && result.ConfigurationPath is not null && result.ConfigurationSha256 is not null &&
          Plain(result.ConfigurationPath).StartsWith(output + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase));
      var revision = new Revision(result.ConfigurationPath!, result.ConfigurationSha256!);
      var next = Bind(revision).Catalog.Get();
      Require(next.StatusCode == "ready" && IsHash(next.CatalogSha256) && next.MaximumKnownSeason >= before.MaximumKnownSeason &&
          before.Seasons.All(old =>
              (old.ProcessingStatusCode == "unresolved" && next.Seasons[old.SeasonNumber - 1].ProcessingStatusCode != "unresolved" &&
               (old.DisplayName is null || next.Seasons[old.SeasonNumber - 1].DisplayName == old.DisplayName) &&
               (old.DefaultWeaknessCode is null || next.Seasons[old.SeasonNumber - 1].DefaultWeaknessCode == old.DefaultWeaknessCode)) ||
              (next.Seasons[old.SeasonNumber - 1].DisplayName == old.DisplayName &&
               next.Seasons[old.SeasonNumber - 1].DefaultWeaknessCode == old.DefaultWeaknessCode)));
      WriteAtomic(Path.Combine(root, "revisions", next.CatalogSha256 + ".json"), revision);
      WriteAtomic(Path.Combine(root, "current.json"), next.CatalogSha256);
      Volatile.Write(ref currentHash, next.CatalogSha256!);
      return new("updated", next.MaximumKnownSeason - before.MaximumKnownSeason);
    }
    catch (OperationCanceledException) { throw; }
    catch (Exception error) when (IsReadFailure(error) || error is BossPipelineException or System.ComponentModel.Win32Exception)
    { return new("failed", 0, error is BossPipelineException failure ? failure.FailureCode : "boss_catalog_sync_failed"); }
    finally { gate.Release(); }
  }
  private static void WriteAtomic<T>(string path, T value)
  {
    var temporary = Plain(path + "." + Guid.NewGuid().ToString("N") + ".tmp");
    using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
    { JsonSerializer.Serialize(stream, value, JsonOptions); stream.Flush(true); }
    File.Move(temporary, Plain(path), true);
  }
}

public sealed class PowerShellBossSeasonSyncRunner(BossSeasonSyncOptions options) : IBossSeasonSyncRunner
{
  public async Task<BossSeasonSyncCandidate> RunAsync(BossPipelineOptions current, string output, CancellationToken token)
  {
    foreach (var (path, hash, limit) in new[] { (options.ScriptPath, options.ScriptSha256, 1048576),
        (options.MaterializerPath, options.MaterializerSha256, 10485760), (current.PowerShellPath, current.PowerShellSha256, 10485760) })
      Require(IsHash(hash) && Hash(ReadFile(path, limit)) == hash);
    string Q(string value) => "'" + value.Replace("'", "''", StringComparison.Ordinal) + "'";
    var command = "$ErrorActionPreference='Stop'; try { & " + Q(options.ScriptPath) +
        " -ConfigurationPath " + Q(current.ConfigurationPath) + " -ExpectedConfigurationSha256 " + Q(current.ConfigurationSha256) +
        " -SourcePackPath " + Q(options.SourcePackPath) + " -LocaleSourcePath " + Q(options.LocaleSourcePath) +
        " -CatalogMaterializerPath " + Q(options.MaterializerPath) + " -OutputRoot " + Q(output) +
        " *> $null; exit 0 } catch { $code=$_.Exception.Message; if($code -cnotmatch '^boss_catalog_sync_[a-z_]+$')" +
        "{$code='boss_catalog_sync_failed'}; [IO.File]::WriteAllText(" + Q(Path.Combine(output, "failure-code.txt")) + ",$code); exit 1 }";
    using var owner = ExecutionJob.Create("Local\\NLL.BossSeasonSync." + Guid.NewGuid().ToString("N"));
    using var child = owner.Start(current.PowerShellPath, "-NoProfile -NonInteractive -EncodedCommand " +
        Convert.ToBase64String(Encoding.Unicode.GetBytes(command)));
    using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
    timeout.CancelAfter(TimeSpan.FromMinutes(5));
    try
    {
      await child.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
      if (child.ExitCode != 0) throw new BossPipelineException(PowerShellBossPipelineRunner.ReadFailureCode(output));
      return JsonSerializer.Deserialize<BossSeasonSyncCandidate>(ReadFile(Path.Combine(output, "sync-result.json"), 8192), JsonOptions)
          ?? throw new JsonException("boss_catalog_sync_failed");
    }
    catch (OperationCanceledException) when (!token.IsCancellationRequested)
    { throw new BossPipelineException("boss_catalog_sync_timeout"); }
    finally { owner.TerminateAndWait(15000); }
  }
}
