using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Domain.Character;

public enum CombatBuildReadiness
{
  Ready,
  Unresolved,
  Invalid,
}

public enum ResolutionIssueKind
{
  Unresolved,
  Invalid,
}

public sealed class ResolutionIssue
{
  internal ResolutionIssue(ResolutionIssueKind kind, string fieldCode, string reasonCode)
  {
    Kind = kind;
    FieldCode = ControlledCode.Require(fieldCode, nameof(fieldCode));
    ReasonCode = ControlledCode.Require(reasonCode, nameof(reasonCode));
  }

  public ResolutionIssueKind Kind { get; }

  public string FieldCode { get; }

  public string ReasonCode { get; }
}

public sealed class CombatEquipmentSeed
{
  internal CombatEquipmentSeed(
      EquipmentSlot slot,
      NormalizedFact<EntityUid> equipmentDefinitionUid,
      NormalizedFact<int> tier,
      NormalizedFact<int> enhancementLevel,
      NormalizedFact<bool> manufacturerMatch)
  {
    Slot = slot;
    EquipmentDefinitionUid = equipmentDefinitionUid;
    Tier = tier;
    EnhancementLevel = enhancementLevel;
    ManufacturerMatch = manufacturerMatch;
  }

  public EquipmentSlot Slot { get; }

  public NormalizedFact<EntityUid> EquipmentDefinitionUid { get; }

  public NormalizedFact<int> Tier { get; }

  public NormalizedFact<int> EnhancementLevel { get; }

  public NormalizedFact<bool> ManufacturerMatch { get; }
}

public sealed class DetachedCubeSeed
{
  private DetachedCubeSeed()
  {
  }

  public static DetachedCubeSeed Instance { get; } = new();

  public bool Equipped => false;

  public EntityUid? CubeUid => null;

  public int? Level => null;
}

public sealed class CombatSkillSeed
{
  internal CombatSkillSeed(
      NormalizedFact<int> skill1,
      NormalizedFact<int> skill2,
      NormalizedFact<int> burst)
  {
    Skill1 = skill1;
    Skill2 = skill2;
    Burst = burst;
  }

  public NormalizedFact<int> Skill1 { get; }

  public NormalizedFact<int> Skill2 { get; }

  public NormalizedFact<int> Burst { get; }
}

/// <summary>
/// Reserved shape for future overload writes. combat-max/v1 intentionally emits no instances.
/// </summary>
public sealed class CombatOverloadLine
{
  internal CombatOverloadLine(
      EquipmentSlot slot,
      int lineIndex,
      string optionCode,
      string exactValue,
      string unitCode)
  {
    Slot = slot;
    LineIndex = lineIndex;
    OptionCode = optionCode;
    ExactValue = exactValue;
    UnitCode = unitCode;
  }

  public EquipmentSlot Slot { get; }

  public int LineIndex { get; }

  public string OptionCode { get; }

  public string ExactValue { get; }

  public string UnitCode { get; }
}

public sealed class CombatMaxBuildSeed
{
  internal CombatMaxBuildSeed(
      EntityUid datasetSnapshotUid,
      EntityUid characterUid,
      EntityUid definitionVersionUid,
      Sha256Digest definitionContentSha256,
      int characterLevel,
      NormalizedFact<int> limitBreak,
      NormalizedFact<int> coreLevel,
      NormalizedFact<int> bondLevel,
      IReadOnlyList<CombatEquipmentSeed> equipment,
      CombatSkillSeed skills,
      NormalizedFact<int> collectionLevel,
      NormalizedFact<int> favoriteLevel)
  {
    DatasetSnapshotUid = datasetSnapshotUid;
    CharacterUid = characterUid;
    DefinitionVersionUid = definitionVersionUid;
    DefinitionContentSha256 = definitionContentSha256;
    CharacterLevel = characterLevel;
    LimitBreak = limitBreak;
    CoreLevel = coreLevel;
    BondLevel = bondLevel;
    Equipment = equipment;
    Skills = skills;
    CollectionLevel = collectionLevel;
    FavoriteLevel = favoriteLevel;
  }

  public string PolicyId => CombatMaxV1Resolver.PolicyId;

  public EntityUid DatasetSnapshotUid { get; }

  public EntityUid CharacterUid { get; }

  public EntityUid DefinitionVersionUid { get; }

  public Sha256Digest DefinitionContentSha256 { get; }

  public int CharacterLevel { get; }

  public NormalizedFact<int> LimitBreak { get; }

  public NormalizedFact<int> CoreLevel { get; }

  public NormalizedFact<int> BondLevel { get; }

  public IReadOnlyList<CombatEquipmentSeed> Equipment { get; }

  public DetachedCubeSeed Cube => DetachedCubeSeed.Instance;

  public CombatSkillSeed Skills { get; }

  public IReadOnlyList<CombatOverloadLine> OverloadLines { get; } = Array.Empty<CombatOverloadLine>();

  public NormalizedFact<int> CollectionLevel { get; }

  public NormalizedFact<int> FavoriteLevel { get; }
}

public sealed class CombatMaxResolution
{
  internal CombatMaxResolution(CombatMaxBuildSeed seed, IReadOnlyList<ResolutionIssue> issues)
  {
    Seed = seed;
    Issues = issues;
    Status = issues.Any(static issue => issue.Kind == ResolutionIssueKind.Invalid)
        ? CombatBuildReadiness.Invalid
        : issues.Any(static issue => issue.Kind == ResolutionIssueKind.Unresolved)
            ? CombatBuildReadiness.Unresolved
            : CombatBuildReadiness.Ready;
  }

  public CombatBuildReadiness Status { get; }

  public CombatMaxBuildSeed Seed { get; }

  public IReadOnlyList<ResolutionIssue> Issues { get; }
}
