using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Data.Sqlite;

namespace ResourceCatalogPreflight;

internal static class NativeBehaviorExport
{
  internal sealed record Bundle(string Key, bool IsLocal);

  internal static Bundle Resolve(SqliteConnection db)
  {
    using var command = db.CreateCommand();
    command.CommandText = """
        SELECT DISTINCT i.internal_id,d.is_local FROM entries e
        JOIN internal_ids i ON i.rowid=e.internal_id_rowid
        JOIN provider_ids p ON p.rowid=e.provider_id_rowid
        JOIN entry_data d ON d.rowid=e.data_rowid
        WHERE p.provider_id='UnityEngine.ResourceManagement.ResourceProviders.AssetBundleProvider'
          AND i.internal_id GLOB 'externalbehavior_assets_all_*.bundle'
        """;
    using var reader = command.ExecuteReader();
    var rows = new List<Bundle>();
    while (reader.Read())
    {
      var key = reader.GetString(0);
      Require(rows.Count < 2 && Regex.IsMatch(key, @"\Aexternalbehavior_assets_all_[0-9a-f]+\.bundle\z") &&
          !reader.IsDBNull(1) && reader.GetInt64(1) is 0 or 1, "binding_invalid");
      rows.Add(new(key, reader.GetInt64(1) == 1));
    }
    Require(rows.Count == 1, rows.Count == 0 ? "bundle_missing" : "bundle_ambiguous");
    return rows[0];
  }

  internal static object Export(string planPath, string planSha256, string destination)
  {
    planPath = NativeFxExport.Plain(planPath);
    Require(new FileInfo(planPath).Length is > 0 and <= 1048576 &&
        NativeFxExport.HashFile(planPath) == planSha256, "plan_drift");
    using var document = JsonDocument.Parse(File.ReadAllBytes(planPath));
    var plan = document.RootElement;
    Require(plan.GetProperty("contractId").GetString() == "nll/native-fx-export-plan/v1", "plan_invalid");
    var pins = new List<(string Path, string Hash)> { (planPath, planSha256) };
    string Pin(JsonElement value)
    {
      var path = NativeFxExport.Plain(value.GetProperty("path").GetString()!);
      var hash = value.GetProperty("sha256").GetString()!;
      Require(Regex.IsMatch(hash, "\\A[0-9a-f]{64}\\z") && NativeFxExport.HashFile(path) == hash, "input_drift");
      pins.Add((path, hash));
      return path;
    }
    CatalogDatabase Catalog(string role) => new(Pin(plan.GetProperty(role).GetProperty("body")),
        Pin(plan.GetProperty(role).GetProperty("signature")));
    using var embedded = Catalog("embedded");
    using var inner = Catalog("inner");
    using var outer = Catalog("outer");
    var chunks = NativeFxExport.Plain(plan.GetProperty("chunkRoot").GetString()!);
    var local = NativeFxExport.Plain(plan.GetProperty("localBundleRoot").GetString()!);
    Require(CatalogInspection.Read(outer).LayoutCode == "chunk_catalog_v1" &&
        NativeFxExport.HashFile(CatalogLinkageProbe.ResolveRawFile(outer, chunks, "catalog.db")) == inner.BodySha256 &&
        NativeFxExport.HashFile(CatalogLinkageProbe.ResolveRawFile(outer, chunks, "catalog.db.nds")) == inner.SignatureSha256 &&
        NativeFxExport.HashFile(Path.Combine(chunks, "catalog.ndb")) == outer.BodySha256 &&
        NativeFxExport.HashFile(Path.Combine(chunks, "catalog.ndb.nds")) == outer.SignatureSha256, "catalog_link_mismatch");
    var index = NativeFxExport.Plain(Path.Combine(chunks, "chunk", "store.cdb.idx"));
    NativeFxExport.Plain(Path.Combine(chunks, "chunk", "store.cdb"));
    var indexHash = plan.GetProperty("indexSha256").GetString()!;
    pins.Add((index, indexHash));
    using var store = new ChunkStoreReader(chunks);
    Require(store.IndexSha256 == indexHash, "index_drift");
    var bundle = Resolve(inner.Connection);
    Require(bundle == Resolve(embedded.Connection), "catalog_disagreement");
    byte[] bytes;
    if (bundle.IsLocal)
    {
      var path = NativeFxExport.Plain(Path.Combine(local, bundle.Key));
      Require(new FileInfo(path).Length is > 0 and <= 64 * 1024 * 1024, "bundle_size_invalid");
      bytes = File.ReadAllBytes(path);
      pins.Add((path, CatalogDatabase.Hash(bytes)));
    }
    else bytes = AddressableFxBinding.Assemble(outer.Connection, bundle.Key, store.ReadVerified);
    try
    {
      Require(bytes.AsSpan().StartsWith("UnityFS\0"u8), "bundle_format_invalid");
      destination = NativeFxExport.Plain(destination);
      Require(!Directory.Exists(destination) && !File.Exists(destination) &&
          Directory.Exists(Path.GetDirectoryName(destination)), "output_invalid");
      foreach (var boundary in pins.Select(p => Path.GetDirectoryName(p.Path)!).Append(chunks).Append(local)
          .Append(@"C:\NLL").Append(@"C:\NIKKE"))
      {
        var prefix = Path.GetFullPath(boundary).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        var outputPrefix = destination.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        Require(!outputPrefix.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) &&
            !prefix.StartsWith(outputPrefix, StringComparison.OrdinalIgnoreCase), "output_overlaps_input");
      }
      foreach (var pin in pins) Require(NativeFxExport.HashFile(pin.Path) == pin.Hash, "input_drift");
      Directory.CreateDirectory(destination);
      var hash = CatalogDatabase.Hash(bytes);
      var path = Path.Combine(destination, bundle.Key);
      NativeFxExport.WriteNew(path, bytes);
      foreach (var pin in pins) Require(NativeFxExport.HashFile(pin.Path) == pin.Hash, "input_drift");
      Require(NativeFxExport.HashFile(path) == hash, "output_drift");
      return new { contractId = "nll/native-behavior-export/v1", planSha256,
        statusCode = "offline_payload_bound", bundle = bundle.Key, sha256 = hash, byteLength = bytes.Length,
        innerCatalogSha256 = inner.BodySha256, outerCatalogSha256 = outer.BodySha256,
        indexSha256 = indexHash, sourceMutationPerformed = false, nativeClientExecuted = false };
    }
    finally { CryptographicOperations.ZeroMemory(bytes); }
  }

  private static void Require(bool condition, string code)
  { if (!condition) throw new PreflightException("resource_behavior_" + code); }
}
