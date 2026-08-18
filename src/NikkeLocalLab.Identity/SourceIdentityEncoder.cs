using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;

namespace NikkeLocalLab.Identity;

public static class SourceIdentityEncoder
{
  private static readonly Encoding StrictUtf8 = new UTF8Encoding(
      encoderShouldEmitUTF8Identifier: false,
      throwOnInvalidBytes: true);

  public static EntityUid Encode(
      ReadOnlySpan<byte> localSecret,
      string sourceNamespace,
      string entityKind,
      string rawSourceIdentifier)
  {
    if (localSecret.Length < 32)
    {
      throw new ArgumentException("The local identity secret must contain at least 32 bytes.", nameof(localSecret));
    }

    ArgumentException.ThrowIfNullOrWhiteSpace(sourceNamespace);
    ArgumentException.ThrowIfNullOrWhiteSpace(entityKind);
    ArgumentException.ThrowIfNullOrWhiteSpace(rawSourceIdentifier);

    var components = new[]
    {
      "nll/source-identity/v1",
      sourceNamespace,
      entityKind,
      rawSourceIdentifier
    };
    var byteCounts = components.Select(StrictUtf8.GetByteCount).ToArray();
    var messageLength = checked(byteCounts.Sum() + (components.Length * sizeof(int)));
    var message = GC.AllocateUninitializedArray<byte>(messageLength);
    var offset = 0;
    for (var index = 0; index < components.Length; index++)
    {
      BinaryPrimitives.WriteInt32BigEndian(message.AsSpan(offset, sizeof(int)), byteCounts[index]);
      offset += sizeof(int);
      StrictUtf8.GetBytes(components[index], message.AsSpan(offset, byteCounts[index]));
      offset += byteCounts[index];
    }

    byte[] digest;
    try
    {
      digest = HMACSHA256.HashData(localSecret, message);
    }
    finally
    {
      CryptographicOperations.ZeroMemory(message);
    }

    digest[6] = (byte)((digest[6] & 0x0f) | 0x80);
    digest[8] = (byte)((digest[8] & 0x3f) | 0x80);
    var hex = Convert.ToHexString(digest).ToLowerInvariant();
    CryptographicOperations.ZeroMemory(digest);

    var formatted = $"{hex[..8]}-{hex[8..12]}-{hex[12..16]}-{hex[16..20]}-{hex[20..32]}";
    return new EntityUid(Guid.ParseExact(formatted, "D"));
  }
}
