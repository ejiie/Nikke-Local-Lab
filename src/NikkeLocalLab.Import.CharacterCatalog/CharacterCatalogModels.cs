using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Import.CharacterCatalog;

public enum ImportedFactStatus
{
  Ready,
  Unresolved,
  NotApplicable
}

public sealed record ImportedCodeFact
{
  private ImportedCodeFact(ImportedFactStatus status, string? value, string? reasonCode)
  {
    Status = status;
    Value = value;
    ReasonCode = reasonCode;
  }

  public ImportedFactStatus Status { get; }

  public string? Value { get; }

  public string? ReasonCode { get; }

  public static ImportedCodeFact Ready(string value) =>
      new(ImportedFactStatus.Ready, RequireCode(value), null);

  public static ImportedCodeFact Unresolved(string reasonCode) =>
      new(ImportedFactStatus.Unresolved, null, RequireCode(reasonCode));

  private static string RequireCode(string value)
  {
    ArgumentException.ThrowIfNullOrWhiteSpace(value);
    if (value.Length > 64 || value.Any(character =>
            !((character >= 'a' && character <= 'z') ||
              (character >= '0' && character <= '9') ||
              character is '_' or '-')))
    {
      throw new ArgumentException("The value must be a controlled lowercase code.", nameof(value));
    }

    return value;
  }
}

public sealed record ImportedIntegerFact
{
  private ImportedIntegerFact(ImportedFactStatus status, int? value, string? reasonCode)
  {
    Status = status;
    Value = value;
    ReasonCode = reasonCode;
  }

  public ImportedFactStatus Status { get; }

  public int? Value { get; }

  public string? ReasonCode { get; }

  public static ImportedIntegerFact Ready(int value)
  {
    if (value < 0)
    {
      throw new ArgumentOutOfRangeException(nameof(value));
    }

    return new ImportedIntegerFact(ImportedFactStatus.Ready, value, null);
  }

  public static ImportedIntegerFact Unresolved(string reasonCode) =>
      new(ImportedFactStatus.Unresolved, null, ImportedCodeFact.Unresolved(reasonCode).ReasonCode);

  public static ImportedIntegerFact NotApplicable() =>
      new(ImportedFactStatus.NotApplicable, null, null);
}

public sealed record ImportedCharacterDefinitionCandidate(
    SourceAliasFingerprint AliasFingerprint,
    ImportedCodeFact Rarity,
    ImportedCodeFact CharacterClass,
    ImportedCodeFact Weapon,
    ImportedCodeFact Element,
    ImportedCodeFact Manufacturer,
    ImportedIntegerFact MaximumCharacterLevel,
    ImportedIntegerFact MaximumLimitBreak,
    ImportedIntegerFact MaximumCore,
    ImportedIntegerFact MaximumBond,
    ImportedIntegerFact MaximumSkill1,
    ImportedIntegerFact MaximumSkill2,
    ImportedIntegerFact MaximumBurstSkill,
    ImportedIntegerFact MaximumEquipmentTier,
    ImportedIntegerFact MaximumEquipmentEnhancement,
    ImportedIntegerFact MaximumCubeLevel,
    ImportedIntegerFact MaximumCollectionLevel,
    ImportedIntegerFact MaximumFavoriteItemLevel)
{
  public bool IsSourceResolved =>
      CharacterClass.Status == ImportedFactStatus.Ready &&
      Rarity.Status == ImportedFactStatus.Ready &&
      Weapon.Status == ImportedFactStatus.Ready &&
      Element.Status == ImportedFactStatus.Ready &&
      Manufacturer.Status == ImportedFactStatus.Ready &&
      RequiredIntegerFacts().All(fact => fact.Status == ImportedFactStatus.Ready) &&
      MaximumCore.Status is ImportedFactStatus.Ready or ImportedFactStatus.NotApplicable &&
      MaximumCollectionLevel.Status is ImportedFactStatus.Ready or ImportedFactStatus.NotApplicable &&
      MaximumFavoriteItemLevel.Status is ImportedFactStatus.Ready or ImportedFactStatus.NotApplicable;

  private IEnumerable<ImportedIntegerFact> RequiredIntegerFacts()
  {
    yield return MaximumCharacterLevel;
    yield return MaximumLimitBreak;
    yield return MaximumBond;
    yield return MaximumSkill1;
    yield return MaximumSkill2;
    yield return MaximumBurstSkill;
    yield return MaximumEquipmentTier;
    yield return MaximumEquipmentEnhancement;
    yield return MaximumCubeLevel;
  }
}

public sealed record CharacterCatalogDiagnostic(string Code, int OccurrenceCount);

public sealed record CharacterCatalogExtraction(
    IReadOnlyList<ImportedCharacterDefinitionCandidate> Characters,
    IReadOnlyList<CharacterCatalogDiagnostic> Diagnostics,
    Sha256Digest CanonicalCandidateSha256)
{
  public int SourceResolvedCharacterCount =>
      Characters.Count(character => character.IsSourceResolved);
}

public sealed class CharacterCatalogSourceException : Exception
{
  public CharacterCatalogSourceException(string code)
      : base("The character catalog source failed a controlled validation.")
  {
    Code = ImportedCodeFact.Unresolved(code).ReasonCode!;
  }

  public string Code { get; }
}
