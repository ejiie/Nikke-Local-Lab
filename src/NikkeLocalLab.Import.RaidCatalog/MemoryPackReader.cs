using System.Buffers.Binary;
using System.Text;

namespace NikkeLocalLab.Import.RaidCatalog;

internal sealed class MemoryPackReader
{
  private const int MaximumStringBytes = 1 * 1024 * 1024;
  private const int MaximumStringCharacters = MaximumStringBytes / sizeof(char);
  private const int MaximumCollectionLength = 250_000;
  private static readonly Encoding StrictUtf8 = new UTF8Encoding(false, true);
  private static readonly Encoding StrictUtf16 = new UnicodeEncoding(false, false, true);
  private readonly ReadOnlyMemory<byte> _memory;
  private int _offset;

  public MemoryPackReader(ReadOnlyMemory<byte> memory)
  {
    _memory = memory;
  }

  public byte ReadByte()
  {
    Require(sizeof(byte));
    return _memory.Span[_offset++];
  }

  public bool ReadBoolean() => ReadByte() switch
  {
    0 => false,
    1 => true,
    _ => throw new ChallengeRaidCatalogSourceException("memorypack_boolean_invalid")
  };

  public int ReadInt32()
  {
    Require(sizeof(int));
    var value = BinaryPrimitives.ReadInt32LittleEndian(_memory.Span.Slice(_offset, sizeof(int)));
    _offset += sizeof(int);
    return value;
  }

  public long ReadInt64()
  {
    Require(sizeof(long));
    var value = BinaryPrimitives.ReadInt64LittleEndian(_memory.Span.Slice(_offset, sizeof(long)));
    _offset += sizeof(long);
    return value;
  }

  public string? ReadString()
  {
    var header = ReadInt32();
    if (header == -1)
    {
      return null;
    }

    if (header == 0)
    {
      return string.Empty;
    }

    if (header <= -2)
    {
      var byteCount = ~header;
      var characterCount = ReadInt32();
      if (byteCount < 0 || byteCount > MaximumStringBytes ||
          characterCount < 0 || characterCount > MaximumStringCharacters)
      {
        throw new ChallengeRaidCatalogSourceException("memorypack_string_invalid");
      }

      var value = Decode(StrictUtf8, ReadBytes(byteCount).Span);
      if (value.Length != characterCount)
      {
        throw new ChallengeRaidCatalogSourceException("memorypack_string_length_mismatch");
      }

      return value;
    }

    if (header > MaximumStringCharacters)
    {
      throw new ChallengeRaidCatalogSourceException("memorypack_string_invalid");
    }

    return Decode(StrictUtf16, ReadBytes(checked(header * sizeof(char))).Span);
  }

  public int ReadCollectionLength(int maximumLength = MaximumCollectionLength, bool allowNull = false)
  {
    if (maximumLength < 0 || maximumLength > MaximumCollectionLength)
    {
      throw new ArgumentOutOfRangeException(nameof(maximumLength));
    }

    var length = ReadInt32();
    if (allowNull && length == -1)
    {
      return -1;
    }

    if (length < 0 || length > maximumLength)
    {
      throw new ChallengeRaidCatalogSourceException("memorypack_collection_invalid");
    }

    return length;
  }

  public int[]? ReadInt32Array(bool allowNull = true, int maximumLength = 16_384)
  {
    var length = ReadCollectionLength(maximumLength, allowNull);
    if (length < 0)
    {
      return null;
    }

    var result = new int[length];
    for (var index = 0; index < length; index++)
    {
      result[index] = ReadInt32();
    }

    return result;
  }

  public long[]? ReadInt64Array(bool allowNull = true, int maximumLength = 16_384)
  {
    var length = ReadCollectionLength(maximumLength, allowNull);
    if (length < 0)
    {
      return null;
    }

    var result = new long[length];
    for (var index = 0; index < length; index++)
    {
      result[index] = ReadInt64();
    }

    return result;
  }

  public string?[]? ReadStringArray(bool allowNull = true, int maximumLength = 16_384)
  {
    var length = ReadCollectionLength(maximumLength, allowNull);
    if (length < 0)
    {
      return null;
    }

    var result = new string?[length];
    for (var index = 0; index < length; index++)
    {
      result[index] = ReadString();
    }

    return result;
  }

  public void RequireObject(int expectedMemberCount)
  {
    if (ReadByte() != expectedMemberCount)
    {
      throw new ChallengeRaidCatalogSourceException("memorypack_schema_mismatch");
    }
  }

  public void EnsureEnd()
  {
    if (_offset != _memory.Length)
    {
      throw new ChallengeRaidCatalogSourceException("memorypack_trailing_bytes");
    }
  }

  private ReadOnlyMemory<byte> ReadBytes(int count)
  {
    Require(count);
    var result = _memory.Slice(_offset, count);
    _offset += count;
    return result;
  }

  private void Require(int count)
  {
    if (count < 0 || _offset > _memory.Length - count)
    {
      throw new ChallengeRaidCatalogSourceException("memorypack_truncated");
    }
  }

  private static string Decode(Encoding encoding, ReadOnlySpan<byte> bytes)
  {
    try
    {
      return encoding.GetString(bytes);
    }
    catch (DecoderFallbackException)
    {
      throw new ChallengeRaidCatalogSourceException("memorypack_string_invalid");
    }
  }
}
