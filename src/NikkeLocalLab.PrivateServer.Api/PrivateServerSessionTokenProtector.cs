using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using NikkeLocalLab.Identity;

namespace NikkeLocalLab.PrivateServer.Api;

internal sealed class PrivateServerSessionTokenProtector : IDisposable
{
  public const string AuthorizationScheme = "NLL-Session";

  private byte[]? _key = RandomNumberGenerator.GetBytes(32);

  public PrivateServerSessionGrant Issue(EntityUid sessionUid, DateTimeOffset expiresAtUtc)
  {
    if (sessionUid.Value == Guid.Empty || expiresAtUtc.Offset != TimeSpan.Zero)
    {
      throw new ArgumentException("private_server_session_grant_invalid");
    }

    var payload = string.Create(
        CultureInfo.InvariantCulture,
        $"nll1.{sessionUid}.{expiresAtUtc.UtcTicks}");
    var signature = Sign(payload);
    try
    {
      return new PrivateServerSessionGrant(
          $"{payload}.{Base64Url(signature)}",
          expiresAtUtc);
    }
    finally
    {
      CryptographicOperations.ZeroMemory(signature);
    }
  }

  public bool TryValidate(
      string? authorization,
      DateTimeOffset observedAtUtc,
      out EntityUid sessionUid)
  {
    sessionUid = default;
    if (authorization is null ||
        !authorization.StartsWith(AuthorizationScheme + " ", StringComparison.Ordinal))
    {
      return false;
    }

    var token = authorization[(AuthorizationScheme.Length + 1)..];
    var parts = token.Split('.', StringSplitOptions.None);
    if (parts.Length != 4 ||
        !string.Equals(parts[0], "nll1", StringComparison.Ordinal) ||
        !Guid.TryParseExact(parts[1], "D", out var parsedUid) ||
        parsedUid == Guid.Empty ||
        !long.TryParse(
            parts[2],
            NumberStyles.None,
            CultureInfo.InvariantCulture,
            out var expiresAtTicks) ||
        expiresAtTicks <= 0 ||
        !TryDecodeSignature(parts[3], out var suppliedSignature))
    {
      return false;
    }

    try
    {
      DateTimeOffset expiresAtUtc;
      try
      {
        expiresAtUtc = new DateTimeOffset(expiresAtTicks, TimeSpan.Zero);
      }
      catch (ArgumentOutOfRangeException)
      {
        return false;
      }

      if (observedAtUtc.ToUniversalTime() >= expiresAtUtc)
      {
        return false;
      }

      var payload = string.Create(
          CultureInfo.InvariantCulture,
          $"{parts[0]}.{parts[1]}.{parts[2]}");
      var expectedSignature = Sign(payload);
      try
      {
        if (!CryptographicOperations.FixedTimeEquals(expectedSignature, suppliedSignature))
        {
          return false;
        }
      }
      finally
      {
        CryptographicOperations.ZeroMemory(expectedSignature);
      }

      sessionUid = new EntityUid(parsedUid);
      return true;
    }
    finally
    {
      CryptographicOperations.ZeroMemory(suppliedSignature);
    }
  }

  public void Dispose()
  {
    var key = Interlocked.Exchange(ref _key, null);
    if (key is not null)
    {
      CryptographicOperations.ZeroMemory(key);
    }
  }

  private byte[] Sign(string payload)
  {
    var key = _key ?? throw new ObjectDisposedException(nameof(PrivateServerSessionTokenProtector));
    var bytes = Encoding.UTF8.GetBytes(payload);
    try
    {
      return HMACSHA256.HashData(key, bytes);
    }
    finally
    {
      CryptographicOperations.ZeroMemory(bytes);
    }
  }

  private static string Base64Url(ReadOnlySpan<byte> value) =>
      Convert.ToBase64String(value).TrimEnd('=').Replace('+', '-').Replace('/', '_');

  private static bool TryDecodeSignature(string value, out byte[] bytes)
  {
    bytes = [];
    if (value.Length != 43 || value.Any(static character =>
            !((character >= 'a' && character <= 'z') ||
              (character >= 'A' && character <= 'Z') ||
              (character >= '0' && character <= '9') ||
              character is '-' or '_')))
    {
      return false;
    }

    try
    {
      bytes = Convert.FromBase64String(value.Replace('-', '+').Replace('_', '/') + "=");
      if (bytes.Length == 32 &&
          string.Equals(value, Base64Url(bytes), StringComparison.Ordinal))
      {
        return true;
      }

      CryptographicOperations.ZeroMemory(bytes);
      bytes = [];
      return false;
    }
    catch (FormatException)
    {
      return false;
    }
  }
}

internal readonly record struct PrivateServerSessionGrant(
    string Token,
    DateTimeOffset ExpiresAtUtc);
