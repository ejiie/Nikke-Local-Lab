using System.Security.Cryptography;
using System.Text.Json;
using NikkeLocalLab.Phase3B2.LocalBootstrap;

namespace NikkeLocalLab.Admin.Api.UnitTests;

public sealed class UserValidationPinMeasurementTests
{
  [Fact]
  public void DeepPinReadsAreMeasuredAndLeaseAllowsCacheWritesOnlyAfterRelease()
  {
    if (!OperatingSystem.IsWindows()) return;
    var root = Path.Combine(Path.GetTempPath(), "nll-pin-measurement-" + Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(root);
    try
    {
      var bytes = Enumerable.Range(0, 8192).Select(i => (byte)i).ToArray();
      var path = Path.Combine(root, "synthetic.bin"); File.WriteAllBytes(path, bytes);
      var hash = Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
      var measurement = new UserValidationPreflightMeasurement("bootstrap", new string('a', 64), bytes.Length);
      using (var lease = UserValidationPinnedFiles.Open(path, bytes.Length, hash, 16384, measurement.Observe))
      {
        Assert.Equal(bytes.Length, measurement.CompletedReadBytes);
        Assert.Throws<IOException>(() => { using var writer = File.OpenWrite(path); });
        Assert.Throws<IOException>(() => File.Move(path, path + ".moved"));
      }
      var timestamp = File.GetLastWriteTimeUtc(path);
      bytes[100] ^= 1; File.WriteAllBytes(path, bytes); File.SetLastWriteTimeUtc(path, timestamp);
      Assert.Throws<InvalidOperationException>(() => UserValidationPinnedFiles.Open(path, bytes.Length, hash, 16384, measurement.Observe));
      Assert.Equal(bytes.Length * 2, measurement.CompletedReadBytes);
      measurement.Save(root, passed: false);
      using var receipt = JsonDocument.Parse(File.ReadAllBytes(Directory.GetFiles(root, "*.json").Single()));
      Assert.Equal("failed", receipt.RootElement.GetProperty("statusCode").GetString());
      Assert.Equal(bytes.Length * 2, receipt.RootElement.GetProperty("completedReadBytes").GetInt64());
      Assert.False(receipt.RootElement.GetProperty("actualGameAcceptanceClaimed").GetBoolean());
    }
    finally
    {
      Assert.StartsWith(Path.GetFullPath(Path.GetTempPath()) + "nll-pin-measurement-", Path.GetFullPath(root), StringComparison.Ordinal);
      Directory.Delete(root, recursive: true);
    }
  }
}
