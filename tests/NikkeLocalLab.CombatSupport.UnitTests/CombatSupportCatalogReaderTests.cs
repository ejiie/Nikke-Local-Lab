using System.IO.Compression;
using System.Security.Cryptography;
using NikkeLocalLab.Domain.CombatSupport;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Import.CombatSupportCatalog;

namespace NikkeLocalLab.CombatSupport.UnitTests;

public sealed class CombatSupportCatalogReaderTests
{
  [Fact]
  public void SyntheticArchivePreservesScopedDefinitionsAndSourceFreeCanonicalContent()
  {
    using var source = SyntheticCombatSupportStaticData.Create();
    var extraction = Read(source);

    Assert.Equal(46, extraction.Definitions.Count);
    Assert.Equal(24, extraction.Count(CombatSupportDefinitionKind.Equipment));
    Assert.Equal(1, extraction.Count(CombatSupportDefinitionKind.HarmonyCube));
    Assert.Equal(2, extraction.Count(CombatSupportDefinitionKind.GenericCollection));
    Assert.Equal(1, extraction.Count(CombatSupportDefinitionKind.Favorite));
    Assert.Equal(9, extraction.Count(CombatSupportDefinitionKind.Console));
    Assert.Equal(9, extraction.Count(CombatSupportDefinitionKind.OverloadOption));

    var diagnosticCounts = extraction.Diagnostics.ToDictionary(static item => item.Code, static item => item.OccurrenceCount);
    Assert.Equal(45, diagnosticCounts["cube_stat_unit_unresolved"]);
    Assert.Equal(4, diagnosticCounts["skill_definition_catalog_not_imported"]);
    Assert.Equal(9, diagnosticCounts["overload_duplicate_policy_unresolved"]);

    var equipment = extraction.Definitions.Select(static item => item.Payload)
        .OfType<ImportedEquipmentDefinitionPayload>()
        .ToArray();
    Assert.Equal(24, equipment.Length);
    Assert.All(equipment, static item =>
    {
      Assert.Equal(CombatSupportFactStatus.NotApplicable, item.Manufacturer.Status);
      Assert.Equal(0, item.EnhancementGrade.Value);
      Assert.Equal(5, item.MaximumEnhancementLevel.Value);
      Assert.Equal(2, item.BaseStats.Count);
      Assert.Equal(3, item.OptionSlots.Count);
    });
    Assert.Equal(
        12,
        equipment.Count(static item => item.Tier.Value == 10 && item.OverloadEligible.Value == true));
    Assert.Equal(
        12,
        equipment.Count(static item => item.Tier.Value == 9 && item.OverloadEligible.Value == false));

    var collections = extraction.Definitions.Select(static item => item.Payload)
        .OfType<ImportedGenericCollectionDefinitionPayload>()
        .OrderBy(static item => item.Rarity.Value)
        .ToArray();
    Assert.Equal([CombatSupportRarity.R, CombatSupportRarity.Sr], collections.Select(static item => item.Rarity.Value));
    Assert.All(collections, static item =>
        Assert.Equal(CombatSupportFactStatus.Unresolved, item.SkillSemantics.Status));

    var overload = extraction.Definitions.Select(static item => item.Payload)
        .OfType<ImportedOverloadOptionDefinitionPayload>()
        .ToArray();
    Assert.Equal(135, overload.Sum(static item => item.LegalValueAliases.Count));
    Assert.Equal(
        135,
        overload.SelectMany(static item => item.LegalValueAliases)
            .Select(static item => item.SourceValueAlias)
            .Distinct()
            .Count());
    Assert.All(overload, static item =>
    {
      Assert.True(item.IsResearchReady);
      Assert.True(item.IsGameLegalReady);
      Assert.Equal(CombatSupportFactStatus.Unresolved, item.DuplicatePolicy.Status);
      Assert.Equal(15, item.LegalBands.SelectMany(static band => band.OrderedValues).Count());
    });
    Assert.All(
        overload.Where(static item => item.OptionType.Value is
            CombatSupportOverloadOptionType.ChargeSpeed or CombatSupportOverloadOptionType.HitRate)
            .SelectMany(static item => item.LegalBands)
            .SelectMany(static item => item.OrderedValues),
        static value =>
        {
          Assert.True(value.SourceRawValue < 0);
          Assert.True(value.MagnitudeBasisPoints > 0);
          Assert.Equal(value.MagnitudeBasisPoints / 100m, value.UiPercent.ToDecimal());
          Assert.Equal(value.MagnitudeBasisPoints / 10_000m, value.EngineFraction.ToDecimal());
        });

    var canonical = ImportedCombatSupportCandidateCanonicalizer.ToCanonicalText(extraction.Definitions);
    Assert.DoesNotContain(
        SyntheticCombatSupportStaticData.SourceIdentityLeakSentinel.ToString(System.Globalization.CultureInfo.InvariantCulture),
        canonical,
        StringComparison.Ordinal);
    Assert.DoesNotContain("Table.mpk", canonical, StringComparison.Ordinal);
    Assert.Equal(
        extraction.CanonicalCandidateSha256,
        ImportedCombatSupportCandidateCanonicalizer.ComputeHash(extraction.Definitions.Reverse()));
  }

  [Fact]
  public void ProjectionUsesOwnUidsAndLeavesUnimportedSkillSemanticsIncomplete()
  {
    using var source = SyntheticCombatSupportStaticData.Create();
    var extraction = Read(source);
    var projection = CombatSupportCatalogProjector.Project(
        extraction,
        EntityUid.New(),
        new SyntheticIdentityResolver());

    Assert.Equal(46, projection.Manifest.Count);
    Assert.Equal(extraction.Definitions.Count, projection.Versions.Count);
    Assert.All(
        projection.Versions.Where(static item => item.Content.Kind == CombatSupportDefinitionKind.Equipment),
        static item => Assert.True(item.Content.HasCompleteCombatSemantics));
    Assert.All(
        projection.Versions.Where(static item => item.Content.Kind is
            CombatSupportDefinitionKind.HarmonyCube or
            CombatSupportDefinitionKind.GenericCollection or
            CombatSupportDefinitionKind.Favorite),
        static item =>
        {
          Assert.True(item.Content.IsProfileSelectable);
          Assert.False(item.Content.HasCompleteCombatSemantics);
        });
    Assert.All(
        projection.Versions.Where(static item => item.Content.Kind == CombatSupportDefinitionKind.OverloadOption),
        static item => Assert.False(item.Content.HasCompleteCombatSemantics));
    Assert.All(extraction.Definitions, candidate =>
        Assert.DoesNotContain(candidate.AliasFingerprint.Hex, projection.Manifest.CanonicalText, StringComparison.Ordinal));
  }

  [Theory]
  [InlineData(580)]
  [InlineData(680)]
  public void ConsoleMaximumLevelIsDerivedFromEachSourceContiguousCoordinate(int maximumLevel)
  {
    using var source = SyntheticCombatSupportStaticData.Create(consoleMaximumLevel: maximumLevel);
    var extraction = Read(source);
    var consoles = extraction.Definitions.Select(static item => item.Payload)
        .OfType<ImportedConsoleDefinitionPayload>()
        .ToArray();

    Assert.Equal(9, consoles.Length);
    Assert.All(consoles, item =>
    {
      Assert.Equal(maximumLevel, item.MaximumLevel.Value);
      Assert.Equal(maximumLevel, item.Levels.Count);
      Assert.Equal(Enumerable.Range(1, maximumLevel), item.Levels.Select(static level => level.Level));
    });
  }

  [Fact]
  public void ConsoleDefinitionsDoNotInventACrossNodeMaximumConstraint()
  {
    using var source = SyntheticCombatSupportStaticData.Create(
        consoleMaximumLevel: 680,
        firstConsoleMaximumLevel: 579);
    var extraction = Read(source);
    var maximumLevels = extraction.Definitions.Select(static item => item.Payload)
        .OfType<ImportedConsoleDefinitionPayload>()
        .Select(static item => item.MaximumLevel.RequireValue())
        .Order()
        .ToArray();

    Assert.Equal(579, maximumLevels[0]);
    Assert.All(maximumLevels[1..], static maximum => Assert.Equal(680, maximum));
  }

  [Fact]
  public void SkillGroupReassignmentChangesSnapshotProvenanceButNotLossyPhaseOneCandidate()
  {
    using var firstSource = SyntheticCombatSupportStaticData.Create(skillAssignmentVariant: 0);
    using var secondSource = SyntheticCombatSupportStaticData.Create(skillAssignmentVariant: 10);
    var secret = RandomNumberGenerator.GetBytes(32);
    try
    {
      var reader = new StaticDataCombatSupportCatalogReader();
      var first = reader.Read(firstSource, secret);
      var second = reader.Read(secondSource, secret);

      Assert.NotEqual(first.SourceArchiveSha256, second.SourceArchiveSha256);
      Assert.Equal(first.CanonicalCandidateSha256, second.CanonicalCandidateSha256);
      Assert.All(
          first.Definitions.Where(static item => item.Kind is
              CombatSupportDefinitionKind.HarmonyCube or
              CombatSupportDefinitionKind.GenericCollection or
              CombatSupportDefinitionKind.Favorite),
          static item => Assert.False(CombatSupportCatalogProjector.ToDomainContent(
              item.Payload,
              new SyntheticIdentityResolver()).HasCompleteCombatSemantics));
    }
    finally
    {
      CryptographicOperations.ZeroMemory(secret);
    }
  }

  [Theory]
  [InlineData(SyntheticCombatSupportFault.GradeCoreOrphan, "equipment_grade_fk_invalid")]
  [InlineData(SyntheticCombatSupportFault.GrowthRelationMismatch, "equipment_growth_relation_invalid")]
  [InlineData(SyntheticCombatSupportFault.OverloadSignMismatch, "overload_function_value_invalid")]
  public void BrokenSourceRelationsFailClosed(
      SyntheticCombatSupportFault fault,
      string expectedCode)
  {
    using var source = SyntheticCombatSupportStaticData.Create(fault);
    var exception = Assert.Throws<CombatSupportCatalogSourceException>(() => Read(source));

    Assert.Equal(expectedCode, exception.Code);
    Assert.DoesNotContain(
        SyntheticCombatSupportStaticData.SourceIdentityLeakSentinel.ToString(System.Globalization.CultureInfo.InvariantCulture),
        exception.Message,
        StringComparison.Ordinal);
    Assert.DoesNotContain("Table.mpk", exception.Message, StringComparison.Ordinal);
  }

  [Theory]
  [InlineData(SyntheticCombatSupportFault.UnknownCollectionWeapon, "collection_weapon_class_unknown")]
  [InlineData(SyntheticCombatSupportFault.UnknownCollectionStat, "combat_stat_unknown")]
  public void UnknownSourceFactsRemainExplicitAndEmitControlledDiagnostics(
      SyntheticCombatSupportFault fault,
      string expectedCode)
  {
    using var source = SyntheticCombatSupportStaticData.Create(fault);
    var extraction = Read(source);

    var diagnostic = Assert.Single(extraction.Diagnostics, item => item.Code == expectedCode);
    Assert.Equal(1, diagnostic.OccurrenceCount);
    var canonical = ImportedCombatSupportCandidateCanonicalizer.ToCanonicalText(extraction.Definitions);
    Assert.Contains($"unresolved:{expectedCode}", canonical, StringComparison.Ordinal);
  }

  [Fact]
  public void DuplicateArchiveEntryFailsBeforeDecode()
  {
    using var source = SyntheticCombatSupportStaticData.Create(mutateArchive: static archive =>
    {
      var duplicate = archive.CreateEntry("synthetic/CharacterTable.mpk", CompressionLevel.NoCompression);
      using var target = duplicate.Open();
      target.WriteByte(0);
    });

    var exception = Assert.Throws<CombatSupportCatalogSourceException>(() => Read(source));
    Assert.Equal("archive_entry_duplicate", exception.Code);
  }

  private static CombatSupportCatalogExtraction Read(Stream source)
  {
    var secret = RandomNumberGenerator.GetBytes(32);
    try
    {
      return new StaticDataCombatSupportCatalogReader().Read(source, secret);
    }
    finally
    {
      CryptographicOperations.ZeroMemory(secret);
    }
  }

  private sealed class SyntheticIdentityResolver : ICombatSupportCatalogIdentityResolver
  {
    private readonly Dictionary<(CombatSupportDefinitionKind Kind, SourceAliasFingerprint Alias), EntityUid>
        _definitionUids = [];
    private readonly Dictionary<SourceAliasFingerprint, EntityUid> _characterUids = [];

    public EntityUid ResolveDefinitionUid(
        CombatSupportDefinitionKind kind,
        SourceAliasFingerprint sourceAliasFingerprint)
    {
      if (!_definitionUids.TryGetValue((kind, sourceAliasFingerprint), out var uid))
      {
        uid = EntityUid.New();
        _definitionUids.Add((kind, sourceAliasFingerprint), uid);
      }

      return uid;
    }

    public EntityUid ResolveCharacterUid(SourceAliasFingerprint sourceAliasFingerprint)
    {
      if (!_characterUids.TryGetValue(sourceAliasFingerprint, out var uid))
      {
        uid = EntityUid.New();
        _characterUids.Add(sourceAliasFingerprint, uid);
      }

      return uid;
    }

    public EntityUid NewDefinitionVersionUid() => EntityUid.New();
  }
}
