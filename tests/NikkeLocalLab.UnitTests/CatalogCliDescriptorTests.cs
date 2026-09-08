using System.Runtime.CompilerServices;
using Xunit;

public sealed class CatalogCliDescriptorTests
{
  [Fact]
  public void Catalog_cli_descriptors_use_valid_controlled_versions()
  {
    var catalogCliTypes = new[]
    {
      typeof(CharacterCatalogCli),
      typeof(CombatSupportCatalogCli),
      typeof(RaidCatalogCli)
    };

    foreach (var catalogCliType in catalogCliTypes)
    {
      var exception = Record.Exception(
          () => RuntimeHelpers.RunClassConstructor(catalogCliType.TypeHandle));

      Assert.Null(exception);
    }
  }
}
