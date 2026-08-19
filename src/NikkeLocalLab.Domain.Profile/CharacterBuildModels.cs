using NikkeLocalLab.Domain.Character;
using NikkeLocalLab.Domain.CombatSupport;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Domain.Profile;

public enum CharacterBuildMaterializationPolicy
{
  ExplicitV1,
  CombatMaxV1
}

public enum ProfileAttachmentKind
{
  Attached,
  Detached,
  Unresolved
}

public sealed class CharacterBuild
{
  public CharacterBuild(
      EntityUid characterBuildUid,
      LocalAccount account,
      EntityUid characterUid)
  {
    ArgumentNullException.ThrowIfNull(account);
    CharacterBuildUid = ProfileGuard.RequireUid(characterBuildUid, nameof(characterBuildUid));
    LocalAccountUid = account.LocalAccountUid;
    CharacterUid = ProfileGuard.RequireUid(characterUid, nameof(characterUid));
  }

  public EntityUid CharacterBuildUid { get; }

  public EntityUid LocalAccountUid { get; }

  public EntityUid CharacterUid { get; }
}

public sealed class CharacterInvestmentState
{
  public CharacterInvestmentState(
      int characterLevel,
      ProfileFact<int> limitBreak,
      ProfileFact<int> coreLevel,
      ProfileFact<int> bondLevel)
  {
    if (characterLevel <= 0)
    {
      throw new ArgumentOutOfRangeException(nameof(characterLevel));
    }

    CharacterLevel = characterLevel;
    LimitBreak = ProfileGuard.RequireFact(limitBreak, nameof(limitBreak));
    CoreLevel = ProfileGuard.RequireFact(coreLevel, nameof(coreLevel));
    BondLevel = ProfileGuard.RequireFact(bondLevel, nameof(bondLevel));
  }

  /// <summary>A mandatory manual battle level; imports cannot substitute an ambiguous observation.</summary>
  public int CharacterLevel { get; }

  public ProfileFact<int> LimitBreak { get; }

  public ProfileFact<int> CoreLevel { get; }

  public ProfileFact<int> BondLevel { get; }
}

public sealed class CharacterSkillState
{
  public CharacterSkillState(
      ProfileFact<int> skill1,
      ProfileFact<int> skill2,
      ProfileFact<int> burst)
  {
    Skill1 = ProfileGuard.RequireFact(skill1, nameof(skill1));
    Skill2 = ProfileGuard.RequireFact(skill2, nameof(skill2));
    Burst = ProfileGuard.RequireFact(burst, nameof(burst));
  }

  public ProfileFact<int> Skill1 { get; }

  public ProfileFact<int> Skill2 { get; }

  public ProfileFact<int> Burst { get; }
}

public sealed class CharacterOverloadLineInput
{
  public CharacterOverloadLineInput(
      int lineIndex,
      CombatSupportDefinitionVersion optionDefinitionVersion,
      CombatSupportExactValue applicationValue)
  {
    if (lineIndex is < 1 or > 3)
    {
      throw new ArgumentOutOfRangeException(nameof(lineIndex));
    }

    ArgumentNullException.ThrowIfNull(optionDefinitionVersion);
    if (optionDefinitionVersion.Content is not OverloadOptionDefinitionContent)
    {
      throw new ArgumentException("An OL line must reference an overload-option definition.", nameof(optionDefinitionVersion));
    }

    LineIndex = lineIndex;
    OptionDefinitionVersion = optionDefinitionVersion;
    ApplicationValue = applicationValue;
  }

  public int LineIndex { get; }

  public CombatSupportDefinitionVersion OptionDefinitionVersion { get; }

  /// <summary>
  /// The signed normalized application value. Research mode preserves any exact decimal value.
  /// </summary>
  public CombatSupportExactValue ApplicationValue { get; }
}

public sealed class CharacterEquipmentInput
{
  private CharacterEquipmentInput(
      EntityUid equipmentSlotUid,
      CombatSupportEquipmentSlot slot,
      ProfileAttachmentKind attachmentKind,
      CombatSupportDefinitionVersion? definitionVersion,
      ProfileFact<int> enhancementLevel,
      ProfileFact<bool> manufacturerMatch,
      IReadOnlyList<CharacterOverloadLineInput> overloadLines,
      string? reasonCode)
  {
    EquipmentSlotUid = ProfileGuard.RequireUid(equipmentSlotUid, nameof(equipmentSlotUid));
    Slot = ProfileGuard.RequireEnum(slot, nameof(slot));
    AttachmentKind = ProfileGuard.RequireEnum(attachmentKind, nameof(attachmentKind));
    DefinitionVersion = definitionVersion;
    EnhancementLevel = enhancementLevel;
    ManufacturerMatch = manufacturerMatch;
    OverloadLines = overloadLines;
    ReasonCode = reasonCode;
  }

  public EntityUid EquipmentSlotUid { get; }

  public CombatSupportEquipmentSlot Slot { get; }

  public ProfileAttachmentKind AttachmentKind { get; }

  public bool Equipped => AttachmentKind == ProfileAttachmentKind.Attached;

  public CombatSupportDefinitionVersion? DefinitionVersion { get; }

  public ProfileFact<int> EnhancementLevel { get; }

  public ProfileFact<bool> ManufacturerMatch { get; }

  /// <summary>Unique sparse line indexes in the fixed 1..3 coordinate, sorted without compaction.</summary>
  public IReadOnlyList<CharacterOverloadLineInput> OverloadLines { get; }

  public string? ReasonCode { get; }

  public static CharacterEquipmentInput Detached(
      EntityUid equipmentSlotUid,
      CombatSupportEquipmentSlot slot) =>
      new(
          equipmentSlotUid,
          slot,
          ProfileAttachmentKind.Detached,
          null,
          ProfileFact<int>.NotApplicable(),
          ProfileFact<bool>.NotApplicable(),
          Array.Empty<CharacterOverloadLineInput>(),
          null);

  public static CharacterEquipmentInput Unresolved(
      EntityUid equipmentSlotUid,
      CombatSupportEquipmentSlot slot,
      string reasonCode)
  {
    var controlled = ControlledCode.Require(reasonCode, nameof(reasonCode));
    return new CharacterEquipmentInput(
        equipmentSlotUid,
        slot,
        ProfileAttachmentKind.Unresolved,
        null,
        ProfileFact<int>.Unresolved(controlled),
        ProfileFact<bool>.Unresolved(controlled),
        Array.Empty<CharacterOverloadLineInput>(),
        controlled);
  }

  public static CharacterEquipmentInput EquippedWith(
      EntityUid equipmentSlotUid,
      CombatSupportDefinitionVersion definitionVersion,
      ProfileFact<int> enhancementLevel,
      ProfileFact<bool> manufacturerMatch,
      IEnumerable<CharacterOverloadLineInput>? overloadLines = null)
  {
    ArgumentNullException.ThrowIfNull(definitionVersion);
    if (definitionVersion.Content is not EquipmentDefinitionContent equipment)
    {
      throw new ArgumentException("An equipped slot must reference an equipment definition.", nameof(definitionVersion));
    }

    var lines = (overloadLines ?? Array.Empty<CharacterOverloadLineInput>())
        .OrderBy(static line => line.LineIndex)
        .ToArray();
    if (lines.Any(static line => line is null) ||
        lines.GroupBy(static line => line.LineIndex).Any(static group => group.Count() != 1))
    {
      throw new ArgumentException("OL line indexes must be a unique sparse subset of 1..3.", nameof(overloadLines));
    }

    return new CharacterEquipmentInput(
        equipmentSlotUid,
        equipment.Slot,
        ProfileAttachmentKind.Attached,
        definitionVersion,
        ProfileGuard.RequireFact(enhancementLevel, nameof(enhancementLevel)),
        ProfileGuard.RequireFact(manufacturerMatch, nameof(manufacturerMatch)),
        Array.AsReadOnly(lines),
        null);
  }
}

public sealed class CharacterCubeInput
{
  private CharacterCubeInput(
      ProfileAttachmentKind attachmentKind,
      CombatSupportDefinitionVersion? definitionVersion,
      ProfileFact<int> level,
      string? reasonCode)
  {
    AttachmentKind = attachmentKind;
    DefinitionVersion = definitionVersion;
    Level = level;
    ReasonCode = reasonCode;
  }

  public ProfileAttachmentKind AttachmentKind { get; }

  public bool Equipped => AttachmentKind == ProfileAttachmentKind.Attached;

  public CombatSupportDefinitionVersion? DefinitionVersion { get; }

  public ProfileFact<int> Level { get; }

  public string? ReasonCode { get; }

  public static CharacterCubeInput Detached() =>
      new(ProfileAttachmentKind.Detached, null, ProfileFact<int>.NotApplicable(), null);

  public static CharacterCubeInput Unresolved(string reasonCode)
  {
    var controlled = ControlledCode.Require(reasonCode, nameof(reasonCode));
    return new CharacterCubeInput(
        ProfileAttachmentKind.Unresolved,
        null,
        ProfileFact<int>.Unresolved(controlled),
        controlled);
  }

  public static CharacterCubeInput Attached(
      CombatSupportDefinitionVersion definitionVersion,
      ProfileFact<int> level)
  {
    ArgumentNullException.ThrowIfNull(definitionVersion);
    if (definitionVersion.Content is not HarmonyCubeDefinitionContent)
    {
      throw new ArgumentException("An attached cube must reference a harmony-cube definition.", nameof(definitionVersion));
    }

    return new CharacterCubeInput(
        ProfileAttachmentKind.Attached,
        definitionVersion,
        ProfileGuard.RequireFact(level, nameof(level)),
        null);
  }
}

public enum CharacterCollectibleSelectionKind
{
  Detached,
  GenericCollection,
  Favorite,
  NotApplicable,
  Unresolved
}

public sealed class CharacterCollectibleInput
{
  private CharacterCollectibleInput(
      CharacterCollectibleSelectionKind kind,
      CombatSupportDefinitionVersion? definitionVersion,
      ProfileFact<int> level,
      string? reasonCode)
  {
    Kind = kind;
    DefinitionVersion = definitionVersion;
    Level = level;
    ReasonCode = reasonCode;
  }

  public CharacterCollectibleSelectionKind Kind { get; }

  public CombatSupportDefinitionVersion? DefinitionVersion { get; }

  public ProfileFact<int> Level { get; }

  public string? ReasonCode { get; }

  public static CharacterCollectibleInput Detached() =>
      new(CharacterCollectibleSelectionKind.Detached, null, ProfileFact<int>.NotApplicable(), null);

  public static CharacterCollectibleInput NotApplicable() =>
      new(CharacterCollectibleSelectionKind.NotApplicable, null, ProfileFact<int>.NotApplicable(), null);

  public static CharacterCollectibleInput Unresolved(string reasonCode) =>
      new(
          CharacterCollectibleSelectionKind.Unresolved,
          null,
          ProfileFact<int>.Unresolved(reasonCode),
          ControlledCode.Require(reasonCode, nameof(reasonCode)));

  public static CharacterCollectibleInput GenericCollection(
      CombatSupportDefinitionVersion definitionVersion,
      ProfileFact<int> level) =>
      Selected(CharacterCollectibleSelectionKind.GenericCollection, definitionVersion, level);

  public static CharacterCollectibleInput Favorite(
      CombatSupportDefinitionVersion definitionVersion,
      ProfileFact<int> level) =>
      Selected(CharacterCollectibleSelectionKind.Favorite, definitionVersion, level);

  private static CharacterCollectibleInput Selected(
      CharacterCollectibleSelectionKind kind,
      CombatSupportDefinitionVersion definitionVersion,
      ProfileFact<int> level)
  {
    ArgumentNullException.ThrowIfNull(definitionVersion);
    var expectedKind = kind == CharacterCollectibleSelectionKind.GenericCollection
        ? CombatSupportDefinitionKind.GenericCollection
        : CombatSupportDefinitionKind.Favorite;
    if (definitionVersion.Content.Kind != expectedKind)
    {
      throw new ArgumentException("A collectible selection references the wrong definition kind.", nameof(definitionVersion));
    }

    return new CharacterCollectibleInput(
        kind,
        definitionVersion,
        ProfileGuard.RequireFact(level, nameof(level)),
        null);
  }
}

public sealed class CharacterOverloadLine
{
  internal CharacterOverloadLine(
      int lineIndex,
      CombatSupportDefinitionReference optionDefinition,
      ProfileFact<CombatSupportOverloadOptionType> optionType,
      ProfileFact<CombatSupportValueUnit> unit,
      CombatSupportExactValue applicationValue)
  {
    LineIndex = lineIndex;
    OptionDefinition = optionDefinition;
    OptionType = optionType;
    Unit = unit;
    ApplicationValue = applicationValue;
  }

  public int LineIndex { get; }

  public CombatSupportDefinitionReference OptionDefinition { get; }

  public ProfileFact<CombatSupportOverloadOptionType> OptionType { get; }

  public ProfileFact<CombatSupportValueUnit> Unit { get; }

  public CombatSupportExactValue ApplicationValue { get; }
}

public sealed class CharacterEquipmentState
{
  internal CharacterEquipmentState(
      EntityUid equipmentSlotUid,
      CombatSupportEquipmentSlot slot,
      ProfileAttachmentKind attachmentKind,
      CombatSupportDefinitionReference? definition,
      ProfileFact<int> tier,
      ProfileFact<int> enhancementLevel,
      ProfileFact<bool> manufacturerMatch,
      IReadOnlyList<CharacterOverloadLine> overloadLines,
      string? reasonCode)
  {
    EquipmentSlotUid = equipmentSlotUid;
    Slot = slot;
    AttachmentKind = attachmentKind;
    Definition = definition;
    Tier = tier;
    EnhancementLevel = enhancementLevel;
    ManufacturerMatch = manufacturerMatch;
    OverloadLines = overloadLines;
    ReasonCode = reasonCode;
  }

  public EntityUid EquipmentSlotUid { get; }

  public CombatSupportEquipmentSlot Slot { get; }

  public ProfileAttachmentKind AttachmentKind { get; }

  public bool Equipped => AttachmentKind == ProfileAttachmentKind.Attached;

  public CombatSupportDefinitionReference? Definition { get; }

  public ProfileFact<int> Tier { get; }

  public ProfileFact<int> EnhancementLevel { get; }

  public ProfileFact<bool> ManufacturerMatch { get; }

  public IReadOnlyList<CharacterOverloadLine> OverloadLines { get; }

  public string? ReasonCode { get; }
}

public sealed class CharacterCubeState
{
  internal CharacterCubeState(
      ProfileAttachmentKind attachmentKind,
      CombatSupportDefinitionReference? definition,
      ProfileFact<int> level,
      string? reasonCode)
  {
    AttachmentKind = attachmentKind;
    Definition = definition;
    Level = level;
    ReasonCode = reasonCode;
  }

  public ProfileAttachmentKind AttachmentKind { get; }

  public bool Equipped => AttachmentKind == ProfileAttachmentKind.Attached;

  public CombatSupportDefinitionReference? Definition { get; }

  public ProfileFact<int> Level { get; }

  public string? ReasonCode { get; }
}

public sealed class CharacterCollectibleState
{
  internal CharacterCollectibleState(
      CharacterCollectibleSelectionKind kind,
      CombatSupportDefinitionReference? definition,
      ProfileFact<int> level,
      string? reasonCode)
  {
    Kind = kind;
    Definition = definition;
    Level = level;
    ReasonCode = reasonCode;
  }

  public CharacterCollectibleSelectionKind Kind { get; }

  public CombatSupportDefinitionReference? Definition { get; }

  public ProfileFact<int> Level { get; }

  public string? ReasonCode { get; }
}

public sealed class CharacterBuildRevisionContent
{
  internal CharacterBuildRevisionContent(
      ProfileDatasetBinding datasetBinding,
      CharacterBuildMaterializationPolicy materializationPolicy,
      ProfileValidationMode validationMode,
      CharacterDefinitionReference characterDefinition,
      CharacterInvestmentState investment,
      CharacterSkillState skills,
      IReadOnlyList<CharacterEquipmentState> equipment,
      CharacterCubeState cube,
      CharacterCollectibleState collectible)
  {
    DatasetBinding = datasetBinding;
    MaterializationPolicy = materializationPolicy;
    ValidationMode = validationMode;
    CharacterDefinition = characterDefinition;
    Investment = investment;
    Skills = skills;
    Equipment = equipment;
    Cube = cube;
    Collectible = collectible;
  }

  public ProfileDatasetBinding DatasetBinding { get; }

  public CharacterBuildMaterializationPolicy MaterializationPolicy { get; }

  public ProfileValidationMode ValidationMode { get; }

  public CharacterDefinitionReference CharacterDefinition { get; }

  public CharacterInvestmentState Investment { get; }

  public CharacterSkillState Skills { get; }

  public IReadOnlyList<CharacterEquipmentState> Equipment { get; }

  public CharacterCubeState Cube { get; }

  public CharacterCollectibleState Collectible { get; }
}

public sealed class CharacterBuildRevisionReference
{
  private CharacterBuildRevisionReference(
      EntityUid characterBuildUid,
      EntityUid revisionUid,
      EntityUid localAccountUid,
      EntityUid characterUid,
      ProfileDatasetBinding datasetBinding,
      Sha256Digest contentSha256,
      ProfileReadiness readiness,
      ProfileReadiness combatSemanticsReadiness)
  {
    CharacterBuildUid = characterBuildUid;
    RevisionUid = revisionUid;
    LocalAccountUid = localAccountUid;
    CharacterUid = characterUid;
    DatasetBinding = datasetBinding;
    ContentSha256 = contentSha256;
    Readiness = readiness;
    CombatSemanticsReadiness = combatSemanticsReadiness;
  }

  public EntityUid CharacterBuildUid { get; }

  public EntityUid RevisionUid { get; }

  public EntityUid LocalAccountUid { get; }

  public EntityUid CharacterUid { get; }

  public ProfileDatasetBinding DatasetBinding { get; }

  public Sha256Digest ContentSha256 { get; }

  public ProfileReadiness Readiness { get; }

  public ProfileReadiness CombatSemanticsReadiness { get; }

  internal static CharacterBuildRevisionReference Restore(
      EntityUid characterBuildUid,
      EntityUid revisionUid,
      EntityUid localAccountUid,
      EntityUid characterUid,
      ProfileDatasetBinding datasetBinding,
      Sha256Digest contentSha256,
      ProfileReadiness readiness,
      ProfileReadiness combatSemanticsReadiness) =>
      new(
          ProfileGuard.RequireUid(characterBuildUid, nameof(characterBuildUid)),
          ProfileGuard.RequireUid(revisionUid, nameof(revisionUid)),
          ProfileGuard.RequireUid(localAccountUid, nameof(localAccountUid)),
          ProfileGuard.RequireUid(characterUid, nameof(characterUid)),
          datasetBinding ?? throw new ArgumentNullException(nameof(datasetBinding)),
          ProfileGuard.RequireDigest(contentSha256, nameof(contentSha256)),
          ProfileGuard.RequireEnum(readiness, nameof(readiness)),
          ProfileGuard.RequireEnum(combatSemanticsReadiness, nameof(combatSemanticsReadiness)));
}
