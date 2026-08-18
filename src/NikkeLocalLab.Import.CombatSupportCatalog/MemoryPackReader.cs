using System.Buffers.Binary;
using System.Text;

namespace NikkeLocalLab.Import.CombatSupportCatalog;

internal sealed class MemoryPackReader
{
  private const int MaximumTableRowCount = 250_000;
  private const int MaximumNestedCollectionLength = 16_384;
  private const int MaximumStringByteLength = 1 * 1024 * 1024;
  private const int MaximumStringCharacterLength = MaximumStringByteLength / sizeof(char);
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
    _ => throw new CombatSupportCatalogSourceException("memorypack_boolean_invalid")
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

  public double ReadDouble()
  {
    var value = BitConverter.Int64BitsToDouble(ReadInt64());
    if (!double.IsFinite(value))
    {
      throw new CombatSupportCatalogSourceException("memorypack_number_invalid");
    }

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
      var utf16Length = ReadInt32();
      if (byteCount < 0 || byteCount > MaximumStringByteLength ||
          utf16Length < 0 || utf16Length > MaximumStringCharacterLength)
      {
        throw new CombatSupportCatalogSourceException("memorypack_string_invalid");
      }

      var bytes = ReadBytes(byteCount);
      var value = Decode(StrictUtf8, bytes.Span);
      if (value.Length != utf16Length)
      {
        throw new CombatSupportCatalogSourceException("memorypack_string_length_mismatch");
      }

      return value;
    }

    if (header > MaximumStringCharacterLength)
    {
      throw new CombatSupportCatalogSourceException("memorypack_string_invalid");
    }

    return Decode(StrictUtf16, ReadBytes(header * sizeof(char)).Span);
  }

  public int ReadCollectionLength(bool allowNull = false, int maximumLength = MaximumTableRowCount)
  {
    if (maximumLength < 0 || maximumLength > MaximumTableRowCount)
    {
      throw new ArgumentOutOfRangeException(nameof(maximumLength));
    }

    var length = ReadInt32();
    if (length == -1 && allowNull)
    {
      return -1;
    }

    if (length < 0 || length > maximumLength)
    {
      throw new CombatSupportCatalogSourceException("memorypack_collection_invalid");
    }

    return length;
  }

  public void RequireObject(int expectedMemberCount)
  {
    if (ReadByte() != expectedMemberCount)
    {
      throw new CombatSupportCatalogSourceException("memorypack_schema_mismatch");
    }
  }

  public int[]? ReadInt32Array(bool allowNull = true)
  {
    var count = ReadCollectionLength(allowNull, MaximumNestedCollectionLength);
    if (count < 0)
    {
      return null;
    }

    var values = new int[count];
    for (var index = 0; index < count; index++)
    {
      values[index] = ReadInt32();
    }

    return values;
  }

  public string?[]? ReadStringArray(bool allowNull = true)
  {
    var count = ReadCollectionLength(allowNull, MaximumNestedCollectionLength);
    if (count < 0)
    {
      return null;
    }

    var values = new string?[count];
    for (var index = 0; index < count; index++)
    {
      values[index] = ReadString();
    }

    return values;
  }

  public void EnsureEnd()
  {
    if (_offset != _memory.Length)
    {
      throw new CombatSupportCatalogSourceException("memorypack_trailing_bytes");
    }
  }

  private ReadOnlyMemory<byte> ReadBytes(int count)
  {
    Require(count);
    var value = _memory.Slice(_offset, count);
    _offset += count;
    return value;
  }

  private void Require(int count)
  {
    if (count < 0 || _offset > _memory.Length - count)
    {
      throw new CombatSupportCatalogSourceException("memorypack_truncated");
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
      throw new CombatSupportCatalogSourceException("memorypack_string_invalid");
    }
  }
}
