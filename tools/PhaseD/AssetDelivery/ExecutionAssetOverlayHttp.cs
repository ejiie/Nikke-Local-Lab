using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.Features;
using NikkeLocalLab.Automation;

namespace NikkeLocalLab.AssetDelivery;

/// <summary>Source-linked by the external adapter; never mounts a listener itself.</summary>
public sealed class ExecutionAssetOverlayHttp(ExecutionAssetOverlay overlay)
{
  public async Task<bool> TryHandleAsync(HttpContext context)
  {
    // Other asset types remain the existing adapter's responsibility. Check
    // bundles against RawTarget so percent decoding, queries and path cleanup
    // cannot turn an invalid request into an admitted route.
    var raw = context.Features.Get<IHttpRequestFeature>()?.RawTarget;
    if (!(context.Request.Path.Value?.EndsWith(".bundle", StringComparison.OrdinalIgnoreCase) == true ||
        raw?.Contains(".bundle", StringComparison.OrdinalIgnoreCase) == true))
      return false;
    if (!HttpMethods.IsGet(context.Request.Method) && !HttpMethods.IsHead(context.Request.Method))
    {
      context.Response.StatusCode = StatusCodes.Status405MethodNotAllowed;
      return true;
    }
    byte[]? bytes;
    try
    {
      bytes = overlay.GetResponse(raw ?? "");
    }
    catch (InvalidDataException)
    {
      context.Response.StatusCode = StatusCodes.Status409Conflict;
      return true; // Never fall through to an uncorrected cache on failure.
    }
    if (bytes is null)
      return false;
    // Avoid persisting derived bytes under an original HTTP validator. Unity's
    // native cache/catalog validation is a separate, still-unproved gate.
    context.Response.Headers.CacheControl = "no-store";
    await Results.Bytes(bytes, "application/octet-stream", enableRangeProcessing: true)
        .ExecuteAsync(context);
    return true;
  }
}
