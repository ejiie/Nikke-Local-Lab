using System.Security.Cryptography;

namespace NikkeLocalLab.Admin.Api;

internal sealed class AdminAccessSessionManager
{
  public const string CookieName = "nll_admin_session";

  private static readonly TimeSpan BootstrapLifetime = TimeSpan.FromMinutes(5);
  // The desktop host owns this process and stops it with the application. Keep
  // an actively used local session alive for a full operator work period instead
  // of expiring midway through account editing or a game validation run.
  private const int MaximumBootstrapAttempts = 5;

  private readonly object _gate = new();
  private readonly TimeProvider _timeProvider;
  private readonly TimeSpan _sessionLifetime;
  private byte[]? _bootstrapCodeSha256;
  private readonly DateTimeOffset _bootstrapExpiresAtUtc;
  private int _failedBootstrapAttempts;
  private byte[]? _sessionTokenSha256;
  private DateTimeOffset? _sessionExpiresAtUtc;

  private AdminAccessSessionManager(
      TimeProvider timeProvider,
      TimeSpan sessionLifetime,
      byte[] bootstrapCodeSha256,
      DateTimeOffset bootstrapExpiresAtUtc)
  {
    _timeProvider = timeProvider;
    _sessionLifetime = sessionLifetime;
    _bootstrapCodeSha256 = bootstrapCodeSha256;
    _bootstrapExpiresAtUtc = bootstrapExpiresAtUtc;
  }

  public static AdminAccessSessionManager Create(
      TimeProvider timeProvider,
      TimeSpan sessionLifetime,
      Action<string> bootstrapCodeSink)
  {
    ArgumentNullException.ThrowIfNull(timeProvider);
    ArgumentNullException.ThrowIfNull(bootstrapCodeSink);
    if (sessionLifetime < TimeSpan.FromMinutes(1) || sessionLifetime > TimeSpan.FromHours(24))
    {
      throw new ArgumentOutOfRangeException(nameof(sessionLifetime));
    }
    var bytes = RandomNumberGenerator.GetBytes(32);
    try
    {
      var code = Base64Url(bytes);
      var manager = new AdminAccessSessionManager(
          timeProvider,
          sessionLifetime,
          SHA256.HashData(bytes),
          timeProvider.GetUtcNow().Add(BootstrapLifetime));
      try
      {
        bootstrapCodeSink(code);
        return manager;
      }
      catch
      {
        if (manager._bootstrapCodeSha256 is not null)
        {
          CryptographicOperations.ZeroMemory(manager._bootstrapCodeSha256);
          manager._bootstrapCodeSha256 = null;
        }

        throw;
      }
    }
    finally
    {
      CryptographicOperations.ZeroMemory(bytes);
    }
  }

  public bool TryExchange(string? bootstrapCode, out AdminSessionGrant session)
  {
    session = default;
    byte[] candidateBytes;
    try
    {
      candidateBytes = DecodeBase64Url(bootstrapCode);
    }
    catch (FormatException)
    {
      RegisterFailedAttempt();
      return false;
    }

    try
    {
      var candidateHash = SHA256.HashData(candidateBytes);
      try
      {
        lock (_gate)
        {
          if (_bootstrapCodeSha256 is null ||
              _failedBootstrapAttempts >= MaximumBootstrapAttempts ||
              _timeProvider.GetUtcNow() >= _bootstrapExpiresAtUtc ||
              !CryptographicOperations.FixedTimeEquals(candidateHash, _bootstrapCodeSha256))
          {
            _failedBootstrapAttempts++;
            InvalidateBootstrapIfExhausted();
            return false;
          }

          CryptographicOperations.ZeroMemory(_bootstrapCodeSha256);
          _bootstrapCodeSha256 = null;
          var tokenBytes = RandomNumberGenerator.GetBytes(32);
          try
          {
            _sessionTokenSha256 = SHA256.HashData(tokenBytes);
            _sessionExpiresAtUtc = _timeProvider.GetUtcNow().Add(_sessionLifetime);
            session = new AdminSessionGrant(Base64Url(tokenBytes), _sessionExpiresAtUtc.Value);
            return true;
          }
          finally
          {
            CryptographicOperations.ZeroMemory(tokenBytes);
          }
        }
      }
      finally
      {
        CryptographicOperations.ZeroMemory(candidateHash);
      }
    }
    finally
    {
      CryptographicOperations.ZeroMemory(candidateBytes);
    }
  }

  public bool TryRefreshSession(string? token, out DateTimeOffset expiresAtUtc)
  {
    expiresAtUtc = default;
    byte[] tokenBytes;
    try
    {
      tokenBytes = DecodeBase64Url(token);
    }
    catch (FormatException)
    {
      return false;
    }

    try
    {
      var candidateHash = SHA256.HashData(tokenBytes);
      try
      {
        lock (_gate)
        {
          if (_sessionTokenSha256 is null || _sessionExpiresAtUtc is null ||
              _timeProvider.GetUtcNow() >= _sessionExpiresAtUtc.Value)
          {
            InvalidateSession();
            return false;
          }

          if (!CryptographicOperations.FixedTimeEquals(candidateHash, _sessionTokenSha256))
          {
            return false;
          }

          _sessionExpiresAtUtc = _timeProvider.GetUtcNow().Add(_sessionLifetime);
          expiresAtUtc = _sessionExpiresAtUtc.Value;
          return true;
        }
      }
      finally
      {
        CryptographicOperations.ZeroMemory(candidateHash);
      }
    }
    finally
    {
      CryptographicOperations.ZeroMemory(tokenBytes);
    }
  }

  private void RegisterFailedAttempt()
  {
    lock (_gate)
    {
      _failedBootstrapAttempts++;
      InvalidateBootstrapIfExhausted();
    }
  }

  private void InvalidateBootstrapIfExhausted()
  {
    if (_failedBootstrapAttempts < MaximumBootstrapAttempts || _bootstrapCodeSha256 is null)
    {
      return;
    }

    CryptographicOperations.ZeroMemory(_bootstrapCodeSha256);
    _bootstrapCodeSha256 = null;
  }

  private void InvalidateSession()
  {
    if (_sessionTokenSha256 is not null)
    {
      CryptographicOperations.ZeroMemory(_sessionTokenSha256);
      _sessionTokenSha256 = null;
    }

    _sessionExpiresAtUtc = null;
  }

  private static string Base64Url(ReadOnlySpan<byte> bytes) =>
      Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');

  private static byte[] DecodeBase64Url(string? value)
  {
    if (string.IsNullOrEmpty(value) || value.Length != 43 ||
        value.Any(character =>
            !((character >= 'a' && character <= 'z') ||
              (character >= 'A' && character <= 'Z') ||
              (character >= '0' && character <= '9') ||
              character is '-' or '_')))
    {
      throw new FormatException();
    }

    var normalized = value.Replace('-', '+').Replace('_', '/') + "=";
    return Convert.FromBase64String(normalized);
  }
}

internal readonly record struct AdminSessionGrant(string Token, DateTimeOffset ExpiresAtUtc);
