using System.Data.Common;
using System.Net;
using System.Net.Http.Headers;
using System.Reflection;
using System.Runtime.Loader;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

// Explicit local-only verification of the built external adapter, never Epinel Main.
// The caller pins the candidate's entire output inventory before/after invoking it.
try
{
  Check(args.Length >= 3 && Environment.Version.Major == 10);
  var server = Path.GetFullPath(args[1]);
  var dll = Path.Combine(server, "EpinelPS.dll");
  Check(Hash(File.ReadAllBytes(dll)) == args[2]);
  AssemblyLoadContext.Default.Resolving += (_, name) =>
  {
    Check(name.Name is not null && Path.GetFileName(name.Name) == name.Name);
    var file = Path.Combine(server, name.Name + ".dll");
    return File.Exists(file) ? AssemblyLoadContext.Default.LoadFromAssemblyPath(file) : null;
  };
  var assembly = AssemblyLoadContext.Default.LoadFromAssemblyPath(dll);
  if (args[0] == "catalog")
  {
    Check(args.Length == 7);
    Check(new FileInfo(args[3]).Length is > 0 and <= 64 * 1024 * 1024);
    var raw = File.ReadAllBytes(args[3]);
    Check(Hash(raw) == args[4] && raw.Length <= 64 * 1024 * 1024);
    if (!raw.AsSpan().StartsWith("SQLite format 3\0"u8))
    {
      Check(raw.Length >= 36 && raw.AsSpan(0, 8).SequenceEqual(new byte[] { 78, 75, 68, 66, 0, 0, 0, 1 }));
      var segmentSize = System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(raw.AsSpan(24, 4));
      var segmentCount = System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(raw.AsSpan(28, 4));
      Check(segmentSize > 0 && segmentCount > 0 && (ulong)segmentSize * segmentCount <= 64 * 1024 * 1024 &&
          36UL + segmentCount * 4UL <= (ulong)raw.Length);
    }
    var sqlite = raw.AsSpan().StartsWith("SQLite format 3\0"u8) ? raw :
        (byte[])assembly.GetType("EpinelPS.Data.NkdbDecryptor")!.GetMethod("Decrypt")!.Invoke(null, [raw])!;
    Check(sqlite.AsSpan().StartsWith("SQLite format 3\0"u8));
    // Inspection copy is private, new, outside the installed client. Never modify its catalog.
    var path = Path.Combine(AppContext.BaseDirectory, Guid.NewGuid().ToString("N") + ".private.sqlite");
    using (var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None)) file.Write(sqlite);
    var dbAssembly = AssemblyLoadContext.Default.LoadFromAssemblyPath(Path.Combine(server, "Microsoft.Data.Sqlite.dll"));
    using var db = (DbConnection)Activator.CreateInstance(dbAssembly.GetType("Microsoft.Data.Sqlite.SqliteConnection")!,
        ["Data Source=" + path + ";Mode=ReadOnly;Pooling=False"])!;
    db.Open();
    using var cmd = db.CreateCommand();
    cmd.CommandText = "PRAGMA trusted_schema=OFF";
    cmd.ExecuteNonQuery();
    cmd.CommandText = "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name";
    var tables = new List<string>();
    using (var reader = cmd.ExecuteReader()) while (reader.Read()) tables.Add(reader.GetString(0));
    var schema = new Dictionary<string, string[]>();
    foreach (var table in tables)
    {
      cmd.CommandText = "SELECT name FROM pragma_table_info($table) ORDER BY cid";
      cmd.Parameters.Clear(); var parameter = cmd.CreateParameter(); parameter.ParameterName = "$table"; parameter.Value = table; cmd.Parameters.Add(parameter);
      var columns = new List<string>();
      using var reader = cmd.ExecuteReader();
      while (reader.Read()) columns.Add(reader.GetString(0));
      schema[table] = columns.ToArray();
    }
    var deliveryBytes = File.ReadAllBytes(args[5]);
    Check(Hash(deliveryBytes) == args[6]);
    using var delivery = JsonDocument.Parse(deliveryBytes);
    var leaf = Path.GetFileName(delivery.RootElement.GetProperty("requestPath").GetString()!);
    Check(schema.ContainsKey("internal_ids") && schema.ContainsKey("entry_data"));
    cmd.Parameters.Clear();
    var leafParameter = cmd.CreateParameter(); leafParameter.ParameterName = "$leaf"; leafParameter.Value = leaf; cmd.Parameters.Add(leafParameter);
    cmd.CommandText = "SELECT COUNT(*) FROM internal_ids WHERE internal_id=$leaf COLLATE BINARY OR substr(internal_id,-length($leaf)-1)='/' || $leaf COLLATE BINARY";
    var exactBundleMatches = Convert.ToInt64(cmd.ExecuteScalar());
    cmd.CommandText = "SELECT COUNT(*) FROM internal_ids WHERE internal_id LIKE '%.bundle'";
    var bundleEntries = Convert.ToInt64(cmd.ExecuteScalar());
    // A name-stem hint is diagnostic only, never an admitted route or a replacement for exact closure.
    var stem = Regex.Replace(leaf, "_[0-9a-f]{32}\\.bundle$", "", RegexOptions.CultureInvariant);
    leafParameter.Value = stem;
    cmd.CommandText = "SELECT COUNT(*) FROM internal_ids WHERE instr(internal_id,$leaf)>0";
    var nameStemMatches = Convert.ToInt64(cmd.ExecuteScalar());
    cmd.CommandText = "SELECT COUNT(*) FROM entry_data WHERE is_local=1";
    var localEntries = schema["entry_data"].Contains("is_local") ? Convert.ToInt64(cmd.ExecuteScalar()) : -1;
    db.Close();
    File.Delete(path); // This probe's unique private inspection copy, not a client/catalog cache file.
    Console.WriteLine(JsonSerializer.Serialize(new
    {
      contractId = "nll/fx-catalog-inspection/v1",
      sourceSha256 = args[4],
      schema,
      bundleEntries,
      exactBundleMatches,
      localEntries,
      nameStemMatches,
      hashSuffixRemoved = stem != leaf,
      nativeDeliveryStatusCode = "unresolved",
      deliveryManifestSha256 = args[6],
      nativeClientExecuted = false
    }));
    return 0;
  }
  Check(args[0] is "http" or "retire" && args.Length == 4);
  var root = Path.Combine(server, "execution-fx");
  var manifestBytes = File.ReadAllBytes(Path.Combine(root, "manifest.private.json"));
  Check(Hash(manifestBytes) == args[3]);
  using var manifest = JsonDocument.Parse(manifestBytes);
  var row = manifest.RootElement;
  string Field(string name) => row.GetProperty(name).GetString()!;
  if (args[0] == "retire")
  {
    var bindingType = assembly.GetType("NikkeLocalLab.Automation.ExecutionAssetBinding")!;
    var binding = Activator.CreateInstance(bindingType,
        [Field("executionCode"), Field("candidateSealSha256"), Field("profileSha256"), Field("weaknessCode")]);
    assembly.GetType("NikkeLocalLab.Automation.ExecutionAssetOverlay")!.GetMethod("Retire")!.Invoke(null, [root, args[3], binding]);
    Console.WriteLine("{\"contractId\":\"nll/epinel-fx-probe-retirement/v1\",\"statusCode\":\"passed\",\"productionProcessTreeVerified\":false}");
    return 0;
  }
  var route = Field("requestPath");
  var expected = row.GetProperty("overlay").GetProperty("sha256").GetString();
  var env = new Dictionary<string, string?>
  {
    ["EPINELPS_EXECUTION_FX_ROOT"] = root,
    ["EPINELPS_EXECUTION_FX_MANIFEST_SHA256"] = args[3],
    ["EPINELPS_EXECUTION_FX_EXECUTION_CODE"] = Field("executionCode"),
    ["EPINELPS_EXECUTION_FX_CANDIDATE_SHA256"] = Field("candidateSealSha256"),
    ["EPINELPS_EXECUTION_FX_PROFILE_SHA256"] = Field("profileSha256"),
    ["EPINELPS_EXECUTION_FX_WEAKNESS_CODE"] = Field("weaknessCode")
  };
  var asset = assembly.GetType("EpinelPS.Utils.AssetDownloadUtil")!;
  asset.GetMethod("ConfigureOfficialOutbound")!.Invoke(null, [false]);
  var startupType = assembly.GetType("NikkeLocalLab.AssetDelivery.ExecutionAssetOverlayStartup")!;
  using var startup = (IDisposable)startupType.GetMethod("OpenFromEnvironment")!.Invoke(null,
      [server, true, true, false, (Func<string, string?>)(key => env.GetValueOrDefault(key))])!;
  var handler = asset.GetMethod("HandleReq")!.CreateDelegate<Func<HttpContext, string, Task>>();
  var builder = WebApplication.CreateBuilder();
  builder.Logging.ClearProviders();
  builder.WebHost.ConfigureKestrel(options => options.Listen(IPAddress.Loopback, 0));
  await using var app = builder.Build();
  startupType.GetMethod("Mount")!.Invoke(startup, [app]);
  app.UseMiddleware(assembly.GetType("EpinelPS.Networking.EncryptionMiddleware")!);
  app.MapGet("/PC/{**all}", handler);
  app.MapGet("/prdenv/{**all}", handler);
  await app.StartAsync();
  try
  {
    var address = app.Services.GetRequiredService<IServer>().Features.Get<IServerAddressesFeature>()!.Addresses.Single();
    using var client = new HttpClient(new HttpClientHandler { UseProxy = false })
    { BaseAddress = new Uri(address), Timeout = TimeSpan.FromSeconds(10) };
    using var full = await client.GetAsync(route);
    var bytes = await full.Content.ReadAsByteArrayAsync();
    Check(full.StatusCode == HttpStatusCode.OK && Hash(bytes) == expected && full.Headers.CacheControl?.NoStore == true);
    using var request = new HttpRequestMessage(HttpMethod.Get, route);
    request.Headers.Range = new RangeHeaderValue(2, 15);
    using var range = await client.SendAsync(request);
    Check(range.StatusCode == HttpStatusCode.PartialContent && (await range.Content.ReadAsByteArrayAsync()).SequenceEqual(bytes[2..16]));
    using var head = await client.SendAsync(new HttpRequestMessage(HttpMethod.Head, route));
    Check(head.StatusCode == HttpStatusCode.OK && head.Content.Headers.ContentLength == bytes.Length && (await head.Content.ReadAsByteArrayAsync()).Length == 0);
    using var invalid = await client.GetAsync(route + "?invalid=1");
    Check(invalid.StatusCode == HttpStatusCode.Conflict);
    using var post = await client.PostAsync(route, null);
    Check(post.StatusCode == HttpStatusCode.MethodNotAllowed);
    // Exercise the real legacy handler without touching its cache: preexisting variant route.
    asset.GetMethod("ConfigureClientStaticDataVariant")!.Invoke(null, ["/prdenv/synthetic/StaticData.pack", typeof(Program).Assembly.Location]);
    using var legacy = await client.GetAsync("/prdenv/synthetic/StaticData.pack");
    Check(legacy.StatusCode == HttpStatusCode.OK && Hash(await legacy.Content.ReadAsByteArrayAsync()) == Hash(File.ReadAllBytes(typeof(Program).Assembly.Location)));
    startup.Dispose();
    using var closed = await client.GetAsync(route);
    Check(closed.StatusCode == HttpStatusCode.Conflict);
  }
  finally { await app.StopAsync(); }
  Console.WriteLine(JsonSerializer.Serialize(new
  {
    contractId = "nll/epinel-fx-mount-probe/v1",
    statusCode = "passed",
    epinelSha256 = args[2],
    manifestSha256 = args[3],
    actualExternalAssetHandler = true,
    nativeClientExecuted = false,
    operatingDatabaseTouched = false,
    deployed = false,
    runtimeAdmissionStatusCode = "not_assessed",
    privateCopiesRetired = false
  }));
  return 0;
}
catch
{
  Console.Error.WriteLine("epinel_fx_probe_failed");
  return 1;
}

static void Check(bool value) { if (!value) throw new InvalidDataException("epinel_fx_probe_failed"); }
static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
