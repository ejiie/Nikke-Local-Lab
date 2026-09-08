using System.Net;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Server.Kestrel.Core;
using Microsoft.Extensions.Logging;

namespace ResourceCatalogPreflight;

// Separate metadata-only listener on 127.0.0.1:8443; it is not a game server or
// launch controller. Neither production Epinel, DB nor game processes are used.
internal static class ResourceRouteProbeHost
{
  internal const string EvidenceParent = @"C:\NLL\Staging\ResourceProbeRuns";
  private static readonly JsonSerializerOptions JsonOptions = new()
  {
    PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
  };

  internal sealed record Plan(string ContractId, string AssessmentUid, string ExpectedHost,
      string MetadataRequestPath, string MetadataFile, long MetadataByteLength, string MetadataSha256,
      string CertificateFile, long CertificateByteLength, string CertificateSha256,
      int DurationSeconds, int MaximumRequests);

  internal static Plan ReadPlan(string path, string sha256, string allowedParent = EvidenceParent)
  {
    var parent = Path.GetFullPath(allowedParent).TrimEnd(Path.DirectorySeparatorChar);
    var full = Path.GetFullPath(path);
    var directory = Path.GetDirectoryName(full)!;
    if (Path.GetFileName(full) != "probe.private.json" ||
        !directory.StartsWith(parent + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) ||
        !Guid.TryParseExact(Path.GetRelativePath(parent, directory), "D", out var uid))
      throw new PreflightException("resource_probe_plan_path_invalid");
    var fileLength = new FileInfo(full).Length;
    if (fileLength is < 1 or > 16384) throw new PreflightException("resource_probe_plan_size_invalid");
    using var file = new SealedResourceFile(full, fileLength, sha256);
    var plan = JsonSerializer.Deserialize<Plan>(file.ReadRange(0, checked((int)file.Length)), JsonOptions)
        ?? throw new PreflightException("resource_probe_plan_invalid");
    if (plan.ContractId != "nll/resource-route-probe-plan/v1" || plan.AssessmentUid != uid.ToString("D") ||
        plan.DurationSeconds is < 15 or > 300 || plan.MaximumRequests is < 1 or > 64 ||
        string.IsNullOrEmpty(plan.ExpectedHost) || string.IsNullOrEmpty(plan.MetadataRequestPath) ||
        string.IsNullOrEmpty(plan.MetadataSha256) || string.IsNullOrEmpty(plan.CertificateSha256) ||
        plan.MetadataByteLength is < 1 or > 65536 || plan.CertificateByteLength is < 1 or > 65536 ||
        plan.CertificateFile != Path.Combine(directory, "server.pfx") ||
        plan.MetadataFile != Path.Combine(directory, "version-metadata.txt"))
      throw new PreflightException("resource_probe_plan_invalid");
    return plan;
  }

  internal static async Task<object> RunAsync(string planPath, string planSha256, bool start)
  {
    var plan = ReadPlan(planPath, planSha256);
    using var metadata = new SealedResourceFile(plan.MetadataFile, plan.MetadataByteLength, plan.MetadataSha256);
    using var certificateFile = new SealedResourceFile(plan.CertificateFile, plan.CertificateByteLength, plan.CertificateSha256);
    using var certificate = LoadCertificate(certificateFile);
    ValidateCertificate(certificate, plan.ExpectedHost);
    var metadataBytes = metadata.ReadRange(0, checked((int)metadata.Length));
    // Validate the endpoint contract even in inspection-only mode.
    _ = new ResourceRouteProbe(plan.ExpectedHost, plan.MetadataRequestPath, metadataBytes,
        plan.MetadataSha256, _ => false, plan.MaximumRequests, port: 8443);
    if (!start) return new
    {
      contractId = plan.ContractId,
      status = "probe_inputs_verified_not_started",
      nativeAdmission = "not_evaluated",
      serverStarted = false,
      clientStarted = false
    };

    var directory = Path.GetDirectoryName(Path.GetFullPath(planPath))!;
    using var log = new PrivateRouteProbeLog(directory, EvidenceParent);
    var endpoint = new ResourceRouteProbe(plan.ExpectedHost, plan.MetadataRequestPath, metadataBytes,
        plan.MetadataSha256, log.TryRecord, plan.MaximumRequests, port: 8443);
    await using var app = CreateApplication(directory, certificate, endpoint.HandleAsync);
    using var duration = new CancellationTokenSource(TimeSpan.FromSeconds(plan.DurationSeconds));
    try
    {
      await app.StartAsync(duration.Token);
      await Task.Delay(Timeout.InfiniteTimeSpan, duration.Token);
    }
    catch (OperationCanceledException) when (duration.IsCancellationRequested) { }
    finally
    {
      using var shutdown = new CancellationTokenSource(TimeSpan.FromSeconds(5));
      await app.StopAsync(shutdown.Token);
    }
    return log.Summary();
  }

  internal static void ValidateCertificate(X509Certificate2 certificate, string hostname)
  {
    if (!certificate.HasPrivateKey || DateTime.UtcNow < certificate.NotBefore.ToUniversalTime() ||
        DateTime.UtcNow >= certificate.NotAfter.ToUniversalTime() ||
        !certificate.MatchesHostname(hostname, allowWildcards: true, allowCommonName: false))
      throw new PreflightException("resource_probe_certificate_invalid");
  }

  // Port 0 is available only to in-process synthetic tests; the CLI always uses 8443.
  internal static WebApplication CreateApplication(string directory, X509Certificate2 certificate,
      RequestDelegate handler, int port = 8443)
  {
    if (port is not (0 or 8443)) throw new PreflightException("resource_probe_port_invalid");
    var builder = WebApplication.CreateSlimBuilder(new WebApplicationOptions
    {
      Args = [],
      ContentRootPath = directory,
      ApplicationName = typeof(ResourceRouteProbeHost).Assembly.FullName
    });
    // Do not inherit Kestrel endpoints/URLs from environment or appsettings.
    builder.Configuration.Sources.Clear();
    builder.Logging.ClearProviders();
    builder.WebHost.ConfigureKestrel(options =>
    {
      options.AddServerHeader = false;
      options.Limits.MaxRequestBodySize = 0;
      options.Limits.MaxRequestLineSize = 4096;
      options.Limits.RequestHeadersTimeout = TimeSpan.FromSeconds(10);
      options.Listen(IPAddress.Loopback, port, listen =>
      {
        listen.Protocols = HttpProtocols.Http1AndHttp2;
        listen.UseHttps(certificate);
      });
    });
    var app = builder.Build();
    app.Run(handler);
    return app;
  }

  private static X509Certificate2 LoadCertificate(SealedResourceFile file)
  {
    var bytes = file.ReadRange(0, checked((int)file.Length));
    // Windows Schannel requires an accessible key container. Do not persist the
    // imported key or add a certificate to a trust store; Dispose releases it.
    try { return X509CertificateLoader.LoadPkcs12(bytes, "", X509KeyStorageFlags.DefaultKeySet); }
    finally { CryptographicOperations.ZeroMemory(bytes); }
  }
}
