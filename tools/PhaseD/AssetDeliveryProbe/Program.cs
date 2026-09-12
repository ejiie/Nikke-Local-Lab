using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using NikkeLocalLab.AssetDelivery;
using NikkeLocalLab.Automation;

// Explicit local-data check only. No Epinel, DB, client, hosts, firewall or admission.
try
{
  Check(args.Length == 3);
  var root = args[0];
  var receiptBytes = File.ReadAllBytes(args[1]);
  Check(Hash(receiptBytes) == args[2]);
  using var receipt = JsonDocument.Parse(receiptBytes);
  var row = receipt.RootElement;
  string Field(string name) => row.GetProperty(name).GetString()!;
  Check(Field("contractId") == "nll/execution-fx-staging-receipt/v1" &&
      Field("runtimeAdmissionStatusCode") == "not_assessed" &&
      !row.GetProperty("clientStarted").GetBoolean() && !row.GetProperty("sharedCacheModified").GetBoolean());
  var manifestSha = Field("manifestSha256");
  var binding = new ExecutionAssetBinding(Field("executionCode"), Field("candidateSealSha256"),
      Field("profileSha256"), Field("weaknessCode"));
  using var overlay = ExecutionAssetOverlay.Open(root, manifestSha, binding, officialOutboundEnabled: false);
  using var manifest = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(root, "manifest.private.json")));
  var path = manifest.RootElement.GetProperty("requestPath").GetString()!;
  var expected = manifest.RootElement.GetProperty("overlay").GetProperty("sha256").GetString();
  var bytes = overlay.GetResponse(path)!;
  Check(Hash(bytes) == expected);
  var blocked = false;
  try { ExecutionAssetOverlay.Retire(root, manifestSha, binding); }
  catch (InvalidDataException error) when (error.Message == "execution_fx_busy_or_unclean_owner") { blocked = true; }
  Check(blocked);
  var builder = WebApplication.CreateBuilder();
  builder.Logging.ClearProviders();
  builder.WebHost.ConfigureKestrel(options => options.Listen(IPAddress.Loopback, 0));
  await using var app = builder.Build();
  var http = new ExecutionAssetOverlayHttp(overlay);
  app.Run(async context =>
  {
    if (!await http.TryHandleAsync(context))
      context.Response.StatusCode = 404;
  });
  await app.StartAsync();
  try
  {
    var address = app.Services.GetRequiredService<IServer>().Features.Get<IServerAddressesFeature>()!.Addresses.Single();
    using var client = new HttpClient(new HttpClientHandler { UseProxy = false })
    {
      BaseAddress = new Uri(address),
      Timeout = TimeSpan.FromSeconds(10)
    };
    using var full = await client.GetAsync(path);
    Check(full.StatusCode == HttpStatusCode.OK && Hash(await full.Content.ReadAsByteArrayAsync()) == expected &&
        full.Headers.CacheControl?.NoStore == true);
    using var request = new HttpRequestMessage(HttpMethod.Get, path);
    request.Headers.Range = new RangeHeaderValue(2, 15);
    using var range = await client.SendAsync(request);
    Check(range.StatusCode == HttpStatusCode.PartialContent &&
        (await range.Content.ReadAsByteArrayAsync()).SequenceEqual(bytes[2..16]));
    using var head = await client.SendAsync(new HttpRequestMessage(HttpMethod.Head, path));
    Check(head.StatusCode == HttpStatusCode.OK && head.Content.Headers.ContentLength == bytes.Length &&
        (await head.Content.ReadAsByteArrayAsync()).Length == 0);
    using var invalid = await client.GetAsync(path + "?invalid=1");
    Check(invalid.StatusCode == HttpStatusCode.Conflict);
  }
  finally { await app.StopAsync(); }
  overlay.Dispose();
  ExecutionAssetOverlay.Retire(root, manifestSha, binding);
  ExecutionAssetOverlay.Retire(root, manifestSha, binding);
  blocked = false;
  try { using var unexpected = ExecutionAssetOverlay.Open(root, manifestSha, binding, false); }
  catch (InvalidDataException error) when (error.Message == "execution_fx_retired") { blocked = true; }
  Check(blocked);
  Console.WriteLine(JsonSerializer.Serialize(new
  {
    contractId = "nll/execution-fx-http-probe/v1",
    statusCode = "passed",
    manifestSha256 = manifestSha,
    weaknessCode = binding.WeaknessCode,
    fullRangeHeadVerified = true,
    activeRetirementBlocked = true,
    retirementChecks = 2,
    retiredReopenBlocked = true,
    originalClientExecuted = false,
    runtimeAdmissionStatusCode = "not_assessed"
  }));
  return 0;
}
catch
{
  Console.Error.WriteLine("execution_fx_http_probe_failed"); // No raw request/path/payload exception logs.
  return 1;
}

static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
static void Check(bool condition)
{
  if (!condition)
    throw new InvalidDataException("execution_fx_http_probe_assertion_failed");
}
