using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using EpinelPS.Data;
using EpinelPS.Utils;
using Microsoft.Data.Sqlite;

// Local presentation data only. This does not discover assets, admit a boss, or
// assert that the largest season in a static snapshot is the current live season.
internal static class BossSeasonCatalog
{
  internal sealed record Card(int SeasonNumber, string? DisplayName, string? DefaultWeaknessCode,
      string DiscoveryStatusCode, string? FailureCode, string NameStatusCode,
      string ImageStatusCode = "unresolved", string? ImageSha256 = null);
  internal sealed record ImageHint(int SeasonNumber, string? MonsterImage, string? MonsterImageSi);
  internal sealed record Snapshot(int MaximumKnownSeason, Card[] Seasons, ImageHint[] Images);

  public static void Export(GameData data, string staticPack, string localeRoot, string outputRoot, string expectedPackSha256)
  {
    outputRoot = Path.GetFullPath(outputRoot);
    Require(!Directory.Exists(outputRoot) && !File.Exists(outputRoot), "output_exists");
    foreach (var path in new[] { outputRoot, staticPack, localeRoot }) Plain(path);
    Require(!outputRoot.StartsWith(@"C:\NIKKE", StringComparison.OrdinalIgnoreCase), "official_path_forbidden");
    var packHash = Hash(staticPack);
    Require(packHash == expectedPackSha256, "input_drifted");
    var locales = ReadLocales(localeRoot);
    var archive = BossContentDiscovery.GetDecodedArchive(data);
    try
    {
      var managers = BossContentDiscovery.DeserializeEntry<SoloRaidManagerRecord>(archive, "SoloRaidManagerTable.mpk");
      var presets = BossContentDiscovery.DeserializeEntry<SoloRaidPresetRecord>(archive, "SoloRaidPresetTable.mpk");
      var waves = BossContentDiscovery.DeserializeEntry<WaveDataRecord>(archive, "WaveDataTable.wave_Intercept_001.mpk");
      var monsters = BossContentDiscovery.DeserializeEntry<MonsterRecord>(archive, "MonsterTable.mpk");
      var elements = BossContentDiscovery.DeserializeEntry<ElementRecord>(archive, "ElementTable.mpk");
      var snapshot = Build(managers, presets, waves, monsters, elements, locales.Values);
      Require(Hash(staticPack) == packHash && locales.Pins.All(pair => Hash(pair.Key) == pair.Value), "input_drifted");
      Directory.CreateDirectory(outputRoot);
      WriteNew(Path.Combine(outputRoot, "images.private.json"), new { schemaVersion = 1,
        contractId = "nll/private-boss-season-images/v1", sourceStaticDataSha256 = packHash, images = snapshot.Images });
      WriteNew(Path.Combine(outputRoot, "catalog.json"), new { schemaVersion = 1, contractId = "nll/boss-season-catalog/v1",
        sourceStaticDataSha256 = packHash, sourceLocaleSetSha256 = HashText(string.Join("\n", locales.Pins.Values.Order(StringComparer.Ordinal))),
        maximumKnownSeason = snapshot.MaximumKnownSeason, currentSeasonStatusCode = "unresolved", seasons = snapshot.Seasons });
    }
    finally { CryptographicOperations.ZeroMemory(archive); }
  }

  internal static Snapshot Build(SoloRaidManagerRecord[] managers, SoloRaidPresetRecord[] presets, WaveDataRecord[] waves,
      MonsterRecord[] monsters, ElementRecord[] elements, Dictionary<string, string> names)
  {
      var seasons = managers.Select(row => row.RankingGroupId).Where(value => value > 0).ToArray();
      Require(seasons.Length > 0 && seasons.Max() <= 1000, "season_range_invalid");
      var cards = new List<Card>();
      var privateImages = new List<ImageHint>();
      foreach (var season in Enumerable.Range(1, seasons.Max()))
      {
        string? name = null, weakness = null, failure = null;
        try
        {
          var manager = One(managers.Where(row => row.RankingGroupId == season), "manager_unresolved");
          var preset = One(presets.Where(row => row.PresetGroupId == manager.MonsterPreset &&
              (int)row.DifficultyType == 2 && row.WaveOrder == 8), "challenge_preset_unresolved");
          var wave = One(waves.Where(row => row.StageId == preset.Wave), "wave_unresolved");
          var spawned = (wave.WaveData ?? []).SelectMany(row => row.WaveMonsterList ?? [])
              .Select(row => row.WaveMonsterId).ToHashSet();
          var target = One((wave.TargetList ?? []).Where(spawned.Contains).Distinct(), "target_unresolved");
          var monster = One(monsters.Where(row => row.Id == target), "monster_unresolved");
          var elementId = One(monster.ElementId ?? [], "affinity_unresolved");
          var element = One(elements.Where(row => row.Id == elementId), "affinity_unresolved");
          var weakElement = One(elements.Where(row => row.Id == element.WeakElementId), "affinity_unresolved");
          weakness = BossContentDiscovery.ElementCode(weakElement.Element);
          name = Resolve(names, monster.NameLocalkey) ?? Resolve(names, preset.WaveName);
          privateImages.Add(new(season, preset.MonsterImage, preset.MonsterImageSi));
        }
        catch (InvalidOperationException exception) when (exception.Message.StartsWith("phase_d_boss_catalog_", StringComparison.Ordinal) ||
            exception.Message == "phase_d_boss_discovery_affinity_unresolved")
        {
          failure = exception.Message;
        }
        cards.Add(new(season, name, weakness, failure is null ? "resolved" : "unresolved", failure,
          name is null ? "unresolved" : "resolved"));
      }
      return new(seasons.Max(), cards.ToArray(), privateImages.ToArray());
  }

  private sealed record Locales(Dictionary<string, string> Values, Dictionary<string, string> Pins);
  private static Locales ReadLocales(string root)
  {
    Require(Directory.Exists(root), "locale_missing");
    var files = Directory.GetFiles(root, "Locale_*.lsc").Order(StringComparer.Ordinal).ToArray();
    Require(files.Length is > 0 and <= 64, "locale_missing");
    var values = new Dictionary<string, string>(StringComparer.Ordinal);
    var pins = new Dictionary<string, string>(StringComparer.Ordinal);
    foreach (var file in files)
    {
      Plain(file);
      Require(new FileInfo(file).Length is > 0 and <= 134217728, "locale_invalid");
      var encrypted = File.ReadAllBytes(file);
      pins.Add(file, Convert.ToHexStringLower(SHA256.HashData(encrypted)));
      var decoded = NkdbDecryptor.Decrypt(encrypted);
      var temporary = Path.Combine(Path.GetTempPath(), "nll-boss-locale-" + Guid.NewGuid().ToString("N") + ".db");
      var temporaryOwned = false;
      try
      {
        using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
        { temporaryOwned = true; stream.Write(decoded); }
        using var connection = new SqliteConnection(new SqliteConnectionStringBuilder {
          DataSource = temporary, Mode = SqliteOpenMode.ReadOnly, Pooling = false }.ToString());
        connection.Open();
        using var tableCommand = connection.CreateCommand();
        tableCommand.CommandText = "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'";
        using var reader = tableCommand.ExecuteReader();
        var tables = new List<string>();
        while (reader.Read()) tables.Add(reader.GetString(0));
        reader.Close();
        Require(tables.Count == 1 && tables[0] == Path.GetFileNameWithoutExtension(file), "locale_table_invalid");
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT Key, ko FROM \"" + tables[0].Replace("\"", "\"\"", StringComparison.Ordinal) + "\"";
        using var rows = command.ExecuteReader();
        while (rows.Read())
        {
          if (rows.IsDBNull(1)) continue;
          Require(values.TryAdd(tables[0] + ":" + rows.GetString(0), rows.GetString(1)), "locale_ambiguous");
        }
      }
      finally
      {
        CryptographicOperations.ZeroMemory(encrypted);
        CryptographicOperations.ZeroMemory(decoded);
        if (temporaryOwned) File.Delete(temporary); // Never delete a failed CreateNew collision.
      }
    }
    return new(values, pins);
  }

  private static string? Resolve(Dictionary<string, string> values, string? key)
  {
    if (string.IsNullOrWhiteSpace(key)) return null;
    if (!key.Contains(':', StringComparison.Ordinal)) key = "Locale_System:" + key;
    return values.TryGetValue(key, out var value) && !string.IsNullOrWhiteSpace(value) && value.Length <= 160 &&
        !value.Any(char.IsControl) ? value : null; // Never return an unresolved source key.
  }
  private static T One<T>(IEnumerable<T> rows, string code)
  {
    var matches = rows.Take(2).ToArray();
    Require(matches.Length == 1, code);
    return matches[0];
  }
  private static void Plain(string path)
  {
    Require(Path.IsPathFullyQualified(path) && !path.StartsWith(@"\\", StringComparison.Ordinal), "path_invalid");
    for (var cursor = Path.GetFullPath(path); !string.IsNullOrEmpty(cursor); cursor = Path.GetDirectoryName(cursor))
      if (File.Exists(cursor) || Directory.Exists(cursor))
        Require((File.GetAttributes(cursor) & FileAttributes.ReparsePoint) == 0, "reparse_forbidden");
  }
  private static void WriteNew(string path, object value)
  {
    using var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
    stream.Write(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(value, new JsonSerializerOptions {
      PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true }) + "\n"));
    stream.Flush(true);
  }
  private static string Hash(string path) { using var stream = File.OpenRead(path); return Convert.ToHexStringLower(SHA256.HashData(stream)); }
  private static string HashText(string text) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(text)));
  private static void Require(bool condition, string code) { if (!condition) throw new InvalidOperationException("phase_d_boss_catalog_" + code); }
}
