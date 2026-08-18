using System.IO.Compression;
using System.Text;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Import.CharacterCatalog;

namespace NikkeLocalLab.UnitTests;

public sealed class CharacterCatalogSourceTests
{
  [Fact]
  public void StaticDataReaderNormalizesSyntheticCharacterWithoutExposingSourceIdentity()
  {
    using var archive = SyntheticStaticData.Create();
    var secret = Enumerable.Range(1, 32).Select(value => (byte)value).ToArray();
    var extraction = new StaticDataCharacterCatalogReader().Read(
        archive,
        secret,
        new CharacterCatalogRuntimeCaps(30, 40));

    var character = Assert.Single(extraction.Characters);
    Assert.True(character.IsSourceResolved);
    Assert.Equal("ssr", character.Rarity.Value);
    Assert.Equal("attacker", character.CharacterClass.Value);
    Assert.Equal("ar", character.Weapon.Value);
    Assert.Equal("electric", character.Element.Value);
    Assert.Equal("missilis", character.Manufacturer.Value);
    Assert.Equal(1400, character.MaximumCharacterLevel.Value);
    Assert.Equal(3, character.MaximumLimitBreak.Value);
    Assert.Equal(7, character.MaximumCore.Value);
    Assert.Equal(30, character.MaximumBond.Value);
    Assert.Equal(10, character.MaximumSkill1.Value);
    Assert.Equal(10, character.MaximumSkill2.Value);
    Assert.Equal(10, character.MaximumBurstSkill.Value);
    Assert.Equal(10, character.MaximumEquipmentTier.Value);
    Assert.Equal(5, character.MaximumEquipmentEnhancement.Value);
    Assert.Equal(15, character.MaximumCubeLevel.Value);
    Assert.Equal(15, character.MaximumCollectionLevel.Value);
    Assert.Equal(2, character.MaximumFavoriteItemLevel.Value);
    Assert.DoesNotContain("424242", character.AliasFingerprint.Hex, StringComparison.Ordinal);
    Assert.DoesNotContain("31337", character.AliasFingerprint.Hex, StringComparison.Ordinal);
    Assert.Equal(64, extraction.CanonicalCandidateSha256.Hex.Length);
  }

  [Fact]
  public void AliasFingerprintIsStableButNeverAnEntityUid()
  {
    var secret = Enumerable.Range(0, 32).Select(value => (byte)value).ToArray();
    var first = SourceAliasFingerprintEncoder.Encode(secret, "fixture", "character", "raw-canary");
    var second = SourceAliasFingerprintEncoder.Encode(secret, "fixture", "character", "raw-canary");

    Assert.Equal(first, second);
    Assert.NotEqual(EntityUid.New().ToString(), first.Hex);
    Assert.Equal(64, first.Hex.Length);
  }

  [Fact]
  public void TruncatedSourceFailsWithControlledCodeOnly()
  {
    using var archive = SyntheticStaticData.Create(truncateCharacterTable: true);
    var exception = Assert.Throws<CharacterCatalogSourceException>(() =>
        new StaticDataCharacterCatalogReader().Read(
            archive,
            new byte[32],
            new CharacterCatalogRuntimeCaps(30, 40)));

    Assert.Matches("^[a-z0-9_]+$", exception.Code);
    Assert.DoesNotContain("CharacterTable", exception.Message, StringComparison.Ordinal);
  }

  [Theory]
  [InlineData(0, 30)]
  [InlineData(1, 40)]
  public void RuntimeBondCapUsesOnlyTheKnownCorporationSubtypes(int subtype, int expectedMaximum)
  {
    using var archive = SyntheticStaticData.Create(corporationSubtype: subtype);
    var extraction = new StaticDataCharacterCatalogReader().Read(
        archive,
        new byte[32],
        new CharacterCatalogRuntimeCaps(30, 40));

    Assert.Equal(expectedMaximum, Assert.Single(extraction.Characters).MaximumBond.Value);
  }

  [Theory]
  [InlineData(0, 40)]
  [InlineData(30, 29)]
  public void InvalidRuntimeCapsFailClosed(int normalMaximum, int overspecMaximum)
  {
    var exception = Assert.Throws<CharacterCatalogSourceException>(() =>
        new CharacterCatalogRuntimeCaps(normalMaximum, overspecMaximum));
    Assert.Equal("runtime_caps_invalid", exception.Code);
  }

  [Fact]
  public void UnknownCorporationSubtypeRemainsUnresolved()
  {
    using var archive = SyntheticStaticData.Create(corporationSubtype: 2);
    var extraction = new StaticDataCharacterCatalogReader().Read(
        archive,
        new byte[32],
        new CharacterCatalogRuntimeCaps(30, 40));

    var character = Assert.Single(extraction.Characters);
    Assert.False(character.IsSourceResolved);
    Assert.Equal(ImportedFactStatus.Unresolved, character.MaximumBond.Status);
    Assert.Contains(extraction.Diagnostics, diagnostic =>
        diagnostic.Code == "character_progression_unresolved" && diagnostic.OccurrenceCount == 1);
  }

  [Fact]
  public void StaticDataArchiveRejectsTraversalEntry()
  {
    using var archive = SyntheticStaticData.Create(mutateArchive: value =>
        AddBytes(value, "../canary.bin", [1], CompressionLevel.NoCompression));

    AssertSourceCode(archive, "archive_entry_name_invalid");
  }

  [Fact]
  public void StaticDataArchiveRejectsDuplicateNormalizedEntry()
  {
    using var archive = SyntheticStaticData.Create(mutateArchive: value =>
        AddBytes(value, "FIXTURE/charactertable.mpk", [1], CompressionLevel.NoCompression));

    AssertSourceCode(archive, "archive_entry_duplicate");
  }

  [Fact]
  public void MemoryPackRejectsOversizedCollectionBeforeAllocation()
  {
    using var bytes = new MemoryStream();
    using (var writer = new BinaryWriter(bytes, Encoding.UTF8, leaveOpen: true))
    {
      writer.Write(250_001);
    }

    using var archive = SyntheticStaticData.Create(characterTableOverride: bytes.ToArray());
    AssertSourceCode(archive, "memorypack_collection_invalid");
  }

  [Fact]
  public void MemoryPackRejectsInvalidBooleanEncoding()
  {
    using var archive = SyntheticStaticData.Create(invalidCharacterBoolean: true);
    AssertSourceCode(archive, "memorypack_boolean_invalid");
  }

  [Fact]
  public void MemoryPackRejectsMalformedUtf16()
  {
    using var bytes = new MemoryStream();
    using (var writer = new BinaryWriter(bytes, Encoding.UTF8, leaveOpen: true))
    {
      writer.Write(1);
      writer.Write((byte)40);
      writer.Write(1);
      writer.Write(1);
      writer.Write((ushort)0xD800);
    }

    using var archive = SyntheticStaticData.Create(characterTableOverride: bytes.ToArray());
    AssertSourceCode(archive, "memorypack_string_invalid");
  }

  [Fact]
  public void FavoriteItemLevelsRejectForeignKeyMismatch()
  {
    using var archive = SyntheticStaticData.Create(fault: SyntheticFault.FavoriteLevelForeignKey);
    AssertSourceCode(archive, "favorite_level_fk_invalid");
  }

  [Fact]
  public void FavoriteItemLevelsRejectMissingCoordinate()
  {
    using var archive = SyntheticStaticData.Create(fault: SyntheticFault.FavoriteLevelGap);
    AssertSourceCode(archive, "favorite_level_coordinates_invalid");
  }

  [Theory]
  [InlineData(SyntheticFault.FavoriteOrphan)]
  [InlineData(SyntheticFault.FavoriteDuplicate)]
  public void FavoriteItemsRejectOrphanAndAmbiguousCharacterReferences(SyntheticFault fault)
  {
    using var archive = SyntheticStaticData.Create(fault: fault);
    AssertSourceCode(archive, "favorite_level_fk_invalid");
  }

  [Theory]
  [InlineData(SyntheticFault.EquipmentExpForeignKey)]
  [InlineData(SyntheticFault.EquipmentExpGap)]
  public void EquipmentExperienceRejectsForeignKeyAndCoordinateGaps(SyntheticFault fault)
  {
    using var archive = SyntheticStaticData.Create(fault: fault);
    AssertSourceCode(archive, "equipment_exp_fk_invalid");
  }

  [Fact]
  public void CubeCoordinateGapRemainsExplicitlyUnresolved()
  {
    using var archive = SyntheticStaticData.Create(fault: SyntheticFault.CubeLevelGap);
    var extraction = ReadSynthetic(archive);

    Assert.False(Assert.Single(extraction.Characters).IsSourceResolved);
    Assert.Contains(extraction.Diagnostics, diagnostic =>
        diagnostic.Code == "cube_maximum_unresolved" && diagnostic.OccurrenceCount == 1);
  }

  [Fact]
  public void CharacterLevelRejectsMissingCoordinate()
  {
    using var archive = SyntheticStaticData.Create(fault: SyntheticFault.CharacterLevelGap);
    AssertSourceCode(archive, "character_level_maximum_missing");
  }

  [Fact]
  public void AttractiveLevelValidatesLevelCoordinatesRatherThanRecordIdentifiers()
  {
    using var archive = SyntheticStaticData.Create(fault: SyntheticFault.AttractiveLevelDuplicate);
    AssertSourceCode(archive, "attractive_level_coordinates_invalid");
  }

  [Theory]
  [InlineData(SyntheticFault.GradeCoreSetGap)]
  [InlineData(SyntheticFault.GradeCoreTerminalNotMaximal)]
  public void ProgressionRejectsIncompleteOrNonterminalGradeCoreCoordinates(SyntheticFault fault)
  {
    using var archive = SyntheticStaticData.Create(fault: fault);
    var extraction = ReadSynthetic(archive);

    Assert.False(Assert.Single(extraction.Characters).IsSourceResolved);
    Assert.Contains(extraction.Diagnostics, diagnostic =>
        diagnostic.Code == "character_progression_unresolved" && diagnostic.OccurrenceCount == 1);
  }

  [Theory]
  [InlineData(SyntheticFault.StatEnhanceConflict)]
  [InlineData(SyntheticFault.SkillTableConflict)]
  public void CharacterVariantsRejectCombatJoinKeyConflicts(SyntheticFault fault)
  {
    using var archive = SyntheticStaticData.Create(fault: fault);
    AssertSourceCode(archive, "character_catalog_empty");
  }

  [Fact]
  public void SdBinReaderMapsRuntimeCapsAndRejectsDuplicateConfigIdentifiers()
  {
    using var valid = CreateSdBin(ValidConfigJson);
    var caps = new SdBinCharacterConfigReader().Read(valid);

    Assert.Equal(30, caps.ForCorporationSubtype(0));
    Assert.Equal(40, caps.ForCorporationSubtype(1));
    Assert.Null(caps.ForCorporationSubtype(-1));
    Assert.Null(caps.ForCorporationSubtype(2));

    const string duplicate = """
        {"records":[
          {"id":"AttractiveNormalMaxLv","value":30},
          {"id":"AttractiveNormalMaxLv","value":31},
          {"id":"AttractiveOverspecMaxLv","value":40}
        ]}
        """;
    using var invalid = CreateSdBin(duplicate);
    var exception = Assert.Throws<CharacterCatalogSourceException>(() =>
        new SdBinCharacterConfigReader().Read(invalid));
    Assert.Equal("game_config_identifier_invalid", exception.Code);
  }

  [Fact]
  public void SdBinArchiveRejectsEntryCountLimit()
  {
    using var archive = CreateSdBin(ValidConfigJson, value =>
    {
      for (var index = 0; index < 32; index++)
      {
        AddBytes(value, $"extra-{index:D2}.bin", [1], CompressionLevel.NoCompression);
      }
    });

    AssertConfigCode(archive, "archive_entry_count_invalid");
  }

  [Fact]
  public void SdBinArchiveRejectsTotalExpandedSizeLimit()
  {
    var payload = new byte[3 * 1024 * 1024];
    using var archive = CreateSdBin(ValidConfigJson, value =>
    {
      for (var index = 0; index < 3; index++)
      {
        AddBytes(value, $"bulk-{index}.bin", payload, CompressionLevel.NoCompression);
      }
    });

    AssertConfigCode(archive, "archive_total_size_invalid");
  }

  [Fact]
  public void SdBinArchiveRejectsExcessiveCompressionRatio()
  {
    using var archive = CreateSdBin(ValidConfigJson, value =>
        AddBytes(value, "ratio-bomb.bin", new byte[1024 * 1024], CompressionLevel.SmallestSize));

    AssertConfigCode(archive, "archive_compression_ratio_invalid");
  }

  private const string ValidConfigJson = """
      {"records":[
        {"id":"AttractiveNormalMaxLv","value":30},
        {"id":"AttractiveOverspecMaxLv","value":"40"}
      ]}
      """;

  private static void AssertSourceCode(MemoryStream archive, string expectedCode)
  {
    var exception = Assert.Throws<CharacterCatalogSourceException>(() =>
        new StaticDataCharacterCatalogReader().Read(
            archive,
            new byte[32],
            new CharacterCatalogRuntimeCaps(30, 40)));
    Assert.Equal(expectedCode, exception.Code);
    Assert.Equal("The character catalog source failed a controlled validation.", exception.Message);
  }

  private static CharacterCatalogExtraction ReadSynthetic(MemoryStream archive) =>
      new StaticDataCharacterCatalogReader().Read(
          archive,
          new byte[32],
          new CharacterCatalogRuntimeCaps(30, 40));

  public enum SyntheticFault
  {
    None,
    FavoriteLevelForeignKey,
    FavoriteLevelGap,
    FavoriteOrphan,
    FavoriteDuplicate,
    EquipmentExpForeignKey,
    EquipmentExpGap,
    CubeLevelGap,
    CharacterLevelGap,
    AttractiveLevelDuplicate,
    GradeCoreSetGap,
    GradeCoreTerminalNotMaximal,
    StatEnhanceConflict,
    SkillTableConflict
  }

  private static void AssertConfigCode(MemoryStream archive, string expectedCode)
  {
    var exception = Assert.Throws<CharacterCatalogSourceException>(() =>
        new SdBinCharacterConfigReader().Read(archive));
    Assert.Equal(expectedCode, exception.Code);
  }

  private static MemoryStream CreateSdBin(string json, Action<ZipArchive>? mutateArchive = null)
  {
    var stream = new MemoryStream();
    using (var archive = new ZipArchive(stream, ZipArchiveMode.Create, leaveOpen: true))
    {
      AddBytes(
          archive,
          "ConfigGameTable.json",
          Encoding.UTF8.GetBytes(json),
          CompressionLevel.NoCompression);
      mutateArchive?.Invoke(archive);
    }

    stream.Position = 0;
    return stream;
  }

  private static void AddBytes(
      ZipArchive archive,
      string name,
      byte[] bytes,
      CompressionLevel compressionLevel)
  {
    var entry = archive.CreateEntry(name, compressionLevel);
    using var target = entry.Open();
    target.Write(bytes);
  }

  private static class SyntheticStaticData
  {
    public static MemoryStream Create(
        bool truncateCharacterTable = false,
        int corporationSubtype = 0,
        bool invalidCharacterBoolean = false,
        byte[]? characterTableOverride = null,
        Action<ZipArchive>? mutateArchive = null,
        SyntheticFault fault = SyntheticFault.None)
    {
      var stream = new MemoryStream();
      using (var archive = new ZipArchive(stream, ZipArchiveMode.Create, leaveOpen: true))
      {
        Add(
            archive,
            "CharacterTable.mpk",
            characterTableOverride ?? WriteCharacters(corporationSubtype, invalidCharacterBoolean, fault),
            truncateCharacterTable);
        Add(archive, "CharacterLevelTable.mpk", WriteCharacterLevels(fault));
        Add(archive, "CharacterShotTable.mpk", WriteShots());
        Add(archive, "SkillInfoTable.mpk", WriteSkillInfo());
        Add(archive, "AttractiveLevelTable.mpk", WriteAttractive(fault));
        Add(archive, "FavoriteItemTable.mpk", WriteFavoriteItems(fault));
        Add(archive, "FavoriteItemLevelTable.mpk", WriteFavoriteItemLevels(fault));
        Add(archive, "GradeCoreTable.mpk", WriteGradeCore(fault));
        Add(archive, "ItemEquipTable.mpk", WriteEquipment());
        Add(archive, "ItemEquipExpTable.mpk", WriteEquipmentExperience(fault));
        Add(archive, "ItemHarmonyCubeTable.mpk", WriteCubes());
        Add(archive, "ItemHarmonyCubeLevelTable.mpk", WriteCubeLevels(fault));
        mutateArchive?.Invoke(archive);
      }

      stream.Position = 0;
      return stream;
    }

    private static void Add(
        ZipArchive archive,
        string name,
        byte[] bytes,
        bool truncate = false)
    {
      var entry = archive.CreateEntry($"fixture/{name}", CompressionLevel.NoCompression);
      using var target = entry.Open();
      target.Write(bytes, 0, truncate ? bytes.Length - 1 : bytes.Length);
    }

    private static byte[] WriteCharacters(
        int corporationSubtype,
        bool invalidBoolean,
        SyntheticFault fault)
    {
      var gradeCoreIds = Enumerable.Range(1, 11)
          .Where(id => fault != SyntheticFault.GradeCoreSetGap || id != 6)
          .ToArray();
      return WriteTable(gradeCoreIds.Length, writer =>
      {
        foreach (var grade in gradeCoreIds)
        {
          writer.Write((byte)40);
          writer.Write(100000 + grade);
          WriteString(writer, "synthetic-name-key");
          WriteString(writer, "synthetic-description-key");
          writer.Write(424242);
          writer.Write(0);
          writer.Write(31337);
          writer.Write(1);
          writer.Write(3);
          writer.Write(grade);
          writer.Write(0);
          writer.Write(fault == SyntheticFault.StatEnhanceConflict && grade == 11 ? 1 : 0);
          writer.Write(2);
          writer.Write(corporationSubtype);
          writer.Write(1);
          writer.Write(1);
          writer.Write(400001);
          writer.Write(1500);
          writer.Write(15000);
          writer.Write(9001);
          writer.Write(25);
          writer.Write(45);
          writer.Write(3);
          writer.Write(4);
          writer.Write(0);
          writer.Write(1000);
          writer.Write(21);
          writer.Write(1);
          writer.Write(fault == SyntheticFault.SkillTableConflict && grade == 11 ? 2 : 1);
          writer.Write(11);
          writer.Write(1);
          writer.Write(0);
          writer.Write(0);
          writer.Write(0);
          writer.Write(0);
          writer.Write(0);
          WriteString(writer, "synthetic-cv-key");
          writer.Write(0);
          writer.Write(0);
          writer.Write(true);
          writer.Write(false);
          if (invalidBoolean)
          {
            writer.Write((byte)2);
          }
          else
          {
            writer.Write(false);
          }
        }
      });
    }

    private static byte[] WriteShots()
    {
      return WriteTable(1, writer =>
      {
        writer.Write((byte)58);
        writer.Write(9001);
        WriteString(writer, "shot");
        WriteString(writer, "shot-description");
        WriteString(writer, "camera");
        writer.Write(1);
        for (var field = 5; field <= 49; field++)
        {
          if (field == 9)
          {
            writer.Write(false);
          }
          else
          {
            writer.Write(0);
          }
        }

        WriteString(writer, "homing");
        writer.Write(0);
        writer.Write(0);
        writer.Write(0);
        writer.Write(0);
        writer.Write(0);
        writer.Write(0);
        WriteString(writer, "aim");
      });
    }

    private static byte[] WriteCharacterLevels(SyntheticFault fault)
    {
      var levels = Enumerable.Range(1, 1400)
          .Where(level => fault != SyntheticFault.CharacterLevelGap || level != 100)
          .ToArray();
      return WriteTable(levels.Length, writer =>
      {
        foreach (var level in levels)
        {
          writer.Write((byte)6);
          writer.Write(level);
          writer.Write(0);
          writer.Write(0);
          writer.Write(0);
          writer.Write(0);
          writer.Write(0);
        }
      });
    }

    private static byte[] WriteSkillInfo()
    {
      return WriteTable(30, writer =>
      {
        var id = 1;
        foreach (var group in new[] { 7001, 7002, 7003 })
        {
          for (var level = 1; level <= 10; level++)
          {
            writer.Write((byte)10);
            writer.Write(id++);
            writer.Write(group);
            writer.Write(level);
            writer.Write(0);
            writer.Write(0);
            WriteString(writer, "icon");
            WriteString(writer, "name");
            WriteString(writer, "description");
            WriteString(writer, "info");
            writer.Write(0);
          }
        }
      });
    }

    private static byte[] WriteAttractive(SyntheticFault fault)
    {
      return WriteTable(40, writer =>
      {
        for (var id = 1; id <= 40; id++)
        {
          var level = fault == SyntheticFault.AttractiveLevelDuplicate && id == 20 ? 19 : id;
          writer.Write((byte)21);
          writer.Write(id);
          writer.Write(level);
          for (var field = 2; field < 21; field++)
          {
            writer.Write(0);
          }
        }
      });
    }

    private static byte[] WriteFavoriteItems(SyntheticFault fault)
    {
      var count = fault == SyntheticFault.FavoriteDuplicate ? 3 : 2;
      return WriteTable(count, writer =>
      {
        WriteFavorite(
            writer,
            id: 1,
            favoriteType: 1,
            favoriteRarity: 1,
            weapon: 1,
            nameCode: 0,
            maximumLevel: 15,
            levelEnhanceId: 500);
        WriteFavorite(
            writer,
            id: 2,
            favoriteType: 2,
            favoriteRarity: 3,
            weapon: 1,
            nameCode: fault == SyntheticFault.FavoriteOrphan ? 99999 : 31337,
            maximumLevel: 2,
            levelEnhanceId: 501);
        if (fault == SyntheticFault.FavoriteDuplicate)
        {
          WriteFavorite(
              writer,
              id: 3,
              favoriteType: 2,
              favoriteRarity: 3,
              weapon: 2,
              nameCode: 31337,
              maximumLevel: 2,
              levelEnhanceId: 502);
        }
      });
    }

    private static byte[] WriteFavoriteItemLevels(SyntheticFault fault)
    {
      var collectionLevels = Enumerable.Range(0, 16)
          .Where(level => fault != SyntheticFault.FavoriteLevelGap || level != 7)
          .ToArray();
      return WriteTable(collectionLevels.Length + 3, writer =>
      {
        var id = 1;
        foreach (var level in collectionLevels)
        {
          WriteFavoriteItemLevel(writer, id++, 500, Math.Min(level / 5, 3), level);
        }

        for (var level = 0; level <= 2; level++)
        {
          var enhanceId = fault == SyntheticFault.FavoriteLevelForeignKey ? 999 : 501;
          WriteFavoriteItemLevel(writer, id++, enhanceId, level + 1, level);
        }
      });
    }

    private static byte[] WriteGradeCore(SyntheticFault fault)
    {
      return WriteTable(11, writer =>
      {
        for (var id = 1; id <= 11; id++)
        {
          writer.Write((byte)7);
          writer.Write(id);
          writer.Write(3);
          writer.Write(Math.Min(id - 1, 3));
          writer.Write(Math.Max(0, id - 4));
          writer.Write(200);
          var isTerminal = fault == SyntheticFault.GradeCoreTerminalNotMaximal
              ? id == 10
              : id == 11;
          writer.Write(isTerminal ? 0 : 50);
          writer.Write(id == 11 ? 40 : Math.Min(id * 10, 40));
        }
      });
    }

    private static void WriteFavorite(
        BinaryWriter writer,
        int id,
        int favoriteType,
        int favoriteRarity,
        int weapon,
        int nameCode,
        int maximumLevel,
        int levelEnhanceId)
    {
      writer.Write((byte)17);
      writer.Write(id);
      for (var field = 0; field < 5; field++)
      {
        WriteString(writer, "fixture");
      }

      writer.Write(0);
      writer.Write(favoriteRarity);
      writer.Write(favoriteType);
      writer.Write(weapon);
      writer.Write(nameCode);
      writer.Write(maximumLevel);
      writer.Write(levelEnhanceId);
      writer.Write(0);
      WriteObjectIntList(writer, 2, 1);
      WriteObjectIntList(writer, 3, 3);
      writer.Write(0);
    }

    private static void WriteFavoriteItemLevel(
        BinaryWriter writer,
        int id,
        int levelEnhanceId,
        int grade,
        int level)
    {
      writer.Write((byte)6);
      writer.Write(id);
      writer.Write(levelEnhanceId);
      writer.Write(grade);
      writer.Write(level);
      WriteObjectIntList(writer, 3, 2);
      WriteObjectIntList(writer, 2, 1);
    }

    private static byte[] WriteEquipment()
    {
      return WriteTable(12, writer =>
      {
        var id = 1;
        for (var characterClass = 1; characterClass <= 3; characterClass++)
        {
          for (var slot = 1; slot <= 4; slot++)
          {
            writer.Write((byte)15);
            writer.Write(id++);
            WriteString(writer, "equipment-name");
            WriteString(writer, "equipment-description");
            WriteString(writer, "equipment-resource");
            writer.Write(1);
            writer.Write(slot);
            writer.Write(characterClass);
            writer.Write(10);
            writer.Write(10);
            writer.Write(0);
            WriteObjectIntList(writer, 6, 2);
            WriteObjectIntList(writer, 3, 2);
            writer.Write(0);
            writer.Write(0);
            writer.Write(0);
          }
        }
      });
    }

    private static byte[] WriteEquipmentExperience(SyntheticFault fault)
    {
      var levels = Enumerable.Range(0, 6)
          .Where(level => fault != SyntheticFault.EquipmentExpGap || level != 3)
          .ToArray();
      return WriteTable(levels.Length, writer =>
      {
        foreach (var level in levels)
        {
          writer.Write((byte)5);
          writer.Write(level + 1);
          writer.Write(10);
          writer.Write(fault == SyntheticFault.EquipmentExpForeignKey ? 11 : 10);
          writer.Write(level);
          writer.Write(level * 100);
        }
      });
    }

    private static byte[] WriteCubes()
    {
      return WriteTable(1, writer =>
      {
        writer.Write((byte)15);
        writer.Write(1);
        WriteString(writer, "cube-name");
        WriteString(writer, "cube-description");
        writer.Write(0);
        WriteString(writer, "cube-location");
        writer.Write(0);
        writer.Write(0);
        WriteString(writer, "cube-bg");
        WriteString(writer, "cube-color");
        writer.Write(0);
        writer.Write(0);
        writer.Write(0);
        writer.Write(0);
        writer.Write(900);
        writer.Write(3);
        foreach (var skillGroupId in new[] { 7001, 7002, 0 })
        {
          writer.Write((byte)1);
          writer.Write(skillGroupId);
        }
      });
    }

    private static byte[] WriteCubeLevels(SyntheticFault fault)
    {
      var levels = Enumerable.Range(1, 15)
          .Where(level => fault != SyntheticFault.CubeLevelGap || level != 8)
          .ToArray();
      return WriteTable(levels.Length, writer =>
      {
        foreach (var level in levels)
        {
          writer.Write((byte)9);
          writer.Write(level);
          writer.Write(900);
          writer.Write(level);
          WriteObjectIntList(writer, 3, 1);
          writer.Write(0);
          writer.Write(0);
          writer.Write(0);
          writer.Write(0);
          WriteObjectIntList(writer, 3, 2);
        }
      });
    }

    private static void WriteObjectIntList(BinaryWriter writer, int count, int memberCount)
    {
      writer.Write(count);
      for (var item = 0; item < count; item++)
      {
        writer.Write((byte)memberCount);
        for (var field = 0; field < memberCount; field++)
        {
          writer.Write(item + field + 1);
        }
      }
    }

    private static byte[] WriteTable(int count, Action<BinaryWriter> writeRecords)
    {
      using var stream = new MemoryStream();
      using (var writer = new BinaryWriter(stream, Encoding.UTF8, leaveOpen: true))
      {
        writer.Write(count);
        writeRecords(writer);
      }

      return stream.ToArray();
    }

    private static void WriteString(BinaryWriter writer, string value)
    {
      writer.Write(value.Length);
      writer.Write(Encoding.Unicode.GetBytes(value));
    }
  }
}
