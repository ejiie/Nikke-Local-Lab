using System.Net;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Extensions.DependencyInjection.Extensions;
using NikkeLocalLab.Application.PrivateServer;

namespace NikkeLocalLab.PrivateServer.Api;

public sealed record PrivateServerApiHostOptions
{
  public int Port { get; init; } = 17879;

  public long MaximumRequestBodyBytes { get; init; } = 262_144;

  public TimeSpan LocalSessionLifetime { get; init; } = TimeSpan.FromMinutes(30);

  public Action<IServiceCollection>? ConfigureServices { get; init; }

  public TimeProvider? TimeProvider { get; init; }

  public bool AllowMissingPrivateServerServiceForTests { get; init; }
}

public static class PrivateServerApiHost
{
  public static WebApplication Build(
      string[]? args = null,
      PrivateServerApiHostOptions? options = null)
  {
    if (args is { Length: > 0 })
    {
      throw new InvalidOperationException("private_server_host_arguments_not_supported");
    }

    options ??= new PrivateServerApiHostOptions();
    if (options.Port is < 0 or > 65535 ||
        options.MaximumRequestBodyBytes is < 1 or > 1_048_576 ||
        options.LocalSessionLifetime < TimeSpan.FromMinutes(1) ||
        options.LocalSessionLifetime > TimeSpan.FromHours(24))
    {
      throw new ArgumentOutOfRangeException(nameof(options));
    }

    var applicationDirectory = AppContext.BaseDirectory;
    var builder = WebApplication.CreateBuilder(new WebApplicationOptions
    {
      Args = ["--preventHostingStartup=true"],
      ApplicationName = typeof(PrivateServerApiHost).Assembly.GetName().Name,
      ContentRootPath = applicationDirectory,
      EnvironmentName = Environments.Production
    });
    builder.Configuration.Sources.Clear();
    builder.Configuration.AddInMemoryCollection();
    builder.Logging.ClearProviders();
    builder.Logging.AddSimpleConsole(console =>
    {
      console.SingleLine = true;
      console.TimestampFormat = "yyyy-MM-ddTHH:mm:ss.fffZ ";
      console.UseUtcTimestamp = true;
    });
    builder.Logging.SetMinimumLevel(LogLevel.Warning);
    builder.WebHost.ConfigureKestrel(server =>
    {
      server.Listen(IPAddress.Loopback, options.Port);
      server.Limits.MaxRequestBodySize = options.MaximumRequestBodyBytes;
      server.AllowSynchronousIO = false;
      server.AddServerHeader = false;
    });

    builder.Services.ConfigureHttpJsonOptions(json =>
    {
      json.SerializerOptions.PropertyNamingPolicy = JsonNamingPolicy.CamelCase;
      json.SerializerOptions.PropertyNameCaseInsensitive = false;
      json.SerializerOptions.UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow;
      json.SerializerOptions.NumberHandling = JsonNumberHandling.Strict;
      json.SerializerOptions.MaxDepth = 32;
      json.SerializerOptions.Converters.Add(new EntityUidJsonConverter());
      json.SerializerOptions.Converters.Add(new Sha256DigestJsonConverter());
    });
    builder.Services.AddSingleton(options);
    builder.Services.AddSingleton(options.TimeProvider ?? TimeProvider.System);
    builder.Services.TryAddSingleton<PrivateServerSessionTokenProtector>();
    options.ConfigureServices?.Invoke(builder.Services);
    var hasPrivateServerService = builder.Services.Any(
        static descriptor => descriptor.ServiceType == typeof(IPrivateServerService));
    if (!hasPrivateServerService && !options.AllowMissingPrivateServerServiceForTests)
    {
      throw new InvalidOperationException("private_server_composition_missing");
    }

    var app = builder.Build();
    app.UseMiddleware<SafePrivateServerApiExceptionMiddleware>();
    app.UseMiddleware<PrivateServerSecurityHeadersMiddleware>();
    app.UseMiddleware<LoopbackPrivateServerGuardMiddleware>();
    app.UseMiddleware<PrivateServerSessionGuardMiddleware>();
    app.UseMiddleware<StrictPrivateServerJsonMiddleware>(options.MaximumRequestBodyBytes);
    app.UseStatusCodePages(async statusContext =>
    {
      var context = statusContext.HttpContext;
      if (!context.Request.Path.StartsWithSegments(
              PrivateServerApiSecurity.ApiPrefix,
              StringComparison.Ordinal))
      {
        return;
      }

      var code = context.Response.StatusCode switch
      {
        StatusCodes.Status400BadRequest => "request_json_invalid",
        StatusCodes.Status404NotFound => "lab_route_not_found",
        StatusCodes.Status405MethodNotAllowed => "method_not_allowed",
        StatusCodes.Status413PayloadTooLarge => "request_body_too_large",
        StatusCodes.Status415UnsupportedMediaType => "json_content_type_required",
        _ => "request_failed"
      };
      PrivateServerApiSecurity.ApplySecurityHeaders(context.Response.Headers);
      context.Response.ContentType = "application/problem+json";
      await context.Response.WriteAsync(
          JsonSerializer.Serialize(new { code, traceId = context.TraceIdentifier }),
          context.RequestAborted).ConfigureAwait(false);
    });
    app.MapPrivateServerApiEndpoints();
    return app;
  }
}
