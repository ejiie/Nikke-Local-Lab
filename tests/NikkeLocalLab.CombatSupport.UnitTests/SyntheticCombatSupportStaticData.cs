using System.IO.Compression;
using System.Text;

namespace NikkeLocalLab.CombatSupport.UnitTests;

public enum SyntheticCombatSupportFault
{
  None,
  GradeCoreOrphan,
  GrowthRelationMismatch,
  OverloadSignMismatch,
  UnknownCollectionWeapon,
  UnknownCollectionStat
}

internal static class SyntheticCombatSupportStaticData
{
  public const int SourceIdentityLeakSentinel = 987_654_321;
  private const int StandardOverloadGroup = 777_000;

  public static MemoryStream Create(
      SyntheticCombatSupportFault fault = SyntheticCombatSupportFault.None,
      int skillAssignmentVariant = 0,
      int consoleMaximumLevel = 680,
      int? firstConsoleMaximumLevel = null,
      Action<ZipArchive>? mutateArchive = null)
  {
    if (consoleMaximumLevel <= 0 || firstConsoleMaximumLevel is <= 0)
    {
      throw new ArgumentOutOfRangeException(nameof(consoleMaximumLevel));
    }

    var stream = new MemoryStream();
    using (var archive = new ZipArchive(stream, ZipArchiveMode.Create, leaveOpen: true))
    {
      Add(archive, "CharacterTable.mpk", WriteCharacters());
      Add(archive, "EquipmentOptionTable.mpk", WriteEquipmentOptions());
      Add(archive, "FavoriteItemLevelTable.mpk", WriteFavoriteLevels(fault));
      Add(archive, "FavoriteItemTable.mpk", WriteFavoriteItems(fault));
      Add(archive, "FunctionTable.mpk", WriteFunctions(fault));
      Add(archive, "GradeCoreEquipmentTable.mpk", WriteGradeCoreEquipment());
      Add(archive, "ItemEquipExpTable.mpk", WriteEquipmentExperience(fault));
      Add(archive, "ItemEquipTable.mpk", WriteEquipment(fault));
      Add(archive, "ItemHarmonyCubeLevelTable.mpk", WriteCubeLevels());
      Add(archive, "ItemHarmonyCubeTable.mpk", WriteCubes(skillAssignmentVariant));
      Add(
          archive,
          "RecycleResearchLevelTable.mpk",
          WriteConsoleLevels(consoleMaximumLevel, firstConsoleMaximumLevel));
      Add(archive, "RecycleResearchStatTable.mpk", WriteConsoleStats());
      Add(archive, "StateEffectTable.mpk", WriteStateEffects());
      mutateArchive?.Invoke(archive);
    }

    stream.Position = 0;
    return stream;
  }

  private static byte[] WriteCharacters() => WriteTable(1, writer =>
  {
    writer.Write((byte)40);
    writer.Write(810_001);
    WriteString(writer, "synthetic-character-name");
    WriteString(writer, "synthetic-character-description");
    writer.Write(810_002);
    writer.Write(0);
    writer.Write(700);
    writer.Write(1);
    writer.Write(3);
    writer.Write(1);
    writer.Write(0);
    writer.Write(1);
    writer.Write(1);
    writer.Write(0);
    writer.Write(1);
    writer.Write(1);
    writer.Write(1);
    for (var field = 0; field < 19; field++)
    {
      writer.Write(field + 1);
    }

    WriteString(writer, "synthetic-character-voice");
    writer.Write(0);
    writer.Write(0);
    writer.Write(true);
    writer.Write(false);
    writer.Write(false);
  });

  private static byte[] WriteEquipment(SyntheticCombatSupportFault fault)
  {
    var identifiers = EquipmentIdentifiers();
    return WriteTable(24, writer =>
    {
      foreach (var role in Enumerable.Range(1, 3))
      {
        foreach (var slot in Enumerable.Range(1, 4))
        {
          foreach (var tier in new[] { 9, 10 })
          {
            writer.Write((byte)15);
            writer.Write(identifiers[(role, slot, tier)]);
            WriteString(writer, "synthetic-equipment-name");
            WriteString(writer, "synthetic-equipment-description");
            WriteString(writer, "synthetic-equipment-resource");
            writer.Write(0);
            writer.Write(slot);
            writer.Write(role);
            writer.Write(tier);
            var gradeCore = tier == 9 ? 910_009 : 910_010;
            if (fault == SyntheticCombatSupportFault.GradeCoreOrphan && tier == 9)
            {
              gradeCore = 919_999;
            }

            writer.Write(gradeCore);
            var growthTarget = tier == 9 ? identifiers[(role, slot, 10)] : 0;
            if (fault == SyntheticCombatSupportFault.GrowthRelationMismatch &&
                role == 1 && slot == 1 && tier == 9)
            {
              growthTarget = identifiers[(role, 2, 10)];
            }

            writer.Write(growthTarget);
            WriteEquipmentStats(writer, slot, role, tier);
            WriteEquipmentOptionSlots(writer, tier);
            writer.Write(0);
            writer.Write(0);
            writer.Write(0);
          }
        }
      }
    });
  }

  private static Dictionary<(int Role, int Slot, int Tier), int> EquipmentIdentifiers()
  {
    var result = new Dictionary<(int Role, int Slot, int Tier), int>();
    var ordinal = 0;
    foreach (var role in Enumerable.Range(1, 3))
    {
      foreach (var slot in Enumerable.Range(1, 4))
      {
        result.Add(
            (role, slot, 9),
            ordinal == 0 ? SourceIdentityLeakSentinel : 100_000 + ordinal);
        result.Add((role, slot, 10), 200_000 + ordinal);
        ordinal++;
      }
    }

    return result;
  }

  private static void WriteEquipmentStats(BinaryWriter writer, int slot, int role, int tier)
  {
    var baseValue = (role * 1_000) + (tier * 10) + slot;
    var active = slot switch
    {
      1 or 2 => new[] { (Kind: 1, Value: baseValue), (Kind: 2, Value: baseValue + 1) },
      3 => new[] { (Kind: 1, Value: baseValue), (Kind: 3, Value: baseValue + 1) },
      4 => new[] { (Kind: 2, Value: baseValue), (Kind: 3, Value: baseValue + 1) },
      _ => throw new InvalidOperationException()
    };
    writer.Write(6);
    foreach (var stat in active)
    {
      writer.Write((byte)2);
      writer.Write(stat.Kind);
      writer.Write(stat.Value);
    }

    for (var padding = active.Length; padding < 6; padding++)
    {
      writer.Write((byte)2);
      writer.Write(0);
      writer.Write(0);
    }
  }

  private static void WriteEquipmentOptionSlots(BinaryWriter writer, int tier)
  {
    writer.Write(3);
    var ratios = tier == 10 ? new[] { 10_000, 5_000, 3_000 } : new[] { 0, 0, 0 };
    foreach (var ratio in ratios)
    {
      writer.Write((byte)2);
      writer.Write(tier == 10 ? StandardOverloadGroup : 0);
      writer.Write(ratio);
    }
  }

  private static byte[] WriteGradeCoreEquipment() => WriteTable(2, writer =>
  {
    WriteGradeCoreEquipmentRow(writer, 910_009, "synthetic-tier-nine");
    WriteGradeCoreEquipmentRow(writer, 910_010, "synthetic-overload");
  });

  private static void WriteGradeCoreEquipmentRow(BinaryWriter writer, int id, string rarity)
  {
    writer.Write((byte)6);
    writer.Write(id);
    writer.Write(0);
    writer.Write(5);
    writer.Write(0);
    writer.Write(0);
    WriteString(writer, rarity);
  }

  private static byte[] WriteEquipmentExperience(SyntheticCombatSupportFault fault)
  {
    var tierNineGrade = fault == SyntheticCombatSupportFault.GradeCoreOrphan ? 919_999 : 910_009;
    return WriteTable(12, writer =>
    {
      var id = 920_000;
      foreach (var coordinate in new[] { (Tier: 9, Grade: tierNineGrade), (Tier: 10, Grade: 910_010) })
      {
        foreach (var level in Enumerable.Range(0, 6))
        {
          writer.Write((byte)5);
          writer.Write(id++);
          writer.Write(coordinate.Tier);
          writer.Write(coordinate.Grade);
          writer.Write(level);
          writer.Write(level * 10);
        }
      }
    });
  }

  private static byte[] WriteCubes(int skillAssignmentVariant) => WriteTable(1, writer =>
  {
    writer.Write((byte)15);
    writer.Write(310_001);
    WriteString(writer, "synthetic-cube-name");
    WriteString(writer, "synthetic-cube-description");
    writer.Write(0);
    WriteString(writer, "synthetic-cube-location");
    writer.Write(0);
    writer.Write(0);
    WriteString(writer, "synthetic-cube-background");
    WriteString(writer, "synthetic-cube-color");
    writer.Write(0);
    writer.Write(0);
    writer.Write(3);
    writer.Write(4);
    writer.Write(310_100);
    WriteObjectRows(
        writer,
        new[]
        {
          new[] { 311_001 + skillAssignmentVariant },
          new[] { 311_002 + skillAssignmentVariant },
          new[] { 0 }
        });
  });

  private static byte[] WriteCubeLevels() => WriteTable(15, writer =>
  {
    foreach (var level in Enumerable.Range(1, 15))
    {
      writer.Write((byte)9);
      writer.Write(312_000 + level);
      writer.Write(310_100);
      writer.Write(level);
      WriteObjectRows(
          writer,
          new[] { new[] { level }, new[] { level }, new[] { 0 } });
      writer.Write(0);
      writer.Write(0);
      writer.Write(0);
      writer.Write(level);
      WriteObjectRows(
          writer,
          new[] { new[] { 0, 0 }, new[] { 0, 0 }, new[] { 0, 0 } });
    }
  });

  private static byte[] WriteFavoriteItems(SyntheticCombatSupportFault fault) => WriteTable(3, writer =>
  {
    WriteFavoriteItem(
        writer,
        320_001,
        rarity: 1,
        favoriteType: 1,
        nameCode: 0,
        groupId: 321_001,
        weapon: fault == SyntheticCombatSupportFault.UnknownCollectionWeapon ? 99 : 1);
    WriteFavoriteItem(writer, 320_002, rarity: 2, favoriteType: 1, nameCode: 0, groupId: 321_002);
    WriteFavoriteItem(writer, 320_003, rarity: 3, favoriteType: 2, nameCode: 700, groupId: 321_003);
  });

  private static void WriteFavoriteItem(
      BinaryWriter writer,
      int id,
      int rarity,
      int favoriteType,
      int nameCode,
      int groupId,
      int weapon = 1)
  {
    writer.Write((byte)17);
    writer.Write(id);
    for (var field = 0; field < 5; field++)
    {
      WriteString(writer, "synthetic-favorite-text");
    }

    writer.Write(0);
    writer.Write(rarity);
    writer.Write(favoriteType);
    writer.Write(weapon);
    writer.Write(nameCode);
    writer.Write(2);
    writer.Write(groupId);
    writer.Write(0);
    WriteObjectRows(writer, new[] { new[] { 322_001 }, new[] { 322_002 } });
    WriteObjectRows(
        writer,
        new[]
        {
          new[] { 323_001, 1, 0 },
          new[] { 323_002, 1, 0 },
          new[] { 323_003, 1, 0 }
        });
    writer.Write(0);
  }

  private static byte[] WriteFavoriteLevels(SyntheticCombatSupportFault fault) => WriteTable(9, writer =>
  {
    var id = 324_000;
    foreach (var groupId in new[] { 321_001, 321_002, 321_003 })
    {
      foreach (var level in Enumerable.Range(0, 3))
      {
        writer.Write((byte)6);
        writer.Write(id++);
        writer.Write(groupId);
        writer.Write(level / 2);
        writer.Write(level);
        var firstStatKind = fault == SyntheticCombatSupportFault.UnknownCollectionStat &&
            groupId == 321_001 && level == 0 ? 99 : 1;
        WriteObjectRows(
            writer,
            new[]
            {
              new[] { firstStatKind, 10 + level },
              new[] { 2, 20 + level },
              new[] { 3, 30 + level }
            });
        WriteObjectRows(writer, new[] { new[] { level }, new[] { level } });
      }
    }
  });

  private static readonly (int Type, int Subtype, int Attack, int Defence, int Hp)[] ConsoleNodes =
  [
      (1, 1, 0, 0, 450),
    (2, 2, 0, 5, 750),
    (2, 3, 0, 5, 750),
    (2, 4, 0, 5, 750),
    (3, 5, 25, 5, 0),
    (3, 6, 25, 5, 0),
    (3, 7, 25, 5, 0),
    (3, 8, 25, 5, 0),
    (3, 9, 25, 5, 0)
  ];

  private static byte[] WriteConsoleStats() => WriteTable(ConsoleNodes.Length, writer =>
  {
    for (var index = 0; index < ConsoleNodes.Length; index++)
    {
      var node = ConsoleNodes[index];
      writer.Write((byte)14);
      writer.Write(330_000 + index);
      WriteString(writer, "synthetic-console-name");
      WriteString(writer, "synthetic-console-description");
      WriteString(writer, "synthetic-console-level");
      writer.Write(0);
      writer.Write(node.Type);
      writer.Write(node.Subtype);
      writer.Write(0);
      writer.Write(0);
      writer.Write(1);
      writer.Write(0);
      writer.Write(node.Attack);
      writer.Write(node.Defence);
      writer.Write(node.Hp);
    }
  });

  private static byte[] WriteConsoleLevels(int maximumLevel, int? firstMaximumLevel)
  {
    var first = firstMaximumLevel ?? maximumLevel;
    return WriteTable(checked(first + ((ConsoleNodes.Length - 1) * maximumLevel)), writer =>
    {
      var id = 340_000;
      for (var nodeIndex = 0; nodeIndex < ConsoleNodes.Length; nodeIndex++)
      {
        var node = ConsoleNodes[nodeIndex];
        var nodeMaximum = nodeIndex == 0 ? first : maximumLevel;
        foreach (var level in Enumerable.Range(1, nodeMaximum))
        {
          writer.Write((byte)7);
          writer.Write(id++);
          writer.Write(node.Type);
          writer.Write(node.Subtype);
          writer.Write(level);
          writer.Write(level / 10);
          writer.Write(1);
          writer.Write(level);
        }
      }

    });
  }

  private static readonly (int FunctionType, int Weight, bool Negative)[] OverloadKinds =
  [
    (1, 10, false),
    (15, 10, false),
    (108, 12, false),
    (11, 12, false),
    (61, 12, true),
    (9, 12, false),
    (51, 10, false),
    (80, 10, false),
    (8, 12, true)
  ];

  private static byte[] WriteEquipmentOptions() => WriteTable(30, writer =>
  {
    var optionId = 350_000;
    for (var kindIndex = 0; kindIndex < OverloadKinds.Length; kindIndex++)
    {
      var kind = OverloadKinds[kindIndex];
      foreach (var band in Enumerable.Range(0, 3))
      {
        writer.Write((byte)7);
        writer.Write(optionId++);
        WriteString(writer, "synthetic-overload-option");
        writer.Write(StandardOverloadGroup);
        writer.Write(kind.Weight);
        writer.Write(351_000 + kindIndex);
        writer.Write(5);
        foreach (var level in Enumerable.Range((band * 5) + 1, 5))
        {
          writer.Write((byte)2);
          writer.Write(StateEffectId(kindIndex, level));
          writer.Write(level);
        }

        writer.Write(band switch { 0 => 6_000, 1 => 3_500, _ => 500 });
      }
    }

    WriteExcludedEquipmentOption(writer, optionId++, 778_000);
    WriteExcludedEquipmentOption(writer, optionId++, 778_000);
    WriteExcludedEquipmentOption(writer, optionId, 779_000);
  });

  private static void WriteExcludedEquipmentOption(BinaryWriter writer, int id, int groupId)
  {
    writer.Write((byte)7);
    writer.Write(id);
    WriteString(writer, "synthetic-excluded-option");
    writer.Write(groupId);
    writer.Write(1);
    writer.Write(id);
    WriteObjectRows(writer, new[] { new[] { id, 1 } });
    writer.Write(1);
  }

  private static byte[] WriteStateEffects() => WriteTable(135, writer =>
  {
    for (var kindIndex = 0; kindIndex < OverloadKinds.Length; kindIndex++)
    {
      foreach (var level in Enumerable.Range(1, 15))
      {
        writer.Write((byte)5);
        writer.Write(StateEffectId(kindIndex, level));
        writer.Write(0);
        writer.Write(0);
        WriteObjectRows(
            writer,
            new[] { new[] { 0 }, new[] { FunctionId(kindIndex, level) }, new[] { 0 } });
        WriteString(writer, "synthetic-state-effect");
      }
    }
  });

  private static byte[] WriteFunctions(SyntheticCombatSupportFault fault) => WriteTable(135, writer =>
  {
    for (var kindIndex = 0; kindIndex < OverloadKinds.Length; kindIndex++)
    {
      var kind = OverloadKinds[kindIndex];
      foreach (var level in Enumerable.Range(1, 15))
      {
        var magnitude = ((kindIndex + 1) * 100) + level;
        long value = kind.Negative ? -magnitude : magnitude;
        if (fault == SyntheticCombatSupportFault.OverloadSignMismatch &&
            kind.FunctionType == 61 && level == 1)
        {
          value = magnitude;
        }

        WriteFunction(writer, FunctionId(kindIndex, level), level, kind.FunctionType, value);
      }
    }
  });

  private static void WriteFunction(
      BinaryWriter writer,
      int id,
      int level,
      int functionType,
      long functionValue)
  {
    writer.Write((byte)55);
    writer.Write(id);
    writer.Write(1);
    writer.Write(level);
    writer.Write(0);
    WriteString(writer, "synthetic-function");
    WriteString(writer, "synthetic-function-description");
    writer.Write(0);
    writer.Write(0);
    writer.Write(functionType);
    writer.Write(0);
    writer.Write(0);
    writer.Write(functionValue);
    writer.Write(0);
    writer.Write(false);
    for (var field = 14; field <= 24; field++)
    {
      writer.Write(0);
    }

    writer.Write(0L);
    writer.Write(0);
    writer.Write(0);
    writer.Write(0L);
    writer.Write(0);
    WriteString(writer, "synthetic-function-extra");
    WriteString(writer, "synthetic-function-extra");
    writer.Write(0);
    for (var effect = 0; effect < 7; effect++)
    {
      WriteString(writer, "synthetic-function-effect");
      writer.Write(0);
      writer.Write(0);
    }

    writer.Write(0);
  }

  private static int FunctionId(int kindIndex, int level) =>
      360_000 + (kindIndex * 100) + level;

  private static int StateEffectId(int kindIndex, int level) =>
      370_000 + (kindIndex * 100) + level;

  private static void Add(ZipArchive archive, string name, byte[] bytes)
  {
    var entry = archive.CreateEntry($"synthetic/{name}", CompressionLevel.NoCompression);
    using var target = entry.Open();
    target.Write(bytes);
  }

  private static byte[] WriteTable(int count, Action<BinaryWriter> writeRows)
  {
    using var stream = new MemoryStream();
    using (var writer = new BinaryWriter(stream, Encoding.UTF8, leaveOpen: true))
    {
      writer.Write(count);
      writeRows(writer);
    }

    return stream.ToArray();
  }

  private static void WriteObjectRows(BinaryWriter writer, IEnumerable<int[]> rows)
  {
    var normalized = rows.ToArray();
    writer.Write(normalized.Length);
    foreach (var row in normalized)
    {
      writer.Write((byte)row.Length);
      foreach (var value in row)
      {
        writer.Write(value);
      }
    }
  }

  private static void WriteString(BinaryWriter writer, string value)
  {
    writer.Write(value.Length);
    writer.Write(Encoding.Unicode.GetBytes(value));
  }
}
