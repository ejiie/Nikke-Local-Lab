using ResourceCatalogPreflight;
using Xunit;

namespace ResourceCatalogPreflight.Tests;

public sealed class LocalResourceSourceTests
{
  [Fact]
  public void RawChecksumIsIndependentOfLocallyPinnedSha256()
  {
    var directory = Path.Combine(Path.GetTempPath(), "nll-native-raw-" + Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(directory);
    var path = Path.Combine(directory, "synthetic.bin");
    var bytes = new byte[131073];
    new Random(729).NextBytes(bytes);
    using var input = new MemoryStream(bytes);
    var nativeHash = Convert.ToHexString(SegmentedSpookyHash.Compute(input, bytes.Length));
    File.WriteAllBytes(path, bytes);
    try
    {
      using (var source = new SealedResourceFile(path, bytes.Length, CatalogDatabase.Hash(bytes), nativeHash))
        Assert.Equal(bytes[^1], source.ReadRange(bytes.Length - 1, 1)[0]);
      bytes[^1] ^= 1;
      File.WriteAllBytes(path, bytes);
      // A fresh SHA of a corrupt copy cannot override the hash in its catalog.
      Assert.Equal("resource_patch_raw_digest_mismatch", Assert.Throws<PreflightException>(() =>
        new SealedResourceFile(path, bytes.Length, CatalogDatabase.Hash(bytes), nativeHash)).Message);
      Assert.Throws<PreflightException>(() => new SealedResourceFile(path, bytes.Length, CatalogDatabase.Hash(bytes) + "\n"));
    }
    finally { File.Delete(path); Directory.Delete(directory); }
  }

  [Fact]
  public void PakRangesUseCatalogCoordinatesAndOriginalCompressedBytes()
  {
    var spans = new[] { new VirtualPakReader.Span(100, 4, "a"), new VirtualPakReader.Span(104, 3, "b") };
    var bytes = VirtualPakReader.ReadRange(spans, 102, 4,
        (hash, _) => hash == "a" ? [10, 11, 12, 13] : [20, 21, 22]);
    Assert.Equal(new byte[] { 12, 13, 20, 21 }, bytes);
  }

  [Theory]
  [InlineData(-1, 1)]
  [InlineData(0, 0)]
  [InlineData(0, 16777217)]
  [InlineData(long.MaxValue, 2)]
  public void InvalidRangesFailBeforeReading(long offset, int length)
  {
    Assert.Equal("resource_pak_range_invalid", Assert.Throws<PreflightException>(() =>
        VirtualPakReader.ReadRange([], offset, length, (_, _) => throw new InvalidOperationException())).Message);
  }

  [Theory]
  [InlineData(3)]
  [InlineData(5)]
  public void OverlapAndHolesCannotBeSilentlyFilled(long secondOffset)
  {
    var spans = new[] { new VirtualPakReader.Span(0, 4, "a"), new VirtualPakReader.Span(secondOffset, 4, "b") };
    Assert.Equal("resource_pak_range_layout_invalid", Assert.Throws<PreflightException>(() =>
        VirtualPakReader.ReadRange(spans, 0, 8, (_, _) => throw new InvalidOperationException())).Message);
  }

  [Fact]
  public void NoSpansOrUnavailableTailDoesNotReturnZeros()
  {
    Assert.Equal("resource_pak_range_unavailable", Assert.Throws<PreflightException>(() =>
        VirtualPakReader.ReadRange([], 0, 3, (_, _) => [])).Message);
    Assert.Equal("resource_pak_range_unavailable", Assert.Throws<PreflightException>(() =>
        VirtualPakReader.ReadRange([new(0, 2, "a")], 0, 3, (_, _) => [])).Message);
  }

  [Fact]
  public void ReaderFailureIsPropagatedAndBuffersAreCleared()
  {
    var first = new byte[] { 10, 11 };
    Assert.Throws<PreflightException>(() => VirtualPakReader.ReadRange([new(0, 2, "a"), new(2, 2, "b")], 0, 4,
        (hash, _) => hash == "a" ? first : throw new PreflightException("resource_chunk_member_missing")));
    Assert.Equal(new byte[2], first);
    Assert.Equal("resource_pak_chunk_length_mismatch", Assert.Throws<PreflightException>(() =>
        VirtualPakReader.ReadRange([new(0, 2, "a")], 0, 2, (_, _) => [1])).Message);
  }

  [Fact]
  public void SealedRawSourcePreservesNkdbBytesAndRejectsDrift()
  {
    var directory = Path.Combine(Path.GetTempPath(), "nll-sealed-source-" + Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(directory);
    var path = Path.Combine(directory, "synthetic.bin");
    byte[] bytes = "NKDBsynthetic-raw-not-sqlite"u8.ToArray();
    File.WriteAllBytes(path, bytes);
    try
    {
      using (var source = new SealedResourceFile(path, bytes.Length, CatalogDatabase.Hash(bytes)))
      {
        Assert.Equal("NKDB"u8.ToArray(), source.ReadRange(0, 4));
        Assert.Equal(bytes, source.ReadRange(0, bytes.Length));
        Assert.Throws<PreflightException>(() => source.ReadRange(bytes.Length, 1));
        Assert.Throws<PreflightException>(() => source.ReadRange(-1, 1));
        if (OperatingSystem.IsWindows()) Assert.Throws<IOException>(() => File.WriteAllBytes(path, [0]));
      }
      Assert.Throws<PreflightException>(() => new SealedResourceFile(path, bytes.Length + 1, CatalogDatabase.Hash(bytes)));
      Assert.Throws<PreflightException>(() => new SealedResourceFile(path, bytes.Length, new string('0', 64)));
      Assert.Equal(bytes, File.ReadAllBytes(path));
    }
    finally { File.Delete(path); Directory.Delete(directory); }
  }
}
