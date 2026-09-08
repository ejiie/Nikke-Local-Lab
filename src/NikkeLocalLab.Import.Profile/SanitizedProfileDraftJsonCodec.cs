using System.Buffers;
using System.Globalization;
using System.Text.Json;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Import.Profile;

public sealed class SanitizedProfileDraftCodecException : Exception
{
  internal SanitizedProfileDraftCodecException(string code)
      : base(ControlledCode.Require(code, nameof(code)))
  {
    Code = code;
  }

  public string Code { get; }
}

public static class SanitizedProfileDraftJsonCodec
{
  private const int MaximumCanonicalBytes = 16 * 1024 * 1024;
  private const int MaximumScalar = 1_000_000;
  private const int MaximumBuilds = 1_024;
  private const string TimestampFormat = "yyyy-MM-dd'T'HH:mm:ss.ffffff'Z'";

  public static SanitizedProfileDraft Rebase(
      SanitizedProfileDraft source,
      DateTimeOffset derivedAtUtc,
      Sha256Digest transformerBinarySha256,
      ProfileImportCatalogBinding targetCharacterCatalog,
      ProfileImportCatalogBinding targetCombatSupportCatalog,
      IReadOnlyDictionary<EntityUid, EntityUid> explicitMappings)
  {
    if (source is null || targetCharacterCatalog is null || targetCombatSupportCatalog is null ||
        explicitMappings is null)
    {
      throw Failure("sanitized_draft_rebase_input_invalid");
    }

    Validate(source);
    var plan = CreateRebasePlan(
        source,
        targetCharacterCatalog,
        targetCombatSupportCatalog,
        explicitMappings);
    return CreateDerived(
        SanitizedProfileTransformerProfile.CatalogRebase,
        derivedAtUtc,
        transformerBinarySha256,
        targetCharacterCatalog,
        targetCombatSupportCatalog,
        plan.AccountState,
        plan.Builds,
        plan.ReviewedOverrides);
  }

  public static SanitizedProfileDraft ApplyReviewedOverrides(
      SanitizedProfileDraft source,
      DateTimeOffset derivedAtUtc,
      Sha256Digest transformerBinarySha256,
      IReadOnlyList<SanitizedProfileReviewedOverrideRequest> overrides)
  {
    if (source is null || overrides is null || overrides.Count is <= 0 or > MaximumBuilds * 5)
    {
      throw Failure("sanitized_draft_override_input_invalid");
    }

    Validate(source);
    var applied = ApplyOverrides(source, overrides);
    return CreateDerived(
        SanitizedProfileTransformerProfile.ReviewedOverride,
        derivedAtUtc,
        transformerBinarySha256,
        source.CharacterCatalog,
        source.CombatSupportCatalog,
        source.AccountState,
        applied.Builds,
        applied.ReviewedOverrides);
  }

  public static byte[] Encode(SanitizedProfileDraft draft)
  {
    Validate(draft);
    var buffer = new ArrayBufferWriter<byte>();
    using (var writer = new Utf8JsonWriter(buffer, new JsonWriterOptions
    {
      Indented = false,
      SkipValidation = false
    }))
    {
      WriteDraft(writer, draft);
    }

    if (buffer.WrittenCount > MaximumCanonicalBytes)
    {
      throw Failure("sanitized_draft_json_size_exceeded");
    }

    return buffer.WrittenSpan.ToArray();
  }

  public static SanitizedProfileDraft Decode(ReadOnlySpan<byte> canonicalUtf8Json)
  {
    if (canonicalUtf8Json.Length is <= 0 or > MaximumCanonicalBytes)
    {
      throw Failure("sanitized_draft_json_size_invalid");
    }

    try
    {
      using var document = JsonDocument.Parse(canonicalUtf8Json.ToArray(), new JsonDocumentOptions
      {
        AllowTrailingCommas = false,
        CommentHandling = JsonCommentHandling.Disallow,
        MaxDepth = 16
      });
      var draft = ParseDraft(document.RootElement);
      Validate(draft);
      var encoded = Encode(draft);
      if (!canonicalUtf8Json.SequenceEqual(encoded))
      {
        throw Failure("sanitized_draft_json_not_canonical");
      }

      return draft;
    }
    catch (SanitizedProfileDraftCodecException)
    {
      throw;
    }
    catch (Exception exception) when (exception is JsonException or FormatException or
        ArgumentException or InvalidOperationException or OverflowException)
    {
      throw Failure("sanitized_draft_json_invalid");
    }
  }

  private static void WriteDraft(Utf8JsonWriter writer, SanitizedProfileDraft draft)
  {
    writer.WriteStartObject();
    writer.WriteString("schema_code", draft.Provenance.SchemaCode);
    WriteProvenance(writer, draft.Provenance);
    WriteBinding(writer, "character_catalog", draft.CharacterCatalog);
    WriteBinding(writer, "combat_support_catalog", draft.CombatSupportCatalog);
    WriteAccountState(writer, draft.AccountState);
    writer.WritePropertyName("builds");
    writer.WriteStartArray();
    foreach (var build in draft.Builds)
    {
      WriteBuild(writer, build);
    }

    writer.WriteEndArray();
    writer.WritePropertyName("reviewed_overrides");
    writer.WriteStartArray();
    foreach (var reviewedOverride in draft.ReviewedOverrides)
    {
      WriteReviewedOverride(writer, reviewedOverride);
    }

    writer.WriteEndArray();
    writer.WriteBoolean(
        "can_materialize_local_account_profile",
        draft.CanMaterializeLocalAccountProfile);
    writer.WriteBoolean("is_local_account_profile_write_ready", draft.IsLocalAccountProfileWriteReady);
    writer.WriteEndObject();
  }

  private static void WriteProvenance(
      Utf8JsonWriter writer,
      SanitizedProfileImportProvenance provenance)
  {
    writer.WritePropertyName("provenance");
    writer.WriteStartObject();
    writer.WriteString("source_schema_sha256", provenance.SourceSchemaSha256.Hex);
    writer.WriteString("transformer_id", provenance.TransformerId);
    writer.WriteString("transformer_version", provenance.TransformerVersion);
    writer.WriteString("transformer_fingerprint_sha256", provenance.TransformerFingerprintSha256.Hex);
    writer.WriteString("transformer_binary_sha256", provenance.TransformerBinarySha256.Hex);
    writer.WriteString("semantic_options_sha256", provenance.SemanticOptionsSha256.Hex);
    writer.WriteString("sanitized_payload_sha256", provenance.SanitizedPayloadSha256.Hex);
    writer.WriteString(
        "imported_at_utc",
        provenance.ImportedAtUtc.UtcDateTime.ToString(TimestampFormat, CultureInfo.InvariantCulture));
    writer.WritePropertyName("capture_time");
    WriteTimestampFact(writer, provenance.CaptureTime);
    writer.WriteString("capture_atomicity", CaptureAtomicityCode(provenance.CaptureAtomicity));
    writer.WriteString("source_hash_policy", SourceHashPolicyCode(provenance.SourceHashPolicy));
    writer.WriteEndObject();
  }

  private static void WriteBinding(
      Utf8JsonWriter writer,
      string propertyName,
      ProfileImportCatalogBinding binding)
  {
    writer.WritePropertyName(propertyName);
    writer.WriteStartObject();
    writer.WriteString("catalog_snapshot_uid", binding.CatalogSnapshotUid.ToString());
    writer.WriteString("dataset_snapshot_uid", binding.DatasetSnapshotUid.ToString());
    writer.WriteString("manifest_sha256", binding.ManifestSha256.Hex);
    writer.WriteEndObject();
  }

  private static void WriteAccountState(
      Utf8JsonWriter writer,
      SanitizedAccountCombatStateDraft accountState)
  {
    writer.WritePropertyName("account_state");
    writer.WriteStartObject();
    writer.WriteNumber("synchro_level", accountState.SynchroLevel);
    writer.WriteNumber(
        "occupied_synchro_slot_count_observation",
        accountState.OccupiedSynchroSlotCountObservation);
    writer.WritePropertyName("consoles");
    writer.WriteStartArray();
    foreach (var console in accountState.Consoles)
    {
      writer.WriteStartObject();
      writer.WriteString("coordinate", ConsoleCode(console.Coordinate));
      writer.WriteString("definition_uid", console.DefinitionUid.ToString());
      writer.WriteNumber("level", console.Level);
      writer.WriteNumber("observed_experience", console.ObservedExperience);
      writer.WriteEndObject();
    }

    writer.WriteEndArray();
    writer.WriteEndObject();
  }

  private static void WriteBuild(Utf8JsonWriter writer, SanitizedCharacterBuildDraft build)
  {
    writer.WriteStartObject();
    writer.WriteString("character_uid", build.CharacterUid.ToString());
    writer.WritePropertyName("level");
    writer.WriteStartObject();
    writer.WriteNumber("roster_level", build.Level.RosterLevel);
    writer.WriteNumber("detail_level", build.Level.DetailLevel);
    writer.WritePropertyName("resolved_battle_level");
    WriteIntFact(writer, build.Level.ResolvedBattleLevel);
    if (build.Level.AuthorityPolicyCode is null)
    {
      writer.WriteNull("authority_policy_code");
    }
    else
    {
      writer.WriteString("authority_policy_code", build.Level.AuthorityPolicyCode);
    }

    writer.WriteEndObject();
    writer.WriteNumber("limit_break", build.LimitBreak);
    writer.WriteNumber("core_level", build.CoreLevel);
    writer.WriteNumber("bond_level_observation", build.BondLevelObservation);
    writer.WritePropertyName("resolved_bond_level");
    WriteIntFact(writer, build.ResolvedBondLevel);
    writer.WriteNumber("skill1_level", build.Skill1Level);
    writer.WriteNumber("skill2_level", build.Skill2Level);
    writer.WriteNumber("burst_level", build.BurstLevel);
    writer.WriteNumber("roster_combat_power_observation", build.RosterCombatPowerObservation);
    writer.WriteNumber("detail_combat_power_observation", build.DetailCombatPowerObservation);
    writer.WritePropertyName("equipment");
    writer.WriteStartArray();
    foreach (var equipment in build.Equipment)
    {
      WriteEquipment(writer, equipment);
    }

    writer.WriteEndArray();
    WriteCube(writer, build.Cube);
    WriteCollection(writer, build.Collection);
    writer.WriteEndObject();
  }

  private static void WriteEquipment(
      Utf8JsonWriter writer,
      SanitizedEquipmentSelection equipment)
  {
    writer.WriteStartObject();
    writer.WriteString("slot", EquipmentSlotCode(equipment.Slot));
    writer.WriteString("state", AttachmentStateCode(equipment.State));
    WriteNullableUid(writer, "definition_uid", equipment.DefinitionUid);
    WriteNullableInt(writer, "enhancement_level", equipment.EnhancementLevel);
    writer.WritePropertyName("manufacturer_matched_observation");
    if (equipment.ManufacturerMatchedObservation is null)
    {
      writer.WriteNullValue();
    }
    else
    {
      WriteBoolFact(writer, equipment.ManufacturerMatchedObservation);
    }

    writer.WritePropertyName("resolved_manufacturer_matched");
    if (equipment.ResolvedManufacturerMatched is null)
    {
      writer.WriteNullValue();
    }
    else
    {
      WriteBoolFact(writer, equipment.ResolvedManufacturerMatched);
    }

    writer.WritePropertyName("overload_lines");
    writer.WriteStartArray();
    foreach (var line in equipment.OverloadLines)
    {
      writer.WriteStartObject();
      writer.WriteNumber("line_index", line.LineIndex);
      writer.WriteString("option_definition_uid", line.OptionDefinitionUid.ToString());
      writer.WriteString("unit", ValueUnitCode(line.Unit));
      writer.WritePropertyName("exact_value");
      WriteExactValue(writer, line.ExactValue);
      writer.WriteEndObject();
    }

    writer.WriteEndArray();
    writer.WriteEndObject();
  }

  private static void WriteReviewedOverride(
      Utf8JsonWriter writer,
      SanitizedProfileReviewedOverride reviewedOverride)
  {
    writer.WriteStartObject();
    writer.WriteString("kind", ReviewedOverrideKindCode(reviewedOverride.Kind));
    writer.WriteString("character_uid", reviewedOverride.CharacterUid.ToString());
    if (reviewedOverride.EquipmentSlot.HasValue)
    {
      writer.WriteString("equipment_slot", EquipmentSlotCode(reviewedOverride.EquipmentSlot.Value));
    }
    else
    {
      writer.WriteNull("equipment_slot");
    }

    WriteNullableInt(writer, "integer_value", reviewedOverride.IntegerValue);
    if (reviewedOverride.BooleanValue.HasValue)
    {
      writer.WriteBoolean("boolean_value", reviewedOverride.BooleanValue.Value);
    }
    else
    {
      writer.WriteNull("boolean_value");
    }

    writer.WriteString("original_reason_code", reviewedOverride.OriginalReasonCode);
    writer.WriteString("reason_code", reviewedOverride.ReasonCode);
    writer.WriteEndObject();
  }

  private static void WriteCube(Utf8JsonWriter writer, SanitizedCubeSelection cube)
  {
    writer.WritePropertyName("cube");
    writer.WriteStartObject();
    writer.WriteString("state", AttachmentStateCode(cube.State));
    WriteNullableUid(writer, "definition_uid", cube.DefinitionUid);
    WriteNullableInt(writer, "level", cube.Level);
    writer.WriteEndObject();
  }

  private static void WriteCollection(
      Utf8JsonWriter writer,
      SanitizedCollectionSelection collection)
  {
    writer.WritePropertyName("collection");
    writer.WriteStartObject();
    writer.WriteString("kind", CollectionKindCode(collection.Kind));
    WriteNullableUid(writer, "definition_uid", collection.DefinitionUid);
    WriteNullableInt(writer, "level", collection.Level);
    writer.WriteEndObject();
  }

  private static void WriteIntFact(Utf8JsonWriter writer, ProfileImportFact<int> fact)
  {
    writer.WriteStartObject();
    writer.WriteString("status", FactStatusCode(fact.Status));
    if (fact.Status == ProfileImportFactStatus.Ready)
    {
      writer.WriteNumber("value", fact.Value!.Value);
    }
    else if (fact.Status == ProfileImportFactStatus.Unresolved)
    {
      writer.WriteString("reason_code", fact.ReasonCode);
    }

    writer.WriteEndObject();
  }

  private static void WriteBoolFact(Utf8JsonWriter writer, ProfileImportFact<bool> fact)
  {
    writer.WriteStartObject();
    writer.WriteString("status", FactStatusCode(fact.Status));
    if (fact.Status == ProfileImportFactStatus.Ready)
    {
      writer.WriteBoolean("value", fact.Value!.Value);
    }
    else if (fact.Status == ProfileImportFactStatus.Unresolved)
    {
      writer.WriteString("reason_code", fact.ReasonCode);
    }

    writer.WriteEndObject();
  }

  private static void WriteTimestampFact(
      Utf8JsonWriter writer,
      ProfileImportFact<DateTimeOffset> fact)
  {
    writer.WriteStartObject();
    writer.WriteString("status", FactStatusCode(fact.Status));
    if (fact.Status == ProfileImportFactStatus.Ready)
    {
      writer.WriteString(
          "value",
          fact.Value!.Value.UtcDateTime.ToString(TimestampFormat, CultureInfo.InvariantCulture));
    }
    else if (fact.Status == ProfileImportFactStatus.Unresolved)
    {
      writer.WriteString("reason_code", fact.ReasonCode);
    }

    writer.WriteEndObject();
  }

  private static void WriteExactValue(Utf8JsonWriter writer, ProfileImportExactValue value)
  {
    writer.WriteStartObject();
    writer.WriteNumber("unscaled_value", value.UnscaledValue);
    writer.WriteNumber("decimal_scale", value.DecimalScale);
    writer.WriteEndObject();
  }

  private static void WriteNullableUid(
      Utf8JsonWriter writer,
      string propertyName,
      EntityUid? value)
  {
    if (value.HasValue)
    {
      writer.WriteString(propertyName, value.Value.ToString());
    }
    else
    {
      writer.WriteNull(propertyName);
    }
  }

  private static void WriteNullableInt(Utf8JsonWriter writer, string propertyName, int? value)
  {
    if (value.HasValue)
    {
      writer.WriteNumber(propertyName, value.Value);
    }
    else
    {
      writer.WriteNull(propertyName);
    }
  }

  private static SanitizedProfileDraft ParseDraft(JsonElement root)
  {
    RequireObject(
        root,
        "sanitized_draft_root_shape_invalid",
        "schema_code",
        "provenance",
        "character_catalog",
        "combat_support_catalog",
        "account_state",
        "builds",
        "reviewed_overrides",
        "can_materialize_local_account_profile",
        "is_local_account_profile_write_ready");
    var schemaCode = ReadString(root, "schema_code");
    var provenance = ParseProvenance(root.GetProperty("provenance"), schemaCode);
    var characterCatalog = ParseBinding(root.GetProperty("character_catalog"));
    var combatSupportCatalog = ParseBinding(root.GetProperty("combat_support_catalog"));
    var accountState = ParseAccountState(root.GetProperty("account_state"));
    var buildsElement = root.GetProperty("builds");
    RequireKind(buildsElement, JsonValueKind.Array, "sanitized_draft_builds_shape_invalid");
    if (buildsElement.GetArrayLength() is <= 0 or > MaximumBuilds)
    {
      throw Failure("sanitized_draft_build_count_invalid");
    }

    var builds = buildsElement.EnumerateArray().Select(ParseBuild).ToArray();
    var overridesElement = root.GetProperty("reviewed_overrides");
    RequireKind(
        overridesElement,
        JsonValueKind.Array,
        "sanitized_draft_reviewed_override_set_shape_invalid");
    if (overridesElement.GetArrayLength() > MaximumBuilds * 5)
    {
      throw Failure("sanitized_draft_reviewed_override_count_invalid");
    }

    var reviewedOverrides = overridesElement.EnumerateArray()
        .Select(ParseReviewedOverride)
        .ToArray();
    return new SanitizedProfileDraft(
        provenance,
        characterCatalog,
        combatSupportCatalog,
        accountState,
        Array.AsReadOnly(builds),
        Array.AsReadOnly(reviewedOverrides),
        ReadBoolean(root, "can_materialize_local_account_profile"),
        ReadBoolean(root, "is_local_account_profile_write_ready"));
  }

  private static SanitizedProfileImportProvenance ParseProvenance(
      JsonElement value,
      string schemaCode)
  {
    RequireObject(
        value,
        "sanitized_draft_provenance_shape_invalid",
        "source_schema_sha256",
        "transformer_id",
        "transformer_version",
        "transformer_fingerprint_sha256",
        "transformer_binary_sha256",
        "semantic_options_sha256",
        "sanitized_payload_sha256",
        "imported_at_utc",
        "capture_time",
        "capture_atomicity",
        "source_hash_policy");
    return new SanitizedProfileImportProvenance(
        schemaCode,
        ReadDigest(value, "source_schema_sha256"),
        ReadControlledCode(value, "transformer_id"),
        ReadControlledCode(value, "transformer_version"),
        ReadDigest(value, "transformer_fingerprint_sha256"),
        ReadDigest(value, "transformer_binary_sha256"),
        ReadDigest(value, "semantic_options_sha256"),
        ReadDigest(value, "sanitized_payload_sha256"),
        ReadTimestamp(value, "imported_at_utc"),
        ParseTimestampFact(value.GetProperty("capture_time")),
        ParseCaptureAtomicity(ReadString(value, "capture_atomicity")),
        ParseSourceHashPolicy(ReadString(value, "source_hash_policy")));
  }

  private static ProfileImportCatalogBinding ParseBinding(JsonElement value)
  {
    RequireObject(
        value,
        "sanitized_draft_catalog_binding_shape_invalid",
        "catalog_snapshot_uid",
        "dataset_snapshot_uid",
        "manifest_sha256");
    return new ProfileImportCatalogBinding(
        ReadUid(value, "catalog_snapshot_uid"),
        ReadUid(value, "dataset_snapshot_uid"),
        ReadDigest(value, "manifest_sha256"));
  }

  private static SanitizedAccountCombatStateDraft ParseAccountState(JsonElement value)
  {
    RequireObject(
        value,
        "sanitized_draft_account_state_shape_invalid",
        "synchro_level",
        "occupied_synchro_slot_count_observation",
        "consoles");
    var consolesElement = value.GetProperty("consoles");
    RequireKind(consolesElement, JsonValueKind.Array, "sanitized_draft_console_set_shape_invalid");
    if (consolesElement.GetArrayLength() != 9)
    {
      throw Failure("sanitized_draft_console_set_invalid");
    }

    var consoles = consolesElement.EnumerateArray().Select(ParseConsole).ToArray();
    return new SanitizedAccountCombatStateDraft(
        ReadInt32(value, "synchro_level"),
        ReadInt32(value, "occupied_synchro_slot_count_observation"),
        Array.AsReadOnly(consoles));
  }

  private static SanitizedConsoleState ParseConsole(JsonElement value)
  {
    RequireObject(
        value,
        "sanitized_draft_console_shape_invalid",
        "coordinate",
        "definition_uid",
        "level",
        "observed_experience");
    return new SanitizedConsoleState(
        ParseConsoleCoordinate(ReadString(value, "coordinate")),
        ReadUid(value, "definition_uid"),
        ReadInt32(value, "level"),
        ReadInt64(value, "observed_experience"));
  }

  private static SanitizedCharacterBuildDraft ParseBuild(JsonElement value)
  {
    RequireObject(
        value,
        "sanitized_draft_build_shape_invalid",
        "character_uid",
        "level",
        "limit_break",
        "core_level",
        "bond_level_observation",
        "resolved_bond_level",
        "skill1_level",
        "skill2_level",
        "burst_level",
        "roster_combat_power_observation",
        "detail_combat_power_observation",
        "equipment",
        "cube",
        "collection");
    var equipmentElement = value.GetProperty("equipment");
    RequireKind(equipmentElement, JsonValueKind.Array, "sanitized_draft_equipment_set_shape_invalid");
    if (equipmentElement.GetArrayLength() != 4)
    {
      throw Failure("sanitized_draft_equipment_set_invalid");
    }

    var equipment = equipmentElement.EnumerateArray().Select(ParseEquipment).ToArray();
    return new SanitizedCharacterBuildDraft(
        ReadUid(value, "character_uid"),
        ParseLevel(value.GetProperty("level")),
        ReadInt32(value, "limit_break"),
        ReadInt32(value, "core_level"),
        ReadInt32(value, "bond_level_observation"),
        ParseIntFact(value.GetProperty("resolved_bond_level")),
        ReadInt32(value, "skill1_level"),
        ReadInt32(value, "skill2_level"),
        ReadInt32(value, "burst_level"),
        ReadInt64(value, "roster_combat_power_observation"),
        ReadInt64(value, "detail_combat_power_observation"),
        Array.AsReadOnly(equipment),
        ParseCube(value.GetProperty("cube")),
        ParseCollection(value.GetProperty("collection")));
  }

  private static SanitizedCharacterLevelObservation ParseLevel(JsonElement value)
  {
    RequireObject(
        value,
        "sanitized_draft_level_shape_invalid",
        "roster_level",
        "detail_level",
        "resolved_battle_level",
        "authority_policy_code");
    return new SanitizedCharacterLevelObservation(
        ReadInt32(value, "roster_level"),
        ReadInt32(value, "detail_level"),
        ParseIntFact(value.GetProperty("resolved_battle_level")),
        ReadNullableString(value, "authority_policy_code"));
  }

  private static SanitizedEquipmentSelection ParseEquipment(JsonElement value)
  {
    RequireObject(
        value,
        "sanitized_draft_equipment_shape_invalid",
        "slot",
        "state",
        "definition_uid",
        "enhancement_level",
        "manufacturer_matched_observation",
        "resolved_manufacturer_matched",
        "overload_lines");
    var linesElement = value.GetProperty("overload_lines");
    RequireKind(linesElement, JsonValueKind.Array, "sanitized_draft_overload_set_shape_invalid");
    if (linesElement.GetArrayLength() > 3)
    {
      throw Failure("sanitized_draft_overload_set_invalid");
    }

    var manufacturerObservationElement = value.GetProperty("manufacturer_matched_observation");
    var manufacturerObservation = manufacturerObservationElement.ValueKind == JsonValueKind.Null
        ? null
        : ParseBoolFact(manufacturerObservationElement);
    var resolvedManufacturerElement = value.GetProperty("resolved_manufacturer_matched");
    var resolvedManufacturer = resolvedManufacturerElement.ValueKind == JsonValueKind.Null
        ? null
        : ParseBoolFact(resolvedManufacturerElement);
    return new SanitizedEquipmentSelection(
        ParseEquipmentSlot(ReadString(value, "slot")),
        ParseAttachmentState(ReadString(value, "state")),
        ReadNullableUid(value, "definition_uid"),
        ReadNullableInt32(value, "enhancement_level"),
        manufacturerObservation,
        resolvedManufacturer,
        Array.AsReadOnly(linesElement.EnumerateArray().Select(ParseOverloadLine).ToArray()));
  }

  private static SanitizedProfileReviewedOverride ParseReviewedOverride(JsonElement value)
  {
    RequireObject(
        value,
        "sanitized_draft_reviewed_override_shape_invalid",
        "kind",
        "character_uid",
        "equipment_slot",
        "integer_value",
        "boolean_value",
        "original_reason_code",
        "reason_code");
    var slotElement = value.GetProperty("equipment_slot");
    var slot = slotElement.ValueKind == JsonValueKind.Null
        ? (ProfileImportEquipmentSlot?)null
        : ParseEquipmentSlot(ReadString(value, "equipment_slot"));
    return new SanitizedProfileReviewedOverride(
        ParseReviewedOverrideKind(ReadString(value, "kind")),
        ReadUid(value, "character_uid"),
        slot,
        ReadNullableInt32(value, "integer_value"),
        ReadNullableBoolean(value, "boolean_value"),
        ReadControlledCode(value, "original_reason_code"),
        ReadControlledCode(value, "reason_code"));
  }

  private static SanitizedOverloadLine ParseOverloadLine(JsonElement value)
  {
    RequireObject(
        value,
        "sanitized_draft_overload_shape_invalid",
        "line_index",
        "option_definition_uid",
        "unit",
        "exact_value");
    return new SanitizedOverloadLine(
        ReadInt32(value, "line_index"),
        ReadUid(value, "option_definition_uid"),
        ParseValueUnit(ReadString(value, "unit")),
        ParseExactValue(value.GetProperty("exact_value")));
  }

  private static SanitizedCubeSelection ParseCube(JsonElement value)
  {
    RequireObject(
        value,
        "sanitized_draft_cube_shape_invalid",
        "state",
        "definition_uid",
        "level");
    return new SanitizedCubeSelection(
        ParseAttachmentState(ReadString(value, "state")),
        ReadNullableUid(value, "definition_uid"),
        ReadNullableInt32(value, "level"));
  }

  private static SanitizedCollectionSelection ParseCollection(JsonElement value)
  {
    RequireObject(
        value,
        "sanitized_draft_collection_shape_invalid",
        "kind",
        "definition_uid",
        "level");
    return new SanitizedCollectionSelection(
        ParseCollectionKind(ReadString(value, "kind")),
        ReadNullableUid(value, "definition_uid"),
        ReadNullableInt32(value, "level"));
  }

  private static ProfileImportExactValue ParseExactValue(JsonElement value)
  {
    RequireObject(
        value,
        "sanitized_draft_exact_value_shape_invalid",
        "unscaled_value",
        "decimal_scale");
    return new ProfileImportExactValue(
        ReadInt64(value, "unscaled_value"),
        ReadInt32(value, "decimal_scale"));
  }

  private static ProfileImportFact<int> ParseIntFact(JsonElement value)
  {
    RequireKind(value, JsonValueKind.Object, "sanitized_draft_fact_shape_invalid");
    var status = ParseFactStatus(ReadString(value, "status"));
    if (status == ProfileImportFactStatus.Ready)
    {
      RequireObject(value, "sanitized_draft_fact_shape_invalid", "status", "value");
      return ProfileImportFact<int>.Ready(ReadInt32(value, "value"));
    }

    if (status == ProfileImportFactStatus.NotApplicable)
    {
      RequireObject(value, "sanitized_draft_fact_shape_invalid", "status");
      return ProfileImportFact<int>.NotApplicable();
    }

    RequireObject(value, "sanitized_draft_fact_shape_invalid", "status", "reason_code");
    return ProfileImportFact<int>.Unresolved(ReadControlledCode(value, "reason_code"));
  }

  private static ProfileImportFact<bool> ParseBoolFact(JsonElement value)
  {
    RequireKind(value, JsonValueKind.Object, "sanitized_draft_fact_shape_invalid");
    var status = ParseFactStatus(ReadString(value, "status"));
    if (status == ProfileImportFactStatus.Ready)
    {
      RequireObject(value, "sanitized_draft_fact_shape_invalid", "status", "value");
      return ProfileImportFact<bool>.Ready(ReadBoolean(value, "value"));
    }

    if (status == ProfileImportFactStatus.NotApplicable)
    {
      RequireObject(value, "sanitized_draft_fact_shape_invalid", "status");
      return ProfileImportFact<bool>.NotApplicable();
    }

    RequireObject(value, "sanitized_draft_fact_shape_invalid", "status", "reason_code");
    return ProfileImportFact<bool>.Unresolved(ReadControlledCode(value, "reason_code"));
  }

  private static ProfileImportFact<DateTimeOffset> ParseTimestampFact(JsonElement value)
  {
    RequireKind(value, JsonValueKind.Object, "sanitized_draft_fact_shape_invalid");
    var status = ParseFactStatus(ReadString(value, "status"));
    if (status == ProfileImportFactStatus.Ready)
    {
      RequireObject(value, "sanitized_draft_fact_shape_invalid", "status", "value");
      return ProfileImportFact<DateTimeOffset>.Ready(ReadTimestamp(value, "value"));
    }

    if (status == ProfileImportFactStatus.NotApplicable)
    {
      RequireObject(value, "sanitized_draft_fact_shape_invalid", "status");
      return ProfileImportFact<DateTimeOffset>.NotApplicable();
    }

    RequireObject(value, "sanitized_draft_fact_shape_invalid", "status", "reason_code");
    return ProfileImportFact<DateTimeOffset>.Unresolved(ReadControlledCode(value, "reason_code"));
  }

  private static void Validate(SanitizedProfileDraft? draft)
  {
    if (draft is null || draft.Provenance is null || draft.CharacterCatalog is null ||
        draft.CombatSupportCatalog is null || draft.AccountState is null || draft.Builds is null ||
        draft.ReviewedOverrides is null)
    {
      throw Failure("sanitized_draft_shape_invalid");
    }

    var transformerProfile = ValidateProvenance(draft.Provenance);
    var payload = ValidatePayload(
        draft.CharacterCatalog,
        draft.CombatSupportCatalog,
        draft.AccountState,
        draft.Builds,
        draft.ReviewedOverrides);
    if ((transformerProfile == SanitizedProfileTransformerProfile.OfflineRawSanitizer &&
         draft.ReviewedOverrides.Count != 0) ||
        (transformerProfile == SanitizedProfileTransformerProfile.ReviewedOverride &&
         draft.ReviewedOverrides.Count == 0))
    {
      throw Failure("sanitized_draft_transformer_payload_mismatch");
    }

    var expectedOptions = OfflineProfileImportOptions.ComputeSemanticOptionsSha256(
        payload.Authority,
        transformerProfile);
    if (draft.Provenance.SemanticOptionsSha256 != expectedOptions)
    {
      throw Failure("sanitized_draft_semantic_options_mismatch");
    }

    if (draft.CanMaterializeLocalAccountProfile != payload.CanMaterialize ||
        draft.IsLocalAccountProfileWriteReady != payload.IsWriteReady)
    {
      throw Failure("sanitized_draft_write_readiness_mismatch");
    }

    var expectedHash = SanitizedProfileCanonicalizer.Compute(
        draft.CharacterCatalog,
        draft.CombatSupportCatalog,
        draft.AccountState,
        draft.Builds,
        draft.ReviewedOverrides,
        draft.Provenance.SourceSchemaSha256,
        draft.Provenance.TransformerFingerprintSha256,
        draft.Provenance.TransformerBinarySha256,
        draft.Provenance.SemanticOptionsSha256);
    if (expectedHash != draft.Provenance.SanitizedPayloadSha256)
    {
      throw Failure("sanitized_draft_hash_mismatch");
    }
  }

  private static (CharacterLevelAuthorityPolicy? Authority, bool CanMaterialize, bool IsWriteReady)
      ValidatePayload(
      ProfileImportCatalogBinding characterCatalog,
      ProfileImportCatalogBinding combatSupportCatalog,
      SanitizedAccountCombatStateDraft accountState,
      IReadOnlyList<SanitizedCharacterBuildDraft> builds,
      IReadOnlyList<SanitizedProfileReviewedOverride> reviewedOverrides)
  {
    ValidateBinding(characterCatalog);
    ValidateBinding(combatSupportCatalog);
    ValidateAccountState(accountState);
    if (builds.Count is <= 0 or > MaximumBuilds ||
        builds.Any(static build => build is null) ||
        builds.Select(static build => build.CharacterUid).Distinct().Count() != builds.Count ||
        !builds.Select(static build => build.CharacterUid.ToString()).SequenceEqual(
            builds.Select(static build => build.CharacterUid.ToString())
                .OrderBy(static value => value, StringComparer.Ordinal)))
    {
      throw Failure("sanitized_draft_build_set_invalid");
    }

    CharacterLevelAuthorityPolicy? authority = null;
    var authorityInitialized = false;
    foreach (var build in builds)
    {
      var buildAuthority = ValidateBuild(build);
      if (!authorityInitialized)
      {
        authority = buildAuthority;
        authorityInitialized = true;
      }
      else if (authority != buildAuthority)
      {
        throw Failure("sanitized_draft_level_authority_mixed");
      }
    }

    ValidateReviewedOverrides(builds, reviewedOverrides);
    var canMaterialize = authority.HasValue;
    var isWriteReady = canMaterialize && builds.All(static build =>
        build.Level.ResolvedBattleLevel.Status == ProfileImportFactStatus.Ready &&
        build.ResolvedBondLevel.Status != ProfileImportFactStatus.Unresolved &&
        build.Equipment.All(static equipment =>
            equipment.State == ProfileImportAttachmentState.Unequipped ||
            equipment.ResolvedManufacturerMatched?.Status !=
                ProfileImportFactStatus.Unresolved));
    return (authority, canMaterialize, isWriteReady);
  }

  private static SanitizedProfileDraft CreateDerived(
      SanitizedProfileTransformerProfile transformerProfile,
      DateTimeOffset derivedAtUtc,
      Sha256Digest transformerBinarySha256,
      ProfileImportCatalogBinding characterCatalog,
      ProfileImportCatalogBinding combatSupportCatalog,
      SanitizedAccountCombatStateDraft accountState,
      IReadOnlyList<SanitizedCharacterBuildDraft> builds,
      IReadOnlyList<SanitizedProfileReviewedOverride> reviewedOverrides)
  {
    if (derivedAtUtc.Offset != TimeSpan.Zero || derivedAtUtc.Ticks % 10 != 0 ||
        transformerBinarySha256 == default || characterCatalog is null ||
        combatSupportCatalog is null || accountState is null || builds is null ||
        reviewedOverrides is null)
    {
      throw Failure("sanitized_draft_derived_input_invalid");
    }

    var descriptor = transformerProfile switch
    {
      SanitizedProfileTransformerProfile.CatalogRebase =>
          SanitizedProfileDraftContract.RebaseTransformer,
      SanitizedProfileTransformerProfile.ReviewedOverride =>
          SanitizedProfileDraftContract.ReviewedOverrideTransformer,
      _ => throw Failure("sanitized_draft_derived_transformer_invalid")
    };
    var copiedAccountState = CopyAccountState(accountState);
    var copiedBuilds = CopyBuilds(builds);
    var copiedOverrides = CopyReviewedOverrides(reviewedOverrides);
    var payload = ValidatePayload(
        characterCatalog,
        combatSupportCatalog,
        copiedAccountState,
        copiedBuilds,
        copiedOverrides);
    var semanticOptionsSha256 = OfflineProfileImportOptions.ComputeSemanticOptionsSha256(
        payload.Authority,
        transformerProfile);
    var sanitizedPayloadSha256 = SanitizedProfileCanonicalizer.Compute(
        characterCatalog,
        combatSupportCatalog,
        copiedAccountState,
        copiedBuilds,
        copiedOverrides,
        descriptor.ContractSha256,
        descriptor.FingerprintSha256,
        transformerBinarySha256,
        semanticOptionsSha256);
    var provenance = new SanitizedProfileImportProvenance(
        SanitizedProfileDraftContract.SchemaCode,
        descriptor.ContractSha256,
        descriptor.ExtractorId,
        descriptor.ExtractorVersion,
        descriptor.FingerprintSha256,
        transformerBinarySha256,
        semanticOptionsSha256,
        sanitizedPayloadSha256,
        derivedAtUtc,
        ProfileImportFact<DateTimeOffset>.Unresolved("capture_time_not_observed"),
        ProfileCaptureAtomicity.Unresolved,
        CredentialBearingSourceHashPolicy.Prohibited);
    var draft = new SanitizedProfileDraft(
        provenance,
        characterCatalog,
        combatSupportCatalog,
        copiedAccountState,
        copiedBuilds,
        copiedOverrides,
        payload.CanMaterialize,
        payload.IsWriteReady);
    Validate(draft);
    return draft;
  }

  private static (
      SanitizedAccountCombatStateDraft AccountState,
      IReadOnlyList<SanitizedCharacterBuildDraft> Builds,
      IReadOnlyList<SanitizedProfileReviewedOverride> ReviewedOverrides) CreateRebasePlan(
      SanitizedProfileDraft source,
      ProfileImportCatalogBinding targetCharacterCatalog,
      ProfileImportCatalogBinding targetCombatSupportCatalog,
      IReadOnlyDictionary<EntityUid, EntityUid> explicitMappings)
  {
    var characterChanged = source.CharacterCatalog != targetCharacterCatalog;
    var supportChanged = source.CombatSupportCatalog != targetCombatSupportCatalog;
    if (!characterChanged && !supportChanged)
    {
      throw Failure("sanitized_draft_rebase_target_unchanged");
    }

    var characterReferences = source.Builds.Select(static build => build.CharacterUid).ToHashSet();
    var supportReferences = source.AccountState.Consoles
        .Select(static console => console.DefinitionUid)
        .Concat(source.Builds.SelectMany(static build => build.Equipment)
            .Where(static equipment => equipment.DefinitionUid.HasValue)
            .Select(static equipment => equipment.DefinitionUid!.Value))
        .Concat(source.Builds.SelectMany(static build => build.Equipment)
            .SelectMany(static equipment => equipment.OverloadLines)
            .Select(static line => line.OptionDefinitionUid))
        .Concat(source.Builds.Where(static build => build.Cube.DefinitionUid.HasValue)
            .Select(static build => build.Cube.DefinitionUid!.Value))
        .Concat(source.Builds.Where(static build => build.Collection.DefinitionUid.HasValue)
            .Select(static build => build.Collection.DefinitionUid!.Value))
        .ToHashSet();
    var required = new HashSet<EntityUid>();
    if (characterChanged)
    {
      required.UnionWith(characterReferences);
    }

    if (supportChanged)
    {
      required.UnionWith(supportReferences);
    }

    if (!required.SetEquals(explicitMappings.Keys) ||
        explicitMappings.Any(static item =>
            item.Key.Value == Guid.Empty || item.Value.Value == Guid.Empty) ||
        explicitMappings.Values.Distinct().Count() != explicitMappings.Count)
    {
      throw Failure("sanitized_draft_rebase_mapping_set_invalid");
    }

    EntityUid Map(EntityUid value, bool changed) =>
        changed ? explicitMappings[value] : value;

    var accountState = source.AccountState with
    {
      Consoles = Array.AsReadOnly(source.AccountState.Consoles.Select(console => console with
      {
        DefinitionUid = Map(console.DefinitionUid, supportChanged)
      }).ToArray())
    };
    var builds = source.Builds.Select(build => build with
    {
      CharacterUid = Map(build.CharacterUid, characterChanged),
      Equipment = Array.AsReadOnly(build.Equipment.Select(equipment => equipment with
      {
        DefinitionUid = equipment.DefinitionUid.HasValue
            ? Map(equipment.DefinitionUid.Value, supportChanged)
            : null,
        OverloadLines = Array.AsReadOnly(equipment.OverloadLines.Select(line => line with
        {
          OptionDefinitionUid = Map(line.OptionDefinitionUid, supportChanged)
        }).ToArray())
      }).ToArray()),
      Cube = build.Cube with
      {
        DefinitionUid = build.Cube.DefinitionUid.HasValue
            ? Map(build.Cube.DefinitionUid.Value, supportChanged)
            : null
      },
      Collection = build.Collection with
      {
        DefinitionUid = build.Collection.DefinitionUid.HasValue
            ? Map(build.Collection.DefinitionUid.Value, supportChanged)
            : null
      }
    }).OrderBy(static build => build.CharacterUid.ToString(), StringComparer.Ordinal).ToArray();
    var reviewedOverrides = source.ReviewedOverrides.Select(reviewedOverride => reviewedOverride with
    {
      CharacterUid = Map(reviewedOverride.CharacterUid, characterChanged)
    }).OrderBy(ReviewedOverrideSortKey, StringComparer.Ordinal).ToArray();
    return (
        accountState,
        Array.AsReadOnly(builds),
        Array.AsReadOnly(reviewedOverrides));
  }

  private static (
      IReadOnlyList<SanitizedCharacterBuildDraft> Builds,
      IReadOnlyList<SanitizedProfileReviewedOverride> ReviewedOverrides) ApplyOverrides(
      SanitizedProfileDraft source,
      IReadOnlyList<SanitizedProfileReviewedOverrideRequest> requests)
  {
    if (requests.Any(static request => request is null ||
            request.CharacterUid.Value == Guid.Empty || !Enum.IsDefined(request.Kind) ||
            !SanitizedProfileReviewedOverrideReasonCodes.IsAllowed(request.ReasonCode)) ||
        requests.Select(ReviewedOverrideTargetKey).Distinct(StringComparer.Ordinal).Count() !=
            requests.Count)
    {
      throw Failure("sanitized_draft_override_request_invalid");
    }

    var builds = CopyBuilds(source.Builds).ToDictionary(static build => build.CharacterUid);
    var reviewedOverrides = source.ReviewedOverrides.Select(static item => item with { }).ToList();
    var occupiedTargets = reviewedOverrides.Select(ReviewedOverrideTargetKey)
        .ToHashSet(StringComparer.Ordinal);
    foreach (var request in requests)
    {
      var targetKey = ReviewedOverrideTargetKey(request);
      if (!occupiedTargets.Add(targetKey) ||
          !builds.TryGetValue(request.CharacterUid, out var build))
      {
        throw Failure("sanitized_draft_override_target_invalid");
      }

      if (request.Kind == SanitizedProfileReviewedOverrideKind.BondLevel)
      {
        const string originalReason = "bond_level_zero_semantics_unresolved";
        if (request.EquipmentSlot.HasValue ||
            request.IntegerValue is not (>= 1 and <= MaximumScalar) ||
            request.BooleanValue.HasValue || request.ReasonCode == originalReason ||
            build.BondLevelObservation != 0 ||
            build.ResolvedBondLevel.Status != ProfileImportFactStatus.Unresolved ||
            build.ResolvedBondLevel.ReasonCode != originalReason)
        {
          throw Failure("sanitized_draft_override_target_invalid");
        }

        builds[build.CharacterUid] = build with
        {
          ResolvedBondLevel = ProfileImportFact<int>.Ready(request.IntegerValue.Value)
        };
        reviewedOverrides.Add(new SanitizedProfileReviewedOverride(
            request.Kind,
            request.CharacterUid,
            null,
            request.IntegerValue,
            null,
            originalReason,
            request.ReasonCode));
        continue;
      }

      const string manufacturerOriginalReason = "equipment_manufacturer_observation_missing";
      if (request.Kind != SanitizedProfileReviewedOverrideKind.EquipmentManufacturerMatched ||
          !request.EquipmentSlot.HasValue ||
          !Enum.IsDefined(request.EquipmentSlot.Value) || request.IntegerValue.HasValue ||
          !request.BooleanValue.HasValue || request.ReasonCode == manufacturerOriginalReason)
      {
        throw Failure("sanitized_draft_override_target_invalid");
      }

      var equipment = build.Equipment.Single(
          item => item.Slot == request.EquipmentSlot.Value);
      if (equipment.State != ProfileImportAttachmentState.Equipped ||
          equipment.ManufacturerMatchedObservation?.Status !=
              ProfileImportFactStatus.Unresolved ||
          equipment.ManufacturerMatchedObservation.ReasonCode != manufacturerOriginalReason ||
          equipment.ResolvedManufacturerMatched?.Status !=
              ProfileImportFactStatus.Unresolved ||
          equipment.ResolvedManufacturerMatched.ReasonCode != manufacturerOriginalReason)
      {
        throw Failure("sanitized_draft_override_target_invalid");
      }

      var equipmentCopy = build.Equipment.Select(item => item.Slot == request.EquipmentSlot.Value
          ? item with
          {
            ResolvedManufacturerMatched =
                ProfileImportFact<bool>.Ready(request.BooleanValue.Value)
          }
          : item).ToArray();
      builds[build.CharacterUid] = build with
      {
        Equipment = Array.AsReadOnly(equipmentCopy)
      };
      reviewedOverrides.Add(new SanitizedProfileReviewedOverride(
          request.Kind,
          request.CharacterUid,
          request.EquipmentSlot,
          null,
          request.BooleanValue,
          manufacturerOriginalReason,
          request.ReasonCode));
    }

    return (
        Array.AsReadOnly(builds.Values
            .OrderBy(static build => build.CharacterUid.ToString(), StringComparer.Ordinal)
            .ToArray()),
        Array.AsReadOnly(reviewedOverrides.OrderBy(ReviewedOverrideSortKey, StringComparer.Ordinal)
            .ToArray()));
  }

  private static SanitizedAccountCombatStateDraft CopyAccountState(
      SanitizedAccountCombatStateDraft accountState)
  {
    if (accountState.Consoles is null || accountState.Consoles.Any(static item => item is null))
    {
      throw Failure("sanitized_draft_factory_input_invalid");
    }

    return accountState with
    {
      Consoles = Array.AsReadOnly(
          accountState.Consoles.Select(static item => item with { }).ToArray())
    };
  }

  private static IReadOnlyList<SanitizedCharacterBuildDraft> CopyBuilds(
      IReadOnlyList<SanitizedCharacterBuildDraft> builds)
  {
    if (builds.Any(static build => build is null || build.Level is null ||
        build.ResolvedBondLevel is null || build.Equipment is null || build.Cube is null ||
        build.Collection is null || build.Equipment.Any(static equipment => equipment is null ||
            equipment.OverloadLines is null ||
            equipment.OverloadLines.Any(static line => line is null))))
    {
      throw Failure("sanitized_draft_factory_input_invalid");
    }

    var copies = builds.Select(static build => build with
    {
      Level = build.Level with { },
      Equipment = Array.AsReadOnly(build.Equipment.Select(static equipment => equipment with
      {
        OverloadLines = Array.AsReadOnly(
            equipment.OverloadLines.Select(static line => line with { }).ToArray())
      }).ToArray()),
      Cube = build.Cube with { },
      Collection = build.Collection with { }
    }).ToArray();
    return Array.AsReadOnly(copies);
  }

  private static IReadOnlyList<SanitizedProfileReviewedOverride> CopyReviewedOverrides(
      IReadOnlyList<SanitizedProfileReviewedOverride> reviewedOverrides)
  {
    if (reviewedOverrides.Any(static item => item is null))
    {
      throw Failure("sanitized_draft_factory_input_invalid");
    }

    return Array.AsReadOnly(reviewedOverrides.Select(static item => item with { }).ToArray());
  }

  private static SanitizedProfileTransformerProfile ValidateProvenance(
      SanitizedProfileImportProvenance provenance)
  {
    if (provenance.SchemaCode != SanitizedProfileDraftContract.SchemaCode ||
        provenance.TransformerBinarySha256 == default ||
        provenance.SemanticOptionsSha256 == default ||
        provenance.SanitizedPayloadSha256 == default ||
        provenance.ImportedAtUtc.Offset != TimeSpan.Zero ||
        provenance.ImportedAtUtc.Ticks % 10 != 0 ||
        provenance.CaptureTime is null ||
        provenance.CaptureTime.Status != ProfileImportFactStatus.Unresolved ||
        provenance.CaptureTime.ReasonCode != "capture_time_not_observed" ||
        provenance.CaptureAtomicity != ProfileCaptureAtomicity.Unresolved ||
        provenance.SourceHashPolicy != CredentialBearingSourceHashPolicy.Prohibited)
    {
      throw Failure("sanitized_draft_provenance_invalid");
    }

    if (MatchesTransformer(provenance, SanitizedProfileDraftContract.Transformer))
    {
      return SanitizedProfileTransformerProfile.OfflineRawSanitizer;
    }

    if (MatchesTransformer(provenance, SanitizedProfileDraftContract.RebaseTransformer))
    {
      return SanitizedProfileTransformerProfile.CatalogRebase;
    }

    if (MatchesTransformer(provenance, SanitizedProfileDraftContract.ReviewedOverrideTransformer))
    {
      return SanitizedProfileTransformerProfile.ReviewedOverride;
    }

    throw Failure("sanitized_draft_transformer_profile_invalid");
  }

  private static bool MatchesTransformer(
      SanitizedProfileImportProvenance provenance,
      ExtractorDescriptor descriptor) =>
      provenance.SourceSchemaSha256 == descriptor.ContractSha256 &&
      provenance.TransformerId == descriptor.ExtractorId &&
      provenance.TransformerVersion == descriptor.ExtractorVersion &&
      provenance.TransformerFingerprintSha256 == descriptor.FingerprintSha256;

  private static void ValidateBinding(ProfileImportCatalogBinding binding)
  {
    if (binding.CatalogSnapshotUid.Value == Guid.Empty ||
        binding.DatasetSnapshotUid.Value == Guid.Empty || binding.ManifestSha256 == default)
    {
      throw Failure("sanitized_draft_catalog_binding_invalid");
    }
  }

  private static void ValidateAccountState(SanitizedAccountCombatStateDraft accountState)
  {
    if (accountState.SynchroLevel is <= 0 or > MaximumScalar ||
        accountState.OccupiedSynchroSlotCountObservation is < 0 or > MaximumScalar ||
        accountState.Consoles is null || accountState.Consoles.Count != 9 ||
        accountState.Consoles.Any(static console => console is null) ||
        !accountState.Consoles.Select(static console => console.Coordinate)
            .SequenceEqual(Enum.GetValues<ProfileImportConsoleCoordinate>()))
    {
      throw Failure("sanitized_draft_account_state_invalid");
    }

    foreach (var console in accountState.Consoles)
    {
      if (console.DefinitionUid.Value == Guid.Empty ||
          console.Level is < 0 or > MaximumScalar || console.ObservedExperience < 0)
      {
        throw Failure("sanitized_draft_console_invalid");
      }
    }
  }

  private static CharacterLevelAuthorityPolicy? ValidateBuild(
      SanitizedCharacterBuildDraft build)
  {
    if (build.CharacterUid.Value == Guid.Empty || build.Level is null ||
        build.Level.RosterLevel is <= 0 or > MaximumScalar ||
        build.Level.DetailLevel is <= 0 or > MaximumScalar ||
        build.LimitBreak is < 0 or > MaximumScalar ||
        build.CoreLevel is < 0 or > MaximumScalar ||
        build.BondLevelObservation is < 0 or > MaximumScalar ||
        build.Skill1Level is <= 0 or > MaximumScalar ||
        build.Skill2Level is <= 0 or > MaximumScalar ||
        build.BurstLevel is <= 0 or > MaximumScalar ||
        build.RosterCombatPowerObservation < 0 || build.DetailCombatPowerObservation < 0 ||
        build.Equipment is null || build.Equipment.Count != 4 ||
        build.Equipment.Any(static equipment => equipment is null) ||
        !build.Equipment.Select(static equipment => equipment.Slot)
            .SequenceEqual(Enum.GetValues<ProfileImportEquipmentSlot>()) ||
        build.Cube is null || build.Collection is null)
    {
      throw Failure("sanitized_draft_build_invalid");
    }

    ValidateBond(build);
    foreach (var equipment in build.Equipment)
    {
      ValidateEquipment(equipment);
    }

    ValidateCube(build.Cube);
    ValidateCollection(build.Collection);
    return ValidateLevelAuthority(build.Level);
  }

  private static void ValidateBond(SanitizedCharacterBuildDraft build)
  {
    if (build.ResolvedBondLevel is null)
    {
      throw Failure("sanitized_draft_bond_invalid");
    }

    var valid = build.BondLevelObservation == 0
        ? (build.ResolvedBondLevel.Status == ProfileImportFactStatus.Unresolved &&
           build.ResolvedBondLevel.ReasonCode == "bond_level_zero_semantics_unresolved") ||
          build.ResolvedBondLevel.Status == ProfileImportFactStatus.NotApplicable ||
          (build.ResolvedBondLevel.Status == ProfileImportFactStatus.Ready &&
           build.ResolvedBondLevel.Value is >= 1 and <= MaximumScalar)
        : build.ResolvedBondLevel.Status == ProfileImportFactStatus.Ready &&
          build.ResolvedBondLevel.Value == build.BondLevelObservation;
    if (!valid)
    {
      throw Failure("sanitized_draft_bond_invalid");
    }
  }

  private static CharacterLevelAuthorityPolicy? ValidateLevelAuthority(
      SanitizedCharacterLevelObservation level)
  {
    if (level.ResolvedBattleLevel is null)
    {
      throw Failure("sanitized_draft_level_authority_invalid");
    }

    if (level.ResolvedBattleLevel.Status == ProfileImportFactStatus.Unresolved)
    {
      if (level.ResolvedBattleLevel.ReasonCode != "level_authority_not_selected" ||
          level.AuthorityPolicyCode is not null)
      {
        throw Failure("sanitized_draft_level_authority_invalid");
      }

      return null;
    }

    var authority = level.AuthorityPolicyCode switch
    {
      CharacterLevelAuthorityPolicyCodes.RosterObservationV1 =>
          CharacterLevelAuthorityPolicy.RosterObservationV1,
      CharacterLevelAuthorityPolicyCodes.DetailObservationV1 =>
          CharacterLevelAuthorityPolicy.DetailObservationV1,
      _ => throw Failure("sanitized_draft_level_authority_invalid")
    };
    var expected = authority == CharacterLevelAuthorityPolicy.RosterObservationV1
        ? level.RosterLevel
        : level.DetailLevel;
    if (level.ResolvedBattleLevel.Value != expected)
    {
      throw Failure("sanitized_draft_level_authority_invalid");
    }

    return authority;
  }

  private static void ValidateEquipment(SanitizedEquipmentSelection equipment)
  {
    if (!Enum.IsDefined(equipment.Slot) || !Enum.IsDefined(equipment.State) ||
        equipment.OverloadLines is null || equipment.OverloadLines.Count > 3 ||
        equipment.OverloadLines.Any(static line => line is null) ||
        !equipment.OverloadLines.Select(static line => line.LineIndex).SequenceEqual(
            equipment.OverloadLines.Select(static line => line.LineIndex).Order()))
    {
      throw Failure("sanitized_draft_equipment_invalid");
    }

    if (equipment.State == ProfileImportAttachmentState.Unequipped)
    {
      if (equipment.DefinitionUid.HasValue || equipment.EnhancementLevel.HasValue ||
          equipment.ManufacturerMatchedObservation is not null ||
          equipment.ResolvedManufacturerMatched is not null || equipment.OverloadLines.Count != 0)
      {
        throw Failure("sanitized_draft_equipment_invalid");
      }

      return;
    }

    if (!equipment.DefinitionUid.HasValue ||
        equipment.DefinitionUid.Value.Value == Guid.Empty ||
        !equipment.EnhancementLevel.HasValue ||
        equipment.EnhancementLevel is < 0 or > 5 ||
        equipment.ManufacturerMatchedObservation is null ||
        equipment.ResolvedManufacturerMatched is null)
    {
      throw Failure("sanitized_draft_equipment_invalid");
    }

    ValidateManufacturerFact(equipment.ManufacturerMatchedObservation);
    ValidateManufacturerFact(equipment.ResolvedManufacturerMatched);
    var indexes = new HashSet<int>();
    foreach (var line in equipment.OverloadLines)
    {
      if (line.LineIndex is < 1 or > 3 || !indexes.Add(line.LineIndex) ||
          line.OptionDefinitionUid.Value == Guid.Empty || line.Unit != ProfileImportValueUnit.Ratio ||
          line.ExactValue.UnscaledValue == 0 ||
          line.ExactValue.UnscaledValue < -int.MaxValue ||
          line.ExactValue.UnscaledValue > int.MaxValue ||
          line.ExactValue.DecimalScale != 4)
      {
        throw Failure("sanitized_draft_overload_invalid");
      }
    }
  }

  private static void ValidateManufacturerFact(ProfileImportFact<bool> fact)
  {
    if (fact.Status == ProfileImportFactStatus.NotApplicable)
    {
      return;
    }

    if (fact.Status == ProfileImportFactStatus.Unresolved &&
        fact.ReasonCode == "equipment_manufacturer_observation_missing")
    {
      return;
    }

    if (fact.Status != ProfileImportFactStatus.Ready || !fact.Value.HasValue)
    {
      throw Failure("sanitized_draft_manufacturer_fact_invalid");
    }
  }

  private static void ValidateReviewedOverrides(
      IReadOnlyList<SanitizedCharacterBuildDraft> builds,
      IReadOnlyList<SanitizedProfileReviewedOverride> reviewedOverrides)
  {
    if (reviewedOverrides.Count > builds.Count * 5 ||
        reviewedOverrides.Any(static item => item is null) ||
        !reviewedOverrides.Select(ReviewedOverrideSortKey).SequenceEqual(
            reviewedOverrides.Select(ReviewedOverrideSortKey)
                .OrderBy(static value => value, StringComparer.Ordinal)) ||
        reviewedOverrides.Select(ReviewedOverrideTargetKey).Distinct(StringComparer.Ordinal).Count() !=
            reviewedOverrides.Count)
    {
      throw Failure("sanitized_draft_reviewed_override_set_invalid");
    }

    var byCharacter = builds.ToDictionary(static build => build.CharacterUid);
    var overridesByTarget = reviewedOverrides.ToDictionary(
        ReviewedOverrideTargetKey,
        StringComparer.Ordinal);
    foreach (var reviewedOverride in reviewedOverrides)
    {
      if (reviewedOverride.CharacterUid.Value == Guid.Empty ||
          !SanitizedProfileReviewedOverrideReasonCodes.IsAllowed(reviewedOverride.ReasonCode) ||
          reviewedOverride.ReasonCode == reviewedOverride.OriginalReasonCode ||
          !byCharacter.TryGetValue(reviewedOverride.CharacterUid, out var build))
      {
        throw Failure("sanitized_draft_reviewed_override_invalid");
      }

      if (reviewedOverride.Kind == SanitizedProfileReviewedOverrideKind.BondLevel)
      {
        if (reviewedOverride.EquipmentSlot.HasValue ||
            reviewedOverride.IntegerValue is not (>= 1 and <= MaximumScalar) ||
            reviewedOverride.BooleanValue.HasValue ||
            reviewedOverride.OriginalReasonCode != "bond_level_zero_semantics_unresolved" ||
            build.BondLevelObservation != 0 ||
            build.ResolvedBondLevel.Status != ProfileImportFactStatus.Ready ||
            build.ResolvedBondLevel.Value != reviewedOverride.IntegerValue)
        {
          throw Failure("sanitized_draft_reviewed_override_invalid");
        }

        continue;
      }

      if (reviewedOverride.Kind !=
              SanitizedProfileReviewedOverrideKind.EquipmentManufacturerMatched ||
          !reviewedOverride.EquipmentSlot.HasValue ||
          !Enum.IsDefined(reviewedOverride.EquipmentSlot.Value) ||
          reviewedOverride.IntegerValue.HasValue || !reviewedOverride.BooleanValue.HasValue ||
          reviewedOverride.OriginalReasonCode != "equipment_manufacturer_observation_missing")
      {
        throw Failure("sanitized_draft_reviewed_override_invalid");
      }

      var equipment = build.Equipment.Single(
          item => item.Slot == reviewedOverride.EquipmentSlot.Value);
      if (equipment.State != ProfileImportAttachmentState.Equipped ||
          equipment.ManufacturerMatchedObservation?.Status !=
              ProfileImportFactStatus.Unresolved ||
          equipment.ManufacturerMatchedObservation.ReasonCode !=
              reviewedOverride.OriginalReasonCode ||
          equipment.ResolvedManufacturerMatched?.Status != ProfileImportFactStatus.Ready ||
          equipment.ResolvedManufacturerMatched.Value != reviewedOverride.BooleanValue)
      {
        throw Failure("sanitized_draft_reviewed_override_invalid");
      }
    }

    foreach (var build in builds)
    {
      var bondKey = ReviewedOverrideTargetKey(
          SanitizedProfileReviewedOverrideKind.BondLevel,
          build.CharacterUid,
          null);
      var hasBondOverride = overridesByTarget.ContainsKey(bondKey);
      if ((build.BondLevelObservation == 0 &&
           build.ResolvedBondLevel.Status == ProfileImportFactStatus.Ready) != hasBondOverride)
      {
        throw Failure("sanitized_draft_reviewed_override_missing");
      }

      foreach (var equipment in build.Equipment.Where(
          static item => item.State == ProfileImportAttachmentState.Equipped))
      {
        var observation = equipment.ManufacturerMatchedObservation!;
        var resolved = equipment.ResolvedManufacturerMatched!;
        var key = ReviewedOverrideTargetKey(
            SanitizedProfileReviewedOverrideKind.EquipmentManufacturerMatched,
            build.CharacterUid,
            equipment.Slot);
        var hasOverride = overridesByTarget.ContainsKey(key);
        if (observation.Status == ProfileImportFactStatus.Ready)
        {
          if (resolved.Status != ProfileImportFactStatus.Ready ||
              resolved.Value != observation.Value || hasOverride)
          {
            throw Failure("sanitized_draft_manufacturer_fact_invalid");
          }
        }
        else if ((resolved.Status == ProfileImportFactStatus.Ready) != hasOverride ||
            (resolved.Status == ProfileImportFactStatus.Unresolved &&
             resolved.ReasonCode != observation.ReasonCode))
        {
          throw Failure("sanitized_draft_reviewed_override_missing");
        }
      }
    }
  }

  private static string ReviewedOverrideSortKey(SanitizedProfileReviewedOverride value) =>
      string.Join(
          '|',
          value.CharacterUid.ToString(),
          ReviewedOverrideKindCode(value.Kind),
          value.EquipmentSlot.HasValue ? EquipmentSlotCode(value.EquipmentSlot.Value) : string.Empty);

  private static string ReviewedOverrideTargetKey(SanitizedProfileReviewedOverride value) =>
      ReviewedOverrideTargetKey(value.Kind, value.CharacterUid, value.EquipmentSlot);

  private static string ReviewedOverrideTargetKey(
      SanitizedProfileReviewedOverrideRequest value) =>
      ReviewedOverrideTargetKey(value.Kind, value.CharacterUid, value.EquipmentSlot);

  private static string ReviewedOverrideTargetKey(
      SanitizedProfileReviewedOverrideKind kind,
      EntityUid characterUid,
      ProfileImportEquipmentSlot? slot) => string.Join(
          '|',
          characterUid.ToString(),
          ReviewedOverrideKindCode(kind),
          slot.HasValue ? EquipmentSlotCode(slot.Value) : string.Empty);

  private static void ValidateCube(SanitizedCubeSelection cube)
  {
    var valid = cube.State switch
    {
      ProfileImportAttachmentState.Unequipped =>
          !cube.DefinitionUid.HasValue && !cube.Level.HasValue,
      ProfileImportAttachmentState.Equipped =>
          cube.DefinitionUid.HasValue && cube.DefinitionUid.Value.Value != Guid.Empty &&
          cube.Level is >= 1 and <= MaximumScalar,
      _ => false
    };
    if (!valid)
    {
      throw Failure("sanitized_draft_cube_invalid");
    }
  }

  private static void ValidateCollection(SanitizedCollectionSelection collection)
  {
    var valid = collection.Kind switch
    {
      ProfileImportCollectionKind.Detached =>
          !collection.DefinitionUid.HasValue && !collection.Level.HasValue,
      ProfileImportCollectionKind.GenericCollection or ProfileImportCollectionKind.Favorite =>
          collection.DefinitionUid.HasValue && collection.DefinitionUid.Value.Value != Guid.Empty &&
          collection.Level is >= 0 and <= MaximumScalar,
      _ => false
    };
    if (!valid)
    {
      throw Failure("sanitized_draft_collection_invalid");
    }
  }

  private static void RequireObject(JsonElement value, string code, params string[] propertyNames)
  {
    RequireKind(value, JsonValueKind.Object, code);
    var actual = new HashSet<string>(StringComparer.Ordinal);
    foreach (var property in value.EnumerateObject())
    {
      if (!actual.Add(property.Name))
      {
        throw Failure(code);
      }
    }

    if (actual.Count != propertyNames.Length ||
        propertyNames.Any(name => !actual.Contains(name)))
    {
      throw Failure(code);
    }
  }

  private static void RequireKind(JsonElement value, JsonValueKind kind, string code)
  {
    if (value.ValueKind != kind)
    {
      throw Failure(code);
    }
  }

  private static string ReadString(JsonElement value, string propertyName)
  {
    var property = value.GetProperty(propertyName);
    RequireKind(property, JsonValueKind.String, "sanitized_draft_json_value_invalid");
    return property.GetString()!;
  }

  private static string? ReadNullableString(JsonElement value, string propertyName)
  {
    var property = value.GetProperty(propertyName);
    if (property.ValueKind == JsonValueKind.Null)
    {
      return null;
    }

    RequireKind(property, JsonValueKind.String, "sanitized_draft_json_value_invalid");
    return property.GetString();
  }

  private static string ReadControlledCode(JsonElement value, string propertyName)
  {
    var code = ReadString(value, propertyName);
    try
    {
      return ControlledCode.Require(code, propertyName);
    }
    catch (ArgumentException)
    {
      throw Failure("sanitized_draft_controlled_code_invalid");
    }
  }

  private static int ReadInt32(JsonElement value, string propertyName)
  {
    var property = value.GetProperty(propertyName);
    if (property.ValueKind != JsonValueKind.Number || !property.TryGetInt32(out var result))
    {
      throw Failure("sanitized_draft_json_value_invalid");
    }

    return result;
  }

  private static int? ReadNullableInt32(JsonElement value, string propertyName)
  {
    var property = value.GetProperty(propertyName);
    if (property.ValueKind == JsonValueKind.Null)
    {
      return null;
    }

    if (property.ValueKind != JsonValueKind.Number || !property.TryGetInt32(out var result))
    {
      throw Failure("sanitized_draft_json_value_invalid");
    }

    return result;
  }

  private static long ReadInt64(JsonElement value, string propertyName)
  {
    var property = value.GetProperty(propertyName);
    if (property.ValueKind != JsonValueKind.Number || !property.TryGetInt64(out var result))
    {
      throw Failure("sanitized_draft_json_value_invalid");
    }

    return result;
  }

  private static bool ReadBoolean(JsonElement value, string propertyName)
  {
    var property = value.GetProperty(propertyName);
    if (property.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
    {
      throw Failure("sanitized_draft_json_value_invalid");
    }

    return property.GetBoolean();
  }

  private static bool? ReadNullableBoolean(JsonElement value, string propertyName)
  {
    var property = value.GetProperty(propertyName);
    if (property.ValueKind == JsonValueKind.Null)
    {
      return null;
    }

    if (property.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
    {
      throw Failure("sanitized_draft_json_value_invalid");
    }

    return property.GetBoolean();
  }

  private static EntityUid ReadUid(JsonElement value, string propertyName) =>
      ParseUid(ReadString(value, propertyName));

  private static EntityUid? ReadNullableUid(JsonElement value, string propertyName)
  {
    var property = value.GetProperty(propertyName);
    return property.ValueKind == JsonValueKind.Null ? null : ParseUid(ReadString(value, propertyName));
  }

  private static EntityUid ParseUid(string text)
  {
    if (!Guid.TryParseExact(text, "D", out var value) || value == Guid.Empty)
    {
      throw Failure("sanitized_draft_uid_invalid");
    }

    return new EntityUid(value);
  }

  private static Sha256Digest ReadDigest(JsonElement value, string propertyName)
  {
    if (!Sha256Digest.TryParse(ReadString(value, propertyName), out var result))
    {
      throw Failure("sanitized_draft_digest_invalid");
    }

    return result;
  }

  private static DateTimeOffset ReadTimestamp(JsonElement value, string propertyName)
  {
    if (!DateTimeOffset.TryParseExact(
            ReadString(value, propertyName),
            TimestampFormat,
            CultureInfo.InvariantCulture,
            DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
            out var result) || result.Offset != TimeSpan.Zero || result.Ticks % 10 != 0)
    {
      throw Failure("sanitized_draft_timestamp_invalid");
    }

    return result;
  }

  private static ProfileImportFactStatus ParseFactStatus(string code) => code switch
  {
    "ready" => ProfileImportFactStatus.Ready,
    "unresolved" => ProfileImportFactStatus.Unresolved,
    "not_applicable" => ProfileImportFactStatus.NotApplicable,
    _ => throw Failure("sanitized_draft_fact_status_invalid")
  };

  private static ProfileImportEquipmentSlot ParseEquipmentSlot(string code) => code switch
  {
    "head" => ProfileImportEquipmentSlot.Head,
    "torso" => ProfileImportEquipmentSlot.Torso,
    "arms" => ProfileImportEquipmentSlot.Arms,
    "legs" => ProfileImportEquipmentSlot.Legs,
    _ => throw Failure("sanitized_draft_equipment_slot_invalid")
  };

  private static ProfileImportAttachmentState ParseAttachmentState(string code) => code switch
  {
    "equipped" => ProfileImportAttachmentState.Equipped,
    "unequipped" => ProfileImportAttachmentState.Unequipped,
    _ => throw Failure("sanitized_draft_attachment_state_invalid")
  };

  private static ProfileImportCollectionKind ParseCollectionKind(string code) => code switch
  {
    "detached" => ProfileImportCollectionKind.Detached,
    "generic_collection" => ProfileImportCollectionKind.GenericCollection,
    "favorite" => ProfileImportCollectionKind.Favorite,
    _ => throw Failure("sanitized_draft_collection_kind_invalid")
  };

  private static SanitizedProfileReviewedOverrideKind ParseReviewedOverrideKind(
      string code) => code switch
      {
        "bond_level" => SanitizedProfileReviewedOverrideKind.BondLevel,
        "equipment_manufacturer_matched" =>
            SanitizedProfileReviewedOverrideKind.EquipmentManufacturerMatched,
        _ => throw Failure("sanitized_draft_reviewed_override_kind_invalid")
      };

  private static ProfileImportConsoleCoordinate ParseConsoleCoordinate(string code) => code switch
  {
    "common" => ProfileImportConsoleCoordinate.Common,
    "attacker" => ProfileImportConsoleCoordinate.Attacker,
    "defender" => ProfileImportConsoleCoordinate.Defender,
    "supporter" => ProfileImportConsoleCoordinate.Supporter,
    "elysion" => ProfileImportConsoleCoordinate.Elysion,
    "missilis" => ProfileImportConsoleCoordinate.Missilis,
    "tetra" => ProfileImportConsoleCoordinate.Tetra,
    "pilgrim" => ProfileImportConsoleCoordinate.Pilgrim,
    "abnormal" => ProfileImportConsoleCoordinate.Abnormal,
    _ => throw Failure("sanitized_draft_console_coordinate_invalid")
  };

  private static ProfileImportValueUnit ParseValueUnit(string code) => code switch
  {
    "absolute" => ProfileImportValueUnit.Absolute,
    "ratio" => ProfileImportValueUnit.Ratio,
    "percent" => ProfileImportValueUnit.Percent,
    "count" => ProfileImportValueUnit.Count,
    _ => throw Failure("sanitized_draft_value_unit_invalid")
  };

  private static ProfileCaptureAtomicity ParseCaptureAtomicity(string code) => code switch
  {
    "unresolved" => ProfileCaptureAtomicity.Unresolved,
    _ => throw Failure("sanitized_draft_capture_atomicity_invalid")
  };

  private static CredentialBearingSourceHashPolicy ParseSourceHashPolicy(string code) => code switch
  {
    "prohibited" => CredentialBearingSourceHashPolicy.Prohibited,
    _ => throw Failure("sanitized_draft_source_hash_policy_invalid")
  };

  private static string FactStatusCode(ProfileImportFactStatus value) => value switch
  {
    ProfileImportFactStatus.Ready => "ready",
    ProfileImportFactStatus.Unresolved => "unresolved",
    ProfileImportFactStatus.NotApplicable => "not_applicable",
    _ => throw Failure("sanitized_draft_fact_status_invalid")
  };

  private static string EquipmentSlotCode(ProfileImportEquipmentSlot value) => value switch
  {
    ProfileImportEquipmentSlot.Head => "head",
    ProfileImportEquipmentSlot.Torso => "torso",
    ProfileImportEquipmentSlot.Arms => "arms",
    ProfileImportEquipmentSlot.Legs => "legs",
    _ => throw Failure("sanitized_draft_equipment_slot_invalid")
  };

  private static string AttachmentStateCode(ProfileImportAttachmentState value) => value switch
  {
    ProfileImportAttachmentState.Equipped => "equipped",
    ProfileImportAttachmentState.Unequipped => "unequipped",
    _ => throw Failure("sanitized_draft_attachment_state_invalid")
  };

  private static string CollectionKindCode(ProfileImportCollectionKind value) => value switch
  {
    ProfileImportCollectionKind.Detached => "detached",
    ProfileImportCollectionKind.GenericCollection => "generic_collection",
    ProfileImportCollectionKind.Favorite => "favorite",
    _ => throw Failure("sanitized_draft_collection_kind_invalid")
  };

  private static string ReviewedOverrideKindCode(
      SanitizedProfileReviewedOverrideKind value) => value switch
      {
        SanitizedProfileReviewedOverrideKind.BondLevel => "bond_level",
        SanitizedProfileReviewedOverrideKind.EquipmentManufacturerMatched =>
            "equipment_manufacturer_matched",
        _ => throw Failure("sanitized_draft_reviewed_override_kind_invalid")
      };

  private static string ConsoleCode(ProfileImportConsoleCoordinate value) => value switch
  {
    ProfileImportConsoleCoordinate.Common => "common",
    ProfileImportConsoleCoordinate.Attacker => "attacker",
    ProfileImportConsoleCoordinate.Defender => "defender",
    ProfileImportConsoleCoordinate.Supporter => "supporter",
    ProfileImportConsoleCoordinate.Elysion => "elysion",
    ProfileImportConsoleCoordinate.Missilis => "missilis",
    ProfileImportConsoleCoordinate.Tetra => "tetra",
    ProfileImportConsoleCoordinate.Pilgrim => "pilgrim",
    ProfileImportConsoleCoordinate.Abnormal => "abnormal",
    _ => throw Failure("sanitized_draft_console_coordinate_invalid")
  };

  private static string ValueUnitCode(ProfileImportValueUnit value) => value switch
  {
    ProfileImportValueUnit.Absolute => "absolute",
    ProfileImportValueUnit.Ratio => "ratio",
    ProfileImportValueUnit.Percent => "percent",
    ProfileImportValueUnit.Count => "count",
    _ => throw Failure("sanitized_draft_value_unit_invalid")
  };

  private static string CaptureAtomicityCode(ProfileCaptureAtomicity value) => value switch
  {
    ProfileCaptureAtomicity.Unresolved => "unresolved",
    _ => throw Failure("sanitized_draft_capture_atomicity_invalid")
  };

  private static string SourceHashPolicyCode(CredentialBearingSourceHashPolicy value) => value switch
  {
    CredentialBearingSourceHashPolicy.Prohibited => "prohibited",
    _ => throw Failure("sanitized_draft_source_hash_policy_invalid")
  };

  private static SanitizedProfileDraftCodecException Failure(string code) => new(code);
}
