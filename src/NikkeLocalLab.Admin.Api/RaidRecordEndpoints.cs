using NikkeLocalLab.Persistence.PostgreSql;

namespace NikkeLocalLab.Admin.Api;

public static class RaidRecordEndpoints
{
  public static IEndpointRouteBuilder MapRaidRecordEndpoints(this IEndpointRouteBuilder endpoints)
  {
    endpoints.MapGet("/admin-api/v1/accounts/{accountUid:guid}/raid-records/{battleUid:guid}/composition", async (
        Guid accountUid, Guid battleUid, IServiceProvider services, CancellationToken token) =>
    {
      var store = services.GetService<RaidCompositionStore>() ?? throw new ApiRequestException(503, "raid_analysis_unavailable");
      var result = await store.GetAsync(accountUid, battleUid, token).ConfigureAwait(false);
      return result is null ? Results.NotFound() : Results.Json(result);
    });
    endpoints.MapGet("/admin-api/v1/accounts/{accountUid:guid}/raid-records", async (
        Guid accountUid, int season, string kind, int step, string mode, string weakness, string? cursor,
        IServiceProvider services, CancellationToken token) =>
    {
      if (accountUid == Guid.Empty || season < 1 || kind is not ("solo" or "union") || step < 1 || step > 5 ||
              (kind == "solo" && step != 1) || mode is not ("practice" or "live") ||
              weakness is not ("all" or "unknown" or "fire" or "water" or "wind" or "electric" or "iron"))
        throw new ApiRequestException(400, "raid_record_scope_invalid");
      var store = services.GetService<RaidRecordStore>() ?? throw new ApiRequestException(503, "raid_records_unavailable");
      try { return Results.Json(await store.ListAsync(accountUid, season, kind, step, mode, weakness, cursor, token).ConfigureAwait(false)); }
      catch (ArgumentException) { throw new ApiRequestException(400, "raid_cursor_invalid"); }
    });
    return endpoints;
  }
}
