using System.Buffers.Binary;
using System.Data.HashFunction.SpookyHash;
using ResourceCatalogPreflight;
using Xunit;

namespace ResourceCatalogPreflight.Tests;

public sealed class SegmentedSpookyHashTests
{
  [Theory]
  [InlineData(0)]
  [InlineData(1)]
  [InlineData(131071)]
  [InlineData(131072)]
  [InlineData(131073)]
  [InlineData(262144)]
  [InlineData(262145)]
  public void FixedBlockSeedsMatchIndependentBlockCalculation(int size)
  {
    var data = new byte[size];
    new Random(719).NextBytes(data);
    var expected = new byte[16];
    for (var offset = 0; offset < Math.Max(1, size); offset += 131072)
    {
      var block = data.Skip(offset).Take(131072).ToArray();
      expected = SpookyHashV2Factory.Instance.Create(new SpookyHashConfig
      {
        HashSizeInBits = 128, Seed = BinaryPrimitives.ReadUInt64LittleEndian(expected),
        Seed2 = BinaryPrimitives.ReadUInt64LittleEndian(expected.AsSpan(8))
      }).ComputeHash(block).Hash;
    }
    using var stream = new ShortReadStream(data);
    Assert.Equal(expected, SegmentedSpookyHash.Compute(stream, size));
    if (size > 131072)
      Assert.NotEqual(SpookyHashV2Factory.Instance.Create(new SpookyHashConfig { HashSizeInBits = 128 })
        .ComputeHash(data).Hash, expected);
  }

  [Fact]
  public void TruncatedInputCannotProduceAnAcceptedPartialHash()
  {
    using var stream = new MemoryStream(new byte[8]);
    Assert.Throws<EndOfStreamException>(() => SegmentedSpookyHash.Compute(stream, 9));
  }

  private sealed class ShortReadStream(byte[] bytes) : MemoryStream(bytes, writable: false)
  {
    public override int Read(Span<byte> buffer) => base.Read(buffer[..Math.Min(buffer.Length, 17)]);
  }
}
