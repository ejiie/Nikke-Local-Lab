using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using ResourceCatalogPreflight;
using Xunit;

namespace ResourceCatalogPreflight.Tests;

public sealed class ResourceRouteProbePlanTests
{
  [Fact]
  public void PinnedPlanIsReadOnlyAndNoRuntimeOrLogIsCreated()
  {
    using var fixture = new Fixture();
    var plan = ResourceRouteProbeHost.ReadPlan(fixture.Path, fixture.Digest, fixture.Root);
    Assert.Equal("fixture.example", plan.ExpectedHost);
    Assert.Equal(120, plan.DurationSeconds);
    Assert.Single(Directory.GetFiles(fixture.Directory));
    Assert.Throws<PreflightException>(() => ResourceRouteProbeHost.ReadPlan(fixture.Path, new string('0', 64), fixture.Root));
    Assert.Throws<PreflightException>(() => ResourceRouteProbeHost.ReadPlan(fixture.Path, fixture.Digest));
  }

  [Theory]
  [InlineData("contractId", "other")]
  [InlineData("assessmentUid", "00000000-0000-0000-0000-000000000000")]
  [InlineData("expectedHost", "")]
  [InlineData("metadataFile", "C:\\NIKKE\\not-allowed")]
  [InlineData("certificateFile", "C:\\NLL\\Runtime\\not-allowed")]
  public void PlanRejectsUnboundIdentityAndPaths(string key, string value)
  {
    using var fixture = new Fixture();
    fixture.Rewrite(node => node[key] = value);
    Assert.Throws<PreflightException>(() => ResourceRouteProbeHost.ReadPlan(fixture.Path, fixture.Digest, fixture.Root));
  }

  [Theory]
  [InlineData("durationSeconds", 0)]
  [InlineData("durationSeconds", 301)]
  [InlineData("maximumRequests", 0)]
  [InlineData("maximumRequests", 65)]
  [InlineData("metadataByteLength", 0)]
  [InlineData("certificateByteLength", 65537)]
  public void PlanRejectsUnboundedLimits(string key, int value)
  {
    using var fixture = new Fixture();
    fixture.Rewrite(node => node[key] = value);
    Assert.Throws<PreflightException>(() => ResourceRouteProbeHost.ReadPlan(fixture.Path, fixture.Digest, fixture.Root));
  }

  [Fact]
  public void PlanRejectsUnknownFieldsRatherThanAcceptingAnOutboundOption()
  {
    using var fixture = new Fixture();
    fixture.Rewrite(node => node["outboundFallback"] = true);
    Assert.Throws<JsonException>(() => ResourceRouteProbeHost.ReadPlan(fixture.Path, fixture.Digest, fixture.Root));
  }

  private sealed class Fixture : IDisposable
  {
    internal string Root { get; } = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "nll-probe-plan-fixture-" + Guid.NewGuid().ToString("D"));
    internal string Directory { get; }
    internal string Path { get; }
    internal string Digest => Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(Path))).ToLowerInvariant();
    internal Fixture()
    {
      var uid = Guid.NewGuid().ToString("D");
      Directory = System.IO.Path.Combine(Root, uid);
      System.IO.Directory.CreateDirectory(Directory);
      Path = System.IO.Path.Combine(Directory, "probe.private.json");
      var plan = new ResourceRouteProbeHost.Plan("nll/resource-route-probe-plan/v1", uid,
          "fixture.example", "/fixture/pck/latest-123.txt", System.IO.Path.Combine(Directory, "version-metadata.txt"),
          100, new string('a', 64), System.IO.Path.Combine(Directory, "server.pfx"), 100, new string('b', 64), 120, 64);
      File.WriteAllText(Path, JsonSerializer.Serialize(plan, new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase }));
    }
    internal void Rewrite(Action<JsonNode> change)
    {
      var node = JsonNode.Parse(File.ReadAllBytes(Path))!;
      change(node);
      File.WriteAllText(Path, node.ToJsonString());
    }
    public void Dispose()
    {
      if (System.IO.Path.GetDirectoryName(Root) != System.IO.Path.TrimEndingDirectorySeparator(System.IO.Path.GetTempPath()) ||
          !System.IO.Path.GetFileName(Root).StartsWith("nll-probe-plan-fixture-", StringComparison.Ordinal) ||
          (File.GetAttributes(Root) & FileAttributes.ReparsePoint) != 0)
        throw new InvalidOperationException("synthetic_fixture_cleanup_boundary_invalid");
      System.IO.Directory.Delete(Root, recursive: true);
    }
  }
}
