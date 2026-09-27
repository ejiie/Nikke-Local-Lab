using System.Text.Json;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging.Abstractions;
using NikkeLocalLab.Admin.Api;

namespace NikkeLocalLab.Admin.Api.UnitTests;

public sealed class AccountImportFailureTests
{
  [Theory]
  [InlineData("error:migration_checksum_mismatch", "account_import_schema_mismatch")]
  [InlineData("error:migration_history_unknown\r\n", "account_import_schema_mismatch")]
  [InlineData("private response body", "account_import_draft_materialization_failed")]
  [InlineData("error:private_value", "account_import_draft_materialization_failed")]
  public void ChildProcessErrorsExposeOnlyKnownDiagnosticCodes(string stderr, string expected)
  {
    Assert.Equal(expected, FilesystemAccountImportService.ResolveProcessFailure(
        stderr, "account_import_draft_materialization_failed"));
  }

  [Theory]
  [InlineData("account_import_schema_mismatch")]
  [InlineData("account_import_draft_materialization_failed")]
  public async Task ImportFailureOnConnectionRoutePreservesControlledCode(string code)
  {
    using var services = new ServiceCollection().AddLogging().ConfigureHttpJsonOptions(_ => { }).BuildServiceProvider();
    var context = new DefaultHttpContext { RequestServices = services };
    context.Request.Path = "/admin-api/v1/accounts/00000000-0000-0000-0000-000000000001/synchronize";
    using var body = new MemoryStream();
    context.Response.Body = body;
    var middleware = new SafeApiExceptionMiddleware(_ => throw new AccountImportException(code),
        NullLogger<SafeApiExceptionMiddleware>.Instance);
    await middleware.InvokeAsync(context);
    Assert.Equal(422, context.Response.StatusCode);
    body.Position = 0;
    using var json = await JsonDocument.ParseAsync(body);
    Assert.Equal(code, json.RootElement.GetProperty("code").GetString());
  }
}
