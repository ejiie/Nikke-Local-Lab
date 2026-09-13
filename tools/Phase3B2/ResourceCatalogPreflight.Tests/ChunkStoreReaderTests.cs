using System.Buffers.Binary;
using System.Data.HashFunction.SpookyHash;
using ResourceCatalogPreflight;
using Xunit;

namespace ResourceCatalogPreflight.Tests;

public sealed class ChunkStoreReaderTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), "nll-chunk-test-" + Guid.NewGuid().ToString("N"));
    private readonly byte[] payload = "synthetic chunk payload only"u8.ToArray();
    private readonly byte[] compressed;
    private readonly string hash;

    public ChunkStoreReaderTests()
    {
        Directory.CreateDirectory(Path.Combine(root, "chunk"));
        using var zstd = new ZstdSharp.Compressor();
        compressed = zstd.Wrap(payload).ToArray();
        var hashBytes = SpookyHashV2Factory.Instance.Create(new SpookyHashConfig { HashSizeInBits = 128 }).ComputeHash(compressed).Hash;
        hash = Convert.ToHexString(hashBytes);
        var store = new byte[256 + compressed.Length];
        new byte[] { 67, 66, 76, 66, 1, 0, 0, 0 }.CopyTo(store, 0);
        compressed.CopyTo(store, 256);
        File.WriteAllBytes(Path.Combine(root, "chunk", "store.cdb"), store);
        var index = new byte[56];
        new byte[] { 67, 73, 68, 88, 1, 0, 0, 0 }.CopyTo(index, 0);
        BinaryPrimitives.WriteInt32LittleEndian(index.AsSpan(8), 1);
        hashBytes.CopyTo(index, 12);
        BinaryPrimitives.WriteInt64LittleEndian(index.AsSpan(28), 256);
        BinaryPrimitives.WriteInt32LittleEndian(index.AsSpan(36), compressed.Length);
        File.WriteAllBytes(Path.Combine(root, "chunk", "store.cdb.idx"), index);
    }

    [Fact]
    public void IndexHypothesisProbeDoesNotClaimReadiness()
    {
        using var result = System.Text.Json.JsonDocument.Parse(System.Text.Json.JsonSerializer.Serialize(IndexDigestProbe.Inspect(root)));
        Assert.Equal("not_evaluated", result.RootElement.GetProperty("nativeReadiness").GetString());
        Assert.False(result.RootElement.GetProperty("sourceMutationPerformed").GetBoolean());
        Assert.Empty(result.RootElement.GetProperty("matches").EnumerateArray());
    }

    [Fact]
    public void ValidSyntheticChunkRoundTripsWithoutCertifyingUnknownTrailer()
    {
        using var reader = new ChunkStoreReader(root);
        Assert.False(reader.IndexTrailerVerified);
        Assert.Equal(payload, reader.ReadVerified(hash, payload.Length, compressed.Length));
    }

    [Fact]
    public void RecordChainedTrailerIsReportedWithoutNativeAdmission()
    {
        var path = Path.Combine(root, "chunk", "store.cdb.idx");
        var index = File.ReadAllBytes(path);
        ChunkIndexDigest.Compute(index.AsSpan(0, index.Length - 16)).CopyTo(index, index.Length - 16);
        File.WriteAllBytes(path, index);
        using var reader = new ChunkStoreReader(root);
        Assert.True(reader.IndexTrailerVerified);
        Assert.Equal(payload, reader.ReadVerified(hash, payload.Length, compressed.Length));
        using var result = System.Text.Json.JsonDocument.Parse(System.Text.Json.JsonSerializer.Serialize(IndexDigestProbe.Inspect(root)));
        Assert.Contains(result.RootElement.GetProperty("matches").EnumerateArray(),
            item => item.GetString() == "spooky_header12_records28_seeded");
        Assert.Equal("not_evaluated", result.RootElement.GetProperty("nativeReadiness").GetString());
        Assert.False(result.RootElement.GetProperty("sourceMutationPerformed").GetBoolean());
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void WholeFileHashOrDamagedTrailerIsNotCertified(bool damaged)
    {
        var path = Path.Combine(root, "chunk", "store.cdb.idx");
        var index = File.ReadAllBytes(path);
        var digest = damaged ? ChunkIndexDigest.Compute(index.AsSpan(0, index.Length - 16)) :
            SpookyHashV2Factory.Instance.Create(new SpookyHashConfig { HashSizeInBits = 128 })
                .ComputeHash(index[..^16]).Hash;
        if (damaged) digest[0] ^= 1;
        digest.CopyTo(index, index.Length - 16);
        File.WriteAllBytes(path, index);
        using var reader = new ChunkStoreReader(root);
        Assert.False(reader.IndexTrailerVerified);
    }

    [Fact]
    public void CatalogSizeMismatchFails()
    {
        using var reader = new ChunkStoreReader(root);
        Assert.Equal("resource_chunk_catalog_size_mismatch", Assert.Throws<PreflightException>(
            () => reader.ReadVerified(hash, payload.Length, compressed.Length + 1)).Message);
    }

    [Fact]
    public void CompressedRangeSourceDoesNotReturnDecompressedAssets()
    {
        using var reader = new ChunkStoreReader(root);
        Assert.Equal(compressed, reader.ReadCompressedVerified(hash, compressed.Length));
        Assert.Equal(payload, reader.ReadVerified(hash, payload.Length, compressed.Length));
    }

    [Fact]
    public async Task SharedSourceReadsAreSerializedWithoutPositionCorruption()
    {
        using var reader = new ChunkStoreReader(root);
        await Task.WhenAll(Enumerable.Range(0, 32).Select(_ => Task.Run(() =>
            Assert.Equal(payload, reader.ReadVerified(hash, payload.Length, compressed.Length)))));
    }

    [Fact]
    public void MissingHashDoesNotSelectAnotherChunk()
    {
        using var reader = new ChunkStoreReader(root);
        Assert.Equal("resource_chunk_member_missing", Assert.Throws<PreflightException>(
            () => reader.ReadVerified(new string('0', 32), payload.Length, compressed.Length)).Message);
    }

    [Fact]
    public void PayloadDamageIsCaughtBeforeDecompression()
    {
        var path = Path.Combine(root, "chunk", "store.cdb");
        var bytes = File.ReadAllBytes(path);
        bytes[^1] ^= 1;
        File.WriteAllBytes(path, bytes);
        using var reader = new ChunkStoreReader(root);
        Assert.Equal("resource_chunk_digest_mismatch", Assert.Throws<PreflightException>(
            () => reader.ReadVerified(hash, payload.Length, compressed.Length)).Message);
    }

    [Theory]
    [InlineData(-1)]
    [InlineData(255)]
    [InlineData(long.MaxValue)]
    public void BadPhysicalOffsetsCannotReachOutsideTheStore(long offset)
    {
        var path = Path.Combine(root, "chunk", "store.cdb.idx");
        var index = File.ReadAllBytes(path);
        BinaryPrimitives.WriteInt64LittleEndian(index.AsSpan(28), offset);
        File.WriteAllBytes(path, index);
        Assert.Equal("resource_chunk_index_range_invalid", Assert.Throws<PreflightException>(() => new ChunkStoreReader(root)).Message);
    }

    public void Dispose()
    {
        foreach (var file in Directory.GetFiles(Path.Combine(root, "chunk"))) File.Delete(file);
        Directory.Delete(Path.Combine(root, "chunk"));
        Directory.Delete(root);
    }
}
