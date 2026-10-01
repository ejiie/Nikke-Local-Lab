using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.DependencyInjection;

namespace NikkeLocalLab.Admin.Api.UnitTests;

public sealed class UnionRaidTests : IDisposable
{
  private readonly string root = Path.Combine(Path.GetTempPath(), "nll-union-test-" + Guid.NewGuid().ToString("N"));
  private readonly JsonSerializerOptions json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
  private UnionRaidSeasonCard Season(int number, int count = 5) => new(number, "available", null, new string('c', 64),
      Enumerable.Range(1, count).Select(order => new UnionRaidBossCard(order, "합성 보스")).ToArray());
  private UnionRaidCatalogService Service(params UnionRaidSeasonCard[] seasons)
  {
    Directory.CreateDirectory(root);
    var path = Path.Combine(root, "catalog.json");
    File.WriteAllText(path, JsonSerializer.Serialize(new UnionRaidCatalogDocument(1, "nll/union-raid-hard-catalog/v1", new string('a', 64), seasons), json));
    var hash = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path))).ToLowerInvariant();
    return new(path, hash, Path.Combine(root, "registry"));
  }
  [Fact]
  public void CatalogOrdersNewestFirstAndRejectsPartialOrDuplicateSeasons()
  {
    Assert.Equal([3, 1], Service(Season(1), Season(3)).Read().Seasons.Select(s => s.SeasonNumber).ToArray());
    Assert.Throws<ApiRequestException>(() => Service(Season(3, 4)).Read());
    Assert.Throws<ApiRequestException>(() => Service(Season(3), Season(3)).Read());
  }
  [Fact]
  public async Task DurableWorkerKeepsFailedSeasonUnpublishedAndReplaysTheSameOperation()
  {
    var catalog = Service(Season(3));
    var jobs = new FilesystemBossOnboardingService(Path.Combine(root, "jobs"), catalog, new FailingRunner());
    var request = new BossOnboardingRequest(Guid.NewGuid(), 3, catalog.Read().CatalogSha256);
    var first = await jobs.StartAsync(request, default);
    Assert.Equal(first.JobUid, (await jobs.StartAsync(request, default)).JobUid);
    await jobs.RunNextAsync(default);
    Assert.Equal("failed", jobs.Get(first.JobUid)!.StatusCode);
    Assert.Equal("available", catalog.Read().Seasons.Single().StatusCode);
  }
  [Fact]
  public void ExistingCatalogWithoutPresentationFieldsRemainsReadable()
  {
    Service(Season(3));
    var path = Path.Combine(root, "catalog.json");
    var document = JsonNode.Parse(File.ReadAllText(path))!;
    foreach (var boss in document["seasons"]![0]!["bosses"]!.AsArray())
      foreach (var key in new[] { "weaknessCode", "imageStatusCode", "imageSha256" }) boss!.AsObject().Remove(key);
    File.WriteAllText(path, document.ToJsonString());
    var service = new UnionRaidCatalogService(path, Hash(File.ReadAllBytes(path)), Path.Combine(root, "registry"));
    Assert.All(service.Read().Seasons.Single().Bosses, b => { Assert.Null(b.WeaknessCode); Assert.Null(b.ImageUrl); });
    Assert.Null(service.GetImage(3, 1, service.Read().CatalogSha256));
  }

  [Theory]
  [InlineData("ice", "unresolved", null)]
  [InlineData("water", "resolved", null)]
  [InlineData(null, "resolved", "../escape")]
  [InlineData(null, "other", null)]
  [InlineData(null, "unresolved", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")]
  public void InvalidPresentationMetadataIsRejected(string? weakness, string status, string? hash)
  {
    var season = Season(3);
    season.Bosses[0] = new(1, "합성 보스", weakness, status, hash);
    Assert.Throws<ApiRequestException>(() => Service(season).Read());
  }

  [Fact]
  public async Task ImageEndpointServesOnlyPinnedPngAndProjectionUsesBossOrder()
  {
    byte[] png = [137, 80, 78, 71, 13, 10, 26, 10, 0]; // Synthetic signature fixture, same boundary as Solo.
    var season = Season(3);
    season.Bosses[1] = new(2, "합성 보스", "water", "resolved", Hash(png));
    var catalog = Service(season);
    var view = catalog.Read();
    Assert.Equal("water", view.Seasons[0].Bosses[1].WeaknessCode);
    Assert.Equal($"/admin-api/v1/union-raid/seasons/3/bosses/2/image?catalog={view.CatalogSha256}", view.Seasons[0].Bosses[1].ImageUrl);
    Directory.CreateDirectory(Path.Combine(root, "images"));
    var image = Path.Combine(root, "images", Hash(png) + ".png");
    File.WriteAllBytes(image, png);
    var builder = WebApplication.CreateBuilder();
    builder.Services.AddSingleton(new UnionRaidService(catalog,
        new FilesystemBossOnboardingService(Path.Combine(root, "jobs"), catalog, new FailingRunner())));
    await using var app = builder.Build();
    app.MapUnionRaidEndpoints();
    var endpoint = ((IEndpointRouteBuilder)app).DataSources.SelectMany(s => s.Endpoints).OfType<RouteEndpoint>()
        .Single(e => e.RoutePattern.RawText!.EndsWith("/image", StringComparison.Ordinal));
    async Task<DefaultHttpContext> Request(int number, int order, string pin)
    {
      var context = new DefaultHttpContext { RequestServices = app.Services };
      context.Request.Method = "GET";
      context.Request.RouteValues["season"] = number.ToString();
      context.Request.RouteValues["order"] = order.ToString();
      context.Request.QueryString = new QueryString("?catalog=" + pin);
      context.Response.Body = new MemoryStream();
      await endpoint.RequestDelegate!(context);
      return context;
    }
    var response = await Request(3, 2, view.CatalogSha256);
    Assert.Equal(200, response.Response.StatusCode);
    Assert.Equal("image/png", response.Response.ContentType);
    Assert.Equal(png, ((MemoryStream)response.Response.Body).ToArray());
    Assert.Equal(404, (await Request(3, 2, new string('0', 64))).Response.StatusCode);
    Assert.Equal(404, (await Request(1, 2, view.CatalogSha256)).Response.StatusCode);
    Assert.Equal(404, (await Request(3, 1, view.CatalogSha256)).Response.StatusCode);
    Assert.Equal(404, (await Request(3, 6, view.CatalogSha256)).Response.StatusCode);
    File.WriteAllBytes(image, [1, 2, 3]);
    Assert.Equal(404, (await Request(3, 2, view.CatalogSha256)).Response.StatusCode);
    File.Delete(image);
    Assert.Equal(404, (await Request(3, 2, view.CatalogSha256)).Response.StatusCode);
    File.WriteAllText(Path.Combine(root, "catalog.json"), "{}");
    Assert.Equal(404, (await Request(3, 2, view.CatalogSha256)).Response.StatusCode);
  }

  [Fact]
  public void MatchingHashWithoutPngSignatureIsNotAnImage()
  {
    byte[] bytes = [1, 2, 3];
    var season = Season(3);
    season.Bosses[0] = new(1, "합성 보스", null, "resolved", Hash(bytes));
    var service = Service(season);
    Directory.CreateDirectory(Path.Combine(root, "images"));
    File.WriteAllBytes(Path.Combine(root, "images", Hash(bytes) + ".png"), bytes);
    Assert.Null(service.GetImage(3, 1, service.Read().CatalogSha256));
  }

  [Theory]
  [InlineData("solo", "all", 400)]
  [InlineData("union", "all", 503)]
  [InlineData("union", "live", 503)]
  [InlineData("solo", "practice", 503)]
  public async Task AllModeIsAcceptedOnlyForUnion(string kind, string mode, int status)
  {
    await using var app = WebApplication.CreateBuilder().Build();
    app.MapRaidRecordEndpoints();
    var endpoint = ((IEndpointRouteBuilder)app).DataSources.SelectMany(s => s.Endpoints).OfType<RouteEndpoint>()
        .Single(e => e.RoutePattern.RawText!.EndsWith("/raid-records", StringComparison.Ordinal));
    var context = new DefaultHttpContext { RequestServices = app.Services };
    context.Request.Method = "GET";
    context.Request.RouteValues["accountUid"] = Guid.NewGuid().ToString();
    context.Request.QueryString = new QueryString($"?season=3&kind={kind}&step=1&mode={mode}&weakness=all");
    var error = await Assert.ThrowsAsync<ApiRequestException>(() => endpoint.RequestDelegate!(context));
    Assert.Equal(status, error.StatusCode);
  }

  private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
  private sealed class FailingRunner : IBossPipelineRunner
  {
    public Task<BossPipelineResult> RunAsync(BossOnboardingJob job, string output, CancellationToken token) =>
        throw new BossPipelineException("boss_union_behavior_unresolved");
    public Task<bool> RecoverAsync(BossOnboardingJob job, CancellationToken token) => Task.FromResult(true);
  }
  public void Dispose() { if (Directory.Exists(root)) Directory.Delete(root, true); }
}
