using System.Text.Json;
using NikkeLocalLab.Application.PrivateServer;

namespace NikkeLocalLab.PrivateServer.Api;

internal sealed class PrivateServerApiRequestException : Exception
{
  public PrivateServerApiRequestException(int statusCode, string code)
      : base(code)
  {
    StatusCode = statusCode;
    Code = code;
  }

  public int StatusCode { get; }

  public string Code { get; }
}

internal sealed class SafePrivateServerApiExceptionMiddleware
{
  private readonly RequestDelegate _next;
  private readonly ILogger<SafePrivateServerApiExceptionMiddleware> _logger;

  public SafePrivateServerApiExceptionMiddleware(
      RequestDelegate next,
      ILogger<SafePrivateServerApiExceptionMiddleware> logger)
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
      _logger.LogWarning("Private-server API request failed with controlled code {Code}.", code);
      if (context.Response.HasStarted)
      {
        context.Abort();
        return;
      }

      context.Response.Clear();
      PrivateServerApiSecurity.ApplySecurityHeaders(context.Response.Headers);
      context.Response.StatusCode = statusCode;
      context.Response.ContentType = "application/problem+json";
      await context.Response.WriteAsJsonAsync(
          new PrivateServerApiErrorResponse(code, context.TraceIdentifier),
          context.RequestAborted).ConfigureAwait(false);
    }
  }

  private static (int StatusCode, string Code) Map(Exception exception) => exception switch
  {
    PrivateServerApiRequestException request => (request.StatusCode, request.Code),
    PrivateServerApplicationException application => application.Kind switch
    {
      PrivateServerFailureKind.InvalidRequest =>
          (StatusCodes.Status400BadRequest, application.Code),
      PrivateServerFailureKind.NotFound =>
          (StatusCodes.Status404NotFound, application.Code),
      PrivateServerFailureKind.Conflict =>
          (StatusCodes.Status409Conflict, application.Code),
      PrivateServerFailureKind.Forbidden =>
          (StatusCodes.Status403Forbidden, application.Code),
      PrivateServerFailureKind.PolicyUnresolved =>
          (StatusCodes.Status422UnprocessableEntity, application.Code),
      PrivateServerFailureKind.Unsupported =>
          (StatusCodes.Status501NotImplemented, application.Code),
      PrivateServerFailureKind.Unavailable =>
          (StatusCodes.Status503ServiceUnavailable, application.Code),
      _ => (StatusCodes.Status500InternalServerError, "internal_error")
    },
    BadHttpRequestException badRequest => badRequest.StatusCode switch
    {
      StatusCodes.Status413PayloadTooLarge =>
          (StatusCodes.Status413PayloadTooLarge, "request_body_too_large"),
      StatusCodes.Status415UnsupportedMediaType =>
          (StatusCodes.Status415UnsupportedMediaType, "json_content_type_required"),
      >= 400 and <= 499 => (badRequest.StatusCode, "request_invalid"),
      _ => (StatusCodes.Status400BadRequest, "request_invalid")
    },
    JsonException => (StatusCodes.Status400BadRequest, "request_json_invalid"),
    FormatException => (StatusCodes.Status400BadRequest, "request_value_invalid"),
    ArgumentException => (StatusCodes.Status400BadRequest, "request_value_invalid"),
    _ => (StatusCodes.Status500InternalServerError, "internal_error")
  };
}

internal sealed record PrivateServerApiErrorResponse(string Code, string TraceId);
