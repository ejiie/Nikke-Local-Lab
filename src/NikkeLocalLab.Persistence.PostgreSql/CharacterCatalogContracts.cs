using System.Security.Cryptography;
using NikkeLocalLab.Application.Importing;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Persistence.PostgreSql;

public sealed class CharacterCatalogIntegrityException : Exception
{
  public CharacterCatalogIntegrityException(string code)
      : base(code)
  {
    Code = code;
  }

  public string Code { get; }
}

public sealed record CharacterCatalogIdentityBinding
{
  public const string SupportedEncoderVersion = "hmac_sha256_v1";

  public CharacterCatalogIdentityBinding(string encoderVersion, Sha256Digest keyCheckSha256)
  {
    if (!string.Equals(encoderVersion, SupportedEncoderVersion, StringComparison.Ordinal))
    {
      throw new CharacterCatalogIntegrityException("identity_encoder_version_unsupported");
    }

    if (keyCheckSha256 == default)
    {
      throw new ArgumentException("The identity key check digest is required.", nameof(keyCheckSha256));
    }

    EncoderVersion = encoderVersion;
    KeyCheckSha256 = keyCheckSha256;
  }

  public string EncoderVersion { get; }

  public Sha256Digest KeyCheckSha256 { get; }

  public static CharacterCatalogIdentityBinding FromSecret(ReadOnlySpan<byte> localSecret)
  {
    var digest = SourceAliasFingerprintEncoder.CreateKeyCheck(localSecret);
    try
    {
      return new CharacterCatalogIdentityBinding(
          SupportedEncoderVersion,
          Sha256Digest.FromBytes(digest));
    }
    finally
    {
      CryptographicOperations.ZeroMemory(digest);
    }
  }
}

public enum CharacterCatalogFactStatus
{
  Ready,
  Unresolved,
  NotApplicable
}

public enum CharacterRarityCode
{
  R,
  Sr,
  Ssr
}

public enum CharacterCombatClassCode
{
  Attacker,
  Defender,
  Supporter
}

public enum CharacterWeaponCode
{
  AssaultRifle,
  MachineGun,
  RocketLauncher,
  Shotgun,
  SniperRifle,
  SubmachineGun
}

public enum CharacterElementCode
{
  Electric,
  Fire,
  Iron,
  Water,
  Wind
}

public enum CharacterManufacturerCode
{
  Abnormal,
  Elysion,
  Missilis,
  Pilgrim,
  Tetra
}

public enum CharacterCapabilityCode
{
  CharacterLevel,
  LimitBreak,
  CoreLevel,
  BondLevel,
  Cube,
  Skill1,
  Skill2,
  Burst,
  CollectionItem,
  FavoriteItem
}

public enum CharacterEquipmentSlot
{
  Head,
  Torso,
  Arms,
  Legs
}

public sealed record CharacterCatalogTextFact
{
  public CharacterCatalogTextFact(
      CharacterCatalogFactStatus status,
      string? value = null,
      string? unresolvedReasonCode = null)
  {
    var normalizedReason = CharacterCatalogFactValidation.ValidateShape(
        status,
        value is not null,
        unresolvedReasonCode);
    if (status == CharacterCatalogFactStatus.Ready &&
        (string.IsNullOrWhiteSpace(value) || value.Length > 128))
    {
      throw new CharacterCatalogIntegrityException("profile_fact_invalid");
    }

    Status = status;
    Value = value;
    UnresolvedReasonCode = normalizedReason;
  }

  public CharacterCatalogFactStatus Status { get; }

  public string? Value { get; }

  public string? UnresolvedReasonCode { get; }
}

public sealed record CharacterCatalogValueFact<T>
    where T : struct
{
  public CharacterCatalogValueFact(
      CharacterCatalogFactStatus status,
      T? value = null,
      string? unresolvedReasonCode = null)
  {
    Status = status;
    Value = value;
    UnresolvedReasonCode = CharacterCatalogFactValidation.ValidateShape(
        status,
        value.HasValue,
        unresolvedReasonCode);
  }

  public CharacterCatalogFactStatus Status { get; }

  public T? Value { get; }

  public string? UnresolvedReasonCode { get; }
}

public sealed record CharacterCatalogCapability
{
  public CharacterCatalogCapability(
      CharacterCapabilityCode code,
      CharacterCatalogFactStatus status,
      int? maximumLevel = null,
      string? unresolvedReasonCode = null)
  {
    var mayBeNotApplicable = code is CharacterCapabilityCode.CoreLevel or
        CharacterCapabilityCode.Cube or
        CharacterCapabilityCode.CollectionItem or
        CharacterCapabilityCode.FavoriteItem;
    var allowsZero = code is CharacterCapabilityCode.LimitBreak or
        CharacterCapabilityCode.CoreLevel;
    if ((status == CharacterCatalogFactStatus.NotApplicable && !mayBeNotApplicable) ||
        maximumLevel is < 0 or > 1_000_000 ||
        (status == CharacterCatalogFactStatus.Ready && !allowsZero && maximumLevel == 0))
    {
      throw new CharacterCatalogIntegrityException("capability_fact_invalid");
    }

    Code = code;
    Status = status;
    MaximumLevel = maximumLevel;
    UnresolvedReasonCode = CharacterCatalogFactValidation.ValidateShape(
        status,
        maximumLevel.HasValue,
        unresolvedReasonCode);
  }

  public CharacterCapabilityCode Code { get; }

  public CharacterCatalogFactStatus Status { get; }

  public int? MaximumLevel { get; }

  public string? UnresolvedReasonCode { get; }
}

public sealed record CharacterCatalogEquipmentCapability
{
  public CharacterCatalogEquipmentCapability(
      CharacterEquipmentSlot slot,
      CharacterCatalogValueFact<EntityUid> equipmentDefinitionUid,
      CharacterCatalogValueFact<int> maximumTier,
      CharacterCatalogValueFact<int> maximumTierTenEnhancementLevel,
      CharacterCatalogValueFact<bool> manufacturerMatch)
  {
    EquipmentDefinitionUid = RequireApplicable(
        equipmentDefinitionUid,
        nameof(equipmentDefinitionUid));
    MaximumTier = RequireApplicable(maximumTier, nameof(maximumTier));
    MaximumTierTenEnhancementLevel = RequireApplicable(
        maximumTierTenEnhancementLevel,
        nameof(maximumTierTenEnhancementLevel));
    ManufacturerMatch = manufacturerMatch ?? throw new ArgumentNullException(nameof(manufacturerMatch));
    if ((EquipmentDefinitionUid.Status == CharacterCatalogFactStatus.Ready &&
         EquipmentDefinitionUid.Value!.Value.Value == Guid.Empty) ||
        (MaximumTier.Value is < 0 or > 1_000_000) ||
        (MaximumTierTenEnhancementLevel.Value is < 0 or > 1_000_000))
    {
      throw new CharacterCatalogIntegrityException("equipment_capability_fact_invalid");
    }

    Slot = slot;
  }

  public CharacterEquipmentSlot Slot { get; }

  public CharacterCatalogValueFact<EntityUid> EquipmentDefinitionUid { get; }

  public CharacterCatalogValueFact<int> MaximumTier { get; }

  public CharacterCatalogValueFact<int> MaximumTierTenEnhancementLevel { get; }

  public CharacterCatalogValueFact<bool> ManufacturerMatch { get; }

  private static CharacterCatalogValueFact<T> RequireApplicable<T>(
      CharacterCatalogValueFact<T> fact,
      string parameterName)
      where T : struct
  {
    ArgumentNullException.ThrowIfNull(fact, parameterName);
    if (fact.Status == CharacterCatalogFactStatus.NotApplicable)
    {
      throw new CharacterCatalogIntegrityException("equipment_capability_fact_invalid");
    }

    return fact;
  }
}

public sealed record CharacterCatalogDefinition(
    SourceAliasFingerprint SourceAliasFingerprint,
    Sha256Digest DefinitionContentSha256,
    CharacterCatalogTextFact DisplayName,
    CharacterCatalogValueFact<CharacterRarityCode> Rarity,
    CharacterCatalogValueFact<CharacterCombatClassCode> CombatClass,
    CharacterCatalogValueFact<CharacterWeaponCode> Weapon,
    CharacterCatalogValueFact<CharacterElementCode> Element,
    CharacterCatalogValueFact<CharacterManufacturerCode> Manufacturer,
    IReadOnlyList<CharacterCatalogCapability> Capabilities,
    IReadOnlyList<CharacterCatalogEquipmentCapability> Equipment);

public sealed record CharacterCatalogPublication(
    CharacterCatalogIdentityBinding IdentityBinding,
    IReadOnlyList<CharacterCatalogDefinition> Definitions);

public sealed record CharacterCatalogMemberReceipt(
    int Ordinal,
    EntityUid CharacterUid,
    EntityUid CharacterDefinitionVersionUid);

public sealed record CharacterCatalogImportReceipt(
    ImportReceipt Import,
    EntityUid CharacterCatalogSnapshotUid,
    Sha256Digest CatalogManifestSha256,
    IReadOnlyList<CharacterCatalogMemberReceipt> Members);

internal static class CharacterCatalogFactValidation
{
  public static string? ValidateShape(
      CharacterCatalogFactStatus status,
      bool hasValue,
      string? unresolvedReasonCode)
  {
    var isValid = status switch
    {
      CharacterCatalogFactStatus.Ready => hasValue && unresolvedReasonCode is null,
      CharacterCatalogFactStatus.Unresolved => !hasValue && unresolvedReasonCode is not null,
      CharacterCatalogFactStatus.NotApplicable => !hasValue && unresolvedReasonCode is null,
      _ => false
    };
    if (!isValid)
    {
      throw new CharacterCatalogIntegrityException("fact_shape_invalid");
    }

    return unresolvedReasonCode is null
        ? null
        : ControlledCode.Require(unresolvedReasonCode, nameof(unresolvedReasonCode));
  }
}
