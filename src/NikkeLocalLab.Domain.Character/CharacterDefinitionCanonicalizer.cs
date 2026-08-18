using System.Globalization;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Domain.Character;

public static class CharacterDefinitionCanonicalizer
{
  public const string ContractId = "nll/character-definition-content/v1";

  public static string ToCanonicalText(CharacterDefinitionContent content)
  {
    ArgumentNullException.ThrowIfNull(content);
    var profile = content.Profile;
    var capabilities = content.Capabilities;

    var lines = new List<string>(32)
    {
      ContractId,
      $"profile.rarity={Format(profile.Rarity, RarityCode)}",
      $"profile.combat-role={Format(profile.CombatRole, CombatRoleCode)}",
      $"profile.weapon-class={Format(profile.WeaponClass, WeaponClassCode)}",
      $"profile.element={Format(profile.Element, ElementCode)}",
      $"profile.manufacturer={Format(profile.Manufacturer, ManufacturerCode)}",
      $"capability.maximum-character-level={Format(capabilities.MaximumCharacterLevel, IntegerCode)}",
      $"capability.maximum-limit-break={Format(capabilities.MaximumLimitBreak, IntegerCode)}",
      $"capability.maximum-core-level={Format(capabilities.MaximumCoreLevel, IntegerCode)}",
      $"capability.maximum-bond-level={Format(capabilities.MaximumBondLevel, IntegerCode)}",
    };

    foreach (var equipment in capabilities.Equipment)
    {
      var prefix = $"capability.equipment.{EquipmentSlotCode(equipment.Slot)}";
      lines.Add($"{prefix}.definition-uid={Format(equipment.EquipmentDefinitionUid, UidCode)}");
      lines.Add($"{prefix}.maximum-tier={Format(equipment.MaximumTier, IntegerCode)}");
      lines.Add(
          $"{prefix}.maximum-tier-ten-enhancement-level={Format(equipment.MaximumTierTenEnhancementLevel, IntegerCode)}");
      lines.Add($"{prefix}.manufacturer-match={Format(equipment.ManufacturerMatch, BooleanCode)}");
    }

    lines.Add($"capability.skill-1.maximum-level={Format(capabilities.SkillMaximums.Skill1, IntegerCode)}");
    lines.Add($"capability.skill-2.maximum-level={Format(capabilities.SkillMaximums.Skill2, IntegerCode)}");
    lines.Add($"capability.burst.maximum-level={Format(capabilities.SkillMaximums.Burst, IntegerCode)}");
    lines.Add($"capability.cube.maximum-level={Format(capabilities.MaximumCubeLevel, IntegerCode)}");
    lines.Add($"capability.collection.maximum-level={Format(capabilities.MaximumCollectionLevel, IntegerCode)}");
    lines.Add($"capability.favorite.maximum-level={Format(capabilities.MaximumFavoriteLevel, IntegerCode)}");

    return string.Join('\n', lines);
  }

  public static Sha256Digest ComputeContentHash(CharacterDefinitionContent content) =>
      Sha256Digest.ComputeUtf8(ToCanonicalText(content));

  private static string Format<T>(NormalizedFact<T> fact, Func<T, string> valueCode)
      where T : struct
  {
    return fact.Status switch
    {
      FactStatus.Ready => $"ready:{valueCode(fact.RequireValue())}",
      FactStatus.Unresolved => $"unresolved:{fact.ReasonCode}",
      FactStatus.NotApplicable => "not_applicable",
      _ => throw new InvalidOperationException("The normalized fact status is not supported."),
    };
  }

  private static string RarityCode(CharacterRarity value) => value switch
  {
    CharacterRarity.R => "r",
    CharacterRarity.SR => "sr",
    CharacterRarity.SSR => "ssr",
    _ => throw new ArgumentOutOfRangeException(nameof(value)),
  };

  private static string CombatRoleCode(CombatRole value) => value switch
  {
    CombatRole.Attacker => "attacker",
    CombatRole.Defender => "defender",
    CombatRole.Supporter => "supporter",
    _ => throw new ArgumentOutOfRangeException(nameof(value)),
  };

  private static string WeaponClassCode(WeaponClass value) => value switch
  {
    WeaponClass.AssaultRifle => "assault-rifle",
    WeaponClass.SubmachineGun => "submachine-gun",
    WeaponClass.Shotgun => "shotgun",
    WeaponClass.SniperRifle => "sniper-rifle",
    WeaponClass.RocketLauncher => "rocket-launcher",
    WeaponClass.MachineGun => "machine-gun",
    _ => throw new ArgumentOutOfRangeException(nameof(value)),
  };

  private static string ElementCode(NikkeElement value) => value switch
  {
    NikkeElement.Fire => "fire",
    NikkeElement.Water => "water",
    NikkeElement.Wind => "wind",
    NikkeElement.Electric => "electric",
    NikkeElement.Iron => "iron",
    _ => throw new ArgumentOutOfRangeException(nameof(value)),
  };

  private static string ManufacturerCode(Manufacturer value) => value switch
  {
    Manufacturer.Elysion => "elysion",
    Manufacturer.Missilis => "missilis",
    Manufacturer.Tetra => "tetra",
    Manufacturer.Pilgrim => "pilgrim",
    Manufacturer.Abnormal => "abnormal",
    _ => throw new ArgumentOutOfRangeException(nameof(value)),
  };

  private static string EquipmentSlotCode(EquipmentSlot value) => value switch
  {
    EquipmentSlot.Head => "head",
    EquipmentSlot.Torso => "torso",
    EquipmentSlot.Arms => "arms",
    EquipmentSlot.Legs => "legs",
    _ => throw new ArgumentOutOfRangeException(nameof(value)),
  };

  private static string IntegerCode(int value) => value.ToString(CultureInfo.InvariantCulture);

  private static string BooleanCode(bool value) => value ? "true" : "false";

  private static string UidCode(EntityUid value) => value.ToString();
}
