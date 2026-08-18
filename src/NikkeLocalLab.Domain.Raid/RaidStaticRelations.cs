using System.Globalization;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Domain.Raid;

/// <summary>
/// A source-ID-free part relation captured from the authoritative Challenge chain.
/// TypeCode is a normalized semantic code; it must never contain a copied source enum or object name.
/// </summary>
public sealed class RaidPartStaticRelation
{
  public RaidPartStaticRelation(
      EntityUid partUid,
      int ordinal,
      string typeCode,
      int damageHpRatio,
      int hpRatio,
      int defenceRatio,
      int energyResistRatio,
      int metalResistRatio,
      int bioResistRatio,
      int attackRatio,
      bool isMainPart,
      bool isDamageable,
      bool isHpVisible,
      EntityUid? linkedPartUid = null)
  {
    PartUid = RaidDomainGuard.RequireUid(partUid, nameof(partUid));
    Ordinal = RequireOrdinal(ordinal);
    TypeCode = ControlledCode.Require(typeCode, nameof(typeCode));
    DamageHpRatio = RequireRatio(damageHpRatio, nameof(damageHpRatio));
    HpRatio = RequireRatio(hpRatio, nameof(hpRatio));
    DefenceRatio = RequireRatio(defenceRatio, nameof(defenceRatio));
    EnergyResistRatio = RequireRatio(energyResistRatio, nameof(energyResistRatio));
    MetalResistRatio = RequireRatio(metalResistRatio, nameof(metalResistRatio));
    BioResistRatio = RequireRatio(bioResistRatio, nameof(bioResistRatio));
    AttackRatio = RequireRatio(attackRatio, nameof(attackRatio));
    IsMainPart = isMainPart;
    IsDamageable = isDamageable;
    IsHpVisible = isHpVisible;
    LinkedPartUid = linkedPartUid.HasValue
        ? RaidDomainGuard.RequireUid(linkedPartUid.Value, nameof(linkedPartUid))
        : null;

    if (LinkedPartUid == PartUid)
    {
      throw new ArgumentException("A raid part cannot link to itself.", nameof(linkedPartUid));
    }
  }

  public EntityUid PartUid { get; }

  public int Ordinal { get; }

  public string TypeCode { get; }

  public int DamageHpRatio { get; }

  public int HpRatio { get; }

  public int DefenceRatio { get; }

  public int EnergyResistRatio { get; }

  public int MetalResistRatio { get; }

  public int BioResistRatio { get; }

  public int AttackRatio { get; }

  public bool IsMainPart { get; }

  public bool IsDamageable { get; }

  public bool IsHpVisible { get; }

  public EntityUid? LinkedPartUid { get; }

  internal string ToCanonicalTuple() => string.Join(
      '\t',
      PartUid,
      Ordinal.ToString(CultureInfo.InvariantCulture),
      TypeCode,
      DamageHpRatio.ToString(CultureInfo.InvariantCulture),
      HpRatio.ToString(CultureInfo.InvariantCulture),
      DefenceRatio.ToString(CultureInfo.InvariantCulture),
      EnergyResistRatio.ToString(CultureInfo.InvariantCulture),
      MetalResistRatio.ToString(CultureInfo.InvariantCulture),
      BioResistRatio.ToString(CultureInfo.InvariantCulture),
      AttackRatio.ToString(CultureInfo.InvariantCulture),
      IsMainPart ? "true" : "false",
      IsDamageable ? "true" : "false",
      IsHpVisible ? "true" : "false",
      LinkedPartUid?.ToString() ?? "none");

  private static int RequireOrdinal(int value)
  {
    if (value < 0)
    {
      throw new ArgumentOutOfRangeException(nameof(value), "A relation ordinal cannot be negative.");
    }

    return value;
  }

  private static int RequireRatio(int value, string parameterName)
  {
    if (value < 0)
    {
      throw new ArgumentOutOfRangeException(parameterName, "A normalized raid ratio cannot be negative.");
    }

    return value;
  }
}

/// <summary>
/// A source-ID-free identity for one ordered monster-skill slot.
/// Phase 1C preserves slot occupancy and order, but does not claim that the
/// underlying skill definition or runtime semantics have been normalized.
/// </summary>
public sealed class RaidSkillStaticRelation
{
  public RaidSkillStaticRelation(
      EntityUid skillUid,
      int ordinal,
      string roleCode)
  {
    SkillUid = RaidDomainGuard.RequireUid(skillUid, nameof(skillUid));
    if (ordinal < 0)
    {
      throw new ArgumentOutOfRangeException(nameof(ordinal), "A relation ordinal cannot be negative.");
    }

    Ordinal = ordinal;
    RoleCode = ControlledCode.Require(roleCode, nameof(roleCode));
  }

  public EntityUid SkillUid { get; }

  public int Ordinal { get; }

  public string RoleCode { get; }

  internal string ToCanonicalTuple() => string.Join(
      '\t',
      SkillUid,
      Ordinal.ToString(CultureInfo.InvariantCulture),
      RoleCode);
}

public sealed class RaidStaticRelations
{
  public RaidStaticRelations(
      IEnumerable<RaidPartStaticRelation> parts,
      IEnumerable<RaidSkillStaticRelation> skills)
  {
    Parts = Normalize(
        parts,
        static value => value.PartUid,
        static value => value.Ordinal,
        nameof(parts));
    Skills = Normalize(
        skills,
        static value => value.SkillUid,
        static value => value.Ordinal,
        nameof(skills));

    var partUids = Parts.Select(static part => part.PartUid).ToHashSet();
    if (Parts.Any(part => part.LinkedPartUid.HasValue && !partUids.Contains(part.LinkedPartUid.Value)))
    {
      throw new ArgumentException(
          "Every linked raid part UID must resolve inside the same static relation set.",
          nameof(parts));
    }
  }

  public IReadOnlyList<RaidPartStaticRelation> Parts { get; }

  public IReadOnlyList<RaidSkillStaticRelation> Skills { get; }

  private static IReadOnlyList<T> Normalize<T>(
      IEnumerable<T> values,
      Func<T, EntityUid> uid,
      Func<T, int> ordinal,
      string parameterName)
      where T : class
  {
    ArgumentNullException.ThrowIfNull(values, parameterName);
    var normalized = values
        .Select(value => value ??
            throw new ArgumentException("A static relation collection cannot contain null entries.", parameterName))
        .OrderBy(ordinal)
        .ThenBy(value => uid(value).ToString(), StringComparer.Ordinal)
        .ToArray();
    if (normalized.GroupBy(uid).Any(static group => group.Count() != 1) ||
        normalized.GroupBy(ordinal).Any(static group => group.Count() != 1) ||
        !normalized.Select(ordinal).SequenceEqual(Enumerable.Range(0, normalized.Length)))
    {
      throw new ArgumentException(
          "Static relations require unique UIDs and contiguous zero-based ordinals.",
          parameterName);
    }

    return Array.AsReadOnly(normalized);
  }
}
