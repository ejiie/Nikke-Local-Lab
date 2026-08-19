using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Domain.Profile;

public sealed class LocalAccount
{
  public LocalAccount(EntityUid localAccountUid, DateTimeOffset createdAtUtc)
  {
    LocalAccountUid = ProfileGuard.RequireUid(localAccountUid, nameof(localAccountUid));
    CreatedAtUtc = ProfileGuard.RequireUtc(createdAtUtc, nameof(createdAtUtc));
    CanonicalSha256 = LocalAccountCanonicalizer.ComputeHash(this);
  }

  public EntityUid LocalAccountUid { get; }

  public DateTimeOffset CreatedAtUtc { get; }

  public Sha256Digest CanonicalSha256 { get; }
}

public enum LocalSessionStatus
{
  Active,
  Expired,
  Revoked
}

/// <summary>
/// A lab-owned session marker. It deliberately carries no bearer secret or official credential semantics.
/// </summary>
public sealed class LocalSession
{
  private LocalSession(
      EntityUid localSessionUid,
      EntityUid localAccountUid,
      DateTimeOffset issuedAtUtc,
      DateTimeOffset expiresAtUtc,
      LocalSessionStatus status,
      DateTimeOffset statusRecordedAtUtc)
  {
    LocalSessionUid = ProfileGuard.RequireUid(localSessionUid, nameof(localSessionUid));
    LocalAccountUid = ProfileGuard.RequireUid(localAccountUid, nameof(localAccountUid));
    IssuedAtUtc = ProfileGuard.RequireUtc(issuedAtUtc, nameof(issuedAtUtc));
    ExpiresAtUtc = ProfileGuard.RequireUtc(expiresAtUtc, nameof(expiresAtUtc));
    Status = ProfileGuard.RequireEnum(status, nameof(status));
    StatusRecordedAtUtc = ProfileGuard.RequireUtc(statusRecordedAtUtc, nameof(statusRecordedAtUtc));

    if (ExpiresAtUtc <= IssuedAtUtc || StatusRecordedAtUtc < IssuedAtUtc)
    {
      throw new ArgumentException("A local session has an invalid UTC lifetime.");
    }

    if (Status == LocalSessionStatus.Active && StatusRecordedAtUtc >= ExpiresAtUtc)
    {
      throw new ArgumentException("An active session cannot be recorded at or after its expiration.", nameof(status));
    }

    if (Status == LocalSessionStatus.Expired && StatusRecordedAtUtc < ExpiresAtUtc)
    {
      throw new ArgumentException("An expired session must be recorded at or after its expiration.", nameof(status));
    }

    CanonicalSha256 = LocalSessionCanonicalizer.ComputeHash(this);
  }

  public EntityUid LocalSessionUid { get; }

  public EntityUid LocalAccountUid { get; }

  public DateTimeOffset IssuedAtUtc { get; }

  public DateTimeOffset ExpiresAtUtc { get; }

  public LocalSessionStatus Status { get; }

  public DateTimeOffset StatusRecordedAtUtc { get; }

  public DateTimeOffset? RevokedAtUtc => Status == LocalSessionStatus.Revoked
      ? StatusRecordedAtUtc
      : null;

  public Sha256Digest CanonicalSha256 { get; }

  public static LocalSession Issue(
      EntityUid localSessionUid,
      LocalAccount account,
      DateTimeOffset issuedAtUtc,
      DateTimeOffset expiresAtUtc)
  {
    ArgumentNullException.ThrowIfNull(account);
    return new LocalSession(
        localSessionUid,
        account.LocalAccountUid,
        issuedAtUtc,
        expiresAtUtc,
        LocalSessionStatus.Active,
        issuedAtUtc);
  }

  public LocalSession Expire(DateTimeOffset recordedAtUtc)
  {
    if (Status != LocalSessionStatus.Active)
    {
      throw new InvalidOperationException("An expired or revoked session is terminal.");
    }

    return new(
          LocalSessionUid,
          LocalAccountUid,
          IssuedAtUtc,
          ExpiresAtUtc,
          LocalSessionStatus.Expired,
          recordedAtUtc);
  }

  public LocalSession Revoke(DateTimeOffset recordedAtUtc)
  {
    if (Status != LocalSessionStatus.Active)
    {
      throw new InvalidOperationException("An expired or revoked session is terminal.");
    }

    if (recordedAtUtc >= ExpiresAtUtc)
    {
      throw new ArgumentException("A session at or after its expiration must expire rather than revoke.", nameof(recordedAtUtc));
    }

    return new(
          LocalSessionUid,
          LocalAccountUid,
          IssuedAtUtc,
          ExpiresAtUtc,
          LocalSessionStatus.Revoked,
          recordedAtUtc);
  }
}
