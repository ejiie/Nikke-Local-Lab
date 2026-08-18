using System.Globalization;
using System.IO.Compression;
using System.Security.Cryptography;
using NikkeLocalLab.Domain.CombatSupport;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Import.CombatSupportCatalog;

public sealed class StaticDataCombatSupportCatalogReader
{
  private const string SourceNamespace = "nikke-staticdata";
  private static readonly ZipArchiveLimits ArchiveLimits = new(
      MaximumEntryCount: 20_000,
      MaximumEntryBytes: 32 * 1024 * 1024,
      MaximumTotalBytes: 512L * 1024 * 1024,
      MaximumCompressionRatio: 100m);
  private static readonly string[] RequiredEntries =
  [
    "CharacterTable.mpk",
    "EquipmentOptionTable.mpk",
    "FavoriteItemLevelTable.mpk",
    "FavoriteItemTable.mpk",
    "FunctionTable.mpk",
    "GradeCoreEquipmentTable.mpk",
    "ItemEquipExpTable.mpk",
    "ItemEquipTable.mpk",
    "ItemHarmonyCubeLevelTable.mpk",
    "ItemHarmonyCubeTable.mpk",
    "RecycleResearchLevelTable.mpk",
    "RecycleResearchStatTable.mpk",
    "StateEffectTable.mpk"
  ];

  public CombatSupportCatalogExtraction Read(
      Stream staticDataArchive,
      ReadOnlySpan<byte> identitySecret)
  {
    ArgumentNullException.ThrowIfNull(staticDataArchive);
    if (!staticDataArchive.CanRead || !staticDataArchive.CanSeek)
    {
      throw new CombatSupportCatalogSourceException("archive_stream_invalid");
    }

    if (staticDataArchive.Length is <= 0 or > 64L * 1024 * 1024)
    {
      throw new CombatSupportCatalogSourceException("archive_size_invalid");
    }

    if (identitySecret.Length < 32)
    {
      throw new CombatSupportCatalogSourceException("identity_secret_invalid");
    }

    var entryBytes = new Dictionary<string, byte[]>(StringComparer.Ordinal);
    try
    {
      staticDataArchive.Position = 0;
      var archiveSha256 = Sha256Digest.FromBytes(SHA256.HashData(staticDataArchive));
      staticDataArchive.Position = 0;
      using (var archive = new ZipArchive(staticDataArchive, ZipArchiveMode.Read, leaveOpen: true))
      {
        var validatedEntries = ZipArchiveGuard.Validate(archive, ArchiveLimits);
        foreach (var requiredEntry in RequiredEntries)
        {
          entryBytes.Add(requiredEntry, ReadSingleEntry(validatedEntries, requiredEntry));
        }
      }

      var diagnostics = new Dictionary<string, int>(StringComparer.Ordinal);
      var characterAliases = ReadCharacterAliases(
          entryBytes["CharacterTable.mpk"],
          identitySecret);
      var equipmentRows = ReadEquipment(entryBytes["ItemEquipTable.mpk"]);
      var standardOverloadGroupId = ResolveStandardOverloadGroup(equipmentRows);
      var equipment = BuildEquipmentCandidates(
          equipmentRows,
          ReadGradeCoreEquipment(entryBytes["GradeCoreEquipmentTable.mpk"]),
          ReadEquipmentExperience(entryBytes["ItemEquipExpTable.mpk"]),
          identitySecret);
      var cubes = BuildCubeCandidates(
          ReadCubes(entryBytes["ItemHarmonyCubeTable.mpk"]),
          ReadCubeLevels(entryBytes["ItemHarmonyCubeLevelTable.mpk"]),
          identitySecret,
          diagnostics);
      var collections = BuildCollectionCandidates(
          ReadFavoriteItems(entryBytes["FavoriteItemTable.mpk"]),
          ReadFavoriteLevels(entryBytes["FavoriteItemLevelTable.mpk"]),
          characterAliases,
          identitySecret,
          diagnostics);
      var consoles = BuildConsoleCandidates(
          ReadConsoleStats(entryBytes["RecycleResearchStatTable.mpk"]),
          ReadConsoleLevels(entryBytes["RecycleResearchLevelTable.mpk"]),
          identitySecret);
      var stateEffects = ReadStateEffects(entryBytes["StateEffectTable.mpk"]);
      var functions = ReadFunctions(entryBytes["FunctionTable.mpk"]);
      var overloadOptions = BuildOverloadOptionCandidates(
          ReadEquipmentOptions(entryBytes["EquipmentOptionTable.mpk"]),
          stateEffects,
          functions,
          standardOverloadGroupId,
          identitySecret,
          diagnostics);

      var definitions = equipment
          .Concat(cubes)
          .Concat(collections)
          .Concat(consoles)
          .Concat(overloadOptions)
          .ToArray();
      var canonicalSha256 = ImportedCombatSupportCandidateCanonicalizer.ComputeHash(definitions);
      return new CombatSupportCatalogExtraction(
          definitions,
          diagnostics.Select(static item => new CombatSupportCatalogDiagnostic(item.Key, item.Value)),
          archiveSha256,
          canonicalSha256);
    }
    catch (CombatSupportCatalogSourceException)
    {
      throw;
    }
    catch (Exception exception) when (
        exception is InvalidDataException or IOException or OverflowException or
        ArgumentException or CryptographicException)
    {
      throw new CombatSupportCatalogSourceException("archive_decode_invalid");
    }
    finally
    {
      foreach (var bytes in entryBytes.Values)
      {
        CryptographicOperations.ZeroMemory(bytes);
      }
    }
  }

  private static byte[] ReadSingleEntry(
      IReadOnlyList<ZipArchiveEntry> archiveEntries,
      string requiredName)
  {
    var matches = archiveEntries
        .Where(entry => string.Equals(
            ZipArchiveGuard.FileName(entry),
            requiredName,
            StringComparison.Ordinal))
        .ToArray();
    if (matches.Length != 1)
    {
      throw new CombatSupportCatalogSourceException("archive_required_entry_invalid");
    }

    return ZipArchiveGuard.ReadExactly(matches[0]);
  }

  private static IReadOnlyDictionary<int, SourceAliasFingerprint> ReadCharacterAliases(
      byte[] bytes,
      ReadOnlySpan<byte> identitySecret)
  {
    var reader = new MemoryPackReader(bytes);
    var count = reader.ReadCollectionLength();
    var rows = new List<CharacterAliasRow>(count);
    var identifiers = new HashSet<int>();
    for (var index = 0; index < count; index++)
    {
      reader.RequireObject(40);
      var id = reader.ReadInt32();
      if (id <= 0 || !identifiers.Add(id))
      {
        throw new CombatSupportCatalogSourceException("character_identifier_invalid");
      }

      _ = reader.ReadString();
      _ = reader.ReadString();
      var resourceId = reader.ReadInt32();
      _ = reader.ReadStringArray();
      var nameCode = reader.ReadInt32();
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      var gradeCoreId = reader.ReadInt32();
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      _ = reader.ReadInt32Array();
      for (var field = 0; field < 19; field++)
      {
        _ = reader.ReadInt32();
      }

      _ = reader.ReadString();
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      var isVisible = reader.ReadBoolean();
      _ = reader.ReadBoolean();
      var isDetailClose = reader.ReadBoolean();
      rows.Add(new CharacterAliasRow(resourceId, nameCode, gradeCoreId, isVisible, isDetailClose));
    }

    reader.EnsureEnd();
    var result = new Dictionary<int, SourceAliasFingerprint>();
    foreach (var group in rows
                 .Where(static row => row.IsVisible && !row.IsDetailClose)
                 .GroupBy(static row => row.NameCode))
    {
      if (group.Key <= 0 || group.Select(static row => row.ResourceId).Distinct().Count() != 1 ||
          group.Select(static row => row.GradeCoreId).Distinct().Count() != group.Count())
      {
        throw new CombatSupportCatalogSourceException("character_alias_relation_invalid");
      }

      result.Add(
          group.Key,
          Alias(identitySecret, "character-resource", group.Key));
    }

    return result;
  }

  private static IReadOnlyList<EquipmentRow> ReadEquipment(byte[] bytes)
  {
    var reader = new MemoryPackReader(bytes);
    var count = reader.ReadCollectionLength();
    var rows = new EquipmentRow[count];
    var identifiers = new HashSet<int>();
    for (var index = 0; index < count; index++)
    {
      reader.RequireObject(15);
      var id = reader.ReadInt32();
      _ = reader.ReadString();
      _ = reader.ReadString();
      _ = reader.ReadString();
      _ = reader.ReadInt32();
      var slot = reader.ReadInt32();
      var combatRole = reader.ReadInt32();
      var tier = reader.ReadInt32();
      var gradeCoreId = reader.ReadInt32();
      var growGrade = reader.ReadInt32();
      var stats = ReadObjectIntRows(reader, 2);
      var optionSlots = ReadObjectIntRows(reader, 2);
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      if (id <= 0 || slot <= 0 || combatRole <= 0 || tier <= 0 ||
          gradeCoreId <= 0 || growGrade < 0 || stats.Length != 6 || optionSlots.Length != 3 ||
          stats.Any(static row => row[1] < 0) ||
          !identifiers.Add(id))
      {
        throw new CombatSupportCatalogSourceException("equipment_value_invalid");
      }

      rows[index] = new EquipmentRow(
          id,
          slot,
          combatRole,
          tier,
          gradeCoreId,
          growGrade,
          stats,
          optionSlots);
    }

    reader.EnsureEnd();
    return rows;
  }

  private static IReadOnlyList<EquipmentExperienceRow> ReadEquipmentExperience(byte[] bytes)
  {
    var reader = new MemoryPackReader(bytes);
    var count = reader.ReadCollectionLength();
    var rows = new EquipmentExperienceRow[count];
    var identifiers = new HashSet<int>();
    var coordinates = new HashSet<(int Tier, int GradeCoreId, int Level)>();
    for (var index = 0; index < count; index++)
    {
      reader.RequireObject(5);
      var id = reader.ReadInt32();
      var tier = reader.ReadInt32();
      var gradeCoreId = reader.ReadInt32();
      var level = reader.ReadInt32();
      var experience = reader.ReadInt32();
      if (id <= 0 || tier <= 0 || gradeCoreId <= 0 || level < 0 || experience < 0 ||
          !identifiers.Add(id) || !coordinates.Add((tier, gradeCoreId, level)))
      {
        throw new CombatSupportCatalogSourceException("equipment_exp_coordinate_invalid");
      }

      rows[index] = new EquipmentExperienceRow(tier, gradeCoreId, level);
    }

    reader.EnsureEnd();
    return rows;
  }

  private static IReadOnlyDictionary<int, GradeCoreEquipmentRow> ReadGradeCoreEquipment(byte[] bytes)
  {
    var reader = new MemoryPackReader(bytes);
    var count = reader.ReadCollectionLength();
    var rows = new Dictionary<int, GradeCoreEquipmentRow>();
    for (var index = 0; index < count; index++)
    {
      reader.RequireObject(6);
      var id = reader.ReadInt32();
      var grade = reader.ReadInt32();
      var maximumLevel = reader.ReadInt32();
      var maximumGrade = reader.ReadInt32();
      var materialValue = reader.ReadInt32();
      var rarity = reader.ReadString();
      if (id <= 0 || grade < 0 || maximumLevel < 0 || maximumGrade < grade || materialValue < 0 ||
          string.IsNullOrWhiteSpace(rarity) ||
          !rows.TryAdd(id, new GradeCoreEquipmentRow(grade, maximumLevel)))
      {
        throw new CombatSupportCatalogSourceException("equipment_grade_coordinate_invalid");
      }
    }

    reader.EnsureEnd();
    return rows;
  }

  private static IReadOnlyList<ImportedCombatSupportDefinitionCandidate> BuildEquipmentCandidates(
      IReadOnlyList<EquipmentRow> equipment,
      IReadOnlyDictionary<int, GradeCoreEquipmentRow> gradeCoreEquipment,
      IReadOnlyList<EquipmentExperienceRow> experience,
      ReadOnlySpan<byte> identitySecret)
  {
    var supported = equipment.Where(static row => row.Tier is 9 or 10 && row.CombatRole is >= 1 and <= 3)
        .ToArray();
    var expected =
        (from role in Enumerable.Range(1, 3)
         from slot in Enumerable.Range(1, 4)
         from tier in new[] { 9, 10 }
         select (Role: role, Slot: slot, Tier: tier)).ToHashSet();
    if (supported.Length != 24 ||
        !expected.SetEquals(supported.Select(static row => (row.CombatRole, row.Slot, row.Tier))) ||
        supported.GroupBy(static row => (row.CombatRole, row.Slot, row.Tier))
            .Any(static group => group.Count() != 1) ||
        supported.Any(static row => row.GrowGrade < 0))
    {
      throw new CombatSupportCatalogSourceException("equipment_supported_grid_invalid");
    }

    var tierTenById = supported.Where(static row => row.Tier == 10)
        .ToDictionary(static row => row.Id);
    foreach (var row in supported)
    {
      if (row.Tier == 10)
      {
        if (row.GrowGrade != 0)
        {
          throw new CombatSupportCatalogSourceException("equipment_growth_relation_invalid");
        }

        continue;
      }

      if (!tierTenById.TryGetValue(row.GrowGrade, out var target) ||
          target.CombatRole != row.CombatRole || target.Slot != row.Slot)
      {
        throw new CombatSupportCatalogSourceException("equipment_growth_relation_invalid");
      }
    }

    foreach (var coordinate in supported.Select(static row => (row.Tier, row.GradeCoreId)).Distinct())
    {
      var levels = experience
          .Where(row => row.Tier == coordinate.Tier && row.GradeCoreId == coordinate.GradeCoreId)
          .Select(static row => row.Level)
          .Order()
          .ToArray();
      if (!levels.SequenceEqual(Enumerable.Range(0, 6)))
      {
        throw new CombatSupportCatalogSourceException("equipment_exp_fk_invalid");
      }
    }

    var result = new List<ImportedCombatSupportDefinitionCandidate>(supported.Length);
    foreach (var row in supported)
    {
      if (!gradeCoreEquipment.TryGetValue(row.GradeCoreId, out var grade) ||
          grade.MaximumLevel != 5)
      {
        throw new CombatSupportCatalogSourceException("equipment_grade_fk_invalid");
      }

      result.Add(new ImportedCombatSupportDefinitionCandidate(
          Alias(identitySecret, "combat-support-equipment", row.Id),
          new ImportedEquipmentDefinitionPayload(
              MapEquipmentSlot(row.Slot),
              CombatSupportFact<CombatSupportCombatRole>.Ready(MapCombatRole(row.CombatRole)),
              CombatSupportFact<CombatSupportManufacturer>.NotApplicable(),
              CombatSupportFact<int>.Ready(row.Tier),
              CombatSupportFact<int>.Ready(grade.Grade),
              CombatSupportFact<int>.Ready(grade.MaximumLevel),
              CombatSupportFact<bool>.Ready(row.Tier == 10),
              BuildEquipmentContributions(row),
              BuildEquipmentOptionSlots(row))));
    }

    return Array.AsReadOnly(result.ToArray());
  }

  private static int ResolveStandardOverloadGroup(IReadOnlyList<EquipmentRow> equipment)
  {
    var scoped = equipment
        .Where(static row => row.Tier is 9 or 10 && row.CombatRole is >= 1 and <= 3)
        .ToArray();
    var tierNineSlots = scoped.Where(static row => row.Tier == 9)
        .SelectMany(static row => row.OptionSlots)
        .ToArray();
    var tierTenSlots = scoped.Where(static row => row.Tier == 10)
        .SelectMany(static row => row.OptionSlots)
        .ToArray();
    if (tierNineSlots.Length != 36 || tierNineSlots.Any(static row => row[0] != 0 || row[1] != 0) ||
        tierTenSlots.Length != 36 || tierTenSlots.Any(static row => row[0] <= 0) ||
        tierTenSlots.Select(static row => row[0]).Distinct().Count() != 1)
    {
      throw new CombatSupportCatalogSourceException("equipment_overload_group_relation_invalid");
    }

    return tierTenSlots[0][0];
  }

  private static IReadOnlyList<CubeRow> ReadCubes(byte[] bytes)
  {
    var reader = new MemoryPackReader(bytes);
    var count = reader.ReadCollectionLength();
    var rows = new CubeRow[count];
    var identifiers = new HashSet<int>();
    for (var index = 0; index < count; index++)
    {
      reader.RequireObject(15);
      var id = reader.ReadInt32();
      _ = reader.ReadString();
      _ = reader.ReadString();
      _ = reader.ReadInt32();
      _ = reader.ReadString();
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      _ = reader.ReadString();
      _ = reader.ReadString();
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      var rarity = reader.ReadInt32();
      var combatRole = reader.ReadInt32();
      var levelEnhanceId = reader.ReadInt32();
      var skillGroupIds = ReadSingleIntObjectList(reader);
      if (id <= 0 || levelEnhanceId <= 0 || skillGroupIds.Length != 3 ||
          skillGroupIds.Count(static value => value == 0) != 1 ||
          !identifiers.Add(id))
      {
        throw new CombatSupportCatalogSourceException("cube_value_invalid");
      }

      rows[index] = new CubeRow(id, rarity, combatRole, levelEnhanceId);
    }

    reader.EnsureEnd();
    return rows;
  }

  private static IReadOnlyList<CubeLevelRow> ReadCubeLevels(byte[] bytes)
  {
    var reader = new MemoryPackReader(bytes);
    var count = reader.ReadCollectionLength();
    var rows = new CubeLevelRow[count];
    var identifiers = new HashSet<int>();
    var coordinates = new HashSet<(int GroupId, int Level)>();
    for (var index = 0; index < count; index++)
    {
      reader.RequireObject(9);
      var id = reader.ReadInt32();
      var groupId = reader.ReadInt32();
      var level = reader.ReadInt32();
      var skillLevels = ReadSingleIntObjectList(reader);
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      var capacity = reader.ReadInt32();
      var stats = ReadObjectIntRows(reader, 2);
      if (id <= 0 || groupId <= 0 || level <= 0 || capacity < 0 ||
          skillLevels.Length != 3 || skillLevels.Any(static value => value < 0) ||
          stats.Length != 3 || !identifiers.Add(id) || !coordinates.Add((groupId, level)))
      {
        throw new CombatSupportCatalogSourceException("cube_level_coordinate_invalid");
      }

      rows[index] = new CubeLevelRow(groupId, level, skillLevels, capacity, stats);
    }

    reader.EnsureEnd();
    return rows;
  }

  private static IReadOnlyList<ImportedCombatSupportDefinitionCandidate> BuildCubeCandidates(
      IReadOnlyList<CubeRow> cubes,
      IReadOnlyList<CubeLevelRow> levels,
      ReadOnlySpan<byte> identitySecret,
      IDictionary<string, int> diagnostics)
  {
    if (cubes.Count == 0 || cubes.Select(static row => row.LevelEnhanceId).Distinct().Count() != cubes.Count)
    {
      throw new CombatSupportCatalogSourceException("cube_level_fk_invalid");
    }

    var groups = levels.GroupBy(static row => row.GroupId)
        .ToDictionary(static group => group.Key, static group => group.OrderBy(row => row.Level).ToArray());
    if (!cubes.Select(static row => row.LevelEnhanceId).ToHashSet().SetEquals(groups.Keys))
    {
      throw new CombatSupportCatalogSourceException("cube_level_fk_invalid");
    }

    Increment(diagnostics, "cube_stat_unit_unresolved", levels.Sum(static row => row.Stats.Length));
    Increment(diagnostics, "skill_definition_catalog_not_imported", cubes.Count);
    var result = new List<ImportedCombatSupportDefinitionCandidate>(cubes.Count);
    foreach (var cube in cubes)
    {
      var group = groups[cube.LevelEnhanceId];
      if (!group.Select(static row => row.Level).SequenceEqual(Enumerable.Range(1, 15)))
      {
        throw new CombatSupportCatalogSourceException("cube_level_coordinates_invalid");
      }

      var coordinates = group.Select(row => new CombatSupportLevelCoordinate(
          row.Level,
          CombatSupportFact<int>.NotApplicable(),
          CombatSupportFact<int>.Ready(row.Capacity),
          row.SkillLevels,
          BuildContributions(
              row.Stats,
              CombatSupportFact<CombatSupportValueUnit>.Unresolved("cube_stat_unit_unresolved"),
              diagnostics)))
          .ToArray();
      result.Add(new ImportedCombatSupportDefinitionCandidate(
          Alias(identitySecret, "combat-support-harmony-cube", cube.Id),
          new ImportedHarmonyCubeDefinitionPayload(
              MapRarity(cube.Rarity),
              MapOptionalCombatRole(cube.CombatRole),
              CombatSupportFact<int>.Ready(15),
              Array.AsReadOnly(coordinates),
              CombatSupportFact<bool>.Unresolved("skill_definition_catalog_not_imported"))));
    }

    return Array.AsReadOnly(result.ToArray());
  }

  private static IReadOnlyList<FavoriteItemRow> ReadFavoriteItems(byte[] bytes)
  {
    var reader = new MemoryPackReader(bytes);
    var count = reader.ReadCollectionLength();
    var rows = new FavoriteItemRow[count];
    var identifiers = new HashSet<int>();
    for (var index = 0; index < count; index++)
    {
      reader.RequireObject(17);
      var id = reader.ReadInt32();
      if (id <= 0 || !identifiers.Add(id))
      {
        throw new CombatSupportCatalogSourceException("favorite_item_identifier_invalid");
      }

      for (var field = 0; field < 5; field++)
      {
        _ = reader.ReadString();
      }

      _ = reader.ReadInt32();
      var rarity = reader.ReadInt32();
      var favoriteType = reader.ReadInt32();
      var weapon = reader.ReadInt32();
      var nameCode = reader.ReadInt32();
      var maximumLevel = reader.ReadInt32();
      var levelEnhanceId = reader.ReadInt32();
      _ = reader.ReadInt32();
      var collectionSkillGroups = ReadSingleIntObjectList(reader);
      var favoriteSkillGroups = ReadObjectIntRows(reader, 3);
      _ = reader.ReadInt32();
      var validType = favoriteType switch
      {
        1 => rarity is 1 or 2 && nameCode == 0 && collectionSkillGroups.Length == 2,
        2 => rarity == 3 && nameCode > 0 && favoriteSkillGroups.Length == 3,
        _ => false
      };
      if (!validType || weapon <= 0 || maximumLevel <= 0 || levelEnhanceId <= 0 ||
          collectionSkillGroups.Length != 2 || favoriteSkillGroups.Length != 3)
      {
        throw new CombatSupportCatalogSourceException("favorite_item_value_invalid");
      }

      rows[index] = new FavoriteItemRow(
          id,
          rarity,
          favoriteType,
          weapon,
          nameCode,
          maximumLevel,
          levelEnhanceId);
    }

    reader.EnsureEnd();
    return rows;
  }

  private static IReadOnlyList<FavoriteLevelRow> ReadFavoriteLevels(byte[] bytes)
  {
    var reader = new MemoryPackReader(bytes);
    var count = reader.ReadCollectionLength();
    var rows = new FavoriteLevelRow[count];
    var identifiers = new HashSet<int>();
    var coordinates = new HashSet<(int GroupId, int Grade, int Level)>();
    for (var index = 0; index < count; index++)
    {
      reader.RequireObject(6);
      var id = reader.ReadInt32();
      var groupId = reader.ReadInt32();
      var grade = reader.ReadInt32();
      var level = reader.ReadInt32();
      var stats = ReadObjectIntRows(reader, 2);
      var skillLevels = ReadSingleIntObjectList(reader);
      if (id <= 0 || groupId <= 0 || grade < 0 || level < 0 ||
          stats.Length != 3 || skillLevels.Length != 2 ||
          skillLevels.Any(static value => value < 0) ||
          !identifiers.Add(id) || !coordinates.Add((groupId, grade, level)))
      {
        throw new CombatSupportCatalogSourceException("favorite_level_coordinate_invalid");
      }

      rows[index] = new FavoriteLevelRow(groupId, grade, level, stats, skillLevels);
    }

    reader.EnsureEnd();
    return rows;
  }

  private static IReadOnlyList<ImportedCombatSupportDefinitionCandidate> BuildCollectionCandidates(
      IReadOnlyList<FavoriteItemRow> items,
      IReadOnlyList<FavoriteLevelRow> levels,
      IReadOnlyDictionary<int, SourceAliasFingerprint> characterAliases,
      ReadOnlySpan<byte> identitySecret,
      IDictionary<string, int> diagnostics)
  {
    if (items.Count == 0 || items.Select(static row => row.LevelEnhanceId).Distinct().Count() != items.Count ||
        items.GroupBy(static row => (row.FavoriteType, row.Rarity, row.Weapon, row.NameCode))
            .Any(static group => group.Count() != 1))
    {
      throw new CombatSupportCatalogSourceException("favorite_level_fk_invalid");
    }

    var groups = levels.GroupBy(static row => row.GroupId)
        .ToDictionary(static group => group.Key, static group => group.OrderBy(row => row.Level).ToArray());
    if (!items.Select(static item => item.LevelEnhanceId).ToHashSet().SetEquals(groups.Keys))
    {
      throw new CombatSupportCatalogSourceException("favorite_level_fk_invalid");
    }

    var result = new List<ImportedCombatSupportDefinitionCandidate>(items.Count);
    Increment(diagnostics, "skill_definition_catalog_not_imported", items.Count);
    foreach (var item in items)
    {
      var group = groups[item.LevelEnhanceId];
      if (!group.Select(static row => row.Level)
          .SequenceEqual(Enumerable.Range(0, checked(item.MaximumLevel + 1))))
      {
        throw new CombatSupportCatalogSourceException("favorite_level_coordinates_invalid");
      }

      var coordinates = group.Select(row => new CombatSupportLevelCoordinate(
          row.Level,
          CombatSupportFact<int>.Ready(row.Grade),
          CombatSupportFact<int>.NotApplicable(),
          row.SkillLevels,
          BuildContributions(
              row.Stats,
              CombatSupportFact<CombatSupportValueUnit>.Ready(CombatSupportValueUnit.Absolute),
              diagnostics)))
          .ToArray();
      if (item.FavoriteType == 1)
      {
        result.Add(new ImportedCombatSupportDefinitionCandidate(
            Alias(identitySecret, "combat-support-generic-collection", item.Id),
            new ImportedGenericCollectionDefinitionPayload(
                MapWeaponClass(item.Weapon, diagnostics),
                MapRarity(item.Rarity),
                CombatSupportFact<int>.Ready(item.MaximumLevel),
                Array.AsReadOnly(coordinates),
                CombatSupportFact<bool>.Unresolved("skill_definition_catalog_not_imported"))));
        continue;
      }

      var applicableCharacter = characterAliases.TryGetValue(item.NameCode, out var characterAlias)
          ? CombatSupportFact<SourceAliasFingerprint>.Ready(characterAlias)
          : CombatSupportFact<SourceAliasFingerprint>.Unresolved("favorite_character_relation_unresolved");
      if (applicableCharacter.Status == CombatSupportFactStatus.Unresolved)
      {
        Increment(diagnostics, "favorite_character_relation_unresolved");
      }

      result.Add(new ImportedCombatSupportDefinitionCandidate(
          Alias(identitySecret, "combat-support-favorite", item.Id),
          new ImportedFavoriteDefinitionPayload(
              applicableCharacter,
              MapRarity(item.Rarity),
              CombatSupportFact<int>.Ready(item.MaximumLevel),
              Array.AsReadOnly(coordinates),
              CombatSupportFact<bool>.Unresolved("skill_definition_catalog_not_imported"))));
    }

    return Array.AsReadOnly(result.ToArray());
  }

  private static IReadOnlyList<ConsoleStatRow> ReadConsoleStats(byte[] bytes)
  {
    var reader = new MemoryPackReader(bytes);
    var count = reader.ReadCollectionLength();
    var rows = new ConsoleStatRow[count];
    var identifiers = new HashSet<int>();
    var coordinates = new HashSet<(int Type, int Subtype)>();
    for (var index = 0; index < count; index++)
    {
      reader.RequireObject(14);
      var id = reader.ReadInt32();
      _ = reader.ReadString();
      _ = reader.ReadString();
      _ = reader.ReadString();
      _ = reader.ReadInt32();
      var type = reader.ReadInt32();
      var subtype = reader.ReadInt32();
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      var attack = reader.ReadInt32();
      var defence = reader.ReadInt32();
      var hp = reader.ReadInt32();
      if (id <= 0 || attack < 0 || defence < 0 || hp < 0 ||
          !identifiers.Add(id) || !coordinates.Add((type, subtype)))
      {
        throw new CombatSupportCatalogSourceException("console_stat_coordinate_invalid");
      }

      rows[index] = new ConsoleStatRow(id, type, subtype, attack, defence, hp);
    }

    reader.EnsureEnd();
    return rows;
  }

  private static IReadOnlyList<ConsoleLevelRow> ReadConsoleLevels(byte[] bytes)
  {
    var reader = new MemoryPackReader(bytes);
    var count = reader.ReadCollectionLength();
    var rows = new ConsoleLevelRow[count];
    var identifiers = new HashSet<int>();
    var coordinates = new HashSet<(int Type, int Subtype, int Level)>();
    for (var index = 0; index < count; index++)
    {
      reader.RequireObject(7);
      var id = reader.ReadInt32();
      var type = reader.ReadInt32();
      var subtype = reader.ReadInt32();
      var level = reader.ReadInt32();
      var minimumSynchroLevel = reader.ReadInt32();
      var itemId = reader.ReadInt32();
      var itemValue = reader.ReadInt32();
      if (id <= 0 || level <= 0 || minimumSynchroLevel < 0 || itemId <= 0 || itemValue < 0 ||
          !identifiers.Add(id) || !coordinates.Add((type, subtype, level)))
      {
        throw new CombatSupportCatalogSourceException("console_level_coordinate_invalid");
      }

      rows[index] = new ConsoleLevelRow(type, subtype, level, minimumSynchroLevel);
    }

    reader.EnsureEnd();
    return rows;
  }

  private static IReadOnlyList<ImportedCombatSupportDefinitionCandidate> BuildConsoleCandidates(
      IReadOnlyList<ConsoleStatRow> stats,
      IReadOnlyList<ConsoleLevelRow> levels,
      ReadOnlySpan<byte> identitySecret)
  {
    if (stats.Count != 9)
    {
      throw new CombatSupportCatalogSourceException("console_coordinate_set_invalid");
    }

    var levelGroups = levels.GroupBy(static row => (row.Type, row.Subtype))
        .ToDictionary(static group => group.Key, static group => group.OrderBy(row => row.Level).ToArray());
    if (!stats.Select(static row => (row.Type, row.Subtype)).ToHashSet().SetEquals(levelGroups.Keys))
    {
      throw new CombatSupportCatalogSourceException("console_level_fk_invalid");
    }

    foreach (var group in levelGroups.Values)
    {
      if (group.Length == 0 ||
          !group.Select(static row => row.Level).SequenceEqual(Enumerable.Range(1, group.Length)))
      {
        throw new CombatSupportCatalogSourceException("console_level_coordinates_invalid");
      }
    }

    var coordinates = new HashSet<CombatSupportConsoleCoordinate>();
    var result = new List<ImportedCombatSupportDefinitionCandidate>(9);
    foreach (var stat in stats)
    {
      var coordinate = MapConsoleCoordinate(stat.Type, stat.Subtype);
      if (!coordinates.Add(coordinate))
      {
        throw new CombatSupportCatalogSourceException("console_coordinate_set_invalid");
      }

      var group = levelGroups[(stat.Type, stat.Subtype)];
      var maximumLevel = group.Length;
      var legalLevels = group.Select(row => new CombatSupportLevelCoordinate(
          row.Level,
          CombatSupportFact<int>.NotApplicable(),
          CombatSupportFact<int>.NotApplicable(),
          [],
          [],
          CombatSupportFact<int>.Ready(row.MinimumSynchroLevel)))
          .ToArray();
      var perLevelContributions = new[]
      {
        Contribution(0, CombatSupportStat.Attack, stat.Attack),
        Contribution(1, CombatSupportStat.Defence, stat.Defence),
        Contribution(2, CombatSupportStat.Hp, stat.Hp)
      };
      result.Add(new ImportedCombatSupportDefinitionCandidate(
          Alias(identitySecret, "combat-support-console", stat.Id),
          new ImportedConsoleDefinitionPayload(
              coordinate,
              CombatSupportFact<int>.Ready(maximumLevel),
              Array.AsReadOnly(legalLevels),
              Array.AsReadOnly(perLevelContributions))));
    }

    if (!coordinates.SetEquals(Enum.GetValues<CombatSupportConsoleCoordinate>()))
    {
      throw new CombatSupportCatalogSourceException("console_coordinate_set_invalid");
    }

    return Array.AsReadOnly(result.ToArray());
  }

  private static IReadOnlyDictionary<int, StateEffectRow> ReadStateEffects(byte[] bytes)
  {
    var reader = new MemoryPackReader(bytes);
    var count = reader.ReadCollectionLength();
    var rows = new Dictionary<int, StateEffectRow>();
    for (var index = 0; index < count; index++)
    {
      reader.RequireObject(5);
      var id = reader.ReadInt32();
      _ = reader.ReadInt32Array();
      _ = reader.ReadInt32Array();
      var functionIds = ReadSingleIntObjectList(reader);
      _ = reader.ReadString();
      if (id <= 0 || !rows.TryAdd(id, new StateEffectRow(functionIds)))
      {
        throw new CombatSupportCatalogSourceException("state_effect_identifier_invalid");
      }
    }

    reader.EnsureEnd();
    return rows;
  }

  private static IReadOnlyDictionary<int, FunctionRow> ReadFunctions(byte[] bytes)
  {
    var reader = new MemoryPackReader(bytes);
    var count = reader.ReadCollectionLength();
    var rows = new Dictionary<int, FunctionRow>();
    for (var index = 0; index < count; index++)
    {
      reader.RequireObject(55);
      var id = reader.ReadInt32();
      _ = reader.ReadInt32();
      var level = reader.ReadInt32();
      _ = reader.ReadInt32();
      _ = reader.ReadString();
      _ = reader.ReadString();
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      var functionType = reader.ReadInt32();
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      var functionValue = reader.ReadInt64();
      _ = reader.ReadInt32();
      _ = reader.ReadBoolean();
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      _ = reader.ReadInt64();
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      _ = reader.ReadInt64();
      _ = reader.ReadInt32();
      _ = reader.ReadString();
      _ = reader.ReadString();
      _ = reader.ReadInt32();
      for (var effect = 0; effect < 7; effect++)
      {
        _ = reader.ReadString();
        _ = reader.ReadInt32();
        _ = reader.ReadInt32();
      }

      _ = reader.ReadInt32Array();
      if (id <= 0 || !rows.TryAdd(id, new FunctionRow(level, functionType, functionValue)))
      {
        throw new CombatSupportCatalogSourceException("function_identifier_invalid");
      }
    }

    reader.EnsureEnd();
    return rows;
  }

  private static IReadOnlyList<EquipmentOptionRow> ReadEquipmentOptions(byte[] bytes)
  {
    var reader = new MemoryPackReader(bytes);
    var count = reader.ReadCollectionLength();
    var rows = new EquipmentOptionRow[count];
    var identifiers = new HashSet<int>();
    for (var index = 0; index < count; index++)
    {
      reader.RequireObject(7);
      var id = reader.ReadInt32();
      _ = reader.ReadString();
      var optionGroupId = reader.ReadInt32();
      var optionGroupRatio = reader.ReadInt32();
      var stateEffectGroupId = reader.ReadInt32();
      var stateEffects = ReadObjectIntRows(reader, 2);
      var optionRatio = reader.ReadInt32();
      if (id <= 0 || optionGroupId <= 0 || optionGroupRatio < 0 || stateEffectGroupId <= 0 ||
          optionRatio < 0 || stateEffects.Length == 0 ||
          stateEffects.Any(static row => row[0] <= 0 || row[1] <= 0) ||
          !identifiers.Add(id))
      {
        throw new CombatSupportCatalogSourceException("overload_option_value_invalid");
      }

      rows[index] = new EquipmentOptionRow(
          id,
          optionGroupId,
          optionGroupRatio,
          stateEffectGroupId,
          optionRatio,
          stateEffects);
    }

    reader.EnsureEnd();
    return rows;
  }

  private static IReadOnlyList<ImportedCombatSupportDefinitionCandidate> BuildOverloadOptionCandidates(
      IReadOnlyList<EquipmentOptionRow> options,
      IReadOnlyDictionary<int, StateEffectRow> stateEffects,
      IReadOnlyDictionary<int, FunctionRow> functions,
      int standardGroupId,
      ReadOnlySpan<byte> identitySecret,
      IDictionary<string, int> diagnostics)
  {
    var selected = options.Where(option => option.OptionGroupId == standardGroupId).ToArray();
    if (options.Count != 30 || selected.Length != 27 || options.Count - selected.Length != 3)
    {
      throw new CombatSupportCatalogSourceException("overload_standard_group_invalid");
    }

    var resolvedRows = new List<ResolvedEquipmentOptionRow>(selected.Length);
    foreach (var option in selected)
    {
      if (option.StateEffects.Length != 5)
      {
        throw new CombatSupportCatalogSourceException("overload_state_effect_cardinality_invalid");
      }

      var resolvedValues = new List<ResolvedOverloadValue>(5);
      foreach (var reference in option.StateEffects)
      {
        if (!stateEffects.TryGetValue(reference[0], out var stateEffect))
        {
          throw new CombatSupportCatalogSourceException("overload_state_effect_fk_invalid");
        }

        var nonzeroFunctionIds = stateEffect.FunctionIds.Where(static value => value != 0).ToArray();
        if (nonzeroFunctionIds.Length != 1 ||
            !functions.TryGetValue(nonzeroFunctionIds[0], out var function) ||
            function.Level != reference[1])
        {
          throw new CombatSupportCatalogSourceException("overload_function_fk_invalid");
        }

        resolvedValues.Add(new ResolvedOverloadValue(
            Alias(identitySecret, "combat-support-overload-legal-value", reference[0]),
            function.Level,
            function.FunctionType,
            function.FunctionValue));
      }

      if (resolvedValues.Select(static value => value.FunctionType).Distinct().Count() != 1)
      {
        throw new CombatSupportCatalogSourceException("overload_function_kind_invalid");
      }

      resolvedRows.Add(new ResolvedEquipmentOptionRow(option, resolvedValues.ToArray()));
    }

    var byFunctionType = resolvedRows.GroupBy(static row => row.Values[0].FunctionType).ToArray();
    if (byFunctionType.Length != 9 || byFunctionType.Any(static group => group.Count() != 3))
    {
      throw new CombatSupportCatalogSourceException("overload_kind_coordinate_invalid");
    }

    var result = new List<ImportedCombatSupportDefinitionCandidate>(9);
    var kindWeightTotal = 0;
    foreach (var group in byFunctionType)
    {
      var optionType = MapOverloadOptionType(group.Key);
      var rows = group.ToArray();
      var kindWeights = rows.Select(static row => row.Source.OptionGroupRatio).Distinct().ToArray();
      var stateEffectGroups = rows.Select(static row => row.Source.StateEffectGroupId).Distinct().ToArray();
      if (kindWeights.Length != 1 || stateEffectGroups.Length != 1 ||
          kindWeights[0] != ExpectedOverloadKindWeight(optionType))
      {
        throw new CombatSupportCatalogSourceException("overload_kind_weight_invalid");
      }

      kindWeightTotal = checked(kindWeightTotal + kindWeights[0]);
      var orderedRows = rows.OrderBy(static row => BandOrdinal(row.Source.OptionRatio)).ToArray();
      var legalBands = new CombatSupportOverloadLegalBand[3];
      var legalValueAliases = new List<ImportedOverloadLegalValueAlias>(15);
      for (var bandOrdinal = 0; bandOrdinal < orderedRows.Length; bandOrdinal++)
      {
        var row = orderedRows[bandOrdinal];
        var expectedProbability = bandOrdinal switch
        {
          0 => 6_000,
          1 => 3_500,
          2 => 500,
          _ => throw new CombatSupportCatalogSourceException("overload_band_ordinal_invalid")
        };
        if (row.Source.OptionRatio != expectedProbability)
        {
          throw new CombatSupportCatalogSourceException("overload_band_probability_invalid");
        }

        var values = row.Values.OrderBy(static value => value.Level)
            .Select(value => ToLegalValue(optionType, value))
            .ToArray();
        legalValueAliases.AddRange(row.Values.OrderBy(static value => value.Level)
            .Select(static value => new ImportedOverloadLegalValueAlias(
                value.SourceValueAlias,
                value.Level)));
        legalBands[bandOrdinal] = new CombatSupportOverloadLegalBand(
            bandOrdinal,
            new CombatSupportExactValue(expectedProbability, 4),
            values);
      }

      if (!legalBands.SelectMany(static band => band.OrderedValues)
              .Select(static value => value.RollLevel).SequenceEqual(Enumerable.Range(1, 15)) ||
          !legalValueAliases.Select(static value => value.RollLevel)
              .SequenceEqual(Enumerable.Range(1, 15)) ||
          legalValueAliases.Select(static value => value.SourceValueAlias).Distinct().Count() != 15)
      {
        throw new CombatSupportCatalogSourceException("overload_legal_level_coordinates_invalid");
      }

      var optionCode = CombatSupportCanonicalCodes.OverloadOptionType(optionType);
      result.Add(new ImportedCombatSupportDefinitionCandidate(
          SourceAliasFingerprintEncoder.Encode(
              identitySecret,
              SourceNamespace,
              "combat-support-overload-option-kind",
              optionCode),
          new ImportedOverloadOptionDefinitionPayload(
              CombatSupportFact<CombatSupportOverloadOptionType>.Ready(optionType),
              CombatSupportFact<CombatSupportValueUnit>.Ready(CombatSupportValueUnit.Ratio),
              new CombatSupportExactValue(kindWeights[0], 2),
              Array.AsReadOnly(legalBands),
              Array.AsReadOnly(legalValueAliases.ToArray()),
              CombatSupportFact<CombatSupportOverloadDuplicatePolicy>.Unresolved(
                  "overload_duplicate_policy_unresolved"),
              stateEffectReferencesValidated: true)));
    }

    if (kindWeightTotal != 100)
    {
      throw new CombatSupportCatalogSourceException("overload_kind_weight_total_invalid");
    }

    var allLegalValueAliases = result
        .Select(static item => (ImportedOverloadOptionDefinitionPayload)item.Payload)
        .SelectMany(static payload => payload.LegalValueAliases)
        .Select(static item => item.SourceValueAlias)
        .ToArray();
    if (allLegalValueAliases.Length != 135 || allLegalValueAliases.Distinct().Count() != 135)
    {
      throw new CombatSupportCatalogSourceException("overload_legal_value_alias_invalid");
    }

    Increment(diagnostics, "overload_duplicate_policy_unresolved", result.Count);
    return Array.AsReadOnly(result
        .OrderBy(static item => CombatSupportCanonicalCodes.DefinitionKind(item.Kind), StringComparer.Ordinal)
        .ThenBy(static item => item.AliasFingerprint.Hex, StringComparer.Ordinal)
        .ToArray());
  }

  private static IReadOnlyList<CombatSupportStatContribution> BuildContributions(
      IReadOnlyList<int[]> stats,
      CombatSupportFact<CombatSupportValueUnit> unit,
      IDictionary<string, int>? diagnostics = null)
  {
    var result = new List<CombatSupportStatContribution>(stats.Count);
    foreach (var row in stats)
    {
      if (row[0] == 0 && row[1] == 0)
      {
        continue;
      }

      if (row[0] == 0 || row[1] <= 0)
      {
        throw new CombatSupportCatalogSourceException("combat_stat_value_invalid");
      }

      var stat = MapStat(row[0]);
      if (stat.Status == CombatSupportFactStatus.Unresolved && diagnostics is not null)
      {
        Increment(diagnostics, "combat_stat_unknown");
      }

      result.Add(new CombatSupportStatContribution(
          result.Count,
          stat,
          unit,
          new CombatSupportExactValue(row[1], 0)));
    }

    return Array.AsReadOnly(result.ToArray());
  }

  private static IReadOnlyList<CombatSupportStatContribution> BuildEquipmentContributions(
      EquipmentRow row)
  {
    var result = BuildContributions(
        row.Stats,
        CombatSupportFact<CombatSupportValueUnit>.Ready(CombatSupportValueUnit.Absolute));
    var expected = row.Slot switch
    {
      1 or 2 => new[] { CombatSupportStat.Attack, CombatSupportStat.Hp },
      3 => new[] { CombatSupportStat.Attack, CombatSupportStat.Defence },
      4 => new[] { CombatSupportStat.Hp, CombatSupportStat.Defence },
      _ => throw new CombatSupportCatalogSourceException("equipment_slot_unknown")
    };
    if (result.Count != 2 ||
        result.Any(static item => item.Stat.Status != CombatSupportFactStatus.Ready) ||
        !result.Select(static item => item.Stat.RequireValue()).ToHashSet().SetEquals(expected))
    {
      throw new CombatSupportCatalogSourceException("equipment_stat_coordinates_invalid");
    }

    return result;
  }

  private static IReadOnlyList<CombatSupportEquipmentOptionSlot> BuildEquipmentOptionSlots(
      EquipmentRow row)
  {
    var expectedRatios = row.Tier == 10
        ? new[] { 10_000, 5_000, 3_000 }
        : new[] { 0, 0, 0 };
    if (row.OptionSlots.Length != 3 ||
        !row.OptionSlots.Select(static item => item[1]).SequenceEqual(expectedRatios) ||
        (row.Tier == 9 && row.OptionSlots.Any(static item => item[0] != 0)) ||
        (row.Tier == 10 &&
         (row.OptionSlots.Any(static item => item[0] <= 0) ||
          row.OptionSlots.Select(static item => item[0]).Distinct().Count() != 1)))
    {
      throw new CombatSupportCatalogSourceException("equipment_option_slot_coordinates_invalid");
    }

    return Array.AsReadOnly(row.OptionSlots.Select((item, index) =>
        new CombatSupportEquipmentOptionSlot(
            index,
            new CombatSupportExactValue(item[1], 4))).ToArray());
  }

  private static CombatSupportStatContribution Contribution(
      int ordinal,
      CombatSupportStat stat,
      int value) => new(
          ordinal,
          CombatSupportFact<CombatSupportStat>.Ready(stat),
          CombatSupportFact<CombatSupportValueUnit>.Ready(CombatSupportValueUnit.Absolute),
          new CombatSupportExactValue(value, 0));

  private static int[][] ReadObjectIntRows(MemoryPackReader reader, int memberCount)
  {
    var count = reader.ReadCollectionLength(allowNull: true, maximumLength: 16_384);
    if (count < 0)
    {
      throw new CombatSupportCatalogSourceException("memorypack_collection_invalid");
    }

    var result = new int[count][];
    for (var index = 0; index < count; index++)
    {
      reader.RequireObject(memberCount);
      result[index] = new int[memberCount];
      for (var field = 0; field < memberCount; field++)
      {
        result[index][field] = reader.ReadInt32();
      }
    }

    return result;
  }

  private static int[] ReadSingleIntObjectList(MemoryPackReader reader) =>
      ReadObjectIntRows(reader, 1).Select(static row => row[0]).ToArray();

  private static CombatSupportEquipmentSlot MapEquipmentSlot(int value) => value switch
  {
    1 => CombatSupportEquipmentSlot.Head,
    2 => CombatSupportEquipmentSlot.Torso,
    3 => CombatSupportEquipmentSlot.Arms,
    4 => CombatSupportEquipmentSlot.Legs,
    _ => throw new CombatSupportCatalogSourceException("equipment_slot_unknown")
  };

  private static CombatSupportCombatRole MapCombatRole(int value) => value switch
  {
    1 => CombatSupportCombatRole.Attacker,
    2 => CombatSupportCombatRole.Defender,
    3 => CombatSupportCombatRole.Supporter,
    _ => throw new CombatSupportCatalogSourceException("equipment_combat_role_unknown")
  };

  private static CombatSupportFact<CombatSupportCombatRole> MapOptionalCombatRole(int value)
  {
    if (value == 4)
    {
      return CombatSupportFact<CombatSupportCombatRole>.NotApplicable();
    }

    if (value is >= 1 and <= 3)
    {
      return CombatSupportFact<CombatSupportCombatRole>.Ready(MapCombatRole(value));
    }

    throw new CombatSupportCatalogSourceException("cube_combat_role_unknown");
  }

  private static CombatSupportFact<CombatSupportRarity> MapRarity(int value) => value switch
  {
    1 => CombatSupportFact<CombatSupportRarity>.Ready(CombatSupportRarity.R),
    2 => CombatSupportFact<CombatSupportRarity>.Ready(CombatSupportRarity.Sr),
    3 => CombatSupportFact<CombatSupportRarity>.Ready(CombatSupportRarity.Ssr),
    _ => throw new CombatSupportCatalogSourceException("combat_support_rarity_unknown")
  };

  private static CombatSupportFact<CombatSupportWeaponClass> MapWeaponClass(
      int value,
      IDictionary<string, int> diagnostics)
  {
    var result = value switch
    {
      1 => CombatSupportFact<CombatSupportWeaponClass>.Ready(CombatSupportWeaponClass.AssaultRifle),
      2 => CombatSupportFact<CombatSupportWeaponClass>.Ready(CombatSupportWeaponClass.RocketLauncher),
      3 => CombatSupportFact<CombatSupportWeaponClass>.Ready(CombatSupportWeaponClass.SniperRifle),
      4 => CombatSupportFact<CombatSupportWeaponClass>.Ready(CombatSupportWeaponClass.MachineGun),
      5 => CombatSupportFact<CombatSupportWeaponClass>.Ready(CombatSupportWeaponClass.Shotgun),
      9 => CombatSupportFact<CombatSupportWeaponClass>.Ready(CombatSupportWeaponClass.SubmachineGun),
      _ => CombatSupportFact<CombatSupportWeaponClass>.Unresolved("collection_weapon_class_unknown")
    };
    if (result.Status == CombatSupportFactStatus.Unresolved)
    {
      Increment(diagnostics, "collection_weapon_class_unknown");
    }

    return result;
  }

  private static CombatSupportFact<CombatSupportStat> MapStat(int value) => value switch
  {
    1 => CombatSupportFact<CombatSupportStat>.Ready(CombatSupportStat.Attack),
    2 => CombatSupportFact<CombatSupportStat>.Ready(CombatSupportStat.Hp),
    3 => CombatSupportFact<CombatSupportStat>.Ready(CombatSupportStat.Defence),
    4 => CombatSupportFact<CombatSupportStat>.Ready(CombatSupportStat.EnergyResistance),
    5 => CombatSupportFact<CombatSupportStat>.Ready(CombatSupportStat.MetalResistance),
    6 => CombatSupportFact<CombatSupportStat>.Ready(CombatSupportStat.BioResistance),
    _ => CombatSupportFact<CombatSupportStat>.Unresolved("combat_stat_unknown")
  };

  private static int BandOrdinal(int probability) => probability switch
  {
    6_000 => 0,
    3_500 => 1,
    500 => 2,
    _ => throw new CombatSupportCatalogSourceException("overload_band_probability_invalid")
  };

  private static CombatSupportOverloadOptionType MapOverloadOptionType(int value) => value switch
  {
    1 => CombatSupportOverloadOptionType.Attack,
    15 => CombatSupportOverloadOptionType.Defence,
    108 => CombatSupportOverloadOptionType.MaximumAmmunition,
    11 => CombatSupportOverloadOptionType.ChargeDamage,
    61 => CombatSupportOverloadOptionType.ChargeSpeed,
    9 => CombatSupportOverloadOptionType.CriticalRate,
    51 => CombatSupportOverloadOptionType.CriticalDamage,
    80 => CombatSupportOverloadOptionType.ElementalDamage,
    8 => CombatSupportOverloadOptionType.HitRate,
    _ => throw new CombatSupportCatalogSourceException("overload_function_kind_unknown")
  };

  private static int ExpectedOverloadKindWeight(CombatSupportOverloadOptionType optionType) => optionType switch
  {
    CombatSupportOverloadOptionType.Attack or
    CombatSupportOverloadOptionType.Defence or
    CombatSupportOverloadOptionType.CriticalDamage or
    CombatSupportOverloadOptionType.ElementalDamage => 10,
    CombatSupportOverloadOptionType.MaximumAmmunition or
    CombatSupportOverloadOptionType.ChargeDamage or
    CombatSupportOverloadOptionType.ChargeSpeed or
    CombatSupportOverloadOptionType.CriticalRate or
    CombatSupportOverloadOptionType.HitRate => 12,
    _ => throw new ArgumentOutOfRangeException(nameof(optionType))
  };

  private static CombatSupportOverloadLegalValue ToLegalValue(
      CombatSupportOverloadOptionType optionType,
      ResolvedOverloadValue value)
  {
    var expectsNegativeSource = optionType is
        CombatSupportOverloadOptionType.ChargeSpeed or CombatSupportOverloadOptionType.HitRate;
    if ((expectsNegativeSource && value.FunctionValue >= 0) ||
        (!expectsNegativeSource && value.FunctionValue <= 0) ||
        value.FunctionValue == long.MinValue ||
        Math.Abs(value.FunctionValue) > int.MaxValue)
    {
      throw new CombatSupportCatalogSourceException("overload_function_value_invalid");
    }

    var magnitude = (int)Math.Abs(value.FunctionValue);
    return new CombatSupportOverloadLegalValue(
        value.Level,
        value.FunctionValue,
        magnitude,
        new CombatSupportExactValue(magnitude, 4));
  }

  private static CombatSupportConsoleCoordinate MapConsoleCoordinate(int type, int subtype) =>
      (type, subtype) switch
      {
        (1, 1) => CombatSupportConsoleCoordinate.Common,
        (2, 2) => CombatSupportConsoleCoordinate.Attacker,
        (2, 3) => CombatSupportConsoleCoordinate.Defender,
        (2, 4) => CombatSupportConsoleCoordinate.Supporter,
        (3, 5) => CombatSupportConsoleCoordinate.Elysion,
        (3, 6) => CombatSupportConsoleCoordinate.Missilis,
        (3, 7) => CombatSupportConsoleCoordinate.Tetra,
        (3, 8) => CombatSupportConsoleCoordinate.Pilgrim,
        (3, 9) => CombatSupportConsoleCoordinate.Abnormal,
        _ => throw new CombatSupportCatalogSourceException("console_coordinate_unknown")
      };

  private static SourceAliasFingerprint Alias(
      ReadOnlySpan<byte> identitySecret,
      string entityKind,
      int sourceIdentifier) => SourceAliasFingerprintEncoder.Encode(
          identitySecret,
          SourceNamespace,
          entityKind,
          sourceIdentifier.ToString(CultureInfo.InvariantCulture));

  private static void Increment(IDictionary<string, int> diagnostics, string code, int count = 1)
  {
    diagnostics.TryGetValue(code, out var existing);
    diagnostics[code] = checked(existing + count);
  }

  private sealed record CharacterAliasRow(
      int ResourceId,
      int NameCode,
      int GradeCoreId,
      bool IsVisible,
      bool IsDetailClose);

  private sealed record EquipmentRow(
      int Id,
      int Slot,
      int CombatRole,
      int Tier,
      int GradeCoreId,
      int GrowGrade,
      int[][] Stats,
      int[][] OptionSlots);

  private sealed record EquipmentExperienceRow(int Tier, int GradeCoreId, int Level);

  private sealed record GradeCoreEquipmentRow(int Grade, int MaximumLevel);

  private sealed record CubeRow(
      int Id,
      int Rarity,
      int CombatRole,
      int LevelEnhanceId);

  private sealed record CubeLevelRow(
      int GroupId,
      int Level,
      int[] SkillLevels,
      int Capacity,
      int[][] Stats);

  private sealed record FavoriteItemRow(
      int Id,
      int Rarity,
      int FavoriteType,
      int Weapon,
      int NameCode,
      int MaximumLevel,
      int LevelEnhanceId);

  private sealed record FavoriteLevelRow(
      int GroupId,
      int Grade,
      int Level,
      int[][] Stats,
      int[] SkillLevels);

  private sealed record ConsoleStatRow(
      int Id,
      int Type,
      int Subtype,
      int Attack,
      int Defence,
      int Hp);

  private sealed record ConsoleLevelRow(
      int Type,
      int Subtype,
      int Level,
      int MinimumSynchroLevel);

  private sealed record StateEffectRow(int[] FunctionIds);

  private sealed record FunctionRow(int Level, int FunctionType, long FunctionValue);

  private sealed record EquipmentOptionRow(
      int Id,
      int OptionGroupId,
      int OptionGroupRatio,
      int StateEffectGroupId,
      int OptionRatio,
      int[][] StateEffects);

  private sealed record ResolvedOverloadValue(
      SourceAliasFingerprint SourceValueAlias,
      int Level,
      int FunctionType,
      long FunctionValue);

  private sealed record ResolvedEquipmentOptionRow(
      EquipmentOptionRow Source,
      ResolvedOverloadValue[] Values);
}
