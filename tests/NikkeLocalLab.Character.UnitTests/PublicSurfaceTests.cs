using System.Reflection;

namespace NikkeLocalLab.Character.UnitTests;

public sealed class PublicSurfaceTests
{
  [Fact]
  public void Public_domain_surface_does_not_offer_source_identity_or_alias_fields()
  {
    var forbiddenFragments = new[] { "raw", "source", "alias", "fingerprint" };
    var publicMembers = typeof(CharacterDefinition).Assembly
        .GetExportedTypes()
        .Where(type => type.Namespace == typeof(CharacterDefinition).Namespace)
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
