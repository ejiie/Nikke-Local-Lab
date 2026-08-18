using NikkeLocalLab.Domain.CombatSupport;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Import.CombatSupportCatalog;

public interface IImportedCombatSupportDefinitionPayload
{
  CombatSupportDefinitionKind Kind { get; }

  bool IsSourceResolved { get; }
}

public sealed record ImportedEquipmentDefinitionPayload(
    CombatSupportEquipmentSlot Slot,
    CombatSupportFact<CombatSupportCombatRole> CombatRole,
    CombatSupportFact<CombatSupportManufacturer> Manufacturer,
    CombatSupportFact<int> Tier,
    CombatSupportFact<int> EnhancementGrade,
    CombatSupportFact<int> MaximumEnhancementLevel,
    CombatSupportFact<bool> OverloadEligible,
    IReadOnlyList<CombatSupportStatContribution> BaseStats,
    IReadOnlyList<CombatSupportEquipmentOptionSlot> OptionSlots) : IImportedCombatSupportDefinitionPayload
{
  public CombatSupportDefinitionKind Kind => CombatSupportDefinitionKind.Equipment;

  public bool IsSourceResolved =>
      CombatRole.Status == CombatSupportFactStatus.Ready &&
      Tier.Status == CombatSupportFactStatus.Ready &&
      EnhancementGrade.Status == CombatSupportFactStatus.Ready &&
      MaximumEnhancementLevel.Status == CombatSupportFactStatus.Ready;
}

public sealed record ImportedHarmonyCubeDefinitionPayload(
    CombatSupportFact<CombatSupportRarity> Rarity,
    CombatSupportFact<CombatSupportCombatRole> ApplicableCombatRole,
    CombatSupportFact<int> MaximumLevel,
    IReadOnlyList<CombatSupportLevelCoordinate> Levels,
    CombatSupportFact<bool> SkillSemantics) : IImportedCombatSupportDefinitionPayload
{
  public CombatSupportDefinitionKind Kind => CombatSupportDefinitionKind.HarmonyCube;

  public bool IsSourceResolved =>
      Rarity.Status == CombatSupportFactStatus.Ready &&
      ApplicableCombatRole.IsResolved &&
      MaximumLevel.Status == CombatSupportFactStatus.Ready &&
      MaximumLevel.Value == 15 &&
      Levels.Count == 15;
}

public sealed record ImportedGenericCollectionDefinitionPayload(
    CombatSupportFact<CombatSupportWeaponClass> ApplicableWeaponClass,
    CombatSupportFact<CombatSupportRarity> Rarity,
    CombatSupportFact<int> MaximumLevel,
    IReadOnlyList<CombatSupportLevelCoordinate> Levels,
    CombatSupportFact<bool> SkillSemantics) : IImportedCombatSupportDefinitionPayload
{
  public CombatSupportDefinitionKind Kind => CombatSupportDefinitionKind.GenericCollection;

  public bool IsSourceResolved =>
      ApplicableWeaponClass.Status == CombatSupportFactStatus.Ready &&
      Rarity.Status == CombatSupportFactStatus.Ready &&
      MaximumLevel.Status == CombatSupportFactStatus.Ready &&
      Levels.Count > 0;
}

public sealed record ImportedFavoriteDefinitionPayload(
    CombatSupportFact<SourceAliasFingerprint> ApplicableCharacterAlias,
    CombatSupportFact<CombatSupportRarity> Rarity,
    CombatSupportFact<int> MaximumLevel,
    IReadOnlyList<CombatSupportLevelCoordinate> Levels,
    CombatSupportFact<bool> SkillSemantics) : IImportedCombatSupportDefinitionPayload
{
  public CombatSupportDefinitionKind Kind => CombatSupportDefinitionKind.Favorite;

  public bool IsSourceResolved =>
      ApplicableCharacterAlias.Status == CombatSupportFactStatus.Ready &&
      Rarity.Status == CombatSupportFactStatus.Ready &&
      MaximumLevel.Status == CombatSupportFactStatus.Ready &&
      Levels.Count > 0;
}

public sealed record ImportedConsoleDefinitionPayload(
    CombatSupportConsoleCoordinate Coordinate,
    CombatSupportFact<int> MaximumLevel,
    IReadOnlyList<CombatSupportLevelCoordinate> Levels,
    IReadOnlyList<CombatSupportStatContribution> PerLevelContributions) : IImportedCombatSupportDefinitionPayload
{
  public CombatSupportDefinitionKind Kind => CombatSupportDefinitionKind.Console;

  public bool IsSourceResolved =>
      MaximumLevel.Status == CombatSupportFactStatus.Ready &&
      Levels.Count > 0 &&
      PerLevelContributions.Count == 3;
}

public sealed record ImportedOverloadOptionDefinitionPayload : IImportedCombatSupportDefinitionPayload
{
  public ImportedOverloadOptionDefinitionPayload(
      CombatSupportFact<CombatSupportOverloadOptionType> optionType,
      CombatSupportFact<CombatSupportValueUnit> unit,
      CombatSupportExactValue kindSelectionProbability,
      IEnumerable<CombatSupportOverloadLegalBand> legalBands,
      IEnumerable<ImportedOverloadLegalValueAlias> legalValueAliases,
      CombatSupportFact<CombatSupportOverloadDuplicatePolicy> duplicatePolicy,
      bool stateEffectReferencesValidated)
  {
    OptionType = optionType ?? throw new ArgumentNullException(nameof(optionType));
    Unit = unit ?? throw new ArgumentNullException(nameof(unit));
    KindSelectionProbability = kindSelectionProbability;
    ArgumentNullException.ThrowIfNull(legalBands);
    ArgumentNullException.ThrowIfNull(legalValueAliases);
    DuplicatePolicy = duplicatePolicy ?? throw new ArgumentNullException(nameof(duplicatePolicy));
    var normalizedBands = legalBands.OrderBy(static item => item.Ordinal).ToArray();
    var normalizedAliases = legalValueAliases.OrderBy(static item => item.RollLevel).ToArray();
    if (normalizedBands.Any(static item => item is null) ||
        !normalizedBands.Select(static item => item.Ordinal)
            .SequenceEqual(Enumerable.Range(0, normalizedBands.Length)) ||
        !normalizedAliases.Select(static item => item.RollLevel).SequenceEqual(Enumerable.Range(1, 15)) ||
        normalizedAliases.Select(static item => item.SourceValueAlias).Distinct().Count() != 15)
    {
      throw new ArgumentException("Imported overload legal-value relations are not canonical.");
    }

    LegalBands = Array.AsReadOnly(normalizedBands);
    LegalValueAliases = Array.AsReadOnly(normalizedAliases);
    StateEffectReferencesValidated = stateEffectReferencesValidated;
  }

  public CombatSupportDefinitionKind Kind => CombatSupportDefinitionKind.OverloadOption;

  public CombatSupportFact<CombatSupportOverloadOptionType> OptionType { get; }

  public CombatSupportFact<CombatSupportValueUnit> Unit { get; }

  public CombatSupportExactValue KindSelectionProbability { get; }

  public IReadOnlyList<CombatSupportOverloadLegalBand> LegalBands { get; }

  public IReadOnlyList<ImportedOverloadLegalValueAlias> LegalValueAliases { get; }

  public CombatSupportFact<CombatSupportOverloadDuplicatePolicy> DuplicatePolicy { get; }

  public bool StateEffectReferencesValidated { get; }

  public bool IsResearchReady =>
      OptionType.Status == CombatSupportFactStatus.Ready &&
      Unit.Status == CombatSupportFactStatus.Ready;

  public bool IsGameLegalReady =>
      IsResearchReady && LegalBands.Count > 0 &&
      LegalBands.Sum(static item => item.OrderedValues.Count) == 15 &&
      LegalValueAliases.Count == 15;

  public bool IsSourceResolved => StateEffectReferencesValidated;
}

public sealed record ImportedOverloadLegalValueAlias
{
  public ImportedOverloadLegalValueAlias(
      SourceAliasFingerprint sourceValueAlias,
      int rollLevel)
  {
    if (sourceValueAlias == default || rollLevel is < 1 or > 15)
    {
      throw new ArgumentException("An overload source-value relation is invalid.");
    }

    SourceValueAlias = sourceValueAlias;
    RollLevel = rollLevel;
  }

  public SourceAliasFingerprint SourceValueAlias { get; }

  public int RollLevel { get; }
}

public sealed record ImportedCombatSupportDefinitionCandidate
{
  public ImportedCombatSupportDefinitionCandidate(
      SourceAliasFingerprint aliasFingerprint,
      IImportedCombatSupportDefinitionPayload payload)
  {
    if (aliasFingerprint == default)
    {
      throw new ArgumentException("A combat-support source alias must be initialized.", nameof(aliasFingerprint));
    }

    AliasFingerprint = aliasFingerprint;
    Payload = payload ?? throw new ArgumentNullException(nameof(payload));
  }

  public SourceAliasFingerprint AliasFingerprint { get; }

  public IImportedCombatSupportDefinitionPayload Payload { get; }

  public CombatSupportDefinitionKind Kind => Payload.Kind;
}

public sealed record CombatSupportCatalogDiagnostic
{
  public CombatSupportCatalogDiagnostic(string code, int occurrenceCount)
  {
    Code = ControlledCode.Require(code, nameof(code));
    if (occurrenceCount <= 0)
    {
      throw new ArgumentOutOfRangeException(nameof(occurrenceCount));
    }

    OccurrenceCount = occurrenceCount;
  }

  public string Code { get; }

  public int OccurrenceCount { get; }
}

public sealed record CombatSupportCatalogExtraction
{
  public CombatSupportCatalogExtraction(
      IEnumerable<ImportedCombatSupportDefinitionCandidate> definitions,
      IEnumerable<CombatSupportCatalogDiagnostic> diagnostics,
      Sha256Digest sourceArchiveSha256,
      Sha256Digest canonicalCandidateSha256)
  {
    ArgumentNullException.ThrowIfNull(definitions);
    ArgumentNullException.ThrowIfNull(diagnostics);
    var normalizedDefinitions = definitions
        .OrderBy(static item => CombatSupportCanonicalCodes.DefinitionKind(item.Kind), StringComparer.Ordinal)
        .ThenBy(static item => item.AliasFingerprint.Hex, StringComparer.Ordinal)
        .ToArray();
    var normalizedDiagnostics = diagnostics.OrderBy(static item => item.Code, StringComparer.Ordinal).ToArray();
    if (normalizedDefinitions.Length == 0 ||
        normalizedDefinitions.Any(static item => item is null) ||
        normalizedDefinitions.GroupBy(static item => item.AliasFingerprint)
            .Any(static group => group.Count() != 1) ||
        Enum.GetValues<CombatSupportDefinitionKind>()
            .Any(kind => normalizedDefinitions.All(item => item.Kind != kind)) ||
        normalizedDiagnostics.Any(static item => item is null) ||
        sourceArchiveSha256 == default ||
        canonicalCandidateSha256 == default ||
        canonicalCandidateSha256 != ImportedCombatSupportCandidateCanonicalizer.ComputeHash(
            normalizedDefinitions))
    {
      throw new ArgumentException("The combat-support extraction is incomplete or non-canonical.");
    }

    Definitions = Array.AsReadOnly(normalizedDefinitions);
    Diagnostics = Array.AsReadOnly(normalizedDiagnostics);
    SourceArchiveSha256 = sourceArchiveSha256;
    CanonicalCandidateSha256 = canonicalCandidateSha256;
  }

  public IReadOnlyList<ImportedCombatSupportDefinitionCandidate> Definitions { get; }

  public IReadOnlyList<CombatSupportCatalogDiagnostic> Diagnostics { get; }

  public Sha256Digest SourceArchiveSha256 { get; }

  public Sha256Digest CanonicalCandidateSha256 { get; }

  public int Count(CombatSupportDefinitionKind kind) =>
      Definitions.Count(item => item.Kind == kind);
}

public sealed class CombatSupportCatalogSourceException : Exception
{
  public CombatSupportCatalogSourceException(string code)
      : base("The combat-support catalog source failed a controlled validation.")
  {
    Code = ControlledCode.Require(code, nameof(code));
  }

  public string Code { get; }
}
