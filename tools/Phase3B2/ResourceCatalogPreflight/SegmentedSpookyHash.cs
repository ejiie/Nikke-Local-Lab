using System.Buffers.Binary;
using System.Data.HashFunction.SpookyHash;
using System.Security.Cryptography;

namespace ResourceCatalogPreflight;

// Observed patch raw-file rule: each fixed-size block uses the preceding 128-bit
// result as its seeds. Verified against all 189 installed raw references, including
// 83 >128 KiB files that differ from ordinary streaming SpookyHash. This is an
// integrity checksum, not publisher authentication or native route/version proof.
internal static class SegmentedSpookyHash
{
  internal static byte[] Compute(Stream source, long length, int blockSize = 128 * 1024)
  {
    if (length < 0 || blockSize is < 1 or > 1024 * 1024)
      throw new PreflightException("resource_hash_dimensions_invalid");
    var buffer = new byte[blockSize];
    var state = new byte[16];
    try
    {
      long remaining = length;
      do
      {
        var count = (int)Math.Min(remaining, blockSize);
        source.ReadExactly(buffer.AsSpan(0, count));
        var hash = SpookyHashV2Factory.Instance.Create(new SpookyHashConfig
        {
          HashSizeInBits = 128,
          Seed = BinaryPrimitives.ReadUInt64LittleEndian(state),
          Seed2 = BinaryPrimitives.ReadUInt64LittleEndian(state.AsSpan(8))
        });
        using var block = new MemoryStream(buffer, 0, count, writable: false);
        var next = hash.ComputeHash(block).Hash;
        CryptographicOperations.ZeroMemory(state);
        state = next;
        remaining -= count;
      } while (remaining > 0);
      return state;
    }
    catch { CryptographicOperations.ZeroMemory(state); throw; }
    finally { CryptographicOperations.ZeroMemory(buffer); }
  }
}
