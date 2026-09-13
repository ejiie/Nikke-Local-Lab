using System.Buffers.Binary;
using System.Data.HashFunction.SpookyHash;
using System.Security.Cryptography;
using System.Text.Json;

namespace ResourceCatalogPreflight;

// Produces only a NEW, offline payload package. Never installs bytes, changes a
// catalog/hash rule, starts a process, or turns a candidate into runtime admission.
internal static class NativeFxChunkCandidate
{
  internal sealed record Patch(string Role, int Ordinal, long Offset, byte[] Before, byte[] After);

  internal static byte[] CompressExact(byte[] decoded, int targetSize)
  {
    Require(decoded.Length is > 0 and <= 16 * 1024 * 1024 && targetSize is > 0 and <= 16 * 1024 * 1024,
        "size_invalid");
    byte[]? best = null;
    try
    {
      foreach (var level in new[] { 1, 3, 6, 9, 15, 19 })
      {
        using var compressor = new ZstdSharp.Compressor(level);
        var packed = compressor.Wrap(decoded).ToArray();
        try
        {
          var gap = targetSize - packed.Length;
          if ((gap == 0 || gap >= 8) && (best is null || packed.Length < best.Length))
          {
            if (best is not null) CryptographicOperations.ZeroMemory(best);
            best = packed.ToArray();
          }
        }
        finally { CryptographicOperations.ZeroMemory(packed); }
      }
      Require(best is not null, "exact_compression_unavailable");
      var output = new byte[targetSize];
      best!.CopyTo(output, 0);
      if (best.Length != targetSize)
      {
        BinaryPrimitives.WriteUInt32LittleEndian(output.AsSpan(best.Length), 0x184D2A50);
        BinaryPrimitives.WriteUInt32LittleEndian(output.AsSpan(best.Length + 4), (uint)(targetSize - best.Length - 8));
      }
      try
      {
        using var decompressor = new ZstdSharp.Decompressor();
        var roundtrip = decompressor.Unwrap(output, decoded.Length).ToArray();
        try { Require(roundtrip.AsSpan().SequenceEqual(decoded), "roundtrip_mismatch"); }
        finally { CryptographicOperations.ZeroMemory(roundtrip); }
        return output;
      }
      catch { CryptographicOperations.ZeroMemory(output); throw; }
    }
    finally { if (best is not null) CryptographicOperations.ZeroMemory(best); }
  }

  internal static void ValidatePatches(IReadOnlyList<Patch> patches, long storeLength)
  {
    Require(patches.Count is > 0 and <= 32, "patch_count_invalid");
    var seen = new HashSet<(string Role, int Ordinal)>();
    long previousEnd = 256;
    foreach (var patch in patches.OrderBy(item => item.Offset))
    {
      Require(patch.Role is "fire" or "wind" or "iron" && patch.Ordinal >= 0 && seen.Add((patch.Role, patch.Ordinal)),
          "patch_identity_invalid");
      Require(patch.Before.Length is > 0 and <= 16 * 1024 * 1024 && patch.Before.Length == patch.After.Length &&
          !patch.Before.AsSpan().SequenceEqual(patch.After), "patch_payload_invalid");
      Require(patch.Offset >= previousEnd && patch.Offset <= storeLength - patch.Before.Length, "patch_range_invalid");
      previousEnd = patch.Offset + patch.Before.Length;
    }
  }

  internal static object Stage(string sourceRoot, string layoutRoot, string layoutSha256, string destination)
  {
    sourceRoot = NativeFxExport.Plain(sourceRoot);
    layoutRoot = NativeFxExport.Plain(layoutRoot);
    var pins = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    byte[] Read(string path, string expected)
    {
      path = NativeFxExport.Plain(path);
      Require(new FileInfo(path).Length is > 0 and <= 64 * 1024 * 1024, "input_size_invalid");
      var bytes = File.ReadAllBytes(path);
      Require(CatalogDatabase.Hash(bytes) == expected, "input_drift");
      Require(!pins.TryGetValue(path, out var previous) || previous == expected, "pin_conflict");
      pins[path] = expected;
      return bytes;
    }
    using var layoutDocument = JsonDocument.Parse(Read(Path.Combine(layoutRoot, "receipt.json"), layoutSha256));
    var layout = layoutDocument.RootElement;
    Require(layout.GetProperty("contractId").GetString() == "nll/native-fx-fixed-layout-candidate/v1" &&
        layout.GetProperty("statusCode").GetString() == "offline_fixed_layout_verified" &&
        !layout.GetProperty("nativeClientExecuted").GetBoolean() && !layout.GetProperty("installedFilesModified").GetBoolean() &&
        layout.GetProperty("runtimeAdmissionStatusCode").GetString() == "not_assessed", "layout_invalid");
    using var sourceDocument = JsonDocument.Parse(Read(Path.Combine(sourceRoot, "receipt.json"),
        layout.GetProperty("sourceCandidateSha256").GetString()!));
    var source = sourceDocument.RootElement;
    Require(source.GetProperty("contractId").GetString() == "nll/native-fx-candidate-receipt/v1" &&
        source.GetProperty("statusCode").GetString() == "offline_native_candidate_verified" &&
        !source.GetProperty("nativeClientExecuted").GetBoolean() && !source.GetProperty("installedFilesModified").GetBoolean() &&
        source.GetProperty("runtimeAdmissionStatusCode").GetString() == "not_assessed", "source_invalid");
    foreach (var field in new[] { "bindingManifestSha256", "exportPlanSha256" })
      Require(source.GetProperty(field).GetString() == layout.GetProperty(field).GetString(), "provenance_mismatch");
    using var bindingDocument = JsonDocument.Parse(Read(Path.Combine(sourceRoot, "native", "binding.private.json"),
        layout.GetProperty("bindingManifestSha256").GetString()!));
    using var planDocument = JsonDocument.Parse(Read(Path.Combine(sourceRoot, "export-plan.private.json"),
        layout.GetProperty("exportPlanSha256").GetString()!));
    var binding = bindingDocument.RootElement;
    var plan = planDocument.RootElement;
    Require(binding.GetProperty("contractId").GetString() == "nll/native-fx-binding/v1" &&
        binding.GetProperty("planSha256").GetString() == layout.GetProperty("exportPlanSha256").GetString() &&
        plan.GetProperty("contractId").GetString() == "nll/native-fx-export-plan/v1", "binding_invalid");
    var outer = plan.GetProperty("outer");
    string PinnedPath(JsonElement item)
    {
      var path = item.GetProperty("path").GetString()!;
      var bytes = Read(path, item.GetProperty("sha256").GetString()!);
      CryptographicOperations.ZeroMemory(bytes);
      return path;
    }
    using var catalog = new CatalogDatabase(PinnedPath(outer.GetProperty("body")), PinnedPath(outer.GetProperty("signature")));
    var chunks = NativeFxExport.Plain(plan.GetProperty("chunkRoot").GetString()!);
    var indexPath = Path.Combine(chunks, "chunk", "store.cdb.idx");
    var index = Read(indexPath, plan.GetProperty("indexSha256").GetString()!);
    CryptographicOperations.ZeroMemory(index);
    var storePath = NativeFxExport.Plain(Path.Combine(chunks, "chunk", "store.cdb"));
    var storeSha256 = NativeFxExport.HashFile(storePath);
    pins[storePath] = storeSha256;
    var storeLength = new FileInfo(storePath).Length;
    using var store = new ChunkStoreReader(chunks);
    Require(store.IndexTrailerVerified && store.IndexSha256 == binding.GetProperty("indexSha256").GetString() &&
        catalog.BodySha256 == binding.GetProperty("outerCatalogSha256").GetString(), "store_binding_invalid");
    destination = NativeFxExport.Plain(destination);
    Require(!Directory.Exists(destination) && !File.Exists(destination) && Directory.Exists(Path.GetDirectoryName(destination)),
        "output_exists_or_parent_missing");
    foreach (var boundary in pins.Keys.Select(path => Path.GetDirectoryName(path)!).Append(sourceRoot).Append(layoutRoot)
        .Append(chunks).Append(@"C:\NLL").Append(@"C:\NIKKE"))
    {
      var prefix = Path.GetFullPath(boundary).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
      var outputPrefix = destination.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
      Require(!outputPrefix.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) &&
          !prefix.StartsWith(outputPrefix, StringComparison.OrdinalIgnoreCase), "output_overlaps_input");
    }
    var rows = layout.GetProperty("entries").EnumerateArray().ToArray();
    var roles = new HashSet<string>(StringComparer.Ordinal);
    var patches = new List<Patch>();
    try
    {
      Require(rows.Length == 3, "roles_invalid");
      foreach (var row in rows)
      {
        var role = row.GetProperty("roleCode").GetString()!;
        Require(role is "fire" or "wind" or "iron" && roles.Add(role) &&
            row.GetProperty("objectPayloadsMatchVerifiedOverlay").GetBoolean() &&
            row.GetProperty("directoryAndOffsetsUnchanged").GetBoolean() && row.GetProperty("changedTransformCount").GetInt32() > 0,
            "roles_invalid");
        var sourceRow = source.GetProperty("entries").EnumerateArray().Single(item => item.GetProperty("roleCode").GetString() == role);
        foreach (var (layoutPin, sourcePin) in new[] { ("original", "original"), ("verifiedOverlay", "overlay") })
          Require(row.GetProperty(layoutPin).GetProperty("sha256").GetString() == sourceRow.GetProperty(sourcePin).GetProperty("sha256").GetString() &&
              row.GetProperty(layoutPin).GetProperty("byteLength").GetInt64() == sourceRow.GetProperty(sourcePin).GetProperty("byteLength").GetInt64(), "payload_binding_invalid");
        var candidate = Read(Path.Combine(layoutRoot, role + ".bundle"), row.GetProperty("fixedLayout").GetProperty("sha256").GetString()!);
        try
        {
          Require(candidate.Length == row.GetProperty("fixedLayout").GetProperty("byteLength").GetInt32() &&
              candidate.Length == row.GetProperty("original").GetProperty("byteLength").GetInt32(), "payload_size_invalid");
          var dependency = binding.GetProperty("bindings").EnumerateArray().Single(item => item.GetProperty("role").GetString() == role)
              .GetProperty("dependencies").EnumerateArray().Single(item => !item.GetProperty("isLocal").GetBoolean());
          Require(dependency.GetProperty("sha256").GetString() == row.GetProperty("original").GetProperty("sha256").GetString(), "payload_binding_invalid");
          var offset = 0;
          var ordinal = 0;
          var beforeCount = patches.Count;
          var original = AddressableFxBinding.Assemble(catalog.Connection, dependency.GetProperty("key").GetString()!, (hash, size, compressedSize) =>
          {
            Require(offset <= candidate.Length - size, "payload_size_invalid");
            var decoded = store.ReadVerified(hash, size, compressedSize);
            var replacement = candidate.AsSpan(offset, size).ToArray();
            try
            {
              if (!decoded.AsSpan().SequenceEqual(replacement))
              {
                using var command = catalog.Connection.CreateCommand();
                // One reference, not merely one distinct file: a reused chunk at a
                // second offset of this same file is also unsafe to replace here.
                command.CommandText = "SELECT COUNT(*) FROM chunk_file_map m JOIN chunks c ON c.chunk_id=m.chunk_id WHERE c.hash=$hash";
                command.Parameters.AddWithValue("$hash", Convert.FromHexString(hash));
                Require(Convert.ToInt64(command.ExecuteScalar(), System.Globalization.CultureInfo.InvariantCulture) == 1, "chunk_shared");
                Require(patches.Count < 32, "patch_count_invalid");
                var compressed = CompressExact(replacement, compressedSize);
                var digest = SpookyHashV2Factory.Instance.Create(new SpookyHashConfig { HashSizeInBits = 128 });
                Require(Convert.ToHexString(digest.ComputeHash(compressed).Hash) != hash, "old_digest_unexpectedly_matches");
                patches.Add(new(role, ordinal, store.Entries[hash].Offset, store.ReadCompressedVerified(hash, compressedSize), compressed));
              }
              offset += size;
              ordinal++;
              return decoded;
            }
            catch { CryptographicOperations.ZeroMemory(decoded); throw; }
            finally { CryptographicOperations.ZeroMemory(replacement); }
          });
          try
          {
            Require(offset == candidate.Length && CatalogDatabase.Hash(original) == row.GetProperty("original").GetProperty("sha256").GetString()
                && patches.Count > beforeCount, "original_assembly_mismatch");
          }
          finally { CryptographicOperations.ZeroMemory(original); }
        }
        finally { CryptographicOperations.ZeroMemory(candidate); }
      }
      ValidatePatches(patches, storeLength);
      void Recheck()
      {
        foreach (var pin in pins) Require(NativeFxExport.HashFile(pin.Key) == pin.Value, "input_drift");
      }
      Recheck();
      // Exclusive reservation with a file prevents concurrent writers from both
      // sealing the same output; an interrupted directory is never reused.
      Directory.CreateDirectory(destination);
      NativeFxExport.WriteNew(Path.Combine(destination, ".reservation"), "nll/native-fx-chunk-stage/v1"u8.ToArray());
      foreach (var patch in patches)
      {
        NativeFxExport.WriteNew(Path.Combine(destination, Name(patch, "before")), patch.Before);
        NativeFxExport.WriteNew(Path.Combine(destination, Name(patch, "after")), patch.After);
      }
      Recheck();
      Require(Directory.GetFileSystemEntries(destination).Length == patches.Count * 2 + 1, "output_drift");
      foreach (var patch in patches)
        Require(NativeFxExport.HashFile(Path.Combine(destination, Name(patch, "before"))) == CatalogDatabase.Hash(patch.Before) &&
            NativeFxExport.HashFile(Path.Combine(destination, Name(patch, "after"))) == CatalogDatabase.Hash(patch.After), "output_drift");
      var manifest = JsonSerializer.SerializeToUtf8Bytes(new
      {
        contractId = "nll/native-fx-chunk-candidate-private/v1", layoutSha256,
        sourceStore = new { path = storePath, sha256 = storeSha256, byteLength = storeLength },
        indexSha256 = store.IndexSha256,
        entries = patches.Select(item => new
        {
          roleCode = item.Role, ordinal = item.Ordinal, offset = item.Offset, byteLength = item.Before.Length,
          beforeFile = Name(item, "before"), beforeSha256 = CatalogDatabase.Hash(item.Before),
          afterFile = Name(item, "after"), afterSha256 = CatalogDatabase.Hash(item.After)
        }),
        oldChunkDigestsMatch = false, nativeClientExecuted = false, runtimeAdmissionStatusCode = "not_assessed"
      });
      NativeFxExport.WriteNew(Path.Combine(destination, "manifest.private.json"), manifest);
      var receipt = new
      {
        contractId = "nll/native-fx-chunk-candidate/v1", layoutSha256,
        manifestSha256 = CatalogDatabase.Hash(manifest), sourceStoreSha256 = storeSha256, sourceStoreByteLength = storeLength,
        changedChunkCount = patches.Count, roleCodes = roles.Order(StringComparer.Ordinal).ToArray(),
        indexTrailerVerified = true, exactCompressedLengthRoundTripVerified = true,
        sourceFilesUnchanged = true, installedFilesModified = false, nativeClientExecuted = false,
        oldChunkDigestsMatch = false, runtimeAdmissionStatusCode = "not_assessed", statusCode = "offline_chunk_candidate_verified"
      };
      NativeFxExport.WriteNew(Path.Combine(destination, "receipt.json"), JsonSerializer.SerializeToUtf8Bytes(receipt));
      return receipt;
    }
    finally
    {
      foreach (var patch in patches) { CryptographicOperations.ZeroMemory(patch.Before); CryptographicOperations.ZeroMemory(patch.After); }
    }
  }

  private static string Name(Patch patch, string suffix) =>
      FormattableString.Invariant($"{patch.Role}-{patch.Ordinal}-{suffix}.chunk");

  private static void Require(bool value, string suffix) => AddressableFxBinding.Require(value, "chunk_candidate_" + suffix);
}
