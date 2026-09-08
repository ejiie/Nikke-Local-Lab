using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Import.Profile;

public static class FetchedAccountSnapshotContract
{
  public const int SchemaVersion = 1;
  public const string ContractId = "nll/fetched-account-snapshot/v1";
  public const string WorkerCode = "credential-bearing-profile-sanitizer";
  public const string WorkerVersion = "v1";
}

public sealed record FetchedBasicAccountObservation(
    string? DisplayName,
    int? CommanderLevel,
    string? NormalStageLabel,
    string? HardStageLabel,
    string? StoryStageLabel);

public sealed record FetchedProgressionObservation(
    Sha256Digest? MainQuestDataSha256,
    int? MainQuestCompletedCount,
    int? CompletedScenarioCount,
    int? ContentsOpenUnlockedCount,
    EntityUid? BoundSnapshotUid = null,
    Sha256Digest? DetailedObservationSha256 = null,
    string? DetailedStatusCode = null,
    IReadOnlyList<string>? DetailedReasonCodes = null,
    int? StageClearHistoryCount = null,
    int? TriggerCount = null,
    DateTimeOffset? BoundCapturedAtUtc = null);

public sealed record FetchedSnapshotSource(
    string WorkerCode,
    string WorkerVersion,
    int ArtifactByteLength,
    Sha256Digest ArtifactSha256,
    bool CredentialOrSessionPersisted,
    bool RawSourcePersisted);

public sealed record FetchedSnapshotCompleteness(
    string StatusCode,
    int RosterCount,
    int CharacterDetailCount,
    int EquipmentCharacterCount,
    int MissingCharacterCount,
    IReadOnlyList<string> ReasonCodes);

public sealed record FetchedConsoleState(
    string CoordinateCode,
    int Level,
    long Experience);

public sealed record FetchedAccountState(
    string? DisplayName,
    int? CommanderLevel,
    int SynchroLevel,
    IReadOnlyList<FetchedConsoleState> Consoles);

public sealed record FetchedProgressionState(
    string? NormalStageLabel,
    string? HardStageLabel,
    string? StoryStageLabel,
    Sha256Digest? MainQuestDataSha256,
    int? MainQuestCompletedCount,
    int? CompletedScenarioCount,
    int? ContentsOpenUnlockedCount);

public sealed record FetchedCharacterSkills(int Skill1, int Skill2, int Burst);

public sealed record FetchedOverloadLine(
    int LineIndex,
    EntityUid OptionDefinitionVersionUid,
    long UnscaledValue,
    int DecimalScale);

public sealed record FetchedEquipmentState(
    string SlotCode,
    string StateCode,
    EntityUid? DefinitionVersionUid,
    int? EnhancementLevel,
    bool? ManufacturerMatched,
    IReadOnlyList<FetchedOverloadLine> OverloadLines);

public sealed record FetchedCubeState(
    string StateCode,
    EntityUid? DefinitionVersionUid,
    int? Level);

public sealed record FetchedCollectibleState(
    string KindCode,
    EntityUid? DefinitionVersionUid,
    int? Level);

public sealed record FetchedCharacterState(
    EntityUid CharacterUid,
    int? CharacterLevel,
    string? CharacterLevelReasonCode,
    int LimitBreak,
    int CoreLevel,
    int? BondLevel,
    string? BondLevelReasonCode,
    FetchedCharacterSkills Skills,
    IReadOnlyList<FetchedEquipmentState> Equipment,
    FetchedCubeState Cube,
    FetchedCollectibleState Collectible);

public sealed record FetchedAccountSnapshot(
    int SchemaVersion,
    string ContractId,
    EntityUid SnapshotUid,
    DateTimeOffset CapturedAtUtc,
    FetchedSnapshotSource Source,
    FetchedSnapshotCompleteness Completeness,
    FetchedAccountState Account,
    FetchedProgressionState Progression,
    IReadOnlyList<FetchedCharacterState> Characters);

public sealed record FetchedAccountSnapshotMaterializationCommand(
    EntityUid SnapshotUid,
    DateTimeOffset CapturedAtUtc,
    SanitizedProfileDraft SanitizedProfile,
    CredentialBearingProfileCoverage Coverage,
    FetchedBasicAccountObservation BasicAccount,
    FetchedProgressionObservation Progression,
    IReadOnlyList<ProfileImportDiagnostic> SanitizerDiagnostics);

public static class FetchedAccountSnapshotMaterializer
{
  public static FetchedAccountSnapshot Materialize(
      FetchedAccountSnapshotMaterializationCommand command)
  {
    ArgumentNullException.ThrowIfNull(command);
    if (command.CapturedAtUtc.Offset != TimeSpan.Zero || command.CapturedAtUtc.Ticks % 10 != 0)
    {
      throw new ArgumentException(
          "The snapshot capture timestamp must be a PostgreSQL-safe UTC value.",
          nameof(command));
    }

    var draft = command.SanitizedProfile ?? throw new ArgumentNullException(nameof(command));
    if (command.Progression.BoundSnapshotUid is not null &&
        command.Progression.BoundSnapshotUid != command.SnapshotUid)
      throw new ArgumentException("The progression observation is bound to another snapshot.", nameof(command));
    if (command.Progression.BoundCapturedAtUtc is not null &&
        command.Progression.BoundCapturedAtUtc != command.CapturedAtUtc)
      throw new ArgumentException("The progression observation was captured at another time.", nameof(command));
    var canonicalDraft = SanitizedProfileDraftJsonCodec.Encode(draft);
    var canonicalDraftSha256 = Sha256Digest.Compute(canonicalDraft);

    var reasons = new SortedSet<string>(StringComparer.Ordinal);
    var builds = draft.Builds.OrderBy(static item => item.CharacterUid.ToString(), StringComparer.Ordinal)
        .ToArray();
    var duplicateCharacterCount = builds.Length - builds.Select(static item => item.CharacterUid).Distinct().Count();
    if (command.Coverage.RosterObservationCount <= 0) reasons.Add("roster_empty");
    if (command.Coverage.RosterObservationCount != command.Coverage.DetailObservationCount)
      reasons.Add("roster_detail_count_mismatch");
    if (command.Coverage.RosterObservationCount != builds.Length)
      reasons.Add("materialized_build_count_mismatch");
    if (command.Coverage.EquipmentCoordinateCount != checked(builds.Length * 4))
      reasons.Add("equipment_coordinate_count_mismatch");
    if (draft.AccountState.Consoles.Count != 9) reasons.Add("console_count_invalid");
    if (duplicateCharacterCount != 0) reasons.Add("duplicate_character");
    if (string.IsNullOrWhiteSpace(command.BasicAccount.DisplayName)) reasons.Add("display_name_missing");
    if (command.BasicAccount.CommanderLevel is null or < 1) reasons.Add("commander_level_missing");
    if (command.Progression.MainQuestDataSha256 is null ||
        command.Progression.MainQuestCompletedCount is null ||
        command.Progression.CompletedScenarioCount is null ||
        command.Progression.ContentsOpenUnlockedCount is null)
      reasons.Add("progression_summary_missing");
    if (command.Progression.DetailedReasonCodes is not null)
    {
      foreach (var reason in command.Progression.DetailedReasonCodes)
      {
        if (!string.IsNullOrWhiteSpace(reason)) reasons.Add(reason);
      }
    }
    if (!draft.IsLocalAccountProfileWriteReady) reasons.Add("profile_import_not_write_ready");
    if (command.SanitizerDiagnostics.Any(static item =>
        item.Severity == ProfileImportDiagnosticSeverity.Error))
      reasons.Add("profile_import_error");
    if (command.SanitizerDiagnostics.Any(static item =>
        item.Scope == ProfileImportDiagnosticScope.Catalog))
      reasons.Add("catalog_resolution_issue");

    var equipmentCharacterCount = builds.Count(static item => item.Equipment.Count == 4);
    var missingCharacterCount = Math.Max(
        command.Coverage.RosterObservationCount - command.Coverage.DetailObservationCount,
        0);
    var status = reasons.Contains("profile_import_error") ? "failed" :
        reasons.Count == 0 ? "complete" : "incomplete";

    return new FetchedAccountSnapshot(
        FetchedAccountSnapshotContract.SchemaVersion,
        FetchedAccountSnapshotContract.ContractId,
        command.SnapshotUid,
        command.CapturedAtUtc,
        new FetchedSnapshotSource(
            FetchedAccountSnapshotContract.WorkerCode,
            FetchedAccountSnapshotContract.WorkerVersion,
            canonicalDraft.Length,
            canonicalDraftSha256,
            CredentialOrSessionPersisted: false,
            RawSourcePersisted: false),
        new FetchedSnapshotCompleteness(
            status,
            command.Coverage.RosterObservationCount,
            command.Coverage.DetailObservationCount,
            equipmentCharacterCount,
            missingCharacterCount,
            reasons.ToArray()),
        new FetchedAccountState(
            NormalizeOptionalText(command.BasicAccount.DisplayName),
            command.BasicAccount.CommanderLevel,
            draft.AccountState.SynchroLevel,
            draft.AccountState.Consoles
                .OrderBy(static item => ConsoleCode(item.Coordinate), StringComparer.Ordinal)
                .Select(static item => new FetchedConsoleState(
                    ConsoleCode(item.Coordinate),
                    item.Level,
                    item.ObservedExperience))
                .ToArray()),
        new FetchedProgressionState(
            NormalizeOptionalText(command.BasicAccount.NormalStageLabel),
            NormalizeOptionalText(command.BasicAccount.HardStageLabel),
            NormalizeOptionalText(command.BasicAccount.StoryStageLabel),
            command.Progression.MainQuestDataSha256,
            command.Progression.MainQuestCompletedCount,
            command.Progression.CompletedScenarioCount,
            command.Progression.ContentsOpenUnlockedCount),
        builds.Select(MapCharacter).ToArray());
  }

  private static FetchedCharacterState MapCharacter(SanitizedCharacterBuildDraft build) => new(
      build.CharacterUid,
      build.Level.ResolvedBattleLevel.Value,
      build.Level.ResolvedBattleLevel.ReasonCode,
      build.LimitBreak,
      build.CoreLevel,
      build.ResolvedBondLevel.Value,
      build.ResolvedBondLevel.ReasonCode,
      new FetchedCharacterSkills(build.Skill1Level, build.Skill2Level, build.BurstLevel),
      build.Equipment.OrderBy(static item => SlotOrder(item.Slot)).Select(MapEquipment).ToArray(),
      new FetchedCubeState(
          AttachmentCode(build.Cube.State),
          build.Cube.DefinitionUid,
          build.Cube.Level),
      new FetchedCollectibleState(
          CollectionCode(build.Collection.Kind),
          build.Collection.DefinitionUid,
          build.Collection.Level));

  private static FetchedEquipmentState MapEquipment(SanitizedEquipmentSelection equipment) => new(
      SlotCode(equipment.Slot),
      AttachmentCode(equipment.State),
      equipment.DefinitionUid,
      equipment.EnhancementLevel,
      equipment.ResolvedManufacturerMatched?.Value,
      equipment.OverloadLines.OrderBy(static item => item.LineIndex)
          .Select(static item => new FetchedOverloadLine(
              item.LineIndex,
              item.OptionDefinitionUid,
              item.ExactValue.UnscaledValue,
              item.ExactValue.DecimalScale))
          .ToArray());

  private static string? NormalizeOptionalText(string? value) =>
      string.IsNullOrWhiteSpace(value) ? null : value.Trim();

  private static int SlotOrder(ProfileImportEquipmentSlot slot) => slot switch
  {
    ProfileImportEquipmentSlot.Head => 0,
    ProfileImportEquipmentSlot.Torso => 1,
    ProfileImportEquipmentSlot.Arms => 2,
    ProfileImportEquipmentSlot.Legs => 3,
    _ => throw new ArgumentOutOfRangeException(nameof(slot))
  };

  private static string SlotCode(ProfileImportEquipmentSlot slot) => slot switch
  {
    ProfileImportEquipmentSlot.Head => "head",
    ProfileImportEquipmentSlot.Torso => "torso",
    ProfileImportEquipmentSlot.Arms => "arms",
    ProfileImportEquipmentSlot.Legs => "legs",
    _ => throw new ArgumentOutOfRangeException(nameof(slot))
  };

  private static string AttachmentCode(ProfileImportAttachmentState state) => state switch
  {
    ProfileImportAttachmentState.Equipped => "equipped",
    ProfileImportAttachmentState.Unequipped => "unequipped",
    _ => throw new ArgumentOutOfRangeException(nameof(state))
  };

  private static string CollectionCode(ProfileImportCollectionKind kind) => kind switch
  {
    ProfileImportCollectionKind.Detached => "none",
    ProfileImportCollectionKind.GenericCollection => "generic_collection",
    ProfileImportCollectionKind.Favorite => "favorite",
    _ => throw new ArgumentOutOfRangeException(nameof(kind))
  };

  private static string ConsoleCode(ProfileImportConsoleCoordinate coordinate) => coordinate switch
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
    _ => throw new ArgumentOutOfRangeException(nameof(coordinate))
  };
}

public sealed record FetchedBasicAccountObservationResult(
    FetchedBasicAccountObservation? Observation,
    IReadOnlyList<string> ReasonCodes)
{
  public bool Succeeded => Observation is not null && ReasonCodes.Count == 0;
}

public static class CredentialBearingBasicInfoSanitizer
{
  private const int MaximumSourceBytes = 16 * 1024 * 1024;

  public static FetchedBasicAccountObservationResult Sanitize(Stream credentialBearingSource)
  {
    ArgumentNullException.ThrowIfNull(credentialBearingSource);
    try
    {
      using var document = ParseBounded(credentialBearingSource);
      var observations = new List<FetchedBasicAccountObservation>();
      foreach (var phaseName in new[] { "phase_1_initial_load", "phase_2_after_click" })
      {
        if (!document.RootElement.TryGetProperty(phaseName, out var packets) ||
            packets.ValueKind != JsonValueKind.Array)
          continue;
        foreach (var packet in packets.EnumerateArray())
        {
          if (!packet.TryGetProperty("data", out var data) || data.ValueKind != JsonValueKind.Object ||
              !data.TryGetProperty("basic_info", out var basic) || basic.ValueKind != JsonValueKind.Object)
            continue;
          observations.Add(new FetchedBasicAccountObservation(
              OptionalString(basic, "nickname", 64),
              OptionalPositiveInt32(basic, "lv"),
              OptionalScalarLabel(basic, "progress_normal_campaign"),
              OptionalScalarLabel(basic, "progress_hard_campaign"),
              OptionalScalarLabel(basic, "progress_easy_campaign")));
        }
      }

      if (observations.Count == 0)
        return new(null, new[] { "basic_info_missing" });
      var distinct = observations.Distinct().ToArray();
      return distinct.Length == 1
          ? new(distinct[0], Array.Empty<string>())
          : new(null, new[] { "basic_info_conflict" });
    }
    catch (JsonException)
    {
      return new(null, new[] { "basic_info_source_json_invalid" });
    }
    catch (InvalidDataException exception)
    {
      return new(null, new[] { exception.Message });
    }
  }

  private static JsonDocument ParseBounded(Stream source)
  {
    using var buffer = new MemoryStream();
    var chunk = new byte[81920];
    while (true)
    {
      var read = source.Read(chunk, 0, chunk.Length);
      if (read == 0) break;
      if (buffer.Length + read > MaximumSourceBytes)
        throw new InvalidDataException("basic_info_source_too_large");
      buffer.Write(chunk, 0, read);
    }
    return JsonDocument.Parse(buffer.ToArray());
  }

  private static string? OptionalString(JsonElement element, string propertyName, int maximumLength)
  {
    if (!element.TryGetProperty(propertyName, out var value) || value.ValueKind == JsonValueKind.Null)
      return null;
    if (value.ValueKind != JsonValueKind.String)
      throw new InvalidDataException("basic_info_field_invalid");
    var result = value.GetString()?.Trim();
    if (string.IsNullOrEmpty(result) || result.Length > maximumLength)
      throw new InvalidDataException("basic_info_field_invalid");
    return result;
  }

  private static int? OptionalPositiveInt32(JsonElement element, string propertyName)
  {
    if (!element.TryGetProperty(propertyName, out var value) || value.ValueKind == JsonValueKind.Null)
      return null;
    if (value.ValueKind != JsonValueKind.Number || !value.TryGetInt32(out var result) || result < 1)
      throw new InvalidDataException("basic_info_field_invalid");
    return result;
  }

  private static string? OptionalScalarLabel(JsonElement element, string propertyName)
  {
    if (!element.TryGetProperty(propertyName, out var value) || value.ValueKind == JsonValueKind.Null)
      return null;
    var result = value.ValueKind switch
    {
      JsonValueKind.String => value.GetString()?.Trim(),
      JsonValueKind.Number => value.GetRawText(),
      _ => throw new InvalidDataException("basic_info_field_invalid")
    };
    if (string.IsNullOrEmpty(result) || result.Length > 128)
      throw new InvalidDataException("basic_info_field_invalid");
    return result;
  }
}

public static class FetchedAccountSnapshotJsonCodec
{
  private static readonly JsonSerializerOptions Options = CreateOptions();

  public static byte[] Encode(FetchedAccountSnapshot snapshot)
  {
    Validate(snapshot);
    return JsonSerializer.SerializeToUtf8Bytes(snapshot, Options);
  }

  public static FetchedAccountSnapshot Decode(ReadOnlySpan<byte> utf8Json)
  {
    FetchedAccountSnapshot? snapshot;
    try
    {
      snapshot = JsonSerializer.Deserialize<FetchedAccountSnapshot>(utf8Json, Options);
    }
    catch (Exception exception) when (exception is JsonException or FormatException or ArgumentException)
    {
      throw new InvalidDataException("fetched_account_snapshot_json_invalid", exception);
    }
    Validate(snapshot);
    return snapshot!;
  }

  private static void Validate(FetchedAccountSnapshot? snapshot)
  {
    if (snapshot is null ||
        snapshot.SchemaVersion != FetchedAccountSnapshotContract.SchemaVersion ||
        !string.Equals(snapshot.ContractId, FetchedAccountSnapshotContract.ContractId, StringComparison.Ordinal) ||
        snapshot.CapturedAtUtc.Offset != TimeSpan.Zero ||
        snapshot.CapturedAtUtc.Ticks % 10 != 0 ||
        snapshot.Source is null ||
        snapshot.Completeness is null ||
        snapshot.Account is null ||
        snapshot.Progression is null ||
        snapshot.Characters is null ||
        snapshot.Source.ArtifactByteLength < 0 ||
        snapshot.Source.ArtifactSha256 == default ||
        snapshot.Source.CredentialOrSessionPersisted ||
        snapshot.Source.RawSourcePersisted ||
        snapshot.Account.SynchroLevel < 1 ||
        snapshot.Account.Consoles is null ||
        snapshot.Account.Consoles.Count > 9 ||
        snapshot.Completeness.ReasonCodes is null ||
        snapshot.Completeness.StatusCode is not ("complete" or "incomplete" or "failed") ||
        snapshot.Completeness.RosterCount < 0 ||
        snapshot.Completeness.CharacterDetailCount < 0 ||
        snapshot.Completeness.EquipmentCharacterCount < 0 ||
        snapshot.Completeness.MissingCharacterCount < 0)
      throw new InvalidDataException("fetched_account_snapshot_shape_invalid");

    if (snapshot.Source.WorkerCode != FetchedAccountSnapshotContract.WorkerCode ||
        snapshot.Source.WorkerVersion != FetchedAccountSnapshotContract.WorkerVersion ||
        snapshot.Completeness.ReasonCodes.Distinct(StringComparer.Ordinal).Count() !=
            snapshot.Completeness.ReasonCodes.Count ||
        snapshot.Characters.Select(static item => item.CharacterUid).Distinct().Count() !=
            snapshot.Characters.Count ||
        snapshot.Account.Consoles.Select(static item => item.CoordinateCode)
            .Distinct(StringComparer.Ordinal).Count() != snapshot.Account.Consoles.Count)
      throw new InvalidDataException("fetched_account_snapshot_integrity_invalid");

    if (snapshot.Completeness.StatusCode == "complete" &&
        (snapshot.Completeness.ReasonCodes.Count != 0 ||
         snapshot.Account.Consoles.Count != 9 ||
         snapshot.Account.DisplayName is null ||
         snapshot.Account.CommanderLevel is null ||
         snapshot.Progression.MainQuestDataSha256 is null ||
         snapshot.Progression.MainQuestCompletedCount is null ||
         snapshot.Progression.CompletedScenarioCount is null ||
         snapshot.Progression.ContentsOpenUnlockedCount is null))
      throw new InvalidDataException("fetched_account_snapshot_complete_state_invalid");
  }

  private static JsonSerializerOptions CreateOptions()
  {
    var options = new JsonSerializerOptions
    {
      PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
      WriteIndented = false,
      DefaultIgnoreCondition = JsonIgnoreCondition.Never,
      UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
    };
    options.Converters.Add(new EntityUidJsonConverter());
    options.Converters.Add(new Sha256DigestJsonConverter());
    return options;
  }

  private sealed class EntityUidJsonConverter : JsonConverter<EntityUid>
  {
    public override EntityUid Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
      var text = reader.GetString();
      return Guid.TryParseExact(text, "D", out var value)
          ? new EntityUid(value)
          : throw new JsonException("entity_uid_invalid");
    }

    public override void Write(Utf8JsonWriter writer, EntityUid value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.ToString());
  }

  private sealed class Sha256DigestJsonConverter : JsonConverter<Sha256Digest>
  {
    public override Sha256Digest Read(
        ref Utf8JsonReader reader,
        Type typeToConvert,
        JsonSerializerOptions options)
    {
      var text = reader.GetString();
      return Sha256Digest.TryParse(text, out var digest)
          ? digest
          : throw new JsonException("sha256_invalid");
    }

    public override void Write(
        Utf8JsonWriter writer,
        Sha256Digest value,
        JsonSerializerOptions options) => writer.WriteStringValue(value.Hex);
  }
}
