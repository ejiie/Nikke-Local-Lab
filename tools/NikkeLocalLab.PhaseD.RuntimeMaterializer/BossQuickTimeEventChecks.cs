using EpinelPS.Data;
using MemoryPack;
using System.Text.Json;

// Synthetic records only; uses the installed record type and actual serializer.
internal static class BossQuickTimeEventChecks
{
  internal static void Run()
  {
    var passed = new List<string>();
    void Case(string name, Action action)
    {
      try { action(); passed.Add(name); }
      catch { throw new InvalidOperationException("phase_d_qte_check_failed_" + name); }
    }
    static void Check(bool value)
    {
      if (!value) throw new InvalidOperationException("check_failed");
    }
    static void Reject(string code, Action action)
    {
      try { action(); }
      catch (InvalidOperationException exception) when (exception.Message == "phase_d_qte_" + code) { return; }
      throw new InvalidOperationException("expected_rejection");
    }
    foreach (var element in new[] { 1, 2, 3, 4, 5 })
    {
      Case("element_" + element, () =>
      {
        var before = Rows();
        var after = Clone(before);
        var original = BossQuickTimeEventVariant.HashRecords(before);
        var contract = Contract(before);
        var changed = BossQuickTimeEventVariant.Apply(after, 101, contract, Codes, 4, element);
        Check(changed == (element == 4 ? 0 : 2));
        Check(BossQuickTimeEventVariant.Select(after, 101).All(row => row.ElementId == element));
        Check(after.Single(row => row.Id == 3).ElementId == 4);
        Check(after.Single(row => row.Id == 4).ElementId == 0);
        Check(BossQuickTimeEventVariant.HashImmutable(BossQuickTimeEventVariant.Select(after, 101)) ==
            contract.ImmutablePayloadSetSha256);
        BossQuickTimeEventVariant.VerifyBoundary(before, Clone(after), 101, element, changed);
        Check(BossQuickTimeEventVariant.HashRecords(before) == original);
      });
    }
    Case("legacy_no_qte", () => Check(BossQuickTimeEventVariant.Apply([], 101, null, Codes, 4, 1) == 0));
    Case("legacy_non_elemental", () =>
    {
      var rows = Rows();
      foreach (var row in rows) row.ElementId = 0;
      Check(BossQuickTimeEventVariant.Apply(rows, 101, null, Codes, 4, 1) == 0);
    });
    Case("legacy_baseline", () => Check(BossQuickTimeEventVariant.Apply(Rows(), 101, null, Codes, 4, 4) == 0));
    Case("legacy_elemental_rejected", () => Reject("contract_required", () =>
        BossQuickTimeEventVariant.Apply(Rows(), 101, null, Codes, 4, 1)));
    Case("source_element_codes_mismatch", () => Reject("source_mismatch", () =>
        BossQuickTimeEventVariant.Apply(Rows(), 101, Contract(Rows()) with { SourceElementCodes = ["iron"] }, Codes, 4, 1)));
    Case("target_invalid", () => Reject("target_invalid", () =>
        BossQuickTimeEventVariant.Apply(Rows(), 101, Contract(Rows()), Codes, 4, 0)));
    Case("target_absent", () => Reject("source_mismatch", () =>
        BossQuickTimeEventVariant.Apply(Rows(), 999, Contract(Rows()), Codes, 4, 1)));
    Case("duplicate_id", () =>
    {
      var rows = Rows(); rows[2].Id = rows[0].Id;
      Reject("index_invalid", () => BossQuickTimeEventVariant.Apply(rows, 101, Contract(Rows()), Codes, 4, 1));
    });
    var originalContract = Contract(Rows());
    foreach (var (name, invalid) in new[]
    {
      ("record_hash", originalContract with { RecordSetSha256 = new string('0', 64) }),
      ("immutable_hash", originalContract with { ImmutablePayloadSetSha256 = new string('0', 64) }),
      ("element_hash", originalContract with { SourceElementSetSha256 = new string('0', 64) }),
      ("record_count", originalContract with { RecordCount = 1 }),
      ("monster_count", originalContract with { MonsterReferenceCount = 1 }),
      ("mode", originalContract with { ModeCode = "unsupported" })
    })
      Case(name, () => Reject("source_mismatch", () =>
          BossQuickTimeEventVariant.Apply(Rows(), 101, invalid, Codes, 4, 1)));
    foreach (var element in new[] { 1, 2, 3, 4, 5 })
    {
      // Linked rows authored with different elements: the boss element keeps them
      // as authored; any other target converts all and counts actual differences.
      Case("mixed_source_element_" + element, () =>
      {
        var before = Rows(); before[1].ElementId = 5;
        var after = Clone(before);
        var contract = Contract(before);
        Check(contract.SourceElementCodes.SequenceEqual(["electric", "iron"]));
        var changed = BossQuickTimeEventVariant.Apply(after, 101, contract, Codes, 4, element);
        Check(changed == element switch { 4 => 0, 5 => 1, _ => 2 });
        Check(element == 4
            ? after.Select(row => row.ElementId).SequenceEqual(before.Select(row => row.ElementId))
            : BossQuickTimeEventVariant.Select(after, 101).All(row => row.ElementId == element));
        Check(after.Single(row => row.Id == 3).ElementId == 4 && after.Single(row => row.Id == 4).ElementId == 0);
        BossQuickTimeEventVariant.VerifyBoundary(before, Clone(after), 101, element, changed);
      });
    }
    Case("boss_element_differs_from_qte", () =>
    {
      // Boss iron, linked rows electric: electric target changes no row at all.
      foreach (var (element, expected) in new[] { (5, 0), (4, 0), (1, 2) })
      {
        var after = Rows();
        var changed = BossQuickTimeEventVariant.Apply(after, 101, Contract(Rows()), Codes, 5, element);
        Check(changed == expected);
        BossQuickTimeEventVariant.VerifyBoundary(Rows(), after, 101, element, changed);
      }
    });
    foreach (var (name, elementId) in new[] { ("non_elemental_linked_row", 0), ("unknown_linked_element", 9) })
      Case(name, () =>
      {
        // A linked row without a real element is never made elemental.
        var rows = Rows(); rows[1].ElementId = elementId;
        Reject("source_mismatch", () => BossQuickTimeEventVariant.Apply(rows, 101, Contract(rows), Codes, 4, 1));
      });
    Case("foreign_element_changed", () =>
    {
      var after = Rows(); after[2].ElementId = 1;
      Reject("foreign_row_changed", () => BossQuickTimeEventVariant.VerifyBoundary(Rows(), after, 101, 1, 1));
    });
    Case("wrong_target_element", () =>
    {
      var after = Rows(); after[0].ElementId = 2;
      Reject("foreign_row_changed", () => BossQuickTimeEventVariant.VerifyBoundary(Rows(), after, 101, 1, 1));
    });
    Case("missing_modification", () => Reject("modified_count_invalid", () =>
        BossQuickTimeEventVariant.VerifyBoundary(Rows(), Rows(), 101, 1, 2)));
    Case("table_row_removed", () => Reject("table_boundary_invalid", () =>
        BossQuickTimeEventVariant.VerifyBoundary(Rows(), Rows()[..^1], 101, 1, 0)));
    Case("table_reordered", () => Reject("table_boundary_invalid", () =>
        BossQuickTimeEventVariant.VerifyBoundary(Rows(), Rows().Reverse().ToArray(), 101, 1, 0)));
    var mutations = new (string Name, Action<QuickTimeEventRecord> Change)[]
    {
      ("prefab", row => row.QtePrefab = "synthetic-other-pattern"),
      ("timer", row => row.TimeLimit++),
      ("first_animation", row => row.FirstColAnimTime++),
      ("random", row => row.RandomPreset = !row.RandomPreset),
      ("groups", row => row.GroupId.Add(99)),
      ("monster_references", row => row.MonsterId.Add(999))
    };
    foreach (var (name, mutate) in mutations)
      foreach (var index in new[] { 0, 2 })
        Case(name + "_row_" + index, () =>
        {
          var after = Rows(); mutate(after[index]);
          Reject("immutable_payload_changed", () =>
              BossQuickTimeEventVariant.VerifyBoundary(Rows(), after, 101, 1, 0));
        });
    Console.WriteLine(JsonSerializer.Serialize(new
    {
      contractId = "nll/boss-qte-behavior-check/v1", syntheticOnly = true,
      passed = passed.Count, failed = 0, cases = passed,
      originalClientExecuted = false, operatingDatabaseTouched = false, deployed = false
    }));
  }

  private static QuickTimeEventRecord[] Rows() =>
  [
    new() { Id = 1, MonsterId = [101, 102, 103], ElementId = 4,
        QtePrefab = "synthetic-pattern-a", GroupId = [11, 12], TimeLimit = 30, FirstColAnimTime = 2 },
    new() { Id = 2, MonsterId = [101], ElementId = 4,
        QtePrefab = "synthetic-pattern-b", GroupId = [21], RandomPreset = true, TimeLimit = 15, FirstColAnimTime = 1 },
    new() { Id = 3, MonsterId = [201], ElementId = 4,
        QtePrefab = "synthetic-foreign-pattern", GroupId = [31], TimeLimit = 5 },
    new() { Id = 4, MonsterId = [], ElementId = 0, QtePrefab = null, GroupId = [] }
  ];

  private static QuickTimeEventRecord[] Clone(QuickTimeEventRecord[] rows) =>
      MemoryPackSerializer.Deserialize<QuickTimeEventRecord[]>(MemoryPackSerializer.Serialize(rows))!;

  private static readonly Dictionary<int, string> Codes = new()
  {
    [1] = "fire", [2] = "water", [3] = "wind", [4] = "electric", [5] = "iron"
  };

  // Mirrors discovery: per-row element codes as a sorted set, unknown kept unresolved.
  private static BossRuntimeVariantQuickTimeEventAffinity Contract(QuickTimeEventRecord[] rows)
  {
    var selected = BossQuickTimeEventVariant.Select(rows, 101);
    return new("target_monster_linked_element_only", selected.Length,
        selected.SelectMany(row => row.MonsterId).Distinct().Count(),
        BossQuickTimeEventVariant.HashRecords(selected), BossQuickTimeEventVariant.HashImmutable(selected),
        BossQuickTimeEventVariant.HashElements(selected), selected
            .Select(row => Codes.GetValueOrDefault(row.ElementId, "unresolved"))
            .Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToArray());
  }
}
