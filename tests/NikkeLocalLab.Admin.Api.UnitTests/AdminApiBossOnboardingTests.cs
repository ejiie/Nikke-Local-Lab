using System.Net;
using System.Net.Http.Json;
using System.Text.Json;

namespace NikkeLocalLab.Admin.Api.UnitTests;

public sealed partial class AdminApiSecurityTests
{
  [Fact]
  public async Task BossCatalogAndJobsAreAuthenticatedAndImportRequiresCsrf()
  {
    await using var fixture = await RunningApi.StartAsync();
    foreach (var path in new[] { "/admin-api/v1/boss-seasons", "/admin-api/v1/boss-onboarding-jobs" })
    {
      using var denied = await fixture.Client.GetAsync(path);
      Assert.Equal(HttpStatusCode.Unauthorized, denied.StatusCode);
    }
    var csrf = await fixture.GetCsrfAsync();
    using var catalog = await fixture.Client.GetAsync("/admin-api/v1/boss-seasons");
    Assert.Equal(HttpStatusCode.OK, catalog.StatusCode);
    using var document = JsonDocument.Parse(await catalog.Content.ReadAsStringAsync());
    Assert.Equal("blocked", document.RootElement.GetProperty("statusCode").GetString());
    Assert.False(document.RootElement.TryGetProperty("sourcePath", out _));
    using var jobs = await fixture.Client.GetAsync("/admin-api/v1/boss-onboarding-jobs");
    Assert.Equal(HttpStatusCode.OK, jobs.StatusCode);
    Assert.Equal("[]", await jobs.Content.ReadAsStringAsync());
    using var missingCsrf = new HttpRequestMessage(HttpMethod.Post, "/admin-api/v1/boss-onboarding-jobs");
    missingCsrf.Headers.TryAddWithoutValidation("Origin", fixture.Origin);
    missingCsrf.Content = JsonContent.Create(new { seasonNumber = 1, catalogSha256 = new string('a', 64), operationUid = Guid.NewGuid() });
    using var deniedCommand = await fixture.Client.SendAsync(missingCsrf);
    Assert.Equal(HttpStatusCode.Forbidden, deniedCommand.StatusCode);
    using var command = new HttpRequestMessage(HttpMethod.Post, "/admin-api/v1/boss-onboarding-jobs");
    command.Headers.TryAddWithoutValidation("Origin", fixture.Origin);
    command.Headers.TryAddWithoutValidation("X-NLL-CSRF", csrf);
    command.Content = JsonContent.Create(new { seasonNumber = 1, catalogSha256 = new string('a', 64), operationUid = Guid.NewGuid() });
    using var response = await fixture.Client.SendAsync(command);
    Assert.Equal(HttpStatusCode.ServiceUnavailable, response.StatusCode);
    Assert.Contains("boss_onboarding_not_configured", await response.Content.ReadAsStringAsync(), StringComparison.Ordinal);
  }
}
