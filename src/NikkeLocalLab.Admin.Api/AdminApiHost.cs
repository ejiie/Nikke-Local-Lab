using System.Net;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.AspNetCore.Antiforgery;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using NikkeLocalLab.Application.PrivateServer;
using NikkeLocalLab.Application.ProfileManagement;

namespace NikkeLocalLab.Admin.Api;

public sealed record AdminApiHostOptions
{
  public int Port { get; init; } = 17878;

  // A complete source-free account registration carries the canonical account
  // snapshot, sanitized draft, and progression observation in one local admin
  // request. The current real capture is larger than 1 MiB, while remaining
  // comfortably inside the already-validated 4 MiB administrative ceiling.
  public long MaximumRequestBodyBytes { get; init; } = 4_194_304;

  public TimeSpan AdminSessionLifetime { get; init; } = TimeSpan.FromHours(12);

  public Action<string>? BootstrapCodeSink { get; init; }

  public Action<IServiceCollection>? ConfigureServices { get; init; }

  public bool AllowUnavailableProfileManagementForTests { get; init; }

  public bool RequirePrivateServerAdministration { get; init; }

  public bool RequirePhaseDExecution { get; init; }
}

public static class AdminApiHost
{
  public static WebApplication Build(
      string[]? args = null,
      AdminApiHostOptions? options = null)
  {
    if (args is { Length: > 0 })
    {
      throw new InvalidOperationException("admin_host_arguments_not_supported");
    }

    options ??= new AdminApiHostOptions();
    if (options.Port is < 0 or > 65535 || options.MaximumRequestBodyBytes is < 1 or > 4_194_304 ||
        options.AdminSessionLifetime < TimeSpan.FromMinutes(1) ||
        options.AdminSessionLifetime > TimeSpan.FromHours(24))
    {
      throw new ArgumentOutOfRangeException(nameof(options));
    }

    if (options.BootstrapCodeSink is null)
    {
      throw new InvalidOperationException("admin_bootstrap_delivery_missing");
    }

    var applicationDirectory = AppContext.BaseDirectory;
    var builder = WebApplication.CreateBuilder(new WebApplicationOptions
    {
      Args = ["--preventHostingStartup=true"],
      ApplicationName = typeof(AdminApiHost).Assembly.GetName().Name,
      ContentRootPath = applicationDirectory,
      WebRootPath = Path.Combine(applicationDirectory, "wwwroot"),
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
    builder.WebHost.UseStaticWebAssets();

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
    builder.Services.AddAntiforgery(antiforgery =>
    {
      antiforgery.HeaderName = AdminApiSecurity.AntiforgeryHeaderName;
      antiforgery.Cookie.Name = "nll_admin_csrf";
      antiforgery.Cookie.HttpOnly = true;
      antiforgery.Cookie.IsEssential = true;
      antiforgery.Cookie.Path = "/admin-api";
      antiforgery.Cookie.SameSite = SameSiteMode.Strict;
      antiforgery.Cookie.SecurePolicy = CookieSecurePolicy.None;
    });
    builder.Services.AddDataProtection().UseEphemeralDataProtectionProvider();
    builder.Services.AddSingleton(TimeProvider.System);
    builder.Services.AddSingleton<AdminAccessSessionManager>(services =>
        AdminAccessSessionManager.Create(
            services.GetRequiredService<TimeProvider>(),
            options.AdminSessionLifetime,
            options.BootstrapCodeSink));
    options.ConfigureServices?.Invoke(builder.Services);
    builder.Services.TryAddSingleton<IProfileManagementService, UnavailableProfileManagementService>();
    builder.Services.TryAddSingleton<IPrivateServerService, UnavailablePrivateServerService>();
    builder.Services.TryAddSingleton<IPhaseDExecutionService, UnavailablePhaseDExecutionService>();
    builder.Services.TryAddSingleton<IPhaseDPreparationService, UnavailablePhaseDPreparationService>();
    builder.Services.TryAddSingleton<IBossSeasonCatalogService, UnavailableBossSeasonCatalogService>();
    builder.Services.TryAddSingleton<IBossOnboardingService, UnavailableBossOnboardingService>();
    builder.Services.TryAddSingleton<IAccountImportService, UnavailableAccountImportService>();

    var app = builder.Build();
    if (!options.AllowUnavailableProfileManagementForTests &&
        app.Services.GetRequiredService<IProfileManagementService>() is UnavailableProfileManagementService)
    {
      throw new InvalidOperationException("profile_management_composition_missing");
    }

    if (options.RequirePrivateServerAdministration &&
        app.Services.GetRequiredService<IPrivateServerService>() is UnavailablePrivateServerService)
    {
      throw new InvalidOperationException("private_server_administration_composition_missing");
    }

    if (options.RequirePhaseDExecution &&
        app.Services.GetRequiredService<IPhaseDExecutionService>() is UnavailablePhaseDExecutionService)
    {
      throw new InvalidOperationException("phase_d_execution_composition_missing");
    }

    _ = app.Services.GetRequiredService<AdminAccessSessionManager>();

    app.UseMiddleware<SafeApiExceptionMiddleware>();
    app.UseMiddleware<SecurityHeadersMiddleware>();
    app.UseMiddleware<LoopbackAdminGuardMiddleware>();
    app.UseMiddleware<StrictJsonRequestMiddleware>(options.MaximumRequestBodyBytes);
    app.UseStatusCodePages(async statusContext =>
    {
      var context = statusContext.HttpContext;
      if (!context.Request.Path.StartsWithSegments("/admin-api", StringComparison.Ordinal) &&
          !context.Request.Path.StartsWithSegments("/admin-auth", StringComparison.Ordinal))
      {
        return;
      }

      var code = context.Response.StatusCode switch
      {
        StatusCodes.Status404NotFound => "admin_route_not_found",
        StatusCodes.Status405MethodNotAllowed => "method_not_allowed",
        StatusCodes.Status413PayloadTooLarge => "request_body_too_large",
        StatusCodes.Status415UnsupportedMediaType => "json_content_type_required",
        _ => "request_failed"
      };
      AdminApiSecurity.ApplySecurityHeaders(context.Response.Headers);
      context.Response.ContentType = "application/problem+json";
      await context.Response.WriteAsync(
          JsonSerializer.Serialize(new { code, traceId = context.TraceIdentifier }),
          context.RequestAborted).ConfigureAwait(false);
    });
    app.UseDefaultFiles();
    app.UseStaticFiles();

    app.MapGet("/", () => Results.Redirect("/editor/"));
    app.MapPost(
        "/admin-auth/v1/bootstrap",
        (AdminBootstrapRequest request, HttpContext context, AdminAccessSessionManager access) =>
        {
          if (!access.TryExchange(request.Code, out var session))
          {
            throw new ApiRequestException(StatusCodes.Status401Unauthorized, "admin_bootstrap_rejected");
          }

          context.Response.Cookies.Append(
              AdminAccessSessionManager.CookieName,
              session.Token,
              new CookieOptions
              {
                HttpOnly = true,
                IsEssential = true,
                SameSite = SameSiteMode.Strict,
                Secure = false,
                Path = "/admin-api",
                Expires = session.ExpiresAtUtc
              });
          return Results.NoContent();
        });
    app.MapGet("/admin-api/v1/security/csrf", (HttpContext context, IAntiforgery antiforgery) =>
    {
      var tokens = antiforgery.GetAndStoreTokens(context);
      if (string.IsNullOrEmpty(tokens.RequestToken))
      {
        throw new ApiRequestException(StatusCodes.Status503ServiceUnavailable, "csrf_token_unavailable");
      }

      return Results.Json(new { requestToken = tokens.RequestToken });
    });
    app.MapAdminApiEndpoints();
    app.MapPrivateServerPolicyAdminEndpoints();
    app.MapPrivateServerExecutionAdminEndpoints();
    app.MapPhaseDExecutionEndpoints();
    app.MapBossSeasonEndpoints();
    app.MapUnionRaidEndpoints();
    app.MapAccountImportEndpoints();
    app.MapAccountDirectoryEndpoints();
    app.MapRaidRecordEndpoints();
    app.MapAccountConnectionEndpoints();
    return app;
  }
}
