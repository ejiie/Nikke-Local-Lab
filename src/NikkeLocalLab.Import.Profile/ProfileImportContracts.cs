using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Import.Profile;

public static class SanitizedProfileDraftContract
{
  public const string SchemaCode = "nll/sanitized-profile-draft/v1";
  public const string TransformerId = "offline-profile-sanitizer";
  public const string TransformerVersion = "v1";
  public const string RebaseTransformerId = "profile-catalog-rebase";
  public const string ReviewedOverrideTransformerId = "profile-reviewed-override";

  internal const string SourceNamespace = "nikke-staticdata";
  internal const string CharacterEntityKind = "character-resource";
  internal const string EquipmentEntityKind = "combat-support-equipment";
  internal const string CubeEntityKind = "combat-support-harmony-cube";
  internal const string GenericCollectionEntityKind = "combat-support-generic-collection";
  internal const string FavoriteEntityKind = "combat-support-favorite";
  internal const string ConsoleEntityKind = "combat-support-console";
  internal const string OverloadLegalValueEntityKind = "combat-support-overload-legal-value";

  internal const string SchemaCanonicalText = """
      nll/credential-bearing-profile-source-schema/v1
      root=uid:string,phase_1_initial_load:packet[],phase_2_after_click:packet[]
      packet=endpoint:string,url:string,data:object|null
      roster=characters[]:{name_code:int,lv:int,grade:int,core:int,combat:int,costume_id:int}
      detail=character_details[]:{name_code:int,lv:int,grade:int,core:int,combat:int,attractive_lv:int,skill1_lv:int,skill2_lv:int,ulti_skill_lv:int,equipment:4x3,cube:int+level,collection:int+level}
      state_effect=state_effects[]:{id:positive-integer-string,function_details[1]:{function_value:int}}
      outpost=outpost_info:{synchro_level:int,synchro_nonempty_slot_count:int,recycle_room_researches[9]:{tid:int,lv:int,exp:int}}
      selection=direct-properties-only
      state-effect-binding=same-detail-packet-and-exact-catalog-member
      character-range=exact-selected-character-catalog-member
      unknown-field=rejected-on-recognized-payload
      sensitive=root.uid,packet.endpoint,packet.url,data.trace_id,credential-payloads:dropped
      raw-source-path-hash-time=not-persisted
      """;

  internal const string RebaseSourceCanonicalText = """
      nll/profile-catalog-rebase-source/v1
      input=nll/sanitized-profile-draft/v1
      mapping=typed-explicit-definition-uid-map
      target-binding=exact-dual-snapshot
      string-rewrite=prohibited
      derived-fields=semantic-options,readiness,canonical-hash
      """;

  internal const string ReviewedOverrideSourceCanonicalText = """
      nll/profile-reviewed-override-source/v1
      input=nll/sanitized-profile-draft/v1
      override=typed-source-free-bond-or-manufacturer-fact
      original-observation=preserved
      reason=required-controlled-code
      derived-fields=semantic-options,readiness,canonical-hash
      """;

  public static Sha256Digest SourceSchemaSha256 { get; } =
      Sha256Digest.ComputeUtf8(SchemaCanonicalText.Replace("\r\n", "\n", StringComparison.Ordinal));

  public static Sha256Digest RebaseSourceSchemaSha256 { get; } =
      Sha256Digest.ComputeUtf8(
          RebaseSourceCanonicalText.Replace("\r\n", "\n", StringComparison.Ordinal));

  public static Sha256Digest ReviewedOverrideSourceSchemaSha256 { get; } =
      Sha256Digest.ComputeUtf8(
          ReviewedOverrideSourceCanonicalText.Replace("\r\n", "\n", StringComparison.Ordinal));

  public static ExtractorDescriptor Transformer { get; } = new(
      TransformerId,
      TransformerVersion,
      SourceSchemaSha256);

  public static ExtractorDescriptor RebaseTransformer { get; } = new(
      RebaseTransformerId,
      TransformerVersion,
      RebaseSourceSchemaSha256);

  public static ExtractorDescriptor ReviewedOverrideTransformer { get; } = new(
      ReviewedOverrideTransformerId,
      TransformerVersion,
      ReviewedOverrideSourceSchemaSha256);
}

internal enum SanitizedProfileTransformerProfile
{
  OfflineRawSanitizer,
  CatalogRebase,
  ReviewedOverride
}

public enum CharacterLevelAuthorityPolicy
{
  RosterObservationV1,
  DetailObservationV1
}

public static class CharacterLevelAuthorityPolicyCodes
{
  public const string RosterObservationV1 = "roster_observation/v1";
  public const string DetailObservationV1 = "detail_observation/v1";

  public static string ToCode(CharacterLevelAuthorityPolicy value) => value switch
  {
    CharacterLevelAuthorityPolicy.RosterObservationV1 => RosterObservationV1,
    CharacterLevelAuthorityPolicy.DetailObservationV1 => DetailObservationV1,
    _ => throw new ArgumentOutOfRangeException(nameof(value))
  };
}

public sealed record OfflineProfileImportOptions
{
  public OfflineProfileImportOptions(
      DateTimeOffset importedAtUtc,
      Sha256Digest transformerBinarySha256,
      CharacterLevelAuthorityPolicy? characterLevelAuthority = null)
  {
    if (importedAtUtc.Offset != TimeSpan.Zero || importedAtUtc.Ticks % 10 != 0)
    {
      throw new ArgumentException("The import timestamp must be a PostgreSQL-safe UTC value.", nameof(importedAtUtc));
    }

    if (characterLevelAuthority.HasValue && !Enum.IsDefined(characterLevelAuthority.Value))
    {
      throw new ArgumentOutOfRangeException(nameof(characterLevelAuthority));
    }

    if (transformerBinarySha256 == default)
    {
      throw new ArgumentException(
          "The transformer binary SHA-256 must be complete.",
          nameof(transformerBinarySha256));
    }

    ImportedAtUtc = importedAtUtc;
    TransformerBinarySha256 = transformerBinarySha256;
    CharacterLevelAuthority = characterLevelAuthority;
    SemanticOptionsSha256 = ComputeSemanticOptionsSha256(
        characterLevelAuthority,
        SanitizedProfileTransformerProfile.OfflineRawSanitizer);
  }

  public DateTimeOffset ImportedAtUtc { get; }

  public Sha256Digest TransformerBinarySha256 { get; }

  public CharacterLevelAuthorityPolicy? CharacterLevelAuthority { get; }

  public Sha256Digest SemanticOptionsSha256 { get; }

  internal static Sha256Digest ComputeSemanticOptionsSha256(
      CharacterLevelAuthorityPolicy? authority,
      SanitizedProfileTransformerProfile transformerProfile)
  {
    var authorityCode = authority.HasValue
        ? CharacterLevelAuthorityPolicyCodes.ToCode(authority.Value)
        : "unresolved";
    return Sha256Digest.ComputeUtf8(string.Join(
        '\n',
        "nll/profile-sanitizer-options/v1",
        $"transformer-profile={TransformerProfileCode(transformerProfile)}",
        $"level-authority={authorityCode}",
        "unknown-field=strict",
        "raw-source-hash=prohibited"));
  }

  internal static string TransformerProfileCode(
      SanitizedProfileTransformerProfile profile) => profile switch
      {
        SanitizedProfileTransformerProfile.OfflineRawSanitizer => "offline-raw-sanitizer",
        SanitizedProfileTransformerProfile.CatalogRebase => "catalog-rebase",
        SanitizedProfileTransformerProfile.ReviewedOverride => "reviewed-override",
        _ => throw new ArgumentOutOfRangeException(nameof(profile))
      };
}

public enum ProfileImportFactStatus
{
  Ready,
  Unresolved
}

public sealed record ProfileImportFact<T>
    where T : struct
{
  private ProfileImportFact(ProfileImportFactStatus status, T? value, string? reasonCode)
  {
    var valid = status switch
    {
      ProfileImportFactStatus.Ready => value.HasValue && reasonCode is null,
      ProfileImportFactStatus.Unresolved => !value.HasValue && reasonCode is not null,
      _ => false
    };
    if (!valid)
    {
      throw new ArgumentException("A profile import fact has an invalid shape.");
    }

    Status = status;
    Value = value;
    ReasonCode = reasonCode is null ? null : ControlledCode.Require(reasonCode, nameof(reasonCode));
  }

  public ProfileImportFactStatus Status { get; }

  public T? Value { get; }

  public string? ReasonCode { get; }

  public static ProfileImportFact<T> Ready(T value) =>
      new(ProfileImportFactStatus.Ready, value, null);

  public static ProfileImportFact<T> Unresolved(string reasonCode) =>
      new(ProfileImportFactStatus.Unresolved, null, reasonCode);
}

public enum ProfileImportEquipmentSlot
{
  Head,
  Torso,
  Arms,
  Legs
}

public enum ProfileImportCombatRole
{
  Attacker,
  Defender,
  Supporter
}

public enum ProfileImportWeaponClass
{
  AssaultRifle,
  RocketLauncher,
  SniperRifle,
  MachineGun,
  Shotgun,
  SubmachineGun
}

public enum ProfileImportManufacturer
{
  Elysion,
  Missilis,
  Tetra,
  Pilgrim,
  Abnormal
}

public enum ProfileImportAttachmentState
{
  Equipped,
  Unequipped
}

public enum ProfileImportCollectionKind
{
  Detached,
  GenericCollection,
  Favorite
}

public enum ProfileImportConsoleCoordinate
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

public enum ProfileImportValueUnit
{
  Absolute,
  Ratio,
  Percent,
  Count
}

public readonly record struct ProfileImportExactValue
{
  public ProfileImportExactValue(long unscaledValue, int decimalScale)
  {
    if (decimalScale is < 0 or > 9)
    {
      throw new ArgumentOutOfRangeException(nameof(decimalScale));
    }

    UnscaledValue = unscaledValue;
    DecimalScale = decimalScale;
  }

  public long UnscaledValue { get; }

  public int DecimalScale { get; }
}

public sealed record ProfileImportCatalogBinding
{
  public ProfileImportCatalogBinding(
      EntityUid catalogSnapshotUid,
      EntityUid datasetSnapshotUid,
      Sha256Digest manifestSha256)
  {
    if (catalogSnapshotUid.Value == Guid.Empty || datasetSnapshotUid.Value == Guid.Empty ||
        manifestSha256 == default)
    {
      throw new ArgumentException("A profile import catalog binding must be complete.");
    }

    CatalogSnapshotUid = catalogSnapshotUid;
    DatasetSnapshotUid = datasetSnapshotUid;
    ManifestSha256 = manifestSha256;
  }

  public EntityUid CatalogSnapshotUid { get; }

  public EntityUid DatasetSnapshotUid { get; }

  public Sha256Digest ManifestSha256 { get; }
}

public enum ProfileAliasResolutionStatus
{
  Resolved,
  Missing,
  Ambiguous,
  CatalogMismatch
}

public sealed record ProfileAliasResolution<T>
    where T : class
{
  private ProfileAliasResolution(ProfileAliasResolutionStatus status, T? value)
  {
    if (!Enum.IsDefined(status) ||
        (status == ProfileAliasResolutionStatus.Resolved) != (value is not null))
    {
      throw new ArgumentException("An alias resolution has an invalid shape.");
    }

    Status = status;
    Value = value;
  }

  public ProfileAliasResolutionStatus Status { get; }

  public T? Value { get; }

  public static ProfileAliasResolution<T> Resolved(T value) =>
      new(ProfileAliasResolutionStatus.Resolved, value ?? throw new ArgumentNullException(nameof(value)));

  public static ProfileAliasResolution<T> Missing() =>
      new(ProfileAliasResolutionStatus.Missing, null);

  public static ProfileAliasResolution<T> Ambiguous() =>
      new(ProfileAliasResolutionStatus.Ambiguous, null);

  public static ProfileAliasResolution<T> CatalogMismatch() =>
      new(ProfileAliasResolutionStatus.CatalogMismatch, null);
}

public sealed record ResolvedProfileCharacter(
    EntityUid CharacterUid,
    ProfileImportCombatRole CombatRole,
    ProfileImportManufacturer Manufacturer,
    ProfileImportWeaponClass WeaponClass,
    int MaximumCharacterLevel,
    int MaximumLimitBreak,
    int MaximumCoreLevel,
    int MaximumBondLevel,
    int MaximumSkill1Level,
    int MaximumSkill2Level,
    int MaximumBurstLevel);

public sealed record ResolvedProfileEquipment(
    EntityUid DefinitionUid,
    ProfileImportEquipmentSlot Slot,
    ProfileImportCombatRole CombatRole,
    ProfileImportFact<ProfileImportManufacturer> Manufacturer,
    int Tier,
    int MaximumEnhancementLevel,
    bool OverloadEligible);

public sealed record ResolvedProfileCube(
    EntityUid DefinitionUid,
    int MaximumLevel,
    ProfileImportCombatRole? ApplicableCombatRole);

public sealed record ResolvedProfileCollection(
    EntityUid DefinitionUid,
    ProfileImportCollectionKind Kind,
    int MaximumLevel,
    EntityUid? ApplicableCharacterUid,
    ProfileImportWeaponClass? ApplicableWeaponClass);

public sealed record ResolvedProfileConsole(
    EntityUid DefinitionUid,
    ProfileImportConsoleCoordinate Coordinate,
    int SelectedLevel,
    int MaximumLevel,
    ProfileImportFact<int> SelectedLevelMinimumSynchroLevel);

public sealed record ResolvedProfileOverloadValue(
    EntityUid OptionDefinitionUid,
    ProfileImportValueUnit Unit,
    long SourceRawValue,
    ProfileImportExactValue ApplicationValue);

public interface IProfileCatalogAliasResolver
{
  ProfileImportCatalogBinding CharacterCatalog { get; }

  ProfileImportCatalogBinding CombatSupportCatalog { get; }

  ProfileAliasResolution<ResolvedProfileCharacter> ResolveCharacter(
      SourceAliasFingerprint sourceAlias);

  ProfileAliasResolution<ResolvedProfileEquipment> ResolveEquipment(
      SourceAliasFingerprint sourceAlias);

  ProfileAliasResolution<ResolvedProfileCube> ResolveCube(
      SourceAliasFingerprint sourceAlias);

  ProfileAliasResolution<ResolvedProfileCollection> ResolveGenericCollection(
      SourceAliasFingerprint sourceAlias);

  ProfileAliasResolution<ResolvedProfileCollection> ResolveFavorite(
      SourceAliasFingerprint sourceAlias);

  ProfileAliasResolution<ResolvedProfileConsole> ResolveConsole(
      SourceAliasFingerprint sourceAlias,
      int selectedLevel);

  ProfileAliasResolution<ResolvedProfileOverloadValue> ResolveOverloadValue(
      SourceAliasFingerprint sourceAlias);
}

public sealed record SanitizedCharacterLevelObservation(
    int RosterLevel,
    int DetailLevel,
    ProfileImportFact<int> ResolvedBattleLevel,
    string? AuthorityPolicyCode);

public sealed record SanitizedOverloadLine(
    int LineIndex,
    EntityUid OptionDefinitionUid,
    ProfileImportValueUnit Unit,
    ProfileImportExactValue ExactValue);

public sealed record SanitizedEquipmentSelection(
    ProfileImportEquipmentSlot Slot,
    ProfileImportAttachmentState State,
    EntityUid? DefinitionUid,
    int? EnhancementLevel,
    ProfileImportFact<bool>? ManufacturerMatchedObservation,
    ProfileImportFact<bool>? ResolvedManufacturerMatched,
    IReadOnlyList<SanitizedOverloadLine> OverloadLines);

public sealed record SanitizedCubeSelection(
    ProfileImportAttachmentState State,
    EntityUid? DefinitionUid,
    int? Level);

public sealed record SanitizedCollectionSelection(
    ProfileImportCollectionKind Kind,
    EntityUid? DefinitionUid,
    int? Level);

public sealed record SanitizedCharacterBuildDraft(
    EntityUid CharacterUid,
    SanitizedCharacterLevelObservation Level,
    int LimitBreak,
    int CoreLevel,
    int BondLevelObservation,
    ProfileImportFact<int> ResolvedBondLevel,
    int Skill1Level,
    int Skill2Level,
    int BurstLevel,
    long RosterCombatPowerObservation,
    long DetailCombatPowerObservation,
    IReadOnlyList<SanitizedEquipmentSelection> Equipment,
    SanitizedCubeSelection Cube,
    SanitizedCollectionSelection Collection);

public sealed record SanitizedConsoleState(
    ProfileImportConsoleCoordinate Coordinate,
    EntityUid DefinitionUid,
    int Level,
    long ObservedExperience);

public sealed record SanitizedAccountCombatStateDraft(
    int SynchroLevel,
    int OccupiedSynchroSlotCountObservation,
    IReadOnlyList<SanitizedConsoleState> Consoles);

public enum SanitizedProfileReviewedOverrideKind
{
  BondLevel,
  EquipmentManufacturerMatched
}

public static class SanitizedProfileReviewedOverrideReasonCodes
{
  public const string UserReviewed = "user_reviewed_override";
  public const string OriginalClientVerified = "original_client_verified_override";

  internal static bool IsAllowed(string? value) =>
      value is UserReviewed or OriginalClientVerified;
}

public sealed record SanitizedProfileReviewedOverrideRequest(
    SanitizedProfileReviewedOverrideKind Kind,
    EntityUid CharacterUid,
    ProfileImportEquipmentSlot? EquipmentSlot,
    int? IntegerValue,
    bool? BooleanValue,
    string ReasonCode);

public sealed record SanitizedProfileReviewedOverride(
    SanitizedProfileReviewedOverrideKind Kind,
    EntityUid CharacterUid,
    ProfileImportEquipmentSlot? EquipmentSlot,
    int? IntegerValue,
    bool? BooleanValue,
    string OriginalReasonCode,
    string ReasonCode);

public enum ProfileCaptureAtomicity
{
  Unresolved
}

public enum CredentialBearingSourceHashPolicy
{
  Prohibited
}

public sealed record SanitizedProfileImportProvenance(
    string SchemaCode,
    Sha256Digest SourceSchemaSha256,
    string TransformerId,
    string TransformerVersion,
    Sha256Digest TransformerFingerprintSha256,
    Sha256Digest TransformerBinarySha256,
    Sha256Digest SemanticOptionsSha256,
    Sha256Digest SanitizedPayloadSha256,
    DateTimeOffset ImportedAtUtc,
    ProfileImportFact<DateTimeOffset> CaptureTime,
    ProfileCaptureAtomicity CaptureAtomicity,
    CredentialBearingSourceHashPolicy SourceHashPolicy);

public sealed record SanitizedProfileDraft(
    SanitizedProfileImportProvenance Provenance,
    ProfileImportCatalogBinding CharacterCatalog,
    ProfileImportCatalogBinding CombatSupportCatalog,
    SanitizedAccountCombatStateDraft AccountState,
    IReadOnlyList<SanitizedCharacterBuildDraft> Builds,
    IReadOnlyList<SanitizedProfileReviewedOverride> ReviewedOverrides,
    bool CanMaterializeLocalAccountProfile,
    bool IsLocalAccountProfileWriteReady);

public enum ProfileImportDiagnosticSeverity
{
  Warning,
  Error
}

public enum ProfileImportDiagnosticScope
{
  Capture,
  Roster,
  Character,
  Equipment,
  Overload,
  Console,
  Catalog
}

public sealed record ProfileImportDiagnostic
{
  public ProfileImportDiagnostic(
      string code,
      ProfileImportDiagnosticSeverity severity,
      ProfileImportDiagnosticScope scope,
      int count)
  {
    Code = ControlledCode.Require(code, nameof(code));
    if (!Enum.IsDefined(severity) || !Enum.IsDefined(scope) || count <= 0)
    {
      throw new ArgumentException("A profile import diagnostic has an invalid shape.");
    }

    Severity = severity;
    Scope = scope;
    Count = count;
  }

  public string Code { get; }

  public ProfileImportDiagnosticSeverity Severity { get; }

  public ProfileImportDiagnosticScope Scope { get; }

  public int Count { get; }
}

public sealed record SanitizedProfileImportResult(
    SanitizedProfileDraft? Draft,
    IReadOnlyList<ProfileImportDiagnostic> Diagnostics)
{
  public bool Succeeded => Draft is not null &&
      Diagnostics.All(static item => item.Severity != ProfileImportDiagnosticSeverity.Error);
}

public sealed record CredentialBearingProfileCoverage(
    int RosterObservationCount,
    int DetailObservationCount,
    int CharacterLevelDifferenceCount,
    int EquipmentCoordinateCount,
    int OverloadReferenceCount,
    int StateEffectResolvedReferenceCount,
    int SparseOverloadEquipmentCount,
    int ConsoleObservationCount);

public sealed record CredentialBearingProfileCoverageResult(
    CredentialBearingProfileCoverage? Coverage,
    IReadOnlyList<ProfileImportDiagnostic> Diagnostics)
{
  public bool Succeeded => Coverage is not null &&
      Diagnostics.All(static item => item.Severity != ProfileImportDiagnosticSeverity.Error);
}
