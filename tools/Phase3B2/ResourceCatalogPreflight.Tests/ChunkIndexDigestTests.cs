using System.Buffers.Binary;
using System.Data.HashFunction.SpookyHash;
using ResourceCatalogPreflight;
using Xunit;

namespace ResourceCatalogPreflight.Tests;

public sealed class ChunkIndexDigestTests
{
    private static byte[] Prefix(int count)
    {
        var bytes = new byte[12 + count * 28];
        "CIDX\u0001\0\0\0"u8.CopyTo(bytes);
        BinaryPrimitives.WriteInt32LittleEndian(bytes.AsSpan(8), count);
        for (var i = 12; i < bytes.Length; i++) bytes[i] = (byte)(i * 17 + 3);
        return bytes;
    }

    private static byte[] Hash(byte[] data, ulong first = 0, ulong second = 0) =>
        SpookyHashV2Factory.Instance.Create(new SpookyHashConfig
        { HashSizeInBits = 128, Seed = first, Seed2 = second }).ComputeHash(data).Hash;

    [Fact]
    public void EmptyIndexStillHashesItsHeader()
    {
        var prefix = Prefix(0);
        Assert.Equal(Hash(prefix), ChunkIndexDigest.Compute(prefix));
        Assert.NotEqual(new byte[16], ChunkIndexDigest.Compute(prefix));
    }

    [Fact]
    public void EachRecordUsesBothPreviousHashHalvesAsSeeds()
    {
        var prefix = Prefix(2);
        var header = Hash(prefix[..12]);
        var first = Hash(prefix[12..40], BinaryPrimitives.ReadUInt64LittleEndian(header),
            BinaryPrimitives.ReadUInt64LittleEndian(header.AsSpan(8)));
        var second = Hash(prefix[40..68], BinaryPrimitives.ReadUInt64LittleEndian(first),
            BinaryPrimitives.ReadUInt64LittleEndian(first.AsSpan(8)));
        Assert.Equal(second, ChunkIndexDigest.Compute(prefix));
        Assert.NotEqual(Hash(prefix), second);
        using var uniform = new MemoryStream(prefix);
        Assert.NotEqual(SegmentedSpookyHash.Compute(uniform, prefix.Length, 28), second);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(4)]
    [InlineData(8)]
    [InlineData(11)]
    public void TruncatedHeaderIsRejected(int length) =>
        Assert.Equal("resource_chunk_index_format_unsupported", Assert.Throws<PreflightException>(
            () => ChunkIndexDigest.Compute(Prefix(0).AsSpan(0, length))).Message);

    [Theory]
    [InlineData(0)]
    [InlineData(4)]
    [InlineData(7)]
    public void UnknownMagicOrVersionIsRejected(int offset)
    {
        var prefix = Prefix(0);
        prefix[offset] ^= 1;
        Assert.Equal("resource_chunk_index_format_unsupported", Assert.Throws<PreflightException>(
            () => ChunkIndexDigest.Compute(prefix)).Message);
    }

    [Theory]
    [InlineData(0u)]
    [InlineData(2u)]
    [InlineData(uint.MaxValue)]
    public void WrongCountCannotWrapOrIgnoreBytes(uint count)
    {
        var prefix = Prefix(1);
        BinaryPrimitives.WriteUInt32LittleEndian(prefix.AsSpan(8), count);
        Assert.Equal("resource_chunk_index_length_invalid", Assert.Throws<PreflightException>(
            () => ChunkIndexDigest.Compute(prefix)).Message);
    }

    [Theory]
    [InlineData(39)]
    [InlineData(41)]
    [InlineData(56)]
    public void PartialRecordExtraBytesOrIncludedTrailerIsRejected(int length)
    {
        var prefix = Prefix(1);
        Array.Resize(ref prefix, length);
        Assert.Equal("resource_chunk_index_length_invalid", Assert.Throws<PreflightException>(
            () => ChunkIndexDigest.Compute(prefix)).Message);
    }

    [Theory]
    [InlineData(12)]
    [InlineData(28)]
    [InlineData(36)]
    [InlineData(40)]
    [InlineData(67)]
    public void BothRecordsAndEveryFieldAffectDigest(int offset)
    {
        var prefix = Prefix(2);
        var expected = ChunkIndexDigest.Compute(prefix);
        prefix[offset] ^= 1;
        Assert.NotEqual(expected, ChunkIndexDigest.Compute(prefix));
    }
}
