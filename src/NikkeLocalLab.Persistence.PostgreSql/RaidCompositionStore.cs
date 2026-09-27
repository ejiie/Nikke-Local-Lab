using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;
using NikkeLocalLab.BattleLog;
using Npgsql;

namespace NikkeLocalLab.Persistence.PostgreSql;

public sealed record RaidCompositionPaths(string ArchiveRoot, string AnalysisRoot);
public sealed record RaidCompositionResult(Guid BattleUid, string Status, DamageComposition? Analysis);

// Derived, versioned files are memoized outside the game path. The existing DB remains
// authoritative for account scope, roster ordinal, log hash and corrected damage.
public sealed class RaidCompositionStore(NpgsqlDataSource data, RaidCompositionPaths paths)
{
  private readonly SemaphoreSlim gate = new(1, 1);
  private static readonly JsonSerializerOptions Json = new() { PropertyNameCaseInsensitive = true };
  private sealed record Archive(Guid BattleUid, Guid AccountUid, string ClientBuild, string Sha256, BattleLogCharacter[] Identities);
  private sealed record CatalogPin(string ClientBuild, string File, string Sha256);

  public async Task<RaidCompositionResult?> GetAsync(Guid account, Guid battle, CancellationToken token)
  {
    string? build = null, hash = null;
    var tab = new Dictionary<int, long>(); var corrected = new List<ProjectileCharacter>();
    await using (var command = data.CreateCommand("""
            SELECT b.payload->>'ClientBuild',a.log_sha256,c.ordinal,c.attack_total_damage,p.projectile_damage,p.excluded_damage
            FROM lab_private_server.raid_battle_observation b
            LEFT JOIN lab_private_server.raid_projectile_analysis a ON a.battle_uid=b.battle_uid AND a.analysis_version=@version AND a.status='ready'
            LEFT JOIN lab_private_server.raid_character_damage c ON c.battle_uid=b.battle_uid
            LEFT JOIN lab_private_server.raid_character_projectile_damage p ON p.battle_uid=c.battle_uid AND p.ordinal=c.ordinal AND p.analysis_version=a.analysis_version
            WHERE b.account_uid=@account AND b.battle_uid=@battle ORDER BY c.ordinal
            """))
    {
      command.Parameters.AddWithValue("account", account); command.Parameters.AddWithValue("battle", battle);
      command.Parameters.AddWithValue("version", ProjectileAnalysis.CurrentVersion);
      await using var reader = await command.ExecuteReaderAsync(token).ConfigureAwait(false);
      var found = false;
      while (await reader.ReadAsync(token).ConfigureAwait(false))
      {
        found = true; build = reader.IsDBNull(0) ? null : reader.GetString(0); hash = reader.IsDBNull(1) ? null : reader.GetString(1);
        if (!reader.IsDBNull(2) && !reader.IsDBNull(3)) tab.Add(reader.GetInt32(2), reader.GetInt64(3));
        if (!reader.IsDBNull(4) && !reader.IsDBNull(5)) corrected.Add(new(reader.GetInt32(2), reader.GetInt64(4), reader.GetInt64(5)));
      }
      if (!found) return null;
    }
    RaidCompositionResult State(string status) => new(battle, status, null);
    if (hash is null || build is null || tab.Count == 0 || corrected.Count != tab.Count) return State("analysis_unavailable");
    if (!Regex.IsMatch(hash, "^[0-9a-f]{64}$")) return State("analysis_unavailable");
    if (!await gate.WaitAsync(TimeSpan.FromSeconds(30), token).ConfigureAwait(false)) return State("busy");
    try
    {
      var archiveBase = Path.Combine(paths.ArchiveRoot, account.ToString("D"), battle.ToString("D"));
      // Preserved pre-archive diagnostics are imported separately; never replace capture-owned files.
      if (!File.Exists(archiveBase + ".private.json") && !File.Exists(archiveBase + ".private.bin"))
        archiveBase = Path.Combine(paths.AnalysisRoot, "imported-logs", account.ToString("D"), battle.ToString("D"));
      if (!File.Exists(archiveBase + ".private.json") || !File.Exists(archiveBase + ".private.bin")) return State("log_missing");
      var archive = JsonSerializer.Deserialize<Archive>(Read(archiveBase + ".private.json", 128 * 1024), Json)!;
      if (archive.BattleUid != battle || archive.AccountUid != account || archive.Sha256 != hash || archive.ClientBuild != build ||
          archive.Identities is null || archive.Identities.Length != tab.Count || archive.Identities.Select(x => x.Ordinal).Distinct().Count() != tab.Count ||
          archive.Identities.Any(x => !tab.TryGetValue(x.Ordinal, out var damage) || damage != x.TabDamage)) return State("source_mismatch");
      var indexPath = Path.Combine(paths.AnalysisRoot, "catalogs", "index.private.json");
      if (!File.Exists(indexPath)) return State("catalog_missing");
      var pins = JsonSerializer.Deserialize<CatalogPin[]>(Read(indexPath, 128 * 1024), Json)!;
      var pin = pins.SingleOrDefault(p => p.ClientBuild == build);
      if (pin is null) return State("catalog_missing");
      if (!Regex.IsMatch(pin.Sha256, "^[0-9a-f]{64}$") || pin.File != pin.Sha256 + ".private.json") return State("catalog_invalid");
      var catalogBytes = Read(Path.Combine(paths.AnalysisRoot, "catalogs", pin.File), 64 * 1024 * 1024);
      if (Hash(catalogBytes) != pin.Sha256) return State("catalog_invalid");
      var raw = Read(archiveBase + ".private.bin", BattleLogProjectileDecoder.MaximumRawBytes);
      if (Hash(raw) != hash) return State("source_mismatch");
      var cache = Path.Combine(paths.AnalysisRoot, DamageComposition.CurrentVersion.Replace('/', '-'), account.ToString("D"), battle.ToString("D"), hash + "-" + pin.Sha256 + ".json");
      if (File.Exists(cache))
      {
        var saved = JsonSerializer.Deserialize<DamageComposition>(Read(cache, 1024 * 1024), Json)!;
        if (saved.Version == DamageComposition.CurrentVersion && saved.LogSha256 == hash && saved.CatalogSha256 == pin.Sha256)
          return new(battle, saved.Status, saved);
        return State("cache_invalid");
      }
      var catalog = JsonSerializer.Deserialize<DamageCatalog>(catalogBytes, Json)!;
      if (catalog.ClientBuild != build) return State("catalog_invalid");
      var projectile = new ProjectileAnalysis("ready", hash, ProjectileAnalysis.CurrentVersion, corrected);
      var analysis = await Task.Run(() => DamageCompositionAnalyzer.Analyze(raw, archive.Identities, projectile, catalog, pin.Sha256), token).ConfigureAwait(false);
      // No failure is cached: a repaired archive/catalog can be retried.
      if (analysis.Status is "ready" or "partial")
      {
        CheckPath(cache); Directory.CreateDirectory(Path.GetDirectoryName(cache)!);
        var temporary = cache + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try { await File.WriteAllBytesAsync(temporary, JsonSerializer.SerializeToUtf8Bytes(analysis), token).ConfigureAwait(false); File.Move(temporary, cache); }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
      }
      return new(battle, analysis.Status, analysis);
    }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException or InvalidOperationException or ArgumentException)
    { return State("analysis_failed"); }
    finally { gate.Release(); }
  }
  private static byte[] Read(string path, int limit)
  {
    CheckPath(path);
    using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
    if (stream.Length > limit) throw new InvalidDataException();
    var bytes = new byte[checked((int)stream.Length)]; stream.ReadExactly(bytes); return bytes;
  }
  private static void CheckPath(string path)
  {
    for (string? p = Path.GetFullPath(path); p is not null; p = Path.GetDirectoryName(p))
      if ((File.Exists(p) || Directory.Exists(p)) && (File.GetAttributes(p) & FileAttributes.ReparsePoint) != 0) throw new IOException("analysis_path_invalid");
  }
  private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
}
