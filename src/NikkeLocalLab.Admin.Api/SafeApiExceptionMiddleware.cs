using System.Text.Json;
using NikkeLocalLab.Application.PrivateServer;
using NikkeLocalLab.Application.ProfileManagement;

namespace NikkeLocalLab.Admin.Api;

internal sealed class ApiRequestException : Exception
{
  public ApiRequestException(int statusCode, string code)
      : base(code)
  {
    StatusCode = statusCode;
    Code = code;
  }

  public int StatusCode { get; }

  public string Code { get; }
}

internal sealed class SafeApiExceptionMiddleware
{
  private readonly RequestDelegate _next;
  private readonly ILogger<SafeApiExceptionMiddleware> _logger;

  public SafeApiExceptionMiddleware(
      RequestDelegate next,
      ILogger<SafeApiExceptionMiddleware> logger)
  {
    _next = next;
    _logger = logger;
  }

  public async Task InvokeAsync(HttpContext context)
  {
    try
    {
      await _next(context).ConfigureAwait(false);
    }
    catch (OperationCanceledException) when (context.RequestAborted.IsCancellationRequested)
    {
      return;
    }
    catch (Exception exception)
    {
      var (statusCode, code) = Map(exception);
      _logger.LogWarning("Admin API request failed with controlled code {Code}.", code);
      if (context.Response.HasStarted)
      {
        context.Abort();
        return;
      }

      context.Response.Clear();
      AdminApiSecurity.ApplySecurityHeaders(context.Response.Headers);
      context.Response.StatusCode = statusCode;
      context.Response.ContentType = "application/problem+json";
      context.Response.Headers.CacheControl = "no-store";
      await context.Response.WriteAsJsonAsync(
          new ApiErrorResponse(code, context.TraceIdentifier),
          context.RequestAborted).ConfigureAwait(false);
    }
  }

  private static (int StatusCode, string Code) Map(Exception exception) => exception switch
  {
    ApiRequestException request => (request.StatusCode, request.Code),
    ProfileManagementException management => management.Kind switch
    {
      ProfileManagementFailureKind.InvalidRequest => (StatusCodes.Status400BadRequest, management.Code),
      ProfileManagementFailureKind.NotFound => (StatusCodes.Status404NotFound, management.Code),
      ProfileManagementFailureKind.Conflict => (StatusCodes.Status409Conflict, management.Code),
      ProfileManagementFailureKind.Unprocessable =>
          (StatusCodes.Status422UnprocessableEntity, management.Code),
      ProfileManagementFailureKind.Unavailable =>
          (StatusCodes.Status503ServiceUnavailable, management.Code),
      _ => (StatusCodes.Status500InternalServerError, "internal_error")
    },
    PrivateServerApplicationException privateServer => privateServer.Kind switch
    {
      PrivateServerFailureKind.InvalidRequest =>
          (StatusCodes.Status400BadRequest, privateServer.Code),
      PrivateServerFailureKind.NotFound =>
          (StatusCodes.Status404NotFound, privateServer.Code),
      PrivateServerFailureKind.Conflict =>
          (StatusCodes.Status409Conflict, privateServer.Code),
      PrivateServerFailureKind.Forbidden =>
          (StatusCodes.Status403Forbidden, privateServer.Code),
      PrivateServerFailureKind.PolicyUnresolved =>
          (StatusCodes.Status422UnprocessableEntity, privateServer.Code),
      PrivateServerFailureKind.Unsupported =>
          (StatusCodes.Status501NotImplemented, privateServer.Code),
      PrivateServerFailureKind.Unavailable =>
          (StatusCodes.Status503ServiceUnavailable, privateServer.Code),
      _ => (StatusCodes.Status500InternalServerError, "internal_error")
    },
    BadHttpRequestException badRequest =>
        (badRequest.StatusCode is >= 400 and <= 499 ? badRequest.StatusCode : 400, "request_invalid"),
    JsonException => (StatusCodes.Status400BadRequest, "request_json_invalid"),
    FormatException => (StatusCodes.Status400BadRequest, "request_value_invalid"),
    ArgumentException => (StatusCodes.Status400BadRequest, "request_value_invalid"),
    _ => (StatusCodes.Status500InternalServerError, "internal_error")
  };

  private sealed record ApiErrorResponse(string Code, string TraceId);
}
