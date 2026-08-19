using System.Reflection;

namespace NikkeLocalLab.Profile.UnitTests;

public sealed class PublicSurfaceTests
{
  [Fact]
  public void Public_profile_surface_has_no_original_identity_path_or_secret_fields()
  {
    var forbiddenFragments = new[]
    {
      "raw",
      "source",
      "alias",
      "fingerprint",
      "credential",
      "token",
      "password",
      "path"
    };
    var members = typeof(LocalAccount).Assembly.GetExportedTypes()
        .Where(type => type.Namespace == typeof(LocalAccount).Namespace)
        .SelectMany(type => type.GetMembers(
            BindingFlags.Public |
            BindingFlags.Instance |
            BindingFlags.Static |
            BindingFlags.DeclaredOnly))
        .Select(member => $"{member.DeclaringType?.FullName}.{member.Name}")
        .ToArray();

    foreach (var member in members)
    {
      Assert.DoesNotContain(
          forbiddenFragments,
          fragment => member.Contains(fragment, StringComparison.OrdinalIgnoreCase));
    }
  }

  [Fact]
  public void Canonical_contracts_have_no_trailing_newline_and_use_only_local_references()
  {
    var catalog = ProfileTestData.SupportCatalog();
    var build = ProfileTestData.ExplicitBuild(20, 21, 10, catalog);
    var canonical = ProfileCanonicalizer.ToCanonicalText(build.Content);

    Assert.StartsWith(ProfileCanonicalizer.CharacterBuildContractId, canonical, StringComparison.Ordinal);
    Assert.False(canonical.EndsWith('\n'));
    Assert.DoesNotContain("raw", canonical, StringComparison.OrdinalIgnoreCase);
    Assert.DoesNotContain("alias", canonical, StringComparison.OrdinalIgnoreCase);
    Assert.DoesNotContain("path", canonical, StringComparison.OrdinalIgnoreCase);
    Assert.Equal(build.ContentSha256, Sha256Digest.ComputeUtf8(canonical));
  }

  [Fact]
  public void Trusted_catalog_evidence_and_persisted_projection_are_not_public_factories()
  {
    Assert.Empty(typeof(ProfileCatalogEvidence).GetConstructors(
        BindingFlags.Public | BindingFlags.Instance));
    Assert.DoesNotContain(
        typeof(ProfileCatalogEvidence).GetMethods(BindingFlags.Public | BindingFlags.Static),
        method => method.ReturnType == typeof(ProfileCatalogEvidence));
    Assert.False(typeof(ProfilePersistedProjection).IsPublic);
  }
}
