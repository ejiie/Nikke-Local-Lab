using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Domain.Profile;

public enum ProfileFactStatus
{
  Ready,
  Unresolved,
  NotApplicable
}

public sealed class ProfileFact<T> : IEquatable<ProfileFact<T>>
    where T : struct
{
  private ProfileFact(ProfileFactStatus status, T? value, string? reasonCode)
  {
    Status = status;
    Value = value;
    ReasonCode = reasonCode;
  }

  public ProfileFactStatus Status { get; }

  public T? Value { get; }

  public string? ReasonCode { get; }

  public bool IsResolved => Status is ProfileFactStatus.Ready or ProfileFactStatus.NotApplicable;

  public static ProfileFact<T> Ready(T value) => new(ProfileFactStatus.Ready, value, null);

  public static ProfileFact<T> Unresolved(string reasonCode) =>
      new(ProfileFactStatus.Unresolved, null, ControlledCode.Require(reasonCode, nameof(reasonCode)));

  public static ProfileFact<T> NotApplicable() => new(ProfileFactStatus.NotApplicable, null, null);

  public T RequireValue()
  {
    if (Status != ProfileFactStatus.Ready || Value is null)
    {
      throw new InvalidOperationException("Only a ready profile fact has a value.");
    }

    return Value.Value;
  }

  public bool Equals(ProfileFact<T>? other) =>
      other is not null &&
      Status == other.Status &&
      EqualityComparer<T?>.Default.Equals(Value, other.Value) &&
      string.Equals(ReasonCode, other.ReasonCode, StringComparison.Ordinal);

  public override bool Equals(object? obj) => obj is ProfileFact<T> other && Equals(other);

  public override int GetHashCode() => HashCode.Combine(Status, Value, ReasonCode);
}

public enum ProfileReadiness
{
  Ready,
  Unresolved,
  Invalid
}

public enum ProfileValidationMode
{
  Research,
  GameLegal
}

public enum ProfileIssueKind
{
  Unresolved,
  Invalid
}

public sealed class ProfileValidationIssue
{
  internal ProfileValidationIssue(ProfileIssueKind kind, string fieldCode, string reasonCode)
  {
    Kind = kind;
    FieldCode = ControlledCode.Require(fieldCode, nameof(fieldCode));
    ReasonCode = ControlledCode.Require(reasonCode, nameof(reasonCode));
  }

  public ProfileIssueKind Kind { get; }

  public string FieldCode { get; }

  public string ReasonCode { get; }
}

public sealed class ProfileValidationResult
{
  internal ProfileValidationResult(IEnumerable<ProfileValidationIssue> issues)
  {
    ArgumentNullException.ThrowIfNull(issues);
    var normalized = issues.ToArray();
    if (normalized.Any(static issue => issue is null))
    {
      throw new ArgumentException("Validation issues cannot contain null entries.", nameof(issues));
    }

    Issues = Array.AsReadOnly(normalized);
    Status = normalized.Any(static issue => issue.Kind == ProfileIssueKind.Invalid)
        ? ProfileReadiness.Invalid
        : normalized.Any(static issue => issue.Kind == ProfileIssueKind.Unresolved)
            ? ProfileReadiness.Unresolved
            : ProfileReadiness.Ready;
  }

  public ProfileReadiness Status { get; }

  public IReadOnlyList<ProfileValidationIssue> Issues { get; }

  internal static ProfileValidationResult Ready { get; } = new(Array.Empty<ProfileValidationIssue>());
}

public sealed class ProfileCatalogBinding : IEquatable<ProfileCatalogBinding>
{
  public ProfileCatalogBinding(
      EntityUid catalogSnapshotUid,
      EntityUid datasetSnapshotUid,
      Sha256Digest catalogManifestSha256)
  {
    CatalogSnapshotUid = ProfileGuard.RequireUid(catalogSnapshotUid, nameof(catalogSnapshotUid));
    DatasetSnapshotUid = ProfileGuard.RequireUid(datasetSnapshotUid, nameof(datasetSnapshotUid));
    CatalogManifestSha256 = ProfileGuard.RequireDigest(catalogManifestSha256, nameof(catalogManifestSha256));
  }

  public EntityUid CatalogSnapshotUid { get; }

  public EntityUid DatasetSnapshotUid { get; }

  public Sha256Digest CatalogManifestSha256 { get; }

  public bool Equals(ProfileCatalogBinding? other) =>
      other is not null &&
      CatalogSnapshotUid == other.CatalogSnapshotUid &&
      DatasetSnapshotUid == other.DatasetSnapshotUid &&
      CatalogManifestSha256 == other.CatalogManifestSha256;

  public override bool Equals(object? obj) => obj is ProfileCatalogBinding other && Equals(other);

  public override int GetHashCode() => HashCode.Combine(CatalogSnapshotUid, DatasetSnapshotUid, CatalogManifestSha256);
}

public sealed class ProfileDatasetBinding : IEquatable<ProfileDatasetBinding>
{
  public ProfileDatasetBinding(
      ProfileCatalogBinding characterCatalog,
      ProfileCatalogBinding combatSupportCatalog)
  {
    CharacterCatalog = characterCatalog ?? throw new ArgumentNullException(nameof(characterCatalog));
    CombatSupportCatalog = combatSupportCatalog ?? throw new ArgumentNullException(nameof(combatSupportCatalog));
  }

  public ProfileCatalogBinding CharacterCatalog { get; }

  public ProfileCatalogBinding CombatSupportCatalog { get; }

  public bool Equals(ProfileDatasetBinding? other) =>
      other is not null &&
      CharacterCatalog.Equals(other.CharacterCatalog) &&
      CombatSupportCatalog.Equals(other.CombatSupportCatalog);

  public override bool Equals(object? obj) => obj is ProfileDatasetBinding other && Equals(other);

  public override int GetHashCode() => HashCode.Combine(CharacterCatalog, CombatSupportCatalog);
}

public enum ProfileRevisionOrigin
{
  UserEdit,
  CombatMaxV1,
  OfflineSanitizedImport,
  Rebase
}

public sealed class ProfileRevisionProvenance
{
  public ProfileRevisionProvenance(
      ProfileRevisionOrigin origin,
      DateTimeOffset materializedAtUtc,
      EntityUid? previousRevisionUid)
  {
    if (!Enum.IsDefined(origin))
    {
      throw new ArgumentOutOfRangeException(nameof(origin));
    }

    Origin = origin;
    MaterializedAtUtc = ProfileGuard.RequireUtc(materializedAtUtc, nameof(materializedAtUtc));
    PreviousRevisionUid = previousRevisionUid is { } uid
        ? ProfileGuard.RequireUid(uid, nameof(previousRevisionUid))
        : null;
  }

  public ProfileRevisionOrigin Origin { get; }

  public DateTimeOffset MaterializedAtUtc { get; }

  public EntityUid? PreviousRevisionUid { get; }
}

internal static class ProfileGuard
{
  public static EntityUid RequireUid(EntityUid value, string parameterName)
  {
    if (value.Value == Guid.Empty)
    {
      throw new ArgumentException("A Local Lab UID cannot be empty.", parameterName);
    }

    return value;
  }

  public static Sha256Digest RequireDigest(Sha256Digest value, string parameterName)
  {
    if (!Sha256Digest.TryParse(value.ToString(), out _))
    {
      throw new ArgumentException("A canonical SHA-256 digest is required.", parameterName);
    }

    return value;
  }

  public static DateTimeOffset RequireUtc(DateTimeOffset value, string parameterName)
  {
    if (value.Offset != TimeSpan.Zero)
    {
      throw new ArgumentException("A profile timestamp must be expressed in UTC.", parameterName);
    }

    return value;
  }

  public static void RequireRevision(long revisionNumber, ProfileRevisionProvenance provenance)
  {
    ArgumentNullException.ThrowIfNull(provenance);
    if (revisionNumber <= 0)
    {
      throw new ArgumentOutOfRangeException(nameof(revisionNumber));
    }

    if ((revisionNumber == 1) != (provenance.PreviousRevisionUid is null))
    {
      throw new ArgumentException(
          "Revision one must have no predecessor and later revisions must name their exact predecessor.",
          nameof(provenance));
    }
  }

  public static T RequireEnum<T>(T value, string parameterName)
      where T : struct, Enum
  {
    if (!Enum.IsDefined(value))
    {
      throw new ArgumentOutOfRangeException(parameterName);
    }

    return value;
  }

  public static ProfileFact<T> RequireFact<T>(ProfileFact<T> fact, string parameterName)
      where T : struct => fact ?? throw new ArgumentNullException(parameterName);

  public static ProfileValidationIssue Unresolved(string fieldCode, string reasonCode) =>
      new(ProfileIssueKind.Unresolved, fieldCode, reasonCode);

  public static ProfileValidationIssue Invalid(string fieldCode, string reasonCode) =>
      new(ProfileIssueKind.Invalid, fieldCode, reasonCode);

  public static void AddRequiredFactIssue<T>(
      ProfileFact<T> fact,
      string fieldCode,
      ICollection<ProfileValidationIssue> issues)
      where T : struct
  {
    if (fact.Status == ProfileFactStatus.Unresolved)
    {
      issues.Add(Unresolved(fieldCode, fact.ReasonCode ?? "missing_reason_code"));
    }
    else if (fact.Status == ProfileFactStatus.NotApplicable)
    {
      issues.Add(Invalid(fieldCode, "not_applicable_for_required_field"));
    }
  }
}
