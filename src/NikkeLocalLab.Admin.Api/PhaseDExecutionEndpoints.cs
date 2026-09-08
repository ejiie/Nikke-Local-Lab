using NikkeLocalLab.Identity;

namespace NikkeLocalLab.Admin.Api;

public static class PhaseDExecutionEndpoints
{
  public static IEndpointRouteBuilder MapPhaseDExecutionEndpoints(this IEndpointRouteBuilder endpoints)
  {
    var group = endpoints.MapGroup("/admin-api/v1");
    group.MapPost("/executions", StartAsync);
    // A preparation command may start a read-only validator child. Status GETs
    // remain file reads only, with no process creation or lifecycle mutation.
    group.MapPost("/execution-preparation", (PhaseDPreparationRequest request,
        IPhaseDPreparationService service, CancellationToken cancellationToken) =>
        service.PrepareAsync(request.SeasonNumber, request.WeaknessCode, cancellationToken));
    group.MapGet("/executions/{launchContextUid}", GetAsync);
    group.MapGet("/accounts/{accountUid}/executions", ListAsync);
    return endpoints;
  }

  private static async Task<IResult> StartAsync(
      PhaseDLaunchRequest request,
      IPhaseDExecutionService service,
      CancellationToken cancellationToken)
  {
    try
    {
      var projection = await service.StartAsync(request, cancellationToken).ConfigureAwait(false);
      return Results.Json(projection, statusCode: StatusCodes.Status201Created);
    }
    catch (PhaseDExecutionException exception)
    {
      throw Map(exception);
    }
  }

  private static async Task<IResult> GetAsync(
      string launchContextUid,
      IPhaseDExecutionService service,
      CancellationToken cancellationToken)
  {
    try
    {
      var projection = await service.GetAsync(ParseUid(launchContextUid), cancellationToken)
          .ConfigureAwait(false);
      return projection is null
          ? Results.NotFound(new { code = "phase_d_execution_not_found" })
          : Results.Json(projection);
    }
    catch (PhaseDExecutionException exception)
    {
      throw Map(exception);
    }
  }

  private static async Task<IResult> ListAsync(
      string accountUid,
      IPhaseDExecutionService service,
      CancellationToken cancellationToken)
  {
    try
    {
      var projection = await service.ListAsync(ParseUid(accountUid), cancellationToken)
          .ConfigureAwait(false);
      return Results.Json(projection);
    }
    catch (PhaseDExecutionException exception)
    {
      throw Map(exception);
    }
  }

  private static EntityUid ParseUid(string value)
  {
    if (!Guid.TryParseExact(value, "D", out var guid) || guid == Guid.Empty)
    {
      throw new ApiRequestException(StatusCodes.Status400BadRequest, "entity_uid_invalid");
    }

    return new EntityUid(guid);
  }

  private static ApiRequestException Map(PhaseDExecutionException exception)
  {
    var status = exception.Message switch
    {
      "phase_d_account_not_found" or "phase_d_execution_not_found" =>
          StatusCodes.Status404NotFound,
      "phase_d_runtime_not_cold" or "phase_d_operation_in_progress" or
          "phase_d_owner_identity_unresolved" or "phase_d_execution_owner_unresolved" => StatusCodes.Status409Conflict,
      "phase_d_operation_pending" or "phase_d_preparation_changed" => StatusCodes.Status409Conflict,
      "phase_d_launch_request_invalid" or "phase_d_account_uid_invalid" or
          "phase_d_launch_uid_invalid" or "phase_d_account_candidate_not_ready" or
          "phase_d_lobby_not_materialized" => StatusCodes.Status422UnprocessableEntity,
      "phase_d_execution_not_configured" => StatusCodes.Status503ServiceUnavailable,
      _ when exception.Message.StartsWith("phase_d_boss_variant_", StringComparison.Ordinal) ||
          exception.Message.StartsWith("phase_d_bundle_", StringComparison.Ordinal) ||
          exception.Message.StartsWith("phase_d_preparation_", StringComparison.Ordinal) => StatusCodes.Status422UnprocessableEntity,
      _ => StatusCodes.Status500InternalServerError
    };
    return new ApiRequestException(status, exception.Message);
  }
}
