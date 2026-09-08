using System.Globalization;
using System.Net;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.Features;

namespace ResourceCatalogPreflight;

// No production route registration exists yet. An external, audited manifest
// must supply exact native paths after version/route evidence has been verified.
internal sealed class LocalPatchEndpoint
{
  internal sealed record Resource(long ByteLength, bool RangeRequired, Func<long, int, byte[]> ReadRange);
  private readonly IReadOnlyDictionary<string, Resource> resources;
  private readonly string host;

  internal LocalPatchEndpoint(string expectedHost, IReadOnlyDictionary<string, Resource> exactResources)
  {
    if (!Regex.IsMatch(expectedHost, "\\A[a-z0-9.-]+\\z") || expectedHost.Contains("..", StringComparison.Ordinal))
      throw new PreflightException("resource_transport_host_invalid");
    var copy = new Dictionary<string, Resource>(StringComparer.Ordinal);
    foreach (var pair in exactResources)
    {
      if (!CanonicalPath(pair.Key) || pair.Value.ByteLength <= 0 || pair.Value.ReadRange is null)
        throw new PreflightException("resource_transport_manifest_invalid");
      copy.Add(pair.Key, pair.Value);
    }
    host = expectedHost;
    resources = copy;
  }

  internal async Task HandleAsync(HttpContext context)
  {
    var request = context.Request;
    var response = context.Response;
    // Defense in depth; this does not replace an exact loopback server bind.
    if (!IPAddress.Loopback.Equals(context.Connection.LocalIpAddress) ||
        !IPAddress.Loopback.Equals(context.Connection.RemoteIpAddress) ||
        !string.Equals(request.Host.Host, host, StringComparison.OrdinalIgnoreCase) ||
        request.Headers.ContainsKey("Authorization") || request.Headers.ContainsKey("Cookie"))
    {
      response.StatusCode = StatusCodes.Status403Forbidden;
      return;
    }
    if (request.Method is not ("GET" or "HEAD"))
    {
      response.StatusCode = StatusCodes.Status405MethodNotAllowed;
      response.Headers.Allow = "GET, HEAD";
      return;
    }
    var path = request.Path.Value ?? "";
    var rawTarget = context.Features.Get<IHttpRequestFeature>()?.RawTarget;
    if (request.QueryString.HasValue || request.PathBase.HasValue || !CanonicalPath(path) ||
        (!string.IsNullOrEmpty(rawTarget) && rawTarget != path))
    {
      response.StatusCode = StatusCodes.Status400BadRequest;
      return;
    }
    if (!resources.TryGetValue(path, out var resource))
    {
      response.StatusCode = StatusCodes.Status404NotFound;
      return;
    }

    long start = 0, length = resource.ByteLength;
    var partial = false;
    // Conditional requests are not interpreted until the native validator/ETag
    // contract is observed. Never silently ignore If-Range and send wrong bytes.
    if (new[] { "If-Range", "If-None-Match", "If-Match", "If-Modified-Since", "If-Unmodified-Since" }
        .Any(request.Headers.ContainsKey))
    {
      response.StatusCode = StatusCodes.Status412PreconditionFailed;
      return;
    }
    if (request.Headers.TryGetValue("Range", out var ranges))
    {
      if (ranges.Count != 1 || !TryRange(ranges[0]!, resource.ByteLength, out start, out length))
      {
        response.StatusCode = StatusCodes.Status416RangeNotSatisfiable;
        response.Headers.ContentRange = "bytes */" + resource.ByteLength.ToString(CultureInfo.InvariantCulture);
        return;
      }
      partial = true;
    }
    else if (resource.RangeRequired && request.Method != "HEAD")
    {
      response.StatusCode = StatusCodes.Status416RangeNotSatisfiable;
      return;
    }

    // Raw/catalog GETs are streamed in bounded blocks. Pak ranges are bounded
    // and fully verified before committing a success status or any payload bytes.
    byte[]? verifiedPak = null;
    try
    {
      if (resource.RangeRequired && request.Method != "HEAD")
      {
        if (length > VirtualPakReader.MaximumRangeBytes)
        {
          response.StatusCode = StatusCodes.Status416RangeNotSatisfiable;
          return;
        }
        context.RequestAborted.ThrowIfCancellationRequested();
        verifiedPak = resource.ReadRange(start, checked((int)length));
        if (verifiedPak.LongLength != length) throw new PreflightException("resource_response_length_mismatch");
      }
      response.StatusCode = partial ? StatusCodes.Status206PartialContent : StatusCodes.Status200OK;
      response.ContentType = "application/octet-stream";
      response.ContentLength = length;
      response.Headers.AcceptRanges = "bytes";
      response.Headers.CacheControl = "no-store";
      if (partial) response.Headers.ContentRange = FormattableString.Invariant($"bytes {start}-{start + length - 1}/{resource.ByteLength}");
      if (request.Method == "HEAD") return;
      if (verifiedPak is not null)
      {
        await response.Body.WriteAsync(verifiedPak, context.RequestAborted);
        return;
      }
      for (long copied = 0; copied < length;)
      {
        context.RequestAborted.ThrowIfCancellationRequested();
        var count = (int)Math.Min(128 * 1024, length - copied);
        var bytes = resource.ReadRange(start + copied, count);
        try
        {
          if (bytes.Length != count) throw new PreflightException("resource_response_length_mismatch");
          await response.Body.WriteAsync(bytes, context.RequestAborted);
        }
        finally { CryptographicOperations.ZeroMemory(bytes); }
        copied += count;
      }
    }
    catch (Exception error) when (error is PreflightException or IOException)
    {
      if (response.HasStarted) context.Abort();
      else
      {
        response.Clear();
        response.StatusCode = StatusCodes.Status503ServiceUnavailable;
      }
    }
    finally { if (verifiedPak is not null) CryptographicOperations.ZeroMemory(verifiedPak); }
  }

  private static bool CanonicalPath(string path) => Regex.IsMatch(path, "\\A/[A-Za-z0-9_./-]+\\z") &&
      !path.Contains("//", StringComparison.Ordinal) && !path.Split('/').Any(part => part is "." or "..");

  private static bool TryRange(string value, long total, out long start, out long length)
  {
    start = length = 0;
    var match = Regex.Match(value, "\\Abytes=([0-9]+)-([0-9]+)\\z");
    if (!match.Success || !long.TryParse(match.Groups[1].Value, NumberStyles.None, CultureInfo.InvariantCulture, out start) ||
        !long.TryParse(match.Groups[2].Value, NumberStyles.None, CultureInfo.InvariantCulture, out var end) ||
        end < start || end >= total) return false;
    length = end - start + 1;
    return true;
  }
}
