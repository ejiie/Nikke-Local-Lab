using NikkeLocalLab.Domain.CombatSupport;
using NikkeLocalLab.Identity;

namespace NikkeLocalLab.Import.CombatSupportCatalog;

public interface ICombatSupportCatalogIdentityResolver
{
  EntityUid ResolveDefinitionUid(
      CombatSupportDefinitionKind kind,
      SourceAliasFingerprint sourceAliasFingerprint);

  EntityUid ResolveCharacterUid(SourceAliasFingerprint sourceAliasFingerprint);

  EntityUid NewDefinitionVersionUid();
}

public sealed record CombatSupportCatalogProjection(
    IReadOnlyList<CombatSupportDefinitionVersion> Versions,
    CombatSupportCatalogManifest Manifest);

public static class CombatSupportCatalogProjector
{
  public static CombatSupportCatalogProjection Project(
      CombatSupportCatalogExtraction extraction,
      EntityUid datasetSnapshotUid,
      ICombatSupportCatalogIdentityResolver identityResolver)
  {
    ArgumentNullException.ThrowIfNull(extraction);
    ArgumentNullException.ThrowIfNull(identityResolver);
    if (datasetSnapshotUid.Value == Guid.Empty)
    {
      throw new ArgumentException("A dataset snapshot UID cannot be empty.", nameof(datasetSnapshotUid));
    }

    var versions = extraction.Definitions.Select(candidate =>
    {
      var definitionUid = identityResolver.ResolveDefinitionUid(candidate.Kind, candidate.AliasFingerprint);
      var definition = new CombatSupportDefinition(definitionUid);
      return CombatSupportDefinitionVersion.Create(
          identityResolver.NewDefinitionVersionUid(),
          definition,
          datasetSnapshotUid,
          ToDomainContent(candidate.Payload, identityResolver));
    }).ToArray();
    var readOnlyVersions = Array.AsReadOnly(versions);
    return new CombatSupportCatalogProjection(
        readOnlyVersions,
        CombatSupportCatalogManifest.Create(readOnlyVersions));
  }

  public static ICombatSupportDefinitionContent ToDomainContent(
      IImportedCombatSupportDefinitionPayload payload,
      ICombatSupportCatalogIdentityResolver identityResolver)
  {
    ArgumentNullException.ThrowIfNull(payload);
    ArgumentNullException.ThrowIfNull(identityResolver);
    return payload switch
    {
      ImportedEquipmentDefinitionPayload equipment => new EquipmentDefinitionContent(
          equipment.Slot,
          equipment.CombatRole,
          equipment.Manufacturer,
          equipment.Tier,
          equipment.EnhancementGrade,
          equipment.MaximumEnhancementLevel,
          equipment.OverloadEligible,
          equipment.BaseStats,
          equipment.OptionSlots),
      ImportedHarmonyCubeDefinitionPayload cube => new HarmonyCubeDefinitionContent(
          cube.Rarity,
          cube.ApplicableCombatRole,
          cube.MaximumLevel,
          cube.Levels,
          cube.SkillSemantics),
      ImportedGenericCollectionDefinitionPayload collection => new GenericCollectionDefinitionContent(
          collection.ApplicableWeaponClass,
          collection.Rarity,
          collection.MaximumLevel,
          collection.Levels,
          collection.SkillSemantics),
      ImportedFavoriteDefinitionPayload favorite => new FavoriteDefinitionContent(
          ResolveCharacter(favorite.ApplicableCharacterAlias, identityResolver),
          favorite.Rarity,
          favorite.MaximumLevel,
          favorite.Levels,
          favorite.SkillSemantics),
      ImportedConsoleDefinitionPayload console => new ConsoleDefinitionContent(
          console.Coordinate,
          console.MaximumLevel,
          console.Levels,
          console.PerLevelContributions),
      ImportedOverloadOptionDefinitionPayload overload => new OverloadOptionDefinitionContent(
          overload.OptionType,
          overload.Unit,
          overload.KindSelectionProbability,
          overload.LegalBands,
          overload.DuplicatePolicy),
      _ => throw new ArgumentException("The imported combat-support payload type is unsupported.", nameof(payload))
    };
  }

  private static CombatSupportFact<EntityUid> ResolveCharacter(
      CombatSupportFact<SourceAliasFingerprint> sourceFact,
      ICombatSupportCatalogIdentityResolver identityResolver) => sourceFact.Status switch
      {
        CombatSupportFactStatus.Ready => CombatSupportFact<EntityUid>.Ready(
            identityResolver.ResolveCharacterUid(sourceFact.RequireValue())),
        CombatSupportFactStatus.Unresolved => CombatSupportFact<EntityUid>.Unresolved(sourceFact.ReasonCode!),
        CombatSupportFactStatus.NotApplicable => CombatSupportFact<EntityUid>.NotApplicable(),
        _ => throw new ArgumentOutOfRangeException(nameof(sourceFact))
      };
}
