using System.Globalization;
using NikkeLocalLab.Domain.CombatSupport;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Import.CombatSupportCatalog;

public static class ImportedCombatSupportCandidateCanonicalizer
{
  public const string ContractId = "nll/imported-combat-support-candidates/v1";

  public static string ToCanonicalText(
      IEnumerable<ImportedCombatSupportDefinitionCandidate> definitions)
  {
    ArgumentNullException.ThrowIfNull(definitions);
    var normalized = definitions
        .OrderBy(static item => CombatSupportCanonicalCodes.DefinitionKind(item.Kind), StringComparer.Ordinal)
        .ThenBy(static item => item.AliasFingerprint.Hex, StringComparer.Ordinal)
        .ToArray();
    if (normalized.Length == 0 || normalized.Any(static item => item is null) ||
        normalized.GroupBy(static item => item.AliasFingerprint).Any(static group => group.Count() != 1))
    {
      throw new ArgumentException("Imported combat-support candidates must be non-empty and unique.", nameof(definitions));
    }

    var lines = new List<string> { ContractId, $"count={Integer(normalized.Length)}" };
    for (var index = 0; index < normalized.Length; index++)
    {
      var candidate = normalized[index];
      var prefix = $"definitions.{Integer(index)}";
      lines.Add($"{prefix}.kind={CombatSupportCanonicalCodes.DefinitionKind(candidate.Kind)}");
      lines.Add($"{prefix}.source-alias={candidate.AliasFingerprint.Hex}");
      AppendPayload(lines, prefix, candidate.Payload);
    }

    return string.Join('\n', lines);
  }

  public static Sha256Digest ComputeHash(
      IEnumerable<ImportedCombatSupportDefinitionCandidate> definitions) =>
      Sha256Digest.ComputeUtf8(ToCanonicalText(definitions));

  private static void AppendPayload(
      ICollection<string> lines,
      string prefix,
      IImportedCombatSupportDefinitionPayload payload)
  {
    switch (payload)
    {
      case ImportedEquipmentDefinitionPayload equipment:
        lines.Add($"{prefix}.slot={CombatSupportCanonicalCodes.EquipmentSlot(equipment.Slot)}");
        lines.Add($"{prefix}.combat-role={Fact(equipment.CombatRole, CombatSupportCanonicalCodes.CombatRole)}");
        lines.Add($"{prefix}.manufacturer={Fact(equipment.Manufacturer, CombatSupportCanonicalCodes.Manufacturer)}");
        lines.Add($"{prefix}.tier={Fact(equipment.Tier, Integer)}");
        lines.Add($"{prefix}.enhancement-grade={Fact(equipment.EnhancementGrade, Integer)}");
        lines.Add($"{prefix}.maximum-enhancement-level={Fact(equipment.MaximumEnhancementLevel, Integer)}");
        lines.Add($"{prefix}.overload-eligible={Fact(equipment.OverloadEligible, Boolean)}");
        AppendContributions(lines, $"{prefix}.base-stats", equipment.BaseStats);
        lines.Add($"{prefix}.option-slots.count={Integer(equipment.OptionSlots.Count)}");
        foreach (var optionSlot in equipment.OptionSlots.OrderBy(static item => item.Ordinal))
        {
          lines.Add(
              $"{prefix}.option-slots.{Integer(optionSlot.Ordinal)}.activation-probability={Exact(optionSlot.ActivationProbability)}");
        }

        break;
      case ImportedHarmonyCubeDefinitionPayload cube:
        lines.Add($"{prefix}.rarity={Fact(cube.Rarity, CombatSupportCanonicalCodes.Rarity)}");
        lines.Add(
            $"{prefix}.applicable-combat-role={Fact(cube.ApplicableCombatRole, CombatSupportCanonicalCodes.CombatRole)}");
        lines.Add($"{prefix}.maximum-level={Fact(cube.MaximumLevel, Integer)}");
        lines.Add($"{prefix}.skill-semantics={Fact(cube.SkillSemantics, Boolean)}");
        AppendLevels(lines, prefix, cube.Levels);
        break;
      case ImportedGenericCollectionDefinitionPayload collection:
        lines.Add(
            $"{prefix}.applicable-weapon-class={Fact(collection.ApplicableWeaponClass, CombatSupportCanonicalCodes.WeaponClass)}");
        lines.Add($"{prefix}.rarity={Fact(collection.Rarity, CombatSupportCanonicalCodes.Rarity)}");
        lines.Add($"{prefix}.maximum-level={Fact(collection.MaximumLevel, Integer)}");
        lines.Add($"{prefix}.skill-semantics={Fact(collection.SkillSemantics, Boolean)}");
        AppendLevels(lines, prefix, collection.Levels);
        break;
      case ImportedFavoriteDefinitionPayload favorite:
        lines.Add(
            $"{prefix}.applicable-character-alias={Fact(favorite.ApplicableCharacterAlias, Alias)}");
        lines.Add($"{prefix}.rarity={Fact(favorite.Rarity, CombatSupportCanonicalCodes.Rarity)}");
        lines.Add($"{prefix}.maximum-level={Fact(favorite.MaximumLevel, Integer)}");
        lines.Add($"{prefix}.skill-semantics={Fact(favorite.SkillSemantics, Boolean)}");
        AppendLevels(lines, prefix, favorite.Levels);
        break;
      case ImportedConsoleDefinitionPayload console:
        lines.Add($"{prefix}.coordinate={CombatSupportCanonicalCodes.ConsoleCoordinate(console.Coordinate)}");
        lines.Add($"{prefix}.maximum-level={Fact(console.MaximumLevel, Integer)}");
        AppendContributions(lines, $"{prefix}.per-level", console.PerLevelContributions);
        AppendLevels(lines, prefix, console.Levels);
        break;
      case ImportedOverloadOptionDefinitionPayload overload:
        lines.Add($"{prefix}.option-type={Fact(overload.OptionType, CombatSupportCanonicalCodes.OverloadOptionType)}");
        lines.Add($"{prefix}.unit={Fact(overload.Unit, CombatSupportCanonicalCodes.ValueUnit)}");
        lines.Add($"{prefix}.kind-selection-probability={Exact(overload.KindSelectionProbability)}");
        lines.Add($"{prefix}.legal-bands.count={Integer(overload.LegalBands.Count)}");
        foreach (var band in overload.LegalBands.OrderBy(static item => item.Ordinal))
        {
          var bandPrefix = $"{prefix}.legal-bands.{Integer(band.Ordinal)}";
          lines.Add($"{bandPrefix}.probability={Exact(band.Probability)}");
          lines.Add($"{bandPrefix}.values.count={Integer(band.OrderedValues.Count)}");
          for (var valueOrdinal = 0; valueOrdinal < band.OrderedValues.Count; valueOrdinal++)
          {
            var value = band.OrderedValues[valueOrdinal];
            var valuePrefix = $"{bandPrefix}.values.{Integer(valueOrdinal)}";
            lines.Add($"{valuePrefix}.roll-level={Integer(value.RollLevel)}");
            lines.Add($"{valuePrefix}.source-raw={value.SourceRawValue.ToString(CultureInfo.InvariantCulture)}");
            lines.Add($"{valuePrefix}.magnitude-bp={Integer(value.MagnitudeBasisPoints)}");
            lines.Add($"{valuePrefix}.engine-fraction={Exact(value.EngineFraction)}");
          }
        }

        var aliases = overload.LegalValueAliases.OrderBy(static item => item.RollLevel).ToArray();
        lines.Add($"{prefix}.legal-value-aliases.count={Integer(aliases.Length)}");
        for (var aliasOrdinal = 0; aliasOrdinal < aliases.Length; aliasOrdinal++)
        {
          var alias = aliases[aliasOrdinal];
          lines.Add(
              $"{prefix}.legal-value-aliases.{Integer(aliasOrdinal)}={Integer(alias.RollLevel)}:{alias.SourceValueAlias.Hex}");
        }

        lines.Add(
            $"{prefix}.duplicate-policy={Fact(overload.DuplicatePolicy, CombatSupportCanonicalCodes.OverloadDuplicatePolicy)}");
        lines.Add($"{prefix}.state-effect-references-validated={Boolean(overload.StateEffectReferencesValidated)}");
        break;
      default:
        throw new ArgumentException("The imported combat-support payload is unsupported.", nameof(payload));
    }

    lines.Add($"{prefix}.source-resolved={Boolean(payload.IsSourceResolved)}");
  }

  private static void AppendLevels(
      ICollection<string> lines,
      string prefix,
      IReadOnlyList<CombatSupportLevelCoordinate> levels)
  {
    lines.Add($"{prefix}.levels.count={Integer(levels.Count)}");
    for (var index = 0; index < levels.Count; index++)
    {
      var level = levels[index];
      var levelPrefix = $"{prefix}.levels.{Integer(index)}";
      lines.Add($"{levelPrefix}.level={Integer(level.Level)}");
      lines.Add($"{levelPrefix}.grade={Fact(level.Grade, Integer)}");
      lines.Add($"{levelPrefix}.capacity={Fact(level.Capacity, Integer)}");
      lines.Add($"{levelPrefix}.minimum-synchro-level={Fact(level.MinimumSynchroLevel, Integer)}");
      lines.Add($"{levelPrefix}.skill-levels.count={Integer(level.SkillLevels.Count)}");
      for (var skillOrdinal = 0; skillOrdinal < level.SkillLevels.Count; skillOrdinal++)
      {
        lines.Add(
            $"{levelPrefix}.skill-levels.{Integer(skillOrdinal)}={Integer(level.SkillLevels[skillOrdinal])}");
      }

      AppendContributions(lines, levelPrefix, level.Contributions);
    }
  }

  private static void AppendContributions(
      ICollection<string> lines,
      string prefix,
      IReadOnlyList<CombatSupportStatContribution> contributions)
  {
    lines.Add($"{prefix}.contributions.count={Integer(contributions.Count)}");
    foreach (var contribution in contributions.OrderBy(static item => item.Ordinal))
    {
      var contributionPrefix = $"{prefix}.contributions.{Integer(contribution.Ordinal)}";
      lines.Add($"{contributionPrefix}.stat={Fact(contribution.Stat, CombatSupportCanonicalCodes.Stat)}");
      lines.Add($"{contributionPrefix}.unit={Fact(contribution.Unit, CombatSupportCanonicalCodes.ValueUnit)}");
      lines.Add($"{contributionPrefix}.value={Exact(contribution.Value)}");
    }
  }

  private static string Fact<T>(CombatSupportFact<T> fact, Func<T, string> formatter)
      where T : struct => fact.Status switch
      {
        CombatSupportFactStatus.Ready => $"ready:{formatter(fact.RequireValue())}",
        CombatSupportFactStatus.Unresolved => $"unresolved:{fact.ReasonCode}",
        CombatSupportFactStatus.NotApplicable => "not_applicable",
        _ => throw new ArgumentOutOfRangeException(nameof(fact))
      };

  private static string Exact(CombatSupportExactValue value) =>
      $"{value.UnscaledValue.ToString(CultureInfo.InvariantCulture)}e-{value.DecimalScale.ToString(CultureInfo.InvariantCulture)}";

  private static string Integer(int value) => value.ToString(CultureInfo.InvariantCulture);

  private static string Boolean(bool value) => value ? "true" : "false";

  private static string Alias(SourceAliasFingerprint value) => value.Hex;
}
