using NikkeLocalLab.Persistence.PostgreSql;

namespace NikkeLocalLab.Admin.Api;

public static class AccountDirectoryEndpoints
{
  public static IEndpointRouteBuilder MapAccountDirectoryEndpoints(this IEndpointRouteBuilder endpoints)
  {
    endpoints.MapGet("/admin-api/v1/unions", async (IServiceProvider services, CancellationToken token) =>
    {
      var unions = await Require(services).ListAsync(token).ConfigureAwait(false);
      if (services.GetService<AccountFrameArtwork>() is { } artwork)
        unions = await artwork.ApplyAsync(unions, token).ConfigureAwait(false);
      return Results.Json(unions);
    });
    endpoints.MapPost("/admin-api/v1/accounts/create", async (CreateDirectoryAccountCommand request,
        IServiceProvider services, CancellationToken token) =>
    {
      var uid = await Require(services).CreateAsync(request, token).ConfigureAwait(false);
      return Results.Json(new { AccountUid = uid }, statusCode: StatusCodes.Status201Created);
    });
    return endpoints;
  }

  private static AccountDirectoryStore Require(IServiceProvider services) =>
      services.GetService<AccountDirectoryStore>() ??
      throw new ApiRequestException(StatusCodes.Status503ServiceUnavailable, "account_directory_unavailable");
}
