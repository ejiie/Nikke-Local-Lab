using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.Features;
using Microsoft.Extensions.Logging;
using ResourceCatalogPreflight;
using Xunit;

namespace ResourceCatalogPreflight.Tests;

public sealed class ResourceRouteProbeTests
{
  private const string MetadataPath = "/fixture/platform/pck/latest-123.txt";
  private static readonly byte[] Metadata = Encoding.UTF8.GetBytes(
      "abcdef0\ncore:151.8.b1,123\ndp:abcdef1,124\nfd:abcdef2,125\nsaus:abcdef3,126\nko:abcdef4,127\nen:abcdef5,128\nja:abcdef6,129\n");
  private static readonly string Digest = Convert.ToHexString(SHA256.HashData(Metadata)).ToLowerInvariant();

  [Fact]
  public async Task OnlyPinnedMetadataCanBeServedAndInputIsDefensivelyCopied()
  {
    var records = new List<ResourceRouteProbe.Observation>();
    var input = Metadata.ToArray();
    var endpoint = new ResourceRouteProbe("fixture.example", MetadataPath, input, Digest,
        observation => { records.Add(observation); return true; });
    input[0] ^= 1;
    var get = Context(MetadataPath);
    await endpoint.HandleAsync(get);
    Assert.Equal(200, get.Response.StatusCode);
    Assert.Equal(Metadata, Body(get));
    var head = Context(MetadataPath);
    head.Request.Method = "HEAD";
    await endpoint.HandleAsync(head);
    Assert.Equal(Metadata.Length, head.Response.ContentLength);
    Assert.Empty(Body(head));
    foreach (var path in new[] { "/catalog.ndb", "/raw/member", "/packs/sample.pak", "/StaticData.pack", "/battle/result" })
    {
      var context = Context(path);
      await endpoint.HandleAsync(context);
      Assert.Equal(404, context.Response.StatusCode);
      Assert.Empty(Body(context));
    }
    Assert.Equal(7, records.Count);
  }

  [Theory]
  [InlineData("bytes=1-9", "closed", 1)]
  [InlineData("bytes=9-", "open_ended", 1)]
  [InlineData("bytes=-9", "suffix", 1)]
  [InlineData("bytes=1-9, 20-30", "multiple", 2)]
  [InlineData("bytes=9-1", "unresolved", 0)]
  [InlineData("bytes=-0", "unresolved", 0)]
  [InlineData("bytes=9223372036854775808-", "unresolved", 0)]
  [InlineData("bytes=1-9\n", "unresolved", 0)]
  public async Task RangeCoordinatesAreObservedWithoutServingPak(string range, string shape, int count)
  {
    ResourceRouteProbe.Observation? observed = null;
    var endpoint = Endpoint(record => { observed = record; return true; });
    var context = Context("/fixture/sample.pak");
    context.Request.Headers.Range = range;
    await endpoint.HandleAsync(context);
    Assert.Equal(404, context.Response.StatusCode);
    Assert.Empty(Body(context));
    Assert.Equal(shape, observed!.RangeShape);
    Assert.Equal(count, observed.Ranges.Count);
    if (shape == "closed")
    {
      Assert.Equal(1L, observed.Ranges[0].Start);
      Assert.Equal(9L, observed.Ranges[0].End);
    }
  }

  [Fact]
  public async Task ConditionalValuesAndInvalidRangeStringsAreNeverRetained()
  {
    ResourceRouteProbe.Observation? observed = null;
    var endpoint = Endpoint(record => { observed = record; return true; });
    var context = Context(MetadataPath);
    context.Request.Headers.IfRange = "synthetic-private-etag";
    context.Request.Headers.Range = "synthetic-private-invalid-range";
    await endpoint.HandleAsync(context);
    Assert.Equal(412, context.Response.StatusCode);
    Assert.Equal(new[] { "If-Range" }, observed!.ConditionalHeaders);
    Assert.DoesNotContain("synthetic-private", JsonSerializer.Serialize(observed));
    Assert.Empty(Body(context));
  }

  [Theory]
  [InlineData("foreign-remote", 403)]
  [InlineData("wildcard-local", 403)]
  [InlineData("foreign-host", 403)]
  [InlineData("foreign-port", 403)]
  [InlineData("Authorization", 403)]
  [InlineData("Proxy-Authorization", 403)]
  [InlineData("Cookie", 403)]
  [InlineData("query", 400)]
  [InlineData("encoded", 400)]
  [InlineData("traversal", 400)]
  [InlineData("body", 400)]
  [InlineData("chunked-body", 400)]
  [InlineData("long-path", 400)]
  [InlineData("post", 405)]
  public async Task InvalidRequestsAreRejectedBeforeObservation(string variant, int status)
  {
    var count = 0;
    var endpoint = Endpoint(_ => { count++; return true; });
    var context = Context("/catalog.ndb");
    switch (variant)
    {
      case "foreign-remote": context.Connection.RemoteIpAddress = IPAddress.Parse("192.0.2.1"); break;
      case "wildcard-local": context.Connection.LocalIpAddress = IPAddress.Any; break;
      case "foreign-host": context.Request.Host = new HostString("other.example"); break;
      case "foreign-port": context.Request.Host = new HostString("fixture.example", 8443); break;
      case "query": context.Request.QueryString = new QueryString("?secret=synthetic"); break;
      case "encoded": context.Features.Get<IHttpRequestFeature>()!.RawTarget = "/%63atalog.ndb"; break;
      case "traversal": context.Request.Path = "/a/../catalog.ndb"; break;
      case "body": context.Request.ContentLength = 1; break;
      case "chunked-body": context.Request.Headers.TransferEncoding = "chunked"; break;
      case "long-path": context.Request.Path = "/" + new string('a', 2048); break;
      case "post": context.Request.Method = "POST"; break;
      default: context.Request.Headers[variant] = "synthetic-private"; break;
    }
    await endpoint.HandleAsync(context);
    Assert.Equal(status, context.Response.StatusCode);
    Assert.Equal(0, count);
    Assert.Empty(Body(context));
  }

  [Fact]
  public async Task SinkFailureCannotSendMetadataAndLimitIsAtomic()
  {
    foreach (var sink in new Func<ResourceRouteProbe.Observation, bool>[]
    {
      _ => false, _ => throw new IOException("synthetic-private")
    })
    {
      var context = Context(MetadataPath);
      await Endpoint(sink).HandleAsync(context);
      Assert.Equal(503, context.Response.StatusCode);
      Assert.Empty(Body(context));
    }
    var count = 0;
    var bounded = new ResourceRouteProbe("fixture.example", MetadataPath, Metadata, Digest,
        _ => { count++; return true; }, maximumRequests: 2);
    var requests = Enumerable.Range(0, 12).Select(_ => Context(MetadataPath)).ToArray();
    await Task.WhenAll(requests.Select(context => Task.Run(() => bounded.HandleAsync(context))));
    Assert.Equal(2, count);
    Assert.Equal(2, bounded.ObservationCount);
    Assert.Equal(2, requests.Count(context => context.Response.StatusCode == 200));
    Assert.Equal(10, requests.Count(context => context.Response.StatusCode == 503));
  }

  [Fact]
  public void AssetBodiesOrChangedMetadataAreNotAcceptedAsMetadata()
  {
    Assert.Throws<PreflightException>(() => new ResourceRouteProbe("fixture.example", MetadataPath,
        Metadata, new string('0', 64), _ => true));
    Assert.Throws<PreflightException>(() => new ResourceRouteProbe("fixture.example", "/catalog.ndb",
        Metadata, Digest, _ => true));
    Assert.ThrowsAny<Exception>(() => new ResourceRouteProbe("fixture.example", MetadataPath,
        "NKDBfixture"u8.ToArray(), Convert.ToHexString(SHA256.HashData("NKDBfixture"u8)).ToLowerInvariant(), _ => true));
  }

  [Fact]
  public async Task ActualSyntheticLoopbackTransportObservesMissingCatalogAndStopsCleanly()
  {
    var records = new List<ResourceRouteProbe.Observation>();
    var builder = WebApplication.CreateSlimBuilder();
    builder.Logging.ClearProviders();
    builder.WebHost.ConfigureKestrel(options => options.Listen(IPAddress.Loopback, 0));
    await using var app = builder.Build();
    app.Run(Endpoint(record => { records.Add(record); return true; }).HandleAsync);
    using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
    await app.StartAsync(timeout.Token);
    try
    {
      using var client = new HttpClient(new SocketsHttpHandler
      { UseProxy = false, UseCookies = false, AllowAutoRedirect = false });
      client.DefaultRequestHeaders.Host = "fixture.example";
      var address = new Uri(app.Urls.Single());
      using var metadata = await client.GetAsync(new Uri(address, MetadataPath), timeout.Token);
      Assert.Equal(Metadata, await metadata.Content.ReadAsByteArrayAsync(timeout.Token));
      using var catalog = await client.GetAsync(new Uri(address, "/fixture/catalog.ndb"), timeout.Token);
      Assert.Equal(HttpStatusCode.NotFound, catalog.StatusCode);
      Assert.Empty(await catalog.Content.ReadAsByteArrayAsync(timeout.Token));
      Assert.Equal(new[] { MetadataPath, "/fixture/catalog.ndb" }, records.Select(record => record.Path));
    }
    finally { await app.StopAsync(CancellationToken.None); }
  }

  private static ResourceRouteProbe Endpoint(Func<ResourceRouteProbe.Observation, bool> sink) =>
      new("fixture.example", MetadataPath, Metadata, Digest, sink);

  private static DefaultHttpContext Context(string path)
  {
    var context = new DefaultHttpContext();
    context.Connection.LocalIpAddress = IPAddress.Loopback;
    context.Connection.RemoteIpAddress = IPAddress.Loopback;
    context.Request.Method = "GET";
    context.Request.Host = new HostString("fixture.example");
    context.Request.Path = path;
    context.Response.Body = new MemoryStream();
    return context;
  }

  private static byte[] Body(HttpContext context) => ((MemoryStream)context.Response.Body).ToArray();
}
