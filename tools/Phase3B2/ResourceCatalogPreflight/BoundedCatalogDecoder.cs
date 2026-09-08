using System.Buffers.Binary;
using System.IO.Compression;
using System.Security.Cryptography;
using EpinelPS.Data;

namespace ResourceCatalogPreflight;

internal static class BoundedCatalogDecoder
{
    // NKDB v1 uses the pinned external OFB compatibility primitive. Unlike
    // the upstream convenience decoder, both offsets and expansion are bounded
    // before allocating/copying data from a not-yet-verified local catalog.
    internal static byte[] Decode(byte[] body, int maximumLength = 512 * 1024 * 1024)
    {
        if (body.Length < 36 || !body.AsSpan(0, 8).SequenceEqual(new byte[] { 78, 75, 68, 66, 0, 0, 0, 1 }))
            throw new PreflightException("resource_catalog_container_unsupported");
        var segmentSize = BinaryPrimitives.ReadUInt32BigEndian(body.AsSpan(24, 4));
        var segmentCount = BinaryPrimitives.ReadUInt32BigEndian(body.AsSpan(28, 4));
        var maximumDeclared = (ulong)segmentSize * segmentCount;
        if (maximumLength < 1 || segmentSize == 0 || segmentCount == 0 ||
            maximumDeclared > (ulong)maximumLength || 36UL + segmentCount * 4UL > (ulong)body.Length)
            throw new PreflightException("resource_catalog_dimensions_invalid");
        var offsets = new int[segmentCount + 1];
        var tableEnd = 36UL + segmentCount * 4UL;
        for (var i = 0; i < offsets.Length; i++)
        {
            var offset = BinaryPrimitives.ReadUInt32BigEndian(body.AsSpan(32 + i * 4, 4));
            if (offset < tableEnd || offset > body.Length || (i > 0 && offset <= offsets[i - 1]))
                throw new PreflightException("resource_catalog_segment_range_invalid");
            offsets[i] = (int)offset;
        }
        if (offsets[^1] != body.Length) throw new PreflightException("resource_catalog_segment_range_invalid");
        var key = body.AsSpan(8, 16).ToArray();
        var buffer = new byte[64 * 1024];
        using var output = new MemoryStream();
        try
        {
            for (var i = 0; i < segmentCount; i++)
            {
                using var cipher = Aes.Create();
                cipher.Key = key;
                var iv = new byte[16];
                BinaryPrimitives.WriteInt32LittleEndian(iv, i);
                BinaryPrimitives.WriteInt32LittleEndian(iv.AsSpan(4), offsets[i]);
                cipher.IV = iv;
                using var compressed = new MemoryStream(body, offsets[i], offsets[i + 1] - offsets[i], writable: false);
                using var ofb = new OfbStream(compressed, cipher, CryptoStreamMode.Read);
                using var zlib = new ZLibStream(ofb, CompressionMode.Decompress);
                long segmentLength = 0;
                int length;
                while ((length = zlib.Read(buffer, 0, buffer.Length)) != 0)
                {
                    segmentLength += length;
                    if (segmentLength > segmentSize || output.Length + length > maximumLength)
                        throw new PreflightException("resource_catalog_expansion_limit_exceeded");
                    output.Write(buffer, 0, length);
                }
                if (segmentLength == 0 || (i < segmentCount - 1 && segmentLength != segmentSize))
                    throw new PreflightException("resource_catalog_segment_length_invalid");
            }
            return output.ToArray();
        }
        finally
        {
            CryptographicOperations.ZeroMemory(key);
            CryptographicOperations.ZeroMemory(buffer);
            if (output.TryGetBuffer(out var contents)) CryptographicOperations.ZeroMemory(contents.AsSpan());
        }
    }
}
