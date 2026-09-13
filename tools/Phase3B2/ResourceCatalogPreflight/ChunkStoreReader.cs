using System.Buffers.Binary;
using System.Data.HashFunction.SpookyHash;

namespace ResourceCatalogPreflight;

internal sealed class ChunkStoreReader : IDisposable
{
  internal readonly record struct Location(long Offset, int Length);
  private readonly FileStream store;
  private readonly object gate = new();
  private readonly ISpookyHashV2 spooky = SpookyHashV2Factory.Instance.Create(new SpookyHashConfig { HashSizeInBits = 128 });
  private ZstdSharp.Decompressor? zstd;
  internal IReadOnlyDictionary<string, Location> Entries { get; }
  internal string IndexSha256 { get; }
  internal bool IndexTrailerVerified { get; }

  internal ChunkStoreReader(string directory)
  {
    var indexPath = Path.Combine(directory, "chunk", "store.cdb.idx");
    var storePath = Path.Combine(directory, "chunk", "store.cdb");
    if (new FileInfo(indexPath).Length is < 28 or > 64 * 1024 * 1024)
      throw new PreflightException("resource_chunk_index_size_invalid");
    var index = File.ReadAllBytes(indexPath);
    if (!index.AsSpan(0, 8).SequenceEqual(new byte[] { 67, 73, 68, 88, 1, 0, 0, 0 }))
      throw new PreflightException("resource_chunk_index_format_unsupported");
    var count = BinaryPrimitives.ReadUInt32LittleEndian(index.AsSpan(8));
    if (12UL + count * 28UL + 16UL != (ulong)index.Length)
      throw new PreflightException("resource_chunk_index_length_invalid");
    IndexSha256 = CatalogDatabase.Hash(index);
    IndexTrailerVerified = ChunkIndexDigest.Compute(index.AsSpan(0, index.Length - 16))
        .AsSpan().SequenceEqual(index.AsSpan(index.Length - 16));
    store = new FileStream(storePath, FileMode.Open, FileAccess.Read, FileShare.Read);
    try
    {
      var header = new byte[256];
      store.ReadExactly(header);
      if (!header.AsSpan(0, 8).SequenceEqual(new byte[] { 67, 66, 76, 66, 1, 0, 0, 0 }))
        throw new PreflightException("resource_chunk_store_format_unsupported");
      var entries = new Dictionary<string, Location>(StringComparer.Ordinal);
      for (var i = 0; i < count; i++)
      {
        var record = index.AsSpan(12 + i * 28, 28);
        var hash = Convert.ToHexString(record[..16]);
        var offset = BinaryPrimitives.ReadInt64LittleEndian(record.Slice(16, 8));
        var length = BinaryPrimitives.ReadInt32LittleEndian(record.Slice(24, 4));
        if (offset < 256 || length is < 1 or > 16 * 1024 * 1024 || offset > store.Length - length ||
            !entries.TryAdd(hash, new Location(offset, length)))
          throw new PreflightException("resource_chunk_index_range_invalid");
      }
      long previousEnd = 256;
      foreach (var location in entries.Values.OrderBy(location => location.Offset))
      {
        if (location.Offset < previousEnd) throw new PreflightException("resource_chunk_index_ranges_overlap");
        previousEnd = location.Offset + location.Length;
      }
      Entries = entries;
    }
    catch { Dispose(); throw; }
  }

  internal byte[] ReadVerified(string hash, int originalSize, int compressedSize)
  {
    if (originalSize is < 1 or > 16 * 1024 * 1024)
      throw new PreflightException("resource_chunk_original_size_invalid");
    lock (gate)
    {
      var compressed = ReadCompressedVerified(hash, compressedSize);
      try
      {
        zstd ??= new ZstdSharp.Decompressor();
        var decoded = zstd.Unwrap(compressed, originalSize);
        if (decoded.Length != originalSize) throw new PreflightException("resource_chunk_decompressed_size_mismatch");
        return decoded.ToArray();
      }
      finally { System.Security.Cryptography.CryptographicOperations.ZeroMemory(compressed); }
    }
  }

  // Pak offsets describe compressed source bytes, not decoded assets or physical
  // CDB offsets. Range providers must preserve these bytes without re-encoding.
  internal byte[] ReadCompressedVerified(string hash, int compressedSize)
  {
    lock (gate)
    {
      if (!Entries.TryGetValue(hash, out var location)) throw new PreflightException("resource_chunk_member_missing");
      if (location.Length != compressedSize) throw new PreflightException("resource_chunk_catalog_size_mismatch");
      var compressed = new byte[location.Length];
      store.Position = location.Offset;
      store.ReadExactly(compressed);
      if (Convert.ToHexString(spooky.ComputeHash(compressed).Hash) != hash)
      {
        System.Security.Cryptography.CryptographicOperations.ZeroMemory(compressed);
        throw new PreflightException("resource_chunk_digest_mismatch");
      }
      return compressed;
    }
  }

  public void Dispose() { lock (gate) { store?.Dispose(); zstd?.Dispose(); } }
}
