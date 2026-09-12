using System.Net;
using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using NikkeLocalLab.AssetDelivery;

namespace NikkeLocalLab.Automation.UnitTests;

public sealed class ExecutionAssetOverlayStartupTests : IDisposable
{
  private readonly string runtime = Path.Combine(Path.GetTempPath(), "nll-fx-startup-" + Guid.NewGuid().ToString("N"));
  private readonly Dictionary<string, string?> environment;
  private const string Route = "/PC/synthetic/fx.bundle";
  private readonly byte[] derived = "synthetic derived"u8.ToArray();
  private string Root => Path.Combine(runtime, "execution-fx");

  public ExecutionAssetOverlayStartupTests()
  {
    Directory.CreateDirectory(Root);
    byte[] original = "synthetic original"u8.ToArray();
    File.WriteAllBytes(Path.Combine(Root, "original.bundle"), original);
    File.WriteAllBytes(Path.Combine(Root, "overlay.bundle"), derived);
    var bytes = JsonSerializer.SerializeToUtf8Bytes(new
    {
      schemaVersion = 1,
      contractId = "nll/execution-fx-delivery/v1",
      executionCode = new string('a', 32),
      candidateSealSha256 = new string('b', 64),
      profileSha256 = new string('c', 64),
      weaknessCode = "water",
      bossElementCode = "fire",
      requestPath = Route,
      original = new { sha256 = Hash(original), byteLength = original.Length },
      overlay = new { sha256 = Hash(derived), byteLength = derived.Length },
      runtimeAdmissionStatusCode = "not_assessed"
    });
    File.WriteAllBytes(Path.Combine(Root, "manifest.private.json"), bytes);
    string[] values = [Root, Hash(bytes), new string('a', 32), new string('b', 64), new string('c', 64), "water"];
    environment = ExecutionAssetOverlayStartup.EnvironmentNames.Zip(values).ToDictionary(pair => pair.First, pair => (string?)pair.Second);
  }

  private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
  private ExecutionAssetOverlayStartup? Open(bool local = true, bool headless = true, bool outbound = false) =>
      ExecutionAssetOverlayStartup.OpenFromEnvironment(runtime, local, headless, outbound, key => environment.GetValueOrDefault(key));

  [Fact]
  public void AbsentConfigurationIsInertEvenForOrdinaryServer()
  {
    environment.Clear();
    Assert.Null(Open(false, false, true));
    Assert.False(File.Exists(Path.Combine(Root, ".lease")));
  }

  [Theory]
  [InlineData(0)]
  [InlineData(1)]
  [InlineData(2)]
  [InlineData(3)]
  [InlineData(4)]
  [InlineData(5)]
  public void EveryPartialOrBlankConfigurationFailsBeforeLease(int field)
  {
    var name = ExecutionAssetOverlayStartup.EnvironmentNames[field];
    environment.Remove(name);
    Assert.Equal("execution_fx_startup_rejected", Assert.Throws<InvalidDataException>(() => Open()).Message);
    environment[name] = " ";
    Assert.Throws<InvalidDataException>(() => Open());
    Assert.False(File.Exists(Path.Combine(Root, ".lease")));
  }

  [Theory]
  [InlineData(false, true, false)]
  [InlineData(true, false, false)]
  [InlineData(true, true, true)]
  public void UnsafeExecutionModeNeverMounts(bool local, bool headless, bool outbound)
  {
    Assert.Throws<InvalidDataException>(() => Open(local, headless, outbound));
    Assert.False(File.Exists(Path.Combine(Root, ".lease")));
  }

  [Fact]
  public void ForeignRootAndBindingDriftAreControlledAndDoNotAcquireLease()
  {
    environment[ExecutionAssetOverlayStartup.EnvironmentNames[0]] = runtime;
    Assert.Throws<InvalidDataException>(() => Open());
    environment[ExecutionAssetOverlayStartup.EnvironmentNames[0]] = Root;
    environment[ExecutionAssetOverlayStartup.EnvironmentNames[4]] = new string('d', 64);
    var error = Assert.Throws<InvalidDataException>(() => Open());
    Assert.Equal("execution_fx_startup_rejected", error.Message);
    Assert.Null(error.InnerException);
    Assert.False(File.Exists(Path.Combine(Root, ".lease")));
  }

  [Fact]
  public async Task MountedMiddlewarePrecedesLegacyRoutesAndNeverFallsBackOnRejection()
  {
    using var startup = Open()!;
    var builder = WebApplication.CreateBuilder();
    builder.Logging.ClearProviders();
    builder.WebHost.ConfigureKestrel(options => options.Listen(IPAddress.Loopback, 0));
    await using var app = builder.Build();
    startup.Mount(app);
    var fallbackCount = 0;
    app.Run(context => { Interlocked.Increment(ref fallbackCount); return context.Response.WriteAsync("legacy"); });
    await app.StartAsync();
    try
    {
      var addresses = app.Services.GetRequiredService<IServer>().Features.Get<IServerAddressesFeature>()!;
      using var client = new HttpClient(new HttpClientHandler { UseProxy = false })
      { BaseAddress = new Uri(addresses.Addresses.Single()), Timeout = TimeSpan.FromSeconds(10) };
      Assert.Equal(derived, await client.GetByteArrayAsync(Route));
      using var head = await client.SendAsync(new HttpRequestMessage(HttpMethod.Head, Route));
      Assert.Equal(derived.Length, head.Content.Headers.ContentLength);
      using var invalid = await client.GetAsync(Route + "?bad=1");
      Assert.Equal(HttpStatusCode.Conflict, invalid.StatusCode);
      using var post = await client.PostAsync(Route, null);
      Assert.Equal(HttpStatusCode.MethodNotAllowed, post.StatusCode);
      Assert.Equal(0, fallbackCount);
      Assert.Equal("legacy", await client.GetStringAsync("/PC/synthetic/other.bundle"));
      Assert.Equal("legacy", await client.GetStringAsync("/prdenv/synthetic/catalog.db"));
      Assert.Equal(2, fallbackCount);
      startup.Dispose();
      using var closed = await client.GetAsync(Route);
      Assert.Equal(HttpStatusCode.Conflict, closed.StatusCode);
      Assert.Equal(2, fallbackCount);
      Assert.True(File.Exists(Path.Combine(Root, "overlay.bundle"))); // Host exit is not tree exit.
      Assert.False(File.Exists(Path.Combine(Root, "retired.json")));
    }
    finally { await app.StopAsync(); }
  }

  public void Dispose() => Directory.Delete(runtime, recursive: true); // This fixture's synthetic temp tree only.
}
