namespace NikkeLocalLab.Domain.Character;

public sealed class CombatMaxV1Resolver
{
  public const string PolicyId = "combat-max/v1";
  public const int DefaultEquipmentTier = 10;
  public const int DefaultEquipmentEnhancementLevel = 5;
  public const int DefaultSkillLevel = 10;

  public CombatMaxResolution Resolve(CharacterDefinitionVersion definition, int explicitCharacterLevel)
  {
    ArgumentNullException.ThrowIfNull(definition);
    if (explicitCharacterLevel <= 0)
    {
      throw new ArgumentOutOfRangeException(
          nameof(explicitCharacterLevel),
          "An explicit character level must be positive.");
    }

    var issues = new List<ResolutionIssue>();
    AddProfileIssues(definition.Content.Profile, issues);

    var capabilities = definition.Content.Capabilities;
    ValidateExplicitLevel(capabilities.MaximumCharacterLevel, explicitCharacterLevel, issues);
    AddRequiredMaximumIssue(capabilities.MaximumLimitBreak, "limit_break", issues);
    AddOptionalMaximumIssue(capabilities.MaximumCoreLevel, "core_level", issues);
    AddRequiredMaximumIssue(capabilities.MaximumBondLevel, "bond_level", issues);

    var equipment = capabilities.Equipment
        .Select(capability => ResolveEquipment(capability, issues))
        .ToArray();
    var skills = new CombatSkillSeed(
        ResolveFixedLevel(capabilities.SkillMaximums.Skill1, "skill_1", issues),
        ResolveFixedLevel(capabilities.SkillMaximums.Skill2, "skill_2", issues),
        ResolveFixedLevel(capabilities.SkillMaximums.Burst, "burst", issues));

    AddOptionalMaximumIssue(capabilities.MaximumCollectionLevel, "collection_level", issues);
    AddOptionalMaximumIssue(capabilities.MaximumFavoriteLevel, "favorite_level", issues);

    var seed = new CombatMaxBuildSeed(
        definition.DatasetSnapshotUid,
        definition.CharacterUid,
        definition.DefinitionVersionUid,
        definition.ContentSha256,
        explicitCharacterLevel,
        capabilities.MaximumLimitBreak,
        capabilities.MaximumCoreLevel,
        capabilities.MaximumBondLevel,
        Array.AsReadOnly(equipment),
        skills,
        capabilities.MaximumCollectionLevel,
        capabilities.MaximumFavoriteLevel);

    return new CombatMaxResolution(seed, Array.AsReadOnly(issues.ToArray()));
  }

  private static void AddProfileIssues(CharacterProfile profile, ICollection<ResolutionIssue> issues)
  {
    foreach (var field in profile.EnumerateReadiness())
    {
      if (field.Status == FactStatus.Unresolved)
      {
        issues.Add(Unresolved(field.Name, field.ReasonCode));
      }
    }
  }

  private static void ValidateExplicitLevel(
      NormalizedFact<int> maximum,
      int explicitLevel,
      ICollection<ResolutionIssue> issues)
  {
    if (maximum.Status == FactStatus.Unresolved)
    {
      issues.Add(Unresolved("character_level", maximum.ReasonCode));
      return;
    }

    if (maximum.Status == FactStatus.NotApplicable)
    {
      issues.Add(Invalid("character_level", "maximum_not_applicable"));
      return;
    }

    if (explicitLevel > maximum.RequireValue())
    {
      issues.Add(Invalid("character_level", "above_snapshot_maximum"));
    }
  }

  private static CombatEquipmentSeed ResolveEquipment(
      EquipmentSlotCapability capability,
      ICollection<ResolutionIssue> issues)
  {
    var slotCode = EquipmentSlotFieldCode(capability.Slot);
    AddRequiredMaximumIssue(capability.EquipmentDefinitionUid, $"equipment_{slotCode}_definition", issues);
    var tier = ResolveFixedValue(
        capability.MaximumTier,
        DefaultEquipmentTier,
        $"equipment_{slotCode}_tier",
        "tier_ten_unsupported",
        issues);
    var enhancement = ResolveFixedValue(
        capability.MaximumTierTenEnhancementLevel,
        DefaultEquipmentEnhancementLevel,
        $"equipment_{slotCode}_enhancement",
        "enhancement_five_unsupported",
        issues);

    if (capability.ManufacturerMatch.Status == FactStatus.Unresolved)
    {
      issues.Add(Unresolved($"equipment_{slotCode}_manufacturer_match", capability.ManufacturerMatch.ReasonCode));
    }

    return new CombatEquipmentSeed(
        capability.Slot,
        capability.EquipmentDefinitionUid,
        tier,
        enhancement,
        capability.ManufacturerMatch);
  }

  private static NormalizedFact<int> ResolveFixedLevel(
      NormalizedFact<int> maximum,
      string fieldCode,
      ICollection<ResolutionIssue> issues) =>
      ResolveFixedValue(maximum, DefaultSkillLevel, fieldCode, "level_ten_unsupported", issues);

  private static NormalizedFact<int> ResolveFixedValue(
      NormalizedFact<int> maximum,
      int requested,
      string fieldCode,
      string unsupportedReason,
      ICollection<ResolutionIssue> issues)
  {
    if (maximum.Status == FactStatus.Unresolved)
    {
      issues.Add(Unresolved(fieldCode, maximum.ReasonCode));
      return NormalizedFact<int>.Unresolved(maximum.ReasonCode!);
    }

    if (maximum.Status == FactStatus.NotApplicable)
    {
      issues.Add(Invalid(fieldCode, "maximum_not_applicable"));
      return NormalizedFact<int>.NotApplicable();
    }

    if (maximum.RequireValue() < requested)
    {
      issues.Add(Invalid(fieldCode, unsupportedReason));
      return NormalizedFact<int>.Unresolved(unsupportedReason);
    }

    return NormalizedFact<int>.Ready(requested);
  }

  private static void AddRequiredMaximumIssue<T>(
      NormalizedFact<T> maximum,
      string fieldCode,
      ICollection<ResolutionIssue> issues)
      where T : struct
  {
    if (maximum.Status == FactStatus.Unresolved)
    {
      issues.Add(Unresolved(fieldCode, maximum.ReasonCode));
    }
    else if (maximum.Status == FactStatus.NotApplicable)
    {
      issues.Add(Invalid(fieldCode, "maximum_not_applicable"));
    }
  }

  private static void AddOptionalMaximumIssue(
      NormalizedFact<int> maximum,
      string fieldCode,
      ICollection<ResolutionIssue> issues)
  {
    if (maximum.Status == FactStatus.Unresolved)
    {
      issues.Add(Unresolved(fieldCode, maximum.ReasonCode));
    }
  }

  private static ResolutionIssue Unresolved(string fieldCode, string? reasonCode) =>
      new(ResolutionIssueKind.Unresolved, fieldCode, reasonCode ?? "missing_reason_code");

  private static ResolutionIssue Invalid(string fieldCode, string reasonCode) =>
      new(ResolutionIssueKind.Invalid, fieldCode, reasonCode);

  private static string EquipmentSlotFieldCode(EquipmentSlot slot) => slot switch
  {
    EquipmentSlot.Head => "head",
    EquipmentSlot.Torso => "torso",
    EquipmentSlot.Arms => "arms",
    EquipmentSlot.Legs => "legs",
    _ => throw new ArgumentOutOfRangeException(nameof(slot)),
  };
}
