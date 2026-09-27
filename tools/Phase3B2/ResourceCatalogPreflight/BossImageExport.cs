using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Data.Sqlite;

namespace ResourceCatalogPreflight;

// Presentation only: exact image aliases select installed bundles. No downloads,
// client settings or runtime asset installation are involved.
internal static class BossImageExport
{
  internal sealed record Candidate(string Bundle, string Quality);
  internal sealed record Image(string Name, string StatusCode, string? Bundle = null,
      string? Sha256 = null, string? Quality = null);

  internal static Candidate[] Find(SqliteConnection db, string name)
  {
    Require(Regex.IsMatch(name, @"\Afull_[A-Za-z0-9_]{1,128}\z"), "name_invalid");
    using var command = db.CreateCommand();
    command.CommandText = """
        SELECT DISTINCT b.internal_id
        FROM keys k JOIN key_entries ke ON ke.key_rowid=k.rowid
        JOIN entries e ON e.rowid=ke.entry_rowid
        JOIN provider_ids ap ON ap.rowid=e.provider_id_rowid
        JOIN key_entries de ON de.key_rowid=e.dependency_key_rowid
        JOIN entries be ON be.rowid=de.entry_rowid
        JOIN internal_ids b ON b.rowid=be.internal_id_rowid
        JOIN provider_ids bp ON bp.rowid=be.provider_id_rowid
        JOIN entry_data d ON d.rowid=be.data_rowid
        WHERE k.key=$name COLLATE BINARY AND d.is_local=0
          AND ap.provider_id='UnityEngine.ResourceManagement.ResourceProviders.BundledAssetProvider'
          AND bp.provider_id='UnityEngine.ResourceManagement.ResourceProviders.AssetBundleProvider'
        """;
    command.Parameters.AddWithValue("$name", name);
    using var reader = command.ExecuteReader();
    var candidates = new List<Candidate>();
    while (reader.Read())
    {
      var bundle = reader.GetString(0);
      Require(candidates.Count < 8 && Regex.IsMatch(bundle, @"\A[A-Za-z0-9_()\-]{1,512}\.bundle\z"), "binding_invalid");
      // Quality is explicitly encoded by the game's bundle group. Unknown
      // groups remain unresolved; never guess another boss from a filename.
      var quality = bundle.Contains("(hd)", StringComparison.Ordinal) ? "hd" :
          bundle.Contains("(sd)", StringComparison.Ordinal) ? "sd" : "unresolved";
      candidates.Add(new(bundle, quality));
    }
    Require(candidates.All(c => c.Quality != "unresolved") &&
        candidates.GroupBy(c => c.Quality).All(g => g.Count() == 1), "binding_ambiguous");
    return candidates.OrderBy(c => c.Quality == "hd" ? 0 : 1).ToArray();
  }

  internal static Candidate? Select(Candidate[] candidates, Func<string, bool> installed) =>
      candidates.FirstOrDefault(c => installed(c.Bundle));

  internal static bool Installed(SqliteConnection db, ChunkStoreReader store, string bundle)
  {
    using var command = db.CreateCommand();
    command.CommandText = """
        SELECT hex(c.hash) FROM files_chunktype f
        JOIN chunk_file_map m ON m.file_id=f.file_id JOIN chunks c ON c.chunk_id=m.chunk_id WHERE f.key=$key
        """;
    command.Parameters.AddWithValue("$key", bundle);
    using var reader = command.ExecuteReader();
    var count = 0;
    while (reader.Read()) { count++; if (!store.Entries.ContainsKey(reader.GetString(0))) return false; }
    return count > 0;
  }

  internal static object Export(string source, string hintsPath, string hintsHash, string destination)
  {
    source = NativeFxExport.Plain(source); hintsPath = NativeFxExport.Plain(hintsPath);
    Require(new FileInfo(hintsPath).Length is > 0 and <= 1048576 &&
        NativeFxExport.HashFile(hintsPath) == hintsHash, "hints_invalid");
    using var hints = JsonDocument.Parse(File.ReadAllBytes(hintsPath));
    Require(hints.RootElement.GetProperty("contractId").GetString() == "nll/private-boss-season-images/v1", "hints_invalid");
    var names = hints.RootElement.GetProperty("images").EnumerateArray()
        .Select(row => row.GetProperty("monsterImage").GetString()!).Distinct(StringComparer.Ordinal).ToArray();
    Require(names.Length <= 1000, "hints_invalid");
    destination = ChunkFileAssembler.ValidateDestination(source, destination);
    using var outer = new CatalogDatabase(Path.Combine(source, "catalog.ndb"), Path.Combine(source, "catalog.ndb.nds"));
    var body = CatalogLinkageProbe.ResolveRawFile(outer, source, "catalog.db");
    var signature = CatalogLinkageProbe.ResolveRawFile(outer, source, "catalog.db.nds");
    using var inner = new CatalogDatabase(body, signature);
    using var store = new ChunkStoreReader(source);
    Directory.CreateDirectory(destination);
    var exported = new Dictionary<string, (string Leaf, string Hash)>(StringComparer.Ordinal);
    var rows = new List<Image>();
    foreach (var name in names)
    {
      try
      {
        var selected = Select(Find(inner.Connection, name), bundle => Installed(outer.Connection, store, bundle));
        if (selected is null) { rows.Add(new(name, "not_installed")); continue; }
        if (!exported.TryGetValue(selected.Bundle, out var payload))
        {
          var bytes = AddressableFxBinding.Assemble(outer.Connection, selected.Bundle, store.ReadVerified);
          var hash = CatalogDatabase.Hash(bytes);
          var leaf = hash + ".bundle";
          if (!File.Exists(Path.Combine(destination, leaf)))
            using (var file = new FileStream(Path.Combine(destination, leaf), FileMode.CreateNew, FileAccess.Write)) file.Write(bytes);
          payload = (leaf, hash); exported.Add(selected.Bundle, payload);
        }
        rows.Add(new(name, "resolved", payload.Leaf, payload.Hash, selected.Quality));
      }
      catch (PreflightException) { rows.Add(new(name, "unresolved")); }
    }
    Require(NativeFxExport.HashFile(Path.Combine(source, "catalog.ndb")) == outer.BodySha256 &&
        NativeFxExport.HashFile(body) == inner.BodySha256 && NativeFxExport.HashFile(hintsPath) == hintsHash,
        "source_changed");
    var options = new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true };
    File.WriteAllText(Path.Combine(destination, "images.private.json"), JsonSerializer.Serialize(new {
      contractId = "nll/local-boss-image-bundles/v1", hintsSha256 = hintsHash,
      outerCatalogSha256 = outer.BodySha256, innerCatalogSha256 = inner.BodySha256,
      indexSha256 = store.IndexSha256, images = rows }, options));
    return new { contractId = "nll/local-boss-image-export/v1", requestedImageCount = rows.Count,
      resolvedImageCount = rows.Count(r => r.StatusCode == "resolved"), bundleCount = exported.Count,
      sourceModified = false, networkRequested = false };
  }

  private static void Require(bool value, string suffix)
  { if (!value) throw new PreflightException("resource_boss_image_" + suffix); }
}
