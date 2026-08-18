using System.Globalization;
using System.Text;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Domain.CombatSupport;

public static class CombatSupportDefinitionCanonicalizer
{
  public const string ContractId = "nll/combat-support-definition-content/v1";

  public static string ToCanonicalText(ICombatSupportDefinitionContent content)
  {
    ArgumentNullException.ThrowIfNull(content);
    var lines = new List<string>
    {
      ContractId,
      $"kind={CombatSupportCanonicalCodes.DefinitionKind(content.Kind)}"
    };

    switch (content)
    {
      case EquipmentDefinitionContent equipment:
        lines.Add($"equipment.slot={CombatSupportCanonicalCodes.EquipmentSlot(equipment.Slot)}");
        lines.Add($"equipment.combat-role={Fact(equipment.CombatRole, CombatSupportCanonicalCodes.CombatRole)}");
        lines.Add($"equipment.manufacturer={Fact(equipment.Manufacturer, CombatSupportCanonicalCodes.Manufacturer)}");
        lines.Add($"equipment.tier={Fact(equipment.Tier, Integer)}");
        lines.Add($"equipment.enhancement-grade={Fact(equipment.EnhancementGrade, Integer)}");
        lines.Add($"equipment.maximum-enhancement-level={Fact(equipment.MaximumEnhancementLevel, Integer)}");
        lines.Add($"equipment.overload-eligible={Fact(equipment.OverloadEligible, Boolean)}");
        AppendContributions(lines, "equipment.base-stats", equipment.BaseStats);
        lines.Add($"equipment.option-slots.count={Integer(equipment.OptionSlots.Count)}");
        foreach (var slot in equipment.OptionSlots)
        {
          lines.Add(
              $"equipment.option-slots.{Integer(slot.Ordinal)}.activation-probability={Exact(slot.ActivationProbability)}");
        }

        break;
      case HarmonyCubeDefinitionContent cube:
        lines.Add($"cube.rarity={Fact(cube.Rarity, CombatSupportCanonicalCodes.Rarity)}");
        lines.Add(
            $"cube.applicable-combat-role={Fact(cube.ApplicableCombatRole, CombatSupportCanonicalCodes.CombatRole)}");
        lines.Add($"cube.maximum-level={Fact(cube.MaximumLevel, Integer)}");
        lines.Add($"cube.skill-semantics={Fact(cube.SkillSemantics, Boolean)}");
        AppendLevels(lines, cube.Levels);
        break;
      case GenericCollectionDefinitionContent collection:
        lines.Add(
            $"collection.applicable-weapon-class={Fact(collection.ApplicableWeaponClass, CombatSupportCanonicalCodes.WeaponClass)}");
        lines.Add($"collection.rarity={Fact(collection.Rarity, CombatSupportCanonicalCodes.Rarity)}");
        lines.Add($"collection.maximum-level={Fact(collection.MaximumLevel, Integer)}");
        lines.Add($"collection.skill-semantics={Fact(collection.SkillSemantics, Boolean)}");
        AppendLevels(lines, collection.Levels);
        break;
      case FavoriteDefinitionContent favorite:
        lines.Add($"favorite.applicable-character-uid={Fact(favorite.ApplicableCharacterUid, Uid)}");
        lines.Add($"favorite.rarity={Fact(favorite.Rarity, CombatSupportCanonicalCodes.Rarity)}");
        lines.Add($"favorite.maximum-level={Fact(favorite.MaximumLevel, Integer)}");
        lines.Add($"favorite.skill-semantics={Fact(favorite.SkillSemantics, Boolean)}");
        AppendLevels(lines, favorite.Levels);
        break;
      case ConsoleDefinitionContent console:
        lines.Add($"console.coordinate={CombatSupportCanonicalCodes.ConsoleCoordinate(console.Coordinate)}");
        lines.Add($"console.maximum-level={Fact(console.MaximumLevel, Integer)}");
        AppendContributions(lines, "console.per-level", console.PerLevelContributions);
        AppendLevels(lines, console.Levels);
        break;
      case OverloadOptionDefinitionContent overload:
        lines.Add($"overload.option-type={Fact(overload.OptionType, CombatSupportCanonicalCodes.OverloadOptionType)}");
        lines.Add($"overload.unit={Fact(overload.Unit, CombatSupportCanonicalCodes.ValueUnit)}");
        lines.Add($"overload.kind-selection-probability={Exact(overload.KindSelectionProbability)}");
        lines.Add($"overload.legal-bands.count={Integer(overload.LegalBands.Count)}");
        foreach (var band in overload.LegalBands)
        {
          var prefix = $"overload.legal-bands.{Integer(band.Ordinal)}";
          lines.Add($"{prefix}.probability={Exact(band.Probability)}");
          lines.Add($"{prefix}.values.count={Integer(band.OrderedValues.Count)}");
          for (var valueOrdinal = 0; valueOrdinal < band.OrderedValues.Count; valueOrdinal++)
          {
            var legalValue = band.OrderedValues[valueOrdinal];
            lines.Add($"{prefix}.values.{Integer(valueOrdinal)}.roll-level={Integer(legalValue.RollLevel)}");
            lines.Add(
                $"{prefix}.values.{Integer(valueOrdinal)}.source-raw={legalValue.SourceRawValue.ToString(CultureInfo.InvariantCulture)}");
            lines.Add(
                $"{prefix}.values.{Integer(valueOrdinal)}.magnitude-bp={Integer(legalValue.MagnitudeBasisPoints)}");
            lines.Add(
                $"{prefix}.values.{Integer(valueOrdinal)}.engine-fraction={Exact(legalValue.EngineFraction)}");
          }
        }

        lines.Add(
            $"overload.duplicate-policy={Fact(overload.DuplicatePolicy, CombatSupportCanonicalCodes.OverloadDuplicatePolicy)}");
        break;
      default:
        throw new ArgumentException("The combat-support definition content type is not supported.", nameof(content));
    }

    lines.Add($"readiness.profile-selectable={Boolean(content.IsProfileSelectable)}");
    lines.Add($"readiness.complete-combat-semantics={Boolean(content.HasCompleteCombatSemantics)}");
    return string.Join('\n', lines);
  }

  public static Sha256Digest ComputeContentHash(ICombatSupportDefinitionContent content) =>
      Sha256Digest.ComputeUtf8(ToCanonicalText(content));

  private static void AppendLevels(
      ICollection<string> lines,
      IReadOnlyList<CombatSupportLevelCoordinate> levels)
  {
    lines.Add($"levels.count={Integer(levels.Count)}");
    for (var index = 0; index < levels.Count; index++)
    {
      var level = levels[index];
      var prefix = $"levels.{Integer(index)}";
      lines.Add($"{prefix}.level={Integer(level.Level)}");
      lines.Add($"{prefix}.grade={Fact(level.Grade, Integer)}");
      lines.Add($"{prefix}.capacity={Fact(level.Capacity, Integer)}");
      lines.Add($"{prefix}.minimum-synchro-level={Fact(level.MinimumSynchroLevel, Integer)}");
      lines.Add($"{prefix}.skill-levels.count={Integer(level.SkillLevels.Count)}");
      for (var skillOrdinal = 0; skillOrdinal < level.SkillLevels.Count; skillOrdinal++)
      {
        lines.Add(
            $"{prefix}.skill-levels.{Integer(skillOrdinal)}={Integer(level.SkillLevels[skillOrdinal])}");
      }

      AppendContributions(lines, prefix, level.Contributions);
    }
  }

  private static void AppendContributions(
      ICollection<string> lines,
      string prefix,
      IReadOnlyList<CombatSupportStatContribution> contributions)
  {
    lines.Add($"{prefix}.contributions.count={Integer(contributions.Count)}");
    foreach (var contribution in contributions)
    {
      var contributionPrefix = $"{prefix}.contributions.{Integer(contribution.Ordinal)}";
      lines.Add($"{contributionPrefix}.stat={Fact(contribution.Stat, CombatSupportCanonicalCodes.Stat)}");
      lines.Add($"{contributionPrefix}.unit={Fact(contribution.Unit, CombatSupportCanonicalCodes.ValueUnit)}");
      lines.Add($"{contributionPrefix}.value={Exact(contribution.Value)}");
    }
  }

  private static string Fact<T>(CombatSupportFact<T> fact, Func<T, string> formatter)
      where T : struct => fact.Status switch
      {
        CombatSupportFactStatus.Ready => $"ready:{formatter(fact.RequireValue())}",
        CombatSupportFactStatus.Unresolved => $"unresolved:{fact.ReasonCode}",
        CombatSupportFactStatus.NotApplicable => "not_applicable",
        _ => throw new ArgumentOutOfRangeException(nameof(fact))
      };

  private static string Exact(CombatSupportExactValue value) =>
      $"{value.UnscaledValue.ToString(CultureInfo.InvariantCulture)}e-{value.DecimalScale.ToString(CultureInfo.InvariantCulture)}";

  private static string Integer(int value) => value.ToString(CultureInfo.InvariantCulture);

  private static string Boolean(bool value) => value ? "true" : "false";

  private static string Uid(EntityUid value) => value.ToString();
}

public static class CombatSupportCanonicalCodes
{
  public static string DefinitionKind(CombatSupportDefinitionKind value) => value switch
  {
    CombatSupportDefinitionKind.Equipment => "equipment",
    CombatSupportDefinitionKind.HarmonyCube => "harmony-cube",
    CombatSupportDefinitionKind.GenericCollection => "generic-collection",
    CombatSupportDefinitionKind.Favorite => "favorite",
    CombatSupportDefinitionKind.Console => "console",
    CombatSupportDefinitionKind.OverloadOption => "overload-option",
    _ => throw new ArgumentOutOfRangeException(nameof(value))
  };

  public static string EquipmentSlot(CombatSupportEquipmentSlot value) => value switch
  {
    CombatSupportEquipmentSlot.Head => "head",
    CombatSupportEquipmentSlot.Torso => "torso",
    CombatSupportEquipmentSlot.Arms => "arms",
    CombatSupportEquipmentSlot.Legs => "legs",
    _ => throw new ArgumentOutOfRangeException(nameof(value))
  };

  public static string CombatRole(CombatSupportCombatRole value) => value switch
  {
    CombatSupportCombatRole.Attacker => "attacker",
    CombatSupportCombatRole.Defender => "defender",
    CombatSupportCombatRole.Supporter => "supporter",
    _ => throw new ArgumentOutOfRangeException(nameof(value))
  };

  public static string Manufacturer(CombatSupportManufacturer value) => value switch
  {
    CombatSupportManufacturer.Elysion => "elysion",
    CombatSupportManufacturer.Missilis => "missilis",
    CombatSupportManufacturer.Tetra => "tetra",
    CombatSupportManufacturer.Pilgrim => "pilgrim",
    CombatSupportManufacturer.Abnormal => "abnormal",
    _ => throw new ArgumentOutOfRangeException(nameof(value))
  };

  public static string Rarity(CombatSupportRarity value) => value switch
  {
    CombatSupportRarity.R => "r",
    CombatSupportRarity.Sr => "sr",
    CombatSupportRarity.Ssr => "ssr",
    _ => throw new ArgumentOutOfRangeException(nameof(value))
  };

  public static string WeaponClass(CombatSupportWeaponClass value) => value switch
  {
    CombatSupportWeaponClass.AssaultRifle => "assault-rifle",
    CombatSupportWeaponClass.RocketLauncher => "rocket-launcher",
    CombatSupportWeaponClass.SniperRifle => "sniper-rifle",
    CombatSupportWeaponClass.MachineGun => "machine-gun",
    CombatSupportWeaponClass.Shotgun => "shotgun",
    CombatSupportWeaponClass.SubmachineGun => "submachine-gun",
    _ => throw new ArgumentOutOfRangeException(nameof(value))
  };

  public static string ConsoleCoordinate(CombatSupportConsoleCoordinate value) => value switch
  {
    CombatSupportConsoleCoordinate.Common => "common",
    CombatSupportConsoleCoordinate.Attacker => "attacker",
    CombatSupportConsoleCoordinate.Defender => "defender",
    CombatSupportConsoleCoordinate.Supporter => "supporter",
    CombatSupportConsoleCoordinate.Elysion => "elysion",
    CombatSupportConsoleCoordinate.Missilis => "missilis",
    CombatSupportConsoleCoordinate.Tetra => "tetra",
    CombatSupportConsoleCoordinate.Pilgrim => "pilgrim",
    CombatSupportConsoleCoordinate.Abnormal => "abnormal",
    _ => throw new ArgumentOutOfRangeException(nameof(value))
  };

  public static string Stat(CombatSupportStat value) => value switch
  {
    CombatSupportStat.Attack => "attack",
    CombatSupportStat.Defence => "defence",
    CombatSupportStat.Hp => "hp",
    CombatSupportStat.EnergyResistance => "energy-resistance",
    CombatSupportStat.MetalResistance => "metal-resistance",
    CombatSupportStat.BioResistance => "bio-resistance",
    _ => throw new ArgumentOutOfRangeException(nameof(value))
  };

  public static string ValueUnit(CombatSupportValueUnit value) => value switch
  {
    CombatSupportValueUnit.Absolute => "absolute",
    CombatSupportValueUnit.Ratio => "ratio",
    CombatSupportValueUnit.Percent => "percent",
    CombatSupportValueUnit.Count => "count",
    _ => throw new ArgumentOutOfRangeException(nameof(value))
  };

  public static string OverloadOptionType(CombatSupportOverloadOptionType value) => value switch
  {
    CombatSupportOverloadOptionType.Attack => "attack",
    CombatSupportOverloadOptionType.Defence => "defence",
    CombatSupportOverloadOptionType.MaximumAmmunition => "maximum-ammunition",
    CombatSupportOverloadOptionType.CriticalRate => "critical-rate",
    CombatSupportOverloadOptionType.CriticalDamage => "critical-damage",
    CombatSupportOverloadOptionType.ChargeDamage => "charge-damage",
    CombatSupportOverloadOptionType.ChargeSpeed => "charge-speed",
    CombatSupportOverloadOptionType.ElementalDamage => "elemental-damage",
    CombatSupportOverloadOptionType.HitRate => "hit-rate",
    _ => throw new ArgumentOutOfRangeException(nameof(value))
  };

  public static string OverloadDuplicatePolicy(CombatSupportOverloadDuplicatePolicy value) => value switch
  {
    CombatSupportOverloadDuplicatePolicy.AllowSameTypeOnOneEquipment => "allow-same-type-on-one-equipment",
    CombatSupportOverloadDuplicatePolicy.ForbidSameTypeOnOneEquipment => "forbid-same-type-on-one-equipment",
    _ => throw new ArgumentOutOfRangeException(nameof(value))
  };
}
