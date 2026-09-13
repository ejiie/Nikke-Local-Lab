using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Data.Sqlite;

namespace ResourceCatalogPreflight;

// Read-only presentation discovery. A name match is a candidate, not permission
// to choose an ambiguous image or evidence of a battle/FX asset binding.
internal static class BossImageReferences
{
  internal static object Inspect(string catalogBody, string catalogSignature, string bodyHash,
      string signatureHash, string hintsPath, string hintsHash)
  {
    foreach (var pair in new[] { (catalogBody, bodyHash), (catalogSignature, signatureHash), (hintsPath, hintsHash) })
      Require(NativeFxExport.HashFile(NativeFxExport.Plain(pair.Item1)) == pair.Item2, "input_drifted");
    Require(new FileInfo(hintsPath).Length is > 0 and <= 1048576, "hints_invalid");
    using var hints = JsonDocument.Parse(File.ReadAllBytes(hintsPath));
    Require(hints.RootElement.GetProperty("schemaVersion").GetInt32() == 1 &&
        hints.RootElement.GetProperty("contractId").GetString() == "nll/private-boss-season-images/v1", "hints_invalid");
    var images = hints.RootElement.GetProperty("images").EnumerateArray().ToArray();
    Require(images.Length is > 0 and <= 1000 && images.Select(row => row.GetProperty("seasonNumber").GetInt32()).Distinct().Count() == images.Length,
        "hints_invalid");
    using var catalog = new CatalogDatabase(catalogBody, catalogSignature);
    var rows = images.Select(row => {
      var season = row.GetProperty("seasonNumber").GetInt32();
      Require(season is > 0 and <= 1000, "hints_invalid");
      var name = row.GetProperty("monsterImage").GetString();
      var candidates = Find(catalog.Connection, name);
      return new { seasonNumber = season, exactNameCandidateCount = candidates.Length,
        statusCode = candidates.Length == 1 ? "presentation_reference_candidate" : "unresolved" };
    }).ToArray();
    foreach (var pair in new[] { (catalogBody, bodyHash), (catalogSignature, signatureHash), (hintsPath, hintsHash) })
      Require(NativeFxExport.HashFile(pair.Item1) == pair.Item2, "input_drifted");
    return new { contractId = "nll/boss-image-reference-inspection/v1", catalogSha256 = bodyHash,
      hintsSha256 = hintsHash, images = rows, nativeClientExecuted = false, sourceModified = false };
  }

  internal static string[] Find(SqliteConnection database, string? name)
  {
    if (name is null) return [];
    Require(Regex.IsMatch(name, "\\Afull_[A-Za-z0-9_]{1,128}\\z", RegexOptions.CultureInvariant), "name_invalid");
    using var command = database.CreateCommand();
    // Parameterized coarse search narrows the scan; the exact basename test
    // rejects suffix collisions and never maps another boss by similarity.
    command.CommandText = "SELECT key FROM keys WHERE instr(key,$name)>0 LIMIT 4097";
    command.Parameters.AddWithValue("$name", name);
    using var reader = command.ExecuteReader();
    var matches = new List<string>();
    var count = 0;
    while (reader.Read())
    {
      Require(++count <= 4096 && !reader.IsDBNull(0), "reference_set_invalid");
      var key = reader.GetString(0);
      Require(key.Length <= 4096, "reference_set_invalid");
      if (key.Contains('\\') || key.Split('/').Any(part => part is "" or "." or "..")) continue;
      var leaf = key.Split('/')[^1];
      if (leaf == name || leaf == name + ".png" || leaf == name + ".asset") matches.Add(key);
    }
    return matches.ToArray(); // Duplicates stay ambiguous, not silently distinct-ed.
  }

  private static void Require(bool value, string suffix)
  {
    if (!value) throw new PreflightException("resource_boss_image_" + suffix);
  }
}
