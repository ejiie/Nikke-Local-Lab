using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace ResourceCatalogPreflight;

// Server initialization inputs only. Original NKDB bodies are copied unchanged;
// this does not register a native resource route or select a voice language.
internal static class ProbeServerLocales
{
  internal static readonly string[] RequiredNames =
      ["Locale_Bgm.lsc", "Locale_Character.lsc", "Locale_CharacterCostume.lsc", "Locale_Item.lsc"];
  internal sealed record Member(string Name, string SourcePath, long Length, string Sha256, string RawDigest);

  internal static Member[] Inspect(SqliteConnection connection, string directory)
  {
    var selected = new Dictionary<string, Member>(StringComparer.Ordinal);
    using var command = connection.CreateCommand();
    command.CommandText = "SELECT key,hex(hash),size FROM files_rawtype";
    using var rows = command.ExecuteReader();
    while (rows.Read())
    {
      var key = rows.GetString(0);
      var name = key.Split('/')[^1];
      if (!RequiredNames.Contains(name, StringComparer.Ordinal)) continue;
      if (key.Split('/').Any(part => part is "" or "." or "..") || key.Contains('\\') || key.Contains(':'))
        throw new PreflightException("resource_server_locale_key_invalid");
      if (selected.ContainsKey(name)) throw new PreflightException("resource_server_locale_ambiguous");
      var length = rows.GetInt64(2);
      if (length is < 36 or > 64 * 1024 * 1024) throw new PreflightException("resource_server_locale_size_invalid");
      var rawDigest = rows.GetString(1).ToLowerInvariant();
      var path = CatalogLinkageProbe.ResolveRawFile(connection, directory, key);
      using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
      var digest = Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
      using var sealedFile = new SealedResourceFile(path, length, digest, rawDigest);
      if (!sealedFile.ReadRange(0, 4).AsSpan().SequenceEqual("NKDB"u8))
        throw new PreflightException("resource_server_locale_container_invalid");
      selected.Add(name, new(name, path, length, digest, rawDigest));
    }
    if (selected.Count != RequiredNames.Length) throw new PreflightException("resource_server_locale_missing");
    return RequiredNames.Select(name => selected[name]).ToArray();
  }

  internal static object Stage(string source, string destination, string catalogHash, string signatureHash)
  {
    var target = Path.GetFullPath(destination);
    const string parent = @"C:\NLL\Staging\ResourceProbeServerInputs";
    if (!target.StartsWith(parent + @"\", StringComparison.OrdinalIgnoreCase) ||
        !Guid.TryParseExact(Path.GetRelativePath(parent, target), "D", out var uid) || Directory.Exists(target))
      throw new PreflightException("resource_server_locale_target_invalid");
    for (DirectoryInfo? entry = new DirectoryInfo(target); entry is not null; entry = entry.Parent)
      if (entry.Exists && (entry.Attributes & FileAttributes.ReparsePoint) != 0)
        throw new PreflightException("resource_server_locale_reparse");
    var body = Path.Combine(source, "catalog.ndb");
    var signature = body + ".nds";
    using var bodySeal = new SealedResourceFile(body, new FileInfo(body).Length, catalogHash);
    using var signatureSeal = new SealedResourceFile(signature, 96, signatureHash);
    using var catalog = new CatalogDatabase(body, signature);
    if (CatalogInspection.Read(catalog).LayoutCode != "chunk_catalog_v1")
      throw new PreflightException("resource_chunk_layout_required");
    var members = Inspect(catalog.Connection, source);
    // All source references resolve and verify before any output is created.
    Directory.CreateDirectory(target);
    foreach (var member in members)
    {
      using var input = new SealedResourceFile(member.SourcePath, member.Length, member.Sha256, member.RawDigest);
      using var output = new FileStream(Path.Combine(target, member.Name), FileMode.CreateNew, FileAccess.Write, FileShare.None);
      for (long offset = 0; offset < member.Length; offset += 1024 * 1024)
        output.Write(input.ReadRange(offset, (int)Math.Min(1024 * 1024, member.Length - offset)));
      output.Flush(flushToDisk: true);
    }
    var receipt = new { contractId = "nll/resource-probe-server-locales/v1", assessmentUid = uid,
      status = "four_local_server_inputs_verified", catalogSha256 = catalogHash, signatureSha256 = signatureHash,
      members = members.Select((member, index) => new { roleCode = "server_locale_" + index, member.Length, member.Sha256 }),
      originalBytesPreserved = true, sourceModified = false, nativeAdmission = "not_evaluated" };
    using var receiptFile = new FileStream(Path.Combine(target, "locales.receipt.json"), FileMode.CreateNew, FileAccess.Write, FileShare.None);
    JsonSerializer.Serialize(receiptFile, receipt, new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase });
    receiptFile.Flush(flushToDisk: true);
    return receipt;
  }
}
