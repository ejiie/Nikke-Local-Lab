using System.Globalization;
using System.Net;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.Features;
using NikkeLocalLab.Automation;

namespace ResourceCatalogPreflight;

// Diagnostic transport only. Never forwards a request or supplies a catalog,
// raw asset, pak, static pack or battle response. Its sink must remain private:
// original request paths are not source-free receipts and must not reach logs.
internal sealed class ResourceRouteProbe
{
  internal sealed record ByteRange(long? Start, long? End);
  internal sealed record Observation(string Method, string Path, string RangeShape,
      IReadOnlyList<ByteRange> Ranges, IReadOnlyList<string> ConditionalHeaders, int PlannedResponseStatus);

  private static readonly string[] ConditionalHeaders =
      ["If-Range", "If-Match", "If-None-Match", "If-Modified-Since", "If-Unmodified-Since"];
  private readonly string expectedHost;
  private readonly string metadataPath;
  private readonly byte[] metadata;
  private readonly Func<Observation, bool> recordPrivate;
  private readonly object gate = new();
  private readonly int maximumObservations;
  private readonly int expectedPort;
  private int observationCount;

  internal ResourceRouteProbe(string host, string exactMetadataPath, byte[] metadataBytes,
      string expectedMetadataSha256, Func<Observation, bool> privateSink, int maximumRequests = 64,
      int port = 443)
  {
    if (host.Length > 253 || !Regex.IsMatch(host, @"\A[a-z0-9.-]+\z") ||
        host.Contains("..", StringComparison.Ordinal) ||
        !CanonicalPath(exactMetadataPath) ||
        !Regex.IsMatch(exactMetadataPath, @"/pck/latest-[0-9]+[.]txt\z") ||
        metadataBytes.Length is < 1 or > 65536 ||
        !Regex.IsMatch(expectedMetadataSha256, @"\A[a-f0-9]{64}\z") ||
        maximumRequests is < 1 or > 256 || privateSink is null || port is not (443 or 8443))
      throw new PreflightException("resource_probe_manifest_invalid");
    metadata = metadataBytes.ToArray();
    if (Convert.ToHexString(SHA256.HashData(metadata)).ToLowerInvariant() != expectedMetadataSha256)
      throw new PreflightException("resource_probe_metadata_drift");
    // A known version-metadata envelope is the only body this probe can serve.
    // Parsing it does not bind its publisher/version to installed catalog bytes.
    _ = PatchVersionMetadata.Parse(metadata);
    expectedHost = host;
    metadataPath = exactMetadataPath;
    recordPrivate = privateSink;
    maximumObservations = maximumRequests;
    expectedPort = port;
  }

  internal int ObservationCount { get { lock (gate) return observationCount; } }

  internal async Task HandleAsync(HttpContext context)
  {
    var request = context.Request;
    var response = context.Response;
    response.Headers.CacheControl = "no-store";
    if (!IPAddress.Loopback.Equals(context.Connection.LocalIpAddress) ||
        !IPAddress.Loopback.Equals(context.Connection.RemoteIpAddress) ||
        !string.Equals(request.Host.Host, expectedHost, StringComparison.OrdinalIgnoreCase) ||
        (request.Host.Port ?? 443) != expectedPort ||
        request.Headers.ContainsKey("Authorization") || request.Headers.ContainsKey("Proxy-Authorization") ||
        request.Headers.ContainsKey("Cookie"))
    {
      response.StatusCode = StatusCodes.Status403Forbidden;
      return;
    }
    if (request.Method is not ("GET" or "HEAD"))
    {
      response.StatusCode = StatusCodes.Status405MethodNotAllowed;
      return;
    }
    var path = request.Path.Value ?? "";
    var rawTarget = context.Features.Get<IHttpRequestFeature>()?.RawTarget;
    if (!CanonicalPath(path) || request.QueryString.HasValue || request.PathBase.HasValue ||
        (!string.IsNullOrEmpty(rawTarget) && rawTarget != path))
    {
      response.StatusCode = StatusCodes.Status400BadRequest;
      return;
    }
    // Never read a body, including for unusual GET requests.
    if (request.ContentLength is > 0 || request.Headers.ContainsKey("Transfer-Encoding"))
    {
      response.StatusCode = StatusCodes.Status400BadRequest;
      return;
    }
    var (rangeShape, ranges) = ReadRangeShape(request);
    var conditionals = ConditionalHeaders.Where(request.Headers.ContainsKey).ToArray();
    var status = path == metadataPath
        ? conditionals.Length != 0 ? 412 : rangeShape != "absent" ? 416 : 200
        : 404;
    var observation = new Observation(request.Method, path, rangeShape, ranges, conditionals, status);
    bool recorded;
    lock (gate)
    {
      if (observationCount >= maximumObservations)
      {
        response.StatusCode = StatusCodes.Status503ServiceUnavailable;
        return;
      }
      try { recorded = recordPrivate(observation); }
      catch (Exception error) when (error is IOException or UnauthorizedAccessException)
      {
        recorded = false;
      }
      if (recorded) observationCount++;
    }
    if (!recorded)
    {
      response.StatusCode = StatusCodes.Status503ServiceUnavailable;
      return;
    }
    response.StatusCode = status;
    if (status != 200) return;
    response.ContentType = "text/plain; charset=utf-8";
    response.ContentLength = metadata.Length;
    if (request.Method == "GET")
      await response.Body.WriteAsync(metadata, context.RequestAborted);
  }

  private static bool CanonicalPath(string path) => path.Length is > 1 and <= 2048 &&
      Regex.IsMatch(path, @"\A/[A-Za-z0-9_./-]+\z") &&
      !path.Contains("//", StringComparison.Ordinal) &&
      !path.Split('/').Any(part => part is "." or "..");

  private static (string Shape, IReadOnlyList<ByteRange> Ranges) ReadRangeShape(HttpRequest request)
  {
    if (!request.Headers.TryGetValue("Range", out var values)) return ("absent", []);
    if (values.Count != 1 || values[0] is not { Length: > 0 and <= 512 } value ||
        !value.StartsWith("bytes=", StringComparison.Ordinal)) return ("unresolved", []);
    var members = value[6..].Split(',');
    if (members.Length is < 1 or > 8) return ("unresolved", []);
    var ranges = new List<ByteRange>();
    foreach (var member in members)
    {
      var match = Regex.Match(member.Trim(' '), @"\A([0-9]*)-([0-9]*)\z");
      if (!match.Success) return ("unresolved", []);
      var first = match.Groups[1].Value;
      var last = match.Groups[2].Value;
      if (first.Length == 0 && last.Length == 0) return ("unresolved", []);
      long? start = null, end = null;
      if (first.Length != 0)
      {
        if (!long.TryParse(first, NumberStyles.None, CultureInfo.InvariantCulture, out var number))
          return ("unresolved", []);
        start = number;
      }
      if (last.Length != 0)
      {
        if (!long.TryParse(last, NumberStyles.None, CultureInfo.InvariantCulture, out var number))
          return ("unresolved", []);
        end = number;
      }
      if ((start.HasValue && end.HasValue && start > end) || (!start.HasValue && end == 0))
        return ("unresolved", []);
      ranges.Add(new(start, end));
    }
    if (ranges.Count > 1) return ("multiple", ranges);
    return (ranges[0].Start is null ? "suffix" : ranges[0].End is null ? "open_ended" : "closed", ranges);
  }
}
