using System.Globalization;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using EpinelPS.Data;
using EpinelPS.Database;
using EpinelPS.Models;
using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;
using NewtonsoftJson = Newtonsoft.Json.JsonConvert;

const string SourceContract =
    "nll/phase3b2-user-progression-private-source/v1";
const string ProjectionContract =
    "nll/phase3b2-user-progression-private-static-projection/v2";
const string CandidateSummaryContract =
    "nll/phase3b2-user-progression-candidate-summary/v2";
const string MigrationSummaryContract =
    "nll/phase3b2-user-progression-trigger-migration-proof/v1";
const string StaticIntegrityContract =
    "nll/phase3b2-user-progression-static-integrity/v1";
const string SqliteMaterializationContract =
    "nll/phase3b2-user-progression-sqlite-materialization/v1";
const string StrictDiffContract =
    "nll/phase3b2-user-progression-strict-diff/v1";

try
{
    if (args.Length == 5 && string.Equals(args[0], "build",
        StringComparison.Ordinal))
    {
        await BuildCandidateAsync(args[1], args[2], args[3], args[4]);
        Environment.Exit(0);
    }

    if (args.Length == 4 && string.Equals(args[0], "verify-migration",
        StringComparison.Ordinal))
    {
        await VerifyMigrationAsync(args[1], args[2], args[3]);
        Environment.Exit(0);
    }

    if (args.Length == 6 && string.Equals(args[0], "verify-static",
        StringComparison.Ordinal))
    {
        await VerifyStaticIntegrityAsync(args[1], args[2], args[3], args[4],
            args[5]);
        Environment.Exit(0);
    }

    if (args.Length == 2 && string.Equals(args[0], "materialize-sqlite",
        StringComparison.Ordinal))
    {
        await MaterializeSqliteAsync(args[1]);
        Environment.Exit(0);
    }

    if (args.Length == 7 && string.Equals(args[0], "compare-strict",
        StringComparison.Ordinal))
    {
        await CompareStrictAsync(args[1], args[2], args[3], args[4], args[5],
            args[6]);
        Environment.Exit(0);
    }

    throw new InvalidOperationException(
        "supported commands: build <static-pack> <private-source> " +
        "<golden-db> <output-directory>; verify-migration <private-source> " +
        "<candidate-db> <sqlite-output>; verify-static <static-pack> " +
        "<private-source> <golden-db> <candidate-db> <summary-output>; " +
        "materialize-sqlite <sqlite-output>; compare-strict " +
        "<private-source> <golden-db> <candidate-db> <golden-sqlite> " +
        "<candidate-sqlite> <summary-output>");
}
catch (Exception exception)
{
    Console.Error.WriteLine(exception.ToString());
    Environment.Exit(1);
}

static async Task BuildCandidateAsync(string packArgument, string sourceArgument,
    string goldenArgument, string outputArgument)
{
    var packPath = Path.GetFullPath(packArgument);
    var sourcePath = Path.GetFullPath(sourceArgument);
    var goldenPath = Path.GetFullPath(goldenArgument);
    var outputRoot = Path.GetFullPath(outputArgument);
    Require(File.Exists(packPath), "static_data_pack_missing");
    Require(File.Exists(sourcePath), "private_source_missing");
    Require(File.Exists(goldenPath), "golden_database_missing");
    Require(!Directory.Exists(outputRoot) && !File.Exists(outputRoot),
        "candidate_output_already_exists");

    var source = JsonSerializer.Deserialize<PrivateSource>(
        await File.ReadAllTextAsync(sourcePath), JsonOptions()) ??
        throw new InvalidDataException("private_source_json_invalid");
    ValidateSource(source);

    var gameData = await LoadGameDataAsync(packPath);
    var stages = ProjectStages(gameData);
    var mainStages = stages.Where(stage => stage.IsMain).ToArray();
    var tutorials = ProjectTutorials(gameData);
    var quests = gameData.QuestDataRecords.Values
        .OrderBy(row => row.Id)
        .Select(row => new PrivateQuest(row.Id,
            (row.ConditionId ?? []).Select(value => value.ConditionId)
                .Distinct().Order().ToArray()))
        .ToArray();
    var questIds = quests.Select(value => value.QuestId).ToArray();
    var questConditionIds = quests.SelectMany(value => value.ConditionIds)
        .ToHashSet();
    var contents = ProjectContents(gameData);

    var targets = new[]
    {
        ResolveTarget(mainStages, ChapterMod.Normal, source.LastStageIds.Normal),
        ResolveTarget(mainStages, ChapterMod.Hard, source.LastStageIds.Hard),
        ResolveTarget(mainStages, ChapterMod.Story, source.LastStageIds.Story)
    };
    var stageById = stages.ToDictionary(stage => stage.StageId);
    var campaignClearReferences = source.SelectedTriggers
        .Where(value => value.TypeCode == 2)
        .Select(value => value.ConditionId).ToHashSet();
    var completedStages = campaignClearReferences
        .Where(stageById.ContainsKey).ToHashSet();
    var nonStageCampaignReferences = campaignClearReferences
        .Where(value => !stageById.ContainsKey(value)).ToHashSet();
    var questConditionCampaignReferences = nonStageCampaignReferences
        .Where(questConditionIds.Contains).ToHashSet();
    var unresolvedCampaignReferences = nonStageCampaignReferences
        .Where(value => !questConditionIds.Contains(value)).ToHashSet();
    var triggerStageRecords = completedStages.Select(value => stageById[value])
        .OrderBy(stage => stage.Mod)
        .ThenBy(stage => stage.SourceChapterId)
        .ThenBy(stage => stage.StageId)
        .ToArray();
    var profileMainClosure = targets.SelectMany(target => mainStages
            .Where(stage => stage.Mod == target.Mod &&
                (stage.Chapter < target.Chapter ||
                 stage.Chapter == target.Chapter &&
                 stage.Ordinal <= target.Ordinal)))
        .ToArray();
    Require(targets.All(target => profileMainClosure.Any(stage =>
            stage.StageId == target.StageId)),
        "profile_main_stage_closure_invalid");
    var projectedStageRecords = triggerStageRecords.Concat(profileMainClosure)
        .GroupBy(stage => stage.StageId)
        .Select(group => group.First())
        .OrderBy(stage => stage.Mod)
        .ThenBy(stage => stage.SourceChapterId)
        .ThenBy(stage => stage.StageId)
        .ToArray();
    ValidateTriggerClosure(source, triggerStageRecords, questIds);

    var completedScenarios = projectedStageRecords
        .SelectMany(stage => new[] { stage.EnterScenario, stage.ExitScenario })
        .Where(value => !string.IsNullOrWhiteSpace(value))
        .Select(value => value!)
        .Distinct(StringComparer.Ordinal)
        .Order(StringComparer.Ordinal)
        .ToArray();

    var database = JsonNode.Parse(await File.ReadAllTextAsync(goldenPath)) as
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
        CountObject(user, "FieldInfoNew") == 0 &&
        CountObject(user, "ClearedTutorialDataNew") == 0 &&
        CountArray(user, "CompletedScenarios") == 0 &&
        CountObject(user, "MainQuestData") == 0 &&
        CountObject(user, "ContentsOpenUnlocked") == 0 &&
        CountArray(user, "StageClearHistorys") == 0 &&
        CountArray(user, "Triggers") == 0,
        "golden_database_progression_baseline_invalid");

    var unaffectedBefore = UnaffectedCanonicalSha256(database);
    user["LastNormalStageCleared"] = source.LastStageIds.Normal;
    user["LastHardStageCleared"] = source.LastStageIds.Hard;
    user["LastStoryStageCleared"] = source.LastStageIds.Story;
    user["FieldInfoNew"] = BuildFieldProjection(projectedStageRecords);
    user["ClearedTutorialDataNew"] = BuildTutorialProjection(tutorials);
    user["CompletedScenarios"] = new JsonArray(completedScenarios
        .Select(value => (JsonNode?)JsonValue.Create(value)).ToArray());
    user["MainQuestData"] = BuildMainQuestProjection(source.MainQuestData);

    var userLevel = user["userPointData"]?["UserLevel"]?.GetValue<int>() ?? 1;
    var projectedStageIds = projectedStageRecords.Select(stage => stage.StageId)
        .ToHashSet();
    var unlockedContents = ResolveUnlockedContents(contents, projectedStageIds,
        source.MainQuestData.Select(value => value.QuestId).ToHashSet(), userLevel);
    user["ContentsOpenUnlocked"] = BuildContentsProjection(unlockedContents);
    user["Triggers"] = BuildTriggerProjection(source.SelectedTriggers);

    Require(CountArray(user, "StageClearHistorys") == 0,
        "stage_clear_history_fabricated");
    var unaffectedAfter = UnaffectedCanonicalSha256(database);
    Require(string.Equals(unaffectedBefore, unaffectedAfter,
        StringComparison.Ordinal), "unrelated_golden_database_state_changed");

    Directory.CreateDirectory(outputRoot);
    var projectionPath = Path.Combine(outputRoot,
        "private-static-projection.json");
    var candidatePath = Path.Combine(outputRoot, "candidate-db.json");
    var summaryPath = Path.Combine(outputRoot, "candidate.summary.json");

    var stageCanonical = string.Concat(stages.Select(stage =>
        string.Create(CultureInfo.InvariantCulture,
            $"{stage.StageId}\t{(int)stage.Mod}\t{stage.SourceChapterId}\t" +
            $"{stage.Chapter}\t{stage.Ordinal}\t{stage.MapId}\t" +
            $"{stage.GroupId}\t{stage.EnterScenario}\t{stage.ExitScenario}\t" +
            $"{stage.IsMain}\n")));
    var scenarioCanonical = string.Concat(completedScenarios.Select(value =>
        value + "\n"));
    var contentCanonical = string.Concat(contents.Select(value =>
        string.Create(CultureInfo.InvariantCulture,
            $"{value.Id}\t{value.ViewConditionType}\t" +
            $"{value.ViewConditionValue}\t" +
            $"{string.Join(',', value.OpenConditions.Select(condition =>
                $"{condition.Type}:{condition.Value}"))}\n")));
    var projection = new StaticProjection(
        2,
        ProjectionContract,
        await Sha256FileAsync(packPath),
        new FileInfo(packPath).Length,
        stages.Length,
        Sha256Text(stageCanonical),
        stages,
        tutorials.Length,
        tutorials,
        quests.Length,
        quests,
        contents.Length,
        Sha256Text(contentCanonical),
        contents,
        (int)ContentsOpen.SoloRaidMuseum);
    await WriteExclusiveJsonAsync(projectionPath, projection);
    await WriteExclusiveJsonAsync(candidatePath, database);

    var roundTrip = NewtonsoftJson.DeserializeObject<CoreInfo>(
        await File.ReadAllTextAsync(candidatePath)) ??
        throw new InvalidDataException("candidate_runtime_roundtrip_invalid");
    var runtimeUser = roundTrip.Users.Single();
#pragma warning disable 612
    Require(runtimeUser.LastNormalStageCleared == source.LastStageIds.Normal &&
        runtimeUser.LastHardStageCleared == source.LastStageIds.Hard &&
        runtimeUser.LastStoryStageCleared == source.LastStageIds.Story &&
        runtimeUser.FieldInfoNew.Values.Sum(field =>
            field.CompletedStages.Count) == projectedStageIds.Count &&
        runtimeUser.CompletedScenarios.Count == completedScenarios.Length &&
        runtimeUser.CompletedScenarios.Distinct(StringComparer.Ordinal).Count() ==
            completedScenarios.Length &&
        runtimeUser.MainQuestData.Count == source.MainQuestData.Length &&
        runtimeUser.MainQuestData.All(value => value.Value) &&
        runtimeUser.ContentsOpenUnlocked.Count == unlockedContents.Length &&
        runtimeUser.ContentsOpenUnlocked.All(value =>
            value.Value.ButtonAnimationPlayed &&
            value.Value.PopupAnimationPlayed) &&
        runtimeUser.ClearedTutorialDataNew.Count == tutorials.Length &&
        runtimeUser.StageClearHistorys.Count == 0 &&
        runtimeUser.Triggers.Count == source.SelectedTriggers.Length,
        "candidate_runtime_roundtrip_invalid");
#pragma warning restore 612

    var summary = new CandidateSummary(
        2,
        CandidateSummaryContract,
        await Sha256FileAsync(sourcePath),
        await Sha256FileAsync(goldenPath),
        await Sha256FileAsync(candidatePath),
        new FileInfo(candidatePath).Length,
        targets.Select(StageLabel).ToArray(),
        targets.Count(target => !completedStages.Contains(target.StageId)),
        projectedStageRecords.GroupBy(value => value.Mod)
            .OrderBy(value => value.Key).ToDictionary(
            value => value.Key.ToString(), value => value.Count(),
            StringComparer.Ordinal),
        projectedStageRecords.Count(value => value.IsMain),
        nonStageCampaignReferences.Count,
        questConditionCampaignReferences.Count,
        unresolvedCampaignReferences.Count,
        ((JsonObject)user["FieldInfoNew"]!).Count,
        completedScenarios.Length,
        Sha256Text(scenarioCanonical),
        source.MainQuestData.Length,
        unlockedContents.Length,
        unlockedContents.Contains((int)ContentsOpen.SoloRaid),
        !unlockedContents.Contains((int)ContentsOpen.SoloRaidMuseum),
        tutorials.Length,
        source.SelectedTriggers.Length,
        TriggerCanonicalSha256(source.SelectedTriggers),
        0,
        true,
        unaffectedBefore,
        false,
        false,
        false,
        false,
        false);
    await WriteExclusiveJsonAsync(summaryPath, summary);
    Console.WriteLine(JsonSerializer.Serialize(summary, JsonOptions()));
}

static async Task VerifyMigrationAsync(string sourceArgument,
    string candidateArgument, string sqliteArgument)
{
    var sourcePath = Path.GetFullPath(sourceArgument);
    var candidatePath = Path.GetFullPath(candidateArgument);
    var sqlitePath = Path.GetFullPath(sqliteArgument);
    Require(File.Exists(sourcePath) && File.Exists(candidatePath),
        "migration_proof_input_missing");
    Require(!File.Exists(sqlitePath), "migration_proof_sqlite_already_exists");
    var candidateSha256Before = await Sha256FileAsync(candidatePath);
    var adjacentDb = Path.Combine(AppDomain.CurrentDomain.BaseDirectory,
        "db.json");
    Require(File.Exists(adjacentDb) &&
        string.Equals(await Sha256FileAsync(adjacentDb),
            candidateSha256Before, StringComparison.Ordinal),
        "migration_proof_adjacent_candidate_invalid");

    var source = JsonSerializer.Deserialize<PrivateSource>(
        await File.ReadAllTextAsync(sourcePath), JsonOptions()) ??
        throw new InvalidDataException("migration_source_json_invalid");
    ValidateSource(source);
    SQLitePCL.Batteries_V2.Init();
    var options = new DbContextOptionsBuilder<GameContext>()
        .UseSqlite($"Data Source={sqlitePath}")
        .Options;
    var priorOut = Console.Out;
    try
    {
        Console.SetOut(TextWriter.Null);
        await using var context = new GameContext(options);
        DbInitializer.Initialize(context);
    }
    finally
    {
        Console.SetOut(priorOut);
    }

    GameUser[] users;
    TriggerModelNew[] triggers;
    await using (var verifyContext = new GameContext(options))
    {
        users = await verifyContext.Users.AsNoTracking().ToArrayAsync();
        triggers = await verifyContext.Triggers.AsNoTracking()
            .OrderBy(value => value.Id).ToArrayAsync();
    }
    Require(users.Length == 1 &&
        triggers.Length == source.SelectedTriggers.Length &&
        triggers.Select(value => value.UserId).Distinct().Single() == users[0].ID &&
        triggers.Select((value, index) => value.Id == index + 1).All(value => value),
        "migration_proof_relational_shape_invalid");
    var migratedCanonical = string.Concat(triggers.Select(value =>
        string.Create(CultureInfo.InvariantCulture,
            $"{(int)value.Type}\t{value.ConditionId}\t{value.Value}\t" +
            $"{value.CreatedAt}\n")));
    var sourceCanonicalSha256 = TriggerCanonicalSha256(source.SelectedTriggers);
    Require(string.Equals(Sha256Text(migratedCanonical),
        sourceCanonicalSha256, StringComparison.Ordinal),
        "migration_proof_trigger_digest_invalid");

    string? integrity;
    await using (var connection = new SqliteConnection(
        $"Data Source={sqlitePath}"))
    {
        await connection.OpenAsync();
        await using var command = connection.CreateCommand();
        command.CommandText = "PRAGMA integrity_check;";
        integrity = (string?)await command.ExecuteScalarAsync();
    }
    Require(string.Equals(integrity, "ok", StringComparison.OrdinalIgnoreCase),
        "migration_proof_sqlite_integrity_invalid");
    SqliteConnection.ClearAllPools();

    var migratedDb = NewtonsoftJson.DeserializeObject<CoreInfo>(
        await File.ReadAllTextAsync(adjacentDb)) ??
        throw new InvalidDataException("migration_proof_json_roundtrip_invalid");
#pragma warning disable 612
    Require(migratedDb.Users.Count == 1 &&
        migratedDb.Users[0].Triggers.Count == source.SelectedTriggers.Length,
        "migration_proof_json_roundtrip_invalid");
#pragma warning restore 612

    var summary = new MigrationSummary(
        1,
        MigrationSummaryContract,
        await Sha256FileAsync(sourcePath),
        candidateSha256Before,
        new FileInfo(sqlitePath).Length,
        await Sha256FileAsync(sqlitePath),
        users.Length,
        triggers.Length,
        sourceCanonicalSha256,
        Sha256Text(migratedCanonical),
        integrity!,
        true,
        true,
        false,
        false,
        false);
    Console.WriteLine(JsonSerializer.Serialize(summary, JsonOptions()));
}

static async Task VerifyStaticIntegrityAsync(string packArgument,
    string sourceArgument, string goldenArgument, string candidateArgument,
    string summaryArgument)
{
    var packPath = Path.GetFullPath(packArgument);
    var sourcePath = Path.GetFullPath(sourceArgument);
    var goldenPath = Path.GetFullPath(goldenArgument);
    var candidatePath = Path.GetFullPath(candidateArgument);
    var summaryPath = Path.GetFullPath(summaryArgument);
    Require(new[] { packPath, sourcePath, goldenPath, candidatePath }
        .All(File.Exists), "static_integrity_input_missing");
    Require(!File.Exists(summaryPath),
        "static_integrity_summary_already_exists");

    var source = JsonSerializer.Deserialize<PrivateSource>(
        await File.ReadAllTextAsync(sourcePath), JsonOptions()) ??
        throw new InvalidDataException("static_integrity_source_invalid");
    ValidateSource(source);
    var gameData = await LoadGameDataAsync(packPath);
    var stages = ProjectStages(gameData);
    var stageById = stages.ToDictionary(value => value.StageId);
    var exactQuestIds = gameData.QuestDataRecords.Keys.ToHashSet();
    var exactContentIds = gameData.ContentsOpenTable.Keys
        .Select(value => (int)value).ToHashSet();
    var albumScenarioIds = gameData.albumResourceRecords.Values
        .Select(value => NullIfWhiteSpace(value.ScenarioGroupId))
        .Where(value => value is not null)
        .Select(value => value!)
        .ToHashSet(StringComparer.Ordinal);

    var golden = ParseRootObject(goldenPath, "static_integrity_golden");
    var candidate = ParseRootObject(candidatePath,
        "static_integrity_candidate");
    var goldenUser = GetSingleUser(golden, "static_integrity_golden");
    var candidateUser = GetSingleUser(candidate,
        "static_integrity_candidate");
    var allowedChanges = AllowedProgressionProperties();
    var changedProperties = GetChangedUserProperties(golden, candidate);
    Require(changedProperties.SetEquals(allowedChanges),
        "static_integrity_json_change_boundary_invalid");
    Require(string.Equals(UnaffectedCanonicalSha256(golden),
            UnaffectedCanonicalSha256(candidate), StringComparison.Ordinal),
        "static_integrity_unrelated_json_state_changed");

    var completedStageIds = new HashSet<int>();
    var fieldInfo = candidateUser["FieldInfoNew"] as JsonObject ??
        throw new InvalidDataException("static_integrity_field_info_invalid");
    foreach (var field in fieldInfo)
    {
        var fieldValue = field.Value as JsonObject ??
            throw new InvalidDataException("static_integrity_field_invalid");
        var completed = fieldValue["CompletedStages"] as JsonArray ??
            throw new InvalidDataException(
                "static_integrity_completed_stages_invalid");
        foreach (var node in completed)
        {
            var stageId = node?.GetValue<int>() ??
                throw new InvalidDataException(
                    "static_integrity_stage_id_invalid");
            Require(completedStageIds.Add(stageId) &&
                    stageById.TryGetValue(stageId, out var exactStage) &&
                    string.Equals(exactStage.MapId, field.Key,
                        StringComparison.Ordinal),
                "static_integrity_stage_reference_invalid");
        }
    }
    Require(completedStageIds.Count > 0,
        "static_integrity_stage_reference_empty");

    foreach (var property in new[]
    {
        (Name: "LastNormalStageCleared", Mod: ChapterMod.Normal),
        (Name: "LastHardStageCleared", Mod: ChapterMod.Hard),
        (Name: "LastStoryStageCleared", Mod: ChapterMod.Story)
    })
    {
        var stageId = ScalarInt(candidateUser, property.Name);
        Require(completedStageIds.Contains(stageId) &&
                stageById.TryGetValue(stageId, out var exactStage) &&
                exactStage.Mod == property.Mod,
            "static_integrity_last_stage_reference_invalid");
    }

    var expectedScenarios = completedStageIds.Select(value => stageById[value])
        .SelectMany(value => new[] { value.EnterScenario, value.ExitScenario })
        .Where(value => value is not null)
        .Select(value => value!)
        .ToHashSet(StringComparer.Ordinal);
    var actualScenarios = (candidateUser["CompletedScenarios"] as JsonArray ??
            throw new InvalidDataException(
                "static_integrity_completed_scenarios_invalid"))
        .Select(value => value?.GetValue<string>() ?? string.Empty)
        .ToArray();
    Require(actualScenarios.Length == actualScenarios.Distinct(
            StringComparer.Ordinal).Count(),
        "static_integrity_scenario_duplicate_invalid");
    Require(expectedScenarios.SetEquals(actualScenarios),
        "static_integrity_scenario_stage_index_mismatch");
    var albumCrossReferencedScenarios = expectedScenarios
        .Where(albumScenarioIds.Contains).Order(StringComparer.Ordinal).ToArray();
    var albumUnindexedScenarios = expectedScenarios
        .Where(value => !albumScenarioIds.Contains(value))
        .Order(StringComparer.Ordinal).ToArray();
    var albumUnindexedCanonical = string.Concat(albumUnindexedScenarios
        .Select(value => value + "\n"));

    var questObject = candidateUser["MainQuestData"] as JsonObject ??
        throw new InvalidDataException("static_integrity_main_quest_invalid");
    var candidateQuestIds = new HashSet<int>();
    foreach (var item in questObject)
    {
        Require(int.TryParse(item.Key, NumberStyles.None,
                    CultureInfo.InvariantCulture, out var questId) &&
                item.Value?.GetValue<bool>() == true &&
                exactQuestIds.Contains(questId) &&
                candidateQuestIds.Add(questId),
            "static_integrity_main_quest_reference_invalid");
    }
    Require(candidateQuestIds.SetEquals(source.MainQuestData.Select(
            value => value.QuestId)),
        "static_integrity_main_quest_source_mismatch");

    var contentObject = candidateUser["ContentsOpenUnlocked"] as JsonObject ??
        throw new InvalidDataException("static_integrity_contents_invalid");
    var baselineContentIds = new HashSet<int>([2, 3, 4, 6, 15, 16, 18, 19]);
    var candidateContentIds = new HashSet<int>();
    foreach (var item in contentObject)
    {
        Require(int.TryParse(item.Key, NumberStyles.None,
                    CultureInfo.InvariantCulture, out var contentId) &&
                (exactContentIds.Contains(contentId) ||
                    baselineContentIds.Contains(contentId)) &&
                candidateContentIds.Add(contentId),
            "static_integrity_content_reference_invalid");
        var state = item.Value as JsonObject ??
            throw new InvalidDataException(
                "static_integrity_content_state_invalid");
        Require(state["ButtonAnimationPlayed"]?.GetValue<bool>() == true &&
                state["PopupAnimationPlayed"]?.GetValue<bool>() == true,
            "static_integrity_content_state_invalid");
    }
    Require(candidateContentIds.Contains((int)ContentsOpen.SoloRaid) &&
            !candidateContentIds.Contains((int)ContentsOpen.SoloRaidMuseum),
        "static_integrity_solo_raid_boundary_invalid");

    var triggerArray = candidateUser["Triggers"] as JsonArray ??
        throw new InvalidDataException("static_integrity_triggers_invalid");
    Require(triggerArray.Count == source.SelectedTriggers.Length,
        "static_integrity_trigger_count_invalid");
    var triggerCanonical = new StringBuilder();
    for (var index = 0; index < triggerArray.Count; index++)
    {
        var trigger = triggerArray[index] as JsonObject ??
            throw new InvalidDataException("static_integrity_trigger_invalid");
        var expected = source.SelectedTriggers[index];
        Require(ScalarInt(trigger, "Id") == expected.LocalOrder &&
                ScalarInt(trigger, "Type") == expected.TypeCode &&
                ScalarInt(trigger, "ConditionId") == expected.ConditionId &&
                ScalarInt(trigger, "Value") == expected.UserValue &&
                trigger["CreatedAt"]?.GetValue<long>() == expected.CreatedAt,
            "static_integrity_trigger_source_mismatch");
        triggerCanonical.Append(CultureInfo.InvariantCulture,
            $"{expected.TypeCode}\t{expected.ConditionId}\t" +
            $"{expected.UserValue}\t{expected.CreatedAt}\n");
    }

    var unresolvedCampaign = source.SelectedTriggers
        .Where(value => value.TypeCode == 2 &&
            !stageById.ContainsKey(value.ConditionId) &&
            !gameData.QuestDataRecords.Values.Any(quest =>
                (quest.ConditionId ?? []).Any(condition =>
                    condition.ConditionId == value.ConditionId)))
        .Select(value => value.ConditionId).Distinct().Order().ToArray();
    var unresolvedCanonical = string.Concat(unresolvedCampaign.Select(value =>
        value.ToString(CultureInfo.InvariantCulture) + "\n"));
    Require(CountArray(candidateUser, "StageClearHistorys") == 0,
        "static_integrity_stage_history_fabricated");

    var summary = new StaticIntegritySummary(
        1,
        StaticIntegrityContract,
        await Sha256FileAsync(packPath),
        await Sha256FileAsync(sourcePath),
        await Sha256FileAsync(goldenPath),
        await Sha256FileAsync(candidatePath),
        completedStageIds.Count,
        fieldInfo.Count,
        true,
        expectedScenarios.Count,
        albumScenarioIds.Count,
        albumCrossReferencedScenarios.Length,
        albumUnindexedScenarios.Length,
        Sha256Text(albumUnindexedCanonical),
        true,
        candidateQuestIds.Count,
        true,
        candidateContentIds.Count,
        true,
        source.SelectedTriggers.Length,
        Sha256Text(triggerCanonical.ToString()),
        unresolvedCampaign.Length,
        Sha256Text(unresolvedCanonical),
        changedProperties.Order(StringComparer.Ordinal).ToArray(),
        true,
        0,
        false,
        false,
        false);
    await WriteExclusiveJsonAsync(summaryPath, summary);
    Console.WriteLine(JsonSerializer.Serialize(summary, JsonOptions()));
}

static async Task MaterializeSqliteAsync(string sqliteArgument)
{
    var sqlitePath = Path.GetFullPath(sqliteArgument);
    var adjacentDb = Path.Combine(AppDomain.CurrentDomain.BaseDirectory,
        "db.json");
    Require(File.Exists(adjacentDb), "sqlite_materialization_db_missing");
    Require(!File.Exists(sqlitePath),
        "sqlite_materialization_output_already_exists");
    var sourceDatabaseSha256 = await Sha256FileAsync(adjacentDb);
    SQLitePCL.Batteries_V2.Init();
    var options = new DbContextOptionsBuilder<GameContext>()
        .UseSqlite($"Data Source={sqlitePath}")
        .Options;
    var priorOut = Console.Out;
    try
    {
        Console.SetOut(TextWriter.Null);
        await using var context = new GameContext(options);
        DbInitializer.Initialize(context);
    }
    finally
    {
        Console.SetOut(priorOut);
    }
    SqliteConnection.ClearAllPools();
    var snapshot = await ReadDatabaseSnapshotAsync(sqlitePath);
    var summary = new SqliteMaterializationSummary(
        1,
        SqliteMaterializationContract,
        sourceDatabaseSha256,
        await Sha256FileAsync(adjacentDb),
        !string.Equals(sourceDatabaseSha256,
            await Sha256FileAsync(adjacentDb), StringComparison.Ordinal),
        new FileInfo(sqlitePath).Length,
        await Sha256FileAsync(sqlitePath),
        snapshot.Tables.Length,
        snapshot.Tables.Single(value => value.Name == "Users").RowCount,
        snapshot.Tables.Single(value => value.Name == "SdkUsers").RowCount,
        snapshot.Tables.Single(value => value.Name == "Triggers").RowCount,
        snapshot.IntegrityCode,
        snapshot.ForeignKeyViolationCount,
        true,
        false,
        false);
    Console.WriteLine(JsonSerializer.Serialize(summary, JsonOptions()));
}

static async Task CompareStrictAsync(string sourceArgument,
    string goldenArgument, string candidateArgument, string goldenSqliteArgument,
    string candidateSqliteArgument, string summaryArgument)
{
    var sourcePath = Path.GetFullPath(sourceArgument);
    var goldenPath = Path.GetFullPath(goldenArgument);
    var candidatePath = Path.GetFullPath(candidateArgument);
    var goldenSqlitePath = Path.GetFullPath(goldenSqliteArgument);
    var candidateSqlitePath = Path.GetFullPath(candidateSqliteArgument);
    var summaryPath = Path.GetFullPath(summaryArgument);
    Require(new[] { sourcePath, goldenPath, candidatePath, goldenSqlitePath,
            candidateSqlitePath }.All(File.Exists),
        "strict_diff_input_missing");
    Require(!File.Exists(summaryPath), "strict_diff_summary_already_exists");
    var source = JsonSerializer.Deserialize<PrivateSource>(
        await File.ReadAllTextAsync(sourcePath), JsonOptions()) ??
        throw new InvalidDataException("strict_diff_source_invalid");
    ValidateSource(source);
    var golden = ParseRootObject(goldenPath, "strict_diff_golden");
    var candidate = ParseRootObject(candidatePath, "strict_diff_candidate");
    var changedProperties = GetChangedUserProperties(golden, candidate);
    Require(changedProperties.SetEquals(AllowedProgressionProperties()) &&
            string.Equals(UnaffectedCanonicalSha256(golden),
                UnaffectedCanonicalSha256(candidate), StringComparison.Ordinal),
        "strict_diff_json_boundary_invalid");

    var goldenSnapshot = await ReadDatabaseSnapshotAsync(goldenSqlitePath);
    var candidateSnapshot = await ReadDatabaseSnapshotAsync(candidateSqlitePath);
    Require(goldenSnapshot.IntegrityCode == "ok" &&
            candidateSnapshot.IntegrityCode == "ok" &&
            goldenSnapshot.ForeignKeyViolationCount == 0 &&
            candidateSnapshot.ForeignKeyViolationCount == 0,
        "strict_diff_sqlite_integrity_invalid");
    var goldenTables = goldenSnapshot.Tables.ToDictionary(value => value.Name,
        StringComparer.Ordinal);
    var candidateTables = candidateSnapshot.Tables.ToDictionary(
        value => value.Name, StringComparer.Ordinal);
    Require(goldenTables.Keys.ToHashSet(StringComparer.Ordinal).SetEquals(
            candidateTables.Keys), "strict_diff_table_set_invalid");
    foreach (var name in goldenTables.Keys)
    {
        Require(string.Equals(goldenTables[name].SchemaSha256,
                candidateTables[name].SchemaSha256, StringComparison.Ordinal),
            "strict_diff_schema_changed");
        if (name is not "Triggers" and not "sqlite_sequence")
        {
            Require(goldenTables[name].RowCount ==
                    candidateTables[name].RowCount &&
                    string.Equals(goldenTables[name].RowCanonicalSha256,
                        candidateTables[name].RowCanonicalSha256,
                        StringComparison.Ordinal),
                "strict_diff_non_trigger_table_changed");
        }
    }

    var goldenTrigger = goldenTables["Triggers"];
    var candidateTrigger = candidateTables["Triggers"];
    Require(goldenTrigger.RowCount == 0 &&
            candidateTrigger.RowCount == source.SelectedTriggers.Length,
        "strict_diff_trigger_row_count_invalid");
    var migratedTriggerCanonical = await ReadTriggerCanonicalAsync(
        candidateSqlitePath);
    Require(string.Equals(Sha256Text(migratedTriggerCanonical),
            TriggerCanonicalSha256(source.SelectedTriggers),
            StringComparison.Ordinal), "strict_diff_trigger_rows_invalid");
    var goldenSequence = await ReadSequenceStateAsync(goldenSqlitePath);
    var candidateSequence = await ReadSequenceStateAsync(candidateSqlitePath);
    Require(goldenSequence.TriggerSequence is null &&
            candidateSequence.TriggerSequence == source.SelectedTriggers.Length &&
            string.Equals(goldenSequence.OtherCanonicalSha256,
                candidateSequence.OtherCanonicalSha256,
                StringComparison.Ordinal),
        "strict_diff_sqlite_sequence_invalid");

    var tableDiffs = goldenTables.Keys.Order(StringComparer.Ordinal)
        .Select(name => new StrictTableDiff(
            name,
            goldenTables[name].RowCount,
            candidateTables[name].RowCount,
            goldenTables[name].SchemaSha256,
            candidateTables[name].SchemaSha256,
            name == "Triggers" ? "allowed_trigger_rows_only" :
            name == "sqlite_sequence" ? "allowed_trigger_sequence_only" :
            "identical"))
        .ToArray();
    var summary = new StrictDiffSummary(
        1,
        StrictDiffContract,
        await Sha256FileAsync(sourcePath),
        await Sha256FileAsync(goldenPath),
        await Sha256FileAsync(candidatePath),
        await Sha256FileAsync(goldenSqlitePath),
        await Sha256FileAsync(candidateSqlitePath),
        changedProperties.Order(StringComparer.Ordinal).ToArray(),
        true,
        tableDiffs,
        tableDiffs.Length,
        tableDiffs.Count(value => value.VerdictCode == "identical"),
        candidateTrigger.RowCount,
        TriggerCanonicalSha256(source.SelectedTriggers),
        Sha256Text(migratedTriggerCanonical),
        goldenSnapshot.IntegrityCode,
        candidateSnapshot.IntegrityCode,
        0,
        true,
        false,
        false,
        false);
    await WriteExclusiveJsonAsync(summaryPath, summary);
    Console.WriteLine(JsonSerializer.Serialize(summary, JsonOptions()));
}

static async Task<GameData> LoadGameDataAsync(string packPath)
{
    var originalOut = Console.Out;
    try
    {
        Console.SetOut(TextWriter.Null);
        var gameData = new GameData(packPath);
        var instanceField = typeof(GameData).GetField("_instance",
            BindingFlags.Static | BindingFlags.NonPublic) ??
            throw new MissingFieldException(typeof(GameData).FullName,
                "_instance");
        instanceField.SetValue(null, gameData);
        await gameData.Parse();
        return gameData;
    }
    finally
    {
        Console.SetOut(originalOut);
    }
}

static PrivateStage[] ProjectStages(GameData gameData) =>
    gameData.StageDataRecords.Values
        .GroupBy(stage => (stage.ChapterMod, stage.ChapterId))
        .OrderBy(group => group.Key.ChapterMod)
        .ThenBy(group => group.Key.ChapterId)
        .SelectMany(group =>
        {
            var mainOrdinal = 0;
            return group.OrderBy(stage => stage.Id).Select(stage =>
            {
                var isMain = stage.StageType == StageType.Main;
                if (isMain) mainOrdinal++;
                return new PrivateStage(
                    stage.Id,
                    stage.ChapterMod,
                    stage.ChapterId,
                    stage.ChapterId - 1,
                    isMain ? mainOrdinal : 0,
                    ResolveMapId(gameData, stage.ChapterId, stage.ChapterMod),
                    stage.GroupId,
                    stage.ParentsId,
                    stage.StageChild,
                    NullIfWhiteSpace(stage.EnterScenario),
                    NullIfWhiteSpace(stage.ExitScenario),
                    isMain);
            }).ToArray();
        })
        .ToArray();

static PrivateTutorialGroup[] ProjectTutorials(GameData gameData) =>
    gameData.TutorialTable.Values
        .GroupBy(row => row.GroupId)
        .Select(group =>
        {
            var rows = group.OrderBy(row => row.Id).ToArray();
            return new PrivateTutorialGroup(group.Key, rows[^1].Id,
                rows[^1].VersionGroup, rows.Length);
        })
        .OrderBy(group => group.GroupId)
        .ToArray();

static PrivateContent[] ProjectContents(GameData gameData) =>
    gameData.ContentsOpenTable.Values
        .OrderBy(value => (int)value.Id)
        .Select(value => new PrivateContent(
            (int)value.Id,
            (int)value.ViewConditionType,
            value.ViewConditionValue,
            (value.OpenCondition ?? []).Select(condition =>
                new PrivateCondition((int)condition.OpenConditionType,
                    condition.OpenConditionValue)).ToArray()))
        .ToArray();

static void ValidateSource(PrivateSource source)
{
    Require(source.SchemaVersion == 1 &&
        string.Equals(source.ContractId, SourceContract,
            StringComparison.Ordinal) &&
        source.SelectedTriggers.Length > 0 &&
        source.MainQuestData.Length > 0 &&
        source.SourceSequencePersisted == false &&
        source.OfficialUserIdentifierPersisted == false &&
        source.CredentialOrSessionFieldPersisted == false,
        "private_source_contract_invalid");
    Require(source.SelectedTriggers.Select((value, index) =>
            value.LocalOrder == index + 1).All(value => value) &&
        source.SelectedTriggers.Select(value => value.LocalOrder)
            .Distinct().Count() == source.SelectedTriggers.Length,
        "private_source_local_order_invalid");
    var allowed = new Dictionary<int, string>
    {
        [2] = "CampaignClear",
        [3] = "ChapterClear",
        [22] = "MainQuestClear",
        [25] = "CampaignGroupClear",
        [35] = "HardChapterClear"
    };
    Require(source.SelectedTriggers.All(value =>
            allowed.TryGetValue(value.TypeCode, out var name) &&
            string.Equals(name, value.TypeName, StringComparison.Ordinal) &&
            value.ConditionId > 0 && value.UserValue > 0 &&
            value.CreatedAt > 0) &&
        source.MainQuestData.All(value =>
            value.QuestId > 0 && value.RewardClaimed) &&
        source.MainQuestData.Select(value => value.QuestId)
            .Distinct().Count() == source.MainQuestData.Length,
        "private_source_record_invalid");
}

static void ValidateTriggerClosure(PrivateSource source,
    PrivateStage[] completedStages, int[] exactQuestIds)
{
    var byType = source.SelectedTriggers.GroupBy(value => value.TypeCode)
        .ToDictionary(group => group.Key,
            group => group.Select(value => value.ConditionId).ToHashSet());
    Require(byType.Count == 5 && completedStages.All(stage =>
            byType[2].Contains(stage.StageId)),
        "campaign_clear_trigger_closure_invalid");
    var normalChapters = completedStages
        .Where(stage => stage.Mod == ChapterMod.Normal)
        .Select(stage => stage.SourceChapterId).ToHashSet();
    var hardChapters = completedStages
        .Where(stage => stage.Mod == ChapterMod.Hard)
        .Select(stage => stage.SourceChapterId).ToHashSet();
    Require(byType[3].SetEquals(normalChapters) &&
        byType[35].SetEquals(hardChapters),
        "chapter_clear_trigger_closure_invalid");
    var groups = completedStages
        .Select(stage => stage.GroupId).Where(value => value > 0).ToHashSet();
    Require(byType[25].SetEquals(groups),
        "campaign_group_trigger_closure_invalid");
    var sourceQuests = source.MainQuestData.Select(value => value.QuestId)
        .ToHashSet();
    Require(byType[22].SetEquals(sourceQuests) &&
        sourceQuests.IsSubsetOf(exactQuestIds),
        "main_quest_trigger_closure_invalid");
}

static JsonObject BuildFieldProjection(PrivateStage[] completedStages)
{
    var result = new JsonObject();
    foreach (var map in completedStages
        .GroupBy(stage => stage.MapId, StringComparer.Ordinal)
        .OrderBy(group => group.Key, StringComparer.Ordinal))
    {
        result.Add(map.Key, new JsonObject
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
    return result;
}

static JsonObject BuildTutorialProjection(PrivateTutorialGroup[] groups)
{
    var result = new JsonObject();
    foreach (var group in groups)
    {
        result.Add(group.GroupId.ToString(CultureInfo.InvariantCulture),
            new JsonObject
            {
                ["Id"] = group.TerminalTutorialId,
                ["VersionGroup"] = group.VersionGroup
            });
    }
    return result;
}

static JsonObject BuildMainQuestProjection(PrivateMainQuest[] quests)
{
    var result = new JsonObject();
    foreach (var quest in quests.OrderBy(value => value.QuestId))
    {
        result.Add(quest.QuestId.ToString(CultureInfo.InvariantCulture), true);
    }
    return result;
}

static JsonObject BuildContentsProjection(int[] contents)
{
    var result = new JsonObject();
    foreach (var value in contents.Order())
    {
        result.Add(value.ToString(CultureInfo.InvariantCulture), new JsonObject
        {
            ["ButtonAnimationPlayed"] = true,
            ["PopupAnimationPlayed"] = true
        });
    }
    return result;
}

static JsonArray BuildTriggerProjection(PrivateTrigger[] triggers) =>
    new(triggers.OrderBy(value => value.LocalOrder).Select(value =>
        (JsonNode?)new JsonObject
        {
            ["Type"] = value.TypeCode,
            ["Id"] = value.LocalOrder,
            ["CreatedAt"] = value.CreatedAt,
            ["ConditionId"] = value.ConditionId,
            ["Value"] = value.UserValue
        }).ToArray());

static int[] ResolveUnlockedContents(PrivateContent[] contents,
    HashSet<int> completedStages, HashSet<int> completedQuests, int userLevel)
{
    var result = new HashSet<int>([2, 3, 4, 6, 15, 16, 18, 19]);
    foreach (var content in contents)
    {
        if (content.Id is (int)ContentsOpen.None or
            (int)ContentsOpen.SoloRaidMuseum)
        {
            continue;
        }
        if (ConditionSatisfied(content.ViewConditionType,
                content.ViewConditionValue, completedStages, completedQuests,
                userLevel) && content.OpenConditions.All(condition =>
                ConditionSatisfied(condition.Type, condition.Value,
                    completedStages, completedQuests, userLevel)))
        {
            result.Add(content.Id);
        }
    }
    Require(result.Contains((int)ContentsOpen.SoloRaid),
        "solo_raid_unlock_condition_not_satisfied");
    result.Remove((int)ContentsOpen.SoloRaidMuseum);
    return result.Order().ToArray();
}

static bool ConditionSatisfied(int type, int value,
    HashSet<int> completedStages, HashSet<int> completedQuests, int userLevel) =>
    (ContentsOpenCondition)type switch
    {
        ContentsOpenCondition.None => true,
        ContentsOpenCondition.UserLevel => userLevel >= value,
        ContentsOpenCondition.StageClear => completedStages.Contains(value),
        ContentsOpenCondition.MainQuest => completedQuests.Contains(value),
        _ => false
    };

static PrivateStage ResolveTarget(PrivateStage[] stages, ChapterMod mod,
    int stageId)
{
    var matches = stages.Where(stage => stage.Mod == mod &&
        stage.StageId == stageId).ToArray();
    Require(matches.Length == 1,
        $"{mod}_user_progress_not_in_exact_static_data");
    return matches[0];
}

static string ResolveMapId(GameData gameData, int chapterId, ChapterMod mod)
{
    var values = gameData.ChapterCampaignData.Values
        .Where(chapter => chapter.Chapter + 1 == chapterId)
        .Select(chapter => mod switch
        {
            ChapterMod.Normal => chapter.FieldId,
            ChapterMod.Hard => chapter.HardFieldId,
            ChapterMod.Story => chapter.StoryFieldId,
            _ => null
        })
        .Where(value => !string.IsNullOrWhiteSpace(value))
        .Distinct(StringComparer.Ordinal).ToArray();
    Require(values.Length == 1,
        $"campaign_map_resolution_invalid_{mod}_{chapterId}");
    return values[0]!;
}

static string StageLabel(PrivateStage stage) =>
    string.Create(CultureInfo.InvariantCulture,
        $"{stage.Chapter}-{stage.Ordinal}");

static string? NullIfWhiteSpace(string? value) =>
    string.IsNullOrWhiteSpace(value) ? null : value;

static int ScalarInt(JsonObject value, string property) =>
    value[property]?.GetValue<int>() ??
    throw new InvalidDataException($"database_{property}_invalid");

static int CountObject(JsonObject value, string property) =>
    (value[property] as JsonObject)?.Count ??
    throw new InvalidDataException($"database_{property}_invalid");

static int CountArray(JsonObject value, string property) =>
    (value[property] as JsonArray)?.Count ??
    throw new InvalidDataException($"database_{property}_invalid");

static string UnaffectedCanonicalSha256(JsonObject database)
{
    var clone = database.DeepClone() as JsonObject ??
        throw new InvalidDataException("database_clone_invalid");
    var user = (clone["Users"] as JsonArray)?[0] as JsonObject ??
        throw new InvalidDataException("database_clone_user_invalid");
    foreach (var property in new[]
    {
        "LastNormalStageCleared", "LastHardStageCleared",
        "LastStoryStageCleared", "FieldInfoNew",
        "ClearedTutorialDataNew", "CompletedScenarios", "MainQuestData",
        "ContentsOpenUnlocked", "Triggers"
    })
    {
        Require(user.Remove(property), $"database_clone_{property}_missing");
    }
    return Sha256Text(clone.ToJsonString(new JsonSerializerOptions
    {
        WriteIndented = false
    }));
}

static string TriggerCanonicalSha256(IEnumerable<PrivateTrigger> triggers) =>
    Sha256Text(string.Concat(triggers.OrderBy(value => value.LocalOrder)
        .Select(value => string.Create(CultureInfo.InvariantCulture,
            $"{value.TypeCode}\t{value.ConditionId}\t{value.UserValue}\t" +
            $"{value.CreatedAt}\n"))));

static JsonObject ParseRootObject(string path, string code) =>
    JsonNode.Parse(File.ReadAllText(path)) as JsonObject ??
    throw new InvalidDataException(code + "_root_invalid");

static JsonObject GetSingleUser(JsonObject database, string code)
{
    var users = database["Users"] as JsonArray ??
        throw new InvalidDataException(code + "_users_invalid");
    Require(users.Count == 1 && users[0] is JsonObject,
        code + "_user_shape_invalid");
    return (JsonObject)users[0]!;
}

static HashSet<string> AllowedProgressionProperties() => new(
    [
        "LastNormalStageCleared", "LastHardStageCleared",
        "LastStoryStageCleared", "FieldInfoNew",
        "ClearedTutorialDataNew", "CompletedScenarios", "MainQuestData",
        "ContentsOpenUnlocked", "Triggers"
    ], StringComparer.Ordinal);

static HashSet<string> GetChangedUserProperties(JsonObject golden,
    JsonObject candidate)
{
    Require(golden.Select(value => value.Key).ToHashSet(StringComparer.Ordinal)
            .SetEquals(candidate.Select(value => value.Key)),
        "database_root_property_set_changed");
    foreach (var property in golden.Where(value => value.Key != "Users"))
    {
        Require(JsonNode.DeepEquals(property.Value, candidate[property.Key]),
            "database_non_user_root_state_changed");
    }
    var goldenUser = GetSingleUser(golden, "database_golden");
    var candidateUser = GetSingleUser(candidate, "database_candidate");
    Require(goldenUser.Select(value => value.Key)
            .ToHashSet(StringComparer.Ordinal)
            .SetEquals(candidateUser.Select(value => value.Key)),
        "database_user_property_set_changed");
    return goldenUser.Where(property => !JsonNode.DeepEquals(property.Value,
            candidateUser[property.Key]))
        .Select(property => property.Key).ToHashSet(StringComparer.Ordinal);
}

static async Task<DatabaseSnapshot> ReadDatabaseSnapshotAsync(string path)
{
    var builder = new SqliteConnectionStringBuilder
    {
        DataSource = path,
        Mode = SqliteOpenMode.ReadOnly
    };
    await using var connection = new SqliteConnection(builder.ToString());
    await connection.OpenAsync();
    string integrity;
    await using (var command = connection.CreateCommand())
    {
        command.CommandText = "PRAGMA integrity_check;";
        integrity = (string?)await command.ExecuteScalarAsync() ?? string.Empty;
    }
    var foreignKeyViolationCount = 0;
    await using (var command = connection.CreateCommand())
    {
        command.CommandText = "PRAGMA foreign_key_check;";
        await using var reader = await command.ExecuteReaderAsync();
        while (await reader.ReadAsync()) foreignKeyViolationCount++;
    }
    var schemas = new List<(string Name, string Sql)>();
    await using (var command = connection.CreateCommand())
    {
        command.CommandText = "SELECT name, coalesce(sql, '') FROM " +
            "sqlite_master WHERE type = 'table' ORDER BY name;";
        await using var reader = await command.ExecuteReaderAsync();
        while (await reader.ReadAsync())
        {
            schemas.Add((reader.GetString(0), reader.GetString(1)));
        }
    }
    var tables = new List<TableSnapshot>();
    foreach (var schema in schemas)
    {
        tables.Add(await ReadTableSnapshotAsync(connection, schema.Name,
            schema.Sql));
    }
    return new DatabaseSnapshot(integrity.ToLowerInvariant(),
        foreignKeyViolationCount, tables.ToArray());
}

static async Task<TableSnapshot> ReadTableSnapshotAsync(
    SqliteConnection connection, string tableName, string schemaSql)
{
    var columns = new List<(string Name, int PrimaryKeyOrder)>();
    await using (var command = connection.CreateCommand())
    {
        command.CommandText = $"PRAGMA table_info({QuoteIdentifier(tableName)});";
        await using var reader = await command.ExecuteReaderAsync();
        while (await reader.ReadAsync())
        {
            columns.Add((reader.GetString(1), reader.GetInt32(5)));
        }
    }
    Require(columns.Count > 0, "sqlite_table_has_no_columns");
    var orderColumns = columns.Where(value => value.PrimaryKeyOrder > 0)
        .OrderBy(value => value.PrimaryKeyOrder).Select(value => value.Name)
        .ToArray();
    if (orderColumns.Length == 0)
    {
        orderColumns = columns.Select(value => value.Name).ToArray();
    }
    var selectColumns = string.Join(", ", columns.Select(value =>
        QuoteIdentifier(value.Name)));
    var orderBy = string.Join(", ", orderColumns.Select(QuoteIdentifier));
    var canonical = new StringBuilder();
    long rowCount = 0;
    await using (var command = connection.CreateCommand())
    {
        command.CommandText = $"SELECT {selectColumns} FROM " +
            $"{QuoteIdentifier(tableName)} ORDER BY {orderBy};";
        await using var reader = await command.ExecuteReaderAsync();
        while (await reader.ReadAsync())
        {
            for (var index = 0; index < reader.FieldCount; index++)
            {
                AppendSqlValue(canonical, reader.GetValue(index));
                canonical.Append('\t');
            }
            canonical.Append('\n');
            rowCount++;
        }
    }
    return new TableSnapshot(tableName, rowCount, Sha256Text(schemaSql + "\n"),
        Sha256Text(canonical.ToString()));
}

static async Task<string> ReadTriggerCanonicalAsync(string sqlitePath)
{
    var builder = new SqliteConnectionStringBuilder
    {
        DataSource = sqlitePath,
        Mode = SqliteOpenMode.ReadOnly
    };
    await using var connection = new SqliteConnection(builder.ToString());
    await connection.OpenAsync();
    await using var command = connection.CreateCommand();
    command.CommandText = "SELECT Type, ConditionId, Value, CreatedAt " +
        "FROM Triggers ORDER BY Id;";
    await using var reader = await command.ExecuteReaderAsync();
    var canonical = new StringBuilder();
    while (await reader.ReadAsync())
    {
        canonical.Append(CultureInfo.InvariantCulture,
            $"{reader.GetInt32(0)}\t{reader.GetInt32(1)}\t" +
            $"{reader.GetInt32(2)}\t{reader.GetInt64(3)}\n");
    }
    return canonical.ToString();
}

static async Task<SequenceState> ReadSequenceStateAsync(string sqlitePath)
{
    var builder = new SqliteConnectionStringBuilder
    {
        DataSource = sqlitePath,
        Mode = SqliteOpenMode.ReadOnly
    };
    await using var connection = new SqliteConnection(builder.ToString());
    await connection.OpenAsync();
    await using var command = connection.CreateCommand();
    command.CommandText = "SELECT name, seq FROM sqlite_sequence " +
        "ORDER BY name;";
    await using var reader = await command.ExecuteReaderAsync();
    long? triggerSequence = null;
    var otherCanonical = new StringBuilder();
    while (await reader.ReadAsync())
    {
        var name = reader.GetString(0);
        var sequence = reader.GetInt64(1);
        if (string.Equals(name, "Triggers", StringComparison.Ordinal))
        {
            triggerSequence = sequence;
        }
        else
        {
            otherCanonical.Append(name).Append('\t')
                .Append(sequence.ToString(CultureInfo.InvariantCulture))
                .Append('\n');
        }
    }
    return new SequenceState(triggerSequence,
        Sha256Text(otherCanonical.ToString()));
}

static string QuoteIdentifier(string value) =>
    "\"" + value.Replace("\"", "\"\"", StringComparison.Ordinal) + "\"";

static void AppendSqlValue(StringBuilder builder, object value)
{
    switch (value)
    {
        case DBNull:
            builder.Append("N:");
            break;
        case byte[] bytes:
            builder.Append("B:").Append(Convert.ToBase64String(bytes));
            break;
        case long integer:
            builder.Append("I:").Append(integer.ToString(
                CultureInfo.InvariantCulture));
            break;
        case double real:
            builder.Append("R:").Append(real.ToString("R",
                CultureInfo.InvariantCulture));
            break;
        case string text:
            builder.Append("S:").Append(Convert.ToBase64String(
                Encoding.UTF8.GetBytes(text)));
            break;
        default:
            builder.Append("O:").Append(Convert.ToBase64String(
                Encoding.UTF8.GetBytes(Convert.ToString(value,
                    CultureInfo.InvariantCulture) ?? string.Empty)));
            break;
    }
}

static void Require(bool condition, string code)
{
    if (!condition) throw new InvalidDataException(code);
}

static JsonSerializerOptions JsonOptions() => new()
{
    PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    PropertyNameCaseInsensitive = true,
    WriteIndented = true
};

static async Task WriteExclusiveJsonAsync(string path, object value)
{
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

static string Sha256Text(string value) => Convert.ToHexStringLower(
    SHA256.HashData(Encoding.UTF8.GetBytes(value)));

internal sealed record PrivateSource(
    int SchemaVersion,
    string ContractId,
    string ExtractionUid,
    PrivateStageIds LastStageIds,
    PrivateTrigger[] SelectedTriggers,
    PrivateMainQuest[] MainQuestData,
    bool SourceSequencePersisted,
    bool OfficialUserIdentifierPersisted,
    bool CredentialOrSessionFieldPersisted);

internal sealed record PrivateStageIds(int Normal, int Hard, int Story);

internal sealed record PrivateTrigger(
    int LocalOrder,
    int TypeCode,
    string TypeName,
    int ConditionId,
    int UserValue,
    long CreatedAt);

internal sealed record PrivateMainQuest(int QuestId, bool RewardClaimed);

internal sealed record StaticProjection(
    int SchemaVersion,
    string ContractId,
    string StaticDataPackSha256,
    long StaticDataPackByteLength,
    int CampaignStageCount,
    string CampaignStageCanonicalSha256,
    PrivateStage[] CampaignStages,
    int TutorialGroupCount,
    PrivateTutorialGroup[] TutorialGroups,
    int MainQuestRecordCount,
    PrivateQuest[] MainQuestRecords,
    int ContentsOpenRecordCount,
    string ContentsOpenCanonicalSha256,
    PrivateContent[] ContentsOpenRecords,
    int ExcludedMuseumContentsCode);

internal sealed record PrivateStage(
    int StageId,
    ChapterMod Mod,
    int SourceChapterId,
    int Chapter,
    int Ordinal,
    string MapId,
    int GroupId,
    int ParentStageId,
    int ChildStageId,
    string? EnterScenario,
    string? ExitScenario,
    bool IsMain);

internal sealed record PrivateTutorialGroup(
    int GroupId,
    int TerminalTutorialId,
    int VersionGroup,
    int MemberCount);

internal sealed record PrivateQuest(int QuestId, int[] ConditionIds);

internal sealed record PrivateContent(
    int Id,
    int ViewConditionType,
    int ViewConditionValue,
    PrivateCondition[] OpenConditions);

internal sealed record PrivateCondition(int Type, int Value);

internal sealed record CandidateSummary(
    int SchemaVersion,
    string ContractId,
    string PrivateSourceSha256,
    string GoldenDatabaseSha256,
    string CandidateDatabaseSha256,
    long CandidateDatabaseByteLength,
    string[] SourceProgressStageLabels,
    int ProfileTargetMissingFromTriggerCount,
    Dictionary<string, int> ProjectedStageCountsByMode,
    int CompletedMainStageCount,
    int NonStageCampaignClearTriggerCount,
    int QuestConditionCampaignClearTriggerCount,
    int UnresolvedCampaignClearTriggerCount,
    int FieldMapCount,
    int CompletedScenarioCount,
    string CompletedScenarioCanonicalSha256,
    int MainQuestCount,
    int ContentsOpenUiStateCount,
    bool SoloRaidUiStateIncluded,
    bool SoloRaidMuseumExcluded,
    int TutorialGroupCount,
    int TriggerCount,
    string TriggerCanonicalSha256,
    int StageClearHistoryCount,
    bool EpinelRuntimeRoundTripVerified,
    string UnrelatedStateCanonicalSha256,
    bool UnrelatedStateChanged,
    bool RawOriginalIdentifierEmitted,
    bool RuntimeDatabaseModified,
    bool ServerExecutionStarted,
    bool ClientExecutionStarted);

internal sealed record MigrationSummary(
    int SchemaVersion,
    string ContractId,
    string PrivateSourceSha256,
    string CandidateDatabaseSha256,
    long SqliteByteLength,
    string SqliteSha256,
    int UserRowCount,
    int TriggerRowCount,
    string SourceTriggerCanonicalSha256,
    string MigratedTriggerCanonicalSha256,
    string SqliteIntegrityCode,
    bool ExactEpinelDbInitializerUsed,
    bool TriggerPaginationSequenceContinuous,
    bool MicronRuntimeDatabaseModified,
    bool ServerExecutionStarted,
    bool ClientExecutionStarted);

internal sealed record StaticIntegritySummary(
    int SchemaVersion,
    string ContractId,
    string StaticDataPackSha256,
    string PrivateSourceSha256,
    string GoldenDatabaseSha256,
    string CandidateDatabaseSha256,
    int CompletedStageReferenceCount,
    int FieldMapCount,
    bool StageAndMapReferencesVerified,
    int CompletedScenarioCount,
    int ExactAlbumScenarioIndexCount,
    int AlbumCrossReferencedScenarioCount,
    int AlbumUnindexedScenarioCount,
    string AlbumUnindexedScenarioCanonicalSha256,
    bool ScenarioReferencesVerifiedAgainstExactStageIndex,
    int MainQuestCount,
    bool MainQuestReferencesVerified,
    int ContentsOpenUiStateCount,
    bool ContentsOpenReferencesVerified,
    int TriggerCount,
    string TriggerCanonicalSha256,
    int PreservedUnresolvedCampaignTriggerCount,
    string PreservedUnresolvedCampaignTriggerCanonicalSha256,
    string[] ChangedUserProperties,
    bool AllowedJsonChangeBoundaryVerified,
    int StageClearHistoryCount,
    bool RuntimeDatabaseModified,
    bool ServerExecutionStarted,
    bool ClientExecutionStarted);

internal sealed record SqliteMaterializationSummary(
    int SchemaVersion,
    string ContractId,
    string SourceDatabaseSha256,
    string NormalizedIsolatedDatabaseSha256,
    bool IsolatedDatabaseNormalizationOccurred,
    long SqliteByteLength,
    string SqliteSha256,
    int TableCount,
    long UserRowCount,
    long SdkUserRowCount,
    long TriggerRowCount,
    string SqliteIntegrityCode,
    int ForeignKeyViolationCount,
    bool ExactEpinelDbInitializerUsed,
    bool RuntimeDatabaseModified,
    bool ServerExecutionStarted);

internal sealed record StrictDiffSummary(
    int SchemaVersion,
    string ContractId,
    string PrivateSourceSha256,
    string GoldenDatabaseSha256,
    string CandidateDatabaseSha256,
    string GoldenSqliteSha256,
    string CandidateSqliteSha256,
    string[] ChangedUserProperties,
    bool AllowedJsonChangeBoundaryVerified,
    StrictTableDiff[] TableDiffs,
    int ComparedTableCount,
    int IdenticalTableCount,
    long CandidateTriggerRowCount,
    string SourceTriggerCanonicalSha256,
    string MigratedTriggerCanonicalSha256,
    string GoldenSqliteIntegrityCode,
    string CandidateSqliteIntegrityCode,
    int ForeignKeyViolationCount,
    bool OnlyTriggerRowsAndTriggerSequenceChanged,
    bool RuntimeDatabaseModified,
    bool ServerExecutionStarted,
    bool ClientExecutionStarted);

internal sealed record StrictTableDiff(
    string TableName,
    long GoldenRowCount,
    long CandidateRowCount,
    string GoldenSchemaSha256,
    string CandidateSchemaSha256,
    string VerdictCode);

internal sealed record DatabaseSnapshot(
    string IntegrityCode,
    int ForeignKeyViolationCount,
    TableSnapshot[] Tables);

internal sealed record TableSnapshot(
    string Name,
    long RowCount,
    string SchemaSha256,
    string RowCanonicalSha256);

internal sealed record SequenceState(
    long? TriggerSequence,
    string OtherCanonicalSha256);
