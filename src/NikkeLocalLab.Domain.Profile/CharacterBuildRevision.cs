using NikkeLocalLab.Domain.Character;
using NikkeLocalLab.Domain.CombatSupport;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Domain.Profile;

public sealed class CharacterBuildValidation
{
  internal CharacterBuildValidation(
      ProfileValidationResult selection,
      ProfileValidationResult combatSemantics)
  {
    Selection = selection;
    CombatSemantics = combatSemantics;
  }

  /// <summary>Whether the materialized profile selections can be saved and referenced.</summary>
  public ProfileValidationResult Selection { get; }

  /// <summary>Whether every selected item has normalized standalone combat-effect semantics.</summary>
  public ProfileValidationResult CombatSemantics { get; }
}

public sealed class CharacterBuildRevision
{
  private CharacterBuildRevision(
      EntityUid characterBuildRevisionUid,
      EntityUid characterBuildUid,
      EntityUid localAccountUid,
      EntityUid characterUid,
      long revisionNumber,
      ProfileRevisionProvenance provenance,
      CharacterBuildRevisionContent content,
      CharacterBuildValidation validation)
  {
    CharacterBuildRevisionUid = characterBuildRevisionUid;
    CharacterBuildUid = characterBuildUid;
    LocalAccountUid = localAccountUid;
    CharacterUid = characterUid;
    RevisionNumber = revisionNumber;
    Provenance = provenance;
    Content = content;
    Validation = validation;
    ContentSha256 = ProfileCanonicalizer.ComputeContentHash(content);
  }

  public EntityUid CharacterBuildRevisionUid { get; }

  public EntityUid CharacterBuildUid { get; }

  public EntityUid LocalAccountUid { get; }

  public EntityUid CharacterUid { get; }

  public long RevisionNumber { get; }

  public ProfileRevisionProvenance Provenance { get; }

  public CharacterBuildRevisionContent Content { get; }

  public CharacterBuildValidation Validation { get; }

  public ProfileReadiness Readiness => Validation.Selection.Status;

  public ProfileReadiness CombatSemanticsReadiness => Validation.CombatSemantics.Status;

  public Sha256Digest ContentSha256 { get; }

  public static CharacterBuildRevision CreateExplicit(
      EntityUid characterBuildRevisionUid,
      CharacterBuild build,
      long revisionNumber,
      ProfileRevisionProvenance provenance,
      ProfileCatalogEvidence catalogEvidence,
      CharacterDefinitionVersion characterDefinitionVersion,
      ProfileValidationMode validationMode,
      CharacterInvestmentState investment,
      CharacterSkillState skills,
      IEnumerable<CharacterEquipmentInput> equipment,
      CharacterCubeInput cube,
      CharacterCollectibleInput collectible) =>
      CreateCore(
          characterBuildRevisionUid,
          build,
          revisionNumber,
          provenance,
          catalogEvidence,
          characterDefinitionVersion,
          CharacterBuildMaterializationPolicy.ExplicitV1,
          validationMode,
          investment,
          skills,
          equipment,
          cube,
          collectible);

  internal static CharacterBuildRevision CreateCore(
      EntityUid characterBuildRevisionUid,
      CharacterBuild build,
      long revisionNumber,
      ProfileRevisionProvenance provenance,
      ProfileCatalogEvidence catalogEvidence,
      CharacterDefinitionVersion characterDefinitionVersion,
      CharacterBuildMaterializationPolicy materializationPolicy,
      ProfileValidationMode validationMode,
      CharacterInvestmentState investment,
      CharacterSkillState skills,
      IEnumerable<CharacterEquipmentInput> equipment,
      CharacterCubeInput cube,
      CharacterCollectibleInput collectible)
  {
    ArgumentNullException.ThrowIfNull(build);
    ArgumentNullException.ThrowIfNull(catalogEvidence);
    ArgumentNullException.ThrowIfNull(characterDefinitionVersion);
    ArgumentNullException.ThrowIfNull(investment);
    ArgumentNullException.ThrowIfNull(skills);
    ArgumentNullException.ThrowIfNull(equipment);
    ArgumentNullException.ThrowIfNull(cube);
    ArgumentNullException.ThrowIfNull(collectible);
    ProfileGuard.RequireRevision(revisionNumber, provenance);
    ProfileGuard.RequireEnum(materializationPolicy, nameof(materializationPolicy));
    ProfileGuard.RequireEnum(validationMode, nameof(validationMode));

    var equipmentInputs = NormalizeEquipment(equipment);
    catalogEvidence.RequireCharacter(characterDefinitionVersion, nameof(characterDefinitionVersion));
    catalogEvidence.RequireCombatSupport(
        EnumerateDefinitions(equipmentInputs, cube, collectible),
        nameof(equipment));
    var equipmentStates = equipmentInputs.Select(ToState).ToArray();
    var cubeState = ToState(cube);
    var collectibleState = ToState(collectible);
    var content = new CharacterBuildRevisionContent(
        catalogEvidence.DatasetBinding,
        materializationPolicy,
        validationMode,
        CharacterDefinitionReference.From(characterDefinitionVersion),
        investment,
        skills,
        Array.AsReadOnly(equipmentStates),
        cubeState,
        collectibleState);
    var supportDefinitions = EnumerateDefinitions(equipmentInputs, cube, collectible).ToArray();
    var validation = ValidateContent(
        content,
        build,
        characterDefinitionVersion,
        supportDefinitions,
        provenance);

    return new CharacterBuildRevision(
        ProfileGuard.RequireUid(characterBuildRevisionUid, nameof(characterBuildRevisionUid)),
        build.CharacterBuildUid,
        build.LocalAccountUid,
        build.CharacterUid,
        revisionNumber,
        provenance,
        content,
        validation);
  }

  public CharacterBuildValidation Validate(
      CharacterDefinitionVersion characterDefinitionVersion,
      IEnumerable<CombatSupportDefinitionVersion> combatSupportDefinitions)
  {
    var syntheticAccount = new LocalAccount(LocalAccountUid, Provenance.MaterializedAtUtc);
    var build = new CharacterBuild(CharacterBuildUid, syntheticAccount, CharacterUid);
    return ValidateContent(Content, build, characterDefinitionVersion, combatSupportDefinitions, Provenance);
  }

  public CharacterBuildRevisionReference ToReference() =>
      CharacterBuildRevisionReference.Restore(
          CharacterBuildUid,
          CharacterBuildRevisionUid,
          LocalAccountUid,
          CharacterUid,
          Content.DatasetBinding,
          ContentSha256,
          Readiness,
          CombatSemanticsReadiness);

  private static IReadOnlyList<CharacterEquipmentInput> NormalizeEquipment(
      IEnumerable<CharacterEquipmentInput> equipment)
  {
    var items = equipment.ToArray();
    var expected = Enum.GetValues<CombatSupportEquipmentSlot>();
    if (items.Any(static item => item is null) ||
        items.Length != expected.Length ||
        items.GroupBy(static item => item.Slot).Any(static group => group.Count() != 1) ||
        items.GroupBy(static item => item.EquipmentSlotUid).Any(static group => group.Count() != 1))
    {
      throw new ArgumentException(
          "A build must contain four uniquely identified equipment slots, one per fixed coordinate.",
          nameof(equipment));
    }

    return Array.AsReadOnly(expected.Select(slot => items.Single(item => item.Slot == slot)).ToArray());
  }

  private static CharacterEquipmentState ToState(CharacterEquipmentInput input)
  {
    if (input.DefinitionVersion?.Content is not EquipmentDefinitionContent definition)
    {
      var unresolved = input.AttachmentKind == ProfileAttachmentKind.Unresolved;
      return new CharacterEquipmentState(
          input.EquipmentSlotUid,
          input.Slot,
          input.AttachmentKind,
          null,
          unresolved
              ? ProfileFact<int>.Unresolved(input.ReasonCode ?? "equipment_definition_unresolved")
              : ProfileFact<int>.NotApplicable(),
          input.EnhancementLevel,
          input.ManufacturerMatch,
          Array.Empty<CharacterOverloadLine>(),
          input.ReasonCode);
    }

    var lines = input.OverloadLines.Select(line =>
    {
      var option = (OverloadOptionDefinitionContent)line.OptionDefinitionVersion.Content;
      return new CharacterOverloadLine(
          line.LineIndex,
          CombatSupportDefinitionReference.From(line.OptionDefinitionVersion),
          FromCombatSupportFact(option.OptionType),
          FromCombatSupportFact(option.Unit),
          line.ApplicationValue);
    }).ToArray();

    return new CharacterEquipmentState(
        input.EquipmentSlotUid,
        input.Slot,
        ProfileAttachmentKind.Attached,
        CombatSupportDefinitionReference.From(input.DefinitionVersion),
        FromCombatSupportFact(definition.Tier),
        input.EnhancementLevel,
        input.ManufacturerMatch,
        Array.AsReadOnly(lines),
        null);
  }

  private static CharacterCubeState ToState(CharacterCubeInput input) =>
      input.DefinitionVersion is null
          ? new CharacterCubeState(input.AttachmentKind, null, input.Level, input.ReasonCode)
          : new CharacterCubeState(
              ProfileAttachmentKind.Attached,
              CombatSupportDefinitionReference.From(input.DefinitionVersion),
              input.Level,
              null);

  private static CharacterCollectibleState ToState(CharacterCollectibleInput input) =>
      new(
          input.Kind,
          input.DefinitionVersion is null
              ? null
              : CombatSupportDefinitionReference.From(input.DefinitionVersion),
          input.Level,
          input.ReasonCode);

  private static IEnumerable<CombatSupportDefinitionVersion> EnumerateDefinitions(
      IEnumerable<CharacterEquipmentInput> equipment,
      CharacterCubeInput cube,
      CharacterCollectibleInput collectible)
  {
    foreach (var item in equipment)
    {
      if (item.DefinitionVersion is not null)
      {
        yield return item.DefinitionVersion;
      }

      foreach (var line in item.OverloadLines)
      {
        yield return line.OptionDefinitionVersion;
      }
    }

    if (cube.DefinitionVersion is not null)
    {
      yield return cube.DefinitionVersion;
    }

    if (collectible.DefinitionVersion is not null)
    {
      yield return collectible.DefinitionVersion;
    }
  }

  private static CharacterBuildValidation ValidateContent(
      CharacterBuildRevisionContent content,
      CharacterBuild build,
      CharacterDefinitionVersion characterDefinitionVersion,
      IEnumerable<CombatSupportDefinitionVersion> combatSupportDefinitions,
      ProfileRevisionProvenance provenance)
  {
    ArgumentNullException.ThrowIfNull(characterDefinitionVersion);
    ArgumentNullException.ThrowIfNull(combatSupportDefinitions);
    var support = combatSupportDefinitions.ToArray();
    if (support.Any(static item => item is null) ||
        support.GroupBy(static item => item.DefinitionVersionUid).Any(static group =>
            group.Select(static item => item.ContentSha256).Distinct().Count() != 1))
    {
      throw new ArgumentException("Combat-support evidence has an ambiguous version UID.", nameof(combatSupportDefinitions));
    }

    support = support
        .GroupBy(static item => item.DefinitionVersionUid)
        .Select(static group => group.First())
        .ToArray();
    var issues = new List<ProfileValidationIssue>();
    ValidateDefinitionBinding(content, build, characterDefinitionVersion, issues);
    ValidateInvestment(
        content.Investment,
        characterDefinitionVersion.Content.Profile,
        characterDefinitionVersion.Content.Capabilities,
        issues);
    ValidateSkills(content.Skills, characterDefinitionVersion.Content.Capabilities.SkillMaximums, issues);
    ValidateMaterializationProvenance(content.MaterializationPolicy, provenance, issues);
    ValidateCombatMaxPolicy(content, characterDefinitionVersion, support, issues);

    foreach (var equipment in content.Equipment)
    {
      ValidateEquipment(
          equipment,
          characterDefinitionVersion,
          content,
          support,
          issues);
    }

    ValidateCube(content.Cube, characterDefinitionVersion, content, support, issues);
    ValidateCollectible(content.Collectible, characterDefinitionVersion, content, support, issues);

    var semanticIssues = new List<ProfileValidationIssue>(issues);
    AddCombatSemanticsIssues(
        content,
        characterDefinitionVersion.Content.Profile,
        support,
        semanticIssues);
    return new CharacterBuildValidation(
        new ProfileValidationResult(issues),
        new ProfileValidationResult(semanticIssues));
  }

  private static void ValidateDefinitionBinding(
      CharacterBuildRevisionContent content,
      CharacterBuild build,
      CharacterDefinitionVersion version,
      ICollection<ProfileValidationIssue> issues)
  {
    if (!content.CharacterDefinition.Matches(version))
    {
      issues.Add(ProfileGuard.Invalid("character_definition", "definition_reference_mismatch"));
    }

    if (version.CharacterUid != build.CharacterUid)
    {
      issues.Add(ProfileGuard.Invalid("character_definition", "character_identity_mismatch"));
    }

    if (version.DatasetSnapshotUid != content.DatasetBinding.CharacterCatalog.DatasetSnapshotUid)
    {
      issues.Add(ProfileGuard.Invalid("character_definition", "dataset_binding_mismatch"));
    }
  }

  private static void ValidateInvestment(
      CharacterInvestmentState investment,
      CharacterProfile profile,
      CharacterCapabilities capabilities,
      ICollection<ProfileValidationIssue> issues)
  {
    ValidateExplicitCharacterLevel(investment.CharacterLevel, capabilities.MaximumCharacterLevel, issues);
    ValidateBoundedFact(investment.LimitBreak, capabilities.MaximumLimitBreak, 0, false, "limit_break", issues);
    ValidateBoundedFact(investment.CoreLevel, capabilities.MaximumCoreLevel, 0, true, "core_level", issues);
    var bondNotApplicable = profile.Rarity.Status == FactStatus.Ready &&
        profile.Rarity.Value == CharacterRarity.R;
    ValidateBoundedFact(
        investment.BondLevel,
        capabilities.MaximumBondLevel,
        1,
        bondNotApplicable,
        "bond_level",
        issues,
        allowReadyMaximumAsNotApplicable: bondNotApplicable);
  }

  private static void ValidateExplicitCharacterLevel(
      int value,
      NormalizedFact<int> maximum,
      ICollection<ProfileValidationIssue> issues)
  {
    if (maximum.Status == FactStatus.Unresolved)
    {
      issues.Add(ProfileGuard.Unresolved(
          "character_level",
          maximum.ReasonCode ?? "character_level_maximum_unresolved"));
    }
    else if (maximum.Status == FactStatus.NotApplicable)
    {
      issues.Add(ProfileGuard.Invalid("character_level", "character_level_not_applicable"));
    }
    else if (value > maximum.RequireValue())
    {
      issues.Add(ProfileGuard.Invalid("character_level", "above_catalog_maximum"));
    }
  }

  private static void ValidateSkills(
      CharacterSkillState skills,
      SkillMaximums maximums,
      ICollection<ProfileValidationIssue> issues)
  {
    ValidateBoundedFact(skills.Skill1, maximums.Skill1, 1, false, "skill_1", issues);
    ValidateBoundedFact(skills.Skill2, maximums.Skill2, 1, false, "skill_2", issues);
    ValidateBoundedFact(skills.Burst, maximums.Burst, 1, false, "burst", issues);
  }

  private static void ValidateBoundedFact(
      ProfileFact<int> value,
      NormalizedFact<int> maximum,
      int minimum,
      bool optional,
      string fieldCode,
      ICollection<ProfileValidationIssue> issues,
      bool allowReadyMaximumAsNotApplicable = false)
  {
    if (value.Status == ProfileFactStatus.Unresolved)
    {
      issues.Add(ProfileGuard.Unresolved(fieldCode, value.ReasonCode ?? "missing_reason_code"));
      return;
    }

    if (value.Status == ProfileFactStatus.NotApplicable)
    {
      if (!optional ||
          (maximum.Status != FactStatus.NotApplicable &&
           !(allowReadyMaximumAsNotApplicable && maximum.Status == FactStatus.Ready)))
      {
        issues.Add(ProfileGuard.Invalid(fieldCode, "not_applicable_mismatch"));
      }

      return;
    }

    var selected = value.RequireValue();
    if (selected < minimum)
    {
      issues.Add(ProfileGuard.Invalid(fieldCode, "below_legal_minimum"));
    }

    if (maximum.Status == FactStatus.Unresolved)
    {
      issues.Add(ProfileGuard.Unresolved(fieldCode, maximum.ReasonCode ?? "catalog_maximum_unresolved"));
    }
    else if (maximum.Status == FactStatus.NotApplicable)
    {
      issues.Add(ProfileGuard.Invalid(fieldCode, "value_is_not_applicable"));
    }
    else if (selected > maximum.RequireValue())
    {
      issues.Add(ProfileGuard.Invalid(fieldCode, "above_catalog_maximum"));
    }
  }

  private static void ValidateMaterializationProvenance(
      CharacterBuildMaterializationPolicy policy,
      ProfileRevisionProvenance provenance,
      ICollection<ProfileValidationIssue> issues)
  {
    if ((policy == CharacterBuildMaterializationPolicy.CombatMaxV1) !=
        (provenance.Origin == ProfileRevisionOrigin.CombatMaxV1))
    {
      issues.Add(ProfileGuard.Invalid("materialization_policy", "provenance_policy_mismatch"));
    }
  }

  private static void ValidateCombatMaxPolicy(
      CharacterBuildRevisionContent content,
      CharacterDefinitionVersion character,
      IReadOnlyCollection<CombatSupportDefinitionVersion> support,
      ICollection<ProfileValidationIssue> issues)
  {
    if (content.MaterializationPolicy != CharacterBuildMaterializationPolicy.CombatMaxV1)
    {
      return;
    }

    foreach (var state in content.Equipment)
    {
      var field = $"equipment_{ProfileCanonicalCodes.EquipmentSlot(state.Slot)}";
      if (!state.Equipped)
      {
        issues.Add(ProfileGuard.Unresolved(field, "combat_max_tier_ten_definition_not_unique"));
        continue;
      }

      if (state.Tier.Value != CombatMaxV1ProfileResolver.EquipmentTier ||
          state.EnhancementLevel.Value != CombatMaxV1ProfileResolver.EquipmentEnhancementLevel ||
          state.OverloadLines.Count != 0)
      {
        issues.Add(ProfileGuard.Invalid(field, "combat_max_equipment_policy_mismatch"));
      }
    }

    if (content.Cube.Equipped)
    {
      issues.Add(ProfileGuard.Invalid("cube", "combat_max_default_must_be_detached"));
    }

    if (content.Skills.Skill1.Value != CombatMaxV1ProfileResolver.SkillLevel ||
        content.Skills.Skill2.Value != CombatMaxV1ProfileResolver.SkillLevel ||
        content.Skills.Burst.Value != CombatMaxV1ProfileResolver.SkillLevel)
    {
      issues.Add(ProfileGuard.Unresolved("skills", "combat_max_skill_level_unresolved"));
    }

    RequireMaximumMaterialized(
        content.Investment.LimitBreak,
        character.Content.Capabilities.MaximumLimitBreak,
        "limit_break",
        issues);
    RequireMaximumMaterialized(
        content.Investment.CoreLevel,
        character.Content.Capabilities.MaximumCoreLevel,
        "core_level",
        issues);
    RequireMaximumMaterialized(
        content.Investment.BondLevel,
        character.Content.Capabilities.MaximumBondLevel,
        "bond_level",
        issues);

    if (content.Collectible.Kind is CharacterCollectibleSelectionKind.GenericCollection or
        CharacterCollectibleSelectionKind.Favorite &&
        content.Collectible.Definition is { } reference &&
        FindDefinition(reference, support)?.Content is ICombatSupportDefinitionContent selected)
    {
      var maximum = selected switch
      {
        GenericCollectionDefinitionContent collection => collection.MaximumLevel,
        FavoriteDefinitionContent favorite => favorite.MaximumLevel,
        _ => null
      };
      if (maximum?.Status == CombatSupportFactStatus.Ready &&
          content.Collectible.Level.Value != maximum.RequireValue())
      {
        issues.Add(ProfileGuard.Invalid("collectible", "combat_max_level_not_materialized"));
      }
    }
    else if (content.Collectible.Kind == CharacterCollectibleSelectionKind.Detached)
    {
      issues.Add(ProfileGuard.Unresolved("collectible", "combat_max_collectible_unresolved"));
    }
  }

  private static void RequireMaximumMaterialized(
      ProfileFact<int> selected,
      NormalizedFact<int> maximum,
      string fieldCode,
      ICollection<ProfileValidationIssue> issues)
  {
    if (maximum.Status == FactStatus.Ready && selected.Value != maximum.RequireValue())
    {
      issues.Add(ProfileGuard.Invalid(fieldCode, "combat_max_value_not_materialized"));
    }
    else if (maximum.Status == FactStatus.NotApplicable && selected.Status != ProfileFactStatus.NotApplicable)
    {
      issues.Add(ProfileGuard.Invalid(fieldCode, "combat_max_not_applicable_mismatch"));
    }
  }

  private static void ValidateEquipment(
      CharacterEquipmentState state,
      CharacterDefinitionVersion character,
      CharacterBuildRevisionContent content,
      IReadOnlyCollection<CombatSupportDefinitionVersion> support,
      ICollection<ProfileValidationIssue> issues)
  {
    var slotCode = ProfileCanonicalCodes.EquipmentSlot(state.Slot);
    var prefix = $"equipment_{slotCode}";
    if (state.AttachmentKind == ProfileAttachmentKind.Unresolved)
    {
      issues.Add(ProfileGuard.Unresolved(prefix, state.ReasonCode ?? "equipment_definition_unresolved"));
      return;
    }

    if (!state.Equipped)
    {
      if (state.Tier.Status != ProfileFactStatus.NotApplicable ||
          state.EnhancementLevel.Status != ProfileFactStatus.NotApplicable ||
          state.ManufacturerMatch.Status != ProfileFactStatus.NotApplicable ||
          state.OverloadLines.Count != 0)
      {
        issues.Add(ProfileGuard.Invalid(prefix, "detached_slot_has_equipped_state"));
      }

      return;
    }

    var version = FindDefinition(state.Definition!, support);
    if (version?.Content is not EquipmentDefinitionContent definition)
    {
      issues.Add(ProfileGuard.Invalid($"{prefix}_definition", "definition_reference_mismatch"));
      return;
    }

    if (version.DatasetSnapshotUid != content.DatasetBinding.CombatSupportCatalog.DatasetSnapshotUid)
    {
      issues.Add(ProfileGuard.Invalid($"{prefix}_definition", "dataset_binding_mismatch"));
    }

    if (definition.Slot != state.Slot)
    {
      issues.Add(ProfileGuard.Invalid($"{prefix}_definition", "equipment_slot_mismatch"));
    }

    ValidateEquipmentRole(definition, character.Content.Profile, prefix, issues);
    ProfileGuard.AddRequiredFactIssue(state.Tier, $"{prefix}_tier", issues);
    var tier = state.Tier.Value;
    if (state.Tier.Status == ProfileFactStatus.Ready && tier is not (9 or 10))
    {
      issues.Add(ProfileGuard.Invalid($"{prefix}_tier", "unsupported_equipment_tier"));
    }

    ProfileGuard.AddRequiredFactIssue(state.EnhancementLevel, $"{prefix}_enhancement", issues);
    if (state.EnhancementLevel.Value is { } enhancement)
    {
      if (enhancement is < 0 or > 5)
      {
        issues.Add(ProfileGuard.Invalid($"{prefix}_enhancement", "enhancement_out_of_range"));
      }
      else if (definition.MaximumEnhancementLevel.Status == CombatSupportFactStatus.Ready &&
               enhancement > definition.MaximumEnhancementLevel.RequireValue())
      {
        issues.Add(ProfileGuard.Invalid($"{prefix}_enhancement", "above_catalog_maximum"));
      }
    }

    if (definition.MaximumEnhancementLevel.Status == CombatSupportFactStatus.Unresolved)
    {
      issues.Add(ProfileGuard.Unresolved(
          $"{prefix}_enhancement",
          definition.MaximumEnhancementLevel.ReasonCode ?? "equipment_maximum_unresolved"));
    }
    else if (definition.MaximumEnhancementLevel.Status == CombatSupportFactStatus.NotApplicable)
    {
      issues.Add(ProfileGuard.Invalid($"{prefix}_enhancement", "equipment_maximum_not_applicable"));
    }

    if (state.ManufacturerMatch.Status != ProfileFactStatus.NotApplicable)
    {
      ProfileGuard.AddRequiredFactIssue(
          state.ManufacturerMatch,
          $"{prefix}_manufacturer_match",
          issues);
    }
    ValidateEquipmentManufacturer(
        definition.Manufacturer,
        character.Content.Profile.Manufacturer,
        state.ManufacturerMatch,
        prefix,
        issues);

    if (state.OverloadLines.Count != 0 && definition.OverloadEligible.Status == CombatSupportFactStatus.Unresolved)
    {
      issues.Add(ProfileGuard.Unresolved(
          $"{prefix}_overload",
          definition.OverloadEligible.ReasonCode ?? "overload_applicability_unresolved"));
      return;
    }

    if (state.OverloadLines.Count != 0 &&
        (tier != 10 || definition.OverloadEligible.Status != CombatSupportFactStatus.Ready ||
         definition.OverloadEligible.Value != true))
    {
      issues.Add(ProfileGuard.Invalid($"{prefix}_overload", "overload_not_applicable"));
      return;
    }

    ValidateOverloadLines(state, content, support, prefix, issues);
  }

  private static void ValidateEquipmentRole(
      EquipmentDefinitionContent equipment,
      CharacterProfile profile,
      string prefix,
      ICollection<ProfileValidationIssue> issues)
  {
    if (equipment.CombatRole.Status != CombatSupportFactStatus.Ready ||
        profile.CombatRole.Status != FactStatus.Ready)
    {
      issues.Add(ProfileGuard.Unresolved($"{prefix}_role", "combat_role_unresolved"));
      return;
    }

    var expected = profile.CombatRole.RequireValue() switch
    {
      CombatRole.Attacker => CombatSupportCombatRole.Attacker,
      CombatRole.Defender => CombatSupportCombatRole.Defender,
      CombatRole.Supporter => CombatSupportCombatRole.Supporter,
      _ => throw new ArgumentOutOfRangeException(nameof(profile))
    };
    if (equipment.CombatRole.RequireValue() != expected)
    {
      issues.Add(ProfileGuard.Invalid($"{prefix}_role", "combat_role_mismatch"));
    }
  }

  private static void ValidateEquipmentManufacturer(
      CombatSupportFact<CombatSupportManufacturer> equipmentManufacturer,
      NormalizedFact<Manufacturer> characterManufacturer,
      ProfileFact<bool> manufacturerMatch,
      string prefix,
      ICollection<ProfileValidationIssue> issues)
  {
    var field = $"{prefix}_manufacturer_match";
    if (equipmentManufacturer.Status == CombatSupportFactStatus.NotApplicable)
    {
      return;
    }

    if (equipmentManufacturer.Status == CombatSupportFactStatus.Unresolved)
    {
      issues.Add(ProfileGuard.Unresolved(
          field,
          equipmentManufacturer.ReasonCode ?? "equipment_manufacturer_unresolved"));
      return;
    }

    if (characterManufacturer.Status == FactStatus.Unresolved)
    {
      issues.Add(ProfileGuard.Unresolved(
          field,
          characterManufacturer.ReasonCode ?? "character_manufacturer_unresolved"));
      return;
    }

    if (equipmentManufacturer.Status != CombatSupportFactStatus.Ready ||
        characterManufacturer.Status != FactStatus.Ready)
    {
      issues.Add(ProfileGuard.Invalid(field, "manufacturer_status_invalid"));
      return;
    }

    if (manufacturerMatch.Status != ProfileFactStatus.Ready)
    {
      return;
    }

    var expected = characterManufacturer.RequireValue() switch
    {
      Manufacturer.Elysion => CombatSupportManufacturer.Elysion,
      Manufacturer.Missilis => CombatSupportManufacturer.Missilis,
      Manufacturer.Tetra => CombatSupportManufacturer.Tetra,
      Manufacturer.Pilgrim => CombatSupportManufacturer.Pilgrim,
      Manufacturer.Abnormal => CombatSupportManufacturer.Abnormal,
      _ => throw new ArgumentOutOfRangeException(nameof(characterManufacturer))
    };
    if (manufacturerMatch.RequireValue() !=
        (equipmentManufacturer.RequireValue() == expected))
    {
      issues.Add(ProfileGuard.Invalid(field, "manufacturer_match_mismatch"));
    }
  }

  private static void ValidateOverloadLines(
      CharacterEquipmentState equipment,
      CharacterBuildRevisionContent content,
      IReadOnlyCollection<CombatSupportDefinitionVersion> support,
      string prefix,
      ICollection<ProfileValidationIssue> issues)
  {
    var resolvedTypes = new List<(CombatSupportOverloadOptionType Type, OverloadOptionDefinitionContent Definition)>();
    foreach (var line in equipment.OverloadLines)
    {
      var linePrefix = $"{prefix}_overload_{line.LineIndex}";
      var version = FindDefinition(line.OptionDefinition, support);
      if (version?.Content is not OverloadOptionDefinitionContent definition)
      {
        issues.Add(ProfileGuard.Invalid(linePrefix, "definition_reference_mismatch"));
        continue;
      }

      if (version.DatasetSnapshotUid != content.DatasetBinding.CombatSupportCatalog.DatasetSnapshotUid)
      {
        issues.Add(ProfileGuard.Invalid(linePrefix, "dataset_binding_mismatch"));
      }

      ProfileGuard.AddRequiredFactIssue(line.OptionType, $"{linePrefix}_type", issues);
      ProfileGuard.AddRequiredFactIssue(line.Unit, $"{linePrefix}_unit", issues);
      if (definition.OptionType.Status != CombatSupportFactStatus.Ready ||
          definition.Unit.Status != CombatSupportFactStatus.Ready)
      {
        issues.Add(ProfileGuard.Unresolved(linePrefix, "overload_semantics_unresolved"));
        continue;
      }

      var optionType = definition.OptionType.RequireValue();
      if (line.OptionType.Value != optionType || line.Unit.Value != definition.Unit.RequireValue())
      {
        issues.Add(ProfileGuard.Invalid(linePrefix, "overload_semantics_mismatch"));
      }

      resolvedTypes.Add((optionType, definition));
      if (content.ValidationMode == ProfileValidationMode.GameLegal &&
          !definition.LegalBands.SelectMany(static band => band.OrderedValues)
              .Any(value => value.EngineFraction == line.ApplicationValue))
      {
        issues.Add(ProfileGuard.Invalid($"{linePrefix}_value", "value_not_in_discrete_legal_set"));
      }
    }

    if (content.ValidationMode != ProfileValidationMode.GameLegal)
    {
      return;
    }

    foreach (var duplicate in resolvedTypes.GroupBy(static item => item.Type).Where(static group => group.Count() > 1))
    {
      if (duplicate.Any(static item =>
              item.Definition.DuplicatePolicy.Status == CombatSupportFactStatus.Ready &&
              item.Definition.DuplicatePolicy.Value ==
              CombatSupportOverloadDuplicatePolicy.ForbidSameTypeOnOneEquipment))
      {
        issues.Add(ProfileGuard.Invalid($"{prefix}_overload", "duplicate_option_type_forbidden"));
      }
    }
  }

  private static void ValidateCube(
      CharacterCubeState cube,
      CharacterDefinitionVersion character,
      CharacterBuildRevisionContent content,
      IReadOnlyCollection<CombatSupportDefinitionVersion> support,
      ICollection<ProfileValidationIssue> issues)
  {
    if (cube.AttachmentKind == ProfileAttachmentKind.Unresolved)
    {
      issues.Add(ProfileGuard.Unresolved("cube", cube.ReasonCode ?? "cube_definition_unresolved"));
      return;
    }

    if (!cube.Equipped)
    {
      if (cube.Level.Status != ProfileFactStatus.NotApplicable)
      {
        issues.Add(ProfileGuard.Invalid("cube", "detached_cube_has_level"));
      }

      return;
    }

    var version = FindDefinition(cube.Definition!, support);
    if (version?.Content is not HarmonyCubeDefinitionContent definition)
    {
      issues.Add(ProfileGuard.Invalid("cube_definition", "definition_reference_mismatch"));
      return;
    }

    if (version.DatasetSnapshotUid != content.DatasetBinding.CombatSupportCatalog.DatasetSnapshotUid)
    {
      issues.Add(ProfileGuard.Invalid("cube_definition", "dataset_binding_mismatch"));
    }

    ValidateLevel(cube.Level, definition.MaximumLevel, definition.Levels, 1, "cube_level", issues);
    ValidateBoundedFact(
        cube.Level,
        character.Content.Capabilities.MaximumCubeLevel,
        1,
        true,
        "cube_level",
        issues);
    if (definition.ApplicableCombatRole.Status == CombatSupportFactStatus.Unresolved)
    {
      issues.Add(ProfileGuard.Unresolved(
          "cube_definition",
          definition.ApplicableCombatRole.ReasonCode ?? "cube_applicability_unresolved"));
    }
    else if (definition.ApplicableCombatRole.Status == CombatSupportFactStatus.Ready &&
             character.Content.Profile.CombatRole.Status != FactStatus.Ready)
    {
      issues.Add(ProfileGuard.Unresolved(
          "cube_definition",
          character.Content.Profile.CombatRole.ReasonCode ?? "character_combat_role_unresolved"));
    }
    else if (definition.ApplicableCombatRole.Status == CombatSupportFactStatus.Ready)
    {
      var role = character.Content.Profile.CombatRole.RequireValue() switch
      {
        CombatRole.Attacker => CombatSupportCombatRole.Attacker,
        CombatRole.Defender => CombatSupportCombatRole.Defender,
        CombatRole.Supporter => CombatSupportCombatRole.Supporter,
        _ => throw new ArgumentOutOfRangeException(nameof(character))
      };
      if (definition.ApplicableCombatRole.RequireValue() != role)
      {
        issues.Add(ProfileGuard.Invalid("cube_definition", "combat_role_mismatch"));
      }
    }
  }

  private static void ValidateCollectible(
      CharacterCollectibleState collectible,
      CharacterDefinitionVersion character,
      CharacterBuildRevisionContent content,
      IReadOnlyCollection<CombatSupportDefinitionVersion> support,
      ICollection<ProfileValidationIssue> issues)
  {
    if (collectible.Kind == CharacterCollectibleSelectionKind.Unresolved)
    {
      issues.Add(ProfileGuard.Unresolved(
          "collectible",
          collectible.ReasonCode ?? "collectible_selection_unresolved"));
      return;
    }

    if (collectible.Kind == CharacterCollectibleSelectionKind.Detached)
    {
      return;
    }

    var capabilities = character.Content.Capabilities;
    if (collectible.Kind == CharacterCollectibleSelectionKind.NotApplicable)
    {
      if (capabilities.MaximumCollectionLevel.Status != FactStatus.NotApplicable ||
          capabilities.MaximumFavoriteLevel.Status != FactStatus.NotApplicable)
      {
        issues.Add(ProfileGuard.Invalid("collectible", "collectible_is_applicable"));
      }

      return;
    }

    var version = FindDefinition(collectible.Definition!, support);
    if (version is null)
    {
      issues.Add(ProfileGuard.Invalid("collectible_definition", "definition_reference_mismatch"));
      return;
    }

    if (version.DatasetSnapshotUid != content.DatasetBinding.CombatSupportCatalog.DatasetSnapshotUid)
    {
      issues.Add(ProfileGuard.Invalid("collectible_definition", "dataset_binding_mismatch"));
    }

    if (collectible.Kind == CharacterCollectibleSelectionKind.GenericCollection &&
        version.Content is GenericCollectionDefinitionContent collection)
    {
      ValidateLevel(
          collectible.Level,
          collection.MaximumLevel,
          collection.Levels,
          0,
          "collection_level",
          issues);
      ValidateBoundedFact(
          collectible.Level,
          capabilities.MaximumCollectionLevel,
          0,
          true,
          "collection_level",
          issues);
      ValidateCollectionWeapon(collection, character.Content.Profile, issues);
    }
    else if (collectible.Kind == CharacterCollectibleSelectionKind.Favorite &&
             version.Content is FavoriteDefinitionContent favorite)
    {
      ValidateLevel(
          collectible.Level,
          favorite.MaximumLevel,
          favorite.Levels,
          0,
          "favorite_level",
          issues);
      ValidateBoundedFact(
          collectible.Level,
          capabilities.MaximumFavoriteLevel,
          0,
          true,
          "favorite_level",
          issues);
      if (favorite.ApplicableCharacterUid.Status != CombatSupportFactStatus.Ready)
      {
        issues.Add(ProfileGuard.Unresolved("favorite_definition", "character_applicability_unresolved"));
      }
      else if (favorite.ApplicableCharacterUid.RequireValue() != character.CharacterUid)
      {
        issues.Add(ProfileGuard.Invalid("favorite_definition", "character_applicability_mismatch"));
      }
    }
    else
    {
      issues.Add(ProfileGuard.Invalid("collectible_definition", "definition_kind_mismatch"));
    }
  }

  private static void ValidateCollectionWeapon(
      GenericCollectionDefinitionContent collection,
      CharacterProfile profile,
      ICollection<ProfileValidationIssue> issues)
  {
    if (collection.ApplicableWeaponClass.Status != CombatSupportFactStatus.Ready ||
        profile.WeaponClass.Status != FactStatus.Ready)
    {
      issues.Add(ProfileGuard.Unresolved("collection_definition", "weapon_applicability_unresolved"));
      return;
    }

    var expected = profile.WeaponClass.RequireValue() switch
    {
      WeaponClass.AssaultRifle => CombatSupportWeaponClass.AssaultRifle,
      WeaponClass.RocketLauncher => CombatSupportWeaponClass.RocketLauncher,
      WeaponClass.SniperRifle => CombatSupportWeaponClass.SniperRifle,
      WeaponClass.MachineGun => CombatSupportWeaponClass.MachineGun,
      WeaponClass.Shotgun => CombatSupportWeaponClass.Shotgun,
      WeaponClass.SubmachineGun => CombatSupportWeaponClass.SubmachineGun,
      _ => throw new ArgumentOutOfRangeException(nameof(profile))
    };
    if (collection.ApplicableWeaponClass.RequireValue() != expected)
    {
      issues.Add(ProfileGuard.Invalid("collection_definition", "weapon_applicability_mismatch"));
    }
  }

  private static void ValidateLevel(
      ProfileFact<int> selected,
      CombatSupportFact<int> maximum,
      IReadOnlyCollection<CombatSupportLevelCoordinate> coordinates,
      int minimum,
      string fieldCode,
      ICollection<ProfileValidationIssue> issues)
  {
    ProfileGuard.AddRequiredFactIssue(selected, fieldCode, issues);
    if (selected.Status != ProfileFactStatus.Ready)
    {
      return;
    }

    var value = selected.RequireValue();
    if (value < minimum)
    {
      issues.Add(ProfileGuard.Invalid(fieldCode, "below_legal_minimum"));
    }

    if (maximum.Status != CombatSupportFactStatus.Ready)
    {
      issues.Add(ProfileGuard.Unresolved(fieldCode, "catalog_maximum_unresolved"));
    }
    else if (value > maximum.RequireValue() || coordinates.All(item => item.Level != value))
    {
      issues.Add(ProfileGuard.Invalid(fieldCode, "level_not_in_catalog"));
    }
  }

  private static void AddCombatSemanticsIssues(
      CharacterBuildRevisionContent content,
      CharacterProfile characterProfile,
      IReadOnlyCollection<CombatSupportDefinitionVersion> support,
      ICollection<ProfileValidationIssue> issues)
  {
    AddCharacterProfileSemanticsIssues(characterProfile, issues);

    foreach (var equipment in content.Equipment.Where(static item => item.Equipped))
    {
      if (equipment.Definition is { } equipmentReference &&
          FindDefinition(equipmentReference, support)?.Content is EquipmentDefinitionContent definition &&
          !definition.HasCompleteCombatSemantics)
      {
        issues.Add(ProfileGuard.Unresolved(
            $"equipment_{ProfileCanonicalCodes.EquipmentSlot(equipment.Slot)}_combat_semantics",
            "equipment_combat_semantics_unresolved"));
      }
    }

    if (content.Cube.Definition is { } cubeReference &&
        FindDefinition(cubeReference, support)?.Content is HarmonyCubeDefinitionContent cube &&
        !cube.HasCompleteCombatSemantics)
    {
      issues.Add(ProfileGuard.Unresolved("cube_combat_semantics", "skill_definition_catalog_not_imported"));
    }

    if (content.Collectible.Definition is { } collectibleReference &&
        FindDefinition(collectibleReference, support)?.Content is
            GenericCollectionDefinitionContent or FavoriteDefinitionContent and { HasCompleteCombatSemantics: false })
    {
      issues.Add(ProfileGuard.Unresolved("collectible_combat_semantics", "skill_definition_catalog_not_imported"));
    }
  }

  private static void AddCharacterProfileSemanticsIssues(
      CharacterProfile profile,
      ICollection<ProfileValidationIssue> issues)
  {
    AddRequiredCharacterProfileFact(profile.Rarity, "rarity", issues);
    AddRequiredCharacterProfileFact(profile.CombatRole, "combat_role", issues);
    AddRequiredCharacterProfileFact(profile.WeaponClass, "weapon_class", issues);
    AddRequiredCharacterProfileFact(profile.Element, "element", issues);
    AddRequiredCharacterProfileFact(profile.Manufacturer, "manufacturer", issues);
  }

  private static void AddRequiredCharacterProfileFact<T>(
      NormalizedFact<T> fact,
      string fieldCode,
      ICollection<ProfileValidationIssue> issues)
      where T : struct, Enum
  {
    var semanticField = $"character_profile_{fieldCode}_combat_semantics";
    if (fact.Status == FactStatus.Unresolved)
    {
      issues.Add(ProfileGuard.Unresolved(
          semanticField,
          fact.ReasonCode ?? $"character_{fieldCode}_unresolved"));
    }
    else if (fact.Status == FactStatus.NotApplicable)
    {
      issues.Add(ProfileGuard.Invalid(semanticField, "required_character_profile_fact_not_applicable"));
    }
    else if (!Enum.IsDefined(fact.RequireValue()))
    {
      issues.Add(ProfileGuard.Invalid(semanticField, "character_profile_enum_unknown"));
    }
  }

  private static CombatSupportDefinitionVersion? FindDefinition(
      CombatSupportDefinitionReference reference,
      IEnumerable<CombatSupportDefinitionVersion> definitions) =>
      definitions.SingleOrDefault(reference.Matches);

  private static ProfileFact<T> FromCombatSupportFact<T>(CombatSupportFact<T> fact)
      where T : struct => fact.Status switch
      {
        CombatSupportFactStatus.Ready => ProfileFact<T>.Ready(fact.RequireValue()),
        CombatSupportFactStatus.Unresolved => ProfileFact<T>.Unresolved(
            fact.ReasonCode ?? "combat_support_fact_unresolved"),
        CombatSupportFactStatus.NotApplicable => ProfileFact<T>.NotApplicable(),
        _ => throw new ArgumentOutOfRangeException(nameof(fact))
      };
}
