using System.Buffers.Binary;
using ResourceCatalogPreflight;
using Xunit;

namespace ResourceCatalogPreflight.Tests;

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
  [InlineData("water", 0)]
  [InlineData("../fire", 0)]
  [InlineData("electric", 0)]
  [InlineData("fire", -1)]
  public void NonNormalizedRolesAndBadOrdinalsCannotBecomeOutputPaths(string role, int ordinal)
  {
    Assert.Throws<PreflightException>(() => NativeFxChunkCandidate.ValidatePatches([Patch(role, ordinal)], 1000));
  }

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
