using System.Buffers.Binary;
using System.Data.HashFunction.SpookyHash;
using ResourceCatalogPreflight;
using Xunit;

namespace ResourceCatalogPreflight.Tests;

// Synthetic store only. The registered identity replaces a whole-store re-hash;
// length, path and every read chunk digest must still be enforced.
public sealed class NativeFxRegisteredStoreTests : IDisposable
{
  private readonly string root = Path.Combine(Path.GetTempPath(), "nll-registered-store-test-" + Guid.NewGuid().ToString("N"));
  private readonly byte[] payload = "synthetic registered chunk"u8.ToArray();
  private readonly byte[] compressed;
  private readonly string hash;
  private string StorePath => Path.Combine(root, "chunk", "store.cdb");
  private string Length => new FileInfo(StorePath).Length.ToString(System.Globalization.CultureInfo.InvariantCulture);
  // Deliberately not the synthetic file's real SHA-256: the stage records the registration.
  private static readonly string Registered = new('c', 64);

  public NativeFxRegisteredStoreTests()
  {
    Directory.CreateDirectory(Path.Combine(root, "chunk"));
    using var zstd = new ZstdSharp.Compressor();
    compressed = zstd.Wrap(payload).ToArray();
    var hashBytes = SpookyHashV2Factory.Instance.Create(new SpookyHashConfig { HashSizeInBits = 128 }).ComputeHash(compressed).Hash;
    hash = Convert.ToHexString(hashBytes);
    var store = new byte[256 + compressed.Length];
    new byte[] { 67, 66, 76, 66, 1, 0, 0, 0 }.CopyTo(store, 0);
    compressed.CopyTo(store, 256);
    File.WriteAllBytes(StorePath, store);
    var index = new byte[56];
    new byte[] { 67, 73, 68, 88, 1, 0, 0, 0 }.CopyTo(index, 0);
    BinaryPrimitives.WriteInt32LittleEndian(index.AsSpan(8), 1);
    hashBytes.CopyTo(index, 12);
    BinaryPrimitives.WriteInt64LittleEndian(index.AsSpan(28), 256);
    BinaryPrimitives.WriteInt32LittleEndian(index.AsSpan(36), compressed.Length);
    File.WriteAllBytes(Path.Combine(root, "chunk", "store.cdb.idx"), index);
  }

  [Fact]
  public void RegisteredIdentityOpensTheSameHandleThatServesVerifiedReads()
  {
    using var store = NativeFxChunkCandidate.OpenRegisteredStore(root, StorePath.ToUpperInvariant(), Registered, Length);
    Assert.Equal(new FileInfo(StorePath).Length, store.StoreLength);
    Assert.Equal(payload, store.ReadVerified(hash, payload.Length, compressed.Length));
    // Writers are denied while the registered handle is open.
    Assert.Throws<IOException>(() => new FileStream(StorePath, FileMode.Open, FileAccess.Write, FileShare.ReadWrite).Dispose());
  }

  [Theory]
  [InlineData(1)]
  [InlineData(-1)]
  public void WrongRegisteredLengthIsRejected(int delta)
  {
    var length = (new FileInfo(StorePath).Length + delta).ToString(System.Globalization.CultureInfo.InvariantCulture);
    Assert.Equal("resource_fx_chunk_candidate_store_length_mismatch", Assert.Throws<PreflightException>(
        () => NativeFxChunkCandidate.OpenRegisteredStore(root, StorePath, Registered, length)).Message);
    using var writable = new FileStream(StorePath, FileMode.Open, FileAccess.Write, FileShare.None); // Handle was released.
  }

  [Theory]
  [InlineData("other", null, null)]
  [InlineData(null, "C", null)]
  [InlineData(null, "c", null)]
  [InlineData(null, null, "256")]
  [InlineData(null, null, "-300")]
  [InlineData(null, null, "3e2")]
  [InlineData(null, null, "")]
  public void OtherPathOrMalformedRegistrationIsRejected(string? path, string? digest, string? length)
  {
    path = path is null ? StorePath : Path.Combine(root, path, "store.cdb");
    digest = digest is null ? Registered : digest == "c" ? new string('c', 63) : new string('C', 64);
    Assert.Equal("resource_fx_chunk_candidate_registered_store_invalid", Assert.Throws<PreflightException>(
        () => NativeFxChunkCandidate.OpenRegisteredStore(root, path, digest, length ?? Length)).Message);
  }

  [Fact]
  public void CorruptedChunkWithUnchangedLengthIsStillRejected()
  {
    var bytes = File.ReadAllBytes(StorePath);
    bytes[^1] ^= 1;
    File.WriteAllBytes(StorePath, bytes);
    using var store = NativeFxChunkCandidate.OpenRegisteredStore(root, StorePath, Registered, Length);
    Assert.Equal("resource_chunk_digest_mismatch", Assert.Throws<PreflightException>(
        () => store.ReadVerified(hash, payload.Length, compressed.Length)).Message);
    Assert.Equal("resource_chunk_digest_mismatch", Assert.Throws<PreflightException>(
        () => store.ReadCompressedVerified(hash, compressed.Length)).Message);
  }

  public void Dispose()
  {
    foreach (var file in Directory.GetFiles(Path.Combine(root, "chunk"))) File.Delete(file);
    Directory.Delete(Path.Combine(root, "chunk"));
    Directory.Delete(root);
  }
}

public sealed class NativeFxChunkCandidateTests
{
  [Theory]
  [InlineData(1)]
  [InlineData(1024)]
  [InlineData(150000)]
  public void PaddedFrameHasExactLengthAndDecodesToCandidate(int length)
  {
    var input = Enumerable.Range(0, length).Select(i => (byte)(i % 31)).ToArray();
    var result = NativeFxChunkCandidate.CompressExact(input, length + 128);
    Assert.Equal(length + 128, result.Length);
    using var decoder = new ZstdSharp.Decompressor();
    Assert.Equal(input, decoder.Unwrap(result, length).ToArray());
    Assert.Equal(result, NativeFxChunkCandidate.CompressExact(input, length + 128));
    var magic = new byte[4];
    BinaryPrimitives.WriteUInt32LittleEndian(magic, 0x184D2A50);
    Assert.True(result.AsSpan().IndexOf(magic) >= 0);
  }

  [Fact]
  public void ExactCompressedSizeDoesNotRequirePadding()
  {
    var input = "synthetic payload"u8.ToArray();
    using var encoder = new ZstdSharp.Compressor(1);
    var target = encoder.Wrap(input).Length;
    var result = NativeFxChunkCandidate.CompressExact(input, target);
    Assert.Equal(target, result.Length);
    using var decoder = new ZstdSharp.Decompressor();
    Assert.Equal(input, decoder.Unwrap(result, input.Length).ToArray());
  }

  [Theory]
  [InlineData(1)]
  [InlineData(2)]
  [InlineData(7)]
  public void InsufficientCompressionSpaceFailsInsteadOfChangingOffsets(int size)
  {
    Assert.Equal("resource_fx_chunk_candidate_exact_compression_unavailable", Assert.Throws<PreflightException>(
        () => NativeFxChunkCandidate.CompressExact("synthetic incompressible example"u8.ToArray(), size)).Message);
  }

  [Theory]
  [InlineData(0, 100)]
  [InlineData(1, 0)]
  [InlineData(1, -1)]
  [InlineData(1, 16777217)]
  public void UnboundedOrEmptyInputsFail(int length, int size)
  {
    Assert.Equal("resource_fx_chunk_candidate_size_invalid", Assert.Throws<PreflightException>(
        () => NativeFxChunkCandidate.CompressExact(new byte[length], size)).Message);
  }

  private static NativeFxChunkCandidate.Patch Patch(string role = "fire", int ordinal = 0, long offset = 256) =>
      new(role, ordinal, offset, "before"u8.ToArray(), "after!"u8.ToArray());

  [Fact]
  public void OutOfOrderNonOverlappingPatchesPreserveOriginalPositions()
  {
    NativeFxChunkCandidate.ValidatePatches([Patch("iron", offset: 400), Patch(), Patch("wind", offset: 300)], 406);
  }

  [Theory]
  [InlineData(255)]
  [InlineData(-1)]
  [InlineData(long.MaxValue)]
  [InlineData(995)]
  public void HeaderNegativeOverflowOrPastEndOffsetsFail(long offset)
  {
    Assert.Equal("resource_fx_chunk_candidate_patch_range_invalid", Assert.Throws<PreflightException>(
        () => NativeFxChunkCandidate.ValidatePatches([Patch(offset: offset)], 1000)).Message);
  }

  [Fact]
  public void OverlapOrSameChunkInTwoRolesFails()
  {
    foreach (var offset in new long[] { 256, 260 })
      Assert.Throws<PreflightException>(() => NativeFxChunkCandidate.ValidatePatches([Patch(), Patch("wind", offset: offset)], 1000));
  }

  [Fact]
  public void DuplicateRoleOrdinalFailsEvenWhenRangesDoNotOverlap()
  {
    Assert.Equal("resource_fx_chunk_candidate_patch_identity_invalid", Assert.Throws<PreflightException>(
        () => NativeFxChunkCandidate.ValidatePatches([Patch(), Patch(offset: 300)], 1000)).Message);
  }

  [Theory]
  [InlineData("Water", 0)]
  [InlineData("../fire", 0)]
  [InlineData("electric/", 0)]
  [InlineData("fire", -1)]
  public void NonNormalizedRolesAndBadOrdinalsCannotBecomeOutputPaths(string role, int ordinal)
  {
    Assert.Throws<PreflightException>(() => NativeFxChunkCandidate.ValidatePatches([Patch(role, ordinal)], 1000));
  }

  [Theory]
  [InlineData("fire")]
  [InlineData("water")]
  [InlineData("wind")]
  [InlineData("electric")]
  [InlineData("iron")]
  public void AnyBossElementCanSupplyAnAdjustedChunk(string role)
    => NativeFxChunkCandidate.ValidatePatches([Patch(role)], 1000);

  [Fact]
  public void EmptyEqualResizedAndExcessivePatchesAreRejected()
  {
    var valid = Patch();
    foreach (var invalid in new[] { valid with { After = valid.Before }, valid with { Before = [] }, valid with { After = [1] } })
      Assert.Throws<PreflightException>(() => NativeFxChunkCandidate.ValidatePatches([invalid], 1000));
    Assert.Throws<PreflightException>(() => NativeFxChunkCandidate.ValidatePatches([], 1000));
    Assert.Throws<PreflightException>(() => NativeFxChunkCandidate.ValidatePatches(
        Enumerable.Range(0, 33).Select(i => Patch(ordinal: i, offset: 256 + i * 6)).ToArray(), 1000));
  }
}
