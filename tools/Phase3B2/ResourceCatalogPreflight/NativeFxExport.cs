using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace ResourceCatalogPreflight;

internal static class NativeFxExport
{
  internal static object Export(string planPath, string planSha256, string destination)
  {
    Plain(planPath);
    AddressableFxBinding.Require(new FileInfo(planPath).Length is > 0 and <= 1024 * 1024, "plan_size_invalid");
    var planBytes = File.ReadAllBytes(planPath);
    AddressableFxBinding.Require(CatalogDatabase.Hash(planBytes) == planSha256, "plan_drift");
    using var document = JsonDocument.Parse(planBytes);
    var plan = document.RootElement;
    AddressableFxBinding.Require(plan.GetProperty("contractId").GetString() == "nll/native-fx-export-plan/v1", "plan_invalid");
    var inputs = new List<(string Path, string Hash)>();
    string Pin(JsonElement value)
    {
      var path = Plain(value.GetProperty("path").GetString()!);
      var hash = value.GetProperty("sha256").GetString()!;
      AddressableFxBinding.Require(Regex.IsMatch(hash, "\\A[0-9a-f]{64}\\z") && HashFile(path) == hash, "input_drift");
      inputs.Add((path, hash));
      return path;
    }
    CatalogDatabase Catalog(string name)
    {
      var item = plan.GetProperty(name);
      return new(Pin(item.GetProperty("body")), Pin(item.GetProperty("signature")));
    }
    using var embedded = Catalog("embedded");
    using var inner = Catalog("inner");
    using var outer = Catalog("outer");
    var chunks = Plain(plan.GetProperty("chunkRoot").GetString()!);
    var local = Plain(plan.GetProperty("localBundleRoot").GetString()!);
    AddressableFxBinding.Require(CatalogInspection.Read(outer).LayoutCode == "chunk_catalog_v1" &&
        HashFile(CatalogLinkageProbe.ResolveRawFile(outer, chunks, "catalog.db")) == inner.BodySha256 &&
        HashFile(CatalogLinkageProbe.ResolveRawFile(outer, chunks, "catalog.db.nds")) == inner.SignatureSha256 &&
        HashFile(Path.Combine(chunks, "catalog.ndb")) == outer.BodySha256 &&
        HashFile(Path.Combine(chunks, "catalog.ndb.nds")) == outer.SignatureSha256, "catalog_link_mismatch");
    var index = Plain(Path.Combine(chunks, "chunk", "store.cdb.idx"));
    Plain(Path.Combine(chunks, "chunk", "store.cdb"));
    var indexHash = plan.GetProperty("indexSha256").GetString()!;
    inputs.Add((index, indexHash));
    using var store = new ChunkStoreReader(chunks);
    AddressableFxBinding.Require(store.IndexSha256 == indexHash, "index_drift");
    var assets = plan.GetProperty("assets").EnumerateArray().ToArray();
    AddressableFxBinding.Require(assets.Length == 4, "roles_invalid");
    var roles = new HashSet<string>(StringComparer.Ordinal);
    var keys = new HashSet<string>(StringComparer.Ordinal);
    var payloads = new List<(string Role, byte[] Bytes)>();
    var bindings = new List<object>();
    try
    {
      foreach (var asset in assets)
      {
        var role = asset.GetProperty("role").GetString()!;
        var key = asset.GetProperty("key").GetString()!;
        AddressableFxBinding.Require(role is "electric" or "fire" or "wind" or "iron" && roles.Add(role) && keys.Add(key), "roles_invalid");
        var first = AddressableFxBinding.Resolve(embedded.Connection, key);
        var second = AddressableFxBinding.Resolve(inner.Connection, key);
        AddressableFxBinding.Require(first.Dependencies.SequenceEqual(second.Dependencies), "catalog_disagreement");
        var dependencies = new List<object>();
        foreach (var dependency in second.Dependencies)
        {
          byte[] bytes;
          if (dependency.IsLocal)
          {
            var path = Plain(Path.Combine(local, dependency.Key));
            AddressableFxBinding.Require(new FileInfo(path).Length is > 0 and <= 64 * 1024 * 1024, "local_bundle_size_invalid");
            bytes = File.ReadAllBytes(path);
            inputs.Add((path, CatalogDatabase.Hash(bytes)));
          }
          else bytes = AddressableFxBinding.Assemble(outer.Connection, dependency.Key, store.ReadVerified);
          try
          {
            AddressableFxBinding.Require(bytes.AsSpan().StartsWith("UnityFS\0"u8), "bundle_format_invalid");
            dependencies.Add(new
            {
              key = dependency.Key,
              isLocal = dependency.IsLocal,
              sha256 = CatalogDatabase.Hash(bytes),
              byteLength = bytes.Length
            });
            if (!dependency.IsLocal) { payloads.Add((role, bytes)); bytes = []; }
          }
          finally { CryptographicOperations.ZeroMemory(bytes); }
        }
        bindings.Add(new { role, assetKey = key, dependencies });
      }
      // Recheck pinned inputs before any output; no folder exists on a failed binding.
      foreach (var input in inputs) AddressableFxBinding.Require(HashFile(input.Path) == input.Hash, "input_drift");
      AddressableFxBinding.Require(HashFile(planPath) == planSha256, "plan_drift");
      destination = Plain(destination);
      AddressableFxBinding.Require(!Directory.Exists(destination) && !File.Exists(destination) &&
          Directory.Exists(Path.GetDirectoryName(destination)), "output_exists_or_parent_missing");
      foreach (var boundary in inputs.Select(item => Path.GetDirectoryName(item.Path)!).Append(chunks).Append(local)
          .Append(@"C:\NIKKE").Append(@"C:\NLL"))
      {
        var prefix = Path.GetFullPath(boundary).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        AddressableFxBinding.Require(!destination.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) &&
            !prefix.StartsWith(destination.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase), "output_overlaps_input");
      }
      Directory.CreateDirectory(destination);
      foreach (var payload in payloads) WriteNew(Path.Combine(destination, payload.Role + ".bundle"), payload.Bytes);
      foreach (var input in inputs) AddressableFxBinding.Require(HashFile(input.Path) == input.Hash, "input_drift");
      AddressableFxBinding.Require(HashFile(planPath) == planSha256 &&
          Directory.GetFileSystemEntries(destination).Length == payloads.Count, "output_drift");
      foreach (var payload in payloads)
        AddressableFxBinding.Require(HashFile(Path.Combine(destination, payload.Role + ".bundle")) ==
            CatalogDatabase.Hash(payload.Bytes), "output_drift");
      var manifest = JsonSerializer.SerializeToUtf8Bytes(new
      {
        contractId = "nll/native-fx-binding/v1",
        planSha256,
        embeddedCatalogSha256 = embedded.BodySha256,
        innerCatalogSha256 = inner.BodySha256,
        outerCatalogSha256 = outer.BodySha256,
        indexSha256 = store.IndexSha256,
        bindings,
        indexTrailerStatusCode = store.IndexTrailerVerified ? ChunkIndexDigest.VerifiedStatusCode : "unresolved",
        statusCode = "offline_payload_bound",
        nativeClientExecuted = false,
        runtimeAdmissionStatusCode = "not_assessed"
      });
      WriteNew(Path.Combine(destination, "binding.private.json"), manifest); // Last; interrupted output is not sealed.
      return new
      {
        contractId = "nll/native-fx-export-receipt/v1",
        planSha256,
        manifestSha256 = CatalogDatabase.Hash(manifest),
        statusCode = "offline_payload_bound",
        assetCount = payloads.Count,
        payloads = payloads.Select(item => new { roleCode = item.Role, byteLength = item.Bytes.Length, sha256 = CatalogDatabase.Hash(item.Bytes) }).ToArray(),
        nativeClientExecuted = false,
        sourceMutationPerformed = false,
        runtimeAdmissionStatusCode = "not_assessed"
      };
    }
    finally { foreach (var payload in payloads) CryptographicOperations.ZeroMemory(payload.Bytes); }
  }

  internal static string Plain(string path)
  {
    AddressableFxBinding.Require(Path.IsPathFullyQualified(path) && !path.StartsWith(@"\\", StringComparison.Ordinal), "path_invalid");
    path = Path.GetFullPath(path);
    AddressableFxBinding.Require(!path[Path.GetPathRoot(path)!.Length..].Contains(':'), "path_invalid");
    for (var current = path; current is not null; current = Path.GetDirectoryName(current))
      if (File.Exists(current) || Directory.Exists(current))
        AddressableFxBinding.Require((File.GetAttributes(current) & FileAttributes.ReparsePoint) == 0, "path_reparse");
    return path;
  }

  internal static string HashFile(string path)
  {
    using var stream = new FileStream(Plain(path), FileMode.Open, FileAccess.Read, FileShare.Read);
    return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
  }

  internal static void WriteNew(string path, byte[] bytes)
  {
    using var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
    stream.Write(bytes);
    stream.Flush(true);
  }
}
