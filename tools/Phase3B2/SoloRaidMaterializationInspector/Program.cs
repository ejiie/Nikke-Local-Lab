using System.Collections;
using System.Reflection;
using System.Reflection.Emit;
using System.Runtime.Loader;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

if ((args.Length != 6 && args.Length != 7) ||
    args[0] != "--runtime-root" ||
    args[2] != "--static-pack" ||
    args[4] != "--manager-id" ||
    !int.TryParse(args[5], out var managerId) ||
    managerId <= 0 ||
    (args.Length == 7 && args[6] != "--database-boundary"))
{
    Console.Error.WriteLine(
        "usage: --runtime-root <path> --static-pack <path> --manager-id <positive-int> [--database-boundary]");
    return 2;
}

var databaseBoundaryRequested = args.Length == 7;

var runtimeRoot = Path.GetFullPath(args[1]);
var staticPackPath = Path.GetFullPath(args[3]);
var assemblyPath = Path.Combine(runtimeRoot, "EpinelPS.dll");
var gameConfigPath = Path.Combine(runtimeRoot, "gameconfig.json");

RequireDirectory(runtimeRoot, "runtime_root_missing");
RequireFile(assemblyPath, "epinel_assembly_missing");
RequireFile(gameConfigPath, "game_config_missing");
RequireFile(staticPackPath, "static_pack_missing");

var localConfigPath = Path.Combine(AppContext.BaseDirectory, "gameconfig.json");
File.Copy(gameConfigPath, localConfigPath, overwrite: true);

AssemblyLoadContext.Default.Resolving += (context, name) =>
{
    var candidate = Path.Combine(runtimeRoot, $"{name.Name}.dll");
    return File.Exists(candidate)
        ? context.LoadFromAssemblyPath(candidate)
        : null;
};

var epinelAssembly = AssemblyLoadContext.Default.LoadFromAssemblyPath(assemblyPath);
var gameDataType = RequiredType(epinelAssembly, "EpinelPS.Data.GameData");
var gameData = Activator.CreateInstance(gameDataType, staticPackPath)
    ?? throw new InvalidOperationException("game_data_construction_failed");
RequiredField(gameDataType, "_instance", BindingFlags.NonPublic | BindingFlags.Static)
    .SetValue(null, gameData);

var parseTask = RequiredMethod(gameDataType, "Parse", BindingFlags.Public | BindingFlags.Instance)
    .Invoke(gameData, null) as Task
    ?? throw new InvalidOperationException("game_data_parse_task_missing");
await parseTask.ConfigureAwait(false);

var managerTable = RequiredDictionary(gameData, "SoloRaidManagerTable");
var presetTable = RequiredDictionary(gameData, "SoloRaidPresetTable");
var waveTable = RequiredDictionary(gameData, "WaveIntercept001Table");
var monsterTable = RequiredDictionary(gameData, "MonsterTable");
var modelTable = RequiredDictionary(gameData, "MonsterModelTable");
var statTable = RequiredDictionary(gameData, "MonsterStatEnhanceTable");

var managerFound = managerTable.Contains(managerId);
var manager = managerFound ? managerTable[managerId] : null;
var monsterPreset = manager is null ? 0 : IntMember(manager, "MonsterPreset");

var challengePresets = presetTable.Values.Cast<object>()
    .Where(value =>
        IntMember(value, "PresetGroupId") == monsterPreset &&
        IntMember(value, "WaveOrder") == 8)
    .ToArray();
var preset = challengePresets.Length == 1 ? challengePresets[0] : null;
var waveId = preset is null ? 0 : IntMember(preset, "Wave");
var monsterStageLevel = preset is null ? 0 : IntMember(preset, "MonsterStageLv");

var waveFound = waveId > 0 && waveTable.Contains(waveId);
var wave = waveFound ? waveTable[waveId] : null;
var targets = wave is null
    ? Array.Empty<long>()
    : LongSequence(Member(wave, "TargetList")).ToArray();
var firstTarget = targets.FirstOrDefault();
var firstTargetFound = firstTarget > 0 && monsterTable.Contains(firstTarget);
var monster = firstTargetFound ? monsterTable[firstTarget] : null;
var statEnhanceId = monster is null ? 0 : IntMember(monster, "StatenhanceId");
var monsterModelId = monster is null ? 0 : IntMember(monster, "MonsterModelId");
var model = monsterModelId > 0 && modelTable.Contains(monsterModelId)
    ? modelTable[monsterModelId]
    : null;

var matchingStats = statTable.Values.Cast<object>()
    .Where(value =>
        IntMember(value, "GroupId") == statEnhanceId &&
        IntMember(value, "Lv") == monsterStageLevel)
    .ToArray();
var hpSum = matchingStats.Sum(value => LongMember(value, "LevelHp"));

var managerRoleLineCount = manager is null ? 0 : 3;
var presetRoleLineCount = preset is null ? 0 : 13;
var waveRoleLineCount = 0;
if (wave is not null && firstTarget > 0)
{
    var targetListCount = LongSequence(Member(wave, "TargetList"))
        .Count(value => value == firstTarget);
    var targetWaveLines = 0;
    foreach (var waveItem in ObjectSequence(Member(wave, "WaveData")))
    {
        var matchingWaveMonsters = ObjectSequence(Member(waveItem, "WaveMonsterList"))
            .Count(value => LongMember(value, "WaveMonsterId") == firstTarget);
        if (matchingWaveMonsters > 0)
        {
            targetWaveLines += 2 + 1 + (matchingWaveMonsters * 2);
        }
    }
    waveRoleLineCount = 5 + 1 + targetListCount + 1 + targetWaveLines;
}
var monsterRoleLineCount = 0;
var monsterElementCount = 0;
var monsterNonzeroSkillCount = 0;
var monsterNestedSkillLineCount = 0;
var monsterSkills = Array.Empty<object>();
if (monster is not null)
{
    monsterElementCount = ObjectSequence(Member(monster, "ElementId")).Count();
    monsterSkills = ObjectSequence(Member(monster, "SkillData")).ToArray();
    var skillLines = 0;
    foreach (var skill in monsterSkills
        .Where(value => IntMember(value, "SkillId") != 0))
    {
        monsterNonzeroSkillCount++;
        skillLines += 1;
        skillLines += 1 + ObjectSequence(Member(skill, "UseFunctionIdSkill")).Count();
        skillLines += 1 + ObjectSequence(Member(skill, "HurtFunctionIdSkill")).Count();
    }
    monsterNestedSkillLineCount = skillLines;
    monsterRoleLineCount = 16 + 1 + monsterElementCount + 1 + skillLines;
}
var modelRoleLineCount = model is not null ? 12 : 0;
var statRoleLineCount = matchingStats.Length == 1 ? 12 : 0;

var targetBindingType = RequiredType(
    epinelAssembly,
    "EpinelPS.SoloRaidSelection.ClassicSoloRaidTargetBinding");
var targetValidator = RequiredMethod(
    targetBindingType,
    "CreateValidator",
    BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static).Invoke(null, null)
    ?? throw new InvalidOperationException("classic_solo_raid_target_validator_missing");
var pristineTargetValidation = RequiredMethod(
    targetValidator.GetType(),
    "Validate",
    BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance).Invoke(
        targetValidator,
        new object[] { managerId })
    ?? throw new InvalidOperationException("pristine_target_observation_validation_missing");
var pristineTargetObservationTrusted = BoolMember(
    pristineTargetValidation,
    "IsTrustedTarget");
var pristineTargetObservationCode = Member(
    pristineTargetValidation,
    "Code").ToString()
    ?? "pristine_target_observation_code_missing";
var skillShapeAfterPristineTargetValidation = InspectSkillShape(monster);

var userType = RequiredType(epinelAssembly, "EpinelPS.Models.User");
var helperType = RequiredType(
    epinelAssembly,
    "EpinelPS.LobbyServer.Soloraid.SoloRaidHelper");
var raidType = RequiredType(epinelAssembly, "EpinelPS.SoloRaidType");
var trial = Enum.ToObject(raidType, 2);

var rawUser = Activator.CreateInstance(userType)
    ?? throw new InvalidOperationException("raw_user_construction_failed");
var openMethod = RequiredMethod(
    helperType,
    "OpenSoloRaid",
    BindingFlags.Public | BindingFlags.Static);
var rawOpenCount = Convert.ToInt32(openMethod.Invoke(
    null,
    new[] { rawUser, (object)managerId, 8, trial }));
var rawState = InspectTrialState(rawUser, managerId);
var skillShapeAfterRawOpen = InspectSkillShape(monster);

var ensuredUser = Activator.CreateInstance(userType)
    ?? throw new InvalidOperationException("ensured_user_construction_failed");
var ensureMethod = RequiredMethod(
    helperType,
    "EnsureTrialOpen",
    BindingFlags.Public | BindingFlags.Static);
var firstResolution = ensureMethod.Invoke(
    null,
    new object?[] { ensuredUser, managerId, 8, null })
    ?? throw new InvalidOperationException("first_resolution_missing");
var firstState = InspectTrialState(ensuredUser, managerId);
var skillShapeAfterFirstEnsure = InspectSkillShape(monster);
var secondResolution = ensureMethod.Invoke(
    null,
    new object?[] { ensuredUser, managerId, 8, null })
    ?? throw new InvalidOperationException("second_resolution_missing");
var secondState = InspectTrialState(ensuredUser, managerId);
var skillShapeAfterReplayEnsure = InspectSkillShape(monster);

var targetValidation = RequiredMethod(
    targetValidator.GetType(),
    "Validate",
    BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance).Invoke(
        targetValidator,
        new object[] { managerId })
    ?? throw new InvalidOperationException("target_observation_validation_missing");
var targetObservationTrusted = BoolMember(targetValidation, "IsTrustedTarget");
var targetObservationCode = Member(targetValidation, "Code").ToString()
    ?? "target_observation_code_missing";
var skillShapeAfterTargetValidation = InspectSkillShape(monster);
var validatorType = targetValidator.GetType();
var emitterType = validatorType.GetNestedType(
    "CanonicalEmitter",
    BindingFlags.NonPublic)
    ?? throw new InvalidOperationException("canonical_emitter_type_missing");
var contractType = RequiredType(
    epinelAssembly,
    "EpinelPS.SoloRaidSelection.ClassicSoloRaidTargetObservationContract");
var season26Contract = RequiredProperty(
    contractType,
    "Season26",
    BindingFlags.Public | BindingFlags.Static).GetValue(null)
    ?? throw new InvalidOperationException("season26_contract_missing");
var contractId = Member(season26Contract, "ContractId").ToString()
    ?? throw new InvalidOperationException("season26_contract_id_missing");
var exactRoleLineCounts = new
{
    manager = manager is null ? 0 : ExactEmitterLineCount(
        validatorType, emitterType, contractId, "EmitManager", manager),
    challengePreset = preset is null ? 0 : ExactEmitterLineCount(
        validatorType, emitterType, contractId, "EmitPreset", preset),
    wave = wave is null || firstTarget <= 0 ? 0 : ExactEmitterLineCount(
        validatorType, emitterType, contractId, "EmitWave", wave, firstTarget),
    monster = monster is null ? 0 : ExactEmitterLineCount(
        validatorType, emitterType, contractId, "EmitMonster", monster),
    model = model is null ? 0 : ExactEmitterLineCount(
        validatorType, emitterType, contractId, "EmitModel", model),
    statEnhance = matchingStats.Length != 1 ? 0 : ExactEmitterLineCount(
        validatorType, emitterType, contractId, "EmitStat", matchingStats[0])
};
var exactMonsterSkillPredicate = ExactMonsterSkillPredicateObservation(
    validatorType,
    monsterSkills);
var exactMonsterSkillDelegateCache = ExactMonsterSkillDelegateCacheObservation(
    validatorType,
    monsterSkills);
var exactMonsterEmitterDetail = monster is null
    ? null
    : ExactMonsterEmitterObservation(
        validatorType,
        emitterType,
        contractId,
        monster);
var exactMonsterEmitterIlMembers = ExactIlMemberSequence(RequiredMethod(
    validatorType,
    "EmitMonster",
    BindingFlags.NonPublic | BindingFlags.Static));

DatabaseBoundaryResult? databaseBoundary = null;
if (databaseBoundaryRequested)
{
    var scratchDatabasePath = Path.Combine(AppContext.BaseDirectory, "db.json");
    RequireFile(scratchDatabasePath, "scratch_database_missing");
    var scratchDatabaseSha256Before = Sha256(scratchDatabasePath);

    var jsonDbType = RequiredType(epinelAssembly, "EpinelPS.Database.JsonDb");
    var jsonDbInstance = RequiredProperty(
        jsonDbType,
        "Instance",
        BindingFlags.Public | BindingFlags.Static).GetValue(null)
        ?? throw new InvalidOperationException("json_db_instance_missing");
    var users = (Member(jsonDbInstance, "Users") as IEnumerable)
        ?.Cast<object>()
        .ToArray()
        ?? throw new InvalidOperationException("json_db_users_missing");
    if (users.Length != 1)
    {
        throw new InvalidOperationException("scratch_database_user_cardinality_invalid");
    }

    var accountId = Convert.ToUInt64(Member(users[0], "ID"));
    var persistenceCoordinator = RequiredProperty(
        jsonDbType,
        "ClassicSoloRaidPersistence",
        BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static).GetValue(null)
        ?? throw new InvalidOperationException("classic_solo_raid_persistence_missing");
    var startupBindingType = RequiredType(
        epinelAssembly,
        "EpinelPS.SoloRaidSelection.SoloRaidManagerSelectionStartup");
    var startupBinding = RequiredMethod(
        startupBindingType,
        "BindFromEnvironment",
        BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static).Invoke(
            null,
            new[] { persistenceCoordinator, targetValidator, (object)false })
        ?? throw new InvalidOperationException("startup_binding_result_missing");
    var startupBindingConfigured = BoolMember(startupBinding, "IsConfigured");
    var startupBindingSucceeded = BoolMember(startupBinding, "IsSuccess");
    var startupBindingPersisted = BoolMember(startupBinding, "Persisted");
    var startupBindingCode = Member(startupBinding, "Code").ToString()
        ?? "binding_code_missing";
    var startupBindingResolutionCode =
        MemberOrNull(startupBinding, "ResolutionCode")?.ToString() ?? "none";
    var currentAfterBinding = RequiredProperty(
        jsonDbType,
        "Instance",
        BindingFlags.Public | BindingFlags.Static).GetValue(null)
        ?? throw new InvalidOperationException("json_db_after_binding_missing");
    var userAfterBinding = SingleUser(currentAfterBinding);
    var selectedManagerPresentAfterBinding =
        MemberOrNull(userAfterBinding, "SelectedClassicSoloRaidManagerId") is not null;
    var scratchDatabaseSha256AfterBinding = Sha256(scratchDatabasePath);

    var routeExecutorType = RequiredType(
        epinelAssembly,
        "EpinelPS.LobbyServer.Soloraid.ClassicSoloRaidRouteExecutor");
    var routeOpenMethod = RequiredMethod(
        routeExecutorType,
        "OpenTrial",
        BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static);
    var routeGetMethod = RequiredMethod(
        routeExecutorType,
        "GetLevelTrial",
        BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static);
    var reloadMethod = RequiredMethod(
        jsonDbType,
        "Reload",
        BindingFlags.Public | BindingFlags.Static);

    var openResponse = routeOpenMethod.Invoke(null, new object[] { accountId, 8 })
        ?? throw new InvalidOperationException("route_open_response_missing");
    var openPeriodResult = IntMember(openResponse, "PeriodResult");
    var openRaidCount = IntMember(openResponse, "RaidOpenCount");
    var currentAfterOpen = RequiredProperty(
        jsonDbType,
        "Instance",
        BindingFlags.Public | BindingFlags.Static).GetValue(null)
        ?? throw new InvalidOperationException("json_db_after_open_missing");
    var userAfterOpen = SingleUser(currentAfterOpen);
    var inMemoryStateAfterOpen = InspectTrialState(userAfterOpen, managerId);
    var scratchDatabaseSha256AfterOpen = Sha256(scratchDatabasePath);

    reloadMethod.Invoke(null, null);
    var currentAfterReload = RequiredProperty(
        jsonDbType,
        "Instance",
        BindingFlags.Public | BindingFlags.Static).GetValue(null)
        ?? throw new InvalidOperationException("json_db_after_reload_missing");
    var userAfterReload = SingleUser(currentAfterReload);
    var reloadedStateAfterOpen = InspectTrialState(userAfterReload, managerId);

    var getResponse = routeGetMethod.Invoke(null, new object[] { accountId, 8 })
        ?? throw new InvalidOperationException("route_get_response_missing");
    var getPeriodResult = IntMember(getResponse, "PeriodResult");
    var getJoinDataPresent = MemberOrNull(getResponse, "JoinData") is not null;
    var currentAfterGet = RequiredProperty(
        jsonDbType,
        "Instance",
        BindingFlags.Public | BindingFlags.Static).GetValue(null)
        ?? throw new InvalidOperationException("json_db_after_get_missing");
    var userAfterGet = SingleUser(currentAfterGet);
    var inMemoryStateAfterGet = InspectTrialState(userAfterGet, managerId);
    var scratchDatabaseSha256AfterGet = Sha256(scratchDatabasePath);

    databaseBoundary = new DatabaseBoundaryResult(
        ScratchDatabaseSha256Before: scratchDatabaseSha256Before,
        StartupBindingConfigured: startupBindingConfigured,
        StartupBindingSucceeded: startupBindingSucceeded,
        StartupBindingPersisted: startupBindingPersisted,
        StartupBindingCode: startupBindingCode,
        StartupBindingResolutionCode: startupBindingResolutionCode,
        SelectedManagerPresentAfterBinding: selectedManagerPresentAfterBinding,
        ScratchDatabaseChangedByBinding:
            scratchDatabaseSha256AfterBinding != scratchDatabaseSha256Before,
        OpenPeriodResult: openPeriodResult,
        OpenRaidCountPositive: openRaidCount > 0,
        InMemoryStateAfterOpen: inMemoryStateAfterOpen,
        ScratchDatabaseChangedAfterOpen:
            scratchDatabaseSha256AfterOpen != scratchDatabaseSha256AfterBinding,
        ReloadedStateAfterOpen: reloadedStateAfterOpen,
        GetPeriodResult: getPeriodResult,
        GetJoinDataPresent: getJoinDataPresent,
        InMemoryStateAfterGet: inMemoryStateAfterGet,
        ScratchDatabaseSha256AfterGet: scratchDatabaseSha256AfterGet,
        Verified:
            startupBindingConfigured &&
            startupBindingSucceeded &&
            startupBindingPersisted &&
            selectedManagerPresentAfterBinding &&
            openPeriodResult == 0 &&
            openRaidCount > 0 &&
            inMemoryStateAfterOpen.ValidFreshTrial &&
            scratchDatabaseSha256AfterOpen != scratchDatabaseSha256AfterBinding &&
            reloadedStateAfterOpen.ValidFreshTrial &&
            getPeriodResult == 0 &&
            getJoinDataPresent &&
            inMemoryStateAfterGet.ValidFreshTrial);
}

var staticChain = new
{
    managerFound,
    challengePresetMatchCount = challengePresets.Length,
    challengePresetUnique = challengePresets.Length == 1,
    waveFound,
    waveTargetCount = targets.Length,
    firstTargetFound,
    statEnhanceIdNonzero = statEnhanceId > 0,
    matchingStatEnhanceRowCount = matchingStats.Length,
    matchingHpSumPositive = hpSum > 0,
    canonicalRoleLineCounts = new
    {
        manager = managerRoleLineCount,
        challengePreset = presetRoleLineCount,
        wave = waveRoleLineCount,
        monster = monsterRoleLineCount,
        model = modelRoleLineCount,
        statEnhance = statRoleLineCount
    },
    monsterShape = new
    {
        elementCount = monsterElementCount,
        nonzeroSkillCount = monsterNonzeroSkillCount,
        nestedSkillLineCount = monsterNestedSkillLineCount,
        mutationTimeline = new
        {
            initial = new SkillShape(monsterSkills.Length, monsterNonzeroSkillCount),
            afterPristineTargetValidation = skillShapeAfterPristineTargetValidation,
            afterRawOpen = skillShapeAfterRawOpen,
            afterFirstEnsure = skillShapeAfterFirstEnsure,
            afterReplayEnsure = skillShapeAfterReplayEnsure,
            afterTargetValidation = skillShapeAfterTargetValidation
        },
        exactPredicate = exactMonsterSkillPredicate,
        exactDelegateCache = exactMonsterSkillDelegateCache,
        exactEmitter = exactMonsterEmitterDetail,
        exactEmitterIlMembers = exactMonsterEmitterIlMembers
    },
    expectedCanonicalRoleLineCounts = new[] { 3, 13, 13, 96, 12, 12 },
    exactEmitterRoleLineCounts = exactRoleLineCounts,
    pristineTargetObservationTrusted,
    pristineTargetObservationCode,
    targetObservationTrusted,
    targetObservationCode
};

var firstSuccess = BoolMember(firstResolution, "Success");
var firstCreated = BoolMember(firstResolution, "Created");
var firstOpenCount = IntMember(firstResolution, "OpenCount");
var secondSuccess = BoolMember(secondResolution, "Success");
var secondCreated = BoolMember(secondResolution, "Created");
var secondOpenCount = IntMember(secondResolution, "OpenCount");

var failureLeafCode = ClassifyFailure(
    managerFound,
    challengePresets.Length,
    waveFound,
    targets.Length,
    firstTargetFound,
    statEnhanceId,
    matchingStats.Length,
    hpSum,
    rawOpenCount,
    rawState,
    firstSuccess,
    firstCreated,
    firstOpenCount,
    firstState,
    secondSuccess,
    secondCreated,
    secondOpenCount,
    secondState);
if (failureLeafCode == "none" && !targetObservationTrusted)
{
    failureLeafCode = $"target_observation_rejected:{targetObservationCode}";
}
if (failureLeafCode == "none" && databaseBoundaryRequested && databaseBoundary?.Verified != true)
{
    failureLeafCode = "production_database_boundary_reproduction_failed";
}

var result = new
{
    schemaVersion = 1,
    contractId = "nll/phase3b2-epinel-solo-raid-materialization-inspection/v1",
    inspectedAtUtc = DateTimeOffset.UtcNow,
    assemblyByteLength = new FileInfo(assemblyPath).Length,
    assemblySha256 = Sha256(assemblyPath),
    staticPackByteLength = new FileInfo(staticPackPath).Length,
    staticPackSha256 = Sha256(staticPackPath),
    raidLevel = 8,
    staticChain,
    rawOpen = new
    {
        returnedPositiveCount = rawOpenCount > 0,
        state = rawState
    },
    firstEnsure = new
    {
        success = firstSuccess,
        created = firstCreated,
        returnedPositiveCount = firstOpenCount > 0,
        state = firstState
    },
    replayEnsure = new
    {
        success = secondSuccess,
        created = secondCreated,
        returnedSameCount = secondOpenCount == firstOpenCount,
        stateUnchanged = secondState == firstState,
        state = secondState
    },
    databaseBoundary,
    failureLeafCode,
    verdictCode = failureLeafCode == "none"
        ? "exact_materialization_and_replay_verified"
        : "exact_materialization_failure_reproduced",
    runtimeMutationPerformed = false,
    sourceDatabaseReadPerformed = databaseBoundaryRequested,
    sourceDatabaseMutationPerformed = false,
    scratchDatabaseMutationPerformed = databaseBoundaryRequested,
    officialOutboundUsed = false
};

Console.WriteLine(JsonSerializer.Serialize(result, new JsonSerializerOptions
{
    WriteIndented = true
}));
return failureLeafCode == "none" ? 0 : 1;

static string ClassifyFailure(
    bool managerFound,
    int presetCount,
    bool waveFound,
    int targetCount,
    bool firstTargetFound,
    int statEnhanceId,
    int statRowCount,
    long hpSum,
    int rawOpenCount,
    TrialState rawState,
    bool firstSuccess,
    bool firstCreated,
    int firstOpenCount,
    TrialState firstState,
    bool secondSuccess,
    bool secondCreated,
    int secondOpenCount,
    TrialState secondState)
{
    if (!managerFound) return "manager_missing";
    if (presetCount == 0) return "challenge_preset_missing";
    if (presetCount != 1) return "challenge_preset_ambiguous";
    if (!waveFound) return "wave_intercept_missing";
    if (targetCount == 0) return "wave_target_missing";
    if (!firstTargetFound) return "first_target_monster_missing";
    if (statEnhanceId <= 0) return "monster_stat_enhance_id_zero";
    if (statRowCount == 0) return "monster_stat_enhance_rows_missing";
    if (hpSum <= 0) return "monster_hp_sum_nonpositive";
    if (rawOpenCount <= 0) return "open_solo_raid_returned_zero";
    if (!rawState.ValidFreshTrial) return "open_solo_raid_post_state_invalid";
    if (!firstSuccess) return "ensure_trial_open_failed";
    if (!firstCreated) return "ensure_trial_open_first_call_not_created";
    if (firstOpenCount <= 0) return "ensure_trial_open_count_nonpositive";
    if (!firstState.ValidFreshTrial) return "ensure_trial_open_post_state_invalid";
    if (!secondSuccess) return "ensure_trial_open_replay_failed";
    if (secondCreated) return "ensure_trial_open_replay_recreated";
    if (secondOpenCount != firstOpenCount) return "ensure_trial_open_replay_count_changed";
    if (secondState != firstState) return "ensure_trial_open_replay_state_changed";
    return "none";
}

static TrialState InspectTrialState(object user, int managerId)
{
    var soloRaidData = Member(user, "SoloRaidData") as IDictionary
        ?? throw new InvalidOperationException("solo_raid_data_missing");
    if (!soloRaidData.Contains(managerId))
    {
        return TrialState.Missing;
    }

    var info = soloRaidData[managerId]
        ?? throw new InvalidOperationException("solo_raid_info_missing");
    var levels = Member(info, "SoloRaidLevels") as IEnumerable
        ?? throw new InvalidOperationException("solo_raid_levels_missing");
    var trialLevels = levels.Cast<object>()
        .Where(value =>
            IntMember(value, "RaidLevel") == 8 &&
            IntMember(value, "Type") == 2 &&
            BoolMember(value, "IsOpen"))
        .ToArray();

    if (trialLevels.Length != 1)
    {
        return new TrialState(
            Present: false,
            MatchingLevelCount: trialLevels.Length,
            TrialCount: IntMember(info, "TrialCount"),
            IsClear: false,
            Status: -1,
            RaidJoinCount: -1,
            LogCount: -1,
            ValidFreshTrial: false);
    }

    var trial = trialLevels[0];
    var logs = Member(trial, "Logs") as ICollection
        ?? throw new InvalidOperationException("trial_logs_missing");
    var state = new TrialState(
        Present: true,
        MatchingLevelCount: 1,
        TrialCount: IntMember(info, "TrialCount"),
        IsClear: BoolMember(trial, "IsClear"),
        Status: IntMember(trial, "Status"),
        RaidJoinCount: IntMember(trial, "RaidJoinCount"),
        LogCount: logs.Count,
        ValidFreshTrial: false);
    return state with
    {
        ValidFreshTrial =
            state.TrialCount > 0 &&
            !state.IsClear &&
            state.Status == 0 &&
            state.RaidJoinCount == 0 &&
            state.LogCount == 0
    };
}

static object SingleUser(object coreInfo)
{
    var users = (Member(coreInfo, "Users") as IEnumerable)
        ?.Cast<object>()
        .ToArray()
        ?? throw new InvalidOperationException("core_info_users_missing");
    return users.Length == 1
        ? users[0]
        : throw new InvalidOperationException("core_info_user_cardinality_invalid");
}

static int ExactEmitterLineCount(
    Type validatorType,
    Type emitterType,
    string contractId,
    string methodName,
    params object[] roleArguments)
{
    var emitter = Activator.CreateInstance(
        emitterType,
        BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic,
        binder: null,
        args: new object[] { contractId },
        culture: null)
        ?? throw new InvalidOperationException("canonical_emitter_construction_failed");
    var before = IntMember(emitter, "LineCount");
    var arguments = new object[roleArguments.Length + 1];
    arguments[0] = emitter;
    Array.Copy(roleArguments, 0, arguments, 1, roleArguments.Length);
    RequiredMethod(
        validatorType,
        methodName,
        BindingFlags.NonPublic | BindingFlags.Static).Invoke(null, arguments);
    return IntMember(emitter, "LineCount") - before;
}

static SkillShape InspectSkillShape(object? monster)
{
    if (monster is null) return new SkillShape(0, 0);
    var skills = ObjectSequence(Member(monster, "SkillData")).ToArray();
    return new SkillShape(
        skills.Length,
        skills.Count(skill => IntMember(skill, "SkillId") != 0));
}

static object ExactMonsterSkillPredicateObservation(
    Type validatorType,
    IReadOnlyList<object> skills)
{
    var candidates = validatorType
        .GetNestedTypes(BindingFlags.NonPublic)
        .SelectMany(type => type.GetMethods(
            BindingFlags.Public | BindingFlags.NonPublic |
            BindingFlags.Static | BindingFlags.Instance))
        .Where(method =>
            method.Name.Contains("<EmitMonster>", StringComparison.Ordinal) &&
            method.ReturnType == typeof(bool) &&
            method.GetParameters().Length == 1 &&
            (skills.Count == 0 ||
             method.GetParameters()[0].ParameterType.IsInstanceOfType(skills[0])))
        .ToArray();

    if (candidates.Length != 1)
    {
        return new
        {
            candidateCount = candidates.Length,
            trueCount = -1,
            falseCount = -1
        };
    }

    var predicate = candidates[0];
    object? instance = null;
    if (!predicate.IsStatic)
    {
        instance = predicate.DeclaringType?
            .GetField("<>9", BindingFlags.NonPublic | BindingFlags.Static)?
            .GetValue(null)
            ?? Activator.CreateInstance(predicate.DeclaringType!, nonPublic: true);
    }

    var results = skills
        .Select(skill => Convert.ToBoolean(predicate.Invoke(instance, new[] { skill })))
        .ToArray();
    return new
    {
        candidateCount = 1,
        trueCount = results.Count(value => value),
        falseCount = results.Count(value => !value)
    };
}

static object ExactMonsterEmitterObservation(
    Type validatorType,
    Type emitterType,
    string contractId,
    object monster)
{
    var emitter = Activator.CreateInstance(
        emitterType,
        BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic,
        binder: null,
        args: new object[] { contractId },
        culture: null)
        ?? throw new InvalidOperationException("canonical_emitter_construction_failed");
    RequiredMethod(
        validatorType,
        "EmitMonster",
        BindingFlags.NonPublic | BindingFlags.Static).Invoke(
            null,
            new[] { emitter, monster });
    var bytes = RequiredMethod(
        emitterType,
        "Finish",
        BindingFlags.Public | BindingFlags.Instance).Invoke(emitter, null) as byte[]
        ?? throw new InvalidOperationException("canonical_emitter_finish_failed");
    var lines = Encoding.UTF8.GetString(bytes)
        .Split('\n', StringSplitOptions.RemoveEmptyEntries);
    var countLine = lines.Single(line =>
        line.StartsWith("monster\tskillData.count\tuint32\t", StringComparison.Ordinal));
    var declaredCount = int.Parse(
        countLine[(countLine.LastIndexOf('\t') + 1)..],
        System.Globalization.CultureInfo.InvariantCulture);
    return new
    {
        declaredSkillCount = declaredCount,
        emittedSkillDetailLineCount = lines.Count(line =>
            line.StartsWith("monster\tskillData[", StringComparison.Ordinal))
    };
}

static object ExactMonsterSkillDelegateCacheObservation(
    Type validatorType,
    IReadOnlyList<object> skills)
{
    var skillType = skills.Count == 0 ? null : skills[0].GetType();
    var candidates = validatorType
        .GetNestedTypes(BindingFlags.NonPublic)
        .SelectMany(type => type.GetFields(
            BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static))
        .Where(field =>
            typeof(Delegate).IsAssignableFrom(field.FieldType) &&
            field.FieldType.IsGenericType &&
            field.FieldType.GetGenericArguments() is var arguments &&
            arguments.Length == 2 &&
            arguments[1] == typeof(bool) &&
            (skillType is null || arguments[0] == skillType))
        .Select(field => field.GetValue(null) as Delegate)
        .Where(value => value is not null)
        .Cast<Delegate>()
        .ToArray();

    var results = candidates.Select(candidate => new
    {
        methodName = candidate.Method.Name,
        trueCount = skills.Count(skill =>
            Convert.ToBoolean(candidate.DynamicInvoke(skill)))
    }).ToArray();
    return new
    {
        initializedCandidateCount = candidates.Length,
        results
    };
}

static string[] ExactIlMemberSequence(MethodInfo method)
{
    var body = method.GetMethodBody()
        ?? throw new InvalidOperationException("emit_monster_method_body_missing");
    var bytes = body.GetILAsByteArray()
        ?? throw new InvalidOperationException("emit_monster_il_missing");
    var opCodes = typeof(OpCodes)
        .GetFields(BindingFlags.Public | BindingFlags.Static)
        .Select(field => (OpCode)field.GetValue(null)!)
        .ToDictionary(opCode => unchecked((ushort)opCode.Value));
    var members = new List<string>();
    var offset = 0;
    while (offset < bytes.Length)
    {
        var instructionOffset = offset;
        ushort value = bytes[offset++];
        if (value == 0xfe)
        {
            value = (ushort)(0xfe00 | bytes[offset++]);
        }
        var opCode = opCodes[value];
        var operandOffset = offset;
        var operandLength = opCode.OperandType switch
        {
            OperandType.InlineNone => 0,
            OperandType.ShortInlineBrTarget or
            OperandType.ShortInlineI or
            OperandType.ShortInlineVar => 1,
            OperandType.InlineVar => 2,
            OperandType.InlineBrTarget or
            OperandType.InlineField or
            OperandType.InlineI or
            OperandType.InlineMethod or
            OperandType.InlineSig or
            OperandType.InlineString or
            OperandType.InlineTok or
            OperandType.InlineType or
            OperandType.ShortInlineR => 4,
            OperandType.InlineI8 or OperandType.InlineR => 8,
            OperandType.InlineSwitch => 4 +
                (BitConverter.ToInt32(bytes, operandOffset) * 4),
            _ => throw new InvalidOperationException(
                $"unsupported_operand_type:{opCode.OperandType}")
        };

        if (opCode.OperandType is OperandType.InlineField or
            OperandType.InlineMethod or OperandType.InlineTok or
            OperandType.InlineType)
        {
            var token = BitConverter.ToInt32(bytes, operandOffset);
            var member = method.Module.ResolveMember(
                token,
                method.DeclaringType?.GetGenericArguments(),
                method.GetGenericArguments());
            members.Add($"{instructionOffset:x4}:{opCode.Name}:" +
                $"{member?.DeclaringType?.FullName}::{member?.Name}");
        }
        offset += operandLength;
    }
    return members.ToArray();
}

static IDictionary RequiredDictionary(object instance, string name) =>
    Member(instance, name) as IDictionary
    ?? throw new InvalidOperationException($"{name}_dictionary_missing");

static object Member(object instance, string name)
{
    var type = instance.GetType();
    var field = type.GetField(name, BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance);
    if (field is not null) return field.GetValue(instance)
        ?? throw new InvalidOperationException($"{name}_field_value_missing");
    var property = type.GetProperty(name, BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance)
        ?? throw new InvalidOperationException($"{name}_member_missing");
    return property.GetValue(instance)
        ?? throw new InvalidOperationException($"{name}_property_value_missing");
}

static object? MemberOrNull(object instance, string name)
{
    var type = instance.GetType();
    var field = type.GetField(name, BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance);
    if (field is not null) return field.GetValue(instance);
    var property = type.GetProperty(name, BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance)
        ?? throw new InvalidOperationException($"{name}_member_missing");
    return property.GetValue(instance);
}

static int IntMember(object instance, string name) =>
    Convert.ToInt32(Member(instance, name));

static long LongMember(object instance, string name) =>
    Convert.ToInt64(Member(instance, name));

static bool BoolMember(object instance, string name) =>
    Convert.ToBoolean(Member(instance, name));

static IEnumerable<long> LongSequence(object value)
{
    if (value is not IEnumerable sequence)
    {
        throw new InvalidOperationException("long_sequence_missing");
    }
    foreach (var item in sequence)
    {
        yield return Convert.ToInt64(item);
    }
}

static IEnumerable<object> ObjectSequence(object value)
{
    if (value is not IEnumerable sequence)
    {
        throw new InvalidOperationException("object_sequence_missing");
    }
    foreach (var item in sequence)
    {
        if (item is not null) yield return item;
    }
}

static Type RequiredType(Assembly assembly, string name) =>
    assembly.GetType(name, throwOnError: true, ignoreCase: false)
    ?? throw new InvalidOperationException($"{name}_type_missing");

static FieldInfo RequiredField(Type type, string name, BindingFlags flags) =>
    type.GetField(name, flags)
    ?? throw new InvalidOperationException($"{name}_field_missing");

static PropertyInfo RequiredProperty(Type type, string name, BindingFlags flags) =>
    type.GetProperty(name, flags)
    ?? throw new InvalidOperationException($"{name}_property_missing");

static MethodInfo RequiredMethod(Type type, string name, BindingFlags flags) =>
    type.GetMethod(name, flags)
    ?? throw new InvalidOperationException($"{name}_method_missing");

static void RequireFile(string path, string code)
{
    if (!File.Exists(path)) throw new FileNotFoundException(code, path);
}

static void RequireDirectory(string path, string code)
{
    if (!Directory.Exists(path)) throw new DirectoryNotFoundException(code);
}

static string Sha256(string path) =>
    Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path))).ToLowerInvariant();

internal readonly record struct SkillShape(int TotalCount, int NonzeroCount);

internal readonly record struct TrialState(
    bool Present,
    int MatchingLevelCount,
    int TrialCount,
    bool IsClear,
    int Status,
    int RaidJoinCount,
    int LogCount,
    bool ValidFreshTrial)
{
    public static TrialState Missing => new(
        Present: false,
        MatchingLevelCount: 0,
        TrialCount: 0,
        IsClear: false,
        Status: -1,
        RaidJoinCount: -1,
        LogCount: -1,
        ValidFreshTrial: false);
}

internal sealed record DatabaseBoundaryResult(
    string ScratchDatabaseSha256Before,
    bool StartupBindingConfigured,
    bool StartupBindingSucceeded,
    bool StartupBindingPersisted,
    string StartupBindingCode,
    string StartupBindingResolutionCode,
    bool SelectedManagerPresentAfterBinding,
    bool ScratchDatabaseChangedByBinding,
    int OpenPeriodResult,
    bool OpenRaidCountPositive,
    TrialState InMemoryStateAfterOpen,
    bool ScratchDatabaseChangedAfterOpen,
    TrialState ReloadedStateAfterOpen,
    int GetPeriodResult,
    bool GetJoinDataPresent,
    TrialState InMemoryStateAfterGet,
    string ScratchDatabaseSha256AfterGet,
    bool Verified);
