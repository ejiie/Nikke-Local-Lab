using System.Buffers.Binary;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Import.Profile;

internal static class SanitizedProfileCanonicalizer
{
  public static Sha256Digest Compute(
      ProfileImportCatalogBinding characterCatalog,
      ProfileImportCatalogBinding combatSupportCatalog,
      SanitizedAccountCombatStateDraft accountState,
      IReadOnlyList<SanitizedCharacterBuildDraft> builds,
      IReadOnlyList<SanitizedProfileReviewedOverride> reviewedOverrides,
      Sha256Digest sourceSchemaSha256,
      Sha256Digest transformerFingerprintSha256,
      Sha256Digest transformerBinarySha256,
      Sha256Digest semanticOptionsSha256)
  {
    using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
    Append(hash, SanitizedProfileDraftContract.SchemaCode);
    Append(hash, sourceSchemaSha256.Hex);
    Append(hash, transformerFingerprintSha256.Hex);
    Append(hash, transformerBinarySha256.Hex);
    Append(hash, semanticOptionsSha256.Hex);
    AppendBinding(hash, characterCatalog);
    AppendBinding(hash, combatSupportCatalog);
    Append(hash, "capture-time=unresolved");
    Append(hash, "capture-atomicity=unresolved");
    Append(hash, "credential-bearing-source-hash=prohibited");
    Append(hash, accountState.SynchroLevel.ToString(CultureInfo.InvariantCulture));
    Append(
        hash,
        accountState.OccupiedSynchroSlotCountObservation.ToString(CultureInfo.InvariantCulture));
    Append(hash, accountState.Consoles.Count.ToString(CultureInfo.InvariantCulture));
    foreach (var console in accountState.Consoles)
    {
      Append(hash, Code(console.Coordinate));
      Append(hash, console.DefinitionUid.ToString());
      Append(hash, console.Level.ToString(CultureInfo.InvariantCulture));
      Append(hash, console.ObservedExperience.ToString(CultureInfo.InvariantCulture));
    }

    Append(hash, builds.Count.ToString(CultureInfo.InvariantCulture));
    foreach (var build in builds)
    {
      Append(hash, build.CharacterUid.ToString());
      Append(hash, build.Level.RosterLevel.ToString(CultureInfo.InvariantCulture));
      Append(hash, build.Level.DetailLevel.ToString(CultureInfo.InvariantCulture));
      AppendFact(hash, build.Level.ResolvedBattleLevel);
      Append(hash, build.Level.AuthorityPolicyCode);
      Append(hash, build.LimitBreak.ToString(CultureInfo.InvariantCulture));
      Append(hash, build.CoreLevel.ToString(CultureInfo.InvariantCulture));
      Append(hash, build.BondLevelObservation.ToString(CultureInfo.InvariantCulture));
      AppendFact(hash, build.ResolvedBondLevel);
      Append(hash, build.Skill1Level.ToString(CultureInfo.InvariantCulture));
      Append(hash, build.Skill2Level.ToString(CultureInfo.InvariantCulture));
      Append(hash, build.BurstLevel.ToString(CultureInfo.InvariantCulture));
      Append(hash, build.RosterCombatPowerObservation.ToString(CultureInfo.InvariantCulture));
      Append(hash, build.DetailCombatPowerObservation.ToString(CultureInfo.InvariantCulture));
      foreach (var equipment in build.Equipment)
      {
        Append(hash, Code(equipment.Slot));
        Append(hash, Code(equipment.State));
        Append(hash, equipment.DefinitionUid?.ToString());
        Append(hash, equipment.EnhancementLevel?.ToString(CultureInfo.InvariantCulture));
        if (equipment.ManufacturerMatchedObservation is null)
        {
          Append(hash, null);
        }
        else
        {
          AppendFact(hash, equipment.ManufacturerMatchedObservation);
        }
        if (equipment.ResolvedManufacturerMatched is null)
        {
          Append(hash, null);
        }
        else
        {
          AppendFact(hash, equipment.ResolvedManufacturerMatched);
        }
        Append(hash, equipment.OverloadLines.Count.ToString(CultureInfo.InvariantCulture));
        foreach (var line in equipment.OverloadLines)
        {
          Append(hash, line.LineIndex.ToString(CultureInfo.InvariantCulture));
          Append(hash, line.OptionDefinitionUid.ToString());
          Append(hash, Code(line.Unit));
          Append(hash, line.ExactValue.UnscaledValue.ToString(CultureInfo.InvariantCulture));
          Append(hash, line.ExactValue.DecimalScale.ToString(CultureInfo.InvariantCulture));
        }
      }

      Append(hash, Code(build.Cube.State));
      Append(hash, build.Cube.DefinitionUid?.ToString());
      Append(hash, build.Cube.Level?.ToString(CultureInfo.InvariantCulture));
      Append(hash, Code(build.Collection.Kind));
      Append(hash, build.Collection.DefinitionUid?.ToString());
      Append(hash, build.Collection.Level?.ToString(CultureInfo.InvariantCulture));
    }

    Append(hash, reviewedOverrides.Count.ToString(CultureInfo.InvariantCulture));
    foreach (var reviewedOverride in reviewedOverrides)
    {
      Append(hash, Code(reviewedOverride.Kind));
      Append(hash, reviewedOverride.CharacterUid.ToString());
      Append(hash, reviewedOverride.EquipmentSlot.HasValue
          ? Code(reviewedOverride.EquipmentSlot.Value)
          : null);
      Append(hash, reviewedOverride.IntegerValue?.ToString(CultureInfo.InvariantCulture));
      Append(hash, reviewedOverride.BooleanValue.HasValue
          ? (reviewedOverride.BooleanValue.Value ? "true" : "false")
          : null);
      Append(hash, reviewedOverride.OriginalReasonCode);
      Append(hash, reviewedOverride.ReasonCode);
    }

    return Sha256Digest.FromBytes(hash.GetHashAndReset());
  }

  private static void AppendBinding(IncrementalHash hash, ProfileImportCatalogBinding binding)
  {
    Append(hash, binding.CatalogSnapshotUid.ToString());
    Append(hash, binding.DatasetSnapshotUid.ToString());
    Append(hash, binding.ManifestSha256.Hex);
  }

  private static void AppendFact(IncrementalHash hash, ProfileImportFact<int> fact)
  {
    Append(hash, fact.Status == ProfileImportFactStatus.Ready ? "ready" : "unresolved");
    Append(hash, fact.Value?.ToString(CultureInfo.InvariantCulture));
    Append(hash, fact.ReasonCode);
  }

  private static void AppendFact(IncrementalHash hash, ProfileImportFact<bool> fact)
  {
    Append(hash, fact.Status == ProfileImportFactStatus.Ready ? "ready" : "unresolved");
    Append(hash, fact.Value.HasValue ? (fact.Value.Value ? "true" : "false") : null);
    Append(hash, fact.ReasonCode);
  }

  private static string Code(ProfileImportEquipmentSlot value) => value switch
  {
    ProfileImportEquipmentSlot.Head => "head",
    ProfileImportEquipmentSlot.Torso => "torso",
    ProfileImportEquipmentSlot.Arms => "arms",
    ProfileImportEquipmentSlot.Legs => "legs",
    _ => throw new ArgumentOutOfRangeException(nameof(value))
  };

  private static string Code(ProfileImportAttachmentState value) => value switch
  {
    ProfileImportAttachmentState.Equipped => "equipped",
    ProfileImportAttachmentState.Unequipped => "unequipped",
    _ => throw new ArgumentOutOfRangeException(nameof(value))
  };

  private static string Code(ProfileImportCollectionKind value) => value switch
  {
    ProfileImportCollectionKind.Detached => "detached",
    ProfileImportCollectionKind.GenericCollection => "generic_collection",
    ProfileImportCollectionKind.Favorite => "favorite",
    _ => throw new ArgumentOutOfRangeException(nameof(value))
  };

  private static string Code(ProfileImportConsoleCoordinate value) => value switch
  {
    ProfileImportConsoleCoordinate.Common => "common",
    ProfileImportConsoleCoordinate.Attacker => "attacker",
    ProfileImportConsoleCoordinate.Defender => "defender",
    ProfileImportConsoleCoordinate.Supporter => "supporter",
    ProfileImportConsoleCoordinate.Elysion => "elysion",
    ProfileImportConsoleCoordinate.Missilis => "missilis",
    ProfileImportConsoleCoordinate.Tetra => "tetra",
    ProfileImportConsoleCoordinate.Pilgrim => "pilgrim",
    ProfileImportConsoleCoordinate.Abnormal => "abnormal",
    _ => throw new ArgumentOutOfRangeException(nameof(value))
  };

  private static string Code(ProfileImportValueUnit value) => value switch
  {
    ProfileImportValueUnit.Absolute => "absolute",
    ProfileImportValueUnit.Ratio => "ratio",
    ProfileImportValueUnit.Percent => "percent",
    ProfileImportValueUnit.Count => "count",
    _ => throw new ArgumentOutOfRangeException(nameof(value))
  };

  private static string Code(SanitizedProfileReviewedOverrideKind value) => value switch
  {
    SanitizedProfileReviewedOverrideKind.BondLevel => "bond_level",
    SanitizedProfileReviewedOverrideKind.EquipmentManufacturerMatched =>
        "equipment_manufacturer_matched",
    _ => throw new ArgumentOutOfRangeException(nameof(value))
  };

  private static void Append(IncrementalHash hash, string? value)
  {
    Span<byte> length = stackalloc byte[sizeof(int)];
    if (value is null)
    {
      BinaryPrimitives.WriteInt32BigEndian(length, -1);
      hash.AppendData(length);
      return;
    }

    var bytes = Encoding.UTF8.GetBytes(value);
    BinaryPrimitives.WriteInt32BigEndian(length, bytes.Length);
    hash.AppendData(length);
    hash.AppendData(bytes);
  }
}
