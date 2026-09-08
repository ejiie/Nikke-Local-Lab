using System.Buffers.Binary;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;
using static NikkeLocalLab.Persistence.PostgreSql.LocalProfileContractGuard;

namespace NikkeLocalLab.Persistence.PostgreSql;

public sealed class LocalAccountProfileIntegrityException : Exception
{
  public LocalAccountProfileIntegrityException(string code)
      : base(code)
  {
    Code = RequireCode(code);
  }

  public string Code { get; }

  internal static string RequireCode(string value)
  {
    if (string.IsNullOrEmpty(value) || value.Length > 64 ||
        value[0] is < 'a' or > 'z' ||
        value.Any(static character =>
            !((character >= 'a' && character <= 'z') ||
              (character >= '0' && character <= '9') ||
              character is '.' or '_' or '-')))
    {
      throw new ArgumentException("A profile code must be controlled.", nameof(value));
    }

    return value;
  }
}

public enum LocalProfileFactStatus
{
  Ready,
  Unresolved,
  NotApplicable
}

public readonly record struct LocalProfileReasonCode
{
  public LocalProfileReasonCode(string code)
  {
    Code = LocalAccountProfileIntegrityException.RequireCode(code);
  }

  public string Code { get; }

  public static LocalProfileReasonCode NotObserved => new("not_observed");

  public static LocalProfileReasonCode SourceAmbiguous => new("source_ambiguous");

  public static LocalProfileReasonCode Unsupported => new("unsupported");

  public static LocalProfileReasonCode SemanticsUnresolved => new("semantics_unresolved");

  public static LocalProfileReasonCode UserChoiceMissing => new("user_choice_missing");

  public override string ToString() => Code ?? string.Empty;
}

public enum LocalProfileValidationMode
{
  Research,
  GameLegal
}

public enum LocalProfileMaterializationPolicy
{
  ExplicitV1,
  CombatMaxV1
}

public enum LocalProfileRevisionOrigin
{
  UserEdit,
  CombatMaxV1,
  OfflineSanitizedImport,
  Rebase
}

public enum LocalEquipmentSlot
{
  Head,
  Torso,
  Arms,
  Legs
}

public enum LocalEquipmentState
{
  Equipped,
  Unequipped,
  Unresolved
}

public enum LocalOptionalSelectionState
{
  Equipped,
  Unequipped,
  Unresolved
}

public enum LocalCollectionSelectionKind
{
  Detached,
  GenericCollection,
  Favorite,
  Unresolved,
  NotApplicable
}

public enum LocalConsoleCoordinate
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

public enum LocalProfileValueUnit
{
  Absolute,
  Ratio,
  Percent,
  Count
}

public enum LocalSessionStatus
{
  Active,
  Expired,
  Revoked
}

public readonly record struct LocalProfileExactValue
{
  public LocalProfileExactValue(long unscaledValue, int decimalScale)
  {
    if (decimalScale is < 0 or > 9)
    {
      throw new LocalAccountProfileIntegrityException("profile_exact_value_invalid");
    }

    UnscaledValue = unscaledValue;
    DecimalScale = decimalScale;
  }

  public long UnscaledValue { get; }

  public int DecimalScale { get; }
}

public sealed record LocalProfileFact<T>
    where T : struct
{
  public LocalProfileFact(
      LocalProfileFactStatus status,
      T? value = null,
      LocalProfileReasonCode? reasonCode = null)
  {
    var valid = status switch
    {
      LocalProfileFactStatus.Ready => value.HasValue && reasonCode is null,
      LocalProfileFactStatus.Unresolved => !value.HasValue && reasonCode.HasValue,
      LocalProfileFactStatus.NotApplicable => !value.HasValue && reasonCode is null,
      _ => false
    };
    if (!valid)
    {
      throw new LocalAccountProfileIntegrityException("profile_fact_shape_invalid");
    }

    if (reasonCode is { } reason && string.IsNullOrEmpty(reason.Code))
    {
      throw new LocalAccountProfileIntegrityException("profile_reason_code_invalid");
    }

    if (value is Enum enumValue && !Enum.IsDefined(enumValue.GetType(), enumValue))
    {
      throw new LocalAccountProfileIntegrityException("profile_fact_value_invalid");
    }

    Status = status;
    Value = value;
    ReasonCode = reasonCode;
  }

  public LocalProfileFactStatus Status { get; }

  public T? Value { get; }

  public LocalProfileReasonCode? ReasonCode { get; }

  public static LocalProfileFact<T> Ready(T value) => new(LocalProfileFactStatus.Ready, value);

  public static LocalProfileFact<T> Unresolved(LocalProfileReasonCode reasonCode) =>
      new(LocalProfileFactStatus.Unresolved, reasonCode: reasonCode);

  public static LocalProfileFact<T> NotApplicable() => new(LocalProfileFactStatus.NotApplicable);
}

public sealed record LocalConsoleStateWrite
{
  public LocalConsoleStateWrite(
      LocalConsoleCoordinate coordinate,
      EntityUid consoleDefinitionUid,
      LocalProfileFact<int> level,
      LocalProfileFact<long> observedExperience)
  {
    RequireEnum(coordinate, "profile_console_coordinate_invalid");
    RequireUid(consoleDefinitionUid, "profile_console_definition_invalid");
    ArgumentNullException.ThrowIfNull(level);
    ArgumentNullException.ThrowIfNull(observedExperience);
    if (level.Status == LocalProfileFactStatus.NotApplicable ||
        (level.Value is { } resolvedLevel && resolvedLevel is < 0 or > 1_000_000) ||
        observedExperience.Status == LocalProfileFactStatus.NotApplicable ||
        observedExperience.Value is < 0)
    {
      throw new LocalAccountProfileIntegrityException("profile_console_value_invalid");
    }

    Coordinate = coordinate;
    ConsoleDefinitionUid = consoleDefinitionUid;
    Level = level;
    ObservedExperience = observedExperience;
  }

  public LocalConsoleCoordinate Coordinate { get; }

  public EntityUid ConsoleDefinitionUid { get; }

  public LocalProfileFact<int> Level { get; }

  public LocalProfileFact<long> ObservedExperience { get; }
}

public sealed record LocalOwnedCubeWrite
{
  public LocalOwnedCubeWrite(EntityUid definitionUid, int level)
  {
    if (definitionUid.Value == Guid.Empty || level is < 1 or > 15)
    {
      throw new LocalAccountProfileIntegrityException("profile_account_cube_invalid");
    }

    DefinitionUid = definitionUid;
    Level = level;
  }

  public EntityUid DefinitionUid { get; }

  public int Level { get; }
}

public sealed record LocalAccountCombatStateWrite
{
  public LocalAccountCombatStateWrite(
      LocalProfileFact<int> synchroLevel,
      IEnumerable<LocalConsoleStateWrite> consoles,
      LocalProfileValidationMode validationMode,
      LocalProfileRevisionOrigin origin = LocalProfileRevisionOrigin.UserEdit)
      : this(synchroLevel, consoles, validationMode, origin, null)
  {
  }

  public LocalAccountCombatStateWrite(
      LocalProfileFact<int> synchroLevel,
      IEnumerable<LocalConsoleStateWrite> consoles,
      LocalProfileValidationMode validationMode,
      LocalProfileRevisionOrigin origin,
      IEnumerable<LocalOwnedCubeWrite>? cubes)
  {
    ArgumentNullException.ThrowIfNull(synchroLevel);
    ArgumentNullException.ThrowIfNull(consoles);
    RequireEnum(validationMode, "profile_validation_mode_invalid");
    RequireEnum(origin, "profile_revision_origin_invalid");
    if (synchroLevel.Status == LocalProfileFactStatus.NotApplicable ||
        (synchroLevel.Value is { } value && value is < 1 or > 1_000_000))
    {
      throw new LocalAccountProfileIntegrityException("profile_synchro_level_invalid");
    }

    var normalized = consoles.OrderBy(static item => item.Coordinate).ToArray();
    if (normalized.Length != 9 || normalized.Any(static item => item is null) ||
        !normalized.Select(static item => item.Coordinate)
            .SequenceEqual(Enum.GetValues<LocalConsoleCoordinate>().Order()))
    {
      throw new LocalAccountProfileIntegrityException("profile_console_set_invalid");
    }

    SynchroLevel = synchroLevel;
    Consoles = Array.AsReadOnly(normalized);
    ValidationMode = validationMode;
    Origin = origin;
    var ownedCubes = (cubes ?? []).OrderBy(static item => item.DefinitionUid.ToString(), StringComparer.Ordinal).ToArray();
    if (ownedCubes.Select(static item => item.DefinitionUid).Distinct().Count() != ownedCubes.Length)
    {
      throw new LocalAccountProfileIntegrityException("profile_account_cube_duplicate");
    }

    Cubes = Array.AsReadOnly(ownedCubes);
  }

  public LocalProfileFact<int> SynchroLevel { get; }

  public IReadOnlyList<LocalConsoleStateWrite> Consoles { get; }

  public IReadOnlyList<LocalOwnedCubeWrite> Cubes { get; }

  public LocalProfileValidationMode ValidationMode { get; }

  public LocalProfileRevisionOrigin Origin { get; }
}

public sealed record LocalOverloadLineWrite
{
  public LocalOverloadLineWrite(
      int lineIndex,
      EntityUid optionDefinitionUid,
      LocalProfileValueUnit unit,
      LocalProfileExactValue exactValue)
  {
    if (lineIndex is < 1 or > 3)
    {
      throw new LocalAccountProfileIntegrityException("profile_overload_line_invalid");
    }

    RequireUid(optionDefinitionUid, "profile_overload_definition_invalid");
    RequireEnum(unit, "profile_value_unit_invalid");
    LineIndex = lineIndex;
    OptionDefinitionUid = optionDefinitionUid;
    Unit = unit;
    ExactValue = exactValue;
  }

  public int LineIndex { get; }

  public EntityUid OptionDefinitionUid { get; }

  public LocalProfileValueUnit Unit { get; }

  public LocalProfileExactValue ExactValue { get; }
}

public sealed record LocalEquipmentWrite
{
  public LocalEquipmentWrite(
      LocalEquipmentSlot slot,
      LocalEquipmentState state,
      EntityUid? equipmentDefinitionUid,
      int enhancementLevel,
      LocalProfileFact<bool>? manufacturerMatched = null,
      IEnumerable<LocalOverloadLineWrite>? overloadLines = null,
      LocalProfileReasonCode? unresolvedReasonCode = null)
      : this(
          slot,
          state,
          equipmentDefinitionUid,
          LocalProfileFact<int>.Ready(enhancementLevel),
          manufacturerMatched,
          overloadLines,
          unresolvedReasonCode)
  {
  }

  public LocalEquipmentWrite(
      LocalEquipmentSlot slot,
      LocalEquipmentState state,
      EntityUid? equipmentDefinitionUid = null,
      LocalProfileFact<int>? enhancementLevel = null,
      LocalProfileFact<bool>? manufacturerMatched = null,
      IEnumerable<LocalOverloadLineWrite>? overloadLines = null,
      LocalProfileReasonCode? unresolvedReasonCode = null)
  {
    RequireEnum(slot, "profile_equipment_slot_invalid");
    RequireEnum(state, "profile_equipment_state_invalid");
    var lines = (overloadLines ?? []).OrderBy(static item => item.LineIndex).ToArray();
    if (lines.Any(static item => item is null) || lines.Length > 3 ||
        lines.Select(static item => item.LineIndex).Distinct().Count() != lines.Length)
    {
      throw new LocalAccountProfileIntegrityException("profile_overload_line_set_invalid");
    }

    var valid = state switch
    {
      LocalEquipmentState.Equipped =>
          equipmentDefinitionUid.HasValue &&
          equipmentDefinitionUid.Value.Value != Guid.Empty &&
          enhancementLevel is not null &&
          enhancementLevel.Status != LocalProfileFactStatus.NotApplicable &&
          (enhancementLevel.Value is null or (>= 0 and <= 5)) &&
          manufacturerMatched is not null &&
          unresolvedReasonCode is null,
      LocalEquipmentState.Unequipped =>
          equipmentDefinitionUid is null && enhancementLevel is null &&
          lines.Length == 0 &&
          manufacturerMatched is { Status: LocalProfileFactStatus.NotApplicable } &&
          unresolvedReasonCode is null,
      LocalEquipmentState.Unresolved =>
          equipmentDefinitionUid is null && enhancementLevel is null && lines.Length == 0 &&
          manufacturerMatched is null && unresolvedReasonCode.HasValue,
      _ => false
    };
    if (!valid)
    {
      throw new LocalAccountProfileIntegrityException("profile_equipment_shape_invalid");
    }

    Slot = slot;
    State = state;
    EquipmentDefinitionUid = equipmentDefinitionUid;
    EnhancementLevel = enhancementLevel;
    ManufacturerMatched = manufacturerMatched;
    OverloadLines = Array.AsReadOnly(lines);
    UnresolvedReasonCode = unresolvedReasonCode;
  }

  public LocalEquipmentSlot Slot { get; }

  public LocalEquipmentState State { get; }

  public EntityUid? EquipmentDefinitionUid { get; }

  public LocalProfileFact<int>? EnhancementLevel { get; }

  public LocalProfileFact<bool>? ManufacturerMatched { get; }

  public IReadOnlyList<LocalOverloadLineWrite> OverloadLines { get; }

  public LocalProfileReasonCode? UnresolvedReasonCode { get; }
}

public sealed record LocalCubeSelectionWrite
{
  public LocalCubeSelectionWrite(
      LocalOptionalSelectionState state,
      EntityUid? definitionUid,
      int level,
      LocalProfileReasonCode? unresolvedReasonCode = null)
      : this(
          state,
          definitionUid,
          LocalProfileFact<int>.Ready(level),
          unresolvedReasonCode)
  {
  }

  public LocalCubeSelectionWrite(
      LocalOptionalSelectionState state,
      EntityUid? definitionUid = null,
      LocalProfileFact<int>? level = null,
      LocalProfileReasonCode? unresolvedReasonCode = null)
  {
    RequireEnum(state, "profile_cube_state_invalid");
    var valid = state switch
    {
      LocalOptionalSelectionState.Equipped =>
          definitionUid.HasValue && definitionUid.Value.Value != Guid.Empty &&
          level is not null && level.Status != LocalProfileFactStatus.NotApplicable &&
          (level.Value is null or (>= 1 and <= 15)) && unresolvedReasonCode is null,
      LocalOptionalSelectionState.Unequipped =>
          definitionUid is null && level is null && unresolvedReasonCode is null,
      LocalOptionalSelectionState.Unresolved =>
          definitionUid is null && level is null && unresolvedReasonCode.HasValue,
      _ => false
    };
    if (!valid)
    {
      throw new LocalAccountProfileIntegrityException("profile_cube_shape_invalid");
    }

    State = state;
    DefinitionUid = definitionUid;
    Level = level;
    UnresolvedReasonCode = unresolvedReasonCode;
  }

  public LocalOptionalSelectionState State { get; }

  public EntityUid? DefinitionUid { get; }

  public LocalProfileFact<int>? Level { get; }

  public LocalProfileReasonCode? UnresolvedReasonCode { get; }
}

public sealed record LocalCollectionSelectionWrite
{
  public LocalCollectionSelectionWrite(
      LocalCollectionSelectionKind kind,
      EntityUid? definitionUid,
      int level,
      LocalProfileReasonCode? unresolvedReasonCode = null)
      : this(
          kind,
          definitionUid,
          LocalProfileFact<int>.Ready(level),
          unresolvedReasonCode)
  {
  }

  public LocalCollectionSelectionWrite(
      LocalCollectionSelectionKind kind,
      EntityUid? definitionUid = null,
      LocalProfileFact<int>? level = null,
      LocalProfileReasonCode? unresolvedReasonCode = null)
  {
    RequireEnum(kind, "profile_collection_kind_invalid");
    var selected = kind is LocalCollectionSelectionKind.GenericCollection or
        LocalCollectionSelectionKind.Favorite;
    var valid = selected
        ? definitionUid.HasValue && definitionUid.Value.Value != Guid.Empty &&
          level is not null && level.Status != LocalProfileFactStatus.NotApplicable &&
          (level.Value is null or (>= 0 and <= 1_000_000)) && unresolvedReasonCode is null
        : kind == LocalCollectionSelectionKind.Unresolved
            ? definitionUid is null && level is null && unresolvedReasonCode.HasValue
            : definitionUid is null && level is null && unresolvedReasonCode is null;
    if (!valid)
    {
      throw new LocalAccountProfileIntegrityException("profile_collection_shape_invalid");
    }

    Kind = kind;
    DefinitionUid = definitionUid;
    Level = level;
    UnresolvedReasonCode = unresolvedReasonCode;
  }

  public LocalCollectionSelectionKind Kind { get; }

  public EntityUid? DefinitionUid { get; }

  public LocalProfileFact<int>? Level { get; }

  public LocalProfileReasonCode? UnresolvedReasonCode { get; }
}

public sealed record LocalCharacterBuildWrite
{
  public LocalCharacterBuildWrite(
      EntityUid characterUid,
      int characterLevel,
      LocalProfileFact<int> limitBreak,
      LocalProfileFact<int> coreLevel,
      LocalProfileFact<int> bondLevel,
      int skill1Level,
      int skill2Level,
      int burstLevel,
      IEnumerable<LocalEquipmentWrite> equipment,
      LocalCubeSelectionWrite cube,
      LocalCollectionSelectionWrite collection,
      LocalProfileValidationMode validationMode,
      LocalProfileMaterializationPolicy materializationPolicy =
          LocalProfileMaterializationPolicy.ExplicitV1,
      LocalProfileRevisionOrigin origin = LocalProfileRevisionOrigin.UserEdit)
      : this(
          characterUid,
          characterLevel,
          limitBreak,
          coreLevel,
          bondLevel,
          LocalProfileFact<int>.Ready(skill1Level),
          LocalProfileFact<int>.Ready(skill2Level),
          LocalProfileFact<int>.Ready(burstLevel),
          equipment,
          cube,
          collection,
          validationMode,
          materializationPolicy,
          origin)
  {
  }

  public LocalCharacterBuildWrite(
      EntityUid characterUid,
      int characterLevel,
      LocalProfileFact<int> limitBreak,
      LocalProfileFact<int> coreLevel,
      LocalProfileFact<int> bondLevel,
      LocalProfileFact<int> skill1Level,
      LocalProfileFact<int> skill2Level,
      LocalProfileFact<int> burstLevel,
      IEnumerable<LocalEquipmentWrite> equipment,
      LocalCubeSelectionWrite cube,
      LocalCollectionSelectionWrite collection,
      LocalProfileValidationMode validationMode,
      LocalProfileMaterializationPolicy materializationPolicy =
          LocalProfileMaterializationPolicy.ExplicitV1,
      LocalProfileRevisionOrigin origin = LocalProfileRevisionOrigin.UserEdit)
  {
    RequireUid(characterUid, "profile_character_uid_invalid");
    ArgumentNullException.ThrowIfNull(limitBreak);
    ArgumentNullException.ThrowIfNull(coreLevel);
    ArgumentNullException.ThrowIfNull(bondLevel);
    ArgumentNullException.ThrowIfNull(skill1Level);
    ArgumentNullException.ThrowIfNull(skill2Level);
    ArgumentNullException.ThrowIfNull(burstLevel);
    ArgumentNullException.ThrowIfNull(equipment);
    Cube = cube ?? throw new ArgumentNullException(nameof(cube));
    Collection = collection ?? throw new ArgumentNullException(nameof(collection));
    RequireEnum(validationMode, "profile_validation_mode_invalid");
    RequireEnum(materializationPolicy, "profile_materialization_policy_invalid");
    RequireEnum(origin, "profile_revision_origin_invalid");
    if ((materializationPolicy == LocalProfileMaterializationPolicy.CombatMaxV1) !=
        (origin == LocalProfileRevisionOrigin.CombatMaxV1))
    {
      throw new LocalAccountProfileIntegrityException("profile_revision_origin_policy_mismatch");
    }
    if (characterLevel is < 1 or > 1_000_000 ||
        !ValidPositiveFact(skill1Level) || !ValidPositiveFact(skill2Level) ||
        !ValidPositiveFact(burstLevel) ||
        !ValidNonnegativeFact(limitBreak) || !ValidNonnegativeFact(coreLevel) ||
        !ValidNonnegativeFact(bondLevel) || bondLevel.Value is 0)
    {
      throw new LocalAccountProfileIntegrityException("profile_build_scalar_invalid");
    }

    var normalizedEquipment = equipment.OrderBy(static item => item.Slot).ToArray();
    if (normalizedEquipment.Length != 4 || normalizedEquipment.Any(static item => item is null) ||
        !normalizedEquipment.Select(static item => item.Slot)
            .SequenceEqual(Enum.GetValues<LocalEquipmentSlot>().Order()))
    {
      throw new LocalAccountProfileIntegrityException("profile_equipment_set_invalid");
    }

    CharacterUid = characterUid;
    CharacterLevel = characterLevel;
    LimitBreak = limitBreak;
    CoreLevel = coreLevel;
    BondLevel = bondLevel;
    Skill1Level = skill1Level;
    Skill2Level = skill2Level;
    BurstLevel = burstLevel;
    Equipment = Array.AsReadOnly(normalizedEquipment);
    ValidationMode = validationMode;
    MaterializationPolicy = materializationPolicy;
    Origin = origin;
  }

  public EntityUid CharacterUid { get; }

  public int CharacterLevel { get; }

  public LocalProfileFact<int> LimitBreak { get; }

  public LocalProfileFact<int> CoreLevel { get; }

  public LocalProfileFact<int> BondLevel { get; }

  public LocalProfileFact<int> Skill1Level { get; }

  public LocalProfileFact<int> Skill2Level { get; }

  public LocalProfileFact<int> BurstLevel { get; }

  public IReadOnlyList<LocalEquipmentWrite> Equipment { get; }

  public LocalCubeSelectionWrite Cube { get; }

  public LocalCollectionSelectionWrite Collection { get; }

  public LocalProfileValidationMode ValidationMode { get; }

  public LocalProfileMaterializationPolicy MaterializationPolicy { get; }

  public LocalProfileRevisionOrigin Origin { get; }

  private static bool ValidNonnegativeFact(LocalProfileFact<int> fact) =>
      fact.Value is null or >= 0 and <= 1_000_000;

  private static bool ValidPositiveFact(LocalProfileFact<int> fact) =>
      fact.Value is null or >= 1 and <= 1_000_000;
}

public sealed record LocalProfileCatalogBindingWrite
{
  public LocalProfileCatalogBindingWrite(
      EntityUid catalogSnapshotUid,
      EntityUid datasetSnapshotUid,
      Sha256Digest catalogManifestSha256)
  {
    RequireUid(catalogSnapshotUid, "profile_catalog_uid_invalid");
    RequireUid(datasetSnapshotUid, "profile_dataset_uid_invalid");
    if (catalogManifestSha256 == default)
    {
      throw new LocalAccountProfileIntegrityException("profile_catalog_manifest_invalid");
    }

    CatalogSnapshotUid = catalogSnapshotUid;
    DatasetSnapshotUid = datasetSnapshotUid;
    CatalogManifestSha256 = catalogManifestSha256;
  }

  public EntityUid CatalogSnapshotUid { get; }

  public EntityUid DatasetSnapshotUid { get; }

  public Sha256Digest CatalogManifestSha256 { get; }
}

public sealed record LocalAccountProfileWrite
{
  public LocalAccountProfileWrite(
      LocalProfileCatalogBindingWrite characterCatalog,
      LocalProfileCatalogBindingWrite combatSupportCatalog,
      LocalAccountCombatStateWrite accountState,
      IEnumerable<LocalCharacterBuildWrite> builds,
      IEnumerable<EntityUid>? squadCharacterUids = null,
      LocalProfileRevisionOrigin squadOrigin = LocalProfileRevisionOrigin.UserEdit,
      LocalProfileRevisionOrigin profileTemplateOrigin = LocalProfileRevisionOrigin.UserEdit)
  {
    CharacterCatalog = characterCatalog ?? throw new ArgumentNullException(nameof(characterCatalog));
    CombatSupportCatalog = combatSupportCatalog ??
        throw new ArgumentNullException(nameof(combatSupportCatalog));
    AccountState = accountState ?? throw new ArgumentNullException(nameof(accountState));
    ArgumentNullException.ThrowIfNull(builds);
    RequireEnum(squadOrigin, "profile_revision_origin_invalid");
    RequireEnum(profileTemplateOrigin, "profile_revision_origin_invalid");
    var normalizedBuilds = builds.OrderBy(static item => item.CharacterUid.ToString(), StringComparer.Ordinal)
        .ToArray();
    var squad = squadCharacterUids?.ToArray();
    if (normalizedBuilds.Any(static item => item is null) ||
        normalizedBuilds.Select(static item => item.CharacterUid).Distinct().Count() != normalizedBuilds.Length ||
        (squad is not null &&
         (squad.Length != 5 || squad.Any(static item => item.Value == Guid.Empty) ||
          squad.Distinct().Count() != 5 ||
          squad.Any(uid => normalizedBuilds.All(build => build.CharacterUid != uid)))))
    {
      throw new LocalAccountProfileIntegrityException("profile_build_or_squad_set_invalid");
    }

    Builds = Array.AsReadOnly(normalizedBuilds);
    SquadCharacterUids = squad is null ? null : Array.AsReadOnly(squad);
    SquadOrigin = squadOrigin;
    ProfileTemplateOrigin = profileTemplateOrigin;
    CanonicalSha256 = LocalAccountProfileCanonicalizer.ComputeProfileWriteSha256(this);
  }

  public LocalProfileCatalogBindingWrite CharacterCatalog { get; }

  public LocalProfileCatalogBindingWrite CombatSupportCatalog { get; }

  public LocalAccountCombatStateWrite AccountState { get; }

  public IReadOnlyList<LocalCharacterBuildWrite> Builds { get; }

  public IReadOnlyList<EntityUid>? SquadCharacterUids { get; }

  public LocalProfileRevisionOrigin SquadOrigin { get; }

  public LocalProfileRevisionOrigin ProfileTemplateOrigin { get; }

  public Sha256Digest CanonicalSha256 { get; }
}

public sealed record CreateLocalAccountProfileCommand
{
  public CreateLocalAccountProfileCommand(
      EntityUid operationUid,
      LocalAccountProfileWrite profile,
      DateTimeOffset createdAtUtc,
      string? accountLabel = null,
      EntityUid? saveAsParentAccountUid = null)
  {
    RequireUid(operationUid, "profile_operation_uid_invalid");
    RequirePostgresTimestamp(createdAtUtc);
    if (accountLabel is not null &&
        (string.IsNullOrWhiteSpace(accountLabel) || accountLabel.Length > 64 ||
         accountLabel.Any(static character => char.IsControl(character) ||
             character is '/' or '\\' or ':')))
    {
      throw new LocalAccountProfileIntegrityException("account_label_invalid");
    }

    if (saveAsParentAccountUid is { Value: var parentUid } && parentUid == Guid.Empty)
    {
      throw new LocalAccountProfileIntegrityException("profile_account_uid_invalid");
    }

    OperationUid = operationUid;
    Profile = profile ?? throw new ArgumentNullException(nameof(profile));
    CreatedAtUtc = createdAtUtc;
    AccountLabel = accountLabel;
    SaveAsParentAccountUid = saveAsParentAccountUid;
    RequestSha256 = LocalAccountProfileCanonicalizer.ComputeCreateRequestSha256(this);
  }

  public EntityUid OperationUid { get; }

  public LocalAccountProfileWrite Profile { get; }

  public DateTimeOffset CreatedAtUtc { get; }

  public string? AccountLabel { get; }

  public EntityUid? SaveAsParentAccountUid { get; }

  public Sha256Digest RequestSha256 { get; }
}

public sealed record SaveLocalAccountProfileCommand
{
  public SaveLocalAccountProfileCommand(
      EntityUid operationUid,
      EntityUid accountUid,
      EntityUid expectedProfileTemplateRevisionUid,
      LocalAccountProfileWrite profile,
      DateTimeOffset createdAtUtc)
  {
    RequireUid(operationUid, "profile_operation_uid_invalid");
    RequireUid(accountUid, "profile_account_uid_invalid");
    RequireUid(expectedProfileTemplateRevisionUid, "profile_expected_revision_uid_invalid");
    RequirePostgresTimestamp(createdAtUtc);

    OperationUid = operationUid;
    AccountUid = accountUid;
    ExpectedProfileTemplateRevisionUid = expectedProfileTemplateRevisionUid;
    Profile = profile ?? throw new ArgumentNullException(nameof(profile));
    CreatedAtUtc = createdAtUtc;
    RequestSha256 = LocalAccountProfileCanonicalizer.ComputeSaveRequestSha256(this);
  }

  public EntityUid OperationUid { get; }

  public EntityUid AccountUid { get; }

  public EntityUid ExpectedProfileTemplateRevisionUid { get; }

  public LocalAccountProfileWrite Profile { get; }

  public DateTimeOffset CreatedAtUtc { get; }

  public Sha256Digest RequestSha256 { get; }
}

public sealed record LocalEquipmentSlotReceipt(
    LocalEquipmentSlot Slot,
    EntityUid EquipmentSlotUid);

public sealed record LocalRevisionLineage(
    int RevisionNumber,
    EntityUid? PreviousRevisionUid,
    LocalProfileRevisionOrigin Origin,
    DateTimeOffset MaterializedAtUtc);

public sealed record LocalCharacterBuildReceipt(
    EntityUid CharacterUid,
    EntityUid CharacterBuildUid,
    EntityUid CharacterBuildRevisionUid,
    LocalRevisionLineage Lineage,
    Sha256Digest ContentSha256,
    bool IsSelectionReady,
    bool HasCombatSemantics,
    bool IsGameLegalReady,
    IReadOnlyList<string> IssueCodes,
    IReadOnlyList<LocalEquipmentSlotReceipt> EquipmentSlots);

public sealed record LocalAccountProfileReceipt(
    EntityUid? OperationUid,
    bool IsIdempotentReplay,
    EntityUid AccountUid,
    DateTimeOffset AccountCreatedAtUtc,
    Sha256Digest AccountCanonicalSha256,
    EntityUid AccountCombatStateUid,
    EntityUid AccountCombatStateRevisionUid,
    LocalRevisionLineage AccountStateLineage,
    Sha256Digest AccountStateContentSha256,
    bool IsAccountCombatReady,
    bool IsFullFidelity,
    bool IsAccountGameLegalReady,
    EntityUid? SquadUid,
    EntityUid? SquadRevisionUid,
    LocalRevisionLineage? SquadLineage,
    Sha256Digest? SquadContentSha256,
    bool? IsSquadSelectionReady,
    bool? SquadHasCompleteCombatSemantics,
    EntityUid ProfileTemplateUid,
    EntityUid ProfileTemplateRevisionUid,
    LocalRevisionLineage ProfileTemplateLineage,
    Sha256Digest ProfileContentSha256,
    bool IsCombatReady,
    bool HasCompleteCombatSemantics,
    bool IsGameLegalReady,
    IReadOnlyList<string> IssueCodes,
    IReadOnlyList<LocalCharacterBuildReceipt> Builds);

public sealed record LocalSessionReceipt(
    EntityUid SessionUid,
    EntityUid AccountUid,
    DateTimeOffset IssuedAtUtc,
    DateTimeOffset ExpiresAtUtc,
    DateTimeOffset? RevokedAtUtc,
    LocalSessionStatus Status);

public sealed record LocalCurrentAccountProfile(
    LocalAccountProfileReceipt Revision,
    LocalAccountProfileWrite Profile);

public static class LocalAccountProfileCanonicalizer
{
  public static Sha256Digest ComputeProfileWriteSha256(LocalAccountProfileWrite profile)
  {
    ArgumentNullException.ThrowIfNull(profile);
    using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
    Append(hash, "nll/local-account-profile-write/v1");
    AppendCatalogBinding(hash, profile.CharacterCatalog);
    AppendCatalogBinding(hash, profile.CombatSupportCatalog);
    AppendAccountState(hash, profile.AccountState);
    Append(hash, profile.Builds.Count.ToString(CultureInfo.InvariantCulture));
    foreach (var build in profile.Builds)
    {
      AppendBuild(hash, build);
    }

    Append(hash, profile.SquadCharacterUids?.Count.ToString(CultureInfo.InvariantCulture));
    foreach (var uid in profile.SquadCharacterUids ?? [])
    {
      Append(hash, uid.ToString());
    }

    if (profile.SquadCharacterUids is not null)
    {
      Append(hash, Code(profile.SquadOrigin));
    }

    Append(hash, Code(profile.ProfileTemplateOrigin));

    return Digest(hash);
  }

  public static Sha256Digest ComputeCreateRequestSha256(CreateLocalAccountProfileCommand command)
  {
    using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
    var labeled = command.AccountLabel is not null || command.SaveAsParentAccountUid is not null;
    Append(hash, labeled
        ? "nll/create-local-account-profile/v2"
        : "nll/create-local-account-profile/v1");
    Append(hash, command.Profile.CanonicalSha256.Hex);
    Append(hash, command.CreatedAtUtc.UtcDateTime.Ticks.ToString(CultureInfo.InvariantCulture));
    if (labeled)
    {
      Append(hash, command.AccountLabel);
      Append(hash, command.SaveAsParentAccountUid?.ToString());
    }

    return Digest(hash);
  }

  public static Sha256Digest ComputeSaveRequestSha256(SaveLocalAccountProfileCommand command)
  {
    using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
    Append(hash, "nll/save-local-account-profile/v1");
    Append(hash, command.AccountUid.ToString());
    Append(hash, command.ExpectedProfileTemplateRevisionUid.ToString());
    Append(hash, command.Profile.CanonicalSha256.Hex);
    Append(hash, command.CreatedAtUtc.UtcDateTime.Ticks.ToString(CultureInfo.InvariantCulture));
    return Digest(hash);
  }

  private static void AppendAccountState(
      IncrementalHash hash,
      LocalAccountCombatStateWrite state)
  {
    Append(hash, Code(state.Origin));
    Append(hash, Code(state.ValidationMode));
    AppendFact(hash, state.SynchroLevel, static value => value.ToString(CultureInfo.InvariantCulture));
    foreach (var console in state.Consoles)
    {
      Append(hash, Code(console.Coordinate));
      Append(hash, console.ConsoleDefinitionUid.ToString());
      AppendFact(hash, console.Level, static value => value.ToString(CultureInfo.InvariantCulture));
      AppendFact(
          hash,
          console.ObservedExperience,
          static value => value.ToString(CultureInfo.InvariantCulture));
    }

    // Legacy revisions keep their exact request hash when no inventory was recorded.
    if (state.Cubes.Count > 0)
    {
      Append(hash, "account-cubes/v1");
      Append(hash, state.Cubes.Count.ToString(CultureInfo.InvariantCulture));
      foreach (var cube in state.Cubes)
      {
        Append(hash, cube.DefinitionUid.ToString());
        Append(hash, cube.Level.ToString(CultureInfo.InvariantCulture));
      }
    }
  }

  private static void AppendCatalogBinding(
      IncrementalHash hash,
      LocalProfileCatalogBindingWrite binding)
  {
    Append(hash, binding.CatalogSnapshotUid.ToString());
    Append(hash, binding.DatasetSnapshotUid.ToString());
    Append(hash, binding.CatalogManifestSha256.Hex);
  }

  private static void AppendBuild(IncrementalHash hash, LocalCharacterBuildWrite build)
  {
    Append(hash, build.CharacterUid.ToString());
    Append(hash, build.CharacterLevel.ToString(CultureInfo.InvariantCulture));
    AppendFact(hash, build.LimitBreak, static value => value.ToString(CultureInfo.InvariantCulture));
    AppendFact(hash, build.CoreLevel, static value => value.ToString(CultureInfo.InvariantCulture));
    AppendFact(hash, build.BondLevel, static value => value.ToString(CultureInfo.InvariantCulture));
    AppendFact(hash, build.Skill1Level, static value => value.ToString(CultureInfo.InvariantCulture));
    AppendFact(hash, build.Skill2Level, static value => value.ToString(CultureInfo.InvariantCulture));
    AppendFact(hash, build.BurstLevel, static value => value.ToString(CultureInfo.InvariantCulture));
    Append(hash, Code(build.Origin));
    Append(hash, Code(build.MaterializationPolicy));
    Append(hash, Code(build.ValidationMode));
    foreach (var equipment in build.Equipment)
    {
      Append(hash, Code(equipment.Slot));
      Append(hash, Code(equipment.State));
      Append(hash, equipment.EquipmentDefinitionUid?.ToString());
      AppendOptionalFact(
          hash,
          equipment.EnhancementLevel,
          static value => value.ToString(CultureInfo.InvariantCulture));
      if (equipment.ManufacturerMatched is null)
      {
        Append(hash, null);
      }
      else
      {
        AppendFact(hash, equipment.ManufacturerMatched, static value => value ? "true" : "false");
      }

      Append(hash, equipment.UnresolvedReasonCode is { } equipmentReason
          ? Code(equipmentReason)
          : null);
      Append(hash, equipment.OverloadLines.Count.ToString(CultureInfo.InvariantCulture));
      foreach (var line in equipment.OverloadLines)
      {
        Append(hash, line.LineIndex.ToString(CultureInfo.InvariantCulture));
        Append(hash, line.OptionDefinitionUid.ToString());
        Append(hash, Code(line.Unit));
        AppendExact(hash, line.ExactValue);
      }
    }

    Append(hash, Code(build.Cube.State));
    Append(hash, build.Cube.DefinitionUid?.ToString());
    AppendOptionalFact(
        hash,
        build.Cube.Level,
        static value => value.ToString(CultureInfo.InvariantCulture));
    Append(hash, build.Cube.UnresolvedReasonCode is { } cubeReason ? Code(cubeReason) : null);
    Append(hash, Code(build.Collection.Kind));
    Append(hash, build.Collection.DefinitionUid?.ToString());
    AppendOptionalFact(
        hash,
        build.Collection.Level,
        static value => value.ToString(CultureInfo.InvariantCulture));
    Append(hash, build.Collection.UnresolvedReasonCode is { } collectionReason
        ? Code(collectionReason)
        : null);
  }

  private static void AppendFact<T>(
      IncrementalHash hash,
      LocalProfileFact<T> fact,
      Func<T, string> formatter)
      where T : struct
  {
    Append(hash, Code(fact.Status));
    Append(hash, fact.Value is { } value ? formatter(value) : null);
    Append(hash, fact.ReasonCode is { } reason ? Code(reason) : null);
  }

  private static void AppendOptionalFact<T>(
      IncrementalHash hash,
      LocalProfileFact<T>? fact,
      Func<T, string> formatter)
      where T : struct
  {
    if (fact is null)
    {
      Append(hash, null);
      return;
    }

    AppendFact(hash, fact, formatter);
  }

  private static void AppendExact(IncrementalHash hash, LocalProfileExactValue exact)
  {
    Append(hash, exact.UnscaledValue.ToString(CultureInfo.InvariantCulture));
    Append(hash, exact.DecimalScale.ToString(CultureInfo.InvariantCulture));
  }

  private static Sha256Digest Digest(IncrementalHash hash) =>
      Sha256Digest.FromBytes(hash.GetHashAndReset());

  private static void Append(IncrementalHash hash, string? value)
  {
    Span<byte> length = stackalloc byte[sizeof(int)];
    if (value is null)
    {
      BinaryPrimitives.WriteInt32BigEndian(length, -1);
      hash.AppendData(length);
      return;
    }

    var bytes = Encoding.UTF8.GetBytes(value);
    BinaryPrimitives.WriteInt32BigEndian(length, bytes.Length);
    hash.AppendData(length);
    hash.AppendData(bytes);
  }

  internal static string Code(LocalProfileFactStatus value) => value switch
  {
    LocalProfileFactStatus.Ready => "ready",
    LocalProfileFactStatus.Unresolved => "unresolved",
    LocalProfileFactStatus.NotApplicable => "not_applicable",
    _ => throw new LocalAccountProfileIntegrityException("profile_fact_status_invalid")
  };

  internal static string Code(LocalProfileReasonCode value) => value switch
  {
    { Code: { Length: > 0 } code } => LocalAccountProfileIntegrityException.RequireCode(code),
    _ => throw new LocalAccountProfileIntegrityException("profile_reason_code_invalid")
  };

  internal static string Code(LocalProfileValidationMode value) => value switch
  {
    LocalProfileValidationMode.Research => "research",
    LocalProfileValidationMode.GameLegal => "game_legal",
    _ => throw new LocalAccountProfileIntegrityException("profile_validation_mode_invalid")
  };

  internal static string Code(LocalProfileMaterializationPolicy value) => value switch
  {
    LocalProfileMaterializationPolicy.ExplicitV1 => "explicit_v1",
    LocalProfileMaterializationPolicy.CombatMaxV1 => "combat_max_v1",
    _ => throw new LocalAccountProfileIntegrityException(
        "profile_materialization_policy_invalid")
  };

  internal static string Code(LocalProfileRevisionOrigin value) => value switch
  {
    LocalProfileRevisionOrigin.UserEdit => "user_edit",
    LocalProfileRevisionOrigin.CombatMaxV1 => "combat_max_v1",
    LocalProfileRevisionOrigin.OfflineSanitizedImport => "offline_sanitized_import",
    LocalProfileRevisionOrigin.Rebase => "rebase",
    _ => throw new LocalAccountProfileIntegrityException("profile_revision_origin_invalid")
  };

  internal static string Code(LocalEquipmentSlot value) => value switch
  {
    LocalEquipmentSlot.Head => "head",
    LocalEquipmentSlot.Torso => "torso",
    LocalEquipmentSlot.Arms => "arms",
    LocalEquipmentSlot.Legs => "legs",
    _ => throw new LocalAccountProfileIntegrityException("profile_equipment_slot_invalid")
  };

  internal static string Code(LocalEquipmentState value) => value switch
  {
    LocalEquipmentState.Equipped => "equipped",
    LocalEquipmentState.Unequipped => "unequipped",
    LocalEquipmentState.Unresolved => "unresolved",
    _ => throw new LocalAccountProfileIntegrityException("profile_equipment_state_invalid")
  };

  internal static string Code(LocalOptionalSelectionState value) => value switch
  {
    LocalOptionalSelectionState.Equipped => "equipped",
    LocalOptionalSelectionState.Unequipped => "unequipped",
    LocalOptionalSelectionState.Unresolved => "unresolved",
    _ => throw new LocalAccountProfileIntegrityException("profile_selection_state_invalid")
  };

  internal static string Code(LocalCollectionSelectionKind value) => value switch
  {
    LocalCollectionSelectionKind.Detached => "detached",
    LocalCollectionSelectionKind.GenericCollection => "generic_collection",
    LocalCollectionSelectionKind.Favorite => "favorite",
    LocalCollectionSelectionKind.Unresolved => "unresolved",
    LocalCollectionSelectionKind.NotApplicable => "not_applicable",
    _ => throw new LocalAccountProfileIntegrityException("profile_collection_kind_invalid")
  };

  internal static string Code(LocalConsoleCoordinate value) => value switch
  {
    LocalConsoleCoordinate.Common => "common",
    LocalConsoleCoordinate.Attacker => "attacker",
    LocalConsoleCoordinate.Defender => "defender",
    LocalConsoleCoordinate.Supporter => "supporter",
    LocalConsoleCoordinate.Elysion => "elysion",
    LocalConsoleCoordinate.Missilis => "missilis",
    LocalConsoleCoordinate.Tetra => "tetra",
    LocalConsoleCoordinate.Pilgrim => "pilgrim",
    LocalConsoleCoordinate.Abnormal => "abnormal",
    _ => throw new LocalAccountProfileIntegrityException("profile_console_coordinate_invalid")
  };

  internal static string Code(LocalProfileValueUnit value) => value switch
  {
    LocalProfileValueUnit.Absolute => "absolute",
    LocalProfileValueUnit.Ratio => "ratio",
    LocalProfileValueUnit.Percent => "percent",
    LocalProfileValueUnit.Count => "count",
    _ => throw new LocalAccountProfileIntegrityException("profile_value_unit_invalid")
  };

  private static void RequireUid(EntityUid uid, string code)
  {
    if (uid.Value == Guid.Empty)
    {
      throw new LocalAccountProfileIntegrityException(code);
    }
  }

  private static void RequireEnum<T>(T value, string code)
      where T : struct, Enum
  {
    if (!Enum.IsDefined(value))
    {
      throw new LocalAccountProfileIntegrityException(code);
    }
  }
}

internal static class LocalProfileContractGuard
{
  internal static void RequirePostgresTimestamp(DateTimeOffset value)
  {
    if (value.Offset != TimeSpan.Zero || value.Ticks % 10 != 0)
    {
      throw new LocalAccountProfileIntegrityException("profile_timestamp_invalid");
    }
  }

  internal static void RequireUid(EntityUid uid, string code)
  {
    if (uid.Value == Guid.Empty)
    {
      throw new LocalAccountProfileIntegrityException(code);
    }
  }

  internal static void RequireEnum<T>(T value, string code)
      where T : struct, Enum
  {
    if (!Enum.IsDefined(value))
    {
      throw new LocalAccountProfileIntegrityException(code);
    }
  }
}
