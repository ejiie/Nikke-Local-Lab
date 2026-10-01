using System.Text.Json;

namespace NikkeLocalLab.Admin.Api;

public sealed record UnionRaidBossView(int Order, string? DisplayName, string? WeaknessCode, string? ImageUrl);
public sealed record UnionRaidBossCard(int Order, string? DisplayName, string? WeaknessCode = null,
    string ImageStatusCode = "unresolved", string? ImageSha256 = null);
public sealed record UnionRaidSeasonCard(int SeasonNumber, string StatusCode, string? FailureCode,
    string? SourceSetSha256, UnionRaidBossCard[] Bosses);
public sealed record UnionRaidSeasonView(int SeasonNumber, string StatusCode, string? FailureCode,
    string? SourceSetSha256, UnionRaidBossView[] Bosses);
public sealed record UnionRaidCatalogDocument(int SchemaVersion, string ContractId, string SourceStaticDataSha256,
    UnionRaidSeasonCard[] Seasons);
public sealed record UnionRaidCatalogView(string StatusCode, string CatalogSha256, UnionRaidSeasonView[] Seasons);

public sealed class UnionRaidCatalogService(string catalogPath, string catalogSha256, string registryRoot) : IBossSeasonCatalogService
{
  private UnionRaidCatalogDocument ReadSnapshot()
  {
    var bytes = FilesystemBossSeasonCatalogService.ReadFile(catalogPath, 1048576);
    if (FilesystemBossSeasonCatalogService.Hash(bytes) != catalogSha256) throw new ApiRequestException(503, "boss_union_catalog_changed");
    var data = JsonSerializer.Deserialize<UnionRaidCatalogDocument>(bytes, FilesystemBossSeasonCatalogService.JsonOptions);
    if (data is null || data.SchemaVersion != 1 || data.ContractId != "nll/union-raid-hard-catalog/v1" ||
        data.Seasons is null || data.Seasons.Length is < 1 or > 999 || data.Seasons.Select(s => s?.SeasonNumber).Distinct().Count() != data.Seasons.Length ||
        data.Seasons.Any(s => s is null || s.Bosses is null || s.SeasonNumber is < 1 or > 999 || s.StatusCode is not ("available" or "unresolved") ||
          s.Bosses.Any(b => b is null || b.Order is < 1 or > 5 ||
            (b.WeaknessCode is not null && !FilesystemBossSeasonCatalogService.IsWeakness(b.WeaknessCode)) ||
            (b.ImageStatusCode == "resolved" ? !FilesystemBossSeasonCatalogService.IsHash(b.ImageSha256) :
              b.ImageStatusCode != "unresolved" || b.ImageSha256 is not null)) ||
          (s.StatusCode == "available" && (!FilesystemBossSeasonCatalogService.IsHash(s.SourceSetSha256) ||
            !s.Bosses.Select(b => b.Order).SequenceEqual(Enumerable.Range(1, 5))))))
      throw new ApiRequestException(503, "boss_union_catalog_invalid");
    return data;
  }
  public UnionRaidCatalogView Read() => new("ready", catalogSha256,
      ReadSnapshot().Seasons.OrderByDescending(s => s.SeasonNumber).Select(s => new UnionRaidSeasonView(
        s.SeasonNumber, s.StatusCode == "available" && Published(s.SeasonNumber) ? "assembled" : s.StatusCode,
        s.FailureCode, s.SourceSetSha256, s.Bosses.Select(b => new UnionRaidBossView(b.Order, b.DisplayName,
          b.WeaknessCode, b.ImageStatusCode == "resolved" ?
            $"/admin-api/v1/union-raid/seasons/{s.SeasonNumber}/bosses/{b.Order}/image?catalog={catalogSha256}" : null)).ToArray())).ToArray());

  public byte[]? GetImage(int season, int order, string hash)
  {
    if (hash != catalogSha256) return null;
    try
    {
      var row = ReadSnapshot().Seasons.SingleOrDefault(s => s.SeasonNumber == season)?.Bosses.SingleOrDefault(b => b.Order == order);
      if (row?.ImageStatusCode != "resolved") return null;
      var bytes = FilesystemBossSeasonCatalogService.ReadFile(
          Path.Combine(Path.GetDirectoryName(catalogPath)!, "images", row.ImageSha256 + ".png"), 20971520);
      return FilesystemBossSeasonCatalogService.Hash(bytes) == row.ImageSha256 &&
          bytes.AsSpan().StartsWith(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 }) ? bytes : null;
    }
    catch (Exception error) when (FilesystemBossSeasonCatalogService.IsReadFailure(error) || error is ApiRequestException) { return null; }
  }
  private bool Published(int season)
  {
    var root = Path.Combine(registryRoot, $"{season}-{catalogSha256}");
    if (!File.Exists(Path.Combine(root, "receipt.json"))) return false;
    try
    {
      using var receipt = JsonDocument.Parse(FilesystemBossSeasonCatalogService.ReadFile(Path.Combine(root, "receipt.json"), 16384));
      UnionRaidService.ValidateReceipt(receipt.RootElement, season, catalogSha256);
      return FilesystemBossSeasonCatalogService.Hash(FilesystemBossSeasonCatalogService.ReadFile(Path.Combine(root, "runtime.private.json"), 16777216)) ==
          receipt.RootElement.GetProperty("runtimeSha256").GetString();
    }
    catch (Exception error) when (error is IOException or JsonException or InvalidOperationException) { return false; }
  }
  public BossSeasonCatalogProjection Get()
  {
    var view = Read();
    return new(1, "nll/union-raid-hard-catalog-view/v1", "ready", null, catalogSha256,
        view.Seasons.Max(s => s.SeasonNumber), "unresolved", view.Seasons.Select(s => new BossSeasonProjection(
          s.SeasonNumber, null, null, s.StatusCode == "unresolved" ? "unresolved" : "unprocessed", s.FailureCode, null)).ToArray());
  }
  public byte[]? GetImage(int season, string hash) => null;
}

public sealed record UnionRaidService(UnionRaidCatalogService Catalog, FilesystemBossOnboardingService Jobs)
{
  internal static void ValidateReceipt(JsonElement row, int season, string hash)
  {
    if (row.GetProperty("contractId").GetString() != "nll/union-raid-hard-assembly/v1" ||
        row.GetProperty("seasonNumber").GetInt32() != season || row.GetProperty("catalogSha256").GetString() != hash ||
        row.GetProperty("elementModified").GetBoolean() || row.GetProperty("fxModified").GetBoolean() ||
        row.GetProperty("nativeClientExecuted").GetBoolean() ||
        !row.GetProperty("bosses").EnumerateArray().Select(b => b.GetProperty("order").GetInt32()).SequenceEqual(Enumerable.Range(1, 5)))
      throw new InvalidOperationException("boss_union_receipt_invalid");
  }
  internal static BossPipelineResult ReadResult(string output, BossOnboardingJob job)
  {
    var bytes = FilesystemBossSeasonCatalogService.ReadFile(Path.Combine(output, "assembly.json"), 16384);
    using var document = JsonDocument.Parse(bytes);
    ValidateReceipt(document.RootElement, job.SeasonNumber, job.CatalogSha256);
    var hash = FilesystemBossSeasonCatalogService.Hash(bytes);
    // This receipt admits the five behavior closures only; it does not certify
    // game launch, a battle result or Solo affinity/FX delivery.
    return new("completed", null, hash, hash);
  }
}

public sealed class UnionRaidWorker(UnionRaidService service, ILogger<UnionRaidWorker> logger) : BackgroundService
{
  protected override async Task ExecuteAsync(CancellationToken stoppingToken)
  {
    while (!stoppingToken.IsCancellationRequested)
    {
      try { await service.Jobs.RunNextAsync(stoppingToken).ConfigureAwait(false); }
      catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { break; }
      catch { logger.LogWarning("boss_union_worker_unavailable"); }
      try { await Task.Delay(TimeSpan.FromSeconds(2), stoppingToken).ConfigureAwait(false); }
      catch (OperationCanceledException) { break; }
    }
  }
}

public static class UnionRaidEndpoints
{
  public static void MapUnionRaidEndpoints(this IEndpointRouteBuilder endpoints)
  {
    static UnionRaidService Service(IServiceProvider provider) => provider.GetService<UnionRaidService>() ??
        throw new ApiRequestException(503, "boss_union_not_configured");
    var group = endpoints.MapGroup("/admin-api/v1/union-raid");
    group.MapGet("/seasons", (IServiceProvider p) => Service(p).Catalog.Read());
    group.MapGet("/seasons/{season:int}/bosses/{order:int}/image", (int season, int order, string catalog, IServiceProvider p) =>
        Service(p).Catalog.GetImage(season, order, catalog) is { } image ? Results.File(image, "image/png") : Results.NotFound());
    group.MapGet("/jobs", (IServiceProvider p) => Service(p).Jobs.List());
    group.MapPost("/jobs", async (BossOnboardingRequest request, IServiceProvider p, CancellationToken token) =>
        Results.Json(await Service(p).Jobs.StartAsync(request, token).ConfigureAwait(false), statusCode: 202));
  }
}
