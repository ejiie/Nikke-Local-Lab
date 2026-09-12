using System.Diagnostics;
using System.Security.Cryptography;
using System.Text.Json;
using NikkeLocalLab.Persistence.PostgreSql;

namespace NikkeLocalLab.PostgreSql.IntegrationTests;

internal static class RuntimePersistenceAdapterProbe
{
  // The source-free CI suite needs no external server assembly. The explicit
  // Windows adapter gate requires a pinned freshly built executable and receipt.
  internal static async Task RunIfRequestedAsync(ClassicSoloRaidRuntimeStateKey key)
  {
    var path = Environment.GetEnvironmentVariable("NLL_TEST_RUNTIME_MATERIALIZER");
    if (string.IsNullOrEmpty(path)) return;
    var expectedHash = Environment.GetEnvironmentVariable("NLL_TEST_RUNTIME_MATERIALIZER_SHA256");
    Assert.True(Path.IsPathFullyQualified(path) && File.Exists(path));
    Assert.Equal(expectedHash, Convert.ToHexString(SHA256.HashData(await File.ReadAllBytesAsync(path))).ToLowerInvariant());
    var start = new ProcessStartInfo(path)
    {
      UseShellExecute = false,
      CreateNoWindow = true,
      RedirectStandardOutput = true,
      RedirectStandardError = true,
    };
    foreach (var argument in new[]
    {
      "--verify-runtime-persistence-integration", "true", "--account-uid", key.LocalAccountUid.ToString("D"),
      "--account-revision-set-sha256", new string('a',64), "--season-number", "26",
      "--raid-snapshot-uid", key.RaidSnapshotUid.ToString("D"), "--raid-snapshot-sha256", Convert.ToHexString(key.RaidSnapshotSha256).ToLowerInvariant(),
      "--client-build-code", key.ClientBuildCode, "--client-executable-sha256", Convert.ToHexString(key.ClientExecutableSha256).ToLowerInvariant(),
    }) start.ArgumentList.Add(argument);
    using var process = Process.Start(start)!;
    var outputTask = process.StandardOutput.ReadToEndAsync();
    var errorTask = process.StandardError.ReadToEndAsync();
    using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(60));
    try { await process.WaitForExitAsync(deadline.Token); }
    catch (OperationCanceledException)
    {
      process.Kill(entireProcessTree: false);
      await process.WaitForExitAsync();
      throw new InvalidOperationException("synthetic_materializer_deadline_exceeded");
    }
    var output = await outputTask;
    Assert.True(process.ExitCode == 0, await errorTask);
    using var parsed = JsonDocument.Parse(output);
    Assert.Equal("passed", parsed.RootElement.GetProperty("status").GetString());
    Assert.True(parsed.RootElement.GetProperty("actualCapturePersistRestore").GetBoolean());
    Assert.False(parsed.RootElement.GetProperty("operatingDatabaseTouched").GetBoolean());
    var receiptPath = Environment.GetEnvironmentVariable("NLL_TEST_RUNTIME_PERSISTENCE_RECEIPT")!;
    Assert.True(Path.IsPathFullyQualified(receiptPath));
    await File.WriteAllTextAsync(receiptPath, output);
  }
}
