using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace NikkeLocalLab.Admin.Api.UnitTests;

public sealed class BossPipelineResultTests : IDisposable
{
  private readonly string root = Path.Combine(Path.GetTempPath(), "nll-boss-result-test-" + Guid.NewGuid().ToString("N"));
  private readonly BossOnboardingJob job = new(1, "nll/boss-onboarding-job/v1", Guid.NewGuid(), Guid.NewGuid(), 1,
      new string('a', 64), "running", null, DateTimeOffset.UtcNow, DateTimeOffset.UtcNow);
  private JsonObject candidate = null!, result = null!;
  public BossPipelineResultTests()
  {
    Directory.CreateDirectory(Path.Combine(root, "candidate"));
    candidate = new()
    {
      ["contractId"] = "nll/boss-onboarding-verified-candidate/v1",
      ["seasonNumber"] = 1,
      ["affinityVariantCount"] = 5,
      ["fiveAffinityVariantStatusCode"] = "passed",
      ["runtimeAdmissionStatusCode"] = "not_assessed",
      ["clientStarted"] = false,
      ["profileSha256"] = new string('c', 64)
    };
    result = new()
    {
      ["schemaVersion"] = 1,
      ["contractId"] = "nll/boss-pipeline-result/v1",
      ["jobUid"] = job.JobUid,
      ["seasonNumber"] = 1,
      ["catalogSha256"] = job.CatalogSha256,
      ["statusCode"] = "awaiting_runtime_delivery",
      ["admissionReceiptSha256"] = null,
      ["nativeClientExecuted"] = false
    };
  }
  private void Save()
  {
    var bytes = JsonSerializer.SerializeToUtf8Bytes(candidate);
    File.WriteAllBytes(Path.Combine(root, "candidate", "onboarding-verified-candidate.receipt.json"), bytes);
    result["candidateReceiptSha256"] = Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
    File.WriteAllText(Path.Combine(root, "pipeline-result.json"), result.ToJsonString());
  }
  [Fact]
  public void VerifiedOfflineResultRemainsUnadmitted()
  {
    Save();
    var read = PowerShellBossPipelineRunner.ReadResult(root, job);
    Assert.Equal("awaiting_runtime_delivery", read.StatusCode);
    Assert.Equal("boss_runtime_delivery_required", read.FailureCode);
    Assert.Null(read.AdmissionReceiptSha256);
  }
  [Theory]
  [InlineData("candidate-season")]
  [InlineData("candidate-count")]
  [InlineData("candidate-runtime")]
  [InlineData("candidate-client")]
  [InlineData("result-season")]
  [InlineData("result-catalog")]
  [InlineData("result-client")]
  [InlineData("game-handoff-without-delivery")]
  [InlineData("missing-admission")]
  [InlineData("unexpected-admission")]
  [InlineData("missing-native-package")]
  [InlineData("candidate-drift")]
  public void MissingEvidenceAndCrossJobClaimsCannotBecomeCompletion(string change)
  {
    switch (change)
    {
      case "candidate-season": candidate["seasonNumber"] = 2; break;
      case "candidate-count": candidate["affinityVariantCount"] = 4; break;
      case "candidate-runtime": candidate["runtimeAdmissionStatusCode"] = "passed"; break;
      case "candidate-client": candidate["clientStarted"] = true; break;
      case "result-season": result["seasonNumber"] = 2; break;
      case "result-catalog": result["catalogSha256"] = new string('b', 64); break;
      case "result-client": result["nativeClientExecuted"] = true; break;
      case "game-handoff-without-delivery": result["statusCode"] = "awaiting_game_validation"; break;
      case "missing-admission": result["statusCode"] = "completed"; break;
      case "unexpected-admission": result["admissionReceiptSha256"] = new string('d', 64); break;
      case "missing-native-package": result["nativeChunkReceiptSha256"] = new string('d', 64); break;
    }
    Save();
    if (change == "candidate-drift") File.AppendAllText(Path.Combine(root, "candidate", "onboarding-verified-candidate.receipt.json"), " ");
    Assert.ThrowsAny<Exception>(() => PowerShellBossPipelineRunner.ReadResult(root, job));
  }
  public void Dispose()
  {
    if (Path.GetDirectoryName(root) != Path.TrimEndingDirectorySeparator(Path.GetTempPath()) ||
        !Path.GetFileName(root).StartsWith("nll-boss-result-test-", StringComparison.Ordinal) ||
        (File.GetAttributes(root) & FileAttributes.ReparsePoint) != 0) throw new InvalidOperationException("synthetic_cleanup_boundary_invalid");
    Directory.Delete(root, recursive: true);
  }
}
