using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;

namespace NikkeLocalLab.Identity;

/// <summary>
/// Import-boundary fingerprint for a source identity. This value is never an entity UID.
/// </summary>
public readonly record struct SourceAliasFingerprint
{
  public const int ByteLength = 32;
  public const int HexLength = ByteLength * 2;

  private SourceAliasFingerprint(string hex)
  {
    Hex = hex;
  }

  public string Hex { get; }

  public static SourceAliasFingerprint FromBytes(ReadOnlySpan<byte> bytes)
  {
    if (bytes.Length != ByteLength)
    {
      throw new ArgumentException("A source alias fingerprint must contain exactly 32 bytes.", nameof(bytes));
    }

    return new SourceAliasFingerprint(Convert.ToHexString(bytes).ToLowerInvariant());
  }

  public static SourceAliasFingerprint Parse(string value)
  {
    if (value is null || value.Length != HexLength ||
        value.Any(character => !((character >= '0' && character <= '9') ||
                                 (character >= 'a' && character <= 'f'))))
    {
      throw new FormatException("A source alias fingerprint must contain 64 lowercase hexadecimal characters.");
    }

    return new SourceAliasFingerprint(value);
  }

  public byte[] ToByteArray()
  {
    if (Hex is null)
    {
      throw new InvalidOperationException("The source alias fingerprint is not initialized.");
    }

    return Convert.FromHexString(Hex);
  }

  public override string ToString() => Hex ?? string.Empty;
}

public static class SourceAliasFingerprintEncoder
{
  private static readonly Encoding StrictUtf8 = new UTF8Encoding(
      encoderShouldEmitUTF8Identifier: false,
      throwOnInvalidBytes: true);

  public static SourceAliasFingerprint Encode(
      ReadOnlySpan<byte> localSecret,
      string sourceNamespace,
      string entityKind,
      string rawSourceIdentifier)
  {
    if (localSecret.Length < 32)
    {
      throw new ArgumentException("The local identity secret must contain at least 32 bytes.", nameof(localSecret));
    }

    var message = EncodeEnvelope(
    [
        "nll/source-alias-fingerprint/v1",
      RequireComponent(sourceNamespace, nameof(sourceNamespace)),
      RequireComponent(entityKind, nameof(entityKind)),
      RequireComponent(rawSourceIdentifier, nameof(rawSourceIdentifier))
    ]);

    byte[]? digest = null;
    try
    {
      digest = HMACSHA256.HashData(localSecret, message);
      return SourceAliasFingerprint.FromBytes(digest);
    }
    finally
    {
      CryptographicOperations.ZeroMemory(message);
      if (digest is not null)
      {
        CryptographicOperations.ZeroMemory(digest);
      }
    }
  }

  public static byte[] CreateKeyCheck(ReadOnlySpan<byte> localSecret)
  {
    if (localSecret.Length < 32)
    {
      throw new ArgumentException("The local identity secret must contain at least 32 bytes.", nameof(localSecret));
    }

    var message = StrictUtf8.GetBytes("nll/source-alias-key-check/v1");
    try
    {
      return HMACSHA256.HashData(localSecret, message);
    }
    finally
    {
      CryptographicOperations.ZeroMemory(message);
    }
  }

  private static byte[] EncodeEnvelope(IReadOnlyList<string> components)
  {
    var byteCounts = components.Select(StrictUtf8.GetByteCount).ToArray();
    var messageLength = checked(byteCounts.Sum() + (components.Count * sizeof(int)));
    var message = GC.AllocateUninitializedArray<byte>(messageLength);
    var offset = 0;
    for (var index = 0; index < components.Count; index++)
    {
      BinaryPrimitives.WriteInt32BigEndian(message.AsSpan(offset, sizeof(int)), byteCounts[index]);
      offset += sizeof(int);
      StrictUtf8.GetBytes(components[index], message.AsSpan(offset, byteCounts[index]));
      offset += byteCounts[index];
    }

    return message;
  }

  private static string RequireComponent(string value, string parameterName)
  {
    ArgumentException.ThrowIfNullOrWhiteSpace(value, parameterName);
    return value;
  }
}
