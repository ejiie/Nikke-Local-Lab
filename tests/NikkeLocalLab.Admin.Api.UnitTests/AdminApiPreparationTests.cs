using System.Net;
using System.Net.Http.Json;
using System.Text.Json;

namespace NikkeLocalLab.Admin.Api.UnitTests;

public sealed partial class AdminApiSecurityTests
{
  [Fact]
  public async Task PreparationRequiresAuthenticatedCsrfCommandAndDoesNotRunOnGet()
  {
    await using var fixture = await RunningApi.StartAsync();
    const string path = "/admin-api/v1/execution-preparation";
    using var anonymous = new HttpRequestMessage(HttpMethod.Post, path);
    anonymous.Headers.TryAddWithoutValidation("Origin", fixture.Origin);
    anonymous.Content = JsonContent.Create(new { seasonNumber = 26, weaknessCode = "water" });
    using var denied = await fixture.Client.SendAsync(anonymous);
    Assert.Equal(HttpStatusCode.Unauthorized, denied.StatusCode);
    var csrf = await fixture.GetCsrfAsync();
    using var get = await fixture.Client.GetAsync(path);
    Assert.Equal(HttpStatusCode.MethodNotAllowed, get.StatusCode);
    using var command = new HttpRequestMessage(HttpMethod.Post, path);
    command.Headers.TryAddWithoutValidation("Origin", fixture.Origin);
    command.Headers.TryAddWithoutValidation("X-NLL-CSRF", csrf);
    command.Content = JsonContent.Create(new { seasonNumber = 26, weaknessCode = "water" });
    using var response = await fixture.Client.SendAsync(command);
    Assert.Equal(HttpStatusCode.OK, response.StatusCode);
    using var document = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
    var root = document.RootElement;
    Assert.Equal("nll/phase-d-preparation/v1", root.GetProperty("contractId").GetString());
    Assert.Equal("blocked", root.GetProperty("statusCode").GetString());
    Assert.False(root.TryGetProperty("plan", out _));
  }
}
