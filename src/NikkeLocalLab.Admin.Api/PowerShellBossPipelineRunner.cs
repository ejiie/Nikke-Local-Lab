using System.ComponentModel;
using System.Text;
using System.Text.Json;
using Nll.PhaseD;

namespace NikkeLocalLab.Admin.Api;

public sealed record BossPipelineOptions(string PowerShellPath, string PowerShellSha256, string WorkerPath, string WorkerSha256,
    string ConfigurationPath, string ConfigurationSha256, int TimeoutSeconds = 1800);

public sealed class PowerShellBossPipelineRunner(BossPipelineOptions options) : IBossPipelineRunner
{
  private static string JobName(Guid uid) => "Local\\NLL.BossOnboarding." + uid.ToString("N");
  private static string Literal(string value) => "'" + value.Replace("'", "''", StringComparison.Ordinal) + "'";
  private static void Pin(string path, string hash, int maximum)
  {
    if (!FilesystemBossSeasonCatalogService.IsHash(hash) ||
        FilesystemBossSeasonCatalogService.Hash(FilesystemBossSeasonCatalogService.ReadFile(path, maximum)) != hash)
      throw new InvalidOperationException("boss_pipeline_input_drifted");
  }
  public async Task<BossPipelineResult> RunAsync(BossOnboardingJob job, string outputRoot, CancellationToken cancellationToken)
  {
    if (!OperatingSystem.IsWindows() || options.TimeoutSeconds is < 1 or > 7200)
      throw new InvalidOperationException("boss_pipeline_host_invalid");
    outputRoot = FilesystemBossSeasonCatalogService.Plain(outputRoot);
    if (Directory.Exists(outputRoot) || File.Exists(outputRoot)) throw new InvalidOperationException("boss_pipeline_output_exists");
    Pin(options.PowerShellPath, options.PowerShellSha256, 10485760);
    Pin(options.WorkerPath, options.WorkerSha256, 1048576);
    Pin(options.ConfigurationPath, options.ConfigurationSha256, 1048576);
    Directory.CreateDirectory(outputRoot);
    using (var request = new FileStream(Path.Combine(outputRoot, "request.json"), FileMode.CreateNew, FileAccess.Write, FileShare.None))
    {
      JsonSerializer.Serialize(request, job, FilesystemBossSeasonCatalogService.JsonOptions);
      request.Flush(true);
    }
    using var owner = ExecutionJob.Create(JobName(job.JobUid));
    var code = "$ErrorActionPreference='Stop'; try { & " + Literal(options.WorkerPath) +
        " -ConfigurationPath " + Literal(options.ConfigurationPath) + " -ExpectedConfigurationSha256 " + Literal(options.ConfigurationSha256) +
        " -JobRoot " + Literal(outputRoot) + " *> $null; exit 0 } catch { " +
        "$failure=$_.Exception.Message; if($failure -cnotmatch '\\A(?:boss_|phase_d_)[a-z0-9_]{1,100}\\z'){$failure='boss_pipeline_worker_failed'}; " +
        "[IO.File]::WriteAllText(" + Literal(Path.Combine(outputRoot, "failure-code.txt")) + ", $failure); exit 1 }";
    // Creation-time assignment, KILL_ON_JOB_CLOSE, no breakaway. A crashing API
    // cannot leave the offline materializer/Python child tree unowned.
    using var child = owner.Start(options.PowerShellPath, "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand " +
        Convert.ToBase64String(Encoding.Unicode.GetBytes(code)));
    using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
    timeout.CancelAfter(TimeSpan.FromSeconds(options.TimeoutSeconds));
    try
    {
      await child.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
      if (child.ExitCode != 0) throw new InvalidOperationException("boss_pipeline_worker_failed");
      for (var attempt = 0; attempt < 20 && owner.ActiveProcesses != 0; attempt++)
        await Task.Delay(50, timeout.Token).ConfigureAwait(false);
      if (owner.ActiveProcesses != 0) throw new InvalidOperationException("boss_pipeline_children_running");
      Pin(options.WorkerPath, options.WorkerSha256, 1048576);
      Pin(options.ConfigurationPath, options.ConfigurationSha256, 1048576);
      return ReadResult(outputRoot, job);
    }
    finally { owner.TerminateAndWait(15000); }
  }
  public Task<bool> RecoverAsync(BossOnboardingJob job, CancellationToken cancellationToken)
  {
    if (!OperatingSystem.IsWindows()) return Task.FromResult(false);
    try
    {
      // Name is derived only from our source-free job UID, under a separate
      // namespace. Never enumerate/stop game, Epinel, ACE or PostgreSQL processes.
      using var owner = ExecutionJob.Open(JobName(job.JobUid));
      owner.TerminateAndWait(15000);
      return Task.FromResult(owner.ActiveProcesses == 0);
    }
    catch (Win32Exception error) when (error.NativeErrorCode == 2) { return Task.FromResult(true); }
    catch (Exception error) when (error is Win32Exception or InvalidOperationException) { return Task.FromResult(false); }
  }
  public static BossPipelineResult ReadResult(string outputRoot, BossOnboardingJob job)
  {
    using var result = JsonDocument.Parse(FilesystemBossSeasonCatalogService.ReadFile(Path.Combine(outputRoot, "pipeline-result.json"), 16384));
    var row = result.RootElement;
    void Require(bool condition) { if (!condition) throw new InvalidOperationException("boss_pipeline_result_invalid"); }
    Require(row.GetProperty("schemaVersion").GetInt32() == 1 && row.GetProperty("contractId").GetString() == "nll/boss-pipeline-result/v1" &&
        row.GetProperty("jobUid").GetGuid() == job.JobUid && row.GetProperty("seasonNumber").GetInt32() == job.SeasonNumber &&
        row.GetProperty("catalogSha256").GetString() == job.CatalogSha256 && !row.GetProperty("nativeClientExecuted").GetBoolean());
    var candidateBytes = FilesystemBossSeasonCatalogService.ReadFile(Path.Combine(outputRoot, "candidate", "onboarding-verified-candidate.receipt.json"), 1048576);
    var candidateHash = FilesystemBossSeasonCatalogService.Hash(candidateBytes);
    Require(candidateHash == row.GetProperty("candidateReceiptSha256").GetString());
    using var candidate = JsonDocument.Parse(candidateBytes);
    var c = candidate.RootElement;
    Require(c.GetProperty("contractId").GetString() == "nll/boss-onboarding-verified-candidate/v1" &&
        c.GetProperty("seasonNumber").GetInt32() == job.SeasonNumber && c.GetProperty("affinityVariantCount").GetInt32() == 5 &&
        c.GetProperty("fiveAffinityVariantStatusCode").GetString() == "passed" &&
        c.GetProperty("runtimeAdmissionStatusCode").GetString() == "not_assessed" && !c.GetProperty("clientStarted").GetBoolean());
    var status = row.GetProperty("statusCode").GetString();
    // A game-validation handoff needs a separate verified delivery contract.
    // This offline worker cannot manufacture that state from an FX candidate.
    Require(status is "completed" or "awaiting_runtime_delivery");
    if (row.TryGetProperty("nativeChunkReceiptSha256", out var nativePin) && nativePin.ValueKind != JsonValueKind.Null)
    {
      JsonDocument ReadPinned(string relative, string? expected)
      {
        var bytes = FilesystemBossSeasonCatalogService.ReadFile(Path.Combine(outputRoot, relative), 1048576);
        Require(FilesystemBossSeasonCatalogService.IsHash(expected) && FilesystemBossSeasonCatalogService.Hash(bytes) == expected);
        return JsonDocument.Parse(bytes);
      }
      Require(status == "awaiting_runtime_delivery");
      using var chunks = ReadPinned("native-chunks/receipt.json", nativePin.GetString());
      var ch = chunks.RootElement;
      Require(ch.GetProperty("contractId").GetString() == "nll/native-fx-chunk-candidate/v1" &&
          ch.GetProperty("statusCode").GetString() == "offline_chunk_candidate_verified" &&
          !ch.GetProperty("nativeClientExecuted").GetBoolean() && !ch.GetProperty("installedFilesModified").GetBoolean() &&
          !ch.GetProperty("oldChunkDigestsMatch").GetBoolean() && ch.GetProperty("sourceFilesUnchanged").GetBoolean() &&
          ch.GetProperty("runtimeAdmissionStatusCode").GetString() == "not_assessed");
      using var manifest = ReadPinned("native-chunks/manifest.private.json", ch.GetProperty("manifestSha256").GetString());
      Require(manifest.RootElement.GetProperty("contractId").GetString() == "nll/native-fx-chunk-candidate-private/v1");
      using var layout = ReadPinned("native-fixed-layout/receipt.json", ch.GetProperty("layoutSha256").GetString());
      Require(layout.RootElement.GetProperty("contractId").GetString() == "nll/native-fx-fixed-layout-candidate/v1");
      using var native = ReadPinned("native-candidate/receipt.json", layout.RootElement.GetProperty("sourceCandidateSha256").GetString());
      Require(native.RootElement.GetProperty("contractId").GetString() == "nll/native-fx-candidate-receipt/v1" &&
          native.RootElement.GetProperty("sourceCandidateManifestSha256").GetString() == c.GetProperty("shieldFxCandidateManifestSha256").GetString());
    }
    string? admissionHash = null;
    if (status == "completed")
    {
      var bytes = FilesystemBossSeasonCatalogService.ReadFile(Path.Combine(outputRoot, "candidate", "onboarding-admission.receipt.json"), 1048576);
      admissionHash = FilesystemBossSeasonCatalogService.Hash(bytes);
      Require(admissionHash == row.GetProperty("admissionReceiptSha256").GetString());
      using var admission = JsonDocument.Parse(bytes);
      var a = admission.RootElement;
      Require(a.GetProperty("contractId").GetString() == "nll/boss-onboarding-admission/v1" &&
          a.GetProperty("seasonNumber").GetInt32() == job.SeasonNumber && a.GetProperty("profileSha256").GetString() == c.GetProperty("profileSha256").GetString() &&
          a.GetProperty("operationalStatusCode").GetString() == "enabled" && a.GetProperty("fiveAffinityVariantStatusCode").GetString() == "passed");
    }
    else Require(row.GetProperty("admissionReceiptSha256").ValueKind == JsonValueKind.Null);
    return new(status!, status == "completed" ? null : "boss_runtime_delivery_required",
        candidateHash, admissionHash);
  }
}
