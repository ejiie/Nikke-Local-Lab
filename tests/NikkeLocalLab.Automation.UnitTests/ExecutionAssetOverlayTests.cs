using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using NikkeLocalLab.AssetDelivery;

namespace NikkeLocalLab.Automation.UnitTests;

public sealed class ExecutionAssetOverlayTests : IDisposable
{
  private readonly string root = Path.Combine(Path.GetTempPath(), "nll-delivery-" + Guid.NewGuid().ToString("N"));
  private readonly byte[] original = "synthetic-original-bundle"u8.ToArray();
  private readonly byte[] derived = "synthetic-derived-bundle"u8.ToArray();
  private readonly ExecutionAssetBinding binding = new(new string('a', 32), new string('b', 64), new string('c', 64), "water");
  private string sha = "";
  private const string Route = "/PC/synthetic/fx.bundle";

  public ExecutionAssetOverlayTests()
  {
    Directory.CreateDirectory(root);
    File.WriteAllBytes(Path.Combine(root, "original.bundle"), original);
    File.WriteAllBytes(Path.Combine(root, "overlay.bundle"), derived);
    Seal();
  }

  private void Seal(string route = Route, string weakness = "water", string target = "fire", long? size = null)
  {
    var raw = JsonSerializer.SerializeToUtf8Bytes(new
    {
      schemaVersion = 1,
      contractId = "nll/execution-fx-delivery/v1",
      executionCode = binding.ExecutionCode,
      candidateSealSha256 = binding.CandidateSealSha256,
      profileSha256 = binding.ProfileSha256,
      weaknessCode = weakness,
      bossElementCode = target,
      requestPath = route,
      original = new { sha256 = Hash(original), byteLength = original.Length },
      overlay = new { sha256 = Hash(derived), byteLength = size ?? derived.Length },
      runtimeAdmissionStatusCode = "not_assessed"
    });
    File.WriteAllBytes(Path.Combine(root, "manifest.private.json"), raw);
    sha = Hash(raw);
  }

  private static string Hash(byte[] raw) => Convert.ToHexString(SHA256.HashData(raw)).ToLowerInvariant();
  private ExecutionAssetOverlay Open() => ExecutionAssetOverlay.Open(root, sha, binding, false);
  private void Retire() => ExecutionAssetOverlay.Retire(root, sha, binding);

  [Fact]
  public void ExactRouteUsesOwnedVerifiedBytesAndIndependentResponseCopies()
  {
    using var overlay = Open();
    var first = overlay.GetResponse(Route)!;
    Assert.Equal(derived, first);
    first[0] = 0;
    File.WriteAllText(Path.Combine(root, "overlay.bundle"), "drift after immutable load");
    Assert.Equal(derived, overlay.GetResponse(Route));
    Assert.Null(overlay.GetResponse("/PC/synthetic/other.bundle"));
    Assert.Null(overlay.GetResponse("/PC/synthetic/FX.bundle"));
    Assert.Equal(original, File.ReadAllBytes(Path.Combine(root, "original.bundle")));
  }

  [Theory]
  [InlineData("/PC/synthetic/fx.bundle?version=2")]
  [InlineData("/PC/synthetic/%66x.bundle")]
  [InlineData("/PC/synthetic/../fx.bundle")]
  [InlineData("/PC//synthetic/fx.bundle")]
  [InlineData("https://example.invalid/PC/synthetic/fx.bundle")]
  [InlineData("/pc/synthetic/fx.bundle")]
  [InlineData("/PC/synthetic\\fx.bundle")]
  [InlineData("/PC/synthetic/fx.bundle#fragment")]
  public void AmbiguousRequestsAndManifestRoutesAreRejected(string route)
  {
    using (var overlay = Open())
      Assert.Throws<InvalidDataException>(() => overlay.GetResponse(route));
    Seal(route);
    Assert.Throws<InvalidDataException>(Open);
  }

  [Fact]
  public void AllExecutionBindingsAndOfficialOutboundAreRequired()
  {
    foreach (var wrong in new[]
    {
            binding with { ExecutionCode = new string('d', 32) },
            binding with { CandidateSealSha256 = new string('d', 64) },
            binding with { ProfileSha256 = new string('d', 64) },
            binding with { WeaknessCode = "fire" }
        })
      Assert.Throws<InvalidDataException>(() => ExecutionAssetOverlay.Open(root, sha, wrong, false));
    Assert.Throws<InvalidDataException>(() => ExecutionAssetOverlay.Open(root, sha, binding, true));
    Assert.Throws<InvalidDataException>(() => ExecutionAssetOverlay.Open(root, new string('e', 64), binding, false));
    Seal(target: "wind");
    Assert.Throws<InvalidDataException>(Open);
    Seal(size: long.MaxValue);
    Assert.Throws<InvalidDataException>(Open);
    Assert.False(File.Exists(Path.Combine(root, ".lease")));
  }

  [Theory]
  [InlineData("original.bundle")]
  [InlineData("overlay.bundle")]
  [InlineData("manifest.private.json")]
  public void AnyDriftPreventsOpenAndCleanupWithoutPartialDeletion(string leaf)
  {
    File.WriteAllText(Path.Combine(root, leaf), "synthetic drift");
    Assert.Throws<InvalidDataException>(Open);
    Assert.Throws<InvalidDataException>(Retire);
    Assert.True(File.Exists(Path.Combine(root, "original.bundle")));
    Assert.True(File.Exists(Path.Combine(root, "overlay.bundle")));
    Assert.False(File.Exists(Path.Combine(root, ".retiring")));
  }

  [Fact]
  public void ActiveAndUncleanLeasesBlockSecondOwnerAndRetirement()
  {
    using (var overlay = Open())
    {
      Assert.Throws<InvalidDataException>(Open);
      Assert.Throws<InvalidDataException>(Retire);
      Assert.Equal(derived, overlay.GetResponse(Route));
    }
    File.WriteAllBytes(Path.Combine(root, ".lease"), []);
    Assert.Throws<InvalidDataException>(Open);
    Assert.Throws<InvalidDataException>(Retire);
    Assert.True(File.Exists(Path.Combine(root, ".lease")));
  }

  [Fact]
  public void RetireIsIdempotentAndNeverRevivesAClosedRoute()
  {
    var overlay = Open();
    var inFlight = overlay.GetResponse(Route);
    overlay.Dispose();
    overlay.Dispose();
    Retire();
    Retire();
    Assert.Equal(derived, inFlight);
    Assert.Throws<InvalidDataException>(() => overlay.GetResponse(Route));
    Assert.Throws<InvalidDataException>(Open);
    Assert.False(File.Exists(Path.Combine(root, "original.bundle")));
    Assert.False(File.Exists(Path.Combine(root, "overlay.bundle")));
    Assert.True(File.Exists(Path.Combine(root, "manifest.private.json")));
    Assert.True(File.Exists(Path.Combine(root, "retired.json")));
  }

  [Fact]
  public void InterruptedRetirementResumesOnlyKnownRemainingFiles()
  {
    File.WriteAllText(Path.Combine(root, ".retiring"), sha, new UTF8Encoding(false));
    File.Delete(Path.Combine(root, "original.bundle"));
    Assert.Throws<InvalidDataException>(Open);
    File.WriteAllText(Path.Combine(root, "foreign.txt"), "retain me");
    Assert.Throws<InvalidDataException>(Retire);
    Assert.True(File.Exists(Path.Combine(root, "overlay.bundle")));
    File.Delete(Path.Combine(root, "foreign.txt"));
    Retire();
    Retire();
  }

  [Fact]
  public void MissingFileWithoutIntentAndForeignDirectoriesFailClosed()
  {
    Directory.CreateDirectory(Path.Combine(root, "foreign"));
    Assert.Throws<InvalidDataException>(Open);
    Assert.Throws<InvalidDataException>(Retire);
    Directory.Delete(Path.Combine(root, "foreign"));
    File.Delete(Path.Combine(root, "original.bundle"));
    Assert.Throws<InvalidDataException>(Retire);
    Assert.True(File.Exists(Path.Combine(root, "overlay.bundle")));
  }

  [Fact]
  public void ReparseAncestorCannotRedirectOpenOrRetirement()
  {
    var link = root + "-alias";
    try
    {
      if (OperatingSystem.IsWindows())
      {
        using var process = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
        {
          FileName = "cmd.exe",
          Arguments = $"/d /c mklink /J \"{link}\" \"{root}\"",
          UseShellExecute = false,
          CreateNoWindow = true,
          RedirectStandardOutput = true,
          RedirectStandardError = true
        })!;
        Assert.True(process.WaitForExit(10000));
        Assert.Equal(0, process.ExitCode);
      }
      else
        Directory.CreateSymbolicLink(link, root);
      Assert.Throws<InvalidDataException>(() => ExecutionAssetOverlay.Open(link, sha, binding, false));
      Assert.Throws<InvalidDataException>(() => ExecutionAssetOverlay.Retire(link, sha, binding));
      Assert.False(File.Exists(Path.Combine(root, ".lease")));
      Assert.Equal(original, File.ReadAllBytes(Path.Combine(root, "original.bundle")));
    }
    finally
    {
      if (Directory.Exists(link))
        Directory.Delete(link); // Exact test-created link only; never traverse the target.
    }
  }

  [Fact]
  public async Task RealLoopbackHttpServesExactBytesRangesHeadAndControlledFailures()
  {
    using var overlay = Open();
    var bridge = new ExecutionAssetOverlayHttp(overlay);
    var builder = WebApplication.CreateBuilder();
    builder.Logging.ClearProviders();
    builder.WebHost.ConfigureKestrel(options => options.Listen(IPAddress.Loopback, 0));
    await using var app = builder.Build();
    app.Run(async context =>
    {
      if (!await bridge.TryHandleAsync(context))
        context.Response.StatusCode = 404;
    });
    await app.StartAsync();
    try
    {
      var addresses = app.Services.GetRequiredService<IServer>().Features.Get<IServerAddressesFeature>()!;
      using var client = new HttpClient(new HttpClientHandler { UseProxy = false })
      {
        BaseAddress = new Uri(addresses.Addresses.Single()),
        Timeout = TimeSpan.FromSeconds(10)
      };
      using var full = await client.GetAsync(Route);
      Assert.Equal(HttpStatusCode.OK, full.StatusCode);
      Assert.Equal(derived, await full.Content.ReadAsByteArrayAsync());
      Assert.True(full.Headers.CacheControl!.NoStore);
      using var range = new HttpRequestMessage(HttpMethod.Get, Route);
      range.Headers.Range = new RangeHeaderValue(2, 6);
      using var partial = await client.SendAsync(range);
      Assert.Equal(HttpStatusCode.PartialContent, partial.StatusCode);
      Assert.Equal(derived[2..7], await partial.Content.ReadAsByteArrayAsync());
      using var head = await client.SendAsync(new HttpRequestMessage(HttpMethod.Head, Route));
      Assert.Equal(derived.Length, head.Content.Headers.ContentLength);
      Assert.Empty(await head.Content.ReadAsByteArrayAsync());
      using var invalid = await client.GetAsync(Route + "?x=1");
      Assert.Equal(HttpStatusCode.Conflict, invalid.StatusCode);
      using var missing = await client.GetAsync("/PC/synthetic/other.bundle");
      Assert.Equal(HttpStatusCode.NotFound, missing.StatusCode);
      using var post = await client.PostAsync(Route, null);
      Assert.Equal(HttpStatusCode.MethodNotAllowed, post.StatusCode);
      overlay.Dispose();
      using var closed = await client.GetAsync(Route);
      Assert.Equal(HttpStatusCode.Conflict, closed.StatusCode);
    }
    finally
    {
      await app.StopAsync();
    }
  }

  public void Dispose() => Directory.Delete(root, recursive: true); // Only this test's synthetic temp tree.
}
