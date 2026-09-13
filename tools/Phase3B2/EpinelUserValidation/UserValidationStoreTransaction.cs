using System.Security.Cryptography;

namespace NikkeLocalLab.Phase3B2.UserValidation;

internal sealed record UserValidationStoreRange(long Offset, byte[] Before, byte[] After);
internal sealed record UserValidationStoreSeal(long Length, string OriginalSha256, string CandidateSha256);

// Bounded byte-range transaction, NOT a path/admission policy. The caller must
// hold an exclusive physical-file handle, persist pinned rollback inputs before
// Apply, and prove the full game/service scope cold before Apply or Restore.
// It never interprets or modifies executable code, indexes, catalogues or files
// outside the caller-supplied stream. Only the reviewed selected FX chunks differ.
internal static class UserValidationStoreTransaction
{
  internal static UserValidationStoreSeal Prepare(Stream stream, IReadOnlyList<UserValidationStoreRange> ranges,
      string originalSha256)
  {
    Validate(stream, ranges);
    Require(IsHash(originalSha256));
    var result = Measure(stream, ranges, recovery: false);
    Require(result.Current == originalSha256 && result.Original == originalSha256 && result.Candidate != originalSha256);
    return new(stream.Length, originalSha256, result.Candidate);
  }

  internal static void Apply(Stream stream, IReadOnlyList<UserValidationStoreRange> ranges, UserValidationStoreSeal seal)
  {
    ValidateSeal(stream, ranges, seal);
    // Verify every original byte and every range BEFORE the first write.
    Require(Prepare(stream, ranges, seal.OriginalSha256) == seal);
    Write(stream, ranges, restore: false);
    Require(Hash(stream) == seal.CandidateSha256);
  }

  internal static bool Restore(Stream stream, IReadOnlyList<UserValidationStoreRange> ranges, UserValidationStoreSeal seal)
  {
    ValidateSeal(stream, ranges, seal);
    // A torn write may contain a mixture of before/after bytes, but no third
    // value is accepted. Project the ORIGINAL entire store without writing:
    // any unrelated cache change causes a zero-write refusal, not data loss.
    var result = Measure(stream, ranges, recovery: true);
    Require(result.Original == seal.OriginalSha256 && result.Candidate == seal.CandidateSha256);
    if (result.Current == seal.OriginalSha256) return false;
    Write(stream, ranges, restore: true);
    Require(Hash(stream) == seal.OriginalSha256);
    return true;
  }

  private static (string Current, string Original, string Candidate) Measure(Stream stream,
      IReadOnlyList<UserValidationStoreRange> ranges, bool recovery)
  {
    using var current = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
    using var original = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
    using var candidate = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
    var buffer = new byte[1024 * 1024];
    stream.Position = 0;
    void Unchanged(long count)
    {
      while (count > 0)
      {
        var size = (int)Math.Min(count, buffer.Length);
        stream.ReadExactly(buffer.AsSpan(0, size));
        current.AppendData(buffer, 0, size); original.AppendData(buffer, 0, size); candidate.AppendData(buffer, 0, size);
        count -= size;
      }
    }
    foreach (var range in ranges)
    {
      Unchanged(range.Offset - stream.Position);
      var bytes = new byte[range.Before.Length];
      stream.ReadExactly(bytes);
      for (var i = 0; i < bytes.Length; i++)
        Require(bytes[i] == range.Before[i] || recovery && bytes[i] == range.After[i]);
      current.AppendData(bytes); original.AppendData(range.Before); candidate.AppendData(range.After);
    }
    Unchanged(stream.Length - stream.Position);
    Require(stream.ReadByte() == -1);
    return (Hex(current.GetHashAndReset()), Hex(original.GetHashAndReset()), Hex(candidate.GetHashAndReset()));
  }

  private static void Write(Stream stream, IReadOnlyList<UserValidationStoreRange> ranges, bool restore)
  {
    Require(stream.CanWrite);
    foreach (var range in ranges)
    {
      stream.Position = range.Offset;
      stream.Write(restore ? range.Before : range.After);
      if (stream is FileStream file) file.Flush(flushToDisk: true); else stream.Flush();
    }
  }
  private static string Hash(Stream stream) { stream.Position = 0; return Hex(SHA256.HashData(stream)); }
  private static string Hex(byte[] bytes) => Convert.ToHexString(bytes).ToLowerInvariant();
  private static bool IsHash(string? hash) => hash is { Length: 64 } && hash.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f');
  private static void ValidateSeal(Stream stream, IReadOnlyList<UserValidationStoreRange> ranges, UserValidationStoreSeal seal)
  {
    Validate(stream, ranges);
    Require(seal is not null && seal.Length == stream.Length && IsHash(seal.OriginalSha256) &&
        IsHash(seal.CandidateSha256) && seal.OriginalSha256 != seal.CandidateSha256);
  }
  private static void Validate(Stream stream, IReadOnlyList<UserValidationStoreRange> ranges)
  {
    Require(stream.CanRead && stream.CanSeek && stream.Length > 256 && ranges is { Count: > 0 and <= 32 });
    long end = 256, total = 0;
    foreach (var range in ranges!)
    {
      Require(range is not null && range.Before is { Length: > 0 and <= 16777216 } &&
          range.After is not null && range.After.Length == range.Before.Length &&
          !range.Before.AsSpan().SequenceEqual(range.After) && range.Offset >= end &&
          range.Offset <= stream.Length - range.Before.Length);
      end = range!.Offset + range.Before.Length;
      total += range.Before.Length;
    }
    Require(total <= 67108864);
  }
  private static void Require(bool value)
  {
    if (!value) throw new InvalidOperationException("user_validation_store_transaction_rejected");
  }
}
