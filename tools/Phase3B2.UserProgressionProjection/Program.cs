using System.Globalization;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using EpinelPS.Data;
using EpinelPS.Models;
using NewtonsoftJson = Newtonsoft.Json.JsonConvert;

const string ProjectionContract =
    "nll/phase3b2-epinel-user-progression-private-projection/v1";
const string SummaryContract =
    "nll/phase3b2-epinel-user-progression-projection-summary/v1";

if (args.Length > 0 && string.Equals(args[0], "materialize", StringComparison.Ordinal))
{
    await MaterializeAsync(args[1..]);
    Environment.Exit(0);
}

if (args.Length != 3 || !string.Equals(args[0], "inspect", StringComparison.Ordinal))
{
    throw new InvalidOperationException(
        "supported commands: inspect, materialize");
}

var packPath = Path.GetFullPath(args[1]);
var projectionPath = Path.GetFullPath(args[2]);
Require(File.Exists(packPath), "static_data_pack_missing");
Require(!File.Exists(projectionPath), "private_projection_already_exists");

var originalOut = Console.Out;
GameData gameData;
try
{
    Console.SetOut(TextWriter.Null);
    gameData = new GameData(packPath);
    var instanceField = typeof(GameData).GetField(
        "_instance", BindingFlags.Static | BindingFlags.NonPublic) ??
        throw new MissingFieldException(typeof(GameData).FullName, "_instance");
    instanceField.SetValue(null, gameData);
    await gameData.Parse();
}
finally
{
    Console.SetOut(originalOut);
}

Require(gameData.ContentsOpenTable.TryGetValue(ContentsOpen.SoloRaid,
    out var soloRaid), "solo_raid_contents_open_record_missing");
Require(gameData.ContentsOpenTable.ContainsKey(ContentsOpen.SoloRaidMuseum),
    "solo_raid_museum_contents_open_record_missing");
Require(soloRaid!.OpenCondition is not null && soloRaid.OpenCondition.Count > 0,
    "solo_raid_open_condition_missing");

var campaignMainStages = gameData.StageDataRecords.Values
    .Where(stage => stage.StageType == StageType.Main)
    .GroupBy(stage => (stage.ChapterMod, stage.ChapterId))
    .OrderBy(group => group.Key.ChapterMod)
    .ThenBy(group => group.Key.ChapterId)
    .SelectMany(group => group.OrderBy(stage => stage.Id)
        .Select((stage, index) => new PrivateStage(
            stage.Id,
            stage.ChapterMod,
            stage.ChapterId - 1,
            index + 1,
            ResolveMapId(gameData, stage.ChapterId, stage.ChapterMod),
            stage.ParentsId,
            stage.StageChild)))
    .ToArray();
Require(campaignMainStages.Length > 0 &&
    campaignMainStages.Select(stage => stage.StageId).Distinct().Count() ==
        campaignMainStages.Length, "campaign_main_stage_projection_invalid");

var stageById = campaignMainStages.ToDictionary(stage => stage.StageId);
var openConditions = soloRaid.OpenCondition!
    .Select(condition =>
    {
        string? stageLabel = null;
        if (condition.OpenConditionType == ContentsOpenCondition.StageClear)
        {
            Require(stageById.TryGetValue(condition.OpenConditionValue,
                out var stage) && stage!.Mod == ChapterMod.Normal,
                "solo_raid_stage_condition_not_normal_main");
            stageLabel = StageLabel(stage!);
        }
        return new PrivateOpenCondition(
            condition.OpenConditionType,
            condition.OpenConditionValue,
            stageLabel);
    })
    .ToArray();

string? viewStageLabel = null;
if (soloRaid.ViewConditionType == ContentsOpenCondition.StageClear)
{
    Require(stageById.TryGetValue(soloRaid.ViewConditionValue, out var stage),
        "solo_raid_view_stage_not_normal_main");
    Require(stage!.Mod == ChapterMod.Normal,
        "solo_raid_view_stage_not_normal_main");
    viewStageLabel = StageLabel(stage!);
}

var tutorialRows = gameData.TutorialTable.Values
    .OrderBy(row => row.GroupId)
    .ThenBy(row => row.Id)
    .ToArray();
Require(tutorialRows.Length > 0, "tutorial_table_empty");
var tutorialGroups = tutorialRows.GroupBy(row => row.GroupId)
    .Select(group =>
    {
        var rows = group.OrderBy(row => row.Id).ToArray();
        var terminal = rows[^1];
        var clearedStageIds = rows.Select(row => row.ClearedStageId)
            .Where(value => value != 0).Distinct().Order().ToArray();
        var closeStageIds = rows.Select(row => row.CloseStageId)
            .Where(value => value != 0).Distinct().Order().ToArray();
        return new PrivateTutorialGroup(
            group.Key,
            terminal.Id,
            terminal.VersionGroup,
            rows.Length,
            rows.Select(row => row.SubGroupId).Distinct().Order().ToArray(),
            rows.Select(row => row.TriggerValue).Distinct().Order().ToArray(),
            rows.Select(row => row.CloseValue).Distinct().Order().ToArray(),
            clearedStageIds,
            closeStageIds,
            rows.Count(row => row.SaveTutorial),
            rows.Count(row => row.SkipButtonControl));
    })
    .OrderBy(group => group.GroupId)
    .ToArray();
Require(tutorialGroups.Select(group => group.GroupId).Distinct().Count() ==
    tutorialGroups.Length, "tutorial_group_projection_invalid");

var stageCanonical = string.Concat(campaignMainStages.Select(stage =>
    string.Create(CultureInfo.InvariantCulture,
        $"{stage.StageId}\t{(int)stage.Mod}\t{stage.Chapter}\t" +
        $"{stage.Ordinal}\t{stage.MapId}\t" +
        $"{stage.ParentStageId}\t{stage.ChildStageId}\n")));
var tutorialCanonical = string.Concat(tutorialGroups.Select(group =>
    string.Create(CultureInfo.InvariantCulture,
        $"{group.GroupId}\t{group.TerminalTutorialId}\t{group.VersionGroup}\t" +
        $"{group.MemberCount}\t{string.Join(',', group.SubGroups.Select(v => (int)v))}\t" +
        $"{string.Join(',', group.Triggers.Select(v => (int)v))}\t" +
        $"{string.Join(',', group.CloseTriggers.Select(v => (int)v))}\t" +
        $"{string.Join(',', group.ClearedStageIds)}\t{string.Join(',', group.CloseStageIds)}\t" +
        $"{group.SaveTutorialCount}\t{group.SkipControlledCount}\n")));

var projection = new PrivateProjection(
    1,
    ProjectionContract,
    await Sha256FileAsync(packPath),
    new FileInfo(packPath).Length,
    soloRaid.ViewConditionType,
    soloRaid.ViewConditionValue,
    viewStageLabel,
    openConditions,
    campaignMainStages.Length,
    Sha256Text(stageCanonical),
    campaignMainStages,
    tutorialRows.Length,
    tutorialGroups.Length,
    Sha256Text(tutorialCanonical),
    tutorialGroups,
    ContentsOpen.SoloRaidMuseum);
await WriteExclusiveJsonAsync(projectionPath, projection);

var stageModeCounts = campaignMainStages
    .GroupBy(stage => stage.Mod.ToString())
    .OrderBy(group => group.Key, StringComparer.Ordinal)
    .ToDictionary(group => group.Key, group => group.Count(), StringComparer.Ordinal);
var subgroupCounts = tutorialGroups
    .SelectMany(group => group.SubGroups.DefaultIfEmpty(ContentsTutorialSubGroup.None))
    .GroupBy(value => value.ToString())
    .OrderBy(group => group.Key, StringComparer.Ordinal)
    .ToDictionary(group => group.Key, group => group.Count(), StringComparer.Ordinal);
var summary = new
{
    schemaVersion = 1,
    contractId = SummaryContract,
    staticDataPackByteLength = projection.StaticDataPackByteLength,
    staticDataPackSha256 = projection.StaticDataPackSha256,
    soloRaidViewConditionCode = projection.SoloRaidViewConditionType.ToString(),
    soloRaidViewStageLabel = projection.SoloRaidViewStageLabel,
    soloRaidOpenConditionCodes = projection.SoloRaidOpenConditions
        .Select(condition => condition.Type.ToString()).ToArray(),
    soloRaidOpenStageLabels = projection.SoloRaidOpenConditions
        .Where(condition => condition.StageLabel is not null)
        .Select(condition => condition.StageLabel).ToArray(),
    campaignMainStageCount = projection.CampaignMainStageCount,
    campaignMainStageModeCounts = stageModeCounts,
    campaignMainStageCanonicalSha256 = projection.CampaignMainStageCanonicalSha256,
    tutorialRecordCount = projection.TutorialRecordCount,
    tutorialGroupCount = projection.TutorialGroupCount,
    tutorialGroupCanonicalSha256 = projection.TutorialGroupCanonicalSha256,
    tutorialGroupSubgroupCounts = subgroupCounts,
    soloRaidMuseumExcluded = true,
    privateProjectionByteLength = new FileInfo(projectionPath).Length,
    privateProjectionSha256 = await Sha256FileAsync(projectionPath),
    rawOriginalIdentifiersEmittedToStdout = false
};
Console.WriteLine(JsonSerializer.Serialize(summary, JsonOptions()));
Environment.Exit(0);

static async Task MaterializeAsync(string[] commandArgs)
{
    if (commandArgs.Length != 4)
    {
        throw new InvalidOperationException(
            "materialize requires: <private-projection.json> " +
            "<user-progress-source.json> <golden-db.json> <candidate-db.json>");
    }

    var projectionPath = Path.GetFullPath(commandArgs[0]);
    var sourcePath = Path.GetFullPath(commandArgs[1]);
    var inputPath = Path.GetFullPath(commandArgs[2]);
    var outputPath = Path.GetFullPath(commandArgs[3]);
    Require(File.Exists(projectionPath) && File.Exists(sourcePath) &&
        File.Exists(inputPath), "materialization_input_missing");
    Require(!File.Exists(outputPath), "candidate_database_already_exists");

    var projection = JsonSerializer.Deserialize<PrivateProjection>(
        await File.ReadAllTextAsync(projectionPath), JsonOptions()) ??
        throw new InvalidDataException("private_projection_json_invalid");
    Require(projection.SchemaVersion == 1 &&
        string.Equals(projection.ContractId, ProjectionContract,
            StringComparison.Ordinal) &&
        projection.CampaignMainStageCount == projection.CampaignMainStages.Length &&
        projection.CampaignMainStages.Select(stage => stage.StageId)
            .Distinct().Count() == projection.CampaignMainStages.Length &&
        projection.TutorialGroupCount == projection.TutorialGroups.Length &&
        projection.TutorialGroups.Select(group => group.GroupId)
            .Distinct().Count() == projection.TutorialGroups.Length,
        "private_projection_contract_invalid");

    var observed = await ReadUserProgressAsync(sourcePath);
    var targets = new[]
    {
        ResolveTarget(projection, ChapterMod.Normal, observed.Normal),
        ResolveTarget(projection, ChapterMod.Hard, observed.Hard),
        ResolveTarget(projection, ChapterMod.Story, observed.Story)
    };
    var closures = targets.ToDictionary(
        target => target.Mod,
        target => projection.CampaignMainStages
            .Where(stage => stage.Mod == target.Mod &&
                (stage.Chapter < target.Chapter ||
                    stage.Chapter == target.Chapter &&
                    stage.Ordinal <= target.Ordinal))
            .OrderBy(stage => stage.Chapter)
            .ThenBy(stage => stage.Ordinal)
            .ToArray());
    foreach (var target in targets)
    {
        var closure = closures[target.Mod];
        Require(closure.Length > 0 && closure[^1].StageId == target.StageId &&
            closure.Select(stage => stage.StageId).Distinct().Count() ==
                closure.Length, $"{target.Mod}_campaign_closure_invalid");
    }

    var database = JsonNode.Parse(await File.ReadAllTextAsync(inputPath)) as
        JsonObject ?? throw new InvalidDataException("golden_database_root_invalid");
    var users = database["Users"] as JsonArray ??
        throw new InvalidDataException("golden_database_users_missing");
    Require(users.Count == 1 && users[0] is JsonObject,
        "golden_database_user_shape_invalid");
    var user = (JsonObject)users[0]!;
    Require((user["Characters"] as JsonArray)?.Count == 193 &&
        ScalarInt(user, "LastNormalStageCleared") == 0 &&
        ScalarInt(user, "LastHardStageCleared") == 0 &&
        ScalarInt(user, "LastStoryStageCleared") == 0 &&
        (user["FieldInfoNew"] as JsonObject)?.Count == 0 &&
        (user["ClearedTutorialDataNew"] as JsonObject)?.Count == 0 &&
        (user["StageClearHistorys"] as JsonArray)?.Count == 0,
        "golden_database_progression_baseline_invalid");

    var unaffectedBefore = UnaffectedCanonicalSha256(database);
    user["LastNormalStageCleared"] = observed.Normal;
    user["LastHardStageCleared"] = observed.Hard;
    user["LastStoryStageCleared"] = observed.Story;

    var fieldProjection = new JsonObject();
    foreach (var map in closures.Values.SelectMany(stages => stages)
        .GroupBy(stage => stage.MapId, StringComparer.Ordinal)
        .OrderBy(group => group.Key, StringComparer.Ordinal))
    {
        fieldProjection.Add(map.Key, new JsonObject
        {
            ["CompletedStages"] = new JsonArray(map
                .OrderBy(stage => stage.Chapter)
                .ThenBy(stage => stage.Ordinal)
                .Select(stage => (JsonNode?)JsonValue.Create(stage.StageId))
                .ToArray()),
            ["CompletedObjects"] = new JsonArray(),
            ["FieldItemTableIdList"] = new JsonArray(),
            ["AcquiredPasswordList"] = new JsonArray(),
            ["UnlockedDoorList"] = new JsonArray(),
            ["BossEntered"] = false
        });
    }
    user["FieldInfoNew"] = fieldProjection;

    var tutorialProjection = new JsonObject();
    foreach (var group in projection.TutorialGroups.OrderBy(group => group.GroupId))
    {
        tutorialProjection.Add(group.GroupId.ToString(CultureInfo.InvariantCulture),
            new JsonObject
            {
                ["Id"] = group.TerminalTutorialId,
                ["VersionGroup"] = group.VersionGroup
            });
    }
    user["ClearedTutorialDataNew"] = tutorialProjection;

    var unaffectedAfter = UnaffectedCanonicalSha256(database);
    Require(string.Equals(unaffectedBefore, unaffectedAfter, StringComparison.Ordinal),
        "unrelated_golden_database_state_changed");
    await WriteExclusiveJsonAsync(outputPath, database);

    var reloaded = JsonNode.Parse(await File.ReadAllTextAsync(outputPath)) as
        JsonObject ?? throw new InvalidDataException("candidate_database_reload_invalid");
    var reloadedUser = (reloaded["Users"] as JsonArray)?[0] as JsonObject;
    Require(reloadedUser is not null &&
        ScalarInt(reloadedUser, "LastNormalStageCleared") == observed.Normal &&
        ScalarInt(reloadedUser, "LastHardStageCleared") == observed.Hard &&
        ScalarInt(reloadedUser, "LastStoryStageCleared") == observed.Story &&
        (reloadedUser["ClearedTutorialDataNew"] as JsonObject)?.Count ==
            projection.TutorialGroupCount &&
        string.Equals(UnaffectedCanonicalSha256(reloaded), unaffectedBefore,
            StringComparison.Ordinal), "candidate_database_verification_failed");
    var runtimeRoundTrip = NewtonsoftJson.DeserializeObject<CoreInfo>(
        await File.ReadAllTextAsync(outputPath)) ??
        throw new InvalidDataException("candidate_database_runtime_roundtrip_invalid");
    Require(runtimeRoundTrip.Users.Count == 1 &&
        runtimeRoundTrip.Users[0].Characters.Count == 193 &&
        runtimeRoundTrip.Users[0].LastNormalStageCleared == observed.Normal &&
        runtimeRoundTrip.Users[0].LastHardStageCleared == observed.Hard &&
        runtimeRoundTrip.Users[0].LastStoryStageCleared == observed.Story &&
        runtimeRoundTrip.Users[0].FieldInfoNew.Values
            .Sum(field => field.CompletedStages.Count) ==
                closures.Values.Sum(stages => stages.Length) &&
        runtimeRoundTrip.Users[0].ClearedTutorialDataNew.Count ==
            projection.TutorialGroupCount,
        "candidate_database_runtime_roundtrip_invalid");

    var summary = new
    {
        schemaVersion = 1,
        contractId =
            "nll/phase3b2-epinel-user-progression-candidate-materialization-summary/v1",
        sourceByteLength = new FileInfo(sourcePath).Length,
        sourceSha256 = await Sha256FileAsync(sourcePath),
        databaseBeforeByteLength = new FileInfo(inputPath).Length,
        databaseBeforeSha256 = await Sha256FileAsync(inputPath),
        candidateDatabaseByteLength = new FileInfo(outputPath).Length,
        candidateDatabaseSha256 = await Sha256FileAsync(outputPath),
        resolvedProgress = targets.Select(target => new
        {
            mode = target.Mod.ToString(),
            stageLabel = StageLabel(target),
            exactStaticDataMatch = true
        }).ToArray(),
        completedMainStageCounts = closures.OrderBy(pair => pair.Key)
            .ToDictionary(pair => pair.Key.ToString(), pair => pair.Value.Length,
                StringComparer.Ordinal),
        fieldMapCount = fieldProjection.Count,
        tutorialGroupCount = tutorialProjection.Count,
        epinelRuntimeRoundTripVerified = true,
        stageClearHistoryFabricated = false,
        scenarioStateFabricated = false,
        questStateFabricated = false,
        rewardStateFabricated = false,
        unrelatedStateChanged = false,
        unrelatedStateCanonicalSha256 = unaffectedBefore,
        rawOriginalIdentifiersEmittedToStdout = false
    };
    Console.WriteLine(JsonSerializer.Serialize(summary, JsonOptions()));
}

static PrivateStage ResolveTarget(PrivateProjection projection, ChapterMod mod,
    int stageId)
{
    var matches = projection.CampaignMainStages
        .Where(stage => stage.Mod == mod && stage.StageId == stageId).ToArray();
    Require(matches.Length == 1, $"{mod}_user_progress_not_in_exact_static_data");
    return matches[0];
}

static async Task<ObservedProgress> ReadUserProgressAsync(string sourcePath)
{
    await using var stream = File.OpenRead(sourcePath);
    using var document = await JsonDocument.ParseAsync(stream, new JsonDocumentOptions
    {
        AllowTrailingCommas = false,
        CommentHandling = JsonCommentHandling.Disallow,
        MaxDepth = 32
    });
    var root = document.RootElement;
    if (root.ValueKind != JsonValueKind.Object ||
        !root.TryGetProperty("phase_1_initial_load", out var phaseOne) ||
        !root.TryGetProperty("phase_2_after_click", out var phaseTwo) ||
        phaseOne.ValueKind != JsonValueKind.Array ||
        phaseTwo.ValueKind != JsonValueKind.Array)
    {
        throw new InvalidDataException("user_progress_source_shape_invalid");
    }
    var packets = phaseOne.EnumerateArray().Concat(phaseTwo.EnumerateArray())
        .Where(packet => packet.TryGetProperty("endpoint", out var endpoint) &&
            endpoint.ValueKind == JsonValueKind.String &&
            string.Equals(endpoint.GetString(), "GetUserProfileBasicInfo",
                StringComparison.Ordinal))
        .ToArray();
    if (packets.Length != 1 ||
        !packets[0].TryGetProperty("data", out var data) ||
        data.ValueKind != JsonValueKind.Object ||
        !data.TryGetProperty("basic_info", out var basic) ||
        basic.ValueKind != JsonValueKind.Object)
    {
        throw new InvalidDataException("user_progress_packet_shape_invalid");
    }
    return new ObservedProgress(
        PositiveStageId(basic, "progress_normal_campaign"),
        PositiveStageId(basic, "progress_hard_campaign"),
        PositiveStageId(basic, "progress_easy_campaign"));
}

static int PositiveStageId(JsonElement element, string property)
{
    Require(element.TryGetProperty(property, out var value),
        $"user_progress_{property}_missing");
    var text = value.ValueKind switch
    {
        JsonValueKind.String => value.GetString(),
        JsonValueKind.Number => value.GetRawText(),
        _ => null
    };
    Require(int.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture,
        out var parsed) && parsed > 0, $"user_progress_{property}_invalid");
    return parsed;
}

static int ScalarInt(JsonObject value, string property) =>
    value[property]?.GetValue<int>() ??
        throw new InvalidDataException($"database_{property}_invalid");

static string UnaffectedCanonicalSha256(JsonObject database)
{
    var clone = database.DeepClone() as JsonObject ??
        throw new InvalidDataException("database_clone_invalid");
    var users = clone["Users"] as JsonArray ??
        throw new InvalidDataException("database_clone_users_missing");
    var user = users[0] as JsonObject ??
        throw new InvalidDataException("database_clone_user_missing");
    user["LastNormalStageCleared"] = 0;
    user["LastHardStageCleared"] = 0;
    user["LastStoryStageCleared"] = 0;
    user["FieldInfoNew"] = new JsonObject();
    user["ClearedTutorialDataNew"] = new JsonObject();
    return Sha256Text(clone.ToJsonString(new JsonSerializerOptions
    {
        WriteIndented = false
    }));
}

static string ResolveMapId(GameData gameData, int chapterId, ChapterMod mod)
{
    var candidates = gameData.ChapterCampaignData.Values
        .Where(chapter => chapter.Chapter + 1 == chapterId)
        .Select(chapter => mod switch
        {
            ChapterMod.Normal => chapter.FieldId,
            ChapterMod.Hard => chapter.HardFieldId,
            ChapterMod.Story => chapter.StoryFieldId,
            _ => null
        })
        .Where(value => !string.IsNullOrWhiteSpace(value))
        .Distinct(StringComparer.Ordinal)
        .ToArray();
    if (candidates.Length != 1)
    {
        throw new InvalidDataException(
            $"campaign_map_resolution_invalid_for_{mod}_chapter_{chapterId}");
    }
    return candidates[0]!;
}

static string StageLabel(PrivateStage stage) =>
    string.Create(CultureInfo.InvariantCulture, $"{stage.Chapter}-{stage.Ordinal}");

static void Require(bool condition, string code)
{
    if (!condition) throw new InvalidDataException(code);
}

static JsonSerializerOptions JsonOptions() => new()
{
    PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    WriteIndented = true
};

static async Task WriteExclusiveJsonAsync(string path, object value)
{
    Directory.CreateDirectory(Path.GetDirectoryName(path) ??
        throw new InvalidDataException("private_projection_parent_invalid"));
    await using var stream = new FileStream(path, FileMode.CreateNew,
        FileAccess.Write, FileShare.None);
    await JsonSerializer.SerializeAsync(stream, value, JsonOptions());
    await stream.WriteAsync(Encoding.UTF8.GetBytes("\n"));
}

static async Task<string> Sha256FileAsync(string path)
{
    await using var stream = File.OpenRead(path);
    return Convert.ToHexStringLower(await SHA256.HashDataAsync(stream));
}

static string Sha256Text(string value) =>
    Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(value)));

internal sealed record PrivateProjection(
    int SchemaVersion,
    string ContractId,
    string StaticDataPackSha256,
    long StaticDataPackByteLength,
    ContentsOpenCondition SoloRaidViewConditionType,
    int SoloRaidViewConditionValue,
    string? SoloRaidViewStageLabel,
    PrivateOpenCondition[] SoloRaidOpenConditions,
    int CampaignMainStageCount,
    string CampaignMainStageCanonicalSha256,
    PrivateStage[] CampaignMainStages,
    int TutorialRecordCount,
    int TutorialGroupCount,
    string TutorialGroupCanonicalSha256,
    PrivateTutorialGroup[] TutorialGroups,
    ContentsOpen ExcludedMuseumContentsCode);

internal sealed record PrivateOpenCondition(
    ContentsOpenCondition Type,
    int Value,
    string? StageLabel);

internal sealed record PrivateStage(
    int StageId,
    ChapterMod Mod,
    int Chapter,
    int Ordinal,
    string MapId,
    int ParentStageId,
    int ChildStageId);

internal sealed record PrivateTutorialGroup(
    int GroupId,
    int TerminalTutorialId,
    int VersionGroup,
    int MemberCount,
    ContentsTutorialSubGroup[] SubGroups,
    ContentsTutorialTriggerValue[] Triggers,
    ContentsTutorialTriggerValue[] CloseTriggers,
    int[] ClearedStageIds,
    int[] CloseStageIds,
    int SaveTutorialCount,
    int SkipControlledCount);

internal sealed record ObservedProgress(int Normal, int Hard, int Story);
