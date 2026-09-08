using System.Text.Json;
using ResourceCatalogPreflight;
using Xunit;

namespace ResourceCatalogPreflight.Tests;

public sealed class PrivateRouteProbeLogTests
{
  [Fact]
  public void PrivateContentHasOnlyABoundedSourceFreeSummaryAndCannotBeOverwritten()
  {
    using var fixture = new Fixture();
    var record = new ResourceRouteProbe.Observation("GET", "/fixture/private-member.pak", "closed",
        [new(1, 9)], ["If-Range"], 404);
    using (var log = new PrivateRouteProbeLog(fixture.Assessment, fixture.Root))
    {
      Assert.True(log.TryRecord(record));
      var summary = JsonSerializer.Serialize(log.Summary());
      Assert.DoesNotContain("private-member", summary);
      Assert.Contains("\"requestCount\":1", summary);
      Assert.Contains("\"nativeAdmission\":\"not_evaluated\"", summary);
    }
    var path = Path.Combine(fixture.Assessment, "requests.private.jsonl");
    var before = File.ReadAllBytes(path);
    Assert.Throws<IOException>(() => new PrivateRouteProbeLog(fixture.Assessment, fixture.Root));
    Assert.Equal(before, File.ReadAllBytes(path));
  }

  [Fact]
  public void WriterRejectsParentEscapeAndEnforcesByteAndCountBounds()
  {
    using var fixture = new Fixture();
    Assert.Throws<PreflightException>(() => new PrivateRouteProbeLog(fixture.Root, fixture.Root));
    Assert.Throws<PreflightException>(() => new PrivateRouteProbeLog(
        Path.Combine(fixture.Root, "not-an-assessment"), fixture.Root));
    using var log = new PrivateRouteProbeLog(fixture.Assessment, fixture.Root);
    var oversized = new ResourceRouteProbe.Observation("GET", "/" + new string('x', 9000), "absent", [], [], 404);
    Assert.False(log.TryRecord(oversized));
    var record = new ResourceRouteProbe.Observation("GET", "/fixture", "absent", [], [], 404);
    for (var index = 0; index < 256; index++) Assert.True(log.TryRecord(record));
    Assert.False(log.TryRecord(record));
    Assert.Contains("\"requestCount\":256", JsonSerializer.Serialize(log.Summary()));
  }

  private sealed class Fixture : IDisposable
  {
    internal string Root { get; } = Path.Combine(Path.GetTempPath(), "nll-probe-log-fixture-" + Guid.NewGuid().ToString("D"));
    internal string Assessment { get; }
    internal Fixture()
    {
      Assessment = Path.Combine(Root, Guid.NewGuid().ToString("D"));
      Directory.CreateDirectory(Assessment);
    }
    public void Dispose()
    {
      if (Path.GetDirectoryName(Root) != Path.TrimEndingDirectorySeparator(Path.GetTempPath()) ||
          !Path.GetFileName(Root).StartsWith("nll-probe-log-fixture-", StringComparison.Ordinal) ||
          (File.GetAttributes(Root) & FileAttributes.ReparsePoint) != 0)
        throw new InvalidOperationException("synthetic_fixture_cleanup_boundary_invalid");
      Directory.Delete(Root, recursive: true);
    }
  }
}
