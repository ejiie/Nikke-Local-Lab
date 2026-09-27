using System.Net;
using System.Net.Http.Json;

namespace NikkeLocalLab.Admin.Api.UnitTests;

public sealed partial class AdminApiSecurityTests
{
  [Fact]
  public void CharacterSyncInstalledConfigurationSupportsAllWorkerFields()
  {
    const string json = """
        {"root":"synthetic-root","scriptPath":"synthetic-script","scriptSha256":"synthetic-hash",
         "materializerPath":"synthetic-materializer","importerPath":"synthetic-importer",
         "gameConfigArchivePath":"synthetic-config","presentationPath":"synthetic-presentation",
         "toolPins":[{"path":"synthetic-tool","sha256":"synthetic-pin"}]}
        """;
    var options = System.Text.Json.JsonSerializer.Deserialize<CharacterCatalogSyncOptions>(
        json, FilesystemBossSeasonCatalogService.JsonOptions);
    Assert.NotNull(options);
    Assert.Equal("synthetic-root", options.Root);
  }

  [Fact]
  public async Task CharacterSyncRequiresAuthenticationJsonAndCsrfAndReturnsCounts()
  {
    var service = new CharacterSyncStub();
    await using var fixture = await RunningApi.StartAsync(characterSynchronizer: service);
    const string path = "/admin-api/v1/characters/sync";
    using var anonymousRequest = new HttpRequestMessage(HttpMethod.Post, path) { Content = JsonContent.Create(new { }) };
    anonymousRequest.Headers.TryAddWithoutValidation("Origin", fixture.Origin);
    using var anonymous = await fixture.Client.SendAsync(anonymousRequest);
    Assert.Equal(HttpStatusCode.Unauthorized, anonymous.StatusCode);
    var csrf = await fixture.GetCsrfAsync();
    using var empty = new HttpRequestMessage(HttpMethod.Post, path);
    empty.Headers.TryAddWithoutValidation("Origin", fixture.Origin);
    using var rejected = await fixture.Client.SendAsync(empty);
    Assert.Equal(HttpStatusCode.UnsupportedMediaType, rejected.StatusCode);
    using var missing = new HttpRequestMessage(HttpMethod.Post, path) { Content = JsonContent.Create(new { }) };
    missing.Headers.TryAddWithoutValidation("Origin", fixture.Origin);
    using var denied = await fixture.Client.SendAsync(missing);
    Assert.Equal(HttpStatusCode.Forbidden, denied.StatusCode);
    Assert.Equal(0, service.Calls);
    using var command = new HttpRequestMessage(HttpMethod.Post, path) { Content = JsonContent.Create(new { }) };
    command.Headers.TryAddWithoutValidation("Origin", fixture.Origin);
    command.Headers.TryAddWithoutValidation("X-NLL-CSRF", csrf);
    using var accepted = await fixture.Client.SendAsync(command);
    Assert.Equal(HttpStatusCode.OK, accepted.StatusCode);
    Assert.Equal(1, (await accepted.Content.ReadFromJsonAsync<CharacterCatalogSyncResult>())!.AddedCharacterCount);
    Assert.Equal(1, service.Calls);
  }
  private sealed class CharacterSyncStub : ICharacterCatalogSynchronizer
  {
    public int Calls { get; private set; }
    public Task<CharacterCatalogSyncResult> SynchronizeAsync(CancellationToken token)
    { Calls++; return Task.FromResult(new CharacterCatalogSyncResult("updated", 1)); }
  }
}
