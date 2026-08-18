namespace NikkeLocalLab.Domain.Character;

public enum CharacterRarity
{
  R,
  SR,
  SSR,
}

public enum CombatRole
{
  Attacker,
  Defender,
  Supporter,
}

public enum WeaponClass
{
  AssaultRifle,
  SubmachineGun,
  Shotgun,
  SniperRifle,
  RocketLauncher,
  MachineGun,
}

public enum NikkeElement
{
  Fire,
  Water,
  Wind,
  Electric,
  Iron,
}

public enum Manufacturer
{
  Elysion,
  Missilis,
  Tetra,
  Pilgrim,
  Abnormal,
}

public sealed class CharacterProfile
{
  public CharacterProfile(
      NormalizedFact<CharacterRarity> rarity,
      NormalizedFact<CombatRole> combatRole,
      NormalizedFact<WeaponClass> weaponClass,
      NormalizedFact<NikkeElement> element,
      NormalizedFact<Manufacturer> manufacturer)
  {
    Rarity = RequireApplicable(rarity, nameof(rarity));
    CombatRole = RequireApplicable(combatRole, nameof(combatRole));
    WeaponClass = RequireApplicable(weaponClass, nameof(weaponClass));
    Element = RequireApplicable(element, nameof(element));
    Manufacturer = RequireApplicable(manufacturer, nameof(manufacturer));
  }

  public NormalizedFact<CharacterRarity> Rarity { get; }

  public NormalizedFact<CombatRole> CombatRole { get; }

  public NormalizedFact<WeaponClass> WeaponClass { get; }

  public NormalizedFact<NikkeElement> Element { get; }

  public NormalizedFact<Manufacturer> Manufacturer { get; }

  internal IEnumerable<(string Name, FactStatus Status, string? ReasonCode)> EnumerateReadiness()
  {
    yield return ("rarity", Rarity.Status, Rarity.ReasonCode);
    yield return ("combat_role", CombatRole.Status, CombatRole.ReasonCode);
    yield return ("weapon_class", WeaponClass.Status, WeaponClass.ReasonCode);
    yield return ("element", Element.Status, Element.ReasonCode);
    yield return ("manufacturer", Manufacturer.Status, Manufacturer.ReasonCode);
  }

  private static NormalizedFact<T> RequireApplicable<T>(NormalizedFact<T> fact, string parameterName)
      where T : struct
  {
    ArgumentNullException.ThrowIfNull(fact, parameterName);
    if (fact.Status == FactStatus.NotApplicable)
    {
      throw new ArgumentException("A character profile field cannot be not_applicable.", parameterName);
    }

    return fact;
  }
}
