using System.Globalization;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Import.CharacterCatalog;

public sealed class StaticDataCharacterCatalogReader
{
  private static readonly ZipArchiveLimits ArchiveLimits = new(
      MaximumEntryCount: 20_000,
      MaximumEntryBytes: 32 * 1024 * 1024,
      MaximumTotalBytes: 512L * 1024 * 1024,
      MaximumCompressionRatio: 100m);

  private static readonly string[] RequiredEntries =
  [
      "AttractiveLevelTable.mpk",
    "CharacterLevelTable.mpk",
    "CharacterShotTable.mpk",
    "CharacterTable.mpk",
    "FavoriteItemLevelTable.mpk",
    "FavoriteItemTable.mpk",
    "GradeCoreTable.mpk",
    "ItemEquipExpTable.mpk",
    "ItemEquipTable.mpk",
    "ItemHarmonyCubeLevelTable.mpk",
    "ItemHarmonyCubeTable.mpk",
    "SkillInfoTable.mpk"
  ];

  public CharacterCatalogExtraction Read(
      Stream staticDataArchive,
      ReadOnlySpan<byte> identitySecret,
      CharacterCatalogRuntimeCaps runtimeCaps)
  {
    ArgumentNullException.ThrowIfNull(staticDataArchive);
    if (!staticDataArchive.CanRead || !staticDataArchive.CanSeek)
    {
      throw new CharacterCatalogSourceException("archive_stream_invalid");
    }

    if (staticDataArchive.Length is <= 0 or > 64L * 1024 * 1024)
    {
      throw new CharacterCatalogSourceException("archive_size_invalid");
    }

    if (identitySecret.Length < 32)
    {
      throw new CharacterCatalogSourceException("identity_secret_invalid");
    }

    ArgumentNullException.ThrowIfNull(runtimeCaps);

    try
    {
      using var archive = new ZipArchive(staticDataArchive, ZipArchiveMode.Read, leaveOpen: true);
      var validatedArchiveEntries = ZipArchiveGuard.Validate(archive, ArchiveLimits);
      var entries = RequiredEntries.ToDictionary(
          name => name,
          name => ReadSingleEntry(validatedArchiveEntries, name),
          StringComparer.Ordinal);

      var characters = ReadCharacters(entries["CharacterTable.mpk"]);
      var shots = ReadShots(entries["CharacterShotTable.mpk"]);
      var characterLevelMaximum = ReadCharacterLevelMaximum(entries["CharacterLevelTable.mpk"]);
      var skillLevels = ReadSkillLevels(entries["SkillInfoTable.mpk"]);
      var attractiveMaximum = ReadAttractiveMaximum(entries["AttractiveLevelTable.mpk"]);
      var favoriteItems = ReadFavoriteItems(entries["FavoriteItemTable.mpk"]);
      var favoriteItemLevels = ReadFavoriteItemLevels(entries["FavoriteItemLevelTable.mpk"]);
      ValidateFavoriteItemCatalog(characters, favoriteItems, favoriteItemLevels);
      var gradeCoreRows = ReadGradeCore(entries["GradeCoreTable.mpk"]);
      var equipmentMaximums = ValidateEquipmentCatalog(
          ReadEquipment(entries["ItemEquipTable.mpk"]),
          ReadEquipmentExperience(entries["ItemEquipExpTable.mpk"]));
      var cubeGroups = ReadCubes(entries["ItemHarmonyCubeTable.mpk"]);
      var cubeLevelMaximums = ReadCubeLevelMaximums(entries["ItemHarmonyCubeLevelTable.mpk"]);

      var diagnostics = new Dictionary<string, int>(StringComparer.Ordinal);
      var cubeMaximum = ResolveCubeMaximum(cubeGroups, cubeLevelMaximums, skillLevels, diagnostics);
      var result = new List<ImportedCharacterDefinitionCandidate>();

      foreach (var group in characters
                   .Where(character => character.IsVisible && !character.IsDetailClose)
                   .GroupBy(character => character.NameCode)
                   .OrderBy(group => group.Key))
      {
        if (group.Key <= 0)
        {
          throw new CharacterCatalogSourceException("character_name_code_invalid");
        }

        var rows = group.OrderBy(row => row.GradeCoreId).ToArray();
        var first = rows[0];
        var alias = SourceAliasFingerprintEncoder.Encode(
            identitySecret,
            "nikke-staticdata",
            "character-resource",
            group.Key.ToString(CultureInfo.InvariantCulture));

        var consistency = rows.All(row =>
            row.ResourceId == first.ResourceId &&
            row.NameCode == first.NameCode &&
            row.OriginalRare == first.OriginalRare &&
            row.StatEnhanceId == first.StatEnhanceId &&
            row.CharacterClass == first.CharacterClass &&
            row.Corporation == first.Corporation &&
            row.CorporationSubtype == first.CorporationSubtype &&
            row.ShotId == first.ShotId &&
            row.Skill1Id == first.Skill1Id &&
            row.Skill1Table == first.Skill1Table &&
            row.Skill2Id == first.Skill2Id &&
            row.Skill2Table == first.Skill2Table &&
            row.UltimateSkillId == first.UltimateSkillId &&
            row.ElementIds.SequenceEqual(first.ElementIds));

        if (!consistency)
        {
          Increment(diagnostics, "character_variant_conflict");
          continue;
        }

        var progression = ResolveProgression(
            first.OriginalRare,
            rows.Select(row => row.GradeCoreId),
            gradeCoreRows,
            runtimeCaps.ForCorporationSubtype(first.CorporationSubtype));
        if (!progression.IsReady)
        {
          Increment(diagnostics, "character_progression_unresolved");
        }

        var weapon = shots.TryGetValue(first.ShotId, out var weaponValue)
            ? ResolveWeapon(weaponValue)
            : ImportedCodeFact.Unresolved("weapon_reference_missing");
        if (weapon.Status != ImportedFactStatus.Ready)
        {
          Increment(diagnostics, "character_weapon_unresolved");
        }

        var maximumBond = progression.MaximumBond.Status == ImportedFactStatus.Ready &&
                          attractiveMaximum >= progression.MaximumBond.Value
            ? progression.MaximumBond
            : ImportedIntegerFact.Unresolved("bond_maximum_missing");
        var maximumSkill1 = ResolveSkillMaximum(first.Skill1Id, skillLevels, diagnostics);
        var maximumSkill2 = ResolveSkillMaximum(first.Skill2Id, skillLevels, diagnostics);
        var maximumBurst = ResolveSkillMaximum(first.UltimateSkillId, skillLevels, diagnostics);

        var collectionMaximum = ResolveCollectionMaximum(weapon, favoriteItems);
        var favoriteMaximum = ResolveFavoriteMaximum(first.NameCode, favoriteItems);
        result.Add(new ImportedCharacterDefinitionCandidate(
            alias,
            ResolveRarity(first.OriginalRare),
            ResolveClass(first.CharacterClass),
            weapon,
            ResolveElement(first.ElementIds),
            ResolveManufacturer(first.Corporation),
            ImportedIntegerFact.Ready(characterLevelMaximum),
            progression.MaximumLimitBreak,
            progression.MaximumCore,
            maximumBond,
            maximumSkill1,
            maximumSkill2,
            maximumBurst,
            ImportedIntegerFact.Ready(equipmentMaximums.MaximumTier),
            ImportedIntegerFact.Ready(equipmentMaximums.MaximumEnhancementLevel),
            cubeMaximum,
            collectionMaximum,
            favoriteMaximum));
      }

      if (result.Count == 0)
      {
        throw new CharacterCatalogSourceException("character_catalog_empty");
      }

      var ordered = result.OrderBy(item => item.AliasFingerprint.Hex, StringComparer.Ordinal).ToArray();
      var canonicalBytes = EncodeCanonicalCandidates(ordered);
      try
      {
        return new CharacterCatalogExtraction(
            ordered,
            diagnostics.OrderBy(item => item.Key, StringComparer.Ordinal)
                .Select(item => new CharacterCatalogDiagnostic(item.Key, item.Value))
                .ToArray(),
            Sha256Digest.Compute(canonicalBytes));
      }
      finally
      {
        CryptographicOperations.ZeroMemory(canonicalBytes);
      }
    }
    catch (CharacterCatalogSourceException)
    {
      throw;
    }
    catch (Exception exception) when (exception is InvalidDataException or IOException)
    {
      throw new CharacterCatalogSourceException("archive_invalid");
    }
  }

  private static byte[] ReadSingleEntry(
      IReadOnlyList<ZipArchiveEntry> archiveEntries,
      string requiredName)
  {
    var matches = archiveEntries
        .Where(entry => string.Equals(ZipArchiveGuard.FileName(entry), requiredName, StringComparison.Ordinal))
        .ToArray();
    if (matches.Length != 1)
    {
      throw new CharacterCatalogSourceException("archive_entry_invalid");
    }

    return ZipArchiveGuard.ReadExactly(matches[0]);
  }

  private static IReadOnlyList<CharacterRow> ReadCharacters(byte[] bytes)
  {
    var reader = new MemoryPackReader(bytes);
    var count = reader.ReadCollectionLength();
    var rows = new CharacterRow[count];
    var identifiers = new HashSet<int>();
    for (var index = 0; index < count; index++)
    {
      reader.RequireObject(40);
      var id = reader.ReadInt32();
      if (id <= 0 || !identifiers.Add(id))
      {
        throw new CharacterCatalogSourceException("character_identifier_invalid");
      }

      _ = reader.ReadString();
      _ = reader.ReadString();
      var resourceId = reader.ReadInt32();
      _ = reader.ReadStringArray();
      var nameCode = reader.ReadInt32();
      _ = reader.ReadInt32();
      var originalRare = reader.ReadInt32();
      var gradeCoreId = reader.ReadInt32();
      _ = reader.ReadInt32();
      var statEnhanceId = reader.ReadInt32();
      var corporation = reader.ReadInt32();
      var corporationSubtype = reader.ReadInt32();
      var characterClass = reader.ReadInt32();
      var elementIds = reader.ReadInt32Array() ?? [];
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      var shotId = reader.ReadInt32();
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      var ultimateSkillId = reader.ReadInt32();
      var skill1Id = reader.ReadInt32();
      var skill1Table = reader.ReadInt32();
      var skill2Id = reader.ReadInt32();
      var skill2Table = reader.ReadInt32();
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      _ = reader.ReadString();
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      var isVisible = reader.ReadBoolean();
      _ = reader.ReadBoolean();
      var isDetailClose = reader.ReadBoolean();
      rows[index] = new CharacterRow(
          resourceId,
          nameCode,
          originalRare,
          gradeCoreId,
          statEnhanceId,
          corporation,
          corporationSubtype,
          characterClass,
          elementIds,
          shotId,
          skill1Id,
          skill1Table,
          skill2Id,
          skill2Table,
          ultimateSkillId,
          isVisible,
          isDetailClose);
    }

    reader.EnsureEnd();
    return rows;
  }

  private static IReadOnlyDictionary<int, int> ReadShots(byte[] bytes)
  {
    var reader = new MemoryPackReader(bytes);
    var count = reader.ReadCollectionLength();
    var result = new Dictionary<int, int>();
    for (var index = 0; index < count; index++)
    {
      reader.RequireObject(58);
      var id = reader.ReadInt32();
      if (id <= 0)
      {
        throw new CharacterCatalogSourceException("shot_identifier_invalid");
      }

      _ = reader.ReadString();
      _ = reader.ReadString();
      _ = reader.ReadString();
      var weapon = reader.ReadInt32();
      for (var field = 5; field <= 49; field++)
      {
        _ = field == 9 ? reader.ReadBoolean() ? 1 : 0 : reader.ReadInt32();
      }

      _ = reader.ReadString();
      _ = reader.ReadInt32();
      _ = reader.ReadInt32Array();
      _ = reader.ReadInt32Array();
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      _ = reader.ReadString();
      if (!result.TryAdd(id, weapon))
      {
        throw new CharacterCatalogSourceException("shot_identifier_duplicate");
      }
    }

    reader.EnsureEnd();
    return result;
  }

  private static SkillLevelIndex ReadSkillLevels(byte[] bytes)
  {
    var reader = new MemoryPackReader(bytes);
    var count = reader.ReadCollectionLength();
    var groupByRecordIdentifier = new Dictionary<int, int>();
    var maximumLevelByGroup = new Dictionary<int, int>();
    var groupLevels = new HashSet<(int GroupId, int Level)>();
    for (var index = 0; index < count; index++)
    {
      reader.RequireObject(10);
      var id = reader.ReadInt32();
      var groupId = reader.ReadInt32();
      var skillLevel = reader.ReadInt32();
      if (id <= 0 || groupId <= 0 || skillLevel <= 0 ||
          !groupByRecordIdentifier.TryAdd(id, groupId) || !groupLevels.Add((groupId, skillLevel)))
      {
        throw new CharacterCatalogSourceException("skill_identifier_invalid");
      }

      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      _ = reader.ReadString();
      _ = reader.ReadString();
      _ = reader.ReadString();
      _ = reader.ReadString();
      var descriptionCount = reader.ReadCollectionLength(allowNull: true, maximumLength: 16_384);
      for (var description = 0; description < Math.Max(descriptionCount, 0); description++)
      {
        reader.RequireObject(1);
        _ = reader.ReadString();
      }

      maximumLevelByGroup[groupId] = Math.Max(
          maximumLevelByGroup.GetValueOrDefault(groupId),
          skillLevel);
    }

    reader.EnsureEnd();
    return new SkillLevelIndex(groupByRecordIdentifier, maximumLevelByGroup);
  }

  private static int ReadAttractiveMaximum(byte[] bytes)
  {
    var reader = new MemoryPackReader(bytes);
    var count = reader.ReadCollectionLength();
    var maximum = 0;
    var identifiers = new HashSet<int>();
    var levels = new HashSet<int>();
    for (var index = 0; index < count; index++)
    {
      reader.RequireObject(21);
      var id = reader.ReadInt32();
      var level = reader.ReadInt32();
      if (id <= 0 || !identifiers.Add(id))
      {
        throw new CharacterCatalogSourceException("attractive_identifier_invalid");
      }

      if (level <= 0 || !levels.Add(level))
      {
        throw new CharacterCatalogSourceException("attractive_level_coordinates_invalid");
      }

      maximum = Math.Max(maximum, level);
      for (var field = 2; field < 21; field++)
      {
        _ = reader.ReadInt32();
      }
    }

    reader.EnsureEnd();
    if (maximum <= 0 ||
        !levels.Order().SequenceEqual(Enumerable.Range(1, maximum)))
    {
      throw new CharacterCatalogSourceException("attractive_level_coordinates_invalid");
    }

    return maximum;
  }

  private static int ReadCharacterLevelMaximum(byte[] bytes)
  {
    var reader = new MemoryPackReader(bytes);
    var count = reader.ReadCollectionLength();
    var maximum = 0;
    var levels = new HashSet<int>();
    for (var index = 0; index < count; index++)
    {
      reader.RequireObject(6);
      var level = reader.ReadInt32();
      if (level <= 0 || !levels.Add(level))
      {
        throw new CharacterCatalogSourceException("character_level_identifier_invalid");
      }

      maximum = Math.Max(maximum, level);
      for (var field = 1; field < 6; field++)
      {
        _ = reader.ReadInt32();
      }
    }

    reader.EnsureEnd();
    if (maximum <= 0 || !levels.Order().SequenceEqual(Enumerable.Range(1, maximum)))
    {
      throw new CharacterCatalogSourceException("character_level_maximum_missing");
    }

    return maximum;
  }

  private static IReadOnlyList<FavoriteItemRow> ReadFavoriteItems(byte[] bytes)
  {
    var reader = new MemoryPackReader(bytes);
    var count = reader.ReadCollectionLength();
    var result = new FavoriteItemRow[count];
    var identifiers = new HashSet<int>();
    for (var index = 0; index < count; index++)
    {
      reader.RequireObject(17);
      var id = reader.ReadInt32();
      if (id <= 0 || !identifiers.Add(id))
      {
        throw new CharacterCatalogSourceException("favorite_item_identifier_invalid");
      }

      for (var field = 0; field < 5; field++)
      {
        _ = reader.ReadString();
      }

      _ = reader.ReadInt32();
      var favoriteRarity = reader.ReadInt32();
      var favoriteType = reader.ReadInt32();
      var weapon = reader.ReadInt32();
      var nameCode = reader.ReadInt32();
      var maximumLevel = reader.ReadInt32();
      var levelEnhanceId = reader.ReadInt32();
      _ = reader.ReadInt32();
      var collectionSkillCount = ReadObjectIntList(reader, 1);
      var favoriteSkillCount = ReadObjectIntList(reader, 3);
      _ = reader.ReadInt32();
      var typeIsValid = favoriteType switch
      {
        1 => favoriteRarity is 1 or 2 && nameCode == 0,
        2 => favoriteRarity == 3 && nameCode > 0,
        _ => false
      };
      if (weapon <= 0 ||
          maximumLevel <= 0 ||
          levelEnhanceId <= 0 ||
          collectionSkillCount != 2 ||
          favoriteSkillCount != 3 ||
          !typeIsValid)
      {
        throw new CharacterCatalogSourceException("favorite_item_value_invalid");
      }

      result[index] = new FavoriteItemRow(
          id,
          favoriteType,
          favoriteRarity,
          weapon,
          nameCode,
          maximumLevel,
          levelEnhanceId);
    }

    reader.EnsureEnd();
    return result;
  }

  private static IReadOnlyList<FavoriteItemLevelRow> ReadFavoriteItemLevels(byte[] bytes)
  {
    var reader = new MemoryPackReader(bytes);
    var count = reader.ReadCollectionLength();
    var result = new FavoriteItemLevelRow[count];
    var identifiers = new HashSet<int>();
    var coordinates = new HashSet<(int EnhanceId, int Grade, int Level)>();
    for (var index = 0; index < count; index++)
    {
      reader.RequireObject(6);
      var id = reader.ReadInt32();
      var levelEnhanceId = reader.ReadInt32();
      var grade = reader.ReadInt32();
      var level = reader.ReadInt32();
      var statCount = ReadObjectIntList(reader, 2);
      var skillLevelCount = ReadObjectIntList(reader, 1);
      if (id <= 0 ||
          levelEnhanceId <= 0 ||
          grade < 0 ||
          level < 0 ||
          statCount != 3 ||
          skillLevelCount != 2 ||
          !identifiers.Add(id) ||
          !coordinates.Add((levelEnhanceId, grade, level)))
      {
        throw new CharacterCatalogSourceException("favorite_level_coordinate_invalid");
      }

      result[index] = new FavoriteItemLevelRow(id, levelEnhanceId, grade, level);
    }

    reader.EnsureEnd();
    return result;
  }

  private static void ValidateFavoriteItemCatalog(
      IReadOnlyList<CharacterRow> characters,
      IReadOnlyList<FavoriteItemRow> items,
      IReadOnlyList<FavoriteItemLevelRow> levels)
  {
    var visibleCharacterNameCodes = characters
        .Where(character => character.IsVisible && !character.IsDetailClose && character.NameCode > 0)
        .Select(character => character.NameCode)
        .ToHashSet();
    var favorites = items.Where(item => item.FavoriteType == 2).ToArray();
    if (items.Count == 0 ||
        items.Select(item => item.LevelEnhanceId).Distinct().Count() != items.Count ||
        items.GroupBy(item => (item.FavoriteType, item.FavoriteRarity, item.Weapon, item.NameCode))
            .Any(group => group.Count() != 1) ||
        favorites.GroupBy(item => item.NameCode).Any(group => group.Count() != 1) ||
        favorites.Any(item => !visibleCharacterNameCodes.Contains(item.NameCode)))
    {
      throw new CharacterCatalogSourceException("favorite_level_fk_invalid");
    }

    var groups = levels.GroupBy(level => level.LevelEnhanceId)
        .ToDictionary(group => group.Key, group => group.ToArray());
    var expectedGroupIds = items.Select(item => item.LevelEnhanceId).ToHashSet();
    if (!expectedGroupIds.SetEquals(groups.Keys))
    {
      throw new CharacterCatalogSourceException("favorite_level_fk_invalid");
    }

    foreach (var item in items)
    {
      var group = groups[item.LevelEnhanceId];
      var expectedLevels = Enumerable.Range(0, checked(item.MaximumLevel + 1));
      if (item.MaximumLevel != group.Max(row => row.Level) ||
          !group.Select(row => row.Level).Order().SequenceEqual(expectedLevels))
      {
        throw new CharacterCatalogSourceException("favorite_level_coordinates_invalid");
      }
    }
  }

  private static IReadOnlyList<EquipmentRow> ReadEquipment(byte[] bytes)
  {
    var reader = new MemoryPackReader(bytes);
    var count = reader.ReadCollectionLength();
    var result = new EquipmentRow[count];
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
      var characterClass = reader.ReadInt32();
      var tier = reader.ReadInt32();
      var gradeCoreId = reader.ReadInt32();
      var growGrade = reader.ReadInt32();
      var statCount = ReadObjectIntList(reader, 2);
      var optionSlotCount = ReadObjectIntList(reader, 2);
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      if (id <= 0 ||
          slot <= 0 ||
          characterClass <= 0 ||
          tier <= 0 ||
          gradeCoreId <= 0 ||
          growGrade < 0 ||
          statCount != 6 ||
          optionSlotCount != 3 ||
          !identifiers.Add(id))
      {
        throw new CharacterCatalogSourceException("equipment_value_invalid");
      }

      result[index] = new EquipmentRow(id, slot, characterClass, tier, gradeCoreId, growGrade);
    }

    reader.EnsureEnd();
    return result;
  }

  private static IReadOnlyList<EquipmentExperienceRow> ReadEquipmentExperience(byte[] bytes)
  {
    var reader = new MemoryPackReader(bytes);
    var count = reader.ReadCollectionLength();
    var result = new EquipmentExperienceRow[count];
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
      if (id <= 0 ||
          tier <= 0 ||
          gradeCoreId <= 0 ||
          level < 0 ||
          experience < 0 ||
          !identifiers.Add(id) ||
          !coordinates.Add((tier, gradeCoreId, level)))
      {
        throw new CharacterCatalogSourceException("equipment_exp_coordinate_invalid");
      }

      result[index] = new EquipmentExperienceRow(id, tier, gradeCoreId, level);
    }

    reader.EnsureEnd();
    return result;
  }

  private static EquipmentMaximums ValidateEquipmentCatalog(
      IReadOnlyList<EquipmentRow> equipment,
      IReadOnlyList<EquipmentExperienceRow> experience)
  {
    var tierTen = equipment.Where(row => row.Tier == 10).ToArray();
    var coordinates = tierTen.GroupBy(row => (row.CharacterClass, row.Slot)).ToArray();
    var expectedCoordinates =
        (from characterClass in Enumerable.Range(1, 3)
         from slot in Enumerable.Range(1, 4)
         select (CharacterClass: characterClass, Slot: slot)).ToHashSet();
    if (tierTen.Length != 12 ||
        coordinates.Any(group => group.Count() != 1) ||
        !expectedCoordinates.SetEquals(coordinates.Select(group => group.Key)) ||
        tierTen.Any(row => row.GrowGrade != 0))
    {
      throw new CharacterCatalogSourceException("equipment_tier_ten_coordinates_invalid");
    }

    foreach (var gradeCoreId in tierTen.Select(row => row.GradeCoreId).Distinct())
    {
      var levels = experience
          .Where(row => row.Tier == 10 && row.GradeCoreId == gradeCoreId)
          .Select(row => row.Level)
          .Order()
          .ToArray();
      if (!levels.SequenceEqual(Enumerable.Range(0, 6)))
      {
        throw new CharacterCatalogSourceException("equipment_exp_fk_invalid");
      }
    }

    return new EquipmentMaximums(10, 5);
  }

  private static IReadOnlyDictionary<int, GradeCoreRow> ReadGradeCore(byte[] bytes)
  {
    var reader = new MemoryPackReader(bytes);
    var count = reader.ReadCollectionLength();
    var result = new Dictionary<int, GradeCoreRow>();
    var coordinates = new HashSet<(int Rarity, int Grade, int Core)>();
    for (var index = 0; index < count; index++)
    {
      reader.RequireObject(7);
      var id = reader.ReadInt32();
      var rarity = reader.ReadInt32();
      var grade = reader.ReadInt32();
      var core = reader.ReadInt32();
      _ = reader.ReadInt32();
      var pieceValue = reader.ReadInt32();
      var maximumBond = reader.ReadInt32();
      if (id <= 0 ||
          rarity <= 0 ||
          grade < 0 ||
          core < 0 ||
          pieceValue < 0 ||
          maximumBond < 0 ||
          !coordinates.Add((rarity, grade, core)))
      {
        throw new CharacterCatalogSourceException("grade_core_value_invalid");
      }

      if (!result.TryAdd(id, new GradeCoreRow(id, rarity, grade, core, pieceValue, maximumBond)))
      {
        throw new CharacterCatalogSourceException("grade_core_identifier_duplicate");
      }
    }

    reader.EnsureEnd();
    return result;
  }

  private static IReadOnlyList<CubeRow> ReadCubes(byte[] bytes)
  {
    var reader = new MemoryPackReader(bytes);
    var count = reader.ReadCollectionLength();
    var result = new CubeRow[count];
    var identifiers = new HashSet<int>();
    for (var index = 0; index < count; index++)
    {
      reader.RequireObject(15);
      var id = reader.ReadInt32();
      if (id <= 0 || !identifiers.Add(id))
      {
        throw new CharacterCatalogSourceException("cube_identifier_invalid");
      }

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
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      var levelEnhanceId = reader.ReadInt32();
      if (levelEnhanceId <= 0)
      {
        throw new CharacterCatalogSourceException("cube_level_reference_invalid");
      }

      var skillGroupIds = ReadSingleIntObjectList(reader);
      result[index] = new CubeRow(levelEnhanceId, skillGroupIds);
    }

    reader.EnsureEnd();
    return result;
  }

  private static IReadOnlyDictionary<int, IReadOnlySet<int>> ReadCubeLevelMaximums(byte[] bytes)
  {
    var reader = new MemoryPackReader(bytes);
    var count = reader.ReadCollectionLength();
    var result = new Dictionary<int, HashSet<int>>();
    var identifiers = new HashSet<int>();
    var groupLevels = new HashSet<(int GroupId, int Level)>();
    for (var index = 0; index < count; index++)
    {
      reader.RequireObject(9);
      var id = reader.ReadInt32();
      var groupId = reader.ReadInt32();
      var level = reader.ReadInt32();
      if (id <= 0 || groupId <= 0 || level <= 0 ||
          !identifiers.Add(id) || !groupLevels.Add((groupId, level)))
      {
        throw new CharacterCatalogSourceException("cube_level_identifier_invalid");
      }

      var skillLevelCount = ReadObjectIntList(reader, 1);
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      _ = reader.ReadInt32();
      var statCount = ReadObjectIntList(reader, 2);
      if (skillLevelCount != 3 || statCount != 3)
      {
        throw new CharacterCatalogSourceException("cube_level_vector_invalid");
      }

      if (!result.TryGetValue(groupId, out var levels))
      {
        levels = [];
        result.Add(groupId, levels);
      }

      levels.Add(level);
    }

    reader.EnsureEnd();
    return result.ToDictionary(
        pair => pair.Key,
        pair => (IReadOnlySet<int>)pair.Value);
  }

  private static int ReadObjectIntList(MemoryPackReader reader, int memberCount)
  {
    var count = reader.ReadCollectionLength(allowNull: true, maximumLength: 16_384);
    for (var item = 0; item < Math.Max(count, 0); item++)
    {
      reader.RequireObject(memberCount);
      for (var field = 0; field < memberCount; field++)
      {
        _ = reader.ReadInt32();
      }
    }

    return count;
  }

  private static int[] ReadSingleIntObjectList(MemoryPackReader reader)
  {
    var count = reader.ReadCollectionLength(allowNull: true, maximumLength: 16_384);
    if (count < 0)
    {
      throw new CharacterCatalogSourceException("memorypack_collection_invalid");
    }

    var result = new int[count];
    for (var index = 0; index < count; index++)
    {
      reader.RequireObject(1);
      result[index] = reader.ReadInt32();
    }

    return result;
  }

  private static ImportedIntegerFact ResolveCubeMaximum(
      IReadOnlyList<CubeRow> cubes,
      IReadOnlyDictionary<int, IReadOnlySet<int>> levels,
      SkillLevelIndex skillLevels,
      IDictionary<string, int> diagnostics)
  {
    if (cubes.Count == 0 ||
        cubes.Select(cube => cube.LevelEnhanceId).Distinct().Count() != cubes.Count ||
        !cubes.Select(cube => cube.LevelEnhanceId).ToHashSet().SetEquals(levels.Keys))
    {
      Increment(diagnostics, "cube_maximum_unresolved");
      return ImportedIntegerFact.Unresolved("cube_maximum_missing");
    }

    var nonzeroSkillGroups = new HashSet<int>();
    var coordinatesAreValid = cubes.All(cube =>
        levels[cube.LevelEnhanceId].Order().SequenceEqual(Enumerable.Range(1, 15)) &&
        cube.SkillGroupIds.Length == 3 &&
        cube.SkillGroupIds.Count(groupId => groupId == 0) == 1 &&
        cube.SkillGroupIds.Where(groupId => groupId != 0).All(groupId =>
            skillLevels.MaximumLevelByGroup.ContainsKey(groupId) && nonzeroSkillGroups.Add(groupId)));
    if (!coordinatesAreValid)
    {
      Increment(diagnostics, "cube_maximum_unresolved");
      return ImportedIntegerFact.Unresolved("cube_coordinates_invalid");
    }

    return ImportedIntegerFact.Ready(15);
  }

  private static ProgressionResult ResolveProgression(
      int rarity,
      IEnumerable<int> gradeCoreIds,
      IReadOnlyDictionary<int, GradeCoreRow> gradeCoreRows,
      int? subtypeMaximumBond)
  {
    var supplied = gradeCoreIds.ToArray();
    var actual = supplied.Distinct().ToHashSet();
    var expected = gradeCoreRows.Values
        .Where(row => row.Rarity == rarity)
        .Select(row => row.Id)
        .ToHashSet();
    if (supplied.Length != actual.Count || actual.Count == 0 || !actual.SetEquals(expected))
    {
      return ProgressionResult.Unresolved();
    }

    if (actual.Any(id => !gradeCoreRows.ContainsKey(id)))
    {
      return ProgressionResult.Unresolved();
    }

    var rows = actual.Select(id => gradeCoreRows[id]).ToArray();
    if (rows.Any(row => row.Rarity != rarity))
    {
      return ProgressionResult.Unresolved();
    }

    var terminal = rows.Where(row => row.PieceValue == 0).ToArray();
    if (terminal.Length != 1)
    {
      return ProgressionResult.Unresolved();
    }

    var maximum = terminal[0];
    var maximalGrade = rows.Max(row => row.Grade);
    var maximalCoreAtGrade = rows.Where(row => row.Grade == maximalGrade).Max(row => row.Core);
    if (maximum.Grade != maximalGrade || maximum.Core != maximalCoreAtGrade)
    {
      return ProgressionResult.Unresolved();
    }

    return new ProgressionResult(
        ImportedIntegerFact.Ready(maximum.Grade),
        maximum.Core > 0
            ? ImportedIntegerFact.Ready(maximum.Core)
            : ImportedIntegerFact.NotApplicable(),
        maximum.MaximumBond > 0 && subtypeMaximumBond is > 0
            ? ImportedIntegerFact.Ready(Math.Min(maximum.MaximumBond, subtypeMaximumBond.Value))
            : ImportedIntegerFact.Unresolved("bond_maximum_missing"));
  }

  private static ImportedIntegerFact ResolveSkillMaximum(
      int skillId,
      SkillLevelIndex levels,
      IDictionary<string, int> diagnostics)
  {
    if (skillId != 0 &&
        levels.GroupByRecordIdentifier.TryGetValue(skillId, out var groupId) &&
        levels.MaximumLevelByGroup.TryGetValue(groupId, out var maximum) &&
        maximum >= 10)
    {
      return ImportedIntegerFact.Ready(10);
    }

    Increment(diagnostics, "character_skill_unresolved");
    return ImportedIntegerFact.Unresolved("skill_level_10_unsupported");
  }

  private static ImportedIntegerFact ResolveCollectionMaximum(
      ImportedCodeFact weapon,
      IReadOnlyList<FavoriteItemRow> rows)
  {
    if (weapon.Status != ImportedFactStatus.Ready)
    {
      return ImportedIntegerFact.Unresolved("collection_weapon_unresolved");
    }

    var sourceWeapon = weapon.Value switch
    {
      "ar" => 1,
      "rl" => 2,
      "sr" => 3,
      "mg" => 4,
      "sg" => 5,
      "smg" => 9,
      _ => 0
    };
    var matches = rows.Where(row =>
        row.FavoriteType == 1 && row.NameCode == 0 && row.Weapon == sourceWeapon).ToArray();
    return matches.Length == 0
        ? ImportedIntegerFact.Unresolved("collection_definition_missing")
        : ImportedIntegerFact.Ready(matches.Max(row => row.MaximumLevel));
  }

  private static ImportedIntegerFact ResolveFavoriteMaximum(
      int nameCode,
      IReadOnlyList<FavoriteItemRow> rows)
  {
    var matches = rows.Where(row =>
        row.FavoriteType == 2 && row.NameCode == nameCode && nameCode != 0).ToArray();
    return matches.Length == 0
        ? ImportedIntegerFact.NotApplicable()
        : ImportedIntegerFact.Ready(matches.Max(row => row.MaximumLevel));
  }

  private static ImportedCodeFact ResolveClass(int value) => value switch
  {
    1 => ImportedCodeFact.Ready("attacker"),
    2 => ImportedCodeFact.Ready("defender"),
    3 => ImportedCodeFact.Ready("supporter"),
    _ => ImportedCodeFact.Unresolved("character_class_unknown")
  };

  private static ImportedCodeFact ResolveRarity(int value) => value switch
  {
    1 => ImportedCodeFact.Ready("r"),
    2 => ImportedCodeFact.Ready("sr"),
    3 => ImportedCodeFact.Ready("ssr"),
    _ => ImportedCodeFact.Unresolved("character_rarity_unknown")
  };

  private static ImportedCodeFact ResolveWeapon(int value) => value switch
  {
    1 => ImportedCodeFact.Ready("ar"),
    2 => ImportedCodeFact.Ready("rl"),
    3 => ImportedCodeFact.Ready("sr"),
    4 => ImportedCodeFact.Ready("mg"),
    5 => ImportedCodeFact.Ready("sg"),
    9 => ImportedCodeFact.Ready("smg"),
    _ => ImportedCodeFact.Unresolved("weapon_type_unknown")
  };

  private static ImportedCodeFact ResolveElement(IReadOnlyList<int> values)
  {
    if (values.Count != 1)
    {
      return ImportedCodeFact.Unresolved("element_cardinality_invalid");
    }

    return values[0] switch
    {
      100001 => ImportedCodeFact.Ready("fire"),
      200001 => ImportedCodeFact.Ready("water"),
      300001 => ImportedCodeFact.Ready("wind"),
      400001 => ImportedCodeFact.Ready("electric"),
      500001 => ImportedCodeFact.Ready("iron"),
      _ => ImportedCodeFact.Unresolved("element_unknown")
    };
  }

  private static ImportedCodeFact ResolveManufacturer(int value) => value switch
  {
    1 => ImportedCodeFact.Ready("elysion"),
    2 => ImportedCodeFact.Ready("missilis"),
    3 => ImportedCodeFact.Ready("tetra"),
    4 => ImportedCodeFact.Ready("pilgrim"),
    7 => ImportedCodeFact.Ready("abnormal"),
    _ => ImportedCodeFact.Unresolved("manufacturer_unknown")
  };

  private static byte[] EncodeCanonicalCandidates(
      IReadOnlyList<ImportedCharacterDefinitionCandidate> characters)
  {
    var builder = new StringBuilder("nll/character-catalog-candidate/v1\n");
    builder.Append("count=").Append(characters.Count.ToString(CultureInfo.InvariantCulture));
    foreach (var character in characters)
    {
      builder.Append('\n').Append(character.AliasFingerprint.Hex);
      Append(builder, character.Rarity);
      Append(builder, character.CharacterClass);
      Append(builder, character.Weapon);
      Append(builder, character.Element);
      Append(builder, character.Manufacturer);
      Append(builder, character.MaximumCharacterLevel);
      Append(builder, character.MaximumLimitBreak);
      Append(builder, character.MaximumCore);
      Append(builder, character.MaximumBond);
      Append(builder, character.MaximumSkill1);
      Append(builder, character.MaximumSkill2);
      Append(builder, character.MaximumBurstSkill);
      Append(builder, character.MaximumEquipmentTier);
      Append(builder, character.MaximumEquipmentEnhancement);
      Append(builder, character.MaximumCubeLevel);
      Append(builder, character.MaximumCollectionLevel);
      Append(builder, character.MaximumFavoriteItemLevel);
    }

    return Encoding.UTF8.GetBytes(builder.ToString());
  }

  private static void Append(StringBuilder builder, ImportedCodeFact fact) =>
      builder.Append('\t').Append(fact.Status.ToString().ToLowerInvariant())
          .Append(':').Append(fact.Value ?? fact.ReasonCode ?? "-");

  private static void Append(StringBuilder builder, ImportedIntegerFact fact) =>
      builder.Append('\t').Append(fact.Status.ToString().ToLowerInvariant())
          .Append(':').Append(fact.Value?.ToString(CultureInfo.InvariantCulture) ?? fact.ReasonCode ?? "-");

  private static void Increment(IDictionary<string, int> diagnostics, string code)
  {
    diagnostics.TryGetValue(code, out var count);
    diagnostics[code] = count + 1;
  }

  private sealed record CharacterRow(
      int ResourceId,
      int NameCode,
      int OriginalRare,
      int GradeCoreId,
      int StatEnhanceId,
      int Corporation,
      int CorporationSubtype,
      int CharacterClass,
      int[] ElementIds,
      int ShotId,
      int Skill1Id,
      int Skill1Table,
      int Skill2Id,
      int Skill2Table,
      int UltimateSkillId,
      bool IsVisible,
      bool IsDetailClose);

  private sealed record FavoriteItemRow(
      int Id,
      int FavoriteType,
      int FavoriteRarity,
      int Weapon,
      int NameCode,
      int MaximumLevel,
      int LevelEnhanceId);

  private sealed record FavoriteItemLevelRow(int Id, int LevelEnhanceId, int Grade, int Level);

  private sealed record EquipmentRow(
      int Id,
      int Slot,
      int CharacterClass,
      int Tier,
      int GradeCoreId,
      int GrowGrade);

  private sealed record EquipmentExperienceRow(
      int Id,
      int Tier,
      int GradeCoreId,
      int Level);

  private sealed record EquipmentMaximums(int MaximumTier, int MaximumEnhancementLevel);

  private sealed record GradeCoreRow(
      int Id,
      int Rarity,
      int Grade,
      int Core,
      int PieceValue,
      int MaximumBond);

  private sealed record CubeRow(int LevelEnhanceId, int[] SkillGroupIds);

  private sealed record SkillLevelIndex(
      IReadOnlyDictionary<int, int> GroupByRecordIdentifier,
      IReadOnlyDictionary<int, int> MaximumLevelByGroup);

  private sealed record ProgressionResult(
      ImportedIntegerFact MaximumLimitBreak,
      ImportedIntegerFact MaximumCore,
      ImportedIntegerFact MaximumBond)
  {
    public bool IsReady =>
        MaximumLimitBreak.Status == ImportedFactStatus.Ready &&
        MaximumCore.Status is ImportedFactStatus.Ready or ImportedFactStatus.NotApplicable &&
        MaximumBond.Status == ImportedFactStatus.Ready;

    public static ProgressionResult Unresolved() => new(
        ImportedIntegerFact.Unresolved("limit_break_maximum_missing"),
        ImportedIntegerFact.Unresolved("core_maximum_missing"),
        ImportedIntegerFact.Unresolved("bond_maximum_missing"));
  }
}
