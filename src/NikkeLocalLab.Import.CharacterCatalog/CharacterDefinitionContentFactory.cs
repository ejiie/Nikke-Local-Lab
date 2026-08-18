using NikkeLocalLab.Domain.Character;
using NikkeLocalLab.Identity;

namespace NikkeLocalLab.Import.CharacterCatalog;

public static class CharacterDefinitionContentFactory
{
  public static CharacterDefinitionContent Create(ImportedCharacterDefinitionCandidate candidate)
  {
    ArgumentNullException.ThrowIfNull(candidate);

    var profile = new CharacterProfile(
        MapCode(candidate.Rarity, ParseRarity),
        MapCode(candidate.CharacterClass, ParseRole),
        MapCode(candidate.Weapon, ParseWeapon),
        MapCode(candidate.Element, ParseElement),
        MapCode(candidate.Manufacturer, ParseManufacturer));
    var equipment = Enum.GetValues<EquipmentSlot>()
        .Select(slot => new EquipmentSlotCapability(
            slot,
            NormalizedFact<EntityUid>.Unresolved("equipment_definition_unselected"),
            MapInteger(candidate.MaximumEquipmentTier),
            MapInteger(candidate.MaximumEquipmentEnhancement),
            NormalizedFact<bool>.Unresolved("manufacturer_match_unselected")))
        .ToArray();
    var capabilities = new CharacterCapabilities(
        MapInteger(candidate.MaximumCharacterLevel),
        MapInteger(candidate.MaximumLimitBreak),
        MapInteger(candidate.MaximumCore),
        MapInteger(candidate.MaximumBond),
        equipment,
        new SkillMaximums(
            MapInteger(candidate.MaximumSkill1),
            MapInteger(candidate.MaximumSkill2),
            MapInteger(candidate.MaximumBurstSkill)),
        MapInteger(candidate.MaximumCubeLevel),
        MapInteger(candidate.MaximumCollectionLevel),
        MapInteger(candidate.MaximumFavoriteItemLevel));
    return new CharacterDefinitionContent(profile, capabilities);
  }

  private static NormalizedFact<int> MapInteger(ImportedIntegerFact fact) => fact.Status switch
  {
    ImportedFactStatus.Ready => NormalizedFact<int>.Ready(fact.Value!.Value),
    ImportedFactStatus.Unresolved => NormalizedFact<int>.Unresolved(fact.ReasonCode!),
    ImportedFactStatus.NotApplicable => NormalizedFact<int>.NotApplicable(),
    _ => throw new InvalidOperationException("The imported fact status is unsupported.")
  };

  private static NormalizedFact<T> MapCode<T>(ImportedCodeFact fact, Func<string, T> parser)
      where T : struct => fact.Status switch
      {
        ImportedFactStatus.Ready => NormalizedFact<T>.Ready(parser(fact.Value!)),
        ImportedFactStatus.Unresolved => NormalizedFact<T>.Unresolved(fact.ReasonCode!),
        ImportedFactStatus.NotApplicable => NormalizedFact<T>.NotApplicable(),
        _ => throw new InvalidOperationException("The imported fact status is unsupported.")
      };

  private static CharacterRarity ParseRarity(string value) => value switch
  {
    "r" => CharacterRarity.R,
    "sr" => CharacterRarity.SR,
    "ssr" => CharacterRarity.SSR,
    _ => throw new InvalidOperationException("The normalized rarity code is unsupported.")
  };

  private static CombatRole ParseRole(string value) => value switch
  {
    "attacker" => CombatRole.Attacker,
    "defender" => CombatRole.Defender,
    "supporter" => CombatRole.Supporter,
    _ => throw new InvalidOperationException("The normalized role code is unsupported.")
  };

  private static WeaponClass ParseWeapon(string value) => value switch
  {
    "ar" => WeaponClass.AssaultRifle,
    "smg" => WeaponClass.SubmachineGun,
    "sg" => WeaponClass.Shotgun,
    "sr" => WeaponClass.SniperRifle,
    "rl" => WeaponClass.RocketLauncher,
    "mg" => WeaponClass.MachineGun,
    _ => throw new InvalidOperationException("The normalized weapon code is unsupported.")
  };

  private static NikkeElement ParseElement(string value) => value switch
  {
    "fire" => NikkeElement.Fire,
    "water" => NikkeElement.Water,
    "wind" => NikkeElement.Wind,
    "electric" => NikkeElement.Electric,
    "iron" => NikkeElement.Iron,
    _ => throw new InvalidOperationException("The normalized element code is unsupported.")
  };

  private static Manufacturer ParseManufacturer(string value) => value switch
  {
    "elysion" => Manufacturer.Elysion,
    "missilis" => Manufacturer.Missilis,
    "tetra" => Manufacturer.Tetra,
    "pilgrim" => Manufacturer.Pilgrim,
    "abnormal" => Manufacturer.Abnormal,
    _ => throw new InvalidOperationException("The normalized manufacturer code is unsupported.")
  };
}
