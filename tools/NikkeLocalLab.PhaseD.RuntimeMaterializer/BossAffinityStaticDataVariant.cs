using System.IO.Compression;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using EpinelPS.Data;
using EpinelPS.Models;
using EpinelPS.SoloRaidSelection;
using EpinelPS.Utils;
using MemoryPack;

internal sealed record BossAffinityStaticDataVariantResult(
    string VariantProfileCode,
    string VariantProfileSha256,
    int SeasonNumber,
    string WeaknessCode,
    string SourceBossElementCode,
    string SourceBossWeaknessCode,
    string TargetBossElementCode,
    bool VariantRequired,
    string? VariantSha256);

internal static class BossAffinityStaticDataVariant
{
  internal static int ResolveUniqueUserValidationManager(GameData gameData, BossRuntimeVariantProfile profile)
  {
    var validator = CreateTargetObservationValidator(gameData, profile);
    var matches = gameData.SoloRaidManagerTable.Keys
        .Where(id => validator.Validate(id).IsTrustedTarget).Take(2).ToArray();
    Require(matches.Length == 1, "phase_d_boss_variant_manager_observation_not_unique");
    // Reuse the exact Challenge preset/wave/spawned target closure, not a season label lookup.
    _ = ResolveChallengeTargetMonsterId(gameData, new User { SelectedClassicSoloRaidManagerId = matches[0] }, profile);
    return matches[0];
  }

  internal static void ValidateUserValidationSelection(GameData gameData, BossRuntimeVariantProfile profile, User user)
  {
    var resolution = SoloRaidManagerSelectionResolver.Resolve(user, CreateTargetObservationValidator(gameData, profile));
    Require(resolution.IsValid && resolution.Code == ClassicSoloRaidSelectionCode.SelectedWithoutActiveRun,
        "phase_d_user_validation_account_active_run_or_selection_invalid");
  }

  public static object InspectTargetObservation(
      GameData gameData,
      BossRuntimeVariantProfile profile)
  {
    var validator = CreateTargetObservationValidator(gameData, profile);
    var results = gameData.SoloRaidManagerTable.Keys
        .Select(managerId => validator.Validate(managerId))
        .ToArray();
    return new
    {
      schemaVersion = 1,
      contractId = "nll/boss-target-observation-validation/v1",
      profileCode = profile.ProfileCode,
      seasonNumber = profile.SeasonNumber,
      managerRecordCount = results.Length,
      trustedTargetCount = results.Count(result => result.IsTrustedTarget),
      rejectionCounts = results.Where(result => !result.IsTrustedTarget)
          .GroupBy(result => result.Code, StringComparer.Ordinal)
          .OrderBy(group => group.Key, StringComparer.Ordinal)
          .ToDictionary(group => group.Key, group => group.Count(), StringComparer.Ordinal),
      rawSourceIdentifiersPersisted = false
    };
  }

  public static async Task<BossAffinityStaticDataVariantResult> CreateAsync(
      GameData gameData,
      User user,
      BossRuntimeVariantProfile profile,
      string weaknessCode,
      string sourcePackPath,
      string variantPackPath,
      string receiptPath)
  {
    weaknessCode = NormalizeCode(weaknessCode) ??
        throw new InvalidOperationException("phase_d_weakness_code_invalid");
    sourcePackPath = Path.GetFullPath(sourcePackPath);
    variantPackPath = Path.GetFullPath(variantPackPath);
    receiptPath = Path.GetFullPath(receiptPath);
    Require(File.Exists(sourcePackPath), "phase_d_staticdata_pack_missing");
    Require(!File.Exists(variantPackPath) && !File.Exists(receiptPath),
        "phase_d_staticdata_variant_output_exists");
    Require(profile.ElementShield.ModeCode is "none" or "dynamic_affinity_linked",
        "phase_d_boss_variant_element_shield_not_supported");

    var targetMonsterId = ResolveChallengeTargetMonsterId(gameData, user, profile);
    var decodedArchive = GetDecodedArchive(gameData);
    var elementRows = DeserializeEntry<ElementRecord>(decodedArchive, "ElementTable.mpk");
    var monsterRows = DeserializeEntry<MonsterRecord>(decodedArchive, "MonsterTable.mpk");
    var partRows = DeserializeEntry<MonsterPartsRecord>(decodedArchive, "MonsterPartsTable.mpk");
    var stateEffectRows = DeserializeEntry<StateEffectRecord>(decodedArchive, "StateEffectTable.mpk");
    var functionRows = DeserializeEntry<FunctionRecord>(decodedArchive, "FunctionTable.mpk");
    var quickTimeEventRows = DeserializeEntry<QuickTimeEventRecord>(decodedArchive, "QuickTimeEventTable.mpk");
    var sourceQuickTimeEventRows = DeserializeEntry<QuickTimeEventRecord>(decodedArchive, "QuickTimeEventTable.mpk");
    ValidateElementTableIndex(elementRows);
    Require(monsterRows.Select(row => row.Id).Distinct().Count() == monsterRows.Length,
        "phase_d_staticdata_monster_index_invalid");
    var targetMonster = monsterRows.SingleOrDefault(row => row.Id == targetMonsterId);
    Require(targetMonster is not null && targetMonster.ElementId is [_],
        "phase_d_staticdata_target_monster_invalid");
    var targetShieldFunctions = ResolveTargetShieldFunctions(
        targetMonster!, partRows, stateEffectRows, functionRows);
    ValidateShieldContract(profile, targetShieldFunctions);

    var elementById = elementRows.ToDictionary(row => row.Id);
    var sourceWeaknessCodes = targetMonster!.ElementId
        .Select(elementId => WeaknessCodeForElement(elementId, elementById))
        .Distinct(StringComparer.Ordinal)
        .ToArray();
    Require(sourceWeaknessCodes.Length == 1, "phase_d_staticdata_source_weakness_ambiguous");
    var sourceWeaknessCode = sourceWeaknessCodes[0];
    var sourceBossElementCodes = targetMonster.ElementId
        .Select(elementId =>
        {
          Require(elementById.TryGetValue(elementId, out var element),
              "phase_d_staticdata_element_chain_invalid");
          return CodeForAttackType(element!.Element);
        })
        .Distinct(StringComparer.Ordinal)
        .ToArray();
    Require(sourceBossElementCodes.Length == 1,
        "phase_d_staticdata_source_boss_element_ambiguous");
    var sourceBossElementCode = sourceBossElementCodes[0];
    Require(sourceBossElementCode == profile.SourceAffinity.BossElementCode &&
            sourceWeaknessCode == profile.SourceAffinity.WeaknessCode,
        "phase_d_boss_variant_source_affinity_mismatch");
    var targetBossElementCode = CodeForAttackType(
        BossElementTypeForWeakness(AttackTypeForCode(weaknessCode)));
    var targetShieldFxVariant = profile.ElementShield.ModeCode == "dynamic_affinity_linked"
        ? profile.ElementShield.FxVariants.SingleOrDefault(value =>
            value.BossElementCode == targetBossElementCode)
        : null;
    Require(profile.ElementShield.ModeCode != "dynamic_affinity_linked" ||
            targetShieldFxVariant is not null,
        "phase_d_boss_variant_element_shield_fx_unresolved");
    var sourceShieldFxPrefabSetSha256 = HashStrings(targetShieldFunctions
        .Where(HasFxBinding)
        .Select(ShieldFxPrefabSetSha256)
        .Distinct(StringComparer.Ordinal)
        .Order(StringComparer.Ordinal));
    var targetShieldMappings = targetShieldFxVariant?.Mappings.ToDictionary(
        value => value.SourceFxPrefabSetSha256,
        StringComparer.Ordinal) ?? [];
    var expectedShieldFxSetByFunctionId = targetShieldFunctions
        .Where(HasFxBinding)
        .ToDictionary(
            row => row.Id,
            row =>
            {
              var sourceSet = ShieldFxPrefabSetSha256(row);
              Require(targetShieldMappings.TryGetValue(sourceSet, out var mapping),
                  "phase_d_boss_variant_element_shield_fx_unresolved");
              return mapping!.TargetFxPrefabSetSha256;
            });
    var shieldFxVariantRequired = expectedShieldFxSetByFunctionId.Any(pair =>
        ShieldFxPrefabSetSha256(targetShieldFunctions.Single(row => row.Id == pair.Key)) !=
            pair.Value);
    var elementVariantRequired =
        !string.Equals(sourceWeaknessCode, weaknessCode, StringComparison.Ordinal);
    var variantRequired = elementVariantRequired || shieldFxVariantRequired;
    var sourceBossElementId = targetMonster.ElementId[0];
    var elementCodeById = elementById.ToDictionary(pair => pair.Key, pair => CodeForAttackType(pair.Value.Element));
    BossQuickTimeEventVariant.ValidateSource(quickTimeEventRows, targetMonsterId,
        profile.QuickTimeEventAffinity, elementCodeById);
    string? variantSha256 = null;
    var modifiedMonsterCount = 0;
    var modifiedFunctionCount = 0;
    var modifiedQuickTimeEventCount = 0;

    if (variantRequired)
    {
      var requestedWeakness = AttackTypeForCode(weaknessCode);
      var targetBossElement = BossElementTypeForWeakness(requestedWeakness);
      var canonicalTargetElements = elementRows
          .Where(row => row.Element == targetBossElement)
          .Take(2)
          .ToArray();
      Require(canonicalTargetElements.Length == 1,
          "phase_d_staticdata_requested_element_ambiguous");
      modifiedQuickTimeEventCount = BossQuickTimeEventVariant.Apply(quickTimeEventRows, targetMonsterId,
          profile.QuickTimeEventAffinity, elementCodeById, sourceBossElementId, canonicalTargetElements[0].Id);
      BossQuickTimeEventVariant.VerifyBoundary(sourceQuickTimeEventRows, quickTimeEventRows,
          targetMonsterId, canonicalTargetElements[0].Id, modifiedQuickTimeEventCount);
      var sourceMonsterFingerprints = monsterRows.ToDictionary(row => row.Id, FingerprintRecord);
      var sourceFunctionFingerprints = functionRows.ToDictionary(row => row.Id, FingerprintRecord);
      if (elementVariantRequired)
      {
        targetMonster.ElementId = [canonicalTargetElements[0].Id];
      }
      modifiedMonsterCount = CountModifiedMonsterRecords(
          monsterRows, sourceMonsterFingerprints, targetMonsterId);
      Require(modifiedMonsterCount == (elementVariantRequired ? 1 : 0),
          "phase_d_staticdata_target_monster_reference_not_isolated");

      if (shieldFxVariantRequired)
      {
        var targetPrefabSets = targetShieldMappings.Values
            .Select(mapping => mapping.TargetFxPrefabSetSha256)
            .Distinct(StringComparer.Ordinal)
            .ToArray();
        var fxSources = new Dictionary<string, ShieldFxPrefabs>(StringComparer.Ordinal);
        foreach (var targetPrefabSet in targetPrefabSets)
        {
          var fxCandidates = functionRows
              .Where(row => HasFxBinding(row) &&
                  ShieldFxPrefabSetSha256(row) == targetPrefabSet)
              .ToArray();
          Require(fxCandidates.Length > 0,
              "phase_d_boss_variant_element_shield_fx_unresolved");
          var fxSource = fxCandidates[0];
          Require(fxCandidates.All(row => SameFxPrefabSet(row, fxSource)),
              "phase_d_boss_variant_element_shield_fx_ambiguous");
          fxSources.Add(targetPrefabSet, ReadFxPrefabs(fxSource));
        }
        foreach (var shieldFunction in targetShieldFunctions.Where(HasFxBinding))
        {
          var expectedSet = expectedShieldFxSetByFunctionId[shieldFunction.Id];
          if (ShieldFxPrefabSetSha256(shieldFunction) != expectedSet)
          {
            CopyFxPrefabs(fxSources[expectedSet], shieldFunction);
          }
        }
      }
      modifiedFunctionCount = CountModifiedFunctionRecords(
          functionRows,
          sourceFunctionFingerprints,
          targetShieldFunctions.Select(row => row.Id).ToHashSet());
      Require(modifiedFunctionCount ==
              expectedShieldFxSetByFunctionId.Count(pair =>
                  sourceFunctionFingerprints[pair.Key] !=
                      FingerprintRecord(targetShieldFunctions.Single(row => row.Id == pair.Key))),
          "phase_d_staticdata_target_function_reference_not_isolated");

      var sourceElementTableSha256 = HashZipEntry(decodedArchive, "ElementTable.mpk");
      var replacementMonsterTable = MemoryPackSerializer.Serialize(monsterRows);
      var replacementFunctionTable = MemoryPackSerializer.Serialize(functionRows);
      var replacementMonsterTableSha256 = HashBytes(replacementMonsterTable);
      var replacementFunctionTableSha256 = HashBytes(replacementFunctionTable);
      var replacementQuickTimeEventTable = MemoryPackSerializer.Serialize(quickTimeEventRows);
      var replacementQuickTimeEventTableSha256 = modifiedQuickTimeEventCount == 0
          ? HashZipEntry(decodedArchive, "QuickTimeEventTable.mpk") : HashBytes(replacementQuickTimeEventTable);
      var replacements = new Dictionary<string, byte[]>(StringComparer.Ordinal)
      {
        ["MonsterTable.mpk"] = replacementMonsterTable,
        ["FunctionTable.mpk"] = replacementFunctionTable
      };
      if (modifiedQuickTimeEventCount > 0) replacements.Add("QuickTimeEventTable.mpk", replacementQuickTimeEventTable);
      var modifiedDecodedArchive = ReplaceZipEntries(
          decodedArchive,
          replacements);
      var variantBytes = BuildUnsignedVariantPack(
          sourcePackPath,
          modifiedDecodedArchive,
          GameConfig.Root.StaticDataMpk);
      try
      {
        Directory.CreateDirectory(Path.GetDirectoryName(variantPackPath)!);
        await WriteAtomicBytesAsync(variantPackPath, variantBytes);
        variantSha256 = Convert.ToHexStringLower(SHA256.HashData(variantBytes));
        VerifyVariantPack(
            variantPackPath,
            targetMonsterId,
            weaknessCode,
            targetBossElement,
            canonicalTargetElements[0].Id,
            sourceElementTableSha256,
            replacementMonsterTableSha256,
            replacementFunctionTableSha256,
            replacementQuickTimeEventTableSha256,
            sourceQuickTimeEventRows,
            modifiedQuickTimeEventCount,
            profile,
            targetShieldFxVariant,
            expectedShieldFxSetByFunctionId,
            GameConfig.Root.StaticDataMpk);
      }
      finally
      {
        CryptographicOperations.ZeroMemory(variantBytes);
        CryptographicOperations.ZeroMemory(modifiedDecodedArchive);
        CryptographicOperations.ZeroMemory(replacementMonsterTable);
        CryptographicOperations.ZeroMemory(replacementFunctionTable);
        CryptographicOperations.ZeroMemory(replacementQuickTimeEventTable);
      }
    }

    var receipt = new
    {
      schemaVersion = 1,
      contractId = "nll/boss-affinity-static-data-variant/v1",
      createdAtUtc = DateTimeOffset.UtcNow,
      variantProfileCode = profile.ProfileCode,
      variantProfileSha256 = profile.Sha256,
      seasonNumber = profile.SeasonNumber,
      challengeDifficultyTypeCode = profile.ChallengeSelector.DifficultyTypeCode,
      challengeWaveOrder = profile.ChallengeSelector.WaveOrder,
      sourceBossElementCode,
      targetBossElementCode,
      weaknessCode,
      sourceBossWeaknessCode = sourceWeaknessCode,
      elementShieldModeCode = profile.ElementShield.ModeCode,
      fxVariantRequired = profile.ElementShield.FxVariantRequired,
      fxVariantStatusCode = profile.ElementShield.FxVariantStatusCode,
      shieldFxVariantApplied = shieldFxVariantRequired,
      // StaticData prefab selection is not an installed/verified client bundle overlay.
      shieldFxTransformStatusCode = profile.ShieldFxTransformNormalization?.TargetBossElementCodes
          .Contains(targetBossElementCode, StringComparer.Ordinal) == true ||
          profile.ShieldFxPreparation?.Variants.Any(row => row.BossElementCode == targetBossElementCode &&
              row.OperationCode == "adjust_candidate") == true
          ? "pending_isolated_asset_overlay" : "not_required",
      runtimeAdmissionStatusCode = "not_assessed",
      shieldFxMappingSetSha256 = targetShieldFxVariant?.MappingSetSha256,
      shieldFxAssetBundles = targetShieldFxVariant?.Mappings
          .SelectMany(mapping => mapping.AssetBundles)
          .DistinctBy(bundle => (bundle.ByteLength, bundle.Sha256))
          .OrderBy(bundle => bundle.ByteLength)
          .ThenBy(bundle => bundle.Sha256, StringComparer.Ordinal)
          .Select(bundle => new { sha256 = bundle.Sha256, byteLength = bundle.ByteLength })
          .ToArray() ?? [],
      sourceShieldFxPrefabSetSha256,
      variantRequired,
      sourceStaticDataSha256 = HashFile(sourcePackPath),
      variantStaticDataSha256 = variantSha256,
      modifiedMonsterRecordCount = modifiedMonsterCount,
      modifiedFunctionRecordCount = modifiedFunctionCount,
      modifiedQuickTimeEventRecordCount = modifiedQuickTimeEventCount,
      quickTimeEventAffinityContractVerified = profile.QuickTimeEventAffinity is not null,
      modifiedElementRecordCount = 0,
      modifiedTableCount = (modifiedMonsterCount == 0 ? 0 : 1) +
          (modifiedFunctionCount == 0 ? 0 : 1) + (modifiedQuickTimeEventCount == 0 ? 0 : 1),
      modifiedTableCodes = new[]
      {
        modifiedMonsterCount == 0 ? null : "target_monster_element_reference",
        modifiedFunctionCount == 0 ? null : "target_dynamic_shield_fx_reference",
        modifiedQuickTimeEventCount == 0 ? null : "target_qte_element_reference"
      }.Where(value => value is not null).ToArray(),
      elementTablePreserved = true,
      clientElementIndexInvariantVerified = true,
      serverStaticDataModified = false,
      officialInstallModified = false,
      signatureStatusCode = variantRequired ? "original_signature_not_valid_for_derived_payload" : "source_unchanged",
      clientAcceptanceStatusCode = variantRequired ? "pending_original_client_runtime_observation" : "source_baseline",
      rawSourceIdentifierPersisted = false
    };
    await WriteAtomicTextAsync(
        receiptPath,
        JsonSerializer.Serialize(receipt, new JsonSerializerOptions { WriteIndented = true }) + "\n");
    return new(
        profile.ProfileCode,
        profile.Sha256,
        profile.SeasonNumber,
        weaknessCode,
        sourceBossElementCode,
        sourceWeaknessCode,
        targetBossElementCode,
        variantRequired,
        variantSha256);
  }

  private static long ResolveChallengeTargetMonsterId(
      GameData gameData,
      User user,
      BossRuntimeVariantProfile profile)
  {
    var validator = CreateTargetObservationValidator(gameData, profile);
    var managerId = user.SelectedClassicSoloRaidManagerId.GetValueOrDefault();
    if (managerId > 0)
    {
      Require(validator.Validate(managerId).IsTrustedTarget,
          "phase_d_boss_variant_selected_manager_mismatch");
    }
    else
    {
      var matches = gameData.SoloRaidManagerTable.Keys
          .Where(candidate => validator.Validate(candidate).IsTrustedTarget)
          .Take(2)
          .ToArray();
      Require(matches.Length == 1,
          "phase_d_boss_variant_manager_observation_not_unique");
      managerId = matches[0];
    }
    Require(gameData.SoloRaidManagerTable.TryGetValue(managerId, out var manager),
        "phase_d_staticdata_manager_missing");
    var presets = gameData.SoloRaidPresetTable.Values
        .Where(row => row.PresetGroupId == manager!.MonsterPreset &&
            (int)row.DifficultyType == 2 &&
            row.WaveOrder == profile.ChallengeSelector.WaveOrder)
        .Take(2)
        .ToArray();
    Require(presets.Length == 1, "phase_d_staticdata_challenge_preset_invalid");
    Require(gameData.WaveIntercept001Table.TryGetValue(presets[0].Wave, out var wave),
        "phase_d_staticdata_challenge_wave_missing");
    var spawned = (wave!.WaveData ?? [])
        .SelectMany(row => row.WaveMonsterList ?? [])
        .Select(row => row.WaveMonsterId)
        .ToHashSet();
    var targets = (wave.TargetList ?? []).Where(spawned.Contains).Distinct().Take(2).ToArray();
    Require(targets.Length == profile.ChallengeSelector.TargetCardinality,
        "phase_d_staticdata_target_monster_invalid");
    return targets[0];
  }

  private static ClassicSoloRaidTargetObservationValidator CreateTargetObservationValidator(
      GameData gameData,
      BossRuntimeVariantProfile profile)
  {
    var observation = profile.SelectedManagerObservation;
    return new ClassicSoloRaidTargetObservationValidator(
        new GameDataClassicSoloRaidObservationData(gameData),
        new ClassicSoloRaidTargetObservationContract(
            observation.ContractId,
            observation.CanonicalizationCode,
            observation.SourceObservationSha256,
            observation.RoleLineCounts is { Length: 6 }
                ? observation.RoleLineCounts
                : [3, 13, 13, 96, 12, 12],
            observation.CanonicalLineCount,
            observation.CanonicalByteLength,
            observation.TrustedSha256));
  }

  private static byte[] GetDecodedArchive(GameData gameData)
  {
    var field = typeof(GameData).GetField("ZipStream", BindingFlags.Instance | BindingFlags.NonPublic);
    var stream = field?.GetValue(gameData) as MemoryStream;
    Require(stream is not null, "phase_d_staticdata_binding_unavailable");
    return stream!.ToArray();
  }

  private static T[] DeserializeEntry<T>(byte[] archive, string entryName)
      where T : class
  {
    var bytes = ReadZipEntry(archive, entryName);
    try
    {
      return MemoryPackSerializer.Deserialize<T[]>(bytes) ??
          throw new InvalidOperationException("phase_d_staticdata_table_invalid");
    }
    finally
    {
      CryptographicOperations.ZeroMemory(bytes);
    }
  }

  private static string WeaknessCodeForElement(
      int elementId,
      IReadOnlyDictionary<int, ElementRecord> elementById)
  {
    Require(elementById.TryGetValue(elementId, out var element),
        "phase_d_staticdata_element_chain_invalid");
    Require(elementById.TryGetValue(element!.WeakElementId, out var weak),
        "phase_d_staticdata_element_chain_invalid");
    return CodeForAttackType(weak!.Element);
  }

  private static void ValidateElementTableIndex(IReadOnlyList<ElementRecord> elements)
  {
    var supported = new[]
    {
      AttackType.Fire,
      AttackType.Water,
      AttackType.Wind,
      AttackType.Electronic,
      AttackType.Iron
    };
    Require(elements.Count == supported.Length &&
            elements.Select(row => row.Id).Distinct().Count() == elements.Count &&
            elements.Select(row => row.Element).Distinct().Count() == elements.Count,
        "phase_d_staticdata_element_index_invalid");
    var byId = elements.ToDictionary(row => row.Id);
    foreach (var elementType in supported)
    {
      var matches = elements.Where(row => row.Element == elementType).Take(2).ToArray();
      Require(matches.Length == 1 &&
              byId.TryGetValue(matches[0].WeakElementId, out var weakness) &&
              BossElementTypeForWeakness(weakness!.Element) == elementType,
          "phase_d_staticdata_element_index_invalid");
    }
  }

  private static int CountModifiedMonsterRecords(
      IReadOnlyList<MonsterRecord> monsters,
      IReadOnlyDictionary<long, string> sourceFingerprints,
      long targetMonsterId)
  {
    Require(monsters.Count == sourceFingerprints.Count,
        "phase_d_staticdata_target_monster_reference_not_isolated");
    var modifiedCount = 0;
    foreach (var monster in monsters)
    {
      Require(sourceFingerprints.TryGetValue(monster.Id, out var sourceFingerprint),
          "phase_d_staticdata_target_monster_reference_not_isolated");
      if (!string.Equals(sourceFingerprint, FingerprintRecord(monster), StringComparison.Ordinal))
      {
        Require(monster.Id == targetMonsterId,
            "phase_d_staticdata_target_monster_reference_not_isolated");
        modifiedCount++;
      }
    }
    return modifiedCount;
  }

  private static FunctionRecord[] ResolveTargetShieldFunctions(
      MonsterRecord targetMonster,
      IReadOnlyList<MonsterPartsRecord> parts,
      IReadOnlyList<StateEffectRecord> stateEffects,
      IReadOnlyList<FunctionRecord> functions)
  {
    var stateEffectById = stateEffects.ToDictionary(row => row.Id);
    var functionById = functions.ToDictionary(row => row.Id);
    var passiveIds = parts.Where(row => row.MonsterModelId == targetMonster.MonsterModelId)
        .Select(row => row.PassiveSkillId)
        .Append(targetMonster.PassiveSkillId)
        .Where(id => id != 0)
        .Distinct()
        .ToArray();
    Require(passiveIds.All(stateEffectById.ContainsKey),
        "phase_d_staticdata_target_shield_reference_invalid");
    var roots = (targetMonster.SkillData ?? [])
        .SelectMany(row => (row.UseFunctionIdSkill ?? [])
            .Concat(row.HurtFunctionIdSkill ?? []))
        .Concat(passiveIds.SelectMany(id => StateEffectFunctionIds(stateEffectById[id])))
        .Where(id => id != 0)
        .Distinct()
        .ToArray();
    var pending = new Queue<int>(roots);
    var visited = new HashSet<int>();
    var selected = new List<FunctionRecord>();
    while (pending.TryDequeue(out var id))
    {
      if (!visited.Add(id)) continue;
      Require(functionById.TryGetValue(id, out var row),
          "phase_d_staticdata_target_shield_reference_invalid");
      selected.Add(row!);
      foreach (var connected in row!.ConnectedFunction ?? [])
      {
        if (connected != 0) pending.Enqueue(connected);
      }
    }
    return selected.Where(row => (int)row.FunctionType == 110)
        .OrderBy(row => row.Id)
        .ToArray();
  }

  private static IEnumerable<int> StateEffectFunctionIds(StateEffectRecord row) =>
      (row.UseFunctionIdList ?? [])
          .Concat(row.HurtFunctionIdList ?? [])
          .Concat((row.Functions ?? []).Select(value => value.Function));

  private static void ValidateShieldContract(
      BossRuntimeVariantProfile profile,
      IReadOnlyList<FunctionRecord> shieldFunctions)
  {
    if (profile.ElementShield.ModeCode == "none")
    {
      Require(shieldFunctions.Count == 0,
          "phase_d_boss_variant_element_shield_contract_mismatch");
      return;
    }
    var fxPrefabSetSha256 = HashStrings(shieldFunctions
        .Where(HasFxBinding)
        .Select(ShieldFxPrefabSetSha256)
        .Distinct(StringComparer.Ordinal)
        .Order(StringComparer.Ordinal));
    Require(profile.ElementShield.FunctionTypeCode == "immune_other_element" &&
            profile.ElementShield.FunctionRecordCount == shieldFunctions.Count &&
            HashRecordSet(shieldFunctions.Cast<object>()) ==
                profile.ElementShield.FunctionSetSha256 &&
            fxPrefabSetSha256 == profile.ElementShield.SourceFxPrefabSetSha256 &&
            profile.ElementShield.FxVariantRequired &&
            profile.ElementShield.FxVariantStatusCode == "resolved",
        "phase_d_boss_variant_element_shield_contract_mismatch");
  }

  private static bool HasFxBinding(FunctionRecord row) =>
      new[]
      {
        row.FxPrefab01, row.FxPrefab02, row.FxPrefab03, row.FxPrefabFull,
        row.FxPrefab01Arena, row.FxPrefab02Arena, row.FxPrefab03Arena
      }.Any(value => !string.IsNullOrWhiteSpace(value));

  private static string ShieldFxPrefabSetSha256(FunctionRecord row)
  {
    var canonical = string.Join("\n", new[]
    {
      row.FxPrefab01 ?? "", row.FxPrefab02 ?? "", row.FxPrefab03 ?? "",
      row.FxPrefabFull ?? "", row.FxPrefab01Arena ?? "",
      row.FxPrefab02Arena ?? "", row.FxPrefab03Arena ?? ""
    });
    return HashBytes(Encoding.UTF8.GetBytes(canonical));
  }

  private static bool SameFxPrefabSet(FunctionRecord left, FunctionRecord right) =>
      left.FxPrefab01 == right.FxPrefab01 &&
      left.FxPrefab02 == right.FxPrefab02 &&
      left.FxPrefab03 == right.FxPrefab03 &&
      left.FxPrefabFull == right.FxPrefabFull &&
      left.FxPrefab01Arena == right.FxPrefab01Arena &&
      left.FxPrefab02Arena == right.FxPrefab02Arena &&
      left.FxPrefab03Arena == right.FxPrefab03Arena;

  private static ShieldFxPrefabs ReadFxPrefabs(FunctionRecord source) => new(
      source.FxPrefab01,
      source.FxPrefab02,
      source.FxPrefab03,
      source.FxPrefabFull,
      source.FxPrefab01Arena,
      source.FxPrefab02Arena,
      source.FxPrefab03Arena);

  private static void CopyFxPrefabs(ShieldFxPrefabs source, FunctionRecord target)
  {
    target.FxPrefab01 = source.FxPrefab01;
    target.FxPrefab02 = source.FxPrefab02;
    target.FxPrefab03 = source.FxPrefab03;
    target.FxPrefabFull = source.FxPrefabFull;
    target.FxPrefab01Arena = source.FxPrefab01Arena;
    target.FxPrefab02Arena = source.FxPrefab02Arena;
    target.FxPrefab03Arena = source.FxPrefab03Arena;
  }

  private static int CountModifiedFunctionRecords(
      IReadOnlyList<FunctionRecord> functions,
      IReadOnlyDictionary<int, string> sourceFingerprints,
      IReadOnlySet<int> allowedIds)
  {
    Require(functions.Count == sourceFingerprints.Count,
        "phase_d_staticdata_target_function_reference_not_isolated");
    var modifiedCount = 0;
    foreach (var function in functions)
    {
      Require(sourceFingerprints.TryGetValue(function.Id, out var sourceFingerprint),
          "phase_d_staticdata_target_function_reference_not_isolated");
      if (sourceFingerprint != FingerprintRecord(function))
      {
        Require(allowedIds.Contains(function.Id),
            "phase_d_staticdata_target_function_reference_not_isolated");
        modifiedCount++;
      }
    }
    return modifiedCount;
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

  private static string FingerprintRecord<T>(T record)
  {
    var bytes = MemoryPackSerializer.Serialize(record);
    try
    {
      return HashBytes(bytes);
    }
    finally
    {
      CryptographicOperations.ZeroMemory(bytes);
    }
  }

  private static byte[] BuildUnsignedVariantPack(
      string sourcePackPath,
      byte[] modifiedDecodedArchive,
      StaticData staticData)
  {
    var outerArchive = DecryptOuterPack(File.ReadAllBytes(sourcePackPath), staticData);
    byte[] signature;
    try
    {
      signature = ReadZipEntry(outerArchive, "sign");
    }
    finally
    {
      CryptographicOperations.ZeroMemory(outerArchive);
    }

    var shared = GetPresharedValue();
    var salt1Key = Rfc2898DeriveBytes.Pbkdf2(
        shared, staticData.GetSalt1Bytes(), 10_000, HashAlgorithmName.SHA256, 32);
    byte[] encryptedData;
    try
    {
      using var input = new MemoryStream(modifiedDecodedArchive, writable: false);
      using var output = new MemoryStream();
      GameData.DoTransformation(salt1Key[..16], salt1Key[16..32], input, output);
      encryptedData = output.ToArray();
    }
    finally
    {
      CryptographicOperations.ZeroMemory(salt1Key);
      CryptographicOperations.ZeroMemory(shared);
    }

    byte[] rebuiltOuter;
    try
    {
      rebuiltOuter = CreateZip(new Dictionary<string, byte[]>(StringComparer.Ordinal)
      {
        ["sign"] = signature,
        ["data"] = encryptedData
      });
    }
    finally
    {
      CryptographicOperations.ZeroMemory(signature);
      CryptographicOperations.ZeroMemory(encryptedData);
    }

    try
    {
      return EncryptOuterPack(rebuiltOuter, staticData);
    }
    finally
    {
      CryptographicOperations.ZeroMemory(rebuiltOuter);
    }
  }

  private static void VerifyVariantPack(
      string variantPackPath,
      long targetMonsterId,
      string expectedWeaknessCode,
      AttackType expectedBossElement,
      int expectedBossElementId,
      string expectedElementTableSha256,
      string expectedMonsterTableSha256,
      string expectedFunctionTableSha256,
      string expectedQuickTimeEventTableSha256,
      QuickTimeEventRecord[] sourceQuickTimeEventRows,
      int expectedModifiedQuickTimeEventCount,
      BossRuntimeVariantProfile profile,
      BossRuntimeVariantShieldFxVariant? expectedShieldFxVariant,
      IReadOnlyDictionary<int, string> expectedShieldFxSetByFunctionId,
      StaticData staticData)
  {
    var outer = DecryptOuterPack(File.ReadAllBytes(variantPackPath), staticData);
    byte[] encryptedData;
    try
    {
      encryptedData = ReadZipEntry(outer, "data");
    }
    finally
    {
      CryptographicOperations.ZeroMemory(outer);
    }

    var shared = GetPresharedValue();
    var key = Rfc2898DeriveBytes.Pbkdf2(
        shared, staticData.GetSalt1Bytes(), 10_000, HashAlgorithmName.SHA256, 32);
    byte[] decoded;
    try
    {
      using var input = new MemoryStream(encryptedData, writable: false);
      using var output = new MemoryStream();
      GameData.DoTransformation(key[..16], key[16..32], input, output);
      decoded = output.ToArray();
    }
    finally
    {
      CryptographicOperations.ZeroMemory(shared);
      CryptographicOperations.ZeroMemory(key);
      CryptographicOperations.ZeroMemory(encryptedData);
    }

    try
    {
      Require(HashZipEntry(decoded, "ElementTable.mpk") == expectedElementTableSha256 &&
              HashZipEntry(decoded, "MonsterTable.mpk") == expectedMonsterTableSha256 &&
              HashZipEntry(decoded, "FunctionTable.mpk") == expectedFunctionTableSha256 &&
              HashZipEntry(decoded, "QuickTimeEventTable.mpk") == expectedQuickTimeEventTableSha256,
          "phase_d_staticdata_variant_table_boundary_invalid");
      BossQuickTimeEventVariant.VerifyBoundary(sourceQuickTimeEventRows,
          DeserializeEntry<QuickTimeEventRecord>(decoded, "QuickTimeEventTable.mpk"),
          targetMonsterId, expectedBossElementId, expectedModifiedQuickTimeEventCount);
      var elements = DeserializeEntry<ElementRecord>(decoded, "ElementTable.mpk");
      var monsters = DeserializeEntry<MonsterRecord>(decoded, "MonsterTable.mpk");
      var functions = DeserializeEntry<FunctionRecord>(decoded, "FunctionTable.mpk");
      ValidateElementTableIndex(elements);
      Require(monsters.Select(row => row.Id).Distinct().Count() == monsters.Length,
          "phase_d_staticdata_monster_index_invalid");
      var elementById = elements.ToDictionary(row => row.Id);
      var monster = monsters.SingleOrDefault(row => row.Id == targetMonsterId);
      Require(monster is not null &&
              monster.ElementId is [_] &&
              monster.ElementId[0] == expectedBossElementId,
          "phase_d_staticdata_variant_roundtrip_invalid");
      var observedWeakness = monster!.ElementId
          .Select(elementId => WeaknessCodeForElement(elementId, elementById))
          .Distinct(StringComparer.Ordinal)
          .ToArray();
      var observedBossElements = monster.ElementId
          .Select(elementId => elementById.TryGetValue(elementId, out var element)
              ? element.Element
              : AttackType.None)
          .Distinct()
          .ToArray();
      Require(observedWeakness.Length == 1 && observedWeakness[0] == expectedWeaknessCode &&
              observedBossElements.Length == 1 && observedBossElements[0] == expectedBossElement,
          "phase_d_staticdata_variant_roundtrip_invalid");
      var observedShieldFunctions = functions
          .Where(row => expectedShieldFxSetByFunctionId.ContainsKey(row.Id))
          .ToArray();
      Require(observedShieldFunctions.Length == expectedShieldFxSetByFunctionId.Count,
          "phase_d_staticdata_variant_roundtrip_invalid");
      if (profile.ElementShield.ModeCode == "dynamic_affinity_linked")
      {
        Require(expectedShieldFxVariant is not null &&
                observedShieldFunctions.Count(HasFxBinding) > 0 &&
                observedShieldFunctions.Where(HasFxBinding).All(row =>
                    ShieldFxPrefabSetSha256(row) ==
                        expectedShieldFxSetByFunctionId[row.Id]),
            "phase_d_staticdata_variant_shield_roundtrip_invalid");
      }
    }
    finally
    {
      CryptographicOperations.ZeroMemory(decoded);
    }
  }

  private static byte[] DecryptOuterPack(byte[] encrypted, StaticData staticData)
  {
    var shared = GetPresharedValue();
    var key = Rfc2898DeriveBytes.Pbkdf2(
        shared, staticData.GetSalt2Bytes(), 10_000, HashAlgorithmName.SHA256, 32);
    try
    {
      using var aes = Aes.Create();
      aes.KeySize = 128;
      aes.BlockSize = 128;
      aes.Mode = CipherMode.CBC;
      aes.Padding = PaddingMode.PKCS7;
      aes.Key = key[..16];
      aes.IV = key[16..32];
      using var input = new MemoryStream(encrypted, writable: false);
      using var crypto = new CryptoStream(input, aes.CreateDecryptor(), CryptoStreamMode.Read);
      using var output = new MemoryStream();
      crypto.CopyTo(output);
      return output.ToArray();
    }
    finally
    {
      CryptographicOperations.ZeroMemory(key);
      CryptographicOperations.ZeroMemory(shared);
      CryptographicOperations.ZeroMemory(encrypted);
    }
  }

  private static byte[] EncryptOuterPack(byte[] plain, StaticData staticData)
  {
    var shared = GetPresharedValue();
    var key = Rfc2898DeriveBytes.Pbkdf2(
        shared, staticData.GetSalt2Bytes(), 10_000, HashAlgorithmName.SHA256, 32);
    try
    {
      using var aes = Aes.Create();
      aes.KeySize = 128;
      aes.BlockSize = 128;
      aes.Mode = CipherMode.CBC;
      aes.Padding = PaddingMode.PKCS7;
      aes.Key = key[..16];
      aes.IV = key[16..32];
      using var output = new MemoryStream();
      using (var crypto = new CryptoStream(output, aes.CreateEncryptor(), CryptoStreamMode.Write, true))
      {
        crypto.Write(plain);
        crypto.FlushFinalBlock();
      }
      return output.ToArray();
    }
    finally
    {
      CryptographicOperations.ZeroMemory(key);
      CryptographicOperations.ZeroMemory(shared);
    }
  }

  private static byte[] GetPresharedValue()
  {
    var field = typeof(GameData).GetField("PresharedValue", BindingFlags.Static | BindingFlags.NonPublic);
    var value = field?.GetValue(null) as byte[];
    Require(value is { Length: 64 }, "phase_d_staticdata_crypto_binding_unavailable");
    return value!.ToArray();
  }

  private static byte[] ReadZipEntry(byte[] archive, string entryName)
  {
    using var input = new MemoryStream(archive, writable: false);
    using var zip = new ZipArchive(input, ZipArchiveMode.Read, leaveOpen: false);
    var entry = zip.GetEntry(entryName);
    Require(entry is not null, "phase_d_staticdata_archive_entry_missing");
    using var stream = entry!.Open();
    using var output = new MemoryStream();
    stream.CopyTo(output);
    return output.ToArray();
  }

  private static byte[] ReplaceZipEntries(
      byte[] archive,
      IReadOnlyDictionary<string, byte[]> replacements)
  {
    using var input = new MemoryStream(archive, writable: false);
    using var source = new ZipArchive(input, ZipArchiveMode.Read, leaveOpen: false);
    using var output = new MemoryStream();
    using (var target = new ZipArchive(output, ZipArchiveMode.Create, leaveOpen: true))
    {
      var replaced = new HashSet<string>(StringComparer.Ordinal);
      foreach (var entry in source.Entries)
      {
        var created = target.CreateEntry(entry.FullName, CompressionLevel.Optimal);
        created.LastWriteTime = new DateTimeOffset(2000, 1, 1, 0, 0, 0, TimeSpan.Zero);
        using var destination = created.Open();
        if (replacements.TryGetValue(entry.FullName, out var replacement))
        {
          destination.Write(replacement);
          replaced.Add(entry.FullName);
        }
        else
        {
          using var original = entry.Open();
          original.CopyTo(destination);
        }
      }
      Require(replaced.SetEquals(replacements.Keys),
          "phase_d_staticdata_archive_entry_missing");
    }
    return output.ToArray();
  }

  private static byte[] CreateZip(IReadOnlyDictionary<string, byte[]> entries)
  {
    using var output = new MemoryStream();
    using (var zip = new ZipArchive(output, ZipArchiveMode.Create, leaveOpen: true))
    {
      foreach (var pair in entries)
      {
        var entry = zip.CreateEntry(pair.Key, CompressionLevel.NoCompression);
        entry.LastWriteTime = new DateTimeOffset(2000, 1, 1, 0, 0, 0, TimeSpan.Zero);
        using var stream = entry.Open();
        stream.Write(pair.Value);
      }
    }
    return output.ToArray();
  }

  private static string? NormalizeCode(string value) => value.Trim().ToLowerInvariant() switch
  {
    "fire" => "fire",
    "water" => "water",
    "wind" => "wind",
    "electric" => "electric",
    "iron" => "iron",
    _ => null
  };

  private static AttackType AttackTypeForCode(string code) => code switch
  {
    "fire" => AttackType.Fire,
    "water" => AttackType.Water,
    "wind" => AttackType.Wind,
    "electric" => AttackType.Electronic,
    "iron" => AttackType.Iron,
    _ => throw new InvalidOperationException("phase_d_weakness_code_invalid")
  };

  private static AttackType BossElementTypeForWeakness(AttackType weakness) => weakness switch
  {
    AttackType.Fire => AttackType.Wind,
    AttackType.Water => AttackType.Fire,
    AttackType.Wind => AttackType.Iron,
    AttackType.Electronic => AttackType.Water,
    AttackType.Iron => AttackType.Electronic,
    _ => throw new InvalidOperationException("phase_d_staticdata_element_chain_invalid")
  };

  private static string CodeForAttackType(AttackType value) => value switch
  {
    AttackType.Fire => "fire",
    AttackType.Water => "water",
    AttackType.Wind => "wind",
    AttackType.Electronic => "electric",
    AttackType.Iron => "iron",
    _ => throw new InvalidOperationException("phase_d_staticdata_element_chain_invalid")
  };

  private static async Task WriteAtomicBytesAsync(string path, byte[] bytes)
  {
    var temporary = path + ".partial-" + Guid.NewGuid().ToString("N");
    await File.WriteAllBytesAsync(temporary, bytes);
    File.Move(temporary, path);
  }

  private static async Task WriteAtomicTextAsync(string path, string text)
  {
    Directory.CreateDirectory(Path.GetDirectoryName(path)!);
    var temporary = path + ".partial-" + Guid.NewGuid().ToString("N");
    await File.WriteAllTextAsync(temporary, text, new System.Text.UTF8Encoding(false));
    File.Move(temporary, path);
  }

  private static string HashFile(string path)
  {
    using var stream = File.OpenRead(path);
    return Convert.ToHexStringLower(SHA256.HashData(stream));
  }

  private static string HashZipEntry(byte[] archive, string entryName)
  {
    var bytes = ReadZipEntry(archive, entryName);
    try
    {
      return HashBytes(bytes);
    }
    finally
    {
      CryptographicOperations.ZeroMemory(bytes);
    }
  }

  private static string HashBytes(byte[] bytes) =>
      Convert.ToHexStringLower(SHA256.HashData(bytes));

  private static void Require(bool condition, string code)
  {
    if (!condition) throw new InvalidOperationException(code);
  }

  private sealed record ShieldFxPrefabs(
      string? FxPrefab01,
      string? FxPrefab02,
      string? FxPrefab03,
      string? FxPrefabFull,
      string? FxPrefab01Arena,
      string? FxPrefab02Arena,
      string? FxPrefab03Arena);
}
