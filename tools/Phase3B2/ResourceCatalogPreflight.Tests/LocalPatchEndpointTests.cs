using System.Net;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.Features;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.Logging;
using ResourceCatalogPreflight;
using Xunit;

namespace ResourceCatalogPreflight.Tests;

public sealed class LocalPatchEndpointTests
{
  private static readonly byte[] Payload = "NKDBsynthetic"u8.ToArray();

  [Fact]
  public async Task ExactCatalogGetPreservesBytesAndHeadHasNoBody()
  {
    var endpoint = Endpoint();
    var get = Context();
    await endpoint.HandleAsync(get);
    Assert.Equal(200, get.Response.StatusCode);
    Assert.Equal(Payload, Body(get));
    Assert.Equal(Payload.Length, get.Response.ContentLength);
    var head = Context();
    head.Request.Method = "HEAD";
    await endpoint.HandleAsync(head);
    Assert.Equal(200, head.Response.StatusCode);
    Assert.Empty(Body(head));
    Assert.Equal(Payload.Length, head.Response.ContentLength);
  }

  [Fact]
  public async Task PakSingleRangeIs206WithExactCoordinates()
  {
    var context = Context();
    context.Request.Headers.Range = "bytes=1-3";
    await Endpoint(rangeRequired: true).HandleAsync(context);
    Assert.Equal(206, context.Response.StatusCode);
    Assert.Equal(Payload[1..4], Body(context));
    Assert.Equal($"bytes 1-3/{Payload.Length}", context.Response.Headers.ContentRange.ToString());
    Assert.Equal(3, context.Response.ContentLength);
  }

  [Theory]
  [InlineData("bytes=0-")]
  [InlineData("bytes=-2")]
  [InlineData("bytes=0-2,4-5")]
  [InlineData("bytes=4-3")]
  [InlineData("bytes=0-9999999999999999999999")]
  [InlineData("bytes=0-999")]
  [InlineData("bytes=0-3\n")]
  public async Task UnimplementedOrInvalidRangeCannotFallBackToWholePak(string range)
  {
    var context = Context();
    context.Request.Headers.Range = range;
    await Endpoint(rangeRequired: true).HandleAsync(context);
    Assert.Equal(416, context.Response.StatusCode);
    Assert.Empty(Body(context));
  }

  [Fact]
  public async Task PakNeedsRangeAndMissingChunkReturnsNoPartialSuccess()
  {
    var context = Context();
    await Endpoint(rangeRequired: true).HandleAsync(context);
    Assert.Equal(416, context.Response.StatusCode);
    context = Context();
    context.Request.Headers.Range = "bytes=0-3";
    await Endpoint(rangeRequired: true, read: (_, _) => throw new PreflightException("resource_chunk_member_missing"))
        .HandleAsync(context);
    Assert.Equal(503, context.Response.StatusCode);
    Assert.Empty(Body(context));
  }

  [Theory]
  [InlineData("/other", 404)]
  [InlineData("/../catalog.ndb", 400)]
  [InlineData("//catalog.ndb", 400)]
  [InlineData("/%2e/catalog.ndb", 400)]
  public async Task UnlistedOrNoncanonicalPathsDoNotFallBackToDisk(string path, int status)
  {
    var context = Context();
    context.Request.Path = path;
    await Endpoint().HandleAsync(context);
    Assert.Equal(status, context.Response.StatusCode);
    Assert.Empty(Body(context));
  }

  [Fact]
  public async Task ForeignConnectionsHostsAndCredentialsAreRejected()
  {
    foreach (var variant in new[] { "remote", "local", "host", "Authorization", "Cookie" })
    {
      var context = Context();
      switch (variant)
      {
        case "remote": context.Connection.RemoteIpAddress = IPAddress.Parse("192.0.2.1"); break;
        case "local": context.Connection.LocalIpAddress = IPAddress.Any; break;
        case "host": context.Request.Host = new HostString("other.example"); break;
        default: context.Request.Headers[variant] = "synthetic-only"; break;
      }
      await Endpoint().HandleAsync(context);
      Assert.Equal(403, context.Response.StatusCode);
    }
  }

  [Fact]
  public async Task QueryNormalizationAndConditionalRequestsFailClosed()
  {
    var context = Context();
    context.Request.QueryString = new QueryString("?x=1");
    await Endpoint().HandleAsync(context);
    Assert.Equal(400, context.Response.StatusCode);
    context = Context();
    context.Features.Get<IHttpRequestFeature>()!.RawTarget = "/%63atalog.ndb";
    await Endpoint().HandleAsync(context);
    Assert.Equal(400, context.Response.StatusCode);
    context = Context();
    context.Request.Headers.IfRange = "synthetic-etag";
    await Endpoint().HandleAsync(context);
    Assert.Equal(412, context.Response.StatusCode);
    context = Context();
    context.Request.Method = "POST";
    await Endpoint().HandleAsync(context);
    Assert.Equal(405, context.Response.StatusCode);
  }

  [Fact]
  public void InvalidManifestIsRejectedBeforeRequestHandling()
  {
    Assert.Throws<PreflightException>(() => new LocalPatchEndpoint("fixture.example",
        new Dictionary<string, LocalPatchEndpoint.Resource> { ["/../escape"] = new(3, false, (_, _) => []) }));
    Assert.Throws<PreflightException>(() => new LocalPatchEndpoint("fixture.example",
        new Dictionary<string, LocalPatchEndpoint.Resource> { ["/catalog.ndb\n"] = new(3, false, (_, _) => []) }));
  }

  [Fact]
  public async Task SyntheticHttpRoundTripUsesOnlyTemporaryLoopbackListener()
  {
    var builder = WebApplication.CreateSlimBuilder();
    builder.Logging.ClearProviders();
    builder.WebHost.ConfigureKestrel(options => options.Listen(IPAddress.Loopback, 0));
    await using var app = builder.Build();
    var endpoint = Endpoint();
    app.Run(endpoint.HandleAsync);
    using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
    await app.StartAsync(timeout.Token);
    try
    {
      var address = new Uri(app.Urls.Single());
      Assert.Equal("127.0.0.1", address.Host);
      using var client = new HttpClient(new SocketsHttpHandler
      {
        UseProxy = false, UseCookies = false, AllowAutoRedirect = false
      });
      client.DefaultRequestHeaders.Host = "fixture.example";
      using var whole = await client.GetAsync(new Uri(address, "/catalog.ndb"), timeout.Token);
      Assert.Equal(HttpStatusCode.OK, whole.StatusCode);
      Assert.Equal(Payload, await whole.Content.ReadAsByteArrayAsync(timeout.Token));
      using var request = new HttpRequestMessage(HttpMethod.Get, new Uri(address, "/catalog.ndb"));
      request.Headers.Range = new System.Net.Http.Headers.RangeHeaderValue(1, 3);
      using var part = await client.SendAsync(request, timeout.Token);
      Assert.Equal(HttpStatusCode.PartialContent, part.StatusCode);
      Assert.Equal(Payload[1..4], await part.Content.ReadAsByteArrayAsync(timeout.Token));
      using var missing = await client.GetAsync(new Uri(address, "/not-in-manifest"), timeout.Token);
      Assert.Equal(HttpStatusCode.NotFound, missing.StatusCode);
    }
    finally { await app.StopAsync(CancellationToken.None); }
  }

  private static LocalPatchEndpoint Endpoint(bool rangeRequired = false, Func<long, int, byte[]>? read = null) =>
      new("fixture.example", new Dictionary<string, LocalPatchEndpoint.Resource>
      {
        ["/catalog.ndb"] = new(Payload.Length, rangeRequired,
            read ?? ((offset, count) => Payload.AsSpan((int)offset, count).ToArray()))
      });

  private static DefaultHttpContext Context()
  {
    var context = new DefaultHttpContext();
    context.Connection.LocalIpAddress = IPAddress.Loopback;
    context.Connection.RemoteIpAddress = IPAddress.Loopback;
    context.Request.Host = new HostString("fixture.example");
    context.Request.Method = "GET";
    context.Request.Path = "/catalog.ndb";
    context.Response.Body = new MemoryStream();
    return context;
  }

  private static byte[] Body(HttpContext context) => ((MemoryStream)context.Response.Body).ToArray();
}
