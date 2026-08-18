using System.Globalization;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using NikkeLocalLab.Domain.Raid;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Import.RaidCatalog;

public sealed class StaticDataChallengeRaidCatalogReader
{
  private const int ChallengeDifficultyType = 2;
  private const int ChallengeWaveOrder = 8;

  private static readonly ZipArchiveLimits ArchiveLimits = new(
      MaximumEntryCount: 20_000,
      MaximumEntryBytes: 256L * 1024 * 1024,
      MaximumTotalBytes: 2L * 1024 * 1024 * 1024,
      MaximumCompressionRatio: 1_000m);

  private static readonly string[] RequiredEntries =
  [
    "ElementTable.mpk",
    "MonsterPartsTable.mpk",
    "MonsterTable.mpk",
    "SoloRaidManagerTable.mpk",
    "SoloRaidPresetTable.mpk",
    "WaveData.GroupDict.csv"
  ];

  public ChallengeRaidCatalogExtraction Read(Stream staticDataArchive) =>
      Read(staticDataArchive, ChallengeEvidencePackage.Empty);

  public ChallengeRaidCatalogExtraction Read(
      Stream staticDataArchive,
      Stream compatibilityArchive)
  {
    ArgumentNullException.ThrowIfNull(compatibilityArchive);
    return Read(
        staticDataArchive,
        ChallengeBehaviorEvidenceArchiveReader.Read(compatibilityArchive));
  }

  private static ChallengeRaidCatalogExtraction Read(
      Stream staticDataArchive,
      ChallengeEvidencePackage compatibility)
  {
    ArgumentNullException.ThrowIfNull(staticDataArchive);
    ArgumentNullException.ThrowIfNull(compatibility);
    ValidateArchiveStream(staticDataArchive, "static_archive_invalid");

    var staticOriginalPosition = staticDataArchive.Position;
    try
    {
      var staticArchiveSha256 = ComputeArchiveHash(staticDataArchive);
      staticDataArchive.Position = 0;
      using var archive = new ZipArchive(staticDataArchive, ZipArchiveMode.Read, leaveOpen: true);
      var archiveEntries = ZipArchiveGuard.Validate(archive, ArchiveLimits);
      var fixedEntries = RequiredEntries.ToDictionary(
          static name => name,
          name => ReadSingleEntry(archiveEntries, name),
          StringComparer.Ordinal);

      var managers = ReadAndClear(fixedEntries["SoloRaidManagerTable.mpk"], ReadManagers);
      var presets = ReadAndClear(fixedEntries["SoloRaidPresetTable.mpk"], ReadPresets);
      var monsters = ReadAndClear(fixedEntries["MonsterTable.mpk"], ReadMonsters);
      var elements = ReadAndClear(fixedEntries["ElementTable.mpk"], ReadElements);
      var parts = ReadAndClear(fixedEntries["MonsterPartsTable.mpk"], ReadParts);
      var waveGroups = ReadAndClear(fixedEntries["WaveData.GroupDict.csv"], ReadWaveGroups);

      var candidates = new List<NormalizedChallengeRaidCandidate>();
      var diagnostics = new Dictionary<(string Code, int? Season), int>();
      var usedEvidenceSeasons = new HashSet<int>();
      var waveTables = new Dictionary<string, IReadOnlyDictionary<int, WaveRow>>(StringComparer.Ordinal);
      var managerRelations = ResolveManagerRelations(managers);
      var challengePresets = ResolveChallengePresets(presets, managerRelations);

      foreach (var relation in challengePresets.OrderBy(static pair => pair.SeasonNumber))
      {
        var season = relation.SeasonNumber;
        if (season is 14 or 39)
        {
          Increment(diagnostics, "excluded_by_policy", season);
          continue;
        }

        if (!TryResolveBoss(
                relation,
                waveGroups,
                archiveEntries,
                waveTables,
                monsters,
                out var monster))
        {
          Increment(diagnostics, "authoritative_challenge_chain_unresolved", season);
          continue;
        }

        var normalizedParts = NormalizeParts(parts.Where(row => row.MonsterModelId == monster.MonsterModelId));
        var spotBehaviorVariantCount = CountSpotBehaviorVariants(monster);
        if (!TryResolveAffinity(monster, elements, out var affinity, out var bossElement, out var weakness))
        {
          candidates.Add(new NormalizedChallengeRaidCandidate(
              season,
              "unresolved",
              null,
              normalizedParts.Parts,
              normalizedParts.HasClosedTopology,
              spotBehaviorVariantCount,
              monster.SkillRelationCount,
              ChallengeCompatibilityEvidence.StaticExact(staticArchiveSha256)));
          Increment(diagnostics, "affinity_unresolved", season);
          continue;
        }

        var admission = ChallengeBossSupportPolicy.Evaluate(
            season,
            bossElement,
            weakness,
            authoritativeChallengeChainResolved: true);
        if (!admission.IsSupported)
        {
          Increment(
              diagnostics,
              admission.Outcome == ChallengeAdmissionOutcome.ExcludedByPolicy
                  ? "excluded_by_policy"
                  : "unsupported_by_policy",
              season);
          continue;
        }

        var evidence = ResolveEvidence(
            season,
            staticArchiveSha256,
            compatibility,
            usedEvidenceSeasons,
            diagnostics);

        var admissionCode = admission.Rule switch
        {
          ChallengeAdmissionRule.ElectricWeakToIron => "electric_weak_to_iron",
          ChallengeAdmissionRule.Season40Explicit => "season_40_explicit",
          _ => throw new ChallengeRaidCatalogSourceException("admission_rule_invalid")
        };

        if (!normalizedParts.HasClosedTopology)
        {
          Increment(diagnostics, "part_topology_unresolved", season);
        }

        if (!normalizedParts.HasResolvedTypes)
        {
          Increment(diagnostics, "part_type_unresolved", season);
        }

        if (spotBehaviorVariantCount != 1)
        {
          Increment(diagnostics, "spot_behavior_unresolved", season);
        }

        if (!monster.SkillRelationCount.HasValue)
        {
          Increment(diagnostics, "monster_skill_relations_unresolved", season);
        }

        candidates.Add(new NormalizedChallengeRaidCandidate(
            season,
            admissionCode,
            affinity,
            normalizedParts.Parts,
            normalizedParts.HasClosedTopology,
            spotBehaviorVariantCount,
            monster.SkillRelationCount,
            evidence));
      }

      if (!usedEvidenceSeasons.SetEquals(compatibility.BySeasonNumber.Keys))
      {
        throw new ChallengeRaidCatalogSourceException("compatibility_evidence_unmatched");
      }

      var orderedCandidates = candidates.OrderBy(static candidate => candidate.SeasonNumber).ToArray();
      return new ChallengeRaidCatalogExtraction(
          Array.AsReadOnly(orderedCandidates),
          diagnostics
              .OrderBy(static pair => pair.Key.Code, StringComparer.Ordinal)
              .ThenBy(static pair => pair.Key.Season)
              .Select(static pair => new ChallengeRaidImportDiagnostic(
                  pair.Key.Code,
                  pair.Key.Season,
                  pair.Value))
              .ToArray(),
          staticArchiveSha256,
          compatibility.ArchiveSha256,
          ChallengeRaidCandidateCanonicalizer.ComputeHash(orderedCandidates));
    }
    catch (ChallengeRaidCatalogSourceException)
    {
      throw;
    }
    catch (Exception exception) when (exception is InvalidDataException or IOException or OverflowException)
    {
      throw new ChallengeRaidCatalogSourceException("static_archive_invalid");
    }
    finally
    {
      staticDataArchive.Position = staticOriginalPosition;
    }
  }

  private static ChallengeCompatibilityEvidence ResolveEvidence(
      int season,
      Sha256Digest staticArchiveSha256,
      ChallengeEvidencePackage package,
      ISet<int> usedEvidenceSeasons,
      IDictionary<(string Code, int? Season), int> diagnostics)
  {
    if (!package.BySeasonNumber.TryGetValue(season, out var evidence))
    {
      Increment(diagnostics, "behavior_evidence_unresolved", season);
      return ChallengeCompatibilityEvidence.StaticExact(staticArchiveSha256);
    }

    usedEvidenceSeasons.Add(season);
    if (evidence.StaticDataArchiveSha256 != staticArchiveSha256)
    {
      Increment(diagnostics, "compatibility_static_binding_mismatch", season);
      Increment(diagnostics, "compatibility_evidence_unmatched", season);
      Increment(diagnostics, "behavior_evidence_unresolved", season);
      return ChallengeCompatibilityEvidence.StaticExact(staticArchiveSha256);
    }

    return evidence;
  }

  private static IReadOnlyDictionary<int, int> ResolveManagerRelations(
      IReadOnlyList<ManagerRow> managers)
  {
    var result = new Dictionary<int, int>();
    foreach (var manager in managers)
    {
      if (result.TryGetValue(manager.PresetGroupId, out var existingSeason) &&
          existingSeason != manager.SeasonNumber)
      {
        throw new ChallengeRaidCatalogSourceException("manager_relation_ambiguous");
      }

      result[manager.PresetGroupId] = manager.SeasonNumber;
    }

    return result;
  }

  private static IReadOnlyList<ChallengePresetRelation> ResolveChallengePresets(
      IReadOnlyList<PresetRow> presets,
      IReadOnlyDictionary<int, int> managerRelations)
  {
    var byGroup = presets
        .Where(static row => row.DifficultyType == ChallengeDifficultyType)
        .GroupBy(static row => row.PresetGroupId)
        .ToDictionary(static group => group.Key, static group => group.ToArray());
    if (!managerRelations.Keys.ToHashSet().SetEquals(byGroup.Keys) ||
        byGroup.Values.Any(static rows => rows.Length != 1))
    {
      throw new ChallengeRaidCatalogSourceException("challenge_preset_relation_invalid");
    }

    var seasons = new HashSet<int>();
    var result = new List<ChallengePresetRelation>();
    foreach (var pair in byGroup)
    {
      var preset = pair.Value[0];
      var season = managerRelations[pair.Key];
      if (preset.WaveOrder != ChallengeWaveOrder || !seasons.Add(season))
      {
        throw new ChallengeRaidCatalogSourceException("challenge_selector_invalid");
      }

      result.Add(new ChallengePresetRelation(season, preset.WaveStageId));
    }

    return result;
  }

  private static bool TryResolveBoss(
      ChallengePresetRelation relation,
      WaveGroupIndex waveGroups,
      IReadOnlyList<ZipArchiveEntry> archiveEntries,
      IDictionary<string, IReadOnlyDictionary<int, WaveRow>> waveTables,
      IReadOnlyDictionary<long, MonsterRow> monsters,
      out MonsterRow monster)
  {
    monster = null!;
    if (!waveGroups.GroupsByStage.TryGetValue(relation.WaveStageId, out var groups) || groups.Count != 1)
    {
      return false;
    }

    var group = groups.Single();
    if (!waveTables.TryGetValue(group, out var table))
    {
      var entry = ReadSingleEntry(archiveEntries, $"WaveDataTable.{group}.mpk");
      var rows = ReadAndClear(entry, ReadWaves);
      if (waveGroups.RowCountByGroup.GetValueOrDefault(group) != rows.Count ||
          rows.Any(row => !string.Equals(row.Group, group, StringComparison.Ordinal)))
      {
        throw new ChallengeRaidCatalogSourceException("wave_group_integrity_invalid");
      }

      table = rows.ToDictionary(static row => row.StageId);
      waveTables.Add(group, table);
    }

    if (!table.TryGetValue(relation.WaveStageId, out var wave))
    {
      return false;
    }

    var targets = wave.TargetMonsterIds.Where(static value => value > 0).ToHashSet();
    var spawned = wave.SpawnedMonsterIds.Where(static value => value > 0).ToHashSet();
    targets.IntersectWith(spawned);
    if (targets.Count != 1 || !monsters.TryGetValue(targets.Single(), out monster!))
    {
      return false;
    }

    return true;
  }

  private static bool TryResolveAffinity(
      MonsterRow monster,
      IReadOnlyDictionary<int, ElementRow> elements,
      out NormalizedRaidAffinity affinity,
      out RaidElement bossElement,
      out RaidElement weakness)
  {
    affinity = null!;
    bossElement = default;
    weakness = default;
    if (monster.ElementIds.Length != 1 ||
        !elements.TryGetValue(monster.ElementIds[0], out var element) ||
        !elements.TryGetValue(element.WeakElementId, out var weakElement) ||
        !TryNormalizeElement(element.AttackType, out bossElement) ||
        !TryNormalizeElement(weakElement.AttackType, out weakness))
    {
      return false;
    }

    affinity = new NormalizedRaidAffinity(ElementCode(bossElement), ElementCode(weakness));
    return true;
  }

  private static int CountSpotBehaviorVariants(MonsterRow monster)
  {
    var values = new[]
    {
      monster.SpotBehavior,
      monster.DefenseSpotBehavior,
      monster.BaseDefenseSpotBehavior
    };
    return values.All(IsBehaviorKeyValid)
        ? values.Distinct(StringComparer.Ordinal).Count()
        : 0;
  }

  private static NormalizedPartSet NormalizeParts(IEnumerable<PartRow> source)
  {
    var ordered = source
        .OrderBy(static row => row.PartType)
        .ThenBy(static row => row.DamageHpRatio)
        .ThenBy(static row => row.HpRatio)
        .ThenBy(static row => row.DefenceRatio)
        .ThenBy(static row => row.EnergyResistRatio)
        .ThenBy(static row => row.MetalResistRatio)
        .ThenBy(static row => row.BioResistRatio)
        .ThenBy(static row => row.AttackRatio)
        .ThenBy(static row => row.IsMainPart)
        .ThenBy(static row => row.IsDamageable)
        .ThenBy(static row => row.IsHpVisible)
        .ThenBy(static row => row.LinkedPartId)
        .ThenBy(static row => row.Id)
        .ToArray();
    var ordinalBySourceId = ordered
        .Select(static (row, ordinal) => (row.Id, Ordinal: ordinal))
        .ToDictionary(static value => value.Id, static value => value.Ordinal);
    var rowBySourceId = ordered.ToDictionary(static row => row.Id);
    // The authoritative relation is a link-group root: the root points to itself and every
    // dependent points to that root. The public relation drops the root's source self-edge.
    var hasClosedTopology = ordered.All(row =>
        row.LinkedPartId == 0 ||
        (rowBySourceId.TryGetValue(row.LinkedPartId, out var root) &&
         root.LinkedPartId == root.Id));
    var hasResolvedTypes = ordered.All(static row => TryNormalizePartType(row.PartType, out _));
    var normalized = ordered.Select((row, ordinal) => new NormalizedRaidPart(
        ordinal,
        TryNormalizePartType(row.PartType, out var typeCode) ? typeCode : "unresolved",
        row.DamageHpRatio,
        row.HpRatio,
        row.DefenceRatio,
        row.EnergyResistRatio,
        row.MetalResistRatio,
        row.BioResistRatio,
        row.AttackRatio,
        row.IsMainPart,
        row.IsDamageable,
        row.IsHpVisible,
        row.LinkedPartId > 0 && row.LinkedPartId != row.Id &&
            ordinalBySourceId.TryGetValue(row.LinkedPartId, out var linkedOrdinal)
            ? linkedOrdinal
            : null)).ToArray();
    return new NormalizedPartSet(
        Array.AsReadOnly(normalized),
        hasClosedTopology,
        hasResolvedTypes);
  }

  private static IReadOnlyList<ManagerRow> ReadManagers(byte[] bytes)
  {
    var reader = new MemoryPackReader(bytes);
    var count = reader.ReadCollectionLength();
    var rows = new ManagerRow[count];
    var identifiers = new HashSet<int>();
    for (var index = 0; index < count; index++)
    {
      reader.RequireObject(3);
      var id = reader.ReadInt32();
      var preset = reader.ReadInt32();
      var season = reader.ReadInt32();
      if (id <= 0 || preset <= 0 || season <= 0 || !identifiers.Add(id))
      {
        throw new ChallengeRaidCatalogSourceException("manager_record_invalid");
      }

      rows[index] = new ManagerRow(preset, season);
    }

    reader.EnsureEnd();
    return Array.AsReadOnly(rows);
  }

  private static IReadOnlyList<PresetRow> ReadPresets(byte[] bytes)
  {
    var reader = new MemoryPackReader(bytes);
    var count = reader.ReadCollectionLength();
    var rows = new PresetRow[count];
    var identifiers = new HashSet<int>();
    for (var index = 0; index < count; index++)
    {
      reader.RequireObject(19);
      var id = reader.ReadInt32();
      var group = reader.ReadInt32();
      var difficulty = reader.ReadInt32();
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      var waveOrder = reader.ReadInt32();
      var wave = reader.ReadInt32();
      for (var field = 8; field < 12; field++)
      {
        _ = reader.ReadInt32();
      }

      _ = reader.ReadBoolean();
      for (var field = 13; field < 17; field++)
      {
        _ = reader.ReadString();
      }

      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      if (id <= 0 || group <= 0 || wave <= 0 || !identifiers.Add(id))
      {
        throw new ChallengeRaidCatalogSourceException("preset_record_invalid");
      }

      rows[index] = new PresetRow(group, difficulty, waveOrder, wave);
    }

    reader.EnsureEnd();
    return Array.AsReadOnly(rows);
  }

  private static IReadOnlyDictionary<long, MonsterRow> ReadMonsters(byte[] bytes)
  {
    var reader = new MemoryPackReader(bytes);
    var count = reader.ReadCollectionLength();
    var rows = new Dictionary<long, MonsterRow>();
    for (var index = 0; index < count; index++)
    {
      reader.RequireObject(33);
      var id = reader.ReadInt64();
      var elementIds = reader.ReadInt32Array() ?? [];
      var modelId = reader.ReadInt32();
      _ = reader.ReadInt32();
      _ = reader.ReadString();
      _ = reader.ReadString();
      _ = reader.ReadString();
      _ = reader.ReadBoolean();
      _ = reader.ReadInt32();
      for (var field = 9; field < 19; field++)
      {
        _ = reader.ReadInt32();
      }

      var spot = reader.ReadString();
      var defense = reader.ReadString();
      var baseDefense = reader.ReadString();
      for (var field = 21; field < 29; field++)
      {
        _ = reader.ReadInt32();
      }

      _ = reader.ReadInt32();
      var skillCount = reader.ReadCollectionLength(allowNull: true, maximumLength: 16_384);
      for (var skill = 0; skill < Math.Max(0, skillCount); skill++)
      {
        reader.RequireObject(3);
        _ = reader.ReadInt32();
        _ = reader.ReadInt32Array();
        _ = reader.ReadInt32Array();
      }

      _ = reader.ReadInt32();
      if (id <= 0 || modelId <= 0 || spot is null || defense is null || baseDefense is null ||
          !rows.TryAdd(id, new MonsterRow(
              id,
              elementIds,
              modelId,
              spot,
              defense,
              baseDefense,
              skillCount >= 0 ? skillCount : null)))
      {
        throw new ChallengeRaidCatalogSourceException("monster_record_invalid");
      }
    }

    reader.EnsureEnd();
    return rows;
  }

  private static IReadOnlyDictionary<int, ElementRow> ReadElements(byte[] bytes)
  {
    var reader = new MemoryPackReader(bytes);
    var count = reader.ReadCollectionLength(maximumLength: 4_096);
    var rows = new Dictionary<int, ElementRow>();
    for (var index = 0; index < count; index++)
    {
      reader.RequireObject(8);
      var id = reader.ReadInt32();
      var attackType = reader.ReadInt32();
      _ = reader.ReadInt32();
      var weakElementId = reader.ReadInt32();
      for (var field = 4; field < 8; field++)
      {
        _ = reader.ReadString();
      }

      if (id <= 0 || weakElementId <= 0 ||
          !rows.TryAdd(id, new ElementRow(attackType, weakElementId)))
      {
        throw new ChallengeRaidCatalogSourceException("element_record_invalid");
      }
    }

    reader.EnsureEnd();
    return rows;
  }

  private static IReadOnlyList<PartRow> ReadParts(byte[] bytes)
  {
    var reader = new MemoryPackReader(bytes);
    var count = reader.ReadCollectionLength();
    var rows = new PartRow[count];
    var identifiers = new HashSet<int>();
    for (var index = 0; index < count; index++)
    {
      reader.RequireObject(23);
      var id = reader.ReadInt32();
      var modelId = reader.ReadInt32();
      _ = reader.ReadString();
      var damageHpRatio = reader.ReadInt32();
      var hpRatio = reader.ReadInt32();
      var defenceRatio = reader.ReadInt32();
      _ = reader.ReadBoolean();
      _ = reader.ReadBoolean();
      _ = reader.ReadInt32();
      var visibleHp = reader.ReadBoolean();
      var linkedPartId = reader.ReadInt32();
      _ = reader.ReadStringArray();
      _ = reader.ReadInt32Array();
      var partType = reader.ReadInt32();
      _ = reader.ReadStringArray();
      var energyResistRatio = reader.ReadInt32();
      var metalResistRatio = reader.ReadInt32();
      var bioResistRatio = reader.ReadInt32();
      var attackRatio = reader.ReadInt32();
      _ = reader.ReadString();
      _ = reader.ReadInt32();
      var isMainPart = reader.ReadBoolean();
      var isDamageable = reader.ReadBoolean();
      if (id <= 0 || modelId <= 0 || linkedPartId < 0 || !identifiers.Add(id))
      {
        throw new ChallengeRaidCatalogSourceException("part_record_invalid");
      }

      rows[index] = new PartRow(
          id,
          modelId,
          partType,
          damageHpRatio,
          hpRatio,
          defenceRatio,
          energyResistRatio,
          metalResistRatio,
          bioResistRatio,
          attackRatio,
          isMainPart,
          isDamageable,
          visibleHp,
          linkedPartId);
    }

    reader.EnsureEnd();
    return Array.AsReadOnly(rows);
  }

  private static WaveGroupIndex ReadWaveGroups(byte[] bytes)
  {
    var text = new UTF8Encoding(false, true).GetString(bytes);
    if (text.Length > 0 && text[0] == '\ufeff')
    {
      text = text[1..];
    }

    var lines = text.Split('\n');
    var header = lines[0].TrimEnd('\r').Split(',').Select(static value => value.Trim()).ToArray();
    if (lines.Length < 2 || header.Length != 2 ||
        !string.Equals(header[0], "stage_id", StringComparison.Ordinal) ||
        !string.Equals(header[1], "group_id", StringComparison.Ordinal))
    {
      throw new ChallengeRaidCatalogSourceException("wave_group_header_invalid");
    }

    var groups = new Dictionary<int, HashSet<string>>();
    var counts = new Dictionary<string, int>(StringComparer.Ordinal);
    var coordinates = new HashSet<(int Stage, string Group)>();
    for (var index = 1; index < lines.Length; index++)
    {
      var line = lines[index].TrimEnd('\r');
      if (line.Length == 0 && index == lines.Length - 1)
      {
        continue;
      }

      var columns = line.Split(',').Select(static value => value.Trim()).ToArray();
      if (columns.Length != 2 ||
          !int.TryParse(columns[0], NumberStyles.None, CultureInfo.InvariantCulture, out var stage) ||
          stage <= 0 || !IsWaveGroupValid(columns[1]) || !coordinates.Add((stage, columns[1])))
      {
        throw new ChallengeRaidCatalogSourceException("wave_group_record_invalid");
      }

      if (!groups.TryGetValue(stage, out var stageGroups))
      {
        stageGroups = new HashSet<string>(StringComparer.Ordinal);
        groups.Add(stage, stageGroups);
      }

      stageGroups.Add(columns[1]);
      counts[columns[1]] = counts.GetValueOrDefault(columns[1]) + 1;
    }

    if (coordinates.Count == 0)
    {
      throw new ChallengeRaidCatalogSourceException("wave_group_record_invalid");
    }

    return new WaveGroupIndex(
        groups.ToDictionary(
            static pair => pair.Key,
            static pair => (IReadOnlySet<string>)pair.Value),
        counts);
  }

  private static IReadOnlyList<WaveRow> ReadWaves(byte[] bytes)
  {
    var reader = new MemoryPackReader(bytes);
    var count = reader.ReadCollectionLength();
    var rows = new WaveRow[count];
    var identifiers = new HashSet<int>();
    for (var index = 0; index < count; index++)
    {
      reader.RequireObject(20);
      var stage = reader.ReadInt32();
      var group = reader.ReadString();
      for (var field = 2; field < 5; field++)
      {
        _ = reader.ReadInt32();
      }

      _ = reader.ReadString();
      _ = reader.ReadInt32();
      _ = reader.ReadBoolean();
      _ = reader.ReadBoolean();
      _ = reader.ReadString();
      _ = reader.ReadString();
      _ = reader.ReadString();
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      _ = reader.ReadString();
      var targets = reader.ReadInt64Array() ?? [];
      var wavePathCount = reader.ReadCollectionLength(allowNull: true, maximumLength: 16_384);
      var spawned = new List<long>();
      for (var path = 0; path < Math.Max(0, wavePathCount); path++)
      {
        reader.RequireObject(3);
        _ = reader.ReadString();
        _ = reader.ReadInt32();
        var monsterCount = reader.ReadCollectionLength(allowNull: true, maximumLength: 16_384);
        for (var monster = 0; monster < Math.Max(0, monsterCount); monster++)
        {
          reader.RequireObject(2);
          spawned.Add(reader.ReadInt64());
          _ = reader.ReadInt32();
        }
      }

      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      if (stage <= 0 || !IsWaveGroupValid(group) || !identifiers.Add(stage))
      {
        throw new ChallengeRaidCatalogSourceException("wave_record_invalid");
      }

      rows[index] = new WaveRow(stage, group!, targets, spawned.ToArray());
    }

    reader.EnsureEnd();
    return Array.AsReadOnly(rows);
  }

  private static T ReadAndClear<T>(byte[] bytes, Func<byte[], T> reader)
  {
    try
    {
      return reader(bytes);
    }
    finally
    {
      CryptographicOperations.ZeroMemory(bytes);
    }
  }

  private static byte[] ReadSingleEntry(
      IReadOnlyList<ZipArchiveEntry> entries,
      string entryName)
  {
    var matches = entries.Where(entry =>
        string.Equals(ZipArchiveGuard.FileName(entry), entryName, StringComparison.Ordinal)).ToArray();
    if (matches.Length != 1)
    {
      throw new ChallengeRaidCatalogSourceException("archive_entry_invalid");
    }

    return ZipArchiveGuard.ReadExactly(matches[0]);
  }

  private static void ValidateArchiveStream(Stream stream, string code)
  {
    if (!stream.CanRead || !stream.CanSeek || stream.Length is <= 0 or > 4L * 1024 * 1024 * 1024)
    {
      throw new ChallengeRaidCatalogSourceException(code);
    }
  }

  private static Sha256Digest ComputeArchiveHash(Stream stream)
  {
    stream.Position = 0;
    return Sha256Digest.FromBytes(SHA256.HashData(stream));
  }

  private static bool TryNormalizeElement(int attackType, out RaidElement element)
  {
    element = attackType switch
    {
      4 => RaidElement.Fire,
      5 => RaidElement.Water,
      6 => RaidElement.Wind,
      7 => RaidElement.Iron,
      8 => RaidElement.Electric,
      _ => default
    };
    return attackType is 4 or 5 or 6 or 7 or 8;
  }

  private static string ElementCode(RaidElement value) => value switch
  {
    RaidElement.Fire => "fire",
    RaidElement.Water => "water",
    RaidElement.Wind => "wind",
    RaidElement.Electric => "electric",
    RaidElement.Iron => "iron",
    _ => throw new ArgumentOutOfRangeException(nameof(value))
  };

  private static bool TryNormalizePartType(int value, out string typeCode)
  {
    typeCode = value switch
    {
      0 => "none",
      1 => "arm-left",
      2 => "arm-right",
      3 => "head",
      4 => "body-lower",
      5 => "body-upper",
      6 => "body",
      7 => "chest",
      8 => "belly",
      9 => "leg-front-left",
      10 => "leg-front-right",
      11 => "leg-back-left",
      12 => "leg-back-right",
      >= 13 and <= 32 => $"weapon-{(value - 12).ToString("D2", CultureInfo.InvariantCulture)}",
      _ => string.Empty
    };
    return typeCode.Length > 0;
  }

  private static bool IsWaveGroupValid(string? value) =>
      !string.IsNullOrWhiteSpace(value) && value.Length <= 128 && value.All(character =>
          (character >= 'a' && character <= 'z') ||
          (character >= 'A' && character <= 'Z') ||
          (character >= '0' && character <= '9') ||
          character is '_' or '-');

  private static bool IsBehaviorKeyValid(string? value) =>
      !string.IsNullOrWhiteSpace(value) && value.Length <= 256 && value.All(character =>
          (character >= 'a' && character <= 'z') ||
          (character >= 'A' && character <= 'Z') ||
          (character >= '0' && character <= '9') ||
          character is '_' or '-');

  private static void Increment(
      IDictionary<(string Code, int? Season), int> diagnostics,
      string code,
      int? season)
  {
    var key = (code, season);
    diagnostics.TryGetValue(key, out var count);
    diagnostics[key] = count + 1;
  }

  private sealed record ManagerRow(int PresetGroupId, int SeasonNumber);

  private sealed record PresetRow(
      int PresetGroupId,
      int DifficultyType,
      int WaveOrder,
      int WaveStageId);

  private sealed record ChallengePresetRelation(int SeasonNumber, int WaveStageId);

  private sealed record WaveRow(
      int StageId,
      string Group,
      long[] TargetMonsterIds,
      long[] SpawnedMonsterIds);

  private sealed record MonsterRow(
      long Id,
      int[] ElementIds,
      int MonsterModelId,
      string SpotBehavior,
      string DefenseSpotBehavior,
      string BaseDefenseSpotBehavior,
      int? SkillRelationCount);

  private sealed record ElementRow(int AttackType, int WeakElementId);

  private sealed record PartRow(
      int Id,
      int MonsterModelId,
      int PartType,
      int DamageHpRatio,
      int HpRatio,
      int DefenceRatio,
      int EnergyResistRatio,
      int MetalResistRatio,
      int BioResistRatio,
      int AttackRatio,
      bool IsMainPart,
      bool IsDamageable,
      bool IsHpVisible,
      int LinkedPartId);

  private sealed record NormalizedPartSet(
      IReadOnlyList<NormalizedRaidPart> Parts,
      bool HasClosedTopology,
      bool HasResolvedTypes);

  private sealed record WaveGroupIndex(
      IReadOnlyDictionary<int, IReadOnlySet<string>> GroupsByStage,
      IReadOnlyDictionary<string, int> RowCountByGroup);
}
