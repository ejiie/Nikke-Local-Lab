using System.Security.Cryptography;
using NikkeLocalLab.Domain.CombatSupport;
using NikkeLocalLab.Import.CombatSupportCatalog;

namespace NikkeLocalLab.CombatSupport.UnitTests;

public sealed class RetainedStaticDataSmokeTests
{
  [Fact]
  public void RetainedSnapshotIsReadOnlyAndMatchesAggregateOracle()
  {
    var archivePath = Environment.GetEnvironmentVariable("NLL_RETAINED_STATICDATA_SMOKE");
    if (string.IsNullOrWhiteSpace(archivePath))
    {
      return;
    }

    var before = ReadDigest(archivePath);
    var secret = RandomNumberGenerator.GetBytes(32);
    CombatSupportCatalogExtraction extraction;
    NikkeLocalLab.Persistence.PostgreSql.CombatSupportCatalogPublication publication;
    try
    {
      using var source = new FileStream(
          archivePath,
          FileMode.Open,
          FileAccess.Read,
          FileShare.Read);
      extraction = new StaticDataCombatSupportCatalogReader().Read(source, secret);
      publication = CombatSupportCatalogCli.ToPublication(extraction, secret);
    }
    finally
    {
      CryptographicOperations.ZeroMemory(secret);
    }

    var after = ReadDigest(archivePath);
    Assert.Equal(before, after);
    Assert.Equal(92, extraction.Definitions.Count);
    Assert.Equal(92, publication.Definitions.Count);
    Assert.All(
        extraction.Diagnostics,
        static diagnostic => Assert.Equal(
            diagnostic.Code,
            CombatSupportCatalogCli.ToSafeDiagnostic(diagnostic).DiagnosticCode));
    Assert.Equal(24, extraction.Count(CombatSupportDefinitionKind.Equipment));
    Assert.Equal(17, extraction.Count(CombatSupportDefinitionKind.HarmonyCube));
    Assert.Equal(12, extraction.Count(CombatSupportDefinitionKind.GenericCollection));
    Assert.Equal(21, extraction.Count(CombatSupportDefinitionKind.Favorite));
    Assert.Equal(9, extraction.Count(CombatSupportDefinitionKind.Console));
    Assert.Equal(9, extraction.Count(CombatSupportDefinitionKind.OverloadOption));
    var diagnostics = extraction.Diagnostics.ToDictionary(static item => item.Code, static item => item.OccurrenceCount);
    Assert.Equal(3, diagnostics.Count);
    Assert.Equal(765, diagnostics["cube_stat_unit_unresolved"]);
    Assert.Equal(50, diagnostics["skill_definition_catalog_not_imported"]);
    Assert.Equal(9, diagnostics["overload_duplicate_policy_unresolved"]);

    var equipment = extraction.Definitions
        .Select(static item => item.Payload)
        .OfType<ImportedEquipmentDefinitionPayload>()
        .ToArray();
    Assert.Equal(48, equipment.Sum(static item => item.BaseStats.Count));
    Assert.All(equipment, static item =>
    {
      Assert.Equal(CombatSupportFactStatus.NotApplicable, item.Manufacturer.Status);
      Assert.Equal(0, item.EnhancementGrade.Value);
      Assert.Equal(5, item.MaximumEnhancementLevel.Value);
    });

    var cubes = extraction.Definitions
        .Select(static item => item.Payload)
        .OfType<ImportedHarmonyCubeDefinitionPayload>()
        .ToArray();
    Assert.Equal(255, cubes.Sum(static item => item.Levels.Count));
    Assert.All(cubes, static item =>
    {
      Assert.Equal(CombatSupportRarity.Ssr, item.Rarity.Value);
      Assert.Equal(CombatSupportFactStatus.NotApplicable, item.ApplicableCombatRole.Status);
      Assert.Equal(CombatSupportFactStatus.Unresolved, item.SkillSemantics.Status);
    });

    var collections = extraction.Definitions
        .Select(static item => item.Payload)
        .OfType<ImportedGenericCollectionDefinitionPayload>()
        .ToArray();
    Assert.Equal(6, collections.Count(static item => item.Rarity.Value == CombatSupportRarity.R));
    Assert.Equal(6, collections.Count(static item => item.Rarity.Value == CombatSupportRarity.Sr));

    var collectionLevelCount = extraction.Definitions.Select(static item => item.Payload)
        .Where(static item => item is ImportedGenericCollectionDefinitionPayload or ImportedFavoriteDefinitionPayload)
        .Sum(static item => item switch
        {
          ImportedGenericCollectionDefinitionPayload collection => collection.Levels.Count,
          ImportedFavoriteDefinitionPayload favorite => favorite.Levels.Count,
          _ => 0
        });
    Assert.Equal(255, collectionLevelCount);

    var consoles = extraction.Definitions.Select(static item => item.Payload)
        .OfType<ImportedConsoleDefinitionPayload>()
        .ToArray();
    Assert.Equal(6_120, consoles.Sum(static item => item.Levels.Count));
    Assert.All(consoles, static item => Assert.Equal(680, item.MaximumLevel.Value));

    var overload = extraction.Definitions.Select(static item => item.Payload)
        .OfType<ImportedOverloadOptionDefinitionPayload>()
        .ToArray();
    Assert.Equal(135, overload.Sum(static item => item.LegalBands.Sum(static band => band.OrderedValues.Count)));
    Assert.Equal(135, overload.Sum(static item => item.LegalValueAliases.Count));
    Assert.All(overload, static item => Assert.Equal(15, item.LegalValueAliases.Count));
    Assert.All(
        overload.Where(static item => item.OptionType.Value is
            CombatSupportOverloadOptionType.ChargeSpeed or CombatSupportOverloadOptionType.HitRate)
            .SelectMany(static item => item.LegalBands)
            .SelectMany(static item => item.OrderedValues),
        static item => Assert.True(item.SourceRawValue < 0));
  }

  [Fact]
  public void LegacyRetainedSnapshotDerivesItsConsoleMaximumWithoutMutation()
  {
    var archivePath = Environment.GetEnvironmentVariable("NLL_LEGACY_STATICDATA_SMOKE");
    if (string.IsNullOrWhiteSpace(archivePath))
    {
      return;
    }

    var before = ReadDigest(archivePath);
    var secret = RandomNumberGenerator.GetBytes(32);
    CombatSupportCatalogExtraction extraction;
    try
    {
      using var source = new FileStream(
          archivePath,
          FileMode.Open,
          FileAccess.Read,
          FileShare.Read);
      extraction = new StaticDataCombatSupportCatalogReader().Read(source, secret);
      _ = CombatSupportCatalogCli.ToPublication(extraction, secret);
    }
    finally
    {
      CryptographicOperations.ZeroMemory(secret);
    }

    Assert.Equal(before, ReadDigest(archivePath));
    var consoles = extraction.Definitions.Select(static item => item.Payload)
        .OfType<ImportedConsoleDefinitionPayload>()
        .ToArray();
    Assert.Equal(9, consoles.Length);
    Assert.Equal(5_220, consoles.Sum(static item => item.Levels.Count));
    Assert.All(consoles, static item => Assert.Equal(580, item.MaximumLevel.Value));
  }

  private static byte[] ReadDigest(string path)
  {
    using var source = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
    return SHA256.HashData(source);
  }
}
