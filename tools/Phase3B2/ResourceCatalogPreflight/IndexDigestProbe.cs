using System.Data.HashFunction.SpookyHash;
using System.Security.Cryptography;

namespace ResourceCatalogPreflight;

internal static class IndexDigestProbe
{
  internal static object Inspect(string directory)
  {
    var path = Path.Combine(directory, "chunk", "store.cdb.idx");
    if (new FileInfo(path).Length is < 28 or > 64 * 1024 * 1024)
      throw new PreflightException("resource_chunk_index_size_invalid");
    var index = File.ReadAllBytes(path);
    var trailer = index.AsSpan(index.Length - 16).ToArray();
    var matches = new List<string>();
    var spooky = SpookyHashV2Factory.Instance.Create(new SpookyHashConfig { HashSizeInBits = 128 });
    foreach (var skip in new[] { 0, 4, 8, 12 })
    {
      var count = index.Length - 16 - skip;
      using var prefix = new MemoryStream(index, skip, count, writable: false);
      if (spooky.ComputeHash(prefix).Hash.AsSpan().SequenceEqual(trailer)) matches.Add($"spooky_whole_skip_{skip}");
      prefix.Position = 0;
      if (MD5.HashData(prefix).AsSpan().SequenceEqual(trailer)) matches.Add($"md5_skip_{skip}");
      foreach (var blockSize in new[] { 4096, 16384, 65536, 131072 })
      {
        prefix.Position = 0;
        if (SegmentedSpookyHash.Compute(prefix, count, blockSize).AsSpan().SequenceEqual(trailer))
          matches.Add($"spooky_seeded_{blockSize}_skip_{skip}");
      }
    }
    using var store = new FileStream(Path.Combine(directory, "chunk", "store.cdb"), FileMode.Open, FileAccess.Read, FileShare.Read);
    var header = new byte[256];
    store.ReadExactly(header);
    var sharedHeaderOffsets = Enumerable.Range(0, 241).Where(offset => header.AsSpan(offset, 16).SequenceEqual(trailer)).ToArray();
    return new
    {
      indexByteLength = index.Length,
      indexSha256 = CatalogDatabase.Hash(index),
      trailerAllZero = trailer.All(value => value == 0),
      matches,
      sharedHeaderOffsets,
      nativeReadiness = "not_evaluated",
      sourceMutationPerformed = false
    };
  }
}
