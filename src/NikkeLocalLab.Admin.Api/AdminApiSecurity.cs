using System.Buffers;
using System.Net;
using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.AspNetCore.Antiforgery;

namespace NikkeLocalLab.Admin.Api;

internal static class AdminApiSecurity
{
  public const string AntiforgeryHeaderName = "X-NLL-CSRF";

  public const string ContentSecurityPolicy =
      "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; " +
      "img-src 'self'; font-src 'none'; object-src 'none'; base-uri 'none'; " +
      "form-action 'none'; frame-ancestors 'none'";

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
    headers["Referrer-Policy"] = "no-referrer";
    headers.CacheControl = "no-cache, no-store";
    headers.Pragma = "no-cache";
    headers["Cross-Origin-Opener-Policy"] = "same-origin";
    headers["Cross-Origin-Resource-Policy"] = "same-origin";
    headers["Permissions-Policy"] =
        "camera=(), microphone=(), geolocation=(), payment=(), usb=()";
  }
}

internal sealed class LoopbackAdminGuardMiddleware
{
  private readonly RequestDelegate _next;

  public LoopbackAdminGuardMiddleware(RequestDelegate next)
  {
    _next = next;
  }

  public async Task InvokeAsync(
      HttpContext context,
      IAntiforgery antiforgery,
      AdminAccessSessionManager adminAccess)
  {
    var remoteAddress = context.Connection.RemoteIpAddress;
    var localAddress = context.Connection.LocalIpAddress;
    if (remoteAddress is null || localAddress is null ||
        !IPAddress.IsLoopback(remoteAddress) || !IPAddress.IsLoopback(localAddress))
    {
      throw new ApiRequestException(StatusCodes.Status403Forbidden, "loopback_required");
    }

    var host = context.Request.Host;
    if (!string.Equals(host.Host, IPAddress.Loopback.ToString(), StringComparison.Ordinal) ||
        host.Port != context.Connection.LocalPort)
    {
      throw new ApiRequestException(StatusCodes.Status403Forbidden, "host_rejected");
    }

    var isAdminApi = context.Request.Path.StartsWithSegments(
        "/admin-api",
        StringComparison.Ordinal);
    var isBootstrap = context.Request.Path.Equals(
        "/admin-auth/v1/bootstrap",
        StringComparison.Ordinal);
    var isUnsafe = AdminApiSecurity.IsUnsafeMethod(context.Request.Method);
    if ((isAdminApi || isBootstrap) && isUnsafe)
    {
      if (!context.Request.HasJsonContentType())
      {
        throw new ApiRequestException(
            StatusCodes.Status415UnsupportedMediaType,
            "json_content_type_required");
      }

      var expectedOrigin = $"http://{IPAddress.Loopback}:{context.Connection.LocalPort}";
      if (!context.Request.Headers.TryGetValue("Origin", out var origins) ||
          origins.Count != 1 ||
          !string.Equals(origins[0], expectedOrigin, StringComparison.Ordinal))
      {
        throw new ApiRequestException(StatusCodes.Status403Forbidden, "origin_rejected");
      }

    }

    if (isAdminApi)
    {
      if (!context.Request.Cookies.TryGetValue(
              AdminAccessSessionManager.CookieName,
              out var sessionToken) ||
          !adminAccess.TryRefreshSession(sessionToken, out var sessionExpiresAtUtc))
      {
        throw new ApiRequestException(StatusCodes.Status401Unauthorized, "admin_session_required");
      }

      context.Response.Cookies.Append(
          AdminAccessSessionManager.CookieName,
          sessionToken,
          new CookieOptions
          {
            HttpOnly = true,
            IsEssential = true,
            SameSite = SameSiteMode.Strict,
            Secure = false,
            Path = "/admin-api",
            Expires = sessionExpiresAtUtc
          });

      if (isUnsafe)
      {
        try
        {
          await antiforgery.ValidateRequestAsync(context).ConfigureAwait(false);
        }
        catch (AntiforgeryValidationException)
        {
          throw new ApiRequestException(StatusCodes.Status403Forbidden, "csrf_validation_failed");
        }
      }
    }

    await _next(context).ConfigureAwait(false);
  }
}

internal sealed class SecurityHeadersMiddleware
{
  private readonly RequestDelegate _next;

  public SecurityHeadersMiddleware(RequestDelegate next)
  {
    _next = next;
  }

  public async Task InvokeAsync(HttpContext context)
  {
    AdminApiSecurity.ApplySecurityHeaders(context.Response.Headers);
    await _next(context).ConfigureAwait(false);
  }
}

internal sealed class StrictJsonRequestMiddleware
{
  private readonly RequestDelegate _next;
  private readonly int _maximumBodyBytes;

  public StrictJsonRequestMiddleware(RequestDelegate next, long maximumBodyBytes)
  {
    _next = next;
    _maximumBodyBytes = checked((int)maximumBodyBytes);
  }

  public async Task InvokeAsync(HttpContext context)
  {
    var isProtectedJsonBody = AdminApiSecurity.IsUnsafeMethod(context.Request.Method) &&
        (context.Request.Path.StartsWithSegments("/admin-api", StringComparison.Ordinal) ||
         context.Request.Path.Equals("/admin-auth/v1/bootstrap", StringComparison.Ordinal)) &&
        context.Request.HasJsonContentType();
    if (!isProtectedJsonBody)
    {
      await _next(context).ConfigureAwait(false);
      return;
    }

    if (context.Request.ContentLength > _maximumBodyBytes)
    {
      throw new ApiRequestException(
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
          throw new ApiRequestException(
              StatusCodes.Status413PayloadTooLarge,
              "request_body_too_large");
        }
      }

      ValidateUniqueProperties(rented.AsSpan(0, length));
      context.Request.Body = new MemoryStream(rented, 0, length, writable: false, publiclyVisible: false);
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
            throw new ApiRequestException(
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
