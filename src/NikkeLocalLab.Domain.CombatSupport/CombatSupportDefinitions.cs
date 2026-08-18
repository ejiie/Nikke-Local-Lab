using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Domain.CombatSupport;

public interface ICombatSupportDefinitionContent
{
  CombatSupportDefinitionKind Kind { get; }

  bool IsProfileSelectable { get; }

  bool HasCompleteCombatSemantics { get; }
}

public sealed class EquipmentDefinitionContent : ICombatSupportDefinitionContent
{
  public EquipmentDefinitionContent(
      CombatSupportEquipmentSlot slot,
      CombatSupportFact<CombatSupportCombatRole> combatRole,
      CombatSupportFact<CombatSupportManufacturer> manufacturer,
      CombatSupportFact<int> tier,
      CombatSupportFact<int> enhancementGrade,
      CombatSupportFact<int> maximumEnhancementLevel,
      CombatSupportFact<bool> overloadEligible,
      IEnumerable<CombatSupportStatContribution> baseStats,
      IEnumerable<CombatSupportEquipmentOptionSlot> optionSlots)
  {
    Slot = RequireEnum(slot, nameof(slot));
    CombatRole = combatRole ?? throw new ArgumentNullException(nameof(combatRole));
    Manufacturer = manufacturer ?? throw new ArgumentNullException(nameof(manufacturer));
    Tier = RequireRange(tier, 1, 100, nameof(tier));
    EnhancementGrade = RequireRange(enhancementGrade, 0, 1_000_000, nameof(enhancementGrade));
    MaximumEnhancementLevel = RequireRange(
        maximumEnhancementLevel,
        0,
        1_000_000,
        nameof(maximumEnhancementLevel));
    OverloadEligible = overloadEligible ?? throw new ArgumentNullException(nameof(overloadEligible));
    ArgumentNullException.ThrowIfNull(baseStats);
    ArgumentNullException.ThrowIfNull(optionSlots);
    var normalizedStats = baseStats.OrderBy(static item => item.Ordinal).ToArray();
    var normalizedSlots = optionSlots.OrderBy(static item => item.Ordinal).ToArray();
    if (normalizedStats.Length != 2 ||
        !normalizedStats.Select(static item => item.Ordinal).SequenceEqual(Enumerable.Range(0, 2)) ||
        normalizedSlots.Length != 3 ||
        !normalizedSlots.Select(static item => item.Ordinal).SequenceEqual(Enumerable.Range(0, 3)))
    {
      throw new ArgumentException("Equipment stats and option slots must preserve their authoritative coordinates.");
    }

    BaseStats = Array.AsReadOnly(normalizedStats);
    OptionSlots = Array.AsReadOnly(normalizedSlots);
  }

  public CombatSupportDefinitionKind Kind => CombatSupportDefinitionKind.Equipment;

  public CombatSupportEquipmentSlot Slot { get; }

  public CombatSupportFact<CombatSupportCombatRole> CombatRole { get; }

  public CombatSupportFact<CombatSupportManufacturer> Manufacturer { get; }

  public CombatSupportFact<int> Tier { get; }

  public CombatSupportFact<int> EnhancementGrade { get; }

  public CombatSupportFact<int> MaximumEnhancementLevel { get; }

  public CombatSupportFact<bool> OverloadEligible { get; }

  public IReadOnlyList<CombatSupportStatContribution> BaseStats { get; }

  public IReadOnlyList<CombatSupportEquipmentOptionSlot> OptionSlots { get; }

  public bool IsProfileSelectable =>
      CombatRole.Status == CombatSupportFactStatus.Ready &&
      Tier.Status == CombatSupportFactStatus.Ready &&
      EnhancementGrade.Status == CombatSupportFactStatus.Ready &&
      MaximumEnhancementLevel.Status == CombatSupportFactStatus.Ready;

  public bool HasCompleteCombatSemantics =>
      IsProfileSelectable &&
      Manufacturer.IsResolved &&
      OverloadEligible.IsResolved &&
      BaseStats.All(static item => item.HasResolvedSemantics);

  private static T RequireEnum<T>(T value, string parameterName)
      where T : struct, Enum
  {
    if (!Enum.IsDefined(value))
    {
      throw new ArgumentOutOfRangeException(parameterName);
    }

    return value;
  }

  private static CombatSupportFact<int> RequireRange(
      CombatSupportFact<int> fact,
      int minimum,
      int maximum,
      string parameterName)
  {
    ArgumentNullException.ThrowIfNull(fact, parameterName);
    if (fact.Value is { } value && (value < minimum || value > maximum))
    {
      throw new ArgumentOutOfRangeException(parameterName);
    }

    return fact;
  }
}

public sealed class HarmonyCubeDefinitionContent : ICombatSupportDefinitionContent
{
  public HarmonyCubeDefinitionContent(
      CombatSupportFact<CombatSupportRarity> rarity,
      CombatSupportFact<CombatSupportCombatRole> applicableCombatRole,
      CombatSupportFact<int> maximumLevel,
      IEnumerable<CombatSupportLevelCoordinate> levels,
      CombatSupportFact<bool> skillSemantics)
  {
    Rarity = rarity ?? throw new ArgumentNullException(nameof(rarity));
    ApplicableCombatRole = applicableCombatRole ??
        throw new ArgumentNullException(nameof(applicableCombatRole));
    MaximumLevel = maximumLevel ?? throw new ArgumentNullException(nameof(maximumLevel));
    SkillSemantics = RequireSkillSemantics(skillSemantics);
    Levels = NormalizeLevels(levels);
    if (MaximumLevel.Value is { } maximum &&
        (maximum != 15 || !Levels.Select(static item => item.Level)
            .SequenceEqual(Enumerable.Range(1, maximum))))
    {
      throw new ArgumentException("A harmony cube must expose the authoritative 1..15 level coordinates.");
    }

    if (Levels.Any(static item =>
            item.Grade.Status != CombatSupportFactStatus.NotApplicable ||
            item.Capacity.Status != CombatSupportFactStatus.Ready ||
            item.MinimumSynchroLevel.Status != CombatSupportFactStatus.NotApplicable ||
            item.SkillLevels.Count != 3))
    {
      throw new ArgumentException("A harmony-cube level coordinate has an invalid shape.", nameof(levels));
    }
  }

  public CombatSupportDefinitionKind Kind => CombatSupportDefinitionKind.HarmonyCube;

  public CombatSupportFact<CombatSupportRarity> Rarity { get; }

  public CombatSupportFact<CombatSupportCombatRole> ApplicableCombatRole { get; }

  public CombatSupportFact<int> MaximumLevel { get; }

  public IReadOnlyList<CombatSupportLevelCoordinate> Levels { get; }

  public CombatSupportFact<bool> SkillSemantics { get; }

  public bool IsProfileSelectable =>
      Rarity.Status == CombatSupportFactStatus.Ready &&
      ApplicableCombatRole.IsResolved &&
      MaximumLevel.Status == CombatSupportFactStatus.Ready &&
      MaximumLevel.Value == 15 &&
      Levels.Count == 15;

  public bool HasCompleteCombatSemantics =>
      IsProfileSelectable &&
      SkillSemantics.Status == CombatSupportFactStatus.Ready &&
      SkillSemantics.Value == true &&
      Levels.All(static item => item.HasResolvedContributionSemantics);

  private static IReadOnlyList<CombatSupportLevelCoordinate> NormalizeLevels(
      IEnumerable<CombatSupportLevelCoordinate> levels) =>
      CombatSupportLevelGuard.Normalize(levels);

  private static CombatSupportFact<bool> RequireSkillSemantics(CombatSupportFact<bool> value)
  {
    ArgumentNullException.ThrowIfNull(value);
    if (value.Status == CombatSupportFactStatus.NotApplicable ||
        (value.Status == CombatSupportFactStatus.Ready && value.Value != true))
    {
      throw new ArgumentException("Skill semantics must be ready or explicitly unresolved.", nameof(value));
    }

    return value;
  }
}

public sealed class GenericCollectionDefinitionContent : ICombatSupportDefinitionContent
{
  public GenericCollectionDefinitionContent(
      CombatSupportFact<CombatSupportWeaponClass> applicableWeaponClass,
      CombatSupportFact<CombatSupportRarity> rarity,
      CombatSupportFact<int> maximumLevel,
      IEnumerable<CombatSupportLevelCoordinate> levels,
      CombatSupportFact<bool> skillSemantics)
  {
    ApplicableWeaponClass = applicableWeaponClass ??
        throw new ArgumentNullException(nameof(applicableWeaponClass));
    Rarity = rarity ?? throw new ArgumentNullException(nameof(rarity));
    MaximumLevel = maximumLevel ?? throw new ArgumentNullException(nameof(maximumLevel));
    SkillSemantics = RequireSkillSemantics(skillSemantics);
    Levels = CombatSupportLevelGuard.Normalize(levels);
    CombatSupportLevelGuard.RequireZeroBasedThroughMaximum(MaximumLevel, Levels, nameof(levels));
    CombatSupportLevelGuard.RequireCollectionShape(Levels, nameof(levels));
  }

  public CombatSupportDefinitionKind Kind => CombatSupportDefinitionKind.GenericCollection;

  public CombatSupportFact<CombatSupportWeaponClass> ApplicableWeaponClass { get; }

  public CombatSupportFact<CombatSupportRarity> Rarity { get; }

  public CombatSupportFact<int> MaximumLevel { get; }

  public IReadOnlyList<CombatSupportLevelCoordinate> Levels { get; }

  public CombatSupportFact<bool> SkillSemantics { get; }

  public bool IsProfileSelectable =>
      ApplicableWeaponClass.Status == CombatSupportFactStatus.Ready &&
      Rarity.Status == CombatSupportFactStatus.Ready &&
      MaximumLevel.Status == CombatSupportFactStatus.Ready &&
      Levels.Count > 0;

  public bool HasCompleteCombatSemantics =>
      IsProfileSelectable &&
      SkillSemantics.Status == CombatSupportFactStatus.Ready &&
      SkillSemantics.Value == true &&
      Levels.All(static item => item.HasResolvedContributionSemantics);

  private static CombatSupportFact<bool> RequireSkillSemantics(CombatSupportFact<bool> value)
  {
    ArgumentNullException.ThrowIfNull(value);
    if (value.Status == CombatSupportFactStatus.NotApplicable ||
        (value.Status == CombatSupportFactStatus.Ready && value.Value != true))
    {
      throw new ArgumentException("Skill semantics must be ready or explicitly unresolved.", nameof(value));
    }

    return value;
  }
}

public sealed class FavoriteDefinitionContent : ICombatSupportDefinitionContent
{
  public FavoriteDefinitionContent(
      CombatSupportFact<EntityUid> applicableCharacterUid,
      CombatSupportFact<CombatSupportRarity> rarity,
      CombatSupportFact<int> maximumLevel,
      IEnumerable<CombatSupportLevelCoordinate> levels,
      CombatSupportFact<bool> skillSemantics)
  {
    ApplicableCharacterUid = applicableCharacterUid ??
        throw new ArgumentNullException(nameof(applicableCharacterUid));
    if (ApplicableCharacterUid.Value is { } characterUid && characterUid.Value == Guid.Empty)
    {
      throw new ArgumentException("An applicable character UID cannot be empty.", nameof(applicableCharacterUid));
    }

    Rarity = rarity ?? throw new ArgumentNullException(nameof(rarity));
    MaximumLevel = maximumLevel ?? throw new ArgumentNullException(nameof(maximumLevel));
    SkillSemantics = RequireSkillSemantics(skillSemantics);
    Levels = CombatSupportLevelGuard.Normalize(levels);
    CombatSupportLevelGuard.RequireZeroBasedThroughMaximum(MaximumLevel, Levels, nameof(levels));
    CombatSupportLevelGuard.RequireCollectionShape(Levels, nameof(levels));
  }

  public CombatSupportDefinitionKind Kind => CombatSupportDefinitionKind.Favorite;

  public CombatSupportFact<EntityUid> ApplicableCharacterUid { get; }

  public CombatSupportFact<CombatSupportRarity> Rarity { get; }

  public CombatSupportFact<int> MaximumLevel { get; }

  public IReadOnlyList<CombatSupportLevelCoordinate> Levels { get; }

  public CombatSupportFact<bool> SkillSemantics { get; }

  public bool IsProfileSelectable =>
      ApplicableCharacterUid.Status == CombatSupportFactStatus.Ready &&
      Rarity.Status == CombatSupportFactStatus.Ready &&
      MaximumLevel.Status == CombatSupportFactStatus.Ready &&
      Levels.Count > 0;

  public bool HasCompleteCombatSemantics =>
      IsProfileSelectable &&
      SkillSemantics.Status == CombatSupportFactStatus.Ready &&
      SkillSemantics.Value == true &&
      Levels.All(static item => item.HasResolvedContributionSemantics);

  private static CombatSupportFact<bool> RequireSkillSemantics(CombatSupportFact<bool> value)
  {
    ArgumentNullException.ThrowIfNull(value);
    if (value.Status == CombatSupportFactStatus.NotApplicable ||
        (value.Status == CombatSupportFactStatus.Ready && value.Value != true))
    {
      throw new ArgumentException("Skill semantics must be ready or explicitly unresolved.", nameof(value));
    }

    return value;
  }
}

public sealed class ConsoleDefinitionContent : ICombatSupportDefinitionContent
{
  public ConsoleDefinitionContent(
      CombatSupportConsoleCoordinate coordinate,
      CombatSupportFact<int> maximumLevel,
      IEnumerable<CombatSupportLevelCoordinate> levels,
      IEnumerable<CombatSupportStatContribution> perLevelContributions)
  {
    if (!Enum.IsDefined(coordinate))
    {
      throw new ArgumentOutOfRangeException(nameof(coordinate));
    }

    Coordinate = coordinate;
    MaximumLevel = maximumLevel ?? throw new ArgumentNullException(nameof(maximumLevel));
    Levels = CombatSupportLevelGuard.Normalize(levels);
    ArgumentNullException.ThrowIfNull(perLevelContributions);
    var normalizedContributions = perLevelContributions.OrderBy(static item => item.Ordinal).ToArray();
    if (normalizedContributions.Length != 3 ||
        normalizedContributions.Any(static item => item is null) ||
        !normalizedContributions.Select(static item => item.Ordinal).SequenceEqual(Enumerable.Range(0, 3)))
    {
      throw new ArgumentException("A console must expose three per-level stat coefficients.", nameof(perLevelContributions));
    }

    PerLevelContributions = Array.AsReadOnly(normalizedContributions);
    if (MaximumLevel.Value is { } maximum &&
        !Levels.Select(static item => item.Level).SequenceEqual(Enumerable.Range(1, maximum)))
    {
      throw new ArgumentException("Console levels must be the contiguous 1..maximum coordinates.", nameof(levels));
    }

    if (Levels.Any(static item =>
            item.Grade.Status != CombatSupportFactStatus.NotApplicable ||
            item.Capacity.Status != CombatSupportFactStatus.NotApplicable ||
            item.SkillLevels.Count != 0 ||
            item.Contributions.Count != 0 ||
            item.MinimumSynchroLevel.Status != CombatSupportFactStatus.Ready))
    {
      throw new ArgumentException("A console level coordinate has an invalid shape.", nameof(levels));
    }
  }

  public CombatSupportDefinitionKind Kind => CombatSupportDefinitionKind.Console;

  public CombatSupportConsoleCoordinate Coordinate { get; }

  public CombatSupportFact<int> MaximumLevel { get; }

  public IReadOnlyList<CombatSupportLevelCoordinate> Levels { get; }

  public IReadOnlyList<CombatSupportStatContribution> PerLevelContributions { get; }

  public bool IsProfileSelectable =>
      MaximumLevel.Status == CombatSupportFactStatus.Ready && Levels.Count > 0;

  public bool HasCompleteCombatSemantics =>
      IsProfileSelectable &&
      PerLevelContributions.All(static item => item.HasResolvedSemantics);
}

public sealed class OverloadOptionDefinitionContent : ICombatSupportDefinitionContent
{
  public OverloadOptionDefinitionContent(
      CombatSupportFact<CombatSupportOverloadOptionType> optionType,
      CombatSupportFact<CombatSupportValueUnit> unit,
      CombatSupportExactValue kindSelectionProbability,
      IEnumerable<CombatSupportOverloadLegalBand> legalBands,
      CombatSupportFact<CombatSupportOverloadDuplicatePolicy> duplicatePolicy)
  {
    OptionType = optionType ?? throw new ArgumentNullException(nameof(optionType));
    Unit = unit ?? throw new ArgumentNullException(nameof(unit));
    if (kindSelectionProbability.ToDecimal() is <= 0m or > 1m)
    {
      throw new ArgumentOutOfRangeException(nameof(kindSelectionProbability));
    }

    KindSelectionProbability = kindSelectionProbability;
    ArgumentNullException.ThrowIfNull(legalBands);
    DuplicatePolicy = duplicatePolicy ?? throw new ArgumentNullException(nameof(duplicatePolicy));
    var normalizedBands = legalBands.OrderBy(static item => item.Ordinal).ToArray();
    if (normalizedBands.Length != 3 ||
        normalizedBands.Any(static item => item is null) ||
        !normalizedBands.Select(static item => item.Ordinal)
            .SequenceEqual(Enumerable.Range(0, normalizedBands.Length)) ||
        !normalizedBands.Select(static item => item.Probability).SequenceEqual(
            new[]
            {
              new CombatSupportExactValue(6_000, 4),
              new CombatSupportExactValue(3_500, 4),
              new CombatSupportExactValue(500, 4)
            }) ||
        normalizedBands.Where((band, index) =>
                !band.OrderedValues.Select(static value => value.RollLevel)
                    .SequenceEqual(Enumerable.Range((index * 5) + 1, 5)))
            .Any() ||
        normalizedBands.SelectMany(static item => item.OrderedValues)
            .Select(static value => value.EngineFraction.ToDecimal()).Distinct().Count() !=
        normalizedBands.Sum(static item => item.OrderedValues.Count))
    {
      throw new ArgumentException("The overload legal-value bands are not canonical.", nameof(legalBands));
    }

    LegalBands = Array.AsReadOnly(normalizedBands);
    if (OptionType.Value is { } resolvedOptionType)
    {
      var expectedKindProbability = resolvedOptionType is
          CombatSupportOverloadOptionType.Attack or
          CombatSupportOverloadOptionType.Defence or
          CombatSupportOverloadOptionType.CriticalDamage or
          CombatSupportOverloadOptionType.ElementalDamage
          ? new CombatSupportExactValue(10, 2)
          : new CombatSupportExactValue(12, 2);
      var expectsNegative = resolvedOptionType is
          CombatSupportOverloadOptionType.ChargeSpeed or CombatSupportOverloadOptionType.HitRate;
      if (KindSelectionProbability != expectedKindProbability ||
          LegalBands.SelectMany(static item => item.OrderedValues).Any(value =>
              expectsNegative ? value.SourceRawValue >= 0 : value.SourceRawValue <= 0))
      {
        throw new ArgumentException("The overload option kind probability or application sign is invalid.");
      }
    }

    if (Unit.Value is { } resolvedUnit && resolvedUnit != CombatSupportValueUnit.Ratio)
    {
      throw new ArgumentException("An overload option must use the normalized ratio unit.", nameof(unit));
    }

    if (OptionType.Status == CombatSupportFactStatus.NotApplicable ||
        Unit.Status == CombatSupportFactStatus.NotApplicable ||
        DuplicatePolicy.Status == CombatSupportFactStatus.NotApplicable)
    {
      throw new ArgumentException("An overload option cannot mark its semantics not-applicable.");
    }
  }

  public CombatSupportDefinitionKind Kind => CombatSupportDefinitionKind.OverloadOption;

  public CombatSupportFact<CombatSupportOverloadOptionType> OptionType { get; }

  public CombatSupportFact<CombatSupportValueUnit> Unit { get; }

  public CombatSupportExactValue KindSelectionProbability { get; }

  public IReadOnlyList<CombatSupportOverloadLegalBand> LegalBands { get; }

  public CombatSupportFact<CombatSupportOverloadDuplicatePolicy> DuplicatePolicy { get; }

  public bool IsResearchReady =>
      OptionType.Status == CombatSupportFactStatus.Ready &&
      Unit.Status == CombatSupportFactStatus.Ready;

  public bool IsGameLegalReady =>
      IsResearchReady && LegalBands.Count > 0 &&
      LegalBands.Sum(static item => item.OrderedValues.Count) == 15;

  public bool IsDuplicatePolicyReady =>
      DuplicatePolicy.Status == CombatSupportFactStatus.Ready;

  public bool IsProfileSelectable => IsResearchReady;

  public bool HasCompleteCombatSemantics => IsGameLegalReady && IsDuplicatePolicyReady;
}

public sealed class CombatSupportDefinition
{
  public CombatSupportDefinition(EntityUid definitionUid)
  {
    DefinitionUid = RequireUid(definitionUid, nameof(definitionUid));
  }

  public EntityUid DefinitionUid { get; }

  internal static EntityUid RequireUid(EntityUid value, string parameterName)
  {
    if (value.Value == Guid.Empty)
    {
      throw new ArgumentException("A combat-support domain UID cannot be empty.", parameterName);
    }

    return value;
  }
}

public sealed class CombatSupportDefinitionVersion
{
  private CombatSupportDefinitionVersion(
      EntityUid definitionVersionUid,
      EntityUid definitionUid,
      EntityUid datasetSnapshotUid,
      ICombatSupportDefinitionContent content,
      Sha256Digest contentSha256)
  {
    DefinitionVersionUid = definitionVersionUid;
    DefinitionUid = definitionUid;
    DatasetSnapshotUid = datasetSnapshotUid;
    Content = content;
    ContentSha256 = contentSha256;
  }

  public EntityUid DefinitionVersionUid { get; }

  public EntityUid DefinitionUid { get; }

  public EntityUid DatasetSnapshotUid { get; }

  public ICombatSupportDefinitionContent Content { get; }

  public Sha256Digest ContentSha256 { get; }

  public static CombatSupportDefinitionVersion Create(
      EntityUid definitionVersionUid,
      CombatSupportDefinition definition,
      EntityUid datasetSnapshotUid,
      ICombatSupportDefinitionContent content)
  {
    ArgumentNullException.ThrowIfNull(definition);
    ArgumentNullException.ThrowIfNull(content);
    return new CombatSupportDefinitionVersion(
        CombatSupportDefinition.RequireUid(definitionVersionUid, nameof(definitionVersionUid)),
        definition.DefinitionUid,
        CombatSupportDefinition.RequireUid(datasetSnapshotUid, nameof(datasetSnapshotUid)),
        content,
        CombatSupportDefinitionCanonicalizer.ComputeContentHash(content));
  }
}

internal static class CombatSupportLevelGuard
{
  public static IReadOnlyList<CombatSupportLevelCoordinate> Normalize(
      IEnumerable<CombatSupportLevelCoordinate> levels)
  {
    ArgumentNullException.ThrowIfNull(levels);
    var normalized = levels.OrderBy(static item => item.Level).ToArray();
    if (normalized.Length == 0 ||
        normalized.Any(static item => item is null) ||
        normalized.GroupBy(static item => item.Level).Any(static group => group.Count() != 1))
    {
      throw new ArgumentException("Level coordinates must be non-empty and unique.", nameof(levels));
    }

    return Array.AsReadOnly(normalized);
  }

  public static void RequireZeroBasedThroughMaximum(
      CombatSupportFact<int> maximumLevel,
      IReadOnlyList<CombatSupportLevelCoordinate> levels,
      string parameterName)
  {
    if (maximumLevel.Value is { } maximum &&
        (maximum <= 0 || !levels.Select(static item => item.Level)
            .SequenceEqual(Enumerable.Range(0, checked(maximum + 1)))))
    {
      throw new ArgumentException("Level coordinates must be contiguous from zero through maximum.", parameterName);
    }
  }

  public static void RequireCollectionShape(
      IReadOnlyList<CombatSupportLevelCoordinate> levels,
      string parameterName)
  {
    if (levels.Any(static item =>
            item.Grade.Status != CombatSupportFactStatus.Ready ||
            item.Capacity.Status != CombatSupportFactStatus.NotApplicable ||
            item.MinimumSynchroLevel.Status != CombatSupportFactStatus.NotApplicable ||
            item.SkillLevels.Count != 2))
    {
      throw new ArgumentException("A collection level coordinate has an invalid shape.", parameterName);
    }
  }
}
