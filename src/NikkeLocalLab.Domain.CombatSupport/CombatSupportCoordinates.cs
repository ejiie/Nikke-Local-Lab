namespace NikkeLocalLab.Domain.CombatSupport;

public enum CombatSupportDefinitionKind
{
  Equipment,
  HarmonyCube,
  GenericCollection,
  Favorite,
  Console,
  OverloadOption
}

public enum CombatSupportEquipmentSlot
{
  Head,
  Torso,
  Arms,
  Legs
}

public enum CombatSupportCombatRole
{
  Attacker,
  Defender,
  Supporter
}

public enum CombatSupportManufacturer
{
  Elysion,
  Missilis,
  Tetra,
  Pilgrim,
  Abnormal
}

public enum CombatSupportRarity
{
  R,
  Sr,
  Ssr
}

public enum CombatSupportWeaponClass
{
  AssaultRifle,
  RocketLauncher,
  SniperRifle,
  MachineGun,
  Shotgun,
  SubmachineGun
}

public enum CombatSupportConsoleCoordinate
{
  Common,
  Attacker,
  Defender,
  Supporter,
  Elysion,
  Missilis,
  Tetra,
  Pilgrim,
  Abnormal
}

public enum CombatSupportStat
{
  Attack,
  Defence,
  Hp,
  EnergyResistance,
  MetalResistance,
  BioResistance
}

public enum CombatSupportValueUnit
{
  Absolute,
  Ratio,
  Percent,
  Count
}

public enum CombatSupportOverloadOptionType
{
  Attack,
  Defence,
  MaximumAmmunition,
  CriticalRate,
  CriticalDamage,
  ChargeDamage,
  ChargeSpeed,
  ElementalDamage,
  HitRate
}

public enum CombatSupportOverloadDuplicatePolicy
{
  AllowSameTypeOnOneEquipment,
  ForbidSameTypeOnOneEquipment
}

public sealed class CombatSupportEquipmentOptionSlot
{
  public CombatSupportEquipmentOptionSlot(int ordinal, CombatSupportExactValue activationProbability)
  {
    if (ordinal < 0 || activationProbability.ToDecimal() is < 0m or > 1m)
    {
      throw new ArgumentOutOfRangeException(nameof(ordinal));
    }

    Ordinal = ordinal;
    ActivationProbability = activationProbability;
  }

  public int Ordinal { get; }

  public CombatSupportExactValue ActivationProbability { get; }
}

public sealed class CombatSupportOverloadLegalBand
{
  public CombatSupportOverloadLegalBand(
      int ordinal,
      CombatSupportExactValue probability,
      IEnumerable<CombatSupportOverloadLegalValue> orderedValues)
  {
    ArgumentNullException.ThrowIfNull(orderedValues);
    var normalized = orderedValues.ToArray();
    if (ordinal < 0 || probability.ToDecimal() is < 0m or > 1m || normalized.Length == 0 ||
        normalized.Any(static value => value is null) ||
        normalized.Select(static value => value.RollLevel).Distinct().Count() != normalized.Length ||
        normalized.Select(static value => value.EngineFraction.ToDecimal()).Distinct().Count() != normalized.Length)
    {
      throw new ArgumentException("An overload legal band is not canonical.");
    }

    Ordinal = ordinal;
    Probability = probability;
    OrderedValues = Array.AsReadOnly(normalized);
  }

  public int Ordinal { get; }

  public CombatSupportExactValue Probability { get; }

  public IReadOnlyList<CombatSupportOverloadLegalValue> OrderedValues { get; }
}

public sealed class CombatSupportOverloadLegalValue
{
  public CombatSupportOverloadLegalValue(
      int rollLevel,
      long sourceRawValue,
      int magnitudeBasisPoints,
      CombatSupportExactValue engineFraction)
  {
    if (rollLevel <= 0)
    {
      throw new ArgumentOutOfRangeException(nameof(rollLevel));
    }

    if (sourceRawValue == long.MinValue || magnitudeBasisPoints <= 0 ||
        Math.Abs(sourceRawValue) != magnitudeBasisPoints ||
        engineFraction != new CombatSupportExactValue(magnitudeBasisPoints, 4))
    {
      throw new ArgumentException("An overload legal value must preserve its signed source and basis-point magnitude.");
    }

    RollLevel = rollLevel;
    SourceRawValue = sourceRawValue;
    MagnitudeBasisPoints = magnitudeBasisPoints;
    EngineFraction = engineFraction;
  }

  public int RollLevel { get; }

  public long SourceRawValue { get; }

  public int MagnitudeBasisPoints { get; }

  public CombatSupportExactValue EngineFraction { get; }

  public CombatSupportExactValue UiPercent => new(MagnitudeBasisPoints, 2);
}

public sealed class CombatSupportStatContribution
{
  public CombatSupportStatContribution(
      int ordinal,
      CombatSupportFact<CombatSupportStat> stat,
      CombatSupportFact<CombatSupportValueUnit> unit,
      CombatSupportExactValue value)
  {
    if (ordinal < 0)
    {
      throw new ArgumentOutOfRangeException(nameof(ordinal));
    }

    Ordinal = ordinal;
    Stat = stat ?? throw new ArgumentNullException(nameof(stat));
    Unit = unit ?? throw new ArgumentNullException(nameof(unit));
    Value = value;
  }

  public int Ordinal { get; }

  public CombatSupportFact<CombatSupportStat> Stat { get; }

  public CombatSupportFact<CombatSupportValueUnit> Unit { get; }

  public CombatSupportExactValue Value { get; }

  public bool HasResolvedSemantics =>
      Stat.Status == CombatSupportFactStatus.Ready &&
      Unit.Status == CombatSupportFactStatus.Ready;
}

public sealed class CombatSupportLevelCoordinate
{
  public CombatSupportLevelCoordinate(
      int level,
      CombatSupportFact<int> grade,
      CombatSupportFact<int> capacity,
      IEnumerable<int> skillLevels,
      IEnumerable<CombatSupportStatContribution> contributions,
      CombatSupportFact<int>? minimumSynchroLevel = null)
  {
    if (level < 0)
    {
      throw new ArgumentOutOfRangeException(nameof(level));
    }

    ArgumentNullException.ThrowIfNull(skillLevels);
    ArgumentNullException.ThrowIfNull(contributions);
    var normalizedSkillLevels = skillLevels.ToArray();
    var normalizedContributions = contributions.OrderBy(static item => item.Ordinal).ToArray();
    if (normalizedSkillLevels.Any(static value => value < 0) ||
        normalizedContributions.Any(static item => item is null) ||
        !normalizedContributions.Select(static item => item.Ordinal)
            .SequenceEqual(Enumerable.Range(0, normalizedContributions.Length)))
    {
      throw new ArgumentException("A combat-support level coordinate is not canonical.");
    }

    Level = level;
    Grade = grade ?? throw new ArgumentNullException(nameof(grade));
    Capacity = capacity ?? throw new ArgumentNullException(nameof(capacity));
    MinimumSynchroLevel = minimumSynchroLevel ?? CombatSupportFact<int>.NotApplicable();
    SkillLevels = Array.AsReadOnly(normalizedSkillLevels);
    Contributions = Array.AsReadOnly(normalizedContributions);
  }

  public int Level { get; }

  public CombatSupportFact<int> Grade { get; }

  public CombatSupportFact<int> Capacity { get; }

  public CombatSupportFact<int> MinimumSynchroLevel { get; }

  public IReadOnlyList<int> SkillLevels { get; }

  public IReadOnlyList<CombatSupportStatContribution> Contributions { get; }

  public bool HasResolvedContributionSemantics =>
      Contributions.All(static contribution => contribution.HasResolvedSemantics);
}
