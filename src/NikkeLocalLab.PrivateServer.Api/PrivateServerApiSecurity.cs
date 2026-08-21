using System.Buffers;
using System.Net;
using System.Security.Cryptography;
using System.Text.Json;
using NikkeLocalLab.Application.PrivateServer;
using NikkeLocalLab.Identity;

namespace NikkeLocalLab.PrivateServer.Api;

internal static class PrivateServerApiSecurity
{
  public const string ApiPrefix = "/lab-api";

  public const string ContentSecurityPolicy =
      "default-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'";

  public static bool IsUnsafeMethod(string method) =>
      !HttpMethods.IsGet(method) &&
      !HttpMethods.IsHead(method) &&
      !HttpMethods.IsOptions(method) &&
      !HttpMethods.IsTrace(method);

  public static void ApplySecurityHeaders(IHeaderDictionary headers)
  {
    headers.ContentSecurityPolicy = ContentSecurityPolicy;
    headers.XContentTypeOptions = "nosniff";
    headers.XFrameOptions = "DENY";
    headers.CacheControl = "no-cache, no-store";
    headers.Pragma = "no-cache";
    headers["Referrer-Policy"] = "no-referrer";
    headers["Cross-Origin-Opener-Policy"] = "same-origin";
    headers["Cross-Origin-Resource-Policy"] = "same-origin";
    headers["Permissions-Policy"] =
        "camera=(), microphone=(), geolocation=(), payment=(), usb=()";
  }
}

internal sealed class LoopbackPrivateServerGuardMiddleware
{
  private readonly RequestDelegate _next;

  public LoopbackPrivateServerGuardMiddleware(RequestDelegate next)
  {
    _next = next;
  }

  public async Task InvokeAsync(HttpContext context)
  {
    var remoteAddress = context.Connection.RemoteIpAddress;
    var localAddress = context.Connection.LocalIpAddress;
    if (remoteAddress is null || localAddress is null ||
        !IPAddress.IsLoopback(remoteAddress) || !IPAddress.IsLoopback(localAddress))
    {
      throw new PrivateServerApiRequestException(
          StatusCodes.Status403Forbidden,
          "loopback_required");
    }

    var host = context.Request.Host;
    if (!string.Equals(host.Host, IPAddress.Loopback.ToString(), StringComparison.Ordinal) ||
        host.Port != context.Connection.LocalPort)
    {
      throw new PrivateServerApiRequestException(
          StatusCodes.Status403Forbidden,
          "host_rejected");
    }

    var isApiRequest = context.Request.Path.StartsWithSegments(
        PrivateServerApiSecurity.ApiPrefix,
        StringComparison.Ordinal);
    var isUnsafeApiRequest = isApiRequest &&
        PrivateServerApiSecurity.IsUnsafeMethod(context.Request.Method);
    if (isUnsafeApiRequest && !context.Request.HasJsonContentType())
    {
      throw new PrivateServerApiRequestException(
          StatusCodes.Status415UnsupportedMediaType,
          "json_content_type_required");
    }

    var hasOrigin = context.Request.Headers.TryGetValue("Origin", out var origins);
    if (isUnsafeApiRequest || hasOrigin)
    {
      var expectedOrigin = $"http://{IPAddress.Loopback}:{context.Connection.LocalPort}";
      if (!hasOrigin || origins.Count != 1 ||
          !string.Equals(origins[0], expectedOrigin, StringComparison.Ordinal))
      {
        throw new PrivateServerApiRequestException(
            StatusCodes.Status403Forbidden,
            "origin_rejected");
      }
    }

    await _next(context).ConfigureAwait(false);
  }
}

internal sealed class PrivateServerSessionGuardMiddleware
{
  private readonly RequestDelegate _next;
  private readonly TimeProvider _timeProvider;

  public PrivateServerSessionGuardMiddleware(
      RequestDelegate next,
      TimeProvider timeProvider)
  {
    _next = next;
    _timeProvider = timeProvider;
  }

  public async Task InvokeAsync(
      HttpContext context,
      PrivateServerSessionTokenProtector tokenProtector,
      IPrivateServerService privateServerService)
  {
    if (!context.Request.Path.StartsWithSegments(
            PrivateServerApiSecurity.ApiPrefix,
            StringComparison.Ordinal) ||
        PrivateServerApiRoutes.IsAnonymous(context.Request))
    {
      await _next(context).ConfigureAwait(false);
      return;
    }

    if (!PrivateServerApiRoutes.TryGetPathSessionUid(
            context.Request.Path,
            out var pathSessionUid))
    {
      throw new PrivateServerApiRequestException(
          StatusCodes.Status401Unauthorized,
          "local_session_access_required");
    }

    var authorization = context.Request.Headers.Authorization;
    if (authorization.Count != 1 ||
        !tokenProtector.TryValidate(
            authorization[0],
            _timeProvider.GetUtcNow(),
            out var authenticatedSessionUid))
    {
      throw new PrivateServerApiRequestException(
          StatusCodes.Status401Unauthorized,
          "local_session_access_required");
    }

    if (pathSessionUid != authenticatedSessionUid)
    {
      throw new PrivateServerApiRequestException(
          StatusCodes.Status403Forbidden,
          "local_session_scope_rejected");
    }

    await privateServerService.ValidateSessionAccessAsync(
        new ValidateLocalSessionAccessQuery(
            authenticatedSessionUid,
            NormalizeServerTime(_timeProvider.GetUtcNow())),
        context.RequestAborted).ConfigureAwait(false);

    context.Items[PrivateServerApiRoutes.AuthenticatedSessionItem] = authenticatedSessionUid;
    await _next(context).ConfigureAwait(false);
  }

  private static DateTimeOffset NormalizeServerTime(DateTimeOffset value)
  {
    var utc = value.ToUniversalTime();
    var normalizedTicks = utc.Ticks - (utc.Ticks % 10);
    return new DateTimeOffset(normalizedTicks, TimeSpan.Zero);
  }
}

internal sealed class PrivateServerSecurityHeadersMiddleware
{
  private readonly RequestDelegate _next;

  public PrivateServerSecurityHeadersMiddleware(RequestDelegate next)
  {
    _next = next;
  }

  public async Task InvokeAsync(HttpContext context)
  {
    PrivateServerApiSecurity.ApplySecurityHeaders(context.Response.Headers);
    await _next(context).ConfigureAwait(false);
  }
}

internal sealed class StrictPrivateServerJsonMiddleware
{
  private readonly RequestDelegate _next;
  private readonly int _maximumBodyBytes;

  public StrictPrivateServerJsonMiddleware(RequestDelegate next, long maximumBodyBytes)
  {
    _next = next;
    _maximumBodyBytes = checked((int)maximumBodyBytes);
  }

  public async Task InvokeAsync(HttpContext context)
  {
    var isProtectedJsonBody =
        context.Request.Path.StartsWithSegments(
            PrivateServerApiSecurity.ApiPrefix,
            StringComparison.Ordinal) &&
        PrivateServerApiSecurity.IsUnsafeMethod(context.Request.Method) &&
        context.Request.HasJsonContentType();
    if (!isProtectedJsonBody)
    {
      await _next(context).ConfigureAwait(false);
      return;
    }

    if (context.Request.ContentLength > _maximumBodyBytes)
    {
      throw new PrivateServerApiRequestException(
          StatusCodes.Status413PayloadTooLarge,
          "request_body_too_large");
    }

    var rented = ArrayPool<byte>.Shared.Rent(_maximumBodyBytes + 1);
    var originalBody = context.Request.Body;
    try
    {
      var length = 0;
      while (true)
      {
        var read = await originalBody.ReadAsync(
            rented.AsMemory(length, _maximumBodyBytes + 1 - length),
            context.RequestAborted).ConfigureAwait(false);
        if (read == 0)
        {
          break;
        }

        length += read;
        if (length > _maximumBodyBytes)
        {
          throw new PrivateServerApiRequestException(
              StatusCodes.Status413PayloadTooLarge,
              "request_body_too_large");
        }
      }

      ValidateUniqueProperties(rented.AsSpan(0, length));
      context.Request.Body = new MemoryStream(
          rented,
          0,
          length,
          writable: false,
          publiclyVisible: false);
      await _next(context).ConfigureAwait(false);
    }
    finally
    {
      context.Request.Body.Dispose();
      context.Request.Body = originalBody;
      CryptographicOperations.ZeroMemory(rented);
      ArrayPool<byte>.Shared.Return(rented);
    }
  }

  private static void ValidateUniqueProperties(ReadOnlySpan<byte> json)
  {
    var reader = new Utf8JsonReader(
        json,
        new JsonReaderOptions
        {
          AllowTrailingCommas = false,
          CommentHandling = JsonCommentHandling.Disallow,
          MaxDepth = 32
        });
    var objects = new Stack<HashSet<string>>();
    while (reader.Read())
    {
      switch (reader.TokenType)
      {
        case JsonTokenType.StartObject:
          objects.Push(new HashSet<string>(StringComparer.Ordinal));
          break;
        case JsonTokenType.EndObject:
          if (objects.Count == 0)
          {
            throw new JsonException();
          }

          objects.Pop();
          break;
        case JsonTokenType.PropertyName:
          if (objects.Count == 0 || !objects.Peek().Add(reader.GetString() ?? string.Empty))
          {
            throw new PrivateServerApiRequestException(
                StatusCodes.Status400BadRequest,
                "request_json_duplicate_property");
          }

          break;
      }
    }

    if (objects.Count != 0)
    {
      throw new JsonException();
    }
  }
}

internal static class PrivateServerApiRoutes
{
  public const string AuthenticatedSessionItem = "nll.authenticated-session";

  public static bool IsAnonymous(HttpRequest request) =>
      (HttpMethods.IsGet(request.Method) &&
          request.Path.Equals("/lab-api/v1/boot", StringComparison.Ordinal)) ||
      (HttpMethods.IsPost(request.Method) &&
          request.Path.Equals("/lab-api/v1/sessions/open", StringComparison.Ordinal));

  public static bool TryGetPathSessionUid(
      PathString path,
      out EntityUid sessionUid)
  {
    sessionUid = default;
    var value = path.Value;
    if (value is null)
    {
      return false;
    }

    var segments = value.Split('/', StringSplitOptions.None);
    return segments.Length >= 5 &&
        string.Equals(segments[1], "lab-api", StringComparison.Ordinal) &&
        string.Equals(segments[2], "v1", StringComparison.Ordinal) &&
        string.Equals(segments[3], "sessions", StringComparison.Ordinal) &&
        Guid.TryParseExact(segments[4], "D", out var guid) &&
        guid != Guid.Empty &&
        (sessionUid = new EntityUid(guid)).Value != Guid.Empty;
  }
}
