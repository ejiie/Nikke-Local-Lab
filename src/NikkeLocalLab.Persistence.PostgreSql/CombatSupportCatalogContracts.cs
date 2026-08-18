using System.Buffers.Binary;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using NikkeLocalLab.Application.Importing;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Persistence.PostgreSql;

public sealed class CombatSupportCatalogIntegrityException : Exception
{
  public CombatSupportCatalogIntegrityException(string code)
      : base(code)
  {
    Code = ControlledCode.Require(code, nameof(code));
  }

  public string Code { get; }
}

public sealed record CombatSupportCatalogIdentityBinding
{
  public const string SupportedEncoderVersion = "hmac_sha256_v1";

  public CombatSupportCatalogIdentityBinding(string encoderVersion, Sha256Digest keyCheckSha256)
  {
    if (!string.Equals(encoderVersion, SupportedEncoderVersion, StringComparison.Ordinal))
    {
      throw new CombatSupportCatalogIntegrityException("support_identity_encoder_unsupported");
    }

    if (keyCheckSha256 == default)
    {
      throw new CombatSupportCatalogIntegrityException("support_identity_key_check_invalid");
    }

    EncoderVersion = encoderVersion;
    KeyCheckSha256 = keyCheckSha256;
  }

  public string EncoderVersion { get; }

  public Sha256Digest KeyCheckSha256 { get; }

  public static CombatSupportCatalogIdentityBinding FromSecret(ReadOnlySpan<byte> localSecret)
  {
    var digest = SourceAliasFingerprintEncoder.CreateKeyCheck(localSecret);
    try
    {
      return new CombatSupportCatalogIdentityBinding(
          SupportedEncoderVersion,
          Sha256Digest.FromBytes(digest));
    }
    finally
    {
      CryptographicOperations.ZeroMemory(digest);
    }
  }
}

public enum CombatSupportDefinitionKind
{
  Equipment,
  Cube,
  Collection,
  Favorite,
  Console,
  OverloadOption
}

public enum CombatSupportFactStatus
{
  Ready,
  Unresolved,
  NotApplicable
}

public enum CombatSupportEquipmentSlot
{
  Head,
  Torso,
  Arms,
  Legs
}

public enum CombatSupportCombatClass
{
  Attacker,
  Defender,
  Supporter
}

public enum CombatSupportManufacturer
{
  Abnormal,
  Elysion,
  Missilis,
  Pilgrim,
  Tetra
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
  MachineGun,
  RocketLauncher,
  Shotgun,
  SniperRifle,
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

public readonly record struct CombatSupportExactValue
{
  public CombatSupportExactValue(long unscaledValue, int decimalScale)
  {
    if (decimalScale is < 0 or > 9)
    {
      throw new CombatSupportCatalogIntegrityException("support_exact_value_invalid");
    }

    UnscaledValue = unscaledValue;
    DecimalScale = decimalScale;
  }

  public long UnscaledValue { get; }

  public int DecimalScale { get; }

  internal decimal ToDecimal() => UnscaledValue / DecimalPowers[DecimalScale];

  private static readonly decimal[] DecimalPowers =
  [
      1m,
    10m,
    100m,
    1_000m,
    10_000m,
    100_000m,
    1_000_000m,
    10_000_000m,
    100_000_000m,
    1_000_000_000m
  ];
}

public sealed record CombatSupportValueFact<T>
    where T : struct
{
  public CombatSupportValueFact(
      CombatSupportFactStatus status,
      T? value = null,
      string? unresolvedReasonCode = null)
  {
    Status = status;
    Value = value;
    UnresolvedReasonCode = CombatSupportFactValidation.ValidateShape(
        status,
        value.HasValue,
        unresolvedReasonCode);
  }

  public CombatSupportFactStatus Status { get; }

  public T? Value { get; }

  public string? UnresolvedReasonCode { get; }
}

public sealed record CombatSupportTextFact
{
  public CombatSupportTextFact(
      CombatSupportFactStatus status,
      string? value = null,
      string? unresolvedReasonCode = null)
  {
    var reason = CombatSupportFactValidation.ValidateShape(
        status,
        value is not null,
        unresolvedReasonCode);
    if (status == CombatSupportFactStatus.NotApplicable ||
        (value is not null &&
         (string.IsNullOrWhiteSpace(value) || value.Length > 128 ||
          !value.IsNormalized(NormalizationForm.FormC) ||
          value.Any(char.IsControl))))
    {
      throw new CombatSupportCatalogIntegrityException("support_display_name_invalid");
    }

    Status = status;
    Value = value;
    UnresolvedReasonCode = reason;
  }

  public CombatSupportFactStatus Status { get; }

  public string? Value { get; }

  public string? UnresolvedReasonCode { get; }
}

public sealed record CombatSupportExactRangeFact
{
  public CombatSupportExactRangeFact(
      CombatSupportFactStatus status,
      CombatSupportExactValue? minimum = null,
      CombatSupportExactValue? maximum = null,
      string? unresolvedReasonCode = null)
  {
    var hasValue = minimum.HasValue && maximum.HasValue;
    if (minimum.HasValue != maximum.HasValue ||
        (hasValue && minimum!.Value.ToDecimal() > maximum!.Value.ToDecimal()))
    {
      throw new CombatSupportCatalogIntegrityException("support_exact_range_invalid");
    }

    Status = status;
    Minimum = minimum;
    Maximum = maximum;
    UnresolvedReasonCode = CombatSupportFactValidation.ValidateShape(
        status,
        hasValue,
        unresolvedReasonCode);
  }

  public CombatSupportFactStatus Status { get; }

  public CombatSupportExactValue? Minimum { get; }

  public CombatSupportExactValue? Maximum { get; }

  public string? UnresolvedReasonCode { get; }
}

public sealed record CombatSupportStatContributionPublication
{
  public CombatSupportStatContributionPublication(
      int ordinal,
      int unlockLevel,
      CombatSupportValueFact<CombatSupportStat> stat,
      CombatSupportValueFact<CombatSupportValueUnit> unit,
      CombatSupportExactValue exactValue)
  {
    if (ordinal < 0 || unlockLevel < 0 || unlockLevel > 1_000_000)
    {
      throw new CombatSupportCatalogIntegrityException("support_contribution_invalid");
    }

    Ordinal = ordinal;
    UnlockLevel = unlockLevel;
    Stat = stat ?? throw new ArgumentNullException(nameof(stat));
    Unit = unit ?? throw new ArgumentNullException(nameof(unit));
    ExactValue = exactValue;
  }

  public int Ordinal { get; }

  public int UnlockLevel { get; }

  public CombatSupportValueFact<CombatSupportStat> Stat { get; }

  public CombatSupportValueFact<CombatSupportValueUnit> Unit { get; }

  public CombatSupportExactValue ExactValue { get; }
}

public sealed record CombatSupportLevelCoordinatePublication
{
  public CombatSupportLevelCoordinatePublication(
      int level,
      CombatSupportValueFact<int> grade,
      CombatSupportValueFact<int> capacity,
      CombatSupportValueFact<int> minimumSynchroLevel)
  {
    if (level < 0 || level > 1_000_000)
    {
      throw new CombatSupportCatalogIntegrityException("support_level_coordinate_invalid");
    }

    Level = level;
    Grade = grade ?? throw new ArgumentNullException(nameof(grade));
    Capacity = capacity ?? throw new ArgumentNullException(nameof(capacity));
    MinimumSynchroLevel = minimumSynchroLevel ??
        throw new ArgumentNullException(nameof(minimumSynchroLevel));
    CombatSupportFactValidation.RequireIntegerRange(
        Grade,
        0,
        1_000_000,
        "support_level_grade_invalid");
    CombatSupportFactValidation.RequireIntegerRange(
        Capacity,
        0,
        1_000_000,
        "support_level_capacity_invalid");
    CombatSupportFactValidation.RequireIntegerRange(
        MinimumSynchroLevel,
        0,
        1_000_000,
        "support_level_synchro_invalid");
  }

  public int Level { get; }

  public CombatSupportValueFact<int> Grade { get; }

  public CombatSupportValueFact<int> Capacity { get; }

  public CombatSupportValueFact<int> MinimumSynchroLevel { get; }
}

public sealed record CombatSupportSkillCoordinatePublication
{
  public CombatSupportSkillCoordinatePublication(
      int ordinal,
      int unlockLevel,
      int skillSlotOrdinal,
      int skillLevel)
  {
    if (ordinal < 0 || unlockLevel < 0 || unlockLevel > 1_000_000 ||
        skillSlotOrdinal < 0 || skillSlotOrdinal > 1_000_000 ||
        skillLevel < 0 || skillLevel > 1_000_000)
    {
      throw new CombatSupportCatalogIntegrityException("support_skill_coordinate_invalid");
    }

    Ordinal = ordinal;
    UnlockLevel = unlockLevel;
    SkillSlotOrdinal = skillSlotOrdinal;
    SkillLevel = skillLevel;
  }

  public int Ordinal { get; }

  public int UnlockLevel { get; }

  public int SkillSlotOrdinal { get; }

  public int SkillLevel { get; }
}

public sealed record CombatSupportEquipmentOptionSlotPublication
{
  public CombatSupportEquipmentOptionSlotPublication(
      int ordinal,
      CombatSupportExactValue successRatio)
  {
    if (ordinal < 0 || successRatio.ToDecimal() is < 0m or > 1m)
    {
      throw new CombatSupportCatalogIntegrityException("support_equipment_option_slot_invalid");
    }

    Ordinal = ordinal;
    SuccessRatio = successRatio;
  }

  public int Ordinal { get; }

  public CombatSupportExactValue SuccessRatio { get; }
}

public sealed record CombatSupportOverloadLegalBandPublication
{
  public CombatSupportOverloadLegalBandPublication(
      int ordinal,
      CombatSupportExactValue probability,
      IEnumerable<CombatSupportOverloadLegalValuePublication> orderedValues)
  {
    ArgumentNullException.ThrowIfNull(orderedValues);
    var normalized = orderedValues.ToArray();
    if (ordinal < 0 || probability.ToDecimal() is < 0m or > 1m ||
        normalized.Length == 0 ||
        normalized.Any(static value => value is null) ||
        normalized.Select(static value => value.RollLevel).Distinct().Count() != normalized.Length ||
        normalized.Select(static value => value.EngineFraction.ToDecimal()).Distinct().Count() != normalized.Length)
    {
      throw new CombatSupportCatalogIntegrityException("support_overload_legal_band_invalid");
    }

    Ordinal = ordinal;
    Probability = probability;
    OrderedValues = Array.AsReadOnly(normalized);
  }

  public int Ordinal { get; }

  public CombatSupportExactValue Probability { get; }

  public IReadOnlyList<CombatSupportOverloadLegalValuePublication> OrderedValues { get; }
}

public sealed record CombatSupportOverloadLegalValuePublication
{
  public CombatSupportOverloadLegalValuePublication(
      SourceAliasFingerprint sourceAliasFingerprint,
      int rollLevel,
      long sourceRawValue,
      int magnitudeBasisPoints,
      CombatSupportExactValue engineFraction)
  {
    if (sourceAliasFingerprint == default || rollLevel <= 0 || rollLevel > 1_000_000 ||
        magnitudeBasisPoints <= 0 || Math.Abs(sourceRawValue) != magnitudeBasisPoints ||
        engineFraction != new CombatSupportExactValue(magnitudeBasisPoints, 4))
    {
      throw new CombatSupportCatalogIntegrityException("support_overload_legal_value_invalid");
    }

    SourceAliasFingerprint = sourceAliasFingerprint;
    RollLevel = rollLevel;
    SourceRawValue = sourceRawValue;
    MagnitudeBasisPoints = magnitudeBasisPoints;
    EngineFraction = engineFraction;
  }

  public SourceAliasFingerprint SourceAliasFingerprint { get; }

  public int RollLevel { get; }

  public long SourceRawValue { get; }

  public int MagnitudeBasisPoints { get; }

  public CombatSupportExactValue EngineFraction { get; }
}

public sealed record CombatSupportConsoleLevelPublication
{
  public CombatSupportConsoleLevelPublication(
      int ordinal,
      int level,
      int minimumSynchroLevel)
  {
    if (ordinal < 0 || level < 1 || level > 1_000_000 ||
        minimumSynchroLevel < 0 || minimumSynchroLevel > 1_000_000)
    {
      throw new CombatSupportCatalogIntegrityException("support_console_level_coordinate_invalid");
    }

    Ordinal = ordinal;
    Level = level;
    MinimumSynchroLevel = minimumSynchroLevel;
  }

  public int Ordinal { get; }

  public int Level { get; }

  public int MinimumSynchroLevel { get; }
}

public sealed record CombatSupportContributionSetPublication
{
  public CombatSupportContributionSetPublication(
      CombatSupportFactStatus status,
      IEnumerable<CombatSupportStatContributionPublication>? contributions = null,
      IEnumerable<CombatSupportSkillCoordinatePublication>? skillCoordinates = null,
      string? unresolvedReasonCode = null)
  {
    var normalized = (contributions ?? []).ToArray();
    var normalizedSkills = (skillCoordinates ?? []).ToArray();
    if (normalized.Any(static item => item is null) ||
        !normalized.Select(static item => item.Ordinal).Order()
            .SequenceEqual(Enumerable.Range(0, normalized.Length)) ||
        normalizedSkills.Any(static item => item is null) ||
        !normalizedSkills.Select(static item => item.Ordinal).Order()
            .SequenceEqual(Enumerable.Range(0, normalizedSkills.Length)))
    {
      throw new CombatSupportCatalogIntegrityException("support_contribution_set_invalid");
    }

    var hasResolvedSet = status == CombatSupportFactStatus.Ready;
    if ((!hasResolvedSet && (normalized.Length != 0 || normalizedSkills.Length != 0)) ||
        (hasResolvedSet && unresolvedReasonCode is not null))
    {
      throw new CombatSupportCatalogIntegrityException("support_contribution_set_invalid");
    }

    Status = status;
    Contributions = Array.AsReadOnly(normalized.OrderBy(static item => item.Ordinal).ToArray());
    SkillCoordinates = Array.AsReadOnly(
        normalizedSkills.OrderBy(static item => item.Ordinal).ToArray());
    UnresolvedReasonCode = CombatSupportFactValidation.ValidateShape(
        status,
        hasResolvedSet,
        unresolvedReasonCode);
  }

  public CombatSupportFactStatus Status { get; }

  public IReadOnlyList<CombatSupportStatContributionPublication> Contributions { get; }

  public IReadOnlyList<CombatSupportSkillCoordinatePublication> SkillCoordinates { get; }

  public string? UnresolvedReasonCode { get; }
}

public interface ICombatSupportDefinitionPayload
{
  CombatSupportDefinitionKind Kind { get; }

  bool IsSourceReady { get; }

  bool IsGameLegalReady { get; }
}

public sealed record CombatSupportEquipmentDefinitionPublication : ICombatSupportDefinitionPayload
{
  public CombatSupportEquipmentDefinitionPublication(
      CombatSupportEquipmentSlot slot,
      CombatSupportValueFact<CombatSupportCombatClass> combatClass,
      CombatSupportValueFact<CombatSupportManufacturer> manufacturer,
      CombatSupportValueFact<int> tier,
      CombatSupportValueFact<int> enhancementGrade,
      CombatSupportValueFact<int> maximumEnhancementLevel,
      CombatSupportValueFact<bool> overloadEligible,
      IEnumerable<CombatSupportEquipmentOptionSlotPublication>? optionSlots = null)
  {
    CombatClass = combatClass ?? throw new ArgumentNullException(nameof(combatClass));
    Manufacturer = manufacturer ?? throw new ArgumentNullException(nameof(manufacturer));
    Tier = tier ?? throw new ArgumentNullException(nameof(tier));
    EnhancementGrade = enhancementGrade ?? throw new ArgumentNullException(nameof(enhancementGrade));
    MaximumEnhancementLevel = maximumEnhancementLevel ??
        throw new ArgumentNullException(nameof(maximumEnhancementLevel));
    OverloadEligible = overloadEligible ?? throw new ArgumentNullException(nameof(overloadEligible));
    CombatSupportFactValidation.RequireIntegerRange(Tier, 1, 100, "support_equipment_tier_invalid");
    CombatSupportFactValidation.RequireIntegerRange(
        EnhancementGrade,
        0,
        1_000_000,
        "support_equipment_enhancement_grade_invalid");
    CombatSupportFactValidation.RequireIntegerRange(
        MaximumEnhancementLevel,
        0,
        1_000_000,
        "support_equipment_enhancement_invalid");
    Slot = slot;
    var normalizedSlots = (optionSlots ?? []).ToArray();
    if (normalizedSlots.Any(static item => item is null) ||
        !normalizedSlots.Select(static item => item.Ordinal).Order()
            .SequenceEqual(Enumerable.Range(0, normalizedSlots.Length)))
    {
      throw new CombatSupportCatalogIntegrityException("support_equipment_option_slot_set_invalid");
    }

    OptionSlots = Array.AsReadOnly(normalizedSlots.OrderBy(static item => item.Ordinal).ToArray());
    var tierValue = Tier.Value;
    var expectedOptionRatios = tierValue == 10
        ? new[] { 1m, 0.5m, 0.3m }
        : new[] { 0m, 0m, 0m };
    if (tierValue is not (9 or 10) ||
        Manufacturer.Status != CombatSupportFactStatus.NotApplicable ||
        EnhancementGrade.Status != CombatSupportFactStatus.Ready ||
        MaximumEnhancementLevel.Status != CombatSupportFactStatus.Ready ||
        MaximumEnhancementLevel.Value != 5 ||
        OverloadEligible.Status != CombatSupportFactStatus.Ready ||
        OverloadEligible.Value != (tierValue == 10) ||
        OptionSlots.Count != 3 ||
        !OptionSlots.Select(static slot => slot.SuccessRatio.ToDecimal())
            .SequenceEqual(expectedOptionRatios))
    {
      throw new CombatSupportCatalogIntegrityException("support_equipment_scope_unsupported");
    }
  }

  public CombatSupportDefinitionKind Kind => CombatSupportDefinitionKind.Equipment;

  public CombatSupportEquipmentSlot Slot { get; }

  public CombatSupportValueFact<CombatSupportCombatClass> CombatClass { get; }

  public CombatSupportValueFact<CombatSupportManufacturer> Manufacturer { get; }

  public CombatSupportValueFact<int> Tier { get; }

  public CombatSupportValueFact<int> EnhancementGrade { get; }

  public CombatSupportValueFact<int> MaximumEnhancementLevel { get; }

  public CombatSupportValueFact<bool> OverloadEligible { get; }

  public IReadOnlyList<CombatSupportEquipmentOptionSlotPublication> OptionSlots { get; }

  public bool IsSourceReady => CombatSupportFactValidation.AreResolved(
      CombatClass,
      Manufacturer,
      Tier,
      EnhancementGrade,
      MaximumEnhancementLevel,
      OverloadEligible);

  public bool IsGameLegalReady => IsSourceReady;
}

public sealed record CombatSupportCubeDefinitionPublication : ICombatSupportDefinitionPayload
{
  public CombatSupportCubeDefinitionPublication(
      CombatSupportValueFact<CombatSupportRarity> rarity,
      CombatSupportValueFact<CombatSupportCombatClass> applicableCombatClass,
      CombatSupportValueFact<int> maximumLevel,
      IEnumerable<CombatSupportLevelCoordinatePublication>? levels,
      CombatSupportValueFact<bool> skillSemantics)
  {
    Rarity = rarity ?? throw new ArgumentNullException(nameof(rarity));
    ApplicableCombatClass = applicableCombatClass ??
        throw new ArgumentNullException(nameof(applicableCombatClass));
    MaximumLevel = maximumLevel ?? throw new ArgumentNullException(nameof(maximumLevel));
    SkillSemantics = CombatSupportFactValidation.RequireSkillSemantics(skillSemantics);
    CombatSupportFactValidation.RequireIntegerRange(
        MaximumLevel,
        1,
        1_000_000,
        "support_cube_level_invalid");
    Levels = CombatSupportLevelValidation.Normalize(
        maximumLevel,
        levels,
        startsAtZero: false,
        "support_cube_level_set_invalid");
  }

  public CombatSupportDefinitionKind Kind => CombatSupportDefinitionKind.Cube;

  public CombatSupportValueFact<CombatSupportRarity> Rarity { get; }

  public CombatSupportValueFact<CombatSupportCombatClass> ApplicableCombatClass { get; }

  public CombatSupportValueFact<int> MaximumLevel { get; }

  public IReadOnlyList<CombatSupportLevelCoordinatePublication> Levels { get; }

  public CombatSupportValueFact<bool> SkillSemantics { get; }

  public bool IsSourceReady => Rarity.Status == CombatSupportFactStatus.Ready &&
      ApplicableCombatClass.Status != CombatSupportFactStatus.Unresolved &&
      MaximumLevel.Status == CombatSupportFactStatus.Ready &&
      Levels.Count == MaximumLevel.Value;

  public bool IsGameLegalReady => IsSourceReady &&
      SkillSemantics.Status == CombatSupportFactStatus.Ready &&
      SkillSemantics.Value == true;
}

public sealed record CombatSupportCollectionDefinitionPublication : ICombatSupportDefinitionPayload
{
  public CombatSupportCollectionDefinitionPublication(
      CombatSupportValueFact<CombatSupportWeaponClass> weaponClass,
      CombatSupportValueFact<CombatSupportRarity> rarity,
      CombatSupportValueFact<int> maximumLevel,
      IEnumerable<CombatSupportLevelCoordinatePublication>? levels,
      CombatSupportValueFact<bool> skillSemantics)
  {
    WeaponClass = weaponClass ?? throw new ArgumentNullException(nameof(weaponClass));
    Rarity = rarity ?? throw new ArgumentNullException(nameof(rarity));
    MaximumLevel = maximumLevel ?? throw new ArgumentNullException(nameof(maximumLevel));
    SkillSemantics = CombatSupportFactValidation.RequireSkillSemantics(skillSemantics);
    CombatSupportFactValidation.RequireIntegerRange(
        MaximumLevel,
        1,
        1_000_000,
        "support_collection_level_invalid");
    Levels = CombatSupportLevelValidation.Normalize(
        maximumLevel,
        levels,
        startsAtZero: true,
        "support_collection_level_set_invalid");
  }

  public CombatSupportDefinitionKind Kind => CombatSupportDefinitionKind.Collection;

  public CombatSupportValueFact<CombatSupportWeaponClass> WeaponClass { get; }

  public CombatSupportValueFact<CombatSupportRarity> Rarity { get; }

  public CombatSupportValueFact<int> MaximumLevel { get; }

  public IReadOnlyList<CombatSupportLevelCoordinatePublication> Levels { get; }

  public CombatSupportValueFact<bool> SkillSemantics { get; }

  public bool IsSourceReady => CombatSupportFactValidation.AreResolved(
      WeaponClass,
      Rarity,
      MaximumLevel) && Levels.Count == MaximumLevel.Value + 1;

  public bool IsGameLegalReady => IsSourceReady &&
      SkillSemantics.Status == CombatSupportFactStatus.Ready &&
      SkillSemantics.Value == true;
}

public sealed record CombatSupportFavoriteDefinitionPublication : ICombatSupportDefinitionPayload
{
  public CombatSupportFavoriteDefinitionPublication(
      CombatSupportValueFact<int> maximumLevel,
      CombatSupportValueFact<SourceAliasFingerprint> applicableCharacterAlias,
      CombatSupportValueFact<CombatSupportRarity> rarity,
      IEnumerable<CombatSupportLevelCoordinatePublication>? levels,
      CombatSupportValueFact<bool> skillSemantics)
  {
    MaximumLevel = maximumLevel ?? throw new ArgumentNullException(nameof(maximumLevel));
    ApplicableCharacterAlias = applicableCharacterAlias ??
        throw new ArgumentNullException(nameof(applicableCharacterAlias));
    Rarity = rarity ?? throw new ArgumentNullException(nameof(rarity));
    SkillSemantics = CombatSupportFactValidation.RequireSkillSemantics(skillSemantics);
    CombatSupportFactValidation.RequireIntegerRange(
        MaximumLevel,
        1,
        1_000_000,
        "support_favorite_level_invalid");
    if (ApplicableCharacterAlias.Status == CombatSupportFactStatus.NotApplicable ||
        (ApplicableCharacterAlias.Status == CombatSupportFactStatus.Ready &&
         ApplicableCharacterAlias.Value!.Value == default))
    {
      throw new CombatSupportCatalogIntegrityException("support_favorite_character_invalid");
    }

    Levels = CombatSupportLevelValidation.Normalize(
        maximumLevel,
        levels,
        startsAtZero: true,
        "support_favorite_level_set_invalid");
  }

  public CombatSupportDefinitionKind Kind => CombatSupportDefinitionKind.Favorite;

  public CombatSupportValueFact<int> MaximumLevel { get; }

  public CombatSupportValueFact<SourceAliasFingerprint> ApplicableCharacterAlias { get; }

  public CombatSupportValueFact<CombatSupportRarity> Rarity { get; }

  public IReadOnlyList<CombatSupportLevelCoordinatePublication> Levels { get; }

  public CombatSupportValueFact<bool> SkillSemantics { get; }

  public bool IsSourceReady => CombatSupportFactValidation.AreResolved(
      MaximumLevel,
      ApplicableCharacterAlias,
      Rarity) && Levels.Count == MaximumLevel.Value + 1;

  public bool IsGameLegalReady => IsSourceReady &&
      SkillSemantics.Status == CombatSupportFactStatus.Ready &&
      SkillSemantics.Value == true;
}

public sealed record CombatSupportConsoleDefinitionPublication : ICombatSupportDefinitionPayload
{
  public CombatSupportConsoleDefinitionPublication(
      CombatSupportConsoleCoordinate coordinate,
      CombatSupportValueFact<int> maximumLevel,
      IEnumerable<CombatSupportConsoleLevelPublication>? legalLevels = null)
  {
    MaximumLevel = maximumLevel ?? throw new ArgumentNullException(nameof(maximumLevel));
    CombatSupportFactValidation.RequireIntegerRange(
        MaximumLevel,
        1,
        1_000_000,
        "support_console_level_invalid");
    Coordinate = coordinate;
    var normalizedLevels = (legalLevels ?? []).OrderBy(static item => item.Ordinal).ToArray();
    if (normalizedLevels.Any(static item => item is null) ||
        !normalizedLevels.Select(static item => item.Ordinal)
            .SequenceEqual(Enumerable.Range(0, normalizedLevels.Length)) ||
        !normalizedLevels.Select(static item => item.Level)
            .SequenceEqual(Enumerable.Range(1, normalizedLevels.Length)) ||
        (MaximumLevel.Status == CombatSupportFactStatus.Ready &&
         MaximumLevel.Value != normalizedLevels.Length) ||
        (MaximumLevel.Status != CombatSupportFactStatus.Ready && normalizedLevels.Length != 0))
    {
      throw new CombatSupportCatalogIntegrityException("support_console_level_set_invalid");
    }

    LegalLevels = Array.AsReadOnly(normalizedLevels);
  }

  public CombatSupportDefinitionKind Kind => CombatSupportDefinitionKind.Console;

  public CombatSupportConsoleCoordinate Coordinate { get; }

  public CombatSupportValueFact<int> MaximumLevel { get; }

  public IReadOnlyList<CombatSupportConsoleLevelPublication> LegalLevels { get; }

  public bool IsSourceReady => MaximumLevel.Status == CombatSupportFactStatus.Ready &&
      LegalLevels.Count == MaximumLevel.Value;

  public bool IsGameLegalReady => IsSourceReady;
}

public sealed record CombatSupportOverloadOptionDefinitionPublication : ICombatSupportDefinitionPayload
{
  public CombatSupportOverloadOptionDefinitionPublication(
      CombatSupportValueFact<CombatSupportOverloadOptionType> optionType,
      CombatSupportValueFact<CombatSupportValueUnit> unit,
      CombatSupportExactValue kindSelectionProbability,
      IEnumerable<CombatSupportOverloadLegalBandPublication> legalBands,
      CombatSupportValueFact<CombatSupportOverloadDuplicatePolicy> duplicatePolicy)
  {
    OptionType = optionType ?? throw new ArgumentNullException(nameof(optionType));
    Unit = unit ?? throw new ArgumentNullException(nameof(unit));
    if (kindSelectionProbability.ToDecimal() is < 0m or > 1m)
    {
      throw new CombatSupportCatalogIntegrityException("support_overload_selection_probability_invalid");
    }

    KindSelectionProbability = kindSelectionProbability;
    ArgumentNullException.ThrowIfNull(legalBands);
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
        !normalizedBands.SelectMany(static item => item.OrderedValues)
            .Select(static value => value.RollLevel).Order()
            .SequenceEqual(Enumerable.Range(1, normalizedBands.Sum(static item => item.OrderedValues.Count))) ||
        normalizedBands.SelectMany(static item => item.OrderedValues)
            .Select(static value => value.EngineFraction.ToDecimal()).Distinct().Count() !=
        normalizedBands.Sum(static item => item.OrderedValues.Count))
    {
      throw new CombatSupportCatalogIntegrityException("support_overload_legal_band_set_invalid");
    }

    LegalBands = Array.AsReadOnly(normalizedBands);
    DuplicatePolicy = duplicatePolicy ?? throw new ArgumentNullException(nameof(duplicatePolicy));
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
        throw new CombatSupportCatalogIntegrityException("support_overload_option_semantics_invalid");
      }
    }

    if (OptionType.Status == CombatSupportFactStatus.NotApplicable ||
        Unit.Status == CombatSupportFactStatus.NotApplicable ||
        (Unit.Value is { } resolvedUnit && resolvedUnit != CombatSupportValueUnit.Ratio) ||
        DuplicatePolicy.Status == CombatSupportFactStatus.NotApplicable)
    {
      throw new CombatSupportCatalogIntegrityException("support_overload_fact_invalid");
    }
  }

  public CombatSupportDefinitionKind Kind => CombatSupportDefinitionKind.OverloadOption;

  public CombatSupportValueFact<CombatSupportOverloadOptionType> OptionType { get; }

  public CombatSupportValueFact<CombatSupportValueUnit> Unit { get; }

  public CombatSupportExactValue KindSelectionProbability { get; }

  public IReadOnlyList<CombatSupportOverloadLegalBandPublication> LegalBands { get; }

  public CombatSupportValueFact<CombatSupportOverloadDuplicatePolicy> DuplicatePolicy { get; }

  public bool IsSourceReady => OptionType.Status == CombatSupportFactStatus.Ready &&
      Unit.Status == CombatSupportFactStatus.Ready;

  public bool IsGameLegalReady => IsSourceReady &&
      LegalBands.Sum(static item => item.OrderedValues.Count) == 15;

  public bool IsDuplicatePolicyReady =>
      DuplicatePolicy.Status == CombatSupportFactStatus.Ready;
}

public sealed record CombatSupportDefinitionPublication
{
  public CombatSupportDefinitionPublication(
      SourceAliasFingerprint sourceAliasFingerprint,
      CombatSupportTextFact displayName,
      ICombatSupportDefinitionPayload payload,
      CombatSupportContributionSetPublication contributions)
  {
    if (sourceAliasFingerprint == default)
    {
      throw new CombatSupportCatalogIntegrityException("support_definition_invalid");
    }

    SourceAliasFingerprint = sourceAliasFingerprint;
    DisplayName = displayName ?? throw new ArgumentNullException(nameof(displayName));
    Payload = payload ?? throw new ArgumentNullException(nameof(payload));
    Contributions = contributions ?? throw new ArgumentNullException(nameof(contributions));
    if (payload.Kind == CombatSupportDefinitionKind.OverloadOption &&
        Contributions.Status != CombatSupportFactStatus.NotApplicable)
    {
      throw new CombatSupportCatalogIntegrityException("support_overload_contribution_invalid");
    }

    DefinitionContentSha256 = CombatSupportPublicationCanonicalizer
        .ComputeDefinitionContentSha256(this);
  }

  public SourceAliasFingerprint SourceAliasFingerprint { get; }

  public CombatSupportTextFact DisplayName { get; }

  public ICombatSupportDefinitionPayload Payload { get; }

  public CombatSupportContributionSetPublication Contributions { get; }

  public CombatSupportDefinitionKind Kind => Payload.Kind;

  public Sha256Digest DefinitionContentSha256 { get; }

  public bool IsSourceReady => Payload.IsSourceReady &&
      Contributions.Status != CombatSupportFactStatus.Unresolved;

  public bool IsGameLegalReady => IsSourceReady &&
      Payload.IsGameLegalReady &&
      Contributions.Contributions.All(static contribution =>
          contribution.Stat.Status == CombatSupportFactStatus.Ready &&
          contribution.Unit.Status == CombatSupportFactStatus.Ready);
}

public sealed record CombatSupportCatalogPublication
{
  public CombatSupportCatalogPublication(
      CombatSupportCatalogIdentityBinding identityBinding,
      IEnumerable<CombatSupportDefinitionPublication> definitions)
  {
    IdentityBinding = identityBinding ?? throw new ArgumentNullException(nameof(identityBinding));
    ArgumentNullException.ThrowIfNull(definitions);
    var normalized = definitions
        .OrderBy(static item => CombatSupportPublicationCodes.DefinitionKind(item.Kind), StringComparer.Ordinal)
        .ThenBy(static item => item.SourceAliasFingerprint.Hex, StringComparer.Ordinal)
        .ToArray();
    if (normalized.Length == 0 ||
        normalized.Any(static item => item is null) ||
        normalized.Select(static item => item.SourceAliasFingerprint).Distinct().Count() != normalized.Length ||
        Enum.GetValues<CombatSupportDefinitionKind>().Any(
            kind => normalized.All(item => item.Kind != kind)))
    {
      throw new CombatSupportCatalogIntegrityException("support_catalog_invalid");
    }

    var equipmentDefinitions = normalized
        .Where(static item => item.Kind == CombatSupportDefinitionKind.Equipment)
        .Select(static item => (CombatSupportEquipmentDefinitionPublication)item.Payload)
        .ToArray();
    if (equipmentDefinitions.Any(static equipment =>
            equipment.CombatClass.Status != CombatSupportFactStatus.Ready ||
            equipment.Tier.Status != CombatSupportFactStatus.Ready))
    {
      throw new CombatSupportCatalogIntegrityException("support_equipment_subset_invalid");
    }

    var equipmentCoordinates = equipmentDefinitions
        .Select(static equipment =>
            $"{CombatSupportPublicationCodes.CombatClass(equipment.CombatClass.Value!.Value)}|" +
            $"{CombatSupportPublicationCodes.EquipmentSlot(equipment.Slot)}|" +
            equipment.Tier.Value!.Value.ToString(CultureInfo.InvariantCulture))
        .OrderBy(static value => value, StringComparer.Ordinal)
        .ToArray();
    var expectedEquipmentCoordinates = (
        from combatClass in Enum.GetValues<CombatSupportCombatClass>()
        from slot in Enum.GetValues<CombatSupportEquipmentSlot>()
        from tier in new[] { 9, 10 }
        select $"{CombatSupportPublicationCodes.CombatClass(combatClass)}|" +
               $"{CombatSupportPublicationCodes.EquipmentSlot(slot)}|" +
               tier.ToString(CultureInfo.InvariantCulture))
        .OrderBy(static value => value, StringComparer.Ordinal)
        .ToArray();
    if (!equipmentCoordinates.SequenceEqual(expectedEquipmentCoordinates, StringComparer.Ordinal))
    {
      throw new CombatSupportCatalogIntegrityException("support_equipment_subset_invalid");
    }

    var consoleDefinitions = normalized
        .Where(static item => item.Payload is CombatSupportConsoleDefinitionPublication)
        .Select(static item => (CombatSupportConsoleDefinitionPublication)item.Payload)
        .ToArray();
    var consoleCoordinates = consoleDefinitions
        .Select(static item => item.Coordinate)
        .Order()
        .ToArray();
    if (!consoleCoordinates.SequenceEqual(Enum.GetValues<CombatSupportConsoleCoordinate>().Order()))
    {
      throw new CombatSupportCatalogIntegrityException("support_console_coordinate_set_invalid");
    }

    var overloadValueAliases = normalized
        .SelectMany(static definition =>
            definition.Payload is CombatSupportOverloadOptionDefinitionPublication overload
                ? overload.LegalBands.SelectMany(static band => band.OrderedValues)
                    .Select(static value => value.SourceAliasFingerprint)
                : [])
        .ToArray();
    if (overloadValueAliases.Length == 0 ||
        overloadValueAliases.Distinct().Count() != overloadValueAliases.Length ||
        overloadValueAliases.Any(alias => normalized.Any(
            definition => definition.SourceAliasFingerprint == alias)))
    {
      throw new CombatSupportCatalogIntegrityException("support_overload_value_alias_set_invalid");
    }

    var overloadOptionTypes = normalized
        .Where(static definition => definition.Kind == CombatSupportDefinitionKind.OverloadOption)
        .Select(static definition =>
            ((CombatSupportOverloadOptionDefinitionPublication)definition.Payload).OptionType)
        .ToArray();
    if (overloadOptionTypes.Any(static fact => fact.Status != CombatSupportFactStatus.Ready) ||
        !overloadOptionTypes.Select(static fact => fact.Value!.Value).Order()
            .SequenceEqual(Enum.GetValues<CombatSupportOverloadOptionType>().Order()))
    {
      throw new CombatSupportCatalogIntegrityException("support_overload_option_set_invalid");
    }
    if (normalized
        .Where(static definition => definition.Kind == CombatSupportDefinitionKind.OverloadOption)
        .Select(static definition =>
            (CombatSupportOverloadOptionDefinitionPublication)definition.Payload)
        .Any(static overload =>
            !overload.IsGameLegalReady || overload.LegalBands.Count != 3 ||
            overload.LegalBands.Sum(static band => band.Probability.ToDecimal()) != 1m))
    {
      throw new CombatSupportCatalogIntegrityException("support_overload_legal_set_invalid");
    }

    Definitions = Array.AsReadOnly(normalized);
    CanonicalSha256 = CombatSupportPublicationCanonicalizer
        .ComputeCatalogPublicationSha256(this);
  }

  public CombatSupportCatalogIdentityBinding IdentityBinding { get; }

  public IReadOnlyList<CombatSupportDefinitionPublication> Definitions { get; }

  public Sha256Digest CanonicalSha256 { get; }
}

public sealed record CombatSupportCatalogMemberReceipt(
    int Ordinal,
    CombatSupportDefinitionKind Kind,
    EntityUid DefinitionUid,
    EntityUid DefinitionVersionUid,
    Sha256Digest DefinitionContentSha256,
    bool IsSourceReady,
    bool IsProfileSelectable,
    bool IsGameLegalReady,
    bool HasCompleteCombatSemantics,
    bool IsDuplicatePolicyReady);

public sealed record CombatSupportCatalogImportReceipt(
    ImportReceipt Import,
    EntityUid CombatSupportCatalogSnapshotUid,
    Sha256Digest CatalogManifestSha256,
    IReadOnlyList<CombatSupportCatalogMemberReceipt> Members);

public static class CombatSupportPublicationCanonicalizer
{
  public static Sha256Digest ComputeDefinitionContentSha256(
      CombatSupportDefinitionPublication definition)
  {
    ArgumentNullException.ThrowIfNull(definition);
    using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
    Append(hash, "nll/combat-support-definition/v1");
    Append(hash, CombatSupportPublicationCodes.DefinitionKind(definition.Kind));
    AppendTextFact(hash, definition.DisplayName);
    AppendPayload(hash, definition.Payload);
    Append(hash, CombatSupportPublicationCodes.FactStatus(definition.Contributions.Status));
    Append(hash, definition.Contributions.UnresolvedReasonCode);
    Append(hash, definition.Contributions.Contributions.Count.ToString(CultureInfo.InvariantCulture));
    foreach (var contribution in definition.Contributions.Contributions)
    {
      Append(hash, contribution.Ordinal.ToString(CultureInfo.InvariantCulture));
      Append(hash, contribution.UnlockLevel.ToString(CultureInfo.InvariantCulture));
      AppendFact(hash, contribution.Stat, CombatSupportPublicationCodes.Stat);
      AppendFact(hash, contribution.Unit, CombatSupportPublicationCodes.ValueUnit);
      AppendExact(hash, contribution.ExactValue);
    }

    Append(hash, definition.Contributions.SkillCoordinates.Count.ToString(CultureInfo.InvariantCulture));
    foreach (var coordinate in definition.Contributions.SkillCoordinates)
    {
      Append(hash, coordinate.Ordinal.ToString(CultureInfo.InvariantCulture));
      Append(hash, coordinate.UnlockLevel.ToString(CultureInfo.InvariantCulture));
      Append(hash, coordinate.SkillSlotOrdinal.ToString(CultureInfo.InvariantCulture));
      Append(hash, coordinate.SkillLevel.ToString(CultureInfo.InvariantCulture));
    }

    return Sha256Digest.FromBytes(hash.GetHashAndReset());
  }

  public static Sha256Digest ComputeCatalogPublicationSha256(
      CombatSupportCatalogPublication publication)
  {
    ArgumentNullException.ThrowIfNull(publication);
    using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
    Append(hash, "nll/combat-support-catalog-publication/v1");
    Append(hash, publication.IdentityBinding.EncoderVersion);
    Append(hash, publication.IdentityBinding.KeyCheckSha256.Hex);
    Append(hash, publication.Definitions.Count.ToString(CultureInfo.InvariantCulture));
    foreach (var definition in publication.Definitions)
    {
      Append(hash, CombatSupportPublicationCodes.DefinitionKind(definition.Kind));
      Append(hash, definition.SourceAliasFingerprint.Hex);
      Append(hash, definition.DefinitionContentSha256.Hex);
    }

    return Sha256Digest.FromBytes(hash.GetHashAndReset());
  }

  private static void AppendPayload(IncrementalHash hash, ICombatSupportDefinitionPayload payload)
  {
    switch (payload)
    {
      case CombatSupportEquipmentDefinitionPublication equipment:
        Append(hash, CombatSupportPublicationCodes.EquipmentSlot(equipment.Slot));
        AppendFact(hash, equipment.CombatClass, CombatSupportPublicationCodes.CombatClass);
        AppendFact(hash, equipment.Manufacturer, CombatSupportPublicationCodes.Manufacturer);
        AppendFact(hash, equipment.Tier, static value => value.ToString(CultureInfo.InvariantCulture));
        AppendFact(
            hash,
            equipment.EnhancementGrade,
            static value => value.ToString(CultureInfo.InvariantCulture));
        AppendFact(
            hash,
            equipment.MaximumEnhancementLevel,
            static value => value.ToString(CultureInfo.InvariantCulture));
        AppendFact(hash, equipment.OverloadEligible, static value => value ? "true" : "false");
        Append(hash, equipment.OptionSlots.Count.ToString(CultureInfo.InvariantCulture));
        foreach (var slot in equipment.OptionSlots)
        {
          Append(hash, slot.Ordinal.ToString(CultureInfo.InvariantCulture));
          AppendExact(hash, slot.SuccessRatio);
        }
        break;
      case CombatSupportCubeDefinitionPublication cube:
        AppendFact(hash, cube.Rarity, CombatSupportPublicationCodes.Rarity);
        AppendFact(
            hash,
            cube.ApplicableCombatClass,
            CombatSupportPublicationCodes.CombatClass);
        AppendFact(hash, cube.MaximumLevel, static value => value.ToString(CultureInfo.InvariantCulture));
        AppendLevels(hash, cube.Levels);
        AppendFact(hash, cube.SkillSemantics, static value => value ? "true" : "false");
        break;
      case CombatSupportCollectionDefinitionPublication collection:
        AppendFact(hash, collection.WeaponClass, CombatSupportPublicationCodes.WeaponClass);
        AppendFact(hash, collection.Rarity, CombatSupportPublicationCodes.Rarity);
        AppendFact(
            hash,
            collection.MaximumLevel,
            static value => value.ToString(CultureInfo.InvariantCulture));
        AppendLevels(hash, collection.Levels);
        AppendFact(
            hash,
            collection.SkillSemantics,
            static value => value ? "true" : "false");
        break;
      case CombatSupportFavoriteDefinitionPublication favorite:
        AppendFact(
            hash,
            favorite.MaximumLevel,
            static value => value.ToString(CultureInfo.InvariantCulture));
        AppendFact(hash, favorite.ApplicableCharacterAlias, static value => value.Hex);
        AppendFact(hash, favorite.Rarity, CombatSupportPublicationCodes.Rarity);
        AppendLevels(hash, favorite.Levels);
        AppendFact(hash, favorite.SkillSemantics, static value => value ? "true" : "false");
        break;
      case CombatSupportConsoleDefinitionPublication console:
        Append(hash, CombatSupportPublicationCodes.ConsoleCoordinate(console.Coordinate));
        AppendFact(
            hash,
            console.MaximumLevel,
            static value => value.ToString(CultureInfo.InvariantCulture));
        Append(hash, console.LegalLevels.Count.ToString(CultureInfo.InvariantCulture));
        foreach (var level in console.LegalLevels)
        {
          Append(hash, level.Ordinal.ToString(CultureInfo.InvariantCulture));
          Append(hash, level.Level.ToString(CultureInfo.InvariantCulture));
          Append(hash, level.MinimumSynchroLevel.ToString(CultureInfo.InvariantCulture));
        }
        break;
      case CombatSupportOverloadOptionDefinitionPublication overload:
        AppendFact(hash, overload.OptionType, CombatSupportPublicationCodes.OverloadOptionType);
        AppendFact(hash, overload.Unit, CombatSupportPublicationCodes.ValueUnit);
        AppendExact(hash, overload.KindSelectionProbability);
        Append(hash, overload.LegalBands.Count.ToString(CultureInfo.InvariantCulture));
        foreach (var band in overload.LegalBands)
        {
          Append(hash, band.Ordinal.ToString(CultureInfo.InvariantCulture));
          AppendExact(hash, band.Probability);
          Append(hash, band.OrderedValues.Count.ToString(CultureInfo.InvariantCulture));
          foreach (var value in band.OrderedValues)
          {
            Append(hash, value.SourceAliasFingerprint.Hex);
            Append(hash, value.RollLevel.ToString(CultureInfo.InvariantCulture));
            Append(hash, value.SourceRawValue.ToString(CultureInfo.InvariantCulture));
            Append(hash, value.MagnitudeBasisPoints.ToString(CultureInfo.InvariantCulture));
            AppendExact(hash, value.EngineFraction);
          }
        }

        AppendFact(
            hash,
            overload.DuplicatePolicy,
            CombatSupportPublicationCodes.OverloadDuplicatePolicy);
        break;
      default:
        throw new CombatSupportCatalogIntegrityException("support_payload_invalid");
    }
  }

  private static void AppendLevels(
      IncrementalHash hash,
      IReadOnlyList<CombatSupportLevelCoordinatePublication> levels)
  {
    Append(hash, levels.Count.ToString(CultureInfo.InvariantCulture));
    foreach (var level in levels)
    {
      Append(hash, level.Level.ToString(CultureInfo.InvariantCulture));
      AppendFact(hash, level.Grade, static value => value.ToString(CultureInfo.InvariantCulture));
      AppendFact(hash, level.Capacity, static value => value.ToString(CultureInfo.InvariantCulture));
      AppendFact(
          hash,
          level.MinimumSynchroLevel,
          static value => value.ToString(CultureInfo.InvariantCulture));
    }
  }

  private static void AppendTextFact(IncrementalHash hash, CombatSupportTextFact fact)
  {
    Append(hash, CombatSupportPublicationCodes.FactStatus(fact.Status));
    Append(hash, fact.Value);
    Append(hash, fact.UnresolvedReasonCode);
  }

  private static void AppendFact<T>(
      IncrementalHash hash,
      CombatSupportValueFact<T> fact,
      Func<T, string> formatter)
      where T : struct
  {
    Append(hash, CombatSupportPublicationCodes.FactStatus(fact.Status));
    Append(hash, fact.Value is { } value ? formatter(value) : null);
    Append(hash, fact.UnresolvedReasonCode);
  }

  private static void AppendExact(IncrementalHash hash, CombatSupportExactValue value)
  {
    Append(hash, value.UnscaledValue.ToString(CultureInfo.InvariantCulture));
    Append(hash, value.DecimalScale.ToString(CultureInfo.InvariantCulture));
  }

  private static void Append(IncrementalHash hash, string? value)
  {
    if (value is null)
    {
      Span<byte> nullLength = stackalloc byte[sizeof(int)];
      BinaryPrimitives.WriteInt32BigEndian(nullLength, -1);
      hash.AppendData(nullLength);
      return;
    }

    var bytes = Encoding.UTF8.GetBytes(value);
    Span<byte> length = stackalloc byte[sizeof(int)];
    BinaryPrimitives.WriteInt32BigEndian(length, bytes.Length);
    hash.AppendData(length);
    hash.AppendData(bytes);
  }
}

internal static class CombatSupportLevelValidation
{
  public static IReadOnlyList<CombatSupportLevelCoordinatePublication> Normalize(
      CombatSupportValueFact<int> maximumLevel,
      IEnumerable<CombatSupportLevelCoordinatePublication>? levels,
      bool startsAtZero,
      string errorCode)
  {
    var normalized = (levels ?? []).OrderBy(static item => item.Level).ToArray();
    var first = startsAtZero ? 0 : 1;
    var expectedCount = maximumLevel.Value is { } maximum
        ? checked(maximum + (startsAtZero ? 1 : 0))
        : 0;
    if (normalized.Any(static item => item is null) ||
        !normalized.Select(static item => item.Level)
            .SequenceEqual(Enumerable.Range(first, normalized.Length)) ||
        (maximumLevel.Status == CombatSupportFactStatus.Ready &&
         normalized.Length != expectedCount) ||
        (maximumLevel.Status != CombatSupportFactStatus.Ready && normalized.Length != 0))
    {
      throw new CombatSupportCatalogIntegrityException(errorCode);
    }

    return Array.AsReadOnly(normalized);
  }
}

internal static class CombatSupportFactValidation
{
  public static CombatSupportValueFact<bool> RequireSkillSemantics(
      CombatSupportValueFact<bool>? fact)
  {
    ArgumentNullException.ThrowIfNull(fact);
    if (fact.Status == CombatSupportFactStatus.NotApplicable ||
        (fact.Status == CombatSupportFactStatus.Ready && fact.Value != true))
    {
      throw new CombatSupportCatalogIntegrityException("support_skill_semantics_invalid");
    }

    return fact;
  }

  public static string? ValidateShape(
      CombatSupportFactStatus status,
      bool hasValue,
      string? unresolvedReasonCode)
  {
    var valid = status switch
    {
      CombatSupportFactStatus.Ready => hasValue && unresolvedReasonCode is null,
      CombatSupportFactStatus.Unresolved => !hasValue && unresolvedReasonCode is not null,
      CombatSupportFactStatus.NotApplicable => !hasValue && unresolvedReasonCode is null,
      _ => false
    };
    if (!valid)
    {
      throw new CombatSupportCatalogIntegrityException("support_fact_shape_invalid");
    }

    return unresolvedReasonCode is null
        ? null
        : ControlledCode.Require(unresolvedReasonCode, nameof(unresolvedReasonCode));
  }

  public static void RequireIntegerRange(
      CombatSupportValueFact<int> fact,
      int minimum,
      int maximum,
      string errorCode)
  {
    if (fact.Value is { } value && (value < minimum || value > maximum))
    {
      throw new CombatSupportCatalogIntegrityException(errorCode);
    }
  }

  public static bool AreResolved<T1, T2>(
      CombatSupportValueFact<T1> first,
      CombatSupportValueFact<T2> second)
      where T1 : struct
      where T2 : struct =>
      first.Status != CombatSupportFactStatus.Unresolved &&
      second.Status != CombatSupportFactStatus.Unresolved;

  public static bool AreResolved<T1, T2, T3>(
      CombatSupportValueFact<T1> first,
      CombatSupportValueFact<T2> second,
      CombatSupportValueFact<T3> third)
      where T1 : struct
      where T2 : struct
      where T3 : struct =>
      first.Status != CombatSupportFactStatus.Unresolved &&
      second.Status != CombatSupportFactStatus.Unresolved &&
      third.Status != CombatSupportFactStatus.Unresolved;

  public static bool AreResolved<T1, T2, T3, T4, T5, T6, T7>(
      CombatSupportValueFact<T1> first,
      CombatSupportValueFact<T2> second,
      CombatSupportValueFact<T3> third,
      CombatSupportValueFact<T4> fourth,
      CombatSupportValueFact<T5> fifth,
      CombatSupportValueFact<T6> sixth,
      CombatSupportValueFact<T7> seventh)
      where T1 : struct
      where T2 : struct
      where T3 : struct
      where T4 : struct
      where T5 : struct
      where T6 : struct
      where T7 : struct =>
      first.Status != CombatSupportFactStatus.Unresolved &&
      second.Status != CombatSupportFactStatus.Unresolved &&
      third.Status != CombatSupportFactStatus.Unresolved &&
      fourth.Status != CombatSupportFactStatus.Unresolved &&
      fifth.Status != CombatSupportFactStatus.Unresolved &&
      sixth.Status != CombatSupportFactStatus.Unresolved &&
      seventh.Status != CombatSupportFactStatus.Unresolved;

  public static bool AreResolved<T1, T2, T3, T4, T5, T6>(
      CombatSupportValueFact<T1> first,
      CombatSupportValueFact<T2> second,
      CombatSupportValueFact<T3> third,
      CombatSupportValueFact<T4> fourth,
      CombatSupportValueFact<T5> fifth,
      CombatSupportValueFact<T6> sixth)
      where T1 : struct
      where T2 : struct
      where T3 : struct
      where T4 : struct
      where T5 : struct
      where T6 : struct =>
      first.Status != CombatSupportFactStatus.Unresolved &&
      second.Status != CombatSupportFactStatus.Unresolved &&
      third.Status != CombatSupportFactStatus.Unresolved &&
      fourth.Status != CombatSupportFactStatus.Unresolved &&
      fifth.Status != CombatSupportFactStatus.Unresolved &&
      sixth.Status != CombatSupportFactStatus.Unresolved;
}

internal static class CombatSupportPublicationCodes
{
  public static string DefinitionKind(CombatSupportDefinitionKind value) => value switch
  {
    CombatSupportDefinitionKind.Equipment => "equipment",
    CombatSupportDefinitionKind.Cube => "cube",
    CombatSupportDefinitionKind.Collection => "collection",
    CombatSupportDefinitionKind.Favorite => "favorite",
    CombatSupportDefinitionKind.Console => "console",
    CombatSupportDefinitionKind.OverloadOption => "overload_option",
    _ => throw new CombatSupportCatalogIntegrityException("support_definition_kind_invalid")
  };

  public static string FactStatus(CombatSupportFactStatus value) => value switch
  {
    CombatSupportFactStatus.Ready => "ready",
    CombatSupportFactStatus.Unresolved => "unresolved",
    CombatSupportFactStatus.NotApplicable => "not_applicable",
    _ => throw new CombatSupportCatalogIntegrityException("support_fact_status_invalid")
  };

  public static string EquipmentSlot(CombatSupportEquipmentSlot value) => value switch
  {
    CombatSupportEquipmentSlot.Head => "head",
    CombatSupportEquipmentSlot.Torso => "torso",
    CombatSupportEquipmentSlot.Arms => "arms",
    CombatSupportEquipmentSlot.Legs => "legs",
    _ => throw new CombatSupportCatalogIntegrityException("support_equipment_slot_invalid")
  };

  public static string CombatClass(CombatSupportCombatClass value) => value switch
  {
    CombatSupportCombatClass.Attacker => "attacker",
    CombatSupportCombatClass.Defender => "defender",
    CombatSupportCombatClass.Supporter => "supporter",
    _ => throw new CombatSupportCatalogIntegrityException("support_combat_class_invalid")
  };

  public static string Manufacturer(CombatSupportManufacturer value) => value switch
  {
    CombatSupportManufacturer.Abnormal => "abnormal",
    CombatSupportManufacturer.Elysion => "elysion",
    CombatSupportManufacturer.Missilis => "missilis",
    CombatSupportManufacturer.Pilgrim => "pilgrim",
    CombatSupportManufacturer.Tetra => "tetra",
    _ => throw new CombatSupportCatalogIntegrityException("support_manufacturer_invalid")
  };

  public static string Rarity(CombatSupportRarity value) => value switch
  {
    CombatSupportRarity.R => "r",
    CombatSupportRarity.Sr => "sr",
    CombatSupportRarity.Ssr => "ssr",
    _ => throw new CombatSupportCatalogIntegrityException("support_rarity_invalid")
  };

  public static string WeaponClass(CombatSupportWeaponClass value) => value switch
  {
    CombatSupportWeaponClass.AssaultRifle => "assault_rifle",
    CombatSupportWeaponClass.MachineGun => "machine_gun",
    CombatSupportWeaponClass.RocketLauncher => "rocket_launcher",
    CombatSupportWeaponClass.Shotgun => "shotgun",
    CombatSupportWeaponClass.SniperRifle => "sniper_rifle",
    CombatSupportWeaponClass.SubmachineGun => "submachine_gun",
    _ => throw new CombatSupportCatalogIntegrityException("support_weapon_class_invalid")
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
    _ => throw new CombatSupportCatalogIntegrityException("support_console_coordinate_invalid")
  };

  public static string Stat(CombatSupportStat value) => value switch
  {
    CombatSupportStat.Attack => "attack",
    CombatSupportStat.Defence => "defence",
    CombatSupportStat.Hp => "hp",
    CombatSupportStat.EnergyResistance => "energy_resistance",
    CombatSupportStat.MetalResistance => "metal_resistance",
    CombatSupportStat.BioResistance => "bio_resistance",
    _ => throw new CombatSupportCatalogIntegrityException("support_stat_invalid")
  };

  public static string ValueUnit(CombatSupportValueUnit value) => value switch
  {
    CombatSupportValueUnit.Absolute => "absolute",
    CombatSupportValueUnit.Ratio => "ratio",
    CombatSupportValueUnit.Percent => "percent",
    CombatSupportValueUnit.Count => "count",
    _ => throw new CombatSupportCatalogIntegrityException("support_value_unit_invalid")
  };

  public static string OverloadOptionType(CombatSupportOverloadOptionType value) => value switch
  {
    CombatSupportOverloadOptionType.Attack => "attack",
    CombatSupportOverloadOptionType.Defence => "defence",
    CombatSupportOverloadOptionType.MaximumAmmunition => "maximum_ammunition",
    CombatSupportOverloadOptionType.CriticalRate => "critical_rate",
    CombatSupportOverloadOptionType.CriticalDamage => "critical_damage",
    CombatSupportOverloadOptionType.ChargeDamage => "charge_damage",
    CombatSupportOverloadOptionType.ChargeSpeed => "charge_speed",
    CombatSupportOverloadOptionType.ElementalDamage => "elemental_damage",
    CombatSupportOverloadOptionType.HitRate => "hit_rate",
    _ => throw new CombatSupportCatalogIntegrityException("support_overload_option_type_invalid")
  };

  public static string OverloadDuplicatePolicy(CombatSupportOverloadDuplicatePolicy value) => value switch
  {
    CombatSupportOverloadDuplicatePolicy.AllowSameTypeOnOneEquipment => "allow_same_type",
    CombatSupportOverloadDuplicatePolicy.ForbidSameTypeOnOneEquipment => "forbid_same_type",
    _ => throw new CombatSupportCatalogIntegrityException("support_overload_duplicate_policy_invalid")
  };
}
