using System.Globalization;
using System.IO.Compression;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using EpinelPS.Data;
using MemoryPack;

internal static class BossContentDiscovery
{
  private const int ChallengeDifficultyType = 2;
  private const int ChallengeWaveOrder = 8;
  private const int ImmuneOtherElementFunctionType = 110;
  private static readonly int[] ExpectedFixedRoleLineCounts = [3, 13, 13];

  public static async Task WriteAsync(
      GameData gameData,
      int seasonNumber,
      string profileCode,
      string displayNameCode,
      string outputPath,
      string? privateOutputPath)
  {
    Require(seasonNumber > 0 && IsCode(profileCode) && IsCode(displayNameCode),
        "phase_d_boss_discovery_request_invalid");
    outputPath = Path.GetFullPath(outputPath);
    privateOutputPath = privateOutputPath is null ? null : Path.GetFullPath(privateOutputPath);
    Require(!File.Exists(outputPath) &&
            (privateOutputPath is null || !File.Exists(privateOutputPath)),
        "phase_d_boss_discovery_output_exists");

    var archive = GetDecodedArchive(gameData);
    try
    {
      var managerRows = DeserializeEntry<SoloRaidManagerRecord>(archive, "SoloRaidManagerTable.mpk");
      var presetRows = DeserializeEntry<SoloRaidPresetRecord>(archive, "SoloRaidPresetTable.mpk");
      var waveRows = DeserializeEntry<WaveDataRecord>(
          archive,
          "WaveDataTable.wave_Intercept_001.mpk");
      var monsterRows = DeserializeEntry<MonsterRecord>(archive, "MonsterTable.mpk");
      var modelRows = DeserializeEntry<MonsterModelRecord>(archive, "MonsterModelTable.mpk");
      var statEnhancementRows = DeserializeEntry<MonsterStatEnhanceRecord>(
          archive,
          "MonsterStatEnhanceTable.mpk");
      var manager = managerRows.Where(row => row.RankingGroupId == seasonNumber).Take(2).ToArray();
      if (manager.Length != 1 && privateOutputPath is not null)
      {
        await WriteAtomicTextAsync(privateOutputPath, JsonSerializer.Serialize(new
        {
          schemaVersion = 1,
          contractId = "nll/private-boss-manager-diagnostic/v1",
          requestedSeasonNumber = seasonNumber,
          managers = managerRows.OrderBy(row => row.Id)
              .Select(row => new { row.Id, row.MonsterPreset, row.RankingGroupId })
        }, new JsonSerializerOptions { WriteIndented = true }) + "\n");
      }
      Require(manager.Length == 1, "phase_d_boss_discovery_manager_not_unique");
      var presets = presetRows
          .Where(row => row.PresetGroupId == manager[0].MonsterPreset &&
              (int)row.DifficultyType == ChallengeDifficultyType &&
              row.WaveOrder == ChallengeWaveOrder)
          .Take(2)
          .ToArray();
      Require(presets.Length == 1, "phase_d_boss_discovery_challenge_preset_not_unique");
      var waveMatches = waveRows.Where(row => row.StageId == presets[0].Wave).Take(2).ToArray();
      Require(waveMatches.Length == 1, "phase_d_boss_discovery_wave_missing");
      var wave = waveMatches[0];
      var spawned = (wave.WaveData ?? [])
          .SelectMany(row => row.WaveMonsterList ?? [])
          .Select(row => row.WaveMonsterId)
          .ToHashSet();
      var targetIds = (wave.TargetList ?? []).Where(spawned.Contains).Distinct().Take(2).ToArray();
      Require(targetIds.Length == 1, "phase_d_boss_discovery_target_not_unique");
      var targetMatches = monsterRows.Where(row => row.Id == targetIds[0]).Take(2).ToArray();
      Require(targetMatches.Length == 1, "phase_d_boss_discovery_target_missing");
      var targetMonster = targetMatches[0];
      var modelMatches = modelRows.Where(row => row.Id == targetMonster.MonsterModelId).Take(2).ToArray();
      Require(modelMatches.Length == 1, "phase_d_boss_discovery_model_missing");
      var model = modelMatches[0];
      var statRows = statEnhancementRows
          .Where(row => row.GroupId == targetMonster.StatenhanceId &&
              row.Lv == presets[0].MonsterStageLv)
          .Take(2)
          .ToArray();
      Require(statRows.Length == 1, "phase_d_boss_discovery_stat_not_unique");

      var elements = DeserializeEntry<ElementRecord>(archive, "ElementTable.mpk");
      var parts = DeserializeEntry<MonsterPartsRecord>(archive, "MonsterPartsTable.mpk")
          .Where(row => row.MonsterModelId == targetMonster.MonsterModelId)
          .OrderBy(row => row.Id)
          .ToArray();
      var monsterSkills = DeserializeEntry<MonsterSkillRecord>(archive, "MonsterSkillTable.mpk")
          .ToDictionary(row => row.Id);
      var stateEffects = DeserializeEntry<StateEffectRecord>(archive, "StateEffectTable.mpk")
          .ToDictionary(row => row.Id);
      var functions = DeserializeEntry<FunctionRecord>(archive, "FunctionTable.mpk")
          .ToDictionary(row => row.Id);
      var quickTimeEvents = DeserializeEntry<QuickTimeEventRecord>(
          archive,
          "QuickTimeEventTable.mpk");

      var elementById = elements.ToDictionary(row => row.Id);
      Require(targetMonster.ElementId is [_],
          "phase_d_boss_discovery_affinity_unresolved");
      Require(elementById.TryGetValue(targetMonster.ElementId[0], out var bossElement),
          "phase_d_boss_discovery_affinity_unresolved");
      Require(elementById.TryGetValue(bossElement!.WeakElementId, out var weakness),
          "phase_d_boss_discovery_affinity_unresolved");
      var sourceBossElementCode = ElementCode(bossElement!.Element);
      var sourceWeaknessCode = ElementCode(weakness!.Element);
      var targetQuickTimeEvents = quickTimeEvents
          .Where(row => (row.MonsterId ?? []).Contains(targetMonster.Id))
          .OrderBy(row => row.Id)
          .ToArray();
      var quickTimeEventMonsterIds = targetQuickTimeEvents
          .SelectMany(row => row.MonsterId ?? [])
          .Distinct()
          .Order()
          .ToArray();

      var skillRelations = (targetMonster.SkillData ?? [])
          .Where(row => row.SkillId != 0)
          .ToArray();
      var skillIds = skillRelations.Select(row => row.SkillId).Distinct().Order().ToArray();
      var missingSkillCount = skillIds.Count(id => !monsterSkills.ContainsKey(id));
      var selectedSkillRows = skillIds
          .Where(monsterSkills.ContainsKey)
          .Select(id => monsterSkills[id])
          .ToArray();

      var passiveIds = parts.Select(row => row.PassiveSkillId)
          .Append(targetMonster.PassiveSkillId)
          .Where(id => id != 0)
          .Distinct()
          .Order()
          .ToArray();
      var missingPassiveCount = passiveIds.Count(id => !stateEffects.ContainsKey(id));
      var selectedStateEffects = passiveIds
          .Where(stateEffects.ContainsKey)
          .Select(id => stateEffects[id])
          .ToArray();

      var directSkillFunctionIds = skillRelations
          .SelectMany(row => (row.UseFunctionIdSkill ?? []).Concat(row.HurtFunctionIdSkill ?? []));
      var passiveFunctionIds = selectedStateEffects.SelectMany(StateEffectFunctionIds);
      var rootFunctionIds = directSkillFunctionIds.Concat(passiveFunctionIds)
          .Where(id => id != 0)
          .Distinct()
          .Order()
          .ToArray();
      var closure = ResolveFunctionClosure(rootFunctionIds, functions);
      var shieldFunctions = closure.Rows
          .Where(row => (int)row.FunctionType == ImmuneOtherElementFunctionType)
          .OrderBy(row => row.Id)
          .ToArray();
      var shieldRootIds = shieldFunctions.Select(row => row.Id).ToHashSet();
      var skillShieldBindingCount = skillRelations.Count(row =>
          (row.UseFunctionIdSkill ?? []).Concat(row.HurtFunctionIdSkill ?? [])
              .Any(shieldRootIds.Contains));
      var passiveShieldBindingCount = selectedStateEffects.Count(row =>
          StateEffectFunctionIds(row).Any(shieldRootIds.Contains));

      var behaviorKeys = new[]
      {
        targetMonster.SpotAi,
        targetMonster.SpotAiDefense,
        targetMonster.SpotAiBasedefense
      }
          .Where(value => !string.IsNullOrWhiteSpace(value))
          .Select(value => value!)
          .Distinct(StringComparer.Ordinal)
          .Order(StringComparer.Ordinal)
          .ToArray();
      var targetObservation = CreateTargetObservation(
          seasonNumber,
          HashBytes(archive),
          manager[0],
          presets[0],
          wave,
          targetMonster,
          model,
          statRows[0]);
      var fxTuples = shieldFunctions.Select(FxTuple)
          .Where(tuple => tuple.Prefabs.Length > 0)
          .GroupBy(tuple => tuple.Sha256, StringComparer.Ordinal)
          .Select(group => group.First())
          .OrderBy(tuple => tuple.Sha256, StringComparer.Ordinal)
          .ToArray();
      var fxPrefabSets = shieldFunctions.Where(row => FxTuple(row).Prefabs.Length > 0)
          .Select(FxPrefabSetSha256)
          .Distinct(StringComparer.Ordinal)
          .Order(StringComparer.Ordinal)
          .ToArray();
      var shieldMode = shieldFunctions.Length == 0
          ? "none"
          : "dynamic_affinity_linked";
      var unresolvedCodes = new List<string>();
      if (missingSkillCount != 0) unresolvedCodes.Add("monster_skill_reference_missing");
      if (missingPassiveCount != 0) unresolvedCodes.Add("passive_state_effect_reference_missing");
      if (closure.MissingIds.Count != 0) unresolvedCodes.Add("function_reference_missing");
      if (behaviorKeys.Length == 0) unresolvedCodes.Add("behavior_root_missing");
      if (shieldFunctions.Length > 0 && fxTuples.Length == 0)
        unresolvedCodes.Add("element_shield_fx_binding_missing");

      var receipt = new
      {
        schemaVersion = 1,
        contractId = "nll/boss-content-discovery/v1",
        profileCode,
        seasonNumber,
        displayNameCode,
        sourceStaticDataSha256 = HashBytes(archive),
        challengeSelector = new
        {
          difficultyTypeCode = "challenge",
          waveOrder = ChallengeWaveOrder,
          targetCardinality = 1
        },
        selectedManagerObservation = targetObservation,
        sourceAffinity = new
        {
          bossElementCode = sourceBossElementCode,
          weaknessCode = sourceWeaknessCode
        },
        skillClosure = new
        {
          monsterSkillRelationCount = skillRelations.Length,
          monsterSkillRecordCount = selectedSkillRows.Length,
          passiveStateEffectRecordCount = selectedStateEffects.Length,
          rootFunctionRecordCount = rootFunctionIds.Length,
          closedFunctionRecordCount = closure.Rows.Count,
          missingReferenceCount = missingSkillCount + missingPassiveCount + closure.MissingIds.Count,
          canonicalSha256 = HashRecordSet(selectedSkillRows
              .Cast<object>()
              .Concat(selectedStateEffects)
              .Concat(closure.Rows))
        },
        behaviorAssembly = new
        {
          modeCode = "preserve_target_monster_behavior_graph",
          rootReferenceCount = behaviorKeys.Length,
          rootReferenceSetSha256 = HashStrings(behaviorKeys),
          assetClosureStatusCode = "pending_asset_catalog_resolution"
        },
        partClosure = new
        {
          partRecordCount = parts.Length,
          mainPartCount = parts.Count(row => row.IsMainPart),
          passivePartCount = parts.Count(row => row.PassiveSkillId != 0),
          canonicalSha256 = HashRecordSet(parts.Cast<object>())
        },
        elementShield = new
        {
          modeCode = shieldMode,
          functionTypeCode = shieldFunctions.Length == 0
              ? "not_applicable"
              : "immune_other_element",
          functionRecordCount = shieldFunctions.Length,
          skillBindingCount = skillShieldBindingCount,
          passiveBindingCount = passiveShieldBindingCount,
          functionSetSha256 = HashRecordSet(shieldFunctions.Cast<object>()),
          fxTupleCount = fxTuples.Length,
          fxTupleSetSha256 = HashStrings(fxTuples.Select(tuple => tuple.Sha256)),
          fxPrefabSetCount = fxPrefabSets.Length,
          fxPrefabSetSha256 = HashStrings(fxPrefabSets),
          fxVariantStatusCode = shieldFunctions.Length == 0
              ? "not_required"
              : "pending_asset_catalog_resolution"
        },
        quickTimeEventAffinity = new
        {
          modeCode = targetQuickTimeEvents.Length == 0
              ? "not_applicable"
              : "target_monster_linked_element_only",
          recordCount = targetQuickTimeEvents.Length,
          monsterReferenceCount = quickTimeEventMonsterIds.Length,
          recordSetSha256 = HashRecordSet(targetQuickTimeEvents.Cast<object>()),
          immutablePayloadSetSha256 = BossQuickTimeEventVariant.HashImmutable(
              targetQuickTimeEvents),
          sourceElementSetSha256 = HashStrings(targetQuickTimeEvents
              .Select(row => row.ElementId.ToString(CultureInfo.InvariantCulture))
              .Distinct(StringComparer.Ordinal)
              .Order(StringComparer.Ordinal)),
          sourceElementCodes = targetQuickTimeEvents
              .Select(row => elementById.TryGetValue(row.ElementId, out var element)
                  ? ElementCode(element.Element)
                  : "unresolved")
              .Distinct(StringComparer.Ordinal)
              .Order(StringComparer.Ordinal)
              .ToArray()
        },
        unresolvedReasonCodes = unresolvedCodes,
        discoveryStatusCode = unresolvedCodes.Count == 0
            ? "static_graph_resolved"
            : "blocked",
        rawSourceIdentifiersPersisted = false
      };
      await WriteAtomicTextAsync(outputPath, JsonSerializer.Serialize(
          receipt,
          new JsonSerializerOptions { WriteIndented = true }) + "\n");

      if (privateOutputPath is not null)
      {
        var privateDocument = new
        {
          schemaVersion = 1,
          contractId = "nll/private-boss-content-diagnostic/v1",
          seasonNumber,
          managerId = manager[0].Id,
          presetId = presets[0].Id,
          waveId = wave.StageId,
          targetMonsterId = targetMonster.Id,
          targetMonsterModelId = targetMonster.MonsterModelId,
          behaviorKeys,
          skillIds,
          passiveIds,
          rootFunctionIds,
          closedFunctionIds = closure.Rows.Select(row => row.Id).Order().ToArray(),
          shieldFunctions = shieldFunctions.Select(row => new
          {
            row.Id,
            row.GroupId,
            functionType = (int)row.FunctionType,
            row.FunctionValue,
            fx = FxTuple(row).Prefabs,
            fxTupleSha256 = FxTuple(row).Sha256,
            fxPrefabSetSha256 = FxPrefabSetSha256(row),
            fxAttachmentSha256 = FxAttachmentSha256(row),
            fxAttachment = FxAttachmentValues(row)
          }),
          quickTimeEvents = targetQuickTimeEvents.Select(row => new
          {
            row.Id,
            row.MonsterId,
            row.QtePrefab,
            row.GroupId,
            row.RandomPreset,
            row.TimeLimit,
            row.FirstColAnimTime,
            row.ElementId
          }),
          globalShieldFxCandidates = functions.Values
              .Where(row => (int)row.FunctionType == ImmuneOtherElementFunctionType)
              .Select(row => new
              {
                row.Id,
                row.GroupId,
                fx = FxTuple(row).Prefabs,
                fxTupleSha256 = FxTuple(row).Sha256,
                fxPrefabSetSha256 = FxPrefabSetSha256(row),
                fxAttachmentSha256 = FxAttachmentSha256(row),
                fxAttachment = FxAttachmentValues(row)
              })
              .Where(row => row.fx.Length > 0)
              .OrderBy(row => row.Id)
        };
        await WriteAtomicTextAsync(privateOutputPath, JsonSerializer.Serialize(
            privateDocument,
            new JsonSerializerOptions { WriteIndented = true }) + "\n");
      }
    }
    finally
    {
      CryptographicOperations.ZeroMemory(archive);
    }
  }

  private static BossFunctionClosure ResolveFunctionClosure(
      IReadOnlyList<int> rootIds,
      IReadOnlyDictionary<int, FunctionRecord> rows)
  {
    var pending = new Queue<int>(rootIds);
    var visited = new HashSet<int>();
    var missing = new HashSet<int>();
    var selected = new List<FunctionRecord>();
    while (pending.TryDequeue(out var id))
    {
      if (id == 0 || !visited.Add(id)) continue;
      if (!rows.TryGetValue(id, out var row))
      {
        missing.Add(id);
        continue;
      }
      selected.Add(row);
      foreach (var connected in row.ConnectedFunction ?? []) pending.Enqueue(connected);
    }
    return new(
        selected.OrderBy(row => row.Id).ToArray(),
        missing.Order().ToArray());
  }

  private static IEnumerable<int> StateEffectFunctionIds(StateEffectRecord row) =>
      (row.UseFunctionIdList ?? [])
          .Concat(row.HurtFunctionIdList ?? [])
          .Concat((row.Functions ?? []).Select(value => value.Function));

  private static object CreateTargetObservation(
      int seasonNumber,
      string sourceObservationSha256,
      SoloRaidManagerRecord manager,
      SoloRaidPresetRecord preset,
      WaveDataRecord wave,
      MonsterRecord monster,
      MonsterModelRecord model,
      MonsterStatEnhanceRecord stat)
  {
    var contractId = $"nll/season{seasonNumber.ToString(CultureInfo.InvariantCulture)}-classic-target-observation/v3";
    var emitter = new TargetObservationEmitter(contractId);
    emitter.Role(() => EmitManager(emitter, manager));
    emitter.Role(() => EmitPreset(emitter, preset));
    emitter.Role(() => EmitWave(emitter, wave, monster.Id));
    emitter.Role(() => EmitMonster(emitter, monster));
    emitter.Role(() => EmitModel(emitter, model));
    emitter.Role(() => EmitStat(emitter, stat));
    var bytes = emitter.Finish();
    try
    {
      Require(emitter.RoleLineCounts.Take(3).SequenceEqual(ExpectedFixedRoleLineCounts),
          "phase_d_boss_discovery_observation_shape_invalid");
      return new
      {
        contractId,
        canonicalizationCode = "role_path_type_value_tsv_lf_target_projection/v3",
        sourceObservationSha256,
        roleLineCounts = emitter.RoleLineCounts,
        canonicalLineCount = emitter.LineCount,
        canonicalByteLength = bytes.Length,
        trustedSha256 = HashBytes(bytes)
      };
    }
    finally
    {
      CryptographicOperations.ZeroMemory(bytes);
    }

  }

  private static void EmitManager(TargetObservationEmitter e, SoloRaidManagerRecord r)
  {
    e.Int32("manager", "id", r.Id);
    e.Int32("manager", "monsterPreset", r.MonsterPreset);
    e.Int32("manager", "rankingGroupId", r.RankingGroupId);
  }

  private static void EmitPreset(TargetObservationEmitter e, SoloRaidPresetRecord r)
  {
    e.Int32("challenge_preset", "id", r.Id);
    e.Int32("challenge_preset", "presetGroupId", r.PresetGroupId);
    e.Int32("challenge_preset", "difficultyType", (int)r.DifficultyType);
    e.Int32("challenge_preset", "quickBattleType", (int)r.QuickBattleType);
    e.Int32("challenge_preset", "characterLv", r.CharacterLv);
    e.Int32("challenge_preset", "waveOpenCondition", r.WaveOpenCondition);
    e.Int32("challenge_preset", "waveOrder", r.WaveOrder);
    e.Int32("challenge_preset", "wave", r.Wave);
    e.Int32("challenge_preset", "monsterStageLv", r.MonsterStageLv);
    e.Int32("challenge_preset", "monsterStageLvChangeGroup", r.MonsterStageLvChangeGroup);
    e.Int32("challenge_preset", "dynamicObjectStageLv", r.DynamicObjectStageLv);
    e.Int32("challenge_preset", "coverStageLv", r.CoverStageLv);
    e.Bool("challenge_preset", "spotAutocontrol", r.SpotAutocontrol);
  }

  private static void EmitWave(TargetObservationEmitter e, WaveDataRecord r, long targetMonsterId)
  {
    var targetList = (r.TargetList ?? []).Where(value => value == targetMonsterId).ToList();
    var targetWaves = (r.WaveData ?? [])
        .Select(item => new
        {
          Wave = item,
          Monsters = (item.WaveMonsterList ?? [])
              .Where(monster => monster.WaveMonsterId == targetMonsterId)
              .ToList()
        })
        .Where(item => item.Monsters.Count > 0)
        .ToList();
    e.Int32("wave", "stageId", r.StageId);
    e.String("wave", "groupId", r.GroupId);
    e.Int32("wave", "spotMod", (int)r.SpotMod);
    e.Int32("wave", "battleTime", r.BattleTime);
    e.Int32("wave", "monsterCount", r.MonsterCount);
    e.Array("wave", "targetList", targetList,
        (path, value) => e.Int64("wave", path, value));
    e.Array("wave", "waveData", targetWaves, (wavePath, targetWave) =>
    {
      e.String("wave", $"{wavePath}.wavePath", targetWave.Wave.WavePath);
      e.Int32("wave", $"{wavePath}.privateMonsterCount", targetWave.Wave.PrivateMonsterCount);
      e.Array("wave", $"{wavePath}.waveMonsterList", targetWave.Monsters,
          (monsterPath, item) =>
          {
            e.Int64("wave", $"{monsterPath}.waveMonsterId", item.WaveMonsterId);
            e.Int32("wave", $"{monsterPath}.spawnType", (int)item.SpawnType);
          });
    });
  }

  private static void EmitMonster(TargetObservationEmitter e, MonsterRecord r)
  {
    const string role = "monster";
    e.Int64(role, "id", r.Id);
    e.Int32(role, "monsterModelId", r.MonsterModelId);
    e.Int32(role, "uiGrade", (int)r.UiGrade);
    e.Int32(role, "hpRatio", r.HpRatio);
    e.Int32(role, "defenceRatio", r.DefenceRatio);
    e.Int32(role, "attackRatio", r.AttackRatio);
    e.Int32(role, "defenceRatioRatio", r.DefenceRatioRatio);
    e.Int32(role, "energyResistRatio", r.EnergyResistRatio);
    e.Int32(role, "metalResistRatio", r.MetalResistRatio);
    e.Int32(role, "bioResistRatio", r.BioResistRatio);
    e.String(role, "spotAi", r.SpotAi);
    e.String(role, "spotAiDefense", r.SpotAiDefense);
    e.String(role, "spotAiBasedefense", r.SpotAiBasedefense);
    e.Int32(role, "fixedSpawnType", (int)r.FixedSpawnType);
    e.Int32(role, "passiveSkillId", r.PassiveSkillId);
    e.Int32(role, "statenhanceId", r.StatenhanceId);
    e.Array(role, "elementId", r.ElementId ?? [],
        (path, value) => e.Int32(role, path, value));
    var skills = (r.SkillData ?? []).Where(skill => skill.SkillId != 0).ToList();
    e.Array(role, "skillData", skills, (skillPath, skill) =>
    {
      e.Int32(role, $"{skillPath}.skillId", skill.SkillId);
      e.Array(role, $"{skillPath}.useFunctionIdSkill", skill.UseFunctionIdSkill ?? [],
          (path, value) => e.Int32(role, path, value));
      e.Array(role, $"{skillPath}.hurtFunctionIdSkill", skill.HurtFunctionIdSkill ?? [],
          (path, value) => e.Int32(role, path, value));
    });
  }

  private static void EmitModel(TargetObservationEmitter e, MonsterModelRecord r)
  {
    const string role = "model";
    e.Int32(role, "id", r.Id);
    e.Int32(role, "resourceId", r.ResourceId);
    e.String(role, "monPrefab", r.MonPrefab);
    e.Int32(role, "grade", (int)r.Grade);
    e.Int32(role, "size", (int)r.Size);
    e.Int32(role, "dissolveType", (int)r.DissolveType);
    e.Int32(role, "attribute", (int)r.Attribute);
    e.Int32(role, "moveType", (int)r.MoveType);
    e.Int32(role, "categoryType1", (int)r.CategoryType1);
    e.Int32(role, "categoryType2", (int)r.CategoryType2);
    e.Int32(role, "categoryType3", (int)r.CategoryType3);
    e.Int32(role, "class", (int)r.Class);
  }

  private static void EmitStat(TargetObservationEmitter e, MonsterStatEnhanceRecord r)
  {
    const string role = "stat_enhance";
    e.Int32(role, "id", r.Id);
    e.Int32(role, "groupId", r.GroupId);
    e.Int32(role, "lv", r.Lv);
    e.Int64(role, "levelHp", r.LevelHp);
    e.Int32(role, "levelAttack", r.LevelAttack);
    e.Int32(role, "levelDefence", r.LevelDefence);
    e.Int32(role, "levelStatdamageratio", r.LevelStatdamageratio);
    e.Int32(role, "levelEnergyResist", r.LevelEnergyResist);
    e.Int32(role, "levelMetalResist", r.LevelMetalResist);
    e.Int32(role, "levelBioResist", r.LevelBioResist);
    e.Int32(role, "levelProjectileHp", r.LevelProjectileHp);
    e.Int64(role, "levelBrokenHp", r.LevelBrokenHp);
  }

  private static BossFxTuple FxTuple(FunctionRecord row)
  {
    var values = new[]
    {
      row.FxPrefab01, row.FxPrefab02, row.FxPrefab03, row.FxPrefabFull,
      row.FxPrefab01Arena, row.FxPrefab02Arena, row.FxPrefab03Arena
    }.Where(value => !string.IsNullOrWhiteSpace(value)).Select(value => value!).ToArray();
    var canonical = string.Join("\n", new[]
    {
      row.FxPrefab01 ?? "", ((int)row.FxTarget01).ToString(CultureInfo.InvariantCulture),
      ((int)row.FxSocketPoint01).ToString(CultureInfo.InvariantCulture),
      row.FxPrefab02 ?? "", ((int)row.FxTarget02).ToString(CultureInfo.InvariantCulture),
      ((int)row.FxSocketPoint02).ToString(CultureInfo.InvariantCulture),
      row.FxPrefab03 ?? "", ((int)row.FxTarget03).ToString(CultureInfo.InvariantCulture),
      ((int)row.FxSocketPoint03).ToString(CultureInfo.InvariantCulture),
      row.FxPrefabFull ?? "", ((int)row.FxTargetFull).ToString(CultureInfo.InvariantCulture),
      ((int)row.FxSocketPointFull).ToString(CultureInfo.InvariantCulture),
      row.FxPrefab01Arena ?? "", ((int)row.FxTarget01Arena).ToString(CultureInfo.InvariantCulture),
      ((int)row.FxSocketPoint01Arena).ToString(CultureInfo.InvariantCulture),
      row.FxPrefab02Arena ?? "", ((int)row.FxTarget02Arena).ToString(CultureInfo.InvariantCulture),
      ((int)row.FxSocketPoint02Arena).ToString(CultureInfo.InvariantCulture),
      row.FxPrefab03Arena ?? "", ((int)row.FxTarget03Arena).ToString(CultureInfo.InvariantCulture),
      ((int)row.FxSocketPoint03Arena).ToString(CultureInfo.InvariantCulture)
    });
    return new(HashStrings([canonical]), values);
  }

  private static string FxAttachmentSha256(FunctionRecord row) => HashStrings([
      string.Join("\n", new[]
      {
        ((int)row.FxTarget01).ToString(CultureInfo.InvariantCulture),
        ((int)row.FxSocketPoint01).ToString(CultureInfo.InvariantCulture),
        ((int)row.FxTarget02).ToString(CultureInfo.InvariantCulture),
        ((int)row.FxSocketPoint02).ToString(CultureInfo.InvariantCulture),
        ((int)row.FxTarget03).ToString(CultureInfo.InvariantCulture),
        ((int)row.FxSocketPoint03).ToString(CultureInfo.InvariantCulture),
        ((int)row.FxTargetFull).ToString(CultureInfo.InvariantCulture),
        ((int)row.FxSocketPointFull).ToString(CultureInfo.InvariantCulture),
        ((int)row.FxTarget01Arena).ToString(CultureInfo.InvariantCulture),
        ((int)row.FxSocketPoint01Arena).ToString(CultureInfo.InvariantCulture),
        ((int)row.FxTarget02Arena).ToString(CultureInfo.InvariantCulture),
        ((int)row.FxSocketPoint02Arena).ToString(CultureInfo.InvariantCulture),
        ((int)row.FxTarget03Arena).ToString(CultureInfo.InvariantCulture),
        ((int)row.FxSocketPoint03Arena).ToString(CultureInfo.InvariantCulture)
      })
    ]);

  private static string FxPrefabSetSha256(FunctionRecord row) => HashStrings([
      string.Join("\n", new[]
      {
        row.FxPrefab01 ?? "", row.FxPrefab02 ?? "", row.FxPrefab03 ?? "",
        row.FxPrefabFull ?? "", row.FxPrefab01Arena ?? "",
        row.FxPrefab02Arena ?? "", row.FxPrefab03Arena ?? ""
      })
    ]);

  private static int[] FxAttachmentValues(FunctionRecord row) =>
  [
    (int)row.FxTarget01, (int)row.FxSocketPoint01,
    (int)row.FxTarget02, (int)row.FxSocketPoint02,
    (int)row.FxTarget03, (int)row.FxSocketPoint03,
    (int)row.FxTargetFull, (int)row.FxSocketPointFull,
    (int)row.FxTarget01Arena, (int)row.FxSocketPoint01Arena,
    (int)row.FxTarget02Arena, (int)row.FxSocketPoint02Arena,
    (int)row.FxTarget03Arena, (int)row.FxSocketPoint03Arena
  ];

  internal static byte[] GetDecodedArchive(GameData gameData)
  {
    var field = typeof(GameData).GetField("ZipStream", BindingFlags.Instance | BindingFlags.NonPublic);
    var stream = field?.GetValue(gameData) as MemoryStream;
    Require(stream is not null, "phase_d_staticdata_binding_unavailable");
    return stream!.ToArray();
  }

  internal static T[] DeserializeEntry<T>(byte[] archive, string entryName) where T : class
  {
    using var stream = new MemoryStream(archive, writable: false);
    using var zip = new ZipArchive(stream, ZipArchiveMode.Read, leaveOpen: false);
    var matches = zip.Entries.Where(entry =>
        string.Equals(entry.FullName, entryName, StringComparison.Ordinal)).Take(2).ToArray();
    Require(matches.Length == 1, "phase_d_boss_discovery_table_missing");
    using var entryStream = matches[0].Open();
    using var output = new MemoryStream();
    entryStream.CopyTo(output);
    var bytes = output.ToArray();
    try
    {
      return MemoryPackSerializer.Deserialize<T[]>(bytes) ??
          throw new InvalidOperationException("phase_d_boss_discovery_table_invalid");
    }
    finally
    {
      CryptographicOperations.ZeroMemory(bytes);
    }
  }

  private static string HashRecordSet(IEnumerable<object> rows)
  {
    using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
    foreach (var row in rows)
    {
      var bytes = MemoryPackSerializer.Serialize(row.GetType(), row);
      try
      {
        hash.AppendData(bytes);
      }
      finally
      {
        CryptographicOperations.ZeroMemory(bytes);
      }
    }
    return Convert.ToHexStringLower(hash.GetHashAndReset());
  }

  private static string HashStrings(IEnumerable<string> values) =>
      HashBytes(Encoding.UTF8.GetBytes(string.Join("\n", values)));

  private static string HashBytes(byte[] bytes) =>
      Convert.ToHexStringLower(SHA256.HashData(bytes));

  internal static string ElementCode(AttackType value) => value switch
  {
    AttackType.Fire => "fire",
    AttackType.Water => "water",
    AttackType.Wind => "wind",
    AttackType.Electronic => "electric",
    AttackType.Iron => "iron",
    _ => throw new InvalidOperationException("phase_d_boss_discovery_affinity_unresolved")
  };

  private static bool IsCode(string value) =>
      value.Length is >= 1 and <= 64 &&
      value[0] is >= 'a' and <= 'z' &&
      value.All(character => character is >= 'a' and <= 'z' or >= '0' and <= '9' or '.' or '_' or '-');

  private static async Task WriteAtomicTextAsync(string path, string text)
  {
    Directory.CreateDirectory(Path.GetDirectoryName(path)!);
    var temporary = path + ".partial-" + Guid.NewGuid().ToString("N");
    await File.WriteAllTextAsync(temporary, text, new UTF8Encoding(false));
    File.Move(temporary, path);
  }

  private static void Require(bool condition, string code)
  {
    if (!condition) throw new InvalidOperationException(code);
  }

  private sealed record BossFunctionClosure(
      IReadOnlyList<FunctionRecord> Rows,
      IReadOnlyList<int> MissingIds);

  private sealed record BossFxTuple(string Sha256, string[] Prefabs);

  private sealed class TargetObservationEmitter(string contractId)
  {
    private readonly StringBuilder _text = new($"contractId\tstring\t{contractId}\n");
    private readonly List<int> _roleLineCounts = [];
    public int LineCount { get; private set; } = 1;
    public IReadOnlyList<int> RoleLineCounts => _roleLineCounts;

    public void Role(Action emit)
    {
      var before = LineCount;
      emit();
      _roleLineCounts.Add(LineCount - before);
    }

    public void Int32(string role, string path, int value) =>
        Line(role, path, "int32", value.ToString(CultureInfo.InvariantCulture));
    public void Int64(string role, string path, long value) =>
        Line(role, path, "int64", value.ToString(CultureInfo.InvariantCulture));
    public void Bool(string role, string path, bool value) =>
        Line(role, path, "bool", value ? "true" : "false");
    public void String(string role, string path, string? value)
    {
      Require(value is not null && value.IndexOfAny(['\t', '\r', '\n']) < 0,
          "phase_d_boss_discovery_observation_string_invalid");
      Line(role, path, "string", value!.Normalize(NormalizationForm.FormC));
    }
    public void Array<T>(string role, string path, IReadOnlyList<T> values, Action<string, T> emit)
    {
      Line(role, $"{path}.count", "uint32", values.Count.ToString(CultureInfo.InvariantCulture));
      for (var index = 0; index < values.Count; index++) emit($"{path}[{index}]", values[index]);
    }
    public byte[] Finish() => new UTF8Encoding(false).GetBytes(_text.ToString());
    private void Line(string role, string path, string type, string value)
    {
      _text.Append(role).Append('\t').Append(path).Append('\t').Append(type).Append('\t')
          .Append(value).Append('\n');
      LineCount++;
    }
  }
}
