using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Data.Sqlite;

namespace ResourceCatalogPreflight;

// Copies original local locale containers for presentation only. No download,
// client-local mutation, signature rewrite, server/game startup or admission.
internal static class BossCatalogLocales
{
  internal sealed record Member(string Path, long Length, string Sha256, string RawHash);
  internal static bool IsLocaleName(string name) => Regex.IsMatch(name, "\\ALocale_[A-Za-z0-9_]{1,64}\\.lsc\\z", RegexOptions.CultureInvariant);
  internal static object Stage(string source, string destination, string catalogHash, string signatureHash)
  {
    source = NativeFxExport.Plain(source);
    destination = NativeFxExport.Plain(destination);
    if (Directory.Exists(destination) || File.Exists(destination) ||
        destination.StartsWith(@"C:\NIKKE", StringComparison.OrdinalIgnoreCase) ||
        destination.StartsWith(source + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) ||
        source.StartsWith(destination + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
      throw new PreflightException("resource_boss_locale_target_invalid");
    var body = Path.Combine(source, "catalog.ndb");
    var signature = body + ".nds";
    using var bodySeal = new SealedResourceFile(body, new FileInfo(body).Length, catalogHash);
    using var signatureSeal = new SealedResourceFile(signature, 96, signatureHash);
    using var catalog = new CatalogDatabase(body, signature);
    var members = Inspect(catalog.Connection, source);
    Directory.CreateDirectory(destination);
    foreach (var member in members.OrderBy(pair => pair.Key, StringComparer.Ordinal))
    {
      var row = member.Value;
      using var input = new SealedResourceFile(row.Path, row.Length, row.Sha256, row.RawHash);
      using var output = new FileStream(Path.Combine(destination, member.Key), FileMode.CreateNew, FileAccess.Write, FileShare.None);
      for (long offset = 0; offset < row.Length; offset += 1048576)
        output.Write(input.ReadRange(offset, (int)Math.Min(1048576, row.Length - offset)));
      output.Flush(true);
    }
    // Re-read whole input/output hashes at the final seal, not just pre-copy.
    if (NativeFxExport.HashFile(body) != catalogHash || NativeFxExport.HashFile(signature) != signatureHash ||
        members.Any(pair => NativeFxExport.HashFile(pair.Value.Path) != pair.Value.Sha256 ||
          NativeFxExport.HashFile(Path.Combine(destination, pair.Key)) != pair.Value.Sha256))
      throw new PreflightException("resource_boss_locale_input_drifted");
    var result = new { schemaVersion = 1, contractId = "nll/boss-catalog-locales/v1",
      catalogSha256 = catalogHash, signatureSha256 = signatureHash, sourceModified = false,
      clientStarted = false, members = members.OrderBy(pair => pair.Key, StringComparer.Ordinal)
          .Select(pair => new { name = pair.Key, sha256 = pair.Value.Sha256, byteLength = pair.Value.Length }) };
    using var receipt = new FileStream(Path.Combine(destination, "receipt.json"), FileMode.CreateNew, FileAccess.Write, FileShare.None);
    JsonSerializer.Serialize(receipt, result);
    receipt.Flush(true);
    return result;
  }

  internal static Dictionary<string, Member> Inspect(SqliteConnection connection, string source)
  {
    var members = new Dictionary<string, Member>(StringComparer.Ordinal);
    using (var command = connection.CreateCommand())
    {
      command.CommandText = "SELECT key,hex(hash),size FROM files_rawtype";
      using var rows = command.ExecuteReader();
      while (rows.Read())
      {
        var key = rows.GetString(0);
        var name = key.Split('/')[^1];
        if (!IsLocaleName(name)) continue;
        if (key.Contains('\\') || key.Contains(':') || key.Split('/').Any(part => part is "" or "." or "..") || members.ContainsKey(name))
          throw new PreflightException("resource_boss_locale_reference_invalid");
        var length = rows.GetInt64(2);
        if (length is < 36 or > 134217728 || members.Count >= 64)
          throw new PreflightException("resource_boss_locale_size_invalid");
        var path = NativeFxExport.Plain(CatalogLinkageProbe.ResolveRawFile(connection, source, key));
        var digest = NativeFxExport.HashFile(path);
        var rawHash = rows.GetString(1).ToLowerInvariant();
        using var seal = new SealedResourceFile(path, length, digest, rawHash);
        if (!seal.ReadRange(0, 4).AsSpan().SequenceEqual("NKDB"u8))
          throw new PreflightException("resource_boss_locale_container_invalid");
        members.Add(name, new(path, length, digest, rawHash));
      }
    }
    if (members.Count == 0 || members.Values.Sum(row => row.Length) > 536870912)
      throw new PreflightException("resource_boss_locale_set_invalid");
    return members;
  }
}
