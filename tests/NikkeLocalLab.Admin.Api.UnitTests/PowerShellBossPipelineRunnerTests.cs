using System.Security.Cryptography;
using System.Text;

namespace NikkeLocalLab.Admin.Api.UnitTests;

public sealed class PowerShellBossPipelineRunnerTests : IDisposable
{
  private readonly string root = Path.Combine(Path.GetTempPath(), "nll-boss-runner-test-'" + Guid.NewGuid().ToString("N"));
  private string Worker => Path.Combine(root, "synthetic-worker.ps1");
  private string Config => Path.Combine(root, "config.json");
  private string Output => Path.Combine(root, "output");
  private const string SyntheticWorker = """
      param([string]$ConfigurationPath,[string]$ExpectedConfigurationSha256,[string]$JobRoot)
      $ErrorActionPreference='Stop'
      try {
      $r=Get-Content -LiteralPath (Join-Path $JobRoot 'request.json') -Raw | ConvertFrom-Json
      $candidate=Join-Path $JobRoot 'candidate'
      New-Item -ItemType Directory -Path $candidate | Out-Null
      $c=@{contractId='nll/boss-onboarding-verified-candidate/v1';seasonNumber=$r.seasonNumber;
      affinityVariantCount=5;fiveAffinityVariantStatusCode='passed';runtimeAdmissionStatusCode='not_assessed';clientStarted=$false;profileSha256=('c'*64)}
      $seal=Join-Path $candidate 'onboarding-verified-candidate.receipt.json'
      [IO.File]::WriteAllText($seal,($c|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
      $sha=[Security.Cryptography.SHA256]::Create()
      try {$sealHash=[BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($seal))).Replace('-','').ToLowerInvariant()} finally {$sha.Dispose()}
      $result=@{schemaVersion=1;contractId='nll/boss-pipeline-result/v1';jobUid=$r.jobUid;seasonNumber=$r.seasonNumber;
      catalogSha256=$r.catalogSha256;nativeClientExecuted=$false;statusCode='awaiting_runtime_delivery';
      admissionReceiptSha256=$null;candidateReceiptSha256=$sealHash}
      [IO.File]::WriteAllText((Join-Path $JobRoot 'pipeline-result.json'),($result|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
      } catch {
      [IO.File]::WriteAllText((Join-Path $JobRoot 'failure.synthetic.json'),(@{type=$_.Exception.GetType().Name;line=$_.InvocationInfo.ScriptLineNumber;code=$_.FullyQualifiedErrorId}|ConvertTo-Json))
      throw
      }
      """;
  private static string Hash(string path) => Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path))).ToLowerInvariant();
  private BossOnboardingJob Job() => new(1, "nll/boss-onboarding-job/v1", Guid.NewGuid(), Guid.NewGuid(), 1, new string('a', 64),
      "running", null, DateTimeOffset.UtcNow, DateTimeOffset.UtcNow);
  private BossPipelineOptions Prepare(string script = SyntheticWorker, int timeout = 15)
  {
    Directory.CreateDirectory(root);
    File.WriteAllText(Worker, script, new UTF8Encoding(false));
    File.WriteAllText(Config, "{\"synthetic\":true}");
    var shell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
    return new(shell, Hash(shell), Worker, Hash(Worker), Config, Hash(Config), timeout);
  }
  [Fact]
  public async Task WindowsWorkerUsesExactPinsQuotedPathsAndRetiresItsOwnedJob()
  {
    if (!OperatingSystem.IsWindows()) return;
    var runner = new PowerShellBossPipelineRunner(Prepare());
    var job = Job();
    BossPipelineResult result;
    try { result = await runner.RunAsync(job, Output, CancellationToken.None); }
    catch
    {
      var diagnostic = Path.Combine(Output, "failure.synthetic.json");
      if (File.Exists(diagnostic)) Assert.Fail(File.ReadAllText(diagnostic));
      throw;
    }
    Assert.Equal("awaiting_runtime_delivery", result.StatusCode);
    Assert.Null(result.AdmissionReceiptSha256);
    Assert.True(await runner.RecoverAsync(job, CancellationToken.None));
    await Assert.ThrowsAsync<InvalidOperationException>(() => runner.RunAsync(job, Output, CancellationToken.None));
  }
  [Fact]
  public async Task InputDriftIsRejectedBeforeAWorkerOrOutputExists()
  {
    if (!OperatingSystem.IsWindows()) return;
    var runner = new PowerShellBossPipelineRunner(Prepare());
    File.AppendAllText(Config, " ");
    var failure = await Assert.ThrowsAsync<InvalidOperationException>(() => runner.RunAsync(Job(), Output, CancellationToken.None));
    Assert.Equal("boss_pipeline_input_drifted", failure.Message);
    Assert.False(Directory.Exists(Output));
  }
  [Fact]
  public async Task TimeoutRetiresTheOwnedOfflineToolWithoutCallingAnyGameOrService()
  {
    if (!OperatingSystem.IsWindows()) return;
    var runner = new PowerShellBossPipelineRunner(Prepare("param($ConfigurationPath,$ExpectedConfigurationSha256,$JobRoot)\nStart-Sleep -Seconds 90", 1));
    var job = Job();
    await Assert.ThrowsAnyAsync<OperationCanceledException>(() => runner.RunAsync(job, Output, CancellationToken.None));
    Assert.True(await runner.RecoverAsync(job, CancellationToken.None));
    Assert.False(File.Exists(Path.Combine(Output, "pipeline-result.json")));
  }
  public void Dispose()
  {
    if (!Directory.Exists(root)) return;
    if (Path.GetDirectoryName(root) != Path.TrimEndingDirectorySeparator(Path.GetTempPath()) ||
        !Path.GetFileName(root).StartsWith("nll-boss-runner-test-", StringComparison.Ordinal) ||
        (File.GetAttributes(root) & FileAttributes.ReparsePoint) != 0) throw new InvalidOperationException("synthetic_cleanup_boundary_invalid");
    Directory.Delete(root, recursive: true);
  }
}
