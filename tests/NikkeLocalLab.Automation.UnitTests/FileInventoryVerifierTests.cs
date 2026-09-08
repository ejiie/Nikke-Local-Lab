using NikkeLocalLab.Automation;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Automation.UnitTests;

public sealed class FileInventoryVerifierTests
{
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
