using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Domain.Raid;

internal static class RaidDomainGuard
{
  public static EntityUid RequireUid(EntityUid value, string parameterName)
  {
    if (value.Value == Guid.Empty)
    {
      throw new ArgumentException("A raid domain UID cannot be empty.", parameterName);
    }

    return value;
  }

  public static Sha256Digest RequireDigest(Sha256Digest value, string parameterName)
  {
    if (value == default)
    {
      throw new ArgumentException("A raid artifact digest must be initialized.", parameterName);
    }

    return value;
  }

  public static IReadOnlyList<string> NormalizeCodes(
      IEnumerable<string>? values,
      string parameterName)
  {
    if (values is null)
    {
      return Array.Empty<string>();
    }

    var normalized = values
        .Select(value => ControlledCode.Require(value, parameterName))
        .Distinct(StringComparer.Ordinal)
        .OrderBy(static value => value, StringComparer.Ordinal)
        .ToArray();
    return Array.AsReadOnly(normalized);
  }
}
