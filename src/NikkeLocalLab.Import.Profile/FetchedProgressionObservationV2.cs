using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Import.Profile;

public static class FetchedProgressionObservationV2Contract
{
  public const int SchemaVersion = 2;
  public const string ContractId = "nll/fetched-progression-observation/v2";
  public const string WorkerCode = "progression-source-sanitizer";
  public const string WorkerVersion = "v2";
}

public sealed record FetchedProgressionSourceV2(
    string WorkerCode,
    string WorkerVersion,
    string ProvenanceCode,
    bool CredentialOrSessionPersisted,
    bool OfficialUserIdentifierPersisted,
    bool RawSourcePersisted,
    bool RawSourcePathPersisted,
    bool RawSourceHashPersisted);

public sealed record FetchedProgressionCompletenessV2(
    string StatusCode,
    int AvailableComponentCount,
    int DerivedComponentCount,
    int UnavailableComponentCount,
    IReadOnlyList<string> ReasonCodes);

public sealed record FetchedProgressionComponentV2(
    string StateCode,
    string EvidenceCode,
    int? ItemCount,
    Sha256Digest? CanonicalEntriesSha256);

public sealed record FetchedMainQuestEntryV2(
    EntityUid QuestUid,
    bool Completed,
    bool RewardClaimed);

public sealed record FetchedMainQuestDataV2(
    FetchedProgressionComponentV2 Summary,
    int? CompletedCount,
    int? RewardClaimedCount,
    IReadOnlyList<FetchedMainQuestEntryV2> Entries);

public sealed record FetchedCompletedScenarioEntryV2(EntityUid ScenarioUid);

public sealed record FetchedCompletedScenariosV2(
    FetchedProgressionComponentV2 Summary,
    IReadOnlyList<FetchedCompletedScenarioEntryV2> Entries);

public sealed record FetchedContentsOpenEntryV2(
    EntityUid ContentUid,
    bool ButtonAnimationPlayed,
    bool PopupAnimationPlayed);

public sealed record FetchedContentsOpenUnlockedV2(
    FetchedProgressionComponentV2 Summary,
    IReadOnlyList<FetchedContentsOpenEntryV2> Entries);

public sealed record FetchedStageClearHistoryEntryV2(
    EntityUid StageUid,
    long? ClearedAt);

public sealed record FetchedStageClearHistorysV2(
    FetchedProgressionComponentV2 Summary,
    IReadOnlyList<FetchedStageClearHistoryEntryV2> Entries);

public sealed record FetchedTriggerEntryV2(
    EntityUid TriggerUid,
    int TypeCode,
    string TypeName,
    long UserValue,
    long CreatedAt);

public sealed record FetchedTriggersV2(
    FetchedProgressionComponentV2 Summary,
    IReadOnlyList<FetchedTriggerEntryV2> Entries);

public sealed record FetchedProgressionObservationV2(
    int SchemaVersion,
    string ContractId,
    EntityUid SnapshotUid,
    DateTimeOffset CapturedAtUtc,
    FetchedProgressionSourceV2 Source,
    FetchedProgressionCompletenessV2 Completeness,
    FetchedCompletedScenariosV2 CompletedScenarios,
    FetchedMainQuestDataV2 MainQuestData,
    FetchedContentsOpenUnlockedV2 ContentsOpenUnlocked,
    FetchedStageClearHistorysV2 StageClearHistorys,
    FetchedTriggersV2 Triggers);

public sealed record LegacyProgressionMaterializationCommandV2(
    EntityUid SnapshotUid,
    DateTimeOffset CapturedAtUtc,
    Stream PrivateSource,
    Stream? DerivedCandidateDatabase,
    byte[] LocalIdentitySecret,
    string? ExpectedExtractionUid = null);

public static class LegacyProgressionObservationMaterializerV2
{
  private const int MaximumSourceBytes = 32 * 1024 * 1024;
  private const string IdentityNamespace = "phase3b2-user-progression";
  private static readonly IReadOnlyDictionary<int, string> TriggerNames =
      new Dictionary<int, string>
      {
        [2] = "campaign_clear",
        [3] = "chapter_clear",
        [22] = "main_quest_clear",
        [25] = "campaign_group_clear",
        [35] = "hard_chapter_clear"
      };

  public static FetchedProgressionObservationV2 Materialize(
      LegacyProgressionMaterializationCommandV2 command)
  {
    ArgumentNullException.ThrowIfNull(command);
    ArgumentNullException.ThrowIfNull(command.PrivateSource);
    ArgumentNullException.ThrowIfNull(command.LocalIdentitySecret);
    if (command.LocalIdentitySecret.Length < 32)
      throw new ArgumentException("The local identity secret must contain at least 32 bytes.", nameof(command));
    if (command.CapturedAtUtc.Offset != TimeSpan.Zero || command.CapturedAtUtc.Ticks % 10 != 0)
      throw new ArgumentException("The capture timestamp must be a PostgreSQL-safe UTC value.", nameof(command));

    using var privateDocument = ParseBounded(command.PrivateSource);
    var privateRoot = privateDocument.RootElement;
    RequireObject(privateRoot, "progression_private_source_invalid");
    RequireContract(
        privateRoot,
        1,
        "nll/phase3b2-user-progression-private-source/v1",
        "progression_private_source_invalid");
    RequireFalse(privateRoot, "sourceSequencePersisted", "progression_private_source_invalid");
    RequireFalse(privateRoot, "officialUserIdentifierPersisted", "progression_private_source_invalid");
    RequireFalse(privateRoot, "credentialOrSessionFieldPersisted", "progression_private_source_invalid");
    if (command.ExpectedExtractionUid is not null &&
        (!privateRoot.TryGetProperty("extractionUid", out var extractionUid) ||
         extractionUid.ValueKind != JsonValueKind.String ||
         extractionUid.GetString() != command.ExpectedExtractionUid))
      throw new InvalidDataException("progression_private_source_receipt_binding_invalid");

    var mainQuestEntries = ReadMainQuestEntries(privateRoot, command.LocalIdentitySecret);
    var triggerEntries = ReadTriggerEntries(privateRoot, command.LocalIdentitySecret);
    var completedScenarios = UnavailableScenarios();
    var contentsOpen = UnavailableContents();
    var stageHistory = UnavailableStageHistory();
    var provenanceCode = "legacy_private_source_read_only_v1";

    if (command.DerivedCandidateDatabase is not null)
    {
      using var candidateDocument = ParseBounded(command.DerivedCandidateDatabase);
      var candidate = ReadCandidate(
          candidateDocument.RootElement,
          command.LocalIdentitySecret,
          mainQuestEntries,
          triggerEntries);
      completedScenarios = candidate.CompletedScenarios;
      contentsOpen = candidate.ContentsOpenUnlocked;
      stageHistory = candidate.StageClearHistorys;
      provenanceCode = "legacy_private_source_plus_derived_candidate_v1";
    }

    var mainQuest = new FetchedMainQuestDataV2(
        AvailableSummary(
            "observed",
            "selected_main_quest_trigger_with_operator_reward_attestation",
            mainQuestEntries),
        mainQuestEntries.Count(static item => item.Completed),
        mainQuestEntries.Count(static item => item.RewardClaimed),
        mainQuestEntries);
    var triggers = new FetchedTriggersV2(
        AvailableSummary("observed", "selected_trigger_cache_read_only", triggerEntries),
        triggerEntries);

    var states = new[]
    {
      completedScenarios.Summary.StateCode,
      mainQuest.Summary.StateCode,
      contentsOpen.Summary.StateCode,
      stageHistory.Summary.StateCode,
      triggers.Summary.StateCode
    };
    var reasons = new SortedSet<string>(StringComparer.Ordinal);
    AddUnavailableReason(reasons, completedScenarios.Summary, "completed_scenarios_unavailable");
    AddUnavailableReason(reasons, mainQuest.Summary, "main_quest_data_unavailable");
    AddUnavailableReason(reasons, contentsOpen.Summary, "contents_open_unlocked_unavailable");
    AddUnavailableReason(reasons, stageHistory.Summary, "stage_clear_historys_unavailable");
    AddUnavailableReason(reasons, triggers.Summary, "triggers_unavailable");

    var observation = new FetchedProgressionObservationV2(
        FetchedProgressionObservationV2Contract.SchemaVersion,
        FetchedProgressionObservationV2Contract.ContractId,
        command.SnapshotUid,
        command.CapturedAtUtc,
        new FetchedProgressionSourceV2(
            FetchedProgressionObservationV2Contract.WorkerCode,
            FetchedProgressionObservationV2Contract.WorkerVersion,
            provenanceCode,
            CredentialOrSessionPersisted: false,
            OfficialUserIdentifierPersisted: false,
            RawSourcePersisted: false,
            RawSourcePathPersisted: false,
            RawSourceHashPersisted: false),
        new FetchedProgressionCompletenessV2(
            reasons.Count == 0 ? "complete" : "incomplete",
            states.Count(static state => state == "observed"),
            states.Count(static state => state == "derived"),
            states.Count(static state => state == "unavailable"),
            reasons.ToArray()),
        completedScenarios,
        mainQuest,
        contentsOpen,
        stageHistory,
        triggers);
    FetchedProgressionObservationV2JsonCodec.Validate(observation);
    return observation;
  }

  private static IReadOnlyList<FetchedMainQuestEntryV2> ReadMainQuestEntries(
      JsonElement root,
      ReadOnlySpan<byte> secret)
  {
    var array = RequireArray(root, "mainQuestData", "progression_private_source_invalid");
    var result = new List<FetchedMainQuestEntryV2>(array.GetArrayLength());
    foreach (var item in array.EnumerateArray())
    {
      RequireObject(item, "progression_private_source_invalid");
      var rawId = RequireIntegerIdentifier(item, "questId", "progression_private_source_invalid");
      var rewardClaimed = RequireBoolean(item, "rewardClaimed", "progression_private_source_invalid");
      result.Add(new FetchedMainQuestEntryV2(
          SourceIdentityEncoder.Encode(secret, IdentityNamespace, "main_quest", rawId),
          Completed: true,
          rewardClaimed));
    }
    return SortUnique(result, static item => item.QuestUid, "progression_main_quest_duplicate");
  }

  private static IReadOnlyList<FetchedTriggerEntryV2> ReadTriggerEntries(
      JsonElement root,
      ReadOnlySpan<byte> secret)
  {
    var array = RequireArray(root, "selectedTriggers", "progression_private_source_invalid");
    var result = new List<FetchedTriggerEntryV2>(array.GetArrayLength());
    foreach (var item in array.EnumerateArray())
    {
      RequireObject(item, "progression_private_source_invalid");
      var typeCode = RequireInt32(item, "typeCode", "progression_private_source_invalid");
      if (!TriggerNames.TryGetValue(typeCode, out var typeName))
        throw new InvalidDataException("progression_trigger_type_unsupported");
      var rawConditionId = RequireIntegerIdentifier(
          item,
          "conditionId",
          "progression_private_source_invalid");
      var triggerUid = SourceIdentityEncoder.Encode(
          secret,
          IdentityNamespace,
          "trigger",
          string.Create(
              CultureInfo.InvariantCulture,
              $"{typeCode}:{rawConditionId}"));
      result.Add(new FetchedTriggerEntryV2(
          triggerUid,
          typeCode,
          typeName,
          RequireInt64(item, "userValue", "progression_private_source_invalid"),
          RequireInt64(item, "createdAt", "progression_private_source_invalid")));
    }
    return SortUnique(result, static item => item.TriggerUid, "progression_trigger_duplicate");
  }

  private static CandidateComponents ReadCandidate(
      JsonElement root,
      byte[] secret,
      IReadOnlyList<FetchedMainQuestEntryV2> privateMainQuests,
      IReadOnlyList<FetchedTriggerEntryV2> privateTriggers)
  {
    RequireObject(root, "progression_candidate_invalid");
    var users = RequireArray(root, "Users", "progression_candidate_invalid");
    if (users.GetArrayLength() != 1)
      throw new InvalidDataException("progression_candidate_user_count_invalid");
    var user = users[0];
    RequireObject(user, "progression_candidate_invalid");

    var scenarios = new List<FetchedCompletedScenarioEntryV2>();
    foreach (var item in RequireArray(
                 user,
                 "CompletedScenarios",
                 "progression_candidate_invalid").EnumerateArray())
    {
      var rawId = RequireScalarIdentifier(item, "progression_candidate_invalid");
      scenarios.Add(new FetchedCompletedScenarioEntryV2(
          SourceIdentityEncoder.Encode(secret, IdentityNamespace, "scenario", rawId)));
    }
    var sortedScenarios = SortUnique(
        scenarios,
        static item => item.ScenarioUid,
        "progression_scenario_duplicate");

    var contentsObject = RequireProperty(user, "ContentsOpenUnlocked", "progression_candidate_invalid");
    RequireObject(contentsObject, "progression_candidate_invalid");
    var contents = new List<FetchedContentsOpenEntryV2>();
    foreach (var property in contentsObject.EnumerateObject())
    {
      RequireObject(property.Value, "progression_candidate_invalid");
      contents.Add(new FetchedContentsOpenEntryV2(
          SourceIdentityEncoder.Encode(secret, IdentityNamespace, "content_open", property.Name),
          RequireBoolean(property.Value, "ButtonAnimationPlayed", "progression_candidate_invalid"),
          RequireBoolean(property.Value, "PopupAnimationPlayed", "progression_candidate_invalid")));
    }
    var sortedContents = SortUnique(
        contents,
        static item => item.ContentUid,
        "progression_content_duplicate");

    var candidateMainQuestObject = RequireProperty(user, "MainQuestData", "progression_candidate_invalid");
    RequireObject(candidateMainQuestObject, "progression_candidate_invalid");
    var candidateMainQuestUids = candidateMainQuestObject.EnumerateObject()
        .Select(property => SourceIdentityEncoder.Encode(
            secret,
            IdentityNamespace,
            "main_quest",
            property.Name))
        .OrderBy(static uid => uid.ToString(), StringComparer.Ordinal)
        .ToArray();
    RequireUidParity(
        candidateMainQuestUids,
        privateMainQuests.Select(static item => item.QuestUid),
        "progression_candidate_main_quest_drift");

    var candidateTriggers = new List<EntityUid>();
    foreach (var item in RequireArray(user, "Triggers", "progression_candidate_invalid").EnumerateArray())
    {
      var typeCode = RequireInt32(item, "Type", "progression_candidate_invalid");
      if (!TriggerNames.ContainsKey(typeCode))
        throw new InvalidDataException("progression_trigger_type_unsupported");
      var rawConditionId = RequireIntegerIdentifier(item, "ConditionId", "progression_candidate_invalid");
      candidateTriggers.Add(SourceIdentityEncoder.Encode(
          secret,
          IdentityNamespace,
          "trigger",
          string.Create(CultureInfo.InvariantCulture, $"{typeCode}:{rawConditionId}")));
    }
    RequireUidParity(
        candidateTriggers,
        privateTriggers.Select(static item => item.TriggerUid),
        "progression_candidate_trigger_drift");

    var stageArray = RequireArray(user, "StageClearHistorys", "progression_candidate_invalid");
    if (stageArray.GetArrayLength() != 0)
      throw new InvalidDataException("progression_candidate_stage_history_shape_unsupported");

    return new CandidateComponents(
        new FetchedCompletedScenariosV2(
            AvailableSummary("derived", "static_scenario_closure_projection", sortedScenarios),
            sortedScenarios),
        new FetchedContentsOpenUnlockedV2(
            AvailableSummary("derived", "static_content_unlock_projection", sortedContents),
            sortedContents),
        UnavailableStageHistory());
  }

  private static FetchedProgressionComponentV2 AvailableSummary<T>(
      string stateCode,
      string evidenceCode,
      IReadOnlyList<T> entries)
  {
    var canonical = FetchedProgressionObservationV2JsonCodec.EncodeEntries(entries);
    return new FetchedProgressionComponentV2(
        stateCode,
        evidenceCode,
        entries.Count,
        Sha256Digest.Compute(canonical));
  }

  private static FetchedCompletedScenariosV2 UnavailableScenarios() => new(
      UnavailableSummary("not_present_in_legacy_private_source"),
      Array.Empty<FetchedCompletedScenarioEntryV2>());

  private static FetchedContentsOpenUnlockedV2 UnavailableContents() => new(
      UnavailableSummary("not_present_in_legacy_private_source"),
      Array.Empty<FetchedContentsOpenEntryV2>());

  private static FetchedStageClearHistorysV2 UnavailableStageHistory() => new(
      UnavailableSummary("legacy_candidate_empty_not_observed"),
      Array.Empty<FetchedStageClearHistoryEntryV2>());

  private static FetchedProgressionComponentV2 UnavailableSummary(string evidenceCode) =>
      new("unavailable", evidenceCode, null, null);

  private static void AddUnavailableReason(
      ISet<string> reasons,
      FetchedProgressionComponentV2 summary,
      string reason)
  {
    if (summary.StateCode == "unavailable") reasons.Add(reason);
  }

  private static IReadOnlyList<T> SortUnique<T>(
      IEnumerable<T> values,
      Func<T, EntityUid> uid,
      string duplicateCode)
  {
    var result = values.OrderBy(item => uid(item).ToString(), StringComparer.Ordinal).ToArray();
    if (result.Select(uid).Distinct().Count() != result.Length)
      throw new InvalidDataException(duplicateCode);
    return result;
  }

  private static void RequireUidParity(
      IEnumerable<EntityUid> left,
      IEnumerable<EntityUid> right,
      string failureCode)
  {
    var leftValues = left.OrderBy(static value => value.ToString(), StringComparer.Ordinal).ToArray();
    var rightValues = right.OrderBy(static value => value.ToString(), StringComparer.Ordinal).ToArray();
    if (!leftValues.SequenceEqual(rightValues)) throw new InvalidDataException(failureCode);
  }

  private static JsonDocument ParseBounded(Stream source)
  {
    if (source.CanSeek && source.Length > MaximumSourceBytes)
      throw new InvalidDataException("progression_source_too_large");
    using var buffer = new MemoryStream();
    var chunk = new byte[81920];
    var total = 0;
    int read;
    while ((read = source.Read(chunk, 0, chunk.Length)) != 0)
    {
      total = checked(total + read);
      if (total > MaximumSourceBytes) throw new InvalidDataException("progression_source_too_large");
      buffer.Write(chunk, 0, read);
    }
    return JsonDocument.Parse(buffer.ToArray(), new JsonDocumentOptions
    {
      AllowTrailingCommas = false,
      CommentHandling = JsonCommentHandling.Disallow,
      MaxDepth = 128
    });
  }

  private static void RequireContract(JsonElement root, int version, string contractId, string code)
  {
    if (RequireInt32(root, "schemaVersion", code) != version ||
        RequireProperty(root, "contractId", code).ValueKind != JsonValueKind.String ||
        !string.Equals(root.GetProperty("contractId").GetString(), contractId, StringComparison.Ordinal))
      throw new InvalidDataException(code);
  }

  private static JsonElement RequireProperty(JsonElement element, string name, string code) =>
      element.TryGetProperty(name, out var value) ? value : throw new InvalidDataException(code);

  private static JsonElement RequireArray(JsonElement element, string name, string code)
  {
    var value = RequireProperty(element, name, code);
    return value.ValueKind == JsonValueKind.Array ? value : throw new InvalidDataException(code);
  }

  private static void RequireObject(JsonElement element, string code)
  {
    if (element.ValueKind != JsonValueKind.Object) throw new InvalidDataException(code);
  }

  private static void RequireFalse(JsonElement element, string name, string code)
  {
    if (RequireProperty(element, name, code).ValueKind is not JsonValueKind.False)
      throw new InvalidDataException(code);
  }

  private static bool RequireBoolean(JsonElement element, string name, string code)
  {
    var value = RequireProperty(element, name, code);
    return value.ValueKind switch
    {
      JsonValueKind.True => true,
      JsonValueKind.False => false,
      _ => throw new InvalidDataException(code)
    };
  }

  private static int RequireInt32(JsonElement element, string name, string code)
  {
    var value = RequireProperty(element, name, code);
    return value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var result)
        ? result
        : throw new InvalidDataException(code);
  }

  private static long RequireInt64(JsonElement element, string name, string code)
  {
    var value = RequireProperty(element, name, code);
    return value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var result)
        ? result
        : throw new InvalidDataException(code);
  }

  private static string RequireIntegerIdentifier(JsonElement element, string name, string code)
  {
    var value = RequireProperty(element, name, code);
    return value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var result)
        ? result.ToString(CultureInfo.InvariantCulture)
        : throw new InvalidDataException(code);
  }

  private static string RequireScalarIdentifier(JsonElement value, string code) => value.ValueKind switch
  {
    JsonValueKind.String when !string.IsNullOrWhiteSpace(value.GetString()) => value.GetString()!,
    JsonValueKind.Number when value.TryGetInt64(out var integer) => integer.ToString(CultureInfo.InvariantCulture),
    _ => throw new InvalidDataException(code)
  };

  private sealed record CandidateComponents(
      FetchedCompletedScenariosV2 CompletedScenarios,
      FetchedContentsOpenUnlockedV2 ContentsOpenUnlocked,
      FetchedStageClearHistorysV2 StageClearHistorys);
}

public static class FetchedProgressionObservationV2JsonCodec
{
  private static readonly JsonSerializerOptions Options = CreateOptions();

  public static byte[] Encode(FetchedProgressionObservationV2 observation)
  {
    Validate(observation);
    return JsonSerializer.SerializeToUtf8Bytes(observation, Options);
  }

  public static FetchedProgressionObservationV2 Decode(ReadOnlySpan<byte> utf8Json)
  {
    FetchedProgressionObservationV2? observation;
    try
    {
      observation = JsonSerializer.Deserialize<FetchedProgressionObservationV2>(utf8Json, Options);
    }
    catch (Exception exception) when (exception is JsonException or FormatException or ArgumentException)
    {
      throw new InvalidDataException("fetched_progression_observation_v2_json_invalid", exception);
    }
    Validate(observation);
    return observation!;
  }

  internal static byte[] EncodeEntries<T>(IReadOnlyList<T> entries) =>
      JsonSerializer.SerializeToUtf8Bytes(entries, Options);

  public static void Validate(FetchedProgressionObservationV2? observation)
  {
    if (observation is null ||
        observation.SchemaVersion != FetchedProgressionObservationV2Contract.SchemaVersion ||
        observation.ContractId != FetchedProgressionObservationV2Contract.ContractId ||
        observation.CapturedAtUtc.Offset != TimeSpan.Zero ||
        observation.CapturedAtUtc.Ticks % 10 != 0 ||
        observation.Source is null ||
        observation.Completeness is null ||
        observation.CompletedScenarios is null ||
        observation.MainQuestData is null ||
        observation.ContentsOpenUnlocked is null ||
        observation.StageClearHistorys is null ||
        observation.Triggers is null ||
        observation.Source.WorkerCode != FetchedProgressionObservationV2Contract.WorkerCode ||
        observation.Source.WorkerVersion != FetchedProgressionObservationV2Contract.WorkerVersion ||
        observation.Source.CredentialOrSessionPersisted ||
        observation.Source.OfficialUserIdentifierPersisted ||
        observation.Source.RawSourcePersisted ||
        observation.Source.RawSourcePathPersisted ||
        observation.Source.RawSourceHashPersisted ||
        observation.Completeness.StatusCode is not ("complete" or "incomplete") ||
        observation.Completeness.ReasonCodes is null ||
        observation.Completeness.ReasonCodes.Distinct(StringComparer.Ordinal).Count() !=
            observation.Completeness.ReasonCodes.Count)
      throw new InvalidDataException("fetched_progression_observation_v2_shape_invalid");

    ValidateComponent(
        observation.CompletedScenarios.Summary,
        observation.CompletedScenarios.Entries,
        observation.CompletedScenarios.Entries.Select(static item => item.ScenarioUid));
    ValidateComponent(
        observation.MainQuestData.Summary,
        observation.MainQuestData.Entries,
        observation.MainQuestData.Entries.Select(static item => item.QuestUid));
    ValidateComponent(
        observation.ContentsOpenUnlocked.Summary,
        observation.ContentsOpenUnlocked.Entries,
        observation.ContentsOpenUnlocked.Entries.Select(static item => item.ContentUid));
    ValidateComponent(
        observation.StageClearHistorys.Summary,
        observation.StageClearHistorys.Entries,
        observation.StageClearHistorys.Entries.Select(static item => item.StageUid));
    ValidateComponent(
        observation.Triggers.Summary,
        observation.Triggers.Entries,
        observation.Triggers.Entries.Select(static item => item.TriggerUid));

    if (observation.MainQuestData.CompletedCount !=
            NullableCount(observation.MainQuestData.Summary, observation.MainQuestData.Entries.Count(static item => item.Completed)) ||
        observation.MainQuestData.RewardClaimedCount !=
            NullableCount(observation.MainQuestData.Summary, observation.MainQuestData.Entries.Count(static item => item.RewardClaimed)) ||
        observation.Triggers.Entries.Any(item =>
            !LegacyProgressionObservationMaterializerV2TriggerNames.Contains(item.TypeCode, item.TypeName)))
      throw new InvalidDataException("fetched_progression_observation_v2_integrity_invalid");

    var summaries = new[]
    {
      observation.CompletedScenarios.Summary,
      observation.MainQuestData.Summary,
      observation.ContentsOpenUnlocked.Summary,
      observation.StageClearHistorys.Summary,
      observation.Triggers.Summary
    };
    var observed = summaries.Count(static item => item.StateCode == "observed");
    var derived = summaries.Count(static item => item.StateCode == "derived");
    var unavailable = summaries.Count(static item => item.StateCode == "unavailable");
    if (observation.Completeness.AvailableComponentCount != observed ||
        observation.Completeness.DerivedComponentCount != derived ||
        observation.Completeness.UnavailableComponentCount != unavailable ||
        (observation.Completeness.StatusCode == "complete") != (unavailable == 0) ||
        (observation.Completeness.StatusCode == "complete" && observation.Completeness.ReasonCodes.Count != 0))
      throw new InvalidDataException("fetched_progression_observation_v2_completeness_invalid");
  }

  private static int? NullableCount(FetchedProgressionComponentV2 summary, int count) =>
      summary.StateCode == "unavailable" ? null : count;

  private static void ValidateComponent<T>(
      FetchedProgressionComponentV2? summary,
      IReadOnlyList<T>? entries,
      IEnumerable<EntityUid> uids)
  {
    if (summary is null || entries is null ||
        summary.StateCode is not ("observed" or "derived" or "unavailable") ||
        string.IsNullOrWhiteSpace(summary.EvidenceCode))
      throw new InvalidDataException("fetched_progression_component_invalid");
    if (summary.StateCode == "unavailable")
    {
      if (summary.ItemCount is not null || summary.CanonicalEntriesSha256 is not null || entries.Count != 0)
        throw new InvalidDataException("fetched_progression_component_unavailable_invalid");
      return;
    }
    if (summary.ItemCount != entries.Count || summary.CanonicalEntriesSha256 is null ||
        summary.CanonicalEntriesSha256 != Sha256Digest.Compute(EncodeEntries(entries)))
      throw new InvalidDataException("fetched_progression_component_hash_invalid");
    var values = uids.Select(static uid => uid.ToString()).ToArray();
    if (values.Distinct(StringComparer.Ordinal).Count() != values.Length ||
        !values.SequenceEqual(values.OrderBy(static value => value, StringComparer.Ordinal)))
      throw new InvalidDataException("fetched_progression_component_order_invalid");
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
    options.Converters.Add(new EntityUidConverter());
    options.Converters.Add(new Sha256Converter());
    return options;
  }

  private sealed class EntityUidConverter : JsonConverter<EntityUid>
  {
    public override EntityUid Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        Guid.TryParseExact(reader.GetString(), "D", out var value) && value != Guid.Empty
            ? new EntityUid(value)
            : throw new JsonException("entity_uid_invalid");

    public override void Write(Utf8JsonWriter writer, EntityUid value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.ToString());
  }

  private sealed class Sha256Converter : JsonConverter<Sha256Digest>
  {
    public override Sha256Digest Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        Sha256Digest.TryParse(reader.GetString(), out var value)
            ? value
            : throw new JsonException("sha256_invalid");

    public override void Write(Utf8JsonWriter writer, Sha256Digest value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.ToString());
  }

  private static class LegacyProgressionObservationMaterializerV2TriggerNames
  {
    private static readonly IReadOnlyDictionary<int, string> Values = new Dictionary<int, string>
    {
      [2] = "campaign_clear",
      [3] = "chapter_clear",
      [22] = "main_quest_clear",
      [25] = "campaign_group_clear",
      [35] = "hard_chapter_clear"
    };

    public static bool Contains(int code, string name) =>
        Values.TryGetValue(code, out var expected) && expected == name;
  }
}
