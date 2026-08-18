using System.Reflection;

namespace NikkeLocalLab.Raid.UnitTests;

public sealed class PublicSurfaceTests
{
  [Fact]
  public void Public_raid_domain_surface_does_not_expose_origin_identity_or_storage_location()
  {
    var forbiddenFragments = new[]
    {
      "raw",
      "source",
      "alias",
      "fingerprint",
      "path",
      "filename",
    };
    var publicMembers = typeof(RaidSnapshot).Assembly
        .GetExportedTypes()
        .Where(type => type.Namespace == typeof(RaidSnapshot).Namespace)
        .SelectMany(type => type.GetMembers(BindingFlags.Public | BindingFlags.Instance | BindingFlags.Static |
                                            BindingFlags.DeclaredOnly))
        .Select(member => $"{member.DeclaringType?.FullName}.{member.Name}")
        .ToArray();

    foreach (var member in publicMembers)
    {
      Assert.DoesNotContain(
          forbiddenFragments,
          fragment => member.Contains(fragment, StringComparison.OrdinalIgnoreCase));
    }
  }
}
