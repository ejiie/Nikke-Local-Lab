using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Domain.Raid;

public sealed class RaidArtifactReference
{
  public RaidArtifactReference(EntityUid artifactUid, Sha256Digest sha256)
  {
    ArtifactUid = RaidDomainGuard.RequireUid(artifactUid, nameof(artifactUid));
    Sha256 = RaidDomainGuard.RequireDigest(sha256, nameof(sha256));
  }

  public EntityUid ArtifactUid { get; }

  public Sha256Digest Sha256 { get; }
}

public enum AssetBundleRole
{
  Stage,
  Model,
  Behavior,
  Timeline,
  Animation,
  Audio,
  Other,
}

public sealed class SelectedAssetBundle
{
  public SelectedAssetBundle(
      EntityUid artifactUid,
      Sha256Digest sha256,
      IEnumerable<AssetBundleRole> roles)
  {
    ArtifactUid = RaidDomainGuard.RequireUid(artifactUid, nameof(artifactUid));
    Sha256 = RaidDomainGuard.RequireDigest(sha256, nameof(sha256));
    ArgumentNullException.ThrowIfNull(roles);

    var normalizedRoles = roles
        .Distinct()
        .OrderBy(RaidCanonicalCodes.AssetBundleRole, StringComparer.Ordinal)
        .ToArray();
    if (normalizedRoles.Length == 0)
    {
      throw new ArgumentException("A selected asset bundle must have at least one role.", nameof(roles));
    }

    Roles = Array.AsReadOnly(normalizedRoles);
  }

  public EntityUid ArtifactUid { get; }

  public Sha256Digest Sha256 { get; }

  public IReadOnlyList<AssetBundleRole> Roles { get; }
}

public static class AssetBundleSetCanonicalizer
{
  public static Sha256Digest ComputeHash(IEnumerable<SelectedAssetBundle> bundles)
  {
    ArgumentNullException.ThrowIfNull(bundles);
    var digests = bundles
        .Select(static bundle => bundle ??
            throw new ArgumentException("An asset bundle set cannot contain null entries.", nameof(bundles)))
        .Select(static bundle => bundle.Sha256.ToString())
        .Distinct(StringComparer.Ordinal)
        .OrderBy(static digest => digest, StringComparer.Ordinal)
        .ToArray();
    if (digests.Length == 0)
    {
      throw new ArgumentException("An asset bundle set cannot be empty.", nameof(bundles));
    }

    return Sha256Digest.ComputeUtf8(string.Join('\n', digests));
  }
}

public sealed class TimelineArtifactReference
{
  public TimelineArtifactReference(
      RaidArtifactReference artifact,
      IEnumerable<ClockBasis> clockBases)
  {
    Artifact = artifact ?? throw new ArgumentNullException(nameof(artifact));
    ArgumentNullException.ThrowIfNull(clockBases);
    var normalizedBases = clockBases
        .Distinct()
        .OrderBy(RaidCanonicalCodes.ClockBasis, StringComparer.Ordinal)
        .ToArray();
    if (normalizedBases.Length == 0)
    {
      throw new ArgumentException("A timeline artifact must declare at least one clock basis.", nameof(clockBases));
    }

    ClockBases = Array.AsReadOnly(normalizedBases);
  }

  public RaidArtifactReference Artifact { get; }

  public IReadOnlyList<ClockBasis> ClockBases { get; }
}
