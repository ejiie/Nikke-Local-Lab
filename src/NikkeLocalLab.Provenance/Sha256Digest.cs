using System.Security.Cryptography;
using System.Text;

namespace NikkeLocalLab.Provenance;

public readonly record struct Sha256Digest
{
  public const int ByteLength = 32;
  public const int HexLength = ByteLength * 2;

  private Sha256Digest(string hex)
  {
    Hex = hex;
  }

  public string Hex { get; }

  public static Sha256Digest Parse(string value)
  {
    if (!TryParse(value, out var digest))
    {
      throw new FormatException("A SHA-256 digest must contain exactly 64 lowercase hexadecimal characters.");
    }

    return digest;
  }

  public static bool TryParse(string? value, out Sha256Digest digest)
  {
    digest = default;
    if (value is null || value.Length != HexLength)
    {
      return false;
    }

    for (var index = 0; index < value.Length; index++)
    {
      var character = value[index];
      if (!((character >= '0' && character <= '9') || (character >= 'a' && character <= 'f')))
      {
        return false;
      }
    }

    digest = new Sha256Digest(value);
    return true;
  }

  public static Sha256Digest Compute(ReadOnlySpan<byte> value) => FromBytes(SHA256.HashData(value));

  public static Sha256Digest ComputeUtf8(string value) => Compute(Encoding.UTF8.GetBytes(value));

  public static async Task<Sha256Digest> ComputeAsync(Stream stream, CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(stream);
    var bytes = await SHA256.HashDataAsync(stream, cancellationToken).ConfigureAwait(false);
    return FromBytes(bytes);
  }

  public static Sha256Digest FromBytes(ReadOnlySpan<byte> bytes)
  {
    if (bytes.Length != ByteLength)
    {
      throw new ArgumentException("A SHA-256 digest must contain exactly 32 bytes.", nameof(bytes));
    }

    return new Sha256Digest(Convert.ToHexString(bytes).ToLowerInvariant());
  }

  public byte[] ToByteArray()
  {
    if (Hex is null)
    {
      throw new InvalidOperationException("The SHA-256 digest is not initialized.");
    }

    return Convert.FromHexString(Hex);
  }

  public override string ToString() => Hex ?? string.Empty;
}
