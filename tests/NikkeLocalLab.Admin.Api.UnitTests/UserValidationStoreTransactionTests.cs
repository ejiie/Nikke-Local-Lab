using System.Security.Cryptography;
using NikkeLocalLab.Phase3B2.UserValidation;

namespace NikkeLocalLab.Admin.Api.UnitTests;

public sealed class UserValidationStoreTransactionTests
{
  private static byte[] Source() => Enumerable.Range(0, 4096).Select(i => (byte)(i % 251)).ToArray();
  private static UserValidationStoreRange[] Ranges(byte[] original) =>
      [new(300, original[300..320], Enumerable.Repeat((byte)252, 20).ToArray()),
        new(3000, original[3000..3040], Enumerable.Repeat((byte)253, 40).ToArray())];
  private static string Hash(byte[] value) => Convert.ToHexString(SHA256.HashData(value)).ToLowerInvariant();

  [Fact]
  public void FullRoundTripPreservesUnselectedBytesAndRepeatedRestoreIsReadOnly()
  {
    var original = Source(); var ranges = Ranges(original); using var stream = new MemoryStream(original.ToArray());
    var seal = UserValidationStoreTransaction.Prepare(stream, ranges, Hash(original));
    Assert.Equal(original, stream.ToArray());
    UserValidationStoreTransaction.Apply(stream, ranges, seal);
    var expected = original.ToArray();
    foreach (var row in ranges) row.After.CopyTo(expected, (int)row.Offset);
    Assert.Equal(expected, stream.ToArray()); Assert.Equal(Hash(expected), seal.CandidateSha256);
    Assert.True(UserValidationStoreTransaction.Restore(stream, ranges, seal));
    Assert.Equal(original, stream.ToArray());
    Assert.False(UserValidationStoreTransaction.Restore(stream, ranges, seal));
  }

  public static IEnumerable<object[]> WritePositions() => Enumerable.Range(0, 61).Select(n => new object[] { n });
  [Theory]
  [MemberData(nameof(WritePositions))]
  public void EveryTornWritePositionCanBeRestoredWithoutGuessingUnownedBytes(int limit)
  {
    var original = Source(); var ranges = Ranges(original); using var stream = new TornWriteStream(original.ToArray(), limit);
    var seal = UserValidationStoreTransaction.Prepare(stream, ranges, Hash(original));
    if (limit < 60) Assert.Throws<IOException>(() => UserValidationStoreTransaction.Apply(stream, ranges, seal));
    else UserValidationStoreTransaction.Apply(stream, ranges, seal);
    stream.Remaining = int.MaxValue;
    UserValidationStoreTransaction.Restore(stream, ranges, seal);
    Assert.Equal(original, stream.ToArray());
    Assert.False(UserValidationStoreTransaction.Restore(stream, ranges, seal));
  }

  [Theory]
  [InlineData(12)]
  [InlineData(900)]
  [InlineData(4095)]
  [InlineData(305)]
  public void UnrelatedOrUnknownMutationRefusesRestoreBeforeAnyWrite(int position)
  {
    var original = Source(); var ranges = Ranges(original); using var stream = new TornWriteStream(original.ToArray(), int.MaxValue);
    var seal = UserValidationStoreTransaction.Prepare(stream, ranges, Hash(original));
    UserValidationStoreTransaction.Apply(stream, ranges, seal);
    stream.Position = position; stream.WriteByte(254);
    var changed = stream.ToArray(); stream.Remaining = 0;
    Assert.Throws<InvalidOperationException>(() => UserValidationStoreTransaction.Restore(stream, ranges, seal));
    Assert.Equal(changed, stream.ToArray());
  }

  [Fact]
  public void WrongPinsRangesAndRepeatedApplyRefuseBeforeAnyWrite()
  {
    var original = Source(); var ranges = Ranges(original); using var stream = new MemoryStream(original.ToArray());
    var seal = UserValidationStoreTransaction.Prepare(stream, ranges, Hash(original));
    foreach (var bad in new[] { seal with { OriginalSha256 = new string('0', 64) },
        seal with { CandidateSha256 = new string('0', 64) }, seal with { Length = 4095 } })
      Assert.Throws<InvalidOperationException>(() => UserValidationStoreTransaction.Apply(stream, ranges, bad));
    foreach (var bad in new[] { Array.Empty<UserValidationStoreRange>(), ranges.Reverse().ToArray(),
        new[] { ranges[0], ranges[0] }, new[] { ranges[0] with { Offset = 0 } },
        new[] { ranges[0] with { Offset = 4090 } }, new[] { ranges[0] with { After = new byte[1] } },
        new[] { ranges[0] with { After = ranges[0].Before } } })
      Assert.Throws<InvalidOperationException>(() => UserValidationStoreTransaction.Apply(stream, bad, seal));
    Assert.Equal(original, stream.ToArray());
    UserValidationStoreTransaction.Apply(stream, ranges, seal);
    var applied = stream.ToArray();
    Assert.Throws<InvalidOperationException>(() => UserValidationStoreTransaction.Apply(stream, ranges, seal));
    Assert.Equal(applied, stream.ToArray());
  }

  private sealed class TornWriteStream(byte[] bytes, int remaining) : MemoryStream(bytes)
  {
    internal int Remaining { get; set; } = remaining;
    public override void Write(ReadOnlySpan<byte> buffer)
    {
      var keep = Math.Min(buffer.Length, Remaining);
      base.Write(buffer[..keep]); Remaining -= keep;
      if (keep < buffer.Length) throw new IOException("synthetic_torn_write");
    }
  }
}
