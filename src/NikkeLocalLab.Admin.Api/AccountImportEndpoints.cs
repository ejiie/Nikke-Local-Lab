namespace NikkeLocalLab.Admin.Api;

public static class AccountImportEndpoints
{
  public static IEndpointRouteBuilder MapAccountImportEndpoints(this IEndpointRouteBuilder endpoints)
  {
    endpoints.MapPost("/admin-api/v1/account-imports", ImportAsync);
    return endpoints;
  }

  private static async Task<IResult> ImportAsync(
      AccountImportRequest request,
      IAccountImportService service,
      CancellationToken cancellationToken)
  {
    try
    {
      var projection = await service.ImportAsync(request, cancellationToken).ConfigureAwait(false);
      return Results.Json(projection, statusCode: StatusCodes.Status201Created);
    }
    catch (AccountImportException exception)
    {
      var status = exception.Message switch
      {
        "account_import_uid_invalid" => StatusCodes.Status400BadRequest,
        "account_import_not_configured" => StatusCodes.Status503ServiceUnavailable,
        "account_import_profile_not_materializable" => StatusCodes.Status422UnprocessableEntity,
        _ => StatusCodes.Status500InternalServerError
      };
      throw new ApiRequestException(status, exception.Message);
    }
  }
}
