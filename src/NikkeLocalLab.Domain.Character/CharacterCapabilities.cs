using NikkeLocalLab.Identity;

namespace NikkeLocalLab.Domain.Character;

public enum EquipmentSlot
{
  Head,
  Torso,
  Arms,
  Legs,
}

public sealed class EquipmentSlotCapability
{
  public EquipmentSlotCapability(
      EquipmentSlot slot,
      NormalizedFact<EntityUid> equipmentDefinitionUid,
      NormalizedFact<int> maximumTier,
      NormalizedFact<int> maximumTierTenEnhancementLevel,
      NormalizedFact<bool> manufacturerMatch)
  {
    Slot = slot;
    EquipmentDefinitionUid = FactValidation.RequireApplicable(
        equipmentDefinitionUid,
        nameof(equipmentDefinitionUid));
    FactValidation.RequireReadyUid(EquipmentDefinitionUid, nameof(equipmentDefinitionUid));
    MaximumTier = FactValidation.RequireApplicableNonNegative(maximumTier, nameof(maximumTier));
    MaximumTierTenEnhancementLevel = FactValidation.RequireApplicableNonNegative(
        maximumTierTenEnhancementLevel,
        nameof(maximumTierTenEnhancementLevel));
    ManufacturerMatch = FactValidation.RequireFact(manufacturerMatch, nameof(manufacturerMatch));
  }

  public EquipmentSlot Slot { get; }

  public NormalizedFact<EntityUid> EquipmentDefinitionUid { get; }

  public NormalizedFact<int> MaximumTier { get; }

  public NormalizedFact<int> MaximumTierTenEnhancementLevel { get; }

  public NormalizedFact<bool> ManufacturerMatch { get; }
}

public sealed class SkillMaximums
{
  public SkillMaximums(
      NormalizedFact<int> skill1,
      NormalizedFact<int> skill2,
      NormalizedFact<int> burst)
  {
    Skill1 = FactValidation.RequireApplicablePositive(skill1, nameof(skill1));
    Skill2 = FactValidation.RequireApplicablePositive(skill2, nameof(skill2));
    Burst = FactValidation.RequireApplicablePositive(burst, nameof(burst));
  }

  public NormalizedFact<int> Skill1 { get; }

  public NormalizedFact<int> Skill2 { get; }

  public NormalizedFact<int> Burst { get; }
}

public sealed class CharacterCapabilities
{
  private static readonly EquipmentSlot[] RequiredEquipmentSlots = Enum.GetValues<EquipmentSlot>();

  public CharacterCapabilities(
      NormalizedFact<int> maximumCharacterLevel,
      NormalizedFact<int> maximumLimitBreak,
      NormalizedFact<int> maximumCoreLevel,
      NormalizedFact<int> maximumBondLevel,
      IEnumerable<EquipmentSlotCapability> equipment,
      SkillMaximums skillMaximums,
      NormalizedFact<int> maximumCubeLevel,
      NormalizedFact<int> maximumCollectionLevel,
      NormalizedFact<int> maximumFavoriteLevel)
  {
    MaximumCharacterLevel = FactValidation.RequireApplicablePositive(
        maximumCharacterLevel,
        nameof(maximumCharacterLevel));
    MaximumLimitBreak = FactValidation.RequireApplicableNonNegative(
        maximumLimitBreak,
        nameof(maximumLimitBreak));
    MaximumCoreLevel = FactValidation.RequireOptionalNonNegative(maximumCoreLevel, nameof(maximumCoreLevel));
    MaximumBondLevel = FactValidation.RequireApplicablePositive(maximumBondLevel, nameof(maximumBondLevel));
    Equipment = NormalizeEquipment(equipment);
    SkillMaximums = skillMaximums ?? throw new ArgumentNullException(nameof(skillMaximums));
    MaximumCubeLevel = FactValidation.RequireOptionalPositive(maximumCubeLevel, nameof(maximumCubeLevel));
    MaximumCollectionLevel = FactValidation.RequireOptionalPositive(
        maximumCollectionLevel,
        nameof(maximumCollectionLevel));
    MaximumFavoriteLevel = FactValidation.RequireOptionalPositive(
        maximumFavoriteLevel,
        nameof(maximumFavoriteLevel));
  }

  public NormalizedFact<int> MaximumCharacterLevel { get; }

  public NormalizedFact<int> MaximumLimitBreak { get; }

  public NormalizedFact<int> MaximumCoreLevel { get; }

  public NormalizedFact<int> MaximumBondLevel { get; }

  public IReadOnlyList<EquipmentSlotCapability> Equipment { get; }

  public SkillMaximums SkillMaximums { get; }

  public NormalizedFact<int> MaximumCubeLevel { get; }

  public NormalizedFact<int> MaximumCollectionLevel { get; }

  public NormalizedFact<int> MaximumFavoriteLevel { get; }

  private static IReadOnlyList<EquipmentSlotCapability> NormalizeEquipment(
      IEnumerable<EquipmentSlotCapability> equipment)
  {
    ArgumentNullException.ThrowIfNull(equipment);
    var items = equipment.ToArray();
    if (items.Any(static item => item is null))
    {
      throw new ArgumentException("Equipment capabilities cannot contain null entries.", nameof(equipment));
    }

    var duplicates = items.GroupBy(static item => item.Slot).Where(static group => group.Count() > 1).ToArray();
    if (duplicates.Length != 0 || items.Length != RequiredEquipmentSlots.Length)
    {
      throw new ArgumentException("Equipment capabilities must contain each of the four slots exactly once.", nameof(equipment));
    }

    var ordered = RequiredEquipmentSlots.Select(slot => items.Single(item => item.Slot == slot)).ToArray();
    return Array.AsReadOnly(ordered);
  }
}

internal static class FactValidation
{
  public static NormalizedFact<T> RequireFact<T>(NormalizedFact<T> fact, string parameterName)
      where T : struct
  {
    ArgumentNullException.ThrowIfNull(fact, parameterName);
    return fact;
  }

  public static NormalizedFact<T> RequireApplicable<T>(NormalizedFact<T> fact, string parameterName)
      where T : struct
  {
    RequireFact(fact, parameterName);
    if (fact.Status == FactStatus.NotApplicable)
    {
      throw new ArgumentException("This capability cannot be not_applicable.", parameterName);
    }

    return fact;
  }

  public static NormalizedFact<int> RequireApplicablePositive(NormalizedFact<int> fact, string parameterName)
  {
    RequireApplicable(fact, parameterName);
    RequireReadyRange(fact, static value => value > 0, "A ready value must be positive.", parameterName);
    return fact;
  }

  public static NormalizedFact<int> RequireApplicableNonNegative(
      NormalizedFact<int> fact,
      string parameterName)
  {
    RequireApplicable(fact, parameterName);
    RequireReadyRange(fact, static value => value >= 0, "A ready value cannot be negative.", parameterName);
    return fact;
  }

  public static NormalizedFact<int> RequireOptionalPositive(NormalizedFact<int> fact, string parameterName)
  {
    RequireFact(fact, parameterName);
    RequireReadyRange(fact, static value => value > 0, "A ready value must be positive.", parameterName);
    return fact;
  }

  public static NormalizedFact<int> RequireOptionalNonNegative(NormalizedFact<int> fact, string parameterName)
  {
    RequireFact(fact, parameterName);
    RequireReadyRange(fact, static value => value >= 0, "A ready value cannot be negative.", parameterName);
    return fact;
  }

  public static void RequireReadyUid(NormalizedFact<EntityUid> fact, string parameterName)
  {
    if (fact.Status == FactStatus.Ready && fact.RequireValue().Value == Guid.Empty)
    {
      throw new ArgumentException("A ready domain UID cannot be empty.", parameterName);
    }
  }

  private static void RequireReadyRange(
      NormalizedFact<int> fact,
      Func<int, bool> predicate,
      string message,
      string parameterName)
  {
    if (fact.Status == FactStatus.Ready && !predicate(fact.RequireValue()))
    {
      throw new ArgumentOutOfRangeException(parameterName, message);
    }
  }
}
