using System.Buffers.Binary;
using System.IO.Compression;
using System.Security.Cryptography;
using EpinelPS.Data;
using ResourceCatalogPreflight;
using Xunit;

namespace ResourceCatalogPreflight.Tests;

public sealed class BoundedCatalogDecoderTests
{
    [Fact]
    public void SyntheticSingleSegmentMatchesPinnedExternalDecoder()
    {
        var expected = "synthetic catalog bytes only"u8.ToArray();
        var container = Encode(expected, expected.Length);
        Assert.Equal(expected, BoundedCatalogDecoder.Decode(container));
        Assert.Equal(NkdbDecryptor.Decrypt(container), BoundedCatalogDecoder.Decode(container));
    }

    [Fact]
    public void SmallDeclaredSizeCannotHideLargeInflatedBody()
    {
        var container = Encode(new byte[128 * 1024], 64);
        Assert.Equal("resource_catalog_expansion_limit_exceeded", Assert.Throws<PreflightException>(
            () => BoundedCatalogDecoder.Decode(container)).Message);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(39)]
    [InlineData(int.MaxValue)]
    public void InvalidOffsetsFailBeforeDecrypting(int offset)
    {
        var container = Encode([1, 2, 3], 3);
        BinaryPrimitives.WriteInt32BigEndian(container.AsSpan(32), offset);
        Assert.Equal("resource_catalog_segment_range_invalid", Assert.Throws<PreflightException>(
            () => BoundedCatalogDecoder.Decode(container)).Message);
    }

    [Fact]
    public void TrailingUnmappedBytesAreRejected()
    {
        var container = Encode([1, 2, 3], 3).Concat(new byte[] { 0 }).ToArray();
        Assert.Equal("resource_catalog_segment_range_invalid", Assert.Throws<PreflightException>(
            () => BoundedCatalogDecoder.Decode(container)).Message);
    }

    private static byte[] Encode(byte[] payload, int declaredSegmentSize)
    {
        using var compressed = new MemoryStream();
        using (var zlib = new ZLibStream(compressed, CompressionMode.Compress, leaveOpen: true)) zlib.Write(payload);
        var packed = compressed.ToArray();
        var body = new byte[40 + packed.Length];
        new byte[] { 78, 75, 68, 66, 0, 0, 0, 1 }.CopyTo(body, 0);
        BinaryPrimitives.WriteInt32BigEndian(body.AsSpan(24), declaredSegmentSize);
        BinaryPrimitives.WriteInt32BigEndian(body.AsSpan(28), 1);
        BinaryPrimitives.WriteInt32BigEndian(body.AsSpan(32), 40);
        BinaryPrimitives.WriteInt32BigEndian(body.AsSpan(36), body.Length);
        using var cipher = Aes.Create();
        cipher.Key = new byte[16];
        var iv = new byte[16];
        BinaryPrimitives.WriteInt32LittleEndian(iv.AsSpan(4), 40);
        cipher.IV = iv;
        using var input = new MemoryStream(packed);
        using var ofb = new OfbStream(input, cipher, CryptoStreamMode.Read);
        ofb.ReadExactly(body.AsSpan(40));
        return body;
    }
}
