using System.Security.Cryptography;
using System.Text.Json;
using NikkeLocalLab.Admin.Api;

// Explicit opt-in local integration, no web host, PostgreSQL, game or UAC.
var inspect = args.Length == 4 && args[2] == "--inspect-job";
if ((args.Length != 3 && !inspect) || !OperatingSystem.IsWindows()) throw new ArgumentException("boss_check_arguments_invalid");
var configPath = Path.GetFullPath(args[0]);
var bytes = File.ReadAllBytes(configPath);
var configHash = Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
if (configHash != args[1]) throw new InvalidOperationException("boss_check_configuration_drifted");
using var document = JsonDocument.Parse(bytes);
var config = document.RootElement;
string Text(string name) => config.GetProperty(name).GetString() ?? throw new JsonException();
if (config.GetProperty("allowLegacyPublication").GetBoolean()) throw new InvalidOperationException("boss_check_publication_forbidden");
var catalog = new FilesystemBossSeasonCatalogService(Text("catalogPath"), Text("catalogSha256"), Text("registryRoot"));
var runner = new PowerShellBossPipelineRunner(new(Text("powerShellPath"), Text("powerShellSha256"),
    Path.Combine(Text("repositoryRoot"), "scripts", "invoke-nll-boss-onboarding-job.ps1"), Text("workerSha256"),
    configPath, configHash, config.GetProperty("timeoutSeconds").GetInt32()));
var service = new FilesystemBossOnboardingService(Text("jobsRoot"), catalog, runner);
if (inspect)
{
  var existing = service.Get(Guid.ParseExact(args[3], "D")) ?? throw new InvalidOperationException("boss_check_job_missing");
  var verified = PowerShellBossPipelineRunner.ReadResult(Path.Combine(Text("jobsRoot"), existing.JobUid.ToString("D"), "output"), existing);
  if (verified.CandidateReceiptSha256 != existing.CandidateReceiptSha256 || verified.StatusCode != existing.StatusCode ||
      !await runner.RecoverAsync(existing, CancellationToken.None)) throw new InvalidOperationException("boss_check_existing_result_invalid");
  Console.WriteLine(JsonSerializer.Serialize(new
  {
    contractId = "nll/boss-pipeline-local-inspection/v1",
    existing.JobUid,
    existing.StatusCode,
    receiptChainVerified = true,
    workerStarted = false,
    originalClientExecuted = false
  }));
  return 0;
}
var request = new BossOnboardingRequest(Guid.NewGuid(), int.Parse(args[2], System.Globalization.CultureInfo.InvariantCulture), Text("catalogSha256"));
var beforeRegistry = File.ReadAllBytes(Path.Combine(Text("registryRoot"), "registry.json"));
var accepted = await service.StartAsync(request, CancellationToken.None);
Console.WriteLine(JsonSerializer.Serialize(new { statusCode = "queued", jobUid = accepted.JobUid, seasonNumber = request.SeasonNumber }));
if (!await service.RunNextAsync(CancellationToken.None)) throw new InvalidOperationException("boss_check_worker_unavailable");
var terminal = service.Get(accepted.JobUid)!;
var restarted = new FilesystemBossOnboardingService(Text("jobsRoot"), catalog, runner);
var replay = await restarted.StartAsync(request, CancellationToken.None);
if (replay != terminal || !await runner.RecoverAsync(terminal, CancellationToken.None) ||
    !beforeRegistry.AsSpan().SequenceEqual(File.ReadAllBytes(Path.Combine(Text("registryRoot"), "registry.json"))))
  throw new InvalidOperationException("boss_check_recovery_invalid");
Console.WriteLine(JsonSerializer.Serialize(new
{
  contractId = "nll/boss-pipeline-local-check/v1",
  terminal.JobUid,
  terminal.SeasonNumber,
  terminal.StatusCode,
  terminal.FailureCode,
  terminal.CandidateReceiptSha256,
  replayAfterRestartVerified = true,
  ownedToolsRetired = true,
  registryModified = false,
  originalClientExecuted = false,
  operatingDatabaseTouched = false,
  deployed = false
}));
return terminal.StatusCode == "awaiting_runtime_delivery" && terminal.CandidateReceiptSha256 is not null ? 0 : 1;
