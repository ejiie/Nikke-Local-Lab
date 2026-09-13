using System.Security.Cryptography;
using System.Text.Json;

namespace NikkeLocalLab.Admin.Api.UnitTests;

public sealed class BossSeasonCatalogTests : IDisposable
{
  private readonly string root = Path.Combine(Path.GetTempPath(), "nll-boss-catalog-test-" + Guid.NewGuid().ToString("N"));
  private static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
  private string CatalogPath => Path.Combine(root, "catalog.json");
  private string RegistryRoot => Path.Combine(root, "registry");
  private string RegistryPath => Path.Combine(RegistryRoot, "registry.json");
  private BossSeasonSnapshot Snapshot => new(1, "nll/boss-season-catalog/v1", new string('a', 64), new string('b', 64), 3, "unresolved",
      [new(1, "합성 보스", "water", "resolved", null, "resolved", "unresolved", null),
        new(2, null, null, "unresolved", "phase_d_boss_catalog_manager_unresolved", "unresolved", "unresolved", null),
        new(3, "합성 보스", "fire", "resolved", null, "resolved", "unresolved", null)]);
  public BossSeasonCatalogTests()
  {
    Directory.CreateDirectory(RegistryRoot);
    Write(CatalogPath, Snapshot);
    Write(RegistryPath, new { schemaVersion = 1, contractId = "nll/boss-runtime-variant-registry/v1", profiles = Array.Empty<object>() });
  }
  private FilesystemBossSeasonCatalogService Service() => new(CatalogPath, Hash(CatalogPath), RegistryRoot);
  private static void Write(string path, object value) => File.WriteAllBytes(path, JsonSerializer.SerializeToUtf8Bytes(value, Json));
  private static string Hash(string path) => Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path))).ToLowerInvariant();
  private void Register(int version = 2, string relative = "synthetic.json", bool correctHash = true)
  {
    var profile = Path.Combine(RegistryRoot, "synthetic.json");
    Write(profile, new
    {
      schemaVersion = version,
      contractId = $"nll/boss-runtime-variant-profile/v{version}",
      seasonNumber = 1,
      profileCode = "synthetic-boss",
      sourceAffinity = new { weaknessCode = "water" }
    });
    Write(RegistryPath, new
    {
      schemaVersion = 1,
      contractId = "nll/boss-runtime-variant-registry/v1",
      profiles = new[] { new {
      seasonNumber = 1, profileCode = "synthetic-boss", profileRelativePath = relative, profileSha256 = correctHash ? Hash(profile) : new string('0', 64),
      operationalStatusCode = "enabled" } }
    });
  }
  [Fact]
  public void SnapshotKeepsSeasonGapsDefaultWeaknessAndSameBossSeparate()
  {
    var before = Directory.GetFiles(root, "*", SearchOption.AllDirectories).ToDictionary(path => path, Hash);
    var result = Service().Get();
    Assert.Equal("ready", result.StatusCode);
    Assert.Equal("unresolved", result.CurrentSeasonStatusCode);
    Assert.Equal(3, result.MaximumKnownSeason);
    Assert.Equal("unresolved", result.Seasons[1].ProcessingStatusCode);
    Assert.Equal("water", result.Seasons[0].DefaultWeaknessCode);
    Assert.Equal("fire", result.Seasons[2].DefaultWeaknessCode);
    Assert.Equal(result.Seasons[0].DisplayName, result.Seasons[2].DisplayName);
    Assert.All(before, pair => Assert.Equal(pair.Value, Hash(pair.Key)));
    Assert.Equal(before.Count, Directory.GetFiles(root, "*", SearchOption.AllDirectories).Length);
  }
  [Theory]
  [InlineData(1, true, "processed")]
  [InlineData(1, false, "unprocessed")]
  [InlineData(2, true, "processed")]
  [InlineData(2, false, "unprocessed")]
  [InlineData(3, true, "awaiting_runtime_delivery")]
  public void OnlyPinnedEnabledLegacyProfilesAppearProcessed(int version, bool pin, string expected)
  {
    Register(version, correctHash: pin);
    Assert.Equal(expected, Service().Get().Seasons[0].ProcessingStatusCode);
  }
  [Fact]
  public void ExistingV1ProfileStaysProcessedBesideADriftedV3Draft()
  {
    Register(1);
    var legacyPath = Path.Combine(RegistryRoot, "synthetic.json");
    var draftPath = Path.Combine(RegistryRoot, "draft.json");
    Write(draftPath, new
    {
      schemaVersion = 3,
      contractId = "nll/boss-runtime-variant-profile/v3",
      seasonNumber = 3,
      profileCode = "synthetic-draft",
      sourceAffinity = new { weaknessCode = "fire" }
    });
    Write(RegistryPath, new
    {
      schemaVersion = 1,
      contractId = "nll/boss-runtime-variant-registry/v1",
      profiles = new[] {
      new { seasonNumber = 1, profileCode = "synthetic-boss", profileRelativePath = "synthetic.json",
        profileSha256 = Hash(legacyPath), operationalStatusCode = "enabled" },
      new { seasonNumber = 3, profileCode = "synthetic-draft", profileRelativePath = "draft.json",
        profileSha256 = new string('0', 64), operationalStatusCode = "enabled" }
    }
    });
    var result = Service().Get();
    Assert.Equal("processed", result.Seasons[0].ProcessingStatusCode);
    Assert.Equal("unprocessed", result.Seasons[2].ProcessingStatusCode);
    Assert.Equal("boss_profile_drifted", result.Seasons[2].FailureCode);
  }
  [Theory]
  [InlineData("../synthetic.json")]
  [InlineData("other/synthetic.json")]
  [InlineData("C:\\outside.json")]
  [InlineData("synthetic.json:stream")]
  public void RegistryPathsCannotEscape(string relative)
  {
    Register(relative: relative);
    Assert.Equal("boss_registry_unavailable", Service().Get().Seasons[0].FailureCode);
  }
  [Fact]
  public void SnapshotDriftOrUnknownFieldsFailClosedWithoutChangingFiles()
  {
    var service = Service();
    File.AppendAllText(CatalogPath, " ");
    Assert.Equal("blocked", service.Get().StatusCode);
    Write(CatalogPath, new { schemaVersion = 1, unexpected = "private-source-key" });
    Assert.Equal("blocked", Service().Get().StatusCode);
    Assert.Null(Service().GetImage(1, Hash(CatalogPath)));
  }
  [Theory]
  [InlineData("current")]
  [InlineData("ready")]
  public void SnapshotCannotInventCurrentSeason(string current)
  {
    Write(CatalogPath, Snapshot with { CurrentSeasonStatusCode = current });
    Assert.Equal("blocked", Service().Get().StatusCode);
  }
  [Fact]
  public void MalformedGapOrDuplicateSeasonDoesNotLeakPartialCatalog()
  {
    var data = Snapshot;
    data.Seasons[1] = data.Seasons[0];
    Write(CatalogPath, data);
    Assert.Empty(Service().Get().Seasons);
  }
  [Fact]
  public void ImageRequiresPinnedSnapshotExactHashPngAndExistingSeason()
  {
    var bytes = new byte[] { 137, 80, 78, 71, 13, 10, 26, 10, 0, 0 }; // Synthetic header only, never a game image.
    var digest = Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
    Directory.CreateDirectory(Path.Combine(root, "images"));
    var imagePath = Path.Combine(root, "images", digest + ".png");
    File.WriteAllBytes(imagePath, bytes);
    var data = Snapshot;
    data.Seasons[0] = data.Seasons[0] with { ImageStatusCode = "resolved", ImageSha256 = digest };
    Write(CatalogPath, data);
    var service = Service();
    Assert.Equal(bytes, service.GetImage(1, Hash(CatalogPath)));
    Assert.Null(service.GetImage(1, new string('0', 64)));
    Assert.Null(service.GetImage(100, Hash(CatalogPath)));
    File.AppendAllText(imagePath, "drift");
    Assert.Null(service.GetImage(1, Hash(CatalogPath)));
  }
  public void Dispose()
  {
    if (Path.GetDirectoryName(root) != Path.TrimEndingDirectorySeparator(Path.GetTempPath()) ||
        !Path.GetFileName(root).StartsWith("nll-boss-catalog-test-", StringComparison.Ordinal) ||
        (File.GetAttributes(root) & FileAttributes.ReparsePoint) != 0) throw new InvalidOperationException("synthetic_cleanup_boundary_invalid");
    Directory.Delete(root, recursive: true);
  }
}
