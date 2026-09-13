using System.Buffers.Binary;
using System.Data.HashFunction.SpookyHash;

namespace ResourceCatalogPreflight;

// CIDX v1 accumulates the 12-byte header, then each 28-byte record separately.
// Every append seeds a new SpookyHash128 with the preceding result. This is not
// a streaming hash of the concatenated bytes and does not authenticate catalogs.
internal static class ChunkIndexDigest
{
    internal const string VerifiedStatusCode = "spooky_header12_records28_seeded_verified";

    internal static byte[] Compute(ReadOnlySpan<byte> prefix)
    {
        if (prefix.Length > 64 * 1024 * 1024 - 16)
            throw new PreflightException("resource_chunk_index_size_invalid");
        if (prefix.Length < 12 || !prefix[..8].SequenceEqual("CIDX\u0001\0\0\0"u8))
            throw new PreflightException("resource_chunk_index_format_unsupported");
        var count = BinaryPrimitives.ReadUInt32LittleEndian(prefix[8..]);
        if (12UL + count * 28UL != (ulong)prefix.Length)
            throw new PreflightException("resource_chunk_index_length_invalid");
        var state = Append(prefix[..12], new byte[16]);
        for (var offset = 12; offset < prefix.Length; offset += 28)
            state = Append(prefix.Slice(offset, 28), state);
        return state;
    }

    private static byte[] Append(ReadOnlySpan<byte> segment, byte[] state) =>
        SpookyHashV2Factory.Instance.Create(new SpookyHashConfig
        {
            HashSizeInBits = 128,
            Seed = BinaryPrimitives.ReadUInt64LittleEndian(state),
            Seed2 = BinaryPrimitives.ReadUInt64LittleEndian(state.AsSpan(8))
        }).ComputeHash(segment.ToArray()).Hash;
}
