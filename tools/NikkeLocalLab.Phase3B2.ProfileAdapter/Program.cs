using System.Globalization;
using System.Security.Cryptography;
using System.Reflection;
using System.Text;
using System.Text.Json;
using EpinelPS;
using EpinelPS.Data;
using EpinelPS.Models;
using EpinelPS.SoloRaidSelection;
using EpinelPS.Utils;
using Newtonsoft.Json;

#pragma warning disable CS0612

const int ExpectedRosterCount = 193;
const int ExpectedDetailCount = 193;
const int ExpectedEquipmentCoordinateCount = 772;
const int ExpectedOverloadReferenceCount = 638;
const int ExpectedConsoleCount = 9;
const int MaximumScalar = 1_000_000;

var options = ParseArguments(args);
var sourcePath = Required(options, "source");
var serverRoot = Path.GetFullPath(Required(options, "server-root"));
var contextPath = Path.GetFullPath(Required(options, "context"));
var receiptPath = Path.GetFullPath(Required(options, "receipt"));
var expectedSourceLength = long.Parse(Required(options, "expected-source-length"), CultureInfo.InvariantCulture);
var expectedSourceSha256 = Required(options, "expected-source-sha256").ToLowerInvariant();

Require(expectedSourceLength > 0, "source_length_expectation_invalid");
Require(expectedSourceSha256.Length == 64 && expectedSourceSha256.All(IsLowerHex), "source_hash_expectation_invalid");
Require(File.Exists(sourcePath), "credential_bearing_source_missing");
Require(Directory.Exists(serverRoot), "server_root_missing");
Require(!File.Exists(Path.Combine(serverRoot, "db.json")), "database_already_exists");
Require(!File.Exists(contextPath) && !File.Exists(receiptPath), "output_already_exists");

var sourceInfo = new FileInfo(sourcePath);
Require(sourceInfo.Length == expectedSourceLength, "credential_bearing_source_length_mismatch");
Require(HashFile(sourcePath) == expectedSourceSha256, "credential_bearing_source_hash_mismatch");

var capture = ParseCapture(sourcePath);
Require(capture.Roster.Count == ExpectedRosterCount, "roster_count_mismatch");
Require(capture.Details.Count == ExpectedDetailCount, "detail_count_mismatch");
Require(capture.Details.Sum(value => value.Equipment.Count) == ExpectedEquipmentCoordinateCount,
    "equipment_coordinate_count_mismatch");
Require(capture.Details.SelectMany(value => value.Equipment)
        .SelectMany(value => value.OptionReferences).Count(value => value != 0) == ExpectedOverloadReferenceCount,
    "overload_reference_count_mismatch");
Require(capture.Outpost.Consoles.Count == ExpectedConsoleCount, "console_count_mismatch");

AssetDownloadUtil.ConfigureOfficialOutbound(false);
await GameData.CreateAsync();
var decodedArchiveField = typeof(GameData).GetField("ZipStream", BindingFlags.Instance | BindingFlags.NonPublic);
var decodedArchive = decodedArchiveField?.GetValue(GameData.Instance) as MemoryStream;
Require(decodedArchive is not null, "decoded_archive_binding_unavailable");
var decodedArchiveSha256 = Convert.ToHexString(SHA256.HashData(decodedArchive!.ToArray())).ToLowerInvariant();
Require(decodedArchiveSha256 == ClassicSoloRaidTargetObservationContract.Season26.SourceObservationSha256,
    "decoded_archive_binding_mismatch");

var validator = new ClassicSoloRaidTargetObservationValidator(
    new GameDataClassicSoloRaidObservationData(GameData.Instance),
    ClassicSoloRaidTargetObservationContract.Season26);
var targetObservations = GameData.Instance.SoloRaidManagerTable.Keys
    .Select(value => (ManagerId: value, Validation: validator.Validate(value)))
    .ToArray();
var targets = targetObservations
    .Where(value => value.Validation.IsTrustedTarget)
    .Take(2)
    .Select(value => value.ManagerId)
    .ToArray();
if (targets.Length != 1)
{
    var reasonCounts = string.Join("_", targetObservations
        .GroupBy(value => value.Validation.Code, StringComparer.Ordinal)
        .OrderBy(value => value.Key, StringComparer.Ordinal)
        .Select(value => $"{value.Key}-{value.Count().ToString(CultureInfo.InvariantCulture)}"));
    throw new InvalidOperationException(
        $"season26_target_count_{targets.Length.ToString(CultureInfo.InvariantCulture)}_{reasonCounts}_{Season26Shape(GameData.Instance)}");
}

var rosterByReference = capture.Roster.ToDictionary(value => value.CharacterReference);
var detailsByReference = capture.Details.ToDictionary(value => value.CharacterReference);
Require(rosterByReference.Keys.ToHashSet().SetEquals(detailsByReference.Keys),
    "roster_detail_coverage_mismatch");
var characterRowsByNameCode = GameData.Instance.CharacterTable.Values
    .Where(value => value.IsVisible)
    .GroupBy(value => (long)value.NameCode)
    .ToDictionary(value => value.Key, value => value.OrderBy(row => row.GradeCoreId).ToArray());
var nameCodeCoverage = rosterByReference.Keys.Count(characterRowsByNameCode.ContainsKey);
var tableKeyCoverage = rosterByReference.Keys.Count(value => value <= int.MaxValue &&
    GameData.Instance.CharacterTable.ContainsKey((int)value));
Require(nameCodeCoverage == rosterByReference.Count,
    $"character_catalog_mapping_coverage_name-{nameCodeCoverage}_key-{tableKeyCoverage}_expected-{rosterByReference.Count}");

var launcherPassword = NewLauncherPassword();
var launcherPasswordHash = LauncherPasswordHash(launcherPassword);
Require(launcherPassword.Length == 20 && launcherPassword.All(IsLowerHex),
    "launcher_password_shape_invalid");
Require(launcherPasswordHash.Length == 32 && launcherPasswordHash.All(IsLowerHex),
    "launcher_password_hash_shape_invalid");

var user = new User
{
    ID = NewSyntheticAccountId(),
    Username = $"synthetic-{Guid.NewGuid():N}@invalid.local",
    Password = launcherPasswordHash,
    PlayerName = "SyntheticLab",
    Nickname = "SyntheticLab",
    RegisterTime = DateTimeOffset.UtcNow.ToUnixTimeSeconds(),
    SynchroDeviceLevel = capture.Outpost.SynchroLevel,
    SelectedClassicSoloRaidManagerId = null
};

long nextItemSerial = 100_000;
long nextFavoriteSerial = 200_000;
var zeroBondOmittedCount = 0;
var equippedEquipmentCount = 0;
var equipmentAwakeningCount = 0;
var equippedCubeCount = 0;
var equippedFavoriteCount = 0;
var characterSerial = 1;

foreach (var reference in rosterByReference.Keys.Order())
{
    var roster = rosterByReference[reference];
    var detail = detailsByReference[reference];
    Require(roster.LimitBreak == detail.LimitBreak && roster.CoreLevel == detail.CoreLevel &&
            roster.CombatPower == detail.CombatPower && roster.CostumeId == detail.CostumeId,
        "roster_detail_scalar_conflict");

    var candidates = characterRowsByNameCode[reference];
    Require(candidates.Length > 0 && candidates.Select(value => value.GradeCoreId).Distinct().Count() == candidates.Length,
        "character_catalog_mapping_missing");
    var expectedGradeCore = checked(candidates[0].GradeCoreId + roster.LimitBreak + roster.CoreLevel);
    var selected = candidates.SingleOrDefault(value => value.GradeCoreId == expectedGradeCore);
    Require(selected is not null && selected.IsVisible && selected.ResourceId > 0 && selected.Skill1Id > 0 &&
            selected.Skill2Id > 0 && selected.UltiSkillId > 0,
        "character_catalog_mapping_invalid");
    Require(roster.CostumeId == 0 || GameData.Instance.CharacterCostumeTable.ContainsKey(roster.CostumeId),
        "costume_catalog_mapping_missing");

    var csn = characterSerial++;
    user.Characters.Add(new CharacterModel
    {
        Csn = csn,
        Tid = selected!.Id,
        CostumeId = roster.CostumeId,
        Level = roster.Level,
        UltimateLevel = detail.BurstLevel,
        Skill1Lvl = detail.Skill1Level,
        Skill2Lvl = detail.Skill2Level,
        Grade = selected.GradeCoreId,
        IsMainForce = false
    });
    if (roster.CostumeId != 0)
    {
        user.CostumeList.Add(roster.CostumeId);
    }

    if (detail.BondLevel == 0)
    {
        zeroBondOmittedCount++;
    }
    else
    {
        user.BondInfo.Add(new NetUserAttractiveData
        {
            NameCode = checked((int)reference),
            Lv = detail.BondLevel,
            Exp = 0
        });
    }

    foreach (var equipment in detail.Equipment.OrderBy(value => value.Position))
    {
        if (equipment.DefinitionReference == 0)
        {
            Require(equipment.Tier == 0 && equipment.Level == 0 && equipment.Corporation == 0 &&
                    equipment.OptionReferences.All(value => value == 0),
                "unequipped_equipment_state_conflict");
            continue;
        }

        var equipmentTid = checked((int)equipment.DefinitionReference);
        Require(GameData.Instance.ItemEquipTable.TryGetValue(equipmentTid, out var record),
            "equipment_catalog_mapping_missing");
        Require(record!.GradeCoreId == equipment.Tier &&
                EquipmentPosition(record.ItemSubType) == equipment.Position &&
                equipment.Level is >= 0 and <= 5 &&
                equipment.Corporation is 0 or 1 or 2 or 3 or 4 or 7,
            "equipment_catalog_mapping_invalid");

        var isn = nextItemSerial++;
        user.Items.Add(new DbItemData
        {
            ItemType = equipmentTid,
            Csn = csn,
            Count = 1,
            Level = equipment.Level,
            Exp = 0,
            Position = equipment.Position,
            Corp = equipment.Corporation,
            Isn = isn
        });
        equippedEquipmentCount++;

        if (equipment.OptionReferences.Any(value => value != 0))
        {
            user.EquipmentAwakenings.Add(new EquipmentAwakeningData
            {
                Isn = isn,
                IsNewData = false,
                Option = new NetEquipmentAwakeningOption
                {
                    Option1Id = checked((int)equipment.OptionReferences[0]),
                    Option2Id = checked((int)equipment.OptionReferences[1]),
                    Option3Id = checked((int)equipment.OptionReferences[2])
                }
            });
            equipmentAwakeningCount++;
        }
    }

    if (detail.CubeReference != 0)
    {
        var cubeTid = checked((int)detail.CubeReference);
        Require(GameData.Instance.ItemHarmonyCubeTable.TryGetValue(cubeTid, out var cube) && detail.CubeLevel > 0,
            "cube_catalog_mapping_missing");
        Require(GameData.Instance.ItemHarmonyCubeLevelTable.Values.Any(value =>
                value.LevelEnhanceId == cube!.LevelEnhanceId && value.Level == detail.CubeLevel),
            "cube_level_catalog_mapping_missing");
        user.Items.Add(new DbItemData
        {
            ItemType = cubeTid,
            Csn = 0,
            Count = 1,
            Level = detail.CubeLevel,
            Exp = 0,
            Position = cube!.LocationId,
            Corp = 0,
            Isn = nextItemSerial++,
            CsnList = [csn]
        });
        equippedCubeCount++;
    }
    else
    {
        Require(detail.CubeLevel == 0, "cube_state_conflict");
    }

    if (detail.FavoriteReference != 0)
    {
        var favoriteTid = checked((int)detail.FavoriteReference);
        Require(GameData.Instance.FavoriteItemTable.TryGetValue(favoriteTid, out var favorite) &&
                detail.FavoriteLevel >= 0 && detail.FavoriteLevel <= favorite!.MaxLevel,
            "favorite_catalog_mapping_missing");
        user.FavoriteItems.Add(new NetUserFavoriteItemData
        {
            FavoriteItemId = nextFavoriteSerial++,
            Tid = favoriteTid,
            Csn = csn,
            Lv = detail.FavoriteLevel,
            Exp = 0
        });
        equippedFavoriteCount++;
    }
    else
    {
        Require(detail.FavoriteLevel == 0, "favorite_state_conflict");
    }
}

user.CostumeList = user.CostumeList.Distinct().Order().ToList();
foreach (var console in capture.Outpost.Consoles.OrderBy(value => value.DefinitionReference))
{
    var tid = checked((int)console.DefinitionReference);
    Require(GameData.Instance.RecycleResearchStats.TryGetValue(tid, out var stat),
        "console_catalog_mapping_missing");
    user.ResearchProgress.Add(tid, new RecycleRoomResearchProgress
    {
        Level = console.Level,
        Attack = checked(stat!.Attack * console.Level),
        Defense = checked(stat.Defence * console.Level),
        Hp = checked(stat.Hp * console.Level)
    });
}

Require(user.Characters.Count == ExpectedRosterCount && user.Items.Count == equippedEquipmentCount + equippedCubeCount &&
        user.ResearchProgress.Count == ExpectedConsoleCount,
    "materialized_profile_count_mismatch");

var core = new CoreInfo
{
    Users = [user],
    LauncherTokenKey = RandomNumberGenerator.GetBytes(32),
    DbVersion = 5,
    EncryptionTokenKey = RandomNumberGenerator.GetBytes(32),
    LogLevel = LogType.Error,
    MaxInterceptionCount = 3,
    ResetHourUtcTime = 20,
    ActiveEventBannerIds = []
};

Directory.CreateDirectory(Path.GetDirectoryName(contextPath)!);
Directory.CreateDirectory(Path.GetDirectoryName(receiptPath)!);
var dbPath = Path.Combine(serverRoot, "db.json");
WriteAtomic(dbPath, JsonConvert.SerializeObject(core, Formatting.Indented) + "\n");

var dbRoundTrip = JsonConvert.DeserializeObject<CoreInfo>(await File.ReadAllTextAsync(dbPath));
Require(dbRoundTrip is not null && dbRoundTrip.Users.Count == 1 &&
        dbRoundTrip.Users[0].ID == user.ID && dbRoundTrip.Users[0].Characters.Count == ExpectedRosterCount &&
        dbRoundTrip.Users[0].Password == launcherPasswordHash &&
        dbRoundTrip.Users[0].SelectedClassicSoloRaidManagerId is null,
    "database_roundtrip_validation_failed");

var context = new
{
    contractId = "nll/phase3b2-synthetic-runtime-context/v1",
    accountId = user.ID,
    username = user.Username,
    password = launcherPassword,
    managerId = targets[0],
    selectedManagerPersisted = false
};
WriteAtomic(contextPath, SerializeSourceFree(context));

var dbEvidence = Evidence(dbPath);
var contextEvidence = Evidence(contextPath);
var receipt = new
{
    contractId = "nll/phase3b2-offline-synthetic-profile/v1",
    createdAtUtc = DateTimeOffset.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture),
    levelAuthority = "roster_observation/v1",
    decodedArchiveBindingVerified = true,
    characterCount = user.Characters.Count,
    equippedEquipmentCount,
    equipmentAwakeningCount,
    overloadReferenceCount = ExpectedOverloadReferenceCount,
    equippedCubeCount,
    equippedFavoriteCount,
    consoleCount = user.ResearchProgress.Count,
    zeroBondObservationOmittedCount = zeroBondOmittedCount,
    ignoredUnrecognizedPacketCount = capture.IgnoredPacketCount,
    officialIdentityPersisted = false,
    officialCredentialPersisted = false,
    officialEndpointPersisted = false,
    officialTracePersisted = false,
    combatPowerMaterialized = false,
    selectedManagerPersisted = false,
    launcherPasswordPlaintextLength = launcherPassword.Length,
    launcherPasswordStorageLength = launcherPasswordHash.Length,
    launcherPasswordStorageSchemeCode = "md5_lower_hex_legacy_launcher_compatibility",
    launcherPasswordPlaintextPersistedInDatabase = false,
    dbByteLength = dbEvidence.Length,
    dbSha256 = dbEvidence.Sha256,
    runtimeContextByteLength = contextEvidence.Length,
    runtimeContextSha256 = contextEvidence.Sha256,
    serverExecutionStarted = false,
    clientExecutionStarted = false
};
WriteAtomic(receiptPath, SerializeSourceFree(receipt));

Console.WriteLine(SerializeSourceFree(new
{
    status = "synthetic_profile_ready",
    characterCount = user.Characters.Count,
    equippedEquipmentCount,
    equipmentAwakeningCount,
    equippedCubeCount,
    equippedFavoriteCount,
    consoleCount = user.ResearchProgress.Count,
    zeroBondObservationOmittedCount = zeroBondOmittedCount,
    serverExecutionStarted = false,
    clientExecutionStarted = false
}).TrimEnd());

static Capture ParseCapture(string path)
{
    using var stream = File.OpenRead(path);
    using var document = JsonDocument.Parse(stream, new JsonDocumentOptions
    {
        AllowTrailingCommas = false,
        CommentHandling = JsonCommentHandling.Disallow,
        MaxDepth = 24
    });
    EnsureNoDuplicateProperties(document.RootElement);
    RequireObject(document.RootElement,
        ["uid", "phase_1_initial_load", "phase_2_after_click"],
        ["uid", "phase_1_initial_load", "phase_2_after_click"], "source_root_shape_invalid");
    Require(document.RootElement.GetProperty("uid").ValueKind == JsonValueKind.String,
        "source_root_shape_invalid");

    List<RawRoster>? roster = null;
    RawOutpost? outpost = null;
    var details = new List<RawDetail>();
    var ignored = 0;
    ParsePhase(document.RootElement.GetProperty("phase_1_initial_load"), ref roster, ref outpost, details, ref ignored);
    ParsePhase(document.RootElement.GetProperty("phase_2_after_click"), ref roster, ref outpost, details, ref ignored);
    Require(roster is not null && outpost is not null, "required_profile_payload_missing");
    Require(roster!.Select(value => value.CharacterReference).Distinct().Count() == roster!.Count &&
            details.Select(value => value.CharacterReference).Distinct().Count() == details.Count,
        "character_observation_duplicate");
    return new Capture(roster!, details, outpost!, ignored);
}

static void ParsePhase(JsonElement phase, ref List<RawRoster>? roster, ref RawOutpost? outpost,
    List<RawDetail> details, ref int ignored)
{
    Require(phase.ValueKind == JsonValueKind.Array && phase.GetArrayLength() <= 1_024,
        "source_phase_shape_invalid");
    foreach (var packet in phase.EnumerateArray())
    {
        RequireObject(packet, ["endpoint", "url", "data"], ["endpoint", "url", "data"],
            "source_packet_shape_invalid");
        Require(packet.GetProperty("endpoint").ValueKind == JsonValueKind.String &&
                packet.GetProperty("url").ValueKind == JsonValueKind.String,
            "source_packet_shape_invalid");
        var data = packet.GetProperty("data");
        if (data.ValueKind == JsonValueKind.Null) { ignored++; continue; }
        Require(data.ValueKind == JsonValueKind.Object, "source_packet_shape_invalid");
        var hasRoster = data.TryGetProperty("characters", out _);
        var hasDetail = data.TryGetProperty("character_details", out _) || data.TryGetProperty("state_effects", out _);
        var hasOutpost = data.TryGetProperty("outpost_info", out _);
        Require((hasRoster ? 1 : 0) + (hasDetail ? 1 : 0) + (hasOutpost ? 1 : 0) <= 1,
            "recognized_payload_mixed");
        if (hasRoster)
        {
            Require(roster is null, "roster_payload_duplicate");
            roster = ParseRoster(data);
        }
        else if (hasDetail)
        {
            ParseDetails(data, details);
        }
        else if (hasOutpost)
        {
            Require(outpost is null, "outpost_payload_duplicate");
            outpost = ParseOutpost(data);
        }
        else
        {
            ignored++;
        }
    }
}

static List<RawRoster> ParseRoster(JsonElement data)
{
    RequireObject(data, ["characters", "is_banned", "trace_id"], ["characters"],
        "roster_payload_shape_invalid");
    var rows = data.GetProperty("characters");
    Require(rows.ValueKind == JsonValueKind.Array && rows.GetArrayLength() is > 0 and <= 1_024,
        "roster_count_invalid");
    var result = new List<RawRoster>();
    foreach (var row in rows.EnumerateArray())
    {
        RequireObject(row, ["name_code", "lv", "grade", "core", "combat", "costume_id"],
            ["name_code", "lv", "grade", "core", "combat", "costume_id"],
            "roster_character_shape_invalid");
        result.Add(new RawRoster(
            PositiveLong(row, "name_code"),
            PositiveInt(row, "lv", MaximumScalar),
            NonnegativeInt(row, "grade", MaximumScalar),
            NonnegativeInt(row, "core", MaximumScalar),
            NonnegativeLong(row, "combat"),
            checked((int)NonnegativeLong(row, "costume_id"))));
    }
    return result;
}

static void ParseDetails(JsonElement data, List<RawDetail> details)
{
    RequireObject(data, ["character_details", "state_effects", "trace_id"],
        ["character_details", "state_effects"], "detail_payload_shape_invalid");
    var effects = ParseStateEffects(data.GetProperty("state_effects"));
    var rows = data.GetProperty("character_details");
    Require(rows.ValueKind == JsonValueKind.Array && rows.GetArrayLength() is > 0 and <= 128,
        "detail_batch_count_invalid");
    foreach (var row in rows.EnumerateArray())
    {
        var allowed = new HashSet<string>(StringComparer.Ordinal)
        {
            "arena_combat", "arena_harmony_cube_lv", "arena_harmony_cube_tid", "attractive_lv", "combat",
            "core", "costume_tid", "favorite_item_lv", "favorite_item_tid", "grade", "harmony_cube_lv",
            "harmony_cube_tid", "lv", "name_code", "skill1_lv", "skill2_lv", "ulti_skill_lv"
        };
        foreach (var prefix in new[] { "head", "torso", "arm", "leg" })
        {
            foreach (var suffix in new[] { "corporation_type", "lv", "option1_id", "option2_id", "option3_id", "tid", "tier" })
                allowed.Add($"{prefix}_equip_{suffix}");
        }
        RequireObject(row, allowed, allowed.Where(value => !value.StartsWith("arena_", StringComparison.Ordinal)).ToArray(),
            "detail_character_shape_invalid");
        var equipment = new[]
        {
            ParseEquipment(row, 0, "head"), ParseEquipment(row, 1, "torso"),
            ParseEquipment(row, 2, "arm"), ParseEquipment(row, 3, "leg")
        };
        Require(equipment.SelectMany(value => value.OptionReferences).Where(value => value != 0)
                .All(effects.Contains), "overload_same_packet_state_effect_missing");
        details.Add(new RawDetail(
            PositiveLong(row, "name_code"), PositiveInt(row, "lv", MaximumScalar),
            NonnegativeInt(row, "grade", MaximumScalar), NonnegativeInt(row, "core", MaximumScalar),
            NonnegativeLong(row, "combat"), NonnegativeInt(row, "attractive_lv", MaximumScalar),
            PositiveInt(row, "skill1_lv", MaximumScalar), PositiveInt(row, "skill2_lv", MaximumScalar),
            PositiveInt(row, "ulti_skill_lv", MaximumScalar), NonnegativeLong(row, "harmony_cube_tid"),
            NonnegativeInt(row, "harmony_cube_lv", MaximumScalar), NonnegativeLong(row, "favorite_item_tid"),
            NonnegativeInt(row, "favorite_item_lv", MaximumScalar),
            checked((int)NonnegativeLong(row, "costume_tid")), equipment));
    }
}

static HashSet<long> ParseStateEffects(JsonElement effects)
{
    Require(effects.ValueKind == JsonValueKind.Array && effects.GetArrayLength() <= 4_096,
        "state_effect_count_invalid");
    var result = new HashSet<long>();
    foreach (var effect in effects.EnumerateArray())
    {
        RequireObject(effect,
            ["function_details", "functions", "hurt_function_id_list", "icon", "id", "use_function_id_list"],
            ["function_details", "id"], "state_effect_shape_invalid");
        var idNode = effect.GetProperty("id");
        var idText = idNode.ValueKind == JsonValueKind.String ? idNode.GetString() : null;
        var parsedId = long.TryParse(idText, NumberStyles.None, CultureInfo.InvariantCulture, out var id);
        Require(idNode.ValueKind == JsonValueKind.String && parsedId && id > 0,
            "state_effect_value_invalid");
        Require(result.Add(id), "state_effect_reference_duplicate");
        var functions = effect.GetProperty("function_details");
        Require(functions.ValueKind == JsonValueKind.Array && functions.GetArrayLength() == 1,
            "state_effect_function_count_invalid");
        RequireObject(functions[0],
            ["buff", "buff_icon", "duration_type", "duration_value", "function_battlepower", "function_standard",
             "function_target", "function_type", "function_value", "function_value_type", "id", "level", "name_localvalues"],
            ["function_type", "function_value", "function_value_type", "id"],
            "state_effect_function_shape_invalid");
        Integer(functions[0], "function_value");
        Integer(functions[0], "id");
    }
    return result;
}

static RawEquipment ParseEquipment(JsonElement row, int position, string prefix) => new(
    position,
    NonnegativeLong(row, $"{prefix}_equip_tid"),
    NonnegativeInt(row, $"{prefix}_equip_tier", 100),
    NonnegativeInt(row, $"{prefix}_equip_lv", 5),
    NonnegativeInt(row, $"{prefix}_equip_corporation_type", 100),
    [NonnegativeLong(row, $"{prefix}_equip_option1_id"),
     NonnegativeLong(row, $"{prefix}_equip_option2_id"),
     NonnegativeLong(row, $"{prefix}_equip_option3_id")]);

static RawOutpost ParseOutpost(JsonElement data)
{
    RequireObject(data, ["outpost_info"], ["outpost_info"], "outpost_payload_shape_invalid");
    var outpost = data.GetProperty("outpost_info");
    RequireObject(outpost,
        ["infra_core_level", "is_hide", "jukebox_count", "memorial_counts", "outpost_battle_level",
         "recycle_room_researches", "synchro_level", "synchro_nonempty_slot_count", "tactic_academy_class",
         "tactic_academy_lesson"],
        ["recycle_room_researches", "synchro_level", "synchro_nonempty_slot_count"], "outpost_shape_invalid");
    var rows = outpost.GetProperty("recycle_room_researches");
    Require(rows.ValueKind == JsonValueKind.Array && rows.GetArrayLength() == ExpectedConsoleCount,
        "console_set_count_invalid");
    var consoles = new List<RawConsole>();
    foreach (var row in rows.EnumerateArray())
    {
        RequireObject(row, ["exp", "lv", "tid"], ["exp", "lv", "tid"], "console_shape_invalid");
        consoles.Add(new RawConsole(PositiveLong(row, "tid"), NonnegativeInt(row, "lv", MaximumScalar),
            NonnegativeLong(row, "exp")));
    }
    Require(consoles.Select(value => value.DefinitionReference).Distinct().Count() == ExpectedConsoleCount,
        "console_reference_duplicate");
    return new RawOutpost(PositiveInt(outpost, "synchro_level", MaximumScalar), consoles);
}

static Dictionary<string, string> ParseArguments(string[] values)
{
    Require(values.Length > 0 && values.Length % 2 == 0, "argument_shape_invalid");
    var result = new Dictionary<string, string>(StringComparer.Ordinal);
    for (var i = 0; i < values.Length; i += 2)
    {
        Require(values[i].StartsWith("--", StringComparison.Ordinal) &&
                result.TryAdd(values[i][2..], values[i + 1]), "argument_shape_invalid");
    }
    return result;
}

static string Required(IReadOnlyDictionary<string, string> values, string key)
{
    Require(values.TryGetValue(key, out var value) && !string.IsNullOrWhiteSpace(value), $"argument_{key}_missing");
    return value!;
}

static void RequireObject(JsonElement value, IEnumerable<string> allowed, IEnumerable<string> required, string code)
{
    Require(value.ValueKind == JsonValueKind.Object, code);
    var allowedSet = allowed.ToHashSet(StringComparer.Ordinal);
    var actual = value.EnumerateObject().Select(property => property.Name).ToHashSet(StringComparer.Ordinal);
    Require(actual.All(allowedSet.Contains) && required.All(actual.Contains), code);
}

static void EnsureNoDuplicateProperties(JsonElement value)
{
    if (value.ValueKind == JsonValueKind.Object)
    {
        var names = new HashSet<string>(StringComparer.Ordinal);
        foreach (var property in value.EnumerateObject())
        {
            Require(names.Add(property.Name), "source_duplicate_property");
            EnsureNoDuplicateProperties(property.Value);
        }
    }
    else if (value.ValueKind == JsonValueKind.Array)
    {
        foreach (var member in value.EnumerateArray()) EnsureNoDuplicateProperties(member);
    }
}

static long Integer(JsonElement value, string name)
{
    var property = value.GetProperty(name);
    Require(property.ValueKind == JsonValueKind.Number, "numeric_value_invalid");
    var parsed = property.TryGetInt64(out var result);
    Require(parsed, "numeric_value_invalid");
    return result;
}

static long PositiveLong(JsonElement value, string name)
{
    var result = Integer(value, name);
    Require(result > 0, "positive_value_invalid");
    return result;
}

static long NonnegativeLong(JsonElement value, string name)
{
    var result = Integer(value, name);
    Require(result >= 0, "nonnegative_value_invalid");
    return result;
}

static int PositiveInt(JsonElement value, string name, int maximum)
{
    var result = PositiveLong(value, name);
    Require(result <= maximum, "positive_value_invalid");
    return checked((int)result);
}

static int NonnegativeInt(JsonElement value, string name, int maximum)
{
    var result = NonnegativeLong(value, name);
    Require(result <= maximum, "nonnegative_value_invalid");
    return checked((int)result);
}

static int EquipmentPosition(ItemSubType subtype) => subtype switch
{
    ItemSubType.ModuleA => 0,
    ItemSubType.ModuleB => 1,
    ItemSubType.ModuleC => 2,
    ItemSubType.ModuleD => 3,
    _ => -1
};

static string Season26Shape(GameData data)
{
    var managers = data.SoloRaidManagerTable.Values.Where(value => value.RankingGroupId == 26).ToArray();
    if (managers.Length != 1) return $"season_manager_count-{managers.Length}";
    var manager = managers[0];
    var presets = data.SoloRaidPresetTable.Values.Where(value =>
        value.PresetGroupId == manager.MonsterPreset && (int)value.DifficultyType == 2 &&
        value.WaveOrder == SoloRaidManagerSelectionResolver.ChallengeRaidLevel).ToArray();
    if (presets.Length != 1) return $"season_preset_count-{presets.Length}";
    var preset = presets[0];
    if (!data.WaveIntercept001Table.TryGetValue(preset.Wave, out var wave)) return "season_wave_missing";
    var targets = wave.TargetList?.Count ?? 0;
    var waveGroups = wave.WaveData?.Count ?? 0;
    var spawns = wave.WaveData?.Sum(value => value.WaveMonsterList?.Count ?? 0) ?? 0;
    var waveLines = 5 + 1 + targets + 1 + (wave.WaveData?.Sum(value =>
        2 + 1 + 2 * (value.WaveMonsterList?.Count ?? 0)) ?? 0);
    var targetSet = (wave.TargetList ?? []).ToHashSet();
    targetSet.IntersectWith((wave.WaveData ?? []).SelectMany(value => value.WaveMonsterList ?? [])
        .Select(value => value.WaveMonsterId));
    if (targetSet.Count != 1 || !data.MonsterTable.TryGetValue(targetSet.Single(), out var monster))
        return $"season_wave_shape-{targets}-{waveGroups}-{spawns}-{waveLines}_monster_missing";
    var targetMonsterId = targetSet.Single();
    var waveRows = wave.WaveData ?? [];
    var targetWaveOrdinal = waveRows.FindIndex(value =>
        (value.WaveMonsterList ?? []).Any(monsterRow => monsterRow.WaveMonsterId == targetMonsterId));
    var targetWave = targetWaveOrdinal >= 0 ? waveRows[targetWaveOrdinal] : null;
    var targetSpawnOrdinal = targetWave is null ? -1 : (targetWave.WaveMonsterList ?? []).FindIndex(value =>
        value.WaveMonsterId == targetMonsterId);
    var activeSkills = (monster.SkillData ?? []).Where(value => value.SkillId != 0).ToArray();
    var monsterLines = 18 + (monster.ElementId?.Count ?? 0) + activeSkills.Sum(value =>
        3 + (value.UseFunctionIdSkill?.Count ?? 0) + (value.HurtFunctionIdSkill?.Count ?? 0));
    return $"season_wave_shape-{targets}-{waveGroups}-{spawns}-{waveLines}-{wave.MonsterCount}-{targetWaveOrdinal}-{targetSpawnOrdinal}-{targetWave?.PrivateMonsterCount ?? -1}-{targetWave?.WavePath?.Length ?? -1}_monster_shape-{activeSkills.Length}-{monsterLines}";
}

static ulong NewSyntheticAccountId()
{
    var bytes = RandomNumberGenerator.GetBytes(8);
    var value = BitConverter.ToUInt64(bytes) & 0x7fffffffffffffffUL;
    return value == 0 ? 1UL : value;
}

static string NewLauncherPassword() =>
    Convert.ToHexString(RandomNumberGenerator.GetBytes(10)).ToLowerInvariant();

static string LauncherPasswordHash(string password) =>
    Convert.ToHexString(MD5.HashData(Encoding.ASCII.GetBytes(password))).ToLowerInvariant();

static string HashFile(string path)
{
    using var stream = File.OpenRead(path);
    return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
}

static (long Length, string Sha256) Evidence(string path) =>
    (new FileInfo(path).Length, HashFile(path));

static void WriteAtomic(string path, string text)
{
    var temporary = path + ".tmp";
    Require(!File.Exists(temporary), "temporary_output_already_exists");
    File.WriteAllText(temporary, text, new UTF8Encoding(false));
    File.Move(temporary, path);
}

static string SerializeSourceFree<T>(T value) =>
    System.Text.Json.JsonSerializer.Serialize(value, new JsonSerializerOptions { WriteIndented = true }) + "\n";

static bool IsLowerHex(char value) => value is >= '0' and <= '9' or >= 'a' and <= 'f';

static void Require(bool condition, string code)
{
    if (!condition) throw new InvalidOperationException(code);
}

sealed record Capture(IReadOnlyList<RawRoster> Roster, IReadOnlyList<RawDetail> Details,
    RawOutpost Outpost, int IgnoredPacketCount);
sealed record RawRoster(long CharacterReference, int Level, int LimitBreak, int CoreLevel,
    long CombatPower, int CostumeId);
sealed record RawDetail(long CharacterReference, int Level, int LimitBreak, int CoreLevel,
    long CombatPower, int BondLevel, int Skill1Level, int Skill2Level, int BurstLevel,
    long CubeReference, int CubeLevel, long FavoriteReference, int FavoriteLevel, int CostumeId,
    IReadOnlyList<RawEquipment> Equipment);
sealed record RawEquipment(int Position, long DefinitionReference, int Tier, int Level, int Corporation,
    IReadOnlyList<long> OptionReferences);
sealed record RawOutpost(int SynchroLevel, IReadOnlyList<RawConsole> Consoles);
sealed record RawConsole(long DefinitionReference, int Level, long Experience);
