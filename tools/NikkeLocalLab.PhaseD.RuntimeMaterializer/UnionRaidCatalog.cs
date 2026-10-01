using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using EpinelPS.Data;

// Union uses the shared native behavior reader. It never enters the Solo
// weakness/QTE/FX transformation or rewrites the original combat data.
internal static class UnionRaidCatalog
{
  internal sealed record Boss(int Order, string? DisplayName, string[] BehaviorKeys,
      UnionRaidPresetRecord[] Presets, WaveDataRecord[] Waves, MonsterRecord[] Monsters);
  internal sealed record Season(int Number, UnionRaidManagerRecord Manager, int NormalLastLevel,
      Boss[] Bosses, string? FailureCode);
  private static readonly JsonSerializerOptions Json = new()
  { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, IncludeFields = true, WriteIndented = true };

  internal static Season[] Build(UnionRaidManagerRecord[] managers, UnionRaidPresetRecord[] presets,
      WaveDataRecord[] waves, MonsterRecord[] monsters, Dictionary<string, string> names)
  {
    // The source's manager namespace has a three-digit season suffix. Keep the
    // public season separate from the private manager identifier; never renumber
    // the remaining rows when an older season is absent.
    Require(managers.Length > 0 && managers.All(m => m.Id % 1000 > 0) &&
        managers.Select(m => m.Id % 1000).Distinct().Count() == managers.Length, "season_mapping_invalid");
    return managers.OrderByDescending(m => m.Id % 1000).Select(manager =>
    {
      var number = manager.Id % 1000;
      var selected = presets.Where(p => p.PresetGroupId == manager.MonsterPreset).ToArray();
      var hard = selected.Where(p => p.DifficultyType == UnionRaidDifficultyType.Hard).ToArray();
      var normal = selected.Where(p => p.DifficultyType == UnionRaidDifficultyType.Normal && !p.IsTrial).ToArray();
      try
      {
        Require(hard.Length > 0, "hard_not_available");
        Require(normal.Length > 0 && normal.Max(p => p.WaveChangeStep) > 0, "normal_state_unresolved");
        Require(hard.Select(p => p.WaveOrder).Distinct().Order().SequenceEqual(Enumerable.Range(1, 5)), "five_bosses_unresolved");
        var bosses = Enumerable.Range(1, 5).Select(order =>
        {
          var rows = hard.Where(p => p.WaveOrder == order).OrderBy(p => p.WaveChangeStep).ToArray();
          Require(rows.Any(p => !p.IsTrial) && rows.Select(p => (p.WaveChangeStep, p.IsTrial)).Distinct().Count() == rows.Length,
              "hard_presets_ambiguous");
          var bossWaves = rows.Select(p => p.Wave).Distinct().Select(id => One(waves.Where(w => w.StageId == id), "wave_unresolved")).ToArray();
          var targets = bossWaves.Select(w =>
          {
            var spawned = (w.WaveData ?? []).SelectMany(a => a.WaveMonsterList ?? []).Select(a => a.WaveMonsterId).ToHashSet();
            var id = One((w.TargetList ?? []).Where(spawned.Contains).Distinct(), "target_unresolved");
            return One(monsters.Where(m => m.Id == id), "monster_unresolved");
          }).DistinctBy(m => m.Id).ToArray();
          var keys = targets.SelectMany(m => new[] { m.SpotAi, m.SpotAiDefense, m.SpotAiBasedefense })
              .Where(k => !string.IsNullOrWhiteSpace(k)).Select(k => k!).Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToArray();
          Require(keys.Length > 0, "behavior_unresolved");
          var label = targets.Select(m => m.NameLocalkey).Concat(rows.Select(p => p.WaveName))
              .Select(k => BossSeasonCatalog.Resolve(names, k)).FirstOrDefault(k => k is not null);
          return new Boss(order, label, keys, rows, bossWaves, targets);
        }).ToArray();
        return new Season(number, manager, normal.Max(p => p.WaveChangeStep), bosses, null);
      }
      catch (InvalidOperationException error) when (error.Message.StartsWith("boss_union_", StringComparison.Ordinal))
      { return new Season(number, manager, 0, [], error.Message); }
    }).ToArray();
  }

  internal static void Export(string pack, string config, string localeRoot, string output)
  {
    output = Path.GetFullPath(output);
    Require(!Directory.Exists(output) && !File.Exists(output), "output_exists");
    BossSeasonCatalog.Plain(output);
    Require(!output.StartsWith(@"C:\NIKKE", StringComparison.OrdinalIgnoreCase), "output_invalid");
    var packHash = Hash(File.ReadAllBytes(pack));
    BossSeasonCatalog.ReadLocalArchive(pack, config, archive =>
    {
      T[] Read<T>(string entry) where T : class => BossContentDiscovery.DeserializeEntry<T>(archive, entry);
      var managers = Read<UnionRaidManagerRecord>("UnionRaidManagerTable.mpk");
      var presets = Read<UnionRaidPresetRecord>("UnionRaidPresetTable.mpk");
      var wanted = presets.Select(p => p.Wave).ToHashSet();
      using var zip = new ZipArchive(new MemoryStream(archive), ZipArchiveMode.Read);
      var waves = zip.Entries.Where(e => e.FullName.StartsWith("WaveDataTable.", StringComparison.Ordinal))
          .SelectMany(e => Read<WaveDataRecord>(e.FullName)).Where(w => wanted.Contains(w.StageId)).ToArray();
      var locales = BossSeasonCatalog.ReadLocales(localeRoot, true);
      var seasons = Build(managers, presets, waves, Read<MonsterRecord>("MonsterTable.mpk"), locales.Values);
      var elements = Read<ElementRecord>("ElementTable.mpk");
      Require(Hash(File.ReadAllBytes(pack)) == packHash && locales.Pins.All(p => Hash(File.ReadAllBytes(p.Key)) == p.Value), "input_drifted");
      Directory.CreateDirectory(output);
      foreach (var season in seasons.Where(s => s.FailureCode is null))
      {
        var root = Path.Combine(output, $"season-{season.Number}");
        Directory.CreateDirectory(root);
        Write(Path.Combine(root, "runtime.private.json"), new { contractId = "nll/private-union-raid-hard/v1", seasonNumber = season.Number,
          sourceStaticDataSha256 = packHash, manager = season.Manager, normalLastLevel = season.NormalLastLevel, bosses = season.Bosses });
        foreach (var boss in season.Bosses)
        {
          var bossRoot = Path.Combine(root, $"boss-{boss.Order}");
          Directory.CreateDirectory(bossRoot);
          Write(Path.Combine(bossRoot, "discovery.json"), new { contractId = "nll/boss-content-discovery/v1",
            seasonNumber = season.Number, profileCode = $"union-hard-{season.Number}-boss-{boss.Order}",
            behaviorAssembly = new { rootReferenceCount = boss.BehaviorKeys.Length,
              rootReferenceSetSha256 = Hash(Encoding.UTF8.GetBytes(string.Join("\n", boss.BehaviorKeys))) } });
          Write(Path.Combine(bossRoot, "discovery.private.json"), new { contractId = "nll/private-boss-content-diagnostic/v1",
            seasonNumber = season.Number, behaviorKeys = boss.BehaviorKeys });
        }
      }
      Write(Path.Combine(output, "images.private.json"), new { schemaVersion = 1,
        contractId = "nll/private-boss-season-images/v1", sourceStaticDataSha256 = packHash, images = ImageHints(seasons) });
      Write(Path.Combine(output, "catalog.json"), new { schemaVersion = 1, contractId = "nll/union-raid-hard-catalog/v1",
        sourceStaticDataSha256 = packHash, seasons = seasons.Select(s => new { seasonNumber = s.Number,
          statusCode = s.FailureCode is null ? "available" : "unresolved", failureCode = s.FailureCode,
          sourceSetSha256 = s.FailureCode is null ? SourceSetHash(Path.Combine(output, $"season-{s.Number}")) : null,
          bosses = s.Bosses.Select(b => new { order = b.Order, displayName = b.DisplayName,
            weaknessCode = Weakness(b, elements), imageStatusCode = "unresolved", imageSha256 = (string?)null }) }) });
    });
  }
  // Presentation metadata must not change combat closure or season admission.
  internal static string? Weakness(Boss boss, ElementRecord[] elements)
  {
    var weaknesses = new HashSet<string>(StringComparer.Ordinal);
    foreach (var monster in boss.Monsters)
    {
      if (monster.ElementId is not { Length: > 0 }) return null;
      foreach (var id in monster.ElementId)
      {
        var source = elements.Where(e => e.Id == id).ToArray();
        if (source.Length != 1) return null;
        var target = elements.Where(e => e.Id == source[0].WeakElementId).ToArray();
        if (target.Length != 1) return null;
        try { weaknesses.Add(BossContentDiscovery.ElementCode(target[0].Element)); }
        catch (InvalidOperationException error) when (error.Message == "phase_d_boss_discovery_affinity_unresolved") { return null; }
      }
    }
    return weaknesses.Count == 1 ? weaknesses.Single() : null;
  }

  internal sealed record ImageHint(int SeasonNumber, int Order, string MonsterImage, string? MonsterImageSi);
  internal static ImageHint[] ImageHints(Season[] seasons) => seasons.SelectMany(season => season.Bosses.SelectMany(boss =>
  {
    var names = boss.Presets.Select(p => p.MonsterImage).Distinct(StringComparer.Ordinal).ToArray();
    if (names.Length != 1 || string.IsNullOrWhiteSpace(names[0])) return Array.Empty<ImageHint>();
    var si = boss.Presets.Select(p => p.MonsterImageSi).Distinct(StringComparer.Ordinal).ToArray();
    return new[] { new ImageHint(season.Number, boss.Order, names[0]!, si.Length == 1 ? si[0] : null) };
  })).ToArray();

  private static T One<T>(IEnumerable<T> values, string code)
  { var rows = values.Take(2).ToArray(); Require(rows.Length == 1, code); return rows[0]; }
  private static void Require(bool value, string code)
  { if (!value) throw new InvalidOperationException("boss_union_" + code); }
  private static string Hash(byte[] bytes) => Convert.ToHexStringLower(SHA256.HashData(bytes));
  private static string SourceSetHash(string root) => Hash(Encoding.UTF8.GetBytes(string.Join("\n",
      Directory.GetFiles(root, "*.json", SearchOption.AllDirectories).Select(p =>
          Path.GetRelativePath(root, p).Replace('\\', '/') + " " + Hash(File.ReadAllBytes(p))).Order(StringComparer.Ordinal))));
  private static void Write(string path, object value)
  { using var stream = new FileStream(path, FileMode.CreateNew); JsonSerializer.Serialize(stream, value, Json); }
}
