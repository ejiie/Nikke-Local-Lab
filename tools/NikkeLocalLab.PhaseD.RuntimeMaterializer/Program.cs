using System.Buffers.Binary;
using System.Globalization;
using System.Diagnostics.CodeAnalysis;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using EpinelPS;
using EpinelPS.Data;
using EpinelPS.Models;
using EpinelPS.Utils;
using Newtonsoft.Json;
using Npgsql;
using NikkeLocalLab.Application.ProfileManagement;

#pragma warning disable CS0612

const string ExpectedDecodedStaticDataSha256 =
    "925762cd3ef56601916b2e2ae58f929d4dd389055b0d8bcd2176e9abd9b29e69";

return await RunAsync(args);

static async Task<int> RunAsync(string[] arguments)
{
  try
  {
    await ExecuteAsync(arguments);
    return 0;
  }
  catch (Exception exception)
  {
    // Offline preparation diagnostics only: no exception message, row values,
    // source IDs, connection string or token is emitted.
    Console.Error.WriteLine(System.Text.Json.JsonSerializer.Serialize(new
    {
      preparationExceptionType = exception.GetType().FullName,
      preparationMethod = exception.TargetSite?.DeclaringType?.FullName,
      innerExceptionType = exception.InnerException?.GetType().FullName
    }));
    if (arguments.Contains("--export-boss-season-catalog", StringComparer.Ordinal))
    {
      var chain = new List<object>();
      for (Exception? cursor = exception; cursor is not null && chain.Count < 8; cursor = cursor.InnerException)
        chain.Add(new { type = cursor.GetType().FullName, method = cursor.TargetSite?.DeclaringType?.FullName });
      Console.Error.WriteLine(System.Text.Json.JsonSerializer.Serialize(new { catalogExceptionChain = chain }));
    }
    var failureCode = IsSafeFailureCode(exception.Message)
        ? exception.Message
        : "phase_d_materializer_uncontrolled_failure";
    Console.Error.WriteLine(failureCode);
    return 1;
  }
}

static bool IsSafeFailureCode(string value) =>
    value.Length is >= 3 and <= 128 &&
    value.StartsWith("phase_d_", StringComparison.Ordinal) &&
    value.All(static character =>
        character is >= 'a' and <= 'z' or >= '0' and <= '9' or '_' or '.' or '-');

static async Task ExecuteAsync(string[] args)
{
var options = ParseArguments(args);
if (options.ContainsKey("retire-execution-fx"))
{
  NikkeLocalLab.Automation.ExecutionAssetRetirement.Retire(Required(options, "launch-root"),
      RequiredText(options, "expected-bundle-sha256"), RequiredText(options, "expected-termination-sha256"));
  Console.WriteLine("{\"contractId\":\"nll/execution-fx-cleanup/v1\",\"statusCode\":\"private_delivery_retired\"}");
  return;
}
if (options.ContainsKey("verify-boss-qte"))
{
  BossQuickTimeEventChecks.Run();
  return;
}
if (options.ContainsKey("verify-runtime-persistence-integration"))
{
  await RuntimePersistenceIntegrationChecks.RunAsync(options);
  return;
}
if (options.ContainsKey("verify-runtime-persistence"))
{
  RuntimePersistenceChecks.Run();
  return;
}
if (options.ContainsKey("verify-runtime-migration"))
{
  RuntimeMigrationChecks.Run();
  return;
}
if (options.ContainsKey("inspect-static-pack"))
{
  var packPath = Required(options, "static-pack");
  Require(HashFile(packPath) == RequiredText(options, "expected-pack-sha256"),
      "phase_d_staticdata_pack_hash_mismatch");
  var configPath = Required(options, "game-config");
  Require(HashFile(configPath) == RequiredText(options, "expected-config-sha256"),
      "phase_d_staticdata_config_hash_mismatch");
  var consoleOutput = Console.Out;
  using var captured = new StringWriter(CultureInfo.InvariantCulture);
  GameData inspected;
  try
  {
    Console.SetOut(captured);
    // Explicit local constructor verifies the embedded RSA signature. Never call
    // GameData.Load(), which can invoke the external asset downloader.
    inspected = await LoadStaticDataForInspectionAsync(packPath, configPath);
  }
  finally { Console.SetOut(consoleOutput); }
  var messages = captured.ToString();
  var parseErrors = System.Text.RegularExpressions.Regex.Matches(messages, "Failed to parse ").Count;
  var missingTables = System.Text.RegularExpressions.Regex.Matches(messages, " does not exist in static data").Count;
  var populatedTables = typeof(GameData).GetFields(BindingFlags.Public | BindingFlags.Instance)
      .Select(field => field.GetValue(inspected)).OfType<System.Collections.IDictionary>()
      .Count(dictionary => dictionary.Count > 0);
  var decoded = (MemoryStream?)typeof(GameData).GetField("ZipStream", BindingFlags.NonPublic | BindingFlags.Instance)?.GetValue(inspected);
  Require(decoded is not null, "phase_d_staticdata_archive_binding_unavailable");
  var decodedPosition = decoded!.Position;
  decoded.Position = 0;
  var decodedHash = LowerHex(SHA256.HashData(decoded));
  decoded.Position = decodedPosition;
  Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(new
  {
    contractId = "nll/static-pack-offline-inspection/v1",
    packSha256 = HashFile(packPath), configSha256 = HashFile(configPath),
    embeddedSignatureVerified = true, parseErrorCount = parseErrors, missingTableCount = missingTables,
    populatedTableCount = populatedTables,
    characterCount = inspected.CharacterTable.Count, equipmentCount = inspected.ItemEquipTable.Count,
    cubeCount = inspected.ItemHarmonyCubeTable.Count, monsterCount = inspected.MonsterTable.Count,
    soloRaidManagerCount = inspected.SoloRaidManagerTable.Count, soloRaidPresetCount = inspected.SoloRaidPresetTable.Count,
    decodedArchiveSha256 = decodedHash,
    originalDataEmitted = false, databaseChanged = false, nativeReadiness = "not_evaluated"
  }));
  Require(parseErrors == 0 && missingTables == 0, "phase_d_staticdata_table_parse_incomplete");
  return;
}
if (ClassicSoloRaidRuntimeState.IsVerifyBindingMode(options))
{
  await ClassicSoloRaidRuntimeState.VerifyOperationalBindingAsync(options);
  return;
}
if (ClassicSoloRaidRuntimeState.IsCaptureMode(options))
{
  await ClassicSoloRaidRuntimeState.CaptureAsync(options);
  return;
}
if (ClassicSoloRaidRuntimeState.IsPersistMode(options))
{
  await ClassicSoloRaidRuntimeState.PersistAsync(options);
  return;
}
if (options.ContainsKey("export-static-data"))
{
  ExportDecodedStaticData(
      Required(options, "static-pack"),
      Required(options, "game-config"),
      Required(options, "export-static-data"));
  return;
}
if (options.ContainsKey("enrich-cube-presentation"))
{
  var cubeData = await LoadStaticDataForInspectionAsync(Required(options, "static-pack"), Required(options, "game-config"));
  var document = System.Text.Json.Nodes.JsonNode.Parse(await File.ReadAllTextAsync(Required(options, "presentation-input")))!;
  Require(document["contractId"]?.GetValue<string>() == "nll/control-center-presentation/v1", "phase_d_presentation_input_invalid");
  var definitions = document["supportDefinitions"]!.AsArray();
  var plans = new List<PresentationSupportAssetPlan>();
  for (var index = 0; index < definitions.Count; index++)
  {
    var entry = definitions[index]!;
    if (entry["kindCode"]?.GetValue<string>() != "cube") continue;
    var uid = entry["definitionUid"]!.GetValue<string>();
    var name = entry["displayName"]!.GetValue<string>();
    var cube = cubeData.ItemHarmonyCubeTable.Values.Single(row => ResolveLocale(row.NameLocalkey, "") == name);
    definitions[index] = System.Text.Json.JsonSerializer.SerializeToNode(CubePresentation.Build(cubeData, cube, uid));
    plans.Add(new PresentationSupportAssetPlan(uid, "cubes", $"icon/equip/ie_{cube.ResourceId}.webp"));
  }
  Require(plans.Count == cubeData.ItemHarmonyCubeTable.Count, "phase_d_presentation_cube_catalog_incomplete");
  await ExportPresentationSupportAssetsAsync(Required(options, "presentation-support-asset-root"), plans);
  await WriteAtomicAsync(Required(options, "enrich-cube-presentation"), document.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
  Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(new { cubeCount = plans.Count, levelsPerCube = 15 }));
  return;
}
if (options.ContainsKey("inspect-cube-catalog"))
{
  var cubeData = await LoadStaticDataForInspectionAsync(
      Required(options, "static-pack"), Required(options, "game-config"));
  Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(
      cubeData.ItemHarmonyCubeTable.Values.OrderBy(cube => cube.Order).Select(cube => new
      {
        name = ResolveLocale(cube.NameLocalkey, "하모니 큐브"),
        description = ResolveLocale(cube.DescriptionLocalkey, ""),
        functions = cubeData.FunctionRecords.Values.Where(function =>
            function.GroupId == cube.HarmonycubeSkillGroup[0].SkillGroupId && function.Level == 1)
            .Select(function => new { type = function.FunctionType.ToString(), unit = function.FunctionValueType.ToString(), value = function.FunctionValue }),
        levels = cubeData.ItemHarmonyCubeLevelTable.Values
            .Where(level => level.LevelEnhanceId == cube.LevelEnhanceId)
            .OrderBy(level => level.Level).Where(level => level.Level is 1 or 3 or 7 or 15)
            .Select(level => new
            {
              level = level.Level,
              skills = cube.HarmonycubeSkillGroup.Select((group, index) => new
              {
                skillLevel = level.SkillLevels[index].SkillLevel,
                info = cubeData.skillInfoTable.Values.Where(skill => skill.GroupId == group.SkillGroupId &&
                    skill.SkillLevel == level.SkillLevels[index].SkillLevel).Select(skill => new
                {
                  name = ResolveLocale(skill.NameLocalkey, ""),
                  description = ResolveLocale(skill.DescriptionLocalkey, ""),
                  values = skill.DescriptionValueList.Select(value => value.DescriptionValue)
                })
              })
            })
      })));
  return;
}
if (options.ContainsKey("verify-boss-season-catalog"))
{
  Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(BossSeasonCatalogChecks.Verify()));
  return;
}
if (options.ContainsKey("export-boss-season-catalog"))
{
  AssetDownloadUtil.ConfigureOfficialOutbound(false);
  var catalogPackHash = HashFile(Required(options, "static-pack"));
  var catalogConfigHash = HashFile(Required(options, "game-config"));
  var catalogData = await LoadStaticDataForInspectionAsync(Required(options, "static-pack"), Required(options, "game-config"));
  Require(HashFile(Required(options, "game-config")) == catalogConfigHash, "phase_d_boss_catalog_input_drifted");
  BossSeasonCatalog.Export(catalogData, Required(options, "static-pack"), Required(options, "locale-root"),
      Required(options, "export-boss-season-catalog"), catalogPackHash);
  return;
}
if (options.ContainsKey("discover-boss-content"))
{
  var discoveryGameData = await LoadStaticDataForInspectionAsync(
      Required(options, "static-pack"),
      Required(options, "game-config"));
  await BossContentDiscovery.WriteAsync(
      discoveryGameData,
      RequiredPositiveIntegerOption(options, "season-number"),
      RequiredText(options, "profile-code"),
      RequiredText(options, "display-name-code"),
      Required(options, "discover-boss-content"),
      options.TryGetValue("private-discovery-output", out var privateDiscoveryOutput)
          ? Path.GetFullPath(privateDiscoveryOutput)
          : null);
  return;
}
if (options.ContainsKey("validate-boss-variant-profile"))
{
  var profile = await BossRuntimeVariantProfile.LoadAsync(
      Required(options, "validate-boss-variant-profile"));
  Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(new
  {
    schemaVersion = 1,
    contractId = "nll/boss-runtime-variant-profile-validation/v1",
    profileCode = profile.ProfileCode,
    seasonNumber = profile.SeasonNumber,
    profileSha256 = profile.Sha256,
    skillClosureResolved = profile.SkillClosure is not null,
    behaviorAssemblyResolved = profile.BehaviorAssembly is not null,
    elementShieldModeCode = profile.ElementShield.ModeCode,
    rawSourceIdentifiersPersisted = false
  }));
  return;
}
if (options.ContainsKey("inspect-boss-target-observation"))
{
  var observationGameData = await LoadStaticDataForInspectionAsync(
      Required(options, "static-pack"),
      Required(options, "game-config"));
  var profile = await BossRuntimeVariantProfile.LoadAsync(
      Required(options, "inspect-boss-target-observation"));
  Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(
      BossAffinityStaticDataVariant.InspectTargetObservation(
          observationGameData,
          profile)));
  return;
}
if (options.ContainsKey("create-static-data-variant"))
{
  var variantSourceDatabasePath = Required(options, "source-db");
  Require(File.Exists(variantSourceDatabasePath), "phase_d_source_database_missing");
  AssetDownloadUtil.ConfigureOfficialOutbound(false);
  var variantGameData = await LoadStaticDataForInspectionAsync(
      Required(options, "source-static-pack"),
      Required(options, "game-config"));
  var source = JsonConvert.DeserializeObject<CoreInfo>(await File.ReadAllTextAsync(variantSourceDatabasePath)) ??
      throw new InvalidOperationException("phase_d_source_database_invalid");
  Require(source.Users.Count == 1, "phase_d_source_user_cardinality_invalid");
  var variantProfile = await BossRuntimeVariantProfile.LoadAsync(
      Required(options, "boss-variant-profile"));
  var result = await BossAffinityStaticDataVariant.CreateAsync(
      variantGameData,
      source.Users[0],
      variantProfile,
      RequiredText(options, "weakness-code"),
      Required(options, "source-static-pack"),
      Required(options, "variant-static-pack"),
      Required(options, "variant-static-data-receipt"));
  Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(result));
  return;
}
if (options.ContainsKey("prepare-user-validation-account"))
{
  await PrepareUserValidationAccountAsync(options);
  return;
}
if (options.ContainsKey("export-presentation-catalog"))
{
  var connectionName = RequiredText(options, "connection-string-env");
  var secretName = RequiredText(options, "identity-secret-env");
  var connection = Environment.GetEnvironmentVariable(connectionName);
  var secretValue = Environment.GetEnvironmentVariable(secretName);
  Require(!string.IsNullOrWhiteSpace(connection), "phase_d_database_environment_missing");
  Require(!string.IsNullOrWhiteSpace(secretValue), "phase_d_identity_environment_missing");
  byte[] presentationSecret;
  try { presentationSecret = Convert.FromBase64String(secretValue!); }
  catch (FormatException) { throw new InvalidOperationException("phase_d_identity_secret_invalid"); }
  Require(presentationSecret.Length >= 32, "phase_d_identity_secret_invalid");
  try
  {
    await ExportPresentationCatalogAsync(
        Required(options, "export-presentation-catalog"),
        connection!,
        presentationSecret,
        options.TryGetValue("presentation-support-asset-root", out var assetRoot)
            ? Path.GetFullPath(assetRoot)
            : null);
  }
  finally { CryptographicOperations.ZeroMemory(presentationSecret); }
  return;
}
var candidatePath = Required(options, "candidate");
var lobbyPath = Required(options, "lobby");
var sourceDatabasePath = Required(options, "source-db");
var outputDatabasePath = Required(options, "output-db");
var receiptPath = Required(options, "receipt");
var connectionEnvironmentVariable = RequiredText(options, "connection-string-env");
var secretEnvironmentVariable = RequiredText(options, "identity-secret-env");

Require(File.Exists(candidatePath), "phase_d_candidate_missing");
Require(File.Exists(lobbyPath), "phase_d_lobby_missing");
Require(File.Exists(sourceDatabasePath), "phase_d_source_database_missing");
Require(!File.Exists(outputDatabasePath) && !File.Exists(receiptPath), "phase_d_output_exists");
var connectionString = Environment.GetEnvironmentVariable(connectionEnvironmentVariable);
var secretText = Environment.GetEnvironmentVariable(secretEnvironmentVariable);
Require(!string.IsNullOrWhiteSpace(connectionString), "phase_d_database_environment_missing");
Require(!string.IsNullOrWhiteSpace(secretText), "phase_d_identity_environment_missing");

byte[] identitySecret;
try
{
  identitySecret = Convert.FromBase64String(secretText!);
}
catch (FormatException)
{
  throw new InvalidOperationException("phase_d_identity_secret_invalid");
}
Require(identitySecret.Length >= 32, "phase_d_identity_secret_invalid");

try
{
  var jsonOptions = PhaseDExecutionDocumentJson.CreateOptions();
  var candidate = System.Text.Json.JsonSerializer.Deserialize<PhaseDRuntimeCandidateDocument>(
      await File.ReadAllTextAsync(candidatePath), jsonOptions) ??
      throw new InvalidOperationException("phase_d_candidate_invalid");
  var lobby = System.Text.Json.JsonSerializer.Deserialize<PhaseDLobbyDocument>(
      await File.ReadAllTextAsync(lobbyPath), jsonOptions) ??
      throw new InvalidOperationException("phase_d_lobby_invalid");
  var accountUidParsed = Guid.TryParse(candidate.AccountUid, out var accountUid);
  Require(candidate.SchemaVersion == 1 &&
          candidate.ContractId == "nll/runtime-projection-candidate/v1" &&
          accountUidParsed && accountUid != Guid.Empty &&
          candidate.BaseRevisions.RevisionSetSha256.Length == 64 &&
          candidate.Values.Count > 0,
      "phase_d_candidate_invalid");
  Require(lobby.SchemaVersion == 1 && lobby.ContractId == "nll/phase-d-lobby-projection/v1" &&
          lobby.AccountUid == candidate.AccountUid && lobby.CommanderLevel is >= 1 and <= 1_000_000 &&
          !string.IsNullOrWhiteSpace(lobby.DisplayName) && lobby.DisplayName.Length <= 32,
      "phase_d_lobby_invalid");
  Require(candidate.Values.All(value => value.Status is "ready" or "not_applicable"),
      "phase_d_candidate_contains_unresolved_value");

  AssetDownloadUtil.ConfigureOfficialOutbound(false);
  await GameData.CreateAsync();
  var decodedArchiveField = typeof(GameData).GetField(
      "ZipStream", BindingFlags.Instance | BindingFlags.NonPublic);
  var decodedArchive = decodedArchiveField?.GetValue(GameData.Instance) as MemoryStream;
  Require(decodedArchive is not null, "phase_d_staticdata_binding_unavailable");
  var decodedSha256 = LowerHex(SHA256.HashData(decodedArchive!.ToArray()));
  var expectedRuntimeStaticData = RuntimeVersionBinding.ExpectedArchive(
      RequiredText(options, "client-build-code"),
      RequiredText(options, "client-executable-sha256"));
  Require(decodedSha256 == expectedRuntimeStaticData, "phase_d_staticdata_drifted");

  await using var dataSource = NpgsqlDataSource.Create(connectionString!);
  var aliasRows = await ReadAliasRowsAsync(dataSource);
  VerifyIdentityKey(identitySecret, aliasRows.CharacterKeyCheck, aliasRows.SupportKeyCheck);
  var mappings = BuildMappings(identitySecret, aliasRows);

  var core = JsonConvert.DeserializeObject<CoreInfo>(
      await File.ReadAllTextAsync(sourceDatabasePath)) ??
      throw new InvalidOperationException("phase_d_source_database_invalid");
  Require(core.Users.Count == 1, "phase_d_source_user_cardinality_invalid");
  var user = core.Users[0];
  var sourceProgression = RuntimeProgressionSnapshot.Capture(user);
  Materialize(user, candidate, lobby, mappings);
  var preferenceCharacterUids = new Dictionary<long, string>();
  foreach (var character in user.Characters)
  {
    if (GameData.Instance.CharacterTable.TryGetValue(character.Tid, out var row) &&
        mappings.CharacterUidByNameCode.TryGetValue(row.NameCode, out var uid))
      preferenceCharacterUids.Add(character.Csn, uid);
  }
  var preferencesHeadUid = await RuntimePreferencesPersistence.RestoreAsync(user, dataSource, identitySecret,
      new NikkeLocalLab.Persistence.PostgreSql.RuntimePreferencesKey(accountUid,
          RequiredText(options, "client-build-code"), Convert.FromHexString(RequiredText(options, "client-executable-sha256"))),
      candidate.BaseRevisions.RevisionSetSha256, RequiredText(options, "weakness-code"), preferenceCharacterUids);
  var operationalSoloRaidBinding =
      await ClassicSoloRaidRuntimeState.ResolveOperationalBindingAsync(
          dataSource,
          options,
          accountUid);
  var restoredSoloRaidState = await ClassicSoloRaidRuntimeState.RestoreAsync(
      user,
      dataSource,
      identitySecret,
      options,
      accountUid,
       operationalSoloRaidBinding,
       Convert.FromHexString(candidate.BaseRevisions.RevisionSetSha256));
  var variantProfile = await BossRuntimeVariantProfile.LoadAsync(
      Required(options, "boss-variant-profile"));
  Require(variantProfile.SeasonNumber == operationalSoloRaidBinding.SeasonNumber,
      "phase_d_boss_variant_profile_season_mismatch");
  var staticDataVariant = await BossAffinityStaticDataVariant.CreateAsync(
      GameData.Instance,
      user,
      variantProfile,
      RequiredText(options, "weakness-code"),
      Required(options, "source-static-pack"),
      Required(options, "variant-static-pack"),
      Required(options, "variant-static-data-receipt"));

  Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(outputDatabasePath))!);
  await WriteAtomicAsync(
      outputDatabasePath,
      JsonConvert.SerializeObject(core, Formatting.Indented) + "\n");
  var roundTrip = JsonConvert.DeserializeObject<CoreInfo>(
      await File.ReadAllTextAsync(outputDatabasePath));
  Require(roundTrip is not null && roundTrip.Users.Count == 1 &&
          roundTrip.Users[0].Characters.Count == user.Characters.Count &&
          roundTrip.Users[0].Nickname == lobby.DisplayName &&
          roundTrip.Users[0].userPointData.UserLevel == lobby.CommanderLevel,
      "phase_d_output_roundtrip_invalid");
  Require(sourceProgression == RuntimeProgressionSnapshot.Capture(roundTrip!.Users[0]),
      "phase_d_progression_changed_during_materialization");

  var receipt = new
  {
    schemaVersion = 1,
    contractId = "nll/phase-d-runtime-materialization/v1",
    materializedAtUtc = DateTimeOffset.UtcNow,
    accountUid = candidate.AccountUid,
    accountRevisionSetSha256 = candidate.BaseRevisions.RevisionSetSha256,
    candidateSha256 = candidate.CandidateSha256,
    sourceDatabaseSha256 = HashFile(sourceDatabasePath),
    runtimeDatabaseSha256 = HashFile(outputDatabasePath),
    characterCount = user.Characters.Count,
    equipmentCount = user.Items.Count(item => GameData.Instance.ItemEquipTable.ContainsKey(item.ItemType)),
    cubeCount = user.Items.Count(item => GameData.Instance.ItemHarmonyCubeTable.ContainsKey(item.ItemType)),
    favoriteCount = user.FavoriteItems.Count,
    consoleCount = user.ResearchProgress.Count,
    commanderLevel = user.userPointData.UserLevel,
    progressionPreserved = true,
    preferencesHeadRevisionUid = preferencesHeadUid,
    progressionSha256 = sourceProgression,
    tutorialGroupCount = user.ClearedTutorialDataNew.Count,
    completedScenarioCount = user.CompletedScenarios.Count,
    raidSeasonNumber = operationalSoloRaidBinding.SeasonNumber,
    raidSnapshotUid = operationalSoloRaidBinding.RaidSnapshotUid,
    raidSnapshotSha256 = LowerHex(operationalSoloRaidBinding.RaidSnapshotSha256),
    bossVariantProfileCode = staticDataVariant.VariantProfileCode,
    bossVariantProfileSha256 = staticDataVariant.VariantProfileSha256,
    raidWeaknessCode = staticDataVariant.WeaknessCode,
    sourceBossElementCode = staticDataVariant.SourceBossElementCode,
    sourceBossWeaknessCode = staticDataVariant.SourceBossWeaknessCode,
    targetBossElementCode = staticDataVariant.TargetBossElementCode,
    staticDataVariantRequired = staticDataVariant.VariantRequired,
    staticDataVariantSha256 = staticDataVariant.VariantSha256,
    soloRaidStateAvailable = restoredSoloRaidState.StateAvailable,
    soloRaidStateRestored = restoredSoloRaidState.StateRestored,
    soloRaidStateHeadRevisionUid = restoredSoloRaidState.HeadRevisionUid,
    soloRaidStateContentSha256 = restoredSoloRaidState.StateContentSha256,
    soloRaidCompletedBestTotalDamage = restoredSoloRaidState.CompletedBestTotalDamage,
    soloRaidCompletedBestTeamCount = restoredSoloRaidState.CompletedBestTeamCount,
    soloRaidOpenTeamCount = restoredSoloRaidState.OpenTeamCount,
    soloRaidOpenRunRestored = restoredSoloRaidState.OpenRunRestored,
    soloRaidInheritedCompletedRecordFromBuild = restoredSoloRaidState.InheritedCompletedRecordFromBuild,
    soloRaidInheritedSourceRevisionUid = restoredSoloRaidState.InheritedSourceRevisionUid,
    soloRaidOpenRunDiscardedForProfileRevisionMismatch =
        restoredSoloRaidState.OpenRunDiscardedForProfileRevisionMismatch,
    soloRaidLegacyPartialCompletionDiscarded =
        restoredSoloRaidState.LegacyPartialCompletionDiscarded,
    identitySecretPersisted = false,
    rawSourceIdentifierPersisted = false,
    sourceDatabaseModified = false,
    officialOutboundUsed = false
  };
  await WriteAtomicAsync(
      receiptPath,
      System.Text.Json.JsonSerializer.Serialize(
          receipt,
          new JsonSerializerOptions { WriteIndented = true }) + "\n");
  Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(receipt));
}
finally
{
  CryptographicOperations.ZeroMemory(identitySecret);
}
}

static void Materialize(
    User user,
    PhaseDRuntimeCandidateDocument candidate,
    PhaseDLobbyDocument lobby,
    RuntimeMappings mappings)
{
  var values = candidate.Values.ToDictionary(
      value => (value.FieldCode, value.SubjectUid ?? ""),
      value => value);
  user.Nickname = lobby.DisplayName;
  user.PlayerName = lobby.DisplayName;
  user.userPointData.UserLevel = lobby.CommanderLevel;
  user.SynchroDeviceLevel = CheckedInteger(RequiredValue(values, "synchro_level", null));

  var characterSubjects = candidate.Values
      .Where(value => value.SubjectUid is not null && value.FieldCode == "character_level")
      .Select(value => value.SubjectUid!)
      .Distinct(StringComparer.Ordinal)
      .Order(StringComparer.Ordinal)
      .ToArray();
  var nextCsn = user.Characters.Count == 0 ? 1 : user.Characters.Max(item => item.Csn) + 1;
  var nextIsn = user.Items.Count == 0 ? 100_000L : user.Items.Max(item => item.Isn) + 1;
  var nextFavoriteId = user.FavoriteItems.Count == 0
      ? 200_000L
      : user.FavoriteItems.Max(item => item.FavoriteItemId) + 1;

  foreach (var subject in characterSubjects)
  {
    Require(mappings.CharacterNameCodeByUid.TryGetValue(subject, out var nameCode),
        "phase_d_character_mapping_missing");
    var variants = GameData.Instance.CharacterTable.Values
        .Where(row => row.IsVisible && row.NameCode == nameCode)
        .OrderBy(row => row.GradeCoreId)
        .ToArray();
    Require(variants.Length > 0, "phase_d_character_variant_missing");
    var character = user.Characters.SingleOrDefault(item =>
        GameData.Instance.CharacterTable.TryGetValue(item.Tid, out var row) && row.NameCode == nameCode);
    if (character is null)
    {
      character = new CharacterModel { Csn = nextCsn++ };
      user.Characters.Add(character);
    }

    var limitBreak = CheckedInteger(RequiredValue(values, "limit_break", subject));
    var coreLevel = IntegerOrZeroWhenNotApplicable(values, "core_level", subject);
    var expectedGrade = checked(variants[0].GradeCoreId + limitBreak + coreLevel);
    var selected = variants.SingleOrDefault(row => row.GradeCoreId == expectedGrade);
    Require(selected is not null, "phase_d_character_grade_mapping_missing");
    character.Tid = selected!.Id;
    character.Grade = selected.GradeCoreId;
    // The editable local profile uses one effective synchro level for every
    // roster character. Preserve the per-character coordinate as a required
    // source fact, but project the configured synchro level into runtime.
    _ = CheckedInteger(RequiredValue(values, "character_level", subject));
    character.Level = user.SynchroDeviceLevel;
    character.Skill1Lvl = CheckedInteger(RequiredValue(values, "skill_1_level", subject));
    character.Skill2Lvl = CheckedInteger(RequiredValue(values, "skill_2_level", subject));
    character.UltimateLevel = CheckedInteger(RequiredValue(values, "burst_level", subject));

    var bond = IntegerOrZeroWhenNotApplicable(values, "bond_level", subject);
    user.BondInfo.RemoveAll(item => item.NameCode == nameCode);
    if (bond > 0)
    {
      user.BondInfo.Add(new NetUserAttractiveData { NameCode = nameCode, Lv = bond, Exp = 0 });
    }

    foreach (var (slotCode, position) in new[]
    {
      ("head", 0), ("torso", 1), ("arms", 2), ("legs", 3)
    })
    {
      var prefix = $"equipment.{slotCode}";
      var state = RequiredValue(values, $"{prefix}.state", subject).ControlledValue;
      var existing = user.Items.SingleOrDefault(item => item.Csn == character.Csn && item.Position == position &&
          GameData.Instance.ItemEquipTable.ContainsKey(item.ItemType));
      if (state == "unequipped")
      {
        if (existing is not null)
        {
          user.EquipmentAwakenings.RemoveAll(item => item.Isn == existing.Isn);
          user.Items.Remove(existing);
        }
        continue;
      }
      Require(state == "equipped", "phase_d_equipment_state_invalid");
      var definitionUid = RequiredValue(values, $"{prefix}.definition", subject).ReferenceUid;
      Require(definitionUid is not null, "phase_d_equipment_mapping_missing");
      Require(mappings.SupportRawIdByUid.TryGetValue(definitionUid, out var itemTid),
          "phase_d_equipment_mapping_missing");
      Require(GameData.Instance.ItemEquipTable.TryGetValue(itemTid, out var itemDefinition),
          "phase_d_equipment_mapping_missing");
      var item = existing ?? new DbItemData
      {
        Csn = character.Csn,
        Count = 1,
        Position = position,
        Isn = nextIsn++
      };
      if (existing is null) user.Items.Add(item);
      item.ItemType = itemTid;
      item.Level = CheckedInteger(RequiredValue(values, $"{prefix}.enhancement_level", subject));
      item.Exp = 0;
      var matched = BooleanOrFalseWhenNotApplicable(
          values,
          $"{prefix}.manufacturer_matched",
          subject);
      // Tier 10/Overload equipment has no manufacturer designation in the
      // original client. Keep the wire value neutral even when an older editor
      // revision left a stale ready:true manufacturer fact in the profile.
      item.Corp = (int)itemDefinition!.ItemRare == 10
          ? 0
          : matched ? (int)selected.Corporation : 0;

      var optionIds = new int[3];
      for (var line = 1; line <= 3; line++)
      {
        var linePrefix = $"{prefix}.overload.{line}";
        var lineState = RequiredValue(values, $"{linePrefix}.state", subject).ControlledValue;
        if (lineState == "absent") continue;
        Require(lineState == "present", "phase_d_overload_state_invalid");
        var definition = RequiredValue(values, $"{linePrefix}.definition", subject).ReferenceUid;
        var exact = RequiredValue(values, $"{linePrefix}.value", subject);
        Require(definition is not null && exact.UnscaledValue is not null && exact.DecimalScale is not null &&
                mappings.OverloadRawIdByValue.TryGetValue(
                    (definition, exact.UnscaledValue.Value, exact.DecimalScale.Value), out optionIds[line - 1]),
            "phase_d_overload_value_mapping_missing");
      }
      user.EquipmentAwakenings.RemoveAll(value => value.Isn == item.Isn);
      if (optionIds.Any(value => value != 0))
      {
        user.EquipmentAwakenings.Add(new EquipmentAwakeningData
        {
          Isn = item.Isn,
          IsNewData = false,
          Option = new NetEquipmentAwakeningOption
          {
            Option1Id = optionIds[0],
            Option2Id = optionIds[1],
            Option3Id = optionIds[2]
          }
        });
      }
    }

    foreach (var cube in user.Items.Where(item => item.CsnList.Contains(character.Csn)).ToArray())
    {
      cube.CsnList.Remove(character.Csn);
    }
    var cubeState = RequiredValue(values, "cube.state", subject).ControlledValue;
    if (cubeState == "equipped")
    {
      var cubeUid = RequiredValue(values, "cube.definition", subject).ReferenceUid;
      Require(cubeUid is not null, "phase_d_cube_mapping_missing");
      Require(mappings.SupportRawIdByUid.TryGetValue(cubeUid, out var cubeTid),
          "phase_d_cube_mapping_missing");
      Require(GameData.Instance.ItemHarmonyCubeTable.TryGetValue(cubeTid, out var cubeDefinition),
          "phase_d_cube_mapping_missing");
      var cubeLevel = CheckedInteger(RequiredValue(values, "cube.level", subject));
      var matchingCubeItems = user.Items
          .Where(item => item.ItemType == cubeTid && item.Csn == 0)
          .OrderBy(item => item.Isn)
          .ToArray();
      var cubeItem = matchingCubeItems.FirstOrDefault(item => item.Level == cubeLevel) ??
          matchingCubeItems.FirstOrDefault();
      if (cubeItem is null)
      {
        cubeItem = new DbItemData
        {
          ItemType = cubeTid,
          Csn = 0,
          Count = 1,
          Level = cubeLevel,
          Exp = 0,
          Position = cubeDefinition!.LocationId,
          Corp = 0,
          Isn = nextIsn++
        };
        user.Items.Add(cubeItem);
      }
      else
      {
        cubeItem.Level = cubeLevel;
        foreach (var duplicate in matchingCubeItems.Where(item => item != cubeItem))
        {
          foreach (var assignedCsn in duplicate.CsnList)
          {
            if (!cubeItem.CsnList.Contains(assignedCsn))
            {
              cubeItem.CsnList.Add(assignedCsn);
            }
          }
          user.Items.Remove(duplicate);
        }
      }
      cubeItem.CsnList.Add(character.Csn);
    }
    else
    {
      Require(cubeState == "unequipped", "phase_d_cube_state_invalid");
    }

    user.FavoriteItems.RemoveAll(item => item.Csn == character.Csn);
    var collectionKind = RequiredValue(values, "collection.kind", subject).ControlledValue;
    if (collectionKind is "generic_collection" or "favorite")
    {
      var collectionUid = RequiredValue(values, "collection.definition", subject).ReferenceUid;
      Require(collectionUid is not null, "phase_d_collection_mapping_missing");
      Require(mappings.SupportRawIdByUid.TryGetValue(collectionUid, out var favoriteTid),
          "phase_d_collection_mapping_missing");
      Require(GameData.Instance.FavoriteItemTable.ContainsKey(favoriteTid),
          "phase_d_collection_mapping_missing");
      user.FavoriteItems.Add(new NetUserFavoriteItemData
      {
        FavoriteItemId = nextFavoriteId++,
        Tid = favoriteTid,
        Csn = character.Csn,
        Lv = CheckedInteger(RequiredValue(values, "collection.level", subject)),
        Exp = 0
      });
    }
    else
    {
      Require(collectionKind is "detached" or "not_applicable", "phase_d_collection_state_invalid");
    }
  }

  var ownedCubeValues = candidate.Values.Where(value => value.FieldCode == "account_cube_level").ToArray();
  var ownedCubeLevels = new Dictionary<int, int>();
  foreach (var value in ownedCubeValues)
  {
    Require(value.SubjectUid is not null && mappings.SupportRawIdByUid.ContainsKey(value.SubjectUid),
        "phase_d_account_cube_mapping_missing");
    var rawId = mappings.SupportRawIdByUid[value.SubjectUid!];
    var level = CheckedInteger(value);
    Require(GameData.Instance.ItemHarmonyCubeTable.TryGetValue(rawId, out var definition) &&
        GameData.Instance.ItemHarmonyCubeLevelTable.Values.Any(row =>
            row.LevelEnhanceId == definition.LevelEnhanceId && row.Level == level) &&
        level is >= 1 and <= 15 && ownedCubeLevels.TryAdd(rawId, level),
        "phase_d_account_cube_inventory_invalid");
  }
  Require(ownedCubeLevels.Count == 0 || ownedCubeLevels.Count == GameData.Instance.ItemHarmonyCubeTable.Count,
      "phase_d_account_cube_inventory_incomplete");
  foreach (var definition in GameData.Instance.ItemHarmonyCubeTable.Values)
  {
    var existing = user.Items.Where(item => item.ItemType == definition.Id && item.Csn == 0)
        .OrderBy(item => item.Isn).ToArray();
    var level = ownedCubeLevels.GetValueOrDefault(definition.Id,
        existing.Length > 0 ? existing.Max(item => item.Level) : 15);
    var item = existing.FirstOrDefault();
    if (item is null)
    {
      item = new DbItemData { ItemType = definition.Id, Isn = nextIsn++, Csn = 0, Count = 1,
          Level = level, Exp = 0, Corp = 0, Position = definition.LocationId };
      user.Items.Add(item);
    }
    item.Level = level;
    item.Count = 1;
    foreach (var duplicate in existing.Skip(1))
    {
      foreach (var csn in duplicate.CsnList)
        if (!item.CsnList.Contains(csn)) item.CsnList.Add(csn);
      user.Items.Remove(duplicate);
    }
  }

  foreach (var consoleValue in candidate.Values.Where(value => value.FieldCode == "console_level"))
  {
    Require(consoleValue.SubjectUid is not null, "phase_d_console_mapping_missing");
    Require(mappings.SupportRawIdByUid.TryGetValue(consoleValue.SubjectUid, out var tid),
        "phase_d_console_mapping_missing");
    Require(GameData.Instance.RecycleResearchStats.TryGetValue(tid, out var stat),
        "phase_d_console_mapping_missing");
    var level = CheckedInteger(consoleValue);
    user.ResearchProgress[tid] = new RecycleRoomResearchProgress
    {
      Level = level,
      Attack = checked(stat!.Attack * level),
      Defense = checked(stat.Defence * level),
      Hp = checked(stat.Hp * level)
    };
  }

  var legalOverloadStateEffectIds = GameData.Instance.EquipmentOptionTable.Values
      .SelectMany(option => option.StateEffectList ?? [])
      .Select(stateEffect => stateEffect.StateEffectId)
      .ToHashSet();
  Require(user.EquipmentAwakenings.All(awakening =>
          new[]
          {
            awakening.Option.Option1Id,
            awakening.Option.Option2Id,
            awakening.Option.Option3Id
          }.All(optionId => optionId == 0 || legalOverloadStateEffectIds.Contains(optionId))),
      "phase_d_overload_state_effect_mapping_invalid");
}

static PhaseDRuntimeCandidateValueDocument RequiredValue(
    IReadOnlyDictionary<(string Field, string Subject), PhaseDRuntimeCandidateValueDocument> values,
    string field,
    string? subject)
{
  var value = RequiredCoordinate(values, field, subject);
  Require(value.Status == "ready", "phase_d_candidate_coordinate_missing");
  return value!;
}

static PhaseDRuntimeCandidateValueDocument RequiredCoordinate(
    IReadOnlyDictionary<(string Field, string Subject), PhaseDRuntimeCandidateValueDocument> values,
    string field,
    string? subject)
{
  Require(values.TryGetValue((field, subject ?? ""), out var value) &&
          value.Status is "ready" or "not_applicable",
      "phase_d_candidate_coordinate_missing");
  return value!;
}

static int IntegerOrZeroWhenNotApplicable(
    IReadOnlyDictionary<(string Field, string Subject), PhaseDRuntimeCandidateValueDocument> values,
    string field,
    string? subject)
{
  var value = RequiredCoordinate(values, field, subject);
  return value.Status == "not_applicable" ? 0 : CheckedInteger(value);
}

static bool BooleanOrFalseWhenNotApplicable(
    IReadOnlyDictionary<(string Field, string Subject), PhaseDRuntimeCandidateValueDocument> values,
    string field,
    string? subject)
{
  var value = RequiredCoordinate(values, field, subject);
  if (value.Status == "not_applicable") return false;
  Require(value.BooleanValue is not null, "phase_d_boolean_value_invalid");
  return value.BooleanValue.Value;
}

static int CheckedInteger(PhaseDRuntimeCandidateValueDocument value)
{
  Require(value.IntegerValue is >= 0 and <= 1_000_000, "phase_d_integer_value_invalid");
  return checked((int)value.IntegerValue.Value);
}

static RuntimeMappings BuildMappings(byte[] secret, AliasRows rows)
{
  var characterByFingerprint = rows.CharacterAliases.ToDictionary(row => row.Fingerprint, row => row.Uid);
  var supportByFingerprint = rows.SupportAliases.ToDictionary(row => row.Fingerprint, row => row.Uid);
  var character = new Dictionary<string, int>(StringComparer.Ordinal);
  foreach (var nameCode in GameData.Instance.CharacterTable.Values.Where(row => row.IsVisible)
               .Select(row => row.NameCode).Distinct())
  {
    var fingerprint = Fingerprint(secret, "character-resource", nameCode);
    if (characterByFingerprint.TryGetValue(fingerprint, out var uid)) character[uid] = nameCode;
  }
  var characterUidByNameCode = character
      .GroupBy(pair => pair.Value)
      .ToDictionary(group => group.Key, group => group.Single().Key);

  var support = new Dictionary<string, int>(StringComparer.Ordinal);
  AddSupport(GameData.Instance.ItemEquipTable.Keys, "combat-support-equipment");
  AddSupport(GameData.Instance.ItemHarmonyCubeTable.Keys, "combat-support-harmony-cube");
  AddSupport(GameData.Instance.FavoriteItemTable.Keys, "combat-support-generic-collection");
  AddSupport(GameData.Instance.FavoriteItemTable.Keys, "combat-support-favorite");
  AddSupport(GameData.Instance.RecycleResearchStats.Keys, "combat-support-console");

  var overloadByFingerprint = rows.OverloadAliases.ToLookup(row => row.Fingerprint);
  var overload = new Dictionary<(string Uid, long Unscaled, int Scale), int>();
  foreach (var option in GameData.Instance.EquipmentOptionTable.Values)
  {
    foreach (var stateEffect in option.StateEffectList ?? [])
    {
      // Both the source alias and NetEquipmentAwakeningOption are keyed by the
      // concrete state-effect ID. EquipmentOption.Id only identifies the parent
      // roll group and is not present in the client's StateEffectTable.
      var fingerprint = Fingerprint(
          secret, "combat-support-overload-legal-value", stateEffect.StateEffectId);
      foreach (var row in overloadByFingerprint[fingerprint])
      {
        overload.TryAdd(
            (row.Uid, row.UnscaledValue, row.DecimalScale),
            stateEffect.StateEffectId);
      }
    }
  }

  return new RuntimeMappings(character, characterUidByNameCode, support, overload);

  void AddSupport(IEnumerable<int> rawIds, string kind)
  {
    foreach (var rawId in rawIds)
    {
      var fingerprint = Fingerprint(secret, kind, rawId);
      if (supportByFingerprint.TryGetValue(fingerprint, out var uid)) support[uid] = rawId;
    }
  }
}

static string Fingerprint(byte[] secret, string kind, int rawId) =>
    EncodeAliasFingerprint(
        secret,
        "nikke-staticdata",
        kind,
        rawId.ToString(CultureInfo.InvariantCulture));

static async Task<AliasRows> ReadAliasRowsAsync(NpgsqlDataSource dataSource)
{
  await using var connection = await dataSource.OpenConnectionAsync();
  var characterKeyCheck = await ScalarBytesAsync(connection,
      "SELECT key_check_sha256 FROM lab_meta.character_identity_key_binding WHERE binding_id = 1;");
  var supportKeyCheck = await ScalarBytesAsync(connection,
      "SELECT key_check_sha256 FROM lab_meta.combat_support_identity_key_binding WHERE binding_id = 1;");
  var characters = await ReadAliasesAsync(connection, """
      SELECT c.character_uid::text, encode(a.alias_fingerprint, 'hex')
      FROM lab_private.character_source_alias a
      JOIN lab_catalog.character_entity c USING (character_entity_id);
      """);
  var support = await ReadAliasesAsync(connection, """
      SELECT e.definition_uid::text, encode(a.alias_fingerprint, 'hex')
      FROM lab_private.combat_support_source_alias a
      JOIN lab_combat_support.definition_entity e USING (definition_entity_id);
      """);
  var overload = new List<OverloadAlias>();
  await using (var command = connection.CreateCommand())
  {
    command.CommandText = """
        SELECT DISTINCT e.definition_uid::text,
               v.engine_fraction_unscaled_value,
               v.engine_fraction_decimal_scale,
               encode(a.alias_fingerprint, 'hex'),
               d.option_type_code
        FROM lab_private.overload_legal_value_source_alias a
        JOIN lab_combat_support.definition_entity e USING (definition_entity_id)
        JOIN lab_combat_support.overload_option_definition_detail d
          ON d.definition_version_id = a.definition_version_id
        JOIN lab_combat_support.overload_legal_value v
          ON v.definition_version_id = a.definition_version_id
         AND v.roll_level = a.roll_level
        WHERE d.option_type_status = 'ready';
        """;
    await using var reader = await command.ExecuteReaderAsync();
    while (await reader.ReadAsync())
    {
      overload.Add(new OverloadAlias(
          reader.GetString(0), reader.GetInt64(1), reader.GetInt16(2), reader.GetString(3),
          reader.GetString(4)));
    }
  }
  return new AliasRows(characterKeyCheck, supportKeyCheck, characters, support, overload);
}

static async Task<byte[]> ScalarBytesAsync(NpgsqlConnection connection, string sql)
{
  await using var command = connection.CreateCommand();
  command.CommandText = sql;
  return (byte[])(await command.ExecuteScalarAsync() ??
      throw new InvalidOperationException("phase_d_identity_binding_missing"));
}

static async Task<IReadOnlyList<AliasRow>> ReadAliasesAsync(
    NpgsqlConnection connection,
    string sql)
{
  var result = new List<AliasRow>();
  await using var command = connection.CreateCommand();
  command.CommandText = sql;
  await using var reader = await command.ExecuteReaderAsync();
  while (await reader.ReadAsync()) result.Add(new AliasRow(reader.GetString(0), reader.GetString(1)));
  return result;
}

static async Task ExportPresentationCatalogAsync(
    string outputPath,
    string connectionString,
    byte[] identitySecret,
    string? supportAssetRoot)
{
  Require(!File.Exists(outputPath), "phase_d_presentation_output_exists");
  AssetDownloadUtil.ConfigureOfficialOutbound(false);
  await GameData.CreateAsync();
  await using var dataSource = NpgsqlDataSource.Create(connectionString);
  var aliases = await ReadAliasRowsAsync(dataSource);
  VerifyIdentityKey(identitySecret, aliases.CharacterKeyCheck, aliases.SupportKeyCheck);
  var mappings = BuildMappings(identitySecret, aliases);
  var characters = new List<object>();
  await using (var connection = await dataSource.OpenConnectionAsync())
  await using (var command = connection.CreateCommand())
  {
    command.CommandText = """
        WITH latest_character_catalog AS (
          SELECT character_catalog_snapshot_id
          FROM lab_catalog.character_catalog_snapshot
          ORDER BY character_catalog_snapshot_id DESC
          LIMIT 1
        )
        SELECT entity.character_uid::text,
               version.rarity_code,
               version.combat_class_code,
               version.weapon_code,
               version.element_code,
               version.manufacturer_code
        FROM latest_character_catalog catalog
        JOIN lab_catalog.character_catalog_snapshot_member member
          ON member.character_catalog_snapshot_id =
             catalog.character_catalog_snapshot_id
        JOIN lab_catalog.character_entity entity
          ON entity.character_entity_id = member.character_entity_id
        JOIN lab_catalog.character_definition_version version
          ON version.character_definition_version_id =
             member.character_definition_version_id
        ORDER BY member.ordinal;
        """;
    await using var reader = await command.ExecuteReaderAsync();
    while (await reader.ReadAsync())
    {
      var uid = reader.GetString(0);
      Require(mappings.CharacterNameCodeByUid.TryGetValue(uid, out var nameCode),
          "phase_d_presentation_character_mapping_missing");
      var row = GameData.Instance.CharacterTable.Values
          .Where(value => value.IsVisible && !value.IsDetailClose && value.NameCode == nameCode)
          .OrderBy(value => value.GradeCoreId)
          .FirstOrDefault();
      Require(row is not null, "phase_d_presentation_character_static_missing");
      var displayName = LocaleNameResolver.Resolve(row!.NameLocalkey, "ko").Trim();
      Require(!string.IsNullOrWhiteSpace(displayName) &&
              !string.Equals(displayName, row.NameLocalkey, StringComparison.Ordinal),
          "phase_d_presentation_character_locale_missing");
      characters.Add(new
      {
        characterUid = uid,
        displayName,
        rarityCode = reader.IsDBNull(1) ? null : reader.GetString(1),
        combatClassCode = reader.IsDBNull(2) ? null : reader.GetString(2),
        weaponCode = reader.IsDBNull(3) ? null : reader.GetString(3),
        elementCode = reader.IsDBNull(4) ? null : reader.GetString(4),
        manufacturerCode = reader.IsDBNull(5) ? null : reader.GetString(5),
        burstStep = (int)row.UseBurstSkill,
        // The browser never receives a raw game resource identifier. A separate,
        // source-free presentation-asset step maps the localized display name to
        // a local image and stores it under this lab-owned character UID.
        portraitPath = $"/editor/assets/characters/{uid}.png"
      });
    }
  }
  var consoles = new List<object>();
  var consoleCodes = new HashSet<string>(StringComparer.Ordinal);
  await using (var connection = await dataSource.OpenConnectionAsync())
  await using (var command = connection.CreateCommand())
  {
    command.CommandText = """
        WITH console_candidates AS (
          SELECT entity.definition_uid,
                 detail.coordinate_code,
                 version.definition_version_id AS ordering_id,
                 0 AS source_priority
          FROM lab_combat_support.definition_entity entity
          JOIN lab_combat_support.definition_version version
            ON version.definition_entity_id = entity.definition_entity_id
           AND version.definition_kind = entity.definition_kind
          JOIN lab_combat_support.console_definition_detail detail
            ON detail.definition_version_id = version.definition_version_id
           AND detail.definition_entity_id = version.definition_entity_id
           AND detail.definition_kind = version.definition_kind
          WHERE entity.definition_kind = 'console'

          UNION ALL

          SELECT entity.definition_uid,
                 state.coordinate_code,
                 state.account_state_revision_id AS ordering_id,
                 1 AS source_priority
          FROM lab_profile.account_console_state state
          JOIN lab_combat_support.definition_entity entity
            ON entity.definition_entity_id = state.definition_entity_id
           AND entity.definition_kind = 'console'
        )
        SELECT DISTINCT ON (definition_uid)
               definition_uid::text,
               coordinate_code
        FROM console_candidates
        ORDER BY definition_uid, source_priority DESC, ordering_id DESC;
        """;
    await using var reader = await command.ExecuteReaderAsync();
    while (await reader.ReadAsync())
    {
      var code = reader.GetString(1);
      consoleCodes.Add(code);
      consoles.Add(new
      {
        definitionUid = reader.GetString(0),
        coordinateCode = code,
        displayName = code switch
        {
          "common" => "공용 콘솔", "attacker" => "화력형 콘솔",
          "defender" => "방어형 콘솔", "supporter" => "지원형 콘솔",
          "elysion" => "엘리시온 콘솔", "missilis" => "미실리스 콘솔",
          "tetra" => "테트라 콘솔", "pilgrim" => "필그림 콘솔",
          "abnormal" => "어브노멀 콘솔",
          _ => throw new InvalidOperationException("phase_d_presentation_console_code_invalid")
        }
      });
    }
  }
  if (characters.Count == 0 || consoleCodes.Count != 9)
  {
    throw new InvalidOperationException(
        $"phase_d_presentation_catalog_incomplete:characters={characters.Count}:" +
        $"consoleMembers={consoles.Count}:consoleCodes=" +
        string.Join(',', consoleCodes.Order(StringComparer.Ordinal)));
  }
  var supportDefinitions = new List<object>();
  var supportAssetPlans = new List<PresentationSupportAssetPlan>();
  await using (var connection = await dataSource.OpenConnectionAsync())
  await using (var command = connection.CreateCommand())
  {
    command.CommandText = """
        SELECT definition_uid::text, definition_kind
        FROM lab_combat_support.definition_entity
        WHERE definition_kind IN ('equipment', 'cube', 'collection', 'favorite')
        ORDER BY definition_kind, definition_uid;
        """;
    await using var reader = await command.ExecuteReaderAsync();
    while (await reader.ReadAsync())
    {
      var uid = reader.GetString(0);
      var kind = reader.GetString(1);
      Require(mappings.SupportRawIdByUid.TryGetValue(uid, out var rawId),
          "phase_d_presentation_support_mapping_missing");
      if (kind == "equipment")
      {
        Require(GameData.Instance.ItemEquipTable.TryGetValue(rawId, out var equipment),
            "phase_d_presentation_equipment_static_missing");
        var enhancementLevels = GameData.Instance.itemEquipExpTable.Values
            .Where(item => item.ItemRare == equipment!.ItemRare &&
                           item.GradeCoreId == equipment.GradeCoreId)
            .Select(static item => item.Level)
            .Distinct()
            .Order()
            .ToArray();
        Require(enhancementLevels.SequenceEqual(Enumerable.Range(0, 6)),
            "phase_d_presentation_equipment_enhancement_coordinates_invalid");
        supportDefinitions.Add(new
        {
          definitionUid = uid,
          kindCode = kind,
          displayName = ResolveLocale(equipment!.NameLocalkey, "장비"),
          imagePath = $"/editor/assets/equipment/{uid}.webp",
          weaponCode = (string?)null,
          favoriteCharacterUid = (string?)null,
          tier = (int)equipment.ItemRare,
          slotCode = equipment.ItemSubType switch
          {
            ItemSubType.ModuleA => "head",
            ItemSubType.ModuleB => "torso",
            ItemSubType.ModuleC => "arms",
            ItemSubType.ModuleD => "legs",
            _ => throw new InvalidOperationException(
                "phase_d_presentation_equipment_slot_invalid")
          },
          combatClassCode = equipment.Class switch
          {
            CharacterClassType.Attacker => "attacker",
            CharacterClassType.Defender => "defender",
            CharacterClassType.Supporter => "supporter",
            _ => throw new InvalidOperationException(
                "phase_d_presentation_equipment_class_invalid")
          },
          maximumEnhancementLevel = enhancementLevels[^1],
          // The client applies +10% of the level-0 stat per enhancement level,
          // then rounds the positive result to the nearest integer.
          enhancementStatIncreaseBasisPointsPerLevel = 1_000,
          stats = equipment.Stat.Select(item => new
          {
            label = StatLabel(item.StatType),
            baseValue = item.StatValue,
            value = item.StatValue.ToString("N0", CultureInfo.InvariantCulture)
          }).ToArray(),
          levels = Array.Empty<object>()
        });
        Require(!string.IsNullOrWhiteSpace(equipment.ResourceId),
            "phase_d_presentation_equipment_resource_missing");
        supportAssetPlans.Add(new PresentationSupportAssetPlan(
            uid,
            "equipment",
            $"icon/equip/{equipment.ResourceId}.webp"));
      }
      else if (kind is "collection" or "favorite")
      {
        Require(GameData.Instance.FavoriteItemTable.TryGetValue(rawId, out var collection),
            "phase_d_presentation_collection_static_missing");
        string? favoriteCharacterUid = null;
        if (kind == "favorite")
        {
          Require(collection!.NameCode != 0 &&
                  mappings.CharacterUidByNameCode.TryGetValue(
                      collection.NameCode, out favoriteCharacterUid),
              "phase_d_presentation_favorite_character_mapping_missing");
        }
        var levels = GameData.Instance.FavoriteItemLevelTable.Values
            .Where(item => item.LevelEnhanceId == collection!.LevelEnhanceId)
            .OrderBy(item => item.Grade)
            .ThenBy(item => item.Level)
            .Select(item => new
            {
              grade = item.Grade,
              level = item.Level,
              stats = item.FavoriteitemStatData.Select(stat => new
              {
                label = StatLabel(stat.StatType),
                value = stat.StatValue.ToString("N0", CultureInfo.InvariantCulture)
              }).ToArray()
            }).ToArray();
        supportDefinitions.Add(new
        {
          definitionUid = uid,
          kindCode = kind,
          displayName = ResolveLocale(
              collection!.NameLocalkey,
              kind == "favorite" ? "애장품" : "소장품"),
          imagePath = $"/editor/assets/collections/{uid}.webp",
          weaponCode = WeaponCode(collection.WeaponType),
          rarityCode = collection.FavoriteRare switch
          {
            FavoriteItemRare.R => "r",
            FavoriteItemRare.SR => "sr",
            FavoriteItemRare.SSR => "ssr",
            _ => throw new InvalidOperationException(
                "phase_d_presentation_collection_rarity_invalid")
          },
          favoriteCharacterUid,
          stats = Array.Empty<object>(),
          levels
        });
        Require(!string.IsNullOrWhiteSpace(collection.IconResourceId),
            "phase_d_presentation_collection_resource_missing");
        supportAssetPlans.Add(new PresentationSupportAssetPlan(
            uid,
            "collections",
            $"icon/favoriteitem/{collection.IconResourceId}.webp"));
      }
      else
      {
        Require(GameData.Instance.ItemHarmonyCubeTable.TryGetValue(rawId, out var cube),
            "phase_d_presentation_cube_static_missing");
        supportDefinitions.Add(CubePresentation.Build(GameData.Instance, cube!, uid));
        supportAssetPlans.Add(new PresentationSupportAssetPlan(uid, "cubes", $"icon/equip/ie_{cube!.ResourceId}.webp"));
      }
    }
  }
  var overloadOptions = new List<object>();
  foreach (var group in aliases.OverloadAliases.GroupBy(static item => item.Uid, StringComparer.Ordinal))
  {
    var mappedAliases = new List<(OverloadAlias Alias, int RawId)>();
    foreach (var alias in group)
    {
      if (mappings.OverloadRawIdByValue.TryGetValue(
          (alias.Uid, alias.UnscaledValue, alias.DecimalScale), out var mappedRawId))
      {
        mappedAliases.Add((alias, mappedRawId));
      }
    }
    // Private aliases are append-only and may contain legal rolls from an
    // older static-data snapshot. Presentation must describe only values that
    // resolve against the pinned runtime selected for this installation.
    if (mappedAliases.Count == 0) continue;
    var legalValues = mappedAliases
        .Select(item => new
        {
          unscaledValue = item.Alias.UnscaledValue,
          decimalScale = item.Alias.DecimalScale
        })
        .Distinct()
        .OrderBy(static item => item.decimalScale)
        .ThenBy(static item => item.unscaledValue)
        .ToArray();
    var stateEffectId = mappedAliases[0].RawId;
    Require(GameData.Instance.EquipmentOptionTable.Values.Any(option =>
                option.StateEffectList?.Any(stateEffect =>
                    stateEffect.StateEffectId == stateEffectId) == true),
        "phase_d_presentation_overload_static_missing");
    var optionTypes = mappedAliases
        .Select(static item => item.Alias.OptionTypeCode)
        .Distinct(StringComparer.Ordinal)
        .ToArray();
    Require(optionTypes.Length == 1, "phase_d_presentation_overload_option_type_invalid");
    overloadOptions.Add(new
    {
      definitionUid = group.Key,
      displayName = OverloadOptionDisplayName(optionTypes[0]),
      optionTypeCode = optionTypes[0],
      storedUnitCode = "ratio",
      displayUnitCode = "percent",
      ratioToDisplayMultiplier = 100,
      unitLabel = "%",
      legalValues
    });
  }
  Require(overloadOptions.Count > 0, "phase_d_presentation_overload_catalog_empty");
  if (supportAssetRoot is not null)
  {
    await ExportPresentationSupportAssetsAsync(supportAssetRoot, supportAssetPlans);
  }
  var catalog = new
  {
    schemaVersion = 1,
    contractId = "nll/control-center-presentation/v1",
    generatedAtUtc = DateTimeOffset.UtcNow,
    localeCode = "ko",
    characters,
    consoles,
    supportDefinitions,
    overloadOptions,
    rawSourceIdentifierPersisted = false,
      officialOutboundUsed = false
  };
  await WriteAtomicAsync(
      outputPath,
      System.Text.Json.JsonSerializer.Serialize(
          catalog, new JsonSerializerOptions { WriteIndented = true }) + "\n");
}

static async Task ExportPresentationSupportAssetsAsync(
    string outputRoot,
    IReadOnlyList<PresentationSupportAssetPlan> plans)
{
  Require(Path.IsPathFullyQualified(outputRoot), "phase_d_presentation_support_asset_root_invalid");
  Require(plans.Count > 0, "phase_d_presentation_support_asset_plan_empty");
  Directory.CreateDirectory(outputRoot);
  using var client = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
  client.DefaultRequestHeaders.UserAgent.ParseAdd("NLL-ControlCenter-AssetMaterializer/1.0");
  var members = new List<object>();
  foreach (var plan in plans
      .DistinctBy(static item => (item.KindCode, item.DefinitionUid))
      .OrderBy(static item => item.KindCode, StringComparer.Ordinal)
      .ThenBy(static item => item.DefinitionUid, StringComparer.Ordinal))
  {
    var uri = BlablalinkNormalResourceUri(plan.LogicalPath);
    using var response = await client.GetAsync(uri, HttpCompletionOption.ResponseHeadersRead);
    Require(response.IsSuccessStatusCode, "phase_d_presentation_support_asset_download_failed");
    var bytes = await response.Content.ReadAsByteArrayAsync();
    Require(IsWebp(bytes), "phase_d_presentation_support_asset_format_invalid");
    var directory = Path.Combine(outputRoot, plan.KindCode);
    Directory.CreateDirectory(directory);
    var path = Path.Combine(directory, plan.DefinitionUid + ".webp");
    var temporary = path + ".partial-" + Guid.NewGuid().ToString("N");
    await File.WriteAllBytesAsync(temporary, bytes);
    File.Move(temporary, path, true);
    members.Add(new
    {
      definitionUid = plan.DefinitionUid,
      kindCode = plan.KindCode,
      byteLength = bytes.LongLength,
      sha256 = LowerHex(SHA256.HashData(bytes))
    });
  }

  var receipt = new
  {
    schemaVersion = 1,
    contractId = "nll/phase-d-presentation-support-assets/v1",
    materializedAtUtc = DateTimeOffset.UtcNow,
    assetCount = members.Count,
    members,
    sourceHost = "sg-tools-cdn.blablalink.com",
    rawGameResourceIdentifierPersisted = false,
    officialAccountOrSessionUsed = false,
    officialInstallModified = false
  };
  await WriteAtomicAsync(
      Path.Combine(outputRoot, "support-assets.receipt.json"),
      System.Text.Json.JsonSerializer.Serialize(
          receipt, new JsonSerializerOptions { WriteIndented = true }) + "\n");
}

static Uri BlablalinkNormalResourceUri(string logicalPath)
{
  var path = logicalPath.TrimStart('/');
  var segments = path.Split('/');
  long[] primes = [224737L, 1000639L, 2654435761L, 2654435769L, 1000621L, 4294967291L];
  Require(segments.Length >= 2 && segments.Length <= primes.Length + 1,
      "phase_d_blablalink_resource_path_invalid");
  var output = new List<string>();
  for (var index = 0; index < segments.Length - 1; index++)
  {
    var seed = primes[index];
    long hash = seed;
    foreach (var character in path)
    {
      var unsigned = unchecked((hash * 33L + character) & 0xffffffffL);
      hash = unsigned >= 0x80000000L ? unsigned - 0x100000000L : unsigned;
    }
    var remainder = ((hash % seed) + seed) % seed;
    var first = (char)('a' + ((remainder / 26) % 26));
    var second = (char)('a' + (remainder % 26));
    output.Add($"{first}{second}-{remainder % 99:00}");
  }
  var leaf = segments[^1];
  var firstDot = leaf.IndexOf('.', StringComparison.Ordinal);
  Require(firstDot > 0, "phase_d_blablalink_resource_leaf_invalid");
  var extension = leaf[(firstDot + 1)..];
  var hashLeaf = LowerHex(MD5.HashData(Encoding.UTF8.GetBytes(path))) + "." + extension;
  output.Add(hashLeaf);
  return new Uri("https://sg-tools-cdn.blablalink.com/" + string.Join('/', output));
}

static bool IsWebp(ReadOnlySpan<byte> bytes) =>
    bytes.Length > 12 &&
    bytes[..4].SequenceEqual("RIFF"u8) &&
    bytes.Slice(8, 4).SequenceEqual("WEBP"u8);

static string ResolveLocale(string? localKey, string fallback)
{
  if (string.IsNullOrWhiteSpace(localKey)) return fallback;
  var resolved = LocaleNameResolver.Resolve(localKey, "ko").Trim();
  return string.IsNullOrWhiteSpace(resolved) || string.Equals(resolved, localKey, StringComparison.Ordinal)
      ? fallback
      : resolved;
}

static string OverloadOptionDisplayName(string optionTypeCode) => optionTypeCode switch
{
  "attack" => "공격력 증가",
  "defence" => "방어력 증가",
  "maximum_ammunition" => "최대 장탄 수 증가",
  "critical_rate" => "크리티컬 확률 증가",
  "critical_damage" => "크리티컬 대미지 증가",
  "charge_damage" => "차지 대미지 증가",
  "charge_speed" => "차지 속도 증가",
  "elemental_damage" => "우월코드 대미지 증가",
  "hit_rate" => "명중률 증가",
  _ => throw new InvalidOperationException("phase_d_presentation_overload_option_type_invalid")
};

static string StatLabel(StatType statType) => statType switch
{
  StatType.Atk => "공격력",
  StatType.Hp => "체력",
  StatType.Defence => "방어력",
  StatType.EnergyResist => "에너지 저항",
  StatType.MetalResist => "메탈 저항",
  StatType.BioResist => "바이오 저항",
  _ => "능력치"
};

static string? WeaponCode(WeaponType weaponType) => weaponType switch
{
  WeaponType.AR => "assault_rifle",
  WeaponType.MG => "machine_gun",
  WeaponType.RL => "rocket_launcher",
  WeaponType.SG => "shotgun",
  WeaponType.SR => "sniper_rifle",
  WeaponType.SMG => "submachine_gun",
  _ => null
};

static void VerifyIdentityKey(byte[] secret, byte[] characterCheck, byte[] supportCheck)
{
  var expected = CreateAliasKeyCheck(secret);
  try
  {
    Require(CryptographicOperations.FixedTimeEquals(expected, characterCheck) &&
            CryptographicOperations.FixedTimeEquals(expected, supportCheck),
        "phase_d_identity_key_mismatch");
  }
  finally
  {
    CryptographicOperations.ZeroMemory(expected);
    CryptographicOperations.ZeroMemory(characterCheck);
    CryptographicOperations.ZeroMemory(supportCheck);
  }
}

static string EncodeAliasFingerprint(
    ReadOnlySpan<byte> secret,
    string sourceNamespace,
    string entityKind,
    string rawSourceIdentifier)
{
  Require(secret.Length >= 32, "phase_d_identity_secret_invalid");
  var components = new[]
  {
    "nll/source-alias-fingerprint/v1",
    sourceNamespace,
    entityKind,
    rawSourceIdentifier
  };
  var strictUtf8 = new UTF8Encoding(false, true);
  var byteCounts = components.Select(strictUtf8.GetByteCount).ToArray();
  var message = GC.AllocateUninitializedArray<byte>(
      checked(byteCounts.Sum() + components.Length * sizeof(int)));
  var offset = 0;
  for (var index = 0; index < components.Length; index++)
  {
    BinaryPrimitives.WriteInt32BigEndian(message.AsSpan(offset, sizeof(int)), byteCounts[index]);
    offset += sizeof(int);
    strictUtf8.GetBytes(components[index], message.AsSpan(offset, byteCounts[index]));
    offset += byteCounts[index];
  }
  try
  {
    return Convert.ToHexString(HMACSHA256.HashData(secret, message)).ToLowerInvariant();
  }
  finally
  {
    CryptographicOperations.ZeroMemory(message);
  }
}

static byte[] CreateAliasKeyCheck(ReadOnlySpan<byte> secret)
{
  Require(secret.Length >= 32, "phase_d_identity_secret_invalid");
  var message = Encoding.UTF8.GetBytes("nll/source-alias-key-check/v1");
  try
  {
    return HMACSHA256.HashData(secret, message);
  }
  finally
  {
    CryptographicOperations.ZeroMemory(message);
  }
}

static Dictionary<string, string> ParseArguments(string[] args)
{
  Require(args.Length % 2 == 0, "phase_d_arguments_invalid");
  var result = new Dictionary<string, string>(StringComparer.Ordinal);
  for (var index = 0; index < args.Length; index += 2)
  {
    Require(args[index].StartsWith("--", StringComparison.Ordinal) &&
            result.TryAdd(args[index][2..], args[index + 1]),
        "phase_d_arguments_invalid");
  }
  return result;
}

static void ExportDecodedStaticData(
    string staticPackPath,
    string gameConfigPath,
    string outputPath)
{
  Require(File.Exists(staticPackPath) && new FileInfo(staticPackPath).Length == 17_177_168L,
      "phase_d_staticdata_pack_invalid");
  Require(HashFile(staticPackPath) ==
      "8c0dfdcaf17446d0d25ecf2c5910272b1c1fc906191e6926037a81d94ef858e3",
      "phase_d_staticdata_pack_drifted");
  Require(File.Exists(gameConfigPath) && !File.Exists(outputPath),
      "phase_d_staticdata_export_input_invalid");

  using var configDocument = JsonDocument.Parse(File.ReadAllText(gameConfigPath));
  var staticDataElement = configDocument.RootElement.GetProperty("StaticDataMpk");
  var configRoot = new GameConfigRoot
  {
    StaticDataMpk = new EpinelPS.Utils.StaticData
    {
      Url = "",
      Version = staticDataElement.GetProperty("Version").GetString() ?? "",
      Salt1 = staticDataElement.GetProperty("Salt1").GetString() ?? "",
      Salt2 = staticDataElement.GetProperty("Salt2").GetString() ?? ""
    }
  };
  var configRootField = typeof(GameConfig).GetField(
      "_root", BindingFlags.Static | BindingFlags.NonPublic);
  Require(configRootField is not null, "phase_d_staticdata_config_binding_unavailable");
  configRootField!.SetValue(null, configRoot);

  var gameData = new GameData(staticPackPath);
  var decodedArchiveField = typeof(GameData).GetField(
      "ZipStream", BindingFlags.Instance | BindingFlags.NonPublic);
  var decodedArchive = decodedArchiveField?.GetValue(gameData) as MemoryStream;
  Require(decodedArchive is not null, "phase_d_staticdata_binding_unavailable");
  var decoded = decodedArchive!.ToArray();
  try
  {
    Require(decoded.LongLength == 17_176_616L &&
            LowerHex(SHA256.HashData(decoded)) == ExpectedDecodedStaticDataSha256,
        "phase_d_staticdata_archive_drifted");
    Directory.CreateDirectory(Path.GetDirectoryName(outputPath)!);
    File.WriteAllBytes(outputPath, decoded);
  }
  finally
  {
    CryptographicOperations.ZeroMemory(decoded);
    decodedArchive.Dispose();
  }
}

static async Task PrepareUserValidationAccountAsync(IReadOnlyDictionary<string, string> options)
{
  var output = Required(options, "prepare-user-validation-account");
  if (!OperatingSystem.IsWindows()) throw new InvalidOperationException("phase_d_user_validation_windows_required");
  Require(Directory.Exists(output) &&
      !Directory.EnumerateFileSystemEntries(output).Any(), "phase_d_user_validation_output_not_empty");
  AssertUserValidationPath(output);
  var acl = System.IO.FileSystemAclExtensions.GetAccessControl(new DirectoryInfo(output));
  var allowed = new[] { System.Security.Principal.WindowsIdentity.GetCurrent().User!.Value,
      "S-1-5-18", "S-1-5-32-544" };
  Require(acl.AreAccessRulesProtected, "phase_d_user_validation_output_not_private");
  foreach (System.Security.AccessControl.FileSystemAccessRule rule in acl.GetAccessRules(true, true,
      typeof(System.Security.Principal.SecurityIdentifier)))
    Require(rule.AccessControlType != System.Security.AccessControl.AccessControlType.Allow ||
        allowed.Contains(rule.IdentityReference.Value), "phase_d_user_validation_output_not_private");
  var leases = new List<FileStream>();
  var secrets = new List<byte[]>();
  try
  {
    byte[] Read(string name, int limit)
    {
      var path = Required(options, name);
      AssertUserValidationPath(path);
      var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
      leases.Add(stream);
      Require(stream.Length > 0 && stream.Length <= limit, "phase_d_user_validation_input_size_invalid");
      var bytes = new byte[checked((int)stream.Length)];
      secrets.Add(bytes);
      stream.ReadExactly(bytes);
      Require(UserValidationAccount.Hash(bytes) == RequiredText(options, name + "-sha256"),
          "phase_d_user_validation_input_drifted");
      return bytes;
    }
    var source = Read("source-db", 32 * 1024 * 1024);
    var receipt = Read("source-receipt", 65536);
    var sourcePack = Read("source-static-pack", 64 * 1024 * 1024);
    _ = Read("game-config", 1024 * 1024);
    _ = Read("boss-variant-profile", 1024 * 1024);
    Require(Guid.TryParseExact(RequiredText(options, "assessment-uid"), "D", out var assessment) &&
        assessment != Guid.Empty, "phase_d_user_validation_assessment_invalid");
    AssetDownloadUtil.ConfigureOfficialOutbound(false);
    // Upstream GameData uses an exclusive read handle. Parse a new private copy
    // while retaining the original read lease; never release the source pin.
    var inspectionPack = Path.Combine(output, "inspection-static.pack");
    using (var copy = new FileStream(inspectionPack, FileMode.CreateNew, FileAccess.Write, FileShare.None))
    {
      copy.Write(sourcePack);
      copy.Flush(true);
    }
    var console = Console.Out;
    GameData data;
    using var suppressed = new StringWriter(CultureInfo.InvariantCulture);
    try
    {
      Console.SetOut(suppressed);
      data = await LoadStaticDataForInspectionAsync(inspectionPack, Required(options, "game-config"));
    }
    finally { Console.SetOut(console); }
    Require(HashFile(inspectionPack) == UserValidationAccount.Hash(sourcePack), "phase_d_user_validation_input_drifted");
    Require(!suppressed.ToString().Contains("Failed to parse ", StringComparison.Ordinal) &&
        !suppressed.ToString().Contains(" does not exist in static data", StringComparison.Ordinal),
        "phase_d_staticdata_table_parse_incomplete");
    var profile = await BossRuntimeVariantProfile.LoadAsync(Required(options, "boss-variant-profile"));
    var manager = BossAffinityStaticDataVariant.ResolveUniqueUserValidationManager(data, profile);
    var entropy = RandomNumberGenerator.GetBytes(15);
    var launcher = RandomNumberGenerator.GetBytes(32);
    var encryption = RandomNumberGenerator.GetBytes(32);
    secrets.AddRange([entropy, launcher, encryption]);
    var result = UserValidationAccount.Create(source, receipt, assessment, manager, profile.SeasonNumber,
        RequiredText(options, "weakness-code"), profile.Sha256, entropy, launcher, encryption);
    secrets.AddRange([result.Database, result.Context]);
    var prepared = JsonConvert.DeserializeObject<CoreInfo>(Encoding.UTF8.GetString(result.Database)) ??
        throw new InvalidOperationException("phase_d_user_validation_account_rejected");
    BossAffinityStaticDataVariant.ValidateUserValidationSelection(data, profile, prepared.Users.Single());
    // CreateNew only; a partial failure leaves private evidence, never overwrites or publishes success.
    foreach (var pair in new[] { ("db.json", result.Database), ("synthetic-context.json", result.Context),
        ("account.receipt.json", result.Receipt) })
    {
      AssertUserValidationPath(output);
      using var file = new FileStream(Path.Combine(output, pair.Item1), FileMode.CreateNew, FileAccess.Write, FileShare.None);
      file.Write(pair.Item2);
      file.Flush(true);
    }
    Console.WriteLine(Encoding.UTF8.GetString(result.Receipt));
  }
  finally
  {
    foreach (var lease in leases) lease.Dispose();
    foreach (var secret in secrets) CryptographicOperations.ZeroMemory(secret);
  }
}

static void AssertUserValidationPath(string path)
{
  Require(!path.StartsWith(@"C:\NIKKE", StringComparison.OrdinalIgnoreCase),
      "phase_d_user_validation_official_path_rejected");
  for (FileSystemInfo? entry = File.Exists(path) ? new FileInfo(path) : new DirectoryInfo(path);
      entry is not null; entry = entry is FileInfo file ? file.Directory : ((DirectoryInfo)entry).Parent)
    Require(entry.Exists && (entry.Attributes & FileAttributes.ReparsePoint) == 0,
        "phase_d_user_validation_reparse_path_rejected");
}

static async Task<GameData> LoadStaticDataForInspectionAsync(
    string staticPackPath,
    string gameConfigPath)
{
  Require(File.Exists(staticPackPath), "phase_d_staticdata_pack_invalid");
  Require(File.Exists(gameConfigPath), "phase_d_staticdata_export_input_invalid");
  using var configDocument = JsonDocument.Parse(File.ReadAllText(gameConfigPath));
  var staticDataElement = configDocument.RootElement.GetProperty("StaticDataMpk");
  var configRoot = new GameConfigRoot
  {
    StaticDataMpk = new EpinelPS.Utils.StaticData
    {
      Url = "",
      Version = staticDataElement.GetProperty("Version").GetString() ?? "",
      Salt1 = staticDataElement.GetProperty("Salt1").GetString() ?? "",
      Salt2 = staticDataElement.GetProperty("Salt2").GetString() ?? ""
    }
  };
  var configRootField = typeof(GameConfig).GetField(
      "_root", BindingFlags.Static | BindingFlags.NonPublic);
  Require(configRootField is not null, "phase_d_staticdata_config_binding_unavailable");
  configRootField!.SetValue(null, configRoot);
  var gameData = new GameData(staticPackPath);
  var instanceField = typeof(GameData).GetField(
      "_instance", BindingFlags.Static | BindingFlags.NonPublic);
  Require(instanceField is not null, "phase_d_staticdata_binding_unavailable");
  instanceField!.SetValue(null, gameData);
  await gameData.Parse();
  return gameData;
}

static int RequiredPositiveIntegerOption(
    IReadOnlyDictionary<string, string> options,
    string name)
{
  var value = RequiredText(options, name);
  Require(int.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out var parsed) &&
          parsed > 0,
      "phase_d_required_option_invalid");
  return parsed;
}

static string Required(IReadOnlyDictionary<string, string> options, string name)
{
  return Path.GetFullPath(RequiredText(options, name));
}

static string RequiredText(IReadOnlyDictionary<string, string> options, string name)
{
  Require(options.TryGetValue(name, out var value) && !string.IsNullOrWhiteSpace(value),
      "phase_d_required_option_missing");
  return value!;
}

static async Task WriteAtomicAsync(string path, string text)
{
  Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
  var temporary = path + ".partial-" + Guid.NewGuid().ToString("N");
  await File.WriteAllTextAsync(temporary, text, new System.Text.UTF8Encoding(false));
  File.Move(temporary, path);
}

static string HashFile(string path)
{
  using var stream = File.OpenRead(path);
  return LowerHex(SHA256.HashData(stream));
}

static string LowerHex(byte[] bytes) => Convert.ToHexString(bytes).ToLowerInvariant();

static void Require([DoesNotReturnIf(false)] bool condition, string code)
{
  if (!condition) throw new InvalidOperationException(code);
}

sealed record PresentationSupportAssetPlan(
    string DefinitionUid,
    string KindCode,
    string LogicalPath);
sealed record AliasRow(string Uid, string Fingerprint);
sealed record OverloadAlias(
    string Uid,
    long UnscaledValue,
    int DecimalScale,
    string Fingerprint,
    string OptionTypeCode);
sealed record AliasRows(
    byte[] CharacterKeyCheck,
    byte[] SupportKeyCheck,
    IReadOnlyList<AliasRow> CharacterAliases,
    IReadOnlyList<AliasRow> SupportAliases,
    IReadOnlyList<OverloadAlias> OverloadAliases);
sealed record RuntimeMappings(
    IReadOnlyDictionary<string, int> CharacterNameCodeByUid,
    IReadOnlyDictionary<int, string> CharacterUidByNameCode,
    IReadOnlyDictionary<string, int> SupportRawIdByUid,
    IReadOnlyDictionary<(string Uid, long Unscaled, int Scale), int> OverloadRawIdByValue);
