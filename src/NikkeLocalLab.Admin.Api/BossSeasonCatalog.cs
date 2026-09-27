using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace NikkeLocalLab.Admin.Api;

public sealed record BossSeasonCard(int SeasonNumber, string? DisplayName, string? DefaultWeaknessCode,
    string DiscoveryStatusCode, string? FailureCode, string NameStatusCode, string ImageStatusCode, string? ImageSha256);
public sealed record BossSeasonSnapshot(int SchemaVersion, string ContractId, string SourceStaticDataSha256,
    string SourceLocaleSetSha256, int MaximumKnownSeason, string CurrentSeasonStatusCode, BossSeasonCard[] Seasons);
public sealed record BossSeasonProjection(int SeasonNumber, string? DisplayName, string? DefaultWeaknessCode,
    string ProcessingStatusCode, string? FailureCode, string? ImageUrl);
public sealed record BossSeasonCatalogProjection(int SchemaVersion, string ContractId, string StatusCode,
    string? FailureCode, string? CatalogSha256, int MaximumKnownSeason, string CurrentSeasonStatusCode,
    BossSeasonProjection[] Seasons);

public interface IBossSeasonCatalogService
{
  BossSeasonCatalogProjection Get();
  BossSeasonCatalogProjection GetRevision(string catalogSha256) => Get();
  byte[]? GetImage(int season, string catalogSha256);
}

public sealed class UnavailableBossSeasonCatalogService : IBossSeasonCatalogService
{
  public BossSeasonCatalogProjection Get() => new(1, "nll/boss-season-catalog-view/v1", "blocked",
      "boss_catalog_not_configured", null, 0, "unresolved", []);
  public byte[]? GetImage(int season, string catalogSha256) => null;
}

public sealed class FilesystemBossSeasonCatalogService(string catalogPath, string catalogSha256, string registryRoot,
    UserValidationDelivery? userValidation = null)
    : IBossSeasonCatalogService
{
  internal static readonly JsonSerializerOptions JsonOptions = new()
  {
    PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
    MaxDepth = 24
  };

  public BossSeasonCatalogProjection Get()
  {
    try
    {
      var snapshot = ReadSnapshot();
      // Read once per GET so all cards describe one registry version. This starts
      // no process, doesn't publish, and is NOT execution preparation/admission.
      var statuses = ReadRegistry(snapshot);
      if (userValidation is not null)
      {
        try
        {
          var delivery = userValidation.ReadBound();
          var season = snapshot.Seasons.SingleOrDefault(row => row.SeasonNumber == delivery.View.SeasonNumber);
          // Only the separately prepared validation lane is exposed. Never
          // overwrite an admitted S26 card or enable the old v6/v3 run path.
          if (season is not null && season.DiscoveryStatusCode == "resolved" &&
              season.DefaultWeaknessCode == delivery.DefaultWeaknessCode && statuses[season.SeasonNumber].Status != "processed")
            statuses[season.SeasonNumber] = ("awaiting_game_validation", null);
        }
        catch (Exception error) when (IsReadFailure(error)) { /* Existing conservative registry projection remains authoritative. */ }
      }
      return new(1, "nll/boss-season-catalog-view/v1", "ready", null, catalogSha256, snapshot.MaximumKnownSeason,
          snapshot.CurrentSeasonStatusCode, snapshot.Seasons.Select(row =>
          {
            var (status, failure) = row.DiscoveryStatusCode != "resolved" ? ("unresolved", row.FailureCode) : statuses[row.SeasonNumber];
            return new BossSeasonProjection(row.SeasonNumber, row.DisplayName, row.DefaultWeaknessCode, status, failure,
                row.ImageStatusCode != "resolved" ? null : $"/admin-api/v1/boss-seasons/{row.SeasonNumber}/image?catalog={catalogSha256}");
          }).ToArray());
    }
    catch (Exception error) when (IsReadFailure(error))
    {
      return new(1, "nll/boss-season-catalog-view/v1", "blocked", "boss_catalog_unavailable", null, 0, "unresolved", []);
    }
  }

  public byte[]? GetImage(int season, string requestedCatalogSha256)
  {
    if (requestedCatalogSha256 != catalogSha256) return null;
    try { return Image(ReadSnapshot().Seasons.SingleOrDefault(row => row.SeasonNumber == season)); }
    catch (Exception error) when (IsReadFailure(error)) { return null; }
  }

  private BossSeasonSnapshot ReadSnapshot()
  {
    var bytes = ReadFile(catalogPath, 1048576);
    Require(IsHash(catalogSha256) && Hash(bytes) == catalogSha256);
    var result = JsonSerializer.Deserialize<BossSeasonSnapshot>(bytes, JsonOptions);
    Require(result is not null && result.SchemaVersion == 1 && result.ContractId == "nll/boss-season-catalog/v1" &&
        IsHash(result.SourceStaticDataSha256) && IsHash(result.SourceLocaleSetSha256) && result.MaximumKnownSeason is > 0 and <= 1000 &&
        result.CurrentSeasonStatusCode == "unresolved" && result.Seasons is not null && result.Seasons.Length == result.MaximumKnownSeason);
    for (var index = 0; index < result!.Seasons.Length; index++)
    {
      var row = result.Seasons[index];
      Require(row is not null && row.SeasonNumber == index + 1 &&
          (row.DiscoveryStatusCode == "resolved" ? IsWeakness(row.DefaultWeaknessCode) && row.FailureCode is null :
              row.DiscoveryStatusCode == "unresolved" && row.DefaultWeaknessCode is null && IsFailure(row.FailureCode)) &&
          (row.NameStatusCode == "resolved" ? row.DisplayName is { Length: > 0 and <= 160 } && !row.DisplayName.Any(char.IsControl) :
              row.NameStatusCode == "unresolved" && row.DisplayName is null) &&
          (row.ImageStatusCode == "resolved" ? IsHash(row.ImageSha256) : row.ImageStatusCode == "unresolved" && row.ImageSha256 is null));
    }
    return result;
  }

  private Dictionary<int, (string Status, string? Failure)> ReadRegistry(BossSeasonSnapshot snapshot)
  {
    var result = snapshot.Seasons.ToDictionary(row => row.SeasonNumber, _ => ("unprocessed", (string?)null));
    try
    {
      using var document = JsonDocument.Parse(ReadFile(Path.Combine(registryRoot, "registry.json"), 1048576));
      var root = document.RootElement;
      Require(root.GetProperty("schemaVersion").GetInt32() == 1 && root.GetProperty("contractId").GetString() == "nll/boss-runtime-variant-registry/v1");
      var entries = root.GetProperty("profiles").EnumerateArray().ToArray();
      Require(entries.Length <= 1000 && entries.Select(row => row.GetProperty("seasonNumber").GetInt32()).Distinct().Count() == entries.Length &&
          entries.Select(row => row.GetProperty("profileCode").GetString()).Distinct(StringComparer.Ordinal).Count() == entries.Length);
      foreach (var entry in entries)
      {
        var season = entry.GetProperty("seasonNumber").GetInt32();
        if (!result.ContainsKey(season)) continue;
        result[season] = ("unprocessed", "boss_profile_not_ready");
        var relative = entry.GetProperty("profileRelativePath").GetString();
        var hash = entry.GetProperty("profileSha256").GetString();
        Require(relative is not null && Regex.IsMatch(relative, "\\A[a-z][a-z0-9._-]{0,140}\\.json\\z", RegexOptions.CultureInvariant) && IsHash(hash));
        var bytes = ReadFile(Path.Combine(registryRoot, relative!), 1048576);
        if (Hash(bytes) != hash) { result[season] = ("unprocessed", "boss_profile_drifted"); continue; }
        using var profile = JsonDocument.Parse(bytes);
        var p = profile.RootElement;
        if (p.GetProperty("schemaVersion").GetInt32() == 3) { result[season] = ("awaiting_runtime_delivery", "boss_runtime_delivery_required"); continue; }
        // Existing admitted profiles may be v1 (including the verified S26).
        // Catalog presentation does not impose the NEW publisher's v2-only gate.
        var version = p.GetProperty("schemaVersion").GetInt32();
        Require(version is 1 or 2 or 4 && p.GetProperty("contractId").GetString() == $"nll/boss-runtime-variant-profile/v{version}" &&
            p.GetProperty("seasonNumber").GetInt32() == season && p.GetProperty("profileCode").GetString() == entry.GetProperty("profileCode").GetString() &&
            p.GetProperty("sourceAffinity").GetProperty("weaknessCode").GetString() == snapshot.Seasons[season - 1].DefaultWeaknessCode);
        if (version == 4)
        {
          if (!entry.TryGetProperty("delivery", out var delivery)) { result[season] = ("awaiting_runtime_delivery", "boss_runtime_delivery_required"); continue; }
          var deliveryBytes = ReadFile(delivery.GetProperty("path").GetString()!, 1048576);
          Require(Hash(deliveryBytes) == delivery.GetProperty("sha256").GetString());
          using var bound = JsonDocument.Parse(deliveryBytes);
          Require(bound.RootElement.GetProperty("contractId").GetString() == "nll/common-boss-delivery/v1" &&
              bound.RootElement.GetProperty("profileSha256").GetString() == hash);
        }
        // Processed means assembled/delivered. Launch still requires the common
        // preparation gate; this card never claims actual game acceptance.
        if (entry.GetProperty("operationalStatusCode").GetString() == "enabled") result[season] = ("processed", null);
      }
    }
    catch (Exception error) when (IsReadFailure(error))
    {
      // Malformed shared registry cannot produce a partial set of ready cards.
      return snapshot.Seasons.ToDictionary(row => row.SeasonNumber, _ => ("unprocessed", (string?)"boss_registry_unavailable"));
    }
    return result;
  }

  private byte[]? Image(BossSeasonCard? row)
  {
    if (row?.ImageStatusCode != "resolved") return null;
    try
    {
      var bytes = ReadFile(Path.Combine(Path.GetDirectoryName(catalogPath)!, "images", row.ImageSha256 + ".png"), 20971520);
      return Hash(bytes) == row.ImageSha256 && bytes.AsSpan().StartsWith(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 }) ? bytes : null;
    }
    catch (Exception error) when (IsReadFailure(error)) { return null; }
  }
  internal static bool IsReadFailure(Exception error) => error is IOException or UnauthorizedAccessException or JsonException or
      InvalidOperationException or KeyNotFoundException or ArgumentException or NotSupportedException or OverflowException;
  internal static bool IsHash(string? value) => value is not null && Regex.IsMatch(value, "\\A[0-9a-f]{64}\\z", RegexOptions.CultureInvariant);
  internal static bool IsWeakness(string? value) => value is "fire" or "water" or "wind" or "electric" or "iron";
  private static bool IsFailure(string? value) => value is not null && Regex.IsMatch(value, "\\Aphase_d_boss_[a-z0-9_]{1,100}\\z", RegexOptions.CultureInvariant);
  internal static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
  internal static string Plain(string path)
  {
    Require(Path.IsPathFullyQualified(path) && !path.StartsWith(@"\\", StringComparison.Ordinal));
    path = Path.GetFullPath(path);
    Require(!path[Path.GetPathRoot(path)!.Length..].Contains(':'));
    for (var current = path; current is not null; current = Path.GetDirectoryName(current))
      if (File.Exists(current) || Directory.Exists(current)) Require((File.GetAttributes(current) & FileAttributes.ReparsePoint) == 0);
    return path;
  }
  internal static byte[] ReadFile(string path, int maximum)
  {
    using var stream = new FileStream(Plain(path), FileMode.Open, FileAccess.Read, FileShare.Read);
    Require(stream.Length > 0 && stream.Length <= maximum);
    var bytes = new byte[(int)stream.Length];
    stream.ReadExactly(bytes);
    Require(stream.ReadByte() == -1);
    return bytes;
  }
  internal static void Require([System.Diagnostics.CodeAnalysis.DoesNotReturnIf(false)] bool condition)
  { if (!condition) throw new JsonException("boss_catalog_invalid"); }
}

public static class BossSeasonEndpoints
{
  public static IEndpointRouteBuilder MapBossSeasonEndpoints(this IEndpointRouteBuilder endpoints)
  {
    var group = endpoints.MapGroup("/admin-api/v1");
    group.MapGet("/boss-seasons", (IBossSeasonCatalogService service) => service.Get());
    group.MapPost("/characters/sync", async (IServiceProvider provider, CancellationToken token) =>
        await (provider.GetService<ICharacterCatalogSynchronizer>() ?? throw new ApiRequestException(503, "character_catalog_sync_not_configured"))
            .SynchronizeAsync(token).ConfigureAwait(false));
    group.MapPost("/boss-seasons/sync", async (IServiceProvider provider, CancellationToken token) =>
        await (provider.GetService<IBossSeasonSynchronizer>() ?? throw new ApiRequestException(503, "boss_catalog_sync_not_configured"))
            .SynchronizeAsync(token).ConfigureAwait(false));
    group.MapGet("/boss-user-validation/{season:int}", (int season, IServiceProvider provider) =>
        provider.GetService<UserValidationDelivery>()?.Get(season) ??
        new UserValidationDeliveryView(1, "nll/user-validation-delivery-view/v1", season, "blocked",
            "boss_validation_delivery_unavailable", null, []));
    group.MapGet("/boss-user-validation/{season:int}/{weakness}", (int season, string weakness, IServiceProvider provider) =>
        provider.GetService<UserValidationExecution>()?.Get(season, weakness) ??
        new UserValidationActionView(1, "nll/user-validation-action/v1", null, season, weakness, "blocked", "boss_validation_delivery_unavailable"));
    group.MapPost("/boss-user-validation-actions", async (UserValidationActionRequest request, IServiceProvider provider, CancellationToken token) =>
    {
      var execution = provider.GetService<UserValidationExecution>() ?? throw new ApiRequestException(503, "boss_validation_delivery_unavailable");
      return Results.Json(await execution.BeginAsync(request, token).ConfigureAwait(false), statusCode: StatusCodes.Status202Accepted);
    });
    group.MapGet("/boss-onboarding-jobs", (IBossOnboardingService service) => service.List());
    group.MapGet("/boss-onboarding-jobs/{uid:guid}", (Guid uid, IBossOnboardingService service) =>
        service.Get(uid) is { } job ? Results.Json(job) : Results.NotFound());
    group.MapPost("/boss-onboarding-jobs", async (BossOnboardingRequest request, IBossOnboardingService service, CancellationToken token) =>
        Results.Json(await service.StartAsync(request, token).ConfigureAwait(false), statusCode: StatusCodes.Status202Accepted));
    group.MapGet("/boss-seasons/{season:int}/image", (int season, string catalog, IBossSeasonCatalogService service) =>
        service.GetImage(season, catalog) is { } image ? Results.File(image, "image/png") : Results.NotFound());
    return endpoints;
  }
}
