using NikkeLocalLab.Automation;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Automation.UnitTests;

public sealed class FileInventoryVerifierTests
{
  [Theory]
  [InlineData(false)]
  [InlineData(true)]
  public async Task MatchingBytesOutsideInventoryViaLinkAreRejected(bool rootIsLink)
  {
    using var directory = new TemporaryDirectory();
    using var outside = new TemporaryDirectory();
    var outsideFile = Path.Combine(outside.Path, rootIsLink ? "runtime/server.dll" : "server.dll");
    Directory.CreateDirectory(Path.GetDirectoryName(outsideFile)!);
    await File.WriteAllTextAsync(outsideFile, "server");
    var link = Path.Combine(directory.Path, rootIsLink ? "linked-root" : "runtime");
    if (OperatingSystem.IsWindows())
    {
      using var process = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("cmd.exe")
      {
        Arguments = $"/c mklink /J \"{link}\" \"{outside.Path}\"",
        UseShellExecute = false,
        CreateNoWindow = true,
        RedirectStandardOutput = true,
        RedirectStandardError = true
      })!;
      var stdout = process.StandardOutput.ReadToEndAsync();
      var stderr = process.StandardError.ReadToEndAsync();
      await process.WaitForExitAsync();
      await Task.WhenAll(stdout, stderr);
      Assert.Equal(0, process.ExitCode);
    }
    else Directory.CreateSymbolicLink(link, outside.Path);
    try
    {
      var error = await Assert.ThrowsAsync<PipelineManifestException>(() =>
          FileInventoryVerifier.ObserveAsync(Manifest(6, Sha256Digest.ComputeUtf8("server")), rootIsLink ? link : directory.Path));
      Assert.Equal("pipeline_input_reparse_rejected", error.FailureCode);
      Assert.Equal("server", await File.ReadAllTextAsync(outsideFile));
    }
    finally { Directory.Delete(link); }
  }

  [Fact]
  public async Task ExactFileMatchesManifest()
  {
    using var directory = new TemporaryDirectory();
    var path = Path.Combine(directory.Path, "runtime", "server.dll");
    Directory.CreateDirectory(Path.GetDirectoryName(path)!);
    await File.WriteAllTextAsync(path, "server");
    var bytes = await File.ReadAllBytesAsync(path);
    var manifest = Manifest(bytes.LongLength, Sha256Digest.Compute(bytes));

    var result = await FileInventoryVerifier.ObserveAsync(manifest, directory.Path);

    Assert.True(result.AllMatched);
    var observation = Assert.Single(result.Observations);
    Assert.Equal(ArtifactMatchStatus.Matched, observation.Status);
  }

  [Fact]
  public async Task SameLengthContentChangeIsDigestDrift()
  {
    using var directory = new TemporaryDirectory();
    var path = Path.Combine(directory.Path, "runtime", "server.dll");
    Directory.CreateDirectory(Path.GetDirectoryName(path)!);
    await File.WriteAllTextAsync(path, "server");
    var manifest = Manifest(6, Sha256Digest.ComputeUtf8("change"));

    var result = await FileInventoryVerifier.ObserveAsync(manifest, directory.Path);

    Assert.False(result.AllMatched);
    Assert.Equal(ArtifactMatchStatus.DigestMismatch, Assert.Single(result.Observations).Status);
  }

  private static PipelineRunManifest Manifest(long length, Sha256Digest digest) => new(
      PipelineManifestTests.Uid(30),
      PipelineManifestTests.Target(),
      [new PipelineArtifactSpec("server_dll", "runtime/server.dll", length, digest)],
      [
        PipelineManifestTests.Step("inventory", PipelineStepKind.Inventory, false),
        PipelineManifestTests.Step("validate", PipelineStepKind.Validate, false, ["inventory"]),
        PipelineManifestTests.Step(
            "stage",
            PipelineStepKind.Stage,
            true,
            ["validate"],
            actions: [new PipelineAction("install_candidate", "runtime_overlay")],
            rollback: [new PipelineAction("remove_candidate", "runtime_overlay")])
      ]);

  private sealed class TemporaryDirectory : IDisposable
  {
    public TemporaryDirectory()
    {
      Path = System.IO.Path.Combine(
          System.IO.Path.GetTempPath(),
          "NikkeLocalLab.Automation.Tests",
          Guid.NewGuid().ToString("N"));
      Directory.CreateDirectory(Path);
    }

    public string Path { get; }

    public void Dispose()
    {
      if (Directory.Exists(Path))
      {
        Directory.Delete(Path, true);
      }
    }
  }
}
