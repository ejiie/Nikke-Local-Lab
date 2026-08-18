using NikkeLocalLab.Application.Importing;
using NikkeLocalLab.Import.CombatSupportCatalog;
using NikkeLocalLab.Persistence.PostgreSql;

namespace NikkeLocalLab.CombatSupport.UnitTests;

public sealed class CombatSupportCatalogCliCompositionTests
{
  [Fact]
  public void Synthetic_extraction_maps_the_exact_scoped_catalog_to_publication()
  {
    using var archive = SyntheticCombatSupportStaticData.Create();
    var secret = Enumerable.Range(1, 32).Select(static value => (byte)value).ToArray();
    var extraction = new StaticDataCombatSupportCatalogReader().Read(archive, secret);

    var publication = CombatSupportCatalogCli.ToPublication(extraction, secret);

    Assert.Equal(46, publication.Definitions.Count);
    Assert.Equal(24, publication.Definitions.Count(static item =>
        item.Kind == NikkeLocalLab.Persistence.PostgreSql.CombatSupportDefinitionKind.Equipment));
    Assert.Equal(1, publication.Definitions.Count(static item =>
        item.Kind == NikkeLocalLab.Persistence.PostgreSql.CombatSupportDefinitionKind.Cube));
    Assert.Equal(2, publication.Definitions.Count(static item =>
        item.Kind == NikkeLocalLab.Persistence.PostgreSql.CombatSupportDefinitionKind.Collection));
    Assert.Equal(1, publication.Definitions.Count(static item =>
        item.Kind == NikkeLocalLab.Persistence.PostgreSql.CombatSupportDefinitionKind.Favorite));
    Assert.Equal(9, publication.Definitions.Count(static item =>
        item.Kind == NikkeLocalLab.Persistence.PostgreSql.CombatSupportDefinitionKind.Console));
    Assert.Equal(9, publication.Definitions.Count(static item =>
        item.Kind == NikkeLocalLab.Persistence.PostgreSql.CombatSupportDefinitionKind.OverloadOption));

    var equipment = publication.Definitions
        .Select(static item => item.Payload)
        .OfType<CombatSupportEquipmentDefinitionPublication>()
        .ToArray();
    Assert.Equal(24, equipment.Select(static item => (
        item.CombatClass.Value,
        item.Slot,
        item.Tier.Value)).Distinct().Count());
    Assert.All(equipment, static item =>
    {
      Assert.Equal(NikkeLocalLab.Persistence.PostgreSql.CombatSupportFactStatus.NotApplicable,
          item.Manufacturer.Status);
      Assert.Equal(5, item.MaximumEnhancementLevel.Value);
      Assert.Equal(3, item.OptionSlots.Count);
    });

    var overload = publication.Definitions
        .Select(static item => item.Payload)
        .OfType<CombatSupportOverloadOptionDefinitionPublication>()
        .ToArray();
    var legalValues = overload.SelectMany(static item => item.LegalBands)
        .SelectMany(static item => item.OrderedValues)
        .ToArray();
    Assert.Equal(135, legalValues.Length);
    Assert.Equal(135, legalValues.Select(static item => item.SourceAliasFingerprint).Distinct().Count());
    Assert.All(overload, static item =>
    {
      Assert.Equal(15, item.LegalBands.Sum(static band => band.OrderedValues.Count));
      Assert.Equal(NikkeLocalLab.Persistence.PostgreSql.CombatSupportFactStatus.Unresolved,
          item.DuplicatePolicy.Status);
    });

    Assert.All(
        extraction.Diagnostics,
        static diagnostic => Assert.Equal(
            diagnostic.Code,
            CombatSupportCatalogCli.ToSafeDiagnostic(diagnostic).DiagnosticCode));
  }

  [Theory]
  [InlineData("collection_weapon_class_unknown")]
  [InlineData("combat_stat_unknown")]
  [InlineData("cube_stat_unit_unresolved")]
  [InlineData("favorite_character_relation_unresolved")]
  [InlineData("overload_duplicate_policy_unresolved")]
  [InlineData("skill_definition_catalog_not_imported")]
  public void Every_importer_diagnostic_has_a_safe_application_mapping(string code)
  {
    var safe = CombatSupportCatalogCli.ToSafeDiagnostic(
        new CombatSupportCatalogDiagnostic(code, 2));

    Assert.Equal(ImportDiagnosticSeverity.Warning, safe.Severity);
    Assert.Equal("combat_support_catalog", safe.StageCode);
    Assert.Equal(code, safe.DiagnosticCode);
    Assert.Equal(2, safe.OccurrenceCount);
  }

  [Fact]
  public void Unknown_diagnostic_is_rejected_at_the_cli_boundary()
  {
    Assert.Throws<ArgumentException>(() => CombatSupportCatalogCli.ToSafeDiagnostic(
        new CombatSupportCatalogDiagnostic("not_in_the_safe_catalog", 1)));
  }
}
