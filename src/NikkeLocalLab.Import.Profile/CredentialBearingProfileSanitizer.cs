using System.Collections.ObjectModel;
using System.Globalization;
using System.Text.Json;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Import.Profile;

public sealed class CredentialBearingProfileSanitizer
{
  private const long MaximumSourceBytes = 16L * 1024 * 1024;
  private const int MaximumPacketsPerPhase = 1_024;
  private const int MaximumCharacters = 1_024;
  private const int MaximumDetailBatch = 128;
  private const int MaximumStateEffectsPerPacket = 4_096;
  private const int MaximumDistinctStateEffects = MaximumCharacters * 4 * 3;
  private const int MaximumScalar = 1_000_000;

  private static readonly string[] RootAllowed =
      ["uid", "phase_1_initial_load", "phase_2_after_click"];
  private static readonly string[] RootRequired = RootAllowed;
  private static readonly string[] PacketAllowed = ["endpoint", "url", "data"];
  private static readonly string[] PacketRequired = PacketAllowed;
  private static readonly string[] RosterDataAllowed = ["characters", "is_banned", "trace_id"];
  private static readonly string[] RosterDataRequired = ["characters"];
  private static readonly string[] DetailDataAllowed =
      ["character_details", "state_effects", "trace_id"];
  private static readonly string[] DetailDataRequired = ["character_details", "state_effects"];
  private static readonly string[] OutpostDataAllowed = ["outpost_info"];
  private static readonly string[] OutpostDataRequired = OutpostDataAllowed;
  private static readonly string[] RosterCharacterAllowed =
      ["name_code", "lv", "grade", "core", "combat", "costume_id"];
  private static readonly string[] RosterCharacterRequired = RosterCharacterAllowed;
  private static readonly string[] DetailCharacterAllowed =
  [
      "arena_combat",
    "arena_harmony_cube_lv",
    "arena_harmony_cube_tid",
    "arm_equip_corporation_type",
    "arm_equip_lv",
    "arm_equip_option1_id",
    "arm_equip_option2_id",
    "arm_equip_option3_id",
    "arm_equip_tid",
    "arm_equip_tier",
    "attractive_lv",
    "combat",
    "core",
    "costume_tid",
    "favorite_item_lv",
    "favorite_item_tid",
    "grade",
    "harmony_cube_lv",
    "harmony_cube_tid",
    "head_equip_corporation_type",
    "head_equip_lv",
    "head_equip_option1_id",
    "head_equip_option2_id",
    "head_equip_option3_id",
    "head_equip_tid",
    "head_equip_tier",
    "leg_equip_corporation_type",
    "leg_equip_lv",
    "leg_equip_option1_id",
    "leg_equip_option2_id",
    "leg_equip_option3_id",
    "leg_equip_tid",
    "leg_equip_tier",
    "lv",
    "name_code",
    "skill1_lv",
    "skill2_lv",
    "torso_equip_corporation_type",
    "torso_equip_lv",
    "torso_equip_option1_id",
    "torso_equip_option2_id",
    "torso_equip_option3_id",
    "torso_equip_tid",
    "torso_equip_tier",
    "ulti_skill_lv"
  ];
  private static readonly string[] DetailCharacterRequired =
  [
      "name_code",
    "lv",
    "grade",
    "core",
    "combat",
    "attractive_lv",
    "skill1_lv",
    "skill2_lv",
    "ulti_skill_lv",
    "harmony_cube_tid",
    "harmony_cube_lv",
    "favorite_item_tid",
    "favorite_item_lv",
    "head_equip_corporation_type",
    "head_equip_lv",
    "head_equip_option1_id",
    "head_equip_option2_id",
    "head_equip_option3_id",
    "head_equip_tid",
    "head_equip_tier",
    "torso_equip_corporation_type",
    "torso_equip_lv",
    "torso_equip_option1_id",
    "torso_equip_option2_id",
    "torso_equip_option3_id",
    "torso_equip_tid",
    "torso_equip_tier",
    "arm_equip_corporation_type",
    "arm_equip_lv",
    "arm_equip_option1_id",
    "arm_equip_option2_id",
    "arm_equip_option3_id",
    "arm_equip_tid",
    "arm_equip_tier",
    "leg_equip_corporation_type",
    "leg_equip_lv",
    "leg_equip_option1_id",
    "leg_equip_option2_id",
    "leg_equip_option3_id",
    "leg_equip_tid",
    "leg_equip_tier"
  ];
  private static readonly string[] StateEffectAllowed =
      ["function_details", "functions", "hurt_function_id_list", "icon", "id", "use_function_id_list"];
  private static readonly string[] StateEffectRequired = ["function_details", "id"];
  private static readonly string[] FunctionDetailAllowed =
  [
      "buff",
    "buff_icon",
    "duration_type",
    "duration_value",
    "function_battlepower",
    "function_standard",
    "function_target",
    "function_type",
    "function_value",
    "function_value_type",
    "id",
    "level",
    "name_localvalues"
  ];
  private static readonly string[] FunctionDetailRequired =
      ["function_type", "function_value", "function_value_type", "id"];
  private static readonly string[] OutpostAllowed =
  [
      "infra_core_level",
    "is_hide",
    "jukebox_count",
    "memorial_counts",
    "outpost_battle_level",
    "recycle_room_researches",
    "synchro_level",
    "synchro_nonempty_slot_count",
    "tactic_academy_class",
    "tactic_academy_lesson"
  ];
  private static readonly string[] OutpostRequired =
      ["recycle_room_researches", "synchro_level", "synchro_nonempty_slot_count"];
  private static readonly string[] ConsoleAllowed = ["exp", "lv", "tid"];
  private static readonly string[] ConsoleRequired = ConsoleAllowed;

  public SanitizedProfileImportResult Sanitize(
      Stream credentialBearingSource,
      ReadOnlySpan<byte> localIdentitySecret,
      IProfileCatalogAliasResolver catalogResolver,
      OfflineProfileImportOptions options)
  {
    ArgumentNullException.ThrowIfNull(credentialBearingSource);
    ArgumentNullException.ThrowIfNull(catalogResolver);
    ArgumentNullException.ThrowIfNull(options);
    if (localIdentitySecret.Length < 32)
    {
      throw new ArgumentException("The local identity secret must contain at least 32 bytes.", nameof(localIdentitySecret));
    }

    try
    {
      var parsed = Parse(credentialBearingSource);
      return Resolve(parsed, localIdentitySecret, catalogResolver, options);
    }
    catch (ProfileImportFailure failure)
    {
      return Failed(failure.Code, failure.Scope);
    }
    catch (JsonException)
    {
      return Failed("source_json_invalid", ProfileImportDiagnosticScope.Capture);
    }
    catch (IOException)
    {
      return Failed("source_read_failed", ProfileImportDiagnosticScope.Capture);
    }
    catch (UnauthorizedAccessException)
    {
      return Failed("source_read_failed", ProfileImportDiagnosticScope.Capture);
    }
    catch (NotSupportedException)
    {
      return Failed("source_stream_invalid", ProfileImportDiagnosticScope.Capture);
    }
    catch (Exception exception) when (exception is not OutOfMemoryException and
        not OperationCanceledException)
    {
      return Failed("profile_sanitization_failed", ProfileImportDiagnosticScope.Capture);
    }
  }

  public CredentialBearingProfileCoverageResult InspectCoverage(Stream credentialBearingSource)
  {
    ArgumentNullException.ThrowIfNull(credentialBearingSource);
    try
    {
      var parsed = Parse(credentialBearingSource);
      var rosterReferences = parsed.Roster.Select(static item => item.CharacterReference).ToHashSet();
      var detailReferences = parsed.Details.Select(static item => item.CharacterReference).ToHashSet();
      if (!rosterReferences.SetEquals(detailReferences))
      {
        throw new ProfileImportFailure(
            "roster_detail_coverage_mismatch",
            ProfileImportDiagnosticScope.Roster);
      }

      var rosterByReference = parsed.Roster.ToDictionary(static item => item.CharacterReference);
      var stateEffectReferences = parsed.StateEffects
          .Select(static item => item.SourceReference)
          .ToHashSet();
      var overloadReferences = parsed.Details
          .SelectMany(static item => item.Equipment)
          .SelectMany(static item => item.OptionReferences)
          .Where(static value => value != 0)
          .ToArray();
      var resolvedReferences = overloadReferences.Count(stateEffectReferences.Contains);
      if (resolvedReferences != overloadReferences.Length)
      {
        throw new ProfileImportFailure(
            "overload_state_effect_missing",
            ProfileImportDiagnosticScope.Overload);
      }

      var sparseEquipmentCount = parsed.Details
          .SelectMany(static item => item.Equipment)
          .Count(static item => item.OptionReferences[0] != 0 &&
              item.OptionReferences[1] == 0 && item.OptionReferences[2] != 0);
      var levelDifferenceCount = parsed.Details.Count(
          item => rosterByReference[item.CharacterReference].Level != item.Level);
      return new CredentialBearingProfileCoverageResult(
          new CredentialBearingProfileCoverage(
              parsed.Roster.Count,
              parsed.Details.Count,
              levelDifferenceCount,
              checked(parsed.Details.Count * 4),
              overloadReferences.Length,
              resolvedReferences,
              sparseEquipmentCount,
              parsed.Outpost.Consoles.Count),
          Array.Empty<ProfileImportDiagnostic>());
    }
    catch (ProfileImportFailure failure)
    {
      return FailedCoverage(failure.Code, failure.Scope);
    }
    catch (JsonException)
    {
      return FailedCoverage("source_json_invalid", ProfileImportDiagnosticScope.Capture);
    }
    catch (IOException)
    {
      return FailedCoverage("source_read_failed", ProfileImportDiagnosticScope.Capture);
    }
    catch (UnauthorizedAccessException)
    {
      return FailedCoverage("source_read_failed", ProfileImportDiagnosticScope.Capture);
    }
    catch (NotSupportedException)
    {
      return FailedCoverage("source_stream_invalid", ProfileImportDiagnosticScope.Capture);
    }
    catch (Exception exception) when (exception is not OutOfMemoryException and
        not OperationCanceledException)
    {
      return FailedCoverage("profile_inspection_failed", ProfileImportDiagnosticScope.Capture);
    }
  }

  private static SanitizedProfileImportResult Resolve(
      ParsedCapture parsed,
      ReadOnlySpan<byte> localIdentitySecret,
      IProfileCatalogAliasResolver resolver,
      OfflineProfileImportOptions options)
  {
    var diagnostics = new DiagnosticAccumulator();
    diagnostics.Add(
        "capture_time_not_observed",
        ProfileImportDiagnosticSeverity.Warning,
        ProfileImportDiagnosticScope.Capture);
    diagnostics.Add(
        "capture_atomicity_unresolved",
        ProfileImportDiagnosticSeverity.Warning,
        ProfileImportDiagnosticScope.Capture);
    diagnostics.Add(
        "synchro_slot_count_not_profile_write_field",
        ProfileImportDiagnosticSeverity.Warning,
        ProfileImportDiagnosticScope.Capture);

    var rosterBySource = parsed.Roster.ToDictionary(static item => item.CharacterReference);
    var detailBySource = parsed.Details.ToDictionary(static item => item.CharacterReference);
    if (rosterBySource.Count != detailBySource.Count ||
        !rosterBySource.Keys.ToHashSet().SetEquals(detailBySource.Keys))
    {
      throw new ProfileImportFailure("roster_detail_coverage_mismatch", ProfileImportDiagnosticScope.Roster);
    }

    var stateEffects = parsed.StateEffects.ToDictionary(static item => item.SourceReference);
    var builds = new List<SanitizedCharacterBuildDraft>(rosterBySource.Count);
    var resolvedCharacterUids = new HashSet<EntityUid>();
    var levelDifferenceCount = 0;
    var unresolvedBondCount = 0;
    var unresolvedManufacturerCount = 0;

    foreach (var sourceReference in rosterBySource.Keys.Order())
    {
      var roster = rosterBySource[sourceReference];
      var detail = detailBySource[sourceReference];
      if (roster.LimitBreak != detail.LimitBreak || roster.CoreLevel != detail.CoreLevel ||
          roster.CombatPower != detail.CombatPower)
      {
        throw new ProfileImportFailure(
            "roster_detail_scalar_conflict",
            ProfileImportDiagnosticScope.Character);
      }

      if (roster.Level != detail.Level)
      {
        levelDifferenceCount++;
      }

      var resolvedCharacter = ResolveRequired(
          resolver.ResolveCharacter(Alias(localIdentitySecret, SanitizedProfileDraftContract.CharacterEntityKind, sourceReference)),
          "character_alias",
          ProfileImportDiagnosticScope.Catalog);
      if (resolvedCharacter.CharacterUid.Value == Guid.Empty ||
          !Enum.IsDefined(resolvedCharacter.CombatRole) ||
          !Enum.IsDefined(resolvedCharacter.Manufacturer) ||
          !Enum.IsDefined(resolvedCharacter.WeaponClass) ||
          resolvedCharacter.MaximumCharacterLevel is <= 0 or > MaximumScalar ||
          resolvedCharacter.MaximumLimitBreak is < 0 or > MaximumScalar ||
          resolvedCharacter.MaximumCoreLevel is < 0 or > MaximumScalar ||
          resolvedCharacter.MaximumBondLevel is <= 0 or > MaximumScalar ||
          resolvedCharacter.MaximumSkill1Level is <= 0 or > MaximumScalar ||
          resolvedCharacter.MaximumSkill2Level is <= 0 or > MaximumScalar ||
          resolvedCharacter.MaximumBurstLevel is <= 0 or > MaximumScalar)
      {
        throw new ProfileImportFailure(
            "character_catalog_resolution_invalid",
            ProfileImportDiagnosticScope.Catalog);
      }

      ValidateCharacterObservations(roster, detail, resolvedCharacter);

      if (!resolvedCharacterUids.Add(resolvedCharacter.CharacterUid))
      {
        throw new ProfileImportFailure(
            "character_alias_collision",
            ProfileImportDiagnosticScope.Catalog);
      }

      var equipment = new List<SanitizedEquipmentSelection>(4);
      foreach (var item in detail.Equipment.OrderBy(static item => item.Slot))
      {
        var resolvedEquipment = ResolveEquipment(
            item,
            resolvedCharacter,
            stateEffects,
            localIdentitySecret,
            resolver);
        equipment.Add(resolvedEquipment);
        if (resolvedEquipment.State == ProfileImportAttachmentState.Equipped &&
            resolvedEquipment.ResolvedManufacturerMatched?.Status != ProfileImportFactStatus.Ready)
        {
          unresolvedManufacturerCount++;
        }
      }
      var cube = ResolveCube(detail, resolvedCharacter, localIdentitySecret, resolver);
      var collection = ResolveCollection(detail, resolvedCharacter, localIdentitySecret, resolver);
      var level = ResolveLevel(roster.Level, detail.Level, options.CharacterLevelAuthority);
      var bond = detail.BondLevel == 0
          ? ProfileImportFact<int>.Unresolved("bond_level_zero_semantics_unresolved")
          : ProfileImportFact<int>.Ready(detail.BondLevel);
      if (detail.BondLevel == 0)
      {
        unresolvedBondCount++;
      }

      builds.Add(new SanitizedCharacterBuildDraft(
          resolvedCharacter.CharacterUid,
          level,
          roster.LimitBreak,
          roster.CoreLevel,
          detail.BondLevel,
          bond,
          detail.Skill1Level,
          detail.Skill2Level,
          detail.BurstLevel,
          roster.CombatPower,
          detail.CombatPower,
          Array.AsReadOnly(equipment.ToArray()),
          cube,
          collection));
    }

    if (levelDifferenceCount > 0)
    {
      diagnostics.Add(
          "level_observations_differ",
          ProfileImportDiagnosticSeverity.Warning,
          ProfileImportDiagnosticScope.Character,
          levelDifferenceCount);
    }

    if (!options.CharacterLevelAuthority.HasValue)
    {
      diagnostics.Add(
          "level_authority_not_selected",
          ProfileImportDiagnosticSeverity.Warning,
          ProfileImportDiagnosticScope.Character,
          builds.Count);
    }

    if (unresolvedBondCount > 0)
    {
      diagnostics.Add(
          "bond_level_zero_semantics_unresolved",
          ProfileImportDiagnosticSeverity.Warning,
          ProfileImportDiagnosticScope.Character,
          unresolvedBondCount);
    }

    if (unresolvedManufacturerCount > 0)
    {
      diagnostics.Add(
          "equipment_manufacturer_observation_unresolved",
          ProfileImportDiagnosticSeverity.Warning,
          ProfileImportDiagnosticScope.Equipment,
          unresolvedManufacturerCount);
    }

    var consoles = ResolveConsoles(
        parsed.Outpost.Consoles,
        parsed.Outpost.SynchroLevel,
        localIdentitySecret,
        resolver);
    var accountState = new SanitizedAccountCombatStateDraft(
        parsed.Outpost.SynchroLevel,
        parsed.Outpost.OccupiedSlotCount,
        Array.AsReadOnly(consoles));
    var orderedBuilds = builds.OrderBy(static item => item.CharacterUid.ToString(), StringComparer.Ordinal)
        .ToArray();
    var sanitizedHash = SanitizedProfileCanonicalizer.Compute(
        resolver.CharacterCatalog,
        resolver.CombatSupportCatalog,
        accountState,
        orderedBuilds,
        Array.Empty<SanitizedProfileReviewedOverride>(),
        SanitizedProfileDraftContract.SourceSchemaSha256,
        SanitizedProfileDraftContract.Transformer.FingerprintSha256,
        options.TransformerBinarySha256,
        options.SemanticOptionsSha256);
    var provenance = new SanitizedProfileImportProvenance(
        SanitizedProfileDraftContract.SchemaCode,
        SanitizedProfileDraftContract.SourceSchemaSha256,
        SanitizedProfileDraftContract.TransformerId,
        SanitizedProfileDraftContract.TransformerVersion,
        SanitizedProfileDraftContract.Transformer.FingerprintSha256,
        options.TransformerBinarySha256,
        options.SemanticOptionsSha256,
        sanitizedHash,
        options.ImportedAtUtc,
        ProfileImportFact<DateTimeOffset>.Unresolved("capture_time_not_observed"),
        ProfileCaptureAtomicity.Unresolved,
        CredentialBearingSourceHashPolicy.Prohibited);
    var canMaterialize = options.CharacterLevelAuthority.HasValue;
    var isProfileWriteReady = canMaterialize &&
        orderedBuilds.All(static build =>
            build.Level.ResolvedBattleLevel.Status == ProfileImportFactStatus.Ready &&
            build.ResolvedBondLevel.Status == ProfileImportFactStatus.Ready &&
            build.Equipment.All(static equipment =>
                equipment.State == ProfileImportAttachmentState.Unequipped ||
                equipment.ResolvedManufacturerMatched?.Status == ProfileImportFactStatus.Ready));
    var draft = new SanitizedProfileDraft(
        provenance,
        resolver.CharacterCatalog,
        resolver.CombatSupportCatalog,
        accountState,
        Array.AsReadOnly(orderedBuilds),
        Array.Empty<SanitizedProfileReviewedOverride>(),
        canMaterialize,
        isProfileWriteReady);
    return new SanitizedProfileImportResult(draft, diagnostics.ToReadOnly());
  }

  private static void ValidateCharacterObservations(
      RawRoster roster,
      RawDetail detail,
      ResolvedProfileCharacter character)
  {
    if (roster.Level > character.MaximumCharacterLevel ||
        detail.Level > character.MaximumCharacterLevel ||
        roster.LimitBreak > character.MaximumLimitBreak ||
        roster.CoreLevel > character.MaximumCoreLevel ||
        detail.BondLevel > character.MaximumBondLevel ||
        detail.Skill1Level > character.MaximumSkill1Level ||
        detail.Skill2Level > character.MaximumSkill2Level ||
        detail.BurstLevel > character.MaximumBurstLevel)
    {
      throw new ProfileImportFailure(
          "character_catalog_range_mismatch",
          ProfileImportDiagnosticScope.Character);
    }
  }

  private static SanitizedCharacterLevelObservation ResolveLevel(
      int rosterLevel,
      int detailLevel,
      CharacterLevelAuthorityPolicy? authority)
  {
    if (!authority.HasValue)
    {
      return new SanitizedCharacterLevelObservation(
          rosterLevel,
          detailLevel,
          ProfileImportFact<int>.Unresolved("level_authority_not_selected"),
          null);
    }

    var value = authority.Value switch
    {
      CharacterLevelAuthorityPolicy.RosterObservationV1 => rosterLevel,
      CharacterLevelAuthorityPolicy.DetailObservationV1 => detailLevel,
      _ => throw new ProfileImportFailure(
          "level_authority_invalid",
          ProfileImportDiagnosticScope.Character)
    };
    return new SanitizedCharacterLevelObservation(
        rosterLevel,
        detailLevel,
        ProfileImportFact<int>.Ready(value),
        CharacterLevelAuthorityPolicyCodes.ToCode(authority.Value));
  }

  private static SanitizedEquipmentSelection ResolveEquipment(
      RawEquipment equipment,
      ResolvedProfileCharacter character,
      IReadOnlyDictionary<long, RawStateEffect> stateEffects,
      ReadOnlySpan<byte> localIdentitySecret,
      IProfileCatalogAliasResolver resolver)
  {
    if (equipment.DefinitionReference == 0)
    {
      if (equipment.Tier != 0 || equipment.EnhancementLevel != 0 ||
          equipment.ManufacturerCode != 0 || equipment.OptionReferences.Any(static value => value != 0))
      {
        throw new ProfileImportFailure(
            "unequipped_equipment_state_conflict",
            ProfileImportDiagnosticScope.Equipment);
      }

      return new SanitizedEquipmentSelection(
          equipment.Slot,
          ProfileImportAttachmentState.Unequipped,
          null,
          null,
          null,
          null,
          Array.Empty<SanitizedOverloadLine>());
    }

    var resolved = ResolveRequired(
        resolver.ResolveEquipment(Alias(
            localIdentitySecret,
            SanitizedProfileDraftContract.EquipmentEntityKind,
            equipment.DefinitionReference)),
        "equipment_alias",
        ProfileImportDiagnosticScope.Catalog);
    if (resolved.Slot != equipment.Slot || resolved.CombatRole != character.CombatRole ||
        resolved.Tier != equipment.Tier || equipment.EnhancementLevel > resolved.MaximumEnhancementLevel ||
        resolved.DefinitionUid.Value == Guid.Empty || !Enum.IsDefined(resolved.Slot) ||
        !Enum.IsDefined(resolved.CombatRole) || resolved.Manufacturer is null ||
        (resolved.Manufacturer.Status == ProfileImportFactStatus.Ready &&
         (!resolved.Manufacturer.Value.HasValue ||
          !Enum.IsDefined(resolved.Manufacturer.Value.Value))) ||
        resolved.Tier is not (9 or 10) ||
        resolved.MaximumEnhancementLevel is < 0 or > 5)
    {
      throw new ProfileImportFailure(
          "equipment_catalog_mismatch",
          ProfileImportDiagnosticScope.Equipment);
    }

    var manufacturer = ResolveManufacturer(equipment.ManufacturerCode);
    if (manufacturer.HasValue &&
        resolved.Manufacturer.Status == ProfileImportFactStatus.Ready &&
        resolved.Manufacturer.Value != manufacturer.Value)
    {
      throw new ProfileImportFailure(
          "equipment_manufacturer_catalog_mismatch",
          ProfileImportDiagnosticScope.Equipment);
    }

    var matched = manufacturer.HasValue
        ? ProfileImportFact<bool>.Ready(manufacturer.Value == character.Manufacturer)
        : ProfileImportFact<bool>.Unresolved("equipment_manufacturer_observation_missing");
    var lines = new List<SanitizedOverloadLine>(3);
    for (var index = 0; index < equipment.OptionReferences.Count; index++)
    {
      var optionReference = equipment.OptionReferences[index];
      if (optionReference == 0)
      {
        continue;
      }

      if (!resolved.OverloadEligible || !stateEffects.TryGetValue(optionReference, out var effect))
      {
        throw new ProfileImportFailure(
            "overload_state_effect_missing",
            ProfileImportDiagnosticScope.Overload);
      }

      var option = ResolveRequired(
          resolver.ResolveOverloadValue(Alias(
              localIdentitySecret,
              SanitizedProfileDraftContract.OverloadLegalValueEntityKind,
              optionReference)),
          "overload_alias",
          ProfileImportDiagnosticScope.Catalog);
      if (option.SourceRawValue != effect.SourceRawValue ||
          option.OptionDefinitionUid.Value == Guid.Empty ||
          option.Unit != ProfileImportValueUnit.Ratio ||
          option.SourceRawValue == 0 || option.SourceRawValue < -int.MaxValue ||
          option.SourceRawValue > int.MaxValue ||
          option.ApplicationValue.UnscaledValue != option.SourceRawValue ||
          option.ApplicationValue.DecimalScale != 4)
      {
        throw new ProfileImportFailure(
            "overload_exact_value_mismatch",
            ProfileImportDiagnosticScope.Overload);
      }

      lines.Add(new SanitizedOverloadLine(
          index + 1,
          option.OptionDefinitionUid,
          option.Unit,
          option.ApplicationValue));
    }

    return new SanitizedEquipmentSelection(
        equipment.Slot,
        ProfileImportAttachmentState.Equipped,
        resolved.DefinitionUid,
        equipment.EnhancementLevel,
        matched,
        matched,
        Array.AsReadOnly(lines.ToArray()));
  }

  private static SanitizedCubeSelection ResolveCube(
      RawDetail detail,
      ResolvedProfileCharacter character,
      ReadOnlySpan<byte> localIdentitySecret,
      IProfileCatalogAliasResolver resolver)
  {
    if (detail.CubeReference == 0)
    {
      if (detail.CubeLevel != 0)
      {
        throw new ProfileImportFailure("cube_state_conflict", ProfileImportDiagnosticScope.Character);
      }

      return new SanitizedCubeSelection(ProfileImportAttachmentState.Unequipped, null, null);
    }

    var cube = ResolveRequired(
        resolver.ResolveCube(Alias(
            localIdentitySecret,
            SanitizedProfileDraftContract.CubeEntityKind,
            detail.CubeReference)),
        "cube_alias",
        ProfileImportDiagnosticScope.Catalog);
    if (cube.DefinitionUid.Value == Guid.Empty || cube.MaximumLevel is < 1 or > MaximumScalar ||
        (cube.ApplicableCombatRole.HasValue && !Enum.IsDefined(cube.ApplicableCombatRole.Value)) ||
        detail.CubeLevel is < 1 || detail.CubeLevel > cube.MaximumLevel ||
        (cube.ApplicableCombatRole.HasValue && cube.ApplicableCombatRole != character.CombatRole))
    {
      throw new ProfileImportFailure("cube_catalog_mismatch", ProfileImportDiagnosticScope.Character);
    }

    return new SanitizedCubeSelection(
        ProfileImportAttachmentState.Equipped,
        cube.DefinitionUid,
        detail.CubeLevel);
  }

  private static SanitizedCollectionSelection ResolveCollection(
      RawDetail detail,
      ResolvedProfileCharacter character,
      ReadOnlySpan<byte> localIdentitySecret,
      IProfileCatalogAliasResolver resolver)
  {
    if (detail.CollectionReference == 0)
    {
      if (detail.CollectionLevel != 0)
      {
        throw new ProfileImportFailure(
            "collection_state_conflict",
            ProfileImportDiagnosticScope.Character);
      }

      return new SanitizedCollectionSelection(ProfileImportCollectionKind.Detached, null, null);
    }

    var generic = resolver.ResolveGenericCollection(Alias(
        localIdentitySecret,
        SanitizedProfileDraftContract.GenericCollectionEntityKind,
        detail.CollectionReference));
    var favorite = resolver.ResolveFavorite(Alias(
        localIdentitySecret,
        SanitizedProfileDraftContract.FavoriteEntityKind,
        detail.CollectionReference));
    if (generic.Status == ProfileAliasResolutionStatus.Ambiguous ||
        favorite.Status == ProfileAliasResolutionStatus.Ambiguous)
    {
      throw new ProfileImportFailure(
          "collection_alias_ambiguous",
          ProfileImportDiagnosticScope.Catalog);
    }

    if (generic.Status == ProfileAliasResolutionStatus.CatalogMismatch ||
        favorite.Status == ProfileAliasResolutionStatus.CatalogMismatch)
    {
      throw new ProfileImportFailure(
          "collection_alias_catalog_mismatch",
          ProfileImportDiagnosticScope.Catalog);
    }

    var candidates = new[] { generic, favorite }
        .Where(static item => item.Status == ProfileAliasResolutionStatus.Resolved)
        .Select(static item => item.Value!)
        .ToArray();
    if (candidates.Length != 1)
    {
      throw new ProfileImportFailure(
          candidates.Length > 1 ? "collection_alias_ambiguous" : "collection_alias_missing",
          ProfileImportDiagnosticScope.Catalog);
    }

    var selection = candidates[0];
    var resolvedAsGeneric = generic.Status == ProfileAliasResolutionStatus.Resolved;
    var namespaceAndApplicabilityValid = resolvedAsGeneric
        ? selection.Kind == ProfileImportCollectionKind.GenericCollection &&
          selection.ApplicableCharacterUid is null &&
          selection.ApplicableWeaponClass.HasValue &&
          Enum.IsDefined(selection.ApplicableWeaponClass.Value) &&
          selection.ApplicableWeaponClass.Value == character.WeaponClass
        : selection.Kind == ProfileImportCollectionKind.Favorite &&
          selection.ApplicableCharacterUid == character.CharacterUid &&
          !selection.ApplicableWeaponClass.HasValue;
    if (selection.DefinitionUid.Value == Guid.Empty ||
        selection.MaximumLevel is < 0 or > MaximumScalar ||
        !namespaceAndApplicabilityValid ||
        detail.CollectionLevel < 0 || detail.CollectionLevel > selection.MaximumLevel ||
        selection.Kind is not (ProfileImportCollectionKind.GenericCollection or
        ProfileImportCollectionKind.Favorite))
    {
      throw new ProfileImportFailure(
          "collection_catalog_mismatch",
          ProfileImportDiagnosticScope.Character);
    }

    return new SanitizedCollectionSelection(
        selection.Kind,
        selection.DefinitionUid,
        detail.CollectionLevel);
  }

  private static SanitizedConsoleState[] ResolveConsoles(
      IReadOnlyList<RawConsole> sourceConsoles,
      int accountSynchroLevel,
      ReadOnlySpan<byte> localIdentitySecret,
      IProfileCatalogAliasResolver resolver)
  {
    var result = new List<SanitizedConsoleState>(9);
    var coordinates = new HashSet<ProfileImportConsoleCoordinate>();
    foreach (var source in sourceConsoles)
    {
      var resolved = ResolveRequired(
          resolver.ResolveConsole(Alias(
              localIdentitySecret,
              SanitizedProfileDraftContract.ConsoleEntityKind,
              source.DefinitionReference),
              source.Level),
          "console_alias",
          ProfileImportDiagnosticScope.Catalog);
      if (resolved.DefinitionUid.Value == Guid.Empty || !Enum.IsDefined(resolved.Coordinate) ||
          resolved.SelectedLevel != source.Level ||
          resolved.MaximumLevel is < 1 or > MaximumScalar ||
          resolved.SelectedLevel is < 0 || resolved.SelectedLevel > resolved.MaximumLevel ||
          resolved.SelectedLevelMinimumSynchroLevel is null ||
          !coordinates.Add(resolved.Coordinate))
      {
        throw new ProfileImportFailure(
            "console_catalog_mismatch",
            ProfileImportDiagnosticScope.Console);
      }

      var minimumSynchro = resolved.SelectedLevelMinimumSynchroLevel;
      if (source.Level == 0)
      {
        if (minimumSynchro.Status != ProfileImportFactStatus.Ready ||
            minimumSynchro.Value != 0)
        {
          throw new ProfileImportFailure(
              "console_zero_level_gate_invalid",
              ProfileImportDiagnosticScope.Console);
        }
      }
      else if (minimumSynchro.Status == ProfileImportFactStatus.Unresolved)
      {
        throw new ProfileImportFailure(
            "console_minimum_synchro_unresolved",
            ProfileImportDiagnosticScope.Console);
      }
      else if (minimumSynchro.Status != ProfileImportFactStatus.Ready ||
          !minimumSynchro.Value.HasValue || minimumSynchro.Value.Value < 0 ||
          minimumSynchro.Value.Value > MaximumScalar)
      {
        throw new ProfileImportFailure(
            "console_minimum_synchro_invalid",
            ProfileImportDiagnosticScope.Console);
      }
      else if (accountSynchroLevel < minimumSynchro.Value.Value)
      {
        throw new ProfileImportFailure(
            "console_minimum_synchro_mismatch",
            ProfileImportDiagnosticScope.Console);
      }

      result.Add(new SanitizedConsoleState(
          resolved.Coordinate,
          resolved.DefinitionUid,
          source.Level,
          source.Experience));
    }

    if (result.Count != 9 || coordinates.Count != 9 ||
        !coordinates.SetEquals(Enum.GetValues<ProfileImportConsoleCoordinate>()))
    {
      throw new ProfileImportFailure(
          "console_coordinate_set_invalid",
          ProfileImportDiagnosticScope.Console);
    }

    return result.OrderBy(static item => item.Coordinate).ToArray();
  }

  private static ProfileImportManufacturer? ResolveManufacturer(int sourceCode) => sourceCode switch
  {
    0 => null,
    1 => ProfileImportManufacturer.Elysion,
    2 => ProfileImportManufacturer.Missilis,
    3 => ProfileImportManufacturer.Tetra,
    4 => ProfileImportManufacturer.Pilgrim,
    7 => ProfileImportManufacturer.Abnormal,
    _ => throw new ProfileImportFailure(
        "equipment_manufacturer_unknown",
        ProfileImportDiagnosticScope.Equipment)
  };

  private static T ResolveRequired<T>(
      ProfileAliasResolution<T> resolution,
      string prefix,
      ProfileImportDiagnosticScope scope)
      where T : class
  {
    ArgumentNullException.ThrowIfNull(resolution);
    if (resolution.Status == ProfileAliasResolutionStatus.Resolved)
    {
      return resolution.Value!;
    }

    var suffix = resolution.Status switch
    {
      ProfileAliasResolutionStatus.Missing => "missing",
      ProfileAliasResolutionStatus.Ambiguous => "ambiguous",
      ProfileAliasResolutionStatus.CatalogMismatch => "catalog_mismatch",
      _ => "invalid"
    };
    throw new ProfileImportFailure($"{prefix}_{suffix}", scope);
  }

  private static SourceAliasFingerprint Alias(
      ReadOnlySpan<byte> localIdentitySecret,
      string entityKind,
      long sourceIdentifier) => SourceAliasFingerprintEncoder.Encode(
          localIdentitySecret,
          SanitizedProfileDraftContract.SourceNamespace,
          entityKind,
          sourceIdentifier.ToString(CultureInfo.InvariantCulture));

  private static ParsedCapture Parse(Stream source)
  {
    if (!source.CanRead || !source.CanSeek || source.Position < 0 ||
        source.Length - source.Position <= 0)
    {
      throw new ProfileImportFailure("source_stream_invalid", ProfileImportDiagnosticScope.Capture);
    }

    if (source.Length - source.Position > MaximumSourceBytes)
    {
      throw new ProfileImportFailure(
          "source_size_limit_exceeded",
          ProfileImportDiagnosticScope.Capture);
    }

    using var limitedSource = new ReadLimitStream(source, MaximumSourceBytes);
    using var document = JsonDocument.Parse(limitedSource, new JsonDocumentOptions
    {
      AllowTrailingCommas = false,
      CommentHandling = JsonCommentHandling.Disallow,
      MaxDepth = 16
    });
    var root = document.RootElement;
    RequireObject(root, RootAllowed, RootRequired, "source_root_shape_invalid");
    RequireKind(root.GetProperty("uid"), JsonValueKind.String, "source_root_shape_invalid");

    List<RawRoster>? rosters = null;
    RawOutpost? outpost = null;
    var details = new List<RawDetail>();
    var stateEffects = new Dictionary<long, RawStateEffect>();
    ParsePhase(root.GetProperty("phase_1_initial_load"), ref rosters, ref outpost, details, stateEffects);
    ParsePhase(root.GetProperty("phase_2_after_click"), ref rosters, ref outpost, details, stateEffects);
    if (rosters is null || rosters.Count is <= 0 or > MaximumCharacters ||
        outpost is null || details.Count is <= 0 or > MaximumCharacters)
    {
      throw new ProfileImportFailure(
          "required_profile_payload_missing",
          ProfileImportDiagnosticScope.Capture);
    }

    if (rosters.Select(static item => item.CharacterReference).Distinct().Count() != rosters.Count ||
        details.Select(static item => item.CharacterReference).Distinct().Count() != details.Count)
    {
      throw new ProfileImportFailure(
          "character_observation_duplicate",
          ProfileImportDiagnosticScope.Roster);
    }

    return new ParsedCapture(
        Array.AsReadOnly(rosters.ToArray()),
        Array.AsReadOnly(details.ToArray()),
        new ReadOnlyCollection<RawStateEffect>(stateEffects.Values.OrderBy(static item => item.SourceReference).ToArray()),
        outpost);
  }

  private static void ParsePhase(
      JsonElement phase,
      ref List<RawRoster>? roster,
      ref RawOutpost? outpost,
      ICollection<RawDetail> details,
      IDictionary<long, RawStateEffect> stateEffects)
  {
    RequireKind(phase, JsonValueKind.Array, "source_phase_shape_invalid");
    if (phase.GetArrayLength() > MaximumPacketsPerPhase)
    {
      throw new ProfileImportFailure("source_packet_limit_exceeded", ProfileImportDiagnosticScope.Capture);
    }

    foreach (var packet in phase.EnumerateArray())
    {
      RequireObject(packet, PacketAllowed, PacketRequired, "source_packet_shape_invalid");
      RequireKind(packet.GetProperty("endpoint"), JsonValueKind.String, "source_packet_shape_invalid");
      RequireKind(packet.GetProperty("url"), JsonValueKind.String, "source_packet_shape_invalid");
      var data = packet.GetProperty("data");
      if (data.ValueKind == JsonValueKind.Null)
      {
        continue;
      }

      RequireKind(data, JsonValueKind.Object, "source_packet_shape_invalid");
      var hasRoster = data.TryGetProperty("characters", out _);
      var hasDetail = data.TryGetProperty("character_details", out _) ||
          data.TryGetProperty("state_effects", out _);
      var hasOutpost = data.TryGetProperty("outpost_info", out _);
      if ((hasRoster ? 1 : 0) + (hasDetail ? 1 : 0) + (hasOutpost ? 1 : 0) > 1)
      {
        throw new ProfileImportFailure(
            "recognized_payload_mixed",
            ProfileImportDiagnosticScope.Capture);
      }

      if (hasRoster)
      {
        if (roster is not null)
        {
          throw new ProfileImportFailure("roster_payload_duplicate", ProfileImportDiagnosticScope.Roster);
        }

        roster = ParseRoster(data);
      }
      else if (hasDetail)
      {
        ParseDetail(data, details, stateEffects);
      }
      else if (hasOutpost)
      {
        if (outpost is not null)
        {
          throw new ProfileImportFailure("outpost_payload_duplicate", ProfileImportDiagnosticScope.Console);
        }

        outpost = ParseOutpost(data);
      }
    }
  }

  private static List<RawRoster> ParseRoster(JsonElement data)
  {
    RequireObject(data, RosterDataAllowed, RosterDataRequired, "roster_payload_shape_invalid");
    RequireOptionalKind(data, "is_banned", JsonValueKind.False, JsonValueKind.True);
    RequireOptionalKind(data, "trace_id", JsonValueKind.String);
    var characters = data.GetProperty("characters");
    RequireKind(characters, JsonValueKind.Array, "roster_payload_shape_invalid");
    if (characters.GetArrayLength() is <= 0 or > MaximumCharacters)
    {
      throw new ProfileImportFailure("roster_count_invalid", ProfileImportDiagnosticScope.Roster);
    }

    var result = new List<RawRoster>(characters.GetArrayLength());
    foreach (var item in characters.EnumerateArray())
    {
      RequireObject(item, RosterCharacterAllowed, RosterCharacterRequired, "roster_character_shape_invalid");
      result.Add(new RawRoster(
          PositiveLong(item, "name_code", "roster_character_value_invalid"),
          PositiveInt(item, "lv", MaximumScalar, "roster_character_value_invalid"),
          NonnegativeInt(item, "grade", MaximumScalar, "roster_character_value_invalid"),
          NonnegativeInt(item, "core", MaximumScalar, "roster_character_value_invalid"),
          NonnegativeLong(item, "combat", "roster_character_value_invalid")));
      NonnegativeLong(item, "costume_id", "roster_character_value_invalid");
    }

    return result;
  }

  private static void ParseDetail(
      JsonElement data,
      ICollection<RawDetail> details,
      IDictionary<long, RawStateEffect> stateEffects)
  {
    RequireObject(data, DetailDataAllowed, DetailDataRequired, "detail_payload_shape_invalid");
    RequireOptionalKind(data, "trace_id", JsonValueKind.String);
    var characterDetails = data.GetProperty("character_details");
    RequireKind(characterDetails, JsonValueKind.Array, "detail_payload_shape_invalid");
    if (characterDetails.GetArrayLength() is <= 0 or > MaximumDetailBatch)
    {
      throw new ProfileImportFailure("detail_batch_count_invalid", ProfileImportDiagnosticScope.Character);
    }

    var batchDetails = new List<RawDetail>(characterDetails.GetArrayLength());
    foreach (var item in characterDetails.EnumerateArray())
    {
      RequireObject(item, DetailCharacterAllowed, DetailCharacterRequired, "detail_character_shape_invalid");
      var equipment = new[]
      {
        ParseEquipment(item, ProfileImportEquipmentSlot.Head, "head"),
        ParseEquipment(item, ProfileImportEquipmentSlot.Torso, "torso"),
        ParseEquipment(item, ProfileImportEquipmentSlot.Arms, "arm"),
        ParseEquipment(item, ProfileImportEquipmentSlot.Legs, "leg")
      };
      batchDetails.Add(new RawDetail(
          PositiveLong(item, "name_code", "detail_character_value_invalid"),
          PositiveInt(item, "lv", MaximumScalar, "detail_character_value_invalid"),
          NonnegativeInt(item, "grade", MaximumScalar, "detail_character_value_invalid"),
          NonnegativeInt(item, "core", MaximumScalar, "detail_character_value_invalid"),
          NonnegativeLong(item, "combat", "detail_character_value_invalid"),
          NonnegativeInt(item, "attractive_lv", MaximumScalar, "detail_character_value_invalid"),
          PositiveInt(item, "skill1_lv", MaximumScalar, "detail_character_value_invalid"),
          PositiveInt(item, "skill2_lv", MaximumScalar, "detail_character_value_invalid"),
          PositiveInt(item, "ulti_skill_lv", MaximumScalar, "detail_character_value_invalid"),
          NonnegativeLong(item, "harmony_cube_tid", "detail_character_value_invalid"),
          NonnegativeInt(item, "harmony_cube_lv", MaximumScalar, "detail_character_value_invalid"),
          NonnegativeLong(item, "favorite_item_tid", "detail_character_value_invalid"),
          NonnegativeInt(item, "favorite_item_lv", MaximumScalar, "detail_character_value_invalid"),
          Array.AsReadOnly(equipment)));
    }

    if (details.Count > MaximumCharacters - batchDetails.Count)
    {
      throw new ProfileImportFailure(
          "detail_character_count_invalid",
          ProfileImportDiagnosticScope.Character);
    }

    var effects = data.GetProperty("state_effects");
    RequireKind(effects, JsonValueKind.Array, "state_effect_payload_shape_invalid");
    if (effects.GetArrayLength() > MaximumStateEffectsPerPacket)
    {
      throw new ProfileImportFailure("state_effect_count_invalid", ProfileImportDiagnosticScope.Overload);
    }

    var packetStateEffects = new Dictionary<long, RawStateEffect>();
    foreach (var item in effects.EnumerateArray())
    {
      var effect = ParseStateEffect(item);
      if (!packetStateEffects.TryAdd(effect.SourceReference, effect))
      {
        throw new ProfileImportFailure(
            "state_effect_reference_duplicate",
            ProfileImportDiagnosticScope.Overload);
      }

      if (stateEffects.TryGetValue(effect.SourceReference, out var prior))
      {
        if (prior.SourceRawValue != effect.SourceRawValue ||
            prior.ContentSha256 != effect.ContentSha256)
        {
          throw new ProfileImportFailure(
              "state_effect_definition_conflict",
              ProfileImportDiagnosticScope.Overload);
        }

        continue;
      }

      if (stateEffects.Count >= MaximumDistinctStateEffects)
      {
        throw new ProfileImportFailure(
            "state_effect_count_invalid",
            ProfileImportDiagnosticScope.Overload);
      }

      stateEffects.Add(effect.SourceReference, effect);
    }

    if (batchDetails.SelectMany(static detail => detail.Equipment)
        .SelectMany(static equipment => equipment.OptionReferences)
        .Any(reference => reference != 0 && !packetStateEffects.ContainsKey(reference)))
    {
      throw new ProfileImportFailure(
          "overload_same_packet_state_effect_missing",
          ProfileImportDiagnosticScope.Overload);
    }

    foreach (var detail in batchDetails)
    {
      details.Add(detail);
    }
  }

  private static RawEquipment ParseEquipment(
      JsonElement item,
      ProfileImportEquipmentSlot slot,
      string prefix)
  {
    var options = Enumerable.Range(1, 3)
        .Select(index => NonnegativeLong(
            item,
            $"{prefix}_equip_option{index.ToString(CultureInfo.InvariantCulture)}_id",
            "equipment_value_invalid"))
        .ToArray();
    return new RawEquipment(
        slot,
        NonnegativeLong(item, $"{prefix}_equip_tid", "equipment_value_invalid"),
        NonnegativeInt(item, $"{prefix}_equip_tier", 100, "equipment_value_invalid"),
        NonnegativeInt(item, $"{prefix}_equip_lv", 5, "equipment_value_invalid"),
        NonnegativeInt(item, $"{prefix}_equip_corporation_type", 100, "equipment_value_invalid"),
        Array.AsReadOnly(options));
  }

  private static RawStateEffect ParseStateEffect(JsonElement item)
  {
    RequireObject(item, StateEffectAllowed, StateEffectRequired, "state_effect_shape_invalid");
    var sourceReference = PositiveIntegerString(item, "id", "state_effect_value_invalid");
    var details = item.GetProperty("function_details");
    RequireKind(details, JsonValueKind.Array, "state_effect_shape_invalid");
    if (details.GetArrayLength() != 1)
    {
      throw new ProfileImportFailure("state_effect_function_count_invalid", ProfileImportDiagnosticScope.Overload);
    }

    var function = details[0];
    RequireObject(function, FunctionDetailAllowed, FunctionDetailRequired, "state_effect_function_shape_invalid");
    RequireKind(function.GetProperty("function_type"), JsonValueKind.String, "state_effect_function_shape_invalid");
    RequireKind(function.GetProperty("function_value_type"), JsonValueKind.String, "state_effect_function_shape_invalid");
    Integer(function, "id", "state_effect_function_shape_invalid");
    var sourceRawValue = Integer(function, "function_value", "state_effect_function_shape_invalid");
    var contentSha256 = Sha256Digest.ComputeUtf8(item.GetRawText());
    return new RawStateEffect(sourceReference, sourceRawValue, contentSha256);
  }

  private static RawOutpost ParseOutpost(JsonElement data)
  {
    RequireObject(data, OutpostDataAllowed, OutpostDataRequired, "outpost_payload_shape_invalid");
    var outpost = data.GetProperty("outpost_info");
    RequireObject(outpost, OutpostAllowed, OutpostRequired, "outpost_shape_invalid");
    var consoles = outpost.GetProperty("recycle_room_researches");
    RequireKind(consoles, JsonValueKind.Array, "console_set_shape_invalid");
    if (consoles.GetArrayLength() != 9)
    {
      throw new ProfileImportFailure("console_set_count_invalid", ProfileImportDiagnosticScope.Console);
    }

    var result = new List<RawConsole>(9);
    foreach (var item in consoles.EnumerateArray())
    {
      RequireObject(item, ConsoleAllowed, ConsoleRequired, "console_shape_invalid");
      result.Add(new RawConsole(
          PositiveLong(item, "tid", "console_value_invalid"),
          NonnegativeInt(item, "lv", MaximumScalar, "console_value_invalid"),
          NonnegativeLong(item, "exp", "console_value_invalid")));
    }

    if (result.Select(static item => item.DefinitionReference).Distinct().Count() != 9)
    {
      throw new ProfileImportFailure("console_reference_duplicate", ProfileImportDiagnosticScope.Console);
    }

    return new RawOutpost(
        PositiveInt(outpost, "synchro_level", MaximumScalar, "outpost_value_invalid"),
        NonnegativeInt(
            outpost,
            "synchro_nonempty_slot_count",
            MaximumScalar,
            "outpost_value_invalid"),
        Array.AsReadOnly(result.ToArray()));
  }

  private static void RequireObject(
      JsonElement value,
      IReadOnlyCollection<string> allowed,
      IReadOnlyCollection<string> required,
      string code)
  {
    RequireKind(value, JsonValueKind.Object, code);
    var names = new HashSet<string>(StringComparer.Ordinal);
    foreach (var property in value.EnumerateObject())
    {
      if (!names.Add(property.Name) || !allowed.Contains(property.Name, StringComparer.Ordinal))
      {
        throw new ProfileImportFailure(code, ProfileImportDiagnosticScope.Capture);
      }
    }

    if (required.Any(name => !names.Contains(name)))
    {
      throw new ProfileImportFailure(code, ProfileImportDiagnosticScope.Capture);
    }
  }

  private static void RequireOptionalKind(
      JsonElement value,
      string propertyName,
      params JsonValueKind[] allowedKinds)
  {
    if (value.TryGetProperty(propertyName, out var property) &&
        !allowedKinds.Contains(property.ValueKind))
    {
      throw new ProfileImportFailure("optional_field_type_invalid", ProfileImportDiagnosticScope.Capture);
    }
  }

  private static void RequireKind(JsonElement value, JsonValueKind kind, string code)
  {
    if (value.ValueKind != kind)
    {
      throw new ProfileImportFailure(code, ProfileImportDiagnosticScope.Capture);
    }
  }

  private static long Integer(JsonElement value, string propertyName, string code)
  {
    var property = value.GetProperty(propertyName);
    if (property.ValueKind != JsonValueKind.Number || !property.TryGetInt64(out var result))
    {
      throw new ProfileImportFailure(code, ProfileImportDiagnosticScope.Capture);
    }

    return result;
  }

  private static long PositiveLong(JsonElement value, string propertyName, string code)
  {
    var result = Integer(value, propertyName, code);
    if (result <= 0)
    {
      throw new ProfileImportFailure(code, ProfileImportDiagnosticScope.Capture);
    }

    return result;
  }

  private static long NonnegativeLong(JsonElement value, string propertyName, string code)
  {
    var result = Integer(value, propertyName, code);
    if (result < 0)
    {
      throw new ProfileImportFailure(code, ProfileImportDiagnosticScope.Capture);
    }

    return result;
  }

  private static int PositiveInt(
      JsonElement value,
      string propertyName,
      int maximum,
      string code)
  {
    var result = PositiveLong(value, propertyName, code);
    if (result > maximum)
    {
      throw new ProfileImportFailure(code, ProfileImportDiagnosticScope.Capture);
    }

    return checked((int)result);
  }

  private static int NonnegativeInt(
      JsonElement value,
      string propertyName,
      int maximum,
      string code)
  {
    var result = NonnegativeLong(value, propertyName, code);
    if (result > maximum)
    {
      throw new ProfileImportFailure(code, ProfileImportDiagnosticScope.Capture);
    }

    return checked((int)result);
  }

  private static long PositiveIntegerString(JsonElement value, string propertyName, string code)
  {
    var property = value.GetProperty(propertyName);
    if (property.ValueKind != JsonValueKind.String ||
        !long.TryParse(
            property.GetString(),
            NumberStyles.None,
            CultureInfo.InvariantCulture,
            out var result) || result <= 0)
    {
      throw new ProfileImportFailure(code, ProfileImportDiagnosticScope.Overload);
    }

    return result;
  }

  private static SanitizedProfileImportResult Failed(
      string code,
      ProfileImportDiagnosticScope scope) => new(
          null,
          Array.AsReadOnly(new[]
          {
            new ProfileImportDiagnostic(
                code,
                ProfileImportDiagnosticSeverity.Error,
                scope,
                1)
          }));

  private static CredentialBearingProfileCoverageResult FailedCoverage(
      string code,
      ProfileImportDiagnosticScope scope) => new(
          null,
          Array.AsReadOnly(new[]
          {
            new ProfileImportDiagnostic(
                code,
                ProfileImportDiagnosticSeverity.Error,
                scope,
                1)
          }));

  private sealed record ParsedCapture(
      IReadOnlyList<RawRoster> Roster,
      IReadOnlyList<RawDetail> Details,
      IReadOnlyList<RawStateEffect> StateEffects,
      RawOutpost Outpost);

  private sealed record RawRoster(
      long CharacterReference,
      int Level,
      int LimitBreak,
      int CoreLevel,
      long CombatPower);

  private sealed record RawDetail(
      long CharacterReference,
      int Level,
      int LimitBreak,
      int CoreLevel,
      long CombatPower,
      int BondLevel,
      int Skill1Level,
      int Skill2Level,
      int BurstLevel,
      long CubeReference,
      int CubeLevel,
      long CollectionReference,
      int CollectionLevel,
      IReadOnlyList<RawEquipment> Equipment);

  private sealed record RawEquipment(
      ProfileImportEquipmentSlot Slot,
      long DefinitionReference,
      int Tier,
      int EnhancementLevel,
      int ManufacturerCode,
      IReadOnlyList<long> OptionReferences);

  private sealed record RawStateEffect(
      long SourceReference,
      long SourceRawValue,
      Sha256Digest ContentSha256);

  private sealed record RawConsole(long DefinitionReference, int Level, long Experience);

  private sealed record RawOutpost(
      int SynchroLevel,
      int OccupiedSlotCount,
      IReadOnlyList<RawConsole> Consoles);

  private sealed class ReadLimitStream : Stream
  {
    private readonly Stream _source;
    private readonly long _maximumBytes;
    private long _bytesRead;

    public ReadLimitStream(Stream source, long maximumBytes)
    {
      _source = source;
      _maximumBytes = maximumBytes;
    }

    public override bool CanRead => true;

    public override bool CanSeek => false;

    public override bool CanWrite => false;

    public override long Length => throw new NotSupportedException();

    public override long Position
    {
      get => _bytesRead;
      set => throw new NotSupportedException();
    }

    public override int Read(byte[] buffer, int offset, int count) =>
        ReadCore(buffer.AsSpan(offset, count));

    public override int Read(Span<byte> buffer) => ReadCore(buffer);

    private int ReadCore(Span<byte> buffer)
    {
      if (buffer.Length == 0)
      {
        return 0;
      }

      var remaining = _maximumBytes - _bytesRead;
      var probeLength = checked((int)Math.Min(buffer.Length, Math.Max(0, remaining) + 1));
      var read = _source.Read(buffer[..probeLength]);
      if (read > remaining)
      {
        throw new ProfileImportFailure(
            "source_size_limit_exceeded",
            ProfileImportDiagnosticScope.Capture);
      }

      _bytesRead = checked(_bytesRead + read);
      return read;
    }

    public override void Flush() => throw new NotSupportedException();

    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();

    public override void SetLength(long value) => throw new NotSupportedException();

    public override void Write(byte[] buffer, int offset, int count) =>
        throw new NotSupportedException();
  }

  private sealed class ProfileImportFailure : Exception
  {
    public ProfileImportFailure(string code, ProfileImportDiagnosticScope scope)
        : base(ControlledCode.Require(code, nameof(code)))
    {
      Code = code;
      Scope = scope;
    }

    public string Code { get; }

    public ProfileImportDiagnosticScope Scope { get; }
  }

  private sealed class DiagnosticAccumulator
  {
    private readonly Dictionary<(string Code, ProfileImportDiagnosticSeverity Severity,
        ProfileImportDiagnosticScope Scope), int> _counts = new();

    public void Add(
        string code,
        ProfileImportDiagnosticSeverity severity,
        ProfileImportDiagnosticScope scope,
        int count = 1)
    {
      var key = (ControlledCode.Require(code, nameof(code)), severity, scope);
      _counts.TryGetValue(key, out var existing);
      _counts[key] = checked(existing + count);
    }

    public IReadOnlyList<ProfileImportDiagnostic> ToReadOnly() => Array.AsReadOnly(
        _counts.OrderBy(static item => item.Key.Code, StringComparer.Ordinal)
            .ThenBy(static item => item.Key.Severity)
            .ThenBy(static item => item.Key.Scope)
            .Select(static item => new ProfileImportDiagnostic(
                item.Key.Code,
                item.Key.Severity,
                item.Key.Scope,
                item.Value))
            .ToArray());
  }
}
